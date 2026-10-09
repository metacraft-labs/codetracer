## test_plat49_panes_gpui_plan.nim — PLAT-49 part B, the GPUI window's half:
## the user's 2026-10-01 findings 7, 8, 9, 11 and 14 as the SHIPPED
## `codetracer-gpui` draws them, read from its `--report-window-plan` — the
## window's own root builder over a detached root, `--window-ops` events
## dispatched through its own pointer and key handlers — and its geometry
## file, on the real `calc` recording with a real `replay-server`.
##
##   8. CALL TRACE — each row is its `CallRow` parts (`data-call-part`), the
##      arguments in CALLTRACE_ARGS_COLOR and the return in
##      CALLTRACE_RETURN_COLOR, the current call selected; a press on a row
##      goes there (the tick moves), on its toggle collapses it.
##   9. FOOTER — the bottom labels are in the window's footer (its status
##      bar, full width, the position on its right); hovering a label
##      previews its pane only after the delay (`wait:<ms>` lets the time
##      pass), leaving closes it after the grace; a click docks it OPEN — a
##      band the tree gives up, no overlay — and a second click closes it.
##  11. DROP ZONES — the window's pixel hit-test answers GoldenLayout's
##      quarters over a pane's body, swept against the rule restated here; a
##      tab's left half inserts before it, its right half after it.
##  14. EVENT LOG — the table's columns are the ViewModel's: tick, #, kind,
##      output.
##   7. SESSION TABS — the band's tabs: each its own box with a gap, the
##      close control at its end, the agent's indicator and progress.
##
## No mocks: the shipped binary, a real recording, a real engine; the session
## tabs' layout is the pure `gpuiTopBarLayout` over `SessionTabView` values.

import std/[json, options, os, osproc, sets, streams, strtabs, strutils,
            tables, tempfiles, unittest]

import codetracer_embed
import headless_app/session_tabs
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar
import gpui/app/dock_projection
import styles/generated/design_tokens

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 139
    ## 128 -> 136 (2026-10-04): the call-trace cases find their rows by what
    ## the call is rather than by number (+5 in the first case: the row
    ## indices are asserted, and the selected row is checked to be the only
    ## one; +2 in the second: the two rows' places), and the collapse sweep
    ## visits one row more, because the recording now has one more call line
    ## (the Python recorder's `<toplevel>` root). 136 -> 137: the footer case
    ## reads the entry tick from the top bar before comparing the position.
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1920
  H = 1080
  RowPx = 26           # `leaves.CallRowPx`
  IndentPx = 16        # `leaves.CallIndentPx`
  ArgsColour = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
  ReturnColour = DesignTokenHex[dtColorsUiTextInformationOnColor][dmDark]

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc windowPlan(ops: string; geometry: var JsonNode;
                pre: seq[string] = @[]; subject = ""): JsonNode =
  ## The window's root after `ops`, as the shipped binary reports it, and the
  ## geometry file the window wrote (where it drew every pane, tab and part).
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc)
  let state = createTempDir("plat49b-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  let geomFile = state / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add (if subject.len > 0: subject else: calc)
  let errFile = genTempPath("plat49b-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  geometry = if fileExists(geomFile): parseFile(geomFile) else: newJNull()
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  # The marks' SVG files the plan names are left for its reader; drop them.
  proc sweep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and fileExists(src):
        try: removeDir(src.parentDir)
        except OSError: discard
    for c in n{"children"}.getElems: sweep(c)
  sweep(result)

proc windowPlan(ops: string): JsonNode =
  var g: JsonNode
  windowPlan(ops, g)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
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
  PxRect(x: n.px("left"), y: n.px("top"), w: n.px("w"), h: n.px("h"))

proc popover(plan: JsonNode; path: string): JsonNode =
  for p in plan.nodesWith("data-ct-menu-popover"):
    if p.attr("data-ct-menu-popover") == path:
      return p
  nil

proc item(plan: JsonNode; label: string): JsonNode =
  for it in plan.nodesWith("data-ct-menu-item"):
    if it.attr("data-ct-menu-item") == label:
      return it
  nil

proc centre(r: JsonNode): (int, int) =
  (r[0].getInt + r[2].getInt div 2, r[1].getInt + r[3].getInt div 2)


proc callRows(plan: JsonNode): seq[JsonNode] = plan.nodesWith("data-call-index")

proc callRow(plan: JsonNode; index: int): JsonNode =
  for r in plan.callRows:
    if r.attr("data-call-index") == $index: return r
  nil

proc callRowOf(plan: JsonNode; name, args: string): JsonNode =
  ## The call-trace row of the call named `name` called with `args` — found
  ## by WHAT the call is, not by its number, which depends on the frames the
  ## recorder wraps the program in (the Python recorder roots the trace in a
  ## `<toplevel>` call above the `<__main__>` module frame).
  for r in plan.callRows:
    let t = r.textOf
    if t.contains(" " & name & " #") and t.contains(args):
      return r
  nil

proc indexOf(row: JsonNode): int =
  if row.isNil: -1 else: parseInt(row.attr("data-call-index"))

proc part(row: JsonNode; kind: string): seq[JsonNode] =
  for c in row{"children"}.getElems:
    if c.attr("data-call-part") == kind: result.add c

proc calltraceBody(geom: JsonNode): seq[int] =
  for n in geom["nodes"]:
    if n{"kind"}.getStr == "tabs" and "calltrace" in n["panes"].to(seq[string]):
      return n["body"].to(seq[int])
  @[]

proc tickOf(geom: JsonNode): int = geom{"topBar"}{"tick"}.getInt(-1)

suite "PLAT-49 part B: the GPUI window's call trace":

  test "each row is its parts, in the desktop's colours; the current call selected":
    let plan = windowPlan("")
    let rows = plan.callRows
    ck rows.len >= 10
    let r2 = plan.callRowOf("evaluate", "(expression=\"2 + 3\")")
    let ev = r2.indexOf
    ck ev > 0
    ck r2.textOf == "▾ evaluate #" & $ev & "(expression=\"2 + 3\") => 5"
    ck r2.part("argName")[0].textOf == "expression"
    ck r2.part("argValue")[0].textOf == "\"2 + 3\""
    ck r2.part("argValue")[0].style("text_color").toLowerAscii ==
       ArgsColour.toLowerAscii
    ck r2.part("returnValue")[0].textOf == "5"
    ck r2.part("returnValue")[0].style("text_color").toLowerAscii ==
       ReturnColour.toLowerAscii
    ck r2.attr("data-call-toggle") == "expanded"
    let add = plan.callRowOf("add", "(left=2, right=3)")
    ck add.indexOf > ev
    ck add.attr("data-call-toggle") == "leaf"
    ck add.textOf.startsWith("· add #" & $add.indexOf & "(left=2, right=3)")
    let main = plan.callRowOf("main", "()")
    ck main.indexOf >= 0 and main.indexOf < ev
    ck main.textOf == "▾ main #" & $main.indexOf & "() => @[5, 7, 42, 17, 2]"
    # The trace's root is the first row, and it is a frame the recorder wraps
    # the program in — not a call the program made.
    ck plan.callRow(0).textOf.startsWith("▾ <")
    # The current call — the entry, at the module's top level, in a frame the
    # recorder wraps the program in — selected, on its ground; and only it.
    var selected: seq[JsonNode] = @[]
    for r in rows:
      if r.attr("data-call-selected") == "true": selected.add r
    ck selected.len == 1
    let sel = (if selected.len == 1: selected[0] else: plan.callRow(0))
    ck sel.indexOf < main.indexOf
    ck sel.textOf.startsWith("▾ <")
    ck r2.attr("data-call-selected") == "false"
    ck sel.style("bg").len > 0
    ck r2.style("bg").len == 0
    # The selected row's ground is the design system's active-row token
    # (ui/surface/primary/secondary-hover), and its toggle is drawn in the
    # body colour on it — the muted one is not legible there.
    ck sel.style("bg").toLowerAscii.startsWith(
      DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark].toLowerAscii)
    ck sel.part("toggle")[0].style("text_color").toLowerAscii ==
       DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark].toLowerAscii
    ck r2.part("toggle")[0].style("text_color").toLowerAscii ==
       DesignTokenHex[dtColorsUiTextPrimaryCaptionSubtle][dmDark].toLowerAscii

  test "a press on a row goes there; a press on its toggle collapses it":
    var geom: JsonNode
    discard windowPlan("", geom)
    let b = geom.calltraceBody
    ck b.len == 4
    # The entry stop's tick: the program's first step, after the `<toplevel>`
    # root's entry step (the trace format's step 0).
    let entryTick = geom.tickOf
    ck entryTick >= 0
    proc rowY(i: int): int = b[1] + ChromePaddingPx + i * RowPx + RowPx div 2
    # The first `add` and its `apply_op`, found by what they are. They are the
    # trace's first descent — every row above them is an ancestor, opened —
    # so a row's place on screen and its depth are both its index.
    let opened = windowPlan("")
    let addAt = opened.callRowOf("add", "(left=2, right=3)").indexOf
    let opAt = opened.callRowOf("apply_op", "(symbol=\"+\", left=2, right=3)").indexOf
    ck opAt > 0
    ck addAt == opAt + 1
    # `add`: its name, right of its toggle.
    let xa = b[0] + ChromePaddingPx + addAt * IndentPx + 40
    var g2: JsonNode
    let jumped = windowPlan("press:" & $xa & ":" & $rowY(addAt) & ",release:" &
                            $xa & ":" & $rowY(addAt), g2)
    checkpoint("tick after the jump " & $g2.tickOf)
    ck g2.tickOf > entryTick
    ck jumped.callRow(addAt).attr("data-call-selected") == "true"
    # `apply_op`: its toggle.
    let xt = b[0] + ChromePaddingPx + opAt * IndentPx + 4
    let collapsed = windowPlan("press:" & $xt & ":" & $rowY(opAt) & ",release:" &
                               $xt & ":" & $rowY(opAt))
    ck collapsed.callRow(opAt).attr("data-call-toggle") == "collapsed"
    ck collapsed.callRow(opAt).textOf.startsWith("▸ apply_op #" & $opAt & "(")
    # Its child `add` is gone; the rows below move up — and are renumbered,
    # as the desktop's are (`#N` is the row's place in the section).
    for r in collapsed.callRows:
      ck not r.textOf.contains("add #" & $addAt & "(left=2, right=3)")
    ck collapsed.callRow(addAt).textOf.startsWith("▾ evaluate #" & $addAt &
                                                  "(expression=\"10 - 4 + 1\")")

suite "PLAT-49 part B: the GPUI window's event log columns":

  test "the table's columns are the ViewModel's: tick, #, kind, output":
    let plan = windowPlan("")
    var headers: seq[string] = @[]
    for t in plan.nodesWith("data-view-kind"):
      if t.attr("data-view-id") == "eventLog":
        for th in t{"children"}[0]{"children"}.getElems:
          headers.add th.textOf
    ck headers == @["tick", "#", "kind", "output"]
    var rowTexts: seq[string] = @[]
    for t in plan.nodesWith("data-view-kind"):
      if t.attr("data-view-id") == "eventLog":
        rowTexts.add t.textOf
    ck rowTexts.len == 1
    ck rowTexts[0].contains("2 + 3 = 5")
    ck not rowTexts[0].contains("main.py:111")

  test "the omnibar's column command shows the location column":
    proc typed(text: string): string =
      for ch in text:
        result.add(if ch == ' ': ",key:space" else: ",key:" & $ch)
    let plan = windowPlan("key:p:control,key:colon" &
                          typed("hide column location") & ",key:enter")
    var headers: seq[string] = @[]
    for t in plan.nodesWith("data-view-kind"):
      if t.attr("data-view-id") == "eventLog":
        for th in t{"children"}[0]{"children"}.getElems:
          headers.add th.textOf
    checkpoint("headers " & $headers)
    ck headers == @["tick", "#", "location", "kind", "output"]
    var rowTexts = ""
    for t in plan.nodesWith("data-view-kind"):
      if t.attr("data-view-id") == "eventLog":
        rowTexts.add t.textOf
    ck rowTexts.contains("main.py:111")

suite "PLAT-49 part B: the GPUI window's footer auto-hide panels":

  test "the labels are in the footer, the window's status bar":
    var geom: JsonNode
    let plan = windowPlan("", geom)
    let f = geom["footer"].to(seq[int])
    ck f == @[0, H - FooterPx, W, FooterPx]
    var bottom: JsonNode
    for st in geom["strips"]:
      if st["edge"].getStr == "bottom": bottom = st
    ck not bottom.isNil
    for sl in bottom["slots"]:
      let r = sl["rect"].to(seq[int])
      ck r[1] == f[1] and r[1] + r[3] <= f[1] + f[3]
    let a = geom["area"].to(seq[int])
    ck a[1] + a[3] <= f[1]
    ck plan.nodesWith("data-ct-footer").len == 1
    # THE DESKTOP'S ORDER (review): the file info first — the language and
    # the encoding — and the labels after it.
    let info = plan.nodesWith("data-ct-footer-file-info")
    ck info.len == 1 and info[0].textOf == "Python | UTF-8"
    let firstLabel = bottom["slots"][0]["rect"].to(seq[int])
    ck info[0].rectOf.x < firstLabel[0]
    ck firstLabel[0] >= info[0].rectOf.x + info[0].rectOf.w
    let pos = plan.nodesWith("data-ct-footer-position")
    # The entry stop: line 1, at the tick the window's top bar reports.
    ck geom.tickOf >= 0
    ck pos.len == 1 and pos[0].textOf == "main.py:1  tick " & $geom.tickOf

  test "a hover previews after the delay; leaving closes it after the grace":
    var g: JsonNode
    discard windowPlan("hover-label:buildOutput", g)
    ck g["revealed"].kind == JNull
    discard windowPlan("hover-label:buildOutput,wait:250", g)
    ck g["revealed"].kind == JNull
    let shown = windowPlan("hover-label:buildOutput,wait:350", g)
    ck g["revealed"]{"pane"}.getStr == "buildOutput"
    ck shown.nodesWith("data-ct-revealed").len == 1
    discard windowPlan("hover-label:buildOutput,wait:350,move:900:300,wait:100",
                       g)
    ck g["revealed"]{"pane"}.getStr == "buildOutput"
    discard windowPlan("hover-label:buildOutput,wait:350,move:900:300,wait:350",
                       g)
    ck g["revealed"].kind == JNull

  test "a click docks the pane open — a band the tree gives up — and a second closes it":
    var g0, g1, g2: JsonNode
    discard windowPlan("", g0)
    let opened = windowPlan("label:buildOutput", g1)
    ck g1["openDock"]{"pane"}.getStr == "buildOutput"
    ck g1["revealed"].kind == JNull
    ck opened.nodesWith("data-ct-docked-open").len == 1
    ck opened.nodesWith("data-ct-revealed").len == 0
    let band = g1["openDock"]["rect"].to(seq[int])
    let inner0 = g0["inner"].to(seq[int])
    let inner1 = g1["inner"].to(seq[int])
    ck inner1[3] < inner0[3]
    ck inner1[1] + inner1[3] < band[1]
    ck band[1] + band[3] == inner0[1] + inner0[3]
    ck band[3] == inner0[3] * DockedOpenSharePercent div 100
    # The tree's panes all end above the band.
    for n in g1["nodes"]:
      let r = n["rect"].to(seq[int])
      ck r[1] + r[3] <= band[1]
    var lit = false
    for s in opened.nodesWith("data-ct-dock-slot"):
      if s.attr("data-ct-dock-slot") == "buildOutput":
        lit = s.attr("data-ct-tab-active") == "true"
    ck lit
    discard windowPlan("label:buildOutput,label:buildOutput", g2)
    ck g2["openDock"].kind == JNull
    ck g2["inner"].to(seq[int]) == inner0

suite "PLAT-49 part B: the GPUI window's drop zones are GoldenLayout's":

  proc oracle(b: PxRect; x, y: int): Option[DropZone] =
    ## GoldenLayout's body segments (`Stack.getArea` / `highlightDropZone`),
    ## RESTATED here (PLAT-51, Layout-ViewModel §4.2.2): left = the first
    ## quarter of the content's width, right = the last, both full height;
    ## between them top = the upper half, bottom = the lower — except the
    ## user's smaller middle (the centred third on both axes), which joins.
    ## GoldenLayout's tests are STRICT, so a pixel on a boundary is in no
    ## segment: `none`, and the sweep skips it.
    let (fx, fy) = (float(x - b.x) / float(b.w), float(y - b.y) / float(b.h))
    if fx <= 0.0 or fx >= 1.0 or fy <= 0.0 or fy >= 1.0:
      return none(DropZone)
    if fx < 0.25: return some(dzLeftEdge)
    if fx > 1.0 / 3.0 + 1e-9 and fx < 2.0 / 3.0 - 1e-9 and
       fy > 1.0 / 3.0 + 1e-9 and fy < 2.0 / 3.0 - 1e-9:
      return some(dzCentre)
    if fx > 0.25 and fx < 0.75 and fy < 0.5: return some(dzTopEdge)
    if fx > 0.75: return some(dzRightEdge)
    if fx > 0.25 and fx < 0.75 and fy > 0.5: return some(dzBottomEdge)
    none(DropZone)

  proc rootOracle(inner, stack: PxRect; x, y: int): Option[DropZone] =
    ## GoldenLayout's GROUND side areas, restated (`GroundItem
    ## .createSideAreas`: 50 px inside the layout along each edge) with
    ## `getArea`'s rule (the smallest area wins, the ground's on a tie).
    let d = 50
    var best = high(int)
    for (zone, r) in [(dzRootLeft, PxRect(x: inner.x, y: inner.y, w: d, h: inner.h)),
                      (dzRootRight, PxRect(x: inner.x + inner.w - d, y: inner.y,
                                           w: d, h: inner.h)),
                      (dzRootTop, PxRect(x: inner.x, y: inner.y, w: inner.w, h: d)),
                      (dzRootBottom, PxRect(x: inner.x, y: inner.y + inner.h - d,
                                            w: inner.w, h: d))]:
      if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h and
         r.w * r.h < best:
        best = r.w * r.h
        result = some(zone)
    if result.isSome and best > stack.w * stack.h:
      result = none(DropZone)

  test "a quarter on each side, the SMALLER centre joins; a tab's halves":
    let shared = sharedDefaultLayout()
    let layout = initLayout(shared.tree, shared.docked)
    let proj = projectDock(layout, DockViewport(width: W, height: H,
                                                dockExtent: DockStripPx))
    ck proj.status == dpsProjected
    let g = windowGeometryOf(layout, proj.state, W, H, GpuiTopBandPx)
    var swept = 0
    var wrong = 0
    var seen: HashSet[DropZone]
    for n in g.nodes:
      if n.kind != gnTabs: continue
      let b = n.body
      var y = b.y
      while y < b.y + b.h:
        var x = b.x
        while x < b.x + b.w:
          let p = g.pointerAt(x, y)
          if p.isSome:
            inc swept
            seen.incl p.get.zone
            let root = rootOracle(g.inner, n.rect, x, y)
            let want = if root.isSome: root
                       else: oracle(b, x, y)
            if want.isSome and p.get.zone != want.get:
              inc wrong
              if wrong <= 5:
                checkpoint("(" & $x & ", " & $y & ") in " & n.path & ": " &
                           $p.get.zone & ", GoldenLayout " & $want.get)
          x += 7
        y += 7
    ck wrong == 0
    ck swept > 1000
    # The quarters and the centre, and along the layout's outer edges the
    # root split (PLAT-49 part B review: GoldenLayout's ground bands).
    ck seen == toHashSet([dzLeftEdge, dzRightEdge, dzTopEdge, dzBottomEdge,
                          dzCentre, dzRootLeft, dzRootRight, dzRootTop,
                          dzRootBottom])
    ck g.rootBandOf(leRight).w == 50 and g.rootBandOf(leRight).h == g.inner.h
    # A stacked node's tab: its left half inserts before it, its right half
    # after it; the last tab's right half appends.
    for n in g.nodes:
      if n.kind == gnTabs and n.stacked and n.tabs.len >= 2:
        let t0 = n.tabs[0]
        let l = g.pointerAt(t0.x + 2, t0.y + t0.h div 2)
        let r = g.pointerAt(t0.x + t0.w - 3, t0.y + t0.h div 2)
        ck l.get.zone == dzTabStrip and r.get.zone == dzTabStrip
        ck l.get.path != r.get.path
        let tl = n.tabs[^1]
        ck g.pointerAt(tl.x + tl.w - 3, tl.y + tl.h div 2).get.zone == dzCentre
        break

suite "PLAT-49 part B: the GPUI band's session tabs":

  test "each tab its own box with a gap, the close control, the agent's progress":
    let agent = SessionTabAgent(present: true, running: true,
                                lifecycle: aslRunning, task: "Fix",
                                completed: 2, total: 5)
    let tabs = @[
      SessionTabView(title: "calc", active: true, label: "calc",
                     closable: true),
      SessionTabView(title: "agent", label: tabLabelOf("agent", agent),
                     closable: true, agent: agent)]
    let lay = gpuiTopBarLayout(newMenuVM(nativeFrontEndMenu("calc")),
                               newOmnibarVM(), tabs, W)
    let t0 = lay.segOf(gtTab, 0).rect
    let t1 = lay.segOf(gtTab, 1).rect
    ck t0.w > 0 and t1.w > 0
    ck t1.x == t0.x + t0.w + SessionTabGapPx
    let c1 = lay.segOf(gtTabClose, 1).rect
    ck c1.x + c1.w == t1.x + t1.w and c1.w == SessionTabClosePx
    ck lay.topBarHitAt(c1.x + 2, c1.y + 2).part == gtTabClose
    ck lay.topBarHitAt(t1.x + 4, t1.y + 4).part == gtTab
    ck sessionTabText(tabs[1]) == "⟳ agent 2/5"
    ck sessionTabText(tabs[0]) == "calc"

suite "PLAT-49 part B review: the GPUI band's + opens a recording in a new tab":

  proc typed(text: string): string =
    for ch in text:
      result.add ",key:" & $ch

  proc moves(fromRow, toRow: int): string =
    ## The arrow keys that walk the welcome screen's focus between two rows.
    for _ in 0 ..< abs(toRow - fromRow):
      result.add (if toRow > fromRow: ",key:down" else: ",key:up")

  test "the + with one session; a recording chosen opens beside it; a tab switches; a close stops it":
    let pages = repo / "test-logs/tui-fixtures/call_pages-d6745afd1e2e"
    if not dirExists(pages):
      raise newException(IOError, "prerequisite missing: " & pages)
    # One session: no tabs drawn (the desktop's `single-session`), the "+".
    let one = windowPlan("")
    ck one.nodesWith("data-ct-session-tab").len == 0
    let add = one.nodesWith("data-ct-session-tab-add")
    ck add.len == 1 and add[0].textOf == NewSessionTabGlyph
    ck add[0].attr("data-ct-session-tab-add") == NewSessionTabTitle
    # PLAT-51 (Multi-Window-Tab-Management.md rule 3): the "+" opens a tab
    # showing the WELCOME SCREEN — the recordings beside calc are its recent
    # traces, and "Open local trace" is one of its start options.
    var g: JsonNode
    let opened = windowPlan("tab-add", g)
    ck opened.nodesWith("data-ct-welcome").len == 1
    var rows: seq[string] = @[]
    var labels: seq[string] = @[]
    var focusAt = -1
    for n in opened.nodesWith("data-ct-welcome-row"):
      if n.attr("data-ct-welcome-focus") == "true": focusAt = rows.len
      rows.add n.attr("data-ct-welcome-row")
      labels.add n.textOf.strip
    checkpoint("rows: " & $rows)
    var pagesAt, calcAt, localAt = -1
    for i, k in rows:
      if k.startsWith("recent-trace:") and k.contains("call_pages-d6745afd1e2e"):
        pagesAt = i
      if k.startsWith("recent-trace:") and k.contains("calc-2f0db4f45192"):
        calcAt = i
      if k.startsWith("option:") and labels[i] == "Open local trace":
        localAt = i
    ck pagesAt >= 0 and calcAt >= 0 and localAt >= 0
    # The focus starts on the first live start option ("Open folder").
    ck rows[focusAt] == "option:open-folder"
    let toPages = moves(focusAt, pagesAt)
    let toLocal = moves(focusAt, localAt)
    # The recent recording, chosen: a second session, its own tab, its panes.
    let two = windowPlan("tab-add" & toPages & ",key:enter")
    var titles: seq[string] = @[]
    var active = ""
    for t in two.nodesWith("data-ct-session-tab"):
      titles.add t.attr("data-ct-session-tab")
      if t.attr("data-ct-tab-active") == "true": active = t.attr("data-ct-session-tab")
    ck titles == @["calc-2f0db4f45192", "call_pages-d6745afd1e2e"]
    ck active == "call_pages-d6745afd1e2e"
    ck two.nodesWith("data-ct-session-tab-close").len == 2
    ck two.nodesWith("data-ct-session-tab-add").len == 1
    let pagesRows = two.callRows.len
    ck pagesRows > one.callRows.len          # call_pages's trace is long
    # The same through "Open local trace" and a typed path.
    let typedOpen = windowPlan("tab-add" & toLocal & ",key:enter" &
                               typed(pages) & ",key:enter")
    ck typedOpen.callRows.len == pagesRows
    # The first tab: calc's panes again.
    let back = windowPlan("tab-add" & toPages & ",key:enter,tab:0")
    ck back.callRows.len == one.callRows.len
    let backEv = back.callRowOf("evaluate", "(expression=\"2 + 3\")")
    ck backEv.textOf == "▾ evaluate #" & $backEv.indexOf & "(expression=\"2 + 3\") => 5"
    # Closing the second tab: one session, no tabs, the "+" stays.
    let closed = windowPlan("tab-add" & toPages & ",key:enter,tab-close:1")
    ck closed.nodesWith("data-ct-session-tab").len == 0
    ck closed.nodesWith("data-ct-session-tab-add").len == 1
    ck closed.callRows.len == one.callRows.len
    # A folder that is not a recording opens nothing: the welcome tab stays,
    # and says why.
    let refused = windowPlan("tab-add" & toLocal & ",key:enter" &
                             typed("/no/such/recording") & ",key:enter")
    ck refused.nodesWith("data-ct-welcome").len == 1
    ck refused.nodesWith("data-ct-welcome-message").len == 1

suite "PLAT-49 part B GPUI: assertion count":
  test "every assertion ran":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
