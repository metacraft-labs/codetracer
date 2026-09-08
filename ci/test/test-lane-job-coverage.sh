#!/usr/bin/env bash
#
# test-lane-job-coverage.sh — fail, BY NAME, on any test lane that no CI job runs.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/test-lane-coverage.sh` proves FILE -> LANE. This proves LANE -> JOB.
# Nothing proved the second, and the gap is where sixteen lanes were living.
#
# Measured on this tree on 2026-09-08 by this guard: 30 lanes declared in
# ci/lib/test-lane-files.sh, and 16 of them invoked by NO CI job at all.
# The hand count that prompted this work said 12; it had missed `frontend-js`,
# `bpf`, `book-isonim` and `agentic-headless`. Two of those four were ALREADY
# recorded as dark by ci/test/shell-gate-coverage.known-dark.txt -- as SCRIPTS
# (`ci/test/frontend-js.sh`, `scripts/test-codetracer-agentic-headless.sh`).
# Nobody had connected that to the LANES those scripts run, which is the whole
# argument for asking the question in lane terms as well as in script terms. They
# were not hidden — they were VISIBLE AND LOOKED FINE. `test-lane-coverage.sh`
# was green on every one, because their files were correctly assigned. And
# their only other references, in `ci/test/test-lane-report-test.sh`, assert
# that a lane is WELL-FORMED — that its file list resolves, that its backend is
# a real backend — never that anything runs it. So a new test file could be
# written, correctly assigned to a lane, pass every gate in the repository, and
# be executed by nothing. `just test-vm-unit` was in precisely that state: zero
# hits across all twelve files in .github/workflows, while the ViewModel unit
# pyramid it runs was being cited as covered.
#
# That is the same defect the whole lane library was built to end, one level up
# the chain. The library ended "a lane forgets a FILE". This ends "CI forgets a
# LANE".
#
# WHAT "RUN BY A JOB" MEANS HERE
# ------------------------------
# A lane is COVERED when its entrypoint — `test_lane_entrypoint <id>`, a `just`
# recipe or a script — is reachable from a GitHub workflow: named directly by a
# `run:` step, or reached from one through recipe dependencies and
# script-to-script calls. That walk is ci/lib/ci-reachability.sh, the same
# engine ci/test/shell-gate-coverage.sh uses to answer the identical question
# about shell gates. Sharing it is deliberate: two copies would agree on the
# day the second was written and drift by the first bugfix applied to one.
#
# WHAT THIS DOES NOT CLAIM
# ------------------------
# Not that a lane PASSES. Not that a reachable lane actually EXECUTES — a step
# behind a false `if:` is reachable and never runs. This measures the graph,
# which is strictly less than the schedule, and saying so is the difference
# between a guard and a reassurance.
#
# THE FOUR CHECKS
# ---------------
#   1. EVERY LANE DECLARES AN ENTRYPOINT. `test_lane_entrypoint` returns empty
#      for anything it does not know, and empty is a failure naming the lane.
#      A lane added without one is the exact state this file exists to stop.
#
#   2. THE ENTRYPOINT EXISTS. A declared recipe must be defined in the
#      justfile; a declared script must be on disk. This is the anti-rot arm,
#      and it is not hypothetical: `scripts/test-codetracer-agentic-headless.sh`
#      named a test file for months after that file was renamed.
#
#   3. THE DECLARATION AGREES WITH THE DERIVATION. For the 21 lanes whose
#      recipe body names the lane id (`run-nim-test-lane.sh <id>` or
#      `test_lane_files <id>`), the entrypoint is ALSO derived from the
#      justfile, and a disagreement is a hard failure. This is what stops the
#      table in test-lane-files.sh from rotting into naming a recipe that
#      stopped running the lane — the failure mode a pure declaration always
#      has, and the reason this gate does not simply trust one.
#
#   4. THE ENTRYPOINT IS REACHABLE FROM A WORKFLOW. The finding itself.
#
# THE RECORDED-ORPHAN INVENTORY
# -----------------------------
# Sixteen lanes cannot be wired the day this guard lands. Six of them are RED
# for reasons that are not theirs (a missing recorder sibling, an uncommitted
# cross-process recording, a drifted collab registry), and wiring a red lane
# into a required job breaks every build for everybody. So they are RECORDED,
# in test-lane-job-coverage.known-orphan.txt, each with a reason and a
# retirement condition, under a CEILING that is an equality: the count must
# match exactly, so adding a line to make this guard green is a diff that
# changes a number a reviewer is looking at. Recording an orphan is not
# exempting it — a recorded orphan is still printed on every run, still counted,
# and still darkness. It is the difference between a debt that is written down
# and a debt that is invisible.
#
# Usage:
#   ci/test/test-lane-job-coverage.sh
#   ci/test/test-lane-job-coverage.sh --root DIR    # drive a synthetic tree
#
# `--root` exists so ci/test/test-lane-job-coverage-test.sh can prove this
# guard RED on a deliberately-orphaned lane before trusting it green here.

set -uo pipefail

# The tree under examination. `--root` moves it.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The checkout THIS SCRIPT lives in, which nothing moves. The reachability
# library is loaded from here, not from `root`: the contract suite points
# `--root` at synthetic fixture trees that carry a justfile and a
# .github/workflows and no ci/lib/ci-reachability.sh at all.
gate_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The floor Step 0 enforces on the lane population. FIVE for a real run: this
# repository has thirty lanes and a scan that resolved fewer than five has
# broken its enumeration, which would make every "must not contain" check below
# vacuously true. `--min-lanes` lowers it ONLY for
# ci/test/test-lane-job-coverage-test.sh, whose synthetic trees carry two or
# three lanes on purpose — an arm has to be small enough to reason about. It is
# not passed in CI, and lowering it there would switch off the vacuity guard
# that Step 0 exists to be.
min_lanes=5

while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		root="$(cd "$2" && pwd)"
		shift 2
		;;
	--min-lanes)
		min_lanes="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,60p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "test-lane-job-coverage.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
done
cd "${root}" || exit 2

checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

echo "=== test lane -> CI job coverage ==="
echo

# ---------------------------------------------------------------------------
# The lane library of the tree under scan.
# ---------------------------------------------------------------------------
if [ ! -f "${root}/ci/lib/test-lane-files.sh" ]; then
	echo "ERROR: ${root}/ci/lib/test-lane-files.sh does not exist — there is no" >&2
	echo "  lane declaration to check. Refusing to report coverage of nothing." >&2
	exit 2
fi
# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime, through the tree under scan
source "${root}/ci/lib/test-lane-files.sh"

if ! command -v test_lane_entrypoint >/dev/null 2>&1; then
	echo "ERROR: ci/lib/test-lane-files.sh defines no test_lane_entrypoint." >&2
	echo "  Without it this guard cannot tell which command runs a lane, so it" >&2
	echo "  would have to skip every check below — and a skipped check that" >&2
	echo "  still prints OK is how the thing it guards comes back." >&2
	exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

test_lane_ids >"${tmp}/lanes"
lane_count="$(grep -c . <"${tmp}/lanes" || true)"

# ---------------------------------------------------------------------------
# Step 0: the population is real.
# ---------------------------------------------------------------------------
# Every "must not contain" check below is vacuously true over an empty lane
# list, and would print a perfect score. Same trap as Step 0 of
# shell-gate-coverage.sh, and it is kept for the same reason: a guard that can
# report on nothing will eventually be handed nothing.
echo "Step 0: there are lanes to check"
if [ "${lane_count}" -ge "${min_lanes}" ]; then
	ok "ci/lib/test-lane-files.sh declares ${lane_count} lane(s)"
else
	bad "only ${lane_count} lane(s) declared (floor is ${min_lanes}) — the enumeration is broken, and every check below would be vacuous"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
# The reachability walk, shared with ci/test/shell-gate-coverage.sh.
# ---------------------------------------------------------------------------
# `gates` is the universe references are resolved against. It is the same
# ci/ + scripts/ script inventory the shell-gate guard uses, because a lane's
# entrypoint can be reached THROUGH a script (`codetracer.yml` ->
# `ci/test/non-gui.sh` -> `just test`), and a walk that could not follow a
# script edge would report reachable lanes as orphans.
# shellcheck source=ci/lib/ci-reachability.sh
# shellcheck disable=SC1091 # resolved at runtime through gate_repo_root
source "${gate_repo_root}/ci/lib/ci-reachability.sh"

gates="$(find ci scripts \( -name node_modules -o -name .git \) -prune -o \
	-type f -print 2>/dev/null |
	sed 's#^\./##' | grep -E '\.(sh|bash|mjs|js|py|ps1)$' | sort)"

roots="$(ci_reach_roots)"
root_count="$(printf '%s\n' "${roots}" | grep -c . || true)"

echo "Step 1: the CI roots are readable"
if [ "${root_count}" -ge 1 ]; then
	ok "${root_count} workflow file(s) to walk from"
else
	bad "found ${root_count} workflow file(s) — reachability below would be measured from nothing"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
echo

ci_reach_parse_justfile
ci_reach_walk

# ---------------------------------------------------------------------------
# The derivation: which recipe's body names each lane id.
# ---------------------------------------------------------------------------
# `${tmp}/bodies` is NAME <tab> one body line, filled by ci_reach_parse_justfile.
# A recipe DERIVES a lane when its body invokes the lane runner on that id, or
# asks the lane library for that id's files. Matched with a trailing boundary so
# `vm-unit` does not claim `vm-unit-js`'s recipe — without it the derivation
# credits the wrong recipe for every lane whose id is a prefix of another's.
derive_recipe_for_lane() {
	awk -F'\t' -v lane="$1" '
	{
		body = substr($0, length($1) + 2)
		if (body ~ ("run-nim-test-lane\\.sh[ \t]+" lane "([ \t]|$)") ||
			body ~ ("test_lane_files[ \t]+" lane "([ \t)]|$)"))
			print $1
	}
	' "${tmp}/bodies" | sort -u
}

# ---------------------------------------------------------------------------
# Steps 2-4, one pass over the lanes.
# ---------------------------------------------------------------------------
: >"${tmp}/no-entrypoint"
: >"${tmp}/rot"
: >"${tmp}/disagree"
: >"${tmp}/orphan"
: >"${tmp}/covered"

while read -r lane; do
	[ -n "${lane}" ] || continue
	entry="$(test_lane_entrypoint "${lane}")"

	if [ -z "${entry}" ]; then
		printf '%s\n' "${lane}" >>"${tmp}/no-entrypoint"
		continue
	fi

	kind="${entry%%:*}"
	target="${entry#*:}"

	# --- check 2: the entrypoint exists ---------------------------------
	case "${kind}" in
	just)
		if ! grep -Fxq -- "${target}" "${tmp}/recipe-names"; then
			printf '%s\t%s\tno such recipe in the justfile\n' \
				"${lane}" "${entry}" >>"${tmp}/rot"
			continue
		fi
		;;
	script)
		if [ ! -f "${target}" ]; then
			printf '%s\t%s\tno such file\n' \
				"${lane}" "${entry}" >>"${tmp}/rot"
			continue
		fi
		;;
	*)
		printf '%s\t%s\tentrypoint must be just:<recipe> or script:<path>\n' \
			"${lane}" "${entry}" >>"${tmp}/rot"
		continue
		;;
	esac

	# --- check 3: declaration agrees with derivation --------------------
	# Only for lanes the justfile can be asked about. A lane with no derived
	# recipe is one whose runner does not consume the lane library; silence
	# there is expected and is not a disagreement.
	derived="$(derive_recipe_for_lane "${lane}")"
	if [ -n "${derived}" ] && [ "${kind}" = "just" ]; then
		if ! grep -Fxq -- "${target}" <<<"${derived}"; then
			printf '%s\t%s\t%s\n' "${lane}" "${entry}" \
				"$(printf '%s' "${derived}" | tr '\n' ' ')" >>"${tmp}/disagree"
			continue
		fi
	fi

	# --- check 4: reachable from a workflow -----------------------------
	reached=1
	case "${kind}" in
	just) grep -Fxq -- "${target}" "${tmp}/rreached" || reached=0 ;;
	script) grep -Fxq -- "${target}" "${tmp}/reached" || reached=0 ;;
	esac

	if [ "${reached}" -eq 1 ]; then
		printf '%s\t%s\n' "${lane}" "${entry}" >>"${tmp}/covered"
	else
		printf '%s\t%s\n' "${lane}" "${entry}" >>"${tmp}/orphan"
	fi
done <"${tmp}/lanes"

no_entry_n="$(grep -c . <"${tmp}/no-entrypoint" || true)"
rot_n="$(grep -c . <"${tmp}/rot" || true)"
disagree_n="$(grep -c . <"${tmp}/disagree" || true)"
orphan_n="$(grep -c . <"${tmp}/orphan" || true)"
covered_n="$(grep -c . <"${tmp}/covered" || true)"

echo "Step 2: every lane declares an entrypoint"
if [ "${no_entry_n}" -eq 0 ]; then
	ok "all ${lane_count} lane(s) name the command that runs them"
else
	bad "${no_entry_n} lane(s) declare NO entrypoint:"
	sed 's/^/             /' <"${tmp}/no-entrypoint"
	cat <<'EOF'

    Add an arm to `test_lane_entrypoint` in ci/lib/test-lane-files.sh saying
    which `just` recipe or script runs the lane. If nothing runs it, that is
    the finding — wire it up or delete the lane.
EOF
fi
echo

echo "Step 3: every declared entrypoint exists, and matches what the justfile does"
if [ "${rot_n}" -eq 0 ]; then
	ok "every declared recipe is defined and every declared script is on disk"
else
	bad "${rot_n} lane(s) name an entrypoint that does not exist:"
	while IFS=$'\t' read -r lane entry why; do
		printf '             %-24s %-40s %s\n' "${lane}" "${entry}" "${why}"
	done <"${tmp}/rot"
fi
if [ "${disagree_n}" -eq 0 ]; then
	ok "every derivable lane's declaration matches the recipe that runs it"
else
	bad "${disagree_n} lane(s) declare one entrypoint while the justfile runs them from another:"
	while IFS=$'\t' read -r lane entry derived; do
		printf '             %-24s declared %-32s justfile: %s\n' \
			"${lane}" "${entry}" "${derived}"
	done <"${tmp}/disagree"
	cat <<'EOF'

    One of the two is wrong. Either the recipe stopped running the lane, or
    the declaration was not updated when the lane moved.
EOF
fi
echo

# ---------------------------------------------------------------------------
# Step 4: the finding.
# ---------------------------------------------------------------------------
inventory="${root}/ci/test/test-lane-job-coverage.known-orphan.txt"
recorded=""
if [ -f "${inventory}" ]; then
	recorded="$(grep -vE '^[[:space:]]*(#|$)' "${inventory}" || true)"
fi
recorded_n="$(printf '%s\n' "${recorded}" | grep -c . || true)"

echo "Step 4: every lane is invoked by at least one CI job"
: >"${tmp}/unrecorded"
: >"${tmp}/recorded-hit"
while IFS=$'\t' read -r lane entry; do
	[ -n "${lane}" ] || continue
	if printf '%s\n' "${recorded}" | grep -Fxq -- "${lane}"; then
		printf '%s\t%s\n' "${lane}" "${entry}" >>"${tmp}/recorded-hit"
	else
		printf '%s\t%s\n' "${lane}" "${entry}" >>"${tmp}/unrecorded"
	fi
done <"${tmp}/orphan"
unrecorded_n="$(grep -c . <"${tmp}/unrecorded" || true)"
recorded_hit_n="$(grep -c . <"${tmp}/recorded-hit" || true)"

if [ "${recorded_hit_n}" -gt 0 ]; then
	note "recorded orphans — declared in test-lane-job-coverage.known-orphan.txt,"
	note "still dark, still counted:"
	while IFS=$'\t' read -r lane entry; do
		printf '      %-24s %s\n' "${lane}" "${entry}"
	done <"${tmp}/recorded-hit"
	echo
fi

if [ "${unrecorded_n}" -eq 0 ]; then
	ok "${covered_n} of ${lane_count} lane(s) reachable; ${recorded_hit_n} recorded orphan(s), 0 unrecorded"
else
	bad "${unrecorded_n} lane(s) are invoked by NO workflow, NO recipe a workflow calls, and NO reachable script:"
	while IFS=$'\t' read -r lane entry; do
		printf '             %-24s %s\n' "${lane}" "${entry}"
	done <"${tmp}/unrecorded"
	cat <<'EOF'

    Each of these compiles and asserts nothing that can fail a build. Fix by
    either:
      * invoking its entrypoint from a workflow step (and adding the job to
        ci/verdict/required-jobs.txt, so a run that skips it reports lost
        coverage rather than a pass); or
      * deleting the lane, if it should not exist; or
      * recording it in ci/test/test-lane-job-coverage.known-orphan.txt with a
        reason and a retirement condition, AND raising that file's ceiling in
        the same diff.

EOF
fi

# THE CEILING, AND WHY IT IS AN EQUALITY.
#
# The inventory is an exception list, and an exception list that can grow
# quietly stops being read: the cheapest way to make this guard green is to
# append a line. An equality means the number in the file has to move too, in
# the same diff, where a reviewer is looking at it — and it means REMOVING an
# orphan without lowering the ceiling is also an error, so the debt cannot be
# quietly paid off and then silently re-borrowed against.
ceiling=""
if [ -f "${inventory}" ]; then
	ceiling="$(grep -E '^[[:space:]]*#[[:space:]]*RECORDED-ORPHAN-CEILING:' "${inventory}" |
		head -1 | sed 's/.*://; s/[^0-9]//g')"
fi
if [ -n "${recorded}" ] || [ -f "${inventory}" ]; then
	if [ -z "${ceiling}" ]; then
		bad "${inventory##*/} carries no '# RECORDED-ORPHAN-CEILING: <n>' line"
	elif [ "${recorded_n}" -eq "${ceiling}" ]; then
		ok "recorded-orphan inventory holds exactly its declared ceiling of ${ceiling}"
	else
		bad "recorded-orphan inventory holds ${recorded_n} entries, ceiling says ${ceiling} — move the ceiling in the same diff"
	fi
fi
echo

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s)"
printf '  lanes: %d declared, %d reachable, %d recorded orphan(s), %d UNRECORDED orphan(s)\n' \
	"${lane_count}" "${covered_n}" "${recorded_hit_n}" "${unrecorded_n}"
echo "  NOT claimed: that any lane passes, or that a reachable lane executes —"
echo '  a step behind a false `if:` is reachable and never runs.'

if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
