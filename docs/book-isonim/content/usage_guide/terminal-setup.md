---
title: Setting up your terminal
order: 12
---
# Setting up your terminal for CodeTracer

The terminal front-end (`ct replay --ui=tui`, `codetracer-tui`) adapts to the
terminal it runs in. At start-up it asks the terminal who it is and what it can
do, measures how wide it draws the characters CodeTracer uses, and picks the
glyphs, colours and features to match. Most terminals need no setup. This page
says how to check what was decided, what to change when something looks wrong,
and which settings exist.

## 1. Check

```sh
ct doctor terminal
```

prints the report and a glyph test card in the terminal you run it in. The same
report is `codetracer-tui --capabilities` (`--capabilities=json` for a bug
report), and inside a session the palette entry **Terminal: Show
Capabilities** (`:terminal-info`) shows it live.

This is the report from inside tmux 3.6 on a local machine (the last line,
`summary`, is omitted):

```text
Terminal     unknown terminal via tmux 3.6a   (default: unknown)
Link         local, round trip 2 ms   (probe)
Encoding     UTF-8 (P0)   (probe)
Widths       ambiguous narrow (P1=1), blocks narrow (P2=1), Unicode 13 no (P3=4), wide yes (P5=2), clusters no (P6=8)
             ambiguous-wide rule off   (probe: measured narrow (P1=1))
Glyphs       extended   (environment: auto: UTF-8 (en_US.UTF-8), not a console)
             modern-unicode off   (default: off)
Colours      truecolor   (environment)
Mouse        SGR, any-motion   (default)
Clipboard    osc52 via tmux   (probe)
Sync output  off   (default: not answered)
Graphemes    DEC 2027 not recognised
Keyboard     modify-other-keys   (environment)
Motion       animated   (default)
Background   bg: default -> dark
Remedies     tmux withholds extended keys (Ctrl+Shift+…): set -s extended-keys on
             tmux withholds the mouse: set -g mouse on
```

Here tmux's own width table measured `🮇` (U+1FB87) four cells (`P3=4`), so
`modern-unicode` should stay off, and the two remedies are the tmux lines in
section 4.

Every line says where its answer came from:

| Source | Meaning |
|---|---|
| `setting` | a `:set`, a `[terminal "…"]` section, or your global settings |
| `flag` | a command-line flag for this run |
| `environment` | a `CODETRACER_TUI_*` variable, `NO_COLOR`, or a hint such as `COLORTERM` or `LANG` |
| `probe` | the terminal answered a question |
| `identity` | the terminal's name and version, looked up in what its documentation says it can do |
| `cache` | the terminal's answers from last time, used until this session's arrive |
| `default` | nothing answered; the safe choice |

### The glyph test card

The card shows each kind of glyph between `[` and `]`, over a ruler. A glyph your
font draws wider than the terminal measured pushes its closing bracket out of
line. That is the one way to see a font problem, because no terminal can be
asked whether its font has a glyph.

Its **Legacy Computing** row (`🮇 🮂 🭰 🭻`) decides `modern-unicode`. If any of
these is a box, a blank or a different shape, keep `modern-unicode` off. In
`:terminal-info`, press `y` if they look right or `n` if not: that sets
`modern-unicode` for **this terminal only**.

## 2. The four things that matter most

- **A UTF-8 locale.** `LANG=C.UTF-8` or another UTF-8 locale. CodeTracer also
  measures whether the terminal decodes UTF-8, so a C locale on a UTF-8 terminal
  still gets Unicode, and the report gives the `LANG` remedy.
- **A font with box-drawing and block glyphs, or a terminal that draws them
  itself.** kitty, WezTerm, Ghostty, foot, Alacritty, Windows Terminal, VTE
  (GNOME Terminal) and VS Code draw them without the font. Elsewhere use
  `--glyphs=basic` if the eighth blocks (`▁▂▃`) look wrong, or `--glyphs=ascii`.
- **24-bit colour through tmux.** See below.
- **Mouse reporting through tmux.** See below.

## 3. Per terminal

| Concern | Where you set it |
|---|---|
| Ambiguous-width characters | GNOME Terminal / VTE: Preferences, Profile, Compatibility; WezTerm: `treat_east_asian_ambiguous_width_as_wide`; xterm: `-cjk_width`; tmux 3.6+: `codepoint-widths` |
| Built-in glyphs | WezTerm: `custom_block_glyphs`; foot: `box-drawings-uses-font-glyphs = no` (the default); Alacritty: `font.builtin_box_drawing`; Windows Terminal: `font.builtinGlyphs`; VS Code: `terminal.integrated.customGlyphs` with GPU acceleration |
| Clipboard (OSC 52) | kitty: `clipboard_control`; Alacritty: `terminal.osc52`; xterm: `allowWindowOps`; tmux: `set-clipboard on` |
| The kitty keyboard protocol | WezTerm: `enable_kitty_keyboard = true`; tmux: `extended-keys on` |

## 4. tmux

```text
set -g mouse on                                # the mouse reaches CodeTracer
set -as terminal-features ',<your-term>*:RGB'  # 24-bit colour
set -g extended-keys on                        # Ctrl+Shift chords
set -g set-clipboard on                        # copy reaches your clipboard
set -g allow-passthrough on                    # pointer shapes reach the terminal
set -g focus-events on                         # the VCS pane refreshes on return
```

Inside tmux, every question is answered by tmux. What CodeTracer knows about the
terminal outside tmux comes from tmux itself (`tmux display`), read once at
start-up. When tmux withholds something that has a one-line fix, the status line
says so once per session. `:terminal-info dismiss` turns that hint off for good.

## 5. SSH and mosh

SSH carries every question and answer, so detection works remotely. What SSH does
not carry is the environment: only `TERM` and, usually, the locale. The answers
arrive after one round trip; until then the first frame uses this terminal's
answers from last time (`cache`). When the round trip is over 40 ms the session
is **link-conservative**: animations such as the scrollbar fade show their end
state at once. `--reduce-motion=on` does the same on any link.

mosh runs its own terminal emulator, so the answers describe mosh, not your
terminal. It needs a UTF-8 locale.

## 6. CJK and ambiguous width

Many characters CodeTracer draws as chrome (`…`, `─`, `│`, `●`, `▶`, most block
glyphs) are *ambiguous width*: a terminal set for CJK draws them two cells wide.
CodeTracer measures this. When they are wide, it draws chrome only with glyphs
that are one cell everywhere (`▸`, `▐`, `|`, `*`), and the truncation mark `…`
as two cells. Your program's own text is always drawn as recorded. If the
terminal cannot be measured and your locale is Japanese, Chinese or Korean, the
safe glyphs are used. Under tmux, make tmux and the terminal agree: set both wide
or both narrow (tmux 3.6+: `codepoint-widths`).

## 7. The options

Each is a `:set NAME VALUE` (remembered), a `--NAME=VALUE` flag for one run, and,
where listed, a `CODETRACER_TUI_*` variable.

| Setting | Values | Default |
|---|---|---|
| `glyphs` | `auto`, `ascii`, `basic`, `extended` | `auto` (`--ascii-borders` is `--glyphs=ascii`; `CODETRACER_TUI_GLYPHS`) |
| `modern-unicode` | `off`, `on`, `auto` | `off` (`auto`: only where the terminal draws the glyphs itself; `CODETRACER_TUI_MODERN_UNICODE`) |
| `ambiguous-width` | `auto`, `narrow`, `wide` | `auto`, measured (`CODETRACER_TUI_AMBIGUOUS_WIDTH`) |
| `colors` | `auto`, `truecolor`, `256`, `16`, `mono` | `auto` (`--truecolor`, `--no-color`; `CODETRACER_TUI_COLORS`) |
| `terminal-probe` | `on`, `off` | `on` (`--no-probe`; `CODETRACER_TUI_PROBE`) |
| `reduce-motion` | `auto`, `on`, `off` | `auto`: reduced over a slow link |
| `terminal-hints` | `on`, `off` | `on` |

A setting can be scoped to one terminal in the remembered preferences file
(`tui-preferences` in CodeTracer's state directory):

```text
modern-unicode=off
[terminal "kitty*"]
modern-unicode=on
```

**Precedence**, strongest first: `:set` in this session, a flag, a
`CODETRACER_TUI_*` variable, a `[terminal "…"]` section, your global settings,
`NO_COLOR`, the terminal's answers, its identity, environment hints, the cache,
the default.

## 8. When something looks wrong

- Odd characters on start-up, or a terminal that misbehaves on a query:
  `--no-probe`.
- Broken-looking bars or boxes: `--glyphs=basic`, then `--glyphs=ascii`.
- Misaligned columns on a CJK setup: `--ambiguous-width=wide` (or `narrow`).
- To report a problem: attach the output of
  `codetracer-tui --capabilities=json` and say which terminal, version and font
  you use.
