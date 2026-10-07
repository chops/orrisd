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
      # The pinned nixpkgs (26.11) has dropped x86_64-darwin, so declaring it
      # here made every x86_64-darwin output an evaluation error rather than a
      # package. Orris pins the same nixpkgs rev and declares the same three.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      version = "0.1.0";

      # One binding for the mix dependency hash: fetchMixDeps and (RB-1 C3) the build identity
      # read the same string, so they cannot drift.
      mixDepsHash = "sha256-LdIpt1YHFQjnacyASDNhnA6wjC4K7LddJVYN2tu+Zxk=";

      # The Elixir the RB-1 C3 check helpers run under (the CLI package's pin).
      elixirFor = pkgs: pkgs.beam.packages.erlang_29.elixir_1_20;

      # NS-32.M.001 RB-1: the build identity, an INPUT identity (never the build's own output):
      # build_id is the sha256 of these "key=value\n" lines in this order. Rebuilding the same
      # inputs on the same system gives the same record. A tree without a revision (dirty) records
      # source_revision null, clean false, rollback_eligible false.
      buildIdentityFor = { rev, narHash, system }:
        let
          canonical = nixpkgs.lib.concatMapStrings ({ key, value }: "${key}=${value}\n") [
            { key = "name"; value = "ai-pair"; }
            { key = "version"; value = version; }
            { key = "source_nar_hash"; value = narHash; }
            { key = "flake_lock_sha256"; value = builtins.hashFile "sha256" ./flake.lock; }
            { key = "mix_deps_hash"; value = mixDepsHash; }
            { key = "system"; value = system; }
            { key = "release_name"; value = "ai_pair"; }
            { key = "ipc_protocols"; value = "1,2,3"; }
          ];
        in
        {
          name = "ai-pair";
          inherit version;
          source_revision = rev;
          clean = rev != null;
          source_nar_hash = narHash;
          build_id = builtins.hashString "sha256" canonical;
          ipc_protocols = [ 1 2 3 ];
          rollback_eligible = rev != null;
        };

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
          # NS-32.M.001 RB-1: the stamped record and the manifest with its identity object, both
          # rendered by builtins.toJSON (sorted keys, no timestamps).
          identity = buildIdentityFor {
            rev = self.rev or null;
            narHash = self.narHash;
            system = pkgs.stdenv.hostPlatform.system;
          };
          identityFile = pkgs.writeText "build-identity.json" (builtins.toJSON identity);
          manifestFile = pkgs.writeText "manifest.json" (builtins.toJSON (
            builtins.fromJSON (builtins.readFile ./nix/manifest.json) // { inherit identity; }
          ));
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
            hash = mixDepsHash;
          };

          # Service modules resolve the bridge through the daemon package.
          # Include it in the release closure as well as the CLI package.
          postInstall = ''
            install -Dm755 ${./nix/files/ap-bridge.sh} $out/bin/ap-bridge
            install -Dm644 ${./nix/files/tooling.ex} $out/bin/tooling.ex
            substituteInPlace $out/bin/ap-bridge --replace-fail 'elixir -r' '${beamPackages.elixir}/bin/elixir -r'
            # RB-1: the identity record, and the manifest copy_manifest/1 wrote, now with its identity.
            install -Dm644 ${identityFile} $out/share/ai-pair/build-identity.json
            install -Dm644 ${manifestFile} $out/share/ai-pair/manifest.json
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
            install -Dm644 ${./nix/files/tooling.ex} $out/bin/tooling.ex
            install -Dm644 ${./nix/files/telemetry-batch.ex} $out/bin/telemetry-batch.ex
            substituteInPlace $out/bin/ap $out/bin/start-pair $out/bin/ap-bridge $out/bin/gemini-otel \
              --replace-fail 'elixir -r' '${pkgs.beam.packages.erlang_29.elixir_1_20}/bin/elixir -r'
            substituteInPlace $out/bin/ap $out/bin/start-pair \
              --replace-fail 'sha256sum' '${pkgs.coreutils}/bin/sha256sum'
            substituteInPlace $out/bin/start-pair --replace-fail 'command -v elixir' \
              'test -x ${pkgs.beam.packages.erlang_29.elixir_1_20}/bin/elixir'
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

          start-pair-trustgate-regex = pkgs.runCommand "start-pair-trustgate-regex-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ];
          } ''
            bash ${./test/start_pair_trustgate_regex_test.sh} ${./nix/files/start-pair.sh} ${./test/fixtures/fingerprints}
            touch "$out"
          '';

          ap-project-resolution = pkgs.runCommand "ap-project-resolution-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.beam.packages.erlang_29.elixir_1_20 ];
          } ''
            bash ${./test/ap_project_resolution_test.sh} ${./nix/files/ap.sh} ${./nix/files/start-pair.sh} ${./nix/files/tooling.ex}
            touch "$out"
          '';

          ap-doctor = pkgs.runCommand "ap-doctor-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.beam.packages.erlang_29.elixir_1_20 ];
          } ''
            bash ${./test/ap_doctor_test.sh} ${./nix/files/ap.sh} ${./nix/files/start-pair.sh} ${./nix/files/tooling.ex}
            touch "$out"
          '';

          gemini-otel-provider-sampling = pkgs.runCommand "gemini-otel-provider-sampling-test" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.gnugrep pkgs.beam.packages.erlang_29.elixir_1_20 ];
          } ''
            bash ${./test/gemini_otel_provider_sampling_test.sh} ${./nix/files/gemini-otel.sh} ${./nix/files/telemetry-batch.ex}
            touch "$out"
          '';

          hm-ap-self-package = import ./nix/hm-ap-self-package-check.nix {
            inherit self nixpkgs system;
          };

          # NS-32.M.001 RB-1 C3: the stamped build identity (nix/checks/rb1_build_identity_check.exs).
          # N1: the package's record equals an independent recompute from this flake's inputs, and
          # the manifest's identity object equals it.
          rb1-n1-stamped-identity = pkgs.runCommand "rb1-n1-stamped-identity" {
            nativeBuildInputs = [ (elixirFor pkgs) ];
          } ''
            export HOME=$TMPDIR
            elixir ${./nix/checks/rb1_build_identity_check.exs} n1 \
              ${self.packages.${system}.default} '${version}' '${self.rev or ""}' '${self.narHash}' \
              '${builtins.hashFile "sha256" ./flake.lock}' '${mixDepsHash}' '${system}'
            touch "$out"
          '';

          # N2: two distinct release derivations (an inert RB1_BUILD_INSTANCE makes both really
          # build; same store, no isolated-store claim) stamp byte-identical identity and manifest.
          rb1-n2-two-builds =
            let
              instance = tag: (mkAiPair pkgs).overrideAttrs (_: { RB1_BUILD_INSTANCE = tag; });
              a = instance "a";
              b = instance "b";
            in
            pkgs.runCommand "rb1-n2-two-builds" {
              nativeBuildInputs = [ pkgs.diffutils ];
            } ''
              echo "N2 a=${a} b=${b}"
              cmp ${a}/share/ai-pair/build-identity.json ${b}/share/ai-pair/build-identity.json
              cmp ${a}/share/ai-pair/manifest.json ${b}/share/ai-pair/manifest.json
              touch "$out"
            '';

          # N3: the identity function's dirty shape (synthetic: CI checks out a clean tree).
          # An absent function is a BUILD-time failure: it is tested before any call, so
          # evaluation (`nix flake check --no-build`) stays valid.
          rb1-n3-dirty-shape =
            let
              f = self.lib.buildIdentity or null;
              shapeOk =
                let
                  dirty = f { rev = null; narHash = self.narHash; inherit system; };
                  clean = f { rev = "0123456789abcdef0123456789abcdef01234567"; narHash = self.narHash; inherit system; };
                in
                dirty.source_revision == null
                && dirty.clean == false
                && dirty.rollback_eligible == false
                && clean.rollback_eligible == true
                && dirty.build_id == clean.build_id;
              script =
                if f == null then ''echo "N3: lib.buildIdentity is absent" >&2; exit 1''
                else if shapeOk then ''touch "$out"''
                else ''echo "N3: the dirty shape is wrong" >&2; exit 1'';
            in
            pkgs.runCommand "rb1-n3-dirty-shape" { } script;

          # N4: the built release, evaluated without activation, resolves :code.root_dir() to the
          # package and its default reader returns the stamped record there.
          rb1-n4-release-root = pkgs.runCommand "rb1-n4-release-root" {
            nativeBuildInputs = [ (elixirFor pkgs) ];
          } ''
            export HOME=$TMPDIR
            pkg=${self.packages.${system}.default}
            "$pkg/bin/ai_pair" eval 'Code.eval_file("${./nix/checks/rb1_n4_eval.exs}")' > "$TMPDIR/n4.out"
            elixir ${./nix/checks/rb1_build_identity_check.exs} n4 "$pkg" "$TMPDIR/n4.out"
            touch "$out"
          '';
        } // (
          # NS-32.M.002 RB-2b: the manifest's "reads" stamp (nix/checks/rb2b_reads_check.exs). Each
          # evaluates the built release without activation (nix/checks/rb2b_eval.exs), then:
          # N1, the stamp equals the release's own AiPair.Compat.reads/0 as canonical JSON;
          # N2, the stamp is exactly a declaration and a fresh inbox is :supported against it;
          # N3, negative control: a drifted synthetic stamp is refused by N1's comparison, by name.
          let
            rb2b = n: name: pkgs.runCommand name {
              nativeBuildInputs = [ (elixirFor pkgs) ];
            } ''
              export HOME=$TMPDIR
              pkg=${self.packages.${system}.default}
              "$pkg/bin/ai_pair" eval 'Code.eval_file("${./nix/checks/rb2b_eval.exs}")' > "$TMPDIR/rb2b.out"
              elixir ${./nix/checks/rb2b_reads_check.exs} ${n} "$pkg" "$TMPDIR/rb2b.out"
              touch "$out"
            '';
          in
          {
            rb2b-n1-reads-stamp = rb2b "n1" "rb2b-n1-reads-stamp";
            rb2b-n2-declaration-shape = rb2b "n2" "rb2b-n2-declaration-shape";
            rb2b-n3-drift-refused = rb2b "n3" "rb2b-n3-drift-refused";
          }
        ));

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
      #
      # The CLI defaults to this flake's own `packages.${system}.ap`, built
      # from the pinned nixpkgs above, never from the consumer's `pkgs.beam`
      # (a consumer nixpkgs can carry release-candidate Elixir/OTP that
      # nixpkgs refuses to combine). mkDefault keeps it overridable.
      homeManagerModules.ai-pair-user = { lib, pkgs, ... }: {
        imports = [ ./nix/home-universal-module.nix ];
        programs.ai-pair-user.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.ap;
      };

      # Helper for direnv .envrc: `use ai_pair`.
      lib.useAiPair = ./nix/files/use_ai_pair.sh;

      # NS-32.M.001 RB-1: the build identity function (checked by rb1-n3-dirty-shape).
      lib.buildIdentity = buildIdentityFor;
    };
}
