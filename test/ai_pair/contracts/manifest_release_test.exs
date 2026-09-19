defmodule AiPair.Contracts.ManifestReleaseTest do
  @moduledoc """
  Binds `nix/manifest.json` to the release it describes.

  The manifest is the canonical runtime contract. Three Nix modules read it with
  `builtins.fromJSON` and build launchd/systemd units out of it
  (`nix/darwin-module.nix:6-9` and siblings, which resolve
  `manifest.executables.watch.path` against the release package), `ap doctor`
  implements its healthcheck by hand (`nix/files/ap.sh`), and `mix.exs` copies
  the file into the release at `share/ai-pair/manifest.json` through the
  `copy_manifest/1` release step.

  Nothing asserted that any of that agreed. A declared executable could name a
  path the release does not contain, and the installed unit would then fail at
  activation on the operator's machine rather than here; the manifest version
  could drift from the Mix version that names the release directory. Both are
  checked below against the real `Mix.Project.config/0` and the real
  `rel/overlays` tree.

  The set equality in "no undeclared executable ships" is deliberate: the
  release copies `rel/overlays` wholesale, so an overlay binary that the
  manifest does not declare is an executable surface no module and no operator
  tool knows about. Adding one is allowed; adding one silently is not.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @manifest_path Path.join([@root, "nix", "manifest.json"])
  @overlay_dir Path.join([@root, "rel", "overlays"])

  setup_all do
    assert File.regular?(@manifest_path), "nix/manifest.json is missing"
    {:ok, manifest: @manifest_path |> File.read!() |> Jason.decode!()}
  end

  test "the manifest version is the Mix version the release is built from", %{manifest: manifest} do
    mix_version = Mix.Project.config()[:version]

    assert is_binary(mix_version)

    assert manifest["version"] == mix_version,
           "nix/manifest.json declares version #{inspect(manifest["version"])} but mix.exs " <>
             "builds #{inspect(mix_version)}; the installed release directory and the " <>
             "manifest shipped inside it would disagree"
  end

  test "the manifest name is the Mix application name", %{manifest: manifest} do
    assert manifest["name"] == "ai-pair"
    assert Mix.Project.config()[:app] == :ai_pair
  end

  test "every declared executable exists in the release overlay and is executable", %{
    manifest: manifest
  } do
    executables = manifest["executables"]

    assert is_map(executables) and map_size(executables) > 0,
           "the manifest declares no executables"

    for {role, declaration} <- executables do
      path = declaration["path"]

      assert is_binary(path), "executable #{role} declares no path"

      refute String.starts_with?(path, "/"),
             "executable #{role} declares an absolute path #{path}; modules join it onto the " <>
               "release package prefix"

      assert String.starts_with?(path, "bin/"),
             "executable #{role} declares #{path}, which is outside the release bin directory"

      on_disk = Path.join(@overlay_dir, path)

      assert File.regular?(on_disk),
             "manifest executable #{role} declares #{path}, which is not in rel/overlays"

      %File.Stat{mode: mode} = File.stat!(on_disk)

      assert Bitwise.band(mode, 0o111) != 0,
             "manifest executable #{role} declares #{path}, which ships without an execute bit"

      assert is_list(declaration["args"]),
             "manifest executable #{role} declares no args list"
    end
  end

  test "no undeclared executable ships in the release overlay", %{manifest: manifest} do
    declared =
      manifest["executables"]
      |> Map.values()
      |> Enum.map(& &1["path"])
      |> MapSet.new()

    shipped =
      [@overlay_dir, "bin", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(fn path -> Path.join("bin", Path.basename(path)) end)
      |> MapSet.new()

    assert MapSet.equal?(declared, shipped),
           "rel/overlays and nix/manifest.json disagree: undeclared #{inspect(MapSet.to_list(MapSet.difference(shipped, declared)))}, " <>
             "declared but absent #{inspect(MapSet.to_list(MapSet.difference(declared, shipped)))}"
  end

  test "the release still carries the overlay directory this test measures" do
    release = Mix.Project.config()[:releases][:ai_pair]

    assert release[:overlays] == ["rel/overlays"],
           "the ai_pair release no longer copies rel/overlays, so the executables asserted " <>
             "above would not reach the installed package"
  end

  test "the healthcheck socket lives in a declared state directory", %{manifest: manifest} do
    healthcheck = manifest["daemon"]["healthcheck"]
    state_dirs = manifest["daemon"]["required_state_dirs"]

    assert is_list(state_dirs) and state_dirs != []
    assert healthcheck["type"] == "uds-json-ping"
    assert is_integer(healthcheck["timeout_ms"]) and healthcheck["timeout_ms"] > 0

    socket_dir =
      healthcheck["socket"]
      |> Path.dirname()
      |> Path.basename()

    assert socket_dir in state_dirs,
           "the healthcheck socket is under #{socket_dir}/, which the manifest does not list " <>
             "in required_state_dirs #{inspect(state_dirs)}, so an install would create the " <>
             "state dirs and still have nowhere to put the socket"
  end
end
