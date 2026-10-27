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
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

GATE="ci/test/noir-studio-signed-out.sh"
GUARD_SRC="src/frontend/ui_js.nim"
cache_root="$(ct_nim_cache_root "${repo_root}")"
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
	# 19 since WD7 and its review: the `session-allocation` surface's own
	# count, the credentialed-request check reading the dynamic-surface SUM
	# rather than collab alone, the `credentials`-key accounting identity, and
	# the same-origin check over the allocation sites.
	if [ "${control_checks}" != "19" ]; then
		miss "control: expected 19 checks, saw ${control_checks} — an assertion appeared or vanished"
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
expect_red "M8 a tenth credentialed request, with only 9 dynamic-surface sites" "${rc}" \
	"credentialed requests: 10 (budget 9), dynamic-surface egress sites: 9"

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
if still_green "the scanner reports 15 egress sites on the renderer arm"; then
	note "    isolated: the TOTAL stayed 15 — only the per-surface split moved,"
	note "    which is the case a total-only budget would pass over"
else
	miss "M11 isolation: the total also moved, so this does not prove the split is checked"
fi

# --- M12: a credentialed request in the SPELLING the old pattern missed -----
# WD7's arm, and the one that proves the WIDENING is load-bearing rather than
# cosmetic. The gate used to count the literal `credentials: "include"`; the
# allocation client writes `credentials: 'same-origin'`, which is equally
# attributable and which that pattern does not match. So before the widening,
# this mutation left the gate GREEN — a credentialed request the budget could
# not see. M8 above covers the spelling the old pattern did see; this one
# covers the spelling it did not, and without both the pattern can be narrowed
# back without any arm noticing.
{
	cat "${BASE_REND}"
	printf "\nvar ctSameOriginCredentialed = { credentials: 'same-origin' };\n"
} >"${work}/m12.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m12.js")"
expect_red "M12 a credentialed request spelled 'same-origin' (the spelling the old pattern could not see)" "${rc}" \
	"credentialed requests: 10 (budget 9), dynamic-surface egress sites: 9"

# --- M13: a session-allocation site reclassified, total unchanged -----------
# M11's shape for WD7's surface: the COUNT is still 15, so step 3 stays green,
# and only the split moves. The marker is replaced inside the window the
# classifier actually reads — `n-20 .. n+8` around the FIRST allocation site,
# located by search rather than by a line number so this survives a rebuild.
# The two allocation sites are far enough apart that their windows do not
# overlap, which the arm checks rather than assumes: if the mutation moved both
# markers the per-surface counts would move by two and the arm would not
# isolate the split.
sa_line="$(grep -na 'CODETRACER_SESSION_ALLOCATION' "${BASE_REND}" | head -1 | cut -d: -f1)"
sa_count="$(grep -ca 'CODETRACER_SESSION_ALLOCATION' "${BASE_REND}" || true)"
if [ -z "${sa_line}" ] || [ "${sa_count}" != "2" ]; then
	miss "M13 setup: expected 2 allocation markers in the renderer arm, found ${sa_count:-0}"
else
	awk -v want="${sa_line}" \
		'NR==want { gsub(/CODETRACER_SESSION_ALLOCATION/, "CODETRACER_COLLAB") } { print }' \
		"${BASE_REND}" >"${work}/m13.js"
	if [ "$(grep -ca 'CODETRACER_SESSION_ALLOCATION' "${work}/m13.js" || true)" != "1" ]; then
		miss "M13 setup: the mutation did not leave exactly one allocation marker, so it does not isolate the split"
	fi
	if [ "$(grep -caE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${work}/m13.js" || true)" \
		!= "$(grep -caE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${BASE_REND}" || true)" ]; then
		miss "M13 setup: the mutation changed the egress-site count, so it does not isolate the split"
	fi
	rc="$(run_gate "${BASE_LOOP}" "${work}/m13.js")"
	expect_red "M13 one site reclassified session-allocation -> collab, total unchanged" "${rc}" \
		"surface 'collab': 8 egress site(s), budget says 7" \
		"surface 'session-allocation': 1 egress site(s), budget says 2"
	if still_green "the scanner reports 15 egress sites on the renderer arm"; then
		note "    isolated: the TOTAL stayed 15 — only the per-surface split moved"
	else
		miss "M13 isolation: the total also moved"
	fi
fi

# --- M14: an allocation site rewritten to a CROSS-ORIGIN absolute URL -------
# REVIEW'S ARM, and it survived every assertion this file had: the egress total,
# the per-surface split, the marker count and the credentialed count were all
# identical to the control, so the gate did not notice that the bundle had
# acquired a hostname and was sending the login cookie to it.
#
# `session_allocation_client.nim` rests its whole argument on same-origin --
# the front door routes `/api/v1` to `API_ORIGIN`, so the product is fixed by
# the api-server's deployment, and *"a bundle that chose an origin would be a
# bundle choosing which grant it spends against"* (D-S13). That was argued in a
# comment and measured nowhere.
#
# The rewrite ADDS NO SITE: it edits the existing `fetch(` argument, so a kill
# here cannot come from the total moving. The arm checks that rather than
# assuming it.
m14_line="$(grep -na 'CODETRACER_SESSION_ALLOCATION' "${BASE_REND}" | head -1 | cut -d: -f1)"
m14_fetch="$(awk -v n="${m14_line}" 'NR>=n && NR<=n+28 && /fetch\(/ { print NR; exit }' "${BASE_REND}")"
if [ -z "${m14_fetch}" ]; then
	miss "M14 setup: no fetch( found below the first allocation marker"
else
	awk -v want="${m14_fetch}" \
		'NR==want { sub(/fetch\(/, "fetch(\"https://wd7-m14-not-our-origin.example.net\" + ") } { print }' \
		"${BASE_REND}" >"${work}/m14.js"
	m14_before="$(grep -caoE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${BASE_REND}" || true)"
	m14_after="$(grep -caoE '(await )?fetch\(|new XMLHttpRequest|new WebSocket\(' "${work}/m14.js" || true)"
	if [ "${m14_before}" != "${m14_after}" ]; then
		miss "M14 setup: the rewrite changed the egress-site count (${m14_before} -> ${m14_after}), so a kill would not isolate the origin"
	elif [ "$(grep -ca 'wd7-m14-not-our-origin.example.net' "${work}/m14.js" || true)" = "0" ]; then
		miss "M14 setup: the hostname was not planted, so this arm tests nothing"
	elif [ "$(grep -ca 'wd7-m14-not-our-origin.example.net' "${BASE_REND}" || true)" != "0" ]; then
		miss "M14 setup: the nonce host already occurs in the control bundle"
	else
		rc="$(run_gate "${BASE_LOOP}" "${work}/m14.js")"
		expect_red "M14 an allocation site rewritten to a cross-origin absolute URL" "${rc}" \
			"a session-allocation site names an absolute URL"
		# Isolated on the SURFACE COUNT rather than on the total, deliberately.
		# The total is only 15 when the renderer arm was built against CI's
		# pinned siblings; a local override build carries extra sites of its own,
		# and an isolation needle that can never be green there tells you nothing
		# about the arm. The allocation surface's own count is 2 either way.
		if still_green "surface 'session-allocation': 2 egress site(s), as budgeted"; then
			note "    isolated: both allocation sites are still classified and still"
			note "    counted -- the host name is the only thing that changed, and"
			note "    before this assertion existed nothing here could see it"
		else
			miss "M14 isolation: the split moved too, so this does not isolate the origin"
		fi
	fi
fi

# --- M15: `credentials: 'omit'`, which must NOT be counted as credentialed ---
# THE OVER-COUNT ARM, and it is a MUST-STAY-GREEN one. `omit` is the Fetch
# standard's explicit opt-out: it attaches nothing. The first version of the
# widened pattern matched any quoted value, so this plant pushed the
# credentialed count to 10 against a budget of 9 and turned the gate red for a
# change that made the product MORE private. The accounting identity keeps the
# site visible without mis-counting it.
{
	cat "${BASE_REND}"
	printf "\nvar ctOptedOutOfCredentials = { credentials: 'omit' };\n"
} >"${work}/m15.js"
# Read on the TWO CREDENTIALS ASSERTIONS rather than on the gate's exit code.
# "The whole gate is green" is only available when the renderer arm was built
# against CI's pinned siblings; this arm's claim is narrower than that and is
# checkable wherever it runs. It is also the isolation the rest of this file
# asks for: the assertion under test, by name, with its numbers.
#
# `still_green` anchors its needle immediately after the `[OK]` column, so a
# needle taken from the MIDDLE of a message never matches and reports a miss
# while the assertion it names is green. Both needles here start at the first
# word of their message for that reason, and neither contains a backtick --
# the formatter rewrites a backtick-bearing literal into single quotes and the
# linter then objects to it, so the messages carry none.
rc="$(run_gate "${BASE_LOOP}" "${work}/m15.js")"
arms=$((arms + 1))
if still_green "all 9 credentialed requests are dynamic-surface sites" &&
	still_green "every one of the 10 credentials keys is accounted for (9 attributable + 1 omit)"; then
	pass "M15 \`credentials: 'omit'\` is SEEN and accounted for, and NOT counted as credentialed (gate rc ${rc})"
else
	miss "M15 an 'omit' site was counted as credentialed, or was not seen at all; it attaches no cookies and is not attributable"
	grep -E '\[(OK|FAILED)\].*credential' "${work}/out" | sed 's/^/    /'
fi

# --- M16: a `credentials` spelling no pattern recognises --------------------
# The other half of M15. Narrowing the pattern to the two attributable values
# would be a regression if it also stopped SEEING an unrecognised spelling, so
# the identity is asserted and this arm is what proves it bites.
{
	cat "${BASE_REND}"
	printf '\nvar ctHiddenCredentials = { credentials: ctPickedAtRuntime };\n'
} >"${work}/m16.js"
rc="$(run_gate "${BASE_LOOP}" "${work}/m16.js")"
expect_red "M16 a credentials value no pattern recognises is still SEEN" "${rc}" \
	"a spelling this gate cannot classify attaches cookies to something it is not counting"

echo
echo "${arms} arm(s), ${misses} miss(es)"
if [ "${misses}" -gt 0 ]; then
	echo "RESULT: FAILED — ${misses} arm(s) did not kill on their own assertion"
	exit 1
fi
echo "RESULT: OK — every assertion in ${GATE} has a mutation that reddens it"
