## PLAT-69 — THE GPUI WINDOW IS A NORMAL DESKTOP WINDOW: its top bar is the
## title bar. GuiAssert scenarios on a REAL compositor.
##
##   bash ci/test/plat69-window-chrome.sh [<scenario>...]
##
## which builds nothing itself: it needs `build/bin/codetracer-gpui-window`
## (the GPUI front-end pinned to isonim-gpui's windowed shim, as
## `ci/test/gpui-window-captures.sh` builds it), the `calc` recording, a
## `replay-server`, and for the desktop half `src/build-debug/bin/ct` with its
## Electron bundle (`just build-once`). It runs this file in GuiAssert's dev
## shell, where the compositor and its session stack are pinned.
##
## THE SCENARIOS (each a suite; name one or more on the command line):
##
##   plat69-window-management  (client-side decorations)
##     the bar's empty space moves the window, a control and the menu button
##     do not; the right edge widens it and the next geometry report has the
##     top bar, the arrangement and the footer at the new width; maximize and
##     restore by the button and by a double-click, the icon swapping — where
##     the compositor maximizes at all; the supported buttons drawn and the
##     unsupported ones absent; close ends the process with status 0.
##   plat69-button-placement   (client-side decorations)
##     a right-side and a left-side `button-layout`, set while the window is
##     open, each put the buttons on that side in that order — read from the
##     window's report AND from the screen's pixels — and the close button
##     closes the window from wherever the layout put it.
##   plat69-initial-window
##     with no `window:` setting both front-ends (GPUI and the desktop) ask
##     to open maximized; with `initial: windowed` and a size both open at
##     exactly that size, as the compositor reports it; both report the app
##     id `codetracer`.
##   plat69-server-mode        (the compositor draws the frame)
##     no window buttons, no drag strip, and a drag on the bar moves nothing.
##
## THE TARGET is `PLAT69_TARGET`: `sway` (the default, GuiAssert's headless
## sway) or `gnome` (its headless GNOME Shell). The scenarios are written
## once; nothing below branches on which it is.
##
## WHAT DECIDES THE EXPECTATIONS. The target's facts, never its name: which
## buttons the compositor advertises (`window.capabilities`), whether it
## maximizes the window (`window.canMaximize`), whether it can draw the frame
## at all (`decorations.serverAvailable`), the configured `button-layout`.
## On sway client-side decorations are granted to floating windows only, so
## the app id floats there, and the window is asked for them
## (`ISONIM_GPUI_DECORATIONS=client`; GNOME leaves them to the app anyway).
##
## vacuity_guard: every client-side case first waits until the WINDOW reports
## client-side decorations in force (its geometry's `topBar.window`) and the
## target says it honours a client request. A compositor that kept drawing
## the frame would otherwise pass every "the window did not move" check.
##
## WHERE EACH READING COMES FROM. Where the window is and how big: the
## compositor (sway's IPC). What was drawn: the screen (`grim`). Where to
## aim, and what the window believes (its decoration mode, its buttons, the
## size it asked for): the window's own geometry report
## (`CODETRACER_GPUI_GEOMETRY_OUT`), labelled as the app's account wherever it
## is the evidence — only for what no compositor can report (a maximize
## request a compositor ignores).
##
## MOCKS: none. A real sway, the real windowed front-end on a real recording,
## a real pointer device, the real desktop front-end.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, times,
            unittest]
import gui_assert/desktop_env
import gui_assert/desktop_env/[gnome, sway]

const
  AppId = "codetracer"
    ## Both front-ends' app id (PLAT-69 C4): `resources/codetracer.desktop`.
  OutputW = 1600
  OutputH = 1000
  WinW = 1280
  WinH = 800
  Settle = 600   ## ms for "nothing happened" to have had its chance

proc need(name: string; file = false): string =
  result = getEnv(name)
  if result.len == 0 or (file and not fileExists(result) and
                         not dirExists(result)):
    quit("plat69_window_chrome: " & name & " is not set or names nothing " &
         "(run `bash ci/test/plat69-window-chrome.sh`)", 2)

let gpuiBin = need("PLAT69_GPUI_BIN", file = true)
let gpuiLibs = need("PLAT69_GPUI_LD_LIBRARY_PATH")
let trace = need("PLAT69_TRACE", file = true)
let replayServer = need("REPLAY_SERVER_BIN", file = true)
let outDir = need("PLAT69_OUT")
let repo = need("PLAT69_REPO", file = true)

var t: TargetEnvironment

# ---------------------------------------------------------------------------
# One front-end, launched into its own home
# ---------------------------------------------------------------------------

type Launched = object
  p: Process
  dir, geometryFile, log: string

proc shippedConfigWith(window: string): string =
  ## The shipped configuration, its `window:` entry replaced by `window`
  ## ("" drops it: a configuration from before the entry existed). A whole
  ## file, because the desktop reads every other key of it too.
  let shipped = readFile(repo / "src/config/default_config.yaml")
  var lines: seq[string]
  var skipping = false
  for line in shipped.splitLines():
    if line == "window:":
      skipping = true
      if window.len > 0: lines.add window.strip(leading = false)
      continue
    if skipping and line.startsWith("  "): continue
    skipping = false
    lines.add line
  lines.join("\n")

var shortHomes: seq[string]
  ## The desktop's homes, under /tmp (`home`), removed at the end.

proc home(config: string; short = false): string =
  ## A private `CODETRACER_HOME` (configuration, state, trace index) holding
  ## `config` as its `.config.yaml`, or no configuration at all. `short`: in
  ## /tmp, for the desktop, whose session manager listens on a unix socket
  ## under the home — and a socket path longer than `sun_path` (108 bytes)
  ## cannot be bound (measured: EINVAL under a 90-byte scratch directory,
  ## and the desktop waited for its session manager for ever).
  if short:
    result = createTempDir("p69-", "", "/tmp")
    shortHomes.add result
  else:
    result = createTempDir("case-", "", outDir)
  createDir(result / "home" / "config")
  createDir(result / "state")
  if config.len > 0:
    writeFile(result / "home" / "config" / ".config.yaml", config)

proc launchGpui(decorations = "client"; size = true; config = ""): Launched =
  result.dir = home(config)
  result.geometryFile = result.dir / "geometry.json"
  result.log = result.dir / "gpui.log"
  var args = @[gpuiBin, "--quit-after-ms=600000"]
  if size: args.add @["--width=" & $WinW, "--height=" & $WinH]
  args.add trace
  result.p = t.spawn(@["/bin/sh", "-c", "exec \"$0\" \"$@\" >" &
                       quoteShell(result.log) & " 2>&1"] & args,
    extraEnv = [("LD_LIBRARY_PATH", gpuiLibs),
                ("REPLAY_SERVER_BIN", replayServer),
                ("ISONIM_GPUI_DECORATIONS", decorations),
                ("CODETRACER_HOME", result.dir / "home"),
                ("XDG_STATE_HOME", result.dir / "state"),
                ("CODETRACER_TUI_LAYOUT_DIR", result.dir / "state"),
                ("CODETRACER_GPUI_GEOMETRY_OUT", result.geometryFile),
                ("CODETRACER_GPUI_GESTURE_TRACE", "1")],
    workingDir = result.dir)

proc launchDesktop(config: string; replay = false): Launched =
  ## The DESKTOP front-end under the same home arrangement: `ct edit
  ## <folder>`, the `.desktop` file's own command, or (`replay`) `ct replay`
  ## of the same recording the GPUI window opens.
  result.dir = home(config, short = true)
  result.log = result.dir / "desktop.log"
  createDir(result.dir / "project")
  writeFile(result.dir / "project" / "main.py", "print('plat69')\n")
  let command = if replay: @["replay", "--trace-folder=" & trace]
                else: @["edit", result.dir / "project"]
  result.p = t.spawn(@["/bin/sh", "-c", "exec \"$0\" \"$@\" >" &
                       quoteShell(result.log) & " 2>&1",
                       need("PLAT69_CT_BIN", file = true)] & command,
    extraEnv = [("PATH", need("PLAT69_CT_PATH")),
                ("LD_LIBRARY_PATH", getEnv("PLAT69_CT_LD_LIBRARY_PATH")),
                ("NODE_PATH", getEnv("PLAT69_CT_NODE_PATH")),
                ("CODETRACER_HOME", result.dir / "home"),
                ("ELECTRON_OZONE_PLATFORM_HINT", "wayland")],
    workingDir = result.dir)

proc geometry(l: Launched): JsonNode =
  ## The window's latest geometry report; JNull until it has written one
  ## (it is rewritten in place, so a half-written file is retried).
  for _ in 0 ..< 20:
    if not fileExists(l.geometryFile): return newJNull()
    try: return parseJson(readFile(l.geometryFile))
    except JsonParsingError, IOError: sleep(50)
  newJNull()

proc win(g: JsonNode): JsonNode = g{"topBar"}{"window"}

proc rectOf(j: JsonNode): Rect =
  Rect(x: j[0].getInt, y: j[1].getInt, w: j[2].getInt, h: j[3].getInt)

proc seg(g: JsonNode; part: string; label = ""): Rect =
  for s in g["topBar"]["segs"]:
    if s["part"].getStr == part and (label.len == 0 or s["label"].getStr == label):
      return rectOf(s["rect"])
  raise t.envError("seg", "the window drew no " & part & " " & label)

proc buttonsDrawn(g: JsonNode): seq[string] =
  ## The window buttons the window reports drawing, left to right.
  var xs: seq[(int, string)]
  for s in g["topBar"]["segs"]:
    if s["part"].getStr == "window-button":
      xs.add (s["rect"][0].getInt, s["label"].getStr)
  for (_, name) in xs.sortedByIt(it[0]): result.add name

proc names(j: JsonNode): seq[string] =
  for n in j: result.add n.getStr

proc centre(r: Rect): (int, int) = (r.x + r.w div 2, r.y + r.h div 2)

proc onScreen(w: EnvWindow; p: (int, int)): (int, int) =
  (w.rect.x + p[0], w.rect.y + p[1])

proc ready(l: Launched; csd: bool; timeoutS = 120): EnvWindow =
  ## The window once it is drawn, reports the decoration mode `csd`, and its
  ## content is the window the compositor reports.
  t.waitUntil("the window up, csd=" & $csd & " at the compositor's size",
    proc(): bool =
      let g = l.geometry
      if g.kind == JNull or g.win.isNil: return false
      if g.win["clientDecorated"].getBool != csd: return false
      let (found, w) = t.findWindow(AppId)
      found and g.win["content"] == %*[w.rect.w, w.rect.h],
    timeout = initDuration(seconds = timeoutS))
  result = t.window(AppId)
  discard t.captureSettled(result.rect, timeout = initDuration(seconds = 60))

proc defaultCsd(): bool =
  ## Whether a window that asks for no decoration mode draws its own frame
  ## here: true where the compositor cannot draw one (GNOME), false where it
  ## draws it by default (sway). A fact, measured by the target.
  t.fact("decorations.default").value == "client"

proc movedBy(before, after: Rect; dx, dy: int): bool =
  ## A title-bar move of (dx, dy) whose first motion was the 1px arming one:
  ## the window travels dx - 1 or dx, as the compositor anchors its move grab
  ## at that motion (sway) or at the press (Mutter) — a difference between
  ## compositors, measured on both, not between runs.
  after.x - before.x in [dx - 1, dx] and after.y - before.y == dy and
    (after.w, after.h) == (before.w, before.h)

proc guardClient(l: Launched): EnvWindow =
  ## THE VACUITY GUARD: client-side decorations are in force, or no case
  ## below proves anything.
  check t.fact("decorations.honoursClientRequest").value != "never"
  result = l.ready(csd = true)
  check l.geometry.win["clientDecorated"].getBool
  check l.geometry.win["live"].getBool

proc placeAt(l: Launched; x, y: int): EnvWindow =
  t.placeWindow(t.window(AppId), x, y)
  t.waitUntil("the window at " & $x & "," & $y, proc(): bool =
    let w = t.window(AppId)
    w.rect.x == x and w.rect.y == y)
  t.window(AppId)

proc moveDrag(src: (int, int); delta: (int, int)) =
  ## A title-bar drag. The renderer starts the move on the FIRST motion after
  ## the press (a double-click can still maximize), and the compositor's
  ## move follows the pointer from there: that motion is 1px, and the window
  ## travels `delta - (1, 0)`.
  t.pointerMove(src[0], src[1])
  t.press()
  sleep(150)
  t.pointerMove(src[0] + 1, src[1])
  sleep(150)
  t.drag(src + (1, 0), src + delta, steps = 10, stepMs = 30,
         releaseHoldMs = 250, pressHoldMs = -1)

proc expectedButtons(layout: string): tuple[left, right: seq[string]] =
  ## `layout` (GNOME `button-layout`), left side then right, less what the
  ## compositor does not advertise; close is always available.
  let advertised = t.fact("window.capabilities").value.split(',')
  let colon = layout.find(':')
  proc side(text: string; seen: var seq[string]): seq[string] =
    for name in text.split(','):
      let n = name.strip()
      if n in ["minimize", "maximize", "close"] and n notin seen and
         (n == "close" or n in advertised):
        seen.add n
        result.add n
  var seen: seq[string]
  result.left = side(layout[0 ..< colon], seen)
  result.right = side(layout[colon + 1 .. ^1], seen)

proc setLayout(l: Launched; layout: string) =
  t.configure("buttonLayout", layout)
  let want = expectedButtons(layout)
  t.waitUntil("the window's buttons for " & layout, proc(): bool =
    let g = l.geometry
    g.kind != JNull and g.win["buttonLayout"].getStr == layout and
      g.win["left"].names == want.left and g.win["right"].names == want.right)
  sleep(300)

proc iconPixels(img: RgbImage): int =
  ## Pixels of the desktop's window-button icons (#C8C8C8 / #F3F3F3 on the
  ## window's dark ground).
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let (r, g, b) = img.pixel(x, y)
      if r > 150 and g > 150 and b > 150: inc result

proc exited(l: Launched): bool = not l.p.running

# ---------------------------------------------------------------------------

proc stopTarget() =
  t.stop()
  for d in shortHomes:
    try: removeDir(d)
    except OSError: discard
  shortHomes.setLen 0

proc startTarget() =
  case getEnv("PLAT69_TARGET", "sway")
  of "sway": t = newSwayTarget(OutputW, OutputH, floatingAppIds = @[AppId])
  of "gnome": t = newGnomeTarget(OutputW, OutputH)
  else: quit("plat69_window_chrome: PLAT69_TARGET is sway or gnome", 2)
  t.start()

suite "plat69-window-management":

  setup:
    startTarget()
  teardown:
    stopTarget()

  test "the bar's empty space moves the window; a control and the menu button do not":
    let l = launchGpui()
    discard l.guardClient()
    var w = l.placeAt(60, 60)
    let g = l.geometry
    # The gap between the last debugger control and the omnibar.
    var lastControl = Rect()
    for s in g["topBar"]["segs"]:
      if s["part"].getStr == "control": lastControl = rectOf(s["rect"])
    let omni = g.seg("omnibar")
    check lastControl.w > 0
    check omni.x > lastControl.x + lastControl.w + 8
    let band = rectOf(g["topBar"]["band"])
    let gap = ((lastControl.x + lastControl.w + omni.x) div 2,
               band.y + band.h div 2)
    moveDrag(w.onScreen(gap), (120, 70))
    t.waitUntil("the window moved", proc(): bool =
      t.window(AppId).rect.x != w.rect.x)
    check movedBy(w.rect, t.window(AppId).rect, 120, 70)
    # The padding ABOVE the band drags too (the strip starts at y = 0). At
    # y = 8: the renderer's top resize zone takes the first 5 px inside the
    # content, as a desktop window's top edge resizes.
    w = l.placeAt(60, 60)
    check band.y > 8
    moveDrag(w.onScreen((gap[0], 8)), (80, 40))
    t.waitUntil("the window moved from the padding", proc(): bool =
      t.window(AppId).rect.x != w.rect.x)
    check movedBy(w.rect, t.window(AppId).rect, 80, 40)
    # A control is the control's, the menu button the menu's: no move.
    w = l.placeAt(60, 60)
    for part in [("control", "reverse-next"), ("menu", "")]:
      moveDrag(w.onScreen(g.seg(part[0], part[1]).centre), (120, 70))
      sleep(Settle)
      checkpoint(part[0] & " " & part[1])
      check t.window(AppId).rect == w.rect
      t.keys("Escape")
      sleep(300)

  test "the right edge widens the window, and the layout follows it":
    let l = launchGpui()
    discard l.guardClient()
    var w = l.placeAt(40, 40)
    let before = l.geometry
    let footerH = before["footer"][3].getInt
    let areaRight = w.rect.w - (before["area"][0].getInt + before["area"][2].getInt)
    # 2 px inside the content: within the renderer's right resize zone.
    # The holds are for this window: the press reaches its own pointer
    # handling too (it focuses the pane under it), motion sent before the
    # compositor has started the grab is lost to it, and every configure the
    # grab sends is a full re-layout here. (An oscillating, short resize was
    # measured here once — 1284, 1292, 1304, 1292, 1320, 1292 for 40 px — and
    # was the renderer drawing a frame of its fallback title bar at each
    # decoration grant, fixed in isonim-gpui d34c790; traced since: sway's
    # configures step 1280 -> 1320 in 5 px steps, none throttled.)
    let grab = (w.rect.x + w.rect.w - 3, w.rect.y + w.rect.h div 2)
    t.drag(grab, grab + (40, 0), steps = 8, stepMs = 250,
           pressHoldMs = 800, releaseHoldMs = 800)
    t.waitUntil("the window widened by 40", proc(): bool =
      t.window(AppId).rect.w == w.rect.w + 40,
      timeout = initDuration(seconds = 30))
    var settled = t.window(AppId).rect
    var still = 0
    t.waitUntil("the compositor's size settled", proc(): bool =
      sleep(250)
      let now = t.window(AppId).rect
      if now == settled: inc still else: (still = 0; settled = now)
      still >= 6,
      timeout = initDuration(seconds = 30))
    checkpoint("widened " & $w.rect & " -> " & $settled)
    let before0 = w.rect
    w = t.window(AppId)
    check w.rect.w == before0.w + 40
    check (w.rect.x, w.rect.h) == (40, WinH)
    t.waitUntil("the window laid out at its new size", proc(): bool =
      l.geometry.win["content"] == %*[w.rect.w, w.rect.h])
    let g = l.geometry
    let W = w.rect.w
    let H = w.rect.h
    # The top bar spans the new width, its buttons at its new end, the drag
    # strip with it; the arrangement and the footer fill it.
    check rectOf(g["topBar"]["band"]) ==
          Rect(x: 12, y: 12, w: W - 24, h: before["topBar"]["band"][3].getInt)
    check g.win["drag"] == %*[0, 0, W, g.win["drag"][3].getInt]
    let close = g.seg("window-button", "close")
    check close.x + close.w == W - 12 - 5
    check g["footer"] == %*[0, H - footerH, W, footerH]
    check W - (g["area"][0].getInt + g["area"][2].getInt) == areaRight
    # Every pane box of the arrangement within it, the last one to its edge.
    var rightmost = 0
    for n in g["nodes"]:
      rightmost = max(rightmost, n["rect"][0].getInt + n["rect"][2].getInt)
    check rightmost == W - areaRight
    # And the pixels: the close button's icon is drawn at its new place.
    let img = t.captureSettled(Rect(x: w.rect.x + close.x, y: w.rect.y + close.y,
                                    w: close.w, h: close.h))
    check img.iconPixels > 0
    # Remembered layouts are not rewritten by a resize.
    var remembered: seq[string]
    for f in walkDirRec(l.dir / "state"):
      if "gpui-layout" in f.extractFilename: remembered.add f
    check remembered.len == 0

  test "maximize and restore, by the button and by a double-click":
    let l = launchGpui()
    discard l.guardClient()
    l.setLayout(":minimize,maximize,close")
    let canMaximize = t.boolFact("window.canMaximize")
    let w = l.placeAt(60, 60)
    let g = l.geometry
    let maxButton = w.onScreen(g.seg("window-button", "maximize").centre)
    proc icon(): string =
      for s in l.geometry["topBar"]["segs"]:
        if s["label"].getStr == "maximize": return s["icon"].getStr
    check icon() == "maximize"
    var lastControl = Rect()
    for s in g["topBar"]["segs"]:
      if s["part"].getStr == "control": lastControl = rectOf(s["rect"])
    let omni = g.seg("omnibar")
    # In the window's own coordinates: the window is somewhere else once
    # maximized, and the restore double-click is on the window as it is then.
    let gapIn = ((lastControl.x + lastControl.w + omni.x) div 2,
                 g.seg("omnibar").centre[1])
    for how in ["button", "double-click"]:
      checkpoint(how & ", canMaximize=" & $canMaximize)
      if how == "button": t.click(maxButton)
      else: t.doubleClick(t.window(AppId).onScreen(gapIn))
      if canMaximize:
        t.waitUntil("maximized by " & how, proc(): bool =
          l.geometry.win["maximized"].getBool and icon() == "restore")
        # The window's account comes first; the compositor's follows.
        t.waitUntil("the compositor's window maximized", proc(): bool =
          t.window(AppId).rect.w > w.rect.w)
        sleep(800)   # past the double-click interval: the next one is a new gesture
        # Restore, from the button where it now is.
        let g2 = l.geometry
        let at = t.window(AppId).onScreen(g2.seg("window-button", "maximize").centre)
        if how == "button": t.click(at)
        else: t.doubleClick(t.window(AppId).onScreen(gapIn))
        t.waitUntil("restored by " & how, proc(): bool =
          not l.geometry.win["maximized"].getBool and icon() == "maximize")
        t.waitUntil("the compositor's window restored to its size", proc(): bool =
          (t.window(AppId).rect.w, t.window(AppId).rect.h) == (w.rect.w, w.rect.h))
        sleep(800)
      else:
        # This compositor does not maximize the window (a fact, measured):
        # the button is there, and nothing changes — not the window, not
        # the window's belief, not the icon.
        sleep(Settle)
        check t.window(AppId).rect == w.rect
        check not l.geometry.win["maximized"].getBool
        check icon() == "maximize"

  test "each supported button is drawn and acts; each unsupported one is absent":
    let l = launchGpui()
    discard l.guardClient()
    let layout = ":minimize,maximize,close"
    l.setLayout(layout)
    let want = expectedButtons(layout)
    let advertised = t.fact("window.capabilities").value.split(',')
    let g = l.geometry
    check g.buttonsDrawn == want.right
    check ("minimize" in g.buttonsDrawn) == ("minimize" in advertised)
    check ("minimize" in g.buttonsDrawn) == t.boolFact("window.canMinimize")
    check g.win["supported"].names.filterIt(it != "close").allIt(it in advertised)
    let w = t.window(AppId)
    t.click(w.onScreen(g.seg("window-button", "close").centre))
    t.waitUntil("the window closed by its close button", proc(): bool =
      l.exited, timeout = initDuration(seconds = 30))
    check l.p.peekExitCode == 0
    check not t.findWindow(AppId)[0]

suite "plat69-button-placement":

  setup:
    startTarget()
  teardown:
    stopTarget()

  test "a right-side and a left-side layout put the buttons there, in that order":
    let l = launchGpui()
    discard l.guardClient()
    let w = l.placeAt(60, 60)
    var band = rectOf(l.geometry["topBar"]["band"])
    for layout in [":minimize,maximize,close", "close,maximize,minimize:",
                   "maximize:close"]:
      l.setLayout(layout)
      let want = expectedButtons(layout)
      let g = l.geometry
      checkpoint(layout & " -> " & $g.buttonsDrawn)
      check g.buttonsDrawn == want.left & want.right
      band = rectOf(g["topBar"]["band"])
      let menu = g.seg("menu")
      for name in want.left:
        let r = g.seg("window-button", name)
        check r.x + r.w <= menu.x
        check r.x < band.x + band.w div 2
      for name in want.right:
        let r = g.seg("window-button", name)
        check r.x > band.x + band.w div 2
        check r.x + r.w <= band.x + band.w - 5
      # THE SCREEN AGREES: each button's icon is drawn where it is reported,
      # and nothing is drawn at the other end, where the other layout's
      # buttons were.
      for name in want.left & want.right:
        let r = g.seg("window-button", name)
        let img = t.captureSettled(Rect(x: w.rect.x + r.x, y: w.rect.y + r.y,
                                        w: r.w, h: r.h))
        check img.iconPixels > 0
      if want.right.len == 0:
        # A left-only layout leaves the band's right end empty: nothing is
        # drawn where the right-side layout's close button was. (The left
        # end of a right-only layout holds the menu button, whose glyph is
        # light too, so that end is not this check's.)
        let empty = Rect(x: band.x + band.w - 29, y: band.y + 5, w: 24, h: 24)
        let img = t.captureSettled(Rect(x: w.rect.x + empty.x,
          y: w.rect.y + empty.y, w: empty.w, h: empty.h))
        check img.iconPixels == 0
    # The close button closes from where the last layout put it (the right).
    let g = l.geometry
    t.click(t.window(AppId).onScreen(g.seg("window-button", "close").centre))
    t.waitUntil("closed", proc(): bool = l.exited,
                timeout = initDuration(seconds = 30))
    check l.p.peekExitCode == 0

  test "the close button closes from the left, too":
    let l = launchGpui()
    discard l.guardClient()
    l.setLayout("close:")
    let g = l.geometry
    check g.buttonsDrawn == @["close"]
    let r = g.seg("window-button", "close")
    check r.x == 12 + 5
    t.click(t.window(AppId).onScreen(r.centre))
    t.waitUntil("closed from the left", proc(): bool = l.exited,
                timeout = initDuration(seconds = 30))
    check l.p.peekExitCode == 0

suite "plat69-initial-window":

  setup:
    startTarget()
  teardown:
    stopTarget()

  proc desktopWindow(l: Launched): EnvWindow =
    ## The desktop's window, once it shows its page.
    t.waitUntil("the desktop's window", proc(): bool =
      t.findWindow(AppId)[0], timeout = initDuration(seconds = 120))
    result = t.window(AppId)
    discard t.captureSettled(result.rect, timeout = initDuration(seconds = 90))
    result = t.window(AppId)

  proc desktopOpened(l: Launched): string =
    ## The desktop's account of what it asked for (`index/window.nim`).
    for line in readFile(l.log).splitLines():
      let at = line.find("index: window opens ")
      if at >= 0: return line[at + "index: window opens ".len .. ^1].strip()

  test "with no window setting, both front-ends open maximized":
    let canMaximize = t.boolFact("window.canMaximize")
    checkpoint("canMaximize=" & $canMaximize)
    # GPUI, with no --width / --height: the setting decides.
    block:
      let l = launchGpui(decorations = "", size = false,
                         config = shippedConfigWith(""))
      discard l.ready(csd = defaultCsd())
      let launch = l.geometry.win["launch"]
      check launch["maximized"].getBool         # the window's request
      check not launch["explicitSize"].getBool
      check (launch["width"].getInt, launch["height"].getInt) == (1900, 1400)
      if canMaximize:
        check l.geometry.win["maximized"].getBool   # the compositor's answer
      l.p.terminate()
      discard l.p.waitForExit(10000)
    # The desktop, from the same (absent) setting.
    block:
      let l = launchDesktop(shippedConfigWith(""))
      let w = l.desktopWindow
      t.waitUntil("the desktop said how it opened", proc(): bool =
        l.desktopOpened.len > 0, timeout = initDuration(seconds = 60))
      check l.desktopOpened.startsWith("maximized")
      if canMaximize:
        check w.rect.w == OutputW   # the desktop's own panel may take height

  test "with initial: windowed and a size, both open at exactly that size":
    let config = shippedConfigWith(
      "window:\n  initial: windowed\n  width: 1200\n  height: 700\n")
    block:
      let l = launchGpui(decorations = "", size = false, config = config)
      let w = l.ready(csd = defaultCsd())
      check (w.rect.w, w.rect.h) == (1200, 700)    # the compositor's
      check not l.geometry.win["launch"]["maximized"].getBool
      check not l.geometry.win["maximized"].getBool
      l.p.terminate()
      discard l.p.waitForExit(10000)
    block:
      let l = launchDesktop(config)
      let w = l.desktopWindow
      check (w.rect.w, w.rect.h) == (1200, 700)
      check l.desktopOpened.startsWith("windowed")

  test "both report the same app id, the .desktop file's, and the same title":
    var titles: seq[string]
    block:
      let l = launchGpui(decorations = "")
      let w = l.ready(csd = defaultCsd())
      check w.appId == AppId
      check l.geometry.win["appId"].getStr == AppId
      titles.add w.title
      check l.geometry.win["title"].getStr == w.title
      l.p.terminate()
      discard l.p.waitForExit(10000)
    block:
      # The desktop on the same recording. Its title passes through the
      # program's path before its page names it (measured: `CodeTracer`,
      # then `/…/calc/main.py`, then `main.py — CodeTracer`).
      let l = launchDesktop(shippedConfigWith(""), replay = true)
      discard l.desktopWindow
      t.waitUntil("the desktop's page named the window", proc(): bool =
        t.window(AppId).title.endsWith(" — CodeTracer"),
        timeout = initDuration(seconds = 120))
      let w = t.window(AppId)
      check w.appId == AppId
      titles.add w.title
    checkpoint("titles: " & $titles)
    check titles[0].endsWith(" — CodeTracer")
    check titles[0] == titles[1]

suite "plat69-server-mode":

  setup:
    startTarget()
  teardown:
    stopTarget()

  test "where the compositor draws the frame: no buttons, no drag strip, no move":
    # A target that cannot draw a frame (GNOME has no decoration manager)
    # has no server mode to control: SKIPPED, and reported as such.
    if not t.boolFact("decorations.serverAvailable"):
      # Not applicable here, by name: this compositor cannot draw a frame.
      echo "NOT APPLICABLE on ", getEnv("PLAT69_TARGET", "sway"),
           ": decorations.serverAvailable is false"
      skip()
    else:
      let l = launchGpui(decorations = "")
      discard l.ready(csd = false)
      let w = l.placeAt(60, 60)
      let g = l.geometry
      check not g.win["clientDecorated"].getBool
      check g.buttonsDrawn.len == 0
      check g.win["drag"].kind == JNull
      check g.seg("menu").x == 12
      # A drag on the bar's empty space is nothing's.
      var lastControl = Rect()
      for s in g["topBar"]["segs"]:
        if s["part"].getStr == "control": lastControl = rectOf(s["rect"])
      let omni = g.seg("omnibar")
      moveDrag(w.onScreen(((lastControl.x + lastControl.w + omni.x) div 2,
                           omni.centre[1])), (120, 70))
      sleep(Settle)
      check t.window(AppId).rect == w.rect
      # And the band's right end, where client-side buttons would be, is the
      # band's ground: nothing is drawn there.
      let band = rectOf(g["topBar"]["band"])
      let img = t.captureSettled(Rect(x: w.rect.x + band.x + band.w - 29,
                                      y: w.rect.y + band.y + 5, w: 24, h: 24))
      check img.iconPixels == 0
