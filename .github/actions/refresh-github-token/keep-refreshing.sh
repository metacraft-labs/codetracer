#!/usr/bin/env bash
# Re-mint the GitHub App installation token every 40 minutes for the rest of
# the job, and write each new one into nix.conf and the Nix netrc (refresh.sh
# without GITHUB_ENV, which a running step cannot see anyway).
#
# A single step can outlast a token: the AppImage build alone runs for more
# than an hour on a fresh runner, and the 26.10.1 dry run (36832102898) failed
# 61 minutes into it, when nix fetched a flake input with a token minted just
# before the step. Nix rereads its configuration and netrc on every
# invocation, so rewriting the files is enough for every later fetch.
#
# Needs APP_ID and APP_PRIVATE_KEY in the environment, and openssl, curl and
# jq on PATH. Runs until the job ends; the runner kills it then.
set -uo pipefail
: "${APP_ID:?}" "${APP_PRIVATE_KEY:?}"
here="$(cd "$(dirname "$0")" && pwd)"
owner="${OWNER:-metacraft-labs}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint() {
  local now header payload signature jwt installation token
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  signature="$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign <(printf '%s\n' "$APP_PRIVATE_KEY") | b64url)" || return 1
  jwt="$header.$payload.$signature"
  installation="$(curl -fsS -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/orgs/$owner/installation" | jq -r .id)" || return 1
  token="$(curl -fsS -X POST -H "Authorization: Bearer $jwt" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/app/installations/$installation/access_tokens" | jq -r .token)" || return 1
  [ -n "$token" ] && [ "$token" != null ] || return 1
  NEW_TOKEN="$token" GITHUB_ENV=/dev/null GITHUB_WORKSPACE=/nonexistent GIT_CONFIG_COUNT=0 \
    bash "$here/refresh.sh" > /dev/null
}

while true; do
  sleep 2400
  if mint; then
    echo "$(date -u +%FT%TZ) refreshed the GitHub token" >&2
  else
    echo "$(date -u +%FT%TZ) could not refresh the GitHub token; retrying in 5 minutes" >&2
    sleep 300
    mint || echo "$(date -u +%FT%TZ) second refresh attempt failed" >&2
  fi
done
