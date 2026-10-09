#!/usr/bin/env bash
# shellcheck shell=bash
#
# sha256.sh — one sha256 that exists on every machine this repository runs on,
# resolved ONCE and refused LOUDLY when it is absent.
#
# WHY THIS EXISTS
# ---------------
# Ten gates spelled their digest as a bare `shasum -a 256`, inline, inside a
# `$(...)` in the middle of a `note` line:
#
#     note "ui.js: $(wc -c <f) bytes, sha256 $(shasum -a 256 f | cut -c1-16)"
#
# `shasum` is PERL's. macOS ships it and GNU/Linux does not; the NixOS runner
# images this repository's CI uses ship `sha256sum` and no `shasum` at all. So
# on every CI run, that line produced
#
#     ci/test/noir-demo-in-browser.sh: line 100: shasum: command not found
#     ui.js:   20160375 bytes, sha256
#
# (measured in run 37894032724, 2026-10-09) — a `$(...)` whose tool is missing
# does not fail the gate, it MANUFACTURES AN EMPTY STRING, and the surrounding
# `note` prints it as a successful observation. `set -e` cannot see it either,
# because the failure is inside a command substitution in an argument.
#
# That note is not decoration. `/ui.js` sits at a stable URL under a long
# max-age and the bundle tree survives branch switches, so the digest is the
# ONLY thing in the output that says WHICH renderer the assertions below
# measured. A gate that cannot name its subject and reports a pass anyway is
# the exact defect shape this repository has spent a campaign removing: it does
# not report "I could not measure", it reports nothing and looks fine.
#
# `verify-deployed-bytes.sh` had already written the rule down —
#
#     A tool that is missing must say so once, up front, rather than be
#     re-discovered as a fake result per call site.
#
# — and three copies of its resolution block had been pasted around. This is
# that block, once.
#
# USAGE
# -----
#   # shellcheck source=ci/lib/sha256.sh
#   source "${repo_root}/ci/lib/sha256.sh"
#
#   ct_sha256_require || exit 2          # in a precondition block
#   d="$(ct_sha256_short f)" || die ...  # or route the refusal yourself
#
# NOTHING HERE EXITS. Every caller already owns a refusal idiom that prints its
# own verdict ("0 assertion(s) ran; the suite never started.", `exit 2`), and a
# library that exits from a sourced top level would take that sentence away —
# the same reasoning `ci/lib/wasm-engine-freshness.sh` records for
# `wasm_engine_assert_fresh`.
#
# `sha256sum` IS PREFERRED OVER `shasum`, deliberately, even though the earlier
# pasted blocks tried `shasum` first. Both answer identically; `sha256sum` is
# the one present in CI, so preferring it keeps the common path off the
# fallback and makes a CI failure here mean "the dev shell is wrong", not
# "perl is missing".

CT_SHA256_CMD=""
CT_SHA256_ARGS=()

# Resolve the digest tool. 0 when one is available, 2 when none is, with the
# reason on stderr. Idempotent and cheap to call again.
ct_sha256_require() {
	[ -n "${CT_SHA256_CMD}" ] && return 0
	if command -v sha256sum >/dev/null 2>&1; then
		CT_SHA256_CMD="$(command -v sha256sum)"
		CT_SHA256_ARGS=()
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		CT_SHA256_CMD="$(command -v shasum)"
		CT_SHA256_ARGS=(-a 256)
		return 0
	fi
	echo "ci/lib/sha256.sh: neither sha256sum nor shasum is on PATH, so nothing" >&2
	echo "  here can name the bytes it is measuring. Run inside the dev shell" >&2
	echo "  (direnv exec <repo> ...), which carries coreutils' sha256sum." >&2
	return 2
}

# The full sha256 of a file. Prints NOTHING and returns non-zero when the tool
# is missing or the file is not there — never a partial or empty digest that a
# caller could print as if it had measured something.
ct_sha256_file() {
	ct_sha256_require || return 2
	if [ ! -f "$1" ]; then
		echo "ci/lib/sha256.sh: no such file to digest: $1" >&2
		return 3
	fi
	local line
	line="$("${CT_SHA256_CMD}" "${CT_SHA256_ARGS[@]}" "$1")" || return 4
	line="${line%% *}"
	# 64 hex characters or it is not a sha256, whatever produced it.
	case "${#line}" in
	64) printf '%s' "${line}" ;;
	*)
		echo "ci/lib/sha256.sh: ${CT_SHA256_CMD} produced ${#line} characters, not 64, for $1" >&2
		return 5
		;;
	esac
}

# The first N characters of it (default 16), for a one-line provenance note.
ct_sha256_short() {
	local full n="${2:-16}"
	full="$(ct_sha256_file "$1")" || return $?
	printf '%s' "${full:0:${n}}"
}
