#!/usr/bin/env bash
# ci/test/plat47-vcs-fixture-test.sh — scripts/plat47-vcs-fixture.sh builds its
# repository in the directory it is given, and touches no other repository,
# even when the caller's environment names one.
#
# A git hook (or `git rebase --exec`, or a harness started from either) exports
# GIT_DIR. The fixture once inherited it, and its `git config user.*` and
# `commit.gpgsign false` landed in codetracer's own shared .git/config: every
# later commit from any worktree was authored as the fixture, unsigned. This
# runs the real script against a real outer repository named by GIT_DIR, and
# checks the outer repository is unchanged and the fixture is complete.
#
# Negative control: the same run with the script's `unset` line removed must
# change the outer repository, or this check could not fail.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

fixture=scripts/plat47-vcs-fixture.sh
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

new_outer() { # $1 dir: a repository with one commit and no local identity
	git init -q "$1" &&
		git -C "$1" -c user.name=outer -c user.email=outer@invalid \
			-c commit.gpgsign=false commit -q --allow-empty -m outer
}

outer_state() { # $1 dir: what the fixture must not change
	git -C "$1" config --local --list | sort
	git -C "$1" rev-parse HEAD
	git -C "$1" for-each-ref --format='%(refname)'
}

run_fixture() { # $1 script, $2 outer repository, $3 fixture dir
	GIT_DIR="$2/.git" GIT_WORK_TREE="$2" bash "$1" "$3" >/dev/null 2>&1
}

echo "== the fixture leaves a repository the caller's GIT_DIR names alone"
new_outer "${work}/outer" || exit 2
before="$(outer_state "${work}/outer")"
if ! run_fixture "${fixture}" "${work}/outer" "${work}/fixture"; then
	fail "the fixture failed with GIT_DIR set"
fi
after="$(outer_state "${work}/outer")"
if [ "${before}" != "${after}" ]; then
	fail "the outer repository changed:"
	diff <(echo "${before}") <(echo "${after}") | sed 's/^/         /'
else
	echo "  ok   the outer repository's config, HEAD and refs are unchanged"
fi
status="$(git -C "${work}/fixture" status --porcelain 2>&1 | sort)"
want="$(printf '%s\n' ' M notes.txt' '?? scratch.txt' 'A  added.txt' | sort)"
if [ "${status}" = "${want}" ]; then
	echo "  ok   the fixture repository has its modified, added and untracked files"
else
	fail "the fixture repository's status is not the three states:"
	printf '         %s\n' "${status}"
fi

echo "== negative control: without the unset, the outer repository changes"
broken="${work}/broken-fixture.sh"
# shellcheck disable=SC2016 # the literal line, not an expansion
grep -v '^unset \$(git rev-parse --local-env-vars)$' "${fixture}" >"${broken}"
if cmp -s "${fixture}" "${broken}"; then
	fail "the control found no unset line to remove"
else
	new_outer "${work}/outer2" || exit 2
	before="$(outer_state "${work}/outer2")"
	run_fixture "${broken}" "${work}/outer2" "${work}/fixture2"
	if [ "${before}" = "$(outer_state "${work}/outer2")" ]; then
		fail "the outer repository is unchanged even without the unset (the check cannot fail)"
	else
		echo "  ok   without the unset the fixture writes into the outer repository"
	fi
fi

if [ "${failures}" -gt 0 ]; then
	echo "plat47-vcs-fixture: ${failures} failure(s)"
	exit 1
fi
echo "plat47-vcs-fixture: ok"
