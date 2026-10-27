#!/usr/bin/env bash
#
# plat37-macos-electron-capture.sh — THE ELECTRON REFERENCE SET, captured on
# macOS through the SAME path the GPUI window lane uses.
#
#   bash ci/test/plat37-macos-electron-capture.sh
#   bash ci/test/plat37-macos-electron-capture.sh --only editor
#   bash ci/test/plat37-macos-electron-capture.sh --out build/x
#   bash ci/test/plat37-macos-electron-capture.sh --controls-only
#
# ===========================================================================
# WHAT THIS LANE IS, AND WHY IT IS NOT A PLAYWRIGHT GOLDEN LANE
# ===========================================================================
#
# `ci/test/plat37-macos-window-capture.sh` opens a real `codetracer-gpui`
# window, attests it through `CGWindowListCopyWindowInfo`, captures THAT
# WINDOW'S OWN SURFACE through ScreenCaptureKit and grades the frame with
# PLAT-39's screen oracle. This lane does the same four things to the real
# ELECTRON front-end, with the same two binaries, so that a difference between
# the two reference sets is a difference between the two front-ends and not
# between two capture stacks.
#
# THE DECISION WAS MEASURED, 2026-10-12, on this host, and the measurement is
# re-taken on every run rather than quoted:
#
#   * The Electron window is attestable and capturable by exactly the same
#     code. Probed with the lane's own binary against the product launched
#     from `src/build-debug-repro/bin/ct`: window 1657, owner `Electron`,
#     1728x1084 points -> 3456x2168 pixels at scale 2.0,
#     `sameWindowAsAttested: true`, `satisfiesG1: true`. The GPUI `editor`
#     capture of the same day reports the same 1728x1084 / 3456x2168 / 2.0.
#     Two frames of identical extent, from one compositor, one display, one
#     scale factor and one font stack.
#   * The owner is `Electron`, not `ct` and not `CodeTracer`, because `ct`
#     **execv()s** into the Electron executable on POSIX
#     (`src/ct/launch/electron.nim`), so the process owning the window is the
#     nix `electron-41.3.0` bundle.
#   * `page.screenshot()` is taken as well, every run, from the same settled
#     state — `<view>.page.png` beside `<view>.png`, both named in
#     `<view>.route.json`. The routing decision therefore stays falsifiable:
#     if the two routes ever disagree about the content area, the records say
#     so rather than the choice being an argument in a header.
#
# WHAT THE WINDOW ROUTE GIVES UP, stated here because a reader of the
# reference set needs it:
#
#   * **Window chrome is in the frame — on ONE side only, and that is the
#     finding.** The GPUI window is a standard titled window: asked for
#     1440x900 it is a 1440x929 frame, the 29 extra points being its title
#     bar. CodeTracer's ELECTRON window is not: measured 2026-10-12 at `wide`,
#     `CGWindowListCopyWindowInfo` reports 1920x1080 while the page's own
#     `window.innerHeight` and `getContentSize()` both read 1080. Frame and
#     content are the same rectangle, so this lane passes
#     `--title-bar-points=0` and the driver asserts the premise. **A parity
#     differ must crop the GPUI frame's top 29 points and must NOT crop the
#     Electron one.** Cropping both, or neither, compares a title bar against
#     a row of product.
#   * **No `toHaveScreenshot` masking / tolerance / retry.** The replacement
#     is `codetracer-image-diff` (NVIDIA FLIP) for the perceptual comparison
#     and the spec's own `captureSettled` for the stability. Both are
#     deliberate: FLIP builds on darwin in this workspace and `magick` /
#     `compare` do not exist here at all.
#   * **Compositor alpha.** The window surface carries the window server's own
#     alpha at the rounded corners; a page raster is opaque. Measured on
#     `entry-shell`: RGB agrees to SSIM 0.999901 / PSNR 59.3 dB while alpha
#     is 39.7 dB. A differ that weights alpha will see corners and nothing
#     else.
#
# THE DIVERGENCE THAT WAS NOT THIS LANE'S TO FIX — AND IS NOW CLOSED.
# `scenarios.json`'s `wide` viewport is 1920x1080 POINTS. This block used to
# read *"Electron honours it and GPUI cannot"*: measured on this display
# (1728x1117 points), the Electron window was 1920x1080 points (3840x2160
# pixels) and the GPUI window asked for the same thing came back 1728x1084
# (3456x2168). Three of the six scenarios therefore had reference frames of
# DIFFERENT EXTENT on the two sides and could not be diffed at all.
#
# The cause was never this host and never Electron being special: it is
# `-[NSWindow constrainFrameRect:toScreen:]`, AppKit's fit-to-visible-frame
# default, which Chromium's window class overrides and gpui's did not — the
# diagnosis already written out at `whyViewports` below. PARITY-G1
# (2026-10-18) adds that override to gpui's `GPUIWindow` from the shim
# (`isonim-gpui/rust/gpui-nim-shim/src/mac_window_frame.rs`), and the GPUI
# window is now 1920x1108 points (3840x2216) — the same 1920x1080 of content,
# plus the 28-point title bar its frame includes and Electron's capture does
# not. Cropping those 56 device pixels makes the two extents equal, which is
# the guard `build/plat37-parity-*/compare.sh` enforces and never bypasses.
#
# So the resolution was none of the three this comment used to offer. It was
# not scale, not letterbox, and NOT "add a viewport that fits this display" —
# that last one would have made the suite pass by measuring something else,
# and would still have differed from Electron on every display smaller than
# the viewport. Both lanes still record `viewportHonoured` and the deviation;
# neither relabels.
#
# ===========================================================================
# ITS STANDING: HOST-CONDITIONAL EVIDENCE, NEVER A REQUIRED GATE
# ===========================================================================
#
# Same standing as its GPUI twin and for the same reason: it needs a live
# macOS GUI session and a `kTCCServiceScreenCapture` grant held by
# `com.metacraft-labs.guiassert.capture`, and neither exists on a fresh host
# or in CI. PLAT-23's G5 — *"a gate cannot be passed by a measurement that
# could not have failed"* — has the mirror image that a gate which cannot RUN
# is a green tick for an absent machine. **Wire this into no required check.**
#
# ===========================================================================
# WHAT IT REUSES
# ===========================================================================
#
#  * `src/tests/visual/scenarios.json` — the SIX scenarios, with the same
#    two-sided cardinality assertions. The ONE `gpuiProbe` is deliberately not
#    driven: scenarios.json says of it *"A probe is NOT part of the
#    cross-renderer comparison: it has no Electron arm, so nothing here claims
#    one."*
#  * `ci/test/plat37_macos_window_capture.nim` and
#    `ci/test/plat37_macos_window_grade.nim` — the SAME two binaries, built
#    here the same way, with `--owner` pointed at the Electron window.
#  * `src/tests/gui/lib/fixtures.ts` — the product's own launch path, so the
#    capture is of the shipped binaries and not of a harness-built surface.
#
# ===========================================================================
# POINTS AND PIXELS
# ===========================================================================
#
# Every PNG the capture binary writes is in DEVICE pixels (2x here). A second
# frame is written beside it downscaled to the window's POINT extent
# (`<view>.points.png`), and THAT is the one the oracle grades, because the
# oracle's constants are 1x. The GPUI lane does exactly this; a parity
# comparison must use the point-extent frames on both sides.
#
# ===========================================================================

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCENARIOS="${root}/src/tests/visual/scenarios.json"
# The arrangement every CodeTracer front-end opens with — the generated
# translation of the desktop's own debug-mode default. The per-view pane
# census is taken against THIS and never against a literal count.
SHARED_DEFAULT_LAYOUT="${root}/src/frontend/headless_app/shared_default_layout.generated.json"
CAPTURE="${root}/build/plat37_macos_window_capture"
GRADE="${root}/build/plat37_macos_window_grade"
OUT="${root}/build/plat37-macos-electron"
GUI="${root}/src/tests/gui"
SPEC="tests/visual/plat37-electron-window-capture.spec.ts"
ONLY=""
CONTROLS_ONLY=0
OWNER="${CODETRACER_PLAT37E_OWNER:-Electron}"
GRADE_TIMEOUT_S="${CODETRACER_PLAT37E_GRADE_TIMEOUT_S:-300}"
CAPTURE_TIMEOUT_S="${CODETRACER_PLAT37E_CAPTURE_TIMEOUT_S:-240}"
DRIVE_TIMEOUT_S="${CODETRACER_PLAT37E_DRIVE_TIMEOUT_S:-5400}"

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
[ "$(uname -s)" = "Darwin" ] ||
	fail 'this lane is macOS-only by construction: it drives ScreenCaptureKit
      and the Quartz window server. The Linux Electron arm is
      just plat35-capture-electron (its own Xvfb at -dpi 96).'
[ -f "${SCENARIOS}" ] || fail "the scenario set is not at ${SCENARIOS}"
[ -f "${SHARED_DEFAULT_LAYOUT}" ] || fail "the shared default layout is not
      at ${SHARED_DEFAULT_LAYOUT}; the per-view pane census has nothing to
      be a census against, and this lane will not grade a reference frame
      without one."
[ -d "${GUI}/node_modules" ] || fail "${GUI}/node_modules is absent; run
      \`bash ci/lib/npm-install.sh ${GUI}\` once."
command -v timeout >/dev/null || fail "timeout(1) is not on PATH, and this
      lane will not run an unbounded capture against a window server."
command -v ffmpeg >/dev/null || fail "ffmpeg is not on PATH; it is what
      downscales each device-pixel capture to its point extent."
command -v npx >/dev/null || fail "npx is not on PATH; this lane drives the
      product through the repository's own Playwright suite."

# THE BUILT FRONT-END, NAMED AND DATED RATHER THAN ASSUMED FRESH.
#
# `CODETRACER_BUILD_DIR` is what `src/tests/gui/lib/fixtures.ts` resolves
# `bin/ct` and the Electron entry point under. A reference set is only as
# current as the bundle it was taken from, so the lane refuses an absent one
# and RECORDS the mtime of the one it found. `Verification-Harness-Traps`:
# the artefact's own word, not the checkout's.
BUILD_DIR="${CODETRACER_BUILD_DIR:-${root}/src/build-debug-repro}"
[ -x "${BUILD_DIR}/bin/ct" ] || fail "no built front-end at
      ${BUILD_DIR}/bin/ct. Build it with \`just build-once\` and re-run.
      Set CODETRACER_BUILD_DIR to point elsewhere."
[ -f "${BUILD_DIR}/index.js" ] || fail "no Electron entry point at
      ${BUILD_DIR}/index.js; the tree at ${BUILD_DIR} is not a front-end
      build."
export CODETRACER_BUILD_DIR="${BUILD_DIR}"

# ---------------------------------------------------------------------------
# THE FRESHNESS GATE — and why RECORDING the mtime was not enough
# ---------------------------------------------------------------------------
#
# This lane already did better than its GPUI twin: it recorded `ctMtimeUtc`,
# `indexJsMtimeUtc` and `uiJsMtimeUtc` in the manifest, with a `note` saying
# in as many words that *"when they predate the checkout revision, the frames
# below are of an OLDER front-end than the tree names and a parity comparison
# must say so."*
#
# That note was correct, present, and useless. On 2026-10-12 the comparison
# did not say so — because a note is addressed to a reader who has already
# decided to look, and the whole failure mode is that nobody looks. The GPUI
# arm's binary was 127 commits stale, this arm's bundle was current, and the
# reading went out claiming both were one build.
#
# So the mtimes stay (they are the artefact's own word and cost nothing) and
# an ASSERTION is put in front of them. The bundle is build-once output, is
# gitignored, survives every branch switch, and is therefore stale by default
# rather than by accident — exactly the shape `ci/lib/wasm-engine-freshness.sh`
# was written for.
#
# THE RULE, and it is WEAKER than the GPUI arm's — labelled rather than left
# to look equivalent. The bundle has three Nim entry points built by `repro`
# out of `repro.nim` with three different define sets and two backends, so
# replaying the compiler's own closure here would mean keeping a second copy
# of `repro.nim`'s flags in a file nothing links to it. Instead the bundle is
# digested by its TRACKED SOURCE TREE: `git ls-files -s` (mode + blob sha1 +
# path — a content digest straight from the index, 1,786 files in 64 ms),
# plus a working-tree overlay for unstaged edits and untracked files, which
# the index alone cannot see. `ci/lib/build-freshness.sh` states what that
# does not cover — the toolchain, which the GPUI side gets for free and this
# side does not.
echo
echo "=== the subject: is this bundle of THIS tree? ==="
# shellcheck source=ci/lib/build-freshness.sh disable=SC1091
. "${root}/ci/lib/build-freshness.sh"
bf_electron_assert_fresh "${root}" "${BUILD_DIR}" ||
	fail "the Electron bundle this lane would have captured is not the one
      this checkout describes. Refused rather than captured: a reference set
      is only as current as the bundle it was taken from, and a frame of the
      wrong front-end grades exactly as green as a frame of the right one."
ELECTRON_INPUT_DIGEST="$(bf_electron_input_digest "${root}")"
ELECTRON_STAMP="${BUILD_DIR}/${BF_ELECTRON_STAMP_NAME}"

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
	fail "the host control failed. Its record is at ${OUT}/host.json and names
      which of the three it was: no still capture at all, no ScreenCapture
      grant for the capture bundle (the record carries the exact clickable
      remedy), or a display that could not be captured."

# ---------------------------------------------------------------------------
# CONTROL 2 — a capture aimed at a window that is not there must REFUSE
# ---------------------------------------------------------------------------
echo
echo "=== control 2: a capture aimed at an owner that does not exist ==="
if timeout "${CAPTURE_TIMEOUT_S}" "${CAPTURE}" capture \
	--owner="plat37e-no-such-application" \
	--out="${OUT}/control-absent.png" \
	--record="${OUT}/control-absent.json" \
	--view=control --scenario=absent-owner \
	--requested-width=1440 --requested-height=900 \
	--wait-ms=0 >/dev/null 2>&1; then
	fail "the capture path answered OK for an owner that does not exist. It is
      then answering about something other than its target, and every green
      below it would be unfalsifiable."
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
timeout "${GRADE_TIMEOUT_S}" "${GRADE}" --frame="${OUT}/control-flat.png" \
	--record="${OUT}/control-flat.blank.json" \
	--view=control --scenario=flat-frame \
	--scratch="${OUT}/scratch/control" --expect-blank ||
	fail "the flat control frame did not grade as blank, so the grader's
      negative arm is not reaching the predicate it is supposed to control."
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
TSV="${OUT}/scenarios.tsv"
python3 - "${SCENARIOS}" "${TSV}" <<'PY' || fail "the scenario set did not parse"
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
viewports = doc["viewports"]
if len(viewports) != doc["expectedViewports"]:
    sys.exit(f"FAIL: scenarios.json declares {doc['expectedViewports']} "
             f"viewports and holds {len(viewports)}")
kinds = set(doc["operationKinds"])
names = {sc["view"] for sc in scenarios}
if len(names) != len(scenarios):
    sys.exit("FAIL: two scenarios share a view name, so one would overwrite "
             "the other's PNG and the lane would still report success")
rows = []
for sc in scenarios:
    for op in sc["operations"]:
        if op["kind"] not in kinds:
            sys.exit(f"FAIL: scenario {sc['id']} uses operation "
                     f"'{op['kind']}', which operationKinds does not publish")
    vp = viewports[sc["viewport"]]
    rows.append("\t".join([sc["id"], sc["view"], str(vp["width"]),
                           str(vp["height"]), sc["viewport"]]))
open(sys.argv[2], "w").write("\n".join(rows) + "\n")
print(f"scenarios.json: {len(scenarios)} scenarios, {len(probes)} GPUI "
      f"probe(s) NOT driven here, {len(kinds)} operation kinds, "
      f"{len(viewports)} viewports")
PY

# A `--only` THAT MATCHED NOTHING IS A FAILURE AND NOT A PASS.
expected="$(python3 -c "
import json,sys
doc=json.load(open(sys.argv[1])); only=sys.argv[2]
print(sum(1 for s in doc['scenarios'] if not only or s['view']==only))
" "${SCENARIOS}" "${ONLY}")"
if [ "${expected}" -eq 0 ]; then
	fail "no scenario has the view '${ONLY}'. The view names are
      scenarios.json's own: $(cut -f2 "${TSV}" | paste -sd' ' -)"
fi

# ---------------------------------------------------------------------------
# Drive the product and capture each window
# ---------------------------------------------------------------------------
export CODETRACER_PLAT37E_OUT="${OUT}"
export CODETRACER_PLAT37E_CAPTURE="${CAPTURE}"
export CODETRACER_PLAT37E_OWNER="${OWNER}"
export CODETRACER_DEV_TOOLS=0

# ---------------------------------------------------------------------------
# THE FIXTURE'S OWN `CODETRACER_HOME`, WHICH FITS `sun_path`
# ---------------------------------------------------------------------------
#
# MEASURED 2026-10-12, first run of this lane: the fixture's per-worker
# `CODETRACER_HOME` was made in `os.tmpdir()`, inside the dev shell a nested
# nix-shell scratch (`/var/folders/<..>/T/nix-shell.DjiX0m/`), and the replay
# backend's Unix socket under it was longer than macOS's 104-byte
# `sockaddr_un.sun_path`. The session manager refused it, and the product drew
# its shell with an EMPTY editor — zero rendered rows, zero recognised
# strings, no pane located by the oracle: the exact shape of frame this lane
# must never grade green.
#
# This lane used to pick a short home itself and assert the bound. It takes
# the fixture's default now: `src/tests/gui/lib/fixtures.ts` makes the home
# under `/tmp` and refuses, before it launches anything, one whose longest
# socket path does not fit — its own or one given in
# `CODETRACER_GUI_TEST_CODETRACER_HOME` — naming the path, its length and the
# limit (`src/tests/gui/lib/socket-path-bound.ts`). And a replay that cannot
# start now fails the session with a `trace-load-error` naming the cause
# instead of leaving an empty editor, so the frames the spec asserts on are
# of an attached session or of none.
# A CAPTURE LANE MEASURES PIXELS, NOT SPEED.
#
# `lib/performance-limits.ts` gates every `timed` launch step, and
# `CODETRACER_PERF_LIMIT_SCALE` exists for lanes whose subject is not
# performance — its own docstring names the visual captures. The sibling
# PLAT-35 Electron lane has set it since its first run
# (`Justfile:5012`, `${CODETRACER_PERF_LIMIT_SCALE:-4}`); this lane never did,
# and paid for it. On 2026-10-17, graded against codetracer 596cb6e50, the
# `advanced-state` and `returned-calltrace` captures died in the LAUNCH
# fixture with `Performance limit exceeded: "first window" took 35567ms /
# 32122ms (limit: 10000ms)` — before the window was driven, before anything
# was captured, and with nothing whatever to say about the frames this lane
# exists to take.
#
# 6 rather than the sibling's 4: 35567 ms is 89% of the 40 s a scale of 4
# gives, which `timed` itself would print as SLOW, and a lane that has to be
# re-run because the host was busy is a lane that does not get run. 6 puts
# the measured worst case at 59%. A lane that GATES performance must never
# set this; this one grades pixels.
export CODETRACER_PERF_LIMIT_SCALE="${CODETRACER_PERF_LIMIT_SCALE:-6}"

# No `--headless`: the point of this lane is a window on the window server.
# `--disable-gpu-compositing` only; the Linux default also passes `--no-zygote`
# and `--disable-dev-shm-usage`, neither of which applies on Darwin.
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --disable-gpu-compositing}"

grep_filter=()
[ -n "${ONLY}" ] && grep_filter=(--grep "capture ${ONLY}\$")

# ---------------------------------------------------------------------------
# THE RUN STAMP — what makes a frame on disk THIS run's frame.
# ---------------------------------------------------------------------------
#
# The capture happens inside Playwright, in a separate process, BEFORE the
# grading loop below ever runs. So unlike the GPUI lane — which deletes
# `${view}.png`, `${view}.capture.json` and the rest immediately before it
# captures each view (plat37-macos-window-capture.sh:496) and therefore cannot
# physically grade a frame it did not just take — this lane's only freshness
# test used to be `[ -f "${rec}" ]`. A scenario whose Playwright test died
# before the capture step left the PREVIOUS run's record and PNG untouched,
# and the loop graded them as if they were this run's.
#
# That is not hypothetical. On 2026-10-17, graded against codetracer
# 596cb6e50, the `state`, `calltrace` and `editor` records carried
# `takenAt` 2026-10-12T20:29..20:39Z while `shell`, `eventLog` and
# `editorWithMark` carried 2026-10-17T13:19..13:25Z. The three stale frames
# predate the `noUserLayout` fixture option (9226bc5ed, 2026-10-15), so they
# show the raw bundled tree's standing TEST RESULTS / CONSTRAINTS column —
# and the pane census duly reported "Electron draws seven panes where the
# shared default places five" for exactly those three views, as PARITY-S1.
# The reading was an artefact of the output directory, not of the product.
#
# The remedy is a stamp, not a delete: the stale frame is kept, because it is
# the evidence that something went wrong, and the lane REFUSES to grade it and
# says in one line which two timestamps it compared. `date -u` is ISO-8601 Z,
# the same spelling the capture driver writes into `takenAt`, so the two sort
# lexicographically and the comparison needs no date parsing.
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "run stamp: frames older than ${RUN_STARTED_AT} will be refused, not graded"

# ---------------------------------------------------------------------------
# WHAT HAPPENED TO EACH SCENARIO, RECORDED BY THE RUN — not read off the log.
# ---------------------------------------------------------------------------
#
# On 2026-10-17 four of six scenarios failed, and the readings written from
# `playwright.log` said "all four failures are the same assertion at :862 ...
# AFTER the window has been captured". Two had died in the LAUNCH fixture, one
# inside `drive`, and only `entry-shell` at that assertion, after capturing
# (codetracer-pm issues/2026-10-17-plat37-readings-of-2026-10-17-misreport-
# all-four-playwright-failures-as-one-assertion.md). A list log invites that
# summary: the phase of each failure had to be inferred from line numbers.
#
# So the run writes Playwright's JSON report beside the list log, the spec
# names its phases as `test.step`s, and `ci/test/plat37_electron_outcomes.py`
# turns the report into `scenarioOutcomes` in manifest.json: per scenario its
# status, phase (the failing step, or `launch` when it failed before entering
# any), first error line, error location and whether the capture phase was
# reached. `--reporter=list,json` keeps the list output on stdout, teed to
# playwright.log as before; `PLAYWRIGHT_JSON_OUTPUT_NAME` sends the JSON to a
# file (playwright/lib/reporters/base.js `resolveOutputFile`, 1.56.1) instead
# of stdout. The path is made absolute because the driver runs from
# `${GUI}` and `--out` may be relative. A previous run's report is removed
# first, for the reason `RUN_STARTED_AT` gives: a file that merely exists is
# not this run's evidence, and a run that writes none must read as "no
# outcomes known", never as the last run's outcomes.
PW_JSON="$(cd "${OUT}" && pwd -P)/playwright.json"
rm -f "${PW_JSON}"
if [ -n "${ONLY}" ]; then
	expected_views="${ONLY}"
else
	expected_views="$(cut -f2 "${TSV}" | paste -sd, -)"
fi

echo
echo "=== driving ${expected} scenario(s) through the product's own toolbar ==="
drive_rc=0
(
	cd "${GUI}" &&
		PLAYWRIGHT_JSON_OUTPUT_NAME="${PW_JSON}" \
			timeout "${DRIVE_TIMEOUT_S}" npx playwright test --workers=1 \
			--reporter=list,json "${SPEC}" "${grep_filter[@]}"
) 2>&1 | tee "${OUT}/playwright.log" || drive_rc=$?

# ---------------------------------------------------------------------------
# Downscale to point extent and grade — the same two steps, in the same order,
# as the GPUI lane, so the graded frame means the same thing on both sides.
# ---------------------------------------------------------------------------
RECORDS="${OUT}/records.jsonl"
: >"${RECORDS}"
captured=0
refused=0

while IFS=$'\t' read -r id view width height vpname; do
	[ -n "${id}" ] || continue
	if [ -n "${ONLY}" ] && [ "${view}" != "${ONLY}" ]; then continue; fi
	png="${OUT}/${view}.png"
	points_png="${OUT}/${view}.points.png"
	rec="${OUT}/${view}.capture.json"
	route="${OUT}/${view}.route.json"
	grade="${OUT}/${view}.grade.json"

	echo
	echo "### ${id} -> ${view} at ${vpname} ${width}x${height} points"

	if [ ! -f "${rec}" ]; then
		echo "  no capture record at ${rec} — the driver did not reach it" >&2
		refused=$((refused + 1))
		continue
	fi
	# THE STAMP, CHECKED. See `RUN_STARTED_AT` above for why a record that
	# merely exists is not evidence. A record this run did not write means
	# the Playwright test for this view did not reach its capture step, which
	# is the same condition as a missing record and is counted the same way.
	rec_taken="$(python3 -c "
import json,sys; print(json.load(open(sys.argv[1])).get('takenAt',''))" "${rec}")"
	if [ -z "${rec_taken}" ] || [ "${rec_taken}" \< "${RUN_STARTED_AT}" ]; then
		echo "  REFUSED AS STALE: ${rec} was taken at '${rec_taken:-<no takenAt>}',
      before this run began at ${RUN_STARTED_AT}. The Playwright test for
      this view did not reach its capture step, so the frame on disk is a
      PREVIOUS run's and grading it would attribute an older build's
      rendering to this one. Refused rather than graded." >&2
		refused=$((refused + 1))
		python3 -c "
import json,sys
r=json.load(open(sys.argv[1]))
r['graded']=False
r['refusal']=('stale: takenAt %s precedes this run (%s)'
              % (r.get('takenAt','<none>'), sys.argv[2]))
print(json.dumps(r))" "${rec}" "${RUN_STARTED_AT}" >>"${RECORDS}"
		continue
	fi
	if [ "$(python3 -c "
import json,sys; print(json.load(open(sys.argv[1])).get('outcome'))" "${rec}")" != "captured" ]; then
		echo "  refused: $(python3 -c "
import json,sys; print(json.load(open(sys.argv[1])).get('refusal','?'))" "${rec}")" >&2
		refused=$((refused + 1))
		python3 -c "
import json,sys
r=json.load(open(sys.argv[1])); r['graded']=False
print(json.dumps(r))" "${rec}" >>"${RECORDS}"
		continue
	fi

	pw="$(python3 -c "
import json,sys; print(json.load(open(sys.argv[1]))['capturedPoints']['width'])" "${rec}")"
	ph="$(python3 -c "
import json,sys; print(json.load(open(sys.argv[1]))['capturedPoints']['height'])" "${rec}")"
	ffmpeg -loglevel error -y -i "${png}" \
		-vf "scale=${pw}:${ph}:flags=lanczos" "${points_png}" ||
		fail "downscaling ${png} to its point extent failed"

	# ----------------------------------------------------------------
	# THE ROUTING DECISION, RE-MEASURED EVERY RUN
	# ----------------------------------------------------------------
	#
	# This lane chose the window over `page.screenshot()`. That choice is
	# only honest while the two are known to agree about the content they
	# share, so the agreement is computed rather than asserted in a header.
	#
	# Measured 2026-10-12 on `entry-shell` at `wide`: both PNGs 3840x2160,
	# SSIM **0.999901** all-channel and PSNR **59.3 dB** on R, G and B, with
	# the alpha channel the only real difference (PSNR 39.7 dB) — the
	# compositor's own alpha at the window's rounded corners, which a page
	# raster has no notion of. So the window route costs nothing in content
	# fidelity and buys the one thing the page route cannot: a frame of the
	# same KIND as the GPUI arm's, from the same compositor at the same
	# scale.
	#
	# A run where these two diverge is a finding about the capture stack and
	# is recorded, never silently preferred.
	page_png="${OUT}/${view}.page.png"
	route_cmp="${OUT}/${view}.routecmp.txt"
	: >"${route_cmp}"
	if [ -f "${page_png}" ]; then
		{
			ffmpeg -hide_banner -loglevel error -i "${png}" -i "${page_png}" \
				-lavfi "[0:v][1:v]psnr=stats_file=-" -f null - 2>&1 |
				grep -E '^n:' | head -1
			ffmpeg -hide_banner -loglevel error -i "${png}" -i "${page_png}" \
				-lavfi "[0:v][1:v]ssim=stats_file=-" -f null - 2>&1 |
				grep -E '^n:' | head -1
		} >>"${route_cmp}" 2>&1 || true
		echo "  route agreement (window vs page): $(tr '\n' ' ' <"${route_cmp}")"
	fi

	grade_rc=0
	timeout "${GRADE_TIMEOUT_S}" "${GRADE}" --frame="${points_png}" \
		--record="${grade}" --view="${view}" --scenario="${id}" \
		--scratch="${OUT}/scratch/${view}" || grade_rc=$?

	python3 - "${rec}" "${grade}" "${png}" "${points_png}" "${grade_rc}" \
		"${route}" "${route_cmp}" "${SHARED_DEFAULT_LAYOUT}" \
		>>"${RECORDS}" <<'PY' || fail "the census did not assemble"
import json, os, struct, sys
rec = json.load(open(sys.argv[1]))
grade = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else None
png, points_png, grade_rc, route_path = sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
route = json.load(open(route_path)) if os.path.exists(route_path) else None
cmp_path = sys.argv[7]
shared_layout_path = sys.argv[8]
route_cmp = (open(cmp_path).read().strip().splitlines()
             if os.path.exists(cmp_path) else [])
problems = []

# THE PNG'S OWN IHDR against what the driver said it captured. The record is
# the driver's word for what it took; the IHDR is the artefact's word for what
# it holds.
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

if not rec.get("satisfiesG1"):
    problems.append("a captured run did not claim G1")
if rec["attestation"]["matched"] < 1:
    problems.append("G1 is claimed and no window was attested")
if not rec["capture"]["sameWindowAsAttested"]:
    problems.append("ScreenCaptureKit captured a different window than the "
                    "one CGWindowListCopyWindowInfo attested")
if route is None:
    problems.append("the driver wrote no route record, so nothing says which "
                    "program state this frame is of")
else:
    if route["finalState"]["rrTicks"] < 0:
        problems.append("the product reported no position at capture time")
    # A ROUTE SAMPLED BUSY IS REFUSED, NOT GRADED. The driver now settles
    # before its first sample and throws on a busy final state; this is the
    # defence in depth against a record that was written anyway. `entry-shell`
    # once recorded `busy: true, line 0` beside a frame that drew line 1
    # (codetracer-pm issue 2026-10-12-the-electron-capture-lanes-entry-shell-
    # samples-...). `is not False`: an absent flag is not "not busy".
    if route["finalState"].get("busy") is not False:
        problems.append("the route's final state was sampled with busy="
                        f"{route['finalState'].get('busy')!r}; the lane "
                        "measured before the session settled")
    # A VACUOUS GREEN IS REFUSED: "settled between operations" over zero
    # operations must be recorded as null, never true.
    if (route.get("editorSettledBetweenOperations") is True
            and route.get("movesPerformed") == 0):
        problems.append("editorSettledBetweenOperations is true over zero "
                        "operations, which is vacuous; it must be null")
    if not route["pageRoute"]["byteStable"]:
        problems.append("the page never produced two byte-identical "
                        "screenshots, so the window was still moving")
if grade is None:
    problems.append("the grader wrote no record")
elif grade["verdict"] != "OK":
    problems.append("grader: " + "; ".join(grade["problems"]))
elif grade_rc != 0:
    problems.append(f"the grader answered OK and exited {grade_rc}")

# ---------------------------------------------------------------------------
# THE PANE CENSUS, AGAINST THE SHARED DEFAULT AND NOT AGAINST A NUMBER
# ---------------------------------------------------------------------------
#
# WHAT THIS CATCHES, and it is the reason it exists rather than a precaution.
# Until 2026-10-14 this spec did not set `noUserLayout`, so the launch fixture
# copied `src/config/default_layout.json` VERBATIM into the run's config and
# the index process loaded it instead of deriving debug mode's default. The
# bundled tree carries a top-level TEST RESULTS / CONSTRAINTS column that the
# product's own source calls "nobody's layout" and that
# `frontend.modeDefaultOmittedContentIds` / `.paneHomesForMode` remove from
# every mode. Every frame this lane took therefore showed two panes no
# CodeTracer front-end opens with, the oracle counted 7 against the GPUI
# window's 5, and that was filed as PARITY-S1 with GPUI named the deficient
# side. The frames were right and the finding read them backwards. (Since
# 2026-10-22 the fixture takes the product's first-run path by default and
# `noUserLayout` is gone; the raw bundled tree is the opt-in `bundledLayout`,
# which this lane must not set.)
#
# WHY THE EXPECTATION IS DERIVED AND NOT WRITTEN DOWN. `expected` below is
# computed from `headless_app/shared_default_layout.generated.json` — the
# generated translation of the desktop's own debug-mode default, and the
# arrangement every front-end opens with. A literal `== 5` here would be a
# second copy of that truth, free to go on agreeing with itself after the
# shared tree moved (Verification-Harness-Traps 14). Change the shared
# default and this expectation changes with it.
#
# WHY IT IS A SET AND NOT A COUNT. A count of 5 is satisfied by a frame with
# five WRONG panes, and `paneCount` alone is also satisfied by an oracle that
# has started labelling everything `other`. The comparison is over the
# labelled multiset, so a renderer that loses `state` and gains an `other`
# still fails. An oracle that reads nothing answers the empty set and fails
# too, which is the property a vacuous assertion would not have.
def _shared_default_visible_panes(path):
    """The panes the shared default layout DRAWS: one per stack (the active
    tab), plus every pane that is not inside a stack. A background tab is not
    on screen and the oracle cannot see one."""
    doc = json.load(open(path))
    out = []

    def walk(node):
        kind = node.get("kind")
        if kind == "pane":
            out.append(node["pane"])
            return
        kids = node.get("children", []) or []
        if kind == "stack":
            if not kids:
                return
            i = node.get("activeIndex", 0)
            if not isinstance(i, int) or i < 0 or i >= len(kids):
                raise ValueError(
                    f"{path}: a stack's activeIndex {i!r} is not a tab of it")
            walk(kids[i])
            return
        for k in kids:
            walk(k)

    walk(doc)
    if not out:
        raise ValueError(f"{path}: the shared default draws no pane at all")
    return sorted(out)


if grade is not None and grade.get("oracle") is None:
    # NOT a silent skip. A grader that stops emitting `oracle` would otherwise
    # make this whole census vacuous while every other check stayed green,
    # which is the failure mode the census was written to not have.
    problems.append(
        "the grader wrote a record with no `oracle`, so the pane census could "
        "not be taken at all")
elif grade is not None:
    try:
        expected = _shared_default_visible_panes(shared_layout_path)
    except Exception as exc:                      # noqa: BLE001 - reported, never swallowed
        problems.append(
            "the shared default layout could not be read, so the pane census "
            f"has nothing to be a census AGAINST: {exc}")
    else:
        seen = sorted(grade["oracle"].get("panes") or [])
        rec["paneCensus"] = {
            "expected": expected,
            "seen": seen,
            "expectedFrom": os.path.relpath(shared_layout_path),
            "agrees": seen == expected,
        }
        if seen != expected:
            extra = sorted((set(seen) - set(expected)) or [])
            missing = sorted((set(expected) - set(seen)) or [])
            problems.append(
                "the pane census disagrees with the shared default "
                f"({len(seen)} drawn, {len(expected)} expected): "
                f"saw {seen}, expected {expected}"
                + (f"; extra {extra}" if extra else "")
                + (f"; missing {missing}" if missing else "")
                + ". A frame with panes the shared default does not place is "
                  "not a reference frame for parity: see this lane's spec "
                  "launch-layout note (the fixture default, the product's first-run "
                  "layout) and PARITY-S1.")

rec["grade"] = grade
rec["route"] = route
rec["routeAgreement"] = {
    "what": "window capture vs page.screenshot() of the same settled state",
    "ffmpeg": route_cmp,
    "why": "the routing decision, re-measured rather than asserted. Both "
           "frames are of the same content at the same device extent; a run "
           "in which they diverge is a finding about the capture stack.",
}
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
done <"${TSV}"

# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------
python3 - "${SCENARIOS}" "${OUT}" "${ONLY}" "${BUILD_DIR}" "${drive_rc}" \
	"${ELECTRON_INPUT_DIGEST}" "${ELECTRON_STAMP}" \
	"${root}/ci/test" "${PW_JSON}" "${expected_views}" \
	<<'PY' || fail "the manifest did not assemble"
import datetime, json, os, subprocess, sys
(scenarios_path, out, only, build_dir, drive_rc,
 input_digest, stamp_path, outcomes_dir, pw_json,
 expected_views) = sys.argv[1:11]
sys.path.insert(0, outcomes_dir)
import plat37_electron_outcomes


def stamp_field(name):
    try:
        for line in open(stamp_path):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None

doc = json.load(open(scenarios_path))
records = []
p = os.path.join(out, "records.jsonl")
if os.path.exists(p):
    for line in open(p):
        line = line.strip()
        if line:
            records.append(json.loads(line))


def mtime(path):
    try:
        return (datetime.datetime.utcfromtimestamp(os.path.getmtime(path))
                .strftime("%Y-%m-%dT%H:%M:%SZ"))
    except OSError:
        return None


def git(*args):
    try:
        return subprocess.run(("git",) + args, capture_output=True,
                              text=True, timeout=20).stdout.strip()
    except Exception:
        return ""


manifest = {
    "schemaVersion": 1,
    "milestone": "PLAT-37",
    "lane": "plat37-macos-electron-capture",
    "renderer": "electron",
    "only": only,
    "playwrightExitCode": int(drive_rc),
    # PER SCENARIO, FROM THE RUN'S OWN JSON REPORT: status, the phase it
    # failed in, the first error line, its location and whether the capture
    # phase was reached. A readings file summarising this run enumerates from
    # HERE, and never states a common cause or an "after the capture" that
    # `captureReached` does not back. `reportStatus` other than "parsed" means
    # the outcomes are UNKNOWN, not that nothing failed.
    "scenarioOutcomes": plat37_electron_outcomes.summarise(
        pw_json, [v for v in expected_views.split(",") if v]),
    "expectedScenarios": doc["expectedScenarios"],
    "gpuiProbesDriven": 0,
    "whyNoProbes": "scenarios.json: 'A probe is NOT part of the "
                   "cross-renderer comparison: it has no Electron arm, so "
                   "nothing here claims one.'",
    "operationKinds": doc["operationKinds"],
    "host": json.load(open(os.path.join(out, "host.json"))),
    # THE PROVENANCE OF THE THING CAPTURED. A reference set is only as current
    # as the bundle it was taken from, and this lane states the bundle's age
    # rather than letting the checkout's revision imply it.
    "subject": {
        "buildDir": build_dir,
        "ctMtimeUtc": mtime(os.path.join(build_dir, "bin", "ct")),
        "indexJsMtimeUtc": mtime(os.path.join(build_dir, "index.js")),
        "uiJsMtimeUtc": mtime(os.path.join(build_dir, "ui.js")),
        "checkoutRevision": git("rev-parse", "HEAD"),
        "checkoutBranch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "note": "the mtimes are the artefact's own word. When they predate "
                "the checkout revision, the frames below are of an OLDER "
                "front-end than the tree names and a parity comparison must "
                "say so.",
        # The mtimes above are a NOTE. This is the ASSERTION, and the
        # difference is the whole lesson of 2026-10-12: the note was present,
        # correct and ignored, because a note is addressed to a reader who
        # has already decided to look and the failure mode is that nobody
        # looks. The lane now refuses before it captures.
        "freshnessGate": {
            "enforced": True,
            "rule": "the bundle must carry ci/lib/build-freshness.sh's stamp "
                    "at .codetracer-bundle.build-stamp, and the stamp's "
                    "input_digest must equal the digest recomputed from this "
                    "tree now: `git ls-files -s` over the bundle's source "
                    "roots, plus a working-tree overlay for unstaged edits "
                    "and untracked files.",
            "refusesRatherThanWarns": True,
            "inputDigest": input_digest,
            "stampInputDigest": stamp_field("input_digest"),
            "stampBuiltAt": stamp_field("built_at"),
            "weakerThanTheGpuiArm": "the GPUI binary's digest is the "
                    "COMPILER's own closure, so it covers the toolchain for "
                    "free (a /nix/store path is a content hash). This one is "
                    "a source-tree digest and does NOT see the compiler: a "
                    "bundle built by a different nim from identical sources "
                    "reads as fresh here. Recorded rather than implied.",
            "overApproximates": "the roots include src/frontend/gpui/**, "
                    "which no Electron entry point compiles, so a GPUI-only "
                    "edit demands a bundle rebuild it does not strictly "
                    "need. That is the safe direction (false red, never "
                    "false green) and for a parity reading it is arguably "
                    "correct: both arms must be of ONE checkout.",
        },
    },
    "pixelPaths": {
        "macos-window-screencapturekit": {
            "how": "the product launched through its own `ct` (which execv()s "
                   "into Electron) on the Quartz window server; "
                   "SCScreenshotManager over "
                   "SCContentFilter(desktopIndependentWindow:)",
            "needsCompositor": True,
            "needsTccGrant": True,
            "satisfiesG1": True,
            "file": "<view>.png (device pixels) / <view>.points.png (points)",
            "why": "the same binary, the same attestation and the same probe "
                   "the GPUI arm uses, so a difference between the two "
                   "reference sets is a difference between the front-ends.",
        },
        "cdp-page-screenshot": {
            "how": "page.screenshot() over CDP — Chromium's own raster of the "
                   "web contents",
            "needsCompositor": False,
            "needsTccGrant": False,
            "satisfiesG1": False,
            "file": "<view>.page.png",
            "why": "kept beside the window frame, from the same settled "
                   "state, so the routing decision stays falsifiable instead "
                   "of being an argument in a header. It is NOT the reference "
                   "frame: a page raster is not a window.",
        },
    },
    "standing": {
        "kind": "host-conditional evidence",
        "requiredGate": False,
        "why": "needs a live macOS GUI session and a kTCCServiceScreenCapture "
               "grant held by com.metacraft-labs.guiassert.capture. Neither "
               "exists on a fresh host or in CI. PLAT-23's G5 cuts both ways: "
               "a gate that cannot RUN is not a gate.",
    },
    "displayConstraint": {
        "note": "A WINDOW CAN BE WIDER THAN ITS DISPLAY, and on this lane one "
                "is. scenarios.json's `wide` viewport is 1920x1080 POINTS and "
                "this display is 1728x1117 points; the ELECTRON window is "
                "made at 1920x1080 points at origin (0,33) — 192 points of it "
                "hang off the right edge — and the capture is of the window's "
                "OWN surface through SCContentFilter(desktopIndependentWindow:), "
                "so the off-screen strip is captured and is real rendered "
                "product, not padding. The GPUI window asked for the same "
                "thing WAS clamped to 1728x1084, and is no longer: that "
                "asymmetry was a property of the two FRONT-ENDS and not of "
                "this host — gpui built a titled NSWindow and did not "
                "override `constrainFrameRect:toScreen:`, so AppKit's "
                "default visible-frame constraint applied to it and not to "
                "Electron, which overrides that hook. Since PARITY-G1 "
                "(2026-10-18) the shim adds the same override to gpui's "
                "`GPUIWindow`, and the GPUI window is 1920x1108 points — "
                "1920x1080 of content plus its 28-point title bar, which "
                "the parity crop removes. Read `viewportsHonoured` and "
                "`viewportsClamped` below rather than this sentence: they are "
                "computed from the records. Whatever is clamped is recorded "
                "as viewportHonoured:false with the deviation in CONTENT "
                "points (frame height minus titleBarPoints) and is never "
                "relabelled.",
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

# ONE LINE PER FAILED SCENARIO, from `scenarioOutcomes` — each with its own
# phase and cause, so a reader never has to infer either from the list log.
# Exit 2 means the report is missing, unparseable or empty; the line says so,
# and that is "outcomes unknown", never "no scenario failed".
echo
echo "=== per-scenario outcomes (manifest.json scenarioOutcomes) ==="
python3 "${root}/ci/test/plat37_electron_outcomes.py" --report "${PW_JSON}" \
	--expect-views "${expected_views}" --format lines | sed 's/^/  /' || true
# The same record, condensed for the fail messages below: `<scenario> (<phase>)`
# per failure, or the reason there is no record.
failed_scenarios="$(
	python3 - "${OUT}/manifest.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))["scenarioOutcomes"]
if o["reportStatus"] != "parsed":
    print(f"per-scenario outcomes UNKNOWN ({o['reportStatus']}): {o['problem']}")
else:
    bad = [f"{s['scenario']} ({s['phase']})" for s in o["scenarios"]
           if s["status"] not in ("passed", "skipped")]
    bad += [f"{v} (not in report)" for v in o["missingScenarios"]]
    print("failed: " + ", ".join(bad) if bad else "no scenario failed")
PY
)" || failed_scenarios="per-scenario outcomes UNKNOWN: manifest.json unreadable"

total=$((captured + refused))
[ "${total}" -eq "${expected}" ] ||
	fail "${total} scenarios ran where ${expected} were declared;
      ${failed_scenarios}"

python3 - "${OUT}/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
s = m["subject"]
print(f"  subject: {s['buildDir']}")
print(f"           bin/ct {s['ctMtimeUtc']}  ui.js {s['uiJsMtimeUtc']}")
print(f"           checkout {s['checkoutRevision'][:9]} ({s['checkoutBranch']})")
for r in m["records"]:
    if r.get("outcome") != "captured":
        continue
    req, got = r["requestedPoints"], r["windowFramePoints"]
    mark = "honoured" if r.get("viewportHonoured") else "CLAMPED BY THE DISPLAY"
    rt = r.get("route") or {}
    traj = ",".join(rt.get("trajectory", [])[-2:])
    print(f"  {r['view']:<14} asked {req['width']}x{req['height']} pt, "
          f"window {got['width']}x{got['height']} pt, "
          f"captured {r['capturedPixels']['width']}x"
          f"{r['capturedPixels']['height']} px @{r['pointPixelScale']}x  "
          f"-> {mark}   [{traj}]")
PY

[ "${refused}" -eq 0 ] ||
	fail "${refused} of ${total} scenarios did not produce a graded frame;
      ${failed_scenarios}. Each failure's phase and cause are in
      ${OUT}/manifest.json under scenarioOutcomes."
[ "${drive_rc}" -eq 0 ] ||
	fail "the Playwright driver exited ${drive_rc}; ${failed_scenarios}.
      Each failure's phase and cause are in ${OUT}/manifest.json under
      scenarioOutcomes; the list log is ${OUT}/playwright.log."
echo
echo "OK: ${captured} of ${expected} attested Electron window frames in ${OUT}"
echo "    Every record carries satisfiesG1: true and"
echo "    standing: HOST-CONDITIONAL EVIDENCE. This lane is not a gate."
