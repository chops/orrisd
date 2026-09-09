#!/usr/bin/env bash
# ap — ai-pair user CLI.
#
# Subcommands:
#   up [--recreate]            Start pair from PWD with fresh project identity
#   down                       Kill pair session for current project
#   status                     Show pair-session and daemon status
#   logs [--follow]            Tail start-pair / processor logs
#   doctor                     Sanity checks (daemon, socket, paths, env)
#   migrate [DIR] [--apply]    Scaffold .envrc into project dirs
#   ping [--protocol-version 2]     Query daemon health and delivery capabilities
#   reconcile <pane> --protocol-version 2 --msg-id ID --payload-hash HASH [--wait-ms N]
#   send [--msg-id ID] <pane> <text>  Wake a peer pane with <text> via the daemon
#   send [--msg-id ID] <pane> --stdin Same, reading payload from stdin
#   consult [--wait [S]] [--peer A] <text...>  Stage a peer consultation
#   consult [--wait [S]] [--peer A] --stdin    Same, reading body from stdin
#   attach <pane> [--agent A]  Register a pane (agent: claude_code|codex_cli)
#   pane_status <pane>         Report pane state (idle|busy|...) + queue
#   detach <pane>              Unregister a pane from the daemon
#   gemini otel [--project P] [--limit N] [--open]  Gemini one-shot report on recent LLM telemetry
#   gemini launch-interactive [--project P]         Interactive Gemini analyst seeded with that telemetry
#   help                       Show this
set -Eeuo pipefail

CMD="${1:-help}"; shift || true

# Preserve the caller's project-scoped values for doctor. Resolution below
# intentionally replaces them, but doctor must still report inherited drift.
INHERITED_WORKDIR="${WORKDIR-}"
INHERITED_AI_PAIR_INBOX="${AI_PAIR_INBOX-}"
INHERITED_AI_PAIR_CODEX_HOME="${AI_PAIR_CODEX_HOME-}"
INHERITED_AI_PAIR_PROJECT_HASH="${AI_PAIR_PROJECT_HASH-}"

# Resolve sibling binaries (start-pair, ai-pair) next to this script first,
# falling back to PATH. Shells invoked without /etc/profiles/per-user/$USER/bin
# on PATH (notably some Claude Code sessions) otherwise hit `start-pair: not
# found` when `ap up` execs the colocated helper.
HERE="$(dirname "$0")"
resolve_bin() {
  local name="$1"
  if [[ -x "$HERE/$name" ]]; then printf '%s' "$HERE/$name"
  else printf '%s' "$name"
  fi
}

resolve_project() {
  # Inside a pair, session identity remains anchored to the root stamped at
  # pane creation even after the operator changes directories. Outside a pair,
  # the current directory is the project root.
  WORKDIR="${AI_PAIR_PROJECT_DIR:-$PWD}"
  WORKDIR="$(cd "$WORKDIR" && pwd -P)"
  if [[ -n "${AI_PAIR_PROJECT_DIR:-}" ]]; then
    AI_PAIR_PROJECT="${AI_PAIR_PROJECT:-$(basename "$WORKDIR")}"
  else
    AI_PAIR_PROJECT="$(basename "$WORKDIR")"
  fi
  if command -v shasum >/dev/null 2>&1; then
    PROJECT_HASH="$(printf '%s' "$WORKDIR" | shasum -a 256 | head -c 8)"
  else
    PROJECT_HASH="$(printf '%s' "$WORKDIR" | sha256sum | head -c 8)"
  fi
  SESSION="ai-pair/${AI_PAIR_PROJECT}-${PROJECT_HASH}"
  INBOX_BASE="${AI_PAIR_INBOX_BASE:-$HOME/.ai-agent-inbox}"
  AI_PAIR_INBOX="$INBOX_BASE/$AI_PAIR_PROJECT-$PROJECT_HASH"
  AI_PAIR_PROJECT_DIR="$WORKDIR"
  AI_PAIR_PROJECT_HASH="$PROJECT_HASH"
  export WORKDIR AI_PAIR_PROJECT PROJECT_HASH SESSION AI_PAIR_INBOX
  export AI_PAIR_PROJECT_DIR AI_PAIR_PROJECT_HASH
}

DAEMON_SOCK_DEFAULT="$HOME/.ai-agent-inbox/ai-pair/sock/ai-pair.sock"

case "$CMD" in
  up)
    # `ap up` is lifecycle creation, not an in-pane command. Its target is the
    # caller's PWD (or start-pair's explicit --workdir), so no project identity
    # from an outer ai-pair session may cross into the new session. Keep this
    # list aligned with start-pair's project-scoped inputs. Calling start-pair
    # directly retains its expert environment-override contract.
    unset WORKDIR AI_PAIR_PROJECT AI_PAIR_PROJECT_DIR AI_PAIR_PROJECT_HASH
    unset AI_PAIR_INBOX AI_PAIR_CODEX_HOME CODEX_HOME
    exec "$(resolve_bin start-pair)" "$@"
    ;;

  down)
    resolve_project
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      tmux kill-session -t "$SESSION"
      echo "killed $SESSION"
    else
      echo "no session for $SESSION"
    fi
    ;;

  status)
    resolve_project
    echo "project:        $AI_PAIR_PROJECT  ($WORKDIR)"
    echo "session:        $SESSION"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "tmux:           up"
    else
      echo "tmux:           down"
    fi
    echo "inbox:          $AI_PAIR_INBOX"
    local_sock="$AI_PAIR_INBOX/sock/ai-pair.sock"
    if [[ -S "$local_sock" ]]; then
      echo "local sock:     $local_sock (exists)"
    else
      echo "local sock:     $local_sock (missing)"
    fi
    if [[ -S "$DAEMON_SOCK_DEFAULT" ]]; then
      echo "daemon sock:    $DAEMON_SOCK_DEFAULT (exists)"
    else
      echo "daemon sock:    $DAEMON_SOCK_DEFAULT (missing)"
    fi
    ;;

  logs)
    resolve_project
    follow=0
    [[ "${1:-}" == "--follow" || "${1:-}" == "-f" ]] && follow=1
    LOG="$AI_PAIR_INBOX/logs/start-pair.log"
    [[ -f "$LOG" ]] || { echo "no log at $LOG"; exit 1; }
    if (( follow )); then exec tail -F "$LOG"; else exec tail -n 200 "$LOG"; fi
    ;;

  doctor)
    rc=0
    say() { printf '  %s\n' "$*"; }
    fail() { rc=1; printf '  [FAIL] %s\n' "$*" >&2; }
    ok()   { printf '  [ ok ] %s\n' "$*"; }
    echo "ai-pair doctor"
    echo "host:"
    say "$(uname -a)"
    echo "binaries:"
    # External deps must be on PATH; without them the agent harness is broken.
    for b in tmux claude codex; do
      if command -v "$b" >/dev/null; then ok "$b → $(command -v "$b")"; else fail "$b not on PATH"; fi
    done
    # Sibling wrappers: if this script is running, both exist on disk by
    # definition (same home-manager profile). Resolve via dirname first so
    # we report the canonical path even when the invoking shell omits
    # /etc/profiles/per-user/$USER/bin from PATH.
    for b in start-pair ap; do
      resolved="$(resolve_bin "$b")"
      if [[ -x "$resolved" ]]; then
        ok "$b → $resolved"
      elif command -v "$b" >/dev/null; then
        ok "$b → $(command -v "$b")"
      else
        fail "$b not resolvable (sibling=$resolved, PATH lookup empty)"
      fi
    done
    echo "daemon:"
    if [[ -S "$DAEMON_SOCK_DEFAULT" ]]; then ok "socket $DAEMON_SOCK_DEFAULT"; else fail "socket $DAEMON_SOCK_DEFAULT missing"; fi
    if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q 'io\.charlesholloway\.ai-pair\|ai-pair'; then
      ok "launchd agent listed"
    else
      say "launchd: no ai-pair entry (ok if Linux or not yet activated)"
    fi
    # Manifest healthcheck contract (nix/manifest.json daemon.healthcheck):
    # type=uds-json-ping, packet=4, timeout_ms=1000. Socket-exists alone is
    # not proof of life — exercise the IPC round-trip end-to-end.
    hc_client="$(resolve_bin ai-pair)"
    # resolve_bin returns bare "ai-pair" when no sibling exists; do an
    # explicit PATH lookup so -x below sees a real path.
    [[ -x "$hc_client" ]] || hc_client="$(command -v ai-pair 2>/dev/null || true)"
    hc_timeout="/run/current-system/sw/bin/timeout"
    [[ -x "$hc_timeout" ]] || hc_timeout="$(command -v timeout 2>/dev/null || true)"
    hc_date="/run/current-system/sw/bin/date"
    [[ -x "$hc_date" ]] || hc_date="$(command -v gdate 2>/dev/null || /bin/date)"
    if [[ -z "$hc_timeout" || ! -x "$hc_client" ]]; then
      fail "healthcheck cannot run (timeout=$hc_timeout client=$hc_client)"
    else
      hc_start_ms=$("$hc_date" +%s%3N 2>/dev/null || echo 0)
      # Outer 2s hard cap covers BEAM startup; manifest's 1000ms is the
      # IPC round-trip budget, reported separately below.
      hc_out="$("$hc_timeout" 2 "$hc_client" ping 2>&1 || true)"
      hc_end_ms=$("$hc_date" +%s%3N 2>/dev/null || echo 0)
      if [[ "$hc_start_ms" != 0 && "$hc_end_ms" != 0 ]]; then
        hc_elapsed=$(( hc_end_ms - hc_start_ms ))
      else
        hc_elapsed="?"
      fi
      if printf '%s' "$hc_out" | grep -q '"ok":[[:space:]]*true'; then
        hc_pong="$(printf '%s' "$hc_out" | sed -nE 's/.*"pong":"([^"]+)".*/\1/p')"
        ok "healthcheck uds-json-ping (pong=${hc_pong:-?}, ${hc_elapsed}ms wall)"
        if [[ "$hc_elapsed" != "?" && "$hc_elapsed" -gt 1500 ]]; then
          say "warn: ${hc_elapsed}ms exceeds manifest 1000ms+cushion budget"
        fi
      else
        fail "healthcheck uds-json-ping failed (${hc_elapsed}ms): $hc_out"
      fi
    fi
    echo "project resolution:"
    resolve_project
    say "WORKDIR        = $WORKDIR"
    say "PROJECT        = $AI_PAIR_PROJECT"
    say "PROJECT_HASH   = $PROJECT_HASH"
    say "SESSION        = $SESSION"
    say "AI_PAIR_INBOX  = $AI_PAIR_INBOX"
    echo "project-scoped env drift:"
    expected_codex_home="$AI_PAIR_INBOX/codex-home"
    if [[ -n "$INHERITED_WORKDIR" && "$(cd "$INHERITED_WORKDIR" 2>/dev/null && pwd -P || printf '%s' "$INHERITED_WORKDIR")" != "$WORKDIR" ]]; then
      fail "WORKDIR=$INHERITED_WORKDIR disagrees with session root $WORKDIR"
    fi
    if [[ -n "$INHERITED_AI_PAIR_INBOX" && "$INHERITED_AI_PAIR_INBOX" != "$AI_PAIR_INBOX" ]]; then
      fail "AI_PAIR_INBOX=$INHERITED_AI_PAIR_INBOX disagrees with expected $AI_PAIR_INBOX"
    fi
    if [[ -n "$INHERITED_AI_PAIR_CODEX_HOME" && "$INHERITED_AI_PAIR_CODEX_HOME" != "$expected_codex_home" ]]; then
      fail "AI_PAIR_CODEX_HOME=$INHERITED_AI_PAIR_CODEX_HOME disagrees with expected $expected_codex_home"
    fi
    if [[ -n "$INHERITED_AI_PAIR_PROJECT_HASH" && "$INHERITED_AI_PAIR_PROJECT_HASH" != "$PROJECT_HASH" ]]; then
      fail "AI_PAIR_PROJECT_HASH=$INHERITED_AI_PAIR_PROJECT_HASH disagrees with expected $PROJECT_HASH"
    fi
    if [[ "$rc" -eq 0 ]]; then
      ok "project-scoped environment agrees with the session root"
    fi
    echo "env divergence (daemon vs shell):"
    for v in OTEL_EXPORTER_OTLP_ENDPOINT AI_PAIR_INBOX_BASE LANG TZ; do
      cur="${!v-<unset>}"
      say "  $v=$cur"
    done
    say "(compare against launchctl getenv $v if a daemon discrepancy is suspected)"
    exit "$rc"
    ;;

  migrate)
    target="${1:-}"; apply=0
    [[ "${1:-}" == "--apply" ]] && { apply=1; target="${2:-$PWD}"; }
    [[ -z "$target" ]] && target="$PWD"
    [[ "${2:-}" == "--apply" ]] && apply=1
    target="$(cd "$target" && pwd -P)"
    mode="dry-run"; (( apply )) && mode="apply"
    echo "ap migrate [$mode]: scanning $target"
    found=0; written=0; skipped=0
    while IFS= read -r -d '' d; do
      [[ -d "$d/.git" || -f "$d/flake.nix" || -f "$d/mix.exs" || -f "$d/Cargo.toml" || -f "$d/package.json" || -f "$d/pyproject.toml" ]] || continue
      found=$((found+1))
      envrc="$d/.envrc"
      if [[ -f "$envrc" ]] && grep -q 'use ai_pair' "$envrc"; then
        skipped=$((skipped+1))
        printf '  skip   %s (already has use ai_pair)\n' "$d"
        continue
      fi
      if [[ "$d" == */apps/* ]]; then
        umbrella_root="${d%/apps/*}"
        if [[ -f "$umbrella_root/mix.exs" && -f "$umbrella_root/.envrc" ]]; then
          skipped=$((skipped+1))
          printf '  skip   %s (umbrella root owns .envrc)\n' "$envrc"
          continue
        fi
      fi
      if (( apply )); then
        [[ -f "$envrc" ]] && printf '\n' >> "$envrc"
        {
          echo "# >>> ai-pair >>> managed block (do not hand-edit between markers)"
          echo "use ai_pair"
          echo "# <<< ai-pair <<<"
        } >> "$envrc"
        touch "$d/.envrc"
        (cd "$d" && direnv allow >/dev/null 2>&1 || true)
        written=$((written+1))
        printf '  write  %s\n' "$envrc"
      else
        printf '  would  %s\n' "$envrc"
      fi
    done < <(find "$target" -mindepth 1 -maxdepth 4 -type d \
              ! -path '*/node_modules/*' ! -path '*/.git/*' \
              ! -path '*/_build/*' ! -path '*/deps/*' ! -path '*/target/*' \
              ! -path '*/.worktrees/*' ! -path '*/.claude/worktrees/*' \
              ! -path '*/backup' ! -path '*/backup/*' \
              ! -path '*.bak' ! -path '*.bak/*' \
              -print0)
    echo "summary: candidates=$found written=$written skipped=$skipped mode=$mode"
    ;;

  ping|reconcile)
    exec "$(resolve_bin ai-pair)" "$CMD" "$@"
    ;;

  send)
    resolve_project
    exec "$(resolve_bin ai-pair)" send "$@"
    ;;

  consult)
    resolve_project
    exec "$(resolve_bin ai-pair)" consult "$@"
    ;;

  attach)
    exec "$(resolve_bin ai-pair)" attach "$@"
    ;;

  pane_status)
    exec "$(resolve_bin ai-pair)" pane_status "$@"
    ;;

  detach)
    exec "$(resolve_bin ai-pair)" detach "$@"
    ;;

  gemini)
    resolve_project
    exec "$(resolve_bin gemini-otel)" "$@"
    ;;

  help|--help|-h|"")
    sed -n '2,/^set -/p' "$0" | sed '$d'
    ;;

  *)
    echo "ap: unknown subcommand: $CMD" >&2
    sed -n '2,/^set -/p' "$0" | sed '$d' >&2
    exit 2
    ;;
esac
