#!/usr/bin/env bash
# =============================================================================
# CI wrapper for non-GUI tests.
#
# Handles the difference between NixOS (uses nix develop) and macOS (uses
# the non-nix build environment with detect-siblings.sh).
#
# Environment:
#   CODETRACER_CI_PLATFORM  — "nixos" or "macos" (default: "nixos")
# =============================================================================
set -euo pipefail

PLATFORM="${CODETRACER_CI_PLATFORM:-nixos}"

case "$PLATFORM" in
  nixos)
    # The nix dev shell hook builds and sets up the environment.
    # Override rr-backend detection so cross-repo tests don't run here.
    exec nix develop .#devShells.x86_64-linux.default --command \
      env CODETRACER_RR_BACKEND_PATH= CODETRACER_RR_BACKEND_PRESENT=0 just test
    ;;
  macos)
    # Source sibling detection for the non-nix environment.
    REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT"
    # Override rr-backend detection — rr is not available on macOS.
    export CODETRACER_RR_BACKEND_PATH=
    export CODETRACER_RR_BACKEND_PRESENT=0
    exec just test
    ;;
  *)
    echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
    exit 1
    ;;
esac
