#!/usr/bin/env bash
# NOT-A-CI-GATE: a measurement that runs three ViewModel lanes of ~200 suites,
# cold and twice more after edits, three times over (hours); its output is a
# ratio a person applies to a decision, not a pass/fail CI could act on.
#
# plat18-dev-lane.sh — Uniform-WASM-Core.md §4 metric 7 at LANE scale: the
# time to build and run the whole ViewModel suite set on each backend.
#
# §5's fifth adopt criterion reads "the developer loop does not get
# materially slower — metric 7's quantity, the full ViewModel suite (the
# lane), not one suite from cold". `plat18-dev-loop.sh` measures one suite;
# this measures the lanes, through `ci/lib/run-nim-test-lane.sh`, which is
# what `just test-vm-*` runs.
#
# ## ARMS
#
#   js     `vm-unit-js`    the current web build's backend: `nim js` under node
#   wasm   `vm-unit-wasm`  wasm32 through Emscripten, with the developer
#                          profile the lane uses (`ci/lib/wasm-dev-profile.sh`)
#   native `vm-unit`       `nim c`, the TUI's and GPUI's backend
#   emcc   `vm-unit-wasm`  with CT_WASM_CC=emcc: the wasm lane as it was
#                          before the profile, for the record
#
# CT_P18_LANE_ARMS chooses which run (default `js wasm native`, or `wasm
# native` once `vm-unit-js` is no longer a lane: the `js` arm is then refused
# by name rather than run against a lane that is gone).
#
# ## SCENARIOS — TWO, BECAUSE A DEVELOPER PAYS BOTH
#
#   cold   a fresh, empty CT_NIM_CACHE_ROOT per arm per repetition: nothing
#          cached by Nim, by the object cache or by anything else under it.
#          What a first build after a toolchain change, or on a new
#          checkout, costs.
#   edit   the cache the cold run left, then ONE REAL EDIT to a module every
#          ViewModel suite imports (`store/types.nim` gains a module-level
#          statement, so its generated code changes), then the lane again.
#          What the next run after an ordinary edit costs. The edit is
#          reverted afterwards, byte for byte.
#   typeedit  the same, but the edit adds a FIELD to `Location`, an object
#          most of the core's types contain, so every module that uses it is
#          generated afresh. The expensive kind of edit, measured rather than
#          assumed: the earlier evaluation held that the cold lane is "what a
#          developer pays after the edits that matter", and this is the edit
#          that would make that true.
#
# `nim js` caches nothing between runs, so its edit run is the same work as
# its cold one, measured again; the C backends reuse what did not change.
#
# ## PAIRED AND INTERLEAVED
#
# The CI host this was written on runs at a one-minute load above 100. An
# absolute lane time there is a property of the scheduler, so the quantity
# reported is the RATIO between arms measured back to back inside one
# repetition, and each repetition runs the arms in a rotated order so no arm
# always goes first. The median of the per-repetition ratios is the figure;
# every arm's own times and the load around each run are printed beside it.
#
# ## A LANE THAT DID LESS WORK IS NOT FASTER
#
# Each arm's run must end with the lane's own summary line and the same
# file and case counts on every repetition of that arm — a lane that
# compiled fewer files took less time for a reason that is not the backend.
# A red file does not void a run (the lanes have documented baselines), but
# the counts must not move between repetitions.
#
# Output: one `PLAT18-DEVLANE …` line per run and a `PLAT18-DEVLANE-RATIO`
# line per scenario. §5's threshold is 2.0x against `js`; the script reports
# whether it held and exits 0 either way when every run was valid, because
# a decision criterion is not a CI gate. Exit 1 when a run was invalid, 2
# when a tool is missing.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

for tool in nim emcc node; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	fi
done

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/test-lane-files.sh"
js_lane_exists=0
grep -qxF vm-unit-js <<<"$(test_lane_ids)" && js_lane_exists=1
default_arms="wasm native"
[ "${js_lane_exists}" -eq 1 ] && default_arms="js wasm native"
read -r -a arms <<<"${CT_P18_LANE_ARMS:-${default_arms}}"
# Arms run in the FIRST repetition only — a reference measured once beside
# the arms the ratio is about (e.g. `native emcc`), when hours matter.
read -r -a once_arms <<<"${CT_P18_LANE_ONCE_ARMS:-}"
reps="${CT_P18_LANE_REPS:-3}"
read -r -a scenarios <<<"${CT_P18_LANE_SCENARIOS:-cold edit typeedit}"
work="${CT_P18_LANE_WORK:-${TMPDIR:-/tmp}/plat18-dev-lane}"
threshold="${CT_P18_LANE_THRESHOLD:-2.0}"
edit_file="src/frontend/viewmodel/store/types.nim"

lane_of() {
	case "$1" in
	js)
		[ "${js_lane_exists}" -eq 1 ] || {
			echo "ERROR: the js arm measures vm-unit-js, which is no longer a lane" >&2
			return 1
		}
		echo vm-unit-js
		;;
	wasm | emcc) echo vm-unit-wasm ;;
	native) echo vm-unit ;;
	*) return 1 ;;
	esac
}
for a in "${arms[@]}" ${once_arms[@]+"${once_arms[@]}"}; do
	lane_of "${a}" >/dev/null || {
		echo "ERROR: unknown arm ${a}" >&2
		exit 2
	}
done

mkdir -p "${work}"
edit_backup="${work}/types.nim.orig"
cp "${edit_file}" "${edit_backup}"
restore_edit() { cmp -s "${edit_backup}" "${edit_file}" || cp "${edit_backup}" "${edit_file}"; }
trap restore_edit EXIT

commit="$(git rev-parse --short=11 HEAD 2>/dev/null || echo unknown)"
dirty="$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
echo "=== PLAT-18 developer loop at lane scale ==="
echo "    commit=${commit} tracked-files-modified=${dirty} arms=${arms[*]} reps=${reps}" \
	"once=${once_arms[*]:-none}" \
	"scenarios=${scenarios[*]} cpus=$(nproc)"

# Each run appends one record to times.txt and any refusal to invalid.txt,
# so the arms can run concurrently (below) without sharing shell state.
invalid_file="${work}/invalid.txt"
rm -f "${work}/times.txt" "${work}/times.txt.moved" "${invalid_file}"
refuse() {
	echo "PLAT18-DEVLANE INVALID $*"
	echo "$*" >>"${invalid_file}"
}

run_lane() { # <scenario> <arm> <rep> <cache-root>
	local scenario=$1 arm=$2 rep=$3 cache=$4 lane log s e secs summary
	lane="$(lane_of "${arm}")"
	log="${work}/${scenario}-${arm}-${rep}.log"
	local load_before load_after
	load_before="$(cut -d' ' -f1 /proc/loadavg)"
	s="$(date +%s.%N)"
	if [ "${arm}" = emcc ]; then
		CT_WASM_CC=emcc CT_NIM_CACHE_ROOT="${cache}" bash ci/lib/run-nim-test-lane.sh "${lane}" >"${log}" 2>&1
	else
		CT_NIM_CACHE_ROOT="${cache}" bash ci/lib/run-nim-test-lane.sh "${lane}" >"${log}" 2>&1
	fi
	e="$(date +%s.%N)"
	load_after="$(cut -d' ' -f1 /proc/loadavg)"
	secs="$(awk -v s="${s}" -v e="${e}" 'BEGIN{printf "%.1f", e - s}')"
	summary="$(grep -E "^${lane}: [0-9]+ file\(s\) passed" "${log}" | tail -1)"
	if [ -z "${summary}" ]; then
		refuse "scenario=${scenario} arm=${arm} rep=${rep}: no lane summary (see ${log})"
		return
	fi
	echo "PLAT18-DEVLANE scenario=${scenario} arm=${arm} lane=${lane} rep=${rep} secs=${secs}" \
		"load_before=${load_before} load_after=${load_after} summary=\"${summary}\""
	printf '%s %s %s %s\t%s\n' "${scenario}" "${arm}" "${rep}" "${secs}" "${summary}" >>"${work}/times.txt"
}

# The edits. Each is applied to the tree once, before the scenario's runs,
# and reverted after them.
apply_edit() { # <scenario> <rep>
	case "$1" in
	edit)
		# A module-level statement in a module every ViewModel suite imports.
		# It runs at module initialisation, so dead-code elimination cannot
		# drop it and the module's generated code changes; what imports the
		# module does not have to.
		printf '\nvar ctDevLoopEdit* = 0  # plat18-dev-lane edit\nctDevLoopEdit.inc %d\n' \
			"$(($2 + 1))" >>"${edit_file}"
		;;
	typeedit)
		# A field in `Location`: every module whose generated code lays the
		# object out changes.
		if ! grep -q '^    ## Source-code position\.$' "${edit_file}"; then
			refuse "scenario=typeedit: the Location anchor moved in ${edit_file}"
			return 1
		fi
		sed -i "s/^    ## Source-code position\.\$/&\n    ctDevLoopField$2*: int  # plat18-dev-lane edit/" "${edit_file}"
		;;
	esac
}

# The edit must have reached the C backends' generated code, or the run
# measured a no-op.
check_edit() { # <scenario> <arm> <rep> <cache>
	local needle
	case "$1" in
	edit) needle=ctDevLoopEdit ;;
	typeedit) needle="ctDevLoopField$3" ;;
	*) return 0 ;;
	esac
	[ "$2" = js ] && return 0
	if ! grep -rlq --include='*.nim.c' "${needle}" "$4" 2>/dev/null; then
		refuse "scenario=$1 arm=$2 rep=$3: the edit is in no generated C file under $4"
	fi
}

# CT_P18_LANE_PARALLEL=1 runs a scenario's arms CONCURRENTLY and waits for
# all of them before the next scenario: every arm then sees the same host
# load at the same moment, which pairs them more tightly than running them
# one after another, at the price of the arms competing with each other.
# The default runs them one after another, in an order rotated per
# repetition.
parallel="${CT_P18_LANE_PARALLEL:-0}"
echo "    mode=$([ "${parallel}" = 1 ] && echo concurrent || echo sequential)"

for rep in $(seq 1 "${reps}"); do
	order=()
	n=${#arms[@]}
	for i in $(seq 0 $((n - 1))); do
		order+=("${arms[$(((i + rep - 1) % n))]}")
	done
	if [ "${rep}" = 1 ]; then
		order+=(${once_arms[@]+"${once_arms[@]}"})
	fi
	for arm in "${order[@]}"; do
		rm -rf "${work}/cache-${arm}-${rep}"
	done
	for scenario in "${scenarios[@]}"; do
		apply_edit "${scenario}" "${rep}" || continue
		for arm in "${order[@]}"; do
			if [ "${parallel}" = 1 ]; then
				run_lane "${scenario}" "${arm}" "${rep}" "${work}/cache-${arm}-${rep}" &
			else
				run_lane "${scenario}" "${arm}" "${rep}" "${work}/cache-${arm}-${rep}"
			fi
		done
		wait
		restore_edit
		for arm in "${order[@]}"; do
			check_edit "${scenario}" "${arm}" "${rep}" "${work}/cache-${arm}-${rep}"
		done
	done
	for arm in "${order[@]}"; do
		rm -rf "${work}/cache-${arm}-${rep}"
	done
done

python3 - "${work}/times.txt" "${threshold}" "${commit}" <<'PY'
import statistics, sys
from collections import defaultdict
path, threshold, commit = sys.argv[1], float(sys.argv[2]), sys.argv[3]
t = defaultdict(dict)
summaries = defaultdict(set)
for line in open(path):
    head, _, summary = line.rstrip("\n").partition("\t")
    sc, arm, rep, secs = head.split()
    t[(sc, int(rep))][arm] = float(secs)
    summaries[(sc, arm)].add(summary)
# A lane that did less work is not faster: an arm's counts must be the same
# on every repetition of a scenario.
moved = {k: v for k, v in summaries.items() if len(v) > 1}
for (sc, arm), v in sorted(moved.items()):
    print(f"PLAT18-DEVLANE INVALID scenario={sc} arm={arm}: counts moved between "
          f"repetitions: {sorted(v)}")
if moved:
    open(path + ".moved", "w").write("moved\n")
scen = sorted({sc for sc, _ in t})
for sc in scen:
    reps = sorted(r for s, r in t if s == sc)
    arms = sorted({a for (s, r) in t if s == sc for a in t[(s, r)]})
    med = {a: statistics.median([t[(sc, r)][a] for r in reps if a in t[(sc, r)]]) for a in arms}
    parts = [f"{a}_median_s={med[a]:.1f}" for a in arms]
    ratios = {}
    for num in ("wasm", "emcc", "native"):
        if num in arms and "js" in arms:
            per = [t[(sc, r)][num] / t[(sc, r)]["js"] for r in reps
                   if num in t[(sc, r)] and "js" in t[(sc, r)]]
            ratios[f"{num}/js"] = statistics.median(per)
    if "wasm" in arms and "native" in arms:
        per = [t[(sc, r)]["wasm"] / t[(sc, r)]["native"] for r in reps
               if "wasm" in t[(sc, r)] and "native" in t[(sc, r)]]
        ratios["wasm/native"] = statistics.median(per)
    rtext = " ".join(f"{k}={v:.2f}" for k, v in ratios.items())
    held = ""
    if "wasm/js" in ratios:
        held = f" criterion=wasm/js<{threshold} {'HELD' if ratios['wasm/js'] < threshold else 'NOT-HELD'}"
    print(f"PLAT18-DEVLANE-RATIO scenario={sc} commit={commit} reps={len(reps)} "
          f"{' '.join(parts)} {rtext}{held} (median of per-repetition ratios)")
PY

invalid=0
[ -f "${invalid_file}" ] && invalid="$(wc -l <"${invalid_file}")"
[ -f "${work}/times.txt.moved" ] && invalid=$((invalid + 1))
if [ "${invalid}" -ne 0 ]; then
	echo "plat18-dev-lane: ${invalid} invalid run(s)"
	exit 1
fi
exit 0
