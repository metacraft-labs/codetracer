#!/usr/bin/env bash
#
# identity-token-mutation.sh — the mutation proof for the identity layer:
# the verifier (ID1), the session (ID1) and the device grant (ID2).
#
# `src/frontend/viewmodel/identity/token.nim` decides whether a signed identity
# token is accepted, which band of its life it is in, and whether a subject is
# revoked. A suite that reports ten green cases over it is worth exactly what
# the evidence says it is, so this file supplies the evidence: one mutation per
# assertion family, each verified to redden THE CASE WRITTEN FOR IT.
#
# A mutation caught by some other case is a MISS, not a kill. Every arm below
# names the case it expects to go red, and several additionally name the cases
# that must stay GREEN — because an arm that reddens everything proves only
# that the suite noticed a change, not that the assertion in question can fail.
#
# ## The arm that justifies the JS lane
#
# M10 narrows `token.nim`'s bare `except:` to `except CatchableError:`. That is
# the exact defect CONTRIBUTING.md records as a class rather than an incident:
# on the C backend `parseJson` raises `JsonParsingError`, a `CatchableError`,
# so the narrow form is correct there and the suite stays GREEN; on the JS
# backend V8 throws a raw `SyntaxError` that no Nim exception type matches, so
# the guard catches nothing and the exception escapes.
#
# That arm therefore asserts a DIFFERENT outcome per backend — green on C, red
# on JS — which is the only way to demonstrate that running `vm-unit-js` is
# load-bearing rather than duplicative. If both backends went red, the arm
# would prove nothing about the lane.
#
# ## Restoring
#
# Arms mutate the module in place and restore it from a copy taken here — not
# with `git checkout --`, because this repo installs a post-checkout hook that
# "repairs" worktree hooks as a side effect, and a test run must not mutate git
# state. The trap restores on interrupt too.
#
# Usage:  bash ci/test/identity-token-mutation.sh
# Env:    CT_NIM_CACHE_ROOT  nimcache root (default /tmp/ct-nim-cache)
#         CT_IDENTITY_ARMS   'c' to skip the JS backend (local iteration only;
#                            CI must run both, and M10 needs both)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

MODULE="src/frontend/viewmodel/identity/token.nim"
SUITE="src/frontend/viewmodel/tests/unit/test_identity_token.nim"
MODULE2="src/frontend/viewmodel/identity/session.nim"
SUITE2="src/frontend/viewmodel/tests/unit/test_identity_session.nim"
MODULE3="src/frontend/viewmodel/identity/device_grant.nim"
SUITE3="src/frontend/viewmodel/tests/unit/test_device_grant.nim"

# Which pair the arms below currently operate on. `use_pair` swaps both at
# once, so an arm can never mutate one module and run the other's suite —
# which would produce a green run that proved nothing and looked like a
# surviving mutant.
active_module="${MODULE}"
active_suite="${SUITE}"
active_cases=10
use_pair() {
	case "$1" in
	token)
		active_module="${MODULE}"
		active_suite="${SUITE}"
		active_cases=10
		;;
	session)
		active_module="${MODULE2}"
		active_suite="${SUITE2}"
		active_cases=10
		;;
	devicegrant)
		active_module="${MODULE3}"
		active_suite="${SUITE3}"
		active_cases=11
		;;
	esac
}
cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
work="$(mktemp -d)"
backends="c js"
[ "${CT_IDENTITY_ARMS:-}" = "c" ] && backends="c"

arms=0
misses=0

cleanup() {
	if [ -f "${work}/token.nim.orig" ]; then
		cp "${work}/token.nim.orig" "${MODULE}" 2>/dev/null || true
	fi
	if [ -f "${work}/session.nim.orig" ]; then
		cp "${work}/session.nim.orig" "${MODULE2}" 2>/dev/null || true
	fi
	if [ -f "${work}/device_grant.nim.orig" ]; then
		cp "${work}/device_grant.nim.orig" "${MODULE3}" 2>/dev/null || true
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

command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH; run inside the dev shell" >&2
	exit 2
}
[ -f "${MODULE}" ] || {
	echo "${MODULE} does not exist; this proof has no subject" >&2
	exit 2
}
[ -f "${MODULE2}" ] || {
	echo "${MODULE2} does not exist; this proof has no subject" >&2
	exit 2
}
cp "${MODULE}" "${work}/token.nim.orig"
cp "${MODULE2}" "${work}/session.nim.orig"
cp "${MODULE3}" "${work}/device_grant.nim.orig"

# run_suite BACKEND -> transcript in ${work}/out.BACKEND ; echoes a state word
#   ran      the suite compiled and produced case results
#   nobuild  compilation failed (NOT a kill: the assertion never ran)
run_suite() {
	local backend="$1" out="${work}/out.$1"
	if [ "${backend}" = "c" ]; then
		nim c --hints:off --warnings:off \
			--nimcache:"${cache_root}/idmut-c" \
			-o:"${work}/suite-bin" -r "${active_suite}" >"${out}" 2>&1
	else
		nim js --hints:off --warnings:off \
			--nimcache:"${cache_root}/idmut-js" \
			-o:"${work}/suite.js" -r "${active_suite}" >"${out}" 2>&1
	fi
	if grep -q '\[Suite\]' "${out}"; then
		printf 'ran'
	else
		printf 'nobuild'
	fi
}

case_red() { grep -qF "[FAILED] $2" "${work}/out.$1"; }
case_green() { grep -qF "[OK] $2" "${work}/out.$1"; }

# mutate SED_SCRIPT — apply to the pristine module
pristine_of() {
	case "${active_module}" in
	"${MODULE2}") printf '%s' "${work}/session.nim.orig" ;;
	"${MODULE3}") printf '%s' "${work}/device_grant.nim.orig" ;;
	*) printf '%s' "${work}/token.nim.orig" ;;
	esac
}
mutate() {
	local orig
	orig="$(pristine_of)"
	sed "$1" "${orig}" >"${active_module}"
	if cmp -s "${active_module}" "${orig}"; then
		return 1
	fi
	return 0
}
restore() { cp "$(pristine_of)" "${active_module}"; }

# arm LABEL CASE SED — the common shape: mutate, run every backend, require
# the named case red on each.
arm() {
	local label="$1" want_case="$2" sed_script="$3"
	if ! mutate "${sed_script}"; then
		miss "${label}: the mutation changed nothing — the pattern no longer matches the module"
		restore
		return
	fi
	local b state ok=1
	for b in ${backends}; do
		state="$(run_suite "${b}")"
		if [ "${state}" = "nobuild" ]; then
			miss "${label}: the mutated module did not compile on ${b}; the assertion never ran, so this is not a kill"
			ok=0
			break
		fi
		if ! case_red "${b}" "${want_case}"; then
			miss "${label}: ${b} backend did not redden \"${want_case}\""
			note "    a kill by a different case is a MISS. Cases that went red:"
			grep '\[FAILED\]' "${work}/out.${b}" | sed 's/^/    /' | head -6
			ok=0
			break
		fi
	done
	[ "${ok}" = "1" ] && pass "${label}"
	restore
}

echo "=== mutation proof for ${MODULE} (ID1) ==="
note "backends: ${backends}"
echo

# ---------------------------------------------------------------------------
echo "Control arm: the unmutated token module, on every backend"
# ---------------------------------------------------------------------------
control_ok=1
for b in ${backends}; do
	state="$(run_suite "${b}")"
	if [ "${state}" != "ran" ]; then
		printf '  [MISS]   control: the suite did not build on %s\n' "${b}"
		tail -12 "${work}/out.${b}" | sed 's/^/    /'
		control_ok=0
		continue
	fi
	n_ok="$(grep -c '\[OK\]' "${work}/out.${b}" || true)"
	n_bad="$(grep -c '\[FAILED\]' "${work}/out.${b}" || true)"
	if [ "${n_bad}" -eq 0 ] && [ "${n_ok}" -eq "${active_cases}" ]; then
		printf '  [OK]     control: %s backend, %s cases, 0 failures\n' "${b}" "${n_ok}"
	else
		printf '  [MISS]   control: %s backend, %s ok / %s failed (expected %s / 0)\n' \
			"${b}" "${n_ok}" "${n_bad}" "${active_cases}"
		control_ok=0
	fi
done
arms=$((arms + 1))
[ "${control_ok}" = "1" ] || misses=$((misses + 1))
echo

# ---------------------------------------------------------------------------
echo "Mutation arms for ${MODULE} — one per assertion family"
# ---------------------------------------------------------------------------

# --- the four bands --------------------------------------------------------
arm "M1  the warning band collapses into the renewing band" \
	"test_expiry_degrades_to_grace_then_prompt" \
	's/    return ibWarning/    return ibRenewing/'

arm "M2  expiry boundary becomes exclusive (>= to >)" \
	"test_expiry_degrades_to_grace_then_prompt" \
	's/nowUnix >= c.expiresAtField/nowUnix > c.expiresAtField/'

arm "M3  the silent renewing band starts warning the user" \
	"test_expiry_degrades_to_grace_then_prompt" \
	's/  band == ibWarning$/  band in {ibRenewing, ibWarning}/'

arm "M4  renewal is never attempted" \
	"test_expiry_degrades_to_grace_then_prompt" \
	's/  band in {ibRenewing, ibWarning}$/  false/'

# --- revocation and its window ---------------------------------------------
arm "M5  the revocation list is never consulted" \
	"test_revocation_takes_effect_within_the_stated_window" \
	's/if revocations.isRevoked(claims.subjectField):/if false and revocations.isRevoked(claims.subjectField):/'

arm "M6  the revocation window is understated as the renew lead" \
	"test_revocation_takes_effect_within_the_stated_window" \
	's/^  policy.licensePeriod$/  policy.renewLead/'

# M7 was first written as a rewrite of the rejection MESSAGE, which produced a
# dangling string continuation on the following line and did not compile. The
# harness reported that as a MISS rather than a kill — correctly, because an
# assertion that never ran has not been shown to be able to fail. Narrowing the
# guard from `<= 0` to `< 0` is the same defect expressed in code that builds:
# `expires_at: 0` stops being caught as "never expires". It also touches the
# twin guard in `windowsExceedPolicy`, which is harmless — the two differ only
# AT zero, and no other fixture in the suite uses a zero expiry.
arm "M7  a never-expiring token is accepted, unbounding revocation" \
	"test_revocation_takes_effect_within_the_stated_window" \
	's/  if c.expiresAtField <= 0:/  if c.expiresAtField < 0:/'

arm "M8  a widened window no longer needs a recorded reason" \
	"test_revocation_takes_effect_within_the_stated_window" \
	's/  period > policy.licensePeriod or renewLead > policy.renewLead/  false/'

# --- the signature and what a rejection may reveal -------------------------
arm "M9  the signature is never checked" \
	"test_verification_needs_no_network" \
	's/  if not keyring.verify(claims.keyIdField, inspection.messageField,/  if false and keyring.verify(claims.keyIdField, inspection.messageField,/'

arm "M10 a rejected token leaks its claims" \
	"test_verification_needs_no_network" \
	's/    return reject(dkBadSignature, "the pinned key rejected this token")/    return IdentityDecision(kindField: dkBadSignature, bandField: ibNormal, claimsField: claims, detailField: "the pinned key rejected this token")/'

# M11 was first written as `if keyring.verify.isNil:` -> `if false:`, which
# does not fail the assertion — it CRASHES, because the next statement calls
# the nil closure. The harness scored that a MISS, and that verdict is the
# right one twice over: a crash leaves the case neither [OK] nor [FAILED], so
# nothing demonstrated that the fail-closed assertion can go red, and a arm
# whose evidence is a segfault cannot tell a missing guard from a broken build.
# Failing OPEN — returning an ACCEPTED decision where the guard used to
# reject — is the defect the assertion is actually written against.
arm "M11 an absent verifier fails OPEN instead of closed" \
	"the container is refused when it is not ours" \
	's/    return reject(dkMalformed, "no signature verifier was supplied")/    return IdentityDecision(kindField: dkAccepted, bandField: ibNormal, claimsField: claims, detailField: "")/'

# --- rotation --------------------------------------------------------------
arm "M12 the key id is never checked, so rotation is inexpressible" \
	"key rotation is expressible, which licensing cannot do" \
	's/  if not keyring.knows(claims.keyIdField):/  if false:/'

# --- the container ---------------------------------------------------------
arm "M13 a licence container is accepted as an identity token" \
	"the container is refused when it is not ours" \
	's/    if raw\[i\] != byte(IdentityMagic\[i\]):/    if false:/'

arm "M14 a declared length that does not span the container is trusted" \
	"the container is refused when it is not ours" \
	's/  if payloadEnd + SignatureLen != raw.len:/  if false:/'

# --- the published windows -------------------------------------------------
arm "M15 a published window is quietly changed" \
	"the published windows are inherited, not invented" \
	's/  DefaultRenewLead\* = 14/  DefaultRenewLead* = 21/'

# --- claims may not be authored --------------------------------------------
arm "M16 the claim fields become writable by any product" \
	"claims cannot be authored by a product" \
	's/    subjectField: string/    subjectField*: string/'

# ---------------------------------------------------------------------------
# M17 IS THE BACKEND-PORTABILITY ARM AND ASSERTS A DIFFERENT OUTCOME PER
# BACKEND. It is written out longhand because `arm` requires the same verdict
# everywhere, and the whole value here is that the verdicts DIFFER.
# ---------------------------------------------------------------------------
if [ "${backends}" = "c js" ]; then
	label="M17 the JSON guard is narrowed to except CatchableError"
	want="test_rejects_a_payload_that_is_not_json"
	if ! mutate 's/^  except:$/  except CatchableError:/'; then
		miss "${label}: the mutation changed nothing"
		restore
	else
		c_state="$(run_suite c)"
		js_state="$(run_suite js)"
		if [ "${c_state}" != "ran" ]; then
			miss "${label}: the mutated module did not compile on C"
		elif case_red c "${want}"; then
			miss "${label}: the C backend ALSO reddened. The arm's whole claim is that this defect is invisible on C, so a red there means the mutation is not the one CONTRIBUTING.md describes"
		elif ! case_green c "${want}"; then
			miss "${label}: the C backend neither passed nor failed the case"
		elif [ "${js_state}" != "ran" ] && ! grep -q 'SyntaxError' "${work}/out.js"; then
			miss "${label}: the JS run produced neither case results nor a SyntaxError"
			tail -8 "${work}/out.js" | sed 's/^/    /'
		elif case_red js "${want}" || grep -q 'SyntaxError' "${work}/out.js"; then
			pass "${label}"
			note "    C backend: GREEN (JsonParsingError IS a CatchableError there)"
			note "    JS backend: RED  (V8's raw SyntaxError matches no Nim type)"
			note "    This is why vm-unit-js is load-bearing and not duplicative."
		else
			miss "${label}: the JS backend did not redden \"${want}\""
			grep '\[FAILED\]' "${work}/out.js" | sed 's/^/    /' | head -4
		fi
		restore
	fi
else
	note "M17 skipped: it needs both backends (CT_IDENTITY_ARMS=c is set)"
fi

# ---------------------------------------------------------------------------
echo
echo "Control arm: the unmutated session module"
# ---------------------------------------------------------------------------
use_pair session
control_ok=1
for b in ${backends}; do
	state="$(run_suite "${b}")"
	if [ "${state}" != "ran" ]; then
		printf '  [MISS]   control(session): the suite did not build on %s\n' "${b}"
		tail -12 "${work}/out.${b}" | sed 's/^/    /'
		control_ok=0
		continue
	fi
	n_ok="$(grep -c '\[OK\]' "${work}/out.${b}" || true)"
	n_bad="$(grep -c '\[FAILED\]' "${work}/out.${b}" || true)"
	if [ "${n_bad}" -eq 0 ] && [ "${n_ok}" -eq "${active_cases}" ]; then
		printf '  [OK]     control(session): %s backend, %s cases, 0 failures\n' "${b}" "${n_ok}"
	else
		printf '  [MISS]   control(session): %s backend, %s ok / %s failed (expected %s / 0)\n' \
			"${b}" "${n_ok}" "${n_bad}" "${active_cases}"
		control_ok=0
	fi
done
arms=$((arms + 1))
[ "${control_ok}" = "1" ] || misses=$((misses + 1))
echo

# ---------------------------------------------------------------------------
echo "Mutation arms for ${MODULE2} — the layer that CAN reach a network"
# ---------------------------------------------------------------------------

# S1 IS THE ONE THIS WHOLE MODULE EXISTS FOR. §3.3.1a's first row is "No
# network required, no renewal attempted", and a refresh client that polls in
# the normal band passes every functional test while deleting the offline
# property. Only a call COUNT catches it.
arm "S1  the refresh client polls in the normal band" \
	"the normal band makes no network call at all" \
	's/  if action == raNone:/  if false:/'

arm "S2  the silent and visible bands collapse into one action" \
	"the renewing band refreshes silently and the warning band visibly" \
	's/  of ibRenewing: raSilent/  of ibRenewing: raVisible/'

# S3: an unknown key id is answerable locally. Skipping that check sends
# attacker-shaped input to the transport, which is how a malformed token
# becomes a way to drive traffic.
arm "S3  an unknown key id is sent to the transport instead of refused locally" \
	"a token that fails inspection never becomes a network event" \
	's/  if not known:/  if false:/'

arm "S4  a fetched revocation list is discarded" \
	"revocation arrives over the transport and takes effect" \
	's/      s.revocationsField = list/      discard list/'

arm "S5  revocation staleness uses the warn lead instead of the renew lead" \
	"revocation staleness is the renew lead, not a number of its own" \
	's/  nowUnix - s.revocationsField.obtainedAt > s.policyField.renewLead/  nowUnix - s.revocationsField.obtainedAt > s.policyField.warnLead/'

# S6 was first written as a two-line sed pattern with an embedded \n, which
# sed does not match against the pattern space line-by-line — it changed
# nothing, and the harness said so rather than scoring a phantom kill. The
# single-line form matches the same guard in `decide`, `plan` AND `bandOf`,
# which is correct here: all three are asserted by the one case, and a session
# that forgot it had no token would be wrong in all three ways at once.
arm "S6  a session with no token decides as though it had one" \
	"a session with no token is refused, and says so" \
	's/if not s.hasTokenField:/if false:/'

arm "S7  an invalid signature still admits the token" \
	"admission checks the signature exactly once, and only after inspection" \
	's/      if not valid:/      if false:/'

# S8's subject lives in token.nim but its ASSERTION lives in the session
# suite, so the pair is swapped by hand: mutate the token module, run the
# session suite. This is the one place the two are deliberately crossed, and
# it is crossed because `rejectedDecision` is the seam between them.
active_module="${MODULE}"
arm "S8  the decision constructor stops coercing a forged acceptance" \
	"a decision cannot be forged through the exported constructor" \
	's/    kindField: (if kind == dkAccepted: dkMalformed else: kind),/    kindField: kind,/'
active_module="${MODULE2}"

# ---------------------------------------------------------------------------
echo
echo "Control arm: the unmutated device-grant module"
# ---------------------------------------------------------------------------
use_pair devicegrant
control_ok=1
for b in ${backends}; do
	state="$(run_suite "${b}")"
	if [ "${state}" != "ran" ]; then
		printf '  [MISS]   control(device grant): the suite did not build on %s\n' "${b}"
		tail -12 "${work}/out.${b}" | sed 's/^/    /'
		control_ok=0
		continue
	fi
	n_ok="$(grep -c '\[OK\]' "${work}/out.${b}" || true)"
	n_bad="$(grep -c '\[FAILED\]' "${work}/out.${b}" || true)"
	if [ "${n_bad}" -eq 0 ] && [ "${n_ok}" -eq "${active_cases}" ]; then
		printf '  [OK]     control(device grant): %s backend, %s cases, 0 failures\n' "${b}" "${n_ok}"
	else
		printf '  [MISS]   control(device grant): %s backend, %s ok / %s failed (expected %s / 0)\n' \
			"${b}" "${n_ok}" "${n_bad}" "${active_cases}"
		control_ok=0
	fi
done
arms=$((arms + 1))
[ "${control_ok}" = "1" ] || misses=$((misses + 1))
echo

# ---------------------------------------------------------------------------
echo "Mutation arms for ${MODULE3} — ID2's fallback flow"
# ---------------------------------------------------------------------------

# G1 IS THE DECISION ITSELF. The device grant is the flow for when loopback
# CANNOT run; a selection that takes it while loopback works makes the weaker
# flow reachable in the one state neither threat model covers.
arm "G1  the fallback engages while loopback still works" \
	"the fallback engages only when loopback cannot run" \
	's/  if capability.canBindLoopback and capability.canLaunchBrowser:/  if capability.canBindLoopback or capability.canLaunchBrowser:/'

# G2: a third field on the capability record is the configuration §5.3 refuses.
arm "G2  the capability record grows a configuration field" \
	"nothing but a measurement can select the flow" \
	's/    canLaunchBrowser\*: bool/    canLaunchBrowser*: bool\n    forceDeviceGrant*: bool/'

# G3: the device code is a bearer secret; the user code is not. Showing the
# wrong one hands the session to anyone who reads the screen.
arm "G3  the user-facing prompt leaks the device code" \
	"the device code is never in what the user is shown" \
	's/  "To sign in, visit " \& a.verificationUriField \&/  "To sign in, visit " \& a.deviceCodeField \&/'

# G4: RFC 8628 §3.5 says the slow_down increase persists "for this and all
# subsequent requests". Resetting on the next pending is the obvious
# implementation and the wrong one.
# G4's first writing used a two-line sed with an embedded \n — the same
# mistake S6 made, and sed does not match that against the pattern space, so
# it changed nothing and the harness said so rather than scoring a phantom
# kill. THAT IS THE SECOND TIME IN THIS FILE; the rule is now explicit:
# every arm here is a SINGLE-LINE substitution, and an arm that needs more
# than one line is written longhand like M17 and G9.
#
# The single-line form computes the raise from the DEFAULT rather than from
# the current interval, so a second slow_down returns 10 instead of 15 — the
# rise stops persisting, which is exactly what RFC 8628 §3.5 forbids.
arm "G4  the slow_down increase does not persist" \
	"slow_down raises the interval and the rise persists" \
	's/  min(current + SlowDownIncrement, MaxPollInterval)/  min(DefaultPollInterval + SlowDownIncrement, MaxPollInterval)/'

# G5: our own deadline, not the server's. Off by one at the boundary.
arm "G5  the poll window closes one second late" \
	"polling stops at the deadline, on our own clock" \
	's/  nowUnix >= auth.expiresAtField/  nowUnix > auth.expiresAtField/'

# G6: trap 2, exactly. Success must be the PRESENCE of a token, never the
# absence of an error — an empty object must not read as "signed in".
arm "G6  an empty response reads as signed in" \
	"poll responses classify to RFC 8628's outcomes" \
	's/    if token.isNil or token.kind != JString or token.getStr.len == 0:/    if false:/'

# G7: expires_in is RELATIVE. Storing it as absolute makes every deadline
# 1970, so polling stops immediately — or, with the comparison flipped, never.
arm "G7  expires_in is stored as though it were absolute" \
	"a device authorization response is parsed into an absolute deadline" \
	's/  auth.expiresAtField = nowUnix + expiresIn/  auth.expiresAtField = expiresIn/'

# G8: RFC 8628 §3.2 — interval is OPTIONAL and defaults to 5. Defaulting to 0
# is a busy-poll against the authorization server.
arm "G8  a missing interval defaults to zero rather than five" \
	"a device authorization response is parsed into an absolute deadline" \
	's/    if interval <= 0: DefaultPollInterval else: int(interval)/    int(interval)/'

# ---------------------------------------------------------------------------
# G9 IS THE SECOND BACKEND-DIFFERENTIATED ARM, and it exists for the same
# reason M17 does: this module parses attacker-shaped JSON off the network on
# both backends, so narrowing its guards is invisible on C and fatal on JS.
# Keeping one such arm per module that parses is the rule this campaign
# arrived at; adding a parser without one would quietly drop the only
# demonstration that the JS lane earns its runtime.
# ---------------------------------------------------------------------------
if [ "${backends}" = "c js" ]; then
	label="G9  device_grant's JSON guards narrowed to except CatchableError"
	want="parses nothing that is not a device authorization response"
	if ! mutate 's/^  except:$/  except CatchableError:/'; then
		miss "${label}: the mutation changed nothing"
		restore
	else
		c_state="$(run_suite c)"
		js_state="$(run_suite js)"
		if [ "${c_state}" != "ran" ]; then
			miss "${label}: the mutated module did not compile on C"
		elif case_red c "${want}"; then
			miss "${label}: the C backend ALSO reddened, so this is not the portability defect"
		elif ! case_green c "${want}"; then
			miss "${label}: the C backend neither passed nor failed the case"
		elif case_red js "${want}" || grep -q 'SyntaxError' "${work}/out.js"; then
			pass "${label}"
			note "    C backend: GREEN, JS backend: RED — the same class as M17,"
			note "    in the second module that parses network input."
		else
			miss "${label}: the JS backend did not redden \"${want}\""
			grep '\[FAILED\]' "${work}/out.js" | sed 's/^/    /' | head -4
		fi
		restore
	fi
fi

echo
echo "${arms} arm(s), ${misses} miss(es)"
if [ "${misses}" -gt 0 ]; then
	echo "RESULT: FAILED — ${misses} arm(s) did not kill on their own case"
	exit 1
fi
echo "RESULT: OK — every assertion family in the identity layer (${MODULE}, ${MODULE2}, ${MODULE3}) has a mutation that reddens it"
