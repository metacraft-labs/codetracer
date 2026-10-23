#!/usr/bin/env bash
# plat18-harness-grades-the-tree-it-mutates.sh — the PLAT-18 marshalling
# harness kills a meter arm even when `ISONIM_SRC` points at another copy of
# isonim.
#
# `run-plat18-marshalling-mutations.py` mutates
# `../isonim/src/isonim/core/boundary_meter.nim` — the sibling checkout — for
# arms M1-M4, and grades them by compiling the marshalling probe. The probe
# reaches isonim through `config.nims`, which puts the sibling's `src` on the
# Nim path and then `$ISONIM_SRC` AFTER it; Nim searches later `--path`
# entries first, so a set `ISONIM_SRC` wins, and a `--path:` on the command
# line cannot outrank it (config.nims is read after the command line).
# `ISONIM_SRC` is a supported override — a pin worktree, a Nix store source —
# so an ambient value is ordinary. With one set, the harness edited one tree
# and compiled another: M1-M4 came back `SURVIVED  the instrument reported
# nothing`, which reads as a hole in the instrument and was a hole in the
# harness (codetracer-pm issues/2026-10-21-plat18-marshalling-arms-m1-m4-
# survive-on-agents.md; Verification-Harness-Traps.md §1b — show the subject
# was THERE before reading anything off a quiet run).
#
# This test reproduces that redirect with an UNMUTATED copy of the sibling's
# `src` in a temp dir, exports `ISONIM_SRC` at it, runs the harness on arm M1
# alone, and asserts:
#   * M1's arm row is verdict `killed` — not SURVIVED, not MIS-ATTRIBUTED,
#     not a HARNESS-FAILURE; i.e. the probe was built from the tree the arm
#     mutated, and said so for the arm's own recorded reason;
#   * the harness said, in one line, that it overrode the ambient
#     `ISONIM_SRC` — an override that happens silently is a second thing the
#     next reader has to rediscover;
#   * the harness exited 0 (every control green, 0 problems);
#   * codetracer and the sibling isonim are byte-for-byte what they were.
#
# It compiles the probe three times (pre-flight, arm, control): minutes, not
# seconds. Run it inside the dev environment (`repro exec . -- bash <this>`),
# which supplies `nim` and `python3`.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1

harness="src/frontend/viewmodel/tests/unit/run-plat18-marshalling-mutations.py"
isonim="${root}/../isonim"

python3_bin="$(command -v python3 || true)"
[ -n "${python3_bin}" ] || {
	echo "FAIL: python3 is not on PATH (run under 'repro exec . --')" >&2
	exit 1
}
command -v nim >/dev/null || {
	echo "FAIL: nim is not on PATH (run under 'repro exec . --')" >&2
	exit 1
}
[ -f "${harness}" ] || {
	echo "FAIL: ${harness} is missing" >&2
	exit 1
}
[ -f "${isonim}/src/isonim/core/boundary_meter.nim" ] || {
	echo "FAIL: the sibling isonim checkout is missing at ${isonim}" >&2
	exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/plat18-grades-mutated-tree.XXXXXX")" || exit 1
trap 'rm -rf "${tmp}"' EXIT

tree_state() {
	# What a mutating run would leave behind, in BOTH repos the harness edits:
	# tracked content and untracked names.
	local repo
	for repo in "${root}" "${isonim}"; do
		git -C "${repo}" diff --no-ext-diff 2>/dev/null
		git -C "${repo}" status --porcelain=v1 --untracked-files=all 2>/dev/null
	done | sha256sum
}

# THE REDIRECT: a second, unmutated isonim tree. `cp -r` of `src` is all
# config.nims reads through `ISONIM_SRC`.
if ! { mkdir -p "${tmp}/isonim-copy" && cp -r "${isonim}/src" "${tmp}/isonim-copy/"; }; then
	echo "FAIL: could not copy ${isonim}/src into ${tmp}" >&2
	exit 1
fi

before="$(tree_state)"
failed=0

out="$(env ISONIM_SRC="${tmp}/isonim-copy/src" \
	CT_NIM_CACHE_ROOT="${tmp}/nimcache" \
	CT_P18_HARNESS_OUT="${tmp}/harness" \
	"${python3_bin}" "${harness}" --only=M1 2>&1)"
rc=$?
printf '%s\n' "${out}" >"${tmp}/transcript.txt"

# The arm row is `M1    <grader label>   <verdict padded to 22>  <note>`.
# `killed` followed by two or more spaces is the plain kill; `killed
# (UNATTRIBUTED)` has one space and is a different verdict.
row="$(printf '%s\n' "${out}" | grep -E '^M1 +plat18_marshalling_probe@native ' | head -1)"
if [ -z "${row}" ]; then
	echo "FAIL: the transcript carries no M1 arm row (harness rc ${rc})"
	printf '%s\n' "${out}" | tail -15 | sed 's/^/      /'
	failed=$((failed + 1))
elif ! printf '%s\n' "${row}" | grep -qE '^M1 +plat18_marshalling_probe@native +killed {2,}'; then
	echo "FAIL: M1 was not killed with ISONIM_SRC pointed at another isonim copy:"
	echo "      ${row}"
	failed=$((failed + 1))
else
	echo "ok: M1 killed with ISONIM_SRC pointed at another isonim copy"
fi

if printf '%s\n' "${out}" | grep -q '^note: ISONIM_SRC overridden'; then
	echo "ok: the harness said it overrode the ambient ISONIM_SRC"
else
	echo "FAIL: the harness did not say it overrode the ambient ISONIM_SRC"
	failed=$((failed + 1))
fi

if [ "${rc}" -eq 0 ]; then
	echo "ok: the harness exited 0 ($(printf '%s\n' "${out}" | grep -E '^[0-9]+ arms, ' | tail -1))"
else
	echo "FAIL: the harness exited ${rc}"
	printf '%s\n' "${out}" | tail -8 | sed 's/^/      /'
	failed=$((failed + 1))
fi

if [ "$(tree_state)" = "${before}" ]; then
	echo "ok: codetracer and ../isonim are unchanged"
else
	echo "FAIL: the run changed codetracer or ../isonim"
	git -C "${root}" status --porcelain=v1 | head -5 | sed 's/^/      /'
	git -C "${isonim}" status --porcelain=v1 | head -5 | sed 's/^/      /'
	failed=$((failed + 1))
fi

if [ "${failed}" -ne 0 ]; then
	echo "plat18-harness-grades-the-tree-it-mutates: ${failed} check(s) failed"
	exit 1
fi
echo "plat18-harness-grades-the-tree-it-mutates: M1 graded against the tree it mutated, with ISONIM_SRC redirected"
