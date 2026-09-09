defmodule AiPair.OtelTraceLinkageTest do
  @moduledoc """
  End-to-end OpenTelemetry trace-linkage tests for the
  CLI → IPC → StateMachine → paste pipeline.

  Asserts that a single trace ID propagates the whole way and that
  parent-child relationships survive both the UDS hop (CLI ↔ IPC) and
  the `:gen_statem.call` hop (IPC ↔ StateMachine), in both the
  immediate-paste path and the queued-then-drained path.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper
  import ExUnit.CaptureIO

  alias AiPair.CLI.Client
  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_otel_trace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    sock_path = Path.join(tmp, "sock/ai-pair.sock")

    prior_sock = System.get_env("AI_PAIR_DAEMON_SOCK")
    System.put_env("AI_PAIR_DAEMON_SOCK", sock_path)

    on_exit(fn ->
      case prior_sock do
        nil -> System.delete_env("AI_PAIR_DAEMON_SOCK")
        v -> System.put_env("AI_PAIR_DAEMON_SOCK", v)
      end

      File.rm_rf!(tmp)
    end)

    setup_otel_capture()

    {:ok, inbox: tmp, sock_path: sock_path}
  end

  defp start_ipc!(inbox, name) do
    {:ok, pid} = Server.start_link(inbox: inbox, name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  defp await_state(pane_id, target, timeout_ms \\ 1_000) do
    via = {:via, Registry, {AiPair.Registry, {:pane, pane_id}}}
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> StateMachine.state(via) end)
    |> Enum.reduce_while(:wait, fn
      ^target, _ ->
        {:halt, :ok}

      _other, _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, :timeout}
        else
          Process.sleep(10)
          {:cont, :wait}
        end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("pane #{pane_id} did not reach #{inspect(target)} in time")
    end
  end

  test "immediate-paste path: cli.send → ipc.send → pane.paste share a trace, paste.queue_wait_ms == 0",
       %{inbox: inbox} do
    start_ipc!(inbox, :otel_trace_immediate)

    pane_id = "%otel-immediate-#{System.unique_integer([:positive])}"
    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)

    test_pid = self()

    capture_fn = fn _ -> {:ok, "IDLE_MARKER"} end

    paste_fn = fn ^pane_id, text ->
      send(test_pid, {:pasted, text})
      :ok
    end

    {:ok, _sm} =
      PaneSupervisor.start_pane(pane_id,
        capture_fn: capture_fn,
        paste_fn: paste_fn,
        classifier: AiPair.Test.MarkerClassifier,
        poll_interval_ms: 20,
        idle_debounce_ms: 30
      )

    await_state(pane_id, :idle)
    # Let the debounce window elapse so send_text takes the immediate path.
    Process.sleep(60)

    # Drain any spans emitted by the pane bootstrap so they don't interfere
    # with the trace-linkage assertions below.
    flush_spans()

    # Drive the full CLI dispatcher so the `cli.send` span actually opens
    # (it's opened by run_cmd/2 inside main/1, not by request/1 directly).
    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(test_pid, {exit_code_ref, Client.main(["send", pane_id, "trace-imm"])})
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"sent")
    assert_receive {:pasted, "trace-imm"}, 500

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")

    cli_trace = trace_id(cli_span)
    assert cli_trace == trace_id(ipc_span), "ipc.send trace_id should match cli.send"
    assert cli_trace == trace_id(paste_span), "pane.paste trace_id should match cli.send"

    assert parent_span_id(ipc_span) == span_id(cli_span),
           "ipc.send should be a child of cli.send (traceparent over UDS)"

    assert parent_span_id(paste_span) == span_id(ipc_span),
           "pane.paste should be a child of ipc.send (ctx survives :gen_statem.call)"

    cli_attrs = span_attrs(cli_span)
    assert cli_attrs["cli.command"] == "send"
    assert cli_attrs["cli.exit_code"] == 0

    paste_attrs = span_attrs(paste_span)
    assert paste_attrs["paste.source"] == "send_text"
    assert paste_attrs["paste.queue_wait_ms"] == 0
    assert paste_attrs["paste.bytes"] == byte_size("trace-imm")
    assert paste_attrs["paste.outcome"] == "ok"
  end

  test "queued path: pane.paste opens from the drain handler, parented to ipc.send, paste.queue_wait_ms > 0",
       %{inbox: inbox} do
    start_ipc!(inbox, :otel_trace_queued)

    pane_id = "%otel-queued-#{System.unique_integer([:positive])}"
    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)

    test_pid = self()

    {:ok, marker_agent} = Agent.start_link(fn -> "BUSY_MARKER" end)
    on_exit(fn -> if Process.alive?(marker_agent), do: Agent.stop(marker_agent) end)

    capture_fn = fn _ -> {:ok, Agent.get(marker_agent, & &1)} end

    paste_fn = fn ^pane_id, text ->
      send(test_pid, {:pasted, text})
      :ok
    end

    {:ok, _sm} =
      PaneSupervisor.start_pane(pane_id,
        capture_fn: capture_fn,
        paste_fn: paste_fn,
        classifier: AiPair.Test.MarkerClassifier,
        poll_interval_ms: 20,
        idle_debounce_ms: 30
      )

    await_state(pane_id, :busy)
    flush_spans()

    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(test_pid, {exit_code_ref, Client.main(["send", pane_id, "trace-q"])})
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"queued")

    # Resolve the cli.send / ipc.send pair BEFORE flipping to idle so we
    # have their span ids to match against the later pane.paste.
    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")

    # Flip the pane to idle and wait for the drain timer to fire.
    Agent.update(marker_agent, fn _ -> "IDLE_MARKER" end)

    assert_receive {:pasted, "trace-q"}, 1_000

    assert {:ok, paste_span} = assert_span([name: "pane.paste"], 500)

    assert trace_id(paste_span) == trace_id(cli_span),
           "drained pane.paste should share the cli.send trace_id"

    assert parent_span_id(paste_span) == span_id(ipc_span),
           "drained pane.paste should still parent to ipc.send (queued ctx survives)"

    paste_attrs = span_attrs(paste_span)
    assert paste_attrs["paste.source"] == "drain_queue"
    assert paste_attrs["paste.queue_wait_ms"] > 0
    assert paste_attrs["paste.outcome"] == "ok"
  end
end
