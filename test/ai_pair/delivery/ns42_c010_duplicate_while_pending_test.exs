defmodule AiPair.Delivery.NS42C010DuplicateWhilePendingTest do
  @moduledoc """
  NS-42.C.010: a duplicate or racing send of the same msg id never opens a second paste,
  and never waits behind the first attempt. This holds while the first attempt is still
  pending inside the pane, when two sends race for the same id, and after a proven
  non-delivery.

  The harness is copied, not shared, from
  `test/ai_pair/delivery/ns42_c008_timeout_and_validation_test.exs`:

    * a `ReceiptStore` on a unique inbox and a real `AiPair.IPC.Server` with that store;
    * raw JSON frames over the UNIX socket (the socket receive timeout for reconcile
      frames is 3_000 ms);
    * a msg id builder and a v2 reconcile frame with a per-call `wait_ms`.

  Panes are started only through `AiPair.PaneSupervisor.start_pane/2`. Every option list
  is literal and carries both `:capture_fn` and `:paste_fn`. Pane ids are built at run
  time as `"%" <> "ns42_c010_" <> n <> "_" <> tag`. Each is checked with
  `ReceiptLog.valid_pane?/1` and refuted against the tmux-shaped numeric form before use.

  Detectors, shared by every row and its control:

    * a recording `paste_fn` that counts pastes per `{pane, text}`, with a gate-once. When
      the gate is armed, the NEXT paste sends `{:paste_started, pane_pid, text}` to the
      test and blocks until `{:release_paste, :ok}`. After 5_000 ms it gives up with
      `{:error, :gate_timeout}`;
    * `statuses(id)` from the receipt log, as `[{attempt, status}]`;
    * v2 reconcile over the socket, with `wait_ms` chosen per call;
    * the number of `{:"$gen_call", _, {:send_receipted, _, _, id, _}}` messages in the
      pane's mailbox;
    * the store's registered reconcile waiters for an id, read from the `waiters` map in
      `ReceiptStore` state with `:sys.get_state/1`;
    * timed reconcile frames, stamped in native units after connect, immediately before
      the request is written, and again when the reply is read.

  Paste counts are asserted as DELTAS within a row. Each row's control runs first, on
  the same pane, text and detectors as the row, so the row's own count is measured from
  the value the control left.

  Rows (control named per row):

    * T1: a msg id reused while its first attempt is pending. The duplicate replies
      while the first send is still inside the pane, as `pending` attempt 1. The first
      send is then `sent`, with one paste. Control C-T1: a fresh id with the same text
      does NOT reply until release, and then two pastes are recorded.
    * T1-W, the wake: a reconcile with `wait_ms: 2_000`, issued while the send is held,
      is observed registered as a store waiter before the release, was written before
      the release, and answers `delivered` only after it. Control C-T1-W: `wait_ms: 0`
      answers at once as `ambiguous`/`pending`.
    * W2, the timeout: a reconcile with `wait_ms: 150` and NO release is observed
      registered as a store waiter and answers `ambiguous`/`pending` at least 150 ms after
      its request was written, with the waiter gone and no finalize in the log. T1-W is
      its control.
    * T3, a TOCTOU race on one id: the pane is held inside an untracked v1 paste while two
      sends of the same id queue in its mailbox. Exactly one is sent and the other is a
      duplicate, with one paste. Control C-T3: two different ids, both sent, two pastes.
    * T4, a conflict while pending: the same id with other text, or on another pane,
      answers `conflict` at once and pastes nothing. Control: different ids wait for,
      or reach, their own pastes.
    * T5, a sequential retry after proven non-delivery: a pane reaped dead refuses
      `pane_dead` and records attempt 1 `not_delivered`. After a restart the resend is
      attempt 2, `delivered`, with one paste. Control: an id delivered on the live pane
      and resent is a duplicate at attempt 1, with no attempt 2.
    * T6, racing retries after non-delivery: after attempt 1 is `not_delivered`, the T3
      race on one id opens exactly one attempt 2, with one paste. Before the release a
      reconcile still answers `absent` on attempt 1. Control: two different ids race,
      both are sent and each reaches attempt 2.

  H-4 (main `66de070c`) moves an idle pane to `:unknown` on its first `pane_gone`
  capture. T5 and T6 were checked against it: with threshold 2 and grace 0 the pane still
  reaches `:dead`, confirmed by `[:ai_pair, :pane, :reaped]` telemetry and by `state/1`.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns42_c010_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})
    server = :"ns42_c010_server_#{n}"
    start_supervised!({Server, inbox: inbox, name: server, receipt_store: store})

    # Paste counts per {pane, text}, and the gate-once flag.
    paste = start_supervised!({Agent, fn -> %{counts: %{}, armed: false} end})

    handler = "ns42_c010_" <> Integer.to_string(n)

    :ok =
      :telemetry.attach(
        handler,
        [:ai_pair, :pane, :reaped],
        &__MODULE__.forward_reaped/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok,
     n: n,
     store: store,
     paste: paste,
     log: ReceiptStore.path(store),
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  @doc false
  def forward_reaped(_event, _m, %{pane_id: pane}, test), do: send(test, {:reaped, pane})

  # ===== T1: msg id reuse while pending =====

  describe "T1: a msg id reused while its first attempt is pending" do
    test "the duplicate replies pending at once; one paste; control: a fresh id waits", c do
      p = pane!(c, "a")
      sm = start_idle!(c, p)
      x = "T1 X " <> Integer.to_string(c.n)

      # Control C-T1: a fresh id with the same text waits for the held paste.
      base = pastes(c, p, x)
      arm(c)
      held = Task.async(fn -> send_v2!(c, p, id(c, "t1-hold"), x) end)
      assert_receive {:paste_started, ^sm, ^x}, 2_000
      fresh = Task.async(fn -> send_v2!(c, p, id(c, "t1-fresh"), x) end)
      early = Task.yield(fresh, 200)
      assert early == nil, "C-T1 fresh id must wait; observed " <> inspect(early)
      release(sm)
      assert_sent(Task.await(held, 6_000), "C-T1 held")
      assert_sent(Task.await(fresh, 6_000), "C-T1 fresh")
      assert_delta(c, p, x, base, 2, "C-T1")

      # T1: the same id while the first attempt is inside the pane.
      id1 = id(c, "t1")
      base = pastes(c, p, x)
      arm(c)
      a = Task.async(fn -> send_v2!(c, p, id1, x) end)
      assert_receive {:paste_started, ^sm, ^x}, 2_000

      dup = send_v2!(c, p, id1, x)
      still = Task.yield(a, 0)
      assert still == nil, "T1 A must still be inside the pane; observed " <> inspect(still)

      assert dup == %{
               "ok" => true,
               "duplicate" => true,
               "status" => "pending",
               "delivery_attempt" => 1,
               "payload_hash" => hash(x),
               "protocol_version" => 2,
               "msg_id" => id1,
               "pane_id" => p
             },
             "T1 duplicate; observed " <> inspect(dup)

      release(sm)
      assert_sent(Task.await(a, 6_000), "T1 A")
      assert_delta(c, p, x, base, 1, "T1")
      assert_statuses(c, id1, [{1, "pending"}, {1, "delivered"}], "T1")

      third = send_v2!(c, p, id1, x)

      assert {third["duplicate"], third["status"], third["delivery_attempt"]} ==
               {true, "delivered", 1},
             "T1 third send; observed " <> inspect(third)

      assert_delta(c, p, x, base, 1, "T1 after third")
    end
  end

  # ===== T1-W / W2: reconcile waits =====

  describe "T1-W and W2: reconcile while the first attempt is held" do
    test "T1-W: wait_ms 2_000 wakes on release with delivered; control: wait_ms 0 is " <>
           "ambiguous at once",
         c do
      p = pane!(c, "w")
      sm = start_idle!(c, p)
      t = "T1-W text " <> Integer.to_string(c.n)

      # Control C-T1-W: wait_ms 0 answers at once.
      idc = id(c, "t1w-control")
      base = pastes(c, p, t)
      arm(c)
      held = Task.async(fn -> send_v2!(c, p, idc, t) end)
      assert_receive {:paste_started, ^sm, ^t}, 2_000
      dup = send_v2!(c, p, idc, t)
      assert dup == typed_duplicate(idc, p, t), "C-T1-W duplicate; observed " <> inspect(dup)
      now = reconcile!(c, p, idc, t, 0)

      assert {now["outcome"], now["status"], now["delivery_attempt"]} ==
               {"ambiguous", "pending", 1},
             "C-T1-W wait 0; observed " <> inspect(now)

      release(sm)
      assert_sent(Task.await(held, 6_000), "C-T1-W held")
      assert_delta(c, p, t, base, 1, "C-T1-W")

      # T1-W: wait_ms 2_000 is woken by the release.
      idw = id(c, "t1w")
      base = pastes(c, p, t)
      arm(c)
      s = Task.async(fn -> send_v2!(c, p, idw, t) end)
      assert_receive {:paste_started, ^sm, ^t}, 2_000
      dup = send_v2!(c, p, idw, t)
      assert dup == typed_duplicate(idw, p, t), "T1-W duplicate; observed " <> inspect(dup)
      assert_waiters(c, idw, 0, "T1-W before the reconcile")

      # w_sent_at is stamped after connect, immediately before the request is written.
      w = Task.async(fn -> timed_reconcile!(c, p, idw, t, 2_000) end)

      # The release waits for the store's own registration of this waiter.
      assert_waiters(c, idw, 1, "T1-W registered before release")
      early = Task.yield(w, 200)
      assert early == nil, "T1-W must wait while held; observed " <> inspect(early)
      # Native units: a millisecond stamp can tie with the wake it precedes.
      released_at = now_native()
      release(sm)
      {reply, w_sent_at, w_received_at} = Task.await(w, 3_000)

      assert w_sent_at < released_at,
             "T1-W request written before release; observed sent #{w_sent_at}, " <>
               "released #{released_at}"

      assert w_received_at > released_at,
             "T1-W answered after release; observed received #{w_received_at}, " <>
               "released #{released_at}"

      waited_ms = System.convert_time_unit(w_received_at - w_sent_at, :native, :millisecond)
      assert waited_ms < 2_000, "T1-W woken before its bound; observed #{waited_ms} ms"

      assert {reply["outcome"], reply["status"], reply["delivery_attempt"]} ==
               {"delivered", "delivered", 1},
             "T1-W reply; observed " <> inspect(reply)

      assert_waiters(c, idw, 0, "T1-W after the wake")
      assert_sent(Task.await(s, 6_000), "T1-W send")
      assert_delta(c, p, t, base, 1, "T1-W")
      assert_statuses(c, idw, [{1, "pending"}, {1, "delivered"}], "T1-W")
    end

    test "W2: wait_ms 150 with no release answers ambiguous after at least 150 ms", c do
      p = pane!(c, "t")
      sm = start_idle!(c, p)
      t = "W2 text " <> Integer.to_string(c.n)
      id2 = id(c, "w2")
      base = pastes(c, p, t)

      arm(c)
      a = Task.async(fn -> send_v2!(c, p, id2, t) end)
      assert_receive {:paste_started, ^sm, ^t}, 2_000
      dup = send_v2!(c, p, id2, t)
      assert dup == typed_duplicate(id2, p, t), "W2 duplicate; observed " <> inspect(dup)
      assert_waiters(c, id2, 0, "W2 before the reconcile")

      # The clock starts after connect, immediately before the request is written.
      w = Task.async(fn -> timed_reconcile!(c, p, id2, t, 150) end)

      # The wait is the store's: its waiter for id2 is registered while the request is open.
      assert_waiters(c, id2, 1, "W2 registered")
      {reply, sent_at, received_at} = Task.await(w, 3_000)
      elapsed = System.convert_time_unit(received_at - sent_at, :native, :millisecond)

      assert elapsed >= 150 and elapsed < 2_000, "W2 elapsed; observed #{elapsed} ms"

      # The timeout's own answer: ambiguous on a record still pending, with the waiter gone
      # and no finalize in the log, so no notify woke it.
      assert {reply["outcome"], reply["status"], reply["delivery_attempt"]} ==
               {"ambiguous", "pending", 1},
             "W2 reply; observed " <> inspect(reply)

      assert_waiters(c, id2, 0, "W2 after the timeout")
      assert_statuses(c, id2, [{1, "pending"}], "W2 while held")

      release(sm)
      assert_sent(Task.await(a, 6_000), "W2 A")
      assert_statuses(c, id2, [{1, "pending"}, {1, "delivered"}], "W2 after release")
      assert_delta(c, p, t, base, 1, "W2")
    end
  end

  # ===== T3: TOCTOU race on one id =====

  describe "T3: two sends of the same id race into a held pane" do
    test "exactly one is sent and one is a duplicate; control: two ids both paste", c do
      p = pane!(c, "r")
      sm = start_idle!(c, p)
      z = "T3 Z " <> Integer.to_string(c.n)

      # Control C-T3: two different ids.
      {id5, id6} = {id(c, "t3-a"), id(c, "t3-b")}
      base = pastes(c, p, z)
      {block, r1, r2} = race!(c, p, sm, {id5, z}, {id6, z})
      assert_mailbox(sm, id5, 1, "C-T3 id5")
      assert_mailbox(sm, id6, 1, "C-T3 id6")
      release(sm)
      assert_v1_sent(Task.await(block, 6_000), "C-T3 block")
      assert_sent(Task.await(r1, 6_000), "C-T3 r1")
      assert_sent(Task.await(r2, 6_000), "C-T3 r2")
      assert_delta(c, p, z, base, 2, "C-T3")

      # T3: the same id twice.
      id4 = id(c, "t3")
      base = pastes(c, p, z)
      {block, r1, r2} = race!(c, p, sm, {id4, z}, {id4, z})
      assert_mailbox(sm, id4, 2, "T3 id4")
      pre = reconcile!(c, p, id4, z, 0)

      assert pre["outcome"] == "absent" and not Map.has_key?(pre, "delivery_attempt"),
             "T3 nothing admitted before release; observed " <> inspect(pre)

      release(sm)
      assert_v1_sent(Task.await(block, 6_000), "T3 block")
      replies = Enum.map([r1, r2], &Task.await(&1, 6_000))
      sent = Enum.filter(replies, &(&1["status"] == "sent" and not Map.has_key?(&1, "duplicate")))
      dups = Enum.filter(replies, &(&1["duplicate"] == true))

      assert length(sent) == 1 and length(dups) == 1,
             "T3 one sent and one duplicate; observed " <> inspect(replies)

      [d] = dups

      assert {d["status"], d["delivery_attempt"]} == {"delivered", 1},
             "T3 duplicate; observed " <> inspect(d)

      assert_delta(c, p, z, base, 1, "T3")
      assert_statuses(c, id4, [{1, "pending"}, {1, "delivered"}], "T3")
    end
  end

  # ===== T4: conflict while pending =====

  describe "T4: the same id with other text or another pane while pending" do
    test "answers conflict at once with no paste; control: different ids reach their " <>
           "pastes",
         c do
      pp = pane!(c, "p")
      q = pane!(c, "q")
      sm = start_idle!(c, pp)
      _q_sm = start_idle!(c, q)
      x2 = "T4 X2 " <> Integer.to_string(c.n)
      y2 = "T4 Y2 " <> Integer.to_string(c.n)

      # Control: different ids.
      {y_base, q_base} = {pastes(c, pp, y2), pane_pastes(c, q)}
      arm(c)
      h = Task.async(fn -> send_v2!(c, pp, id(c, "t4-hold"), x2) end)
      assert_receive {:paste_started, ^sm, ^x2}, 2_000
      c8 = Task.async(fn -> send_v2!(c, pp, id(c, "t4-8"), y2) end)
      early = Task.yield(c8, 200)
      assert early == nil, "T4 control P send waits; observed " <> inspect(early)
      assert_sent(send_v2!(c, q, id(c, "t4-9"), x2), "T4 control Q send at once")
      release(sm)
      assert_sent(Task.await(h, 6_000), "T4 control hold")
      assert_sent(Task.await(c8, 6_000), "T4 control P send")
      assert_delta(c, pp, y2, y_base, 1, "T4 control Y2")
      qp = pane_pastes(c, q) - q_base
      assert qp == 1, "T4 control Q pastes; observed #{qp}"

      # T4: conflicts while id7 is pending on P.
      id7 = id(c, "t4")
      {y_base, q_base} = {pastes(c, pp, y2), pane_pastes(c, q)}
      arm(c)
      h7 = Task.async(fn -> send_v2!(c, pp, id7, x2) end)
      assert_receive {:paste_started, ^sm, ^x2}, 2_000

      other_text = send_v2!(c, pp, id7, y2)
      other_pane = send_v2!(c, q, id7, x2)
      still = Task.yield(h7, 0)
      assert still == nil, "T4 answered while held; observed " <> inspect(still)

      for {reply, pane} <- [{other_text, pp}, {other_pane, q}] do
        assert reply == %{
                 "ok" => false,
                 "error" => "conflict",
                 "protocol_version" => 2,
                 "msg_id" => id7,
                 "pane_id" => pane
               },
               "T4 conflict; observed " <> inspect(reply)

        refute Map.has_key?(reply, "status"), "T4 no status; observed " <> inspect(reply)
      end

      release(sm)
      assert_sent(Task.await(h7, 6_000), "T4 hold")
      assert_statuses(c, id7, [{1, "pending"}, {1, "delivered"}], "T4 id7")
      assert_delta(c, pp, y2, y_base, 0, "T4 Y2")
      qp = pane_pastes(c, q) - q_base
      assert qp == 0, "T4 Q pastes; observed #{qp}"
    end
  end

  # ===== T5 / T6: after proven non-delivery =====

  describe "T5: a sequential retry after proven non-delivery" do
    test "attempt 2 is delivered once; control: a delivered id resent is a duplicate", c do
      d = pane!(c, "dd")
      {sm, capture} = start_switchable!(c, d)
      v = "T5 V " <> Integer.to_string(c.n)

      # Control: delivered on the live pane, then resent.
      idc = id(c, "t5-control")
      assert_sent(send_v2!(c, d, idc, v), "T5 control")
      again = send_v2!(c, d, idc, v)

      assert {again["duplicate"], again["status"], again["delivery_attempt"]} ==
               {true, "delivered", 1},
             "T5 control resend; observed " <> inspect(again)

      assert_statuses(c, idc, [{1, "pending"}, {1, "delivered"}], "T5 control")
      base = pastes(c, d, v)

      # Dead by the reaper (H-4: idle -> unknown on the first pane_gone, then dead).
      kill!(sm, d, capture)

      id10 = id(c, "t5")
      refused = send_v2!(c, d, id10, v)
      assert refused["error"] == "pane_dead", "T5 refusal; observed " <> inspect(refused)
      assert_statuses(c, id10, [{1, "pending"}, {1, "not_delivered"}], "T5 refused")

      restart!(c, d)
      assert_sent(send_v2!(c, d, id10, v), "T5 resend")

      assert_statuses(
        c,
        id10,
        [{1, "pending"}, {1, "not_delivered"}, {2, "pending"}, {2, "delivered"}],
        "T5"
      )

      assert_delta(c, d, v, base, 1, "T5")
    end
  end

  describe "T6: racing retries after non-delivery" do
    test "the same id opens exactly one attempt 2; control: two ids each reach attempt 2",
         c do
      e = pane!(c, "ee")
      {sm, capture} = start_switchable!(c, e)
      w = "T6 W " <> Integer.to_string(c.n)
      {id11, id12, id13} = {id(c, "t6-a"), id(c, "t6"), id(c, "t6-b")}

      kill!(sm, e, capture)

      for i <- [id11, id12, id13] do
        r = send_v2!(c, e, i, w)
        assert r["error"] == "pane_dead", "T6 attempt 1 refusal; observed " <> inspect(r)
        assert_statuses(c, i, [{1, "pending"}, {1, "not_delivered"}], "T6 attempt 1")
      end

      sm = restart!(c, e)

      # Control: two different ids race.
      base = pastes(c, e, w)
      {block, r1, r2} = race!(c, e, sm, {id11, w}, {id13, w})
      assert_mailbox(sm, id11, 1, "T6 control id11")
      assert_mailbox(sm, id13, 1, "T6 control id13")
      release(sm)
      assert_v1_sent(Task.await(block, 6_000), "T6 control block")
      assert_sent(Task.await(r1, 6_000), "T6 control r1")
      assert_sent(Task.await(r2, 6_000), "T6 control r2")
      assert_delta(c, e, w, base, 2, "T6 control")

      for i <- [id11, id13] do
        assert_statuses(
          c,
          i,
          [{1, "pending"}, {1, "not_delivered"}, {2, "pending"}, {2, "delivered"}],
          "T6 control"
        )
      end

      # T6: the same id races.
      base = pastes(c, e, w)
      {block, r1, r2} = race!(c, e, sm, {id12, w}, {id12, w})
      assert_mailbox(sm, id12, 2, "T6 id12")
      pre = reconcile!(c, e, id12, w, 0)

      # Attempt 1 is recorded not_delivered, so the pre-release marker is outcome absent on
      # attempt 1: no attempt 2 is admitted before release.
      assert {pre["outcome"], pre["status"], pre["delivery_attempt"]} ==
               {"absent", "not_delivered", 1},
             "T6 nothing admitted before release; observed " <> inspect(pre)

      release(sm)
      assert_v1_sent(Task.await(block, 6_000), "T6 block")
      replies = Enum.map([r1, r2], &Task.await(&1, 6_000))
      recorded = statuses(c, id12)
      twos = Enum.count(recorded, &(&1 == {2, "pending"}))
      assert twos == 1, "T6 exactly one attempt 2; observed " <> inspect(recorded)

      assert recorded == [
               {1, "pending"},
               {1, "not_delivered"},
               {2, "pending"},
               {2, "delivered"}
             ],
             "T6 id12 statuses; observed " <> inspect(recorded)

      assert Enum.sort_by(replies, &Map.has_key?(&1, "duplicate")) |> Enum.map(&kind/1) ==
               [:sent, {:duplicate, "delivered", 2}],
             "T6 replies; observed " <> inspect(replies)

      assert_delta(c, e, w, base, 1, "T6")
    end
  end

  # ===== pane starters (every option list is literal) =====

  defp paste_fn(c) do
    paste = c.paste
    test = self()

    fn pane, text ->
      gated =
        Agent.get_and_update(paste, fn s ->
          counts = Map.update(s.counts, {pane, text}, 1, &(&1 + 1))
          {s.armed, %{s | counts: counts, armed: false}}
        end)

      if gated do
        send(test, {:paste_started, self(), text})

        receive do
          {:release_paste, result} -> result
        after
          5_000 -> {:error, :gate_timeout}
        end
      else
        :ok
      end
    end
  end

  defp start_idle!(c, pane) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    assert :ok = await_state(sm, :idle)
    sm
  end

  defp start_switchable!(c, pane) do
    # Unlinked, and stopped only after the pane (on_exit runs in reverse order).
    {:ok, capture} = Agent.start(fn -> {:ok, "IDLE_MARKER"} end)
    on_exit(fn -> Agent.stop(capture) end)

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> Agent.get(capture, & &1) end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        pane_gone_threshold: 2,
        pane_gone_grace_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    assert :ok = await_state(sm, :idle)
    {sm, capture}
  end

  defp kill!(sm, pane, capture) do
    Agent.update(capture, fn _ -> {:error, :pane_gone} end)
    assert_receive {:reaped, ^pane}, 2_000
    state = StateMachine.state(sm)
    assert state == :dead, "reaped pane state; observed " <> inspect(state)
  end

  defp restart!(c, pane) do
    assert :ok = PaneSupervisor.stop_pane(pane)
    assert :ok = await_unregistered(pane)
    start_idle!(c, pane)
  end

  # ===== detectors =====

  defp arm(c), do: Agent.update(c.paste, &%{&1 | armed: true})
  defp release(sm), do: send(sm, {:release_paste, :ok})

  defp pastes(c, pane, text), do: Agent.get(c.paste, &Map.get(&1.counts, {pane, text}, 0))

  defp pane_pastes(c, pane) do
    Agent.get(c.paste, fn s ->
      s.counts
      |> Enum.filter(fn {{p, _}, _} -> p == pane end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()
    end)
  end

  defp assert_delta(c, pane, text, base, expected, label) do
    delta = pastes(c, pane, text) - base
    assert delta == expected, label <> " pastes; observed #{delta}"
  end

  defp statuses(c, id) do
    c.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  defp assert_statuses(c, id, expected, label) do
    observed = statuses(c, id)
    assert observed == expected, label <> " statuses; observed " <> inspect(observed)
  end

  defp mailbox_calls(sm, id) do
    {:messages, messages} = Process.info(sm, :messages)
    Enum.count(messages, &match?({:"$gen_call", _, {:send_receipted, _, _, ^id, _}}, &1))
  end

  defp assert_mailbox(sm, id, count, label, timeout \\ 2_000) do
    deadline = now_ms() + timeout

    result =
      Stream.repeatedly(fn ->
        seen = mailbox_calls(sm, id)

        cond do
          seen >= count -> {:ok, seen}
          now_ms() > deadline -> {:timeout, seen}
          true -> Process.sleep(5) && :retry
        end
      end)
      |> Enum.find(&(&1 != :retry))

    assert result == {:ok, count}, label <> " mailbox calls; observed " <> inspect(result)
  end

  # The store's registered reconcile waiters for `id` (`ReceiptStore` state `waiters`).
  defp waiters(c, id) do
    c.store |> :sys.get_state() |> Map.fetch!(:waiters) |> Enum.count(&(elem(&1, 1).id == id))
  end

  defp assert_waiters(c, id, count, label, timeout \\ 2_000) do
    deadline = now_ms() + timeout

    result =
      Stream.repeatedly(fn ->
        seen = waiters(c, id)

        cond do
          seen == count -> {:ok, seen}
          now_ms() > deadline -> {:timeout, seen}
          true -> Process.sleep(1) && :retry
        end
      end)
      |> Enum.find(&(&1 != :retry))

    assert result == {:ok, count}, label <> " store waiters; observed " <> inspect(result)
  end

  defp typed_duplicate(id, pane, text) do
    %{
      "ok" => true,
      "duplicate" => true,
      "status" => "pending",
      "delivery_attempt" => 1,
      "payload_hash" => hash(text),
      "protocol_version" => 2,
      "msg_id" => id,
      "pane_id" => pane
    }
  end

  # Holds the pane inside an untracked v1 paste, then starts two v2 sends behind it.
  defp race!(c, pane, sm, {id_a, text_a}, {id_b, text_b}) do
    arm(c)
    block_text = "BLOCK " <> Integer.to_string(System.unique_integer([:positive]))
    block = Task.async(fn -> send_v1!(c, pane, block_text) end)
    assert_receive {:paste_started, ^sm, ^block_text}, 2_000
    r1 = Task.async(fn -> send_v2!(c, pane, id_a, text_a) end)
    r2 = Task.async(fn -> send_v2!(c, pane, id_b, text_b) end)
    {block, r1, r2}
  end

  defp kind(%{"duplicate" => true} = r), do: {:duplicate, r["status"], r["delivery_attempt"]}
  defp kind(%{"status" => "sent"}), do: :sent
  defp kind(other), do: {:other, other}

  defp assert_sent(reply, label) do
    assert {reply["ok"], reply["status"], Map.has_key?(reply, "duplicate")} ==
             {true, "sent", false},
           label <> "; observed " <> inspect(reply)
  end

  defp assert_v1_sent(reply, label) do
    assert {reply["ok"], reply["status"]} == {true, "sent"},
           label <> "; observed " <> inspect(reply)
  end

  # ===== frames =====

  defp pane!(c, tag) do
    pane = "%" <> "ns42_c010_" <> Integer.to_string(c.n) <> "_" <> tag
    assert ReceiptLog.valid_pane?(pane), "pane grammar; observed " <> inspect(pane)
    refute pane =~ ~r/\A%[0-9]+\z/, "pane must not be tmux-shaped; observed " <> inspect(pane)
    pane
  end

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp send_v2!(c, pane, id, text) do
    frame!(
      c,
      %{
        "cmd" => "send",
        "protocol_version" => 2,
        "pane_id" => pane,
        "msg_id" => id,
        "text" => text
      },
      6_000
    )
  end

  defp send_v1!(c, pane, text),
    do: frame!(c, %{"cmd" => "send", "pane_id" => pane, "text" => text}, 6_000)

  defp reconcile!(c, pane, id, text, wait_ms),
    do: c |> timed_reconcile!(pane, id, text, wait_ms) |> elem(0)

  # {reply, sent_at, received_at} in native units; sent_at is stamped after connect,
  # immediately before the request is written.
  defp timed_reconcile!(c, pane, id, text, wait_ms) do
    timed_frame!(
      c,
      %{
        "cmd" => "reconcile",
        "protocol_version" => 2,
        "pane_id" => pane,
        "msg_id" => id,
        "payload_hash" => hash(text),
        "wait_ms" => wait_ms
      },
      3_000
    )
  end

  defp frame!(c, payload, recv_timeout), do: c |> timed_frame!(payload, recv_timeout) |> elem(0)

  defp timed_frame!(c, payload, recv_timeout) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      sent_at = now_native()
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, recv_timeout)
      received_at = now_native()
      {Jason.decode!(frame), sent_at, received_at}
    after
      :gen_tcp.close(client)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp now_native, do: System.monotonic_time()

  defp await_unregistered(pane, timeout \\ 2_000) do
    deadline = now_ms() + timeout

    Stream.repeatedly(fn ->
      cond do
        PaneSupervisor.whereis_pane(pane) == :error -> :ok
        now_ms() > deadline -> :timeout
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end

  defp await_state(sm, target, timeout \\ 2_000) do
    deadline = now_ms() + timeout

    Stream.repeatedly(fn ->
      cond do
        StateMachine.state(sm) == target -> :ok
        now_ms() > deadline -> {:timeout, StateMachine.state(sm)}
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
  end
end
