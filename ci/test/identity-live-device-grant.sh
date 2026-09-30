#!/usr/bin/env bash
#
# identity-live-device-grant.sh — WD3's verification, run end to end:
# "against the local Zitadel, a device-grant round trip yields an ID token that
# this code's discovery, JWKS, signature and claim checks all accept".
#
# WHAT THIS GATE IS FOR
# ---------------------
# CodeTracer's identity layer (`src/ct/identity/`) was written, compiled and
# unit-tested while NO RUNNING ISSUER HAD EVER ACCEPTED A TOKEN IT VERIFIED.
# `oidc_test.nim` drives it against a fake transport and is worth having, but a
# fake transport cannot be wrong in the way a real issuer is: it agrees with
# whatever the code expects. The seam is named in
# `metacraft-specs/infrastructure/local-development-parity.md` §4.1, and the
# only thing that closes it is a real connection to a real issuer.
#
# So this drives TWO real processes against one running Zitadel:
#
#   1. `ci/test/identity_live_device_grant_probe.nim` — the product's own
#      modules, compiled for the native backend, performing RFC 8628's
#      device-authorization request and poll loop over TLS, and then putting
#      the ID token through `parseJwt` → `parseJwks` → `selectKey` →
#      `newWebCryptoVerifier` → `checkClaims` in the product's own order.
#   2. `ci/test/identity-device-approve.mjs` — a real headless Chromium that
#      signs in on the ISSUER'S OWN hosted login and presses Allow on the
#      device-authorization consent page.
#
# The two meet only at the issuer, which is the point of the device flow: the
# password is typed into a browser the CLI has no handle on, and the CLI learns
# only that a token came back. Approving the grant through the issuer's session
# API instead would close the loop through a door users do not have.
#
# WHY IT SKIPS RATHER THAN FAILS, AND WHY LOUDLY
# ----------------------------------------------
# It needs a running stack that no CI job provisions. A gate that cannot run
# must SAY SO — exit 2 with a named remedy — because the failure mode this
# whole file guards against is a green that means nothing. Every skip below
# names the one thing to do. It never exits 0 without having watched a token
# come back.
#
# WHAT IS NOT MOCKED: all of it. Real TLS against a certificate the probe
# verifies against the dev CA (there is deliberately no flag that turns
# verification off), a real browser that verifies the same chain, a real
# password check, a real consent click, a real RS256 signature over a real
# JWKS.
#
# Usage:  bash ci/test/identity-live-device-grant.sh
# Env:
#   CT_ISONIM_PLATFORM      the isonim-platform checkout that runs the stack
#                           (default: the sibling ../isonim-platform)
#   CT_IDENTITY_ISSUER      issuer URL (default https://login.metacraft-labs.test:8443)
#   CT_IDENTITY_CLIENT_ID   override the CLI relying party's client id. Exists
#                           for the negative control that points the probe at
#                           an unregistered client and expects red.
#   CT_DEVICE_ACTION        allow (default) | deny | none — what the browser
#                           does at the consent page. `deny`/`none` are the
#                           negative controls: the run MUST go red.
#   CT_DEVICE_GRANT_TIMEOUT seconds to wait for the probe after the browser has
#                           decided (default 180). A bound, not a guess: the
#                           device code lives ~15 minutes and a hung harness is
#                           indistinguishable from a slow one.
#   CT_CHROMIUM             Chromium binary (default: found under
#                           PLAYWRIGHT_BROWSERS_PATH)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

PROBE_SRC="ci/test/identity_live_device_grant_probe.nim"
APPROVE_MJS="ci/test/identity-device-approve.mjs"

platform="${CT_ISONIM_PLATFORM:-$(cd "${repo_root}/.." 2>/dev/null && pwd)/isonim-platform}"
issuer="${CT_IDENTITY_ISSUER:-https://login.metacraft-labs.test:8443}"
action="${CT_DEVICE_ACTION:-allow}"
grant_timeout="${CT_DEVICE_GRANT_TIMEOUT:-180}"

issuer_hostport="${issuer#https://}"
issuer_host="${issuer_hostport%%:*}"
issuer_port="${issuer_hostport##*:}"
[ "${issuer_port}" = "${issuer_host}" ] && issuer_port=443

checks=0
failures=0
ok() {
	checks=$((checks + 1))
	printf '  [OK]      %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED]  %s\n' "$*"
}
note() { printf '            %s\n' "$*"; }

# A skip is a sentence and a remedy. Exit 2, never 0: see the header.
skip() {
	printf '\n  LOUD SKIP (exit 2, NOT a pass): %s\n' "$1" >&2
	printf '  remedy: %s\n' "$2" >&2
	exit 2
}

work="$(mktemp -d)"
probe_pid=""
cleanup() {
	if [ -n "${probe_pid}" ] && kill -0 "${probe_pid}" 2>/dev/null; then
		kill "${probe_pid}" 2>/dev/null || true
		wait "${probe_pid}" 2>/dev/null || true
	fi
	rm -rf "${work}"
}
trap cleanup EXIT INT TERM

echo "=== WD3: a running issuer accepts a token this code verifies ==="
echo "  issuer:   ${issuer}"
echo "  platform: ${platform}"
echo "  action:   ${action}"
echo

# ---------------------------------------------------------------------------
# Preconditions. Each one is a separate skip with its own remedy, because
# "something was missing" is not actionable and this gate has six moving parts.
# ---------------------------------------------------------------------------
command -v nim >/dev/null 2>&1 ||
	skip "nim is not on PATH" "run inside the dev shell: nix develop"
command -v node >/dev/null 2>&1 ||
	skip "node is not on PATH" "run inside the dev shell: nix develop"
command -v curl >/dev/null 2>&1 ||
	skip "curl is not on PATH" "run inside the dev shell: nix develop"
command -v unshare >/dev/null 2>&1 ||
	skip "unshare is not on PATH" \
		"this gate needs unprivileged user+mount namespaces (util-linux); it is Linux-only"

[ -f "${PROBE_SRC}" ] || skip "${PROBE_SRC} is missing" "this gate has no subject"
[ -f "${APPROVE_MJS}" ] || skip "${APPROVE_MJS} is missing" "this gate has no browser leg"

[ -d "${platform}" ] ||
	skip "no isonim-platform checkout at ${platform}" \
		"repro ws enable isonim, or set CT_ISONIM_PLATFORM=<path>"

ca_file="${platform}/local-dev/state/ca/isonim-dev-ca.crt"
client_id_file="${platform}/local-dev/state/idp/cli-client-id"
rp_env="${platform}/local-dev/state/idp/relying-party.env"

[ -f "${ca_file}" ] ||
	skip "the dev CA is absent (${ca_file})" \
		"cd ${platform} && just dev-up   (it generates the CA on first start)"
[ -f "${client_id_file}" ] ||
	skip "the CLI relying party is not registered (${client_id_file})" \
		"cd ${platform} && just dev-up   (isonim-dev-idp's ensure_cli_app registers it)"
[ -f "${rp_env}" ] ||
	skip "no fixture credentials (${rp_env})" \
		"cd ${platform} && just dev-up   (isonim-dev-idp writes the fixture user there)"

client_id="${CT_IDENTITY_CLIENT_ID:-$(tr -d '[:space:]' <"${client_id_file}")}"
[ -n "${client_id}" ] || skip "the client id is empty" "re-run the stack's IdP provisioning"

# The fixture user, read from the stack's own state rather than hardcoded —
# a credential written into this file would be a credential that drifts.
login_user="$(sed -n 's/^ISONIM_DEV_IDP_TEST_USER="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${rp_env}" | head -1)"
login_password="$(sed -n 's/^ISONIM_DEV_IDP_TEST_PASSWORD="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${rp_env}" | head -1)"
[ -n "${login_user}" ] && [ -n "${login_password}" ] ||
	skip "could not read the fixture user out of ${rp_env}" \
		"cd ${platform} && just dev-up   (or check that file's ISONIM_DEV_IDP_TEST_* lines)"

# IS THE ISSUER ACTUALLY UP. This is what separates "the stack is down" (skip)
# from "the client id is wrong" (fail) — without it, the negative control below
# would be indistinguishable from an absent stack, and a control that can be
# mistaken for a skip is not a control.
if ! curl -fsS --max-time 10 --cacert "${ca_file}" \
	--resolve "${issuer_host}:${issuer_port}:127.0.0.1" \
	"${issuer}/.well-known/openid-configuration" >"${work}/discovery.json" 2>"${work}/discovery.err"; then
	skip "the issuer at ${issuer} did not serve its discovery document" \
		"cd ${platform} && just dev-up   ($(head -1 "${work}/discovery.err" 2>/dev/null))"
fi

# Chromium and playwright. Found the way ci/test/constraints-listing-browser.sh
# finds them; the two `find` calls are its (macOS bundle, plain binary).
chromium="${CT_CHROMIUM:-}"
if [ -z "${chromium}" ]; then
	chromium="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
		-path '*/Chromium.app/Contents/MacOS/Chromium' -type f 2>/dev/null | head -1)"
	[ -n "${chromium}" ] || chromium="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
		-name 'chrome' -type f 2>/dev/null | head -1)"
fi
[ -n "${chromium}" ] && [ -x "${chromium}" ] ||
	skip "no Chromium found" \
		"run inside the dev shell (it sets PLAYWRIGHT_BROWSERS_PATH), or set CT_CHROMIUM"

playwright_main="$(node -e 'console.log(require.resolve("playwright"))' 2>/dev/null || true)"
[ -n "${playwright_main}" ] && [ -f "${playwright_main}" ] ||
	skip "playwright is not resolvable from node" "run inside the dev shell: nix develop"

# HOW THE BROWSER COMES TO TRUST THE DEV CA — and it is not by being told to
# overlook the certificate. Two routes, in order of preference:
#
#   1. A throwaway NSS database, exactly as isonim-platform's own browser test
#      builds one. Chromium reads $HOME/.pki/nssdb, so nothing about
#      verification is special-cased: the chain is checked normally.
#   2. Failing that (`certutil` ships in nssTools, which this repo's dev shell
#      does not carry), pin the CA's SPKI hash. Chromium still builds and
#      checks the chain; the flag adds exactly one public key to what it will
#      accept. `--ignore-certificate-errors`, which accepts ANY chain, is not
#      used and must not be substituted — it would make the TLS half of this
#      test vacuous.
ca_spki=""
profile=""
if command -v certutil >/dev/null 2>&1; then
	profile="${work}/browser-profile"
	mkdir -p "${profile}/.pki/nssdb"
	certutil -N -d "sql:${profile}/.pki/nssdb" --empty-password >/dev/null 2>&1 || true
	if certutil -d "sql:${profile}/.pki/nssdb" -A -t "C,," -n "isonim-dev-ca" \
		-i "${ca_file}" >/dev/null 2>&1; then
		note "the dev CA is in a throwaway NSS database at ${profile}"
	else
		profile=""
	fi
fi
if [ -z "${profile}" ]; then
	command -v openssl >/dev/null 2>&1 ||
		skip "neither certutil nor openssl is available" \
			"run inside the dev shell: nix develop"
	ca_spki="$(openssl x509 -in "${ca_file}" -pubkey -noout |
		openssl pkey -pubin -outform der |
		openssl dgst -sha256 -binary | openssl enc -base64)"
	[ -n "${ca_spki}" ] ||
		skip "could not compute the dev CA's SPKI hash" "check that ${ca_file} is a PEM certificate"
	note "no certutil; pinning the dev CA's SPKI (${ca_spki})"
fi

# ---------------------------------------------------------------------------
echo "Step 1: build the probe — the product's own identity modules, natively"
# ---------------------------------------------------------------------------
cache="$(ct_nim_cache_root "${repo_root}")/identity-live-device-grant"
mkdir -p "${cache}"
# NEVER TRUST AN EXIT CODE ALONE: the output is named and then tested for.
nim c -d:ssl --hints:off --warnings:off \
	--nimcache:"${cache}/nimcache" -o:"${cache}/probe" \
	"${PROBE_SRC}" >"${work}/build.log" 2>&1
if [ ! -x "${cache}/probe" ]; then
	bad "the probe did not build"
	tail -25 "${work}/build.log" | sed 's/^/            /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED — the subject does not compile"
	exit 1
fi
ok "the probe built ($(wc -c <"${cache}/probe" | tr -d ' ') bytes)"

# ---------------------------------------------------------------------------
echo
echo "Step 2: start the probe — it asks the issuer for a device code and polls"
# ---------------------------------------------------------------------------
# NAME RESOLUTION, WITHOUT ROOT AND WITHOUT TOUCHING THE MACHINE. The dev hosts
# are not in /etc/hosts, and on a Nix-managed host /etc/hosts is a read-only
# store symlink. So the probe runs in an unprivileged user+mount namespace with
# its own hosts file.
#
# THE /run/nscd BIND IS NOT OPTIONAL where a name-service cache daemon is
# running: glibc prefers the nscd/nsncd socket over /etc/hosts, that socket
# lives OUTSIDE the namespace, and the override is then silently ignored —
# a failure that looks like "the issuer is unreachable". Masking the directory
# with an empty one makes glibc fall back to the files it can see.
printf '127.0.0.1 localhost\n127.0.0.1 %s\n::1 localhost\n' "${issuer_host}" >"${work}/hosts"
mkdir -p "${work}/empty"
nscd_mask=""
[ -d /run/nscd ] && nscd_mask="mount --bind '${work}/empty' /run/nscd;"

unshare -rm bash -c "
	mount --bind '${work}/hosts' /etc/hosts || exit 70
	${nscd_mask}
	exec '${cache}/probe' --issuer='${issuer}' --client-id='${client_id}' --ca-file='${ca_file}'
" >"${work}/probe.out" 2>&1 &
probe_pid=$!

# Wait for the DEVICE line. A bound rather than a poll-forever: if the device
# authorization request is refused — which is what the unregistered-client
# control does — the probe exits 1 within a second and this loop must notice
# the dead process rather than sit out the whole timeout.
device_line=""
for _ in $(seq 1 60); do
	device_line="$(grep -m1 '^DEVICE ' "${work}/probe.out" 2>/dev/null || true)"
	[ -n "${device_line}" ] && break
	kill -0 "${probe_pid}" 2>/dev/null || break
	sleep 1
done

if [ -z "${device_line}" ]; then
	bad "the probe never printed a DEVICE line — the issuer did not start a device authorization"
	sed 's/^/            /' "${work}/probe.out"
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED — no device authorization to approve"
	exit 1
fi
ok "the issuer started a device authorization"

# Parsed with a JSON parser, not a regex: the URI carries a query string with
# its own `&` and `=` and a sed expression over it is a latent defect.
approve_url="$(printf '%s' "${device_line#DEVICE }" |
	node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(j.verification_uri_complete||"")})')"
user_code="$(printf '%s' "${device_line#DEVICE }" |
	node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(j.user_code||"")})')"
if [ -n "${approve_url}" ]; then
	ok "it published a verification URI a person can open (user code ${user_code})"
else
	bad "the DEVICE line carried no verification_uri_complete"
	note "${device_line}"
fi

# The device code is NOT in the probe's output — it is the bearer secret, and
# the probe deliberately withholds it. Asserted, because a future edit that
# "helpfully" printed it would hand the session to anything reading a CI log.
if grep -q 'device_code' "${work}/probe.out"; then
	bad "the probe printed a device_code — that is the bearer secret for this grant"
else
	ok "the probe withheld the device code from its output"
fi

# ---------------------------------------------------------------------------
echo
echo "Step 3: a real browser signs in and decides (${action})"
# ---------------------------------------------------------------------------
# The catch-all NOTFOUND rule is deliberate: it proves the browser reached
# nothing but loopback for the whole run.
#
# Exported rather than written as a `VAR=... node` prefix: CT_CA_SPKI is
# base64 and CT_PROFILE is a path, and an unquoted `${x:+VAR=$x}` prefix is the
# classic way such a value acquires a splitting bug that only bites on some
# hosts. The subshell keeps the exports out of the rest of the run.
(
	export CT_PLAYWRIGHT="${playwright_main}"
	export CT_CHROMIUM="${chromium}"
	export CT_RESOLVER_RULES="MAP ${issuer_host} 127.0.0.1,MAP * ~NOTFOUND"
	export CT_APPROVE_URL="${approve_url}"
	export CT_LOGIN_USER="${login_user}"
	export CT_LOGIN_PASSWORD="${login_password}"
	export CT_DEVICE_ACTION="${action}"
	[ -n "${profile}" ] && export CT_PROFILE="${profile}"
	[ -n "${ca_spki}" ] && export CT_CA_SPKI="${ca_spki}"
	node "${APPROVE_MJS}" 2>&1
) | sed 's/^/      /'
browser_rc="${PIPESTATUS[0]}"
if [ "${browser_rc}" = "0" ]; then
	ok "the browser leg completed (exit 0)"
else
	bad "the browser leg failed (exit ${browser_rc}) — see its own output above"
fi

# ---------------------------------------------------------------------------
echo
echo "Step 4: the probe's verdict on what the issuer gave it"
# ---------------------------------------------------------------------------
waited=0
while kill -0 "${probe_pid}" 2>/dev/null; do
	if [ "${waited}" -ge "${grant_timeout}" ]; then
		bad "the probe was still polling after ${grant_timeout}s — no grant ever arrived"
		note "this is the expected shape of the 'approve nothing' control"
		kill "${probe_pid}" 2>/dev/null || true
		break
	fi
	sleep 2
	waited=$((waited + 2))
done
wait "${probe_pid}" 2>/dev/null
probe_rc=$?
probe_pid=""

sed 's/^/      /' "${work}/probe.out"
echo

# THREE SEPARATE ASSERTIONS over one run, and they are separate on purpose.
# A probe that died before finishing is a different state from one that
# reported a failure, and neither may be read as the other; and an exit 0 with
# no SUBJECT would mean the verification chain was skipped rather than passed.
if [ "${probe_rc}" = "0" ]; then
	ok "the probe exited 0"
else
	bad "the probe exited ${probe_rc}"
fi

if grep -q '^PASSED ' "${work}/probe.out"; then
	ok "the probe printed PASSED — a running issuer accepted a token this code verified"
else
	bad "the probe printed no PASSED line"
	grep -m1 '^FAILED ' "${work}/probe.out" | sed 's/^/            /'
fi

subject="$(sed -n 's/^SUBJECT //p' "${work}/probe.out" | head -1)"
if [ -n "${subject}" ]; then
	ok "the verified token names a subject (${subject})"
else
	bad "the probe printed no non-empty SUBJECT — the claim check did not complete"
fi

# The chain, step by step. Named individually because "PASSED" is one line that
# hides five checks, and a future edit that short-circuits one of them would
# still print it.
for step in \
	"OK discovery bound to:discovery reached the real issuer" \
	"OK an id_token was issued:the issuer issued an id_token" \
	"OK the issuer published:the JWKS came from the issuer's own jwks_uri" \
	"OK the id_token parses:the token parsed" \
	"OK the signing key is one the issuer publishes:the kid matched a published key" \
	"OK the RS256 signature verifies:the RS256 signature verified against that key" \
	"OK the claims check out:the claims verified against issuer and audience"; do
	pat="${step%%:*}"
	label="${step#*:}"
	if grep -qF "${pat}" "${work}/probe.out"; then
		ok "${label}"
	else
		bad "${label} — no \"${pat}\" line"
	fi
done

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — a real device-grant round trip against a real issuer, verified by the shipped code"
