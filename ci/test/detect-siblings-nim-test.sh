#!/usr/bin/env bash
#
# detect-siblings-nim-test.sh -- contract suite for the `nim` that
# scripts/detect-siblings.sh leaves in charge of the dev shell.
#
# WHAT IS BEING PINNED
# --------------------
# The dev shell provides `nim` from the pinned Nim fork (reprobuild's
# `packages.nim-fork`). A workspace may ALSO hold a `codetracer-nim` sibling
# with a `bin/nim` in it, built from whatever that checkout was on whenever
# someone last built it. The detector used to put that build first on PATH, so
# every Nim program the shell compiled -- the db-backend tests' Nim fixtures
# among them -- was compiled by it: a build that predated the fork's
# source-map fix made the Nim MCR flow test stop nowhere while the pinned
# compiler carried the fix.
#
# So the invariant is: THE DEV SHELL'S NIM WINS on PATH, and the sibling build
# is reachable only by name, through CODETRACER_NIM_BIN, for the consumers that
# want the sibling's compiler specifically. Both halves are asserted, with and
# without a sibling build, because a detector that only ever gives one answer
# is the defect.
#
# Fixtures are built under mktemp with the real directory layout and sourced in
# a subshell. Pure bash; no nix, no Nim, nothing compiled. A stub `nix` that
# fails keeps the detector's libpcre lookup offline.
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

fake_tool() {
	mkdir -p "$(dirname "$1")"
	printf '#!/bin/sh\necho "%s"\n' "$2" >"$1"
	chmod +x "$1"
}

# <ws>/codetracer, an empty <ws>/codetracer-native-backend (the detector
# recognises a workspace root by a known sibling), and a directory standing in
# for the dev shell's bin on PATH.
ws="$tmp_root/ws"
mkdir -p "$ws/codetracer" "$ws/codetracer-native-backend"
shell_bin="$tmp_root/devshell/bin"
fake_tool "$shell_bin/nim" "devshell"
printf '#!/bin/sh\nexit 1\n' >"$shell_bin/nix"
chmod +x "$shell_bin/nix"

resolved=""
nim_bin=""
run_detect() {
	local raw
	# shellcheck disable=SC2016  # $1..$2 belong to the INNER shell.
	raw="$(env -u CODETRACER_NIM_BIN -u DETECT_SIBLINGS_QUIET \
		PATH="$shell_bin:$PATH" \
		bash -c '
			source "$1" "$2/codetracer" >/dev/null 2>&1
			echo "RESOLVED=$(nim)"
			echo "NIM_BIN=${CODETRACER_NIM_BIN:-}"
		' _ "$DETECT" "$ws")"
	resolved="$(sed -n 's/^RESOLVED=//p' <<<"$raw")"
	nim_bin="$(sed -n 's/^NIM_BIN=//p' <<<"$raw")"
}

printf 'the nim detect-siblings.sh leaves in charge\n'

run_detect
if [ "$resolved" = "devshell" ] && [ -z "$nim_bin" ]; then
	ok "without a codetracer-nim build, nim is the dev shell's and CODETRACER_NIM_BIN is unset"
else
	fail "without a codetracer-nim build, nim is the dev shell's and CODETRACER_NIM_BIN is unset" \
		"PATH resolved nim to the '$resolved' one; CODETRACER_NIM_BIN='$nim_bin'"
fi

fake_tool "$ws/codetracer-nim/bin/nim" "sibling"
run_detect
if [ "$resolved" = "devshell" ]; then
	ok "a built codetracer-nim sibling does not shadow the dev shell's nim"
else
	fail "a built codetracer-nim sibling does not shadow the dev shell's nim" \
		"PATH resolved nim to the '$resolved' one."
fi
if [ "$nim_bin" = "$ws/codetracer-nim/bin/nim" ]; then
	ok "CODETRACER_NIM_BIN names the sibling build for the consumers that ask for it"
else
	fail "CODETRACER_NIM_BIN names the sibling build for the consumers that ask for it" \
		"CODETRACER_NIM_BIN='$nim_bin'"
fi

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
