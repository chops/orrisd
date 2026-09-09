defmodule AiPair.Delivery.QueuedSendLossTest do
  @moduledoc """
  Regression rows for the product bug behind `queued` vs `delivered`.

  The bug: when a send is parked in the pane queue and its later paste fails,
  `drain_queue/2` logs a warning and drops it. The caller already received
  `{:queued, reason}` and is never told the bytes did not land, so the loss is silent on
  both sides of the seam.

  Resolving that loss to `absent` would be wrong and dangerous.
  `default_paste/2` collapses `set_buffer -> paste_buffer -> send_keys Enter` behind one
  `with`, so a `paste_failed` can be raised **after** bytes have already reached the pane.
  Absence is therefore not proven. Only a failure proven before any paste attempt --
  a dead pane, a full queue, a validation refusal -- may record `not_delivered` and read
  as `absent`. Everything else is `ambiguous`.

  A further rule is that `queued` is not terminal: a queued send must converge to
  `delivered | not_delivered | ambiguous`, and this file waits for that convergence on a
  `ReceiptStore` subscription rather than on a blind `Process.sleep/1`.

  These tests assert on the durable receipt outcome rather than on which internal path
  produced it, because the contract under test is what a later reconciliation is allowed
  to conclude.

  Further rules:

    * A duplicate is a typed receipt view, not a bare status string. No caller parses
      `"pending"` out of a tuple, and the pane must treat a duplicate exactly as it treats
      reconciliation.
    * `observe/2` is a test-only observation hook, not a product API; reconciliation owns
      waiter registration.
    * Statuses are terminal per physical attempt. A send proven never to have reached
      the pane may be retried under the same id as a new `delivery_attempt`, and the pane
      must actually paste that retry.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Pane.StateMachine
  alias AiPair.Test.MarkerClassifier

  @pane "%test"
  @prompt "queued prompt"
  @msg_a "snd_" <> String.duplicate("a1", 32)
  @msg_b "snd_" <> String.duplicate("b2", 32)

  setup do
    inbox = Path.join(System.tmp_dir!(), "ai_pair_drain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})
    {:ok, inbox: inbox, store: store}
  end

  describe "a paste that may have landed is never reported as absence" do
    test "a queued send dropped during drain is ambiguous", ctx do
      {sm, pane} = start_pane(ctx, paste_fn: fn _pane, _text -> {:error, :paste_failed} end)

      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)

      assert_receive {:receipt_finalized, @msg_a, "ambiguous"}, 2_000

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(ctx, @msg_a),
             "the paste may have landed before it failed, so the loss is ambiguous, not absent"
    end

    test "a direct paste failure is ambiguous", ctx do
      {sm, pane} = start_pane(ctx, paste_fn: fn _pane, _text -> {:error, :enoent} end)

      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      _ = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)

      assert_receive {:receipt_finalized, @msg_a, "ambiguous"},
                     2_000,
                     "set-buffer, paste-buffer and send-keys hide behind one result, so a" <>
                       " failure does not prove the pane is clean"
    end

    test "a queued send that later pastes cleanly converges to delivered", ctx do
      {sm, pane} = start_pane(ctx)

      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)

      assert_receive {:receipt_finalized, @msg_a, "delivered"}, 2_000

      assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}, {1, "delivered"}],
             "queued is a waypoint that must converge, not a terminal state"

      assert {:ok, %{outcome: "delivered"}} = reconcile(ctx, @msg_a)
    end
  end

  describe "only a failure proven before the paste may read as absent" do
    test "failed dead-queue finalization cannot claim durable absence", ctx do
      alias AiPair.Test.FaultFs
      fs = FaultFs.new()
      inbox = Path.join(ctx.inbox, "fault")
      File.mkdir_p!(inbox)

      store =
        start_supervised!(%{
          id: :fault_store,
          start: {ReceiptStore, :start_link, [[inbox: inbox, fs: fs]]}
        })

      ctx = %{ctx | store: store}
      owner = self()

      {sm, _pane} =
        start_pane(ctx,
          paste_fn: fn _, _ ->
            send(owner, :unexpected_paste)
            :ok
          end
        )

      assert match?({:queued, _}, StateMachine.send_text(sm, @prompt, 1_000, @msg_a))
      :ok = ReceiptStore.observe(store, @msg_a)
      FaultFs.inject(fs, :sync, FaultFs.count(fs, :sync) + 1, {:error, :eio})
      StateMachine.mark_dead(sm)
      assert StateMachine.state(sm) == :dead
      assert StateMachine.pending_count(sm) == 0
      assert {:error, :receipt_store_unavailable} = reconcile(ctx, @msg_a)
      refute_received {:receipt_finalized, @msg_a, "not_delivered"}
      refute_received :unexpected_paste
    end

    for cause <- [:explicit, :reaped] do
      test "an already queued send is finalized before paste when the pane dies: #{cause}", ctx do
        cause = unquote(cause)
        owner = self()
        {:ok, capture} = Agent.start_link(fn -> {:ok, "BUSY_MARKER"} end)

        {sm, _pane} =
          start_pane(ctx,
            capture_fn: fn _ -> Agent.get(capture, & &1) end,
            paste_fn: fn _, _ ->
              send(owner, :unexpected_paste)
              :ok
            end,
            pane_gone_threshold: 1,
            pane_gone_grace_ms: 0
          )

        :ok = ReceiptStore.observe(ctx.store, @msg_a)
        assert match?({:queued, _}, StateMachine.send_text(sm, @prompt, 1_000, @msg_a))

        kill_pane(cause, sm, capture)

        assert_receive {:receipt_finalized, @msg_a, "not_delivered"}, 1_000
        assert StateMachine.state(sm) == :dead
        assert StateMachine.pending_count(sm) == 0
        assert {:ok, %{outcome: "absent", delivery_attempt: 1}} = reconcile(ctx, @msg_a)
        assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}, {1, "not_delivered"}]
        refute_received :unexpected_paste
      end
    end

    test "a dead pane records a pre-paste non-delivery", ctx do
      {sm, _pane} = start_pane(ctx)
      :ok = StateMachine.mark_dead(sm)

      assert {:error, :pane_dead} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)

      assert {:ok, %{outcome: "absent"}} = reconcile(ctx, @msg_a),
             "nothing was pasted, so the daemon can prove the pane never saw these bytes"

      assert statuses(ctx, @msg_a) |> List.last() == {1, "not_delivered"}
    end

    test "a rejected send on a full queue records a pre-paste non-delivery", ctx do
      {sm, _pane} = start_pane(ctx)

      for n <- 1..32 do
        assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, message_id(n))
      end

      assert {:error, {:queue_full, 32}} = StateMachine.send_text(sm, @prompt, 1_000, @msg_b)

      assert {:ok, %{outcome: "absent"}} = reconcile(ctx, @msg_b),
             "a queue rejection happens before any paste attempt, so absence is provable"
    end

    test "a proven non-delivery may be sent again under the same id", ctx do
      {:ok, pastes} = Agent.start_link(fn -> 0 end)

      paste_fn = fn _pane, _text ->
        Agent.update(pastes, &(&1 + 1))
        :ok
      end

      {dead_sm, _dead_pane} = start_pane(ctx, paste_fn: paste_fn)
      :ok = StateMachine.mark_dead(dead_sm)
      assert {:error, :pane_dead} = StateMachine.send_text(dead_sm, @prompt, 1_000, @msg_a)
      assert {:ok, %{outcome: "absent"}} = reconcile(ctx, @msg_a)

      # A send id is a pure function of run and assignment, so the retry presents the very
      # same id. Attempt 1 is closed and immutable; attempt 2 is what actually pastes.
      {live_sm, live_pane} = start_pane(ctx, paste_fn: paste_fn)
      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(live_sm, @prompt, 1_000, @msg_a)
      go_idle(live_pane)

      assert_receive {:receipt_finalized, @msg_a, "delivered"}, 2_000

      assert statuses(ctx, @msg_a) == [
               {1, "pending"},
               {1, "not_delivered"},
               {2, "pending"},
               {2, "queued"},
               {2, "delivered"}
             ],
             "the closed attempt is kept, and only the new attempt reaches the pane"

      assert Agent.get(pastes, & &1) == 1
      assert {:ok, %{outcome: "delivered", delivery_attempt: 2}} = reconcile(ctx, @msg_a)
    end

    test "an ambiguous send is never retried by the pane", ctx do
      {sm, pane} = start_pane(ctx, paste_fn: fn _pane, _text -> {:error, :paste_failed} end)

      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)
      assert_receive {:receipt_finalized, @msg_a, "ambiguous"}, 2_000

      assert {:duplicate, %{status: "ambiguous", delivery_attempt: 1}} =
               StateMachine.send_text(sm, @prompt, 1_000, @msg_a),
             "bytes may already have reached the pane, and may is not no"
    end
  end

  describe "the pane never pastes the same message twice" do
    test "a duplicate send observing pending is answered from the receipt", ctx do
      {:ok, pastes} = Agent.start_link(fn -> 0 end)

      paste_fn = fn _pane, _text ->
        Agent.update(pastes, &(&1 + 1))
        :ok
      end

      {sm, pane} = start_pane(ctx, paste_fn: paste_fn)

      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)

      assert {:duplicate, %{status: "queued", delivery_attempt: 1, message_id: @msg_a}} =
               StateMachine.send_text(sm, @prompt, 1_000, @msg_a),
             """
             D5: the second send is answered from the receipt, never enqueued a second time.
             The first send already returned {:queued, _}, so the durable status the view
             reports is `queued`: `pending` would describe an admission that has not yet
             been recorded, and MUST-5 makes the queued waypoint durable before the reply.
             """

      go_idle(pane)
      assert_receive {:receipt_finalized, @msg_a, "delivered"}, 2_000

      assert Agent.get(pastes, & &1) == 1
    end
  end

  describe "a caller timeout does not resolve the send" do
    test "reconciliation is ambiguous while a live pane still owns the paste", ctx do
      test_pid = self()

      paste_fn = fn _pane, _text ->
        send(test_pid, :paste_entered)
        receive do: (:release -> :ok)
      end

      {sm, pane} = start_pane(ctx, paste_fn: paste_fn)
      go_idle(pane)

      # The pane parks the send until it is idle-stable, so the paste begins on drain.
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      assert_receive :paste_entered, 2_000

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(ctx, @msg_a, wait_ms: 50),
             "a bounded wait on a live owner that has not finalized expires as ambiguous"

      send(sm, :release)

      assert {:ok, %{outcome: "delivered"}} = reconcile(ctx, @msg_a, wait_ms: 2_000),
             "the same waiter, woken by finalization, sees the real outcome"
    end
  end

  describe "a daemon restart resolves a queued send without resending it" do
    test "a send left queued by a crash is ambiguous, not retried", ctx do
      {:ok, pastes} = Agent.start_link(fn -> 0 end)
      parent = self()

      paste_fn = fn _pane, _text ->
        Agent.update(pastes, &(&1 + 1))
        send(parent, :paste_entered)
        Process.sleep(:infinity)
      end

      {sm, pane} = start_pane(ctx, paste_fn: paste_fn)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)

      # The paste is under way and durably recorded as queued. Nothing has answered yet.
      assert_receive :paste_entered, 2_000
      assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}]
      assert Agent.get(pastes, & &1) == 1

      revived = restart_store!(ctx)
      ctx = %{ctx | store: revived}

      # The operation that owned this send died with the daemon that minted its epoch.
      # There is no owner left to wait for, so the deadline is already past on arrival and
      # the answer is available without a wait.
      assert {:ok, %{outcome: "ambiguous", delivery_attempt: 1}} =
               ReceiptStore.reconcile(revived, @msg_a, @pane, payload_hash(@prompt), wait_ms: 0)

      assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}, {1, "ambiguous"}],
             "the crossed epoch is finalized once, durably, rather than re-derived per query"

      assert {:ok, %{outcome: "ambiguous", delivery_attempt: 1}} =
               ReceiptStore.reconcile(revived, @msg_a, @pane, payload_hash(@prompt), wait_ms: 0)

      assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}, {1, "ambiguous"}],
             "reconciliation is a query, so repeating it must not grow the evidence log"

      {resumed_sm, _pane} = start_pane(%{ctx | store: revived}, paste_fn: paste_fn)

      assert {:duplicate, %{status: "ambiguous", delivery_attempt: 1}} =
               StateMachine.send_text(resumed_sm, @prompt, 1_000, @msg_a),
             "a resumed run reconciles a queued send; it never re-pastes one"

      assert Agent.get(pastes, & &1) == 1,
             "the crash is not evidence of non-delivery, so the bytes are not sent twice"
    end

    test "a send finalized before the crash is read back, not re-decided", ctx do
      {sm, pane} = start_pane(ctx)
      :ok = ReceiptStore.observe(ctx.store, @msg_a)
      assert {:queued, _} = StateMachine.send_text(sm, @prompt, 1_000, @msg_a)
      go_idle(pane)
      assert_receive {:receipt_finalized, @msg_a, "delivered"}, 2_000

      revived = restart_store!(ctx)
      ctx = %{ctx | store: revived}

      assert {:ok, %{outcome: "delivered", delivery_attempt: 1}} =
               ReceiptStore.reconcile(revived, @msg_a, @pane, payload_hash(@prompt), wait_ms: 0),
             "a terminal record outlives the epoch that wrote it"

      assert statuses(ctx, @msg_a) == [{1, "pending"}, {1, "queued"}, {1, "delivered"}]
    end
  end

  # ----- helpers -----

  defp kill_pane(:explicit, sm, _capture), do: StateMachine.mark_dead(sm)
  defp kill_pane(:reaped, _sm, capture), do: Agent.update(capture, fn _ -> {:error, :pane_gone} end)

  defp start_pane(ctx, opts \\ []) do
    {:ok, pane} = Agent.start_link(fn -> "BUSY_MARKER" end)

    {:ok, sm} =
      StateMachine.start_link(
        Keyword.merge(
          [
            pane_id: @pane,
            capture_fn: fn _pane_id -> {:ok, Agent.get(pane, & &1)} end,
            paste_fn: fn _pane_id, _text -> :ok end,
            classifier: MarkerClassifier,
            poll_interval_ms: 5,
            idle_debounce_ms: 10,
            receipt_store: ctx.store
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(sm), do: :gen_statem.stop(sm, :normal, 500) end)
    {sm, pane}
  end

  defp go_idle(pane), do: Agent.update(pane, fn _ -> "IDLE_MARKER" end)

  # A crash, not a shutdown: a graceful stop could flush what a lost daemon never would.
  defp restart_store!(ctx) do
    ref = Process.monitor(ctx.store)
    Process.exit(ctx.store, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 1_000
    stop_supervised!(ReceiptStore)
    start_supervised!({ReceiptStore, inbox: ctx.inbox})
  end

  defp reconcile(ctx, msg_id, opts \\ [wait_ms: 0]) do
    ReceiptStore.reconcile(ctx.store, msg_id, @pane, payload_hash(@prompt), opts)
  end

  defp statuses(ctx, msg_id) do
    ctx.store
    |> ReceiptStore.path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg_id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  defp payload_hash(text) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
  end

  defp message_id(n) do
    "snd_" <> Base.encode16(:crypto.hash(:sha256, "queued-#{n}"), case: :lower)
  end
end
