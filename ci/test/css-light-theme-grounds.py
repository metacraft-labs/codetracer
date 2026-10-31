#!/usr/bin/env python3
"""css-light-theme-grounds.py — the light theme paints its grounds light, and
the text and outlines on them dark enough to read.

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
     or a dot's (``ink_shaped``; a custom property counts when every rule
     that reads it into a background is so shaped, ``read_as_ink``), so a
     text or icon token spread over a pane is still a dark ground —
     or the rule's selector is in ``MODE_INDEPENDENT``, matched EXACTLY
     against one member of the rule's selector list, never by substring, so
     a new rule cannot hide under an old entry.  The list is self-checking:
     an entry whose selector no longer appears in the light sheet, or no
     longer paints dark there, fails too, so it cannot outlive its rule.

Then EVERY foreground (added for the light theme's pale text and white
checkbox outlines, codetracer-pm issue 2026-10-21).  Making every ground
light left the ink written for the dark ground where it was: caption text
``#b0b0b0`` (2:1 on the light tab bar), pale cyan ``#a5f3fc`` (1.2:1), and
checkbox strokes in translucent white (1.0:1).  Text and outlines drawn on a
light ground are part of that surface, so:

  5. every ``color``, ``caret-color``, ``text-decoration(-color)``,
     ``outline(-color)``, ``column-rule(-color)`` and ``border*`` colour
     (shorthand, side, logical side, ``-color`` longhand; placeholder text is
     ``color`` on a ``::placeholder`` selector) of the LIGHT stylesheet, and
     every custom property such a declaration reads, is graded against the
     GROUND it sits on, and one below ``MIN_FOREGROUND_CONTRAST`` (3:1, WCAG
     2.x's large-text and non-text floor; its comment says why not 4.5:1)
     fails.  The ground is found from the selector alone
     (``foreground_ground``): the element's own background (its selector,
     then that selector without the last pseudo-class or pseudo-element),
     else each ancestor the selector names, innermost first, else the
     window ground; translucent layers composite outward, ``var()`` resolves
     through the element's and its ancestors' custom properties and then
     ``:root``.  A border, an outline or a column rule is an EDGE and reads
     against what surrounds the element, so its own fill is skipped.  Where
     the markup puts an element on a surface its selector does not name, the
     commented, self-checking ``SITS_ON`` map says which, and the colour is
     graded against that surface instead (it is not exempted);
  6. unless the colour follows the mode: it is opaque and is a design
     token's Light value that the dark sheet does not paint at the same place
     (``follows_mode``, as in check 4) and that token may paint the
     property's role (``fit_for_role``: text is never painted in a surface,
     border or divider token, the role check 4 asks of a rule's shape), or
     it is a token of the property's role — ``colors-ui-border-*`` for an
     edge, ``colors-ui-text-*`` / ``colors-ui-icon-*`` for text — that has
     the same value in both modes (``role_tokens``: ``border/information``
     is #93c5fd in each, and whether that suits a light ground is the design
     system's question); in both cases the tokens for ink on a coloured
     surface (``*-on-color*``, ``*-on-action*``, ``border/contrast``) count
     only on a ground the design system made for them (the Light value of an
     action, alert or on-colour surface token), never on the window ground
     or any other surface —
     or it is drawn on a MODE_INDEPENDENT surface, dark in both modes, whose
     foregrounds the light theme does not change and this check does not
     grade, or its rule is in the self-checking ``UNRENDERED`` list (markup
     nothing renders, cross-checked against the footer guard's own list).

Translucent colours are graded by what they PAINT: composited over the light
sheet's own window ground (``body``'s background) with ordinary source-over
alpha in sRGB, as the browser blends them.  An alpha-0 colour is the ground
itself, a faint tint is nearly so, and a scrim is graded by the grey it
leaves: ``rgba(0,0,0,.5)`` lands mid-grey and passes, ``rgba(0,0,0,.9)``
lands near-black and fails.  This is the window ground, not each element's
real backdrop (which is not knowable statically), and it is the ground a
dark-on-light defect shows up against.
A translucent FOREGROUND is composited the same way over the ground check 5
finds for it, and the contrast is taken between the two results.

Values this cannot grade are skipped, and the reasons are deliberate:
``url()`` images; ``transparent``, ``none``, ``inherit``, ``currentColor``;
and unresolved identifiers, which ``ci/test/css-token-resolution.sh`` owns.
An element's own ``opacity`` is not folded into its colour: it dims the
element's text with it, so it is not a property of the ground alone.  A
foreground's ground is what its selector says about the DOM and no more
(plus ``SITS_ON``): an ancestor the selector does not name is not knowable
statically, and the window ground stands for it, as it does for check 3.

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

# Watch rows share the Variables pane's ground. Pin their semantic colours,
# including the active toggle's ink: a contrast-only check could miss pale
# active text while its accidentally dark fill still makes it readable.
# The last column preserves the dark stylesheet's existing appearance; the
# light column is resolved from the design system, never copied from output.
WATCH_COLOURS = [
    (".isonim-state .hide-other-process-watches", "border",
     "colors-ui-border-primary", "#3a3a3a"),
    (".isonim-state .hide-other-process-watches", "color",
     "colors-ui-text-primary-body-subtle", "#b4b4b4"),
    (".isonim-state .hide-other-process-watches.active", "background-color",
     "colors-ui-surface-base-card", "#262626"),
    (".isonim-state .hide-other-process-watches.active", "color",
     "colors-ui-text-primary-body", "#f3f3f3"),
    (".isonim-state .value-watch.watch-invalid .value-expanded-text", "color",
     "colors-ui-text-primary-body-subtle", "#b4b4b4"),
    (".isonim-state .value-watch.watch-pending .value-expanded-text", "color",
     "colors-ui-text-primary-body-subtle", "#b4b4b4"),
]

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

# The properties that draw a FOREGROUND: text, its caret and decoration, and
# the edges an element is outlined with (a border shorthand or any side or
# logical side of it, its colour longhands, an outline, a column rule).
# `border-radius`, `-width`, `-style` and `-collapse` name no colour and do not
# match.  Placeholder text is `color` on a `::placeholder` selector.
FOREGROUND_PROP_RE = re.compile(
    r"color|caret-color|text-decoration(-color)?|outline(-color)?|column-rule(-color)?"
    r"|border(-(top|right|bottom|left|block|inline)(-(start|end))?)?(-color)?")

# The least contrast a foreground may have with its ground.  3:1 is WCAG 2.x's
# floor for large text (SC 1.4.3) and for the graphical objects and component
# boundaries a border or an outline draws (SC 1.4.11):
# https://www.w3.org/TR/WCAG21/#contrast-minimum and
# https://www.w3.org/TR/WCAG21/#non-text-contrast.  Not the 4.5:1 for body
# text, which the editor's own text is held to above: the compiled sheet does
# not say how large any text is, and the design system's own Light text
# tokens sit under 4.5:1 on its own window ground (`text/primary/caption`
# #7a756a is 4.25:1 on #f8f6f2, `text/success/primary` 3.05:1), so 4.5:1
# here would grade the design system rather than whether a rule follows the
# mode.  The defect this guards against — ink written for the dark ground —
# sits far below 3:1 on a light one (#b0b0b0 2.0:1, #a5f3fc 1.2:1, a white
# hairline 1.0:1).
MIN_FOREGROUND_CONTRAST = 3.0

# Where the DOM puts a foreground on a surface its selector does not name.
# A compiled selector says which ancestors it requires, and nothing else, so
# the overlay text of a video stage (`.video-player-component
# .video-player-empty`) cannot be seen to sit on that stage
# (`.video-player-component .video-player-stage`, dark in both modes, see
# MODE_INDEPENDENT).  Each entry names the surface the element is a child of
# in the markup, and the foreground is then graded against THAT surface's
# paint: it is not exempted, it must still read there.  Keys and values are
# compiled selectors, matched exactly.  Self-checking: an entry whose key no
# longer appears in the light sheet, or that no longer turns any colour from
# failing on the window ground to passing on its surface, fails.
SITS_ON = {
    # viewmodel/views/isonim_video_player_view.nim: the empty and loading
    # notices and the startup chip are children of the stage.
    ".video-player-component .video-player-empty":
        ".video-player-component .video-player-stage",
    ".video-player-component .video-player-loading":
        ".video-player-component .video-player-stage",
    ".video-player-component .video-player-startup":
        ".video-player-component .video-player-stage",
    # The spinner and its label are children of the startup chip.
    ".video-player-component .video-player-startup-spinner":
        ".video-player-component .video-player-startup",
    ".video-player-component .video-player-startup-label":
        ".video-player-component .video-player-startup",
    # The loupe is a child of the stage; its canvas's ring is drawn on it.
    ".video-player-component .video-player-loupe-canvas":
        ".video-player-component .video-player-stage",
    # The RGBA line is a readout chip itself (`video-player-loupe-readout
    # video-player-loupe-rgba` on one element), so it has the readout's
    # ground.
    ".video-player-component .video-player-loupe-rgba":
        ".video-player-component .video-player-loupe-readout",
}

# Foreground rules whose markup nothing in the frontend renders, so a pale
# colour in them never meets a pixel.  Each is the compiled selector of an
# entry in the footer guard's `UNREACHABLE_SELECTORS`
# (src/tests/gui/page-objects/status-footer-contrast.ts), which asserts
# against the frontend sources that the class is still unrendered and holds
# the evidence; status_bar.styl says why the colour is left alone rather than
# adjusted.  Self-checking: an entry must still be listed there, still appear
# in the light sheet, and still carry a colour this check would fail.
UNRENDERED = {
    "#status #status-base .whitespace-set": "whitespace-set",
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
    stops it.  A custom property has no shape of its own, so a dark Light
    value read through ``var()`` passes only when every rule that reads it
    into a background is ink-shaped (``read_as_ink``); otherwise give it a
    ground token, or move the colour into the rule that draws the ink.
    `inline-size` / `block-size` count as `width` / `height`, and a side
    written as `var(--x)` counts when every definition of `--x` is that
    small (``side_is_ink``)."""
    for s, p, v, _ in decls:
        if s != selector:
            continue
        bare = p[len("-webkit-"):] if p.startswith("-webkit-") else p
        if bare == "mask" or bare.startswith("mask-"):
            return True
        if p == "background-image" and v.strip().lower() != "none" and not colours_in(v) \
                and not re.search(r"gradient\(", v, re.I):
            return True
        if p in ("width", "height", "inline-size", "block-size") and \
                side_is_ink(v, decls):
            return True
    return False


def side_is_ink(value, decls):
    """Whether a `width` / `height` (or its logical twin) `value` is at most
    ``INK_MAX_SIDE``: a length, or a `var(--x)` every definition of which in
    the sheet is such a length.  Every definition, because the compiled
    sheet does not say which one reaches the element (the checkmark's
    `--ct-checkmark-minus-height` is 0.125em wherever it is set)."""
    m = INK_SIDE_RE.fullmatch(value.strip())
    if m:
        return float(m.group(1)) <= INK_MAX_SIDE[m.group(2)]
    m = re.fullmatch(r"var\(\s*(--[-a-zA-Z0-9_]+)\s*\)", value.strip())
    if not m:
        return False
    defs = [v for _, p, v, _ in decls if p == m.group(1)]
    return bool(defs) and all(INK_SIDE_RE.fullmatch(v.strip()) and
                              side_is_ink(v, decls) for v in defs)


def read_as_ink(prop, decls):
    """Whether custom property `prop` is read into a background only by
    rules shaped like ink (``ink_shaped``): then it is an ink colour carried
    in a variable (the checkmark's `--ct-checkmark-icon`, which draws both
    the tick's strokes and the indeterminate dash), not a ground."""
    readers = {s for s, p, v, _ in decls
               if p in BACKGROUND_PROPS and prop in VAR_READ_RE.findall(v)}
    return bool(readers) and all(ink_shaped(s, decls) for s in readers)


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
        if candidates and (ink_shaped(d["selector"], light_decls) or
                           (d["prop"].startswith("--") and read_as_ink(d["prop"], light_decls))):
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


def split_compounds(selector):
    """`selector` cut at its top-level combinators, as a list of
    (combinator, compound): the first combinator is ``""``, a descendant one
    is ``" "``.  Brackets and parentheses are respected, so
    ``[data-x="a b"]`` and ``:not(.a .b)`` stay whole."""
    out, buf, depth, comb, i = [], "", 0, "", 0
    while i < len(selector):
        c = selector[i]
        if c in "[(":
            depth += 1
        elif c in "])":
            depth -= 1
        if depth == 0 and c in " >+~":
            # Collapse a run of whitespace and at most one explicit combinator.
            j, seen = i, " "
            while j < len(selector) and selector[j] in " >+~":
                if selector[j] != " ":
                    seen = selector[j]
                j += 1
            if buf:
                out.append((comb, buf))
                buf = ""
            comb, i = seen, j
            continue
        buf += c
        i += 1
    if buf:
        out.append((comb, buf))
    return out


def strip_pseudo(compound):
    """`compound` without its pseudo-classes and pseudo-elements: the element
    a `:hover`, a `::placeholder` or an `::after` belongs to."""
    out, depth, i = "", 0, 0
    while i < len(compound):
        c = compound[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        if c == ":" and depth == 0:
            # Skip `:name`, `::name` and a balanced `(...)` argument.
            i += 1
            while i < len(compound) and compound[i] == ":":
                i += 1
            while i < len(compound) and (compound[i].isalnum() or compound[i] in "-_"):
                i += 1
            if i < len(compound) and compound[i] == "(":
                d = 0
                while i < len(compound):
                    d += {"(": 1, ")": -1}.get(compound[i], 0)
                    i += 1
                    if d == 0:
                        break
            continue
        out += c
        i += 1
    return out


def ground_layers(selector):
    """The selectors whose background can lie under what `selector` paints,
    nearest first, as (selector, same_element) pairs.

    The element itself comes first (its own selector, then that selector with
    the last compound's pseudo-classes cut, so a `:hover` or a
    `::placeholder` sits on its element's ground), then each ancestor the
    selector names, innermost first.  A compound reached through `+` or `~` is
    a sibling, not an ancestor, so it is skipped.  The compiled sheet does not
    know the DOM beyond what a selector says, so an ancestor the selector does
    not name cannot be found; the window ground stands for it."""
    parts = split_compounds(selector)
    out, seen = [], set()

    def add(sel, same):
        if sel and sel not in seen:
            seen.add(sel)
            out.append((sel, same))

    for n in range(len(parts), 0, -1):
        same = n == len(parts)
        if not same and parts[n][0] in "+~":
            continue
        prefix = parts[:n]
        text = "".join((c if k else "") + p for k, (c, p) in enumerate(prefix)).strip()
        add(text, same)
        last = strip_pseudo(prefix[-1][1])
        if last:
            text = "".join((c if k else "") + p for k, (c, p) in enumerate(prefix[:-1] + [(prefix[-1][0], last)])).strip()
            add(text, same)
    return out


def resolve_vars(value, context, root, depth=0):
    """`value` with each `var(--x, fallback)` replaced by the value `--x`
    takes for the element: its definition on the nearest of the `context`
    selectors (the element and its ancestors, nearest first, as
    ``ground_layers`` lists them), else on `:root`, else the fallback.
    Definitions are themselves resolved, to a bounded depth (a cycle is
    invalid CSS and resolves to nothing)."""
    if depth > 8:
        return ""
    out, i = [], 0
    for m in VAR_READ_RE.finditer(value):
        if m.start() < i:
            continue
        open_at = value.index("(", m.start())
        d, j = 1, open_at + 1
        while j < len(value) and d:
            d += {"(": 1, ")": -1}.get(value[j], 0)
            j += 1
        inner = value[open_at + 1:j - 1]
        fallback = inner.split(",", 1)[1].strip() if "," in inner else ""
        name = m.group(1)
        defined = next((v for sel in context for s, p, v, _ in reversed(sel) if p == name), None)
        if defined is None:
            defined = root.get(name)
        out.append(value[i:m.start()])
        out.append(resolve_vars(defined if defined is not None else fallback,
                                context, root, depth + 1))
        i = j
    return "".join(out) + value[i:]


def foreground_ground(selector, decls_by_sel, root, page_ground, sits_on, edge):
    """The opaque colour the foreground of `selector` sits on, the selector
    that painted it (``"body"`` for the window ground), the `sits_on`
    entries the walk went through, and the MODE_INDEPENDENT surface among
    the layers that painted it (None when there is none).

    Walk ``ground_layers`` outward and take each layer's winning `background`
    / `background-color` colour (a gradient by its first stop; `transparent`,
    `none` and images paint nothing knowable and are passed over) until one is
    opaque; translucent layers are composited, outermost first, over it or
    over the window ground.  An `edge` (a border, an outline, a column rule)
    is drawn at the element's boundary and has to read against what
    surrounds the element, so the element's own fill is skipped for it.  A
    layer listed in `sits_on` continues the walk at the surface named there
    (see ``SITS_ON``)."""
    layers, painted_by, via, media = [], "body", [], None
    queue = list(ground_layers(selector))
    visited = set()
    while queue:
        sel, same = queue.pop(0)
        if sel in visited:
            continue
        visited.add(sel)
        own = [] if edge and same else decls_by_sel.get(sel, [])
        bg = [(v, imp) for s, p, v, imp in own if p in ("background", "background-color")]
        colour = None
        if bg:
            important = [v for v, imp in bg if imp]
            value = important[-1] if important else bg[-1][0]
            context = [decls_by_sel.get(s, []) for s, _ in ground_layers(sel)]
            found = colours_in(resolve_vars(value, context, root))
            if found:
                colour = found[0][1:]
        if colour:
            layers.append(colour)
            painted_by = sel if len(layers) == 1 else painted_by
            if sel in MODE_INDEPENDENT and media is None:
                media = sel
            if colour[3] >= 1.0:
                break
        if sel in sits_on:
            via.append(sel)
            queue = [(sits_on[sel], False)] + [(s, False) for s, _ in ground_layers(sits_on[sel])]
    ground = page_ground
    for r, g, b, alpha in reversed(layers):
        ground = composite(r, g, b, alpha, ground)
    return ground, painted_by, via, media


def role_tokens(colour_hex, prop, tokens, on_surface):
    """The design tokens of the property's ROLE that paint `colour_hex` in
    BOTH modes: `colors-ui-border-*` for an edge, `colors-ui-text-*` and
    `colors-ui-icon-*` for text.  The design system chose that colour for the
    role in its Light mode too (`border/information` is #93c5fd in each), so
    a rule that paints it in both sheets follows the mode; whether the colour
    suits the role is the design system's question, not this check's.

    The compiled sheet does not record which variable a value came from, so
    a hard-coded colour that equals such a token passes as well: it IS the
    design system's Light colour for that role.  The tokens meant for ink on
    a coloured surface (`*-on-color*`, `*-on-action*`, `border/contrast`)
    count only `on_surface`: when the rule's ground is one the design system
    made for them, the Light value of a `surface/action/*`,
    `surface/alert/*` or `surface/on-color/*` token (other than the window
    ground's own colour).  On any other ground they are pale by design:
    #fca5a5 error text on a pale pink hover, 1.26:1.  A custom property
    takes the tokens of either role, since its readers may draw an edge or
    text."""
    edge, custom = is_edge(prop), prop.startswith("--")
    out = []
    for var, (dark, light) in tokens.items():
        if dark != light or light != colour_hex:
            continue
        is_border = var.startswith("colors-ui-border-")
        is_text = var.startswith(("colors-ui-text-", "colors-ui-icon-"))
        # A custom property may be read as either (`--ct-checkmark-border-error`
        # is a border), so either role's tokens count for it.
        if not (is_border if edge else (is_border or is_text) if custom else is_text):
            continue
        if re.search(r"-on-(color|action)|-contrast", var) and not on_surface:
            continue
        out.append(var)
    return sorted(out)


def is_edge(prop):
    return bool(re.match(r"(border|outline|column-rule)", prop))


# Token families that name a GROUND (a surface, a separator, the editor's own
# ground or selection), never ink.  Text painted in one of these follows the
# mode only in the sense that a ground does: `colors-ui-surface-input-default`
# as text is the window ground's colour on the window ground.
GROUND_TOKEN_PREFIXES = ("colors-ui-surface-", "colors-ui-border-", "colors-ui-divider-",
                         "colors-editor-surface-", "colors-editor-action-",
                         "editor-theme-ground", "editor-theme-selection",
                         "editor-theme-executionline")


def fit_for_role(names, prop, on_surface):
    """The tokens among `names` (those ``follows_mode`` found for a
    foreground's colour) that may paint it in its ROLE.  ``follows_mode``
    cannot see the role, as check 4 cannot, and check 4 answers that with the
    rule's shape; a foreground's role is its property instead:

    - TEXT (`color`, `caret-color`, `text-decoration`) is not painted in a
      ground token: a surface, border or divider token's Light value as text
      is pale by design.  An EDGE keeps every name, because a border drawn
      in a surface colour is a CSS idiom for a ground (a tooltip's arrow
      triangle, a scrollbar thumb's inset, a knock-out ring around a dot);
      so does a custom property, whose readers may be either.
    - The tokens for ink on a coloured surface (`*-on-color*`,
      `*-on-action*`, `border/contrast`) count only `on_surface`, as in
      ``role_tokens``: on the bare window ground they are pale by design.

    Without this, a pale colour passed whenever ANY token had it as its
    Light value: `.recent-trace`'s `text/warning/on-color` (#fdba74, 1.56:1
    on the window ground) and a dropdown's text in `surface/input/default`
    (1.03:1) both did."""
    text = not is_edge(prop) and not prop.startswith("--")
    out = []
    for var in names:
        if text and var.startswith(GROUND_TOKEN_PREFIXES):
            continue
        if re.search(r"-on-(color|action)|-contrast", var) and not on_surface:
            continue
        out.append(var)
    return out


def pale_foregrounds(light_decls, dark_decls, tokens, page_ground):
    """Check 5 of the header.  Returns (offending, followed, on_media,
    unused_sits_on, unrendered): the pale colours that fail, those that pass
    because they follow the mode, those that pass on a SITS_ON or
    MODE_INDEPENDENT surface, the SITS_ON entries that no longer change any
    verdict, and the pale colours of ``UNRENDERED`` rules."""
    decls_by_sel = {}
    for d in light_decls:
        decls_by_sel.setdefault(d[0], []).append(d)
    root = {p: v for s, p, v, _ in light_decls if s == ":root" and p.startswith("--")}
    read_vars = {v for _, p, val, _ in light_decls if FOREGROUND_PROP_RE.fullmatch(p)
                 for v in VAR_READ_RE.findall(val)}
    on_root = set(root)
    seen, offending, followed, on_media = {}, [], [], []
    sits_on_used, unrendered = set(), []
    # The grounds the design system made for on-colour ink: the Light values
    # of its action, alert and on-colour surfaces, less the window ground's
    # own colour (`surface/on-color/secondary` is #f8f6f2 in Light).
    coloured_surfaces = {light for var, (_, light) in tokens.items()
                         if var.startswith(("colors-ui-surface-action-",
                                            "colors-ui-surface-alert-",
                                            "colors-ui-surface-on-color-"))} - {page_ground}
    for selector, prop, value, _ in light_decls:
        if not FOREGROUND_PROP_RE.fullmatch(prop) and prop not in read_vars:
            continue
        occurrence = seen.get((selector, prop), 0)
        seen[(selector, prop)] = occurrence + 1
        # A custom property is graded where it is defined, as text would be
        # (it has no edge of its own); the readers are graded as well.
        edge = is_edge(prop)
        ground, painted_by, listed, media = foreground_ground(
            selector, decls_by_sel, root, page_ground, SITS_ON, edge)
        plain_ground = foreground_ground(selector, decls_by_sel, root, page_ground,
                                         {}, edge)[0] if listed else None
        for index, (spelling, r, g, b, alpha) in enumerate(
                colours_in(drop_fallbacks(value, on_root))):
            painted = composite(r, g, b, alpha, ground)
            ratio = contrast(painted, ground)
            plain_fails = plain_ground is not None and contrast(
                composite(r, g, b, alpha, plain_ground), plain_ground) < MIN_FOREGROUND_CONTRAST
            if ratio >= MIN_FOREGROUND_CONTRAST or media:
                # Readable on its real surface, or drawn on a surface that is
                # dark in both modes (MODE_INDEPENDENT), whose foregrounds the
                # light theme does not change and this check does not grade.
                if plain_fails:
                    sits_on_used.update(listed)
                if plain_fails or (media and ratio < MIN_FOREGROUND_CONTRAST):
                    on_media.append((selector, prop, spelling, painted_by, ratio, media))
                continue
            hit = dict(selector=selector, prop=prop, value=value, occurrence=occurrence,
                       index=index, spelling=spelling, rgba=(r, g, b, alpha),
                       ground=ground, painted_by=painted_by, ratio=ratio)
            opaque_hex = "#" + "".join(f"{c:02x}" for c in (r, g, b))
            names = []
            if alpha >= 1.0:
                on_surface = ground in coloured_surfaces
                names = fit_for_role(follows_mode(hit, dark_decls, tokens), prop,
                                     on_surface) or \
                    role_tokens(opaque_hex, prop, tokens, on_surface)
            if names:
                followed.append((hit, names))
            elif selector in UNRENDERED:
                unrendered.append(hit)
            else:
                offending.append(hit)
    unused = [s for s in SITS_ON if s not in sits_on_used]
    return offending, followed, on_media, unused, unrendered


def check_every_foreground(light_decls, dark_decls, tokens, failures, repo_root):
    """Check 5 of the header over the LIGHT sheet's declarations."""
    page_ground = norm_hex(winning(light_decls, "body", "background-color"))
    if not page_ground:
        return  # check_every_ground has already failed on this
    offending, followed, on_media, unused, unrendered = pale_foregrounds(
        light_decls, dark_decls, tokens, page_ground)
    footer_guard = (repo_root / "src/tests/gui/page-objects/status-footer-contrast.ts"
                    ).read_text(encoding="utf-8")
    for selector, identifier in UNRENDERED.items():
        if f'identifier: "{identifier}"' not in footer_guard:
            failures.append(f"UNRENDERED lists `{selector}`, but `{identifier}` is no longer "
                            f"in UNREACHABLE_SELECTORS: grade it, or drop the entry")
        elif not any(h["selector"] == selector for h in unrendered):
            failures.append(f"UNRENDERED lists `{selector}`, which no longer appears in the "
                            f"light stylesheet or no longer paints a pale colour: drop the entry")
    for h in unrendered:
        print(f"  ok   light {h['selector']} {{ {h['prop']}: {h['spelling']} }} is "
              f"{h['ratio']:.2f}:1 on {h['ground']}, but nothing renders it (UNRENDERED)")
    for h in offending:
        where = "the window ground" if h["painted_by"] == "body" else \
            f"the ground `{h['painted_by']}` paints"
        shown = h["spelling"]
        if h["rgba"][3] < 1.0:
            shown += f" (paints {composite(*h['rgba'], h['ground'])})"
        failures.append(
            f"light stylesheet paints `{h['selector']} {{ {h['prop']}: {h['value']} }}` pale: "
            f"{shown} on {h['ground']}, {where}, is {h['ratio']:.2f}:1 < "
            f"{MIN_FOREGROUND_CONTRAST}:1 — a colour written for the dark ground; give it "
            f"the design token of its role in the light mode")
    for selector in unused:
        if not any(s == selector for s, _, _, _ in light_decls):
            failures.append(f"SITS_ON lists `{selector}`, which no longer appears in the "
                            f"light stylesheet: drop the entry")
        else:
            failures.append(f"SITS_ON lists `{selector}` ({SITS_ON[selector]}), but no "
                            f"foreground under it needs that surface to read: drop the entry")
    for h, names in followed:
        shown = " / ".join(names[:3]) + (" / ..." if len(names) > 3 else "")
        print(f"  ok   light {h['selector']} {{ {h['prop']}: {h['spelling']} }} is "
              f"{h['ratio']:.2f}:1 on {h['ground']}, but it is the Light value of {shown} "
              f"(follows the mode)")
    for selector, prop, spelling, painted_by, ratio, media in on_media:
        where = f"`{painted_by}`" + (f", over the media surface `{media}`"
                                     if media and media != painted_by else "")
        verdict = "reads" if ratio >= MIN_FOREGROUND_CONTRAST else \
            "is dark in both modes and not graded:"
        print(f"  ok   light {selector} {{ {prop}: {spelling} }} {verdict} {ratio:.2f}:1 on "
              f"{where}")
    if not offending:
        print(f"  ok   light: no other foreground reads below {MIN_FOREGROUND_CONTRAST}:1 "
              f"on its ground")


def check_watch_colours(sheets, tokens, failures):
    """Require each shipped watch declaration, in its role's colour per mode."""
    for selector, prop, token, dark in WATCH_COLOURS:
        if token not in tokens:
            failures.append(f"{token} is not a mapped colour token in design_tokens.nim")
            continue
        for mode, want in (("dark", dark), ("light", tokens[token][1])):
            got = winning(sheets[mode], selector, prop)
            # Stylus retains the border shorthand; its final word is its
            # colour. Missing declarations stay None and fail explicitly.
            colour = got.split()[-1] if got and prop == "border" else got
            if norm_hex(colour) != want:
                failures.append(
                    f"{mode} watch colour `{selector} {{ {prop} }}` is {got!s}, "
                    f"expected {want} ({token} in Light, existing colour in Dark)")
            else:
                print(f"  ok   {mode:5} watch {selector} {{ {prop}: {want} }}")


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

    check_watch_colours(sheets, tokens, failures)

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
    check_every_foreground(sheets["light"], sheets["dark"], tokens, failures, args.repo_root)

    if failures:
        print(f"FAIL: {len(failures)} light-theme ground(s) or foreground(s) wrong:",
              file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"OK: {len(GROUNDS)} grounds paint their design-token value in each mode, "
          f"the light editor's text is readable, no light background is dark "
          f"but ink from the Light tokens and the {len(MODE_INDEPENDENT)} "
          f"mode-independent media surfaces, and no light foreground is paler than "
          f"{MIN_FOREGROUND_CONTRAST}:1 on its ground but colours that follow the mode")
    return 0


if __name__ == "__main__":
    sys.exit(main())
