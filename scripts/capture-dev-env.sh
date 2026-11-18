#!/usr/bin/env bash
# Capture Nix's Bash program without exposing a partially written environment.
# The guard must precede every Nix assignment: a shellHook guard is too late
# for zsh, which stops at Nix's assignment to its read-only LINENO parameter.
# NOT-A-CI-GATE: developer capture helper, exercised by test-captured-dev-env.sh.
set -euo pipefail
if [ "$#" -lt 1 ] || [ -z "$1" ]; then
	printf '%s\n' 'usage: capture-dev-env.sh OUTPUT [nix print-dev-env arguments...]' >&2
	exit 2
fi
destination=$1
shift
case "$destination" in
/*) ;;
*) destination="$PWD/$destination" ;;
esac
if [ -d "$destination" ]; then
	printf 'capture destination is a directory: %s\n' "$destination" >&2
	exit 2
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
capture_tmp=$(mktemp "${destination}.tmp.XXXXXX")
trap 'rm -f -- "$capture_tmp"' EXIT
cat >"$capture_tmp" <<'GUARD'
# Nix print-dev-env produces Bash code. Refuse before evaluating any of it.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'CodeTracer: source this captured environment from bash; use bash -c '\''source "$1" && <command>'\'' captured-env /path/to/env.sh' >&2
    return 1
fi
GUARD
cd "$repo"
nix print-dev-env --no-write-lock-file "$@" >>"$capture_tmp"
mv -f -- "$capture_tmp" "$destination"
