#!/usr/bin/env bash
# plat35-gpui-capture.sh — PLAT-35's GPUI PIXEL capture, with no compositor.
#
# ## What this lane is, and what it is not
#
# `codetracer-specs/spec/Methodologies/visual-design-iteration.md` needs a capture
# step: an image file at a known path, for a named view at a named viewport,
# targetable one view at a time. PLAT-35 had one for the Electron front-end
# (`src/tests/gui/tests/visual/visual-alignment-capture.spec.ts`) and none at
# all for the GPUI one — `PLAT35-VG1` — so every cross-front-end claim about
# pixels was argued rather than measured.
#
# The nine existing GPUI window lanes cannot supply it on every host, and that
# is measured rather than asserted:
# `codetracer-specs/issues/2026-09-29-gpui-window-capture-lanes-are-wayland-only.md`
# records all nine taking their frames from `grim`, a
# `zwlr_screencopy_manager_v1` client, under a nested headless `sway`. On
# aarch64-darwin none of `sway`, `grim`, `wayland-info` or `wtype` exists, a
# `codetracer-gpui` window DOES open (`CGWindowListCopyWindowInfo` reports
# `owner=codetracer-gpui bounds=1280x829 layer=0`), and reading that window's
# pixels is TCC-refused: `screencapture -x -o -l<id>` answers *"could not
# create image from window"*, rc 1.
#
# So this lane takes the other pixel path — `gpui_render_to_pixels` under
# `--features gpui-headless`, which needs no compositor and no entitlement —
# and runs on BOTH platforms for the same reason: a capture lane that only
# exists on one operating system is how a milestone's pixel half stays
# permanently partial.
#
# **IT DOES NOT SATISFY G1 AND SAYS SO IN EVERY RECORD IT WRITES.** PLAT-23's
# G1 asks that *a window has been observed*; an off-screen RGBA buffer is a
# frame and is not a window. `satisfiesG1: false` is in each scenario's census
# and in the manifest, because the whole reason PLAT-37 wrote the two pixel
# paths down as a table is that one of them cannot answer the other's
# question. The windowed lane (`plat37-window-frame.sh`) keeps G1.
#
# ## The content assertion, and why existence is not one
#
# **A capture that writes a file is not evidence the scene rendered.** A
# renderer handed a tree it cannot draw returns a correctly-sized buffer of
# zeroes, and `[ -s "$png" ]` passes on it. Each scenario is therefore graded
# on the census the binary itself wrote — `producedAFrame`, `nonZeroBytes` and
# `distinctByteValues` — exactly as `ci/test/plat37_headless_probe.nim` grades
# its own 320x200 scene, and `codetracer-gpui` exits non-zero on a blank frame
# before this script even looks.
#
# ## Usage
#
#   bash ci/test/plat35-gpui-capture.sh                  # all six scenarios
#   bash ci/test/plat35-gpui-capture.sh --only shell     # one view
#   bash ci/test/plat35-gpui-capture.sh --out build/x    # elsewhere
#
# `--only` takes a VIEW name (the methodology's `--view` targeting), which is
# what a review iteration re-captures; the scenario ids are an implementation
# detail of the corpus and the views are what the brief's expected-elements
# blocks are keyed by.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISONIM_GPUI="${ISONIM_GPUI:-$(cd "${root}/.." && pwd)/isonim-gpui}"
SCENARIOS="${root}/src/tests/visual/scenarios.json"
BIN="${root}/build/bin/codetracer-gpui"
OUT="${root}/build/plat35/gpui"
ONLY=""

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--only)
		ONLY="${2:?--only needs a view name}"
		shift 2
		;;
	--out)
		OUT="${2:?--out needs a directory}"
		shift 2
		;;
	*) fail "unknown argument '$1'" ;;
	esac
done

# ---------------------------------------------------------------------------
# The shim — SELECTED BY FILE SUBSTITUTION, for the measured reason
# ---------------------------------------------------------------------------
#
# `isonim_gpui/bindings.nim` resolves the cdylib at COMPILE time and bakes the
# absolute path `…/isonim-gpui/rust/target/debug/libgpui_nim_shim.<ext>` into
# its `{.dynlib.}` pragma. `dlopen` on an absolute path consults neither
# `LD_LIBRARY_PATH` nor `DYLD_LIBRARY_PATH`, so a lane that set either would
# have run against whichever shim happened to be at that path — and would have
# reported `RendererUnavailable` while believing it had selected the headless
# build. `plat37-window-frame.sh` carries the same measurement and the same
# remedy; the one thing added here is that the extension is derived rather
# than spelled `.so`, which is what made that lane macOS-only.
case "$(uname -s)" in
Darwin) SHIM_EXT="dylib" ;;
*) SHIM_EXT="so" ;;
esac
SHIM_DIR="${ISONIM_GPUI}/rust/target/plat37"
LIVE_SHIM="${ISONIM_GPUI}/rust/target/debug/libgpui_nim_shim.${SHIM_EXT}"
HEADLESS_SHIM="${SHIM_DIR}/libgpui_nim_shim.headless.${SHIM_EXT}"
SHIM_BACKUP=""

restore_shim() {
	if [ -n "${SHIM_BACKUP}" ] && [ -f "${SHIM_BACKUP}" ]; then
		mv -f "${SHIM_BACKUP}" "${LIVE_SHIM}"
		SHIM_BACKUP=""
		echo "restored ${LIVE_SHIM}"
	fi
}
trap restore_shim EXIT

[ -x "${BIN}" ] || fail "${BIN} is not built. Run \`just build-gpui\`."
[ -f "${SCENARIOS}" ] || fail "the scenario set is not at ${SCENARIOS}"
[ -f "${HEADLESS_SHIM}" ] || fail "the headless shim is not at ${HEADLESS_SHIM}.
      Build all three in the sibling's own dev shell, which is where the
      linker flags are declared:

          cd ${ISONIM_GPUI} && nix develop --command just plat37-shims

      This lane does NOT build it: measured 2026-09-22, a shim build run from
      codetracer's dev shell fails to link."

# The recording. Resolved the same way `plat37-window-frame.sh` resolves it,
# and REFUSED rather than skipped when it is absent: a green run over no
# recording is worth less than a red one.
TRACE="${CODETRACER_PLAT35_TRACE:-${CODETRACER_PLAT37_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}}"
[ -d "${TRACE}" ] || fail "the \`calc\` recording is not at ${TRACE}.
      Point CODETRACER_PLAT35_TRACE at one, or produce it through the tui
      lane's fixture provider (\`just test-tui\` once)."

mkdir -p "${OUT}"

# ---------------------------------------------------------------------------
# The scenario set, READ from scenarios.json and never listed here
# ---------------------------------------------------------------------------
#
# `expectedScenarios` is asserted against the parsed length, so a parser that
# stopped early cannot pass — the two-sidedness both of PLAT-35's existing
# readers already have. The viewport comes out of the same file, so a lane
# that captured everything at one size could not claim the matrix.
SPEC="${OUT}/scenarios.tsv"
python3 - "${SCENARIOS}" "${SPEC}" <<'PY' || fail "the scenario set did not parse"
import json, sys
doc = json.load(open(sys.argv[1]))
scenarios = doc["scenarios"]
if len(scenarios) != doc["expectedScenarios"]:
    sys.exit(f"FAIL: scenarios.json declares {doc['expectedScenarios']} "
             f"scenarios and holds {len(scenarios)}")
kinds = set(doc["operationKinds"])
viewports = doc["viewports"]
if len(viewports) != doc["expectedViewports"]:
    sys.exit(f"FAIL: scenarios.json declares {doc['expectedViewports']} "
             f"viewports and holds {len(viewports)}")
rows = []
for sc in scenarios:
    terms = []
    for op in sc["operations"]:
        kind = op["kind"]
        if kind not in kinds:
            sys.exit(f"FAIL: scenario {sc['id']} uses operation '{kind}', "
                     f"which operationKinds does not publish")
        terms.append(f"{kind}@{op['line']}" if kind == "setBreakpoint"
                     else f"{kind}={op.get('times', 1)}")
    vp = viewports[sc["viewport"]]
    rows.append("\t".join([sc["id"], sc["view"], str(vp["width"]),
                           str(vp["height"]), ",".join(terms)]))
open(sys.argv[2], "w").write("\n".join(rows) + "\n")
print(f"scenarios.json: {len(scenarios)} scenarios, {len(kinds)} operation "
      f"kinds, {len(viewports)} viewports")
PY

# ---------------------------------------------------------------------------
# Stage the headless shim and capture
# ---------------------------------------------------------------------------
if [ -z "${SHIM_BACKUP}" ] && [ -f "${LIVE_SHIM}" ]; then
	SHIM_BACKUP="${LIVE_SHIM}.plat35-backup"
	cp -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
fi
cp -f "${HEADLESS_SHIM}" "${LIVE_SHIM}"
echo "shim in place: headless ($(wc -c <"${LIVE_SHIM}" | tr -d ' ') bytes)"

RECORDS="${OUT}/records.jsonl"
: >"${RECORDS}"
captured=0
refused=0

while IFS=$'\t' read -r id view width height ops; do
	[ -n "${id}" ] || continue
	if [ -n "${ONLY}" ] && [ "${view}" != "${ONLY}" ]; then
		continue
	fi
	png="${OUT}/${view}.png"
	log="${OUT}/${view}.capture.log"
	rm -f "${png}" "${png}.json" "${log}"
	argv=("${BIN}" "--width=${width}" "--height=${height}"
		"--pixels-out=${png}" "--pixels-view=${view}"
		"--pixels-scenario=${id}")
	[ -n "${ops}" ] && argv+=("--replay-ops=${ops}")
	argv+=("${TRACE}")
	echo
	echo "### ${id} -> ${view} at ${width}x${height} [${ops:-no operations}]"
	if "${argv[@]}" >"${log}" 2>&1; then
		rc=0
	else
		rc=$?
	fi
	tail -3 "${log}"
	# THE CENSUS IS THE VERDICT, not the exit code and not the file's size.
	# A record is written on every path the binary reaches, INCLUDING a
	# refusal, so "the capture ran and this host has no headless renderer"
	# is distinguishable from "the capture did not run"
	# (Verification-Harness-Traps §4).
	if [ ! -f "${png}.json" ]; then
		echo "  no census written (rc ${rc})" >&2
		refused=$((refused + 1))
		continue
	fi
	verdict="$(
		python3 - "${png}.json" "${png}" "${width}" "${height}" "${id}" \
			"${view}" <<'PY'
import json, os, struct, sys
rec = json.load(open(sys.argv[1]))
png, width, height, sid, view = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
problems = []
if rec["scenario"] != sid or rec["view"] != view:
    problems.append(f"the census says {rec['view']}/{rec['scenario']}")
if rec["width"] != width or rec["height"] != height:
    problems.append(f"the census says {rec['width']}x{rec['height']}")
if not rec["producedAFrame"]:
    problems.append(f"no frame: rc={rec['rc']} ({rec['rcMeaning']})")
if rec["isBlank"]:
    problems.append("the frame is blank")
if rec["satisfiesG1"]:
    problems.append("this path must never claim G1")
if not problems:
    # THE PNG'S OWN IHDR, against the declared viewport. The census is the
    # binary's word for what it rendered; the IHDR is the artefact's word
    # for what it holds, and PLAT-35 already lost a milestone-month to a
    # viewport matrix that was asserted from the DECLARATION.
    if not os.path.exists(png):
        problems.append("the census claims a frame and there is no image")
    else:
        head = open(png, "rb").read(33)
        if head[:8] != b"\x89PNG\r\n\x1a\n":
            problems.append("the image is not a PNG")
        else:
            iw, ih = struct.unpack(">II", head[16:24])
            if (iw, ih) != (width, height):
                problems.append(f"the PNG's IHDR is {iw}x{ih}")
print("OK" if not problems else "BAD: " + "; ".join(problems))
PY
	)"
	echo "  ${verdict}"
	if [ "${verdict}" = "OK" ]; then
		captured=$((captured + 1))
		python3 -c "
import json,sys
rec=json.load(open(sys.argv[1]))
rec['png']=sys.argv[2]
rec['pngBytes']=__import__('os').path.getsize(sys.argv[2])
print(json.dumps(rec))" "${png}.json" "${png}" >>"${RECORDS}"
	else
		refused=$((refused + 1))
		python3 -c "
import json,sys
rec=json.load(open(sys.argv[1]))
rec['refusal']=sys.argv[2]
print(json.dumps(rec))" "${png}.json" "${verdict}" >>"${RECORDS}"
	fi
done <"${SPEC}"

restore_shim

echo
echo "=== ${captured} captured, ${refused} refused ==="
expected="$(python3 -c "
import json,sys
doc=json.load(open(sys.argv[1]))
only=sys.argv[2]
print(sum(1 for s in doc['scenarios'] if not only or s['view']==only))
" "${SCENARIOS}" "${ONLY}")"
# THE POPULATION, NOT THE PROPERTY (§34). The realised count is asserted
# against the scenario set's own cardinality, read off the runs that happened.
total=$((captured + refused))
# **A `--only` THAT MATCHED NOTHING IS A FAILURE AND NOT A PASS**, and this
# clause is here because the first run of the negative control earned it: with
# `--only nosuchview` the lane printed `0 captured, 0 refused` and
# `OK: 0 of 0 frames`, which is the Silent-Self-Pass shape
# (`Verification-Harness-Traps` §4) — a green run over an empty population. It
# is a typo away from a review iteration that re-captures nothing and reports
# success, and the reviewer then grades the previous iteration's image.
#
# The equality below could not catch it on its own, because `expected` is
# derived from the SAME filter: zero equals zero.
if [ "${expected}" -eq 0 ]; then
	fail "no scenario has the view '${ONLY}'. The view names are
      scenarios.json's own: $(cut -f2 "${SPEC}" | paste -sd' ' -)"
fi
[ "${total}" -eq "${expected}" ] ||
	fail "${total} scenarios ran where ${expected} were declared"
[ "${refused}" -eq 0 ] || fail "${refused} of ${total} scenarios produced no frame"
echo "OK: ${captured} of ${expected} frames in ${OUT}"
