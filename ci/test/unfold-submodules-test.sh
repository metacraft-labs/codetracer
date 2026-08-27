#!/usr/bin/env bash
# =============================================================================
# Contract: `ci/unfold-submodules.sh` makes EVERY submodule's contents visible
# to `git ls-files`, or fails saying so.
#
# # The defect this suite was written against
#
# `Cross-Repo Integration Tests` has never been green on `dev`. Its
# `rr-backend-tests` job died four steps after an "Unfold native-backend
# submodules into parent index" step that reported SUCCESS. The step's entire
# output was one line:
#
#     unfolding submodule native-backend/libs/delve
#     <step succeeds, 0.13s>
#     ...
#     error: Path 'libs/rr/flake.nix' in the repository
#     "/.../codetracer-native-backend" is not tracked by Git.
#
# (run 32995543471.) `libs/rr` is never mentioned. The step's loop skipped any
# submodule `git submodule status` marks `-` -- UNINITIALISED, which the
# sibling clone can legitimately leave behind because it fetches submodules
# with `--submodules-optional` -- and it had no diagnostic on that branch. The
# git calls also carried `2>/dev/null` and `|| true`, and the enumerating
# command sat in a process substitution whose exit status `set -e` cannot see,
# so an aborted walk would have looked identical. Three independent silences
# over one state.
#
# That is the shape of bug this file exists to catch: not "the unfold is
# wrong" but "the unfold is PARTIAL and says it succeeded".
#
# A CORRECTION worth recording, since it cost time: the first diagnosis here
# was that the walk aborted -- that deleting a submodule's `.git` mid-stream
# made `git submodule status --recursive` fail and stop. It does not.
# git 2.50 reports such a submodule as `-` and carries on to the next one
# (verified directly). The uninitialised branch is the reachable path, and the
# fixture below reproduces it deterministically rather than depending on
# stdio buffering.
#
# # No mocks
#
# Real `git init`, real `git submodule add`, real working trees on the real
# filesystem, and the real `ci/unfold-submodules.sh` as committed. Nothing is
# stubbed. The fixtures are built under `mktemp -d` and removed on exit.
#
# The fixture reproduces the properties that made the original bug possible:
# MORE THAN ONE submodule (a partial unfold is indistinguishable from a
# complete one when there is only one), one of them UNINITIALISED, and a NESTED
# submodule (a `git add -f` of the outer path while an inner `.git` survives
# re-adds the inner one as another gitlink -- the same defect, one level down).
#
# Run: bash ci/test/unfold-submodules-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly UNFOLD="$REPO_ROOT/ci/unfold-submodules.sh"

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

if ! command -v git >/dev/null 2>&1; then
	# A check that cannot run must say so and fail, not pass quietly: a
	# vacuous green here is worse than a red, because this suite guards a
	# lane that was silently broken for months.
	echo "SKIP-FATAL: git is not on PATH, so this contract proved nothing." >&2
	exit 1
fi

WORK="$(mktemp -d)"
readonly WORK
# shellcheck disable=SC2064  # expand $WORK now.
trap "rm -rf '$WORK'" EXIT

# Submodule adds from a local path need this on modern git.
export GIT_ALLOW_PROTOCOL="${GIT_ALLOW_PROTOCOL:-file:ssh:https}"
GIT_CFG=(-c protocol.file.allow=always -c user.name=ci -c user.email=ci@example.invalid
	-c init.defaultBranch=main -c advice.detachedHead=false -c commit.gpgsign=false)

# Create a standalone repo containing a flake.nix, the file a `path:` input
# resolves. $1 = directory, $2 = a marker written into flake.nix.
make_repo() {
	local dir="$1" marker="$2"
	mkdir -p "$dir"
	git "${GIT_CFG[@]}" init -q "$dir"
	printf '{ description = "%s"; }\n' "$marker" >"$dir/flake.nix"
	git "${GIT_CFG[@]}" -C "$dir" add -A
	git "${GIT_CFG[@]}" -C "$dir" commit -qm "$marker"
}

# Build the fixture: a parent with two submodules, the second of which itself
# has one. Mirrors codetracer-native-backend's libs/delve + libs/rr shape.
build_fixture() {
	local root="$1"
	rm -rf "$root"
	mkdir -p "$root"
	make_repo "$root/upstream-delve" delve
	make_repo "$root/upstream-inner" inner
	make_repo "$root/upstream-rr" rr
	git "${GIT_CFG[@]}" -C "$root/upstream-rr" submodule add -q "$root/upstream-inner" third-party/inner
	git "${GIT_CFG[@]}" -C "$root/upstream-rr" commit -qm "add nested submodule"

	git "${GIT_CFG[@]}" init -q "$root/parent"
	printf '{ inputs.rr.url = "path:libs/rr"; }\n' >"$root/parent/flake.nix"
	git "${GIT_CFG[@]}" -C "$root/parent" add -A
	git "${GIT_CFG[@]}" -C "$root/parent" commit -qm init
	git "${GIT_CFG[@]}" -C "$root/parent" submodule add -q "$root/upstream-delve" libs/delve
	git "${GIT_CFG[@]}" -C "$root/parent" submodule add -q "$root/upstream-rr" libs/rr
	git "${GIT_CFG[@]}" -C "$root/parent" commit -qm "add submodules"
	git "${GIT_CFG[@]}" -C "$root/parent" submodule update -q --init --recursive
}

tracked() { # $1 = repo, $2 = path -> 0 when git ls-files reports it
	git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 0. THE ORIGINAL BUG, REPRODUCED.
#
# The CI state was a repository whose `libs/rr` was UNINITIALISED -- the clone
# asked for submodules optionally, so a submodule that did not fetch leaves an
# empty directory and a successful clone. Running the loop the workflow used to
# inline against exactly that state reproduces the CI log character for
# character: one `unfolding` line, exit 0, and `libs/rr/flake.nix` untracked.
#
# If this ever stops reproducing, the fixture no longer exercises the failure
# and every assertion below is measuring nothing, so it is asserted rather than
# assumed.
# ---------------------------------------------------------------------------
echo "the pre-fix inline loop is still reproducibly broken (fixture is honest)"

build_fixture "$WORK/regression"
# The state the sibling clone left behind: one submodule present, one not.
git "${GIT_CFG[@]}" -C "$WORK/regression/parent" submodule deinit -q -f libs/rr

buggy_rc=0
buggy_out="$(
	set -uo pipefail
	PARENT="$WORK/regression/parent"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		[[ "${line:0:1}" == "-" ]] && continue
		rest="${line:1}"
		rest="${rest#* }"
		sub="${rest%% *}"
		[[ -z "$sub" ]] && continue
		echo "  unfolding submodule ${sub}"
		rm -rf "$PARENT/${sub}/.git"
		git -C "$PARENT" rm -f --cached "${sub}" >/dev/null 2>&1 || true
		git -C "$PARENT" add -f "${sub}" 2>/dev/null || true
	done < <(git -C "$PARENT" submodule status --recursive 2>/dev/null)
	exit 0
)" || buggy_rc=$?

if [ "$buggy_rc" -eq 0 ]; then
	ok "the pre-fix loop still exits 0 (it never reported its own failure)"
else
	fail "the pre-fix loop still exits 0 (it never reported its own failure)" \
		"got exit $buggy_rc; the point of the original defect was that it did NOT fail."
fi

case "$buggy_out" in
*"libs/rr"*)
	fail "the pre-fix loop never mentions the submodule it skipped" \
		"The fixture no longer reproduces the defect this suite exists for, so the" \
		"assertions below prove nothing about it: the loop was supposed to be SILENT" \
		"about the uninitialised submodule, which is what made the CI log a single" \
		"'unfolding libs/delve' line and a green step." \
		"$buggy_out"
	;;
*) ok "the pre-fix loop never mentions the submodule it skipped" ;;
esac

if tracked "$WORK/regression/parent" libs/rr/flake.nix; then
	fail "the pre-fix loop leaves libs/rr/flake.nix untracked" \
		"which is the exact precondition of the Nix error four steps later:" \
		"error: Path 'libs/rr/flake.nix' ... is not tracked by Git."
else
	ok "the pre-fix loop leaves libs/rr/flake.nix untracked, silently"
fi

# ---------------------------------------------------------------------------
# 0b. THE FIX, AGAINST THE SAME STATE.
#
# The script's job is not to REPORT that state -- reporting it would only move
# the red four steps earlier. An uninitialised submodule is repairable, so the
# script repairs it and the lane goes green.
# ---------------------------------------------------------------------------
echo
echo "ci/unfold-submodules.sh repairs the state the pre-fix loop skipped"

build_fixture "$WORK/deinit"
git "${GIT_CFG[@]}" -C "$WORK/deinit/parent" submodule deinit -q -f libs/rr
out="$(bash "$UNFOLD" "$WORK/deinit/parent" libs/rr/flake.nix libs/delve/flake.nix 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
	ok "it exits 0 against a repository with an uninitialised submodule"
else
	fail "it exits 0 against a repository with an uninitialised submodule" "exit $rc" "$out"
fi

if tracked "$WORK/deinit/parent" libs/rr/flake.nix; then
	ok "the deinitialised submodule is re-initialised and unfolded"
else
	fail "the deinitialised submodule is re-initialised and unfolded" \
		"This is the case the whole lane has been failing on since 2026-06-08." "$out"
fi

# ---------------------------------------------------------------------------
# 1. The script unfolds EVERY submodule, including the nested one.
# ---------------------------------------------------------------------------
echo
echo "ci/unfold-submodules.sh unfolds every submodule"

build_fixture "$WORK/happy"
out="$(bash "$UNFOLD" "$WORK/happy/parent" libs/rr/flake.nix libs/delve/flake.nix 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
	ok "it exits 0 on a fully-initialised repository"
else
	fail "it exits 0 on a fully-initialised repository" "exit $rc" "$out"
fi

for p in libs/delve/flake.nix libs/rr/flake.nix libs/rr/third-party/inner/flake.nix; do
	if tracked "$WORK/happy/parent" "$p"; then
		ok "git ls-files reports $p"
	else
		fail "git ls-files reports $p" \
			"This is exactly what Nix asks for when resolving a 'path:' flake input." \
			"$out"
	fi
done

# A nested submodule that survives as a gitlink is the original bug one level
# down: `git ls-files` shows the PATH but Nix still cannot see inside it.
inner_mode="$(git -C "$WORK/happy/parent" ls-files --stage -- libs/rr/third-party/inner | { read -r m _ || true; printf '%s' "${m:-}"; })"
if [ "$inner_mode" != "160000" ]; then
	ok "the nested submodule is not re-added as a gitlink (mode '${inner_mode:-<none>}')"
else
	fail "the nested submodule is not re-added as a gitlink" \
		"mode 160000 means 'git add -f' recorded another submodule reference," \
		"so the files under it remain invisible to Nix."
fi

# ---------------------------------------------------------------------------
# 2. It FAILS LOUDLY when a required path cannot be produced.
#
# The property the original step lacked. Asserted against a repository with no
# submodules at all, which is the state a non-recursive clone leaves behind --
# the realistic way this precondition breaks.
# ---------------------------------------------------------------------------
echo
echo "it fails loudly rather than passing a partial unfold downstream"

make_repo "$WORK/bare-parent" parent-only
out="$(bash "$UNFOLD" "$WORK/bare-parent" libs/rr/flake.nix 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
	ok "a required path that cannot be produced is a non-zero exit"
else
	fail "a required path that cannot be produced is a non-zero exit" \
		"It exited 0 having not tracked libs/rr/flake.nix -- the same silent partial" \
		"success the inline loop had." "$out"
fi

case "$out" in
*"libs/rr/flake.nix"*) ok "the diagnostic names the path that is missing" ;;
*) fail "the diagnostic names the path that is missing" "$out" ;;
esac

# ---------------------------------------------------------------------------
# 3. An UNREPAIRABLE submodule fails loudly, and does not take the others with
#    it.
#
# Repair is a fetch, and a fetch can fail -- an upstream that is gone, an
# unauthenticated private submodule, a full disk. The contract is that this
# ends as a named failure here rather than as a Nix stack trace later, and that
# the submodules that COULD be unfolded still were, so the diagnostic is about
# one repo and not about the whole set.
# ---------------------------------------------------------------------------
echo
echo "an unrepairable submodule is a named failure, not a silent skip"

build_fixture "$WORK/broken"
git "${GIT_CFG[@]}" -C "$WORK/broken/parent" submodule deinit -q -f libs/rr
# Make the repair impossible. `submodule deinit` leaves the objects behind in
# `.git/modules/<name>`, so a re-init succeeds offline -- which is realistic
# for a warm runner and useless as a test of the failure path. Removing the
# module store as well as the upstream is what a FRESH clone of a repository
# whose submodule cannot be fetched actually looks like.
rm -rf "$WORK/broken/upstream-rr" "$WORK/broken/parent/.git/modules/libs/rr"
out="$(bash "$UNFOLD" "$WORK/broken/parent" libs/rr/flake.nix libs/delve/flake.nix 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
	ok "an unfetchable submodule is a non-zero exit"
else
	fail "an unfetchable submodule is a non-zero exit" \
		"exit 0 here is the original defect: a green step and a Nix failure downstream." \
		"$out"
fi

case "$out" in
*"libs/rr/flake.nix"*) ok "the diagnostic names the path that could not be produced" ;;
*) fail "the diagnostic names the path that could not be produced" "$out" ;;
esac

if tracked "$WORK/broken/parent" libs/delve/flake.nix; then
	ok "the submodules that could be unfolded still were"
else
	fail "the submodules that could be unfolded still were" \
		"One unfetchable submodule must not abandon the rest; the report is about" \
		"libs/rr, and saying nothing about libs/delve would make it ambiguous." "$out"
fi

# ---------------------------------------------------------------------------
# 4. Idempotence: CI re-runs on a warm self-hosted runner re-enter this step
#    against a tree a previous run already unfolded.
# ---------------------------------------------------------------------------
echo
echo "running it twice is the same as running it once"

out="$(bash "$UNFOLD" "$WORK/happy/parent" libs/rr/flake.nix libs/delve/flake.nix 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && tracked "$WORK/happy/parent" libs/rr/flake.nix; then
	ok "a second run over an already-unfolded tree still succeeds"
else
	fail "a second run over an already-unfolded tree still succeeds" "exit $rc" "$out"
fi

# ---------------------------------------------------------------------------
# Self-accounting.
# ---------------------------------------------------------------------------
echo
readonly EXPECTED_ASSERTIONS=16
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
