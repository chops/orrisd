#!/usr/bin/env bash
# ap doctor is the operator's entire installation-verification surface, and
# until this file existed no test ran it except through the project-scoped
# environment-drift legs that test/ap_project_resolution_test.sh already pins.
# Those four legs are deliberately NOT repeated here. What is pinned here is
# everything else doctor decides: agent binaries on PATH, sibling wrapper
# resolution when PATH omits the profile directory, daemon socket presence,
# the launchd entry leg, and the manifest uds-json-ping round trip in its
# healthy, refused and unrunnable shapes.
#
# Every binary doctor consults is a fake inside the test root, so nothing here
# reaches an installed daemon, a real launchd, or a real tmux server.
set -euo pipefail

ap_source="${1:?usage: ap_doctor_test.sh PATH_TO_AP PATH_TO_START_PAIR [PATH_TO_TOOLING]}"
start_pair_source="${2:?usage: ap_doctor_test.sh PATH_TO_AP PATH_TO_START_PAIR [PATH_TO_TOOLING]}"
tooling_source="${3:-$(dirname "$ap_source")/tooling.ex}"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

bin="$root/bin"
tools="$root/tools"
# Short names: the daemon socket path below hangs off $home and an AF_UNIX
# path has a hard length limit (104 bytes on darwin) that a deep build
# sandbox temp directory can otherwise push it past.
home="$root/h"
project="$root/p"
mkdir -p "$bin" "$tools" "$home" "$project"
project="$(cd "$project" && pwd -P)"

sock_dir="$home/.ai-agent-inbox/ai-pair/sock"
sock="$sock_dir/ai-pair.sock"
mkdir -p "$sock_dir"

cp "$ap_source" "$bin/ap"
cp "$start_pair_source" "$bin/start-pair"
cp "$tooling_source" "$bin/tooling.ex"
chmod +x "$bin/ap" "$bin/start-pair"

for tool in bash basename cat date dirname elixir grep head mkdir ln mktemp rm sha256sum tail timeout tr uname; do
  resolved="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then ln -s "$resolved" "$tools/$tool"; fi
done

fail() {
  printf 'ap doctor test: %s\n' "$*" >&2
  exit 1
}

# The Linux Nix build sandbox has no /usr/bin, so an executable whose shebang
# is /usr/bin/env bash cannot be run there and its caller sees exit 126. Point
# every executable this test writes at the bash the test itself is running.
bash_bin="$(command -v bash)"
retarget_shebang() {
  local file body
  for file in "$@"; do
    body="$(tail -n +2 "$file")"
    printf '#!%s\n%s\n' "$bash_bin" "$body" >"$file"
  done
}

# A real AF_UNIX socket file, because doctor tests the daemon socket with
# [[ -S ]] and a regular file would pass a weaker test than the real one.
cat >"$root/mksock.exs" <<'EOF'
path = System.fetch_env!("SOCK_PATH")
{:ok, socket} = :gen_tcp.listen(0, [{:ifaddr, {:local, String.to_charlist(path)}}])
:ok = :gen_tcp.close(socket)
EOF
SOCK_PATH="$sock" elixir "$root/mksock.exs"
[[ -S "$sock" ]] || fail "test setup did not create a unix socket at $sock"

cat >"$bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# The healthcheck client. FAKE_PING_MODE selects the reply doctor has to
# classify; the manifest calls this exchange uds-json-ping.
cat >"$bin/ai-pair" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ping" ]]; then
  case "${FAKE_PING_MODE:-ok}" in
    ok)     printf '{"ok":true,"pong":"0.1.0-fake"}\n' ;;
    refuse) printf '{"ok":false,"error":"daemon_not_running"}\n' ;;
    *)      printf 'ai-pair: connect failed\n'; exit 1 ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$bin/tmux" "$bin/claude" "$bin/codex" "$bin/ai-pair"
retarget_shebang "$bin/ap" "$bin/start-pair" "$bin/tmux" "$bin/claude" "$bin/codex" "$bin/ai-pair"

# Runs doctor with a controlled PATH and a clean project-scoped environment,
# and records stdout, stderr and the exit status. Never inherits the caller's
# TMUX, AI_PAIR or profile PATH, so no installed component can answer.
doctor_ap="$bin/ap"

run_doctor() {
  local label="$1" path="$2"
  shift 2
  mkdir -p "$root/$label"
  set +e
  (
    cd "$project" || exit 111
    unset WORKDIR AI_PAIR_PROJECT AI_PAIR_PROJECT_DIR AI_PAIR_PROJECT_HASH
    unset AI_PAIR_INBOX AI_PAIR_CODEX_HOME CODEX_HOME TMUX TMUX_PANE
    env HOME="$home" PATH="$path" AI_PAIR_INBOX_BASE="$home/.ai-agent-inbox" "$@" \
      "$doctor_ap" doctor >"$root/$label/out" 2>"$root/$label/err"
  )
  printf '%s' "$?" >"$root/$label/rc"
  set -e
}

rc_of() { cat "$root/$1/rc"; }

out_has() {
  grep -F "$2" "$root/$1/out" >/dev/null || fail "$3"
}

err_has() {
  grep -F "$2" "$root/$1/err" >/dev/null || fail "$3"
}

# Leg 1: everything present. Doctor must pass and report each surface.
run_doctor healthy "$bin:$tools"
[[ "$(rc_of healthy)" == "0" ]] || fail "doctor failed on a complete installation: $(cat "$root/healthy/err")"
out_has healthy "[ ok ] tmux" "doctor did not report tmux on PATH"
out_has healthy "[ ok ] claude" "doctor did not report claude on PATH"
out_has healthy "[ ok ] codex" "doctor did not report codex on PATH"
out_has healthy "[ ok ] socket $sock" "doctor did not report the daemon socket"
out_has healthy "[ ok ] healthcheck uds-json-ping (pong=0.1.0-fake" \
  "doctor did not report the manifest healthcheck round trip or its pong"
out_has healthy "[ ok ] project-scoped environment agrees with the session root" \
  "doctor did not report a clean project-scoped environment"
out_has healthy "launchd: no ai-pair entry" \
  "doctor treated an absent launchctl as anything other than a note"

# Leg 2: the agent CLIs are missing. Doctor must fail, name both, and still
# report the surfaces that come after them rather than exiting at the first.
agents_gone="$root/agents-gone"
mkdir -p "$agents_gone"
ln -s "$bin/tmux" "$agents_gone/tmux"
ln -s "$bin/ai-pair" "$agents_gone/ai-pair"
run_doctor no-agents "$agents_gone:$tools"
[[ "$(rc_of no-agents)" != "0" ]] || fail "doctor accepted an installation with no claude and no codex"
err_has no-agents "[FAIL] claude not on PATH" "doctor did not report the missing claude binary"
err_has no-agents "[FAIL] codex not on PATH" "doctor did not report the missing codex binary"
out_has no-agents "[ ok ] socket $sock" "doctor stopped at the first failure instead of reporting every surface"

# Leg 3: the daemon socket is absent.
mv "$sock" "$root/parked.sock"
run_doctor no-socket "$bin:$tools"
mv "$root/parked.sock" "$sock"
[[ "$(rc_of no-socket)" != "0" ]] || fail "doctor accepted a missing daemon socket"
err_has no-socket "[FAIL] socket $sock missing" "doctor did not report the missing daemon socket"

# Leg 4: the daemon answers, and refuses. Socket presence is not proof of life,
# which is the whole reason the manifest declares a healthcheck.
run_doctor ping-refused "$bin:$tools" FAKE_PING_MODE=refuse
[[ "$(rc_of ping-refused)" != "0" ]] || fail "doctor accepted a not-ok healthcheck reply beside a present socket"
err_has ping-refused "[FAIL] healthcheck uds-json-ping failed" \
  "doctor did not report the refused healthcheck"
err_has ping-refused "daemon_not_running" \
  "doctor discarded the client output that says why the healthcheck failed"

# Leg 5: the healthcheck cannot run at all, because no client is resolvable.
# ap is copied somewhere with no ai-pair sibling AND run with a PATH that has
# none either, since sibling resolution alone would otherwise find one.
no_client="$root/no-client"
lonely="$root/lonely"
mkdir -p "$no_client" "$lonely"
for name in tmux claude codex; do ln -s "$bin/$name" "$no_client/$name"; done
cp "$ap_source" "$lonely/ap"
cp "$tooling_source" "$lonely/tooling.ex"
chmod +x "$lonely/ap"
retarget_shebang "$lonely/ap"
doctor_ap="$lonely/ap"
run_doctor no-client "$no_client:$tools"
doctor_ap="$bin/ap"
[[ "$(rc_of no-client)" != "0" ]] || fail "doctor accepted an installation with no resolvable ai-pair client"
err_has no-client "[FAIL] healthcheck cannot run" \
  "doctor reported a healthcheck result with no client to run it"

# Leg 6: PATH omits the profile directory entirely. Sibling resolution is the
# reason ap up does not die with start-pair: not found in such a shell, so it
# must still resolve start-pair, ap and the healthcheck client next to itself.
run_doctor siblings "$tools"
out_has siblings "[ ok ] start-pair → $bin/start-pair" \
  "doctor did not resolve start-pair as a sibling when PATH omitted it"
out_has siblings "[ ok ] ap → $bin/ap" \
  "doctor did not resolve ap as a sibling when PATH omitted it"
out_has siblings "[ ok ] healthcheck uds-json-ping (pong=0.1.0-fake" \
  "doctor did not resolve the healthcheck client as a sibling when PATH omitted it"

# Leg 7: a launchd entry exists. Fake launchctl, so no real launchd is queried.
cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then
  printf '%s\n' '-\t0\tio.charlesholloway.ai-pair'
  exit 0
fi
exit 1
EOF
chmod +x "$bin/launchctl"
retarget_shebang "$bin/launchctl"
run_doctor launchd "$bin:$tools"
[[ "$(rc_of launchd)" == "0" ]] || fail "doctor failed with a listed launchd agent: $(cat "$root/launchd/err")"
out_has launchd "[ ok ] launchd agent listed" "doctor did not report the listed launchd agent"
rm -f "$bin/launchctl"

printf 'ap doctor tests: PASS\n'
