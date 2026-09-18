defmodule AiPair.Contracts.DurableIPCContractTest do
  @moduledoc """
  Freezes the durable attach/detach frames under `test/fixtures/contracts/ipc/durable`
  (contract: `docs/contracts/durable-attach-detach.org`). Each fixture is one v1 frame as
  the repository's JSON encoder produces it: compact, one trailing newline. The bytes and
  `CONTRACT_HASH` are pinned under the v1 rule (sha256 over filename NUL bytes NUL,
  byte-sorted).

  The reply producer is the R04 S9 slice and is not on main: `lib/ai_pair/ipc/server.ex`
  never reads the `durable` request key today. So no reply fixture is regenerated here.
  The structural checks below are the contract's closed shapes and vocabularies read back
  off the frozen bytes with the repository's JSON decoder, rejecting duplicate object keys.
  The three `request.attach.*` fixtures ARE checked against their real producer,
  `AiPair.CLI.Client.attach_payload/3`, which landed with R04 S3.

  This module also guards the NS-39 boundary from the durable side: no member this
  contract introduces may appear in any frozen IPC v1 fixture.
  """

  use ExUnit.Case, async: true

  alias AiPair.CLI.Client
  alias AiPair.PaneIntentStore.Record

  @fixture_dir Path.expand("../../fixtures/contracts/ipc/durable", __DIR__)
  @v1_dir Path.expand("../../fixtures/contracts/ipc/v1", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")
  @pinned_hash "6915cf1b2e323c32f8c67f437c8a77fbc711279e523d90c4e128f9fb1ef071b5"
  @expected_fixture_count 36

  @pane_id "<pane_id>"

  # Every member name any frame in this contract may carry.
  @request_members ~w(agent cmd durable pane_id)
  @reply_members ~w(
    agent body_error classifier coordinator_error error fallback missing ok pane_id
    pane_registered persist_outcome persist_stage persisted repair_required started
    state status
  )

  # Members that exist only because durability was asked about. None may appear in a
  # legacy-mode reply, and none may appear in a frozen v1 fixture.
  @durable_members ~w(
    body_error coordinator_error durable missing pane_registered persist_outcome
    persist_stage persisted repair_required
  )

  @fence_errors ~w(coordinator_unavailable pane_busy unresolved_operation)

  @attach_errors @fence_errors ++
                   ~w(
                     durable_metadata_missing durable_unavailable durable_pane_unobserved
                     durable_observation_ambiguous durable_observation_unavailable
                     durable_observation_changed marker_absent marker_foreign
                     marker_malformed marker_changed marker_unavailable session_mismatch
                     durable_write_failed durable_store_timeout
                   )

  @detach_errors @fence_errors ++
                   ~w(
                     pane_not_found durable_unavailable durable_lookup_failed
                     durable_store_timeout durable_withdrawal_failed
                   )

  @persist_outcomes ~w(committed unchanged uncertain skipped)

  # The server's own unanswered-call stages, then the store's stage atoms as they appear
  # in `lib/ai_pair/pane_intent_store.ex` on main. The store types `stage` as `atom()`, so
  # this list is advisory for a future producer; see the contract's OQ-2.
  @call_stages ~w(put list delete)
  @store_stages ~w(
    ownership validation path permission read create write file_sync rename
    directory_sync poisoned
  )
  @persist_stages @call_stages ++ @store_stages

  @detach_statuses ~w(intent_withdrawn withdrawal_failed detached already_detached)

  # The exact thirteen record keys the contract quotes, in contract order.
  @record_keys ~w(
    schema_version pane_id agent classifier project project_dir project_inbox
    tmux_session session_gen cwd command pane_pid updated_at
  )

  test "the durable fixture set matches its pinned content hash" do
    paths = fixture_paths()

    assert length(paths) == @expected_fixture_count,
           "durable IPC fixture set is missing or incomplete"

    assert File.regular?(@hash_path), "durable IPC CONTRACT_HASH is missing"

    payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)
    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert actual == @pinned_hash
    assert @hash_path |> File.read!() |> String.trim() == @pinned_hash
  end

  test "every fixture is compact JSON with exactly one trailing newline" do
    for path <- fixture_paths() do
      bytes = File.read!(path)
      base = Path.basename(path)

      assert String.ends_with?(bytes, "}\n"), "#{base} must end with one newline after the object"
      assert length(String.split(bytes, "\n")) == 2, "#{base} must be one line plus its newline"
    end
  end

  for path <-
        Path.wildcard(
          Path.join(Path.expand("../../fixtures/contracts/ipc/durable", __DIR__), "*.json")
        ) do
    fixture_name = Path.basename(path)

    test "#{fixture_name} carries only contract members" do
      name = unquote(fixture_name)
      frame = fixture(name)

      allowed =
        if String.starts_with?(name, "request."), do: @request_members, else: @reply_members

      for key <- Map.keys(frame) do
        assert key in allowed, "#{name}: member #{inspect(key)} is not in the contract"
      end
    end
  end

  test "request fixtures are exactly what the real payload builder produces" do
    assert Client.attach_payload(@pane_id, "<agent>", false) ==
             fixture("request.attach.legacy.json")

    assert Client.attach_payload(@pane_id, "<agent>", true) ==
             fixture("request.attach.durable.json")

    assert Client.attach_payload(@pane_id, nil, true) ==
             fixture("request.attach.durable_no_agent.json")

    # `durable` is never sent as false: a legacy frame carries no such key at all.
    refute Map.has_key?(fixture("request.attach.legacy.json"), "durable")
    assert fixture("request.attach.durable.json")["durable"] == true
    refute Map.has_key?(fixture("request.attach.durable_no_agent.json"), "agent")
  end

  test "the detach request carries only the command and the pane" do
    assert fixture("request.detach.json") == %{"cmd" => "detach_pane", "pane_id" => @pane_id}
  end

  test "every reply names its outcome and, when refused, a closed-vocabulary error" do
    for {name, frame} <- reply_fixtures() do
      assert is_boolean(frame["ok"]), "#{name}: ok must be a boolean"
      assert frame["pane_id"] == @pane_id, "#{name}: pane_id is echoed"

      if frame["ok"] do
        refute Map.has_key?(frame, "error"), "#{name}: a successful reply carries no error"
      else
        vocabulary =
          if String.starts_with?(name, "detach."), do: @detach_errors, else: @attach_errors

        assert frame["error"] in vocabulary,
               "#{name}: #{inspect(frame["error"])} is outside the closed vocabulary"
      end
    end
  end

  test "persisted is the strong claim: only true, and only beside a committed outcome" do
    for {name, frame} <- reply_fixtures(), Map.has_key?(frame, "persisted") do
      assert frame["persisted"] == true, "#{name}: persisted is never false"

      assert frame["persist_outcome"] == "committed",
             "#{name}: persisted may only accompany a committed outcome"

      assert frame["ok"] == true, "#{name}: persisted may only accompany a successful reply"
    end
  end

  test "repair_required is only ever true, and never beside persisted" do
    for {name, frame} <- reply_fixtures(), Map.has_key?(frame, "repair_required") do
      assert frame["repair_required"] == true, "#{name}: repair_required is never false"
      assert frame["ok"] == false, "#{name}: repair is owed only on a refusal"
      refute Map.has_key?(frame, "persisted"), "#{name}: a repair-owing reply claims nothing"
    end
  end

  test "persist_outcome and persist_stage stay inside their unions" do
    for {name, frame} <- reply_fixtures() do
      outcome = frame["persist_outcome"]
      stage = frame["persist_stage"]

      if outcome != nil do
        assert outcome in @persist_outcomes,
               "#{name}: #{inspect(outcome)} is not a persist_outcome"
      end

      if stage != nil do
        assert stage in @persist_stages, "#{name}: #{inspect(stage)} is not a known persist_stage"

        assert outcome in ~w(unchanged uncertain),
               "#{name}: a stage is named only by a failed commit"
      end
    end
  end

  test "a fence refusal is exactly ok, pane_id and error" do
    names = ~w(
      attach.error.coordinator_unavailable.json attach.error.pane_busy.json
      attach.error.unresolved_operation.json detach.error.coordinator_unavailable.json
      detach.error.pane_busy.json
    )

    for name <- names do
      frame = fixture(name)
      assert Enum.sort(Map.keys(frame)) == ~w(error ok pane_id)
      assert frame["ok"] == false
      assert frame["error"] in @fence_errors
    end
  end

  test "pre-effect attach refusals claim nothing about disk, except the unreadable marker" do
    bare = ~w(
      durable_unavailable durable_pane_unobserved durable_observation_ambiguous
      durable_observation_unavailable durable_observation_changed marker_absent
      marker_foreign marker_malformed marker_changed session_mismatch
    )

    for error <- bare do
      frame = fixture("attach.error.#{error}.json")
      assert Enum.sort(Map.keys(frame)) == ~w(error ok pane_id)
      assert frame["error"] == error
    end

    # G5: could not look is not absence, and the wire says so with "uncertain".
    unavailable = fixture("attach.error.marker_unavailable.json")
    assert unavailable["persist_outcome"] == "uncertain"
    refute Map.has_key?(unavailable, "persisted")
    refute Map.has_key?(unavailable, "repair_required")
  end

  test "the metadata refusal names every missing field in the fixed order" do
    frame = fixture("attach.error.durable_metadata_missing.json")

    assert frame["error"] == "durable_metadata_missing"
    assert frame["missing"] == ~w(agent project project_dir project_inbox)
    refute Map.has_key?(frame, "persisted")
  end

  test "a post-start persistence failure keeps the stage and owes repair" do
    unchanged = fixture("attach.error.durable_write_failed.unchanged.json")
    assert unchanged["persist_outcome"] == "unchanged"
    assert unchanged["persist_stage"] == "file_sync"
    assert unchanged["repair_required"] == true

    uncertain = fixture("attach.error.durable_write_failed.uncertain.json")
    assert uncertain["persist_outcome"] == "uncertain"
    assert uncertain["persist_stage"] == "directory_sync"

    # C2: "put" names the unanswered call boundary, never an inferred filesystem stage.
    timeout = fixture("attach.error.durable_store_timeout.json")
    assert timeout["persist_stage"] == "put"
    assert timeout["persist_outcome"] == "uncertain"
    assert timeout["error"] != "durable_unavailable"
  end

  test "a fence-update failure keeps the known persistence outcome and reports separately" do
    frame = fixture("attach.error.fence_update_failed.json")

    assert frame["ok"] == false
    assert frame["error"] == "coordinator_unavailable"
    assert frame["persist_outcome"] == "committed"
    assert frame["repair_required"] == true
    refute Map.has_key?(frame, "persisted")
    assert is_binary(frame["coordinator_error"])

    # OQ-1: ff8650e emits body_error as null when the body itself succeeded. Pinned as
    # observed; the S9 review decides whether to omit it.
    assert Map.has_key?(frame, "body_error")
    assert frame["body_error"] == nil
  end

  test "a successful durable attach reports the child and the commit together" do
    for name <- ~w(attach.ok.committed.json attach.ok.committed.already_started.json) do
      frame = fixture(name)

      assert Enum.sort(Map.keys(frame)) ==
               ~w(agent classifier ok pane_id persist_outcome persisted started state)

      assert frame["ok"] == true
      assert frame["persisted"] == true
      assert frame["persist_outcome"] == "committed"
    end

    assert fixture("attach.ok.committed.json")["started"] == true
    assert fixture("attach.ok.committed.already_started.json")["started"] == false
  end

  test "detach outcomes keep an answer apart from the absence of one" do
    withdrawn = fixture("detach.ok.intent_withdrawn.json")

    assert Enum.sort(Map.keys(withdrawn)) ==
             ~w(ok pane_id pane_registered persist_outcome persisted status)

    assert withdrawn["status"] == "intent_withdrawn"
    assert is_boolean(withdrawn["pane_registered"])

    # A successful read that found nothing: a pre-effect skip, not a measured failure.
    skipped = fixture("detach.error.pane_not_found.skipped.json")
    assert skipped["error"] == "pane_not_found"
    assert skipped["persist_outcome"] == "skipped"
    refute Map.has_key?(skipped, "repair_required")

    # A store nobody could read is never reported as an authoritative absence.
    unreachable = ~w(
      detach.error.durable_unavailable.json detach.error.durable_lookup_failed.json
    )

    for name <- unreachable do
      frame = fixture(name)
      assert frame["persist_outcome"] == "uncertain"
      assert frame["repair_required"] == true
      refute frame["error"] == "pane_not_found"
    end

    failed = fixture("detach.error.durable_withdrawal_failed.json")
    assert failed["status"] == "withdrawal_failed"
    assert failed["persist_outcome"] == "unchanged"
    assert failed["persist_stage"] == "file_sync"

    committed = fixture("detach.error.coordinator_unavailable.committed.json")
    assert committed["error"] == "coordinator_unavailable"
    assert committed["persist_outcome"] == "committed"
    assert committed["repair_required"] == true
    refute Map.has_key?(committed, "persisted")
  end

  test "every status string is in the closed set and belongs to a detach reply" do
    for {name, frame} <- reply_fixtures(), frame["status"] != nil do
      status = frame["status"]
      assert status in @detach_statuses, "#{name}: #{inspect(status)} is not a detach status"

      assert String.starts_with?(name, "detach.") or String.starts_with?(name, "legacy.detach."),
             "#{name}: only a detach reply carries a status"
    end
  end

  test "a legacy-mode reply was never asked the durability question" do
    for name <- ~w(legacy.attach.ok.json legacy.detach.ok.json) do
      frame = fixture(name)
      assert frame["ok"] == true

      for member <- @durable_members do
        refute Map.has_key?(frame, member), "#{name}: legacy replies carry no #{member}"
      end
    end

    assert Enum.sort(Map.keys(fixture("legacy.attach.ok.json"))) ==
             ~w(agent classifier ok pane_id started state)

    assert fixture("legacy.detach.ok.json") == %{
             "ok" => true,
             "pane_id" => @pane_id,
             "status" => "detached"
           }
  end

  test "NS-39: no durable member reaches a frozen IPC v1 fixture" do
    paths = @v1_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
    assert length(paths) == 15, "the frozen v1 set is fifteen fixtures"

    for path <- paths do
      frame = path |> File.read!() |> decode()

      for member <- @durable_members do
        refute Map.has_key?(frame, member),
               "#{Path.basename(path)} gained the durable member #{member}"
      end
    end
  end

  test "the record the contract quotes is the store's own thirteen-key schema" do
    assert @record_keys == Record.record_keys()
    assert length(@record_keys) == 13
    assert is_binary(Record.version())
  end

  defp reply_fixtures do
    for path <- fixture_paths(),
        name = Path.basename(path),
        not String.starts_with?(name, "request."),
        do: {name, fixture(name)}
  end

  defp fixture(name), do: @fixture_dir |> Path.join(name) |> File.read!() |> decode()

  defp decode(bytes) do
    {:ok, ordered} = Jason.decode(bytes, objects: :ordered_objects)
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
