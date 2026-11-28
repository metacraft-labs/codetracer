## story_host.nim — `codetracer-zgui-story`: one declared CodeTracer story
## drawn by zgui, headless, and written as a PNG.
##
## The story-parity harness (`scripts/story-parity.sh`) draws the same story
## with every renderer at the same size and compares the pixels. This is the
## zgui arm. It draws what the DOM arm draws, built the same way:
##
##   * the document: `html > body > .ct-storybook-surface`, then the frame a
##     story of that kind gets (`stories/story_frames`, the twin of
##     `storybook/stories/lib/surfaces.js`), then the production IsoNim view
##     over the story's stand-in state (`stories/story_mount`), through
##     `ZguiRenderer` instead of `WebRenderer`;
##   * the stylesheets: every `<link rel="stylesheet">` of the app's
##     `index.html`, read from the built tree (`src/build-debug-repro`) in the
##     page's order, the theme's swapped as the IsoNim Editor swaps it, then
##     the surface sheet and the preview document's sizing rule;
##   * the resources: each sheet is installed with the directory it is read
##     from, so its `@font-face` faces, `background-image` and `mask-image`
##     pictures load from the files its relative `url()`s name, as a browser
##     loads them relative to the sheet's own URL.
##
## Usage:
##   codetracer-zgui-story --story=<kind>/<surface>/<fixture> --out=<png>
##     [--title=<tab title>] [--width=1600] [--height=1000] [--scale=1]
##     [--theme=dark|light] [--build-root=src/build-debug-repro]

import std/[json, os, strutils, tables]

import isonim_zgui/[renderer, png, testing]

import ../stories/[story_frames, story_mount]
import ./zgui_view_support
import ./story_options
import ../viewmodel/views/debug_control_marks

const
  IndexHtml = staticRead("../index.html")
  ThemeFiles = {"dark": "default_dark_theme_electron.css",
                "light": "default_white_theme_electron.css"}.toTable
  PreviewSizing = "html,body{margin:0;padding:0;height:100%;overflow:hidden}"
    ## The IsoNim Editor's page preview document's own rule
    ## (`isonim_editor_codetracer.codeTracerPreviewDocument`, `page = true`).


# ---------------------------------------------------------------------------
# The app's stylesheets, as the page links them
# ---------------------------------------------------------------------------

proc attributeValue(tag, name: string): string =
  let lower = tag.toLowerAscii
  var at = 0
  while true:
    at = lower.find(name & "=", at)
    if at < 0: return ""
    if at > 0 and lower[at - 1] in Whitespace:
      let start = at + name.len + 1
      if start < tag.len and tag[start] in {'"', '\''}:
        let close = tag.find(tag[start], start + 1)
        if close > start: return tag[start + 1 ..< close]
      return ""
    at += name.len

proc appStylesheets(html: string): seq[tuple[id, href: string]] =
  ## Every `<link rel="stylesheet">` of the page, in order, root-relative.
  var at = 0
  while true:
    let start = html.find("<link", at)
    if start < 0: break
    let stop = html.find('>', start)
    if stop < 0: break
    let tag = html[start .. stop]
    at = stop + 1
    if "stylesheet" notin attributeValue(tag, "rel").splitWhitespace: continue
    var href = attributeValue(tag, "href")
    while href.startsWith("./"): href = href[2 .. ^1]
    if href.len > 0: result.add (attributeValue(tag, "id"), "/" & href.strip(chars = {'/'}))

proc normalise(served: string): string =
  ## A served path with `.` and `..` resolved, clamped at the root as a
  ## browser clamps a URL's path.
  var parts: seq[string] = @[]
  for part in served.split('/'):
    case part
    of "", ".": discard
    of "..":
      if parts.len > 0: parts.setLen(parts.len - 1)
    else: parts.add part
  "/" & parts.join("/")

proc onDisk(opts: HostOptions; served: string): string =
  ## Where the static tree the DOM arm serves keeps `served`: `/frontend` and
  ## `/public` are the built tree's, `/libs/codetracer-design-system` the
  ## checkout's (`scripts/isonim-editor-codetracer.sh`, StoryBook's
  ## `.storybook/main.ts`).
  let p = normalise(served)
  if p.startsWith("/frontend/") or p.startsWith("/public/"):
    opts.buildRoot / p[1 .. ^1]
  elif p.startsWith("/libs/"):
    opts.repoRoot / p[1 .. ^1]
  else:
    ""

type PageSheet = tuple[name, css, dir: string]

proc readRoot(opts: HostOptions): string =
  ## The directory zgui may read a sheet's resources inside: the checkout the
  ## built tree belongs to. It is found from where `frontend/` really is, so a
  ## built tree reached through symlinks (a mirror sharing another checkout's
  ## build) still contains the files its sheets name, such as the
  ## design-system fonts at `../../../../libs`.
  let frontend = opts.buildRoot / "frontend"
  if not dirExists(frontend):
    raise newException(IOError, "no built tree at " & opts.buildRoot &
      " (build it with `just build-once`)")
  expandFilename(frontend).parentDir.parentDir.parentDir

proc appSheets(opts: HostOptions): seq[PageSheet] =
  ## The page's stylesheets in order, each with the directory it is read from.
  for link in appStylesheets(IndexHtml):
    var served = link.href
    if link.id == "theme":
      served = served[0 .. served.rfind('/')] & ThemeFiles.getOrDefault(opts.theme,
        ThemeFiles["dark"])
    let path = onDisk(opts, served)
    if path.len == 0 or not fileExists(path):
      raise newException(IOError, "the page's stylesheet " & served & " is not at " & path &
        " (build the tree with `just build-once`)")
    result.add (served, readFile(path), expandFilename(path).parentDir)

# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

var gOpts: HostOptions
var gSheets: seq[PageSheet]
var gReadRoot: string
var gDispose: StoryDispose
var gSurface: ZguiNode
var gLayout: DefaultDebugFrame[ZguiNode]
var gBuildError: string
  ## What the window's build raised. isonim-zgui reports a raising build and
  ## keeps the window, which then draws an empty page; a capture of that is
  ## not a measurement, so `main` fails instead of writing it.

proc dumpBoxes(path: string) =
  ## Every element under the surface, in document order, with its border box
  ## in CSS pixels: the same walk `capture-dom.mjs --boxes` takes over the
  ## DOM arm, so the two lists pair up element for element.
  var lines: seq[string]
  proc walk(n: ZguiNode; depth: int) =
    let tag = elementName(n)
    if tag.len == 0 or tag.startsWith("#"): return # a text node
    let b = borderBox(n)
    var label = ""
    let id = n.getAttribute("id")
    if id.len > 0: label.add "#" & id
    let cls = n.getAttribute("class")
    if cls.len > 0: label.add "." & cls.splitWhitespace.join(".")
    lines.add "{\"d\":" & $depth & ",\"t\":" & escapeJson(tag) & ",\"e\":" & escapeJson(label) & ",\"x\":" & $b.x &
      ",\"y\":" & $b.y & ",\"w\":" & $b.w & ",\"h\":" & $b.h & "}"
    for i in 0 ..< n.childCount: walk(n.nthChild(i), depth + 1)
  walk(gSurface, 0)
  writeFile(path, "[\n" & lines.join(",\n") & "\n]\n")

proc buildStory(root: ZguiNode) =
  # The page's sheets before the first frame, in the page's order (installed
  # sheets cascade in installation order), then the story's own sheet last.
  for sheet in gSheets:
    # A sheet that really lives outside the checkout (the third-party sheets
    # the build links from the Nix store's node_modules) reads only beside
    # itself: zgui resolves the sheet's directory through symlinks and refuses
    # a root that does not contain it.
    let root = if sheet.dir.startsWith(gReadRoot & DirSep): gReadRoot else: ""
    installStylesheet(sheet.name, sheet.css, dir = sheet.dir, root = root)
  installStylesheet("story", storySurfaceCss & "\n" & PreviewSizing & "\n")
  let r = ZguiRenderer()
  let html = r.createElement("html")
  r.setAttribute(html, "data-codetracer-theme", gOpts.theme)
  r.appendChild(root, html)
  let body = r.createElement("body")
  r.setAttribute(body, "data-codetracer-story", gOpts.surface & "/" & gOpts.fixture)
  r.appendChild(html, body)
  let surface = createSurface(r, body, gOpts.kind, gOpts.surface)
  gSurface = surface
  if gOpts.kind == "layout" and gOpts.surface == "default-debug":
    # `surfaces.js` `renderDefaultDebugLayout`: the reference shell, its
    # GoldenLayout geometry (`syncDefaultLayoutGeometry`, once `#ROOT` has
    # been laid out: see `main`), then a panel story in every tab.
    gLayout = buildDefaultDebugFrame(r, surface, body, gOpts.fixture)
    return
  let frame = createAppShell(r, surface, gOpts.kind, gOpts.surface, gOpts.title)
  case gOpts.kind
  of "panel":
    gDispose = mountPanelStory(r, frame, gOpts.surface, gOpts.fixture)
  else:
    raise newException(ValueError, "no native mount for " & gOpts.kind & " stories yet")

proc finishDefaultDebugLayout() =
  ## The default layout's geometry from `#ROOT`'s laid-out size, then its
  ## panels. A tab whose panel has no native mount yet (the editor) stays
  ## empty, and says so on stderr.
  let r = ZguiRenderer()
  let box = borderBox(gLayout.root)
  syncDefaultLayoutGeometry(r, gLayout, float(box.w) / gOpts.scale,
                            float(box.h) / gOpts.scale)
  # The transport marks, as `ctAttachDebugControlMarks` puts them on the
  # reference shell's buttons in the browser.
  for mark in ControlMarks:
    for (id, button) in gLayout.debugButtons:
      if id == mark.buttonId:
        r.appendChild(button, renderControlMark[ZguiRenderer, ZguiNode](r, mark))
  var disposers: seq[StoryDispose]
  for m in gLayout.mounts:
    if m.name in nativePanelSurfaces:
      disposers.add mountPanelStory(r, m.mount, m.name,
        if m.fixture.len > 0: m.fixture else: "populated")
    else:
      stderr.writeLine "codetracer-zgui-story: no native mount for the `", m.name,
        "` panel of the default layout"
  gDispose = proc() =
    for d in disposers: d()

proc buildDocument(root: ZguiNode) =
  try:
    buildStory(root)
  except CatchableError as e:
    gBuildError = e.msg
    raise

proc main() =
  try:
    gOpts = parseOptions(commandLineParams())
  except ValueError as e:
    quit(e.msg, 2)
  gReadRoot = readRoot(gOpts)
  gSheets = appSheets(gOpts)
  openHeadless(float32(gOpts.width), float32(gOpts.height), "", zrOffscreen, buildDocument)
  try:
    if gBuildError.len > 0:
      quit("codetracer-zgui-story: the story's build failed: " & gBuildError, 1)
    # HiDPI first, as the DOM arm's window has its scale from the start: the default layout's
    # GoldenLayout geometry is computed once from the laid-out `#ROOT`, so a scale applied after
    # it left the panels at the geometry of the other scale.
    if gOpts.scale != 1.0:
      setHeadlessScale(gOpts.scale, float32(gOpts.width), float32(gOpts.height))
    for _ in 0 ..< 8: discard settle(512)
    if not gLayout.root.isNil:
      finishDefaultDebugLayout()
      for _ in 0 ..< 8: discard settle(512)
    # The scrubbers the views attached, placed from the laid-out boxes.
    refreshScrubbers(gOpts.scale)
    for _ in 0 ..< 4: discard settle(512)
    if gOpts.boxesPath.len > 0: dumpBoxes(gOpts.boxesPath)
    let c = testing.capture()
    if c.width == 0: quit("zgui presented no frame to capture", 1)
    createDir(parentDir(absolutePath(gOpts.outPath)))
    writePng(gOpts.outPath, c.width, c.height, c.pixels)
    echo "wrote ", gOpts.outPath, " (", c.width, "x", c.height, ")"
  finally:
    if gDispose != nil: gDispose()
    closeHeadless()

when isMainModule:
  main()
