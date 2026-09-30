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

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles,
            unittest]

import codetracer_embed
import headless_app/layout_model
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar
import views/debug_control_marks

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 173
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1920
  H = 1080

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

var drawnFiles: Table[string, string]
  ## Every file a reported plan's `img src` names, read as soon as the plan
  ## is: `--report-window-plan` leaves the marks' SVG files for its reader,
  ## and this reader removes them.

proc windowPlan(ops: string): JsonNode =
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
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
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

suite "PLAT-48: the GPUI window's top bar and auto-hide panels, as drawn":

  test "the band: the shared menu's titles, the desktop's nine marks, the omnibar":
    let plan = windowPlan("")
    let band = plan.nodesWith("data-ct-top-bar")
    var bandBox: JsonNode
    for b in band:
      if b.attr("data-ct-top-bar") == "band": bandBox = b
    ck not bandBox.isNil
    let br = bandBox.rectOf
    ck br.x == ChromePaddingPx and br.y == ChromePaddingPx and br.h == TopBarPx
    # The titles are the shared tree's visible folders, in its order.
    let tree = nativeFrontEndMenu("calc")
    var want: seq[string] = @[]
    for i in tree.visibleChildren(): want.add tree.children[i].label
    var got: seq[string] = @[]
    for t in plan.nodesWith("data-ct-menu-title"):
      got.add t.attr("data-ct-menu-title")
      ck t.textOf == t.attr("data-ct-menu-title")
    ck got == want
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
      ck svg.contains(chromeOf(crTabActiveForeground))
      let r = c.rectOf
      ck r.y == br.y and r.h > 0 and r.x >= br.x
    let omni = plan.nodesWith("data-ct-omnibar")
    ck omni.len == 1
    ck omni[0].textOf.startsWith("⌕ Search files")

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
    ck pops.len == 1
    let pop = pops[0]
    let pr = pop.rectOf
    # The Debug folder's items, the chords the desktop binds beside them.
    let items = plan.nodesWith("data-ct-menu-item")
    ck items.len >= 8
    var stepOver = ""
    for it in items:
      if it.attr("data-ct-menu-item") == "Step Over": stepOver = it.textOf
    ck stepOver.contains("F10")
    # Paint order: a pin button that the popover overlaps is painted BEFORE
    # it (under it), never over its rows.
    var overlapped = 0
    for pin in plan.nodesWith("data-ct-pin"):
      if pin.rectOf.overlaps(pr):
        inc overlapped
        checkpoint("pin " & pin.attr("data-ct-pin") & " under the popover")
        ck plan.topIndex(pin) < plan.topIndex(pop)
    ck overlapped >= 1
    for it in items:
      ck plan.topIndex(it) > plan.topIndex(pop)

  test "a key walks the open menu: the highlight is drawn where the ViewModel has it":
    let plan = windowPlan("menu:Debug,key:down")
    var active: seq[string] = @[]
    for it in plan.nodesWith("data-ct-menu-item"):
      if it.attr("data-ct-menu-active") == "true":
        active.add it.attr("data-ct-menu-item")
    ck active == @["Step Over"]

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
    let plan = windowPlan("key:o:control")
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
    for pin in plan.nodesWith("data-ct-pin"):
      checkpoint("pin " & pin.attr("data-ct-pin"))
      ck not pin.rectOf.overlaps(rr)

  test "a click on a strip label reveals that pane; Esc hides it":
    let plan = windowPlan("label:problems")
    let rev = plan.nodesWith("data-ct-revealed")
    ck rev.len == 1 and rev[0].attr("data-ct-revealed") == $paneProblems
    let hidden = windowPlan("label:problems,key:escape")
    ck hidden.nodesWith("data-ct-revealed").len == 0
    ck hidden.nodesWith("data-ct-unpin").len == 0

  test "the TOP edge: a tab dragged to the top margin docks there and reveals from it":
    let plan = windowPlan("drag:state:top")
    var top: JsonNode
    for s in plan.nodesWith("data-ct-dock-strip"):
      if s.attr("data-ct-dock-strip") == $leTop: top = s
    ck not top.isNil
    var slots: seq[string] = @[]
    if not top.isNil:
      for s in top.nodesWith("data-ct-dock-slot"):
        slots.add s.attr("data-ct-dock-slot")
    ck slots == @[$paneState]
    # No pane box holds State any more.
    for pin in plan.nodesWith("data-ct-pin"):
      ck pin.attr("data-ct-pin") != $paneState
    let shown = windowPlan("drag:state:top,label:state")
    let rev = shown.nodesWith("data-ct-revealed")
    ck rev.len == 1 and rev[0].attr("data-ct-revealed") == $paneState
    let rr = rev[0].rectOf
    # From the top: the overlay starts below the band, above the middle.
    ck rr.y > ChromePaddingPx + TopBarPx and rr.y < H div 3
    # The tree's pin buttons do not show through it (they did: the three
    # panes under a top reveal painted their ⇲ over the revealed pane).
    var under = 0
    for pin in shown.nodesWith("data-ct-pin"):
      checkpoint("pin " & pin.attr("data-ct-pin"))
      ck not pin.rectOf.overlaps(rr)
      inc under
    ck under >= 1

  test "a tab dragged over a pane: the drop tint is drawn over that pane's pin button":
    let plan = windowPlan("hold:state:editor")
    let tints = plan.nodesWith("data-ct-drop")
    ck tints.len == 1
    let tr = tints[0].rectOf
    ck tr.w > 0 and tr.h > 0
    for pin in plan.nodesWith("data-ct-pin"):
      checkpoint("pin " & pin.attr("data-ct-pin"))
      ck not pin.rectOf.overlaps(tr)
    # The editor's own pin is the one the tint covers: it is not drawn.
    var editorPin = false
    for pin in plan.nodesWith("data-ct-pin"):
      if pin.attr("data-ct-pin") == $paneEditor: editorPin = true
    ck not editorPin

  test "pin docks a pane to the footer; Unpin puts it back beside where it was":
    let pinned = windowPlan("pin:state")
    var bottom: seq[string] = @[]
    for s in pinned.nodesWith("data-ct-dock-slot"):
      bottom.add s.attr("data-ct-dock-slot")
    ck $paneState in bottom
    for p in pinned.nodesWith("data-ct-pin"):
      ck p.attr("data-ct-pin") != $paneState
    let back = windowPlan("pin:state,label:state,unpin")
    ck back.nodesWith("data-ct-revealed").len == 0
    var slots: seq[string] = @[]
    for s in back.nodesWith("data-ct-dock-slot"):
      slots.add s.attr("data-ct-dock-slot")
    ck $paneState notin slots
    # Back in a pane box (a stack whose active tab it may not be): its tab
    # is drawn in the tree again, beside Scratchpad as in the shared default.
    var together = false
    for t in back.nodesWith("data-ct-tabs"):
      let labels = t.attr("data-ct-tabs").split(',')
      if "State" in labels and "Scratchpad" in labels: together = true
    ck together

  test "every assertion ran":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions
