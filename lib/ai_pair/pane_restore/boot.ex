defmodule AiPair.PaneRestore.Boot.ReportWriterBehaviour do
  @moduledoc """
  The boot report sink.

  `AiPair.PaneRestore.Boot` accepts either a module implementing this behaviour
  or a two-arity function at the same boundary, so a test can observe the
  publication without a filesystem. `write/2` is handed the absolute report path
  and the published report and answers `:ok` or `{:error, term}`. A writer that
  raises, exits or answers anything else is reported as an error; it is never
  fatal to the boot.
  """
  @callback write(Path.t(), map()) :: :ok | {:error, term()}
end

defmodule AiPair.PaneRestore.Boot do
  @moduledoc """
  One ready-on-return reconciliation attempt per durable daemon boot.

  `start_link/1` returns only after the single `AiPair.PaneRestore.Reconciler`
  attempt has settled - joined, or terminated at the deadline - and the report
  has been handed to the writer. `status/1` then replies the published report,
  the write outcome and the reconciliation outcome, and nothing else ever
  changes them.

  ## What this child owns, and what it does not

    * It owns ONE reconciliation worker, run under its own `Task.Supervisor`,
      and nothing else. The worker is joined on its own monitor before this
      module reports either outcome, so a reported `:completed` or
      `joined: true` is an observation of the worker being DOWN, never a
      guess.
    * It never terminates a `AiPair.PaneRestore.Coordinator` effect worker. An
      effect accepted inside the fence belongs to the coordinator and outlives
      this child's deadline; the deadline ends this boot's WAITING, not the
      work the daemon already asked another process to carry.
    * It is `restart: :temporary`: a later crash must not reconcile a second
      time in the same boot. Reconciliation reads sources it does not own, and
      a second attempt would re-observe a tmux server that this boot has
      already started children against.
    * An unexpected worker failure fails startup (`{:reconciliation_failed,
      reason}`). A crash is not a source refusal and must never be converted
      into a successful empty report, which a reader would take as "every
      source answered and nothing was recorded".

  ## The published report

  The report is the shape `docs/contracts/boot-report.org` freezes, published at
  `<root>/state/boot-report.json`. A boot that timed out publishes the
  contract's timed-out report: no panes, the single
  `{:reconciliation_timeout, deadline_ms}` issue and an unobserved marker
  observation.

  The production writer publishes ATOMICALLY: the encoded bytes are written to
  a hidden temporary file in the same `state` directory, flushed, and renamed
  onto the target, so a concurrent reader observes either the previous document
  or the new one and never a partial one. (The reviewed lane wrote the target
  in place with `File.write/2`, which is observable half-written; the contract's
  atomicity requirement closes that here.)

  The report is never rewritten after publication. The child's state is fixed
  before `init/1` returns and `status/1` only replies it; a reconciliation
  result that arrives after the worker was terminated at the deadline is logged
  and dropped, and any later message is ignored.
  """

  use GenServer, restart: :temporary
  require Logger

  alias AiPair.PaneRestore.Reconciler

  @join_timeout 1_000
  @default_deadline_ms 10_000
  @reconcile_options [:store, :root, :tmux, :binding, :callbacks]
  @options @reconcile_options ++ [:report_writer, :deadline_ms]

  @typedoc "The writer boundary: a behaviour module or a two-arity function."
  @type report_writer :: module() | (Path.t(), map() -> :ok | {:error, term()})

  @type reconciliation :: {:completed, pid()} | {:timed_out, %{worker: pid(), joined: true}}

  @type status :: %{
          report: Reconciler.report(),
          report_write: :ok | {:error, term()},
          reconciliation: reconciliation()
        }

  defmodule ReportWriter do
    @moduledoc """
    The production sink: the report as compact JSON with one trailing newline,
    published by temporary file and rename.

    The temporary file is created in the target's OWN directory, so the rename
    is a same-filesystem `rename(2)` and therefore atomic; its name is hidden
    and does not end in `.json`, so a reader enumerating `*.json` cannot pick
    up a document still being written. It is removed if any step fails, and the
    failure is returned, never raised.
    """

    @behaviour AiPair.PaneRestore.Boot.ReportWriterBehaviour

    @impl true
    def write(path, report) do
      bytes = Jason.encode!(json_value(report)) <> "\n"
      temp = temp_path(path)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- write_and_flush(temp, bytes),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, _reason} = error ->
          _ = File.rm(temp)
          error
      end
    end

    @doc """
    The temporary path `write/2` publishes through, for a target report path.

    In the target's own directory, hidden, and not a `*.json` name: the three
    properties the atomic publish depends on. Each call answers a fresh name.
    """
    @spec temp_path(Path.t()) :: Path.t()
    def temp_path(path) do
      unique = System.unique_integer([:positive])
      Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{unique}.tmp")
    end

    # Flushed before the rename: a publish that survives the rename must not be
    # able to become an empty file behind it.
    defp write_and_flush(path, bytes) do
      case File.open(path, [:write, :binary]) do
        {:ok, device} ->
          written = with :ok <- IO.binwrite(device, bytes), do: :file.sync(device)
          closed = File.close(device)
          if written == :ok, do: closed, else: written

        {:error, _reason} = error ->
          error
      end
    end

    # The contract's "Encoding of Elixir terms", clause for clause as
    # `AiPair.Test.BootReportShape.encode/1` states it.
    defp json_value(value) when is_map(value) and not is_struct(value),
      do: Map.new(value, fn {key, item} -> {json_key(key), json_value(item)} end)

    defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

    defp json_value(value) when is_tuple(value),
      do: value |> Tuple.to_list() |> Enum.map(&json_value/1)

    defp json_value(value) when is_pid(value) or is_reference(value), do: inspect(value)
    defp json_value(value) when value in [true, false, nil], do: value
    defp json_value(value) when is_atom(value), do: Atom.to_string(value)
    defp json_value(value) when is_binary(value) or is_number(value), do: value
    defp json_value(value), do: inspect(value)

    defp json_key(key) when is_binary(key), do: key
    defp json_key(key) when is_atom(key), do: Atom.to_string(key)
    defp json_key(key), do: inspect(key)
  end

  @doc """
  Runs the boot's one reconciliation and publishes its report; ready on return.

  Options, all of `AiPair.PaneRestore.Reconciler.reconcile/1`'s required five
  (`:store`, `:root`, `:tmux`, `:binding`, `:callbacks`) plus:

    * `:report_writer` - a module exporting `write/2` or a two-arity function;
      defaults to #{inspect(__MODULE__)}.ReportWriter
    * `:deadline_ms` - a positive integer, default `#{@default_deadline_ms}`;
      the whole reconciliation attempt is given this long, after which its
      worker is terminated, joined, and the timed-out report is published

  Every option is validated in the CALLER, before a process exists: a caller
  defect raises here rather than becoming a start error that reads like a
  source failure. `{:ok, pid}` means the report has been published.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, config!(opts), timeout: :infinity)
  end

  @doc "The published report, the write outcome and the reconciliation outcome."
  @spec status(GenServer.server()) :: status()
  def status(boot), do: GenServer.call(boot, :status)

  @doc "Where a boot of `root` publishes its report."
  @spec report_path(binary()) :: Path.t()
  def report_path(root) when is_binary(root), do: Path.join([root, "state", "boot-report.json"])

  # --- options --------------------------------------------------------------

  defp config!(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Boot options: #{inspect(unknown)}"
    end

    case Enum.reject(@reconcile_options, &Keyword.has_key?(opts, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "missing required Boot options: #{inspect(missing)}"
    end

    %{
      reconcile: Keyword.take(opts, @reconcile_options),
      root: validated_root!(Keyword.fetch!(opts, :root)),
      writer: validated_writer!(Keyword.get(opts, :report_writer, ReportWriter)),
      deadline_ms: validated_deadline!(Keyword.get(opts, :deadline_ms, @default_deadline_ms))
    }
  end

  # The same rule the Reconciler applies, applied before the worker exists: the
  # timed-out report carries `root` without ever reaching the Reconciler, and a
  # relative root there would publish a document the contract forbids.
  defp validated_root!(root) when is_binary(root) do
    if byte_size(root) > 0 and String.valid?(root) and Path.type(root) == :absolute do
      root
    else
      raise ArgumentError, "root must be an absolute path, got: #{inspect(root)}"
    end
  end

  defp validated_root!(root),
    do: raise(ArgumentError, "root must be an absolute path, got: #{inspect(root)}")

  defp validated_deadline!(deadline) when is_integer(deadline) and deadline > 0, do: deadline

  defp validated_deadline!(deadline),
    do: raise(ArgumentError, "deadline_ms must be a positive integer, got: #{inspect(deadline)}")

  defp validated_writer!(writer) when is_function(writer, 2), do: writer

  defp validated_writer!(writer) when is_atom(writer) and not is_nil(writer) do
    if Code.ensure_loaded?(writer) and function_exported?(writer, :write, 2) do
      writer
    else
      raise ArgumentError, "report_writer module must export write/2, got: #{inspect(writer)}"
    end
  end

  defp validated_writer!(writer),
    do:
      raise(
        ArgumentError,
        "report_writer must be a module exporting write/2 or a function/2, got: #{inspect(writer)}"
      )

  # --- the one attempt ------------------------------------------------------

  @impl true
  def init(config) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn -> Reconciler.reconcile(config.reconcile) end)

      monitor = Process.monitor(task.pid)
      {report, reconciliation} = settle(task, monitor, config)
      report_write = write_report(config.writer, report_path(config.root), report)

      if report_write != :ok do
        Logger.error("boot report write failed: #{inspect(report_write)}")
      end

      {:ok, %{report: report, report_write: report_write, reconciliation: reconciliation}}
    after
      Supervisor.stop(supervisor, :normal, @join_timeout)
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  # Nothing published is ever revised: a message arriving after `init/1` - a
  # reply from a worker this child has already terminated among them - changes
  # no state.
  @impl true
  def handle_info(message, state) do
    Logger.debug("boot ignoring post-publication message: #{inspect(message)}")
    {:noreply, state}
  end

  defp settle(task, monitor, config) do
    case Task.yield(task, config.deadline_ms) do
      {:ok, report} ->
        join!(monitor, task.pid)
        {report, {:completed, task.pid}}

      {:exit, reason} ->
        join!(monitor, task.pid)
        exit({:reconciliation_failed, reason})

      nil ->
        # The separate monitor proves the actual worker is DOWN, including in
        # the completion/deadline race. Only this child's own worker is ever
        # terminated; Coordinator effect workers are never touched.
        Process.exit(task.pid, :kill)
        join!(monitor, task.pid)
        Process.demonitor(task.ref, [:flush])

        receive do
          {ref, _report} when ref == task.ref ->
            Logger.info(
              "late reconciliation completion after deadline: #{inspect(task.pid)}; " <>
                "timeout disposition retained"
            )
        after
          0 -> :ok
        end

        {timed_out_report(config), {:timed_out, %{worker: task.pid, joined: true}}}
    end
  end

  defp timed_out_report(config) do
    %{
      root: config.root,
      panes: [],
      issues: [{:reconciliation_timeout, config.deadline_ms}],
      marker_observation: :unobserved,
      marker_writes: 0
    }
  end

  defp join!(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      @join_timeout -> exit({:reconciliation_join_failed, worker})
    end
  end

  # A sink failure of any shape is a disposition, never an exception: the report
  # stays intact in memory and the daemon still boots.
  defp write_report(writer, path, report) do
    result = if is_function(writer, 2), do: writer.(path, report), else: writer.write(path, report)

    case result do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_writer_result, other}}
    end
  catch
    kind, reason -> {:error, {:report_writer_failed, kind, reason}}
  end
end
