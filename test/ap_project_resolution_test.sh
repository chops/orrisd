#!/usr/bin/env bash
set -euo pipefail

ap_source="${1:?usage: ap_project_resolution_test.sh PATH_TO_AP PATH_TO_START_PAIR}"
start_pair_source="${2:?usage: ap_project_resolution_test.sh PATH_TO_AP PATH_TO_START_PAIR}"
tooling_source="${3:-$(dirname "$ap_source")/tooling.ex}"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

bin="$root/bin"
tools="$root/tools"
project_x="$root/project-x"
project_y="$root/project-y"
project_z="$root/project-z"
home="$root/home"
mkdir -p "$bin" "$tools" "$project_x" "$project_y" "$project_z" "$home"
export AI_PAIR_INBOX_BASE="$home/.ai-agent-inbox"
project_x="$(cd "$project_x" && pwd -P)"
project_y="$(cd "$project_y" && pwd -P)"
project_z="$(cd "$project_z" && pwd -P)"
cp "$ap_source" "$bin/ap"
cp "$start_pair_source" "$bin/start-pair"
cp "$tooling_source" "$bin/tooling.ex"
chmod +x "$bin/ap" "$bin/start-pair"

for tool in bash basename cat date dirname elixir grep head mkdir ln mktemp od rm sha256sum tail tr uname; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$resolved" ]] && ln -s "$resolved" "$tools/$tool"
done

cat >"$bin/tmux" <<'EOF'
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

cat >"$bin/ai-pair" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ping" ]]; then
  printf '{"ok":true,"pong":"test"}\n'
  exit 0
fi
if [[ -z "${FAKE_CLIENT_ENV:-}" ]]; then
  exit 0
fi
{
  printf 'command=%s\n' "${1:-}"
  printf 'project_dir=%s\n' "${AI_PAIR_PROJECT_DIR-}"
  printf 'project_hash=%s\n' "${AI_PAIR_PROJECT_HASH-}"
  printf 'inbox=%s\n' "${AI_PAIR_INBOX-}"
} >"$FAKE_CLIENT_ENV"
EOF

cat >"$bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin/tmux" "$bin/ai-pair" "$bin/claude" "$bin/codex"

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
retarget_shebang "$bin/ap" "$bin/start-pair" "$bin/tmux" "$bin/ai-pair" "$bin/claude" "$bin/codex"

fail() {
  printf 'ap project-resolution test: %s\n' "$*" >&2
  exit 1
}

hash_path() {
  printf '%s' "$1" | sha256sum | head -c 8
}

for project_var in \
  WORKDIR AI_PAIR_PROJECT AI_PAIR_PROJECT_DIR AI_PAIR_PROJECT_HASH \
  AI_PAIR_INBOX AI_PAIR_CODEX_HOME CODEX_HOME; do
  grep -Eq "unset .*\\b${project_var}\\b" "$ap_source" ||
    fail "ap up does not clear start-pair input $project_var"
done

run_up() {
  local target="$1" name="$2"
  shift 2
  mkdir -p "$root/$name"
  (
    cd "$target"
    HOME="$home" \
      PATH="$bin:$tools" \
      WORKDIR="$project_x" \
      AI_PAIR_PROJECT="project-x" \
      AI_PAIR_PROJECT_DIR="$project_x" \
      AI_PAIR_PROJECT_HASH="$(hash_path "$project_x")" \
      AI_PAIR_INBOX="$root/stale-inbox" \
      AI_PAIR_CODEX_HOME="$root/stale-inbox/codex-home" \
      AI_PAIR_GEMINI_WINDOW=0 \
      AI_PAIR_AUTODISMISS_TRUSTGATES=0 \
      AI_PAIR_SKIP_CODEX_AUTH_CHECK=1 \
      FAKE_TMUX_LOG="$root/$name/tmux.log" \
      "$bin/ap" up --detach "$@" >"$root/$name/stdout" 2>"$root/$name/stderr"
  )
}

run_up "$project_y" lifecycle-fresh
y_hash="$(hash_path "$project_y")"
grep -F "ai-pair/project-y-$y_hash" "$root/lifecycle-fresh/tmux.log" >/dev/null || \
  fail "ap up inherited the outer session identity"
grep -F "AI_PAIR_INBOX=$home/.ai-agent-inbox/project-y-$y_hash" "$root/lifecycle-fresh/tmux.log" >/dev/null || \
  fail "ap up did not derive the target inbox"
grep -F "CODEX_HOME=$home/.ai-agent-inbox/project-y-$y_hash/codex-home" "$root/lifecycle-fresh/tmux.log" >/dev/null || \
  fail "ap up did not derive an isolated target Codex home"
if grep -F "$project_x" "$root/lifecycle-fresh/tmux.log" >/dev/null; then
  fail "ap up leaked the outer project into the target session"
fi

mkdir -p "$root/clean-baseline"
(
  unset WORKDIR AI_PAIR_PROJECT AI_PAIR_PROJECT_DIR AI_PAIR_PROJECT_HASH
  unset AI_PAIR_INBOX AI_PAIR_CODEX_HOME CODEX_HOME
  cd "$project_y"
  HOME="$home" PATH="$bin:$tools" AI_PAIR_GEMINI_WINDOW=0 \
    AI_PAIR_AUTODISMISS_TRUSTGATES=0 AI_PAIR_SKIP_CODEX_AUTH_CHECK=1 \
    FAKE_TMUX_LOG="$root/clean-baseline/tmux.log" \
    "$bin/ap" up --detach >"$root/clean-baseline/stdout" 2>"$root/clean-baseline/stderr"
)
grep -F "ai-pair/project-y-$y_hash" "$root/clean-baseline/tmux.log" >/dev/null || \
  fail "clean ap up baseline did not resolve the current project"

run_up "$project_y" lifecycle-override --workdir "$project_z"
z_hash="$(hash_path "$project_z")"
grep -F "ai-pair/project-z-$z_hash" "$root/lifecycle-override/tmux.log" >/dev/null || \
  fail "ap up --workdir did not select the explicit target"

status_out="$root/status.out"
(
  cd "$root"
  HOME="$home" PATH="$bin:$tools" FAKE_TMUX_LOG="$root/status.tmux" \
    AI_PAIR_PROJECT="project-y" AI_PAIR_PROJECT_DIR="$project_y" \
    AI_PAIR_PROJECT_HASH="$y_hash" AI_PAIR_INBOX="$home/.ai-agent-inbox/project-y-$y_hash" \
    WORKDIR="$project_x" "$bin/ap" status >"$status_out"
)
grep -F "project:        project-y  ($project_y)" "$status_out" >/dev/null || \
  fail "in-pane status did not remain anchored to the stamped session root"

FAKE_CLIENT_ENV="$root/consult.env" HOME="$home" PATH="$bin:$tools" \
  AI_PAIR_PROJECT="project-y" AI_PAIR_PROJECT_DIR="$project_y" \
  AI_PAIR_PROJECT_HASH="$y_hash" AI_PAIR_INBOX="$root/stale-inbox" \
  WORKDIR="$project_x" "$bin/ap" consult test
grep -F "project_dir=$project_y" "$root/consult.env" >/dev/null || \
  fail "consult did not resolve the stamped session root"
grep -F "inbox=$home/.ai-agent-inbox/project-y-$y_hash" "$root/consult.env" >/dev/null || \
  fail "consult retained a stale inbox"

set +e
FAKE_CLIENT_ENV="$root/doctor-client.env" HOME="$home" PATH="$bin:$tools" \
  AI_PAIR_PROJECT="project-y" AI_PAIR_PROJECT_DIR="$project_y" \
  AI_PAIR_PROJECT_HASH="deadbeef" AI_PAIR_INBOX="$root/stale-inbox" \
  AI_PAIR_CODEX_HOME="$root/stale-inbox/codex-home" WORKDIR="$project_x" \
  "$bin/ap" doctor >"$root/doctor.out" 2>"$root/doctor.err"
doctor_rc=$?
set -e
[ "$doctor_rc" -ne 0 ] || fail "doctor accepted project-scoped environment drift"
grep -F "WORKDIR=$project_x disagrees with session root $project_y" "$root/doctor.err" >/dev/null || \
  fail "doctor did not report WORKDIR drift"
grep -F "AI_PAIR_INBOX=$root/stale-inbox disagrees with expected" "$root/doctor.err" >/dev/null || \
  fail "doctor did not report inbox drift"
grep -F "AI_PAIR_CODEX_HOME=$root/stale-inbox/codex-home disagrees with expected" "$root/doctor.err" >/dev/null || \
  fail "doctor did not report Codex-home drift"
grep -F "AI_PAIR_PROJECT_HASH=deadbeef disagrees with expected $y_hash" "$root/doctor.err" >/dev/null || \
  fail "doctor did not report project-hash drift"
grep -F "WORKDIR        = $project_y" "$root/doctor.out" >/dev/null || \
  fail "doctor reported the stale root after detecting drift"

printf 'ap project-resolution tests: PASS\n'
