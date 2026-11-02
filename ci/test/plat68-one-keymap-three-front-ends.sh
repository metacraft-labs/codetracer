#!/usr/bin/env bash
#
# plat68-one-keymap-three-front-ends.sh — ONE `keybindings.json` on disk,
# read by the terminal (a real pty), GPUI (the window plan) and the desktop
# (the real Electron app) in ONE run, and the three behave identically
# (Base-Keymaps-And-Layer-Stack.md §3.5: "the user configuration applies to
# all front-ends").
#
# The file carries a PANE-SCOPED row — Step Over on `Ctrl+Alt+J` only while a
# list pane has the focus (`when: listFocus`) — and removes the base's `F10`
# → Step Over with a `-command` row. Each front-end, on the `calc` recording
# from its start, answers four execution lines: at the start; after
# `Ctrl+Alt+J` in the editor (out of the row's scope: unchanged); after `F10`
# in the call trace (removed: unchanged); after `Ctrl+Alt+J` there (the
# user's row: one step).
#
#   1. the terminal and GPUI: `ci/test/plat68_one_keymap_probe.nim`, compiled
#      here, run over the file (it asserts its own two agree);
#   2. the desktop: `src/tests/gui/tests/keymaps/plat68c-shared-keybindings.
#      spec.ts`, through `scripts/plat68-desktop-keys.sh` (this checkout's
#      desktop JavaScript over the built `ct`);
#   3. the three answers compared: the same three lines on every front-end.
#
# Needs: `just build-once`, `just build-tui`, `just build-gpui`, the `calc`
# recording in test-logs/tui-fixtures (the tui lane records it), a
# replay-server (REPLAY_SERVER_BIN or the checkout's), and a display or Xvfb.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"

work="$(mktemp -d "${TMPDIR:-/tmp}/plat68-one-keymap.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat >"$work/keybindings.json" <<'JSON'
// one keymap for every front-end
[
  { "key": "ctrl+alt+j", "command": "debugger.step-over", "when": "listFocus" },
  { "key": "f10", "command": "-debugger.step-over" },
]
JSON
export PLAT68_SHARED_KEYBINDINGS="$work/keybindings.json"
export PLAT68_SHARED_RESULTS="$work/results.jsonl"
: >"$PLAT68_SHARED_RESULTS"

echo "== 1. the terminal and GPUI over $PLAT68_SHARED_KEYBINDINGS"
# The Tier-2 lane's own flags (TermAssert, TermAssertClient, libvterm).
read -r -a lane_flags <<<"$(. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
	test_lane_extra_flags tui-real-terminal)"
nim c --hints:off --warnings:off "${lane_flags[@]}" --nimcache:"$work/nimcache" \
	-o:"$work/plat68_one_keymap_probe" ci/test/plat68_one_keymap_probe.nim
"$work/plat68_one_keymap_probe"

echo "== 2. the desktop over the same file"
PLAT68_SPEC=tests/keymaps/plat68c-shared-keybindings.spec.ts \
	bash scripts/plat68-desktop-keys.sh

echo "== 3. the three answers"
python3 - "$PLAT68_SHARED_RESULTS" <<'PY'
import json, sys
answers = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {a["frontEnd"]: a for a in answers}
for a in answers:
    print("  ", json.dumps(a))
missing = {"terminal", "gpui", "desktop"} - set(by)
if missing or len(answers) != 3:
    sys.exit("FAIL: expected one answer from each front-end, got %s" % sorted(by))
fail = False
for k in ("start", "afterOutside", "afterRemoved", "afterRebound"):
    vals = {fe: by[fe][k] for fe in by}
    if len(set(vals.values())) != 1:
        print("FAIL: the front-ends disagree on %s: %s" % (k, vals))
        fail = True
    else:
        print("ok   every front-end answers %s = %s" % (k, vals["desktop"]))
d = by["desktop"]
if d["afterOutside"] != d["start"]:
    print("FAIL: Ctrl+Alt+J stepped outside its scope"); fail = True
if d["afterRemoved"] != d["start"]:
    print("FAIL: the removed F10 stepped"); fail = True
if d["afterRebound"] == d["start"]:
    print("FAIL: the user's Ctrl+Alt+J did not step"); fail = True
sys.exit(1 if fail else 0)
PY
echo "RESULT: OK — one keybindings.json, three front-ends, one behaviour"
