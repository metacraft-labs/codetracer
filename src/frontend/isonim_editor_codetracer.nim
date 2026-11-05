## The IsoNim Editor instance over CodeTracer's stories.
##
## CodeTracer is the editor's user project here: every story declared in
## `stories/codetracer_stories.nim` (the declaration StoryBook's story files
## are generated from) is a component story of the editor, one story group per
## StoryBook section, the Agent Harbor prototypes first.
##
## How a story reaches the preview. The editor hands a project an element in
## its preview frame (`EditorWorkspace.previewMount`). The frame's document is
## the one `codeTracerPreviewDocument` writes: CodeTracer's own stylesheets,
## read from the production `index.html` exactly as StoryBook's
## `.storybook/appStyles.js` reads them, the StoryBook components bundle
## (`storybook/dist/components.js`, which builds each story's viewmodel and
## renders the production IsoNim view through `mountCodeTracerStory`) and
## `storybook/stories/lib/surfaces.js`, which frames a story by its kind. The
## mount runs `renderSurface` in the frame's own window, so a story's code
## sees the frame's document and window as it sees StoryBook's preview frame:
## the two surfaces render a story with the same code, styles and fixture.
##
## Served by `just isonim-editor-codetracer` (`scripts/isonim-editor-codetracer.sh`,
## which assembles the static tree these URLs name and runs IsoNim's editor
## server with its agent routes over this checkout).
##
## Preview theme: `?ctTheme=light` on the editor URL shows the stories in
## CodeTracer's light theme; the default is dark, as in StoryBook.

when not defined(js):
  {.error: "isonim_editor_codetracer.nim is the editor's browser entry point; compile with `nim js`".}

import std/[strutils, tables]

import isonim/core/owner
import isonim/editor
import isonim/editor/browser

import stories/codetracer_stories

const
  editorId* = "codetracer-stories"
  editorTitle = "CodeTracer stories"
  catalogSource = "src/frontend/stories/codetracer_stories.nim"
  appIndexHtml = staticRead("index.html")
    ## CodeTracer's production page, the one source of its stylesheet list.

  # Where the static tree assembled by `scripts/isonim-editor-codetracer.sh`
  # serves what a preview frame loads. `/frontend`, `/public` and
  # `/libs/codetracer-design-system` are the paths StoryBook serves the same
  # directories at (`storybook/.storybook/main.ts`), so the app stylesheets'
  # relative font URLs resolve the same way in both.
  componentsBundleUrl = "/codetracer-storybook/components.js"
  surfacesModuleUrl = "/codetracer-storybook/lib/surfaces.js"

  themeStylesheets = {"dark": "default_dark_theme_electron.css",
                      "light": "default_white_theme_electron.css"}.toTable
    ## The theme names CodeTracer's `loadTheme` resolves, as in
    ## `storybook/.storybook/appStyles.js` `CODETRACER_THEMES`.

proc attributeValue(tag, name: string): string =
  ## The value of attribute `name` in one HTML start tag, quoted with ' or ".
  let lower = tag.toLowerAscii
  var at = 0
  while true:
    at = lower.find(name & "=", at)
    if at < 0: return ""
    # Only a whole attribute name: preceded by whitespace.
    if at > 0 and lower[at - 1] in Whitespace:
      let start = at + name.len + 1
      if start < tag.len and tag[start] in {'"', '\''}:
        let close = tag.find(tag[start], start + 1)
        if close > start: return tag[start + 1 ..< close]
      return ""
    at += name.len

proc appStylesheets(html: string): seq[tuple[id, href: string]] =
  ## Every `<link rel="stylesheet">` of the app page, in order, with its href
  ## made root-relative the way `appStyles.js` `appHref` does (the page is
  ## served from the root in both StoryBook and this instance).
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
    if href.len == 0: continue
    while href.startsWith("./"): href = href[2 .. ^1]
    if not href.startsWith("/"): href = "/" & href
    result.add (attributeValue(tag, "id"), href)

const appLinks = appStylesheets(appIndexHtml)

static:
  # The page this instance mirrors must still declare its theme stylesheet;
  # without it every preview would render unstyled and this would not say so.
  var hasTheme = false
  for link in appLinks:
    if link.id == "theme": hasTheme = true
  doAssert hasTheme, "src/frontend/index.html no longer declares <link id='theme'>"

func frameHeight(kind: string): int =
  ## The preview frame's height for a story kind. The editor sizes a preview
  ## frame to its content, and CodeTracer's surfaces fill their viewport
  ## (`100vh`), so the document fixes a height: the brief's `panel` size
  ## (760 x 640) for panels, a laptop height for whole layouts.
  case kind
  of "layout": 900
  of "panel": 640
  of "view": 480
  else: 320

proc codeTracerPreviewDocument*(story: CodeTracerStory; theme: string): string =
  ## The preview frame's document for `story` in `theme` (`dark`/`light`).
  let themeFile = themeStylesheets.getOrDefault(theme, themeStylesheets["dark"])
  let themeKey = if theme in themeStylesheets: theme else: "dark"
  result = "<!doctype html><html data-codetracer-theme=\"" & themeKey &
    "\"><head><meta charset=\"utf-8\">"
  for link in appLinks:
    var href = link.href
    if link.id == "theme":
      let slash = href.rfind('/')
      href = href[0 .. slash] & themeFile
    result.add "<link rel=\"stylesheet\" href=\"" & href & "\"" &
      (if link.id.len > 0: " id=\"" & link.id & "\"" else: "") & ">"
  let height = $frameHeight(story.kind)
  # Harness sizing only, as storybook/README.md allows: the frame's height,
  # no visual property.
  result.add "<style>html,body{margin:0;padding:0;height:" & height &
    "px;overflow:hidden}</style>"
  result.add "<script src=\"" & componentsBundleUrl & "\"></script>"
  result.add "<script type=\"module\">import { renderSurface } from \"" &
    surfacesModuleUrl & "\"; window.__ctRenderStory = renderSurface;</script>"
  result.add "</head><body data-codetracer-story=\"" & story.surface & "/" &
    story.fixture & "\"></body></html>"

type StoryKey = tuple[group, name: string]

proc storyTable(sections: seq[CodeTracerStorySection]): Table[StoryKey, CodeTracerStory] =
  for section in sections:
    for story in section.stories:
      result[(section.group, story.name)] = story

proc storyGroups(sections: seq[CodeTracerStorySection]): seq[StoryGroup] =
  for index, section in sections:
    var items: seq[StoryItem]
    for story in section.stories:
      items.add StoryItem(name: story.name, description: story.describe,
                          kind: skComponent, group: section.group)
    result.add StoryGroup(name: section.group, kind: skComponent,
                          expanded: index == 0,
                          description: section.description, items: items)

proc previewTheme(): string =
  var value: cstring
  {.emit: [value, " = (new URLSearchParams(window.location.search)).get('ctTheme') || '';"].}
  $value

proc mountInFrame(host: PreviewMountHost; story: CodeTracerStory) =
  ## Frame `story` by its kind and mount it, in the preview frame's window.
  ## Disposes the story's viewmodels when the editor disposes the mount.
  let kind = story.kind.cstring
  let surface = story.surface.cstring
  let fixture = story.fixture.cstring
  let name = frameTitleOf(story).cstring
  var container: RootRef
  {.emit: ["""
    (function () {
      const doc = """, host, """.ownerDocument;
      const win = doc && doc.defaultView;
      const render = win && win.__ctRenderStory;
      if (typeof render !== 'function') {
        const note = doc.createElement('div');
        note.className = 'ct-editor-story-unavailable';
        note.textContent = 'The CodeTracer story harness did not load into the preview frame (' +
          '""", surfacesModuleUrl, """, """, componentsBundleUrl, """).';
        """, host, """.appendChild(note);
        return;
      }
      """, container, """ = render(""", kind, ", ", surface, ", ", fixture, ", ", name, """);
      """, host, """.appendChild(""", container, """);
    })();
  """].}
  onCleanup proc() =
    {.emit: ["""
      if (""", container, """ && typeof """, container, """.__dispose === 'function') {
        """, container, """.__dispose();
      }
    """].}

proc newCodeTracerEditorWorkspace*(): EditorWorkspace =
  ## The editor workspace over every declared CodeTracer story.
  let sections = codeTracerStorySections()
  let problems = validateStorySections(sections)
  if problems.len > 0:
    raise newException(ValueError, "invalid story declaration: " & problems.join("; "))
  let stories = storyTable(sections)
  let groups = storyGroups(sections)
  let theme = previewTheme()
  let first = sections[0]

  let previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
    let key = (story.group, story.name)
    if story.kind != skComponent or key notin stories:
      return ProjectPreview(status: ppsUnsupportedStory, story: story)
    let declared = stories[key]
    ProjectPreview(
      status: ppsRendered,
      story: story,
      title: story.group & " / " & declared.name,
      bodyText: declared.describe,
      documentHtml: codeTracerPreviewDocument(declared, theme),
      metadata: StoryRenderMetadata(
        story: story, title: declared.name, sourceFile: catalogSource,
        fixtureName: declared.fixture, renderKind: declared.kind))

  let previewMount = proc(story: StoryRef; host: PreviewMountHost) =
    let key = (story.group, story.name)
    if key in stories:
      mountInFrame(host, stories[key])

  newEditorWorkspace(
    title = editorTitle,
    storyGroups = groups,
    id = editorId,
    description = "CodeTracer's StoryBook stories, from their one declaration",
    initialView = evComponentDetail,
    initialStory = some(StoryRef(group: first.group, name: first.stories[0].name,
                                 kind: skComponent, index: 0)),
    previewHook = previewHook,
    previewMount = previewMount,
    # Web only: the stories render CodeTracer's web views.
    allowedPlatforms = {pbWeb},
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: false, createStory: false, createVariant: false,
      duplicate: false, delete: false))

const
  previewViewportWidth* = 760
  previewViewportHeight* = 640
    ## The preview viewport the instance opens with: the brief's `panel` size,
    ## the size CodeTracer's panel stories are designed and reviewed at.
    ##
    ## Why not the editor's default (Desktop, 1440 x 900). In Comment and Edit
    ## mode the editor lays a story out at the viewport's width and, when that
    ## is wider than its centre column, scales the whole frame down to fit
    ## (`views/component_edit.nim`). At a laptop-sized window that is a scale
    ## of about 0.67, which draws CodeTracer's 12 px text at 8 px, where
    ## Chromium on Linux spaces the design-system face's glyphs unevenly
    ## ("need sinput"). The story is then not what StoryBook shows. At 760 px
    ## the frame fits the column and is drawn at its own size, so the preview
    ## a reviewer comments on is the StoryBook render
    ## (`tools/isonim-editor/smoke.mjs` compares the two). A viewport named on
    ## the URL (`?viewport=desktop`, `custom-<w>x<h>`) still wins.

proc routeNamesViewport(): bool =
  var named = false
  {.emit: [named, " = (new URLSearchParams(window.location.search)).has('viewport') || /[#&?]viewport=/.test(window.location.hash);"].}
  named

when isMainModule:
  # Asked before mounting: the mounted editor writes its own state, viewport
  # included, into the URL.
  let viewportNamed = routeNamesViewport()
  let vm = mountEditor(newCodeTracerEditorWorkspace())
  if not viewportNamed:
    vm.changeViewport(makeCustomViewport(previewViewportWidth, previewViewportHeight))
