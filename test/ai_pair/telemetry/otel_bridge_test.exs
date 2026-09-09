defmodule AiPair.Telemetry.OtelBridgeTest do
  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper

  alias AiPair.Telemetry.OtelBridge

  setup :setup_otel_capture

  defp start_bridge(opts) do
    opts =
      Keyword.merge(
        [
          name: :"otel_bridge_#{System.unique_integer([:positive])}",
          handler_id: {:otel_bridge_test, System.unique_integer([:positive])}
        ],
        opts
      )

    {:ok, pid} = OtelBridge.start_link(opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    {:ok, pid}
  end

  test "build_attrs flattens measurements + metadata under ai_pair. namespace" do
    attrs =
      OtelBridge.build_attrs(
        %{age_s: 320, count: 1},
        %{pane_id: "%7", reason: :queue_full, msg_id: nil}
      )

    assert attrs == %{
             "ai_pair.age_s" => 320,
             "ai_pair.count" => 1,
             "ai_pair.pane_id" => "%7",
             "ai_pair.reason" => "queue_full"
           }
  end

  test "bridges [:ai_pair, :pane, :reaped] into an ai_pair.pane.reaped span" do
    {:ok, _} = start_bridge(heartbeat_interval_ms: 3_600_000)

    :telemetry.execute(
      [:ai_pair, :pane, :reaped],
      %{elapsed_ms: 42, capture_count: 3, pending_count: 0},
      %{
        pane_id: "%9",
        agent: :claude_code,
        classifier_name: :marker,
        from_state: :busy
      }
    )

    assert {:ok, span} = assert_span(name: "ai_pair.pane.reaped", kind: :internal)
    attrs = span_attrs(span)
    assert attrs["ai_pair.pane_id"] == "%9"
    assert attrs["ai_pair.agent"] == "claude_code"
    assert attrs["ai_pair.from_state"] == "busy"
    assert attrs["ai_pair.elapsed_ms"] == 42
    assert attrs["ai_pair.capture_count"] == 3
    assert attrs["ai_pair.pending_count"] == 0
  end

  test "bridges [:ai_pair, :ipc, :send_rejected] with reason attribute" do
    {:ok, _} = start_bridge(heartbeat_interval_ms: 3_600_000)

    :telemetry.execute(
      [:ai_pair, :ipc, :send_rejected],
      %{count: 1, cap: 32},
      %{pane_id: "%9", agent: :claude_code, reason: :queue_full, from_state: :idle}
    )

    assert {:ok, span} = assert_span(name: "ai_pair.ipc.send_rejected")
    attrs = span_attrs(span)
    assert attrs["ai_pair.reason"] == "queue_full"
    assert attrs["ai_pair.cap"] == 32
    assert attrs["ai_pair.from_state"] == "idle"
  end

  test "bridges [:ai_pair, :inbox, :stuck] with path metadata" do
    {:ok, _} = start_bridge(heartbeat_interval_ms: 3_600_000)

    :telemetry.execute(
      [:ai_pair, :inbox, :stuck],
      %{age_s: 600},
      %{pane_id: nil, msg_id: "m_stuck_abc", path: "/tmp/inbox/m_stuck_abc.json"}
    )

    assert {:ok, span} = assert_span(name: "ai_pair.inbox.stuck")
    attrs = span_attrs(span)
    assert attrs["ai_pair.age_s"] == 600
    assert attrs["ai_pair.msg_id"] == "m_stuck_abc"
    assert attrs["ai_pair.path"] == "/tmp/inbox/m_stuck_abc.json"
    refute Map.has_key?(attrs, "ai_pair.pane_id")
  end

  test "emits ai_pair.daemon.heartbeat span at the configured interval" do
    {:ok, _} = start_bridge(heartbeat_interval_ms: 50)

    assert {:ok, _span} = assert_span([name: "ai_pair.daemon.heartbeat"], 2_000)
    assert {:ok, _span} = assert_span([name: "ai_pair.daemon.heartbeat"], 2_000)
  end

  test "detaches its telemetry handler on terminate" do
    handler_id = {:otel_bridge_detach_test, System.unique_integer([:positive])}

    {:ok, pid} =
      start_bridge(
        handler_id: handler_id,
        heartbeat_interval_ms: 3_600_000
      )

    assert Enum.any?(:telemetry.list_handlers([:ai_pair, :pane, :reaped]), fn h ->
             h.id == handler_id
           end)

    :ok = GenServer.stop(pid)

    refute Enum.any?(:telemetry.list_handlers([:ai_pair, :pane, :reaped]), fn h ->
             h.id == handler_id
           end)
  end
end
