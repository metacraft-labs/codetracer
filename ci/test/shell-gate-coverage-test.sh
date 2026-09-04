#!/usr/bin/env bash
#
# shell-gate-coverage-test.sh — does shell-gate-coverage.sh bite?
#
# The convention `ci/lint/nim.sh` states for its Nim sibling: "a guard that has
# only ever been watched printing OK is not evidence. It drives the guard against
# synthetic trees and asserts each of its checks fires by name."
#
# So every arm below builds a SYNTHETIC tree — a few files with the shape the
# guard reads — rather than mutating the real one. Two reasons, and the second is
# the one that decided it:
#
#   * other agents are editing `ci/test/` and `.github/workflows/` concurrently,
#     and an in-place mutate-and-restore would race them;
#   * a synthetic tree lets an arm assert the guard's answer on a KNOWN input.
#     Against the real tree, "13 dark" and "5 dark" both look like a working
#     guard, and the first one was wrong.
#
# That is not hypothetical. The guard's first run over the real tree reported 13
# dark gates; 8 of those were reachable through `ci/lint/*.sh`, which was missing
# from its roots. Its second run reported 63 of 63 reachable, because it had been
# wired up and the walk was following names out of its own DOC COMMENT. Neither
# number was right and both looked plausible. Arms 1 and 5 are those two mistakes,
# frozen.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/shell-gate-coverage.sh"

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
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A minimal tree the guard can read: enough gates to clear its non-vacuity floor,
# two CI roots, and one gate reachable only through a lint dispatcher.
stage() {
	local d="$1"
	rm -rf "${d}"
	mkdir -p "${d}/.github/workflows" "${d}/ci/test" "${d}/ci/lint"
	local i
	for i in $(seq 1 12); do
		printf '#!/usr/bin/env bash\necho gate%s\n' "${i}" >"${d}/ci/test/gate${i}.sh"
	done
	# Root 1: a workflow naming ten gates directly.
	{
		printf 'name: t\non:\n  push:\njobs:\n  a:\n    steps:\n'
		for i in $(seq 1 10); do
			printf '      - run: bash ci/test/gate%s.sh\n' "${i}"
		done
	} >"${d}/.github/workflows/t.yml"
	# Root 2: the justfile.
	printf 'lint:\n  bash ci/lint/sh.sh\n' >"${d}/justfile"
	# A dispatcher, cited by the justfile, that reaches gate11. gate12 is
	# reachable only transitively, through gate11.
	printf '#!/usr/bin/env bash\nbash ci/test/gate11.sh\n' >"${d}/ci/lint/sh.sh"
	printf '#!/usr/bin/env bash\nbash ci/test/gate12.sh\n' >"${d}/ci/test/gate11.sh"
	: >"${d}/ci/test/shell-gate-coverage.known-dark.txt"
}

run_guard() { bash "${guard}" --root "$1" 2>&1; }

echo "=== shell-gate-coverage selftest — six arms ==="
echo

# ---------------------------------------------------------------------------
# THE CONTROL. Without a green baseline every red below is unattributable.
# ---------------------------------------------------------------------------
stage "${work}/base"
base_out="$(run_guard "${work}/base")"
if grep -q 'RESULT: OK' <<<"${base_out}"; then
	ok "CONTROL: a fully-wired synthetic tree is green"
else
	bad "CONTROL: the synthetic tree is already red — no arm can demonstrate anything"
	printf '%s\n' "${base_out}" | grep -E '\[FAILED\]' | head -4 | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi

# The control also has to prove the two INDIRECT paths resolved, or the arms
# below would be measuring a guard that only ever sees direct references.
if grep -q '12 reachable' <<<"${base_out}"; then
	ok "CONTROL: all 12 gates resolved, including the dispatcher and transitive ones"
else
	bad "CONTROL: the walk did not reach all 12 — the indirect paths are not being followed"
	printf '%s\n' "${base_out}" | grep 'gates:' | sed 's/^/           /'
fi
echo

arm() {
	local name="$1" expect="$2"
	shift 2
	stage "${work}/arm"
	"$@" || {
		bad "${name}: the mutation could not be applied"
		return
	}
	local out
	out="$(run_guard "${work}/arm")"
	if grep -q 'RESULT: OK' <<<"${out}"; then
		bad "${name}: SURVIVED — the guard is still green with the defect in place"
		return
	fi
	if grep -qF -- "${expect}" <<<"${out}"; then
		ok "${name}: killed"
	else
		bad "${name}: went red, but not for its own reason (wanted: ${expect})"
		printf '%s\n' "${out}" | grep -E '\[FAILED\]' | head -3 | sed 's/^/           /'
	fi
}

# ARM 1 — a gate nothing reaches. The whole point.
m_dark() { printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/nobody-runs-me.sh"; }
arm "1/a gate no root reaches" "nobody-runs-me.sh is reachable from NO workflow" m_dark

# ARM 2 — the ROT check: a root naming a gate that does not exist.
m_rot() { printf '      - run: bash ci/test/deleted-gate.sh\n' >>"${work}/arm/.github/workflows/t.yml"; }
arm "2/a root names a gate that is gone" "which does not exist" m_rot

# ARM 3 — the inventory naming a gate that IS reachable. The both-directions
# rule, which evicted eight wrong entries from the real inventory on its first
# correct run.
m_resurrected() { echo "gate1.sh" >"${work}/arm/ci/test/shell-gate-coverage.known-dark.txt"; }
arm "3/inventory names a reachable gate" "IS now reachable — delete that line" m_resurrected

# ARM 4 — the CONTRADICTION check: wired up AND declaring it is not a gate.
m_contradiction() {
	printf '#!/usr/bin/env bash\n# NOT-A-CI-GATE: but I am wired anyway\necho x\n' \
		>"${work}/arm/ci/test/gate1.sh"
}
arm "4/reachable and declares it is not a gate" "one of the two is wrong" m_contradiction

# ARM 5 — THE TRAP THIS GUARD WALKED INTO. A gate that merely NAMES another in a
# comment must not make it reachable. Without comment-stripping the guard
# reported 63 of 63 covered while four gates were referenced by nothing.
m_prose() {
	printf '#!/usr/bin/env bash\necho x\n' >"${work}/arm/ci/test/only-named-in-prose.sh"
	printf '# see also only-named-in-prose.sh for the other half\n' \
		>>"${work}/arm/ci/test/gate1.sh"
}
arm "5/a name in a comment does not confer reachability" \
	"only-named-in-prose.sh is reachable from NO workflow" m_prose

# ARM 6 — the non-vacuity floor: a tree with almost no gates must not report a
# clean sweep.
m_empty() { rm -f "${work}/arm"/ci/test/gate*.sh; }
arm "6/an empty scan is not a clean sweep" "the scan is broken" m_empty

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "  The guard reports each hole, and a name in a comment is not a wire."
echo "RESULT: OK"
