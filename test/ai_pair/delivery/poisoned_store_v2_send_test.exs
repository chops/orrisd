defmodule AiPair.Delivery.PoisonedStoreV2SendTest do
  @moduledoc """
  D5 (C5-SCOPE:379-381), base-GREEN CHARACTERISATION added in S2 step 2G. These rows
  pin behaviour the base already has: they are qualified GREEN before any RED step and
  are never listed in a RED receipt.

  The fault is a POISONED receipt store, not a stopped one. A stopped store would make
  `ReceiptStore.reconcile/5` in `AiPair.IPC.Delivery.send_to_pane/2` exit first, which
  is caught and answered `delivery_unavailable`; a poisoned store still answers the
  read as `absent`, so the send reaches the registered pane's atomic admission and is
  refused there before any paste.

  Each test gets a FRESH, UNPOISONED store on its own inbox through `AiPair.Test.FaultFs`.
  The positive control shows the harness observes a paste inside `@paste_deadline_ms`,
  so the poisoned row's zero-paste wait over the same deadline is not vacuous.

  Pane ids are built at runtime, because the redaction gate refuses literal tmux pane
  ids. `AiPair.IPC.Delivery.dispatch/2` is called directly with the store, so no socket
  or server is needed.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptLog, ReceiptStore}
  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneSupervisor
  alias AiPair.Test.{FaultFs, MarkerClassifier}

  # One bound for BOTH tests, so the negative wait is exactly as long as the positive one.
  @paste_deadline_ms 1_000

  setup do
    n = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "poisoned_store_v2_send_" <> Integer.to_string(n))
    on_exit(fn -> File.rm_rf!(inbox) end)
    File.mkdir_p!(inbox)

    fs = FaultFs.new()
    store = start_supervised!({ReceiptStore, inbox: inbox, fs: fs})

    # One Agent counts pastes per pane id.
    paste = start_supervised!({Agent, fn -> %{} end})

    {:ok, n: n, store: store, fs: fs, paste: paste}
  end

  test "control: an unpoisoned store and registered pane answer a v2 send with sent and exactly one paste (base-GREEN characterisation)",
       c do
    pane = pane_id(c, "control")
    assert ReceiptLog.valid_pane?(pane)

    sm = start_pane!(c, pane)
    assert :ok = await_state(sm, :idle)

    fresh = id(c, "control")
    text = "poisoned-store control send " <> Integer.to_string(c.n)

    reply = Delivery.dispatch(send_frame(pane, fresh, text), c.store)

    assert reply.ok == true
    assert reply.status == "sent"
    assert reply.protocol_version == 2
    assert reply.msg_id == fresh
    assert reply.pane_id == pane

    assert eventually(fn -> pastes(c, pane) == 1 end, @paste_deadline_ms),
           "the unpoisoned control never pasted, so the zero-paste row would be vacuous"

    assert pastes(c, pane) == 1
  end

  test "a v2 send to a registered pane over a poisoned store answers receipt_store_unavailable and pastes nothing (base-GREEN characterisation)",
       c do
    pane = pane_id(c, "poisoned")
    assert ReceiptLog.valid_pane?(pane)

    sm = start_pane!(c, pane)
    assert :ok = await_state(sm, :idle)

    # POISON: the first append's fsync fails, which poisons the store.
    throwaway_a = id(c, "throwaway-a")
    FaultFs.inject(c.fs, :sync, 1, {:error, :eio})

    assert {:error, {:receipt_sync_failed, :eio}} =
             ReceiptStore.admit(c.store, throwaway_a, pane, hash("throwaway"), self())

    # PRECONDITION: the store now refuses every admission.
    throwaway_b = id(c, "throwaway-b")

    assert {:error, :receipt_store_unavailable} =
             ReceiptStore.admit(c.store, throwaway_b, pane, hash("throwaway-b"), self())

    # Only then: a fresh id, distinct from both throwaways, through the v2 send path.
    fresh = id(c, "poisoned")
    refute fresh in [throwaway_a, throwaway_b]
    text = "poisoned-store send " <> Integer.to_string(c.n)

    reply = Delivery.dispatch(send_frame(pane, fresh, text), c.store)

    assert reply == %{
             ok: false,
             error: "receipt_store_unavailable",
             protocol_version: 2,
             msg_id: fresh,
             pane_id: pane
           }

    # Zero paste over the full deadline the control shows is enough to see one.
    refute eventually(fn -> pastes(c, pane) > 0 end, @paste_deadline_ms),
           "a send over a poisoned store reached the paste boundary"

    assert pastes(c, pane) == 0
    assert StateMachine.pending_count(sm) == 0
  end

  # ===== helpers =====

  defp pane_id(c, tag),
    do: "%" <> "poisoned_store_v2_" <> Integer.to_string(c.n) <> "_" <> tag

  defp start_pane!(c, pane) do
    paste = c.paste

    {:ok, sm} =
      PaneSupervisor.start_pane(pane,
        receipt_store: c.store,
        capture_fn: fn _pane_id -> {:ok, "IDLE_MARKER"} end,
        paste_fn: fn pane_id, _text ->
          Agent.update(paste, &Map.update(&1, pane_id, 1, fn count -> count + 1 end))
          :ok
        end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
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

  # Copied from test/ai_pair/pane_restore/quarantine_test.exs (a private helper there).
  # The `\\ 1_000` default is dropped: every call here passes @paste_deadline_ms, and an
  # unused default would be a compile warning.
  defp eventually(fun, deadline_ms) do
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
end
