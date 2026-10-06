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

import std/[options, os, strutils, tables]

import codetracer_embed   # PLAT-43: `KeymapModel`, `selectKeymap`
import headless_app/auto_hide_hover

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
import ./views/event_log
import ./views/vcs_pane

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
    submitFileJob*: proc(job: FileJob) {.closure.}
      ## PLAT-29. Hand a read (`:e!`) or a write (`:w`) to the host's file
      ## worker (`host/file_worker`), which answers through `deliverFileJob`.
      ## Nil in a session with no host thread: the job then runs inline
      ## through `readFile` / `writeFile` and is delivered at once, down the
      ## same reconciliation.
    requestHighlight*: proc(req: HighlightRequest) {.closure.}
      ## PLAT-29. Hand a parse to the host's worker thread
      ## (`host/highlight_worker`), which answers through `deliverHighlight`.
      ## Nil in a session with no host thread — the suites — where the SAME
      ## `computeHighlight` runs inline, so both routes classify identically.
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

  PaneClickKind* = enum
    ## PLAT-50: what a click in a pane asks the HOST to do — the operations
    ## that need the session (`headless_app/pane_clicks`' shared ops). The
    ## ones the runtime can do on its own models (a variable expanded, a
    ## menu opened, a point selected) never reach the host.
    pcNone
    pcOpenFile
      ## Files: a file — show it in the editor (`path`).
    pcToggleFolder
      ## Files: a folder — expand or collapse it (`path`).
    pcToggleBreakpoint
      ## The editor's gutter: a breakpoint on `path:line`, or none.
    pcSetBreakpointEnabled
      ## The editor's gutter, right-click: `enabled` for `path:line`'s.
    pcLineJump
      ## The editor's text, Ctrl / middle click or the menu: go to
      ## `path:line` (`behaviour`: smart, forward, backward).
    pcEventJump
      ## The event log: go to the event whose log index is `index`.
    pcSeek
      ## The timeline: go to `tick`.
    pcDeleteBreakpoints
      ## The editor's menu: delete every breakpoint of `path` ("Delete
      ## breakpoints in file"), or of every file when `path` is "" ("Delete
      ## ALL breakpoints").
    pcColumnBreakpoint
      ## The editor's text, Alt+click: a breakpoint on `path:line` anchored
      ## at `column`.
    pcCallJump
      ## Ctrl+Alt+click on a call, or the menu's call jumps: go to the call
      ## of `text` (the word) on `path:line` (`behaviour`).
    pcEventOrder
      ## The event log's header: order the log by `order`.
    pcScratchpadAdd
      ## Pin `values` to the scratchpad.
    pcScratchpadRemove
      ## The scratchpad's close button: remove the value at `index`.
    pcValueHistory
      ## The Variables menu's "Toggle value history" on the variable at
      ## `path`.
    pcValueOrigin
      ## The Variables menu's "Show value origin" on the variable at `path`.
    pcVcsDiff
      ## The VCS pane: show the diff of `path` (`text` its state letter) —
      ## the working tree's, or commit `behaviour`'s when it names one.
    pcVcsCommit
      ## The VCS pane: open or close commit `index`.
    pcTerminalView
      ## PLAT-52: the Terminal Output pane's toggle — show the view named by
      ## `text` (`lines` / `screen`), remembered for this recording.

  PaneClickRequest* = object
    kind*: PaneClickKind
    path*: string
    line*: int
    column*: int
    index*: int64
    tick*: uint64
    enabled*: bool
    behaviour*: string
    text*: string
      ## An event's content (`pcEventJump`), the word a call jump names.
    values*: seq[NamedValue]
      ## The (expression, value) pairs `pcScratchpadAdd` pins.
    order*: EventLogOrder
      ## `pcEventOrder`'s order.

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
    awaitsOrigin*: bool
      ## `o` / `:origin` ASKED for a chain (`ct/originChain`) rather than
      ## moving: no `stopped` comes, so the host must not pump a move. It
      ## takes the `ct/updated-origin-chain` answer into the Origin ViewModel
      ## and runs the action again (`retryOrigin`), which then walks the
      ## chain — `interpreter.dispatchOrigin`'s arm 2. Until this, the host
      ## pumped a move here and the terminal froze waiting for one.
    originRetry*: string
      ## The command line to run again (`:origin X`), or "" for the key.
    refreshesSession*: bool
      ## The engine's state changed WITHOUT a move — a breakpoint was set or
      ## cleared — so the host rebuilds the panes from the session, but must
      ## not pump for a `stopped` event that is not coming.
    pagesCallTrace*: bool
    jumpsToCall*: bool
      ## PLAT-49 part B: a click on a call-trace row — the host goes to that
      ## call (`ct/calltrace-jump`, the desktop's click) and refreshes.
    togglesCall*: bool
      ## PLAT-49 part B: a click on a row's toggle — the host expands or
      ## collapses that call's children (`ct/expand-calls` /
      ## `ct/collapse-calls`) and reloads the section.
    callIndex*: int64
      ## The trace index `jumpsToCall` / `togglesCall` act on.
    paneClick*: PaneClickRequest
      ## PLAT-50: a click in a pane that the host carries out.
      ## PLAT-47. The reader scrolled the call trace: the host loads the
      ## section of the trace the pane now shows, if it does not hold it
      ## (`tui_session.pageCallTrace`), and nothing else — no pump, no
      ## rebuild of the other panes.
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
    themeService*: proc(name: string): bool {.closure.}
      ## The HOST's live mode switch behind §4.3's `:theme <dark|light>`: it
      ## re-resolves the terminal capabilities with the named design-system
      ## mode pinned, adopts them on the driver (so the next frame is a full
      ## repaint) and updates `caps`. Nil in a host that cannot repaint, where
      ## `:theme` answers `unsupported` by name. The host installs it into
      ## `dispatcher.services.setTheme` wherever it builds the dispatcher.
    layoutCommitted*: proc(rt: TuiRuntime) {.closure.}
      ## PLAT-45 deliverable 8: the HOST's write-through, called after every
      ## layout command or gesture that COMMITTED a change (`lasApplied`), so
      ## a crash loses nothing. `host/layout_store.nim` is what it runs in a
      ## shipped binary; nil in a host that does not persist, where nothing
      ## happens. A hook rather than a call, because `app/` may not open a
      ## file.
    saveIcons*: proc(mode: IconsMode): string {.closure.}
      ## PLAT-48: the HOST's write of the `icons` setting (`:icons`), "" on
      ## success. Nil in a host that keeps no state.
    autoHide*: AutoHideHover
      ## PLAT-49 part B (finding 9): the pointer's timing over the auto-hide
      ## labels — the desktop's hover preview and leave dismissal
      ## (`headless_app/auto_hide_hover`). Medium state, held here, never in
      ## the layout.
    topBarPressConsumed*: bool
      ## PLAT-48: the top bar (or an open menu / omnibar) took the last
      ## press, so its release is not a layout gesture.
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

proc paneBodyRows*(rt: TuiRuntime; pane: PaneKind): int
  ## FORWARD-DECLARED for the call trace's scroll keys; defined beside
  ## `sourcePaneRows`.

proc runFileJob(rt: TuiRuntime; job: FileJob)
  ## FORWARD-DECLARED for the `:w` and `:e!` arms of `runPromptLine`; defined
  ## beside `deliverFileJob`, the answer it hands a job to.

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
    width: width, height: height,
    autoHide: initAutoHideHover())

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

proc afterLayoutCommit(rt: TuiRuntime) =
  ## A layout command or gesture committed a change. Two consequences, both
  ## PLAT-45 deliverable 8 (and the half PLAT-4 handed forward):
  ##
  ##   * **the session's own slot is told**, when there is one, so the
  ##     arrangement a `HeadlessApp.saveLayouts` would write is the one on
  ##     screen — the binding and the session no longer diverge after the
  ##     first gesture;
  ##   * **the host writes it through** (`layoutCommitted`), so the terminal's
  ##     remembered arrangement is current after every change rather than only
  ##     after a clean exit.
  if not rt.layoutBindingEnabled():
    return
  let slot = rt.app.shell.activeSlot()
  if not slot.isNil:
    slot.layout = rt.app.layoutBinding.layout.clone()
  if not rt.layoutCommitted.isNil:
    rt.layoutCommitted(rt)

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

proc refreshMenuForKeymap*(rt: TuiRuntime)
  ## FORWARD-DECLARED for `:keys`; defined with the top bar below.

const EventLogColumnVerbs* = ["columns", "column-show", "column-hide",
                              "column-left", "column-right"]
  ## PLAT-49 part B: the event log's column verbs (`runColumnVerb`).

proc describeColumns(c: EventLogColumns): string =
  var parts: seq[string] = @[]
  for col in c.order:
    parts.add (if c.isVisible(col): "" else: "(") & eventLogColumnTitle(col) &
              (if c.isVisible(col): "" else: ")")
  "event log columns: " & parts.join(" ") & " — hidden in parentheses"

proc runColumnVerb*(rt: TuiRuntime; verb, arg: string): string =
  ## One column verb against the event log's `EventLogColumns`; answers the
  ## status line's text (every verb says what it did, or why it did nothing).
  if verb == "columns":
    return describeColumns(rt.app.eventLog.columns)
  if arg.len == 0:
    return ":" & verb & " needs a column: tick, #, location, kind or output"
  let (ok, col) = parseEventLogColumn(arg)
  if not ok:
    return "no event log column '" & arg &
           "'; the columns are tick, #, location, kind and output"
  var c = rt.app.eventLog.columns
  let changed =
    case verb
    of "column-show": c.showColumn(col)
    of "column-hide": c.hideColumn(col)
    of "column-left": c.moveColumn(col, -1)
    else: c.moveColumn(col, 1)
  if not changed:
    return "event log column " & eventLogColumnTitle(col) & ": " &
      (case verb
       of "column-show": "already shown"
       of "column-hide":
         (if not c.isVisible(col): "already hidden"
          else: "the last visible column stays")
       else: (if not c.isVisible(col): "hidden; show it first"
              else: "already at that end"))
  rt.app.eventLog.columns = c
  describeColumns(c)

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

  # PLAT-48's TWO TOP-BAR VERBS, `:icons` and `:keys`. A separate surface
  # from §4.3 for the reason the layout verbs below give (its sixteen
  # commands are a published table), and routed in every product mode.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and words[0] in ["icons", "keys"]:
      let arg = if words.len > 1: words[1] else: ""
      if words[0] == "icons":
        if arg.len == 0:
          rt.note("icons " & $rt.app.icons & "; the accepted values are " &
                  iconsModeNames())
        else:
          let (ok, mode) = parseIconsMode(arg)
          if not ok:
            rt.note("unknown icons value '" & arg &
                    "'; the accepted values are " & iconsModeNames())
          else:
            rt.app.icons = mode
            rt.app.iconsChosen = true
            let saved =
              if rt.saveIcons.isNil: "not remembered: this session keeps " &
                                     "no state"
              else: rt.saveIcons(mode)
            var msg = "icons " & $mode
            if mode == imGraphics and not rt.app.graphicsDrawn:
              msg.add " — this terminal did not answer the graphics query, " &
                      "so the controls are drawn as unicode"
            if saved.len > 0:
              msg.add " (" & saved & ")"
            rt.note(msg)
      else:
        # `:keys <file>` layers a `.cttui-keys` file (CTUI-9's user keymap)
        # over the built-in table; `:keys default` goes back to the table.
        # The menu's shortcuts and the controls' tooltips follow at once —
        # they are read from the active keymap, never written beside it.
        if arg.len == 0 or arg == "default":
          rt.keymap = defaultKeymap()
          rt.note("keys: the built-in table")
        else:
          if not fileExists(expandTilde(arg)):
            rt.note("keys: no such file: " & arg)
            outcome.detail = rt.app.notification
            return
          try:
            let load = loadKeymapFile(defaultKeymap(), expandTilde(arg))
            rt.keymap = load.keymap
            rt.note(if load.errors.len == 0: "keys " & arg
                    else: describeError(load.errors[0]))
          except CatchableError as e:
            rt.note("keys: " & arg & ": " & e.msg)
        rt.refreshMenuForKeymap()
      outcome.detail = rt.app.notification
      return

  # PLAT-49 part B (finding 14): THE EVENT LOG'S COLUMN VERBS — the desktop's
  # show / hide / reorder capability, over the Event Log ViewModel's column
  # model (`EventLogColumns`). `:columns` lists them; `:column-show NAME`,
  # `:column-hide NAME`, `:column-left NAME`, `:column-right NAME`.
  block:
    var text = line.strip()
    if text.startsWith(":"):
      text = text[1 .. ^1].strip()
    let words = text.splitWhitespace()
    if words.len > 0 and words[0] in EventLogColumnVerbs:
      rt.note(rt.runColumnVerb(words[0],
                               (if words.len > 1: words[1] else: "")))
      outcome.detail = rt.app.notification
      outcome.repaint = true
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
      if acted.status == lasApplied:
        rt.afterLayoutCommit()
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
    of "break", "b":
      # §4.3's `:break`, in Edit mode: the same toggle `F9` makes, at the
      # caret or at the line given. A function name — which Debug mode
      # resolves against the recording — has nothing to resolve against here,
      # and is refused by name rather than guessed.
      let buf = if rt.app.editSession.isNil: nil
                else: rt.app.editSession.activeBuffer()
      if buf.isNil:
        rt.note("no file is open to place a breakpoint in")
      else:
        var line = buf.caretLine
        var ok = true
        if rest.len > 0:
          try:
            line = parseInt(rest)
          except ValueError:
            ok = false
            rt.note("`" & rest & "` is not a line number; in Edit mode " &
                    ":break takes a line of " & buf.path)
        if ok and (line < 1 or line > buf.lineCount):
          ok = false
          rt.note(buf.path & " has no line " & $line)
        if ok:
          let placed = rt.app.editSession.togglePointAt(buf.path, line)
          rt.note((if placed: "breakpoint at " else: "removed the breakpoint at ") &
                  buf.path & ":" & $line)
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
      elif rt.editServices.writeFile.isNil and
           rt.editServices.submitFileJob.isNil:
        rt.note(":w has no writer in this session")
      else:
        # PLAT-29: a WRITE IS A PRODUCER. The bytes of this version go to the
        # host's file worker; its acknowledgement arrives through
        # `deliverFileJob`, which marks the buffer saved as of exactly those
        # bytes and says "wrote …". A session with no worker runs it inline,
        # down the same path.
        rt.note("writing " & buf.path & "…")
        rt.runFileJob(fileJobFor(fjWrite, buf.doc, buf.path, buf.serial))
      outcome.detail = rt.app.notification
      return
    of "e!", "edit!":
      # PLAT-29. Vim's `:e!`: reload the open file from disk. The read is a
      # producer — see `file_io_producer` — so a reload the user typed past
      # while it was in flight is discarded and SAID so, never installed
      # over the typing; one that lands on an unmoved buffer replaces its text
      # through the editing core, where it can be undone.
      let buf = if rt.app.editSession.isNil: nil
                else: rt.app.editSession.activeBuffer()
      if buf.isNil:
        rt.note(":e! needs an open file")
      else:
        rt.note("reloading " & buf.path & "…")
        rt.runFileJob(fileJobFor(fjRead, buf.doc, buf.path, buf.serial))
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

  # PLAT-50: "Add tracepoint" on an editor line chose WHERE the next
  # `:tracepoint` goes (the desktop's tracepoint editor opens on that line);
  # any other command forgets it.
  var context = rt.context
  if rt.app.tracepointAt.path.len > 0:
    let verb = line.strip().strip(chars = {':'}).splitWhitespace()
    if verb.len > 0 and verb[0] == "tracepoint":
      context.file = rt.app.tracepointAt.path
      context.line = rt.app.tracepointAt.line
    rt.app.tracepointAt = ("", 0)
  let result = runCommand(rt.dispatcher, context, line)
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
    # PLAT-50: an origin query is not a move (`awaitsOrigin`).
    if outcome.action == kaValueOrigin and
       result.message.startsWith(OriginPendingText):
      outcome.awaitsMove = false
      outcome.awaitsOrigin = true
      outcome.originRetry = line

const CallTraceWheelRows* = 3
  ## Rows one wheel notch scrolls the call trace — the common terminal
  ## default (xterm, VTE and tmux all scroll three lines a notch).

proc scrollCallTrace(rt: TuiRuntime; delta: int; outcome: var RuntimeOutcome) =
  ## PLAT-47: scroll the call trace by `delta` rows (down is positive), from
  ## where it is drawn now, and stop following the current call. The host
  ## loads the section the pane then shows (`RuntimeOutcome.pagesCallTrace`),
  ## as the desktop's calltrace pane loads a section when it is scrolled.
  let body = max(1, rt.paneBodyRows(paneCalltrace))
  let m = rt.app.callTrace
  let top = m.clampTop(m.visibleTop(body) + delta, body)
  rt.app.callTrace.scrollTop = top
  rt.app.callTrace.follow = false
  rt.app.callTraceScrolled = true
  outcome.pagesCallTrace = true
  outcome.repaint = true
  rt.note("call trace " & $(top + 1) & "-" & $min(m.total, top + body) &
          " of " & $m.total)

const GestureInteractions = {ikDraggingTab, ikResizingSplit}
  ## A drag or a resize: gestures whose progress the status line narrates.
const MouseNoteStatuses* = {lasRefused, lasBadArgument, lasUnknownCommand}
  ## PLAT-49 part B: the outcomes of a MOUSE gesture the status line reports —
  ## the ones whose result is not on the screen. A click, a drag, a drop, a
  ## resize or a reveal that worked is visible and says nothing.

# ---------------------------------------------------------------------------
# PLAT-50: CLICKS IN PANES — the desktop's click behaviours
# (`headless_app/pane_clicks.ClickInventory`)
# ---------------------------------------------------------------------------

proc applyLocalAction(rt: TuiRuntime; action: KeyAction;
                      outcome: var RuntimeOutcome): bool
  ## Forward-declared for the tab menu's "Maximise container".

proc shellScreenOf*(rt: TuiRuntime): ShellScreen
  ## FORWARD-DECLARED for the top bar's and the panes' hit-testing, which
  ## read the cells the next frame is painted with; defined with the other
  ## screen readers.

proc paneUnderStrip(geometry: LayoutGeometry; idx: int): CellArea =
  ## The rectangle a pane's painter is handed (`shell.paintPane`'s `under`):
  ## from its strip's row, its box's width and height. Its first row is the
  ## painter's heading, which the strip covers; its content starts below.
  let region = geometry.projection.regions[idx]
  let frame = paneFrame(region.area, geometry.body)
  CellArea(col: region.area.col, row: region.area.row,
           width: frame.box.width, height: frame.box.height)

proc openContextMenu(rt: TuiRuntime; menu: ContextMenuModel; row, col: int;
                     outcome: var RuntimeOutcome) =
  ## A right-click's menu, at the cell pressed.
  rt.app.contextMenu.openAt(menu, row, col)
  rt.app.menu.close()
  outcome.repaint = true

proc requestClick(outcome: var RuntimeOutcome; request: PaneClickRequest) =
  outcome.paneClick = request
  outcome.repaint = true

# ---------------------------------------------------------------------------
# PLAT-52: the Terminal Output pane — K32 and its scrubbers
# ---------------------------------------------------------------------------

const TerminalWheelRows* = 3

proc terminalOutputArea(rt: TuiRuntime; geometry: LayoutGeometry): CellArea =
  ## The rectangle the Terminal Output pane is painted into (its strip row
  ## first), or an empty one when it is not on the screen.
  for i, region in geometry.projection.regions:
    if region.pane == paneTerminalOutput:
      return paneUnderStrip(geometry, i)
  CellArea()

proc terminalWriteJump(rt: TuiRuntime; write: int;
                       outcome: var RuntimeOutcome): bool =
  ## Go to the moment write `write` was produced: the host's `ct/event-jump`
  ## (`pcEventJump`), the desktop's fragment click (K32).
  let m = rt.app.terminalOutput
  if m.screen.isNil or write < 0 or write >= m.screen.writes.len:
    return false
  let ev = m.screen.writes[write]
  outcome.requestClick(PaneClickRequest(
    kind: pcEventJump, index: ev.logIndex, tick: ev.rrTicks, path: ev.path,
    line: ev.line))
  true

proc scrollTerminalOutput(rt: TuiRuntime; delta: int;
                          outcome: var RuntimeOutcome) =
  ## Scroll the line view by `delta` rows (wheel, keys), leaving follow.
  let area = rt.terminalOutputArea(rt.layoutGeometry())
  let geo = terminalPaneGeometry(rt.app.terminalOutput, area)
  let rows = max(1, geo.contentRows)
  let m = rt.app.terminalOutput
  let top = max(0, min(max(0, m.lines.len - rows), m.visibleTop(rows) + delta))
  rt.app.terminalOutput.scrollTop = top
  rt.app.terminalOutput.follow = false
  outcome.repaint = true

proc scrubTerminalLines(rt: TuiRuntime; area: CellArea; row: int;
                        click: bool) =
  ## The line view's scrubber (Scrollbar-Scrubbers.md §3): a click on the
  ## track centres the line at the clicked fraction of the WHOLE output; a
  ## dragged thumb follows the pointer. It moves the view, never the
  ## debugger.
  let m = rt.app.terminalOutput
  let geo = terminalPaneGeometry(m, area)
  if geo.contentRows <= 0:
    return
  let sm = m.scrubberOf(geo.contentRows)
  let f = fractionAt(row - geo.contentTop, geo.contentRows)
  let top =
    if click: sm.clickAt(f)
    else: sm.dragTo(f - sm.thumbLength / 2.0)
  rt.app.terminalOutput.scrollTop = top
  rt.app.terminalOutput.follow = false

proc scrubTerminalScreen(rt: TuiRuntime; area: CellArea; col: int;
                         outcome: var RuntimeOutcome) =
  ## The screen's built-in scrubber held at column `col`. REAL-TIME (the
  ## user, 2026-10-06; Terminal-Output-Pane.md §3): the debugger moves to the
  ## write under the pointer as it is dragged — one jump per write crossed —
  ## and the screen shows that write while the move is made.
  let m = rt.app.terminalOutput
  if m.screen.isNil:
    return
  let geo = terminalPaneGeometry(m, area)
  let f = fractionAt(col - geo.screenTrackCol, geo.screenTrackWidth)
  let w = writeAtFraction(m.screen.writeCount, f)
  if w < 0:
    return
  rt.app.terminalOutput.shownWrite = w
  rt.app.terminalOutput.previewing = true
  if w != m.scrubSent:
    rt.app.terminalOutput.scrubSent = w
    discard rt.terminalWriteJump(w, outcome)
  outcome.repaint = true

proc endTerminalScrub(rt: TuiRuntime) =
  rt.app.terminalOutput.previewing = false
  rt.app.terminalOutput.scrubSent = -1

proc routeTerminalOutputClick(rt: TuiRuntime; area: CellArea;
                              event: MouseEvent;
                              outcome: var RuntimeOutcome): bool =
  ## A press in the Terminal Output pane: the toggle, a fragment (K32), the
  ## line view's scrubber, the screen's scrubber. The desktop has no menu on
  ## the pane, so a right press is not taken.
  if event.button != mbLeft or not rt.app.terminalOutput.loaded:
    return false
  let hit = rt.app.terminalOutput.terminalOutputHitAt(area, event.row,
                                                      event.col)
  case hit.kind
  of thNone, thScreen:
    return false
  of thViewLines:
    outcome.requestClick(PaneClickRequest(kind: pcTerminalView,
                                          text: $tvLines))
  of thViewScreen:
    outcome.requestClick(PaneClickRequest(kind: pcTerminalView,
                                          text: $tvScreen))
  of thFragment:
    return rt.terminalWriteJump(hit.eventIndex, outcome)
  of thLineTrack:
    rt.scrubTerminalLines(area, event.row, click = true)
    outcome.repaint = true
  of thLineThumb:
    rt.app.terminalDrag = tdLineThumb
    rt.scrubTerminalLines(area, event.row, click = false)
    outcome.repaint = true
  of thScreenTrack:
    rt.app.terminalDrag = tdScreen
    rt.app.terminalOutput.scrubSent = -1
    rt.scrubTerminalScreen(area, event.col, outcome)
  true

proc routeTerminalDrag(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## A press held on one of the pane's scrubbers owns the pointer until it is
  ## released: the line view's thumb follows it (the view, never the
  ## debugger); the screen's scrubber moves the debugger LIVE to the write
  ## under it (§3, real-time), and the release ends the drag there.
  if rt.app.terminalDrag == tdNone:
    return false
  let kind = rt.app.terminalDrag
  if event.kind == mekPress:
    rt.app.terminalDrag = tdNone
    if kind == tdScreen:
      rt.endTerminalScrub()
    return false
  let area = rt.terminalOutputArea(rt.layoutGeometry())
  if event.kind == mekMotion:
    case kind
    of tdLineThumb:
      rt.scrubTerminalLines(area, event.row, click = false)
      outcome.repaint = true
    of tdScreen: rt.scrubTerminalScreen(area, event.col, outcome)
    of tdNone: discard
    return true
  # The release: the screen's drag ends on the write under the pointer.
  rt.app.terminalDrag = tdNone
  if kind == tdScreen:
    rt.scrubTerminalScreen(area, event.col, outcome)
    rt.endTerminalScrub()
  outcome.repaint = true
  true

proc terminalOutputOwnsToken*(rt: TuiRuntime; token: string): bool =
  ## The pane's own keys while it is focused: Left / Right step a write back /
  ## forward (the screen's "step-by-write keys ... scoped to the pane", which
  ## the line view keeps too), `v` toggles lines / screen.
  let (had, focused) = rt.focus.focusedPane()
  if not had or focused != paneTerminalOutput or
     not rt.app.terminalOutput.loaded:
    return false
  keyName(token) in ["Left", "Right", "v"]

proc routeTokenToTerminalOutput(rt: TuiRuntime; token: string;
                                outcome: var RuntimeOutcome) =
  let m = rt.app.terminalOutput
  case keyName(token)
  of "v":
    outcome.requestClick(PaneClickRequest(
      kind: pcTerminalView,
      text: (if m.view == tvScreen: $tvLines else: $tvScreen)))
  of "Left", "Right":
    let n = if m.screen.isNil: 0 else: m.screen.writeCount
    let delta = if keyName(token) == "Left": -1 else: 1
    let at = m.shownWrite
    let target = if at < 0 and delta > 0: 0 else: at + delta
    if n == 0 or target < 0 or target >= n:
      rt.note(if delta < 0: "no earlier write" else: "no later write")
      outcome.repaint = true
      return
    discard rt.terminalWriteJump(target, outcome)
  else: discard

proc showContent(rt: TuiRuntime; title, text: string; diff = false;
                 outcome: var RuntimeOutcome) =
  ## A text over the body (`views/context_menu.ContentOverlay`).
  rt.app.content = ContentOverlay(open: true, title: title, text: text,
                                  diff: diff)
  outcome.repaint = true

proc copyToClipboard(rt: TuiRuntime; text, what: string) =
  ## PLAT-50: hand `text` to the terminal's clipboard (OSC 52, written by the
  ## next frame) and say what was copied, as the desktop's copy does.
  rt.app.clipboard = text
  rt.note("copied " & what)

proc eventRowAt(model: EventLogModel; area: CellArea;
                row: int): (bool, event_log.EventLogRow, EventLogScreen) =
  ## The row painted on `row` when the log is painted into `area` (the
  ## pane's painter, re-run on a scratch grid so the hit is the paint's), and
  ## that screen (its header, for a header press).
  var g = newStyledGrid(area.col + area.width, area.row + area.height)
  let screen = paintEventLog(g, area, model)
  let firstBody = area.row + (if screen.headerRow >= 0: 2 else: 1)
  let i = row - firstBody
  if i < 0 or i >= screen.visible.len or screen.visible[i].kind != elrEvent:
    return (false, event_log.EventLogRow(), screen)
  (true, screen.visible[i], screen)

proc timelineTickAt(rt: TuiRuntime; content: CellArea; col: int): int64 =
  ## The tick the timeline's track maps column `col` to, for the bar painted
  ## into `content` (the painter re-run on a scratch grid, so the mapping is
  ## the drawing's), or -1 off the track.
  var g = newStyledGrid(content.col + content.width,
                        content.row + content.height)
  let bar = paintTimelineBar(g, content, rt.app.timeline)
  if bar.barRow < 0 or bar.trackWidth <= 0 or col < bar.trackCol or
     col >= bar.trackCol + bar.trackWidth:
    return -1
  int64(tickForColumn(col - bar.trackCol, rt.app.timeline.minTick,
                      rt.app.timeline.maxTick, bar.trackWidth))

proc routeEventLogClick(rt: TuiRuntime; area: CellArea; event: MouseEvent;
                        outcome: var RuntimeOutcome): bool =
  ## K24 / K25 / K26: a left click on an event goes to it (`eventJump`, the
  ## desktop's row click); a right click shows its whole content (the desktop
  ## opens it in a read-only editor view); a left click on a column's header
  ## orders the log by it, again to reverse (the desktop's DataTables order).
  let (ok, row, screen) = eventRowAt(rt.app.eventLog, area, event.row)
  if not ok:
    let (onHeader, column) = screen.headerColumnAt(event.row, event.col)
    if onHeader and event.button == mbLeft:
      outcome.requestClick(PaneClickRequest(
        kind: pcEventOrder,
        order: rt.app.eventLog.order.clickedHeader(column)))
      return true
    return false
  let ev = row.event
  rt.app.eventLog.selected = row.index
  if event.button == mbRight:
    rt.showContent("event #" & $ev.index & " at tick " & $ev.tick &
                     (if ev.file.len > 0: "  " & ev.file & ":" & $ev.line
                      else: ""),
                   ev.content, outcome = outcome)
    return true
  outcome.requestClick(PaneClickRequest(kind: pcEventJump, index: ev.index,
                                        tick: ev.tick, path: ev.file,
                                        line: ev.line, text: ev.content))
  true

proc editorTextMenu(rt: TuiRuntime; target: SourceClickTarget):
    ContextMenuModel =
  ## The editor menu on `target`'s line, with the line's breakpoint state and
  ## the word under the pointer (`callTokenAt`).
  let src = rt.app.source
  let mark = src.markFor(target.line)
  var inFile, any = false
  for p in rt.app.points.rows:
    if p.kind == PointKindBreakpoint:
      any = true
      if p.path == src.path: inFile = true
  let onLine: LineBreakpoint =
    case mark
    of gmBreakpoint: lbEnabled
    of gmBreakpointDisabled: lbDisabled
    else: lbNone
  let (token, tokenError) = callTokenAt(target.lineText, target.column,
                                        rust = src.path.endsWith(".rs"))
  editorTextContextMenu(src.path, target.line, lineText = target.lineText,
                        column = target.column, token = token,
                        tokenError = tokenError, breakpoint = onLine,
                        fileHasBreakpoints = inFile, anyBreakpoints = any)

proc lineValues(target: SourceClickTarget): seq[NamedValue] =
  for v in target.values:
    result.add (v.name, v.value)

proc routeEditorClick(rt: TuiRuntime; under: CellArea; event: MouseEvent;
                      outcome: var RuntimeOutcome): bool =
  ## K10-K15 and K36 on the recording's source in Debug: the gutter's toggle
  ## and enable / disable, the text's line and call jumps, a column
  ## breakpoint, the editor menu, and an inline value's click, Ctrl+click and
  ## menu — `ui/editor`'s and `ui/flow`'s mouse handlers.
  if rt.app.modes.product == pmEdit or rt.app.source.isEmpty:
    return false
  let src = rt.app.source
  let target = src.sourceClickTargetAt(under, event.row, event.col)
  if target.line < 1:
    return false
  let line = target.line
  if target.onGutter:
    if event.button == mbLeft:
      outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,
                                            path: src.path, line: line))
      return true
    if event.button == mbRight:
      # The desktop's gutter right-click enables / disables a breakpoint
      # that is there, and does nothing on a line without one.
      let mark = src.markFor(line)
      if mark in {gmBreakpoint, gmBreakpointDisabled}:
        outcome.requestClick(PaneClickRequest(
          kind: pcSetBreakpointEnabled, path: src.path, line: line,
          enabled: mark == gmBreakpointDisabled))
        return true
    return false
  # K36: AN INLINE VALUE — `ui/flow`'s value: a click goes to the step the
  # line ran at, Ctrl+click pins it, a right click opens its menu.
  if target.value >= 0:
    let v = target.values[target.value]
    case event.button
    of mbRight:
      rt.openContextMenu(flowValueContextMenu(src.path, line, v.name, v.value,
                                              lineValues(target)),
                         event.row, event.col, outcome)
    of mbLeft:
      if event.ctrl:
        outcome.requestClick(PaneClickRequest(kind: pcScratchpadAdd,
                                              values: @[(v.name, v.value)]))
      else:
        # The value IS the current step's (the terminal annotates only the
        # line the debugger is on), so the step it was observed at is here.
        rt.note(v.name & " = " & v.value & " is the value at this step")
        outcome.repaint = true
    else:
      return false
    return true
  case event.button
  of mbRight:
    rt.openContextMenu(rt.editorTextMenu(target), event.row, event.col,
                       outcome)
    true
  of mbMiddle:
    outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,
                                          line: line, behaviour: "smart"))
    true
  of mbLeft:
    if event.ctrl and event.alt:
      # K15: the desktop's Ctrl+Alt+click on a function's name.
      let (token, err) = callTokenAt(target.lineText, target.column,
                                     rust = src.path.endsWith(".rs"))
      if token.len == 0:
        rt.note(if err.len > 0: err & " on line " & $line & "."
                else: NoWordSelected)
        outcome.repaint = true
      else:
        outcome.requestClick(PaneClickRequest(kind: pcCallJump,
                                              path: src.path, line: line,
                                              text: token,
                                              behaviour: "smart"))
      true
    elif event.alt:
      # K14: the desktop's Alt+click — a breakpoint anchored at the column
      # (`column_click_resolver`: the text's column, clamped to the line).
      let width = max(1, cellWidthOf(target.lineText))
      outcome.requestClick(PaneClickRequest(
        kind: pcColumnBreakpoint, path: src.path, line: line,
        column: max(1, min(target.column, width))))
      true
    elif event.ctrl:
      outcome.requestClick(PaneClickRequest(kind: pcLineJump, path: src.path,
                                            line: line, behaviour: "smart"))
      true
    else:
      false
  else:
    false

proc routeDockLabelClick(rt: TuiRuntime; geometry: LayoutGeometry;
                         event: MouseEvent;
                         outcome: var RuntimeOutcome): bool =
  ## K42: a right-click on a docked pane's label opens the desktop's strip
  ## menu (`ui/auto_hide`'s `onContextMenu`).
  if event.kind != mekPress or event.button != mbRight:
    return false
  let s = geometry.stripIndexAt(event.row, event.col)
  if s < 0:
    return false
  let strip = geometry.strips[s]
  let i = strip.slotAt(event.row, event.col)
  if i < 0:
    return false
  rt.openContextMenu(dockLabelContextMenu(strip.slots[i].pane, strip.edge),
                     event.row, event.col, outcome)
  true

proc routePaneClick(rt: TuiRuntime; geometry: LayoutGeometry;
                    event: MouseEvent; outcome: var RuntimeOutcome): bool =
  ## A press the layout did not act on (`lasNoGesture`), on a pane's strip or
  ## body, or a dock label: what the desktop does there. Answers whether it
  ## was taken.
  if event.kind != mekPress or
     event.button notin {mbLeft, mbRight, mbMiddle}:
    return false
  if rt.routeDockLabelClick(geometry, event, outcome):
    return true
  # K37: the status line (the desktop's status bar location and its copy
  # button) — a click on it copies the current file's path, as the
  # desktop's copy control does (measured: the path, without the line). The
  # bottom dock labels in that row are the layout's, handled before this.
  if event.row == rt.height - 1 and event.button == mbLeft:
    let colon = rt.app.location.rfind(':')
    if colon <= 0:
      return false
    let path = rt.app.location[0 ..< colon]
    rt.copyToClipboard(path, "the path " & path)
    outcome.repaint = true
    return true
  let idx = geometry.regionIndexAt(event.row, event.col)
  if idx < 0:
    return false
  let region = geometry.projection.regions[idx]
  let under = paneUnderStrip(geometry, idx)
  # K7: a right-click on a TAB opens the tab's menu.
  if event.row == region.area.row:
    if event.button != mbRight:
      return false
    let pane = rt.app.layoutBinding.stripPaneAt(geometry, event.row,
                                                event.col)
    if pane.isNone:
      return false
    rt.openContextMenu(tabContextMenu(pane.get, rt.maximize.active),
                       event.row, event.col, outcome)
    return true
  if not under.contains(event.row, event.col):
    return false   # the divider
  case region.pane
  of paneFileTree:
    # K17 / K18 (K19: the desktop has no Files menu).
    if event.button != mbLeft:
      return false
    let tree = rt.app.fileTree
    if tree.entries.len == 0:
      return false
    let i = tree.scrollTop + (event.row - under.row - 1)
    if i < 0 or i >= tree.entries.len:
      return false
    let e = tree.entries[i]
    outcome.requestClick(PaneClickRequest(
      kind: (if e.isFolder: pcToggleFolder else: pcOpenFile), path: e.path))
    return true
  of paneEditor:
    return rt.routeEditorClick(under, event, outcome)
  of paneCalltrace:
    # K22 / K23 (K20 / K21 are the left press in `routeMouseReport`).
    if event.button != mbRight or rt.app.callTrace.isEmpty:
      return false
    let hit = rt.app.callTrace.callTraceHitAt(under, event.row, event.col)
    if hit.kind == cthNone:
      return false
    let local = int(hit.index - rt.app.callTrace.firstIndex)
    if local < 0 or local >= rt.app.callTrace.rows.len:
      return false
    let call = rt.app.callTrace.rows[local].callOf
    if hit.arg >= 0 and hit.arg < call.args.len:
      let a = call.args[hit.arg]
      rt.openContextMenu(callArgumentContextMenu(hit.index, a.name, a.value),
                         event.row, event.col, outcome)
      return true
    rt.openContextMenu(callTraceContextMenu(hit.index, call.toggle != crtLeaf,
                                            call.toggle == crtExpanded),
                       event.row, event.col, outcome)
    return true
  of paneEventLog:
    if event.button notin {mbLeft, mbRight}:
      return false
    return rt.routeEventLogClick(under, event, outcome)
  of paneTimeline:
    # K30 / K45 on the scrubber's track; the event log under it as K24-K26.
    let content = CellArea(col: under.col, row: under.row + 1,
                           width: under.width,
                           height: max(0, under.height - 1))
    if content.height < 2 or not rt.app.timeline.boundsKnown:
      return false
    if event.row < content.row + TimelineBarRows:
      if event.button != mbLeft:
        return false
      let tick = rt.timelineTickAt(content, event.col)
      if tick < 0:
        return false
      # A press seeks; a drag from it seeks again where it is released (the
      # desktop's `mousedown` / `mouseup` on the track).
      rt.app.timelineDrag = true
      outcome.requestClick(PaneClickRequest(kind: pcSeek, tick: uint64(tick)))
      return true
    if event.button notin {mbLeft, mbRight}:
      return false
    let log = CellArea(col: content.col, row: content.row + TimelineBarRows - 1,
                       width: content.width,
                       height: content.height - TimelineBarRows + 1)
    return rt.routeEventLogClick(log, event, outcome)
  of paneState:
    # K27 / K28.
    if rt.app.variables.isEmpty:
      return false
    var g = newStyledGrid(under.col + under.width, under.row + under.height)
    let screen = paintVariables(g, under, rt.app.variables)
    let path = screen.pathAtScreenRow(event.row)
    if path.len == 0:
      return false
    rt.app.variables.selected = path
    rt.app.variables.focused = path
    # `o` acts on the selected variable (`CommandContext.selectedVariable`).
    rt.context.selectedVariable = variablePathOf(path)
    if event.button == mbRight:
      rt.openContextMenu(variablesContextMenu(path), event.row, event.col,
                         outcome)
      return true
    if event.button == mbLeft:
      discard rt.app.variables.toggleNode(path)
      outcome.repaint = true
      return true
    return false
  of panePointList:
    # K31: the desktop's click selects the point.
    if event.button != mbLeft or not rt.app.points.loaded:
      return false
    let i = event.row - under.row - 1
    if i < 0 or i >= rt.app.points.rows.len:
      return false
    rt.app.points.selected = i
    outcome.repaint = true
    return true
  of paneScratchpad:
    # K33: the close button removes the value.
    if event.button != mbLeft or not rt.app.scratchpad.loaded:
      return false
    let hit = rt.app.scratchpad.scratchpadHitAt(under, event.row, event.col)
    if hit.row < 0 or not hit.close:
      return false
    outcome.requestClick(PaneClickRequest(kind: pcScratchpadRemove,
                                          index: hit.row))
    return true
  of paneVcs:
    # K34 / K53: a changed file opens its diff; a commit opens (lists the
    # files it changed) or closes; a commit's file opens that change.
    if event.button != mbLeft or not rt.app.vcs.loaded:
      return false
    var g = newStyledGrid(under.col + under.width, under.row + under.height)
    let content = CellArea(col: under.col, row: under.row + 1,
                           width: under.width,
                           height: max(0, under.height - 1))
    let screen = paintVcsPane(g, content, rt.app.vcs)
    let t = screen.vcsTargetAt(event.row)
    case t.kind
    of vrNone:
      return false
    of vrFile, vrCommitFile:
      outcome.requestClick(PaneClickRequest(kind: pcVcsDiff, path: t.path,
                                            text: t.status,
                                            behaviour: t.hash))
    of vrCommit:
      outcome.requestClick(PaneClickRequest(kind: pcVcsCommit,
                                            index: t.index))
    return true
  of paneTerminalOutput:
    # PLAT-52 (K32): a fragment goes to the write that produced it; the
    # toggle and the two scrubbers.
    return rt.routeTerminalOutputClick(under, event, outcome)
  else:
    return false

proc runContextAction(rt: TuiRuntime; action: ContextAction;
                      target: ContextTarget; outcome: var RuntimeOutcome) =
  ## A context-menu entry was chosen: route its action to the operation the
  ## desktop's entry runs.
  outcome.repaint = true
  let binding = rt.app.layoutBinding
  proc layout(rt: TuiRuntime; cmd: LayoutCommand) =
    if binding.isNil:
      return
    let acted = binding.dispatch(cmd)
    if acted.status == lasApplied:
      rt.afterLayoutCommit()
      rt.rebuildFocus()
    elif acted.status in MouseNoteStatuses:
      rt.note(acted.message)
  case action
  of caNone: discard
  of caPinLeft: rt.layout(cmdDock(target.pane, leLeft))
  of caPinBottom: rt.layout(cmdDock(target.pane, leBottom))
  of caPinRight: rt.layout(cmdDock(target.pane, leRight))
  of caUnpin: rt.layout(cmdRestoreDocked(target.pane))
  of caClosePane: rt.layout(cmdRemovePane(target.pane))
  of caMaximise:
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(target.pane)
    discard rt.applyLocalAction(kaMaximizePane, outcome)
  of caCopy:
    # Monaco's Copy with nothing selected copies the caret's line, and the
    # right-click put the caret on it.
    rt.copyToClipboard(target.text & "\n", "line " & $target.line)
  of caFind:
    # The desktop's Find (Monaco's find widget): this front-end's search.
    discard rt.applyLocalAction(kaSearchForward, outcome)
  of caAddBreakpoint, caDeleteBreakpoint:
    outcome.requestClick(PaneClickRequest(kind: pcToggleBreakpoint,
                                          path: target.path,
                                          line: target.line))
  of caEnableBreakpoint, caDisableBreakpoint:
    outcome.requestClick(PaneClickRequest(
      kind: pcSetBreakpointEnabled, path: target.path, line: target.line,
      enabled: action == caEnableBreakpoint))
  of caDeleteBreakpointsInFile:
    outcome.requestClick(PaneClickRequest(kind: pcDeleteBreakpoints,
                                          path: target.path))
  of caDeleteAllBreakpoints:
    outcome.requestClick(PaneClickRequest(kind: pcDeleteBreakpoints))
  of caJumpToLine, caRunToCursor, caJumpBackwardToLine:
    outcome.requestClick(PaneClickRequest(
      kind: pcLineJump, path: target.path, line: target.line,
      behaviour: (case action
                  of caRunToCursor: "forward"
                  of caJumpBackwardToLine: "backward"
                  else: "smart")))
  of caJumpToCall, caJumpForwardToCall, caJumpBackwardToCall:
    if target.token.len == 0:
      rt.note(if target.tokenError.len > 0:
                target.tokenError & " on line " & $target.line & "."
              else: NoWordSelected)
    else:
      outcome.requestClick(PaneClickRequest(
        kind: pcCallJump, path: target.path, line: target.line,
        text: target.token,
        behaviour: (case action
                    of caJumpForwardToCall: "forward"
                    of caJumpBackwardToCall: "backward"
                    else: "smart")))
  of caAddTracepoint:
    # The desktop opens its tracepoint editor on the line; this front-end
    # sets tracepoints with `:tracepoint <expr>`, so the prompt opens with it
    # typed, placed on the chosen line instead of the stop's.
    rt.app.tracepointAt = (target.path, target.line)
    discard rt.openPrompt(pkCommand)
    discard rt.prompt.insert("tracepoint ")
    rt.note("a tracepoint at " & target.path.extractFilename & ":" &
            $target.line & " — type its expression and press Enter")
  of caToggleCallChildren:
    outcome.togglesCall = true
    outcome.callIndex = target.index
  of caToggleValueHistory:
    outcome.requestClick(PaneClickRequest(kind: pcValueHistory,
                                          path: target.path))
  of caShowValueOrigin:
    # The desktop's entry SHOWS the chain (its origin panel); `o` / `:origin`
    # walk it, which is a different act.
    outcome.requestClick(PaneClickRequest(kind: pcValueOrigin,
                                          path: target.path))
  of caAddValueToScratchpad, caAddAllValuesToScratchpad:
    outcome.requestClick(PaneClickRequest(
      kind: pcScratchpadAdd, values: target.scratchpadSamplesOf(action)))
  of caJumpToValue:
    rt.note(target.expression & " = " & target.text &
            " is the value at this step")

proc routeOverlayMouse(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## PLAT-50: an open context menu or content overlay owns the mouse: the
  ## pointer over an entry selects it, a press on an entry chooses it, a press
  ## anywhere else closes the menu (or the overlay) and does nothing else; the
  ## wheel scrolls the overlay's text.
  if rt.app.contextMenu.open:
    let screen = shellScreenOf(rt)
    let (inside, index) = rt.app.contextMenu.contextMenuHitAt(
      screen.contextMenuArea, event.row, event.col)
    case event.kind
    of mekMotion:
      if inside and index >= 0 and index != rt.app.contextMenu.selected:
        rt.app.contextMenu.hover(index)
        outcome.repaint = true
      return true
    of mekRelease:
      return true
    of mekPress:
      outcome.repaint = true
      if inside:
        if index >= 0 and event.button == mbLeft:
          let chosen = rt.app.contextMenu.choose(index)
          if chosen.chosen:
            rt.runContextAction(chosen.action, chosen.target, outcome)
          elif rt.app.contextMenu.open:
            rt.note(rt.app.contextMenu.menu.entries[index].label & ": " &
                    rt.app.contextMenu.menu.entries[index].reason)
        return true
      rt.app.contextMenu.close()
      return true
  if rt.app.content.open:
    if event.kind == mekPress:
      if event.button in {mbWheelUp, mbWheelDown}:
        rt.app.content.scroll(if event.button == mbWheelDown: 3 else: -3)
      else:
        rt.app.content = ContentOverlay()
      outcome.repaint = true
    return event.kind != mekMotion
  false

proc routeTimelineDrag(rt: TuiRuntime; event: MouseEvent;
                       outcome: var RuntimeOutcome): bool =
  ## K45: while a press on the timeline's track is held, the motion previews
  ## the tick under the pointer and the release seeks there (the desktop's
  ## drag on the track: `mousemove` previews, `mouseup` seeks).
  if not rt.app.timelineDrag:
    return false
  if event.kind == mekPress:
    rt.app.timelineDrag = false
    return false
  let geometry = rt.layoutGeometry()
  let idx = geometry.regionIndexAt(event.row, event.col)
  var tick = -1'i64
  if idx >= 0 and geometry.projection.regions[idx].pane == paneTimeline:
    let under = paneUnderStrip(geometry, idx)
    let content = CellArea(col: under.col, row: under.row + 1,
                           width: under.width,
                           height: max(0, under.height - 1))
    tick = rt.timelineTickAt(content, event.col)
  if event.kind == mekMotion:
    if tick >= 0:
      rt.note("tick " & $tick)
      outcome.repaint = true
    return true
  # The release.
  rt.app.timelineDrag = false
  if tick >= 0 and uint64(tick) != rt.app.timeline.currentTick:
    outcome.requestClick(PaneClickRequest(kind: pcSeek, tick: uint64(tick)))
  true

proc handleContextMenuKey(rt: TuiRuntime; token: string;
                          outcome: var RuntimeOutcome) =
  ## Up / Down move, Enter chooses, Esc closes — the program menu's keys.
  outcome.repaint = true
  case keyName(token)
  of "Up": rt.app.contextMenu.move(-1)
  of "Down": rt.app.contextMenu.move(1)
  of "Enter":
    let chosen = rt.app.contextMenu.choose(-1)
    if chosen.chosen:
      rt.runContextAction(chosen.action, chosen.target, outcome)
  of "Escape", "Esc": rt.app.contextMenu.close()
  else:
    if token == "\x1b":
      rt.app.contextMenu.close()

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
  ## (PLAT-47: the call trace now takes the wheel over its body, through the
  ## `lasNoGesture` seam described below.)
  ##
  ## **Nothing else in this front-end consumed a mouse report then**, and that
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
  let geometry = rt.layoutGeometry()
  let before = binding.interaction.kind
  let acted = binding.onMouse(geometry, event)
  # PLAT-49 part B: a click on a label docked its pane open (or closed it)
  # — the preview and its timers end; an overlay closed any other way (an
  # outside press) is no longer the hover machine's either.
  if acted.command.isSome and acted.command.get.kind == lcSetAutoHide and
     acted.command.get.autoHideDirection in {ahOpen, ahClose}:
    rt.autoHide.clicked()
  elif binding.interaction.kind != ikRevealingDock:
    rt.autoHide.overlayClosed()
  let inGesture = before in GestureInteractions or
                  binding.interaction.kind in GestureInteractions
  outcome.detail = acted.message
  # PLAT-49 (the user, 2026-10-01): A PLAIN CLICK SAYS NOTHING. What the
  # layout did — a drag's progress, a drop, a resize, a reveal — goes on the
  # status line; a report that did nothing to the layout (`lasNoGesture`: a
  # click that only focused a pane, a press that marked a tab, a release
  # with no drag) does not, so clicking around a pane never shows drag
  # messages like "release with no drag in flight".
  #
  # PLAT-49 part B (the user's finding 2, followed through): A CLICK THAT
  # WORKED SAYS NOTHING EITHER. A tab click used to print the layout command
  # it ran ("activateTab(vcs) applied"), a dock label's click "revealing …" —
  # an echo of a click whose result is on the screen. Only a refusal and why
  # is written for a click (`MouseNoteStatuses`). A DRAG or a RESIZE keeps
  # its running commentary (where the drop would land, what it did): that is
  # a gesture's feedback, not a click's echo.
  if acted.status in MouseNoteStatuses or
     (inGesture and acted.status != lasNoGesture):
    rt.note(acted.message)
  # PLAT-47: A WHEEL OVER THE CALL TRACE'S BODY SCROLLS IT — the hand-off
  # `lasNoGesture` exists for (the binding takes a wheel only over a tab
  # strip).
  # PLAT-49 part B: A CLICK ON THE CALL TRACE — on a row, go to that call;
  # on its toggle, expand or collapse it — as the desktop's row does
  # (`isonim_calltrace_view.rowHandlers`).
  if acted.status == lasNoGesture and event.kind == mekPress and
     event.button == mbLeft and not rt.app.callTrace.isEmpty:
    let idx = geometry.regionIndexAt(event.row, event.col)
    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace:
      let region = geometry.projection.regions[idx]
      let frame = paneFrame(region.area, geometry.body)
      let area = CellArea(col: region.area.col, row: region.area.row,
                          width: frame.box.width, height: frame.box.height)
      let hit = rt.app.callTrace.callTraceHitAt(area, event.row, event.col)
      case hit.kind
      of cthRow:
        outcome.jumpsToCall = true
        outcome.callIndex = hit.index
        outcome.repaint = true
        rt.rebuildFocus()
        discard rt.focus.focusPaneKind(paneCalltrace)
        return
      of cthToggle:
        outcome.togglesCall = true
        outcome.callIndex = hit.index
        outcome.repaint = true
        return
      of cthNone:
        discard
  if acted.status == lasNoGesture and event.kind == mekPress and
     event.button in {mbWheelUp, mbWheelDown}:
    let idx = geometry.regionIndexAt(event.row, event.col)
    if idx >= 0 and geometry.projection.regions[idx].pane == paneCalltrace and
       not rt.app.callTrace.isEmpty:
      rt.scrollCallTrace(
        (if event.button == mbWheelDown: CallTraceWheelRows
         else: -CallTraceWheelRows), outcome)
      return
    # PLAT-52: the wheel scrolls the Terminal Output's line view.
    if idx >= 0 and
       geometry.projection.regions[idx].pane == paneTerminalOutput and
       rt.app.terminalOutput.loaded and not rt.app.terminalOutput.screenShown:
      rt.scrollTerminalOutput(
        (if event.button == mbWheelDown: TerminalWheelRows
         else: -TerminalWheelRows), outcome)
      return
  # PLAT-50: every other press the layout did not act on is the pane's —
  # the desktop's click behaviour there (`routePaneClick`).
  if acted.status == lasNoGesture and not inGesture and
     rt.routePaneClick(geometry, event, outcome):
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(binding.focus)
    return
  if acted.status == lasApplied:
    rt.afterLayoutCommit()
  # A gesture can take a pane off the screen (a drop on a dock strip) or put one
  # back, so the ring is re-derived from the arrangement the NEXT frame will
  # paint — the same reason `runPromptLine` rebuilds it after a layout command —
  # and only then is the gesture's own pane carried into it.
  rt.rebuildFocus()
  discard rt.focus.focusPaneKind(binding.focus)
  # EVERY REPORT THE BINDING WAS OFFERED REPAINTS: a click moves focus (and
  # the focus outline with it), a gesture moves a tint or a ghost.
  # `main.nim`'s write coalescing is what keeps a dragged pointer from
  # costing a frame per report.
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
  result = rt.app.editSession.applyEditKeyIn(buf, keyName(token), nowMs)
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
  of kaToggleBreakpoint:
    # EDIT MODE ANSWERS IT HERE; DEBUG MODE SENDS IT TO THE ENGINE. An edit
    # session has no engine — `ct edit` starts none — so `dispatchAction`'s
    # breakpoint service is absent and the key answered "unavailable" on the
    # one mode §3 of CodeTracer-TUI-Edit-Mode.md says it must work in. The
    # point goes on the edit session, at the caret of the file being edited,
    # and moves with that file's text (`edit_binding.applyEditKeyIn`).
    if rt.app.modes.product != pmEdit:
      return false
    let buf = if rt.app.editSession.isNil: nil
              else: rt.app.editSession.activeBuffer()
    if buf.isNil:
      rt.note("no file is open to place a breakpoint in")
    else:
      let line = buf.caretLine
      let placed = rt.app.editSession.togglePointAt(buf.path, line)
      rt.note((if placed: "breakpoint at " else: "removed the breakpoint at ") &
              buf.path & ":" & $line)
    outcome.detail = rt.app.notification
    outcome.repaint = true
    true
  of kaScrollLineDown, kaScrollLineUp, kaHalfPageDown, kaHalfPageUp,
     kaCenterOnPointer:
    # PLAT-47: THE CALL TRACE SCROLLS, and loads as it scrolls. These are
    # pane-local actions (`interpreter.paneLocal`); the call trace is the
    # pane that answers them here. Any other focused pane leaves them to the
    # dispatcher, exactly as before.
    let (had, focused) = rt.focus.focusedPane()
    # PLAT-52: the Terminal Output's line view scrolls the same way; `.`
    # follows the current position again.
    if had and focused == paneTerminalOutput and
       rt.app.terminalOutput.loaded and not rt.app.terminalOutput.screenShown:
      if action == kaCenterOnPointer:
        rt.app.terminalOutput.follow = true
        rt.note("terminal output follows the current position")
        outcome.repaint = true
        return true
      let area = rt.terminalOutputArea(rt.layoutGeometry())
      let rows = max(1, terminalPaneGeometry(rt.app.terminalOutput,
                                             area).contentRows)
      let (_, delta) = scrollDelta(action, rows)
      rt.scrollTerminalOutput(delta, outcome)
      return true
    if not had or focused != paneCalltrace or rt.app.callTrace.isEmpty:
      return false
    if action == kaCenterOnPointer:
      # `.`: follow the current call again.
      rt.app.callTraceScrolled = false
      rt.app.callTrace.follow = true
      outcome.pagesCallTrace = true
      outcome.repaint = true
      rt.note("call trace follows the current call")
      return true
    let (_, delta) = scrollDelta(action,
                                 max(1, rt.paneBodyRows(paneCalltrace)))
    rt.scrollCallTrace(delta, outcome)
    true
  of kaQuit:
    outcome.quit = true
    outcome.detail = QuitDetail
    true
  of kaNextSessionTab, kaPrevSessionTab:
    # CodeTracer-TUI.md §3.3.1: `g t` / `g T` (and `Ctrl+Tab` /
    # `Ctrl+Shift+Tab` where the terminal reports them) step the session
    # tabs, wrapping. With one session there is no other tab, and the status
    # line says so rather than the key doing nothing silently.
    let delta = if action == kaNextSessionTab: 1 else: -1
    if rt.app.shell.stepTab(delta):
      let tabs = rt.app.shell.tabsOf()
      let at = rt.app.shell.activeTabIndex()
      rt.note("session " & $(at + 1) & " of " & $tabs.len & ": " &
              tabs[at].title)
    else:
      rt.note("only one session is open; there is no other tab to switch to")
    outcome.detail = rt.app.notification
    outcome.repaint = true
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

# ---------------------------------------------------------------------------
# PLAT-48 — the top bar: the menu, the debugger controls, the omnibar, the
# session tabs, and the auto-hide strips' key
# ---------------------------------------------------------------------------

const
  MenuKey* = "F12"
    ## Opens the program menu. The desktop's `Ctrl+M` is `Enter` on a
    ## terminal's wire and `Alt+<letter>` reaches this front-end as the bare
    ## letter (`host/terminal_driver.feed`), so the menu takes the one free
    ## function key; it is also a click on `≡` or a folder title.
  RevealKey* = "Ctrl+o"
    ## Reveals the next auto-hidden pane (and, after the last, hides again):
    ## the auto-hide strips' keyboard route beside a click and `:reveal`.

proc transportKeyAction*(id: string): KeyAction =
  ## The terminal's action for a debugger control (`TransportControls` id).
  case id
  of "reverse-next": kaReverseStepOver
  of "next": kaStepOver
  of "reverse-step-in": kaReverseStepInto
  of "step-in": kaStepInto
  of "reverse-step-out": kaReverseStepOut
  of "step-out": kaStepOut
  of "reverse-continue": kaReverseContinue
  of "continue": kaContinue
  of "run-to-entry": kaJumpToStart
  else: kaNone

proc menuKeyAction*(action: string): KeyAction =
  ## The terminal's key action for a menu item's `ClientAction`, or `kaNone`.
  case action
  of "forwardContinue": kaContinue
  of "reverseContinue": kaReverseContinue
  of "forwardNext": kaStepOver
  of "reverseNext": kaReverseStepOver
  of "forwardStep": kaStepInto
  of "reverseStep": kaReverseStepInto
  of "forwardStepOut": kaStepOut
  of "reverseStepOut": kaReverseStepOut
  of "aBreakpoint": kaToggleBreakpoint
  of "aExit": kaQuit
  else: kaNone

proc menuPaneOf*(action: string): (bool, PaneKind) =
  ## The pane a View-menu item shows.
  case action
  of "aFilesystem": (true, paneFileTree)
  of "aFullCalltrace": (true, paneCalltrace)
  of "aState": (true, paneState)
  of "aEventLog": (true, paneEventLog)
  of "aTimeline": (true, paneTimeline)
  of "aTerminal": (true, paneTerminalOutput)
  of "aScratchpad": (true, paneScratchpad)
  of "aPointList": (true, panePointList)
  of "aAgentActivity": (true, paneAgentActivity)
  else: (false, paneEditor)

proc menuPromptLine*(action: string): string =
  ## The `:` line a menu item is, for the items that are one.
  case action
  of "aResetLayout": ":reset-layout"
  of "aTheme3": ":theme dark"
  of "aTheme1": ":theme light"
  else: ""

proc menuOmnibarQuery*(action: string): (bool, string) =
  case action
  of "findSymbol": (true, ":sym ")
  of "findInFiles": (true, ":grep ")
  else: (false, "")

proc menuActionAvailable*(action: string): bool =
  ## Whether the terminal performs a menu item. The rest are drawn DISABLED,
  ## not dropped, so every front-end shows the same menu.
  menuKeyAction(action) != kaNone or menuPaneOf(action)[0] or
    menuPromptLine(action).len > 0 or menuOmnibarQuery(action)[0]

proc chordOf*(rt: TuiRuntime; action: KeyAction): string =
  ## The ACTIVE keymap's first NORMAL-mode binding for `action`, as §4.2
  ## spells it — what the menu and a control's tooltip display.
  if action == kaNone:
    return ""
  for bnd in rt.keymap.bindingsOf(action):
    if bnd.mode == mmNormal:
      return bnd.spelling
  ""

proc refreshMenuForKeymap*(rt: TuiRuntime) =
  ## Enable the items the terminal performs and show the ACTIVE keymap's
  ## chords beside them. Run at start-up and after every keymap switch.
  var chords = initTable[string, string]()
  for (_, it) in rt.app.menu.root.actionItems():
    let chord = rt.chordOf(menuKeyAction(it.action))
    if chord.len > 0:
      chords[it.action] = chord
  let (hasPalette, _) = menuOmnibarQuery("findSymbol")
  if hasPalette:
    let chord = rt.chordOf(kaCommandPalette)
    if chord.len > 0:
      chords["findSymbol"] = chord
  rt.app.menu.setEnabled(menuActionAvailable)
  rt.app.menu.setShortcuts(chords)
  rt.app.refreshOmnibarIndex()

proc performAction(rt: TuiRuntime; action: KeyAction;
                   outcome: var RuntimeOutcome) =
  ## One resolved action, end to end: its product-mode scope, its modal
  ## transition, a local answer, or the dispatcher — the path a key takes
  ## once `keymap.resolve` named its action, shared by the menu, the
  ## debugger controls and the omnibar so a click and a key cannot differ.
  outcome.action = action
  if not appliesIn(action, rt.app.modes.product):
    outcome.detail = inertReason(action, rt.app.modes.product)
    rt.note(outcome.detail)
    outcome.repaint = true
    return
  let (known, ev) = modalEventFor(action)
  if known:
    let transition = rt.modal.applyModalEvent(ev)
    if not transition.accepted:
      rt.note(describeTransition(transition))
      outcome.repaint = true
      return
  if rt.applyLocalAction(action, outcome):
    return
  let dispatch = dispatchAction(rt.dispatcher, rt.context, action)
  outcome.detail = dispatch.detail
  rt.note(dispatch.detail)
  outcome.repaint = true
  if dispatch.status == drDone and movesTheDebugger(action):
    if action == kaValueOrigin and dispatch.detail.startsWith(OriginPendingText):
      outcome.awaitsOrigin = true
    else:
      outcome.awaitsMove = true
  if dispatch.status == drDone and changesSessionState(action):
    outcome.refreshesSession = true

proc omnibarHit(rt: TuiRuntime; screen: ShellScreen;
                event: MouseEvent): (bool, int) =
  var bar = rt.app.shellModel(rt.width, rt.height).topBar
  bar.header = rt.app.shellModel(rt.width, rt.height).header
  omnibarHitAt(bar, screen.topBarLayout, rt.width, rt.height, event.row,
               event.col)

proc openOmnibar*(rt: TuiRuntime; query = "") =
  if rt.app.menu.isOpen:
    rt.app.menu.close()
  rt.app.refreshOmnibarIndex()
  rt.app.omnibar.open(query)
  if query == OpenRecordingQuery:
    rt.note("new tab: choose a recording, or type its folder")
  else:
    rt.note("omnibar: type a file, :sym <function>, :<command> or #<tick>")

proc showPane(rt: TuiRuntime; pane: PaneKind; outcome: var RuntimeOutcome) =
  ## A View-menu item: bring `pane` forward — reveal it when it is docked,
  ## activate its tab and focus it when it is placed.
  if not rt.layoutBindingEnabled():
    rt.note($pane & ": the layout is not rearrangeable in this session")
    return
  let b = rt.app.layoutBinding
  if b.layout.dockedIndex(pane) >= 0:
    let acted = b.beginRevealDock(pane)
    rt.note(acted.message)
  elif b.layout.tree.contains(pane):
    let acted = b.dispatch(cmdActivateTab(pane))
    if acted.status == lasApplied:
      rt.afterLayoutCommit()
    rt.rebuildFocus()
    discard rt.focus.focusPaneKind(pane)
    b.focus = pane
    rt.note("focus " & $pane)
  else:
    # PLAT-50: A PANE THE ARRANGEMENT DOES NOT PLACE IS OPENED, as the
    # desktop's View menu opens its panel — a tab beside the event log
    # (the "Timeline & Tracepoints" stack), else at the root.
    let anchor = if b.layout.tree.contains(paneEventLog): some(paneEventLog)
                 else: none(PaneKind)
    let added = b.dispatch(cmdAddPane(pane, after = anchor))
    if added.status == lasApplied:
      rt.afterLayoutCommit()
      rt.rebuildFocus()
      discard rt.focus.focusPaneKind(pane)
      b.focus = pane
      rt.note("opened " & $pane)
    else:
      rt.note($pane & ": " & added.message)
  outcome.repaint = true

proc runMenuAction*(rt: TuiRuntime; action: string;
                    outcome: var RuntimeOutcome) =
  ## A chosen menu item (or omnibar command), in the terminal's terms.
  # PLAT-49 part B: the omnibar's event-log column commands
  # (`omnibar_sources.eventLogColumnCommands`), the `:column-*` verbs.
  let col = parseEventLogColumnCommand(action)
  if col.ok:
    let verb = case col.verb
               of "left": "column-left"
               of "right": "column-right"
               else: (if rt.app.eventLog.columns.isVisible(col.column):
                        "column-hide" else: "column-show")
    rt.note(rt.runColumnVerb(verb, eventLogColumnTitle(col.column)))
    outcome.repaint = true
    return
  let ka = menuKeyAction(action)
  if ka != kaNone:
    rt.performAction(ka, outcome)
    return
  let (isPane, pane) = menuPaneOf(action)
  if isPane:
    rt.showPane(pane, outcome)
    return
  let line = menuPromptLine(action)
  if line.len > 0:
    rt.runPromptLine(line, outcome)
    if outcome.action != kaNone:
      discard rt.applyLocalAction(outcome.action, outcome)
    outcome.repaint = true
    return
  let (isOmni, query) = menuOmnibarQuery(action)
  if isOmni:
    rt.openOmnibar(query)
    outcome.repaint = true
    return
  rt.note(action & " is not available in the terminal")
  outcome.repaint = true

proc acceptOmnibar(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `Enter` in the omnibar: act on the chosen entry. A tick and a symbol go
  ## to that point in time (`:goto`), a command runs its menu item, a file is
  ## selected in the Files pane (the debugger's source pane shows where the
  ## recording is; in Edit mode it is opened).
  let (ok, entry) = rt.app.omnibar.accept()
  outcome.repaint = true
  if not ok:
    rt.note("nothing matches")
    return
  case entry.kind
  of omTick, omSymbol:
    if entry.target.len == 0:
      rt.note(entry.label & " has no tick to go to")
      return
    rt.runPromptLine(":goto " & entry.target, outcome)
  of omCommand:
    rt.runMenuAction(entry.target, outcome)
  of omFile:
    if rt.app.modes.product == pmEdit:
      rt.runPromptLine(":e " & entry.target, outcome)
    else:
      rt.app.fileTree.openPath = entry.target
      rt.note("file " & entry.target)
  of omRecording:
    # PLAT-49 part B: open it in a new session tab — the host's to do.
    if rt.app.recordingOpener.isNil:
      rt.note("this terminal cannot open another recording")
    else:
      let why = rt.app.recordingOpener(entry.target)
      if why.len > 0:
        rt.note(why)
  else:
    rt.note(entry.label)

proc handleOmnibarKey(rt: TuiRuntime; token: string;
                      outcome: var RuntimeOutcome) =
  ## Every key while the omnibar is open belongs to it.
  let name = keyName(token)
  outcome.repaint = true
  case name
  of "Esc":
    rt.app.omnibar.close()
    rt.note("")
  of "Enter":
    rt.acceptOmnibar(outcome)
  of "Up": rt.app.omnibar.moveSelection(-1)
  of "Down": rt.app.omnibar.moveSelection(1)
  of "Backspace": rt.app.omnibar.backspace()
  # PLAT-49: the query is edited at a caret, in insert or overwrite mode.
  of "Delete": rt.app.omnibar.deleteForward()
  of "Left": rt.app.omnibar.moveCursor(-1)
  of "Right": rt.app.omnibar.moveCursor(1)
  of "Home": rt.app.omnibar.cursorHome()
  of "End": rt.app.omnibar.cursorEnd()
  of "Insert": rt.app.omnibar.toggleOverwrite()
  else:
    if isTextKey(name):
      rt.app.omnibar.typeText(keyCharacter(name))
    else:
      outcome.repaint = false

proc handleMenuKey(rt: TuiRuntime; token: string; nowMs: int64;
                   outcome: var RuntimeOutcome) =
  ## Every key while the menu is open belongs to it. The menu is the
  ## desktop's cascade (PLAT-49): `Up`/`Down` move within the open level,
  ## `Right` (or `Enter`) on a folder opens its submenu beside it, `Left`
  ## backs out of a submenu, `Esc` backs out and closes at the first level.
  let vm = rt.app.menu
  let name = keyName(token)
  outcome.repaint = true
  case name
  of "Esc": vm.escape()
  of MenuKey: vm.close()
  of "Enter":
    let act = vm.activate()
    if act.ran:
      rt.runMenuAction(act.action, outcome)
  of "Up": vm.moveHighlight(-1)
  of "Down": vm.moveHighlight(1)
  of "Right": discard vm.enterFolder()
  of "Left": discard vm.leaveFolder()
  else:
    if isTextKey(name):
      vm.typeToSelect(keyCharacter(name), nowMs)
    else:
      outcome.repaint = false
  if not vm.isOpen:
    rt.note(if outcome.detail.len > 0: outcome.detail else: rt.app.notification)

proc cycleReveal(rt: TuiRuntime; outcome: var RuntimeOutcome) =
  ## `Ctrl+o`: reveal the first docked pane, then the next; after the last,
  ## hide. The strips' key.
  outcome.repaint = true
  if not rt.layoutBindingEnabled():
    rt.note("no pane is docked")
    return
  let b = rt.app.layoutBinding
  let docked = b.layout.docked
  if docked.len == 0:
    rt.note("no pane is docked")
    return
  var next = 0
  if b.interaction.kind == ikRevealingDock:
    for i, d in docked:
      if d.pane == b.interaction.pane:
        next = i + 1
  if next >= docked.len:
    discard b.cancelGesture()
    rt.note("hid the auto-hide pane")
    return
  rt.note(b.beginRevealDock(docked[next].pane).message)

proc applyAutoHideReply(rt: TuiRuntime; reply: AutoHideReply): bool =
  ## Carry out what the hover machine said: open the preview overlay (the
  ## binding's `ikRevealingDock`) or close it. True when the screen changed.
  let b = rt.app.layoutBinding
  case reply.cue
  of ahcNone: false
  of ahcPreview:
    if b.interaction.kind in {ikDraggingTab, ikResizingSplit}:
      return false
    b.beginRevealDock(reply.pane).status == lasPending
  of ahcDismiss:
    if b.interaction.kind == ikRevealingDock and
       b.interaction.pane == reply.pane:
      b.interaction = b.interaction.cancel()
      return true
    false

proc autoHidePointer(rt: TuiRuntime; event: MouseEvent; nowMs: int64;
                     outcome: var RuntimeOutcome) =
  ## PLAT-49 part B (finding 9): the pointer over the screen, for the
  ## auto-hide labels — the desktop's hover: after a moment over a label its
  ## pane is previewed as an overlay; leaving the label and the overlay closes
  ## the preview a moment later (`auto_hide_hover`).
  let b = rt.app.layoutBinding
  let geom = rt.layoutGeometry()
  var label = none(PaneKind)
  var open = false
  let strip = geom.stripIndexAt(event.row, event.col)
  if strip >= 0:
    let slot = geom.strips[strip].slotAt(event.row, event.col)
    if slot >= 0:
      let pane = geom.strips[strip].slots[slot].pane
      label = some(pane)
      let at = b.layout.dockedIndex(pane)
      open = at >= 0 and b.layout.docked[at].open
  let inOverlay = b.interaction.kind == ikRevealingDock and
                  geom.reveal.contains(event.row, event.col)
  if rt.applyAutoHideReply(rt.autoHide.pointerAt(label, inOverlay, open,
                                                 nowMs)):
    outcome.repaint = true

proc tickAutoHide*(rt: TuiRuntime; nowMs: int64): bool =
  ## The loop's clock for the auto-hide hover (a preview due, a dismissal
  ## due). True when the screen changed and must be painted.
  if not rt.layoutBindingEnabled():
    return false
  rt.applyAutoHideReply(rt.autoHide.tick(nowMs))

proc autoHideDueMs*(rt: TuiRuntime): int64 =
  ## When `tickAutoHide` next has something to do, -1 for never.
  rt.autoHide.nextDueMs

proc routeTopBarMouse(rt: TuiRuntime; event: MouseEvent;
                      outcome: var RuntimeOutcome): bool =
  ## PLAT-48: a mouse report the top bar, an open menu or an open omnibar
  ## takes. Answers whether it was taken (the layout binding never sees it).
  ##
  ##   * the pointer passing over the row (no button, `?1003`): the control
  ##     under it shows its tooltip and key on the status line;
  ##   * with the menu open, a press in a dropdown clicks the item (a folder
  ##     opens, an item runs); a press outside the menu closes it;
  ##   * with the omnibar open, a press on a result chooses it; outside, it
  ##     closes;
  ##   * a press on the row: `≡` / a folder title opens the menu, a control
  ##     runs its action, the omnibar opens, a tab is activated.
  let screen = shellScreenOf(rt)
  let lay = screen.topBarLayout
  let vm = rt.app.menu
  if event.kind == mekRelease:
    if rt.topBarPressConsumed:
      rt.topBarPressConsumed = false
      return true
    return false
  if event.kind == mekMotion:
    if event.button == mbLeft:
      return false   # a drag: the binding's
    # Hover: the row's controls, and the open menu's items.
    var hovered = -1
    var hoveredTab = -1
    var hoveredAdd = false
    if event.row == 0:
      let hit = lay.topBarHitAt(event.col)
      if hit.kind == thControl:
        hovered = hit.index
      elif hit.kind == thTab:
        hoveredTab = hit.index
      elif hit.kind == thTabAdd:
        hoveredAdd = true
    # PLAT-49 part B: a session tab's tooltip (its title; with an agent in
    # the session, the task, its state and progress) under it while hovered;
    # the "+"'s ("New tab") under it.
    if hoveredTab != rt.app.hoveredTab:
      rt.app.hoveredTab = hoveredTab
      outcome.repaint = true
    if hoveredAdd != rt.app.hoveredTabAdd:
      rt.app.hoveredTabAdd = hoveredAdd
      outcome.repaint = true
    if vm.isOpen:
      let (inside, path) = menuHitAt(screen.menuDropdowns, event.row,
                                     event.col)
      if inside and path.len > 0:
        let before = vm.revision
        vm.hoverPath(path)
        if vm.revision != before:
          outcome.repaint = true
    if hovered != rt.app.hoveredControl:
      rt.app.hoveredControl = hovered
      # PLAT-49: the tooltip is the ViewModel's (`transportTooltip`: label
      # and key), drawn as a label under the control and said on the status
      # line.
      if hovered >= 0:
        let c = TransportControls[hovered]
        rt.app.hoveredTooltip = transportTooltip(
          c.id, rt.chordOf(transportKeyAction(c.id)))
        rt.note(rt.app.hoveredTooltip)
      else:
        rt.app.hoveredTooltip = ""
      outcome.repaint = true
    return true
  if event.kind != mekPress or event.button != mbLeft:
    return vm.isOpen or rt.app.omnibar.isOpen or event.row == 0
  # A left press.
  if vm.isOpen:
    let (inside, path) = menuHitAt(screen.menuDropdowns, event.row, event.col)
    if inside:
      rt.topBarPressConsumed = true
      outcome.repaint = true
      if path.len > 0:
        let act = vm.clickPath(path)
        if act.ran:
          rt.runMenuAction(act.action, outcome)
      return true
    if event.row != 0:
      vm.close()
      rt.topBarPressConsumed = true
      outcome.repaint = true
      return true
  if rt.app.omnibar.isOpen:
    let (inside, index) = rt.omnibarHit(screen, event)
    if inside:
      rt.topBarPressConsumed = true
      outcome.repaint = true
      if index >= 0:
        rt.app.omnibar.select(index)
        rt.acceptOmnibar(outcome)
      return true
    if event.row != 0 or lay.topBarHitAt(event.col).kind != thOmnibar:
      rt.app.omnibar.close()
      if event.row != 0:
        rt.topBarPressConsumed = true
        outcome.repaint = true
        return true
  if event.row != 0:
    return false
  rt.topBarPressConsumed = true
  outcome.repaint = true
  let hit = lay.topBarHitAt(event.col, rt.app.shell.tabsOf())
  case hit.kind
  of thMenuButton:
    if vm.isOpen: vm.close() else: vm.open(keyboard = false)
  of thControl:
    let c = TransportControls[hit.index]
    let ka = transportKeyAction(c.id)
    let enabled = hit.index < rt.app.controlsEnabledOf().len and
                  rt.app.controlsEnabledOf()[hit.index]
    if not enabled:
      rt.note(c.label & " is not available here")
    else:
      rt.performAction(ka, outcome)
  of thOmnibar:
    if not rt.app.omnibar.isOpen:
      rt.openOmnibar()
  of thTab:
    # A click on a session tab switches to it; the switch is on the screen,
    # so nothing is echoed (PLAT-49 part B).
    discard rt.app.shell.activateTab(hit.index)
  of thTabClose:
    # PLAT-49 part B: the tab's close control — the desktop's
    # `.session-tab-close` (Multi-Window-Tab-Management.md, rule 4: "Closing
    # a tab stops its backend and removes it"). The HOST closes a session it
    # opened — its engine with it (`sessionCloser`).
    let closed =
      if not rt.app.sessionCloser.isNil: rt.app.sessionCloser(hit.index)
      else: rt.app.shell.closeTab(hit.index)
    if closed:
      rt.app.hoveredTab = -1
  of thTabAdd:
    # PLAT-49 part B: the strip's "+" — the desktop's "New tab" opens an
    # empty tab whose welcome screen picks the recording; here the omnibar
    # opens on `:open `, listing the recordings the host can see, and the
    # one chosen (or a typed path) opens in a new tab (`acceptOmnibar`).
    rt.app.hoveredTabAdd = false
    rt.openOmnibar(OpenRecordingQuery)
  of thTabMore:
    rt.app.tabScroll = max(0, rt.app.tabScroll + hit.index)
  of thNone:
    discard
  true

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
  # PLAT-48: THE TOP BAR, AN OPEN MENU AND AN OPEN OMNIBAR TAKE THE MOUSE
  # FIRST — a press on row 0 or in a dropdown is never a layout gesture —
  # and the pointer merely passing over the screen (`?1003` motion, no
  # button) is theirs or nobody's: it never repaints a frame for nothing.
  block:
    let (isMouse, event) = decodeMouse(token)
    if isMouse:
      # PLAT-49 part B: the pointer's passing is the auto-hide hover's too.
      if event.kind == mekMotion and event.button != mbLeft and
         rt.layoutBindingEnabled():
        rt.autoHidePointer(event, nowMs, result)
      # PLAT-50: an open right-click menu or content overlay first — it is
      # over everything, the top bar included.
      if rt.routeOverlayMouse(event, result):
        return
      # PLAT-50 (K45): a press held on the timeline's track owns the
      # pointer until it is released.
      if rt.routeTimelineDrag(event, result):
        return
      # PLAT-52: a press held on a Terminal Output scrubber, likewise.
      if rt.routeTerminalDrag(event, result):
        return
      if rt.routeTopBarMouse(event, result):
        return
      if event.kind == mekMotion and event.button != mbLeft:
        return
  if rt.layoutBindingEnabled():
    let (isMouse, event) = decodeMouse(token)
    if isMouse:
      rt.routeMouseReport(event, result)
      return
    # PLAT-47: `Esc` CANCELS A GESTURE IN FLIGHT — a drag's drop tint and
    # ghost go, a held divider snaps back, and nothing is committed (`cancel`
    # takes no layout). Only when one is in flight: otherwise `Esc` is the
    # mode key it has always been.
    if token == "\x1b" and not rt.app.menu.isOpen and
        not rt.app.omnibar.isOpen and
        rt.app.layoutBinding.interaction.kind in {ikDraggingTab,
                                                  ikResizingSplit,
                                                  ikRevealingDock}:
      let cancelled = rt.app.layoutBinding.cancelGesture()
      rt.note(cancelled.message)
      result.detail = cancelled.message
      result.repaint = true
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

  # PLAT-50: an open right-click menu owns the keys, as the program menu
  # does; the content overlay closes on Esc / q / Enter.
  if rt.app.contextMenu.open:
    rt.handleContextMenuKey(token, result)
    return
  if rt.app.content.open:
    case keyName(token)
    of "Escape", "Esc", "Enter", "q":
      rt.app.content = ContentOverlay()
      result.repaint = true
      return
    of "Up", "k": rt.app.content.scroll(-1); result.repaint = true; return
    of "Down", "j": rt.app.content.scroll(1); result.repaint = true; return
    of "PageUp": rt.app.content.scroll(-10); result.repaint = true; return
    of "PageDown", "Space":
      rt.app.content.scroll(10); result.repaint = true; return
    else: discard
  # PLAT-48: AN OPEN OMNIBAR, THEN AN OPEN MENU, OWN EVERY KEY — the text
  # field and the menu are modal, as the desktop's are.
  if rt.app.omnibar.isOpen:
    rt.handleOmnibarKey(token, result)
    return
  if rt.app.menu.isOpen:
    rt.handleMenuKey(token, nowMs, result)
    return
  case keyName(token)
  of MenuKey:
    rt.app.menu.open(keyboard = true)
    rt.note("menu: arrows to move, Enter to choose, Esc to close")
    result.repaint = true
    return
  of RevealKey:
    rt.cycleReveal(result)
    return
  else:
    discard

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

  # PLAT-52: THE TERMINAL OUTPUT'S OWN KEYS while it is focused — the
  # previous / next write and the view toggle, keys no global binding uses.
  if rt.terminalOutputOwnsToken(token):
    rt.routeTokenToTerminalOutput(token, result)
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

  # PLAT-48: §4.2's `Ctrl+p` / `F1` "Fuzzy Command Palette" IS THE OMNIBAR —
  # the desktop's palette is its omnibar, and one model draws both.
  if resolution.action == kaCommandPalette:
    result.action = kaCommandPalette
    rt.openOmnibar()
    result.repaint = true
    return

  rt.performAction(resolution.action, result)

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

proc scheduleHighlights*(rt: TuiRuntime) =
  ## Before a frame: bring the active buffer's held spans up to its current
  ## version, and ask for a parse of that version if none is current or in
  ## flight. Never waits — §11's third rule — so the frame draws whatever is
  ## known, and the answer arrives through `deliverHighlight`.
  if rt.app.modes.product != pmEdit or rt.app.editSession.isNil:
    return
  let buf = rt.app.editSession.activeBuffer()
  if buf.isNil:
    return
  # The buffer's own viewport height, not `sourcePaneRows`: that one builds
  # the whole shell model to find a rectangle, and this runs every frame.
  let rows = buf.doc.viewportRows + HighlightWindowSlack
  buf.highlights.refreshHeld(buf.doc, buf.viewportTop, rows)
  if buf.highlights.needsRequest(buf.doc):
    let req = highlightRequestFor(buf.doc, buf.serial)
    buf.highlights.noteRequested(req)
    if rt.editServices.requestHighlight.isNil:
      buf.highlights.installHighlight(buf.doc, computeHighlight(req),
                                      buf.viewportTop, rows)
    else:
      rt.editServices.requestHighlight(req)

proc deliverFileJob*(rt: TuiRuntime; res: FileJobResult): bool =
  ## A file answer arrived. Reconciled against the buffer it was made for
  ## (`file_io_producer.answerFor`); a read the buffer's edits made stale is
  ## discarded rather than installed over them, and a write marks the buffer
  ## saved as of the bytes that were written. `true` when a frame should be
  ## drawn.
  if rt.app.editSession.isNil:
    return false
  for buf in rt.app.editSession.buffers:
    if buf.path == res.job.path and buf.serial == res.job.bufferSerial:
      if buf.doc.version < res.job.version:
        return false
      let answer = buf.doc.answerFor(res, buf.fileReport)
      if answer.install:
        discard buf.doc.applyChangeSet(answer.change, 0)
      if answer.saved:
        # `loadedText` is "the bytes on disk" — the ones this answer is
        # about, never the buffer's current text, which may have moved while
        # the write ran. See `markSaved`.
        #
        # THE BUFFER STOPS BEING DIRTY AND GOES ON OUTRUNNING THE RECORDING,
        # and those are two predicates rather than one: `recordedText` is NOT
        # touched, because §2.1's staleness is about whether the bytes differ
        # from what was RECORDED, and a save makes a recording MORE stale.
        # Asserted in `test_edit_mode_source.nim` ("a saved edit is still an
        # edit the recording predates") and through the shipped binary in
        # `tests/real_terminal/test_real_edit_mode.nim`.
        buf.markSaved(answer.savedText)
      if answer.install:
        rt.app.editSession.refreshEditedPaths()
      rt.note(answer.note)
      return true
  false

proc runFileJob(rt: TuiRuntime; job: FileJob) =
  ## Submit to the host's worker, or — with none — do the job inline and
  ## deliver it, down the same path.
  if not rt.editServices.submitFileJob.isNil:
    rt.editServices.submitFileJob(job)
    return
  var res = FileJobResult(job: job)
  case job.kind
  of fjRead:
    if rt.editServices.readFile.isNil:
      res.message = ":e! has no reader in this session"
    else:
      let r = rt.editServices.readFile(job.path)
      res.ok = r.ok
      res.text = r.text
      res.message = r.message
  of fjWrite:
    if rt.editServices.writeFile.isNil:
      res.message = ":w has no writer in this session"
    else:
      let w = rt.editServices.writeFile(job.path, job.text)
      res.ok = w.ok
      res.message = w.message
  discard rt.deliverFileJob(res)

proc deliverHighlight*(rt: TuiRuntime; res: HighlightResult): bool =
  ## A parse arrived from the host's worker. Installed into the buffer it
  ## was asked for — reconciled against that buffer's timeline when the
  ## document moved while it was in flight — and `true` when a frame should
  ## be drawn. A result for a buffer that is gone, or for an earlier opening
  ## of the same file, is refused: it names a timeline this session no longer
  ## has.
  if rt.app.editSession.isNil:
    return false
  for buf in rt.app.editSession.buffers:
    if buf.path == res.request.path and buf.serial == res.request.bufferSerial:
      if buf.doc.version < res.request.version:
        return false
      buf.highlights.installHighlight(buf.doc, res, buf.viewportTop,
                                      buf.doc.viewportRows +
                                        HighlightWindowSlack)
      return true
  false

proc shellScreenOf*(rt: TuiRuntime): ShellScreen =
  ## The whole frame for this runtime, at its current size.
  ##
  ## The MODE reaches the status bar through `modal_state.statusMode`, and the
  ## LAYOUT through `motions.layoutFor` — so `z` really replaces the tree with a
  ## single-pane one rather than merely noting that it was pressed.
  rt.scheduleHighlights()
  var model = rt.app.shellModel(rt.width, rt.height)
  model.status.mode = statusMode(rt.modal.mode)
  if rt.maximize.active:
    # `z`. `motions.layoutFor` builds a one-pane `LayoutNode` of the SAME type
    # the profiles build, so `projectLayout`'s totality checks apply to the
    # maximized screen unchanged.
    model.layout = rt.maximize.layoutFor(model.profile)
  if rt.app.notification.len > 0:
    model.status.notification = rt.app.notification
  # PLAT-46: the focused pane gets the focused border role.
  let (hasFocus, focused) = rt.focus.focusedPane()
  model.hasFocus = hasFocus
  model.focused = focused
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

proc paneBodyRows*(rt: TuiRuntime; pane: PaneKind): int =
  ## How many rows `pane` has for its content on the CURRENT screen, under
  ## its tab strip (every pane has one since PLAT-49, and no title row
  ## below it): the rectangle `shell.paintPane` hands its painter, less the
  ## divider row a pane with a neighbour below gives up (`shell.paneFrame`).
  ## Zero when the pane is not on the screen.
  let model = rt.app.shellModel(rt.width, rt.height)
  let layout = if rt.maximize.active: rt.maximize.layoutFor(model.profile)
               else: model.layout
  let body = bodyArea(rt.width, rt.height)
  let projection = projectLayout(layout, body)
  for region in projection.regions:
    if region.pane == pane:
      let frame = paneFrame(region.area, body)
      return max(0, frame.box.height - 1)
  0

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

proc retryOrigin*(rt: TuiRuntime; line: string): RuntimeOutcome =
  ## PLAT-50: run `o` (`line` "") or `:origin X` again, now that the host
  ## put the chain it asked for into the Origin ViewModel — the walk then
  ## moves (`awaitsMove`), or says why it cannot.
  if line.len > 0:
    rt.runPromptLine(line, result)
  else:
    rt.performAction(kaValueOrigin, result)
  result.repaint = true
