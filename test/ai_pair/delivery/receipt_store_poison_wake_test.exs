defmodule AiPair.Delivery.ReceiptStorePoisonWakeTest do
  @moduledoc """
  A poisoned receipt store must wake its registered waiters with the named error.

  ADR-0003 lines 65-67: after any failed append or fsync, previously unresolved records
  cannot answer queued/pending as if finalization remained healthy, and the caller receives
  a named error. A caller that arrives after the poison already gets
  `{:error, :receipt_store_unavailable}`. A caller that was already waiting must get the
  same answer at the moment of the poison, not a pending/queued view when its own timer
  fires about 5 s later.

  Timing discipline: every waiter asks for `wait_ms: 5_000` and is collected within 2 s.
  Before the fix only the waiter's own timer could answer, at about 5 s, so an answer
  inside 2 s proves the wake and a `nil` proves the stranding. Every scenario first proves
  registration through the size of the store's `waiters` map.

  RED rows (R1-R5) fail against the unfixed store. Control rows (C1-C7) pass both before
  and after the fix, and each names what would make it fail.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Test.FaultFs

  @pane "%" <> Integer.to_string(7)
  @payload "sha256:" <> String.duplicate("a7", 32)
  @unavailable {:error, :receipt_store_unavailable}
  @wait_ms 5_000
  @wake_ms 2_000

  @owner_loss_phases [:pending, :pending_in_flight, :queued_in_flight]
  @transition_faults [:sync, :write]
  @scenarios Enum.map(@owner_loss_phases, &{:owner_loss, &1}) ++
               Enum.map(@transition_faults, &{:transition, &1}) ++ [:bystander, :admission]

  setup do
    root = Path.join(System.tmp_dir!(), "poison-wake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "RED: a poisoning failure wakes every registered waiter" do
    test "R1 owner-loss append refused: both same-id waiters get the named error", c do
      answers =
        Map.new(@owner_loss_phases, fn phase ->
          armed = arm(c, {:owner_loss, phase})
          assert poison!(armed) == :no_caller
          {phase, collect(armed.waiters)}
        end)

      assert answers == Map.new(@owner_loss_phases, &{&1, [@unavailable, @unavailable]})
    end

    test "R2 transition append refused: caller keeps its reason, waiter gets the named error",
         c do
      results =
        Map.new(@transition_faults, fn fault ->
          armed = arm(c, {:transition, fault})
          reply = poison!(armed)
          {fault, {reply, collect(armed.waiters)}}
        end)

      assert Map.new(results, fn {fault, {reply, _}} -> {fault, reply} end) == %{
               sync: {:error, {:receipt_sync_failed, :eio}},
               write: {:error, {:receipt_write_failed, :eio}}
             }

      assert Map.new(results, fn {fault, {_, answers}} -> {fault, answers} end) == %{
               sync: [@unavailable],
               write: [@unavailable]
             }
    end

    test "R3 another id's refused owner-loss append wakes a bystander waiter", c do
      armed = arm(c, :bystander)
      assert poison!(armed) == :no_caller
      assert collect(armed.waiters) == [@unavailable]
    end

    test "R4 a refused first admission wakes an existing waiter on another id", c do
      armed = arm(c, :admission)
      assert poison!(armed) == {:error, {:receipt_write_failed, :eio}}
      assert collect(armed.waiters) == [@unavailable]
    end

    test "R5 the waiter map is drained at the poisoning event", c do
      sizes =
        Map.new(@scenarios, fn scenario ->
          armed = arm(c, scenario)
          poison!(armed)
          size = map_size(:sys.get_state(armed.store).waiters)
          discard(armed.waiters)
          {scenario, size}
        end)

      assert sizes == Map.new(@scenarios, &{&1, 0})
    end
  end

  describe "controls: unchanged behaviour around the wake" do
    test "C1 healthy owner loss still wakes the waiter with durable ambiguity", c do
      {store, fs} = start_store!(c, :c1)
      owner = spawn_owner()
      id = message_id(:c1)
      admit!(store, id, owner)
      [waiter] = waiters(store, id, 1)
      syncs = FaultFs.count(fs, :sync)
      Process.exit(owner, :kill)

      assert {:ok, {:ok, %{status: "ambiguous", outcome: "ambiguous"}}} =
               Task.yield(waiter, @wake_ms) || Task.shutdown(waiter, :brutal_kill)

      assert FaultFs.count(fs, :sync) == syncs + 1
      state = :sys.get_state(store)
      refute state.poisoned
      assert map_size(state.waiters) == 0
    end

    test "C2 a healthy wait timeout still answers pending as ambiguous", c do
      {store, _fs} = start_store!(c, :c2)
      id = message_id(:c2)
      admit!(store, id, spawn_owner())
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{outcome: "ambiguous", status: "pending"}} =
               ReceiptStore.reconcile(store, id, @pane, @payload, wait_ms: 50)

      assert System.monotonic_time(:millisecond) - started >= 50
    end

    test "C3 the poison fabricates nothing: one refused append, no retry, no record", c do
      facts =
        Map.new(@scenarios, fn scenario ->
          armed = arm(c, scenario)
          path = ReceiptStore.path(armed.store)
          bytes = File.read!(path)
          log = :sys.get_state(armed.store).log
          writes = FaultFs.count(armed.fs, :write)
          syncs = FaultFs.count(armed.fs, :sync)
          poison!(armed)
          after_poison = :sys.get_state(armed.store).log
          discard(armed.waiters)
          settled = :sys.get_state(armed.store).log

          fact = %{
            writes: FaultFs.count(armed.fs, :write) - writes,
            syncs: FaultFs.count(armed.fs, :sync) - syncs,
            entries_unchanged: after_poison.entries == log.entries and settled == after_poison,
            seq_unchanged: settled.seq == log.seq,
            # A1: a refused sync follows a completed write, and FaultFs does not undo it, so
            # disk bytes are claimed unchanged only for a refused write.
            bytes_unchanged: armed.fault == :sync or File.read!(path) == bytes
          }

          {scenario, fact}
        end)

      expected =
        Map.new(@scenarios, fn scenario ->
          syncs = if scenario == {:transition, :sync}, do: 1, else: 0

          {scenario,
           %{
             writes: 1,
             syncs: syncs,
             entries_unchanged: true,
             seq_unchanged: true,
             bytes_unchanged: true
           }}
        end)

      assert facts == expected
    end

    test "C4 post-poison queries: pending is refused at once, terminal and absent still answer",
         c do
      poisoned = poisoned_by_admission!(c)
      store = poisoned.store

      for wait <- [0, @wait_ms] do
        started = System.monotonic_time(:millisecond)

        assert ReceiptStore.reconcile(store, poisoned.pending, @pane, @payload, wait_ms: wait) ==
                 @unavailable

        assert System.monotonic_time(:millisecond) - started < 100
        assert map_size(:sys.get_state(store).waiters) == 0
      end

      assert {:ok, %{outcome: "delivered"}} =
               ReceiptStore.reconcile(store, poisoned.delivered, @pane, @payload)

      assert {:ok, %{outcome: "absent"}} =
               ReceiptStore.reconcile(store, poisoned.refused, @pane, @payload)
    end

    test "C5 later mutations are refused and write nothing", c do
      poisoned = poisoned_by_admission!(c)
      store = poisoned.store
      writes = FaultFs.count(poisoned.fs, :write)

      assert ReceiptStore.admit(store, message_id(:c5_fresh), @pane, @payload, spawn_owner()) ==
               @unavailable

      assert ReceiptStore.transition(store, poisoned.pending, poisoned.token, "delivered") ==
               @unavailable

      assert ReceiptStore.begin_paste(store, poisoned.pending, poisoned.token) == @unavailable
      assert FaultFs.count(poisoned.fs, :write) == writes
    end

    test "C6 a waiter that died before the poison is harmless", c do
      {store, fs} = start_store!(c, :c6)
      owner = spawn_owner()
      id = message_id(:c6)
      admit!(store, id, owner)
      [doomed, survivor] = waiters(store, id, 2)

      :ok = :sys.suspend(store)
      inject_next(fs, :write)
      kill_and_await(owner)
      Task.shutdown(doomed, :brutal_kill)
      wait_until(fn -> Process.info(store, :message_queue_len) == {:message_queue_len, 2} end)
      :ok = :sys.resume(store)

      wait_until(fn -> :sys.get_state(store).poisoned end)
      assert Process.alive?(store)
      # The survivor is answered either way: by the wake after the fix, by its own timer
      # before it. This row pins only that the dead waiter crashed nothing.
      assert {:ok, _answer} = Task.yield(survivor, @wait_ms + 1_000)
      assert Process.alive?(store)
      assert map_size(:sys.get_state(store).waiters) == 0
    end

    test "C7 late timer harmless: an expiry queued behind the poison crashes nothing", c do
      {store, fs} = start_store!(c, :c7)
      owner = spawn_owner()
      id = message_id(:c7)
      admit!(store, id, owner)
      [waiter] = waiters(store, id, 1, 200)
      writes = FaultFs.count(fs, :write)

      :ok = :sys.suspend(store)
      inject_next(fs, :write)
      kill_and_await(owner)
      # The waiter's own timer fires into the suspended mailbox behind the owner DOWN.
      Process.sleep(300)
      wait_until(fn -> Process.info(store, :message_queue_len) == {:message_queue_len, 2} end)
      :ok = :sys.resume(store)

      assert {:ok, _answer} = Task.yield(waiter, @wake_ms)
      state = :sys.get_state(store)
      assert state.poisoned
      assert map_size(state.waiters) == 0
      assert Process.alive?(store)
      assert FaultFs.count(fs, :write) == writes + 1
    end
  end

  # ----- scenarios -----

  # Every scenario registers its waiters, injects exactly one fault on the next append, and
  # returns a trigger that makes that append happen.
  defp arm(c, {:owner_loss, phase} = scenario) do
    {store, fs} = start_store!(c, scenario)
    owner = spawn_owner()
    id = message_id(scenario)
    admission = admit!(store, id, owner)

    if phase == :queued_in_flight,
      do: :ok = ReceiptStore.transition(store, id, admission.operation_token, "queued")

    if phase in [:pending_in_flight, :queued_in_flight],
      do: :ok = ReceiptStore.begin_paste(store, id, admission.operation_token)

    tasks = waiters(store, id, 2)
    inject_next(fs, :write)
    armed(store, fs, tasks, :write, fn -> owner_loss(owner) end)
  end

  defp arm(c, {:transition, fault} = scenario) do
    {store, fs} = start_store!(c, scenario)
    id = message_id(scenario)
    admission = admit!(store, id, spawn_owner())
    :ok = ReceiptStore.begin_paste(store, id, admission.operation_token)
    tasks = waiters(store, id, 1)
    inject_next(fs, fault)

    armed(store, fs, tasks, fault, fn ->
      ReceiptStore.transition(store, id, admission.operation_token, "delivered")
    end)
  end

  defp arm(c, :bystander) do
    {store, fs} = start_store!(c, :bystander)
    owner = spawn_owner()
    admit!(store, message_id(:bystander_a), owner)
    bystander = message_id(:bystander_b)
    admit!(store, bystander, spawn_owner())
    tasks = waiters(store, bystander, 1)
    inject_next(fs, :write)
    armed(store, fs, tasks, :write, fn -> owner_loss(owner) end)
  end

  defp arm(c, :admission) do
    {store, fs} = start_store!(c, :admission)
    existing = message_id(:admission_b)
    admit!(store, existing, spawn_owner())
    tasks = waiters(store, existing, 1)
    inject_next(fs, :write)

    armed(store, fs, tasks, :write, fn ->
      ReceiptStore.admit(store, message_id(:admission_c), @pane, @payload, spawn_owner())
    end)
  end

  defp armed(store, fs, tasks, fault, trigger),
    do: %{store: store, fs: fs, waiters: tasks, fault: fault, trigger: trigger}

  # Runs the trigger and returns only once the store has handled the poisoning event.
  defp poison!(armed) do
    reply = armed.trigger.()
    wait_until(fn -> :sys.get_state(armed.store).poisoned end)
    reply
  end

  defp owner_loss(owner) do
    Process.exit(owner, :kill)
    :no_caller
  end

  # A store with one delivered id, one pending id with a live owner and no waiter, and a
  # refused first admission that poisoned it.
  defp poisoned_by_admission!(c) do
    {store, fs} = start_store!(c, :poisoned_by_admission)
    delivered = message_id(:delivered)
    done = admit!(store, delivered, spawn_owner())
    :ok = ReceiptStore.transition(store, delivered, done.operation_token, "delivered")
    pending = message_id(:pending)
    open = admit!(store, pending, spawn_owner())
    refused = message_id(:refused)
    inject_next(fs, :write)

    assert ReceiptStore.admit(store, refused, @pane, @payload, spawn_owner()) ==
             {:error, {:receipt_write_failed, :eio}}

    assert :sys.get_state(store).poisoned

    %{
      store: store,
      fs: fs,
      delivered: delivered,
      pending: pending,
      token: open.operation_token,
      refused: refused
    }
  end

  # ----- helpers -----

  defp start_store!(c, name) do
    inbox = Path.join(c.root, Base.encode16(:erlang.term_to_binary(name), case: :lower))
    File.mkdir_p!(inbox)
    fs = FaultFs.new()

    store =
      start_supervised!(
        Supervisor.child_spec({ReceiptStore, inbox: inbox, fs: fs},
          id: {ReceiptStore, name},
          restart: :temporary
        )
      )

    {store, fs}
  end

  defp inject_next(fs, op), do: FaultFs.inject(fs, op, FaultFs.count(fs, op) + 1, {:error, :eio})

  defp admit!(store, id, owner) do
    {:ok, {:admitted, admission}} = ReceiptStore.admit(store, id, @pane, @payload, owner)
    admission
  end

  defp waiters(store, id, n, wait \\ @wait_ms) do
    before = map_size(:sys.get_state(store).waiters)

    tasks =
      for _ <- 1..n do
        Task.async(fn -> ReceiptStore.reconcile(store, id, @pane, @payload, wait_ms: wait) end)
      end

    wait_until(fn -> map_size(:sys.get_state(store).waiters) == before + n end)
    tasks
  end

  # Replies arriving within the wake bound; `nil` marks a waiter left stranded.
  defp collect(tasks) do
    tasks
    |> Task.yield_many(@wake_ms)
    |> Enum.map(fn {task, result} ->
      case result || Task.shutdown(task, :brutal_kill) do
        {:ok, reply} -> reply
        other -> other
      end
    end)
  end

  defp discard(tasks) do
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
  end

  defp message_id(name) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(name))
    "snd_" <> Base.encode16(digest, case: :lower)
  end

  defp spawn_owner do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
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

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        true
      else
        Process.sleep(5)
        false
      end
    end)
    |> Enum.find(fn ready -> ready or System.monotonic_time(:millisecond) > deadline end)
    |> case do
      true -> :ok
      _ -> flunk("condition did not hold within #{timeout}ms")
    end
  end
end
