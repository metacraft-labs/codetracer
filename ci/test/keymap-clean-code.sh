#!/usr/bin/env bash
#
# keymap-clean-code.sh — the mechanical half of Base-Keymaps-And-Layer-Stack.md
# §8 ("Clean code") and §9 KL-10: ONE RESOLVER, ONE KEY DECODER PER DEVICE,
# ONE MODIFIER ORDER, BASES AS DATA, NO BEHAVIOUR IN A BINDING, ONE OWNER PER
# MODULE.
#
# The user, 2026-10-09: "You need to aim for a very clean code as discussed
# previously." §8 turns that into eight checkable items and says each has a
# mechanical check; this is the source-level one for items 1-4 and 6 (item 5,
# no hidden mode state, is the router's API and is held by test_plat68_layers;
# items 7 and 8 are the deletions and the no-mocks rule, held by the
# reachability ratchet and by every suite's header). Its contract suite,
# ci/test/keymap-clean-code-test.sh, plants each violation in a synthetic tree
# and requires this gate to redden on it, by check name — a gate nobody has
# watched fail is not evidence.
#
# THE CHECKS
#
#   1  ONE RESOLVER. A routine RESOLVES KEYS if it walks a binding trie
#      (calls `nodeAfter(`, or reads a trie node's `.children[` /
#      `.children.hasKey(` in a module that names `EditingTrie` / `TrieNode`,
#      without building one — a builder assigns `children[...] =`), or if it
#      returns an `EditingResolution` and matches a key against bindings'
#      `.chords`. Exactly one routine may: `editing_keymap.resolveLayers`
#      (`nodeAfter`, the walk primitive it calls, is counted separately and
#      must stay in the same module). The retired resolvers' names
#      (`actionForChord`, `chordOfKey`, Mousetrap) must not come back.
#   2  ONE KEY DECODER PER DEVICE.
#      2a `key_names.chordName` spells every canonical key name. Its callers
#         outside `key_names` are exactly the declared decoders: GPUI's
#         (`gpui/app/gpui_keys`), the desktop's KeyboardEvent decoder
#         (`common/key_event_names`), and the `.vimrc` importer
#         (`viewmodel/keymap/vim_import`, a text notation, not a device). Both
#         directions: a declared decoder that stopped calling it is stale.
#      2b Each front-end's key entry reaches its decoder: the terminal runtime
#         calls `keyName(`, GPUI's window `canonicalKeyOfGpui(`, the desktop's
#         router `canonicalKeyOfDom(` (the positive control: a decoder nobody
#         calls is not the front-end's decoder).
#      2c No module but `key_names` spells a terminal KEY as its bytes — a
#         string literal holding `ESC [ … <A-D F H P-S ~ u>` or `ESC O <…>`.
#         Comment lines, tests and test support (`tests/`, `testing/`,
#         `*_test.nim`) are not scanned; the screen-clearing OUTPUT sequences
#         two host modules write (`ESC[2J ESC[H`) are allowed by file.
#   3  ONE MODIFIER ORDER (Ctrl, Shift, Alt, Meta — `chordName`'s). No string
#      literal outside `key_names` spells two or more modifiers out of that
#      order (`Shift+Ctrl+K`), or builds a multi-modifier prefix
#      (`"Ctrl+Alt+"`), and no array of modifier names is written in another
#      order.
#   4  BASES ARE DATA (§8 item 3). `cua_keymap`, `emacs_keymap` and
#      `navigation_keymap` hold no routine (proc / func / iterator / template /
#      macro / method / converter), no lambda, no `case`, `for` or `while`.
#      `vim_keymap` and `kakoune_keymap` are PLAT-31's GENERATED tables (a
#      motion's three forms, the 26 registers) and are named here as such,
#      not assessed — the deviation is recorded, not hidden.
#   5  NO BEHAVIOUR IN A BINDING (§8 item 4). The row types `BaseRow`,
#      `EditingBinding` and `UserRow` carry no field of a procedural type.
#   6  ONE OWNER PER MODULE (§8 item 6). Every module under
#      `viewmodel/keymap/` opens with a `## <file>.nim` header that has an
#      `Owns:` line and a `Refuses to own:` line.
#
# Usage: ci/test/keymap-clean-code.sh [ROOT]   (ROOT defaults to the repository)

set -uo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

python3 -I - "${root}" <<'PY'
import os
import re
import sys

root = sys.argv[1]
SRC = os.path.join(root, "src")
KEYMAP_DIR = "src/frontend/viewmodel/keymap"
KEY_NAMES = "src/common/key_names.nim"
RESOLVER = ("src/frontend/viewmodel/keymap/editing_keymap.nim", "resolveLayers")
DECLARED_DECODERS = {
    "src/frontend/gpui/app/gpui_keys.nim": "GPUI's keystroke decoder",
    "src/common/key_event_names.nim": "the desktop's KeyboardEvent decoder",
    "src/frontend/viewmodel/keymap/vim_import.nim":
        "the .vimrc importer (Vim's <C-x> notation, not a device)",
}
ENTRIES = [
    ("src/frontend/tui/app/runtime.nim", "keyName(", "the terminal"),
    ("src/frontend/gpui/main.nim", "canonicalKeyOfGpui(", "GPUI"),
    ("src/frontend/ui/key_router.nim", "canonicalKeyOfDom(", "the desktop"),
]
OUTPUT_SEQUENCES = {
    # file -> the exact literals it may hold: screen OUTPUT, not keys.
    "src/frontend/tui/app/views/hyperlinks.nim": {"\\x1b[2J\\x1b[H"},
    "src/frontend/tui/host/ssh_tuning.nim": {"\\x1b[2J\\x1b[H"},
}
DATA_BASES = ["cua_keymap.nim", "emacs_keymap.nim", "navigation_keymap.nim"]
GENERATED_BASES = {
    "vim_keymap.nim": "PLAT-31's generated table (a motion's three forms, the registers)",
    "kakoune_keymap.nim": "PLAT-31's generated table (select / extend pairs, the registers)",
}
ROW_TYPES = [
    ("src/frontend/viewmodel/keymap/base_rows.nim", "BaseRow"),
    ("src/frontend/viewmodel/keymap/editing_keymap.nim", "EditingBinding"),
    ("src/frontend/viewmodel/keymap/user_keymap.nim", "UserRow"),
]
WRITTEN_CHORDS = {
    # Modules whose chord literals are WRITTEN chords — spelled as their
    # specification spells them (CUA-Keymap.md, Emacs-Keymap.md, the stepping
    # presets) and read through `key_names.normalizeChord`, which puts the
    # modifiers in the one order. They are input to the speller, not names.
    "src/frontend/viewmodel/keymap/cua_keymap.nim",
    "src/frontend/viewmodel/keymap/emacs_keymap.nim",
    "src/frontend/viewmodel/keymap/navigation_keymap.nim",
    "src/frontend/viewmodel/keymap/binding_sets.nim",
}
RETIRED_RESOLVERS = ["actionForChord", "chordOfKey", "Mousetrap"]
MODS = ["Ctrl", "Shift", "Alt", "Meta"]

failures = []
oks = []

def bad(check, msg):
    failures.append(f"[{check}] {msg}")

def ok(check, msg):
    oks.append(f"[{check}] {msg}")

def rel(p):
    return os.path.relpath(p, root).replace(os.sep, "/")

def is_test(r):
    parts = r.split("/")
    return ("tests" in parts or "test" in parts or "testing" in parts or
            r.endswith("_test.nim") or os.path.basename(r).startswith("test_"))

product = []
for d, _, files in os.walk(SRC):
    for f in files:
        if f.endswith(".nim"):
            r = rel(os.path.join(d, f))
            if not is_test(r):
                product.append(r)
product.sort()

def read(r):
    try:
        with open(os.path.join(root, r), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None

ROUTINE = re.compile(r"^(\s*)(proc|func|method|iterator|template|macro|converter)\s+`?([A-Za-z_][A-Za-z0-9_]*)")

def routines(text):
    """(name, header line, body) per routine: the body is every following
    line indented deeper than the header (blank lines included)."""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = ROUTINE.match(lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        name = m.group(3)
        head = [lines[i]]
        j = i + 1
        # a signature continued over several lines
        while j < len(lines) and not head[-1].rstrip().endswith("=") and \
                j - i < 12 and lines[j].strip():
            head.append(lines[j])
            j += 1
        body = []
        while j < len(lines):
            ln = lines[j]
            if ln.strip() and (len(ln) - len(ln.lstrip())) <= indent:
                break
            body.append(ln)
            j += 1
        out.append((name, "\n".join(head), "\n".join(body)))
        i = j
    return out

def code_only(text):
    """Text with comment lines and trailing comments dropped (a `#` inside a
    string is rare enough in these modules to keep the scan simple)."""
    out = []
    for ln in text.splitlines():
        s = ln.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        out.append(ln)
    return "\n".join(out)

STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')

def literals(text):
    for n, ln in enumerate(code_only(text).splitlines(), 1):
        for m in STRING.finditer(ln):
            yield n, m.group(1)

# ---------------------------------------------------------------- check 1
resolvers = []
walk_primitive = []
for r in product:
    text = read(r)
    if text is None:
        continue
    trie_module = "EditingTrie" in text or "TrieNode" in text
    for name, head, body in routines(code_only(text)):
        walks = "nodeAfter(" in body
        if trie_module and re.search(r"\.children(\[|\.hasKey\()", body):
            builds = re.search(r"children\[[^\]]*\]\s*=", body) or "TrieNode(" in body
            if not builds:
                walks = True
        linear = ("EditingResolution" in head and re.search(r"\.chords\s*(==|\[)", body)
                  and re.search(r"\bfor\b[^\n]*\bbindings\b", body))
        if name == "nodeAfter":
            walk_primitive.append((r, name))
            continue
        if walks or linear:
            resolvers.append((r, name))
    for retired in RETIRED_RESOLVERS:
        for n, ln in enumerate(code_only(text).splitlines(), 1):
            if re.search(r"\b" + retired + r"\b", ln):
                bad("1", f"{r}:{n}: the retired resolver `{retired}` is back")
if resolvers == [RESOLVER]:
    ok("1", f"one resolver: {RESOLVER[0]}.{RESOLVER[1]}")
elif RESOLVER not in resolvers:
    bad("1", f"positive control: {RESOLVER[0]}.{RESOLVER[1]} was not found "
             f"walking the trie — the scan reads nothing, or the resolver moved")
for r, name in resolvers:
    if (r, name) != RESOLVER:
        bad("1", f"a second resolver: {r}: `{name}` walks or matches bindings "
                 f"(Base-Keymaps §8 item 1: one resolver)")
for r, name in walk_primitive:
    if r != RESOLVER[0]:
        bad("1", f"{r}: a second trie walk primitive `{name}`")

# ---------------------------------------------------------------- check 2
callers = set()
for r in product:
    if r == KEY_NAMES:
        continue
    text = read(r)
    if text and re.search(r"\bchordName\(", code_only(text)):
        callers.add(r)
for r in sorted(callers - set(DECLARED_DECODERS)):
    bad("2a", f"{r} spells key names itself (calls `chordName`) and is not a "
              f"declared decoder — a second decoder")
for r in sorted(set(DECLARED_DECODERS) - callers):
    bad("2a", f"{r} ({DECLARED_DECODERS[r]}) no longer calls `chordName`: the "
              f"declaration is stale, or it spells names its own way")
if callers == set(DECLARED_DECODERS):
    ok("2a", f"chordName's callers are the {len(callers)} declared decoders")
for r, call, who in ENTRIES:
    text = read(r)
    if text is None or call not in code_only(text):
        bad("2b", f"{who}'s key entry ({r}) does not call `{call.rstrip('(')}` "
                  f"— its keys reach no declared decoder")
    else:
        ok("2b", f"{who} decodes through `{call.rstrip('(')}`")
KEY_BYTES = re.compile(r"(\\x1b|\\e|\\27|\\033)(\[[0-9;:]*[A-DFHP-Su~]|O[A-DFHP-S])")
    # No `?`: a private-mode query or report (`CSI ? u`) is never a key.
for r in product:
    if r == KEY_NAMES:
        continue
    text = read(r)
    if not text:
        continue
    allowed = OUTPUT_SEQUENCES.get(r, set())
    for n, lit in literals(text):
        if KEY_BYTES.search(lit) and lit not in allowed:
            bad("2c", f"{r}:{n}: \"{lit}\" spells a terminal key as its bytes "
                      f"(only key_names turns the terminal's bytes into names)")

# ---------------------------------------------------------------- check 3
def mod_order_problem(lit):
    tokens = [t for t in re.split(r"\+", lit) if t != ""]
    seen = [t for t in tokens if t in MODS]
    if len(seen) >= 2 and seen != sorted(seen, key=MODS.index):
        return "spells modifiers out of the order Ctrl, Shift, Alt, Meta"
    if lit.endswith("+") and len(seen) >= 2 and all(t in MODS for t in tokens):
        return "builds a multi-modifier prefix (only chordName spells one)"
    return ""

ARRAY = re.compile(r"[\[(]\s*((?:\"(?:Ctrl|Shift|Alt|Meta)\"\s*,\s*)+\"(?:Ctrl|Shift|Alt|Meta)\")\s*[\])]")
for r in product:
    if r == KEY_NAMES or r in WRITTEN_CHORDS:
        continue
    text = read(r)
    if not text:
        continue
    for n, lit in literals(text):
        p = mod_order_problem(lit)
        if p:
            bad("3", f"{r}:{n}: \"{lit}\" {p}")
    for n, ln in enumerate(code_only(text).splitlines(), 1):
        for m in ARRAY.finditer(ln):
            names = re.findall(r"\"(\w+)\"", m.group(1))
            if names != sorted(names, key=MODS.index):
                bad("3", f"{r}:{n}: the modifier names {names} are listed out "
                         f"of the order Ctrl, Shift, Alt, Meta")

# ---------------------------------------------------------------- check 4
PROCEDURAL = re.compile(r"\b(proc|func|method|iterator|template|macro|converter|"
                        r"case|for|while)\b|=>")
    # Matched against the line with its string literals blanked, so an
    # operation named `find.toggle-case` is not a `case`.
for f in DATA_BASES:
    r = f"{KEYMAP_DIR}/{f}"
    text = read(r)
    if text is None:
        bad("4", f"{r} is gone: the data base has no subject")
        continue
    hits = [(n, ln.strip()) for n, ln in enumerate(code_only(text).splitlines(), 1)
            if PROCEDURAL.search(STRING.sub('""', ln))]
    for n, ln in hits:
        bad("4", f"{r}:{n}: `{ln[:60]}` — a base is data: no procedure, closure, "
                 f"loop or `case` over keys (§8 item 3)")
    if not hits:
        ok("4", f"{f} is data")
for f, why in GENERATED_BASES.items():
    print(f"  not assessed  {KEYMAP_DIR}/{f}: {why}")

# ---------------------------------------------------------------- check 5
for r, typ in ROW_TYPES:
    text = read(r)
    if text is None:
        bad("5", f"{r} is gone: `{typ}` has no subject")
        continue
    lines = code_only(text).splitlines()
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^\s*" + typ + r"\*?\s*=\s*(ref\s+)?object\b", ln):
            start = i
            break
    if start is None:
        bad("5", f"positive control: `{typ}` is not declared in {r}")
        continue
    indent = len(lines[start]) - len(lines[start].lstrip())
    fields = []
    for ln in lines[start + 1:]:
        if ln.strip() and (len(ln) - len(ln.lstrip())) <= indent:
            break
        m = re.match(r"^\s*([A-Za-z_][\w]*\*?(?:\s*,\s*[A-Za-z_]\w*\*?)*)\s*:\s*(.+)$", ln)
        if m:
            fields.append((m.group(1), m.group(2)))
    if not fields:
        bad("5", f"positive control: no field of `{typ}` was read in {r}")
    for name, t in fields:
        if re.search(r"\bproc\b|\bclosure\b|\bmethod\b|->", t):
            bad("5", f"{r}: `{typ}.{name.strip()}` is a procedure ({t.strip()}): "
                     f"a binding names an operation and literal arguments, "
                     f"nothing else (§8 item 4)")
    if fields and not any(re.search(r"\bproc\b|->", t) for _, t in fields):
        ok("5", f"{typ}: {len(fields)} field(s), none procedural")

# ---------------------------------------------------------------- check 6
kdir = os.path.join(root, KEYMAP_DIR)
modules = sorted(f for f in os.listdir(kdir) if f.endswith(".nim")) if os.path.isdir(kdir) else []
if not modules:
    bad("6", f"positive control: no module under {KEYMAP_DIR}")
for f in modules:
    text = read(f"{KEYMAP_DIR}/{f}") or ""
    header = []
    for ln in text.splitlines():
        if ln.startswith("##"):
            header.append(ln)
        elif ln.strip() == "":
            if header:
                break
        else:
            break
    problems = []
    if not header or not header[0].startswith(f"## {f}"):
        problems.append(f"its header does not open with `## {f}`")
    if not any(re.match(r"^##\s+(\*\*)?Owns:", h) for h in header):
        problems.append("its header has no `Owns:` line")
    if not any(re.search(r"\bRefuses to own:", h) for h in header):
        problems.append("its header has no `Refuses to own:` line")
    for p in problems:
        bad("6", f"{KEYMAP_DIR}/{f}: {p} (§8 item 6: one owner per module)")
if modules and not any(f.startswith(f"[6] {KEYMAP_DIR}") for f in failures):
    ok("6", f"{len(modules)} keymap modules, each with its owner header")

for o in oks:
    print(f"  ok    {o}")
for f in failures:
    print(f"  FAIL  {f}")
print()
print("RESULT: " + ("OK" if not failures else f"FAILED ({len(failures)})"))
sys.exit(1 if failures else 0)
PY
