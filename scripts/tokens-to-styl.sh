#!/usr/bin/env bash
# A code generator, not a check on one — and it IS reachable from CI, through
# the check on it: `ci/test/design-tokens-fresh.sh` (run by `ci/lint/nim.sh`)
# regenerates BOTH outputs below from the pinned `libs/codetracer-design-system`
# revision and diffs them against the committed files.
#
# Design tokens in, TWO outputs out, from ONE resolution of the token layers:
#
#   * stylus, into src/frontend/styles/generated/ — the desktop's stylesheets
#     import it. The stylus keeps its references symbolic (`a = b`) and lets
#     stylus resolve them; its bytes are unchanged by the second emitter.
#   * (optional, `--nim-out FILE`) a Nim module of RESOLVED token constants,
#     every colour token of the `mapped` layer resolved through `alias` and
#     `brand` to a `#rrggbb` hex in BOTH colour modes (Dark and Light). The
#     terminal front-end paints from it, so the terminal and the desktop read
#     one design-system revision through one resolver.
#
#   * (with `--nim-out` and `--editor-theme DIR`, PLAT-47) the EDITOR THEME in
#     the same Nim module: the desktop's Monaco theme documents
#     (`DIR/codetracerDark.json` for Dark, `DIR/codetracerWhite.json` for
#     Light — the files `renderer.nim` feeds to `monaco.editor.defineTheme`)
#     resolved to `#rrggbb` per mode, as more `DesignToken` members: every
#     token rule's scope (`editor-theme/rule/<scope>`, resolved the way Monaco
#     resolves a scope — the rule itself, else its longest dotted prefix, else
#     the default rule), and the colours the desktop paints around Monaco
#     (the file's `codetracer` block: the editor ground, line numbers, the
#     execution line, the selection; a value is a hex or a `{token.path}`
#     reference into the design system, resolved by the same resolver). The
#     terminal's editor is painted from these, so it equals the desktop's.
#
# Usage: tokens-to-styl.sh <design-system-root> <stylus-out-dir> [<mode>]
#                          [--nim-out <file.nim>] [--editor-theme <dir>]
set -euo pipefail

POSITIONAL=()
NIM_OUT=""
EDITOR_THEME_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --nim-out) NIM_OUT="${2:?--nim-out needs a file path}"; shift 2 ;;
    --nim-out=*) NIM_OUT="${1#--nim-out=}"; shift ;;
    --editor-theme) EDITOR_THEME_DIR="${2:?--editor-theme needs a directory}"; shift 2 ;;
    --editor-theme=*) EDITOR_THEME_DIR="${1#--editor-theme=}"; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

ROOT_DIR="${1:-.}"
OUT_DIR="${2:-$ROOT_DIR/stylus}"
# Optional 3rd arg: a mode name (e.g. Light, Compact, Spacious). When given, each
# token resolves to $extensions.modes[<mode>] if that mode is present, otherwise
# it falls back to its default $value. With NO mode arg the output is identical
# to the single-value export (so existing consumers are untouched). This is the
# consumer half of the design-system "axes" campaign (color-mode + density).
# The mode applies to the STYLUS only: the Nim module always carries every mode.
SELECT_MODE="${3:-}"

mkdir -p "$OUT_DIR"

python3 - "$ROOT_DIR" "$OUT_DIR" "$SELECT_MODE" "$NIM_OUT" "$EDITOR_THEME_DIR" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

ROOT_DIR = Path(sys.argv[1]).resolve()
OUT_DIR = Path(sys.argv[2]).resolve()
SELECT_MODE = sys.argv[3] if len(sys.argv) > 3 else ""
NIM_OUT = sys.argv[4] if len(sys.argv) > 4 else ""
EDITOR_THEME_DIR = sys.argv[5] if len(sys.argv) > 5 else ""

EXPECTED_FOLDERS = ["brand", "alias", "mapped"]

def find_single_json(folder: Path) -> Path:
    if not folder.exists() or not folder.is_dir():
        raise SystemExit(f"[ERROR] Missing folder: {folder}")
    files = sorted([p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == ".json"])
    if not files:
        raise SystemExit(f"[ERROR] No .json file found in: {folder}")
    if len(files) > 1:
        raise SystemExit(
            f"[ERROR] Expected exactly 1 .json file in {folder}, found {len(files)}: "
            + ", ".join(p.name for p in files)
        )
    return files[0]

def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"[ERROR] Invalid JSON in {path}: {e}")

def sanitize_part(part: str) -> str:
    part = str(part).strip().lower()
    part = part.replace("&", " and ")
    part = re.sub(r"[^a-z0-9]+", "-", part)
    part = re.sub(r"-{2,}", "-", part).strip("-")
    return part or "token"

def path_to_var(path_parts):
    return "-".join(sanitize_part(p) for p in path_parts)

REF_RE = re.compile(r"^\{([^{}]+)\}$")

def ref_to_var(ref_text: str) -> str:
    inner = ref_text.strip()[1:-1].strip()
    parts = [p.strip() for p in inner.split(".")]
    return path_to_var(parts)

def is_hex_color(s: str) -> bool:
    return bool(re.fullmatch(r"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})", s))

def is_css_dimension(s: str) -> bool:
    return bool(re.fullmatch(r"-?\d+(?:\.\d+)?(?:px|rem|em|vh|vw|%)", s))

def quote_string(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)

def stylus_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        value = value.strip()
        if REF_RE.fullmatch(value):
            return ref_to_var(value)
        if is_hex_color(value):
            return value
        if is_css_dimension(value):
            return value
        return quote_string(value)
    return None

def stylus_value(value, indent=0):
    scalar = stylus_scalar(value)
    if scalar is not None:
        return scalar

    if isinstance(value, dict):
        pad = "  " * indent
        inner = "  " * (indent + 1)
        lines = ["{"]
        for k, v in value.items():
            key = sanitize_part(k)
            rendered = stylus_value(v, indent + 1)
            lines.append(f"{inner}{key}: {rendered}")
        lines.append(f"{pad}" + "}")
        return "\n".join(lines)

    if isinstance(value, list):
        rendered = ", ".join(stylus_value(v, indent) for v in value)
        return f"[{rendered}]"

    return quote_string(str(value))

def flatten_tokens(node, path=None, out=None, mode=None):
    # `mode=None` means "the stylus's mode" (SELECT_MODE). The Nim emitter
    # passes each colour mode explicitly; the stylus path is unchanged.
    if mode is None:
        mode = SELECT_MODE
    if path is None:
        path = []
    if out is None:
        out = {}

    if isinstance(node, dict):
        if "$value" in node:
            value = node.get("$value")
            # Mode selection (additive): if a mode was requested and this token
            # carries $extensions.modes[<mode>], use that per-mode value; else
            # fall back to the default $value. No mode → always $value.
            if mode:
                modes = (node.get("$extensions") or {}).get("modes") or {}
                if mode in modes:
                    value = modes[mode]
            out[tuple(path)] = {
                "type": node.get("$type"),
                "value": value,
            }
            return out

        for key, value in node.items():
            if key.startswith("$"):
                continue
            flatten_tokens(value, path + [key], out, mode)

    return out

def collect_all_vars(*flat_maps):
    vars_set = set()
    for flat in flat_maps:
        for token_path in flat.keys():
            vars_set.add(path_to_var(token_path))
    return vars_set

def render_file(title, flat_map, known_vars):
    lines = []
    lines.append(f"// Auto-generated from {title}.json")
    lines.append(f"// Source layer: {title}")
    if SELECT_MODE:
        lines.append(f"// Mode: {SELECT_MODE} (tokens without this mode fall back to their default $value)")
    lines.append("")

    unresolved = []

    for token_path in sorted(flat_map.keys(), key=lambda p: [sanitize_part(x) for x in p]):
        token = flat_map[token_path]
        var_name = path_to_var(token_path)
        rendered = stylus_value(token["value"])

        refs = []
        def gather_refs(v):
            if isinstance(v, str) and REF_RE.fullmatch(v):
                refs.append(ref_to_var(v))
            elif isinstance(v, dict):
                for vv in v.values():
                    gather_refs(vv)
            elif isinstance(v, list):
                for vv in v:
                    gather_refs(vv)

        gather_refs(token["value"])
        for ref in refs:
            if ref not in known_vars:
                unresolved.append((var_name, ref))

        lines.append(f"{var_name} = {rendered}")
        lines.append("")

    if unresolved:
        lines.append("// Unresolved references detected:")
        for src, ref in unresolved:
            lines.append(f"// {src} -> {ref}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"

# Required layers, in dependency order, plus any optional layers present.
# `space` (the density collection) is optional so older design-system checkouts
# without it still work. Add a new collection folder here (or make it optional)
# and it flows through with no other change.
REQUIRED_LAYERS = ["brand", "alias", "mapped"]
OPTIONAL_LAYERS = ["space"]

layers = list(REQUIRED_LAYERS)
for name in OPTIONAL_LAYERS:
    if (ROOT_DIR / name).is_dir():
        layers.append(name)

# ONE LOAD of the layers. Both emitters below read these documents; neither
# re-reads the design system.
documents = {name: load_json(find_single_json(ROOT_DIR / name)) for name in layers}
flats = {name: flatten_tokens(documents[name]) for name in layers}
known_vars = collect_all_vars(*flats.values())

for name in layers:
    (OUT_DIR / f"{name}.styl").write_text(render_file(name, flats[name], known_vars), encoding="utf-8")

emitted_layers = layers

# Font paths are relative to the compiled CSS output location
# (src/build-debug/frontend/styles/), so ../../../../libs/codetracer-design-system/
# resolves back to the design system submodule at the repo root.
SG_BASE = "../../../../libs/codetracer-design-system/SpaceGrotesk_Complete/Fonts/WEB/fonts"
SM_BASE = "../../../../libs/codetracer-design-system/SpaceGrotesk_Complete/Fonts/Space_Mono"
FM_BASE = "../../../../libs/codetracer-design-system/Fira_Mono"

def font_face(family, weight_value, style, ttf_base, ttf_file, woff2_file=None):
    src_parts = []
    if woff2_file:
        src_parts.append(f"url('{ttf_base}/{woff2_file}') format('woff2')")
    src_parts.append(f"url('{ttf_base}/{ttf_file}') format('truetype')")
    src_value = ",\n       ".join(src_parts)
    lines = [
        "@font-face {",
        f"  font-family: \"{family}\";",
        f"  font-weight: {weight_value};",
        f"  font-style: {style};",
        f"  src: {src_value};",
        "}",
        "",
    ]
    return "\n".join(lines)

fonts_lines = ["// Auto-generated @font-face declarations from design system fonts", ""]

# Space Grotesk – UI primary font (sourced from libs/codetracer-design-system)
sg_weights = [
    (300, "normal", "SpaceGrotesk-Light.ttf",    "SpaceGrotesk-Light.woff2"),
    (400, "normal", "SpaceGrotesk-Regular.ttf",  "SpaceGrotesk-Regular.woff2"),
    (500, "normal", "SpaceGrotesk-Medium.ttf",   "SpaceGrotesk-Medium.woff2"),
    (600, "normal", "SpaceGrotesk-SemiBold.ttf", "SpaceGrotesk-SemiBold.woff2"),
    (700, "normal", "SpaceGrotesk-Bold.ttf",     "SpaceGrotesk-Bold.woff2"),
]
for weight_value, style, ttf, woff2 in sg_weights:
    fonts_lines.append(font_face("SpaceGrotesk", weight_value, style, SG_BASE, ttf, woff2))

# Space Mono – UI/label secondary font (sourced from libs/codetracer-design-system)
sm_weights = [
    (400, "normal", "SpaceMono-Regular.ttf"),
    (700, "normal", "SpaceMono-Bold.ttf"),
    (400, "italic", "SpaceMono-Italic.ttf"),
    (700, "italic", "SpaceMono-BoldItalic.ttf"),
]
for weight_value, style, ttf in sm_weights:
    fonts_lines.append(font_face("SpaceMono", weight_value, style, SM_BASE, ttf))

# Fira Mono – editor/terminal monospace font (sourced from libs/codetracer-design-system)
fm_weights = [
    (400, "normal", "FiraMono-Regular.ttf"),
    (500, "normal", "FiraMono-Medium.ttf"),
    (700, "normal", "FiraMono-Bold.ttf"),
]
for weight_value, style, ttf in fm_weights:
    fonts_lines.append(font_face("FiraMono", weight_value, style, FM_BASE, ttf))

fonts_out = "\n".join(fonts_lines).rstrip() + "\n"
(OUT_DIR / "fonts.styl").write_text(fonts_out, encoding="utf-8")

index_out = "\n".join([
    "// Auto-generated import index",
    "// Note: fonts.styl is NOT included here to avoid duplicate @font-face rules.",
    "// Fonts are imported once via components/font_family.styl in codetracer.styl.",
    *[f'@import "{name}.styl"' for name in emitted_layers],
    "",
])
(OUT_DIR / "index.styl").write_text(index_out, encoding="utf-8")

for name in emitted_layers:
    print(f"[OK] wrote      : {OUT_DIR / (name + '.styl')}")
print(f"[OK] wrote      : {OUT_DIR / 'fonts.styl'}")
print(f"[OK] wrote      : {OUT_DIR / 'index.styl'}")

# ---------------------------------------------------------------------------
# The Nim emitter: every `mapped` colour token, resolved to a hex, per mode.
# ---------------------------------------------------------------------------

NIM_MODES = ["Dark", "Light"]
  # The design system's two colour modes. A mode the design system stops
  # publishing is a loud failure below, not a silent fallback to $value.

def nim_ident(path_parts):
    words = []
    for part in path_parts:
        for w in re.split(r"[^A-Za-z0-9]+", str(part)):
            if w:
                words.append(w[0].upper() + w[1:].lower())
    return "dt" + "".join(words)

def resolve_hex(var_name, stack, below=None, trail=()):
    # Follow `{a.b.c}` references to a literal colour.
    #
    # `stack` is one {var: value} map per layer, in import order. A reference
    # resolves to the LATEST layer at or below the referring token's own layer
    # that defines it — and a token that re-exports a same-named token of an
    # earlier layer (`alias`'s `colors.base.white = {colors.base.white}`)
    # resolves to that earlier layer. That is the reading stylus gives the same
    # files when index.styl imports them in this order.
    #
    # A dangling or cyclic reference, or a non-hex terminal value, fails the
    # whole run rather than emitting a guess.
    top = len(stack) - 1 if below is None else below
    layer = next((i for i in range(top, -1, -1) if var_name in stack[i]), None)
    if layer is None:
        raise SystemExit(f"[ERROR] unresolved token reference: {var_name}"
                         + (f" (from {trail[0]})" if trail else ""))
    if (var_name, layer) in trail:
        raise SystemExit("[ERROR] reference cycle at " + var_name)
    value = stack[layer][var_name]
    if isinstance(value, str) and REF_RE.fullmatch(value.strip()):
        ref = ref_to_var(value.strip())
        nxt = layer - 1 if ref == var_name else layer
        return resolve_hex(ref, stack, nxt, trail + ((var_name, layer),))
    if isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value.strip()):
        return value.strip().lower()
    raise SystemExit(f"[ERROR] {var_name} resolves to {value!r}, which is not a #rrggbb colour")

def emit_nim(out_file):
    per_mode = {}
    for mode in NIM_MODES:
        per_mode[mode] = [
            {path_to_var(tp): t["value"]
             for tp, t in flatten_tokens(documents[name], mode=mode).items()}
            for name in layers]
    mapped_modes = set()
    def collect_modes(node):
        if isinstance(node, dict):
            if "$value" in node:
                mapped_modes.update(((node.get("$extensions") or {}).get("modes") or {}).keys())
                return
            for k, v in node.items():
                if not k.startswith("$"):
                    collect_modes(v)
    collect_modes(documents["mapped"])
    for mode in NIM_MODES:
        if mode not in mapped_modes:
            raise SystemExit(f"[ERROR] the mapped layer publishes no '{mode}' mode (has: {sorted(mapped_modes)})")
    colour_paths = sorted(
        [p for p, t in flats["mapped"].items() if t["type"] == "color"],
        key=lambda p: [sanitize_part(x) for x in p])
    idents = {}
    for p in colour_paths:
        ident = nim_ident(p)
        # Nim identifiers are style-insensitive after the first letter.
        key = ident[0] + ident[1:].lower().replace("_", "")
        if key in idents:
            raise SystemExit(f"[ERROR] tokens {'/'.join(idents[key])} and {'/'.join(p)} map to one Nim identifier {ident}")
        idents[key] = p
    lines = [
        "## AUTO-GENERATED by scripts/tokens-to-styl.sh from codetracer-design-system",
        "## (the `libs/codetracer-design-system` revision this checkout pins). DO NOT",
        "## EDIT: `just sync-design-tokens` regenerates it together with the stylus,",
        "## and `ci/test/design-tokens-fresh.sh` fails when either is stale.",
        "##",
        "## Every colour token of the `mapped` layer, resolved through `alias` and",
        "## `brand` to a `#rrggbb` hex, in each colour mode the design system",
        "## publishes. `$value` (what the desktop's stylus uses) equals the Dark mode.",
        "",
        "type",
        "  DesignMode* = enum",
        "    ## The design system's colour modes (`$extensions.modes`).",
    ]
    for mode in NIM_MODES:
        lines.append(f"    dm{mode} = \"{mode}\"")
    lines += ["", "  DesignToken* = enum", "    ## One member per `mapped` colour token, named by its token path."]
    for p in colour_paths:
        lines.append(f"    {nim_ident(p)} = \"{'/'.join(p)}\"")
    editor = editor_theme_entries(per_mode) if EDITOR_THEME_DIR else []
    if editor:
        lines.append("    # ---- the EDITOR THEME (PLAT-47): the desktop's Monaco theme")
        lines.append("    # documents, resolved per mode (see the generator's header).")
        for ident, path, _hexes in editor:
            lines.append(f"    {ident} = \"{path}\"")
    lines += ["", "const", "  DesignTokenCount* = " + str(len(colour_paths)),
              "    ## The design system's own `mapped` colour tokens; the editor-theme",
              "    ## members follow them in the enum.",
              "  DesignTokenHex*: array[DesignToken, array[DesignMode, string]] = ["]
    rows = [(nim_ident(p), [resolve_hex(path_to_var(p), per_mode[m]) for m in NIM_MODES])
            for p in colour_paths]
    rows += [(ident, hexes) for ident, _path, hexes in editor]
    for i, (ident, hexes) in enumerate(rows):
        sep = "," if i + 1 < len(rows) else "]"
        lines.append(f"    {ident}: [" + ", ".join(f'"{h}"' for h in hexes) + "]" + sep)
    if editor:
        rule_rows = [(path[len("editor-theme/rule/"):], ident)
                     for ident, path, _h in editor if path.startswith("editor-theme/rule/")]
        lines += ["",
                  "  EditorThemeRules*: array[" + str(len(rule_rows)) +
                  ", tuple[scope: string, token: DesignToken]] = [",
                  "    ## Every token rule of either Monaco theme, by scope (`\"\"` is the",
                  "    ## default rule). `editor_theme.editorScopeToken` resolves a scope",
                  "    ## against it the way Monaco does."]
        for i, (scope, ident) in enumerate(rule_rows):
            sep = "," if i + 1 < len(rule_rows) else "]"
            lines.append(f"    (scope: \"{scope}\", token: {ident}){sep}")
    lines.append("")
    Path(out_file).parent.mkdir(parents=True, exist_ok=True)
    Path(out_file).write_text("\n".join(lines), encoding="utf-8")
    print(f"[OK] wrote      : {Path(out_file).resolve()}")

EDITOR_THEME_FILES = {"Dark": "codetracerDark.json", "Light": "codetracerWhite.json"}
  # Which Monaco theme document is which design-system mode: the pair
  # `renderer.monacoThemeName` maps the desktop's dark and light themes onto.

EDITOR_GROUND_ROLES = [
    # (the `codetracer` block's key, the Nim identifier's suffix)
    ("ground", "Ground"),
    ("lineNumber", "LineNumber"),
    ("activeLineNumber", "ActiveLineNumber"),
    ("executionLine", "ExecutionLine"),
    ("selection", "Selection"),
]

def monaco_hex(value, where):
    v = str(value).strip()
    if not v.startswith("#"):
        v = "#" + v
    if re.fullmatch(r"#[0-9a-fA-F]{6}", v):
        return v.lower()
    raise SystemExit(f"[ERROR] {where}: {value!r} is not an opaque #rrggbb colour")

def resolve_scope(rules, scope):
    # Monaco's reading of a token scope against a theme's rules: the rule for
    # the scope itself, else the rule for its longest dotted prefix, else the
    # default rule (`""`).
    parts = scope.split(".") if scope else []
    while parts:
        key = ".".join(parts)
        if key in rules:
            return rules[key]
        parts.pop()
    if "" not in rules:
        raise SystemExit("[ERROR] an editor theme has no default ('') token rule")
    return rules[""]

def editor_theme_entries(per_mode):
    docs = {}
    for mode, name in EDITOR_THEME_FILES.items():
        path = Path(EDITOR_THEME_DIR) / name
        if not path.is_file():
            raise SystemExit(f"[ERROR] editor theme {path} is missing")
        docs[mode] = load_json(path)
    rules = {}
    scopes = set()
    for mode, doc in docs.items():
        rules[mode] = {}
        for r in doc.get("rules", []):
            if "foreground" not in r:
                continue
            scope = str(r.get("token", ""))
            rules[mode][scope] = monaco_hex(r["foreground"], f"{EDITOR_THEME_FILES[mode]} rule '{scope}'")
            scopes.add(scope)
    entries = []
    for key, suffix in EDITOR_GROUND_ROLES:
        hexes = []
        for mode in NIM_MODES:
            block = docs[mode].get("codetracer") or {}
            if key not in block:
                raise SystemExit(f"[ERROR] {EDITOR_THEME_FILES[mode]} has no codetracer.{key}")
            v = str(block[key]).strip()
            if REF_RE.fullmatch(v):
                hexes.append(resolve_hex(ref_to_var(v), per_mode[mode]))
            else:
                hexes.append(monaco_hex(v, f"{EDITOR_THEME_FILES[mode]} codetracer.{key}"))
        entries.append(("dtEditorTheme" + suffix, "editor-theme/" + key, hexes))
    seen = {}
    for scope in sorted(scopes):
        ident = "dtEditorThemeRule" + ("".join(
            w[0].upper() + w[1:].lower()
            for w in re.split(r"[^A-Za-z0-9]+", scope) if w) or "Default")
        key = ident[0] + ident[1:].lower()
        if key in seen:
            raise SystemExit(f"[ERROR] editor scopes '{seen[key]}' and '{scope}' map to one Nim identifier {ident}")
        seen[key] = scope
        hexes = [resolve_scope(rules[m], scope) for m in NIM_MODES]
        entries.append((ident, "editor-theme/rule/" + scope, hexes))
    return entries

if NIM_OUT:
    emit_nim(NIM_OUT)
PY
