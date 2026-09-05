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

export headless_app

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

proc newTuiApp*(title: string = "CodeTracer TUI"): TuiApp =
  ## An application with no sessions. Constructing it sends nothing anywhere
  ## and opens nothing: creation is passive, exactly as `newHeadlessApp` and
  ## `newDebuggerSession` are.
  TuiApp(shell: newHeadlessApp(), title: title)

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
