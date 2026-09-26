## LAYER RULE — `src/frontend/gpui/app/` is the SDK-CONSUMING half of the GPUI
## front-end, and it carries a `.sdk-consumer` marker saying so. See that file,
## and `src/frontend/tui/app/cli.nim`'s header for the rule this copies.
##
## gpui/app/shell.nim — PLAT-20. **The shell, and it contains no GPUI.**
##
## ## The decomposition, stated so it can be checked rather than believed
##
## PLAT-20 asks for *"the shell/leaf decomposition applied: the shell is
## `HeadlessApp` plus the layout model, and only the leaves are GPUI. This is
## the same split the TUI already demonstrates, and the reason a third
## front-end is a binding rather than a rewrite."*
##
## So:
##
##   * **the shell** is this module. It is `HeadlessApp` (the session set, which
##     one is active, each session's panes) plus `WindowSet`/`Layout` (the
##     arrangement) plus `dock_projection` (what a dock host is handed). Its
##     five imports are `std/[json, sets, tables]`, `codetracer_embed`,
##     `headless_app/headless_app`, `headless_app/window_set` and
##     `./dock_projection` — no renderer, no `isonim_gpui`, no `isonim`, no
##     window. `test_gpui_shell_split.nim` asserts that list and its length.
##   * **the leaves** are `gpui/app/leaves.nim`, which is the only module in
##     this front-end that imports `isonim_gpui`, and
##     `gpui/host/` which owns the process.
##
## The `static:` block below is not documentation: it is a compile-time
## assertion that no renderer type is in scope here, and
## `tests/test_gpui_shell_split.nim` asserts the same property from the outside
## by reading this file's import list. Two instruments, two failure modes — the
## `static:` catches a renderer reached through a re-export that no import line
## names, and the suite catches a renderer whose type the `static:` happens not
## to name.
##
## ## `HeadlessApp` IS UNCHANGED BY THIS MILESTONE
##
## That is PLAT-20's verification gate — *"a shell that needed changing to host
## a second GPU front-end was not renderer-free"* — and it is a property of this
## file rather than of a promise: everything below is built out of
## `HeadlessApp`'s existing surface (`openSession`, `activate`, `slot`,
## `paneViewModel`, `saveLayouts`, `restoreLayouts`) with no new field, no new
## parameter and no new hook. Measured rather than asserted: on PLAT-20's
## working tree `git diff --stat -- src/frontend/headless_app/` prints NOTHING
## — not one tracked file under it is modified — and `git status --porcelain
## -uall` lists exactly one addition there, `extent_distribution.nim`, which is
## a new file and therefore additive by construction.
##
## ## WHY THE SHELL HOLDS A `WindowSet` AND `HeadlessApp` HOLDS A `Layout`
##
## `HeadlessSessionSlot.layout` was a bare `LayoutNode` when this file was
## written, and widening it was a change to `HeadlessApp` — the one thing
## PLAT-20's gate forbade — so the shell held the `WindowSet` ITSELF, keyed by
## session, and synchronised only the TREE back onto the slot. That dropped a
## docked pane on the way: `saveLayouts` then wrote an arrangement with the
## pane in neither place. PLAT-4's closing pass (2026-09-26) widened the slot
## to a whole `Layout`, and the sync below now carries the docked panes too.
##
## The shell still holding the `WindowSet` is not a workaround: it is where the concept belongs. Layout-ViewModel
## §3A.1 puts `WindowSet` *above* `Layout`, and a top-level window is the
## HOST's concept: the terminal has exactly one and says so, a GPUI host may
## have several, and `HeadlessApp` — which is neither — should not know.

import std/[json, sets, tables]

import codetracer_embed
import headless_app/headless_app
import headless_app/window_set
import ./dock_projection

export headless_app, window_set, dock_projection

static:
  # THE SHELL IMPORTS NO RENDERER, asserted at compile time.
  #
  # A `when declared(...)` over a symbol only a renderer defines is the cheapest
  # form of this that cannot pass vacuously: if `isonim_gpui/renderer` were
  # reachable from here, `GpuiRenderer` would resolve and this would fail the
  # build. It is paired with the source-reading case in
  # `tests/test_gpui_shell_split.nim`, which catches the mirror failure — a
  # renderer whose type this expression happens not to name.
  when declared(GpuiRenderer):
    {.error: "gpui/app/shell.nim reached a GPUI renderer. The shell is " &
             "HeadlessApp plus the layout model; only the leaves are GPUI " &
             "(PLAT-20).".}
  when declared(TerminalRenderer):
    {.error: "gpui/app/shell.nim reached a terminal renderer.".}

type
  GpuiShellError* = object of CatchableError
    ## A caller mistake — an unknown window, a shell used after dispose.
    ## A *session* failure is not this, for the reason `HeadlessAppError`'s
    ## own comment gives.

  GpuiShell* = ref object
    ## The GPUI front-end's shell. Renderer-free by construction.
    app*: HeadlessApp
      ## The session set. Constructed here, never subclassed, never extended.
    windows*: WindowSet
      ## The arrangement, one `Layout` per top-level window. See the header for
      ## why this is the shell's and not `HeadlessApp`'s.
    viewport*: DockViewport
      ## The extent the dock projection divides. The host's, set by the host.
    bindings: Table[int, HeadlessSessionId]
      ## Which session each window shows, keyed by `int(WindowId)`. A
      ## `Table[WindowId, …]` would need a `hash` for a distinct int; the key
      ## is unwrapped here rather than widening `window_set`'s surface for a
      ## consumer's convenience.

  GpuiLeafKind* = enum
    ## What a leaf slot holds, and the enumeration is PLAT-9's `PaneRefKind`
    ## carried to this front-end rather than re-derived: a contributed pane
    ## from an extension that is not loaded is a REPORT, never a blank region.
    glkBuiltin
    glkContributed
    glkUnloadedExtension

  GpuiLeaf* = object
    ## **One leaf, as the host must render it.** This is the seam: everything
    ## above it is the shell, everything that consumes it is GPUI.
    ##
    ## It carries no colour, no font, no element and no pixel. `slot` says
    ## where the dock puts the leaf and `vm` says what to draw; turning those
    ## two into GPUI elements is `leaves.nim`'s whole job, and the reason the
    ## shell can be tested with no display.
    kind*: GpuiLeafKind
    paneId*: string
      ## The model's own persisted id.
    builtin*: PaneKind
      ## Meaningful when `kind == glkBuiltin`.
    title*: string
    slot*: DockPaneSlot
      ## Placement and stack membership, from the projected document — NOT
      ## re-derived from the model. A host that read the model here would be
      ## drawing one arrangement while the dock was told another.
    vm*: ViewModel
      ## The ViewModel behind the pane, or nil when the session has not been
      ## launched. `live` is the predicate; nothing reads this without it.

  GpuiLeafSet* = object
    windowId*: WindowId
    leaves*: seq[GpuiLeaf]
    refused*: seq[DockProjectionProblem]
      ## Non-empty exactly when the projection refused. A host shows this
      ## instead of a window full of nothing — the `prInvalidLayout` rule one
      ## medium across.

func live*(leaf: GpuiLeaf): bool =
  ## Whether the leaf has a ViewModel to draw.
  not leaf.vm.isNil

proc raiseShell(msg: string) {.noreturn.} =
  raise newException(GpuiShellError, msg)

const DefaultGpuiViewport* = DockViewport(width: 1440, height: 900,
                                          dockExtent: 300)
  ## A host that has not measured its window yet. Named rather than inlined so
  ## a test and a host cannot disagree about what "the default" divides.

proc newGpuiShell*(viewport: DockViewport = DefaultGpuiViewport): GpuiShell =
  ## A shell with no sessions and no windows. Passive, like
  ## `newHeadlessApp` — constructing it sends nothing anywhere and opens no
  ## display.
  GpuiShell(app: newHeadlessApp(),
            windows: WindowSet(windows: @[], focused: 0,
                               capacity: wcMultiWindow,
                               version: WindowSetSchemaVersion),
            viewport: viewport,
            bindings: initTable[int, HeadlessSessionId]())

proc openWindowForSession*(shell: GpuiShell; id: WindowId;
                           session: HeadlessSessionId): WindowSetOutcome =
  ## Give `session` a top-level window whose `Layout` is the session's own
  ## — a copy of the slot's, docked panes included. Changing it later is a
  ## `WindowSet` operation on THIS side, and the session's `Layout` follows
  ## via `syncSessionLayouts`.
  if shell.isNil:
    raiseShell("GpuiShell is nil")
  let slot = shell.app.slot(session)
  if slot.isNil:
    raiseShell("openWindowForSession: unknown session " & $session)
  let outcome = shell.windows.openWindow(id, slot.layout.clone())
  if outcome.kind == wsApplied:
    shell.windows = outcome.windows
    shell.bindings[int(id)] = session
  outcome

proc openWindow*(shell: GpuiShell; id: WindowId;
                 layout: Layout): WindowSetOutcome =
  ## A top-level window showing an arrangement and NO session.
  ##
  ## A REAL PRODUCT STATE and not a test affordance, which is why it is here
  ## rather than in a suite. `HeadlessApp.openSession` creates a session in
  ## `dspCreated` and its panel ViewModels stay nil until `launch` or `attach`,
  ## so between opening a window and a session answering, every leaf in it has
  ## no ViewModel — and `leavesFor` already reports that state by name. A
  ## window with no session at all is the same state with one fewer thing in
  ## it, and a host that opened a window before choosing a recording is in it.
  ##
  ## It is also what lets PLAT-20's three named integration tests run with no
  ## backend of any kind, real or mocked: their subject is *pane placement and
  ## stack membership*, which is a property of the arrangement and not of a
  ## recording. Per the workspace policy on mocks, the right answer to "this
  ## test would need a mock backend" is usually that it does not need a
  ## backend.
  if shell.isNil:
    raiseShell("GpuiShell is nil")
  let outcome = shell.windows.openWindow(id, layout)
  if outcome.kind == wsApplied:
    shell.windows = outcome.windows
  outcome

proc sessionOf*(shell: GpuiShell; id: WindowId): HeadlessSessionId =
  ## Which session a window shows, or `NoHeadlessSession`.
  if shell.isNil or not shell.bindings.hasKey(int(id)):
    return NoHeadlessSession
  shell.bindings[int(id)]

proc syncSessionLayouts*(shell: GpuiShell) =
  ## Push each window's committed tree back onto the session slot it shows.
  ##
  ## ONE DIRECTION, and it is the one that keeps `HeadlessApp.saveLayouts`
  ## honest: the shell owns the arrangement while the front-end is running, and
  ## the session slot is what a *save* reads. Running it the other way — the
  ## slot overwriting the window — would make an activation in one window move
  ## a pane in another, which is the coupling `HeadlessSessionSlot.layout`'s own
  ## comment exists to prevent.
  if shell.isNil:
    return
  for slot in shell.windows.windows:
    if not shell.bindings.hasKey(int(slot.id)):
      continue
    let session = shell.app.slot(shell.bindings[int(slot.id)])
    if session.isNil:
      continue
    # The WHOLE layout. Copying only `.tree` (as this did while the slot held
    # a `LayoutNode`) loses every docked pane on the way to `saveLayouts`.
    session.layout = slot.layout.clone()

proc applyIn*(shell: GpuiShell; id: WindowId;
              cmd: LayoutCommand): WindowSetOutcome =
  ## Apply one layout command in one window, and keep the session in step.
  ##
  ## Every arrangement change a GPUI host can make goes through here, which is
  ## what makes PLAT-20's floating-panel assertion a statement about the
  ## FRONT-END rather than about a function: there is no second door, and
  ## `LayoutCommand` has no member that can place a pane outside the split
  ## tree.
  if shell.isNil:
    raiseShell("GpuiShell is nil")
  let outcome = shell.windows.applyIn(id, cmd)
  if outcome.kind == wsApplied:
    shell.windows = outcome.windows
    shell.syncSessionLayouts()
  outcome

proc projectionFor*(shell: GpuiShell; id: WindowId): DockProjection =
  ## The dock document for one window.
  let idx = shell.windows.indexOf(id)
  if idx < 0:
    return DockProjection(status: dpsRefused, problems: @[
      DockProjectionProblem(kind: dppEmptyLayout,
                            detail: "no window " & $id)])
  projectDock(shell.windows.windows[idx].layout, shell.viewport)

proc leavesFor*(shell: GpuiShell; id: WindowId;
                loadedExtensions: HashSet[string] =
                  initHashSet[string]()): GpuiLeafSet =
  ## **The seam.** Every leaf a host must draw for one window, in the order the
  ## projected document places them.
  ##
  ## Derived from the PROJECTION rather than from the model, deliberately: the
  ## host draws what the dock was told, and a leaf list re-walked out of the
  ## `Layout` would be a second opinion from the same source (§14). A pane the
  ## projection refused to place is not in this list, and the refusal is.
  result = GpuiLeafSet(windowId: id, leaves: @[], refused: @[])
  if shell.isNil:
    return
  let projection = shell.projectionFor(id)
  if projection.status == dpsRefused:
    result.refused = projection.problems
    return
  let arrangement = readDockArrangement(projection.state)
  let sessionId = shell.sessionOf(id)
  let session = shell.app.slot(sessionId)
  let idx = shell.windows.indexOf(id)
  let tree = if idx >= 0: shell.windows.windows[idx].layout.tree else: nil
  for slot in arrangement.slots:
    var leaf = GpuiLeaf(slot: slot, paneId: slot.pane)
    if slot.contributed:
      # PLAT-9's three-way classification, THROUGH `layout_model.classify` —
      # the model's own function, which its doc comment calls "THE ONE PLACE
      # `prUnloadedExtension` IS PRODUCED". Deciding it here instead would be a
      # second copy of the predicate (Verification-Harness-Traps §14), and the
      # first draft of this line got it wrong in exactly the way a second copy
      # does: it asked whether the pane was IN THE TREE, which is always true
      # for a pane the projection just placed, so `glkUnloadedExtension` was
      # unreachable. Being in the layout and being provided by a loaded
      # extension are different questions, and `classify` is the one that asks
      # the second.
      let node = if tree.isNil: nil else: tree.findContributed(slot.pane)
      let classified = classify(PaneRef(kind: prContributed, id: slot.pane),
                                loadedExtensions)
      leaf.kind = if classified.kind == prContributed: glkContributed
                  else: glkUnloadedExtension
      leaf.title = if node.isNil: "" else: node.title
    else:
      var found = false
      for k in PaneKind:
        if $k == slot.pane:
          leaf.kind = glkBuiltin
          leaf.builtin = k
          found = true
          break
      if not found:
        leaf.kind = glkUnloadedExtension
      elif not session.isNil:
        leaf.vm = session.paneViewModel(leaf.builtin)
      if not tree.isNil:
        let node = tree.find(leaf.builtin)
        if not node.isNil:
          leaf.title = node.title
    result.leaves.add leaf

# ---------------------------------------------------------------------------
# Persistence — the SAME document the terminal front-end writes
# ---------------------------------------------------------------------------

proc saveWindowLayout*(shell: GpuiShell; id: WindowId): JsonNode =
  ## One window's arrangement, as `layout_model.saveLayout` writes it.
  ##
  ## **THIS IS THE MODEL'S DOCUMENT AND NOT A DOCK DOCUMENT**, and that is
  ## PLAT-20's risk mitigation made concrete: *"the round-trip test is between
  ## front-ends, through the model. It cannot pass if the model is not
  ## authoritative."* A GPUI front-end that persisted `DockAreaState` would
  ## make the dock the source of truth, and the terminal could not read it.
  let idx = shell.windows.indexOf(id)
  if idx < 0:
    raiseShell("saveWindowLayout: no window " & $id)
  saveLayout(shell.windows.windows[idx].layout)

proc restoreWindowLayout*(shell: GpuiShell; id: WindowId;
                          doc: JsonNode): WindowSetOutcome =
  ## Adopt a document written by ANY front-end. Raises `LayoutDecodeError` by
  ## kind on a document this build cannot read, exactly as the terminal's
  ## `restoreDocument` does, rather than falling back silently.
  let idx = shell.windows.indexOf(id)
  if idx < 0:
    raiseShell("restoreWindowLayout: no window " & $id)
  let restored = restoreLayoutDocument(doc)
  var next = shell.windows.clone()
  next.windows[idx].layout = restored
  # `{}`: the shell declares no owned-pane set (`validate`'s `owned` has no
  # default, so the vacuous answer is spelled rather than inherited).
  let problems = next.validate({})
  if problems.len > 0:
    # The FIRST problem, because `WindowSetOutcome` carries one — the same
    # shape `window_set`'s own refusals take. `validate` is still the thing
    # that found it, so a caller wanting all of them calls `validate` itself.
    return WindowSetOutcome(kind: wsRefused, problem: problems[0])
  shell.windows = next
  shell.syncSessionLayouts()
  WindowSetOutcome(kind: wsApplied, windows: next)

proc saveAllWindows*(shell: GpuiShell): JsonNode =
  ## The whole set, through `window_set.saveWindowSet`.
  saveWindowSet(shell.windows)

proc restoreAllWindows*(shell: GpuiShell; doc: JsonNode) =
  shell.windows = restoreWindowSet(doc)
  shell.syncSessionLayouts()
