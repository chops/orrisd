# Flake check: the home-manager universal module (flake output
# `homeManagerModules.ai-pair-user`) installs this flake's own
# `packages.${system}.ap` and never reads the consumer's BEAM set.
#
# Orrisd has no home-manager input and this check does not add one, and
# adding a second nixpkgs input only for a check is out of scope. So the
# module is evaluated with `lib.evalModules` against:
#   * option stubs for the few home-manager options it defines into, plus a
#     stub `lib.hm.dag.entryAfter`; and
#   * a synthetic consumer `pkgs`: the pinned package set with every
#     top-level `beam*`, `elixir*`, `erlang*` and `rebar*` attribute
#     replaced by `throw`.
# Forcing the module outputs therefore aborts evaluation if the module or
# its flake wrapper reads any of those attributes from the consumer `pkgs`.
# This approximates a consumer nixpkgs whose BEAM set is unusable (the
# release-candidate case); it is not an evaluation against a second nixpkgs
# revision, and it does not build anything.
{ self, nixpkgs, system }:

let
  selfPkgs = nixpkgs.legacyPackages.${system};

  lib = nixpkgs.lib.extend (final: prev: {
    hm.dag.entryAfter = after: data: { inherit after data; };
  });

  isBeamName = n:
    lib.hasPrefix "beam" n || lib.hasPrefix "elixir" n
    || lib.hasPrefix "erlang" n || lib.hasPrefix "rebar" n;

  beamNames = builtins.filter isBeamName (builtins.attrNames selfPkgs);

  consumerPkgs = selfPkgs // lib.genAttrs beamNames (n:
    throw "hm-ap-self-package: the module read consumer pkgs.${n}");

  hmStubs = { lib, ... }: {
    options = {
      home.homeDirectory = lib.mkOption { type = lib.types.str; };
      home.packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      home.file = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      home.sessionVariables = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      home.activation = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      launchd.agents = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
    };
    config.home.homeDirectory = "/var/empty/hm-ap-self-package";
  };

  evalHm = extra: (lib.evalModules {
    specialArgs = { inherit lib; pkgs = consumerPkgs; };
    modules = [
      hmStubs
      self.homeManagerModules.ai-pair-user
      { programs.ai-pair-user.enable = true; }
    ] ++ extra;
  }).config;

  ap = self.packages.${system}.ap;

  cfgDefault = evalHm [ ];
  installed = cfgDefault.home.packages;

  # Every non-package output of the module, forced in full. None of these
  # hold derivations (store paths only appear as strings), so deepSeq is
  # bounded.
  otherOutputs = {
    inherit (cfgDefault.home) file sessionVariables activation;
    inherit (cfgDefault.launchd) agents;
  };

  overridePkg = selfPkgs.runCommandLocal "hm-ap-self-package-override" { } ''
    mkdir "$out"
  '';
  overrideInstalled = (evalHm [
    { programs.ai-pair-user.package = overridePkg; }
  ]).home.packages;

  contextKeys = p: builtins.attrNames (builtins.getContext (p.buildCommand or ""));
  rcPattern = ".*-(elixir|erlang)-[0-9][^/]*rc[^/]*";
  rcRefs = builtins.filter (k: builtins.match rcPattern k != null)
    (lib.concatMap contextKeys installed);

  selfElixir = selfPkgs.beam.packages.erlang_29.elixir_1_20;
  selfErlang = selfPkgs.beam.interpreters.erlang_29;
  isRc = v: builtins.match ".*rc.*" v != null;
in
assert lib.assertMsg (builtins.elem "beam" beamNames)
  "negative control: pkgs.beam is not among the replaced consumer attributes";
assert lib.assertMsg (!(builtins.tryEval (builtins.seq consumerPkgs.beam true)).success)
  "negative control: synthetic consumer pkgs.beam did not throw";
assert lib.assertMsg (builtins.length installed == 2)
  "home.packages is not exactly [ ap peer-protocol-docs ]";
assert lib.assertMsg ((builtins.head installed).drvPath == ap.drvPath)
  "home.packages CLI drvPath differs from self.packages.${system}.ap";
assert lib.assertMsg ((builtins.head installed).outPath == ap.outPath)
  "home.packages CLI outPath differs from self.packages.${system}.ap";
assert lib.assertMsg ((builtins.elemAt installed 1).name == "ai-pair-peer-protocol")
  "second home.packages entry is not the peer-protocol docs";
assert lib.assertMsg (builtins.deepSeq otherOutputs true)
  "module outputs other than home.packages did not evaluate";
assert lib.assertMsg (builtins.elem selfElixir.drvPath (contextKeys ap))
  "witness: ap does not reference the pinned beam.packages.erlang_29.elixir_1_20";
assert lib.assertMsg (rcRefs == [ ])
  "home.packages references a release-candidate elixir or erlang derivation";
assert lib.assertMsg (!(isRc selfElixir.version))
  "pinned Elixir ${selfElixir.version} is a release candidate";
assert lib.assertMsg (!(isRc selfErlang.version))
  "pinned Erlang ${selfErlang.version} is a release candidate";
assert lib.assertMsg ((builtins.head overrideInstalled).drvPath == overridePkg.drvPath)
  "programs.ai-pair-user.package override did not take effect";
assert lib.assertMsg (!(builtins.elem ap.drvPath (map (p: p.drvPath) overrideInstalled)))
  "self ap still installed after programs.ai-pair-user.package override";
selfPkgs.runCommandLocal "hm-ap-self-package-check" { } ''
  touch "$out"
''
