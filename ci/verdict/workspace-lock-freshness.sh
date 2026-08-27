#!/usr/bin/env bash
# =============================================================================
# Alarm: the shared manifests repo is still receiving workspace locks for this
# repo's commits.
#
# # Why this file exists
#
# Until 2026-08-04, "is this commit locked?" was answered on every run as a side
# effect: `setup-dev-env` resolved each cross-repo sibling's revision from the
# per-commit workspace lock, so an unlocked commit could not get past
# `Setup dev env`. That coupling was a terrible gate — it took six jobs down in
# their first real step and left nine more `skipped` for eight days — and the
# `siblings:` entries now name their refs explicitly so it cannot happen again.
#
# But that coupling was also the ONLY thing anyone was watching. Removing it
# fixes the pipeline and silences the alarm in the same stroke, and the
# underlying condition is not small:
#
#   Nothing has been committed to metacraft-labs/metacraft-manifests, for ANY
#   repo, since 2026-08-02 (`b3b0ac6 Publish 1 workspace lock entry`).
#
# Those per-commit locks are what make a published workspace state reproducible.
# A stall means no reproducible snapshot of the workspace exists for any commit
# in that window — a fact about the whole workspace, not about CI.
#
# The failure is quieter than "the tooling broke". `repro`'s post-commit hook
# still WRITES the lock, into a workspace-local checkout of the manifests repo,
# and logs `ok wrote <path>` and exits 0. It is the commit-and-push that stopped:
# the files sit untracked in that checkout. On 2026-08-13 a developer's checkout
# held twenty untracked codetracer locks, including one for the exact commit CI
# was reporting as unlocked. The tooling's success message was true and useless
# — the artefact existed on one disk and nowhere else.
#
# So this job exists to say that out loud, on every run, in its own name.
#
# # Why it is a job and not a gate
#
# Nothing declares `needs:` on this job and it is absent from
# `ci/verdict/required-jobs.txt`. That is deliberate, and it is the whole design:
# a red check here must never be able to skip a test job. Coupling lock
# publication to the test suite is precisely the defect this repo just spent a
# PR undoing; re-introducing it as a gate would trade an eight-day outage for
# the next one. It is loud (a named, red check on every run) and structurally
# incapable of cascading.
#
# # What is asserted
#
# A lock exists for the commit under test, or for its first parent (the same two
# candidates `clone-siblings` probes, and the same `--no-walk` reasoning: CI
# checkouts are shallow, so an ancestry walk would hide the diagnosis rather
# than answer it). Resolution is delegated to `scripts/resolve-sibling-rev.sh`,
# the repo's existing resolver — it already knows both lock layouts (nested and
# flat) and both spellings (repo-workspaces `.xml`, reprobuild `.toml`), and it
# carries its own 51-assertion contract suite. Exit 3 from it is its only "this
# commit is not locked" answer; anything else means a lock exists but cannot be
# trusted, which is a different and worse report.
#
# # No mocks
#
# The input is a real checkout of the manifests repo, cloned by the caller.
# `--manifest-dir` exists so the check can be exercised against a fixture
# directory offline, not so CI can be handed a stub.
#
# # Why there is a grace window
#
# Locks are published ASYNCHRONOUSLY, by the pusher's pre-push hook, into a
# different repo than the one CI checked out — so the alarm and the publisher
# race, and this alarm used to lose. It answered from the single clone the
# workflow handed it: for 84a8b633 that clone ran at 14:10:09 and the lock
# landed at 14:11:03, 54 seconds later, by which time the check had already
# said "missing". The workflow's two candidates (HEAD and HEAD^) blunted this
# into intermittency rather than fixing it — which is worse, because an alarm
# that is red on some commits and green on others with no change between them
# teaches its readers to discount it, and that is the exact disease this whole
# campaign is about.
#
# So absence is now something the check EARNS rather than assumes: it
# re-fetches the manifests repo and re-probes until either a lock appears or a
# bounded window expires.
#
# THE BOUND IS 300 SECONDS, and the reasoning matters more than the number.
# The 54s instance is one sample, not a specification, and the mechanism that
# sets this distribution's tail is not raw network latency — it is contention
# on the shared manifests remote, which several live sessions write
# concurrently, so a push can be refused as a non-fast-forward and retried
# after a fetch/rebase. Five minutes covers several such rounds (~5.5x the one
# observed sample, so it is not fitted to it) while costing nothing that
# matters: this alarm does no build, runs on a stock hosted runner, and
# RELEASES that runner the instant a fetch finds the lock, so the healthy case
# pays nothing. Past ~5 minutes we would be buying vanishing race coverage with
# real reporting delay, and a lock still absent after five minutes is far more
# likely to be the publication stall this alarm was built for than a slow push.
#
# Three properties of the window are deliberate, and each is pinned by a
# contract in the suite:
#
#   * It PREFERS FETCHING TO SLEEPING. Every round re-fetches; when the fetch
#     moves the ref the check re-probes at once instead of sitting out the
#     poll interval. A fetch that finds the ref is faster and more honest than
#     a fixed wait.
#   * It is only ever spent on a question waiting can answer. A lock that
#     EXISTS but cannot be trusted (resolver 4/5/6), and a `--manifest-dir`
#     with no upstream to re-fetch from, are both reported IMMEDIATELY —
#     waiting could not change either.
#   * It ends. When the lock is genuinely never coming the check still reports,
#     in full, at the bound. Curing this flake by learning to say nothing would
#     be a far worse defect than the flake.
#
# If every re-fetch failed, the check did not observe absence — it failed to
# look — and it says so instead of blaming publication. It stays red either
# way; an alarm must not go quiet because its own network broke.
#
# Usage:
#   ci/verdict/workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha PARENT_SHA]
#                                          [--grace-seconds N] [--poll-seconds N]
#
#   --grace-seconds N  how long a missing lock may still arrive (default 300).
#   --poll-seconds N   pause between re-fetches when the ref did not move
#                      (default 15). Both exist so the contract suite can
#                      compress the window into seconds; CI uses the defaults.
#
# Exit: 0 a lock exists · 1 no lock, or no trustworthy answer (the alarm)
#     · 2 usage error
# Lane: the `workspace-lock-freshness` job (stock ubuntu-latest, bash + git).
# Contract suite: ./workspace-lock-freshness-test.sh — run it after any change
# here; the decisive fixture is a lock that arrives while the check is running.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly RESOLVER="$REPO_ROOT/scripts/resolve-sibling-rev.sh"

# The sibling probed is irrelevant to the question being asked — any entry in
# the lock proves the lock exists. `codetracer-trace-format` is used because it
# is in every one of this repo's sibling lists, so a lock that omits it is
# itself worth the louder exit-4 report.
readonly PROBE_SIBLING="codetracer-trace-format"

MANIFEST_DIR=""
SHAS=()
GRACE_SECONDS=300
POLL_SECONDS=15

usage() {
	echo "usage: workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha SHA]" \
		"[--grace-seconds N] [--poll-seconds N]" >&2
	exit 2
}

# A window that cannot be parsed must not silently become an unbounded wait, so
# anything but a non-negative integer is a usage error rather than a default.
require_uint() {
	case "${1:-}" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--manifest-dir)
		MANIFEST_DIR="${2:-}"
		shift 2
		;;
	--sha)
		[ -n "${2:-}" ] && SHAS+=("$2")
		shift 2
		;;
	--grace-seconds)
		require_uint "${2:-}" || usage
		GRACE_SECONDS="$2"
		shift 2
		;;
	--poll-seconds)
		require_uint "${2:-}" || usage
		POLL_SECONDS="$2"
		shift 2
		;;
	*)
		usage
		;;
	esac
done

if [ -z "$MANIFEST_DIR" ] || [ "${#SHAS[@]}" -eq 0 ]; then
	usage
fi
# A zero poll with a non-zero window would spin the loop as fast as git can
# fetch, hammering the shared remote for no extra coverage.
[ "$POLL_SECONDS" -lt 1 ] && POLL_SECONDS=1
readonly GRACE_SECONDS POLL_SECONDS

# The all-zero SHA is what GitHub reports for a branch's first push; it is not a
# commit and must not be probed.
readonly ZERO_SHA="0000000000000000000000000000000000000000"

locked_sha=""
untrusted=""

# One pass over the candidate SHAs against whatever is on disk right now.
probe_candidates() {
	local sha rc
	locked_sha=""
	untrusted=""
	for sha in "${SHAS[@]}"; do
		[ "$sha" = "$ZERO_SHA" ] && continue
		rc=0
		"$RESOLVER" --repo codetracer --sibling "$PROBE_SIBLING" \
			--manifest-dir "$MANIFEST_DIR" --sha "$sha" --no-walk >/dev/null 2>&1 || rc=$?
		if [ "$rc" -eq 0 ]; then
			locked_sha="$sha"
			return 0
		fi
		# 3 is "not locked" (try the next candidate). 4/5/6 mean a lock EXISTS
		# but cannot be trusted — a different report, and not the stall this
		# watches for. Waiting cannot turn a broken lock into a good one, so
		# this ends the window immediately rather than spending it.
		if [ "$rc" -ne 3 ]; then
			untrusted="$sha (resolver exit $rc)"
			return 0
		fi
	done
	return 1
}

# Can this manifest dir even receive a late lock? A real clone can; the offline
# fixture directory `--manifest-dir` also accepts cannot, and giving one a
# grace window would be pure latency in exchange for nothing.
manifest_remote=""
manifest_branch=""
if git -C "$MANIFEST_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	manifest_branch="$(git -C "$MANIFEST_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	manifest_remote="$(git -C "$MANIFEST_DIR" remote 2>/dev/null | head -n1)"
fi
refreshable=0
if [ -n "$manifest_remote" ] && [ -n "$manifest_branch" ]; then
	refreshable=1
fi

fetch_attempts=0
# Counts only rounds where the fetch AND the fast-forward both landed, i.e.
# where the files the resolver reads were actually brought up to date. A fetch
# whose fast-forward was refused left the checkout as stale as before, so
# counting it as a success would let the check claim it looked when it did not.
refresh_successes=0

# refresh_manifest — bring the checkout up to date with its upstream.
# Exit: 0 the ref moved · 1 the fetch or the fast-forward failed
#     · 2 fetched, nothing new.
#
# Fast-forward, never `reset --hard`: `--manifest-dir` may legitimately be a
# developer's own manifests checkout, and an alarm has no business discarding
# work there. A refused fast-forward is reported, not forced.
refresh_manifest() {
	local before after
	before="$(git -C "$MANIFEST_DIR" rev-parse HEAD 2>/dev/null || true)"
	fetch_attempts=$((fetch_attempts + 1))
	if ! git -C "$MANIFEST_DIR" fetch --quiet "$manifest_remote" "$manifest_branch" >/dev/null 2>&1; then
		return 1
	fi
	if ! git -C "$MANIFEST_DIR" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then
		return 1
	fi
	refresh_successes=$((refresh_successes + 1))
	after="$(git -C "$MANIFEST_DIR" rev-parse HEAD 2>/dev/null || true)"
	[ "$before" != "$after" ] && return 0
	return 2
}

started_at="$(date +%s)"
deadline=$((started_at + GRACE_SECONDS))
waited=0  # set once the loop exits, from started_at

while :; do
	probe_candidates && break

	# Nothing upstream could deliver a late lock — answer from what we have,
	# and say further down that that is what happened.
	[ "$refreshable" -eq 0 ] && break

	# THE ONE BOUND. Deliberately the only deadline test in this loop: both
	# ways round the loop pass back through here, so there is a single place
	# that can end the wait and a single place to get right. An earlier draft
	# also re-tested the deadline just before sleeping; that second test made
	# each one individually removable without any fixture noticing, which is
	# how a bound stops being a bound. One check, and the suite's `churn`
	# contract drives the fast path through it.
	now="$(date +%s)"
	[ "$now" -ge "$deadline" ] && break

	refresh_rc=0
	refresh_manifest || refresh_rc=$?
	# The ref moved: re-probe at once rather than sitting out the interval —
	# this is what makes an arriving lock cheap to notice. It loops back to the
	# bound above, and each round costs a real fetch, so it cannot spin.
	[ "$refresh_rc" -eq 0 ] && continue

	# `now` predates the fetch, and the bound above guarantees it was still
	# before the deadline, so this is always >= 1. Overshoot is at most one
	# fetch's duration, and the bound catches it on the next pass.
	remaining=$((deadline - now))
	if [ "$remaining" -lt "$POLL_SECONDS" ]; then
		sleep "$remaining"
	else
		sleep "$POLL_SECONDS"
	fi
done

waited=$(($(date +%s) - started_at))

# How stale is the shared repo overall? Reported either way: a lock for THIS
# commit does not prove publication is healthy for everyone else.
newest_lock_date="$(git -C "$MANIFEST_DIR" log -1 --format=%ad --date=short -- locks/ 2>/dev/null || true)"
[ -z "$newest_lock_date" ] && newest_lock_date="unknown"

if [ -n "$untrusted" ]; then
	echo "::error::A workspace lock exists for $untrusted but cannot be used. This is not a publication stall; read the resolver's diagnostic."
	exit 1
fi

if [ -n "$locked_sha" ]; then
	echo "Workspace lock present for ${locked_sha}."
	if [ "$fetch_attempts" -gt 0 ]; then
		echo "Found by re-fetching the manifests repo ${fetch_attempts} time(s) over ${waited}s:" \
			"the lock was NOT in the snapshot this job cloned, so a single-snapshot" \
			"check would have called this commit unlocked."
	fi
	echo "Newest commit touching locks/ in the manifests repo: ${newest_lock_date}."
	exit 0
fi

# Not one round brought the checkout up to date. We did not observe absence, we
# failed to look — which is still red (an alarm must not go quiet because its
# own network broke) but it is emphatically not a report about publication.
if [ "$refreshable" -eq 1 ] && [ "$fetch_attempts" -gt 0 ] && [ "$refresh_successes" -eq 0 ]; then
	echo "::error::The manifests repo could not be re-fetched (${fetch_attempts} attempts over ${waited}s, none brought '${MANIFEST_DIR}' up to date), so no lock could be confirmed either way for: ${SHAS[*]}. This is a report about THIS job's access to '${manifest_remote}/${manifest_branch}' — an unreachable remote, or a checkout that cannot fast-forward — not about workspace-lock publication. Fix that, then read the result."
	exit 1
fi

# How the window was spent, stated so the reader can judge the verdict rather
# than take it on trust.
if [ "$refreshable" -eq 1 ]; then
	window_note="Re-fetched the manifests repo ${fetch_attempts} time(s) over a ${GRACE_SECONDS}s grace
window (waited ${waited}s) before concluding this, so the lock is absent
rather than merely late."
else
	window_note="NOTE: '${MANIFEST_DIR}' has no upstream to re-fetch, so this was answered
from a single snapshot with no grace window. A late-arriving lock could
not have been seen. In CI this directory is a fresh clone and IS
re-fetched; this wording means the check was pointed at a fixture."
fi

cat <<EOF

==============================================================
  WORKSPACE LOCK PUBLICATION HAS STALLED
==============================================================

No workspace lock exists in the shared manifests repo for any of:

$(printf '  - %s\n' "${SHAS[@]}")

Newest commit touching locks/ in that repo: ${newest_lock_date}.

${window_note}

This is NOT a CI failure and it does not affect the test jobs — they
stopped depending on the lock deliberately. It is a statement about
the WORKSPACE: for every commit in this window there is no published,
reproducible snapshot of which sibling revisions it was built against.

The likely shape, because it is the one already observed: 'repro's
post-commit hook still writes the lock into a workspace-local checkout
of the manifests repo and logs 'ok wrote <path>', exit 0 — and nothing
commits or pushes it. Check for untracked files:

    git -C <workspace>/.repro/manifests status --porcelain locks/

Two other silent modes have been seen in the same logs, both exit 0:

    skipped-dirty  dirty sibling(s): <repo>     (no lock written at all)
    failed         repo '<x>' has no on-disk checkout at ...

    <workspace>/.repro/workspace/post-commit-lock.log

EOF
exit 1
