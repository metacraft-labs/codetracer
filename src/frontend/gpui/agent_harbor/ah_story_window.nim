## gpui/agent_harbor/ah_story_window.nim — CTF-P1b. A GPUI window showing ONE
## story of the `CodeTracer/Agent Harbor` StoryBook section, by its StoryBook
## id, in a colour mode and at a size: the window story host.
##
## StoryBook shows each story of the section in the browser, mounted by
## `storybook_components.mountCodeTracerStory`; this program is the same for
## GPUI. It opens a real window (`gpui_launch`, the windowed isonim-gpui shim)
## and mounts the story into it with `ah_stories.mountAgentHarborStoryGpui` —
## the same viewmodel constructors the web mount uses, so the window shows the
## state the web story shows, drawn by the GPUI views. A panel story is framed
## as the web frames it (a title tab over the panel); a view story is drawn
## bare, at the window's width.
##
## It is what the CTF-P1b capture path launches, one window per story, theme
## and size, on GuiAssert's headless sway (`ci/test/ctf-p1b-gpui-story-capture.sh`,
## after PLAT-35's `plat35-gpui-window-capture.sh`): GPUI has no headless
## renderer off macOS, so a GPUI capture on Linux is a window on a compositor.
##
## Command line:
##
##   codetracer-gpui-story --story=<storybook id> [--theme=dark|light]
##                         [--width=<px>] [--height=<px>]
##                         [--regions=<declaration.json> --regions-out=<file>]
##                         [--moment=<name>] [--quit-after-ms=<n>] [--list]
##   codetracer-gpui-story --story=<storybook id> --list-moments
##
## `--list` prints every story id of the section and exits. `--list-moments`
## prints the story's named moments (`storyMomentNames`), one a line in
## time order (nothing for a story that is not a playback story), and exits:
## the CTF-P1c capture path opens each of them with `--moment`. A playback story
## (`stories/agent_harbor_playback.nim`) plays on IsoNim's `RealClock`, with
## the host's playback bar under it (`ah_playback_bar.nim`: play / pause,
## step, the previous and next named moment, rewind, and where the playback
## is); `--moment` opens it at one of its named moments (`storyMomentNames`) instead of
## its first frame (an unknown name is a usage error naming the moments). The
## window's tick pumps the clock's timers. `--regions` names
## the region declaration (`src/tests/visual/agent-harbor-regions.json`): for
## each named region, which element of the GPUI views it is (the `data-ah-*`
## facts the element must carry). Every element so named is given the
## `data-layout-probe` attribute, so the shim records where the window laid it
## out (isonim-gpui `layout_bounds`), and once two consecutive ticks read the
## same bounds the regions are written to `--regions-out` as JSON, in window
## pixels, beside the viewport they were measured in. A region is the first
## element in document order carrying its facts, or, for `"pick":
## "last-whole"`, the last one drawn whole, its bottom edge inside the window
## (the last row of a list the window shows entirely). With `within`, only
## the matches drawn wholly inside the first element carrying `within`'s
## facts count: the rows a scrolling list shows. A region with a
## `pick` also reports its `index` among the matches laid out with an area,
## as the web capture does, so the layout test can tell the same row from
## another. A region with `gpuiValue` also reports that attribute's value on
## the element measured (`value`: the N of a `+N more` line, a list's
## total), and one with `gpuiCount` how many of its matches the window laid
## out with an area (`count`: the rows a list drew); the layout judge reads
## them as facts of GPUI's drawing (the control center's held overview). Beside
## the regions, `drawnCuts` lists every text the window drew
## cut (isonim-gpui's `drawnText`, ending in "…"), for the layout check's
## rule on cut texts. The web capture writes
## the same file from the browser's own layout (`capture-storybook.mjs
## --regions`), and the CTF-P1b layout test compares the two
## (`src/tests/visual/agent_harbor/test_ctf_p1b_gpui_capture_matches_web_layout.nim`).
##
## Exit codes: 0 the window ran and closed; 2 a bad command line or an unknown
## story; 3 no window can open (the featureless shim, or no graphical session:
## `window_preflight.nim`, the same refusal and code `codetracer-gpui` uses);
## 1 anything else, named on stderr.

import std/[json, os, strutils]

import isonim_gpui/window
import nim_everywhere/async_compat
from isonim_gpui/bindings import gpui_launch, gpui_has_window_backend,
  gpui_quit_after_ms, gpui_set_tick, gpui_layout_bounds_reset

import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../window_preflight
import ../design_fonts
import ../chrome
import ./ah_stories
from ../../viewmodel/views/agent_harbor_words import CutEllipsis

const
  SectionTitle = "CodeTracer/Agent Harbor"
  AppId = "codetracer-story"
    ## Its own app id, apart from the debugger's `codetracer`, so a
    ## compositor rule or a capture driver waiting for one never takes the
    ## other.
  ExitUsage = 2
  ExitNoWindow = 3
  TickMs = 100'u32
  DefaultWidth = 1440
  DefaultHeight = 900

type
  StoryCommand = object
    storyId, regionsDecl, regionsOut, moment: string
    mode: DesignMode
    width, height: int
    quitAfterMs: uint32
    list, listMoments: bool

  RegionPick = enum
    rpNone        ## no `pick`: the first match, and no index reported
    rpFirst       ## `"pick": "first"`: the first match, with its index
    rpLastWhole   ## `"pick": "last-whole"`: the last match the window shows whole

  RegionProbe = object
    ## One declared region: its name, the `data-ah-*` facts its element
    ## carries, how one of several matches is picked, and every element of
    ## the mounted story that carries them, in document order (empty: none).
    name: string
    facts: seq[(string, string)]
    pick: RegionPick
    elements: seq[GpuiElement]
    within: seq[(string, string)]
      ## `within`'s facts: only the matches drawn wholly inside the first
      ## element carrying them (a scrolling list) count; empty: every match.
    container: seq[GpuiElement]
      ## The element(s) carrying `within`'s facts, in document order.
    valueAttr: string
      ## `"gpuiValue"`: a `data-ah-*` attribute whose value, on the element
      ## measured, is reported beside its box (`"value"`): a count the view
      ## drew, such as a `+N more` line's N. Empty: none.
    count: bool
      ## `"gpuiCount"`: also report how many matches the window laid out
      ## with an area (`"count"`): the rows of a list the view drew.

  StoryWindow = object
    ## Everything the cdecl root builder and the tick need, which cannot be
    ## captured by a closure (`gpui_launch` takes a C callback).
    cmd: StoryCommand
    story: CodeTracerStory
    mount: AhStoryMount
    probes: seq[RegionProbe]
    lastRead: string
    stableReads: int
    written: bool
    builderCalls: int

var gWindow: StoryWindow

proc usage(): string =
  "usage: codetracer-gpui-story --story=<storybook id> [--theme=dark|light] " &
  "[--width=<px>] [--height=<px>] [--regions=<declaration.json> " &
  "--regions-out=<file>] [--moment=<name>] [--quit-after-ms=<n>] [--list] " &
  "[--list-moments]"

proc parseCommand(args: seq[string]): StoryCommand =
  ## Raises `ValueError` with the sentence to print for a bad command line.
  result = StoryCommand(mode: dmDark, width: DefaultWidth, height: DefaultHeight)
  proc positive(arg, name: string): int =
    try: result = parseInt(arg)
    except ValueError: raise newException(ValueError, name & " needs an integer, got " & arg)
    if result <= 0: raise newException(ValueError, name & " needs a positive number")
  for arg in args:
    let eq = arg.find('=')
    let (key, value) = if eq > 0: (arg[0 ..< eq], arg[eq + 1 .. ^1]) else: (arg, "")
    case key
    of "--story": result.storyId = value
    of "--theme":
      case value
      of "dark": result.mode = dmDark
      of "light": result.mode = dmLight
      else: raise newException(ValueError, "--theme is dark or light, got " & value)
    of "--width": result.width = positive(value, "--width")
    of "--height": result.height = positive(value, "--height")
    of "--regions": result.regionsDecl = value
    of "--regions-out": result.regionsOut = value
    of "--moment": result.moment = value
    of "--quit-after-ms": result.quitAfterMs = uint32(positive(value, "--quit-after-ms"))
    of "--list": result.list = true
    of "--list-moments": result.listMoments = true
    else: raise newException(ValueError, "unknown argument " & arg)
  if not result.list and result.storyId.len == 0:
    raise newException(ValueError, "--story is required")
  if (result.regionsDecl.len > 0) != (result.regionsOut.len > 0):
    raise newException(ValueError, "--regions and --regions-out go together")

proc agentHarborSection(): CodeTracerStorySection =
  for s in codeTracerStorySections():
    if s.title == SectionTitle: return s
  raise newException(ValueError, "no StoryBook section " & SectionTitle)

proc findStory(section: CodeTracerStorySection; id: string): CodeTracerStory =
  ## The story whose StoryBook id is `id` (the generator's own `storybookId`,
  ## so the id is the one StoryBook and the web captures use).
  for story in section.stories:
    if storybookId(section, story) == id: return story
  raise newException(ValueError, "no story " & id & " in " & SectionTitle &
                     " (--list prints them)")

# ---------------------------------------------------------------------------
# Regions
# ---------------------------------------------------------------------------

proc readDeclaration(path: string): seq[RegionProbe] =
  ## The declared regions' GPUI side: `regions[].name` and `regions[].gpui`,
  ## an object of `data-ah-*` attribute to required value ("" for any).
  let doc = parseJson(readFile(path))
  for region in doc["regions"]:
    var probe = RegionProbe(name: region["name"].getStr)
    for k, v in region["gpui"].pairs: probe.facts.add (k, v.getStr)
    probe.pick =
      case region{"pick"}.getStr
      of "": rpNone
      of "first": rpFirst
      of "last-whole": rpLastWhole
      else: raise newException(ValueError, path & ": region " & probe.name &
                               ": unknown pick " & region{"pick"}.getStr)
    if region.hasKey("within"):
      for k, v in region["within"]["gpui"].pairs: probe.within.add (k, v.getStr)
    probe.valueAttr = region{"gpuiValue"}.getStr
    probe.count = region{"gpuiCount"}.getBool
    if probe.name.len == 0 or probe.facts.len == 0:
      raise newException(ValueError, path & ": a region needs a name and gpui facts")
    result.add probe

proc matches(el: GpuiElement; facts: seq[(string, string)]): bool =
  for (attr, want) in facts:
    let have = getAttribute(el, attr)
    if have.len == 0 or (want.len > 0 and have != want): return false
  true

proc allMatches(node: GpuiElement; facts: seq[(string, string)];
                into: var seq[GpuiElement]) =
  ## Every element under `node` (itself included), in document order,
  ## carrying every fact — the order `document.querySelectorAll` answers in.
  if node.isNil: return
  if matches(node, facts): into.add node
  for i in 0 ..< childCount(node):
    allMatches(nthChild(node, i), facts, into)

proc readRegions(probes: seq[RegionProbe]; viewportHeight: int): JsonNode =
  ## The laid-out regions, or nil while the first match of a region has no
  ## bounds yet. A region whose element is absent, or laid out with no area,
  ## is left out: the web side leaves out an invisible element the same way.
  ## Of a picked region's matches, those after the first that no frame laid
  ## out are counted as not shown (a frame lays out the whole tree, so once
  ## the first has bounds the others' are in the same frame or never).
  result = newJObject()
  for probe in probes:
    if probe.elements.len == 0: continue
    var shown: seq[tuple[x, y, w, h: float; el: GpuiElement]]
    # `within`: the box of the container the matches must lie inside.
    var boxY, boxH = 0.0
    var hasBox = false
    for c in probe.container:
      var cx, cy, cw, ch: float
      if layoutBounds(c, cx, cy, cw, ch) and cw > 0 and ch > 0:
        boxY = cy
        boxH = ch
        hasBox = true
        break
    if probe.within.len > 0 and not hasBox: continue
    for i, el in probe.elements:
      var x, y, w, h: float
      if not layoutBounds(el, x, y, w, h):
        if i == 0: return nil
        continue
      if hasBox and (y < boxY - 0.5 or y + h > boxY + boxH + 0.5): continue
      if w > 0 and h > 0: shown.add (x, y, w, h, el)
      if probe.pick == rpNone and not probe.count and shown.len > 0: break
    var chosen = if shown.len > 0: 0 else: -1
    if probe.pick == rpLastWhole:
      chosen = -1
      for i, b in shown:
        if b.y + b.h <= float(viewportHeight): chosen = i
    if chosen < 0: continue
    let b = shown[chosen]
    result[probe.name] = %*{"x": b.x, "y": b.y, "w": b.w, "h": b.h}
    if probe.pick != rpNone: result[probe.name]["index"] = %chosen
    if probe.valueAttr.len > 0:
      result[probe.name]["value"] = %getAttribute(b.el, probe.valueAttr)
    if probe.count: result[probe.name]["count"] = %shown.len
    # A line of text the view says needs `text-px` (`textWidth`, the face's
    # kerned advances, as GPUI sets them) is cut when laid out narrower: GPUI
    # elides it (`text-overflow: ellipsis`). The web side measures its text
    # itself; the layout check compares the two (`elision`).
    let need = getAttribute(b.el, "data-ah-text-px")
    if need.endsWith("px"):
      try:
        result[probe.name]["cut"] = %(b.w + 0.01 < parseFloat(need[0 ..< ^2]))
      except ValueError: discard

proc drawnCuts(node: GpuiElement; into: var seq[string]) =
  ## Every text the window drew cut, in document order: what isonim-gpui's
  ## text element drew for each element that declares `text-overflow`
  ## (`drawnText`), where it ends in "…". The layout check holds each to the
  ## views' rule for a cut (`agent_harbor_words.danglesBeforeEllipsis`).
  if node.isNil: return
  let drawn = drawnText(node)
  if drawn.endsWith(CutEllipsis): into.add drawn
  for i in 0 ..< childCount(node): drawnCuts(nthChild(node, i), into)

proc writeRegions(regions: JsonNode; cuts: seq[string]) =
  let c = gWindow.cmd
  let doc = %*{
    "renderer": "gpui",
    "story": c.storyId,
    "theme": (if c.mode == dmDark: "dark" else: "light"),
    "viewport": {"width": c.width, "height": c.height},
    "regions": regions,
    "drawnCuts": cuts}
  createDir(parentDir(c.regionsOut))
  # Written beside the file and renamed into place, so the file appears
  # whole or not at all: a capture waits for it to exist and then ends the
  # window, and a file it saw half-written was left empty (a rename within
  # one directory is atomic, https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
  let partial = c.regionsOut & ".partial"
  writeFile(partial, pretty(doc) & "\n")
  moveFile(partial, c.regionsOut)
  echo "codetracer-gpui-story: regions written to ", c.regionsOut

proc pumpClock() =
  ## A playback story's real clock fires its timers through the platform's
  ## event loop, which nothing else in this process polls: drain what is
  ## due, so a playing story moves (its views and bar redraw from their
  ## render effects).
  if not gWindow.mount.playback.isNil: drainPlatformCallbacks()

proc regionTick() {.cdecl.} =
  ## Every `TickMs`: a playing story's clock is pumped; once two consecutive
  ## reads of the laid-out regions agree, they are the settled layout, and
  ## are written once.
  pumpClock()
  if gWindow.written or gWindow.probes.len == 0: return
  let regions = readRegions(gWindow.probes, gWindow.cmd.height)
  if regions.isNil: return
  var cuts: seq[string]
  drawnCuts(gWindow.mount.root, cuts)
  let read = $regions & $(%cuts)
  if read == gWindow.lastRead: inc gWindow.stableReads
  else:
    gWindow.lastRead = read
    gWindow.stableReads = 0
  if gWindow.stableReads >= 1:
    writeRegions(regions, cuts)
    gWindow.written = true
    if gWindow.mount.playback.isNil: gpui_set_tick(0, nil)

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------

proc buildStory(root: GpuiElement) {.cdecl.} =
  ## `gpui_launch`'s root builder: the story, mounted into the window's root.
  inc gWindow.builderCalls
  var r: GpuiRenderer
  let c = gWindow.cmd
  let story = gWindow.story
  let p = ahPalette(c.mode)
  r.setStyle(root, "display", "flex")
  r.setStyle(root, "flex-direction", "column")
  r.setStyle(root, "width", "100%")
  r.setStyle(root, "height", "100%")
  r.setStyle(root, "background-color", p.ground)
  r.setStyle(root, "color", p.textBody)
  r.setStyle(root, "font-family", WindowFontFamily)
  let frameTitle = if story.kind == "panel": frameTitleOf(story) else: ""
  gWindow.mount = r.mountAgentHarborStoryGpui(story.surface, story.fixture,
                                              c.width, c.height, c.mode, frameTitle,
                                              moment = c.moment)
  r.appendChild(root, gWindow.mount.root)
  for probe in gWindow.probes.mitems:
    probe.elements.setLen 0
    allMatches(gWindow.mount.root, probe.facts, probe.elements)
    # Only the first match is measured unless one of several is picked, or
    # the matches must lie inside a container (`within`).
    if probe.pick == rpNone and probe.within.len == 0 and not probe.count and
       probe.elements.len > 1:
      probe.elements.setLen 1
    for el in probe.elements:
      r.setAttribute(el, LayoutProbeAttribute, probe.name)
    probe.container.setLen 0
    if probe.within.len > 0:
      allMatches(gWindow.mount.root, probe.within, probe.container)
      for el in probe.container:
        if getAttribute(el, LayoutProbeAttribute).len == 0:
          r.setAttribute(el, LayoutProbeAttribute, probe.name & ":within")
  if gWindow.probes.len > 0:
    gpui_layout_bounds_reset()
  if gWindow.probes.len > 0 or not gWindow.mount.playback.isNil:
    gpui_set_tick(TickMs, regionTick)

proc run(cmd: StoryCommand): int =
  let section = agentHarborSection()
  if cmd.list:
    for story in section.stories: echo storybookId(section, story)
    return 0
  gWindow = StoryWindow(cmd: cmd, story: findStory(section, cmd.storyId))
  if cmd.listMoments:
    if isPlaybackStory(gWindow.story.surface, gWindow.story.fixture):
      for name in storyMomentNames(gWindow.story.surface, gWindow.story.fixture):
        echo name
    return 0
  if cmd.moment.len > 0 and not isPlaybackStory(gWindow.story.surface, gWindow.story.fixture):
    raise newException(ValueError, "--moment names a moment of a playback story; " &
                       cmd.storyId & " is not one")
  if cmd.moment.len > 0:
    # Checked before the window opens: the root builder is a C callback,
    # which must not raise.
    let names = storyMomentNames(gWindow.story.surface, gWindow.story.fixture)
    if cmd.moment notin names:
      raise newException(ValueError, "the story " & cmd.storyId & " has no moment named '" &
                         cmd.moment & "' (its moments: " & names.join(", ") & ")")
  if cmd.regionsDecl.len > 0: gWindow.probes = readDeclaration(cmd.regionsDecl)
  let preflight = currentWindowPreflight(gpui_has_window_backend() == 1'u8)
  if preflight.refusal != wpWindowCanOpen:
    stderr.writeLine("codetracer-gpui-story: " & preflight.message)
    return ExitNoWindow
  discard registerDesignFonts()
  if cmd.quitAfterMs > 0'u32: gpui_quit_after_ms(cmd.quitAfterMs)
  setMinWindowSize(1.0, 1.0)
  setInitialWindowState(false)
  setAppId(AppId)
  gpui_launch(cstring("CodeTracer story — " & cmd.storyId), float(cmd.width),
              float(cmd.height), buildStory)
  if gWindow.builderCalls != 1:
    stderr.writeLine("codetracer-gpui-story: the root builder ran " &
                     $gWindow.builderCalls & " times, expected exactly 1")
    return 1
  if gWindow.probes.len > 0 and not gWindow.written:
    stderr.writeLine("codetracer-gpui-story: the window closed before its " &
                     "regions settled; nothing was written to " & cmd.regionsOut)
    return 1
  if gWindow.mount.dispose != nil: gWindow.mount.dispose()
  0

when isMainModule:
  var cmd: StoryCommand
  try:
    cmd = parseCommand(commandLineParams())
  except ValueError as e:
    stderr.writeLine("codetracer-gpui-story: " & e.msg)
    stderr.writeLine(usage())
    quit(ExitUsage)
  try:
    quit(run(cmd))
  except ValueError as e:
    stderr.writeLine("codetracer-gpui-story: " & e.msg)
    quit(ExitUsage)
  except CatchableError as e:
    stderr.writeLine("codetracer-gpui-story: " & e.msg.splitLines()[0])
    quit(1)
