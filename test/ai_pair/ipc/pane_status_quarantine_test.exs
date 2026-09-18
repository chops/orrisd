defmodule AiPair.IPC.PaneStatusQuarantineTest do
  # R04 slice S6 wire guard. NS-39.A.001 forbids new fields on the frozen v1
  # IPC fixtures. AiPair.Pane.StateMachine.status/1 now carries a
  # `:quarantined` boolean; the v1 `pane_status` reply is built from that
  # snapshot (server.ex pane_status/1) by naming its keys one by one, so the
  # new key must NOT leak onto the wire. This row pins that for a pane that
  # IS quarantined — the only case in which a leak could show — against the
  # frozen fixture's exact key set and, with placeholders, its exact content.
  #
  # Starts a private IPC server on a private inbox exactly as
  # contract_fixture_test.exs does; the pane runs on injected fakes, so no
  # tmux server is addressed. Serialized because AiPair.PaneSupervisor is
  # application-global.
  use ExUnit.Case, async: false

  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Pane.StateMachine

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "ai_pair_ipc_quarantine_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    sock_path = Path.join(tmp, "sock/ai-pair.sock")

    {:ok, server} = Server.start_link(inbox: tmp, name: :ipc_pane_status_quarantine_server)

    on_exit(fn ->
      stop_quietly(server)
      File.rm_rf!(tmp)
    end)

    %{sock_path: sock_path}
  end

  test "pane_status for a QUARANTINED pane carries exactly the frozen v1 keys", %{
    sock_path: sock_path
  } do
    pane_id = "%quarantine-wire-#{System.unique_integer([:positive])}"
    on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

    token = make_ref()

    {:ok, pane} =
      AiPair.PaneSupervisor.start_pane(pane_id,
        capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
        paste_fn: fn _, _ -> :ok end,
        classifier: AiPair.Test.MarkerClassifier,
        classifier_name: "fixture",
        agent: "claude_code",
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        quarantine_token: token
      )

    wait_for_state(pane, :idle)

    # Precondition: the pane really is quarantined in-BEAM. Without this the
    # row could pass for a legacy pane and prove nothing about the leak.
    assert %{quarantined: true} = StateMachine.status(pane)

    reply = send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id})
    fixture = fixture("pane_status.ok.json")

    # Exact key set: no "quarantined" (or any other) key may be added to v1.
    assert Enum.sort(Map.keys(reply)) == Enum.sort(Map.keys(fixture))
    refute Map.has_key?(reply, "quarantined")

    # And, with the same placeholders the contract suite substitutes, the
    # whole reply equals the frozen fixture byte-for-byte after decoding.
    normalized =
      reply
      |> Map.put("pane_id", "<pane_id>")
      |> Map.put("state", "<state>")
      |> Map.put("agent", "<agent>")
      |> Map.put("classifier", "<classifier>")

    assert normalized == fixture
    assert reply["state"] == "idle"
    assert reply["pending_count"] == 0
  end

  defp fixture(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp send_frame(sock_path, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  defp wait_for_state(pane, expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000

    Stream.repeatedly(fn -> StateMachine.state(pane) end)
    |> Enum.reduce_while(nil, fn
      ^expected, _ ->
        {:halt, :ok}

      _state, _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, :timeout}
        else
          Process.sleep(5)
          {:cont, nil}
        end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("pane did not reach #{expected}")
    end
  end
end
