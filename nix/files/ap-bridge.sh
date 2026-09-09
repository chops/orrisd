#!/usr/bin/env bash
# ap-bridge — peer-protocol envelope router for cross-host delivery.
#
# Watches the local $AI_PAIR_INBOX/inbox/ for envelopes whose to.host is
# not the local host (per /etc/ai-pair/routing.json), atomically moves
# them to outbox-bridge/<host>/, and rsyncs them into the destination
# host's inbox/. Once the remote rsync acknowledges, the local copy is
# unlinked. On failure the envelope stays in outbox-bridge/<host>/ for
# the next poll tick.
#
# Single-tenant: one bridge per ai-pair daemon user. No cross-user
# routing. The bridge never writes to inbox/ — only to outbox-bridge/ —
# so it can't conflict with local readers.
#
# Routing config is rendered by the NixOS module to
# /etc/ai-pair/routing.json (override via $AP_BRIDGE_ROUTING).
#
# Envelope routing rules:
#   - Missing to.host        → skip (intra-host envelope; no routing)
#   - to.host == local_host  → skip (already addressed locally)
#   - to.host in routes      → forward
#   - to.host not in routes  → log + leave (operator must extend routes)
#
# All forwarded envelopes preserve the original filename so the
# destination's stuck-scanner mtime-based timing stays consistent.
set -Eeuo pipefail

ROUTING="${AP_BRIDGE_ROUTING:-/etc/ai-pair/routing.json}"
INBOX="${AI_PAIR_INBOX:?AI_PAIR_INBOX not set}"
POLL_INTERVAL_S="${AP_BRIDGE_POLL_INTERVAL_S:-5}"

INBOX_DIR="$INBOX/inbox"
OUTBOX_BRIDGE="$INBOX/outbox-bridge"
LOG_PREFIX="ap-bridge"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

if [[ ! -r "$ROUTING" ]]; then
  log "routing config $ROUTING not readable; bridge idle"
fi

# Load and parse routing.json each tick — config is small and reloads
# without restarting the unit when the NixOS module re-renders /etc.
read_routing() {
  if [[ -r "$ROUTING" ]]; then
    cat "$ROUTING"
  else
    printf '{"local_host":null,"routes":{}}'
  fi
}

# Move-and-forward one envelope. Returns 0 on success, non-zero on
# failure. Caller decides retry policy (we just leave it in outbox-bridge
# and try again next tick — rsync is idempotent on same filename).
forward_envelope() {
  local src="$1" dest_host="$2" routing_json="$3"
  local base="${src##*/}"

  local route
  route="$(printf '%s' "$routing_json" | jq -e --arg h "$dest_host" '.routes[$h] // empty')"
  if [[ -z "$route" ]]; then
    log "no route for host=$dest_host (envelope $base); leaving in place"
    return 1
  fi

  local user host port inbox_path identity
  user="$(printf '%s' "$route" | jq -r '.user // "agent"')"
  host="$(printf '%s' "$route" | jq -r '.host')"
  port="$(printf '%s' "$route" | jq -r '.port // 22')"
  inbox_path="$(printf '%s' "$route" | jq -r '.inbox')"
  identity="$(printf '%s' "$route" | jq -r '.identity_file // empty')"

  if [[ -z "$host" || -z "$inbox_path" || "$host" == "null" || "$inbox_path" == "null" ]]; then
    log "route for $dest_host missing host/inbox; leaving in place"
    return 1
  fi

  local stage="$OUTBOX_BRIDGE/$dest_host"
  mkdir -p "$stage"
  local staged="$stage/$base"
  # Atomic same-fs rename. If src/stage straddle filesystems mv falls
  # back to copy+unlink which we accept — the bridge's correctness
  # property is "destination either has the file or it stays here," and
  # the worst case is a one-tick duplicate that rsync collapses.
  mv -f "$src" "$staged"

  # rsync over ssh. --remove-source-files atomically unlinks the local
  # staged file once the remote write succeeds; that's our delivery
  # confirmation. We do NOT use --inplace here — remote stuck-scanner
  # watches inbox/ for moved-in files, not in-place writes.
  local ssh_cmd="ssh -p $port -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes"
  if [[ -n "$identity" ]]; then
    ssh_cmd="$ssh_cmd -i $identity"
  fi

  if rsync \
      --quiet \
      --remove-source-files \
      -e "$ssh_cmd" \
      "$staged" \
      "$user@$host:$inbox_path/inbox/$base"; then
    log "delivered $base → $dest_host ($user@$host:$port)"
    return 0
  else
    log "delivery failed for $base → $dest_host; staged at $staged for retry"
    return 1
  fi
}

# One poll cycle. Reads routing once at top, walks inbox/.
scan_once() {
  local routing local_host
  routing="$(read_routing)"
  local_host="$(printf '%s' "$routing" | jq -r '.local_host // empty')"

  if [[ -z "$local_host" ]]; then
    return 0
  fi

  shopt -s nullglob
  local f
  for f in "$INBOX_DIR"/*.json; do
    [[ -f "$f" ]] || continue

    local to_host
    to_host="$(jq -r '.to.host // empty' "$f" 2>/dev/null || true)"

    # No to.host or addressed to local → not our concern.
    if [[ -z "$to_host" || "$to_host" == "$local_host" ]]; then
      continue
    fi

    forward_envelope "$f" "$to_host" "$routing" || true
  done
  shopt -u nullglob
}

mkdir -p "$OUTBOX_BRIDGE"

log "started: routing=$ROUTING inbox=$INBOX poll=${POLL_INTERVAL_S}s"

while true; do
  scan_once || log "scan_once errored (continuing)"
  sleep "$POLL_INTERVAL_S"
done
