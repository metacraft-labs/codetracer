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

import codetracer_embed
import headless_app/headless_app
import isonim_tui

import ./views/shell

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
    variables*: VariablesModel
    timeline*: TimelineBarModel
    eventLog*: EventLogModel
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
    notification*: string
      ## §3.3.6's message line. Owned here rather than recomputed per frame so
      ## the answer to the last command survives until the next one.
    traceName*: string
    tick*: int
    totalTicks*: int
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
         highlighting: newHighlighterCache())

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
  ## carries `slot.layout` — the very `LayoutNode` `HeadlessApp` created for
  ## it, the one `saveLayouts` persists and the one a desktop tab click would
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
  result = ShellModel(
    header: header,
    status: initStatusBarModel(mode = umNormal, profile = selected,
                               notification = app.notification),
    layout: (if active.isNil: profileLayout(selected) else: active.layout),
    profile: selected,
    source: app.source,
    highlighting: app.highlighting,
    callStack: app.callStack,
    variables: app.variables,
    timeline: app.timeline,
    eventLog: app.eventLog)

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
