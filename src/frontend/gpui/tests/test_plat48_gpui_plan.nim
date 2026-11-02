## test_plat48_gpui_plan.nim — PLAT-48, **what the GPUI window DRAWS for its
## top bar and its auto-hide panels, read out of the window's own render
## plan**.
##
## `test_plat48_gpui_top_bar.nim` grades the geometry and the decisions the
## drawing reads; `test_plat48_gpui_window.nim` asserts a committed record
## measured off a real window's pixels. Neither can be re-run per mutation:
## the first never runs `gpui/main.nim`'s drawing, the second needs a
## compositor. This suite runs the SHIPPED `build/bin/codetracer-gpui`
## (`just build-gpui`) with `--report-window-plan`: the window's own root
## builder (`paintWindowChrome`, the function `gpui_launch` calls) over a
## detached root, the events of `--window-ops` dispatched through the
## window's own pointer and key handlers, and the resulting shadow tree
## printed — the tree the shim paints. So a defect in the drawing (a wrong
## mark, a button painted over a popover or through a revealed pane, a hover
## label without its chord, a reveal that is not the pane) is visible here,
## on the real `calc` recording stepped by a real replay-server, without a
## window.
##
## Run (needs `just build-gpui`, the `calc` recording under
## `test-logs/tui-fixtures/`, `REPLAY_SERVER_BIN`, isonim-gpui's shim):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat48_gpui_plan.nim
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a
## real recording. A missing prerequisite fails by name.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles,
            unicode, unittest]
import ./gpui_child_env

import codetracer_embed
import headless_app/layout_model
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar
import gpui/app/dock_projection
import views/debug_control_marks
import styles/generated/design_tokens   # the bar buttons' ink (`ControlInk`)

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 243
    ## 222 -> 243 (M76, codetracer#843): the Debug menu's Stop and point
    ## items drawn enabled (+15), and Shift+F5 ending the session (+6).
    ## Measured.
    ## 216 -> 222 (2026-10-22, codetracer-pm issue 2026-10-08-gpui-pane-
    ## docked-at-start-has-no-element-so-its-label-hover-reveals-nothing):
    ## the top-edge case asserts that the label of a pane docked BEFORE the
    ## window opened previews it (+3) and docks it open (+3). Measured.
    ## 213 -> 216 (2026-10-17, arm GW4's re-grade): the popover case also
    ## focuses the Files pane and asserts its outline is painted under the
    ## first level (+3). Measured.
    ## 212 -> 213 (2026-10-17, the PLAT-48 mutation harness's GW9 re-aim):
    ## the Ctrl+O case also presses a pin under the revealed pane and asserts
    ## it docked nothing (+1). Measured.
    ## 203 -> 212 (the Electron-parity redesign, 2026-10-17), measured. The
    ## pins are icons in their tabs now, not buttons of their own: the cases
    ## that walked `data-ct-pin` walk the drawn pins (one check per pin under
    ## a popover / reveal / tint, by paint order) and read where they are
    ## from the window's geometry, checked against the drawn tabs (+1) and
    ## the drawn pin count (+1); the Ctrl+O, top-edge and pin cases each
    ## assert a non-empty pin / tab set first. The band also asserts the menu
    ## button's logo and place and the omnibox's magnifier.
    ## 203 -> 203 (PLAT-51 part B), net: the top-edge case docks by a layout
    ## command, since a drag no longer docks, and no longer asserts the reveal
    ## from that strip (a pane docked at start had no element — filed, and
    ## fixed 2026-10-22, above); the drop-tint case also asserts the smaller
    ## middle's join; the Ctrl+O case
    ## also reveals a pane from the LEFT strip over the strips there (+2).
    ## Measured.
    ## 179 -> 203 at the adversarial review of 2026-10-03: ONE case added
    ## (`PLAT35-F3`, the horizontal wheel), 24 assertions. The move is
    ## structural and is stated rather than bumped silently — this file
    ## carries a literal and the price of a literal is that every move has
    ## to be accounted for.
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1920
  H = 1080
  MenuLogoSvg = "src/public/resources/menu/ct_logo_dark.svg"
    ## The desktop's `#menu-logo-img`, which the root menu button draws.
  OmnibarGlassSvg = "src/public/resources/shared/input_empty_search_icon_dark.svg"
    ## The omnibox's magnifier (`ct-images-empty-search-icon`).
  TabPinSvg = "src/public/resources/menu/lm_pin_tab_dark.svg"
    ## A tab's pin icon (`LAYOUT_TAB_PIN_ICON_PATH`).

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

var drawnFiles: Table[string, string]
  ## Every file a reported plan's `img src` names, read as soon as the plan
  ## is: `--report-window-plan` leaves the marks' SVG files for its reader,
  ## and this reader removes them.

var lastPlanTrace = ""
  ## M76: the gesture trace (`CODETRACER_GPUI_GESTURE_TRACE=1`) of the last
  ## `windowPlan(…, trace = true)` run — what the window says it did.

proc windowPlan(ops: string; pre: seq[string] = @[]; trace = false): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc)
  let state = createTempDir("plat48-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  # Every other per-user location (trace index, config, caches) of the
  # spawned binary: its own, under this case's directory (common/ct_home).
  env["CODETRACER_HOME"] = state / "ct-home"
  if trace:
    env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add calc
  let errFile = genTempPath("plat48-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  lastPlanTrace = err
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  var dirs: seq[string] = @[]
  proc keep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and fileExists(src):
        drawnFiles[src] = readFile(src)
        if src.parentDir notin dirs: dirs.add src.parentDir
    for c in n{"children"}.getElems: keep(c)
  keep(result)
  for d in dirs:
    try: removeDir(d)
    except OSError: discard

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  ## Every node carrying `attribute`, in plan (paint) order.
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc px(n: JsonNode; style: string): int =
  let v = n{"styles"}{style}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc rectOf(n: JsonNode): PxRect =
  ## An absolutely placed element's rectangle, from its own styles.
  ## (The plan spells a box's size as the shim's `w` / `h`.)
  PxRect(x: n.px("left"), y: n.px("top"), w: n.px("w"), h: n.px("h"))

proc topIndex(plan: JsonNode; n: JsonNode): int =
  ## Where `n` is among the root's children — its paint order.
  for i, c in plan{"children"}.getElems:
    if c == n: return i
  -1

proc imgSrc(n: JsonNode): string =
  for c in n{"children"}.getElems:
    if c{"tag"}.getStr == "img": return c.attr("src")

proc markPaths(id: string): seq[string] =
  ## The `d` of every path of the DESKTOP'S mark for a control.
  let svg = svgMarkup(markFor(id))
  var at = 0
  while true:
    let i = svg.find("d=\"", at)
    if i < 0: break
    let j = svg.find('"', i + 3)
    result.add svg[i + 3 ..< j]
    at = j + 1

proc drawnPins(plan: JsonNode): seq[tuple[pane: string, root: int]] =
  ## Every pane whose tab draws the desktop's pin icon (`.lm_pin_tab`), with
  ## the root child (paint order) the tab is drawn in. Since the Electron
  ## parity redesign the pin is an icon INSIDE its tab, in the pane tree, not
  ## a button of its own over the tree.
  let pinSvg = readFile(repo / TabPinSvg)
  for i, c in plan{"children"}.getElems:
    for tab in c.nodesWith("data-ct-tab-pane"):
      var pinned = false
      proc look(n: JsonNode) =
        if n{"tag"}.getStr == "img" and
           drawnFiles.getOrDefault(n.attr("src")) == pinSvg:
          pinned = true
        for k in n{"children"}.getElems: look(k)
      look(tab)
      if pinned: result.add (pane: tab.attr("data-ct-tab-pane"), root: i)

proc tabPanes(plan: JsonNode): seq[string] =
  ## Every pane with a tab in the tree, in plan order.
  for t in plan.nodesWith("data-ct-tab-pane"):
    result.add t.attr("data-ct-tab-pane")

proc defaultGeometry(): WindowGeometry =
  ## The window's arrangement of the shared default at `W` x `H` — what the
  ## window lays its panes out from (`windowGeometryOf` under the top bar,
  ## over the shared default it opens with).
  let layout = initLayout(sharedDefaultLayout().tree,
                          sharedDefaultLayout().docked)
  let proj = projectDock(layout, DockViewport(width: W, height: H,
                                              dockExtent: 300))
  doAssert proj.status == dpsProjected
  windowGeometryOf(layout, proj.state, W, H, GpuiTopBandPx)

suite "PLAT-48: the GPUI window's top bar and auto-hide panels, as drawn":

  test "the band: the shared menu's root button, the desktop's nine marks, the omnibar":
    let plan = windowPlan("")
    let band = plan.nodesWith("data-ct-top-bar")
    var bandBox: JsonNode
    for b in band:
      if b.attr("data-ct-top-bar") == "band": bandBox = b
    ck not bandBox.isNil
    let br = bandBox.rectOf
    # The desktop's caption bar: the window's whole width from its top-left
    # corner, `TopBarPx` high.
    ck br == PxRect(x: 0, y: 0, w: W, h: TopBarPx)
    # Every part where the bar's own layout puts it (the one computation the
    # pointer reads too), with the "+" a recording window offers.
    let lay = gpuiTopBarLayout(newMenuVM(nativeFrontEndMenu("calc")),
                               newOmnibarVM(), @[], W, canAddTab = true)
    # PLAT-49: ONE root button, as the desktop's menu has; its folders are a
    # popover inside it (`test_plat49_gpui_plan`), never titles in the band.
    # Since the parity redesign it draws the desktop's logo where it drew "≡".
    let menuButton = plan.nodesWith("data-ct-menu-button")
    ck menuButton.len == 1
    ck menuButton.len == 1 and menuButton[0].textOf == "" and
       drawnFiles.getOrDefault(menuButton[0].imgSrc) ==
         readFile(repo / MenuLogoSvg)
    ck menuButton.len == 1 and menuButton[0].rectOf == lay.segOf(gtMenuButton).rect
    ck plan.nodesWith("data-ct-menu-title").len == 0
    # Nine controls, in the desktop toolbar's order, each drawing the
    # DESKTOP'S mark for itself — its own paths — in the ink its state takes.
    let ctl = plan.nodesWith("data-ct-control")
    ck ctl.len == TransportControls.len
    for i, c in ctl:
      let id = TransportControls[i].id
      checkpoint(id)
      ck c.attr("data-ct-control") == id
      ck c.attr("data-ct-enabled") == "true"
      let src = c.imgSrc
      ck src.len > 0 and src in drawnFiles
      let svg = drawnFiles.getOrDefault(src)
      ck svg.contains("data-mark=\"" & id & "\"")
      var all = true
      for d in markPaths(id):
        if not svg.contains("d=\"" & d & "\""): all = false
      ck all and markPaths(id).len > 0
      ck not svg.contains("currentColor")
      # The desktop's `ct-button-image-md-secondary` ink (#b4b4b4).
      ck svg.contains(DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark])
      let r = c.rectOf
      ck r == lay.segOf(gtControl, i).rect and r.y >= br.y and
         r.y + r.h <= br.y + br.h
    let omni = plan.nodesWith("data-ct-omnibar")
    ck omni.len == 1
    # The placeholder after the desktop's magnifier icon (no glyph since the
    # parity redesign).
    ck omni[0].textOf == OmnibarPlaceholder
    ck drawnFiles.getOrDefault(omni[0].imgSrc) == readFile(repo / OmnibarGlassSvg)

  test "the footer strip is the shared default's docked panes, in order":
    let plan = windowPlan("")
    let strips = plan.nodesWith("data-ct-dock-strip")
    ck strips.len == 1
    ck strips[0].attr("data-ct-dock-strip") == $leBottom
    var labels: seq[string] = @[]
    for s in strips[0].nodesWith("data-ct-dock-slot"):
      labels.add s.textOf
      ck s.attr("data-ct-tab-active") == "false"
    var want: seq[string] = @[]
    for d in sharedDefaultDocked(): want.add d.title
    ck labels == want

  test "an open menu's popover is drawn over every pane's pin button":
    let plan = windowPlan("menu:Debug")
    let pops = plan.nodesWith("data-ct-menu-popover")
    # The first level and, beside it, the Debug folder (PLAT-49's cascade).
    ck pops.len == 2
    let pop = pops[^1]
    let pr = pop.rectOf
    # The Debug folder's items, the chords the desktop binds beside them.
    let items = plan.nodesWith("data-ct-menu-item")
    ck items.len >= 8
    var stepOver = ""
    for it in items:
      if it.attr("data-ct-menu-item") == "Step Over": stepOver = it.textOf
    ck stepOver.contains("F10")
    ck pr.w > 0
    for it in items:
      ck plan.topIndex(it) > plan.topIndex(pops[0])
    # Paint order: a pin that a popover overlaps is painted BEFORE it (under
    # it), never over its rows. Since the parity redesign the pin is an icon
    # in its tab (`.lm_pin_tab`), drawn with the pane tree; where it is comes
    # from the window's geometry, checked first against the tabs the window
    # drew (each exactly as wide as the geometry says). The first level, under
    # the root button, lies over the Files pane's strip and its pins.
    let edit = windowPlan("menu:Edit")
    let g = defaultGeometry()
    var drawnWidths, geomWidths: seq[(string, int)] = @[]
    for t in edit.nodesWith("data-ct-tab-pane"):
      drawnWidths.add (t.attr("data-ct-tab-pane"), t.px("w"))
    var pinOf = initTable[string, PxRect]()
    for n in g.nodes:
      if n.kind == gnTabs:
        for k, pane in n.panes:
          geomWidths.add (pane, n.tabs[k].w)
          pinOf[pane] = n.pins[k]
    checkpoint("drawn tabs " & $drawnWidths & " geometry " & $geomWidths)
    ck drawnWidths == geomWidths
    let pins = edit.drawnPins()
    ck pins.len == geomWidths.len
    var overlapped = 0
    for p in edit.nodesWith("data-ct-menu-popover"):
      for (pane, root) in pins:
        if pinOf.getOrDefault(pane).overlaps(p.rectOf):
          inc overlapped
          checkpoint("pin " & pane & " under a popover")
          ck root < edit.topIndex(p)
    ck overlapped >= 1
    # NOR IS ANY OTHER PART OF THE WINDOW painted over it (PLAT-48 arm GW4,
    # re-graded 2026-10-17: with the pins in the pane tree, a popover moved
    # to the FRONT of the window's top elements still clears every pin, and
    # what it then falls under is the rest of the chrome). The Files pane is
    # focused first, so its focus outline is drawn over the pane the first
    # level opens over; the outline is painted BEFORE the popover.
    var filesBody: PxRect
    for n in g.nodes:
      if n.kind == gnTabs and $paneFileTree in n.panes: filesBody = n.body
    let fx = filesBody.x + filesBody.w div 2
    let fy = filesBody.y + filesBody.h div 2
    let focused = windowPlan("press:" & $fx & ":" & $fy & ",release:" & $fx &
                             ":" & $fy & ",menu:Edit")
    let first = focused.nodesWith("data-ct-menu-popover")
    let outlines = focused.nodesWith("data-ct-focus-outline")
    ck first.len >= 1 and outlines.len == 1
    if first.len >= 1 and outlines.len == 1:
      checkpoint("outline " & $outlines[0].rectOf & " popover " &
                 $first[0].rectOf)
      ck outlines[0].rectOf.overlaps(first[0].rectOf)
      ck focused.topIndex(outlines[0]) < focused.topIndex(first[0])

  test "a key walks the open menu: the highlight is drawn where the ViewModel has it":
    let plan = windowPlan("menu:Debug,key:down")
    var active: seq[string] = @[]
    for it in plan.nodesWith("data-ct-menu-item"):
      if it.attr("data-ct-menu-active") == "true":
        active.add it.attr("data-ct-menu-item")
    ck active == @["Debug", "Step Over"]

  test "the pointer on a control: its tooltip and the desktop's chord, below it":
    let plan = windowPlan("control:next")
    let labels = plan.nodesWith("data-ct-hover-label")
    ck labels.len == 1
    ck labels[0].textOf == "Next (F10)"
    var nx: JsonNode
    for c in plan.nodesWith("data-ct-control"):
      if c.attr("data-ct-control") == "next": nx = c
    ck labels[0].rectOf.y >= nx.rectOf.y + nx.rectOf.h
    ck plan.topIndex(labels[0]) == plan{"children"}.len - 1

  test "Ctrl+O reveals the first docked pane ITSELF over the tree, with Unpin":
    # PLAT-68: `Ctrl+O` is the Vim and Kakoune bases' reveal (§4.2's), so the
    # window runs under Vim here; under CUA the reveal is the strips' and the
    # palette's.
    let plan = windowPlan("key:o:control", @["--keymap=vim"])
    let rev = plan.nodesWith("data-ct-revealed")
    ck rev.len == 1
    ck rev[0].attr("data-ct-revealed") == $paneBuildOutput
    let rr = rev[0].rectOf
    ck rr.y + rr.h <= H and rr.w > W div 2
    # The pane's own leaf is inside the overlay.
    var panes: seq[string] = @[]
    for p in rev[0].nodesWith("data-ct-pane"): panes.add p.attr("data-ct-pane")
    ck panes == @[$paneBuildOutput]
    # The strip marks the revealed label as active, and only it.
    for s in plan.nodesWith("data-ct-dock-slot"):
      ck (s.attr("data-ct-tab-active") == "true") ==
         (s.attr("data-ct-dock-slot") == $paneBuildOutput)
    let unpin = plan.nodesWith("data-ct-unpin")
    ck unpin.len == 1
    ck unpin[0].textOf == "Unpin"
    let ur = unpin[0].rectOf
    ck ur.x >= rr.x and ur.x + ur.w <= rr.x + rr.w and ur.y >= rr.y
    # No pin is drawn through it: every pin is an icon in the pane tree,
    # painted before (under) the revealed pane.
    let pins = plan.drawnPins()
    ck pins.len > 0
    for (pane, root) in pins:
      checkpoint("pin " & pane)
      ck root < plan.topIndex(rev[0])
    # A pane revealed from the LEFT strip lies over the tree's left third —
    # over the strips there, whose pin buttons are not drawn through it.
    # (PLAT-51 part B: the top strip's reveal did this job while a drag
    # still docked; the top-edge case below now asserts that reveal itself.)
    let left = windowPlan("hover-label:state,wait:350",
                          @["--layout-ops=dock:state:left"])
    let lrev = left.nodesWith("data-ct-revealed")
    ck lrev.len == 1
    var over = 0
    let leftPins = left.drawnPins()
    if lrev.len == 1:
      for (_, root) in leftPins:
        if root > left.topIndex(lrev[0]): inc over
    ck leftPins.len > 0 and over == 0
    # Nor is a pin PRESSED through it (`pinButtonShown` gates the press as it
    # gated the old button's drawing): Files' pin lies under the left third,
    # and a press on it while State is revealed there docks nothing.
    let through = windowPlan("hover-label:state,wait:350,pin:fileTree",
                             @["--layout-ops=dock:state:left"])
    ck $paneFileTree in through.tabPanes()

  test "the pointer resting on a strip label reveals that pane; Esc hides it":
    # PLAT-49 part B (finding 9): as on the desktop, a HOVER previews the
    # pane as an overlay; a click docks it open (test_plat49_panes_gpui_plan).
    let plan = windowPlan("hover-label:problems,wait:350")
    let rev = plan.nodesWith("data-ct-revealed")
    ck rev.len == 1 and rev[0].attr("data-ct-revealed") == $paneProblems
    let hidden = windowPlan("hover-label:problems,wait:350,key:escape")
    ck hidden.nodesWith("data-ct-revealed").len == 0
    ck hidden.nodesWith("data-ct-unpin").len == 0

  test "the TOP edge: a pane docked there is a label on the top strip":
    # PLAT-51: since the drop zones are GoldenLayout's, a drag docks nothing
    # (a pointer past the layout is constrained onto its edge); the dock is
    # the menus' and `:dock`'s — here the layout command they issue.
    let dockTop = @["--layout-ops=dock:state:top"]
    let plan = windowPlan("", dockTop)
    var top: JsonNode
    for s in plan.nodesWith("data-ct-dock-strip"):
      if s.attr("data-ct-dock-strip") == $leTop: top = s
    ck not top.isNil
    var slots: seq[string] = @[]
    if not top.isNil:
      for s in top.nodesWith("data-ct-dock-slot"):
        slots.add s.attr("data-ct-dock-slot")
    ck slots == @[$paneState]
    # No pane box holds State any more: no tab of the tree is State's.
    ck plan.tabPanes().len > 0
    ck $paneState notin plan.tabPanes()
    # Its label previews it and docks it open, as every strip label does —
    # although the pane was docked BEFORE the window opened. The top strip is
    # the window's own (the dock document has no `top`), and until 2026-10-22
    # its pane got no element at start-up, so the hover previewed nothing
    # (codetracer-pm issue 2026-10-08-gpui-pane-docked-at-start-has-no-
    # element-so-its-label-hover-reveals-nothing.md).
    let hovered = windowPlan("hover-label:state,wait:350", dockTop)
    let rev = hovered.nodesWith("data-ct-revealed")
    ck rev.len == 1
    if rev.len == 1:
      ck rev[0].attr("data-ct-revealed") == $paneState
      var panes: seq[string] = @[]
      for p in rev[0].nodesWith("data-ct-pane"): panes.add p.attr("data-ct-pane")
      ck panes == @[$paneState]
    let opened = windowPlan("label:state", dockTop)
    let open = opened.nodesWith("data-ct-docked-open")
    ck open.len == 1
    if open.len == 1:
      ck open[0].attr("data-ct-docked-open") == $paneState
      var panes: seq[string] = @[]
      for p in open[0].nodesWith("data-ct-pane"): panes.add p.attr("data-ct-pane")
      ck panes == @[$paneState]

  test "a tab dragged over a pane: the drop tint covers its content, never a pin button":
    # PLAT-51: aimed at the pane's LEFT quarter — GoldenLayout's left segment,
    # a split, whose tint is half the content; its smaller middle joins, and
    # that tint is the strip where the tab would land (below).
    let plan = windowPlan("hold:state:editor:left")
    let tints = plan.nodesWith("data-ct-drop")
    ck tints.len == 1
    let tr = tints[0].rectOf
    ck tr.w > 0 and tr.h > 0
    # Every pin is in the pane tree, painted before (under) the tint.
    let pins = plan.drawnPins()
    for (pane, root) in pins:
      checkpoint("pin " & pane)
      ck root < plan.topIndex(tints[0])
    # The tint is the pane's CONTENT (PLAT-49: GoldenLayout highlights a
    # stack's content, below its header), so the editor's own pin, on its
    # strip — the top `TabStripPx` of the editor, which meets the layout's
    # top under the bar — is drawn and is not under the tint.
    var editorPin = false
    for (pane, _) in pins:
      if pane == $paneEditor:
        editorPin = true
    ck editorPin
    ck tr.y >= GpuiTopBandPx + TabStripPx
    # The middle: a join, highlighted on the editor's strip — above its
    # content, the height of a strip.
    let join = windowPlan("hold:state:editor")
    let jt = join.nodesWith("data-ct-drop")
    ck jt.len == 1
    if jt.len == 1:
      ck jt[0].rectOf.y + jt[0].rectOf.h <= tr.y and jt[0].rectOf.h < tr.h

  test "pin docks a pane to the footer; Unpin puts it back beside where it was":
    let pinned = windowPlan("pin:state")
    # In the FOOTER strip (the pin's edge), and in no other strip.
    var bottom, elsewhere: seq[string] = @[]
    for st in pinned.nodesWith("data-ct-dock-strip"):
      for s in st.nodesWith("data-ct-dock-slot"):
        if st.attr("data-ct-dock-strip") == $leBottom:
          bottom.add s.attr("data-ct-dock-slot")
        else:
          elsewhere.add s.attr("data-ct-dock-slot")
    ck $paneState in bottom
    ck elsewhere.len == 0
    # Out of the tree: no tab of it is State's.
    ck pinned.tabPanes().len > 0
    ck $paneState notin pinned.tabPanes()
    let back = windowPlan("pin:state,hover-label:state,wait:350,unpin")
    ck back.nodesWith("data-ct-revealed").len == 0
    var slots: seq[string] = @[]
    for s in back.nodesWith("data-ct-dock-slot"):
      slots.add s.attr("data-ct-dock-slot")
    ck $paneState notin slots
    # Back in its own stack, AT ITS OWN PLACE: the shared default's
    # "Variables | Scratchpad", not "Scratchpad | Variables" (the state
    # pane is the first tab, so it goes back in front of the tab that
    # followed it). Its tab reads "Variables" since the one-list Variables
    # pane (`9ae2786b7`, `pane_names.nim`).
    var tabs: seq[string] = @[]
    for t in back.nodesWith("data-ct-tabs"):
      let labels = t.attr("data-ct-tabs").split(',')
      if "Scratchpad" in labels: tabs = labels
    ck tabs == @["Variables", "Scratchpad"]

  test "PLAT35-F3: the horizontal wheel reaches the editor, and the clipped text arrives":
    # **WHY THIS CASE IS IN THIS FILE AND NOT IN
    # `test_plat35_editor_scrollbar.nim`.** That suite grades the DECISION and
    # the DRAWING — `leaves.editorHScrollOf` and the tree `renderEditor`
    # builds — and `PLAT35-F3`'s closure rested on one thing neither it nor
    # any other suite could see: the BINDING. The wheel arm
    # (`main.windowPointer`'s `gekWheel`), the clamp's caller
    # (`main.scrollEditorColumns`), the redraw (`main.redrawEditorRows`), the
    # pane width taken from the window's own geometry
    # (`main.syncEditorViewport`) and the scripted spelling
    # (`--window-ops=hwheel:<pane>:<columns>`) are all in `gpui/main.nim`,
    # which is COMPILED by `test_plat35_text_faces.nim` and was ASSERTED OVER
    # by nothing. This suite drives the shipped binary, so it is the one that
    # can.
    #
    # **AND THE PATH WAS BROKEN WHEN IT WAS ONLY ANNOUNCED.** Measured at the
    # adversarial review of 2026-10-03: `hwheel` was documented in `--help`
    # and had its arm in `runWindowOp`, and the argument parser's allow-list
    # did not carry it, so every `--window-ops=hwheel:…` answered
    # *"unknown event"* and exited 2. Nothing reddened, because nothing drove
    # it. That is the §7 shape — a capability that exists in every place
    # except the one that is used — and this case is what makes it impossible
    # again: `windowPlan` RAISES on a non-zero exit, so a `hwheel` the parser
    # refuses fails here by name.
    #
    # Nothing here re-derives the arithmetic. The widths come out of the
    # editor's own `data-ct-editor-scroll` stamp, and the text claim is the
    # DRAWN text at rest sliced by the offset the plan reports — two readings
    # of one tree rather than a model of it.
    let rest = windowPlan("")
    let metrics = rest.nodesWith("data-ct-editor-scroll")
    ck metrics.len == 1
    proc fieldOf(plan: JsonNode; key: string): int =
      ## One field of `leaves.scrollMetricText`'s `k=v;k=v` stamp.
      let stamp = plan.nodesWith("data-ct-editor-scroll")[0]
        .attr("data-ct-editor-scroll")
      for part in stamp.split(';'):
        let kv = part.split('=')
        if kv.len == 2 and kv[0] == key: return parseInt(kv[1])
      -1
    proc codeTextOf(n: JsonNode): string =
      ## A code column's text, without the inline value chips the desktop's
      ## flow draws over it (`data-ct-inline-values`, positioned past the
      ## line's end): they are not columns of the line.
      if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
      if n.has("data-ct-inline-values"): return ""
      for c in n{"children"}.getElems: result.add codeTextOf(c)
    proc codeByRow(plan: JsonNode): Table[int, string] =
      ## Every drawn row's CODE text, by line number.
      result = initTable[int, string]()
      for row in plan.nodesWith("data-ct-row"):
        var code = ""
        for col in row.nodesWith("data-ct-code-column"):
          code.add codeTextOf(col)
        result[parseInt(row.attr("data-ct-row"))] = code
    proc gutterRunsOf(plan: JsonNode): seq[string] =
      for lane in plan.nodesWith("data-ct-gutter-lane"):
        result.add textOf(lane)

    # THE FINDING'S OWN PREMISE, asserted rather than assumed: at this
    # viewport the drawn content does NOT fit, so there is something to
    # reach. A layout change that made the editor wide enough reddens here
    # instead of leaving the rest of this case vacuously true.
    let maxLeft = rest.fieldOf("maxLeftCols")
    ck maxLeft > 0
    ck rest.fieldOf("leftCols") == 0
    let tracks = rest.nodesWith("data-ct-editor-scrollbar")
    ck tracks.len == 1
    ck tracks[0].px("h") == 12
    ck tracks[0].px("padding_left") == 0

    let atRest = rest.codeByRow()
    ck atRest.len > 0
    var widestRow, widestCols = 0
    for line, code in atRest:
      if code.runeLen > widestCols:
        widestCols = code.runeLen
        widestRow = line
    ck widestCols > 0
    # THE STAMP AND THE DRAWN TEXT ARE THE SAME TREE's two readings: the
    # `codeCols` the editor published is the width of the widest row it
    # actually drew. A stamp computed from rows other than the drawn ones
    # fails here, and so does a stamp that is a constant.
    ck widestCols == rest.fieldOf("codeCols")

    # ONE COLUMN, then HALF WAY: the offset the plan reports is the offset
    # asked for, and the drawn text is the at-rest text with exactly that
    # many columns gone.
    for cols in [1, maxLeft div 2]:
      let moved = windowPlan("hwheel:editor:" & $cols)
      ck moved.fieldOf("leftCols") == cols
      ck moved.codeByRow()[widestRow] ==
         atRest[widestRow].runeSubstr(cols)

    # PAST THE END: clamped, the last column is INSIDE the pane, and the
    # thumb is flush against the track's right edge.
    let last = windowPlan("hwheel:editor:" & $(maxLeft + 100))
    ck last.fieldOf("leftCols") == maxLeft
    let tail = atRest[widestRow].runeSubstr(maxLeft)
    ck last.codeByRow()[widestRow] == tail
    ck tail.runeLen == widestCols - maxLeft
    let lastTrack = last.nodesWith("data-ct-editor-scrollbar")[0]
    let lastThumb = last.nodesWith("data-ct-editor-scrollbar-thumb")[0]
    ck lastTrack.px("padding_left") ==
       lastTrack.px("w") - lastThumb.px("w")
    ck lastTrack.px("padding_left") > 0
    # THE GUTTER DOES NOT TRAVEL WITH THE CODE, as the desktop's
    # line-number margin does not.
    ck gutterRunsOf(last) == gutterRunsOf(rest)
    ck gutterRunsOf(rest).len > 0

    # BEFORE THE START: clamped the other way, and the tree is the one at
    # rest rather than a shifted one.
    let before = windowPlan("hwheel:editor:-5")
    ck before.fieldOf("leftCols") == 0
    ck before.codeByRow()[widestRow] == atRest[widestRow]

    # AND IT IS AIMED AT A PANE. A wheel over another pane's centre does
    # not scroll the editor, so the arm is not "any horizontal wheel".
    let elsewhere = windowPlan("hwheel:state:" & $maxLeft)
    ck elsewhere.fieldOf("leftCols") == 0
    ck elsewhere.codeByRow()[widestRow] == atRest[widestRow]

  test "M76 (#843): the Debug menu draws Stop and every breakpoint and tracepoint item enabled":
    # An item's enabled state is the ink it is drawn in (`crWindowForeground`
    # enabled, `crTabInactiveForeground` disabled), read against two items
    # whose state M76 does not change: Step Over (performed) and Keyboard
    # Shortcuts (the undecided half of #843, still disabled).
    let plan = windowPlan("menu:Debug")
    var ink = initTable[string, string]()
    for it in plan.nodesWith("data-ct-menu-item"):
      ink[it.attr("data-ct-menu-item")] = it{"styles"}{"text_color"}.getStr
    let enabledInk = ink.getOrDefault("Step Over")
    let disabledInk = ink.getOrDefault("Keyboard Shortcuts")
    checkpoint("enabled ink " & enabledInk & ", disabled ink " & disabledInk)
    ck enabledInk.len > 0 and disabledInk.len > 0 and enabledInk != disabledInk
    for label in ["Stop", "Delete Breakpoint", "Delete All Breakpoints",
                  "Enable Breakpoint", "Enable All Breakpoints",
                  "Disable Breakpoint", "Disable All Breakpoints",
                  "Add a Tracepoint", "Delete Tracepoint", "Enable Tracepoint",
                  "Enable All Tracepoints", "Disable Tracepoint",
                  "Disable All Tracepoints", "Run All Tracepoints"]:
      checkpoint(label & ": " & ink.getOrDefault(label, "(not drawn)"))
      ck ink.getOrDefault(label) == enabledInk

  test "M76 (#843): Shift+F5 is Stop: the session tab gives way to an Edit tab and its replay ends":
    # The window's own key handler, CUA's `debugger.stop` row. What the plan
    # shows afterwards — no session tab, the toolbar's Stop unavailable — and
    # what the window says it did: `session_driver.endDebugSession` ended a
    # RUNNING replay (it answers "had already ended" otherwise).
    let plan = windowPlan("key:f5:shift", trace = true)
    checkpoint(lastPlanTrace)
    # The key reached the operation (CUA's row), and the operation ran.
    ck lastPlanTrace.contains("gesture operation debugger.stop")
    ck not lastPlanTrace.contains("is not available in this window")
    # The workspace is in Edit mode: the recording's folder shown as an
    # Edit tab.
    ck lastPlanTrace.contains("folder tab ")
    ck lastPlanTrace.contains("stop: stopped the debugging session")
    var stopTool = 0
    for b in plan.nodesWith("data-ct-tool"):
      if b.attr("data-ct-tool") == "stop":
        inc stopTool
        ck b.attr("data-ct-enabled") == "false"
    ck stopTool == 1

  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
