defmodule AiPair.NS15G002DaemonRefusalBeforePasteTest do
  @moduledoc """
  NS-15.G.002, daemon half: a send to a pane the daemon cannot deliver to is refused (or
  held) BEFORE any paste, over the real IPC socket, on both protocol versions.

  Harness copied from `test/ai_pair/delivery/ns42_c008_timeout_and_validation_test.exs`
  (not shared): a `ReceiptStore` on a unique inbox, a real `AiPair.IPC.Server` with that
  store, raw JSON frames over the UNIX socket, a msg id builder and a v2 reconcile frame
  with a `wait_ms` parameter. Panes are started only through
  `AiPair.PaneSupervisor.start_pane/2`, and every option list is literal and carries both
  `:capture_fn` and `:paste_fn`.

  Detectors, shared by every row and its control:

    * a recording `paste_fn` keyed by `{pane, text}` (an Agent);
    * the receipt log bytes before and after, as the `File.read/1` tuple;
    * v2 reconcile with `wait_ms: 0`: `absent` with no `delivery_attempt` means nothing
      was admitted;
    * `StateMachine.pending_count/1` for the queue;
    * telemetry handlers on `[:ai_pair, :pane, :poll]` and `[:ai_pair, :pane, :reaped]`
      forwarding to the test process.

  Pane ids are built at run time as `"%" <> "ns15_g002_" <> n <> "_" <> tag` and checked
  with `ReceiptLog.valid_pane?/1` and against the tmux-shaped numeric form before use.

  Rows (each names its control):

    * R1 v2, never registered: `pane_not_found`, nothing admitted. Control: the SAME
      pane id and the SAME msg id after `start_pane` (IDLE, debounce 0) is sent, pasted
      once, changes the log and reconciles `delivered`. R1's negative necessarily runs
      before its control, because the control reuses the identity.
    * R1b v2, registered then stopped: `pane_not_found`. Control: a send before the stop.
    * R2 / R2b: the same two constructions on v1. They carry no receipt-log assertion:
      v1 `send_legacy` goes to `:send_untracked` and writes no receipt, so such an
      assertion could never fail.
    * R3 v2, dead by the reaper (threshold 2, grace 0, switchable capture). Control: a
      send while IDLE, before the capture is switched. The refusal is `pane_dead` with no
      paste. DISCLOSED ADMISSION (PD-3, finding H-1), asserted as observed, not as
      correct: the refused send still leaves a record, reconcile answers `absent` with
      `status: not_delivered` and `delivery_attempt: 1`, and the log gains `pending` then
      `not_delivered`.
    * R4 v1, dead by the reaper: `pane_dead`, queue 0.
    * R5 v2, quarantined (a run-time token): refused `pane_quarantined` (the H-2 fix,
      main `0be02ccc`, added it to `Delivery`'s request errors). No paste, log
      unchanged, nothing admitted, queue 0. Control: a sibling pane without the token,
      sent once before and once after the negative send.
    * R6 v1, quarantined: FINDING H-3, pinned as current behaviour. The handler crashes
      in `format_send_result/2` on `{:error, :pane_quarantined}`, so the socket reads
      `{:error, :closed}`. The server still answers a ping afterwards. Control: a sibling
      without the token, v1 sent.
    * R7 v2, simulated capture failure, unreaped: the capture always returns
      `{:error, :pane_gone}` with a reaper threshold of 1_000_000. The send is queued as
      `unknown`, and 20+ polls after it all report `:unknown`. This is a simulated
      capture failure on an unreaped pane; it is not proof of real tmux liveness or
      absence. DISCLOSED, asserted as observed and not as correct: the attempt is
      admitted and queued, so reconcile answers `queued`/`queued`/attempt 1. Control: a
      sibling with the same option list (threshold 1_000_000) and an IDLE capture.
    * R8 v2, receipt-authority mismatch: a pane started without `:receipt_store`
      answers `receipt_store_mismatch`, with nothing admitted. Control: a sibling with
      the store.
    * C-Q, the queue detector control: a sibling whose capture is BUSY queues a v1 send
      as `busy`, and `pending_count` reads 1.

  `mark_dead/1` is not used; death comes only from the reaper.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns15_g002_daemon_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})

    start_supervised!(
      {Server, inbox: inbox, name: :"ns15_g002_daemon_server_#{n}", receipt_store: store}
    )

    # Paste counts keyed by {pane, text}.
    paste = start_supervised!({Agent, fn -> %{} end})

    handler = "ns15_g002_daemon_" <> Integer.to_string(n)

    :ok =
      :telemetry.attach_many(
        handler,
        [[:ai_pair, :pane, :poll], [:ai_pair, :pane, :reaped]],
        &__MODULE__.forward_telemetry/4,
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
  def forward_telemetry([:ai_pair, :pane, :poll], _m, %{pane_id: pane} = meta, test),
    do: send(test, {:poll, pane, meta.to_state})

  def forward_telemetry([:ai_pair, :pane, :reaped], _m, %{pane_id: pane}, test),
    do: send(test, {:reaped, pane})

  def forward_telemetry(_event, _m, _meta, _test), do: :ok

  # ===== R1 / R1b: v2 to an unregistered pane =====

  describe "R1 / R1b: v2 send to a pane that is not registered" do
    test "R1 never registered: pane_not_found, nothing admitted; control: same ids after " <>
           "start_pane are sent",
         c do
      pane = pane!(c, "r")
      id = id(c, "r1")
      text = "R1 text " <> Integer.to_string(c.n)

      # Preconditions.
      where = PaneSupervisor.whereis_pane(pane)
      assert where == :error, "R1 precondition unregistered; observed " <> inspect(where)
      assert_absent_unadmitted(c, pane, id, text)
      before = File.read(c.log)

      # Negative.
      reply = send_v2!(c, pane, id, text)

      assert reply == refusal_v2(pane, id, "pane_not_found"),
             "R1 reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R1 pastes; observed #{pastes(c, pane, text)}"
      after_neg = File.read(c.log)
      assert after_neg == before, "R1 log unchanged; observed " <> inspect(after_neg)
      assert_absent_unadmitted(c, pane, id, text)

      # Control: the same pane id and the same msg id, now registered and idle.
      _sm = start_idle!(c, pane)
      ctl = send_v2!(c, pane, id, text)

      assert {ctl["ok"], ctl["status"]} == {true, "sent"},
             "R1 control; observed " <> inspect(ctl)

      assert pastes(c, pane, text) == 1, "R1 control pastes; observed #{pastes(c, pane, text)}"
      after_ctl = File.read(c.log)

      refute after_ctl == before,
             "R1 control must change the log; observed " <> inspect(after_ctl)

      rec = reconcile!(c, pane, id, text)

      assert {rec["outcome"], rec["delivery_attempt"]} == {"delivered", 1},
             "R1 control reconcile; observed " <> inspect(rec)
    end

    test "R1b registered then stopped: pane_not_found; control: sent before the stop", c do
      pane = pane!(c, "rb")
      _sm = start_idle!(c, pane)

      # Control first, on the registered pane. Its text differs from the row's only as an
      # incidental difference; the named variable is registration.
      ctl_id = id(c, "r1b-control")
      ctl_text = "R1b control " <> Integer.to_string(c.n)
      ctl_before = File.read(c.log)
      ctl = send_v2!(c, pane, ctl_id, ctl_text)
      assert ctl["status"] == "sent", "R1b control; observed " <> inspect(ctl)
      assert_pastes(c, pane, ctl_text, 1, "R1b control")
      ctl_after = File.read(c.log)

      refute ctl_after == ctl_before,
             "R1b control must change the log; observed " <> inspect(ctl_after)

      # Stop and prove the stop.
      assert_stopped(pane, "R1b")

      id = id(c, "r1b")
      text = "R1b text " <> Integer.to_string(c.n)
      assert_absent_unadmitted(c, pane, id, text)
      before = File.read(c.log)

      reply = send_v2!(c, pane, id, text)

      assert reply == refusal_v2(pane, id, "pane_not_found"),
             "R1b reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R1b pastes; observed #{pastes(c, pane, text)}"
      after_neg = File.read(c.log)
      assert after_neg == before, "R1b log unchanged; observed " <> inspect(after_neg)
      assert_absent_unadmitted(c, pane, id, text)
    end
  end

  # ===== R2 / R2b: the same on v1 =====

  describe "R2 / R2b: v1 send to a pane that is not registered" do
    test "R2 never registered: pane_not_found; control: same pane after start_pane is sent",
         c do
      pane = pane!(c, "s")
      text = "R2 text " <> Integer.to_string(c.n)

      where = PaneSupervisor.whereis_pane(pane)
      assert where == :error, "R2 precondition unregistered; observed " <> inspect(where)

      # No receipt-log assertion on v1: send_legacy goes to :send_untracked and writes no
      # receipt, so a log-unchanged check here could never fail.
      reply = send_v1!(c, pane, text)

      assert reply == %{"ok" => false, "pane_id" => pane, "error" => "pane_not_found"},
             "R2 reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R2 pastes; observed #{pastes(c, pane, text)}"

      # Control: the same pane id, registered and idle.
      _sm = start_idle!(c, pane)
      ctl = send_v1!(c, pane, text)

      assert {ctl["ok"], ctl["status"]} == {true, "sent"},
             "R2 control; observed " <> inspect(ctl)

      assert pastes(c, pane, text) == 1, "R2 control pastes; observed #{pastes(c, pane, text)}"
    end

    test "R2b registered then stopped: pane_not_found; control: sent before the stop", c do
      pane = pane!(c, "sb")
      _sm = start_idle!(c, pane)

      ctl_text = "R2b control " <> Integer.to_string(c.n)
      ctl = send_v1!(c, pane, ctl_text)
      assert ctl["status"] == "sent", "R2b control; observed " <> inspect(ctl)
      assert_pastes(c, pane, ctl_text, 1, "R2b control")

      assert_stopped(pane, "R2b")

      # No receipt-log assertion on v1 (untracked path, writes no receipt; see R2).
      text = "R2b text " <> Integer.to_string(c.n)
      reply = send_v1!(c, pane, text)

      assert reply == %{"ok" => false, "pane_id" => pane, "error" => "pane_not_found"},
             "R2b reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R2b pastes; observed #{pastes(c, pane, text)}"
    end
  end

  # ===== R3 / R4: dead by the reaper =====

  describe "R3 / R4: a pane reaped dead" do
    test "R3 v2: pane_dead with no paste; the refused send's record is DISCLOSED", c do
      pane = pane!(c, "d")
      {sm, capture} = start_switchable!(c, pane)
      assert_state(sm, :idle, "R3 start")

      # Control: the same pane while idle.
      ctl_id = id(c, "r3-control")
      ctl_text = "R3 control " <> Integer.to_string(c.n)
      ctl = send_v2!(c, pane, ctl_id, ctl_text)
      assert ctl["status"] == "sent", "R3 control; observed " <> inspect(ctl)
      assert_pastes(c, pane, ctl_text, 1, "R3 control")

      # The reaper: capture switched to pane_gone; dead by telemetry and by state.
      Agent.update(capture, fn _ -> {:error, :pane_gone} end)

      assert_receive {:reaped, ^pane},
                     2_000,
                     "R3 reaped telemetry; pane state " <> inspect(StateMachine.state(sm))

      assert_now(sm, :dead, "R3 reaped")

      id = id(c, "r3")
      text = "R3 text " <> Integer.to_string(c.n)
      assert_absent_unadmitted(c, pane, id, text)
      reply = send_v2!(c, pane, id, text)

      assert reply == refusal_v2(pane, id, "pane_dead"),
             "R3 reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R3 pastes; observed #{pastes(c, pane, text)}"

      # DISCLOSED ADMISSION (PD-3, finding H-1), asserted as observed, not as correct
      rec = reconcile!(c, pane, id, text)

      assert {rec["outcome"], rec["status"], rec["delivery_attempt"]} ==
               {"absent", "not_delivered", 1},
             "R3 disclosed reconcile; observed " <> inspect(rec)

      assert statuses(c, id) == [{1, "pending"}, {1, "not_delivered"}],
             "R3 disclosed log; observed " <> inspect(statuses(c, id))
    end

    test "R4 v1: pane_dead with no paste and an empty queue", c do
      pane = pane!(c, "e")
      {sm, capture} = start_switchable!(c, pane)
      assert_state(sm, :idle, "R4 start")

      ctl_text = "R4 control " <> Integer.to_string(c.n)
      ctl = send_v1!(c, pane, ctl_text)
      assert ctl["status"] == "sent", "R4 control; observed " <> inspect(ctl)
      assert_pastes(c, pane, ctl_text, 1, "R4 control")

      Agent.update(capture, fn _ -> {:error, :pane_gone} end)

      assert_receive {:reaped, ^pane},
                     2_000,
                     "R4 reaped telemetry; pane state " <> inspect(StateMachine.state(sm))

      assert_now(sm, :dead, "R4 reaped")

      text = "R4 text " <> Integer.to_string(c.n)
      reply = send_v1!(c, pane, text)

      assert reply == %{"ok" => false, "pane_id" => pane, "error" => "pane_dead"},
             "R4 reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R4 pastes; observed #{pastes(c, pane, text)}"
      q = StateMachine.pending_count(sm)
      assert q == 0, "R4 queue; observed #{q}"
    end
  end

  # ===== R5 / R6: quarantined =====

  describe "R5 / R6: a quarantined pane" do
    test "R5 v2: pane_quarantined; no paste, log unchanged, queue 0", c do
      pane = pane!(c, "q")
      sib = pane!(c, "qs")
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      sm = start_quarantined!(c, pane, token)
      _sib_sm = start_idle!(c, sib)
      assert_state(sm, :idle, "R5 start")

      status = StateMachine.status(sm)

      assert {status.quarantined, status.state} == {true, :idle},
             "R5 precondition; observed " <> inspect(status)

      direct =
        StateMachine.send_receipted(sm, "R5 direct", 1_000, id(c, "r5-direct"), c.store)

      assert direct == {:error, :pane_quarantined}, "R5 direct; observed " <> inspect(direct)

      # Control, before the negative send. Control texts differ from the row's only as an
      # incidental difference; the named variable is the quarantine token.
      ctl1_text = "R5 control before " <> Integer.to_string(c.n)
      ctl1_log = File.read(c.log)
      ctl1 = send_v2!(c, sib, id(c, "r5-control-before"), ctl1_text)
      assert ctl1["status"] == "sent", "R5 control before; observed " <> inspect(ctl1)
      assert_pastes(c, sib, ctl1_text, 1, "R5 control before")
      ctl1_after = File.read(c.log)

      refute ctl1_after == ctl1_log,
             "R5 control before must change the log; observed " <> inspect(ctl1_after)

      id = id(c, "r5")
      text = "R5 text " <> Integer.to_string(c.n)
      assert_absent_unadmitted(c, pane, id, text)
      before = File.read(c.log)
      reply = send_v2!(c, pane, id, text)
      # Flushed after the send, so the poll awaited below is necessarily after it.
      flush_polls(pane)

      # The quarantined pane is refused with its own wire word (H-2 fix, main 0be02ccc).
      assert reply == refusal_v2(pane, id, "pane_quarantined"),
             "R5 reply; observed " <> inspect(reply)

      assert_receive {:poll, ^pane, _},
                     1_000,
                     "R5 poll after the send; pane state " <> inspect(StateMachine.state(sm))

      assert pastes(c, pane, text) == 0, "R5 pastes; observed #{pastes(c, pane, text)}"
      after_neg = File.read(c.log)
      assert after_neg == before, "R5 log unchanged; observed " <> inspect(after_neg)
      assert_absent_unadmitted(c, pane, id, text)
      q = StateMachine.pending_count(sm)
      assert q == 0, "R5 queue; observed #{q}"

      # Control, after the negative send.
      ctl2_text = "R5 control after " <> Integer.to_string(c.n)
      ctl2_log = File.read(c.log)
      ctl2 = send_v2!(c, sib, id(c, "r5-control-after"), ctl2_text)
      assert ctl2["status"] == "sent", "R5 control after; observed " <> inspect(ctl2)
      assert_pastes(c, sib, ctl2_text, 1, "R5 control after")
      ctl2_after = File.read(c.log)

      refute ctl2_after == ctl2_log,
             "R5 control after must change the log; observed " <> inspect(ctl2_after)
    end

    test "R6 v1: FINDING H-3 pinned; the handler crashes, the server still answers", c do
      pane = pane!(c, "u")
      sib = pane!(c, "us")
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      sm = start_quarantined!(c, pane, token)
      _sib_sm = start_idle!(c, sib)
      assert_state(sm, :idle, "R6 start")
      quarantined = StateMachine.status(sm).quarantined
      assert quarantined == true, "R6 precondition quarantined; observed " <> inspect(quarantined)

      # Control.
      ctl_text = "R6 control " <> Integer.to_string(c.n)
      ctl = send_v1!(c, sib, ctl_text)
      assert ctl["status"] == "sent", "R6 control; observed " <> inspect(ctl)
      assert_pastes(c, sib, ctl_text, 1, "R6 control")

      text = "R6 text " <> Integer.to_string(c.n)
      needles = ["FunctionClauseError", "format_send_result", ":pane_quarantined"]

      # The crash report is awaited with a bound (2_000 ms), not a fixed sleep: a
      # forwarding logger handler is polled until every needle appears or the bound passes.
      # with_log only keeps the report off the console.
      {{result, {waited, log}}, _console} =
        ExUnit.CaptureLog.with_log(fn ->
          handler = forward_logs!()
          r = raw_v1(c, %{"cmd" => "send", "pane_id" => pane, "text" => text})
          logged = await_log(needles, 2_000)
          :ok = :logger.remove_handler(handler)
          {r, logged}
        end)

      # FINDING H-3, pinned as current behaviour and not asserted as correct
      assert result == {:error, :closed}, "R6 socket; observed " <> inspect(result)

      assert waited == :ok,
             "R6 crash report within 2_000 ms; observed #{waited}, capture " <> inspect(log)

      for needle <- needles do
        assert log =~ needle, "R6 log must name #{needle}; observed " <> inspect(log)
      end

      ping = send_v1_frame!(c, %{"cmd" => "ping"})
      assert ping["ok"] == true, "R6 ping afterwards; observed " <> inspect(ping)
      q = StateMachine.pending_count(sm)
      assert q == 0, "R6 queue after the closed socket; observed #{q}"
      assert pastes(c, pane, text) == 0, "R6 pastes; observed #{pastes(c, pane, text)}"
    end
  end

  # ===== R7: simulated capture failure, unreaped =====

  describe "R7: simulated capture failure, unreaped" do
    test "R7 v2 queues as unknown and 20+ later polls stay unknown; not proof of real " <>
           "tmux liveness or absence",
         c do
      pane = pane!(c, "g")
      sib = pane!(c, "gs")
      sm = start_gone_unreaped!(c, pane)
      _sib_sm = start_idle_unreaped!(c, sib)

      assert_receive {:poll, ^pane, :unknown},
                     1_000,
                     "R7 first unknown poll; pane state " <> inspect(StateMachine.state(sm))

      # Control: a sibling with the SAME option list (threshold 1_000_000); only the capture
      # double differs (IDLE). The control text differs only as an incidental difference.
      ctl_text = "R7 control " <> Integer.to_string(c.n)
      ctl = send_v2!(c, sib, id(c, "r7-control"), ctl_text)
      assert ctl["status"] == "sent", "R7 control; observed " <> inspect(ctl)
      assert_pastes(c, sib, ctl_text, 1, "R7 control")

      id = id(c, "r7")
      text = "R7 text " <> Integer.to_string(c.n)
      assert_absent_unadmitted(c, pane, id, text)
      reply = send_v2!(c, pane, id, text)

      assert {reply["ok"], reply["status"], reply["queue_reason"]} == {true, "queued", "unknown"},
             "R7 reply; observed " <> inspect(reply)

      # DISCLOSED, asserted as observed, not as correct: the attempt is admitted and queued.
      rec = reconcile!(c, pane, id, text)

      assert {rec["outcome"], rec["status"], rec["delivery_attempt"]} == {"queued", "queued", 1},
             "R7 disclosed reconcile; observed " <> inspect(rec)

      flush_polls(pane)
      polls = collect_polls(pane, 20, 3_000)
      assert length(polls) >= 20, "R7 polls after send; observed #{length(polls)}"

      assert Enum.uniq(polls) == [:unknown],
             "R7 every later poll is unknown; observed " <> inspect(Enum.uniq(polls))

      assert_now(sm, :unknown, "R7 after the polls")
      assert pastes(c, pane, text) == 0, "R7 pastes; observed #{pastes(c, pane, text)}"
    end
  end

  # ===== R8: receipt-authority mismatch =====

  describe "R8: a pane without the daemon's receipt store" do
    test "R8 v2: receipt_store_mismatch, nothing admitted; control: a sibling with the " <>
           "store is sent",
         c do
      pane = pane!(c, "m")
      sib = pane!(c, "ms")
      sm = start_storeless!(c, pane)
      _sib_sm = start_idle!(c, sib)
      assert_state(sm, :idle, "R8 start")

      # Control text differs from the row's only as an incidental difference; the named
      # variable is the :receipt_store option.
      ctl_text = "R8 control " <> Integer.to_string(c.n)
      ctl_log = File.read(c.log)
      ctl = send_v2!(c, sib, id(c, "r8-control"), ctl_text)
      assert ctl["status"] == "sent", "R8 control; observed " <> inspect(ctl)
      ctl_pastes = pastes(c, sib, ctl_text)
      assert ctl_pastes == 1, "R8 control pastes; observed #{ctl_pastes}"
      ctl_after = File.read(c.log)

      refute ctl_after == ctl_log,
             "R8 control must change the log; observed " <> inspect(ctl_after)

      id = id(c, "r8")
      text = "R8 text " <> Integer.to_string(c.n)
      assert_absent_unadmitted(c, pane, id, text)
      before = File.read(c.log)
      reply = send_v2!(c, pane, id, text)

      assert reply == refusal_v2(pane, id, "receipt_store_mismatch"),
             "R8 reply; observed " <> inspect(reply)

      assert pastes(c, pane, text) == 0, "R8 pastes; observed #{pastes(c, pane, text)}"
      after_neg = File.read(c.log)
      assert after_neg == before, "R8 log unchanged; observed " <> inspect(after_neg)
      assert_absent_unadmitted(c, pane, id, text)
    end
  end

  # ===== C-Q: the queue detector fires =====

  describe "C-Q: the queue detector" do
    test "a BUSY sibling queues a v1 send and pending_count reads 1", c do
      pane = pane!(c, "b")
      sm = start_busy!(c, pane)
      assert_state(sm, :busy, "C-Q start")

      text = "C-Q text " <> Integer.to_string(c.n)
      reply = send_v1!(c, pane, text)

      assert {reply["ok"], reply["status"], reply["queue_reason"]} == {true, "queued", "busy"},
             "C-Q reply; observed " <> inspect(reply)

      q = StateMachine.pending_count(sm)
      assert q == 1, "C-Q queue; observed #{q}"
      assert pastes(c, pane, text) == 0, "C-Q pastes; observed #{pastes(c, pane, text)}"
    end
  end

  # ===== pane starters (every option list is literal) =====

  defp paste_fn(c) do
    paste = c.paste

    fn pane, text ->
      Agent.update(paste, &Map.update(&1, {pane, text}, 1, fn k -> k + 1 end))
      :ok
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
    assert_state(sm, :idle, "start_idle! " <> pane)
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
    {sm, capture}
  end

  defp start_quarantined!(c, pane, token) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        quarantine_token: token
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  defp start_gone_unreaped!(c, pane) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:error, :pane_gone} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        pane_gone_threshold: 1_000_000
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  # R7's control: the same option list as start_gone_unreaped!/2; only the capture differs.
  defp start_idle_unreaped!(c, pane) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        pane_gone_threshold: 1_000_000
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    assert_state(sm, :idle, "start_idle_unreaped! " <> pane)
    sm
  end

  defp start_storeless!(c, pane) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        capture_fn: fn _ -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  defp start_busy!(c, pane) do
    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, "BUSY_MARKER"} end,
        paste_fn: paste_fn(c),
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  # ===== helpers =====

  defp pane!(c, tag) do
    pane = "%" <> "ns15_g002_" <> Integer.to_string(c.n) <> "_" <> tag
    assert ReceiptLog.valid_pane?(pane), "pane grammar; observed " <> inspect(pane)
    refute pane =~ ~r/\A%[0-9]+\z/, "pane must not be tmux-shaped; observed " <> inspect(pane)
    pane
  end

  defp pastes(c, pane, text), do: Agent.get(c.paste, &Map.get(&1, {pane, text}, 0))

  defp assert_pastes(c, pane, text, expected, label) do
    n = pastes(c, pane, text)
    assert n == expected, label <> " pastes; observed #{n}"
  end

  # await_state/3 returns {:timeout, state} on a timeout; the message carries it.
  defp assert_state(sm, target, label) do
    r = await_state(sm, target)
    assert r == :ok, label <> " awaiting #{inspect(target)}; observed " <> inspect(r)
  end

  defp assert_now(sm, target, label) do
    s = StateMachine.state(sm)
    assert s == target, label <> " state; observed " <> inspect(s)
  end

  defp assert_stopped(pane, label) do
    stopped = PaneSupervisor.stop_pane(pane)
    assert stopped == :ok, label <> " stop_pane; observed " <> inspect(stopped)
    gone = await_unregistered(pane)
    assert gone == :ok, label <> " unregistered; observed " <> inspect(gone)
  end

  # A logger handler forwarding each formatted event to the test process, removed on exit.
  defp forward_logs! do
    id = :"ns15_g002_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{test: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)
    id
  end

  @doc false
  def log(event, %{config: %{test: test}}) do
    {Logger.Formatter, formatter} = Logger.Formatter.new()
    send(test, {:logged, IO.chardata_to_string(Logger.Formatter.format(event, formatter))})
  end

  # {:ok | :timeout, text}: the forwarded log text, once every needle appears or the bound
  # passes.
  defp await_log(needles, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_log(needles, deadline, "")
  end

  defp do_await_log(needles, deadline, acc) do
    if Enum.all?(needles, &String.contains?(acc, &1)) do
      {:ok, acc}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:logged, text} -> do_await_log(needles, deadline, acc <> text)
      after
        remaining -> {:timeout, acc}
      end
    end
  end

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp refusal_v2(pane, id, error),
    do: %{
      "ok" => false,
      "error" => error,
      "protocol_version" => 2,
      "msg_id" => id,
      "pane_id" => pane
    }

  defp send_v2!(c, pane, id, text) do
    send_frame!(c, %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => pane,
      "msg_id" => id,
      "text" => text
    })
  end

  defp send_v1!(c, pane, text),
    do: send_v1_frame!(c, %{"cmd" => "send", "pane_id" => pane, "text" => text})

  defp send_v1_frame!(c, payload) do
    {:ok, frame} = raw_v1(c, payload)
    Jason.decode!(frame)
  end

  defp raw_v1(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      :gen_tcp.recv(client, 0, 2_000)
    after
      :gen_tcp.close(client)
    end
  end

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

  defp assert_absent_unadmitted(c, pane, id, text) do
    rec = reconcile!(c, pane, id, text)

    assert rec["outcome"] == "absent" and not Map.has_key?(rec, "delivery_attempt"),
           "absent with no attempt (nothing admitted); observed " <> inspect(rec)
  end

  defp send_frame!(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
    end
  end

  defp statuses(c, id) do
    c.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
  end

  defp flush_polls(pane) do
    receive do
      {:poll, ^pane, _} -> flush_polls(pane)
    after
      0 -> :ok
    end
  end

  defp collect_polls(pane, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(pane, count, deadline, [])
  end

  defp do_collect(_pane, count, _deadline, acc) when length(acc) >= count, do: Enum.reverse(acc)

  defp do_collect(pane, count, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:poll, ^pane, to} -> do_collect(pane, count, deadline, [to | acc])
    after
      remaining -> Enum.reverse(acc)
    end
  end

  defp await_unregistered(pane, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        PaneSupervisor.whereis_pane(pane) == :error -> :ok
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(5) && :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
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
