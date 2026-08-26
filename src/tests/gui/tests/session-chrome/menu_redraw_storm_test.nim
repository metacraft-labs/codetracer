## menu_redraw_storm_test.nim
##
## Regression test for issue #555 — "Redraw issue on new file open"
## (milestone M9), where the caption-bar debug buttons blink on and off while
## a trace is being opened.
##
## What the bug actually was
## -------------------------
## `#isonim-debug-controls`, the host the IsoNim debug toolbar is mounted
## into, is emitted by the menu shell view itself
## (`viewmodel/views/isonim_menu_shell_view.nim`).  `renderMenuShellInto`
## starts with `clearChildren(container)`, so every full menu-shell render
## replaces that host with a fresh, empty node and destroys the mounted
## toolbar; `ui/debug.nim`'s `requestDebugControlsRender` then mounts a new
## one.  Because `ui/menu.nim`'s `requestMenuRender` is reached from
## `renderer.sharedDirectRedraw` — that is, from *every* `data.redraw()` — and
## rebuilt the shell unconditionally, a single trace open tore the toolbar
## down and rebuilt it dozens of times.  A previously recorded measurement put
## it at 45 mounts on one clean open.
##
## What this test asserts
## ----------------------
## The mount COUNT, not merely that a toolbar renders.  A test asserting "the
## toolbar is present" passes just as happily while the storm rages, which is
## how the original milestone came to be marked complete without the bug being
## fixed.
##
## `redrawsWithoutGate` deliberately reproduces the pre-fix wiring so the
## simulation is shown to be capable of observing the storm; if that case ever
## stops reporting one mount per redraw, this file is no longer testing
## anything and must be repaired rather than trusted.
##
## No mocks beyond IsoNim's `MockRenderer`: the shell markup comes from the
## real production view and the two decisions under test come from the real
## production module (`ui/menu_render_gate.nim`), which `ui/menu.nim` and
## `ui/debug.nim` also call.  Only the browser DOM and the IPC-driven redraw
## schedule are stood in for, because neither exists on a headless backend.

import std/[strutils, tables, unittest]
import isonim/testing/mock_dom
import views/isonim_menu_shell_view
import ../../../../frontend/ui/menu_render_gate

proc findById(node: MockNode; id: string): MockNode =
  if node.isNil:
    return nil
  if node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if not found.isNil:
      return found
  nil

# ---------------------------------------------------------------------------
# Menu models
# ---------------------------------------------------------------------------

proc record(name: string; path: seq[int];
            kind: MenuNodeRecordKind = MenuRecordElement;
            shortcut = ""; enabled = true;
            children: seq[MenuNodeRecord] = @[]): MenuNodeRecord =
  MenuNodeRecord(
    kind: kind,
    name: name,
    shortcut: shortcut,
    enabled: enabled,
    iconClass: name.toLowerAscii,
    nameClass: "menu-element-" & name.toLowerAscii,
    nodeClass: "",
    path: path,
    nameWidth: name.len + 1,
    beforeNextSubGroup: false,
    children: children)

proc traceMenuModel(programName: string; launchConfigs: int = 0):
    MenuShellModel =
  ## Approximates what `ui/menu.nim`'s `buildMenuShellModel` produces during a
  ## trace open.  The two things that genuinely change over such an open are
  ## the program name baked into the menu by `data.webTechMenu` and the
  ## launch-config entries that arrive later over IPC.
  var runChildren = @[
    record("Run To Entry", @[1, 0], shortcut = "CTRL+E"),
    record("Restart " & programName, @[1, 1], shortcut = "CTRL+R")]
  for i in 0 ..< launchConfigs:
    runChildren.add record("Launch " & $i, @[1, 2 + i])

  MenuShellModel(
    showNavigation: true,
    active: false,
    searchQuery: "",
    rootNodes: @[
      record("File", @[0], kind = MenuRecordFolder, children = @[
        record("Open", @[0, 0], shortcut = "CTRL+O"),
        record("Close", @[0, 1], shortcut = "CTRL+W")]),
      record("Run", @[1], kind = MenuRecordFolder, children = runChildren)],
    searchResults: @[],
    nestedMenus: @[],
    showWindowMenu: true,
    maximized: false)

# ---------------------------------------------------------------------------
# A headless stand-in for the caption-chrome wiring
# ---------------------------------------------------------------------------

type
  MenuChromeSim = ref object
    ## Mirrors, step for step, what one `data.redraw()` does to the caption
    ## chrome: `ui/menu.nim`'s `requestMenuRender` followed by
    ## `ui/debug.nim`'s `requestDebugControlsRender`.
    gate: MenuRenderGate
    shell: MockNode           ## the current `#menu` subtree, nil before first render
    controlsMounted: bool     ## `ui/debug.nim`'s `isoNimDebugMounted`
    useGate: bool             ## false reproduces the pre-#555 behaviour
    owner: string             ## stands in for the per-session `MenuComponent`
    shellRenders: int
    controlMounts: int
    redraws: int

proc newMenuChromeSim(useGate = true): MenuChromeSim =
  MenuChromeSim(gate: MenuRenderGate(), useGate: useGate, owner: "session-0")

proc hostIntact(sim: MenuChromeSim): bool =
  ## What `requestMenuRender` checks against the live DOM: the `#menu` host
  ## still has content AND the debug-controls host is still in it.
  not sim.shell.isNil and sim.shell.children.len > 0 and
    not findById(sim.shell, "isonim-debug-controls").isNil

proc redraw(sim: MenuChromeSim; model: MenuShellModel;
            keyNavigation = false; owner = "session-0") =
  sim.redraws += 1

  # --- ui/menu.nim: requestMenuRender ---------------------------------------
  # The shell's callbacks close over the per-session `MenuComponent`, so a
  # change of owner has to invalidate the cache even when the menu looks
  # identical.
  if owner != sim.owner:
    sim.gate.invalidate()
    sim.owner = owner

  let signature = menuRenderSignature(model, extra = $keyNavigation)
  let render =
    if sim.useGate: sim.gate.shouldRender(signature, sim.hostIntact)
    else: true
  if render:
    # `renderMenuShellInto` clears the host and rebuilds the subtree, so the
    # `#isonim-debug-controls` node the toolbar was mounted into is gone and
    # a fresh empty one takes its place. Replacing `sim.shell` models exactly
    # that loss of node identity.
    let r = MockRenderer()
    sim.shell = renderMenuShell(r, model)
    sim.shellRenders += 1
    sim.gate.noteRendered(signature)

  # --- ui/debug.nim: requestDebugControlsRender ------------------------------
  let host = findById(sim.shell, "isonim-debug-controls")
  if host.isNil:
    return
  if shouldRemountDebugControls(sim.controlsMounted, host.children.len > 0):
    let r = MockRenderer()
    let toolbar = r.createElement("div")
    r.setAttribute(toolbar, "class", "isonim-debug-controls")
    r.appendChild(host, toolbar)
    sim.controlsMounted = true
    sim.controlMounts += 1

suite "issue #555 — menu redraw storm tears down the debug toolbar":

  test "the pre-fix wiring rebuilds the toolbar on every single redraw":
    # Guards the guard: proves the simulation below can actually observe the
    # storm, so a passing `controlMounts == 1` means something.
    let sim = newMenuChromeSim(useGate = false)
    let model = traceMenuModel("hello")
    for _ in 0 ..< 45:
      sim.redraw(model)

    check sim.redraws == 45
    check sim.shellRenders == 45
    check sim.controlMounts == 45

  test "a burst of redraws with an unchanged menu mounts the toolbar once":
    let sim = newMenuChromeSim()
    let model = traceMenuModel("hello")
    for _ in 0 ..< 45:
      sim.redraw(model)

    check sim.redraws == 45
    check sim.shellRenders == 1
    check sim.controlMounts == 1

  test "a whole trace open stays within a small mount bound":
    # The redraw schedule of a real open: a long tail of redraws around three
    # points at which the menu genuinely changes — the menu tree appearing,
    # the program name being baked in, and the launch configs arriving.
    let sim = newMenuChromeSim()
    let empty = MenuShellModel(showNavigation: false, showWindowMenu: true)

    for _ in 0 ..< 5:
      sim.redraw(empty)
    for _ in 0 ..< 15:
      sim.redraw(traceMenuModel("CodeTracer"))
    for _ in 0 ..< 15:
      sim.redraw(traceMenuModel("hello"))
    for _ in 0 ..< 15:
      sim.redraw(traceMenuModel("hello", launchConfigs = 2))

    check sim.redraws == 50
    # One mount per genuine menu change, and nothing else.
    check sim.shellRenders == 4
    check sim.controlMounts == 4

  test "a genuine menu change still re-renders and re-mounts":
    let sim = newMenuChromeSim()
    sim.redraw(traceMenuModel("hello"))
    check sim.shellRenders == 1

    sim.redraw(traceMenuModel("hello"))
    check sim.shellRenders == 1

    sim.redraw(traceMenuModel("hello", launchConfigs = 1))
    check sim.shellRenders == 2
    check sim.controlMounts == 2

  test "opening the menu re-renders even though the tree is unchanged":
    let sim = newMenuChromeSim()
    var model = traceMenuModel("hello")
    sim.redraw(model)
    model.active = true
    sim.redraw(model)
    check sim.shellRenders == 2

  test "keyboard navigation state is part of the render signature":
    let sim = newMenuChromeSim()
    let model = traceMenuModel("hello")
    sim.redraw(model, keyNavigation = false)
    sim.redraw(model, keyNavigation = false)
    check sim.shellRenders == 1
    sim.redraw(model, keyNavigation = true)
    check sim.shellRenders == 2

  test "a session switch re-renders even with an identical menu":
    # `MenuComponent` is per ReplaySession and the shell's click handlers close
    # over it, so caching across a switch would leave the old session wired up.
    let sim = newMenuChromeSim()
    let model = traceMenuModel("hello")
    sim.redraw(model, owner = "session-0")
    sim.redraw(model, owner = "session-0")
    check sim.shellRenders == 1

    sim.redraw(model, owner = "session-1")
    check sim.shellRenders == 2
    sim.redraw(model, owner = "session-1")
    check sim.shellRenders == 2

  test "a host wiped behind our back is rebuilt despite an equal signature":
    # The cache may only be trusted while the DOM it describes survives.
    # Session switching and the welcome screen both empty `#menu`.
    let sim = newMenuChromeSim()
    let model = traceMenuModel("hello")
    sim.redraw(model)
    check sim.shellRenders == 1

    sim.shell.children.setLen(0)
    sim.redraw(model)
    check sim.shellRenders == 2
    check sim.controlMounts == 2

suite "issue #555 — render gate primitives":

  test "the signature separates fields that could otherwise run together":
    # Length prefixes, not delimiters: a menu entry may contain any character.
    let a = MenuShellModel(rootNodes: @[record("ab", @[0]), record("c", @[1])])
    let b = MenuShellModel(rootNodes: @[record("a", @[0]), record("bc", @[1])])
    check menuRenderSignature(a) != menuRenderSignature(b)

    let withColon = MenuShellModel(rootNodes: @[record("3:xyz", @[0])])
    let plain = MenuShellModel(rootNodes: @[record("xyz", @[0])])
    check menuRenderSignature(withColon) != menuRenderSignature(plain)

  test "the signature is stable for structurally identical models":
    # `data.webTechMenu` builds a brand-new node tree on every call, so the
    # gate cannot rely on object identity.
    check menuRenderSignature(traceMenuModel("hello")) ==
      menuRenderSignature(traceMenuModel("hello"))
    check menuRenderSignature(traceMenuModel("hello")) !=
      menuRenderSignature(traceMenuModel("world"))

  test "the signature covers nested submenus and search results":
    var withSearch = traceMenuModel("hello")
    let base = menuRenderSignature(withSearch)
    withSearch.searchResults = @[MenuSearchResultRecord(
      label: "Open", shortcut: "CTRL+O", iconClass: "open", active: true)]
    check menuRenderSignature(withSearch) != base

    var withNested = traceMenuModel("hello")
    withNested.nestedMenus = @[MenuNestedRecord(
      id: "menu-nested-elements-1",
      className: "menu-nested-elements",
      style: "top: 0px",
      nodes: @[record("Open", @[0, 0])])]
    check menuRenderSignature(withNested) != base

  test "a disabled entry is a different signature":
    var model = traceMenuModel("hello")
    let base = menuRenderSignature(model)
    model.rootNodes[0].children[0].enabled = false
    check menuRenderSignature(model) != base

  test "the first render is never skipped":
    let gate = MenuRenderGate()
    check gate.shouldRender("sig", hostIntact = true)

  test "an intact host with an equal signature is the only skip":
    var gate = MenuRenderGate()
    gate.noteRendered("sig")
    check not gate.shouldRender("sig", hostIntact = true)
    check gate.shouldRender("sig", hostIntact = false)
    check gate.shouldRender("other", hostIntact = true)

  test "invalidate forces the next render":
    var gate = MenuRenderGate()
    gate.noteRendered("sig")
    check not gate.shouldRender("sig", hostIntact = true)
    gate.invalidate()
    check gate.shouldRender("sig", hostIntact = true)

  test "the debug controls remount only when the host lost its children":
    check shouldRemountDebugControls(mounted = false, hostHasChildren = false)
    check shouldRemountDebugControls(mounted = false, hostHasChildren = true)
    # The case a menu-shell rebuild creates: flag still set, host emptied.
    check shouldRemountDebugControls(mounted = true, hostHasChildren = false)
    check not shouldRemountDebugControls(mounted = true, hostHasChildren = true)
