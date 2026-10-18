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
# POINTS AND PIXELS, AND THE VIEWPORT THAT IS LARGER THAN THE DISPLAY
# ===========================================================================
#
# Measured on this host (aarch64-darwin, macOS 26.5.2 build 25F84,
# 2026-10-12): ONE display, **1728x1117 POINTS**, `pointPixelScale` **2.000**.
#
#  * `scenarios.json`'s `laptop` viewport (1440x900) is honoured EXACTLY. The
#    window frame is 1440x928 points — the 28 extra points are the title bar,
#    which the frame includes and the content area does not.
#  * `scenarios.json`'s `wide` viewport (1920x1080) **IS ALSO HONOURED, SINCE
#    PARITY-G1 (2026-10-18), THOUGH IT IS WIDER THAN THE DISPLAY.** The window
#    frame is 1920x1108 points at x = -96: it hangs off both side edges, and
#    the capture is unaffected because this lane photographs the window's OWN
#    surface through `SCContentFilter(desktopIndependentWindow:)` rather than
#    a crop of the display.
#
#    **THIS PARAGRAPH USED TO SAY THE OPPOSITE, AND THE REASON IT WAS WRONG IS
#    WORTH KEEPING.** It read *"CANNOT BE HONOURED. A window cannot be wider
#    than its display"*, and the second sentence does not follow from the
#    first. macOS was not refusing an impossible window; AppKit was applying
#    `-[NSWindow constrainFrameRect:toScreen:]`, which fits a window to the
#    screen's VISIBLE FRAME — and 1728x1084 was exactly that visible frame
#    (the full width, the height less the 33-point menu bar), not a limit of
#    the window server. Chromium's window class overrides that method, which
#    is why the Electron front-end always got its full 1920x1080 here; GPUI's
#    class did not, and now does, through
#    `isonim-gpui/rust/gpui-nim-shim/src/mac_window_frame.rs`. A measured
#    number was read as a law, and the law was a default.
#
#    What has NOT changed: the grading. A window that comes back smaller than
#    the request is still recorded `viewportHonoured: false` with the
#    deviation in points, and is still **never relabelled** with the figure it
#    could not reach. The deviation is now 0 because the window is 1920 wide,
#    not because the test was relaxed.
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

# ---------------------------------------------------------------------------
# THE FRESHNESS GATE — and why the line above it is not one
# ---------------------------------------------------------------------------
#
# `[ -x "${BIN}" ]` asks whether the binary EXISTS. It never asks whether the
# binary is of THIS tree, and it never builds it. On 2026-10-12 that gap
# produced the reading this campaign has had to withdraw: this lane ran a
# `codetracer-gpui` dated 2026-10-07 17:51 while the Electron lane ran a
# bundle from 2026-10-12 — **127 commits apart** — and the result was
# published as the first parity reading "against one build".
#
# `Cross-Renderer-Visual-Alignment.md` §2.2 rule 4 was satisfied, and that is
# the point: rule 4 binds REVIEWER -> CAPTURE ("the review's
# againstUiBundleMtime must equal the captured answers' own provenance"). It
# does not bind CAPTURE -> SOURCE. Aligning when the pixels were taken is not
# aligning what was running.
#
# Eleven findings were raised against two different programs and attributed to
# one. `PARITY-S2` had the deficient renderer BACKWARDS: the stale binary
# still drew a Timeline tab that 740d76be2 had deliberately removed, so the
# finding read as "Electron is missing a panel" when Electron was correct to
# lack it. Acting on it would have re-added a deleted panel against a green
# assertion.
#
# THE RULE: the binary must carry a stamp recording the digest of the input
# closure it was compiled from, and that digest must equal the one recomputed
# from this tree right now. The closure is the COMPILER'S OWN answer
# (`nim c --genDeps:on --compileOnly`, 238 in-tree files across four
# repositories, 10 s), not a hand-written directory list, and store paths in
# it cover the toolchain for free. `ci/lib/build-freshness.sh` carries the
# full rule and — more importantly — what it does NOT cover.
#
# IT REFUSES; IT DOES NOT WARN. A lane that printed a warning and captured
# anyway is the defect being fixed, not a milder form of it: the skew was
# fully visible in two `ls -la` outputs that nobody had been given a reason to
# run.
#
# FAILURE MODE, stated rather than left to be discovered: this gate is
# FALSE-RED-biased. It refuses after any edit inside the closure, including
# one that cannot change the rendered frame (a comment, a log string). The
# remedy — `just build-gpui` — always clears it, because the stamp is
# rewritten from the current tree on every build whether or not the emitted
# bytes changed. There is no state in which running the remedy leaves the
# assertion still failing. That is the property mtime-based freshness cannot
# offer, and the reason this is not an mtime check.
echo
echo "=== the subject: is this binary of THIS tree? ==="
# shellcheck source=ci/lib/build-freshness.sh
# The pre-commit hook runs shellcheck WITHOUT `-x`, which is what makes a
# `source=` directive followable, so SC1091 fires on the line below however
# correct that path is. `shellcheck -x` still resolves it.
# shellcheck disable=SC1091
. "${root}/ci/lib/build-freshness.sh"
# Computed ONCE and reused by the manifest below. `bf_gpui_assert_fresh` would
# recompute it, and the closure costs ~10 s of real compiler time, so the gate
# is driven through `bf_assert_fresh` directly with the digest in hand.
GPUI_STAMP="${root}/${BF_GPUI_STAMP}"
GPUI_INPUT_DIGEST="$(bf_gpui_input_digest "${root}")" ||
	fail "the GPUI input closure could not be computed, so this lane cannot
      say what the binary it is about to photograph was built from. Refused
      rather than captured: an unknown subject is not a subject."
bf_assert_fresh "${GPUI_STAMP}" "${BIN}" "${GPUI_INPUT_DIGEST}" "GPUI BINARY" \
	"  Rebuild it, which rewrites the stamp from this tree:
      cd ${root} && nix develop --command just build-gpui" ||
	fail "the GPUI binary this lane would have captured is not the one this
      checkout describes. Refused rather than captured: see the reason and
      the remedy above. This refusal is the whole point of the lane — a
      frame of the wrong program grades just as green as a frame of the
      right one."
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
	# The face the GPUI text system RESOLVED, written by the shim's
	# `register_fonts` at launch. PARITY-P1's residual is an advance
	# difference and advance is a property of the resolved face, so the
	# capture has to record which face that was rather than which one the
	# front-end asked for. It also reaches stderr, hence the log; the file
	# is the machine-readable copy.
	face="${OUT}/${view}.face.json"
	rm -f "${png}" "${points_png}" "${rec}" "${grade}" "${log}" "${face}"

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
	GPUI_FONT_REPORT_PATH="${face}" "${argv[@]}" >"${log}" 2>&1 &
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
python3 - "${SCENARIOS}" "${OUT}" "${ONLY}" "${BIN}" "${GPUI_STAMP}" \
	"${GPUI_INPUT_DIGEST}" "${WINDOWED_SHIM}" "${root}" "${ISONIM_GPUI}" \
	<<'PY' || fail "the manifest did not assemble"
import datetime, hashlib, json, os, subprocess, sys
(scenarios_path, out, only, bin_path, stamp_path, input_digest,
 shim_path, root, isonim_gpui) = sys.argv[1:10]
doc = json.load(open(scenarios_path))


def mtime(path):
    try:
        return (datetime.datetime.utcfromtimestamp(os.path.getmtime(path))
                .strftime("%Y-%m-%dT%H:%M:%SZ"))
    except OSError:
        return None


def sha256(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def git(repo, *args):
    try:
        return subprocess.run(("git", "-C", repo) + args, capture_output=True,
                              text=True, timeout=20).stdout.strip()
    except Exception:
        return ""


def stamp_field(name):
    try:
        for line in open(stamp_path):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None


def literal_count(path, needle):
    """How many times a byte literal occurs in the artefact. The same
    two-polarity idiom the shim's font-kit probe uses, applied to the
    executable — which is the artefact that had NO provenance line at all
    when the 127-commit skew went unnoticed."""
    try:
        data = open(path, "rb").read()
    except OSError:
        return None
    return data.count(needle.encode())
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
    # ----------------------------------------------------------------------
    # THE PROVENANCE OF THE EXECUTABLE. This block is the fix for the defect
    # that cost this campaign a whole reading.
    #
    # Before 2026-10-12 this manifest described the Rust SHIM's provenance —
    # in both polarities, against a literal, with a measurement attached —
    # and said NOTHING about the Nim executable whose window was being
    # photographed. So when that executable turned out to be 127 commits
    # behind the Electron bundle it was compared against, no artefact of the
    # run could have shown it. The one thing nobody wrote a provenance line
    # for is the one that was stale.
    #
    # `freshnessGate` records that the binary was PROVEN to be of this tree,
    # not merely found on disk. `timelineProbe` is the content control for
    # the specific regression that produced PARITY-S2.
    # ----------------------------------------------------------------------
    "subject": {
        "executable": bin_path,
        "sha256": sha256(bin_path),
        "bytes": os.path.getsize(bin_path) if os.path.exists(bin_path) else None,
        "mtimeUtc": mtime(bin_path),
        "freshnessGate": {
            "enforced": True,
            "rule": "the binary must carry ci/lib/build-freshness.sh's stamp, "
                    "and the stamp's input_digest must equal the digest "
                    "recomputed from this tree now. The input closure is the "
                    "COMPILER'S own (nim c --genDeps:on --compileOnly), so it "
                    "spans every sibling repo the build actually reads, and "
                    "/nix/store entries in it are digested by path, which "
                    "covers the toolchain.",
            "refusesRatherThanWarns": True,
            "inputDigest": input_digest,
            "stampInputDigest": stamp_field("input_digest"),
            "stampBuiltAt": stamp_field("built_at"),
            "stampBuiltBy": stamp_field("built_by"),
            "failureMode": "false-red-biased. Any edit inside the closure "
                           "refuses, including one that cannot change a "
                           "pixel. The remedy (`just build-gpui`) always "
                           "clears it, because the stamp is rewritten from "
                           "the current tree on every build whether or not "
                           "the emitted bytes changed — the property an "
                           "mtime check cannot offer.",
        },
        # The two-polarity content control for PLAT-51's Timeline removal
        # (740d76be2). The 2026-10-07 binary answered 2 / 1 / 1 here and so
        # still DREW a Timeline tab the tree had deleted; PARITY-S2 read that
        # as Electron missing a panel, with the deficient renderer backwards.
        #
        # `lpkTimeline` IS DELIBERATELY NOT A DISCRIMINATOR AND IS RECORDED
        # TO SAY SO. Measured 2026-10-12: it is `LogicalPanelKind.lpkTimeline`
        # in src/frontend/viewmodel/collab/types.nim:52 — the COLLAB panel
        # enum, untouched since 2026-09-20 and present at HEAD — not a
        # `PaneKind` spelling. It reads 1 in the stale binary, 1 in the
        # current binary and 1 in Electron's ui.js. plat37-parity-readings.json
        # called it "a PaneKind spelling that no longer exists"; that is an
        # error in the record, and a control that cannot distinguish the two
        # builds must not be counted as one.
        "timelineProbe": {
            "@Timeline": literal_count(bin_path, "@Timeline"),
            "_renderTimeline__appZleaves_":
                literal_count(bin_path, "_renderTimeline__appZleaves_"),
            "Call Trace (POSITIVE CONTROL, must be > 0)":
                literal_count(bin_path, "Call Trace"),
            "ZZQQnonsense_literal_XYZZY (NEGATIVE CONTROL, must be 0)":
                literal_count(bin_path, "ZZQQnonsense_literal_XYZZY"),
            "@lpkTimeline (NOT A DISCRIMINATOR — see above)":
                literal_count(bin_path, "@lpkTimeline"),
        },
        "shim": {
            "path": shim_path,
            "sha256": sha256(shim_path),
            "mtimeUtc": mtime(shim_path),
        },
        "repos": {
            name: {
                "head": git(path, "rev-parse", "HEAD"),
                "branch": git(path, "rev-parse", "--abbrev-ref", "HEAD"),
                "dirtyFiles": len([
                    ln for ln in git(path, "status", "--porcelain").splitlines()
                    if ln.strip()]),
            }
            for name, path in (
                ("codetracer", root),
                ("isonim-gpui", isonim_gpui),
            )
        },
    },
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
