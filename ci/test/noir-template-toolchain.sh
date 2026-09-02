#!/usr/bin/env bash
#
# noir-template-toolchain.sh — the bundled template, checked against the real
# Noir toolchain.
#
# WHAT THIS IS FOR
# ----------------
# `platform/noir_template.nim` carries three claims about a project it ships as
# a compile-time constant, and until now it carried them as prose:
#
#   1. "The code is real Noir rather than a placeholder... a template that does
#      not compile would make the first Run a bug report."
#   2. "`test_the_template_is_a_crate_nargo_builds` is the assertion that keeps
#      it one" — a named test that DID NOT EXIST. The module's own header cites
#      it twice. A citation of an absent check is worse than no citation: it
#      reads, in review, exactly like a check.
#   3. (new) `noirTemplateNargoInfoJson` — the constraint counts the
#      Constraints pane shows on the web, produced by `nargo info --json` at
#      build time because a browser has no `nargo`.
#
# This gate is all three, plus the one that matters most for NS9:
#
#   4. THE PARSER THE BROWSER USES NAMES THE TESTS THE RUNNER RUNS. The web
#      build discovers tests with `ct_test/frameworks/noir_test_syntax`, a pure
#      Nim parser, because there is no `nargo` in a tab. That parser is only
#      trustworthy if its selectors are the runner's own names — otherwise the
#      Test Results pane lists a test `nargo test --exact` cannot select, and
#      the first thing a visitor clicks does nothing. So this compares the
#      parser's selectors against `nargo test --format json`'s `name` fields,
#      as SETS, and requires them equal.
#
#   5. AND THE VERDICTS AGREE, NOT ONLY THE NAMES. Claim 4 guards DISCOVERY:
#      the two agree about which tests exist. It says nothing about what they
#      say happened, and the browser now RUNS the tests — `noir_wasm.wasm`
#      exports `nv_test_vfs`, which drives `nargo::ops::run_test`. A pane that
#      listed the right five tests and reported them backwards would satisfy
#      claim 4 completely. So arm V below runs one program through BOTH engines
#      and diffs the `<name> <status>` lists, over a program deliberately
#      containing a failing test and a `should_fail` test that passes — because
#      a suite in which everything is green is one that a runner with the
#      inversion backwards also reports as green.
#
# THE SHAPE, from Verification-Harness-Traps.md 4a/4c
# ---------------------------------------------------
#   * COUNTED assertions, with the count asserted at the bottom.
#   * A CONTROL ARM: the unmodified template must go green first, so the
#     mutation arms below cannot be red for an unrelated reason.
#   * A MUTATION ARM PER CASE, each verified to redden THE ASSERTION WRITTEN
#     FOR IT and named in the output.
#
# VERIFIED TO REDDEN:
#   * arm P (delete a `#[test]` attribute from the materialised sources):
#     reddens the selector-set equality alone — `nargo` then runs 4 tests and
#     the parser still reports 5, which is precisely the drift claim 4 is
#     about. The compile and info checks stay green.
#   * arm I (perturb one opcode count in the shipped constant): reddens the
#     `nargo info` equality alone. Everything the toolchain says is unchanged;
#     what changed is the bundle's claim about it.
#   * arm B (break the Noir syntax in `main.nr`): reddens the compile check
#     first, and the gate says so rather than reporting five confusing
#     downstream failures.
#   * arm V (invert one expected verdict before the diff): reddens the
#     verdict-equality check alone. Its own control is the un-inverted diff in
#     the same arm, so "the two engines agree" and "the check can see a
#     disagreement" are established over the same two runs.
#
# ARM V IS SKIPPED LOUDLY, not silently, when `CT_NOIR_WASM_COMPILER` is unset
# or `node` is missing — and the expected assertion count moves with it, so a
# skipped arm cannot be mistaken for a passed one. The deploy workflow sets that
# variable from `ci/deploy/build-noir-wasm.sh`'s output directory.
#
# NETWORK: none. `nargo` is a local binary from `ourPkgs.noir`
# (`nix/shells/ci-base.nix`); nothing is fetched.
#
# Usage:  bash ci/test/noir-template-toolchain.sh
# Env:    CT_NIM_CACHE_ROOT       nim cache root (default /tmp/ct-nim-cache)
#         CT_NOIR_WASM_COMPILER   noir_wasm.wasm, for arm V (optional)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-template-toolchain"
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

echo "=== the bundled Noir template, against the real toolchain ==="
echo

command -v nargo >/dev/null 2>&1 || {
	echo "nargo is not on PATH; run inside the dev shell (ourPkgs.noir)" >&2
	exit 2
}
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH; run inside the dev shell" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# The fixture writer — the product's own constants, not this script's.
# ---------------------------------------------------------------------------
fixture_bin="${cache}/noir_template_fixture"
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/fixture" \
	-o:"${fixture_bin}" ci/test/noir_template_fixture.nim \
	>"${cache}/fixture-build.log" 2>&1; then
	echo "  the fixture writer did not compile:" >&2
	grep -E 'Error:' "${cache}/fixture-build.log" | head -3 | sed 's/^/      /' >&2
	exit 1
fi

# `arm_dir` is rebuilt per arm so a mutation cannot leak into the next one —
# the hazard `web-renderer-mounts.sh` records after hard links wrote a mutation
# through into the shared bundle and reddened a later CONTROL arm.
arm_dir=""
trap '[ -n "${arm_dir}" ] && rm -rf "${arm_dir}"' EXIT

materialise() {
	# materialise <dir> ; prints the fixture's report on stdout
	local dir="$1"
	rm -rf "${dir}"
	mkdir -p "${dir}"
	"${fixture_bin}" "${dir}"
}

# Run nargo with its JSON on stdout and its DIAGNOSTICS KEPT SEPARATE, and
# return nargo's own exit status.
#
#   nargo_json <dir> <out.json> <err.txt> [args...]
#
# Folding stderr into the JSON file (`>out 2>&1`) is what this replaces. It
# made a crashing nargo indistinguishable from a nargo that ran and found
# nothing: the parsers skip every line that does not start with `{`, so the
# tool's own explanation of why it died was read as "no tests" and thrown
# away. The gate then reported "the engines disagree" when the truth was
# "one engine never ran" — a verdict about something that did not happen.
nargo_json() {
	local dir="$1" out="$2" err="$3"
	shift 3
	(cd "${dir}" && nargo "$@" >"${out}" 2>"${err}")
}

# 0 if nargo emitted at least one JSON event, i.e. IT RAN.
#
# This is the discriminator the exit status cannot provide: `nargo test`
# exits non-zero both when it crashes and when it runs perfectly and a test
# fails — and arm V *needs* two tests to fail. An emitted event means the
# toolchain got as far as a verdict; an empty file means it never did.
nargo_emitted_rows() {
	grep -q '^[[:space:]]*{' "$1" 2>/dev/null
}

parser_selectors() {
	# The selectors the SHARED parser found, sorted.
	grep '^selector ' "$1" | sed 's/^selector //' | LC_ALL=C sort
}

nargo_selectors() {
	# The test names `nargo test` itself reports, sorted. Read from the
	# `started` events rather than the results, so a test that CRASHES the
	# runner still appears — a set built from passes only would agree with the
	# parser by losing the same rows the run lost.
	python3 -c '
import json, sys
names = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("type") == "test" and row.get("event") == "started":
        names.append(row.get("name", ""))
for n in sorted(set(n for n in names if n)):
    print(n)
' "$1"
}

nargo_verdicts() {
	# `<name> <status>` for every test nargo REACHED A VERDICT ON, sorted.
	#
	# Read from the terminal events and not from `started`, which is what
	# `nargo_selectors` reads: this is the half claim 4 does not cover. The
	# statuses are nargo's own spellings (`ok` / `failed` / `ignored`), and
	# `noir-template-verdicts.mjs` normalises the wasm module's four tags into
	# them so the two sides are comparable without either being rewritten here.
	python3 -c '
import json, sys
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("type") == "test" and row.get("event") in ("ok", "failed", "ignored"):
        rows.append("%s %s" % (row.get("name", ""), row.get("event")))
for r in sorted(set(rows)):
    print(r)
' "$1"
}

nargo_passed_count() {
	python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        row = json.loads(line)
    except Exception:
        continue
    if row.get("type") == "suite" and "passed" in row:
        print(int(row.get("passed", 0)), int(row.get("failed", 0)))
        break
else:
    print(-1, -1)
' "$1"
}

# ---------------------------------------------------------------------------
echo "Arm: CONTROL — the template as it ships"
# ---------------------------------------------------------------------------
arm_dir="${cache}/arm-control"
materialise "${arm_dir}" >"${cache}/control-report.txt" 2>&1

file_count="$(grep -c '^file ' "${cache}/control-report.txt")"
if [ "${file_count}" -ge 4 ]; then
	ck ok "the fixture wrote ${file_count} template files, so every check below has a subject"
else
	ck fail "the fixture wrote ${file_count} file(s) — every check below would be vacuous"
	echo "RESULT: FAILED"
	exit 1
fi

# 1. It compiles. `nargo test` compiles the crate as a side effect, but a
#    dedicated check names the failure correctly when the crate is broken
#    rather than reporting it as "0 tests ran".
if (cd "${arm_dir}" && nargo compile >"${cache}/control-compile.log" 2>&1); then
	ck ok "nargo compiles the bundled template, so the first Run is not a bug report"
else
	ck fail "nargo cannot compile the bundled template:"
	tail -5 "${cache}/control-compile.log" | sed 's/^/      /'
fi

# 2. Its tests pass, and there are five of them. The count is written here
#    because §1a promises a project "its tests already passing"; a template
#    that silently lost a test would still be "all passing".
nargo_json "${arm_dir}" "${cache}/control-test.json" "${cache}/control-test.err" \
	test --format json
control_test_status=$?
read -r passed failed <<<"$(nargo_passed_count "${cache}/control-test.json")"
if [ "${passed}" = "5" ] && [ "${failed}" = "0" ]; then
	ck ok "nargo test runs 5 tests and all 5 pass"
elif ! nargo_emitted_rows "${cache}/control-test.json"; then
	ck fail "nargo test produced NO verdicts at all (exit ${control_test_status}) — the toolchain never ran, so this is not a claim about the template's tests:"
	tail -8 "${cache}/control-test.err" | sed 's/^/      /'
else
	ck fail "nargo test reports ${passed} passed / ${failed} failed; the template must ship 5 passing tests"
	tail -5 "${cache}/control-test.json" | sed 's/^/      /'
fi

# 3. THE CROSS-CHECK. The parser a browser uses and the runner a desktop uses
#    must name the same tests.
parser_selectors "${cache}/control-report.txt" >"${cache}/control-parser.txt"
nargo_selectors "${cache}/control-test.json" >"${cache}/control-nargo.txt"
parser_n="$(wc -l <"${cache}/control-parser.txt" | tr -d ' ')"
nargo_n="$(wc -l <"${cache}/control-nargo.txt" | tr -d ' ')"
if [ "${parser_n}" -ge 5 ] && [ "${nargo_n}" -ge 5 ]; then
	ck ok "the parser found ${parser_n} selectors and nargo reported ${nargo_n}, so the comparison below is not between two empty sets"
else
	ck fail "the parser found ${parser_n} and nargo reported ${nargo_n} — equal empty sets would compare as a pass, so this is checked first"
fi
if diff -u "${cache}/control-nargo.txt" "${cache}/control-parser.txt" \
	>"${cache}/control-selector.diff" 2>&1; then
	ck ok "the shared parser's selectors are exactly nargo's own test names ($(tr '\n' ' ' <"${cache}/control-parser.txt"))"
else
	ck fail "the parser and nargo disagree about which tests exist — the web pane would list a test 'nargo test --exact' cannot select:"
	sed 's/^/      /' "${cache}/control-selector.diff" | head -12
fi

# 4. The shipped constraint constant is what the producer says today.
nargo_json "${arm_dir}" "${cache}/control-info.json" "${cache}/control-info.err" \
	info --json
control_info_status=$?
shipped_info="$(grep '^info ' "${cache}/control-report.txt" | sed 's/^info //')"
measured_info="$(tr -d ' \n' <"${cache}/control-info.json")"
shipped_compact="$(printf '%s' "${shipped_info}" | tr -d ' \n')"
if [ -n "${measured_info}" ]; then
	ck ok "nargo info produced an answer for the template, so the comparison below has a subject"
else
	ck fail "nargo info produced nothing (exit ${control_info_status}); the shipped constant cannot be checked against it:"
	tail -8 "${cache}/control-info.err" | sed 's/^/      /'
fi
if [ "${shipped_compact}" = "${measured_info}" ]; then
	ck ok "the constraint counts the bundle ships are the ones nargo info reports: ${measured_info}"
else
	ck fail "the shipped constraint counts have drifted from the toolchain"
	note "shipped:  ${shipped_compact}"
	note "measured: ${measured_info}"
fi

provenance="$(grep '^provenance ' "${cache}/control-report.txt" | sed 's/^provenance //')"
case "${provenance}" in
*"nargo info"*)
	ck ok "the shipped counts carry their provenance: ${provenance}" ;;
*)
	ck fail "the shipped counts carry no provenance naming nargo info ('${provenance}') — a count a user cannot judge" ;;
esac
echo

# ---------------------------------------------------------------------------
echo "Arm P: MUTATION — a test the parser sees and the runner does not"
echo "    Expect the SELECTOR-SET check RED, compile and info green."
# ---------------------------------------------------------------------------
arm_dir="${cache}/arm-parser-drift"
materialise "${arm_dir}" >"${cache}/p-report.txt" 2>&1
# Remove the `#[test]` attribute from one function. `nargo` then does not run
# it; the parser reads the ATTRIBUTE, so it still would if it were looking at
# the unmodified sources — which is exactly the asymmetry the check must
# catch. The fixture's own selector list is left alone on purpose: it is the
# product's answer for the SHIPPED template, and the runner is now looking at
# something else.
python3 - "${arm_dir}/src/utils.nr" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert s.count("#[test]") == 1, s.count("#[test]")
open(p, "w").write(s.replace("#[test]", "// [test]", 1))
PY
nargo_json "${arm_dir}" "${cache}/p-test.json" "${cache}/p-test.err" \
	test --format json
nargo_selectors "${cache}/p-test.json" >"${cache}/p-nargo.txt"
parser_selectors "${cache}/p-report.txt" >"${cache}/p-parser.txt"
if diff -q "${cache}/p-nargo.txt" "${cache}/p-parser.txt" >/dev/null 2>&1; then
	ck fail "arm P: the selector sets still match after a #[test] was removed — the cross-check cannot detect parser drift, so it proves nothing"
elif ! nargo_emitted_rows "${cache}/p-test.json"; then
	# Divergence is worthless if it comes from an empty list: a nargo that
	# never ran differs from the parser too, and would have shown this arm
	# green while demonstrating nothing.
	ck fail "arm P: nargo emitted no events, so the sets differ only because one is empty — this arm demonstrates nothing:"
	tail -8 "${cache}/p-test.err" | sed 's/^/      /'
else
	ck ok "arm P: the selector sets diverge when a #[test] is removed ($(wc -l <"${cache}/p-nargo.txt" | tr -d ' ') from nargo vs $(wc -l <"${cache}/p-parser.txt" | tr -d ' ') from the parser), so the cross-check can fail"
fi
# The twin: the mutation must not break the crate, or the arm would be red for
# a compile failure and would say nothing about selectors.
if (cd "${arm_dir}" && nargo compile >/dev/null 2>&1); then
	ck ok "arm P: the crate still compiles, so this arm isolates discovery from compilation"
else
	ck fail "arm P: the mutation broke the crate — it is not isolating discovery"
fi
echo

# ---------------------------------------------------------------------------
echo "Arm I: MUTATION — the shipped constraint counts drift from the producer"
echo "    Expect the INFO equality RED, everything else green."
# ---------------------------------------------------------------------------
mutated_info="$(printf '%s' "${shipped_compact}" | sed 's/"opcodes":17/"opcodes":18/')"
if [ "${mutated_info}" = "${shipped_compact}" ]; then
	ck fail "arm I could not be measured: the shipped constant does not contain the opcode count this arm perturbs"
	ck fail "arm I could not be measured (second half)"
else
	if [ "${mutated_info}" = "${measured_info}" ]; then
		ck fail "arm I: the perturbed constant still equals what nargo info reports — the equality check is not reading the counts"
	else
		ck ok "arm I: a one-opcode change to the shipped constant no longer equals nargo info, so the drift check can fail"
	fi
	# The twin: this is a claim about the BUNDLE, not about the toolchain. The
	# measured answer must be untouched by it.
	if [ -n "${measured_info}" ] && [ "${measured_info}" = "$(tr -d ' \n' <"${cache}/control-info.json")" ]; then
		ck ok "arm I: nargo info's own answer is unchanged, so this arm isolates the bundle's claim from the producer"
	else
		ck fail "arm I: the measured answer changed too — the arm is not isolating the bundle's claim"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Arm B: MUTATION — the template stops being valid Noir"
echo "    Expect the COMPILE check RED, and named as a compile failure."
# ---------------------------------------------------------------------------
arm_dir="${cache}/arm-broken"
materialise "${arm_dir}" >"${cache}/b-report.txt" 2>&1
printf '\nfn broken( {\n' >>"${arm_dir}/src/main.nr"
if (cd "${arm_dir}" && nargo compile >"${cache}/b-compile.log" 2>&1); then
	ck fail "arm B: nargo compiled a crate with a syntax error in main.nr — the compile check cannot fail, so it proves nothing"
else
	ck ok "arm B: nargo refuses a crate with a syntax error, so the control's compile check can fail"
fi
# The twin: the fixture writer must still have produced the sources, or the
# arm would be red because nothing was written rather than because it broke.
b_files="$(grep -c '^file ' "${cache}/b-report.txt")"
if [ "${b_files}" -ge 4 ]; then
	ck ok "arm B: the fixture still wrote ${b_files} files, so the arm is red for the syntax error and not for an empty directory"
else
	ck fail "arm B: only ${b_files} file(s) were written — the arm is not isolating the syntax error"
fi
echo

# ---------------------------------------------------------------------------
echo "Arm V: THE VERDICTS — nargo and the wasm module over one program"
echo "    Expect the two engines to agree line for line, and the check to be"
echo "    able to see a disagreement."
# ---------------------------------------------------------------------------
arm_v_checks=0
if [ -z "${CT_NOIR_WASM_COMPILER:-}" ] || [ ! -f "${CT_NOIR_WASM_COMPILER:-}" ]; then
	note "SKIPPED: CT_NOIR_WASM_COMPILER is unset or does not name a file."
	note "  This arm compares the browser's test runner against nargo's. Build"
	note "  the module and point at it:"
	note "    bash ci/deploy/build-noir-wasm.sh /tmp/noir-wasm-out"
	note "    CT_NOIR_WASM_COMPILER=/tmp/noir-wasm-out/noir_wasm.wasm \\"
	note "      bash ci/test/noir-template-toolchain.sh"
elif ! command -v node >/dev/null 2>&1; then
	note "SKIPPED: node is not on PATH, and the wasm module is driven from node."
else
	arm_v_checks=4
	arm_dir="${cache}/arm-verdicts"
	materialise "${arm_dir}" >"${cache}/v-report.txt" 2>&1

	# TWO TESTS THAT MUST NOT BE GREEN, appended to a template whose own five
	# all pass. Without them this arm would compare two lists of `ok`, which is
	# what a runner with the `should_fail` inversion backwards also produces.
	cat >>"${arm_dir}/src/main.nr" <<'ARM_V'

#[test]
fn ci_deliberate_failure() {
    assert(1 == 2, "ci: this test is meant to fail");
}

#[test(should_fail)]
fn ci_should_fail_but_does_not() {
    assert(1 == 1);
}
ARM_V

	# Non-zero is EXPECTED here: two of the seven tests are meant to fail. So
	# the status alone cannot tell a real run from a crash — `nargo_emitted_rows`
	# is what separates them, and it is consulted before any verdict is read.
	nargo_json "${arm_dir}" "${cache}/v-nargo.json" "${cache}/v-nargo.err" \
		test --format json
	v_nargo_status=$?
	nargo_verdicts "${cache}/v-nargo.json" >"${cache}/v-nargo.txt"
	node ci/test/noir-template-verdicts.mjs "${arm_dir}" hello_noir 		>"${cache}/v-wasm.txt" 2>"${cache}/v-wasm.err"
	wasm_status=$?
	sed 's/^/    /' "${cache}/v-wasm.err"

	nargo_v="$(wc -l <"${cache}/v-nargo.txt" | tr -d ' ')"
	wasm_v="$(wc -l <"${cache}/v-wasm.txt" | tr -d ' ')"

	if [ "${wasm_status}" -eq 0 ] && [ "${nargo_v}" -eq 7 ] && [ "${wasm_v}" -eq 7 ]; then
		ck ok "both engines reached a verdict on all 7 tests, so the diff below is not between two empty lists"
	elif ! nargo_emitted_rows "${cache}/v-nargo.json"; then
		# ZERO VERDICTS IS NOT DISAGREEMENT. One engine never ran; the other
		# ran fine. Saying "the engines disagree" here would name the wrong
		# component and send the reader to the wasm runner, which is healthy.
		ck fail "nargo emitted NO events (exit ${v_nargo_status}) — it never ran, so this arm has nothing to compare and the wasm module's ${wasm_v} verdict(s) are not in dispute. nargo's own words:"
		tail -8 "${cache}/v-nargo.err" | sed 's/^/      /'
	else
		ck fail "nargo reported ${nargo_v} verdict(s) and the wasm module ${wasm_v} (exit ${wasm_status}) — two equal empty lists would compare as a pass, so this is checked first"
	fi

	# THE PROGRAM IS NOT ALL-GREEN, asserted rather than assumed. If the two
	# appended tests stopped failing — a template rename, a `nargo` change —
	# this arm would silently become the weak all-`ok` comparison it exists to
	# avoid, and would still pass.
	failing_n="$(grep -c ' failed$' "${cache}/v-nargo.txt")"
	if [ "${failing_n}" -eq 2 ]; then
		ck ok "the program under comparison has 2 failing tests and 5 passing, so an inverted runner cannot agree by accident"
	else
		ck fail "nargo reported ${failing_n} failing test(s); this arm needs exactly 2, or it compares two all-green lists"
	fi

	if diff -u "${cache}/v-nargo.txt" "${cache}/v-wasm.txt" \
		>"${cache}/v-verdict.diff" 2>&1; then
		ck ok "the wasm module's verdicts are nargo's own, line for line ($(tr '\n' '; ' <"${cache}/v-wasm.txt"))"
	elif ! nargo_emitted_rows "${cache}/v-nargo.json"; then
		ck fail "the verdict lists differ only because nargo's is EMPTY — this is nargo failing to run (exit ${v_nargo_status}), not the browser's runner disagreeing with it; fix the toolchain before reading the diff below:"
		sed 's/^/      /' "${cache}/v-verdict.diff" | head -14
	else
		ck fail "the browser's runner and nargo disagree about what happened — a Test Results pane fed by this would contradict the developer's own terminal:"
		sed 's/^/      /' "${cache}/v-verdict.diff" | head -14
	fi

	# THE ARM'S OWN CONTROL: invert one line and the diff must go red. Without
	# this, "the two agree" is satisfied by a comparison that cannot disagree —
	# a `diff` against a file that failed to be written, for instance.
	sed 's/ci_deliberate_failure failed/ci_deliberate_failure ok/' \
		"${cache}/v-wasm.txt" >"${cache}/v-wasm-inverted.txt"
	if diff -q "${cache}/v-nargo.txt" "${cache}/v-wasm-inverted.txt" >/dev/null 2>&1; then
		ck fail "arm V: inverting one verdict still compared equal — the diff is not reading the statuses"
	else
		ck ok "arm V: inverting one verdict makes the comparison red, so it can see a disagreement"
	fi
fi
echo

expect_count $((14 + arm_v_checks))

if [ "${failures}" -eq 0 ]; then
	printf 'RESULT: OK — %d check(s); the bundled template compiles, its five tests pass,\n' "${checks}"
	printf '            the browser'"'"'s parser names the runner'"'"'s tests, and the shipped\n'
	printf '            constraint counts are the ones nargo info reports.\n'
	if [ "${arm_v_checks}" -eq 0 ]; then
		printf '            Arm V (the browser runner'"'"'s verdicts against nargo'"'"'s) was SKIPPED.\n'
	else
		printf '            The browser runner'"'"'s verdicts are nargo'"'"'s own.\n'
	fi
	exit 0
fi
printf 'RESULT: FAILED — %d of %d check(s)\n' "${failures}" "${checks}"
exit 1
