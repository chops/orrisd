# ai-pair (peer-pair harness)

You are running inside an **ai-pair** project tmux session. Your peer is
Claude Code in the adjacent pane. Both panes share a per-project inbox
at `$AI_PAIR_INBOX`.

## Communicating with your peer

Peer messaging has two channels: a **content channel** (envelopes on
disk) and a **wakeup channel** (`ap send` through the daemon). The
content channel carries the payload; the wakeup channel tells the peer
pane to read it. Use both.

### Content channel — file-based peer protocol

Schema and examples in
`~/.ai-agent-inbox/<project>/peer-protocol.md`, or the installed package
resource at `<package>/share/ai-pair/peer-protocol.md`:

- Stage outgoing messages under `$AI_PAIR_INBOX/outbox/`
- Atomically `mv` into `$AI_PAIR_INBOX/inbox/` to publish
- Watch `$AI_PAIR_INBOX/inbox/` for incoming messages addressed to
  `to.agent == "codex"` (your role)
- Move consumed messages to `$AI_PAIR_INBOX/processed/<YYYY-MM-DD>/`
- All envelopes pin `schema_version: "1.0"`; `from`/`to` are objects
  `{agent, pane_id?}`, NOT bare strings
- When replying to a prior envelope, set `in_reply_to` to that
  envelope's `msg_id` so the peer (and triage) can chain Q→A. Optional
  but strongly recommended for `kind: "answer"` and follow-up
  `kind: "note"` / `kind: "status"`

### Wakeup channel — `ap send`

Dropping a file into `$AI_PAIR_INBOX/inbox/` does not wake the peer
pane. Nudge your peer via the daemon:

- `ap send <peer-pane-id> <text>` — type text into the peer pane via
  the daemon (paste-safe; queues if the peer is busy).
- `ap send <peer-pane-id> --stdin` — same, reading payload from stdin
  (use for multi-line nudges).
- `ap pane_status <pane-id>` — report pane state (idle|busy|…) and
  queue depth.
- `ap attach <pane-id> --agent claude_code|codex_cli` — register a
  pane with the daemon (only needed if the session was started outside
  `ap up`).
- `ap detach <pane-id>` — unregister a pane.

**Do not use raw `tmux send-keys` or `tmux paste-buffer` to wake your
peer.** Those bypass the daemon's idle/busy classifier and cause
overlapping pastes / lost prompts. The wakeup channel is `ap send`,
always.

## Consulting your peer

Use `ap consult <text...>` or `ap consult --stdin` for a formal
peer-pair consultation. The command stages a `kind: "consultation"`
envelope in this project's `$AI_PAIR_INBOX`, wakes the peer through the
daemon, and prints status JSON containing the consultation `msg_id` when
not waiting.

Add `--wait` to block for a correlated reply with `in_reply_to` set to
that `msg_id`; the default wait is 600 seconds. Use `--wait <secs>` for
a different timeout, and `--peer claude_code|codex_cli` only when the
peer cannot be inferred from the registered panes.

## Project scope

The environment variable `$AI_PAIR_PROJECT` names the current project.
`$AI_PAIR_PROJECT_DIR` is the absolute project path; `$AI_PAIR_INBOX` is
unique per project (basename + sha256:8 of the project path). Do not
write to another project's inbox.

## Daemon

The ai-pair Elixir daemon runs as a launchd user agent and exposes a
length-prefixed JSON IPC socket at `~/.ai-agent-inbox/ai-pair/sock/ai-pair.sock`.
Do not talk to the socket directly — `ap` is the user-facing CLI:
`ap up/down/status/doctor` for lifecycle, `ap send/attach/pane_status/detach`
for the wakeup channel above. The daemon does pane fingerprinting +
safe-send queueing; it does not arbitrate peer messages.

## Workflow

- `ap up` from a project root starts/attaches the pair session.
- `ap status` reports session + daemon health.
- `ap doctor` runs sanity checks (binaries, sockets, env divergence).
- `ap migrate <dir>` scaffolds `.envrc` into project directories.

If `$AI_PAIR_INBOX` is unset, you are NOT inside an ai-pair session —
fall back to normal Codex CLI behavior and do not attempt peer-protocol
I/O.
