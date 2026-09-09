defmodule AiPair.MsgIdCorrelationTest do
  @moduledoc """
  msg_id ↔ trace correlation.

  Asserts that when `ap send --msg-id <id>` is invoked, the same
  `messaging.message.id` attribute is stamped on all three spans of the canonical chain
  (cli.send → ipc.send → pane.paste), in both the immediate-paste path
  and the queued-then-drained path.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper
  import ExUnit.CaptureIO

  alias AiPair.CLI.Client
  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_msgid_#{System.unique_integer([:positive])}")
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

  test "immediate-paste: --msg-id is stamped on cli.send, ipc.send, and pane.paste",
       %{inbox: inbox} do
    start_ipc!(inbox, :msgid_immediate)

    pane_id = "%msgid-imm-#{System.unique_integer([:positive])}"
    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)

    test_pid = self()
    msg_id = "01J9XABC-MSGID-IMMEDIATE"

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
    Process.sleep(60)
    flush_spans()

    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(
          test_pid,
          {exit_code_ref, Client.main(["send", "--msg-id", msg_id, pane_id, "msgid-imm-payload"])}
        )
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"sent")
    assert_receive {:pasted, "msgid-imm-payload"}, 500

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")

    assert span_attrs(cli_span)["messaging.message.id"] == msg_id,
           "cli.send must stamp msg.id"

    assert span_attrs(ipc_span)["messaging.message.id"] == msg_id,
           "ipc.send must stamp msg.id"

    assert span_attrs(paste_span)["messaging.message.id"] == msg_id,
           "pane.paste must stamp msg.id"
  end

  test "queued path: --msg-id survives the queue and is stamped on the drained pane.paste",
       %{inbox: inbox} do
    start_ipc!(inbox, :msgid_queued)

    pane_id = "%msgid-q-#{System.unique_integer([:positive])}"
    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)

    test_pid = self()
    msg_id = "01J9XABC-MSGID-QUEUED"

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
        send(
          test_pid,
          {exit_code_ref, Client.main(["send", "--msg-id", msg_id, pane_id, "msgid-q-payload"])}
        )
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"queued")

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")

    Agent.update(marker_agent, fn _ -> "IDLE_MARKER" end)
    assert_receive {:pasted, "msgid-q-payload"}, 1_000

    assert {:ok, paste_span} = assert_span([name: "pane.paste"], 500)

    assert span_attrs(cli_span)["messaging.message.id"] == msg_id
    assert span_attrs(ipc_span)["messaging.message.id"] == msg_id

    assert span_attrs(paste_span)["messaging.message.id"] == msg_id,
           "drained pane.paste must carry msg.id (queue entry preserves it)"
  end

  test "no --msg-id: auto-minted msg.id appears on all three spans", %{inbox: inbox} do
    start_ipc!(inbox, :msgid_absent)

    pane_id = "%msgid-absent-#{System.unique_integer([:positive])}"
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
    Process.sleep(60)
    flush_spans()

    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(test_pid, {exit_code_ref, Client.main(["send", pane_id, "no-msgid"])})
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"sent")
    assert_receive {:pasted, "no-msgid"}, 500

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")

    cli_attrs = span_attrs(cli_span)
    msg_id = cli_attrs["messaging.message.id"]

    assert msg_id =~ ~r/^m_\d+_[0-9a-f]{8}$/
    assert cli_attrs["messaging.message.id_minted"] == true
    assert span_attrs(ipc_span)["messaging.message.id"] == msg_id
    assert span_attrs(paste_span)["messaging.message.id"] == msg_id
  end
end
