#!/usr/bin/env bash
#
# workspace-lock-freshness-test.sh — contract suite for
# ci/verdict/workspace-lock-freshness.sh.
#
# # What this suite is really about
#
# The alarm asks "does a published workspace lock exist for this commit?".
# Locks are published ASYNCHRONOUSLY, by the pusher's pre-push hook, into a
# different repo than the one CI just checked out. So the alarm and the
# publisher race, and the alarm was losing: for codetracer 84a8b633 the CI
# clone of the manifests repo ran at 14:10:09 and the lock landed at 14:11:03,
# 54 seconds later. The check had already answered "missing" from a snapshot
# that was, by then, stale.
#
# The decisive fixture here is therefore NOT "a lock is absent" and NOT "a lock
# is present". It is `arrival during the window`: at the instant the check is
# launched the lock exists NOWHERE — not in the manifest-dir snapshot it was
# handed, and not in the upstream it was cloned from — and it is pushed to that
# upstream only after the check is already running. A check that answers from
# one snapshot fails it; a check that re-fetches passes it. The fixture asserts
# both halves of "nowhere" explicitly before it starts the clock, because a
# race fixture that quietly degrades into "the lock was already there" proves
# nothing at all.
#
# The suite is equally armed against the opposite cheat. A "fix" that simply
# stopped reporting absence would make the race test green, so
# `never arrives` requires the stall banner to still appear, and
# `already present` and `untrusted lock` require it to appear PROMPTLY —
# an implementation that waits out the grace window on every run, or that
# waits before reporting a lock it already has, fails them on elapsed time.
#
# # Two guards can hide each other — a general hazard, recorded here because
# # this suite is where it was caught
#
# The check's wait loop deliberately has exactly ONE deadline test. An earlier
# draft had two: one at the top of the loop and one just before sleeping. Every
# contract in this file passed, and mutation testing reported the top one as
# REMOVABLE — deleting it changed no observable behaviour, because the second
# one still ended the loop. Deleting the second alone was equally invisible.
#
# Two guards for one property, each of which makes the other untestable, are
# strictly worse than one. The redundancy reads as belt-and-braces and is
# actually the opposite: neither guard is covered, so neither is maintained,
# and the property survives only as long as nobody removes BOTH — or removes
# the one that was load-bearing for a case the other did not reach. Here the
# two were not even equivalent: only the top check bounded the fast re-probe
# path (the `continue` taken when a fetch moved the ref), so the bottom check
# alone would have looped forever against a manifests repo that keeps moving —
# which is its normal state, since several sessions push to it concurrently.
#
# The fix was to collapse them into one bound that both paths pass through, and
# to add the `churn` contract, which is the only fixture that can tell the two
# placements apart. If you find yourself adding a second check for a property
# this file already covers, prefer moving the existing one.
#
# # No mocks
#
# Every fixture is a real git repository: a real bare upstream on `latest`, a
# real clone standing in for the one the workflow makes, and a real second
# clone standing in for the pusher. The lock files are real
# `reprobuild.workspace.lock.v1` documents read by the real
# `scripts/resolve-sibling-rev.sh`. Nothing is stubbed, and nothing touches the
# network — the "remote" is a path on disk, which is what makes the race
# reproducible in a second rather than observable once in production.
#
# Run directly:  bash ci/verdict/workspace-lock-freshness-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/workspace-lock-freshness.sh"

if ! command -v git >/dev/null 2>&1; then
	echo "workspace-lock-freshness-test: SKIPPED — git is not on PATH, and every" >&2
	echo "  fixture in this suite is a real git repository (there is no stub mode)." >&2
	exit 3
fi

# The probe sibling the check hard-codes. A lock that does not name it is the
# resolver's exit 4, which is a different report from "not locked".
readonly PROBE_SIBLING="codetracer-trace-format"

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

pass_count=0

fail() {
	echo "workspace-lock-freshness-test: FAIL: $*" >&2
	exit 1
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

# hex40 <prefix> — a syntactically valid 40-hex commit id. The resolver rejects
# anything that is not one as a malformed lock, so fixtures must be exact.
hex40() {
	local p="$1"
	printf '%s' "${p}$(printf '0%.0s' $(seq 1 $((40 - ${#p}))))"
}

SHA_UNDER_TEST="$(hex40 84a8b633)"
SHA_PARENT="$(hex40 c0ffee11)"
SHA_UNRELATED="$(hex40 dead1234)"
REV_TRACE_FORMAT="$(hex40 abcdef01)"
REV_NATIVE_BACKEND="$(hex40 fedcba98)"

for s in "$SHA_UNDER_TEST" "$SHA_PARENT" "$SHA_UNRELATED" "$REV_TRACE_FORMAT"; do
	[ "${#s}" -eq 40 ] || fail "fixture bug: '${s}' is ${#s} chars, not a 40-hex commit id"
done

git_q() { git -c user.email=ci@example.invalid -c user.name=ci "$@"; }

# write_lock <checkout> <sha> [--without-probe-sibling]
# A real reprobuild.workspace.lock.v1 document at the nested layout the
# resolver reads: locks/<project>/<trigger-repo>/<sha>.toml
write_lock() {
	local root="$1" sha="$2" mode="${3-}"
	local dir="${root}/locks/codetracer/codetracer"
	mkdir -p "$dir"
	{
		printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
		printf '%s\n' ''
		printf '%s\n' '[lock]'
		printf '%s\n' 'project = "codetracer"'
		printf '%s\n' 'created_at = "2026-08-20T14:11:03Z"'
		printf '%s\n' 'created_by = "repro workspace lock"'
		printf '%s\n' ''
		printf '%s\n' '[[repo]]'
		printf '%s\n' 'name = "codetracer-native-backend"'
		printf '%s\n' 'path = "codetracer-native-backend"'
		printf '%s\n' 'remote = "metacraft-labs"'
		printf '%s\n' "revision = \"${REV_NATIVE_BACKEND}\""
		printf '%s\n' 'branch = "dev"'
		if [ "$mode" != "--without-probe-sibling" ]; then
			printf '%s\n' ''
			printf '%s\n' '[[repo]]'
			printf '%s\n' "name = \"${PROBE_SIBLING}\""
			printf '%s\n' "path = \"${PROBE_SIBLING}\""
			printf '%s\n' 'remote = "metacraft-labs"'
			printf '%s\n' "revision = \"${REV_TRACE_FORMAT}\""
			printf '%s\n' 'branch = "main"'
		fi
	} >"${dir}/${sha}.toml"
	printf '%s\n' "${dir}/${sha}.toml"
}

# new_world <name> — a bare upstream on `latest` seeded with one unrelated
# lock, plus a publisher clone. Echoes nothing; sets BARE / PUB.
new_world() {
	local name="$1"
	BARE="${tmp_root}/${name}.git"
	PUB="${tmp_root}/${name}-publisher"
	git_q -c init.defaultBranch=latest init --quiet --bare "$BARE"
	git_q clone --quiet "$BARE" "$PUB" 2>/dev/null
	git_q -C "$PUB" checkout --quiet -b latest 2>/dev/null || true
	write_lock "$PUB" "$SHA_UNRELATED" >/dev/null
	git_q -C "$PUB" add -A
	git_q -C "$PUB" commit --quiet -m "Publish 1 workspace lock entry"
	git_q -C "$PUB" push --quiet origin HEAD:latest
}

# snapshot <name> — the clone the workflow's "Clone the manifests repo" step
# makes: --branch latest, one shot, no further contact with the upstream.
snapshot() {
	local name="$1"
	SNAP="${tmp_root}/${name}-snapshot"
	git_q clone --quiet --branch latest "$BARE" "$SNAP"
}

# publish <sha> — the pusher's pre-push hook landing a lock upstream.
publish() {
	local sha="$1"
	write_lock "$PUB" "$sha" >/dev/null
	git_q -C "$PUB" add -A
	git_q -C "$PUB" commit --quiet -m "Publish 1 workspace lock entry"
	git_q -C "$PUB" push --quiet origin HEAD:latest
}

# The hard cap on any single invocation. Several contracts below are about the
# check TERMINATING — "it ends at the bound instead of retrying forever". An
# elapsed-time assertion cannot express that on its own, because a check that
# never returns never reaches the assertion; the suite would hang rather than
# fail, and a hung CI job reports nothing useful. So every invocation is capped
# well above the largest window any fixture configures (40s), turning a hang
# into a fast, legible failure (exit 124 matches no expected code).
readonly HARD_CAP_SECONDS=75

if ! command -v timeout >/dev/null 2>&1; then
	echo "workspace-lock-freshness-test: SKIPPED — coreutils 'timeout' is not on PATH." >&2
	echo "  Without it a non-terminating check would hang this suite instead of failing" >&2
	echo "  it, and 'it terminates at the bound' is one of the contracts under test." >&2
	exit 3
fi

# run_check ... -> sets RC, OUT, ELAPSED
#
# DEFAULT --branch dev. Every fixture below this line except the branch-coverage
# contracts is about a PUBLISHING branch whose record did not arrive, which is
# what `dev` is — and the check now refuses to call that a stall unless it can
# see a publisher configured for the branch. Without a branch it would answer
# "cause not determined", which is the correct answer to a question these
# fixtures are not asking. The coverage contracts pass their own `--branch` and
# `--publisher-workflow`, and this default steps aside when they do.
run_check() {
	local start end arg has_branch=0
	for arg in "$@"; do
		[ "$arg" = "--branch" ] && has_branch=1
	done
	[ "$has_branch" -eq 0 ] && set -- "$@" --branch dev
	start="$(date +%s)"
	OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" "$@" 2>&1)"
	RC=$?
	end="$(date +%s)"
	ELAPSED=$((end - start))
	if [ "$RC" -eq 124 ]; then
		OUT="[timed out after ${HARD_CAP_SECONDS}s — the check did not terminate]
${OUT}"
	fi
}

expect_rc() {
	local want="$1" desc="$2"
	[ "$RC" -eq "$want" ] || fail "${desc}: expected exit ${want}, got ${RC}. Output:
${OUT}"
}

expect_contains() {
	local frag="$1" desc="$2"
	case "$OUT" in
	*"$frag"*) : ;;
	*) fail "${desc}: expected output to contain '${frag}'. Output:
${OUT}" ;;
	esac
}

expect_not_contains() {
	local frag="$1" desc="$2"
	case "$OUT" in
	*"$frag"*) fail "${desc}: expected output NOT to contain '${frag}'. Output:
${OUT}" ;;
	*) : ;;
	esac
}

expect_elapsed_at_least() {
	local want="$1" desc="$2"
	[ "$ELAPSED" -ge "$want" ] ||
		fail "${desc}: expected to take at least ${want}s, took ${ELAPSED}s. Output:
${OUT}"
}

expect_elapsed_below() {
	local want="$1" desc="$2"
	[ "$ELAPSED" -lt "$want" ] ||
		fail "${desc}: expected to finish in under ${want}s, took ${ELAPSED}s. Output:
${OUT}"
}

readonly STALL_BANNER="WORKSPACE LOCK PUBLICATION HAS STALLED"

echo "workspace-lock-freshness contracts (${CHECK})"

# ---------------------------------------------------------------------------
# 1. THE RACE. The decisive one.
#
# The lock for the commit under test exists nowhere when the check starts, and
# is pushed upstream 4 seconds in. Both halves of "nowhere" are asserted before
# the clock starts, so this cannot silently become the "already present" case.
# ---------------------------------------------------------------------------
echo "the race: a lock published while the check is running"

new_world race
snapshot race

[ ! -e "${SNAP}/locks/codetracer/codetracer/${SHA_UNDER_TEST}.toml" ] ||
	fail "fixture bug: the lock is already in the snapshot; this would not be a race"
git_q -C "$BARE" cat-file -e "latest:locks/codetracer/codetracer/${SHA_UNDER_TEST}.toml" 2>/dev/null &&
	fail "fixture bug: the lock is already upstream; this would not be a race"
ok "fixture: the lock is in neither the snapshot nor the upstream at t=0"

(
	sleep 4
	publish "$SHA_UNDER_TEST"
) &
publisher_pid=$!

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 40 --poll-seconds 2
wait "$publisher_pid" 2>/dev/null || true

expect_rc 0 "race"
expect_contains "Workspace lock present for ${SHA_UNDER_TEST}" "race"
expect_not_contains "$STALL_BANNER" "race"
ok "a lock that arrives mid-window is found, not reported missing"

# It must have actually waited — an implementation that answered 0 without
# waiting could only be reading a lock that was already there.
expect_elapsed_at_least 4 "race"
ok "the check waited for the arrival rather than answering from its snapshot"

# ...and it must have stopped as soon as the fetch found it, not idled to the
# 40s ceiling. This is the "a fetch that finds the ref is faster than a fixed
# wait" property.
expect_elapsed_below 20 "race"
ok "it returned on arrival, not at the grace ceiling"

expect_contains "re-fetch" "race"
ok "the report says the lock was found by re-fetching, not from the snapshot"

# ---------------------------------------------------------------------------
# 2. THE PARENT CANDIDATE still races correctly: the workflow passes HEAD and
#    HEAD^, and arrival of EITHER must end the wait.
# ---------------------------------------------------------------------------
echo "the race: arrival of the parent candidate also ends the wait"

new_world raceparent
snapshot raceparent
(
	sleep 3
	publish "$SHA_PARENT"
) &
publisher_pid=$!
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" --sha "$SHA_PARENT" \
	--grace-seconds 40 --poll-seconds 2
wait "$publisher_pid" 2>/dev/null || true

expect_rc 0 "race/parent"
expect_contains "Workspace lock present for ${SHA_PARENT}" "race/parent"
ok "a lock arriving for HEAD^ ends the wait and reports that candidate"

# ---------------------------------------------------------------------------
# 3. NEVER ARRIVES. The mutation guard against "fix it by going quiet".
#    The stall this alarm exists for must still be reported, in full, and the
#    job must terminate rather than retry forever.
# ---------------------------------------------------------------------------
echo "absence: a lock that never arrives is still reported"

new_world famine
snapshot famine
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 6 --poll-seconds 2

expect_rc 1 "famine"
expect_contains "$STALL_BANNER" "famine"
expect_contains "$SHA_UNDER_TEST" "famine"
expect_contains "post-commit-lock.log" "famine"
ok "the stall banner and its diagnostic survive the grace window"

expect_elapsed_at_least 6 "famine"
ok "it gave the lock the full grace window before concluding absence"

expect_elapsed_below 30 "famine"
ok "it terminates at the bound instead of retrying forever"

expect_contains "6s" "famine"
ok "the report states the window it waited, so the reader can judge it"

# ---------------------------------------------------------------------------
# 3b. NEVER ARRIVES, ON A BUSY REMOTE. The bound must hold against a manifests
#     repo that keeps MOVING while our lock never appears — which is the normal
#     state of the shared repo, not an exotic one: several live sessions push
#     locks for other repos into it concurrently.
#
#     This is a distinct contract from the quiet case above, because the check
#     deliberately re-probes IMMEDIATELY (skipping the poll interval) whenever a
#     fetch moved the ref. That fast path is what makes an arriving lock cheap
#     to notice, and it is also the one path that could loop indefinitely if the
#     deadline were only consulted on the slow path. A steadily-advancing remote
#     drives the check down the fast path every round, so this fixture is the
#     only one that can tell the two placements of the deadline check apart.
# ---------------------------------------------------------------------------
echo "absence: the bound holds even while the remote keeps moving"

new_world churn
snapshot churn
(
	# One unrelated lock per second for well past the grace window — noise from
	# other repos, never the lock under test.
	i=0
	while [ "$i" -lt 25 ]; do
		publish "$(hex40 "$(printf 'bbbb%04x' "$i")")" 2>/dev/null || true
		i=$((i + 1))
		sleep 1
	done
) &
churn_pid=$!

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 6 --poll-seconds 2
kill "$churn_pid" 2>/dev/null || true
wait "$churn_pid" 2>/dev/null || true

expect_rc 1 "churn"
expect_contains "$STALL_BANNER" "churn"
ok "a remote advancing under it does not stop the check reporting absence"

expect_elapsed_below 25 "churn"
ok "the deadline bounds the fast re-probe path, not just the polling path"

# ---------------------------------------------------------------------------
# 4. ALREADY PRESENT. The guard against "fix it by always sleeping".
# ---------------------------------------------------------------------------
echo "presence: an existing lock is reported at once"

new_world present
publish "$SHA_UNDER_TEST"
snapshot present
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 30 --poll-seconds 5

expect_rc 0 "present"
expect_contains "Workspace lock present for ${SHA_UNDER_TEST}" "present"
expect_elapsed_below 5 "present"
ok "a lock already in the snapshot is reported without entering the window"

expect_contains "Newest commit touching locks/" "present"
ok "the overall staleness line is still reported"

# ---------------------------------------------------------------------------
# 5. UNTRUSTED LOCK. Exit 4/5/6 from the resolver mean a lock EXISTS but cannot
#    answer. That is not a publication stall, so waiting for one is wrong:
#    it must be reported immediately and must not consume the window.
# ---------------------------------------------------------------------------
echo "untrusted: a lock that exists but cannot answer is not waited on"

new_world untrusted
write_lock "$PUB" "$SHA_UNDER_TEST" --without-probe-sibling >/dev/null
git_q -C "$PUB" add -A
git_q -C "$PUB" commit --quiet -m "Publish 1 workspace lock entry"
git_q -C "$PUB" push --quiet origin HEAD:latest
snapshot untrusted
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 30 --poll-seconds 5

expect_rc 1 "untrusted"
expect_contains "cannot be used" "untrusted"
expect_not_contains "$STALL_BANNER" "untrusted"
ok "an untrusted lock is reported as itself, not as a stall"

expect_elapsed_below 5 "untrusted"
ok "it does not spend the grace window on a condition waiting cannot fix"

# ---------------------------------------------------------------------------
# 6. NOTHING TO RE-FETCH. `--manifest-dir` also accepts a plain fixture
#    directory (the documented offline mode). There is no upstream that could
#    deliver a late lock, so waiting would be pure latency — it must answer at
#    once, and must SAY that it answered from a single snapshot rather than
#    let the reader assume a window was given.
# ---------------------------------------------------------------------------
echo "offline: a non-git fixture directory is answered at once, and says so"

plain="${tmp_root}/plain"
mkdir -p "$plain"
run_check --manifest-dir "$plain" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 30 --poll-seconds 5

expect_rc 1 "offline/absent"
expect_contains "$STALL_BANNER" "offline/absent"
expect_contains "single snapshot" "offline/absent"
expect_elapsed_below 5 "offline/absent"
ok "no upstream: absence is reported at once, and the report admits why"

write_lock "$plain" "$SHA_UNDER_TEST" >/dev/null
run_check --manifest-dir "$plain" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 30 --poll-seconds 5
expect_rc 0 "offline/present"
ok "no upstream: a present lock still resolves"

# ---------------------------------------------------------------------------
# 7. UNREACHABLE UPSTREAM. If every re-fetch failed we did not observe absence,
#    we merely failed to look. The alarm must stay red — going quiet on a
#    broken network is the failure mode this whole file guards against — but it
#    must not claim the publication stalled when it never got to check.
# ---------------------------------------------------------------------------
echo "unreachable: a failing fetch is reported as such, not as a stall"

new_world unreachable
snapshot unreachable
git_q -C "$SNAP" remote set-url origin "${tmp_root}/no-such-repo.git"
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 6 --poll-seconds 2

expect_rc 1 "unreachable"
expect_contains "could not be re-fetched" "unreachable"
expect_not_contains "$STALL_BANNER" "unreachable"
ok "an unreachable manifests remote is red, but is not called a stall"

# The same report is owed when the fetch SUCCEEDS but the checkout cannot be
# fast-forwarded onto it — the files the resolver reads are then exactly as
# stale as if nothing had been fetched. (The check fast-forwards rather than
# `reset --hard` precisely because `--manifest-dir` may be a developer's own
# manifests checkout, so a divergent one must be reported, not overwritten.)
echo "diverged: a fetch that cannot be fast-forwarded is not 'looked at'"

new_world diverged
snapshot diverged
# The snapshot commits locally, so `latest` diverges from its upstream.
write_lock "$SNAP" "$(hex40 aaaa1111)" >/dev/null
git_q -C "$SNAP" add -A
git_q -C "$SNAP" commit --quiet -m "local divergence"
publish "$SHA_UNDER_TEST"
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--grace-seconds 6 --poll-seconds 2

expect_rc 1 "diverged"
expect_contains "could not be re-fetched" "diverged"
expect_not_contains "$STALL_BANNER" "diverged"
ok "a refused fast-forward is reported as not having looked, not as a stall"

# And the developer's local commit is still there: an alarm does not discard work.
git_q -C "$SNAP" cat-file -e "HEAD:locks/codetracer/codetracer/$(hex40 aaaa1111).toml" 2>/dev/null ||
	fail "diverged: the check destroyed the local commit in the manifest checkout"
ok "the local commit in the manifest checkout survives the check"

# ---------------------------------------------------------------------------
# 8. USAGE. Unchanged contracts, plus validation of the new bounds — a
#    mistyped window must not silently become an unbounded wait.
# ---------------------------------------------------------------------------
echo "usage"

run_check --sha "$SHA_UNDER_TEST"
expect_rc 2 "usage/no-manifest-dir"
run_check --manifest-dir "$plain"
expect_rc 2 "usage/no-sha"
run_check --manifest-dir "$plain" --sha "$SHA_UNDER_TEST" --grace-seconds forever
expect_rc 2 "usage/non-numeric-grace"
run_check --manifest-dir "$plain" --sha "$SHA_UNDER_TEST" --poll-seconds -1
expect_rc 2 "usage/negative-poll"
ok "usage errors, including an unparseable grace window, exit 2"

# The all-zero SHA (a branch's first push) is not a commit and must not be
# probed — nor may it drag the check through the whole grace window.
new_world zero
snapshot zero
run_check --manifest-dir "$SNAP" \
	--sha "0000000000000000000000000000000000000000" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 1 "usage/zero-sha"
expect_contains "$STALL_BANNER" "usage/zero-sha"
ok "the all-zero SHA is skipped and still yields a report"

# --- the cause of a missing lock is DERIVED, not assumed -------------------
#
# A report that names the missing thing but not the cause is how the `cloud`
# family stayed unexamined for its whole history: the check said "publication
# has stalled" and pointed at a local post-commit log, while the real cause was
# that no publisher was configured for the branch at all — a fact sitting in a
# file in the same checkout. These contracts pin that the check reads that file
# and that BOTH verdicts are reachable, because a cause-detector that can only
# ever return one answer detects nothing.
readonly NOPUB_BANNER="NO PUBLISHER IS CONFIGURED FOR BRANCH"
readonly UNDET_BANNER="WORKSPACE LOCK IS MISSING"

wf_dir="${tmp_root}/publisher-workflows"
mkdir -p "$wf_dir"

# Flow sequence — the spelling publish-workspace-lock.yml actually uses.
cat >"${wf_dir}/flow.yml" <<'YAML'
on:
  push:
    branches: [dev, cloud]
  pull_request_target:
    branches: [dev, cloud, stable]
jobs: {}
YAML

# Block sequence — equally valid YAML. A parser that read only the flow form
# would report a covered branch as uncovered, which is the most expensive way
# this check could be wrong: it would send a reader to edit a workflow that is
# already correct.
cat >"${wf_dir}/block.yml" <<'YAML'
on:
  push:
    branches:
      - dev
      - cloud
jobs: {}
YAML

# THE COMMENT TRAP. A branch named only in a TRAILING comment on a `branches:`
# line is not configuration — but it sits after the key, on a line the parser
# does match, so it is the one place a missing comment-strip actually changes
# the answer. Without stripping, `cloud` becomes a token of this list and the
# check reports the branch as COVERED: it goes quiet on precisely the condition
# it exists to report, which is worse than never having looked.
#
# A comment on its OWN line is not this trap — it fails the `^branches:` match
# either way — so a fixture built from one passes with the strip removed and
# pins nothing. This suite had exactly that fixture first; mutation testing
# reported the strip as removable, which is how the weaker fixture was caught.
cat >"${wf_dir}/comment-trap.yml" <<'YAML'
on:
  push:
    branches: [dev]  # cloud is deliberately excluded here
jobs: {}
YAML

# No `branches:` anywhere: the question cannot be answered from this file, and
# an empty parse must read as UNKNOWN rather than as "covers nothing" — the
# latter would send every reader to edit a workflow that may be fine.
cat >"${wf_dir}/no-list.yml" <<'YAML'
on:
  push: {}
jobs: {}
YAML

new_world coverage
snapshot coverage

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --publisher-workflow "${wf_dir}/flow.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_rc 1 "coverage/covered-flow"
expect_contains "$STALL_BANNER" "coverage/covered-flow"
expect_not_contains "$NOPUB_BANNER" "coverage/covered-flow"
ok "a branch the publisher covers is reported as a STALL, not as a missing publisher"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --publisher-workflow "${wf_dir}/block.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_contains "$STALL_BANNER" "coverage/covered-block"
ok "a block-sequence \`branches:\` list is read too, so a covered branch is never called uncovered"

# THE CONTRACT THAT MATTERS. This is the exact condition that took out 11 of 21
# jobs on `cloud`, and the check must name it rather than blame the workspace.
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --publisher-workflow "${wf_dir}/block.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_contains "$STALL_BANNER" "coverage/guard"
cat >"${wf_dir}/dev-only.yml" <<'YAML'
on:
  push:
    branches: [dev]
  pull_request_target:
    branches: [dev, stable]
jobs: {}
YAML
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --publisher-workflow "${wf_dir}/dev-only.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_rc 1 "coverage/uncovered"
expect_contains "$NOPUB_BANNER" "coverage/uncovered"
expect_not_contains "$STALL_BANNER" "coverage/uncovered"
# The candidates AND the cause, in one report: naming one without the other is
# the defect being fixed.
expect_contains "$SHA_UNDER_TEST" "coverage/uncovered"
expect_contains "REMEDY:" "coverage/uncovered"
ok "an UNCOVERED branch is named as such, with the candidates and a remedy — the two verdicts are distinguishable"

# Not-determined is a third answer, and it must not masquerade as either. A
# parser that silently yields nothing would otherwise read as "not covered" and
# send every reader to edit a workflow that was fine.
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --publisher-workflow "${wf_dir}/comment-trap.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_rc 1 "coverage/comment-trap"
expect_contains "$NOPUB_BANNER" "coverage/comment-trap"
expect_not_contains "$STALL_BANNER" "coverage/comment-trap"
ok "a branch named only in a TRAILING COMMENT is not configuration — the check still reports it uncovered"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch ghost --publisher-workflow "${wf_dir}/no-list.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_rc 1 "coverage/undetermined-parse"
expect_contains "$UNDET_BANNER" "coverage/undetermined-parse"
expect_contains "NOT DETERMINED" "coverage/undetermined-parse"
expect_not_contains "$NOPUB_BANNER" "coverage/undetermined-parse"
ok "a workflow with no \`branches:\` at all reads as UNKNOWN, not as 'covers nothing'"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch "" --publisher-workflow "${wf_dir}/flow.yml" \
	--grace-seconds 0 --poll-seconds 1
expect_rc 1 "coverage/no-branch"
expect_contains "NOT DETERMINED" "coverage/no-branch"
ok "with no --branch the check declines to answer the cause rather than answering it wrongly"

# The default must point at the real workflow, or CI would silently run the
# undetermined path forever and this whole mechanism would be decorative.
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--branch cloud --grace-seconds 0 --poll-seconds 1
expect_contains "$STALL_BANNER" "coverage/default-workflow"
expect_not_contains "NOT DETERMINED" "coverage/default-workflow"
ok "the DEFAULT --publisher-workflow resolves to this repo's real publish-workspace-lock.yml, and it covers 'cloud'"

echo
echo "workspace-lock-freshness-test summary: executed=${pass_count} failed=0"
echo "workspace-lock-freshness-test: all contracts hold."
