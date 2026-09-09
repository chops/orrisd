{
  description = "Orrisd: agent coordination runtime (Elixir/OTP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e8be7818e19ada32105a8af937a6a473b38167ca";
    devenv.url = "github:cachix/devenv/v1.11.2";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = inputs@{ self, nixpkgs, devenv, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      version = "0.1.0";

      mkAiPair = pkgs:
        let
          beamPackages = pkgs.beam.packages.erlang_29.overrideScope (final: prev: {
            elixir = prev.elixir_1_20;
          });
          src = builtins.path {
            path = ./.;
            name = "ai-pair-source";
            # Excluding _build/deps/.elixir_ls keeps the FOD input
            # deterministic across local dev rebuilds.
            filter = path: type:
              let base = baseNameOf path; in
              !(base == "_build" || base == "deps" || base == ".elixir_ls");
          };
        in
        beamPackages.mixRelease {
          pname = "ai-pair";
          inherit version src;
          meta.license = pkgs.lib.licenses.asl20;

          # mix.exs writes a deterministic cookie via a :steps callback.
          # We never enable Erlang distribution (UDS-only IPC), so the
          # cookie value is not secret — keep the file so `bin/ai_pair`
          # doesn't fail with `cat: releases/COOKIE: No such file`.
          removeCookie = false;

          mixFodDeps = beamPackages.fetchMixDeps {
            pname = "mix-deps-ai-pair";
            inherit version src;
            hash = "sha256-LdIpt1YHFQjnacyASDNhnA6wjC4K7LddJVYN2tu+Zxk=";
          };

          # Service modules resolve the bridge through the daemon package.
          # Include it in the release closure as well as the CLI package.
          postInstall = ''
            install -Dm755 ${./nix/files/ap-bridge.sh} $out/bin/ap-bridge
          '';
        };
    in
    {
      packages = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = mkAiPair pkgs;

          # Canonical runtime contract. Modules (nix-darwin / home-manager)
          # should consume `inputs.ai-pair + "/nix/manifest.json"` directly
          # to avoid IFD; this output is for ad-hoc inspection.
          manifest = pkgs.runCommandLocal "ai-pair-manifest" { } ''
            install -D ${./nix/manifest.json} $out/share/ai-pair/manifest.json
          '';

          # User-facing CLI (`ap` + `start-pair`). The home-manager
          # universal-adoption module installs these via home.packages;
          # this output exists for `nix run`/`nix shell` use too.
          ap = pkgs.runCommandLocal "ai-pair-user-cli" {
            meta.license = pkgs.lib.licenses.asl20;
          } ''
            install -Dm755 ${./nix/files/ap.sh}          $out/bin/ap
            install -Dm755 ${./nix/files/start-pair.sh}  $out/bin/start-pair
            install -Dm755 ${./nix/files/ap-bridge.sh}   $out/bin/ap-bridge
            install -Dm755 ${./nix/files/gemini-otel.sh} $out/bin/gemini-otel
          '';

          devenv-up = self.devShells.${system}.default.config.procfileScript;
        });

      checks = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          start-pair-launch-path = pkgs.runCommand "start-pair-launch-path-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
          } ''
            bash ${./test/start_pair_launch_path_test.sh} ${./nix/files/start-pair.sh}
            touch "$out"
          '';

          ap-project-resolution = pkgs.runCommand "ap-project-resolution-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
          } ''
            bash ${./test/ap_project_resolution_test.sh} ${./nix/files/ap.sh} ${./nix/files/start-pair.sh}
            touch "$out"
          '';

          gemini-otel-provider-sampling = pkgs.runCommand "gemini-otel-provider-sampling-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.gawk pkgs.gnugrep pkgs.jq ];
          } ''
            bash ${./test/gemini_otel_provider_sampling_test.sh} ${./nix/files/gemini-otel.sh}
            touch "$out"
          '';
        });

      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [ ./devenv.nix ];
          };
        });

      # nix-darwin module: launchd user agent for the watcher daemon.
      # Consumers wire `inputs.ai-pair.packages.${system}.default` into
      # `services.ai-pair.package` so binary + unit ship together.
      darwinModules.ai-pair = ./nix/darwin-module.nix;
      darwinModules.default = ./nix/darwin-module.nix;

      # home-manager module: systemd user unit equivalent of the darwin
      # launchd agent. Per-user, so no `user`/`home` options. Requires
      # `loginctl enable-linger $USER` to survive logout.
      homeManagerModules.ai-pair = ./nix/home-manager-module.nix;
      homeManagerModules.default = ./nix/home-manager-module.nix;

      # NixOS module: system-level systemd unit running the watcher as
      # `services.ai-pair.user`. Sibling to the home-manager module for
      # hosts that provision the daemon user through their system configuration
      # rather than Home Manager.
      nixosModules.ai-pair = ./nix/nixos-module.nix;
      nixosModules.default = ./nix/nixos-module.nix;

      # home-manager module: universal-adoption surface — installs the
      # `ap` CLI, the `use_ai_pair` direnv layout, optional launchd
      # rotators on darwin, and splices managed marker blocks into
      # ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md. Distinct namespace
      # (`programs.ai-pair-user`) from the Linux daemon module above so
      # both can be imported simultaneously on a host without clobber.
      homeManagerModules.ai-pair-user = ./nix/home-universal-module.nix;

      # Helper for direnv .envrc: `use ai_pair`.
      lib.useAiPair = ./nix/files/use_ai_pair.sh;
    };
}
