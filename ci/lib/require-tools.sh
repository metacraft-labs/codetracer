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
# A COMMAND IS NOT THE ONLY THING A STAGE CAN LOSE, AND THE FIRST VERSION
# COULD ONLY SEE COMMANDS.
#
# `devShells.lint` derived its package list from "every command in command
# position", which is a rule about commands and therefore cannot see an
# `import`. It carried `python3` and not PyYAML;
# `ci/verdict/recorder-clone-implies-build.py` imports `yaml`, so
# `contract suite: a job that clones a recorder builds it` exited 1 with
# "PyYAML is not available; this suite cannot run" on every run — failing
# `lint-bash` and skipping every build job behind it. `command -v python3`
# answered yes throughout, which is precisely the silent-loss failure this
# script exists to prevent, one layer down.
#
# So a requirement may also name a PYTHON MODULE, as `python3:<module>`:
#
#     bash ci/lib/require-tools.sh shellcheck python3 python3:yaml
#
# It is checked by importing it, which is the only test that means anything: a
# module can be on `sys.path` and still not import. The interpreter itself must
# still be listed separately — a missing `python3` is reported as `python3`,
# not as a confusing import failure.
#
# Only `python3` is accepted on the left. A `node:foo` form would need `-e` and
# a different resolution rule, and quietly running `node -c "import foo"` would
# report a missing module for one that is present — a check that lies is worse
# than one that is absent, so an unknown interpreter is a usage error.
#
# Usage:
#   bash ci/lib/require-tools.sh <tool|python3:module> [...]

set -uo pipefail

missing=()
for tool in "$@"; do
	case "${tool}" in
	python3:*)
		module="${tool#*:}"
		# A missing interpreter is reported under its own name -- an
		# unimportable module is the wrong thing to name when there is
		# no interpreter to import it with. The list is de-duplicated
		# before it is printed, so declaring `python3` and two
		# `python3:<module>`s does not report `python3` three times.
		if ! command -v python3 >/dev/null 2>&1; then
			missing+=("python3")
			continue
		fi
		if ! python3 -c "import ${module}" >/dev/null 2>&1; then
			missing+=("${tool}")
		fi
		;;
	*:*)
		echo "require-tools.sh: unsupported requirement '${tool}'." >&2
		echo "  Only 'python3:<module>' is understood on the left of a colon." >&2
		exit 2
		;;
	*)
		if ! command -v "${tool}" >/dev/null 2>&1; then
			missing+=("${tool}")
		fi
		;;
	esac
done

if [ ${#missing[@]} -eq 0 ]; then
	exit 0
fi

# De-duplicated, order preserved. `python3` can be reached both as a bare
# requirement and as the interpreter of every `python3:<module>` one; naming it
# three times would read as three separate absences.
seen=""
deduped=()
for tool in "${missing[@]}"; do
	case " ${seen} " in
	*" ${tool} "*) continue ;;
	esac
	seen="${seen} ${tool}"
	deduped+=("${tool}")
done
missing=("${deduped[@]}")

{
	echo
	echo "###############################################################################"
	echo "This lint stage cannot run: ${#missing[@]} requirement(s) it invokes are absent."
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
	echo "across the lint scripts and everything they run, plus the interpreter"
	echo "MODULES those scripts import, which no reading of command position can"
	echo "find. A 'python3:<module>' line above is such an import: add it to the"
	echo "python3.withPackages list, not as a package of its own."
	echo "Not in that shell? These stages expect the lint devShell, selected as"
	echo "  nix develop .#devShells.<system>.lint"
	echo "  CT_LINT_SHELL=${CT_LINT_SHELL:-<unset>}"
} >&2

exit 1
