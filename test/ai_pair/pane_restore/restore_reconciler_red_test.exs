defmodule AiPair.PaneRestore.RestoreReconcilerRedTest do
  # NS-15.G.003 S2 (design r4, RED design r3): boot reconciliation hands boot-restored queued
  # sends to the admitted quarantined pane, and re-admission fences the old holder first.
  #
  # Every row is a DEPENDENT RED / contract row: its first step restarts a receipt store that
  # holds S2-epoch queued attempts and asserts they are still queued (ambiguous at Orrisd
  # ff960018, the shared restore prerequisite). The reconciler assertions after it are the
  # GREEN contract:
  #
  #   * Reconciler.reconcile/1 accepts `receipt_store:`; for an admitted pane it obtains a
  #     restore capability from that store and starts the quarantined child with it;
  #   * Reconciler.readmit/2 (`receipt_store:`, `callbacks:`, `stop_timeout_ms:`) fences,
  #     stops the old child, and only then issues and starts the replacement;
  #   * started with `restore_issuer: Coordinator`, the receipt store accepts the call
  #     {:issue_restore_capability, p, ref} or {:fence_restore, p, ref} only when
  #     Coordinator.authorize_effect(Coordinator, caller, p, store, request) is true: a live
  #     recorded worker whose op is exactly that request, for pane p, targeting that store,
  #     submitted by p's live transaction holder, with no cause and the pane's disposition
  #     still :completed (the reconciler sends it through Coordinator.submit(p, store, req)
  #     inside p's transaction); any other caller, a timed-out or abandoned operation, or an
  #     unavailable Coordinator gets {:error, :not_issuer} and nothing changes (R5-R7).
  #
  # Fakes are trimmed copies of reconciler_test.exs's FakeStore and FakeTmux; the fence is the
  # real Coordinator and the child is started through the real PaneSupervisor. paste_fn is a
  # recorder and every row asserts it recorded nothing.
  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.{Coordinator, Reconciler}
  alias AiPair.PaneSupervisor

  @root "/synthetic/inbox"
  @generation "213598703592091008239502170616955211460"
  @binding %{project: "synthetic-project", project_dir: @root, project_inbox: @root}

  defmodule FakeStore do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, %{lists: Keyword.fetch!(opts, :lists)}}
    @impl true
    def handle_call(:list, _from, %{lists: [reply | rest]} = s),
      do: {:reply, reply, %{s | lists: rest}}

    def handle_call(:list, _from, %{lists: []} = s), do: {:stop, :unscripted_list, s}

    def handle_call(request, _from, _s),
      do: raise("no intent write expected, got #{inspect(request)}")
  end

  defmodule FakeTmux do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts),
      do: {:ok, %{observe: Keyword.fetch!(opts, :observe), show: Keyword.fetch!(opts, :show)}}

    @impl true
    def handle_call(:observe_panes, _from, %{observe: [r | rest]} = s),
      do: {:reply, r, %{s | observe: rest}}

    def handle_call({:show_options, target, _option}, _from, s) do
      [r | rest] = Map.fetch!(s.show, target)
      {:reply, r, %{s | show: Map.put(s.show, target, rest)}}
    end

    def handle_call(request, _from, _s),
      do: raise("no tmux write expected, got #{inspect(request)}")
  end

  # A live receipt-store stand-in that refuses every call and reports it (R4 refused branch).
  defmodule RefusingStore do
    use GenServer
    @impl true
    def init(parent), do: {:ok, parent}
    @impl true
    def handle_call(request, _from, parent) do
      send(parent, {:refusing_store_call, request})
      {:reply, {:error, :unavailable}, parent}
    end
  end

  setup do
    inbox = Path.join(System.tmp_dir!(), "restore_s2_c_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
    {:ok, inbox: inbox}
  end

  test "R1 an admitted pane's child is quarantined, claims its restored entries in order, and pastes nothing",
       c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r1-a", "r1-b"])
    {agent, callbacks} = recorder()

    report = reconcile(pane, callbacks, receipt_store: rstore)

    assert [%{status: :observed_quarantined, dispatchable: false}] = report.panes
    assert {:ok, sm} = PaneSupervisor.whereis_pane(pane)
    assert StateMachine.status(sm).quarantined == true

    assert eventually(fn -> StateMachine.pending_count(sm) == 2 end),
           "restored entries not handed over"

    {_state, data} = :sys.get_state(sm)
    assert Enum.map(:queue.to_list(data.pending_sends), &elem(&1, 3)) == [id("r1-a"), id("r1-b")]
    assert Enum.all?(registry(rstore)[pane], &(&1.holder == sm))
    assert {:error, :pane_quarantined} = StateMachine.send_text(sm, "hello")
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R2 entries of a pane boot reconciliation does not admit stay unheld, listed and queued",
       c do
    admitted = pane_id()
    other = pane_id()
    own_pane(admitted)
    rstore = restored_store!(c.inbox, other, ["r2"])
    {agent, callbacks} = recorder()

    _report = reconcile(admitted, callbacks, receipt_store: rstore)

    assert [%{msg_id: msg, holder: nil}] = registry(rstore)[other]
    assert msg == id("r2")
    assert last_status(c.inbox, msg) == {"queued", 1}
    assert :error = PaneSupervisor.whereis_pane(other)
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R3 re-admission fences first: a stuck old child refuses re-admission and its tokens stay void",
       c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r3"])
    {agent, callbacks} = recorder()
    _ = reconcile(pane, callbacks, receipt_store: rstore)
    {:ok, old} = PaneSupervisor.whereis_pane(pane)
    assert eventually(fn -> StateMachine.pending_count(old) == 1 end)
    {_state, data} = :sys.get_state(old)
    [{:receipted, _text, _ctx, msg, _at, old_token}] = :queue.to_list(data.pending_sends)

    # Wedge the old child inside its own capture callback: a busy process answers no
    # system message, so its stop cannot complete (a :sys-suspended one still would).
    Agent.update(agent, &%{&1 | blocked: true})
    assert eventually(fn -> Agent.get(agent, & &1.stuck) > 0 end), "the old child never wedged"

    assert {:error, :stop_timeout} =
             apply(Reconciler, :readmit, [
               pane,
               [receipt_store: rstore, callbacks: callbacks, stop_timeout_ms: 100]
             ])

    assert Process.alive?(old)
    assert {:error, :stale_token} = ReceiptStore.transition(rstore, msg, old_token, "not_delivered")
    assert [%{holder: {:fenced, ^old}}] = registry(rstore)[pane]
    assert last_status(c.inbox, msg) == {"queued", 1}
    Agent.update(agent, &%{&1 | blocked: false})
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R3 re-admission order: the replacement holds the entries only after the old child is gone",
       c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r3-ok"])
    {agent, callbacks} = recorder()
    _ = reconcile(pane, callbacks, receipt_store: rstore)
    {:ok, old} = PaneSupervisor.whereis_pane(pane)
    assert eventually(fn -> StateMachine.pending_count(old) == 1 end)
    {_state, data} = :sys.get_state(old)
    [{:receipted, _text, _ctx, msg, _at, old_token}] = :queue.to_list(data.pending_sends)
    ref = Process.monitor(old)

    # Event trace on one timeline (monotonic trace timestamps): the store's received
    # fence and issue calls, the old child's exit, and PaneSupervisor's spawn of the new child.
    sup = Process.whereis(PaneSupervisor)
    1 = :erlang.trace(rstore, true, [:receive, :monotonic_timestamp])
    1 = :erlang.trace(old, true, [:procs, :monotonic_timestamp])
    1 = :erlang.trace(sup, true, [:procs, :monotonic_timestamp])

    assert {:ok, _} =
             apply(Reconciler, :readmit, [
               pane,
               [receipt_store: rstore, callbacks: callbacks, stop_timeout_ms: 1_000]
             ])

    assert_receive {:DOWN, ^ref, :process, ^old, _}, 1_000
    assert {:ok, new} = PaneSupervisor.whereis_pane(pane)
    refute new == old
    :erlang.trace(rstore, false, [:all])
    :erlang.trace(sup, false, [:all])
    events = trace_events()

    fence_at =
      trace_at(events, rstore, :receive, &match?({:"$gen_call", _, {:fence_restore, ^pane, _}}, &1))

    down_at = trace_at(events, old, :exit, fn _ -> true end)

    issue_at =
      trace_at(events, rstore, :receive, fn
        {:"$gen_call", _, {:issue_restore_capability, ^pane, _}} -> true
        _ -> false
      end)

    start_at = trace_at(events, sup, :spawn, &(&1 == new))

    assert Enum.all?([fence_at, down_at, issue_at, start_at], &is_integer/1),
           "missing trace event: #{inspect({fence_at, down_at, issue_at, start_at})}"

    assert fence_at < down_at and down_at < issue_at and issue_at < start_at,
           "order must be fence -> old DOWN -> issue -> replacement start"

    assert eventually(fn -> StateMachine.pending_count(new) == 1 end)
    assert [%{holder: ^new}] = registry(rstore)[pane]
    assert {:error, :stale_token} = ReceiptStore.transition(rstore, msg, old_token, "not_delivered")
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R4 an unavailable receipt store refuses re-admission before any child stop or new capability",
       c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r4"])
    {agent, callbacks} = recorder()
    _ = reconcile(pane, callbacks, receipt_store: rstore)
    {:ok, old} = PaneSupervisor.whereis_pane(pane)
    assert eventually(fn -> StateMachine.pending_count(old) == 1 end)

    Process.exit(rstore, :kill)

    assert {:error, :fence_unavailable} =
             apply(Reconciler, :readmit, [pane, [receipt_store: rstore, callbacks: callbacks]])

    assert Process.alive?(old), "no child may be stopped when the fence is unavailable"
    assert {:ok, ^old} = PaneSupervisor.whereis_pane(pane)
    assert last_status(c.inbox, id("r4")) == {"queued", 1}
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R4b a live store that refuses the fence: no child stop, no issue, entries unchanged", c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r4-refused"])
    {agent, callbacks} = recorder()
    _ = reconcile(pane, callbacks, receipt_store: rstore)
    {:ok, old} = PaneSupervisor.whereis_pane(pane)
    assert eventually(fn -> StateMachine.pending_count(old) == 1 end)

    {:ok, refusing} = GenServer.start(RefusingStore, self())
    on_exit(fn -> if Process.alive?(refusing), do: Process.exit(refusing, :kill) end)

    assert {:error, :fence_unavailable} =
             apply(Reconciler, :readmit, [pane, [receipt_store: refusing, callbacks: callbacks]])

    assert_received {:refusing_store_call, {:fence_restore, ^pane, _}}
    refute_received {:refusing_store_call, {:issue_restore_capability, _, _}}
    assert Process.alive?(old), "no child may be stopped when the fence is refused"
    assert {:ok, ^old} = PaneSupervisor.whereis_pane(pane)
    assert [%{holder: ^old}] = registry(rstore)[pane], "the real store's entries are untouched"
    assert last_status(c.inbox, id("r4-refused")) == {"queued", 1}
    assert Agent.get(agent, & &1.pastes) == []
  end

  # GREEN-review row (G3 AMEND m_20261006T121051Z blocker 2).
  test "R8 a readmit whose Coordinator fence cannot be released reports fence_update_failed",
       c do
    pane = pane_id()
    own_pane(pane)
    rstore = restored_store!(c.inbox, pane, ["r8"])
    {agent, callbacks} = recorder()
    _ = reconcile(pane, callbacks, receipt_store: rstore)
    {:ok, old} = PaneSupervisor.whereis_pane(pane)
    assert eventually(fn -> StateMachine.pending_count(old) == 1 end)

    # Wedge the old child, so readmit holds the pane's fence through its bounded stop.
    Agent.update(agent, &%{&1 | blocked: true})
    assert eventually(fn -> Agent.get(agent, & &1.stuck) > 0 end)

    readmit =
      Task.async(fn ->
        apply(Reconciler, :readmit, [
          pane,
          [receipt_store: rstore, callbacks: callbacks, stop_timeout_ms: 300]
        ])
      end)

    assert eventually(fn -> match?([%{holder: {:fenced, ^old}}], registry(rstore)[pane]) end),
           "the fence was taken"

    # The Coordinator dies while the fence is held: its release cannot be recorded.
    coordinator = Process.whereis(Coordinator)
    ref = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^coordinator, _}

    assert {:error, {:fence_update_failed, {:error, :stop_timeout}, _reason}} =
             Task.await(readmit, 2_000)

    assert [%{holder: {:fenced, ^old}}] = registry(rstore)[pane]
    assert last_status(c.inbox, id("r8")) == {"queued", 1}
    Agent.update(agent, &%{&1 | blocked: false})
    assert Agent.get(agent, & &1.pastes) == []
  end

  test "R5 only the transaction holder's live worker for that pane and exact request may issue or fence",
       c do
    pane = pane_id()
    other = pane_id()
    rstore = restored_store!(c.inbox, pane, ["r5"])
    issue = {:issue_restore_capability, pane, make_ref()}
    fence = {:fence_restore, pane, make_ref()}

    # Not a Coordinator worker.
    assert {:error, :not_issuer} = GenServer.call(rstore, issue)
    assert {:error, :not_issuer} = GenServer.call(rstore, fence)

    # The holder's worker for a different pane, carrying this pane's request.
    assert {:ok, {{:ok, {:error, :not_issuer}}, {:ok, {:error, :not_issuer}}}} =
             Coordinator.transaction(other, fn ->
               {:ok,
                {Coordinator.submit(other, rstore, issue), Coordinator.submit(other, rstore, fence)}}
             end)

    # A worker submitted with no transaction holder for the pane.
    assert {:ok, {:error, :not_issuer}} = Coordinator.submit(pane, rstore, issue)

    assert [%{msg_id: msg, holder: nil}] = registry(rstore)[pane]
    assert msg == id("r5")

    # Control: the holder's worker for that pane with that exact request is accepted.
    assert {:ok, {:ok, {:ok, cap}}} =
             Coordinator.transaction(pane, fn -> {:ok, Coordinator.submit(pane, rstore, issue)} end)

    assert byte_size(cap) == 32
    assert last_status(c.inbox, msg) == {"queued", 1}

    # A store whose issuer Coordinator is not running fails closed.
    {:ok, orphan} =
      GenServer.start(ReceiptStore,
        inbox: c.inbox <> "_orphan",
        fs: SystemFs.new(),
        restore_issuer: :restore_s2_no_coordinator
      )

    on_exit(fn -> File.rm_rf!(c.inbox <> "_orphan") end)
    lone = {:issue_restore_capability, pane, make_ref()}
    assert {:error, :not_issuer} = GenServer.call(orphan, lone)

    assert {:ok, {:ok, {:error, :not_issuer}}} =
             Coordinator.transaction(pane, fn -> {:ok, Coordinator.submit(pane, orphan, lone)} end)

    Process.exit(orphan, :kill)
  end

  test "R6 authorize_effect is true only for the exact live worker, pane, target and request", c do
    pane = pane_id()
    _rstore = restored_store!(c.inbox, pane, ["r6"])
    target = held_target(self())
    request = {:issue_restore_capability, pane, make_ref()}
    holder = hold_submit(pane, target, request, :infinity)
    assert_receive {:held, ^target, ^request}
    assert [worker] = workers_for(pane)

    assert authorize(worker, pane, target, request) == true
    assert authorize(worker, pane_id(), target, request) == false
    assert authorize(worker, pane, self(), request) == false
    assert authorize(worker, pane, target, put_elem(request, 2, make_ref())) == false
    assert authorize(self(), pane, target, request) == false

    send(target, :answer)
    assert_receive {:submitted, ^pane, {:ok, :ok}}
    assert authorize(worker, pane, target, request) == false, "a settled worker is unrecorded"
    send(holder, :release)
  end

  test "R7 a live recorded worker whose caller timed out or whose transaction was abandoned has no authority",
       c do
    pane = pane_id()
    _rstore = restored_store!(c.inbox, pane, ["r7"])

    # Caller timeout: the op keeps its live worker but carries a cause.
    t1 = held_target(self())
    r1 = {:issue_restore_capability, pane, make_ref()}
    h1 = hold_submit(pane, t1, r1, 50)
    assert_receive {:held, ^t1, ^r1}
    assert_receive {:submitted, ^pane, {:error, _}}, 1_000
    assert [w1] = workers_for(pane)
    assert Process.alive?(w1)
    assert authorize(w1, pane, t1, r1) == false, "a timed-out operation keeps no authority"
    send(t1, :answer)
    send(h1, :release)

    # Abandonment: the transaction holder dies while its worker is still in flight.
    abandoned = pane_id()
    t2 = held_target(self())
    r2 = {:fence_restore, abandoned, make_ref()}
    h2 = hold_submit(abandoned, t2, r2, :infinity)
    assert_receive {:held, ^t2, ^r2}
    assert [w2] = workers_for(abandoned)
    assert authorize(w2, abandoned, t2, r2) == true, "control before abandonment"

    # Deterministic death-before-DOWN window: with the Coordinator suspended, the query is
    # queued FIRST, then the holder is killed (its DOWN queues behind the query), then the
    # Coordinator resumes and answers the query before it processes the DOWN. Only the
    # predicate's own holder-liveness check can answer false here.
    coordinator = Process.whereis(Coordinator)
    :ok = :sys.suspend(coordinator)
    query = Task.async(fn -> authorize(w2, abandoned, t2, r2) end)
    qpid = query.pid

    assert eventually(fn ->
             {:messages, queued} = Process.info(coordinator, :messages)

             Enum.any?(
               queued,
               &match?({:"$gen_call", {^qpid, _}, {:authorize_effect, _, _, _, _}}, &1)
             )
           end),
           "the query is queued before the kill"

    ref = Process.monitor(h2)
    Process.exit(h2, :kill)
    assert_receive {:DOWN, ^ref, :process, ^h2, _}
    :ok = :sys.resume(coordinator)

    assert Task.await(query) == false,
           "a dead holder's worker has no authority before its DOWN is processed"

    assert Process.alive?(w2)
    Process.sleep(50)
    assert authorize(w2, abandoned, t2, r2) == false, "nor after its DOWN is processed"
    assert workers_for(abandoned) == [w2], "the worker is still live and recorded"
    send(t2, :answer)
  end

  # ===== helpers =====

  # A target that holds one call unanswered until told, so its worker stays recorded.
  defp held_target(parent) do
    spawn(fn ->
      receive do
        {:"$gen_call", from, request} ->
          send(parent, {:held, self(), request})
          receive do: (:answer -> GenServer.reply(from, :ok))
          # Stay alive after answering, so the op settles by its reply, never by target loss.
          receive do: (:never -> :ok)
      end
    end)
  end

  # A transaction holder for `pane` that submits `request` to `target` and stays until released.
  defp hold_submit(pane, target, request, timeout) do
    parent = self()

    spawn(fn ->
      Coordinator.transaction(pane, fn ->
        send(parent, {:submitted, pane, Coordinator.submit(pane, target, request, timeout)})
        receive do: (:release -> {:ok, :released})
      end)
    end)
  end

  defp workers_for(pane) do
    {:ok, workers} = Coordinator.effect_workers()
    for {^pane, worker} <- workers, do: worker
  end

  defp authorize(worker, pane, target, request),
    do: apply(Coordinator, :authorize_effect, [Coordinator, worker, pane, target, request])

  # Queues one attempt per seed for `pane` under a real receipt store, restarts it, and asserts
  # the shared restore prerequisite (still queued after restart; ambiguous at the base).
  defp restored_store!(inbox, pane, seeds) do
    {:ok, first} =
      GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new(), restore_issuer: Coordinator)

    for seed <- seeds do
      {:ok, {:admitted, %{operation_token: token}}} =
        ReceiptStore.admit(first, id(seed), pane, hash(seed <> " bytes"), self())

      assert :ok = ReceiptStore.queue(first, id(seed), token, seed <> " bytes")
    end

    Process.exit(first, :kill)
    Process.sleep(20)

    {:ok, revived} =
      GenServer.start(ReceiptStore, inbox: inbox, fs: SystemFs.new(), restore_issuer: Coordinator)

    on_exit(fn -> if Process.alive?(revived), do: Process.exit(revived, :kill) end)

    for seed <- seeds do
      assert last_status(inbox, id(seed)) == {"queued", 1},
             "shared restore prerequisite: a queued attempt of an attested epoch stays queued"
    end

    revived
  end

  defp reconcile(pane, callbacks, overrides) do
    rows = [record(pane)]
    census = [observation(pane)]

    store =
      start_supervised!(%{
        id: {:fake_store, pane},
        start: {FakeStore, :start_link, [[lists: [{:ok, rows}, {:ok, rows}]]]},
        restart: :temporary
      })

    name = String.to_atom("fake_tmux_#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: name,
      start:
        {FakeTmux, :start_link,
         [
           [
             name: name,
             observe: [{:ok, census}, {:ok, census}],
             show: %{"$3" => [shown(), shown()]}
           ]
         ]},
      restart: :temporary
    })

    Reconciler.reconcile(
      Keyword.merge(
        [store: store, root: @root, tmux: name, binding: @binding, callbacks: callbacks],
        overrides
      )
    )
  end

  defp recorder do
    {:ok, agent} = start_supervised({Agent, fn -> %{pastes: [], blocked: false, stuck: 0} end})

    callbacks = %{
      # While `blocked` is set the child wedges here (R3's stuck child), counted in `stuck`.
      capture_fn: fn _pane ->
        if Agent.get(agent, & &1.blocked) do
          Agent.update(agent, &%{&1 | stuck: &1.stuck + 1})
          wait_unblocked(agent)
        end

        {:ok, "IDLE_MARKER"}
      end,
      paste_fn: fn pane, text ->
        Agent.update(agent, &%{&1 | pastes: [{pane, text} | &1.pastes]})
        :ok
      end
    }

    {agent, callbacks}
  end

  # Every trace message delivered so far, after a short settle for in-flight deliveries.
  defp trace_events do
    Process.sleep(50)
    drain_traces([])
  end

  defp drain_traces(acc) do
    receive do
      {:trace_ts, _pid, _kind, _a, _ts} = event -> drain_traces([event | acc])
      {:trace_ts, _pid, _kind, _a, _b, _ts} = event -> drain_traces([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The timestamp of the first `kind` event of `pid` whose first payload satisfies `match`.
  defp trace_at(events, pid, kind, match) do
    Enum.find_value(events, fn
      {:trace_ts, ^pid, ^kind, payload, ts} -> if match.(payload), do: ts
      {:trace_ts, ^pid, ^kind, payload, _mfa, ts} -> if match.(payload), do: ts
      _ -> nil
    end)
  end

  defp wait_unblocked(agent) do
    if Process.alive?(agent) and Agent.get(agent, & &1.blocked) do
      Process.sleep(10)
      wait_unblocked(agent)
    end
  end

  defp registry(store), do: apply(ReceiptStore, :restore_registry, [store])

  defp record(pane) do
    %{
      "schema_version" => "1.0",
      "pane_id" => pane,
      "agent" => "synthetic-agent",
      "classifier" => "stub",
      "project" => "synthetic-project",
      "project_dir" => @root,
      "project_inbox" => @root,
      "tmux_session" => "restore-fixture",
      "session_gen" => @generation,
      "cwd" => @root,
      "command" => "zsh",
      "pane_pid" => 4242,
      "updated_at" => "2026-09-11T00:00:00Z"
    }
  end

  defp observation(pane) do
    %{
      pane_id: pane,
      session_id: "$3",
      session_name: "restore-fixture",
      window_index: 0,
      pane_index: 0,
      pane_pid: 4242,
      command: "zsh",
      path: @root
    }
  end

  defp shown do
    marker = %{
      "version" => 1,
      "owner_root" => @root,
      "session_id" => "$3",
      "generation" => @generation
    }

    {:ok, Jason.encode!(marker) <> "\n"}
  end

  defp last_status(inbox, msg) do
    [inbox, "delivery", "receipts.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg))
    |> Enum.map(&{&1["status"], &1["delivery_attempt"]})
    |> List.last()
  end

  defp eventually(fun, deadline_ms \\ 1_000) do
    stop_at = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fun)
    |> Enum.reduce_while(false, fn ok, _ ->
      cond do
        ok -> {:halt, true}
        System.monotonic_time(:millisecond) > stop_at -> {:halt, false}
        true -> Process.sleep(10) && {:cont, false}
      end
    end)
  end

  defp pane_id, do: "%" <> Integer.to_string(System.unique_integer([:positive]))
  defp own_pane(pane), do: on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
  defp hash(text), do: Payload.hash(Payload.new(text))
  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
