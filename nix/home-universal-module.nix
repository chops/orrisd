# home-manager module: ai-pair universal adoption (per-user files +
# direnv layout + launchd timers + global CLAUDE.md/AGENTS.md marker
# blocks).
#
# Namespaced as `programs.ai-pair-user` to avoid colliding with the
# Linux systemd-user daemon module (which is `services.ai-pair`).
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.ai-pair-user;

  apPackage = pkgs.runCommandLocal "ai-pair-user-cli" {
    buildInputs = [ pkgs.coreutils pkgs.bash ];
  } ''
    install -Dm755 ${./files/ap.sh}          $out/bin/ap
    install -Dm755 ${./files/start-pair.sh}  $out/bin/start-pair
    install -Dm755 ${./files/ap-bridge.sh}   $out/bin/ap-bridge
    install -Dm755 ${./files/gemini-otel.sh} $out/bin/gemini-otel
  '';

  useAiPairLib = pkgs.runCommandLocal "ai-pair-direnv-lib" { } ''
    install -Dm644 ${./files/use_ai_pair.sh} $out/share/direnv/lib/use_ai_pair.sh
  '';

  peerProtocolDocs = pkgs.runCommandLocal "ai-pair-peer-protocol" { } ''
    mkdir -p $out/share/ai-pair
    install -Dm644 ${./files/peer-protocol.org}          $out/share/ai-pair/peer-protocol.org
    install -Dm644 ${./files/peer-protocol.schema.json} $out/share/ai-pair/peer-protocol.schema.json
  '';

  markerBegin = name: "# >>> ${name} >>> managed block (do not hand-edit between markers)";
  markerEnd   = name: "# <<< ${name} <<<";

  claudeMdContent = builtins.readFile ./files/claude-md-block.md;
  agentsMdContent = builtins.readFile ./files/agents-md-block.md;

  # Activation script that splices marker-delimited content into a
  # user-owned file. Replaces between markers if found; appends if not.
  # Uses nix-store paths so it works on both darwin and NixOS (where
  # /bin and /usr/bin layouts diverge).
  mkMarkerBlock = { file, name, body }: ''
    set -eu
    target="${file}"
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$target")"
    ${pkgs.coreutils}/bin/touch "$target"
    begin="${markerBegin name}"
    end="${markerEnd name}"
    blockfile="$(${pkgs.coreutils}/bin/mktemp)"
    ${pkgs.coreutils}/bin/cat >"$blockfile" <<'AI_PAIR_BLOCK_EOF'
${body}
AI_PAIR_BLOCK_EOF
    if ${pkgs.gnugrep}/bin/grep -qF "$begin" "$target"; then
      ${pkgs.gawk}/bin/awk -v b="$begin" -v e="$end" -v f="$blockfile" '
        BEGIN { in_blk=0; printed=0 }
        $0==b { in_blk=1;
                print b;
                while ((getline line < f) > 0) print line;
                print e;
                printed=1;
                next }
        $0==e { in_blk=0; next }
        { if (!in_blk) print }
      ' "$target" >"$target.ai-pair.new"
      ${pkgs.coreutils}/bin/mv "$target.ai-pair.new" "$target"
    else
      {
        ${pkgs.coreutils}/bin/printf '\n%s\n' "$begin"
        ${pkgs.coreutils}/bin/cat "$blockfile"
        ${pkgs.coreutils}/bin/printf '%s\n' "$end"
      } >>"$target"
    fi
    ${pkgs.coreutils}/bin/rm -f "$blockfile"
  '';
in
{
  options.programs.ai-pair-user = {
    enable = lib.mkEnableOption "ai-pair user-facing CLI, direnv lib, and CLAUDE/AGENTS marker blocks";

    projectsDir = lib.mkOption {
      type = lib.types.path;
      default = "${config.home.homeDirectory}/src";
      description = "Directory ap migrate targets by default.";
    };

    installCLI = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the `ap` and `start-pair` binaries into home.packages.";
    };

    installStartPair = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Alias for installCLI; reserved for future split.";
    };

    installDirenvLib = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install use_ai_pair direnv layout into ~/.config/direnv/lib/.";
    };

    installLaunchdTimers = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.isDarwin;
      description = ''
        Install per-user launchd timers for log rotation and processed/ retention.
        Implemented via launchd.agents.<name>; no raw .plist files.
      '';
    };

    seedClaudeMd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Splice the ai-pair marker block into ~/.claude/CLAUDE.md (rest of file user-owned).";
    };

    seedAgentsMd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Splice the ai-pair marker block into ~/.codex/AGENTS.md (rest of file user-owned).";
    };

    logRotationKeepDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Days to retain processed/ + logs/ before pruning.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf cfg.installCLI [ apPackage peerProtocolDocs ];

    home.file = lib.mkMerge [
      (lib.mkIf cfg.installDirenvLib {
        ".config/direnv/lib/use_ai_pair.sh".source = "${useAiPairLib}/share/direnv/lib/use_ai_pair.sh";
      })
    ];

    home.sessionVariables = {
      AI_PAIR_INBOX_BASE = "${config.home.homeDirectory}/.ai-agent-inbox";
    };

    launchd.agents = lib.mkIf (cfg.installLaunchdTimers && pkgs.stdenv.isDarwin) {
      ai-pair-log-rotate = {
        enable = true;
        config = {
          ProgramArguments = [
            "${pkgs.bash}/bin/bash" "-c"
            (''
              set -eu
              base="''${AI_PAIR_INBOX_BASE:-$HOME/.ai-agent-inbox}"
              /usr/bin/find "$base" -type d -name logs -prune -exec \
                /usr/bin/find {} -type f -mtime +${toString cfg.logRotationKeepDays} -delete \; 2>/dev/null || true
              /usr/bin/find "$base" -type d -name processed -prune -exec \
                /usr/bin/find {} -type f -mtime +${toString cfg.logRotationKeepDays} -delete \; 2>/dev/null || true
              /usr/bin/find "$base" -type d -name processed -prune -exec \
                /usr/bin/find {} -type d -mtime +${toString cfg.logRotationKeepDays} -empty -delete \; 2>/dev/null || true
            '')
          ];
          StartCalendarInterval = [{ Hour = 4; Minute = 30; }];
          StandardOutPath = "${config.home.homeDirectory}/.ai-agent-inbox/logs/launchd-log-rotate.log";
          StandardErrorPath = "${config.home.homeDirectory}/.ai-agent-inbox/logs/launchd-log-rotate.err";
        };
      };
    };

    home.activation = lib.mkMerge [
      (lib.mkIf cfg.seedClaudeMd {
        aiPairClaudeMd = lib.hm.dag.entryAfter [ "writeBoundary" ] (mkMarkerBlock {
          file = "${config.home.homeDirectory}/.claude/CLAUDE.md";
          name = "ai-pair";
          body = claudeMdContent;
        });
      })
      (lib.mkIf cfg.seedAgentsMd {
        aiPairAgentsMd = lib.hm.dag.entryAfter [ "writeBoundary" ] (mkMarkerBlock {
          file = "${config.home.homeDirectory}/.codex/AGENTS.md";
          name = "ai-pair";
          body = agentsMdContent;
        });
      })
    ];
  };
}
