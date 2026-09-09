# Orrisd

Orrisd is the agent coordination runtime for [Orris](https://github.com/chops/orris).
It combines an Elixir/OTP daemon with a command-line interface for managing agent
panes in tmux, classifying their state, and queuing messages until a pane can
receive them. Versioned delivery receipts support reconciliation after uncertain
send outcomes.

This is an early source release. The repository includes the daemon, CLI, Nix
packaging and modules, protocol documentation, and tests. Product development is
ongoing.

## Contributing

This project is in an early stage of development. We are not currently accepting external code contributions while we establish the architecture, governance, and contribution policies for the project.

Bug reports, feature requests, design feedback, and discussions are welcome.

For now, please do not submit pull requests, patches, source-code implementations, or substantial code snippets through issues, discussions, email, or other channels. This includes unsolicited implementations of bug fixes or requested features.

You are welcome to clone, fork, modify, and experiment with the project in accordance with the Apache License 2.0.

We expect to revisit external code contributions as the project matures.

## What is here

- Pane registration, terminal fingerprint classification, state tracking, and
  queued delivery through the daemon.
- Project-scoped peer envelopes and consultations, with a separate daemon
  wakeup channel.
- A local Unix-domain-socket IPC protocol, including version 2 delivery identity,
  receipts, and reconciliation.
- OpenTelemetry instrumentation and optional telemetry analysis helpers.
- Nix packages and service modules for macOS and Linux.

The public project name is **Orrisd**. Existing identifiers remain `ai-pair`,
`AiPair`, `:ai_pair`, and `ap`, including environment variables, file paths,
service labels, and Nix module options. Examples and code use those identifiers.

## Develop and verify

The pinned Nix development environment provides Elixir 1.20.4 with Erlang/OTP 29.0.5
and verification tools. From a clone with Nix installed and flakes enabled:

```sh
nix develop --impure --command bin/verify
```

The verifier fetches locked dependencies, validates the pinned redaction scanner
and its tests, scans tracked files, checks formatting, compiles and runs Elixir
tests with warnings as errors, runs shell regression tests, and runs ShellCheck.
Run it from a Git checkout so the tracked-file scan has its intended input.
The development shell uses devenv and requires `--impure`; it may fetch build
inputs and initialize local Hex/Rebar caches. Tests use an isolated temporary
inbox.

Build the daemon and CLI packages without installing or starting a service:

```sh
nix build .#default .#ap
nix flake check --impure
```

The CLI scripts require host tools and agent executables appropriate to the
chosen command. Building the packages does not configure those tools or agent
accounts. Review the Nix modules and runtime configuration before starting a
session or enabling a service.

## Optional integrations and compatibility

The launcher can use an operator-supplied `llm-proxy-shim`; without it, it
launches the agent CLIs directly. Telemetry analysis expects an independently
configured Tempo service and spans named `llm-otel-proxy`. It uses the external
`agy` oracle CLI by default (`GEMINI_ORACLE_BIN` can override it). Optional
`codex-check` and `codex-relogin` helpers support operator-managed agent accounts.
These helpers and their authentication configuration are not supplied by this
repository. `AI_PAIR_GEMINI_WINDOW=0` disables the optional analyst window.

Legacy service labels are compatibility identifiers: the Darwin module uses
`dev.fxo.ai-pair`, while `ap doctor` also recognizes the older
`io.charlesholloway.ai-pair` form. This source release preserves those identifiers.
Host routing and bridge SSH keys are configured through the supplied NixOS
module; enabling it is an operator deployment decision.

## Runtime and protocol

The `ap` CLI includes `up`, `down`, `status`, `doctor`, `attach`, `detach`,
`pane_status`, `send`, `consult`, `ping`, and `reconcile`. `up` creates a tmux
session; `send` submits text through the daemon's pane-state queue; `consult`
stages a peer envelope and wakes its recipient. A queued response is distinct
from a confirmed send or completed agent task.

The daemon uses a local Unix-domain socket. The default socket is
`~/.ai-agent-inbox/ai-pair/sock/ai-pair.sock`; project inboxes are separate.
Agent authentication and credentials are configured by the operator in the
agent tools themselves.

- [IPC contract](docs/contracts/ipc-v1.md), including version 2 extensions
- [Peer envelope protocol](nix/files/peer-protocol.md)
- [Delivery receipt design](docs/adr/0003-delivery-receipt-store.md)
- [Versioned delivery wiring](docs/adr/0004-versioned-delivery-wiring.md)
- [Redaction scanner contract](docs/contracts/redaction-scanner.org)
- [Dependency licenses](DEPENDENCIES.md)

The source includes bridge and telemetry helpers. Their presence does not imply
that multi-host orchestration or the full Orris control plane is complete.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
