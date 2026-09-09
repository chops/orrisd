defmodule AiPair.PaneSupervisor do
  @moduledoc """
  DynamicSupervisor for per-pane state machines.

  Each child is one `AiPair.Pane.StateMachine` (`:gen_statem`) responsible
  for exactly one tmux pane: log offset, debounce timers, classification,
  and send eligibility. Started lazily when a CLI invocation or a watcher
  discovery registers a pane.

  Lookup goes through `AiPair.Registry` keyed by `{:pane, pane_id}`. Child
  state machines are registered via `{:via, Registry, ...}`, so callers
  can `:gen_statem.call({:via, Registry, ...}, ...)` without consulting
  this supervisor.
  """

  use DynamicSupervisor
  require OpenTelemetry.Tracer, as: Tracer

  @type pane_id :: String.t()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a `StateMachine` for `pane_id`. Extra `opts` are forwarded to
  `AiPair.Pane.StateMachine.start_link/1` (e.g. `:classifier`,
  `:capture_fn`, `:paste_fn`, `:poll_interval_ms`, `:idle_debounce_ms`).
  """
  @spec start_pane(pane_id(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_pane(pane_id, opts \\ []) when is_binary(pane_id) do
    Tracer.with_span "pane.start", %{
      kind: :internal,
      attributes:
        drop_nils(%{
          "pane.id" => pane_id,
          "pane.agent" => Keyword.get(opts, :agent),
          "pane.classifier" => Keyword.get(opts, :classifier_name)
        })
    } do
      sm_opts = [pane_id: pane_id, name: via_pane(pane_id)] ++ opts

      child_spec = %{
        id: {:pane, pane_id},
        start: {AiPair.Pane.StateMachine, :start_link, [sm_opts]},
        restart: :transient,
        shutdown: 5_000,
        type: :worker
      }

      result = DynamicSupervisor.start_child(__MODULE__, child_spec)
      annotate_start_outcome(result)
      result
    end
  end

  # `{:already_started, _}` is a benign idempotency outcome — every
  # CLI `attach` for a known pane hits this path — so we record it as
  # an attribute but leave span status at :unset. Genuine start
  # failures set :error so they surface in trace search.
  defp annotate_start_outcome({:ok, _pid}),
    do: Tracer.set_attribute("pane.start_outcome", "started")

  defp annotate_start_outcome({:error, {:already_started, _pid}}),
    do: Tracer.set_attribute("pane.start_outcome", "already_started")

  defp annotate_start_outcome({:error, reason}) do
    Tracer.set_attribute("pane.start_outcome", "error")
    Tracer.set_status(:error, "pane.start failed: #{inspect(reason)}")
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @spec whereis_pane(pane_id()) :: {:ok, pid()} | :error
  def whereis_pane(pane_id) when is_binary(pane_id) do
    case Registry.lookup(AiPair.Registry, {:pane, pane_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @spec stop_pane(pane_id()) :: :ok | {:error, :not_found}
  def stop_pane(pane_id) when is_binary(pane_id) do
    case whereis_pane(pane_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      :error -> {:error, :not_found}
    end
  end

  @spec via_pane(pane_id()) :: {:via, module(), {module(), {:pane, pane_id()}}}
  def via_pane(pane_id) when is_binary(pane_id) do
    {:via, Registry, {AiPair.Registry, {:pane, pane_id}}}
  end
end
