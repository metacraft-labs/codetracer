#!/usr/bin/env bash
# =============================================================================
# CI wrapper for DB-based UI tests (Playwright).
#
# Both NixOS and macOS run Playwright inside codetracer's nix dev shell; they
# differ only in which prebuilt ct binary they point at (the nix-built
# ``result/bin/ct`` on NixOS vs the reprobuild ``src/build-debug-repro/bin/ct``
# on macOS) and in the Xvfb wrapping (test-gui-prebuilt starts Xvfb on Linux;
# macOS drives test-e2e directly with the native display).
#
# Arguments are forwarded to Playwright, so a caller can name a single spec
# (e.g. ``tests/event-log/event_log_is_static_across_jumps.spec.ts``) and get a
# separately attributable CI step for it. With no arguments the whole DB-based
# suite runs, which is the default every existing caller relies on.
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
	exec nix develop .#devShells.x86_64-linux.default --command just test-gui-prebuilt "$@"
	;;
macos)
	# The ct binary comes from codetracer's reprobuild build
	# (``just build-once`` on Darwin -> ``src/build-debug-repro/bin/ct``),
	# produced by the workflow's "Build CodeTracer (nix dev shell)" step.
	export CODETRACER_E2E_CT_PATH="${CODETRACER_E2E_CT_PATH:-$REPO_ROOT/src/build-debug-repro/bin/ct}"
	export CODETRACER_DB_TESTS_ONLY=1
	# rr is not available on macOS.
	export CODETRACER_RR_BACKEND_PATH=
	export CODETRACER_RR_BACKEND_PRESENT=0
	# Source sibling detection first so recorder path env vars propagate
	# into the dev-shell subprocess.
	# shellcheck disable=SC1091 # Path resolved at runtime from $REPO_ROOT
	source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT"
	# Run the Playwright suite inside the host-default (aarch64-darwin) dev
	# shell so node / npm / npx / Playwright browsers come from /nix/store.
	# Use ``just test-e2e`` rather than ``just test-gui-prebuilt``: the
	# latter starts Xvfb on every non-Windows host, which macOS neither has
	# nor needs (Electron uses the native display); ``test-e2e`` special-
	# cases Darwin and cd's into ``src/tests/gui`` (the Playwright suite kept
	# the historical ``tsc-ui-tests`` package name but the directory moved
	# into the source tree) to run ``npx playwright test --workers=1``.
	exec nix develop . --command just test-e2e "$@"
	;;
*)
	echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
	exit 1
	;;
esac
