## viewmodels/transport_icons.nim — PLAT-48 deliverable 4. THE DEBUGGER
## CONTROLS' FOUR RENDERINGS, AS DATA, AND THE RULE THAT PICKS ONE.
##
## `debug_controls_vm.TransportActions` is the set of controls (the desktop
## toolbar's nine, in its order); this module says how each one is DRAWN in a
## medium that has no SVG of its own:
##
##   * `nerd`     — Nerd Fonts' Codicon debug glyphs, the set VS Code's debug
##                  toolbar uses, reverse actions included (`debug-step-back`,
##                  `debug-reverse-continue`). Codicons has no reverse step-in
##                  or step-out; those two are the forward glyph after a `←`,
##                  which reads as "the same step, backwards".
##   * `graphics` — the DESKTOP'S OWN marks (`views/debug_control_marks`),
##                  rasterised and drawn through the terminal's image tiers
##                  (`common/terminal_graphics`). No glyph here: the renderer
##                  draws pictures.
##   * `unicode`  — symbols every font has: `⏵ ⏴` continue, `↷ ↶` step over,
##                  `↓ ⇣` step in, `↑ ⇡` step out, `⏮` run to entry. A reverse
##                  action is its forward glyph mirrored or dashed.
##   * `text`     — labelled buttons. When the row is short only a DECLARED
##                  PRIORITY SUBSET is kept (`textPrioritySubset`): the first
##                  `k` of `TextPriority` that fit, drawn in toolbar order.
##                  The rest stay reachable by key and from the menu.
##
## ## Choosing a mode: never assume a font
##
## A terminal cannot be asked whether a font is installed — a cursor-position
## report measures a glyph's WIDTH, not whether it rendered — so `nerd` is
## never picked on the user's behalf. The default is `graphics` when the
## terminal was measured to draw pictures (kitty graphics), else `unicode`;
## when an environment hint says Nerd Fonts are in use (`nerdFontHint`), the
## front-end SUGGESTS `nerd` on the status line and leaves the choice to the
## user. The choice is persisted by the host and switchable at run time.
##
## Plain Nim; C and JavaScript backends.

import std/strutils

type
  IconsMode* = enum
    imNerd = "nerd"
    imGraphics = "graphics"
    imUnicode = "unicode"
    imText = "text"

  TransportControl* = object
    id*: string
      ## `TransportActions`' id: what `invokeToolbarStep` dispatches on and
      ## what `debug_control_marks.markFor` draws.
    label*: string
      ## The desktop toolbar's label — the tooltip's first half.
    clientAction*: string
      ## The desktop's `ClientAction` for the same command (the menu's
      ## action id), so a control and its menu item show the same chord.
    nerd*: string
    unicode*: string
    text*: string

const
  TransportControls*: array[9, TransportControl] = [
    TransportControl(id: "reverse-next", label: "Reverse next",
                     clientAction: "reverseNext",
                     nerd: "\u{EB8F}", unicode: "↶", text: "Rev next"),
    TransportControl(id: "next", label: "Next", clientAction: "forwardNext",
                     nerd: "\u{EAD6}", unicode: "↷", text: "Next"),
    TransportControl(id: "reverse-step-in", label: "Reverse step in",
                     clientAction: "reverseStep",
                     nerd: "←\u{EAD4}", unicode: "⇣", text: "Rev in"),
    TransportControl(id: "step-in", label: "Step in",
                     clientAction: "forwardStep",
                     nerd: "\u{EAD4}", unicode: "↓", text: "In"),
    TransportControl(id: "reverse-step-out", label: "Reverse step out",
                     clientAction: "reverseStepOut",
                     nerd: "←\u{EAD5}", unicode: "⇡", text: "Rev out"),
    TransportControl(id: "step-out", label: "Step out",
                     clientAction: "forwardStepOut",
                     nerd: "\u{EAD5}", unicode: "↑", text: "Out"),
    TransportControl(id: "reverse-continue", label: "Reverse continue",
                     clientAction: "reverseContinue",
                     nerd: "\u{EB8E}", unicode: "⏴", text: "Rev cont"),
    TransportControl(id: "continue", label: "Continue",
                     clientAction: "forwardContinue",
                     nerd: "\u{EACF}", unicode: "⏵", text: "Continue"),
    TransportControl(id: "run-to-entry", label: "Run to entry",
                     clientAction: "",
                     nerd: "\u{EAD2}", unicode: "⏮", text: "Entry")]
    ## In the desktop toolbar's order (`TransportActions`).

  TextPriority*: array[9, string] = [
    "continue", "next", "step-in", "step-out", "reverse-continue",
    "reverse-next", "reverse-step-in", "reverse-step-out", "run-to-entry"]
    ## The order text-mode buttons are KEPT in as the row narrows: forward
    ## motion first (what every debugging session uses), then its reverses,
    ## run-to-entry last.

  NerdSuggestion* = "Nerd Font detected: `:icons nerd` draws the debugger " &
                    "controls with its Codicon glyphs"

func controlIndex*(id: string): int =
  for i, c in TransportControls:
    if c.id == id:
      return i
  -1

func glyphFor*(c: TransportControl; mode: IconsMode): string =
  ## What a cell renderer writes for `c` in `mode`. `graphics` writes no
  ## glyph (the renderer draws the desktop's mark), so it answers "".
  case mode
  of imNerd: c.nerd
  of imUnicode: c.unicode
  of imText: c.text
  of imGraphics: ""

func parseIconsMode*(s: string): tuple[ok: bool, mode: IconsMode] =
  for m in IconsMode:
    if $m == s.strip.toLowerAscii:
      return (true, m)
  (false, imUnicode)

func iconsModeNames*(): string =
  var parts: seq[string] = @[]
  for m in IconsMode:
    parts.add $m
  parts.join(", ")

func defaultIconsMode*(graphicsDrawn: bool): IconsMode =
  ## The mode a front-end starts in when the user has not chosen one:
  ## `graphics` when the terminal was measured to draw pictures, else
  ## `unicode`. NEVER `nerd` (see the module header).
  if graphicsDrawn: imGraphics else: imUnicode

func nerdFontHint*(nerdFontVar, termProgram, termFont: string): bool =
  ## Whether the environment SAYS Nerd Fonts are in use — a hint, never a
  ## measurement:
  ##   * `NERD_FONT` (or `NERDFONT`) set to anything but "", "0", "false";
  ##   * `TERM_PROGRAM=WezTerm`, which bundles the Nerd Font symbols as a
  ##     fallback font;
  ##   * a font name the terminal exports that contains "Nerd" (kitty's
  ##     `KITTY_FONT`-style variables, passed in by the host as `termFont`).
  let v = nerdFontVar.strip.toLowerAscii
  if v.len > 0 and v notin ["0", "false", "no", "off"]:
    return true
  if termProgram.strip.toLowerAscii == "wezterm":
    return true
  termFont.toLowerAscii.contains("nerd")

func textButtonCells*(c: TransportControl): int =
  ## A text button's width: its label padded by one cell each side.
  c.text.len + 2

func textPrioritySubset*(budget: int; gap = 1): seq[int] =
  ## The controls text mode keeps in `budget` cells: the longest prefix of
  ## `TextPriority` whose buttons (plus a `gap` between each) fit, returned
  ## as indices into `TransportControls` IN TOOLBAR ORDER.
  var chosen: seq[int] = @[]
  var used = 0
  for id in TextPriority:
    let i = controlIndex(id)
    let w = textButtonCells(TransportControls[i]) +
            (if chosen.len > 0: gap else: 0)
    if used + w > budget:
      break
    used += w
    chosen.add i
  for i in 0 ..< TransportControls.len:
    if i in chosen:
      result.add i

func tooltipFor*(c: TransportControl; chord: string): string =
  ## The tooltip / status line text: the label, and the key when one is
  ## bound — `debug_controls_vm.toolbarTooltip`'s shape.
  if chord.len == 0: c.label else: c.label & " (" & chord & ")"
