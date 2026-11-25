## ct_zgui_binding.nim — CodeTracer's GuiAssert binding for the zgui window
## (`codetracer-zgui`, `ct replay --ui=zgui`): the zgui flavour of the
## CodeTracer scenario pack (`../../pack/codetracer.pack.yaml`), for
## DemoVideoScript-GuiAssert.
##
## Like the GPUI binding beside it (`ct_gui_binding.nim`), the window is read
## by VISION and nothing else — GuiAssert's capture of the pixels and its OCR
## engine — and driven by OS-level input on the adapter's private X display
## (zgui's winit platform runs on X11 there). The window cooperates in
## nothing: no element tree, no test channel, no `--facts-out`.
##
## What is read follows zgui's own stylesheet (`src/frontend/zgui/app/
## zgui_leaves.nim`, the vocabulary's and the top bar's), whose measures are
## the window's:
##
## * a pane group (`.ct-tabs`) is a box with a 1 px `#3c3c3c` border, a tab
##   strip on `#252526` at its top, and its body on the editor ground; the
##   tab in front is drawn on the ground. A group is found by its strip, and
##   named by the tab in front.
## * the editor (its tab names the file it shows) draws 20 px rows: a 64 px
##   gutter — the execution pointer's `▶` in `#ffcc00`, a mark, the line
##   number right-aligned — then the code. The line numbers are read as a
##   column and checked against each other, because a single OCR'd digit is
##   not trusted on its own: the rows are consecutive, so the first visible
##   line is the one most rows agree on.
## * the call trace is a list (`name #index(arguments) => return`, indented
##   by depth), the event log a table under its `tick # kind output` header,
##   the Variables pane a tree of `name: value` rows — the vocabulary's rows,
##   parsed with the screen oracle's grammar (`pane_grammar`).
##
## * Stages: the pack's one implementation (`../../stages/ct_stages.nim`);
##   `open-recording` starts `codetracer-zgui` on the recording.
## * Conditions: `replay-idle` — the editor draws the execution pointer.
## * The binding resolver: `../../resolver/ct_resolver.nim`, the shared keymap
##   router as a native window builds it (zgui receives keys, as GPUI does).
##
## What vision cannot read here is declared unreadable: a scenario that needs
## it is `unsupported` on this flavour, never answered from elsewhere.

import std/[algorithm, exitprocs, json, options, os, strutils, tables]
import demo_video_script_guiassert
import ../../stages/ct_stages
import ../../resolver/ct_resolver
import ../../../../frontend/viewmodel/keymap/[context_keys, keymap_router]
import ../../../../frontend/viewmodel/viewmodels/product_mode
import ../../../../common/key_names
import ../../../visual/screen_oracle/pane_grammar

proc zguiBinary*(): string =
  ## The zgui front-end: `CODETRACER_ZGUI_BIN` (what `ct replay --ui=zgui`
  ## also honours), else `just build-zgui`'s.
  result = getEnv("CODETRACER_ZGUI_BIN")
  if result.len == 0: result = repo() / "build" / "bin" / "codetracer-zgui"
  if not fileExists(result):
    raise newException(IOError, "the zgui front-end is not built at " & result &
      " (just build-zgui)")

var stageStates = initTable[string, StageState]()

proc removeStageRoots() {.noconv.} =
  for _, s in stageStates: s.removeStage()

proc stageState(ctx: GuiContext): StageState =
  if not ctx.state.hasKey("$stage"):
    let s = newStageState()
    ctx.state["$stage"] = %s.root
    if stageStates.len == 0: addExitProc(removeStageRoots)
    stageStates[s.root] = s
  stageStates[ctx.state["$stage"].getStr]

const
  CellW = 8                ## a terminal cell, as the window's pixels
  CellH = 20
  MaxCells = 400

proc windowSize(width, height: int): (int, int) =
  ## The window's size for the stage's `width` × `height`: a size small
  ## enough to be a terminal's is that many cells of 8 × 20 px (the GPUI
  ## binding's rule), so the terminal's 200 × 50 is 1600 × 1000 here too.
  var w = if width > 0: width else: 1600
  var h = if height > 0: height else: 1000
  if w <= MaxCells and h <= MaxCells:
    w *= CellW
    h *= CellH
  (min(w, 2000), min(h, 1500))

proc launchZgui(ctx: GuiContext; s: StageState) =
  if s.launch.recording.len == 0:
    raise newException(ValueError, "the zgui front-end opens recordings only " &
      "(`ct edit --ui=zgui` is refused by name)")
  let (w, h) = windowSize(s.launch.width, s.launch.height)
  var argv = @[zguiBinary(), "--width=" & $w, "--height=" & $h]
  if s.launch.keymap.len > 0: argv.add "--keymap=" & s.launch.keymap
  argv.add s.launch.recording
  for k, v in s.launch.env: ctx.env[k] = v
  ctx.env.del("LD_PRELOAD")
  # zgui draws through wgpu: on a display with no GPU, Mesa's software
  # Vulkan driver from the dev shell's runtime set (as `just test-zgui` does).
  let runtime = getEnv("CODETRACER_GPUI_RUNTIME_LIB_PATH")
  if getEnv("VK_ICD_FILENAMES").len == 0 and runtime.len > 0:
    for d in runtime.split(':'):
      let icd = d.parentDir / "share" / "vulkan" / "icd.d" / "lvp_icd.x86_64.json"
      if d.endsWith("/lib") and fileExists(icd):
        ctx.env["VK_ICD_FILENAMES"] = icd
        ctx.env["ZGUI_BACKENDS"] = "vulkan"
        break
  ctx.env.del("PROMPT_COMMAND")
  let cwd = getCurrentDir()
  setCurrentDir(s.launch.workDir)
  # The window is named after the recording (`<folder> — CodeTracer`).
  try: ctx.startApp(argv, "CodeTracer", 60_000, titleContains = true)
  finally: setCurrentDir(cwd)

# --- pixels -------------------------------------------------------------------------------

type Rgb = (int, int, int)

const
  Ground: Rgb = (40, 40, 40)         ## the editor ground, a pane body's and the tab in front
  StripGround: Rgb = (37, 37, 38)    ## `.ct-tabstrip`, `.ct-dock-strip`
  Border: Rgb = (60, 60, 60)         ## `.ct-tabs`' border
  PointerInk: Rgb = (255, 204, 0)    ## `.ct-ptr`'s `▶`
  RowPx = 20                         ## `EditorLinePx`
  GutterPx = 64                      ## `.ct-gutter`
  NumberLeftPx = 28                  ## after the pointer's and the mark's 14 px each

proc rgb(f: Frame; x, y: int): Rgb =
  let i = (y * f.image.width + x) * 3
  (ord(f.image.pixels[i]), ord(f.image.pixels[i + 1]), ord(f.image.pixels[i + 2]))

proc near(a, b: Rgb; tol = 3): bool =
  abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol and abs(a[2] - b[2]) <= tol

proc fl(i: int): float = float(i)

proc textImage(f: Frame; x, y, w, h: int; scale = 2): GrayImage =
  ## The region as the OCR engine reads best: gray, inverted (the window's
  ## text is light on dark), scaled up and smoothed.
  let x0 = clamp(x, 0, f.image.width - 1)
  let y0 = clamp(y, 0, f.image.height - 1)
  let ww = max(1, min(w, f.image.width - x0))
  let hh = max(1, min(h, f.image.height - y0))
  result = newImage(GrayImage, ww * scale, hh * scale)
  for yy in 0 ..< hh * scale:
    for xx in 0 ..< ww * scale:
      let l = f.luma(x0 + xx div scale, y0 + yy div scale)
      result.pixels[yy * ww * scale + xx] = char(255 - l)
  result = smooth(result, 1)

proc words(ctx: GuiContext; f: Frame; x, y, w, h: int; psm = 6): seq[Word] =
  ## The words in a region, in frame pixels.
  const scale = 2
  for wd in ctx.recognize(textImage(f, x, y, w, h, scale), psm):
    var m = wd
    m.x = x + wd.x div scale
    m.y = y + wd.y div scale
    m.w = wd.w div scale
    m.h = wd.h div scale
    if m.text.strip.len > 0: result.add m

type TextRow = object
  y0, y1, x0, x1: int
  text: string
  words: seq[Word]

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

# --- the window's parts ------------------------------------------------------------------

type
  Tab = object
    label: string
    x0, x1: int
    active: bool

  Group = object
    ## One `.ct-tabs` box: its strip's rows, its body, its tabs.
    left, right: int           ## inside the border
    stripTop, stripBottom: int
    bodyBottom: int
    tabs: seq[Tab]

proc stripRuns(f: Frame; y: int): seq[(int, int)] =
  ## The runs of the strip's colour on row `y`, 24 px or longer.
  var x = 0
  let w = f.image.width
  while x < w:
    if near(f.rgb(x, y), StripGround, 1):
      var e = x
      while e + 1 < w and near(f.rgb(e + 1, y), StripGround, 1): inc e
      if e - x + 1 >= 24: result.add (x, e)
      x = e + 1
    else: inc x

proc groups(ctx: GuiContext; f: Frame): seq[Group] =
  ## The pane groups: each found by a band of strip-coloured rows 20-34 px
  ## tall that starts under a border row, widened to the borders either side.
  let h = f.image.height
  var y = 1
  var seen: seq[(int, int, int)]      # (top, left, right) of strips found
  while y < h - 18:
    for (a, b) in f.stripRuns(y):
      # the strip's top row: the row above is a border (or the top bar's edge)
      if not near(f.rgb((a + b) div 2, y - 1), Border, 4): continue
      var dup = false
      for (t, l, r) in seen:
        if t == y and a >= l and b <= r: dup = true
      if dup: continue
      var bottom = y
      let mid = (a + b) div 2
      while bottom + 1 < h and near(f.rgb(mid, bottom + 1), StripGround, 1): inc bottom
      let tall = bottom - y + 1
      if tall < 18 or tall > 36: continue
      # widen to the group's borders: the tab in front is drawn on the
      # ground, so the strip's colour does not run the whole width
      var left = a
      while left > 0 and not near(f.rgb(left - 1, y + 2), Border, 4): dec left
      var right = b
      while right + 1 < f.image.width and not near(f.rgb(right + 1, y + 2), Border, 4): inc right
      var bodyBottom = bottom + 1
      while bodyBottom + 1 < h and not near(f.rgb(left + 2, bodyBottom + 1), Border, 4) and
            not near(f.rgb(left + 2, bodyBottom + 1), StripGround, 1):
        inc bodyBottom
      seen.add (y, left, right)
      var g = Group(left: left, right: right, stripTop: y, stripBottom: bottom,
                    bodyBottom: bodyBottom)
      # the tabs: the strip's words, a gap wider than a space between two
      # labels; the one in front is the one drawn on the ground
      var ws = ctx.words(f, left, y, right - left + 1, tall, psm = 7)
      ws.sort(proc (p, q: Word): int = cmp(p.x, q.x))
      for wd in ws:
        if g.tabs.len > 0 and wd.x - g.tabs[^1].x1 <= 10:
          g.tabs[^1].label.add " " & wd.text
          g.tabs[^1].x1 = wd.x + wd.w
        else:
          g.tabs.add Tab(label: wd.text, x0: wd.x, x1: wd.x + wd.w)
      # the tab in front is on the ground (40, 40, 40), the others on the
      # strip (37, 37, 38): three levels apart, so told apart exactly
      for t in g.tabs.mitems:
        t.active = near(f.rgb(max(left, t.x0 - 4), y + tall div 2), Ground, 0)
      result.add g
    inc y

proc activeTab(g: Group): string =
  for t in g.tabs:
    if t.active: return t.label
  ""

proc labelIs(label, want: string): bool =
  ## A tab's label as OCR read it against a pane's name: the engine joins
  ## the words of a short label now and then (`EventLog`).
  label.toLowerAscii.replace(" ", "") == want.toLowerAscii.replace(" ", "")

proc isSourceName(t: string): bool =
  let dot = t.rfind('.')
  dot > 0 and dot < t.len - 1 and t[dot + 1 .. ^1].allCharsInSet(Letters) and
    t[dot + 1 .. ^1].len <= 5 and not t.contains(' ')

proc rowNode(role: string; g: Group; r: TextRow; props: JsonNode;
             keys: seq[(string, string)]): SurfaceNode =
  result = node(role, fl(g.left), fl(r.y0 - 3), fl(g.right - g.left), fl(r.y1 - r.y0 + 6), props, keys)
  result.props["$x0"] = %r.x0
  result.props["$x1"] = %r.x1

proc bodyRows(ctx: GuiContext; f: Frame; g: Group; top = -1): seq[TextRow] =
  ## The body's text, row by row; a row the body's bottom edge cuts through
  ## (its glyphs under 12 px tall) is not read.
  let t = if top >= 0: top else: g.stripBottom + 1
  for r in textRows(ctx.words(f, g.left + 2, t, g.right - g.left - 4, g.bodyBottom - t)):
    if r.y1 - r.y0 >= 12 or r.y1 < g.bodyBottom - 4: result.add r

proc highlighted(f: Frame; g: Group; r: TextRow): bool =
  ## A row drawn on a ground of its own (the selected or current row).
  let cy = (r.y0 + r.y1) div 2
  let c = f.rgb(g.left + 8, cy)
  not near(c, Ground, 2) and not near(c, Border, 2)

# --- the editor ------------------------------------------------------------------------------

proc readEditor(ctx: GuiContext; f: Frame; t: var Tree; g: Group) =
  let file = g.activeTab
  let top = g.stripBottom + 1
  let rowCount = max(0, (g.bodyBottom - top + 1) div RowPx)
  # the line numbers, as one column, and the first line most rows agree on
  let numbers = ctx.words(f, g.left + NumberLeftPx, top, GutterPx - NumberLeftPx,
                          rowCount * RowPx)
  var votes = initCountTable[int]()
  for wd in numbers:
    let i = (wd.y + wd.h div 2 - top) div RowPx
    var n = 0
    try: n = parseInt(wd.text.strip(chars = {'|', '.', ',', ' ', ':'}))
    except ValueError: continue
    votes.inc(n - i)
  var first = 0
  if votes.len > 0: first = votes.largest.key
  # the code, read once as a block and given to the rows by height
  let code = textRows(ctx.words(f, g.left + GutterPx, top, g.right - g.left - GutterPx,
                                rowCount * RowPx))
  var current = 0
  var lines: seq[(int, int, string)]       # (number, y, text)
  for i in 0 ..< rowCount:
    let y = top + i * RowPx
    var ink = 0
    for x in g.left + 2 ..< g.left + 14:
      for yy in y + 5 ..< y + 15:
        if near(f.rgb(x, yy), PointerInk, 40): inc ink
    let number = if first > 0: first + i else: 0
    if ink >= 6 and number > 0: current = number
    var text = ""
    for r in code:
      let cy = (r.y0 + r.y1) div 2
      if cy >= y and cy < y + RowPx: text = r.text
    if number > 0: lines.add (number, y, text)
  let ed = node("editor", fl(g.left), fl(top), fl(g.right - g.left), fl(g.bodyBottom - top),
                %*{"file": file, "active": true, "current-line": current,
                   "first-visible": (if lines.len > 0: lines[0][0] else: 0),
                   "last-visible": (if lines.len > 0: lines[^1][0] else: 0)},
                @[("file", file)])
  ed.unreadable["caret-line"] = "the zgui window draws no caret in its editor"
  ed.unreadable["focused"] = "the zgui editor draws no mark of keyboard focus"
  t.add(t.root, ed)
  for (n, y, text) in lines:
    let ln = node("line", fl(g.left), fl(y), fl(g.right - g.left), fl(RowPx),
                  %*{"number": n, "text": text, "current": n == current},
                  @[("number", $n)])
    ln.props["$codeLeft"] = %(g.left + GutterPx)
    ln.unreadable["caret"] = "the zgui window draws no caret in its editor"
    t.add(ed, ln)

# --- the panes -------------------------------------------------------------------------------

proc readCallTrace(ctx: GuiContext; f: Frame; t: var Tree; g: Group) =
  let pane = node("call-trace", fl(g.left), fl(g.stripBottom + 1), fl(g.right - g.left),
                  fl(g.bodyBottom - g.stripBottom), %*{"count": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  t.add(t.root, pane)
  var indents: seq[int]
  var calls: seq[(TextRow, string, string)]
  for r in ctx.bodyRows(f, g):
    # `callee #i(arguments) => return`: the callee stands before ` #i`
    let hashAt = r.text.find(" #")
    var name = ""
    if hashAt > 0: name = r.text[0 ..< hashAt].strip
    else:
      let (ok, parsed) = parseCallRow(r.text)
      if not ok: continue
      name = parsed
    if name.len == 0: continue
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
    let n = rowNode("call", g, r, %*{"name": name, "arguments": args,
                                     "current": f.highlighted(g, r), "depth": depth},
                    @[("name", name), ("arguments", args)])
    n.unreadable["selected"] = "the selected call and the current call are drawn alike"
    n.unreadable["expanded"] = "the zgui call trace draws no disclosure glyph"
    t.add(pane, n)
  pane.props["count"] = %calls.len

proc readEventLog(ctx: GuiContext; f: Frame; t: var Tree; g: Group) =
  ## The table under its `tick # kind output` header: each row's output is
  ## the text under `output`, read by column.
  let pane = node("event-log", fl(g.left), fl(g.stripBottom + 1), fl(g.right - g.left),
                  fl(g.bodyBottom - g.stripBottom), %*{"count": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  pane.unreadable["total"] = "the zgui event log draws no footer"
  t.add(t.root, pane)
  let rows = ctx.bodyRows(f, g)
  var outputX, tickX, headerBottom = -1
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
    if outputX < 0 or r.y0 <= headerBottom: continue
    var output = ""
    var tick = -1
    var kind = ""
    for wd in r.words:
      if wd.x >= outputX - 6:
        if output.len > 0: output.add " "
        output.add wd.text
      elif abs(wd.x - tickX) <= 24 and tick < 0:
        try: tick = parseInt(wd.text.strip(chars = {'|', '.', ',', ' '}))
        except ValueError: discard
      elif wd.text in EventChannels: kind = wd.text
    if output.len == 0: continue
    let e = rowNode("event", g, r, %*{"text": output, "kind": kind, "tick": tick,
                                      "current": f.highlighted(g, r)},
                    @[("text", output)])
    e.unreadable["future"] = "a future row is not drawn apart in the zgui event log"
    t.add(pane, e)
    inc n
  pane.props["count"] = %n

proc readVariables(ctx: GuiContext; f: Frame; t: var Tree; g: Group) =
  let pane = node("variables", fl(g.left), fl(g.stripBottom + 1), fl(g.right - g.left),
                  fl(g.bodyBottom - g.stripBottom), %*{"count": 0})
  pane.unreadable["focused"] = "keyboard focus has no mark of its own on this pane"
  t.add(t.root, pane)
  var n = 0
  for r in ctx.bodyRows(f, g):
    let (ok, name, value, typ) = splitVariableRow(r.text)
    if not ok: continue
    let v = rowNode("variable", g, r, %*{"name": name, "value": value, "type": typ},
                    @[("name", name)])
    v.unreadable["expanded"] = "an expanded value is told by its disclosure glyph"
    t.add(pane, v)
    inc n
  pane.props["count"] = %n

proc readSurface*(ctx: GuiContext; f: Frame): Tree =
  result.root = node("window", 0, 0, fl(f.image.width), fl(f.image.height), %*{"mode": "debug"})
  result.root.visible = true
  result.root.unreadable["title"] = "the window title is not drawn in the window"
  for g in ctx.groups(f):
    for tab in g.tabs:
      result.add(result.root, node("pane-tab", fl(tab.x0), fl(g.stripTop), fl(tab.x1 - tab.x0),
                                   fl(g.stripBottom - g.stripTop + 1),
                                   %*{"label": tab.label, "active": tab.active},
                                   @[("label", tab.label)]))
    let label = g.activeTab
    if label.isSourceName: ctx.readEditor(f, result, g)
    elif label.labelIs("Call Trace"): ctx.readCallTrace(f, result, g)
    elif label.labelIs("Event Log"): ctx.readEventLog(f, result, g)
    elif label.labelIs("Variables"): ctx.readVariables(f, result, g)

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["mode"], "affordances": []},
    "pane-tab": {"properties": ["label", "active"], "affordances": ["click"]},
    "editor": {"properties": ["file", "active", "current-line", "first-visible", "last-visible"],
               "affordances": ["click", "wheel"]},
    "line": {"properties": ["number", "text", "current"], "affordances": []},
    "call-trace": {"properties": ["count"], "affordances": []},
    "call": {"properties": ["name", "arguments", "current", "depth"], "affordances": ["click"]},
    "event-log": {"properties": ["count"], "affordances": []},
    "event": {"properties": ["text", "kind", "current"], "affordances": ["click"]},
    "variables": {"properties": ["count"], "affordances": []},
    "variable": {"properties": ["name", "type", "value"], "affordances": []}}

proc ctZguiBinding*(): GuiBinding =
  GuiBinding(
    name: "codetracer-zgui",
    roles: roles(),
    stage: proc (ctx: GuiContext; use: string; args: JsonNode) =
      let s = ctx.stageState()
      s.runStage(use, args)
      if use == "open-recording": ctx.launchZgui(s),
    surface: proc (ctx: GuiContext; f: Frame): Tree = ctx.readSurface(f),
    condition: proc (ctx: GuiContext; f: Frame; name: string): Option[bool] =
      case name
      of "replay-idle":
        # the editor draws the execution pointer
        let t = ctx.readSurface(f)
        var stopped = false
        for n in t.kids(t.root):
          if n.role == "editor" and n.props{"current-line"}.getInt(0) > 0: stopped = true
        some(stopped)
      else: none(bool),
    resolveChord: proc (ctx: GuiContext; operation: string): Option[string] =
      let s = ctx.stageState()
      let router = routerFor(baseOf(s.launch.keymap),
                             KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                         keyProtocol: kpNative),
                             s.configDir / "keybindings.json")
      router.resolveChord(operation, ResolverScope(product: pmDebug, replayLoaded: true)),
    anchor: proc (ctx: GuiContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      let midY = int(n.y + n.h / 2)
      let x0 = n.props{"$x0"}.getInt(-1)
      let x1 = n.props{"$x1"}.getInt(-1)
      if x0 < 0: return none((int, int))
      case anchor
      of "text-start", "name": some((x0 + 3, midY))
      of "text-end": some((max(x0 + 3, x1 - 3), midY))
      else: none((int, int)))
