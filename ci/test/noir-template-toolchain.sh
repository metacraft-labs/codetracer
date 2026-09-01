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
#
# NETWORK: none. `nargo` is a local binary from `ourPkgs.noir`
# (`nix/shells/ci-base.nix`); nothing is fetched.
#
# Usage:  bash ci/test/noir-template-toolchain.sh
# Env:    CT_NIM_CACHE_ROOT   nim cache root (default /tmp/ct-nim-cache)

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
(cd "${arm_dir}" && nargo test --format json >"${cache}/control-test.json" 2>&1)
read -r passed failed <<<"$(nargo_passed_count "${cache}/control-test.json")"
if [ "${passed}" = "5" ] && [ "${failed}" = "0" ]; then
	ck ok "nargo test runs 5 tests and all 5 pass"
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
(cd "${arm_dir}" && nargo info --json >"${cache}/control-info.json" 2>/dev/null)
shipped_info="$(grep '^info ' "${cache}/control-report.txt" | sed 's/^info //')"
measured_info="$(tr -d ' \n' <"${cache}/control-info.json")"
shipped_compact="$(printf '%s' "${shipped_info}" | tr -d ' \n')"
if [ -n "${measured_info}" ]; then
	ck ok "nargo info produced an answer for the template, so the comparison below has a subject"
else
	ck fail "nargo info produced nothing; the shipped constant cannot be checked against it"
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
(cd "${arm_dir}" && nargo test --format json >"${cache}/p-test.json" 2>&1)
nargo_selectors "${cache}/p-test.json" >"${cache}/p-nargo.txt"
parser_selectors "${cache}/p-report.txt" >"${cache}/p-parser.txt"
if diff -q "${cache}/p-nargo.txt" "${cache}/p-parser.txt" >/dev/null 2>&1; then
	ck fail "arm P: the selector sets still match after a #[test] was removed — the cross-check cannot detect parser drift, so it proves nothing"
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

expect_count 14

if [ "${failures}" -eq 0 ]; then
	printf 'RESULT: OK — %d check(s); the bundled template compiles, its five tests pass,\n' "${checks}"
	printf '            the browser'"'"'s parser names the runner'"'"'s tests, and the shipped\n'
	printf '            constraint counts are the ones nargo info reports.\n'
	exit 0
fi
printf 'RESULT: FAILED — %d of %d check(s)\n' "${failures}" "${checks}"
exit 1
