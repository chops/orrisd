{ config, lib, pkgs, ... }:

# Operational note: systemd user units stop on logout unless lingering is
# enabled. After enabling this module, run: loginctl enable-linger $USER

let
  cfg = config.services.ai-pair;

  manifest = builtins.fromJSON (builtins.readFile ./manifest.json);
  watchExe = manifest.executables.watch.path;
  stateDirs = manifest.daemon.required_state_dirs;
in
{
  options.services.ai-pair = {
    enable = lib.mkEnableOption "ai-pair tmux watcher daemon (systemd user unit)";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The ai-pair release package built by the flake (typically
        `inputs.ai-pair.packages.''${system}.default`).
      '';
    };

    inboxDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.ai-agent-inbox/ai-pair";
      defaultText = lib.literalExpression
        ''"''${config.home.homeDirectory}/.ai-agent-inbox/ai-pair"'';
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
        Directory for systemd stdout/stderr append logs. Defaults to
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
      description = ''
        Extra environment variables to pass to the systemd user unit.
        Merged last, so entries here override the base environment.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.ai-pair = {
      Unit = {
        Description = "ai-pair tmux watcher";
        After = [ "default.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${cfg.package}/${watchExe}";
        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "append:${cfg.logDir}/ai-pair.out.log";
        StandardError = "append:${cfg.logDir}/ai-pair.err.log";

        Environment =
          let
            base = {
              HOME = config.home.homeDirectory;
              AI_PAIR_INBOX = cfg.inboxDir;
              # The release wrappers self-resolve their own deps via
              # `wrapProgram`; this PATH is for tmux + coreutils that
              # the watcher shells out to.
              PATH = lib.makeBinPath [ pkgs.tmux pkgs.coreutils ];
            };
            otel = lib.optionalAttrs (cfg.otelEndpoint != null) {
              OTEL_EXPORTER_OTLP_ENDPOINT = cfg.otelEndpoint;
              OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
            };
            merged = base // otel // cfg.extraEnvironment;
          in
          lib.mapAttrsToList (k: v: "${k}=${v}") merged;
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # Belt-and-suspenders: the daemon's AiPair.Inbox also creates these,
    # but pre-creating them at activation avoids a first-start race
    # where systemd opens StandardOutput before the daemon mkdir's logs/.
    home.activation.aiPairDirs =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p ${lib.escapeShellArg cfg.inboxDir} ${lib.escapeShellArg cfg.logDir}
        ${lib.concatMapStringsSep "\n" (d: ''
          run mkdir -p ${lib.escapeShellArg "${cfg.inboxDir}/${d}"}
        '') stateDirs}
      '';
  };
}
