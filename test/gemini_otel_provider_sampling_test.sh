#!/usr/bin/env bash
set -euo pipefail

script="${1:?usage: $0 path/to/gemini-otel.sh}"
helper="${2:-$(dirname "$script")/telemetry-batch.ex}"
tmp="$(mktemp -d)"
cleanup() {
  local rc=$? log
  if [[ $rc != 0 ]]; then
    for log in "$tmp"/*.curl; do [[ ! -f $log ]] || cat "$log" >&2; done
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
mkdir -p "$tmp/subject"
cp "$script" "$tmp/subject/gemini-otel.sh"
cp "$helper" "$tmp/subject/telemetry-batch.ex"
script="$tmp/subject/gemini-otel.sh"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
query=""
start=""
end=""
while (($#)); do
  case "$1" in
    --data-urlencode)
      [[ "${2:-}" == q=* ]] && query="${2#q=}"
      [[ "${2:-}" == start=* ]] && start="${2#start=}"
      [[ "${2:-}" == end=* ]] && end="${2#end=}"
      shift 2
      ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$start" "$end" "$url" >>"${CURL_ARGS_LOG:?}"

search() {
  local rows="$1" first=1 id ts
  printf '{"traces":['
  while read -r id ts; do
    [[ -n "$id" ]] || continue
    ((first)) || printf ','
    first=0
    printf '{"traceID":"%s","startTimeUnixNano":"%s"}' "$id" "$ts"
  done <<<"$rows"
  printf ']}\n'
}

if [[ "$url" == */api/v2/search/tag/span.gen_ai.system/values ]]; then
  [[ "${FIXTURE_CASE:?}" == tagfail ]] && exit 22
  case "${FIXTURE_CASE:?}" in
    starvation|drop)
      printf '%s\n' '{"tagValues":[{"type":"string","value":"anthropic"},{"type":"string","value":"openai-codex"}]}'
      ;;
    single)
      printf '%s\n' '{"tagValues":[{"type":"string","value":"anthropic"}]}'
      ;;
    unknown)
      printf '%s\n' '{"tagValues":[{"type":"string","value":"anthropic"},{"type":"string","value":"vertex"}]}'
      ;;
    overflow)
      printf '%s\n' '{"tagValues":[{"type":"string","value":"anthropic"},{"type":"string","value":"openai-codex"},{"type":"string","value":"vertex"}]}'
      ;;
  esac
  exit 0
fi

if [[ "$url" == */api/search ]]; then
  case "$FIXTURE_CASE:$query" in
    starvation:*'gen_ai.system = "anthropic"'*) search $'a400 400\na300 300\na200 200\na100 100' ;;
    starvation:*'gen_ai.system = "openai-codex"'*) search 'o350 350' ;;
    starvation:*) search $'a400 400\na300 300\na200 200\na100 100' ;;
    single:*'gen_ai.system = "anthropic"'*) search $'a300 300\na200 200\na100 100' ;;
    single:*) search $'a300 300\na200 200\na100 100' ;;
    drop:*'gen_ai.system = "anthropic"'*) search 'a300 300' ;;
    drop:*'gen_ai.system = "openai-codex"'*) search $'o500get 500\no400 400' ;;
    drop:*) search $'o500get 500\no400 400\na300 300' ;;
    unknown:*'gen_ai.system = "anthropic"'*) search 'a300 300' ;;
    unknown:*'gen_ai.system = "vertex"'*) search 'v250 250' ;;
    unknown:*) search $'a300 300\nv250 250' ;;
    tagfail:*'gen_ai.system = "anthropic"'*) search $'a400 400\na300 300\na200 200' ;;
    tagfail:*'gen_ai.system = "openai-codex"'*) search 'o350 350' ;;
    tagfail:*) search $'a400 400\na300 300\na200 200' ;;
    overflow:*'gen_ai.system = "anthropic"'*) search 'a300 300' ;;
    overflow:*'gen_ai.system = "openai-codex"'*) search 'o400 400' ;;
    overflow:*'gen_ai.system = "vertex"'*) search 'v500 500' ;;
    overflow:*) search $'v500 500\no400 400\na300 300' ;;
    *) search '' ;;
  esac
  exit 0
fi

if [[ "$url" == */api/traces/* ]]; then
  id="${url##*/}"
  case "$id" in
    a*) provider=anthropic; agent=claude_code ;;
    o*) provider=openai-codex; agent=codex_cli ;;
    v*) provider=vertex; agent=gemini_cli ;;
    *) provider=""; agent=unknown ;;
  esac
  method=POST
  [[ "$id" == o500get ]] && method=GET
  if [[ -n "$provider" ]]; then
    system_attr="{\"key\":\"gen_ai.system\",\"value\":{\"stringValue\":\"$provider\"}},"
  else
    system_attr=""
  fi
  printf '{"batches":[{"scopeSpans":[{"spans":[{"attributes":[%s{"key":"http.request.method","value":{"stringValue":"%s"}},{"key":"ai_pair.pane.agent","value":{"stringValue":"%s"}},{"key":"ai_pair.project","value":{"stringValue":"demo"}},{"key":"messaging.message.id","value":{"stringValue":"%s"}},{"key":"gen_ai.request.model","value":{"stringValue":"model"}},{"key":"gen_ai.operation.name","value":{"stringValue":"responses"}},{"key":"gen_ai.usage.input_tokens","value":{"intValue":"10"}},{"key":"gen_ai.usage.output_tokens","value":{"intValue":"2"}}]}]}]}]}\n' "$system_attr" "$method" "$agent" "$id"
  exit 0
fi

printf '%s\n' '{}'
EOF
chmod +x "$tmp/bin/curl"

cat >"$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == --print ]]; then
    printf '%s\n' "${2:?}" >"${AGY_CAPTURE:?}"
    break
  fi
  shift
done
printf '%s\n' '* Summary' 'fixture report' '' '* Findings' '- [info] fixture' '' '* Suggestions' '- none'
EOF
chmod +x "$tmp/bin/agy"

run_case() {
  local name="$1" limit="$2" inbox
  inbox="$tmp/inbox-$name"
  mkdir -p "$inbox"
  : >"$tmp/$name.curl"
  PATH="$tmp/bin:$PATH" \
    AI_PAIR_INBOX="$inbox" AI_PAIR_PROJECT=demo FIXTURE_CASE="$name" TEMPO=http://tempo-fixture.invalid \
    GEMINI_ORACLE_BIN=agy AGY_CAPTURE="$tmp/$name.prompt" \
    CURL_ARGS_LOG="$tmp/$name.curl" \
      bash "$script" otel --limit "$limit" >"$tmp/$name.out"
  [[ -s $tmp/$name.curl ]]
  while IFS= read -r line; do
    url=${line##*$'\t'}
    [[ $url == http://tempo-fixture.invalid/api/* ]]
  done <"$tmp/$name.curl"
  grep -Fq '/api/v2/search/tag/span.gen_ai.system/values' "$tmp/$name.curl"
  grep -Fq '/api/search' "$tmp/$name.curl"
  grep -Fq '/api/traces/' "$tmp/$name.curl"
  find "$inbox/gemini" -maxdepth 1 -type f -name 'otel-*.org' -print | sort | tail -1
}

report="$(run_case starvation 4)"
grep -q '^#+title: Gemini OTel analysis' "$report"
grep -Fq 'concise Org-mode report' "$tmp/starvation.prompt"
grep -Fq '"* Summary"' "$tmp/starvation.prompt"
grep -Fq -- '- calls analyzed: 4' "$report"
grep -Fq -- '- providers: anthropic=3, openai-codex=1' "$report"
[[ "$(grep -c '^trace_id:' "$tmp/starvation.prompt")" -eq 4 ]]
[[ "$(grep -c '^trace_id: o350$' "$tmp/starvation.prompt")" -eq 1 ]]
selected=()
while IFS= read -r line; do
  [[ $line != trace_id:* ]] || selected+=("${line#trace_id: }")
done <"$tmp/starvation.prompt"
[[ "${selected[*]}" == 'a200 a300 o350 a400' ]]
window_start='' window_end='' window_queries=0
while IFS= read -r line; do
  start=${line%%$'\t'*}
  rest=${line#*$'\t'}
  end=${rest%%$'\t'*}
  url=${rest#*$'\t'}
  [[ $url != */api/traces/* ]] || continue
  if [[ $window_queries == 0 ]]; then window_start=$start; window_end=$end; fi
  [[ -n $start && -n $end && $start == "$window_start" && $end == "$window_end" ]]
  window_queries=$((window_queries + 1))
done <"$tmp/starvation.curl"
[[ $window_queries -gt 0 ]]

report="$(run_case single 3)"
grep -Fq -- '- providers: anthropic=3, openai-codex=0' "$report"
[[ "$(grep -c '^trace_id:' "$tmp/single.prompt")" -eq 3 ]]

report="$(run_case drop 2)"
grep -Fq -- '- providers: anthropic=1, openai-codex=1' "$report"
grep -Fq 'trace_id: o400' "$tmp/drop.prompt"
if grep -Fq 'trace_id: o500get' "$tmp/drop.prompt"; then
  echo "non-POST trace entered the selected batch" >&2
  exit 1
fi

report="$(run_case unknown 2)"
grep -Fq -- '- providers: anthropic=1, openai-codex=0, vertex=1' "$report"
grep -Fq 'provider: vertex' "$tmp/unknown.prompt"

report="$(run_case tagfail 3)"
grep -Fq -- '- providers: anthropic=2, openai-codex=1' "$report"
grep -Fq 'trace_id: o350' "$tmp/tagfail.prompt"

report="$(run_case overflow 2)"
grep -Fq -- '- providers: anthropic=0, openai-codex=1, vertex=1' "$report"
if grep -Fq 'trace_id: a300' "$tmp/overflow.prompt"; then
  echo "oldest provider representative won when providers exceeded limit" >&2
  exit 1
fi

run_case starvation 4 >/dev/null
grep '^trace_id:' "$tmp/starvation.prompt" >"$tmp/selection-1"
run_case starvation 4 >/dev/null
grep '^trace_id:' "$tmp/starvation.prompt" >"$tmp/selection-2"
diff -u "$tmp/selection-1" "$tmp/selection-2"

echo "gemini otel provider sampling tests: PASS"
