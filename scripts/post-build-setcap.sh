#!/bin/sh
# scripts/post-build-setcap.sh — Re-apply BPF capabilities after compilation.
#
# Called by scripts/build-once.sh after the build has compiled the ct binary. Re-applies cap_bpf+cap_perfmon+cap_dac_read_search
# via the codetracer-setcap helper installed by `just developer-setup` or
# the NixOS developer-bpf module.
#
# Silently succeeds if codetracer-setcap is not installed or if passwordless
# sudo is not available — the build still completes successfully.
#
# Usage:
#   scripts/post-build-setcap.sh [binary-path]
#
# If binary-path is omitted, targets the default ct binary.

SETCAP_CMD="$(command -v codetracer-setcap 2>/dev/null)" || exit 0
[ -z "$SETCAP_CMD" ] && exit 0

# Resolve to the real path (e.g. Nix store path) — sudo matches the sudoers
# rule against the resolved path, not the symlink.
SETCAP_REAL="$(readlink -f "$SETCAP_CMD")" || exit 0
[ -z "$SETCAP_REAL" ] && exit 0

if [ $# -gt 0 ]; then
	sudo -n "$SETCAP_REAL" "$1" 2>/dev/null || true
else
	sudo -n "$SETCAP_REAL" 2>/dev/null || true
fi
