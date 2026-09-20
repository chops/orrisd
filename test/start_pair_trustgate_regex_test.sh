#!/usr/bin/env bash
# Pins the start-pair cold-start auto-dismiss default to workspace-trust text.
#
# start-pair sends one bare Enter to a pane when the daemon classifies it as
# :dialog AND the visible pane content matches TRUSTGATE_REGEX. Enter confirms
# whichever row has focus, so the default may match a workspace-trust prompt
# and nothing else: permission prompts are never approved by classification.
# This test renders the default from the launcher text (never by running the
# launcher) and applies it with the launcher's own predicate, grep -Eqi, to
# the daemon fingerprint fixtures and to prompt labels measured in the CLIs.
set -euo pipefail

usage='usage: start_pair_trustgate_regex_test.sh PATH_TO_START_PAIR FINGERPRINT_FIXTURE_DIR'
start_pair="${1:?$usage}"
fixtures="${2:?$usage}"

fail() {
  printf 'start-pair trust-gate regex test: %s\n' "$*" >&2
  exit 1
}

[[ -f "$start_pair" ]] || fail "launcher not found: $start_pair"
[[ -d "$fixtures/claude_code" && -d "$fixtures/codex_cli" ]] ||
  fail "fingerprint fixture directory not found under: $fixtures"

# Render the default exactly as the launcher assigns it. The assignment shape
# is part of the contract: AI_PAIR_TRUSTGATE_REGEX must keep replacing the
# default wholesale, so an operator who widens it does so explicitly.
prefix="TRUSTGATE_REGEX=\"\${AI_PAIR_TRUSTGATE_REGEX:-"
suffix="}\""
assignments="$(grep -F "$prefix" "$start_pair" || true)"
assignment_count="$(printf '%s\n' "$assignments" | grep -c . || true)"
[[ "$assignment_count" == 1 ]] ||
  fail "expected exactly one TRUSTGATE_REGEX default assignment, found $assignment_count"
[[ "$assignments" == "$prefix"*"$suffix" ]] ||
  fail "TRUSTGATE_REGEX assignment shape changed; the AI_PAIR_TRUSTGATE_REGEX override must stay"
regex="${assignments#"$prefix"}"
regex="${regex%"$suffix"}"
[[ -n "$regex" ]] || fail "rendered an empty default regex"

# The launcher runs: printf '%s' "$content" | grep -Eqi "$TRUSTGATE_REGEX".
# Reading the fixture file directly is the same per-line ERE search over the
# same bytes, and the literal helper feeds one line through the same pipe.
fixture_matches() {
  grep -Eqi "$regex" "$1"
}

literal_matches() {
  printf '%s' "$1" | grep -Eqi "$regex"
}

require_fixture() {
  [[ -f "$fixtures/$1" ]] || fail "fixture missing, control could not run: $1"
}

# Workspace-trust screens: the only screens one Enter may confirm.
trust_fixtures=(
  claude_code/dialog_trust_gate_first_run.txt
  codex_cli/dialog_trust_gate_0131_first_run.txt
)
for name in "${trust_fixtures[@]}"; do
  require_fixture "$name"
  fixture_matches "$fixtures/$name" || fail "trust gate no longer matches: $name"
done

trust_literals=(
  'Do you trust the contents of this directory?'
  'Yes, I trust this folder'
)
for text in "${trust_literals[@]}"; do
  literal_matches "$text" || fail "trust prompt text no longer matches: $text"
done

# Approval-shaped :dialog fixtures for the Codex profile. A match here would
# let the cold-start loop confirm a tool approval.
approval_fixtures=(
  codex_cli/dialog_trust_gate_tool_approval.txt
  codex_cli/dialog_trust_gate_bypass.txt
  codex_cli/dialog_trust_gate_yolo.txt
)
for name in "${approval_fixtures[@]}"; do
  require_fixture "$name"
  if fixture_matches "$fixtures/$name"; then
    fail "approval-shaped dialog fixture matches the trust-gate default: $name"
  fi
done

# Claude busy/idle screens carrying the auto-mode banner ("Claude can make
# mistakes that allow harmful commands to run"). These are never :dialog, so
# a match was inert, but a default satisfied by a status banner carries no
# information about what has focus and must not match.
banner_fixtures=(
  claude_code/busy_007.txt
  claude_code/busy_008.txt
  claude_code/busy_009.txt
  claude_code/busy_010.txt
  claude_code/busy_011.txt
  claude_code/idle_003.txt
)
for name in "${banner_fixtures[@]}"; do
  require_fixture "$name"
  if fixture_matches "$fixtures/$name"; then
    fail "auto-mode banner fixture matches the trust-gate default: $name"
  fi
done

# Prompt labels read out of the installed CLIs (Codex 0.155.1 approval option
# table, Claude Code 2.1.278 permission options and banner), plus the Codex
# session-trust and model-switch wording. None may match.
approval_literals=(
  'Yes, proceed'
  'Yes, just this once'
  'Yes, and allow this host for this conversation'
  'Yes, and allow these permissions for this session'
  'Would you like to run the following command?'
  'Yes, allow reading from the workspace during this session'
  'Yes, allow external imports'
  'Do you want to proceed?'
  'Do you want to allow this?'
  'Claude can make mistakes that allow harmful commands to run'
  'Press enter to continue'
  'Trust this session?'
)
for text in "${approval_literals[@]}"; do
  if literal_matches "$text"; then
    fail "approval-shaped text matches the trust-gate default: $text"
  fi
done

printf 'start-pair trust-gate regex tests: PASS (%s)\n' "$regex"
