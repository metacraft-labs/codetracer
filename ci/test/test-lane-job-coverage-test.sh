#!/usr/bin/env bash
#
# test-lane-job-coverage-test.sh — contract suite for ci/test/test-lane-job-coverage.sh.
#
# WHY THIS EXISTS
# ---------------
# The guard next door reports that every test lane is invoked by a CI job. The
# only thing that makes that report worth reading is evidence it can say NO —
# and a coverage guard is the specific kind of instrument that fails silently in
# the passing direction, because every one of its checks is a "must not contain"
# over a list it builds itself. Hand it an empty lane list, a justfile it cannot
# parse, or a workflow scan that matches nothing, and it prints a perfect score.
# That is not hypothetical for this family of guards: the shell-gate guard next
# door shipped exactly that bug, reporting `0 found, 0 reachable, RESULT: OK`.
#
# So every arm below is a MUTATION. Each builds a synthetic tree the guard
# should pass, changes ONE thing that ought to make it fail, and asserts it
# does. An arm that cannot kill its mutation is reported as a failure of THIS
# suite, and the CONTROL arm — the unmutated tree must be GREEN — is what keeps
# the other arms from passing for the wrong reason. Without the control, a
# synthetic tree that is red for an unrelated reason makes every mutation look
# killed while proving nothing.
#
# The synthetic trees are deliberately tiny: a justfile, a .github/workflows,
# and a ci/lib/test-lane-files.sh defining just enough of the lane library's
# interface. The guard is driven against them with `--root`, which is the only
# reason that flag exists.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${repo_root}/ci/test/test-lane-job-coverage.sh"

checks=0
failures=0
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
	if [ -n "${2:-}" ]; then
		printf '%s\n' "${2}" | sed 's/^/             /'
	fi
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# make_tree DIR — a synthetic repo the guard should pass.
# ---------------------------------------------------------------------------
# Two lanes, both wired: `alpha` is reached because a workflow names its recipe
# directly; `beta` is reached only THROUGH a dependency of a recipe a workflow
# names, which is the transitive edge the guard must follow.
make_tree() {
	local d="$1"
	mkdir -p "${d}/.github/workflows" "${d}/ci/lib" "${d}/ci/test" "${d}/scripts"

	cat >"${d}/ci/lib/test-lane-files.sh" <<'EOF'
#!/usr/bin/env bash
test_lane_ids() {
	printf '%s\n' alpha beta
}
test_lane_entrypoint() {
	case "$1" in
	alpha) echo "just:test-alpha" ;;
	beta) echo "just:test-beta" ;;
	*) echo "" ;;
	esac
}
test_lane_files() { echo ""; }
test_lane_description() { echo "synthetic"; }
EOF

	cat >"${d}/justfile" <<'EOF'
test-alpha:
  bash ci/lib/run-nim-test-lane.sh alpha

test-beta:
  bash ci/lib/run-nim-test-lane.sh beta

test-aggregate: test-beta
  echo aggregate
EOF

	cat >"${d}/.github/workflows/ci.yml" <<'EOF'
name: ci
on: [push]
jobs:
  a:
    steps:
      - run: just test-alpha
  b:
    steps:
      - run: just test-aggregate
EOF
}

# `--min-lanes 1` because these fixtures carry two or three lanes on purpose.
# Arm 7 still proves an EMPTY list fails: zero is below one.
run_guard() { bash "${GUARD}" --root "$1" --min-lanes 1 2>&1; }

echo "=== test-lane-job-coverage selftest — mutation arms ==="
echo

# ---------------------------------------------------------------------------
# CONTROL
# ---------------------------------------------------------------------------
ctl="${work}/control"
make_tree "${ctl}"
ctl_out="$(run_guard "${ctl}")"
ctl_rc=$?
if [ "${ctl_rc}" -eq 0 ]; then
	ok "CONTROL: the unmutated synthetic tree is GREEN — the arms below can mean something"
else
	bad "CONTROL: the synthetic tree is already red — no arm can demonstrate anything" \
		"$(printf '%s\n' "${ctl_out}" | grep -E '^\s*\[FAILED\]|^ERROR' | head -5)"
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi

# The control must also prove it MEASURED both lanes, not that it found none.
# `lanes: 2 declared, 2 reachable` is the line that separates "everything is
# covered" from "there was nothing to cover".
if printf '%s\n' "${ctl_out}" | grep -q 'lanes: 2 declared, 2 reachable'; then
	ok "CONTROL: reports 2 declared and 2 reachable — a real population, not an empty one"
else
	bad "CONTROL: did not report 2 declared / 2 reachable" \
		"$(printf '%s\n' "${ctl_out}" | grep -i 'lanes:')"
fi

# ---------------------------------------------------------------------------
# ARM 1 — a lane no workflow reaches is reported, BY NAME.
# ---------------------------------------------------------------------------
# THE ARM THE WHOLE GUARD EXISTS FOR. `gamma` is a well-formed lane with a
# well-formed recipe that no workflow calls and no reached recipe depends on —
# exactly the state 16 real lanes were in when this guard was written.
t="${work}/orphan"
make_tree "${t}"
sed -i.bak "s/printf '%s\\\\n' alpha beta/printf '%s\\\\n' alpha beta gamma/" "${t}/ci/lib/test-lane-files.sh"
sed -i.bak 's|\tbeta) echo "just:test-beta" ;;|\tbeta) echo "just:test-beta" ;;\n\tgamma) echo "just:test-gamma" ;;|' "${t}/ci/lib/test-lane-files.sh"
cat >>"${t}/justfile" <<'EOF'

test-gamma:
  bash ci/lib/run-nim-test-lane.sh gamma
EOF
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'gamma'; then
	ok "1/a lane no workflow reaches is reported by name: killed"
else
	bad "1/a lane no workflow reaches is reported by name: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 2 — deleting the workflow step that reaches a lane makes it an orphan.
# ---------------------------------------------------------------------------
# The complement of arm 1: the lane list is untouched and CI loses a step. This
# is the change that actually happens in practice — nobody adds an orphan lane,
# somebody removes or renames the step that ran one.
t="${work}/unwired"
make_tree "${t}"
sed -i.bak '/just test-alpha/d' "${t}/.github/workflows/ci.yml"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'alpha'; then
	ok "2/removing the workflow step that ran a lane makes it a named orphan: killed"
else
	bad "2/removing the workflow step that ran a lane makes it a named orphan: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 3 — the TRANSITIVE edge is real, not decoration.
# ---------------------------------------------------------------------------
# `beta` is reached only via `test-aggregate: test-beta`. Break that dependency
# and beta must go dark. Without this arm, a guard that credited every recipe in
# the justfile regardless of reachability would still pass arms 1 and 2 — that
# over-crediting is the precise bug the shell-gate guard had, where seeding from
# the justfile marked fourteen unreachable gates as covered.
t="${work}/nodep"
make_tree "${t}"
sed -i.bak 's/^test-aggregate: test-beta$/test-aggregate:/' "${t}/justfile"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'beta'; then
	ok "3/a lane reached only through a recipe dependency goes dark when the dependency is cut: killed"
else
	bad "3/a lane reached only through a recipe dependency goes dark when the dependency is cut: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 4 — a lane with no declared entrypoint fails, rather than defaulting.
# ---------------------------------------------------------------------------
t="${work}/noentry"
make_tree "${t}"
sed -i.bak "s/printf '%s\\\\n' alpha beta/printf '%s\\\\n' alpha beta delta/" "${t}/ci/lib/test-lane-files.sh"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'delta'; then
	ok "4/a lane declaring no entrypoint is named, not silently skipped: killed"
else
	bad "4/a lane declaring no entrypoint is named, not silently skipped: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 5 — an entrypoint naming a recipe that does not exist is ROT.
# ---------------------------------------------------------------------------
# The failure mode a pure declaration always has: the recipe is renamed and the
# table still names the old one. Reachability alone would report this lane as an
# orphan; the guard must say the entrypoint does not EXIST, which is a different
# and more actionable finding.
t="${work}/rot"
make_tree "${t}"
sed -i.bak 's|alpha) echo "just:test-alpha" ;;|alpha) echo "just:test-alpha-renamed-away" ;;|' "${t}/ci/lib/test-lane-files.sh"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'no such recipe'; then
	ok "5/an entrypoint naming a recipe the justfile does not define is reported as rot: killed"
else
	bad "5/an entrypoint naming a recipe the justfile does not define is reported as rot: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 6 — a declaration that disagrees with the justfile is caught.
# ---------------------------------------------------------------------------
# `alpha`'s declaration is pointed at `test-beta`, a recipe that exists and IS
# reachable — so checks 2 and 4 both pass and only the derivation arm can catch
# it. This is what stops the table from rotting into a plausible lie.
t="${work}/disagree"
make_tree "${t}"
sed -i.bak 's|alpha) echo "just:test-alpha" ;;|alpha) echo "just:test-beta" ;;|' "${t}/ci/lib/test-lane-files.sh"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -qi 'while the justfile runs them from another'; then
	ok "6/a declared entrypoint that disagrees with the recipe actually running the lane: killed"
else
	bad "6/a declared entrypoint that disagrees with the recipe actually running the lane: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 7 — an empty lane list must not read as full coverage.
# ---------------------------------------------------------------------------
# The vacuous-pass trap, and the reason Step 0 is a hard exit. A guard that
# reports "0 declared, 0 reachable, RESULT: OK" has measured nothing and said
# everything is fine.
t="${work}/empty"
make_tree "${t}"
sed -i.bak "s/printf '%s\\\\n' alpha beta/printf '%s\\\\n'/" "${t}/ci/lib/test-lane-files.sh"
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ]; then
	ok "7/an empty lane list is a hard failure, not a perfect score: killed"
else
	bad "7/an empty lane list is a hard failure, not a perfect score: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 8 — a lane library with no test_lane_entrypoint refuses to run.
# ---------------------------------------------------------------------------
# The accessor could be deleted in a refactor. The guard must then STOP, not
# skip its checks and print OK — a skipped check that still reports success is
# how the condition it guards comes back.
t="${work}/noaccessor"
make_tree "${t}"
python3 - "${t}/ci/lib/test-lane-files.sh" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'test_lane_entrypoint\(\) \{.*?\n\}\n', '', s, flags=re.S)
open(p,'w').write(s)
PY
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'defines no test_lane_entrypoint'; then
	ok "8/a lane library missing test_lane_entrypoint stops the guard: killed"
else
	bad "8/a lane library missing test_lane_entrypoint stops the guard: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 9 — recording an orphan without moving the ceiling is an error.
# ---------------------------------------------------------------------------
# The inventory's whole safety property. Appending a line is the cheapest way to
# make this guard green; the equality is what forces that diff to also change a
# number a reviewer is looking at.
t="${work}/ceiling"
make_tree "${t}"
sed -i.bak "s/printf '%s\\\\n' alpha beta/printf '%s\\\\n' alpha beta gamma/" "${t}/ci/lib/test-lane-files.sh"
sed -i.bak 's|\tbeta) echo "just:test-beta" ;;|\tbeta) echo "just:test-beta" ;;\n\tgamma) echo "just:test-gamma" ;;|' "${t}/ci/lib/test-lane-files.sh"
cat >>"${t}/justfile" <<'EOF'

test-gamma:
  bash ci/lib/run-nim-test-lane.sh gamma
EOF
# Record the orphan, but declare a ceiling that does not match.
cat >"${t}/ci/test/test-lane-job-coverage.known-orphan.txt" <<'EOF'
# RECORDED-ORPHAN-CEILING: 0
gamma
EOF
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -q 'ceiling says'; then
	ok "9/recording an orphan without raising the ceiling is an error: killed"
else
	bad "9/recording an orphan without raising the ceiling is an error: SURVIVED (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -6)"
fi

# ---------------------------------------------------------------------------
# ARM 10 — a correctly recorded orphan is GREEN, but still printed.
# ---------------------------------------------------------------------------
# The other half of arm 9. If recording an orphan did not make the guard green,
# nobody could land it; if it made the orphan invisible, recording would be
# exempting. Both must hold: exit 0 AND the lane still named in the output.
t="${work}/recorded"
make_tree "${t}"
sed -i.bak "s/printf '%s\\\\n' alpha beta/printf '%s\\\\n' alpha beta gamma/" "${t}/ci/lib/test-lane-files.sh"
sed -i.bak 's|\tbeta) echo "just:test-beta" ;;|\tbeta) echo "just:test-beta" ;;\n\tgamma) echo "just:test-gamma" ;;|' "${t}/ci/lib/test-lane-files.sh"
cat >>"${t}/justfile" <<'EOF'

test-gamma:
  bash ci/lib/run-nim-test-lane.sh gamma
EOF
cat >"${t}/ci/test/test-lane-job-coverage.known-orphan.txt" <<'EOF'
# RECORDED-ORPHAN-CEILING: 1
gamma
EOF
out="$(run_guard "${t}")"
rc=$?
if [ "${rc}" -eq 0 ] && printf '%s\n' "${out}" | grep -q 'gamma'; then
	ok "10/a correctly recorded orphan is green AND still named in the report"
else
	bad "10/a correctly recorded orphan is green AND still named in the report (rc=${rc})" \
		"$(printf '%s\n' "${out}" | tail -8)"
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "  A lane that runs nowhere is named, and recording one costs a ceiling."
	echo "RESULT: OK"
	exit 0
fi
echo "RESULT: FAILED"
exit 1
