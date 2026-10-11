#!/usr/bin/env python3
"""cua-keymap-extractor.py — PLAT-68 deliverable 5: re-extract every VS Code
binding CUA-Keymap.md cites, and find every VS Code default it neither takes
nor declines.

CUA-Keymap.md §1: *"Every `M` row below was read out of Monaco 0.54.0's ESM
sources by a script … The script is a PLAT-68 deliverable, committed beside
the oracle test, so the rows are re-extracted rather than believed. … a W row
the extractor does not reproduce is a red check, not an edit to this table —
the table is fixed to match VS Code, never the other way."*

INPUTS (both pinned to one commit, `484fdf69b8509c1c9370d913b32e9f6d3a68cc99`,
VS Code 1.105.0):

  --monaco DIR   `monaco-editor` 0.54.0's `esm/vs` — the M population. Its
                 `package.json` must say `vscodeCommitId` is the pinned commit.
  --vscode DIR   the VS Code source tree at the pinned commit — the W
                 population (`src/vs/workbench/**`). Its `package.json` must
                 say `1.105.0`.
  --spec FILE    `codetracer-specs/spec/GUI/CUA-Keymap.md`.

WHAT IS CHECKED, AND WHAT IS RED

  1. REPRODUCTION. For every row of a `| Chord |` table in §3 and §4 whose Src
     names M or W, and every (chord, VS Code command) pair the row states, the
     command's extracted bindings must contain the chord on each platform the
     row says it holds on (Linux and Windows; the macOS column is out of the
     terminal's scope, Base-Keymaps §7.4). A pair that is not reproduced is
     red, with what VS Code actually binds.
  2. COMPLETENESS. Every default the extraction found — every M binding, and
     every W binding in a file a row cites — whose Linux chord is in no §3 /
     §4 row and in no §6 row is listed. A non-empty list is red.

  Chords are compared after one normalisation (modifier order Ctrl, Shift,
  Alt, Meta; a letter is a key; `Escape` is `Esc`) — the reading
  `key_names.normalizeChord` gives the same text.

PARSING THE SOURCES

  A binding is an object carrying `primary:` (and optionally `secondary:`,
  `mac:` / `linux:` / `win:` overrides, `when:` / `kbExpr:`), found by brace
  matching around every `primary:`; its command is the `id:` of the nearest
  enclosing object that has one (an editor action's `super({ id, kbOpts })`,
  an `Action2`'s `super({ id, keybinding })`, or the
  `registerCommandAndKeybindingRule({ id, primary })` argument itself). An
  identifier id is resolved through the string constants the tree declares
  (`const X = '…'`, `static readonly ID = '…'`, enum members). Key codes are
  read from the `KeyMod.X` / `KeyCode.Y` spellings — written in TypeScript and
  kept as comments by the ESM build, so one reader serves both.

Exit status: 0 green, 1 red, 2 an input is missing or unpinned.
"""

import argparse
import json
import os
import re
import sys

PINNED_COMMIT = "484fdf69b8509c1c9370d913b32e9f6d3a68cc99"
PINNED_VERSION = "1.105.0"

KEYCODE = {
    "UpArrow": "Up", "DownArrow": "Down", "LeftArrow": "Left",
    "RightArrow": "Right", "Home": "Home", "End": "End", "PageUp": "PageUp",
    "PageDown": "PageDown", "Escape": "Esc", "Enter": "Enter", "Tab": "Tab",
    "Backspace": "Backspace", "Delete": "Delete", "Insert": "Insert",
    "Space": "Space", "Semicolon": ";", "Equal": "=", "Comma": ",",
    "Minus": "-", "Period": ".", "Slash": "/", "Backquote": "`",
    "BracketLeft": "[", "Backslash": "\\", "BracketRight": "]", "Quote": "'",
    "US_SEMICOLON": ";", "US_EQUAL": "=", "US_COMMA": ",", "US_MINUS": "-",
    "US_DOT": ".", "US_SLASH": "/", "US_BACKTICK": "`",
    "US_OPEN_SQUARE_BRACKET": "[", "US_BACKSLASH": "\\",
    "US_CLOSE_SQUARE_BRACKET": "]", "US_QUOTE": "'",
}
MODIFIER_ORDER = ["Ctrl", "Shift", "Alt", "Meta"]
KEYMOD = {"CtrlCmd": "Ctrl", "Shift": "Shift", "Alt": "Alt", "WinCtrl": "Ctrl"}
NAME_ALIASES = {"escape": "Esc", "esc": "Esc", "enter": "Enter",
                "return": "Enter", "tab": "Tab", "backspace": "Backspace",
                "delete": "Delete", "insert": "Insert", "space": "Space",
                "home": "Home", "end": "End", "pageup": "PageUp",
                "pagedown": "PageDown", "up": "Up", "down": "Down",
                "left": "Left", "right": "Right"}


def key_of_code(code):
    if code in KEYCODE:
        return KEYCODE[code]
    m = re.fullmatch(r"Key([A-Z])", code)
    if m:
        return m.group(1).lower()
    m = re.fullmatch(r"Digit(\d)", code)
    if m:
        return m.group(1)
    m = re.fullmatch(r"F(\d+)", code)
    if m:
        return "F" + m.group(1)
    return "<" + code + ">"


def chord(mods, key):
    """The one spelling: modifiers in order, a letter as the key."""
    return "+".join([m for m in MODIFIER_ORDER if m in mods] + [key])


def normalize(text):
    """A written chord (VS Code's notation) -> the canonical spelling."""
    text = text.strip()
    parts, cur = [], ""
    for ch in text:
        if ch == "+" and cur:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    mods = set()
    for p in parts[:-1]:
        p = p.lower()
        mods.add({"ctrl": "Ctrl", "shift": "Shift", "alt": "Alt",
                  "meta": "Meta", "cmd": "Meta"}.get(p, "?" + p))
    key = parts[-1]
    if len(key) == 1:
        key = key.lower()
    elif re.fullmatch(r"Numpad\w+", key):
        key = "<" + key + ">"
    else:
        key = NAME_ALIASES.get(key.lower(), key)
        if re.fullmatch(r"[fF]\d+", key):
            key = key.upper()
    return chord(mods, key)


def normalize_seq(text):
    return " ".join(normalize(c) for c in text.split())


# --------------------------------------------------------------------------
# The sources
# --------------------------------------------------------------------------

def matching(text, i, open_ch, close_ch):
    """Index of the bracket closing the one at `i`, skipping strings."""
    depth = 0
    j = i
    quote = None
    while j < len(text):
        c = text[j]
        if quote:
            if c == "\\":
                j += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def enclosing_open(text, i):
    """Index of the innermost unmatched `{` before `i`."""
    depth = 0
    j = i - 1
    while j >= 0:
        c = text[j]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                return j
            depth -= 1
        j -= 1
    return -1


def top_level_value(obj, key):
    """The text of `key: <value>` at the TOP level of the object text `obj`
    (which starts with `{`), or None."""
    depth = 0
    i = 1
    quote = None
    while i < len(obj) - 1:
        c = obj[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"`":
            quote = c
        elif c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
        elif depth == 0 and obj.startswith(key + ":", i) and \
                (i == 0 or not (obj[i - 1].isalnum() or obj[i - 1] in "_$.")):
            j = i + len(key) + 1
            start = j
            d = 0
            q = None
            while j < len(obj) - 1:
                cj = obj[j]
                if q:
                    if cj == "\\":
                        j += 2
                        continue
                    if cj == q:
                        q = None
                elif cj in "'\"`":
                    q = cj
                elif cj in "{[(":
                    d += 1
                elif cj in "}])":
                    if d == 0:
                        break
                    d -= 1
                elif cj == "," and d == 0:
                    break
                j += 1
            return obj[start:j].strip()
        i += 1
    return None


def strip_line_comments(expr):
    """Drop `// …` comments (a TypeScript source keeps the key names in code;
    the ESM build keeps them in `/* … */`, which must stay)."""
    out = []
    for line in expr.splitlines():
        k = line.find("//")
        out.append(line if k < 0 else line[:k])
    return "\n".join(out)


def desktop_branch(expr):
    """`isWeb ? A : B` -> the desktop branch. A condition naming the web or
    macOS takes the else branch; one naming `isNative` / `!isWeb` the then."""
    depth = 0
    q = c = -1
    for k, ch in enumerate(expr):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif depth == 0 and ch == "?" and q < 0:
            q = k
        elif depth == 0 and ch == ":" and q >= 0:
            c = k
            break
    if q < 0 or c < 0:
        return expr
    cond = expr[:q].strip().strip("()").strip()
    then_, else_ = expr[q + 1:c], expr[c + 1:]
    negated = cond.startswith("!")
    name = cond.lstrip("!")
    # The desktop on Linux / Windows: native, not the web, not Firefox, not
    # Safari, not macOS.
    desktop_true = name in ("isNative", "isLinux", "isWindows")
    return then_ if desktop_true != negated else else_


def has_shorthand(obj, key):
    """Whether the object text `obj` has the shorthand property `key` (`{ id,
    title }`) at its top level."""
    depth = 0
    for m in re.finditer(r"[{}\[\]()]|(?<![\w$.])" + key + r"(?=\s*[,}\n])", obj):
        t = m.group(0)
        if t in "{[(":
            depth += 1
        elif t in "}])":
            depth -= 1
        elif depth == 1:
            return True
    return False


def decode_chords(expr):
    """A `primary` / `secondary` element -> a chord sequence string, or None."""
    expr = desktop_branch(strip_line_comments(expr).strip()).strip()
    if expr in ("undefined", "0", "null", ""):
        return None
    m = re.match(r"KeyChord\((.*)\)$", expr, re.S)
    if m:
        inner = m.group(1)
        depth = 0
        for k, ch in enumerate(inner):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                a = decode_chords(inner[:k])
                b = decode_chords(inner[k + 1:])
                if a and b:
                    return a + " " + b
                return None
    mods = set()
    key = None
    for kind, name in re.findall(r"Key(Mod|Code)\.(\w+)", expr):
        if kind == "Mod":
            mods.add(KEYMOD.get(name, "?" + name))
        else:
            key = key_of_code(name)
    if key is None:
        return None
    return chord(mods, key)


def chords_of(obj, file_text="", file_path=None):
    """{platform: [chords]} for a binding object (base, then overrides).

    A value written as `X.primary` / `X.secondary` / `X.mac` is read from the
    object `const X = { … }` in the same file."""
    def deref(v, key):
        if v is None:
            return None
        m = re.fullmatch(r"(\w+)\." + key, v.strip())
        if not m:
            return v
        text, name = file_text, m.group(1)
        d = re.search(r"\bconst\s+" + name + r"\b[^=]*=\s*\{", text)
        if not d and file_path:
            imp = imports_of(file_path).get(name)
            if imp and imp[0] and imp[1]:
                try:
                    text = open(imp[0], encoding="utf-8", errors="replace").read()
                except OSError:
                    return v
                d = re.search(r"\bconst\s+" + imp[1] + r"\b[^=]*=\s*\{", text)
        if not d:
            return v
        o = d.end() - 1
        close = matching(text, o, "{", "}")
        return top_level_value(text[o:close + 1], key) if close > 0 else v

    def own(o):
        out = []
        p = deref(top_level_value(o, "primary"), "primary")
        if p:
            c = decode_chords(p)
            if c:
                out.append(c)
        s = deref(top_level_value(o, "secondary"), "secondary")
        if s and s.startswith("["):
            depth = 0
            cur = ""
            for ch in s[1:-1]:
                if ch in "([":
                    depth += 1
                elif ch in ")]":
                    depth -= 1
                if ch == "," and depth == 0:
                    c = decode_chords(cur)
                    if c:
                        out.append(c)
                    cur = ""
                else:
                    cur += ch
            c = decode_chords(cur)
            if c:
                out.append(c)
        return out
    base = own(obj)
    result = {}
    for plat in ("linux", "win", "mac"):
        o = deref(top_level_value(obj, plat), plat)
        result[plat] = own(o) if o and o.startswith("{") else base
    return result


def collect_constants(paths):
    consts = {}
    for path in paths:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"\b(?:export\s+)?const\s+(\w+)\s*(?::\s*\w+\s*)?=\s*'([^']+)'", text):
            consts.setdefault(m.group(1), m.group(2))
        cls = None
        for line in text.splitlines():
            mc = re.search(r"\bclass\s+(\w+)", line)
            if mc:
                cls = mc.group(1)
            ms = re.search(r"\bstatic\s+(?:readonly\s+)?(\w+)\s*=\s*'([^']+)'", line)
            if ms and cls:
                consts.setdefault(cls + "." + ms.group(1), ms.group(2))
            # The ESM build's form of a static: `static { this.ID = '…'; }`.
            mt = re.search(r"\bthis\.(\w+)\s*=\s*'([^']+)'", line)
            if mt and cls:
                consts.setdefault(cls + "." + mt.group(1), mt.group(2))
        for me in re.finditer(r"\benum\s+(\w+)\s*\{([^}]*)\}", text):
            for mm in re.finditer(r"(\w+)\s*=\s*'([^']+)'", me.group(2)):
                consts.setdefault(me.group(1) + "." + mm.group(1), mm.group(2))
        # `const FIND_IDS = { StartFindAction: 'actions.find', … }`
        for mo in re.finditer(r"\bconst\s+(\w+)\s*(?::[^=]+)?=\s*\{", text):
            o = mo.end() - 1
            close = matching(text, o, "{", "}")
            if close < 0 or close - o > 20000:
                continue
            for mm in re.finditer(r"(\w+)\s*:\s*'([^']+)'", text[o:close]):
                consts.setdefault(mo.group(1) + "." + mm.group(1), mm.group(2))
    return consts


_IMPORTS = {}
_LOCALS = {}


def imports_of(path):
    """{local name: (module path, original name or None for a namespace)}."""
    if path in _IMPORTS:
        return _IMPORTS[path]
    out = {}
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        _IMPORTS[path] = out
        return out
    base = os.path.dirname(path)
    for m in re.finditer(r"import\s*\{([^}]*)\}\s*from\s*'([^']+)'", text):
        mod = module_path(base, m.group(2))
        for part in m.group(1).split(","):
            part = part.strip()
            if not part:
                continue
            bits = re.split(r"\s+as\s+", part)
            out[bits[-1].strip()] = (mod, bits[0].strip())
    for m in re.finditer(r"import\s*\*\s*as\s+(\w+)\s+from\s*'([^']+)'", text):
        out[m.group(1)] = (module_path(base, m.group(2)), None)
    _IMPORTS[path] = out
    return out


def module_path(base, spec):
    if not spec.startswith("."):
        return None
    p = os.path.normpath(os.path.join(base, spec))
    for cand in (p[:-3] + ".ts" if p.endswith(".js") else p + ".ts", p,
                 p[:-3] + ".js" if p.endswith(".js") else p + ".js"):
        if os.path.isfile(cand):
            return cand
    return None


def locals_of(path):
    if path not in _LOCALS:
        _LOCALS[path] = collect_constants([path])
    return _LOCALS[path]


def resolve_name(name, path, depth=0):
    """A dotted name used in `path` -> the string constant it denotes, by the
    file's own declarations, then its imports (named and namespace)."""
    if path is None or depth > 4:
        return None
    local = locals_of(path)
    if name in local:
        return local[name]
    head, _, rest = name.partition(".")
    imp = imports_of(path).get(head)
    if imp:
        mod, original = imp
        if original is None:
            return resolve_name(rest, mod, depth + 1) if rest else None
        return resolve_name(original + ("." + rest if rest else ""), mod, depth + 1)
    return None


def resolve_id(raw, consts, local=None, path=None):
    """An `id:` value -> the command string. A name the FILE declares wins
    over one declared elsewhere: two classes called `GotoSymbolAction` (the
    standalone editor's and the workbench's) hold two different ids."""
    raw = raw.strip()
    if local and raw in local:
        return local[raw]
    if path:
        v = resolve_name(raw, path)
        if v:
            return v
    m = re.fullmatch(r"'([^']*)'|\"([^\"]*)\"", raw)
    if m:
        return m.group(1) if m.group(1) is not None else m.group(2)
    if raw in consts:
        return consts[raw]
    # A dotted name the file's imports did not resolve: its last TWO segments
    # (`SearchCommandIds.FindInFilesActionId`) — never a bare last segment,
    # which matches whichever `ID` some unrelated file declared first.
    parts = raw.split(".")
    if len(parts) >= 2 and ".".join(parts[-2:]) in consts:
        return consts[".".join(parts[-2:])]
    if len(parts) == 1 and raw in consts:
        return consts[raw]
    return raw


def switch_cases(text, fn, near=0):
    """`function fn(…) { switch (…) { case 1: return X; … } }` -> {1: X}.
    A file may declare two functions of one name in different scopes."""
    ms = list(re.finditer(r"function\s+" + fn + r"\s*\(", text))
    if not ms:
        return {}
    # Function declarations are hoisted and VS Code writes the helpers after
    # the loop that calls them, so the first declaration AFTER the
    # registration is the one in its scope; failing that, the last before it.
    after = [x for x in ms if x.start() > near]
    m = after[0] if after else ms[-1]
    o = text.find("{", m.end())
    close = matching(text, o, "{", "}")
    body = text[o:close]
    return {int(k): v.strip() for k, v in
            re.findall(r"case\s+(\d+)\s*:\s*return\s+([^;]+);", body)}


def loop_bindings(obj, text, path, at=0):
    """A registration inside a loop — `id: toCommandId(i)` with
    `primary: KeyMod.CtrlCmd | toKeyCode(i)` — expanded case by case from the
    two functions' `switch`es (VS Code registers its group-focus chords this
    way)."""
    idv = top_level_value(obj, "id") or ""
    prim = top_level_value(obj, "primary") or ""
    mi = re.fullmatch(r"(\w+)\((\w+)\)", idv.strip())
    mk = re.search(r"(\w+)\(" + (mi.group(2) if mi else "\x00") + r"\)", prim)
    if not mi or not mk:
        return []
    ids = switch_cases(text, mi.group(1), at)
    keys = switch_cases(text, mk.group(1), at)
    mods = re.sub(r"\w+\(\w+\)", "", prim)
    out = []
    for k in sorted(ids):
        if k not in keys:
            continue
        c = decode_chords(mods + " | " + keys[k])
        if c:
            cmd = ids[k].strip("'\"")
            out.append((cmd, path, {"linux": [c], "win": [c], "mac": [c]}, ""))
    return out


def extract(paths, consts):
    """[(command, file, {platform: [chords]}, when)] for every binding."""
    out = []
    for path in paths:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "primary" not in text:
            continue
        local = collect_constants([path])
        seen = set()
        for m in re.finditer(r"(?<![\w$.])primary\s*:", text):
            o = enclosing_open(text, m.start())
            if o < 0:
                continue
            close = matching(text, o, "{", "}")
            if close < 0:
                continue
            # A platform override's own object is part of its parent binding:
            # the parent is the binding — handled at the parent's own
            # `primary:` when it has one, here when it carries only overrides.
            before = text[:o].rstrip()
            if re.search(r"(?<![\w$])(mac|linux|win)\s*:\s*$", before):
                parent = enclosing_open(text, o)
                if parent < 0:
                    continue
                pclose = matching(text, parent, "{", "}")
                if pclose < 0 or top_level_value(text[parent:pclose + 1], "primary") is not None:
                    continue
                o, close = parent, pclose
            if o in seen:
                continue
            seen.add(o)
            obj = text[o:close + 1]
            looped = loop_bindings(obj, text, path, o)
            if looped:
                out.extend(looped)
                continue
            # The command: this object's own `id`, else the nearest enclosing
            # object's.
            cmd = None
            probe = o
            hops = 0
            while probe >= 0 and hops < 6:
                pclose = matching(text, probe, "{", "}")
                pobj = text[probe:pclose + 1] if pclose > 0 else ""
                v = top_level_value(pobj, "id") if pobj else None
                if v is None and pobj and has_shorthand(pobj, "id"):
                    v = "id"
                if v:
                    cmd = resolve_id(v, consts, local, path)
                    break
                probe = enclosing_open(text, probe)
                hops += 1
            if not cmd:
                continue
            when = top_level_value(obj, "when") or top_level_value(obj, "kbExpr") or ""
            out.append((cmd, path, chords_of(obj, text, path), when))
    return out


def files_under(root, exts):
    for dirpath, _, names in os.walk(root):
        for n in names:
            if n.endswith(exts) and not n.endswith(".map") and \
                    "/test/" not in dirpath + "/":
                yield os.path.join(dirpath, n)


# --------------------------------------------------------------------------
# The specification
# --------------------------------------------------------------------------

def table_rows(spec_text, section_prefixes):
    """Every data row of every `| Chord |` table under a `### ` heading whose
    number starts with one of `section_prefixes`."""
    rows = []
    section = None
    header = None
    for line in spec_text.splitlines():
        h = re.match(r"###\s+(\d+(?:\.\d+)?)\s", line)
        if h:
            section = h.group(1)
            header = None
            continue
        h2 = re.match(r"##\s+(\d+)\.\s", line)
        if h2:
            section = h2.group(1)
            header = None
            continue
        if not line.startswith("|"):
            header = None if not line.strip() else header
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = cells
            continue
        if set(line.replace("|", "").strip()) <= set("-: "):
            continue
        if section is None or not any(section == p or section.startswith(p + ".")
                                      for p in section_prefixes):
            continue
        rows.append((section, header, cells))
    return rows


def ticks(cell):
    """The code spans of a cell — `x`, and ``x`` for a span holding a
    backquote (`` Ctrl+` ``)."""
    out = []
    for m in re.finditer(r"``\s?(.+?)\s?``|`([^`]+)`", cell):
        out.append(m.group(1) if m.group(1) is not None else m.group(2))
    return out


def row_chords(cell):
    """The chord cell -> {platform: [[alternatives...] per '/' position]}.

    `A` / `B` pair positionally with the commands; `A`, `C` are alternatives
    at one position; `· *Linux* X` overrides Linux; `· *Windows* also X` adds
    on Windows; `*Windows* X` alone (no base) holds only there."""
    base_part, *clauses = re.split(r"\s+·\s+", cell)
    def positions(text):
        # `A / B, C / D` is two alternative PAIRS (positions 1 and 2 each
        # have two chords); `A, B / C` is two alternatives at position 1.
        parts = re.split(r",\s+(?=`)", text)
        if len(parts) > 1 and all(re.search(r"\s/\s", p) for p in parts):
            merged = []
            for p in parts:
                for k, alts in enumerate(positions(p)):
                    if k < len(merged):
                        merged[k] = merged[k] + alts
                    else:
                        merged.append(list(alts))
            return merged
        pos = []
        for group in re.split(r"\s+/\s+", text):
            alts = [normalize_seq(t) for t in ticks(group)]
            if alts:
                pos.append(alts)
        return pos
    platforms = {}
    only = re.match(r"\*(\w+(?:,\s*\w+)*)\*\s+(.*)", base_part)
    if only:
        names = [n.strip().lower() for n in only.group(1).split(",")]
        for n in names:
            platforms[{"windows": "win"}.get(n, n)] = ("only", positions(only.group(2)))
        return platforms
    base = positions(base_part)
    platforms["linux"] = ("base", base)
    platforms["win"] = ("base", base)
    for c in clauses:
        mc = re.match(r"\*([^*]+)\*\s+(also\s+)?(.*)", c)
        if not mc:
            continue
        names = [n.strip().lower() for n in mc.group(1).split(",")]
        also = bool(mc.group(2))
        pos = positions(mc.group(3))
        for n in names:
            key = {"windows": "win"}.get(n, n)
            if key not in ("linux", "win"):
                continue
            if also:
                merged = [list(p) for p in base]
                for k, extra in enumerate(pos):
                    if k < len(merged):
                        merged[k] = merged[k] + extra
                platforms[key] = ("also", merged)
            else:
                platforms[key] = ("override", pos)
    return platforms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monaco", required=True)
    ap.add_argument("--vscode", required=True)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--dump", help="write the extraction as JSON here")
    args = ap.parse_args()

    mon_pkg = os.path.join(args.monaco, "..", "..", "package.json")
    vs_pkg = os.path.join(args.vscode, "package.json")
    try:
        mon = json.load(open(mon_pkg))
        vs = json.load(open(vs_pkg))
    except OSError as e:
        print("cua-keymap-extractor: an input is missing:", e)
        return 2
    if mon.get("vscodeCommitId") != PINNED_COMMIT or mon.get("version") != "0.54.0":
        print("cua-keymap-extractor: monaco-editor is not 0.54.0 at %s" % PINNED_COMMIT)
        return 2
    if vs.get("version") != PINNED_VERSION:
        print("cua-keymap-extractor: VS Code sources are not %s" % PINNED_VERSION)
        return 2

    mon_files = sorted(files_under(args.monaco, (".js",)))
    wb_files = sorted(files_under(os.path.join(args.vscode, "src", "vs"), (".ts",)))
    consts = collect_constants(mon_files + wb_files)
    m_bindings = extract(mon_files, consts)
    w_bindings = [b for b in extract(wb_files, consts) if "/vs/workbench/" in b[1]]
    by_cmd = {}
    for src, bs in (("M", m_bindings), ("W", w_bindings)):
        for cmd, path, chords, when in bs:
            by_cmd.setdefault(cmd, []).append((src, path, chords, when))

    spec_text = open(args.spec, encoding="utf-8").read()
    red = []

    # 1. REPRODUCTION
    cited_files = set()
    not_keybindings = []
    reproduced = 0
    chords_in_rows = set()
    commands_in_rows = set()
    for section, header, cells in table_rows(spec_text, ["3", "4"]):
        if not header or header[0] != "Chord":
            continue
        col = {h: i for i, h in enumerate(header)}
        for p in row_chords(cells[0]).values():
            for alts in p[1]:
                chords_in_rows.update(alts)
        src_cell = cells[col["Src"]] if "Src" in col else ""
        srcs = set(re.findall(r"\b([MW])\b", src_cell))
        if not srcs:
            continue
        cmd_cell = cells[col["VS Code command"]] if "VS Code command" in col else src_cell
        if "no keybinding" in cmd_cell:
            # A row VS Code serves without a keybinding (typing a newline, the
            # chord dispatcher's cancel): nothing to re-extract, said so.
            not_keybindings.append("§%s %s" % (section, cells[0]))
            continue
        cmds = [c for c in ticks(cmd_cell) if re.fullmatch(r"[\w.]+", c)]
        commands_in_rows.update(cmds)
        plats = row_chords(cells[0])
        for plat in ("linux", "win"):
            if plat not in plats:
                continue
            _, positions = plats[plat]
            for k, alts in enumerate(positions):
                cmd = cmds[k] if k < len(cmds) else (cmds[-1] if cmds else None)
                if cmd is None:
                    red.append("§%s row %s: no VS Code command to check" %
                               (section, cells[0]))
                    continue
                vs_chords = set()
                for src, path, chords, when in by_cmd.get(cmd, []):
                    vs_chords.update(chords.get(plat, []))
                    cited_files.add(path)
                for a in alts:
                    if a in vs_chords:
                        reproduced += 1
                    else:
                        red.append("§%s %s: `%s` -> `%s` is not VS Code's on %s "
                                   "(VS Code binds %s)" %
                                   (section, plat, a, cmd, plat,
                                    sorted(vs_chords) or "nothing"))

    # 2. COMPLETENESS
    declined = set()
    declined_cmds = set()
    for section, header, cells in table_rows(spec_text, ["6"]):
        for t in ticks(cells[0]):
            declined.add(normalize_seq(t))
        for t in ticks(cells[1]) if len(cells) > 1 else []:
            declined_cmds.add(t)
    missing = []
    population = m_bindings + [b for b in w_bindings if b[1] in cited_files]
    for cmd, path, chords, when in population:
        for c in chords.get("linux", []):
            if c in chords_in_rows or c in declined or cmd in commands_in_rows \
                    or cmd in declined_cmds:
                continue
            missing.append("%s  %s  (%s)" % (c, cmd, os.path.relpath(path, args.monaco if path.startswith(args.monaco) else args.vscode)))

    if args.dump:
        json.dump({"M": [list(b[:1]) + [b[2], b[3]] for b in m_bindings],
                   "W": [list(b[:1]) + [b[2], b[3]] for b in w_bindings]},
                  open(args.dump, "w"), indent=1)

    print("cua-keymap-extractor: %d M and %d W bindings extracted; "
          "%d row chords reproduced; %d rows VS Code serves without a "
          "keybinding" % (len(m_bindings), len(w_bindings), reproduced,
                          len(not_keybindings)))
    for r in red:
        print("NOT REPRODUCED:", r)
    for m in sorted(set(missing)):
        print("NOT IN §3/§4 OR §6:", m)
    if red or missing:
        print("cua-keymap-extractor: RED — %d unreproduced, %d unaccounted" %
              (len(red), len(set(missing))))
        return 1
    print("cua-keymap-extractor: green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
