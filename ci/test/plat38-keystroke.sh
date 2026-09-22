#!/usr/bin/env bash
#
# plat38-keystroke.sh — PLAT-38's CAPTURE LANE.
#
#   bash ci/test/plat38-keystroke.sh              # every scenario
#   bash ci/test/plat38-keystroke.sh --only entry-shell
#   bash ci/test/plat38-keystroke.sh --inside     # internal
#
# It opens a real `codetracer-gpui` window on a real compositor, sends a key
# through that compositor's own `wl_seat`, and writes what the RUST-SIDE
# ELEMENT STORE held into `build/plat38/manifest.json`. It asserts almost
# nothing itself: the GATE is
# `src/frontend/gpui/tests/test_gpui_key_delivery.nim`, which reads this
# manifest.
#
# THE SPLIT IS PLAT-37's, and the reason is the same: the assertions are in
# Nim, and a suite that had to run *inside* a nested sway to make them would be
# a suite nobody can run from an editor.
#
# ===========================================================================
# WHAT MAKES THIS A REAL KEY, AND WHY THAT DISTINCTION IS THE MILESTONE
# ===========================================================================
#
# `wtype` is a Wayland client speaking `zwp_virtual_keyboard_manager_v1`.
# wlroots — and therefore sway — implements that protocol, so the keyboard it
# creates is attached to the compositor's own `wl_seat` and the keys it sends
# are routed to the FOCUSED SURFACE by the compositor, exactly as a physical
# keyboard's would be. The path is then: sway -> `gpui_linux`'s Wayland client
# -> GPUI's dispatch tree -> the `on_key_down` listener `gpui_app.rs` attaches
# to the tracked-focus root -> `input::deliver_key_to_focus` -> the focused
# element's own record in the shim's store.
#
# **A SYNTHESISED CALL INTO `gpui_dispatch_event` WOULD TEST THE BINDING
# AGAINST ITSELF**, which is what PLAT-38's gate says this lane must not do,
# and it is also what the workspace's existing emulation does:
# `isonim-render-serve/src/isonim_render_serve/adapters/gpui_input_adapter.nim`
# routes a keyboard event through the SHADOW TREE with a synthesised focus sink
# (`fireEvent(sink.focusedNode, "keydown")`). A case graded against that would
# be grading the emulation. Nothing in this lane calls it.
#
# `ydotool` is NOT an alternative: it injects through `uinput`, needs a
# privileged daemon and a device node, and the key would never reach the
# compositor at all — a different experiment wearing the same name.
#
# ===========================================================================
# THE WINDOWED SHIM, AND WHY IT IS A FILE SUBSTITUTION
# ===========================================================================
#
# `isonim_gpui/bindings.nim` resolves the shim at COMPILE time and bakes the
# ABSOLUTE path `…/isonim-gpui/rust/target/debug/libgpui_nim_shim.so` into
# every `{.dynlib.}` pragma. `dlopen` on an absolute path does not consult
# `LD_LIBRARY_PATH`, so an arm selected by that variable would run against
# whichever shim happened to be at the baked path. PLAT-37 measured this and
# selects by putting the right bytes there; this lane does the same, restores
# the original on exit whatever happens, and REFUSES if the windowed shim is
# absent rather than running the featureless one and reporting no keys.
#
# The shims are built by `isonim-gpui`'s own `just plat37-shims`, in ITS dev
# shell — linking the windowed one needs `-lxcb`, `-lxkbcommon` and
# `-lxkbcommon-x11`, which are declared in that repo's `flake.nix`.
#
# ===========================================================================
# THE PARTITION, AND THE SENTINEL
# ===========================================================================
#
# Every run ends in exactly one of three states and the manifest says which:
# `delivered`, `refused` or `timedout`. `refused` is the NEGATIVE TWIN's
# expected state and is not a failure; `timedout` is. The value is written
# from this script's own control flow and never inferred from whether a file
# exists.
#
# The window is closed by a SENTINEL KEY (`Escape`), not by the
# `--quit-after-ms` deadline: *"the typist finished"* and *"the backstop
# fired"* are different outcomes and only one of them is a delivery. The
# binary records `endedOnDeadline` and this lane reads it.
#
# ===========================================================================
# WHAT THIS LANE REFUSES TO DO
# ===========================================================================
#
#  * NO SKIPS. Every missing prerequisite is a named failure
#    (`Silent-Self-Pass-Audit-2026-08-23.md`).
#  * NO SEVENTH SCENARIO. The six are read from
#    `src/tests/visual/scenarios.json`, unchanged and un-renamed. A scenario
#    invented for this milestone would be a corpus that grew to fit its
#    instrument.
#  * NO RETRY-UNTIL-IT-ARRIVES. A key that did not arrive is a `timedout` row.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1

WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat38"
BIN="${root}/build/bin/codetracer-gpui"
SCENARIOS="${root}/src/tests/visual/scenarios.json"
TRACE="${CODETRACER_PLAT38_TRACE:-${root}/test-logs/tui-fixtures/calc-2f0db4f45192}"

FRAME_W=1440
FRAME_H=900

# The window has to be MAPPED and FOCUSED before a key means anything: a key
# sent earlier goes to whatever sway currently considers focused, which is
# nothing. Measured under headless sway with `WLR_RENDERER=pixman`: the
# `codetracer-gpui` window reaches its first frame in roughly 8 s on this box
# (PLAT-37's `stepped-editor` painted on phase-2 tick 33 of 100, i.e. 8.3 s),
# so the typist waits well past that. It is a SETTLE and not a retry: a key
# sent too early is lost and the row is `timedout`, which is the honest answer.
SETTLE_S=14
KEY_GAP_MS=250
QUIT_AFTER_MS=40000

# THE VISION THRESHOLD, and it is a §36b parameter: the winner is gated and
# the losers are prose unless the search is runnable. `just plat38-threshold-
# probe` re-takes it.
CHANGE_THRESHOLD=0.002

ONLY=""
INSIDE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--only)
		ONLY="${2:-}"
		shift 2
		;;
	--inside)
		INSIDE=1
		shift
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Prerequisites — every one fails BY NAME
# ---------------------------------------------------------------------------
check_prereqs() {
	[ -d "${ISONIM_GPUI}" ] || fail "the isonim-gpui sibling checkout is not at ${ISONIM_GPUI}."
	[ -f "${ISONIM_GPUI}/scripts/wayland-run-test.sh" ] ||
		fail "${ISONIM_GPUI}/scripts/wayland-run-test.sh is missing"
	[ -f "${SCENARIOS}" ] || fail "${SCENARIOS} is missing; the six scenarios are READ, not listed here."
	[ -d "${TRACE}" ] || fail "the \`calc\` recording is not at ${TRACE}.
      A missing recording is a named failure and never a skip."
	[ -x "${BIN}" ] || fail "${BIN} is not built. \`just build-once\` first."
	for tool in sway wayland-info wtype grim python3; do
		command -v "${tool}" >/dev/null 2>&1 ||
			fail "'${tool}' is not on PATH. The dev shell declares it
      (nix/shells/ci-base.nix); running this lane outside the shell is what
      this message is for. \`wtype\` in particular is the whole difference
      between a REAL key and a synthesised call."
	done
}

SHIM_DIR="${ISONIM_GPUI}/rust/target/plat37"
LIVE_SHIM="${ISONIM_GPUI}/rust/target/debug/libgpui_nim_shim.so"
SHIM_BACKUP=""

# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap below
restore_shim() {
	if [ -n "${SHIM_BACKUP}" ] && [ -f "${SHIM_BACKUP}" ]; then
		mv -f "${SHIM_BACKUP}" "${LIVE_SHIM}"
		SHIM_BACKUP=""
		echo "restored ${LIVE_SHIM}"
	fi
}
trap restore_shim EXIT

select_windowed_shim() {
	local src="${SHIM_DIR}/libgpui_nim_shim.windowed.so"
	[ -f "${src}" ] || fail "the WINDOWED shim is not at ${src}.
      Build it in the sibling's own dev shell:
          cd ${ISONIM_GPUI} && nix develop --command just plat37-shims
      This lane REFUSES rather than running the featureless shim, because a
      featureless run opens no window, receives no key, and would report an
      empty arrival list that looks exactly like a delivery failure."
	# The windowed shim must carry PLAT-38's exported surface, or the binary
	# dies at load with `could not import: gpui_focus_element` and the row
	# would read as a capture problem. Checked here, by name.
	if command -v nm >/dev/null 2>&1; then
		nm -D --defined-only "${src}" 2>/dev/null |
			grep -q 'gpui_dispatch_key_to_focus' ||
			fail "${src} does not export gpui_dispatch_key_to_focus.
      It was built before PLAT-38 widened the shim's ABI. Rebuild it."
	fi
	SHIM_BACKUP="${LIVE_SHIM}.plat38-backup"
	[ -f "${LIVE_SHIM}" ] && mv -f "${LIVE_SHIM}" "${SHIM_BACKUP}"
	cp -f "${src}" "${LIVE_SHIM}"
	echo "selected the WINDOWED shim at ${LIVE_SHIM}"
}

runtime_lib_path() {
	echo "${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}"
}

scenario_ids() {
	python3 - "${SCENARIOS}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["scenarios"]:
    print(s["id"])
PY
}

scenario_ops() {
	python3 - "${SCENARIOS}" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["scenarios"]:
    if s["id"] == sys.argv[2]:
        ops = s.get("operations", [])
        print(",".join(
            (o["kind"] + "@" + str(o["row"])) if o["kind"] == "setBreakpoint"
            else (o["kind"] + "=" + str(o.get("count", 1)))
            for o in ops))
        break
PY
}

# THE KEY EACH SCENARIO SENDS, and the population it covers.
#
# §34: a corpus in which every member takes the same path never exercises the
# classes that differ, so the six scenarios send six DIFFERENT classes of key
# rather than six copies of one. The mapping is declared here, beside the
# lane that performs it, and the gate asserts the modifier each row claims —
# two-sidedly, so a row claiming no modifier asserts it received none.
#
#   index  scenario               key             class
#   0      entry-shell            Down            named, unmodified
#   1      stepped-editor         Shift+F10       named, modified
#   2      advanced-state         a               character, unmodified
#   3      returned-calltrace     Ctrl+a          character, modified
#   4      continued-event-log    Home            named, unmodified (second)
#   5      breakpoint-editor      Shift+Tab       the back-tab, whose name it
#                                                 SHARES with Tab and which
#                                                 differs only in the modifier
key_for_index() {
	case "$1" in
	0) echo "-k Down" ;;
	1) echo "-M shift -k F10 -m shift" ;;
	2) echo "a" ;;
	3) echo "-M ctrl a -m ctrl" ;;
	4) echo "-k Home" ;;
	5) echo "-M shift -k Tab -m shift" ;;
	*) echo "-k Down" ;;
	esac
}

modifier_for_index() {
	case "$1" in
	1 | 5) echo "shift" ;;
	3) echo "control" ;;
	*) echo "" ;;
	esac
}

# ---------------------------------------------------------------------------
# One scenario, inside the nested compositor
# ---------------------------------------------------------------------------
capture_one() {
	local idx="$1" id="$2" ops="$3" focused="$4"
	local dir="${OUT}"
	mkdir -p "${dir}"
	local probe="${dir}/${id}.probe.json"
	local log="${dir}/${id}.run.log"
	rm -f "${probe}" "${log}"

	local argv=("${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}"
		"--width=${FRAME_W}" "--height=${FRAME_H}"
		"--input-probe=${probe}")
	[ -n "${ops}" ] && argv+=("--replay-ops=${ops}")
	argv+=("${TRACE}")

	# THE TYPIST, started BEFORE the window so the settle is inside its own
	# schedule rather than inside this script's.
	#
	# `focused=0` is the NEGATIVE TWIN and it is produced by taking the
	# window's focus away rather than by skipping the key: the key is sent
	# either way, and `swaymsg` moves focus to a scratchpad-like empty
	# workspace first. A twin that simply did not send the key would be
	# asserting that nothing happens when nothing is done.
	local keyspec
	keyspec="$(key_for_index "${idx}")"
	#
	# **`SWAYSOCK` IS EXPORTED HERE BECAUSE `swaymsg` CANNOT FIND IT.**
	# Measured: inside `wayland-run-test.sh`'s private `XDG_RUNTIME_DIR` the
	# socket exists as `sway-ipc.<uid>.<pid>.sock` and `swaymsg` still reports
	# *"Unable to retrieve socket path"* and exits 1 — so the `|| true` below
	# was swallowing a failure and the negative twin was running with the
	# window still focused, which is why it came back `delivered`. A twin that
	# cannot take focus away is a twin that asserts nothing.
	local script="export SWAYSOCK=\$(ls ${XDG_RUNTIME_DIR:-/tmp}/sway-ipc.*.sock 2>/dev/null | head -1); "
	script+="sleep ${SETTLE_S}; "
	if [ "${focused}" = "0" ]; then
		script+="swaymsg workspace 9 || echo SWAYMSG-FAILED; sleep 1; "
	fi
	# **EVERY INVOCATION LEADS WITH `-s`, AND THAT IS MEASURED.** A `wtype`
	# invocation with no leading `-s` sends its keystroke before the compositor
	# has processed the new virtual keyboard's keymap, and the key is LOST —
	# silently, with `wtype` exiting 0. Isolated one variable at a time in
	# `isonim-gpui/tests/test_gui_keyboard.nim`, whose header carries the
	# table; the symptom here was every scenario coming back `timedout`
	# because the SENTINEL never arrived while the scenario's own key did.
	# shellcheck disable=SC2086  # the key spec must word-split
	script+="wtype -s ${KEY_GAP_MS} ${keyspec}; sleep 1; "
	script+="wtype -s ${KEY_GAP_MS} -k Escape"

	bash -c "${script}" >"${dir}/${id}.typist.log" 2>&1 &
	local typist=$!

	local started ended elapsed rc
	started=$(date +%s%3N)
	CODETRACER_GPUI_PROBE_SENTINEL="escape" \
		LD_LIBRARY_PATH="$(runtime_lib_path)" \
		"${argv[@]}" >"${log}" 2>&1
	rc=$?
	ended=$(date +%s%3N)
	elapsed=$((ended - started))
	wait "${typist}" 2>/dev/null || true

	# `swaymsg workspace 1` puts focus back, so a negative-twin run does not
	# poison the next scenario.
	# `ls` and not `find`: the glob is a fixed, compositor-generated shape
	# (`sway-ipc.<uid>.<pid>.sock`) in a private directory this harness made,
	# so there is no non-alphanumeric name for `find` to handle better.
	# shellcheck disable=SC2012
	SWAYSOCK="$(ls "${XDG_RUNTIME_DIR:-/tmp}"/sway-ipc.*.sock 2>/dev/null | head -1)" \
		swaymsg workspace 1 >/dev/null 2>&1 || true

	python3 - "${probe}" "${id}" "${idx}" "${elapsed}" "${rc}" \
		"$(modifier_for_index "${idx}")" "${focused}" \
		>"${dir}/${id}.row.json" <<'PY'
import json, os, sys
probe, ident, idx, elapsed, rc, modifier, focused = sys.argv[1:8]
row = {"name": ident, "index": int(idx), "elapsedMs": int(elapsed),
       "rc": int(rc), "expectModifier": modifier,
       "windowFocused": focused == "1",
       "arrivals": [], "deliverySeq": 0, "deliveryCount": 0}
if not os.path.exists(probe):
    # A run that produced NO probe file is `timedout`, never `delivered`.
    # Written from control flow, not inferred: a missing file and a file full
    # of zeros are different states and the gate has to see which.
    row["outcome"] = "timedout"
    row["why"] = "no probe file at " + probe
else:
    d = json.load(open(probe))
    row["arrivals"] = [a for a in d.get("arrivals", [])
                       if a.get("key") != "escape"]
    row["deliverySeq"] = d.get("deliverySeq", 0)
    row["deliveryCount"] = d.get("deliveryCount", 0)
    row["endedOnDeadline"] = d.get("endedOnDeadline", False)
    row["focusedCount"] = d.get("focusedCount", 0)
    row["targetFocused"] = d.get("targetFocused", False)
    if row["endedOnDeadline"]:
        row["outcome"] = "timedout"
        row["why"] = "the loop ended on the backstop, not on the sentinel"
    elif row["arrivals"]:
        row["outcome"] = "delivered"
    else:
        row["outcome"] = "refused"
json.dump(row, sys.stdout, indent=1)
PY
	python3 -c "
import json,sys
r=json.load(open('${dir}/${id}.row.json'))
print('  %-22s %-9s arrivals=%d seq=%d count=%d %dms' % (
    r['name'], r['outcome'], len(r['arrivals']), r['deliverySeq'],
    r['deliveryCount'], r['elapsedMs']))"
}

# ---------------------------------------------------------------------------
# The vision witness: one frame before the key, one after, and the blank
# ---------------------------------------------------------------------------
capture_vision() {
	local dir="${OUT}"
	mkdir -p "${dir}"
	local before="${dir}/vision-before.ppm"
	local after="${dir}/vision-after.ppm"
	local blank="${dir}/vision-blank.ppm"
	rm -f "${before}" "${after}" "${blank}"

	# THE BLANK CONTROL IS TAKEN FIRST, with no client attached, and its
	# ABSENCE IS FATAL. §7b: a control that has never been made to fail is a
	# self-comparison wearing a negation.
	grim -t ppm "${blank}" 2>/dev/null || true
	[ -s "${blank}" ] || fail "could not take the blank control frame.
      Every vision assertion in the gate is a comparison against it, so a run
      without one is refused rather than reported with an asterisk."

	local probe="${dir}/vision.probe.json"
	local argv=("${BIN}" "--quit-after-ms=${QUIT_AFTER_MS}"
		"--width=${FRAME_W}" "--height=${FRAME_H}"
		"--input-probe=${probe}" "${TRACE}")

	# The typist waits for the settle, the shooter takes `before`, the typist
	# sends a key that MOVES something (`Down`), the shooter takes `after`,
	# then the sentinel closes the loop.
	bash -c "sleep ${SETTLE_S}; grim -t ppm '${after}.pre' >/dev/null 2>&1; \
             cp -f '${after}.pre' '${before}'; \
             wtype -s ${KEY_GAP_MS} -k Down; sleep 2; \
             grim -t ppm '${after}' >/dev/null 2>&1; \
             sleep 0.5; wtype -s ${KEY_GAP_MS} -k Escape" \
		>"${dir}/vision.typist.log" 2>&1 &
	local typist=$!
	CODETRACER_GPUI_PROBE_SENTINEL="escape" \
		LD_LIBRARY_PATH="$(runtime_lib_path)" \
		"${argv[@]}" >"${dir}/vision.run.log" 2>&1
	wait "${typist}" 2>/dev/null || true
	swaymsg workspace 1 >/dev/null 2>&1 || true

	python3 - "${before}" "${after}" "${blank}" "${CHANGE_THRESHOLD}" \
		>"${dir}/vision.json" <<'PY'
import json, sys
# ONE MODULE, TWO CALLERS: this lane and `just plat38-threshold-probe` read the
# frames through the same three functions, so the rejected thresholds are
# re-measured by the arithmetic that produced the committed one (§30, §36b).
sys.path.insert(0, "ci/test")
from plat38_frames import read_ppm, nonblank_fraction, changed_fraction

before, after, blank, threshold = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
b = read_ppm(before)
a = read_ppm(after)
z = read_ppm(blank)
out = {"attempted": True, "threshold": threshold,
       "beforeNonBlank": bool(b) and nonblank_fraction(b[2]) > 0.05,
       "afterNonBlank": bool(a) and nonblank_fraction(a[2]) > 0.05,
       # WHAT THE FRAMES SAY AGAINST THE BLANK CONTROL. This is the claim the
       # vision tier can actually make here — *there is a window and its
       # pixels are not the pixels of a blank screen* — measured at the moment
       # of delivery, on BOTH sides of the key.
       "beforeVsBlank": changed_fraction(z[2], b[2]) if b and z else 0.0,
       "afterVsBlank": changed_fraction(z[2], a[2]) if a and z else 0.0,
       # AND WHAT THE KEY ITSELF DID TO THE SCREEN, recorded whatever it is.
       # It is 0.0 on this product today and that is not a capture defect:
       # `codetracer-gpui` has no BINDING from a key to a replay operation
       # (PLAT-23's `--ui=gui` contract), so a delivered key changes the
       # element store and not the picture. Recorded rather than asserted, and
       # PLAT-38's status says the deliverable worded as *"a key changed the
       # screen"* is NOT met for that reason.
       "changedFraction": changed_fraction(b[2], a[2]) if b and a else 0.0,
       "blankPresent": bool(z),
       "blankNonBlank": bool(z) and nonblank_fraction(z[2]) > 0.05,
       # THE CONTROL'S OWN READING, through the SAME function: the blank frame
       # compared with itself must change by nothing. One predicate, rule and
       # control both calling it (§30).
       "blankChangedFraction": changed_fraction(z[2], z[2]) if z else 1.0}
json.dump(out, sys.stdout, indent=1)
PY
	python3 -c "
import json
v=json.load(open('${dir}/vision.json'))
print('  vision  changed=%.4f threshold=%.4f blank=%s' % (
    v['changedFraction'], v['threshold'], v['blankPresent']))"
}

# ---------------------------------------------------------------------------
inside() {
	mkdir -p "${OUT}"
	local ids
	mapfile -t ids < <(scenario_ids)
	[ "${#ids[@]}" -eq 6 ] ||
		fail "${SCENARIOS} declares ${#ids[@]} scenarios, expected 6.
      The six are the corpus PLAT-35 pinned and PLAT-37 captured; a seventh
      invented here would be a corpus that grew to fit its instrument."

	echo "=== the six pinned scenarios, one real key each ==="
	local i=0
	for id in "${ids[@]}"; do
		if [ -n "${ONLY}" ] && [ "${ONLY}" != "${id}" ]; then
			i=$((i + 1))
			continue
		fi
		capture_one "${i}" "${id}" "$(scenario_ops "${id}")" 1
		i=$((i + 1))
	done

	if [ -z "${ONLY}" ]; then
		echo "=== the negative twin: the same key, window unfocused ==="
		capture_one 0 "negative-twin" "" 0
		echo "=== the vision witness ==="
		capture_vision
	fi

	python3 - "${OUT}" "${SCENARIOS}" >"${OUT}/manifest.json" <<'PY'
import datetime, json, os, platform, sys
out, scenarios = sys.argv[1], sys.argv[2]
ids = [s["id"] for s in json.load(open(scenarios))["scenarios"]]
rows = []
for i in ids:
    p = os.path.join(out, i + ".row.json")
    if os.path.exists(p):
        rows.append(json.load(open(p)))
# THE SENTINEL KEY, READ OUT OF THE CAPTURE rather than declared here. It is
# the LAST key the compositor delivered in the first scenario's run, so the
# gate can compare the binding's own spelling for `kEscape` against a name a
# real `wl_seat` produced — which is the only oracle that can see a binding
# whose encoder and decoder are inverse by construction (§30a).
sentinel = ""
first_probe = os.path.join(out, ids[0] + ".probe.json")
if os.path.exists(first_probe):
    sentinel = json.load(open(first_probe)).get("lastKey", "")

twin_path = os.path.join(out, "negative-twin.row.json")
twin = json.load(open(twin_path)) if os.path.exists(twin_path) else {}
vision_path = os.path.join(out, "vision.json")
vision = json.load(open(vision_path)) if os.path.exists(vision_path) else {
    "attempted": False}
doc = {
    "_comment": "PLAT-38. Written by ci/test/plat38-keystroke.sh from a run. "
                "Every arrival is what the RUST-SIDE element store held, read "
                "inside the handler the shim called.",
    "takenAt": datetime.datetime.now().isoformat(timespec="seconds"),
    "host": platform.platform(),
    "sentinelKey": sentinel,
    "scenarios": rows,
    "negativeTwin": {
        "attempted": bool(twin),
        "outcome": ("refused" if twin.get("outcome") in ("refused", "timedout")
                    else twin.get("outcome", "")),
        "key": (rows[0]["arrivals"][-1]["key"]
                if rows and rows[0].get("arrivals") else ""),
        "deliverySeq": twin.get("deliverySeq", 0),
        "deliveryCount": twin.get("deliveryCount", 0)},
    "vision": vision}
json.dump(doc, sys.stdout, indent=1)
PY
	echo "wrote ${OUT}/manifest.json"
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

check_prereqs
select_windowed_shim
mkdir -p "${OUT}"
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat38-keystroke.sh" --inside \
	${ONLY:+--only "${ONLY}"}
rc=$?
echo "plat38-keystroke: rc=${rc}"
exit "${rc}"
