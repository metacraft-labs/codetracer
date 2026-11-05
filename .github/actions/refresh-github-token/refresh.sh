#!/usr/bin/env bash
# Replace every stored copy of the job's GitHub token with $NEW_TOKEN.
# See action.yml for why. Each replacement is a no-op when that store is absent.
set -euo pipefail
: "${NEW_TOKEN:?NEW_TOKEN is required}"
echo "::add-mask::$NEW_TOKEN"
basic="$(printf 'x-access-token:%s' "$NEW_TOKEN" | base64 | tr -d '\n')"
echo "::add-mask::$basic"

# nix.conf: Nix's own github: fetchers.
conf="$HOME/.config/nix/nix.conf"
if [ -f "$conf" ] && grep -q '^ *access-tokens *=' "$conf"; then
	sed -i "s|^\( *access-tokens *= *\).*|\1github.com=$NEW_TOKEN|" "$conf"
	echo "refreshed access-tokens in $conf"
fi

# NIX_CONFIG: setup-nix also exports the job's Nix settings, access-tokens
# included, through GITHUB_ENV, and Nix applies NIX_CONFIG after nix.conf, so
# a stale token there wins over the one refreshed above. TUI job 127318265290
# failed that way: `nix develop` 80 minutes into the job got "401 Bad
# credentials" fetching a github: flake input. The new value goes back through
# GITHUB_ENV, with a random heredoc delimiter because the value is multiline
# (https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#multiline-strings).
if [ -n "${NIX_CONFIG:-}" ] && [ -n "${GITHUB_ENV:-}" ] &&
	grep -q '^ *access-tokens *=' <<<"$NIX_CONFIG"; then
	# A per-line anchored match, the same as nix.conf's above; ${var//}
	# cannot anchor to the start of a line inside a multiline value.
	# shellcheck disable=SC2001
	new_nix_config="$(sed"s|^\( *access-tokens *= *\).*|\1github.com=$NEW_TOKEN|" <<<"$NIX_CONFIG")"
	delimiter="NIX_CONFIG_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
	{
		echo "NIX_CONFIG<<$delimiter"
		printf '%s\n' "$new_nix_config"
		echo "$delimiter"
	} >>"$GITHUB_ENV"
	echo "refreshed access-tokens in NIX_CONFIG for later steps"
fi

# The Nix netrc: git+https inputs, which Nix fetches by running git.
netrc="$HOME/.config/nix/netrc"
if [ -f "$netrc" ] && grep -q 'machine github.com' "$netrc"; then
	tmp="$(mktemp)"
	awk -v tok="$NEW_TOKEN" '
    $1 == "machine" && $2 == "github.com" { print "machine github.com login x-access-token password " tok; skip = 1; next }
    $1 == "machine" { skip = 0 }
    skip && ($1 == "login" || $1 == "password") { next }
    { print }
  ' "$netrc" >"$tmp"
	cat "$tmp" >"$netrc"
	rm -f "$tmp"
	echo "refreshed github.com in $netrc"
fi

# The git extraHeader setup-dev-env exports for the rest of the job.
for i in $(seq 0 $((${GIT_CONFIG_COUNT:-0} - 1))); do
	key_var="GIT_CONFIG_KEY_$i"
	case "${!key_var:-}" in
	http.https://github.com/*.extraHeader | http.https://github.com/*.extraheader)
		echo "GIT_CONFIG_VALUE_$i=AUTHORIZATION: basic $basic" >>"$GITHUB_ENV"
		echo "refreshed ${!key_var} for later steps"
		;;
	esac
done

# The credential actions/checkout persisted in the checkout.
if git -C "$GITHUB_WORKSPACE" config --local --get-all http.https://github.com/.extraheader >/dev/null 2>&1; then
	git -C "$GITHUB_WORKSPACE" config --local --replace-all http.https://github.com/.extraheader "AUTHORIZATION: basic $basic"
	echo "refreshed the checkout's persisted credential"
fi
