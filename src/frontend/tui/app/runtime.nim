## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/runtime.nim — CTUI-11. What one input token DOES to a running
## debugger, as a function of a value.
##
## ## Why this is not in `main.nim`, and not in `host/`
##
## `main.nim` says of itself that it "wires `host/` to `app/` and nothing else"
## and that "the moment a decision here needs state it belongs in `app/`". An
## input loop is nothing but state: a modal mode, a pending chord prefix, a pane
## focus, a prompt buffer, a notification. All of it is here, and `main.nim` is
## the four lines that read a token off a terminal and hand it over.
##
## `host/` is wrong for the same reason from the other side: none of this needs
## a file descriptor. `handleToken` is a pure function of
## `(runtime, token, nowMs)` — the clock is passed in exactly as
## `keymap.resolve` takes it, so a bounded chord timeout is drivable without a
## sleep — and everything it can decide is reported in the returned
## `RuntimeOutcome` rather than done.
##
## ## THE HOST STILL OWNS THE BACKEND, AND THAT SPLIT IS LOAD-BEARING
##
## CTUI-10's `app/commands/interpreter.dispatchAction` is "THE ONE DISPATCH":
## every §4.2 binding and every §4.3 command reaches the debugger through it,
## and it is the only proc under `app/` that names a `DebugControlsVM` action.
## Calling it SENDS a DAP request through the store's injected `BackendService`.
## It does not, and cannot, wait for the answer — `ct/complete-move` arrives on
## an event and the blocking pump for it is `viewmodel/headless_session`, which
## `app/` may not import.
##
## So `RuntimeOutcome.awaitsMove` is how this layer says "a navigation command
## is in flight; pump it". CTUI-5 measured the consequence of getting this
## wrong and recorded it: with nothing pumping the event, a step is sent, the
## engine moves, and every pane keeps reporting the old position forever.

import std/strutils

import ./commands/interpreter
import ./input/keymap
import ./input/motions
import ./layout/project
import ./theme/degradation
import ./tui_app
import ./views/command_line
import ./views/shell

export interpreter, keymap, motions, command_line, tui_app, degradation

type
  RuntimeOutcome* = object
    ## Everything one token decided, as a value the host acts on.
    ##
    ## A VALUE RATHER THAN FOUR CALLBACKS, and the reason is the same one
    ## `app/cli.nim` gives for `TuiCommand`: the whole dispatch becomes
    ## assertable without a terminal, a process or a backend.
    repaint*: bool
      ## Whether anything the user can see changed.
    quit*: bool
      ## §4.2's `q` / `Ctrl+c`.
    awaitsMove*: bool
      ## A navigation command was SENT and the host must consume the
      ## `stopped` + `ct/complete-move` pair it will produce. See the module
      ## header.
    action*: KeyAction
      ## What fired, for the status line and for a test that wants to assert
      ## the binding rather than its effect.
    detail*: string
      ## The dispatch's own message. Copied into the notification, and kept
      ## here too so a caller can tell "nothing happened" from "the engine
      ## refused".

  TuiRuntime* = ref object
    ## The running front-end's state, minus the terminal and minus the process.
    app*: TuiApp
    caps*: TerminalCapabilities
      ## Handed in by `host/capabilities.negotiateCapabilities` before this
      ## object exists, for CTUI-11's "resolved before first paint".
    keymap*: Keymap
    modal*: ModalState
    pending*: PendingState
    focus*: PaneFocus
    maximize*: MaximizeState
    prompt*: CommandLineModel
      ## §3.3.6's `:` / `/` / `?` line. One model rather than three, and the
      ## kind on it says which sigil is showing — `command_line.open` is what
      ## resets the buffer between kinds.
    dispatcher*: Dispatcher
      ## CTUI-10's ViewModel bundle. Filled by the host, because every field is
      ## a ViewModel constructed over a store the host owns.
    context*: CommandContext
      ## Where the debugger IS, refreshed by the host after every move.
    lastToken*: string
    lastKey*: string
      ## For the status line and for a failure message: the exact bytes that
      ## arrived and the canonical name they resolved to.
    width*: int
    height*: int

const
  QuitDetail* = "quit"

proc newTuiRuntime*(app: TuiApp; caps: TerminalCapabilities;
                    width, height: int): TuiRuntime =
  ## A runtime over an application and a negotiated terminal.
  ##
  ## The FOCUS is seeded from the layout's own projection at this size rather
  ## than from a constant, so `Tab` cycles the panes that are actually on
  ## screen — CTUI-9's `newPaneFocus` takes a `Projection` for exactly that
  ## reason, and a Compact profile has fewer panes than an Ultra-wide one.
  let model = app.shellModel(width, height)
  let projection = projectLayout(model.layout, bodyArea(width, height))
  TuiRuntime(
    app: app, caps: caps,
    keymap: defaultKeymap(),
    modal: initModalState(),
    pending: initPendingState(),
    focus: newPaneFocus(projection),
    maximize: initMaximizeState(),
    prompt: initCommandLineModel(),
    dispatcher: Dispatcher(),
    context: CommandContext(),
    lastToken: "", lastKey: "",
    width: width, height: height)

proc resize*(rt: TuiRuntime; width, height: int) =
  ## Adopt a new terminal geometry, re-deriving the focus ring from the layout
  ## the new size projects to.
  ##
  ## The focus ring is REBUILT and the focused pane is CARRIED, which is the
  ## same guard `shell.reprofile` states for the active tab: a resize inside one
  ## profile's band must not silently move the user's focus, and a resize that
  ## crosses a band may legitimately remove the pane they were on.
  let (had, focused) = rt.focus.focusedPane()
  rt.width = width
  rt.height = height
  let model = rt.app.shellModel(width, height)
  let projection = projectLayout(model.layout, bodyArea(width, height))
  rt.focus = newPaneFocus(projection)
  if had:
    discard rt.focus.focusPaneKind(focused)

proc note(rt: TuiRuntime; message: string) =
  rt.app.notification = message

proc promptCandidates(rt: TuiRuntime): seq[string] =
  ## What `Tab` completes at the open prompt. §4.3's command names at `:`, and
  ## nothing at `/` or `?` — a search pattern is not drawn from a vocabulary.
  if rt.prompt.kind == pkCommand: commandNames() else: @[]

proc openPrompt(rt: TuiRuntime; kind: PromptKind): bool =
  discard rt.prompt.open(kind)
  true

proc runPromptLine(rt: TuiRuntime; line: string;
                   outcome: var RuntimeOutcome) =
  ## A committed prompt line, through CTUI-10's interpreter.
  ##
  ## Search prompts do not reach the interpreter: `/pattern` is not a §4.3
  ## command, and handing it to `parseCommand` would report "unknown command
  ## pattern" for a perfectly good search. It is reported as an unbuilt seam
  ## instead, by name — CTUI-10 built the incremental search MODEL
  ## (`app/views/search.nim`) and no pane in the shell binds it yet.
  if rt.prompt.kind != pkCommand:
    rt.note("search for `" & line & "` needs the source pane's search binding," &
            " which no milestone has wired to the shell yet")
    return
  if line.strip().len == 0:
    rt.note("")
    return
  let result = runCommand(rt.dispatcher, rt.context, line)
  outcome.detail = result.message
  var text = describeOutcome(result)
  if text.len == 0:
    text = result.message
  for extra in result.lines:
    text.add "  |  " & extra
  rt.note(text)
  if result.dispatch.status == drDone:
    outcome.awaitsMove = true

proc movesTheDebugger*(action: KeyAction): bool =
  ## Whether firing `action` sends a navigation command the host must pump.
  ##
  ## Enumerated rather than inferred from the dispatch result, because
  ## `drDone` is also what a purely local action answers: `kaMaximizePane`
  ## reports `drDone` and sends nothing, and a host that pumped after it would
  ## block on an event no engine is going to send. `waitForEvent` reads the
  ## pipe until its message budget runs out, so getting this wrong is a hang
  ## rather than a wrong screen.
  case action
  of kaStepOver, kaReverseStepOver, kaStepInto, kaReverseStepInto,
     kaStepOut, kaReverseStepOut, kaContinue, kaReverseContinue,
     kaPrevCall, kaNextCall, kaPrevMutation, kaNextMutation,
     kaJumpToStart, kaJumpToEnd, kaSeekToTick,
     kaValueOrigin, kaReverseOrigin: true
  else: false

proc applyLocalAction(rt: TuiRuntime; action: KeyAction;
                      outcome: var RuntimeOutcome): bool =
  ## The actions this layer answers WITHOUT the backend: focus, maximize, the
  ## three prompt keys. Returns whether it handled `action`.
  ##
  ## Handled here rather than in `dispatchAction` because none of them is a
  ## debugger command — CTUI-10's dispatcher is about the ENGINE, and focus is
  ## about this screen.
  case action
  of kaFocusNextPane:
    let (moved, pane) = rt.focus.focusNextPane()
    if moved: rt.note("focus " & $pane)
    outcome.repaint = moved
    true
  of kaFocusPrevPane:
    let (moved, pane) = rt.focus.focusPrevPane()
    if moved: rt.note("focus " & $pane)
    outcome.repaint = moved
    true
  of kaFocusLeft, kaFocusDown, kaFocusUp, kaFocusRight:
    let (known, dir) = directionFor(action)
    if not known:
      return false
    let (moved, pane) = rt.focus.focusDirection(dir)
    if moved:
      rt.note("focus " & $pane)
    else:
      rt.note("no pane " & $dir & " of the focused one")
    outcome.repaint = true
    true
  of kaSelectCallStack, kaSelectSource, kaSelectVariables, kaSelectTimeline:
    let (known, pane) = directSelectPane(action)
    if not known:
      return false
    let moved = rt.focus.focusPaneKind(pane)
    rt.note(if moved: "focus " & $pane else: $pane & " is not on this screen")
    outcome.repaint = true
    true
  of kaMaximizePane:
    let (had, focused) = rt.focus.focusedPane()
    if not had:
      rt.note("nothing is focused, so nothing can be maximized")
      outcome.repaint = true
      return true
    discard rt.maximize.toggleMaximize(focused)
    rt.note(if rt.maximize.active: "maximized " & $focused
            else: "restored the layout")
    outcome.repaint = true
    true
  of kaOpenCommandPrompt:
    outcome.repaint = rt.openPrompt(pkCommand)
    true
  of kaSearchForward:
    outcome.repaint = rt.openPrompt(pkSearchForward)
    true
  of kaSearchBackward:
    outcome.repaint = rt.openPrompt(pkSearchBackward)
    true
  of kaQuit:
    outcome.quit = true
    outcome.detail = QuitDetail
    true
  else:
    false

proc handleToken*(rt: TuiRuntime; token: string; nowMs: int64): RuntimeOutcome =
  ## ONE input token, end to end.
  ##
  ## The order is the §4.1/§4.2 order and each step is here because leaving it
  ## out changes an observable behaviour:
  ##
  ##   1. **An open prompt owns its keys first.** `command_line.applyKey`
  ##      answers `claUnhandled` for anything that is not a prompt key, so this
  ##      is a filter and not a swallow — but `Esc`, `Enter`, `Backspace`,
  ##      `Tab`, the arrows and every printable character belong to the prompt
  ##      while it is open, and CTUI-10 found the one that bites: `Space` is
  ##      `keyName` `"Space"`, and a resolver that classified it as a command
  ##      lost every space in `:goto 4500`.
  ##   2. **`keymap.resolve`**, which owns the pending-chord timeout and the
  ##      text-entry shadow.
  ##   3. **Local actions** — focus, maximize, opening a prompt, quitting.
  ##   4. **CTUI-10's dispatcher** for everything that is a debugger command.
  result = RuntimeOutcome(repaint: false, quit: false, awaitsMove: false,
                          action: kaNone, detail: "")
  rt.lastToken = token
  rt.lastKey = keyName(token)

  if rt.prompt.open:
    let before = rt.prompt.buffer
    let candidates = rt.promptCandidates()
    let submitted = token == "\r" or token == "\n"
    let line = if submitted: rt.prompt.buffer else: ""
    let cla = rt.prompt.applyKey(token, candidates)
    case cla
    of claUnhandled:
      discard
    of claSubmitted:
      rt.runPromptLine(line, result)
      discard rt.modal.applyModalEvent(meCommit)
      result.repaint = true
      return
    of claCancelled:
      discard rt.modal.applyModalEvent(meCancel)
      rt.note("")
      result.repaint = true
      return
    else:
      result.repaint = rt.prompt.buffer != before or cla == claCursorMoved or
                       cla == claNoCompletion or cla == claNoHistory
      if not result.repaint:
        # An edit that changed nothing still redraws: `claNoCompletion` puts a
        # message on the line, and a message the user cannot see is the same as
        # no message at all.
        result.repaint = true
      return

  let resolution = rt.keymap.resolve(rt.modal, rt.pending, token, nowMs)
  case resolution.kind
  of krNone:
    return
  of krPending, krPendingAbandoned, krPendingTimedOut:
    # The pending indicator is part of the screen (§4.2: "a visible pending
    # indicator"), so every one of these repaints.
    rt.note(if resolution.pending.len > 0: resolution.pending else: "")
    result.repaint = true
    return
  of krText:
    # A printable key in a text-accepting mode with no prompt open. Nothing in
    # this front-end is in that state today — the prompt is what makes a mode
    # text-accepting — so it is reported rather than dropped.
    rt.note("no text field is open for `" & resolution.character & "`")
    result.repaint = true
    return
  of krAction:
    discard

  result.action = resolution.action
  let (known, ev) = modalEventFor(resolution.action)
  if known:
    let transition = rt.modal.applyModalEvent(ev)
    if not transition.accepted:
      rt.note(describeTransition(transition))
      result.repaint = true
      return

  if rt.applyLocalAction(resolution.action, result):
    return

  let dispatch = dispatchAction(rt.dispatcher, rt.context, resolution.action)
  result.detail = dispatch.detail
  rt.note(dispatch.detail)
  result.repaint = true
  if dispatch.status == drDone and movesTheDebugger(resolution.action):
    result.awaitsMove = true

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

proc shellScreenOf*(rt: TuiRuntime): ShellScreen =
  ## The whole frame for this runtime, at its current size.
  ##
  ## The MODE reaches the status bar through `modal_state.statusMode`, and the
  ## LAYOUT through `motions.layoutFor` — so `z` really replaces the tree with a
  ## single-pane one rather than merely noting that it was pressed.
  var model = rt.app.shellModel(rt.width, rt.height)
  model.status.mode = statusMode(rt.modal.mode)
  if rt.maximize.active:
    # `z`. `motions.layoutFor` builds a one-pane `LayoutNode` of the SAME type
    # the profiles build, so `projectLayout`'s totality checks apply to the
    # maximized screen unchanged.
    model.layout = rt.maximize.layoutFor(model.profile)
  if rt.app.notification.len > 0:
    model.status.notification = rt.app.notification
  result = shellScreen(model, rt.width, rt.height)
  if rt.prompt.open and result.rows.len > 0:
    # §3.3.6's prompt replaces the status row while it is open. Painted over the
    # finished screen rather than folded into `ShellModel`, because
    # `app/views/shell.nim` is CTUI-3's and knows nothing about a prompt; the
    # row is the one the status bar occupies, so nothing else moves.
    let last = result.rows.len - 1
    let text = promptText(rt.prompt, rt.width)
    result.rows[last] = text
    result.styledRows[last] = @[StyledSpan(text: text, style: PromptStyle)]

proc sourcePaneRows*(rt: TuiRuntime): int =
  ## How many rows the `editor` rectangle has on the CURRENT screen, minus its
  ## own title row.
  ##
  ## THE NUMBER `SourceVM.setViewport` HAS TO BE GIVEN, and it is a property of
  ## the projection rather than of the terminal.
  ## `SourceVM.followExecutionPointer` scrolls the window it was TOLD about, so
  ## a viewport taller than the pane's rectangle puts the execution line on a row
  ## the pane never draws. Measured on `calc` at 120x40 with the viewport taken
  ## from the terminal's height: the engine was on line 55 and the pane was
  ## showing lines 23-51, with no pointer anywhere on the screen.
  ##
  ## Zero when no profile gives the editor a rectangle, which the caller must
  ## clamp — `setViewport(0)` would hold no lines at all.
  let model = rt.app.shellModel(rt.width, rt.height)
  let layout = if rt.maximize.active: rt.maximize.layoutFor(model.profile)
               else: model.layout
  let projection = projectLayout(layout, bodyArea(rt.width, rt.height))
  for region in projection.regions:
    if region.pane == paneEditor:
      return max(0, region.area.height - 1)
  0

proc promptCursor*(rt: TuiRuntime): (bool, int, int) =
  ## Where the terminal should park its cursor: `(visible, row, col)`, 0-based.
  ##
  ## `(false, …)` when no prompt is open, in which case the driver leaves the
  ## cursor on the frame barrier — `docs/tui-testing.md` records why an app that
  ## moves it needs `waitForCursorAt` instead of `waitForCompleteFrame`, and a
  ## front-end with no prompt open should not pay that.
  if not rt.prompt.open:
    return (false, 0, 0)
  (true, max(0, rt.height - 1), cursorColumn(rt.prompt))

proc describe*(rt: TuiRuntime): string =
  ## One line for a diagnostic: mode, focus, size, negotiated capabilities.
  let (had, pane) = rt.focus.focusedPane()
  "mode=" & $rt.modal.mode &
    " focus=" & (if had: $pane else: "-") &
    " size=" & $rt.width & "x" & $rt.height &
    " " & describe(rt.caps)
