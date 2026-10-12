#!/usr/bin/env bash
#
# plat37-macos-window-capture.sh — PLAT-37's G1 lane ON macOS.
#
#   bash ci/test/plat37-macos-window-capture.sh             # all seven
#   bash ci/test/plat37-macos-window-capture.sh --only state
#   bash ci/test/plat37-macos-window-capture.sh --out build/x
#   bash ci/test/plat37-macos-window-capture.sh --controls-only
#
# ===========================================================================
# WHAT THIS LANE IS
# ===========================================================================
#
# It opens a REAL `codetracer-gpui` window on the macOS window server, once
# per pinned scenario, attests it through `CGWindowListCopyWindowInfo`,
# captures THAT WINDOW'S OWN SURFACE through ScreenCaptureKit, and grades the
# frame with PLAT-39's screen oracle.
#
# It is the first thing in this tree entitled to write `satisfiesG1: true`.
# PLAT-23's G1 asks that *a window has been observed*; PLAT-37's own note
# reads **"G1 ON macOS: A WINDOW IS OBSERVED; ITS PIXELS ARE NOT."** This lane
# closes the second clause. `ci/test/plat35-gpui-capture.sh` renders off
# screen and writes `satisfiesG1: false` — correctly, and its grader actively
# FAILS any census that claims otherwise (`if rec["satisfiesG1"]: problems`).
# Nothing here changes that; this is a different path with a different
# standing, and the two are labelled per record exactly as
# `plat37-window-frame.sh`'s `pixelPaths` table labels its two.
#
# ===========================================================================
# ITS STANDING: HOST-CONDITIONAL EVIDENCE, NEVER A REQUIRED GATE
# ===========================================================================
#
# This lane needs a live macOS GUI session and a `kTCCServiceScreenCapture`
# grant held by `com.metacraft-labs.guiassert.capture`. Neither exists on a
# fresh host, and neither exists in CI.
# `codetracer-specs/issues/2026-09-29-gpui-window-capture-lanes-are-wayland-only.md`
# names that cost itself: a TCC-dependent lane *"would make the lane
# non-reproducible on a fresh host"*. That is true and it is accepted,
# because the alternative on this platform is no G1 evidence at all.
#
# So: **do not wire this into a required check.** PLAT-23's G5 — *"a gate
# cannot be passed by a measurement that could not have failed"* — has a
# mirror image that matters just as much here: a gate that cannot RUN is not
# a gate, it is a green tick for an absent machine. Every record this lane
# writes carries `standing: HOST-CONDITIONAL EVIDENCE`.
#
# ===========================================================================
# WHAT IT REUSES, AND THE ONE THING IT DOES NOT
# ===========================================================================
#
#  * `src/tests/visual/scenarios.json` — the six scenarios and the one GPUI
#    probe, read with the SAME parser and the SAME cardinality assertions
#    `plat35-gpui-capture.sh` uses. NO SEVENTH SCENARIO.
#  * `src/tests/visual/screen_oracle/*` — every reading predicate, through
#    `readFrame`. The grader chooses the OCR engine and writes down what came
#    back; it re-implements nothing.
#  * `ci/test/plat35-gpui-capture.sh`'s driver loop, shim-substitution
#    mechanism and census shape.
#  * GuiAssert `3058e0c`'s `captureWindowStill` and `window_layout`.
#
# IT DOES NOT USE THE HEADLESS SHIM AND DOES NOT SWAP TO IT. `plat35` stages
# `gpui-headless` because its path renders off screen. This lane stages the
# WINDOWED shim (`--features gpui-backend`), because a window is the point.
#
# IT DOES NOT PORT THE THIRTEEN WAYLAND-BOUND `plat3x`/`plat4x` SCRIPTS.
# `Xvfb`, `sway`, `grim`, `convert` and `compare` do not exist on
# aarch64-darwin, and `tesseract` is not reachable from where this lane runs
# (not on the ambient PATH; codetracer's own flake declares none — GuiAssert's
# flake does carry tesseract 5.5.1, but that is a different dev shell with no
# codetracer sources in it). None of them is needed: ScreenCaptureKit replaces
# grim, Apple Vision replaces tesseract, and the window server replaces sway.
#
# ===========================================================================
# POINTS AND PIXELS, AND THE VIEWPORT THAT CANNOT BE HONOURED
# ===========================================================================
#
# Measured on this host (aarch64-darwin, macOS 26.5.2 build 25F84,
# 2026-10-12): ONE display, **1728x1117 POINTS**, `pointPixelScale` **2.000**.
#
#  * `scenarios.json`'s `laptop` viewport (1440x900) is honoured EXACTLY. The
#    window frame is 1440x929 points — the 29 extra points are the title bar,
#    which the frame includes and the content area does not.
#  * `scenarios.json`'s `wide` viewport (1920x1080) **CANNOT BE HONOURED**. A
#    window cannot be wider than its display. Asked for 1920x1080, macOS made
#    a 1728x1084-point window. The lane captures it anyway and records
#    `viewportHonoured: false` with the deviation in points. **It is never
#    relabelled 1920.**
#  * Every PNG is in DEVICE pixels — 2x here, so a 1440-point window is a
#    2880-pixel PNG. A second frame is written beside it, downscaled to the
#    window's POINT extent (`<view>.points.png`), and that is the one the
#    oracle grades and the one a parity comparison must use: Playwright sets
#    no `deviceScaleFactor` anywhere in this tree, so the Electron reference
#    lands at 1x and comparing a 2x PNG against it would read a factor of two
#    as a parity defect.
#
# ===========================================================================
# THE CONTROLS, AND WHY THE LANE RUNS THEM EVERY TIME
# ===========================================================================
#
# Six wrong conclusions in this campaign came from probes that could not see
# their subject. Three controls run before and after the scenarios, and each
# has been made to fail:
#
#  1. **The display still** (in the driver's `host` mode). A host that cannot
#     capture a display cannot capture a window, and this separates "no
#     grant" from "no window" before any scenario runs.
#  2. **A capture aimed at an owner that does not exist** must REFUSE with
#     `outcome: refused` and a non-zero exit. A capture path that answers OK
#     for a window that is not there is answering about something else.
#  3. **The grader's `--expect-blank` arm** over a synthesised flat frame.
#     The `rendersText` assertion's negative case, executed rather than
#     asserted to exist.
#
# And the shim is checked in BOTH polarities for the literal that distinguishes
# the font-kit build, because a lane that captured a textless window and
# graded it green is exactly the failure this one exists to prevent.
#
# ===========================================================================

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISONIM_GPUI="${ISONIM_GPUI:-$(cd "${root}/.." && pwd)/isonim-gpui}"
SCENARIOS="${root}/src/tests/visual/scenarios.json"
BIN="${root}/build/bin/codetracer-gpui"
CAPTURE="${root}/build/plat37_macos_window_capture"
GRADE="${root}/build/plat37_macos_window_grade"
OUT="${root}/build/plat37-macos"
ONLY=""
CONTROLS_ONLY=0
OWNER="codetracer-gpui"

# How long the window stays up, and the external bound on every capture.
# BOTH are needed and neither replaces the other: the SCK helper bounds
# itself and exits 7, but ffmpeg's avfoundation input was measured hanging
# 138 s under denial on this host, so nothing that touches the window server
# runs here without a `timeout(1)` around it as well.
WINDOW_MS="${CODETRACER_PLAT37_WINDOW_MS:-180000}"
# How long the DRIVER may wait for the window to appear. NOT a settle delay:
# `--replay-ops` runs before the window is drawn, so a 21-step scenario opens
# its window tens of seconds after the process starts. Measured 2026-10-12: a
# fixed 6-second settle captured the three scenarios that step nothing and
# found NO WINDOW for all four that do.
WAIT_MS="${CODETRACER_PLAT37_WAIT_MS:-120000}"
SETTLE_S="${CODETRACER_PLAT37_SETTLE_S:-1}"
# The EXTERNAL bound, and it must exceed WAIT_MS or it would cut off the poll
# rather than a hang. Belt and braces: the SCK helper self-bounds and exits 7,
# and ffmpeg's avfoundation input was measured hanging 138 s under denial.
CAPTURE_TIMEOUT_S="${CODETRACER_PLAT37_CAPTURE_TIMEOUT_S:-240}"
GRADE_TIMEOUT_S="${CODETRACER_PLAT37_GRADE_TIMEOUT_S:-300}"

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
	--controls-only)
		CONTROLS_ONLY=1
		shift
		;;
	*) fail "unknown argument '$1'" ;;
	esac
done

# ---------------------------------------------------------------------------
# A REFUSAL, NEVER A SKIP
# ---------------------------------------------------------------------------
#
# `Silent-Self-Pass-Audit-2026-08-23.md`: a lane that detects a missing
# prerequisite, returns early and is counted as passed IS the defect. Every
# one of these exits non-zero.
[ "$(uname -s)" = "Darwin" ] ||
	fail "this lane is macOS-only by construction: it drives
      ScreenCaptureKit and the Quartz window server. The Wayland lane is
      ci/test/plat37-window-frame.sh and the compositor-free one is
      ci/test/plat35-gpui-capture.sh."
[ -x "${BIN}" ] || fail "${BIN} is not built. Run \`just build-gpui\`."
[ -f "${SCENARIOS}" ] || fail "the scenario set is not at ${SCENARIOS}"
command -v timeout >/dev/null || fail "timeout(1) is not on PATH, and this
      lane will not run an unbounded capture against a window server."
command -v ffmpeg >/dev/null || fail "ffmpeg is not on PATH; it is what
      downscales each device-pixel capture to its point extent."

mkdir -p "${OUT}"

# ---------------------------------------------------------------------------
# The two Nim halves, built here rather than assumed
# ---------------------------------------------------------------------------
build_nim() {
	local src="$1" exe="$2" cache="$3"
	echo "building ${exe##*/}"
	nim c --hints:off --warnings:off --path:"${root}/../GuiAssert/src" \
		--nimcache:"${root}/nimcache/${cache}" -o:"${exe}" "${src}" ||
		fail "${src} did not compile"
}
build_nim "${root}/ci/test/plat37_macos_window_capture.nim" "${CAPTURE}" \
	plat37macoscap
build_nim "${root}/ci/test/plat37_macos_window_grade.nim" "${GRADE}" \
	plat37macosgrade

# ---------------------------------------------------------------------------
# CONTROL 1 — the host, the grant and the display positive control
# ---------------------------------------------------------------------------
echo
echo "=== control 1: the host, the grant, and a display still ==="
timeout "${CAPTURE_TIMEOUT_S}" "${CAPTURE}" host \
	--record="${OUT}/host.json" --timeout-ms=30000 ||
	fail "the host control failed. Its record is at ${OUT}/host.json and
      names which of the three it was: no still capture at all, no
      ScreenCapture grant for the capture bundle (the record carries the
      exact clickable remedy), or a display that could not be captured."

# ---------------------------------------------------------------------------
# The shim — SELECTED BY FILE SUBSTITUTION, for the measured reason
# ---------------------------------------------------------------------------
#
# `isonim_gpui/bindings.nim` resolves the cdylib at COMPILE time and bakes the
# absolute path `…/isonim-gpui/rust/target/debug/libgpui_nim_shim.<ext>` into
# its `{.dynlib.}` pragma. `dlopen` on an absolute path consults neither
# `LD_LIBRARY_PATH` nor `DYLD_LIBRARY_PATH`, so a lane that set either would
# have run against whichever shim happened to sit at that path. `plat35` and
# `plat37-window-frame.sh` carry the same measurement and the same remedy.
SHIM_DIR="${ISONIM_GPUI}/rust/target/plat37"
LIVE_SHIM="${ISONIM_GPUI}/rust/target/debug/libgpui_nim_shim.dylib"
WINDOWED_SHIM="${SHIM_DIR}/libgpui_nim_shim.windowed.dylib"
SHIM_BACKUP=""

restore_shim() {
	if [ -n "${SHIM_BACKUP}" ] && [ -f "${SHIM_BACKUP}" ]; then
		mv -f "${SHIM_BACKUP}" "${LIVE_SHIM}"
		SHIM_BACKUP=""
		echo "restored ${LIVE_SHIM}"
	fi
	pkill -f "${BIN}" 2>/dev/null
	return 0
}
trap restore_shim EXIT

[ -f "${WINDOWED_SHIM}" ] || fail "the windowed shim is not at
      ${WINDOWED_SHIM}. Build all three in the sibling's own dev shell,
      which is where the linker flags are declared:

          cd ${ISONIM_GPUI} && nix develop --command just plat37-shims

      This lane does NOT build it: measured 2026-09-22, a shim build run
      from codetracer's dev shell fails to link."

# THE FONT-KIT CHECK, IN BOTH POLARITIES, AGAINST A LITERAL RATHER THAN A
# VERSION STRING.
#
# `isonim-gpui` b0ea5fc added `gpui_platform/font-kit` to the `gpui-backend`
# feature. Without it `gpui_macos` installs a text system that renders
# NOTHING: the window paints its pane grounds and not one glyph on them, and
# every geometric predicate in the oracle still passes on it (measured: the
# no-font-kit frame still located five panes and 225 gray levels). A lane that
# captured that window and graded it green is the exact failure this check
# exists to prevent, and a byte count or a `--version` could not see it.
#
# The discriminator is the REFUSAL MESSAGE of the text system that draws
# nothing, which only the featureless build carries, plus the crate name,
# which only the featured build carries. Measured 2026-10-12:
#
#   windowed, b0ea5fc  (66,282,184 bytes): font_kit 1, "no text…" 0
#   windowed, 76b2a2c  (65,120,504 bytes): font_kit 0, "no text…" 1
#
# `grep -c` EXITS 1 WHEN THE COUNT IS 0, which aborts a `set -e` script on the
# very case this is testing for; `|| true` is load-bearing, not decoration.
has_fontkit="$(grep -a -c 'font_kit' "${WINDOWED_SHIM}" || true)"
has_refusal="$(grep -a -c 'no text will be rendered' "${WINDOWED_SHIM}" || true)"
echo "shim font-kit probe: font_kit=${has_fontkit} textless-refusal=${has_refusal}"
[ "${has_fontkit}" -gt 0 ] || fail "the staged windowed shim carries no
      \`font_kit\` string, so it was built before isonim-gpui b0ea5fc and its
      window will draw NO TEXT. Rebuild it:
          cd ${ISONIM_GPUI} && nix develop --command just plat37-shims"
[ "${has_refusal}" -eq 0 ] || fail "the staged windowed shim carries the
      textless text system's refusal message (\"no text will be rendered\"),
      so it was built WITHOUT \`gpui_platform/font-kit\`. Rebuild it from
      isonim-gpui b0ea5fc or later."

# The recording. REFUSED rather than skipped when absent: a green run over no
# recording is worth less than a red one.
TRACE="${CODETRACER_PLAT37_TRACE:-${CODETRACER_PLAT35_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}}"
[ -d "${TRACE}" ] || fail "the \`calc\` recording is not at ${TRACE}.
      Point CODETRACER_PLAT37_TRACE at one, or produce it through the tui
      lane's fixture provider (\`just test-tui\` once)."

# ---------------------------------------------------------------------------
# CONTROL 2 — a capture aimed at a window that is not there must REFUSE
# ---------------------------------------------------------------------------
echo
echo "=== control 2: a capture aimed at an owner that does not exist ==="
if timeout "${CAPTURE_TIMEOUT_S}" "${CAPTURE}" capture \
	--owner="plat37-no-such-application" \
	--out="${OUT}/control-absent.png" \
	--record="${OUT}/control-absent.json" \
	--view=control --scenario=absent-owner \
	--requested-width=1440 --requested-height=900 \
	--wait-ms=0 >/dev/null 2>&1; then
	fail "the capture path answered OK for an owner that does not exist.
      It is then answering about something other than its target, and every
      green below it would be unfalsifiable."
fi
python3 - "${OUT}/control-absent.json" <<'PY' || fail "control 2 did not refuse as expected"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["outcome"] == "refused", r["outcome"]
assert r["attestation"]["matched"] == 0, r["attestation"]["matched"]
assert "satisfiesG1" not in r, "a refused run must not claim G1"
print("  refused, attestation matched 0, no G1 claim — as required")
PY

# ---------------------------------------------------------------------------
# CONTROL 3 — the grader's negative arm, over a synthesised flat frame
# ---------------------------------------------------------------------------
echo
echo "=== control 3: the grader's rendersText assertion, made to fail ==="
ffmpeg -loglevel error -y -f lavfi -i color=c=0x202020:s=1440x929 \
	-frames:v 1 "${OUT}/control-flat.png" ||
	fail "the flat control frame could not be synthesised"
# It must PASS with --expect-blank …
timeout "${GRADE_TIMEOUT_S}" "${GRADE}" --frame="${OUT}/control-flat.png" \
	--record="${OUT}/control-flat.blank.json" \
	--view=control --scenario=flat-frame \
	--scratch="${OUT}/scratch/control" --expect-blank ||
	fail "the flat control frame did not grade as blank, so the grader's
      negative arm is not reaching the predicate it is supposed to control."
# … and FAIL without it. A control that has never failed is not a control.
if timeout "${GRADE_TIMEOUT_S}" "${GRADE}" --frame="${OUT}/control-flat.png" \
	--record="${OUT}/control-flat.text.json" \
	--view=control --scenario=flat-frame \
	--scratch="${OUT}/scratch/control" >/dev/null 2>&1; then
	fail "the grader passed a FLAT frame as rendering text. The rendersText
      assertion cannot fail, so it is asserting nothing."
fi
echo "  the flat frame grades blank, and fails the text assertion — both arms live"

if [ "${CONTROLS_ONLY}" -eq 1 ]; then
	echo
	echo "OK: the three controls pass. --controls-only, so no scenario ran."
	exit 0
fi

# ---------------------------------------------------------------------------
# The scenario set, READ from scenarios.json and never listed here
# ---------------------------------------------------------------------------
#
# The same parser and the same two-sided cardinality assertions
# `plat35-gpui-capture.sh` uses, including the probe/scenario name-collision
# check: the per-view PNG path is the file name, so a probe sharing a view
# with one of the six would overwrite that frame and the lane would still
# report success.
SPEC="${OUT}/scenarios.tsv"
python3 - "${SCENARIOS}" "${SPEC}" <<'PY' || fail "the scenario set did not parse"
import json, sys
doc = json.load(open(sys.argv[1]))
scenarios = doc["scenarios"]
if len(scenarios) != doc["expectedScenarios"]:
    sys.exit(f"FAIL: scenarios.json declares {doc['expectedScenarios']} "
             f"scenarios and holds {len(scenarios)}")
probes = doc.get("gpuiProbes", [])
if len(probes) != doc.get("expectedGpuiProbes", 0):
    sys.exit(f"FAIL: scenarios.json declares {doc.get('expectedGpuiProbes')} "
             f"GPUI probes and holds {len(probes)}")
kinds = set(doc["operationKinds"])
viewports = doc["viewports"]
if len(viewports) != doc["expectedViewports"]:
    sys.exit(f"FAIL: scenarios.json declares {doc['expectedViewports']} "
             f"viewports and holds {len(viewports)}")
names = {sc["view"] for sc in scenarios}
ids = {sc["id"] for sc in scenarios}
for pr in probes:
    if pr["view"] in names or pr["id"] in ids:
        sys.exit(f"FAIL: probe {pr['id']}/{pr['view']} collides with one of "
                 f"the six pinned scenarios")
rows = []
for sc in scenarios + probes:
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
                           str(vp["height"]), sc["viewport"],
                           ",".join(terms)]))
open(sys.argv[2], "w").write("\n".join(rows) + "\n")
print(f"scenarios.json: {len(scenarios)} scenarios, {len(probes)} GPUI "
      f"probe(s), {len(kinds)} operation kinds, {len(viewports)} viewports")
PY

# ---------------------------------------------------------------------------
# Stage the windowed shim and drive the scenarios
# ---------------------------------------------------------------------------
if [ -z "${SHIM_BACKUP}" ] && [ -f "${LIVE_SHIM}" ]; then
	SHIM_BACKUP="${LIVE_SHIM}.plat37macos-backup"
	cp -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
fi
cp -f "${WINDOWED_SHIM}" "${LIVE_SHIM}"
echo
echo "shim in place: windowed ($(wc -c <"${LIVE_SHIM}" | tr -d ' ') bytes)"

RECORDS="${OUT}/records.jsonl"
: >"${RECORDS}"
captured=0
refused=0

while IFS=$'\t' read -r id view width height vpname ops; do
	[ -n "${id}" ] || continue
	if [ -n "${ONLY}" ] && [ "${view}" != "${ONLY}" ]; then
		continue
	fi
	png="${OUT}/${view}.png"
	points_png="${OUT}/${view}.points.png"
	rec="${OUT}/${view}.capture.json"
	grade="${OUT}/${view}.grade.json"
	log="${OUT}/${view}.gpui.log"
	rm -f "${png}" "${points_png}" "${rec}" "${grade}" "${log}"

	echo
	echo "### ${id} -> ${view} at ${vpname} ${width}x${height} points [${ops:-no operations}]"

	# The window. `--replay-ops` drives the scenario through the front-end's
	# OWN command line rather than through injected input, which is not a
	# convenience: GuiAssert's mouse injection silently NO-OPS on this host
	# (no `kTCCServiceAccessibility` row exists for any subject), so a lane
	# that clicked would capture an undriven screen and call it a scenario.
	# Keyboard injection does work; it is simply not what drives a replay
	# operation here, because no BINDING maps a key to one yet.
	argv=("${BIN}" "--width=${width}" "--height=${height}"
		"--quit-after-ms=${WINDOW_MS}")
	[ -n "${ops}" ] && argv+=("--replay-ops=${ops}")
	argv+=("${TRACE}")
	"${argv[@]}" >"${log}" 2>&1 &
	gpid=$!
	python3 -c "import time; time.sleep(${SETTLE_S})"

	cap_rc=0
	timeout "${CAPTURE_TIMEOUT_S}" "${CAPTURE}" capture \
		--owner="${OWNER}" --out="${png}" --record="${rec}" \
		--view="${view}" --scenario="${id}" \
		--requested-width="${width}" --requested-height="${height}" \
		--timeout-ms=30000 --wait-ms="${WAIT_MS}" || cap_rc=$?

	kill "${gpid}" 2>/dev/null
	wait "${gpid}" 2>/dev/null

	# THE RECORD IS THE VERDICT, not the exit code and not the file's size.
	# The driver writes one on every path it reaches, INCLUDING a refusal, so
	# "the capture ran and the window was not there" stays distinguishable
	# from "the capture did not run" (Verification-Harness-Traps §4).
	if [ ! -f "${rec}" ]; then
		echo "  no record written (rc ${cap_rc}) — the driver did not run" >&2
		refused=$((refused + 1))
		continue
	fi
	if [ "${cap_rc}" -ne 0 ]; then
		echo "  refused (rc ${cap_rc}): $(python3 -c "
import json,sys; print(json.load(open(sys.argv[1])).get('refusal','?'))" "${rec}")" >&2
		refused=$((refused + 1))
		python3 -c "
import json,sys
r=json.load(open(sys.argv[1])); r['graded']=False
print(json.dumps(r))" "${rec}" >>"${RECORDS}"
		continue
	fi

	# THE POINT-EXTENT FRAME. The oracle's constants are 1x and the Electron
	# reference is 1x; the device-pixel PNG is kept beside it as the artefact
	# of record. Both are named in the census, so nothing downstream has to
	# guess which one it is holding.
	pw="$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); print(d['capturedPoints']['width'])" "${rec}")"
	ph="$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); print(d['capturedPoints']['height'])" "${rec}")"
	ffmpeg -loglevel error -y -i "${png}" \
		-vf "scale=${pw}:${ph}:flags=lanczos" "${points_png}" ||
		fail "downscaling ${png} to its point extent failed"

	grade_rc=0
	timeout "${GRADE_TIMEOUT_S}" "${GRADE}" --frame="${points_png}" \
		--record="${grade}" --view="${view}" --scenario="${id}" \
		--scratch="${OUT}/scratch/${view}" || grade_rc=$?

	python3 - "${rec}" "${grade}" "${png}" "${points_png}" "${grade_rc}" \
		>>"${RECORDS}" <<'PY' || fail "the ${view} census did not assemble"
import json, os, struct, sys
rec = json.load(open(sys.argv[1]))
grade = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else None
png, points_png, grade_rc = sys.argv[3], sys.argv[4], int(sys.argv[5])
problems = []

# THE PNG'S OWN IHDR, against what the driver said it captured. The record is
# the driver's word for what it took; the IHDR is the artefact's word for what
# it holds, and PLAT-35 already lost a milestone-month to a viewport matrix
# asserted from the DECLARATION.
for path, key in ((png, "capturedPixels"), (points_png, "capturedPoints")):
    if not os.path.exists(path):
        problems.append(f"no image at {path}")
        continue
    head = open(path, "rb").read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        problems.append(f"{os.path.basename(path)} is not a PNG")
        continue
    iw, ih = struct.unpack(">II", head[16:24])
    want = (rec[key]["width"], rec[key]["height"])
    if (iw, ih) != want:
        problems.append(f"{os.path.basename(path)} IHDR is {iw}x{ih}, "
                        f"the record says {want[0]}x{want[1]}")

# THE ATTESTATION IS WHAT ENTITLES THE RECORD TO CLAIM G1, so it is re-checked
# here against the record rather than trusted from it.
if not rec.get("satisfiesG1"):
    problems.append("a captured run did not claim G1")
if rec["attestation"]["matched"] < 1:
    problems.append("G1 is claimed and no window was attested")
if not rec["capture"]["sameWindowAsAttested"]:
    problems.append("ScreenCaptureKit captured a different window than the "
                    "one CGWindowListCopyWindowInfo attested")
if grade is None:
    problems.append("the grader wrote no record")
elif grade["verdict"] != "OK":
    problems.append("grader: " + "; ".join(grade["problems"]))
elif grade_rc != 0:
    problems.append(f"the grader answered OK and exited {grade_rc}")

rec["grade"] = grade
rec["graded"] = True
rec["png"] = png
rec["pointsPng"] = points_png
rec["pngBytes"] = os.path.getsize(png) if os.path.exists(png) else 0
rec["laneVerdict"] = "OK" if not problems else "BAD"
rec["laneProblems"] = problems
print(json.dumps(rec))
sys.stderr.write(("  OK" if not problems else "  BAD: " + "; ".join(problems)) + "\n")
PY

	if [ "$(python3 -c "
import json,sys
print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])['laneVerdict'])" "${RECORDS}")" = "OK" ]; then
		captured=$((captured + 1))
	else
		refused=$((refused + 1))
	fi
done <"${SPEC}"

restore_shim

# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------
python3 - "${SCENARIOS}" "${OUT}" "${ONLY}" <<'PY' || fail "the manifest did not assemble"
import json, os, sys
scenarios_path, out, only = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(scenarios_path))
records = []
p = os.path.join(out, "records.jsonl")
if os.path.exists(p):
    for line in open(p):
        line = line.strip()
        if line:
            records.append(json.loads(line))
manifest = {
    "schemaVersion": 1,
    "milestone": "PLAT-37",
    "lane": "plat37-macos-window-capture",
    "only": only,
    "expectedScenarios": doc["expectedScenarios"],
    "expectedGpuiProbes": doc.get("expectedGpuiProbes", 0),
    "operationKinds": doc["operationKinds"],
    "host": json.load(open(os.path.join(out, "host.json"))),
    # THE PIXEL PATHS, LABELLED, in the same shape `plat37-window-frame.sh`
    # publishes. `satisfiesG1` is the whole point of each row.
    "pixelPaths": {
        "macos-window-screencapturekit": {
            "how": "gpui_launch under --features gpui-backend on the Quartz "
                   "window server; SCScreenshotManager over "
                   "SCContentFilter(desktopIndependentWindow:)",
            "needsCompositor": True,
            "needsTccGrant": True,
            "satisfiesG1": True,
            "why": "PLAT-23's G1 asks that a window has been observed. This "
                   "is one: CGWindowListCopyWindowInfo attested it before any "
                   "pixel was read, and the capture took that window's own "
                   "surface rather than a crop of the display.",
        },
        "headless-render-to-pixels": {
            "how": "gpui_render_to_pixels under --features gpui-headless, "
                   "over HeadlessAppContext::with_platform + "
                   "Window::render_to_image (ci/test/plat35-gpui-capture.sh)",
            "needsCompositor": False,
            "needsTccGrant": False,
            "satisfiesG1": False,
            "why": "an off-screen RGBA buffer is not a window. Labelled per "
                   "row rather than substituted for the windowed path.",
        },
    },
    "standing": {
        "kind": "host-conditional evidence",
        "requiredGate": False,
        "why": "this lane needs a live macOS GUI session and a "
               "kTCCServiceScreenCapture grant held by "
               "com.metacraft-labs.guiassert.capture. Neither exists on a "
               "fresh host or in CI, which is the non-reproducibility "
               "codetracer-specs/issues/"
               "2026-09-29-gpui-window-capture-lanes-are-wayland-only.md "
               "warns a TCC-dependent lane would introduce. PLAT-23's G5 "
               "says a gate cannot be passed by a measurement that could not "
               "have failed; its mirror image is that a gate that cannot RUN "
               "is not a gate. Wire this into no required check.",
    },
    "displayConstraint": {
        "note": "a window cannot be wider than its display. scenarios.json's "
                "`wide` viewport is 1920x1080 POINTS and this display is "
                "1728x1117 points, so `wide` scenarios are clamped by the "
                "window server and are recorded as viewportHonoured:false "
                "with the deviation in points. They are never relabelled.",
        "viewportsHonoured": sorted({
            r["requestedPoints"]["width"] for r in records
            if r.get("viewportHonoured")}),
        "viewportsClamped": sorted({
            r["requestedPoints"]["width"] for r in records
            if r.get("outcome") == "captured" and not r.get("viewportHonoured")}),
    },
    "records": records,
}
path = os.path.join(out, "manifest.json")
json.dump(manifest, open(path, "w"), indent=2, sort_keys=True)
print(f"manifest: {path}")
PY

# ---------------------------------------------------------------------------
# The population, not the property
# ---------------------------------------------------------------------------
echo
echo "=== ${captured} captured, ${refused} refused ==="
expected="$(python3 -c "
import json,sys
doc=json.load(open(sys.argv[1]))
only=sys.argv[2]
every=doc['scenarios'] + doc.get('gpuiProbes', [])
print(sum(1 for s in every if not only or s['view']==only))
" "${SCENARIOS}" "${ONLY}")"
# A `--only` THAT MATCHED NOTHING IS A FAILURE AND NOT A PASS. The equality
# below cannot catch it on its own, because `expected` is derived from the
# SAME filter: zero equals zero (plat35 earned this clause with a real run).
if [ "${expected}" -eq 0 ]; then
	fail "no scenario has the view '${ONLY}'. The view names are
      scenarios.json's own: $(cut -f2 "${SPEC}" | paste -sd' ' -)"
fi
total=$((captured + refused))
[ "${total}" -eq "${expected}" ] ||
	fail "${total} scenarios ran where ${expected} were declared"

# The viewport summary, printed whether or not the lane passes, because a
# clamped viewport is a finding rather than a failure.
python3 - "${OUT}/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for r in m["records"]:
    if r.get("outcome") != "captured":
        continue
    req, got = r["requestedPoints"], r["windowFramePoints"]
    mark = "honoured" if r.get("viewportHonoured") else "CLAMPED BY THE DISPLAY"
    print(f"  {r['view']:<14} asked {req['width']}x{req['height']} pt, "
          f"window {got['width']}x{got['height']} pt, "
          f"captured {r['capturedPixels']['width']}x"
          f"{r['capturedPixels']['height']} px @{r['pointPixelScale']}x  "
          f"-> {mark}")
PY

[ "${refused}" -eq 0 ] ||
	fail "${refused} of ${total} scenarios did not produce a graded frame"
echo
echo "OK: ${captured} of ${expected} attested window frames in ${OUT}"
echo "    Every record carries satisfiesG1: true and"
echo "    standing: HOST-CONDITIONAL EVIDENCE. This lane is not a gate."
