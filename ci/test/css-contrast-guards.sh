#!/usr/bin/env bash
# =============================================================================
# CI wrapper for the BROWSER-ONLY stylesheet guards.
#
#   tests/status-bar/footer-visibility-css-guard.spec.ts
#       -- is every region the design requires actually THERE, and on screen
#   tests/status-bar/footer-contrast-guard.spec.ts
#       -- is what is there READABLE against the surface behind it
#   tests/build/build-panel-contrast-guard.spec.ts
#       -- is the BUILD output panel readable, on both themes, every severity
#
# WHY A STEP OF ITS OWN, given ``ui-tests-db.sh`` already runs the whole
# Playwright suite in this job. None of these needs Electron, a recorded trace,
# a language recorder or a display: each lays a surface's own markup out in a
# plain browser page with the COMPILED theme stylesheet and measures it.
# Running them here, BEFORE the full suite, means the regressions that have
# actually shipped from these surfaces -- the footer going tabs-only (three
# times: b27da3947, 51a3e820e, 00fd68b7f), its readouts painting at 1.22:1, and
# the build panel's output lines painting at 1.42:1 on the web and 1.05:1 under
# Electron -- are reported in seconds, by name, instead of surfacing an hour
# later as a suite-wide timeout in ``readyOnEntryTest``, which is how the first
# two announced themselves.
#
# THE THIRD ENTRY IS WHY THIS IS NO LONGER CALLED ``status-bar-guards.sh``.
# The build panel shipped the SAME defect as the footer -- a `color` that was
# never declared anywhere in the ancestry, so the text inherited the
# user-agent default -- on a different surface, and it too was found by a user
# looking at the screen rather than by anything in this repo. Three reports of
# one shape is a class of defect. The wrapper is named for the question now,
# so adding the next surface costs one line here instead of a new CI step.
#
# It also keeps them reachable on a leg where the full suite is skipped, and
# makes the failure attributable: a red step called "stylesheet guards"
# says what broke without reading a Playwright report.
#
# WHAT IT DEPENDS ON. Only the built theme stylesheets. The specs resolve them
# via ``CODETRACER_BUILD_DIR``, then ``src/build-debug/frontend/styles``, then
# ``$CODETRACER_E2E_CT_PATH/../../frontend/styles`` -- so this must run AFTER
# the CodeTracer build step, and it exports the same ct path ``ui-tests-db.sh``
# does so the third candidate resolves on both legs. The footer specs read
# ``default_{dark,white}_theme_electron.css``; the build-panel spec also reads
# ``default_dark_theme_extension.css``, which is the sheet the web shell serves
# and therefore the one the report came from. All three are built by the nix
# package (nix/packages/default.nix), so they resolve in ``result/`` as well as
# in a local tup ``src/build-debug``.
#
# THE STATIC SIBLING IS ``ci/test/css-token-resolution.sh``, and it is a
# separate step on purpose. These three ask whether a resolved colour is
# READABLE, which needs a rendered page and therefore a built stylesheet, which
# is why this wrapper runs after the package is built. That one asks whether
# the value RESOLVED AT ALL -- Stylus emits an unknown identifier verbatim, so
# ``color: colors-ui-text-accent`` compiles clean, reaches the browser as an
# invalid value and is dropped. That is a static property of the compiled CSS:
# it needs no browser, no display and no build, it compiles the stylesheets
# itself in about thirty seconds, and so it runs in ``viewmodel-tests``, long
# before anything here. Folding it in here would make a check that can run
# first run last.
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
		--command just test-css-contrast-guards
	;;
macos)
	export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/src/build-debug-repro/bin/ct}"
	exec nix develop . --command just test-css-contrast-guards
	;;
*)
	echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
	exit 1
	;;
esac
