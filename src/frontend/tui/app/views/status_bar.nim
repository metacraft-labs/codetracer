## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/status_bar.nim — CTUI-3. The command line and status bar of
## CodeTracer-TUI.md §3.3.6.
##
## Three fields, in the order the specification lists them: the mode
## indicator, a CONTEXT-SENSITIVE key hint strip, and the notification area.
##
## ## The hints are context-sensitive, and that is asserted rather than claimed
##
## §3.3.6 asks for a "dynamic hint strip showing context-sensitive key
## combinations", and §3.1 shows two DIFFERENT strips — the Compact drawing has
## the function-key set (`F5:Cont F10:Next ...`) and the Standard drawing has
## the letter set (`'n':step-over 'p':rev-step ...`). So `keyHints` is a
## function of BOTH the mode and the profile, and
## `app/tests/test_layout_profiles.nim` asserts the two differ — a "dynamic"
## strip that returned one constant would satisfy every other assertion in this
## milestone.
##
## The keys themselves are CTUI-9's subject; this milestone renders the strip
## and does not bind anything.

import ../layout/profile

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
    profile*: LayoutProfile
    notification*: string
      ## A transient message. Empty means "nothing to say", and nothing is then
      ## drawn — an empty notification area that always reserves its columns
      ## would make a lost message and a quiet one look the same.
    prompt*: string
      ## What the user has typed after `:` or `/`. Shown INSTEAD of the hint
      ## strip in `umCommand` / `umSearch`, because the prompt is what the user
      ## is looking at and the hints are what they no longer need.

proc initStatusBarModel*(mode = umNormal; profile = lpCompact;
                         notification = ""; prompt = ""): StatusBarModel =
  StatusBarModel(mode: mode, profile: profile, notification: notification,
                 prompt: prompt)

proc keyHints*(mode: UiMode; profile: LayoutProfile): string =
  ## The §3.3.6 hint strip for this mode and this profile.
  ##
  ## The Compact strip is the function-key set §3.1's 80x24 drawing shows; the
  ## wider profiles get the letter set from its 120x40 drawing, which is longer
  ## and would be truncated at 80 columns.
  case mode
  of umCommand:
    "Enter:run  Esc:cancel  Tab:complete"
  of umSearch:
    "Enter:find  Esc:cancel  n/N:next/prev match"
  of umInspect:
    # §4.1: "Deep navigation of complex data structures, memory hex viewing,
    # and expression origin inspection" — so the hints are §4.2's Variables
    # Tree row and its Value Origin row, which is exactly the set
    # `app/input/keymap.nim` binds in `mmInspect`.
    "Enter/l:expand  h:collapse  x:hex  m:memory  o/O:origin  Esc:leave"
  of umVisual:
    "y:yank  Esc:leave  hjkl:extend"
  of umSeek:
    "Left/Right:scrub  Enter:jump  Esc:cancel"
  of umNormal:
    case profile
    of lpCompact:
      "F5:Cont F10:Next F11:Step Shift+F10:Prev | :help"
    of lpStandard, lpUltraWide:
      "'n':step-over 'p':rev-step 's':step-into 'b':rev-into 'o':origin | " &
      ":command /:find"

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
  of umNormal: CellStyle(fg: "green", bold: true)
  of umCommand: CellStyle(fg: "yellow", bold: true)
  of umSearch: CellStyle(fg: "magenta", bold: true)
  of umInspect: CellStyle(fg: "cyan", bold: true)
  of umVisual: CellStyle(fg: "blue", bold: true)
  of umSeek: CellStyle(fg: "bright_blue", bold: true)

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
  ## right-aligned so it is not lost in the middle of a hint strip a reader
  ## skims past. On a terminal too narrow for both, the hints go and the
  ## notification stays: a warning the user cannot see is the failure this
  ## whole row exists to prevent.
  if width <= 0:
    return ""
  let mode = $m.mode
  let middle =
    if m.prompt.len > 0 or promptSigil(m.mode).len > 0:
      promptSigil(m.mode) & m.prompt
    else:
      keyHints(m.mode, m.profile)
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
