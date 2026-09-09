defmodule AiPair.Test.FaultFs do
  @moduledoc """
  An `AiPair.Delivery.Fs` that performs real filesystem work and fails on demand.

  It exists so a test can prove *when* durability happens rather than only that the
  bytes are eventually there. Refusing `sync` and asserting the caller was told the
  append failed is the only way to distinguish "fsynced before replying" from "written,
  replied, and flushed later by the kernel".

  A plan entry is keyed by `{op, nth_call_of_that_op}` or by a one-arity matcher over
  the traced arguments. Faults:

    * `{:error, reason}` -- the operation is not performed and returns that error
    * `{:return, value}` -- the operation is not performed and returns that value
    * `{:torn, keep_bytes}` -- `write` only, writes a prefix and then reports an error
    * `{:hook, fun}` -- run a side effect, then perform the operation normally
    * `:halt` -- fail this operation and every later one, modelling process death

  Every call is counted and appended to an ordered trace, so tests can assert both how
  many fsyncs happened and that a repair was durable before a later append.
  """

  @behaviour AiPair.Delivery.Fs

  alias AiPair.Delivery.SystemFs

  @spec new() :: AiPair.Delivery.Fs.t()
  def new do
    {:ok, agent} =
      Agent.start_link(fn -> %{plan: %{}, matchers: [], counts: %{}, trace: [], halted: false} end)

    {__MODULE__, agent}
  end

  @doc "Fail the `nth` call of `op`, or every call matching a one-arity predicate over its args."
  @spec inject(AiPair.Delivery.Fs.t(), atom(), pos_integer() | (list() -> boolean()), term()) :: :ok
  def inject({__MODULE__, agent}, op, nth, fault) when is_integer(nth) do
    Agent.update(agent, fn state -> put_in(state.plan[{op, nth}], fault) end)
  end

  def inject({__MODULE__, agent}, op, matcher, fault) when is_function(matcher, 1) do
    Agent.update(agent, fn state ->
      %{state | matchers: state.matchers ++ [{op, matcher, fault}]}
    end)
  end

  @doc "How many times `op` was called, faulted or not."
  @spec count(AiPair.Delivery.Fs.t(), atom()) :: non_neg_integer()
  def count({__MODULE__, agent}, op), do: Agent.get(agent, &Map.get(&1.counts, op, 0))

  @doc "Every operation in call order."
  @spec ops(AiPair.Delivery.Fs.t()) :: [atom()]
  def ops({__MODULE__, agent}) do
    Agent.get(agent, fn state -> Enum.map(Enum.reverse(state.trace), &elem(&1, 0)) end)
  end

  @doc "Every operation in call order with its traced arguments."
  @spec trace(AiPair.Delivery.Fs.t()) :: [{atom(), list()}]
  def trace({__MODULE__, agent}), do: Agent.get(agent, &Enum.reverse(&1.trace))

  @spec halted?(AiPair.Delivery.Fs.t()) :: boolean()
  def halted?({__MODULE__, agent}), do: Agent.get(agent, & &1.halted)

  @impl true
  def mkdir_p(agent, dir, mode),
    do: perform(agent, :mkdir_p, [dir, mode], fn -> SystemFs.mkdir_p(nil, dir, mode) end)

  @impl true
  def open(agent, path), do: perform(agent, :open, [path], fn -> SystemFs.open(nil, path) end)

  @impl true
  def write(agent, fd, data) do
    perform(
      agent,
      :write,
      [fd, data],
      fn -> SystemFs.write(nil, fd, data) end,
      fn
        {:torn, keep} ->
          prefix = data |> IO.iodata_to_binary() |> binary_part(0, keep)
          _ = SystemFs.write(nil, fd, prefix)
          {:error, :torn_write}

        _ ->
          :no_special_case
      end
    )
  end

  @impl true
  def sync(agent, fd), do: perform(agent, :sync, [fd], fn -> SystemFs.sync(nil, fd) end)

  @impl true
  def close(agent, fd), do: perform(agent, :close, [fd], fn -> SystemFs.close(nil, fd) end)

  @impl true
  def chmod(agent, path, mode),
    do: perform(agent, :chmod, [path, mode], fn -> SystemFs.chmod(nil, path, mode) end)

  @impl true
  def dir_sync(agent, path),
    do: perform(agent, :dir_sync, [path], fn -> SystemFs.dir_sync(nil, path) end)

  @impl true
  def truncate(agent, path, bytes),
    do: perform(agent, :truncate, [path, bytes], fn -> SystemFs.truncate(nil, path, bytes) end)

  @impl true
  def read(agent, path), do: perform(agent, :read, [path], fn -> SystemFs.read(nil, path) end)

  @impl true
  def exists?(agent, path) do
    case perform(agent, :exists?, [path], fn -> {:ok, SystemFs.exists?(nil, path)} end) do
      {:ok, result} -> result
      _ -> false
    end
  end

  defp perform(agent, op, args, run, special \\ fn _ -> :no_special_case end) do
    case record(agent, op, args) do
      :halted ->
        {:error, :halted}

      {:fault, fault} ->
        case special.(fault) do
          :no_special_case -> apply_fault(agent, fault, run)
          result -> result
        end

      :proceed ->
        run.()
    end
  end

  defp apply_fault(agent, fault, run) do
    case fault do
      {:error, reason} -> {:error, reason}
      {:return, value} -> value
      {:hook, fun} -> hook(fun, run)
      :halt -> halt(agent)
      other -> {:error, {:unsupported_fault, other}}
    end
  end

  defp hook(fun, run) do
    _ = fun.()
    run.()
  end

  defp halt(agent) do
    Agent.update(agent, &%{&1 | halted: true})
    {:error, :halted}
  end

  defp record(agent, op, args) do
    Agent.get_and_update(agent, fn state ->
      if state.halted do
        {:halted, state}
      else
        n = Map.get(state.counts, op, 0) + 1

        state = %{
          state
          | counts: Map.put(state.counts, op, n),
            trace: [{op, args} | state.trace]
        }

        fault =
          case Map.fetch(state.plan, {op, n}) do
            {:ok, fault} ->
              fault

            :error ->
              Enum.find_value(state.matchers, fn
                {^op, matcher, fault} -> if matcher.(args), do: fault
                _ -> nil
              end)
          end

        if fault, do: {{:fault, fault}, state}, else: {:proceed, state}
      end
    end)
  end
end
