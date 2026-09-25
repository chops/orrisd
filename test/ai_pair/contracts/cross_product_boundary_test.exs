defmodule AiPair.Contracts.CrossProductBoundaryTest do
  @moduledoc """
  NS-01.A.001, the Orrisd half of the failure control "Cross-product internal
  persistence/registry access rejected".

  Orrisd and Orris are separate products. Orrisd must not reach into Orris's
  internal modules, persistence files or registry. This file checks, from the
  Orrisd side, that no such reference is named in the places that make up the
  Orrisd build and runtime:

    1. Dependency. No dependency in `mix.exs` (its app name or any option, such
       as a git URL or path) and nothing in `mix.lock` names Orris or
       `ai_orchestrator`.

    2. Text. None of the Orris internal names below appears in the enumerated
       scanned surfaces:

         * `lib/**/*.ex`
         * `config/*.exs`
         * `mix.exs`
         * `rel/overlays/bin/*` (the release scripts)
         * `bin/*` (the repository scripts)
         * the Elixir and Bash files directly under `nix/files` (`*.ex`, `*.sh`)

       The names are pinned from Orris main
       `24eee05a3a081923c2e7c5e2e4a61b95e6c09ec9`:

         * `AiOrchestrator`: the Orris module namespace
         * `:ai_orchestrator`: the Orris OTP application
         * `events.jsonl`: the Orris event log file
         * `run.lock.`: the prefix of the Orris run lock files
         * `pane-claims`: the Orris pane-claim registry
         * `ai-orchestrator`: the Orris hyphenated name (paths, services)
         * `AI_ORCHESTRATOR_`: the Orris environment-variable prefix

       If Orris renames any of these, this list must be re-pinned. It does not
       follow Orris automatically.

    3. BEAM. For every compiled Orrisd module (a module in the `:ai_pair` ebin
       whose compile-time source is under `lib/`), the `imports` and `atoms`
       chunks are read with `:beam_lib`. If either chunk cannot be read, the test
       fails; that is not skipped. No imported module and no atom may begin with
       `Elixir.AiOrchestrator` or equal `:ai_orchestrator`. In the test
       environment the ebin also holds `test/support` modules (`elixirc_paths`).
       Those are test code, not Orrisd, and are excluded by their source path.

  Anti-vacuity. Each scanned set must contain named anchor files and meet a
  minimum count, so a moved directory or an empty glob fails instead of passing
  on nothing. The BEAM scan has anchor modules and a floor too. The file count is
  a floor, not an exact number. The text matcher, the dependency matcher and the
  BEAM matcher are each self-checked on in-memory inputs that must match and
  inputs that must not. The BEAM self-check also compiles a throwaway module
  that calls into the Orris namespace and requires the reader to find it. `test/`
  is not a scanned surface, so this file, which names every pinned string, cannot
  match itself.

  LIMITS. These are stated so the coverage is not overread:

    * This is a static absence check. The absence of named references in the
      enumerated surfaces is NOT a runtime access rejection. Nothing here shows
      that Orrisd would refuse or fail an attempt to touch Orris state at run time.
    * Dynamic references are not covered: a module name built at run time
      (`Module.concat/1`, `String.to_atom/1`), or a path or name taken from the
      environment, application config or a file at run time.
    * Surfaces NOT scanned:
        - the Nix entrypoints `flake.nix`, `devenv.nix` and `nix/*.nix` (the
          NixOS, nix-darwin, Home Manager and universal modules);
        - `nix/manifest.json`, and the non-Elixir, non-Bash files in `nix/files`
          (`*.md`, `*.org`, `*.json`);
        - `priv/`, `docs/` and `test/`;
        - `deps/` and the compiled dependencies. The dependency check covers
          only what `mix.exs` and `mix.lock` name.
      `docs/contracts/ipc-v1.org` and `ipc-v2.org` do name Orris modules, because
      they describe the consumer side of the IPC contract. That is documentation,
      outside the scanned set.
    * The names are a pinned list. A reference to an Orris internal that is not
      in the list is not detected.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # Pinned from Orris main 24eee05a3a081923c2e7c5e2e4a61b95e6c09ec9.
  @orris_internal_names [
    "AiOrchestrator",
    ":ai_orchestrator",
    "events.jsonl",
    "run.lock.",
    "pane-claims",
    "ai-orchestrator",
    "AI_ORCHESTRATOR_"
  ]

  # Each set: globs relative to the root, anchor files that must be found, and a
  # minimum count. Floors sit below the current counts on purpose.
  @surfaces [
    %{
      name: "lib",
      globs: ["lib/**/*.ex"],
      min: 30,
      anchors: ["lib/ai_pair/application.ex", "lib/ai_pair/pane/state_machine.ex"]
    },
    %{
      name: "config",
      globs: ["config/*.exs"],
      min: 3,
      anchors: ["config/config.exs", "config/test.exs", "config/runtime.exs"]
    },
    %{name: "mix.exs", globs: ["mix.exs"], min: 1, anchors: ["mix.exs"]},
    %{
      name: "rel scripts",
      globs: ["rel/overlays/bin/*"],
      min: 3,
      anchors: ["rel/overlays/bin/ai-pair"]
    },
    %{
      name: "bin scripts",
      globs: ["bin/*"],
      min: 3,
      anchors: ["bin/verify", "bin/redaction-check"]
    },
    %{
      name: "nix/files Elixir and Bash",
      globs: ["nix/files/*.ex", "nix/files/*.sh"],
      min: 6,
      anchors: ["nix/files/start-pair.sh", "nix/files/tooling.ex"]
    }
  ]

  @anchor_modules [AiPair.Application, AiPair.Pane.StateMachine, AiPair.IPC.Server]
  @min_modules 30

  # "orris" not followed by "d", not preceded by a letter or digit: matches
  # orris, Orris, orris_core and chops/orris, but not orrisd or Orrisd.
  @orris_dep ~r/(?<![a-z0-9])orris(?!d)/i

  # ------------------------------------------------------------ matchers

  defp text_hits(text), do: Enum.filter(@orris_internal_names, &String.contains?(text, &1))

  defp dep_hit?(text), do: Regex.match?(@orris_dep, text) or text =~ ~r/ai[_-]orchestrator/

  defp orris_atom?(atom) when is_atom(atom) do
    name = Atom.to_string(atom)
    atom == :ai_orchestrator or String.starts_with?(name, "Elixir.AiOrchestrator")
  end

  describe "matcher self-checks" do
    test "the text matcher finds every pinned name and ignores Orrisd's own" do
      for name <- @orris_internal_names do
        assert text_hits("x = #{name}suffix") == [name]
      end

      assert text_hits("~/.local/state/orris/events.jsonl") == ["events.jsonl"]
      assert text_hits("AiPair.Pane.StateMachine :ai_pair ai-pair AI_PAIR_INBOX") == []
    end

    test "the dependency matcher finds Orris and ai_orchestrator but not Orrisd" do
      for hit <- [
            ~s({:orris, "~> 1.0"}),
            ~s({:orris_core, git: "x"}),
            ~s(git: "https://github.com/chops/orris.git"),
            ~s("Orris"),
            ~s({:ai_orchestrator, path: "../x"}),
            ~s("ai-orchestrator")
          ] do
        assert dep_hit?(hit), "expected a hit on #{hit}"
      end

      for miss <- [
            ~s(source_url: "https://github.com/chops/orrisd"),
            "Orrisd",
            ~s({:jason, "~> 1.4"})
          ] do
        refute dep_hit?(miss), "expected no hit on #{miss}"
      end
    end

    test "the atom matcher finds the Orris namespace and application only" do
      assert orris_atom?(AiOrchestrator)
      assert orris_atom?(AiOrchestrator.Dispatch.PaneClient)
      assert orris_atom?(:ai_orchestrator)

      refute orris_atom?(AiPair.Application)
      refute orris_atom?(:ai_pair)
      refute orris_atom?(:ai_orchestrator_extra)
    end

    test "the BEAM reader finds an Orris import and atom in a compiled module" do
      mod =
        :"Elixir.AiPair.Contracts.CrossProductBoundaryTest.Probe#{System.unique_integer([:positive])}"

      source = """
      defmodule #{inspect(mod)} do
        def call, do: AiOrchestrator.Dispatch.PaneClient.send(:ai_orchestrator)
      end
      """

      {[{^mod, binary}], _diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(source) end)

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
      end)

      {imports, atoms} = read_chunks!(binary)

      assert Enum.any?(imports, fn {m, _f, _a} -> orris_atom?(m) end)
      assert Enum.any?(atoms, &orris_atom?/1)
      assert :ai_orchestrator in atoms
    end
  end

  # ------------------------------------------------------------ 1. dependency

  describe "dependency" do
    test "no mix.exs dependency names Orris or ai_orchestrator" do
      deps = Mix.Project.config()[:deps]
      assert deps != []

      for dep <- deps do
        refute dep_hit?(inspect(dep, limit: :infinity, printable_limit: :infinity)),
               "mix.exs declares a dependency naming Orris: #{inspect(dep)}"
      end
    end

    test "mix.lock names neither Orris nor ai_orchestrator" do
      lock = File.read!(Path.join(@root, "mix.lock"))
      assert lock =~ ~s("jason":), "mix.lock does not look like the lockfile"

      refute dep_hit?(lock),
             "mix.lock names Orris: #{inspect(Regex.run(@orris_dep, lock) || Regex.run(~r/ai[_-]orchestrator/, lock))}"
    end
  end

  # ------------------------------------------------------------ 2. text

  describe "text" do
    for surface <- @surfaces do
      @surface surface

      test "#{surface.name}: anchors present, floor met, no Orris internal names" do
        files = surface_files(@surface)

        for anchor <- @surface.anchors do
          assert anchor in files,
                 "#{@surface.name}: anchor #{anchor} not found in #{inspect(files)}"
        end

        assert length(files) >= @surface.min,
               "#{@surface.name}: #{length(files)} files, floor #{@surface.min}"

        refute Enum.any?(files, &String.starts_with?(&1, "test/"))

        hits =
          for file <- files,
              hits = text_hits(File.read!(Path.join(@root, file))),
              hits != [],
              do: {file, hits}

        assert hits == []
      end
    end
  end

  defp surface_files(surface) do
    surface.globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ------------------------------------------------------------ 3. BEAM

  describe "BEAM" do
    test "no compiled Orrisd module imports or names the Orris namespace or application" do
      modules = orrisd_modules()

      for anchor <- @anchor_modules do
        assert anchor in modules, "anchor module #{inspect(anchor)} not scanned"
      end

      assert length(modules) >= @min_modules,
             "#{length(modules)} Orrisd modules scanned, floor #{@min_modules}"

      hits =
        for mod <- modules,
            {imports, atoms} = read_chunks!(beam_path!(mod)),
            bad_imports = for({m, f, a} <- imports, orris_atom?(m), do: {m, f, a}),
            bad_atoms = Enum.filter(atoms, &orris_atom?/1),
            bad_imports != [] or bad_atoms != [],
            do: {mod, bad_imports, bad_atoms}

      assert hits == []
    end
  end

  # Modules in the :ai_pair application whose compile-time source is under lib/.
  defp orrisd_modules do
    {:ok, modules} = :application.get_key(:ai_pair, :modules)
    lib = Path.join(@root, "lib") <> "/"

    Enum.filter(modules, fn mod ->
      source = mod.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
      String.starts_with?(Path.expand(source), lib)
    end)
  end

  defp beam_path!(mod) do
    case :code.which(mod) do
      path when is_list(path) -> path
      other -> flunk("no BEAM file for #{inspect(mod)}: #{inspect(other)}")
    end
  end

  # Unreadable chunks fail the test; they are never treated as "no references".
  defp read_chunks!(beam) do
    case :beam_lib.chunks(beam, [:imports, :atoms]) do
      {:ok, {_mod, [imports: imports, atoms: atoms]}} when is_list(imports) and is_list(atoms) ->
        {imports, Enum.map(atoms, fn {_index, atom} -> atom end)}

      other ->
        flunk("imports/atoms chunks unreadable: #{inspect(other)}")
    end
  end
end
