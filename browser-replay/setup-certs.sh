#!/usr/bin/env bash
# Verify the TLS material this replay server serves with. It does NOT issue it.
#
# The certificate comes from the org's development certificate set, installed by
# `infra`'s `services/dev-certificates` module at the location
# `metacraft-dev-guidelines/policies/environment-domains-and-dev-certificates.md`
# §5 fixes:
#
#   /etc/mcl-dev-certs/codetracer.localhost/{fullchain.pem,key.pem}
#
# ## Why this script no longer generates anything
#
# It used to mint its own self-signed `CN=localhost` leaf. §5 names that as a
# failure mode rather than a convenience: a project's dev environment "must not
# carry its own copy, generate its own CA, or accept a path from the environment
# — three failure modes that each end with two roots in play and a confusing
# trust error." With the org root installed and trusted machine-wide, a
# second self-signed leaf meant every browser and every `curl` had to be told
# about it separately, which is the cost that clause exists to remove.
#
# It also means the server is now reached at a NAME under the org's scheme
# (`replay.codetracer.localhost`) rather than at bare `localhost`. That name
# resolves to loopback with no `/etc/hosts` entry — RFC 6761 §6.3 reserves
# `localhost` and resolvers answer any name under it — so nothing has to be
# provisioned for it, and the certificate that covers it is already trusted.
#
# ## What it still checks, and why that is the same list as before
#
# EXISTENCE IS NOT VALIDITY. The previous version of this script made that point
# at length and it survives the migration unchanged in spirit: presence answers
# neither "is it still in date" nor "does it cover the name this server is
# reached by". Both can change without the files moving — the first by the
# calendar, the second when the domain set in `infra:lib/dev-certificates.nix`
# is re-minted with a different name list.
#
# What changed is the SAN test. The old leaf was issued for exactly one SAN set,
# so an equality comparison was right. The org leaf carries an apex AND a
# wildcard (`codetracer.localhost`, `*.codetracer.localhost`), so the question is
# COVERAGE, not equality — and a wildcard matches exactly one label, which is the
# part that is easy to get wrong.
# The remedy lines below quote command names and option names in backticks, the
# way the rest of this repo's operator-facing messages do. SC2016 reads a
# backtick inside single quotes as an expansion someone forgot to enable; here the
# single quotes are exactly right, because none of these strings should expand.
# shellcheck disable=SC2016
set -euo pipefail

# §5's known location. NOT configurable: a path that can be overridden is a path
# that can be pointed at a second root, which is the third failure mode above.
MCL_DEV_CERTS=/etc/mcl-dev-certs
SERVER_NAME=replay.codetracer.localhost
LEAF_DIR="$MCL_DEV_CERTS/codetracer.localhost"
CRT="$LEAF_DIR/fullchain.pem"
KEY="$LEAF_DIR/key.pem"
ROOT_CA="$MCL_DEV_CERTS/root-ca.crt"

# Where the pre-migration script wrote its own certificate. Checked for below so
# a leftover private key is reported rather than left to be rediscovered.
SCRIPT_DIR_STALE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs"

# Re-mint a week before expiry rather than on the day: a certificate that dies
# mid-session fails as a browser handshake error in a replay run, which is one of
# the least legible ways this could possibly surface.
RENEW_WINDOW_SECONDS=$((7 * 24 * 60 * 60))

die() {
	printf 'browser-replay: %s\n' "$1" >&2
	shift
	for line in "$@"; do printf '  %s\n' "$line" >&2; done
	exit 1
}

# ---------------------------------------------------------------------------
# Is the development certificate set installed at all?
# ---------------------------------------------------------------------------
if [ ! -d "$MCL_DEV_CERTS" ]; then
	die "$MCL_DEV_CERTS does not exist, so the org development certificates are not installed on this machine." \
		"Enable the module for this host:" \
		"  - a machine in metacraft-labs/infra: imports += services/dev-certificates, mcl.devCertificates.enable = true" \
		"  - your own machine via ~/dotfiles:   see services/dev-certificates/README.md" \
		'Then re-deploy and run `mcl-dev-certs-health`.'
fi

[ -r "$ROOT_CA" ] || die "$ROOT_CA is missing, so the development root CA is not installed." \
	"The certificate directory exists but the root does not, which is a partial install rather than an absent one."

[ -r "$CRT" ] || die "$CRT is missing." \
	'`codetracer.localhost` is a declared row of infra:lib/dev-certificates.nix, so this is' \
	"either a host without the module or a domain set that was never minted." \
	'Run `mcl-dev-certs-health`, which says which.'

# THE TWO FAILURES THAT LOOK IDENTICAL. A readable certificate with an
# unreadable key is not a missing install: it means this machine is not an agenix
# recipient of the leaf key, or is not in the group the key is readable by. §4
# calls this out as the price of sealing leaf keys, and a service cannot tell the
# difference, so this says which it is.
if [ ! -r "$KEY" ]; then
	if [ -e "$KEY" ]; then
		die "$KEY exists but is not readable by $(id -un)." \
			'It is mode 0440 and owned by root with a group (`users` on NixOS, `staff` on darwin).' \
			"You are in: $(id -nG)" \
			"Add yourself to that group, or set mcl.devCertificates.keyGroup for this host."
	fi
	die "$KEY is absent while $CRT is present." \
		"That is NOT a missing module: this machine is not an agenix recipient of the leaf key." \
		'Add its hostname to `consumerHosts` in infra:lib/dev-certificates.nix and reseal:' \
		"  just reseal-dev-cert-keys ~/.ssh/<your-super-admins-key>"
fi

# ---------------------------------------------------------------------------
# In date?
# ---------------------------------------------------------------------------
if ! openssl x509 -in "$CRT" -noout -checkend "$RENEW_WINDOW_SECONDS" >/dev/null 2>&1; then
	die "the certificate has expired or expires within $((RENEW_WINDOW_SECONDS / 86400)) days (not-after: $(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2-))." \
		"These leaves are 90-day certificates with no renewal daemon, by design." \
		'A superadmin re-mints them: `just mint-dev-certs ~/.ssh/<key>` in infra.'
fi

# ---------------------------------------------------------------------------
# Does it cover the name this server is reached by?
# ---------------------------------------------------------------------------
# A WILDCARD MATCHES EXACTLY ONE LABEL. `*.codetracer.localhost` covers
# `replay.codetracer.localhost` and does NOT cover `a.b.codetracer.localhost`
# nor the apex. Getting that wrong is the classic way a local TLS setup
# half-works, so the match is spelled out rather than approximated with a glob.
covers_name() {
	local want="$1" san entry suffix
	san="$(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null |
		tr -d ' \t' | tr ',' '\n' | sed -n 's/^DNS://p')"
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		if [ "$entry" = "$want" ]; then return 0; fi
		case "$entry" in
		'*.'*)
			suffix="${entry#\*.}"
			# One label: strip the first label from `want` and the remainder must
			# equal the wildcard's suffix exactly. `a.b.suffix` fails here, which
			# is the point.
			[ "${want#*.}" = "$suffix" ] && [ "${want%%.*}" != "$want" ] && return 0
			;;
		esac
	done <<<"$san"
	return 1
}

if ! covers_name "$SERVER_NAME"; then
	die "the certificate does not cover '$SERVER_NAME'." \
		"It carries: $(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | tr -d ' \t' | tr '\n' ' ')" \
		"Either this script's SERVER_NAME drifted, or the declared name list in" \
		"infra:lib/dev-certificates.nix changed and the leaf was re-minted without it."
fi

# A key that does not belong to the certificate is the way this pair can be
# present, in date, correctly named and still unusable.
if [ "$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "$KEY" -pubout 2>/dev/null)" ]; then
	die "the private key at $KEY does not belong to the certificate at $CRT." \
		"Both come from the same agenix-managed directory, so this means a partial activation."
fi

# STALE MATERIAL FROM THE OLD SCRIPT. Anyone who ran a previous version has a
# self-signed leaf AND ITS PRIVATE KEY under ./certs/. Nothing reads it any more,
# and leaving it is how "two roots in play" starts: a developer debugging a trust
# error finds a plausible-looking cert there and points something at it.
#
# It is only a warning, not a failure: the directory is gitignored (deliberately
# kept so that an old key cannot be committed by accident), it harms nothing where
# it sits, and refusing to start over it would block a working setup.
if [ -e "$SCRIPT_DIR_STALE/server.key" ] || [ -e "$SCRIPT_DIR_STALE/server.crt" ]; then
	echo "browser-replay: NOTE $SCRIPT_DIR_STALE still holds the self-signed certificate this" >&2
	echo "  script used to generate, including its PRIVATE KEY. Nothing reads it now." >&2
	echo "  Delete it:  rm -rf $SCRIPT_DIR_STALE" >&2
fi

echo "browser-replay: TLS material OK — $SERVER_NAME, from $LEAF_DIR"
echo "  not-after: $(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2-)"
echo "  root CA:   $ROOT_CA (trusted machine-wide; no per-tool --cacert needed)"
