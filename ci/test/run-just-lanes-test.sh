#!/usr/bin/env bash
# =============================================================================
# Contract: an aggregate runs EVERY lane, and names EVERY failure.
#
# # The defect
#
# Two aggregate recipes in `justfile` reported only their first failing lane:
#
#   * `test` (the `test-non-gui` CI job, reached as codetracer.yml ->
#     ci/test/non-gui.sh -> `just test`) was a bash body under `set -e` running
#     seven `just <lane>` calls in sequence. The first failure aborted the body;
#     the remaining six never ran.
#
#   * `test-bpf` was a dependency list of four lanes. `just` aborts the whole
#     invocation at the first dependency that exits non-zero, so the same three
#     lanes went unreported. No shell flag fixes that one.
#
# Both now delegate to ci/lib/run-just-lanes.sh. This suite is what says the
# delegation actually has the property claimed for it.
#
# # What is asserted
#
#   1. A failure in a NON-FIRST lane does not stop the lanes after it: every
#      lane leaves a side effect on disk, and all of them are present.
#   2. The aggregate exits NON-ZERO when any lane failed. The fix must not have
#      turned "stops early and fails" into "runs everything and passes".
#   3. The failure report names EVERY failed lane, not just the first, and
#      carries each lane's own exit status.
#   4. A lane that passes is not reported as failed, and vice versa.
#   5. An empty lane list is a hard error (exit 2), not a vacuous pass.
#   6. THE INSTRUMENT IS ALIVE: the old `set -e` shape is executed here too, in
#      the same harness, and asserted to exhibit the defect (later lanes leave
#      no side effect). If this assertion ever passes trivially, the harness has
#      stopped being able to observe the difference it exists to measure, and
#      assertions 1-3 above would be green for the wrong reason.
#
# # No mocks of the thing under test
#
# The lanes are throwaway `just` recipes in a temporary directory, driven by the
# real `just` binary and the real ci/lib/run-just-lanes.sh. What is synthetic is
# the WORK a lane does (`touch` a marker, `exit 3`) — not the aggregation, not
# the recipe dispatch, and not the exit-status plumbing, which are the whole
# subject.
#
# The real lanes (`test-rust`, `test-bpf-native`, ...) need a built tree, a nix
# dev shell, cargo, nim and in the BPF case root-ish capabilities, so this suite
# does not run them. It is scoped to the aggregation behaviour, which is what
# changed.
#
# Run: bash ci/test/run-just-lanes-test.sh
# Lane: a step of `lint-bash` (bash + just; no nix, no network, no build).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
RUNNER="${REPO_ROOT}/ci/lib/run-just-lanes.sh"
readonly RUNNER

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1" >&2
	if [ "$#" -gt 1 ]; then
		printf '       %s\n' "$2" >&2
	fi
}

assert_eq() {
	# assert_eq <what> <expected> <actual>
	if [ "$2" = "$3" ]; then
		ok "$1"
	else
		fail "$1" "expected [$2], got [$3]"
	fi
}

assert_contains() {
	# assert_contains <what> <needle> <haystack>
	case "$3" in
	*"$2"*) ok "$1" ;;
	*) fail "$1" "output does not contain [$2]" ;;
	esac
}

assert_not_contains() {
	# assert_not_contains <what> <needle> <haystack>
	case "$3" in
	*"$2"*) fail "$1" "output unexpectedly contains [$2]" ;;
	*) ok "$1" ;;
	esac
}

if ! command -v just >/dev/null 2>&1; then
	# No backticks in this string on purpose: shfmt -s would rewrite the
	# double quotes to single ones, and shellcheck then reports SC2016 on the
	# backticks and exits 1. See the note in nix/pre-commit.nix.
	echo "run-just-lanes-test: the just binary is not on PATH." >&2
	echo "  It is declared in nix/shells/ci-base.nix, so its absence means this" >&2
	echo "  suite is running outside the shell it is specified for. Failing" >&2
	echo "  rather than skipping: an unrun contract suite must not look green." >&2
	exit 2
fi

if [ ! -f "${RUNNER}" ]; then
	echo "run-just-lanes-test: ${RUNNER} does not exist" >&2
	exit 2
fi

WORK="$(mktemp -d)"
readonly WORK
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# The fixture. Four lanes; each records that it ran by creating a marker file,
# and lanes named `fail-*` then exit non-zero. The marker is what lets the
# suite distinguish "ran and failed" from "never ran", which is the entire
# difference this fix is about.
# -----------------------------------------------------------------------------
fixture_dir() {
	local dir="${WORK}/$1"
	mkdir -p "${dir}"
	cat >"${dir}/justfile" <<'JUSTFILE'
lane-a:
  #!/usr/bin/env bash
  touch ran-lane-a

lane-b-fails:
  #!/usr/bin/env bash
  touch ran-lane-b
  exit 3

lane-c:
  #!/usr/bin/env bash
  touch ran-lane-c

lane-d-fails:
  #!/usr/bin/env bash
  touch ran-lane-d
  exit 7
JUSTFILE
	printf '%s' "${dir}"
}

marker() {
	# marker <dir> <name> -> "yes" | "no"
	if [ -e "$1/ran-$2" ]; then printf 'yes'; else printf 'no'; fi
}

# =============================================================================
echo "1. a failure in a NON-FIRST lane does not stop the lanes after it"
# =============================================================================
d="$(fixture_dir non-first-failure)"
out="$(cd "${d}" && bash "${RUNNER}" demo lane-a lane-b-fails lane-c 2>&1)"
status=$?

assert_eq "aggregate exits non-zero when a lane failed" "1" "${status}"
assert_eq "lane-a (before the failure) ran" "yes" "$(marker "${d}" lane-a)"
assert_eq "lane-b-fails (the failure) ran" "yes" "$(marker "${d}" lane-b)"
assert_eq "lane-c (AFTER the failure) ran" "yes" "$(marker "${d}" lane-c)"
assert_contains "report names the failed lane" "lane-b-fails" "${out}"
assert_contains "report carries the lane's own exit status" "exit 3" "${out}"
assert_not_contains "a passing lane is not listed as failed" "- lane-c (exit" "${out}"
assert_contains "summary counts all three lanes" "3 lane(s): 2 passed, 1 failed" "${out}"

# =============================================================================
echo "2. MULTIPLE failures are all named, not just the first"
# =============================================================================
d="$(fixture_dir multiple-failures)"
out="$(cd "${d}" && bash "${RUNNER}" demo lane-a lane-b-fails lane-c lane-d-fails 2>&1)"
status=$?

assert_eq "aggregate still exits non-zero" "1" "${status}"
assert_eq "lane-c between the two failures ran" "yes" "$(marker "${d}" lane-c)"
assert_eq "lane-d-fails after the first failure ran" "yes" "$(marker "${d}" lane-d)"
assert_contains "first failure named" "- lane-b-fails (exit 3)" "${out}"
assert_contains "second failure named" "- lane-d-fails (exit 7)" "${out}"
assert_contains "failure count is the total, not one" "2 of 4 lane(s) FAILED" "${out}"

# =============================================================================
echo "3. an all-passing aggregate passes, and says how many lanes it ran"
# =============================================================================
d="$(fixture_dir all-pass)"
out="$(cd "${d}" && bash "${RUNNER}" demo lane-a lane-c 2>&1)"
status=$?

assert_eq "exit 0 when every lane passed" "0" "${status}"
assert_contains "names the number of lanes that passed" "all 2 lane(s) passed" "${out}"
assert_not_contains "no failure section" "FAILED:" "${out}"

# =============================================================================
echo "4. an empty lane list is an error, not a vacuous pass"
# =============================================================================
d="$(fixture_dir empty)"
out="$(cd "${d}" && bash "${RUNNER}" demo 2>&1)"
status=$?

assert_eq "exit 2 on an empty lane list" "2" "${status}"
assert_contains "says why" "NO lanes" "${out}"

out="$(cd "${d}" && bash "${RUNNER}" 2>&1)"
status=$?
assert_eq "exit 2 with no arguments at all" "2" "${status}"

# =============================================================================
echo "5. INSTRUMENT CHECK — the old shape really does hide the later lanes"
#
# Not a test of the fix; a test of this suite's ability to see the fix. The
# scenario from section 1, run the way `justfile` used to run it. If the later
# lane's marker appears here too, then the markers are not measuring what
# section 1 claims and its green means nothing.
# =============================================================================
d="$(fixture_dir old-shape)"
out="$(cd "${d}" && bash -c 'set -e; just lane-a; just lane-b-fails; just lane-c' 2>&1)"
status=$?

# 3, not 1: under `set -e` the body dies with the FAILING COMMAND'S OWN status,
# whereas the new runner reports a uniform 1 for "some lane failed". Asserted
# rather than glossed, because it is the one behavioural difference the fix
# introduces beyond the intended one, and it is safe here only because the sole
# consumer, ci/test/non-gui.sh, `exec`s the recipe and CI tests it for
# non-zero — no caller anywhere reads a specific exit code off these aggregates.
assert_eq "old shape exits with the failing lane's own status" "3" "${status}"
assert_eq "old shape: lane-a ran" "yes" "$(marker "${d}" lane-a)"
assert_eq "old shape: lane-b-fails ran" "yes" "$(marker "${d}" lane-b)"
assert_eq "old shape: lane-c did NOT run — the defect, reproduced" "no" "$(marker "${d}" lane-c)"
assert_not_contains "old shape never mentions the lane it skipped" "lane-c" "${out}"

# =============================================================================
echo "6. INSTRUMENT CHECK — a just DEPENDENCY LIST hides them too"
#
# The `test-bpf` half of the defect. Same fixture, expressed the way `test-bpf`
# used to be written, to show the dependency-list shape is not fixable by shell
# flags and had to be converted to a body.
# =============================================================================
d="$(fixture_dir old-deps)"
cat >>"${d}/justfile" <<'JUSTFILE'

agg: lane-a lane-b-fails lane-c
JUSTFILE
out="$(cd "${d}" && just agg 2>&1)"
status=$?

assert_eq "dependency-list aggregate failed" "3" "${status}"
assert_eq "dep list: lane-b-fails ran" "yes" "$(marker "${d}" lane-b)"
assert_eq "dep list: lane-c did NOT run — the defect, reproduced" "no" "$(marker "${d}" lane-c)"

# =============================================================================
# A short assertion count is itself a finding: if a section stops executing, the
# suite must not report success on the ones that still did.
# =============================================================================
# 28 = 8 (section 1) + 6 (2) + 3 (3) + 3 (4) + 5 (5) + 3 (6).
readonly EXPECTED_ASSERTIONS=28
echo ""
if [ "${assertions}" -ne "${EXPECTED_ASSERTIONS}" ]; then
	echo "run-just-lanes-test: ran ${assertions} assertions, expected ${EXPECTED_ASSERTIONS}." >&2
	echo "  Reconcile the count against the code — do NOT edit the expected" >&2
	echo "  number to match. A short tally means a section stopped running." >&2
	exit 1
fi

if [ "${failures}" -gt 0 ]; then
	echo "run-just-lanes-test: FAILED — ${failures} of ${assertions} assertions" >&2
	exit 1
fi

echo "run-just-lanes-test: OK — ${assertions} assertions, 0 failures"
