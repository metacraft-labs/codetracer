#!/usr/bin/env bash
# =============================================================================
# CI wrapper for the two BROWSER-ONLY status-bar footer guards.
#
#   tests/status-bar/footer-visibility-css-guard.spec.ts
#       -- is every region the design requires actually THERE, and on screen
#   tests/status-bar/footer-contrast-guard.spec.ts
#       -- is what is there READABLE against the surface behind it
#
# WHY A STEP OF ITS OWN, given ``ui-tests-db.sh`` already runs the whole
# Playwright suite in this job. These two need no Electron, no recorded trace,
# no language recorder and no display: they lay the footer's markup out in a
# plain browser page with the COMPILED theme stylesheet and measure it. Running
# them here, BEFORE the full suite, means the two regressions that have
# actually shipped from this bar -- the footer going tabs-only (three times:
# b27da3947, 51a3e820e, 00fd68b7f) and its readouts painting at 1.22:1 -- are
# reported in seconds, by name, instead of surfacing an hour later as a
# suite-wide timeout in ``readyOnEntryTest``, which is how the first two
# announced themselves.
#
# It also keeps them reachable on a leg where the full suite is skipped, and
# makes the failure attributable: a red step called "status bar footer guards"
# says what broke without reading a Playwright report.
#
# WHAT IT DEPENDS ON. Only the built theme stylesheets. The specs resolve them
# via ``CODETRACER_BUILD_DIR``, then ``src/build-debug/frontend/styles``, then
# ``$CODETRACER_E2E_CT_PATH/../../frontend/styles`` -- so this must run AFTER
# the CodeTracer build step, and it exports the same ct path ``ui-tests-db.sh``
# does so the third candidate resolves on both legs. Both specs read only
# ``default_{dark,white}_theme_electron.css``, which are the two themes the nix
# package builds (nix/packages/default.nix), so they resolve in ``result/`` as
# well as in a local tup ``src/build-debug``.
#
# Environment:
#   CODETRACER_CI_PLATFORM  -- "nixos" or "macos" (default: "nixos")
#   CODETRACER_E2E_CT_PATH  -- path to the ct binary (overridable)
# =============================================================================
set -euo pipefail

PLATFORM="${CODETRACER_CI_PLATFORM:-nixos}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "$PLATFORM" in
nixos)
	export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/result/bin/ct}"
	exec nix develop .#devShells.x86_64-linux.default \
		--command just test-status-bar-guards
	;;
macos)
	export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/src/build-debug-repro/bin/ct}"
	exec nix develop . --command just test-status-bar-guards
	;;
*)
	echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
	exit 1
	;;
esac
