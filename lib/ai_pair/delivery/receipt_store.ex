defmodule AiPair.Delivery.ReceiptStore do
  @moduledoc """
  Serialized delivery admission and durable, five-valued reconciliation.

  The operation token authorizes one physical attempt; a caller-supplied message
  id does not. Only proven non-delivery permits another attempt. Owner loss and
  abandoned work on restart become ambiguous, never proof of absence, except a
  queued attempt that boot restores (NS-15.G.003 S2, design r6): its epoch is
  attested in `AiPair.Delivery.Lineage`, its latest record is a v2 queued record
  with no paste marker, and its exact payload object verifies. That attempt stays
  queued; a corrupt or inconsistent lineage refuses the store unchanged.

  One process owns a normalized inbox path within this BEAM. The host must remain
  the sole daemon for that inbox; this registry is not a cross-VM file lock.
  """

  use GenServer
  require Logger
  alias AiPair.Delivery.{Lineage, Payload, PayloadStore, ReceiptLog, SystemFs}
  alias AiPair.PaneRestore.Coordinator

  # `cancelled` (receipt schema 3, RS3) is terminal when read, but this build never writes it:
  # the transition API below admits only @statuses, which excludes it (B2 owns its emission).
  @terminal ~w(delivered not_delivered ambiguous cancelled)
  @statuses ~w(pending queued delivered not_delivered ambiguous)
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

  @doc """
  Queue a pending attempt: publish its payload object durably, then append the queued
  receipt. A refusal finalizes the attempt not_delivered and answers payload_store_full or
  payload_store_unavailable.
  """
  @spec queue(GenServer.server(), String.t(), reference(), binary()) :: :ok | {:error, rejection()}
  def queue(store, id, token, bytes), do: GenServer.call(store, {:queue, id, token, bytes})

  @doc "The default global payload limits: {objects, bytes}."
  @spec payload_limits() :: {pos_integer(), pos_integer()}
  def payload_limits, do: PayloadStore.limits()

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

  # ----- S2 restore registry (design r6 "Handover"; ISSUER-PREDICATE r4) -----

  @doc "Boot-restored queued sends by pane, in receipt seq order, with holder state; never tokens."
  def restore_registry(store), do: GenServer.call(store, :restore_registry)

  @doc "Issue pane's restore capability; only the restore issuer may call it."
  def issue_restore_capability(store, pane, ref),
    do: GenServer.call(store, {:issue_restore_capability, pane, ref})

  @doc "Claim pane's restored entries with its capability; idempotent per holder pid."
  def claim_restored(store, pane, capability, timeout \\ 5_000),
    do: GenServer.call(store, {:claim_restored, pane, capability}, timeout)

  @doc "Fence pane's restored entries: revoke the capability and void every held token."
  def fence_restore(store, pane, ref), do: GenServer.call(store, {:fence_restore, pane, ref})

  @doc "A restored entry whose verified read failed: append ambiguous, remove its object."
  def restore_failed(store, id, attempt, token),
    do: GenServer.call(store, {:restore_failed, id, attempt, token})

  # Boot (design r6 steps 1-6): open the log (corrupt: refuse); validate lineage against it
  # (corrupt or inconsistent: refuse, nothing written); attest this epoch before any receipt
  # of it (fault: stop :lineage_unavailable); classify unresolved attempts in seq order (a
  # restorable queued attempt stays queued, every other one becomes ambiguous); clean payloads
  # keeping exactly the restorable set.
  @impl true
  def init(opts) do
    epoch = "ep_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    inbox = Keyword.fetch!(opts, :inbox)

    case ReceiptLog.open(Keyword.get(opts, :fs, SystemFs.new()), inbox) do
      {:ok, log} ->
        state = %{
          log: log,
          epoch: epoch,
          tokens: %{},
          owners: %{},
          observers: %{},
          waiters: %{},
          in_flight: MapSet.new(),
          pre_paste: %{},
          poisoned: false,
          restored: [],
          # S2 handover: the issuer (a test pid, or the Coordinator), the registry by pane, the
          # live capability digests by pane, holder monitors, and tokens voided by re-mint.
          issuer: Keyword.get(opts, :restore_issuer),
          restore: %{},
          caps: %{},
          holders: %{},
          voided: MapSet.new()
        }

        with {:ok, lineage} <- Lineage.load(log.fs, inbox, log),
             {:ok, lineage} <- Lineage.attest(lineage, epoch, log.seq + 1) do
          state
          |> classify(Lineage.ranges(lineage), inbox)
          |> boot_payloads(opts)
        else
          {:error, reason} ->
            close_on_failure(state)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp classify(state, ranges, inbox) do
    state.log.entries
    |> Map.values()
    |> Enum.sort_by(& &1["seq"])
    |> Enum.filter(&(&1["status"] in ["pending", "queued", "paste_started"]))
    |> Enum.reduce_while({:ok, state}, fn record, {:ok, acc} ->
      view = ReceiptLog.view(record)

      if restorable?(record, ranges) and
           PayloadStore.verified?(acc.log.fs, inbox, acc.log.path, view) do
        {:cont, {:ok, %{acc | restored: acc.restored ++ [view]}}}
      else
        case persist(acc, %{view | status: "ambiguous"}) do
          {:ok, updated} ->
            {:cont, {:ok, updated}}

          {:error, reason, failed} ->
            close_on_failure(failed)
            {:halt, {:stop, reason}}
        end
      end
    end)
  end

  # (b) and (L): the attempt's latest record is a v2 or v3 queued record of an attested epoch
  # (v3, RS3, also carries the attempt's registration pair into the restored view). The range
  # consistency of every attested epoch's records was checked by Lineage.load/3; (c) and (d),
  # the exact verified object, are checked by the caller.
  defp restorable?(record, ranges) do
    record["status"] == "queued" and record["schema_version"] in [2, 3] and
      Map.has_key?(ranges, record["daemon_epoch"])
  end

  # Cleanup keeps exactly the restorable set (S1 kept none); kept objects count from boot.
  defp boot_payloads({:ok, state}, opts) do
    keys = MapSet.new(state.restored, &{&1.message_id, &1.delivery_attempt, &1.payload_hash})
    inbox = Keyword.fetch!(opts, :inbox)

    payload =
      PayloadStore.boot(state.log.fs, inbox, state.log.path, opts, &MapSet.member?(keys, &1))

    {:ok, state |> Map.put(:payload, payload) |> build_registry()}
  end

  defp boot_payloads(stop, _opts), do: stop

  # Design r6 step 6: each restored attempt gets a token minted in this epoch and an unheld
  # registry entry under its pane, in receipt seq order. The entry carries the attempt's
  # registration pair (RS3; null for a version 2 attempt) through the registry and the handover.
  defp build_registry(state) do
    Enum.reduce(state.restored, state, fn view, acc ->
      token = make_ref()

      entry = %{
        msg_id: view.message_id,
        attempt: view.delivery_attempt,
        payload_hash: view.payload_hash,
        registration_id: view.registration_id,
        generation: view.generation,
        token: token,
        holder: nil
      }

      %{
        acc
        | tokens: Map.put(acc.tokens, token, {view.message_id, view.delivery_attempt}),
          restore: Map.update(acc.restore, view.pane_id, [entry], &(&1 ++ [entry]))
      }
    end)
  end

  @impl true
  def handle_call(:daemon_epoch, _from, state), do: {:reply, state.epoch, state}

  def handle_call({:queue, id, token, bytes}, _from, state) do
    with :ok <- writable(state),
         :ok <- valid_id(id),
         {:ok, current} <- current(state, id),
         :ok <- authority(state, id, token, current.delivery_attempt),
         :ok <- legal(current.status, "queued") do
      hash = Payload.hash(Payload.new(bytes))

      case PayloadStore.publish(state.payload, current, bytes, hash) do
        {:ok, payload} ->
          case persist(%{state | payload: payload}, %{current | status: "queued"}) do
            {:ok, updated} -> {:reply, :ok, notify(updated, id)}
            {:error, reason, failed} -> {:reply, {:error, reason}, failed}
          end

        {:error, kind, payload} ->
          case persist(%{state | payload: payload}, %{current | status: "not_delivered"}) do
            {:ok, updated} -> {:reply, {:error, kind}, notify(updated, id)}
            {:error, _reason, failed} -> {:reply, {:error, kind}, failed}
          end
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:path, _from, state), do: {:reply, state.log.path, state}

  # ----- S2 restore registry -----

  def handle_call(:restore_registry, _from, state) do
    registry =
      Map.new(state.restore, fn {pane, entries} ->
        {pane,
         Enum.map(
           entries,
           &Map.take(&1, [:msg_id, :attempt, :payload_hash, :registration_id, :generation, :holder])
         )}
      end)

    {:reply, registry, state}
  end

  def handle_call({:issue_restore_capability, pane, _ref} = request, {caller, _}, state) do
    entries = Map.get(state.restore, pane, [])

    cond do
      not issuer?(state, caller, pane, request) -> {:reply, {:error, :not_issuer}, state}
      entries == [] -> {:reply, {:error, :no_restored_entries}, state}
      Map.has_key?(state.caps, pane) -> {:reply, {:error, :capability_live}, state}
      fenced_alive?(entries) -> {:reply, {:error, :fenced_holder_alive}, state}
      true -> issue(state, pane, entries)
    end
  end

  def handle_call({:claim_restored, pane, cap}, {caller, _}, state) do
    entries = Map.get(state.restore, pane, [])

    cond do
      not is_binary(cap) or entries == [] or Map.get(state.caps, pane) != digest(cap) ->
        {:reply, {:error, :not_authorized}, state}

      Enum.all?(entries, &(&1.holder == caller)) ->
        {:reply, {:ok, handed(state, entries)}, state}

      Enum.any?(entries, &(is_pid(&1.holder) and Process.alive?(&1.holder))) ->
        {:reply, {:error, :held}, state}

      true ->
        state = state |> remint(pane) |> hold(pane, caller)
        {:reply, {:ok, handed(state, state.restore[pane])}, state}
    end
  end

  def handle_call({:fence_restore, pane, _ref} = request, {caller, _}, state) do
    if issuer?(state, caller, pane, request) do
      state = remint(%{state | caps: Map.delete(state.caps, pane)}, pane)

      restore =
        Map.update(state.restore, pane, [], fn entries ->
          Enum.map(entries, fn
            %{holder: pid} = entry when is_pid(pid) -> %{entry | holder: {:fenced, pid}}
            entry -> entry
          end)
        end)

      {:reply, {:ok, make_ref()}, %{state | restore: restore}}
    else
      {:reply, {:error, :not_issuer}, state}
    end
  end

  def handle_call({:restore_failed, id, attempt, token}, _from, state) do
    # Only an exact {msg_id, attempt} of the restore registry may take this path; an ordinary
    # queued attempt, even with its valid token, is refused and nothing changes.
    with :ok <- writable(state),
         true <- restored_entry?(state, id, attempt),
         {:ok, current} <- current(state, id),
         true <- current.delivery_attempt == attempt and current.status == "queued",
         :ok <- authority(state, id, token, attempt) do
      case persist(state, %{current | status: "ambiguous"}) do
        {:ok, updated} -> {:reply, :ok, notify(updated, id)}
        {:error, reason, failed} -> {:reply, {:error, reason}, failed}
      end
    else
      false -> {:reply, {:error, :not_restored}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

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
      # The marker is durable before :ok, so paste_fn never runs without it on disk.
      case persist(state, %{current | status: "paste_started"}) do
        {:ok, updated} ->
          {:reply, :ok,
           %{
             updated
             | in_flight: MapSet.put(updated.in_flight, id),
               pre_paste: Map.put(updated.pre_paste, id, current.status)
           }}

        {:error, _reason, failed} ->
          {:reply, {:error, :receipt_store_unavailable}, failed}
      end
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
        {:ok, view} = public(state, id)

        # A poisoned store can no longer finalize this record; never answer it as pending.
        reply =
          if state.poisoned and view.status in ["pending", "queued"],
            do: {:error, :receipt_store_unavailable},
            else: {:ok, Map.put(view, :outcome, "ambiguous")}

        GenServer.reply(from, reply)
        {:noreply, %{state | waiters: rest}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.owners, ref) do
      {nil, _} ->
        # A restore holder's death returns its entries to unheld and never finalizes them
        # (ADR-0003 restore-registry owner-loss exception, design r6).
        case holder_down(state, ref) do
          {:ok, updated} -> {:noreply, updated}
          :none -> {:noreply, remove_waiter(state, ref)}
        end

      {{id, attempt}, owners} ->
        state = %{state | owners: owners}
        {:ok, view} = current(state, id)

        if view.delivery_attempt == attempt and
             view.status in ["pending", "queued", "paste_started"] do
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

  # A plain pid issuer is for store-level tests. Production passes the Coordinator, which
  # authorizes only the live transaction holder's open operation carrying exactly `request`
  # to this store (ISSUER-PREDICATE r4); the call is bounded and any failure refuses.
  defp issuer?(%{issuer: pid}, caller, _pane, _request) when is_pid(pid), do: caller == pid
  defp issuer?(%{issuer: nil}, _caller, _pane, _request), do: false

  defp issuer?(%{issuer: coordinator}, caller, pane, request),
    do: Coordinator.authorize_effect(coordinator, caller, pane, self(), request) == true

  defp restored_entry?(state, id, attempt) do
    Enum.any?(state.restore, fn {_pane, entries} ->
      Enum.any?(entries, &(&1.msg_id == id and &1.attempt == attempt))
    end)
  end

  defp fenced_alive?(entries) do
    Enum.any?(entries, fn
      %{holder: {:fenced, pid}} -> Process.alive?(pid)
      _ -> false
    end)
  end

  # A new capability: only its digest is kept. Dead fenced holders become unheld.
  defp issue(state, pane, entries) do
    cap = :crypto.strong_rand_bytes(32)

    entries =
      Enum.map(entries, fn
        %{holder: {:fenced, _}} = entry -> %{entry | holder: nil}
        entry -> entry
      end)

    {:reply, {:ok, cap},
     %{
       state
       | caps: Map.put(state.caps, pane, digest(cap)),
         restore: Map.put(state.restore, pane, entries)
     }}
  end

  # What a holder receives: identity, its token, the object path and the store's own uid, so
  # the holder's actual read re-verifies the object under the same owner check (G3).
  defp handed(state, entries) do
    Enum.map(entries, fn entry ->
      %{
        msg_id: entry.msg_id,
        attempt: entry.attempt,
        payload_hash: entry.payload_hash,
        registration_id: entry.registration_id,
        generation: entry.generation,
        token: entry.token,
        object: PayloadStore.object_path(state.payload, entry),
        owner_uid: state.payload.uid
      }
    end)
  end

  # Every token of the pane's entries is replaced; the old ones are void from this instant.
  defp remint(state, pane) do
    Enum.reduce(Map.get(state.restore, pane, []), state, fn entry, acc ->
      token = make_ref()

      entries =
        Enum.map(acc.restore[pane], fn
          %{msg_id: id} = e when id == entry.msg_id -> %{e | token: token}
          e -> e
        end)

      %{
        acc
        | tokens:
            acc.tokens |> Map.delete(entry.token) |> Map.put(token, {entry.msg_id, entry.attempt}),
          voided: MapSet.put(acc.voided, entry.token),
          restore: Map.put(acc.restore, pane, entries)
      }
    end)
  end

  defp hold(state, pane, pid) do
    monitor = Process.monitor(pid)

    %{
      state
      | holders: Map.put(state.holders, monitor, {pane, pid}),
        restore: Map.update!(state.restore, pane, fn es -> Enum.map(es, &%{&1 | holder: pid}) end)
    }
  end

  defp holder_down(state, monitor) do
    case Map.pop(state.holders, monitor) do
      {nil, _} ->
        :none

      {{pane, pid}, holders} ->
        restore =
          Map.update(state.restore, pane, [], fn entries ->
            Enum.map(entries, fn
              %{holder: ^pid} = entry -> %{entry | holder: nil}
              %{holder: {:fenced, ^pid}} = entry -> %{entry | holder: nil}
              entry -> entry
            end)
          end)

        {:ok, %{state | holders: holders, restore: restore}}
    end
  end

  # An entry leaves the registry only when its receipt is terminal (or restore_failed).
  defp drop_restored(state, id) do
    restore =
      state.restore
      |> Map.new(fn {pane, entries} -> {pane, Enum.reject(entries, &(&1.msg_id == id))} end)
      |> Map.reject(fn {_pane, entries} -> entries == [] end)

    %{state | restore: restore}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes)

  defp admit_current(state, id, pane, hash, owner) do
    case public(state, id) do
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
    case public(state, id) do
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

  defp persist(%{poisoned: true} = state, _view),
    do: {:error, :receipt_store_unavailable, fail_waiters(state)}

  defp persist(state, view) do
    case ReceiptLog.append(state.log, view, state.epoch) do
      {:ok, log} -> {:ok, release_payload(%{state | log: log}, view)}
      {:error, reason} -> {:error, reason, fail_waiters(%{state | poisoned: true})}
    end
  end

  # No pending or queued record can be finalized once the store is poisoned, so a waiter on
  # any id could only be answered by its timer with a stale view. Wake every one with the
  # answer a later caller gets; no further append is attempted.
  defp fail_waiters(state) do
    Enum.each(state.waiters, fn {_ref, waiter} ->
      Process.cancel_timer(waiter.timer)
      Process.demonitor(waiter.monitor, [:flush])
      GenServer.reply(waiter.from, {:error, :receipt_store_unavailable})
    end)

    %{state | waiters: %{}}
  end

  defp notify(state, id) do
    {:ok, view} = public(state, id)

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
        drop_restored(state, id)
        | owners: owners,
          observers: Map.delete(state.observers, id),
          in_flight: MapSet.delete(state.in_flight, id),
          pre_paste: Map.delete(state.pre_paste, id)
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

  # What callers see: `paste_started` is internal and reads as the status the live attempt had
  # just before its marker, so every v2 reply is the one it was before the marker existed.
  defp public(state, id) do
    case current(state, id) do
      {:ok, %{status: "paste_started"} = view} ->
        {:ok, %{view | status: Map.get(state.pre_paste, id, "pending")}}

      # RS3: a stored cancelled reads as ambiguous on every reply this build serves (the v2
      # duplicate and reconcile shapes); a v2 client already refuses and never resends it.
      {:ok, %{status: "cancelled"} = view} ->
        {:ok, %{view | status: "ambiguous"}}

      other ->
        other
    end
  end

  # A token voided by a restore re-mint answers :stale_token and changes nothing.
  defp authority(state, id, token, attempt) do
    if MapSet.member?(state.voided, token),
      do: {:error, :stale_token},
      else: token_authority(state, id, token, attempt)
  end

  defp token_authority(state, id, token, attempt) do
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
      status == "paste_started" or MapSet.member?(state.in_flight, id) ->
        {:error, :paste_already_started}

      status not in ["pending", "queued"] ->
        {:error, :paste_not_pending}

      true ->
        :ok
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

  # A terminal receipt is durable before its payload object is removed (receipt first).
  defp release_payload(%{payload: %PayloadStore{} = payload} = state, %{status: status} = view)
       when status in @terminal,
       do: %{state | payload: PayloadStore.release(payload, view)}

  defp release_payload(state, _view), do: state

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
