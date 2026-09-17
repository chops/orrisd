defmodule AiPair.Delivery.ReceiptFirstRetryTest do
  use ExUnit.Case, async: false

  alias AiPair.Delivery.{Payload, ReceiptStore}
  alias AiPair.IPC.Delivery
  alias AiPair.Pane.StateMachine

  defmodule PaneSpy do
    use GenServer

    def start_link(pane),
      do:
        GenServer.start_link(__MODULE__, [],
          name: {:via, Registry, {AiPair.Registry, {:pane, pane}}}
        )

    @impl true
    def init([]), do: {:ok, 0}

    @impl true
    def handle_call(:calls, _from, calls), do: {:reply, calls, calls}

    def handle_call({:send_receipted, _payload, _ctx, _id, _store}, _from, calls),
      do: {:reply, {:error, :receipt_store_mismatch}, calls + 1}
  end

  @id "snd_" <> String.duplicate("a", 64)
  @pane "%receipt_first"
  @other_pane "%receipt_other"
  @text "retained request bytes"

  setup do
    inbox =
      Path.join(System.tmp_dir!(), "orrisd_receipt_first_#{System.unique_integer([:positive])}")

    File.mkdir!(inbox)
    on_exit(fn -> File.rm_rf!(inbox) end)

    unless Process.whereis(AiPair.Registry) do
      start_supervised!({Registry, keys: :unique, name: AiPair.Registry})
    end

    store = start_supervised!({ReceiptStore, inbox: inbox})
    %{store: store}
  end

  test "delivered retry remains a typed duplicate after pane detachment", %{store: store} do
    {:ok, _} = Registry.register(AiPair.Registry, {:pane, @pane}, :synthetic_registration)
    seed(store, "delivered")
    Registry.unregister(AiPair.Registry, {:pane, @pane})
    before = File.read!(ReceiptStore.path(store))

    assert_duplicate(Delivery.dispatch(request(), store), "delivered")
    assert File.read!(ReceiptStore.path(store)) == before
  end

  for status <- ~w(queued ambiguous pending) do
    test "#{status} retry retains its receipt without a registered pane", %{store: store} do
      status = unquote(status)
      seed(store, status)
      before = File.read!(ReceiptStore.path(store))

      assert_duplicate(Delivery.dispatch(request(), store), status)
      assert File.read!(ReceiptStore.path(store)) == before
    end
  end

  test "changed text conflicts before missing-pane lookup without exposing stored payload", %{
    store: store
  } do
    seed(store, "delivered")
    before = File.read!(ReceiptStore.path(store))

    assert Delivery.dispatch(Map.put(request(), "text", "different bytes"), store) == %{
             ok: false,
             error: "conflict",
             protocol_version: 2,
             msg_id: @id,
             pane_id: @pane
           }

    assert File.read!(ReceiptStore.path(store)) == before
  end

  test "changed pane conflicts before missing-pane lookup without exposing stored identity", %{
    store: store
  } do
    seed(store, "queued")
    before = File.read!(ReceiptStore.path(store))

    assert Delivery.dispatch(Map.put(request(), "pane_id", @other_pane), store) == %{
             ok: false,
             error: "conflict",
             protocol_version: 2,
             msg_id: @id,
             pane_id: @other_pane
           }

    assert File.read!(ReceiptStore.path(store)) == before
  end

  test "missing pane with no receipt refuses without admitting an attempt", %{store: store} do
    before = File.read!(ReceiptStore.path(store))

    assert %{ok: false, error: "pane_not_found"} = Delivery.dispatch(request(), store)

    assert {:ok, %{outcome: "absent"} = view} =
             ReceiptStore.reconcile(store, @id, @pane, payload_hash())

    refute Map.has_key?(view, :delivery_attempt)
    assert File.read!(ReceiptStore.path(store)) == before
  end

  test "absent receipt still reaches the registered pane's admission path", %{store: store} do
    spy = start_spy(@pane, store)
    before = File.read!(ReceiptStore.path(store))

    assert %{ok: false, error: "receipt_store_mismatch"} = Delivery.dispatch(request(), store)
    assert GenServer.call(spy, :calls) == 2
    assert {:ok, %{outcome: "absent"}} = ReceiptStore.reconcile(store, @id, @pane, payload_hash())
    assert File.read!(ReceiptStore.path(store)) == before
  end

  test "proven nondelivery with missing pane does not admit the next attempt", %{store: store} do
    seed(store, "not_delivered")
    before = File.read!(ReceiptStore.path(store))

    assert %{ok: false, error: "pane_not_found"} = Delivery.dispatch(request(), store)

    assert {:ok, %{outcome: "absent", status: "not_delivered", delivery_attempt: 1}} =
             ReceiptStore.reconcile(store, @id, @pane, payload_hash())

    assert File.read!(ReceiptStore.path(store)) == before
  end

  for status <- ~w(delivered queued ambiguous pending) do
    test "#{status} retry bypasses a registered pane with a positive call witness", %{store: store} do
      status = unquote(status)
      spy = start_spy(@pane, store)
      seed(store, status)
      before = File.read!(ReceiptStore.path(store))

      assert_duplicate(Delivery.dispatch(request(), store), status)
      assert GenServer.call(spy, :calls) == 1
      assert File.read!(ReceiptStore.path(store)) == before
    end
  end

  test "payload and pane conflicts bypass registered panes with positive call witnesses", %{
    store: store
  } do
    original_spy = start_spy(@pane, store)
    other_spy = start_spy(@other_pane, store)
    seed(store, "delivered")
    before = File.read!(ReceiptStore.path(store))

    for params <- [
          Map.put(request(), "text", "different bytes"),
          Map.put(request(), "pane_id", @other_pane)
        ] do
      assert Delivery.dispatch(params, store) == %{
               ok: false,
               error: "conflict",
               protocol_version: 2,
               msg_id: @id,
               pane_id: params["pane_id"]
             }
    end

    assert GenServer.call(original_spy, :calls) == 1
    assert GenServer.call(other_spy, :calls) == 1
    assert File.read!(ReceiptStore.path(store)) == before
  end

  defp start_spy(pane, store) do
    spy = start_supervised!(Supervisor.child_spec({PaneSpy, pane}, id: {PaneSpy, pane}))

    assert {:error, :receipt_store_mismatch} =
             StateMachine.send_receipted(spy, @text, 1_000, @id, store)

    assert GenServer.call(spy, :calls) == 1
    spy
  end

  defp seed(store, status) do
    {:ok, {:admitted, admission}} = ReceiptStore.admit(store, @id, @pane, payload_hash(), self())

    if status != "pending" do
      :ok = ReceiptStore.transition(store, @id, admission.operation_token, status)
    end
  end

  defp assert_duplicate(reply, status) do
    assert reply == %{
             ok: true,
             duplicate: true,
             status: status,
             delivery_attempt: 1,
             payload_hash: payload_hash(),
             protocol_version: 2,
             msg_id: @id,
             pane_id: @pane
           }
  end

  defp payload_hash, do: Payload.hash(Payload.new(@text))

  defp request,
    do: %{
      "cmd" => "send",
      "protocol_version" => 2,
      "msg_id" => @id,
      "pane_id" => @pane,
      "text" => @text
    }
end
