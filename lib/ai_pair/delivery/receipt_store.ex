defmodule AiPair.Delivery.ReceiptStore do
  @moduledoc """
  Serialized delivery admission and durable, five-valued reconciliation.

  The operation token authorizes one physical attempt; a caller-supplied message
  id does not. Only proven non-delivery permits another attempt. Owner loss and
  abandoned work on restart become ambiguous, never proof of absence.

  One process owns a normalized inbox path within this BEAM. The host must remain
  the sole daemon for that inbox; this registry is not a cross-VM file lock.
  """

  use GenServer
  require Logger
  alias AiPair.Delivery.{ReceiptLog, SystemFs}

  @terminal ~w(delivered not_delivered ambiguous)
  @statuses ["pending", "queued" | @terminal]
  @max_wait_ms 5_000

  @type receipt :: %{
          message_id: String.t(),
          pane_id: String.t(),
          payload_hash: String.t(),
          status: String.t(),
          delivery_attempt: pos_integer()
        }
  @type rejection :: atom() | tuple()

  def start_link(opts) do
    inbox = opts |> Keyword.fetch!(:inbox) |> Path.expand()
    name = {:global, {__MODULE__, inbox}}

    case GenServer.start_link(__MODULE__, Keyword.put(opts, :inbox, inbox), name: name) do
      {:error, {:already_started, _pid}} -> {:error, :receipt_store_already_running}
      other -> other
    end
  end

  @spec daemon_epoch(GenServer.server()) :: String.t()
  def daemon_epoch(store), do: GenServer.call(store, :daemon_epoch)
  @spec path(GenServer.server()) :: Path.t()
  def path(store), do: GenServer.call(store, :path)

  @doc "Admit once, returning a private token only to the new attempt."
  @spec admit(GenServer.server(), String.t(), String.t(), String.t(), pid()) ::
          {:ok, {:admitted, map()} | {:duplicate, receipt()}} | {:error, rejection()}

  def admit(store, id, pane, hash, owner),
    do: GenServer.call(store, {:admit, id, pane, hash, owner})

  @doc "Durably advance the attempt authorized by the opaque operation token."
  @spec transition(GenServer.server(), String.t(), reference(), String.t()) ::
          :ok | {:error, rejection()}
  def transition(store, id, token, status),
    do: GenServer.call(store, {:transition, id, token, status})

  @doc "Authorize crossing the paste boundary once, under the current attempt's token."
  @spec begin_paste(GenServer.server(), String.t(), reference()) :: :ok | {:error, rejection()}
  def begin_paste(store, id, token), do: GenServer.call(store, {:begin_paste, id, token})

  @doc "Query exact identity; a bounded wait expiring is ambiguous, never absence."
  @spec reconcile(GenServer.server(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, rejection()}
  def reconcile(store, id, pane, hash, opts \\ []) do
    wait = Keyword.get(opts, :wait_ms, 0)
    GenServer.call(store, {:reconcile, id, pane, hash, wait}, @max_wait_ms + 1_000)
  end

  @doc false
  def observe(store, id), do: GenServer.call(store, {:observe, id})

  @impl true
  def init(opts) do
    epoch = "ep_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    case ReceiptLog.open(Keyword.get(opts, :fs, SystemFs.new()), Keyword.fetch!(opts, :inbox)) do
      {:ok, log} ->
        state = %{
          log: log,
          epoch: epoch,
          tokens: %{},
          owners: %{},
          observers: %{},
          waiters: %{},
          in_flight: MapSet.new(),
          poisoned: false
        }

        log.entries
        |> Map.values()
        |> Enum.sort_by(& &1["seq"])
        |> Enum.filter(&(&1["status"] in ["pending", "queued"]))
        |> Enum.reduce_while({:ok, state}, fn record, {:ok, acc} ->
          case persist(acc, %{ReceiptLog.view(record) | status: "ambiguous"}) do
            {:ok, updated} ->
              {:cont, {:ok, updated}}

            {:error, reason, failed} ->
              close_on_failure(failed)
              {:halt, {:stop, reason}}
          end
        end)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:daemon_epoch, _from, state), do: {:reply, state.epoch, state}
  def handle_call(:path, _from, state), do: {:reply, state.log.path, state}

  def handle_call({:observe, id}, {pid, _}, state) do
    case valid_id(id) do
      :ok ->
        refs = Map.get(state.observers, id, [])
        {:reply, :ok, %{state | observers: Map.put(state.observers, id, Enum.uniq([pid | refs]))}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:admit, id, pane, hash, owner}, _from, state) do
    with :ok <- writable(state),
         :ok <- identity(id, pane, hash),
         :ok <- live_owner(owner) do
      admit_current(state, id, pane, hash, owner)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:transition, id, token, status}, _from, state) do
    with :ok <- writable(state),
         :ok <- valid_id(id),
         {:ok, current} <- current(state, id),
         :ok <- authority(state, id, token, current.delivery_attempt),
         :ok <- paste_outcome(state, id, status),
         :ok <- legal(current.status, status) do
      case persist(state, %{current | status: status}) do
        {:ok, updated} -> {:reply, :ok, notify(updated, id)}
        {:error, reason, failed} -> {:reply, {:error, reason}, failed}
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:begin_paste, id, token}, _from, state) do
    with :ok <- writable(state),
         :ok <- valid_id(id),
         {:ok, current} <- current(state, id),
         :ok <- authority(state, id, token, current.delivery_attempt),
         :ok <- paste_start(state, id, current.status) do
      {:reply, :ok, %{state | in_flight: MapSet.put(state.in_flight, id)}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reconcile, id, pane, hash, wait}, from, state) do
    with :ok <- identity(id, pane, hash),
         true <- is_integer(wait) and wait >= 0 and wait <= @max_wait_ms do
      reconcile_current(state, id, pane, hash, wait, from)
    else
      false -> {:reply, {:error, :invalid_wait_ms}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:wait_expired, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, id: id, monitor: monitor}, rest} ->
        Process.demonitor(monitor, [:flush])
        {:ok, view} = current(state, id)
        GenServer.reply(from, {:ok, Map.put(view, :outcome, "ambiguous")})
        {:noreply, %{state | waiters: rest}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.owners, ref) do
      {nil, _} ->
        {:noreply, remove_waiter(state, ref)}

      {{id, attempt}, owners} ->
        state = %{state | owners: owners}
        {:ok, view} = current(state, id)

        if view.delivery_attempt == attempt and view.status in ["pending", "queued"] do
          case persist(state, %{view | status: "ambiguous"}) do
            {:ok, updated} -> {:noreply, notify(updated, id)}
            {:error, _reason, failed} -> {:noreply, failed}
          end
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state), do: close_on_failure(state)

  defp admit_current(state, id, pane, hash, owner) do
    case current(state, id) do
      {:error, {:unknown_message_id, _}} ->
        admit_attempt(state, id, pane, hash, owner, 1)

      {:ok, %{pane_id: ^pane, payload_hash: ^hash, status: "not_delivered"} = view} ->
        admit_attempt(state, id, pane, hash, owner, view.delivery_attempt + 1)

      {:ok, %{pane_id: ^pane, payload_hash: ^hash} = view} ->
        {:reply, {:ok, {:duplicate, view}}, state}

      {:ok, view} ->
        {:reply, {:error, {:conflict, view}}, state}
    end
  end

  defp admit_attempt(state, id, pane, hash, owner, attempt) do
    view = %{
      message_id: id,
      pane_id: pane,
      payload_hash: hash,
      status: "pending",
      delivery_attempt: attempt
    }

    case persist(state, view) do
      {:ok, updated} ->
        token = make_ref()
        monitor = Process.monitor(owner)

        updated = %{
          updated
          | tokens: Map.put(updated.tokens, token, {id, attempt}),
            owners: Map.put(updated.owners, monitor, {id, attempt})
        }

        {:reply, {:ok, {:admitted, Map.put(view, :operation_token, token)}}, updated}

      {:error, reason, failed} ->
        {:reply, {:error, reason}, failed}
    end
  end

  defp reconcile_current(state, id, pane, hash, wait, from) do
    case current(state, id) do
      {:error, {:unknown_message_id, _}} ->
        {:reply, {:ok, %{outcome: "absent", message_id: id, pane_id: pane}}, state}

      {:ok, %{status: status}} when state.poisoned and status in ["pending", "queued"] ->
        {:reply, {:error, :receipt_store_unavailable}, state}

      {:ok, %{pane_id: ^pane, payload_hash: ^hash, status: status} = view}
      when status in ["pending", "queued"] ->
        if status == "pending" or MapSet.member?(state.in_flight, id),
          do: wait_for_paste(state, view, wait, from),
          else: {:reply, {:ok, Map.put(view, :outcome, "queued")}, state}

      {:ok, %{pane_id: ^pane, payload_hash: ^hash} = view} ->
        {:reply, {:ok, Map.put(view, :outcome, outcome(view.status))}, state}

      {:ok, view} ->
        {:reply, {:ok, Map.put(view, :outcome, "conflict")}, state}
    end
  end

  defp wait_for_paste(state, view, 0, _from),
    do: {:reply, {:ok, Map.put(view, :outcome, "ambiguous")}, state}

  defp wait_for_paste(state, view, wait, from) do
    ref = make_ref()
    timer = Process.send_after(self(), {:wait_expired, ref}, wait)

    waiter = %{
      id: view.message_id,
      from: from,
      timer: timer,
      monitor: Process.monitor(elem(from, 0))
    }

    {:noreply, %{state | waiters: Map.put(state.waiters, ref, waiter)}}
  end

  defp persist(%{poisoned: true} = state, _view), do: {:error, :receipt_store_unavailable, state}

  defp persist(state, view) do
    case ReceiptLog.append(state.log, view, state.epoch) do
      {:ok, log} -> {:ok, %{state | log: log}}
      {:error, reason} -> {:error, reason, %{state | poisoned: true}}
    end
  end

  defp notify(state, id) do
    {:ok, view} = current(state, id)

    state =
      Enum.reduce(state.waiters, state, fn {ref, waiter}, acc ->
        if waiter.id == id do
          Process.cancel_timer(waiter.timer)
          Process.demonitor(waiter.monitor, [:flush])
          GenServer.reply(waiter.from, {:ok, Map.put(view, :outcome, outcome(view.status))})
          %{acc | waiters: Map.delete(acc.waiters, ref)}
        else
          acc
        end
      end)

    if view.status in @terminal do
      Enum.each(Map.get(state.observers, id, []), &send(&1, {:receipt_finalized, id, view.status}))

      owners =
        Enum.reduce(state.owners, state.owners, fn {ref, {owner_id, _}}, acc ->
          if owner_id == id do
            Process.demonitor(ref, [:flush])
            Map.delete(acc, ref)
          else
            acc
          end
        end)

      %{
        state
        | owners: owners,
          observers: Map.delete(state.observers, id),
          in_flight: MapSet.delete(state.in_flight, id)
      }
    else
      state
    end
  end

  defp remove_waiter(state, monitor) do
    waiters =
      Enum.reduce(state.waiters, state.waiters, fn {ref, waiter}, acc ->
        if waiter.monitor == monitor do
          Process.cancel_timer(waiter.timer)
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    %{state | waiters: waiters}
  end

  defp current(state, id) do
    case Map.fetch(state.log.entries, id) do
      {:ok, record} -> {:ok, ReceiptLog.view(record)}
      :error -> {:error, {:unknown_message_id, id}}
    end
  end

  defp authority(state, id, token, attempt) do
    case Map.get(state.tokens, token) do
      {^id, ^attempt} -> :ok
      {^id, previous} -> {:error, {:stale_operation_token, previous, attempt}}
      _ -> {:error, {:foreign_operation_token, id}}
    end
  end

  defp legal(old, next) do
    cond do
      next not in @statuses ->
        {:error, {:unknown_status, if(next == "failed", do: "failed", else: :invalid)}}

      ReceiptLog.transition?(old, next) ->
        :ok

      true ->
        {:error, {:illegal_transition, old, next}}
    end
  end

  defp paste_start(state, id, status) do
    cond do
      status not in ["pending", "queued"] -> {:error, :paste_not_pending}
      MapSet.member?(state.in_flight, id) -> {:error, :paste_already_started}
      true -> :ok
    end
  end

  defp paste_outcome(state, id, status) do
    if MapSet.member?(state.in_flight, id) and status in ["not_delivered", "queued"],
      do: {:error, :paste_outcome_unproven},
      else: :ok
  end

  defp identity(id, pane, hash) do
    cond do
      not ReceiptLog.valid_id?(id) -> {:error, {:invalid_message_id, :grammar}}
      not ReceiptLog.valid_hash?(hash) -> {:error, {:invalid_payload_hash, :grammar}}
      not ReceiptLog.valid_pane?(pane) -> {:error, {:invalid_pane_id, :grammar}}
      true -> :ok
    end
  end

  defp live_owner(pid) when is_pid(pid) do
    if node(pid) == node() and Process.alive?(pid),
      do: :ok,
      else: {:error, :invalid_operation_owner}
  end

  defp live_owner(_), do: {:error, :invalid_operation_owner}

  defp valid_id(id) do
    if ReceiptLog.valid_id?(id), do: :ok, else: {:error, {:invalid_message_id, :grammar}}
  end

  defp writable(%{poisoned: true}), do: {:error, :receipt_store_unavailable}
  defp writable(_), do: :ok
  defp outcome("not_delivered"), do: "absent"
  defp outcome("pending"), do: "ambiguous"
  defp outcome(status), do: status

  defp close_on_failure(state) do
    case ReceiptLog.close(state.log) do
      :ok -> :ok
      {:error, reason} -> Logger.error("receipt store close failed: #{inspect(reason)}")
    end
  end
end
