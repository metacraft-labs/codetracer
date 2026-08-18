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
	exec nix develop .#devShells.x86_64-linux.default --command \
		env CODETRACER_RR_BACKEND_PATH= CODETRACER_RR_BACKEND_PRESENT=0 just test
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
	# ``nix develop .`` selects the host-default aarch64-darwin dev shell
	# (mirroring the nixos branch, which pins the x86_64-linux shell).
	exec nix develop . --command \
		env CODETRACER_RR_BACKEND_PATH= CODETRACER_RR_BACKEND_PRESENT=0 just test
	;;
*)
	echo "ERROR: unknown CODETRACER_CI_PLATFORM: $PLATFORM" >&2
	exit 1
	;;
esac
