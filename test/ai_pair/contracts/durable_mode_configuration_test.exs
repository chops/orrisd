defmodule AiPair.Contracts.DurableModeConfigurationTest do
  @moduledoc """
  Freezes the durable-mode configuration tables under
  `test/fixtures/contracts/durable-mode-config` (contract:
  `docs/contracts/durable-mode-configuration.org`). The bytes and `CONTRACT_HASH` are
  pinned under the v1 rule (sha256 over filename NUL bytes NUL, byte-sorted).

  The producer is the R04 S10 slice and is not on main: `AiPair.Application` has no
  durable branch and reads none of the six keys. So the durable composition table is
  pinned as documentation, and everything that CAN be checked against main today is
  checked:

    * the three defaults that exist as terms - `AiPair.PaneIntentStore.Fs.default/0`,
      `AiPair.Tmux` and `AiPair.PaneIntentStore`;
    * the generation shape, against the real `AiPair.PaneRestore.Marker.mint_generation/0`;
    * the `:project_binding` key set, against the real `AiPair.PaneRestore.Admission.admit/4`;
    * the store child's id and restart under the `:pane_intent_store_module` substitution,
      against the real `Supervisor.child_spec/2`;
    * every durable child's declared restart type, against its own `child_spec/1`;
    * and the legacy composition, twice over - against the RUNNING supervision tree and
      against the whitespace-normalised text of `lib/ai_pair/application.ex`, so that S10
      cannot alter the legacy branch without failing here.
  """

  use ExUnit.Case, async: true

  alias AiPair.PaneRestore.Admission
  alias AiPair.PaneRestore.Marker

  @fixture_dir Path.expand("../../fixtures/contracts/durable-mode-config", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")
  @pinned_hash "7adbd52a5f9d4cf672ab8d909a049ebd57f94a746ec35493a7f45bcbb638b366"
  @expected_fixture_count 3

  @application_source Path.expand("../../../lib/ai_pair/application.ex", __DIR__)
  @ipc_server_source Path.expand("../../../lib/ai_pair/ipc/server.ex", __DIR__)

  @key_names ~w(
    durable_attachments project_binding tmux_server
    pane_intent_store_fs pane_intent_store_module boot_generation
  )

  @key_fields ~w(
    arrives_with default default_term key read_by_ipc_server set_by type when_absent when_invalid
  )

  test "the durable-mode configuration fixture set matches its pinned content hash" do
    paths = fixture_paths()

    assert length(paths) == @expected_fixture_count,
           "durable-mode configuration fixture set is missing or incomplete"

    assert File.regular?(@hash_path), "durable-mode configuration CONTRACT_HASH is missing"

    payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)
    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert actual == @pinned_hash
    assert @hash_path |> File.read!() |> String.trim() == @pinned_hash
  end

  # --- the six keys ---------------------------------------------------------

  describe "configuration.keys.json" do
    test "names exactly the six keys of the contract, each with the full field set" do
      doc = fixture("configuration.keys.json")

      assert Enum.map(doc["keys"], & &1["key"]) == @key_names
      assert doc["application"] == "ai_pair"

      for entry <- doc["keys"] do
        assert Enum.sort(Map.keys(entry)) == @key_fields
        assert is_binary(entry["type"]) and entry["type"] != ""
        assert is_binary(entry["when_absent"]) and entry["when_absent"] != ""
        assert is_binary(entry["when_invalid"]) and entry["when_invalid"] != ""
        assert is_binary(entry["set_by"]) and entry["set_by"] != ""
        assert is_boolean(entry["read_by_ipc_server"])
      end
    end

    test "every default that exists as a term on main is that term" do
      by_key = keys_by_name()

      # The three defaults S10 will pass are real values today; a rename or a
      # changed default here diverges from the frozen table.
      assert by_key["tmux_server"]["default_term"] == inspect(AiPair.Tmux)

      assert by_key["pane_intent_store_module"]["default_term"] ==
               inspect(AiPair.PaneIntentStore)

      assert by_key["pane_intent_store_fs"]["default_term"] ==
               inspect(AiPair.PaneIntentStore.Fs.default())

      assert AiPair.PaneIntentStore.Fs.default() == {AiPair.PaneIntentStore.Fs.SystemFs, nil}

      # The two keys with no default term have none recorded, and the one whose
      # default is a computation names that computation instead.
      assert by_key["durable_attachments"]["default_term"] == nil
      assert by_key["project_binding"]["default_term"] == nil
      assert by_key["boot_generation"]["default_term"] == nil

      assert by_key["boot_generation"]["default"] ==
               "AiPair.PaneRestore.Marker.mint_generation/0"

      assert exports?(Marker, :mint_generation, 0)
      assert exports?(AiPair.PaneIntentStore, :start_link, 1)
    end

    test "the frozen generation pattern is the one a minted generation satisfies" do
      doc = fixture("configuration.keys.json")

      # The frozen spelling, and the anchored Elixir regex it denotes - the same
      # one `AiPair.IPC.Server` validates a `boot_generation:` option with.
      assert doc["generation_pattern"] == "^[0-9]+$"
      pattern = ~r/\A[0-9]+\z/

      minted = Marker.mint_generation()
      assert is_binary(minted)
      assert Regex.match?(pattern, minted)

      # The contract's stated bound: the decimal form of an unsigned 128-bit integer.
      assert byte_size(minted) in 1..39

      # G9's negative and the two empties the pattern must reject, so the rule
      # that a present-invalid value fails the boot has something to reject.
      refute Regex.match?(pattern, "not-a-decimal")
      refute Regex.match?(pattern, "")
      refute Regex.match?(pattern, "12 34")
      refute Regex.match?(pattern, "12\n")
    end

    test "the frozen binding key set is the one Admission accepts" do
      doc = fixture("configuration.keys.json")
      assert doc["binding_keys"] == ~w(project project_dir project_inbox)

      good = %{project: "synthetic-project", project_dir: "/synthetic", project_inbox: "/synthetic"}
      assert config_findings(good) == []

      # Absent, and any other shape, is the whole-binding finding.
      assert config_findings(nil) == [{:config_invalid, :binding}]
      assert config_findings(%{}) == [{:config_invalid, :binding}]
      assert config_findings(Map.put(good, :extra, 1)) == [{:config_invalid, :binding}]
      assert config_findings(Map.delete(good, :project)) == [{:config_invalid, :binding}]

      # A three-key map with a bad field is located to that field.
      assert config_findings(%{good | project: ""}) == [{:config_invalid, :project}]
      assert config_findings(%{good | project_dir: "relative"}) == [{:config_invalid, :project_dir}]
      assert config_findings(%{good | project_inbox: nil}) == [{:config_invalid, :project_inbox}]
    end

    test "an unusable binding refuses every recorded pane and starts nothing" do
      report = Admission.admit(nil, {:observed, [record()]}, {:observed, []}, :unavailable)

      assert [%{verdict: :refused, refusals: [{:config_invalid, :binding}]}] = report.decisions

      # And the control: with a usable binding the SAME row is not refused for a
      # configuration reason, so the row above measures the binding and not a
      # malformed record.
      good = %{project: "synthetic-project", project_dir: "/synthetic", project_inbox: "/synthetic"}
      control = Admission.admit(good, {:observed, [record()]}, {:observed, []}, :unavailable)

      assert [%{verdict: :refused, refusals: refusals}] = control.decisions
      refute Enum.any?(refusals, &match?({:config_invalid, _}, &1))
    end

    test "the keys that arrive with S10 are not the IPC server's to read" do
      by_key = keys_by_name()
      source = File.read!(@ipc_server_source)

      # The store seams belong to Application composition. This stays true after
      # S10 lands, which is why it is asserted as an invariant and not as a
      # not-yet-implemented marker.
      for name <- ~w(pane_intent_store_fs pane_intent_store_module) do
        assert by_key[name]["read_by_ipc_server"] == false
        refute String.contains?(source, ":" <> name)
      end

      # The three the IPC server does read are read there today.
      for name <- ~w(durable_attachments project_binding tmux_server) do
        assert by_key[name]["read_by_ipc_server"] == true

        assert String.contains?(source, "Application.get_env(:ai_pair, :" <> name),
               "#{name} is documented as read by the IPC server but is not read there"
      end
    end
  end

  # --- the legacy composition ----------------------------------------------

  describe "supervision.legacy.json" do
    test "is the running legacy supervision tree" do
      legacy = fixture("supervision.legacy.json")

      refute Application.get_env(:ai_pair, :durable_attachments) == true,
             "this row measures the LEGACY branch; durable_attachments must not be enabled"

      assert legacy["strategy"] == "one_for_one"
      assert legacy["child_count"] == 8
      assert length(legacy["which_children_order"]) == 8

      running =
        AiPair.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _mods} -> inspect(id) end)

      assert running == legacy["which_children_order"],
             "the legacy supervision tree no longer matches the frozen table"
    end

    test "is the literal child list in lib/ai_pair/application.ex" do
      legacy = fixture("supervision.legacy.json")
      block = Enum.join(legacy["source_block"], "\n")

      assert length(legacy["source_block"]) == 8

      normalised =
        @application_source
        |> File.read!()
        |> String.split("\n")
        |> Enum.map_join("\n", &String.trim/1)

      occurrences = normalised |> String.split(block) |> length() |> Kernel.-(1)

      assert occurrences == 1,
             "the eight legacy children are no longer a single contiguous list in " <>
               "lib/ai_pair/application.ex (found #{occurrences} occurrences). The durable " <>
               "branch may be added beside this list, but the list itself is frozen."
    end

    test "the frozen source block really is the check: a single altered entry fails it" do
      legacy = fixture("supervision.legacy.json")

      normalised =
        @application_source
        |> File.read!()
        |> String.split("\n")
        |> Enum.map_join("\n", &String.trim/1)

      # Negative control for the row above: every one-entry mutation of the frozen
      # block is absent from the source, so a passing check is evidence and not an
      # accident of substring matching.
      for index <- 0..7 do
        mutated =
          legacy["source_block"]
          |> List.update_at(index, fn line -> "{AiPair.Mutated, []}," <> line end)
          |> Enum.join("\n")

        refute String.contains?(normalised, mutated)
      end

      # And a reordering of the list is absent too.
      reordered = legacy["source_block"] |> Enum.reverse() |> Enum.join("\n")
      refute String.contains?(normalised, reordered)
    end

    test "names what a legacy boot must NOT have" do
      legacy = fixture("supervision.legacy.json")
      inbox = Application.fetch_env!(:ai_pair, :inbox)

      assert length(legacy["absent"]) == 6

      assert :undefined == :global.whereis_name({AiPair.PaneIntentStore, Path.expand(inbox)})
      assert Process.whereis(AiPair.PaneRestore.Coordinator) == nil
      assert Process.whereis(AiPair.PaneRestore.Boot) == nil
      refute File.exists?(Path.join([inbox, "state", "boot-report.json"]))

      # The generation is never even fetched in legacy mode, so a legacy boot
      # cannot fail on a malformed one.
      assert Application.fetch_env(:ai_pair, :boot_generation) == :error
    end
  end

  # --- the durable composition ---------------------------------------------

  describe "supervision.durable.json" do
    test "declares eleven children in start order with the three new ones marked" do
      durable = fixture("supervision.durable.json")

      assert durable["strategy"] == "one_for_one"
      assert durable["child_count"] == 11
      assert durable["generation_validated_before_children"] == true
      assert length(durable["start_order"]) == 11

      assert Enum.map(durable["start_order"], & &1["position"]) == Enum.to_list(1..11)

      new_ids = for child <- durable["start_order"], child["new"], do: child["id"]

      assert new_ids == [
               "AiPair.PaneRestore.Coordinator",
               "AiPair.PaneIntentStore",
               "AiPair.PaneRestore.Boot"
             ]

      # Every child the legacy branch starts is still started, and none is dropped.
      legacy = fixture("supervision.legacy.json")
      durable_ids = Enum.map(durable["start_order"], & &1["id"])

      for id <- legacy["which_children_order"] do
        assert id in durable_ids, "the durable branch drops the legacy child #{id}"
      end
    end

    test "every declared restart type is the module's own" do
      durable = fixture("supervision.durable.json")

      # Every module named in the frozen table is referenced literally by
      # `child_spec_args/1` below, so its atom is in the table before this runs.
      for child <- durable["start_order"], child["module"] do
        module = String.to_existing_atom(child["module"])
        assert Code.ensure_loaded?(module), "#{child["module"]} is not a loadable module"
        spec = module.child_spec(child_spec_args(module))

        assert Map.get(spec, :restart, :permanent) == String.to_existing_atom(child["restart"]),
               "#{inspect(module)} declares restart #{child["restart"]} in the frozen table " <>
                 "but its own child_spec/1 says #{inspect(Map.get(spec, :restart, :permanent))}"
      end
    end

    test "the store child keeps its id and restart under the module substitution" do
      opts = [root: "/synthetic/inbox", fs: AiPair.PaneIntentStore.Fs.default()]
      base = Supervisor.child_spec({AiPair.PaneIntentStore, opts}, [])
      substituted = %{base | start: {__MODULE__, :start_link, [opts]}}

      # The rule the contract states and B5b relies on: only :start changes, so the
      # supervision child is still found by the id AiPair.PaneIntentStore whatever
      # module :pane_intent_store_module names.
      assert base.id == AiPair.PaneIntentStore
      assert substituted.id == AiPair.PaneIntentStore
      assert Map.get(base, :restart, :permanent) == :permanent
      assert Map.get(substituted, :restart, :permanent) == :permanent
      assert substituted.start == {__MODULE__, :start_link, [opts]}
      assert base.start == {AiPair.PaneIntentStore, :start_link, [opts]}
      assert Map.delete(base, :start) == Map.delete(substituted, :start)
    end

    test "every declared ordering edge is between two declared children" do
      durable = fixture("supervision.durable.json")
      positions = Map.new(durable["start_order"], &{&1["id"], &1["position"]})

      assert length(durable["edges"]) == 8

      for edge <- durable["edges"] do
        assert Enum.sort(Map.keys(edge)) == ~w(after before breaks why)
        assert Map.has_key?(positions, edge["before"]), "unknown child #{edge["before"]}"
        assert Map.has_key?(positions, edge["after"]), "unknown child #{edge["after"]}"

        assert positions[edge["before"]] < positions[edge["after"]],
               "the frozen start order contradicts the edge " <>
                 "#{edge["before"]} before #{edge["after"]}"

        assert is_binary(edge["why"]) and edge["why"] != ""
        assert is_binary(edge["breaks"]) and edge["breaks"] != ""
      end

      # The load-bearing edge is present and is the one the contract argues.
      assert Enum.any?(
               durable["edges"],
               &(&1["before"] == "AiPair.PaneRestore.Boot" and &1["after"] == "AiPair.IPC.Server")
             )
    end

    test "the fail-closed lists are disjoint and name the store and the generation" do
      durable = fixture("supervision.durable.json")
      closed = durable["fails_boot_closed"]
      open = durable["does_not_fail_boot"]

      assert closed != [] and open != []
      assert MapSet.disjoint?(MapSet.new(closed), MapSet.new(open))

      assert "the store child fails to start" in closed
      assert "boot_generation present and not a decimal string" in closed
      assert "project_binding absent or malformed" in open
      assert "the boot report cannot be written" in open
    end

    test "Boot is ready on return and owns the report path the edge depends on" do
      # The Boot-before-IPC edge is only meaningful because Boot.start_link/1
      # returns after the attempt settled. Both facts are checkable on main.
      assert exports?(AiPair.PaneRestore.Boot, :start_link, 1)
      assert exports?(AiPair.PaneRestore.Boot, :status, 1)

      assert AiPair.PaneRestore.Boot.report_path("/synthetic/inbox") ==
               "/synthetic/inbox/state/boot-report.json"
    end
  end

  # --- helpers --------------------------------------------------------------

  # Only used as an inert MFA term in the substitution row; never called.
  @doc false
  def start_link(_opts), do: {:error, :not_a_store}

  # `function_exported?/3` answers false for a module that is merely compiled and
  # not yet loaded, so the load is forced first.
  defp exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp keys_by_name do
    "configuration.keys.json" |> fixture() |> Map.fetch!("keys") |> Map.new(&{&1["key"], &1})
  end

  # One valid thirteen-key intent row, built from the store's own key list so it
  # cannot drift from what `Admission` accepts.
  defp record do
    values = %{
      "schema_version" => "1.0",
      "pane_id" => "%1",
      "agent" => "claude_code",
      "classifier" => "stub",
      "project" => "synthetic-project",
      "project_dir" => "/synthetic",
      "project_inbox" => "/synthetic",
      "tmux_session" => "synthetic",
      "session_gen" => "1",
      "cwd" => "/synthetic",
      "command" => "bash",
      "pane_pid" => 4321,
      "updated_at" => "2026-09-18T00:00:00Z"
    }

    keys = AiPair.PaneIntentStore.Record.record_keys()
    assert Enum.sort(keys) == Enum.sort(Map.keys(values)), "the record key set changed"
    values
  end

  defp config_findings(binding) do
    binding
    |> Admission.admit({:observed, []}, {:observed, []}, :unavailable)
    |> Map.fetch!(:issues)
    |> Enum.filter(&match?({:config_invalid, _}, &1))
  end

  # `child_spec/1` from `use GenServer` builds the map without starting anything,
  # so these arguments are inert. Every clause head names one of the four modules
  # the frozen durable table carries, which also puts their atoms in the table.
  defp child_spec_args(AiPair.PaneIntentStore), do: [root: "/synthetic/inbox"]
  defp child_spec_args(AiPair.PaneRestore.Boot), do: [root: "/synthetic/inbox"]
  defp child_spec_args(AiPair.PaneRestore.Coordinator), do: []
  defp child_spec_args(AiPair.IPC.Server), do: []

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
