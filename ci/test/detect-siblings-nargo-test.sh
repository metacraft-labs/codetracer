#!/usr/bin/env bash
#
# detect-siblings-nargo-test.sh -- contract suite for the `nargo` that
# scripts/detect-siblings.sh leaves in charge of the dev shell.
#
# WHAT IS BEING PINNED
# --------------------
# The dev shell provides `nargo` from the flake's pinned noir. A workspace may
# ALSO hold a `noir` sibling with a `target/release/nargo` in it, built from
# whatever that checkout was on whenever someone last built it. If the detector
# puts that build first on PATH and in NARGO_PATH unconditionally, every test
# that runs `nargo` records with it, and a months-old build writes containers
# the current reader refuses. That is what happened: a sibling nargo built
# before the interning-table record change made sixteen db-backend tests fail
# with "funcs.dat record is truncated" on one machine and pass everywhere else.
#
# So the invariant is: THE DEV SHELL'S NARGO WINS unless the developer asks for
# the sibling build by name. Every case comes in pairs -- opted in and not --
# because a selector that only ever gives one answer is the defect.
#
# Fixtures are built under mktemp with the real directory layout and sourced in
# a subshell. Pure bash; no nix, no noir, nothing compiled.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DETECT="$REPO_ROOT/scripts/detect-siblings.sh"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

if [ ! -f "$DETECT" ]; then
	printf 'FAIL: %s is missing\n' "$DETECT"
	exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

fake_nargo() {
	mkdir -p "$(dirname "$1")"
	printf '#!/bin/sh\necho "%s"\n' "$2" >"$1"
	chmod +x "$1"
}

# <ws>/codetracer, <ws>/noir/target/release/nargo (the sibling build), and a
# separate directory standing in for the dev shell's nargo on PATH.
ws="$tmp_root/ws"
mkdir -p "$ws/codetracer"
fake_nargo "$ws/noir/target/release/nargo" "sibling"
shell_bin="$tmp_root/devshell/bin"
fake_nargo "$shell_bin/nargo" "devshell"

# Source the detector against the fixture in a clean subshell and report which
# nargo PATH resolves and what NARGO_PATH is.
resolved=""
nargo_path=""
run_detect() {
	local raw
	# shellcheck disable=SC2016  # $1..$3 belong to the INNER shell.
	raw="$(env -u NARGO_PATH -u CODETRACER_NARGO_FROM_SIBLING -u DETECT_SIBLINGS_QUIET \
		"$@" PATH="$shell_bin:$PATH" \
		bash -c '
			source "$1" "$2/codetracer" >/dev/null 2>&1
			echo "RESOLVED=$(nargo)"
			echo "NARGO_PATH=${NARGO_PATH:-}"
		' _ "$DETECT" "$ws")"
	resolved="$(sed -n 's/^RESOLVED=//p' <<<"$raw")"
	nargo_path="$(sed -n 's/^NARGO_PATH=//p' <<<"$raw")"
}

printf 'the nargo detect-siblings.sh leaves in charge\n'

run_detect
if [ "$resolved" = "devshell" ]; then
	ok "a built noir sibling does not shadow the dev shell's nargo"
else
	fail "a built noir sibling does not shadow the dev shell's nargo" \
		"PATH resolved nargo to the '$resolved' one."
fi
if [ "$nargo_path" = "$shell_bin/nargo" ]; then
	ok "NARGO_PATH names the dev shell's nargo"
else
	fail "NARGO_PATH names the dev shell's nargo" "NARGO_PATH='$nargo_path'"
fi

run_detect CODETRACER_NARGO_FROM_SIBLING=1
if [ "$resolved" = "sibling" ]; then
	ok "CODETRACER_NARGO_FROM_SIBLING=1 selects the sibling build"
else
	fail "CODETRACER_NARGO_FROM_SIBLING=1 selects the sibling build" \
		"PATH resolved nargo to the '$resolved' one."
fi
if [ "$nargo_path" = "$ws/noir/target/release/nargo" ]; then
	ok "CODETRACER_NARGO_FROM_SIBLING=1 points NARGO_PATH at the sibling build"
else
	fail "CODETRACER_NARGO_FROM_SIBLING=1 points NARGO_PATH at the sibling build" \
		"NARGO_PATH='$nargo_path'"
fi

run_detect NARGO_PATH="$shell_bin/nargo"
if [ "$nargo_path" = "$shell_bin/nargo" ] && [ "$resolved" = "devshell" ]; then
	ok "an explicitly configured NARGO_PATH is kept"
else
	fail "an explicitly configured NARGO_PATH is kept" \
		"NARGO_PATH='$nargo_path', PATH resolved '$resolved'"
fi

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
