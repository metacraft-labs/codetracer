#!/usr/bin/env bash
# Ask a live host which revision it is serving, and refuse to be satisfied by
# the answer Cloudflare gives for a file that does not exist.
#
# ## The question
#
#   $ curl https://noirstudio.dev/build-id.txt
#   builtFrom 7ae43783f001eb832cab9996934afd08449ea0bc branch=cloud project=…
#
# Before this file existed there was NO WAY to ask a deployed CodeTracer web
# page which commit it came from. The answer was assembled by reading workflow
# logs and comparing hashed asset filenames — `assets/db_backend.7c9b88e3….js`
# identifies bytes and names no revision — and this campaign has repeatedly
# produced verdicts that could not name the artefact they measured because of
# it.
#
# ## Why this is not `curl -f .../build-id.txt`
#
# BECAUSE THAT CHECK CANNOT FAIL. Cloudflare Pages answers an absent path with
# the SPA fallback: HTTP 200, `text/html`, the entry document. So a probe that
# asserts a 200 is green against a deployment that has never heard of this
# file, and green against one whose deploy silently skipped the stamping step.
# This campaign has already been bitten by exactly that shape once — a fetch
# predicate that asked only whether a URL was requested, true whether the
# answer was 18 MB or a 404.
#
# What is asserted here is the CONTENT, by
# `platform/web_deployment.buildIdDefects` through `ci/test/build_id_check.nim`:
# the body must be the one-line form, it must name a full 40-hex object name,
# it must name a branch, and — when a commit is given — it must be THAT commit.
# The rule lives in the product and is unit-tested over inputs including the
# fallback document itself; this script is the part that talks to the network.
#
# ## Usage
#
#   ci/test/verify-build-id.sh <expected-commit|-> <host> [host...]
#
# `-` asks only "does this host publish a build identity at all", which is what
# a by-hand probe of an arbitrary host wants. A 40-hex commit makes it the
# identity test a deploy needs: "is the page I am looking at the one that was
# just built?"
#
#   ci/test/verify-build-id.sh - https://noirstudio.dev
#   ci/test/verify-build-id.sh "$GITHUB_SHA" https://ide.codetracer.com \
#                                            https://noirstudio.dev
#
# ## Environment
#
#   CT_BUILD_ID_DEADLINE_S   how long to keep polling a disagreeing host for
#                            (default 120). Cloudflare's edge takes seconds to
#                            converge after a deploy, and a propagation window
#                            is not a stale deployment — but two minutes of one
#                            is a real problem, so the poll has an end.
#   CT_BUILD_ID_INTERVAL_S   seconds between attempts (default 5).
#
# Exit: 0 every host agrees, 1 at least one does not, 2 the check could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cache="${TMPDIR:-/tmp}/ct-build-id-verify.$$"
mkdir -p "${cache}"
trap 'rm -rf "${cache}"' EXIT

if [ "$#" -lt 2 ]; then
	echo "usage: verify-build-id.sh <expected-commit|-> <host> [host...]" >&2
	exit 2
fi

expected="$1"
shift
hosts=("$@")

deadline_s="${CT_BUILD_ID_DEADLINE_S:-120}"
interval_s="${CT_BUILD_ID_INTERVAL_S:-5}"

# ---------------------------------------------------------------------------
# THE GRADER. Compiled from the product's own rule rather than reimplemented in
# awk, because a second spelling of "what a valid build identity is" would be
# free to drift from the one the deploy writes, and the drift that matters is
# the silent one: a probe that accepts what nothing produces is green about a
# deployment nobody checked.
# ---------------------------------------------------------------------------
grader="${cache}/build-id-check"
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/nimcache" \
	-o:"${grader}" "${repo_root}/ci/test/build_id_check.nim" \
	>"${cache}/compile.log" 2>&1; then
	echo "the build-id grader did not compile — the check could not run" >&2
	grep -E 'Error:' "${cache}/compile.log" | head -5 >&2
	exit 2
fi

# NON-VACUITY, asserted before anything is fetched. Every verdict below is a
# statement about a member of `hosts`, and a universal quantification over an
# empty list passes while measuring nothing — the `ok: 0/0 published files
# match` failure the deploy workflow's own manifest step records at length.
if [ "${#hosts[@]}" -lt 1 ]; then
	echo "no host was named — nothing would be verified" >&2
	exit 2
fi

fail=0
checked=0

fetch_body() {
	# The body and the observed content type, both. The type is REPORTED and
	# not asserted on: it is the tell for the SPA fallback and worth printing,
	# but the verdict comes from the bytes, so a host that served the right
	# file with a surprising type is not failed for it.
	local url="$1" out="$2"
	curl -sS --max-time 30 -o "${out}" -w '%{http_code} %{content_type}' \
		"${url}" 2>"${cache}/curl.err" || echo "000 (no response)"
}

for host in "${hosts[@]}"; do
	# `${host%/}` so both `https://x` and `https://x/` name one URL.
	url="${host%/}/build-id.txt"
	body="${cache}/body"
	waited=0
	while : ; do
		meta="$(fetch_body "${url}" "${body}")"
		if "${grader}" "${expected}" "${host}" "${body}" \
			>"${cache}/verdict.log" 2>&1; then
			break
		fi
		[ "${waited}" -ge "${deadline_s}" ] && break
		sleep "${interval_s}"
		waited=$((waited + interval_s))
	done

	checked=$((checked + 1))
	if "${grader}" "${expected}" "${host}" "${body}" \
		>"${cache}/verdict.log" 2>&1; then
		if [ "${waited}" -eq 0 ]; then
			echo "  $(sed 's/^ok: //' "${cache}/verdict.log")"
		else
			# PRINTED rather than swallowed, for the reason the deploy's byte
			# sweep gives about its own propagation window: a widening lag
			# should show up as a number long before it shows up as a failure.
			echo "  $(sed 's/^ok: //' "${cache}/verdict.log") (after ${waited}s of propagation)"
		fi
	else
		fail=1
		echo "  FAILED: ${url} answered ${meta} after ${waited}s" >&2
		cat "${cache}/verdict.log" >&2
	fi
done

echo "checked ${checked} host(s) against expected commit '${expected}'"
if [ "${checked}" -ne "${#hosts[@]}" ]; then
	echo "  ${checked} verdicts for ${#hosts[@]} hosts — the instrument did not run over every host" >&2
	exit 1
fi
exit "${fail}"
