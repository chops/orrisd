defmodule AiPair.Delivery.ReceiptStoreAdmissionRedTest do
  @moduledoc """
  NS-32.M.002 RB-3a RED, row A6 (producer RED scope r3; RB-3a scope r3, C1): the store is closed
  only AFTER the drain. While a quiesce drains, a ticket taken before the close completes every
  store call it needs (admit, queue, begin_paste, begin_command, end_command, transition, and the
  payload release of a terminal transition); once no ticket is outstanding, AiPair.Admission calls
  ReceiptStore.close_admission/1, after which admit, queue, begin_paste and begin_command are
  refused with {:error, :quiescing}, and completion and read calls (transition, end_command,
  reconcile, observe, effect_status, restore_registry) are never refused. resume reopens the
  store (ReceiptStore.reopen_admission/1) before admission.

  API pinned here (GREEN; apply/3 at RED): ReceiptStore.close_admission/1 and
  reopen_admission/1, each :ok; AiPair.Admission.start_link/1 option :receipt_store.
  """

  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore}

  @text "rb3a admission row"
  @pane "%rb3a_a6"
  @guard_ms 5_000

  setup do
    inbox = Path.join(System.tmp_dir!(), "rb3a-a6-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    {:ok, store: store, inbox: inbox, hash: Payload.hash(Payload.new(@text))}
  end

  defp id, do: "snd_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp admit(c, id) do
    {:ok, {:admitted, %{operation_token: token}}} =
      ReceiptStore.admit(c.store, id, @pane, c.hash, self())

    token
  end

  defp gate(id, token),
    do: %{pane: @pane, msg_id: id, attempt: 1, token: token, buffer: "ai_pair_7"}

  defp await_closed(admission, deadline) do
    case apply(AiPair.Admission, :enter, [admission, :ipc_send]) do
      {:error, :quiescing} ->
        :ok

      {:ok, extra} ->
        :ok = apply(AiPair.Admission, :exit, [admission, extra])

        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("admission never closed"),
          else: await_closed(admission, deadline)
    end
  end

  defp payload_files(c) do
    case File.ls(Path.join([c.inbox, "delivery", "payloads"])) do
      {:ok, names} -> Enum.reject(names, &String.starts_with?(&1, ".tmp-"))
      {:error, :enoent} -> []
    end
  end

  test "A6 after close_admission the store refuses new work and keeps completing and reading", c do
    # one receipt left pending, and one with a transaction begun before the close
    open_id = id()
    open_token = admit(c, open_id)
    begun_id = id()
    begun_token = admit(c, begun_id)
    :ok = ReceiptStore.begin_paste(c.store, begun_id, begun_token)
    {:ok, marker} = ReceiptStore.begin_command(c.store, gate(begun_id, begun_token))
    other_id = id()
    other_token = admit(c, other_id)

    assert apply(ReceiptStore, :close_admission, [c.store]) == :ok

    # new work is refused
    assert ReceiptStore.admit(c.store, id(), @pane, c.hash, self()) == {:error, :quiescing}
    assert ReceiptStore.queue(c.store, open_id, open_token, @text) == {:error, :quiescing}
    assert ReceiptStore.begin_paste(c.store, other_id, other_token) == {:error, :quiescing}

    assert ReceiptStore.begin_command(c.store, gate(other_id, other_token)) ==
             {:error, :quiescing}

    # completion and reads are never refused
    assert ReceiptStore.end_command(c.store, marker, 0, nil) == :ok
    assert ReceiptStore.transition(c.store, begun_id, begun_token, "delivered") == :ok
    assert ReceiptStore.transition(c.store, open_id, open_token, "not_delivered") == :ok
    assert ReceiptStore.observe(c.store, open_id) == :ok
    assert {:ok, _view} = ReceiptStore.reconcile(c.store, begun_id, @pane, c.hash, wait_ms: 0)
    assert %{unresolved: [], residual: _} = ReceiptStore.effect_status(c.store)
    assert is_map(ReceiptStore.restore_registry(c.store))

    assert apply(ReceiptStore, :reopen_admission, [c.store]) == :ok
    assert {:ok, {:admitted, _}} = ReceiptStore.admit(c.store, id(), @pane, c.hash, self())
  end

  test "A6 a ticket held across quiesce completes its store calls; the store closes only after the drain",
       c do
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, "s"), case: :lower)

    {:ok, admission} =
      apply(AiPair.Admission, :start_link, [
        [bound_ms: 60_000, receipt_store: c.store, observe: fn -> {:ok, %{}} end]
      ])

    assert {:ok, ticket} = apply(AiPair.Admission, :enter, [admission, :ipc_send])
    task = Task.async(fn -> apply(AiPair.Admission, :quiesce, [admission, hash]) end)

    # the quiesce is draining: admission is closed (a new enter is refused) while the original
    # ticket is still held and the quiesce has not answered
    await_closed(admission, System.monotonic_time(:millisecond) + @guard_ms)
    assert Task.yield(task, 0) == nil

    # the store is still open for the ticket holder while the quiesce drains
    held_id = id()
    token = admit(c, held_id)
    assert ReceiptStore.queue(c.store, held_id, token, @text) == :ok
    assert length(payload_files(c)) == 1
    assert ReceiptStore.begin_paste(c.store, held_id, token) == :ok
    assert {:ok, marker} = ReceiptStore.begin_command(c.store, gate(held_id, token))
    assert ReceiptStore.end_command(c.store, marker, 0, nil) == :ok
    assert ReceiptStore.transition(c.store, held_id, token, "delivered") == :ok
    # the terminal transition released the queued payload
    assert payload_files(c) == []

    assert apply(AiPair.Admission, :exit, [admission, ticket]) == :ok
    assert {:ok, %{fence_id: _}} = Task.await(task, @guard_ms)

    # after the drain the store refuses new work
    assert ReceiptStore.admit(c.store, id(), @pane, c.hash, self()) == {:error, :quiescing}
  end
end
