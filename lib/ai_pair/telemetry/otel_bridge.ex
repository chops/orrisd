defmodule AiPair.Telemetry.OtelBridge do
  @moduledoc """
  Bridges selected `:telemetry` events into OpenTelemetry spans so
  an operator-configured observability backend can derive metrics
  from span names. A periodic `ai_pair.daemon.heartbeat` span supports
  missing-heartbeat alerts configured separately by the operator.

  Bridged events (one OTel span per event, name = dotted atoms):

    * `[:ai_pair, :pane, :reaped]`       → `ai_pair.pane.reaped`
    * `[:ai_pair, :ipc, :send_rejected]` → `ai_pair.ipc.send_rejected`
    * `[:ai_pair, :inbox, :stuck]`       → `ai_pair.inbox.stuck`

  Measurements and metadata are flattened into span attributes under
  the `ai_pair.` namespace (e.g. `ai_pair.age_s`, `ai_pair.reason`).
  Nil values are dropped, atoms are stringified, everything else passes
  through as-is.
  """

  use GenServer

  require OpenTelemetry.Tracer, as: Tracer

  @default_heartbeat_interval_ms 60_000

  @events [
    [:ai_pair, :pane, :reaped],
    [:ai_pair, :ipc, :send_rejected],
    [:ai_pair, :inbox, :stuck]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    handler_id = Keyword.get(opts, :handler_id, __MODULE__)
    interval = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        nil
      )

    Process.send_after(self(), :heartbeat, 1_000)

    {:ok, %{handler_id: handler_id, heartbeat_interval_ms: interval}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Tracer.with_span "ai_pair.daemon.heartbeat", %{kind: :internal} do
      :ok
    end

    Process.send_after(self(), :heartbeat, state.heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    span_name = event |> Enum.map(&Atom.to_string/1) |> Enum.join(".")

    Tracer.with_span span_name, %{
      kind: :internal,
      attributes: build_attrs(measurements, metadata)
    } do
      :ok
    end
  end

  @doc false
  def build_attrs(measurements, metadata) do
    measurements
    |> Map.merge(metadata)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {"ai_pair.#{k}", encode_attr(v)} end)
    |> Map.new()
  end

  defp encode_attr(v) when is_atom(v) and not is_boolean(v), do: Atom.to_string(v)
  defp encode_attr(v), do: v
end
