defmodule AiPair.Test.ReceiptBackedIPCServer do
  @moduledoc "Starts the receipt prerequisite for legacy socket tests without changing their wire assertions."

  alias AiPair.Delivery.ReceiptStore

  def start_link(opts) do
    inbox = opts |> Keyword.fetch!(:inbox) |> Path.expand()
    store = {:global, {ReceiptStore, inbox}}

    unless AiPair.IPC.Delivery.available?(store) do
      ExUnit.Callbacks.start_supervised!(%{
        id: {ReceiptStore, inbox},
        start: {ReceiptStore, :start_link, [[inbox: inbox]]}
      })
    end

    AiPair.IPC.Server.start_link(Keyword.put(opts, :receipt_store, store))
  end
end
