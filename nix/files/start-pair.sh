#!/usr/bin/env bash
# ai-pair start-pair — launch a project-scoped Claude+Codex tmux pair.
#
# Idempotent: if the project session already exists, attach.
# Project scope: SESSION = "ai-pair/<basename>-<sha256:8 of $WORKDIR>".
# Re-create only with --recreate.
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: start-pair [--recreate] [--detach] [--workdir DIR]
                  [--project NAME] [--no-attach]

Project-scoped tmux session "ai-pair/<basename>-<sha256:8>".

  --recreate    Kill the existing session for this project and start fresh.
  --detach      Start the session but do not attach.
  --no-attach   Same as --detach.
  --workdir DIR Override project root (defaults to PWD).
  --project N   Override project basename (defaults to basename of workdir).
  -r, --resume [ID]  Resume a Claude session in the Claude pane (cold start
                     only). Bare = picker; with ID = that session.
  -c, --continue     Resume the most recent Claude session (cold start only).
  --fork-session     Branch a new id when resuming (safe if the target
                     session is live elsewhere).
  -h, --help    Show this message.

Env:
  AI_PAIR_OTEL_PROBE=1   Probe the OTel collector and warn if unreachable.
  AI_PAIR_TMUX_OPTS=...  Extra args appended to `tmux new-session`.
  AI_PAIR_CLAUDE_BYPASS  Default 1; 0 launches `claude` without
                         `--dangerously-skip-permissions`.
  AI_PAIR_CODEX_BYPASS   Default 1; 0 launches `codex` without
                         `--dangerously-bypass-approvals-and-sandbox`.
  AI_PAIR_GEMINI_WINDOW  Default 1; 0 skips the on-start interactive 'gemini' window.
USAGE
}

recreate=0
attach=1
WORKDIR=""
project_override=""
resume_flag=0
resume_id=""
continue_flag=0
fork_flag=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate) recreate=1; shift ;;
    --detach|--no-attach) attach=0; shift ;;
    --workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
    --project) project_override="${2:?--project needs a value}"; shift 2 ;;
    -r|--resume)
      # Optional id: consume the next token only if it is not another flag.
      resume_flag=1
      if [[ -n "${2:-}" && "${2#-}" == "$2" ]]; then resume_id="$2"; shift; fi
      shift ;;
    -c|--continue) continue_flag=1; shift ;;
    --fork-session) fork_flag=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "start-pair: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)  echo "start-pair: unexpected arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if (( resume_flag && continue_flag )); then
  echo "start-pair: --resume and --continue are mutually exclusive" >&2; exit 2
fi

WORKDIR="${WORKDIR:-$PWD}"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"

# Fail fast on a UUID-shaped --resume id with no transcript under this dir.
# (Bare --resume / --continue are left for Claude's own picker/resolution.)
if (( resume_flag )) && [[ -n "$resume_id" ]]; then
  slug="$(printf '%s' "$WORKDIR" | sed 's/[^A-Za-z0-9]/-/g')"
  transcript="$HOME/.claude/projects/$slug/$resume_id.jsonl"
  if [[ ! -f "$transcript" ]]; then
    echo "start-pair: no Claude session '$resume_id' under $WORKDIR" >&2
    echo "start-pair:   looked for $transcript" >&2
    exit 2
  fi
fi

AI_PAIR_PROJECT="${project_override:-${AI_PAIR_PROJECT:-$(basename "$WORKDIR")}}"
if command -v shasum >/dev/null 2>&1; then
  PROJECT_HASH="$(printf '%s' "$WORKDIR" | shasum -a 256 | head -c 8)"
else
  PROJECT_HASH="$(printf '%s' "$WORKDIR" | sha256sum | head -c 8)"
fi
SESSION="ai-pair/${AI_PAIR_PROJECT}-${PROJECT_HASH}"
export AI_PAIR_PROJECT AI_PAIR_PROJECT_HASH="$PROJECT_HASH" AI_PAIR_PROJECT_DIR="$WORKDIR"

INBOX_BASE="${AI_PAIR_INBOX_BASE:-$HOME/.ai-agent-inbox}"
AI_PAIR_INBOX="${AI_PAIR_INBOX:-$INBOX_BASE/$AI_PAIR_PROJECT-$PROJECT_HASH}"
export AI_PAIR_INBOX
mkdir -p "$AI_PAIR_INBOX"/{inbox,outbox,processed,logs,sock}

# Per-project CODEX_HOME isolation. Multiple codex panes that share one
# ~/.codex/auth.json revoke each other's rotating ChatGPT refresh tokens
# (and `codex logout` now revokes server-side, account-wide), which shows
# up as "your refresh token was revoked" loops that re-login never fixes.
# Give each project its own codex home with an independent token family.
# Only read-mostly global config is shared via symlink (MCP servers + the
# ai-pair AGENTS.md block); auth.json, sqlite, and rollouts stay per-home.
# Side benefit: an orphaned codex from one project can no longer revoke
# another project's (or VS Code's) tokens — isolation bounds the blast
# radius. Override the home with AI_PAIR_CODEX_HOME if needed.
AI_PAIR_CODEX_HOME="${AI_PAIR_CODEX_HOME:-$AI_PAIR_INBOX/codex-home}"
mkdir -p "$AI_PAIR_CODEX_HOME"
for _cfg in config.toml AGENTS.md; do
  if [ -e "$HOME/.codex/$_cfg" ] && [ ! -e "$AI_PAIR_CODEX_HOME/$_cfg" ]; then
    ln -sfn "$HOME/.codex/$_cfg" "$AI_PAIR_CODEX_HOME/$_cfg"
  fi
done
export AI_PAIR_CODEX_HOME

LOG_DIR="$AI_PAIR_INBOX/logs"
START_LOG="$LOG_DIR/start-pair.log"
exec 3>>"$START_LOG"
log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SESSION}" "$*" >&3; }

cleanup_partial() {
  local rc=$?
  log "ERR rc=$rc — tearing down partial session"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  exit "$rc"
}
trap cleanup_partial ERR

# Register both panes with the daemon. Daemon attach is idempotent —
# re-attach returns started:false (ipc/server.ex AlreadyStarted branch).
# Safe to call on cold-start AND session-exists paths so the wakeup
# channel works even after a daemon restart wiped its registry.
register_panes() {
  local HERE AI_PAIR_BIN claude_pane codex_pane
  HERE="$(dirname "$0")"
  AI_PAIR_BIN="$HERE/ai-pair"
  [[ -x "$AI_PAIR_BIN" ]] || AI_PAIR_BIN="ai-pair"
  claude_pane="$(tmux display-message -p -t "$SESSION:pair.0" '#{pane_id}' 2>/dev/null || true)"
  codex_pane="$(tmux display-message -p -t "$SESSION:pair.1" '#{pane_id}' 2>/dev/null || true)"
  if [[ -z "$claude_pane" || -z "$codex_pane" ]]; then
    log "WARN: could not resolve pane IDs for registration (claude='$claude_pane' codex='$codex_pane')"
    return 0
  fi
  log "registering panes with daemon: claude=$claude_pane codex=$codex_pane"
  "$AI_PAIR_BIN" attach "$claude_pane" --agent claude_code >/dev/null 2>&1 \
    || log "WARN: daemon failed to register claude pane $claude_pane"
  "$AI_PAIR_BIN" attach "$codex_pane" --agent codex_cli >/dev/null 2>&1 \
    || log "WARN: daemon failed to register codex pane $codex_pane"
}

# Auto-dismiss first-run trust gates. Claude 2.1.140 and Codex 0.131 both
# render a modal "trust this folder/directory?" prompt on first launch in
# a workspace; the daemon classifies these as :dialog (via the trust-gate
# fingerprint anchors), but `ap send` queues for non-idle panes via the
# SM catch-all, so the wakeup channel cannot dismiss the modal itself.
# Direct tmux send-keys is correct here: the channel-discipline rule
# (peer-protocol.md) forbids raw tmux for waking the PEER agent. This is
# different — we're scripting cold-start setup of panes we own, before
# either agent is interacting. Pre-existing trust state in ~/.claude and
# ~/.codex makes this no-op on subsequent boots; the watcher just times
# out at $max_wait without typing anything. Idempotent + race-tolerant.
# Regex of trust/permission-gate prompt text. Matched against live pane
# content before we ever press Enter. Covers Claude ("Do you trust the files
# in this folder?") and Codex (older "trust this folder?" gates) without
# matching a normal agent TUI. Override/extend via AI_PAIR_TRUSTGATE_REGEX.
TRUSTGATE_REGEX="${AI_PAIR_TRUSTGATE_REGEX:-do you (trust|want to (trust|allow))|trust (this|the) (folder|files|directory|workspace)|allow .* to (work|run|access|edit|make changes)|yes, (allow|proceed|trust)|press enter to (continue|trust|confirm)}"

autodismiss_trustgates() {
  local AI_PAIR_BIN HERE pane_label pane_id state t0 max_wait content
  HERE="$(dirname "$0")"
  AI_PAIR_BIN="$HERE/ai-pair"
  [[ -x "$AI_PAIR_BIN" ]] || AI_PAIR_BIN="ai-pair"
  max_wait="${AI_PAIR_TRUSTGATE_WAIT_S:-30}"
  for pane_label in pair.0 pair.1; do
    pane_id="$(tmux display-message -p -t "$SESSION:$pane_label" '#{pane_id}' 2>/dev/null || true)"
    [[ -z "$pane_id" ]] && continue
    t0=$SECONDS
    while (( SECONDS - t0 < max_wait )); do
      state="$("$AI_PAIR_BIN" pane_status "$pane_id" 2>/dev/null \
        | sed -n 's/.*"state":"\([^"]*\)".*/\1/p' | head -1)"
      if [[ "$state" == "dialog" ]]; then
        # The daemon's :dialog fingerprint false-positives on newer CLI boot
        # screens (e.g. Codex >= 0.135), and a stray Enter on a non-gate
        # screen KILLS the pane. So only dismiss when the live pane content
        # actually shows a trust/permission prompt. Otherwise keep polling:
        # a real gate may still render, or the TUI settles to idle/busy and
        # we break below. Pre-trusted workspaces simply never match and the
        # watcher times out without typing anything.
        content="$(tmux capture-pane -p -t "$pane_id" 2>/dev/null || true)"
        if printf '%s' "$content" | grep -Eqi "$TRUSTGATE_REGEX"; then
          log "auto-dismissing verified trust gate on $pane_label ($pane_id)"
          tmux send-keys -t "$pane_id" Enter
          break
        fi
        log "skip auto-dismiss on $pane_label ($pane_id): :dialog but no trust-gate text (normal TUI)"
      elif [[ "$state" == "idle" || "$state" == "busy" ]]; then
        break
      fi
      sleep 1
    done
  done
}

# Open (once) an ancillary 'gemini' window running the OTel oracle as an
# INTERACTIVE analyst (`gemini-otel launch-interactive`): it seeds an
# `agy --prompt-interactive` session with recent LLM telemetry and hands you a
# TUI you can steer. Idempotent (skips if a 'gemini' window already exists) and
# strictly non-fatal: this must NEVER prevent the Claude+Codex pair from
# starting, so every failure path returns 0 and the ERR trap is avoided via
# `if !`. Toggle off with AI_PAIR_GEMINI_WINDOW=0. Self-contained (builds its
# own env) so it can be called from both the cold-start and session-exists paths.
ensure_gemini_window() {
  [[ "${AI_PAIR_GEMINI_WINDOW:-1}" != "0" ]] || return 0

  if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -Fxq gemini; then
    # Window already present (e.g. re-attach); still ensure attach lands on the
    # 2-pane main view rather than the gemini window.
    tmux select-window -t "$SESSION:pair" 2>/dev/null || true
    tmux select-pane -t "$SESSION:pair.0" 2>/dev/null || true
    return 0
  fi

  local here gemini_bin gemini_cmd
  here="$(dirname "$0")"
  gemini_bin="$here/gemini-otel"
  [[ -x "$gemini_bin" ]] || gemini_bin="gemini-otel"
  # --await: on a cold start there's no telemetry yet, so the window waits for
  # the first LLM calls to land, then launches the analyst (without --await it
  # would exit immediately and — since this window is created only once — never
  # reappear). `;` (not `&&`) so the window still drops to a shell if the oracle
  # is missing, the user bails from the wait, or the analyst TUI is quit;
  # launch-interactive returns (not exec) so its scratch dir is cleaned first.
  gemini_cmd="$gemini_bin launch-interactive --await; exec \${SHELL:-/bin/sh}"

  local genv=(
    -e "AI_PAIR_PROJECT=$AI_PAIR_PROJECT"
    -e "AI_PAIR_PROJECT_HASH=$PROJECT_HASH"
    -e "AI_PAIR_PROJECT_DIR=$WORKDIR"
    -e "AI_PAIR_INBOX=$AI_PAIR_INBOX"
    -e "AI_PAIR_HARNESS=ai-pair"
  )

  if ! tmux new-window -d -t "$SESSION" -n gemini -c "$WORKDIR" "${genv[@]}" "$gemini_cmd"; then
    log "WARN: failed to create gemini window (non-fatal)"
    return 0
  fi

  # `-d` should not steal focus, but reselect the pair window to be safe.
  tmux select-window -t "$SESSION:pair" 2>/dev/null || true
  tmux select-pane -t "$SESSION:pair.0" 2>/dev/null || true
  log "gemini otel window created"
}

if tmux has-session -t "$SESSION" 2>/dev/null; then
  if (( recreate )); then
    log "--recreate: killing existing session"
    tmux kill-session -t "$SESSION"
  else
    if (( resume_flag || continue_flag )); then
      echo "start-pair: session $SESSION exists; --resume/--continue only applies on cold start." >&2
      echo "start-pair:   re-run with --recreate to relaunch the pair with the resumed session." >&2
      exit 2
    fi
    log "session exists; re-registering panes before attach"
    register_panes
    ensure_gemini_window
    if (( attach )) && [[ -t 1 ]]; then
      exec tmux attach -t "$SESSION"
    else
      echo "$SESSION"
      exit 0
    fi
  fi
fi

if [[ "${AI_PAIR_OTEL_PROBE:-0}" == "1" ]]; then
  if ! curl --max-time 1 --silent --fail \
        -X POST "${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}/v1/traces" \
        -H 'content-type: application/json' --data '{"resourceSpans":[]}' >/dev/null 2>&1; then
    log "WARN: OTel collector probe failed at ${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318} (non-fatal)"
  fi
fi

common_env=(
  -e "AI_PAIR_PROJECT=$AI_PAIR_PROJECT"
  -e "AI_PAIR_PROJECT_HASH=$PROJECT_HASH"
  -e "AI_PAIR_PROJECT_DIR=$WORKDIR"
  -e "AI_PAIR_INBOX=$AI_PAIR_INBOX"
  -e "AI_PAIR_HARNESS=ai-pair"
)
# Propagate msg_id only when the parent shell has it set (e.g. `ap up`
# invoked from inside an `ap send --msg-id` envelope). The shim falls
# back to an adhoc id when unset, so we don't want to stamp an empty
# value into the pane env.
if [ -n "${AI_PAIR_MSG_ID:-}" ]; then
  common_env+=(-e "AI_PAIR_MSG_ID=$AI_PAIR_MSG_ID")
fi
claude_env=(
  -e "AI_PAIR_PEER_ROLE=claude"
  -e "AI_PAIR_PANE_AGENT=claude_code"
  # Disable Claude Code prompt suggestions ("ghost text") in pair panes.
  # The suggestion renders as real chars in the input box (e.g. "❯ commit
  # slice 1"), which no longer matches the claude_code idle fingerprint
  # (^❯\s*$). The daemon then reports state=unknown and queues peer wakeups
  # forever, so Claude never picks up a reply. Off in panes only; the user's
  # normal interactive Claude keeps suggestions.
  -e "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false"
)
codex_env=(
  -e "AI_PAIR_PEER_ROLE=codex"
  -e "AI_PAIR_PANE_AGENT=codex_cli"
  -e "CODEX_HOME=$AI_PAIR_CODEX_HOME"
)

read -r -a extra_tmux <<<"${AI_PAIR_TMUX_OPTS:-}"

# Route through llm-proxy-shim when present so x-ai-pair-* correlation
# headers reach the local llm-otel-proxy. Bare CLIs remain the portable
# fallback, but they do not provide the shim's routing or telemetry.
if command -v llm-proxy-shim >/dev/null 2>&1; then
  claude_cmd="llm-proxy-shim claude"
  codex_cmd="llm-proxy-shim codex"
  log "LLM launch path: llm-proxy-shim (telemetry enabled)"
else
  claude_cmd="claude"
  codex_cmd="codex"
  log "WARN: llm-proxy-shim not found; launching raw CLIs with NO TELEMETRY"
  echo "start-pair: WARN: llm-proxy-shim not found; launching raw CLIs with NO TELEMETRY" >&2
fi

if [[ "${AI_PAIR_CLAUDE_BYPASS:-1}" == "1" ]]; then
  claude_cmd="$claude_cmd --dangerously-skip-permissions"
fi

# Resume a Claude session in the pane (cold-start path only; the
# session-exists branch above refuses these flags). Injected inside the
# llm-proxy-shim wrapping so telemetry + OAuth routing are preserved.
if (( continue_flag )); then
  claude_cmd="$claude_cmd --continue"
fi
if (( resume_flag )); then
  claude_cmd="$claude_cmd --resume${resume_id:+ $resume_id}"
fi
if (( fork_flag )); then
  claude_cmd="$claude_cmd --fork-session"
fi

if [[ "${AI_PAIR_CODEX_BYPASS:-1}" == "1" ]]; then
  codex_cmd="$codex_cmd --dangerously-bypass-approvals-and-sandbox"
fi

# Force file-based credential storage for the per-home auth above. If the
# shared config.toml selects `auto`/`keyring`, codex would store tokens in
# the single OS keychain instead of $CODEX_HOME/auth.json — silently
# re-sharing credentials and defeating isolation. Pin `file` so each home
# truly owns its own auth.json. The matching one-time login must use the
# same flag: CODEX_HOME=$AI_PAIR_CODEX_HOME codex login -c cli_auth_credentials_store=file
codex_cmd="$codex_cmd -c cli_auth_credentials_store=file"

# Per-home auth pre-flight (non-fatal). With CODEX_HOME isolation each new
# project needs a one-time login into its own home; otherwise the codex pane
# boots straight onto a sign-in screen. Surface the exact command rather than
# letting it fail silently. Skip the whole block with AI_PAIR_SKIP_CODEX_AUTH_CHECK=1.
if [[ "${AI_PAIR_SKIP_CODEX_AUTH_CHECK:-0}" != "1" ]]; then
  if [[ ! -e "$AI_PAIR_CODEX_HOME/auth.json" ]]; then
    log "WARN: no codex auth in $AI_PAIR_CODEX_HOME — codex pane will need a one-time login"
    echo "ai-pair: codex is not logged in for this project. In a separate terminal run:" >&2
    echo "  CODEX_HOME=$AI_PAIR_CODEX_HOME codex login -c cli_auth_credentials_store=file" >&2
  else
    # auth.json exists — flag a token that will have to REFRESH on launch.
    # ChatGPT OAuth refresh tokens rotate with reuse detection, so the refresh
    # boundary (access token at/near expiry) is exactly where concurrent codex
    # runs against one home get the whole family revoked ("session has ended" /
    # refresh_token_invalidated). This is a cheap LOCAL exp check — no network,
    # no API spend on the common path (access tokens live ~10 days), so it taxes
    # only the launches that are actually near the danger boundary.
    if command -v python3 >/dev/null 2>&1; then
      codex_at_state="$(python3 - "$AI_PAIR_CODEX_HOME/auth.json" <<'PY' 2>/dev/null || true
import json, sys, base64, time
try:
    d = json.load(open(sys.argv[1]))
    at = (d.get("tokens") or {}).get("access_token", "") or ""
    p = at.split(".")[1]; p += "=" * (-len(p) % 4)
    exp = json.loads(base64.urlsafe_b64decode(p)).get("exp", 0)
    left = exp - time.time()
    print("expired" if left <= 0 else ("soon" if left < 3600 else "ok"))
except Exception:
    print("unknown")
PY
)"
      if [[ "$codex_at_state" == "expired" || "$codex_at_state" == "soon" ]]; then
        log "WARN: codex access token for this home is ${codex_at_state}; it must refresh on launch"
        echo "ai-pair: codex will refresh its ChatGPT token on launch (token ${codex_at_state})." >&2
        echo "  If the codex pane dies with 'session has ended' / 'refresh_token_invalidated'," >&2
        echo "  the token family was revoked. Recover with:  codex-relogin $AI_PAIR_PROJECT" >&2
      fi
    fi
    # Opt-in DEEP probe (off by default — costs a real codex turn + a few
    # seconds). Set AI_PAIR_CODEX_VERIFY=1 to confirm the token is actually live
    # before launching, instead of finding out when the pane dies. Delegates to
    # the codex-check helper when installed.
    if [[ "${AI_PAIR_CODEX_VERIFY:-0}" == "1" ]] && command -v codex-check >/dev/null 2>&1; then
      if ! AI_PAIR_INBOX="$AI_PAIR_INBOX" codex-check >/dev/null 2>&1; then
        log "WARN: codex-check reports this home's token is not usable"
        echo "ai-pair: codex token verify failed. Recover with:  codex-relogin $AI_PAIR_PROJECT" >&2
      fi
    fi
  fi
fi

log "creating session at $WORKDIR (claude_cmd=$claude_cmd, codex_cmd=$codex_cmd)"
tmux new-session -d -s "$SESSION" -n pair -c "$WORKDIR" \
  "${common_env[@]}" "${claude_env[@]}" "${extra_tmux[@]}" \
  "$claude_cmd"

tmux split-window -h -t "$SESSION:pair" -c "$WORKDIR" \
  "${common_env[@]}" "${codex_env[@]}" "${extra_tmux[@]}" \
  "$codex_cmd"

tmux select-pane -t "$SESSION:pair.0"

# Cold-start path uses the same helper as the session-exists branch.
register_panes

if [[ "${AI_PAIR_AUTODISMISS_TRUSTGATES:-1}" == "1" ]]; then
  autodismiss_trustgates
fi

ensure_gemini_window

log "session ready"

trap - ERR

if (( attach )) && [[ -t 1 ]]; then
  exec tmux attach -t "$SESSION"
else
  echo "$SESSION"
fi
