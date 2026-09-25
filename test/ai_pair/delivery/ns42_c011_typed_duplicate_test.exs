defmodule AiPair.Delivery.NS42C011TypedDuplicateTest do
  @moduledoc """
  NS-42.C.011 (a duplicate is a typed answer), the producer half, on the daemon's v2 IPC
  send path. Scope: CLAUDE-NEXT-ROW-SCOPE-NS-42.C.011-r2.org (5baf573c), source GO by
  Codex m_1790348800000.

  Register failure control: "Duplicate reply missing duplicate:true, status,
  delivery_attempt or exact message_id/pane_id, or bare-status parsing, fails.
  Delivered/queued duplicates cause no second paste; pending follows rule 9 bounded wait.
  Ambiguous/conflict becomes durable attention, never optimistic success/absence."

  The harness is the real path, copied from `ns42_c008_timeout_and_validation_test.exs`:
  a `ReceiptStore` on a unique inbox, a real `AiPair.IPC.Server` with that store, and real
  panes started through `AiPair.PaneSupervisor.start_pane/2`. Frames are raw v2 JSON over
  the UNIX socket. The capture and paste functions are the only doubles.

  For each stored status a real pane produced, an identical v2 send is answered as the
  typed duplicate and carries the receipt view that a wait-0 reconcile of the same
  identity carries at that moment (`delivery.ex:82-94`, `:121-126`). For pending, and for
  a queued send whose drain paste is in flight, that reconcile's outcome is `ambiguous`
  while the duplicate's status is `pending` / `queued`: the treatment is tied to the
  status (vendored `docs/contracts/ipc-v2.org:434`). A `not_delivered` receipt is never a
  duplicate: admission opens the next attempt. The consumer half (orris) is not here, and
  the rule-9 wait for a pending duplicate is served by reconcile (NS-42.C.010, RU-1 A).

  Every assertion message ends with the observed value, because ExUnit prints no
  left/right once a custom message is given. Each row's control differs in one named
  variable and makes the row's detector fire. The paste recorder counts ATTEMPTS: it
  counts on entry, before the mode is read, so a failed or held paste is counted.

  Pane ids are built at runtime. Every pane passes `pane_gone_threshold: 2` (the default)
  and a grace of 30_000 ms (the default) except the D-ND pane, whose grace is 0 so that
  two `:pane_gone` captures reap it. A pane left inside a held paste is ended by
  `stop_pane/1` in `on_exit`: the pane does not trap exits, so termination ends the gate.
  No release message is sent blindly, because the pane has no clause for a stray info
  message. The capture Agent is unlinked and stopped only after the pane, so a pane that
  polls between the test's exit and its own stop never reads a dead capture double.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @moduletag :capture_log

  @view_keys ~w(status delivery_attempt payload_hash msg_id pane_id)
  @idle {:ok, "IDLE_MARKER"}
  @busy {:ok, "BUSY_MARKER"}

  @d_del "D-DEL: a delivered receipt answers a typed delivered duplicate and no second paste"

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns42_c011_#{n}")
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})
    server = :"ns42_c011_server_#{n}"
    start_supervised!({Server, inbox: inbox, name: server, receipt_store: store})

    # One Agent holds the paste mode and a count of paste ATTEMPTS per text.
    paste = start_supervised!({Agent, fn -> %{mode: :immediate, counts: %{}} end})

    {:ok,
     n: n,
     store: store,
     paste: paste,
     log: ReceiptStore.path(store),
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "NS-42.C.011 typed duplicate over the v2 socket" do
    test "D-PEND: a pending receipt answers a typed pending duplicate " <>
           "with the reconcile view and no paste",
         c do
      p = start_pane!(c, "pend", @idle)
      ready!(p, :idle, "pending")
      sm = p.sm
      id1 = id(c, "pend")
      x = "D-PEND held bytes #{c.n}"
      set_mode(c, :gated)
      a = Task.async(fn -> send_frame!(c, send_frame(p.pane, id1, x)) end)
      assert_receive {:paste_started, ^sm, ^x, _}, 2_000
      held = statuses(c, id1)

      assert held == [{1, "pending"}],
             "pending: the first send was not held at attempt 1; got #{inspect(held)}"

      rec = reconcile!(c, p.pane, id1, x)

      assert rec == reconciled(p.pane, id1, x, "pending", 1, "ambiguous"),
             "pending: the wait-0 reconcile did not answer ambiguous over a pending view; " <>
               "got #{inspect(rec)}"

      log_before = File.read!(c.log)
      dup = send_frame!(c, send_frame(p.pane, id1, x))
      log_after_dup = File.read!(c.log)
      hist_after_dup = statuses(c, id1)
      pastes_after_dup = pastes(c, x)
      first = Task.yield(a, 0)

      assert first == nil,
             "pending: the duplicate was answered only after the held send returned, so it " <>
               "may have routed through the pane; got #{inspect(first)}"

      # C-BYPASS: the same held pane, a fresh msg_id, the same bytes. DIFFERS ONLY in msg_id.
      id2 = id(c, "pend-control")
      ctl = Task.async(fn -> send_frame!(c, send_frame(p.pane, id2, x)) end)
      early = Task.yield(ctl, 200)

      assert early == nil,
             "control: a non-duplicate send answered while the pane was held, so the bypass " <>
               "detector cannot distinguish; got #{inspect(early)}"

      assert dup == expected_dup(p.pane, id1, x, "pending", 1),
             "pending: the duplicate was not the typed receipt view; got #{inspect(dup)}"

      refute Map.has_key?(dup, "outcome"),
             "pending: a duplicate carried an outcome; got #{inspect(dup)}"

      same_view!("pending", dup, rec)

      assert log_after_dup == log_before,
             "pending: a duplicate appended to the receipt log; got #{inspect(hist_after_dup)}"

      assert pastes_after_dup == 1,
             "pending: a duplicate that observed pending pasted; got #{pastes_after_dup}"

      set_mode(c, :immediate)
      send(sm, {:release_paste, :ok})
      a_reply = Task.await(a, 3_000)
      ctl_reply = Task.await(ctl, 3_000)

      assert a_reply["status"] == "sent",
             "pending: the held send did not finish sent; got #{inspect(a_reply)}"

      assert ctl_reply["status"] == "sent",
             "control: the fresh id was not sent after the release; got #{inspect(ctl_reply)}"

      total = pastes(c, x)

      assert total == 2,
             "control: a non-duplicate send of the same bytes did not paste; got #{total}"

      final = statuses(c, id1)

      assert final == [{1, "pending"}, {1, "delivered"}],
             "pending: the held attempt did not finalize delivered; got #{inspect(final)}"
    end

    test "D-QUE: a queued receipt answers a typed queued duplicate, " <>
           "distinct from the bare queued send reply",
         c do
      p = start_pane!(c, "que", @busy)
      ready!(p, :busy, "queued")
      id3 = id(c, "que")
      y = "D-QUE queued bytes #{c.n}"
      first = send_frame!(c, send_frame(p.pane, id3, y))

      assert first == queued_reply(p.pane, id3),
             "queued: the first send was not queued behind the busy pane; got #{inspect(first)}"

      held = statuses(c, id3)

      assert held == [{1, "pending"}, {1, "queued"}],
             "queued: the first send was not queued at attempt 1; got #{inspect(held)}"

      rec = reconcile!(c, p.pane, id3, y)

      assert rec == reconciled(p.pane, id3, y, "queued", 1, "queued"),
             "queued: the wait-0 reconcile did not answer queued over a queued view; " <>
               "got #{inspect(rec)}"

      log_before = File.read!(c.log)
      dup = send_frame!(c, send_frame(p.pane, id3, y))
      log_after_dup = File.read!(c.log)
      hist_after_dup = statuses(c, id3)
      pastes_after_dup = pastes(c, y)

      # C-BARE: the same busy pane, a fresh msg_id, the same bytes. DIFFERS ONLY in msg_id.
      id4 = id(c, "que-control")
      ctl = send_frame!(c, send_frame(p.pane, id4, y))

      assert ctl == queued_reply(p.pane, id4),
             "control: the fresh id was not the bare queued send reply; got #{inspect(ctl)}"

      refute Map.has_key?(ctl, "duplicate") or Map.has_key?(ctl, "delivery_attempt"),
             "control: the bare queued send reply carried duplicate fields; got #{inspect(ctl)}"

      ctl_log = statuses(c, id4)

      assert ctl_log == [{1, "pending"}, {1, "queued"}],
             "control: the fresh id did not open its own queued attempt; got #{inspect(ctl_log)}"

      assert dup == expected_dup(p.pane, id3, y, "queued", 1),
             "queued: the duplicate was not the typed receipt view; got #{inspect(dup)}"

      refute Map.has_key?(dup, "outcome"),
             "queued: a duplicate carried an outcome; got #{inspect(dup)}"

      same_view!("queued", dup, rec)

      assert log_after_dup == log_before,
             "queued: a duplicate appended to the receipt log; got #{inspect(hist_after_dup)}"

      assert pastes_after_dup == 0,
             "queued: a duplicate pasted while the pane was busy; got #{pastes_after_dup}"

      set_capture(p, @idle)
      {drain, seen} = await_last(c, [id3, id4], {1, "delivered"})

      assert drain == :ok,
             "queued: the drain did not deliver both queued sends; got id3 " <>
               "#{inspect(seen[id3])} id4 #{inspect(seen[id4])} pastes #{pastes(c, y)}"

      total = pastes(c, y)

      assert total == 2,
             "queued: the duplicate added a paste, or a queued send was not pasted; got " <>
               "pastes #{total} id3 #{inspect(seen[id3])} id4 #{inspect(seen[id4])}"

      h3 = statuses(c, id3)

      assert h3 == [{1, "pending"}, {1, "queued"}, {1, "delivered"}],
             "queued: the duplicate changed the row id history; got #{inspect(h3)}"

      h4 = statuses(c, id4)

      assert h4 == [{1, "pending"}, {1, "queued"}, {1, "delivered"}],
             "queued: the control id history is not one queued-then-delivered attempt; " <>
               "got #{inspect(h4)}"
    end

    test "D-QIF: a queued receipt whose drain paste is in flight answers a typed queued " <>
           "duplicate and no second paste",
         c do
      p = start_pane!(c, "qif", @busy)
      ready!(p, :busy, "queued in flight")
      sm = p.sm
      id5 = id(c, "qif")
      z = "D-QIF drained bytes #{c.n}"
      first = send_frame!(c, send_frame(p.pane, id5, z))

      assert first == queued_reply(p.pane, id5),
             "queued in flight: the first send was not queued; got #{inspect(first)}"

      set_mode(c, :gated)
      set_capture(p, @idle)
      assert_receive {:paste_started, ^sm, ^z, _}, 2_000
      held = statuses(c, id5)

      assert held == [{1, "pending"}, {1, "queued"}],
             "queued in flight: the held drain is not attempt 1 queued; got #{inspect(held)}"

      rec = reconcile!(c, p.pane, id5, z)

      assert rec == reconciled(p.pane, id5, z, "queued", 1, "ambiguous"),
             "queued in flight: the wait-0 reconcile did not answer ambiguous over a queued " <>
               "view; got #{inspect(rec)}"

      log_before = File.read!(c.log)
      dup = send_frame!(c, send_frame(p.pane, id5, z))
      log_after_dup = File.read!(c.log)
      hist_after_dup = statuses(c, id5)
      pastes_after_dup = pastes(c, z)

      assert dup == expected_dup(p.pane, id5, z, "queued", 1),
             "queued in flight: the duplicate was not the typed receipt view; " <>
               "got #{inspect(dup)}"

      refute Map.has_key?(dup, "outcome"),
             "queued in flight: a duplicate carried an outcome; got #{inspect(dup)}"

      same_view!("queued in flight", dup, rec)

      assert log_after_dup == log_before,
             "queued in flight: a duplicate appended to the receipt log; " <>
               "got #{inspect(hist_after_dup)}"

      assert pastes_after_dup == 1,
             "queued in flight: a duplicate pasted while the drain paste was held; " <>
               "got #{pastes_after_dup}"

      set_mode(c, :immediate)
      send(sm, {:release_paste, :ok})
      {drain, seen} = await_last(c, [id5], {1, "delivered"})

      assert drain == :ok,
             "queued in flight: the released drain did not deliver; got #{inspect(seen[id5])}"

      total = pastes(c, z)
      assert total == 1, "queued in flight: the drain paste was repeated; got #{total}"
    end

    test @d_del, c do
      p = start_pane!(c, "del", @idle)
      ready!(p, :idle, "delivered")
      id6 = id(c, "del")
      v = "D-DEL delivered bytes #{c.n}"
      first = send_frame!(c, send_frame(p.pane, id6, v))

      assert first["status"] == "sent",
             "delivered: the first send was not sent; got #{inspect(first)}"

      held = statuses(c, id6)

      assert held == [{1, "pending"}, {1, "delivered"}],
             "delivered: the first send was not delivered at attempt 1; got #{inspect(held)}"

      rec = reconcile!(c, p.pane, id6, v)

      assert rec == reconciled(p.pane, id6, v, "delivered", 1, "delivered"),
             "delivered: the wait-0 reconcile did not answer delivered; got #{inspect(rec)}"

      log_before = File.read!(c.log)
      dup = send_frame!(c, send_frame(p.pane, id6, v))
      log_after_dup = File.read!(c.log)
      hist_after_dup = statuses(c, id6)
      pastes_after_dup = pastes(c, v)

      # C-PASTE: the same idle pane, a fresh msg_id, the same bytes. DIFFERS ONLY in msg_id.
      id7 = id(c, "del-control")
      ctl = send_frame!(c, send_frame(p.pane, id7, v))
      assert ctl["status"] == "sent", "control: the fresh id was not sent; got #{inspect(ctl)}"
      total = pastes(c, v)
      log_after_ctl = File.read!(c.log)

      assert total == 2,
             "control: a non-duplicate send of the same bytes did not paste, so the paste " <>
               "counter is blind; got #{total}"

      refute log_after_ctl == log_after_dup,
             "control: a non-duplicate send wrote nothing; got #{inspect(statuses(c, id7))}"

      assert dup == expected_dup(p.pane, id6, v, "delivered", 1),
             "delivered: the duplicate was not the typed receipt view; got #{inspect(dup)}"

      refute Map.has_key?(dup, "outcome"),
             "delivered: a duplicate carried an outcome; got #{inspect(dup)}"

      same_view!("delivered", dup, rec)

      assert log_after_dup == log_before,
             "delivered: a duplicate appended to the receipt log; got #{inspect(hist_after_dup)}"

      assert pastes_after_dup == 1,
             "delivered: a delivered duplicate pasted again; got #{pastes_after_dup}"
    end

    test "D-AMB: an ambiguous receipt answers a typed ambiguous duplicate " <>
           "and no second paste",
         c do
      p = start_pane!(c, "amb", @idle)
      ready!(p, :idle, "ambiguous")
      id8 = id(c, "amb")
      w = "D-AMB failing bytes #{c.n}"
      set_mode(c, :fail)
      first = send_frame!(c, send_frame(p.pane, id8, w))

      assert first == refusal(p.pane, id8, "paste_failed"),
             "ambiguous: the first send was not refused paste_failed; got #{inspect(first)}"

      attempted = pastes(c, w)

      assert attempted == 1,
             "ambiguous: the failing paste was not attempted exactly once; got #{attempted}"

      held = statuses(c, id8)

      assert held == [{1, "pending"}, {1, "ambiguous"}],
             "ambiguous: the failed paste was not recorded ambiguous; got #{inspect(held)}"

      rec = reconcile!(c, p.pane, id8, w)

      assert rec == reconciled(p.pane, id8, w, "ambiguous", 1, "ambiguous"),
             "ambiguous: the wait-0 reconcile did not answer ambiguous; got #{inspect(rec)}"

      log_before = File.read!(c.log)
      dup = send_frame!(c, send_frame(p.pane, id8, w))
      log_after_dup = File.read!(c.log)
      hist_after_dup = statuses(c, id8)
      pastes_after_dup = pastes(c, w)

      # C-AMB: paste mode still :fail, a fresh msg_id, the same bytes. DIFFERS ONLY in msg_id.
      id9 = id(c, "amb-control")
      ctl = send_frame!(c, send_frame(p.pane, id9, w))

      assert ctl == refusal(p.pane, id9, "paste_failed"),
             "control: a fresh id under the failing paste was not refused paste_failed; " <>
               "got #{inspect(ctl)}"

      attempts = pastes(c, w)

      assert attempts == 2,
             "control: a non-duplicate send of the same bytes did not attempt a paste, " <>
               "so the attempt counter is blind; got #{attempts}"

      ctl_log = statuses(c, id9)

      assert ctl_log == [{1, "pending"}, {1, "ambiguous"}],
             "control: the fresh id was not its own ambiguous attempt 1; got #{inspect(ctl_log)}"

      row_log = statuses(c, id8)

      assert row_log == [{1, "pending"}, {1, "ambiguous"}],
             "control: the fresh id changed the row id history; got #{inspect(row_log)}"

      assert dup == expected_dup(p.pane, id8, w, "ambiguous", 1),
             "ambiguous: the duplicate was not the typed receipt view; got #{inspect(dup)}"

      refute dup["status"] in ["delivered", "sent"],
             "ambiguous: a duplicate reported optimistic success; got #{inspect(dup)}"

      same_view!("ambiguous", dup, rec)

      assert log_after_dup == log_before,
             "ambiguous: a duplicate appended to the receipt log; got #{inspect(hist_after_dup)}"

      assert pastes_after_dup == 1,
             "ambiguous: an ambiguous duplicate pasted again; got #{pastes_after_dup}"
    end

    test "D-ND: an identical send on a not_delivered receipt is not a duplicate " <>
           "and opens attempt 2",
         c do
      p = start_pane!(c, "nd", @idle, 0)
      ready!(p, :idle, "not_delivered")
      id_c = id(c, "nd-control")
      id_n = id(c, "nd")
      t1 = "D-ND control bytes #{c.n}"
      t2 = "D-ND queued bytes #{c.n}"
      sent = send_frame!(c, send_frame(p.pane, id_c, t1))

      assert sent["status"] == "sent",
             "not_delivered: the control id was not sent; got #{inspect(sent)}"

      set_capture(p, @busy)
      ready!(p, :busy, "not_delivered")
      queued = send_frame!(c, send_frame(p.pane, id_n, t2))

      assert queued == queued_reply(p.pane, id_n),
             "not_delivered: the row id was not queued; got #{inspect(queued)}"

      set_capture(p, {:error, :pane_gone})
      ready!(p, :dead, "not_delivered")
      attempt_1 = [{1, "pending"}, {1, "queued"}, {1, "not_delivered"}]
      settled = statuses(c, id_n)

      assert settled == attempt_1,
             "not_delivered: the dead pane did not settle the queued attempt; " <>
               "got #{inspect(settled)}"

      rn = reconcile!(c, p.pane, id_n, t2)

      assert rn == reconciled(p.pane, id_n, t2, "not_delivered", 1, "absent"),
             "not_delivered: the wait-0 reconcile did not answer absent over a not_delivered " <>
               "view; got #{inspect(rn)}"

      rc = reconcile!(c, p.pane, id_c, t1)

      assert rc == reconciled(p.pane, id_c, t1, "delivered", 1, "delivered"),
             "not_delivered: the control reconcile did not answer delivered; got #{inspect(rc)}"

      control_before = statuses(c, id_c)
      resend = send_frame!(c, send_frame(p.pane, id_n, t2))

      # C-ND: the same dead pane; DIFFERS ONLY in attempt 1's stored status (delivered).
      ctl = send_frame!(c, send_frame(p.pane, id_c, t1))

      assert ctl == expected_dup(p.pane, id_c, t1, "delivered", 1),
             "control: a delivered id on the dead pane was not answered as a duplicate; " <>
               "got #{inspect(ctl)}"

      same_view!("control delivered", ctl, rc)
      control_after = statuses(c, id_c)

      assert control_after == control_before,
             "control: the duplicate changed the control id history; " <>
               "got #{inspect(control_after)}"

      control_pastes = pastes(c, t1)

      assert control_pastes == 1,
             "control: the delivered id was pasted again; got #{control_pastes}"

      assert resend == refusal(p.pane, id_n, "pane_dead"),
             "not_delivered: the resend was not refused pane_dead; got #{inspect(resend)}"

      refute Map.has_key?(resend, "duplicate"),
             "not_delivered: an identical send on a proven non-delivery was answered as a " <>
               "duplicate; got #{inspect(resend)}"

      reopened = statuses(c, id_n)

      assert reopened == attempt_1 ++ [{2, "pending"}, {2, "not_delivered"}],
             "not_delivered: the send did not open attempt 2 through admission; " <>
               "got #{inspect(reopened)}"

      nd_pastes = pastes(c, t2)
      assert nd_pastes == 0, "not_delivered: the row bytes were pasted; got #{nd_pastes}"
    end

    test "X-CONF: a same-id different-payload send is refused conflict with no receipt view", c do
      p = start_pane!(c, "conf", @idle)
      ready!(p, :idle, "conflict")
      id_k = id(c, "conf")
      s1 = "X-CONF first bytes #{c.n}"
      s2 = "X-CONF other bytes #{c.n}"
      sent = send_frame!(c, send_frame(p.pane, id_k, s1))

      assert sent["status"] == "sent",
             "conflict: the first send of the row id was not sent; got #{inspect(sent)}"

      held = statuses(c, id_k)

      assert held == [{1, "pending"}, {1, "delivered"}],
             "conflict: the first send was not delivered at attempt 1; got #{inspect(held)}"

      log_before = File.read!(c.log)
      refused = send_frame!(c, send_frame(p.pane, id_k, s2))
      log_after = File.read!(c.log)
      hist_after = statuses(c, id_k)
      rk = reconcile!(c, p.pane, id_k, s2)

      # C-CONF: the identical resend. DIFFERS ONLY in the text.
      ctl = send_frame!(c, send_frame(p.pane, id_k, s1))

      assert ctl == expected_dup(p.pane, id_k, s1, "delivered", 1),
             "control: the identical resend was not the typed duplicate; got #{inspect(ctl)}"

      assert refused == refusal(p.pane, id_k, "conflict"),
             "conflict: the different-payload send was not refused conflict; " <>
               "got #{inspect(refused)}"

      carried = Map.take(refused, ~w(status delivery_attempt payload_hash duplicate))

      assert carried == %{},
             "conflict: the refusal carried receipt view fields; got #{inspect(carried)}"

      expected_rk = %{"ok" => true, "outcome" => "conflict", "protocol_version" => 2}

      assert rk == Map.merge(expected_rk, %{"msg_id" => id_k, "pane_id" => p.pane}),
             "conflict: the reconcile of the other payload did not answer conflict; " <>
               "got #{inspect(rk)}"

      assert log_after == log_before,
             "conflict: the refused send appended to the receipt log; got #{inspect(hist_after)}"

      other = pastes(c, s2)
      assert other == 0, "conflict: the different-payload bytes were pasted; got #{other}"
    end
  end

  # ===== helpers =====

  # Pane ids are built at runtime; none is a literal, none is a bare tmux number.
  defp pane(c, tag), do: "%" <> "ns42_c011_" <> Integer.to_string(c.n) <> "_" <> tag

  defp start_pane!(c, tag, capture, grace_ms \\ 30_000) do
    pane = pane(c, tag)
    assert ReceiptLog.valid_pane?(pane), "pane id outside the receipt grammar; got #{pane}"
    refute pane =~ ~r/\A%[0-9]+\z/, "pane id is a bare tmux number; got #{pane}"

    # Unlinked, and stopped only after the pane (on_exit runs last-registered first).
    {:ok, cap} = Agent.start(fn -> capture end)
    on_exit(fn -> Agent.stop(cap) end)
    capture_fn = fn _pane_id -> Agent.get(cap, & &1) end

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: capture_fn,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        pane_gone_threshold: 2,
        pane_gone_grace_ms: grace_ms
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    %{pane: pane, sm: sm, cap: cap}
  end

  defp paste_fn(c) do
    test = self()
    paste = c.paste

    fn _pane_id, text ->
      # Counted on entry, before the mode is read: a failed or held paste is an attempt.
      Agent.update(paste, fn s -> %{s | counts: Map.update(s.counts, text, 1, &(&1 + 1))} end)

      case Agent.get(paste, & &1.mode) do
        :immediate ->
          :ok

        :fail ->
          {:error, :x}

        :gated ->
          send(test, {:paste_started, self(), text, System.monotonic_time()})

          receive do
            {:release_paste, result} -> result
          after
            5_000 -> {:error, :gate_timeout}
          end
      end
    end
  end

  defp ready!(p, target, label) do
    seen = await_state(p.sm, target)
    assert seen == :ok, "#{label}: the pane did not reach #{target}; got #{inspect(seen)}"
  end

  defp set_mode(c, mode), do: Agent.update(c.paste, &%{&1 | mode: mode})
  defp set_capture(p, capture), do: Agent.update(p.cap, fn _ -> capture end)
  defp pastes(c, text), do: Agent.get(c.paste, &Map.get(&1.counts, text, 0))

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp send_frame(pane, id, text) do
    %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "text" => text
    }
  end

  # Always wait_ms 0: the same bound the send's own read uses (delivery.ex:88).
  defp reconcile!(c, pane, id, text) do
    send_frame!(c, %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "payload_hash" => hash(text),
      "wait_ms" => 0
    })
  end

  defp send_frame!(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, 3_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
    end
  end

  defp receipt(pane, id, text, status, attempt) do
    %{
      "status" => status,
      "delivery_attempt" => attempt,
      "payload_hash" => hash(text),
      "protocol_version" => 2,
      "msg_id" => id,
      "pane_id" => pane
    }
  end

  defp expected_dup(pane, id, text, status, attempt),
    do: Map.merge(receipt(pane, id, text, status, attempt), %{"ok" => true, "duplicate" => true})

  defp reconciled(pane, id, text, status, attempt, outcome),
    do: Map.merge(receipt(pane, id, text, status, attempt), %{"ok" => true, "outcome" => outcome})

  defp refusal(pane, id, error) do
    %{
      "ok" => false,
      "error" => error,
      "protocol_version" => 2,
      "msg_id" => id,
      "pane_id" => pane
    }
  end

  defp queued_reply(pane, id) do
    %{
      "ok" => true,
      "status" => "queued",
      "queue_reason" => "busy",
      "protocol_version" => 2,
      "msg_id" => id,
      "pane_id" => pane
    }
  end

  defp same_view!(label, dup, rec) do
    rec_view = Map.take(rec, @view_keys)

    assert map_size(rec_view) == 5,
           "#{label}: the reconcile carried no full receipt view; got #{inspect(rec)}"

    assert Map.take(dup, @view_keys) == rec_view,
           "#{label}: the duplicate did not carry the view a reconcile of the same " <>
             "identity carries; duplicate #{inspect(dup)} reconcile #{inspect(rec)}"
  end

  defp statuses(c, id) do
    c.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  # Polls until every id's last record is `last`, or the deadline passes. Returns the
  # observed histories either way, so the caller's message can carry them.
  defp await_last(c, ids, last, timeout \\ 2_000) do
    poll_last(c, ids, last, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll_last(c, ids, last, deadline) do
    seen = Map.new(ids, &{&1, statuses(c, &1)})

    cond do
      Enum.all?(seen, fn {_id, log} -> List.last(log) == last end) ->
        {:ok, seen}

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, seen}

      true ->
        Process.sleep(5)
        poll_last(c, ids, last, deadline)
    end
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
