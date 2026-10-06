defmodule AiPair.Test.BootReportShape do
  @moduledoc """
  The boot report contract (`docs/contracts/boot-report.org`) as predicates a
  test can run over a report the producer built in-BEAM.

  `encode/1` maps an in-memory report to the JSON term the contract's
  "Encoding of Elixir terms" section describes: maps become objects with string
  keys, lists arrays, tuples arrays of their elements, pids and references their
  `inspect` text, atoms strings (with `true`, `false` and `nil` as the JSON
  literals). It is a TEST encoder: the production writer is the Boot slice's,
  and when it lands the fixtures are regenerated through it.

  `assert_closed_shape!/1` is the closed-shape check of
  `test/ai_pair/contracts/boot_report_contract_test.exs`, lifted verbatim so a
  produced report is measured by exactly the predicates the frozen fixtures are
  measured by. That file keeps its own private copy on purpose: the fixture
  bytes are pinned there, and this module must stay in step with it, which the
  producer test's positive control (every frozen fixture passes here too)
  enforces.
  """

  import ExUnit.Assertions

  @top_keys ~w(issues marker_observation marker_writes panes root)
  @pane_keys ~w(dispatchable pane_id refusals status undischarged)
  @pane_statuses ~w(observed_quarantined refused)

  @undischarged ~w(producer_trust process_agent_binding freshness_and_revalidation observation_completeness)

  @refusal_heads ~w(
    config_invalid source_unavailable source_error duplicate scope_mismatch live_absent
    conflicting marker_absent marker_malformed marker_foreign generation_mismatch
    session_mismatch fence_refused source_changed quarantine_unavailable
  )

  @issue_heads ~w(
    config_invalid source_unavailable source_error duplicate scope_mismatch live_absent
    conflicting marker_absent marker_malformed marker_foreign generation_mismatch
    session_mismatch session_issue fence_update_failed reconciliation_timeout
  )

  @doc "The closed refusal heads of the contract."
  def refusal_heads, do: @refusal_heads

  @doc "The closed issue heads of the contract."
  def issue_heads, do: @issue_heads

  @doc "Encodes an in-memory report to the contract's JSON term (decoded form: plain maps and lists)."
  @spec encode(term()) :: term()
  def encode(term) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {encode_key(key), encode(value)} end)
  end

  def encode(term) when is_list(term), do: Enum.map(term, &encode/1)
  def encode(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&encode/1)
  def encode(term) when is_pid(term) or is_reference(term), do: inspect(term)
  def encode(term) when term in [true, false, nil], do: term
  def encode(term) when is_atom(term), do: Atom.to_string(term)
  def encode(term) when is_binary(term) or is_number(term), do: term
  def encode(term), do: inspect(term)

  defp encode_key(key) when is_binary(key), do: key
  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: inspect(key)

  @doc "Round-trips the encoded term through the JSON encoder and decoder, as a writer and reader would."
  @spec json_round_trip(term()) :: term()
  def json_round_trip(encoded), do: encoded |> Jason.encode!() |> Jason.decode!()

  @restored_row_keys ~w(entries fence issue pane_id recorded start)
  @issue_refusals ~w(not_issuer no_restored_entries capability_live fenced_holder_alive other)
  @submit_refusals ~w(pane_busy unresolved_operation target_not_found target_not_local)
  @unresolved ~w(timeout coordinator_unavailable unresolved_operation other)
  @start_refusals ~w(already_started max_children ignore other)

  @doc """
  Asserts the closed `restored` member (boot-report contract, NS-15.G.003 S2 G4): every value
  is from a closed vocabulary, and nothing pid-, reference-, hash- or secret-like is encoded.
  """
  def assert_restored!(restored) do
    case restored do
      "unobserved" ->
        :ok

      "unavailable" ->
        :ok

      ["error", head] ->
        assert head == "other"

      ["observed", rows] when is_list(rows) ->
        pane_ids = Enum.map(rows, & &1["pane_id"])
        assert pane_ids == Enum.sort(pane_ids), "restored rows are sorted by pane_id"

        for row <- rows do
          assert Map.keys(row) |> Enum.sort() == @restored_row_keys
          assert is_binary(row["pane_id"]) and is_boolean(row["recorded"])
          assert row["entries"] != []

          for entry <- row["entries"] do
            assert Map.keys(entry) |> Enum.sort() == ~w(attempt msg_id)
            assert is_binary(entry["msg_id"]) and is_integer(entry["attempt"])
          end

          assert row["fence"] in ["released", "unresolved", "not_attempted"] or
                   match?(
                     ["refused", h]
                     when h in ~w(pane_busy unresolved_operation coordinator_unavailable other),
                     row["fence"]
                   )

          assert_effect!(row["issue"], "issued", @issue_refusals ++ @submit_refusals)
          assert_effect!(row["start"], "started", @start_refusals ++ @submit_refusals)

          unless row["recorded"] do
            assert {row["fence"], row["issue"], row["start"]} ==
                     {"not_attempted", "not_attempted", "not_attempted"}
          end
        end

      other ->
        flunk("unknown restored member: #{inspect(other)}")
    end

    # Privacy: no pid, reference, payload hash, or 64-hex / 43-char base64 run (a token,
    # capability or digest) anywhere in the encoded member. Message ids (snd_ plus 64 hex)
    # are the one permitted identifier and are masked before the scan.
    text = restored |> mask_msg_ids() |> Jason.encode!()
    refute text =~ "#PID<"
    refute text =~ "#Reference<"
    refute text =~ "sha256:"
    refute Regex.match?(~r/[0-9a-f]{64}/, text)
    refute Regex.match?(~r/[A-Za-z0-9_-]{43}/, text)
    :ok
  end

  defp mask_msg_ids(["observed", rows]) when is_list(rows) do
    [
      "observed",
      Enum.map(rows, fn row ->
        Map.update(row, "entries", [], fn entries ->
          Enum.map(entries, &Map.put(&1, "msg_id", "<msg_id>"))
        end)
      end)
    ]
  end

  defp mask_msg_ids(other), do: other

  defp assert_effect!(value, success, refusals) do
    case value do
      ^success -> :ok
      "not_attempted" -> :ok
      ["refused", head] -> assert head in refusals
      ["unresolved", head] -> assert head in @unresolved
      other -> flunk("unknown effect outcome: #{inspect(other)}")
    end
  end

  @doc "Asserts the contract's closed top-level, pane, refusal, issue and marker shapes over a decoded report."
  def assert_closed_shape!(report) do
    # Five members, plus `restored` when Boot was given a receipt store (NS-15.G.003 S2 G4).
    assert Map.keys(report) |> List.delete("restored") |> Enum.sort() == @top_keys
    if Map.has_key?(report, "restored"), do: assert_restored!(report["restored"])
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
    :ok
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

  defp assert_marker_source(["observed", raw]) when is_binary(raw), do: :ok
  defp assert_marker_source(other), do: flunk("unknown marker source: #{inspect(other)}")
end
