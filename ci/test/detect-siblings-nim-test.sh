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

# The libpcre the sibling's bin/nim is given. bin/nim dlopen()s libpcre, so
# the detector puts its directory on LD_LIBRARY_PATH. It used to append `/lib`
# to whatever `nix build nixpkgs#pcre.out` printed; once the floating registry
# dropped `pcre` that printed nothing, `/lib` went on the path, and the host's
# glibc broke every Nix binary in the shell. Without a resolvable libpcre the
# path must be left alone and the gap reported.
printf '\nthe libpcre the sibling build is given\n'

# A `nix` that records its arguments and fails, as the registry lookup did.
nix_log="$tmp_root/nix-args.log"
pcre_bin="$tmp_root/pcre-shell/bin"
mkdir -p "$pcre_bin"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 1\n' "$nix_log" >"$pcre_bin/nix"
chmod +x "$pcre_bin/nix"

ld_path=""
recorder_ld_path=""
detect_err=""
run_detect_pcre() {
	# $1: CT_PCRE_LIB_DIR for the run ("" leaves it unset).
	local raw
	: >"$nix_log"
	# shellcheck disable=SC2016  # $1..$3 belong to the INNER shell.
	raw="$(env -u CODETRACER_NIM_BIN -u DETECT_SIBLINGS_QUIET -u CT_PCRE_LIB_DIR \
		-u CODETRACER_RECORDER_LD_LIBRARY_PATH \
		PATH="$pcre_bin:$shell_bin:$PATH" LD_LIBRARY_PATH=/preset \
		bash -c '
			[ -n "$3" ] && export CT_PCRE_LIB_DIR="$3"
			source "$1" "$2/codetracer" >/dev/null 2>"$4"
			echo "LD=${LD_LIBRARY_PATH:-}"
			echo "REC=${CODETRACER_RECORDER_LD_LIBRARY_PATH:-}"
		' _ "$DETECT" "$ws" "$1" "$tmp_root/detect.err")"
	ld_path="$(sed -n 's/^LD=//p' <<<"$raw")"
	recorder_ld_path="$(sed -n 's/^REC=//p' <<<"$raw")"
	detect_err="$(cat "$tmp_root/detect.err")"
}

run_detect_pcre ""
if [ "$ld_path" = "/preset" ] && [ -z "$recorder_ld_path" ]; then
	ok "an unresolvable libpcre leaves LD_LIBRARY_PATH alone (no host /lib)"
else
	fail "an unresolvable libpcre leaves LD_LIBRARY_PATH alone (no host /lib)" \
		"LD_LIBRARY_PATH='$ld_path'; CODETRACER_RECORDER_LD_LIBRARY_PATH='$recorder_ld_path'"
fi
if grep -q 'WARNING: .*libpcre' <<<"$detect_err"; then
	ok "an unresolvable libpcre is reported"
else
	fail "an unresolvable libpcre is reported" "stderr: $detect_err"
fi
if grep -q -- '--inputs-from .*nixpkgs#pcre.out' "$nix_log"; then
	ok "the fallback lookup resolves nixpkgs from codetracer's flake.lock, not the registry"
else
	fail "the fallback lookup resolves nixpkgs from codetracer's flake.lock, not the registry" \
		"nix was called with: $(tr '\n' ';' <"$nix_log")"
fi

shell_pcre="$tmp_root/pcre-from-shell/lib"
mkdir -p "$shell_pcre"
run_detect_pcre "$shell_pcre"
if [ "$ld_path" = "$shell_pcre:/preset" ] && [ "$recorder_ld_path" = "$shell_pcre" ]; then
	ok "the dev shell's CT_PCRE_LIB_DIR is put on both library paths"
else
	fail "the dev shell's CT_PCRE_LIB_DIR is put on both library paths" \
		"LD_LIBRARY_PATH='$ld_path'; CODETRACER_RECORDER_LD_LIBRARY_PATH='$recorder_ld_path'"
fi
if [ ! -s "$nix_log" ] && ! grep -q 'libpcre' <<<"$detect_err"; then
	ok "with CT_PCRE_LIB_DIR set, nix is not consulted and nothing is reported"
else
	fail "with CT_PCRE_LIB_DIR set, nix is not consulted and nothing is reported" \
		"nix was called with: $(tr '\n' ';' <"$nix_log")" "stderr: $detect_err"
fi

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
