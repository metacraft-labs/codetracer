#!/usr/bin/env bash
#
# identity-token-mutation.sh — the mutation proof for the identity layer:
# the verifier (ID1), the session (ID1) and the device grant (ID2).
#
# `src/frontend/viewmodel/identity/token.nim` decides whether a signed identity
# token is accepted, which band of its life it is in, and whether a subject is
# revoked. A suite that reports ten green cases over it is worth exactly what
# the evidence says it is, so this file supplies the evidence: a mutation per
# assertion family, each verified to redden THE CASE WRITTEN FOR IT.
#
# A mutation caught by some other case is a MISS, not a kill. Every arm below
# names the case it expects to go red, and several additionally name the cases
# that must stay GREEN — because an arm that reddens everything proves only
# that the suite noticed a change, not that the assertion in question can fail.
#
# WHAT THIS FILE DOES NOT DO, and the PASSED line now says so too: it never
# reads the suites' case NAMES. The arms are a hand-written list, each matched
# against one name, so "every declared arm killed the case it names" is the only
# universal this gate can support. A case that no arm targets is simply absent
# from the run, and several cases in the three suites are in that position today.
#
# The one thing that IS pinned is the case COUNT: each control arm requires
# exactly `active_cases` `[OK]` lines, so adding a case makes the control arm
# MISS until someone bumps that number. That is a prompt, not a guard — bumping
# the counter is enough to go green again, and nothing requires the new case to
# acquire an arm. Closing the gap properly would mean enumerating the suites'
# `test "..."` names here and failing on any without a corresponding arm, which
# is not implemented.
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
# Env:    CT_NIM_CACHE_ROOT  nimcache root (default: per-checkout, see ci/lib/nim-cache-root.sh)
#         CT_IDENTITY_ARMS   'c' to skip the JS backend (local iteration only;
#                            CI must run both, and M10 needs both)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

MODULE="src/frontend/viewmodel/identity/token.nim"
SUITE="src/frontend/viewmodel/tests/unit/test_identity_token.nim"
MODULE2="src/frontend/viewmodel/identity/session.nim"
SUITE2="src/frontend/viewmodel/tests/unit/test_identity_session.nim"
MODULE3="src/frontend/viewmodel/identity/device_grant.nim"
SUITE3="src/frontend/viewmodel/tests/unit/test_device_grant.nim"
# A FOURTH PAIR, because the parsing moved. The retired `CTI\x01` container was
# parsed in `token.nim`, so the arms for structure, key selection and the JSON
# guard all mutated that file. A compact JWS is parsed in `jwt.nim`, and an arm
# that stayed pointed at `token.nim` would mutate nothing and be correctly
# scored a MISS.
MODULE4="src/frontend/viewmodel/identity/jwt.nim"
SUITE4="src/frontend/viewmodel/tests/unit/test_identity_jwt.nim"

# Which pair the arms below currently operate on. `use_pair` swaps both at
# once, so an arm can never mutate one module and run the other's suite —
# which would produce a green run that proved nothing and looked like a
# surviving mutant.
active_module="${MODULE}"
active_suite="${SUITE}"
active_cases=11
use_pair() {
	case "$1" in
	token)
		active_module="${MODULE}"
		active_suite="${SUITE}"
		active_cases=11
		;;
	session)
		active_module="${MODULE2}"
		active_suite="${SUITE2}"
		active_cases=12
		;;
	jwt)
		active_module="${MODULE4}"
		active_suite="${SUITE4}"
		active_cases=29
		;;
	devicegrant)
		active_module="${MODULE3}"
		active_suite="${SUITE3}"
		active_cases=15
		;;
	esac
}
cache_root="$(ct_nim_cache_root "${repo_root}")"
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
	if [ -f "${work}/jwt.nim.orig" ]; then
		cp "${work}/jwt.nim.orig" "${MODULE4}" 2>/dev/null || true
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
[ -f "${MODULE4}" ] || {
	echo "${MODULE4} does not exist; this proof has no subject" >&2
	exit 2
}
cp "${MODULE4}" "${work}/jwt.nim.orig"

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
	"${MODULE4}") printf '%s' "${work}/jwt.nim.orig" ;;
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

# ARMS RENUMBERED WITH THE FORMAT, and the old names are worth recording
# because their disappearance is the campaign's outcome rather than an
# oversight. M1/M3 mutated `ibWarning`, M5/M6/M8 the revocation window, M13/M14
# the `CTI\x01` container's magic and length field, M15 `DefaultRenewLead`, and
# M9/M11 the synchronous `PinnedKeyring.verify` seam. None of those symbols
# exists: the container is a compact JWS, the windows were licensing's, and the
# signature seam is asynchronous and lives in `session.nim`. An arm pointed at a
# deleted line mutates nothing and is correctly scored a MISS, so they are gone
# rather than nominally kept.
#
# M2, M4, M7, M12, M16 and M17 survive as T1, T3, T7, J4, T9 and J5 — the same
# defects against the code that now holds them.

# --- the bands --------------------------------------------------------------
arm "T1  expiry boundary becomes exclusive (>= to >)" \
	"the bands, and expiry is inclusive" \
	's/nowUnix >= c.expiresAtField/nowUnix > c.expiresAtField/'

arm "T2  nbf is not tested, so a future-dated token is usable now" \
	"the bands, and expiry is inclusive" \
	's/  if c.notBeforeField > 0 and nowUnix < c.notBeforeField:/  if false:/'

arm "T3  renewal is never attempted" \
	"the bands, and expiry is inclusive" \
	's/^  band == ibRenewing$/  false/'

arm "T4  the refresh point is never derived, so nothing ever renews" \
	"the refresh point is derived from the token's own lifetime" \
	's/  if c.issuedAtField <= 0 or c.expiresAtField <= c.issuedAtField:/  if true:/'

# --- what a decision may say -----------------------------------------------
arm "T5  an expired decision stops returning its claims" \
	"inspection takes no clock, so expiry is decided in one place" \
	's/^                            claimsField: claims,$/                            claimsField: IdentityClaims(),/'

arm "T6  an expired identity counts as in force" \
	"inspection takes no clock, so expiry is decided in one place" \
	's/^  d.kindField == dkAccepted$/  d.kindField in {dkAccepted, dkExpired}/'

# --- key selection and binding ---------------------------------------------
arm "T7  an unknown key id is not refused locally" \
	"a key the issuer does not publish is refused, distinctly" \
	's/    return refuse(dkUnknownKeyId, e.msg)/    discard e.msg/'

arm "T8  a wrong audience is reported as a wrong issuer" \
	"another issuer, and another of our issuer's clients, are told apart" \
	's/    let wrongAudience = "audience" in e.msg or "authorized party" in e.msg/    let wrongAudience = false/'

# --- the claim rules -------------------------------------------------------
arm "T9  a token that names nobody is accepted" \
	"claims that do not hold together are refused, each by name" \
	's/  if c.subjectField.len == 0:/  if false:/'

arm "T10 a token whose iat is after its exp is accepted" \
	"claims that do not hold together are refused, each by name" \
	's/  if c.issuedAtField > 0 and c.issuedAtField >= c.expiresAtField:/  if false:/'

# --- claims may not be authored --------------------------------------------
arm "T11 the claim fields become writable by any product" \
	"claims cannot be authored by a product" \
	's/    subjectField: string/    subjectField*: string/'

arm "T12 the decision constructor stops coercing a forged acceptance" \
	"claims cannot be authored by a product" \
	's/    kindField: (if kind == dkAccepted: dkMalformed else: kind),/    kindField: kind,/'

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
arm "S1  the refresh client polls when nothing needs renewing" \
	"a valid, un-aged token makes no network call at all" \
	's/  if action == raNone:/  if false:/'

arm "S2  the renewing band stops renewing" \
	"past half its life the session renews, silently" \
	's/  of ibRenewing: raSilent/  of ibRenewing: raNone/'

arm "S3  an invalid signature still admits the token" \
	"an invalid signature is refused, and does not admit the token" \
	's/      if not valid:/      if false:/'

arm "S4  a session with no token decides as though it had one" \
	"a session with no token is refused, and says so" \
	's/if not s.hasTokenField:/if false:/'

# --- revocation, which is now a refusal to renew rather than a list ---------
#
# S5 and S6 replace the two arms that mutated the revocation LIST — one that
# discarded a fetched list, one that thresholded its staleness on licensing's
# warn lead instead of its renew lead. Neither line exists: there is no list,
# because OIDC delivers revocation as `invalid_grant` on the refresh.
arm "S5  a transport failure is treated as a revocation" \
	"a refusal to renew is how revocation arrives" \
	's/      if error.kind == pkAccessDenied or "invalid_grant" in error.message:/      if true:/'

arm "S6  a revoked session keeps deciding as though it were live" \
	"a refusal to renew is how revocation arrives" \
	's/  if s.revokedField:/  if false:/'

arm "S7  a fresh token does not clear a revocation the issuer overtook" \
	"a token that verifies clears a revocation the issuer has overtaken" \
	's/      s.revokedField = false/      discard s.revokedField/'

arm "S8  an empty key set replaces a working one" \
	"the key set is refetched on rotation, and never replaced by nothing" \
	's/      if keys.len == 0:/      if false:/'

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
# G6 WAS RE-AIMED, not deleted. It used to mutate
# `if token.isNil or token.kind != JString or token.getStr.len == 0:` — the
# `access_token` guard — and that line is gone: success is now decided by the
# `id_token`, through a `present` helper, because an access token authorises
# calls without saying whose they are. The property is unchanged and the line
# holding it moved, so the arm follows it.
arm "G6  an empty response reads as signed in" \
	"poll responses classify to RFC 8628's outcomes" \
	's/      not (f.isNil or f.kind != JString or f.getStr.len == 0)/      true/'

arm "G10 an access token with no identity reads as signed in" \
	"poll responses classify to RFC 8628's outcomes" \
	's/    if present("id_token"):/    if present("id_token") or present("access_token"):/'

arm "G11 a token response with no id_token is accepted" \
	"the token response yields an identity, a deadline and two secrets" \
	's/  if grant.idTokenField.len == 0:/  if false:/'

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

# ---------------------------------------------------------------------------
echo
echo "Control arm: the unmutated JWT module"
echo "    A FOURTH PAIR, because the parsing moved. The retired container was"
echo "    parsed in token.nim, so the arms for structure, key selection and the"
echo "    JSON guard mutated that file. A compact JWS is parsed in jwt.nim."
# ---------------------------------------------------------------------------
use_pair jwt
control_ok=1
for b in ${backends}; do
	state="$(run_suite "${b}")"
	if [ "${state}" != "ran" ]; then
		printf '  [MISS]   control(jwt): the suite did not build on %s\n' "${b}"
		tail -12 "${work}/out.${b}" | sed 's/^/    /'
		control_ok=0
		continue
	fi
	n_ok="$(grep -c '\[OK\]' "${work}/out.${b}" || true)"
	n_bad="$(grep -c '\[FAILED\]' "${work}/out.${b}" || true)"
	if [ "${n_bad}" -eq 0 ] && [ "${n_ok}" -eq "${active_cases}" ]; then
		printf '  [OK]     control(jwt): %s backend, %s cases, 0 failures\n' "${b}" "${n_ok}"
	else
		printf '  [MISS]   control(jwt): %s backend, %s ok / %s failed (expected %s / 0)\n' \
			"${b}" "${n_ok}" "${n_bad}" "${active_cases}"
		control_ok=0
	fi
done
arms=$((arms + 1))
[ "${control_ok}" = "1" ] || misses=$((misses + 1))
echo

# ---------------------------------------------------------------------------
echo "Mutation arms for ${MODULE4} — where a forged token is actually let in"
# ---------------------------------------------------------------------------

# A forged token rarely defeats RSA; it persuades the verifier not to use it.
# Every arm here is one of those persuasions.
arm "J1  the token chooses its own algorithm" \
	"an algorithm the issuer does not advertise is refused" \
	's/  if result.alg notin allowedAlgs:/  if false:/'

arm "J2  a token with no key id is accepted" \
	"a missing kid is refused at parse time" \
	's/  if result.kid.len == 0:/  if false:/'

arm "J3  an unknown kid is tried against the other keys" \
	"an unknown kid is refused, not tried against the others" \
	's/^    if k.kid == kid:/    if true:/'

# J4 IS AIMED AT THE REASON, NOT THE REFUSAL, and that is the point. With the
# base64url guard gone `parseJwt` still raises: the standard-base64 segment
# decodes to bytes that are not JSON. So a case asserting only "it is refused"
# stays green over the defect — which is what the first writing of this arm
# found, and why it now targets the case that asserts the SENTENCE.
arm "J4  standard base64 is accepted in a segment" \
	"a base64url problem keeps its own sentence, not the JSON one" \
	"s/    if c in {'+', '\/', '='}:/    if false:/"

# J5 first mutated `if azp.len == 0:` alone, and the NEXT guard caught it: with
# that one disabled, `azp != audience` compares "" against ours and refuses
# anyway. Nothing reddened, which is the harness telling the truth — the arm was
# testing code that is guarded twice. Removing the whole multi-audience branch
# is the defect the case is actually written against.
arm "J5  the multi-audience rule is not applied at all" \
	"two audiences and no azp is refused" \
	's/  if aud != nil and aud.kind == JArray and aud.getElems().len > 1:/  if false:/'

arm "J6  the authorized party may name another client" \
	"two audiences with azp naming another client is refused" \
	's/    if azp != audience:/    if false:/'

arm "J7  a token of any size is decoded" \
	"a token larger than the bound is refused before it is decoded" \
	's/  if compact.len > MaxCompactJwsLen:/  if false:/'

# ---------------------------------------------------------------------------
# J8 IS THE BACKEND-PORTABILITY ARM AND ASSERTS A DIFFERENT OUTCOME PER
# BACKEND. It is written out longhand because `arm` requires the same verdict
# everywhere, and the whole value here is that the verdicts DIFFER.
#
# It is M17's successor, re-aimed: the bare `except:` it mutates moved from
# `token.nim`'s `parseClaims` into `jwt.nim` along with the `parseJson` call it
# guards. THIS DEFECT REALLY SHIPPED, in jwt.nim and issuer.nim both, and was
# caught by measurement rather than by review — which is the argument for the
# arm existing at all.
# ---------------------------------------------------------------------------
if [ "${backends}" = "c js" ]; then
	label="J8  the JSON guard is narrowed to except CatchableError"
	want="a token segment that is not JSON raises JwtError, on every backend"
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
	note "J8 skipped: it needs both backends (CT_IDENTITY_ARMS=c is set)"
fi

echo
echo "${arms} arm(s), ${misses} miss(es)"
if [ "${misses}" -gt 0 ]; then
	echo "RESULT: FAILED — ${misses} arm(s) did not kill on their own case"
	exit 1
fi
echo "RESULT: OK — ${arms} mutation arm(s) over the identity layer (${MODULE}, ${MODULE2}, ${MODULE3}); each reddened the case it names"
echo "  SCOPE, because this line used to claim more than it checks: this is NOT"
echo '  "every assertion family has a mutation". The arms are a hand-written list'
echo "  and nothing here reads the suites' case names, so a case that no arm"
echo "  targets is invisible to this gate — and several are in that position."
echo "  The control arms do pin the case COUNT, so a NEW case makes them miss"
echo "  until the counter is bumped; bumping it is enough, no arm is required."
echo '  Diff the arms against the suites test "..." names by hand before'
echo "  reading this line as coverage."
