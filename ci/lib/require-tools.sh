#!/usr/bin/env bash
#
# require-tools.sh — a lint stage says what it needs, by name, before it runs.
#
# WHY THIS EXISTS
# ---------------
# `devShells.lint` carries only the tools the lint stages actually invoke,
# which makes the stage fast and keeps it away from the Cargo git closure of
# Sui and Solana. The risk that buys is precise: a lint step SILENTLY LOSING A
# TOOL. Without this, dropping `nodejs` from that shell does not produce
# "nodejs is missing" — it produces
#
#     tools/visual-review/deepreview-harness-test.sh: line 88: node: command
#     not found
#
# three lines into a contract suite, or worse, a script whose `command -v node`
# guard quietly skips the half of itself that needed it and reports OK. A gate
# that reports OK because it could not run is the exact defect this repository
# has spent a campaign removing; introducing a new way to produce one while
# speeding the stage up would be a bad trade.
#
# So each lint stage names its tools up front and this fails BY NAME, listing
# EVERY missing one rather than the first, because finding them one CI round
# trip at a time is how a five-minute fix becomes an afternoon.
#
# IT RUNS AS A `lint_step`, AND THE FIRST VERSION DID NOT — WHICH WAS A DEFECT
# THIS REPOSITORY'S OWN GUARD CAUGHT.
#
# It was written as a precondition: `bash ci/lib/require-tools.sh ... || exit 1`
# at the top of the stage, on the reasoning that if the shell is wrong every
# later step is meaningless. `ci/test/lint-step-isolation-test.sh` failed it
# immediately, by name:
#
#     bash.sh: 28 step(s) never reported — an earlier failure hid them
#
# That is the whole point of `ci/lib/lint-steps.sh`, and it is the same defect
# shape as the one this campaign has spent itself removing: an early exit that
# makes a stage report NOTHING. A precondition added to stop a stage failing
# obscurely would have made it silent under exactly the condition it was meant
# to diagnose.
#
# So it is a step like any other. A missing tool is then the FIRST failure in
# the summary, named, with every other step still running and reporting. The
# later failures are noise, but they are visible noise under a line that says
# what caused them — which is strictly better than 28 steps that never ran.
#
# Usage:
#   bash ci/lib/require-tools.sh <tool> [<tool>...]

set -uo pipefail

missing=()
for tool in "$@"; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		missing+=("${tool}")
	fi
done

if [ ${#missing[@]} -eq 0 ]; then
	exit 0
fi

{
	echo
	echo "###############################################################################"
	echo "This lint stage cannot run: ${#missing[@]} tool(s) it invokes are not on PATH."
	echo "###############################################################################"
	for tool in "${missing[@]}"; do
		echo "  MISSING  ${tool}"
	done
	echo
	echo "Nothing has been linted. This is a shell that is missing something, not a"
	echo "finding about the code."
	echo
	echo "In devShells.lint? Add the package to nix/shells/lint.nix -- its header"
	echo "records how the list was derived: every command in command position"
	echo "across the lint scripts and everything they run."
	echo "Not in that shell? These stages expect the lint devShell, selected as"
	echo "  nix develop .#devShells.<system>.lint"
	echo "  CT_LINT_SHELL=${CT_LINT_SHELL:-<unset>}"
} >&2

exit 1
