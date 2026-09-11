defmodule AiPair.BootReconciliation do
  @moduledoc """
  Compares supplied reconciliation claims without observing or changing a system.

  Agreement is conditional on the supplied evidence, not authenticated identity,
  freshness, completeness or permission to act. Every report retains the missing
  prerequisites, including reports with no entries or agreements. Missing records
  remain unknown. Invalid source shapes discard that source's entire observation.
  """

  @sources [:intent, :live, :registered]
  @slots [:context | @sources]
  @scope_fields [:project_dir, :project_inbox]
  @fields [:project_dir, :project_inbox, :tmux_session, :session_gen, :agent, :pane_pid]
  @prerequisites [
    :producer_trust,
    :generation_binding,
    :process_agent_binding,
    :freshness_and_revalidation,
    :observation_completeness
  ]

  @typedoc "A nonempty UTF-8 binary, compared without normalization."
  @type text_value :: binary()
  @type source :: :intent | :live | :registered
  @type slot :: :context | source()
  @type field :: :project_dir | :project_inbox | :tmux_session | :session_gen | :agent | :pane_pid
  @type claim(value) :: {:supplied, value} | :unknown
  @type context :: %{project_dir: text_value(), project_inbox: text_value()}
  @type claims :: %{
          project_dir: claim(text_value()),
          project_inbox: claim(text_value()),
          tmux_session: claim(text_value()),
          session_gen: claim(text_value()),
          agent: claim(text_value()),
          pane_pid: claim(pos_integer())
        }
  @type row :: %{pane_id: text_value(), claims: claims()}
  @type input :: {:observations, [row()]} | :unknown | {:error, term()}
  @type issue ::
          {:source_unknown, source()}
          | {:source_error, source(), term()}
          | {:invalid_input, slot()}
          | {:duplicate, source(), text_value()}
  @type reason ::
          {:missing_record, source()}
          | {:unknown_field, source(), field()}
          | {:conflict, field()}
          | {:context_conflict, source(), field()}
  @type outcome :: :unknown | :contradictory_supplied_evidence | :conditional_agreement
  @type entry :: %{
          pane_id: text_value(),
          supplied_in: [source()],
          outcome: outcome(),
          reasons: [reason()]
        }
  @type prerequisite ::
          :producer_trust
          | :generation_binding
          | :process_agent_binding
          | :freshness_and_revalidation
          | :observation_completeness
  @type report :: %{
          entries: [entry()],
          issues: [issue()],
          missing_prerequisites: [prerequisite()]
        }

  @doc """
  Assesses intent, live and registered evidence in fixed argument roles.

  Maps must have exactly the documented keys; lists must be proper. Malformed
  terms yield invalid-input issues. Error payloads are returned unchanged and are
  never interpreted. Any issue suppresses agreement throughout this report only;
  known contradictions still retain their accompanying unknown facts.
  """
  @spec assess(context(), input(), input(), input()) :: report()
  def assess(context, intent, live, registered) do
    valid_context = valid_context?(context)

    normalized =
      @sources
      |> Enum.zip([intent, live, registered])
      |> Enum.map(fn {source, input} -> normalize(source, input) end)

    context_issues = if valid_context, do: [], else: [{:invalid_input, :context}]

    issues =
      (context_issues ++ Enum.flat_map(normalized, & &1.issues))
      |> Enum.sort_by(&issue_order/1)

    pane_ids = normalized |> Enum.flat_map(&MapSet.to_list(&1.keys)) |> Enum.uniq() |> Enum.sort()

    %{
      entries:
        Enum.map(pane_ids, fn pane_id ->
          assess_pane(pane_id, normalized, context, valid_context, issues != [])
        end),
      issues: issues,
      missing_prerequisites: @prerequisites
    }
  end

  defp valid_context?(context) do
    exact_keys?(context, @scope_fields) and
      Enum.all?(@scope_fields, &valid_text?(Map.fetch!(context, &1)))
  end

  defp valid_rows?([]), do: true
  defp valid_rows?([row | rest]), do: valid_row?(row) and valid_rows?(rest)
  defp valid_rows?(_other), do: false

  defp valid_row?(row) do
    exact_keys?(row, [:pane_id, :claims]) and valid_text?(row.pane_id) and
      exact_keys?(row.claims, @fields) and
      Enum.all?(@fields, &valid_claim?(&1, Map.fetch!(row.claims, &1)))
  end

  defp valid_claim?(_field, :unknown), do: true
  defp valid_claim?(:pane_pid, {:supplied, value}), do: is_integer(value) and value > 0
  defp valid_claim?(_field, {:supplied, value}), do: valid_text?(value)
  defp valid_claim?(_field, _other), do: false

  defp valid_text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp exact_keys?(value, keys) when is_map(value) do
    map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp exact_keys?(_value, _keys), do: false

  defp normalize(source, :unknown), do: empty_source(source, {:source_unknown, source})

  defp normalize(source, {:error, error}) do
    empty_source(source, {:source_error, source, error})
  end

  defp normalize(source, {:observations, rows}) do
    if valid_rows?(rows) do
      normalize_rows(source, rows)
    else
      empty_source(source, {:invalid_input, source})
    end
  end

  defp normalize(source, _other), do: empty_source(source, {:invalid_input, source})

  defp empty_source(source, issue) do
    %{source: source, keys: MapSet.new(), claims: %{}, issues: [issue]}
  end

  defp normalize_rows(source, rows) do
    groups = Enum.group_by(rows, & &1.pane_id)

    duplicates =
      groups
      |> Enum.filter(fn {_pane_id, entries} -> length(entries) > 1 end)
      |> Enum.map(fn {pane_id, _entries} -> pane_id end)
      |> Enum.sort()

    # A duplicate invalidates all claims from this source, not just that pane.
    claims = if duplicates == [], do: Map.new(rows, &{&1.pane_id, &1.claims}), else: %{}

    %{
      source: source,
      keys: MapSet.new(Map.keys(groups)),
      claims: claims,
      issues: Enum.map(duplicates, &{:duplicate, source, &1})
    }
  end

  defp issue_order({:source_unknown, source}), do: {0, slot_order(source), ""}
  defp issue_order({:source_error, source, _error}), do: {1, slot_order(source), ""}
  defp issue_order({:invalid_input, slot}), do: {2, slot_order(slot), ""}
  defp issue_order({:duplicate, source, pane_id}), do: {3, slot_order(source), pane_id}
  defp slot_order(slot), do: Enum.find_index(@slots, &(&1 == slot))

  defp assess_pane(pane_id, sources, context, valid_context, issues?) do
    supplied_in = for s <- sources, MapSet.member?(s.keys, pane_id), do: s.source

    available =
      for s <- sources,
          {:ok, claims} <- [Map.fetch(s.claims, pane_id)],
          do: {s.source, claims}

    missing = for source <- @sources, source not in supplied_in, do: {:missing_record, source}

    unknown =
      for {source, claims} <- available,
          field <- @fields,
          Map.fetch!(claims, field) == :unknown,
          do: {:unknown_field, source, field}

    conflicts =
      for field <- @fields,
          conflicting?(available, field),
          do: {:conflict, field}

    context_conflicts = context_conflicts(available, context, valid_context)

    outcome =
      cond do
        conflicts != [] or context_conflicts != [] -> :contradictory_supplied_evidence
        issues? or missing != [] or unknown != [] -> :unknown
        true -> :conditional_agreement
      end

    %{
      pane_id: pane_id,
      supplied_in: supplied_in,
      outcome: outcome,
      reasons: missing ++ unknown ++ conflicts ++ context_conflicts
    }
  end

  defp conflicting?(available, field) do
    values =
      for {_source, claims} <- available,
          {:supplied, value} <- [Map.fetch!(claims, field)],
          do: value

    length(Enum.uniq(values)) > 1
  end

  defp context_conflicts(_available, _context, false), do: []

  defp context_conflicts(available, context, true) do
    for {source, claims} <- available,
        field <- @scope_fields,
        {:supplied, value} <- [Map.fetch!(claims, field)],
        value !== Map.fetch!(context, field),
        do: {:context_conflict, source, field}
  end
end
