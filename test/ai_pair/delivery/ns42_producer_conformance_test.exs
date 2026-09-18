defmodule AiPair.Delivery.NS42ProducerConformanceTest do
  @moduledoc """
  Producer-side conformance rows for the delivery-receipt rules NS-42.C.007 (terminal
  attempts), C.008 (ambiguity), C.009 (token ownership) and C.010 (atomic admission).

  The consumer halves of these four rules are evidenced in the orris repository. The
  producer halves were implemented in this repository and never asserted: the register
  still names "producer-side edge enforcement", "token minting", "handler death" and
  "atomic admission" as Orrisd obligations that remain UNPROVEN. These rows assert the
  behaviour that is already here, and no source is changed to make them pass.

  What each row pins, and what it is NOT a duplicate of:

    * `receipt_store_test.exs` walks individual edges and asserts three illegal ones by
      name. It never enumerates the vocabulary, so an EIGHTH legal edge added to
      `ReceiptLog.transition?/2` would leave every existing row green. The first two rows
      here close the set over the full five-by-five cross product, once as the predicate
      and once through the store itself.
    * `paste_window_test.exs` asserts that a post-authorization `not_delivered` is refused
      as `paste_outcome_unproven`. The store refuses a post-authorization `queued` by the
      same clause and nothing asserted it; a claim of "still queued" after bytes may have
      crossed is the same unproven claim as "never sent".
    * `safe_paste/3` converts a RAISING or THROWING paste function into ambiguity. Every
      existing paste row returns a well-formed `{:error, reason}`, so the rescue and catch
      clauses were unasserted; a crash inside the paste is exactly the case where proof of
      non-delivery is unavailable.
    * The store's `{:DOWN, ...}` clause is guarded on BOTH the attempt and the
      non-terminal status. `receipt_store_test.exs` proves a dead owner of a live attempt
      is ambiguous; nothing proved that a dead owner may not rewrite a TERMINAL record, or
      resolve an attempt it no longer owns.
    * The monitored owner is asserted here through the real `Pane.StateMachine`, which is
      the process that calls `admit/5` with `self()`. The existing store row uses two
      synthetic processes, so it cannot tell which process the product actually names.
    * Admission is serialized by ONE process per NORMALIZED inbox under `:global`. The
      existing row starts a second store on the identical path string; nothing asserted
      the normalization, so admission for one inbox reached through two spellings would
      have been served by two writers.
  """

  use ExUnit.Case, async: true

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.Pane.StateMachine
  alias AiPair.Test.MarkerClassifier

  # The closed status vocabulary of the receipt record.
  @statuses ~w(pending queued delivered not_delivered ambiguous)

  # The seven edges the ledger names. Written out here rather than derived, so that the
  # rows below compare an independent statement of the rule against the implementation.
  @legal_edges [
    {"pending", "queued"},
    {"pending", "delivered"},
    {"pending", "not_delivered"},
    {"pending", "ambiguous"},
    {"queued", "delivered"},
    {"queued", "not_delivered"},
    {"queued", "ambiguous"}
  ]

  @pane "%ns42_producer"
  @payload "sha256:" <> String.duplicate("ab", 32)

  # The bytes the pane row actually sends. The daemon hashes what it is given, so the
  # reconcile question must present the same hash or it is answered `conflict`.
  @queued_text "queued bytes"

  setup do
    inbox =
      Path.join(System.tmp_dir!(), "ns42_producer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  describe "rule 7: a terminal status belongs to an immutable physical attempt" do
    test "the legal edge set is exactly seven pairs over the closed status vocabulary" do
      # ANTI-VACUITY: the comprehension below must really range over a 25-pair space,
      # or "exactly seven" would be a statement about an empty search.
      assert length(@statuses) == 5
      assert length(for(from <- @statuses, to <- @statuses, do: {from, to})) == 25

      legal =
        for from <- @statuses, to <- @statuses, ReceiptLog.transition?(from, to), do: {from, to}

      assert Enum.sort(legal) == Enum.sort(@legal_edges),
             "the receipt edge set is closed; an eighth edge is a new retry policy, not a fix"

      assert length(legal) == 7
    end

    test "the store accepts the seven edges and refuses the other eighteen", %{inbox: inbox} do
      store = start_store!(inbox)

      outcomes =
        for from <- @statuses, to <- @statuses do
          id = message_id("edge-#{from}-#{to}")
          token = drive_to!(store, id, from)
          {{from, to}, ReceiptStore.transition(store, id, token, to)}
        end

      {accepted, refused} = Enum.split_with(outcomes, fn {_edge, result} -> result == :ok end)
      accepted_edges = accepted |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert accepted_edges == Enum.sort(@legal_edges)
      assert length(refused) == 18

      for {{from, to}, result} <- refused do
        assert result == {:error, {:illegal_transition, from, to}},
               "#{from} -> #{to} must be refused by name, not by an unrelated error"
      end
    end

    test "an illegal edge forged into the log is refused when the log is re-read", %{inbox: inbox} do
      store = start_store!(inbox, :first)
      id = message_id("forged-edge")
      _token = drive_to!(store, id, "delivered")
      path = ReceiptStore.path(store)
      :ok = stop_store(store)

      # A syntactically perfect line: correct seq, correct chain link, correct key set,
      # valid grammars, same identity and same attempt. The ONLY thing wrong with it is
      # that `delivered -> queued` is not an edge.
      append_chained!(path, fn last -> %{last | "status" => "queued"} end)

      assert {:error, reason} = start_store(inbox, :second)

      assert inspect(reason) =~ "receipt_log_corrupt",
             "the edge rule is re-validated at open, so a hand-written terminal rewrite " <>
               "cannot be served as history"
    end
  end

  describe "rule 8: unproven outcomes are ambiguous, never absence" do
    test "after paste authorization the store refuses queued as well as proven non-delivery",
         %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("unproven")
      token = admit!(store, id).operation_token
      assert :ok = ReceiptStore.begin_paste(store, id, token)

      assert {:error, :paste_outcome_unproven} =
               ReceiptStore.transition(store, id, token, "not_delivered")

      assert {:error, :paste_outcome_unproven} =
               ReceiptStore.transition(store, id, token, "queued"),
             "once bytes may have crossed, `still queued` is as unproven as `never sent`; " <>
               "pending -> queued is otherwise a legal edge, so only this clause refuses it"

      assert :ok = ReceiptStore.transition(store, id, token, "ambiguous")
      assert {:ok, %{outcome: "ambiguous"}} = reconcile(store, id)
    end

    test "a paste function that raises or throws finalizes ambiguous", %{inbox: inbox} do
      store = start_store!(inbox)
      sm = start_idle_pane!(store, crashing_paste_fn())

      for {text, how} <- [{"RAISE these bytes", "raise"}, {"THROW these bytes", "throw"}] do
        id = message_id(how)

        assert {:error, {:paste_failed, :ambiguous}} =
                 StateMachine.send_receipted(sm, text, 5_000, id, store),
               "a #{how} inside the paste is unproven delivery, so the caller is told so"

        assert {:ok, %{outcome: "ambiguous", status: "ambiguous", delivery_attempt: 1}} =
                 ReceiptStore.reconcile(store, id, @pane, Payload.hash(Payload.new(text))),
               "a #{how} must not be recorded as proven non-delivery, which would licence a resend"
      end
    end
  end

  describe "rule 9: finalization is owned by the attempt, not by the message id" do
    # DEFENCE IN DEPTH, stated rather than implied. Two independent mechanisms keep a
    # closed attempt closed: `notify/2` demonitors and drops every owner entry for an id
    # once its status is terminal, and the `{:DOWN, ...}` clause additionally refuses to
    # act unless the CURRENT view is non-terminal AND its attempt is the one the dead
    # owner held. Removing either alone leaves these two rows green; removing both turns
    # them red. That is the measured mutation result, not an assumption: neither guard is
    # reachable on its own through the public API, so neither can be pinned on its own.
    test "an owner death after the attempt is terminal never rewrites the record", %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("terminal-owner")
      owner = spawn_owner()
      token = admit!(store, id, owner).operation_token
      assert :ok = ReceiptStore.transition(store, id, token, "delivered")

      # Observation is registered AFTER finalization, because a terminal transition clears
      # the observer list; this subscription therefore only sees what the DOWN does.
      :ok = ReceiptStore.observe(store, id)
      before = File.read!(ReceiptStore.path(store))
      kill_and_await(owner)

      refute_receive {:receipt_finalized, ^id, _}, 300

      assert File.read!(ReceiptStore.path(store)) == before,
             "the owner monitor may resolve an unresolved attempt; it may never reopen a closed one"

      assert {:ok, %{outcome: "delivered"}} = reconcile(store, id)
    end

    test "an owner death from a superseded attempt never resolves the live attempt",
         %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("superseded-owner")
      first_owner = spawn_owner()
      second_owner = spawn_owner()

      token = admit!(store, id, first_owner).operation_token
      assert :ok = ReceiptStore.transition(store, id, token, "not_delivered")
      assert %{delivery_attempt: 2} = admit!(store, id, second_owner)

      :ok = ReceiptStore.observe(store, id)
      before = File.read!(ReceiptStore.path(store))
      kill_and_await(first_owner)

      refute_receive {:receipt_finalized, ^id, _}, 300

      assert File.read!(ReceiptStore.path(store)) == before

      assert {:ok, %{status: "pending", delivery_attempt: 2}} = reconcile(store, id),
             "attempt 1 is closed and its owner is nobody; only attempt 2's owner may resolve it"
    end

    test "the monitored owner is the pane state machine, not the process that asked",
         %{inbox: inbox} do
      store = start_store!(inbox)
      sm = start_busy_pane!(store)
      id = message_id("owner-identity")

      caller = spawn_caller(sm, store, id)
      assert_receive {:send_result, {:queued, :busy}}, 5_000
      :ok = ReceiptStore.observe(store, id)

      kill_and_await(caller)

      refute_receive {:receipt_finalized, ^id, _}, 300

      assert {:ok, %{status: "queued"}} = queued_reconcile(store, id),
             "the requesting connection is not the operation owner; its death proves nothing " <>
               "about a paste the pane process is still responsible for"

      Process.unlink(sm)
      kill_and_await(sm)

      assert_receive {:receipt_finalized, ^id, "ambiguous"}, 1_000

      assert {:ok, %{outcome: "ambiguous"}} = queued_reconcile(store, id),
             "the pane process IS the owner, so losing it leaves the queued send unprovable"
    end
  end

  describe "rule 10: admission is atomic within one normalized inbox" do
    test "one normalized inbox has exactly one admission authority, addressed globally",
         %{inbox: inbox} do
      store = start_store!(inbox, :first)

      assert :global.whereis_name({ReceiptStore, Path.expand(inbox)}) == store,
             "the serializing process is addressed by the expanded path, which is what makes " <>
               "two spellings one authority"

      detour = Path.join([inbox, "..", Path.basename(inbox)])
      refute detour == inbox
      assert Path.expand(detour) == inbox

      assert {:error, reason} = start_store(detour, :second)

      assert inspect(reason) =~ "receipt_store_already_running",
             "an unnormalized second store would admit the same id a second time, because " <>
               "admission is serialized by the process, not by the file"
    end

    test "a reconcile read never admits an attempt", %{inbox: inbox} do
      store = start_store!(inbox)
      id = message_id("read-only")
      path = ReceiptStore.path(store)

      assert File.read!(path) == ""
      assert {:ok, %{outcome: "absent"}} = reconcile(store, id)

      assert File.read!(path) == "",
             "an absent answer is a read; admitting here would hand the caller a receipt " <>
               "nobody is pasting"

      token = admit!(store, id).operation_token
      assert :ok = ReceiptStore.transition(store, id, token, "not_delivered")
      before = File.read!(path)

      assert {:ok, %{outcome: "absent", status: "not_delivered", delivery_attempt: 1}} =
               reconcile(store, id)

      assert File.read!(path) == before,
             "a retryable absence is still only a read; attempt 2 is opened by admission alone"
    end
  end

  # ===== helpers =====

  defp start_store!(inbox, id \\ :store) do
    {:ok, pid} = start_store(inbox, id)
    pid
  end

  defp start_store(inbox, id) do
    start_supervised(
      Supervisor.child_spec({ReceiptStore, inbox: inbox}, id: id, restart: :temporary)
    )
  end

  defp stop_store(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid, :normal, 1_000)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
  end

  defp admit!(store, id, owner \\ nil) do
    {:ok, {:admitted, admission}} =
      ReceiptStore.admit(store, id, @pane, @payload, owner || self())

    admission
  end

  defp reconcile(store, id), do: ReceiptStore.reconcile(store, id, @pane, @payload, wait_ms: 0)

  defp queued_reconcile(store, id),
    do:
      ReceiptStore.reconcile(store, id, @pane, Payload.hash(Payload.new(@queued_text)), wait_ms: 0)

  defp message_id(seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  # Puts a fresh message into `status` and returns the token that still authorizes it.
  defp drive_to!(store, id, "pending"), do: admit!(store, id).operation_token

  defp drive_to!(store, id, status) do
    token = admit!(store, id).operation_token
    :ok = ReceiptStore.transition(store, id, token, status)
    token
  end

  # Appends one line that is valid in every respect the caller does not change: the key
  # set, the epoch, the identities, the sequence and the hash-chain link are all derived
  # from the real tail.
  defp append_chained!(path, edit) do
    bytes = File.read!(path)
    last_line = bytes |> String.split(~r/(?<=\n)/, trim: true) |> List.last()
    last = last_line |> String.trim_trailing("\n") |> Jason.decode!()

    forged =
      last
      |> edit.()
      |> Map.put("seq", last["seq"] + 1)
      |> Map.put(
        "prev_line_sha256",
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, last_line), case: :lower)
      )

    File.write!(path, Jason.encode!(forged) <> "\n", [:append])
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

  defp crashing_paste_fn do
    fn _pane_id, text ->
      cond do
        String.contains?(text, "RAISE") -> raise "the paste boundary blew up"
        String.contains?(text, "THROW") -> throw(:paste_vanished)
        true -> :ok
      end
    end
  end

  defp start_idle_pane!(store, paste_fn), do: start_pane!(store, "IDLE_MARKER", :idle, paste_fn)

  defp start_busy_pane!(store),
    do: start_pane!(store, "BUSY_MARKER", :busy, fn _pane_id, _text -> :ok end)

  # A pane that never leaves :busy never drains its queue, so the queued receipt stays
  # unresolved for the whole row and the only thing that can finalize it is owner loss.

  defp start_pane!(store, capture, expected_state, paste_fn) do
    {:ok, sm} =
      StateMachine.start_link(
        pane_id: @pane,
        receipt_store: store,
        capture_fn: fn _pane_id -> {:ok, capture} end,
        paste_fn: paste_fn,
        classifier: MarkerClassifier,
        poll_interval_ms: 10,
        idle_debounce_ms: 0
      )

    on_exit(fn ->
      if Process.alive?(sm) do
        try do
          :gen_statem.stop(sm, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert :ok = await_state(sm, expected_state)
    sm
  end

  # A separate process that issues the send and then stays alive, so that its death can
  # be distinguished from the pane process's death.
  defp spawn_caller(sm, store, id) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:send_result, StateMachine.send_receipted(sm, @queued_text, 5_000, id, store)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
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
