## test_plat48_gpui_top_bar.nim — PLAT-48, GPUI's half, Tier 1: the top
## bar's pixel geometry and hit-test, the menu's popovers, the chords the
## menu shows (PLAT-68: the shared router's), and the TOP dock edge —
## projected, laid out as a strip, reachable by a drop.
##
## Pure functions over the shared ViewModels and the layout model; the window
## itself is exercised by the window record
## (`ci/test/plat48_gpui_window.py`, asserted by
## `test_plat48_gpui_window.nim`). No mocks.

import std/[json, options, strutils, tables, unittest]

import codetracer_embed
import headless_app/layout_model
import ../app/dock_projection
import ../chrome
import ../window_geometry
import ../window_top_bar
import ../app/gpui_keys
import ../app/edit_arm   # `GpuiDelivery`

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 96
# 77 -> 96 (the Electron-parity caption bar): the bar's five tool buttons are
# segments too, so the three per-segment loops run 15 more times; +2 for the
# tool and separator counts, +1 for the area's top, +1 for the header join.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc menu(): MenuVM = newMenuVM(nativeFrontEndMenu("calc"))

suite "PLAT-48 GPUI: the top bar's geometry":

  test "a 1920-pixel window holds the menu button, every control, the omnibar field":
    # PLAT-49: the menu is ONE root button at every width, as the desktop's.
    let lay = gpuiTopBarLayout(menu(), newOmnibarVM(), @[], 1920)
    ck lay.segOf(gtMenuButton).rect.w == MenuButtonPx and lay.omnibarField
    var controls, tools = 0
    for s in lay.segs:
      if s.part == gtControl: inc controls
      if s.part == gtTool: inc tools
    ck controls == TransportControls.len
    # The desktop's caption bar also holds its tool buttons (back, forward,
    # reset, run tests, stop), each after a separator, all of them at 1920.
    ck tools == ord(GToolButton.high) + 1
    ck lay.separators.len > 0
    # The desktop's caption bar spans the window from its top-left corner.
    ck lay.band == PxRect(x: 0, y: 0, w: 1920, h: TopBarPx)
    # Left to right, no overlap.
    for i in 1 ..< lay.segs.len:
      ck lay.segs[i].rect.x >= lay.segs[i - 1].rect.x + lay.segs[i - 1].rect.w

  test "a narrow window keeps the menu button and the controls by priority":
    let lay = gpuiTopBarLayout(menu(), newOmnibarVM(), @[], 320)
    ck lay.segOf(gtMenuButton).rect.w == MenuButtonPx
    var ids: seq[string] = @[]
    for s in lay.segs:
      if s.part == gtControl: ids.add TransportControls[s.index].id
    ck ids.len > 0 and ids.len < TransportControls.len
    var k = 0
    for id in TextPriority:
      if id in ids: inc k
      else: break
    ck k == ids.len

  test "the hit-test answers what is drawn":
    let lay = gpuiTopBarLayout(menu(), newOmnibarVM(), @[], 1920)
    for s in lay.segs:
      let hit = lay.topBarHitAt(s.rect.x + s.rect.w div 2,
                                s.rect.y + s.rect.h div 2)
      ck hit.part == s.part and hit.index == s.index
    ck lay.topBarHitAt(5, 5).rect.w == 0

  test "the session tabs' keys are the router's CUA rows (Ctrl+PageDown / PageUp)":
    # PLAT-68: the window resolves through the one router; GPUI's keystroke
    # decoder spells the chord the CUA table binds.
    var router = initKeymapRouter(bkCua, GpuiDelivery)
    let facts = SessionFacts(product: pmDebug, editor: sourceViewFacts())
    let path = @[element(ekWindow, "window"), element(ekTab, "tab:1"),
                 pane("calltrace")]
    for (key, mods, op) in [("pagedown", @["control"], "session-tabs.next"),
                            ("pageup", @["control"], "session-tabs.previous")]:
      let res = router.route(facts, path, nmNormal,
                             canonicalKeyOfGpui(key, mods), 0)
      ck res.kind == erOperation and res.operation == op

  test "a pin button under a revealed pane is not drawn, and not pressable":
    let pin = PxRect(x: 100, y: 58, w: 24, h: 24)
    ck pinButtonShown(pin, [])
    # A bottom reveal, or a drop tint elsewhere, leaves it.
    ck pinButtonShown(pin, [PxRect(x: 12, y: 700, w: 1800, h: 300)])
    # A top reveal over it, or a drop tint / ghost label over it, hides it.
    ck not pinButtonShown(pin, [PxRect(x: 12, y: 50, w: 1800, h: 300)])
    ck not pinButtonShown(pin, [PxRect(x: 12, y: 700, w: 1800, h: 300),
                                PxRect(x: 90, y: 55, w: 200, h: 900)])
    # Touching edges are not an overlap; one shared pixel is.
    ck not PxRect(x: 0, y: 0, w: 10, h: 10).overlaps(PxRect(x: 10, y: 0, w: 5, h: 5))
    ck PxRect(x: 0, y: 0, w: 10, h: 10).overlaps(PxRect(x: 9, y: 9, w: 5, h: 5))

  test "session tabs appear only with several sessions":
    let two = @[SessionTabView(title: "alpha", active: true),
                SessionTabView(title: "beta", active: false)]
    let lay = gpuiTopBarLayout(menu(), newOmnibarVM(), two, 1920)
    var tabs = 0
    for s in lay.segs:
      if s.part == gtTab: inc tabs
    ck tabs == 2
    let one = gpuiTopBarLayout(menu(), newOmnibarVM(), two[0 .. 0], 1920)
    for s in one.segs:
      ck s.part != gtTab

suite "PLAT-48 GPUI: the menu's popovers":

  test "the first level drops below the button; a folder opens to its right":
    # PLAT-49: the desktop's cascade — the first level is a popover under the
    # root button, and every entered folder opens beside its parent.
    let vm = menu()
    let lay = gpuiTopBarLayout(vm, newOmnibarVM(), @[], 1920)
    vm.openFolder(3)                 # View
    var pops = gpuiMenuPopovers(vm, lay, 1920, 1080)
    ck pops.len == 2
    ck pops[0].rect.x == lay.segOf(gtMenuButton).rect.x
    ck pops[0].rect.y == lay.band.y + lay.band.h
    ck pops[1].rect.x == pops[0].rect.x + pops[0].rect.w
    # Walk to the Theme folder and enter it.
    vm.moveHighlight(-1)
    ck vm.enterFolder()
    pops = gpuiMenuPopovers(vm, lay, 1920, 1080)
    ck pops.len == 3
    ck pops[2].rect.x == pops[1].rect.x + pops[1].rect.w
    # A click inside names the item.
    let row = pops[2].rows[0]
    let (inside, path) = gpuiMenuHitAt(pops, vm, row.rect.x + 4, row.rect.y + 4)
    ck inside and path == vm.path & @[0]

  test "the omnibar's results list below its field":
    let ob = newOmnibarVM()
    ob.setIndex(@[OmnibarEntry(kind: omFile, label: "main.py"),
                  OmnibarEntry(kind: omFile, label: "calc.py")])
    ob.open("py")
    let lay = gpuiTopBarLayout(menu(), ob, @[], 1920)
    let pop = gpuiOmnibarPopover(ob, lay, 1080)
    ck pop.rows.len == 2
    ck pop.rect.x == lay.segOf(gtOmnibar).rect.x

suite "PLAT-68 GPUI: the window's menu shows the router's chords":

  test "each transport item's chord is the one that runs it from the window":
    let router = initKeymapRouter(bkCua, GpuiDelivery)
    let facts = SessionFacts(product: pmDebug, editor: sourceViewFacts())
    let path = @[element(ekWindow, "window"), element(ekTab, "tab:1"),
                 pane("calltrace")]
    proc chordOf(action: string): string =
      let (name, arg) = splitOperation(operationOfClientAction(action))
      router.chordFor(name, facts, path, nmNormal, arg)
    ck chordOf("forwardNext") == "F10"
    ck chordOf("reverseNext") == "Shift+F10"
    ck chordOf("forwardStep") == "F11"
    ck chordOf("forwardContinue") == "F8"
    let vm = menu()
    var chords = initTable[string, string]()
    for action in ["forwardNext", "forwardStep"]:
      chords[action] = chordOf(action)
    vm.setShortcuts(chords)
    ck vm.shortcutFor("forwardStep") == "F11"

suite "PLAT-48 GPUI: the TOP dock edge":

  test "a top-docked layout projects, lays out a top strip, and the top margin docks":
    var layout = initLayout(row([pane(paneEditor), pane(paneState),
                                 pane(paneCalltrace)]))
    let docked = layout.apply(cmdDock(paneState, leTop))
    ck docked.kind == loApplied
    let viewport = DockViewport(width: 1920, height: 1080, dockExtent: 300)
    let projection = projectDock(docked.layout, viewport)
    ck projection.status == dpsProjected
    let g = windowGeometryOf(docked.layout, projection.state, 1920, 1080,
                             GpuiTopBandPx)
    var top = -1
    for i, st in g.strips:
      if st.edge == leTop: top = i
    ck top >= 0
    ck g.strips[top].slots.len == 1 and g.strips[top].slots[0].pane == "state"
    # The strip sits above the tree, directly below the window's top bar
    # (the desktop's layout starts under its caption bar, no padding).
    ck g.area.y == GpuiTopBandPx
    ck g.strips[top].rect.y == GpuiTopBandPx
    ck g.inner.y > g.strips[top].rect.y + g.strips[top].rect.h - 1
    # A reveal from it is a third of the tree, against the top.
    let rr = g.revealRectOf(leTop)
    ck rr.y == g.inner.y and rr.h == g.inner.h div 3
    # PLAT-51: the margin above the layout area is constrained onto the
    # tree's edge (GoldenLayout's `constrainDragToContainer`) — no drop
    # docks; docking is the menus' and `:dock`'s, as on the desktop. Since
    # the panes have no frame inset (the desktop's GoldenLayout headers start
    # at the tree's top edge), the constrained point is ON the header's top
    # edge, which GoldenLayout's strict header test excludes: nothing is
    # found — and one pixel lower, in the header, the drop joins the pane.
    let above = g.pointerAt(g.area.x + 400, g.area.y - 2)
    ck above.isNone
    let header = g.pointerAt(g.area.x + 400, g.inner.y + 1)
    ck header.isSome and header.get.zone == dzCentre
    # Left of the tree, at its middle height: the ground's left band — a
    # split of the whole layout, not the left dock.
    let left = g.pointerAt(g.inner.x - 2, g.inner.y + g.inner.h div 2)
    ck left.isSome and left.get.zone == dzRootLeft

  test "a layout document with a TOP-docked pane, written as the terminal writes it, opens":
    var layout = initLayout(sharedDefaultLayout().tree,
                            sharedDefaultLayout().docked)
    let docked = layout.apply(cmdDock(paneCalltrace, leTop))
    ck docked.kind == loApplied
    let doc = saveLayout(docked.layout)
    let restored = restoreLayoutDocument(parseJson($doc))
    ck restored.dockedAt(leTop).len == 1
    let projection = projectDock(restored, DockViewport(width: 1920,
                                  height: 1080, dockExtent: 300))
    ck projection.status == dpsProjected
    # The footer's bottom dock is in the document; the top one is the
    # window's own.
    ck projection.state.hasKey("bottom_dock")
    ck not projection.state.hasKey("top_dock")

suite "PLAT-48 GPUI top bar: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
