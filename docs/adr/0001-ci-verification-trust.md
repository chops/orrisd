---
status: accepted
date: 2026-09-03
---

# ADR-0001: CI verification trust

## Context

The development flake names the `devenv.cachix.org` binary cache. GitHub Actions
needs that cache to avoid building devenv's dependency graph from source, but a
workflow that accepts cache settings from the checked-out branch lets branch
content choose additional binary substituters.

## Decision

The workflow pins the approved `cache.nixos.org` and `devenv.cachix.org`
substituters and public keys in the pinned Nix installer action. The verification
step does not use `--accept-flake-config`. Local development may accept the
repository flake configuration because the operator controls the checkout.

The canonical product gate remains `bin/verify`; CI and local development invoke
that same script from the pinned Nix environment.

## Consequences

- A branch cannot expand CI binary-cache trust by editing `flake.nix` alone.
- Rotating an approved cache key requires a reviewed workflow change.
- Local and CI toolchains remain identical even though their cache-trust setup is
  expressed at different boundaries.

## Provenance

This document is the decision record.
