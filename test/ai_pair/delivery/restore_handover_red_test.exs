defmodule AiPair.Delivery.RestoreHandoverRedTest do
  @moduledoc """
  NS-15.G.003 S2 (design r4, RED design r3): the restore capability, the pane-pulled
  idempotent handover and holder fencing.

  Every row here is a DEPENDENT RED / contract row (RED design r3). Its first step restarts a
  store that holds an S2-epoch queued attempt and asserts the attempt is still queued; at
  Orrisd ff960018 restart finalizes it ambiguous, so the row fails there on the shared restore
  prerequisite only. The capability, handover and fence assertions after that step are the
  GREEN contract, each bite-proven at GREEN review. The S2 functions are reached through
  apply/3 so the file compiles against the base.

  Pane-level rows assert the paste_fn witness stays 0: quarantine refuses dispatch.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.Pane.StateMachine
  alias AiPair.Test.{FaultFs, MarkerClassifier}

  @pane "%restore_s2_b"

  setup do
    inbox = Path.join(System.tmp_dir!(), "restore_s2_b_#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    {:ok, inbox: inbox}
  end

  # ===== capability =====

  test "C1 a claim without the live capability is refused with no entries", c do
    store = restored_store!(c.inbox, ["c1"])
    assert {:ok, cap} = issue(store, @pane, make_ref())

    assert {:error, :not_authorized} = claim(store, @pane, nil)
    assert {:error, :not_authorized} = claim(store, "%other_pane", cap)
    assert {:error, :not_authorized} = claim(store, @pane, :crypto.strong_rand_bytes(32))

    assert {:ok, _fence} = fence(store, @pane, make_ref())
    assert {:error, :not_authorized} = claim(store, @pane, cap), "a fence revokes the capability"
    stop(store)
  end

  test "C2 only the restore issuer may issue or fence", c do
    store = restored_store!(c.inbox, ["c2"])
    task = Task.async(fn -> {issue(store, @pane, make_ref()), fence(store, @pane, make_ref())} end)
    assert {{:error, :not_issuer}, {:error, :not_issuer}} = Task.await(task)
    stop(store)
  end

  test "C3 a second capability for a pane with a live one is refused", c do
    store = restored_store!(c.inbox, ["c3"])
    assert {:ok, _cap} = issue(store, @pane, make_ref())
    assert {:error, _} = issue(store, @pane, make_ref())
    stop(store)
  end

  test "C4 the capability never appears in the registry, store state, logs or files", c do
    store = restored_store!(c.inbox, ["c4"])

    log =
      capture_log(fn ->
        {:ok, cap} = issue(store, @pane, make_ref())
        {:ok, _entries} = claim(store, @pane, cap)
        send(self(), {:cap, cap})
      end)

    assert_received {:cap, cap}
    encoded = Base.encode16(cap, case: :lower)

    for text <- [inspect(registry(store)), inspect(:sys.get_state(store)), log, tree_text(c.inbox)] do
      refute String.contains?(text, cap)
      refute String.contains?(text, encoded)
      refute String.contains?(text, inspect(cap))
    end

    stop(store)
  end

  # ===== handover =====

  test "H1 a repeated claim by the holder returns the same entries and tokens", c do
    store = restored_store!(c.inbox, ["h1-a", "h1-b"])
    {:ok, cap} = issue(store, @pane, make_ref())
    assert {:ok, first} = claim(store, @pane, cap)
    assert {:ok, ^first} = claim(store, @pane, cap)

    assert Enum.map(first, & &1.msg_id) == [id("h1-a"), id("h1-b")],
           "entries are in receipt seq order"

    stop(store)
  end

  test "H2 a claim that times out and is retried leaves each entry in the pane queue exactly once",
       c do
    store = restored_store!(c.inbox, ["h2-a", "h2-b"])
    {:ok, cap} = issue(store, @pane, make_ref())
    {:ok, pastes} = Agent.start_link(fn -> 0 end)

    :ok = :sys.suspend(store)
    sm = start_quarantined_pane!(store, cap, pastes, restore_claim_timeout_ms: 50)

    # Timeout witness: the pane retries only after its first claim call timed out, so two
    # claim requests from the pane in the suspended store's mailbox prove a timeout and a retry.
    assert eventually(fn -> pending_claims(store, sm) >= 2 end),
           "the pane never retried a timed-out claim"

    :ok = :sys.resume(store)
    assert eventually(fn -> StateMachine.pending_count(sm) == 2 end)
    settle()

    {_state, data} = :sys.get_state(sm)
    queued = :queue.to_list(data.pending_sends)
    assert Enum.count(queued, &(elem(&1, 3) == id("h2-a"))) == 1
    assert Enum.count(queued, &(elem(&1, 3) == id("h2-b"))) == 1
    assert [%{holder: holder}, _] = registry(store)[@pane]
    assert holder == sm

    # No stray late reply: the timed-out first claim's answer never reaches the pane's mailbox.
    {:messages, messages} = Process.info(sm, :messages)

    refute Enum.any?(messages, &match?({tag, _reply} when is_reference(tag) or is_list(tag), &1)),
           "a late claim reply was left in the pane's mailbox"

    assert Agent.get(pastes, & &1) == 0
    stop(store)
  end

  test "H3 a second live process with the capability is refused while the holder lives", c do
    store = restored_store!(c.inbox, ["h3"])
    {:ok, cap} = issue(store, @pane, make_ref())
    assert {:ok, _} = claim(store, @pane, cap)
    other = Task.async(fn -> claim(store, @pane, cap) end)
    assert {:error, :held} = Task.await(other)
    stop(store)
  end

  test "H4 the holder dies: the receipt stays queued, a re-claim gets new tokens, old tokens are void",
       c do
    store = restored_store!(c.inbox, ["h4"])
    {:ok, cap} = issue(store, @pane, make_ref())
    holder = Task.async(fn -> claim(store, @pane, cap) end)
    assert {:ok, [%{token: old}]} = Task.await(holder)
    settle()

    assert last_status(c.inbox, id("h4")) == {"queued", 1}
    assert [%{holder: nil}] = registry(store)[@pane]

    assert {:ok, [%{token: new}]} = claim(store, @pane, cap)
    refute new == old
    before = receipts(c.inbox)
    assert {:error, _} = ReceiptStore.transition(store, id("h4"), old, "not_delivered")
    assert receipts(c.inbox) == before
    stop(store)
  end

  test "H5 a verified-read failure at claim makes only that attempt ambiguous", c do
    store = restored_store!(c.inbox, ["h5-a", "h5-b", "h5-c"])
    {:ok, cap} = issue(store, @pane, make_ref())
    {:ok, pastes} = Agent.start_link(fn -> 0 end)

    # Tampered AFTER boot (boot verified it): only the pane's claim-time verified read sees it.
    bad = object_path(c.inbox, id("h5-b"), "h5-b bytes")
    File.write!(bad, "tampered after boot")
    File.chmod!(bad, 0o600)

    sm = start_quarantined_pane!(store, cap, pastes, [])

    assert eventually(fn -> last_status(c.inbox, id("h5-b")) == {"ambiguous", 1} end),
           "the pane's failed verified read must finalize that attempt"

    # The store appends the terminal status before it removes the object (one call, status first), and
    # the row above polls the log file, so it can observe the status between the two steps.
    assert eventually(fn -> not File.exists?(bad) end), "the failed object is removed"
    assert eventually(fn -> StateMachine.pending_count(sm) == 2 end)
    {_state, data} = :sys.get_state(sm)
    assert Enum.map(:queue.to_list(data.pending_sends), &elem(&1, 3)) == [id("h5-a"), id("h5-c")]
    assert Enum.map(registry(store)[@pane], & &1.msg_id) == [id("h5-a"), id("h5-c")]
    assert last_status(c.inbox, id("h5-a")) == {"queued", 1}
    assert last_status(c.inbox, id("h5-c")) == {"queued", 1}
    assert Agent.get(pastes, & &1) == 0
    stop(store)
  end

  # GREEN-review rows (G2 AMEND m_20261006T114603Z): restore_failed is restore-registry only.
  test "H5s a restored entry's restore_failed appends ambiguous, removes its object and drops the entry",
       c do
    store = restored_store!(c.inbox, ["h5s-a", "h5s-b"])
    {:ok, cap} = issue(store, @pane, make_ref())
    {:ok, entries} = claim(store, @pane, cap)
    bad = Enum.find(entries, &(&1.msg_id == id("h5s-b")))

    assert :ok = apply(ReceiptStore, :restore_failed, [store, bad.msg_id, 1, bad.token])
    assert last_status(c.inbox, id("h5s-b")) == {"ambiguous", 1}
    refute File.exists?(object_path(c.inbox, id("h5s-b"), "h5s-b bytes"))
    assert Enum.map(registry(store)[@pane], & &1.msg_id) == [id("h5s-a")]
    assert last_status(c.inbox, id("h5s-a")) == {"queued", 1}
    stop(store)
  end

  # GREEN-review row (G3 AMEND m_20261006T121051Z blocker 1): fail closed when the ambiguous
  # append behind restore_failed cannot be made durable.
  test "H5f an unrecorded restore_failed keeps the entry held, queued and tracked, and is retried",
       c do
    fs = FaultFs.new()
    store = restored_store!(c.inbox, ["h5f-a", "h5f-b"], fs)
    {:ok, cap} = issue(store, @pane, make_ref())
    {:ok, pastes} = Agent.start_link(fn -> 0 end)

    bad = object_path(c.inbox, id("h5f-b"), "h5f-b bytes")
    File.write!(bad, "tampered after boot")
    File.chmod!(bad, 0o600)

    # The next receipt append, restore_failed's ambiguous record, fails: nothing durable.
    FaultFs.inject(fs, :write, FaultFs.count(fs, :write) + 1, {:error, :eio})
    1 = :erlang.trace(store, true, [:receive])

    sm = start_quarantined_pane!(store, cap, pastes, restore_retry_ms: 20)

    assert eventually(fn -> restore_failed_calls(store, sm, id("h5f-b")) >= 2 end),
           "an unrecorded restore_failed is retried"

    :erlang.trace(store, false, [:all])
    {_state, data} = :sys.get_state(sm)
    assert Map.keys(data.restore_failures) == [id("h5f-b")]
    assert Enum.map(:queue.to_list(data.pending_sends), &elem(&1, 3)) == [id("h5f-a")]

    assert last_status(c.inbox, id("h5f-b")) == {"queued", 1},
           "an unrecorded failure must not be treated as finalized"

    assert %{holder: ^sm} = Enum.find(registry(store)[@pane], &(&1.msg_id == id("h5f-b")))
    assert Process.alive?(sm)
    assert Agent.get(pastes, & &1) == 0
    stop(store)
  end

  test "H5n restore_failed on an ordinary queued attempt with its valid token changes nothing",
       c do
    store = start_store!(c.inbox)
    text = "h5n bytes"
    {:ok, {:admitted, %{operation_token: token}}} = admit(store, id("h5n"), text)
    assert :ok = ReceiptStore.queue(store, id("h5n"), token, text)
    before_log = receipts(c.inbox)
    before_registry = registry(store)

    assert {:error, :not_restored} =
             apply(ReceiptStore, :restore_failed, [store, id("h5n"), 1, token])

    assert receipts(c.inbox) == before_log
    assert File.exists?(object_path(c.inbox, id("h5n"), text))
    assert registry(store) == before_registry
    assert last_status(c.inbox, id("h5n")) == {"queued", 1}
    stop(store)
  end

  test "H6 unclaimed entries stay listed while their receipts are queued", c do
    store = restored_store!(c.inbox, ["h6"])
    assert [%{msg_id: msg, holder: nil}] = registry(store)[@pane]
    assert msg == id("h6")
    stop(store)
  end

  # ===== fencing =====

  test "F1 a fence voids the live holder's tokens; the next admitted child gets the entries", c do
    store = restored_store!(c.inbox, ["f1-a", "f1-b"])
    {:ok, cap} = issue(store, @pane, make_ref())
    parent = self()

    holder =
      spawn(fn ->
        send(parent, {:claimed, claim(store, @pane, cap)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:claimed, {:ok, [%{token: old_a} | _]}}
    assert {:ok, _fence} = fence(store, @pane, make_ref())

    before = receipts(c.inbox)

    assert {:error, :stale_token} =
             ReceiptStore.transition(store, id("f1-a"), old_a, "not_delivered")

    assert receipts(c.inbox) == before
    assert {:error, :not_authorized} = claim(store, @pane, cap)

    ref = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}
    settle()

    assert {:ok, cap2} = issue(store, @pane, make_ref())
    assert {:ok, entries} = claim(store, @pane, cap2)
    assert Enum.map(entries, & &1.msg_id) == [id("f1-a"), id("f1-b")]
    refute hd(entries).token == old_a
    assert last_status(c.inbox, id("f1-a")) == {"queued", 1}
    stop(store)
  end

  test "F2 a fence from a process other than the issuer changes nothing", c do
    store = restored_store!(c.inbox, ["f2"])
    {:ok, cap} = issue(store, @pane, make_ref())
    {:ok, [%{token: token}]} = claim(store, @pane, cap)

    assert {:error, :not_issuer} = Task.await(Task.async(fn -> fence(store, @pane, make_ref()) end))
    assert {:ok, [%{token: ^token}]} = claim(store, @pane, cap)
    stop(store)
  end

  test "F3 a capability cannot be issued while the fenced holder is alive", c do
    store = restored_store!(c.inbox, ["f3"])
    {:ok, cap} = issue(store, @pane, make_ref())
    parent = self()

    spawn(fn ->
      send(parent, {:claimed, claim(store, @pane, cap)})
      receive do: (:stop -> :ok)
    end)

    assert_receive {:claimed, {:ok, _}}
    assert {:ok, _} = fence(store, @pane, make_ref())
    assert {:error, :fenced_holder_alive} = issue(store, @pane, make_ref())
    stop(store)
  end

  test "F4 a stop with no replacement leaves the entries fenced, listed and queued", c do
    store = restored_store!(c.inbox, ["f4"])
    {:ok, cap} = issue(store, @pane, make_ref())
    parent = self()

    holder =
      spawn(fn ->
        send(parent, {:claimed, claim(store, @pane, cap)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:claimed, {:ok, [%{token: old}]}}
    assert {:ok, _} = fence(store, @pane, make_ref())

    # The holder is still alive here: fenced, listed and queued.
    assert Process.alive?(holder)
    assert [%{msg_id: msg, holder: {:fenced, ^holder}}] = registry(store)[@pane]
    assert msg == id("f4")
    assert last_status(c.inbox, msg) == {"queued", 1}

    ref = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}
    settle()

    # Stopped with no replacement: unheld, still listed and queued, old token void.
    assert [%{msg_id: ^msg, holder: nil}] = registry(store)[@pane]
    assert last_status(c.inbox, msg) == {"queued", 1}
    before = receipts(c.inbox)
    assert {:error, _} = ReceiptStore.transition(store, msg, old, "not_delivered")
    assert receipts(c.inbox) == before
    stop(store)
  end

  # ===== helpers =====

  # Queues one attempt per seed under a real store, restarts it, and asserts the shared restore
  # prerequisite: every attempt is still queued after the restart (ambiguous at the base).
  defp restored_store!(inbox, seeds, revived_fs \\ SystemFs.new()) do
    first = start_store!(inbox)

    for seed <- seeds do
      {:ok, {:admitted, %{operation_token: token}}} = admit(first, id(seed), seed <> " bytes")
      assert :ok = ReceiptStore.queue(first, id(seed), token, seed <> " bytes")
    end

    stop(first)
    revived = start_store!(inbox, revived_fs)

    for seed <- seeds do
      assert last_status(inbox, id(seed)) == {"queued", 1},
             "shared restore prerequisite: a queued attempt of an attested epoch stays queued"
    end

    revived
  end

  defp start_quarantined_pane!(store, cap, pastes, opts) do
    {:ok, sm} =
      StateMachine.start_link(
        [
          pane_id: @pane,
          capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
          paste_fn: fn _, _ -> Agent.update(pastes, &(&1 + 1)) end,
          classifier: MarkerClassifier,
          poll_interval_ms: 5,
          idle_debounce_ms: 0,
          receipt_store: store,
          quarantine_token: "q_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          restore_capability: cap
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(sm), do: :gen_statem.stop(sm, :normal, 500) end)
    sm
  end

  defp issue(store, pane, ref),
    do: apply(ReceiptStore, :issue_restore_capability, [store, pane, ref])

  defp claim(store, pane, cap), do: apply(ReceiptStore, :claim_restored, [store, pane, cap])
  defp fence(store, pane, ref), do: apply(ReceiptStore, :fence_restore, [store, pane, ref])
  defp registry(store), do: apply(ReceiptStore, :restore_registry, [store])

  defp start_store!(inbox, fs \\ SystemFs.new()) do
    assert {:ok, pid} = GenServer.start(ReceiptStore, inbox: inbox, fs: fs, restore_issuer: self())

    pid
  end

  defp stop(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))
  defp settle, do: Process.sleep(50)

  # Claim requests from `from` waiting in the (suspended) store's mailbox. Contract: the
  # pane's claim is the GenServer call request {:claim_restored, pane, capability}.
  defp pending_claims(store, from) do
    {:messages, messages} = Process.info(store, :messages)

    Enum.count(messages, fn
      {:"$gen_call", {^from, _tag}, {:claim_restored, @pane, _cap}} -> true
      _other -> false
    end)
  end

  # restore_failed calls the store received from `from` for `msg`, read from this process's
  # trace messages (kept in the mailbox; counted, not consumed).
  defp restore_failed_calls(store, from, msg) do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.count(messages, fn
      {:trace, ^store, :receive, {:"$gen_call", {^from, _}, {:restore_failed, ^msg, _, _}}} -> true
      _ -> false
    end)
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

  defp admit(store, msg, text), do: ReceiptStore.admit(store, msg, @pane, hash(text), self())

  defp receipts(inbox), do: File.read!(Path.join([inbox, "delivery", "receipts.jsonl"]))

  defp last_status(inbox, msg) do
    inbox
    |> receipts()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg))
    |> Enum.map(&{&1["status"], &1["delivery_attempt"]})
    |> List.last()
  end

  defp object_path(inbox, msg, text) do
    "sha256:" <> hex = hash(text)
    Path.join([inbox, "delivery", "payloads", "#{msg}.1.#{hex}.payload"])
  end

  # Every regular file's bytes under the inbox, for the capability-leak check.
  defp tree_text(inbox) do
    inbox
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&(File.lstat!(&1).type == :regular))
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp hash(text), do: Payload.hash(Payload.new(text))
  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
end
