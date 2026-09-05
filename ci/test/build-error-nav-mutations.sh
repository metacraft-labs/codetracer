#!/usr/bin/env bash
#
# build-error-nav-mutations.sh — every claim in the browser gate, killed on
# purpose, one at a time.
#
# `build-error-navigation-in-browser.sh` reports 22 green checks. That number
# is worth nothing until each check has been shown to be capable of going red
# for its own reason, because this whole campaign keeps finding machinery that
# was present, correct and never called — and a gate over such machinery is
# green for the same reason a working one is.
#
# WHAT AN ARM MUST DO TO COUNT
# ----------------------------
# Break one thing, and make THE CHECK WRITTEN FOR IT go red. A kill by some
# other check is reported as a MISS, because it means the check that was
# supposed to cover that behaviour does not. Each arm below therefore names the
# check it must kill BY ITS STABLE TAG -- `[caret-col]`, `[wrap]` and so on --
# and the arm fails if that specific tagged line does not turn `[FAILED]`.
#
# The tag exists because the first version of this runner matched on the
# check's PASS wording, which by construction is absent from a check that has
# gone red. Every arm reported a MISS while actually killing the check written
# for it -- the exact "reports could-not-be-measured forever while looking like
# coverage" failure this header warns about, arriving in the header's own file.
# Both branches of every check now carry the same tag.
#
# THE TRAP THIS IS BUILT AGAINST is an arm whose PREMISE has moved: the patched
# line gets edited, the patch matches nothing, the file is unchanged, the gate
# passes, and the arm reports "could not be measured" forever while looking
# like coverage. So every arm asserts the file actually CHANGED, and a no-op
# patch is a HARD FAILURE rather than a skip.
#
# Usage:  bash ci/test/build-error-nav-mutations.sh
# Env:    CT_WEB_BUNDLE_DIR   an assembled tree (strongly recommended; without
#                             it every arm reassembles one)
# Exit:   0 every arm killed its own check, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

command -v nim >/dev/null 2>&1 || {
	echo "build-error-nav-mutations.sh: no 'nim' on PATH." >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

cache="$(ct_nim_cache_root "${repo_root}")/build-error-nav-mutations"
mkdir -p "${cache}"

arms=0
killed=0
missed=0

# Files an arm may patch. Saved once, restored after every arm and on exit, so
# an interrupted run cannot leave the tree mutated.
FILES=(
	"src/frontend/ui/errors.nim"
	"src/frontend/viewmodel/viewmodels/errors_vm.nim"
	"src/config/default_config.yaml"
	"src/frontend/styles/components/problems.styl"
)

save_tree() {
	local i=0
	for f in "${FILES[@]}"; do
		cp "${f}" "${cache}/orig-${i}"
		i=$((i + 1))
	done
}
restore_tree() {
	local i=0
	for f in "${FILES[@]}"; do
		cp "${cache}/orig-${i}" "${f}"
		i=$((i + 1))
	done
}
save_tree
trap restore_tree EXIT

echo "=== build-error navigation: every check, killed on purpose ==="
echo

# `run_gate <label>` — run the browser gate and leave its output in
# `${cache}/<label>.log`.
run_gate() {
	local label="$1"
	CT_NIM_CACHE_ROOT="${cache}" \
		bash ci/test/build-error-navigation-in-browser.sh \
		>"${cache}/${label}.log" 2>&1
	echo $?
}

# `check_failed <label> <needle>` — did the check whose text contains <needle>
# report FAILED?
#
# The lines are extracted into a variable rather than piped into `grep -q`: the
# consumer exits on its first match, the producing `grep -F` takes EPIPE, and
# under the `set -o pipefail` at the top of this file the pipeline reports 141.
# In `check_failed` that turns a mutation the suite DID catch into "SURVIVED";
# in `check_passed` it turns a green baseline into a red one.
check_failed() {
	grep -qF "$2" <<<"$(grep -F "[FAILED]" "${cache}/$1.log")"
}
# `check_passed <label> <needle>`
check_passed() {
	grep -qF "$2" <<<"$(grep -F "[OK]" "${cache}/$1.log")"
}

# THE BASELINE, and the reason `check_passed` above exists. It was written and
# never called, and what went missing with it is the premise every arm rests on:
# `check_failed` after a mutation only means something if the target check was
# GREEN before it. A check that is permanently red — because it was written
# against a selector that no longer exists, say — is reported [FAILED] by every
# run, so every arm "kills" it and this gate prints "6 killed" while measuring
# nothing at all. That is precisely the vacuous pass a mutation gate exists to
# rule out, and it was reachable through the gate itself.
#
# One extra run of the browser gate, on the unmutated tree, before any arm.
echo "Baseline: the gate on an UNMUTATED tree"
baseline_rc="$(run_gate baseline)"
if [ "${baseline_rc}" != "0" ]; then
	echo "      the gate does not pass on the unmutated tree (exit ${baseline_rc})." >&2
	echo "      Every arm below would be comparing a red tree against a red tree," >&2
	echo "      so no arm can prove anything. See ${cache}/baseline.log" >&2
	grep -F "[FAILED]" "${cache}/baseline.log" | head -6 | sed 's/^/      /' >&2
	exit 2
fi
echo "      green — every target check below is asserted green here before it is killed"
echo

# `arm <label> <description> <target-check-text> <patch-command...>`
arm() {
	local label="$1" description="$2" target="$3"
	shift 3
	arms=$((arms + 1))
	echo "ARM ${label}: ${description}"
	echo "      must kill: \"${target}\""

	# THE PREMISE, from the baseline run. A target that is not green on the
	# unmutated tree cannot be killed by anything this arm does.
	if ! check_passed baseline "${target}"; then
		echo "      [MISS] \"${target}\" is not [OK] on the unmutated tree, so a red"
		echo "             here would prove nothing. Either the check text moved or"
		echo "             the check is already failing. Fix that before this arm."
		missed=$((missed + 1))
		echo
		return
	fi

	restore_tree
	# THE PATCH MUST CHANGE SOMETHING.
	local i=0
	for f in "${FILES[@]}"; do
		cp "${f}" "${cache}/${label}-before-${i}"
		i=$((i + 1))
	done
	"$@"
	local changed=0
	for i in 0 1 2 3; do
		if ! cmp -s "${FILES[${i}]}" "${cache}/${label}-before-${i}"; then
			changed=1
		fi
	done
	if [ "${changed}" -eq 0 ]; then
		echo "      [MISS] the patch changed NOTHING — this arm's premise has moved"
		echo "             and it has been measuring nothing. Fix the arm."
		missed=$((missed + 1))
		restore_tree
		echo
		return
	fi

	local rc
	rc="$(run_gate "${label}")"
	restore_tree

	if [ "${rc}" = "2" ]; then
		echo "      [MISS] the gate could not run (exit 2); see ${cache}/${label}.log"
		missed=$((missed + 1))
		echo
		return
	fi

	if check_failed "${label}" "${target}"; then
		echo "      [KILLED] the intended check went red"
		killed=$((killed + 1))
	else
		# Distinguish "nothing went red" from "something ELSE went red".
		local other
		other="$(grep -cF "[FAILED]" "${cache}/${label}.log")"
		if [ "${other}" -gt 0 ]; then
			echo "      [MISS] ${other} check(s) went red, but NOT the intended one."
			echo "             A kill by another check means the check written for this"
			echo "             behaviour does not actually cover it."
			grep -F "[FAILED]" "${cache}/${label}.log" | head -4 | sed 's/^/             /'
		else
			echo "      [MISS] the gate stayed entirely green over a real break."
		fi
		missed=$((missed + 1))
	fi
	echo
}

# ---------------------------------------------------------------------------
# ARM 1 — the column is dropped on the way to the editor.
#
# The caret still moves, still lands on the right line, still opens the right
# file and still takes focus. ONLY the column is wrong. This is the arm that
# says whether "landed on the line AND COLUMN" is doing any work beyond what
# "the caret moved" already says.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_drop_column() {
	perl -0pi -e 's/discard data\.openLocation\(cstring\(path\), line, col\)/discard data.openLocation(cstring(path), line)/' \
		src/frontend/ui/errors.nim
}
arm column "the column is dropped between the diagnostic and the caret" \
	"[caret-col]" \
	patch_drop_column

# ---------------------------------------------------------------------------
# ARM 2 — wrapping stops being announced.
#
# Navigation still wraps and the caret still lands correctly; the user is just
# not told. EMT-D22.2 calls silent wrapping the thing that makes a three-error
# list feel infinite, so it has its own check and this arm must reach it.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_silent_wrap() {
	perl -0pi -e 's/    vm\.announce\(\n      if step == ensNext: "wrapped to first error" else: "wrapped to last error"\)/    vm.announce("")/' \
		src/frontend/viewmodel/viewmodels/errors_vm.nim
}
arm silentwrap "a wrap happens but is never announced" \
	"[wrap]" \
	patch_silent_wrap

# ---------------------------------------------------------------------------
# ARM 3 — the binding is removed from the config table.
#
# THE MOST IMPORTANT ARM. This reproduces exactly the failure this feature was
# built to avoid: an action that exists, has a handler, and has a menu item,
# but no chord — so `loadShortcut` returns "" and the menu row renders with a
# label and nothing beside it. The keystroke also stops working, which is why
# the target below is the MENU check: if removing the binding only reddened the
# caret checks, the menu assertions would not be covering discoverability.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_unbind() {
	perl -0pi -e 's/^  aGotoNextError: "CTRL\+ALT\+N"$/  aGotoNextErrorUnbound: "CTRL+ALT+N"/m' \
		src/config/default_config.yaml
}
arm unbound "the chord is removed from default_config.yaml" \
	"[menu-chord:Go to Next Error]" \
	patch_unbind

# ---------------------------------------------------------------------------
# ARM 4 — navigation stops revealing the panel.
#
# EMT-D22.4: navigation works whether or not the panel is visible, and reveals
# it. Without the reveal the pane stays parked in a dismissed auto-hide overlay
# at x = -9999 with perfectly correct rows in it — the exact state the first
# run of this gate found, and the reason its row assertions are hit-tested
# rather than counted off `innerText`.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_no_reveal() {
	perl -0pi -e 's/  vm\.onRevealPanel = proc\(\) =\n    revealProblemsPanel\(\)/  vm.onRevealPanel = proc() =\n    discard/' \
		src/frontend/ui/errors.nim
}
arm noreveal "navigating no longer reveals the Problems pane" \
	"[rows]" \
	patch_no_reveal

# ---------------------------------------------------------------------------
# ARM 5 — navigation ranges over every severity, not just errors.
#
# EMT-D22.1. The fixture's first row is a WARNING and its only error is the
# third row, so a navigator that ignored severity lands on the warning and the
# caret no longer matches the first error row's position.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_all_severities() {
	perl -0pi -e 's/    if problem\.severity == blsError and problem\.isNavigable:/    if problem.isNavigable:/' \
		src/frontend/viewmodel/viewmodels/errors_vm.nim
}
arm allseverities "navigation stops filtering to errors" \
	"[skip-warnings]" \
	patch_all_severities

# ---------------------------------------------------------------------------
# ARM 6 — the selected row stops being styled.
#
# The class is still applied, the caret still moves, the announcement is still
# painted. ONLY the highlight disappears. This is the defect this feature
# actually shipped with until it was found by reading the stylesheet: a
# selection that exists in the DOM and nowhere on the screen. A check on the
# class name could not have caught it, which is the whole point of asserting
# the computed paint.
# ---------------------------------------------------------------------------
# INVOKED INDIRECTLY. `arm` takes the patch as its trailing argv and runs it
# with `"$@"`, which shellcheck cannot follow.
# shellcheck disable=SC2329
patch_unstyled_selection() {
	perl -0pi -e 's/\.problems-row-selected\n  background: colors-ui-surface-base-selected\n  box-shadow: inset 0\.1875em 0 0 colors-ui-surface-action-primary\n  &:hover\n    background: colors-ui-surface-base-selected/.problems-row-selected\n  color: inherit/' \
		src/frontend/styles/components/problems.styl
}
arm unstyled "the selected row is no longer styled differently" \
	"[selected-visible]" \
	patch_unstyled_selection

restore_tree

echo "${arms} arm(s), ${killed} killed, ${missed} missed"
if [ "${missed}" -eq 0 ] && [ "${arms}" -gt 0 ]; then
	echo "RESULT: OK — every arm reddened the check written for it"
	exit 0
fi
echo "RESULT: FAILED — a check that cannot fail is not a check"
exit 1
