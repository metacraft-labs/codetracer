#!/usr/bin/env bash
#
# plat18-electron-slice.sh — PLAT-18 deliverable 2: the vertical slice.
#
# Builds the variables pane THREE ways from ONE source and runs all three
# against one real document in one Electron renderer process:
#
#   js-direct      `nim js`                     the CURRENT build: JS core, WebRenderer, one heap
#   js-crossing    `nim js -d:ctPlat18Frame`    same core, serialised boundary
#   wasm-crossing  wasm32 browser build          PLAT-17's core, same boundary
#
# The middle arm is the control that separates "wasm is slower" from "a
# serialised boundary is slower". Those have opposite implications and two
# arms cannot tell them apart; see `plat18_slice.nim`'s header.
#
# ## THE BUILD IS NAMED, BECAUSE A TIMING QUOTES ITS BUILD
#
# Verification-Harness-Traps.md §12b. Every arm is compiled DEBUG (no
# `-d:release`, no `-d:danger`) with `--mm:orc` on the wasm arm, so the three
# match each other and match PLAT-17's lane. `CT_P18_RELEASE=1` builds all
# three `-d:release` instead, and the report says which it was — a debug
# figure compared against a release one is not a comparison.
#
# ## WHY THE WASM ARM IS A DIFFERENT BUILD FROM PLAT-17's LANE
#
# PLAT-17's bound 1: its lane runs under node with `-sNODERAWFS=1`, and a
# browser has no filesystem. This arm is `-sENVIRONMENT=web`, no NODERAWFS,
# `-sMODULARIZE=1` — a build that can be loaded from an ordinary page. The
# artifact size below is therefore NOT PLAT-17's 1,178,754 B and must not be
# compared with it as though it were.
#
# ## EXIT STATUS
#
#   0  every arm ran, every phase's row counts agreed with the document
#   1  a build failed, an arm did not register, or a check voided the run
#   2  a prerequisite is missing — and that is a FAILURE, never a skip, for
#      the reason PLAT-17's lane runner gives: a harness that answers
#      "nothing to do, exit 0" on the machine where a tool stopped resolving
#      satisfies every aggregate above it while measuring nothing.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

samples="${CT_P18_SAMPLES:-9}"
out="${CT_P18_OUT:-${repo_root}/test-logs/plat18-slice}"
host_src="src/frontend/viewmodel/tests/manual/plat18_slice_host"
slice_src="src/frontend/viewmodel/tests/manual/plat18_slice.nim"

# ---------------------------------------------------------------------------
# Prerequisites — named, with the remedy, and fatal
# ---------------------------------------------------------------------------
missing=0
for tool in nim emcc node electron; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: ${tool} is not on PATH." >&2
		missing=1
	fi
done
if [ "${missing}" -ne 0 ]; then
	echo "       Run inside this repo's dev shell (direnv exec . …); it provides" >&2
	echo "       nim, emscripten, node and electron." >&2
	exit 2
fi

# Electron needs a display. There is no headless arm that still runs a real
# Chromium renderer with a real DOM, which is the whole point of this slice,
# so an absent X server is a prerequisite failure and not a reason to measure
# something else.
xvfb_run="$(command -v xvfb-run || true)"
if [ -z "${DISPLAY:-}" ] && [ -z "${xvfb_run}" ]; then
	# The two tool names are spelled WITHOUT a leading `$` on purpose. Written
	# as `\$DISPLAY` inside double quotes, pre-commit `shfmt -s` rewrites the
	# line to single quotes; shellcheck then reports SC2016 on the `$` and
	# exits non-zero, so the pair of hooks has no fixed point on that spelling.
	echo "ERROR: Electron needs a display and neither DISPLAY nor xvfb-run is set." >&2
	echo "       Set DISPLAY, or put xvfb-run on PATH." >&2
	exit 2
fi

rm -rf "${out}"
mkdir -p "${out}"

opt_flags=()
build_label="debug"
if [ "${CT_P18_RELEASE:-0}" = "1" ]; then
	opt_flags=(-d:release)
	build_label="release"
fi

nim_common=(--hints:off --warnings:off --path:src/frontend/viewmodel)
cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/plat18-slice-${build_label}"

echo "=== PLAT-18 vertical slice: variables pane, 600-member fixture ==="
echo "    build=${build_label} samples=${samples}"
echo "    host load at start: $(cat /proc/loadavg 2>/dev/null || uptime)"

# ---------------------------------------------------------------------------
# Arm 1 — js-direct: THE CURRENT BUILD
# ---------------------------------------------------------------------------
# `-d:ctRenderer` and `-d:chronicles_enabled=off` are the product's own
# renderer defines, taken from the `renderer-electron` lane in
# ci/lib/test-lane-files.sh rather than invented here: this arm is only the
# current build if it is compiled the way the current build is.
echo "--- building js-direct ---"
if ! nim js "${nim_common[@]}" "${opt_flags[@]}" \
	-d:ctRenderer -d:chronicles_enabled=off \
	--nimcache:"${cache_root}/js-direct" \
	-o:"${out}/arm_js_direct.raw.js" "${slice_src}"; then
	echo "PLAT18-SLICE-VERDICT FAIL js-direct did not build"
	exit 1
fi

# ---------------------------------------------------------------------------
# Arm 2 — js-crossing
# ---------------------------------------------------------------------------
# THE SAME PRODUCT DEFINES AS js-direct, and that is load-bearing rather than
# tidy: the two JS arms must differ in ONE thing, the boundary. Built without
# them the crossing arm pulled in a module that emits `require`, which a
# browser has not got — the bundle died with `ReferenceError: require is not
# defined` while loading, registered no global, and the run reported two arms
# and a clean verdict. The arm list below is what caught it.
echo "--- building js-crossing ---"
if ! nim js "${nim_common[@]}" "${opt_flags[@]}" \
	-d:ctRenderer -d:chronicles_enabled=off \
	-d:ctPlat18Slice -d:ctPlat18Frame \
	--nimcache:"${cache_root}/js-crossing" \
	-o:"${out}/arm_js_crossing.raw.js" "${slice_src}"; then
	echo "PLAT18-SLICE-VERDICT FAIL js-crossing did not build"
	exit 1
fi

# BOTH `nim js` bundles go into ONE page, and both declare top-level names
# (`p18Mount`, the frame's own `ctP18_buf`, Nim's runtime). Loaded as-is the
# second would silently overwrite the first and the "two arms" would be one
# arm measured twice — a chain of plausible numbers over a world that does not
# exist. An IIFE per bundle is the whole remedy; each installs its own global
# from inside it.
for arm in js_direct js_crossing; do
	{
		echo "(function(){"
		cat "${out}/arm_${arm}.raw.js"
		echo "})();"
	} >"${out}/arm_${arm}.js"
done

# ---------------------------------------------------------------------------
# Arm 3 — wasm-crossing: PLAT-17's core, built for a BROWSER
# ---------------------------------------------------------------------------
echo "--- building wasm-crossing ---"
wasm_exports="_main,_p18Reset,_p18Mount,_p18BeginFrame,_p18Expand,_p18Step"
wasm_exports="${wasm_exports},_p18Collapse,_p18Rows,_p18FrameBase,_p18FrameLen"
wasm_exports="${wasm_exports},_p18Ops,_p18ReadCrossings,_p18Dispatch,_p18OpManifest"
if ! nim c "${nim_common[@]}" "${opt_flags[@]}" \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	-d:ctPlat18Slice -d:ctPlat18Frame \
	--passL:-sSTACK_SIZE=8388608 \
	--passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=0 \
	--passL:-sMODULARIZE=1 \
	--passL:-sEXPORT_NAME=ctP18Module \
	--passL:-sENVIRONMENT=web \
	--passL:"-sEXPORTED_FUNCTIONS=${wasm_exports}" \
	--passL:-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,HEAPU8 \
	--nimcache:"${cache_root}/wasm" \
	-o:"${out}/arm_wasm.js" "${slice_src}"; then
	echo "PLAT18-SLICE-VERDICT FAIL wasm-crossing did not build"
	exit 1
fi

# ---------------------------------------------------------------------------
# Artifact sizes — §4 metric 6, taken here because this is the only place the
# three builds exist side by side and were produced by the same command.
# ---------------------------------------------------------------------------
size_of() { wc -c <"$1" | tr -d ' '; }
js_direct_bytes="$(size_of "${out}/arm_js_direct.raw.js")"
js_crossing_bytes="$(size_of "${out}/arm_js_crossing.raw.js")"
wasm_glue_bytes="$(size_of "${out}/arm_wasm.js")"
wasm_bytes="$(size_of "${out}/arm_wasm.wasm")"
# GZIPPED TOO, because that is what crosses a network. A raw `nim js` bundle
# is unminified source and a `.wasm` is already a compact binary format, so the
# raw comparison flatters wasm; gzip is the closer stand-in for what a browser
# actually downloads. Both are reported, and neither is quoted alone.
gz_of() { gzip -9 -c "$1" | wc -c | tr -d ' '; }
echo "PLAT18-SLICE-ARTIFACT-GZIP build=${build_label}" \
	"js_direct_gz=$(gz_of "${out}/arm_js_direct.raw.js")" \
	"js_crossing_gz=$(gz_of "${out}/arm_js_crossing.raw.js")" \
	"wasm_glue_gz=$(gz_of "${out}/arm_wasm.js")" \
	"wasm_gz=$(gz_of "${out}/arm_wasm.wasm")"
echo "PLAT18-SLICE-ARTIFACT build=${build_label}" \
	"js_direct_bytes=${js_direct_bytes}" \
	"js_crossing_bytes=${js_crossing_bytes}" \
	"wasm_glue_bytes=${wasm_glue_bytes}" \
	"wasm_bytes=${wasm_bytes}" \
	"wasm_total_bytes=$((wasm_glue_bytes + wasm_bytes))"

# ---------------------------------------------------------------------------
# Assemble the page
# ---------------------------------------------------------------------------
cp "${host_src}/applier.js" "${host_src}/driver.js" \
	"${host_src}/wasm_bridge.js" "${host_src}/main.js" \
	"${host_src}/coldstart.html" "${out}/"
cat >"${out}/package.json" <<'PKG'
{"name":"plat18-slice","version":"1.0.0","main":"main.js"}
PKG
sed -e 's|@APPLIER@|applier.js|' \
	-e 's|@DRIVER@|driver.js|' \
	-e 's|@WASM_BRIDGE@|wasm_bridge.js|' \
	-e 's|@JS_DIRECT@|arm_js_direct.js|' \
	-e 's|@JS_CROSSING@|arm_js_crossing.js|' \
	-e 's|@WASM_GLUE@|arm_wasm.js|' \
	"${host_src}/page.html" >"${out}/page.html"
printf 'globalThis.CT_P18_SAMPLES = %s;\n' "${samples}" >"${out}/samples.js"
sed -i 's|<script src="applier.js"></script>|<script src="samples.js"></script>\n    <script src="applier.js"></script>|' \
	"${out}/page.html"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo "--- running (electron) ---"
load_before="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
run_log="${out}/run.log"
if [ -n "${DISPLAY:-}" ]; then
	(cd "${out}" && electron . --no-sandbox) >"${run_log}" 2>&1
	rc=$?
else
	(cd "${out}" && "${xvfb_run}" -a electron . --no-sandbox) >"${run_log}" 2>&1
	rc=$?
fi
load_after="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"

grep '^PLAT18-' "${run_log}" || true
echo "PLAT18-SLICE-HOST cpus=$(nproc 2>/dev/null || echo '?')" \
	"load_before=\"${load_before}\" load_after=\"${load_after}\"" \
	"build=${build_label} samples=${samples}"

if ! grep -q '^PLAT18-SLICE-VERDICT ok$' "${run_log}"; then
	echo "PLAT-18 slice: FAILED — see ${run_log}"
	sed -n '1,60p' "${run_log}" >&2
	exit 1
fi

# THE ARM LIST IS A NON-VACUITY FLOOR. A run in which one bundle failed to
# register its global would still print a verdict and a set of perfectly
# self-consistent numbers — for two arms, or one. The comparison this script
# exists to make needs all three, so their presence is asserted rather than
# assumed.
if ! grep -q '^PLAT18-SLICE-ARMS js-direct,js-crossing,wasm-crossing$' "${run_log}"; then
	echo "PLAT-18 slice: FAILED — not all three arms registered:" >&2
	grep '^PLAT18-SLICE-ARMS' "${run_log}" >&2 || echo "  (no arm line at all)" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# PUBLISH — §6 step 4: "publish the numbers with their conditions in a
# benchmark entry, in the format CTUI-14 established, with real sample counts
# and shapes rather than a stamped constant".
# ---------------------------------------------------------------------------
#
# Its own file rather than `bench-results/benchmark_results.json`, which
# `src/frontend/tui/benchmarks/tui_benchmarks.nim` REWRITES whole on every
# `just bench`: an entry appended there would survive exactly until the next
# TUI benchmark run, and a published figure that disappears is worse than one
# that was never published.
#
# Every entry carries `load1`, `cpus`, `samples` and `shape`, per entry and not
# per run, because the entries below are not made the same way — four are
# medians over `${samples}` interleaved repetitions, three are ONE load of ONE
# renderer process, and three are a `wc -c`. CTUI-14's own header records what
# happens when a suite's loop count is appended to all twelve: it tells a
# reader of the committed artifact that a cold start was averaged over two
# hundred spawns.
#
# AND IT REFUSES TO PUBLISH A RUN THAT WAS NOT A MEASUREMENT. The mutation
# harness drives this script at `CT_P18_SAMPLES=1` — an arm needs the run to
# refuse, not a distribution — and it does so fifteen times per pass. Without
# the floor below, the last of those would overwrite the committed entries
# with single-sample figures taken while a file was mutated, and the published
# artifact would say `samples=1` for numbers a reader is entitled to read as
# medians. A count in a `shape=` field is a claim; this is what keeps it true.
#
# ## A VERIFIER MUST RAISE THE FLOOR, AND THIS IS NOT OPTIONAL ADVICE
#
# The floor stops a run that was not a measurement. It does NOT stop a run
# that was a perfectly good measurement taken under different conditions from
# the published one — and any run at the default `CT_P18_SAMPLES=9`, or at any
# count at or above the floor, REWRITES `bench-results/plat18-marshalling.json`
# WHOLE. Reproducing the published figures therefore destroys them: a
# 15-sample reproduction on this tree replaced the committed `load1=40.10`
# entries with `load1=10.20` ones, and only the git index knew.
#
# So anyone re-running this script to CHECK the published numbers must set the
# floor above their own sample count:
#
#     CT_P18_BENCH_MIN_SAMPLES=99 bash ci/test/plat18-electron-slice.sh
#
# The run then stands in full — every contract, every arm, every printed
# figure — and the artifact is not touched. Publish deliberately, by lowering
# the floor again, or not at all. The committed artifact's identity is
# `sha256 2c85998b…`, 22 entries, `load1=40.10`; `sha256sum` it before and
# after if there is any doubt about which state a tree is in.
bench_min_samples="${CT_P18_BENCH_MIN_SAMPLES:-5}"
if [ "${samples}" -lt "${bench_min_samples}" ]; then
	echo "PLAT18-SLICE-BENCH skipped: ${samples} sample(s) is under the" \
		"${bench_min_samples}-sample floor for publishing; the run stands," \
		"the benchmark entries are not rewritten"
	echo "PLAT-18 slice: ok (${rc})"
	exit 0
fi
bench_dir="${repo_root}/bench-results"
mkdir -p "${bench_dir}"
python3 - "${run_log}" "${bench_dir}/plat18-marshalling.json" \
	"${build_label}" "${samples}" "${load_before}" \
	"${js_direct_bytes}" "${wasm_bytes}" "${wasm_glue_bytes}" <<'PYBENCH'
import json, re, sys

run_log, out_path, build, samples, load1, js_bytes, wasm_bytes, glue_bytes = sys.argv[1:9]
text = open(run_log, errors="replace").read()
load1 = load1.split()[0] if load1.split() else "unknown"

def kv(line):
    return dict(re.findall(r"([a-z_0-9]+)=([^\s]+)", line))

phases, cold, rss, artifacts = {}, {}, {}, {}
for line in text.splitlines():
    if line.startswith("PLAT18-SLICE arm="):
        d = kv(line)
        phases[(d["arm"], d["phase"])] = d
    elif line.startswith("PLAT18-SLICE-COLDSTART arm="):
        d = kv(line)
        cold[d["arm"]] = d
    elif line.startswith("PLAT18-SLICE-RSS arm="):
        d = kv(line)
        rss[d["arm"]] = d

entries = []

def add(name, unit, value, extra):
    entries.append({"name": name, "unit": unit, "value": value,
                    "extra": f"load1={load1} cpus={__import__('os').cpu_count()} "
                             f"build={build} {extra}"})

# §4 metric 2 and 3 — step latency, and latency with the large state tree.
for arm in ("js-direct", "js-crossing", "wasm-crossing"):
    for ph, what in (("STEP", "one locals update with the 600-member node OPEN"),
                     ("EXPAND", "the 600-member node expands: 600 rows appear in one update"),
                     ("MOUNT", "the pane's first render, the node collapsed"),
                     ("COLLAPSE", "the 600 rows are removed")):
        d = phases.get((arm, ph))
        if not d:
            continue
        add(f"plat18/{ph.lower()}-total/{arm}", "ms", float(d["total_ms_median"]),
            f'samples={d["samples"]} shape="the MEDIAN of {d["samples"]} interleaved '
            f'repetitions of all three arms against one document in one Electron '
            f'renderer; one repetition is {what}" '
            f'core_ms={d["core_ms_median"]} host_ms={d["host_ms_median"]} '
            f'min={d["total_ms_min"]} max={d["total_ms_max"]} '
            f'bytes_crossed={d["bytes"]} ops={d["ops"]} rows=602')

# §4 metric 5 — bytes marshalled per step. A COUNT, not a timing: it is a
# property of the view and the fixture and is the same integer on every
# backend, which is why its sample count is 1 and saying so matters.
step = phases.get(("wasm-crossing", "STEP"))
expand = phases.get(("wasm-crossing", "EXPAND"))
if step:
    add("plat18/bytes-per-step", "bytes", int(step["bytes"]),
        'samples=1 shape="a STRUCTURAL count, not a measurement: the flat wire '
        'size of the operations one locals update issues with 602 rows on screen. '
        'Identical on native, nim js and wasm32 — that is what makes the three '
        'comparable" ops=' + step["ops"])
if expand:
    add("plat18/bytes-per-expand", "bytes", int(expand["bytes"]),
        'samples=1 shape="the same count for the worst case in the product: the '
        '600-member mapping expanding in one update" ops=' + expand["ops"])

# §4 metric 1 — cold start.
for arm, d in cold.items():
    if "to_entry_points_ms" not in d:
        continue
    add(f"plat18/cold-start/{arm}", "ms", float(d["to_entry_points_ms"]),
        'samples=1 shape="ONE load of ONE renderer process — a cold start is a '
        'property of a process\'s first moments and a second one would not be '
        'cold. Script fetch, parse and evaluate, plus (wasm) compile, instantiate '
        'and run main, to the point where the entry points exist" '
        'target<=20%-regression-vs-js-direct')

# §4 metric 4 — steady-state memory.
for arm, d in rss.items():
    if "working_set_kb" not in d:
        continue
    add(f"plat18/steady-rss/{arm}", "MB", round(int(d["working_set_kb"]) / 1024.0, 3),
        'samples=1 shape="ONE read of Electron getAppMetrics() for ONE renderer '
        'process holding the 602-row pane — a resident set is a state, not a '
        'distribution. performance.memory.usedJSHeapSize was tried and rejected: '
        'Chromium coarsens it and all three arms reported the identical '
        '157,000,000 with one of them additionally holding 50 MiB of linear '
        'memory" target<=25%-growth-vs-js-direct')

# §4 metric 6 — artifact size.
add("plat18/artifact/js-direct", "bytes", int(js_bytes),
    'samples=1 shape="wc -c of the nim js bundle, UNMINIFIED and unbundled — the '
    'shipped renderer goes through webpack, so this over-states what a user '
    'downloads; the gzip figures in the run log are the closer stand-in"')
add("plat18/artifact/wasm", "bytes", int(wasm_bytes) + int(glue_bytes),
    'samples=1 shape="wc -c of the .wasm plus its emscripten glue, browser '
    'target (-sENVIRONMENT=web, no NODERAWFS). NOT PLAT-17\'s 1,178,754 B, '
    'which is the node build"')

json.dump(entries, open(out_path, "w"), indent=2)
print(f"PLAT18-SLICE-BENCH wrote {len(entries)} entry(ies) to {out_path}")
PYBENCH

echo "PLAT-18 slice: ok (${rc})"
exit 0
