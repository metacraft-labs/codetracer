## app_keybindings.nim — CTUI-9 snapshot app: the modal state machine and the
## §4.2 keymap, driven by real bytes on a real pty.
##
## One component tree, exported so the Tier-1 half of a suite composites the
## SAME proc in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## input framing.
##
## ## WHY THIS APP EXISTS AT ALL
##
## Everything about the keymap that can be decided in process IS decided in
## process — `app/tests/test_modal_transitions.nim`,
## `app/tests/test_keymap_no_conflicts.nim` and
## `app/tests/test_pane_focus_cycle.nim` between them assert the machine, the
## table and the focus cycle without a terminal anywhere.
##
## What none of them can assert is the layer where an F-key binding actually
## breaks: `sendKey("f10")` is `ESC [ 2 1 ~` arriving one byte at a time on a
## real file descriptor, framed by the runtime into a token, decoded by
## `keymap.keyName`, and only then resolved. Every one of those steps is a place
## a binding can be correct in the table and dead on a terminal. `docs/
## tui-testing.md`'s table names it: "keys as bytes — `sendKey("f10")` is an
## xterm sequence, not a synthesized key event."
##
## The same goes for the cursor. §4.1's modes are told apart on screen by the
## status-bar indicator AND by the cursor's shape and visibility, and "the model
## has no cursor" is the fourth row of that same table.
##
## ## NO CROSS-TIER `runDualSnap` CASE, AND THAT IS THE RULE RATHER THAN AN
## ## OMISSION
##
## `docs/tui-testing.md`: "A new PANE needs exactly one cross-tier equivalence
## test." CTUI-9 adds no pane. This app paints CTUI-3's status bar and a plain
## field list; the status bar's cross-tier grounding is `app_shell.nim`'s case,
## which already exists, and a second equality run over the same rendering path
## would prove nothing the first did not.
##
## ## THE STATE IS A VALUE, AND THE PAINT IS A FUNCTION OF IT
##
## `AppState` is a plain object and `paint` takes one. The module-level `current`
## is what the child's input handler mutates; nothing in a test process touches
## it, so the Tier-1 side of anything that imports this module sees the pristine
## initial state.

import std/[monotimes, times]

import isonim_tui

import headless_app/layout_model

import ../../app/input/keymap
import ../../app/input/modal_state
import ../../app/input/motions
import ../../app/layout/profile
import ../../app/layout/project
import ../../app/views/header
import ../../app/views/status_bar
import ../../app/views/styled_row

const
  TitleText* = "CTUI-9 KEYBINDINGS"
  TitleRow* = 0
  ModeRow* = 2
  ActionRow* = 3
  KeyRow* = 4
  KindRow* = 5
  PendingRow* = 6
  FocusRow* = 7
  QuitRow* = 8

  ModeLabel* = "MODE   : "
  ActionLabel* = "ACTION : "
  KeyLabel* = "KEY    : "
  KindLabel* = "KIND   : "
  PendingLabel* = "PENDING: "
  FocusLabel* = "FOCUS  : "
  QuitText* = "QUIT REQUESTED"
    ## §4.2's `q` / `Ctrl+c` is "Exit CodeTracer TUI session cleanly". A
    ## snapshot app cannot exit from inside its input handler — the runtime owns
    ## the loop — so it RECORDS the request and paints it, and the parent then
    ## ends the child the way every other suite does. What CTUI-9 owns is that
    ## the byte resolved to `quit`; ending a process is the driver's, and the
    ## driver is CTUI-11's.

  NoneText* = "-"
    ## What an empty field shows, so "nothing happened" is a glyph rather than a
    ## blank a test cannot tell from a paint that never ran.

type
  AppState* = object
    ## Everything one keystroke can change, as a value.
    # QUALIFIED: `isonim_tui` re-exports its own M14 `modal` module, which has
    # a `ModalState` of its own. Two different concepts with one name, so the
    # spelling here says which.
    modal*: modal_state.ModalState
    pending*: keymap.PendingState
    lastKey*: string
    lastSpelling*: string
    lastAction*: KeyAction
    lastKind*: KeyResolutionKind
    quitRequested*: bool
    focused*: PaneKind
    maximize*: MaximizeState

proc initAppState*(): AppState =
  AppState(modal: initModalState(), pending: initPendingState(), lastKey: "",
           lastSpelling: "", lastAction: kaNone, lastKind: krNone,
           quitRequested: false, focused: paneCalltrace,
           maximize: initMaximizeState())

var current = initAppState()
var lastCols = 80
var lastRows = 24
let km = defaultKeymap()

proc focusFor(cols, rows: int): PaneFocus =
  ## The focus chain for the profile this geometry selects. Rebuilt per key
  ## rather than held, because the geometry can change under a reflow and a
  ## chain built for the old one would name panes that are no longer on screen.
  newPaneFocus(projectLayout(profileLayout(selectProfile(cols, rows)),
                             bodyArea(cols, rows)))

proc fieldText*(label, value: string): string =
  label & (if value.len == 0: NoneText else: value)

proc statusModelFor*(st: AppState; cols, rows: int): StatusBarModel =
  ## The bottom row's model. The pending indicator goes in the NOTIFICATION
  ## field, which is §4.2's "visible pending indicator": the status bar is the
  ## one row that is on screen in every profile.
  initStatusBarModel(mode = statusMode(st.modal.mode),
                     profile = selectProfile(cols, rows),
                     notification = pendingIndicator(st.pending))

proc paint*(g: var StyledGrid; st: AppState; cols, rows: int) =
  ## The whole screen.
  if cols <= 0 or rows <= 0:
    return
  var title = TitleText & " "
  title.add repeatGlyph("─", max(0, cols - textCells(title)))
  g.paint(TitleRow, 0, fitCells(title, cols))
  g.paint(ModeRow, 0, fieldText(ModeLabel, $st.modal.mode))
  g.paint(ActionRow, 0, fieldText(ActionLabel, $st.lastAction))
  g.paint(KeyRow, 0, fieldText(KeyLabel, st.lastKey))
  g.paint(KindRow, 0, fieldText(KindLabel, $st.lastKind))
  g.paint(PendingRow, 0, fieldText(PendingLabel, pendingIndicator(st.pending)))
  g.paint(FocusRow, 0, fieldText(FocusLabel, $st.focused))
  if st.quitRequested:
    g.paint(QuitRow, 0, QuitText)
  if rows > 1:
    let model = statusModelFor(st, cols, rows)
    g.paint(rows - 1, 0, statusBarText(model, cols))
    # THE MODE INDICATOR, REPAINTED IN ITS OWN COLOUR. Same text, so the row's
    # cell count is unchanged; a different style, so a terminal can be asked
    # which mode the app believes it is in without reading a glyph.
    g.paint(rows - 1, 0, $model.mode, modeStyle(model.mode))

proc rowsFor*(st: AppState; cols, rows: int): seq[string] =
  var g = newStyledGrid(cols, rows)
  paint(g, st, cols, rows)
  result = @[]
  for row in 0 ..< rows:
    result.add g.rowText(row)

proc initialRows*(cols, rows: int): seq[string] =
  ## The screen before any key arrives, as a PURE function of the geometry —
  ## what a parent compares its first frame against without touching `current`.
  rowsFor(initAppState(), cols, rows)

proc treeFor(r: TerminalRenderer; st: AppState;
             cols, rows: int): TerminalNode =
  var g = newStyledGrid(cols, rows)
  paint(g, st, cols, rows)
  var out2: seq[StyledRow] = @[]
  for row in 0 ..< rows:
    out2.add g.rowSpans(row)
  styledRowsTree(r, out2)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## `step` is ignored: this app is driven by real keys, and a builder that
  ## ignores its step paints the same tree however often F10 arrives — what
  ## changes the tree is `current`, which F10 changes through `handleInput`.
  lastCols = cols
  lastRows = rows
  treeFor(r, current, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  buildTree(r, cols, rows, 0)

proc nowMs(): int64 =
  ## Milliseconds from a monotonic clock, for `keymap.resolve`'s bounded
  ## pending timeout. A wall clock would let an NTP step abandon a prefix.
  (getMonoTime() - MonoTime()).inMilliseconds

proc applyToken*(st: var AppState; token: string; cols, rows: int;
                 atMs: int64): bool =
  ## One input token against the state. Returns whether to repaint.
  ##
  ## PURE APART FROM `st`: the clock is passed in and the geometry is passed
  ## in, so the child's behaviour is reproducible from a transcript.
  let res = km.resolve(st.modal, st.pending, token, atMs)
  if res.kind == krNone and res.key.len == 0:
    return false                              # a mouse report, or noise
  st.lastKey = res.key
  st.lastKind = res.kind
  case res.kind
  of krAction:
    st.lastAction = res.action
    st.lastSpelling = res.spelling
    let (raises, ev) = modalEventFor(res.action)
    if raises:
      discard applyModalEvent(st.modal, ev)
    case res.action
    of kaQuit:
      st.quitRequested = true
    of kaFocusNextPane, kaFocusPrevPane:
      let pf = focusFor(cols, rows)
      discard pf.focusPaneKind(st.focused)
      let (moved, kind) =
        if res.action == kaFocusNextPane: pf.focusNextPane()
        else: pf.focusPrevPane()
      if moved:
        st.focused = kind
    of kaFocusLeft, kaFocusDown, kaFocusUp, kaFocusRight:
      let pf = focusFor(cols, rows)
      discard pf.focusPaneKind(st.focused)
      let (isDir, dir) = directionFor(res.action)
      if isDir:
        let (moved, kind) = pf.focusDirection(dir)
        if moved:
          st.focused = kind
    of kaSelectCallStack, kaSelectSource, kaSelectVariables, kaSelectTimeline:
      let (isSelect, kind) = directSelectPane(res.action)
      if isSelect:
        let pf = focusFor(cols, rows)
        if pf.focusPaneKind(kind):
          st.focused = kind
    of kaMaximizePane:
      discard toggleMaximize(st.maximize, st.focused)
    else:
      discard
    true
  of krText:
    st.modal.buffer.add res.key
    st.lastAction = kaNone
    true
  of krPending, krPendingAbandoned, krPendingTimedOut:
    st.lastAction = kaNone
    true
  of krNone:
    # A key nothing is bound to. Repainted anyway, so the screen SAYS the key
    # arrived and was not bound — which is what makes "nothing happened" and
    # "the key never got here" two different reports at Tier 2.
    st.lastAction = kaNone
    true

proc handleInput*(token: string): bool =
  ## The child's input handler. CHILD-SIDE ONLY: nothing in a test process may
  ## call this, or the Tier-1 view of `current` would stop being pristine.
  applyToken(current, token, lastCols, lastRows, nowMs())

proc framePrologue*(cols, rows: int): string =
  ## The cursor for the mode the app is in, as DECSCUSR + DECTCEM. See
  ## `app/input/modal_state.cursorControlBytes`.
  discard cols
  discard rows
  cursorControlBytes(current.modal.mode)

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams(),
    input = handleInput,
    prologue = framePrologue))
