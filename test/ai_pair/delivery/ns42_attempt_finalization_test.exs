defmodule AiPair.Delivery.NS42AttemptFinalizationTest do
  @moduledoc """
  NS-42.C.009, producer side: finalization is owned by the attempt.

  Two controls were left open by review. This file maps each to the documented clause
  and asserts the documented outcome; it changes no product source.

  Pending consumer (a consumer waits while the attempt is unresolved and the owner dies):

    * ADR-0003 "Ownership and Recovery": the store "monitors the actual delivery
      operation owner, not the requesting connection. Owner loss makes a pending or
      queued attempt durably ambiguous."
    * ADR-0003 "Ownership and Recovery": "A pending live operation may be waited for up
      to 5 seconds. Timeout does not append a fabricated outcome: the query answers
      ambiguous. [...] The caller disappearing cancels its wait, not the operation it
      was querying."
    * ADR-0003 "Crossing the Paste Boundary": "owner loss wakes waiters with durably
      recorded ambiguity."
    * ADR-0003 "Ownership and Recovery": "Any failed append or fsync stops further
      mutations in that process. Previously unresolved records cannot then answer
      queued/pending as if finalization remained healthy."

  Recovery append (a crash between paste authorization and finalization):

    * ADR-0003 "Ownership and Recovery": "Restart likewise appends ambiguity for every
      unresolved prior-epoch attempt before accepting new calls."
    * ADR-0003 "Crossing the Paste Boundary": `begin_paste/3` "does not append a new
      durable status: the existing pending/queued record already makes a crash
      ambiguous."
    * ADR-0004 "Authority and Ordering": "Store restart recovers unresolved records as
      ambiguous; old operation tokens cannot authorize a paste in the new epoch."

  Already asserted elsewhere, and not repeated here: a queued in-flight waiter woken by
  owner loss (`paste_window_test.exs`), a queued send left by a crash
  (`queued_send_loss_test.exs`), and owner death after a terminal or superseded attempt
  (`ns42_producer_conformance_test.exs`, rule 9).
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.Pane.StateMachine
  alias AiPair.Test.{FaultFs, MarkerClassifier}

  @pane "%ns42_c009"
  @payload "sha256:" <> String.duplicate("c9", 32)
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)
  @text "ns42 c009 direct paste"

  setup do
    inbox = Path.join(System.tmp_dir!(), "ns42_c009_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  describe "(a) a consumer waiting on an unresolved attempt when its owner dies" do
    for phase <- [:pending, :pending_in_flight, :queued_in_flight] do
      test "#{phase}: every waiter is woken with durable ambiguity, and only for its id",
           %{inbox: inbox} do
        phase = unquote(phase)
        fs = FaultFs.new()
        store = start_store!(inbox, :store, fs: fs)
        id = message_id("wake-#{phase}")
        other = message_id("bystander-#{phase}")
        owner = spawn_owner()
        token = open_attempt!(store, id, owner, phase)
        other_token = admit!(store, other, spawn_owner()).operation_token

        waiters = for _ <- 1..2, do: wait_async(store, id, 5_000)
        bystander = wait_async(store, other, 5_000)

        # Every wait is registered before the owner dies, so each answer below is a
        # wake and not an immediate read of an already-resolved record.
        await_waiters(store, 3)
        syncs = FaultFs.count(fs, :sync)
        kill_and_await(owner)

        # The wait bound is 5 s; a 2 s await proves the answer is the wake.
        for waiter <- waiters do
          assert {:ok, reply} = Task.await(waiter, 2_000)
          assert reply.outcome == "ambiguous"
          assert reply.status == "ambiguous"
          assert reply.delivery_attempt == 1
        end

        assert FaultFs.count(fs, :sync) == syncs + 1,
               "exactly one fsynced append records the owner loss"

        path = ReceiptStore.path(store)
        assert List.last(statuses(path, id)) == {1, "ambiguous"}
        assert last_record(path)["daemon_epoch"] == ReceiptStore.daemon_epoch(store)

        assert Task.yield(bystander, 100) == nil,
               "another id's owner death must neither wake nor resolve this waiter"

        assert :ok = ReceiptStore.transition(store, other, other_token, "delivered")
        assert {:ok, %{outcome: "delivered"}} = Task.await(bystander, 2_000)

        before = File.read!(path)

        assert ReceiptStore.transition(store, id, token, "delivered") ==
                 {:error, {:illegal_transition, "ambiguous", "delivered"}},
               "the dead owner's attempt is closed; a late claim cannot reopen it"

        assert File.read!(path) == before
      end
    end

    test "a waiter that dies cancels its own wait, never the attempt", %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("waiter-dies")
      token = admit!(store, id, spawn_owner()).operation_token
      path = ReceiptStore.path(store)
      before = File.read!(path)

      consumer = spawn(fn -> reconcile(store, id, 5_000) end)
      on_exit(fn -> if Process.alive?(consumer), do: Process.exit(consumer, :kill) end)
      await_waiters(store, 1)
      kill_and_await(consumer)
      await_waiters(store, 0)

      assert File.read!(path) == before, "a consumer's death is not the owner's death"

      assert :ok = ReceiptStore.transition(store, id, token, "delivered")
      assert {:ok, %{outcome: "delivered"}} = reconcile(store, id, 0)
    end

    test "an owner loss that cannot be persisted answers ambiguous and poisons the store",
         %{inbox: inbox} do
      fs = FaultFs.new()
      store = start_store!(inbox, :store, fs: fs)
      id = message_id("unpersisted-loss")
      owner = spawn_owner()
      admit!(store, id, owner)
      path = ReceiptStore.path(store)
      before = File.read!(path)

      # The next write is the ambiguity append for the owner loss; it is refused.
      FaultFs.inject(fs, :write, FaultFs.count(fs, :write) + 1, {:error, :eio})

      waiter = wait_async(store, id, 300)
      await_waiters(store, 1)
      kill_and_await(owner)

      assert {:ok, reply} = Task.await(waiter, 2_000)

      assert reply.outcome == "ambiguous",
             "an unrecorded owner loss is still unproven delivery, never absence"

      assert File.read!(path) == before, "no outcome is fabricated behind a failed append"

      assert {:error, :receipt_store_unavailable} = reconcile(store, id, 0),
             "an unresolved record must not keep answering as if finalization were healthy"

      assert {:error, :receipt_store_unavailable} =
               ReceiptStore.admit(store, message_id("after-poison"), @pane, @payload, self())
    end
  end

  describe "(b) a crash between paste authorization and finalization" do
    test "restart appends one ambiguity per unresolved attempt before serving any call",
         %{inbox: inbox} do
      store = start_store!(inbox, :first)
      path = ReceiptStore.path(store)
      old_epoch = ReceiptStore.daemon_epoch(store)
      owner = spawn_owner()

      pasted = message_id("recover-pasted")
      queued = message_id("recover-queued")
      waiting = message_id("recover-waiting")
      delivered = message_id("recover-delivered")
      refused = message_id("recover-refused")

      # seq 1: pending, then the paste boundary is crossed.
      pasted_token = admit!(store, pasted, owner).operation_token
      assert :ok = ReceiptStore.begin_paste(store, pasted, pasted_token)

      # seq 2-3: pending, queued, then the paste boundary is crossed.
      queued_token = admit!(store, queued, owner).operation_token
      assert :ok = ReceiptStore.transition(store, queued, queued_token, "queued")
      assert :ok = ReceiptStore.begin_paste(store, queued, queued_token)

      # seq 4: pending, paste not yet authorized.
      waiting_token = admit!(store, waiting, owner).operation_token

      # seq 5-8: two attempts that were finalized before the crash.
      delivered_token = admit!(store, delivered, owner).operation_token
      assert :ok = ReceiptStore.transition(store, delivered, delivered_token, "delivered")
      refused_token = admit!(store, refused, owner).operation_token
      assert :ok = ReceiptStore.transition(store, refused, refused_token, "not_delivered")

      assert length(lines(path)) == 8,
             "begin_paste appends nothing: the pending or queued record is the crash evidence"

      crash!(store)
      before = File.read!(path)

      revived = start_store!(inbox, :second)

      # Read before ANY call to the revived store: recovery is part of initialization.
      after_recovery = File.read!(path)
      assert String.starts_with?(after_recovery, before), "recovery only appends"
      tail_size = byte_size(after_recovery) - byte_size(before)
      appended = split_lines(binary_part(after_recovery, byte_size(before), tail_size))
      recovered_ids = Enum.map(appended, fn line -> decode_line!(line)["message_id"] end)

      assert recovered_ids == [pasted, queued, waiting],
             "one append per unresolved attempt, in log order, and none for a finalized one"

      new_epoch = ReceiptStore.daemon_epoch(revived)
      refute new_epoch == old_epoch

      for {line, seq} <- Enum.zip(appended, 9..11) do
        record = decode_line!(line)
        assert record["status"] == "ambiguous"
        assert record["seq"] == seq
        assert record["delivery_attempt"] == 1
        assert record["pane_id"] == @pane
        assert record["payload_hash"] == @payload

        assert record["daemon_epoch"] == new_epoch,
               "the recovery record is written by the epoch that recovered it"
      end

      assert_chain!(lines(path))

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(revived, pasted, 0)
      assert {:ok, %{outcome: "ambiguous"}} = reconcile(revived, queued, 0)
      assert {:ok, %{outcome: "ambiguous"}} = reconcile(revived, waiting, 0)
      assert {:ok, %{outcome: "delivered"}} = reconcile(revived, delivered, 0)
      assert {:ok, %{outcome: "absent"}} = reconcile(revived, refused, 0)

      # Old tokens have no authority in the new epoch, whichever entry point they reach.
      recovered = File.read!(path)

      assert ReceiptStore.begin_paste(revived, waiting, waiting_token) ==
               {:error, {:foreign_operation_token, waiting}}

      for {id, token} <- [{pasted, pasted_token}, {queued, queued_token}] do
        assert ReceiptStore.transition(revived, id, token, "delivered") ==
                 {:error, {:foreign_operation_token, id}}
      end

      assert ReceiptStore.transition(revived, waiting, waiting_token, "not_delivered") ==
               {:error, {:foreign_operation_token, waiting}}

      assert File.read!(path) == recovered

      # A crossed epoch is recovered once. A second crash has nothing left to recover.
      crash!(revived)
      third = start_store!(inbox, :third)
      assert File.read!(path) == recovered

      assert {:ok, {:duplicate, %{status: "ambiguous", delivery_attempt: 1}}} =
               ReceiptStore.admit(third, pasted, @pane, @payload, spawn_owner()),
             "a recovered ambiguity is not retryable"
    end

    test "control: a restart with nothing unresolved appends nothing", %{inbox: inbox} do
      store = start_store!(inbox, :first)
      path = ReceiptStore.path(store)
      id = message_id("control-resolved")
      token = admit!(store, id).operation_token
      assert :ok = ReceiptStore.transition(store, id, token, "delivered")
      crash!(store)
      before = File.read!(path)

      _revived = start_store!(inbox, :second)
      assert File.read!(path) == before
    end

    test "a recovery append that fails refuses the store rather than serving the log",
         %{inbox: inbox} do
      store = start_store!(inbox, :first)
      path = ReceiptStore.path(store)
      id = message_id("recover-fails")
      token = admit!(store, id).operation_token
      assert :ok = ReceiptStore.begin_paste(store, id, token)
      crash!(store)
      before = File.read!(path)

      # Initialization writes nothing before the recovery append, so it is write 1.
      fs = FaultFs.new()
      FaultFs.inject(fs, :write, 1, {:error, :eio})

      assert {:error, reason} = start_store(inbox, :failed, fs: fs)
      assert inspect(reason) =~ "receipt_write_failed"
      assert File.read!(path) == before

      revived = start_store!(inbox, :second)
      assert statuses(path, id) == [{1, "pending"}, {1, "ambiguous"}]
      assert {:ok, %{outcome: "ambiguous"}} = reconcile(revived, id, 0)
    end

    test "a direct paste cut off by a daemon crash is recovered ambiguous, not re-pasted",
         %{inbox: inbox} do
      store = start_store!(inbox, :first)
      parent = self()
      {:ok, pastes} = Agent.start_link(fn -> 0 end)

      # The paste reaches the pane and never returns, so finalization never happens.
      paste_fn = fn _pane_id, _text ->
        Agent.update(pastes, &(&1 + 1))
        send(parent, :paste_entered)
        Process.sleep(:infinity)
      end

      sm = start_idle_pane!(store, paste_fn)
      id = message_id("direct-paste-crash")
      hash = Payload.hash(Payload.new(@text))

      caller = spawn(fn -> StateMachine.send_receipted(sm, @text, 10_000, id, store) end)
      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

      assert_receive :paste_entered, 2_000
      path = ReceiptStore.path(store)
      assert statuses(path, id) == [{1, "pending"}]

      crash!(store)
      revived = start_store!(inbox, :second)

      assert statuses(path, id) == [{1, "pending"}, {1, "ambiguous"}]

      assert {:ok, %{outcome: "ambiguous", delivery_attempt: 1}} =
               ReceiptStore.reconcile(revived, id, @pane, hash, wait_ms: 0)

      assert Agent.get(pastes, & &1) == 1, "recovery never re-pastes"
    end
  end

  # ===== helpers =====

  defp open_attempt!(store, id, owner, :pending), do: admit!(store, id, owner).operation_token

  defp open_attempt!(store, id, owner, :pending_in_flight) do
    token = admit!(store, id, owner).operation_token
    assert :ok = ReceiptStore.begin_paste(store, id, token)
    token
  end

  defp open_attempt!(store, id, owner, :queued_in_flight) do
    token = admit!(store, id, owner).operation_token
    assert :ok = ReceiptStore.transition(store, id, token, "queued")
    assert :ok = ReceiptStore.begin_paste(store, id, token)
    token
  end

  defp wait_async(store, id, wait_ms), do: Task.async(fn -> reconcile(store, id, wait_ms) end)

  # Test-only observation of the store's registered waiters, so a row can prove the
  # wait was in place before the event it waits for.
  defp await_waiters(store, count) do
    wait_until(fn -> map_size(:sys.get_state(store).waiters) == count end)
  end

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
    |> case do
      :ok -> :ok
      :timeout -> flunk("condition did not hold within #{timeout}ms")
    end
  end

  defp start_store!(inbox, id \\ :store, opts \\ []) do
    {:ok, pid} = start_store(inbox, id, opts)
    pid
  end

  defp start_store(inbox, id, opts) do
    start_supervised(
      Supervisor.child_spec({ReceiptStore, [inbox: inbox] ++ opts}, id: id, restart: :temporary)
    )
  end

  # A crash, not a shutdown: a graceful stop could do work a lost daemon never would.
  defp crash!(store) do
    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store, :killed}, 1_000
  end

  defp admit!(store, id, owner \\ nil) do
    {:ok, {:admitted, admission}} =
      ReceiptStore.admit(store, id, @pane, @payload, owner || self())

    admission
  end

  defp reconcile(store, id, wait_ms),
    do: ReceiptStore.reconcile(store, id, @pane, @payload, wait_ms: wait_ms)

  defp statuses(path, id) do
    path
    |> lines()
    |> Enum.map(&decode_line!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  defp last_record(path), do: path |> lines() |> List.last() |> decode_line!()

  defp lines(path), do: path |> File.read!() |> split_lines()

  defp split_lines(bytes), do: String.split(bytes, ~r/(?<=\n)/, trim: true)

  defp decode_line!(line), do: line |> String.trim_trailing("\n") |> Jason.decode!()

  defp assert_chain!(lines) do
    Enum.reduce(lines, @anchor, fn line, expected_prev ->
      assert decode_line!(line)["prev_line_sha256"] == expected_prev
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)
    end)
  end

  defp message_id(seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

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

  defp start_idle_pane!(store, paste_fn) do
    {:ok, sm} =
      StateMachine.start_link(
        pane_id: @pane,
        receipt_store: store,
        capture_fn: fn _pane_id -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn,
        classifier: MarkerClassifier,
        poll_interval_ms: 10,
        idle_debounce_ms: 0
      )

    # The pane is parked inside a paste that never returns, so it cannot be stopped
    # politely; it is killed, and the test process is unlinked from it first.
    Process.unlink(sm)
    on_exit(fn -> if Process.alive?(sm), do: Process.exit(sm, :kill) end)
    assert :ok = await_state(sm, :idle)
    sm
  end

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
