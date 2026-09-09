defmodule AiPair.Delivery.ReceiptStoreTest do
  @moduledoc """
  Receipt store contract rows.

  The daemon is the idempotency authority for pane delivery. It must durably record
  `{message_id, pane identity, payload hash, status, delivery_attempt}`, admit each
  physical attempt exactly once, reject same-id mismatches, and answer an exact
  reconciliation query with delivered / queued / absent / ambiguous / conflict.

  What this file pins:

    * The store is **one supervised process**, not module functions appending to a
      shared file. IPC connections run concurrently under `Task.Supervisor`, so append
      order, admission and owner monitoring must be serialized by a single owner.
    * `daemon_epoch` is minted once at boot from the CSPRNG and is **never supplied
      by a caller**. Callers cannot pass one because the API has nowhere to put it.
    * There is no `failed` status. `not_delivered` means proven-before-any-paste,
      and only that may read as `absent`. Every other failure is `ambiguous`.
    * `queued` is not terminal; it may still become `delivered`, `not_delivered`
      or `ambiguous` during drain.
    * Same-epoch pending: a bounded wait is legitimate only while a live operation owner is
      proven. Epoch equality alone is not evidence that a paste is still in flight.
    * Ids are globally scoped `snd_<64 hex>`, so two runs sharing an assignment id
      never collide in this global store.
    * Reconciliation binds the payload via `sha256:<64 hex>`; prompt bytes never
      reach the store.

  Design notes:

    * The mutation entry point is `admit/5`, because this is atomic delivery admission and not
      file opening, and it returns an **opaque operation token** alongside the
      `delivery_attempt`. `transition/4` requires that token, so knowing a `message_id` no
      longer entitles a process to finalize somebody else's paste.
    * A duplicate is a typed receipt view, never a bare status string. No caller parses
      `"pending"` out of a tuple.
    * Statuses are terminal **per physical attempt**, not per logical id. A send id is a
      pure function of run and assignment, so a retry after a proven non-delivery
      presents the same id; terminal-per-id would answer `duplicate not_delivered` forever
      and a provably-unsent assignment could never be sent. `delivery_attempt` names the
      immutable attempt, and only `not_delivered` is retryable: `delivered` and `ambiguous`
      may already have reached the pane.
    * Two live stores never share an inbox in a test merely to compare epochs. A second
      live store on one inbox is **refused**, and the tests must not normalize two
      simultaneous writers to one evidence log.
    * Durability is proven at an injectable filesystem seam. On-disk assertions after a
      successful call cannot distinguish "fsynced before replying" from "written, replied,
      and flushed later by the kernel", which is exactly the distinction the durability contract depends on.

  The record log is a hash chain: every line carries `prev_line_sha256`, the
  SHA-256 of the exact bytes of the previous persisted line **including its newline**, and
  the first line carries the anchor, the hash of the empty string. There is
  deliberately **no separate head pointer**: the receipt log is read in full at boot and
  every acknowledged append is fsynced, so a second mutable pointer would add another crash
  bracket without answering a question the full read leaves open.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Test.FaultFs

  @pane "%" <> Integer.to_string(9)
  @other_pane "%" <> Integer.to_string(8)
  @msg_a "snd_" <> String.duplicate("a1", 32)
  @msg_b "snd_" <> String.duplicate("b2", 32)
  @msg_run1 "snd_" <> String.duplicate("c3", 32)
  @msg_run2 "snd_" <> String.duplicate("d4", 32)
  @payload "sha256:" <> String.duplicate("e5", 32)
  @other_payload "sha256:" <> String.duplicate("f6", 32)
  @epoch_pattern ~r/^ep_[0-9a-f]{24}$/
  @anchor "sha256:" <> Base.encode16(:crypto.hash(:sha256, ""), case: :lower)

  setup do
    inbox = Path.join(System.tmp_dir!(), "ai_pair_receipts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  describe "identity is minted by the store, not by its callers" do
    test "the epoch is a CSPRNG grammar minted once at boot", %{inbox: inbox} do
      store = start_store!(inbox)

      epoch = ReceiptStore.daemon_epoch(store)
      assert epoch =~ @epoch_pattern
      assert ReceiptStore.daemon_epoch(store) == epoch, "the epoch is minted once, not per call"
    end

    test "a second boot of the same inbox mints a different epoch", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      first_epoch = ReceiptStore.daemon_epoch(first)
      :ok = stop_store(first)

      second = start_store!(inbox, :second)

      refute ReceiptStore.daemon_epoch(second) == first_epoch,
             "the boots are sequential, because one inbox never has two live stores"
    end

    test "a second live store on the same inbox is refused", %{inbox: inbox} do
      _first = start_store!(inbox, :first)

      assert {:error, reason} = start_store(inbox, :second)

      assert inspect(reason) =~ "receipt_store_already_running",
             "two simultaneous writers to one evidence log is a defect, not a test fixture"
    end

    test "the persisted record carries the store's own epoch", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      assert [record | _] = records(store)
      assert record["daemon_epoch"] == ReceiptStore.daemon_epoch(store)
    end

    test "two runs sharing an assignment stay independent under global ids", %{inbox: inbox} do
      store = start_store!(inbox)

      run1 = admit!(store, @msg_run1)

      assert %{delivery_attempt: 1} = admit!(store, @msg_run2),
             "distinct runs mint distinct send ids, so the second is not a duplicate"

      assert :ok = ReceiptStore.transition(store, @msg_run1, run1.operation_token, "delivered")

      assert {:ok, %{outcome: "delivered"}} = reconcile(store, @msg_run1)

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_run2, wait_ms: 0),
             "finalizing one run must not resolve the other"
    end
  end

  describe "reconciliation is five-valued" do
    test "an unknown message id is absent", %{inbox: inbox} do
      assert {:ok, %{outcome: "absent"}} = reconcile(start_store!(inbox), @msg_a)
    end

    test "a finalized paste is delivered", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:ok, %{outcome: "delivered", pane_id: @pane}} = reconcile(store, @msg_a)
    end

    test "a send parked in the pane queue is queued", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "queued")

      assert {:ok, %{outcome: "queued"}} = reconcile(store, @msg_a)
    end

    test "a failure proven before any paste is absent", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)

      assert :ok =
               ReceiptStore.transition(store, @msg_a, admission.operation_token, "not_delivered")

      assert {:ok, %{outcome: "absent"}} = reconcile(store, @msg_a),
             "only a pre-paste failure leaves nothing on the pane, so only it may read as absent"
    end

    test "an unprovable outcome is ambiguous", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "ambiguous")

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_a)
    end

    test "the same id with different payload bytes is a conflict", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:ok, %{outcome: "conflict"}} =
               ReceiptStore.reconcile(store, @msg_a, @pane, @other_payload, wait_ms: 0),
             "the payload hash is bound, so a same-id different-payload send is a conflict"
    end

    test "the same id on a different pane is a conflict", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      assert {:ok, %{outcome: "conflict"}} =
               ReceiptStore.reconcile(store, @msg_a, @other_pane, @payload, wait_ms: 0)
    end

    test "a malformed payload hash is refused rather than reconciled", %{inbox: inbox} do
      store = start_store!(inbox)

      assert {:error, {:invalid_payload_hash, _}} =
               ReceiptStore.reconcile(store, @msg_a, @pane, String.duplicate("e5", 32), wait_ms: 0),
             "`sha256:<64 lowercase hex>` is validated, and a bad hash is never `absent`"
    end

    test "a malformed message id is refused rather than reconciled", %{inbox: inbox} do
      store = start_store!(inbox)

      assert {:error, {:invalid_message_id, _}} =
               ReceiptStore.reconcile(store, "send_as_0001", @pane, @payload, wait_ms: 0),
             "the run-scoped `send_as_NNNN` shape is not admissible in a global store"
    end
  end

  describe "pending is never read as absence" do
    test "a live owner that never finalizes times out as ambiguous", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a, spawn_owner())

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_a, wait_ms: 50),
             "a bounded wait that expires is ambiguous, never absent"
    end

    test "a bounded waiter is woken by finalization", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a, spawn_owner())

      waiter = Task.async(fn -> reconcile(store, @msg_a, wait_ms: 2_000) end)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:ok, %{outcome: "delivered"}} = Task.await(waiter, 3_000)
    end

    test "a dead owner is ambiguous immediately, in the same epoch", %{inbox: inbox} do
      store = start_store!(inbox)
      owner = spawn_owner()
      admit!(store, @msg_a, owner)
      :ok = ReceiptStore.observe(store, @msg_a)

      Process.exit(owner, :kill)

      assert_receive {:receipt_finalized, @msg_a, "ambiguous"}, 1_000

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_a, wait_ms: 5_000),
             "epoch equality is not evidence that a paste is still in flight"
    end

    test "the death of the requesting connection alone never finalizes a live paste",
         %{inbox: inbox} do
      store = start_store!(inbox)
      owner = spawn_owner()

      # The IPC connection handler admits on behalf of the pane state machine and then dies;
      # the state machine it named is still executing the paste.
      connection =
        spawn(fn ->
          admit!(store, @msg_a, owner)
          Process.sleep(:infinity)
        end)

      wait_until(fn -> match?([_ | _], records(store)) end)
      kill_and_await(connection)

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_a, wait_ms: 25),
             "the wait still expires as ambiguous, but only on the deadline"

      assert Enum.all?(records(store), &(&1["status"] != "ambiguous")),
             "the monitored owner is the pane state machine, not the connection handler"
    end

    test "a pending record orphaned by daemon loss is ambiguous", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      admit!(first, @msg_a, spawn_owner())
      kill_and_await(first)

      second = start_store!(inbox, :second)

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(second, @msg_a, wait_ms: 0),
             "no owner can survive the epoch boundary, so the wait is not merely bounded, it is skipped"
    end
  end

  describe "only the admitting operation may finalize it" do
    test "a foreign token is refused", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a, spawn_owner())
      other = admit!(store, @msg_b, spawn_owner())

      assert {:error, {:foreign_operation_token, @msg_a}} =
               ReceiptStore.transition(store, @msg_a, other.operation_token, "delivered"),
             "knowing a message id must not entitle a process to finalize its paste"
    end

    test "a fabricated token is refused", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a, spawn_owner())

      assert {:error, {:foreign_operation_token, @msg_a}} =
               ReceiptStore.transition(store, @msg_a, make_ref(), "delivered")
    end

    test "a token from a superseded attempt is refused", %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")

      second = admit!(store, @msg_a)
      assert second.delivery_attempt == 2

      assert {:error, {:stale_operation_token, 1, 2}} =
               ReceiptStore.transition(store, @msg_a, first.operation_token, "delivered"),
             "a late transition from attempt 1 must not finalize attempt 2"

      assert :ok = ReceiptStore.transition(store, @msg_a, second.operation_token, "delivered")
    end
  end

  describe "admission is exactly once per attempt" do
    test "a duplicate observing pending is answered with a typed receipt view", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a, spawn_owner())

      assert {:ok, {:duplicate, view}} = admit(store, @msg_a)

      assert %{
               status: "pending",
               delivery_attempt: 1,
               message_id: @msg_a,
               pane_id: @pane
             } = view,
             "no caller parses a bare status string out of a duplicate"
    end

    test "an identical retry after delivery is deduplicated", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:ok, {:duplicate, %{status: "delivered", delivery_attempt: 1}}} = admit(store, @msg_a)
    end

    test "a same-id payload mismatch is rejected instead of overwriting", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      assert {:error, {:conflict, existing}} =
               ReceiptStore.admit(store, @msg_a, @pane, @other_payload, self())

      assert existing.payload_hash == @payload
    end

    test "a same-id pane mismatch is rejected instead of overwriting", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      assert {:error, {:conflict, existing}} =
               ReceiptStore.admit(store, @msg_a, @other_pane, @payload, self())

      assert existing.pane_id == @pane
    end

    test "concurrent admissions of the same id admit exactly one", %{inbox: inbox} do
      store = start_store!(inbox)

      results =
        1..32
        |> Task.async_stream(fn _ -> admit(store, @msg_a) end, max_concurrency: 32)
        |> Enum.map(fn {:ok, result} -> result end)

      admitted = Enum.count(results, &match?({:ok, {:admitted, _}}, &1))
      duplicates = Enum.count(results, &match?({:ok, {:duplicate, _}}, &1))

      assert admitted == 1, "a serialized owner admits once under concurrency"
      assert duplicates == 31
    end

    test "concurrent same-id different-pane admissions never both admit", %{inbox: inbox} do
      store = start_store!(inbox)

      results =
        [@pane, @other_pane, @pane, @other_pane]
        |> Task.async_stream(
          fn pane -> ReceiptStore.admit(store, @msg_a, pane, @payload, self()) end,
          max_concurrency: 4
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, {:admitted, _}}, &1)) == 1
      assert Enum.any?(results, &match?({:error, {:conflict, _}}, &1))
    end
  end

  describe "a proven non-delivery is the one outcome that may be retried" do
    test "the send id is stable across attempts, so only the attempt distinguishes them",
         %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert first.delivery_attempt == 1
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")

      second = admit!(store, @msg_a)

      assert second.delivery_attempt == 2,
             "a send id is a pure function of run and assignment, so a retry presents the same id"

      refute second.operation_token == first.operation_token,
             "a new attempt is a new operation with its own authority"
    end

    test "not_delivered retried to delivered ends in observation, not attention",
         %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")

      assert {:ok, %{outcome: "absent"}} = reconcile(store, @msg_a),
             "the orchestrator is told nothing reached the pane, so it may send again"

      second = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, second.operation_token, "delivered")

      assert {:ok, %{outcome: "delivered", delivery_attempt: 2}} = reconcile(store, @msg_a),
             "reconciliation answers from the highest admitted attempt"
    end

    test "delivered is not retryable", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:ok, {:duplicate, %{status: "delivered", delivery_attempt: 1}}} = admit(store, @msg_a),
             "bytes already reached the pane, so a second attempt would duplicate the prompt"
    end

    test "ambiguous is not retryable", %{inbox: inbox} do
      store = start_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "ambiguous")

      assert {:ok, {:duplicate, %{status: "ambiguous", delivery_attempt: 1}}} = admit(store, @msg_a),
             "bytes may already have reached the pane, and may is not no"
    end

    test "concurrent retries after a proven non-delivery admit exactly one", %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")

      results =
        1..16
        |> Task.async_stream(fn _ -> admit(store, @msg_a) end, max_concurrency: 16)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, {:admitted, %{delivery_attempt: 2}}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, {:duplicate, _}}, &1)) == 15
    end

    test "each attempt is its own immutable record", %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")
      second = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, second.operation_token, "delivered")

      attempts =
        records(store)
        |> Enum.filter(&(&1["message_id"] == @msg_a))
        |> Enum.map(&{&1["delivery_attempt"], &1["status"]})

      assert attempts == [
               {1, "pending"},
               {1, "not_delivered"},
               {2, "pending"},
               {2, "delivered"}
             ],
             "`a terminal record is never rewritten` holds per attempt, and the history is kept"
    end
  end

  describe "transitions are a closed, strictly ordered vocabulary" do
    test "queued is not terminal", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)

      assert :ok = ReceiptStore.transition(store, @msg_a, token, "queued")
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")
      assert {:ok, %{outcome: "delivered"}} = reconcile(store, @msg_a)
    end

    test "a queued send lost during drain becomes ambiguous", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)

      assert :ok = ReceiptStore.transition(store, @msg_a, token, "queued")
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "ambiguous")
      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, @msg_a)
    end

    test "a terminal record is never rewritten", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")

      assert {:error, {:illegal_transition, "delivered", "queued"}} =
               ReceiptStore.transition(store, @msg_a, token, "queued")

      assert {:error, {:illegal_transition, "delivered", "delivered"}} =
               ReceiptStore.transition(store, @msg_a, token, "delivered"),
             "a duplicate terminal rewrite is rejected, not silently accepted"
    end

    test "a new attempt does not reopen the previous one", %{inbox: inbox} do
      store = start_store!(inbox)
      first = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, first.operation_token, "not_delivered")
      _second = admit!(store, @msg_a)

      assert {:error, {:stale_operation_token, 1, 2}} =
               ReceiptStore.transition(store, @msg_a, first.operation_token, "queued"),
             "retry appends a new attempt; it never revives a closed one"
    end

    test "failed is not a status", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)

      assert {:error, {:unknown_status, "failed"}} =
               ReceiptStore.transition(store, @msg_a, token, "failed"),
             "`failed` collapsed pre-paste and post-paste failure, so it is abolished"
    end

    test "pending is not a transition target", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)

      assert {:error, {:illegal_transition, "pending", "pending"}} =
               ReceiptStore.transition(store, @msg_a, token, "pending"),
             "admission is the only writer of pending, so an attempt cannot be reopened in place"
    end

    test "transitioning an unknown id is refused", %{inbox: inbox} do
      store = start_store!(inbox)

      assert {:error, {:unknown_message_id, @msg_b}} =
               ReceiptStore.transition(store, @msg_b, make_ref(), "delivered"),
             "an unknown id is reported as unknown, not as a token failure"
    end

    test "the sequence is monotonic across appends", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "queued")
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")

      assert Enum.map(records(store), & &1["seq"]) == [1, 2, 3]
    end

    test "concurrent writers produce a gapless sequence and an intact chain", %{inbox: inbox} do
      store = start_store!(inbox)
      owner = self()

      1..24
      |> Task.async_stream(fn n -> admit(store, message_id(n), owner) end, max_concurrency: 24)
      |> Stream.run()

      assert Enum.map(records(store), & &1["seq"]) == Enum.to_list(1..24)
      assert_chain!(store)
    end
  end

  describe "the receipt log is the daemon's own evidence" do
    test "receipts carry a payload hash, never payload bytes", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      contents = File.read!(ReceiptStore.path(store))
      assert contents =~ @payload
      refute contents =~ "prompt"
    end

    test "every persisted record names its attempt", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")

      assert Enum.all?(records(store), &is_integer(&1["delivery_attempt"])),
             "an attempt that is not persisted cannot survive the crash it exists for"
    end

    test "the log is private to the daemon user", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)

      path = ReceiptStore.path(store)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, %File.Stat{mode: dir_mode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end

    test "every line chains to the exact bytes of its predecessor", %{inbox: inbox} do
      store = start_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")
      admit!(store, @msg_b)

      assert [first | _] = records(store)
      assert first["prev_line_sha256"] == @anchor
      assert_chain!(store)
    end

    test "records survive a cold reload of the store", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      %{operation_token: token} = admit!(first, @msg_a)
      assert :ok = ReceiptStore.transition(first, @msg_a, token, "delivered")
      :ok = stop_store(first)

      second = start_store!(inbox, :second)
      assert {:ok, %{outcome: "delivered"}} = reconcile(second, @msg_a)
    end

    test "an attempt history survives a cold reload", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      one = admit!(first, @msg_a)
      assert :ok = ReceiptStore.transition(first, @msg_a, one.operation_token, "not_delivered")
      two = admit!(first, @msg_a)
      assert two.delivery_attempt == 2
      :ok = stop_store(first)

      second = start_store!(inbox, :second)

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(second, @msg_a, wait_ms: 0),
             "attempt 2 was pending and its owner cannot outlive the epoch"

      assert {:ok, {:duplicate, %{delivery_attempt: 2}}} = admit(second, @msg_a),
             "the reloaded store still knows which attempt is highest"
    end

    test "one torn tail is repaired and the chain continues", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      admit!(first, @msg_a)
      path = ReceiptStore.path(first)
      :ok = stop_store(first)

      File.write!(path, ~s({"schema":"ai-pair/delivery-receipt","seq":2,"msg_i), [:append])

      second = start_store!(inbox, :second)

      assert {:ok, %{outcome: "ambiguous"}} = reconcile(second, @msg_a, wait_ms: 0)
      admit!(second, @msg_b)
      assert_chain!(second)
    end

    test "interior corruption fails closed instead of guessing", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      %{operation_token: token} = admit!(first, @msg_a)
      assert :ok = ReceiptStore.transition(first, @msg_a, token, "delivered")
      path = ReceiptStore.path(first)
      :ok = stop_store(first)

      [head, tail] = path |> File.read!() |> String.split("\n", parts: 2)
      File.write!(path, String.replace(head, @pane, @other_pane) <> "\n" <> tail)

      assert {:error, reason} = start_store(inbox, :second)

      assert inspect(reason) =~ "receipt_log_corrupt",
             "a broken chain in the interior is unrecoverable, so the daemon must refuse to serve it"
    end
  end

  # Asserting that the bytes are on disk after a call has already returned cannot
  # distinguish "fsynced before replying" from "written, replied, and flushed later by the
  # kernel". Only refusing the syscall can, so durability is proven at an injectable seam.
  describe "durability is proven at the filesystem boundary" do
    test "a short or failed write is never acknowledged", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      FaultFs.inject(fs, :write, 1, {:error, :enospc})

      assert {:error, {:receipt_write_failed, :enospc}} = admit(store, @msg_a)

      assert {:ok, %{outcome: "absent"}} = reconcile(store, @msg_a, wait_ms: 0),
             "a rejected append leaves no receipt, so nothing was ever admitted"
    end

    test "a torn write is never acknowledged", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      FaultFs.inject(fs, :write, 1, {:torn, 12})

      assert {:error, {:receipt_write_failed, _}} = admit(store, @msg_a)
    end

    test "the reply waits on the file fsync, not on the write", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      FaultFs.inject(fs, :sync, 1, {:error, :eio})

      assert {:error, {:receipt_sync_failed, :eio}} = admit(store, @msg_a),
             "the caller must not be told the receipt is durable before it is"
    end

    test "every acknowledged append is fsynced", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "queued")
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")

      assert FaultFs.count(fs, :sync) >= 3,
             "three acknowledged appends require three file fsyncs"
    end

    test "the directory is fsynced when the log is created", %{inbox: inbox} do
      {_store, fs} = start_faulty_store!(inbox)

      assert FaultFs.count(fs, :dir_sync) >= 1,
             "a file whose directory entry is unsynced can vanish entirely on power loss"
    end

    test "an ordinary append does not fsync the directory", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      before = FaultFs.count(fs, :dir_sync)

      %{operation_token: token} = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, token, "delivered")

      assert FaultFs.count(fs, :dir_sync) == before,
             "the directory entry does not change when a line is appended to an existing file"
    end

    test "a directory fsync failure at creation refuses the store", %{inbox: inbox} do
      fs = FaultFs.new()
      FaultFs.inject(fs, :dir_sync, 1, {:error, :eio})

      assert {:error, reason} = start_store(inbox, :store, fs: fs)
      assert inspect(reason) =~ "receipt_dir_sync_failed"
    end

    test "a create failure refuses the store", %{inbox: inbox} do
      fs = FaultFs.new()
      FaultFs.inject(fs, :open, 1, {:error, :eacces})

      assert {:error, reason} = start_store(inbox, :store, fs: fs)
      assert inspect(reason) =~ "receipt_open_failed"
    end

    test "a chmod failure refuses the store rather than serving a world-readable log",
         %{inbox: inbox} do
      fs = FaultFs.new()
      FaultFs.inject(fs, :chmod, 1, {:error, :eperm})

      assert {:error, reason} = start_store(inbox, :store, fs: fs)

      assert inspect(reason) =~ "receipt_chmod_failed",
             "the evidence log carries pane and payload identity; it is never opened up to fail soft"
    end

    test "a torn tail repair that cannot be fsynced refuses the store", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      admit!(first, @msg_a)
      path = ReceiptStore.path(first)
      :ok = stop_store(first)

      File.write!(path, ~s({"schema":"ai-pair/delivery-receipt","seq":2,"msg_i), [:append])

      fs = FaultFs.new()
      FaultFs.inject(fs, :truncate, 1, {:error, :eio})

      assert {:error, reason} = start_store(inbox, :second, fs: fs)

      assert inspect(reason) =~ "receipt_truncate_failed",
             "an unrepaired torn tail must not be served as if it had been repaired"
    end

    test "a repaired torn tail is fsynced before the store answers", %{inbox: inbox} do
      first = start_store!(inbox, :first)
      admit!(first, @msg_a)
      path = ReceiptStore.path(first)
      :ok = stop_store(first)

      File.write!(path, ~s({"schema":"ai-pair/delivery-receipt","seq":2,"msg_i), [:append])

      fs = FaultFs.new()
      {:ok, _second} = start_store(inbox, :second, fs: fs)

      assert :truncate in FaultFs.ops(fs)

      assert Enum.find_index(FaultFs.ops(fs), &(&1 == :truncate)) <
               Enum.find_index(FaultFs.ops(fs), &(&1 == :sync)),
             "the truncation is durable before any later line is appended after it"
    end
  end

  # ----- helpers -----

  describe "failure containment and replay validation" do
    test "an uncertain append stops subsequent mutations", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      FaultFs.inject(fs, :sync, 1, {:error, :eio})
      assert {:error, {:receipt_sync_failed, :eio}} = admit(store, @msg_a)
      writes = FaultFs.count(fs, :write)
      assert {:error, :receipt_store_unavailable} = admit(store, @msg_b)
      assert FaultFs.count(fs, :write) == writes
    end

    test "uncertain finalization cannot leave an actionable queued answer", %{inbox: inbox} do
      {store, fs} = start_faulty_store!(inbox)
      admission = admit!(store, @msg_a)
      assert :ok = ReceiptStore.transition(store, @msg_a, admission.operation_token, "queued")
      FaultFs.inject(fs, :sync, FaultFs.count(fs, :sync) + 1, {:error, :eio})

      assert {:error, {:receipt_sync_failed, :eio}} =
               ReceiptStore.transition(store, @msg_a, admission.operation_token, "delivered")

      assert {:error, :receipt_store_unavailable} = reconcile(store, @msg_a)
    end

    test "invalid filesystem read shapes refuse startup by name", %{inbox: inbox} do
      fs = FaultFs.new()
      FaultFs.inject(fs, :read, 1, {:return, {:ok, 42}})
      assert {:error, reason} = start_store(inbox, :invalid_read, fs: fs)
      assert inspect(reason) =~ "receipt_read_failed"
    end

    test "all message entry points reject an invalid id without reflecting it", %{inbox: inbox} do
      store = start_store!(inbox)
      id = "INVALID_ID_CANARY"

      assert {:error, {:invalid_message_id, :grammar}} =
               ReceiptStore.transition(store, id, make_ref(), "delivered")

      assert {:error, {:invalid_message_id, :grammar}} = ReceiptStore.observe(store, id)
    end

    test "hash and id grammars reject trailing newlines", %{inbox: inbox} do
      store = start_store!(inbox)
      assert {:error, {:invalid_message_id, :grammar}} = reconcile(store, @msg_a <> "\n")

      assert {:error, {:invalid_payload_hash, :grammar}} =
               ReceiptStore.reconcile(store, @msg_a, @pane, @payload <> "\n")
    end

    test "a duplicate view contains no operation authority", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)
      assert {:ok, {:duplicate, view}} = admit(store, @msg_a)
      refute Map.has_key?(view, :operation_token)
      refute File.read!(ReceiptStore.path(store)) =~ "operation_token"
    end

    test "a complete invalid last record is corruption, not a repairable tail", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)
      path = ReceiptStore.path(store)
      :ok = stop_store(store)
      File.write!(path, "{}\n", [:append])
      before = File.read!(path)
      assert {:error, reason} = start_store(inbox, :corrupt)
      assert inspect(reason) =~ "receipt_log_corrupt"
      assert File.read!(path) == before
    end

    test "a forged retry with a valid chain but no prior non-delivery is refused", %{inbox: inbox} do
      store = start_store!(inbox)
      admit!(store, @msg_a)
      path = ReceiptStore.path(store)
      :ok = stop_store(store)
      prior = File.read!(path)
      record = Jason.decode!(String.trim_trailing(prior, "\n"))

      forged =
        record
        |> Map.put("seq", 2)
        |> Map.put("delivery_attempt", 2)
        |> Map.put(
          "prev_line_sha256",
          "sha256:" <> Base.encode16(:crypto.hash(:sha256, prior), case: :lower)
        )

      File.write!(path, Jason.encode!(forged) <> "\n", [:append])
      assert {:error, reason} = start_store(inbox, :forged)
      assert inspect(reason) =~ "receipt_log_corrupt"
    end
  end

  defp start_store!(inbox, id \\ :store) do
    {:ok, pid} = start_store(inbox, id)
    pid
  end

  defp start_store(inbox, id, opts \\ []) do
    start_supervised(
      Supervisor.child_spec({ReceiptStore, [inbox: inbox] ++ opts}, id: id, restart: :temporary)
    )
  end

  defp start_faulty_store!(inbox) do
    fs = FaultFs.new()
    {:ok, store} = start_store(inbox, :store, fs: fs)
    {store, fs}
  end

  defp stop_store(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal, 1_000)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
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

  defp admit(store, msg_id, owner \\ nil) do
    ReceiptStore.admit(store, msg_id, @pane, @payload, owner || self())
  end

  defp admit!(store, msg_id, owner \\ nil) do
    {:ok, {:admitted, admission}} = admit(store, msg_id, owner)
    admission
  end

  defp reconcile(store, msg_id, opts \\ [wait_ms: 0]) do
    ReceiptStore.reconcile(store, msg_id, @pane, @payload, opts)
  end

  defp message_id(n) do
    "snd_" <> Base.encode16(:crypto.hash(:sha256, "message-#{n}"), case: :lower)
  end

  defp spawn_owner do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
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

  defp records(store) do
    store
    |> ReceiptStore.path()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # Hash-chain rule: the link is over the exact bytes of the previous
  # persisted line, newline included, and the first line anchors on the hash of "".
  defp assert_chain!(store) do
    store
    |> ReceiptStore.path()
    |> File.read!()
    |> String.split(~r/(?<=\n)/, trim: true)
    |> Enum.reduce(@anchor, fn line, expected_prev ->
      assert Jason.decode!(line)["prev_line_sha256"] == expected_prev
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, line), case: :lower)
    end)
  end
end
