## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/status_bar.nim — CTUI-3. The command line and status bar of
## CodeTracer-TUI.md §3.3.6.
##
## Two fields: the mode indicator (input mode, then product mode) and the
## notification area — plus the open prompt's text while one is open.
##
## ## No key-hint strip (PLAT-49)
##
## §3.3.6 once asked for a "dynamic hint strip showing context-sensitive key
## combinations" (`'n':step-over 'p':rev-step …`), and this row drew one for
## every mode and profile. The user removed it on 2026-10-01: no other
## front-end has one, and the keys are reachable from the menu (which shows
## each item's chord, from the active keymap) and from the debugger controls'
## tooltips (label and key). `app/tests/test_layout_profiles.nim` asserts the
## status line carries no hint text in any mode.

import ../layout/profile

# PLAT-16. `ProductMode` — Edit and Debug — comes from the CORE
# (`viewmodel/viewmodels/product_mode.nim`) through the sanctioned facade, and
# NOT from a second enum declared here.
#
# THAT IS THE WHOLE POINT OF THE IMPORT. CodeTracer-TUI-Edit-Mode.md §1.2:
# "`UiMode` … must not gain `EDIT`. It enumerates input modes and its
# cardinality is asserted by `test_layout_profiles.nim`. The product mode is a
# separate indicator in a separate position on the status line." A terminal
# copy of the product vocabulary would be a front-end with its own opinion about
# what mode the product is in, which is exactly the collapse this milestone's
# risk names. `app/tests/test_product_mode_dimensions.nim` asserts that neither
# enum can name a member of the other and that the state space is the PRODUCT of
# the two cardinalities rather than their sum.
import codetracer_embed

# `textCells` / `fitCells` live in `header.nim` rather than in a fourth module
# nobody's deliverable list names. They are the one width-measurement rule the
# whole shell shares, and a second copy of it is exactly how a padding bug
# becomes profile-specific.
import ./header
import ./styled_row

type
  UiMode* = enum
    ## §3.3.6's mode indicator. Spelled as it appears on screen.
    umNormal = "NORMAL"
    umCommand = "COMMAND"
    umSearch = "SEARCH"
    umInspect = "INSPECT"
      ## CTUI-9. §4.1's fourth mode, which CTUI-3 had no indicator for because
      ## nothing could enter it yet. `app/input/modal_state.statusMode` is the
      ## only mapping onto this enum, so the four §4.1 modes and the five
      ## indicators below cannot drift apart silently.
    umVisual = "VISUAL"
    umSeek = "SEEK"

  StatusBarModel* = object
    ## Everything the bottom row shows, as a value.
    mode*: UiMode
      ## The INPUT mode. Six values; see `UiMode`.
    product*: ProductMode
      ## The PRODUCT mode. Two values, and a SEPARATE FIELD rather than a
      ## seventh `UiMode` member — §1.2's requirement, and the field that makes
      ## "a user is in Edit mode *and* in NORMAL input mode, and both
      ## indicators are true at once" representable at all.
      ##
      ## `pmDebug` is the zero value, so every `StatusBarModel` constructed
      ## before this milestone means what it meant.
    profile*: LayoutProfile
    fold*: string
      ## PLAT-45. `profile.foldNote`'s answer: empty when the screen shows the
      ## shared default as every product opens it, else how many of its
      ## regions this terminal folded into tabs. Drawn right after the two
      ## mode indicators and, like them, never dropped: a user looking at
      ## fewer regions than the desktop shows must be able to see why.
    notification*: string
      ## A transient message. Empty means "nothing to say", and nothing is then
      ## drawn — an empty notification area that always reserves its columns
      ## would make a lost message and a quiet one look the same.
    prompt*: string
      ## What the user has typed after `:` or `/`, shown after the mode
      ## indicators in `umCommand` / `umSearch`.

proc initStatusBarModel*(mode = umNormal;
                         profile = selectProfile(80, 24);
                         notification = ""; prompt = "";
                         product = pmDebug; fold = ""): StatusBarModel =
  StatusBarModel(mode: mode, product: product, profile: profile,
                 notification: notification, prompt: prompt, fold: fold)

proc productIndicator*(product: ProductMode): string =
  ## §1.2's separate indicator, in its separate position.
  ##
  ## BRACKETED, so the two indicators read as two facts rather than as one
  ## two-word mode name — `NORMAL [EDIT]` is a user in NORMAL input mode and
  ## Edit product mode, and `NORMAL EDIT` would read as a fifth input mode,
  ## which is the sentence §1.2 forbids rendered instead of typed.
  "[" & $product & "]"

proc productStyle*(product: ProductMode): CellStyle =
  ## The colour the product indicator is painted in.
  ##
  ## DISJOINT FROM EVERY `modeStyle` COLOUR, and that is the property rather
  ## than the palette: a Tier-2 case reads a cell's colour to say which
  ## indicator it is looking at, and a product indicator sharing a colour with
  ## an input mode would make the two indistinguishable to exactly the
  ## assertion that has to tell them apart. `modeStyle` uses green, yellow,
  ## magenta, cyan, blue and bright_blue; these two use neither.
  ##
  ## `bold` is deliberately OFF: the input mode is the primary indicator and
  ## the product mode qualifies it, so they must not compete.
  case product
  of pmDebug: CellStyle(role: srModeDebug)
  of pmEdit: CellStyle(role: srModeEdit)

proc modeStyle*(mode: UiMode): CellStyle =
  ## CTUI-9. The colour §3.3.6's mode indicator is painted in.
  ##
  ## ONE COLOUR PER MODE, and no two the same, because
  ## `tests/real_terminal/test_real_keybindings.nim` asks a real terminal which
  ## mode the app is in and `docs/tui-testing.md`'s rule for a Tier-2 case is
  ## that the colours it relies on for MEANING are asserted absolutely —
  ## `fg.idx == 2`, not "the same as Tier 1". A shared colour would make two
  ## modes indistinguishable to that assertion.
  ##
  ## The six names map onto indexed colours 2, 3, 5, 6, 4 and 12, which is what
  ## both tiers report. `bold` on all of them, so the indicator reads as a
  ## label rather than as coloured prose.
  case mode
  of umNormal: CellStyle(role: srModeNormal)
  of umCommand: CellStyle(role: srModeCommand)
  of umSearch: CellStyle(role: srModeSearch)
  of umInspect: CellStyle(role: srModeInspect)
  of umVisual: CellStyle(role: srModeVisual)
  of umSeek: CellStyle(role: srModeSeek)

proc promptSigil*(mode: UiMode): string =
  ## The character §3.3.6 says each interactive prompt opens with.
  case mode
  of umCommand: ":"
  of umSearch: "/"
  else: ""

proc statusBarText*(m: StatusBarModel; width: int): string =
  ## The bottom row, exactly `width` cells wide.
  ##
  ## The mode indicator is never dropped, and the notification is
  ## right-aligned. On a terminal too narrow for both, the prompt text is cut
  ## before the notification is: a warning the user cannot see is the failure
  ## this whole row exists to prevent.
  if width <= 0:
    return ""
  # THE TWO INDICATORS, IN TWO POSITIONS, ALWAYS BOTH DRAWN.
  #
  # They are concatenated into one `mode` local so the narrow-terminal rule
  # below — "the mode indicator is never dropped" — covers the pair rather than
  # just the input half. A product mode that vanished at 14 columns would leave
  # a user editing a file on a screen that says NORMAL and nothing else.
  let mode = $m.mode & " " & productIndicator(m.product) &
             (if m.fold.len > 0: " " & m.fold else: "")
  # PLAT-49: the prompt's text when one is open, and nothing otherwise — no
  # key-hint strip.
  let middle =
    if m.prompt.len > 0 or promptSigil(m.mode).len > 0:
      promptSigil(m.mode) & m.prompt
    else:
      ""
  if textCells(mode) >= width:
    return fitCells(mode, width)

  var line = mode
  let note = m.notification
  # `noteRoom` is the two separating spaces PLUS the message, so anything below
  # three cells cannot carry a message at all and must be zero rather than one
  # or two. At `noteRoom == 1` the tail below would be `(width - 1) + 2` cells
  # — one column too wide — and every downstream claim that a row is exactly
  # `width` cells would fail at one terminal size in a hundred, which is
  # exactly the kind of arithmetic a sweep finds and three geometries do not.
  var noteRoom = 0
  if note.len > 0:
    noteRoom = min(textCells(note) + 2, width - textCells(mode) - 4)
    if noteRoom < 3:
      noteRoom = 0
  let middleRoom = width - textCells(mode) - 3 - noteRoom
  if middleRoom > 0 and middle.len > 0:
    line.add " | " & fitCells(middle, min(middleRoom, textCells(middle)))
  if noteRoom > 0:
    return fitCells(line, width - noteRoom) & "  " & fitCells(note, noteRoom - 2)
  fitCells(line, width)
