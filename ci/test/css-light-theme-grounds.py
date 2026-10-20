#!/usr/bin/env python3
"""css-light-theme-grounds.py — the light theme paints its grounds light.

WHY THIS EXISTS
---------------
With ``theme: "default_white"`` the desktop applied Monaco's light
``codetracerWhite`` theme, but every panel, the editor's ground included,
stayed on the dark surfaces: ``#282828`` behind the editor and ``#1b1b1b``
splitters, exactly as in the dark theme.  The panel rules read the generated
design-token variables (``src/frontend/styles/generated/*.styl``), and those
carried only the design system's DEFAULT value, which is its Dark mode, into
BOTH stylesheets.  codetracerWhite's text (``#464646``) then sat on
``#282828``: 1.56:1.

Nothing failed.  Stylus compiled both themes clean, the token-resolution
guard saw only resolved values, and the light build differed from the dark one
only in the handful of rules that read the theme file's own SCREAMING_CASE
palette.  The defect is a property of the compiled LIGHT stylesheet, so that
is what this reads.

WHAT IT CHECKS
--------------
Each GROUND below is a rule the window paints a surface with, and the
design-token variable that rule paints it from.  For each one:

  1. the DARK stylesheet paints it with the token's Dark value — the
     instrument check: it proves the selector and the token named here are
     the ones the stylesheet really uses, so a renamed rule fails here rather
     than passing vacuously;
  2. the LIGHT stylesheet paints it with the token's LIGHT value — the
     design system's ``Light`` mode of the ``mapped`` layer, the palette the
     terminal's light chrome already paints from.

Token values come from ``src/frontend/styles/generated/design_tokens.nim``,
which carries every ``mapped`` colour token resolved in both modes and which
``ci/test/design-tokens-fresh.sh`` holds to the pinned design system.

Then the editor: Monaco's own surface is transparent over its pane (the
``.monaco-editor-background`` rule in ``components/text_editor.styl``), so the
editor's ground IS the panel ground, and the light theme's default text
(``codetracerWhite.json``'s default token rule) must be readable on it —
WCAG 2.x AA for body text, 4.5:1.

Usage: css-light-theme-grounds.py --repo-root DIR --light CSS --dark CSS
"""

import argparse
import json
import re
import sys
from pathlib import Path

# (selector, property, design-token variable, what it is).  The selector is
# matched EXACTLY against one member of a rule's selector list.
GROUNDS = [
    ("body", "background-color", "colors-ui-surface-primary-default",
     "the window's ground"),
    (".lm_content", "background-color", "colors-ui-surface-base-panel",
     "every panel's ground, and the editor's (Monaco is transparent over it)"),
    (".lm_splitter", "background", "colors-ui-surface-primary-default",
     "the splitters between panels"),
    (".lm_tab", "background-color", "colors-ui-surface-base-panel",
     "a pane tab"),
    (".margin-view-overlays div", "background-color", "colors-ui-surface-base-panel",
     "the editor's gutter"),
    (".event-selected", "background", "colors-editor-surface-select",
     "a selected row (the call trace's, the event log's)"),
]

EDITOR_GROUND_SELECTOR = ".lm_content"
MONACO_SURFACE_SELECTOR = ".monaco-editor-background"
MIN_TEXT_CONTRAST = 4.5

RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}")
DECL_RE = re.compile(r"([-a-zA-Z]+)\s*:\s*([^;]+);")


def parse_css(text):
    """Every (selector, property, value, important) in source order."""
    out = []
    for sel_text, body in RULE_RE.findall(text):
        selectors = [re.sub(r"\s+", " ", s).strip() for s in sel_text.split(",")]
        for prop, value in DECL_RE.findall(body):
            value = value.strip()
            important = value.endswith("!important")
            value = value[: -len("!important")].strip() if important else value
            for s in selectors:
                out.append((s, prop.strip().lower(), value, important))
    return out


def winning(decls, selector, prop):
    """The value the cascade gives `prop` among rules with exactly `selector`:
    the last !important declaration, else the last one.  Same selector, same
    specificity, so source order decides."""
    hits = [(v, imp) for s, p, v, imp in decls if s == selector and p == prop]
    if not hits:
        return None
    important = [v for v, imp in hits if imp]
    return important[-1] if important else hits[-1][0]


def norm_hex(value):
    m = re.fullmatch(r"#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})", (value or "").strip())
    if not m:
        return None
    h = m.group(1).lower()
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return "#" + h


def token_var(path):
    # scripts/tokens-to-styl.sh's `path_to_var`: each path part lower-cased,
    # runs of anything but [a-z0-9] collapsed to one hyphen, parts joined by
    # hyphens.
    parts = []
    for part in path.split("/"):
        p = re.sub(r"[^a-z0-9]+", "-", part.strip().lower().replace("&", " and "))
        parts.append(re.sub(r"-{2,}", "-", p).strip("-") or "token")
    return "-".join(parts)


def load_tokens(nim_file):
    """{stylus variable: (dark hex, light hex)} from design_tokens.nim."""
    text = nim_file.read_text(encoding="utf-8")
    paths = dict(re.findall(r'^\s+(dt\w+) = "([^"]+)"$', text, re.M))
    hexes = re.findall(r'^\s+(dt\w+): \["(#[0-9a-f]{6})", "(#[0-9a-f]{6})"\]', text, re.M)
    modes = re.search(r"DesignMode\* = enum(.*?)\n\n", text, re.S)
    if not modes or re.findall(r"dm(\w+)", modes.group(1))[:2] != ["Dark", "Light"]:
        raise SystemExit(f"FAIL: {nim_file}: expected DesignMode members dmDark, dmLight in that order")
    out = {}
    for ident, dark, light in hexes:
        if ident in paths:
            out[token_var(paths[ident])] = (dark, light)
    if not out:
        raise SystemExit(f"FAIL: {nim_file}: no resolved tokens read (has its format changed?)")
    return out


def luminance(hex_colour):
    def chan(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True, type=Path)
    ap.add_argument("--light", required=True, type=Path)
    ap.add_argument("--dark", required=True, type=Path)
    args = ap.parse_args()

    tokens = load_tokens(args.repo_root / "src/frontend/styles/generated/design_tokens.nim")
    sheets = {}
    for name, path in (("dark", args.dark), ("light", args.light)):
        text = path.read_text(encoding="utf-8")
        if not text.strip():
            raise SystemExit(f"FAIL: {path} is empty — nothing to grade")
        sheets[name] = parse_css(text)

    failures = []
    for selector, prop, var, what in GROUNDS:
        if var not in tokens:
            failures.append(f"{var} is not a mapped colour token in design_tokens.nim")
            continue
        dark_hex, light_hex = tokens[var]
        for mode, want in (("dark", dark_hex), ("light", light_hex)):
            got = winning(sheets[mode], selector, prop)
            got_hex = norm_hex(got)
            if got_hex == want:
                print(f"  ok   {mode:5} {selector} {{ {prop}: {want} }}  ({var}, {what})")
                continue
            why = ""
            if mode == "light" and got_hex == dark_hex:
                why = f" — the token's DARK value; its Light value is {light_hex}"
            failures.append(
                f"{mode} stylesheet paints {what} (`{selector} {{ {prop} }}`) "
                f"{got!s}, not {var}'s {mode.capitalize()} value {want}{why}")

    # The editor's ground: Monaco transparent over its pane, the pane's ground
    # under the light theme's default text.
    surface = winning(sheets["light"], MONACO_SURFACE_SELECTOR, "background-color")
    if surface != "transparent":
        failures.append(
            f"light stylesheet paints `{MONACO_SURFACE_SELECTOR}` {surface!s}, not transparent: "
            f"the editor's ground is no longer the panel ground this check grades")
    theme = json.loads((args.repo_root / "src/public/third_party/monaco-themes/themes/"
                        "customThemes/json/codetracerWhite.json").read_text(encoding="utf-8"))
    default_rule = next((r for r in theme.get("rules", []) if r.get("token", None) == ""), None)
    ground = norm_hex(winning(sheets["light"], EDITOR_GROUND_SELECTOR, "background-color"))
    text_hex = norm_hex("#" + str(default_rule.get("foreground", "")).lstrip("#")) if default_rule else None
    if not text_hex:
        failures.append("codetracerWhite.json has no opaque default ('') token rule foreground")
    elif not ground:
        failures.append(f"light `{EDITOR_GROUND_SELECTOR}` has no hex ground to grade text against")
    else:
        ratio = contrast(text_hex, ground)
        verdict = "ok  " if ratio >= MIN_TEXT_CONTRAST else "FAIL"
        print(f"  {verdict} light editor text {text_hex} on ground {ground}: {ratio:.2f}:1 "
              f"(floor {MIN_TEXT_CONTRAST}:1)")
        if ratio < MIN_TEXT_CONTRAST:
            failures.append(
                f"the light editor's default text {text_hex} on its ground {ground} is "
                f"{ratio:.2f}:1, below {MIN_TEXT_CONTRAST}:1")

    if failures:
        print(f"FAIL: {len(failures)} light-theme ground(s) wrong:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"OK: {len(GROUNDS)} grounds paint their design-token value in each mode, "
          f"and the light editor's text is readable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
