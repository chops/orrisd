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
  alias AiPair.Delivery.{EffectJournal, Lineage, Payload, PayloadStore, ReceiptLog, SystemFs}
  alias AiPair.PaneRestore.Coordinator

  # `cancelled` (receipt schema 3, RS3) is terminal when read, but this build never writes it:
  # the transition API below admits only @statuses, which excludes it (B2 owns its emission).
  @terminal ~w(delivered not_delivered ambiguous cancelled)
  @statuses ~w(pending queued delivered not_delivered ambiguous)
  # The pair a v1/v2 admission records (B1b): explicit null, never inferred from the registry.
  @unbound %{registration_id: nil, generation: nil}
  @max_wait_ms 5_000
  # S3a: how long a fence waits for a STARTED gated transaction before answering
  # command_in_flight (scope r12, deferred fence reply); overridable by :fence_bound_ms.
  @fence_bound_ms 5_000

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

  @doc """
  Admit a version 3 send bound to the pane identity its caller PROVED under the pane's fence
  (B1b): a new attempt records that registration pair on every line. The binding is required;
  a v1/v2 admission uses `admit/5` and records null. An existing attempt answers its duplicate
  unchanged: its stored pair is never rewritten.
  """
  @spec admit(GenServer.server(), String.t(), String.t(), String.t(), pid(), %{
          registration_id: String.t(),
          generation: String.t()
        }) :: {:ok, {:admitted, map()} | {:duplicate, receipt()}} | {:error, rejection()}
  def admit(store, id, pane, hash, owner, %{registration_id: reg, generation: gen} = binding)
      when is_binary(reg) and is_binary(gen),
      do: GenServer.call(store, {:admit, id, pane, hash, owner, binding})

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

  # ----- S3a gated delivery (scope r12 "Paste-command gate", "Effect journal") -----

  @doc """
  Begin one gated delivery transaction for `gate` (%{pane, msg_id, attempt, token, buffer}):
  refused while the gate is poisoned, the pane is held, fence-pending or already has a STARTED
  transaction, the residual bound is reached or the token is not live; otherwise the begin is
  durable (fsynced) before `{:ok, marker}`, and the caller (the Tmux server) is monitored.
  """
  def begin_command(store, gate), do: GenServer.call(store, {:begin_command, gate})

  @doc """
  Run one tmux step of a STARTED transaction (`exe` with `args`) and answer `{:ok, exit_status}`
  when the client has exited. The STORE opens the step's Port, inside this call and only while
  it holds the marker as started by the calling Tmux server and the gate is not poisoned: no
  step is spawned except by the live gate that holds the token. The reply is deferred (the
  store keeps answering); a store that dies closes the Port it owns and the caller's call
  exits. A restarted store never holds the marker (the started map is in memory).
  """
  def run_step(store, marker, exe, args),
    do: GenServer.call(store, {:run_step, marker, exe, args}, :infinity)

  @doc "Record the residual of a STARTED transaction whose buffer cleanup failed."
  def residual_command(store, marker), do: GenServer.call(store, {:residual_command, marker})

  @doc "End a STARTED transaction with its first nonzero exit (or 0) and its cleanup exit."
  def end_command(store, marker, code, cleanup),
    do: GenServer.call(store, {:end_command, marker, code, cleanup})

  @doc "Held panes, residual buffers, held (unmatched) entries and whether the gate is poisoned."
  def effect_status(store), do: GenServer.call(store, :effect_status)

  @doc "Hold a restored entry whose pair does not match the released identity; never pasted."
  def hold_unmatched(store, id, attempt, token),
    do: GenServer.call(store, {:hold_unmatched, id, attempt, token})

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

    fs = Keyword.get(opts, :fs, SystemFs.new())

    case ReceiptLog.open(fs, inbox) do
      {:ok, log} -> init_state(log, epoch, inbox, opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp open_journal(fs, inbox, log) do
    case EffectJournal.open(fs, inbox) do
      {:ok, journal} ->
        {:ok, journal}

      {:error, _} = error ->
        _ = ReceiptLog.close(log)
        error
    end
  end

  # The effect journal opens after this epoch's lineage attestation, so a lineage fault still
  # stops the store :lineage_unavailable before any journal write (L6, L9).
  defp init_state(log, epoch, inbox, opts) do
    with {:ok, lineage} <- Lineage.load(log.fs, inbox, log),
         {:ok, lineage} <- Lineage.attest(lineage, epoch, log.seq + 1) do
      # open_journal/3 closes the log itself when the journal cannot be opened
      case open_journal(log.fs, inbox, log) do
        {:ok, journal} ->
          log
          |> boot_state(journal, epoch, opts)
          |> classify(Lineage.ranges(lineage), inbox)
          |> boot_payloads(opts)

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} ->
        close_log_on_failure(log)
        {:stop, reason}
    end
  end

  defp boot_state(log, journal, epoch, opts) do
    %{
      # S3a: the effect journal, the STARTED transaction per pane (marker and the Tmux
      # server's monitor), panes held in memory after a journal write failure, pending
      # fences, unmatched entries held by pane, and whether the gate is poisoned.
      journal: journal,
      started: %{},
      # the Port of each running gated step and its deferred run_step caller
      steps: %{},
      held_in_memory: MapSet.new(),
      fences: %{},
      held: %{},
      gate_poisoned: false,
      fence_bound_ms: Keyword.get(opts, :fence_bound_ms, @fence_bound_ms),
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

  # S3a (scope r12): a fence takes effect only when no gated transaction of the pane is
  # STARTED. With one STARTED the reply is deferred (no blocking in this call, so the
  # transaction's end_command can run): fence-pending refuses every begin for the pane, and
  # exactly one terminal reply follows, {:ok, ref} at the end or command_in_flight at the
  # bound. A held (effect-unresolved) pane is never fenced.
  def handle_call({:fence_restore, pane, _ref} = request, {caller, _} = from, state) do
    cond do
      not issuer?(state, caller, pane, request) ->
        {:reply, {:error, :not_issuer}, state}

      Map.has_key?(state.fences, pane) ->
        {:reply, {:error, :fence_pending}, state}

      pane in unresolved_panes(state) ->
        {:reply, {:error, :effect_unresolved}, state}

      Map.has_key?(state.started, pane) ->
        tref = make_ref()
        timer = Process.send_after(self(), {:fence_timeout, pane, tref}, state.fence_bound_ms)
        monitor = Process.monitor(caller)
        pending = %{from: from, tref: tref, timer: timer, monitor: monitor}
        {:noreply, %{state | fences: Map.put(state.fences, pane, pending)}}

      true ->
        {:reply, {:ok, make_ref()}, fence_now(state, pane)}
    end
  end

  def handle_call({:begin_command, gate}, {caller, _}, state) do
    %{pane: pane, msg_id: id, attempt: attempt, buffer: buffer} = gate

    refusal =
      cond do
        state.gate_poisoned -> {:error, :effect_journal_unavailable}
        pane in unresolved_panes(state) -> {:error, :effect_unresolved}
        Map.has_key?(state.fences, pane) -> {:error, :fence_pending}
        Map.has_key?(state.started, pane) -> {:error, :command_in_flight}
        EffectJournal.residual_full?(state.journal) -> {:error, :residual_capacity_full}
        true -> gate_binding(state, gate)
      end

    if refusal == :ok do
      case EffectJournal.begin(state.journal, pane, id, attempt, buffer) do
        {:ok, marker, journal} ->
          started = %{marker: marker, owner: caller, monitor: Process.monitor(caller)}

          {:reply, {:ok, marker},
           %{state | journal: journal, started: Map.put(state.started, pane, started)}}

        {:error, _reason} ->
          {:reply, {:error, :effect_journal_unavailable}, poison_gate(state, pane)}
      end
    else
      {:reply, refusal, state}
    end
  end

  # A poisoned gate runs no gated transaction (scope r12): a transaction already STARTED is
  # refused its later steps too, so it ends without an end line and its pane stays held.
  def handle_call({:run_step, marker, exe, args}, {caller, _} = from, state) do
    pane = started_pane(state, marker)

    cond do
      is_nil(pane) ->
        {:reply, {:error, :unknown_marker}, state}

      state.started[pane].owner != caller ->
        {:reply, {:error, :not_gate_owner}, state}

      state.gate_poisoned ->
        {:reply, {:error, :effect_journal_unavailable}, state}

      true ->
        case open_step(exe, args) do
          {:ok, port} -> {:noreply, %{state | steps: Map.put(state.steps, port, from)}}
          # a spawn failure is a completed step without acknowledgement
          :spawn_failed -> {:reply, {:ok, 127}, state}
        end
    end
  end

  def handle_call({:residual_command, marker}, _from, state) do
    case started_pane(state, marker) do
      nil ->
        {:reply, {:error, :unknown_marker}, state}

      pane ->
        case EffectJournal.residual(state.journal, marker) do
          {:ok, journal} ->
            {:reply, :ok, %{state | journal: journal}}

          {:error, _reason} ->
            {:reply, {:error, :effect_journal_unavailable}, poison_gate(state, pane)}
        end
    end
  end

  def handle_call({:end_command, marker, code, cleanup}, _from, state) do
    case started_pane(state, marker) do
      nil ->
        {:reply, {:error, :unknown_marker}, state}

      pane ->
        Process.demonitor(state.started[pane].monitor, [:flush])
        state = %{state | started: Map.delete(state.started, pane)}

        case EffectJournal.finish(state.journal, marker, code, cleanup) do
          {:ok, journal} ->
            {:reply, :ok, complete_fence(%{state | journal: journal}, pane)}

          {:error, _reason} ->
            # the marker stays uncleared on disk as far as this store knows: the pane is held
            state = poison_gate(state, pane)

            {:reply, {:error, :effect_journal_unavailable},
             answer_fence(state, pane, {:error, :command_in_flight})}
        end
    end
  end

  def handle_call(:effect_status, _from, state) do
    status = %{
      unresolved: unresolved_panes(state),
      residual: EffectJournal.residuals(state.journal),
      held: Map.new(state.held, fn {pane, set} -> {pane, Enum.sort(MapSet.to_list(set))} end),
      poisoned: state.gate_poisoned
    }

    {:reply, status, state}
  end

  # Held is a registry state for this store's lifetime only (scope r12, "Held is a registry
  # state"). After a store restart the entry is restored unheld, but its pane is re-admitted
  # QUARANTINED by boot (which pastes nothing), and only a new release can lift that; the
  # release re-reads the entry's recorded pair, which is durable and unchanged, and holds it
  # again (RED R9). So a held entry is never pasted, across restarts included.
  def handle_call({:hold_unmatched, id, attempt, token}, _from, state) do
    with :ok <- valid_id(id),
         true <- restored_entry?(state, id, attempt),
         :ok <- authority(state, id, token, attempt),
         {:ok, current} <- current(state, id) do
      held =
        Map.update(
          state.held,
          current.pane_id,
          MapSet.new([{id, attempt}]),
          &MapSet.put(&1, {id, attempt})
        )

      {:reply, :ok, %{state | held: held}}
    else
      false -> {:reply, {:error, :not_restored}, state}
      {:error, _} = error -> {:reply, error, state}
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
      admit_current(state, id, pane, hash, owner, @unbound)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:admit, id, pane, hash, owner, binding}, _from, state) do
    with :ok <- writable(state),
         :ok <- identity(id, pane, hash),
         :ok <- valid_binding(binding),
         :ok <- live_owner(owner) do
      admit_current(
        state,
        id,
        pane,
        hash,
        owner,
        Map.take(binding, [:registration_id, :generation])
      )
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
         :ok <- not_fence_pending(state, current.pane_id),
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

  # A gated step's exit status (decision 50: the acknowledgement arrives only after BEAM reaped
  # the client) answers its deferred run_step call; its output is discarded.
  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Map.pop(state.steps, port) do
      {nil, _} ->
        {:noreply, state}

      {from, steps} ->
        GenServer.reply(from, {:ok, status})
        {:noreply, %{state | steps: steps}}
    end
  end

  def handle_info({port, {:data, _output}}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:fence_timeout, pane, tref}, state) do
    case state.fences do
      %{^pane => %{tref: ^tref}} ->
        {:noreply, answer_fence(state, pane, {:error, :command_in_flight})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason} = down, state) do
    cond do
      pane = Enum.find_value(state.started, fn {p, s} -> if s.monitor == ref, do: p end) ->
        # The Tmux server died between begin and end. A step it requested runs on in a Port
        # this store owns (its client may still be running or exit later; that exit status
        # answers no one), and nothing proves an end. The marker stays uncleared: held.
        {:noreply, %{state | started: Map.delete(state.started, pane)}}

      pane = Enum.find_value(state.fences, fn {p, f} -> if f.monitor == ref, do: p end) ->
        # The fence caller died: its pending fence is cleared without a reply.
        Process.cancel_timer(state.fences[pane].timer)
        {:noreply, %{state | fences: Map.delete(state.fences, pane)}}

      true ->
        owner_down(down, state)
    end
  end

  defp owner_down({:DOWN, ref, :process, _pid, _reason}, state) do
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
  # S3a: an entry held unmatched is never handed again; it stays listed in the registry.
  defp handed(state, entries) do
    entries
    |> Enum.reject(&held_entry?(state, &1))
    |> Enum.map(fn entry ->
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

  # A duplicate answers the stored view, its pair untouched; only a new attempt takes `pair`.
  defp admit_current(state, id, pane, hash, owner, pair) do
    case public(state, id) do
      {:error, {:unknown_message_id, _}} ->
        admit_attempt(state, id, pane, hash, owner, 1, pair)

      {:ok, %{pane_id: ^pane, payload_hash: ^hash, status: "not_delivered"} = view} ->
        admit_attempt(state, id, pane, hash, owner, view.delivery_attempt + 1, pair)

      {:ok, %{pane_id: ^pane, payload_hash: ^hash} = view} ->
        {:reply, {:ok, {:duplicate, view}}, state}

      {:ok, view} ->
        {:reply, {:error, {:conflict, view}}, state}
    end
  end

  defp admit_attempt(state, id, pane, hash, owner, attempt, pair) do
    view =
      Map.merge(
        %{
          message_id: id,
          pane_id: pane,
          payload_hash: hash,
          status: "pending",
          delivery_attempt: attempt
        },
        pair
      )

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

  # ----- S3a gate helpers -----

  # Held panes: an uncleared marker whose transaction is not STARTED by a live Tmux server,
  # and any pane whose journal write failed in this store's lifetime.
  defp unresolved_panes(state) do
    state.journal
    |> EffectJournal.unresolved()
    |> Enum.reject(&Map.has_key?(state.started, &1))
    |> MapSet.new()
    |> MapSet.union(state.held_in_memory)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  # A gate is bound to the exact attempt it names: valid values, a live token for that
  # attempt, the receipt's own pane, and a durable paste_started (begin_paste ran first).
  # A token for one pane can therefore never open a transaction under another.
  defp gate_binding(state, %{pane: pane, msg_id: id, attempt: attempt, token: token, buffer: buffer}) do
    with true <- ReceiptLog.valid_pane?(pane) and is_integer(attempt) and attempt >= 1,
         true <- is_binary(buffer) and Regex.match?(~r/\Aai_pair_[0-9]+\z/, buffer),
         :ok <- valid_id(id),
         {:ok, current} <- current(state, id),
         true <- current.pane_id == pane and current.delivery_attempt == attempt,
         true <- current.status == "paste_started" and MapSet.member?(state.in_flight, id) do
      authority(state, id, token, attempt)
    else
      false -> {:error, :gate_mismatch}
      {:error, _} = error -> error
    end
  end

  defp open_step(exe, args) do
    {:ok,
     Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, args: args])}
  rescue
    _ in [ErlangError, ArgumentError] -> :spawn_failed
  end

  defp started_pane(state, marker),
    do: Enum.find_value(state.started, fn {pane, s} -> if s.marker == marker, do: pane end)

  # A journal write failure poisons the gate for the store's lifetime and holds the pane.
  defp poison_gate(state, pane),
    do: %{state | gate_poisoned: true, held_in_memory: MapSet.put(state.held_in_memory, pane)}

  defp not_fence_pending(state, pane),
    do: if(Map.has_key?(state.fences, pane), do: {:error, :fence_pending}, else: :ok)

  # The S2 fence itself: revoke the capability, re-mint every token, mark holders fenced.
  defp fence_now(state, pane) do
    state = remint(%{state | caps: Map.delete(state.caps, pane)}, pane)

    restore =
      Map.update(state.restore, pane, [], fn entries ->
        Enum.map(entries, fn
          %{holder: pid} = entry when is_pid(pid) -> %{entry | holder: {:fenced, pid}}
          entry -> entry
        end)
      end)

    %{state | restore: restore}
  end

  # The STARTED transaction of `pane` ended: a pending fence takes effect now, exactly once.
  defp complete_fence(state, pane) do
    case Map.fetch(state.fences, pane) do
      {:ok, _pending} ->
        state = fence_now(state, pane)
        answer_fence(state, pane, {:ok, make_ref()})

      :error ->
        state
    end
  end

  defp answer_fence(state, pane, reply) do
    case Map.pop(state.fences, pane) do
      {nil, _} ->
        state

      {pending, fences} ->
        Process.cancel_timer(pending.timer)
        Process.demonitor(pending.monitor, [:flush])
        GenServer.reply(pending.from, reply)
        %{state | fences: fences}
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

  # A binding the log could not read back is refused before any line is written.
  defp valid_binding(%{registration_id: id, generation: gen}) do
    if ReceiptLog.valid_pair?(id, gen),
      do: :ok,
      else: {:error, {:invalid_registration_binding, :grammar}}
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

  defp held_entry?(state, entry) do
    Enum.any?(state.held, fn {_pane, set} -> MapSet.member?(set, {entry.msg_id, entry.attempt}) end)
  end

  defp close_log_on_failure(log) do
    case ReceiptLog.close(log) do
      :ok -> :ok
      {:error, reason} -> Logger.error("receipt store close failed: #{inspect(reason)}")
    end
  end

  defp close_on_failure(state) do
    close_log_on_failure(state.log)

    case EffectJournal.close(state.journal) do
      :ok -> :ok
      {:error, reason} -> Logger.error("effect journal close failed: #{inspect(reason)}")
    end
  end
end
