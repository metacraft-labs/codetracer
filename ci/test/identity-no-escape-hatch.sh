#!/usr/bin/env bash
#
# identity-no-escape-hatch.sh — no environment variable may turn identity
# verification off.
#
# ## The hazard this exists for, named
#
# `codetracer-native-recorder/ct_cli/src/ct_cli/licensing_ffi.nim` defines
# `CT_LICENSE_DEV_NO_FFI`. When it is set, `ctLicenseStart` returns a sentinel
# handle, `ctLicenseHeartbeat` returns `Allowed` unconditionally, and the
# licensing cdylib is never loaded. Its own comment says production builds must
# not set it and that the check is deliberately a RUNTIME one — which is to say
# it is a supported way to run the product with enforcement disabled.
#
# For a licence that is survivable: the worst case is an unpaid replay. For an
# **identity** token it is an authentication bypass — every claim about who the
# subject is, and every entitlement resolved from it, becomes settable by
# whoever controls the environment. The failure is not that someone will ship
# with it set; it is that the pattern is normal here, so the next verifier gets
# one because the last one had one.
#
# So the absence is asserted rather than left to habit. That is the whole file.
#
# ## Why a scanner needs two positive controls
#
# "Nothing in these modules reads the environment" is a universal claim over a
# set, and Verification-Harness-Traps.md 4 is unambiguous about those: a search
# whose pattern cannot match is indistinguishable from a codebase that is
# clean, and a scanner with no positive control cannot fail.
#
# There are two here, and they answer different questions:
#
#   SYNTHETIC  a file this script writes, containing the exact hatch, must be
#              FLAGGED. Proves the pattern matches and the engine works. Always
#              available, so the control can never be skipped.
#   REAL       the same scanner over `licensing_ffi.nim` must find
#              `CT_LICENSE_DEV_NO_FFI`. Proves the hazard is not hypothetical
#              and that this scanner would have caught the one that exists.
#              Skipped with a loud note when the sibling is absent — and the
#              synthetic control still holds the floor.
#
# ## Prose is allowed; code is not
#
# The identity modules discuss environment variables at length — this comment
# does too. So a hit is a violation only when it is NOT on a comment line.
# Stripping comments before scanning would be the obvious approach and is the
# wrong one: a `#` inside a string literal would truncate the line and could
# HIDE a real call. Scanning everything and then classifying each hit cannot
# hide anything.
#
# Usage:  bash ci/test/identity-no-escape-hatch.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

IDENTITY_DIR="src/frontend/viewmodel/identity"
EXPECTED_MODULES=4
# `when defined(...)` is legitimate here — `webcrypto_verifier.nim` needs it to
# tell a browser from a native build — but every one of them is a place where
# two different behaviours ship, so the number is budgeted. A new one is then a
# decision recorded in this file rather than a silent second code path through
# a verifier.
EXPECTED_WHEN_DEFINED=3
WHEN_DEFINED_OWNER="webcrypto_verifier.nim"

# POSIX ERE only — `\b`, `\d`, `\w`, `\s` are GNU/PCRE and `git grep` does not
# speak them (trap 4, part 1). Nothing here is handed to `git grep`, but the
# habit is the point: the engine is part of the scanner.
HATCH_PATTERN='getEnv|existsEnv|putEnv|delEnv|envPairs|getAllEnv|paramStr|commandLineParams|process\.env|os\.environ|std/envvars|std/os([^a-zA-Z]|$)|std/osproc'

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
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT INT TERM

# scan FILE -> one "line:text" per hit that is NOT a comment line.
# A comment line is one whose first non-blank character is '#'.
scan() {
	grep -nE "${HATCH_PATTERN}" "$1" 2>/dev/null |
		while IFS= read -r hit; do
			local_text="${hit#*:}"
			case "$(printf '%s' "${local_text}" | sed 's/^[[:space:]]*//' | cut -c1)" in
			'#') ;;
			*) printf '%s\n' "${hit}" ;;
			esac
		done
}

echo "=== identity: no escape hatch (ID2 hard requirement) ==="
echo

# ---------------------------------------------------------------------------
echo "Step 1: the scan reaches the modules it claims to cover"
echo "    A count, not a non-emptiness check: an existential control is"
echo "    satisfied by one member of four (trap 4b)."
# ---------------------------------------------------------------------------
mapfile -t modules < <(find "${IDENTITY_DIR}" -name '*.nim' -type f 2>/dev/null | sort)
if [ "${#modules[@]}" -eq "${EXPECTED_MODULES}" ]; then
	ok "the identity layer is ${#modules[@]} module(s), as this gate expects"
	for m in "${modules[@]}"; do note "  ${m}"; done
else
	bad "the identity layer has ${#modules[@]} module(s), expected ${EXPECTED_MODULES} — a module was added or removed and nobody decided whether it may read the environment"
	for m in "${modules[@]}"; do note "  ${m}"; done
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: THE SYNTHETIC POSITIVE CONTROL — the scanner can report a hatch"
# ---------------------------------------------------------------------------
cat >"${work}/hatch.nim" <<'EOF'
import std/os
const DevNoVerifyEnvOverride* = "CT_IDENTITY_DEV_NO_VERIFY"
proc verificationDisabled*(): bool =
  getEnv(DevNoVerifyEnvOverride).len > 0
EOF
synthetic_hits="$(scan "${work}/hatch.nim" | grep -c . || true)"
if [ "${synthetic_hits}" -ge 2 ]; then
	ok "the scanner flags a planted escape hatch (${synthetic_hits} hits: the import and the call)"
else
	bad "the scanner found ${synthetic_hits} hit(s) in a file that deliberately contains an escape hatch — the pattern cannot match, so every clean result below is meaningless"
fi

# And it must NOT flag a file that only discusses one, or the gate would be
# unusable in a codebase that documents its own hazards — which this one does.
cat >"${work}/prose.nim" <<'EOF'
## This module deliberately does not call getEnv, and must never read
## process.env or commandLineParams. See CT_LICENSE_DEV_NO_FFI for why.
proc nothing*() = discard
EOF
prose_hits="$(scan "${work}/prose.nim" | grep -c . || true)"
if [ "${prose_hits}" -eq 0 ]; then
	ok "the scanner does not flag prose that merely names the hazard"
else
	bad "the scanner flagged ${prose_hits} comment line(s); it cannot tell discussion from code"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: THE REAL POSITIVE CONTROL — the hatch that actually exists"
echo "    Proves the hazard is not hypothetical and that this scanner would"
echo "    have caught the one already shipping in the licensing binding."
# ---------------------------------------------------------------------------
real_ffi=""
for candidate in \
	"${repo_root}/../codetracer-native-recorder/ct_cli/src/ct_cli/licensing_ffi.nim" \
	"${repo_root}/../../codetracer-native-recorder/ct_cli/src/ct_cli/licensing_ffi.nim"; do
	[ -f "${candidate}" ] && real_ffi="${candidate}" && break
done
if [ -z "${real_ffi}" ]; then
	note "SKIPPED: codetracer-native-recorder is not a sibling here."
	note "This is a control, not a subject — step 2's synthetic hatch still"
	note "proves the scanner works, so the run is not vacuous. But note that"
	note "the count of checks below will differ from a full run."
else
	if grep -q "CT_LICENSE_DEV_NO_FFI" "${real_ffi}"; then
		ok "the licensing binding really does define CT_LICENSE_DEV_NO_FFI — the hazard is real"
	else
		bad "CT_LICENSE_DEV_NO_FFI is not in ${real_ffi}; this control's subject moved and the control is now asserting nothing"
	fi
	real_hits="$(scan "${real_ffi}" | grep -c . || true)"
	if [ "${real_hits}" -ge 1 ]; then
		ok "the scanner flags the real binding's environment reads (${real_hits} hit(s))"
	else
		bad "the scanner found no environment read in a file that has one"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: no identity module reads the environment or the command line"
# ---------------------------------------------------------------------------
total_hits=0
scanned=0
for m in "${modules[@]}"; do
	scanned=$((scanned + 1))
	hits="$(scan "${m}")"
	n="$(printf '%s' "${hits}" | grep -c . || true)"
	if [ "${n}" -gt 0 ]; then
		total_hits=$((total_hits + n))
		bad "${m} reads the environment or the command line:"
		printf '%s\n' "${hits}" | sed 's/^/      /'
	fi
done
if [ "${scanned}" -eq "${EXPECTED_MODULES}" ]; then
	ok "all ${scanned} identity module(s) were scanned"
else
	bad "scanned ${scanned} module(s), expected ${EXPECTED_MODULES}"
fi
if [ "${total_hits}" -eq 0 ]; then
	ok "no identity module can be switched off by an environment variable"
else
	bad "${total_hits} escape-hatch site(s) across the identity layer"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 5: conditional compilation is budgeted, so a second code path"
echo "        through a verifier is a decision rather than an accident"
# ---------------------------------------------------------------------------
when_total=0
for m in "${modules[@]}"; do
	n="$(grep -c 'when defined(' "${m}" || true)"
	when_total=$((when_total + n))
	base="$(basename "${m}")"
	if [ "${n}" -gt 0 ] && [ "${base}" != "${WHEN_DEFINED_OWNER}" ]; then
		bad "${m} has ${n} 'when defined(' branch(es); only ${WHEN_DEFINED_OWNER} is budgeted for them, because only it must tell a browser from a native build"
	fi
done
if [ "${when_total}" -eq "${EXPECTED_WHEN_DEFINED}" ]; then
	ok "the identity layer has ${when_total} 'when defined(' branch(es), as budgeted"
else
	bad "the identity layer has ${when_total} 'when defined(' branch(es), budget says ${EXPECTED_WHEN_DEFINED} — fails in both directions on purpose"
fi

# The token verifier itself must have NONE. It is the one module that decides
# whether a subject is who they say they are, and it must compile to exactly
# one behaviour on every backend.
token_when="$(grep -c 'when defined(' "${IDENTITY_DIR}/token.nim" || true)"
if [ "${token_when}" -eq 0 ]; then
	ok "token.nim has no conditional compilation at all — one behaviour, every backend"
else
	bad "token.nim has ${token_when} 'when defined(' branch(es); the verifier must not vary by build"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — identity verification cannot be disabled by configuration"
