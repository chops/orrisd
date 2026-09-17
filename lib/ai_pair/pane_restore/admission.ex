defmodule AiPair.PaneRestore.Admission do
  @moduledoc """
  Decides which recorded pane intents a restore may consider, and reports every
  reason it may not.

  Admission never repairs, rewrites or invents evidence. It reads three
  independently produced observations - recorded intent, a live pane census and
  the session-local ownership marker - and reports, per pane, whether they agree
  well enough for a restore to be *considered*. An admissible decision is not
  permission to act: the prerequisites listed in `undischarged` are still owed by
  the caller, and this module never discharges them.

  ## Observation vocabulary

  Each source arrives as a report about an attempt to observe, never as bare
  data:

      {:observed, value}   the query completed, and this is what it found
      :unavailable         the query could not be made at all
      {:error, term}       the query was made and failed; the term is kept verbatim

  A completed observation that found nothing is `{:observed, []}` for the two
  list sources and `{:observed, :absent}` for the marker, which is singular.
  Three conflations are therefore refused outright, because each destroys a
  distinction an operator needs in order to act:

    * Observed absence is never encoded as unavailability. `{:observed, :absent}`
      yields `{:marker_absent}` - there is no marker - while `:unavailable`
      yields `{:source_unavailable, :marker}` - we do not know whether there is
      one.
    * The singular marker is never encoded as a singleton list. `{:observed,
      [marker]}` is the generic list shape leaking into a slot that never
      carries one, so it is `{:marker_malformed, term}` and not a marker.
    * A failure is never collapsed into an empty observation. A clean empty
      report and a failed source are different reports, distinguishable by
      `issues` alone.

  ## Malformed input

  A row with unexpected keys, a missing key or a wrongly typed value is a defect
  in its producer. Such a row is never dropped and never partially used: it
  invalidates its whole source, reported as `{:source_error, role,
  :malformed_row}`. A source that is not one of the four documented shapes at
  all is `{:source_error, role, :malformed_source}`.

  Because intent alone supplies the pane set, an unusable intent source yields
  no decisions. An unusable live or marker source still yields one refused
  decision per recorded pane, so a failure is never mistaken for "nothing to do".

  ## Issues and refusals

  Both lists carry the same findings from two vantage points. `issues` is the
  report-level view and locates each finding, so pane-level findings carry the
  pane id. `refusals` sits inside an already-located decision and therefore
  drops it. Findings that are not pane-specific - an invalid binding, a source
  failure, an unusable marker - appear identically in both, and are reported
  once at the report level rather than repeated per pane.
  """

  @prerequisites [
    :producer_trust,
    :process_agent_binding,
    :freshness_and_revalidation,
    :observation_completeness
  ]

  @schema_version "1.0"

  @intent_keys ~w(
    schema_version pane_id agent classifier project project_dir project_inbox
    tmux_session session_gen cwd command pane_pid updated_at
  )
  @intent_text_keys @intent_keys -- ["pane_pid"]

  @live_keys [
    :pane_id,
    :session_id,
    :session_name,
    :window_index,
    :pane_index,
    :pane_pid,
    :command,
    :path
  ]
  @live_text_keys [:pane_id, :session_id, :session_name, :command, :path]
  @live_index_keys [:window_index, :pane_index]

  @marker_keys [:version, :owner_root, :session_id, :generation]
  @marker_text_keys [:owner_root, :session_id, :generation]

  # Scope is bound on all three fields: a record can name the right project
  # while pointing at another checkout or another inbox.
  @scope_comparisons [
    {"project", :project},
    {"project_dir", :project_dir},
    {"project_inbox", :project_inbox}
  ]

  # Facts a live pane and its recorded intent both describe independently.
  @live_comparisons [
    {"pane_pid", :pane_pid},
    {"command", :command},
    {"cwd", :path},
    {"tmux_session", :session_name}
  ]

  @typedoc "A nonempty UTF-8 binary, compared exactly and without normalization."
  @type text :: binary()
  @type pane_id :: text()
  @type role :: :intent | :live | :marker
  @type config_field :: :binding | :project | :project_dir | :project_inbox

  @type binding :: %{project: text(), project_dir: text(), project_inbox: text()}
  @type intent_row :: %{optional(text()) => term()}
  @type live_observation :: %{optional(atom()) => term()}
  @type marker :: %{version: 1, owner_root: text(), session_id: text(), generation: text()}

  @type intent_source :: {:observed, [intent_row()]} | :unavailable | {:error, term()}
  @type live_source :: {:observed, [live_observation()]} | :unavailable | {:error, term()}
  @type marker_source ::
          {:observed, marker()} | {:observed, :absent} | :unavailable | {:error, term()}

  @typedoc "A finding as reported at the report level, locating the pane it concerns."
  @type issue ::
          {:config_invalid, config_field()}
          | {:source_unavailable, role()}
          | {:source_error, role(), term()}
          | {:duplicate, role(), pane_id()}
          | {:scope_mismatch, pane_id(), text()}
          | {:live_absent, pane_id()}
          | {:conflicting, :live, pane_id()}
          | {:marker_absent}
          | {:marker_malformed, term()}
          | {:marker_foreign, text()}
          | {:generation_mismatch, pane_id()}
          | {:session_mismatch, pane_id()}

  @typedoc "The same finding inside an already-located decision, without the pane id."
  @type refusal ::
          {:config_invalid, config_field()}
          | {:source_unavailable, role()}
          | {:source_error, role(), term()}
          | {:duplicate, role()}
          | {:scope_mismatch, text()}
          | {:live_absent}
          | {:conflicting, :live}
          | {:marker_absent}
          | {:marker_malformed, term()}
          | {:marker_foreign, text()}
          | {:generation_mismatch}
          | {:session_mismatch}

  @type prerequisite ::
          :producer_trust
          | :process_agent_binding
          | :freshness_and_revalidation
          | :observation_completeness

  @type decision :: %{
          pane_id: pane_id(),
          verdict: :admissible | :refused,
          refusals: [refusal()],
          undischarged: [prerequisite()]
        }

  @type report :: %{issues: [issue()], decisions: [decision()]}

  @doc """
  Assesses recorded intent against a live census and the session-local marker.

  Returns one decision per pane named by intent, in the order intent named them,
  plus every issue found. A pane is admissible only when nothing is wrong with
  it: the configured binding is usable, no source failed, the pane is recorded
  once and observed once, its scope matches the binding, its live observation
  agrees with the record, and the marker is present, locally owned, of the
  record's generation and of the observed session.

  Admissibility is conditional on the supplied evidence only. It certifies
  neither the producer of that evidence, nor its freshness, nor the completeness
  of the observations, nor the binding between a process and the agent it claims
  to be: those remain in `undischarged` on every decision, including admissible
  ones.
  """
  @spec admit(binding(), intent_source(), live_source(), marker_source()) :: report()
  def admit(binding, intent_source, live_source, marker_source) do
    config = validate_binding(binding)
    intent = normalize_source(:intent, intent_source)
    live = normalize_source(:live, live_source)
    marker = normalize_marker(marker_source, binding, config == [])

    context = %{config: config, binding: binding, intent: intent, live: live, marker: marker}

    {decisions, pane_issues} =
      intent.panes
      |> Enum.map(&decide(&1, context))
      |> Enum.unzip()

    %{
      issues: config ++ intent.issues ++ live.issues ++ marker.issues ++ List.flatten(pane_issues),
      decisions: decisions
    }
  end

  # --- configured binding -------------------------------------------------

  defp validate_binding(%{project: project, project_dir: dir, project_inbox: inbox} = binding)
       when map_size(binding) == 3 do
    checks = [
      {:project, valid_text?(project)},
      {:project_dir, absolute_path?(dir)},
      {:project_inbox, absolute_path?(inbox)}
    ]

    for {field, false} <- checks, do: {:config_invalid, field}
  end

  defp validate_binding(_binding), do: [{:config_invalid, :binding}]

  # --- list sources -------------------------------------------------------

  defp normalize_source(role, {:observed, rows}) when is_list(rows) do
    if valid_rows?(role, rows) do
      observed_source(role, rows)
    else
      failed_source({:source_error, role, :malformed_row})
    end
  end

  defp normalize_source(role, :unavailable), do: failed_source({:source_unavailable, role})
  defp normalize_source(role, {:error, reason}), do: failed_source({:source_error, role, reason})
  defp normalize_source(role, _other), do: failed_source({:source_error, role, :malformed_source})

  defp observed_source(role, rows) do
    groups = Enum.group_by(rows, &pane_id(role, &1))
    duplicates = for {pane_id, [_, _ | _]} <- groups, into: MapSet.new(), do: pane_id

    %{
      status: :observed,
      failure: nil,
      panes: rows |> Enum.map(&pane_id(role, &1)) |> Enum.uniq(),
      # A pane recorded twice in one source supplies no single value, so it is
      # withheld here rather than resolved by picking one of the two.
      by_pane: for({pane_id, [row]} <- groups, into: %{}, do: {pane_id, row}),
      duplicates: duplicates,
      issues: duplicates |> Enum.sort() |> Enum.map(&{:duplicate, role, &1})
    }
  end

  defp failed_source(failure) do
    %{
      status: :failed,
      failure: failure,
      panes: [],
      by_pane: %{},
      duplicates: MapSet.new(),
      issues: [failure]
    }
  end

  defp pane_id(:intent, row), do: Map.fetch!(row, "pane_id")
  defp pane_id(:live, observation), do: Map.fetch!(observation, :pane_id)

  # Recursive rather than `Enum.all?/2` so an improper list is rejected as
  # malformed instead of raising.
  defp valid_rows?(_role, []), do: true
  defp valid_rows?(role, [row | rest]), do: valid_row?(role, row) and valid_rows?(role, rest)
  defp valid_rows?(_role, _improper), do: false

  defp valid_row?(:intent, row) do
    exact_keys?(row, @intent_keys) and
      Map.fetch!(row, "schema_version") === @schema_version and
      Enum.all?(@intent_text_keys, &valid_text?(Map.fetch!(row, &1))) and
      pid?(Map.fetch!(row, "pane_pid"))
  end

  defp valid_row?(:live, observation) do
    exact_keys?(observation, @live_keys) and
      Enum.all?(@live_text_keys, &valid_text?(Map.fetch!(observation, &1))) and
      Enum.all?(@live_index_keys, &index?(Map.fetch!(observation, &1))) and
      pid?(Map.fetch!(observation, :pane_pid))
  end

  # --- marker -------------------------------------------------------------

  defp normalize_marker(source, binding, config_usable?) do
    case classify_marker(source) do
      {:ok, marker} -> adopt_marker(marker, binding, config_usable?)
      {:unusable, failure} -> unusable_marker(failure)
    end
  end

  defp classify_marker({:observed, :absent}), do: {:unusable, {:marker_absent}}

  defp classify_marker({:observed, marker}) when is_map(marker) do
    if valid_marker?(marker) do
      {:ok, marker}
    else
      {:unusable, {:marker_malformed, marker}}
    end
  end

  # Anything else in the observed slot - a list wrapping the singular marker
  # included - is malformed input, never an absent or a partial marker.
  defp classify_marker({:observed, other}), do: {:unusable, {:marker_malformed, other}}
  defp classify_marker(:unavailable), do: {:unusable, {:source_unavailable, :marker}}
  defp classify_marker({:error, reason}), do: {:unusable, {:source_error, :marker, reason}}
  defp classify_marker(_other), do: {:unusable, {:source_error, :marker, :malformed_source}}

  defp valid_marker?(marker) do
    exact_keys?(marker, @marker_keys) and
      Map.fetch!(marker, :version) === 1 and
      Enum.all?(@marker_text_keys, &valid_text?(Map.fetch!(marker, &1)))
  end

  defp adopt_marker(marker, binding, true) do
    owner_root = Map.fetch!(marker, :owner_root)

    if owner_root === Map.fetch!(binding, :project_inbox) do
      %{status: :usable, marker: marker, failure: nil, issues: []}
    else
      unusable_marker({:marker_foreign, owner_root})
    end
  end

  # With an unusable binding there is no trustworthy inbox to compare against,
  # so ownership is left unjudged rather than guessed. The configuration issue
  # already refuses every decision in this report.
  defp adopt_marker(marker, _binding, false) do
    %{status: :usable, marker: marker, failure: nil, issues: []}
  end

  defp unusable_marker(failure) do
    %{status: :unusable, marker: nil, failure: failure, issues: [failure]}
  end

  # --- decisions ----------------------------------------------------------

  defp decide(pane_id, context) do
    refusals = refusals(pane_id, context)

    decision = %{
      pane_id: pane_id,
      verdict: verdict(refusals),
      refusals: refusals,
      undischarged: @prerequisites
    }

    {decision, pane_issues(pane_id, refusals)}
  end

  defp verdict([]), do: :admissible
  defp verdict([_ | _]), do: :refused

  # An unusable binding is not a fact about any pane: nothing further can be
  # checked against it, so no other finding is manufactured from it.
  defp refusals(_pane_id, %{config: [_ | _] = config_issues}), do: config_issues

  defp refusals(pane_id, context) do
    intent_refusals(pane_id, context) ++
      live_refusals(pane_id, context) ++
      marker_refusals(pane_id, context)
  end

  defp intent_refusals(pane_id, context) do
    if MapSet.member?(context.intent.duplicates, pane_id) do
      [{:duplicate, :intent}]
    else
      scope_refusals(Map.fetch!(context.intent.by_pane, pane_id), context.binding)
    end
  end

  defp scope_refusals(record, binding) do
    for {record_key, binding_key} <- @scope_comparisons,
        Map.fetch!(record, record_key) !== Map.fetch!(binding, binding_key),
        do: {:scope_mismatch, record_key}
  end

  defp live_refusals(_pane_id, %{live: %{status: :failed, failure: failure}}), do: [failure]

  defp live_refusals(pane_id, context) do
    cond do
      MapSet.member?(context.live.duplicates, pane_id) -> [{:duplicate, :live}]
      not Map.has_key?(context.live.by_pane, pane_id) -> [{:live_absent}]
      true -> conflict_refusals(pane_id, context)
    end
  end

  defp conflict_refusals(pane_id, context) do
    observation = Map.fetch!(context.live.by_pane, pane_id)

    # A pane recorded twice supplies no single value to compare against, and is
    # already refused for that.
    case Map.fetch(context.intent.by_pane, pane_id) do
      {:ok, record} -> conflict_refusal(record, observation)
      :error -> []
    end
  end

  defp conflict_refusal(record, observation) do
    conflicting? =
      Enum.any?(@live_comparisons, fn {record_key, observation_key} ->
        Map.fetch!(record, record_key) !== Map.fetch!(observation, observation_key)
      end)

    if conflicting?, do: [{:conflicting, :live}], else: []
  end

  defp marker_refusals(_pane_id, %{marker: %{status: :unusable, failure: failure}}), do: [failure]

  defp marker_refusals(pane_id, context) do
    marker = context.marker.marker

    generation_refusals(pane_id, context, marker) ++ session_refusals(pane_id, context, marker)
  end

  defp generation_refusals(pane_id, context, marker) do
    case Map.fetch(context.intent.by_pane, pane_id) do
      {:ok, record} ->
        mismatch(
          Map.fetch!(record, "session_gen"),
          Map.fetch!(marker, :generation),
          {:generation_mismatch}
        )

      :error ->
        []
    end
  end

  # Session identity is the tmux session id, never the session name: a name can
  # be reused by a later server while naming a different session.
  defp session_refusals(pane_id, context, marker) do
    case Map.fetch(context.live.by_pane, pane_id) do
      {:ok, observation} ->
        mismatch(
          Map.fetch!(observation, :session_id),
          Map.fetch!(marker, :session_id),
          {:session_mismatch}
        )

      :error ->
        []
    end
  end

  defp mismatch(observed, expected, refusal) do
    if observed === expected, do: [], else: [refusal]
  end

  # --- projections --------------------------------------------------------

  defp pane_issues(pane_id, refusals) do
    refusals
    |> Enum.map(&pane_issue(pane_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp pane_issue(pane_id, {:scope_mismatch, field}), do: {:scope_mismatch, pane_id, field}
  defp pane_issue(pane_id, {:conflicting, role}), do: {:conflicting, role, pane_id}
  defp pane_issue(pane_id, {:live_absent}), do: {:live_absent, pane_id}
  defp pane_issue(pane_id, {:generation_mismatch}), do: {:generation_mismatch, pane_id}
  defp pane_issue(pane_id, {:session_mismatch}), do: {:session_mismatch, pane_id}

  # Already reported once, with the pane id, by the source that found it.
  defp pane_issue(_pane_id, {:duplicate, _role}), do: nil

  # Not pane-specific: reported once at the report level.
  defp pane_issue(_pane_id, {:config_invalid, _field}), do: nil
  defp pane_issue(_pane_id, {:source_unavailable, _role}), do: nil
  defp pane_issue(_pane_id, {:source_error, _role, _reason}), do: nil
  defp pane_issue(_pane_id, {:marker_absent}), do: nil
  defp pane_issue(_pane_id, {:marker_malformed, _term}), do: nil
  defp pane_issue(_pane_id, {:marker_foreign, _root}), do: nil

  # --- value predicates ---------------------------------------------------

  defp exact_keys?(value, keys) when is_map(value) do
    map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp exact_keys?(_value, _keys), do: false

  defp valid_text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp absolute_path?(value), do: valid_text?(value) and Path.type(value) == :absolute

  defp pid?(value), do: is_integer(value) and value > 0

  defp index?(value), do: is_integer(value) and value >= 0
end
