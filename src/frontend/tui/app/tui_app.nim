## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
##
## A module here may import `codetracer_embed`, `headless_app`, `isonim`,
## `isonim_tui` and `std/*` modules that touch neither a process nor a
## terminal. Nothing else. In particular it may not import
## `backend/stdio_backend`, `viewmodel/headless_session`, `std/osproc` or
## `std/posix`: opening a local `.ct` means spawning `replay-server`, and the
## Embed SDK facade deliberately withholds that from consumers
## (CodeTracer-Embed-SDK.md §3.2). `src/frontend/tui/host/` is where that
## lives, and `src/frontend/tui/tests/test_tui_facade_boundary.nim` walks this
## directory's import graph on every run so the rule is a fact rather than a
## convention.
##
## app/tui_app.nim — the terminal application, minus the terminal.
##
## ## What this is
##
## The same argument `headless_app/headless_app.nim` makes for itself, one
## layer out: it composes a whole multi-session debugger shell out of
## `codetracer_embed` and nothing else, and this module composes a whole
## terminal front-end out of `headless_app` plus a renderer. Neither can reach
## a `std/osproc` from where it sits.
##
## `TuiApp` therefore owns
##
##   * the session set and which one is active — by delegation to
##     `HeadlessApp`, so the TUI and the desktop share one shell model rather
##     than growing a second one;
##   * how that state reads on screen — `statusLine`, a pure function, and
##     `renderShell`, which turns it into a `TerminalNode`.
##
## It does **not** own a `BackendService`. Like `HeadlessApp` and
## `DebuggerSession` it takes one by injection, which is precisely what keeps
## it on this side of the facade: a module that constructed one would have to
## spawn a process to do it.
##
## ## Why the render function lives here and not in `host/`
##
## Rendering is not a host capability. A `TerminalNode` tree is a value; it
## becomes bytes only when a driver writes it, and `isonim_tui`'s
## `TerminalTestHarness` can composite one with no terminal at all — which is
## what `test_tui_stack_compiles_and_renders.nim` does. Putting the view here
## is what makes the Tier-1 half of the campaign's testing architecture
## possible, and it is why `host/` stays as small as it does.

import std/options

import codetracer_embed
import headless_app/headless_app
import headless_app/layout_interaction
import isonim_tui

import ./edit_binding
import ./views/shell
# PLAT-48: the top bar's shared models come through `codetracer_embed`.
import headless_app/session_tabs
import headless_app/footer_info
import ./views/status_bar   # `productIndicator`, for the status row's room
import ./views/header       # `textCells`
import ./layout/binding     # `slotExtent`, `footerLeadCells`
import ./layout/cells       # `terminalPaneName`
import ./views/vcs_pane
import ./views/point_list

export headless_app
export shell

type
  TuiApp* = ref object
    ## The terminal front-end's application state.
    ##
    ## Not reactive, for the reason `HeadlessApp` records about itself: every
    ## pane's state is already a signal, and the shell's own state is read once
    ## per redraw.
    shell*: HeadlessApp
      ## The session set, its active member, and each session's `LayoutNode`.
      ## Shared with the desktop by construction rather than by convention —
      ## CTUI-3 projects that same `LayoutNode` onto Yoga.
    title*: string
      ## What the header names this window. A field rather than a constant so a
      ## host embedding the TUI can say what it is.
    source*: SourcePaneModel
      ## CTUI-5's source pane, as a value, for the `editor` rectangle.
      ##
      ## A FIELD RATHER THAN A `SourceVM` HANDLE, and that is the same split
      ## `app/views/source_pane.nim` argues for at length: the view is a pure
      ## function of a value, `app/source_binding.nim` is the only thing that
      ## reads a ViewModel, and a host sets this once per frame from what the
      ## binding produced. Empty by default, in which case the shell paints the
      ## pane's generic title row exactly as it did before CTUI-5.
    highlighting*: HighlighterCache
      ## Parsed token spans, cached per `(path, generation, digest, window)`.
      ## Owned by the application rather than created per frame, which is
      ## CTUI-5's risk mitigation for tree-sitter cost; `nil` parses every
      ## frame.
    callStack*: CallStackModel
    callTrace*: CallTraceModel
      ## PLAT-47: the recording's call trace (see `views/call_trace.nim`).
    callTraceLoaded*: bool
      ## A session asked for the call trace; an empty `callTrace` then means
      ## the recording has none, and the pane says so.
    callTraceScrolled*: bool
      ## The reader scrolled the call trace away from the current call; the
      ## pane keeps its own position (`callTrace.scrollTop`) until `.` asks
      ## it to follow again.
    variables*: VariablesModel
    timeline*: TimelineBarModel
    eventLog*: EventLogModel
    points*: PointListPaneModel
      ## PLAT-40. The Points pane's rows; empty until a session supplies them.
      ## CTUI-6, CTUI-7 and CTUI-8's panes, as values, on exactly the rule
      ## `source` above states: a host sets each one per frame from what the
      ## matching binding produced, and the view is a pure function of the
      ## value.
      ##
      ## CTUI-11 ADDED THESE, and until it did there was nothing that could
      ## have: every one of those panes was exercised only through a test that
      ## built its own model, because `main.nim` had no driver and therefore no
      ## frame to put one in. Their zero values are the EMPTY models
      ## `app/views/shell.nim` already documents as its default, so a `TuiApp`
      ## that never fills them paints exactly the screen it painted before.
    frameViewer*: FrameViewerModel
      ## PLAT-15's frame viewer, magnifier and pixel history, as a value, on
      ## exactly the rule `source` above states.
      ##
      ## CLOSED BY DEFAULT (`FrameViewerModel.open` is false), so a host that
      ## never fills it paints exactly the screen it painted before — which is
      ## what keeps every golden in this repository byte-identical. A host sets
      ## it once per frame from what `app/frame_viewer_binding.nim` produced.
    notification*: string
      ## §3.3.6's message line. Owned here rather than recomputed per frame so
      ## the answer to the last command survives until the next one.
    dividers*: DividerChoice
      ## PLAT-50: `--dividers` — the colour a pane divider is drawn in.
    contextMenu*: ContextMenuState
      ## PLAT-50: the open right-click menu, if any.
    content*: ContentOverlay
      ## PLAT-50: a text shown over the body — an event's full content (a
      ## right-click on its row), a call argument's value (a click on it), a
      ## value's history, a changed file's diff.
    viewedFile*: string
      ## PLAT-50: a file the user opened from the Files pane, shown in the
      ## editor instead of the stop's file until the debugger next moves (the
      ## desktop opens it in a tab, and its editor follows the debugger back).
    scratchpad*: ScratchpadPaneModel
      ## PLAT-50: the values pinned to the scratchpad (`ScratchpadVM`'s rows).
    location*: string
      ## PLAT-50 (K37): where the debugger is, `path:line` — what a click on
      ## the status line copies (the desktop's status bar location and its
      ## copy button).
    clipboard*: string
      ## PLAT-50: text a click copied (Copy, the status bar's location),
      ## handed to the terminal's clipboard by the next frame (OSC 52) and
      ## cleared.
    tracepointAt*: tuple[path: string, line: int]
      ## PLAT-50: the line the editor menu's "Add tracepoint" was chosen on;
      ## the next `:tracepoint` is placed there instead of at the stop.
    timelineDrag*: bool
      ## PLAT-50: a press on the timeline's track is held — its release seeks
      ## where the pointer is then (the desktop's drag on the track).
    layoutBinding*: LayoutBinding
      ## PLAT-6's terminal layout binding: the committed `Layout` with its undo
      ## log, the gesture in flight, and the responsive-profile freeze.
      ##
      ## **`nil` BY DEFAULT, and that is what keeps CTUI-3's screens byte
      ## identical.** With no binding, `shellModel` carries the session's own
      ## `LayoutNode` and an empty `docked`, which is exactly the model CTUI-3
      ## built — so a host that never calls `enableLayoutBinding` paints the
      ## screen it painted before, and every golden written against it still
      ## reads.
      ##
      ## With one, the binding's `Layout` is what is drawn AND what gestures
      ## change, so a moved tab survives the next repaint rather than being
      ## re-derived from the profile.
    modes*: ModeRegister
      ## PLAT-16. WHICH PRODUCT MODE THIS FRONT-END IS IN, and each mode's
      ## arrangement as the user last left it in this session.
      ##
      ## `pmDebug` with two nil cells is the zero value, so an application
      ## nobody switched paints exactly the screen it painted before and
      ## `shellModel`'s layout rule below is untouched by this milestone until
      ## the first `Ctrl+F5`.
      ##
      ## It is a field of the APPLICATION rather than of `ShellModel`, and that
      ## matters: `shellModel` builds a fresh value every frame, so a register
      ## living there would be reset by the next repaint and the toggle would
      ## appear to work once per frame — which is precisely the "works once"
      ## failure Mode-Transitions.md §6 is written against, arriving through
      ## the lifetime of a local instead of through a slot.
    projectRoot*: string
      ## PLAT-16. The folder `ct edit --ui=tui <project>` opened, or "" in a
      ## Debug-only session. Every path the edit host reads or writes is
      ## resolved against it, which is what makes the containment check in
      ## `host/edit_host.nim` a check about something.
    fileTree*: FileTreeModel
      ## PLAT-16. `paneFileTree`'s model, as a value, filled by the host from
      ## `edit_host.listProjectFiles`.
    vcs*: VcsPaneModel
      ## PLAT-47 deliverable 4. `paneVcs`'s model, as a value, filled by the
      ## host (`host/vcs_source.nim`) from the shared `VCSVM`.
    build*: BuildSession
      ## PLAT-16. The build or run in flight, or the last one's verdict, or
      ## `nil` for a session that has never built. `nil` is a state the pane
      ## renders (`build: not started`) rather than one it hides.
    editSession*: EditSession
      ## PLAT-16. The open buffers, their carets, their scroll positions and
      ## the project's points.
      ##
      ## `nil` until Edit mode is entered, and it SURVIVES every subsequent
      ## switch — which is the whole of Mode-Transitions.md §5's preservation
      ## table met by construction. See `app/edit_binding.EditSession`.
    traceName*: string
    tick*: int
    totalTicks*: int
    menu*: MenuVM
      ## PLAT-48. The program menu — the shared tree, the shared state.
    omnibar*: OmnibarVM
      ## PLAT-48. The omnibar.
    icons*: IconsMode
      ## PLAT-48. How the debugger controls are drawn (`:icons`).
    iconsChosen*: bool
      ## Whether the user chose `icons` (stored or typed); when not, the
      ## default follows what the terminal was measured to draw.
    graphicsDrawn*: bool
      ## The terminal answered the kitty graphics query: it draws pictures.
    hoveredControl*: int
    hoveredTab*: int
      ## PLAT-49 part B: the session tab under the pointer, -1 for none.
    hoveredTabAdd*: bool
      ## PLAT-49 part B: the pointer is on the strip's "+".
    recordingOpener*: proc(path: string): string {.closure.}
      ## PLAT-49 part B: the HOST's "open this recording in a new session
      ## tab" — "" when it opened, else why not. Nil when the host cannot
      ## (an in-process caller with no engine to spawn); the strip then
      ## draws no "+". It lives in `host/` because opening a recording
      ## spawns `replay-server`, which this layer cannot.
    sessionCloser*: proc(index: int): bool {.closure.}
      ## PLAT-49 part B: the host closes the session behind tab `index`
      ## (its engine too); nil means the shell's own `closeTab` does.
    recordings*: seq[OmnibarEntry]
      ## PLAT-49 part B: the recordings the host can see (`omRecording`
      ## entries), what the "+"'s `:open ` lists.
    hoveredTooltip*: string
      ## PLAT-49: the hovered control's tooltip, from
      ## `debug_controls_vm.transportTooltip`.
    caretDrawn*: bool
      ## PLAT-49: the terminal is not known to honour caret shapes
      ## (DECSCUSR), so the omnibar's caret is drawn into its cell.
    tabScroll*: int
    controls*: DebugControlsVM
      ## The session's transport ViewModel, for which controls are available.
    filesVM*: FilesystemVM
    store*: ReplayDataStore
      ## What the omnibar's index is gathered from (`omnibar_sources`).
      ## §3.1's header fields for a session a HOST opened.
      ##
      ## SEPARATE FROM `shell.activeSlot()`, and that is the point rather than
      ## duplication. `HeadlessApp`'s slots are the DESKTOP's multi-session
      ## model — a tab strip, a persisted `LayoutNode` per session — and the
      ## terminal front-end opens one trace through `host/tui_session.nim`,
      ## which spawns `replay-server` and therefore cannot be an `app/` concern.
      ## Left at "" and 0 these change nothing: `shellModel` prefers the active
      ## slot's title when there is one, so every existing caller paints the
      ## header it painted before.

proc newTuiApp*(title: string = "CodeTracer TUI"): TuiApp =
  ## An application with no sessions. Constructing it sends nothing anywhere
  ## and opens nothing: creation is passive, exactly as `newHeadlessApp` and
  ## `newDebuggerSession` are.
  TuiApp(shell: newHeadlessApp(), title: title,
         highlighting: newHighlighterCache(),
         modes: initModeRegister(),
         menu: newMenuVM(nativeFrontEndMenu("CodeTracer")),
         omnibar: newOmnibarVM(), icons: imUnicode, hoveredControl: -1,
         hoveredTab: -1,
         # The event log's default columns before any session (PLAT-49 part
         # B): `:column-*` acts on these when no log is open yet.
         eventLog: initEventLogModel())

proc controlsEnabledOf*(app: TuiApp): seq[bool] =
  ## Per `TransportControls`: whether the session's ViewModel offers it now
  ## (`debug_controls_vm.transportAvailable`, the desktop toolbar's rule).
  if app.isNil or app.controls.isNil:
    return
  for c in TransportControls:
    result.add app.controls.transportAvailable(c.id)

proc refreshOmnibarIndex*(app: TuiApp) =
  ## Rebuild what the omnibar can find from the session's ViewModels.
  if app.isNil or app.omnibar.isNil:
    return
  app.omnibar.setIndex(omnibarIndexOf(app.filesVM, app.store, app.menu) &
                       app.recordings)

proc openSession*(app: TuiApp; backend: BackendService;
                  title: string = ""): HeadlessSessionSlot =
  ## Add a session over `backend` and make it active.
  ##
  ## `backend` is injected. This layer cannot build one — see the layer rule
  ## above — so a host that wants a local trace hands in what
  ## `src/frontend/tui/host/` produced.
  app.shell.openSession(backend, title = title)

proc sessionCount*(app: TuiApp): int =
  ## How many sessions are open.
  app.shell.slotCount()

proc dispose*(app: TuiApp) =
  ## Tear the application down. Idempotent, because `HeadlessApp.dispose` is.
  if app.isNil:
    return
  app.shell.dispose()

proc statusLine*(app: TuiApp): string =
  ## The header line, as text.
  ##
  ## A pure function of the shell's state, separately from any rendering, for
  ## the same reason CTUI-3 asks profile selection to be one: a string can be
  ## asserted exactly, and a screen region can then be asserted to CONTAIN it,
  ## which localises a failure to either the model or the compositor instead of
  ## leaving it between them.
  if app.isNil:
    return ""
  let active =
    if app.shell.activeSessionId() == NoHeadlessSession: "-"
    else: $app.shell.activeSessionId()
  app.title & "  sessions:" & $app.shell.slotCount() & "  active:" & active

proc shellModel*(app: TuiApp; width, height: int): ShellModel =
  ## The CTUI-3 screen model for this application at this terminal size.
  ##
  ## THE LAYOUT TREE IS THE SESSION'S OWN. When a session is open, the model
  ## carries `slot.layout`'s tree — the very `LayoutNode` `HeadlessApp` created
  ## for it, the one `saveLayouts` persists and the one a desktop tab click would
  ## `activate`. Copying it, or building a fresh one from the profile, would
  ## give the terminal a second layout that looked identical until the first
  ## `Alt+1`, which is exactly the divergence CTUI-3 exists to prevent.
  ##
  ## With no session open there is nothing to carry, so the profile's default
  ## tree is used and the header says so.
  let selected = selectProfile(width, height)
  var header = initHeaderModel(
    traceName = (if app.traceName.len > 0: app.traceName else: "-"),
    tick = app.tick, totalTicks = app.totalTicks)
  let active = app.shell.activeSlot()
  if not active.isNil:
    header.traceName = (if active.title.len > 0: active.title else: $active.id)
  for id in app.shell.slotIds():
    let s = app.shell.slot(id)
    if not s.isNil:
      header.sessions.add SessionTab(
        title: (if s.title.len > 0: s.title else: $s.id),
        active: s.id == app.shell.activeSessionId())
  # PLAT-6: when a layout binding is enabled it is the authority on the
  # arrangement — the session's tree is what it was CREATED from, and letting
  # the session's node win here would throw away every gesture on the next
  # repaint, which is the same divergence CTUI-3 refused for `activate`.
  let bound = not app.layoutBinding.isNil
  let boundLayout = if bound: app.layoutBinding.layout else: initLayout(nil)
  # PLAT-16: THE REGISTER WINS WHEN IT HOLDS A TREE FOR THE CURRENT MODE.
  #
  # It holds one only after a `Ctrl+F5` has been made, and what it holds for
  # Debug mode is the session's own node rather than a copy of it (see
  # `shell.ModeRegister`), so this is not a second layout authority: in Debug
  # mode with no switch ever made, and in Debug mode after a round trip, the
  # tree is the same object either way. In Edit mode the register is the only
  # authority there is — a session's `LayoutNode` is a REPLAY arrangement and
  # `HeadlessApp` has no edit slot to hold a second one.
  let registered = app.modes.activeLayout()
  # PLAT-49 part B: the status bar's file info — the file the editor shows
  # (the Edit buffer's in Edit mode) — and the width it takes before the
  # bottom labels, which the binding's hit-test reads.
  let infoPath =
    if app.modes.product == pmEdit and not app.editSession.isNil and
       not app.editSession.activeBuffer().isNil:
      app.editSession.activeBuffer().path
    else: app.source.path
  let fullInfo = footerFileInfoText(infoPath)
  result = ShellModel(
    header: header,
    dividers: app.dividers,
    contextMenu: app.contextMenu,
    content: app.content,
    topBar: TopBarModel(menu: app.menu, omnibar: app.omnibar,
                        icons: app.icons, graphicsDrawn: app.graphicsDrawn,
                        controlsEnabled: app.controlsEnabledOf(),
                        hoveredControl: app.hoveredControl,
                        hoverTooltip: app.hoveredTooltip,
                        hoveredTab: app.hoveredTab,
                        canAddTab: not app.recordingOpener.isNil,
                        hoveredTabAdd: app.hoveredTabAdd,
                        tabs: app.shell.tabsOf(), tabScroll: app.tabScroll,
                        caretDrawn: app.caretDrawn),
    status: initStatusBarModel(mode = umNormal, profile = selected,
                               notification = app.notification,
                               product = app.modes.product,
                               # PLAT-45: say so when the screen is the shared
                               # default FOLDED — and only then. An arrangement
                               # the user made is theirs, not a fold.
                               fold = (if bound and
                                          app.layoutBinding.userModified: ""
                                       else: foldNote(app.modes.product,
                                                      selected))),
    layout: (if not registered.isNil: registered
             elif bound: boundLayout.tree
             elif active.isNil: layoutForMode(app.modes.product, selected)
             else: active.layout.tree),
    docked: (if bound: boundLayout.docked
             elif not registered.isNil: @[]
             elif active.isNil: dockedForMode(app.modes.product)
             else: active.layout.docked),
    interaction: (if bound: app.layoutBinding.interaction
                  else: noInteraction()),
    dragPointer: (if bound and app.layoutBinding.pointerRow >= 0 and
                     app.layoutBinding.interaction.kind == ikDraggingTab:
                    some((app.layoutBinding.pointerRow,
                          app.layoutBinding.pointerCol))
                  else: none((int, int))),
    profile: selected,
    source: app.source,
    highlighting: app.highlighting,
    callStack: app.callStack,
    callTrace: app.callTrace,
    callTraceLoaded: app.callTraceLoaded,
    variables: app.variables,
    timeline: app.timeline,
    eventLog: app.eventLog,
    points: app.points,
    scratchpad: app.scratchpad,
    frameViewer: app.frameViewer,
    fileTree: app.fileTree,
    vcs: app.vcs,
    build: buildPaneModelFor(app.build),
    product: app.modes.product,
    edit: (if app.editSession.isNil: initEditPaneModel()
           else: editPaneModelFor(app.editSession,
                                  app.editSession.activeBuffer())))
  # THE FILE INFO YIELDS TO A NOTE. The status row carries the file info, the
  # bottom labels, the mode indicators and the notification; where they do
  # not all fit, the file info is the one left out — a message the user
  # cannot read is the failure this row exists to prevent (`statusBarText`),
  # and the language of the file on screen is the least urgent fact on it.
  var labelsW = 0
  for d in result.docked:
    if d.edge == leBottom:
      labelsW += slotExtent(leBottom, (if d.title.len > 0: d.title
                                       else: terminalPaneName(d.pane)))
  let modeW = textCells("COMMAND " & productIndicator(result.product) &
                        (if result.status.fold.len > 0: " " & result.status.fold
                         else: ""))
  let noteW = (if app.notification.len > 0: textCells(app.notification) + 2
               else: 0)
  let fileInfo =
    if footerLeadCells(fullInfo) + labelsW + 1 + modeW + noteW <= width:
      fullInfo
    else: ""
  result.fileInfo = fileInfo
  if bound:
    app.layoutBinding.footerLead = footerLeadCells(fileInfo)

proc enableLayoutBinding*(app: TuiApp; width, height: int): LayoutBinding =
  ## Give this application a layout the user can rearrange (PLAT-6).
  ##
  ## Seeded from the ACTIVE SESSION's own `Layout` — tree AND docked panes,
  ## since `HeadlessSessionSlot.layout` holds the whole value — when there is
  ## one, so enabling
  ## the binding changes nothing on screen at the moment it is enabled: the
  ## first frame after this call is the frame that would have been painted
  ## without it. With no session open it starts from the profile's default,
  ## which is what `shellModel` would have drawn anyway.
  ##
  ## Explicit rather than automatic in `newTuiApp`, because a host that has not
  ## wired the gesture surface would otherwise gain a layout nothing can drive
  ## and, with it, a second thing that decides what the screen shows.
  let selected = selectProfile(width, height)
  let active = app.shell.activeSlot()
  let seed =
    if active.isNil or active.layout.tree.isNil:
      profileLayoutValue(selected)
    else: active.layout
  app.layoutBinding = newLayoutBinding(seed, selected)
  app.layoutBinding

proc renderScreen*(app: TuiApp; r: TerminalRenderer;
                   width, height: int): TerminalNode =
  ## The whole CTUI-3 shell as a component tree. `renderShell` below is CTUI-0's
  ## one-row probe and is kept because its test asserts a property this does not
  ## — that a `TuiApp` composites at all with no size negotiated.
  renderShellTree(app.shellModel(width, height), r, width, height)

proc renderShell*(app: TuiApp; r: TerminalRenderer): TerminalNode =
  ## Build the application's component tree.
  ##
  ## CTUI-0's shell is one header row: the milestone's subject is that the
  ## renderer and the ViewModel graph co-compile and co-render in one process,
  ## and a single row proves that as completely as twenty would while leaving
  ## CTUI-3 free to specify the real layout. The tree is deliberately built
  ## through the renderer's own element API rather than the `ui` DSL, so this
  ## milestone's compile does not yet depend on `isonim`'s tailwind style map
  ## being generated.
  let root = r.createElement("div")
  let header = r.createElement("div")
  r.appendChild(header, r.createTextNode(app.statusLine()))
  r.appendChild(root, header)
  root
