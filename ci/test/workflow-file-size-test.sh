#!/usr/bin/env bash
# Every workflow file stays under GitHub's size limit for one.
#
# GitHub refuses a workflow file larger than 512,000 bytes. It does not say so
# in the job list: every push then starts a run of that workflow which fails at
# once as a "workflow file issue" and runs no job. That happened on 2026-11-14,
# when codetracer.yml reached 513,291 bytes (run 43599200128), and nothing but
# reading the run page showed it. This check fails before such a push.
#
# It also fails, with a negative control, if it cannot tell an oversized file
# from a small one: a check that passed an empty directory would be no check.
#
# And it fails when a file is within $margin bytes (16 KiB) of the limit. On
# 2026-11-25 codetracer.yml stood 108 bytes under it after one added step, and
# the next would have started every dispatch as a `startup_failure` (run
# 45513601951). A file that nears the limit is caught here, in review, with
# room left to move a group of jobs or a block of prose out of it
# (a job's own workflow, docs/ci-server.md), not by a run that never starts.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
limit=512000
margin=16384
check_dir() { # $1 = directory of workflow files; prints the oversized ones
	local f size bad=0
	for f in "$1"/*.yml "$1"/*.yaml; do
		[ -e "$f" ] || continue
		size=$(wc -c <"$f")
		if [ "$size" -ge "$limit" ]; then
			echo "  ${f#"$root"/}: $size bytes, at or past GitHub's $limit-byte limit for a workflow file"
			bad=1
		elif [ "$size" -gt $((limit - margin)) ]; then
			echo "  ${f#"$root"/}: $size bytes, within $margin bytes of GitHub's $limit-byte limit for a workflow file"
			bad=1
		fi
	done
	return "$bad"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
head -c "$limit" /dev/zero | tr '\0' '#' >"$tmp/oversized.yml"
if check_dir "$tmp" >/dev/null; then
	echo "workflow-file-size: the negative control passed: a $limit-byte file was not refused" >&2
	exit 1
fi
rm "$tmp/oversized.yml"
head -c "$((limit - margin + 1))" /dev/zero | tr '\0' '#' >"$tmp/near.yml"
if check_dir "$tmp" >/dev/null; then
	echo "workflow-file-size: the margin control passed: a file $((margin - 1)) bytes under the limit was not refused" >&2
	exit 1
fi
rm "$tmp/near.yml"
head -c "$((limit - margin))" /dev/zero | tr '\0' '#' >"$tmp/roomy.yml"
if ! check_dir "$tmp" >/dev/null; then
	echo "workflow-file-size: a file exactly $margin bytes under the limit was refused" >&2
	exit 1
fi

n=$(find "$root/.github/workflows" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) | wc -l)
if [ "$n" -eq 0 ]; then
	echo "workflow-file-size: no workflow files under .github/workflows" >&2
	exit 1
fi
if ! check_dir "$root/.github/workflows"; then
	echo "workflow-file-size: move a step's script into a file under ci/ (as ci/test/scenario-lane-provision.sh does), a job into a workflow of its own (as test-ui-tests.yml is), or prose into docs/ci-server.md" >&2
	exit 1
fi
largest=$(cd "$root" && wc -c .github/workflows/*.yml | sort -n | tail -2 | head -1 | awk '{print $2 " (" $1 " bytes)"}')
echo "workflow-file-size: $n workflow file(s) at least $margin bytes under $limit; largest: $largest"
