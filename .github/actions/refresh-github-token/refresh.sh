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
