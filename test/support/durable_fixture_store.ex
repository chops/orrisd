defmodule AiPair.Test.DurableFixtureStore do
  @moduledoc """
  A stand-in for `AiPair.PaneIntentStore` that answers its three API calls from a
  script, including by not answering at all. Registered under the store's own
  `{:global, {AiPair.PaneIntentStore, root}}` name by the row that uses it.

  It exists for the four wire shapes no real store can be driven into from a test
  without either waiting on a real deadline it does not expose or destroying the
  owner: an unanswered `put`/`delete` (`durable_store_timeout`), a `list` that
  FAILED rather than found nothing (`durable_lookup_failed`), and a commit that
  completes while the coordinator is lost underneath it.

  A scripted answer is either a term to reply, `:silent` (never reply, so the
  caller meets its own call deadline), or `{:run, fun, reply}`, which runs `fun`
  in the store process BEFORE replying — that is how a commit is made to complete
  at the exact moment the fence is destroyed.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(script) when is_list(script), do: GenServer.start_link(__MODULE__, script)

  @impl true
  def init(script), do: {:ok, Map.new(script)}

  @impl true
  def handle_call(:list, _from, state), do: answer(:list, state)
  def handle_call({:put, _record}, _from, state), do: answer(:put, state)
  def handle_call({:delete, _pane_id}, _from, state), do: answer(:delete, state)

  defp answer(op, state) do
    case Map.fetch(state, op) do
      {:ok, :silent} -> {:noreply, state}
      {:ok, {:run, fun, reply}} -> run_then_reply(fun, reply, state)
      {:ok, reply} -> {:reply, reply, state}
      :error -> {:reply, {:error, unscripted(op)}, state}
    end
  end

  defp run_then_reply(fun, reply, state) do
    fun.()
    {:reply, reply, state}
  end

  defp unscripted(op) do
    %{stage: :ownership, reason: {:unscripted, op}, outcome: :unchanged, cleanup_errors: []}
  end
end
