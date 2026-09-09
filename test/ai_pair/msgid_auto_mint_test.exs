defmodule AiPair.MsgIdAutoMintTest do
  @moduledoc """
  Automatic msg_id minting for ap send.

  Asserts that omitting --msg-id mints an id before the cli.send span opens,
  and that explicit and invalid msg-id behavior stays unchanged.
  """

  use ExUnit.Case, async: false

  import AiPair.Test.OtelHelper
  import ExUnit.CaptureIO

  alias AiPair.CLI.Client
  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor

  @minted_msg_id ~r/^m_\d+_[0-9a-f]{8}$/

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_msgid_auto_#{System.unique_integer([:positive])}")
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

  defp start_idle_pane!(pane_id, test_pid) do
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

    on_exit(fn -> PaneSupervisor.stop_pane(pane_id) end)
    await_state(pane_id, :idle)
    Process.sleep(60)
    flush_spans()
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

  test "omitted --msg-id mints an id and stamps all send spans", %{inbox: inbox} do
    start_ipc!(inbox, :msgid_auto_mint_omitted)

    pane_id = "%msgid-auto-#{System.unique_integer([:positive])}"
    start_idle_pane!(pane_id, self())

    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(self(), {exit_code_ref, Client.main(["send", pane_id, "auto-payload"])})
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"sent")
    assert_receive {:pasted, "auto-payload"}, 500

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")

    cli_attrs = span_attrs(cli_span)
    msg_id = cli_attrs["messaging.message.id"]

    assert msg_id =~ @minted_msg_id
    assert cli_attrs["messaging.message.id_minted"] == true
    assert span_attrs(ipc_span)["messaging.message.id"] == msg_id
    assert span_attrs(paste_span)["messaging.message.id"] == msg_id
  end

  test "explicit --msg-id is preserved without minted attribute", %{inbox: inbox} do
    start_ipc!(inbox, :msgid_auto_mint_explicit)

    pane_id = "%msgid-explicit-#{System.unique_integer([:positive])}"
    start_idle_pane!(pane_id, self())

    exit_code_ref = make_ref()

    stdout =
      capture_io(fn ->
        send(
          self(),
          {exit_code_ref, Client.main(["send", "--msg-id", "foo", pane_id, "explicit-payload"])}
        )
      end)

    assert_receive {^exit_code_ref, 0}, 500
    assert stdout =~ ~s("status":"sent")
    assert_receive {:pasted, "explicit-payload"}, 500

    assert {:ok, cli_span} = assert_span(name: "cli.send")
    assert {:ok, ipc_span} = assert_span(name: "ipc.send")
    assert {:ok, paste_span} = assert_span(name: "pane.paste")

    cli_attrs = span_attrs(cli_span)
    assert cli_attrs["messaging.message.id"] == "foo"
    refute Map.has_key?(cli_attrs, "messaging.message.id_minted")
    assert span_attrs(ipc_span)["messaging.message.id"] == "foo"
    assert span_attrs(paste_span)["messaging.message.id"] == "foo"
  end

  test "--msg-id empty string remains a parse error" do
    assert :error = Client.parse_send(["%1", "payload", "--msg-id", ""])
  end
end
