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
import std/sequtils
import ../../../visual/screen_oracle/pane_grammar
import ../../../../frontend/gpui/app/pane_names
import headless_app/layout_model

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
  for flag in s.launch.flags: argv.add flag
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

proc wordsL(ctx: GuiContext; f: Frame; x, y, w, h: int; psm = 6): seq[Word]

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
  # the numbers once more, as a column of their own on per-line grounds
  # (a short file's lone digits are lost in the whole box's sparse read)
  var column: seq[Word]
  for w in ctx.wordsL(f, b.left + 30, b.top, 70, b.bottom - b.top, psm = 6):
    # the execution arrow beside the number reads as `>` or `»`
    var t = ""
    for ch in w.text:
      if ch in Digits: t.add ch
      elif ch in {'|', '.', ',', ';', ' ', '>'} or ord(ch) >= 128: discard
      else:
        t = ""
        break
    if t.len > 0:
      var m = w
      m.text = t
      column.add m
  if column.len > nums.len: nums = column
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

# --- gpui batch: the window's boxes, their strips and their rows ---------------------------
#
# The window is a grid of boxes on a darker ground: each box is a strip of
# pane tabs (the active one on a lighter ground, joined to the box's body)
# over the body that draws the active pane. Measured on the windowed
# `codetracer-gpui` (1600x1000, dark theme): the ground is (27,27,27), a box
# body and an inactive tab (40,40,40), the active tab (51,51,51), the strip
# 24 px, the gaps 4 px. Nothing here is a coordinate of a particular layout:
# the boxes are found from the ground around them, the tabs from the gaps
# between them, the labels and the rows by OCR.

type
  PaneTab = object
    x0, x1, y0, y1: int
    label: string
    active: bool
    band: bool               ## the focused box's whole strip (its tabs are cut from it)
    cut: (int, int)          ## on a band: the selected tab, on the window's ground
  PaneBox = object
    left, right, top, bottom: int   ## the body, below the strip
    stripTop: int
    tabs: seq[PaneTab]
  TextRow = object
    y0, y1, x0, x1: int
    text: string
    words: seq[Word]
    ground: (int, int, int)          ## the row's ground, left of its text

proc stretchedText(f: Frame; x, y, w, h: int; scale = 3): GrayImage =
  ## The region as the OCR engine reads dim text best: its commonest gray
  ## (the ground) to white, its brightest to black, the rest stretched
  ## between them, then scaled up bilinearly. Measured on the window's
  ## strips: an inactive tab's dim label (luma ~100 on 40) reads `VCSs` with a
  ## plain inversion and `VCS` stretched.
  let x0 = max(0, x)
  let y0 = max(0, y)
  let ww = max(1, min(w, f.image.width - x0))
  let hh = max(1, min(h, f.image.height - y0))
  var hist: array[256, int]
  var hi = 0
  var src = newSeq[int](ww * hh)
  for yy in 0 ..< hh:
    for xx in 0 ..< ww:
      let l = f.luma(x0 + xx, y0 + yy)
      src[yy * ww + xx] = l
      inc hist[l]
      hi = max(hi, l)
  var lo = 0
  for v in 0 .. 255:
    if hist[v] > hist[lo]: lo = v
  let span = max(1, hi - lo)
  proc ink(v: int): int =
    if v <= lo: 255 else: 255 - min(255, (v - lo) * 255 div span)
  result = newImage(GrayImage, ww * scale, hh * scale)
  for yy in 0 ..< hh * scale:
    let fy = (yy.float + 0.5) / scale.float - 0.5
    let ya = max(0, min(hh - 1, int(floor(fy))))
    let yb = min(hh - 1, ya + 1)
    let ty = max(0.0, min(1.0, fy - ya.float))
    for xx in 0 ..< ww * scale:
      let fx = (xx.float + 0.5) / scale.float - 0.5
      let xa = max(0, min(ww - 1, int(floor(fx))))
      let xb = min(ww - 1, xa + 1)
      let tx = max(0.0, min(1.0, fx - xa.float))
      let v = (ink(src[ya * ww + xa]).float * (1 - tx) + ink(src[ya * ww + xb]).float * tx) * (1 - ty) +
              (ink(src[yb * ww + xa]).float * (1 - tx) + ink(src[yb * ww + xb]).float * tx) * ty
      result.pixels[yy * ww * scale + xx] = char(int(v + 0.5))

proc wordsS(ctx: GuiContext; f: Frame; x, y, w, h: int; psm = 11): seq[Word] =
  ## The words in a region read from its stretched image, in frame pixels.
  const scale = 3
  for wd in ctx.recognize(stretchedText(f, x, y, w, h, scale), psm):
    var m = wd
    m.x = max(0, x) + wd.x div scale
    m.y = max(0, y) + wd.y div scale
    m.w = wd.w div scale
    m.h = wd.h div scale
    if m.text.strip.len > 0: result.add m

proc cubic(p0, p1, p2, p3, t: float): float =
  ## Catmull-Rom between p1 and p2.
  0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t +
         (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)

proc lineGroundText(f: Frame; x, y, w, h: int; scale = 3): GrayImage =
  ## A pane body as the OCR engine reads its rows best: every scanline's own
  ## commonest gray is its ground (a selected row's band is a ground too, so
  ## its text keeps its contrast), ink is what is lighter than that, darkest
  ## where it is brightest; scaled up bicubically. Measured over the window's
  ## call trace and event log: per-scanline grounds read `2 + 3 = 5` on the
  ## current row where one ground for the region read `2 + 3 = b`.
  let x0 = max(0, x)
  let y0 = max(0, y)
  let ww = max(1, min(w, f.image.width - x0))
  let hh = max(1, min(h, f.image.height - y0))
  var ink = newSeq[int](ww * hh)
  var hi = 1
  for yy in 0 ..< hh:
    var hist: array[256, int]
    for xx in 0 ..< ww: inc hist[f.luma(x0 + xx, y0 + yy)]
    var g = 0
    for v in 0 .. 255:
      if hist[v] > hist[g]: g = v
    for xx in 0 ..< ww:
      let v = max(0, f.luma(x0 + xx, y0 + yy) - g)
      ink[yy * ww + xx] = v
      hi = max(hi, v)
  proc at(xx, yy: int): float =
    let cx = max(0, min(ww - 1, xx))
    let cy = max(0, min(hh - 1, yy))
    255.0 - float(min(255, ink[cy * ww + cx] * 255 div hi))
  result = newImage(GrayImage, ww * scale, hh * scale)
  for yy in 0 ..< hh * scale:
    let fy = (yy.float + 0.5) / scale.float - 0.5
    let iy = int(floor(fy))
    let ty = fy - iy.float
    for xx in 0 ..< ww * scale:
      let fx = (xx.float + 0.5) / scale.float - 0.5
      let ix = int(floor(fx))
      let tx = fx - ix.float
      var col: array[4, float]
      for k in 0 .. 3:
        col[k] = cubic(at(ix - 1, iy - 1 + k), at(ix, iy - 1 + k), at(ix + 1, iy - 1 + k),
                       at(ix + 2, iy - 1 + k), tx)
      let v = cubic(col[0], col[1], col[2], col[3], ty)
      result.pixels[yy * ww * scale + xx] = char(max(0, min(255, int(v + 0.5))))

proc wordsL(ctx: GuiContext; f: Frame; x, y, w, h: int; psm = 6): seq[Word] =
  ## The words of a pane body, read from its line-ground image.
  const scale = 3
  for wd in ctx.recognize(lineGroundText(f, x, y, w, h, scale), psm):
    var m = wd
    m.x = max(0, x) + wd.x div scale
    m.y = max(0, y) + wd.y div scale
    m.w = wd.w div scale
    m.h = wd.h div scale
    if m.text.strip.len > 0: result.add m

proc groundOf(f: Frame): (int, int, int) =
  ## The window's ground: the colour of the left edge, mid-window.
  f.rgb(1, f.image.height div 2)

proc near(a, b: (int, int, int); tol = 4): bool =
  abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol and abs(a[2] - b[2]) <= tol

proc isGround(f: Frame; g: (int, int, int); x, y: int): bool =
  if x < 0 or y < 0 or x >= f.image.width or y >= f.image.height: return true
  near(f.rgb(x, y), g)

proc stripLabelWords(ctx: GuiContext; f: Frame; y, h: int): seq[Word] =
  ctx.wordsS(f, 0, y, f.image.width, h, psm = 11)

proc paneBoxes(ctx: GuiContext; f: Frame): seq[PaneBox] =
  ## Every box below the top bar and above the footer, with its tabs.
  let g = f.groundOf
  let w = f.image.width
  let footer = f.image.height - FooterH
  var strips: Table[int, seq[PaneTab]]
  var found: seq[PaneTab]
  for y in TopBarH - 6 ..< footer - 40:
    for x in 0 ..< w:
      if f.isGround(g, x, y) or not f.isGround(g, x - 1, y) or not f.isGround(g, x, y - 1) or
         not f.isGround(g, x + 3, y - 2) or not f.isGround(g, x + 3, y - 3):
        continue
      # a tab's top-left corner (its rounded corner: the same tab is met again
      # a row or two lower, a pixel or two further left)
      var dup = false
      for t in found:
        if y - t.y0 <= 8 and x >= t.x0 - 6 and x <= t.x1: dup = true
      if dup: continue
      let ym = y + 6
      let open = not f.isGround(g, x + 1, ym)
      let c = f.rgb(x + 1, ym)
      var x0 = x
      var x1 = x
      var y1 = ym
      if open:
        while x0 > 0 and not f.isGround(g, x0 - 1, ym): dec x0
        while x1 + 1 < w and not f.isGround(g, x1 + 1, ym): inc x1
        while y1 + 1 < footer and near(f.rgb(x + 1, y1 + 1), c, 2): inc y1
      let tabH = y1 - y + 1
      if not open or x1 - x0 < 30:
        # the focused box's strip: one band of the focus colour across the
        # box, the selected tab cut out of it on the window's ground
        # (Native-Front-End-Parity.md §2, measured: (58,58,58) around a
        # (27,27,27) tab)
        let cb = f.rgb(x + 1, y + 2)
        if f.isGround(g, x + 1, y + 2): continue
        var bx1 = x
        while bx1 + 1 < w and near(f.rgb(bx1 + 1, y + 2), cb, 2): inc bx1
        # the band's depth, down a column that is neither its outline (which
        # runs on down the focused box's sides) nor the cut-out tab
        var by1 = -1
        for col in [x + 3, (x + bx1) div 2, bx1 - 3]:
          var yy = y + 2
          while yy + 1 < footer and near(f.rgb(col, yy + 1), cb, 2): inc yy
          if yy - y >= 22 and yy - y <= 40: by1 = yy
        if bx1 - x < 150 or by1 < 0: continue
        var cut = (-1, -1)
        var cx = x + 3
        let cy = by1 - 3
        while cx < bx1 - 3:
          if f.isGround(g, cx, cy):
            var cx1 = cx
            while cx1 + 1 < bx1 and f.isGround(g, cx1 + 1, cy): inc cx1
            if cx1 - cx >= 30 and cut[0] < 0: cut = (cx, cx1)
            cx = cx1 + 1
          else: inc cx
        let band = PaneTab(x0: x, x1: bx1, y0: y, y1: by1, band: true, cut: cut)
        found.add band
        strips.mgetOrPut(y, @[]).add band
        continue
      if tabH < 16 or tabH > 34: continue
      let tab = PaneTab(x0: x0, x1: x1, y0: y, y1: y1,
                        active: not near(f.rgb(x + 1, y1 + 2), g, 4))
      found.add tab
      strips.mgetOrPut(y, @[]).add tab
  # tabs of one strip met on neighbouring rows (rounded corners) are one strip
  var ys: seq[int]
  for y in strips.keys: ys.add y
  ys.sort()
  for i in 1 ..< ys.len:
    if ys[i] - ys[i - 1] <= 6 and strips.hasKey(ys[i - 1]):
      strips.mgetOrPut(ys[i], @[]).add strips[ys[i - 1]]
      strips.del(ys[i - 1])
  for y0, inStrip in strips:
    var tabs = inStrip
    tabs.sort(proc (a, b: PaneTab): int = cmp(a.x0, b.x0))
    var y = y0
    for t in tabs: y = min(y, t.y0)
    let labels = ctx.stripLabelWords(f, y, tabs[0].y1 - y + 1)
    # a focused strip's band: its tabs are its labels, grouped by the gaps
    # between them; the one over the cut-out ground is the selected one
    var split: seq[PaneTab]
    for t in tabs:
      if not t.band:
        split.add t
        continue
      var ws: seq[Word]
      for wd in labels:
        let cx = wd.x + wd.w div 2
        if cx >= t.x0 and cx <= t.x1: ws.add wd
      ws.sort(proc (a, b: Word): int = cmp(a.x, b.x))
      var groups: seq[(int, int)]
      for wd in ws:
        if groups.len > 0 and wd.x - groups[^1][1] <= 30: groups[^1][1] = wd.x + wd.w
        else: groups.add (wd.x, wd.x + wd.w)
      for (gx0, gx1) in groups:
        let mid = (gx0 + gx1) div 2
        split.add PaneTab(x0: max(t.x0, gx0 - 8), x1: min(t.x1, gx1 + 8), y0: t.y0, y1: t.y1,
                          active: mid >= t.cut[0] and mid <= t.cut[1], band: true)
    tabs = split
    for t in tabs.mitems:
      var parts: seq[Word]
      for wd in labels:
        let cx = wd.x + wd.w div 2
        if cx >= t.x0 and cx <= t.x1 and wd.text.strip.len > 0: parts.add wd
      parts.sort(proc (a, b: Word): int = cmp(a.x, b.x))
      var dirty = false
      for p in parts:
        # the pin and close icons OCR as stray glyphs
        if p.x > t.x1 - 46 and p.text.strip.len <= 2: continue
        # a file's tab: a short mark after its name is the unsaved-changes
        # dot (`●`, which the engine reads as `e`, `@` or `©`)
        if t.label.isSourceName and p.text.strip.len <= 2:
          dirty = true
          continue
        let s = p.text.strip(chars = {'|', '*', '#', '+', '~', '%', '&', '@', ' '})
        if s.len == 0 or (s.len == 1 and s[0] notin Letters): continue
        if t.label.len > 0: t.label.add " "
        t.label.add s
      if dirty: t.label.add " ●"
    # boxes: the body under each tab, followed to the ground around it
    var seen: seq[int]
    for t in tabs:
      let yb = t.y1 + 8
      if f.isGround(g, t.x0 + 2, yb): continue
      var l = t.x0 + 2
      while l > 0 and not f.isGround(g, l - 1, yb): dec l
      if l in seen: continue
      seen.add l
      var r = t.x0 + 2
      while r + 1 < w and not f.isGround(g, r + 1, yb): inc r
      var b = yb
      while b + 1 < footer + 4 and not f.isGround(g, l + 1, b + 1): inc b
      var box = PaneBox(left: l, right: r, top: t.y1 + 1, bottom: b, stripTop: y)
      for t2 in tabs:
        if t2.x0 >= l - 2 and t2.x0 < r: box.tabs.add t2
      result.add box
  result.sort(proc (a, b: PaneBox): int = cmp((a.stripTop, a.left), (b.stripTop, b.left)))

proc footerDocks(ctx: GuiContext; f: Frame): seq[PaneTab] =
  ## The footer's dock labels: the panes pinned to the window's bottom edge,
  ## each a label on its own small ground.
  let g = f.groundOf
  let y0 = f.image.height - FooterH
  let ym = y0 + FooterH div 2
  var x = 0
  var segs: seq[PaneTab]
  while x < f.image.width:
    if not f.isGround(g, x, ym) and f.isGround(g, x - 1, ym):
      let c = f.rgb(x + 1, ym - 8)
      if not near(c, g, 4):
        var x1 = x
        while x1 + 1 < f.image.width and not f.isGround(g, x1 + 1, ym - 8): inc x1
        if x1 - x >= 24 and x1 - x < 300: segs.add PaneTab(x0: x, x1: x1, y0: y0, y1: y0 + FooterH - 1)
        x = x1 + 1
        continue
    inc x
  if segs.len == 0: return
  let ws = ctx.wordsS(f, 0, y0, f.image.width, FooterH, psm = 11)
  for s in segs.mitems:
    var parts: seq[Word]
    for wd in ws:
      let cx = wd.x + wd.w div 2
      if cx >= s.x0 and cx <= s.x1: parts.add wd
    parts.sort(proc (a, b: Word): int = cmp(a.x, b.x))
    for p in parts:
      if s.label.len > 0: s.label.add " "
      s.label.add p.text.strip
    if s.label.len > 0: result.add s

proc textRows(ws: seq[Word]): seq[TextRow] =
  ## Words grouped into the rows they are drawn on.
  var ws = ws
  ws.sort(proc (a, b: Word): int = cmp(a.y + a.h div 2, b.y + b.h div 2))
  for wd in ws:
    let cy = wd.y + wd.h div 2
    if result.len > 0 and abs(cy - (result[^1].y0 + result[^1].y1) div 2) <= max(6, wd.h * 6 div 10):
      result[^1].words.add wd
      result[^1].y0 = min(result[^1].y0, wd.y)
      result[^1].y1 = max(result[^1].y1, wd.y + wd.h)
    else:
      result.add TextRow(y0: wd.y, y1: wd.y + wd.h, words: @[wd])
  for r in result.mitems:
    r.words.sort(proc (a, b: Word): int = cmp(a.x, b.x))
    r.x0 = r.words[0].x
    r.x1 = r.words[^1].x + r.words[^1].w
    for wd in r.words:
      if r.text.len > 0: r.text.add " "
      r.text.add wd.text

proc bodyRows(ctx: GuiContext; f: Frame; b: PaneBox; top = 0): seq[TextRow] =
  let t = (if top > 0: top else: b.top)
  # the right edge is the list's scrubber, whose thumb reads as a glyph
  for r in textRows(ctx.wordsL(f, b.left + 2, t, b.right - b.left - 16, b.bottom - t)):
    var row = r
    row.ground = f.rgb(b.left + 3, (r.y0 + r.y1) div 2)
    result.add row

proc bodyGround(f: Frame; b: PaneBox): (int, int, int) =
  ## The body's own ground: the commonest colour down its left inset.
  var counts = initCountTable[int]()
  for y in b.top ..< b.bottom:
    let (r, g, bb) = f.rgb(b.left + 1, y)
    counts.inc (r shl 16) or (g shl 8) or bb
  if counts.len == 0: return (40, 40, 40)
  let k = counts.largest.key
  ((k shr 16) and 255, (k shr 8) and 255, k and 255)

proc normLabel(s: string): string =
  ## A strip tab's caption as the pack names the pane: the window draws the
  ## desktop's caption (`CALLTRACE`, `EVENT LOG`), which is the pane's own
  ## name (`Call Trace`, `Event Log`) by the product's caption rule
  ## (`pane_names.desktopTabTitle`), read back here.
  let drawn = s.toUpperAscii.splitWhitespace.join(" ")
  for k in PaneKind:
    if desktopTabTitle(k) == drawn or desktopTabTitle(k).replace(" ", "") == drawn.replace(" ", ""):
      return gpuiPaneName(k)
  drawn

proc rowNode(role: string; b: PaneBox; r: TextRow; props: JsonNode;
             keys: seq[(string, string)]): SurfaceNode =
  result = node(role, fl(b.left), fl(r.y0 - 3), fl(b.right - b.left), fl(r.y1 - r.y0 + 6), props, keys)
  # where its text is drawn, for the `text-start` / `text-end` / `expander`
  # anchors
  result.props["$x0"] = %r.x0
  result.props["$x1"] = %r.x1

proc addPaneTabs(t: var Tree; boxes: seq[PaneBox]; docks: seq[PaneTab]) =
  for b in boxes:
    for tab in b.tabs:
      if tab.label.len == 0: continue
      let lbl = if tab.label.split(' ')[0].isSourceName: tab.label else: tab.label.normLabel
      t.add(t.root, node("pane-tab", fl(tab.x0), fl(tab.y0), fl(tab.x1 - tab.x0 + 1),
                         fl(tab.y1 - tab.y0 + 1), %*{"label": lbl, "active": tab.active},
                         @[("label", lbl)]))
  for d in docks:
    let lbl = d.label.toUpperAscii.splitWhitespace.join(" ")
    t.add(t.root, node("dock-label", fl(d.x0), fl(d.y0), fl(d.x1 - d.x0 + 1), fl(d.y1 - d.y0 + 1),
                       %*{"label": lbl}, @[("label", lbl)]))

proc activeLabel(b: PaneBox): string =
  for t in b.tabs:
    if t.active: return t.label.normLabel
  # a docked pane revealed over the window: its strip is one chip naming it
  for t in b.tabs:
    if t.label.len > 0: return t.label.normLabel
  ""

proc highlighted(f: Frame; b: PaneBox; r: TextRow; ground: (int, int, int)): bool =
  ## A row drawn on a ground of its own (the selected or current row): its
  ## ground differs from the body's at both ends of the row.
  let cy = (r.y0 + r.y1) div 2
  let a = f.rgb(b.left + 3, cy)
  let z = f.rgb(b.right - 12, cy)
  not near(a, ground, 3) and near(a, z, 6)

proc readCallTrace(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox) =
  let ground = f.bodyGround(b)
  # the search field is the body's first band; the rows are below it
  let rows = ctx.bodyRows(f, b, b.top + 34)
  let pane = node("call-trace", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"count": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  t.add(t.root, pane)
  var indents: seq[int]
  var calls: seq[(TextRow, string, string)]
  for r in rows:
    # `<toggle> callee #i (arguments) => return`: the callee is what stands
    # before the `#i` (`<end of program>` is several words), after the toggle
    var name = ""
    let toks = r.text.splitWhitespace
    var hashAt = -1
    for i, tk in toks:
      if hashAt < 0 and i > 0 and tk.len >= 2 and tk[0] == '#': hashAt = i
    if hashAt > 0:
      var nameToks = toks[0 ..< hashAt]
      if nameToks.len > 1 and nameToks[0].len <= 2: nameToks.delete(0)
      name = nameToks.join(" ")
    else:
      let (ok, parsed) = parseCallRow(r.text)
      if not ok: continue
      name = parsed
    if name.len == 0: continue
    # the arguments as drawn, with the return after them (`(left=2, right=3) => 5`)
    var args = ""
    let o = r.text.find('(')
    if o >= 0: args = r.text[o .. ^1].strip
    calls.add (r, name, args)
    if r.x0 notin indents: indents.add r.x0
  indents.sort()
  for (r, name, args) in calls:
    var depth = 0
    for i, x in indents:
      if abs(x - r.x0) <= 3:
        depth = i
        break
    let cur = f.highlighted(b, r, ground)
    let n = rowNode("call", b, r, %*{"name": name, "arguments": args, "current": cur,
                                     "depth": depth, "text": r.text},
                    @[("name", name)])
    n.unreadable["selected"] = "the selected call and the current call are drawn alike"
    t.add(pane, n)
  pane.props["count"] = %calls.len

proc readEventLog(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox) =
  ## The event log's table: the header names its columns (`tick`, `#`,
  ## `output`), and each row's output is the text under `output` — read by
  ## column, because a single OCR'd digit in the `#` column is not trusted.
  let ground = f.bodyGround(b)
  let rows = ctx.bodyRows(f, b)
  let pane = node("event-log", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"count": 0, "total": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  pane.unreadable["search"] = "the search field's text is not read by this binding"
  t.add(t.root, pane)
  var outputX = -1
  var tickX = -1
  var headerBottom = -1
  for r in rows:
    var o, tk = -1
    for wd in r.words:
      let low = wd.text.toLowerAscii
      if low.startsWith("output"): o = wd.x
      if low == "tick": tk = wd.x
    if o >= 0 and tk >= 0:
      outputX = o
      tickX = tk
      headerBottom = r.y1
      break
  var n = 0
  for r in rows:
    let (okTotal, total) = parseFooterTotal(r.text)
    if okTotal:
      pane.props["total"] = %total
      continue
    if outputX < 0 or r.y0 <= headerBottom: continue
    var output = ""
    var tick = -1
    for wd in r.words:
      if wd.x >= outputX - 6:
        if output.len > 0: output.add " "
        output.add wd.text
      elif abs(wd.x - tickX) <= 24 and tick < 0:
        try: tick = parseInt(wd.text.strip(chars = {'|', '.', ',', ' '}))
        except ValueError: discard
    if output.len == 0: continue
    var kind = ""
    for ch in EventChannels:
      if output.startsWith(ch & ":") or output.startsWith(ch & " "):
        kind = ch
        output = output[ch.len + 1 .. ^1].strip
    let e = rowNode("event", b, r, %*{"text": output, "kind": kind, "tick": tick,
                                      "current": f.highlighted(b, r, ground)},
                    @[("text", output)])
    e.unreadable["future"] = "a future row is told by a dimmer colour, which this binding does not read"
    t.add(pane, e)
    inc n
  pane.props["count"] = %n

proc readVariables(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox) =
  let rows = ctx.bodyRows(f, b)
  let pane = node("variables", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"count": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  t.add(t.root, pane)
  var n = 0
  for r in rows:
    let (ok, name, value, typ) = splitVariableRow(r.text)
    if not ok: continue
    let v = rowNode("variable", b, r, %*{"name": name, "value": value, "type": typ},
                    @[("name", name)])
    v.unreadable["expanded"] = "an expanded value is told by its disclosure glyph"
    t.add(pane, v)
    inc n
  pane.props["count"] = %n

proc readFiles(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox) =
  let ground = f.bodyGround(b)
  let rows = ctx.bodyRows(f, b)
  let pane = node("filesystem", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"count": rows.len})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  t.add(t.root, pane)
  for r in rows:
    var words = r.words
    # the disclosure chevron and the folder/file icon OCR as stray glyphs
    while words.len > 1 and words[0].text.len <= 2:
      words.delete(0)
    var name = ""
    for wd in words:
      if name.len > 0: name.add " "
      name.add wd.text
    let kind = if name.isSourceName or name.contains('.'): "file" else: "folder"
    let n = rowNode("file-node", b, r, %*{"name": name, "kind": kind,
                                          "selected": f.highlighted(b, r, ground)},
                    @[("name", name)])
    n.unreadable["expanded"] = "a folder's open state is told by its chevron"
    t.add(pane, n)

proc readTerminalOutput(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox) =
  let rows = ctx.bodyRows(f, b)
  var lines: seq[string]
  for r in rows: lines.add r.text
  t.add(t.root, node("terminal-output", fl(b.left), fl(b.top), fl(b.right - b.left),
                     fl(b.bottom - b.top), %*{"text": lines, "count": lines.len}))

proc readGenericPane(ctx: GuiContext; f: Frame; t: var Tree; b: PaneBox; title: string) =
  let ground = f.bodyGround(b)
  let rows = ctx.bodyRows(f, b)
  var lines, tabs: seq[string]
  for r in rows: lines.add r.text
  for tab in b.tabs:
    if tab.label.len > 0: tabs.add(if tab.label.split(" ")[0].isSourceName: tab.label else: tab.label.normLabel)
  let pane = node("pane", fl(b.left), fl(b.top), fl(b.right - b.left), fl(b.bottom - b.top),
                  %*{"title": title, "text": lines, "count": rows.len, "tabs": tabs},
                  @[("title", title)])
  pane.unreadable["hbar"] = "the horizontal scrollbar is not read by this binding"
  t.add(t.root, pane)
  for r in rows:
    t.add(pane, rowNode("row", b, r, %*{"text": r.text, "selected": f.highlighted(b, r, ground)},
                        @[("text", r.text)]))

type Overlay = object
  x0, x1, y0, y1: int
  border: (int, int, int)

proc overlays(f: Frame; boxes: seq[PaneBox]): seq[Overlay] =
  ## What is drawn OVER the grid — a menu, the omnibox's results, a
  ## right-click menu, an event's content, a tooltip: a rectangle with a
  ## one-pixel border of its own colour, which no pane box has (a box meets
  ## the ground directly; the focused box's outline runs along the box's own
  ## edges and is excluded).
  let w = f.image.width
  let h = f.image.height
  var seen: seq[Overlay]
  for y in TopBarH - 4 ..< h - 4:
    var x = 1
    while x < w - 80:
      let c = f.rgb(x, y)
      if near(c, f.rgb(x, y - 1), 3) or near(c, f.rgb(x, y + 1), 3):
        inc x
        continue
      var x1 = x
      while x1 + 1 < w and near(f.rgb(x1 + 1, y), c, 2) and
            not near(f.rgb(x1 + 1, y + 1), c, 3): inc x1
      if x1 - x < 80:
        x = x1 + 1
        continue
      # the left side (below a rounded corner, a few pixels further left):
      # down the border colour
      var lx = -1
      for dx in -10 .. 10:
        # a side that starts at this edge, not a line running on through it
        # (the focused box's outline)
        if lx < 0 and x + dx >= 0 and y + 10 < h and near(f.rgb(x + dx, y + 10), c, 2) and
           not near(f.rgb(x + dx, y - 2), c, 2): lx = x + dx
      if lx < 0:
        x = x1 + 1
        continue
      var y1 = y + 10
      while y1 + 1 < h and near(f.rgb(lx, y1 + 1), c, 2): inc y1
      if y1 - y < 14:
        x = x1 + 1
        continue
      let rx = x1 + (x - lx)
      var inside = false
      for o in seen:
        if x >= o.x0 - 2 and x <= o.x1 + 2 and y >= o.y0 - 2 and y <= o.y1 + 2: inside = true
      var isBox = false
      for b in boxes:
        if (abs(b.left - x) <= 3 and abs(b.right - x1) <= 3) or
           (abs(b.left - lx) <= 3 and abs(b.right - rx) <= 3): isBox = true
      # a pane's own bordered field (the search, the watch expression) is
      # one row on the pane's surface; what is drawn over the panes is taller
      # or on the window's ground
      let field = y1 - y < 40 and not near(f.rgb(lx + 6, y + 4), f.groundOf, 3) and
                  y > TopBarH + 4
      if not inside and not isBox and not field and not near(c, f.groundOf, 3):
        seen.add Overlay(x0: lx, x1: rx, y0: y, y1: y1, border: c)
      x = x1 + 1
  seen

proc textLuma(f: Frame; r: TextRow): int =
  ## The brightest ink of a row's words: an enabled entry is drawn brighter
  ## than a disabled one.
  for wd in r.words:
    for yy in wd.y ..< wd.y + wd.h:
      for xx in wd.x ..< wd.x + wd.w:
        if xx >= 0 and yy >= 0 and xx < f.image.width and yy < f.image.height:
          result = max(result, f.luma(xx, yy))

proc splitHint(r: TextRow): (string, string) =
  ## An entry's label and the hint drawn after it (a chord, a location),
  ## told apart by the wide gap between them.
  var label, hint = ""
  var lastRight = -1
  for wd in r.words:
    if hint.len == 0 and label.len > 0 and wd.x - lastRight > 24:
      hint = wd.text
    elif hint.len > 0:
      hint.add " " & wd.text
    else:
      if label.len > 0: label.add " "
      label.add wd.text
    lastRight = wd.x + wd.w
  (label, hint)

const OmnibarPlaceholderText = "Navigate to file or run a :command"

proc omniboxField(f: Frame): (int, int, int, int) =
  ## The omnibox's field in the top bar: the widest bordered box there.
  var best = (0, 0, 0, 0)
  for y in 2 ..< TopBarH div 2:
    var x = 1
    while x < f.image.width - 200:
      let c = f.rgb(x, y)
      if near(c, f.rgb(x, y - 1), 3):
        inc x
        continue
      var x1 = x
      while x1 + 1 < f.image.width and near(f.rgb(x1 + 1, y), c, 2): inc x1
      if x1 - x > 200 and x1 - x > best[1] - best[0]:
        var y1 = y
        while y1 + 1 < TopBarH and near(f.rgb(x, y1 + 1), c, 2): inc y1
        if y1 - y >= 14: best = (x, x1, y, y1)
      x = x1 + 1
  best

proc readOverlays(ctx: GuiContext; f: Frame; t: var Tree; boxes: seq[PaneBox]) =
  let w = f.image.width
  let h = f.image.height
  # the omnibox: its field's text (the placeholder is no query), then the
  # results drawn under it
  let (fx0, fx1, fy0, fy1) = f.omniboxField
  var omni: SurfaceNode = nil
  if fx1 > fx0:
    var q = ""
    for r in textRows(ctx.wordsS(f, fx0 + 22, fy0 + 2, fx1 - fx0 - 24, fy1 - fy0 - 3, psm = 7)):
      if q.len > 0: q.add " "
      q.add r.text
    # the caret, a bar between two characters, reads as `|`
    q = q.replace("|", "").strip
    if q.replace(" ", "") == OmnibarPlaceholderText.replace(" ", ""): q = ""
    omni = node("omnibox", fl(fx0), fl(fy0), fl(fx1 - fx0), fl(fy1 - fy0), %*{"query": q, "count": 0})
    omni.unreadable["focused"] = "the field draws the same border open or closed"
    t.add(t.root, omni)
  var level = 0
  for o in f.overlays(boxes):
    let rows = textRows(ctx.wordsL(f, o.x0 + 2, o.y0 + 2, o.x1 - o.x0 - 3, o.y1 - o.y0 - 3))
    if rows.len == 0: continue
    let big = (o.x1 - o.x0) * (o.y1 - o.y0) > (w * h) div 6
    if o.y0 <= TopBarH + 6 and omni != nil and o.x0 >= fx0 - 4 and o.x0 <= fx0 + 40:
      omni.props["count"] = %rows.len
      for r in rows:
        let (lbl, detail) = splitHint(r)
        let sel = not near(f.rgb(o.x0 + 4, (r.y0 + r.y1) div 2), f.rgb(o.x1 - 4, o.y1 - 4), 3)
        t.add(omni, node("option", fl(o.x0), fl(r.y0 - 3), fl(o.x1 - o.x0), fl(r.y1 - r.y0 + 6),
                         %*{"label": lbl, "detail": detail, "selected": sel}, @[("label", lbl)]))
    elif o.y0 <= TopBarH + 6 and o.x0 < w div 3:
      # the program menu: one dropdown per level, left to right
      inc level
      let d = node("dropdown", fl(o.x0), fl(o.y0), fl(o.x1 - o.x0), fl(o.y1 - o.y0),
                   %*{"level": level, "count": rows.len}, @[("level", $level)])
      t.add(t.root, d)
      let ground = f.rgb(o.x1 - 3, o.y1 - 3)
      for r in rows:
        let (lbl, hint) = splitHint(r)
        let sel = not near(f.rgb(o.x0 + 3, (r.y0 + r.y1) div 2), ground, 3)
        let it = node("dropdown-item", fl(o.x0), fl(r.y0 - 3), fl(o.x1 - o.x0), fl(r.y1 - r.y0 + 6),
                      %*{"label": lbl, "shortcut": hint, "selected": sel}, @[("label", lbl)])
        it.unreadable["folder"] = "a folder's arrow is not read by this binding"
        t.add(d, it)
    elif big:
      var lines: seq[string]
      for r in rows[1 .. ^1]: lines.add r.text
      t.add(t.root, node("popup", fl(o.x0), fl(o.y0), fl(o.x1 - o.x0), fl(o.y1 - o.y0),
                         %*{"title": rows[0].text, "text": lines}))
    else:
      # a right-click menu: its entries, the enabled ones drawn brighter
      var bright = 0
      for r in rows: bright = max(bright, f.textLuma(r))
      let m = node("context-menu", fl(o.x0), fl(o.y0), fl(o.x1 - o.x0), fl(o.y1 - o.y0),
                   %*{"count": rows.len})
      t.add(t.root, m)
      for r in rows:
        let (label, hint) = splitHint(r)
        let enabled = f.textLuma(r) >= bright - 40
        t.add(m, node("menu-item", fl(o.x0), fl(r.y0 - 3), fl(o.x1 - o.x0), fl(r.y1 - r.y0 + 6),
                      %*{"label": label, "enabled": enabled, "shortcut": hint}, @[("label", label)]))

proc statusMessage(ctx: GuiContext; f: Frame; docks: seq[PaneTab]): string =
  ## The status line's note: the footer's words right of its docked labels
  ## and left of the replay's location.
  let y0 = f.image.height - FooterH
  var left = f.image.width div 5
  for d in docks: left = max(left, d.x1 + 8)
  var right = f.image.width
  let ws = ctx.wordsS(f, 0, y0, f.image.width, FooterH, psm = 11)
  for w in ws:
    let c = w.text.rfind(':')
    if w.text.contains('/') and c > 0: right = min(right, w.x)
  var parts: seq[Word]
  for w in ws:
    if w.x >= left and w.x + w.w <= right: parts.add w
  parts.sort(proc (a, b: Word): int = cmp(a.x, b.x))
  for p in parts:
    if result.len > 0: result.add " "
    result.add p.text

proc readPanes(ctx: GuiContext; f: Frame; t: var Tree) =
  ## The boxes' strips (pane tabs), the footer's docked labels, and the
  ## active pane of every box that is not the editor.
  let boxes = ctx.paneBoxes(f)
  let docks = ctx.footerDocks(f)
  t.addPaneTabs(boxes, docks)
  for n in t.kids(t.root):
    if n.role == "status-line": n.props["message"] = %ctx.statusMessage(f, docks)
  for b in boxes:
    var label = b.activeLabel
    if label.len == 0: continue
    if label.toLowerAscii.split(" ")[0].isSourceName:
      # the editor: its own role above; its box is also a pane by its title
      for tab in b.tabs:
        if tab.active: ctx.readGenericPane(f, t, b, tab.label)
      # the in-document find, when open: a field over the editor's first row,
      # its query then `n of m`
      let ws = ctx.wordsS(f, b.left + 8, b.top + 2, b.right - b.left - 16, 30, psm = 7)
      var at = -1
      for i in 1 ..< ws.len - 1:
        if ws[i].text == "of" and ws[i - 1].text.allCharsInSet(Digits) and
           ws[i + 1].text.allCharsInSet(Digits): at = i
      if at >= 0:
        var q = ""
        for wd in ws[0 ..< at - 1]:
          if q.len > 0: q.add " "
          q.add wd.text
        q = q.strip(leading = false, chars = {'|', ' '})
        let fw = node("find-field", fl(b.left), fl(b.top), fl(b.right - b.left), 30,
                      %*{"query": q, "count": ws[at - 1].text & " of " & ws[at + 1].text})
        t.add(t.root, fw)
      continue
    case label
    of "Call Trace": ctx.readCallTrace(f, t, b)
    of "Event Log": ctx.readEventLog(f, t, b)
    of "Variables": ctx.readVariables(f, t, b)
    of "Files": ctx.readFiles(f, t, b)
    of "Terminal Output": ctx.readTerminalOutput(f, t, b)
    else: discard
    # every box is also a pane by its title, its rows as drawn
    ctx.readGenericPane(f, t, b, label)
  ctx.readOverlays(f, t, boxes)
  # the program menu's root button: the first mark in the top bar, at its
  # left end (an icon; the pack calls it "Menu")
  block menuButton:
    let runs = inkRuns(f, 6, TopBarH - 6, 0, 80)
    if runs.len == 0: break menuButton
    var x0 = runs[0][0]
    var x1 = runs[0][1]
    for r in runs[1 .. ^1]:
      if r[0] - x1 <= 6: x1 = r[1]
    let bar = node("menu-bar", 0, 0, fl(f.image.width), fl(TopBarH))
    t.add(t.root, bar)
    let m = node("menu", fl(x0 - 4), 4, fl(x1 - x0 + 8), fl(TopBarH - 8),
                 %*{"label": "Menu"}, @[("label", "Menu")])
    m.unreadable["open"] = "whether the menu is open is read from its dropdown"
    t.add(bar, m)
  # the editor's gutter marks: a breakpoint is a red dot left of the line's
  # number (the execution pointer, yellow, is read by `pointerRow`)
  for ed in t.kids(t.root):
    if ed.role != "editor": continue
    for ln in t.kids(ed):
      if ln.role != "line": continue
      var red = false
      let left = int(ed.x)
      for y in int(ln.y) ..< int(ln.y + ln.h):
        for x in left ..< left + 70:
          if x >= f.image.width or y < 0 or y >= f.image.height: continue
          let (cr, cg, cb) = f.rgb(x, y)
          if cr > 170 and cg < 110 and cb < 110 and cr - cg > 90: red = true
      ln.props["breakpoint"] = %red
  # where the replay is, from the status line's location (`main.py:1#123`)
  var loc = ""
  for n in t.kids(t.root):
    if n.role == "status-line": loc = n.props{"location"}.getStr
  let hash = loc.rfind('#')
  if hash > 0 and hash + 1 < loc.len and loc[hash + 1 .. ^1].allCharsInSet(Digits):
    let rp = node("replay-position", 0, fl(f.image.height - FooterH), fl(f.image.width), fl(FooterH),
                  %*{"tick": parseInt(loc[hash + 1 .. ^1])})
    rp.unreadable["total"] = "the window does not draw the recording's last tick"
    rp.unreadable["paused"] = "the window draws no paused state"
    t.add(t.root, rp)
  if getEnv("CT_GUI_BINDING_DEBUG").len > 0:
    for b in boxes:
      var ls: seq[string]
      for tab in b.tabs: ls.add tab.label & (if tab.active: "*" else: "")
      stderr.writeLine "box ", b.left, "..", b.right, " x ", b.top, "..", b.bottom, " ", ls.join(" | ")
    for d in docks: stderr.writeLine "dock ", d.label, " ", d.x0, "..", d.x1

proc readSurface*(ctx: GuiContext; f: Frame): Tree =
  result.root = node("window", 0, 0, fl(f.image.width), fl(f.image.height), %*{"mode": "debug"})
  result.root.visible = true
  result.root.unreadable["title"] = "the window title is not drawn in the window"
  result.root.unreadable["pointer"] = "the pointer is drawn by the X server, not in the window's pixels"
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
    if caret == 0 and ctx.running:
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
  ctx.readPanes(f, result)

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["mode", "pointer"], "affordances": []},
    "session-strip": {"properties": ["count"], "affordances": []},
    "session-tab": {"properties": ["title"], "affordances": ["click", "context-click"]},
    "editor": {"properties": ["file", "active", "focused", "current-line", "caret-line",
                              "first-visible", "last-visible"],
               "affordances": ["click", "context-click", "wheel", "focusable", "text-entry"]},
    "line": {"properties": ["number", "text", "current", "caret", "breakpoint"],
             "affordances": ["click", "double-click", "context-click"]},
    "status-line": {"properties": ["location", "message"], "affordances": []},
    # --- gpui batch ---
    "pane-tab": {"properties": ["label", "active"],
                 "affordances": ["click", "context-click", "drag-source"]},
    "dock-label": {"properties": ["label"], "affordances": ["click", "context-click"]},
    "call-trace": {"properties": ["count"], "affordances": ["wheel"]},
    "call": {"properties": ["name", "arguments", "current", "depth"],
             "affordances": ["click", "double-click", "context-click"]},
    "event-log": {"properties": ["count", "total"], "affordances": ["wheel"]},
    "event": {"properties": ["text", "kind", "current"],
              "affordances": ["click", "double-click", "context-click"]},
    "variables": {"properties": ["count"], "affordances": ["wheel"]},
    "variable": {"properties": ["name", "type", "value"],
                 "affordances": ["click", "double-click", "context-click"]},
    "filesystem": {"properties": ["count"], "affordances": ["wheel"]},
    "file-node": {"properties": ["name", "kind", "selected"],
                  "affordances": ["click", "double-click", "context-click"]},
    "terminal-output": {"properties": ["text", "count"], "affordances": ["wheel"]},
    "pane": {"properties": ["title", "text", "count", "tabs"],
             "affordances": ["click", "wheel", "context-click"]},
    "row": {"properties": ["text", "selected"],
            "affordances": ["click", "double-click", "context-click"]},
    "replay-position": {"properties": ["tick"], "affordances": []},
    "context-menu": {"properties": ["count"], "affordances": []},
    "menu-item": {"properties": ["label", "enabled", "shortcut"], "affordances": ["click"]},
    "popup": {"properties": ["title", "text"], "affordances": ["click"]},
    "omnibox": {"properties": ["query", "count"], "affordances": ["click"]},
    "option": {"properties": ["label", "detail", "selected"], "affordances": ["click"]},
    "dropdown": {"properties": ["level", "count"], "affordances": []},
    "dropdown-item": {"properties": ["label", "shortcut", "selected"], "affordances": ["click"]},
    "menu-bar": {"properties": [], "affordances": []},
    "menu": {"properties": ["label"], "affordances": ["click"]},
    "find-field": {"properties": ["query", "count"], "affordances": []}}

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
      of "ready": some(ctx.paneBoxes(f).len > 0)
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
      if n.role != "line":
        # a row of a pane: its text's ends, and a call's toggle before it
        let midY = int(n.y + n.h / 2)
        let x0 = n.props{"$x0"}.getInt(-1)
        let x1 = n.props{"$x1"}.getInt(-1)
        if x0 < 0: return none((int, int))
        case anchor
        of "text-start": return some((x0 + 3, midY))
        of "text-end": return some((max(x0 + 3, x1 - 3), midY))
        of "expander": return some((x0 + 6, midY))
        else: return none((int, int))
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
      of "text-end":
        # the last ink of the line's text (the editor's own right edge excepted)
        var textRight = textLeft
        for r in runs:
          if r[1] < int(n.x + n.w) - 14: textRight = r[1]
        some((max(textLeft + 3, textRight - 3), midY))
      else:
        # `column(c)`: the c-th character, at the code face's advance
        # (Space Mono at 16 px: 9.792 px, measured by the window's own font
        # report)
        if anchor.startsWith("column(") and anchor.endsWith(")"):
          try:
            let c = parseInt(anchor[7 ..< anchor.len - 1])
            some((left + int(float(c - 1) * 9.792 + 4.5), midY))
          except ValueError: none((int, int))
        else: none((int, int)))
