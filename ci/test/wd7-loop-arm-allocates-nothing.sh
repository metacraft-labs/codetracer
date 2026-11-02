#!/usr/bin/env bash
# WD7 — THE NOIR STUDIO ARM CANNOT ALLOCATE, BECAUSE THE CODE THAT ALLOCATES IS
# NOT IN ITS BUNDLE.
#
# `Hosted-Session-Allocation.md` §5's second verification is
# `test_noir_studio_allocates_nothing`, and its own note says what the
# assertion has to be: *"the substrate seeing no request rather than ... reading
# CodeTracer's code"*, with a positive control, because *"an absence is
# satisfied by a substrate that is not running, not reachable, or simply not
# being observed."*
#
# ## WHAT THIS GATE IS, AND WHAT IT IS NOT
#
# It is NOT that test. The observational half needs a running api-server and
# `sessionctl list`, and this gate has neither. It is the CONSTRUCTION half:
# the reason the substrate will see no request, asserted in the built bundle
# rather than in the source — because a module that dropped out of an import
# graph is exactly the failure a source grep cannot see, which is the argument
# `ci/test/noir-studio-signed-out.sh` already makes for measuring in the
# bundle.
#
# Read it as narrowing where the observational test may fail. If this gate is
# green, a substrate that saw a request from Noir Studio did not get it from
# this bundle.
#
# ## THE POSITIVE CONTROL IS THE SECOND ARM, AND IT IS WHY THIS FILE EXISTS
#
# "This bundle contains no allocation" is also true of a bundle that compiled
# nothing, of a scanner that cannot match, and of a pattern with a typo in it.
# So the same scanner, the same build command and the same bundle path are used
# twice:
#
#   arm A   the tree as committed            -> MUST be 0 egress sites
#   arm B   with the allocation client       -> MUST be > 0
#           imported and used by web_main
#
# A run in which both arms report 0 is a broken observer reporting a pass, and
# this gate fails it by name rather than printing OK twice.
#
# ## MUTATION DISCIPLINE
#
# Arm B edits a tracked file. The pre-plant bytes are copied aside, their
# SHA-256 is recorded against the file's FULL PATH, the restore is one `cp`
# into a temporary beside the target followed by one atomic `mv -f`, and the
# nonce's absence afterwards is asserted TOGETHER WITH a positive control in
# the same command — the same grep, over the saved plant copy, must still find
# it. An absence check whose grep is broken reports a clean tree.
#
# The nonce is regenerated per run and appears nowhere in the tree, so the
# absence assertion cannot be satisfied by a string that occurs honestly.
#
# ## Usage
#
#   direnv exec . bash ci/test/wd7-loop-arm-allocates-nothing.sh
#
# Exit 0 green, 1 a finding, 2 could not run (no toolchain, or the plant could
# not be applied) — the same three-way convention
# `ci/test/noir-studio-signed-out.sh` uses, and for the same reason: an absent
# toolchain is a gate that did not run, and conflating that with a red gate is
# how a suite comes to "pass" on a machine that compiled nothing.

set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

# THE SAME PATTERN `noir-studio-signed-out.sh` SCANS WITH, copied with its
# constraint: POSIX ERE only, because `\b`, `\d`, `\w` and `\s` are GNU/PCRE
# extensions and a pinned GNU toolchain would hide the difference.
EGRESS_PATTERN='(await )?fetch\(|new XMLHttpRequest|new WebSocket\(|sendBeacon\(|new EventSource\('

egress_count() {
	# `grep -c` prints 0 AND exits 1 when there are no matches, so counting
	# with `wc -l` over the line list is the spelling that yields one value.
	grep -naoE "${EGRESS_PATTERN}" "$1" 2>/dev/null | cut -d: -f1 | grep -c . || true
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/wd7-loop-arm.XXXXXX")" || exit 2
# Distinct basenames on purpose: two reference copies sharing one is how a
# restore writes back the wrong bytes.
PRE_PLANT="${scratch}/web_main.nim.wd7-pre-plant"
PLANTED_COPY="${scratch}/web_main.nim.wd7-planted-arm-b"
MANIFEST="${scratch}/wd7-plant-manifest.sha256"
TARGET="src/frontend/web_main.nim"
CLIENT="src/frontend/ui/session_allocation_client.nim"

NONCE="wd7q$(date +%s)$$"

restore_target() {
	# cp into a temporary BESIDE the target, then ONE atomic mv. A kill
	# between the two leaves either the plant or the original, never a
	# half-written file — and `mv` within one directory is a rename.
	local tmp="${TARGET}.wd7-restore.tmp"
	cp -- "${PRE_PLANT}" "${tmp}" && mv -f -- "${tmp}" "${TARGET}"
}

cleanup() {
	if [ -f "${PRE_PLANT}" ] && [ -f "${TARGET}" ]; then
		if ! cmp -s "${PRE_PLANT}" "${TARGET}"; then
			restore_target
		fi
	fi
	rm -rf -- "${scratch}"
}
trap cleanup EXIT HUP INT TERM

echo "=== WD7: the Noir Studio arm carries no allocation (Hosted-Session-Allocation §5) ==="
echo

# ---------------------------------------------------------------------------
echo "Step 0: the toolchain, and the subject this gate needs to exist"
# ---------------------------------------------------------------------------
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}
[ -f "${TARGET}" ] || {
	echo "${TARGET} does not exist; this gate has no subject" >&2
	exit 2
}
[ -f "${CLIENT}" ] || {
	echo "${CLIENT} does not exist, so arm B cannot plant anything and arm" >&2
	echo "  A's zero would be vacuous — WD7's allocation client is gone." >&2
	exit 2
}
note "nim: $(command -v nim)"
note "nonce: ${NONCE}"
echo

cp -- "${TARGET}" "${PRE_PLANT}" || exit 2
# THE FULL PATH, not a basename. A manifest keyed on `web_main.nim` cannot say
# which of the tree's same-named files it describes.
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum -- "${repo_root}/${TARGET}" >"${MANIFEST}" || exit 2
else
	shasum -a 256 -- "${repo_root}/${TARGET}" >"${MANIFEST}" || exit 2
fi
pre_hash="$(cut -d' ' -f1 <"${MANIFEST}")"
note "pre-plant sha256: ${pre_hash}  ${repo_root}/${TARGET}"
echo

build_loop_arm() {
	local out="$1" cache="$2" log
	log="$(nim js --hints:off --warnings:off -d:nodejs -d:ctWeb \
		--path:src/frontend/viewmodel \
		--nimcache:"${cache}" -o:"${out}" "${TARGET}" 2>&1)"
	local rc=$?
	if [ "${rc}" -ne 0 ] || [ ! -s "${out}" ]; then
		printf '%s\n' "${log}" | tail -20 >&2
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
echo "Step 1: arm A — the tree as committed"
echo "    The loop arm is \`${TARGET}\` with -d:ctWeb, which is the same"
echo "    bundle ci/test/noir-studio-signed-out.sh requires to have zero"
echo "    egress sites. This gate asks a narrower question of it: whether"
echo "    WD7's allocation client is in its import graph."
# ---------------------------------------------------------------------------
arm_a="${scratch}/arm-a-web.js"
if ! build_loop_arm "${arm_a}" "${scratch}/cache-a"; then
	echo "arm A did not build; nothing was planted" >&2
	exit 2
fi
a_sites="$(egress_count "${arm_a}")"
a_marker="$(grep -ac 'CODETRACER_SESSION_ALLOCATION' "${arm_a}" 2>/dev/null || true)"
note "arm A: $(wc -c <"${arm_a}" | tr -d ' ') bytes"
if [ "${a_sites}" -eq 0 ]; then
	ok "arm A has 0 egress sites"
else
	bad "arm A has ${a_sites} egress site(s) — the development loop reaches the network"
fi
if [ "${a_marker}" -eq 0 ]; then
	ok "arm A carries no CODETRACER_SESSION_ALLOCATION marker, so no allocation call is compiled into it"
else
	bad "arm A carries ${a_marker} allocation marker(s) — the Noir Studio bundle can ask the substrate for a session"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: arm B — the SAME scanner, with the allocation client imported"
echo "    THE POSITIVE CONTROL. Arm A's zero is evidence only if a non-zero"
echo "    was reachable by the same function over the same kind of bundle."
echo "    the exportc pragma keeps the planted proc alive through dead-code"
echo "    elimination: without it nim js would drop the import's only use and"
echo "    the control would report zero for the wrong reason."
# ---------------------------------------------------------------------------
cat >>"${TARGET}" <<PLANT

# ${NONCE}: planted by ci/test/wd7-loop-arm-allocates-nothing.sh as the
# positive control for arm A. Restored by that script; if you are reading this
# in a committed tree, a run was killed between the write and the restore.
import ui/session_allocation_client

proc ${NONCE}PlantedAllocation*(project: cstring) {.exportc.} =
  startSessionForProject(\$project, proc(start: SessionStart) = discard)
PLANT
plant_rc=$?
cp -- "${TARGET}" "${PLANTED_COPY}" 2>/dev/null
if [ "${plant_rc}" -ne 0 ] || ! grep -aq "${NONCE}" "${TARGET}"; then
	echo "the plant did not apply; restoring and refusing to report a result" >&2
	restore_target
	exit 2
fi

arm_b="${scratch}/arm-b-web.js"
b_built=0
if build_loop_arm "${arm_b}" "${scratch}/cache-b"; then
	b_built=1
fi
# RESTORE BEFORE GRADING, so a failing assertion below cannot leave the plant
# in the tree.
restore_target
restore_rc=$?

if [ "${b_built}" -eq 0 ]; then
	bad "arm B did not build, so arm A's zero has no positive control and this run proves nothing"
else
	b_sites="$(egress_count "${arm_b}")"
	b_marker="$(grep -ac 'CODETRACER_SESSION_ALLOCATION' "${arm_b}" 2>/dev/null || true)"
	note "arm B: $(wc -c <"${arm_b}" | tr -d ' ') bytes"
	if [ "${b_sites}" -gt 0 ]; then
		ok "arm B has ${b_sites} egress site(s) — the scanner CAN see an allocation in this bundle"
	else
		bad "arm B has 0 egress sites — the scanner cannot see an allocation it was handed, so arm A's zero means nothing"
	fi
	if [ "${b_marker}" -gt 0 ]; then
		ok "arm B carries ${b_marker} CODETRACER_SESSION_ALLOCATION marker(s), so the marker check CAN fire"
	else
		bad "arm B carries no allocation marker — the marker check in arm A cannot fire and is vacuous"
	fi
	# THE PAIRING IS THE PROPERTY, said as one assertion so a reader cannot
	# take arm A's zero on its own.
	if [ "${a_sites}" -eq 0 ] && [ "${b_sites}" -gt 0 ]; then
		ok "arm A 0 and arm B ${b_sites}: the absence is a measurement, not an absence of measurement"
	else
		bad "arm A ${a_sites} / arm B ${b_sites} — the two arms do not separate, so this gate is not observing what it claims"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: the tree is back at its pre-plant bytes"
echo "    MARKER-ABSENCE WITH A POSITIVE CONTROL IN THE SAME COMMAND. A grep"
echo "    that matches nothing reports a clean tree, so the same grep must"
echo "    still find the nonce in the saved plant copy."
# ---------------------------------------------------------------------------
if [ "${restore_rc}" -ne 0 ]; then
	bad "the restore reported a failure (rc ${restore_rc})"
fi
in_tree="$(grep -ac "${NONCE}" "${TARGET}" 2>/dev/null || true)"
in_copy="$(grep -ac "${NONCE}" "${PLANTED_COPY}" 2>/dev/null || true)"
if [ "${in_tree}" -eq 0 ] && [ "${in_copy}" -gt 0 ]; then
	ok "the nonce is absent from ${TARGET} and the same grep finds it ${in_copy} time(s) in the saved plant copy"
elif [ "${in_copy}" -eq 0 ]; then
	bad "the nonce is in NEITHER the tree nor the saved plant copy — the grep cannot match, so 'absent from the tree' is not a measurement"
else
	bad "${TARGET} still carries the nonce ${in_tree} time(s) — the plant was NOT restored"
fi

if command -v sha256sum >/dev/null 2>&1; then
	post_hash="$(sha256sum -- "${repo_root}/${TARGET}" | cut -d' ' -f1)"
else
	post_hash="$(shasum -a 256 -- "${repo_root}/${TARGET}" | cut -d' ' -f1)"
fi
if [ "${post_hash}" = "${pre_hash}" ]; then
	ok "${TARGET} is byte-identical to its pre-plant copy (${post_hash})"
else
	bad "${TARGET} does not match its pre-plant hash: recorded ${pre_hash}, on disk ${post_hash}"
	note "the pre-plant bytes were copied to ${PRE_PLANT} — but that directory is removed on exit, so recover from git"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "  The Noir Studio arm's bundle contains no allocation call, measured in"
echo "  the built bundle against a planted arm that the same scanner sees."
echo "  It is NOT a claim that the substrate saw no request — that is"
echo "  Hosted-Session-Allocation.md §5's second verification and needs a"
echo "  running substrate to observe."
echo "RESULT: OK"
