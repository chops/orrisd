defmodule AiPair.IPC.ServerTest do
  use ExUnit.Case, async: false

  alias AiPair.Test.ReceiptBackedIPCServer, as: Server
  alias AiPair.Test.RouteGuard

  # TEST-CAPTURE CONTAINMENT. `IPC.Server.attach_pane/3` (`ipc/server.ex:387-391`)
  # supplies neither `:capture_fn` nor `:paste_fn`, so every pane this file
  # attaches polls through `StateMachine.default_capture/1`
  # (`state_machine.ex:246`, `:847-849`), which addresses the REGISTERED
  # `AiPair.Tmux` name. The application starts that adapter with `[]`
  # (`application.ex:32`), so `socket_name` is nil, `prepend_socket/2`
  # (`tmux.ex:571-572`) emits no `-L`, and `run_tmux/2` (`tmux.ex:543`) execs
  # `tmux capture-pane` against the OPERATOR's own default server. Measured
  # before this fix: twelve `capture_pane` calls escaped from this file alone.
  #
  # The guard takes the registered name for the duration of every row, so a
  # default-routed call is refused and RECORDED instead of executed, and a row
  # added later that reaches for the default route is refused the same way
  # rather than silently escaping.
  setup do
    RouteGuard.install!()

    tmp = Path.join(System.tmp_dir!(), "ai_pair_ipc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sock"))
    File.chmod!(Path.join(tmp, "sock"), 0o700)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, inbox: tmp, sock_path: Path.join(tmp, "sock/ai-pair.sock")}
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  test "ping/pong roundtrips a length-prefixed JSON frame over the UDS", %{
    inbox: inbox,
    sock_path: sock_path
  } do
    {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_ping)
    on_exit(fn -> stop_quietly(pid) end)

    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, ~s({"cmd":"ping"}))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)

    assert {:ok, %{"ok" => true, "pong" => version}} = Jason.decode(frame)
    assert is_binary(version)
  end

  test "second start on the same socket is refused", %{inbox: inbox, sock_path: sock_path} do
    {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_first)
    on_exit(fn -> stop_quietly(pid) end)

    Process.flag(:trap_exit, true)
    result = Server.start_link(inbox: inbox, name: :ipc_test_second)

    assert {:error, {:already_running, ^sock_path}} = result
  end

  test "stale socket file is unlinked and rebound", %{inbox: inbox, sock_path: sock_path} do
    File.touch!(sock_path)
    assert File.exists?(sock_path)

    {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_stale)
    on_exit(fn -> stop_quietly(pid) end)

    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, ~s({"cmd":"ping"}))
    {:ok, _frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
  end

  test "frame larger than the cap is rejected", %{inbox: inbox, sock_path: sock_path} do
    {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_oversize)
    on_exit(fn -> stop_quietly(pid) end)

    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    oversize = :binary.copy("a", 1_048_577)
    :ok = :gen_tcp.send(client, oversize)

    assert {:error, _} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
  end

  defp send_frame(sock_path, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock_path}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    :ok = :gen_tcp.send(client, Jason.encode!(payload))
    {:ok, frame} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)
    Jason.decode!(frame)
  end

  describe "attach_pane" do
    setup %{inbox: inbox, sock_path: sock_path} do
      {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_attach)
      on_exit(fn -> stop_quietly(pid) end)
      %{server_pid: pid, sock_path: sock_path}
    end

    test "missing pane_id returns ok:false", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "attach_pane"})
    end

    test "non-string pane_id is rejected as unknown command", %{sock_path: sock_path} do
      assert %{"ok" => false} = send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => 42})
    end

    test "starts a pane and reports started:true with a state string", %{sock_path: sock_path} do
      pane_id = "%attach-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{
               "ok" => true,
               "pane_id" => ^pane_id,
               "started" => true,
               "state" => state
             } = send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      assert state in ~w(idle busy dialog dead unknown)
      assert {:ok, _pid} = AiPair.PaneSupervisor.whereis_pane(pane_id)
    end

    test "second attach on the same pane reports started:false", %{sock_path: sock_path} do
      pane_id = "%attach-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true, "started" => true} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      assert %{"ok" => true, "started" => false, "pane_id" => ^pane_id} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})
    end

    test "no agent → classifier:'stub' and agent:nil", %{sock_path: sock_path} do
      pane_id = "%attach-stub-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{
               "ok" => true,
               "started" => true,
               "agent" => nil,
               "classifier" => "stub"
             } = send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})
    end

    test "known agent → classifier:'fingerprint:<agent>' and agent echoed", %{sock_path: sock_path} do
      pane_id = "%attach-fp-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{
               "ok" => true,
               "started" => true,
               "agent" => "claude_code",
               "classifier" => "fingerprint:claude_code"
             } =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "claude_code"
               })
    end

    test "unknown agent falls back to stub with a fallback marker", %{sock_path: sock_path} do
      pane_id = "%attach-bad-agent-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{
               "ok" => true,
               "started" => true,
               "agent" => "not-a-real-agent",
               "classifier" => "stub",
               "fallback" => "unknown_agent"
             } =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "not-a-real-agent"
               })
    end

    test "corrupt fingerprint JSON falls back to stub with load_failed marker", %{
      sock_path: sock_path
    } do
      tmp =
        Path.join(System.tmp_dir!(), "ai_pair_ipc_corrupt_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "claude_code.json"), "{ invalid json")
      Application.put_env(:ai_pair, :fingerprint_dir, tmp)

      on_exit(fn ->
        Application.delete_env(:ai_pair, :fingerprint_dir)
        File.rm_rf!(tmp)
      end)

      pane_id = "%attach-corrupt-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{
               "ok" => true,
               "agent" => "claude_code",
               "classifier" => "stub",
               "fallback" => "load_failed:" <> _
             } =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "claude_code"
               })
    end

    test "duplicate attach reports the first attach's classifier metadata", %{sock_path: sock_path} do
      pane_id = "%attach-dup-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true, "started" => true, "classifier" => "fingerprint:claude_code"} =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "claude_code"
               })

      # Second attach passes a different agent — the first wins.
      assert %{
               "ok" => true,
               "started" => false,
               "agent" => "claude_code",
               "classifier" => "fingerprint:claude_code"
             } =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "codex_cli"
               })
    end

    test "non-string agent is rejected", %{sock_path: sock_path} do
      pane_id = "%attach-badtype-#{System.unique_integer([:positive])}"

      assert %{"ok" => false, "error" => "agent must be a string"} =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => 42
               })

      # No state machine should have been started.
      assert :error = AiPair.PaneSupervisor.whereis_pane(pane_id)
    end
  end

  describe "send" do
    setup %{inbox: inbox, sock_path: sock_path} do
      {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_send)
      on_exit(fn -> stop_quietly(pid) end)
      %{server_pid: pid, sock_path: sock_path}
    end

    test "missing pane_id returns ok:false", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "send", "text" => "hi"})
    end

    test "missing text returns ok:false", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing text"} =
               send_frame(sock_path, %{"cmd" => "send", "pane_id" => "%send-nope"})
    end

    test "non-string text is rejected as missing text", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing text"} =
               send_frame(sock_path, %{
                 "cmd" => "send",
                 "pane_id" => "%send-nope",
                 "text" => 42
               })
    end

    test "oversize text is rejected", %{sock_path: sock_path} do
      pane_id = "%send-oversize"
      oversize = :binary.copy("x", 524_289)

      assert %{
               "ok" => false,
               "pane_id" => ^pane_id,
               "error" => "oversize",
               "detail" => "text exceeds 524288 bytes"
             } = send_frame(sock_path, %{"cmd" => "send", "pane_id" => pane_id, "text" => oversize})
    end

    test "pane_not_found when no state machine is registered", %{sock_path: sock_path} do
      pane_id = "%send-none-#{System.unique_integer([:positive])}"

      assert %{"ok" => false, "pane_id" => ^pane_id, "error" => "pane_not_found"} =
               send_frame(sock_path, %{
                 "cmd" => "send",
                 "pane_id" => pane_id,
                 "text" => "hello"
               })
    end

    test "send_timeout when paste_fn outlives the configured call timeout", %{sock_path: sock_path} do
      pane_id = "%send-timeout-#{System.unique_integer([:positive])}"

      Application.put_env(:ai_pair, :send_call_timeout_ms, 50)

      on_exit(fn -> Application.delete_env(:ai_pair, :send_call_timeout_ms) end)
      :ok = RouteGuard.own_pane(pane_id)

      capture_fn = fn _ -> {:ok, "IDLE_MARKER"} end

      paste_fn = fn _, _ ->
        Process.sleep(300)
        :ok
      end

      {:ok, _sm} =
        AiPair.PaneSupervisor.start_pane(pane_id,
          capture_fn: capture_fn,
          paste_fn: paste_fn,
          classifier: AiPair.Test.MarkerClassifier,
          poll_interval_ms: 20,
          idle_debounce_ms: 30
        )

      # Wait for the pane to enter :idle and the debounce window to elapse,
      # so that send_text fires paste_fn synchronously inside the SM.
      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn ->
        AiPair.Pane.StateMachine.state({:via, Registry, {AiPair.Registry, {:pane, pane_id}}})
      end)
      |> Enum.reduce_while(:wait, fn
        :idle, _ ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, :timeout}
          else
            Process.sleep(10) && {:cont, :wait}
          end
      end)
      |> case do
        :ok -> :ok
        :timeout -> flunk("pane did not reach :idle in time")
      end

      Process.sleep(50)

      assert %{
               "ok" => false,
               "pane_id" => ^pane_id,
               "error" => "send_timeout",
               "detail" => detail
             } =
               send_frame(sock_path, %{
                 "cmd" => "send",
                 "pane_id" => pane_id,
                 "text" => "slow-paste"
               })

      assert is_binary(detail)
    end

    test "queue_full envelope when pending_sends is at the cap", %{sock_path: sock_path} do
      pane_id = "%send-queuefull-#{System.unique_integer([:positive])}"
      cap = AiPair.Pane.StateMachine.max_pending_sends()

      :ok = RouteGuard.own_pane(pane_id)

      capture_fn = fn _ -> {:ok, "BUSY_MARKER"} end
      paste_fn = fn _, _ -> :ok end

      {:ok, _sm} =
        AiPair.PaneSupervisor.start_pane(pane_id,
          capture_fn: capture_fn,
          paste_fn: paste_fn,
          classifier: AiPair.Test.MarkerClassifier,
          poll_interval_ms: 20,
          idle_debounce_ms: 30
        )

      # Wait until SM is :busy so each send queues instead of pasting.
      sm_via = {:via, Registry, {AiPair.Registry, {:pane, pane_id}}}
      deadline = System.monotonic_time(:millisecond) + 1_000

      Stream.repeatedly(fn -> AiPair.Pane.StateMachine.state(sm_via) end)
      |> Enum.reduce_while(:wait, fn
        :busy, _ ->
          {:halt, :ok}

        _, _ ->
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, :timeout}
          else
            Process.sleep(10) && {:cont, :wait}
          end
      end)
      |> case do
        :ok -> :ok
        :timeout -> flunk("pane did not reach :busy in time")
      end

      # Fill the queue to the cap directly (faster than going through IPC).
      for i <- 1..cap do
        assert {:queued, :busy} = AiPair.Pane.StateMachine.send_text(sm_via, "fill-#{i}")
      end

      # The next send via IPC should hit the cap.
      assert %{
               "ok" => false,
               "pane_id" => ^pane_id,
               "error" => "queue_full",
               "detail" => detail
             } =
               send_frame(sock_path, %{
                 "cmd" => "send",
                 "pane_id" => pane_id,
                 "text" => "rejected"
               })

      assert detail =~ "cap=#{cap}"
    end

    test "after attach, send reports a status / queued / error envelope", %{sock_path: sock_path} do
      pane_id = "%send-attached-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      reply = send_frame(sock_path, %{"cmd" => "send", "pane_id" => pane_id, "text" => "hello"})

      # The attached pane uses the product default capture, which the route
      # guard refuses with status -2. `classify_error/1` (`tmux.ex:815-823`)
      # reads that as "nonzero_exit", NOT "pane_not_found", so the state
      # machine takes its non-`:pane_gone` branch and settles in :unknown
      # rather than advancing the dead-pane reaper. The envelope shape is all
      # this row asserts, and every alternative below stays reachable.
      assert %{"pane_id" => ^pane_id} = reply

      case reply do
        %{"ok" => true, "status" => "queued", "queue_reason" => qr} ->
          assert qr in ~w(unknown busy dialog debounce)

        %{"ok" => true, "status" => "sent"} ->
          :ok

        %{"ok" => false, "error" => err} ->
          assert err in ~w(pane_dead pane_not_found)
      end
    end
  end

  describe "pane_status" do
    setup %{inbox: inbox, sock_path: sock_path} do
      {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_pane_status)
      on_exit(fn -> stop_quietly(pid) end)
      %{server_pid: pid, sock_path: sock_path}
    end

    test "missing pane_id returns ok:false", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "pane_status"})
    end

    test "non-string pane_id is rejected as missing pane_id", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => 42})
    end

    test "pane_not_found when no state machine is registered", %{sock_path: sock_path} do
      pane_id = "%pane-status-none-#{System.unique_integer([:positive])}"

      assert %{"ok" => false, "pane_id" => ^pane_id, "error" => "pane_not_found"} =
               send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id})
    end

    test "attached pane (no agent) reports stub classifier and zero pending_count", %{
      sock_path: sock_path
    } do
      pane_id = "%pane-status-stub-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      reply = send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id})

      assert %{
               "ok" => true,
               "pane_id" => ^pane_id,
               "agent" => nil,
               "classifier" => "stub",
               "pending_count" => 0,
               "state" => state
             } = reply

      assert state in ~w(idle busy dialog dead unknown)
    end

    test "attached pane with known agent reports fingerprint classifier", %{sock_path: sock_path} do
      pane_id = "%pane-status-fp-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true} =
               send_frame(sock_path, %{
                 "cmd" => "attach_pane",
                 "pane_id" => pane_id,
                 "agent" => "claude_code"
               })

      assert %{
               "ok" => true,
               "pane_id" => ^pane_id,
               "agent" => "claude_code",
               "classifier" => "fingerprint:claude_code",
               "pending_count" => 0
             } = send_frame(sock_path, %{"cmd" => "pane_status", "pane_id" => pane_id})
    end
  end

  describe "detach_pane" do
    setup %{inbox: inbox, sock_path: sock_path} do
      {:ok, pid} = Server.start_link(inbox: inbox, name: :ipc_test_detach)
      on_exit(fn -> stop_quietly(pid) end)
      %{server_pid: pid, sock_path: sock_path}
    end

    test "missing pane_id returns ok:false", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "detach_pane"})
    end

    test "non-string pane_id is rejected as missing pane_id", %{sock_path: sock_path} do
      assert %{"ok" => false, "error" => "missing pane_id"} =
               send_frame(sock_path, %{"cmd" => "detach_pane", "pane_id" => 42})
    end

    test "pane_not_found when no state machine is registered", %{sock_path: sock_path} do
      pane_id = "%detach-none-#{System.unique_integer([:positive])}"

      assert %{"ok" => false, "pane_id" => ^pane_id, "error" => "pane_not_found"} =
               send_frame(sock_path, %{"cmd" => "detach_pane", "pane_id" => pane_id})
    end

    test "attached pane is detached and removed from the registry", %{sock_path: sock_path} do
      pane_id = "%detach-ok-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true, "started" => true} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      assert {:ok, _pid} = AiPair.PaneSupervisor.whereis_pane(pane_id)

      assert %{"ok" => true, "pane_id" => ^pane_id, "status" => "detached"} =
               send_frame(sock_path, %{"cmd" => "detach_pane", "pane_id" => pane_id})

      # Allow the registry to clear the dead entry.
      Process.sleep(50)
      assert :error = AiPair.PaneSupervisor.whereis_pane(pane_id)
    end

    test "second detach on a freshly detached pane reports pane_not_found", %{sock_path: sock_path} do
      pane_id = "%detach-twice-#{System.unique_integer([:positive])}"
      :ok = RouteGuard.own_pane(pane_id)

      assert %{"ok" => true} =
               send_frame(sock_path, %{"cmd" => "attach_pane", "pane_id" => pane_id})

      assert %{"ok" => true, "status" => "detached"} =
               send_frame(sock_path, %{"cmd" => "detach_pane", "pane_id" => pane_id})

      Process.sleep(50)

      assert %{"ok" => false, "pane_id" => ^pane_id, "error" => "pane_not_found"} =
               send_frame(sock_path, %{"cmd" => "detach_pane", "pane_id" => pane_id})
    end
  end
end
