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

import codetracer_embed   # PLAT-43: `KeymapModel`, `selectKeymap`

import ./commands/interpreter
import ./edit_binding
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
  EditReadResult* = object
    ## What a host's file reader answered.
    ##
    ## AN OBJECT AND NOT A TUPLE, and the reason is measured rather than
    ## stylistic: Nim 2.2.8 miscompiles a CLOSURE FIELD whose return type is a
    ## tuple — the generated call passes the first argument where the hidden
    ## result pointer belongs, and gcc rejects it
    ## (`expected 'tyTuple…*' but argument is of type 'NimStringV2'`). The
    ## whole `tui` lane went red on it. A named object also makes the call
    ## sites read as `answer.message` rather than `answer[2]`.
    ok*: bool
    text*: string
    message*: string
      ## What the user is shown on failure, so a refusal names the file and the
      ## reason rather than being a bare false.

  EditWriteResult* = object
    ok*: bool
    message*: string

  BuildStartResult* = object
    ok*: bool
    message*: string

  EditListResult* = object
    ## What a host's project walk found. Mirrors
    ## `host/edit_host.ProjectListing`, spelled here because `app/` may not
    ## import `host/`.
    files*: seq[string]
    truncated*: bool
      ## Whether the walk hit its cap. REPORTED rather than silent, for
      ## `edit_host.listProjectFiles`' own reason: a file tree missing files
      ## without saying so is a file tree a user concludes does not contain
      ## them.

  EditServices* = object
    ## PLAT-16's host seam. See `TuiRuntime.editServices`.
    readFile*: proc(relative: string): EditReadResult {.closure.}
    writeFile*: proc(relative, text: string): EditWriteResult {.closure.}
    listFiles*: proc(): EditListResult {.closure.}
      ## The project's files, for the file tree and for the buffer Edit mode
      ## opens on arrival.
      ##
      ## A CLOSURE AND NOT A VALUE, because the two loops that enter Edit mode
      ## learn the listing at different times. `main.editInteractive` takes it
      ## BEFORE the terminal is claimed — an unbounded walk behind a claimed
      ## alternate screen is what `host/edit_host.nim`'s header is written
      ## against — and hands back a closure over the value it already has.
      ## `main.interactive` cannot: a replay session may never press `Ctrl+F5`,
      ## and walking a project on every `ct replay` would put a filesystem walk
      ## inside CTUI-11's cold-start budget for a feature the session does not
      ## use. So its closure walks LAZILY, on the first switch. One consumer
      ## (`ensureEditWorkspace`), two suppliers, no branch in the consumer.
    startBuild*: proc(kind: BuildKind; command: string): BuildStartResult
      {.closure.}
    readConfig*: proc(spelled: string): EditReadResult {.closure.}
      ## PLAT-36. Read a user's Vim configuration for `:source`: `~`
      ## expanded, relative paths against the project. Unlike `readFile` it
      ## may reach outside the project — see `host/edit_host
      ## .readUserConfigFile`. Nil in a session with no host filesystem.
    saveKeymap*: proc(model: KeymapModel): string {.closure.}
      ## PLAT-43. Remember the chosen keymap model for the next session; ""
      ## on success, else a one-line message naming the path. Nil in a session
      ## whose host keeps no state — the choice then holds for this session
      ## only, and `:keymap` says so.
      ## Starts a build and takes ownership of the process. The SESSION it
      ## reports into is `TuiApp.build`, which the host fills, because the poll
      ## loop that advances it is the host's too.

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
    refreshesSession*: bool
      ## The engine's state changed WITHOUT a move — a breakpoint was set or
      ## cleared — so the host rebuilds the panes from the session, but must
      ## not pump for a `stopped` event that is not coming.
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
    keymapModel*: KeymapModel
      ## PLAT-43. The keymap model a NEW edit session starts under: the stored
      ## preference the host loaded, or the last `:keymap` choice. The product
      ## default until a host says otherwise.
    keymapNotice*: string
      ## PLAT-43. A stored keymap preference the host REFUSED, by name, to be
      ## shown when Edit mode is furnished — where it wins the status line over
      ## `editing … — N file(s)`, which would otherwise overwrite it within the
      ## same frame (measured by the pty suite's first run). Shown once.
    editServices*: EditServices
      ## PLAT-16. The HOST's three filesystem/process capabilities, injected.
      ##
      ## THE SAME CATEGORY AS CTUI-8's `EventPages` SEAM AND CTUI-10's
      ## `CommandServices`, and not a mock: `app/` may not open a file or spawn
      ## a process, so the only way `:w` can write is for the host to hand in
      ## the writer. In a shipped binary these are `host/edit_host.nim` and
      ## `host/build_runner.nim`; in a Tier-1 suite they are the suite, and what
      ## is asserted is what the runtime ASKED FOR rather than what a fake
      ## returned.
      ##
      ## A nil field is a reportable state and not a crash: `:w` in a session
      ## with no writer says so, which is the state a Debug-only session is in.
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

proc sourcePaneRows*(rt: TuiRuntime): int
  ## FORWARD-DECLARED. `runPromptLine`'s `:e` arm and `routeTokenToEditor` both
  ## need the editor rectangle's height — the first to size a new buffer's
  ## viewport, the second to follow the caret — and the definition sits with
  ## the other screen readers at the end of this module, where every reader of
  ## the projection is together.

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

proc changesSessionState*(action: KeyAction): bool =
  ## Whether a `drDone` for `action` changed what the session holds without
  ## moving it — the host refreshes the panes but pumps nothing.
  action == kaToggleBreakpoint

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

  # PLAT-16's FIVE EDIT VERBS, ROUTED HERE AND ONLY IN EDIT MODE.
  #
  # A SEPARATE SURFACE FROM §4.3, on exactly the argument PLAT-6's block above
  # makes and for exactly the same structural reason: §4.3's sixteen commands
  # are a published table `app/tests/test_gdb_command_surface.nim` parses out of
  # `CodeTracer-TUI.md` and compares row by row, so a seventeenth entry there is
  # a failing test by construction. `:build`, `:run`, `:cancel`, `:w` and `:e`
  # come from CodeTracer-TUI-Edit-Mode.md §5 instead, and they are a PREFIX on
  # this path.
  #
  # IN DEBUG MODE NOTHING CHANGES: they fall through to `runCommand` and are
  # reported as the unknown commands they have always been.
  if rt.app.modes.product == pmEdit:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    let verb = if words.len > 0: words[0] else: ""
    let rest = if words.len > 1: text[text.find(words[1]) .. ^1] else: ""
    case verb
    of "keymap":
      # PLAT-43. The keymap selector. The NAME is decided by
      # `keymap_selection.selectKeymap` and nowhere else — the same function
      # the stored preference goes through — so an unknown model is refused
      # by name with the accepted set rather than silently defaulted.
      let current =
        if rt.app.editSession.isNil: rt.keymapModel
        else: rt.app.editSession.model
      if rest.len == 0:
        let sourced =
          if rt.app.editSession.isNil or rt.app.editSession.imported.isNil: ""
          else: " with " & rt.app.editSession.imported.source & " sourced"
        rt.note("keymap " & $current & sourced &
                "; the accepted values are " & acceptedKeymapNamesText())
      else:
        let selection = selectKeymap(rest)
        if not selection.ok:
          rt.note(selection.refusal)
        else:
          if rt.app.editSession.isNil:
            rt.app.editSession = newEditSession(selection.model)
          rt.app.editSession.selectModel(selection.model)
          rt.keymapModel = selection.model
          let saved =
            if rt.editServices.saveKeymap.isNil:
              "not remembered: this session keeps no state"
            else: rt.editServices.saveKeymap(selection.model)
          rt.note("keymap " & $selection.model &
                  (if saved.len == 0: "" else: " (" & saved & ")"))
      outcome.detail = rt.app.notification
      return
    of "source", "so":
      # PLAT-36. A user's Vim configuration, imported on top of the Vim
      # keymap and installed for THIS SESSION. Not remembered: the stored
      # preference names a model, and an import is a model plus a file whose
      # contents may change — re-reading it silently at start-up would make
      # a key's meaning depend on a file the user did not name that day.
      # The status line carries §6.3's count and the first untranslated line.
      if rest.len == 0:
        rt.note(":source needs a file, e.g. ':source ~/.vimrc'")
      elif rt.editServices.readConfig.isNil:
        rt.note(":source has no reader in this session")
      else:
        let read = rt.editServices.readConfig(rest)
        if not read.ok:
          rt.note(read.message)
        else:
          let sourced = sourceVimConfig(rest, read.text)
          if rt.app.editSession.isNil:
            rt.app.editSession = newEditSession(kmVim)
          rt.app.editSession.installImported(sourced.imported)
          rt.keymapModel = kmVim
          rt.note(sourcedSummary(sourced))
      outcome.detail = rt.app.notification
      return
    of "w", "write":
      let buf = if rt.app.editSession.isNil: nil
                else: rt.app.editSession.activeBuffer()
      if buf.isNil:
        rt.note(":w needs an open file")
      elif rt.editServices.writeFile.isNil:
        rt.note(":w has no writer in this session")
      else:
        let written = rt.editServices.writeFile(buf.path, buf.text)
        if written.ok:
          # THE BUFFER STOPS BEING DIRTY AND GOES ON OUTRUNNING THE RECORDING,
          # and those are two predicates rather than one. §2.1's staleness is
          # about whether the bytes differ from what was RECORDED, not about
          # whether they are on disk, so saving must not silence the notice —
          # and saving makes a recording MORE stale, because after it the bytes
          # the recording was made from are gone from the disk too.
          #
          # THIS COMMENT USED TO CLAIM THAT AND BE WRONG, which is why it now
          # names the mechanism instead of the intention: `markSaved` updates
          # `loadedText` only, `edit_binding.outrunsRecording` compares against
          # `recordedText`, and `refreshEditedPaths` reads the second. The
          # effect is asserted in `test_edit_mode_source.nim` ("a saved edit is
          # still an edit the recording predates") and through the shipped
          # binary in `tests/real_terminal/test_real_edit_mode.nim` — not by
          # reading `editedPaths` here, which was true while the notice was
          # not.
          buf.markSaved()
          rt.note("wrote " & buf.path)
        else:
          rt.note(written.message)
      outcome.detail = rt.app.notification
      return
    of "e", "edit":
      if rest.len == 0:
        rt.note(":e needs a project-relative path")
      elif rt.editServices.readFile.isNil:
        rt.note(":e has no reader in this session")
      else:
        let opened = rt.editServices.readFile(rest)
        if opened.ok:
          if rt.app.editSession.isNil:
            rt.app.editSession = newEditSession(rt.keymapModel)
          discard rt.app.editSession.openFile(
            rest, opened.text, max(1, rt.sourcePaneRows()))
          rt.app.fileTree.openPath = rest
          rt.note("editing " & rest)
        else:
          rt.note(opened.message)
      outcome.detail = rt.app.notification
      return
    of "build", "run":
      if rest.len == 0:
        rt.note(":" & verb & " needs a command, e.g. ':" & verb &
                " just build'")
      elif rt.editServices.startBuild.isNil:
        rt.note(":" & verb & " has no runner in this session")
      elif not rt.app.build.isNil and rt.app.build.verdict == bvRunning:
        # ONE AT A TIME, and refused rather than queued: two compilers writing
        # into one pane produce interleaved output that belongs to neither, and
        # the verdict would be whichever finished last.
        rt.note("a " & $rt.app.build.kind & " is already running; :cancel it" &
                " first")
      else:
        let kind = if verb == "build": bkBuild else: bkRun
        let started = rt.editServices.startBuild(kind, rest)
        rt.note(started.message)
      outcome.detail = rt.app.notification
      return
    of "cancel":
      if rt.app.build.isNil or rt.app.build.verdict != bvRunning:
        rt.note("nothing is running")
      else:
        # THE FLAG, NOT A KILL. `app/` does not own the process; the host's
        # poll loop reads this on its next tick and terminates it, which is
        # what keeps the cancellation inside the same loop that reads the
        # keyboard. See `host/build_runner.pollBuild`.
        rt.app.build.requestCancel()
        rt.note("cancelling " & $rt.app.build.kind & " …")
      outcome.detail = rt.app.notification
      return
    else:
      discard

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
  # ONLY A NAVIGATION IS PUMPED. This said `drDone` alone until 2026-09-23,
  # which was harmless while every command that answered `drDone` moved the
  # debugger; `:break` answering `drDone` (its service is now wired) would have
  # blocked the loop on a `stopped` event no engine sends — see
  # `movesTheDebugger` on why that is a hang rather than a wrong screen.
  if result.dispatch.status == drDone:
    outcome.awaitsMove = movesTheDebugger(outcome.action)
    outcome.refreshesSession = changesSessionState(outcome.action)

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


const EditorOwnedKeys* = [
    "Backspace", "Delete", "Enter", "Left", "Right", "Up", "Down",
    "Home", "End", "Ctrl+z", "Ctrl+y"]
  ## The NON-PRINTABLE keys the editor takes when it is focused in Edit mode.
  ##
  ## `Tab` and `Shift+Tab` are DELIBERATELY ABSENT, and their absence is the
  ## escape hatch: with every printable key going into the buffer, a user needs
  ## one chord that is guaranteed to move focus off the editor, and this is it.
  ## `edit_binding.applyEditKey` still implements indent and dedent for them —
  ## the buffer can do it, nothing routes it — so the day an INSERT input mode
  ## exists the behaviour is already there rather than needing to be written.

const EditorEscapeKeys* = ["Tab", "Shift+Tab"]
  ## The keys the editor NEVER owns, whatever a model binds — `EditorOwnedKeys`'
  ## header gives the reason: a user needs one chord guaranteed to move focus
  ## off the editor. Named separately because PLAT-43's resolver clause below
  ## would otherwise hand `Tab` to the product default's `indent` binding —
  ## measured: the pty suite's first run typed an indent where it meant to
  ## leave the editor, and never reached the prompt.

proc editorOwnsToken*(rt: TuiRuntime; token: string): bool =
  ## Whether this token is text for the open buffer rather than a command.
  ##
  ## FOUR CONDITIONS, ALL OF THEM ALREADY-MODELLED STATE: Edit product mode,
  ## NORMAL input mode, the editor pane focused, and a buffer open. See the
  ## comment at the call site in `handleToken` for why it is not a fifth input
  ## mode, and for what that costs.
  if rt.isNil or rt.app.isNil:
    return false
  if rt.app.modes.product != pmEdit or rt.modal.mode != mmNormal:
    return false
  if rt.app.editSession.isNil or rt.app.editSession.activeBuffer().isNil:
    return false
  let (had, focused) = rt.focus.focusedPane()
  if not had or focused != paneEditor:
    return false
  let name = keyName(token)
  if name.len == 0:
    return false
  # PLAT-43: OR THE ACTIVE MODEL BINDS IT. `EditorOwnedKeys` is the product
  # default's non-printable set; a Vim buffer needs `Esc` and a Kakoune one
  # `Ctrl+x`, and a fixed list would hand those to the debugger's keymap. The
  # model's own resolver is asked — the one `applyEditKey` then runs — so the
  # two cannot disagree about whose key it is.
  if name in EditorEscapeKeys:
    return false
  name in EditorOwnedKeys or isTextKey(name) or
    rt.app.editSession.activeBuffer().claimsEditKey(name, 0)

proc routeTokenToEditor*(rt: TuiRuntime; token: string;
                         nowMs: int64): EditKeyOutcome =
  ## Apply one token to the open buffer and keep the session's bookkeeping
  ## honest.
  ##
  ## The three things that happen on a CHANGE and not on a move are the point:
  ## the edited path is recorded (so `assessTrace` sees it), the pane follows
  ## the caret, and nothing else. A caller that recorded an edit for an arrow
  ## key would declare a recording stale because somebody scrolled — see
  ## `edit_binding.EditKeyOutcome` on why the outcome is three-valued.
  ##
  ## **`nowMs` IS THE CLOCK PLAT-32's UNDO GROUPING NEEDS, AND IT WAS ALREADY
  ## HERE.** `handleToken` has taken it since CTUI-2 so the debugger keymap's
  ## prefix timeout is assertable at its bound without a sleep; the editing
  ## path simply never asked for it, and `editing_keymap.applyResolution`'s
  ## `applyOperation` call therefore ran at time zero on every keystroke. The
  ## parameter carries it the last step, and `applyEditKey` will not compile
  ## without it.
  ##
  ## `keyCharacter` IS NO LONGER CALLED HERE. `applyEditKey` takes the key
  ## name only and the resolver derives the character from it — one derivation
  ## instead of one per call site, which is CTUI-10's defect removed rather
  ## than re-avoided.
  let buf = rt.app.editSession.activeBuffer()
  result = buf.applyEditKey(keyName(token), nowMs)
  if result == ekChanged:
    rt.app.editSession.recordEdit(buf.path)
    rt.app.editSession.refreshEditedPaths()
  if result != ekIgnored:
    buf.followCaret(max(1, rt.sourcePaneRows()))

proc ensureEditWorkspace*(rt: TuiRuntime): string =
  ## Give this session an Edit-mode workspace if it has not got one: the file
  ## tree, and the first file open in a buffer. Returns the line to put on the
  ## status bar, or "" when there was nothing to do.
  ##
  ## ## WHY THIS EXISTS, AND WHAT IT CLOSES
  ##
  ## PLAT-16's landing pass found that **no shipped route had both a recording
  ## and an editable buffer**, so §2.1's stale-trace notice could not fire in
  ## the product at all:
  ##
  ##   * `ct edit --ui=tui <project>` (`main.editInteractive`) opens buffers and
  ##     has **no recording** — `app.traceName` is "" and `assessTrace` answers
  ##     `stvNoTrace`, correctly, because there is nothing for an edit to be
  ##     stale against. That is not a defect to fix; it is what `ct edit` IS.
  ##   * `ct replay --ui=tui <trace>` (`main.interactive`) has the recording and
  ##     used to reach `Ctrl+F5` with **no `EditServices` at all**, so the Edit
  ##     mode it switched into held an empty session, `activeBuffer()` was nil
  ##     and `:e` answered *"`:e` has no reader in this session"*.
  ##
  ## CodeTracer-TUI-Edit-Mode.md §6 is unambiguous about which of those two is
  ## wrong: *"`ct replay --ui=tui <trace>` opens in Debug mode. **The toggle
  ## moves between them within one session, as on the desktop.**"* So the
  ## notice belongs to the replay loop, and this is the function that gives
  ## that loop something to edit.
  ##
  ## ## IT IS CALLED FROM BOTH LOOPS, WHICH IS THE POINT (§14)
  ##
  ## One function, two callers: the toggle's `pmEdit` arm below, and
  ## `main.editInteractive` on startup. A second copy of "open the first file
  ## and fill the tree" in the entrypoint is exactly the duplicated predicate
  ## §14 is written about — and it is the copy nobody would mutate, because the
  ## entrypoint is not in any suite's module graph.
  ##
  ## ## IT RUNS ONCE PER SESSION
  ##
  ## `EditSession.furnished`, not `buffers.len > 0`: see that field. A second
  ## walk would also be a second chance to REPLACE an unsaved buffer, which
  ## Mode-Transitions.md §5 calls data loss by name.
  if rt.isNil or rt.app.isNil:
    return ""
  if rt.app.editSession.isNil:
    rt.app.editSession = newEditSession(rt.keymapModel)
  if rt.app.editSession.furnished or rt.editServices.listFiles.isNil:
    return ""
  rt.app.editSession.furnished = true
  let listing = rt.editServices.listFiles()
  rt.app.fileTree = initFileTreeModel(
    files = listing.files,
    selected = (if listing.files.len > 0: 0 else: -1),
    truncated = listing.truncated)
  let where = if rt.app.projectRoot.len > 0: rt.app.projectRoot else: "."
  result = "editing " & where & " — " & $listing.files.len & " file(s)" &
    (if listing.truncated: " (truncated)" else: "")
  # If the project has a file, open the first one, so arriving in Edit mode
  # means arriving at something rather than at an empty pane. §7: "The editor
  # is never empty."
  if listing.files.len == 0 or rt.editServices.readFile.isNil:
    return
  let first = rt.editServices.readFile(listing.files[0])
  if first.ok:
    discard rt.app.editSession.openFile(listing.files[0], first.text,
                                        max(1, rt.sourcePaneRows()))
    rt.app.fileTree.openPath = listing.files[0]
    # A REFUSED KEYMAP PREFERENCE WINS TOO, on the same rule: the session is
    # running a model the user did not choose, and "editing …" reads as if
    # it were.
    if rt.keymapNotice.len > 0:
      result = rt.keymapNotice
      rt.keymapNotice = ""
  else:
    # THE REFUSAL WINS THE STATUS LINE. A user who arrived in Edit mode and got
    # an empty pane must be told why; "editing … — 12 file(s)" over an empty
    # editor is the message that reads as success.
    result = first.message

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
  of kaToggleProductMode:
    # PLAT-16 / Mode-Transitions.md. `Ctrl+F5`.
    #
    # HANDLED LOCALLY AND NOT BY `dispatchAction`, on exactly the rule this
    # procedure's docstring states: CTUI-10's dispatcher is about the ENGINE,
    # and a product-mode switch is about this session's workspace. It sends
    # nothing to a backend — §1 of Mode-Transitions.md: the transition proper
    # "is instant in both directions, because both modes' state is already in
    # memory".
    let profile = selectProfile(rt.width, rt.height)
    let changed = rt.app.modes.toggle(rt.app.shellModel(rt.width, rt.height).layout,
                                      profile)
    if not changed:
      # Unreachable through `toggled`, which never answers the current mode.
      # Reported rather than dropped so a future caller of `switchTo` with an
      # explicit target cannot make an idempotent switch look like a working
      # one.
      rt.note("already in " & $rt.app.modes.product & " mode")
      outcome.repaint = true
      return true
    # THE NOTICE IS THE DELIVERABLE, not the switch. §2.1 consequence 3: a user
    # who edits and then toggles back onto an EXISTING trace is looking at a
    # recording their own edits have outrun, and must be told once, plainly.
    # `rt.app.traceName` is what says a recording is open at all — the toggle
    # onto no trace has nothing to be stale about, which is `stvNoTrace`.
    var message = "switched to " & $rt.app.modes.product & " mode"
    if rt.app.modes.product == pmEdit:
      # ARRIVING IN EDIT MODE MEANS ARRIVING AT SOMETHING. Until PLAT-16's
      # landing pass this arm only allocated an empty `EditSession`, so a
      # `ct replay` session that pressed `Ctrl+F5` reached an editor with no
      # buffer, no file tree and no reader — and therefore no route on which
      # the notice below could ever be produced. See `ensureEditWorkspace`.
      let furnished = rt.ensureEditWorkspace()
      if furnished.len > 0:
        message = furnished
    elif not rt.app.editSession.isNil:
      let notice = rt.app.editSession.noticeForSwitchToDebug(
        rt.app.traceName.len > 0)
      if notice.len > 0:
        message = notice
    rt.note(message)
    outcome.detail = message
    rt.rebuildFocus()
    # THE EDITOR TAKES THE FOCUS ON ARRIVAL, and it has to: `editorOwnsToken`
    # requires the editor pane focused before a typed byte is text rather than
    # a command, so a user who toggled into Edit mode and started typing would
    # otherwise be issuing keybindings at their own source. `rebuildFocus`
    # above re-derives the ring from the arrangement the next frame paints —
    # Edit mode's panes are not Debug's — and this names which of them wins.
    # Only when there is a buffer to type into: on an empty project the ring's
    # own answer is the honest one.
    if rt.app.modes.product == pmEdit and not rt.app.editSession.isNil and
       not rt.app.editSession.activeBuffer().isNil:
      discard rt.focus.focusPaneKind(paneEditor)
    outcome.repaint = true
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

  # PLAT-16, STEP 1a: THE EDITOR OWNS ITS OWN KEYS, and it owns them by FOCUS
  # rather than by a fifth input mode.
  #
  # The question "is this key text?" is answered by three facts that are all
  # already modelled: the PRODUCT mode is Edit, the INPUT mode is NORMAL, and
  # the FOCUSED pane is the editor. None of them is new state, which is why
  # this is what the milestone shipped.
  #
  # **THE REASON IS SCOPE, NOT §1.2, AND THE EARLIER SPELLING OF THIS COMMENT
  # HAD THAT WRONG.** It said §1.2 "forbids the obvious implementation — an
  # INSERT mode beside NORMAL/COMMAND/SEARCH/INSPECT". It does not. §1.2
  # forbids `UiMode` gaining **`EDIT`** — a PRODUCT mode masquerading as an
  # input mode — and its sentence is precise about which collapse it is
  # written against: *"`UiMode` … enumerates input modes and its cardinality is
  # asserted by `test_layout_profiles.nim`"*. `INSERT` is an INPUT mode, the
  # same family §4.1 enumerates, and adding it would be a fifth member of a
  # list that already has four; it is not the two-dimensions-into-one collapse
  # §1.2 exists to prevent. Deferring it is still right — a fifth input mode
  # moves `modal_state`'s machine, every transition into and out of it, the
  # cursor policy, the status indicator and the cardinality assertion, which is
  # a milestone of its own — but it is deferred because it is BIG, not because
  # it is FORBIDDEN, and a false prohibition in a comment is worse than an
  # acknowledged gap: it tells the next author the door is locked.
  #
  # WHAT THE DEFERRAL COSTS, RECORDED RATHER THAN DISCOVERED LATER: `:` is a
  # printable key, so while the editor is focused it types a colon instead of
  # opening the command prompt, and `q` types a `q` instead of quitting. `Tab`
  # is therefore deliberately NOT routed to the buffer — it stays "focus the
  # next pane", so there is always a key that gets the user out — and neither
  # is `Shift+Tab`. The consequence is that `:w`, `:build` and `:run` are
  # reached by tabbing off the editor first. That is an ergonomic hole and it
  # is named in PLAT-16's status note.
  if rt.editorOwnsToken(token):
    let outcome = rt.routeTokenToEditor(token, nowMs)
    if outcome != ekIgnored:
      result.repaint = true
      return

  let resolution = rt.keymap.resolve(rt.modal, rt.pending, token, nowMs,
                                     rt.app.modes.product)
  case resolution.kind
  of krNone:
    return
  of krInertInMode:
    # Mode-Transitions.md §8.1: "A chord whose action has no meaning in the
    # current mode must be inert AND SAY SO. … A key that silently does nothing
    # is indistinguishable from a key that is broken."
    #
    # The reason goes on the status line, which is "the surface the user is
    # looking at". `result.action` carries the action that WOULD have fired so
    # a caller can name it; `result.detail` carries the sentence so a test
    # asserts what the user was told rather than that something happened.
    result.action = resolution.action
    result.detail = resolution.reason
    rt.note(resolution.reason)
    result.repaint = true
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
  if dispatch.status == drDone and changesSessionState(resolution.action):
    result.refreshesSession = true

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
