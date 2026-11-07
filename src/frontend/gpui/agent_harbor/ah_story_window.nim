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
##                         [--quit-after-ms=<n>] [--list]
##
## `--list` prints every story id of the section and exits. `--regions` names
## the region declaration (`src/tests/visual/agent-harbor-regions.json`): for
## each named region, which element of the GPUI views it is (the `data-ah-*`
## facts the element must carry). Every element so named is given the
## `data-layout-probe` attribute, so the shim records where the window laid it
## out (isonim-gpui `layout_bounds`), and once two consecutive ticks read the
## same bounds the regions are written to `--regions-out` as JSON, in window
## pixels, beside the viewport they were measured in. The web capture writes
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
from isonim_gpui/bindings import gpui_launch, gpui_has_window_backend,
  gpui_quit_after_ms, gpui_set_tick, gpui_layout_bounds_reset

import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../window_preflight
import ../design_fonts
import ../chrome
import ./ah_stories

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
    storyId, regionsDecl, regionsOut: string
    mode: DesignMode
    width, height: int
    quitAfterMs: uint32
    list: bool

  RegionProbe = object
    ## One declared region: its name, the `data-ah-*` facts its element
    ## carries, and the element the mounted story has for it (nil: none).
    name: string
    facts: seq[(string, string)]
    element: GpuiElement

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
  "--regions-out=<file>] [--quit-after-ms=<n>] [--list]"

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
    of "--quit-after-ms": result.quitAfterMs = uint32(positive(value, "--quit-after-ms"))
    of "--list": result.list = true
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
    if probe.name.len == 0 or probe.facts.len == 0:
      raise newException(ValueError, path & ": a region needs a name and gpui facts")
    result.add probe

proc matches(el: GpuiElement; facts: seq[(string, string)]): bool =
  for (attr, want) in facts:
    let have = getAttribute(el, attr)
    if have.len == 0 or (want.len > 0 and have != want): return false
  true

proc firstMatch(node: GpuiElement; facts: seq[(string, string)]): GpuiElement =
  ## The first element under `node` (itself included), in document order,
  ## carrying every fact — the order `document.querySelector` answers in.
  if node.isNil: return nil
  if matches(node, facts): return node
  for i in 0 ..< childCount(node):
    let hit = firstMatch(nthChild(node, i), facts)
    if not hit.isNil: return hit

proc readRegions(probes: seq[RegionProbe]): JsonNode =
  ## The laid-out regions, or nil while any probed element has no bounds yet.
  ## A region whose element is absent, or laid out with no area, is left out:
  ## the web side leaves out an invisible element the same way.
  result = newJObject()
  for probe in probes:
    if probe.element.isNil: continue
    var x, y, w, h: float
    if not layoutBounds(probe.element, x, y, w, h): return nil
    if w <= 0 or h <= 0: continue
    result[probe.name] = %*{"x": x, "y": y, "w": w, "h": h}

proc writeRegions(regions: JsonNode) =
  let c = gWindow.cmd
  let doc = %*{
    "renderer": "gpui",
    "story": c.storyId,
    "theme": (if c.mode == dmDark: "dark" else: "light"),
    "viewport": {"width": c.width, "height": c.height},
    "regions": regions}
  createDir(parentDir(c.regionsOut))
  writeFile(c.regionsOut, pretty(doc) & "\n")
  echo "codetracer-gpui-story: regions written to ", c.regionsOut

proc regionTick() {.cdecl.} =
  ## Every `TickMs`: once two consecutive reads of the laid-out regions agree,
  ## they are the settled layout, and are written once.
  if gWindow.written: return
  let regions = readRegions(gWindow.probes)
  if regions.isNil: return
  let read = $regions
  if read == gWindow.lastRead: inc gWindow.stableReads
  else:
    gWindow.lastRead = read
    gWindow.stableReads = 0
  if gWindow.stableReads >= 1:
    writeRegions(regions)
    gWindow.written = true
    gpui_set_tick(0, nil)

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
                                              c.width, c.height, c.mode, frameTitle)
  r.appendChild(root, gWindow.mount.root)
  for probe in gWindow.probes.mitems:
    probe.element = firstMatch(gWindow.mount.root, probe.facts)
    if not probe.element.isNil:
      r.setAttribute(probe.element, LayoutProbeAttribute, probe.name)
  if gWindow.probes.len > 0:
    gpui_layout_bounds_reset()
    gpui_set_tick(TickMs, regionTick)

proc run(cmd: StoryCommand): int =
  let section = agentHarborSection()
  if cmd.list:
    for story in section.stories: echo storybookId(section, story)
    return 0
  gWindow = StoryWindow(cmd: cmd, story: findStory(section, cmd.storyId))
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
