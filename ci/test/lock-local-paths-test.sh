#!/usr/bin/env bash
#
# lock-local-paths-test.sh — no committed lock file names a path on the
# machine that wrote it.
#
# A lock refresh run in a workspace records each sibling's source. When it
# records the checkout (`/home/<user>/...`, a `/tmp/...` worktree) instead of
# the sibling's remote, the lock cannot be resolved anywhere else, and it
# leaks the author's directory layout. That landed on `agents` once (fixed in
# 44f2a89ac1e, "name sibling sources by their remotes again"); this gate keeps
# it from landing again.
#
# Scans every tracked repro.lock and locks/*.lock for /home/, /tmp/, /Users/,
# /private/var/ and a Windows user profile (C:\Users\...). Then proves it can
# see one: the same scan over a copy of repro.lock with a local path planted
# must fail.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

pattern='(/home/|/tmp/|/Users/|/private/var/|[A-Za-z]:[\\/]+Users[\\/])'

# scan FILE... — print every offending line, prefixed with its file; exit 1
# when there is one.
scan() {
	local found=0 f
	for f in "$@"; do
		if grep -nE "${pattern}" "${f}" | sed "s|^|  ${f}:|"; then
			found=1
		fi
	done
	return "${found}"
}

mapfile -t locks < <(git ls-files -- 'repro.lock' '*/repro.lock' 'locks/*.lock')
if [ "${#locks[@]}" -eq 0 ]; then
	echo "lock-local-paths: FAIL: no tracked lock file found; this gate scans nothing" >&2
	exit 1
fi

failures=0
if out="$(scan "${locks[@]}")"; then
	echo "  ok   ${#locks[@]} lock file(s) name no local path: ${locks[*]}"
else
	echo "  FAIL a lock file names a path on the machine that wrote it:" >&2
	printf '%s\n' "${out}" >&2
	echo "       Record the sibling's remote instead (rerun the lock refresh from a" >&2
	echo "       workspace whose siblings have their remotes), or drop the lock change." >&2
	failures=$((failures + 1))
fi

# The control: a planted path must be seen.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lock-local-paths.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
cp repro.lock "${scratch}/repro.lock"
printf 'source = "%s"\n' "/home/someone/m/codetracer-gui/isonim" >>"${scratch}/repro.lock"
if scan "${scratch}/repro.lock" >/dev/null; then
	echo "  FAIL control: a planted /home/ path was not reported" >&2
	failures=$((failures + 1))
else
	echo "  ok   control: a planted /home/ path is reported"
fi

if [ "${failures}" -eq 0 ]; then
	echo "lock-local-paths: OK"
	exit 0
fi
echo "lock-local-paths: ${failures} check(s) FAILED" >&2
exit 1
