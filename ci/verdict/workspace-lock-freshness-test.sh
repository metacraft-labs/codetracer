#!/usr/bin/env bash
#
# workspace-lock-freshness-test.sh — contract suite for
# ci/verdict/workspace-lock-freshness.sh.
#
# # Two modes
#
# The check has two modes, one per lock store `clone-siblings` can read
# (reprobuild-specs Unified-Locking-And-Hooks.md §14.5). Section 10 covers the
# default, `lock-store: committed`: the commit's own `repro.lock`, which is the
# mode CI runs. Sections 1-9 cover `lock-store: record-store`, the per-commit
# record in the shared manifests repo, which the check uses only when a
# workflow opts into it. Everything below, down to "Run directly", is about
# the record-store mode.
#
# # What this suite is really about (record-store mode)
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

# The sibling every fixture lock pins. It is no longer hard-coded IN the check —
# the check derives its declared set from `.github/sibling-repos` and the bare
# entries of the `siblings:` blocks (see section 9) — so the fixtures declare it
# explicitly, via the fixture declaration files below, and the sections before 9
# are unchanged in meaning: exactly one declared repo, present in the lock.
readonly PROBE_SIBLING="codetracer-trace-format"

# The second repo every fixture lock pins. Section 9 uses it to build a lock
# that carries EVERY declared repo without needing a third name.
readonly SECOND_SIBLING="codetracer-native-backend"

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

# write_lock <checkout> <sha> [--without-probe-sibling | --malformed-revision]
# A real reprobuild.workspace.lock.v1 document at the nested layout the
# resolver reads: locks/<project>/<trigger-repo>/<sha>.toml
#
# `--without-probe-sibling` is a WELL-FORMED lock that simply does not pin
# ${PROBE_SIBLING} — the resolver's exit 4, and the exact shape of the defect
# section 9 is about. `--malformed-revision` is a lock that cannot be trusted at
# all (a revision that is not a 40-hex SHA — the resolver's exit 5), which is
# what section 5 needs and what exit 4 must NOT be confused with.
write_lock() {
	local root="$1" sha="$2" mode="${3-}"
	local dir="${root}/locks/codetracer/codetracer"
	local trace_rev="$REV_TRACE_FORMAT"
	[ "$mode" = "--malformed-revision" ] && trace_rev="not-a-commit-id"
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
		printf '%s\n' "name = \"${SECOND_SIBLING}\""
		printf '%s\n' "path = \"${SECOND_SIBLING}\""
		printf '%s\n' 'remote = "metacraft-labs"'
		printf '%s\n' "revision = \"${REV_NATIVE_BACKEND}\""
		printf '%s\n' 'branch = "dev"'
		if [ "$mode" != "--without-probe-sibling" ]; then
			printf '%s\n' ''
			printf '%s\n' '[[repo]]'
			printf '%s\n' "name = \"${PROBE_SIBLING}\""
			printf '%s\n' "path = \"${PROBE_SIBLING}\""
			printf '%s\n' 'remote = "metacraft-labs"'
			printf '%s\n' "revision = \"${trace_rev}\""
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

# --- fixture DECLARATION sites --------------------------------------------
#
# The check derives the sibling repos it probes from this repo's real
# declarations (`.github/sibling-repos` plus the bare entries of the
# `siblings:` blocks under `.github/workflows`). Pointed at those, every fixture
# lock in this file would be missing nine or ten declared repos and every
# section below would report the section-9 verdict instead of its own.
#
# So the sections that are not ABOUT the derivation declare exactly one repo —
# ${PROBE_SIBLING}, which every fixture lock pins — and section 9 drives the
# derivation from its own fixtures and from the real files. The overridable
# inputs exist so a contract can state the world it is testing, and there is a
# contract (9g) that the DEFAULTS still point at the real declaration sites.
DECL_DIR="${tmp_root}/declarations"
mkdir -p "$DECL_DIR"
DEFAULT_DECL_LIST="${DECL_DIR}/one-repo"
printf '%s\n' "$PROBE_SIBLING" >"$DEFAULT_DECL_LIST"
# An EMPTY workflow directory, so the default fixture declaration set is exactly
# the one name in the list above and nothing leaks in from a stray `*.yml`.
DEFAULT_DECL_WF="${DECL_DIR}/no-workflows"
mkdir -p "$DEFAULT_DECL_WF"

# run_check ... -> sets RC, OUT, ELAPSED
#
# DEFAULT --branch dev, the branch CI passes; it is only printed in the report.
# It steps aside when a fixture passes its own.
#
# DEFAULT --sibling-list / --workflow-dir, for the reason given just above. Each
# steps aside independently when a fixture passes its own.
#
# DEFAULT --lock-store record-store: sections 1-9 are the record-store mode's
# contracts, and the store the check would otherwise derive from the fixture
# workflow directory is `committed`. Section 10 passes `--lock-store committed`
# and the default steps aside.
run_check() {
	local start end arg has_branch=0 has_list=0 has_wf=0 has_store=0
	for arg in "$@"; do
		case "$arg" in
		--branch) has_branch=1 ;;
		--sibling-list) has_list=1 ;;
		--workflow-dir) has_wf=1 ;;
		--lock-store) has_store=1 ;;
		esac
	done
	[ "$has_store" -eq 0 ] && set -- "$@" --lock-store record-store
	[ "$has_branch" -eq 0 ] && set -- "$@" --branch dev
	[ "$has_list" -eq 0 ] && set -- "$@" --sibling-list "$DEFAULT_DECL_LIST"
	[ "$has_wf" -eq 0 ] && set -- "$@" --workflow-dir "$DEFAULT_DECL_WF"
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
# 5. UNTRUSTED LOCK. Exit 5/6 from the resolver mean a lock EXISTS but is
#    malformed or self-contradictory. That is not a publication stall, so
#    waiting for one is wrong: it must be reported immediately and must not
#    consume the window.
#
#    THE FIXTURE IS A MALFORMED REVISION, not a missing entry. It used to be a
#    lock with the probe sibling omitted, which is the resolver's exit 4 — and
#    exit 4 is now a DIFFERENT verdict (section 9: the lock is fine, the
#    declaration never reached it), with a different exit code and a different
#    remedy. A fixture that conflated the two would let either verdict satisfy
#    this contract, so it now uses a revision that is not a 40-hex commit id:
#    unambiguously exit 5, unambiguously "cannot be trusted".
# ---------------------------------------------------------------------------
echo "untrusted: a lock that exists but cannot answer is not waited on"

new_world untrusted
write_lock "$PUB" "$SHA_UNDER_TEST" --malformed-revision >/dev/null
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

# ---------------------------------------------------------------------------
# 9. A DECLARED REPO THAT NEVER REACHED THE LOCK.
#
# Declaring a sibling repo does not put it in a lock, and until these contracts
# existed nothing noticed. Repos are DECLARED in two places in this repo — the
# bare entries of the `siblings:` blocks in `.github/workflows/*.yml`, and the
# names-only list `.github/sibling-repos` — while locks are PRODUCED elsewhere:
# by a developer's pre-push hook, whose repo set is whatever that developer had
# checked out, and (until it was retired) by the server-side re-anchor in
# publish-workspace-lock.yml, which copied every sibling pin verbatim from an
# older lock named only by `source-sha`. NEITHER PRODUCER READ THE
# DECLARATIONS. So a newly declared bare-name repo had no pin to copy, was
# absent from the next lock, and from every lock carried forward from that one.
#
# It surfaced only at build time, as `resolve-sibling-rev: sibling '<name>' not
# present in lock`, taking out every job that reached `clone-siblings`. That is
# not hypothetical: isonim-tui, isonim-gpui, nim-termctl and nim-pty did exactly
# this (ci/test/sibling-provisioning-test.sh).
#
# The only adjacent check was this one, and it probed ONE hard-coded name
# (`codetracer-trace-format`) justified by a comment claiming that name was "in
# every one of this repo's sibling lists" — which was false: `.github/sibling-
# repos` does not contain it at all. A lock missing any OTHER declared repo
# passed green.
#
# So: probe every DECLARED name, and DERIVE the declared set. The derivation is
# the load-bearing half. A hard-coded list — even a correct one — drifts out of
# agreement with the declarations silently, which is the same disease one layer
# up: the check would go on passing for the very repo somebody had just added.
# Contracts 9d/9e/9f/9g are therefore about the derivation, not just the verdict.
# ---------------------------------------------------------------------------
readonly MISSING_BANNER="DECLARED SIBLING REPOS ARE MISSING FROM THE WORKSPACE LOCK"
readonly UNDECLARED_REPO="codetracer-launcher"

decl_full="${DECL_DIR}/full"
printf '%s\n%s\n' "$PROBE_SIBLING" "$SECOND_SIBLING" >"$decl_full"

decl_with_missing="${DECL_DIR}/with-missing"
printf '%s\n%s\n' "$PROBE_SIBLING" "$UNDECLARED_REPO" >"$decl_with_missing"

new_world declared
publish "$SHA_UNDER_TEST"
snapshot declared

# --- 9a. the healthy case ---------------------------------------------------
echo "declared siblings: a lock carrying every declared repo passes"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_full" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 30 --poll-seconds 5
expect_rc 0 "declared/complete"
expect_contains "Workspace lock present for ${SHA_UNDER_TEST}" "declared/complete"
expect_contains "pins all 2 declared sibling repo(s)" "declared/complete"
expect_not_contains "$MISSING_BANNER" "declared/complete"
ok "a lock that pins every declared repo passes, and says how many it checked"

# --- 9b. the defect ---------------------------------------------------------
#
# The decisive contract. Same lock, same commit, same everything — one more
# DECLARED repo, which the lock does not pin. Before this section that was
# green.
echo "declared siblings: a lock missing one declared repo fails loudly and names it"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_with_missing" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 30 --poll-seconds 5
expect_rc 4 "declared/missing"
expect_contains "$MISSING_BANNER" "declared/missing"
expect_contains "$UNDECLARED_REPO" "declared/missing"
ok "a declared repo absent from an existing lock is a failure that NAMES the repo"

# Naming the repo without naming where it was declared sends the reader hunting
# through fourteen workflow files for the entry to fix.
expect_contains "declared in: ${decl_with_missing}" "declared/missing"
ok "the report names the declaration site, so the entry to fix is not a search"

expect_contains "REMEDY" "declared/missing"
ok "the report carries a remedy, not just an accusation"

# Waiting cannot add a repo to a lock that already exists, so this must not
# spend the window — the same rule the untrusted verdict obeys.
expect_elapsed_below 5 "declared/missing"
ok "it does not spend the grace window on a condition waiting cannot fix"

# --- 9c. the three verdicts are distinguishable -----------------------------
#
# A new failure that reads like an existing one is worth very little: the whole
# point is that the remedies differ. "No lock at all" is the workspace/publisher
# question; "a lock that cannot be parsed" is a data question; "a lock that is
# fine but does not name a repo somebody declared" is a declaration question,
# and only the third has the remedy this report prints.
echo "declared siblings: the new verdict is distinct from the other two"

expect_not_contains "$STALL_BANNER" "declared/missing"
expect_not_contains "cannot be used" "declared/missing"
ok "the missing-declared-repo verdict is neither the stall banner nor the untrusted one"

# ...and the converse, measured rather than assumed: drive the other two
# verdicts through the SAME declaration set and confirm each keeps its own exit
# code and banner. Without this, a check that answered 4 for everything would
# satisfy 9b.
new_world declared_nolock
snapshot declared_nolock
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_with_missing" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 1 "declared/no-lock"
expect_contains "$STALL_BANNER" "declared/no-lock"
expect_not_contains "$MISSING_BANNER" "declared/no-lock"
ok "no lock at all is still exit 1 and the STALL banner, not the missing-repo verdict"

new_world declared_untrusted
write_lock "$PUB" "$SHA_UNDER_TEST" --malformed-revision >/dev/null
git_q -C "$PUB" add -A
git_q -C "$PUB" commit --quiet -m "Publish 1 workspace lock entry"
git_q -C "$PUB" push --quiet origin HEAD:latest
snapshot declared_untrusted
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_with_missing" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 1 "declared/untrusted"
expect_contains "cannot be used" "declared/untrusted"
expect_not_contains "$MISSING_BANNER" "declared/untrusted"
ok "an unparseable lock is still exit 1 and 'cannot be used', not the missing-repo verdict"

# --- 9d/9e/9f. the derivation actually reads the declarations ---------------
#
# These are the contracts that stop the set from quietly becoming a constant
# again. Each drives the VERDICT from a declaration file, so a check that
# ignored the declarations could not pass them.
echo "declared siblings: the set is derived from the declaration sites"

decl_wf="${DECL_DIR}/workflows"
mkdir -p "$decl_wf"

# A BARE entry resolves its revision FROM the lock, so it must be probed.
# A `name=ref` entry bypasses the lock entirely, so probing it would be a
# false alarm about a repo whose revision this lock was never asked for.
cat >"${decl_wf}/mixed.yml" <<YAML
jobs:
  build:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
        with:
          siblings: |
            ${PROBE_SIBLING}
            declared-bare-in-workflow
            pinned-by-ref=dev
            sha-pinned=0123456789012345678901234567890123456789
            # commented-out-repo
YAML

new_world derivation
publish "$SHA_UNDER_TEST"
snapshot derivation

# 9d — declared ONLY in the sibling-repos list: probed.
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_with_missing" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 4 "derivation/list-only"
expect_contains "$UNDECLARED_REPO" "derivation/list-only"
ok "a repo declared ONLY in the sibling-repos list is probed against the lock"

# 9f — declared ONLY as a bare entry in a workflow: probed.
#
# The sibling list passed here carries its own `name=ref`, so this one run
# exercises the BARE_NAME rule on BOTH parsers at once.
decl_list_with_ref="${DECL_DIR}/one-repo-and-a-ref"
printf '%s\n%s\n' "$PROBE_SIBLING" "list-pinned-by-ref=dev" >"$decl_list_with_ref"

run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$decl_list_with_ref" --workflow-dir "$decl_wf" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 4 "derivation/workflow-bare"
expect_contains "declared-bare-in-workflow" "derivation/workflow-bare"
expect_contains "mixed.yml" "derivation/workflow-bare"
# shellcheck disable=SC2016 # literal backticks, nothing to expand
ok 'a BARE `siblings:` entry in a workflow is probed, and the workflow is named'

# 9e — the same block's `name=ref`, SHA-pinned and commented entries are NOT
# probed, and neither is the `name=ref` in the sibling list. They are in the
# same files, the same block and the same run as the bare entry above, so this
# cannot pass by the derivation reading nothing.
expect_not_contains "pinned-by-ref" "derivation/workflow-ref"
expect_not_contains "sha-pinned" "derivation/workflow-ref"
expect_not_contains "commented-out-repo" "derivation/workflow-ref"
# shellcheck disable=SC2016 # literal backticks, nothing to expand
ok 'a `name=ref` entry bypasses the lock and is NOT probed — nor is a commented one'

# 9g — THE DEFAULTS. Everything above drives fixtures; if the defaults did not
# point at this repo's real declaration sites the whole mechanism would be
# decorative in CI. `--list-declared` prints the derived set and reads nothing
# else, so this asserts the derivation against the files as they stand.
echo "declared siblings: the DEFAULT derivation reads this repo's real declarations"

OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --list-declared 2>&1)"
RC=$?
expect_rc 0 "derivation/defaults"

# Declared ONLY in .github/sibling-repos — the name the old hard-coded probe
# could never have covered, and the reason its justifying comment was false.
expect_contains "codetracer-launcher" "derivation/defaults"
# Declared ONLY as a bare entry in a workflow (launcher-recorder-e2e.yml).
expect_contains "nim-everywhere" "derivation/defaults"
ok "the default set spans BOTH declaration sites, from the real files"

# ...and stops at the declarations. `nim-stackable-hooks` appears in this
# repo's `siblings:` blocks only ever as `name=ref` (`=dev`), and `io-mon` only
# ever SHA-pinned; neither resolves from the lock, so neither may be probed
# against it. A derivation that swept every token in those blocks would fail
# here.
#
# This contract used to name `codetracer-native-backend` as the `=ref`-only
# repo. e705fbad5 (2026-09-19, LRC-4: the native edge of the launcher<->recorder
# gate) declared it bare in `.github/sibling-repos`, so it IS declared now and
# the derivation is right to include it; the expectation went stale and failed
# this suite on every run from then on. The name chosen for the `=ref`-only
# role must be one that no declaration site names bare — check with
# `--list-declared` before replacing it.
expect_contains "codetracer-native-backend" "derivation/defaults"
expect_not_contains "nim-stackable-hooks" "derivation/defaults"
expect_not_contains "io-mon" "derivation/defaults"
# shellcheck disable=SC2016 # literal backticks, nothing to expand
ok 'names that are only ever `=ref` or SHA-pinned in the real workflows are excluded'

# --- 9h. an empty declared set is refused, not passed -----------------------
#
# The failure mode this whole section exists to prevent, applied to itself: a
# derivation that silently yields nothing would probe nothing and pass every
# lock ever written, and would look exactly like a healthy check.
echo "declared siblings: a derivation that yields nothing is refused, not green"

empty_list="${DECL_DIR}/empty"
: >"$empty_list"
run_check --manifest-dir "$SNAP" --sha "$SHA_UNDER_TEST" \
	--sibling-list "$empty_list" --workflow-dir "$DEFAULT_DECL_WF" \
	--grace-seconds 4 --poll-seconds 2
expect_rc 2 "derivation/empty"
expect_contains "no declared sibling repos could be derived" "derivation/empty"
expect_not_contains "Workspace lock present" "derivation/empty"
ok "an empty declared set is a refusal (exit 2), never a vacuous pass"

# ---------------------------------------------------------------------------
# 10. THE COMMITTED LOCK (lock-store: committed, the default).
#
# Since reprobuild-specs Unified-Locking-And-Hooks.md §14 the lock CI reads is
# the commit's own `repro.lock`, so this is the mode CI runs. The fixtures are a
# real `reprobuild.solved-graph-lock.v2` `deps` line, in the exact shape
# `repro lock refresh` writes, and two real sibling upstreams on disk for
# `--verify-remote` to fetch from. No manifests repo exists anywhere in this
# section: the healthy case passing without one is itself a contract.
# ---------------------------------------------------------------------------
echo "committed lock: the commit's own repro.lock pins every declared repo"

CL_DIR="${tmp_root}/committed"
mkdir -p "$CL_DIR"

# sibling_upstream <name> — a real upstream with two commits on `dev`. Sets
# UP_URL and UP_HEAD.
sibling_upstream() {
	local up="${CL_DIR}/$1.git" work="${CL_DIR}/$1-work"
	git_q -c init.defaultBranch=dev init --quiet --bare "$up"
	git_q -c init.defaultBranch=dev init --quiet "$work"
	git_q -C "$work" commit --quiet --allow-empty -m "$1 one"
	git_q -C "$work" commit --quiet --allow-empty -m "$1 two"
	git_q -C "$work" push --quiet "$up" HEAD:dev
	UP_URL="file://${up}"
	UP_HEAD="$(git -C "$work" rev-parse HEAD)"
}
sibling_upstream "$PROBE_SIBLING"
TF_URL="$UP_URL"
TF_REV="$UP_HEAD"
sibling_upstream "$SECOND_SIBLING"
NB_URL="$UP_URL"
NB_REV="$UP_HEAD"
# The integrity contradiction below substitutes one sibling's revision for
# the other's. Empty commits made in the same second must still differ.
if [ "$TF_REV" = "$NB_REV" ]; then
	echo "fixture error: sibling upstream revisions must differ" >&2
	exit 1
fi

# dep_entry <name> <url> <revision> [<integrity>] — one inline table, keys in
# the order `repro lock refresh` writes them. Integrity defaults to the
# matching `git-sha1:<revision>`.
dep_entry() {
	printf '{ name = "%s", path = "../%s", coord_kind = "vcs", url = "%s", ref = "dev", revision = "%s", integrity = "%s", version = "", visibility = "public", participation = "" }' \
		"$1" "$1" "$2" "$3" "${4:-git-sha1:$3}"
}

# committed_lock <file> <entry>... — a whole lock: header, an empty solve, and
# a `deps` line whose first entry is the repo itself (`path = "."`), which the
# check must skip exactly as `clone-siblings` does.
committed_lock() {
	local file="$1" deps self
	shift
	self="$(printf '{ name = "codetracer", path = ".", coord_kind = "vcs", url = "https://github.com/metacraft-labs/codetracer", ref = "dev", revision = "%s", integrity = "git-sha1:%s", version = "", visibility = "public", participation = "", depends = "%s,%s" }' \
		"$SHA_UNDER_TEST" "$SHA_UNDER_TEST" "$PROBE_SIBLING" "$SECOND_SIBLING")"
	deps="$self"
	while [ "$#" -gt 0 ]; do
		deps="${deps}, $1"
		shift
	done
	{
		printf '%s\n' 'schema = "reprobuild.solved-graph-lock.v2"'
		printf '%s\n' ''
		printf '%s\n' '[lock]'
		printf '%s\n' 'platform = "amd64-linux"'
		printf '%s\n' 'packages = []'
		printf 'deps = [%s]\n' "$deps"
	} >"$file"
}

TWO_DECL_LIST="${DECL_DIR}/two-repos"
printf '%s\n' "$PROBE_SIBLING" "$SECOND_SIBLING" >"$TWO_DECL_LIST"

# run_committed <lock-file> [args...] — committed mode against the two-repo
# declaration, with the commit under test named for the report.
run_committed() {
	local lock="$1"
	shift
	run_check --lock-store committed --lock-file "$lock" --sha "$SHA_UNDER_TEST" \
		--sibling-list "$TWO_DECL_LIST" "$@"
}

# --- 10a. the healthy case, with and without fetching the pins --------------
GOOD_LOCK="${CL_DIR}/good.lock"
committed_lock "$GOOD_LOCK" \
	"$(dep_entry "$PROBE_SIBLING" "$TF_URL" "$TF_REV")" \
	"$(dep_entry "$SECOND_SIBLING" "$NB_URL" "$NB_REV")"
run_committed "$GOOD_LOCK"
expect_rc 0 "committed/healthy"
expect_contains "pins all 2 declared sibling repo(s)" "committed/healthy"
expect_not_contains "$STALL_BANNER" "committed/healthy"
run_committed "$GOOD_LOCK" --verify-remote
expect_rc 0 "committed/healthy-verified"
expect_contains "Each of the 2 pinned commit(s) was fetched" "committed/healthy-verified"
ok "a committed lock pinning every declared repo passes — no manifests repo exists at all"

# A v3 lock carries only portable identities and an explicit self marker.
V3_LOCK="${CL_DIR}/v3.lock"
sed -e 's/solved-graph-lock.v2/solved-graph-lock.v3/' \
	-e 's/path = "\.", /self = "true", /g' \
	-e 's/path = "[^" ]*", //g' "$GOOD_LOCK" >"$V3_LOCK"
run_committed "$V3_LOCK" --verify-remote
expect_rc 0 "committed/v3-verified"
expect_contains "Each of the 2 pinned commit(s) was fetched" "committed/v3-verified"
V3_SELF_LIST="${DECL_DIR}/v3-declares-self"
printf '%s\n' "codetracer" "$SECOND_SIBLING" >"$V3_SELF_LIST"
run_committed "$V3_LOCK" --sibling-list "$V3_SELF_LIST"
expect_rc 4 "committed/v3-self-excluded"
expect_contains "  - codetracer" "committed/v3-self-excluded"
ok "path-free v3 pins are fetched and self is excluded"

# --- 10b. a declared repo the lock does not pin ------------------------------
MISSING_LOCK="${CL_DIR}/missing.lock"
committed_lock "$MISSING_LOCK" "$(dep_entry "$PROBE_SIBLING" "$TF_URL" "$TF_REV")"
run_committed "$MISSING_LOCK"
expect_rc 4 "committed/missing"
expect_contains "NOT PINNED BY THE COMMITTED LOCK" "committed/missing"
expect_contains "  - ${SECOND_SIBLING}" "committed/missing"
expect_contains "declared in: ${TWO_DECL_LIST}" "committed/missing"
expect_not_contains "  - ${PROBE_SIBLING}" "committed/missing"
expect_not_contains "$STALL_BANNER" "committed/missing"
ok "a declared repo absent from the committed lock is exit 4, named with where it was declared"

# --- 10c. no lock, and a lock that is not a v2 lock --------------------------
run_committed "${CL_DIR}/does-not-exist.lock"
expect_rc 1 "committed/absent"
expect_contains "No committed repro.lock" "committed/absent"
expect_not_contains "$STALL_BANNER" "committed/absent"
V1_LOCK="${CL_DIR}/v1.lock"
sed 's/solved-graph-lock\.v2/solved-graph-lock.v1/' "$GOOD_LOCK" >"$V1_LOCK"
run_committed "$V1_LOCK"
expect_rc 1 "committed/unreadable"
expect_contains "cannot be read" "committed/unreadable"
ok "no repro.lock, or one that is not a solved-graph v2 lock, is exit 1"

# --- 10d. entries clone-siblings refuses -------------------------------------
BRANCH_LOCK="${CL_DIR}/branch.lock"
committed_lock "$BRANCH_LOCK" \
	"$(dep_entry "$PROBE_SIBLING" "$TF_URL" "dev" "")" \
	"$(dep_entry "$SECOND_SIBLING" "$NB_URL" "$NB_REV")"
run_committed "$BRANCH_LOCK"
expect_rc 1 "committed/branch-name"
expect_contains "not a commit id" "committed/branch-name"
CONTRA_LOCK="${CL_DIR}/contra.lock"
committed_lock "$CONTRA_LOCK" \
	"$(dep_entry "$PROBE_SIBLING" "$TF_URL" "$TF_REV")" \
	"$(dep_entry "$SECOND_SIBLING" "$NB_URL" "$NB_REV" "git-sha1:${TF_REV}")"
run_committed "$CONTRA_LOCK"
expect_rc 1 "committed/contradiction"
expect_contains "self-contradictory" "committed/contradiction"
ok "a branch name as a revision, or an integrity naming another commit, is exit 1"

# A refused entry outranks a missing one (the worse report wins), and both are
# still listed, so one run names everything that needs fixing.
BOTH_LOCK="${CL_DIR}/both.lock"
committed_lock "$BOTH_LOCK" "$(dep_entry "$SECOND_SIBLING" "$NB_URL" "main" "")"
run_committed "$BOTH_LOCK"
expect_rc 1 "committed/refused-and-missing"
expect_contains "not a commit id" "committed/refused-and-missing"
expect_contains "  - ${PROBE_SIBLING}" "committed/refused-and-missing"
ok "a refused entry outranks a missing repo (exit 1), and both are reported"

# --- 10e. a pin the remote does not have -------------------------------------
# A well-formed pin of a commit that was never pushed. Only --verify-remote can
# see it: the same lock passes without it, which proves the fetch is what
# caught it rather than some other check.
UNPUSHED_REV="$(hex40 0badc0de)"
UNPUSHED_LOCK="${CL_DIR}/unpushed.lock"
committed_lock "$UNPUSHED_LOCK" \
	"$(dep_entry "$PROBE_SIBLING" "$TF_URL" "$TF_REV")" \
	"$(dep_entry "$SECOND_SIBLING" "$NB_URL" "$UNPUSHED_REV")"
run_committed "$UNPUSHED_LOCK"
expect_rc 0 "committed/unpushed-unverified"
run_committed "$UNPUSHED_LOCK" --verify-remote
expect_rc 1 "committed/unpushed"
expect_contains "cannot be fetched" "committed/unpushed"
expect_contains "  - ${SECOND_SIBLING}: ${UNPUSHED_REV}" "committed/unpushed"
expect_not_contains "  - ${PROBE_SIBLING}:" "committed/unpushed"
ok "--verify-remote reports a pinned commit its remote does not have (exit 1), by name"

# --- 10e2. how an entry is matched to a declared name ------------------------
# Names are stable identities. A stale legacy path cannot impersonate one,
# and either schema's root marker excludes the consuming repo.
RENAMED_LOCK="${CL_DIR}/renamed.lock"
committed_lock "$RENAMED_LOCK" \
	"$(printf '{ name = "renamed-entry", path = "../%s", coord_kind = "vcs", url = "%s", ref = "dev", revision = "%s", integrity = "git-sha1:%s", version = "", visibility = "public", participation = "" }' \
		"$PROBE_SIBLING" "$TF_URL" "$TF_REV" "$TF_REV")" \
	"$(dep_entry "$SECOND_SIBLING" "$NB_URL" "$NB_REV")"
run_committed "$RENAMED_LOCK"
expect_rc 4 "committed/stale-path-is-not-an-identity"
expect_contains "  - ${PROBE_SIBLING}" "committed/stale-path-is-not-an-identity"
SELF_DECL_LIST="${DECL_DIR}/declares-self"
printf '%s\n' "codetracer" "$SECOND_SIBLING" >"$SELF_DECL_LIST"
run_committed "$GOOD_LOCK" --sibling-list "$SELF_DECL_LIST"
expect_rc 4 "committed/self-entry-is-not-a-pin"
expect_contains "  - codetracer" "committed/self-entry-is-not-a-pin"
ok "entries match by name, legacy sibling paths are ignored, and the root is excluded"

# --- 10f. which store: derived from the workflows' lock-store inputs ---------
echo "committed lock: the store is derived from the workflows, like the declared set"

STORE_WF="${DECL_DIR}/store-workflows"
mkdir -p "$STORE_WF"
cat >"${STORE_WF}/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
        with:
          # lock-store: record-store   <- a comment, not an opt-in
          siblings: |
            codetracer-trace-format
YAML
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 0 "store/default"
[ "$OUT" = "committed" ] || fail "store/default: expected 'committed', got: ${OUT}"

printf '%s\n' "          lock-store: committed" >>"${STORE_WF}/ci.yml"
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 0 "store/explicit-committed"
[ "$OUT" = "committed" ] || fail "store/explicit-committed: expected 'committed', got: ${OUT}"

cat >"${STORE_WF}/other.yml" <<'YAML'
jobs:
  other:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/clone-siblings@dev
        with:
          lock-store: "record-store"
YAML
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 0 "store/opt-in"
[ "$OUT" = "record-store" ] || fail "store/opt-in: expected 'record-store', got: ${OUT}"
# Derived record-store routes to record-store mode, which needs a manifests repo.
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --lock-file "$GOOD_LOCK" \
	--sibling-list "$TWO_DECL_LIST" --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 2 "store/opt-in-needs-manifests"
ok "no lock-store input (or 'committed') means committed; any 'record-store' opts the repo in"

# shellcheck disable=SC2016 # a literal GitHub expression, nothing to expand
printf '%s\n' '          lock-store: ${{ inputs.store }}' >>"${STORE_WF}/other.yml"
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 2 "store/unknown"
expect_contains "cannot be determined" "store/unknown"
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store --lock-store committed --workflow-dir "$STORE_WF" 2>&1)"
RC=$?
expect_rc 0 "store/explicit-overrides"
[ "$OUT" = "committed" ] || fail "store/explicit-overrides: expected 'committed', got: ${OUT}"
ok "an unresolvable lock-store input is a usage error unless --lock-store is given"

# The defaults read this repo's real workflows and answer.
OUT="$(timeout "${HARD_CAP_SECONDS}" bash "$CHECK" --print-lock-store 2>&1)"
RC=$?
expect_rc 0 "store/real-defaults"
case "$OUT" in
committed | record-store) : ;;
*) fail "store/real-defaults: expected 'committed' or 'record-store', got: ${OUT}" ;;
esac
ok "the default derivation reads this repo's real workflows and names a store"

# EXPECTED_ASSERTIONS — the number of `ok` calls this file reaches on a clean
# run, counted from the source rather than copied from a previous run's output.
# A suite that dies part-way prints a partial tally that looks exactly like a
# result; comparing against a number derived from the file is what tells the two
# apart. If your count comes out LOWER than this, the suite stopped early or a
# contract was deleted — find out which. Never lower this to make it match.
readonly EXPECTED_ASSERTIONS=48

echo
echo "workspace-lock-freshness-test summary: executed=${pass_count} failed=0"
if [ "$pass_count" -ne "$EXPECTED_ASSERTIONS" ]; then
	echo "workspace-lock-freshness-test: FAIL: reached ${pass_count} assertions, expected ${EXPECTED_ASSERTIONS}." >&2
	echo "  Either the suite stopped before its end, or contracts were added/removed" >&2
	echo "  without updating EXPECTED_ASSERTIONS. A partial tally is not a pass." >&2
	exit 1
fi
echo "workspace-lock-freshness-test: all contracts hold."
