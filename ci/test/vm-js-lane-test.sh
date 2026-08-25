#!/usr/bin/env bash
#
# vm-js-lane-test.sh — contract suite for the `test-vm-js` recipe in justfile.
#
# WHY THIS EXISTS
# ---------------
# The JS ViewModel lane reported test results it could not actually observe.
# Three defects stacked, and each one hid the next:
#
#   1. `nim` auto-defines `nodejs` only for `nim js -r`. This lane compiles and
#      runs as separate steps, so the define was absent, so
#      `std/exitprocs.setProgramResult` was undeclared, so `std/unittest`
#      substituted a no-op and a FAILING suite exited 0.
#   2. The compile redirected everything to /dev/null, so the compiler's own
#      "unittest will not give failing exit code on test failure" warning --
#      which names defect 1 outright -- was discarded on every run.
#   3. `output=$(node ...)` followed by `exitcode=$?` cannot observe a failure
#      under the recipe's `set -e`: a non-zero `node` kills the loop before
#      the assignment is read. So the `$exitcode` arm was dead even where
#      defect 1 did not apply.
#
# The lane still went red when a test printed `[FAILED]`, which is why this
# survived: the human console report was doing all the work, and the structured
# signal the recipe believed it was also checking did not exist. A suite that
# crashed before printing anything, or that ran zero tests, scored `OK`.
#
# The static contracts below pin the recipe's shape; the dynamic ones prove the
# claim about `-d:nodejs` against the real toolchain rather than asserting it.
#
# DESIGN CONSTRAINT
# -----------------
# The static half is pure bash over the justfile, so it runs on a stock runner
# with no Nim, no node and no dev shell -- the same rule the other CI gates
# follow, and what lets `ci-verdict` run it. The dynamic half needs `nim` and
# `node`; when they are absent it says so and is counted as skipped rather than
# quietly passing.
#
# WHERE THIS RUNS, AND WHY BOTH CALL SITES MATTER
# -----------------------------------------------
# Two call sites, deliberately:
#
#   * `ci-verdict` (stock ubuntu-latest, no nim) -- gets the five static
#     contracts. This is the one that runs on every push and PR.
#   * `viewmodel-tests` (inside the dev shell, nim + node present) -- gets all
#     eight, including the three that actually PROVE `-d:nodejs` is
#     load-bearing rather than grepping for it.
#
# For its first day on `dev` there was only the first, so the three dynamic
# contracts skipped on every run while the header claimed they were "exercised
# in full by viewmodel-tests" -- a promise nothing kept. A contract suite whose
# decisive half never executes is the exact defect this suite exists to catch,
# so it is worth being blunt: if the `viewmodel-tests` call site is ever
# dropped, the dynamic contracts stop running and only the summary's skip count
# will say so.
#
# THE SUMMARY REPORTS A DENOMINATOR
# ---------------------------------
# `ran + skipped` is checked against TOTAL_CONTRACTS below and disagreement is
# a hard failure. That is not ceremony: this suite shipped with a skip branch
# that emitted two skips for three dynamic contracts, so on a stock runner it
# printed a total of seven where the real number is eight, and the missing
# contract was invisible. A count without a denominator cannot tell you what it
# failed to mention.
#
# Run directly:  bash ci/test/vm-js-lane-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JUSTFILE="${REPO_ROOT}/justfile"

# Every contract below, counted once, whether or not this environment can run
# it. Bump deliberately when adding one -- the reconciliation at the end fails
# loudly if this disagrees with what actually ran.
TOTAL_CONTRACTS=8

pass_count=0
skip_count=0

fail() {
	echo "vm-js-lane-test: FAIL: $1" >&2
	shift
	for line in "$@"; do echo "    ${line}" >&2; done
	exit 1
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

skip() {
	skip_count=$((skip_count + 1))
	echo "  -- skipped: $1"
}

[ -f "${JUSTFILE}" ] || fail "justfile not found at ${JUSTFILE}"

# Extract the `test-vm-js` recipe body: from its target line to the next
# top-level target or comment block at column 0.
recipe="$(awk '
	/^test-vm-js:/ { inrec = 1; next }
	inrec && /^[^[:space:]#]/ { exit }
	inrec { print }
' "${JUSTFILE}")"

[ -n "${recipe}" ] || fail "could not extract the test-vm-js recipe from ${JUSTFILE}" \
	"either the recipe was renamed or this extractor no longer matches it," \
	"and every contract below would be vacuous"

# The shape contracts below must read the recipe's CODE, never its prose.
# This recipe carries a long comment explaining the very defects being pinned,
# and those comments necessarily quote the tokens under test (`-d:nodejs`,
# `>/dev/null`). Grepping the raw recipe therefore matched the explanation
# instead of the command -- verified: with `-d:nodejs` deleted from the actual
# `nim js` invocation, a raw grep still passed. Strip comment lines first.
# shellcheck disable=SC2001 # parameter expansion cannot express this trim
recipe_code="$(sed 's/[[:space:]]*#.*$//' <<<"${recipe}")"

# The `nim js` invocation is spread over five lines with backslash
# continuations, so a line-oriented grep can only ever see its first fragment.
# That is not hypothetical: contract 4 below looks for a `>/dev/null` on the
# compile, and the redirect sits on the LAST continuation line -- with the
# redirect reinstated, a per-line grep matched nothing and the contract passed
# against the very defect it exists to catch. Fold continuations first so each
# shell command is one line.
recipe_joined="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' <<<"${recipe_code}")"

# Guard against either transform going wrong and silently emptying the
# haystack, which would make every contract below pass vacuously.
grep -q 'nim js' <<<"${recipe_joined}" ||
	fail "the comment stripper preserved the recipe's nim js invocation" \
		"After stripping comments and folding continuations there is no" \
		"'nim js' left, so the shape contracts would be checking an empty string."

echo "test-vm-js lane contracts"

# --- static: the recipe's shape -------------------------------------------

# 1. The define that makes an exit code exist at all. Anchored to the actual
#    `nim js` invocation, not merely present somewhere in the recipe.
if grep -qE 'nim js[[:space:]]+-d:nodejs' <<<"${recipe_joined}"; then
	ok "the recipe's nim js invocation carries -d:nodejs"
else
	fail "the recipe's nim js invocation carries -d:nodejs" \
		"Without it std/unittest cannot set a failing exit code on the js" \
		"backend, so node exits 0 for a failing suite and the exit-code arm" \
		"below becomes dead code."
fi

# 2. node's status must be captured in a form `set -e` cannot swallow.
# shellcheck disable=SC2016 # this is a regex over the recipe text, not an expansion
if grep -qE 'node "\$cache/\$name\.js" 2>&1\) \|\| exitcode=' <<<"${recipe_joined}"; then
	ok "node's exit status is captured with an || guard"
else
	fail "node's exit status is captured with an || guard" \
		"A bare 'output=\$(node ...)' followed by 'exitcode=\$?' cannot observe" \
		"a failure: under this recipe's set -e the non-zero node kills the loop" \
		"before the assignment is read."
fi

# 3. The vacuous-pass guard the native lane has always had. The verdict itself
#    now lives in ci/lib/test-lane-report.sh (and is proved against fixture
#    processes by ci/test/test-lane-report-test.sh); what this contract pins is
#    that THIS recipe still routes through it and still handles the verdict.
if grep -q 'source ci/lib/test-lane-report.sh' <<<"${recipe_joined}" &&
	grep -q 'no-results' <<<"${recipe_joined}"; then
	ok "a build that produces no test results is reported, not scored OK"
else
	fail "a build that produces no test results is reported, not scored OK" \
		"Without this guard a suite that ran zero tests, or died before printing" \
		"anything, is reported as 'OK (0 tests)'. The recipe must source" \
		"ci/lib/test-lane-report.sh and handle its 'no-results' verdict."
fi

# 4. Compiler diagnostics must survive. The warning naming defect 1 was thrown
#    away for as long as the compile was redirected to /dev/null.
if grep -qE 'nim js .*>/dev/null' <<<"${recipe_joined}"; then
	fail "the compile does not discard its diagnostics" \
		"'nim js ... >/dev/null 2>&1' throws away the compiler warning that" \
		"names this lane's own defect."
else
	ok "the compile does not discard its diagnostics"
fi

# 5. The exit code must still be consulted once it is meaningful — and it must
#    be the FIRST thing consulted. `classify_test_run` takes it as argument 1
#    and reads it ahead of the [OK]/[FAILED] tally precisely so a crashed
#    binary cannot be reported as an ordinary partial run; see
#    ci/test/test-lane-report-test.sh, which proves that ordering against a
#    fixture that prints [OK] lines and then SIGSEGVs.
# shellcheck disable=SC2016 # this is a regex over the recipe text, not an expansion
if grep -qE 'classify_test_run "\$exitcode"' <<<"${recipe_joined}"; then
	ok "the recipe still fails a suite on a non-zero exit code"
else
	fail "the recipe still fails a suite on a non-zero exit code" \
		"-d:nodejs makes the exit code meaningful; something must read it," \
		"and it must be node's status that reaches classify_test_run first."
fi

# --- dynamic: prove the -d:nodejs claim against the real toolchain --------
#
# Contract 1 is a grep, and a grep cannot tell you the flag WORKS. These two
# compile the same deliberately-failing suite both ways and compare, so the
# suite carries its own mutation: if -d:nodejs ever stops being load-bearing,
# the second contract fails and contract 1 is revealed as cargo cult.

if ! command -v nim >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
	# One skip per contract in the `else` arm below. There are THREE, and this
	# branch used to emit two -- which is why the totals did not add up.
	skip "nim and/or node not on PATH; cannot verify the -d:nodejs claim here"
	skip "nim and/or node not on PATH; cannot verify the no-define counterpart"
	skip "nim and/or node not on PATH; cannot verify the absence of the warning"
else
	tmp_dir="$(mktemp -d)"
	trap 'rm -rf "${tmp_dir}"' EXIT

	cat >"${tmp_dir}/failing.nim" <<'EOF'
import std/unittest
suite "deliberately failing":
  test "this check must fail":
    check 1 == 2
EOF

	set +e
	with_define_out="$(nim js -d:nodejs --hints:off \
		--nimcache:"${tmp_dir}/cache-with" \
		-o:"${tmp_dir}/with.js" "${tmp_dir}/failing.nim" 2>&1)"
	node "${tmp_dir}/with.js" >/dev/null 2>&1
	with_define_rc=$?

	nim js --hints:off \
		--nimcache:"${tmp_dir}/cache-without" \
		-o:"${tmp_dir}/without.js" "${tmp_dir}/failing.nim" >/dev/null 2>&1
	node "${tmp_dir}/without.js" >/dev/null 2>&1
	without_define_rc=$?
	set -e

	if [ "${with_define_rc}" -ne 0 ]; then
		ok "with -d:nodejs a failing suite exits non-zero (got ${with_define_rc})"
	else
		fail "with -d:nodejs a failing suite exits non-zero" \
			"node exited 0 for a suite whose only test fails, so the lane's" \
			"exit-code arm cannot detect failures even with the define."
	fi

	if [ "${without_define_rc}" -eq 0 ]; then
		ok "without the define that same suite exits 0 — the flag is load-bearing"
	else
		fail "without the define that same suite exits 0" \
			"node exited ${without_define_rc} without -d:nodejs. If the toolchain" \
			"now sets a failing exit code either way, contract 1 no longer" \
			"protects anything and this suite should be revisited rather than" \
			"left asserting a flag that does nothing."
	fi

	if grep -q 'setProgramResult not available' <<<"${with_define_out}"; then
		fail "compiling with -d:nodejs raises no setProgramResult warning" \
			"The define is present but the compiler still reports that unittest" \
			"cannot set a failing exit code."
	else
		ok "compiling with -d:nodejs raises no setProgramResult warning"
	fi
fi

echo

# Reconcile against the declared total before reporting anything. If these
# disagree, some contract neither ran nor announced itself as skipped, and the
# summary below would be quietly understating what this run actually checked.
accounted=$((pass_count + skip_count))
if [ "${accounted}" -ne "${TOTAL_CONTRACTS}" ]; then
	fail "every contract is accounted for as run or skipped" \
		"declared TOTAL_CONTRACTS=${TOTAL_CONTRACTS} but ${pass_count} ran and" \
		"${skip_count} were skipped, which accounts for ${accounted}." \
		"A contract that neither ran nor reported itself skipped is invisible," \
		"so this suite refuses to print a total it cannot justify. Either a" \
		"contract was added without bumping TOTAL_CONTRACTS, or a skip branch" \
		"emits fewer skips than the arm it stands in for."
fi

if [ "${skip_count}" -eq 0 ]; then
	echo "contracts: ${pass_count} of ${TOTAL_CONTRACTS} ran, 0 skipped"
	echo "test-vm-js lane: all contracts hold."
else
	echo "contracts: ${pass_count} of ${TOTAL_CONTRACTS} ran, ${skip_count} skipped" \
		"(no nim and/or node in this environment)"
	echo "test-vm-js lane: the ${pass_count} contracts this environment can check hold."
	echo "  NOTE: the ${skip_count} skipped contract(s) are the ones that PROVE -d:nodejs is"
	# Deliberately no backticks in this string. With them, shfmt -s rewrites
	# the line to single quotes and SC2016 then fires on the backticks; plain
	# words satisfy both tools. (And this comment avoids opening with the
	# linter's name, which would be read as a directive and fail the parse.)
	echo "  load-bearing. They run in the viewmodel-tests job, inside the dev shell."
fi
