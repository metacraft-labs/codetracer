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
# A THIRD kind of file shares that ``.toml`` namespace and is NOT a lock: the
# per-repo participation record reprobuild's ROUTED locking mode writes (see
# ``is_participation_record`` below). It pins only the repo whose directory it
# sits in, so it can never answer a question about a sibling. It is recognised
# and IGNORED, which makes such a commit read as UNLOCKED (exit 3) rather than
# as carrying a broken lock (exit 5).
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
# MANIFEST LAYERS (public / org / team / personal)
# -----------------------------------------------
#
# A workspace's repo set is not necessarily described by ONE manifest repo.
# ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §"Workspace Composition and
# Manifest Layers" specifies a layered model: a public manifest repo defines the
# base repo set, an org/team-private manifest repo (access-controlled,
# VCS-backed, REQUIRED when private repos participate) extends it, and a
# personal manifest repo or purely local workspace metadata sits on top. Repos
# declared in several layers are deduplicated, "with the more specific (private)
# layer taking precedence for overrides".
#
# ``--manifest-dir`` is therefore REPEATABLE, and the order is the precedence
# order: LEAST specific first (public), MOST specific last (private/personal).
# Passing it once is exactly the single-layer behaviour this resolver has always
# had — nothing changes for a caller that names one manifest repo.
#
# Across layers, for the one commit selected below:
#
#   * every layer that carries a lock for that commit is consulted;
#   * a MALFORMED lock (exit 5) or a lock pair that CONTRADICTS itself inside
#     one layer (exit 6) still fails the whole resolve. Untrustworthy data is
#     never skipped in favour of a layer that happens to look healthier;
#   * a layer whose lock simply does not name the sibling contributes nothing.
#     This is the normal case for a private layer that pins only private repos,
#     and is NOT the intra-layer exit-4 condition;
#   * when more than one layer pins the sibling, the MOST SPECIFIC (last) one
#     wins and the shadowing is reported on stderr. This is the spec's override
#     rule, not a coin toss: unlike the xml-vs-toml case inside one layer, the
#     layers are explicitly ordered by the caller;
#   * when NO layer pins it although some layer had a lock, that is exit 4.
#
# Usage:
#   resolve-sibling-rev.sh --repo SELF --sibling NAME \
#       [--manifest-dir DIR]... [--sha COMMIT]... [--repo-dir DIR] \
#       [--prefer-project PROJECT] [--no-walk]
#
#   --repo SELF         repo under test (e.g. codetracer, codetracer-ci)
#   --sibling NAME      sibling repo whose revision to print
#   --manifest-dir DIR  manifest-repo checkout containing locks/.  REPEATABLE;
#                       least-specific layer first, most-specific last.
#                       Default: $CT_MANIFEST_DIR (+ $CT_PRIVATE_MANIFEST_DIR
#                       layered on top of it), else the layers discovered by
#                       walking up from --repo-dir (see below).
#   --sha COMMIT        candidate commit(s) whose lock to use, in priority order.
#                       Repeatable.  Default: HEAD of --repo-dir.
#   --repo-dir DIR      working copy of SELF (for HEAD + ancestry walk).
#                       Default: current directory.
#   --prefer-project P  workspace/project to prefer when several match.
#                       Default: the value of --repo (its canonical workspace).
#   --no-walk           do not walk ancestry; require a direct lock on a
#                       candidate SHA (used by shallow CI checkouts).
#
# Auto-discovered layers, in precedence order (least → most specific), at the
# nearest enclosing workspace root:
#
#   .repro/manifests              the public manifest checkout (reprobuild), or
#   .repo/manifests               the legacy repo-workspaces one when the
#                                 reprobuild layer carries no locks/
#   .repro/manifests-<n>-<slug>   URL-backed ``[[manifest]]`` layers, ordered by
#                                 ``<n>`` NUMERICALLY (the layer's index in the
#                                 workspace's ``[[manifest]]`` array) — not by
#                                 glob order, which would sort ``manifests-10-x``
#                                 ahead of ``manifests-2-x``
#   .repro/manifests-private      the RA-11 private companion manifest checkout
#                                 (``[manifest] private_url`` /
#                                 ``.repro-workspace-private.toml``)
#
# The extra layers are picked up under ``.repro/`` whichever base won, so a
# legacy ``.repo/manifests`` base does not silently drop a private companion.
# A ``.repro/manifests-<name>`` directory whose name does NOT encode an index
# (a hand-written ``local_path`` such as ``manifests-team``) cannot be ordered
# from disk at all, so auto-discovery REFUSES (exit 3) and asks for explicit
# ``--manifest-dir`` layers rather than guessing.
#
# Resolution order for the COMMIT whose lock to read (one commit for every
# layer — the layers describe one workspace state, so they must be read at the
# same commit or they are not layers at all):
#   1. Each --sha candidate, in order, for which ANY layer has a lock.
#   2. Otherwise (unless --no-walk), the nearest first-parent ancestor of the
#      first candidate for which any layer has a lock.  This makes local runs
#      work even when HEAD is unpushed (hence unlocked): siblings are unchanged
#      since the last locked ancestor, so its pin is correct.
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
#   4  a lock was found but no layer mentions the sibling
#   5  a lock was found but is malformed / carries no usable revision
#   6  two locks for the SAME commit IN ONE LAYER disagree about the sibling
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
REPO_DIR="."
PREFER_PROJECT=""
NO_WALK=0
declare -a SHAS=()
# Manifest layers, least specific first. `--manifest-dir` appends; when none is
# given, $CT_MANIFEST_DIR and then auto-discovery fill this in below.
declare -a MANIFEST_DIRS=()

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
		MANIFEST_DIRS+=("$2")
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

# --- locate the manifest layers (locks/ trees) ----------------------------
#
# `.repro/manifests` (reprobuild) is checked before `.repo/manifests`
# (repo-workspaces): a workspace that has migrated keeps the old `.repo`
# directory around for a while, and the stale layer must not shadow the live
# one. A layer that exists but has no `locks/` loses to one that has it.
#
# On top of that PUBLIC base, auto-discovery also picks up the private layers a
# reprobuild workspace materialises next to it (Workspace-And-Develop-Mode.md
# §"Manifest Sources"; the on-disk names are RA-11's):
#
#   .repro/manifests-<n>-<slug>   URL-backed `[[manifest]]` layers
#   .repro/manifests-private      the `[manifest] private_url` companion
#
# They are appended AFTER the public layer, so they take precedence over it —
# and `-private` is appended last of all, because it is the most specific layer
# a workspace can have on disk. A layer with no `locks/` subtree is skipped
# rather than reported: an org manifest that carries only `projects/` fragments
# and no lock records is a normal, complete layer, it just has nothing to say
# about revisions.
#
# The `<n>` in `manifests-<n>-<slug>` is the layer's index in the workspace's
# `[[manifest]]` array (`repro_workspace_manifests/compose.nim` builds the name
# as "manifests-" & $index & "-" & sanitizeForPath(url)), and THAT is the
# precedence order — not the alphabet. Glob order sorts `manifests-10-x` before
# `manifests-2-x`, which would silently invert precedence for any workspace with
# ten or more URL-backed layers, so the numbered layers are sorted on `<n>`
# numerically below.
#
# A `manifests-<something>` directory whose name does NOT encode an index —
# a hand-written `local_path` such as `.repro/manifests-team` or
# `.repro/manifests-personal` — carries no orderable information at all: its
# position lives only in the workspace config's `[[manifest]]` array. Ordering
# such layers alphabetically would make `manifests-team` override
# `manifests-personal`, which is backwards, and it would be a guess either way.
# Auto-discovery therefore REFUSES rather than choosing, and tells the caller to
# order the layers explicitly with `--manifest-dir`. Skipping the layer instead
# would be the silent downgrade to a less specific answer that the whole layering
# model exists to prevent.
FROM_ENV=0
if [[ ${#MANIFEST_DIRS[@]} -eq 0 && -n ${CT_MANIFEST_DIR:-} ]]; then
	MANIFEST_DIRS+=("$CT_MANIFEST_DIR")
	FROM_ENV=1
fi
# The env-var spelling of the private layer, for callers that address the
# manifest checkouts through the environment rather than through flags
# (`ci/setup-rr-backend.sh`, `scripts/run-cross-repo-tests.sh`). It composes on
# top of $CT_MANIFEST_DIR exactly as a second `--manifest-dir` would. It applies
# ONLY when the base layer also came from the environment: a caller that names
# its layers on the command line gets exactly those layers and no other.
if [[ $FROM_ENV -eq 1 && -n ${CT_PRIVATE_MANIFEST_DIR:-} ]]; then
	MANIFEST_DIRS+=("$CT_PRIVATE_MANIFEST_DIR")
fi
AUTO_LOOKED=""
if [[ ${#MANIFEST_DIRS[@]} -eq 0 ]]; then
	d="$(cd "$REPO_DIR" 2>/dev/null && pwd)" || d=""
	base=""
	fallback=""
	while [[ -n $d && $d != "/" ]]; do
		if [[ -d "$d/.repro/manifests/locks" ]]; then
			base="$d/.repro/manifests"
			break
		fi
		if [[ -d "$d/.repo/manifests/locks" ]]; then
			base="$d/.repo/manifests"
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
	[[ -z $base ]] && base="$fallback"
	if [[ -n $base ]]; then
		MANIFEST_DIRS+=("$base")
		AUTO_LOOKED="$base"
		# The extra layers always live under `.repro/`, whichever base won.
		# A legacy `.repo/manifests` base does NOT suppress them: a workspace
		# midway through the migration can easily have a lock-carrying
		# `.repo/manifests` beside a `.repro/manifests-private`, and dropping
		# the private layer because the BASE happens to be the legacy one is
		# exactly the silent downgrade to public-only that the CI path treats
		# as fatal.
		wsroot="${base%/*}" # .../.repo or .../.repro
		wsroot="${wsroot%/*}"
		declare -a XD=() XN=()
		AMBIG=""
		for extra in "$wsroot"/.repro/manifests-*; do
			[[ -d "$extra/locks" ]] || continue
			[[ $extra == */manifests-private ]] && continue
			leaf="${extra##*/}"
			rest="${leaf#manifests-}"
			num="${rest%%-*}"
			okn=1
			# `manifests-<n>-<slug>`: <n> must be present, non-empty, all
			# digits, and actually followed by a `-<slug>`.
			[[ -z $num || $num == "$rest" ]] && okn=0
			if [[ $okn -eq 1 ]]; then
				for ((i = 0; i < ${#num}; i++)); do
					case "${num:i:1}" in
					[0-9]) ;;
					*)
						okn=0
						break
						;;
					esac
				done
			fi
			if [[ $okn -eq 0 ]]; then
				AMBIG="${AMBIG}
    ${extra}"
				continue
			fi
			XD+=("$extra")
			XN+=("$((10#$num))")
		done
		if [[ -n $AMBIG ]]; then
			{
				echo "resolve-sibling-rev: cannot order the auto-discovered manifest layers.$AMBIG"
				echo "  A '.repro/manifests-<name>' layer whose name does not encode its"
				echo "  '[[manifest]]' index (the 'manifests-<n>-<slug>' spelling) carries no"
				echo "  precedence information — its position lives only in the workspace config."
				echo "  Guessing an order here would silently pick a pin; ordering alphabetically"
				echo "  would put 'manifests-team' ahead of 'manifests-personal', which is backwards."
				echo "  Pass the layers explicitly instead, least specific first:"
				echo "    --manifest-dir <public> [--manifest-dir <next>]... --manifest-dir <most specific>"
			} >&2
			exit 3
		fi
		# Selection sort on the `[[manifest]]` index. Glob order is
		# lexicographic, which puts `manifests-10-x` BEFORE `manifests-2-x` and
		# would silently invert precedence at ten or more layers. Pure bash: no
		# `sort` on PATH is assumed.
		xn=${#XD[@]}
		for ((a = 0; a < xn; a++)); do
			m=$a
			for ((b = a + 1; b < xn; b++)); do
				[[ ${XN[b]} -lt ${XN[m]} ]] && m=$b
			done
			if [[ $m -ne $a ]]; then
				t="${XN[a]}"
				XN[a]="${XN[m]}"
				XN[m]="$t"
				t="${XD[a]}"
				XD[a]="${XD[m]}"
				XD[m]="$t"
			fi
		done
		for ((a = 0; a < xn; a++)); do
			MANIFEST_DIRS+=("${XD[a]}")
		done
		# `-private` is the most specific layer a workspace can have on disk.
		if [[ -d "$wsroot/.repro/manifests-private/locks" ]]; then
			MANIFEST_DIRS+=("$wsroot/.repro/manifests-private")
		fi
	fi
fi

# Keep only the layers that actually carry a locks/ tree, preserving order.
declare -a LOCKS_ROOTS=()
declare -a LAYER_DIRS=()
for md in ${MANIFEST_DIRS[@]+"${MANIFEST_DIRS[@]}"}; do
	[[ -n $md && -d "$md/locks" ]] || continue
	LOCKS_ROOTS+=("$md/locks")
	LAYER_DIRS+=("$md")
done
if [[ ${#LOCKS_ROOTS[@]} -eq 0 ]]; then
	{
		echo "resolve-sibling-rev: cannot locate the manifest repo locks/ tree."
		echo "  Pass --manifest-dir <metacraft-manifests checkout> (repeatable, least-"
		echo "  specific layer first), set CT_MANIFEST_DIR, or run from inside a"
		echo "  workspace with .repro/manifests (reprobuild) or .repo/manifests"
		echo "  (repo-workspaces)."
		for md in ${MANIFEST_DIRS[@]+"${MANIFEST_DIRS[@]}"}; do
			[[ -n $md ]] && echo "  (looked at: $md, which has no locks/ subtree)"
		done
		[[ -n $AUTO_LOOKED ]] && echo "  (auto-discovery reached: $AUTO_LOOKED)"
	} >&2
	exit 3
fi

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
# ROUTED PER-REPO PARTICIPATION RECORDS (not locks)
# -------------------------------------------------
#
# `repro locking adopt-manifest` puts a workspace into ROUTED mode (an explicit
# `[locking] route` in the repo's VCS-private reprobuild config). In that mode
# reprobuild's HL-2 tier isolation deliberately stops writing the monolithic
# all-repos lock document — that document is the cross-tier leak it exists to
# prevent — and `recordRoutedParticipation` instead writes ONE MINIMAL RECORD
# PER REPO, through that repo's routed backend. The git-checkout backend's
# records land in the SAME `locks/<project>/<repo>/<sha>.toml` namespace as the
# lock documents, and their whole body is (reprobuild's
# `routedParticipationBody`):
#
#     [[repo]]
#     name = "<repo>"
#     path = "<workspace path>"
#     revision = "<sha>"
#
# That is not a workspace lock and cannot be read as one: it announces no
# schema, and it pins ONLY the repo whose directory it sits in. It cannot
# answer "what revision is sibling S at for commit C" because nothing in it,
# or keyed to C, mentions S at all. Reprobuild itself treats it as a separate
# thing — its strict `readLock` rejects the body and only the lenient
# `shasFromBody` accepts it.
#
# Fed to `rev_from_toml` these records fail as "no top-level 'schema' key" and
# the resolver exits 5. That is the wrong answer and an actively dangerous one:
# exit 5 means "a lock exists but cannot be trusted", which callers escalate to
# a job abort, whereas the truth is the strictly milder "this commit has no
# workspace lock" (exit 3), which every caller already degrades from gracefully.
# 98 such records, covering 96 repos, are already published under
# `locks/codetracer/` in metacraft-labs/metacraft-manifests@latest, so this is
# not hypothetical and cannot be fixed by changing what reprobuild writes NEXT.
#
# So they are recognised HERE, at discovery, and excluded from the lock set —
# which is strictly better than parsing them into an exit 4, because a commit
# whose only record is routed then falls through to the NEXT candidate SHA (the
# parent) exactly as an unlocked commit does, instead of stopping the probe.
#
# The recognition is SEMANTIC, not a syntax fingerprint, so it does not break
# the first time reprobuild adds a key to the record:
#
#   * the document announces no top-level `schema`, AND
#   * every table in it is `[[repo]]`, AND
#   * the only repo NAME it pins is $SELF_REPO itself.
#
# A schema-less document that names some OTHER repo is not a participation
# record — it is a lock document that failed to declare itself — and must still
# be refused loudly (exit 5). Likewise a document that DOES declare a schema is
# a lock, and a one-repo workspace's lock is answered normally.
is_participation_record() { # $1 = .toml file
	local file="$1" l key val
	local tables=0 repo_tables=0 names=0 foreign=0

	while IFS= read -r l || [[ -n $l ]]; do
		l="${l%$'\r'}"
		while [[ $l == [[:space:]]* ]]; do l="${l#?}"; done
		while [[ $l == *[[:space:]] ]]; do l="${l%?}"; done
		[[ -z $l ]] && continue
		[[ ${l:0:1} == "#" ]] && continue

		if [[ ${l:0:1} == "[" ]]; then
			tables=$((tables + 1))
			[[ $l == "[[repo]]" ]] && repo_tables=$((repo_tables + 1))
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

		# A top-level `schema` (i.e. before any table header) makes this a lock
		# document, whatever else it contains.
		if [[ $tables -eq 0 && $key == "schema" ]]; then
			return 1
		fi
		if [[ $key == "name" ]]; then
			names=$((names + 1))
			[[ $val != "$SELF_REPO" ]] && foreign=1
		fi
	done <"$file"

	# At least one [[repo]], nothing but [[repo]] tables, at least one name, and
	# no name other than our own.
	[[ $repo_tables -gt 0 && $tables -eq $repo_tables && $names -gt 0 && $foreign -eq 0 ]]
}

# `find_locks <locks-root> <sha>` — the search is per LAYER, because each layer
# is its own manifest repo with its own `locks/` tree; the three tie-breaks
# below narrow ONE layer's locks for one commit. Ordering BETWEEN layers is the
# caller's explicit `--manifest-dir` order and is applied further down.
declare -a LOCK_FILES=()
# Routed participation records passed over while searching, so the exit-3
# diagnostic can name them instead of reporting a bare "nothing found" for a
# commit that visibly has files on disk.
declare -a SKIPPED_PARTICIPATION=()
find_locks() {
	local locks_root="$1" sha="$2" f proj
	local -a pref_nested=() pref_flat=() other_nested=() other_flat=()
	local other_project=""
	for f in \
		"$locks_root"/*/"$SELF_REPO"/"$sha.xml" \
		"$locks_root"/*/"$SELF_REPO"/"$sha.toml"; do
		[[ -f $f ]] || continue
		if [[ $f == *.toml ]] && is_participation_record "$f"; then
			SKIPPED_PARTICIPATION+=("$f")
			continue
		fi
		if [[ $f == "$locks_root/$PREFER_PROJECT/"* ]]; then
			pref_nested+=("$f")
			continue
		fi
		proj="${f#"$locks_root"/}"
		proj="${proj%%/*}"
		[[ -z $other_project ]] && other_project="$proj"
		[[ $proj == "$other_project" ]] && other_nested+=("$f")
	done
	for f in \
		"$locks_root"/*/"$SELF_REPO-$sha.xml" \
		"$locks_root"/*/"$SELF_REPO-$sha.toml"; do
		[[ -f $f ]] || continue
		if [[ $f == *.toml ]] && is_participation_record "$f"; then
			SKIPPED_PARTICIPATION+=("$f")
			continue
		fi
		if [[ $f == "$locks_root/$PREFER_PROJECT/"* ]]; then
			pref_flat+=("$f")
			continue
		fi
		proj="${f#"$locks_root"/}"
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

# --- select the commit whose locks to read --------------------------------
#
# ONE commit is chosen for ALL layers. The layers are descriptions of the same
# workspace state at the same commit, so reading the public layer at HEAD and a
# private layer at some older ancestor would compose two different workspaces
# into one answer. The candidate list is therefore built first, and the first
# candidate that ANY layer has a lock for is the commit every layer is then read
# at.
declare -a CANDIDATES=("${SHAS[@]}")
# The nearest first-parent ancestors (local / non-shallow only) extend the
# candidate list rather than forming a second search pass, so the "same commit
# for every layer" rule holds for the walk too.
if [[ $NO_WALK -eq 0 ]]; then
	if anc=$(git -C "$REPO_DIR" rev-list --first-parent --max-count=400 "${SHAS[0]}" 2>/dev/null); then
		while IFS= read -r ancsha; do
			[[ -z $ancsha ]] && continue
			CANDIDATES+=("$ancsha")
		done <<<"$anc"
	fi
fi

CHOSEN_SHA=""
for sha in "${CANDIDATES[@]}"; do
	for lr in "${LOCKS_ROOTS[@]}"; do
		if find_locks "$lr" "$sha"; then
			CHOSEN_SHA="$sha"
			break
		fi
	done
	[[ -n $CHOSEN_SHA ]] && break
done

if [[ -z $CHOSEN_SHA ]]; then
	{
		echo "resolve-sibling-rev: no workspace lock found for $SELF_REPO"
		echo "  candidate SHAs: ${SHAS[*]}"
		echo "  searched, for each candidate <sha>, in every manifest layer:"
		for lr in "${LOCKS_ROOTS[@]}"; do
			echo "    $lr/*/$SELF_REPO/<sha>.xml    (repo-workspaces)"
			echo "    $lr/*/$SELF_REPO/<sha>.toml   (reprobuild)"
			echo "    $lr/*/$SELF_REPO-<sha>.xml    (legacy flat)"
			echo "    $lr/*/$SELF_REPO-<sha>.toml   (legacy flat)"
		done
		[[ $NO_WALK -eq 0 ]] && echo "  (also walked first-parent ancestry of ${SHAS[0]})"
		if [[ ${#SKIPPED_PARTICIPATION[@]} -gt 0 ]]; then
			echo "  Ignored ${#SKIPPED_PARTICIPATION[@]} routed per-repo participation record(s):"
			for f in "${SKIPPED_PARTICIPATION[@]}"; do
				echo "    $f"
			done
			echo "  Those are written by reprobuild's ROUTED locking mode ('repro locking"
			echo "  adopt-manifest'), which by design does not write the monolithic workspace"
			echo "  lock document. Each record pins only '$SELF_REPO' itself, so none of them"
			echo "  can name a sibling. Treated exactly as a missing lock, never as a broken"
			echo "  one. To make these commits resolvable, the workspace must publish a"
			echo '  workspace-lock document (schema = "reprobuild.workspace.lock.v1") for the'
			echo "  public tier alongside the routed records."
		fi
		echo "  Every commit under cross-repo CI must be locked by the workspace tooling"
		echo "  ('repro workspace lock' / the reprobuild post-commit + pre-push hooks, or"
		echo "  legacy 'workspace lock'). A missing lock means the commit was not published"
		echo "  through that tooling, or its lock was not pushed to the manifest repo."
	} >&2
	exit 3
fi

# --- read the sibling's revision, layer by layer --------------------------
#
# Within ONE layer: when both a .xml and a .toml lock exist for the same commit
# they are two descriptions of one workspace state and must agree. If they do
# not, there is no basis for choosing between them, and picking either would
# hand CI a revision that half the tooling disputes — so refuse (exit 6).
#
# Across layers: the caller ordered them, so a more specific layer legitimately
# OVERRIDES a less specific one (Workspace-And-Develop-Mode.md §"Layering
# Rules"). The override is announced on stderr; stdout still carries only the
# winning revision.
REV=""
REV_SRC=""
CONSULTED=""
for lr in "${LOCKS_ROOTS[@]}"; do
	find_locks "$lr" "$CHOSEN_SHA" || continue
	LAYER_REV=""
	LAYER_SRC=""
	for LOCK in "${LOCK_FILES[@]}"; do
		CONSULTED="${CONSULTED}
    ${LOCK}"
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
		if [[ -z $LAYER_SRC ]]; then
			LAYER_REV="$this_rev"
			LAYER_SRC="$LOCK"
			continue
		fi
		if [[ $this_rev != "$LAYER_REV" ]]; then
			{
				echo "resolve-sibling-rev: conflicting locks for $SELF_REPO — they disagree about '$SIBLING'"
				echo "  ${LAYER_SRC}: ${LAYER_REV:-<sibling absent>}"
				echo "  ${LOCK}: ${this_rev:-<sibling absent>}"
				echo "  Both locks describe the same commit in the SAME manifest layer, so exactly"
				echo "  one is stale. Remove or regenerate the wrong one; this resolver will not"
				echo "  guess which pin is correct."
			} >&2
			exit 6
		fi
	done
	# A layer that has a lock but does not name the sibling contributes nothing.
	# That is the normal shape of a private layer pinning only private repos —
	# not a failure, as long as some layer does name it.
	[[ -z $LAYER_REV ]] && continue
	if [[ -n $REV && $LAYER_REV != "$REV" ]]; then
		{
			echo "resolve-sibling-rev: '$SIBLING' overridden by a more specific manifest layer"
			echo "  ${REV_SRC}: ${REV}"
			echo "  ${LAYER_SRC}: ${LAYER_REV}  <- used"
		} >&2
	fi
	REV="$LAYER_REV"
	REV_SRC="$LAYER_SRC"
done

if [[ -z $REV ]]; then
	{
		echo "resolve-sibling-rev: sibling '$SIBLING' not present in lock${CONSULTED}"
		echo "  A lock exists for this commit but no manifest layer pins '$SIBLING'. Either"
		echo "  the name is wrong (siblings are keyed by repo NAME, which can differ from the"
		echo "  workspace path) or the repo is not a member of that workspace's project."
	} >&2
	exit 4
fi

printf '%s\n' "$REV"
