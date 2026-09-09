defmodule AiPair.Delivery.CaptureRecoveryIntegrationTest do
  use ExUnit.Case, async: true
  alias AiPair.Delivery.ReceiptStore
  alias AiPair.Pane.StateMachine

  test "capture failure holds the owned receipt until fresh stable idle, then pastes once" do
    inbox = Path.join(System.tmp_dir!(), "receipt-capture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)
    store = start_supervised!({ReceiptStore, inbox: inbox})
    captures = start_supervised!({Agent, fn -> {:ok, "BUSY_MARKER"} end})
    owner = self()

    pane =
      start_supervised!(%{
        id: StateMachine,
        start:
          {StateMachine, :start_link,
           [
             [
               pane_id: "%receipt_capture",
               receipt_store: store,
               capture_fn: fn _ -> Agent.get(captures, & &1) end,
               paste_fn: fn _, _ ->
                 send(owner, :pasted)
                 :ok
               end,
               classifier: AiPair.Test.MarkerClassifier,
               poll_interval_ms: 10,
               idle_debounce_ms: 300
             ]
           ]}
      })

    await(pane, :busy)
    id = "snd_" <> String.duplicate("c", 64)
    bytes = "controlled integration input"
    hash = "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:queued, :busy} = StateMachine.send_receipted(pane, bytes, 1_000, id, store)
    Agent.update(captures, fn _ -> {:ok, "IDLE_MARKER"} end)
    await(pane, :idle)
    Agent.update(captures, fn _ -> {:error, :capture_timeout} end)
    await(pane, :unknown)
    Process.sleep(350)
    assert StateMachine.pending_count(pane) == 1

    assert {:ok, %{outcome: "queued", delivery_attempt: 1}} =
             ReceiptStore.reconcile(store, id, "%receipt_capture", hash)

    refute_received :pasted
    :ok = ReceiptStore.observe(store, id)
    Agent.update(captures, fn _ -> {:ok, "IDLE_MARKER"} end)
    assert_receive {:receipt_finalized, ^id, "delivered"}, 1_000
    assert_received :pasted

    assert {:duplicate, %{status: "delivered", delivery_attempt: 1}} =
             StateMachine.send_receipted(pane, bytes, 1_000, id, store)

    refute_received :pasted
    assert StateMachine.pending_count(pane) == 0
  end

  defp await(pane, state, left \\ 100)
  defp await(_pane, state, 0), do: flunk("did not reach #{state}")

  defp await(pane, state, left) do
    if StateMachine.state(pane) != state do
      Process.sleep(10)
      await(pane, state, left - 1)
    end
  end
end
