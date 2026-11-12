#!/usr/bin/env bash
#
# input-routing-gate.sh — Input-Routing-And-Keymaps.md §9 IR-1: NO VIEW MODULE
# BINDS A CHORD OR SWITCHES ON A KEY NAME.
#
# A view decodes device input into canonical events and hands them to the
# router (§6). The router and the operation tables decide what they mean, so a
# key name in a view module is a behaviour the configuration layer cannot reach
# and the shortcut reference cannot list. Its contract suite,
# ci/test/input-routing-gate-test.sh, plants each violation in a synthetic tree
# and requires this gate to redden on it, by check name.
#
# THE CHECKS, over src/frontend/{ui,tui,gpui,viewmodel/views} minus tests:
#
#   case     a `case` over a key-shaped value with an `of "<key name>"` arm
#   compare  a key-shaped value compared with a key name or key code
#   listen   a `keydown` / `keyup` listener outside the one per window
#   click    a press handler: `onclick =` / `ondblclick =` / `oncontextmenu =`,
#            or a `click` / `dblclick` / `contextmenu` / `auxclick` listener.
#            A press on a pane's element is the pointer keymap's row,
#            performed by the front-end's procedure on the element its hit
#            test found (§5.1; the desktop's `ui/desktop_elements`), so a view
#            that handles a press itself is a behaviour no keymap can rebind.
#
# DECLARED: a decoder's job is exactly to spell key names, so the modules that
# turn a device's bytes or events into canonical names are named here and not
# scanned. Nothing else is exempt; a line carrying `ir1-gate: not a key` is a
# value that merely looks like one, with the comment saying so.
#
# THE LEDGER: ci/test/input-routing-gate-ledger.txt holds what has not moved to
# the router yet, one `<file> <check> <count>` per line. A count above its entry
# is red, and so is a count below it (lower the entry), so it can only shrink.
#
# Usage: ci/test/input-routing-gate.sh [ROOT]   (ROOT defaults to the repository)

set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

python3 -I - "${root}" <<'PY'
import collections
import os
import re
import sys

root = sys.argv[1]
SCANNED = ("src/frontend/ui", "src/frontend/tui", "src/frontend/gpui",
           "src/frontend/viewmodel/views")
DECODERS = {
    "src/frontend/gpui/app/gpui_keys.nim": "GPUI's keystroke decoder",
    "src/frontend/tui/app/input/key_check.nim": "the terminal's key-delivery check names what arrived",
    "src/frontend/tui/app/input/mouse.nim": "the terminal's SGR decoder",
    "src/frontend/tui/app/views/command_line.nim": "the command line is a text field: it takes canonical key names or bytes as text",
    "src/frontend/ui/key_router.nim": "the desktop's one listener per window",
    "src/frontend/viewmodel/views/field_keys.nim": "a focused field's keys: what Enter and Escape mean in the element that owns them",
    "src/frontend/viewmodel/views/shell_keys.nim": "the Shell pane's keys are its shell's",
    "src/frontend/viewmodel/views/keyboard_focus.nim": "the focus model: Tab order and roving composites",
    "src/frontend/viewmodel/views/isonim_activation.nim": "Enter and Space on a role=button, for every host",
}
SKIP_PARTS = ("/tests/", "/testing/", "/test_support/")

NAMES = (r"Up|Down|Left|Right|Enter|Return|Esc|Escape|Tab|Backspace|Delete|Home"
         r"|End|PageUp|PageDown|Space|Insert|Spacebar|F\d+|ArrowUp|ArrowDown"
         r"|ArrowLeft|ArrowRight|up|down|left|right|enter|return|esc|escape|tab"
         r"|backspace|delete|home|end|pageup|pagedown|space|arrowup|arrowdown"
         r"|arrowleft|arrowright|[A-Za-z]|\s")
KEY = r"(?:(?:Ctrl|Shift|Alt|Meta|Cmd|ctrl|shift|alt)\+)*(?:%s)" % NAMES
OF_ARM = re.compile(r'^\s*of\s+c?"(?:%s)"\s*(?:,\s*c?"(?:%s)"\s*)*(?::|,?\s*$)' % (KEY, KEY))
CASE = re.compile(r'^\s*(?:(?:let|var)\s.*=\s*)?case\s+(.+?)\s*$')
KEYISH = re.compile(r'(?i)(^|[\s.(])(key|keyname|keyof|token|chord|lowerkey|name|lower|k)\b|\.key\b|keyOf\(|keyCode')
COMPARE = re.compile(
    r'(?:\bkey\w*|\bname|\.key|keyOf\([^)]*\))\s*(?:==|!=)\s*c?"(?:%s)"'
    r'|(?:\bkey\w*|\.key)\s+(?:in|notin)\s+\[\s*c?"(?:%s)"'
    r'|\bkeyCode\s*(?:==|!=)|\.which\s*(?:==|!=)' % (KEY, KEY))
LISTEN = re.compile(r'''["']key(?:down|up|press)["']''')
CLICK = re.compile(r'''\bon(?:click|dblclick|contextmenu|auxclick)\s*=|["'](?:click|dblclick|contextmenu|auxclick)["']''')
FIELD_LISTEN = "KeyDownEvent"  # a field's own keys, read through `field_keys`
QUIET = "ir1-gate: not a key"

counts = collections.Counter()
where = collections.defaultdict(list)
for top in SCANNED:
    for dirpath, _, names in os.walk(os.path.join(root, top)):
        rel_dir = os.path.relpath(dirpath, root) + "/"
        if any(p in rel_dir for p in SKIP_PARTS) or rel_dir.endswith("/tests/"):
            continue
        for name in sorted(names):
            if not name.endswith(".nim") or name.startswith("test_"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if rel in DECODERS:
                continue
            stack = []
            with open(os.path.join(dirpath, name), errors="replace") as handle:
                for number, line in enumerate(handle, 1):
                    stripped = line.strip()
                    if stripped.startswith("#") or QUIET in line:
                        continue
                    indent = len(line) - len(line.lstrip())
                    opened = CASE.match(line)
                    if opened:
                        while stack and stack[-1][0] >= indent:
                            stack.pop()
                        stack.append((indent, opened.group(1)))
                    if OF_ARM.match(line):
                        while stack and stack[-1][0] > indent:
                            stack.pop()
                        if stack and KEYISH.search(stack[-1][1]):
                            counts[(rel, "case")] += 1
                            where[(rel, "case")].append(number)
                    if COMPARE.search(line):
                        counts[(rel, "compare")] += 1
                        where[(rel, "compare")].append(number)
                    if LISTEN.search(line) and "addEventListener" in line + "":
                        counts[(rel, "listen")] += 1
                        where[(rel, "listen")].append(number)
                    if CLICK.search(line):
                        counts[(rel, "click")] += 1
                        where[(rel, "click")].append(number)

ledger = {}
path = os.path.join(root, "ci/test/input-routing-gate-ledger.txt")
if os.path.exists(path):
    with open(path) as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if line:
                rel, check, count = line.split()
                ledger[(rel, check)] = int(count)

failed = 0
for key in sorted(set(counts) | set(ledger)):
    rel, check = key
    have, allowed = counts.get(key, 0), ledger.get(key, 0)
    if have > allowed:
        failed += 1
        lines = ",".join(str(n) for n in where[key][:12])
        print("FAIL  [%s] %s: %d site(s), the ledger allows %d (lines %s)"
              % (check, rel, have, allowed, lines))
    elif have < allowed:
        failed += 1
        print("FAIL  [ledger] %s %s: %d site(s) left, lower the entry from %d"
              % (rel, check, have, allowed))
total = sum(counts.values())
if failed:
    print("input-routing-gate: FAILED (%d problem(s), %d site(s) in the tree)" % (failed, total))
    sys.exit(1)
print("input-routing-gate: OK (%d site(s) in the ledger)" % total)
PY
