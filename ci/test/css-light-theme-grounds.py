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

Then EVERY ground (added for GitHub issue #858).  The grounds above are the
six the window is mostly made of, and fixing them left dozens of rules that
still painted dark under the light theme: they carried hard-coded hex
(``#3c3c3c`` session tabs, ``#252526`` diff menu, ``var(--bg-hover,
#2a2b34)`` agent panels, ...) instead of a token, so no token change could
reach them and no check above could see them.  Every surface follows the
selected mode — a theme does not keep the other mode's surfaces — so the
light sheet is now read whole:

  3. every ``background`` / ``background-color`` / ``background-image``
     declaration of the LIGHT stylesheet, and every custom property
     (``--x``) that such a declaration reads through ``var(--x)``, is split into the colours it names — hex of
     3, 4, 6 or 8 digits, ``rgb()`` / ``rgba()`` (comma or space syntax), the
     dark CSS named colours, each stop of a gradient, and each ``var()``
     fallback (the fallback is what paints wherever the property is unset)
     unless the property is defined on ``:root``, which reaches every
     element, so the fallback cannot paint — and a colour whose WCAG
     relative luminance is below ``DARK_LUMINANCE`` fails;
  4. unless the colour already follows the mode — it is a design token's
     Light value, and the dark sheet does not paint that same colour at the
     same place (``follows_mode``: icons painted through a mask and
     text-colour hairlines are ink whose Light value the design system made
     dark, not grounds; a colour hard-coded for every theme paints the same
     in both sheets and is caught), and the rule is shaped like ink: it
     paints through a mask or a glyph image, or one of its sides is a line's
     or a dot's (``ink_shaped``), so a text or icon token spread over a pane
     is still a dark ground —
     or the rule's selector is in ``MODE_INDEPENDENT``, matched EXACTLY
     against one member of the rule's selector list, never by substring, so
     a new rule cannot hide under an old entry.  The list is self-checking:
     an entry whose selector no longer appears in the light sheet, or no
     longer paints dark there, fails too, so it cannot outlive its rule.

Translucent colours are graded by what they PAINT: composited over the light
sheet's own window ground (``body``'s background) with ordinary source-over
alpha in sRGB, as the browser blends them.  An alpha-0 colour is the ground
itself, a faint tint is nearly so, and a scrim is graded by the grey it
leaves: ``rgba(0,0,0,.5)`` lands mid-grey and passes, ``rgba(0,0,0,.9)``
lands near-black and fails.  This is the window ground, not each element's
real backdrop (which is not knowable statically), and it is the ground a
dark-on-light defect shows up against.

Values this cannot grade are skipped, and the reasons are deliberate:
``url()`` images; ``transparent``, ``none``, ``inherit``, ``currentColor``;
and unresolved identifiers, which ``ci/test/css-token-resolution.sh`` owns.
An element's own ``opacity`` is not folded into its colour: it dims the
element's text with it, so it is not a property of the ground alone.

The web IDE ships no light sheet of its own: its deployment carries the
dark ``_electron`` sheet (``web_deployment.nim`` ``rendererThemeStylesPath``)
and ``renderer.nim``'s ``loadTheme`` resolves any other theme to the same
``{name}_theme_electron.css`` the desktop loads, so the light sheet graded
here IS the web IDE's.  The Tupfile's other light output,
``default_white_theme.css``, is the palette file compiled alone; it defines
variables only and compiles to an empty sheet.

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

# Below this WCAG relative luminance a colour is a DARK ground.  0.05 is the
# threshold #858 was measured with.  Every Light-mode `surface/primary/*` and
# `surface/base/*` token sits far above it (the darkest, `surface/primary/
# disabled` #7a756a, is 0.18), so no ground taken from the Light tokens comes
# near the line.
DARK_LUMINANCE = 0.05

# Surfaces that are dark in BOTH modes on purpose, as any media viewer's
# stage is: a video or a captured frame is shown on near-black whatever the
# chrome around it paints, so its own pixels are judged against the ground
# they were recorded on.  The last two are controls drawn ON media rather
# than beside it — the loupe's pixel readout floats over the video stage, the
# remove chip over a pasted image's thumbnail — so they keep a dark chip with
# light text that reads over any pixels, in either mode.  Keys are the
# COMPILED selectors, matched exactly; see check 4 in the header.
MODE_INDEPENDENT = {
    ".video-player-component .video-player-stage":
        "the video stage (components/video_player.styl)",
    ".video-player-component .video-player-loupe-canvas":
        "the video loupe's magnified pixels (components/video_player.styl)",
    ".frame-viewer-component .frame-viewer-frame-stage":
        "the captured-frame stage (components/frame_viewer.styl)",
    ".frame-viewer-component .frame-viewer-image":
        "the captured frame (components/frame_viewer.styl)",
    ".video-player-component .video-player-loupe-readout":
        "the loupe's pixel readout, over the video stage (components/video_player.styl)",
    ".agent-ha-container .agent-paste-thumb .agent-paste-remove:hover":
        "the remove chip over a pasted image's thumbnail (components/agent_activity.styl)",
}

# `background-image` too: a gradient written there paints exactly as one in
# the shorthand does (the welcome screen's upload ring was one).
BACKGROUND_PROPS = ("background", "background-color", "background-image")

# The most a side of an ink rule may measure: a hairline, a trace line or a
# dot, not a pane.  The call tree's dots are 0.3125em, its lines 0.0625em; the
# trace chevron's baseline and the call trace's loading sweep are 2px tall.
INK_MAX_SIDE = {"px": 8.0, "em": 0.5, "rem": 0.5}
INK_SIDE_RE = re.compile(r"(\d*\.?\d+)(px|em|rem)")

# The CSS named colours (https://www.w3.org/TR/css-color-4/#named-colors)
# whose relative luminance is below DARK_LUMINANCE.  The others cannot paint
# a dark ground, so they need not be recognised.
DARK_NAMED = {
    "black": "#000000", "navy": "#000080", "darkblue": "#00008b",
    "mediumblue": "#0000cd", "midnightblue": "#191970", "maroon": "#800000",
    "indigo": "#4b0082",
}

HEX_RE = re.compile(r"#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b")
RGB_RE = re.compile(r"rgba?\(([^()]*)\)", re.I)
VAR_READ_RE = re.compile(r"var\(\s*(--[-a-zA-Z0-9_]+)")

RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}")
DECL_RE = re.compile(r"([-a-zA-Z0-9_]+)\s*:\s*([^;]+);")


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


def parse_rgb_channels(args):
    """(r, g, b, alpha) from the inside of rgb()/rgba(), comma or space
    syntax (`rgba(0,0,0,.5)`, `rgb(0 0 0 / 50%)`), or None."""
    parts = [p for p in re.split(r"[\s,/]+", args.strip()) if p]
    if len(parts) not in (3, 4):
        return None
    try:
        rgb = [round(float(p[:-1]) * 2.55) if p.endswith("%") else round(float(p))
               for p in parts[:3]]
        alpha = 1.0
        if len(parts) == 4:
            a = parts[3]
            alpha = float(a[:-1]) / 100 if a.endswith("%") else float(a)
    except ValueError:
        return None
    return tuple(max(0, min(255, c)) for c in rgb) + (max(0.0, min(1.0, alpha)),)


def colours_in(value):
    """Every colour `value` names, as (spelling, r, g, b, alpha): each hex,
    each rgb()/rgba(), each dark named colour — wherever it sits, so gradient
    stops and var() fallbacks are included.  `url()` arguments are cut first:
    an image cannot be graded, and a `#fragment` or a file name in one is not
    a colour."""
    value = re.sub(r"url\([^)]*\)", "url()", value)
    out = []
    for m in HEX_RE.finditer(value):
        h = m.group(1).lower()
        if len(h) in (3, 4):
            h = "".join(c * 2 for c in h)
        alpha = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
        out.append((m.group(0),) + tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,))
    for m in RGB_RE.finditer(value):
        ch = parse_rgb_channels(m.group(1))
        if ch:
            out.append((m.group(0),) + ch)
    for word in re.findall(r"(?<![-#\w])([a-zA-Z]+)(?![-\w(])", value):
        if word.lower() in DARK_NAMED:
            h = DARK_NAMED[word.lower()]
            out.append((word,) + tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) + (1.0,))
    return out


def drop_fallbacks(value, defined):
    """`value` with the fallback cut out of every `var(--x, fallback)` whose
    `--x` is in `defined`.  Parentheses are balanced by hand because a
    fallback can itself be a function (`var(--x, rgba(0, 0, 0, .5))`)."""
    out, i = [], 0
    for m in VAR_READ_RE.finditer(value):
        if m.group(1) not in defined or m.start() < i:
            continue
        depth, j = 1, value.index("(", m.start()) + 1
        while j < len(value) and depth:
            depth += {"(": 1, ")": -1}.get(value[j], 0)
            j += 1
        out.append(value[i:m.start()] + f"var({m.group(1)})")
        i = j
    return "".join(out) + value[i:]


def composite(r, g, b, alpha, ground_hex):
    """Source-over blend of a colour on `ground_hex`, as the browser paints
    it, rounded to an opaque #rrggbb."""
    gr, gg, gb = (int(ground_hex[i:i + 2], 16) for i in (1, 3, 5))
    mix = [round(c * alpha + d * (1 - alpha)) for c, d in ((r, gr), (g, gg), (b, gb))]
    return "#" + "".join(f"{c:02x}" for c in mix)


def dark_grounds(decls, page_ground):
    """Every dark colour among the sheet's background declarations — and the
    custom properties they read — as a dict with the declaration's
    `selector`, `prop`, `value`, its `occurrence` (how many declarations of
    that property on that selector came before it, for pairing with the
    other sheet), the colour's `index` within the value, its `spelling`, the
    hex it `painted` on `page_ground`, and that hex's `lum`inance."""
    read_vars = {v for _, p, val, _ in decls if p in BACKGROUND_PROPS
                 for v in VAR_READ_RE.findall(val)}
    # A custom property defined on `:root` reaches every element, so a
    # `var()` fallback for it never paints; its `:root` value is graded
    # instead, as a property a background reads.
    on_root = {p for s, p, _, _ in decls if s == ":root" and p.startswith("--")}
    seen = {}
    out = []
    for selector, prop, value, _ in decls:
        if prop not in BACKGROUND_PROPS and prop not in read_vars:
            continue
        occurrence = seen.get((selector, prop), 0)
        seen[(selector, prop)] = occurrence + 1
        for index, (spelling, r, g, b, alpha) in enumerate(
                colours_in(drop_fallbacks(value, on_root))):
            painted = composite(r, g, b, alpha, page_ground)
            lum = luminance(painted)
            if lum < DARK_LUMINANCE:
                out.append(dict(selector=selector, prop=prop, value=value,
                                occurrence=occurrence, index=index, spelling=spelling,
                                rgba=(r, g, b, alpha), painted=painted, lum=lum))
    return out


def follows_mode(ground, dark_decls, tokens):
    """The design tokens whose Light value `ground`'s colour is, provided the
    DARK sheet does not paint that same colour at the same place (the same
    colour of the same declaration, or no such declaration at all); else an
    empty list.  Several tokens can share a value, and the compiled sheet
    does not say which one the source named, so all are returned.

    Such a colour is dark in the light sheet because the design system made
    that token's Light value dark: it is ink, not ground.  Examples are an
    icon painted through a mask (``colors-ui-icon-primary-default``, Light
    ``#353430``), a hairline or a progress sweep in a text colour
    (``colors-ui-text-primary-label``), and the call tree's trace lines.
    It comes from the generator's Light mode, which is what this check asks
    of every colour; whether the token suits its role is a design-system
    question, not this check's.

    The condition on the dark sheet is what keeps a hard-coded colour out: a
    colour written once for every theme paints the same in both sheets.  A
    declaration the dark sheet does not have at all was written for the
    light mode alone and passes; one it has must paint a different colour
    there.  It does not ask the dark sheet for the token's Dark value,
    because the dark palette still writes hex of its own (the trace lines
    are ``#E8E8E8`` there) and the dark sheets must not change here.

    What this cannot see is the token's ROLE: the compiled sheet does not
    record which variable a value came from.  So the caller also asks the
    rule's SHAPE (``ink_shaped``): a token's dark Light value spread over a
    pane fails there, while one drawn as a mask, a glyph, a line or a dot
    passes."""
    hits = [v for s, p, v, _ in dark_decls if s == ground["selector"] and p == ground["prop"]]
    r, g, b, alpha = ground["rgba"]
    if ground["occurrence"] < len(hits):
        dark_colours = colours_in(hits[ground["occurrence"]])
        # The dark sheet has this declaration: it must paint a colour here,
        # and a different one.  A declaration whose dark value names no
        # colour (an unresolved palette variable, say) proves nothing about
        # where the light colour came from.
        if ground["index"] >= len(dark_colours) or \
                tuple(dark_colours[ground["index"]][1:]) == (r, g, b, alpha):
            return []
    light_hex = "#" + "".join(f"{c:02x}" for c in (r, g, b))
    # `colors-ui-*` first: the chrome's own tokens name the role better in
    # the report than the editor-syntax ones that share their values.
    return sorted((var for var, (tok_dark, tok_light) in tokens.items()
                   if tok_light == light_hex and tok_dark != tok_light),
                  key=lambda v: (not v.startswith("colors-ui-"), v))


def ink_shaped(selector, decls):
    """Whether the rule for `selector` draws INK rather than a ground: it
    paints through a mask (``mask`` / ``mask-*``, with or without the
    ``-webkit-`` prefix), or draws an image over its fill (a non-``none``
    ``background-image`` naming no colour: the slider handle's grip glyph), or
    its ``width`` or ``height`` is at most ``INK_MAX_SIDE`` — a line or a dot.

    A design token's Light value passes ``follows_mode`` whatever its role,
    so a text token painting a whole pane would pass there; this is what
    stops it.  A custom property is never ink-shaped (``:root`` has no
    shape), so a dark Light value read through ``var()`` fails: give it a
    ground token, or move the colour into the rule that draws the ink."""
    for s, p, v, _ in decls:
        if s != selector:
            continue
        bare = p[len("-webkit-"):] if p.startswith("-webkit-") else p
        if bare == "mask" or bare.startswith("mask-"):
            return True
        if p == "background-image" and v.strip().lower() != "none" and not colours_in(v) \
                and not re.search(r"gradient\(", v, re.I):
            return True
        if p in ("width", "height"):
            m = INK_SIDE_RE.fullmatch(v.strip())
            if m and float(m.group(1)) <= INK_MAX_SIDE[m.group(2)]:
                return True
    return False


def check_every_ground(light_decls, dark_decls, tokens, failures):
    """Checks 3 and 4 of the header over the LIGHT sheet's declarations."""
    page_ground = norm_hex(winning(light_decls, "body", "background-color"))
    if not page_ground:
        failures.append("light `body` has no opaque hex background-color to composite "
                        "translucent grounds over")
        return
    dark = dark_grounds(light_decls, page_ground)
    allowed, inked, offending = [], [], []
    for d in dark:
        if d["selector"] in MODE_INDEPENDENT:
            allowed.append(d)
            continue
        candidates = follows_mode(d, dark_decls, tokens)
        if candidates and ink_shaped(d["selector"], light_decls):
            inked.append((d, candidates))
        else:
            offending.append((d, candidates))
    for d, candidates in offending:
        shown = d["spelling"]
        if d["painted"] != norm_hex(shown):
            shown += f" (paints {d['painted']} on the window ground)"
        why = ""
        if candidates:
            why = (f"; it is the Light value of {candidates[0]}, but the rule is not "
                   f"shaped like ink (no mask or glyph image, no side of a line or a dot), "
                   f"so it paints a ground")
        failures.append(
            f"light stylesheet paints `{d['selector']} {{ {d['prop']}: {d['value']} }}` dark: "
            f"{shown}, luminance {d['lum']:.3f} < {DARK_LUMINANCE}{why}")
    for selector, reason in MODE_INDEPENDENT.items():
        if not any(s == selector for s, _, _, _ in light_decls):
            failures.append(f"MODE_INDEPENDENT lists `{selector}` ({reason}), which no "
                            f"longer appears in the light stylesheet: drop the entry")
        elif not any(d["selector"] == selector for d in allowed):
            failures.append(f"MODE_INDEPENDENT lists `{selector}` ({reason}), which no "
                            f"longer paints a dark ground in the light stylesheet: "
                            f"drop the entry")
    for d, candidates in inked:
        names = " / ".join(candidates[:3]) + (" / ..." if len(candidates) > 3 else "")
        print(f"  ok   light {d['selector']} {{ {d['prop']}: {d['spelling']} }} is the Light "
              f"value of {names} (ink that follows the mode, not a ground)")
    for d in allowed:
        print(f"  ok   light {d['selector']} {{ {d['prop']}: {d['spelling']} }} dark on purpose "
              f"({MODE_INDEPENDENT[d['selector']]})")
    if not offending:
        print(f"  ok   light: no other background paints darker than luminance "
              f"{DARK_LUMINANCE} on the window ground {page_ground}")


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

    check_every_ground(sheets["light"], sheets["dark"], tokens, failures)

    if failures:
        print(f"FAIL: {len(failures)} light-theme ground(s) wrong:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"OK: {len(GROUNDS)} grounds paint their design-token value in each mode, "
          f"the light editor's text is readable, and no light background is dark "
          f"but ink from the Light tokens and the {len(MODE_INDEPENDENT)} "
          f"mode-independent media surfaces")
    return 0


if __name__ == "__main__":
    sys.exit(main())
