#!/usr/bin/env bash
# shellcheck shell=bash
#
# run-just-lanes.sh — run EVERY lane of a `just` aggregate, then fail naming
# ALL the lanes that failed, not just the first one.
#
# WHY THIS EXISTS
# ---------------
# An aggregate recipe is a promise: "`just test` runs the non-GUI tests". Two
# ways of writing one in a justfile both quietly break that promise, and both
# were in this file's tree when it was added:
#
#   * A BASH BODY UNDER `set -e`:
#
#         test:
#           #!/usr/bin/env bash
#           set -e
#           just test-build-alignment
#           just test-flake-pin-alignment
#           ... five more ...
#
#     `set -e` aborts the body at the FIRST non-zero lane. The other six never
#     run. The CI job (`test-non-gui`, via ci/test/non-gui.sh) goes red naming
#     one lane, so whoever picks it up fixes that one, pushes, and discovers the
#     second — one round trip of CI per broken lane, each one costing the full
#     nix dev-shell startup, and no point at which anybody can see how much is
#     actually broken.
#
#   * A DEPENDENCY LIST:
#
#         test-bpf: test-bpf-monitor test-bpf-native test-bpf-native-integration test-bpf-integration
#
#     Identical failure mode for a different reason: `just` runs dependencies in
#     order and aborts the whole invocation when one exits non-zero. It is not a
#     `set -e` artefact and cannot be fixed by changing shell flags; the only fix
#     is to stop expressing the aggregate as a dependency list.
#
# Neither shape is wrong about WHETHER to fail. Both are wrong about WHAT THEY
# REPORT: an aggregate whose job is to answer "is the non-GUI suite healthy?"
# answers "the first thing I tried is not", which is a strictly smaller and less
# useful fact. This script answers the actual question.
#
# WHAT IT DOES NOT DO
# -------------------
# It does not weaken anything. Every lane still runs the same recipe, its exit
# status is still load-bearing, and the aggregate still exits non-zero if ANY
# lane failed. There is no continue-on-error, no allow-list, no way to mark a
# lane advisory. The only change is that a failing lane no longer suppresses the
# lanes after it.
#
# It also refuses a VACUOUS PASS. Zero lanes is not "everything passed"; it is a
# caller that built an empty list, and the whole point of this area of the tree
# (see ci/lib/run-nim-test-lane.sh, ci/test/shell-gate-coverage.sh) is that a
# gate which cannot fail is indistinguishable from one that is not running.
#
# ORDER IS PRESERVED. Lanes run sequentially in the order given, exactly as they
# did before, because some of them share build outputs and were written assuming
# that. This is not a parallel runner.
#
# Usage:
#   bash ci/lib/run-just-lanes.sh <aggregate-name> <lane> [<lane> ...]
#
# Exit status:
#   0  every lane passed
#   1  at least one lane failed (all failures named on stderr)
#   2  usage error, or no lanes given
#
# Environment:
#   CT_JUST  the `just` binary to invoke (default: `just`). Exists so
#            ci/test/run-just-lanes-test.sh can point the runner at a
#            throwaway justfile; not used in CI.

set -uo pipefail

aggregate="${1:-}"
if [ -z "${aggregate}" ]; then
	echo "usage: run-just-lanes.sh <aggregate-name> <lane> [<lane> ...]" >&2
	exit 2
fi
shift

just_bin="${CT_JUST:-just}"

if [ "$#" -eq 0 ]; then
	echo "run-just-lanes.sh: '${aggregate}' was given NO lanes to run." >&2
	echo "  Refusing to report success for an empty aggregate: a gate that" >&2
	echo "  cannot fail is not a gate. Fix the caller's lane list." >&2
	exit 2
fi

lanes=("$@")
passed=()
failed=()

for lane in "${lanes[@]}"; do
	echo ""
	echo "=== ${aggregate}: lane ${lane} ==="
	status=0
	"${just_bin}" "${lane}" || status=$?
	if [ "${status}" -eq 0 ]; then
		passed+=("${lane}")
		echo "=== ${aggregate}: lane ${lane} PASSED ==="
	else
		failed+=("${lane} (exit ${status})")
		# Announced on stderr as well as stdout so that a reader tailing only
		# the error stream still sees every failure, not merely the summary.
		echo "=== ${aggregate}: lane ${lane} FAILED (exit ${status}) ===" >&2
		echo "    continuing — remaining lanes still run, and this failure is" >&2
		echo "    recorded and re-reported in the summary below." >&2
	fi
done

echo ""
echo "=== ${aggregate}: summary — ${#lanes[@]} lane(s): ${#passed[@]} passed, ${#failed[@]} failed ==="

if [ "${#failed[@]}" -gt 0 ]; then
	echo "" >&2
	echo "${aggregate}: ${#failed[@]} of ${#lanes[@]} lane(s) FAILED:" >&2
	for entry in "${failed[@]}"; do
		echo "  - ${entry}" >&2
	done
	echo "" >&2
	echo "  Every lane above was run; this list is complete, not first-failure." >&2
	exit 1
fi

echo "${aggregate}: all ${#lanes[@]} lane(s) passed"
