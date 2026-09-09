# ai-pair peer-protocol (v1)

A simple file-based protocol for inter-agent messages within an ai-pair
project. Compatible with Orris peer-envelope routing (so a project may
participate in both without translation), but scoped to a single project
and consumed locally by ai-pair watcher panes.

## Layout

```
$AI_PAIR_INBOX/
├── inbox/        ← incoming messages (writer-owned, dest-readable)
├── outbox/       ← outgoing messages (this agent's drafts, before rename)
├── processed/    ← messages this agent has consumed; retained for replay
├── logs/         ← human-readable session logs (start-pair, rotators)
└── sock/         ← UDS sockets (ai-pair.sock; managed by daemon)
```

## Atomic publish

Writers MUST stage messages in `outbox/` (or a tempfile under
`inbox/.tmp-<uuid>`) and then `rename(2)` into `inbox/`. The destination
agent SHOULD watch `inbox/` for rename events (kqueue / IN_MOVED_TO) or
fall back to polling; either way, only complete (post-rename) messages
are consumed. Partial writes are invisible.

After consumption, the reader moves the file to `processed/<YYYY-MM-DD>/`
(date-partitioned). The launchd-timer rotator (`logs/` retention) is the
shipped pruner; a `processed/` retention rotator is planned ("keep last
14 days" target) but is not yet wired.

## Envelope schema

```json
{
  "schema_version": "1.0",
  "msg_id": "01J9X3T2QF5G7H8K1N3PMRBV6Y",
  "ts": "2026-05-12T18:30:00Z",
  "from": { "agent": "claude", "pane_id": "%17", "host": "host-a",           "avm_id": "host-a",           "work_key": "pr42" },
  "to":   { "agent": "codex",  "pane_id": null,  "host": "host-b",           "avm_id": "host-b",           "work_key": "pr42" },
  "kind": "note",
  "subject": "short human label",
  "body": "free-form markdown payload",
  "in_reply_to": "01J9X3T2QF5G7H8K1N3PMRBV6Y",
  "links": [ "file://...", "https://..." ],
  "context": { "project": "ai-pair", "topic_slug": "..." }
}
```

### Required fields

`schema_version`, `msg_id`, `ts`, `from.agent`, `to.agent`, `kind`, `body`.

### Field notes

- **`schema_version`**: pinned to `"1.0"` (string). Forward-compat: future
  schemas bump the string; readers MUST refuse unknown majors and MAY
  warn on minor mismatches.
- **`from` / `to`**: objects, not strings. Allows `pane_id` to be carried
  forward without a breaking change later. Receivers ignore unknown keys
  inside these objects.
- **`from.host` / `to.host`**: optional, nullable. Names the host that owns the producing / target pane. Single-host deployments
  MAY omit. Multi-host deployments SHOULD populate so the bridge unit can
  route across `$AI_PAIR_INBOX` islands without re-parsing pane IDs.
- **`from.avm_id` / `to.avm_id`**: optional, nullable. Matches the
  deployment guest identifier (e.g. `guest-a`), historically named AVM.
  Distinct from `host` so one host can run multiple guests.
- **`from.work_key` / `to.work_key`**: optional, nullable. The work-key
  slug (`pr<n>`, `gh<n>`, `slug+hash`) that identifies the worktree this
  envelope belongs to. Lets routers correlate envelopes that span a
  single piece of work even when the pair-session names diverge.
- **`msg_id`**: an opaque identifier of 16–64 ASCII letters, digits,
  underscores or hyphens. ULIDs, UUIDs and the CLI's timestamp/random IDs
  fit this grammar. `ap consult` uses `<msg_id>.json` as the filename.
- **`kind`**: one of `note`, `ask`, `answer`, `status`, `handoff`, or
  `consultation`, closed for v1. `consultation` is the formal peer-pair
  consultation request kind emitted by `ap consult`; replies SHOULD use
  `kind="answer"` with `in_reply_to` set to the consultation `msg_id`.
  Adding another value is a minor bump.
- **`ts`**: RFC3339 in UTC with `Z` suffix. Local time labeled UTC is a
  spec violation.
- **`in_reply_to`**: optional, nullable. The `msg_id` of the envelope this
  one is responding to. Set on `kind="answer"` replies; MAY appear on
  `kind="note"` / `kind="status"` follow-ups. Same character set and
  length bounds as `msg_id`. Receivers MUST treat unknown reply-targets
  as harmless (no lookup required) and MUST NOT fail validation when the
  referenced envelope is absent. Enables threaded triage and Q→A
  chaining at the file layer; no OTel attribute is emitted from this
  field today (instrumenting it is a future minor bump).

## File lifecycle

1. Sender writes payload to `outbox/<ts>-<msg_id>.json.tmp`.
2. Sender `fsync` + `rename` to `inbox/<ts>-<msg_id>.json` (final name).
3. Receiver picks up rename event, reads file, validates schema, processes.
4. Receiver `rename` to `processed/<YYYY-MM-DD>/<msg_id>.json`.
5. Rotator (separate launchd timer) prunes `logs/`; a `processed/`
   pruner with the same shape is planned but not yet shipped.

## Failure modes

- **Schema reject**: receiver moves to `processed/<date>/_rejected/`
  with a `.reject.txt` companion explaining the failed assertion.
- **Stuck inbox**: the daemon scans regular `.json` files every 60 seconds.
  Files at least five minutes old by modification time emit an
  `[:ai_pair, :inbox, :stuck]` telemetry event if their addressed pane is
  registered and idle, or no pane ID is present. The scanner does not move
  or delete envelopes and does not write a dedicated `stuck.log`.
  This is an age/state signal, not proof that an agent accepted a task.

## Triage: pivot from msg_id to trace

Every envelope carries a `msg_id`. When `ap send` is used (with or
without `--msg-id`), that ID is stamped on the OTel attribute
`messaging.message.id` on the three spans of the send chain
(`cli.send`, `ipc.send`, `pane.paste`).

To find the trace for a given envelope (in Grafana → Explore → Tempo):

```
{.messaging.message.id="<msg_id>"}
```

The leading dot is "any-scope" — it matches the attribute whether it
appears on the span, resource, or event scope. Check the returned trace and
query coverage in the configured Tempo instance.

If you need to filter by span kind, AND a name intrinsic into the
predicate. Do NOT replace the attribute predicate:

```
{name="cli.send" && span.messaging.message.id="<msg_id>"}
```

### Tempo 2.10 footgun (do not use)

The intuitive scoped form

```
{resource.service.name="ai-pair" && span.messaging.message.id="<id>"}
```

was observed to behave incorrectly on Tempo 2.10: it returns up to 20
unrelated traces and reports `inspectedJobs < totalJobs` (e.g. 1 of 3
instead of 19 of 19). The bare `span.X="v"` form short-circuits the
planner onto the wrong index path. Always prefer the any-scope dot
form `{.X="v"}` or pair the attribute with a `name=` / `kind=`
intrinsic.

## Compatibility with other consumers

The `schema_version` and the `from`/`to` object shape identify this protocol.
Other consumers may attach fields for their own routing or task metadata.
Readers MUST ignore unknown fields, following the forward-compatibility rule
above; such fields do not add daemon commands or delivery guarantees.
