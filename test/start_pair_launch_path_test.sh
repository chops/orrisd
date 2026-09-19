#!/usr/bin/env bash
set -euo pipefail

start_pair="${1:?usage: start_pair_launch_path_test.sh PATH_TO_START_PAIR}"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

fake_bin="$root/bin"
tool_bin="$root/tools"
mkdir -p "$fake_bin" "$tool_bin" "$root/home" "$root/work"
for tool in bash basename sha256sum head mkdir ln date dirname; do
  ln -s "$(command -v "$tool")" "$tool_bin/$tool"
done

cat >"$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case "${1:-}" in
  has-session) exit 1 ;;
  display-message)
    case "$*" in
      *pair.0*) printf '%%1\n' ;;
      *pair.1*) printf '%%2\n' ;;
    esac
    ;;
esac
EOF

cat >"$fake_bin/ai-pair" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/tmux" "$fake_bin/ai-pair"

# The Linux Nix build sandbox has no /usr/bin, so an executable whose shebang
# is /usr/bin/env bash cannot be run there and its caller sees exit 126. This
# check had never been built by CI, so nothing had discovered that. Point every
# executable this test writes at the bash the test itself is running.
bash_bin="$(command -v bash)"
retarget_shebang() {
  local file body
  for file in "$@"; do
    body="$(tail -n +2 "$file")"
    # A copy of a store file inherits its read-only mode, so make it writable
    # before the rewrite and executable again after it.
    chmod u+w "$file"
    printf '#!%s\n%s\n' "$bash_bin" "$body" >"$file"
    chmod +x "$file"
  done
}
retarget_shebang "$fake_bin/tmux" "$fake_bin/ai-pair"

fail() {
  printf 'start-pair launch-path test: %s\n' "$*" >&2
  exit 1
}

run_start_pair() {
  local name="$1"
  mkdir -p "$root/$name/inbox"
  HOME="$root/home" \
    PATH="$fake_bin:$tool_bin" \
    AI_PAIR_INBOX="$root/$name/inbox" \
    AI_PAIR_GEMINI_WINDOW=0 \
    AI_PAIR_AUTODISMISS_TRUSTGATES=0 \
    AI_PAIR_SKIP_CODEX_AUTH_CHECK=1 \
    FAKE_TMUX_LOG="$root/$name/tmux.log" \
    bash "$start_pair" --detach --workdir "$root/work" \
      >"$root/$name/stdout" 2>"$root/$name/stderr"
}

run_start_pair raw
grep -F 'llm-proxy-shim not found; launching raw CLIs with NO TELEMETRY' \
  "$root/raw/stderr" >/dev/null || fail "raw fallback was silent on stderr"
grep -F 'WARN: llm-proxy-shim not found; launching raw CLIs with NO TELEMETRY' \
  "$root/raw/inbox/logs/start-pair.log" >/dev/null || fail "raw fallback was silent in the start log"

cat >"$fake_bin/llm-proxy-shim" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin/llm-proxy-shim"
retarget_shebang "$fake_bin/llm-proxy-shim"

run_start_pair shim
if grep -F 'NO TELEMETRY' "$root/shim/stderr" "$root/shim/inbox/logs/start-pair.log" >/dev/null; then
  fail "shim launch emitted the raw-fallback warning"
fi
grep -F 'LLM launch path: llm-proxy-shim (telemetry enabled)' \
  "$root/shim/inbox/logs/start-pair.log" >/dev/null || fail "shim launch path was not logged"
grep -F 'llm-proxy-shim codex' "$root/shim/tmux.log" >/dev/null || \
  fail "Codex was not launched through the shim"

printf 'start-pair launch-path tests: PASS\n'
