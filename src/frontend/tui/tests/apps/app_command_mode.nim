## app_command_mode.nim — CTUI-10 snapshot app: the `:` prompt, the §4.3
## interpreter and the fuzzy palette, driven by real bytes on a real pty.
##
## One component tree, exported so the Tier-1 half of a suite composites the
## SAME proc in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime, the frame barrier and the
## input framing.
##
## ## WHY THIS APP EXISTS
##
## Everything about the command surface that can be decided in process IS
## decided in process — `app/tests/test_gdb_command_surface.nim` parses §4.3 out
## of the published document and compares it with the table, and
## `tests/test_value_origin_jump.nim` runs the dispatch against a real
## `replay-server`. Neither can say anything about the two facts
## `docs/tui-testing.md` lists as observable only from the terminal's side:
##
##   * **keys as bytes** — `:goto 4500\r` arriving one byte at a time on a real
##     file descriptor, framed by the runtime, decoded by `keymap.keyName`,
##     shadowed-or-not by `modal_state.isTextEntry`, and only then inserted into
##     a buffer or run. Every one of those steps is a place a prompt can be
##     correct in a value test and dead on a terminal.
##   * **cursor position** — §3.3.6's prompt is only a prompt if the terminal's
##     own cursor is sitting in it. "The model has no cursor" is a row of that
##     table, and CTUI-10 asks for `cursorPosition` specifically.
##
## ## THE CURSOR IS PARKED BY A `FrameEpilogue`, AND THAT CHANGES THE BARRIER
##
## `framePrologue` emits CTUI-9's DECSCUSR + DECTCEM so the cursor's SHAPE says
## which mode this is. `frameEpilogue` emits a CUP so its POSITION says where
## the prompt is — and because that moves the cursor off `(rows-1, cols-1)`, a
## parent driving this app waits on `dual_snap.waitForCursorAt` rather than on
## `waitForCompleteFrame` whenever a prompt is open. In NORMAL the epilogue is
## empty and the ordinary barrier holds, so the first frame is waited for the
## usual way. See `test_app_runtime.FrameEpilogue`.
##
## ## THERE IS NO DEBUGGER HERE, AND THE SCREEN SAYS SO
##
## A snapshot app has no session, so the `Dispatcher` it runs commands through
## has no ViewModels. That is not a stand-in for one: `interpreter.Dispatcher`
## documents nil as "not wired" and answers `drUnavailable` BY NAME, and what
## this app paints is exactly that answer. So the Tier-2 case can assert what
## `:goto 4500` PARSED to — the kind, the argument, the `KeyAction` — and that
## the dispatch reported rather than went silent, which is the whole of
## CTUI-10's second contract. That the seek really moves a debugger is
## `tests/test_value_origin_jump.nim`'s claim, on a real trace.
##
## ## THE STATE IS A VALUE, AND THE PAINT IS A FUNCTION OF IT
##
## `AppState` is a plain object and `paint` takes one. The module-level
## `current` is what the child's input handler mutates; nothing in a test
## process touches it, so the Tier-1 side of anything that imports this module
## sees the pristine initial state.

import std/strutils

import isonim_tui

import ../../app/commands/interpreter
import ../../app/input/keymap
import ../../app/input/modal_state
import ../../app/layout/profile
import ../../app/views/command_line
import ../../app/views/command_palette
import ../../app/views/header
import ../../app/views/search
import ../../app/views/status_bar
import ../../app/views/styled_row

const
  TitleText* = "CTUI-10 COMMAND MODE"
  TitleRow* = 0
  ModeRow* = 2
  PromptRow* = 3
  StatusRow* = 4
  CommandRow* = 5
  ArgumentRow* = 6
  ActionRow* = 7
  ResultRow* = 8
  MessageRow* = 9
  MatchesRow* = 10
  PaletteTopRow* = 12
  PaletteHeight* = 6

  ModeLabel* = "MODE   : "
  PromptLabel* = "PROMPT : "
  StatusLabel* = "STATUS : "
  CommandLabel* = "COMMAND: "
  ArgumentLabel* = "ARG    : "
  ActionLabel* = "ACTION : "
  ResultLabel* = "RESULT : "
  MessageLabel* = "MESSAGE: "
  MatchesLabel* = "MATCHES: "

  NoneText* = "-"
    ## What an empty field shows, so "nothing happened" is a glyph rather than
    ## a blank a test cannot tell from a paint that never ran.

  CommandLineRowFromBottom* = 2
    ## The `:` prompt sits one row above the status bar. §3.3.6 groups the two
    ## into one bottommost region; splitting them into two rows is what gives
    ## the prompt a cursor column a terminal can be asked about without
    ## reverse-engineering the status bar's own layout.

  SearchCorpus*: seq[string] = @[
    "pub fn iterate_asteroids(initial_shield: Field) -> bool {",
    "    let mut remaining_shield = initial_shield;",
    "    let damage = calculate_damage(initial_shield, remaining_shield);",
    "    remaining_shield -= damage;",
    "    status_report(initial_shield, remaining_shield, damage);",
  ]
    ## Five lines of the recorded program this campaign's fixture records, so
    ## `/` has something real to count matches in. Held as a `const` rather
    ## than read from disk because a snapshot app must be a pure function of
    ## its geometry — `runDualSnap` mounts the same `buildTree` in two
    ## processes and a file read would make them two different programs.

type
  AppState* = object
    ## Everything one keystroke can change, as a value.
    # QUALIFIED: `isonim_tui` re-exports its own M14 `modal` module, which has
    # a `ModalState` of its own. Two different concepts with one name.
    modal*: modal_state.ModalState
    pending*: keymap.PendingState
    prompt*: CommandLineModel
    searchModel*: SearchModel
    palette*: PaletteModel
    lastKey*: string
    lastAction*: KeyAction
    outcome*: CommandOutcome
    hasOutcome*: bool

proc paletteEntries(): seq[PaletteEntry] =
  ## §4.3's own table as a palette index. No session, so no functions and no
  ## files — the command rows are the part of §4.2's "files, functions,
  ## commands" that a snapshot app can carry honestly.
  result = @[]
  for spec in Spec43Commands:
    result.add commandEntry(spec.name, spec.summary, spec.argument)

proc initAppState*(): AppState =
  AppState(modal: initModalState(), pending: initPendingState(),
           prompt: initCommandLineModel(pkCommand),
           searchModel: initSearchModel(sscSource, sdirForward),
           palette: initPaletteModel(paletteEntries()),
           lastKey: "", lastAction: kaNone, outcome: CommandOutcome(),
           hasOutcome: false)

var current = initAppState()
var lastCols = 100
var lastRows = 24
let km = defaultKeymap()

proc fieldText*(label, value: string): string =
  label & (if value.len == 0: NoneText else: value)

proc statusModelFor*(st: AppState; cols, rows: int): StatusBarModel =
  initStatusBarModel(mode = statusMode(st.modal.mode),
                     profile = selectProfile(cols, rows),
                     notification = pendingIndicator(st.pending))

proc promptRowOf*(rows: int): int =
  max(0, rows - CommandLineRowFromBottom)

proc paint*(g: var StyledGrid; st: AppState; cols, rows: int) =
  ## The whole screen.
  if cols <= 0 or rows <= 0:
    return
  var title = TitleText & " "
  title.add repeatGlyph("─", max(0, cols - textCells(title)))
  g.paint(TitleRow, 0, fitCells(title, cols))
  g.paint(ModeRow, 0, fieldText(ModeLabel, $st.modal.mode))
  g.paint(PromptRow, 0, fieldText(PromptLabel, st.prompt.buffer))
  g.paint(StatusRow, 0, fieldText(StatusLabel,
    (if st.hasOutcome: $st.outcome.invocation.status else: "")))
  g.paint(CommandRow, 0, fieldText(CommandLabel,
    (if st.hasOutcome and st.outcome.invocation.status == csOk:
       $st.outcome.invocation.kind
     else: "")))
  g.paint(ArgumentRow, 0, fieldText(ArgumentLabel,
    (if st.hasOutcome: st.outcome.invocation.argument else: "")))
  g.paint(ActionRow, 0, fieldText(ActionLabel,
    (if st.hasOutcome: $st.outcome.dispatch.action else: "")))
  g.paint(ResultRow, 0, fieldText(ResultLabel,
    (if st.hasOutcome: $st.outcome.dispatch.status else: "")))
  g.paint(MessageRow, 0, fitCells(
    fieldText(MessageLabel, (if st.hasOutcome: st.outcome.message else: "")),
    cols))
  g.paint(MatchesRow, 0, fieldText(MatchesLabel,
    (if st.searchModel.query.len > 0: st.searchModel.matchCountText()
     else: "")))
  if st.palette.open:
    paint(g, st.palette, PaletteTopRow, 0, cols, PaletteHeight)
  let promptRow = promptRowOf(rows)
  if promptRow > MatchesRow:
    g.paint(promptRow, 0, fitCells(
      (if st.prompt.open: promptText(st.prompt, cols) else: ""), cols))
  if rows > 1:
    let model = statusModelFor(st, cols, rows)
    g.paint(rows - 1, 0, statusBarText(model, cols))
    # THE MODE INDICATOR, REPAINTED IN ITS OWN COLOUR — same text, so the row's
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
  ## The screen before any key arrives, as a PURE function of the geometry.
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
  ## `step` is ignored: this app is driven by real keys, and what changes the
  ## tree is `current`, which `handleInput` changes.
  lastCols = cols
  lastRows = rows
  treeFor(r, current, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  buildTree(r, cols, rows, 0)

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

proc runLine(st: var AppState; line: string) =
  ## §4.3, through the product's own `runCommand`, with NO ViewModels — see
  ## this module's header on why that is the honest wiring for a snapshot app
  ## and not a mock.
  st.outcome = runCommand(Dispatcher(), CommandContext(), line)
  st.hasOutcome = true

proc applyToken*(st: var AppState; token: string; cols, rows: int;
                 atMs: int64): bool =
  ## One input token against the state. Returns whether to repaint.
  let res = km.resolve(st.modal, st.pending, token, atMs)
  if res.kind == krNone and res.key.len == 0:
    return false                                # a mouse report, or noise
  st.lastKey = res.key
  case res.kind
  of krText:
    # A PRINTABLE KEY IN A TEXT-ACCEPTING MODE. `keymap.resolve` decided that,
    # not this app: the shadowing rule is stated once, in one module.
    st.lastAction = kaNone
    # `res.character`, NOT `res.key`: `keyName(" ")` is `"Space"` and a prompt
    # that inserted the NAME would type the word into the buffer. See
    # `keymap.keyCharacter`.
    #
    # ONE BUFFER. The prompt owns what was typed and the palette's query is a
    # projection of it, rather than a second buffer that can disagree with the
    # cursor column the terminal is asked about.
    discard st.prompt.insert(res.character)
    if st.palette.open:
      discard st.palette.setQuery(st.prompt.buffer)
    elif st.modal.mode == mmSearch:
      discard st.searchModel.updateQuery(SearchCorpus, st.prompt.buffer)
    st.modal.buffer = st.prompt.buffer
    true
  of krAction:
    st.lastAction = res.action
    let (raises, ev) = modalEventFor(res.action)
    case res.action
    of kaOpenCommandPrompt:
      if raises and applyModalEvent(st.modal, ev).accepted:
        discard st.prompt.open(pkCommand)
        st.hasOutcome = false
    of kaCommandPalette:
      if raises and applyModalEvent(st.modal, ev).accepted:
        discard st.prompt.open(pkCommand)
        discard st.palette.open()
        st.hasOutcome = false
    of kaSearchForward, kaSearchBackward:
      if raises and applyModalEvent(st.modal, ev).accepted:
        let dir = if res.action == kaSearchForward: sdirForward
                  else: sdirBackward
        st.searchModel = initSearchModel(sscSource, dir)
        discard st.prompt.open(
          if dir == sdirForward: pkSearchForward else: pkSearchBackward)
    of kaCommitPrompt:
      if st.palette.open:
        let (has, line) = st.palette.selectedCommand()
        st.palette.close()
        discard st.prompt.cancel()
        if has:
          st.runLine(line)
        discard applyModalEvent(st.modal, meCancel)
      elif st.modal.mode == mmCommand:
        let (_, line) = st.prompt.submit()
        st.runLine(line)
        discard applyModalEvent(st.modal, meCommit)
      elif st.modal.mode == mmSearch:
        discard st.prompt.submit()
        discard st.searchModel.commit(1)
        discard applyModalEvent(st.modal, meCommit)
    of kaReturnToNormal:
      st.palette.close()
      discard st.prompt.cancel()
      discard applyModalEvent(st.modal, meCancel)
    of kaPromptBackspace:
      discard st.prompt.backspace()
      if st.palette.open:
        discard st.palette.setQuery(st.prompt.buffer)
      elif st.modal.mode == mmSearch:
        discard st.searchModel.updateQuery(SearchCorpus, st.prompt.buffer)
      st.modal.buffer = st.prompt.buffer
    of kaNextMatch:
      discard st.searchModel.nextMatch()
    of kaPrevMatch:
      discard st.searchModel.prevMatch()
    else:
      if raises:
        discard applyModalEvent(st.modal, ev)
    true
  of krPending, krPendingAbandoned, krPendingTimedOut:
    st.lastAction = kaNone
    true
  of krNone:
    # A key nothing is bound to. Repainted anyway, so the screen SAYS the key
    # arrived and was not bound.
    st.lastAction = kaNone
    true

proc handleInput*(token: string): bool =
  ## The child's input handler. CHILD-SIDE ONLY: nothing in a test process may
  ## call this, or the Tier-1 view of `current` would stop being pristine.
  applyToken(current, token, lastCols, lastRows, 0'i64)

proc framePrologue*(cols, rows: int): string =
  ## CTUI-9's cursor SHAPE and visibility for the mode.
  discard cols
  discard rows
  cursorControlBytes(current.modal.mode)

proc cursorParkBytes*(st: AppState; cols, rows: int): string =
  ## CUP to the prompt, or "" in NORMAL.
  ##
  ## `CSI row ; col H` is 1-based — https://invisible-island.net/xterm/ctlseqs/
  ## ctlseqs.html, "Cursor Position". The column is the prompt's own
  ## `cursorColumn`, so what the terminal reports is the model's answer rather
  ## than a number this app computed a second time.
  if not st.prompt.open:
    return ""
  let row = promptRowOf(rows) + 1
  let col = min(st.prompt.cursorColumn(), max(0, cols - 1)) + 1
  "\x1b[" & $row & ";" & $col & "H"

proc frameEpilogue*(cols, rows: int): string =
  cursorParkBytes(current, cols, rows)

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
    prologue = framePrologue,
    epilogue = frameEpilogue))
