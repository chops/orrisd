{ config, lib, pkgs, ... }:

let
  cfg = config.services.ai-pair;

  manifest = builtins.fromJSON (builtins.readFile ./manifest.json);
  watchExe = manifest.executables.watch.path;
  stateDirs = manifest.daemon.required_state_dirs;

  parentDir = builtins.dirOf cfg.inboxDir;
in
{
  options.services.ai-pair = {
    enable = lib.mkEnableOption "ai-pair tmux watcher daemon (NixOS system unit)";

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
        Username that owns the system unit. Determines $HOME and
        the inbox directory default. The unit runs as User=<this>.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = ''
        Primary group of the user. NixOS sets `users.users.<u>.group`
        to "users" by default for `isNormalUser`, which is why this
        defaults to "users" rather than `cfg.user`.
      '';
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}";
      defaultText = lib.literalExpression ''"/home/''${cfg.user}"'';
      description = "Home directory of the user running the daemon.";
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
        Extra environment variables to pass to the systemd unit.
        Merged last, so entries here override the base environment.
      '';
    };

    bridge = {
      enable = lib.mkEnableOption "ai-pair cross-host envelope bridge sibling unit";

      localHost = lib.mkOption {
        type = lib.types.str;
        example = "example-host";
        description = ''
          Name of the local host as it appears in peer-protocol
          `to.host` fields. Envelopes addressed to this host are
          left in `inbox/` for the local watcher; all others are
          forwarded through the routes table.
        '';
      };

      routes = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              default = "agent";
              description = "Remote SSH user on the destination host.";
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "DNS name or IP literal for SSH transport.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 22;
              description = "SSH port on the destination host.";
            };
            inbox = lib.mkOption {
              type = lib.types.str;
              example = "/home/agent/.ai-agent-inbox/ai-pair";
              description = ''
                Absolute path to the destination host's
                `$AI_PAIR_INBOX`. The bridge rsyncs into
                `<inbox>/inbox/<filename>`.
              '';
            };
            identity_file = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Optional SSH identity file readable by
                `services.ai-pair.user`. If null the unit relies on
                user agent / config defaults.
              '';
            };
          };
        });
        default = { };
        description = ''
          Map of destination host name → SSH route. Keys MUST match
          envelope `to.host` values. Entries are written verbatim
          into `/etc/ai-pair/routing.json` for the bridge to consume.
        '';
      };

      pollIntervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Bridge inbox poll interval, in seconds.";
      };

      routingPath = lib.mkOption {
        type = lib.types.str;
        default = "/etc/ai-pair/routing.json";
        description = ''
          Path at which the bridge expects the routing config. The
          module renders this file via `environment.etc` so the
          NixOS toplevel owns it. Override only if a non-`/etc`
          location is needed (e.g. tests).
        '';
      };

      acceptKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = lib.literalExpression ''[ "ssh-ed25519 AAAA... bridge@example-host" ]'';
        description = ''
          OpenSSH-format public keys authorized to deliver envelopes
          into this host's `$AI_PAIR_INBOX/inbox/` via rsync-over-ssh.

          Keys are installed into
          `''${services.ai-pair.home}/.ssh/authorized_keys.bridge` by
          a sibling oneshot unit ordered before `sshd.service`.
          The existing host-managed key in `~/.ssh/authorized_keys` is
          left untouched — sshd consults both files via
          `services.openssh.authorizedKeysFiles`.

          Asymmetric is supported: a host with empty `acceptKeys` but
          non-empty `routes` is send-only; the inverse is receive-only.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Pre-create state dirs and log dir before the unit starts. Parents
    # must be listed explicitly: systemd-tmpfiles `d` does not create
    # intermediate directories. createHome=true gives us cfg.home; we
    # build from cfg.home outward.
    systemd.tmpfiles.rules =
      [
        "d ${parentDir} 0700 ${cfg.user} ${cfg.group} - -"
        "d ${cfg.inboxDir} 0700 ${cfg.user} ${cfg.group} - -"
      ]
      ++ map (d:
        "d ${cfg.inboxDir}/${d} 0700 ${cfg.user} ${cfg.group} - -"
      ) stateDirs
      ++ lib.optional (cfg.logDir != "${cfg.inboxDir}/logs")
        "d ${cfg.logDir} 0700 ${cfg.user} ${cfg.group} - -"
      ++ lib.optional cfg.bridge.enable
        "d ${cfg.inboxDir}/outbox-bridge 0700 ${cfg.user} ${cfg.group} - -";

    environment.etc = lib.mkIf cfg.bridge.enable {
      "ai-pair/routing.json".text = builtins.toJSON {
        local_host = cfg.bridge.localHost;
        routes = cfg.bridge.routes;
      };
    };

    # sshd consults the existing host-managed keys and the separate
    # bridge-keys file written by ai-pair-bridge-keys-install. Bridge
    # enrollment leaves the operator's existing key file untouched.
    services.openssh.authorizedKeysFiles = lib.mkIf cfg.bridge.enable [
      "%h/.ssh/authorized_keys"
      "%h/.ssh/authorized_keys.bridge"
    ];

    systemd.services.ai-pair = {
      description = "ai-pair tmux watcher";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "systemd-tmpfiles-setup.service" ];

      # Use the unit's `path` (extends PATH) rather than
      # `environment.PATH = ...` (collides with the systemd-injected
      # default and fails the build with "conflicting definition
      # values" — observed on NixOS 26.05 with systemd 258).
      path = [ pkgs.tmux pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        ExecStart = "${cfg.package}/${watchExe}";
        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "append:${cfg.logDir}/ai-pair.out.log";
        StandardError = "append:${cfg.logDir}/ai-pair.err.log";
      };

      environment =
        let
          base = {
            HOME = cfg.home;
            AI_PAIR_INBOX = cfg.inboxDir;
          };
          otel = lib.optionalAttrs (cfg.otelEndpoint != null) {
            OTEL_EXPORTER_OTLP_ENDPOINT = cfg.otelEndpoint;
            OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf";
          };
        in
        base // otel // cfg.extraEnvironment;
    };

    # Oneshot: render acceptKeys → ~/.ssh/authorized_keys.bridge before
    # sshd starts so the file is in place on first boot. Idempotent;
    # runs again on every activation. Empty acceptKeys produces an empty
    # file — sshd treats it as "no extra keys", not an error.
    systemd.services.ai-pair-bridge-keys-install = lib.mkIf cfg.bridge.enable {
      description = "ai-pair: install bridge sender accept-keys into ~/.ssh/authorized_keys.bridge";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [ pkgs.coreutils ];

      script = ''
        set -euo pipefail
        ssh_dir="${cfg.home}/.ssh"
        install -d -m 0700 -o ${cfg.user} -g ${cfg.group} "$ssh_dir"
        target="$ssh_dir/authorized_keys.bridge"
        tmp="$(mktemp "$ssh_dir/.bridge-keys.XXXXXX")"
        cat > "$tmp" <<'AI_PAIR_BRIDGE_KEYS_EOF'
        ${lib.concatStringsSep "\n" cfg.bridge.acceptKeys}
        AI_PAIR_BRIDGE_KEYS_EOF
        chmod 0600 "$tmp"
        chown ${cfg.user}:${cfg.group} "$tmp"
        mv -f "$tmp" "$target"
      '';
    };

    systemd.services.ai-pair-bridge = lib.mkIf cfg.bridge.enable {
      description = "ai-pair cross-host envelope bridge";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
        "ai-pair.service"
      ];
      wants = [ "network-online.target" ];

      # The packaged bridge pins its Elixir JSON reader.
      # and envelope to.host on every tick. coreutils for mv/mkdir.
      path = [ pkgs.rsync pkgs.openssh pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;

        ExecStart = "${cfg.package}/bin/ap-bridge";
        Restart = "on-failure";
        RestartSec = 5;

        StandardOutput = "append:${cfg.logDir}/ai-pair-bridge.out.log";
        StandardError  = "append:${cfg.logDir}/ai-pair-bridge.err.log";
      };

      environment = {
        HOME = cfg.home;
        AI_PAIR_INBOX = cfg.inboxDir;
        AP_BRIDGE_ROUTING = cfg.bridge.routingPath;
        AP_BRIDGE_POLL_INTERVAL_S = toString cfg.bridge.pollIntervalSeconds;
      };
    };
  };
}
