{ config, lib, pkgs, ... }:

let
  cfg = config.services.ai-pair;

  manifest = builtins.fromJSON (builtins.readFile ./manifest.json);
  watchExe = manifest.executables.watch.path;
  serviceName = manifest.daemon.service_name;
  stateDirs = manifest.daemon.required_state_dirs;

  serviceLabel = "dev.fxo.${serviceName}";
in
{
  options.services.ai-pair = {
    enable = lib.mkEnableOption "ai-pair tmux watcher daemon (launchd user agent)";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The ai-pair release package built by the flake (typically
        `inputs.ai-pair.packages.''${system}.default`).
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Username that owns the launchd agent. Determines $HOME and
        the inbox directory default.
      '';
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/Users/${cfg.user}";
      defaultText = lib.literalExpression ''"/Users/''${cfg.user}"'';
      description = "Home directory of the user running the agent.";
    };

    inboxDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.home}/.ai-agent-inbox/ai-pair";
      defaultText = lib.literalExpression ''"''${cfg.home}/.ai-agent-inbox/ai-pair"'';
      description = ''
        Runtime state root. The daemon creates `sock/`, `fingerprints/`,
        `logs/`, `state/` underneath. Exposed to the daemon as
        `$AI_PAIR_INBOX`.
      '';
    };

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.inboxDir}/logs";
      defaultText = lib.literalExpression ''"''${cfg.inboxDir}/logs"'';
      description = ''
        Directory for launchd stdout/stderr log files. Defaults to
        the manifest-declared `logs/` state dir under inboxDir so the
        daemon has one log location, not two.
      '';
    };

    otelEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://localhost:4318";
      description = ''
        Optional OTLP HTTP endpoint. When set, exported as
        `OTEL_EXPORTER_OTLP_ENDPOINT` to the daemon.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables to pass to the launchd agent.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    launchd.user.agents.ai-pair = {
      serviceConfig = {
        Label = serviceLabel;

        ProgramArguments = [ "${cfg.package}/${watchExe}" ];

        RunAtLoad = true;
        ProcessType = "Background";

        # Passive crash-restart only. The daemon refuses to start
        # against an existing socket ({:already_running, sock_path}),
        # which exits non-zero and is therefore restartable.
        KeepAlive = {
          SuccessfulExit = false;
        };
        ThrottleInterval = 5;

        StandardOutPath = "${cfg.logDir}/ai-pair.out.log";
        StandardErrorPath = "${cfg.logDir}/ai-pair.err.log";

        EnvironmentVariables = {
          HOME = cfg.home;
          AI_PAIR_INBOX = cfg.inboxDir;
          # TMPDIR is intentionally not set here. tmux ignores TMPDIR on
          # macOS and uses the user's socket directory under /private/tmp.
          # The release wrappers self-resolve their dependencies via
          # `wrapProgram`, but tmux/the user shell still need a sane
          # PATH. Nix package bins first, then profile and system fallbacks.
          PATH = lib.concatStringsSep ":" [
            (lib.makeBinPath [ pkgs.tmux pkgs.coreutils ])
            "${cfg.home}/.nix-profile/bin"
            "/run/current-system/sw/bin"
            "/nix/var/nix/profiles/default/bin"
            "/usr/local/bin"
            "/usr/bin"
            "/bin"
            "/usr/sbin"
            "/sbin"
          ];
        }
        // lib.optionalAttrs (cfg.otelEndpoint != null) {
          OTEL_EXPORTER_OTLP_ENDPOINT = cfg.otelEndpoint;
          OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
        }
        // cfg.extraEnvironment;
      };
    };

    # Materialize state dirs on activation. launchd refuses to write
    # StandardOutPath/StandardErrorPath if the parent is missing.
    # The default logDir == ${inboxDir}/logs is already in stateDirs,
    # but if the user overrode logDir to something outside inboxDir
    # we still need to create it.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      mkdir -p '${cfg.inboxDir}'
      ${lib.concatMapStringsSep "\n" (d: ''
        mkdir -p '${cfg.inboxDir}/${d}'
      '') stateDirs}
      chmod 0700 '${cfg.inboxDir}/sock' 2>/dev/null || true
      chown -R ${cfg.user}:staff '${cfg.inboxDir}' 2>/dev/null || true

      mkdir -p '${cfg.logDir}'
      chown ${cfg.user}:staff '${cfg.logDir}' 2>/dev/null || true
    '';
  };
}
