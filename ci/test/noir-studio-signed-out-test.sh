#!/usr/bin/env bash
#
# noir-studio-signed-out-test.sh — the mutation proof for
# ci/test/noir-studio-signed-out.sh.
#
# A gate that reports "0 egress sites" is worth exactly as much as the
# evidence that it would have said something else. This file supplies that
# evidence: one CONTROL arm over the unmutated product, then one MUTATION arm
# per assertion the gate makes, each verified to redden THE ASSERTION WRITTEN
# FOR IT.
#
# That last clause is the whole rule. A mutation caught by some other check is
# a MISS, not a kill: it proves the suite noticed a change, not that the
# assertion in question can fail. So every arm below names the exact message
# it expects, and additionally asserts that the arms which should stay green
# DID stay green where the two are separable.
#
# The gate compiles two ~1s-to-14MB bundles. Rebuilding them per arm would put
# this file out of reach of CI, so the arms mutate COPIES of bundles built
# once and hand them to the gate through the same `CT_RENDERER_WEB_BUNDLE` /
# `CT_WEB_ENTRY_BUNDLE` entry points the gate already documents. The gate's
# own build path is exercised by the control arm of
# `just test-noir-studio-signed-out`, which passes no such variables.
#
# The one arm that cannot work on a copy is the source-guard arm: the gate
# reads `src/frontend/ui_js.nim` relative to the repo root, deliberately, so
# that no test hook exists to point it somewhere else. That arm edits the file
# and restores it from git, and traps so an interrupted run does not leave the
# tree dirty.
#
# Usage:  bash ci/test/noir-studio-signed-out-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

GATE="ci/test/noir-studio-signed-out.sh"
GUARD_SRC="src/frontend/ui_js.nim"
cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
work="$(mktemp -d)"

arms=0
misses=0

cleanup() {
	# Restore the source file whatever happened, FROM THE COPY THIS SCRIPT
	# TOOK — not with `git checkout --`. The checkout works, but this repo
	# installs a post-checkout hook that "repairs" the worktree's hooks as a
	# side effect, so a test run would mutate git state it has no business
	# touching. Restoring the bytes we saved does exactly one thing.
	if [ -f "${work}/ui_js.nim.orig" ]; then
		cp "${work}/ui_js.nim.orig" "${GUARD_SRC}" 2>/dev/null || true
	fi
	rm -rf "${work}"
}
trap cleanup EXIT INT TERM

note() { printf '  %s\n' "$*"; }
pass() {
	arms=$((arms + 1))
	printf '  [KILL]   %s\n' "$*"
}
miss() {
	arms=$((arms + 1))
	misses=$((misses + 1))
	printf '  [MISS]   %s\n' "$*"
}

echo "=== mutation proof for ${GATE} ==="
echo

# ---------------------------------------------------------------------------
echo "Step 0: build the two arms once; every mutation is a copy of these"
# ---------------------------------------------------------------------------
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH; run inside the dev shell" >&2
	exit 2
}

BASE_LOOP="${CT_WEB_ENTRY_BUNDLE:-}"
BASE_REND="${CT_RENDERER_WEB_BUNDLE:-}"

if [ -z "${BASE_LOOP}" ]; then
	BASE_LOOP="${cache_root}/nsso-loop/web.js"
	mkdir -p "$(dirname "${BASE_LOOP}")"
	nim js -d:nodejs -d:ctWeb --hints:off --warnings:off \
		--path:src/frontend/viewmodel \
		--nimcache:"${cache_root}/nsso-loop" -o:"${BASE_LOOP}" \
		src/frontend/web_main.nim >/dev/null 2>&1 || {
		echo "the loop arm did not build" >&2
		exit 2
	}
fi
if [ -z "${BASE_REND}" ]; then
	BASE_REND="${cache_root}/nsso-renderer/ui.js"
	mkdir -p "$(dirname "${BASE_REND}")"
	nim js --hints:off --warnings:off -d:chronicles_enabled=off -d:ctRenderer -d:ctWeb \
		--nimcache:"${cache_root}/nsso-renderer" -o:"${BASE_REND}" \
		src/frontend/ui_js.nim >/dev/null 2>&1 || {
		echo "the renderer arm did not build" >&2
		exit 2
	}
fi
[ -s "${BASE_LOOP}" ] && [ -s "${BASE_REND}" ] || {
	echo "a base bundle is missing or empty" >&2
	exit 2
}
note "loop arm:     ${BASE_LOOP}"
note "renderer arm: ${BASE_REND}"
echo

# run_gate LOOP REND -> writes transcript to ${work}/out, returns gate's rc
run_gate() {
	CT_WEB_ENTRY_BUNDLE="$1" CT_RENDERER_WEB_BUNDLE="$2" \
		bash "${GATE}" >"${work}/out" 2>&1
	printf '%s' "$?"
}

# expect_red LABEL RC NEEDLE...
#   The gate must have FAILED (rc 1, never 2 — rc 2 is "did not run", which is
#   a different state and must not be allowed to count as a kill), and every
#   needle must appear in the transcript.
expect_red() {
	local label="$1" rc="$2"
	shift 2
	if [ "${rc}" = "2" ]; then
		miss "${label}: the gate exited 2 (did not run) rather than failing"
		return
	fi
	if [ "${rc}" != "1" ]; then
		miss "${label}: the gate returned ${rc}; the mutation SURVIVED"
		return
	fi
	local n
	for n in "$@"; do
		if ! grep -qF "${n}" "${work}/out"; then
			miss "${label}: gate failed, but not on its own assertion — expected \"${n}\""
			note "    a kill by a different check is a MISS. Transcript:"
			grep '\[FAILED\]' "${work}/out" | sed 's/^/    /'
			return
		fi
	done
	pass "${label}"
}

# expect_green_line NEEDLE — an assertion that must have stayed OK, proving
# the arm is isolated to the assertion it targets.
still_green() {
	grep -qF "[OK]     $1" "${work}/out"
}

# ---------------------------------------------------------------------------
echo "Control arm: the unmutated product"
# ---------------------------------------------------------------------------
rc="$(run_gate "${BASE_LOOP}" "${BASE_REND}")"
if [ "${rc}" = "0" ] && grep -q "RESULT: OK" "${work}/out"; then
	control_checks="$(grep -oE '^[0-9]+ check\(s\)' "${work}/out" | grep -oE '^[0-9]+')"
	arms=$((arms + 1))
	printf '  [OK]     control: the gate passes over the unmutated product, %s checks\n' "${control_checks}"
	# The assertion count is a fingerprint: diff it across runs and a silent
	# skip becomes visible (Verification-Harness-Traps.md 4b).
	if [ "${control_checks}" != "15" ]; then
		miss "control: expected 15 checks, saw ${control_checks} — an assertion appeared or vanished"
	fi
else
	arms=$((arms + 1))
	misses=$((misses + 1))
	printf '  [MISS]   control: the gate does NOT pass over the unmutated product (rc %s)\n' "${rc}"
	grep '\[FAILED\]' "${work}/out" | sed 's/^/    /'
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arms — one per assertion, each verified against its own"
# ---------------------------------------------------------------------------

# --- M1: a loop stage drops out of the loop arm ----------------------------
# Targets: "loop stage 'write' is ABSENT" and the 5-of-5 count.
sed 's/__viewmodelZplatformZproject95store_/__viewmodelZplatformZprojectQQstore_/g' \
	"${BASE_LOOP}" >"${work}/m1.js"
rc="$(run_gate "${work}/m1.js" "${BASE_REND}")"
expect_red "M1 loop stage 'write' removed from the loop arm" "${rc}" \
	"loop stage 'write' is ABSENT from the loop arm" \
	"the loop arm carries 4 of 5 loop stages"

# --- M2: the loop acquires a network dependency ----------------------------
# The mutation this whole gate exists to catch: one counter, one fetch.
{
	cat "${BASE_LOOP}"
	printf '\nasync function ctUsageCounter() { return await fetch("/api/v1/usage"); }\n'
} >"${work}/m2.js"
rc="$(run_gate "${work}/m2.js" "${BASE_REND}")"
expect_red "M2 one fetch added to the loop arm" "${rc}" \
	"the loop arm has 1 egress site(s), expected 0"
if still_green "all 5 loop stages are compiled into the loop arm"; then
	note "    isolated: step 2a stayed green, so the kill is step 2b's own"
else
	miss "M2 isolation: step 2a also moved; the arm is not isolated"
fi

# --- M3: the scanner goes blind --------------------------------------------
# Trap 4's own failure mode: a scan that cannot match is indistinguishable
# from a clean codebase. Step 3 exists to make that state loud.
sed -E 's/await fetch\(/await ctBlind_(/g; s/[^A-Za-z_]fetch\(/ ctBlind_(/g; s/new XMLHttpRequest/new CtBlindXHR/g; s/new WebSocket\(/new CtBlindWS(/g' \
	"${BASE_REND}" >"${work}/m3.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m3.js")"
expect_red "M3 every egress site stripped from the renderer arm (scanner blind)" "${rc}" \
	"the scanner reports 0 egress sites on the renderer arm"

# --- M4: an egress site nobody classified ----------------------------------
# Injected at the top of the file, where no surface marker is within the
# classifier's window.
{
	printf 'async function ctTelemetry() { return await fetch("/api/v1/telemetry"); }\n'
	cat "${BASE_REND}"
} >"${work}/m4.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m4.js")"
expect_red "M4 an unclassifiable egress site added to the renderer arm" "${rc}" \
	"belongs to no named surface"

# --- M5: a surface loses a site (the DOWN direction) -----------------------
# Only the FIRST visual-replay fetch, so the change is exactly one site.
awk 'BEGIN { done = 0 }
     !done && /await fetch\(url/ { sub(/await fetch\(url/, "await ctGone_(url"); done = 1 }
     { print }' "${BASE_REND}" >"${work}/m5.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m5.js")"
expect_red "M5 one visual-replay egress site removed (budget DOWN)" "${rc}" \
	"surface 'visual-replay': 3 egress site(s), budget says 4"

# --- M6: the collab path guard leaves the source ---------------------------
# The guard IS the property: without it the collab bootstrap no longer refuses
# a non-collab location. Bundles are unmutated, so ONLY the source assertion
# may redden — which is what makes this arm a test of that assertion.
cp "${GUARD_SRC}" "${work}/ui_js.nim.orig"
sed 's|/collab/join/|/collab/anywhere/|g' "${work}/ui_js.nim.orig" >"${GUARD_SRC}"
rc="$(run_gate "${BASE_LOOP}" "${BASE_REND}")"
expect_red "M6 the collab path guard removed from the source" "${rc}" \
	"the collab path guard '/collab/join/' is GONE from src/frontend/ui_js.nim"
if still_green "the guard survives into the built renderer arm"; then
	note "    isolated: the bundle-side guard assertion stayed green"
else
	miss "M6 isolation: the bundle assertion also moved"
fi
cp "${work}/ui_js.nim.orig" "${GUARD_SRC}"

# --- M7: the guard is in the source but not in what ships ------------------
sed 's|/collab/join/|/collab/anywhere/|g' "${BASE_REND}" >"${work}/m7.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m7.js")"
expect_red "M7 the guard dropped from the built bundle only" "${rc}" \
	"the guard is absent from the built renderer arm"
if still_green "the collab path guard '/collab/join/' is written in src/frontend/ui_js.nim"; then
	note "    isolated: the source-side guard assertion stayed green"
else
	miss "M7 isolation: the source assertion also moved"
fi

# --- M8: a credentialed request outside the collab surface -----------------
{
	cat "${BASE_REND}"
	printf '\nvar ctExtraCredentialed = { credentials: "include" };\n'
} >"${work}/m8.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m8.js")"
expect_red "M8 an eighth credentialed request, with only 7 collab sites" "${rc}" \
	"credentialed requests: 8 (budget 7), collab egress sites: 7"

# --- M9: the loop arm attaches credentials ---------------------------------
{
	cat "${BASE_LOOP}"
	printf '\nvar ctLoopCredentialed = { credentials: "include" };\n'
} >"${work}/m9.js"
rc="$(run_gate "${work}/m9.js" "${BASE_REND}")"
expect_red "M9 the loop arm attaches credentials to something" "${rc}" \
	"the loop arm has 1 credentialed request(s)"
if still_green "the loop arm has 0 egress sites"; then
	note "    isolated: step 2b stayed green — credentials moved, egress did not"
else
	miss "M9 isolation: step 2b also moved"
fi

# --- M10: the renderer arm stops carrying the debug stage ------------------
sed 's/__viewmodelZviewmodelsZdebug95controls95vm_/__viewmodelZviewmodelsZdebugQQcontrols95vm_/g' \
	"${BASE_REND}" >"${work}/m10.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m10.js")"
expect_red "M10 the debug stage removed from the renderer arm" "${rc}" \
	"the debug stage is ABSENT from the renderer arm"

# --- M11: a site is reclassified, total unchanged --------------------------
# The subtlest failure the budget must catch: the COUNT is still 13, so step 3
# stays green, and only the per-surface split moves. A gate that asserted the
# total alone would pass over this.
#
# THIS ARM SURVIVED ITS FIRST WRITING, and the reason is worth keeping. It
# was "replace the first `visual_replay_client_factory` in the file": there
# are 107 of them, the first is at line ~47661, and no egress site is within
# 20 lines of it. The mutation changed a string the classifier never reads,
# the gate was right to stay green, and the arm was measuring nothing.
#
# The fix is to mutate inside the window the classifier ACTUALLY reads — the
# same n-20..n+8 the gate uses — around one real visual-replay site, located
# by search rather than by a hardcoded line so this survives a rebuild.
vr_line="$(grep -naoE 'await fetch\(url' "${BASE_REND}" | head -1 | cut -d: -f1)"
if [ -z "${vr_line}" ]; then
	miss "M11 setup: no visual-replay egress site found to reclassify"
	vr_line=0
fi
awk -v lo=$((vr_line - 20)) -v hi=$((vr_line + 8)) \
	'NR>=lo && NR<=hi { gsub(/visual_replay_client_factory/, "agentic_session_launcher") } { print }' \
	"${BASE_REND}" >"${work}/m11.js"
# The mutation must not have changed the number of egress sites; if it did,
# this arm would be testing step 3 rather than step 4's split.
if [ "$(grep -caE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${work}/m11.js" || true)" \
	!= "$(grep -caE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${BASE_REND}" || true)" ]; then
	miss "M11 setup: the mutation changed the egress-site count, so it does not isolate the split"
fi
rc="$(run_gate "${BASE_LOOP}" "${work}/m11.js")"
expect_red "M11 one site reclassified visual-replay -> agentic, total unchanged" "${rc}" \
	"surface 'visual-replay': 3 egress site(s), budget says 4" \
	"surface 'agentic': 2 egress site(s), budget says 1"
if still_green "the scanner reports 13 egress sites on the renderer arm"; then
	note "    isolated: the TOTAL stayed 13 — only the per-surface split moved,"
	note "    which is the case a total-only budget would pass over"
else
	miss "M11 isolation: the total also moved, so this does not prove the split is checked"
fi

echo
echo "${arms} arm(s), ${misses} miss(es)"
if [ "${misses}" -gt 0 ]; then
	echo "RESULT: FAILED — ${misses} arm(s) did not kill on their own assertion"
	exit 1
fi
echo "RESULT: OK — every assertion in ${GATE} has a mutation that reddens it"
