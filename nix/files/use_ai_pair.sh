# shellcheck shell=bash
# use_ai_pair — direnv layout for ai-pair-scoped projects.
#
# Sourced via `use ai_pair` in a project's .envrc. Zero-nix on purpose:
# direnv runs this on every `cd`, so anything heavyweight (nix eval, IFD,
# devenv up) belongs in `use flake` / `use devenv`, not here.
#
# What it sets:
#   AI_PAIR_PROJECT       basename of project dir
#   AI_PAIR_PROJECT_HASH  sha256:8 of project absolute path
#   AI_PAIR_PROJECT_DIR   absolute project path
#   AI_PAIR_INBOX         per-project inbox under $AI_PAIR_INBOX_BASE
#                         (default: $HOME/.ai-agent-inbox)
#
# Idempotent: re-sourcing is a no-op if vars already match.

use_ai_pair() {
  local workdir
  workdir="$(pwd -P)"
  local project_basename project_hash
  project_basename="$(basename "$workdir")"
  project_hash="$(printf '%s' "$workdir" | sha256sum)" || return
  project_hash="${project_hash:0:8}"

  local inbox_base="${AI_PAIR_INBOX_BASE:-$HOME/.ai-agent-inbox}"
  local inbox="$inbox_base/${project_basename}-${project_hash}"

  export AI_PAIR_PROJECT="$project_basename"
  export AI_PAIR_PROJECT_HASH="$project_hash"
  export AI_PAIR_PROJECT_DIR="$workdir"
  export AI_PAIR_INBOX="$inbox"

  # Watch the .envrc itself so direnv reloads on edit.
  watch_file "$workdir/.envrc"
}
