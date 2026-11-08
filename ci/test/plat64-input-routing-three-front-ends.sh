#!/usr/bin/env bash
#
# plat64-input-routing-three-front-ends.sh — Input-Routing-And-Keymaps.md IR-5,
# IR-3 and §5.1 on all three front-ends, over ONE `keybindings.json`: the same
# chord reaches the same operation through each front-end's own decoder, a press
# on a call row runs what its element declares, a Ctrl+press the user rebound
# follows the rebinding, and the surface that shows the chord shows the new one.
#
#   1. the terminal and GPUI: `ci/test/plat64_input_routing_probe.nim`;
#   2. the desktop: `src/tests/gui/tests/keymaps/plat64-input-routing.spec.ts`,
#      through `scripts/plat68-desktop-keys.sh`;
#   3. the three answers compared.
#
# Needs: `just build-once`, `just build-tui`, `just build-gpui`, the `calc`
# recording in test-logs/tui-fixtures, a replay-server, and a display or Xvfb.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"

work="$(mktemp -d "${TMPDIR:-/tmp}/plat64-input-routing.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat >"$work/keybindings.json" <<'JSON'
// one keymap for every front-end
[
  { "key": "ctrl+alt+j", "command": "debugger.step-over" },
  { "key": "ctrl+click", "command": "debugger.continue",
    "when": "paneKind == calltrace && elementKind == row" },
]
JSON
export PLAT64_SHARED_KEYBINDINGS="$work/keybindings.json"
export PLAT64_SHARED_RESULTS="$work/results.jsonl"
: >"$PLAT64_SHARED_RESULTS"

echo "== 1. the terminal and GPUI over $PLAT64_SHARED_KEYBINDINGS"
read -r -a lane_flags <<<"$(. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
	test_lane_extra_flags tui-real-terminal)"
nim c --hints:off --warnings:off "${lane_flags[@]}" --nimcache:"$work/nimcache" \
	-o:"$work/plat64_input_routing_probe" ci/test/plat64_input_routing_probe.nim
"$work/plat64_input_routing_probe"

echo "== 2. the desktop over the same file"
PLAT68_SPEC=tests/keymaps/plat64-input-routing.spec.ts \
	bash scripts/plat68-desktop-keys.sh

echo "== 3. the three answers"
python3 - "$PLAT64_SHARED_RESULTS" <<'PY'
import json, sys
answers = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = {a["frontEnd"]: a for a in answers}
for a in answers:
    print("  ", json.dumps(a))
missing = {"terminal", "gpui", "desktop"} - set(by)
if missing or len(answers) != 3:
    sys.exit("FAIL: expected one answer from each front-end, got %s" % sorted(by))
fail = False
for k in ("start", "afterChord"):
    vals = {fe: by[fe][k] for fe in by}
    if len(set(vals.values())) != 1:
        print("FAIL: the front-ends disagree on %s: %s" % (k, vals))
        fail = True
    else:
        print("ok   every front-end answers %s = %s" % (k, vals["desktop"]))
for fe, a in by.items():
    if a["afterChord"] == a["start"]:
        print("FAIL: %s: the user's chord did not step" % fe); fail = True
    if a["afterCtrlPress"] == a["afterChord"]:
        print("FAIL: %s: the rebound Ctrl+press did not step" % fe); fail = True
    if not a["chordShown"]:
        print("FAIL: %s: the surface does not show the user's chord" % fe); fail = True
sys.exit(1 if fail else 0)
PY
