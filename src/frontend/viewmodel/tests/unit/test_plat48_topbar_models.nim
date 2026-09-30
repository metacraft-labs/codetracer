## test_plat48_topbar_models.nim — PLAT-48, the shared half: the Menu,
## Omnibar and session-tab ViewModels, the debugger controls' four
## renderings, the shared default's footer docks, and the path rasteriser
## that draws the desktop's marks for the `graphics` icons.
##
## Every subject here is pure (values in, values out), on both backends
## (vm-unit and vm-unit-js). No mocks: the session-tab cases open real
## `HeadlessApp` slots over the SDK's own `MockBackendService`, which is the
## one stand-in — a transport that answers the DAP handshake — and it is not
## a mock of anything asserted here: the strip is a function of the slots,
## and the slots are real.

import std/[strutils, tables, unittest]

import codetracer_embed
import headless_app/headless_app
import headless_app/session_tabs
import ../../viewmodels/[menu_vm, product_menu, omnibar_vm, transport_icons]
import ../../views/debug_control_marks
import ../../../../common/terminal_graphics/[raster, path_raster]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 141

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc menuWith(): MenuVM =
  result = newMenuVM(nativeFrontEndMenu("calc"))

suite "the Menu ViewModel":

  test "the tree is the product's, with macOS entries hidden off macOS":
    let vm = menuWith()
    var titles: seq[string] = @[]
    for i in vm.root.visibleChildren():
      titles.add vm.root.children[i].label
    ck titles == @["File", "Edit", "View", "Build", "Reset", "Debug", "Help"]
    # The hidden macOS folder keeps its index: `File` is child 1, not 0.
    ck vm.root.children[0].hidden
    ck vm.root.children[1].label == "File"
    ck vm.pathOfAction("forwardNext").len == 2

  test "open, walk into a folder, back out, close — the keyboard's operations":
    let vm = menuWith()
    ck not vm.isOpen
    vm.open()
    ck vm.isOpen and vm.path.len == 0
    # The first SELECTABLE item: the hidden macOS folder is skipped.
    ck vm.highlight == 1
    vm.moveHighlight(1)            # Edit
    vm.moveHighlight(1)            # View
    ck vm.highlightedItem().label == "View"
    ck vm.enterFolder()
    ck vm.path == @[3]
    ck vm.highlightedItem().label == "Filesystem"
    vm.moveHighlight(-1)           # wraps to the last visible item
    ck vm.highlightedItem().label == "Theme"
    ck vm.enterFolder()            # the nested Theme folder
    ck vm.path == @[3, 14]
    ck vm.leaveFolder()
    ck vm.highlightedItem().label == "Theme"
    vm.escape()                    # leaves View
    ck vm.path.len == 0 and vm.highlightedItem().label == "View"
    vm.escape()                    # closes
    ck not vm.isOpen and vm.highlight == -1

  test "activating an item runs its action and closes; a folder is entered":
    let vm = menuWith()
    vm.openFolder(6)               # Debug
    ck vm.path == @[6]
    vm.moveHighlight(1)            # Step Over
    let a = vm.activate()
    ck a.ran and a.action == "forwardNext" and a.path == @[6, 1]
    ck not vm.isOpen
    vm.open()
    let b = vm.activate()          # File is a folder
    ck not b.ran and vm.path == @[1]

  test "a disabled item does nothing; setEnabled marks a front-end's gaps":
    let vm = menuWith()
    vm.setEnabled(proc(action: string): bool = action.startsWith("forward"))
    vm.openFolder(1)               # File: nothing there is forward*
    let a = vm.activate()
    ck not a.ran and vm.isOpen
    vm.openFolder(6)
    let b = vm.activate()          # Continue
    ck b.ran and b.action == "forwardContinue"

  test "type-to-select finds by prefix, and the same letter cycles":
    let vm = menuWith()
    vm.openFolder(3)               # View
    vm.typeToSelect("s", 1000)
    ck vm.highlightedItem().label == "State"
    vm.typeToSelect("s", 1100)
    ck vm.highlightedItem().label == "Scratchpad"
    vm.typeToSelect("t", 5000)     # a pause: a new prefix, searched on
    ck vm.highlightedItem().label == "Theme"   # from the highlight

  test "pointer: hover opens folders and highlights items; click runs":
    let vm = menuWith()
    vm.open(keyboard = false)
    vm.hoverPath(@[6])
    ck vm.path == @[6] and not vm.keyNavigation
    vm.hoverPath(@[6, 2])
    ck vm.path == @[6] and vm.highlight == 2
    ck vm.isOnPath(@[6]) and vm.isOnPath(@[6, 2]) and not vm.isOnPath(@[6, 3])
    let a = vm.clickPath(@[6, 2])
    ck a.ran and a.action == "forwardStep" and not vm.isOpen

  test "the shortcut shown is the active keymap's, and switching changes it":
    let vm = menuWith()
    vm.setShortcuts({"forwardNext": "F10"}.toTable)
    vm.openFolder(6)
    let before = vm.openLevels()[1].items[1]
    ck before.label == "Step Over" and before.shortcut == "F10"
    vm.setShortcuts({"forwardNext": "Ctrl+n"}.toTable)
    ck vm.openLevels()[1].items[1].shortcut == "Ctrl+n"

  test "a menu bar's sibling step moves to the next top-level folder":
    let vm = menuWith()
    vm.openFolder(1)
    vm.siblingMenu(1)
    ck vm.path == @[2]
    vm.siblingMenu(-1)
    vm.siblingMenu(-1)             # wraps past the hidden macOS folder
    ck vm.path == @[vm.root.children.high]

  test "the menu's own search finds enabled items by label":
    let vm = menuWith()
    vm.open()
    vm.setSearch("reverse step")
    ck vm.searchLabels == @["Reverse Step Over", "Reverse Step In",
                            "Reverse Step Out"]
    vm.moveSearch(1)
    ck vm.activate().action == "reverseStep"

suite "the Omnibar ViewModel":

  test "the query decides the mode, the desktop's rule":
    ck classifyOmnibarQuery("main").mode == omFile
    ck classifyOmnibarQuery(":sym foo") == (omSymbol, "foo")
    ck classifyOmnibarQuery(":grep bar").mode == omProgram
    ck classifyOmnibarQuery(":step") == (omCommand, "step")
    ck classifyOmnibarQuery(":").mode == omFile
    ck classifyOmnibarQuery("/ai hi").mode == omAgent
    ck classifyOmnibarQuery("#1,420") == (omTick, "1420")
    ck classifyOmnibarQuery("#abc").mode == omFile
    ck desktopKindOf(omTick) == omFile

  test "results are ranked, and the order is total":
    let vm = newOmnibarVM()
    vm.setIndex(@[
      OmnibarEntry(kind: omFile, label: "src/main.py", target: "src/main.py"),
      OmnibarEntry(kind: omFile, label: "src/calc.py", target: "src/calc.py"),
      OmnibarEntry(kind: omFile, label: "tests/test_main.py"),
      OmnibarEntry(kind: omSymbol, label: "main", target: "src/main.py:1"),
      OmnibarEntry(kind: omSymbol, label: "compute_mean")])
    vm.open()
    vm.setQuery("mai")
    ck vm.mode == omFile
    ck vm.resultLabels() == @["src/main.py", "tests/test_main.py"]
    vm.setQuery(":sym mn")
    ck vm.resultLabels() == @["main", "compute_mean"]
    vm.moveSelection(1)
    let chosen = vm.accept()
    ck chosen.ok and chosen.entry.label == "compute_mean"
    ck not vm.isOpen

  test "a tick query answers the tick":
    let vm = newOmnibarVM()
    vm.open("#42")
    ck vm.results.len == 1 and vm.results[0].entry.target == "42"

  test "typing and backspace edit the query":
    let vm = newOmnibarVM()
    vm.open()
    vm.typeText(":s")
    vm.typeText("ym")
    ck vm.query == ":sym"
    vm.backspace()
    ck vm.query == ":sy"

suite "the debugger controls' renderings":

  test "every transport action has a control, in the toolbar's order":
    ck TransportControls.len == TransportActions.len
    for i, (id, label) in TransportActions:
      ck TransportControls[i].id == id and TransportControls[i].label == label

  test "nerd glyphs are Codicons, reverse actions included":
    ck TransportControls[controlIndex("next")].nerd == "\u{EAD6}"
    ck TransportControls[controlIndex("reverse-next")].nerd == "\u{EB8F}"
    ck TransportControls[controlIndex("reverse-continue")].nerd == "\u{EB8E}"
    ck TransportControls[controlIndex("continue")].nerd == "\u{EACF}"

  test "the four modes differ, and graphics draws no glyph":
    for c in TransportControls:
      ck c.glyphFor(imNerd) != c.glyphFor(imUnicode)
      ck c.glyphFor(imGraphics).len == 0
      ck c.glyphFor(imText) == c.text

  test "the default never assumes a font":
    ck defaultIconsMode(graphicsDrawn = true) == imGraphics
    ck defaultIconsMode(graphicsDrawn = false) == imUnicode
    ck nerdFontHint("1", "", "")
    ck not nerdFontHint("0", "", "")
    ck nerdFontHint("", "WezTerm", "")
    ck nerdFontHint("", "", "JetBrainsMono Nerd Font")
    ck not nerdFontHint("", "xterm", "DejaVu Sans Mono")

  test "text mode keeps exactly a priority prefix, in toolbar order":
    let all = textPrioritySubset(1000)
    ck all.len == TransportControls.len
    let narrow = textPrioritySubset(22)
    # Continue (10) + gap + Next (6) + gap + In (4) = 22.
    var ids: seq[string] = @[]
    for i in narrow: ids.add TransportControls[i].id
    ck ids == @["next", "step-in", "continue"]
    ck textPrioritySubset(0).len == 0

suite "the shared default's footer docks":

  test "the desktop's four footer panels, docked at the bottom, in order":
    let docked = sharedDefaultLayout().docked
    var panes: seq[PaneKind] = @[]
    var titles: seq[string] = @[]
    for d in docked:
      ck d.edge == leBottom
      panes.add d.pane
      titles.add d.title
    ck panes == @[paneBuildOutput, paneProblems, paneSearch, paneRequests]
    ck titles == @["BUILD", "PROBLEMS", "FIND IN FILES", "REQUESTS"]
    ck initLayout(sharedDefaultLayout().tree, docked).validate({}).len == 0

suite "session tabs over HeadlessApp's slots":

  test "activate, step, reorder and close":
    let app = newHeadlessApp()
    for t in ["one", "two", "three"]:
      discard app.openSession(newMockBackendService(autoRespond = true)
                                .toBackendService(), t)
    var titles: seq[string] = @[]
    for t in app.tabsOf(): titles.add t.title
    ck titles == @["one", "two", "three"]
    ck app.activeTabIndex() == 2
    ck app.stepTab(1)
    ck app.activeTabIndex() == 0
    ck app.moveTab(0, 2)
    titles = @[]
    for t in app.tabsOf(): titles.add t.title
    ck titles == @["two", "three", "one"]
    ck app.activeTabIndex() == 2      # the active session moved with its tab
    ck app.closeTab(0)
    ck app.tabsOf().len == 2
    ck scrollToShow(@[5, 5, 5, 5], 3, 10, 0) == 2
    app.dispose()

suite "the desktop's marks, rasterised":

  test "every control mark parses and draws ink inside its box":
    let ink = rgb(221, 221, 221)
    let ground = rgb(40, 40, 40)
    for m in ControlMarks:
      var shapes: seq[MarkShape] = @[]
      for s in m.shapes:
        shapes.add MarkShape(d: s.d, stroked: s.stroked,
                             strokeWidth: (if s.strokeWidth.len > 0:
                                             parseFloat(s.strokeWidth)
                                           else: 1.0),
                             roundCaps: s.linecap == "round")
      let img = rasterizeShapes(shapes, m.viewBox, 16, 16, ink, ground)
      let c = img.coverage(ground)
      ck c > 0.03 and c < 0.7

  test "continue and reverse-continue are each other's 180° rotation":
    let ink = rgb(255, 255, 255)
    let ground = rgb(0, 0, 0)
    proc drawOf(action: string): RgbaImage =
      let m = markFor(action)
      var shapes: seq[MarkShape] = @[]
      for s in m.shapes:
        shapes.add MarkShape(d: s.d, stroked: s.stroked,
                             strokeWidth: (if s.strokeWidth.len > 0:
                                             parseFloat(s.strokeWidth)
                                           else: 1.0),
                             roundCaps: s.linecap == "round")
      rasterizeShapes(shapes, m.viewBox, 32, 32, ink, ground)
    let a = drawOf("continue")
    let b = drawOf("reverse-continue")
    var diff = 0
    for y in 0 ..< 32:
      for x in 0 ..< 32:
        let pa = a.pixelAt(x, y)
        let pb = b.pixelAt(31 - x, 31 - y)
        diff += abs(int(pa.r) - int(pb.r))
    # Anti-aliasing differs by a sub-sample at most along the edges.
    ck diff < 32 * 32 * 12

  test "a filled square covers exactly its area":
    let img = rasterizeShapes([MarkShape(d: "M4 4H12V12H4Z")], "0 0 16 16",
                              16, 16, rgb(255, 255, 255), rgb(0, 0, 0))
    ck img.pixelAt(8, 8) == rgb(255, 255, 255)
    ck img.pixelAt(2, 2) == rgb(0, 0, 0)
    ck abs(img.coverage(rgb(0, 0, 0)) - 0.25) < 0.001

  test "relative commands, arcs and malformed data":
    let polys = parsePath("m1 1 l2 0 v2 h-2 z")
    ck polys.len == 1 and polys[0][^1] == (x: 1.0, y: 1.0)
    ck parsePath("M0 0A1 1 0 0 1 2 0").len == 1
    expect PathSyntaxError:
      discard parsePath("M0 0 L")
    ck parseHexRgb("#5a9dd4") == rgb(0x5a, 0x9d, 0xd4)

suite "PLAT-48 shared models: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
