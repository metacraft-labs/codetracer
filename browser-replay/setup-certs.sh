#!/usr/bin/env bash
# Generate self-signed TLS certificates for local development.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/certs"

mkdir -p "$CERT_DIR"

CRT="$CERT_DIR/server.crt"
KEY="$CERT_DIR/server.key"

# The certificate this script issues, stated once so the guard below and the
# `openssl req` invocation cannot drift apart.
DAYS=365
SUBJECT="/CN=localhost"
SAN="subjectAltName=DNS:localhost,IP:127.0.0.1"
# Re-issue a week before expiry rather than on the day: a certificate that dies
# mid-session fails as a browser handshake error in a replay run, which is one
# of the least legible ways this could possibly surface.
RENEW_WINDOW_SECONDS=$((7 * 24 * 60 * 60))

# EXISTENCE IS NOT VALIDITY.
#
# This used to be `[ -f server.crt ] && [ -f server.key ]` -> "Certificates
# already exist" -> exit 0. A certificate is issued for exactly $DAYS days and
# for exactly one SAN set, so presence answers neither of the two questions that
# decide whether it works: is it still in date, and does it still cover the
# names the replay server is reached by? Both change without the files moving --
# the first by the calendar alone, the second whenever this script's SAN list is
# edited, which leaves every machine that ran the old version serving a
# certificate for names it no longer claims to issue.
#
# So the guard asks the properties instead, and each answer names itself: a
# reader who sees "regenerating" should be told which of the four it was.
reason=""
if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
	reason="no certificate or key in $CERT_DIR"
elif ! openssl x509 -in "$CRT" -noout -checkend "$RENEW_WINDOW_SECONDS" >/dev/null 2>&1; then
	reason="the certificate has expired or expires within $((RENEW_WINDOW_SECONDS / 86400)) days (not-after: $(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2-))"
else
	# `openssl x509 -ext` prints the SAN as `DNS:localhost, IP Address:127.0.0.1`
	# -- a different spelling from the `openssl req -addext` input above. Compare
	# the NAMES, not the formatting: whitespace out, `IP Address:` normalised to
	# the `IP:` spelling this script issues with, entries sorted so order is not
	# a difference.
	normalise_san() {
		tr -d ' \t' | tr ',' '\n' |
			sed -e 's/^IPAddress:/IP:/' -e '/^$/d' |
			LC_ALL=C sort | paste -sd, -
	}
	have_san="$(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null |
		grep -E '(DNS|IP)' | normalise_san || true)"
	want_san="$(printf '%s\n' "${SAN#subjectAltName=}" | normalise_san)"
	if [ "$have_san" != "$want_san" ]; then
		reason="the certificate covers '$have_san' but this server is reached at '$want_san'"
	# A key that does not belong to the certificate is the third way this pair
	# can be present and unusable, and it is what a half-finished run of THIS
	# script leaves behind: `openssl req` writes the key first.
	elif [ "$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "$KEY" -pubout 2>/dev/null)" ]; then
		reason="the private key does not match the certificate"
	fi
fi

if [ -z "$reason" ]; then
	echo "Certificates in $CERT_DIR are current (not-after: $(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2-))"
	exit 0
fi

echo "Generating self-signed TLS certificate: $reason"
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$KEY" \
	-out "$CRT" \
	-days "$DAYS" \
	-subj "$SUBJECT" \
	-addext "$SAN"

echo "Certificate generated:"
echo "  $CRT"
echo "  $KEY"
