#!/usr/bin/env bash
# The `/noir/demo` template, against the real toolchain and the real modules.
#
# ## WHAT THIS GATE IS FOR, and the check it deliberately is not
#
# A demo is an EXPERIENCE, and the failure mode of a check over one is that it
# passes without measuring its subject. The naive version — "GET /noir/demo
# returns 200 and a project mounts" — is satisfied by a route that serves the
# STARTER template under a second address. So is "the demo template exists".
# So is "the demo compiles". None of them can tell the two templates apart, and
# a `templateFor` that lost its `efDemo` arm would keep all three green.
#
# So every arm below is about CONTENT:
#
#   * arm D  the demo is not the starter — asserted as a difference between two
#            materialisations, by package name, by file count, and by files the
#            starter does not have.
#   * arm T  its eight tests genuinely pass, and the parser and nargo agree on
#            which eight they are.
#   * arm R  the bug is genuinely REACHABLE: `nargo execute` over the shipped
#            `Prover.toml` refuses, having printed the wrong settled price.
#   * arm F  and it is the bug we think it is — a one-line mutation to
#            `SETTLE_PASSES` makes the same round settle CORRECTLY. This is the
#            arm that makes arm R mean something: without it, "execute fails"
#            is equally satisfied by a template that fails for any reason.
#   * arm S  with that mutation applied the eight tests STILL pass. That is not
#            a curiosity, it is the demo's thesis as an assertion: the suite
#            cannot tell the broken circuit from the fixed one, which is why a
#            debugger is the thing that finds it.
#   * arm A  the shipped constraint count is what the shipping engine computes,
#            with a drift arm.
#   * arm W  it compiles AND traces through the two pinned wasm modules, and
#            the trace contains the wrong price and the assertion — not merely
#            "some events".
#
# Arms F and S are the ones to keep if this file is ever cut down. They are the
# only two that can distinguish "the demo is broken in the intended way" from
# "the demo is broken".
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-demo-template"
mkdir -p "${cache}"

checks=0
failures=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}
note() { printf '  %s\n' "$*"; }

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

require_tool() {
	command -v "$1" >/dev/null 2>&1 && return 0
	printf '\nRESULT: FAILED — 0 assertion(s) ran; the suite never started.\n'
	printf 'An assertion that did not run is not an assertion that passed.\n'
	printf '%s is not on PATH; %s\n' "$1" "$2" >&2
	exit 1
}

echo "=== the /noir/demo template, against the real toolchain ==="
echo

require_tool nargo 'run inside the dev shell.'
require_tool nim 'run inside the dev shell.'

# THE ORACLE NAMES ITSELF. `detect-siblings.sh` can put a sibling checkout's
# nargo ahead of the flake's, so "it compiled" does not say which compiler
# agreed unless the path is printed beside the verdicts.
nargo_path="$(command -v nargo)"
note "nargo:  ${nargo_path}"
nargo --version 2>/dev/null | sed 's/^/    /'
echo

# ---------------------------------------------------------------------------
# The fixture writer — the product's own value, reached through `templateFor`.
# ---------------------------------------------------------------------------
fixture_bin="${cache}/noir_template_fixture"
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/fixture" \
	-o:"${fixture_bin}" ci/test/noir_template_fixture.nim \
	>"${cache}/fixture-build.log" 2>&1; then
	echo "  the fixture writer did not compile:" >&2
	grep -E 'Error:' "${cache}/fixture-build.log" | head -5 | sed 's/^/      /' >&2
	exit 1
fi

arm_dir=""
fix_dir=""
starter_dir=""
trap 'rm -rf "${arm_dir}" "${fix_dir}" "${starter_dir}"' EXIT

# materialise <dir> <starter|demo> ; prints the fixture's report on stdout
materialise() {
	local dir="$1" which="$2"
	rm -rf "${dir}"
	mkdir -p "${dir}"
	"${fixture_bin}" "${dir}" "${which}"
}

nargo_json() {
	local dir="$1" out="$2" err="$3"
	shift 3
	(cd "${dir}" && nargo "$@" >"${out}" 2>"${err}")
}

nargo_emitted_rows() { grep -q '^[[:space:]]*{' "$1" 2>/dev/null; }

# The names nargo itself selects, sorted.
nargo_selectors() {
	python3 -c '
import json, sys
names = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("type") == "test" and row.get("event") == "started":
        names.append(row["name"])
print("\n".join(sorted(names)))' "$1"
}

nargo_passed_count() {
	# shellcheck disable=SC2016 # prose about `nargo test --format json`, not an expansion
	python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    # THE TERMINAL SUITE ROW, not the first one. `nargo test --format json`
    # emits TWO rows of `"type":"suite"`: an opening
    # `{"event":"started","test_count":8,...}` that carries no tally, and a
    # closing one that does. Matching on the type alone selects the opener,
    # whose absent `passed` reads as the -1 sentinel — so every run reported
    # "-1 passed, -1 failed" and the tally check failed identically whatever
    # the suite did. Require the field that makes the row a tally.
    if row.get("type") == "suite" and "passed" in row:
        print(row["passed"], row.get("failed", -1))
        break
else:
    print(-1, -1)' "$1"
}

# ===========================================================================
# arm D — the demo is NOT the starter
# ===========================================================================
echo "--- arm D: the demo route serves a different project ---"
arm_dir="${cache}/demo"
starter_dir="${cache}/starter"
demo_report="$(materialise "${arm_dir}" demo)"
starter_report="$(materialise "${starter_dir}" starter)"

demo_package="$(printf '%s\n' "${demo_report}" | awk '$1=="package"{print $2}')"
starter_package="$(printf '%s\n' "${starter_report}" | awk '$1=="package"{print $2}')"
demo_files="$(printf '%s\n' "${demo_report}" | grep -c '^file ')"
starter_files="$(printf '%s\n' "${starter_report}" | grep -c '^file ')"

note "demo package '${demo_package}' (${demo_files} files); starter package '${starter_package}' (${starter_files} files)"

if [ "${demo_package}" = "oracle_settlement" ]; then
	ck ok "the demo template's package is 'oracle_settlement'"
else
	ck fail "the demo template's package is '${demo_package}', not 'oracle_settlement'"
fi

# THE ASSERTION THAT CATCHES A ROUTE SERVING THE STARTER. The names are also
# the browser project-store keys, so equality here would additionally mean the
# two templates share one stored project.
if [ -n "${demo_package}" ] && [ "${demo_package}" != "${starter_package}" ]; then
	ck ok "the two templates have different package names, so they cannot share a stored project"
else
	ck fail "both templates report package '${demo_package}' — /noir/demo is serving the starter"
fi

# NINE SINCE THE README LANDED: six modules, two manifests, and the one file
# that tells a visitor what the project is for. It was eight until then, and
# the number is asserted rather than derived so that dropping a module and
# adding a note cannot come out even.
if [ "${demo_files}" -eq 9 ]; then
	ck ok "the demo ships 9 files"
else
	ck fail "the demo ships ${demo_files} files, not 9"
fi

# Files the STARTER does not have. A demo that had merely been renamed would
# pass the two checks above and fail this one.
missing=""
for f in src/sort.nr src/aggregate.nr src/report.nr src/config.nr Prover.toml README.md; do
	[ -f "${arm_dir}/${f}" ] || missing="${missing} ${f}"
done
if [ -z "${missing}" ]; then
	ck ok "the demo carries src/{sort,aggregate,report,config}.nr, Prover.toml and README.md"
else
	ck fail "the demo is missing:${missing}"
fi

# THE README MUST NOT GIVE THE BUG AWAY, and that is a property a gate can
# hold. The demo's design is that the bug is invisible to reading — a wrong
# claim in a comment — so a README that named the constant, or the algorithm
# whose bound is wrong, would turn a debugging exercise into a paragraph.
# Checked as an absence, because the failure mode is somebody helpfully adding
# a pointer later.
#
# `sort.nr` IS ALLOWED and is not an oversight. The README tours all seven
# files a visitor sees, one line each, and omitting the one the bug is in
# would point at it by its absence more loudly than naming it.
leaked=""
for token in SETTLE_PASSES bubble; do
	if grep -qi -- "${token}" "${arm_dir}/README.md"; then
		leaked="${leaked} ${token}"
	fi
done
if [ -z "${leaked}" ]; then
	ck ok "README.md names neither the constant the bug lives in nor the algorithm around it"
else
	ck fail "README.md gives the bug away; it mentions:${leaked}"
fi

# NON-VACUITY for the check above: an empty or absent README would pass it.
# The README has to actually make the demo's claim — that the tests pass and
# the answer is wrong anyway — or there is nothing being protected.
if grep -q 'eight tests that all pass' "${arm_dir}/README.md" &&
	grep -q 'is not the price' "${arm_dir}/README.md"; then
	ck ok "README.md states that the tests pass and that the settled price is wrong anyway"
else
	ck fail "README.md no longer states the demo's premise; the previous check is vacuous"
fi

if [ ! -f "${starter_dir}/src/sort.nr" ]; then
	ck ok "the starter does NOT carry src/sort.nr, so the previous check is a difference"
else
	ck fail "the starter also carries src/sort.nr; the two templates are not distinguishable by it"
fi

if ! cmp -s "${arm_dir}/src/main.nr" "${starter_dir}/src/main.nr"; then
	ck ok "the two templates' src/main.nr differ byte for byte"
else
	ck fail "the two templates ship an identical src/main.nr"
fi

# The demo's own subject matter, so a future edit cannot quietly replace the
# circuit with something else and keep the file count.
if grep -q 'SETTLE_PASSES' "${arm_dir}/src/sort.nr" &&
	grep -q 'fn one_pass' "${arm_dir}/src/sort.nr"; then
	ck ok "src/sort.nr declares SETTLE_PASSES and the one_pass frame the calltrace shows"
else
	ck fail "src/sort.nr no longer has SETTLE_PASSES and one_pass; the demo path is broken"
fi

if grep -q 'published_price = "243180"' "${arm_dir}/Prover.toml"; then
	ck ok "Prover.toml publishes 243180, the round's true median"
else
	ck fail "Prover.toml no longer publishes 243180"
fi
echo

# ===========================================================================
# arm T — its tests genuinely pass, and they are the tests the pane lists
# ===========================================================================
echo "--- arm T: the demo's own test suite ---"
if nargo_json "${arm_dir}" "${cache}/t.json" "${cache}/t.err" compile; then
	ck ok "nargo compiles the demo template"
else
	ck fail "nargo refuses the demo template: $(head -3 "${cache}/t.err" | tr '\n' ' ')"
fi

nargo_json "${arm_dir}" "${cache}/test.json" "${cache}/test.err" test --format json
if nargo_emitted_rows "${cache}/test.json"; then
	read -r passed failed <<<"$(nargo_passed_count "${cache}/test.json")"
	note "nargo test: ${passed} passed, ${failed} failed"
	if [ "${passed}" = "8" ] && [ "${failed}" = "0" ]; then
		ck ok "nargo test runs 8 tests over the demo and all 8 pass"
	else
		ck fail "nargo test reports ${passed} passed / ${failed} failed, not 8/0"
	fi
else
	ck fail "nargo test produced NO verdicts over the demo; the toolchain never ran"
fi

# The pane lists what the runner runs. Same cross-check the starter's gate
# makes, over the larger crate, because a five-module project is where a
# single-file parser assumption would break first.
printf '%s\n' "${demo_report}" | awk '$1=="selector"{print $2}' | sort >"${cache}/parser.txt"
nargo_selectors "${cache}/test.json" >"${cache}/nargo.txt"
parser_n="$(wc -l <"${cache}/parser.txt" | tr -d ' ')"
nargo_n="$(wc -l <"${cache}/nargo.txt" | tr -d ' ')"
if [ "${parser_n}" -ge 8 ] && [ "${nargo_n}" -ge 8 ]; then
	ck ok "both the parser (${parser_n}) and nargo (${nargo_n}) named at least 8 tests, so the comparison is not between two empty sets"
else
	ck fail "parser named ${parser_n}, nargo named ${nargo_n}; the comparison below would be vacuous"
fi
if diff -u "${cache}/nargo.txt" "${cache}/parser.txt" >"${cache}/sel.diff" 2>&1; then
	ck ok "the shared parser's selectors are exactly nargo's own test names (${nargo_n})"
else
	ck fail "the parser and nargo disagree about which tests the demo has"
	sed 's/^/      /' "${cache}/sel.diff" | head -12
fi
echo

# ===========================================================================
# arm R — the bug is reachable, and it is the bug we describe
# ===========================================================================
echo "--- arm R: Run over the shipped Prover.toml ---"
if nargo_json "${arm_dir}" "${cache}/exec.out" "${cache}/exec.err" execute; then
	ck fail "nargo execute SUCCEEDED over the demo's Prover.toml; the demo has no bug to find"
else
	ck ok "nargo execute refuses the shipped round, so Run gives the visitor something to debug"
fi

# NOT just "it failed". WHICH failure, and with which wrong value — a template
# that failed to compile, or asserted for some unrelated reason, would satisfy
# a bare non-zero exit.
if grep -q 'the published price is not the median of this round' "${cache}/exec.err"; then
	ck ok "it refuses with the demo's own assertion message"
else
	ck fail "the refusal is not the demo's assertion: $(head -3 "${cache}/exec.err" | tr '\n' ' ')"
fi

if grep -q 'settled price: 242990' "${cache}/exec.out" "${cache}/exec.err"; then
	ck ok "and it printed the WRONG settled price (242990) before refusing"
else
	ck fail "242990 was not printed; the demo no longer settles at the low outlier"
	head -5 "${cache}/exec.out" | sed 's/^/      /'
fi

if grep -q 'fresh reports: 6' "${cache}/exec.out" "${cache}/exec.err"; then
	ck ok "the staleness filter dropped exactly one publisher (6 of 7 fresh)"
else
	ck fail "the round no longer has 6 fresh reports; the demo path's first step is wrong"
fi
echo

# ===========================================================================
# arm F — the mutation that proves arm R measures its subject
# ===========================================================================
echo "--- arm F: paying for the passes the sort actually needs ---"
fix_dir="${cache}/fixed"
materialise "${fix_dir}" demo >/dev/null
# The one-line repair the demo path ends at. If this does not change the
# answer, the bug is not where the demo says it is.

# Capture the status directly rather than reading `$?` on the next line: the
# heredoc makes the two lines look adjacent when they are not, and `$?` there
# is one edit away from reporting some other command's status (SC2181).
repair_rc=0
python3 - "${fix_dir}/src/sort.nr" <<'PY' || repair_rc=$?
import sys
p = sys.argv[1]
s = open(p).read()
old = "pub global SETTLE_PASSES: u32 = MAX_REPORTS / 2;"
new = "pub global SETTLE_PASSES: u32 = MAX_REPORTS - 1;"
if s.count(old) != 1:
    sys.exit("arm F: expected exactly one SETTLE_PASSES definition to repair")
open(p, "w").write(s.replace(old, new))
PY
if [ "${repair_rc}" -ne 0 ]; then
	ck fail "arm F: the SETTLE_PASSES line this arm repairs is no longer there"
	ck fail "arm F: (skipped) the repaired circuit settles the round correctly"
	ck fail "arm F: (skipped) the repaired circuit prints the published price"
else
	ck ok "arm F: src/sort.nr has exactly one SETTLE_PASSES definition to repair"
	if nargo_json "${fix_dir}" "${cache}/fix.out" "${cache}/fix.err" execute; then
		ck ok "arm F: with MAX_REPORTS - 1 passes the SAME round settles and the assert holds"
	else
		ck fail "arm F: the repaired circuit still refuses — the bug is not SETTLE_PASSES: $(head -3 "${cache}/fix.err" | tr '\n' ' ')"
	fi
	if grep -q 'settled price: 243180' "${cache}/fix.out" "${cache}/fix.err"; then
		ck ok "arm F: and it now settles at 243180, the price Prover.toml publishes"
	else
		ck fail "arm F: the repaired circuit does not settle at 243180"
	fi
fi
echo

# ===========================================================================
# arm S — the suite cannot tell the two circuits apart. That is the thesis.
# ===========================================================================
echo "--- arm S: the tests pass either way ---"
nargo_json "${fix_dir}" "${cache}/fixtest.json" "${cache}/fixtest.err" test --format json
if nargo_emitted_rows "${cache}/fixtest.json"; then
	read -r fpassed ffailed <<<"$(nargo_passed_count "${cache}/fixtest.json")"
	note "nargo test over the REPAIRED circuit: ${fpassed} passed, ${ffailed} failed"
	if [ "${fpassed}" = "8" ] && [ "${ffailed}" = "0" ]; then
		ck ok "arm S: all 8 tests pass over the repaired circuit TOO, so the suite does not distinguish them"
	else
		ck fail "arm S: the repaired circuit gives ${fpassed}/${ffailed}; a test DOES catch the bug and the demo's premise is wrong"
	fi
else
	ck fail "arm S: nargo test produced no verdicts over the repaired circuit"
fi
echo

# ===========================================================================
# arm A — what the Constraints pane will show
# ===========================================================================
echo "--- arm A: the shipped constraint count ---"
shipped_acir="$(printf '%s\n' "${demo_report}" | sed -n 's/^info //p' |
	python3 -c '
import json, sys
doc = json.loads(sys.stdin.read())
print(sum(f["opcodes"] for p in doc["programs"] for f in p["functions"]))')"
note "the bundle ships an ACIR total of ${shipped_acir}"

arm_a_checks=0
if [ -n "${CT_NOIR_WASM_COMPILER:-}" ] && [ -f "${CT_NOIR_WASM_COMPILER}" ] &&
	command -v node >/dev/null 2>&1; then
	arm_a_checks=3
	# The known-good case FIRST. `noir-acir-opcode-count.mjs` is a newer
	# technique than the one the starter's gate uses, and a new oracle that has
	# not reproduced the number an existing gate already enforces is an oracle
	# nobody has any reason to believe.
	starter_measured="$(node ci/test/noir-acir-opcode-count.mjs "${starter_dir}" hello_noir 2>"${cache}/acir-starter.err")"
	if [ "${starter_measured}" = "17" ]; then
		ck ok "arm A: the opcode counter reproduces the starter's enforced total (17)"
	else
		ck fail "arm A: the opcode counter says ${starter_measured} for the starter, not the 17 the existing gate enforces"
		sed 's/^/      /' "${cache}/acir-starter.err" | head -4
	fi

	measured_acir="$(node ci/test/noir-acir-opcode-count.mjs "${arm_dir}" oracle_settlement 2>"${cache}/acir.err")"
	if [ "${measured_acir}" = "${shipped_acir}" ]; then
		ck ok "arm A: the ACIR total the bundle ships is the one the shipping engine computes (${measured_acir})"
	else
		ck fail "arm A: the bundle ships ${shipped_acir}; the shipping engine computes ${measured_acir}"
		sed 's/^/      /' "${cache}/acir.err" | head -4
	fi

	# The drift arm: one more opcode than the bundle claims must NOT compare
	# equal, or the check above is an equality nothing could fail.
	if [ "$((shipped_acir + 1))" != "${measured_acir}" ]; then
		ck ok "arm A: one more opcode than the bundle claims does not equal the engine's count, so the check can fail"
	else
		ck fail "arm A: the drift control did not diverge"
	fi
else
	note "SKIPPED: CT_NOIR_WASM_COMPILER (or node) is absent, so the shipped count"
	note "         was NOT compared against the shipping engine."
fi
echo

# ===========================================================================
# arm W — it compiles AND traces through the two pinned modules
# ===========================================================================
echo "--- arm W: compile and trace, through the modules the deploy publishes ---"
arm_w_checks=0
if [ -n "${CT_NOIR_WASM_COMPILER:-}" ] && [ -f "${CT_NOIR_WASM_COMPILER}" ] &&
	[ -n "${CT_NOIR_WASM_TRACER:-}" ] && [ -f "${CT_NOIR_WASM_TRACER}" ] &&
	command -v node >/dev/null 2>&1; then
	arm_w_checks=3
	if node ci/test/noir-demo-trace.mjs "${arm_dir}" oracle_settlement \
		>"${cache}/trace.out" 2>"${cache}/trace.err"; then
		ck ok "arm W: the demo compiles and traces through the two pinned wasm modules"
	else
		ck fail "arm W: the wasm compile-and-trace refused"
		sed 's/^/      /' "${cache}/trace.err" | head -6
	fi
	# NON-TRIVIALITY, separately. This campaign has twice met two modules
	# reporting ok over a trace of one event and zero steps.
	if grep -q '^nontrivial yes$' "${cache}/trace.out"; then
		ck ok "arm W: and the trace has calls and steps in it, not one event and zero steps"
	else
		ck fail "arm W: the trace is trivial: $(grep -E '^(events|steps|calls) ' "${cache}/trace.out" | tr '\n' ' ')"
	fi
	# AND IT IS THIS PROGRAM'S TRACE. Non-triviality is satisfied by any
	# program; the recorded output is what says the browser's Run reaches the
	# same wrong answer the native toolchain does.
	if grep -q '^wrongprice yes$' "${cache}/trace.out" &&
		grep -q '^assertion yes$' "${cache}/trace.out"; then
		ck ok "arm W: the trace's event log carries 'settled price: 242990' and the assertion"
	else
		ck fail "arm W: the trace does not carry the demo's wrong price and assertion"
		sed 's/^/      /' "${cache}/trace.out" | head -10
	fi
	sed 's/^/      /' "${cache}/trace.out" | grep -E 'events|steps|calls' | head -4
else
	note "SKIPPED: CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER (or node) is absent,"
	note "         so the browser's compile-and-trace path was NOT exercised."
fi
echo

# 22 = arm D's 10 + arm T's 4 + arm R's 4 + arm F's 3 + arm S's 1. Arm F writes
# three either way: its repair-failed branch reports the two it could not run
# as failures rather than skipping them, so the count does not move when the
# line it patches goes missing.
#
# Arm D was 8 until the README landed; the two it gained are the pair that
# checks the README makes the demo's claim without giving the bug away.
expect_count $((22 + arm_a_checks + arm_w_checks))

if [ "${failures}" -eq 0 ]; then
	printf 'RESULT: PASSED — %d assertion(s).\n' "${checks}"
	note "The nargo that answered: ${nargo_path}"
	exit 0
fi
printf 'RESULT: FAILED — %d of %d assertion(s).\n' "${failures}" "${checks}"
note "The nargo that answered: ${nargo_path}"
exit 1
