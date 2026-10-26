## test_plat69_gpui_chrome.nim — PLAT-69, **the GPUI top bar as the window's
## title bar, and the layout following the window's size**, read out of the
## window's own drawing with no compositor.
##
## Two tiers:
##
##   * the PURE layout (`window_top_bar.gpuiTopBarLayout`) with window buttons
##     on either side: where each button is, the width each side reserves,
##     the omnibar's centring in what is left, and that the buttons survive a
##     narrow window;
##   * the SHIPPED `build/bin/codetracer-gpui` (`just build-gpui`) with
##     `--report-window-plan`, the window's own root builder over a detached
##     root: with `--window-chrome` standing in for the frame a live window
##     reports, the drag strip, the `no-drag` parts, the window buttons with
##     their regions and icons, the maximize button's restore state, a
##     changed frame redrawn (`chrome:`), and a resize (`resize:`) laying the
##     window out exactly as opening it at that size does.
##
## What a real compositor does with all this — the window moved, resized,
## maximized and closed through it — is `ci/test/plat69_window_chrome.nim`,
## on GuiAssert's sway target.
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a
## real recording. A missing prerequisite fails by name.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import codetracer_embed
import gpui/chrome
import gpui/window_geometry
import gpui/window_top_bar

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 264
    ## 2026-10-17: 239 -> 264. The desktop's caption bar has more parts
    ## (history, reset, run-tests and stop tools beside the controls), and
    ## three cases check once per part (no window-button segment, no overlap
    ## in a narrow window, every part over the strip `no-drag`): +16. The
    ## omnibar case now asserts its centring at a wide window AND that it
    ## clears the controls at 1440 (+8), and the empty reserve is the bar's
    ## padding (+1).
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  W = 1440
  H = 900
  StripH = TopBarPx
    ## The drag strip spans the window's top to the band's bottom. Since
    ## 2026-10-17 the band is the desktop's caption bar, starting at the
    ## window's top-left corner (no `ChromePaddingPx` above it), so that is
    ## the band's own height.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

proc run(args: seq[string]; geometry = ""; state = ""): tuple[rc: int;
    output, err: string] =
  ## The shipped binary, in a private state directory.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc)
  let own = state.len == 0
  let dir = if own: createTempDir("plat69-gpui-", "") else: state
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = dir
  env["XDG_STATE_HOME"] = dir
  env["CODETRACER_HOME"] = dir / "ct-home"
  if geometry.len > 0: env["CODETRACER_GPUI_GEOMETRY_OUT"] = geometry
  let errFile = genTempPath("plat69-gpui-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  result.output = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()
  result.err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  if own: removeDir(dir)

proc windowPlan(chrome: string; ops = ""; width = W; height = H;
                geometry = ""; state = ""): JsonNode =
  var args = @["--report-window-plan", "--width=" & $width,
               "--height=" & $height]
  if chrome.len > 0: args.add "--window-chrome=" & chrome
  if ops.len > 0: args.add "--window-ops=" & ops
  args.add calc
  let r = run(args, geometry, state)
  if r.rc != 0:
    checkpoint("codetracer-gpui exited " & $r.rc & ": " & r.err)
    raise newException(IOError, "the window plan run failed (" & chrome &
                       " " & ops & ")")
  result = parseJson(r.output)
  # The plan names the icons' SVG files and leaves them for its reader.
  proc sweep(n: JsonNode) =
    if n{"tag"}.getStr == "img":
      let src = n{"attributes"}{"src"}.getStr
      if src.len > 0 and dirExists(src.parentDir):
        try: removeDir(src.parentDir)
        except OSError: discard
    for c in n{"children"}.getElems: sweep(c)
  sweep(result)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc nodesWith(plan: JsonNode; attribute: string; value = ""): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute) and
       (value.len == 0 or n.attr(attribute) == value):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc px(n: JsonNode; style: string): int =
  let v = n{"styles"}{style}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc rectOf(n: JsonNode): PxRect =
  PxRect(x: n.px("left"), y: n.px("top"), w: n.px("w"), h: n.px("h"))

proc topIndex(plan, n: JsonNode): int =
  for i, c in plan{"children"}.getElems:
    if c == n: return i
  -1

proc segNames(lay: GTopLayout): seq[string] =
  for s in lay.segs:
    if s.part == gtWindowButton: result.add $GWindowButton(s.index)

suite "PLAT-69: the top bar's layout with window buttons":

  let tabs: seq[SessionTabView] = @[]

  test "no buttons: the layout is exactly the one before PLAT-69":
    let plain = gpuiTopBarLayout(nil, nil, tabs, W, canAddTab = true)
    let none = gpuiTopBarLayout(nil, nil, tabs, W, canAddTab = true,
                                windowButtons = (@[], @[]))
    ck plain.segs == none.segs
    # The bar's own padding at an end with no window buttons (the desktop's
    # `#menu` `padding-left`), and the reserve for none says the same.
    ck plain.segOf(gtMenuButton).rect.x == plain.band.x + BarPadPx
    ck windowButtonsReservePx(0) == BarPadPx
    for s in plain.segs:
      ck s.part != gtWindowButton

  test "right-side buttons: after the tabs and the +, 24 px, touching, 5 from the end":
    let lay = gpuiTopBarLayout(nil, nil, tabs, W, canAddTab = true,
                               windowButtons = (@[], @[gwbMinimize, gwbMaximize,
                                                       gwbClose]))
    ck lay.segNames == @["minimize", "maximize", "close"]
    let band = lay.band
    let close = lay.segOf(gtWindowButton, ord(gwbClose)).rect
    let maxi = lay.segOf(gtWindowButton, ord(gwbMaximize)).rect
    let mini = lay.segOf(gtWindowButton, ord(gwbMinimize)).rect
    ck close.x + close.w == band.x + band.w - WindowButtonEdgePx
    ck maxi.x + maxi.w + WindowButtonGapPx == close.x
    ck mini.x + mini.w + WindowButtonGapPx == maxi.x
    for r in [close, maxi, mini]:
      ck (r.w, r.h) == (WindowButtonPx, WindowButtonPx)
      # On the bar's content row, one pixel down (`.window-menu`), all at
      # the same height.
      ck r.y == band.y + WindowButtonTopPx
    # The "+" ends before the reserve the buttons take.
    let add = lay.segOf(gtTabAdd).rect
    ck add.w > 0
    ck add.x + add.w <= band.x + band.w - windowButtonsReservePx(3)
    # The menu button is where it always was: right-side buttons do not
    # move it from the bar's own left padding.
    ck lay.segOf(gtMenuButton).rect.x == band.x + windowButtonsReservePx(0)

  test "left-side buttons: before the menu button, in the configured order":
    let lay = gpuiTopBarLayout(nil, nil, tabs, W, canAddTab = true,
                               windowButtons = (@[gwbClose, gwbMinimize,
                                                  gwbMaximize], @[]))
    ck lay.segNames == @["close", "minimize", "maximize"]
    let band = lay.band
    ck lay.segOf(gtWindowButton, ord(gwbClose)).rect.x ==
       band.x + WindowButtonEdgePx
    let menu = lay.segOf(gtMenuButton).rect
    ck menu.x == band.x + windowButtonsReservePx(3)
    # The last button ends BEFORE the menu button starts: a gap, not a
    # touch (the narrow-band `PartGapPx` this read was removed with the
    # fallback layout it belonged to).
    ck lay.segOf(gtWindowButton, ord(gwbMaximize)).rect.x + WindowButtonPx <
       menu.x

  test "the omnibar is centred in what the buttons leave of the band":
    # THE DESKTOP'S RULE (measured 2026-10-17): the omnibox's slot is centred
    # between the controls' start and the right end of what the window
    # buttons leave — two equal-share neighbours — but NEVER over the
    # controls. So the centring is observable only in a window wide enough
    # for the share to exceed the controls' width (1920 here); at 1440 the
    # controls push it, and what must hold is that it clears them.
    const Wide = 1920
    let plain = gpuiTopBarLayout(nil, nil, tabs, Wide)
    let right = gpuiTopBarLayout(nil, nil, tabs, Wide,
                                 windowButtons = (@[], @[gwbMinimize,
                                                         gwbMaximize, gwbClose]))
    let left = gpuiTopBarLayout(nil, nil, tabs, Wide,
                                windowButtons = (@[gwbClose], @[]))
    let both = gpuiTopBarLayout(nil, nil, tabs, Wide,
                                windowButtons = (@[gwbClose], @[gwbMinimize]))
    let o = plain.segOf(gtOmnibar).rect
    let band = plain.band
    # The slot is the field plus its inset, and it is the desktop's width.
    let slotW = o.w + OmnibarFieldInsetPx
    ck slotW == omnibarDesktopPx(Wide)
    proc centredIn(leftReserve, rightReserve: int): int =
      ## The field's x when its slot is centred between the menu part
      ## (menu button and its gap) and the right reserve's tab gap.
      let start = band.x + leftReserve + MenuButtonPx + 2 * MenuPartGapPx
      let stop = band.x + band.w - rightReserve - OmnibarTabGapPx
      start + (stop - start - slotW) div 2 + OmnibarFieldInsetPx
    ck o.x == centredIn(windowButtonsReservePx(0), windowButtonsReservePx(0))
    ck right.segOf(gtOmnibar).rect.x ==
       centredIn(windowButtonsReservePx(0), windowButtonsReservePx(3))
    ck left.segOf(gtOmnibar).rect.x ==
       centredIn(windowButtonsReservePx(1), windowButtonsReservePx(0))
    ck both.segOf(gtOmnibar).rect.x ==
       centredIn(windowButtonsReservePx(1), windowButtonsReservePx(1))
    ck right.segOf(gtOmnibar).rect.w == o.w
    # The buttons on one side move it: four layouts, three positions (the
    # reserve is fixed, so `left` and `both` differ only by the right side).
    ck o.x != right.segOf(gtOmnibar).rect.x
    ck o.x != left.segOf(gtOmnibar).rect.x
    ck left.segOf(gtOmnibar).rect.x != both.segOf(gtOmnibar).rect.x
    # At 1440 the controls would overlap a centred slot: it clears them.
    for lay in [gpuiTopBarLayout(nil, nil, tabs, W),
                gpuiTopBarLayout(nil, nil, tabs, W,
                                 windowButtons = (@[gwbClose], @[gwbMinimize]))]:
      var controlsEnd = 0
      for s in lay.segs:
        if s.part in {gtControl, gtTool}:
          controlsEnd = max(controlsEnd, s.rect.x + s.rect.w)
      ck controlsEnd > 0
      ck lay.segOf(gtOmnibar).rect.x - OmnibarFieldInsetPx ==
         controlsEnd + MenuPartGapPx

  test "a narrow window keeps its window buttons":
    let lay = gpuiTopBarLayout(nil, nil, tabs, 360, canAddTab = true,
                               windowButtons = (@[], @[gwbMinimize, gwbMaximize,
                                                       gwbClose]))
    ck lay.segNames == @["minimize", "maximize", "close"]
    for s in lay.segs:
      if s.part != gtWindowButton:
        for b in lay.segs:
          if b.part == gtWindowButton:
            ck not overlaps(s.rect, b.rect)

  test "a hit on a button answers the button":
    let lay = gpuiTopBarLayout(nil, nil, tabs, W,
                               windowButtons = (@[], @[gwbClose]))
    let r = lay.segOf(gtWindowButton, ord(gwbClose)).rect
    let hit = lay.topBarHitAt(r.x + 12, r.y + 12)
    ck hit.part == gtWindowButton
    ck hit.index == ord(gwbClose)

suite "PLAT-69: the window plan, where the platform draws the frame":

  test "server mode (the default): no drag strip, no window buttons, no regions":
    for chrome in ["", "server"]:
      let plan = windowPlan(chrome)
      ck plan.nodesWith("data-window-region").len == 0
      ck plan.nodesWith("data-ct-window-button").len == 0
      ck plan.nodesWith("data-ct-window-drag").len == 0
      # The band is still drawn, as before PLAT-69.
      ck plan.nodesWith("data-ct-top-bar", "band").len == 1

suite "PLAT-69: the window plan, where the top bar is the title bar":

  test "the drag strip: the window's width, its top to the band's bottom, under the band":
    let plan = windowPlan("client")
    let drags = plan.nodesWith("data-window-region", "drag")
    ck drags.len == 1
    let strip = drags[0]
    ck strip.rectOf == PxRect(x: 0, y: 0, w: W, h: StripH)
    ck strip.attr("data-ct-window-drag") == "title-bar"
    let band = plan.nodesWith("data-ct-top-bar", "band")[0]
    ck band.attr("data-window-region") == ""     # the band's space drags
    ck plan.topIndex(strip) >= 0
    ck plan.topIndex(strip) < plan.topIndex(band)

  test "every part and popover over the strip is no-drag":
    # The menu open, so its popover is drawn too.
    let plan = windowPlan("client", ops = "menu:Debug")
    let strip = plan.nodesWith("data-window-region", "drag")[0]
    var parts = 0
    for c in plan{"children"}.getElems:
      if plan.topIndex(c) <= plan.topIndex(strip): continue
      if c.attr("data-ct-top-bar") == "band": continue
      let r = c.attr("data-window-region")
      if c.attr("data-ct-window-button").len > 0:
        ck r == c.attr("data-ct-window-button")
      elif c{"styles"}{"position"}.getStr == "absolute":
        if r != "no-drag":
          checkpoint("not no-drag: " & $c{"attributes"})
        ck r == "no-drag"
        inc parts
    for name in ["data-ct-menu-button", "data-ct-control", "data-ct-omnibar",
                 "data-ct-session-tab-add", "data-ct-menu-popover"]:
      let found = plan.nodesWith(name)
      ck found.len > 0
      for n in found:
        ck n.attr("data-window-region") == "no-drag"
    ck parts >= 12

  test "the buttons: the platform default, right of the + , each its region":
    let geo = genTempPath("plat69-geometry-", ".json")
    defer: removeFile(geo)
    let plan = windowPlan("client", geometry = geo)
    let bs = plan.nodesWith("data-ct-window-button")
    var names: seq[string]
    for b in bs:
      names.add b.attr("data-ct-window-button")
      ck b.attr("data-window-region") == b.attr("data-ct-window-button")
      ck b.attr("data-ct-window-button-icon") == b.attr("data-ct-window-button")
      ck (b.rectOf.w, b.rectOf.h) == (WindowButtonPx, WindowButtonPx)
      ck b{"styles"}{"rounded"}.getStr == "12px"
      var img = false
      for c in b{"children"}.getElems:
        if c{"tag"}.getStr == "img":
          img = c.attr("src").endsWith("window-" &
                                       b.attr("data-ct-window-button") & ".svg")
      ck img
    ck names == @["minimize", "maximize", "close"]
    # Reported in the geometry, as every segment is, where they are drawn.
    let top = parseJson(readFile(geo))["topBar"]
    var reported: seq[string]
    for s in top["segs"]:
      if s["part"].getStr == "window-button":
        reported.add s["label"].getStr
        for b in bs:
          if b.attr("data-ct-window-button") == s["label"].getStr:
            let r = s["rect"]
            ck b.rectOf == PxRect(x: r[0].getInt, y: r[1].getInt,
                                  w: r[2].getInt, h: r[3].getInt)
    ck reported == names
    ck top["window"]["clientDecorated"].getBool
    ck top["window"]["drag"] == %*[0, 0, W, StripH]
    ck top["window"]["right"] == %*["minimize", "maximize", "close"]

  test "the desktop's layout puts them on its side, in its order":
    let plan = windowPlan("client+layout=close,minimize,maximize:")
    var xs: seq[(int, string)]
    for b in plan.nodesWith("data-ct-window-button"):
      xs.add (b.rectOf.x, b.attr("data-ct-window-button"))
    ck xs.len == 3
    ck xs[0] == (WindowButtonEdgePx, "close")   # the band starts at x = 0
    ck xs[1][1] == "minimize"
    ck xs[2][1] == "maximize"
    let menu = plan.nodesWith("data-ct-menu-button")[0]
    ck menu.rectOf.x > xs[2][0]

  test "an unsupported control has no button":
    let plan = windowPlan("client+no-minimize")
    var names: seq[string]
    for b in plan.nodesWith("data-ct-window-button"):
      names.add b.attr("data-ct-window-button")
    ck names == @["maximize", "close"]

  test "maximized: the maximize button restores, and shows it":
    let plan = windowPlan("client+maximized")
    let maxi = plan.nodesWith("data-ct-window-button", "maximize")
    ck maxi.len == 1
    ck maxi[0].attr("data-ct-window-button-icon") == "restore"
    ck maxi[0].attr("data-window-region") == "maximize"
    var src = ""
    for c in maxi[0]{"children"}.getElems:
      if c{"tag"}.getStr == "img": src = c.attr("src")
    ck src.endsWith("window-restore.svg")

  test "a frame that changes while the window is open is drawn again":
    # Restored -> maximized -> restored, and the layout moved to the left:
    # what the renderer's window-state callback reports.
    let geo = genTempPath("plat69-geometry-", ".json")
    defer: removeFile(geo)
    let plan = windowPlan("client", geometry = geo,
      ops = "chrome:client+maximized,chrome:client+layout=close;maximize:")
    var names: seq[string]
    for b in plan.nodesWith("data-ct-window-button"):
      names.add b.attr("data-ct-window-button")
      ck b.attr("data-ct-window-button-icon") == b.attr("data-ct-window-button")
      ck b.rectOf.x < W div 2
    ck names == @["close", "maximize"]
    let top = parseJson(readFile(geo))["topBar"]
    ck top["window"]["left"] == %*["close", "maximize"]
    ck top["window"]["right"] == %*[]
    ck not top["window"]["maximized"].getBool
    # And to server-side: everything of the title bar goes.
    let gone = windowPlan("client", ops = "chrome:server")
    ck gone.nodesWith("data-window-region").len == 0
    ck gone.nodesWith("data-ct-window-button").len == 0

  test "a press on a window button is the window's and nothing else's":
    let plan0 = windowPlan("client")
    let close = plan0.nodesWith("data-ct-window-button", "close")[0].rectOf
    # The press would land on nothing else; the menu stays closed, the
    # debugger stays where it is.
    let plan = windowPlan("client", ops = "press:" & $(close.x + 12) & ":" &
                                          $(close.y + 12))
    ck plan.nodesWith("data-ct-menu-popover").len == 0
    ck plan.nodesWith("data-ct-window-button").len == 3

suite "PLAT-69: the layout follows the window's size":

  proc geometryAfter(width, height: int; ops = ""): JsonNode =
    let geo = genTempPath("plat69-geometry-", ".json")
    defer: removeFile(geo)
    discard windowPlan("client", ops = ops, width = width, height = height,
                       geometry = geo)
    parseJson(readFile(geo))

  test "resized, the window is laid out as it would open at that size":
    for (w, h) in [(1600, 1000), (1100, 700), (1920, 1200)]:
      let opened = geometryAfter(w, h)
      let resized = geometryAfter(W, H, ops = "resize:" & $w & ":" & $h)
      checkpoint($w & "x" & $h)
      for key in ["area", "inner", "nodes", "dividers", "strips", "footer"]:
        if opened[key] != resized[key]:
          checkpoint(key & ": opened " & $opened[key] & " resized " &
                     $resized[key])
        ck opened[key] == resized[key]
      for key in ["band", "segs"]:
        ck opened["topBar"][key] == resized["topBar"][key]
      ck resized["topBar"]["window"]["content"] == %*[w, h]
      ck resized["topBar"]["window"]["drag"] == %*[0, 0, w, StripH]
      ck resized["footer"][2].getInt == w

  test "the open menu's popover follows the resize":
    let opened = geometryAfter(1100, 700, ops = "menu:Debug")
    let resized = geometryAfter(W, H, ops = "menu:Debug,resize:1100:700")
    ck opened["topBar"]["popovers"] == resized["topBar"]["popovers"]

  test "a resize remembers nothing":
    let state = createTempDir("plat69-state-", "")
    defer: removeDir(state)
    discard windowPlan("client", ops = "resize:1600:1000,resize:1200:800",
                       state = state)
    var written: seq[string]
    for f in walkDirRec(state):
      if "gpui-layout" in f.extractFilename: written.add f
    ck written.len == 0

suite "PLAT-69: the command line":

  test "--window-chrome is refused outside --report-window-plan, and when malformed":
    for args in [@["--window-chrome=client", calc],
                 @["--report-window-plan", "--window-chrome=frameless", calc],
                 @["--report-window-plan", "--window-chrome=client+layout=x", calc],
                 @["--report-window-plan", "--window-ops=chrome:bogus", calc],
                 @["--width=0", calc]]:
      let r = run(args)
      checkpoint($args & " -> " & $r.rc & " " & r.err)
      ck r.rc != 0
      ck r.err.len > 0

  test "the assertion count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
