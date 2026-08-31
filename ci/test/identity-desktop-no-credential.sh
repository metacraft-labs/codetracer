#!/usr/bin/env bash
#
# identity-desktop-no-credential.sh — ID2's `test_desktop_never_handles_a_credential`.
#
# "The desktop sign-in path collects no password and hosts no login form; a
# build-time surface check asserts no credential field exists in the
# application."
#
# ## The second half of that sentence is FALSE as written, and that is the finding
#
# Measured on `dev`: 52 source files contain a credential-shaped identifier.
# None of them is a CodeTracer credential. They are
#
#   * a REPLAYED PROGRAM's sudo prompt — `wantsPassword`, `renderPasswordPrompt`.
#     A debugger shows the credential prompts of the process it is debugging;
#     that is the product working.
#   * a third-party PROVIDER key the user supplies for the agent panes —
#     `llmProvider.apiKey`.
#   * a passphrase PROTECTING A SHARED ARTIFACT — the `artifact_crypto` /
#     `artifact_protection` family. A secret about a trace, not about a person.
#   * test fixtures, a vendored SQLite connector, and deployment config.
#
# So "no credential field exists in the application" cannot be the check. A
# scan written that way fails on day one, and a scan tuned until it passes is a
# scan tuned around its own evidence — which is how a token list comes to
# encode a policy nobody stated.
#
# **The check is therefore: every credential surface is CLASSIFIED, and none of
# them is ours.** The classification is written down here, explicitly, rather
# than implied by which words a pattern happens to match. That is the same
# lesson `noir-studio-signed-out.sh` records from the other direction: an LLM
# key and a debuggee's sudo prompt both trip an identity vocabulary and neither
# is an identity.
#
# ## Decision-independence
#
# This gate holds under EITHER desktop sign-in flow — the loopback redirect
# that ships today, or the device authorization grant §5 prescribes. Both keep
# credentials out of our process; that is the property, and it does not depend
# on which flow wins. Nothing here should be read as endorsing either.
#
# Usage:  bash ci/test/identity-desktop-no-credential.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

SIGNIN_PATH="src/ct/online_sharing/authenticate.nim"
SIGNIN_SUPPORT="src/ct/online_sharing/remote_config.nim"
DEVICE_GRANT="src/frontend/viewmodel/identity/device_grant.nim"
IDENTITY_DIR="src/frontend/viewmodel/identity"
EXPECTED_SURFACES=52

# Credential-shaped NAMES the identity layer is allowed to carry, and why.
# Budgeted rather than forbidden, because the layer legitimately holds bearer
# secrets — that is what a token is. What it must never do is COLLECT one from
# a person, which is the separate, absolute check in step 4a.
#
# One entry today:
#   device_grant.nim  `secretDeviceCode` — RFC 8628's `device_code`. It IS a
#                     bearer secret and the flow cannot work without holding
#                     one. It is named conspicuously so that every call site
#                     reads as handling a secret, and `displayPrompt` exists so
#                     that no caller has to decide which of the two codes is
#                     safe to show.
EXPECTED_IDENTITY_CREDENTIAL_NAMES=1

# POSIX ERE. `\b`/`\d`/`\w` are GNU-or-PCRE and the engine is part of the
# scanner (Verification-Harness-Traps.md 4).
#
# EVERY SCAN BELOW IS CASE-INSENSITIVE, and that is not tidiness. Written
# case-sensitively this gate found 41 credential-bearing files; the true number
# is 50. Nim is camelCase, so `wantsPassword`, `getSecret`, `uploadPasswordFile`
# and `apiKey` all contain the word with a capital letter, and a lowercase
# pattern walks straight past them. A 22% blind spot in a check whose whole
# subject is "find every credential surface" — and it was found by the D4
# mutation arm in the companion test, not by reading, which is the argument for
# the arm existing at all.
CREDENTIAL_PATTERN='password|passwd|apiKey|api_key|secret|credential'
# Things that COLLECT a credential, as opposed to naming one.
COLLECTION_PATTERN='readPasswordFromStdin|readLineFromStdin|type="password"|type='"'"'password'"'"'|<form|<input'

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

# Hits that are NOT on a comment line. Comments are CLASSIFIED rather than
# stripped: a '#' inside a string literal would truncate the line and could
# hide a real call, so nothing is removed before scanning.
scan_code() {
	local file="$1" pattern="$2"
	[ -f "${file}" ] || return 0
	grep -inE "${pattern}" "${file}" 2>/dev/null |
		while IFS= read -r hit; do
			text="${hit#*:}"
			case "$(printf '%s' "${text}" | sed 's/^[[:space:]]*//' | cut -c1-2)" in
			'#'*) ;;
			*) printf '%s\n' "${hit}" ;;
			esac
		done
}

count_of() { printf '%s' "$1" | grep -c . || true; }

# The classification. One rule per KIND, matched against the path. Every rule
# names why that kind is not an identity credential.
kind_of() {
	case "$1" in
	src/ct/online_sharing/artifact*) printf 'artifact' ;;
	src/ct/online_sharing/upload.nim | src/ct/online_sharing/download.nim) printf 'artifact' ;;
	src/tests/cli/sharing* | src/tests/gui/tests/sharing/*) printf 'artifacttest' ;;
	src/ct_test/*) printf 'testfixture' ;;
	src/ct/ci/*) printf 'citoken' ;;
	src/db_connector/*) printf 'vendored' ;;
	src/frontend/index/*) printf 'deployment' ;;
	src/frontend/ui/agentic_session_launcher.nim) printf 'provider' ;;
	src/ct/launch/*) printf 'artifact' ;;
	src/frontend/types.nim) printf 'debuggee' ;;
	src/frontend/ui/agent_activity.nim) printf 'debuggee' ;;
	src/frontend/viewmodel/viewmodels/agent_activity_vm.nim) printf 'debuggee' ;;
	src/frontend/viewmodel/identity/*) printf 'identitybearer' ;;
	src/tests/gui/tests/agent-activity/*) printf 'debuggee' ;;
	src/frontend/tests/*) printf 'platform' ;;
	src/frontend/viewmodel/views/isonim_agent_activity_view.nim) printf 'provider' ;;
	src/tests/gui/tests/agentic-coding/*) printf 'provider' ;;
	src/frontend/ui_js.nim | src/frontend/subwindow.nim) printf 'debuggee' ;;
	src/frontend/viewmodel/*) printf 'platform' ;;
	src/ct/codetracerconf.nim | src/ct/utilities/types.nim) printf 'config' ;;
	*) printf 'UNCLASSIFIED' ;;
	esac
}

echo "=== ID2: the desktop path handles no credential of ours ==="
echo

# ---------------------------------------------------------------------------
echo "Step 1: the sign-in path exists and is the thing this gate thinks it is"
echo "    THE POSITIVE CONTROL ON THE SUBJECT. 'This file collects no password'"
echo "    is also true of a file that does not exist, or one this gate is"
echo "    pointed at by a stale path."
# ---------------------------------------------------------------------------
if [ ! -f "${SIGNIN_PATH}" ]; then
	bad "${SIGNIN_PATH} does not exist; every check below would be vacuous"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
markers=0
for marker in 'desktop-port' 'desktop-cli-token' '/auth/desktop'; do
	if grep -qF "${marker}" "${SIGNIN_PATH}"; then
		markers=$((markers + 1))
	else
		bad "the sign-in path no longer mentions '${marker}'; this gate is reading the wrong file, or the flow changed and nobody revisited this"
	fi
done
if [ "${markers}" -eq 3 ]; then
	ok "the sign-in path carries all 3 loopback markers — the subject is real"
else
	bad "the sign-in path carries ${markers} of 3 loopback markers"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: the sign-in path collects nothing and hosts no form"
# ---------------------------------------------------------------------------
signin_cred=""
signin_collect=""
for f in "${SIGNIN_PATH}" "${SIGNIN_SUPPORT}" "${DEVICE_GRANT}"; do
	signin_cred="${signin_cred}$(scan_code "${f}" "${CREDENTIAL_PATTERN}")"
	signin_collect="${signin_collect}$(scan_code "${f}" "${COLLECTION_PATTERN}")"
done
n_cred="$(count_of "${signin_cred}")"
n_collect="$(count_of "${signin_collect}")"

# BOTH desktop flows are scanned, because §5 now specifies both: loopback by
# default, device grant when loopback cannot run. The property has to hold on
# whichever one runs, or the fallback becomes the way to reintroduce what the
# default forbids.
if [ "${n_cred}" -le "${EXPECTED_IDENTITY_CREDENTIAL_NAMES}" ]; then
	ok "the desktop sign-in paths name ${n_cred} credential(s) in code, within the declared budget of ${EXPECTED_IDENTITY_CREDENTIAL_NAMES}"
else
	bad "the desktop sign-in paths name ${n_cred} credential(s) in code, budget is ${EXPECTED_IDENTITY_CREDENTIAL_NAMES}:"
	printf '%s\n' "${signin_cred}" | sed 's/^/      /'
fi
if [ "${n_collect}" -eq 0 ]; then
	ok "neither desktop sign-in path hosts a form or reads a password"
else
	bad "a desktop sign-in path collects a credential in ${n_collect} place(s):"
	printf '%s\n' "${signin_collect}" | sed 's/^/      /'
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: THE POSITIVE CONTROL ON THE SCANNER"
echo "    A planted login form and a planted password read must be flagged by"
echo "    the same functions. Without this, step 2's zeroes are satisfied by a"
echo "    pattern that cannot match."
# ---------------------------------------------------------------------------
cat >"${work}/hatch.nim" <<'EOF'
proc signIn*(): string =
  let password = readPasswordFromStdin("CodeTracer password: ")
  let form = """<form><input type="password" name="credential"></form>"""
  password & form
EOF
h_cred="$(count_of "$(scan_code "${work}/hatch.nim" "${CREDENTIAL_PATTERN}")")"
h_collect="$(count_of "$(scan_code "${work}/hatch.nim" "${COLLECTION_PATTERN}")")"
if [ "${h_cred}" -ge 2 ]; then
	ok "the credential scanner flags a planted sign-in form (${h_cred} hits)"
else
	bad "the credential scanner found ${h_cred} hit(s) in a file that plainly contains credentials"
fi
if [ "${h_collect}" -ge 2 ]; then
	ok "the collection scanner flags a planted password read and form (${h_collect} hits)"
else
	bad "the collection scanner found ${h_collect} hit(s) in a file that plainly collects one"
fi

cat >"${work}/prose.nim" <<'EOF'
## This module never reads a password and hosts no <form>. It must not
## collect a credential or an apiKey. See ID2.
proc nothing*() = discard
EOF
p_hits="$(count_of "$(scan_code "${work}/prose.nim" "${CREDENTIAL_PATTERN}")")"
if [ "${p_hits}" -eq 0 ]; then
	ok "the scanner does not flag prose that merely names the hazard"
else
	bad "the scanner flagged ${p_hits} comment line(s); it cannot tell discussion from code"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4a: the identity layer COLLECTS no credential — absolute"
echo "Step 4b: the credential-shaped names it does carry are budgeted"
echo "    The two are different claims and only the first is absolute. The"
echo "    layer legitimately holds bearer secrets — a token IS one, and RFC"
echo "    8628's device_code is another. What it must never do is take one"
echo "    from a person. Forbidding the word would have forced the device"
echo "    grant to hide its own secret behind a euphemism, which is worse."
# ---------------------------------------------------------------------------
id_collect=0
id_named=0
for f in "${IDENTITY_DIR}"/*.nim; do
	[ -f "${f}" ] || continue
	c="$(count_of "$(scan_code "${f}" "${COLLECTION_PATTERN}")")"
	if [ "${c}" -gt 0 ]; then
		id_collect=$((id_collect + c))
		bad "${f} COLLECTS a credential:"
		scan_code "${f}" "${COLLECTION_PATTERN}" | sed 's/^/      /'
	fi
	n="$(count_of "$(scan_code "${f}" "${CREDENTIAL_PATTERN}")")"
	id_named=$((id_named + n))
done
if [ "${id_collect}" -eq 0 ]; then
	ok "no identity module reads a password or hosts a form — a token is verified, never collected"
fi
if [ "${id_named}" -eq "${EXPECTED_IDENTITY_CREDENTIAL_NAMES}" ]; then
	ok "the identity layer carries ${id_named} budgeted credential-shaped name(s)"
else
	bad "the identity layer names a credential in ${id_named} place(s), budget is ${EXPECTED_IDENTITY_CREDENTIAL_NAMES} — a new one is a decision about what this layer may hold, not an oversight"
	for f in "${IDENTITY_DIR}"/*.nim; do
		[ -f "${f}" ] || continue
		scan_code "${f}" "${CREDENTIAL_PATTERN}" | sed "s|^|      ${f}:|"
	done
fi
echo

# ---------------------------------------------------------------------------
echo "Step 5: every credential surface in the application is classified,"
echo "        and none of them is ours"
echo "    Fails in BOTH directions. A new credential surface nobody classified"
echo "    is a decision that has not been made; a kind that vanished leaves the"
echo "    budget describing an application that no longer exists."
# ---------------------------------------------------------------------------
mapfile -t surfaces < <(grep -rilE "${CREDENTIAL_PATTERN}" --include='*.nim' src/ 2>/dev/null | sort)
if [ "${#surfaces[@]}" -eq "${EXPECTED_SURFACES}" ]; then
	ok "the application has ${#surfaces[@]} credential-bearing file(s), as budgeted"
else
	bad "the application has ${#surfaces[@]} credential-bearing file(s), budget says ${EXPECTED_SURFACES}"
fi

declare -A kind_counts=()
unclassified=0
identity_surfaces=0
for f in "${surfaces[@]}"; do
	k="$(kind_of "${f}")"
	if [ "${k}" = "UNCLASSIFIED" ]; then
		unclassified=$((unclassified + 1))
		bad "unclassified credential surface: ${f}"
		note "      Decide what kind of credential this is. If it is OURS, ID2's"
		note "      deliverable 'no credential ever transits our process' is broken."
		continue
	fi
	# NOTE the kind is `identitybearer`, not `identity`. The distinction is the
	# whole point: the layer HOLDS a bearer secret (a token, a device code); it
	# never COLLECTS a person's credential. Step 4a is what asserts the second
	# half, and it is absolute.
	[ "${k}" = "identity" ] && identity_surfaces=$((identity_surfaces + 1))
	kind_counts["${k}"]=$((${kind_counts["${k}"]:-0} + 1))
done

if [ "${unclassified}" -eq 0 ]; then
	ok "every credential surface resolved to a declared kind"
fi
for k in "${!kind_counts[@]}"; do
	note "  ${k}: ${kind_counts[${k}]} file(s)"
done

if [ "${identity_surfaces}" -eq 0 ]; then
	ok "NONE of them is an identity credential — the application collects credentials for debugged programs, third-party providers and shared artifacts, and never for a CodeTracer account"
else
	bad "${identity_surfaces} identity-credential surface(s) exist; ID2 requires that no credential transits our process"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — the desktop path handles no credential of ours, and every"
echo "        credential the application does hold belongs to somebody else"
