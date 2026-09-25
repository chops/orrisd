#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
scanner="$repo_root/bin/redaction-check"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/redaction-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'redaction-check test failed: %s\n' "$1" >&2
  exit 1
}

run_capture() {
  local expected=$1
  shift
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  [[ $status -eq $expected ]] || fail "expected exit $expected, got $status: $output"
}

mkdir "$tmp/repo"
cd "$tmp/repo"
git init -q
git config user.name test
git config user.email test@example.invalid
printf 'safe\n' >tracked.txt
git add tracked.txt
git commit -qm baseline

run_capture 0 "$scanner"

pane_sample="pane ""%""196 ready"
printf '%s\n' "$pane_sample" >tracked.txt
run_capture 0 "$scanner" --staged
run_capture 1 "$scanner"
[[ "$output" == *"tracked.txt:1:tmux_pane_id"* ]] || fail "tracked finding lacks its masked locator"
[[ "$output" != *"$pane_sample"* ]] || fail "tracked finding printed matched content"

git add tracked.txt
run_capture 1 "$scanner" --staged
[[ "$output" == *"tracked.txt:1:tmux_pane_id"* ]] || fail "staged finding lacks its masked locator"

mkdir nested
cd nested
run_capture 1 "$scanner"
[[ "$output" == *"tracked.txt:1:tmux_pane_id"* ]] || fail "nested invocation did not scan from the Git root"
cd ..

printf 'format %%42s\n' >tracked.txt
git add tracked.txt
run_capture 0 "$scanner" --staged

external="$tmp/evidence"
mkdir "$external"

pattern_names=(
  macos_home
  linux_home
  user_profile
  agent_inbox
  tmux_pane_id
  private_key
  anthropic_token
  provider_token
  github_token
  github_pat
  aws_access_key
  slack_token
  gitlab_token
  google_api_key
  jwt_token
  bearer_token
  url_basic_auth
)

samples=(
  "/""Users/alice/project/"
  "/""home/alice/project/"
  "/etc/profiles/per-""user/alice/bin/tool"
  ".""ai-agent-inbox/example-deadbeef/inbox"
  "pane ""%""204 ready"
  "-----""BEGIN PGP PRIVATE KEY BLOCK-----"
  "s""k-ant-abcdefghijklmnopqrstuvwxyz123456"
  "s""k-abcdefghijklmnopqrstuvwxyz1234567890"
  "g""hp_abcdefghijklmnopqrstuvwxyz123456"
  "github_""pat_abcdefghijklmnopqrstuvwxyz123456"
  "A""SIAABCDEFGHIJKLMNOP"
  "x""oxr-abcdefghijklmnopqrstuvwxyz123456"
  "g""lpat-abcdefghijklmnopqrstuvwxyz123456"
  "A""Izaabcdefghijklmnopqrstuvwxyz123456789"
  "e""yJabcdefghijklmno.eyJpqrstuvwxyz123."
  "B""earer abcdefghijklmnopqrstuvwxyz123456"
  "http""s://user:password@example.invalid/path"
)

for index in "${!pattern_names[@]}"; do
  sample=${samples[$index]}
  pattern=${pattern_names[$index]}
  printf '%s\n' "$sample" >"$external/sample.txt"
  run_capture 1 "$scanner" --paths "$external"
  [[ "$output" == *"<external-1>/sample.txt:1:$pattern"* ]] || fail "$pattern was not reported"
  [[ "$output" != *"$sample"* ]] || fail "$pattern printed matched content"
done

generic_token="s""k-abcdefghijklmnopqrstuvwxyz1234567890"
printf '%s\n' "$generic_token" >"$external/sample.txt"
mkdir "$tmp/grep-fallback"
ln -s "$(command -v sha256sum)" "$tmp/grep-fallback/sha256sum"
run_capture 1 env PATH="$tmp/grep-fallback:/bin:/usr/bin" "$scanner" --paths "$external"
[[ "$output" == *"<external-1>/sample.txt:1:provider_token"* ]] || fail "grep fallback missed a provider token"

anthropic_token="s""k-ant-abcdefghijklmnopqrstuvwxyz123456"
printf '%s\n' "$anthropic_token" >"$external/sample.txt"
run_capture 1 "$scanner" --paths "$external"
[[ $(grep -c ':anthropic_token$' <<<"$output") -eq 1 ]] || fail "Anthropic token was not reported once"
[[ "$output" != *":provider_token"* ]] || fail "Anthropic token was reported twice"

printf '%s\n' "$generic_token" >"$external/sample.txt"
run_capture 1 "$scanner" --locators --paths "$external"
locator=$(grep '^provider_token:<external-1>/sample.txt:' <<<"$output")
[[ -n "$locator" ]] || fail "locator mode did not emit a provider-token locator"
[[ "$locator" != *"$generic_token"* ]] || fail "locator mode disclosed matched content"
printf '%s # reviewed synthetic test value\n' "$locator" >allow
run_capture 0 "$scanner" --allowlist allow --paths "$external"

printf '%s # reviewed without terminal newline' "$locator" >allow
run_capture 0 "$scanner" --allowlist allow --paths "$external"
printf '%sx # not the exact locator\n' "$locator" >allow
run_capture 1 "$scanner" --allowlist allow --paths "$external"
printf '%s # reviewed synthetic test value\n' "$locator" >allow

printf '\n%s\n' "$generic_token" >"$external/sample.txt"
run_capture 0 "$scanner" --allowlist allow --paths "$external"

changed_token="${generic_token}x"
printf '%s\n' "$changed_token" >"$external/sample.txt"
run_capture 1 "$scanner" --allowlist allow --paths "$external"
[[ "$output" != *"$changed_token"* ]] || fail "changed allowlisted value was disclosed"

printf '%s\n' "$locator" >allow
run_capture 2 "$scanner" --allowlist allow --paths "$external"
[[ "$output" == *"needs an exact locator"* ]] || fail "malformed allowlist was not explained"

# Characterization of current scanner behaviour (scope slice 1: T-3, T-3b,
# T-4, T-11). These cases record what the scanner does today; they are not
# statements of desired behaviour. Every expected exit status and stream below
# is source-derived (bin/redaction-check plus the git grep index walk and
# binary probe) and must be confirmed by the first gated run; the receipt of
# that run must record the git and grep that ran.

run_streams() {
  local expected=$1
  shift
  set +e
  "$@" >"$tmp/stdout" 2>"$tmp/stderr"
  status=$?
  set -e
  stdout_text=
  stderr_text=
  IFS= read -r -d '' stdout_text <"$tmp/stdout" || true
  IFS= read -r -d '' stderr_text <"$tmp/stderr" || true
  [[ $status -eq $expected ]] || fail "expected exit $expected, got $status: $stdout_text$stderr_text"
}

expect_streams() {
  local case_name=$1 expected_stdout=$2 expected_stderr=$3
  [[ "$stdout_text" == "$expected_stdout" ]] || fail "$case_name stdout differs: $stdout_text"
  [[ "$stderr_text" == "$expected_stderr" ]] || fail "$case_name stderr differs: $stderr_text"
}

github_value="g""hp_abcdefghijklmnopqrstuvwxyz123456"
control_value="g""lpat-abcdefghijklmnopqrstuvwxyz123456"
home_target="/""home/alice/project/target"
control_only=$'control.txt:1:gitlab_token\nredaction-check: 1 finding(s)\n'

# Each fixture repo carries control.txt with a text value of another family,
# so every scan below is expected to report exactly the control finding and
# a clean result cannot come from a scan that examined nothing.
new_fixture_repo() {
  mkdir "$tmp/$1"
  cd "$tmp/$1"
  git init -q
  git config user.name test
  git config user.email test@example.invalid
  printf '%s\n' "$control_value" >control.txt
}

# T-3: tracked file with a NUL byte before a matching value. git grep -I
# treats it as binary (NUL within the probe window, no attributes) and
# reports no match for it, in tracked and staged mode.
new_fixture_repo binary-fixture
printf 'bin\000%s\n' "$github_value" >bin.dat
git add control.txt bin.dat
git commit -qm binary
run_streams 1 "$scanner"
expect_streams "T-3 tracked binary" "" "$control_only"
run_streams 1 "$scanner" --staged
expect_streams "T-3 staged binary" "" "$control_only"

# T-3 paths mode through the grep fallback: a PATH holding only bash, grep,
# basename and sha256sum, so rg cannot be selected on any host. grep -I skips
# the NUL-bearing file; the text control is the second root.
mkdir "$tmp/paths-grep-only"
for tool in bash grep basename sha256sum; do
  ln -s "$(command -v "$tool")" "$tmp/paths-grep-only/$tool"
done
run_streams 1 env PATH="$tmp/paths-grep-only" "$scanner" --paths bin.dat control.txt
expect_streams "T-3 paths grep binary" "" \
  $'<external-2>/control.txt:1:gitlab_token\nredaction-check: 1 finding(s)\n'

# T-3b: text file marked binary by .gitattributes. The binary macro unsets
# the diff attribute, git grep takes the file as binary and -I reports no
# match for it, in tracked and staged mode.
new_fixture_repo attributes-fixture
printf '%s\n' "$github_value" >attr.txt
printf 'attr.txt binary\n' >.gitattributes
git add control.txt attr.txt .gitattributes
git commit -qm attributes
run_streams 1 "$scanner"
expect_streams "T-3b tracked attributes" "" "$control_only"
run_streams 1 "$scanner" --staged
expect_streams "T-3b staged attributes" "" "$control_only"

# T-4: tracked symlink whose target text matches linux_home. git grep walks
# only regular-file index entries, so the 120000 entry is not reported in
# tracked or staged mode.
new_fixture_repo symlink-fixture
ln -s "$home_target" link
git add control.txt link
git commit -qm symlink
link_entry=$(git ls-files -s -- link)
[[ "$link_entry" == "120000 "* ]] || fail "T-4 fixture link is not a symlink entry: $link_entry"
run_streams 1 "$scanner"
expect_streams "T-4 tracked symlink" "" "$control_only"
run_streams 1 "$scanner" --staged
expect_streams "T-4 staged symlink" "" "$control_only"

# T-11 (Q6): intent-to-add entry versus a genuine empty committed file.
new_fixture_repo intent-fixture
: >empty.txt
git add control.txt empty.txt
git commit -qm intent
run_streams 1 "$scanner"
expect_streams "T-11 tracked empty file alone" "" "$control_only"
printf '%s\n' "$github_value" >ita.txt
git add -N ita.txt
# Mode, object id and stage are identical for the two entries, so the
# object id alone cannot tell intent-to-add from a genuine empty file.
ita_entry=$(git ls-files -s -- ita.txt)
empty_entry=$(git ls-files -s -- empty.txt)
[[ "${ita_entry%%$'\t'*}" == "${empty_entry%%$'\t'*}" ]] ||
  fail "T-11 intent-to-add entry differs from the empty file entry: $ita_entry / $empty_entry"
[[ "$empty_entry" == "100644 "*" 0"$'\t'"empty.txt" ]] || fail "T-11 empty file entry shape: $empty_entry"
# Candidate discriminator: porcelain status shows the intent-to-add entry as
# added in the worktree only, and does not list the committed empty file.
ita_status=$(git status --porcelain --untracked-files=no)
[[ "$ita_status" == " A ita.txt" ]] || fail "T-11 intent-to-add status: $ita_status"
# Tracked mode reads the worktree bytes of the intent-to-add path and reports
# its value; staged mode skips intent-to-add entries.
run_streams 1 "$scanner"
expect_streams "T-11 tracked intent-to-add" "" \
  $'ita.txt:1:github_token\ncontrol.txt:1:gitlab_token\nredaction-check: 2 finding(s)\n'
run_streams 1 "$scanner" --staged
expect_streams "T-11 staged intent-to-add" "" "$control_only"

printf 'redaction-check tests: ok\n'
