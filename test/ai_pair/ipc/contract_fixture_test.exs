defmodule AiPair.IPC.ContractFixtureTest do
  # The timeout fixture changes application environment; keep this module serialized.
  use ExUnit.Case, async: false

  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Pane.StateMachine

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "ai_pair_ipc_contract_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)
    sock_path = Path.join(tmp, "sock/ai-pair.sock")
    server_name = :ipc_contract_fixture_server

    {:ok, server} = Server.start_link(inbox: tmp, name: server_name)

    on_exit(fn ->
      stop_quietly(server)
      File.rm_rf!(tmp)
    end)

    %{sock_path: sock_path}
  end

  test "ping reply matches the v1 fixture", %{sock_path: sock_path} do
    actual = send_frame(sock_path, %{"cmd" => "ping"}) |> Map.put("pong", "<version>")
    assert actual == fixture("ping.ok.json")
  end

  test "pane_status replies match the v1 fixtures", %{sock_path: sock_path} do
    assert send_frame(sock_path, %{"cmd" => "pane_status"}) ==
             fixture("pane_status.error.missing_pane_id.json")

    pane_id = unique_pane("status")
    start_fixture_pane(pane_id, "BUSY_MARKER", fn _, _ -> :ok end, agent: "claude_code")
    wait_for_state(pane_id, :busy)

    actual =
      sock_path
      |> send_frame(%{"cmd" => "pane_status", "pane_id" => pane_id})
      |> Map.put("pane_id", "<pane_id>")
      |> Map.put("state", "<state>")
      |> Map.put("agent", "<agent>")
      |> Map.put("classifier", "<classifier>")

    assert actual == fixture("pane_status.ok.json")

    unowned_pane = unique_pane("status-unowned")
    start_fixture_pane(unowned_pane, "IDLE_MARKER")
    wait_for_state(unowned_pane, :idle)

    assert %{"agent" => nil, "ok" => true} =
             send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => unowned_pane})
  end

  test "pane_status not-found and lookup-race replies match the v1 fixtures", %{
    sock_path: sock_path
  } do
    missing_pane = unique_pane("status-missing")

    not_found =
      sock_path
      |> send_frame(%{"cmd" => "pane_status", "pane_id" => missing_pane})
      |> Map.put("pane_id", "<pane_id>")

    assert not_found == fixture("pane_status.error.pane_not_found.json")

    dead_pane = unique_pane("status-dead")
    owner = self()

    dead_owner =
      spawn(fn ->
        Registry.register(AiPair.Registry, {:pane, dead_pane}, nil)
        send(owner, :dead_status_owner_ready)

        receive do
          {:"$gen_call", _from, :status} -> exit(:kill)
        end
      end)

    on_exit(fn -> if Process.alive?(dead_owner), do: Process.exit(dead_owner, :kill) end)
    assert_receive :dead_status_owner_ready

    dead =
      sock_path
      |> send_frame(%{"cmd" => "pane_status", "pane_id" => dead_pane})
      |> Map.put("pane_id", "<pane_id>")

    assert dead == fixture("pane_status.error.pane_dead.json")
  end

  test "send sent and queued replies match the v1 fixtures", %{sock_path: sock_path} do
    sent_pane = unique_pane("sent")
    owner = self()

    start_fixture_pane(sent_pane, "IDLE_MARKER", fn _, text ->
      send(owner, {:pasted, text})
      :ok
    end)

    wait_for_state(sent_pane, :idle)

    sent =
      sock_path
      |> send_frame(%{
        "cmd" => "send",
        "pane_id" => sent_pane,
        "text" => "sent",
        "msg_id" => "msg_contract_fixture"
      })
      |> Map.put("pane_id", "<pane_id>")

    assert sent == fixture("send.sent.json")
    assert_receive {:pasted, "sent"}

    queued_pane = unique_pane("queued")
    start_fixture_pane(queued_pane, "BUSY_MARKER")
    wait_for_state(queued_pane, :busy)

    queued =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => queued_pane, "text" => "queued"})
      |> Map.put("pane_id", "<pane_id>")

    assert queued == fixture("send.queued.json")
  end

  test "send validation errors match the v1 fixtures", %{sock_path: sock_path} do
    assert send_frame(sock_path, %{"cmd" => "send", "text" => "hello"}) ==
             fixture("send.error.missing_pane_id.json")

    assert send_frame(sock_path, %{"cmd" => "send", "pane_id" => "<pane_id>"}) ==
             fixture("send.error.missing_text.json")

    missing_pane = unique_pane("missing")

    not_found =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => missing_pane, "text" => "hello"})
      |> Map.put("pane_id", "<pane_id>")

    assert not_found == fixture("send.error.pane_not_found.json")
  end

  test "send queue-full reply matches the v1 fixture", %{sock_path: sock_path} do
    pane_id = unique_pane("full")
    pane = start_fixture_pane(pane_id, "BUSY_MARKER")
    wait_for_state(pane_id, :busy)

    for index <- 1..StateMachine.max_pending_sends() do
      assert {:queued, :busy} = StateMachine.send_text(pane, "fill-#{index}")
    end

    actual =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => pane_id, "text" => "overflow"})
      |> Map.put("pane_id", "<pane_id>")

    assert actual == fixture("send.error.queue_full.json")
  end

  test "send oversize and dead-pane replies match the v1 fixtures", %{sock_path: sock_path} do
    pane_id = unique_pane("oversize")
    oversize = :binary.copy("x", 524_289)

    actual =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => pane_id, "text" => oversize})
      |> Map.put("pane_id", "<pane_id>")

    assert actual == fixture("send.error.oversize.json")

    dead_pane = unique_pane("dead")
    pane = start_fixture_pane(dead_pane, "BUSY_MARKER")
    wait_for_state(dead_pane, :busy)
    StateMachine.mark_dead(pane)
    wait_for_state(dead_pane, :dead)

    actual =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => dead_pane, "text" => "hello"})
      |> Map.put("pane_id", "<pane_id>")

    assert actual == fixture("send.error.pane_dead.json")
  end

  test "send timeout reply matches the v1 fixture", %{sock_path: sock_path} do
    previous = Application.get_env(:ai_pair, :send_call_timeout_ms)
    Application.put_env(:ai_pair, :send_call_timeout_ms, 10)

    on_exit(fn ->
      if previous do
        Application.put_env(:ai_pair, :send_call_timeout_ms, previous)
      else
        Application.delete_env(:ai_pair, :send_call_timeout_ms)
      end
    end)

    pane_id = unique_pane("timeout")

    start_fixture_pane(pane_id, "IDLE_MARKER", fn _, _ ->
      Process.sleep(100)
      :ok
    end)

    wait_for_state(pane_id, :idle)

    actual =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => pane_id, "text" => "slow"})
      |> Map.put("pane_id", "<pane_id>")
      |> Map.put("detail", "<detail>")

    assert actual == fixture("send.error.send_timeout.json")
  end

  test "send paste-failure reply matches the v1 fixture", %{sock_path: sock_path} do
    pane_id = unique_pane("paste-failed")
    start_fixture_pane(pane_id, "IDLE_MARKER", fn _, _ -> {:error, :fixture_failure} end)
    wait_for_state(pane_id, :idle)

    actual =
      sock_path
      |> send_frame(%{"cmd" => "send", "pane_id" => pane_id, "text" => "fail"})
      |> Map.put("pane_id", "<pane_id>")
      |> Map.put("detail", "<detail>")

    assert actual == fixture("send.error.paste_failed.json")
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

  defp start_fixture_pane(pane_id, marker, paste_fn \\ fn _, _ -> :ok end, opts \\ []) do
    on_exit(fn -> AiPair.PaneSupervisor.stop_pane(pane_id) end)

    {:ok, pane} =
      AiPair.PaneSupervisor.start_pane(
        pane_id,
        opts ++
          [
            capture_fn: fn _ -> {:ok, marker} end,
            paste_fn: paste_fn,
            classifier: AiPair.Test.MarkerClassifier,
            classifier_name: "fixture",
            poll_interval_ms: 5,
            idle_debounce_ms: 0
          ]
      )

    pane
  end

  defp wait_for_state(pane_id, expected) do
    pane = {:via, Registry, {AiPair.Registry, {:pane, pane_id}}}
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
      :timeout -> flunk("pane #{pane_id} did not reach #{expected}")
    end
  end

  defp unique_pane(label), do: "%contract-#{label}-#{System.unique_integer([:positive])}"
end
