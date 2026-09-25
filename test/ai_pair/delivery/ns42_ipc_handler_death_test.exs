defmodule AiPair.Delivery.NS42IPCHandlerDeathTest do
  @moduledoc """
  NS-42.C.009, rule 9: the death of the REAL IPC connection handler does not finalize a
  receipt; the death of the operation owner does.

  `ns42_producer_conformance_test.exs` ("the monitored owner is the pane state machine,
  not the process that asked") kills a process started by its own `spawn_caller/3`. That
  proves the requesting process is not the owner, but it is not the connection handler the
  daemon runs, so this file kills that handler instead.

  The handler is the task `AiPair.IPC.Server` starts under
  `AiPair.IPC.ConnectionSupervisor` for each accepted connection (`server.ex:310-331`).
  It serves exactly one frame: it reads it, dispatches it, writes the reply and closes
  (`server.ex:334-343`). A v2 `send` to a busy pane is admitted and queued INSIDE that
  dispatch (`delivery.ex:79-114`, `state_machine.ex:510-551`), and the handler exits as
  soon as it has replied `queued`. There is therefore no moment after the queued reply at
  which the handler is still alive to be killed.

  The row kills it at the latest moment it exists instead: after the receipt is admitted
  and its `queued` line is written, and before the handler has replied. The store's
  `sync` of that `queued` line is held by a `FaultFs` hook (no product code is changed),
  so the pending and queued lines are already in the log while the handler is still
  waiting on the pane for its answer. The handler is killed there, the hook is released,
  and only then are the outcomes read.

  Which child is this connection's handler is proven, not assumed: the module runs
  `async: false`, the supervisor's child set is taken before connecting and at the held
  sync, exactly one child is new, and that child was started by this server's own
  acceptor (its `$callers` names the acceptor pid held in the server state).
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.{FaultFs, MarkerClassifier}

  @connections AiPair.IPC.ConnectionSupervisor
  @text "queued bytes whose handler dies"

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns42_c009_hd_#{n}")
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    {:ok,
     inbox: inbox,
     pane: "%ns42_c009_hd_#{n}",
     id: message_id("ipc-handler-death-#{n}"),
     server_name: :"ns42_c009_hd_#{n}"}
  end

  test "killing the real IPC handler leaves the receipt queued; killing the pane owner " <>
         "finalizes it ambiguous",
       ctx do
    test = self()
    fs = FaultFs.new()

    # The store's first sync is the admission's pending line; its second is the queued
    # line. `ReceiptLog.open/2` issues no `sync` (it uses `dir_sync`), so the numbering
    # starts at admission. The hook holds the store inside that second sync, after the
    # queued bytes are written, until the test releases it. The 5 s bound only matters if
    # the test dies first; it is never reached in a passing run.
    FaultFs.inject(
      fs,
      :sync,
      2,
      {:hook,
       fn ->
         send(test, {:queued_sync_held, self()})

         receive do
           :release_queued_sync -> :ok
         after
           5_000 -> :ok
         end
       end}
    )

    store = start_store!(ctx.inbox, fs)
    # Read before the store is held: a call to a held store would block.
    path = ReceiptStore.path(store)
    sm = start_busy_pane!(ctx.pane, store)
    server = start_server!(ctx, store)
    sock = Path.join(ctx.inbox, "sock/ai-pair.sock")

    assert PaneSupervisor.whereis_pane(ctx.pane) == {:ok, sm},
           "the handler must reach this pane through the registry, as the daemon does"

    # Registered before the send, so no finalization can happen unobserved.
    :ok = ReceiptStore.observe(store, ctx.id)

    before = Task.Supervisor.children(@connections)
    client = connect!(sock)

    :ok =
      :gen_tcp.send(
        client,
        Jason.encode!(%{
          "cmd" => "send",
          "protocol_version" => 2,
          "pane_id" => ctx.pane,
          "msg_id" => ctx.id,
          "text" => @text
        })
      )

    assert_receive {:queued_sync_held, ^store}, 2_000

    # 1. The receipt is admitted and its queued line is in the log.
    held_bytes = File.read!(path)

    assert [
             %{"status" => "pending", "delivery_attempt" => 1, "message_id" => id},
             %{"status" => "queued", "delivery_attempt" => 1, "message_id" => id}
           ] = decode_lines(held_bytes)

    assert id == ctx.id
    assert FaultFs.count(fs, :write) == 2
    assert FaultFs.count(fs, :sync) == 2

    # 2. Exactly one new child of the connection supervisor, started by this server.
    assert [handler] = Task.Supervisor.children(@connections) -- before,
           "exactly one connection handler must be new since the connect"

    # Coupled to the server state field `acceptor` (server.ex:231) and to Task.Supervisor
    # recording its caller in `$callers`; a rename fails here, loudly.
    %{acceptor: acceptor} = :sys.get_state(server)
    assert [^acceptor | _] = dictionary_value(handler, :"$callers")
    refute handler in [sm, store, server, acceptor, self()]

    # 3. Kill the handler while it is still waiting for the pane's answer.
    ref = Process.monitor(handler)
    Process.exit(handler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^handler, :killed}, 1_000

    # Control for step 3: the killed pid was the supervisor's child and is gone from it,
    # and the connection it served got no reply because it was closed mid-request.
    refute handler in Task.Supervisor.children(@connections)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)

    send(store, :release_queued_sync)

    # A call to the pane is answered only after it has finished the send it was handling.
    assert StateMachine.pending_count(sm) == 1,
           "the queued send is still the pane's to deliver after its handler died"

    # 4. No finalization, and the receipt is unchanged, within a bounded window.
    refute_receive {:receipt_finalized, _, _}, 300

    assert File.read!(path) == held_bytes,
           "the connection handler is not the operation owner; its death writes nothing"

    assert FaultFs.count(fs, :write) == 2

    assert {:ok, %{outcome: "queued", status: "queued", delivery_attempt: 1}} =
             reconcile(store, ctx)

    # 5. The pane state machine IS the owner, so its death finalizes the attempt.
    Process.unlink(sm)
    kill_and_await(sm)

    assert_receive {:receipt_finalized, ^id, "ambiguous"}, 1_000

    assert {:ok, %{outcome: "ambiguous", status: "ambiguous", delivery_attempt: 1}} =
             reconcile(store, ctx)

    assert [_pending, _queued, %{"status" => "ambiguous", "delivery_attempt" => 1}] =
             decode_lines(File.read!(path))

    refute_received :unexpected_paste
  end

  # ===== helpers =====

  defp start_store!(inbox, fs) do
    start_supervised!(
      Supervisor.child_spec({ReceiptStore, inbox: inbox, fs: fs},
        id: :ns42_c009_hd_store,
        restart: :temporary
      )
    )
  end

  # A pane that never leaves :busy never drains its queue, so the queued receipt stays
  # unresolved and only owner loss can finalize it. It is registered under the daemon's
  # own pane name, which is how the IPC handler finds it.
  defp start_busy_pane!(pane, store) do
    test = self()

    {:ok, sm} =
      StateMachine.start_link(
        pane_id: pane,
        name: PaneSupervisor.via_pane(pane),
        receipt_store: store,
        capture_fn: fn _pane_id -> {:ok, "BUSY_MARKER"} end,
        paste_fn: fn _pane_id, _text ->
          send(test, :unexpected_paste)
          :ok
        end,
        classifier: MarkerClassifier,
        poll_interval_ms: 10,
        idle_debounce_ms: 0
      )

    on_exit(fn -> stop_quietly(sm, &:gen_statem.stop(&1, :normal, 500)) end)
    assert :ok = await_state(sm, :busy)
    sm
  end

  # The pane refuses a store other than its own (`state_machine.ex:449-452`), so the
  # server is given the same store term the pane holds.
  defp start_server!(ctx, store) do
    {:ok, pid} = Server.start_link(inbox: ctx.inbox, name: ctx.server_name, receipt_store: store)
    on_exit(fn -> stop_quietly(pid, &GenServer.stop(&1, :normal, 1_000)) end)
    pid
  end

  defp stop_quietly(pid, stop) do
    if Process.alive?(pid) do
      try do
        stop.(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp connect!(sock) do
    {:ok, client} =
      :gen_tcp.connect({:local, sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    client
  end

  defp reconcile(store, ctx) do
    ReceiptStore.reconcile(store, ctx.id, ctx.pane, Payload.hash(Payload.new(@text)), wait_ms: 0)
  end

  defp dictionary_value(pid, key) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    Keyword.get(dictionary, key)
  end

  defp decode_lines(bytes) do
    bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("the process under test never went down")
    end
  end

  defp message_id(seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  defp await_state(sm, target, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        StateMachine.state(sm) == target -> :ok
        System.monotonic_time(:millisecond) > deadline -> {:timeout, StateMachine.state(sm)}
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end
end
