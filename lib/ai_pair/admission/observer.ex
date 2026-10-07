defmodule AiPair.Admission.Observer do
  @moduledoc """
  The authoritative observation of the quiesce fence (NS-32.M.002 RB-3a; vendored ipc-v3.org
  "Quiesce"), read by AiPair.Admission after its drain while admission stays closed. Each
  dimension is read from its owner; any owner that fails or exits makes the whole observation
  `{:error, dimension}` (never a partial reply), the dimensions checked in the order receipts,
  pane_intent, effects, lineage, payloads, session_marker.

  Sources: `:receipt_store` (owns the receipt log, the effect journal, the lineage and the payload
  store; one `ReceiptStore.observation/1` call), `:pane_intent_store`, `:marker` (a 0-arity
  function returning `{:ok, version}` or `:error`), and optional per-dimension read overrides
  `:effects`, `:lineage` and `:payloads` (0-arity functions returning `{:ok, map}` or `:error`).
  """

  alias AiPair.Delivery.ReceiptStore
  alias AiPair.PaneIntentStore

  @spec observe(map()) :: {:ok, map()} | {:error, String.t()}
  def observe(sources) do
    with {:ok, store} <- read("receipts", fn -> ReceiptStore.observation(sources.receipt_store) end),
         {:ok, intents} <- read("pane_intent", fn -> pane_intent(sources.pane_intent_store) end),
         {:ok, effects} <- read("effects", dimension(sources, :effects, store)),
         {:ok, lineage} <- read("lineage", dimension(sources, :lineage, store)),
         {:ok, payloads} <- read("payloads", dimension(sources, :payloads, store)),
         {:ok, marker} <- read("session_marker", fn -> marker(sources.marker) end) do
      {:ok,
       %{
         "receipts" => store.receipts,
         "pane_intent" => intents,
         "effects" => effects,
         "lineage" => lineage,
         "payloads" => payloads,
         "session_marker" => marker
       }}
    end
  end

  defp dimension(sources, key, store) do
    Map.get(sources, key, fn -> Map.fetch!(store, key) end)
  end

  defp pane_intent(store) do
    case PaneIntentStore.list(store) do
      {:ok, records} ->
        {:ok, %{"version" => PaneIntentStore.Record.version(), "live_panes" => length(records)}}

      _ ->
        :error
    end
  end

  defp marker(fun) do
    case fun.() do
      {:ok, version} when is_integer(version) -> {:ok, %{"version" => version}}
      _ -> :error
    end
  end

  defp read(dimension, fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      _ -> {:error, dimension}
    end
  catch
    _, _ -> {:error, dimension}
  end
end
