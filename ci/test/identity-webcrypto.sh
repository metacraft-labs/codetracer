#!/usr/bin/env bash
#
# identity-webcrypto.sh — ID1's browser signature seam, executed and mutated.
#
# `viewmodel/identity/webcrypto_verifier.nim` is the browser end of the
# `IdentityTransport.verifySignature` seam. It cannot be exercised by a
# `vm-unit-js` suite: `crypto.subtle.verify` is a real V8 microtask and
# `drainPlatformCallbacks` drains nim-everywhere's queue rather than V8's, as
# `outcome.nim`'s own comment says. So it is driven here, under Node, whose
# `globalThis.crypto.subtle` implements Ed25519 with the same API a browser
# exposes — which means this runs the code the tab runs, with real keys.
#
# ## What is asserted, and why the COUNT is
#
# The probe prints one line per check and a `PROBE-DONE checks=N failures=M`
# summary. This gate asserts the summary's COUNT, not merely its presence: a
# probe that returned early after three checks would print a summary, exit 0
# and look identical to a full run. That is trap 4b's silent skip, and the
# count is the only thing that shows it.
#
# The exit code is asserted separately from the summary, per trap 1: a probe
# that died before printing is a different state from one that failed a check,
# and "no summary" must never be read as "no failures".
#
# Usage:  bash ci/test/identity-webcrypto.sh
# Env:    CT_NIM_CACHE_ROOT  nimcache root (default: per-checkout, see ci/lib/nim-cache-root.sh)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

MODULE="src/frontend/viewmodel/identity/webcrypto_verifier.nim"
PROBE="ci/test/identity_webcrypto_probe.nim"
EXPECTED_CHECKS=14

cache_root="$(ct_nim_cache_root "${repo_root}")"
work="$(mktemp -d)"

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

cleanup() {
	if [ -f "${work}/verifier.orig" ]; then
		cp "${work}/verifier.orig" "${MODULE}" 2>/dev/null || true
	fi
	rm -rf "${work}"
}
trap cleanup EXIT INT TERM

command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH; run inside the dev shell" >&2
	exit 2
}
command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH; this gate drives the probe under Node" >&2
	exit 2
}
[ -f "${MODULE}" ] || {
	echo "${MODULE} does not exist; this gate has no subject" >&2
	exit 2
}
cp "${MODULE}" "${work}/verifier.orig"

echo "=== identity WebCrypto seam (ID1) ==="
note "node: $(node --version)"
echo

# run_probe -> transcript at ${work}/out ; echoes the probe's exit code, or
# 'nobuild' when compilation failed. A build failure is NOT a result.
run_probe() {
	if ! nim js -d:nodejs --hints:off --warnings:off \
		--nimcache:"${cache_root}/idwc" \
		-o:"${work}/probe.js" "${PROBE}" >"${work}/build" 2>&1; then
		printf 'nobuild'
		return
	fi
	node "${work}/probe.js" >"${work}/out" 2>&1
	printf '%s' "$?"
}

probe_checks() {
	sed -n 's/^PROBE-DONE checks=\([0-9]*\) .*$/\1/p' "${work}/out" | head -1
}
probe_failures() {
	sed -n 's/^PROBE-DONE .* failures=\([0-9]*\)$/\1/p' "${work}/out" | head -1
}

# ---------------------------------------------------------------------------
echo "Step 1: the probe runs against the real WebCrypto implementation"
# ---------------------------------------------------------------------------
rc="$(run_probe)"
if [ "${rc}" = "nobuild" ]; then
	echo "the probe did not compile" >&2
	tail -20 "${work}/build" >&2
	exit 2
fi

if [ "${rc}" = "0" ]; then
	ok "the probe exited 0"
else
	bad "the probe exited ${rc}"
	sed 's/^/    /' "${work}/out"
fi

n="$(probe_checks)"
m="$(probe_failures)"
if [ -z "${n}" ]; then
	bad "the probe printed no PROBE-DONE summary — it died before finishing, which is not the same as passing"
	sed 's/^/    /' "${work}/out" | tail -10
else
	if [ "${n}" = "${EXPECTED_CHECKS}" ]; then
		ok "the probe ran ${n} checks, the number this gate expects"
	else
		bad "the probe ran ${n} checks, expected ${EXPECTED_CHECKS} — a count that moves means a check appeared or silently stopped running"
	fi
	if [ "${m}" = "0" ]; then
		ok "the probe reported 0 failures"
	else
		bad "the probe reported ${m} failure(s)"
		grep '^\[FAIL\]' "${work}/out" | sed 's/^/    /'
	fi
fi

# The positive control has to be visible in the transcript by name: if
# WebCrypto silently refused everything, every rejection check would pass and
# this one would not.
if grep -qF "[ok] a genuine Ed25519 signature verifies" "${work}/out"; then
	ok "a real Ed25519 signature verified — the rejections below mean something"
else
	bad "the positive control did not pass; every 'does not verify' check in this probe is vacuous without it"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: mutation arms — each must redden the probe check written for it"
# ---------------------------------------------------------------------------
arm() {
	local label="$1" want="$2" sed_script="$3"
	sed "${sed_script}" "${work}/verifier.orig" >"${MODULE}"
	if cmp -s "${MODULE}" "${work}/verifier.orig"; then
		bad "${label}: the mutation changed nothing — the pattern no longer matches"
		cp "${work}/verifier.orig" "${MODULE}"
		return
	fi
	local r
	r="$(run_probe)"
	if [ "${r}" = "nobuild" ]; then
		bad "${label}: the mutated module did not compile; the check never ran, so this is not a kill"
	elif grep -qF "[FAIL] ${want}" "${work}/out"; then
		ok "${label} — killed by \"${want}\""
	else
		bad "${label}: did not redden \"${want}\""
		note "    a kill by a different check is a MISS. Checks that failed:"
		grep '^\[FAIL\]' "${work}/out" | sed 's/^/    /' | head -4
	fi
	cp "${work}/verifier.orig" "${MODULE}"
}

arm "W1 an unpinned key id is accepted instead of refused" \
	"an unpinned key id is refused" \
	's/      return resolvedOk(false)/      return resolvedOk(true)/'

# W2 and W4 target the TWO different failure paths in the binding. W2's first
# writing pointed at `.catch` while the probe only exercised the synchronous
# `atob` throw, so it reddened nothing and the harness said so. The probe was
# strengthened to cover both paths rather than the arm being written off.
arm "W2 an asynchronous WebCrypto rejection is reported as a valid signature" \
	"key material of the wrong length is an error, not a bad-signature verdict" \
	's/      .catch(function () { return -1; });/      .catch(function () { return 1; });/'

arm "W4 a synchronous key-decoding failure is reported as a valid signature" \
	"key material that is not base64 is an error, not a bad-signature verdict" \
	's/    return Promise.resolve(-1);/    return Promise.resolve(1);/'

arm "W3 verification always answers valid" \
	"a one-bit-flipped signature does not verify" \
	's/      .then(function (valid) { return valid ? 1 : 0; })/      .then(function (valid) { return 1; })/'

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — the browser signature seam verifies real Ed25519 and refuses everything else"
