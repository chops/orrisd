defmodule AiPair.Delivery.ReceiptBindingB1bRedTest do
  @moduledoc """
  B1b-fill RED (NS-15.G.002 B1b; scope r2 GO, design r6): a version 3 send binds its attempt to
  the pane identity proved under the pane's fence.

  - A v3 send's new attempt records the reply's `pane_identity` pair (registration_id,
    generation) on its pending line and every later line, boot finalization included.
  - A v1/v2 send records an explicit null pair; nothing infers one from the registry.
  - A duplicate never rewrites a stored pair; a new attempt after not_delivered takes only its
    own opener's pair.
  - A restored v3 queued attempt carries its pair to the registry and the handed entry; a v2 one
    restores with null (S3, held, must treat it as unreleasable).
  - The v3 admission path cannot run without a binding (F7).

  F4 is a control: the B1a-2 refusal already admits nothing at the base. The GREEN-only
  functions (ReceiptStore.admit/6, Delivery.send_core/3, StateMachine.send_receipted/6) are
  reached through apply/3: the file must compile at the base, and F7's deliberate nil arguments
  are clause failures a direct call would turn into a compile-time type warning under
  --warnings-as-errors. Every function the base already exports is called directly.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore, SystemFs}
  alias AiPair.IPC.{Delivery, DeliveryV3}
  alias AiPair.Pane.StateMachine
  alias AiPair.PaneRestore.Coordinator
  alias AiPair.PaneSupervisor
  alias AiPair.Test.MarkerClassifier

  @reg "reg_" <> String.duplicate("b1", 16)
  @generation "4207"
  @binding %{registration_id: @reg, generation: @generation}

  setup do
    suffix = System.unique_integer([:positive])
    inbox = Path.join(System.tmp_dir!(), "b1b-fill-#{suffix}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    start_supervised!({Coordinator, [name: Coordinator]}, restart: :temporary)
    pastes = start_supervised!({Agent, fn -> 0 end}, id: :pastes)
    records = start_supervised!({Agent, fn -> %{} end}, id: :records)

    c = %{inbox: inbox, pane: "%b1b_fill_#{suffix}", pastes: pastes, records: records}
    {:ok, Map.put(c, :store, start_store!(inbox))}
  end

  test "F1 a v3 send's pending line records the pair its reply reports as pane_identity", c do
    start_pane(c, "IDLE_MARKER")
    commit(c)

    reply = DeliveryV3.dispatch(v3_send(c, "f1"), context(c))
    assert %{ok: true, status: "sent", pane_identity: identity} = reply
    assert {identity.registration_id, identity.generation} == {@reg, @generation}

    lines = lines(c.inbox, id("f1"))
    assert [%{"status" => "pending"} = pending | _] = lines
    assert pair(pending) == {@reg, @generation}
    assert Enum.all?(lines, &(pair(&1) == {@reg, @generation})), inspect(lines)
  end

  test "F2 every later line of a bound attempt repeats its pair, boot finalization included", c do
    start_pane(c, "BUSY_MARKER")
    commit(c)
    assert %{ok: true, status: "queued"} = DeliveryV3.dispatch(v3_send(c, "f2-q"), context(c))

    {:ok, {:admitted, %{operation_token: token}}} = admit6(c.store, "f2-nd", c.pane, @binding)
    assert :ok = ReceiptStore.transition(c.store, id("f2-nd"), token, "not_delivered")
    {:ok, {:admitted, _}} = admit6(c.store, "f2-pend", c.pane, @binding)

    # The store dies first, so the pane's own exit cannot finalize the queued attempt.
    stop(c.store)
    PaneSupervisor.stop_pane(c.pane)
    stop(start_store!(c.inbox))

    assert statuses(c.inbox, id("f2-q")) == ["pending", "queued"]
    assert statuses(c.inbox, id("f2-nd")) == ["pending", "not_delivered"]
    assert statuses(c.inbox, id("f2-pend")) == ["pending", "ambiguous"]

    for seed <- ["f2-q", "f2-nd", "f2-pend"], line <- lines(c.inbox, id(seed)) do
      assert pair(line) == {@reg, @generation}, inspect(line)
    end
  end

  test "F3 a v2 send to the same durable pane records an explicit null pair; its v3 send binds",
       c do
    start_pane(c, "IDLE_MARKER")
    commit(c)

    assert %{ok: true, status: "sent"} = Delivery.dispatch(v2_send(c, "f3-v2"), c.store)
    assert %{ok: true, status: "sent"} = DeliveryV3.dispatch(v3_send(c, "f3-v3"), context(c))

    for line <- lines(c.inbox, id("f3-v2")) do
      assert Map.fetch(line, "registration_id") == {:ok, nil} and
               Map.fetch(line, "generation") == {:ok, nil},
             inspect(line)
    end

    assert Enum.all?(lines(c.inbox, id("f3-v3")), &(pair(&1) == {@reg, @generation}))
  end

  test "F4 control: a v3 send refused pane_identity_unavailable admits nothing", c do
    start_pane(c, "IDLE_MARKER")
    before = receipts_bytes(c.inbox)

    assert %{ok: false, error: "pane_identity_unavailable"} =
             DeliveryV3.dispatch(v3_send(c, "f4"), context(c))

    assert receipts_bytes(c.inbox) == before
    assert Agent.get(c.pastes, & &1) == 0
  end

  test "F5 a duplicate never retrofits a stored null pair; a new attempt takes its opener's pair",
       c do
    start_pane(c, "IDLE_MARKER")
    commit(c)
    assert %{ok: true, status: "sent"} = Delivery.dispatch(v2_send(c, "f5-dup"), c.store)

    reply = DeliveryV3.dispatch(v3_send(c, "f5-dup"), context(c))
    assert %{ok: true, duplicate: true, pane_identity: %{registration_id: @reg}} = reply
    assert Enum.all?(lines(c.inbox, id("f5-dup")), &(pair(&1) == {nil, nil}))

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id("f5-nd"), c.pane, payload_hash("f5-nd"), self())

    assert :ok = ReceiptStore.transition(c.store, id("f5-nd"), token, "not_delivered")
    assert %{ok: true, status: "sent"} = DeliveryV3.dispatch(v3_send(c, "f5-nd"), context(c))

    {first, second} = Enum.split_with(lines(c.inbox, id("f5-nd")), &(&1["delivery_attempt"] == 1))
    assert Enum.all?(first, &(pair(&1) == {nil, nil})), "attempt 1 stays unbound"
    assert second != [] and Enum.all?(second, &(pair(&1) == {@reg, @generation}))
  end

  test "F6 a restored v3 queued attempt hands its pair over; a v2 one restores unbound", c do
    start_pane(c, "BUSY_MARKER")
    commit(c)
    assert %{ok: true, status: "queued"} = Delivery.dispatch(v2_send(c, "f6-v2"), c.store)
    assert %{ok: true, status: "queued"} = DeliveryV3.dispatch(v3_send(c, "f6-v3"), context(c))

    # The store dies first, so the pane's own exit cannot finalize the queued attempts.
    stop(c.store)
    PaneSupervisor.stop_pane(c.pane)
    store = start_store!(c.inbox)

    entries = ReceiptStore.restore_registry(store)[c.pane]
    by_id = Map.new(entries, &{&1.msg_id, &1})
    assert %{registration_id: @reg, generation: @generation} = by_id[id("f6-v3")]
    assert %{registration_id: nil, generation: nil} = by_id[id("f6-v2")]

    {:ok, cap} = ReceiptStore.issue_restore_capability(store, c.pane, make_ref())
    {:ok, handed} = ReceiptStore.claim_restored(store, c.pane, cap)
    handed = Map.new(handed, &{&1.msg_id, &1})
    assert %{registration_id: @reg, generation: @generation} = handed[id("f6-v3")]
    assert %{registration_id: nil, generation: nil} = handed[id("f6-v2")]
  end

  test "F7 the v3 admission path cannot run without a binding and writes nothing", c do
    start_pane(c, "IDLE_MARKER")
    {:ok, pid} = PaneSupervisor.whereis_pane(c.pane)
    before = receipts_bytes(c.inbox)

    assert_raise FunctionClauseError, fn ->
      apply(ReceiptStore, :admit, [c.store, id("f7"), c.pane, payload_hash("f7"), self(), nil])
    end

    assert_raise FunctionClauseError, fn ->
      apply(Delivery, :send_core, [v3_send(c, "f7"), c.store, nil])
    end

    assert_raise FunctionClauseError, fn ->
      apply(StateMachine, :send_receipted, [pid, "f7 bytes", 1_000, id("f7"), c.store, nil])
    end

    for bad <- [
          %{registration_id: "reg_" <> String.duplicate("B", 32), generation: @generation},
          %{registration_id: @reg, generation: "12a"}
        ] do
      assert {:error, {:invalid_registration_binding, :grammar}} =
               admit6(c.store, "f7", c.pane, bad),
             "a binding the log could not read back is refused before any line"
    end

    assert receipts_bytes(c.inbox) == before
  end

  # --- helpers -------------------------------------------------------------------------------

  defp admit6(store, seed, pane, binding),
    do: apply(ReceiptStore, :admit, [store, id(seed), pane, payload_hash(seed), self(), binding])

  defp id(seed), do: "snd_" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  defp bytes(seed), do: seed <> " bytes"
  defp payload_hash(seed), do: Payload.hash(Payload.new(bytes(seed)))

  defp v3_send(c, seed),
    do: %{
      "cmd" => "send",
      "protocol_version" => 3,
      "msg_id" => id(seed),
      "pane_id" => c.pane,
      "text" => bytes(seed)
    }

  defp v2_send(c, seed), do: %{v3_send(c, seed) | "protocol_version" => 2}

  defp context(c) do
    %{
      receipt_store: c.store,
      durable: true,
      committed: fn pane ->
        case Agent.get(c.records, &Map.get(&1, pane)) do
          nil -> :none
          record -> {:ok, record}
        end
      end,
      current_pid: fn _pane -> {:ok, 4242} end
    }
  end

  defp commit(c) do
    record = %{"registration_id" => @reg, "session_gen" => @generation}
    Agent.update(c.records, &Map.put(&1, c.pane, record))
  end

  defp start_store!(inbox) do
    assert {:ok, pid} =
             GenServer.start(ReceiptStore,
               inbox: inbox,
               fs: SystemFs.new(),
               restore_issuer: self()
             )

    on_exit(fn -> stop(pid) end)
    pid
  end

  defp stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end
  end

  defp start_pane(c, marker) do
    {:ok, pid} =
      PaneSupervisor.start_pane(c.pane,
        registration_id: @reg,
        receipt_store: c.store,
        capture_fn: fn _ -> {:ok, marker} end,
        paste_fn: fn _, _ -> Agent.update(c.pastes, &(&1 + 1)) end,
        classifier: MarkerClassifier,
        poll_interval_ms: 5,
        idle_debounce_ms: 0
      )

    on_exit(fn -> PaneSupervisor.stop_pane(c.pane) end)
    await_state(pid, if(marker == "IDLE_MARKER", do: :idle, else: :busy), 100)
  end

  defp await_state(_pid, _expected, 0), do: flunk("pane did not classify")

  defp await_state(pid, expected, remaining) do
    if StateMachine.state(pid) != expected do
      Process.sleep(5)
      await_state(pid, expected, remaining - 1)
    end
  end

  defp receipts_bytes(inbox) do
    case File.read(Path.join([inbox, "delivery", "receipts.jsonl"])) do
      {:ok, bytes} -> bytes
      {:error, :enoent} -> ""
    end
  end

  defp lines(inbox, msg) do
    inbox
    |> receipts_bytes()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["message_id"] == msg))
  end

  defp statuses(inbox, msg), do: Enum.map(lines(inbox, msg), & &1["status"])
  defp pair(line), do: {line["registration_id"], line["generation"]}
end
