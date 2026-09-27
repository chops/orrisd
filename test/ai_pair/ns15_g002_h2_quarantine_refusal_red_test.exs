defmodule AiPair.NS15G002H2QuarantineRefusalRedTest do
  @moduledoc """
  NS-15.G.002 refusal finding H-2, RED row (scope CLAUDE-ORRISD-H2-FIX-SOURCE-SCOPE).

  H-2: a pane started with a `:quarantine_token` answers every send call with
  `{:error, :pane_quarantined}` (`state_machine.ex` quarantine clause), but
  `AiPair.IPC.Delivery` does not list that reason in `@request_errors`, so its
  catch-all `rejection/1` put `receipt_store_unavailable` on the v2 wire: the caller
  was told the store was down when the pane was quarantined.

  RED-H2 construction: pane `q` started with `quarantine_token: make_ref()`, capture
  IDLE and debounce 0. The named assertion is on the v2 send reply's `error`, and its
  message carries the observed word, because ExUnit prints no left/right for an
  assertion with a custom message.

  Control: pane `o`, started through the same helper with the same literal option
  list except that the token value is `nil` (read by `init/1` as no quarantine). Same
  store, server and socket. It answers `sent` and pastes once, so the harness reaches
  a paste and the RED row is not vacuous. "Same construction" means the same option
  list except the token; it does not mean the same pane or the same timing.

  Harness copied from ns15_g002_refusal_findings_red_test.exs (itself copied from
  ns42_c008_timeout_and_validation_test.exs): a `ReceiptStore` on a unique inbox, a
  real `AiPair.IPC.Server` with that store, and a recording `paste_fn`. Pane ids are
  built at runtime.

  The describe "CHARACTERISATION (base-GREEN, never RED)" is NOT a RED row. It was
  added in S2 step 2G as a base-GREEN characterisation control: a quarantined pane in
  `:busy` or `:dead` already refuses a v2 send as `pane_quarantined` on the base, it is
  qualified GREEN before any RED step, and it is never listed in a RED receipt. The
  "red" in this file's name refers to the H-2 row only. Its panes are started through
  `start_pane!/4` with a capture marker; the H-2 rows keep the default `IDLE_MARKER`.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns15_g002_h2_red_" <> Integer.to_string(n))
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})

    start_supervised!(
      {Server, inbox: inbox, name: :"ns15_g002_h2_red_server_#{n}", receipt_store: store}
    )

    # One Agent counts pastes per pane id.
    paste = start_supervised!({Agent, fn -> %{} end})

    {:ok, n: n, store: store, paste: paste, sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "RED-H2: a v2 send to a quarantined pane is refused as pane_quarantined" do
    test "a quarantined idle pane refuses a v2 send with its own word", c do
      q = pane_id(c, "q")
      assert ReceiptLog.valid_pane?(q)

      sm = start_pane!(c, q, make_ref())

      # Preconditions: quarantined, idle, and the fresh id has no record.
      assert StateMachine.status(sm).quarantined == true
      assert :ok = await_state(sm, :idle)
      assert StateMachine.state(sm) == :idle

      id = id(c, "red-h2")
      text = "RED-H2 send to a quarantined pane " <> Integer.to_string(c.n)
      assert reconcile!(c, q, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(q, id, text))

      assert reply["protocol_version"] == 2
      assert reply["ok"] == false
      assert reply["pane_id"] == q
      assert reply["msg_id"] == id

      assert reply["error"] == "pane_quarantined",
             "H-2: a v2 send to a quarantined pane must be refused as pane_quarantined; " <>
               "observed error " <> inspect(reply["error"])

      # Follow-ons: refused before admission, nothing pasted or queued.
      assert pastes(c, q) == 0
      assert StateMachine.pending_count(sm) == 0
      answer = reconcile!(c, q, id, text)
      assert answer["outcome"] == "absent"
      refute Map.has_key?(answer, "delivery_attempt")
      assert StateMachine.status(sm).quarantined == true
    end

    test "control: the same option list without a token pastes once", c do
      o = pane_id(c, "o")
      assert ReceiptLog.valid_pane?(o)

      sm = start_pane!(c, o, nil)
      assert StateMachine.status(sm).quarantined == false
      assert :ok = await_state(sm, :idle)
      assert StateMachine.state(sm) == :idle

      id = id(c, "red-h2-control")
      text = "RED-H2 control send " <> Integer.to_string(c.n)
      assert reconcile!(c, o, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(o, id, text))

      assert reply["ok"] == true
      assert reply["status"] == "sent"
      assert pastes(c, o) == 1
    end
  end

  describe "CHARACTERISATION (base-GREEN, never RED): a quarantined pane in :busy or :dead still refuses a v2 send as pane_quarantined" do
    test "a quarantined busy pane refuses a v2 send with its own word (base-GREEN characterisation)",
         c do
      q = pane_id(c, "qbusy")
      assert ReceiptLog.valid_pane?(q)

      sm = start_pane!(c, q, make_ref(), "BUSY_MARKER")

      # Preconditions: quarantined, busy, and the fresh id has no record.
      assert StateMachine.status(sm).quarantined == true
      assert :ok = await_state(sm, :busy)

      id = id(c, "char-busy")
      text = "characterisation send to a quarantined busy pane " <> Integer.to_string(c.n)
      assert reconcile!(c, q, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(q, id, text))

      assert_quarantined_refusal!(c, sm, q, id, text, reply)
    end

    test "a quarantined dead pane refuses a v2 send with its own word (base-GREEN characterisation)",
         c do
      q = pane_id(c, "qdead")
      assert ReceiptLog.valid_pane?(q)

      sm = start_pane!(c, q, make_ref(), "IDLE_MARKER")

      # Preconditions: quarantined, then driven from idle to the terminal dead
      # state, and the fresh id has no record.
      assert StateMachine.status(sm).quarantined == true
      assert :ok = await_state(sm, :idle)
      StateMachine.mark_dead(sm)
      assert :ok = await_state(sm, :dead)

      id = id(c, "char-dead")
      text = "characterisation send to a quarantined dead pane " <> Integer.to_string(c.n)
      assert reconcile!(c, q, id, text)["outcome"] == "absent"

      reply = send_frame!(c, send_frame(q, id, text))

      assert_quarantined_refusal!(c, sm, q, id, text, reply)
    end
  end

  # ===== helpers =====

  # The same assertions as the RED-H2 row, shared by the two characterisation rows.
  defp assert_quarantined_refusal!(c, sm, q, id, text, reply) do
    assert reply["protocol_version"] == 2
    assert reply["ok"] == false
    assert reply["pane_id"] == q
    assert reply["msg_id"] == id

    assert reply["error"] == "pane_quarantined",
           "a v2 send to a quarantined pane must be refused as pane_quarantined; " <>
             "observed error " <> inspect(reply["error"])

    # Refused before admission, nothing pasted or queued.
    assert pastes(c, q) == 0
    assert StateMachine.pending_count(sm) == 0
    answer = reconcile!(c, q, id, text)
    assert answer["outcome"] == "absent"
    refute Map.has_key?(answer, "delivery_attempt")
    assert StateMachine.status(sm).quarantined == true
  end

  defp pane_id(c, tag),
    do: "%" <> "ns15_g002_h2_red_" <> Integer.to_string(c.n) <> "_" <> tag

  defp start_pane!(c, pane, token, marker \\ "IDLE_MARKER") do
    paste = c.paste

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _pane_id -> {:ok, marker} end,
        paste_fn: fn pane_id, _text ->
          Agent.update(paste, &Map.update(&1, pane_id, 1, fn count -> count + 1 end))
          :ok
        end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0,
        quarantine_token: token
      )

    on_exit(fn -> PaneSupervisor.stop_pane(pane) end)
    sm
  end

  defp pastes(c, pane), do: Agent.get(c.paste, &Map.get(&1, pane, 0))

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
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(client)
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
