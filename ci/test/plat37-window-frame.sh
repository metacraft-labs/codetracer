#!/usr/bin/env bash
#
# plat37-window-frame.sh — PLAT-37's CAPTURE LANE.
#
#   bash ci/test/plat37-window-frame.sh              # capture everything
#   bash ci/test/plat37-window-frame.sh --only stepped-editor
#   bash ci/test/plat37-window-frame.sh --inside <config>   # internal
#
# It opens a real `codetracer-gpui` window on a real compositor, once per
# pinned scenario, against a shim built two ways, and writes what happened
# into `build/plat37/manifest.json`. It asserts almost nothing itself: the
# GATE is `src/frontend/gpui/tests/test_gpui_window_frame.nim`, which reads
# this manifest and the frames beside it.
#
# THE SPLIT IS THE SAME ONE PLAT-35 ALREADY HAS, and for the same reason. Its
# Electron arm is a recorded Playwright capture read back as JSON, because
# there is nothing for a Nim binary to link on that side. Here the reason is
# the compositor: the assertions are in Nim, over GuiAssert, and a suite that
# had to be *inside* a nested sway to make them would be a suite nobody can
# run from an editor. A capture that never ran fails in the gate rather than
# passing quietly, which is what the manifest's three-state partition is for.
#
# ===========================================================================
# WHAT IS CAPTURED, AND WHY THERE ARE TWO BUILDS AND THREE SHIMS
# ===========================================================================
#
# `DIFF-6` — the build is the differential, and it is the only one this
# milestone has. The same binary, the same compositor, the same scenario,
# against a shim built WITH and WITHOUT `--features gpui-backend`: the
# featured build produces a frame that clears the vision lane and the
# featureless build produces none at all.
#
# **TWO SWITCHES ARE OFF, NOT ONE, AND THIS LANE THROWS BOTH.** The first is
# the Cargo feature. The second is in `src/frontend/gpui/main.nim`, and it is
# the one four milestones' prose got wrong: `isonim-gpui`'s `window.rs` has no
# `cfg` outside `#[cfg(test)]`, so `create_window` (a `Vec` push) and
# `show_window` (a state transition) are byte-identical in both builds, and
# the ONLY function that branches on the feature is `gpui_launch` — which
# `codetracer-gpui` did not call until PLAT-37. Flipping the feature alone
# would have changed nothing observable.
#
# A THIRD SHIM IS BUILT AND IS NOT A SUBSTITUTE FOR EITHER. `gpui-headless`
# exports `gpui_render_to_pixels` over Zed's `HeadlessAppContext` +
# `Window::render_to_image` and needs no compositor at all. It is measured
# here, beside the windowed path, and LABELLED per row — because PLAT-23's G1
# asks that *a window has been observed*, and an off-screen RGBA buffer is not
# one. Conflating the two would be exactly the tier violation PLAT-23 wrote
# the rule for, so the manifest records `satisfiesG1` per pixel path and the
# gate asserts both values rather than assuming either.
#
# AND FOUR COMPOSITOR CONFIGURATIONS, EACH RUN. PLAT-19 measured four and this
# milestone's floor counts them, so they are four MEASUREMENTS rather than four
# sentences about a measurement somebody else took: sway with wlroots' pixman
# renderer (which is what `wayland-run-test.sh` DEFAULTS to, a detail every
# published sentence about this lane got wrong by calling the default "gles2"),
# sway with gles2, weston's refusal EXECUTED, and Xvfb captured from the X
# server's own `-fbdir` framebuffer — where the re-measurement OVERTURNED the
# published answer: the window paints under Xvfb. See `probe_configurations`
# below.
#
# ===========================================================================
# THE CAPTURE PARTITION
# ===========================================================================
#
# Every scenario run ends in exactly one of three states and the manifest says
# which: `captured`, `refused` or `timedout`. A run that silently produced
# nothing must be indistinguishable from NEITHER of the other two — that is
# the Silent-Self-Pass rule applied to a compositor, and it is why `outcome`
# is written from the script's own control flow rather than inferred from
# whether a file exists.
#
# THE BLANK CONTROL IS PART OF THE CAPTURE, not part of the assertion.
# `isonim-gpui/scripts/wayland-capture-frame.sh` waits for the output to go
# blank before it watches for the window, and since PLAT-37 it RETAINS that
# frame and FAILS when it cannot take one. Every vision assertion in the gate
# is a comparison against it (§7b: a control you have never made fail is not a
# control), so a scenario with no blank control is `refused` here rather than
# `captured` with an asterisk.
#
# ===========================================================================
# WHAT THIS LANE REFUSES TO DO
# ===========================================================================
#
#  * NO NORMALISATION. No retry-until-it-looks-right, no frame selection by
#    score, no cropping to the interesting part. PLAT-35 refused to normalise
#    the editor scroll before its screenshot because *"a capture that
#    normalises publishes a frame the product does not reliably produce"*, and
#    a clamp is a silent repair (§36a).
#  * NO SKIPS. Every missing prerequisite is a named failure. A lane that
#    detects a missing compositor, returns early and is counted as passed is
#    the defect (`Silent-Self-Pass-Audit-2026-08-23.md`).
#  * NO SEVENTH SCENARIO. The six come from `src/tests/visual/scenarios.json`,
#    unchanged and un-renamed, and are read from it rather than listed here. A
#    scenario invented for this milestone would be a corpus that grew to fit
#    its instrument.
#  * NO MOCK COMPOSITOR, NO FAKE FRAME, NO SYNTHETIC PPM. A test against a
#    constructed image proves nothing about a renderer.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# `|| exit` rather than a bare `cd`: every path below is relative to the repo
# root, so a `cd` that failed would run the whole lane somewhere else and the
# first thing anyone would see is a missing fixture rather than a missing
# directory (shellcheck SC2164).
cd "${root}" || exit 1

WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
GUI_ASSERT="${WS}/GuiAssert"
OUT="${root}/build/plat37"
BIN="${root}/build/bin/codetracer-gpui"
SCENARIOS="${root}/src/tests/visual/scenarios.json"

# The window the frames are taken at. NOT the scenario's own viewport: the
# headless sway output is 1920x1080 and a window larger than its output is
# clipped by the compositor, so every scenario is drawn at one size and the
# viewport dimension is PLAT-35's, not this milestone's. Said here rather than
# discovered from a clipped frame.
FRAME_W=1440
FRAME_H=900

# The capture's settle budget, and the event loop's hard bound. The second is
# strictly greater than the first so the window is still up while the capture is
# still watching — and the manifest records the elapsed time and the TICK the
# frame was painted on, so the headroom is a published figure rather than a
# hope.
#
# BOTH NUMBERS ARE MEASURED, AND THE MEASUREMENT IS THE SLOWEST SCENARIO'S,
# NOT THE TYPICAL ONE. They were 25 s / 32 s on 2026-09-22 and five of the six
# scenarios cleared that comfortably (`stepped-editor` painted on phase-2 tick
# 33 of 100, i.e. 8.3 s of a 25 s budget). `returned-calltrace` did NOT: it
# performs 21 `stepIn`s and a `stepOut` BEFORE the window is built, so its
# startup alone outran the whole capture window and the run came back
# `timedout` with `returned-calltrace.ppm.timeout.ppm` holding 25 s of blank
# screen. That is a budget defect and it is fixed as one.
#
# **IT IS NOT FIXED BY GIVING THE TWO ARMS DIFFERENT BUDGETS.** The featureless
# arm's binary exits in about 8 s and then the capture polls an empty screen
# for the rest of the window, which is pure wall clock spent proving a
# negative. Shortening it there would be the cheapest thing in this file and it
# would also destroy `DIFF-6`: an arm that was given less time to produce a
# frame has an explanation for producing none that is not "it has no renderer".
# One budget, both arms, and the cost is paid.
#
# The paint tick is recorded per run so a future slowdown shows up as shrinking
# headroom rather than as a sudden timeout.
CAPTURE_TIMEOUT_S=60
QUIT_AFTER_MS=70000

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Prerequisites — every one of them fails BY NAME
# ---------------------------------------------------------------------------
check_prereqs() {
	[ -d "${ISONIM_GPUI}" ] || fail "the isonim-gpui sibling checkout is not at ${ISONIM_GPUI}.
      The capture script, the compositor harness and the shim all live there.
      It is a workspace repo; a missing sibling is a named failure and never
      a skip."
	[ -d "${GUI_ASSERT}" ] || fail "the GuiAssert sibling checkout is not at ${GUI_ASSERT}.
      PLAT-37 declares this cross-repo edge rather than discovering it:
      the gate imports \`gui_assert\` for four entry points that are each
      pure over a file (decodeGray, computeSsim, edgeChangeRatio, runOcr).
      GuiAssert is NOT a build dependency of codetracer."
	for script in wayland-run-test.sh wayland-capture-frame.sh; do
		[ -f "${ISONIM_GPUI}/scripts/${script}" ] ||
			fail "${ISONIM_GPUI}/scripts/${script} is missing"
	done
	for tool in sway grim wayland-info cargo python3; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fail "'${tool}' is not on PATH. The dev shell declares it
      (nix/shells/ci-base.nix); running this lane outside the shell is what
      this message is for."
	done
	# weston is refused BY NAME rather than absent by accident: it advertises
	# no `wl_seat` and GPUI's Wayland client unwraps that `None`, so every
	# GPUI process dies at startup under it. The refusal is in
	# `wayland-run-test.sh`; naming it here keeps the reason attached to the
	# lane that depends on it.
	if [ "${PLAT37_COMPOSITOR:-sway}" = "weston" ]; then
		fail "weston advertises no wl_seat; GPUI cannot start under it.
      Measured 2026-09-17, refused by name in isonim-gpui/scripts/wayland-run-test.sh."
	fi
	# Xvfb is already in this shell for the Playwright lanes and CANNOT
	# substitute here — but NOT for the reason this comment gave until
	# 2026-09-22, which was *"no DRI3, so wgpu never gets a surface and the
	# window paints nothing"*. **It paints.** `probe_configurations` below
	# measures it and the gate asserts it. What Xvfb cannot do is be CAPTURED
	# by this lane: `grim` speaks `zwlr_screencopy_manager_v1`, a Wayland
	# protocol that does not exist on an X display, and this shell's `ffmpeg`
	# is the default build with no `x11grab` demuxer at all.
	:
}

# ---------------------------------------------------------------------------
# The three shims — BUILT BY THE SIBLING, SELECTED BY SUBSTITUTION
# ---------------------------------------------------------------------------
#
# They are produced by `isonim-gpui`'s own `just plat37-shims`, in ITS dev
# shell, and this lane only consumes them. Measured 2026-09-22: `cargo build
# --features gpui-backend` run from codetracer's dev shell fails to LINK —
# `rust-lld: error: unable to find library -lxcb / -lxkbcommon /
# -lxkbcommon-x11` — because those are declared in the sibling's `flake.nix`
# and are needed by the linker, not merely by the loader. A cross-repo build
# belongs to the repo that owns it.
#
# **AND THE SELECTION IS A FILE SUBSTITUTION, NOT AN `LD_LIBRARY_PATH`. THIS
# IS THE MEASUREMENT THAT DECIDED IT.** `isonim_gpui/bindings.nim` resolves
# the shim at COMPILE time:
#
#     const localShimLib = shimTargetDir / "libgpui_nim_shim.so"
#     when fileExists(localShimLib): const shimLib = localShimLib
#     else:                          const shimLib = "libgpui_nim_shim.so"
#
# so every binary built in this workspace has the ABSOLUTE path
# `…/isonim-gpui/rust/target/debug/libgpui_nim_shim.so` baked into its
# `{.dynlib.}` pragma. `dlopen` on an absolute path does not consult
# `LD_LIBRARY_PATH` at all — confirmed by the failure mode, which names that
# exact path: `could not load: /home/…/rust/target/debug/libgpui_nim_shim.so`.
# A lane that set `LD_LIBRARY_PATH` per configuration would therefore have run
# BOTH arms of `DIFF-6` against whichever shim happened to be at that path,
# and the differential would have compared a build with itself. That is §30's
# two-copies defect wearing an environment variable, and it is the kind that
# passes.
#
# So the arm is selected by putting the right bytes at the baked path, and the
# original is restored on exit whatever happens.
SHIM_DIR="${ISONIM_GPUI}/rust/target/plat37"
LIVE_SHIM="${ISONIM_GPUI}/rust/target/debug/libgpui_nim_shim.so"
SHIM_BACKUP=""

restore_shim() {
	if [ -n "${SHIM_BACKUP}" ] && [ -f "${SHIM_BACKUP}" ]; then
		mv -f "${SHIM_BACKUP}" "${LIVE_SHIM}"
		SHIM_BACKUP=""
		echo "restored ${LIVE_SHIM}"
	fi
}
trap restore_shim EXIT

use_shim() {
	local config="$1"
	local src="${SHIM_DIR}/libgpui_nim_shim.${config}.so"
	[ -f "${src}" ] || fail "the ${config} shim is not at ${src}.
      Build all three in the sibling's own dev shell, which is where the
      linker flags for the windowed one are declared:

          cd ${ISONIM_GPUI} && nix develop --command just plat37-shims

      This lane does NOT build them: measured 2026-09-22, the windowed link
      fails from codetracer's shell with three 'unable to find library'
      errors."
	if [ -z "${SHIM_BACKUP}" ] && [ -f "${LIVE_SHIM}" ]; then
		SHIM_BACKUP="${LIVE_SHIM}.plat37-backup"
		cp -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
	fi
	cp -f "${src}" "${LIVE_SHIM}"
	echo "shim in place: ${config} ($(wc -c <"${LIVE_SHIM}") bytes, \
$(ldd "${LIVE_SHIM}" | wc -l) ldd entries)"
}

record_shim() {
	local config="$1"
	local src="${SHIM_DIR}/libgpui_nim_shim.${config}.so"
	local dest="${OUT}/shim/${config}"
	mkdir -p "${dest}"
	[ -f "${src}" ] || fail "the ${config} shim is not at ${src}"
	# THE ARTEFACT, NOT THE BUILD FILE. PLAT-23 measured the feature's absence
	# as an `ldd` closure of libgcc + libc; `just build-gpui` only WARNS when
	# the cdylib is missing, so a build that silently linked the stub is the
	# state this reading exists against.
	cp -f "${src}" "${dest}/libgpui_nim_shim.so"
	# **`LD_LIBRARY_PATH` IS CLEARED FOR THIS READING, AND THAT IS THE WHOLE
	# DIFFERENCE BETWEEN TWO TRUE NUMBERS.** `ldd` cannot recurse through a
	# library it did not find, so the windowed shim reports EIGHT entries on
	# the bare loader path (three of them `not found`) and ELEVEN once
	# `CODETRACER_GPUI_RUNTIME_LIB_PATH` resolves `libxcb.so.1` and pulls
	# `libXau`, `libXdmcp` and `libxcb-xkb` in behind it. Both are correct
	# readings of one artefact, and a manifest whose figure depended on
	# whether this function happened to run before or after the export would
	# be a figure nobody could reproduce. The DIRECT dependencies are what
	# the feature adds, so the bare reading is the one recorded.
	env -u LD_LIBRARY_PATH ldd "${src}" >"${dest}/ldd.txt" 2>&1
	nm -D --defined-only "${src}" 2>/dev/null |
		awk '{print $NF}' | grep '^gpui_' | sort -u >"${dest}/symbols.txt"
	echo "  ${config}: $(wc -c <"${src}") bytes, \
$(wc -l <"${dest}/ldd.txt") ldd entries, $(wc -l <"${dest}/symbols.txt") gpui_ symbols"
}

runtime_ld_path() {
	# `CODETRACER_GPUI_RUNTIME_LIB_PATH` is exported by the dev shell and
	# carries the GL / Vulkan / Wayland / xkbcommon stack GPUI `dlopen`s at
	# RUN time (none of it shows up in `ldd`). It is NOT on the global
	# `LD_LIBRARY_PATH` on purpose; see the shell. The shim itself is reached
	# by its baked absolute path and needs nothing from here.
	echo "${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}"
}

# ---------------------------------------------------------------------------
# One scenario, one build — run inside the nested compositor
# ---------------------------------------------------------------------------
capture_one() {
	local config="$1" id="$2" ops="$3" mode="${4:-debug}"
	local dir="${OUT}/${config}"
	mkdir -p "${dir}"
	local ppm="${dir}/${id}.ppm"
	local plan="${dir}/${id}.plan.json"
	local log="${dir}/${id}.run.log"
	rm -f "${ppm}" "${ppm}.blank" "${ppm}.done" "${ppm}.log" \
		"${ppm}.timeout.ppm" "${ppm}.dirty.ppm" "${plan}" "${log}"

	local argv=("${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}"
		"--width=${FRAME_W}" "--height=${FRAME_H}"
		"--plan-out=${plan}")
	if [ "${mode}" = "edit" ]; then
		# `ct edit --ui=gpui <project>` — PLAT-16's PRODUCT-MODE dimension,
		# reaching a window through the shipped binary. It opens no
		# recording at all (`product_mode.sourceContractFor(pmEdit)`: the
		# origin is the WORKING TREE), so it takes no operations and a
		# different positional.
		argv+=("--edit" "${EDIT_PROJECT}")
	else
		[ -n "${ops}" ] && argv+=("--replay-ops=${ops}")
		argv+=("${TRACE}")
	fi

	# The capture starts FIRST and polls, so it does not matter that there is
	# nothing to see yet, and its `.done` is what the watcher below waits for.
	bash "${ISONIM_GPUI}/scripts/wayland-capture-frame.sh" \
		"${ppm}" "${CAPTURE_TIMEOUT_S}" &
	local cap=$!

	local started ended elapsed rc
	started=$(date +%s%3N)
	"${argv[@]}" >"${log}" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	elapsed=$((ended - started))

	wait "${cap}"
	local cap_rc=$?

	# THE PARTITION, written from control flow and never inferred.
	local outcome
	if [ ! -f "${ppm}.done" ]; then
		outcome="refused"
	elif [ ! -f "${ppm}.blank" ]; then
		# The blank control could not be taken, so no vision assertion over
		# this frame has anything to be false against. `refused`, not
		# `captured`, whatever else happened.
		outcome="refused"
	elif [ -f "${ppm}" ]; then
		outcome="captured"
	elif [ "${cap_rc}" -ne 0 ]; then
		outcome="timedout"
	else
		outcome="refused"
	fi

	# EVERY VALUE ARRIVES AS AN ARGUMENT, never interpolated into the program
	# text. A path or an ops spec pasted into a heredoc is one apostrophe away
	# from being a different program, and the failure would look like a
	# manifest that quietly lost a row.
	python3 - "${id}" "${config}" "${ops}" "${outcome}" "${rc}" "${cap_rc}" \
		"${elapsed}" "${QUIT_AFTER_MS}" "${CAPTURE_TIMEOUT_S}" \
		"${FRAME_W}" "${FRAME_H}" "${ppm}" "${plan}" "${log}" "${mode}" <<-'PY'
			import json, os, re, sys
			(sid, config, ops, outcome, rc, cap_rc, elapsed, quit_ms, cap_to,
			 fw, fh, ppm, plan, log, mode) = sys.argv[1:16]

			# THE PAINT TICK, READ OUT OF THE CAPTURE'S OWN LOG. It is what makes
			# the settle budget auditable: `capturedAtTick` of `captureTicks` is
			# the headroom this run actually had, so a scenario drifting towards
			# the cap shows up as a shrinking number rather than as a sudden
			# `timedout`. -1 means "no such line", which is a state and not a
			# zero — a run that never painted and a run that painted on tick 0
			# must not share a value.
			def tick_of(pattern, path):
			    try:
			        with open(path) as fh:
			            for line in fh:
			                m = re.search(pattern, line)
			                if m:
			                    return int(m.group(1))
			    except OSError:
			        pass
			    return -1

			caplog = ppm + ".log"
			print(json.dumps({
			    "blankAtTick": tick_of(r"phase1 tick (\d+): output is blank", caplog),
			    "capturedAtTick": tick_of(r"phase2 tick (\d+): painted and settled",
			                              caplog),
			    "captureTicks": int(cap_to) * 4,
			    "scenario": sid,
			    "config": config,
			    "productMode": mode,
			    "ops": ops,
			    "outcome": outcome,
			    "binaryRc": int(rc),
			    "captureRc": int(cap_rc),
			    "elapsedMs": int(elapsed),
			    "quitAfterMs": int(quit_ms),
			    "captureTimeoutS": int(cap_to),
			    "frameWidth": int(fw),
			    "frameHeight": int(fh),
			    "frame": ppm if os.path.exists(ppm) else "",
			    "blank": ppm + ".blank" if os.path.exists(ppm + ".blank") else "",
			    "plan": plan if os.path.exists(plan) else "",
			    "runLog": log,
			    "captureLog": ppm + ".log",
			}))
		PY
}

# ---------------------------------------------------------------------------
# The inner pass — everything below runs INSIDE one nested sway
# ---------------------------------------------------------------------------
inside() {
	local config="$1"
	local records="${OUT}/${config}.records.jsonl"
	: >"${records}"
	local n=0
	while IFS=$'\t' read -r id ops; do
		[ -z "${id}" ] && continue
		if [ -n "${ONLY}" ] && [ "${ONLY}" != "${id}" ]; then continue; fi
		echo "--- ${config} / ${id} (ops: ${ops:-<none>}) ---"
		capture_one "${config}" "${id}" "${ops}" debug >>"${records}"
		n=$((n + 1))
	done <"${OUT}/scenarios.tsv"
	echo "${config}: ${n} scenario run(s)"

	# THE SECOND PRODUCT MODE, reaching a window through the SHIPPED BINARY.
	# `ProductMode` has two members and PLAT-16's whole point is that it is a
	# different axis from the front-end: a lane that only ever ran
	# `ct replay --ui=gpui` would be asserting that ONE of the two modes
	# reaches a window and saying nothing about the other. PLAT-23 measured
	# `ct edit --ui=gpui` reaching its own read-only report; this measures
	# whether it reaches a WINDOW, which is a different question with a
	# different answer.
	local modes="${OUT}/${config}.modes.jsonl"
	: >"${modes}"
	if [ -z "${ONLY}" ]; then
		echo "--- ${config} / edit-mode (ct edit --ui=gpui) ---"
		capture_one "${config}" "edit-mode" "" edit >>"${modes}"
	fi
}

# ONE scenario, inside whichever compositor the caller started. Used by the
# configuration probe, which varies the COMPOSITOR while holding the scenario,
# the binary and the window size fixed — the opposite axis from `inside`,
# which varies the scenario while holding the compositor fixed.
inside_one() {
	local id="$1"
	local ops=""
	while IFS=$'\t' read -r sid sops; do
		[ "${sid}" = "${CONFIG_SCENARIO}" ] && ops="${sops}"
	done <"${OUT}/scenarios.tsv"
	echo "--- ${id} / ${CONFIG_SCENARIO} (ops: ${ops:-<none>}) ---"
	capture_one "${id}" "${CONFIG_SCENARIO}" "${ops}" debug \
		>"${OUT}/${id}.records.jsonl"
}

# ---------------------------------------------------------------------------
# THE FOUR COMPOSITOR CONFIGURATIONS, RE-MEASURED RATHER THAN RE-QUOTED
# ---------------------------------------------------------------------------
#
# PLAT-19 measured four and this milestone's floor counts them, so they have to
# be four MEASUREMENTS and not four sentences about a measurement somebody else
# took. A gate whose evidence for *"Xvfb paints nothing"* is a `grep` over a
# script's comment is `Verification-Harness-Traps` §35 — a scan is only as
# strong as its subject set, and the subject set of a prose scan is prose.
#
# So each of the four is RUN HERE, with the same binary, at the same size, on
# the same scenario (`entry-shell`, the cheapest — no replay operations), and
# each writes a row into `configurations.json` saying what came back:
#
#   sway-pixman   wlroots' software renderer. This is what the capture passes
#                 above already use, because `wayland-run-test.sh` defaults to
#                 `WLR_RENDERER="${WLR_RENDERER:-pixman}"` — a detail worth
#                 stating, since every published sentence about this lane has
#                 described the default arm as "gles2".
#   sway-gles2    the same compositor with wlroots' GL renderer.
#   weston        REFUSED BY NAME. Not skipped and not silently absent: the
#                 refusal is executed and its exit status and message are
#                 recorded, because "we would refuse it" and "we refused it"
#                 are different claims and only one of them is a measurement.
#   xvfb          X11, via `xvfb-run`, captured from `Xvfb -fbdir`'s own raw
#                 framebuffer file. **AND ITS PUBLISHED ANSWER IS WRONG.** See
#                 below; this is the row that changed when it was re-taken.
#
# Each row carries the same numbers — non-NUL bytes, total bytes and the ratio,
# for the frame AND for a blank control taken from the same screen with no
# client on it — so the four are comparable on ONE quantity rather than on four
# different notions of "worked", and each is two-sided on its own.
#
# ===========================================================================
# THE XVFB ROW, RE-MEASURED 2026-09-22, AND THE PUBLISHED ANSWER IS FALSE
# ===========================================================================
#
# Every document in this campaign — PLAT-19's measurement, PLAT-37's own
# deliverable, `wayland-run-test.sh`'s header, this file's first draft and
# `nix/shells/ci-base.nix` — says the same thing about Xvfb: *"no DRI3, so wgpu
# never gets a surface: the window reaches `IsViewable` at its requested size
# and paints nothing. That is a pass-shaped failure."*
#
# **IT PAINTS.** Measured here, on this host, with the windowed shim at
# `gpui-pre 0.3.5`: the Xvfb framebuffer goes from 303 non-NUL bytes of
# 8,297,632 with no client (3.7e-05) to 5,184,303 (0.62) with
# `codetracer-gpui` running, and the frame rendered out of it is the whole
# front-end — five panes, the editor's source with line numbers, the state
# pane, the event log — at 1440x900 on the X root. `libEGL warning: DRI3
# error: Could not get DRI3 device` is still printed, exactly as recorded;
# what does not follow from it is the conclusion. wgpu falls back to a
# software Vulkan device and renders anyway.
#
# The old sentence was true of SOMETHING — an EGL/GL path that genuinely
# cannot get a surface — and was then carried forward as a statement about
# whether a window paints, across five documents, for four milestones, with
# nothing re-taking it. That is §36b's rot in its purest form: a figure no
# gate keeps is free to be wrong, and this one was.
#
# **WHAT DOES NOT CHANGE IS WHICH COMPOSITOR THE LANE USES**, and the reason
# is now the honest one rather than the inherited one: the capture path is
# `grim`, which speaks `zwlr_screencopy_manager_v1`, which is a Wayland
# protocol that does not exist on an X display. Xvfb's own `-fbdir` is a
# perfectly good reader — it is what this row uses — but it reads a raw
# framebuffer rather than a PPM, needs no compositor protocol, and exists only
# on Xvfb. sway stays the lane's compositor because of what reads it, not
# because X paints nothing.
CONFIG_SCENARIO="entry-shell"

config_row() {
	# `config_row <id> <compositor> <renderer> <ran> <refusedByName> <rc>
	#             <framePath> <blankPath> <note>`
	python3 - "$@" <<-'PY'
		import json, os, sys
		(cid, comp, renderer, ran, refused, rc, frame, blank,
		 note) = sys.argv[1:10]

		def measure(path):
		    """(non-NUL bytes, payload bytes) for a PPM or a raw framebuffer.

		    A PPM carries a three-line ASCII header and a raw `Xvfb -fbdir`
		    file carries none, so the header is stripped only when it is
		    there. The payload is what is measured either way: a bigger
		    header must not be able to look like a brighter screen.
		    """
		    if not path or not os.path.exists(path):
		        return -1, -1
		    data = open(path, "rb").read()
		    if data.startswith(b"P6"):
		        for _ in range(3):
		            nl = data.find(b"\n")
		            if nl < 0:
		                break
		            data = data[nl + 1:]
		    return len(data) - data.count(b"\x00"), len(data)

		nonnul, total = measure(frame)
		bnonnul, btotal = measure(blank)
		print(json.dumps({
		    "id": cid,
		    "compositor": comp,
		    "renderer": renderer,
		    "ran": ran == "1",
		    "refusedByName": refused == "1",
		    "rc": int(rc),
		    "frame": frame if frame and os.path.exists(frame) else "",
		    "blank": blank if blank and os.path.exists(blank) else "",
		    "nonNulBytes": nonnul,
		    "payloadBytes": total,
		    "nonNulRatio": (nonnul / total) if total > 0 else -1.0,
		    # THE ROW'S OWN NEGATIVE CONTROL: the same screen, the same run,
		    # with no client attached. Without it "the ratio is high" is a
		    # number with nothing on the other side of it (§7b).
		    "blankNonNulBytes": bnonnul,
		    "blankPayloadBytes": btotal,
		    "blankNonNulRatio": (bnonnul / btotal) if btotal > 0 else -1.0,
		    "note": note,
		}))
	PY
}

probe_configurations() {
	local rows="${OUT}/configurations.jsonl"
	: >"${rows}"
	use_shim windowed

	# --- the two wlroots renderers ---------------------------------------
	local renderer
	for renderer in pixman gles2; do
		local id="sway-${renderer}"
		echo "--- configuration ${id} ---"
		mkdir -p "${OUT}/${id}"
		WLR_RENDERER="${renderer}" \
			bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
			bash "${BASH_SOURCE[0]}" --inside-one "${id}" \
			>"${OUT}/${id}.probe.log" 2>&1
		local ppm="${OUT}/${id}/${CONFIG_SCENARIO}.ppm"
		# The blank control is the one `wayland-capture-frame.sh` already
		# retains beside every frame — the same output, the same run, with no
		# client attached. Reused rather than re-taken: a second spelling of
		# one control is §30.
		config_row "${id}" sway "${renderer}" 1 0 0 \
			"$([ -f "${ppm}" ] && echo "${ppm}" || echo "")" \
			"$([ -f "${ppm}.blank" ] && echo "${ppm}.blank" || echo "")" \
			"wlroots ${renderer} renderer under WLR_BACKENDS=headless" >>"${rows}"
	done

	# --- weston, refused by name -----------------------------------------
	echo "--- configuration weston (expected: refused by name) ---"
	local weston_log="${OUT}/weston-refusal.log"
	bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" --compositor weston \
		-- true >"${weston_log}" 2>&1
	local weston_rc=$?
	config_row weston weston none 0 \
		"$(grep -qi 'wl_seat' "${weston_log}" && echo 1 || echo 0)" \
		"${weston_rc}" "" "" \
		"refused before starting; see ${weston_log}" >>"${rows}"

	# --- Xvfb: a window, and — contrary to four milestones of prose — PIXELS
	echo "--- configuration xvfb ---"
	mkdir -p "${OUT}/xvfb"
	local xfb="${OUT}/xvfb/frame.fb"
	local xblank="${OUT}/xvfb/blank.fb"
	rm -f "${xfb}" "${xblank}"
	# **`Xvfb -fbdir` AND NOT `ffmpeg -f x11grab`.** Measured 2026-09-22: this
	# shell's `ffmpeg` is the default build and its `-devices` list has no
	# `x11grab` at all (`Unknown input format: 'x11grab'`), and there is no
	# `xwd` and no ImageMagick either. `-fbdir` makes the X server itself
	# mmap the screen's framebuffer to a file, which needs nothing beyond the
	# server that is already running. It must be COPIED while the server is
	# alive: Xvfb unlinks the file on exit, which is how the first attempt
	# produced an empty row and nearly recorded "no pixels" as a measurement
	# rather than as a missing one.
	#
	# `WAYLAND_DISPLAY` is UNSET inside, or GPUI would find the outer
	# compositor's socket and quietly run on Wayland while the row claimed X11.
	#
	# EVERY VALUE CROSSES INTO THE INNER SHELL AS A POSITIONAL ARGUMENT, and
	# none of them is spliced into the program text. A path or a dimension
	# pasted into a quoted script body is one apostrophe away from being a
	# different program — the same rule `capture_one` follows for its
	# manifest row — and it is also what shellcheck's SC2016 is pointing at
	# when it warns that `${FRAME_W}` does not expand inside single quotes.
	xvfb-run -a -s "-screen 0 1920x1080x24 -fbdir ${OUT}/xvfb" bash -s -- \
		"${OUT}/xvfb" "${BIN}" "${TRACE}" "${xfb}" "${xblank}" \
		"${FRAME_W}" "${FRAME_H}" \
		>"${OUT}/xvfb/probe.log" 2>&1 <<-'INNER'
			set -u
			dir="$1" bin="$2" trace="$3" frame="$4" blank="$5" w="$6" h="$7"
			unset WAYLAND_DISPLAY
			sleep 2
			# The blank control FIRST, before anything is started: the same
			# screen, the same run, no client.
			cp "${dir}/Xvfb_screen0" "${blank}"
			"${bin}" --quit-after-ms=25000 --width="${w}" --height="${h}" \
				"${trace}" >"${dir}/run.log" 2>&1 &
			child=$!
			sleep 18
			cp "${dir}/Xvfb_screen0" "${frame}"
			wait "${child}" || true
		INNER
	local xvfb_rc=$?
	config_row xvfb Xvfb software-vulkan 1 0 "${xvfb_rc}" \
		"$([ -f "${xfb}" ] && echo "${xfb}" || echo "")" \
		"$([ -f "${xblank}" ] && echo "${xblank}" || echo "")" \
		"re-measured 2026-09-22: the window PAINTS under Xvfb. libEGL still reports 'DRI3 error: Could not get DRI3 device' and wgpu falls back to a software Vulkan device and renders anyway. The published claim that it paints nothing is false on this host." \
		>>"${rows}"

	echo "configurations probed: $(wc -l <"${rows}")"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
ONLY=""
MODE="outer"
INSIDE_CONFIG=""
while [ $# -gt 0 ]; do
	case "$1" in
	--only)
		ONLY="${2:?--only needs a scenario id}"
		shift 2
		;;
	--inside)
		MODE="inside"
		INSIDE_CONFIG="${2:?--inside needs a config}"
		shift 2
		;;
	--inside-one)
		MODE="inside-one"
		INSIDE_CONFIG="${2:?--inside-one needs a configuration id}"
		shift 2
		;;
	*) fail "unknown argument '$1'" ;;
	esac
done

TRACE="${CODETRACER_PLAT37_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"
# Edit mode's subject is a WORKING TREE, so the project is a source directory
# and never a recording. `src/frontend/gpui` is this front-end's own source,
# which makes the frame self-describing and needs no fixture.
EDIT_PROJECT="${root}/src/frontend/gpui"

if [ "${MODE}" = "inside" ]; then
	inside "${INSIDE_CONFIG}"
	exit 0
fi
if [ "${MODE}" = "inside-one" ]; then
	inside_one "${INSIDE_CONFIG}"
	exit 0
fi

check_prereqs
[ -d "${TRACE}" ] || fail "the \`calc\` recording is not at ${TRACE}.
      It is produced on demand by the tui lane's fixture provider through the
      product's own \`ct record\`; run \`just test-tui\` once. It is NOT
      skipped, because a green run over no recording is worth less than a red
      one."

mkdir -p "${OUT}"

# THE SCENARIO SET, READ FROM `scenarios.json` AND NEVER LISTED HERE. Its
# `expectedScenarios` is asserted against the parsed length, so a parser that
# stopped early cannot pass — the same two-sidedness both of PLAT-35's readers
# already have.
if python3 - "${SCENARIOS}" "${OUT}/scenarios.tsv" <<'PY'; then
import json, sys
doc = json.load(open(sys.argv[1]))
scenarios = doc["scenarios"]
expected = doc["expectedScenarios"]
if len(scenarios) != expected:
    sys.exit(f"FAIL: scenarios.json declares {expected} scenarios and holds {len(scenarios)}")
kinds = set(doc["operationKinds"])
lines = []
for sc in scenarios:
    terms = []
    for op in sc["operations"]:
        kind = op["kind"]
        if kind not in kinds:
            sys.exit(f"FAIL: scenario {sc['id']} uses operation '{kind}', "
                     f"which operationKinds does not publish")
        if kind == "setBreakpoint":
            terms.append(f"{kind}@{op['line']}")
        else:
            terms.append(f"{kind}={op.get('times', 1)}")
    lines.append(f"{sc['id']}\t{','.join(terms)}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print(f"scenarios.json: {len(scenarios)} scenarios, {len(kinds)} operation kinds")
PY
	:
else
	fail "the scenario set did not parse"
fi

echo "=== the three shims, read from ${SHIM_DIR} ==="
record_shim featureless
record_shim windowed
record_shim headless

[ -x "${BIN}" ] || fail "${BIN} is not built. Run \`just build-gpui\`."

export LD_LIBRARY_PATH
LD_LIBRARY_PATH="$(runtime_ld_path)"

# ---------------------------------------------------------------------------
# The windowed captures — one nested sway per configuration, not per scenario
# ---------------------------------------------------------------------------
for config in windowed featureless; do
	echo
	echo "############ ${config} ############"
	use_shim "${config}"
	bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
		bash "${BASH_SOURCE[0]}" --inside "${config}" \
		${ONLY:+--only "${ONLY}"}
	# The inner pass writes its own records; its rc is NOT the verdict, and
	# the gate reads the manifest. A compositor that would not start is a
	# missing records file, which the merge below turns into a named failure.
	[ -f "${OUT}/${config}.records.jsonl" ] ||
		fail "the ${config} pass produced no records at all — the compositor
      did not start, or the lane died before its first scenario."
done

# ---------------------------------------------------------------------------
# The four compositor configurations, each RUN
# ---------------------------------------------------------------------------
#
# Skipped when `--only` is in force, because that flag exists to re-take ONE
# scenario in the two capture passes and this stage is about neither. The
# manifest records the skip as an empty array, and the gate reads that as a
# missing configuration set rather than as four silent passes.
if [ -z "${ONLY}" ]; then
	echo
	echo "############ the four compositor configurations ############"
	probe_configurations
else
	: >"${OUT}/configurations.jsonl"
fi

# ---------------------------------------------------------------------------
# The SECOND pixel path — `gpui-headless`, with no compositor
# ---------------------------------------------------------------------------
echo
echo "############ headless (gpui_render_to_pixels) ############"
use_shim headless
headless_out="${OUT}/headless-probe.json"
rm -f "${headless_out}"
nim c -r --hints:off --nimcache:"${root}/build/nimcache/plat37-headless" \
	-o:"${root}/build/plat37/plat37-headless-probe" \
	-d:plat37HeadlessOut="${headless_out}" \
	"${root}/ci/test/plat37_headless_probe.nim" >"${OUT}/headless-probe.log" 2>&1
headless_rc=$?
if [ ! -f "${headless_out}" ]; then
	# LOUD. A probe that produced no answer is not "the path is unavailable";
	# those are different states and the gate asserts which.
	fail "the gpui-headless probe wrote no answer (rc ${headless_rc}); see ${OUT}/headless-probe.log"
fi

# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------
if python3 - "${OUT}" "${SCENARIOS}" "${ONLY}" <<'PY'; then
import json, os, subprocess, sys

out, scenarios_path, only = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(scenarios_path))

def read_jsonl(path):
    recs = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("{"):
                recs.append(json.loads(line))
    return recs


def read_records(config):
    return read_jsonl(os.path.join(out, f"{config}.records.jsonl"))


def read_modes(config):
    path = os.path.join(out, f"{config}.modes.jsonl")
    return read_jsonl(path) if os.path.exists(path) else []

def shim(config):
    d = os.path.join(out, "shim", config)
    ldd = open(os.path.join(d, "ldd.txt")).read().splitlines()
    syms = open(os.path.join(d, "symbols.txt")).read().split()
    return {
        "config": config,
        "path": os.path.join(d, "libgpui_nim_shim.so"),
        "bytes": os.path.getsize(os.path.join(d, "libgpui_nim_shim.so")),
        # THE ARTEFACT'S OWN ANSWER about which features it was built with.
        # `sonames` rather than the raw `ldd` text so the comparison is over a
        # set and not over a store path that moves with every nixpkgs bump.
        "sonames": sorted({l.strip().split()[0] for l in ldd if l.strip()}),
        "gpuiSymbols": sorted(syms),
    }

def tool_version(argv):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        return (p.stdout + p.stderr).strip().splitlines()[0]
    except Exception as e:  # noqa: BLE001 - recorded, never swallowed
        return f"<unavailable: {e}>"

manifest = {
    "schemaVersion": 1,
    "milestone": "PLAT-37",
    "only": only,
    "expectedScenarios": doc["expectedScenarios"],
    "operationKinds": doc["operationKinds"],
    # THE HOST IS NAMED. PLAT-23's G1 requires it: "at least one
    # codetracer-gpui window opened on some host ... The host is named."
    "host": {
        "uname": tool_version(["uname", "-srm"]),
        "compositor": tool_version(["sway", "--version"]),
        "grim": tool_version(["grim", "-h"]),
        # GuiAssert pins nixpkgs b6018f87 and names NO version string for
        # either binary, so an OCR or SSIM figure is only meaningful with
        # these beside it. Recorded, never quoted from a document.
        "ffmpeg": tool_version(["ffmpeg", "-version"]),
        "tesseract": tool_version(["tesseract", "--version"]),
    },
    "shims": {c: shim(c) for c in ("featureless", "windowed", "headless")},
    # THE TWO PIXEL PATHS, LABELLED. `satisfiesG1` is the whole point of the
    # row: an off-screen RGBA buffer is a frame and is not a window.
    "pixelPaths": {
        "windowed-grim": {
            "how": "gpui_launch under --features gpui-backend on headless sway; "
                   "grim -t ppm over zwlr_screencopy_manager_v1",
            "needsCompositor": True,
            "satisfiesG1": True,
            "why": "PLAT-23's G1 asks that a window has been observed. This is one.",
        },
        "headless-render-to-pixels": {
            "how": "gpui_render_to_pixels under --features gpui-headless, over "
                   "HeadlessAppContext::with_platform + Window::render_to_image",
            "needsCompositor": False,
            "satisfiesG1": False,
            "why": "an off-screen RGBA buffer is not a window; it is the cheaper "
                   "lane for a later milestone's per-frame assertions and is "
                   "labelled per row rather than substituted for the windowed path.",
        },
    },
    "headlessProbe": json.load(open(os.path.join(out, "headless-probe.json"))),
    # THE FOUR COMPOSITOR CONFIGURATIONS, EACH RUN RATHER THAN QUOTED. Two
    # wlroots renderers, weston's refusal executed, and Xvfb read out of the X
    # server's own framebuffer — which is the row that changed when it was
    # re-taken.
    "configurations": read_jsonl(os.path.join(out, "configurations.jsonl"))
    if os.path.exists(os.path.join(out, "configurations.jsonl")) else [],
    "runs": {c: read_records(c) for c in ("windowed", "featureless")},
    "productModes": {c: read_modes(c) for c in ("windowed", "featureless")},
}

path = os.path.join(out, "manifest.json")
json.dump(manifest, open(path, "w"), indent=2, sort_keys=True)
print(f"manifest: {path}")
for c, recs in manifest["runs"].items():
    tally = {}
    for r in recs:
        tally[r["outcome"]] = tally.get(r["outcome"], 0) + 1
    print(f"  {c}: {len(recs)} run(s) {tally}")
PY
	:
else
	fail "the manifest did not assemble"
fi

echo
echo "OK: PLAT-37's captures are in ${OUT}. The GATE is"
echo "    src/frontend/gpui/tests/test_gpui_window_frame.nim — this lane"
echo "    records what happened and asserts almost nothing."
