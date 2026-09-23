#!/usr/bin/env bash
# PLAT-44 — PLAT-34's operation sequences TYPED INTO A REAL WINDOW.
#
#   bash ci/test/plat44-sequences-window.sh        # every reachable sequence
#   bash ci/test/plat44-sequences-window.sh --inside   # internal
#
# `ci/test/plat44_sequences_plan.nim` writes the plan: each sequence a key
# reaches (24 of the thirty, measured — the six others are named in the plan
# with the step no model binds), its model, its document, its canonical keys
# and the document the keys must leave on disk. For each, this lane:
#
#   * writes the document into a fresh project and the model into a fresh
#     state directory (the `:keymap` preference the binary reads);
#   * opens `codetracer-gpui --edit` in a real window on a headless sway;
#   * waits for the window to SETTLE (two identical non-blank grabs);
#   * types the keys with ONE `wtype` process (one process per key loses
#     keys — measured, 3 of 14 delivered), then `Esc` for a modal model, then
#     `Ctrl+s`, then the F12 SENTINEL that ends the event loop;
#   * records the FILE ON DISK against the plan's expected document.
#
# THE VERDICT IS THE FILES AND THE CARETS: the file on disk against the plan's
# document, and the caret the binary reports at exit (`--frame-report`)
# against the plan's — a motion-only sequence leaves the file unchanged, so
# the file alone would pass it for doing nothing. The lane's NEGATIVE TWIN is
# the first sequence whose last key the plan shows to matter, typed again
# without it, which must NOT reproduce the expected state — the proof that
# the comparison can fail at all (§4).
# `ci/test/plat44_sequences_window_record.py` turns the run into the
# committed `src/tests/visual/plat44-sequences-window.json`, and
# `test_plat44_sequences_window.nim` asserts over that.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1
WS="$(cd "${root}/.." && pwd)"
ISONIM_GPUI="${WS}/isonim-gpui"
OUT="${root}/build/plat44-sequences"
PLAN="${OUT}/plan.json"
BIN="${CODETRACER_PLAT44_BIN:-${root}/build/bin/codetracer-gpui}"
FRAME_W=1440
FRAME_H=900
KEY_GAP_MS=200
POLL_S=2
STABLE_GRABS=2
SETTLE_MAX_S=120
QUIT_AFTER_MS=180000
SENTINEL="f12"
INSIDE=0
[ "${1:-}" = "--inside" ] && INSIDE=1

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

settle() {
	# Two consecutive identical non-blank grabs, or the budget.
	local dir="$1" prev="$1/prev.ppm" cur="$1/cur.ppm" same=0 waited=0
	while [ "${waited}" -lt "${SETTLE_MAX_S}" ]; do
		sleep "${POLL_S}"
		waited=$((waited + POLL_S))
		grim -t ppm "${cur}" >/dev/null 2>&1 || continue
		if [ -f "${prev}" ] && cmp -s "${prev}" "${cur}"; then
			same=$((same + 1))
		else
			same=0
		fi
		mv "${cur}" "${prev}"
		if [ "${same}" -ge "${STABLE_GRABS}" ] && python3 - "${prev}" <<'PY'; then
import sys
d = open(sys.argv[1], "rb").read()
raster = d.split(b"\n", 3)[3]
sys.exit(0 if max(raster[::97]) > 40 else 1)
PY
			rm -f "${prev}"
			echo "${waited}"
			return 0
		fi
	done
	rm -f "${prev}" "${cur}"
	echo "-1"
}

one() {
	# $1 = run id, $2 = sequence index in the plan, $3 = keys to drop from
	# the end (0, or 1 for the negative twin).
	local id="$1" index="$2" drop="$3"
	local dir="${OUT}/runs/${id}"
	mkdir -p "${dir}/project" "${dir}/state"
	python3 - "${PLAN}" "${index}" "${drop}" "${dir}" "${KEY_GAP_MS}" <<'PY'
import json, sys
plan, index, drop, out, gap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
s = json.load(open(plan))["sequences"][index]
open(out + "/project/doc.txt", "w").write(s["doc"])
open(out + "/state/keymap", "w").write(s["model"] + "\n")
keys = s["keys"][:len(s["keys"]) - drop] if drop else s["keys"]
NAMED = {"Down": "Down", "Up": "Up", "Left": "Left", "Right": "Right",
         "Home": "Home", "End": "End", "PageUp": "Prior", "PageDown": "Next",
         "Enter": "Return", "Esc": "Escape", "Backspace": "BackSpace",
         "Delete": "Delete", "Tab": "Tab", "Space": "space"}
MODS = {"Ctrl": "ctrl", "Alt": "alt", "Shift": "shift"}
# PRIME THE VIRTUAL KEYBOARD. Measured on the first run of this lane: in
# about a third of the windows the FIRST key never reached the editor (the
# exit report's `keysApplied` one short, the caret one motion behind) — a new
# `wtype` virtual keyboard can lose its first key while the compositor is
# still sending the client its keymap. A bare Shift press and release is the
# priming: it reaches the editor as no text and no motion in any model.
args = ["-M", "shift", "-m", "shift", "-s", "500"]
for k in keys:
    parts = k.split("+") if k not in ("+",) else ["+"]
    if k.endswith("++"):
        parts = k[:-2].split("+") + ["+"]
    mods, base = parts[:-1], parts[-1]
    for m in mods:
        args += ["-M", MODS[m]]
    if base in NAMED:
        args += ["-k", NAMED[base]]
    elif base.startswith("-"):
        # A text argument starting with `-` would be read as an option.
        args += ["-k", "minus"] if base == "-" else ["--", base]
    else:
        args += [base]
    for m in reversed(mods):
        args += ["-m", MODS[m]]
    args += ["-s", gap]
# Leave a modal model's insert mode (Esc changes no text), save, end.
if s["modal"]:
    args += ["-k", "Escape", "-s", gap]
args += ["-M", "ctrl", "s", "-m", "ctrl", "-s", "1500", "-k", "F12"]
open(out + "/wtype.args", "w").write("\0".join(args))
json.dump({"id": s["id"], "model": s["model"], "expected": s["expected"],
           "expectedCaretLine": s["expectedCaretLine"],
           "expectedCaretColumn": s["expectedCaretColumn"],
           "keys": keys, "dropped": drop}, open(out + "/meta.json", "w"))
PY
	local started ended rc waited
	started=$(date +%s%3N)
	CODETRACER_GPUI_PROBE_SENTINEL="${SENTINEL}" \
		CODETRACER_TUI_LAYOUT_DIR="${dir}/state" \
		LD_LIBRARY_PATH="${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:${LD_LIBRARY_PATH:-}" \
		"${BIN}" --edit "--quit-after-ms=${QUIT_AFTER_MS}" \
		"--frame-report=${dir}/report.json" \
		"--width=${FRAME_W}" "--height=${FRAME_H}" "${dir}/project" \
		>"${dir}/run.log" 2>&1 &
	local app=$!
	waited="$(settle "${dir}")"
	if [ "${waited}" -ge 0 ] 2>/dev/null; then
		xargs -0 wtype <"${dir}/wtype.args" >"${dir}/wtype.log" 2>&1
	fi
	wait "${app}"
	rc=$?
	ended=$(date +%s%3N)
	python3 - "${dir}" "${rc}" "$((ended - started))" "${QUIT_AFTER_MS}" \
		"${waited}" <<'PY' >>"${OUT}/runs.jsonl"
import json, os, sys
d, rc, elapsed, deadline, waited = sys.argv[1:6]
meta = json.load(open(d + "/meta.json"))
path = d + "/project/doc.txt"
report = {}
if os.path.exists(d + "/report.json"):
    report = json.load(open(d + "/report.json"))
meta.update({"caretLine": report.get("caretLine", -1),
             "caretColumn": report.get("caretColumn", -1),
             "keysApplied": report.get("keysApplied", -1)})
meta.update({"rc": int(rc), "elapsedMs": int(elapsed),
             "endedOnDeadline": int(elapsed) >= int(deadline) - 500,
             "settledAfterS": int(waited),
             "onDisk": open(path).read() if os.path.exists(path) else None})
print(json.dumps(meta))
PY
	echo "  ${id}: rc=${rc} settled=${waited}s"
}

inside() {
	rm -rf "${OUT}/runs" "${OUT}/runs.jsonl"
	mkdir -p "${OUT}/runs"
	local n
	n="$(python3 -c "import json; print(len(json.load(open('${PLAN}'))['sequences']))")"
	for ((i = 0; i < n; i++)); do
		one "seq-${i}" "${i}" 0
	done
	# THE NEGATIVE TWIN: the first sequence whose LAST key the plan shows
	# changes the document or the caret, typed without it.
	local twin
	twin="$(python3 -c "import json; s=json.load(open('${PLAN}'))['sequences']; print(next(i for i, x in enumerate(s) if x['lastKeyMatters']))")"
	one "twin-${twin}" "${twin}" 1
}

if [ "${INSIDE}" = "1" ]; then
	inside
	exit $?
fi

[ -f "${PLAN}" ] || fail "no plan at ${PLAN} — \`just plat44-sequences-plan\` first"
[ -x "${BIN}" ] || fail "${BIN} is not built"
for tool in sway wayland-info wtype grim python3; do
	command -v "${tool}" >/dev/null 2>&1 || fail "'${tool}' is not on PATH"
done
[ "${CODETRACER_WINDOW_BIN_PINS_SHIM:-0}" = "1" ] ||
	fail "this lane needs a binary built with -d:gpuiShimPath=<windowed shim>
      (CODETRACER_WINDOW_BIN_PINS_SHIM=1); it does not swap the shared shim."
bash "${ISONIM_GPUI}/scripts/wayland-run-test.sh" -- \
	bash "${root}/ci/test/plat44-sequences-window.sh" --inside
rc=$?
echo "plat44-sequences-window: rc=${rc}"
exit "${rc}"
