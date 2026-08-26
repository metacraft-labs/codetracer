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
# Usage:
#   ci/verdict/workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha PARENT_SHA]
#
# Exit: 0 a lock exists · 1 no lock (the alarm) · 2 usage error
# Lane: the `workspace-lock-freshness` job (stock ubuntu-latest, bash + git).
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
	*)
		echo "usage: workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha SHA]" >&2
		exit 2
		;;
	esac
done

if [ -z "$MANIFEST_DIR" ] || [ "${#SHAS[@]}" -eq 0 ]; then
	echo "usage: workspace-lock-freshness.sh --manifest-dir DIR --sha SHA [--sha SHA]" >&2
	exit 2
fi

# The all-zero SHA is what GitHub reports for a branch's first push; it is not a
# commit and must not be probed.
readonly ZERO_SHA="0000000000000000000000000000000000000000"

locked_sha=""
untrusted=""
for sha in "${SHAS[@]}"; do
	[ "$sha" = "$ZERO_SHA" ] && continue
	rc=0
	"$RESOLVER" --repo codetracer --sibling "$PROBE_SIBLING" \
		--manifest-dir "$MANIFEST_DIR" --sha "$sha" --no-walk >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		locked_sha="$sha"
		break
	fi
	# 3 is "not locked" (try the next candidate). 4/5/6 mean a lock EXISTS but
	# cannot be trusted — a different report, and not the stall this watches for.
	if [ "$rc" -ne 3 ]; then
		untrusted="$sha (resolver exit $rc)"
		break
	fi
done

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
	echo "Newest commit touching locks/ in the manifests repo: ${newest_lock_date}."
	exit 0
fi

cat <<EOF

==============================================================
  WORKSPACE LOCK PUBLICATION HAS STALLED
==============================================================

No workspace lock exists in the shared manifests repo for any of:

$(printf '  - %s\n' "${SHAS[@]}")

Newest commit touching locks/ in that repo: ${newest_lock_date}.

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
