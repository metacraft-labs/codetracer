#!/usr/bin/env bash
# =============================================================================
# Make a repository's submodule contents visible to Nix's `path:` flake inputs.
#
# # The problem this solves
#
# `codetracer-native-backend/flake.nix` declares
#
#     rr-soft.url      = "path:libs/rr";
#     delve-patched.url = "path:libs/delve";
#
# Nix resolves a `path:` flake input inside a git repository by asking `git
# ls-files` which files exist. A submodule contributes exactly one entry to its
# parent's index -- a gitlink -- so none of the files INSIDE it are listed, and
# `nix develop <native-backend>` aborts with
#
#     error: Path 'libs/rr/flake.nix' in the repository "<dir>" is not tracked
#     by Git.
#
# The fix is to "unfold" each submodule: drop its inner `.git`, remove the
# gitlink from the parent's index, and `git add -f` the materialised files so
# `git ls-files` reports them. This is a destructive, CI-only operation on a
# throwaway clone -- it turns submodules into plain directories.
#
# # Why it is a script and not six lines inline in a workflow
#
# It was six lines inline, and it was silently broken for the entire life of
# the `Cross-Repo Integration Tests` workflow on `dev`. Its whole output was
# one line, and it succeeded:
#
#     unfolding submodule native-backend/libs/delve
#     <step succeeds, 0.13s>
#     ... four steps later ...
#     error: Path 'libs/rr/flake.nix' ... is not tracked by Git.
#
# (run 32995543471, job `rr-backend-tests`; the same shape in every run of that
# job on `dev` back to 2026-06-08.) `libs/rr` never appeared. The loop skipped
# any submodule `git submodule status` marks `-` -- UNINITIALISED -- which is
# right, since an empty directory cannot be unfolded, and then said nothing at
# all about having skipped it.
#
# It could not say which of two things had happened, either, because it was
# silent in three separate ways: the `-` branch had no diagnostic, the git
# calls carried `2>/dev/null` and `|| true`, and the enumerating command sat in
# a PROCESS SUBSTITUTION, whose exit status `set -e` cannot see. A walk that
# reported an uninitialised submodule and a walk that ABORTED partway both
# produced exactly this log and exit 0.
#
# So this script, in that order: MAKE the submodules exist -- uninitialised is
# a fixable state, not a fact about the world -- then enumerate completely
# before mutating anything, then verify the postcondition out loud. Being a
# file also makes it testable: `ci/test/unfold-submodules-test.sh` runs this
# exact script against real git repositories with real submodules.
#
# # Usage
#
#     ci/unfold-submodules.sh <repo-dir> [required-path ...]
#
# Each `required-path` is a repo-relative file that MUST be tracked when the
# unfold finishes -- name the `flake.nix` of every `path:` input, so the failure
# is reported here, by this script, instead of four steps later inside a Nix
# stack trace.
#
# Requires only git and bash: the self-hosted nixos runner's shell has a
# minimal PATH with no awk and no coreutils to spare.
# =============================================================================
set -euo pipefail

if [ "$#" -lt 1 ]; then
	echo "usage: $0 <repo-dir> [required-path ...]" >&2
	exit 2
fi

PARENT="$1"
shift
REQUIRED=("$@")

if [ ! -d "$PARENT/.git" ] && [ ! -f "$PARENT/.git" ]; then
	echo "::error::unfold-submodules: '$PARENT' is not a git repository." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 0. MAKE THE SUBMODULES EXIST.
#
# The clone that produced $PARENT already asked for submodules -- and
# `clone-siblings` asks for them OPTIONALLY (`authenticated-clone.sh
# --submodules-optional`), so a submodule that failed to fetch leaves an empty
# directory and the clone still succeeds. That is the state this script kept
# finding and silently accepting.
#
# `submodule update --init --recursive` is a no-op when everything is already
# checked out, so this costs nothing in the normal case and repairs the case
# that has kept this lane red. It is NOT fatal on its own: whether the repair
# was needed at all is answered by the postcondition check at the bottom, which
# can say something far more useful than git's own error.
# ---------------------------------------------------------------------------
if ! git -C "$PARENT" submodule update --init --recursive; then
	echo "::warning::unfold-submodules: 'git submodule update --init --recursive' failed in '$PARENT'. Continuing; the postcondition check below decides whether it mattered." >&2
fi

# ---------------------------------------------------------------------------
# 1. ENUMERATE, COMPLETELY, BEFORE TOUCHING ANYTHING.
#
# Through a temporary file rather than a pipe or a process substitution, for
# two reasons: git finishes its walk before the first `rm -rf` runs, and its
# exit status is actually observable. Under `set -e` a failed walk stops the
# script here instead of being mistaken for "no submodules".
# ---------------------------------------------------------------------------
# Not `mktemp`: this script runs as a plain workflow `run:` step, on a
# self-hosted runner whose ambient PATH is minimal -- the inline version this
# replaced carried a comment saying it had no awk, and it is not worth
# discovering in CI which other coreutils are missing. `$$` and `$RANDOM` are
# bash builtins, `RUNNER_TEMP` is set by the runner, and the directory is
# per-job, so a fixed-name collision is not reachable.
listing="${RUNNER_TEMP:-/tmp}/unfold-submodules.$$.$RANDOM.list"
# shellcheck disable=SC2064  # expand $listing now: that is the point.
trap "rm -f '$listing'" EXIT

git -C "$PARENT" submodule status --recursive >"$listing"

# `git submodule status` prints `<status-char><sha> <path> (<describe>)`, where
# the status char is ' ' (in sync), '+' (checked out at a different commit),
# 'U' (merge conflict) or '-' (NOT INITIALISED). An uninitialised submodule is
# an empty directory: there is nothing to unfold and nothing to add, and
# treating it as unfoldable would produce an empty `libs/rr` that Nix would
# reject in a more confusing way than the original error.
all_subs=()
uninitialised=()
while IFS= read -r line || [ -n "$line" ]; do
	[ -z "$line" ] && continue
	rest="${line:1}"    # drop the status char
	rest="${rest#* }"   # drop the sha
	sub="${rest%% *}"   # take the path
	[ -z "$sub" ] && continue
	if [ "${line:0:1}" = "-" ]; then
		uninitialised+=("$sub")
		continue
	fi
	all_subs+=("$sub")
done <"$listing"

if [ "${#uninitialised[@]}" -gt 0 ]; then
	echo "unfold-submodules: skipping ${#uninitialised[@]} uninitialised submodule(s): ${uninitialised[*]}"
fi

if [ "${#all_subs[@]}" -eq 0 ]; then
	echo "unfold-submodules: $PARENT has no initialised submodules; nothing to unfold."
else
	# -------------------------------------------------------------------
	# 2. Drop EVERY inner `.git` -- at every depth -- before adding anything.
	#
	# Nested submodules are why this is a separate pass. `git add -f libs/rr`
	# while `libs/rr/third-party/x/.git` still exists records the nested
	# submodule as another gitlink ("adding embedded git repository") and the
	# files under it stay invisible to `git ls-files`: the original bug, one
	# level down. `--recursive` lists a parent before its children, so the
	# reverse order is deepest-first -- which is the natural order for a
	# removal pass even though, with the add deferred to step 3, either order
	# would do.
	# -------------------------------------------------------------------
	for ((i = ${#all_subs[@]} - 1; i >= 0; i--)); do
		sub="${all_subs[$i]}"
		echo "  unfolding ${PARENT##*/}/${sub}"
		rm -rf "${PARENT:?}/${sub}/.git"
	done

	# -------------------------------------------------------------------
	# 3. Replace each TOP-LEVEL gitlink with the files beneath it.
	#
	# Only the top-level submodules appear in this repository's index; the
	# nested ones lived in their parent submodule's index, which step 2 just
	# deleted, so they are plain directories now and `git add -f <top-level>`
	# sweeps them in with everything else.
	# -------------------------------------------------------------------
	top_level=()
	for sub in "${all_subs[@]}"; do
		mode="$(git -C "$PARENT" ls-files --stage -- "$sub" | { read -r m _ || true; printf '%s' "${m:-}"; })"
		# 160000 is git's gitlink mode; anything else is not a submodule
		# entry of THIS index.
		[ "$mode" = "160000" ] && top_level+=("$sub")
	done

	for sub in "${top_level[@]}"; do
		git -C "$PARENT" rm -f --cached -- "$sub" >/dev/null
		git -C "$PARENT" add -f -- "$sub"
	done
fi

# ---------------------------------------------------------------------------
# 4. VERIFY THE POSTCONDITION, HERE, WHERE IT CAN BE EXPLAINED.
#
# Without this the next four steps run and the failure surfaces as a Nix
# evaluation stack trace with the real cause on its last line.
# ---------------------------------------------------------------------------
missing=()
for path in ${REQUIRED[@]+"${REQUIRED[@]}"}; do
	git -C "$PARENT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 ||
		missing+=("$path")
done

if [ "${#missing[@]}" -gt 0 ]; then
	echo "::error::unfold-submodules: after unfolding, these paths are still not tracked by git in '$PARENT': ${missing[*]}" >&2
	{
		echo "Nix resolves a 'path:' flake input through 'git ls-files', so it will fail with"
		echo "    error: Path '${missing[0]}' in the repository \"$PARENT\" is not tracked by Git."
		echo "Initialised submodules seen: ${all_subs[*]:-<none>}"
		echo "Uninitialised (skipped):     ${uninitialised[*]:-<none>}"
		echo "If the submodule is simply absent, the clone step did not fetch it recursively."
	} >&2
	exit 1
fi

if [ "${#REQUIRED[@]}" -gt 0 ]; then
	echo "unfold-submodules: all ${#REQUIRED[@]} required path(s) are tracked: ${REQUIRED[*]}"
fi
