defmodule AiPair.AdmissionG2PathsTest.BlockingFs do
  @moduledoc """
  A pane-intent store fs (`AiPair.PaneIntentStore.Fs`) that delegates every operation to the
  real `SystemFs`, except that while ARMED its commit rename (the write of
  pane-attachments.json) parks the store mid-commit: it reports `{:at_mutation, ref, pid}` to
  the arming test and waits for `{:release, ref}`. The commit then proceeds for real.
  """

  alias AiPair.PaneIntentStore.Fs.SystemFs

  def start! do
    {:ok, agent} = Agent.start(fn -> nil end)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    {__MODULE__, agent}
  end

  def arm({__MODULE__, agent}, test), do: Agent.update(agent, fn _ -> test end)
  def disarm({__MODULE__, agent}), do: Agent.update(agent, fn _ -> nil end)

  def rename(agent, from, to) do
    case Path.basename(to) == "pane-attachments.json" && Agent.get(agent, & &1) do
      test when is_pid(test) ->
        ref = make_ref()
        send(test, {:at_mutation, ref, self()})

        receive do
          {:release, ^ref} -> SystemFs.rename(nil, from, to)
        end

      _ ->
        SystemFs.rename(nil, from, to)
    end
  end

  def lstat(_, path), do: SystemFs.lstat(nil, path)
  def mkdir(_, path), do: SystemFs.mkdir(nil, path)
  def chmod(_, path, mode), do: SystemFs.chmod(nil, path, mode)
  def open_exclusive(_, path), do: SystemFs.open_exclusive(nil, path)
  def read(_, path), do: SystemFs.read(nil, path)
  def write(_, fd, data), do: SystemFs.write(nil, fd, data)
  def file_sync(_, fd), do: SystemFs.file_sync(nil, fd)
  def close(_, fd), do: SystemFs.close(nil, fd)
  def directory_sync(_, dir), do: SystemFs.directory_sync(nil, dir)
  def unlink(_, path), do: SystemFs.unlink(nil, path)
end

defmodule AiPair.AdmissionG2PathsTest do
  @moduledoc """
  NS-32.M.002 RB-3a GREEN-2 guard G2, design r4 W5 (D/rb/RB3A-GREEN2-DESIGN-r4.org, DESIGN GO
  m_20261007T172944Z): for each inventoried path, in the ACTUAL durable application
  (`AiPair.Test.DurableApp`), driving the REAL entry over the daemon socket:

    (a) with a fence held, the version's quiescing refusal and no durable change, no paste;
    (b) a blocking point INSIDE the mutation parks it; while parked, Admission.outstanding/1 is
        exactly the row's expected multiset of {kind, holder} and a quiesce sent then stays
        draining; the test releases ONLY the blocking point (never a ticket), the mutation
        completes through the real path, and only then does the quiesce answer ok, with the
        completed mutation in its observation.

  Blocking points (existing injection points only): the pane's paste_fn for every paste (an
  ordinary receipted send pastes through paste_fn; the tmux gated paste is the released-child
  path only), and the pane-intent store fs commit rename for attach and detach.

  Panes that paste are started in the running application's PaneSupervisor with the option
  set production gives every child (`receipt_store:` and `AiPair.Admission.child_opts/1`) plus
  an injected capture/paste/classifier, as the component rows do; the v3 send pane first takes
  its committed identity from a real durable attach. That production attach binds the
  admission is witnessed separately (row 6 and AdmissionPlumbingTest).
  """

  use ExUnit.Case, async: false

  # A tmux pane id built at run time: the redaction scanner rejects pane-id literals in source.
  defp p(n), do: "%" <> Integer.to_string(n)

  alias AiPair.AdmissionG2PathsTest.BlockingFs
  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Test.{DurableApp, FakeTmuxAdapter, GatedTmuxStub}

  @session "$41"
  @secret String.duplicate("cd", 32)
  @hash "sha256:" <>
          Base.encode16(:crypto.hash(:sha256, Base.decode16!(@secret, case: :lower)),
            case: :lower
          )
  @text "g2 payload"
  @guard_ms 5_000
  @idle_fixture Path.expand("../fixtures/fingerprints/claude_code/idle_001.txt", __DIR__)

  # ---- harness ---------------------------------------------------------------

  defp boot!(panes, extra_env \\ []) do
    app = DurableApp.boot!([], extra_env)

    rows =
      for {pane, pid} <- Enum.with_index(panes, 5000),
          do: DurableApp.row(pane, @session, app.inbox, pid)

    FakeTmuxAdapter.put_rows(app.tmux, rows)
    app
  end

  defp attach(app, pane) do
    DurableApp.request(app.sock, %{
      "cmd" => "attach_pane",
      "pane_id" => pane,
      "agent" => "claude_code",
      "durable" => true
    })
  end

  defp quiesce_task(app) do
    Task.async(fn ->
      DurableApp.request(
        app.sock,
        %{"cmd" => "quiesce", "protocol_version" => 3, "resume_hash" => @hash},
        30_000
      )
    end)
  end

  defp fence!(app) do
    reply = Task.await(quiesce_task(app), 30_000)
    assert reply["ok"] == true and reply["quiesced"] == true, "no fence: #{inspect(reply)}"
    reply
  end

  defp id, do: "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp send_frame(1, pane), do: %{"cmd" => "send", "pane_id" => pane, "text" => @text}

  defp send_frame(version, pane),
    do: %{
      "cmd" => "send",
      "protocol_version" => version,
      "msg_id" => id(),
      "pane_id" => pane,
      "text" => @text
    }

  defp request_task(app, frame),
    do: Task.async(fn -> DurableApp.request(app.sock, frame, 30_000) end)

  # A test pane in the running application: the production child option set, plus a screen the
  # test controls and a paste_fn that parks at {:at_mutation, ref, pid} until {:release, ref}.
  defp pane!(app, pane, screen, extra \\ []) do
    {:ok, agent} = Agent.start(fn -> screen end)
    me = self()

    opts =
      [
        receipt_store: app.receipt_store,
        classifier: AiPair.Test.MarkerClassifier,
        capture_fn: fn _pane -> {:ok, Agent.get(agent, & &1)} end,
        paste_fn: fn _pane, _text ->
          ref = make_ref()
          send(me, {:at_mutation, ref, self()})

          receive do
            {:release, ^ref} -> :ok
          end
        end,
        poll_interval_ms: 20,
        idle_debounce_ms: 20
      ] ++ AiPair.Admission.child_opts(AiPair.Admission) ++ extra

    {:ok, pid} = AiPair.PaneSupervisor.start_pane(pane, opts)
    await!(fn -> elem(:sys.get_state(pid), 0) in [:idle, :busy] end, "pane #{pane} classified")
    if screen == "IDLE_MARKER", do: await_settled_idle!(pid)
    %{pid: pid, screen: agent}
  end

  # The pane pastes a send inside its call only once idle for idle_debounce_ms (the state
  # machine's idle_long_enough?/1); before that a send is queued and drained later.
  defp await_settled_idle!(pid) do
    await!(
      fn ->
        {state, data} = :sys.get_state(pid)

        state == :idle and is_integer(data.idle_since_ms) and
          System.monotonic_time(:millisecond) - data.idle_since_ms >= data.idle_debounce_ms
      end,
      "pane settled idle"
    )
  end

  defp at_mutation! do
    assert_receive {:at_mutation, ref, pid}, @guard_ms
    {ref, pid}
  end

  defp release({ref, pid}), do: send(pid, {:release, ref})

  defp outstanding, do: AiPair.Admission.outstanding(AiPair.Admission)

  defp draining?, do: match?({:draining, _, _, _, _}, :sys.get_state(AiPair.Admission).mode)

  defp await!(fun, what, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries > 0 -> Process.sleep(5) && await!(fun, what, tries - 1)
      true -> flunk("never: #{what}")
    end
  end

  # One live IPC handler (a connection task, never the pane) holds `kind`.
  defp assert_ipc_ticket!(kind, pane_pid) do
    assert [{^kind, holder}] = outstanding()
    assert holder != pane_pid and Process.alive?(holder)
    holder
  end

  defp quiesced_observation!(task) do
    reply = Task.await(task, 30_000)
    assert reply["ok"] == true and reply["quiesced"] == true, inspect(reply)
    reply["observation"]
  end

  # ---- rows ------------------------------------------------------------------

  describe "row 1: v1 send (send_legacy; the pane's paste_fn; no receipt)" do
    test "(b) the ticket spans the paste and the drain waits for it" do
      app = boot!([p(9201)])
      assert attach(app, p(9201))["ok"]
      pane = pane!(app, p(9202), "IDLE_MARKER")

      send_task = request_task(app, send_frame(1, p(9202)))
      parked = at_mutation!()
      assert_ipc_ticket!(:ipc_send, pane.pid)

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      assert [{:ipc_send, _}] = outstanding()

      release(parked)
      assert Task.await(send_task, 30_000)["ok"] == true
      observation = quiesced_observation!(q)
      assert observation["receipts"]["queued"] == 0 and observation["receipts"]["pending"] == 0
    end

    test "(a) fence held: quiescing, no paste, nothing durable changes" do
      app = boot!([p(9203)])
      assert attach(app, p(9203))["ok"]
      _pane = pane!(app, p(9204), "IDLE_MARKER")
      fence!(app)
      before = DurableApp.snapshot(app.inbox)

      assert DurableApp.request(app.sock, send_frame(1, p(9204))) == %{
               "ok" => false,
               "error" => "quiescing"
             }

      refute_received {:at_mutation, _, _}
      assert DurableApp.snapshot(app.inbox) == before
    end
  end

  describe "row 2: v2 send to an idle pane, immediate paste" do
    test "(b) the send's own ticket spans admit and paste; the drain waits for it",
      do: immediate_send_spans!(2, p(9321))

    test "(a) fence held: quiescing, no receipt, no paste", do: fenced_send_refused!(2, p(9322))
  end

  describe "row 3: v3 send to an idle pane, immediate paste" do
    test "(b) the send's own ticket spans admit and paste; the drain waits for it",
      do: immediate_send_spans!(3, p(9331))

    test "(a) fence held: quiescing, no receipt, no paste", do: fenced_send_refused!(3, p(9332))
  end

  defp immediate_send_spans!(version, pane_id) do
    app = boot!([pane_id])
    pane = send_pane!(app, version, pane_id)

    send_task = request_task(app, send_frame(version, pane_id))
    parked = at_mutation!()
    assert_ipc_ticket!(:ipc_send, pane.pid)

    q = quiesce_task(app)
    await!(&draining?/0, "quiesce draining")
    assert [{:ipc_send, _}] = outstanding()

    release(parked)
    assert Task.await(send_task, 30_000)["ok"] == true
    observation = quiesced_observation!(q)
    assert observation["receipts"]["pending"] == 0 and observation["receipts"]["queued"] == 0
  end

  defp fenced_send_refused!(version, pane_id) do
    app = boot!([pane_id])
    _pane = send_pane!(app, version, pane_id)
    fence!(app)
    before = DurableApp.snapshot(app.inbox)

    reply = DurableApp.request(app.sock, send_frame(version, pane_id))
    assert reply["ok"] == false and reply["error"] == "quiescing"
    refute_received {:at_mutation, _, _}
    assert DurableApp.snapshot(app.inbox) == before
  end

  # v2: any pane in the census with a committed record keeps the observation certifiable; the
  # v3 pane's identity is the committed registration of a real durable attach, which the test
  # child then carries (the production child is stopped first, its record kept).
  defp send_pane!(app, 2, pane) do
    assert attach(app, pane)["ok"]
    :ok = AiPair.PaneSupervisor.stop_pane(pane)
    pane!(app, pane, "IDLE_MARKER")
  end

  defp send_pane!(app, 3, pane) do
    assert attach(app, pane)["ok"]
    {:ok, records} = AiPair.PaneIntentStore.list(app.intent_store)
    %{"registration_id" => registration} = Enum.find(records, &(&1["pane_id"] == pane))
    :ok = AiPair.PaneSupervisor.stop_pane(pane)
    pane!(app, pane, "IDLE_MARKER", registration_id: registration)
  end

  describe "row 4: a queued send's idle paste (:idle_paste, held by the pane)" do
    test "(b) the pane's ticket spans the idle paste; the drain waits for it" do
      app = boot!([p(9401)])
      pane = send_pane!(app, 2, p(9401))
      Agent.update(pane.screen, fn _ -> "BUSY_MARKER" end)
      await!(fn -> elem(:sys.get_state(pane.pid), 0) == :busy end, "pane busy")

      assert DurableApp.request(app.sock, send_frame(2, p(9401)))["ok"] == true
      assert outstanding() == []

      Agent.update(pane.screen, fn _ -> "IDLE_MARKER" end)
      parked = at_mutation!()
      assert outstanding() == [{:idle_paste, pane.pid}]

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      release(parked)
      observation = quiesced_observation!(q)
      assert observation["receipts"]["queued"] == 0 and observation["receipts"]["pending"] == 0
    end

    test "(a) fence held: the idle paste is refused, the entry stays queued" do
      app = boot!([p(9402)])
      pane = send_pane!(app, 2, p(9402))
      Agent.update(pane.screen, fn _ -> "BUSY_MARKER" end)
      await!(fn -> elem(:sys.get_state(pane.pid), 0) == :busy end, "pane busy")
      frame = send_frame(2, p(9402))
      assert DurableApp.request(app.sock, frame)["ok"] == true
      fence!(app)

      Agent.update(pane.screen, fn _ -> "IDLE_MARKER" end)
      await!(fn -> elem(:sys.get_state(pane.pid), 0) == :idle end, "pane idle")
      # The drain retries every idle_debounce_ms while refused; three periods with no paste.
      Process.sleep(60)
      refute_received {:at_mutation, _, _}

      hash = AiPair.Delivery.Payload.hash(AiPair.Delivery.Payload.new(@text))

      assert {:ok, %{status: "queued"}} =
               ReceiptStore.reconcile(app.receipt_store, frame["msg_id"], p(9402), hash, wait_ms: 0)
    end
  end

  # A released child with one matched restored entry: durable attach (claude_code), a v3 send
  # queued behind the production child, a daemon restart (Boot restores and quarantines), the
  # fake adapter serving an idle claude_code screen and forwarding the gated transaction to a
  # REAL AiPair.Tmux adapter over the parking Bash stub, then the v3 release (matched 1).
  defp released_with_matched_entry!(pane) do
    app = boot!([pane])
    assert attach(app, pane)["ok"]
    frame = send_frame(3, pane)
    assert DurableApp.request(app.sock, frame)["status"] == "queued"
    app = DurableApp.restart!(app)
    stub = GatedTmuxStub.start!()
    GatedTmuxStub.park(stub)
    :ok = GenServer.call(app.tmux, {:fake_gated_to, stub.name})
    %{app: app, stub: stub, msg: frame["msg_id"]}
  end

  defp released_receipt(app, msg, pane) do
    hash = AiPair.Delivery.Payload.hash(AiPair.Delivery.Payload.new(@text))
    {:ok, view} = ReceiptStore.reconcile(app.receipt_store, msg, pane, hash, wait_ms: 0)
    view.status
  end

  describe "row 4g: a released child's gated transaction (tmux.ex begin_command, :idle_paste)" do
    test "(b) the pane's ticket spans begin_command and the gated steps; the drain waits for them" do
      %{app: app, stub: stub, msg: msg} = released_with_matched_entry!(p(9451))

      released =
        DurableApp.request(app.sock, %{
          "cmd" => "release",
          "protocol_version" => 3,
          "pane_id" => p(9451)
        })

      assert released["ok"] == true and released["counts"]["matched"] == 1

      :ok = GenServer.call(app.tmux, {:fake_put_screen, File.read!(@idle_fixture)})
      await!(fn -> GatedTmuxStub.parked?(stub) end, "the gated paste-buffer step parked")

      # Inside the mutation: begin_command recorded its marker, a step is running, and the only
      # ticket is the released child's :idle_paste.
      {:ok, child} = AiPair.PaneSupervisor.whereis_pane(p(9451))
      assert outstanding() == [{:idle_paste, child}]
      store = GenServer.whereis(app.receipt_store)
      assert Map.has_key?(:sys.get_state(store).started, p(9451))

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      assert Task.yield(q, 0) == nil
      GatedTmuxStub.release(stub)

      observation = quiesced_observation!(q)
      assert observation["receipts"]["queued"] == 0 and observation["receipts"]["pending"] == 0
      assert released_receipt(app, msg, p(9451)) == "delivered"
    end

    test "(a) fence held: the released child's gated paste is refused; the entry stays queued" do
      %{app: app, stub: stub, msg: msg} = released_with_matched_entry!(p(9452))

      released =
        DurableApp.request(app.sock, %{
          "cmd" => "release",
          "protocol_version" => 3,
          "pane_id" => p(9452)
        })

      assert released["ok"] == true
      fence!(app)

      :ok = GenServer.call(app.tmux, {:fake_put_screen, File.read!(@idle_fixture)})
      {:ok, child} = AiPair.PaneSupervisor.whereis_pane(p(9452))
      await!(fn -> elem(:sys.get_state(child), 0) == :idle end, "released child idle")
      # The drain retries every idle_debounce_ms while refused; three periods with no step.
      Process.sleep(3 * elem(:sys.get_state(child), 1).idle_debounce_ms)
      refute GatedTmuxStub.parked?(stub)
      assert released_receipt(app, msg, p(9452)) == "queued"
    end
  end

  describe "row 5: one pane, idle paste then a second send (the only order on one pane)" do
    test "both tickets are outstanding; the drain ends only after the second send completes" do
      app = boot!([p(9501)])
      pane = send_pane!(app, 2, p(9501))
      Agent.update(pane.screen, fn _ -> "BUSY_MARKER" end)
      await!(fn -> elem(:sys.get_state(pane.pid), 0) == :busy end, "pane busy")
      assert DurableApp.request(app.sock, send_frame(2, p(9501)))["ok"] == true

      Agent.update(pane.screen, fn _ -> "IDLE_MARKER" end)
      first = at_mutation!()

      second = request_task(app, send_frame(2, p(9501)))
      await!(fn -> length(outstanding()) == 2 end, "the second send's ticket")
      assert [{:idle_paste, pane_pid}, {:ipc_send, handler2}] = outstanding()
      assert pane_pid == pane.pid and handler2 != pane.pid

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")

      # Only the blocking point is released; the idle paste completes and returns its ticket,
      # then the pane serves the second send, whose own paste parks again.
      release(first)
      second_paste = at_mutation!()
      assert outstanding() == [{:ipc_send, handler2}]
      assert draining?()
      assert Task.yield(q, 0) == nil

      release(second_paste)
      assert Task.await(second, 30_000)["ok"] == true
      observation = quiesced_observation!(q)
      assert observation["receipts"]["queued"] == 0 and observation["receipts"]["pending"] == 0
    end
  end

  describe "row 5b: two panes, the reverse release order" do
    test "the send on B is released first, then A's idle paste; the drain waits for both" do
      app = boot!([p(9511), p(9512)])
      a = send_pane!(app, 2, p(9511))
      b = send_pane!(app, 2, p(9512))

      Agent.update(a.screen, fn _ -> "BUSY_MARKER" end)
      await!(fn -> elem(:sys.get_state(a.pid), 0) == :busy end, "A busy")
      assert DurableApp.request(app.sock, send_frame(2, p(9511)))["ok"] == true
      Agent.update(a.screen, fn _ -> "IDLE_MARKER" end)
      parked_a = at_mutation!()

      send_b = request_task(app, send_frame(2, p(9512)))
      parked_b = at_mutation!()
      await!(fn -> length(outstanding()) == 2 end, "both tickets")
      assert [{:idle_paste, a_pid}, {:ipc_send, handler_b}] = outstanding()
      assert a_pid == a.pid and handler_b != b.pid

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")

      release(parked_b)
      assert Task.await(send_b, 30_000)["ok"] == true
      await!(fn -> outstanding() == [{:idle_paste, a.pid}] end, "B's ticket returned")
      assert draining?()

      release(parked_a)
      observation = quiesced_observation!(q)
      # Seeded: A held one queued entry, B none; both delivered before the observation.
      assert observation["receipts"]["queued"] == 0 and observation["receipts"]["pending"] == 0
    end
  end

  describe "rows 6 and 7: durable attach and detach (the pane-intent commit)" do
    test "(b) attach: the ticket spans the intent commit; the drain waits for it" do
      fs = BlockingFs.start!()
      app = boot!([p(9601), p(9602)], pane_intent_store_fs: fs)
      assert attach(app, p(9601))["ok"]

      BlockingFs.arm(fs, self())
      attach_task = Task.async(fn -> attach(app, p(9602)) end)
      parked = at_mutation!()
      assert_ipc_ticket!(:attach_pane, nil)

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      BlockingFs.disarm(fs)
      release(parked)
      assert Task.await(attach_task, 30_000)["ok"] == true
      assert quiesced_observation!(q)["pane_intent"]["live_panes"] == 2
    end

    test "(b) detach: the ticket spans the intent commit; the drain waits for it" do
      fs = BlockingFs.start!()
      app = boot!([p(9611), p(9612)], pane_intent_store_fs: fs)
      assert attach(app, p(9611))["ok"]
      assert attach(app, p(9612))["ok"]

      BlockingFs.arm(fs, self())

      detach =
        Task.async(fn ->
          DurableApp.request(app.sock, %{"cmd" => "detach_pane", "pane_id" => p(9612)}, 30_000)
        end)

      parked = at_mutation!()
      assert_ipc_ticket!(:detach_pane, nil)

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      BlockingFs.disarm(fs)
      release(parked)
      assert Task.await(detach, 30_000)["ok"] == true
      assert quiesced_observation!(q)["pane_intent"]["live_panes"] == 1
    end

    test "(a) fence held: attach and detach are refused quiescing, no intent, marker or child change" do
      app = boot!([p(9621), p(9622)])
      assert attach(app, p(9621))["ok"]
      fence!(app)
      before = DurableApp.snapshot(app.inbox)
      writes = FakeTmuxAdapter.writes(app.tmux)

      assert attach(app, p(9622)) == %{"ok" => false, "error" => "quiescing"}

      assert DurableApp.request(app.sock, %{"cmd" => "detach_pane", "pane_id" => p(9621)}) ==
               %{"ok" => false, "error" => "quiescing"}

      assert DurableApp.snapshot(app.inbox) == before
      assert FakeTmuxAdapter.writes(app.tmux) == writes
      assert AiPair.PaneSupervisor.whereis_pane(p(9622)) == :error
      assert {:ok, _} = AiPair.PaneSupervisor.whereis_pane(p(9621))
    end

    test "a production durable attach binds its child to the registered admission" do
      app = boot!([p(9631)])
      assert attach(app, p(9631))["ok"]
      {:ok, pid} = AiPair.PaneSupervisor.whereis_pane(p(9631))
      assert elem(:sys.get_state(pid), 1).admission == AiPair.Admission
    end
  end

  # A daemon restart over a committed attach: Boot's reconciliation quarantines the pane.
  defp restarted_quarantine!(pane) do
    app = boot!([pane])
    assert attach(app, pane)["ok"]
    # From here every census records whether the daemon socket existed when it was taken.
    :ok = GenServer.call(app.tmux, {:fake_watch, app.sock})
    app = DurableApp.restart!(app)
    {:ok, pid} = AiPair.PaneSupervisor.whereis_pane(pane)
    {app, pid}
  end

  describe "row 9: Boot" do
    test "a pane child Boot's reconciliation starts carries the registered admission, and the socket follows Boot" do
      {app, pid} = restarted_quarantine!(p(9701))
      assert elem(:sys.get_state(pid), 1).admission == AiPair.Admission

      {AiPair.PaneRestore.Boot, boot, _, _} =
        List.keyfind(Supervisor.which_children(AiPair.Supervisor), AiPair.PaneRestore.Boot, 0)

      status = AiPair.PaneRestore.Boot.status(boot)
      assert {:completed, _worker} = status.reconciliation
      pane = p(9701)
      assert [%{pane_id: ^pane, status: :observed_quarantined}] = status.report.panes

      # The ordered trace: Boot's reconciliation census was taken while the daemon socket did
      # not exist, and the socket exists once the boot returned (a census now sees it).
      assert [{:census, false} | _] = GenServer.call(app.tmux, :fake_trace)
      {:ok, _} = AiPair.Tmux.observe_panes(app.tmux)
      assert List.last(GenServer.call(app.tmux, :fake_trace)) == {:census, true}
      assert File.exists?(app.sock)
    end
  end

  describe "row 8: v3 release" do
    test "(b) the release ticket spans Release.run; the drain waits for the release to finish" do
      {app, quarantined} = restarted_quarantine!(p(9801))

      # The blocking point, INSIDE the release's mutations: the pane supervisor is suspended,
      # so Release.run parks in its stop step, after its held check, identity proof and the
      # receipt store fence it took, and before the stop, the restore capability and the start.
      supervisor = Process.whereis(AiPair.PaneSupervisor)
      :ok = :sys.suspend(supervisor)

      release =
        request_task(app, %{"cmd" => "release", "protocol_version" => 3, "pane_id" => p(9801)})

      await!(fn -> match?([{:release, _}], outstanding()) end, "the release ticket")
      assert_ipc_ticket!(:release, quarantined)
      # Where it is parked, read from the ticket holder itself: in Release.stop/2, the step after
      # the held check, the identity proof and the store fence.
      [{:release, holder}] = outstanding()

      await!(
        fn ->
          {:current_stacktrace, frames} = Process.info(holder, :current_stacktrace)
          Enum.any?(frames, &match?({AiPair.PaneRestore.Release, :stop, 2, _}, &1))
        end,
        "the release parked in its stop step"
      )

      q = quiesce_task(app)
      await!(&draining?/0, "quiesce draining")
      assert Task.yield(release, 0) == nil
      assert {:ok, ^quarantined} = AiPair.PaneSupervisor.whereis_pane(p(9801))
      :ok = :sys.resume(supervisor)

      observation = quiesced_observation!(q)
      # The quiesce could answer only after the ticket's whole Release.run returned: the
      # release had replied and its child replaced the quarantined one by then.
      assert {:ok, reply} = Task.yield(release, 0)
      assert reply["ok"] == true and reply["released"] == true
      {:ok, released} = AiPair.PaneSupervisor.whereis_pane(p(9801))
      assert released != quarantined
      assert elem(:sys.get_state(released), 1).admission == AiPair.Admission
      assert observation["pane_intent"]["live_panes"] == 1
    end

    test "(a) fence held: release is refused quiescing and the quarantined child is untouched" do
      {app, quarantined} = restarted_quarantine!(p(9802))
      fence!(app)
      before = DurableApp.snapshot(app.inbox)

      reply =
        DurableApp.request(app.sock, %{
          "cmd" => "release",
          "protocol_version" => 3,
          "pane_id" => p(9802)
        })

      assert reply["ok"] == false and reply["error"] == "quiescing"
      assert {:ok, ^quarantined} = AiPair.PaneSupervisor.whereis_pane(p(9802))
      assert DurableApp.snapshot(app.inbox) == before
    end
  end
end
