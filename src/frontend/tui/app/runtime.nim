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
import ./layout/persistence
import ./layout/project
import ./theme/degradation
import ./tui_app
import ./views/command_line
import ./views/shell

export interpreter, keymap, motions, command_line, tui_app, degradation
export persistence

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
    layoutDocument*: string
      ## PLAT-6's persistence: where THIS session's rearranged layout is saved.
      ##
      ## **`""` WHENEVER PERSISTENCE IS OFF, which is every session without
      ## `--layout-binding` and every host that never named a document.** The
      ## path is held here rather than recomputed at exit because the two ends
      ## of a save must be the same file: a session that restored from one path
      ## and wrote to another would silently keep two arrangements for one
      ## recording. `host/layout_store.nim` is what fills it, and it is the only
      ## thing in this front-end that touches a file for this purpose.
    layoutDocumentQuarantined*: bool
      ## Whether this session started from a document it could NOT read.
      ##
      ## Carried across the whole session for one reason, and it is the
      ## expensive case the schema chain exists for: a document written by a
      ## NEWER build decodes as `ldeUnknownVersion` here, and a build that
      ## answered by overwriting it on exit would destroy a user's arrangement
      ## because they opened an older binary once. See
      ## `app/layout/persistence.LayoutPersistIntent`.

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

proc layoutBindingEnabled*(rt: TuiRuntime): bool =
  ## Whether PLAT-6's layout binding is driving this runtime's arrangement.
  ##
  ## **OFF BY DEFAULT, AND EVERYTHING BELOW IS GUARDED BY IT.** With no binding
  ## the model `tui_app.shellModel` builds is the one CTUI-3 built — the
  ## session's own `LayoutNode`, an empty `docked`, no `Interaction` — so the
  ## screen is byte-identical and `:move-tab` is the unknown command it has
  ## always been. That is not a temporary state: see `enableLayoutBinding` for
  ## what would have to change before the default could flip.
  not rt.isNil and not rt.app.isNil and not rt.app.layoutBinding.isNil

proc rebuildFocus(rt: TuiRuntime) =
  ## Re-derive the focus ring from the layout that will be painted next,
  ## carrying the focused pane if it is still on screen.
  ##
  ## Called after a resize AND after a layout command, because both can change
  ## which panes have a rectangle: `:dock left` takes one off the screen
  ## entirely, and a focus ring built before it would hand `Tab` a pane that is
  ## no longer projected.
  let (had, focused) = rt.focus.focusedPane()
  let model = rt.app.shellModel(rt.width, rt.height)
  let projection = projectLayout(model.layout, bodyArea(rt.width, rt.height))
  rt.focus = newPaneFocus(projection)
  if had:
    discard rt.focus.focusPaneKind(focused)

proc layoutGeometry*(rt: TuiRuntime): LayoutGeometry =
  ## The binding's geometry at this terminal size — the dock strips, the inner
  ## area and the pane-to-path resolution the next frame will be painted from.
  ##
  ## An empty geometry when no binding is enabled, so a caller cannot use this
  ## to conjure one.
  if not rt.layoutBindingEnabled():
    return LayoutGeometry()
  rt.app.layoutBinding.geometry(bodyArea(rt.width, rt.height))

proc enableLayoutBinding*(rt: TuiRuntime): LayoutBinding =
  ## **THE OPT-IN.** Give this running front-end a layout the user can
  ## rearrange, and route `:`'s layout verbs into it (PLAT-6).
  ##
  ## OPT-IN RATHER THAN THE DEFAULT, and the reason is one level below this
  ## module. `headless_app.HeadlessSessionSlot.layout` is a `LayoutNode`;
  ## a `LayoutBinding` holds a `Layout` whose tree is a CLONE
  ## (`newLayoutHistory` copies), so with a binding enabled the terminal draws
  ## the binding's tree and the session's own node is no longer what is on
  ## screen. Today nothing performs the operation that would make that visible —
  ## `headless_app.activatePane` has no production caller in this repository,
  ## its five call sites are all in `test_headless_app_entrypoint.nim`, and no
  ## key handler here reaches it — so the divergence is LATENT rather than
  ## current, which is exactly what makes an opt-in the right shape: it buys the
  ## gesture surface without creating the second authority for anybody who did
  ## not ask.
  ##
  ## **What would have to be true to flip the default:** `HeadlessSessionSlot`
  ## would have to hold a `Layout` rather than a `LayoutNode`, so that the
  ## session's arrangement and the binding's are one value and `activate` and a
  ## gesture cannot disagree. That is a change to the shared shell model — the
  ## one the desktop persists — and it is PLAT-4-level work rather than a
  ## binding's to make.
  ##
  ## The binding is seeded from the ACTIVE SESSION's own tree, so the first
  ## frame after this call is the frame that would have been painted without it.
  result = rt.app.enableLayoutBinding(rt.width, rt.height)
  # THE FOCUSED PANE IS THE RUNTIME'S, not a second one. `LayoutBinding.focus`
  # is what `:dock`, `:move-tab` and `:resize` act on, and `Tab` / `Ctrl+w` are
  # what a user moves it with — so the two are synchronised here and again
  # before every layout command.
  let (had, focused) = rt.focus.focusedPane()
  if had:
    result.focus = focused

# ---------------------------------------------------------------------------
# PLAT-6's persistence. THE DECISIONS ARE `app/layout/persistence.nim`'s and
# the file itself is `host/layout_store.nim`'s; what is here is the SESSION —
# which document this runtime is bound to, and what adopting one does to the
# rest of the runtime's state.
# ---------------------------------------------------------------------------

proc layoutPersistenceEnabled*(rt: TuiRuntime): bool =
  ## Whether this session saves and restores its arrangement.
  ##
  ## **BOTH HALVES ARE REQUIRED**, and the first is the one that matters: with
  ## no binding there is no arrangement to save, so `--layout-binding` gates
  ## persistence exactly as it gates the gestures. A host that enabled the
  ## binding and named no document gets the behaviour PLAT-6 shipped — a
  ## rearrangeable session that forgets.
  rt.layoutBindingEnabled() and rt.layoutDocument.len > 0

proc bindLayoutDocument*(rt: TuiRuntime; path: string) =
  ## Name the file this session's arrangement is saved to and restored from.
  ##
  ## Naming it does not read it: `host/layout_store.nim` does that and hands
  ## the bytes to `adoptLayoutDocument` below, which is the split
  ## `host/capabilities` -> `app/theme/capabilities` already uses.
  rt.layoutDocument = path
  rt.layoutDocumentQuarantined = false

proc adoptLayoutDocument*(rt: TuiRuntime; path, text: string):
    LayoutRestoreReport =
  ## Adopt one saved document into THIS session, and put the runtime back into
  ## a consistent state around it.
  ##
  ## Three things happen here that `persistence.adoptLayoutDocument` cannot do
  ## from where it sits, and each of them is a defect if it is left out:
  ##
  ##   * **the focus ring is rebuilt**, because a restored arrangement may have
  ##     docked away the pane the ring was seeded with — the same reason
  ##     `runPromptLine` and `routeMouseReport` rebuild it after a gesture. A
  ##     ring built from the profile default would hand `Tab` a pane that is
  ##     not on screen;
  ##   * **the binding's focus is synchronised to the ring**, so the first
  ##     typed verb of the session acts on the pane the user can see is
  ##     focused;
  ##   * **an unreadable document is remembered**, so exiting leaves it alone.
  result = rt.app.layoutBinding.adoptLayoutDocument(path, text)
  rt.layoutDocumentQuarantined = result.status == lrsUnreadable
  if result.status != lrsRestored:
    return
  rt.rebuildFocus()
  let (had, focused) = rt.focus.focusedPane()
  if had:
    rt.app.layoutBinding.focus = focused

proc markLayoutDocumentUnreadable*(rt: TuiRuntime) =
  ## Record a failure that happened BEFORE the bytes reached the decoder — a
  ## file that could not be opened at all. `host/layout_store.nim` is the only
  ## caller, because only it can meet that failure, and the consequence is the
  ## same one `adoptLayoutDocument` sets: the document is left alone on the way
  ## out.
  rt.layoutDocumentQuarantined = true

proc layoutPersistPlanOf*(rt: TuiRuntime): LayoutPersistPlan =
  ## What exiting should do with this session's document.
  ##
  ## `lpiQuarantine` for a session with persistence switched off as well as for
  ## one that started from an unreadable document, and that is deliberate
  ## rather than a coincidence of spelling: **quarantine is the intent that
  ## touches nothing**, which is exactly the answer "the flag is off" needs. A
  ## host that called this without checking would still write no file.
  if not rt.layoutPersistenceEnabled():
    return LayoutPersistPlan(intent: lpiQuarantine, text: "")
  layoutPersistPlan(rt.app.layoutBinding, rt.layoutDocumentQuarantined)

proc resize*(rt: TuiRuntime; width, height: int) =
  ## Adopt a new terminal geometry, re-deriving the focus ring from the layout
  ## the new size projects to.
  ##
  ## The focus ring is REBUILT and the focused pane is CARRIED, which is the
  ## same guard `shell.reprofile` states for the active tab: a resize inside one
  ## profile's band must not silently move the user's focus, and a resize that
  ## crosses a band may legitimately remove the pane they were on.
  rt.width = width
  rt.height = height
  # PLAT-6's responsive-profile decision, when a binding is enabled: the
  # profile always tracks the size, and the TREE is re-flowed only while the
  # user has not modified it. Before the model is read, so the focus ring below
  # is built from the arrangement the next frame will paint.
  if rt.layoutBindingEnabled():
    discard rt.app.layoutBinding.resize(width, height)
  rt.rebuildFocus()

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

  # PLAT-6's TWELVE LAYOUT VERBS, ROUTED HERE AND ONLY WHEN A BINDING IS
  # ENABLED. This is the line that makes a layout gesture reachable from the
  # product's own input path rather than from a test that constructs a
  # `LayoutBinding` directly, and it is what a Tier-2 case can drive through a
  # real pty.
  #
  # A SEPARATE SURFACE FROM §4.3, deliberately and structurally — see
  # `binding.LayoutVerb`: §4.3's sixteen commands are a published table
  # `app/tests/test_gdb_command_surface.nim` parses out of `CodeTracer-TUI.md`
  # and compares row by row, so a seventeenth value in that enum is a failing
  # test by construction. The routing is therefore a PREFIX on this path rather
  # than an entry in that table.
  #
  # WITH NO BINDING NOTHING CHANGES: `:move-tab` falls through to `runCommand`
  # and is reported as the unknown command it has always been, which is the
  # behaviour every existing suite asserts.
  if rt.layoutBindingEnabled():
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and parseLayoutVerb(words[0])[0]:
      # The pane a layout verb acts on is THE ONE `Tab` AND `Ctrl+w` MOVED TO.
      # Synchronised here rather than kept in step by convention, so `:dock
      # bottom` cannot dock a pane other than the focused one.
      let (had, focused) = rt.focus.focusedPane()
      if had:
        rt.app.layoutBinding.focus = focused
      let acted = rt.app.layoutBinding.runLayoutCommand(rt.layoutGeometry(),
                                                        line)
      outcome.detail = acted.message
      rt.note(acted.message)
      # A layout command can take a pane off the screen (`:dock`) or put one
      # back (`:undock`), so the focus ring is re-derived from the arrangement
      # the next frame will paint rather than from the one before the command.
      rt.rebuildFocus()
      return

  let result = runCommand(rt.dispatcher, rt.context, line)
  outcome.detail = result.message
  var text = describeOutcome(result)
  if text.len == 0:
    text = result.message
  for extra in result.lines:
    text.add "  |  " & extra
  rt.note(text)
  # THE ACTION THE COMMAND RESOLVED TO IS CARRIED OUT, so `handleToken` can
  # route it exactly as it routes the same action arriving as a KEY.
  #
  # CTUI-14 found the defect this closes, and `tests/real_terminal/
  # test_real_pty_lifecycle.nim` is what found it: §4.3 publishes `quit` (alias
  # `q`), `interpreter.dispatchAction` answered `drDone` for it, the status bar
  # said `quit` — and the session carried on, because ENDING THE LOOP IS NOT
  # SOMETHING THE DISPATCHER CAN DO. `kaQuit` is a local action; the loop that
  # stops is `main.nim`'s, and only `applyLocalAction` reaches it. The key path
  # (`q`, `Ctrl+c`) always went through there and always worked, which is why a
  # published command was broken behind two working keys.
  outcome.action = result.dispatch.action
  if result.dispatch.status == drDone:
    outcome.awaitsMove = true

proc routeMouseReport(rt: TuiRuntime; event: MouseEvent;
                      outcome: var RuntimeOutcome) =
  ## **PLAT-6's MOUSE HALF.** One decoded SGR-1006 report, as a layout gesture.
  ##
  ## This is the twin of `runPromptLine`'s layout-verb prefix and it closes the
  ## same kind of gap: `binding.onMouse`, `beginDrag`, `hoverAt` and `dropDrag`
  ## were reachable only from a test that constructed a `LayoutBinding`, so with
  ## `--layout-binding` on a typed `:dock bottom` rearranged a real terminal and
  ## a mouse drag did nothing. `host/terminal_driver` already enables SGR-1006
  ## when the capability was negotiated, already frames a whole report into one
  ## token, and `app/input/mouse.decodeMouse` already parses it; the only thing
  ## missing was this call.
  ##
  ## ## PRECEDENCE, WHICH IS THE PART THAT IS A DECISION RATHER THAN A WIRING
  ##
  ## **Nothing else in this front-end consumes a mouse report today**, and that
  ## is measured rather than assumed. CTUI-6's `input/call_stack_keys.applyMouse`
  ## and CTUI-8's `input/timeline_keys.applyMouse` exist and are asserted, and
  ## each is reached from exactly one place: its own module's `applyKey` /
  ## `applyToken`, which in turn is called only from `tests/apps/
  ## app_call_stack.nim` and `tests/apps/app_timeline.nim`. No path from this
  ## module reaches either. So there is no contest to resolve, and the rule
  ## below is written for when there is one:
  ##
  ##   * **The layout binding is offered the report first, and consumes it.**
  ##     Every cell of the body belongs to the layout — a dock strip, a tab
  ##     strip, a pane's title row, or a pane's body — and `onMouse` already
  ##     distinguishes them. In the last case what it does is FOCUS that pane,
  ##     which is what a pane-level consumer would need to have happened first
  ##     in any case.
  ##   * **`lasNoGesture` is the seam.** It is the value that means "the layout
  ##     did not act on this", and it is where a pane router belongs when a pane
  ##     grows a mouse contract — a wheel over a pane body already answers it by
  ##     name, precisely so scrolling can be handed on rather than stolen.
  ##
  ## ## THE TWO FOCUS NOTIONS ARE SYNCHRONISED IN BOTH DIRECTIONS
  ##
  ## `LayoutBinding.focus` is what a drop acts on and `PaneFocus` is what `Tab`
  ## and `Ctrl+w` move, exactly as in `runPromptLine` — so the binding is told
  ## where the keyboard's focus is BEFORE the gesture. Unlike a typed verb, a
  ## mouse press also MOVES the binding's focus (pressing in a pane's body is
  ## how a user focuses it with a pointer), so the answer is carried BACK
  ## afterwards. Without the return leg, clicking a pane and then pressing `Tab`
  ## would continue the ring from wherever the keyboard had left it and the
  ## status bar would name a pane the user is not on.
  let binding = rt.app.layoutBinding
  let (had, focused) = rt.focus.focusedPane()
  if had:
    binding.focus = focused
  let acted = binding.onMouse(rt.layoutGeometry(), event)
  outcome.detail = acted.message
  rt.note(acted.message)
  # A gesture can take a pane off the screen (a drop on a dock strip) or put one
  # back, so the ring is re-derived from the arrangement the NEXT frame will
  # paint — the same reason `runPromptLine` rebuilds it after a layout command —
  # and only then is the gesture's own pane carried into it.
  rt.rebuildFocus()
  discard rt.focus.focusPaneKind(binding.focus)
  # EVERY REPORT THE BINDING WAS OFFERED REPAINTS, and that is not a shrug.
  # `LayoutAction.message` is never empty by that type's own contract — "an
  # unknown command reports it; it never silently does nothing" — and the
  # message has just been written to the status line, so the screen has changed
  # whatever the binding decided. `main.nim`'s write coalescing is what keeps a
  # dragged pointer from costing a frame per report.
  outcome.repaint = true

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
  ##   0. **A mouse report is not a key, and it goes to the layout binding.**
  ##      PLAT-6, and only when a binding is enabled — see `routeMouseReport`
  ##      for the precedence rule and `enableLayoutBinding` for the opt-in.
  ##      Ahead of the prompt because a report is not a prompt key and
  ##      `command_line.applyKey` answers `claUnhandled` for one (its printable
  ##      arm requires `token.len == 1`), so taking it here removes nothing from
  ##      an open prompt.
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

  # PLAT-6's MOUSE HALF, ROUTED HERE AND ONLY WHEN A BINDING IS ENABLED. The
  # decoder is not even CALLED without one, so with the flag off this is one
  # predicate on a nil field and the token takes exactly the path it has always
  # taken: `keyName` answers "" for a mouse report and `keymap.resolve` reports
  # `krNone`, which is why a mouse has been inert in this front-end until now.
  if rt.layoutBindingEnabled():
    let (isMouse, event) = decodeMouse(token)
    if isMouse:
      rt.routeMouseReport(event, result)
      return

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
      # A §4.3 COMMAND MAY RESOLVE TO A LOCAL ACTION, and `quit` does. Routed
      # through the SAME `applyLocalAction` the key path uses rather than
      # answered here, so `:quit` and `q` cannot end a session differently.
      if result.action != kaNone:
        discard rt.applyLocalAction(result.action, result)
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
