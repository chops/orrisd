defmodule Mix.Tasks.AiPair.AlertProbe do
  @shortdoc "Inject synthetic telemetry events to validate the Tempo → Grafana alert pipeline"

  @moduledoc """
  Synthetic injection probe for the
  `:telemetry` → `AiPair.Telemetry.OtelBridge` → OTel exporter → Tempo
  metrics_generator → TraceQL `count_over_time()` → Grafana alert rule
  pipeline.

  This task is a validation tool, not a long-running daemon. It
  runs in a Mix VM (an independently running daemon is unaffected),
  spins up a private `AiPair.Telemetry.OtelBridge` to translate
  `:telemetry` events into OTel spans, emits one or more events for the
  requested probe, force-flushes the SDK, and prints the trace_id so the
  user can confirm the span landed in Tempo before checking the Grafana
  rule state.

  ## Subcommands

      mix ai_pair.alert_probe queue_full      # 1× ai_pair.ipc.send_rejected reason=queue_full
      mix ai_pair.alert_probe pane_reaped     # 1× ai_pair.pane.reaped
      mix ai_pair.alert_probe inbox_stuck     # 1× ai_pair.inbox.stuck
      mix ai_pair.alert_probe heartbeat       # 1× ai_pair.daemon.heartbeat

      mix ai_pair.alert_probe burst <name> <N>
      # e.g. emit five events for an operator-configured burst alert:
      mix ai_pair.alert_probe burst pane_reaped 5

  ## Why a Mix task and not a release eval

  The probe must not boot `AiPair.Application` — that would clash with
  an existing daemon over the IPC socket. The Mix VM only starts
  the OTel SDK and `OtelBridge`; nothing else from the supervision
  tree comes up.

  ## Endpoint

  Spans are exported to the OTLP endpoint configured for the
  `:opentelemetry_exporter` application (config/config.exs default:
  `http://localhost:4318`). Override with `OTEL_EXPORTER_OTLP_ENDPOINT`
  in the calling shell if needed.
  """

  use Mix.Task

  require OpenTelemetry.Tracer, as: Tracer

  @valid_probes ~w(queue_full pane_reaped inbox_stuck heartbeat)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    ensure_otel_started()
    {:ok, bridge_pid} = start_bridge()

    try do
      dispatch(args)
    after
      try do
        :otel_tracer_provider.force_flush()
      catch
        _, _ -> :ok
      end

      GenServer.stop(bridge_pid, :normal, 5_000)
    end
  end

  defp dispatch([name]) when name in @valid_probes, do: probe(name)

  defp dispatch(["burst", name, n_str]) when name in @valid_probes do
    case Integer.parse(n_str) do
      {n, ""} when n > 0 ->
        for _ <- 1..n, do: probe(name)
        Mix.shell().info("burst probe=#{name} count=#{n} done")

      _ ->
        Mix.raise("alert_probe burst: N must be a positive integer, got #{inspect(n_str)}")
    end
  end

  defp dispatch(other) do
    Mix.shell().error(usage())
    Mix.raise("alert_probe: unknown command #{inspect(other)}")
  end

  defp probe(name) do
    parent_span = "ai_pair.alert_probe.#{name}"

    Tracer.with_span parent_span, %{kind: :internal} do
      emit(name)
      trace_id = current_hex_trace_id()
      Mix.shell().info("trace_id=#{trace_id} probe=#{name} parent_span=#{parent_span}")
      trace_id
    end
  end

  defp emit("queue_full") do
    :telemetry.execute(
      [:ai_pair, :ipc, :send_rejected],
      %{count: 1, cap: 32},
      %{reason: :queue_full, pane_id: probe_pane_id(), msg_id: probe_msg_id()}
    )
  end

  defp emit("pane_reaped") do
    :telemetry.execute(
      [:ai_pair, :pane, :reaped],
      %{threshold: 2, missed: 2},
      %{pane_id: probe_pane_id(), reason: :pane_gone}
    )
  end

  defp emit("inbox_stuck") do
    :telemetry.execute(
      [:ai_pair, :inbox, :stuck],
      %{age_s: 600},
      %{pane_id: probe_pane_id(), msg_id: probe_msg_id(), path: "/tmp/alert-probe-stuck"}
    )
  end

  defp emit("heartbeat") do
    # The OtelBridge GenServer emits this on its own timer, but the
    # explicit probe matches the bridge's span shape so we can verify
    # the daemon-down recovery path without waiting 60s for the timer.
    Tracer.with_span "ai_pair.daemon.heartbeat", %{kind: :internal} do
      :ok
    end
  end

  defp probe_pane_id, do: "probe-#{System.unique_integer([:positive])}"
  defp probe_msg_id, do: "m_probe_#{System.unique_integer([:positive])}"

  defp ensure_otel_started do
    # Match the CLI eval pattern in AiPair.CLI.Client.ensure_otel_started_for_eval/0:
    # override the `:batch` default with `:simple` BEFORE starting OTel
    # so `force_flush` is synchronous, not an async cast we'd race on
    # task exit.
    Application.put_env(:opentelemetry, :span_processor, :simple)
    _ = Application.ensure_all_started(:telemetry)
    _ = Application.ensure_all_started(:opentelemetry_exporter)
    _ = Application.ensure_all_started(:opentelemetry)
    :ok
  end

  defp start_bridge do
    # Use a long heartbeat so the bridge's own timer doesn't emit
    # spurious daemon.heartbeat spans during a queue_full/pane_reaped/
    # inbox_stuck probe. The probe will emit one heartbeat explicitly
    # if the user asks for it.
    AiPair.Telemetry.OtelBridge.start_link(
      heartbeat_interval_ms: 3_600_000,
      handler_id: "ai-pair.alert-probe.#{System.unique_integer([:positive])}"
    )
  end

  defp current_hex_trace_id do
    case OpenTelemetry.Tracer.current_span_ctx() do
      :undefined ->
        "undefined"

      span_ctx ->
        # OpenTelemetry.Span.hex_trace_id/1 isn't exposed in every
        # opentelemetry_api version, so format from the raw integer.
        span_ctx
        |> :otel_span.trace_id()
        |> Integer.to_string(16)
        |> String.pad_leading(32, "0")
        |> String.downcase()
    end
  end

  defp usage do
    """
    Usage:
      mix ai_pair.alert_probe queue_full
      mix ai_pair.alert_probe pane_reaped
      mix ai_pair.alert_probe inbox_stuck
      mix ai_pair.alert_probe heartbeat
      mix ai_pair.alert_probe burst <name> <N>
    """
  end
end
