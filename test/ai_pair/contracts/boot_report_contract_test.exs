defmodule AiPair.Contracts.BootReportContractTest do
  @moduledoc """
  Freezes the boot report fixtures under `test/fixtures/contracts/boot-report` (contract:
  `docs/contracts/boot-report.org`). Each fixture is one `<root>/state/boot-report.json`
  as the R04 S8 writer publishes it: compact JSON, one trailing newline. The bytes and
  `CONTRACT_HASH` are pinned under the v1 rule (sha256 over filename NUL bytes NUL,
  byte-sorted).

  The producer (`AiPair.PaneRestore.Reconciler` and `AiPair.PaneRestore.Boot`) is the R04
  S7/S8 pair and is not on main yet, so no fixture is regenerated here. The structural
  checks below are the contract's closed shapes and vocabularies read back off the frozen
  bytes with the repository's JSON decoder; duplicate object keys are rejected, as every
  durable format in this repository rejects them.
  """

  use ExUnit.Case, async: true

  alias AiPair.Test.BootReportShape

  @fixture_dir Path.expand("../../fixtures/contracts/boot-report", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")
  # Amended for NS-15.G.003 S2 G4: three fixtures carry the `restored` member; the original
  # three are byte-unchanged.
  @pinned_hash "060aaae3d96f30fd85124b592195638eb56e660946ed87bc3767b0649b88bb24"
  @expected_fixture_count 6

  @top_keys ~w(issues marker_observation marker_writes panes root)
  @pane_keys ~w(dispatchable pane_id refusals status undischarged)
  @pane_statuses ~w(observed_quarantined refused)

  @undischarged ~w(producer_trust process_agent_binding freshness_and_revalidation observation_completeness)

  # Decision refusals: Admission's closed vocabulary plus the Reconciler's three
  # execution refusals.
  @refusal_heads ~w(
    config_invalid source_unavailable source_error duplicate scope_mismatch live_absent
    conflicting marker_absent marker_malformed marker_foreign generation_mismatch
    session_mismatch fence_refused source_changed quarantine_unavailable
  )

  # Report issues: Admission's located findings plus the Reconciler's per-session marker
  # issue, its fence-update issue and Boot's deadline issue.
  @issue_heads ~w(
    config_invalid source_unavailable source_error duplicate scope_mismatch live_absent
    conflicting marker_absent marker_malformed marker_foreign generation_mismatch
    session_mismatch session_issue fence_update_failed reconciliation_timeout
  )

  test "the boot report fixture set matches its pinned content hash" do
    paths = fixture_paths()

    assert length(paths) == @expected_fixture_count,
           "boot report fixture set is missing or incomplete"

    assert File.regular?(@hash_path), "boot report CONTRACT_HASH is missing"

    payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)
    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert actual == @pinned_hash
    assert @hash_path |> File.read!() |> String.trim() == @pinned_hash
  end

  for path <-
        Path.wildcard(
          Path.join(Path.expand("../../fixtures/contracts/boot-report", __DIR__), "*.json")
        ) do
    name = Path.basename(path)

    test "#{name} has the closed report shape" do
      report = fixture(unquote(name))

      # Five members, plus `restored` exactly when Boot was given a receipt store.
      assert Map.keys(report) |> List.delete("restored") |> Enum.sort() == @top_keys
      if Map.has_key?(report, "restored"), do: BootReportShape.assert_restored!(report["restored"])
      assert is_binary(report["root"]) and String.starts_with?(report["root"], "/")
      assert report["marker_writes"] == 0
      assert is_list(report["panes"])
      assert is_list(report["issues"])

      for pane <- report["panes"] do
        assert Map.keys(pane) |> Enum.sort() == @pane_keys
        assert pane["dispatchable"] == false
        assert is_binary(pane["pane_id"]) or is_nil(pane["pane_id"])
        assert pane["status"] in @pane_statuses
        assert pane["undischarged"] == @undischarged or pane["undischarged"] == "unknown"
        assert is_list(pane["refusals"])
        for refusal <- pane["refusals"], do: assert_tagged(refusal, @refusal_heads)
        if pane["status"] == "observed_quarantined", do: assert(pane["refusals"] == [])
      end

      for issue <- report["issues"], do: assert_tagged(issue, @issue_heads)
      assert_marker_observation(report["marker_observation"])
    end
  end

  test "a clean boot reports no issues and only quarantined panes" do
    report = fixture("boot-report.clean.json")

    assert report["issues"] == []
    assert [%{"status" => "observed_quarantined", "refusals" => []}] = report["panes"]

    assert ["observed", %{"$3" => ["observed", %{"session_id" => "$3", "version" => 1}]}] =
             report["marker_observation"]
  end

  test "a boot with refusals keeps every refusal bound to its source" do
    report = fixture("boot-report.refusals_and_issues.json")
    by_pane = Map.new(report["panes"], &{&1["pane_id"], &1})

    assert by_pane["<pane_a>"]["status"] == "observed_quarantined"
    assert by_pane["<pane_b>"]["refusals"] == [["marker_absent"]]
    assert by_pane["<pane_c>"]["refusals"] == [["live_absent"], ["source_unavailable", "marker"]]
    assert by_pane["<pane_d>"]["refusals"] == [["scope_mismatch", "project"]]
    assert by_pane["<pane_e>"]["refusals"] == [["fence_refused", "pane_busy"]]
    assert by_pane["<pane_f>"]["refusals"] == [["session_mismatch"]]

    # B9: a per-session marker issue locates its session by exact id in the marker role.
    assert Enum.any?(report["issues"], &match?(["session_issue", "marker", "$5", _], &1))
    refute Enum.any?(report["issues"], &match?(["session_issue", "marker", "$50", _], &1))
    assert ["observed", markers] = report["marker_observation"]
    assert markers["$4"] == ["observed", "absent"]
    assert ["error", _] = markers["$5"]
  end

  test "a deadline-expired boot publishes the empty report with the timeout issue" do
    report = fixture("boot-report.deadline_expired.json")

    assert report["panes"] == []
    assert [["reconciliation_timeout", deadline]] = report["issues"]
    assert is_integer(deadline) and deadline > 0
    assert report["marker_observation"] == "unobserved"
  end

  # --- NS-15.G.003 S2 G4: the restored snapshot -----------------------------

  test "the original three fixtures carry no restored member" do
    for name <- ~w(boot-report.clean.json boot-report.refusals_and_issues.json
                   boot-report.deadline_expired.json) do
      refute Map.has_key?(fixture(name), "restored"), "#{name} gained a restored member"
    end
  end

  test "a restored snapshot reports fence, issue and start separately, per pane" do
    report = fixture("boot-report.restored.json")
    assert ["observed", rows] = report["restored"]
    by_pane = Map.new(rows, &{&1["pane_id"], &1})

    assert %{"recorded" => true, "fence" => "released", "issue" => "issued", "start" => "started"} =
             by_pane["<pane_a>"]

    assert %{"recorded" => false, "fence" => "not_attempted", "issue" => "not_attempted"} =
             by_pane["<pane_b>"]

    assert by_pane["<pane_c>"]["issue"] == ["refused", "not_issuer"]
    assert by_pane["<pane_c>"]["start"] == "started"

    # A capability issued is not a child started.
    assert by_pane["<pane_d>"]["issue"] == "issued"
    assert by_pane["<pane_d>"]["start"] == ["refused", "already_started"]
    assert Enum.map(by_pane["<pane_a>"]["entries"], & &1["msg_id"]) == ["<msg_a1>", "<msg_a2>"]
  end

  test "an uncertain start and fence are reported unresolved, with the fence issue" do
    report = fixture("boot-report.restored_unresolved.json")
    assert ["observed", [row]] = report["restored"]
    assert row["fence"] == "unresolved"
    assert row["start"] == ["unresolved", "coordinator_unavailable"]
    assert [["fence_update_failed", "<pane_id>", _]] = report["issues"]
  end

  test "a deadline-expired boot with a receipt store claims no snapshot" do
    report = fixture("boot-report.deadline_expired_restored.json")
    assert report["restored"] == "unobserved"
    assert report["panes"] == []
  end

  defp assert_tagged(term, heads) do
    assert [head | _] = term, "a finding is a non-empty array, got: #{inspect(term)}"
    assert head in heads, "unknown finding head #{inspect(head)} in #{inspect(term)}"
  end

  defp assert_marker_observation(observation) do
    case observation do
      "unobserved" ->
        :ok

      "not_applicable" ->
        :ok

      ["observed", markers] when is_map(markers) ->
        for {session_id, source} <- markers do
          assert is_binary(session_id) and session_id != ""
          assert_marker_source(source)
        end

      other ->
        flunk("unknown marker_observation: #{inspect(other)}")
    end
  end

  defp assert_marker_source("unavailable"), do: :ok
  defp assert_marker_source(["observed", "absent"]), do: :ok
  defp assert_marker_source(["error", _reason]), do: :ok

  defp assert_marker_source(["observed", %{} = marker]) do
    assert Map.keys(marker) |> Enum.sort() == ~w(generation owner_root session_id version)
    assert marker["version"] == 1
  end

  # A malformed marker is observed as its raw bytes.
  defp assert_marker_source(["observed", raw]) when is_binary(raw), do: :ok
  defp assert_marker_source(other), do: flunk("unknown marker source: #{inspect(other)}")

  defp fixture(name) do
    {:ok, ordered} =
      @fixture_dir |> Path.join(name) |> File.read!() |> Jason.decode(objects: :ordered_objects)

    plain(ordered)
  end

  # Rejects duplicate object keys at any depth while flattening to plain maps.
  defp plain(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    assert length(keys) == length(Enum.uniq(keys)), "duplicate object key in #{inspect(keys)}"
    Map.new(pairs, fn {key, value} -> {key, plain(value)} end)
  end

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  defp plain(scalar), do: scalar

  defp fixture_paths, do: @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
end
