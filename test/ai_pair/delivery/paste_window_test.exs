defmodule AiPair.Delivery.PasteWindowTest do
  use ExUnit.Case, async: true

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Test.FaultFs

  @id "snd_" <> String.duplicate("a", 64)
  @hash "sha256:" <> String.duplicate("b", 64)
  @pane "%test"

  setup do
    inbox = Path.join(System.tmp_dir!(), "paste-window-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    fs = FaultFs.new()
    store = start_supervised!({ReceiptStore, inbox: inbox, fs: fs})

    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(store, @id, @pane, @hash, self())

    {:ok, store: store, token: token, inbox: inbox, fs: fs}
  end

  defp begin_paste(store, token), do: apply(ReceiptStore, :begin_paste, [store, @id, token])

  defp reconcile(store, wait \\ 0),
    do: ReceiptStore.reconcile(store, @id, @pane, @hash, wait_ms: wait)

  test "queued is held until authenticated paste start, then unresolved without a new record", c do
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "queued")
    assert {:ok, %{outcome: "queued"}} = reconcile(c.store)
    before = File.read!(ReceiptStore.path(c.store))
    assert :ok = begin_paste(c.store, c.token)
    assert {:ok, %{outcome: "ambiguous"}} = reconcile(c.store)
    assert File.read!(ReceiptStore.path(c.store)) == before
  end

  test "an in-flight queued waiter sees finalization rather than stale queued", c do
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "queued")
    assert :ok = begin_paste(c.store, c.token)
    waiter = Task.async(fn -> reconcile(c.store, 1_000) end)
    assert Task.yield(waiter, 20) == nil
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "delivered")
    assert {:ok, %{outcome: "delivered"}} = Task.await(waiter)
  end

  test "an in-flight queued wait timeout is ambiguous", c do
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "queued")
    assert :ok = begin_paste(c.store, c.token)
    assert {:ok, %{outcome: "ambiguous"}} = reconcile(c.store, 10)
  end

  test "paste authorization is single-use even before finalization", c do
    assert :ok = begin_paste(c.store, c.token)
    assert {:error, :paste_already_started} = begin_paste(c.store, c.token)
  end

  test "foreign token cannot authorize a paste", c do
    assert {:error, {:foreign_operation_token, @id}} = begin_paste(c.store, make_ref())
    assert :ok = begin_paste(c.store, c.token)
  end

  test "a terminal token cannot authorize another paste", c do
    assert :ok = begin_paste(c.store, c.token)
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "delivered")
    assert {:error, :paste_not_pending} = begin_paste(c.store, c.token)
  end

  test "a superseded attempt cannot authorize the current attempt", c do
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "not_delivered")
    assert {:ok, {:admitted, next}} = ReceiptStore.admit(c.store, @id, @pane, @hash, self())
    assert {:error, {:stale_operation_token, 1, 2}} = begin_paste(c.store, c.token)
    assert :ok = begin_paste(c.store, next.operation_token)
  end

  test "paste start forbids later claims of proven non-delivery", c do
    assert :ok = begin_paste(c.store, c.token)

    assert {:error, :paste_outcome_unproven} =
             ReceiptStore.transition(c.store, @id, c.token, "not_delivered")

    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "ambiguous")
  end

  test "poisoned storage cannot authorize crossing the paste boundary", c do
    FaultFs.inject(c.fs, :sync, FaultFs.count(c.fs, :sync) + 1, {:error, :eio})
    assert {:error, _} = ReceiptStore.transition(c.store, @id, c.token, "queued")
    assert {:error, :receipt_store_unavailable} = begin_paste(c.store, c.token)
  end

  test "restart forgets runtime permission but durably marks unresolved paste ambiguous", c do
    assert :ok = ReceiptStore.transition(c.store, @id, c.token, "queued")
    assert :ok = begin_paste(c.store, c.token)
    stop_supervised!(ReceiptStore)
    revived = start_supervised!({ReceiptStore, inbox: c.inbox})
    assert {:ok, %{outcome: "ambiguous"}} = reconcile(revived)
    assert {:error, _} = begin_paste(revived, c.token)
  end

  test "owner loss wakes an in-flight waiter and persists ambiguity", c do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    id = "snd_" <> String.duplicate("c", 64)
    assert {:ok, {:admitted, admitted}} = ReceiptStore.admit(c.store, id, @pane, @hash, owner)
    assert :ok = ReceiptStore.transition(c.store, id, admitted.operation_token, "queued")
    assert :ok = apply(ReceiptStore, :begin_paste, [c.store, id, admitted.operation_token])
    waiter = Task.async(fn -> ReceiptStore.reconcile(c.store, id, @pane, @hash, wait_ms: 5_000) end)
    Process.exit(owner, :kill)
    assert {:ok, %{outcome: "ambiguous", status: "ambiguous"}} = Task.await(waiter, 500)
  end
end
