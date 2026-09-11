defmodule AiPair.BootReconciliationTest do
  use ExUnit.Case, async: true

  @context %{project_dir: "/synthetic/project", project_inbox: "/synthetic/inbox"}
  @claims %{
    project_dir: {:supplied, "/synthetic/project"},
    project_inbox: {:supplied, "/synthetic/inbox"},
    tmux_session: {:supplied, "synthetic-session"},
    session_gen: {:supplied, "7"},
    agent: {:supplied, "synthetic-agent"},
    pane_pid: {:supplied, 123}
  }
  @sources [:intent, :live, :registered]
  @fields [:project_dir, :project_inbox, :tmux_session, :session_gen, :agent, :pane_pid]

  # These fixtures supply comparison claims, not trusted production observations.
  defp row(pane_id \\ "pane-1"), do: %{pane_id: pane_id, claims: @claims}
  defp observations(rows), do: {:observations, rows}
  defp matching_inputs, do: List.duplicate(observations([row()]), 3)

  defp assess(inputs, context \\ @context) do
    apply(AiPair.BootReconciliation, :assess, [context | inputs])
  end

  defp entry(pane_id, sources, outcome, reasons \\ []) do
    %{pane_id: pane_id, supplied_in: sources, outcome: outcome, reasons: reasons}
  end

  defp expected_report(entries, issues \\ []) do
    %{
      entries: entries,
      issues: issues,
      missing_prerequisites: [
        :producer_trust,
        :generation_binding,
        :process_agent_binding,
        :freshness_and_revalidation,
        :observation_completeness
      ]
    }
  end

  test "three supplied matching rows report conditional agreement and all missing prerequisites" do
    assert assess(matching_inputs()) == %{
             entries: [
               %{
                 pane_id: "pane-1",
                 supplied_in: [:intent, :live, :registered],
                 outcome: :conditional_agreement,
                 reasons: []
               }
             ],
             issues: [],
             missing_prerequisites: [
               :producer_trust,
               :generation_binding,
               :process_agent_binding,
               :freshness_and_revalidation,
               :observation_completeness
             ]
           }
  end

  test "empty supplied lists retain every prerequisite without an all-clear result" do
    assert assess(List.duplicate(observations([]), 3)) == expected_report([])
  end

  test "unknown sources are not empty observations" do
    assert assess([:unknown, :unknown, :unknown]) ==
             expected_report([], [
               {:source_unknown, :intent},
               {:source_unknown, :live},
               {:source_unknown, :registered}
             ])
  end

  for {source, index} <- Enum.with_index(@sources) do
    test "a missing #{source} record leaves the other supplied rows unknown" do
      inputs = List.replace_at(matching_inputs(), unquote(index), observations([]))

      assert assess(inputs) ==
               expected_report([
                 entry("pane-1", List.delete(@sources, unquote(source)), :unknown, [
                   {:missing_record, unquote(source)}
                 ])
               ])
    end

    test "an unknown #{source} source preserves its issue and missing-record reason" do
      inputs = List.replace_at(matching_inputs(), unquote(index), :unknown)

      assert assess(inputs) ==
               expected_report(
                 [
                   entry("pane-1", List.delete(@sources, unquote(source)), :unknown, [
                     {:missing_record, unquote(source)}
                   ])
                 ],
                 [{:source_unknown, unquote(source)}]
               )
    end

    test "an error from #{source} keeps its exact uncertain outcome and cleanup payload" do
      error = %{
        stage: :read,
        reason: {:owner_down, make_ref(), self()},
        outcome: :uncertain,
        cleanup_errors: [%{stage: :temporary_cleanup, reason: {:close, :eio}}]
      }

      inputs = List.replace_at(matching_inputs(), unquote(index), {:error, error})

      assert assess(inputs) ==
               expected_report(
                 [
                   entry("pane-1", List.delete(@sources, unquote(source)), :unknown, [
                     {:missing_record, unquote(source)}
                   ])
                 ],
                 [{:source_error, unquote(source), error}]
               )
    end

    for field <- @fields do
      test "unknown #{source} #{field} is never filled from another source" do
        incomplete = put_in(row(), [:claims, unquote(field)], :unknown)
        inputs = List.replace_at(matching_inputs(), unquote(index), observations([incomplete]))

        assert assess(inputs) ==
                 expected_report([
                   entry("pane-1", @sources, :unknown, [
                     {:unknown_field, unquote(source), unquote(field)}
                   ])
                 ])
      end

      test "an omitted #{source} #{field} key makes the entire source malformed" do
        incomplete = %{row() | claims: Map.delete(@claims, unquote(field))}
        inputs = List.replace_at(matching_inputs(), unquote(index), observations([incomplete]))

        assert assess(inputs) ==
                 expected_report(
                   [
                     entry("pane-1", List.delete(@sources, unquote(source)), :unknown, [
                       {:missing_record, unquote(source)}
                     ])
                   ],
                   [{:invalid_input, unquote(source)}]
                 )
      end

      test "unequal supplied #{source} #{field} claims retain the specific conflict" do
        changed = if unquote(field) == :pane_pid, do: 456, else: "different-claim"
        altered = put_in(row(), [:claims, unquote(field)], {:supplied, changed})
        inputs = List.replace_at(matching_inputs(), unquote(index), observations([altered]))

        context_reasons =
          if unquote(field) in [:project_dir, :project_inbox],
            do: [{:context_conflict, unquote(source), unquote(field)}],
            else: []

        assert assess(inputs) ==
                 expected_report([
                   entry("pane-1", @sources, :contradictory_supplied_evidence, [
                     {:conflict, unquote(field)} | context_reasons
                   ])
                 ])
      end
    end
  end

  test "matching scope claims still conflict with a different supplied context" do
    context = %{project_dir: "/other/project", project_inbox: "/other/inbox"}

    assert assess(matching_inputs(), context) ==
             expected_report([
               entry("pane-1", @sources, :contradictory_supplied_evidence, [
                 {:context_conflict, :intent, :project_dir},
                 {:context_conflict, :intent, :project_inbox},
                 {:context_conflict, :live, :project_dir},
                 {:context_conflict, :live, :project_inbox},
                 {:context_conflict, :registered, :project_dir},
                 {:context_conflict, :registered, :project_inbox}
               ])
             ])
  end

  test "unknown fields in all three sources keep source-first field ordering" do
    incomplete = %{
      pane_id: "pane-1",
      claims: %{
        project_dir: :unknown,
        project_inbox: :unknown,
        tmux_session: :unknown,
        session_gen: :unknown,
        agent: :unknown,
        pane_pid: :unknown
      }
    }

    assert assess(List.duplicate(observations([incomplete]), 3)) ==
             expected_report([
               entry("pane-1", @sources, :unknown, [
                 {:unknown_field, :intent, :project_dir},
                 {:unknown_field, :intent, :project_inbox},
                 {:unknown_field, :intent, :tmux_session},
                 {:unknown_field, :intent, :session_gen},
                 {:unknown_field, :intent, :agent},
                 {:unknown_field, :intent, :pane_pid},
                 {:unknown_field, :live, :project_dir},
                 {:unknown_field, :live, :project_inbox},
                 {:unknown_field, :live, :tmux_session},
                 {:unknown_field, :live, :session_gen},
                 {:unknown_field, :live, :agent},
                 {:unknown_field, :live, :pane_pid},
                 {:unknown_field, :registered, :project_dir},
                 {:unknown_field, :registered, :project_inbox},
                 {:unknown_field, :registered, :tmux_session},
                 {:unknown_field, :registered, :session_gen},
                 {:unknown_field, :registered, :agent},
                 {:unknown_field, :registered, :pane_pid}
               ])
             ])
  end

  test "conflicts coexist with missing records, unknown fields and source errors" do
    intent =
      row()
      |> put_in([:claims, :project_inbox], {:supplied, "/other/inbox"})
      |> put_in([:claims, :agent], :unknown)

    live =
      row()
      |> put_in([:claims, :project_dir], {:supplied, "/other/project"})
      |> put_in([:claims, :session_gen], {:supplied, "8"})
      |> put_in([:claims, :pane_pid], :unknown)

    assert assess([observations([intent]), observations([live]), {:error, :timeout}]) ==
             expected_report(
               [
                 entry("pane-1", [:intent, :live], :contradictory_supplied_evidence, [
                   {:missing_record, :registered},
                   {:unknown_field, :intent, :agent},
                   {:unknown_field, :live, :pane_pid},
                   {:conflict, :project_dir},
                   {:conflict, :project_inbox},
                   {:conflict, :session_gen},
                   {:context_conflict, :intent, :project_inbox},
                   {:context_conflict, :live, :project_dir}
                 ])
               ],
               [{:source_error, :registered, :timeout}]
             )
  end

  test "different pane coordinates produce missing counterparts, not an identity match" do
    assert assess([observations([row()]), observations([row("pane-2")]), observations([row()])]) ==
             expected_report([
               entry("pane-1", [:intent, :registered], :unknown, [{:missing_record, :live}]),
               entry("pane-2", [:live], :unknown, [
                 {:missing_record, :intent},
                 {:missing_record, :registered}
               ])
             ])
  end

  test "the union includes intent-only, live-only and registered-only observations in byte order" do
    assert assess([
             observations([row("pane-2")]),
             observations([row("pane-10")]),
             observations([row("pane-1")])
           ]) ==
             expected_report([
               entry("pane-1", [:registered], :unknown, [
                 {:missing_record, :intent},
                 {:missing_record, :live}
               ]),
               entry("pane-10", [:live], :unknown, [
                 {:missing_record, :intent},
                 {:missing_record, :registered}
               ]),
               entry("pane-2", [:intent], :unknown, [
                 {:missing_record, :live},
                 {:missing_record, :registered}
               ])
             ])
  end

  test "a live-only context contradiction retains its missing counterparts" do
    live = put_in(row(), [:claims, :project_dir], {:supplied, "/other/project"})

    assert assess([observations([]), observations([live]), observations([])]) ==
             expected_report([
               entry("pane-1", [:live], :contradictory_supplied_evidence, [
                 {:missing_record, :intent},
                 {:missing_record, :registered},
                 {:context_conflict, :live, :project_dir}
               ])
             ])
  end

  for {source, index} <- Enum.with_index(@sources) do
    test "duplicate #{source} rows discard that source's claims but retain all its pane keys" do
      conflicting = put_in(row("pane-2"), [:claims, :session_gen], {:supplied, "8"})
      unique = put_in(row(), [:claims, :agent], {:supplied, "other-agent"})
      duplicates = observations([row("pane-2"), conflicting, unique, row("pane-2")])
      inputs = List.replace_at(matching_inputs(), unquote(index), duplicates)
      missing = for s <- List.delete(@sources, unquote(source)), do: {:missing_record, s}

      assert assess(inputs) ==
               expected_report(
                 [
                   entry("pane-1", @sources, :unknown),
                   entry("pane-2", [unquote(source)], :unknown, missing)
                 ],
                 [{:duplicate, unquote(source), "pane-2"}]
               )
    end

    test "identical #{source} duplicates are not silently collapsed into agreement" do
      inputs =
        List.replace_at(matching_inputs(), unquote(index), observations([row(), row()]))

      assert assess(inputs) ==
               expected_report(
                 [entry("pane-1", @sources, :unknown)],
                 [{:duplicate, unquote(source), "pane-1"}]
               )
    end

    test "a malformed #{source} row discards otherwise valid rows and keys in that source" do
      bad = observations([row(), row("pane-2"), %{pane_id: "pane-3", claims: %{}}])
      inputs = List.replace_at(matching_inputs(), unquote(index), bad)

      assert assess(inputs) ==
               expected_report(
                 [
                   entry("pane-1", List.delete(@sources, unquote(source)), :unknown, [
                     {:missing_record, unquote(source)}
                   ])
                 ],
                 [{:invalid_input, unquote(source)}]
               )
    end
  end

  test "a duplicate-source issue suppresses agreement throughout only the current report" do
    duplicated = observations([row("pane-2"), row(), row("pane-2")])

    assert assess([duplicated, observations([row()]), observations([row()])]) ==
             expected_report(
               [
                 entry("pane-1", @sources, :unknown),
                 entry("pane-2", [:intent], :unknown, [
                   {:missing_record, :live},
                   {:missing_record, :registered}
                 ])
               ],
               [{:duplicate, :intent, "pane-2"}]
             )

    assert assess(matching_inputs()) ==
             expected_report([entry("pane-1", @sources, :conditional_agreement)])
  end

  test "a malformed source takes structural precedence over duplicates in the same source" do
    assert assess([observations([row(), row(), nil]), observations([]), observations([])]) ==
             expected_report([], [{:invalid_input, :intent}])
  end

  test "an invalid context suppresses agreement without suppressing supplied-claim conflicts" do
    live = put_in(row(), [:claims, :session_gen], {:supplied, "8"})

    assert assess([observations([row()]), observations([live]), observations([row()])], %{
             project_dir: "/other/project"
           }) ==
             expected_report(
               [
                 entry("pane-1", @sources, :contradictory_supplied_evidence, [
                   {:conflict, :session_gen}
                 ])
               ],
               [{:invalid_input, :context}]
             )
  end

  for {label, bad_context} <- [
        nil: nil,
        missing_directory: %{project_inbox: "/synthetic/inbox"},
        missing_inbox: %{project_dir: "/synthetic/project"},
        empty_directory: %{project_dir: "", project_inbox: "/synthetic/inbox"},
        invalid_utf8: %{project_dir: <<255>>, project_inbox: "/synthetic/inbox"},
        tagged_directory: %{
          project_dir: {:supplied, "/synthetic/project"},
          project_inbox: "/synthetic/inbox"
        },
        extra_key: Map.put(@context, :complete, true)
      ] do
    test "#{label} context is invalid and cannot supply partial context comparisons" do
      assert assess(matching_inputs(), unquote(Macro.escape(bad_context))) ==
               expected_report([entry("pane-1", @sources, :unknown)], [{:invalid_input, :context}])
    end
  end

  for {label, bad_input} <- [
        bare_ok: {:ok, []},
        bare_list: [],
        nil: nil,
        wrong_tag: {:complete, []},
        wrong_arity: {:observations, [], true},
        wrong_rows: {:observations, %{}},
        improper_rows: {:observations, [%{pane_id: "pane-1", claims: @claims} | :tail]},
        string_row_keys: {:observations, [%{"pane_id" => "pane-1", "claims" => @claims}]},
        missing_pane: {:observations, [%{claims: @claims}]},
        empty_pane: {:observations, [%{pane_id: "", claims: @claims}]},
        invalid_pane_utf8: {:observations, [%{pane_id: <<255>>, claims: @claims}]},
        extra_row_key: {:observations, [%{pane_id: "pane-1", claims: @claims, source: :registered}]}
      ] do
    test "#{label} input is malformed rather than complete or empty evidence" do
      assert assess([unquote(Macro.escape(bad_input)), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  for field <- [:project_dir, :project_inbox, :tmux_session, :session_gen, :agent],
      {label, value} <- [empty: "", invalid_utf8: <<255>>, integer: 7] do
    test "#{label} supplied #{field} is not a valid nonempty UTF-8 claim" do
      bad = put_in(row(), [:claims, unquote(field)], {:supplied, unquote(value)})

      assert assess([observations([bad]), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  for {label, value} <- [zero: 0, negative: -1, float: 1.0, string: "123", beam_pid: :beam_pid] do
    test "#{label} supplied pane PID is not a positive OS PID integer" do
      value = if unquote(value) == :beam_pid, do: self(), else: unquote(value)
      bad = put_in(row(), [:claims, :pane_pid], {:supplied, value})

      assert assess([observations([bad]), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  for {label, value} <- [nil: nil, bare_value: "synthetic-agent", wrong_tag: {:verified, "agent"}] do
    test "#{label} claim does not stand in for an explicit supplied or unknown value" do
      bad = put_in(row(), [:claims, :agent], unquote(Macro.escape(value)))

      assert assess([observations([bad]), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  for {flag, value} <- [complete: true, verified: true, rows_seen: 1, rows_parsed: 1] do
    test "#{flag} on claims cannot certify completeness or trust" do
      bad = %{row() | claims: Map.put(@claims, unquote(flag), unquote(value))}

      assert assess([observations([bad]), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end

    test "#{flag} on an observation envelope cannot certify completeness or trust" do
      bad = {:observations, Map.put(%{rows: [row()]}, unquote(flag), unquote(value))}

      assert assess([bad, observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  for hint <- [:project, :classifier, :cwd, :command, :updated_at] do
    test "#{hint} is outside the closed comparison claims rather than an equality requirement" do
      bad = %{row() | claims: Map.put(@claims, unquote(hint), "hint")}

      assert assess([observations([bad]), observations([]), observations([])]) ==
               expected_report([], [{:invalid_input, :intent}])
    end
  end

  test "binary comparison does not canonicalize paths or require numeric generation syntax" do
    context = %{project_dir: "synthetic/../project", project_inbox: "synthetic/inbox"}

    supplied = %{
      pane_id: "coordinate",
      claims: %{
        project_dir: {:supplied, "synthetic/../project"},
        project_inbox: {:supplied, "synthetic/inbox"},
        tmux_session: {:supplied, "session"},
        session_gen: {:supplied, "generation-label"},
        agent: {:supplied, "agent"},
        pane_pid: {:supplied, 1}
      }
    }

    assert assess(List.duplicate(observations([supplied]), 3), context) ==
             expected_report([entry("coordinate", @sources, :conditional_agreement)])
  end

  test "arbitrary error terms are opaque even when they resemble successful input or reports" do
    errors = [
      nil,
      false,
      <<255>>,
      [1 | :tail],
      observations([row()]),
      expected_report([entry("pane-1", @sources, :conditional_agreement)]),
      make_ref(),
      self(),
      fn -> raise "opaque error functions must not be invoked" end
    ]

    for error <- errors do
      assert assess([{:error, error}, observations([]), observations([])]) ===
               expected_report([], [{:source_error, :intent, error}])
    end
  end

  for error <- [1, 1.0, %{reason: {1, 1.0}, cleanup_errors: [1.0]}] do
    test "opaque numeric error #{inspect(error)} preserves exact term identity" do
      error = unquote(Macro.escape(error))

      assert assess([{:error, error}, observations([]), observations([])]) ===
               expected_report([], [{:source_error, :intent, error}])
    end
  end

  test "equal errors from different sources retain separate source attribution" do
    assert assess(List.duplicate({:error, :timeout}, 3)) ==
             expected_report([], [
               {:source_error, :intent, :timeout},
               {:source_error, :live, :timeout},
               {:source_error, :registered, :timeout}
             ])
  end

  test "issues sort by kind then slot then pane bytes without duplicate reasons" do
    duplicated =
      observations([row("pane-2"), row("pane-10"), row("pane-2"), row("pane-10"), row("pane-2")])

    assert assess([duplicated, :unknown, {:error, :timeout}], nil) ==
             expected_report(
               [
                 entry("pane-10", [:intent], :unknown, [
                   {:missing_record, :live},
                   {:missing_record, :registered}
                 ]),
                 entry("pane-2", [:intent], :unknown, [
                   {:missing_record, :live},
                   {:missing_record, :registered}
                 ])
               ],
               [
                 {:source_unknown, :live},
                 {:source_error, :registered, :timeout},
                 {:invalid_input, :context},
                 {:duplicate, :intent, "pane-10"},
                 {:duplicate, :intent, "pane-2"}
               ]
             )
  end

  test "invalid-input issues use context then source slot order" do
    assert assess([nil, nil, nil], nil) ==
             expected_report([], [
               {:invalid_input, :context},
               {:invalid_input, :intent},
               {:invalid_input, :live},
               {:invalid_input, :registered}
             ])
  end

  test "three unequal values produce one conflict per field in declared field order" do
    live = %{
      row()
      | claims: %{
          project_dir: {:supplied, "live-dir"},
          project_inbox: {:supplied, "live-inbox"},
          tmux_session: {:supplied, "live-session"},
          session_gen: {:supplied, "live-generation"},
          agent: {:supplied, "live-agent"},
          pane_pid: {:supplied, 456}
        }
    }

    registered = %{
      row()
      | claims: %{
          project_dir: {:supplied, "registered-dir"},
          project_inbox: {:supplied, "registered-inbox"},
          tmux_session: {:supplied, "registered-session"},
          session_gen: {:supplied, "registered-generation"},
          agent: {:supplied, "registered-agent"},
          pane_pid: {:supplied, 789}
        }
    }

    assert assess([observations([row()]), observations([live]), observations([registered])]) ==
             expected_report([
               entry("pane-1", @sources, :contradictory_supplied_evidence, [
                 {:conflict, :project_dir},
                 {:conflict, :project_inbox},
                 {:conflict, :tmux_session},
                 {:conflict, :session_gen},
                 {:conflict, :agent},
                 {:conflict, :pane_pid},
                 {:context_conflict, :live, :project_dir},
                 {:context_conflict, :live, :project_inbox},
                 {:context_conflict, :registered, :project_dir},
                 {:context_conflict, :registered, :project_inbox}
               ])
             ])
  end

  test "row permutations in each source preserve the exact sorted report" do
    expected =
      expected_report([
        entry("pane-1", @sources, :conditional_agreement),
        entry("pane-10", @sources, :conditional_agreement),
        entry("pane-2", @sources, :conditional_agreement)
      ])

    orders = [
      [row("pane-1"), row("pane-10"), row("pane-2")],
      [row("pane-1"), row("pane-2"), row("pane-10")],
      [row("pane-10"), row("pane-1"), row("pane-2")],
      [row("pane-10"), row("pane-2"), row("pane-1")],
      [row("pane-2"), row("pane-1"), row("pane-10")],
      [row("pane-2"), row("pane-10"), row("pane-1")]
    ]

    for intent <- orders, live <- orders, registered <- orders do
      assert assess([observations(intent), observations(live), observations(registered)]) ==
               expected
    end
  end

  test "reordering conflicting duplicate rows cannot choose a first or last winner" do
    changed = put_in(row(), [:claims, :agent], {:supplied, "other-agent"})

    expected =
      expected_report([entry("pane-1", @sources, :unknown)], [{:duplicate, :intent, "pane-1"}])

    for rows <- [[row(), changed], [changed, row()]] do
      assert assess([observations(rows), observations([row()]), observations([row()])]) == expected
    end
  end
end
