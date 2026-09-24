# Agent guidance

This file is for AI coding agents working in this repository. It grants no new
language, scope, publication or permission. The owners' task assignment governs
what you may change; where the assignment is narrower than this file, the
assignment wins. It does not change the contribution policy in
[CONTRIBUTING.org](CONTRIBUTING.org).

## Languages

- The approved implementation languages are Elixir, Bash, Nix and Rust. New
  executable code must be one of them, including tests, test helpers and
  generated scripts. Data and documentation formats are not implementation
  languages.
- Do not use `sed`, `awk`, `jq`, `python`, `perl` or `shasum` in scripts, tests
  or the commands you run. Use Elixir, Bash builtins, `grep`, `rg` or `sha256sum`.

## Toolchain and verification

- The toolchain is Elixir 1.20.4 with Erlang/OTP 29.0.5 from the pinned Nix
  development shell, and `bin/verify` enforces it. `.tool-versions` currently
  lists older versions and conflicts with the gate; follow the Nix shell, not
  `.tool-versions`.
- Run the full gate from a Git checkout:

```bash
nix develop --impure --command bin/verify
```

- Results from any other toolchain are informative only. State the toolchain you used.

## Tests

- For a behaviour change, write the test first and show that it fails for the
  stated reason before changing product code.
- A RED test is never skipped, tagged out, excluded or weakened to make CI pass.
  If the product does not meet the requirement, the test stays RED and is reported.
- Tests that start OS processes, tmux servers or sockets use bounded timeouts,
  uniquely named disposable resources, and cleanup that runs when the test fails.

## Git

- Stage explicit paths, for example `git add lib/ai_pair/example.ex`. Never use
  `git add -A` or `git add .`.
- Never push to `main`. Never force-push or rewrite published history. Work on a
  branch and open a draft pull request unless your assignment says otherwise.
- Never merge without an explicit independent release for the exact head.

## Verification protocol

When a head is ready, comment `READY FOR VERIFICATION at <full commit sha>` on
the pull request and stop pushing to that branch until the report for that head
is posted. Verification runs only at the declared head, on the pinned toolchain.
Any push after the declaration lapses it: declare the new head, and it is
verified from scratch.

## Credentials and status

- Do not read, print, copy or commit credential files, such as agent
  authentication files, tokens, private keys or secret environment files. Tests
  must not touch them either.
- Do not claim that a requirement or register row is closed without the
  supporting independent review. Report what changed, the commands you ran and
  their result lines.

## Documentation

Ordinary documentation uses Org; see
[the documentation format policy](docs/documentation-format.org). This file is
Markdown because agent tools read `AGENTS.md` by name, and it is listed in
`docs/markdown-exceptions.tsv`.
