#!/usr/bin/env bash
# =============================================================================
# CI wrapper for non-GUI tests.
#
# Both NixOS and macOS run the tests inside codetracer's nix dev shell; the
# macOS branch additionally sources detect-siblings.sh for the recorder
# siblings and selects the host-default (aarch64-darwin) dev shell.
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
	#
	# Graceful skipping is OFF: a test whose prerequisite is missing fails
	# instead of passing having asserted nothing. The tests needing tools this
	# lane does not install are named in ci/test/non-gui-not-provided.linux.txt;
	# `just test-rust` excludes them by name and prints each as NOT RUN with the
	# lane that runs it.
	exec nix develop .#devShells.x86_64-linux.default --command \
		env CODETRACER_RR_BACKEND_PATH= CODETRACER_RR_BACKEND_PRESENT=0 \
		CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false \
		CODETRACER_TEST_LANE_NOT_PROVIDED=ci/test/non-gui-not-provided.linux.txt \
		just test
	;;
macos)
	REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

	# Toolchain (nim / cargo / cargo-nextest / nimsuggest) comes from
	# codetracer's nix dev shell now, not non-nix-build/deps. Source sibling
	# detection first so the recorder path env vars (python / ruby / BEAM)
	# propagate into the dev-shell subprocess.
	# shellcheck disable=SC1091 # Path resolved at runtime from $REPO_ROOT
	source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT"
	# Override rr-backend detection — rr is not available on macOS.
	#
	# Graceful skipping is OFF, as on Linux. The tests needing tools this leg
	# does not provide are named in ci/test/non-gui-not-provided.macos.txt, with
	# the leg's toolset and the lane that runs each.
	# ``nix develop .`` selects the host-default aarch64-darwin dev shell
	# (mirroring the nixos branch, which pins the x86_64-linux shell).
	exec nix develop . --command \
		env CODETRACER_RR_BACKEND_PATH= CODETRACER_RR_BACKEND_PRESENT=0 \
		CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false \
		CODETRACER_TEST_LANE_NOT_PROVIDED=ci/test/non-gui-not-provided.macos.txt \
		just test
	;;
*)
	echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
	exit 1
	;;
esac
