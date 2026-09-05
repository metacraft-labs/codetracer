#!/usr/bin/env bash
#
# job-timeouts-test.sh -- contract suite for ci/verdict/job-timeouts.py.
#
# WHAT IS BEING PINNED
# --------------------
# That every job in codetracer.yml carries an explicit `timeout-minutes` -- and,
# just as importantly, that the checker asserting this is ABLE TO FAIL, and
# fails naming the jobs it found rather than merely returning a non-zero status.
#
# There are TWO negative cases, and neither is a mock:
#
#   * The primary one strips the `timeout-minutes:` lines back off the LIVE
#     workflow and requires the checker to name every job it just lost. This is
#     the case that keeps working: a fixture would freeze the job list on the day
#     it was written, whereas this reconstructs the pre-fix state of whatever the
#     file currently contains, and needs no git object, so it behaves the same
#     under the lint lane's fetch-depth of 1.
#   * The secondary one is the genuine pre-fix file at a PINNED commit, which
#     must name exactly the thirty jobs that were unbounded there and none of the
#     twelve that were not. Pinned rather than phrased against `origin/dev`,
#     because once this landed `origin/dev` carries the FIXED file and the case
#     would silently invert into asserting that the fix is broken. Skipped, with
#     a printed notice, when the object is absent from a shallow checkout.
#
# Both require the jobs to be named INDIVIDUALLY. A checker that stopped at the
# first violation would still exit 1, would still pass a status check, and would
# still be useless to whoever has to fix the file.
#
# Further properties, each of which a naive checker gets wrong:
#
#   1. `timeout-minutes: 360` must be REJECTED. It is exactly GitHub's default,
#      so it is a value that satisfies the check while changing nothing. If this
#      were accepted, the cheapest way to silence the checker would also be the
#      way that leaves the fleet exactly as it was.
#   2. An expression (`${{ ... }}`) must be REJECTED. The point of the bound is
#      that the worst-case hold on the concurrency group is computable from the
#      file; a computed bound is not.
#   3. A `uses:` job -- a reusable-workflow call -- must be SKIPPED, not failed.
#      GitHub rejects `timeout-minutes` on those outright, so demanding one
#      would make the check impossible to satisfy.
#
# Pure bash + python3 + PyYAML + git. No nix, no network, no siblings.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/ci/verdict/job-timeouts.py"
WORKFLOW=".github/workflows/codetracer.yml"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

if [ ! -f "$GUARD" ]; then
	printf 'FAIL: %s is missing\n' "$GUARD"
	exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
	printf 'FAIL: PyYAML is not available; this suite cannot run\n'
	exit 1
fi

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# ---------------------------------------------------------------------------
# 1. THE LIVE ASSERTION: the workflow in the working tree is fully bounded.
# ---------------------------------------------------------------------------
printf 'codetracer.yml carries a bound on every job\n'

out="$(cd "$REPO_ROOT" && python3 "$GUARD" "$WORKFLOW" 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then
	ok "every job in $WORKFLOW declares timeout-minutes"
else
	fail "$WORKFLOW has unbounded jobs" "$out"
fi

# The count is asserted upward: this file had 42 jobs when the check was
# written, and a job added without a bound must not be able to reduce the
# number of jobs the checker claims to have examined.
examined="$(sed -n 's/^job-timeouts: \([0-9]*\) job(s) bounded.*/\1/p' <<<"$out")"
if [ -n "$examined" ] && [ "$examined" -ge 42 ]; then
	ok "checker examined $examined jobs (>= the 42 present when written)"
else
	fail "checker examined '$examined' jobs, expected at least 42" "$out"
fi

# ---------------------------------------------------------------------------
# 2. THE NEGATIVE CASE, ON THE REAL FILE: strip the bounds back off the live
#    workflow and require the checker to name every job it just lost.
# ---------------------------------------------------------------------------
#
# This is deliberately run against the LIVE file with its `timeout-minutes:`
# lines removed rather than against a fixture. A fixture would freeze the job
# list on the day it was written; this case reconstructs exactly the state the
# file was in before the bounds landed, and keeps doing so as jobs are added.
# It also needs no git object, so it runs identically under the lint lane's
# fetch-depth of 1.
printf 'the same workflow with its bounds stripped is rejected, by name\n'

stripped_dir="$tmp_root/stripped/.github/workflows"
mkdir -p "$stripped_dir"
grep -v '^[[:space:]]*timeout-minutes:' "$REPO_ROOT/$WORKFLOW" >"$stripped_dir/codetracer.yml"

neg_out="$(cd "$tmp_root/stripped" && python3 "$GUARD" "$WORKFLOW" 2>&1)"
neg_status=$?
if [ "$neg_status" -eq 1 ]; then
	ok "stripping every bound makes the checker exit 1"
else
	fail "stripped workflow exited $neg_status, expected 1" "$neg_out"
fi

# It must name them INDIVIDUALLY. A checker that stopped at the first violation
# would still exit 1 and would still be useless to whoever has to fix the file.
named="$(grep -c ': no `timeout-minutes`' <<<"$neg_out")"
if [ "$named" -ge 42 ]; then
	ok "stripped report names $named jobs individually (>= the 42 present)"
else
	fail "stripped report named only $named jobs, expected at least 42" "$neg_out"
fi

# Spot-check across all four runner classes, so that a regression in how one
# class of job is parsed cannot hide behind a total.
for job in lint-bash lint-rust dev-build dmg-build appimage-cross-distro \
	test-non-gui test-ui-tests viewmodel-tests push-to-attic create-release \
	ci-verdict docs-scope reprobuild-macos-smoke windows-bootstrap-smoke \
	queue-watchdog; do
	if grep -q ": $job: no \`timeout-minutes\`" <<<"$neg_out"; then
		ok "stripped report names $job"
	else
		fail "stripped report does not name $job"
	fi
done

# ---------------------------------------------------------------------------
# 2b. THE HISTORICAL CASE: the genuine pre-fix file, when the object is present.
# ---------------------------------------------------------------------------
#
# Pinned to a SHA, never to `origin/dev`: once this landed, `origin/dev` carries
# the FIXED file, so a case phrased against the branch would silently invert into
# asserting the fix is broken. Skipped rather than failed when the object is
# absent, because the lint lane checks out at fetch-depth 1.
#
# 2f4195622 is the commit this work branched from, and is the last commit at
# which thirty of the forty-two jobs were unbounded.
HISTORICAL_REV="2f4195622"

if git -C "$REPO_ROOT" cat-file -e "$HISTORICAL_REV:$WORKFLOW" 2>/dev/null; then
	printf 'the genuine pre-fix workflow at %s is rejected\n' "$HISTORICAL_REV"
	hist_dir="$tmp_root/hist/.github/workflows"
	mkdir -p "$hist_dir"
	git -C "$REPO_ROOT" show "$HISTORICAL_REV:$WORKFLOW" >"$hist_dir/codetracer.yml"
	hist_out="$(cd "$tmp_root/hist" && python3 "$GUARD" "$WORKFLOW" 2>&1)"
	hist_status=$?
	if [ "$hist_status" -eq 1 ]; then
		ok "pre-fix workflow at $HISTORICAL_REV exits 1"
	else
		fail "pre-fix workflow exited $hist_status, expected 1" "$hist_out"
	fi

	hist_named="$(grep -c ': no `timeout-minutes`' <<<"$hist_out")"
	if [ "$hist_named" -eq 30 ]; then
		ok "pre-fix report names exactly the 30 jobs that were unbounded"
	else
		fail "pre-fix report named $hist_named jobs, expected exactly 30" \
			"If this number MOVED, reconcile it against the file at" \
			"$HISTORICAL_REV -- that commit is immutable, so a different" \
			"count means the checker changed, not the history." \
			"$hist_out"
	fi

	# The twelve that were ALREADY bounded must not be reported, or the check is
	# just listing every job it sees.
	for job in windows-bootstrap-smoke windows-headless-test test-ui-tests-rr \
		visual-replay-regression-gate queue-watchdog workspace-lock-freshness \
		windows-installer-build windows-installer-publish \
		windows-named-pipe-tests windows-rust-components \
		origin-dap-windows origin-dap-windows-nightly; do
		if grep -q ": $job: no \`timeout-minutes\`" <<<"$hist_out"; then
			fail "pre-fix report wrongly names already-bounded $job"
		else
			ok "pre-fix report does not name already-bounded $job"
		fi
	done
else
	printf '  skip %s is not present (shallow checkout); historical case not run\n' \
		"$HISTORICAL_REV"
fi

# ---------------------------------------------------------------------------
# 3. SYNTHETIC EDGE CASES the real history does not contain.
# ---------------------------------------------------------------------------
printf 'values that look like bounds but are not\n'

synth() { # $1 = dir name, $2 = yaml body
	local d="$tmp_root/$1/.github/workflows"
	mkdir -p "$d"
	printf '%s\n' "$2" >"$d/codetracer.yml"
	(cd "$tmp_root/$1" && python3 "$GUARD" "$WORKFLOW" 2>&1)
}

expect() { # $1 = label, $2 = expected status, $3 = dir, $4 = yaml, $5 = substring
	local out
	out="$(synth "$3" "$4")"
	local st=$?
	if [ "$st" -ne "$2" ]; then
		fail "$1: exit $st, expected $2" "$out"
		return
	fi
	if [ -n "${5:-}" ] && ! grep -q "$5" <<<"$out"; then
		fail "$1: output did not mention '$5'" "$out"
		return
	fi
	ok "$1"
}

expect "timeout-minutes: 360 is rejected as no bound at all" 1 t360 \
	'name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 360
    steps: [{run: "true"}]' \
	"bounds nothing"

expect "timeout-minutes: 359 is accepted" 0 t359 \
	'name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 359
    steps: [{run: "true"}]' \
	"1 job(s) bounded"

expect "an expression is rejected" 1 texpr \
	'name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ inputs.t }}
    steps: [{run: "true"}]' \
	"literal integer"

expect "timeout-minutes: 0 is rejected" 1 tzero \
	'name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 0
    steps: [{run: "true"}]' \
	"not a usable bound"

expect "a reusable-workflow call is skipped, not failed" 0 tuses \
	'name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps: [{run: "true"}]
  b:
    uses: ./.github/workflows/other.yml' \
	"1 job(s) bounded"

expect "a workflow with no jobs is an error, not a pass" 2 tempty \
	'name: t
on: [push]
jobs: {}' \
	"declares no jobs"

expect "a missing bound is reported with its runner" 1 trunner \
	'name: t
on: [push]
jobs:
  a:
    runs-on: eph-linux-x64-g1
    steps: [{run: "true"}]' \
	"runs-on: eph-linux-x64-g1"

printf '\n%d assertion(s), %d failure(s)\n' "$assertions" "$failures"
[ "$failures" -eq 0 ]
