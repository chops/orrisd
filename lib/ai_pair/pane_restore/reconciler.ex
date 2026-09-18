defmodule AiPair.PaneRestore.Reconciler do
  @moduledoc """
  Boot-time reconciliation of recorded pane intents against the live tmux
  census and the per-session ownership markers.

  `reconcile/1` runs once per durable boot. It observes three sources it does
  not own - the intent store (`AiPair.PaneIntentStore.list/1`), the strict
  census (`AiPair.Tmux.observe_panes/1`) and one marker per session the census
  enumerates (`AiPair.PaneRestore.Marker.read/2`) - and hands every recorded
  pane to `AiPair.PaneRestore.Admission`. A pane that is admissible on the
  snapshot is then taken through the `AiPair.PaneRestore.Coordinator` fence,
  where intent, census and marker are read AGAIN and admission is re-run on the
  fresh reads; only a fresh admissible decision that agrees with the snapshot
  starts the pane, and it starts it quarantined, through the real
  `AiPair.PaneSupervisor` start request dispatched by the coordinator's owned
  worker.

  ## What this module never does

    * It never writes. There is no call to `PaneIntentStore.put/2` or
      `delete/2` and no call to `Marker.ensure/3` or any `set-option`: a stale
      record is refused and RETAINED, a session without a marker is refused,
      and the report says so. Deleting a record merely because a boot could not
      match it would destroy the evidence an operator needs.
    * It takes no session id. Every marker is looked up by the admitted pane's
      own observed `session_id`; a store may hold panes from several sessions
      and each is judged only against its own session's marker.
    * It never restores a pane to service: a started pane is quarantined and
      reported `dispatchable: false`. Release from quarantine is not here.
    * It never invents a pane: a live pane with no record produces no row.

  ## The report

  The in-memory report is the shape the boot report contract
  (`docs/contracts/boot-report.org`) freezes; the on-disk writer arrives with
  the Boot slice. It carries `root`, `panes` (one row per intent row, in intent
  order), `issues` (de-duplicated, in the contract's concatenation order),
  `marker_observation` and `marker_writes: 0`. Pane rows carry the Admission
  refusals verbatim plus three execution refusals of this module's own:
  `{:fence_refused, admission_error}` when the coordinator refused the pane's
  fence, `{:source_changed, role}` when the fenced re-read of `role` differed
  from the snapshot, and `{:quarantine_unavailable, reason}` when the fenced
  start request did not start the pane. A fence refusal is never mistaken for
  an Admission finding: it is a distinct head, so `:pane_busy` can never read
  as live absence or a marker mismatch.

  ## Observation vocabulary

  Each source is handed to Admission as a report about an attempt to observe,
  never as bare data: `{:observed, value}`, `:unavailable` (the process could
  not be asked) or `{:error, term}` (it was asked and failed). A failed source
  is never collapsed into an empty one, so `panes: []` with `issues: []` means
  every source answered and nothing was recorded.
  """

  alias AiPair.PaneIntentStore
  alias AiPair.PaneRestore.{Admission, Coordinator, Marker}
  alias AiPair.PaneSupervisor
  alias AiPair.Tmux

  @options [:store, :root, :tmux, :binding, :callbacks]

  @typedoc "The bound child effects: capture and paste functions the child uses instead of the default adapter."
  @type callbacks :: %{
          capture_fn: (binary() -> term()),
          paste_fn: (binary(), binary() -> term())
        }

  @typedoc "An execution refusal of this module's own, alongside Admission's refusals."
  @type execution_refusal ::
          {:fence_refused, Coordinator.admission_error()}
          | {:source_changed, Admission.role()}
          | {:quarantine_unavailable, term()}

  @type refusal :: Admission.refusal() | execution_refusal()

  @type pane_row :: %{
          pane_id: Admission.pane_id() | nil,
          status: :observed_quarantined | :refused,
          refusals: [refusal()],
          undischarged: [Admission.prerequisite()] | :unknown,
          dispatchable: false
        }

  @typedoc "A per-session marker finding, located by the exact session id."
  @type session_issue :: {:session_issue, :marker, Admission.text(), Admission.issue()}

  @type issue ::
          Admission.issue()
          | session_issue()
          | {:fence_update_failed, Admission.pane_id(), term()}

  @type marker_observation ::
          :unobserved
          | :not_applicable
          | {:observed, %{Admission.text() => Admission.marker_source()}}

  @type report :: %{
          root: binary(),
          panes: [pane_row()],
          issues: [issue()],
          marker_observation: marker_observation(),
          marker_writes: 0
        }

  @doc """
  Reconciles once.

  Options, all required and none other accepted:

    * `:store` - the `AiPair.PaneIntentStore` server to list intent from
    * `:root` - the daemon inbox root the report is about; an absolute path
    * `:tmux` - the `AiPair.Tmux` adapter to take the census and read markers through
    * `:binding` - the CONFIGURED project binding
      (`%{project, project_dir, project_inbox}`), never derived from a record
    * `:callbacks` - `%{capture_fn: fun/1, paste_fn: fun/2}` bound to a child
      started here; a missing callback is a caller defect and raises before any
      source is read, because a child started without one would route to the
      default adapter

  Steps: snapshot intent, census and one marker per census session; admit every
  recorded pane; for each admissible pane acquire its coordinator fence, re-read
  all three sources, re-admit, and start the quarantined child only on a fresh
  admissible decision that agrees with the snapshot; release. Returns the
  report described in the moduledoc. Never writes to any source.
  """
  @spec reconcile(keyword()) :: report()
  def reconcile(opts) when is_list(opts) do
    context = context!(opts)

    intent = intent_source(context.store)
    live = live_source(context.tmux)
    {markers, marker_observation, marker_issues} = markers(context, live)
    source_issues = source_issues(context.binding, intent, live)

    snapshot = %{intent: intent, live: live, markers: markers}

    {panes, pane_issues} =
      case intent do
        {:observed, rows} when is_list(rows) ->
          rows |> Enum.map(&entry(&1, snapshot, context)) |> Enum.unzip()

        _failed ->
          {[], []}
      end

    %{
      root: context.root,
      panes: panes,
      issues: Enum.uniq(source_issues ++ marker_issues ++ List.flatten(pane_issues)),
      marker_observation: marker_observation,
      marker_writes: 0
    }
  end

  # --- options --------------------------------------------------------------

  defp context!(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown reconcile options: #{inspect(unknown)}"
    end

    %{
      store: Keyword.fetch!(opts, :store),
      root: validated_root!(Keyword.fetch!(opts, :root)),
      tmux: Keyword.fetch!(opts, :tmux),
      binding: Keyword.fetch!(opts, :binding),
      callbacks: validated_callbacks!(Keyword.fetch!(opts, :callbacks))
    }
  end

  defp validated_root!(root) when is_binary(root) do
    if byte_size(root) > 0 and String.valid?(root) and Path.type(root) == :absolute do
      root
    else
      raise ArgumentError, "root must be an absolute path, got: #{inspect(root)}"
    end
  end

  defp validated_root!(root),
    do: raise(ArgumentError, "root must be an absolute path, got: #{inspect(root)}")

  defp validated_callbacks!(%{capture_fn: capture, paste_fn: paste} = callbacks)
       when map_size(callbacks) == 2 and is_function(capture, 1) and is_function(paste, 2),
       do: callbacks

  defp validated_callbacks!(other) do
    raise ArgumentError,
          "callbacks must be %{capture_fn: fun/1, paste_fn: fun/2}, got: #{inspect(other)}"
  end

  # --- snapshot -------------------------------------------------------------

  # Report-level findings about the intent and live sources themselves: an
  # unusable binding, a source that could not be read, and every pane recorded
  # or observed twice. Taken from one admission over the full sources so that a
  # duplicated live pane is reported even when no record names it and even when
  # intent is empty. The placeholder marker contributes nothing that survives
  # the filter: with an unusable marker Admission raises no located marker
  # finding, and marker-role findings are reported per session instead.
  defp source_issues(binding, intent, live) do
    Admission.admit(binding, intent, live, :unavailable).issues
    |> Enum.filter(&source_issue?/1)
  end

  defp source_issue?({:config_invalid, _field}), do: true
  defp source_issue?({:source_unavailable, role}), do: role != :marker
  defp source_issue?({:source_error, role, _reason}), do: role != :marker
  defp source_issue?({:duplicate, _role, _pane_id}), do: true
  defp source_issue?(_other), do: false

  # One marker per session the census enumerates, in census order. There is no
  # global marker query and no invented session: an unreadable census learns no
  # session id, so nothing is asked and the observation says so.
  defp markers(context, {:observed, rows}) when is_list(rows) do
    sessions = rows |> Enum.map(&observed_session/1) |> Enum.filter(&is_binary/1) |> Enum.uniq()
    markers = Map.new(sessions, &{&1, marker_source(context.tmux, &1)})

    issues =
      Enum.flat_map(sessions, fn session ->
        markers
        |> Map.fetch!(session)
        |> marker_findings(context.binding)
        |> Enum.map(&{:session_issue, :marker, session, &1})
      end)

    observation = if sessions == [], do: :not_applicable, else: {:observed, markers}
    {markers, observation, issues}
  end

  defp markers(_context, _unreadable), do: {%{}, :unobserved, []}

  defp observed_session(%{session_id: session}), do: session
  defp observed_session(_row), do: nil

  # Admission is the one classifier of a marker source; only its marker-role
  # findings are reported per session (its binding finding, if any, is a source
  # issue already reported once at the report level).
  defp marker_findings(marker, binding) do
    Admission.admit(binding, {:observed, []}, {:observed, []}, marker).issues
    |> Enum.filter(&marker_finding?/1)
  end

  defp marker_finding?({:marker_absent}), do: true
  defp marker_finding?({:marker_malformed, _raw}), do: true
  defp marker_finding?({:marker_foreign, _owner_root}), do: true
  defp marker_finding?({:source_unavailable, :marker}), do: true
  defp marker_finding?({:source_error, :marker, _reason}), do: true
  defp marker_finding?(_other), do: false

  # --- one row per intent row ---------------------------------------------

  defp entry(row, snapshot, context) do
    pane = row_pane_id(row)
    marker = pane_marker(pane, snapshot.live, snapshot.markers)
    assessment = Admission.admit(context.binding, snapshot.intent, snapshot.live, marker)
    issues = Enum.filter(assessment.issues, &pane_issue?(&1, pane))

    case decision_for(assessment, pane) do
      %{verdict: :admissible} = decision ->
        result =
          Coordinator.transaction(pane, fn ->
            {:ok, revalidate(row, marker, snapshot, decision, context)}
          end)

        {entry, execution_issues} = transaction_entry(result, decision)
        {entry, issues ++ execution_issues}

      %{verdict: :refused} = decision ->
        {refused(pane, decision.refusals, decision.undischarged), issues}

      nil ->
        # Admission names panes from intent alone, so a row it produced no
        # decision for is a row inside an intent source it found unusable; the
        # intent finding is the refusal, and nothing was discharged.
        {refused(pane, intent_findings(assessment), :unknown), issues}
    end
  end

  defp decision_for(assessment, pane), do: Enum.find(assessment.decisions, &(&1.pane_id == pane))

  # Every admission here runs over the full intent and live sources but with
  # ONE pane's session marker, so findings that depend on that marker are true
  # of that pane only. Located findings are kept when they name this pane;
  # marker-role findings are kept because they concern this pane's marker;
  # everything else about the sources is reported once at the report level.
  defp pane_issue?({:scope_mismatch, id, _field}, pane), do: id == pane
  defp pane_issue?({:live_absent, id}, pane), do: id == pane
  defp pane_issue?({:conflicting, _role, id}, pane), do: id == pane
  defp pane_issue?({:generation_mismatch, id}, pane), do: id == pane
  defp pane_issue?({:session_mismatch, id}, pane), do: id == pane
  defp pane_issue?(issue, _pane), do: marker_finding?(issue)

  defp intent_findings(assessment) do
    Enum.filter(assessment.issues, fn
      {:source_unavailable, :intent} -> true
      {:source_error, :intent, _reason} -> true
      _other -> false
    end)
  end

  defp transaction_entry({:ok, entry}, _decision), do: {entry, []}

  defp transaction_entry({:error, reason}, decision) do
    {refused(decision.pane_id, [{:fence_refused, reason}], decision.undischarged), []}
  end

  # The body result is kept, including an established quarantine: the fence
  # could not be released, which is an execution issue about the ledger, not an
  # Admission refusal and not evidence that the child was never started.
  defp transaction_entry({:fence_update_failed, {:ok, entry}, reason}, _decision) do
    {entry, [{:fence_update_failed, entry.pane_id, reason}]}
  end

  # --- inside the fence -----------------------------------------------------

  # Everything is read again under the fence and judged again. Any difference
  # between the snapshot and the fenced read of this pane's own intent row,
  # live observation or session marker refuses naming the changed source, so a
  # record withdrawn, a pane replaced or a marker rewritten between the two
  # reads is never re-registered from stale evidence.
  defp revalidate(row, snapshot_marker, snapshot, decision, context) do
    pane = decision.pane_id
    intent = intent_source(context.store)
    live = live_source(context.tmux)
    session = pane_session(pane, live)
    marker = if session, do: marker_source(context.tmux, session), else: :unavailable
    assessment = Admission.admit(context.binding, intent, live, marker)
    fresh = decision_for(assessment, pane)

    changes =
      changed(:intent, matching_intent(intent, pane), {:observed, [row]}) ++
        changed(:live, matching_live(live, pane), matching_live(snapshot.live, pane)) ++
        changed(:marker, marker, snapshot_marker)

    cond do
      changes != [] ->
        refusals = if fresh, do: fresh.refusals, else: intent_findings(assessment)
        refused(pane, Enum.uniq(changes ++ refusals), decision.undischarged)

      fresh == nil ->
        refused(pane, [{:source_changed, :intent} | intent_findings(assessment)], :unknown)

      fresh.verdict == :refused ->
        refused(pane, fresh.refusals, fresh.undischarged)

      true ->
        quarantine(fresh, context.callbacks)
    end
  end

  defp changed(_role, same, same), do: []
  defp changed(role, _fresh, _snapshot), do: [{:source_changed, role}]

  defp matching_intent({:observed, rows}, pane) when is_list(rows),
    do: {:observed, Enum.filter(rows, &(row_pane_id(&1) == pane))}

  defp matching_intent(source, _pane), do: source

  defp matching_live({:observed, rows}, pane) when is_list(rows),
    do: {:observed, Enum.filter(rows, &(observed_pane(&1) == pane))}

  defp matching_live(source, _pane), do: source

  # A pane observed exactly once names one session; observed twice it names
  # none, and Admission refuses it as a duplicate.
  defp pane_session(pane, live) do
    case matching_live(live, pane) do
      {:observed, [%{session_id: session}]} when is_binary(session) -> session
      _other -> nil
    end
  end

  defp pane_marker(pane, live, markers) do
    case pane_session(pane, live) do
      nil -> :unavailable
      session -> Map.fetch!(markers, session)
    end
  end

  # --- the quarantined start ----------------------------------------------

  # The request term is what `PaneSupervisor.start_pane/2` asks its
  # DynamicSupervisor: the same MFA, restart, shutdown and type, with the same
  # via name, so the child is the one every other caller would find. Only the
  # caller differs: the coordinator's owned worker makes the call, so the
  # effect is fenced and a late reply still discharges its own operation.
  defp quarantine(decision, %{capture_fn: capture_fn, paste_fn: paste_fn}) do
    pane = decision.pane_id

    opts = [
      pane_id: pane,
      name: PaneSupervisor.via_pane(pane),
      quarantine_token: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
      capture_fn: capture_fn,
      paste_fn: paste_fn
    ]

    spec =
      {{AiPair.Pane.StateMachine, :start_link, [opts]}, :transient, 5_000, :worker,
       [AiPair.Pane.StateMachine]}

    case Coordinator.submit(pane, PaneSupervisor, {:start_child, spec}, :infinity) do
      {:ok, {:ok, _pid}} -> observed(decision)
      {:ok, {:ok, _pid, _info}} -> observed(decision)
      {:ok, {:error, reason}} -> containment_refused(decision, reason)
      {:ok, :ignore} -> containment_refused(decision, :ignore)
      {:error, reason} -> containment_refused(decision, reason)
    end
  end

  defp observed(decision) do
    %{
      pane_id: decision.pane_id,
      status: :observed_quarantined,
      refusals: [],
      undischarged: decision.undischarged,
      dispatchable: false
    }
  end

  defp containment_refused(decision, reason),
    do: refused(decision.pane_id, [{:quarantine_unavailable, reason}], decision.undischarged)

  defp refused(pane, refusals, undischarged) do
    %{
      pane_id: pane,
      status: :refused,
      refusals: refusals,
      undischarged: undischarged,
      dispatchable: false
    }
  end

  # --- sources --------------------------------------------------------------

  # A call that does not come back is `:unavailable`, never an empty
  # observation: a store or adapter that never answered has observed nothing.
  defp intent_source(store) do
    case PaneIntentStore.list(store) do
      {:ok, rows} -> {:observed, rows}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp live_source(tmux) do
    case Tmux.observe_panes(tmux) do
      {:ok, rows} -> {:observed, rows}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> :unavailable
  end

  # The reader's findings map onto Admission's marker source one for one; a
  # malformed marker is observed as its raw value so Admission reports the raw.
  defp marker_source(tmux, session) do
    case Marker.read(tmux, session) do
      {:ok, marker} -> {:observed, marker}
      {:error, {:marker_absent}} -> {:observed, :absent}
      {:error, {:marker_malformed, raw}} -> {:observed, raw}
      {:error, {:source_unavailable, :marker}} -> :unavailable
      {:error, {:source_error, :marker, reason}} -> {:error, reason}
    end
  end

  defp row_pane_id(row) when is_map(row), do: Map.get(row, "pane_id")
  defp row_pane_id(_row), do: nil

  defp observed_pane(row) when is_map(row), do: Map.get(row, :pane_id)
  defp observed_pane(_row), do: nil
end
