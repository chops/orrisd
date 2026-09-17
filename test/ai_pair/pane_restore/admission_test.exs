defmodule AiPair.PaneRestore.AdmissionTest do
  # Wiring scope r7 (f4521e29), section C5 and the C1 prerequisite rule; the
  # source-report vocabulary is the ruling-fixed one described below. Ported
  # from the reviewed lane ff8650e as R04 slice S1 (pure decision layer only).
  #
  # Fixtures are synthetic on purpose: no real project, no home path, and pane
  # ids use the `pane-N` form rather than a tmux `%<digits>` coordinate, so this
  # file buys no redaction-scanner exemption.
  use ExUnit.Case, async: true

  alias AiPair.PaneRestore.Admission

  @binding %{
    project: "synthetic-project",
    project_dir: "/synthetic/project",
    project_inbox: "/synthetic/inbox"
  }

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "pane_id" => "pane-1",
        "agent" => "synthetic-agent",
        "classifier" => "stub",
        "project" => "synthetic-project",
        "project_dir" => "/synthetic/project",
        "project_inbox" => "/synthetic/inbox",
        "tmux_session" => "synthetic-session",
        "session_gen" => "7",
        "cwd" => "/synthetic/project",
        "command" => "synthetic-command",
        "pane_pid" => 123,
        "updated_at" => "2026-09-11T00:00:00Z"
      },
      overrides
    )
  end

  defp live(overrides \\ %{}) do
    Map.merge(
      %{
        pane_id: "pane-1",
        session_id: "$1",
        session_name: "synthetic-session",
        window_index: 0,
        pane_index: 0,
        pane_pid: 123,
        command: "synthetic-command",
        path: "/synthetic/project"
      },
      overrides
    )
  end

  defp marker(overrides \\ %{}) do
    Map.merge(
      %{
        version: 1,
        owner_root: "/synthetic/inbox",
        session_id: "$1",
        generation: "7"
      },
      overrides
    )
  end

  # Source-report vocabulary (ruling-fixed). The generic `{:observed, [t]}` shape
  # is amended ONLY for the marker, which is singular:
  #
  #   intent_source :: {:observed, [intent_row]} | :unavailable | {:error, term}
  #   live_source   :: {:observed, [live_obs]}   | :unavailable | {:error, term}
  #   marker_source :: {:observed, marker} | {:observed, :absent}
  #                    | :unavailable | {:error, term}
  #
  # A COMPLETED observation that found nothing is `{:observed, :absent}` for the
  # marker and `{:observed, []}` for the list sources. `:unavailable` means the
  # query could not be made at all. These are never interchangeable.
  defp completed_source(:intent), do: {:observed, [row()]}
  defp completed_source(:live), do: {:observed, [live()]}
  defp completed_source(:marker), do: {:observed, marker()}

  defp failure_source(:intent, :unavailable), do: :unavailable
  defp failure_source(:intent, :error), do: {:error, :intent_read_failed}
  defp failure_source(:intent, :malformed), do: {:observed, [Map.put(row(), "surprise", true)]}
  defp failure_source(:live, :unavailable), do: :unavailable
  defp failure_source(:live, :error), do: {:error, :census_failed}
  defp failure_source(:live, :malformed), do: {:observed, [Map.put(live(), :surprise, true)]}
  defp failure_source(:marker, :unavailable), do: :unavailable
  defp failure_source(:marker, :error), do: {:error, :marker_read_failed}
  defp failure_source(:marker, :malformed), do: {:observed, %{version: 1}}

  # Swap exactly one source slot; every other slot stays at a completed,
  # well-formed observation so any difference is attributable to that slot.
  defp admit_with(role, source) do
    {intent, live_source, marker_source} =
      case role do
        :intent -> {source, completed_source(:live), completed_source(:marker)}
        :live -> {completed_source(:intent), source, completed_source(:marker)}
        :marker -> {completed_source(:intent), completed_source(:live), source}
      end

    Admission.admit(@binding, intent, live_source, marker_source)
  end

  # An issue is "attributed to" a role when the role is recoverable from the
  # issue itself. The marker's singular vocabulary carries the role in the tag
  # rather than in a slot, which is exactly why it needs its own clauses.
  defp attributed?(issues, role) do
    Enum.any?(issues, fn
      {:source_unavailable, ^role} -> true
      {:source_error, ^role, _} -> true
      {:marker_absent} -> role == :marker
      {:marker_malformed, _} -> role == :marker
      {:marker_foreign, _} -> role == :marker
      _ -> false
    end)
  end

  describe "source contract: unavailable is never an empty observation" do
    test "an unavailable intent source raises an issue and admits nothing" do
      report = Admission.admit(@binding, :unavailable, {:observed, [live()]}, {:observed, marker()})

      assert {:source_unavailable, :intent} in report.issues
      assert report.decisions == []
    end

    test "an errored live source keeps the error term and admits nothing" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:error, :census_failed},
          {:observed, marker()}
        )

      assert {:source_error, :live, :census_failed} in report.issues
      assert Enum.all?(report.decisions, &(&1.verdict == :refused))
    end

    test "observed-empty and unavailable are DIFFERENT reports" do
      looked = Admission.admit(@binding, {:observed, []}, {:observed, []}, {:observed, marker()})
      could_not_look = Admission.admit(@binding, :unavailable, :unavailable, {:observed, marker()})

      assert looked.issues == []
      assert could_not_look.issues != []
      refute looked == could_not_look
    end
  end

  describe "issues are reported even when there are no decisions" do
    test "an empty report caused by failure is distinguishable from a clean empty report" do
      clean = Admission.admit(@binding, {:observed, []}, {:observed, []}, {:observed, marker()})
      failed = Admission.admit(@binding, {:error, :eio}, {:observed, []}, {:observed, marker()})

      assert clean.decisions == []
      assert clean.issues == []
      assert failed.decisions == []
      assert {:source_error, :intent, :eio} in failed.issues
    end
  end

  describe "duplicates and conflicts are raised, never silently resolved" do
    test "a duplicate pane_id within one source raises :duplicate AND refuses admission" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row(), row()]},
          {:observed, [live()]},
          {:observed, marker()}
        )

      assert {:duplicate, :intent, "pane-1"} in report.issues

      # Raising an issue is not refusing. The previous revision asserted only
      # the issue, so an implementation that admitted the duplicate anyway
      # would have passed.
      assert [%{pane_id: "pane-1", verdict: :refused}] = report.decisions
      refute Enum.any?(report.decisions, &(&1.verdict == :admissible))
    end

    test "values conflicting across sources raise :conflicting" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row(%{"pane_pid" => 123})]},
          {:observed, [live(%{pane_pid: 456})]},
          {:observed, marker()}
        )

      assert {:conflicting, :live, "pane-1"} in report.issues
      assert [%{verdict: :refused}] = report.decisions
    end
  end

  describe "scope binding matches project, project_dir AND project_inbox" do
    for {field, bad} <- [
          {"project", "other-project"},
          {"project_dir", "/synthetic/elsewhere"},
          {"project_inbox", "/synthetic/other-inbox"}
        ] do
      test "a #{field} mismatch refuses with :scope_mismatch" do
        report =
          Admission.admit(
            @binding,
            {:observed, [row(%{unquote(field) => unquote(bad)})]},
            {:observed, [live()]},
            {:observed, marker()}
          )

        assert {:scope_mismatch, "pane-1", unquote(field)} in report.issues
        assert [%{verdict: :refused}] = report.decisions
      end
    end
  end

  describe "marker identity is exact and session-local" do
    # `{:observed, :absent}` is "we looked and there is no session-local marker".
    # A previous revision passed `:unavailable` here — "we could not look" — and
    # still asserted `marker_absent`, which is the conflation the ruling forbids.
    # The unavailable case now has its own row below and must stay distinguishable.
    test "an absent marker refuses every record without rewriting intent" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, :absent}
        )

      assert {:marker_absent} in report.issues
      assert [%{verdict: :refused, refusals: refusals}] = report.decisions
      assert {:marker_absent} in refusals
    end

    test "an unavailable marker source is a source failure, not an observed absence" do
      report = Admission.admit(@binding, {:observed, [row()]}, {:observed, [live()]}, :unavailable)

      assert {:source_unavailable, :marker} in report.issues
      refute {:marker_absent} in report.issues
      assert [%{verdict: :refused}] = report.decisions
    end

    test "an errored marker source keeps the role and the reason" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:error, :marker_read_failed}
        )

      assert {:source_error, :marker, :marker_read_failed} in report.issues
      refute {:marker_absent} in report.issues
      refute {:source_unavailable, :marker} in report.issues
      assert [%{verdict: :refused}] = report.decisions
    end

    test "a malformed observed marker is reported as malformed, never as absent" do
      malformed = %{version: 1, owner_root: "/synthetic/inbox"}

      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, malformed}
        )

      assert {:marker_malformed, malformed} in report.issues
      refute {:marker_absent} in report.issues
      refute {:source_unavailable, :marker} in report.issues
      assert [%{verdict: :refused}] = report.decisions
    end

    # The marker is singular. Wrapping it in a list is the generic-source shape
    # leaking into the marker slot, and it is malformed input, not a marker.
    test "a singular marker wrapped in a list is malformed, not a marker" do
      wrapped = [marker()]

      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, wrapped}
        )

      assert {:marker_malformed, wrapped} in report.issues
      refute {:marker_absent} in report.issues
      assert [%{verdict: :refused}] = report.decisions
    end

    # The four marker source states must stay four states. This row is also the
    # positive control for the block: `present` must ADMIT, so a blanket-refuse
    # implementation cannot satisfy the rows above.
    test "present, absent, unavailable and errored markers are four different reports" do
      intent = {:observed, [row()]}
      live_source = {:observed, [live()]}

      present = Admission.admit(@binding, intent, live_source, {:observed, marker()})
      absent = Admission.admit(@binding, intent, live_source, {:observed, :absent})
      unavailable = Admission.admit(@binding, intent, live_source, :unavailable)
      errored = Admission.admit(@binding, intent, live_source, {:error, :marker_read_failed})

      assert present.issues == []
      assert [%{verdict: :admissible}] = present.decisions

      assert {:marker_absent} in absent.issues
      assert {:source_unavailable, :marker} in unavailable.issues
      assert {:source_error, :marker, :marker_read_failed} in errored.issues

      assert length(Enum.uniq([present, absent, unavailable, errored])) == 4
    end

    test "a foreign owner_root refuses" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, marker(%{owner_root: "/synthetic/someone-else"})}
        )

      assert {:marker_foreign, "/synthetic/someone-else"} in report.issues
    end

    test "a differing generation refuses that record" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row(%{"session_gen" => "8"})]},
          {:observed, [live()]},
          {:observed, marker(%{generation: "7"})}
        )

      assert [%{verdict: :refused, refusals: refusals}] = report.decisions
      assert {:generation_mismatch} in refusals
    end

    test "session NAME agreement with a differing session_id refuses" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live(%{session_id: "$9"})]},
          {:observed, marker(%{session_id: "$1"})}
        )

      assert [%{verdict: :refused, refusals: refusals}] = report.decisions
      assert {:session_mismatch} in refusals
    end
  end

  describe "prerequisites are never discharged by admission" do
    test "an ADMISSIBLE decision still carries undischarged prerequisites" do
      report =
        Admission.admit(
          @binding,
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, marker()}
        )

      assert [%{verdict: :admissible, undischarged: undischarged}] = report.decisions

      for prerequisite <- [
            :producer_trust,
            :process_agent_binding,
            :freshness_and_revalidation,
            :observation_completeness
          ] do
        assert prerequisite in undischarged
      end
    end

    # `Enum.all?` over a possibly-empty list is vacuously true, so the previous
    # revision's version of this row could pass with NO decisions at all.
    # Every input shape below must produce at least one decision, and every
    # decision must carry undischarged prerequisites.
    # The generator list of a module-level comprehension is evaluated at COMPILE
    # time, where this module's private helpers do not exist. An earlier draft
    # called row()/live()/marker() here and failed to compile with
    # "undefined function row/0". Parameterise over literal shape atoms and
    # build the data at RUNTIME inside the body.
    for {label, shape} <- [
          {"an admissible pane", :admissible},
          {"a refused pane", :refused},
          {"an unavailable live source", :unavailable_live},
          {"an errored marker source", :errored_marker}
        ] do
      test "no input empties the undischarged list: #{label}" do
        {intent, live_rows, mark} =
          case unquote(shape) do
            :admissible ->
              {{:observed, [row()]}, {:observed, [live()]}, {:observed, marker()}}

            :refused ->
              {{:observed, [row(%{"session_gen" => "9"})]}, {:observed, [live()]},
               {:observed, marker()}}

            :unavailable_live ->
              {{:observed, [row()]}, :unavailable, {:observed, marker()}}

            :errored_marker ->
              {{:observed, [row()]}, {:observed, [live()]}, {:error, :eio}}
          end

        report = Admission.admit(@binding, intent, live_rows, mark)

        assert report.decisions != [],
               "this row must exercise at least one decision or it proves nothing"

        for decision <- report.decisions do
          assert decision.undischarged != []
        end
      end
    end
  end

  describe "malformed input is an error, never a dropped row" do
    test "a row with unexpected keys is reported, not skipped" do
      report =
        Admission.admit(
          @binding,
          {:observed, [Map.put(row(), "surprise", true)]},
          {:observed, [live()]},
          {:observed, marker()}
        )

      assert {:source_error, :intent, :malformed_row} in report.issues
      assert report.decisions == []
    end

    test "an invalid configured binding is reported as :config_invalid" do
      report =
        Admission.admit(
          %{@binding | project_dir: "relative/path"},
          {:observed, [row()]},
          {:observed, [live()]},
          {:observed, marker()}
        )

      assert {:config_invalid, :project_dir} in report.issues
      assert Enum.all?(report.decisions, &(&1.verdict == :refused))
    end
  end

  describe "source failure reports are role-attributed and never collapsed" do
    # Role × failure-mode matrix. Individual cells are asserted verbatim
    # elsewhere in this file (intent/unavailable, intent/error, intent/malformed,
    # live/error, and every marker cell). What those rows do NOT assert is the
    # invariant below: for a GIVEN role the three failure modes and a completed
    # observation stay four separate reports, and every failure mode is
    # attributable to the role that failed. That is the property the ruling's
    # three prohibitions protect, so it is asserted uniformly for all roles
    # rather than being re-derived per cell.
    #
    # The generator list is expanded at COMPILE time, where this module's
    # private helpers do not exist — an earlier draft called row()/live()/marker()
    # in a generator and failed to compile with "undefined function row/0".
    # Parameterise over literal atoms; build every source at RUNTIME in the body.
    for role <- [:intent, :live, :marker] do
      test "#{role}: four source states produce four different reports" do
        role = unquote(role)

        reports = [
          admit_with(role, completed_source(role)),
          admit_with(role, failure_source(role, :unavailable)),
          admit_with(role, failure_source(role, :error)),
          admit_with(role, failure_source(role, :malformed))
        ]

        assert length(Enum.uniq(reports)) == 4,
               "#{role} collapsed distinct source states: #{inspect(Enum.map(reports, & &1.issues))}"
      end

      test "#{role}: every failure mode raises an issue attributed to that role" do
        role = unquote(role)

        for mode <- [:unavailable, :error, :malformed] do
          report = admit_with(role, failure_source(role, mode))

          assert attributed?(report.issues, role),
                 "#{mode} on #{role} raised no issue attributed to #{role}: " <>
                   inspect(report.issues)
        end
      end
    end

    # Positive control for this block: with every source completed and
    # well-formed there is no source issue at all and the record is admissible.
    # An implementation that refuses or complains unconditionally fails here.
    test "a completed observation on every source raises no issue and admits" do
      report =
        Admission.admit(
          @binding,
          completed_source(:intent),
          completed_source(:live),
          completed_source(:marker)
        )

      assert report.issues == []
      assert [%{verdict: :admissible}] = report.decisions
    end
  end
end
