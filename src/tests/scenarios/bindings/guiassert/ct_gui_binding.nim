## ct_gui_binding.nim — CodeTracer's GuiAssert binding: the GPUI window
## flavour of the CodeTracer scenario pack (`../../pack/codetracer.pack.yaml`),
## for DemoVideoScript-GuiAssert.
##
## The window is read by VISION and nothing else: GuiAssert's capture of the
## pixels, its OCR engine for text, and classical measurements for what text
## does not carry (the execution pointer's colour, the caret's bar, a
## highlighted band). The window cooperates in nothing — no plan, no element
## tree, no test channel — exactly as the screen oracle reads it
## (`src/tests/visual/screen_oracle/`, PLAT-39), whose measured conventions
## this follows: the window is dark, so text is inverted before the engine
## reads it; the gutter's line numbers are read as a column and checked
## against each other, because a single OCR'd digit is not trusted on its
## own.
##
## * Stages: the pack's one implementation (`../../stages/ct_stages.nim`);
##   `open-recording` / `open-project` start the windowed `codetracer-gpui`
##   on the adapter's private X display.
## * The surface: the session strip (the top bar's tabs), the editor (its
##   file from its tab, its lines from the gutter column and the code beside
##   it, the line the pointer is on, the line the caret is on), the status
##   line (the replay's location).
## * Conditions: `replay-idle` — the status line names where the replay is.
## * The binding resolver: `../../resolver/ct_resolver.nim`, the shared
##   keymap router as the GPUI window builds it (native key delivery).
##
## What vision cannot read is declared unreadable: a scenario that needs it
## is `unsupported` here, never answered from elsewhere.

import std/[algorithm, exitprocs, json, options, os, strutils, tables, math]
from std/unicode import toLower
import demo_video_script_guiassert
import ../../stages/ct_stages
import ../../resolver/ct_resolver
import ../../../../frontend/viewmodel/keymap/[context_keys, keymap_router]
import ../../../../frontend/viewmodel/viewmodels/product_mode
import ../../../../common/key_names

proc gpuiBinary*(): string =
  result = getEnv("CODETRACER_GPUI_WINDOW_BIN")
  if result.len == 0: result = repo() / "build" / "bin" / "codetracer-gpui-window"
  if not fileExists(result):
    raise newException(IOError, "the windowed GPUI front-end is not built at " & result &
      " (codetracer-gpui against isonim-gpui's windowed shim, -d:gpuiShimPath=…)")

proc shimDir*(): string =
  result = getEnv("ISONIM_GPUI_WINDOWED_SHIM_DIR")
  if result.len == 0: result = repo().parentDir / "isonim-gpui/rust/target/windowed/debug"

var stageStates* = initTable[string, StageState]()

proc removeStageRoots() {.noconv.} =
  for _, s in stageStates: s.removeStage()

proc stageState(ctx: GuiContext): StageState =
  if not ctx.state.hasKey("$stage"):
    let s = newStageState()
    ctx.state["$stage"] = %s.root
    if stageStates.len == 0: addExitProc(removeStageRoots)
    stageStates[s.root] = s
  stageStates[ctx.state["$stage"].getStr]

proc launchGpui(ctx: GuiContext; s: StageState) =
  let w = if s.launch.width > 0: s.launch.width else: 1600
  let h = if s.launch.height > 0: s.launch.height else: 1000
  var argv = @[gpuiBinary(), "--width=" & $w, "--height=" & $h]
  if s.launch.keymap.len > 0: argv.add "--keymap=" & s.launch.keymap
  if s.launch.recording.len > 0: argv.add s.launch.recording
  else:
    argv.add "--edit"
    argv.add(if s.launch.file.len > 0: s.launch.project / s.launch.file else: s.launch.project)
  for k, v in s.launch.env: ctx.env[k] = v
  var lib = @[shimDir()]
  for v in [getEnv("CODETRACER_GPUI_RUNTIME_LIB_PATH"), getEnv("LD_LIBRARY_PATH")]:
    if v.len > 0: lib.add v
  ctx.env["LD_LIBRARY_PATH"] = lib.join(":")
  ctx.env.del("LD_PRELOAD")
  if getEnv("CT_GUI_BINDING_DEBUG").len > 0: ctx.env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let cwd = getCurrentDir()
  setCurrentDir(s.launch.workDir)
  # The window is named after what it shows (`<program> — CodeTracer`).
  try: ctx.startApp(argv, "CodeTracer", 60_000, titleContains = true)
  finally: setCurrentDir(cwd)

# --- pixels -------------------------------------------------------------------------------

proc rgb(f: Frame; x, y: int): (int, int, int) =
  let i = (y * f.image.width + x) * 3
  (ord(f.image.pixels[i]), ord(f.image.pixels[i + 1]), ord(f.image.pixels[i + 2]))

proc textImage(f: Frame; x, y, w, h: int; scale = 2): GrayImage =
  ## The region as the OCR engine reads best: gray, inverted (the window's
  ## text is light on dark), scaled up and smoothed.
  let x0 = max(0, x)
  let y0 = max(0, y)
  let ww = max(1, min(w, f.image.width - x0))
  let hh = max(1, min(h, f.image.height - y0))
  result = newImage(GrayImage, ww * scale, hh * scale)
  for yy in 0 ..< hh * scale:
    for xx in 0 ..< ww * scale:
      let l = f.luma(x0 + xx div scale, y0 + yy div scale)
      result.pixels[yy * ww * scale + xx] = char(255 - l)
  result = smooth(result, 1)

proc words(ctx: GuiContext; f: Frame; x, y, w, h: int; psm = 11): seq[Word] =
  ## The words in a region, in frame pixels.
  const scale = 2
  for wd in ctx.recognize(textImage(f, x, y, w, h, scale), psm):
    var m = wd
    m.x = x + wd.x div scale
    m.y = y + wd.y div scale
    m.w = wd.w div scale
    m.h = wd.h div scale
    if m.text.strip.len > 0: result.add m

proc fl(i: int): float = float(i)

# --- the window's parts ------------------------------------------------------------------

const
  TopBarH = 36            ## the top bar: menu, transport, omnibox, session tabs
  StripH = 26             ## a box's strip of pane tabs
  FooterH = 32            ## the status line

proc isSourceName(t: string): bool =
  let base = t.split('/')[^1]
  let dot = base.rfind('.')
  dot > 0 and dot < base.len - 1 and base[dot + 1 .. ^1].allCharsInSet(Letters) and
    base[dot + 1 .. ^1].len <= 5

type EditorBox = object
  file: string
  left, right, top, bottom: int

proc findEditor(ctx: GuiContext; f: Frame): Option[EditorBox] =
  ## The editor: the box whose strip names a source file (`nim-project/tracing.nim`).
  let strip = ctx.words(f, 0, TopBarH, f.image.width, StripH + 4)
  var labels = strip
  labels.sort(proc (a, b: Word): int = cmp(a.x, b.x))
  for i, wd in labels:
    if wd.text.isSourceName:
      var right = f.image.width
      for j in i + 1 ..< labels.len:
        let t = labels[j].text
        if t.len >= 3 and t == t.toUpperAscii and t[0] in Letters:
          right = labels[j].x - 8
          break
      return some(EditorBox(file: wd.text.split('/')[^1], left: max(0, wd.x - 10),
                            right: right, top: TopBarH + StripH,
                            bottom: f.image.height - FooterH))
  none(EditorBox)

type EditorRow = object
  numbersRight: int
  number: int
  y, h: int
  text: string
  textLeft: int

proc editorRows(ctx: GuiContext; f: Frame; b: EditorBox): seq[EditorRow] =
  ## The editor's rows: the gutter's numbers read as a column, the row
  ## rhythm checked against them, and each row's code.
  let ws = ctx.words(f, b.left, b.top, b.right - b.left, b.bottom - b.top)
  var nums: seq[Word]
  var code: seq[Word]
  for w in ws:
    let t = w.text.strip(chars = {'|', '.', ',', ';', ' '})
    if t.len > 0 and t.allCharsInSet(Digits) and w.x < b.left + 110: nums.add w
    elif w.x >= b.left + 90: code.add w
  if nums.len < 2: return
  nums.sort(proc (a, c: Word): int = cmp(a.y, c.y))
  # the row pitch: the most common gap between consecutive numbers' tops
  var gaps = initCountTable[int]()
  for i in 1 ..< nums.len:
    let g = nums[i].y - nums[i - 1].y
    if g > 10 and g < 60: gaps.inc g
  if gaps.len == 0: return
  let pitch = gaps.largest.key
  # the line number of the first row: the vote of every number read, each
  # corrected by its row's distance from the first (one misread digit loses)
  let y0 = nums[0].y
  var votes = initCountTable[int]()
  for n in nums:
    let k = int(round((n.y - y0) / pitch))
    try: votes.inc parseInt(n.text.strip(chars = {'|', '.', ',', ';', ' '})) - k
    except ValueError: discard
  if votes.len == 0: return
  var first = votes.largest.key
  var top = y0 - (pitch - nums[0].h) div 2
  # rows above the first number the engine read (a lone `1` is often lost):
  # the rhythm continues up to the box's top, down to line 1
  while first > 1 and top - pitch >= b.top - 2:
    dec first
    top -= pitch
  var rows = int((nums[^1].y - y0) / pitch + 0.5) + 1 + (y0 - (pitch - nums[0].h) div 2 - top) div pitch
  # and below the last one, while there is code on the row
  for c in code:
    let k = (c.y + c.h div 2 - top) div pitch
    if k + 1 > rows and top + (k + 1) * pitch <= b.bottom: rows = k + 1
  for k in 0 ..< rows:
    let y = top + k * pitch
    var parts: seq[Word]
    for c in code:
      if c.y + c.h div 2 >= y and c.y + c.h div 2 < y + pitch: parts.add c
    parts.sort(proc (a, c: Word): int = cmp(a.x, c.x))
    var text = ""
    for p in parts:
      if text.len > 0: text.add " "
      text.add p.text
    var nr = 0
    for n in nums: nr = max(nr, n.x + n.w)
    result.add EditorRow(numbersRight: nr, number: first + k, y: y, h: pitch, text: text,
                         textLeft: (if parts.len > 0: parts[0].x else: b.left + 110))

proc inkRuns(f: Frame; y0, y1, x0, x1: int): seq[(int, int)] =
  ## The runs of columns holding ink (text lighter than the ground) in a band.
  var start = -1
  var gap = 0
  for x in x0 ..< min(x1, f.image.width):
    var ink = false
    for y in max(0, y0) ..< min(y1, f.image.height):
      if f.luma(x, y) > 110:
        ink = true
        break
    if ink:
      if start < 0: start = x
      gap = 0
    elif start >= 0:
      inc gap
      if gap >= 2:
        result.add (start, x - gap)
        start = -1
        gap = 0
  if start >= 0: result.add (start, min(x1, f.image.width) - 1)

proc codeLeft(f: Frame; b: EditorBox; rows: seq[EditorRow]; numbersRight: int): int =
  ## Column 0 of the code: the leftmost text any row starts with, a fold
  ## chevron (a narrow mark before the text, in its own lane) excepted.
  result = high(int)
  for r in rows:
    let band0 = r.y + r.h div 5
    let band1 = r.y + r.h - r.h div 5
    let runs = inkRuns(f, band0, band1, numbersRight + 4, b.right - 4)
    if runs.len == 0: continue
    var first = runs[0]
    if runs.len > 1 and first[1] - first[0] <= 9 and runs[1][0] - first[1] >= 3:
      first = runs[1]
    result = min(result, first[0])
  if result == high(int): result = numbersRight + 20

proc pointerRow(f: Frame; b: EditorBox; rows: seq[EditorRow]): int =
  ## The execution pointer: the yellow ▸ in the band left of the numbers.
  for r in rows:
    for y in r.y ..< r.y + r.h:
      for x in b.left ..< b.left + 40:
        if y < 0 or y >= f.image.height or x >= f.image.width: continue
        let (cr, cg, cb) = f.rgb(x, y)
        if cr > 180 and cg > 120 and cb < 90 and cr - cb > 120:
          return r.number
  0

proc caretRow(f: Frame; b: EditorBox; rows: seq[EditorRow]): int =
  ## The caret: a light vertical bar one row tall, with background above and
  ## below it — what neither a glyph (shorter) nor an indent guide (running
  ## through the rows) is.
  for r in rows:
    let need = (r.h * 2) div 3
    for x in b.left + 90 ..< b.right - 2:
      var run = 0
      for y in r.y ..< r.y + r.h:
        if y >= 0 and y < f.image.height and f.luma(x, y) > 150: inc run
      if run >= need and f.luma(x + 2, r.y + r.h div 2) < 110 and
         f.luma(x - 2, r.y + r.h div 2) < 110 and
         (r.y - 3 < 0 or f.luma(x, r.y - 3) < 110) and
         (r.y + r.h + 2 >= f.image.height or f.luma(x, r.y + r.h + 2) < 110):
        return r.number
  0

proc sessionTabs(ctx: GuiContext; f: Frame): seq[(string, int)] =
  ## The session tabs: the titles right of the omnibox in the top bar,
  ## grouped by the gaps between them (a tab's `×` is not a word).
  let ws = ctx.words(f, 0, 0, f.image.width, TopBarH)
  var omniRight = -1
  for w in ws:
    if w.text.toLowerAscii.startsWith(":command") or w.text == "command":
      omniRight = max(omniRight, w.x + w.w)
  if omniRight < 0: return
  var rest: seq[Word]
  for w in ws:
    if w.x > omniRight + 24 and w.x < f.image.width - 120 and
       w.text notin ["x", "X", "×", "+", "*", "~"]:
      rest.add w
  rest.sort(proc (a, b: Word): int = cmp(a.x, b.x))
  var cur = ""
  var curX, lastRight = -1
  for w in rest:
    if cur.len > 0 and w.x - lastRight > 28:
      result.add (cur, curX)
      cur = ""
    if cur.len == 0: curX = w.x
    else: cur.add " "
    cur.add w.text
    lastRight = w.x + w.w
  if cur.len > 0: result.add (cur, curX)

proc statusLocation(ctx: GuiContext; f: Frame): string =
  ## Where the replay is, as the status line says it (`…/tracing.nim:18#0`).
  let y = f.image.height - FooterH
  for w in ctx.words(f, f.image.width div 2, y, f.image.width div 2, FooterH, psm = 7):
    let t = w.text
    let c = t.rfind(':')
    if c > 0 and t.contains('/') and c + 1 < t.len and t[c + 1] in Digits:
      return t.split('/')[^1]
  ""

proc readSurface(ctx: GuiContext; f: Frame): Tree =
  result.root = node("window", 0, 0, fl(f.image.width), fl(f.image.height), %*{"mode": "debug"})
  result.root.visible = true
  result.root.unreadable["title"] = "the window title is not drawn in the window"
  let loc = ctx.statusLocation(f)
  let tabs = ctx.sessionTabs(f)
  # one session draws no tab: the strip still has the one session
  let count = if tabs.len == 0 and loc.len > 0: 1 else: tabs.len
  let strip = node("session-strip", 0, 0, fl(f.image.width), fl(TopBarH),
                   %*{"count": count, "active": ""})
  strip.unreadable["active"] = "which tab is in front is told by its colour, which this binding does not read"
  result.add(result.root, strip)
  for (t, x) in tabs:
    let tab = node("session-tab", fl(x), 0, fl(8 * t.len), fl(TopBarH), %*{"title": t}, @[("title", t)])
    tab.unreadable["active"] = "which tab is in front is told by its colour"
    result.add(strip, tab)
  let box = ctx.findEditor(f)
  if box.isSome:
    let b = box.get
    let rows = ctx.editorRows(f, b)
    if getEnv("CT_GUI_BINDING_DEBUG").len > 0:
      for r in rows: stderr.writeLine "row ", r.number, " y=", r.y, " h=", r.h, " ", r.text
    let left = if rows.len > 0: codeLeft(f, b, rows, rows[0].numbersRight) else: b.left + 110
    var current = pointerRow(f, b, rows)
    var caret = caretRow(f, b, rows)
    if caret == 0:
      # the caret may be between blinks: look once more
      let again = ctx.grab()
      caret = caretRow(again, b, rows)
    let ed = node("editor", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"file": b.file, "active": true, "focused": caret > 0,
                     "current-line": current, "caret-line": caret,
                     "first-visible": (if rows.len > 0: rows[0].number else: 0),
                     "last-visible": (if rows.len > 0: rows[^1].number else: 0)},
                  @[("file", b.file)])
    ed.focused = caret > 0
    result.add(result.root, ed)
    for r in rows:
      let ln = node("line", fl(b.left), fl(r.y), fl(b.right - b.left), fl(r.h),
                    %*{"number": r.number, "text": r.text, "current": r.number == current,
                       "caret": r.number == caret},
                    @[("number", $r.number)])
      ln.props["codeLeft"] = %left
      result.add(ed, ln)
  result.add(result.root, node("status-line", 0, fl(f.image.height - FooterH), fl(f.image.width),
                               fl(FooterH), %*{"location": loc}))

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["mode"], "affordances": []},
    "session-strip": {"properties": ["count"], "affordances": []},
    "session-tab": {"properties": ["title"], "affordances": ["click", "context-click"]},
    "editor": {"properties": ["file", "active", "focused", "current-line", "caret-line",
                              "first-visible", "last-visible"],
               "affordances": ["click", "context-click", "wheel", "focusable", "text-entry"]},
    "line": {"properties": ["number", "text", "current", "caret"],
             "affordances": ["click", "double-click", "context-click"]},
    "status-line": {"properties": ["location"], "affordances": []}}

proc ctGuiBinding*(): GuiBinding =
  GuiBinding(
    name: "codetracer-gpui",
    roles: roles(),
    stage: proc (ctx: GuiContext; use: string; args: JsonNode) =
      let s = ctx.stageState()
      s.runStage(use, args)
      if use in ["open-recording", "open-project"]: ctx.launchGpui(s),
    surface: proc (ctx: GuiContext; f: Frame): Tree = ctx.readSurface(f),
    condition: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] =
      case name
      of "replay-idle": some(ctx.statusLocation(f).len > 0)
      else: none(bool),
    resolveChord: proc (ctx: GuiContext; operation: string): Option[string] =
      let s = ctx.stageState()
      let router = routerFor(baseOf(s.launch.keymap),
                             KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                         keyProtocol: kpNative),
                             s.configDir / "keybindings.json")
      let t = ctx.readSurface(ctx.grab())
      var scope = ResolverScope(product: pmDebug, replayLoaded: true)
      for n in t.kids(t.root):
        if n.role == "editor" and n.focused:
          scope.editorFocused = true
          scope.editorReadOnly = true
      router.resolveChord(operation, scope),
    anchor: proc (ctx: GuiContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      if n.role != "line": return none((int, int))
      let midY = int(n.y + n.h / 2)
      let left = n.props{"codeLeft"}.getInt(int(n.x) + 110)
      # the line's first character: the first ink at or right of column 0
      let f = ctx.grab()
      let runs = inkRuns(f, int(n.y) + int(n.h) div 5, int(n.y + n.h) - int(n.h) div 5,
                         left - 1, int(n.x + n.w) - 4)
      let textLeft = if runs.len > 0: runs[0][0] else: left
      if getEnv("CT_GUI_BINDING_DEBUG").len > 0:
        stderr.writeLine "anchor ", anchor, " on ", n.keyText, " -> ", textLeft + 3, ",", midY,
          " (column 0 at ", left, ")"
      case anchor
      of "gutter": some((int(n.x) + 20, midY))
      of "text-start": some((textLeft + 3, midY))
      else: none((int, int)))
