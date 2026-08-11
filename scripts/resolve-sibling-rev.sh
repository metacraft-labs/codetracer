#!/usr/bin/env bash
#
# resolve-sibling-rev.sh — resolve a sibling repo's pinned revision from the
# workspace-lock model.
#
# VENDORED COPY. The authoritative version is
# `metacraft-github-actions/clone-siblings/resolve-sibling-rev.sh`; this copy
# exists so `scripts/run-cross-repo-tests.sh` and `ci/setup-rr-backend.sh` can
# resolve pins without depending on the action being checked out. Keep the two
# byte-identical below this header — they drifted once already (this copy still
# used grep/sed/find after the action had removed them) and a divergence here is
# a divergence in what CI pins. `scripts/resolve-sibling-rev-test.sh` is the
# shared contract suite and is vendored alongside it.
#
# This is the SINGLE approved source of sibling revisions for cross-repo CI and
# for local cross-repo test runs. It reads the per-commit lock snapshot that the
# workspace tooling produces for the commit under test.
#
# TWO LOCK LAYOUTS ARE SUPPORTED, because the Metacraft workspaces are midway
# through migrating from `repo-workspaces` to `reprobuild` and this action is
# shared by projects on both:
#
#   repo-workspaces (legacy)  <manifest-repo>/locks/<project>/<repo>/<sha>.xml
#     a ``repo manifest -r`` snapshot; one ``<project name=... revision=.../>``
#     element per line.
#
#   reprobuild (current)      <manifest-repo>/locks/<project>/<repo>/<sha>.toml
#     a ``schema = "reprobuild.workspace.lock.v1"`` document: a ``[lock]``
#     header table plus one ``[[repo]]`` table per pinned repo, carrying
#     ``name`` / ``path`` / ``remote`` / ``revision`` / ``branch``.
#
# The two agree on everything that matters here: the same directory key
# (project / trigger repo / full commit SHA), and the same identity for a
# sibling — its repo NAME, which may differ from its workspace path (``nim``
# lives at ``codetracer-nim``). Only the file extension and the body syntax
# differ, so both are read through one code path with two small parsers.
#
# The historical flat spelling ``locks/<project>/<repo>-<sha>.<ext>`` is also
# accepted, for both extensions.
#
# Legacy ``.github/sibling-pins`` / ``.github/sibling-pins.json`` /
# ``.github/rr-backend-pin.txt`` files and the ``locks/<project>/index.json``
# layout are NOT used: the lock keyed by the commit-under-test is the only
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
#                       .repro/manifests (reprobuild) or .repo/manifests
#                       (repo-workspaces) discovered by walking up from
#                       --repo-dir.
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
# ``--no-walk`` remains correct for CI under both layouts. It exists because CI
# checkouts are shallow, so ``git rev-list --first-parent`` sees only HEAD and
# the walk would be a no-op that merely hides the real diagnosis. Nothing in the
# reprobuild lock changes that: like the XML snapshot it records only the pinned
# revisions of the workspace at one commit, carrying no ancestry of its own, so
# it cannot substitute for history the checkout does not have.
#
# Prints the resolved revision (a commit SHA) to stdout.  Exits non-zero, with a
# diagnostic on stderr, when no lock can be found or the sibling is absent — CI
# must fail loudly rather than silently fall back to an unpinned branch tip.
#
# Exit codes:
#   2  usage error
#   3  no manifest dir, or no lock for any candidate commit
#   4  a lock was found but does not mention the sibling
#   5  a lock was found but is malformed / carries no usable revision
#   6  two locks for the SAME commit disagree about the sibling
#
# Codes 4/5/6 all mean "a lock exists but cannot be trusted to answer". They are
# deliberately distinct from 3 so a caller probing several candidate commits can
# tell "this commit is not locked" (try the next) from "this commit's lock is
# broken" (stop and report).
#
# Contract suite: ./resolve-sibling-rev-test.sh (pure bash; run it after any
# change here — this action is shared by several Metacraft projects).
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
# `.repro/manifests` (reprobuild) is checked before `.repo/manifests`
# (repo-workspaces): a workspace that has migrated keeps the old `.repo`
# directory around for a while, and the stale layer must not shadow the live
# one. A layer that exists but has no `locks/` loses to one that has it.
if [[ -z $MANIFEST_DIR ]]; then
	d="$(cd "$REPO_DIR" 2>/dev/null && pwd)" || d=""
	fallback=""
	while [[ -n $d && $d != "/" ]]; do
		if [[ -d "$d/.repro/manifests/locks" ]]; then
			MANIFEST_DIR="$d/.repro/manifests"
			break
		fi
		if [[ -d "$d/.repo/manifests/locks" ]]; then
			MANIFEST_DIR="$d/.repo/manifests"
			break
		fi
		if [[ -z $fallback && -d "$d/.repro/manifests" ]]; then
			fallback="$d/.repro/manifests"
		fi
		if [[ -z $fallback && -d "$d/.repo/manifests" ]]; then
			fallback="$d/.repo/manifests"
		fi
		d="${d%/*}"
	done
	[[ -z $MANIFEST_DIR ]] && MANIFEST_DIR="$fallback"
fi
if [[ -z $MANIFEST_DIR || ! -d "$MANIFEST_DIR/locks" ]]; then
	{
		echo "resolve-sibling-rev: cannot locate the manifest repo locks/ tree."
		echo "  Pass --manifest-dir <metacraft-manifests checkout>, set CT_MANIFEST_DIR,"
		echo "  or run from inside a workspace with .repro/manifests (reprobuild) or"
		echo "  .repo/manifests (repo-workspaces)."
		[[ -n $MANIFEST_DIR ]] && echo "  (looked at: $MANIFEST_DIR, which has no locks/ subtree)"
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

# Find the lock file(s) for a given repo@sha across all workspaces, and leave
# them in LOCK_FILES.
#
#   nested: locks/<project>/<repo>/<sha>.{xml,toml}
#   flat:   locks/<project>/<repo>-<sha>.{xml,toml}
#
# Three tie-breaks, applied in this order, narrow a commit's locks down to the
# set that must agree:
#
#   1. project — locks under the canonical project win outright over locks under
#      any other workspace.
#   2. layout — within the winning project, the nested layout wins outright over
#      the flat one. They are not two descriptions of one state: `locks/<proj>/
#      <repo>-<sha>.xml` is the HISTORICAL spelling, and where the tooling wrote
#      both for one commit the nested file is the later, canonical one. The
#      manifest repo really does carry such pairs, with the flat member stale by
#      dozens of revisions, and the flat file has always lost. Treating that as
#      an unresolvable conflict would fail commits that resolve correctly today.
#   3. extension — whatever survives is returned for ALL extensions present, so
#      an .xml and a .toml written for the same commit by the two workspace
#      tools are cross-checked against each other rather than silently resolved
#      by glob order. THIS is the migration hazard worth refusing: neither
#      spelling is the elder, so there is no basis for preferring one.
declare -a LOCK_FILES=()
find_locks() {
	local sha="$1" f proj
	local -a pref_nested=() pref_flat=() other_nested=() other_flat=()
	local other_project=""
	for f in \
		"$LOCKS_ROOT"/*/"$SELF_REPO"/"$sha.xml" \
		"$LOCKS_ROOT"/*/"$SELF_REPO"/"$sha.toml"; do
		[[ -f "$f" ]] || continue
		if [[ $f == "$LOCKS_ROOT/$PREFER_PROJECT/"* ]]; then
			pref_nested+=("$f")
			continue
		fi
		proj="${f#"$LOCKS_ROOT"/}"
		proj="${proj%%/*}"
		[[ -z $other_project ]] && other_project="$proj"
		[[ $proj == "$other_project" ]] && other_nested+=("$f")
	done
	for f in \
		"$LOCKS_ROOT"/*/"$SELF_REPO-$sha.xml" \
		"$LOCKS_ROOT"/*/"$SELF_REPO-$sha.toml"; do
		[[ -f "$f" ]] || continue
		if [[ $f == "$LOCKS_ROOT/$PREFER_PROJECT/"* ]]; then
			pref_flat+=("$f")
			continue
		fi
		proj="${f#"$LOCKS_ROOT"/}"
		proj="${proj%%/*}"
		[[ -z $other_project ]] && other_project="$proj"
		[[ $proj == "$other_project" ]] && other_flat+=("$f")
	done
	# Spelled out rather than looped over nameref'd array names: `local -n` is
	# bash 4.3+, and this script has to run under the bash 3.2 that macOS ships.
	LOCK_FILES=()
	if [[ ${#pref_nested[@]} -gt 0 ]]; then
		LOCK_FILES=("${pref_nested[@]}")
		return 0
	fi
	if [[ ${#pref_flat[@]} -gt 0 ]]; then
		LOCK_FILES=("${pref_flat[@]}")
		return 0
	fi
	if [[ ${#other_nested[@]} -gt 0 ]]; then
		LOCK_FILES=("${other_nested[@]}")
		return 0
	fi
	if [[ ${#other_flat[@]} -gt 0 ]]; then
		LOCK_FILES=("${other_flat[@]}")
		return 0
	fi
	return 1
}

# --- lock parsers ---------------------------------------------------------
#
# Both parsers answer the same question — "what revision does this lock pin for
# the repo NAMED $2?" — and share a calling convention rather than printing to
# stdout, so their diagnostics survive (a command substitution would run them in
# a subshell and lose PARSE_ERR).
#
#   return 0 -> PARSE_REV holds the revision
#   return 1 -> the sibling is not in this lock (PARSE_ERR unset)
#   return 2 -> the lock is malformed; PARSE_ERR says how
#
# Pure bash, no awk/sed/grep: this script runs inside the consumer's dev-env
# shell, which may be a minimal nix bash with no coreutils on PATH.
PARSE_REV=""
PARSE_ERR=""

# A lock pins a REVISION, and in this model a revision is a full 40-hex commit
# SHA — every one of the ~494k revisions currently in the manifest repo is,
# across both layouts. Checking the shape is not pedantry; it is the last place
# a wrong value can be stopped, because the caller substitutes this straight
# into `git fetch <remote> <rev>`:
#
#   * "main" / "refs/heads/main" would make CI build the branch TIP — the exact
#     silent, unpinned fallback this whole mechanism exists to prevent, arriving
#     disguised as a successful resolve.
#   * a value starting with `-` is not a refspec at all: `git fetch origin
#     --upload-pack=<cmd>` runs <cmd>. git parses options after the remote, so
#     this is remote code execution on the runner.
#   * quoting and syntax the small parsers below do not model — a trailing
#     `# comment`, an array, a `"""multi-line"""` string — otherwise survive as
#     plausible-looking garbage that fails much later, far from the cause.
#
# So anything that is not a bare 40-hex SHA is a malformed lock (exit 5), never
# a resolve.
check_rev_shape() {
	local rev="$1" what="$2" i c
	if [[ ${#rev} -ne 40 ]]; then
		PARSE_ERR="$what is not a 40-character commit SHA: '$rev'"
		return 1
	fi
	for ((i = 0; i < 40; i++)); do
		c="${rev:i:1}"
		case "$c" in
		[0-9a-f]) ;;
		*)
			PARSE_ERR="$what is not a hexadecimal commit SHA: '$rev'"
			return 1
			;;
		esac
	done
	return 0
}

# repo-workspaces XML: a `repo manifest -r` snapshot, one <project .../> per
# line.
rev_from_xml() {
	local lock="$1" sibling="$2" l line="" rev
	PARSE_REV=""
	PARSE_ERR=""
	while IFS= read -r l || [[ -n $l ]]; do
		if [[ $l == *"<project"* && $l == *"name=\"$sibling\""* ]]; then
			line="$l"
			break
		fi
	done <"$lock"
	if [[ -z $line ]]; then
		return 1
	fi
	# Guard the attribute's PRESENCE before slicing it out: `${line#*revision="}`
	# leaves the line untouched when there is no such attribute, and the
	# following `%%"*` would then hand back a fragment of the XML tag that looks
	# enough like a value to be passed to `git fetch`.
	if [[ $line != *'revision="'* ]]; then
		PARSE_ERR="<project name=\"$sibling\"> has no revision attribute"
		return 2
	fi
	rev="${line#*revision=\"}"
	rev="${rev%%\"*}"
	if [[ -z $rev ]]; then
		PARSE_ERR="<project name=\"$sibling\"> has an empty revision attribute"
		return 2
	fi
	check_rev_shape "$rev" "<project name=\"$sibling\"> revision" || return 2
	PARSE_REV="$rev"
	return 0
}

# reprobuild TOML: `schema = "reprobuild.workspace.lock.v1"`, a [lock] header
# table, then one [[repo]] table per pinned repo. The shape is flat and fixed
# (see reprobuild-specs/Workspace-Manifests.md), so a scanner is enough — but it
# is a strict one: anything it does not recognise is reported, never skipped.
rev_from_toml() {
	local lock="$1" sibling="$2"
	local l key val
	local schema_seen=0 in_repo=0 repo_blocks=0
	local name="" rev="" hit=0 dup=0
	PARSE_REV=""
	PARSE_ERR=""

	# Flush the [[repo]] block that just ended; sets `hit` when it is ours.
	# The whole file is scanned even after a hit, rather than stopping at the
	# first match, so that a second [[repo]] pinning the SAME name is seen. One
	# repo cannot have two revisions in one workspace; taking whichever came
	# first would be a coin toss dressed up as an answer.
	_flush() {
		if [[ $in_repo -eq 1 && $name == "$sibling" ]]; then
			if [[ $hit -eq 1 ]]; then
				dup=1
			else
				PARSE_REV="$rev"
				hit=1
			fi
		fi
		in_repo=0
		name=""
		rev=""
	}

	while IFS= read -r l || [[ -n $l ]]; do
		l="${l%$'\r'}"
		while [[ $l == [[:space:]]* ]]; do l="${l#?}"; done
		while [[ $l == *[[:space:]] ]]; do l="${l%?}"; done
		[[ -z $l ]] && continue
		[[ ${l:0:1} == "#" ]] && continue

		if [[ ${l:0:1} == "[" ]]; then
			# The schema key is a top-level key, so it must have been seen
			# before the first table header. Refusing an unknown or absent
			# schema is the point: a future lock revision must announce itself
			# rather than be half-understood by this parser.
			if [[ $schema_seen -eq 0 ]]; then
				PARSE_ERR="no top-level 'schema' key (not a reprobuild.workspace.lock.v1 document)"
				return 2
			fi
			_flush
			if [[ $l == "[[repo]]" ]]; then
				in_repo=1
				repo_blocks=$((repo_blocks + 1))
			fi
			continue
		fi

		key="${l%%=*}"
		[[ $key == "$l" ]] && continue
		val="${l#*=}"
		while [[ $key == *[[:space:]] ]]; do key="${key%?}"; done
		while [[ $val == [[:space:]]* ]]; do val="${val#?}"; done
		case "$val" in
		\"*\") val="${val#\"}" && val="${val%\"}" ;;
		\'*\') val="${val#\'}" && val="${val%\'}" ;;
		esac

		if [[ $in_repo -eq 0 ]]; then
			if [[ $key == "schema" ]]; then
				if [[ $val != "reprobuild.workspace.lock.v1" ]]; then
					PARSE_ERR="unsupported lock schema '$val' (this resolver reads reprobuild.workspace.lock.v1)"
					return 2
				fi
				schema_seen=1
			fi
			continue
		fi

		case "$key" in
		name) name="$val" ;;
		revision) rev="$val" ;;
		esac
	done <"$lock"
	_flush

	if [[ $dup -eq 1 ]]; then
		PARSE_REV=""
		PARSE_ERR="more than one [[repo]] entry pins name = \"$sibling\""
		return 2
	fi
	if [[ $schema_seen -eq 0 ]]; then
		PARSE_ERR="no top-level 'schema' key (not a reprobuild.workspace.lock.v1 document)"
		return 2
	fi
	if [[ $repo_blocks -eq 0 ]]; then
		PARSE_ERR="no [[repo]] entries (truncated lock?)"
		return 2
	fi
	if [[ $hit -eq 0 ]]; then
		return 1
	fi
	if [[ -z $PARSE_REV ]]; then
		PARSE_ERR="[[repo]] entry name = \"$sibling\" carries no revision"
		return 2
	fi
	check_rev_shape "$PARSE_REV" "[[repo]] name = \"$sibling\" revision" || {
		PARSE_REV=""
		return 2
	}
	return 0
}

# --- select the lock(s) ---------------------------------------------------
FOUND=0
# 1. direct lock on a candidate SHA (priority order)
for sha in "${SHAS[@]}"; do
	if find_locks "$sha"; then
		FOUND=1
		break
	fi
done
# 2. nearest locked first-parent ancestor (local / non-shallow only)
if [[ $FOUND -eq 0 && $NO_WALK -eq 0 ]]; then
	if anc=$(git -C "$REPO_DIR" rev-list --first-parent --max-count=400 "${SHAS[0]}" 2>/dev/null); then
		while IFS= read -r sha; do
			[[ -z $sha ]] && continue
			if find_locks "$sha"; then
				FOUND=1
				break
			fi
		done <<<"$anc"
	fi
fi

if [[ $FOUND -eq 0 ]]; then
	{
		echo "resolve-sibling-rev: no workspace lock found for $SELF_REPO"
		echo "  candidate SHAs: ${SHAS[*]}"
		echo "  searched, for each candidate <sha>:"
		echo "    $LOCKS_ROOT/*/$SELF_REPO/<sha>.xml    (repo-workspaces)"
		echo "    $LOCKS_ROOT/*/$SELF_REPO/<sha>.toml   (reprobuild)"
		echo "    $LOCKS_ROOT/*/$SELF_REPO-<sha>.xml    (legacy flat)"
		echo "    $LOCKS_ROOT/*/$SELF_REPO-<sha>.toml   (legacy flat)"
		[[ $NO_WALK -eq 0 ]] && echo "  (also walked first-parent ancestry of ${SHAS[0]})"
		echo "  Every commit under cross-repo CI must be locked by the workspace tooling"
		echo "  ('repro workspace lock' / the reprobuild post-commit + pre-push hooks, or"
		echo "  legacy 'workspace lock'). A missing lock means the commit was not published"
		echo "  through that tooling, or its lock was not pushed to the manifest repo."
	} >&2
	exit 3
fi

# --- read the sibling's revision -----------------------------------------
# When both a .xml and a .toml lock exist for the same commit they are two
# descriptions of one workspace state and must agree. If they do not, there is
# no basis for choosing between them, and picking either would hand CI a
# revision that half the tooling disputes — so refuse.
REV=""
REV_SRC=""
for LOCK in "${LOCK_FILES[@]}"; do
	rc=0
	if [[ $LOCK == *.toml ]]; then
		rev_from_toml "$LOCK" "$SIBLING" || rc=$?
	else
		rev_from_xml "$LOCK" "$SIBLING" || rc=$?
	fi
	if [[ $rc -eq 2 ]]; then
		echo "resolve-sibling-rev: malformed lock $LOCK: $PARSE_ERR" >&2
		exit 5
	fi
	this_rev=""
	[[ $rc -eq 0 ]] && this_rev="$PARSE_REV"
	if [[ -z $REV_SRC ]]; then
		REV="$this_rev"
		REV_SRC="$LOCK"
		continue
	fi
	if [[ $this_rev != "$REV" ]]; then
		{
			echo "resolve-sibling-rev: conflicting locks for $SELF_REPO — they disagree about '$SIBLING'"
			echo "  ${REV_SRC}: ${REV:-<sibling absent>}"
			echo "  ${LOCK}: ${this_rev:-<sibling absent>}"
			echo "  Both locks describe the same commit, so exactly one is stale. Remove or"
			echo "  regenerate the wrong one; this resolver will not guess which pin is correct."
		} >&2
		exit 6
	fi
done

if [[ -z $REV ]]; then
	{
		echo "resolve-sibling-rev: sibling '$SIBLING' not present in lock $REV_SRC"
		echo "  A lock exists for this commit but does not pin '$SIBLING'. Either the name is"
		echo "  wrong (siblings are keyed by repo NAME, which can differ from the workspace"
		echo "  path) or the repo is not a member of that workspace's project."
	} >&2
	exit 4
fi

printf '%s\n' "$REV"
