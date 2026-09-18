defmodule AiPair.Contracts.TmuxMarkerContractTest do
  @moduledoc """
  Freezes the tmux session marker fixtures under `test/fixtures/contracts/tmux-marker`
  (contract: `docs/contracts/tmux-session-marker.org`). Each fixture holds the exact bytes
  `tmux show-options -v @ai_pair_session_incarnation` prints for that case: the option
  value followed by one newline. The bytes and `CONTRACT_HASH` are pinned under the v1 rule
  (sha256 over filename NUL bytes NUL, byte-sorted).

  Every fixture is fed verbatim through the byte-level reader, `AiPair.PaneRestore.Marker`
  (R04 S5: trim, ordered decode, duplicate key rejection, exact shape), by scripting a fake
  `tmux` whose `show-options` prints exactly the fixture bytes and calling `Marker.ensure/3`
  as this daemon's root: the three classes of the table are then `ensure`'s three answers,
  and no fixture may provoke a write. Independently, for every fixture that decodes to a
  unique-key document, the pure decision layer `AiPair.PaneRestore.Admission.admit/4` must
  reach the same finding when handed the decoded document as the marker source; the
  duplicate-key and non-JSON fixtures are also pinned at the decoder boundary, because they
  are the cases Marker must refuse before Admission ever sees them.
  """

  use ExUnit.Case, async: true

  alias AiPair.PaneRestore.Admission
  alias AiPair.PaneRestore.Marker
  alias AiPair.Test.ScriptedTmux

  @fixture_dir Path.expand("../../fixtures/contracts/tmux-marker", __DIR__)
  @hash_path Path.join(@fixture_dir, "CONTRACT_HASH")
  @pinned_hash "99385c1d56432285c74dc75d383f8c99eda9afc57b6b350afa62ff1b8498e02a"

  # The binding a consumer compares the marker against; `project_inbox` is the owner root.
  @binding %{
    project: "synthetic-project",
    project_dir: "/synthetic/inbox",
    project_inbox: "/synthetic/inbox"
  }

  # The four contract keys, and nothing else, become the marker's atom keys.
  @marker_keys %{
    "version" => :version,
    "owner_root" => :owner_root,
    "session_id" => :session_id,
    "generation" => :generation
  }

  # fixture -> expected classification (docs/contracts/tmux-session-marker.org, Fixtures).
  #   :ok                                  a usable same-owner marker
  #   {:marker_foreign, owner_root}        usable marker owned by another root
  #   {:marker_malformed, :not_json}       bytes are not a JSON document
  #   {:marker_malformed, :duplicate_key}  a JSON object key occurs twice
  #   {:marker_malformed, :shape}          decodes, but is not exactly the documented object
  @expected [
    {"marker.valid.json", :ok},
    {"marker.foreign_owner.json", {:marker_foreign, "/synthetic/elsewhere"}},
    {"marker.malformed.not_json.json", {:marker_malformed, :not_json}},
    {"marker.malformed.duplicate_key.json", {:marker_malformed, :duplicate_key}},
    {"marker.malformed.duplicate_owner_root.json", {:marker_malformed, :duplicate_key}},
    {"marker.malformed.not_object.json", {:marker_malformed, :shape}},
    {"marker.malformed.wrong_version.json", {:marker_malformed, :shape}},
    {"marker.malformed.missing_field.json", {:marker_malformed, :shape}},
    {"marker.malformed.extra_key.json", {:marker_malformed, :shape}}
  ]

  test "the tmux marker fixture set matches its pinned content hash" do
    paths = fixture_paths()

    assert length(paths) == length(@expected), "tmux marker fixture set is missing or incomplete"
    assert File.regular?(@hash_path), "tmux marker CONTRACT_HASH is missing"

    payload = Enum.map(paths, fn path -> [Path.basename(path), 0, File.read!(path), 0] end)
    actual = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)

    assert actual == @pinned_hash
    assert @hash_path |> File.read!() |> String.trim() == @pinned_hash
  end

  test "the classification table names every fixture exactly once" do
    assert Enum.map(@expected, &elem(&1, 0)) |> Enum.sort() ==
             fixture_paths() |> Enum.map(&Path.basename/1) |> Enum.sort()
  end

  # Every fixture through Marker's classifier: the fake tmux prints the fixture bytes for
  # `show-options`, and `ensure` as the synthetic root must answer the table's class from
  # that one read, without writing. A malformed finding carries the trimmed option value.
  for {name, expected} <- @expected do
    test "#{name} classifies as #{inspect(expected)} through Marker" do
      name = unquote(name)
      {server, dir} = ScriptedTmux.start!([{fixture_bytes(name), 0}])

      result =
        Marker.ensure(server, "$3", owner_root: @binding.project_inbox, generation: "1")

      assert marker_class(result, option_value(name)) == unquote(Macro.escape(expected))

      assert ScriptedTmux.calls!(dir) == 1,
             "a fixture provoked a write: #{inspect(ScriptedTmux.argvs!(dir))}"

      assert ScriptedTmux.argv!(dir, 1) == [
               "show-options",
               "-t",
               "$3",
               "-v",
               "@ai_pair_session_incarnation"
             ]
    end
  end

  # One test per fixture; the body is chosen by the expected class at compile time so
  # each row asserts only the boundary that decides it.
  for {name, expected} <- @expected do
    case expected do
      {:marker_malformed, :not_json} ->
        test "#{name} is refused by the JSON decoder" do
          assert {:error, _} = Jason.decode(option_value(unquote(name)), objects: :ordered_objects)
        end

      {:marker_malformed, :duplicate_key} ->
        test "#{name} carries a duplicate object key" do
          assert {:ok, %Jason.OrderedObject{values: pairs}} =
                   Jason.decode(option_value(unquote(name)), objects: :ordered_objects)

          keys = Enum.map(pairs, &elem(&1, 0))
          assert length(keys) != length(Enum.uniq(keys)), "fixture must carry a duplicate key"
        end

      _ ->
        test "#{name} classifies as #{inspect(expected)} through Admission" do
          assert {:ok, decoded} =
                   Jason.decode(option_value(unquote(name)), objects: :ordered_objects)

          assert admission_finding(decoded) == unquote(Macro.escape(expected))
        end
    end
  end

  # The exact fixture bytes: what `show-options -v` prints, newline included.
  defp fixture_bytes(name), do: @fixture_dir |> Path.join(name) |> File.read!()

  # Maps `Marker.ensure/3`'s answer onto the table's classes. A malformed finding must
  # carry the trimmed option value; its sub-class is decided at the decoder boundary
  # (not JSON, a duplicate key, or a decodable unique-key document of the wrong shape),
  # the same boundary the per-fixture rows below pin.
  defp marker_class(:ok, _raw), do: :ok
  defp marker_class({:error, {:marker_foreign, owner}}, _raw), do: {:marker_foreign, owner}

  defp marker_class({:error, {:marker_malformed, raw}}, raw) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:error, _} -> {:marker_malformed, :not_json}
      {:ok, %Jason.OrderedObject{values: pairs}} -> {:marker_malformed, unique_or_duplicate(pairs)}
      {:ok, _other} -> {:marker_malformed, :shape}
    end
  end

  defp marker_class(other, _raw), do: {:unexpected, other}

  defp unique_or_duplicate(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(keys) == length(Enum.uniq(keys)), do: :shape, else: :duplicate_key
  end

  # marker.ex trims the trailing newline show-options appends; the stored value
  # itself carries none.
  defp option_value(name) do
    value = @fixture_dir |> Path.join(name) |> File.read!() |> String.trim_trailing("\n")
    refute String.ends_with?(value, "\n")
    value
  end

  # Hands the decoded document to Admission as the marker source with empty intent and
  # census, and reads the single marker finding back; `[]` is a usable same-owner marker.
  defp admission_finding(decoded) do
    marker = marker_term(decoded)

    case Admission.admit(@binding, {:observed, []}, {:observed, []}, {:observed, marker}).issues do
      [] -> :ok
      [{:marker_foreign, owner}] -> {:marker_foreign, owner}
      [{:marker_malformed, _}] -> {:marker_malformed, :shape}
      other -> {:unexpected, other}
    end
  end

  defp marker_term(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    assert length(keys) == length(Enum.uniq(keys)), "unique-key fixtures only reach Admission"
    Map.new(pairs, fn {key, value} -> {Map.get(@marker_keys, key, key), value} end)
  end

  defp marker_term(other), do: other

  defp fixture_paths, do: @fixture_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
end
