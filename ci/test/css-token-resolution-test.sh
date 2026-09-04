#!/usr/bin/env bash
#
# css-token-resolution-test.sh — contract suite for the unresolved-style-
# variable guard.
#
# WHY THIS EXISTS
# ---------------
# The guard's whole claim is that it notices something no human and no
# compiler notices. A guard making that claim has to be shown FAILING before
# its passing means anything: a check that has only ever been green is
# indistinguishable from a check that measures nothing, and this repo has now
# collected five separate instances of exactly that (see
# ci/test/test-lane-report-test.sh).
#
# So every arm below either feeds the guard a defect it must report, or feeds
# it a legal construct it must NOT report. The suppression arms matter as much
# as the detection ones: the guard's namespace rule is what keeps `border-box`
# out of the findings, and a guard that cries wolf gets disabled.
#
# NOTHING HERE MUTATES THE WORKTREE.
# Each arm builds a synthetic repo root under a scratch directory — a Tupfile,
# a generated token file, a palette, and hand-written "compiled" CSS. The
# checker is pointed at that. The final arm is the exception and runs the real
# pipeline over the real tree, read-only, to assert it is green.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${here}/css-token-resolution-guard.py"

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-token-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0

report() {
	if [[ $1 == "ok" ]]; then
		pass=$((pass + 1))
		printf '  [OK]     %s\n' "$2"
	else
		fail=$((fail + 1))
		printf '  [FAILED] %s\n' "$2"
		if [[ -n ${3:-} ]]; then
			printf '%s\n' "$3" | sed 's/^/           /'
		fi
	fi
}

# Builds a synthetic repo root at $1 with the CSS body $2 and, optionally, a
# palette body $3. The generated token set is deliberately small and carries a
# real namespace (`colors-ui`) so the namespace rule has something to bite on.
make_fixture() {
	local root="$1" css="$2" palette="${3:-}"
	local styles="${root}/src/frontend/styles"
	rm -rf "${root}"
	mkdir -p "${styles}/generated" "${root}/ci/test" "${root}/css"
	cat >"${styles}/generated/mapped.styl" <<-'EOF'
		colors-ui-text-primary-body = #f3f3f3
		colors-ui-text-primary-label = #c8c8c8
		colors-ui-surface-base-panel = #282828
		colors-ui-border-secondary = #3a3a3a
	EOF
	printf '%s' "${palette}" >"${styles}/theme.styl"
	cat >"${styles}/Tupfile" <<-'EOF'
		include_rules
		: theme.styl |> !stylus |> theme.css
	EOF
	printf '%s\n' "${css}" >"${root}/css/theme.css"
	printf 'theme.css = 0\n' >"${root}/ci/test/css-token-resolution-legacy.baseline"
}

run_guard() {
	local root="$1"
	shift
	python3 "${guard}" --repo-root "${root}" --css-dir "${root}/css" "$@" 2>&1
}

echo "css-token-resolution-test: contract suite for the unresolved-variable guard"
echo

# ---------------------------------------------------------------------------
# 1. The defect the guard exists for: an identifier in a live design-token
#    namespace that nothing defines. This is the shape that shipped three
#    times.
# ---------------------------------------------------------------------------
make_fixture "${work}/f1" '.pane {
  color: colors-ui-text-accent;
}'
out="$(run_guard "${work}/f1" || true)"
if grep -q "colors-ui-text-accent" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "an unresolved token in a known namespace is reported"
else
	report fail "an unresolved token in a known namespace is reported" "${out}"
fi

# ---------------------------------------------------------------------------
# 2. The same identifier, defined. The guard must go quiet — otherwise it is
#    reporting on shape rather than on resolution.
# ---------------------------------------------------------------------------
make_fixture "${work}/f2" '.pane {
  color: #c8c8c8;
  border-color: #3a3a3a;
}'
out="$(run_guard "${work}/f2" || true)"
if grep -q "^OK" <<<"${out}"; then
	report ok "a stylesheet whose values all resolve is green"
else
	report fail "a stylesheet whose values all resolve is green" "${out}"
fi

# ---------------------------------------------------------------------------
# 3. SUPPRESSION. `border-box` and `padding-box` are CSS keywords that happen
#    to start with a token namespace's first segment; `caption-progress-pulse`
#    is an animation name. All three appear in the real dark theme. Reporting
#    any of them would make the guard unusable, which is how guards get
#    deleted.
# ---------------------------------------------------------------------------
make_fixture "${work}/f3" '.pane {
  box-sizing: border-box;
  background-origin: padding-box;
  animation: caption-progress-pulse 2s linear infinite;
  transition: border-color 150ms ease-in-out;
  vector-effect: non-scaling-stroke;
  font-family: sans-serif;
}'
out="$(run_guard "${work}/f3" || true)"
if grep -q "^OK" <<<"${out}"; then
	report ok "CSS keywords and animation names are not mistaken for tokens"
else
	report fail "CSS keywords and animation names are not mistaken for tokens" "${out}"
fi

# ---------------------------------------------------------------------------
# 4. A selector line parses as `name: value` too (`button:focus-visible {`).
#    If the guard scored those it would report `focus-visible` forever.
# ---------------------------------------------------------------------------
make_fixture "${work}/f4" 'button:focus-visible {
  color: #f3f3f3;
}
input:not(:placeholder-shown) {
  color: #f3f3f3;
}'
out="$(run_guard "${work}/f4" || true)"
if grep -q "^OK" <<<"${out}"; then
	report ok "selector lines are not scored as declarations"
else
	report fail "selector lines are not scored as declarations" "${out}"
fi

# ---------------------------------------------------------------------------
# 5. INSTRUMENT. An empty stylesheet must not read as a pass. This is not
#    hypothetical: default_white_theme.styl compiles to zero bytes on dev, and
#    a guard that scanned it and said OK would be measuring nothing.
# ---------------------------------------------------------------------------
make_fixture "${work}/f5" ''
: >"${work}/f5/css/theme.css"
out="$(run_guard "${work}/f5" || true)"
if grep -q "0 declarations" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "an empty compiled stylesheet fails instead of passing silently"
else
	report fail "an empty compiled stylesheet fails instead of passing silently" "${out}"
fi

# ---------------------------------------------------------------------------
# 6. INSTRUMENT. The Tupfile is the guard's file list. If its rule syntax
#    changes and the list comes back empty, the guard must say so rather than
#    scan nothing and exit 0.
# ---------------------------------------------------------------------------
make_fixture "${work}/f6" '.pane {
  color: #fff;
}'
printf 'include_rules\n' >"${work}/f6/src/frontend/styles/Tupfile"
out="$(run_guard "${work}/f6" || true)"
if grep -q "no !stylus outputs" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "a Tupfile the guard cannot read fails instead of scanning nothing"
else
	report fail "a Tupfile the guard cannot read fails instead of scanning nothing" "${out}"
fi

# ---------------------------------------------------------------------------
# 7. INSTRUMENT. One resolved token set is valid for every theme only because
#    no theme redefines a generated name. If one ever does, the guard is
#    measuring one theme's palette against another's output and must say so
#    rather than quietly measure the dark theme twice.
# ---------------------------------------------------------------------------
make_fixture "${work}/f7" '.pane {
  color: #fff;
}' 'colors-ui-text-primary-body = #000000
'
out="$(run_guard "${work}/f7" || true)"
if grep -q "must become per-theme" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "a theme redefining a generated token invalidates the guard loudly"
else
	report fail "a theme redefining a generated token invalidates the guard loudly" "${out}"
fi

# ---------------------------------------------------------------------------
# 8. LEGACY ARM, upward. A palette variable that did not resolve reaches the
#    output as SCREAMING_CASE. Above the ceiling it fails.
# ---------------------------------------------------------------------------
make_fixture "${work}/f8" '.pane {
  background-color: BACKGROUND_NEIGHBOUR_COLOR;
}'
out="$(run_guard "${work}/f8" || true)"
if grep -q "ratchet only turns one way" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "a legacy leak above the ceiling fails"
else
	report fail "a legacy leak above the ceiling fails" "${out}"
fi

# ---------------------------------------------------------------------------
# 9. LEGACY ARM, downward. A ceiling left above reality is room for a
#    regression to hide in, so under-running the ceiling fails too, with the
#    edit that fixes it.
# ---------------------------------------------------------------------------
make_fixture "${work}/f9" '.pane {
  color: #fff;
}'
printf 'theme.css = 3\n' >"${work}/f9/ci/test/css-token-resolution-legacy.baseline"
out="$(run_guard "${work}/f9" || true)"
if grep -q "Lower the ceiling to 0" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "a ceiling that has drifted above reality fails"
else
	report fail "a ceiling that has drifted above reality fails" "${out}"
fi

# ---------------------------------------------------------------------------
# 10. LEGACY ARM, enforcing. The mode this repo switches to once the backlog
#     in css-token-resolution-legacy.baseline is cleared.
# ---------------------------------------------------------------------------
make_fixture "${work}/f10" '.pane {
  background-color: BACKGROUND_NEIGHBOUR_COLOR;
}'
printf 'theme.css = 1\n' >"${work}/f10/ci/test/css-token-resolution-legacy.baseline"
out="$(run_guard "${work}/f10" || true)"
if grep -q "^OK" <<<"${out}"; then
	report ok "a legacy leak at its ceiling is tolerated by the ratchet"
else
	report fail "a legacy leak at its ceiling is tolerated by the ratchet" "${out}"
fi
out="$(run_guard "${work}/f10" --enforce-legacy || true)"
if grep -q "enforce-legacy" <<<"${out}" && grep -q "^FAIL" <<<"${out}"; then
	report ok "--enforce-legacy fails on a leak the ratchet tolerates"
else
	report fail "--enforce-legacy fails on a leak the ratchet tolerates" "${out}"
fi

# ---------------------------------------------------------------------------
# 11. END TO END, over the real tree. Compiles the shipped stylesheets with
#     the real stylus and asserts the real guard is green. Read-only.
#     Skipped rather than failed when stylus is absent, so the suite is still
#     useful outside the dev shell — the arms above need only python3.
# ---------------------------------------------------------------------------
if command -v stylus >/dev/null 2>&1; then
	if out="$(bash "${here}/css-token-resolution.sh" 2>&1)"; then
		report ok "the real shipped stylesheets resolve every variable"
	else
		report fail "the real shipped stylesheets resolve every variable" "${out}"
	fi
else
	printf '  [SKIP]   the real shipped stylesheets resolve every variable (no stylus on PATH)\n'
fi

echo
echo "css-token-resolution-test: ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
