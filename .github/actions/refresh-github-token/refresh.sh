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

# The job credential directory. Newer setup-nix keeps the Nix token out of the
# environment: NIX_CONFIG and nix.conf hold only an `!include` of
# $MCL_JOB_CREDENTIALS_DIR/nix-access-tokens.conf, whose `netrc-file` names the
# job netrc beside it, and a refresh is meant to rewrite those two files in
# place, after which every new `nix` process reads the new token
# (metacraft-github-actions refresh-build-auth/job-credentials.cjs, `rotate`).
# The NIX_CONFIG rewrite above cannot reach them, so TUI job 127569213481 still
# got "401 Bad credentials" after a refresh. Same edits as `rotate`: the
# github.com entry and a github.com/metacraft-labs prefix get the new token,
# every other host and machine is kept, and each file is replaced atomically.
cred_dir="${MCL_JOB_CREDENTIALS_DIR:-}"
if [ -n "$cred_dir" ] && [ -f "$cred_dir/nix-access-tokens.conf" ]; then
	tokens_file="$cred_dir/nix-access-tokens.conf"
	tmp="$(mktemp "$tokens_file.tmp.XXXXXXXX")"
	awk -v tok="$NEW_TOKEN" '
    /^[[:space:]]*access-tokens[[:space:]]*=/ {
      sub(/^[[:space:]]*access-tokens[[:space:]]*=[[:space:]]*/, "")
      n = split($0, entries, /[[:space:]]+/)
      out = ""; seen = 0
      for (i = 1; i <= n; i++) {
        if (entries[i] == "") continue
        eq = index(entries[i], "=")
        host = substr(entries[i], 1, eq - 1)
        if (host == "github.com") { seen = 1 }
        if (host == "github.com" || host == "github.com/metacraft-labs") {
          entries[i] = host "=" tok
        }
        out = out (out == "" ? "" : " ") entries[i]
      }
      if (!seen) out = "github.com=" tok (out == "" ? "" : " " out)
      print "access-tokens = " out
      next
    }
    { print }
  ' "$tokens_file" >"$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$tokens_file"
	echo "refreshed access-tokens in the job credential directory"
	job_netrc="$cred_dir/netrc"
	if [ -f "$job_netrc" ]; then
		tmp="$(mktemp "$job_netrc.tmp.XXXXXXXX")"
		{
			echo "machine github.com login x-access-token password $NEW_TOKEN"
			grep -Ev '^[[:space:]]*machine[[:space:]]+github\.com([[:space:]]|$)' "$job_netrc" | grep -v '^$' || true
		} >"$tmp"
		chmod 600 "$tmp"
		mv -f "$tmp" "$job_netrc"
		echo "refreshed github.com in the job netrc"
	fi
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
