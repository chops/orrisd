defmodule AiPair.Delivery.NS42C008TimeoutAndValidationTest do
  @moduledoc """
  NS-42.C.008 (ambiguity), on the daemon's v2 IPC send path.

  Register failure control: "Generic paste_failed, send_timeout or failed queue drain
  converted to not_delivered/absent fails; these remain ambiguous. Only no record or
  proven pre-paste non-delivery may answer absent. Ambiguity cannot justify retry through
  optimistic non-delivery; a later attempt after proven non-delivery remains allowed."

  The harness is the real path: a `ReceiptStore` on a unique inbox, a real
  `AiPair.IPC.Server` with that store, and a real pane started through
  `AiPair.PaneSupervisor.start_pane/2`. Frames are raw v2 JSON over the UNIX socket. The
  paste function is the only double, because the clause is about the daemon's send path
  and its receipt, not about tmux.

  W1, send_timeout on the receipted path. `delivery.ex:99` answers
  `{ok: false, error: "send_timeout"}` when the handler's call to the pane exceeds
  `:send_call_timeout_ms` (`delivery.ex:107`). The pane has already admitted the attempt
  and is inside the paste (`state_machine.ex:510-535`, `:567-578`); the caller's timeout
  does not stop it. While the paste is held the receipt answers `ambiguous`, never
  `absent`; it then finalizes `delivered` or `ambiguous` by the paste's own result, never
  `not_delivered`; and a retry of an ambiguous id is a duplicate, not a second paste.

  W2, pre-paste request validation. `send_to_pane/2` validates identity and text BEFORE
  any admission (`delivery.ex:80-81`, validators `:128-145`), so `missing_text` and
  `oversize` refusals admit no attempt: the log is unchanged, nothing is pasted, and
  reconcile answers `absent` with no `delivery_attempt` (no record). The register row's
  "pre-paste validation ... may prove not_delivered" is met here only in that form: no
  record, therefore absent. This file does not claim that a validation refusal writes a
  `not_delivered` record; whether "no record" satisfies the row wording is the
  reviewer's decision.

  Controls:
    * C1: the same socket, pane and store with a paste that returns `:ok` at once
      answers `sent` and reconciles `delivered`, so the harness reaches a paste and the
      timeout rows are not vacuous.
    * C2: a dead pane over the same socket reconciles `absent` at `delivery_attempt: 1`
      (proven `not_delivered`), so the reconcile helper can observe `absent` and the W1
      refutations of `absent` are meaningful.
    * C3: the paste-start notice is stamped before the `send_timeout` reply was
      received, so each timeout is a timeout inside the paste, not a pre-paste refusal.

  `async: false`, because W1 sets the application env `:send_call_timeout_ms`.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.IPC.Server
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @max_text_bytes 524_288
  @short_timeout_ms 50

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "ns42_c008_#{n}")
    File.mkdir_p!(Path.join(inbox, "sock"))
    File.chmod!(Path.join(inbox, "sock"), 0o700)
    on_exit(fn -> File.rm_rf!(inbox) end)

    previous = Application.fetch_env(:ai_pair, :send_call_timeout_ms)
    on_exit(fn -> restore_timeout(previous) end)

    store = start_supervised!({ReceiptStore, inbox: inbox})

    start_supervised!({Server, inbox: inbox, name: :"ns42_c008_server_#{n}", receipt_store: store})

    # One Agent holds the paste mode and a count of pastes per text.
    paste = start_supervised!({Agent, fn -> %{mode: :immediate, counts: %{}} end})

    {:ok,
     n: n,
     store: store,
     paste: paste,
     previous_timeout: previous,
     log: ReceiptStore.path(store),
     pane: "%ns42_c008_#{n}",
     sock: Path.join(inbox, "sock/ai-pair.sock")}
  end

  describe "W1: send_timeout on the v2 receipted path stays ambiguous" do
    test "a timed-out send is ambiguous while held, finalizes by the paste's result, and " <>
           "is never retried",
         c do
      sm = start_idle_pane!(c)

      # C1: the same socket, pane and store reach a paste and deliver.
      c1 = id(c, "c1")
      c1_text = "C1 immediate paste #{c.n}"
      assert %{"ok" => true, "status" => "sent"} = send_frame!(c, send_frame(c, c1, c1_text))

      assert %{"outcome" => "delivered", "delivery_attempt" => 1} =
               reconcile!(c, c1, c1_text)

      assert pastes(c, c1_text) == 1

      # From here the handler's call to the pane times out after 50 ms.
      Application.put_env(:ai_pair, :send_call_timeout_ms, @short_timeout_ms)
      set_mode(c, :gated)

      # ---- the gate is released with :ok ----
      id1 = id(c, "w1-ok")
      text1 = "W1 held paste released ok #{c.n}"
      :ok = ReceiptStore.observe(c.store, id1)

      {reply, replied_at} = timed_send!(c, send_frame(c, id1, text1))
      assert_send_timeout(reply, c, id1)
      assert_paste_started_before(sm, text1, replied_at)

      # While the paste is held: ambiguous, never absent.
      held = reconcile!(c, id1, text1)
      assert held["outcome"] == "ambiguous"
      refute held["outcome"] == "absent"
      assert held["delivery_attempt"] == 1

      send(sm, {:release_paste, :ok})
      assert_receive {:receipt_finalized, ^id1, "delivered"}, 2_000

      assert %{"outcome" => "delivered", "delivery_attempt" => 1} = reconcile!(c, id1, text1)
      assert pastes(c, text1) == 1
      assert statuses(c, id1) == [{1, "pending"}, {1, "delivered"}]

      # ---- the gate is released with a generic paste error ----
      id2 = id(c, "w1-error")
      text2 = "W1 held paste released error #{c.n}"
      :ok = ReceiptStore.observe(c.store, id2)

      {reply, replied_at} = timed_send!(c, send_frame(c, id2, text2))
      assert_send_timeout(reply, c, id2)
      assert_paste_started_before(sm, text2, replied_at)

      held = reconcile!(c, id2, text2)
      assert held["outcome"] == "ambiguous"
      refute held["outcome"] == "absent"

      send(sm, {:release_paste, {:error, :x}})
      assert_receive {:receipt_finalized, ^id2, "ambiguous"}, 2_000

      assert %{"outcome" => "ambiguous", "delivery_attempt" => 1} = reconcile!(c, id2, text2)

      recorded = statuses(c, id2)
      assert recorded == [{1, "pending"}, {1, "ambiguous"}]

      refute Enum.any?(recorded, &match?({_, "not_delivered"}, &1)),
             "a generic paste error after a send_timeout is ambiguous, never not_delivered"

      # ---- ambiguity grants no retry ----
      log_before_retry = File.read!(c.log)
      retry = send_frame!(c, send_frame(c, id2, text2))

      assert %{"ok" => true, "duplicate" => true, "status" => "ambiguous"} = retry
      assert retry["delivery_attempt"] == 1
      assert pastes(c, text2) == 1, "an ambiguous id must not be pasted a second time"
      assert File.read!(c.log) == log_before_retry, "a duplicate opens no attempt"
      refute_received {:paste_started, _, ^text2, _}

      # C2: the reconcile helper can observe absence. The default timeout is restored so
      # the dead-pane refusal (two appends) is not raced by the 50 ms bound.
      restore_timeout(c.previous_timeout)
      StateMachine.mark_dead(sm)
      assert :ok = await_state(sm, :dead)

      c2 = id(c, "c2")
      c2_text = "C2 dead pane #{c.n}"
      assert %{"ok" => false, "error" => "pane_dead"} = send_frame!(c, send_frame(c, c2, c2_text))

      assert %{"outcome" => "absent", "delivery_attempt" => 1, "status" => "not_delivered"} =
               reconcile!(c, c2, c2_text)

      assert pastes(c, c2_text) == 0
    end
  end

  describe "W2: a pre-paste validation refusal admits no attempt" do
    test "missing, non-string and oversize text are refused with no record, no paste and " <>
           "an absent reconcile",
         c do
      _sm = start_idle_pane!(c)
      oversize = String.duplicate("a", @max_text_bytes + 1)
      assert byte_size(oversize) == 524_289

      cases = [
        {"missing", :omit, "missing_text"},
        {"non-string", 123, "missing_text"},
        {"oversize", oversize, "oversize"}
      ]

      for {label, text, error} <- cases do
        id = id(c, "w2-#{label}")
        before = File.read!(c.log)

        frame =
          case text do
            :omit -> Map.delete(send_frame(c, id, ""), "text")
            other -> Map.put(send_frame(c, id, ""), "text", other)
          end

        reply = send_frame!(c, frame)

        assert reply["ok"] == false
        assert reply["error"] == error, "#{label}: refused as #{error}"
        assert reply["protocol_version"] == 2
        assert reply["msg_id"] == id

        assert File.read!(c.log) == before, "#{label}: a validation refusal writes nothing"
        assert total_pastes(c) == 0, "#{label}: nothing reaches the paste"

        hash_text = if is_binary(text), do: text, else: ""
        answer = reconcile!(c, id, hash_text)

        assert answer["outcome"] == "absent"

        refute Map.has_key?(answer, "delivery_attempt"),
               "#{label}: absent here is the no-record form; no attempt was admitted"
      end

      # Control: the same harness does write and paste for a valid send, so the two
      # "nothing happened" detectors above can fire.
      id = id(c, "w2-control")
      before = File.read!(c.log)
      assert %{"ok" => true, "status" => "sent"} = send_frame!(c, send_frame(c, id, "valid"))
      refute File.read!(c.log) == before
      assert total_pastes(c) == 1
      assert %{"outcome" => "delivered", "delivery_attempt" => 1} = reconcile!(c, id, "valid")
    end
  end

  # ===== helpers =====

  defp start_idle_pane!(c) do
    test = self()
    paste = c.paste

    paste_fn = fn _pane_id, text ->
      Agent.update(paste, fn s -> %{s | counts: Map.update(s.counts, text, 1, &(&1 + 1))} end)

      case Agent.get(paste, & &1.mode) do
        :immediate ->
          :ok

        :gated ->
          send(test, {:paste_started, self(), text, System.monotonic_time()})

          receive do
            {:release_paste, result} -> result
          after
            5_000 -> {:error, :gate_timeout}
          end
      end
    end

    {:ok, sm} =
      PaneSupervisor.start_pane(c.pane,
        receipt_store: c.store,
        capture_fn: fn _pane_id -> {:ok, "IDLE_MARKER"} end,
        paste_fn: paste_fn,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(c.pane) end)
    assert :ok = await_state(sm, :idle)
    sm
  end

  defp set_mode(c, mode), do: Agent.update(c.paste, &%{&1 | mode: mode})
  defp pastes(c, text), do: Agent.get(c.paste, &Map.get(&1.counts, text, 0))
  defp total_pastes(c), do: Agent.get(c.paste, &(&1.counts |> Map.values() |> Enum.sum()))

  defp restore_timeout({:ok, value}),
    do: Application.put_env(:ai_pair, :send_call_timeout_ms, value)

  defp restore_timeout(:error), do: Application.delete_env(:ai_pair, :send_call_timeout_ms)

  defp id(c, seed),
    do: "snd_" <> Base.encode16(:crypto.hash(:sha256, "#{seed}-#{c.n}"), case: :lower)

  defp hash(text), do: Payload.hash(Payload.new(text))

  defp send_frame(c, id, text) do
    %{
      "cmd" => "send",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "text" => text
    }
  end

  defp reconcile!(c, id, text) do
    send_frame!(c, %{
      "cmd" => "reconcile",
      "protocol_version" => 2,
      "pane_id" => c.pane,
      "msg_id" => id,
      "payload_hash" => hash(text),
      "wait_ms" => 0
    })
  end

  defp send_frame!(c, payload) do
    {reply, _at} = timed_send!(c, payload)
    reply
  end

  # Returns the decoded reply and the monotonic time at which it was received.
  defp timed_send!(c, payload) do
    {:ok, client} =
      :gen_tcp.connect({:local, c.sock}, 0, [:binary, {:active, false}, {:packet, 4}], 1_000)

    try do
      :ok = :gen_tcp.send(client, Jason.encode!(payload))
      {:ok, frame} = :gen_tcp.recv(client, 0, 2_000)
      {Jason.decode!(frame), System.monotonic_time()}
    after
      :gen_tcp.close(client)
    end
  end

  defp assert_send_timeout(reply, c, id) do
    assert reply["ok"] == false
    assert reply["error"] == "send_timeout"
    assert reply["msg_id"] == id
    assert reply["pane_id"] == c.pane
    assert reply["protocol_version"] == 2
    refute Map.has_key?(reply, "outcome"), "a send_timeout reply states no outcome"
  end

  # C3: the paste had started before the timeout reply was received.
  defp assert_paste_started_before(sm, text, replied_at) do
    assert_receive {:paste_started, ^sm, ^text, started_at}, 1_000

    assert started_at < replied_at,
           "the send_timeout must come from a paste in progress, not a pre-paste refusal"
  end

  defp statuses(c, id) do
    c.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == id))
    |> Enum.map(&{&1["delivery_attempt"], &1["status"]})
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
