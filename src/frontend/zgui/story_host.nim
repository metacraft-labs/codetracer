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
##   * the fonts: each `@font-face` rule in those sheets is registered from
##     its font file under its family name, which is what a browser does with
##     the rule (zgui's style engine keeps the rule but fetches nothing).
##
## Usage:
##   codetracer-zgui-story --story=<kind>/<surface>/<fixture> --out=<png>
##     [--title=<tab title>] [--width=1600] [--height=1000] [--scale=1]
##     [--theme=dark|light] [--build-root=src/build-debug-repro]

import std/[json, os, parseopt, strutils, tables]

import isonim_zgui/[renderer, png, testing]

import ../stories/[story_frames, story_mount]
import ./zgui_view_support

const
  IndexHtml = staticRead("../index.html")
  ThemeFiles = {"dark": "default_dark_theme_electron.css",
                "light": "default_white_theme_electron.css"}.toTable
  PreviewSizing = "html,body{margin:0;padding:0;height:100%;overflow:hidden}"
    ## The IsoNim Editor's page preview document's own rule
    ## (`isonim_editor_codetracer.codeTracerPreviewDocument`, `page = true`).

type
  HostOptions = object
    kind, surface, fixture, title, outPath, theme, buildRoot, repoRoot, boxesPath: string
    width, height: int
    scale: float

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

proc resolveUrl(sheetServed, url: string): string =
  let u = url.strip(chars = {'"', '\'', ' '})
  if u.startsWith("/"): normalise(u)
  else: normalise(sheetServed[0 .. sheetServed.rfind('/')] & u)

proc fontFaces(css: string): seq[tuple[family: string; urls: seq[string]]] =
  ## Each `@font-face` rule's family and its sources, in the rule's order.
  var at = 0
  while true:
    let start = css.find("@font-face", at)
    if start < 0: break
    let open = css.find('{', start)
    let close = css.find('}', open)
    if open < 0 or close < 0: break
    at = close + 1
    let body = css[open + 1 ..< close]
    var family = ""
    var urls: seq[string]
    for decl in body.split(';'):
      let colon = decl.find(':')
      if colon < 0: continue
      let name = decl[0 ..< colon].strip.toLowerAscii
      let value = decl[colon + 1 .. ^1].strip
      if name == "font-family":
        family = value.strip(chars = {'"', '\'', ' '})
      elif name == "src":
        var s = 0
        while true:
          let u = value.find("url(", s)
          if u < 0: break
          let e = value.find(')', u)
          if e < 0: break
          urls.add value[u + 4 ..< e].strip(chars = {'"', '\'', ' '})
          s = e + 1
    if family.len > 0 and urls.len > 0: result.add (family, urls)

proc appCss(opts: HostOptions): string =
  ## The page's stylesheets in order, registering their fonts on the way.
  var registered: seq[string] = @[]
  for link in appStylesheets(IndexHtml):
    var served = link.href
    if link.id == "theme":
      served = served[0 .. served.rfind('/')] & ThemeFiles.getOrDefault(opts.theme,
        ThemeFiles["dark"])
    let path = onDisk(opts, served)
    if path.len == 0 or not fileExists(path):
      raise newException(IOError, "the page's stylesheet " & served & " is not at " & path &
        " (build the tree with `just build-once`)")
    let css = readFile(path)
    for (family, urls) in fontFaces(css):
      # The first source zgui's font system reads (TrueType or OpenType) that
      # exists, as a browser takes the first source it can load. A rule whose
      # only loadable source is WOFF is reported: the browser draws it and
      # this arm cannot.
      var chosen = ""
      for url in urls:
        let lower = url.toLowerAscii
        if not (lower.endsWith(".ttf") or lower.endsWith(".otf")): continue
        let file = onDisk(opts, resolveUrl(served, url))
        if file.len > 0 and fileExists(file):
          chosen = file
          break
      if chosen.len == 0:
        stderr.writeLine "codetracer-zgui-story: no TrueType/OpenType source of `", family,
          "` in ", served, " exists (", urls.join(", "), ")"
      elif chosen notin registered:
        registerFontFile(chosen, family)
        registered.add chosen
    result.add "/* " & served & " */\n" & css & "\n"

# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

var gOpts: HostOptions
var gDispose: StoryDispose
var gSurface: ZguiNode
var gLayout: DefaultDebugFrame[ZguiNode]

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

proc buildDocument(root: ZguiNode) =
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

proc parseOptions(): HostOptions =
  result = HostOptions(width: 1600, height: 1000, scale: 1.0, theme: "dark",
                       buildRoot: "src/build-debug-repro", repoRoot: getCurrentDir(),
                       fixture: "populated")
  for kind, key, value in getopt():
    if kind notin {cmdLongOption, cmdShortOption}: continue
    case key
    of "story":
      let parts = value.split('/')
      if parts.len < 2: quit("--story is <kind>/<surface>[/<fixture>]", 2)
      result.kind = parts[0]
      result.surface = parts[1]
      if parts.len > 2: result.fixture = parts[2]
    of "title": result.title = value
    of "out": result.outPath = value
    of "width": result.width = parseInt(value)
    of "height": result.height = parseInt(value)
    of "scale": result.scale = parseFloat(value)
    of "theme": result.theme = value
    of "build-root": result.buildRoot = value
    of "repo-root": result.repoRoot = value
    of "boxes": result.boxesPath = value
    else: quit("unknown option --" & key, 2)
  if result.kind.len == 0 or result.outPath.len == 0:
    quit("usage: codetracer-zgui-story --story=<kind>/<surface>/<fixture> --out=<png> " &
         "[--title=] [--width=] [--height=] [--scale=] [--theme=] [--build-root=]", 2)
  result.buildRoot = absolutePath(result.buildRoot)
  result.repoRoot = absolutePath(result.repoRoot)

proc main() =
  gOpts = parseOptions()
  let css = appCss(gOpts) & "\n" & storySurfaceCss & "\n" & PreviewSizing & "\n"
  openHeadless(float32(gOpts.width), float32(gOpts.height), css, zrOffscreen, buildDocument)
  try:
    for _ in 0 ..< 8: discard settle(512)
    if not gLayout.root.isNil:
      finishDefaultDebugLayout()
      for _ in 0 ..< 8: discard settle(512)
    if gOpts.scale != 1.0:
      setHeadlessScale(gOpts.scale, float32(gOpts.width), float32(gOpts.height))
      for _ in 0 ..< 8: discard settle(512)
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
