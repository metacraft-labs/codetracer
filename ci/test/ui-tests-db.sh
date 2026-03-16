#!/usr/bin/env bash
# =============================================================================
# CI wrapper for DB-based UI tests (Playwright).
#
# Handles the difference between NixOS (uses nix develop + nix-built binary)
# and macOS (uses the non-nix build + system Playwright).
#
# Environment:
#   CODETRACER_CI_PLATFORM  — "nixos" or "macos" (default: "nixos")
#   CODETRACER_E2E_CT_PATH  — path to ct binary (overridable)
# =============================================================================
set -euo pipefail

PLATFORM="${CODETRACER_CI_PLATFORM:-nixos}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "$PLATFORM" in
  nixos)
    export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/result/bin/ct}"
    export CODETRACER_DB_TESTS_ONLY=1
    exec nix develop .#devShells.x86_64-linux.default --command just test-gui
    ;;
  macos)
    export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/non-nix-build/CodeTracer.app/Contents/MacOS/bin/ct}"
    export CODETRACER_DB_TESTS_ONLY=1
    source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT"
    cd "$REPO_ROOT/tsc-ui-tests"
    npm install --no-audit --no-fund
    npx playwright install
    npx playwright test --workers=1
    ;;
  *)
    echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
    exit 1
    ;;
esac
