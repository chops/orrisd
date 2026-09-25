defmodule AiPair.Pane.StateMachine do
  @moduledoc """
  Per-pane `:gen_statem`. One process per tmux pane.

  States:

      :idle | :busy | :dialog | :dead | :unknown

  ## Lifecycle

  Each tick (every `:poll_interval_ms`) the state machine captures the
  pane via the injected `:capture_fn`, ANSI-strips, runs the configured
  classifier, and transitions on mismatch.

  ## Send eligibility

  Sends are eligible only when:
    1. current state is `:idle`,
    2. the pane has been continuously idle for `:idle_debounce_ms`,
    3. the captured content has been stable across the debounce window
       (mid-stream output that fingerprints as `:idle` — e.g. Codex CLI
       0.128 once tokens flow — keeps resetting the timer).

  ## Injection points

  Tests pass `:capture_fn`, `:paste_fn`, and `:classifier` to drive
  transitions deterministically without a real tmux server. Production
  defaults wrap `AiPair.Tmux`.

  ## Quarantine

  A pane started with a `:quarantine_token` is *quarantined*: it is a
  restored pane whose binding to an agent has not been re-established, so
  it must not be written to. Quarantine is derived from start options at
  `init/1` rather than set by a runtime call, so a `restart: :transient`
  replacement comes back quarantined from the same child spec.

  Quarantine suppresses EFFECTS ONLY. It never suppresses observation and
  never suppresses the processing of events:

    * every dispatch entry point is refused with `{:error, :pane_quarantined}`
      — refused, not queued, because queued work would paste the moment the
      gate opened;
    * the debounce timer is still armed, still delivered and still CONSUMED;
      the drain handler declines to paste and leaves the queue intact. Going
      quiet instead (cancelling the timer, dropping the event) would destroy
      the evidence an operator needs to see that the pane is still running;
    * `state/1`, `status/1`, `get_info/1` and `pending_count/1` keep
      answering truthfully.

  The token is the operator's secret — it is what proves who may later
  release the quarantine. It is held but never surfaced: `status/1` exposes
  only the boolean `:quarantined`, and the token is never logged and never
  placed in telemetry metadata. No release API ships here; this is the
  field and the gate.
  """

  @behaviour :gen_statem

  alias AiPair.Delivery.{Payload, ReceiptStore}

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @type pane_id :: String.t()
  @type pane_state :: :idle | :busy | :dialog | :dead | :unknown
  @type capture_fn :: (pane_id() -> {:ok, binary()} | {:error, term()})
  @type paste_fn :: (pane_id(), binary() -> :ok | {:error, term()})

  # The quarantine token is the operator's secret: it is what will later
  # authorize releasing the pane. `status/1` already withholds it, but that
  # only covers the callers who go through `status/1`. Redacting at the
  # struct covers the paths nobody asserts on -- `:sys.get_state/1`, crash
  # dumps, SASL supervisor reports, and any error tuple carrying the state.
  # The field is untouched and quarantine still derives from it at `init/1`;
  # only its rendering is suppressed.
  @derive {Inspect, except: [:quarantine_token]}
  defstruct [
    :pane_id,
    :receipt_store,
    :agent,
    :classifier_name,
    :capture_fn,
    :paste_fn,
    :classifier,
    :poll_interval_ms,
    :idle_debounce_ms,
    :idle_since_ms,
    :last_stripped_hash,
    :pane_gone_threshold,
    :pane_gone_grace_ms,
    :pane_gone_since_ms,
    :recovery_candidate,
    :quarantine_token,
    recovering_capture: false,
    pending_sends: :queue.new(),
    pane_gone_count: 0
  ]

  @default_poll_interval_ms 250
  @default_idle_debounce_ms 500

  # Cap on `pending_sends`. Stops a stuck-busy pane (or one whose classifier
  # never flips back to :idle) from accumulating an unbounded queue. Picked
  # so that legitimate sustained chat backlogs survive but a wedged pane
  # surfaces fast as `{:error, :queue_full}` instead of growing the heap.
  @max_pending_sends 32

  # Dead-pane reaper. We mark a pane :dead only after we observe
  # `{:error, :pane_gone}` from the capture path on at least
  # `@default_pane_gone_threshold` consecutive captures AND at least
  # `@default_pane_gone_grace_ms` of wall-clock time has elapsed since the
  # first observation (counted from after the last successful capture). A
  # successful capture resets both counters. Non-`:pane_gone` capture
  # errors are logged but do NOT advance the reaper — they're treated as
  # transient and clear send eligibility until fresh idle captures recover.
  @default_pane_gone_threshold 2
  @default_pane_gone_grace_ms 30_000

  # ===== Public API =====

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  @spec state(:gen_statem.server_ref()) :: pane_state()
  def state(server), do: :gen_statem.call(server, :state)

  @doc """
  Enqueue text for delivery. Returns:
    * `:ok` — pasted immediately (idle + debounce satisfied)
    * `{:queued, :debounce}` — pane is idle but the debounce/content-stability
      gate hasn't elapsed yet; will drain when it does
    * `{:queued, pane_state()}` — pane is in a non-idle state (busy/dialog/
      unknown); will drain on the next idle transition
    * `{:error, :pane_dead}` — pane is gone, never coming back
    * `{:error, :pane_quarantined}` — the pane is quarantined (see the
      "Quarantine" section above). Refused outright: NOT enqueued, because
      a queued send would paste as soon as the gate opened.
    * `{:error, {:paste_failed, reason}}` — pane was eligible but the
      injected `paste_fn` returned `{:error, reason}` (tmux failure,
      buffer write refused, etc.). The state machine stays alive; the
      caller decides whether to retry.
    * `{:error, {:queue_full, cap}}` — `pending_sends` is at the cap
      (`#{@max_pending_sends}`). The send is dropped, not enqueued; the
      pane is likely stuck-busy or the classifier never flipped back.

  Drain failures (a queued send that fails to paste once the pane returns
  to idle) are logged and dropped — they do NOT bounce back to the queue
  to avoid silent infinite retries.
  """
  @send_call_default_timeout_ms 5_000

  @spec send_text(:gen_statem.server_ref(), binary(), timeout(), String.t() | nil) ::
          :ok
          | {:queued, :debounce | pane_state()}
          | {:error, :pane_dead}
          | {:error, :pane_quarantined}
          | {:error, {:paste_failed, term()}}
          | {:error, {:queue_full, pos_integer()}}
  def send_text(server, text, timeout \\ @send_call_default_timeout_ms, msg_id \\ nil)
      when is_binary(text) do
    # Capture caller's OTel context here — `:otel_ctx` lives in the
    # caller's process dictionary, and `:gen_statem.call/3` delivers the
    # message to a different BEAM process. The callee re-attaches before
    # opening the `pane.paste` span so parent-child linkage survives the
    # process hop (and the deferred drain on a queued send).
    ctx = :otel_ctx.get_current()
    :gen_statem.call(server, {:send_text, Payload.new(text), ctx, msg_id}, timeout)
  end

  @doc false
  def send_legacy(server, text, timeout, msg_id),
    do: :gen_statem.call(server, {:send_untracked, text, :otel_ctx.get_current(), msg_id}, timeout)

  @doc "Send with the receipt authority selected by the versioned IPC listener."
  def send_receipted(server, text, timeout, msg_id, store),
    do:
      :gen_statem.call(
        server,
        {:send_receipted, Payload.new(text), :otel_ctx.get_current(), msg_id, store},
        timeout
      )

  @doc """
  The cap on the pending-sends queue. Exposed so callers and tests can
  reference the same value the state machine enforces.
  """
  @spec max_pending_sends() :: pos_integer()
  def max_pending_sends, do: @max_pending_sends

  @spec mark_dead(:gen_statem.server_ref()) :: :ok
  def mark_dead(server), do: :gen_statem.cast(server, :mark_dead)

  @spec pending_count(:gen_statem.server_ref()) :: non_neg_integer()
  def pending_count(server), do: :gen_statem.call(server, :pending_count)

  @doc """
  Snapshot of process metadata: which agent, which classifier flavor,
  and current state. Used by IPC to report classifier on duplicate attach.
  """
  @spec get_info(:gen_statem.server_ref()) :: %{
          agent: String.t() | nil,
          classifier_name: String.t() | nil,
          state: pane_state()
        }
  def get_info(server), do: :gen_statem.call(server, :get_info)

  @doc """
  Combined snapshot for orchestrators: state + pending queue depth + the
  same metadata `get_info/1` returns. Single atomic call so `pending_count`
  is consistent with `state` at the moment the SM replies.

  `:quarantined` reports the FACT of quarantine and never the token that
  established it: the token is the operator's secret and is deliberately
  absent from this map, so `inspect/1` of a snapshot cannot leak it.
  """
  @spec status(:gen_statem.server_ref()) :: %{
          agent: String.t() | nil,
          classifier_name: String.t() | nil,
          state: pane_state(),
          pending_count: non_neg_integer(),
          quarantined: boolean()
        }
  def status(server), do: :gen_statem.call(server, :status)

  # ===== gen_statem callbacks =====

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(opts) do
    pane_id = Keyword.fetch!(opts, :pane_id)

    data = %__MODULE__{
      pane_id: pane_id,
      receipt_store: Keyword.get(opts, :receipt_store),
      agent: Keyword.get(opts, :agent),
      classifier_name: Keyword.get(opts, :classifier_name),
      capture_fn: Keyword.get(opts, :capture_fn, &default_capture/1),
      paste_fn: Keyword.get(opts, :paste_fn, &default_paste/2),
      classifier: Keyword.get(opts, :classifier, AiPair.Pane.Classifier.Stub),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      idle_debounce_ms: Keyword.get(opts, :idle_debounce_ms, @default_idle_debounce_ms),
      pane_gone_threshold:
        Keyword.get(
          opts,
          :pane_gone_threshold,
          Application.get_env(:ai_pair, :pane_gone_threshold, @default_pane_gone_threshold)
        ),
      pane_gone_grace_ms:
        Keyword.get(
          opts,
          :pane_gone_grace_ms,
          Application.get_env(:ai_pair, :pane_gone_grace_ms, @default_pane_gone_grace_ms)
        ),
      # DERIVED FROM START OPTIONS, never from a runtime call. A
      # `restart: :transient` replacement is started from the same child
      # spec (pane_supervisor.ex), so it comes back quarantined without
      # anyone re-quarantining it — which is the only way containment can
      # survive a crash.
      quarantine_token: Keyword.get(opts, :quarantine_token)
    }

    {:ok, :unknown, data, [{{:timeout, :poll}, 0, nil}]}
  end

  # ----- entry actions -----

  @impl true
  def handle_event(:enter, _old, :idle, data) do
    data2 = %{data | idle_since_ms: now_ms()}
    actions = [{:state_timeout, data.idle_debounce_ms, :drain_pending}]
    {:keep_state, data2, actions}
  end

  def handle_event(:enter, _old, :dead, data) do
    {:keep_state, %{data | idle_since_ms: nil}, [{{:timeout, :poll}, :cancel}]}
  end

  def handle_event(:enter, _old, _new, data) do
    {:keep_state, %{data | idle_since_ms: nil}}
  end

  # ----- poll tick -----

  # Death is terminal for this registered process. Ignore a late poll even
  # if its timer event was already pending when the pane was marked dead.
  def handle_event({:timeout, :poll}, _, :dead, _data), do: :keep_state_and_data

  def handle_event({:timeout, :poll}, _, state, data) do
    started_at_us = System.monotonic_time(:microsecond)

    case data.capture_fn.(data.pane_id) do
      {:ok, raw} ->
        stripped = strip_ansi(raw)
        hash = :erlang.phash2(stripped)
        classified = classify_stripped(data.classifier, stripped)
        {next, data} = recover_capture(data, classified, hash)
        content_changed? = hash != data.last_stripped_hash
        emit_poll_telemetry(started_at_us, state, next, content_changed?, data)

        data2 = %{
          data
          | last_stripped_hash: hash,
            pane_gone_count: 0,
            pane_gone_since_ms: nil
        }

        repoll = {{:timeout, :poll}, data.poll_interval_ms, nil}

        cond do
          next != state ->
            emit_decision_telemetry(state, next, data)
            emit_transition_span(state, next, data)
            {:next_state, next, data2, [repoll]}

          # Mid-stream output that fingerprints as :idle keeps shifting
          # the captured content. Reset the debounce window so a queued
          # send doesn't fire while the TUI is still producing tokens.
          next == :idle and content_changed? ->
            data3 = %{data2 | idle_since_ms: now_ms()}
            actions = [repoll, {:state_timeout, data.idle_debounce_ms, :drain_pending}]
            {:keep_state, data3, actions}

          true ->
            {:keep_state, data2, [repoll]}
        end

      {:error, :pane_gone} ->
        handle_pane_gone(started_at_us, state, data)

      {:error, reason} ->
        # An unreadable pane is not dead, but its previous idle verdict
        # cannot authorize delivery. Leaving idle cancels its debounce.
        emit_poll_telemetry(started_at_us, state, :unknown, false, data)

        Logger.warning(fn ->
          "ai_pair: pane=#{data.pane_id} non-pane capture error (state unknown): " <>
            inspect(reason)
        end)

        repoll = {{:timeout, :poll}, data.poll_interval_ms, nil}

        if state != :unknown do
          emit_decision_telemetry(state, :unknown, data)
          emit_transition_span(state, :unknown, data)
        end

        data2 = %{
          data
          | idle_since_ms: nil,
            last_stripped_hash: nil,
            recovering_capture: true,
            recovery_candidate: nil
        }

        {:next_state, :unknown, data2, [repoll]}
    end
  end

  # ----- idle debounce expired: drain queued sends -----

  # THE GUARD IS HERE, AT THE HANDLER, AND NOT AT THE ARMING SITE. The
  # debounce timer is still armed on entering :idle, still delivered, and
  # still CONSUMED by this clause — the state machine keeps running and an
  # observer can still see it processing its own timers. What is suppressed
  # is the paste, not the event. Declining to arm the timer would suppress
  # the event instead, which looks identical from outside to a wedged pane.
  #
  # The queue is left INTACT: these entries are not discharged, they are
  # held, and `pending_count/1` keeps reporting them.
  def handle_event(:state_timeout, :drain_pending, :idle, data)
      when not is_nil(:erlang.map_get(:quarantine_token, data)) do
    :keep_state_and_data
  end

  def handle_event(:state_timeout, :drain_pending, :idle, data) do
    rest = drain_queue(data, data.pending_sends)
    {:keep_state, %{data | pending_sends: rest}}
  end

  # ----- inspection / control -----

  def handle_event({:call, from}, :state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, :pending_count, _state, data) do
    {:keep_state_and_data, [{:reply, from, :queue.len(data.pending_sends)}]}
  end

  def handle_event({:call, from}, :get_info, state, data) do
    info = %{agent: data.agent, classifier_name: data.classifier_name, state: state}
    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event({:call, from}, :status, state, data) do
    info = %{
      agent: data.agent,
      classifier_name: data.classifier_name,
      state: state,
      pending_count: :queue.len(data.pending_sends),
      # The BOOLEAN only. Putting the token here would surface the
      # operator's secret to every status caller, every IPC reply built
      # from one, and every `inspect/1` of a snapshot.
      quarantined: quarantined?(data)
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event(:cast, :mark_dead, _state, data) do
    {:next_state, :dead, settle_dead_queue(data), []}
  end

  # ----- quarantine: every dispatch entry point is refused -----

  # Placed AHEAD of all three send clauses so the refusal is reached before
  # any state-dependent admission: before the receipt store is consulted
  # (a refused send must not be admitted, or it would hold a receipt it can
  # never discharge), and before the non-idle queueing path (queued work
  # would paste the instant the pane reached idle, which is exactly the
  # effect quarantine exists to prevent).
  #
  # Matching on the request TAG rather than on each shape keeps this single
  # clause total over the dispatch surface: a fourth entry point cannot be
  # added without either appearing in this list or failing to compile a
  # reachable clause below it.
  #
  # The reply is TYPED and names the reason. A bare `{:error, :refused}` —
  # or worse, a silent `:ok` with no paste — would leave an operator unable
  # to tell a quarantined pane from a broken one.
  def handle_event({:call, from}, request, _state, data)
      when not is_nil(:erlang.map_get(:quarantine_token, data)) and is_tuple(request) and
             elem(request, 0) in [:send_text, :send_untracked, :send_receipted] do
    {:keep_state_and_data, [{:reply, from, {:error, :pane_quarantined}}]}
  end

  # ----- send_text per state -----

  def handle_event({:call, from}, {:send_receipted, text, ctx, msg_id, store}, state, data) do
    if not is_nil(store) and data.receipt_store == store,
      do: admit_send(from, text, ctx, msg_id, state, data),
      else: {:keep_state_and_data, [{:reply, from, {:error, :receipt_store_mismatch}}]}
  end

  def handle_event({:call, from}, {:send_text, text, ctx, msg_id}, state, data) do
    if not is_nil(data.receipt_store) and not is_nil(msg_id),
      do: admit_send(from, text, ctx, msg_id, state, data),
      else:
        handle_event(
          {:call, from},
          {:send_untracked, Payload.reveal(text), ctx, msg_id},
          state,
          data
        )
  end

  def handle_event({:call, from}, {:send_untracked, _text, _ctx, _msg_id}, :dead, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :pane_dead}}]}
  end

  def handle_event({:call, from}, {:send_untracked, text, ctx, msg_id}, :idle, data) do
    cond do
      idle_long_enough?(data) ->
        reply =
          with_ctx(ctx, fn ->
            case do_paste(data, text, "send_text", 0, msg_id) do
              :ok -> :ok
              {:error, reason} -> {:error, {:paste_failed, reason}}
            end
          end)

        {:keep_state_and_data, [{:reply, from, reply}]}

      queue_full?(data) ->
        emit_send_rejected_telemetry(:idle, data)

        {:keep_state_and_data, [{:reply, from, {:error, {:queue_full, @max_pending_sends}}}]}

      true ->
        entry = {text, ctx, msg_id, now_ms()}
        data2 = %{data | pending_sends: :queue.in(entry, data.pending_sends)}
        {:keep_state, data2, [{:reply, from, {:queued, :debounce}}]}
    end
  end

  def handle_event({:call, from}, {:send_untracked, text, ctx, msg_id}, state, data) do
    if queue_full?(data) do
      emit_send_rejected_telemetry(state, data)

      {:keep_state_and_data, [{:reply, from, {:error, {:queue_full, @max_pending_sends}}}]}
    else
      entry = {text, ctx, msg_id, now_ms()}
      data2 = %{data | pending_sends: :queue.in(entry, data.pending_sends)}
      {:keep_state, data2, [{:reply, from, {:queued, state}}]}
    end
  end

  # ===== Helpers =====

  defp admit_send(from, text, ctx, msg_id, state, data) do
    hash = Payload.hash(text)

    case receipt_call(fn ->
           ReceiptStore.admit(data.receipt_store, msg_id, data.pane_id, hash, self())
         end) do
      {:ok, {:admitted, %{operation_token: token}}} ->
        send_admitted(from, text, ctx, msg_id, token, state, data)

      {:ok, {:duplicate, view}} ->
        {:keep_state_and_data, [{:reply, from, {:duplicate, view}}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  defp send_admitted(from, text, ctx, msg_id, token, state, data) do
    cond do
      state == :dead ->
        result = finish_unsent(data, msg_id, token, :pane_dead)
        {:keep_state_and_data, [{:reply, from, result}]}

      state == :idle and idle_long_enough?(data) ->
        result = with_ctx(ctx, fn -> paste_receipted(data, text, msg_id, token, 0) end)
        {:keep_state_and_data, [{:reply, from, result}]}

      queue_full?(data) ->
        emit_send_rejected_telemetry(state, data)
        result = finish_unsent(data, msg_id, token, {:queue_full, @max_pending_sends})
        {:keep_state_and_data, [{:reply, from, result}]}

      true ->
        case receipt_call(fn ->
               ReceiptStore.transition(data.receipt_store, msg_id, token, "queued")
             end) do
          :ok ->
            entry = {:receipted, text, ctx, msg_id, now_ms(), token}
            reason = if state == :idle, do: :debounce, else: state

            {:keep_state, %{data | pending_sends: :queue.in(entry, data.pending_sends)},
             [{:reply, from, {:queued, reason}}]}

          {:error, _} = error ->
            {:keep_state_and_data, [{:reply, from, error}]}
        end
    end
  end

  defp finish_unsent(data, id, token, reason) do
    with :ok <-
           receipt_call(fn ->
             ReceiptStore.transition(data.receipt_store, id, token, "not_delivered")
           end),
         do: {:error, reason}
  end

  defp paste_receipted(data, text, id, token, wait_ms) do
    with :ok <- receipt_call(fn -> ReceiptStore.begin_paste(data.receipt_store, id, token) end) do
      safe_data = %{data | paste_fn: fn pane, bytes -> safe_paste(data.paste_fn, pane, bytes) end}
      result = do_paste(safe_data, Payload.reveal(text), "receipt_delivery", wait_ms, id)
      status = if result == :ok, do: "delivered", else: "ambiguous"

      with :ok <-
             receipt_call(fn -> ReceiptStore.transition(data.receipt_store, id, token, status) end) do
        if result == :ok, do: :ok, else: {:error, {:paste_failed, :ambiguous}}
      end
    end
  end

  defp safe_paste(paste_fn, pane, bytes) do
    case paste_fn.(pane, bytes) do
      :ok -> :ok
      _ -> {:error, :ambiguous_paste}
    end
  rescue
    _ -> {:error, :ambiguous_paste}
  catch
    _, _ -> {:error, :ambiguous_paste}
  end

  defp receipt_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :receipt_store_unavailable}
  end

  defp recover_capture(%{recovering_capture: false} = data, classified, _hash),
    do: {classified, data}

  defp recover_capture(%{recovery_candidate: {:busy, _previous_hash}} = data, :busy, _hash),
    do: {:busy, %{data | recovering_capture: false, recovery_candidate: nil}}

  defp recover_capture(%{recovery_candidate: {classified, hash}} = data, classified, hash),
    do: {classified, %{data | recovering_capture: false, recovery_candidate: nil}}

  defp recover_capture(data, classified, hash),
    do: {:unknown, %{data | recovery_candidate: {classified, hash}}}

  # ----- pane_gone reaper -----

  defp handle_pane_gone(started_at_us, state, data) do
    now = now_ms()
    count = data.pane_gone_count + 1
    since = data.pane_gone_since_ms || now
    elapsed = now - since
    repoll = {{:timeout, :poll}, data.poll_interval_ms, nil}

    if count >= data.pane_gone_threshold and elapsed >= data.pane_gone_grace_ms do
      emit_poll_telemetry(started_at_us, state, :dead, false, data)
      emit_decision_telemetry(state, :dead, data)
      emit_transition_span(state, :dead, data)
      emit_reaped_telemetry(elapsed, count, state, data)

      Logger.warning(fn ->
        "ai_pair: reaping pane=#{data.pane_id} after #{count} consecutive :pane_gone " <>
          "captures over #{elapsed}ms (pending=#{:queue.len(data.pending_sends)})"
      end)

      {:next_state, :dead, settle_dead_queue(data), []}
    else
      data2 = %{data | pane_gone_count: count, pane_gone_since_ms: since}
      not_reaped(started_at_us, state, data2, repoll)
    end
  end

  # H-4: a pane observed gone cannot keep an idle verdict while it waits for
  # the reaper. Mirror the non-pane capture error path: leave idle on the
  # first :pane_gone, so sends queue as :unknown instead of pasting, and
  # recovery needs fresh matching captures. The reaper counters are kept,
  # so its threshold and grace are unchanged.
  defp not_reaped(started_at_us, :idle, data, repoll) do
    emit_poll_telemetry(started_at_us, :idle, :unknown, false, data)
    emit_decision_telemetry(:idle, :unknown, data)
    emit_transition_span(:idle, :unknown, data)

    data2 = %{
      data
      | idle_since_ms: nil,
        last_stripped_hash: nil,
        recovering_capture: true,
        recovery_candidate: nil
    }

    {:next_state, :unknown, data2, [repoll]}
  end

  defp not_reaped(started_at_us, state, data, repoll) do
    emit_poll_telemetry(started_at_us, state, state, false, data)
    {:keep_state, data, [repoll]}
  end

  defp classify_stripped(classifier, stripped) do
    case classifier do
      fun when is_function(fun, 1) -> fun.(stripped)
      mod when is_atom(mod) -> mod.classify(stripped)
    end
  end

  defp strip_ansi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, binary, "")
  end

  defp idle_long_enough?(%{idle_since_ms: nil}), do: false

  defp idle_long_enough?(%{idle_since_ms: since, idle_debounce_ms: dbms}) do
    now_ms() - since >= dbms
  end

  defp queue_full?(%{pending_sends: q}), do: :queue.len(q) >= @max_pending_sends

  # Presence of the token IS the quarantine. Nothing reads the token's
  # value; it is held so that a future release path can require it.
  defp quarantined?(%{quarantine_token: nil}), do: false
  defp quarantined?(%{quarantine_token: _token}), do: true

  defp settle_dead_queue(data) do
    remaining =
      data.pending_sends
      |> :queue.to_list()
      |> Enum.reject(fn
        {:receipted, _payload, _ctx, id, _enqueued_at, token} ->
          result =
            receipt_call(fn ->
              ReceiptStore.transition(data.receipt_store, id, token, "not_delivered")
            end)

          if result != :ok,
            do:
              Logger.warning(
                "ai_pair: dead-pane receipt finalization failed; reconciliation required"
              )

          true

        _legacy ->
          false
      end)

    %{data | pending_sends: :queue.from_list(remaining)}
  end

  defp drain_queue(data, queue) do
    case :queue.out(queue) do
      {:empty, _} ->
        queue

      {{:value, {:receipted, text, ctx, msg_id, enqueued_at, token}}, rest} ->
        result =
          with_ctx(ctx, fn ->
            paste_receipted(data, text, msg_id, token, max(now_ms() - enqueued_at, 0))
          end)

        if result != :ok,
          do: Logger.warning("ai_pair: receipted queue drain failed; reconciliation required")

        drain_queue(data, rest)

      {{:value, {text, ctx, msg_id, enqueued_ms}}, rest} ->
        wait_ms = now_ms() - enqueued_ms

        result =
          with_ctx(ctx, fn -> do_paste(data, text, "drain_queue", wait_ms, msg_id) end)

        case result do
          :ok ->
            drain_queue(data, rest)

          {:error, reason} ->
            Logger.warning(fn ->
              "ai_pair: dropping queued send for pane=#{data.pane_id} after paste failure: " <>
                inspect(reason) <> " (text bytes=#{byte_size(text)})"
            end)

            drain_queue(data, rest)
        end
    end
  end

  # Attach a captured OTel context for the duration of `fun`, then detach
  # in `after` so the SM's process dict isn't left holding a foreign ctx.
  # Leaking would poison every subsequent span this process opens.
  defp with_ctx(ctx, fun) do
    token = :otel_ctx.attach(ctx)

    try do
      fun.()
    after
      :otel_ctx.detach(token)
    end
  end

  defp do_paste(data, text, source, queue_wait_ms, msg_id) do
    Tracer.with_span "pane.paste", %{
      kind: :internal,
      attributes:
        drop_nils(%{
          "pane.id" => data.pane_id,
          "pane.agent" => data.agent,
          "pane.classifier" => data.classifier_name,
          "paste.bytes" => byte_size(text),
          "paste.source" => source,
          "paste.queue_wait_ms" => queue_wait_ms,
          "messaging.message.id" => msg_id
        })
    } do
      case data.paste_fn.(data.pane_id, text) do
        :ok ->
          Tracer.set_attribute("paste.outcome", "ok")
          :ok

        {:error, reason} = err ->
          Tracer.set_attribute("paste.outcome", "error")
          Tracer.set_status(:error, inspect(reason))
          err
      end
    end
  end

  defp emit_transition_span(from, to, data) do
    Tracer.with_span "pane.transition", %{
      kind: :internal,
      attributes:
        drop_nils(%{
          "pane.id" => data.pane_id,
          "pane.agent" => data.agent,
          "pane.classifier" => data.classifier_name,
          "pane.from_state" => Atom.to_string(from),
          "pane.to_state" => Atom.to_string(to)
        })
    } do
      :ok
    end
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit_poll_telemetry(started_at_us, from_state, to_state, content_changed?, data) do
    :telemetry.execute(
      [:ai_pair, :pane, :poll],
      %{duration_us: System.monotonic_time(:microsecond) - started_at_us},
      %{
        pane_id: data.pane_id,
        agent: data.agent,
        classifier_name: data.classifier_name,
        from_state: from_state,
        to_state: to_state,
        content_changed: content_changed?
      }
    )
  end

  defp emit_decision_telemetry(from_state, to_state, data) do
    :telemetry.execute(
      [:ai_pair, :classifier, :decision],
      %{system_time: System.system_time()},
      %{
        pane_id: data.pane_id,
        agent: data.agent,
        classifier_name: data.classifier_name,
        from_state: from_state,
        to_state: to_state
      }
    )
  end

  defp emit_send_rejected_telemetry(from_state, data) do
    :telemetry.execute(
      [:ai_pair, :ipc, :send_rejected],
      %{count: 1, cap: @max_pending_sends},
      %{
        pane_id: data.pane_id,
        agent: data.agent,
        reason: :queue_full,
        from_state: from_state
      }
    )
  end

  defp emit_reaped_telemetry(elapsed_ms, capture_count, from_state, data) do
    :telemetry.execute(
      [:ai_pair, :pane, :reaped],
      %{
        elapsed_ms: elapsed_ms,
        capture_count: capture_count,
        pending_count: :queue.len(data.pending_sends)
      },
      %{
        pane_id: data.pane_id,
        agent: data.agent,
        classifier_name: data.classifier_name,
        from_state: from_state
      }
    )
  end

  defp default_capture(pane_id) do
    AiPair.Tmux.capture_pane(pane_id, [], AiPair.Tmux)
  end

  defp default_paste(pane_id, text) do
    buffer_name = "ai_pair_#{System.unique_integer([:positive])}"

    with :ok <- AiPair.Tmux.set_buffer(buffer_name, text),
         :ok <- AiPair.Tmux.paste_buffer(pane_id, buffer_name, delete: true),
         :ok <- AiPair.Tmux.send_keys(pane_id, ["Enter"]) do
      :ok
    end
  end
end
