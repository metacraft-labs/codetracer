#!/usr/bin/env bash
#
# resolve-sibling-rev.sh — resolve a sibling repo's pinned revision from the
# repo-workspaces workspace-lock model.
#
# This is the SINGLE approved source of sibling revisions for cross-repo CI and
# for local cross-repo test runs. It reads the per-commit lock snapshot that
# `workspace lock` (and the repo-workspaces pre-push / post-commit hooks)
# produce:
#
#     <manifest-repo>/locks/<project>/<repo>/<commit-sha>.xml
#
# Each lock is a ``repo manifest -r`` snapshot pinning the exact revision of
# every repo in the workspace at that commit. See
# ``codetracer-specs/Testing/Cross-Repo-CI-Integration.md`` and
# ``repo-workspaces/README.md`` (``workspace lock``).
#
# Legacy ``.github/sibling-pins`` / ``.github/sibling-pins.json`` /
# ``.github/rr-backend-pin.txt`` files and the ``locks/<project>/index.json``
# layout are NOT used: the lock XML keyed by the commit-under-test is the only
# mechanism.
#
# A given repo commit may be locked under several workspaces (e.g. the canonical
# ``codetracer`` workspace plus feature workspaces such as ``mcr``/``dev``); the
# lock location depends on which workspace pushed the commit. We therefore search
# across workspaces, preferring the canonical project when more than one lock
# matches.
#
# Usage:
#   resolve-sibling-rev.sh --repo SELF --sibling NAME \
#       [--manifest-dir DIR] [--sha COMMIT]... [--repo-dir DIR] \
#       [--prefer-project PROJECT] [--no-walk]
#
#   --repo SELF         repo under test (e.g. codetracer, codetracer-ci)
#   --sibling NAME      sibling repo whose revision to print
#   --manifest-dir DIR  manifest-repo checkout containing locks/.  Default:
#                       $CT_MANIFEST_DIR, else the nearest enclosing
#                       .repo/manifests discovered by walking up from --repo-dir.
#   --sha COMMIT        candidate commit(s) whose lock to use, in priority order.
#                       Repeatable.  Default: HEAD of --repo-dir.
#   --repo-dir DIR      working copy of SELF (for HEAD + ancestry walk).
#                       Default: current directory.
#   --prefer-project P  workspace/project to prefer when several match.
#                       Default: the value of --repo (its canonical workspace).
#   --no-walk           do not walk ancestry; require a direct lock on a
#                       candidate SHA (used by shallow CI checkouts).
#
# Resolution order for the lock to read:
#   1. Each --sha candidate, in order, that has a lock.
#   2. Otherwise (unless --no-walk), the nearest first-parent ancestor of the
#      first candidate that has a lock.  This makes local runs work even when
#      HEAD is unpushed (hence unlocked): siblings are unchanged since the last
#      locked ancestor, so its pin is correct.
#
# Prints the resolved revision (a commit SHA) to stdout.  Exits non-zero, with a
# diagnostic on stderr, when no lock can be found or the sibling is absent — CI
# must fail loudly rather than silently fall back to an unpinned branch tip.
set -euo pipefail

SELF_REPO=""
SIBLING=""
MANIFEST_DIR="${CT_MANIFEST_DIR:-}"
REPO_DIR="."
PREFER_PROJECT=""
NO_WALK=0
declare -a SHAS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		SELF_REPO="$2"
		shift 2
		;;
	--sibling)
		SIBLING="$2"
		shift 2
		;;
	--manifest-dir)
		MANIFEST_DIR="$2"
		shift 2
		;;
	--sha)
		SHAS+=("$2")
		shift 2
		;;
	--repo-dir)
		REPO_DIR="$2"
		shift 2
		;;
	--prefer-project)
		PREFER_PROJECT="$2"
		shift 2
		;;
	--no-walk)
		NO_WALK=1
		shift
		;;
	*)
		echo "resolve-sibling-rev: unknown argument: $1" >&2
		exit 2
		;;
	esac
done

for v in SELF_REPO SIBLING; do
	if [[ -z ${!v} ]]; then
		echo "resolve-sibling-rev: missing required value for $v" >&2
		echo "usage: resolve-sibling-rev.sh --repo SELF --sibling NAME [--manifest-dir DIR] [--sha COMMIT]... [--repo-dir DIR] [--prefer-project P] [--no-walk]" >&2
		exit 2
	fi
done

[[ -z $PREFER_PROJECT ]] && PREFER_PROJECT="$SELF_REPO"

# --- locate the manifest repo (locks/ tree) -------------------------------
if [[ -z $MANIFEST_DIR ]]; then
	d="$(cd "$REPO_DIR" 2>/dev/null && pwd)" || d=""
	while [[ -n $d && $d != "/" ]]; do
		if [[ -d "$d/.repo/manifests/locks" ]]; then
			MANIFEST_DIR="$d/.repo/manifests"
			break
		fi
		if [[ -d "$d/.repo/manifests" ]]; then
			MANIFEST_DIR="$d/.repo/manifests"
			break
		fi
		d="$(dirname "$d")"
	done
fi
if [[ -z $MANIFEST_DIR || ! -d "$MANIFEST_DIR/locks" ]]; then
	{
		echo "resolve-sibling-rev: cannot locate the manifest repo locks/ tree."
		echo "  Pass --manifest-dir <metacraft-manifests checkout>, set CT_MANIFEST_DIR,"
		echo "  or run from inside a repo-workspaces workspace (with .repo/manifests)."
	} >&2
	exit 3
fi
LOCKS_ROOT="$MANIFEST_DIR/locks"

# --- candidate SHAs -------------------------------------------------------
if [[ ${#SHAS[@]} -eq 0 ]]; then
	if head_sha="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)"; then
		SHAS+=("$head_sha")
	else
		echo "resolve-sibling-rev: no --sha given and '$REPO_DIR' is not a git repo" >&2
		exit 2
	fi
fi

# Find the lock file for a given repo@sha across all workspaces.
# Nested layout: locks/<project>/<repo>/<sha>.xml ; flat: locks/<project>/<repo>-<sha>.xml
# Prefer a lock under the canonical project, else the first match.
find_lock() {
	local sha="$1" f
	local preferred="" first=""
	while IFS= read -r -d '' f; do
		[[ -z $first ]] && first="$f"
		if [[ $f == "$LOCKS_ROOT/$PREFER_PROJECT/"* ]]; then
			preferred="$f"
			break
		fi
	done < <(find "$LOCKS_ROOT" \
		\( -path "*/$SELF_REPO/$sha.xml" -o -name "$SELF_REPO-$sha.xml" \) \
		-type f -print0 2>/dev/null)
	if [[ -n $preferred ]]; then
		printf '%s\n' "$preferred"
		return 0
	fi
	if [[ -n $first ]]; then
		printf '%s\n' "$first"
		return 0
	fi
	return 1
}

LOCK=""
# 1. direct lock on a candidate SHA (priority order)
for sha in "${SHAS[@]}"; do
	if LOCK="$(find_lock "$sha")"; then break; fi
	LOCK=""
done
# 2. nearest locked first-parent ancestor (local / non-shallow only)
if [[ -z $LOCK && $NO_WALK -eq 0 ]]; then
	if anc=$(git -C "$REPO_DIR" rev-list --first-parent --max-count=400 "${SHAS[0]}" 2>/dev/null); then
		while IFS= read -r sha; do
			[[ -z $sha ]] && continue
			if LOCK="$(find_lock "$sha")"; then break; fi
			LOCK=""
		done <<<"$anc"
	fi
fi

if [[ -z $LOCK ]]; then
	{
		echo "resolve-sibling-rev: no workspace lock found for $SELF_REPO"
		echo "  candidate SHAs: ${SHAS[*]}"
		echo "  searched: $LOCKS_ROOT/*/$SELF_REPO/<sha>.xml and *-<sha>.xml"
		[[ $NO_WALK -eq 0 ]] && echo "  (also walked first-parent ancestry of ${SHAS[0]})"
		echo "  Every commit under cross-repo CI must be locked by the repo-workspaces"
		echo "  pre-push hook (or 'workspace lock'). A missing lock means the commit"
		echo "  was not published through the workspace tooling."
	} >&2
	exit 3
fi

# Each <project .../> is on its own line in a `repo manifest -r` snapshot.
line=$(grep -E "<project[[:space:]][^>]*\bname=\"$SIBLING\"" "$LOCK" | head -1 || true)
if [[ -z $line ]]; then
	echo "resolve-sibling-rev: sibling '$SIBLING' not present in lock $LOCK" >&2
	exit 4
fi
rev=$(printf '%s\n' "$line" | sed -E 's/.*\brevision="([^"]+)".*/\1/')
if [[ -z $rev || $rev == "$line" ]]; then
	echo "resolve-sibling-rev: no revision attribute for '$SIBLING' in $LOCK" >&2
	exit 5
fi

printf '%s\n' "$rev"
