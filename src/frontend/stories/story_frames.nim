## The frame a story is drawn in, built through any IsoNim renderer.
##
## StoryBook and the IsoNim Editor frame a story by its kind in
## `storybook/stories/lib/surfaces.js` (`renderSurface`): the surface
## element, the app shell the app's stylesheets expect around a panel
## (`#root-container > #auto-hide-layout-row > #ROOT > #session-container-0`)
## and GoldenLayout's stack with its one tab. A native renderer that draws the
## same story builds the same frame here, element for element and class for
## class, so the app's stylesheets reach it the way they reach the browser's.
##
## `storySurfaceCss` is the stylesheet `surfaces.js` injects with every story
## (`injectSurfaceStyles`), read out of that file at compile time so the two
## cannot drift apart.

import std/[math, strutils]

const
  SurfacesJsPath = "../../../storybook/stories/lib/surfaces.js"
  SurfacesJs = staticRead(SurfacesJsPath)

func extractSurfaceCss(js: string): string =
  ## The template literal `injectSurfaceStyles` assigns to its `<style>`.
  const opener = "style.textContent = `"
  let start = js.find(opener)
  doAssert start >= 0, "surfaces.js no longer sets style.textContent in injectSurfaceStyles"
  let body = start + opener.len
  let stop = js.find('`', body)
  doAssert stop > body, "surfaces.js: the surface stylesheet's template literal is not closed"
  js[body ..< stop]

const storySurfaceCss* = extractSurfaceCss(SurfacesJs)
  ## The surface stylesheet every framed story is drawn with.

func titleize*(name: string): string =
  ## `event-log` -> `Event Log`, as `surfaces.js` `titleize` does.
  var parts: seq[string] = @[]
  for part in name.split('-'):
    if part.len == 0: parts.add ""
    else: parts.add part[0].toUpperAscii & part[1 .. ^1]
  parts.join(" ")

proc el[R, N](r: R; parent: N; tag: string; id = ""; class = ""): N =
  result = r.createElement(tag)
  if id.len > 0: r.setAttribute(result, "id", id)
  if class.len > 0: r.setAttribute(result, "class", class)
  r.appendChild(parent, result)

proc createGoldenPanelHost*[R, N](r: R; frame: N; title: string): N =
  ## GoldenLayout's root with one stack and one active tab titled `title`,
  ## as `surfaces.js` `createGoldenPanelHost` builds it. Returns the element
  ## the panel is mounted into.
  let layout = el(r, frame, "div", class = "lm_goldenlayout lm_item lm_root ct-storybook-golden-panel")
  let stack = el(r, layout, "div", class = "lm_item lm_stack")
  let header = el(r, stack, "div", class = "lm_header")
  let tabs = el(r, header, "section", class = "lm_tabs")
  let tab = el(r, tabs, "div", class = "lm_tab lm_active")
  r.setAttribute(tab, "title", title)
  let tabTitle = el(r, tab, "span", class = "lm_title")
  r.appendChild(tabTitle, r.createTextNode(title))
  let pin = el(r, tab, "div", class = "lm_pin_tab")
  r.setAttribute(pin, "title", "Pin to the sidebar")
  let close = el(r, tab, "div", class = "lm_close_tab")
  r.setAttribute(close, "title", "Close panel")
  discard el(r, header, "div", class = "lm_controls")
  let items = el(r, stack, "div", class = "lm_items")
  let content = el(r, items, "div", class = "lm_item lm_content")
  result = el(r, content, "div", class = "ct-storybook-panel-content")

proc createSurface*[R, N](r: R; parent: N; kind, name: string): N =
  ## The `.ct-storybook-surface` element `renderSurface` returns.
  result = el(r, parent, "div", class = "ct-storybook-surface")
  r.setAttribute(result, "data-kind", kind)
  r.setAttribute(result, "data-surface", name)

proc createAppShell*[R, N](r: R; container: N; kind, name: string;
                           displayTitle = ""): N =
  ## `surfaces.js` `createAppShell` for a `panel` story (and a plain frame
  ## for `view` / `component`): the app's shell around GoldenLayout's root.
  ## Returns the element the story is mounted into.
  if kind in ["view", "component"]:
    return el(r, container, "div", class = "ct-storybook-frame")
  let rootContainer = el(r, container, "div", id = "root-container",
                         class = "ct-storybook-root-container")
  let layoutRow = el(r, rootContainer, "div", id = "auto-hide-layout-row")
  discard el(r, layoutRow, "div", id = "auto-hide-strip-left")
  let root = el(r, layoutRow, "div", id = "ROOT")
  let contextMenu = el(r, root, "div", id = "context-menu-container")
  r.setStyle(contextMenu, "display", "none")
  discard el(r, root, "div", id = "fixed-search")
  let session = el(r, root, "div", id = "session-container-0", class = "session-container")
  discard el(r, session, "section", id = "main")
  discard el(r, layoutRow, "div", id = "auto-hide-strip-right")
  if kind == "panel":
    return createGoldenPanelHost(r, session,
      if displayTitle.len > 0: displayTitle else: titleize(name))
  result = el(r, session, "div", class = "ct-storybook-frame ct-storybook-session-frame")

# ---------------------------------------------------------------------------
# The default debugging layout (`surfaces.js` `renderDefaultDebugLayout`)
# ---------------------------------------------------------------------------

type
  LayoutTab* = tuple[title, name: string]

  DefaultDebugVariant* = object
    ## One of `surfaces.js` `defaultDebugVariants`.
    focusedPanel*: string
    sidebarTabs*: seq[LayoutTab]
    calltraceFixture*: string
    menuOpen*: bool
    rightTopRightActive*: string
    rightTopRightExtraTabs*: seq[LayoutTab]
    fixedSearchActive*: bool
    commandPaletteOpen*: bool

  LayoutMount*[N] = object
    ## Where one tab's panel is mounted, and with which fixture.
    name*: string
    mount*: N
    fixture*: string
    active*: bool

  DefaultDebugFrame*[N] = object
    root*: N
      ## `#ROOT`, the panels area the layout fills.
    layout*: N
      ## `.ct-storybook-default-layout`.
    boxes*: seq[tuple[name: string; el: N]]
      ## Every `[data-layout-box]` element, the stacks included.
    stacks*: seq[tuple[name: string; stack, header, items: N; activeItems: seq[N]]]
    hSplitters*, vSplitters*: seq[N]
    mounts*: seq[LayoutMount[N]]
    commandOverlay*: N
      ## The command palette's overlay, for `command-palette-open`.
    debugHeader*: N
      ## `#debug`, whose buttons the transport marks fill.
    debugButtons*: seq[tuple[id: string; el: N]]
      ## Its buttons by id, for the marks (`debug_control_marks.ControlMarks`).

const
  buildTabs: seq[LayoutTab] = @[("BUILD", "build")]
  fiveTabs: seq[LayoutTab] = @[("BUILD", "build"), ("BUILD ERRORS", "errors"),
                               ("TRACE LOG", "trace-log"), ("REPL", "repl"),
                               ("LOW LEVEL CODE", "low-level-code")]

func defaultDebugVariant*(fixture: string): DefaultDebugVariant =
  ## `surfaces.js` `defaultDebugVariant`.
  result.focusedPanel = "rightTopRight"
  case fixture
  of "mcr-visual":
    result.focusedPanel = "sidebar"
    result.sidebarTabs = @[("FRAME VIEWER", "frame-viewer")]
  of "filesystem-active": result.focusedPanel = "sidebar"
  of "state-active": result.focusedPanel = "rightTopLeft"
  of "calltrace-search-status-report": result.calltraceFixture = "search-status-report"
  of "menu-view-open":
    result.menuOpen = true
    result.rightTopRightActive = "agent-activity"
  of "status-expanded": result.rightTopRightActive = "agent-activity"
  of "build-open":
    result.rightTopRightActive = "build"
    result.rightTopRightExtraTabs = buildTabs
  of "trace-log-open":
    result.rightTopRightActive = "trace-log"
    result.rightTopRightExtraTabs = fiveTabs[0 .. 2]
  of "search-results-populated":
    result.fixedSearchActive = true
    result.rightTopRightActive = "search-results"
    result.rightTopRightExtraTabs = fiveTabs[0 .. 2] & @[("SEARCH RESULTS", "search-results")]
  of "fixed-search-visible":
    result.fixedSearchActive = true
    result.rightTopRightActive = "build"
    result.rightTopRightExtraTabs = fiveTabs
  of "command-palette-open":
    result.commandPaletteOpen = true
    result.rightTopRightActive = "build"
    result.rightTopRightExtraTabs = fiveTabs
  else: discard

func slugify(name: string): string =
  var dash = false
  for c in name.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}:
      if dash and result.len > 0: result.add '-'
      result.add c
      dash = false
    else:
      dash = true

proc text[R, N](r: R; parent: N; s: string) =
  r.appendChild(parent, r.createTextNode(s))

proc createGoldenStack[R, N](r: R; f: var DefaultDebugFrame[N]; tabsData: seq[LayoutTab];
                             activeName: string; focused: bool; layoutBox, fixture: string): N =
  ## `surfaces.js` `createGoldenStack`.
  var activeIndex = 0
  for i, t in tabsData:
    if t.name == activeName: activeIndex = i
  let stack = r.createElement("div")
  r.setAttribute(stack, "class", "lm_item lm_stack")
  let header = r.createElement("section")
  r.setAttribute(header, "class", "lm_header" & (if focused: " lm_focused" else: ""))
  r.appendChild(stack, header)
  let tabs = el(r, header, "section", class = "lm_tabs")
  for i, t in tabsData:
    let tab = el(r, tabs, "div", class = "lm_tab" & (if i == activeIndex: " lm_active" else: ""))
    r.setAttribute(tab, "title", t.title)
    let title = el(r, tab, "span", class = "lm_title")
    text(r, title, t.title)
    discard el(r, tab, "div", class = "lm_close_tab")
  let buttons = el(r, tabs, "div", class = "layout-buttons-container")
  r.setAttribute(buttons, "tabindex", "0")
  let dropdown = el(r, buttons, "div", id = "layout-dropdown-toggle", class = "layout-dropdown hidden")
  for label in ["Close all", "Maximise container"]:
    text(r, el(r, dropdown, "div", class = "layout-dropdown-node"), label)
  discard el(r, header, "section", class = "lm_controls")
  let dropdownList = el(r, header, "section", class = "lm_tabdropdown_list")
  r.setStyle(dropdownList, "display", "none")
  let items = el(r, stack, "section", class = "lm_items")
  var active: seq[N]
  for i, t in tabsData:
    let item = r.createElement("div")
    if i != activeIndex: r.setAttribute(item, "class", "lm_hidden_item")
    else: active.add item
    r.appendChild(items, item)
    let content = el(r, item, "div", class = "lm_content")
    let mount = el(r, content, "div", class = "ct-storybook-panel-content")
    if t.name.len > 0:
      f.mounts.add LayoutMount[N](name: t.name, mount: mount, fixture: fixture,
                                  active: i == activeIndex)
    if i == activeIndex: active.add content
  r.setAttribute(stack, "data-layout-box", layoutBox)
  var names: seq[string]
  for t in tabsData:
    if t.name.len > 0: names.add t.name
  r.setAttribute(stack, "data-panel-name", names.join(" "))
  f.stacks.add (layoutBox, stack, header, items, active)
  stack

proc createSplitter[R, N](r: R; f: var DefaultDebugFrame[N]; orientation: string): N =
  result = r.createElement("div")
  r.setAttribute(result, "class", "lm_splitter lm_" & orientation)
  discard el(r, result, "div", class = "lm_drag_handle")
  if orientation == "horizontal": f.hSplitters.add result
  else: f.vSplitters.add result

proc appendMenuNode[R, N](r: R; parent: N; label, kind: string; index = 0;
                          iconClass = ""; nameWidth = 16) =
  let container = el(r, parent, "div", class = "menu-node-container")
  let node = el(r, container, "div", class = kind & " menu-node menu-enabled")
  if kind == "menu-element": r.setAttribute(node, "id", "menu-element-1 " & $index)
  let icon = el(r, node, "span", class = "menu-node-icon")
  if kind == "menu-folder":
    discard el(r, icon, "div", class = "icon " & (if iconClass.len > 0: iconClass else: slugify(label)))
  let name = el(r, node, "span", class = "menu-node-name menu-" &
    (if kind == "menu-folder": "folder" else: "element") & "-" & slugify(label))
  r.setStyle(name, "width", $nameWidth & "ch")
  text(r, name, label)
  if kind == "menu-folder": discard el(r, name, "span", class = "menu-expand")

proc appendOpenViewMenu[R, N](r: R; navigation: N) =
  let menuMain = el(r, navigation, "div", id = "menu-main")
  discard el(r, menuMain, "div", id = "menu-search-results")
  let elements = el(r, menuMain, "div", id = "menu-elements")
  for label in ["File", "Edit", "View", "Build", "Reset", "Debug"]:
    appendMenuNode(r, elements, label, "menu-folder", iconClass = slugify(label))
  let nested = el(r, menuMain, "div", id = "menu-nested-elements-1",
                  class = "menu-nested-elements menu-nested-elements-1")
  r.setStyle(nested, "left", "202px")
  r.setStyle(nested, "top", "60px")
  for index, label in ["Filesystem", "Calltrace", "Variables", "Event Log", "Terminal Output",
                       "Scratchpad", "Agent Activity"]:
    appendMenuNode(r, nested, label, "menu-element", index = index)

const DebugItems = ["history-back-image", "history-forward-image", "reverse-next-image",
  "next-image", "reverse-step-in-image", "step-in-image", "reverse-step-out-image",
  "step-out-image", "reverse-continue-image", "continue-image", "reset-operation-image",
  "stop-image", "run-tests-image", "run-to-entry-image"]

proc createKaraxReferenceShell[R, N](r: R; f: var DefaultDebugFrame[N]; container, body: N;
                                     variant: DefaultDebugVariant): N =
  ## `surfaces.js` `createKaraxReferenceShell`: the caption bar, the panels
  ## area and the status bar. Returns `#ROOT`.
  r.setAttribute(body, "class", "monaco-workbench linux web enable-motion")
  let menu = el(r, container, "div", id = "menu")
  let navigation = el(r, menu, "div", id = "navigation-menu")
  r.setAttribute(navigation, "tabindex", "0")
  let menuRoot = el(r, navigation, "div", id = "menu-root")
  discard el(r, menuRoot, "div", id = "menu-logo-img")
  if variant.menuOpen: appendOpenViewMenu(r, navigation)
  let debug = el(r, menu, "div", id = "debug", class = "ct-header")
  f.debugHeader = debug
  var children = 0
  for id in DebugItems:
    if children mod 5 == 0:
      discard el(r, debug, "div", class = "separate-bar")
      inc children
    f.debugButtons.add (id, el(r, debug, "button", id = id,
                              class = "ct-button-image-md-secondary ct-button-no-border"))
    inc children
  let commandView = el(r, debug, "div", id = "command-view", class = "command-view")
  let commandSurface = el(r, commandView, "div", class = "command-surface")
  let input = el(r, commandSurface, "input", id = "command-query-text",
                 class = "mousetrap ct-input-com-pal ct-input-search-image")
  r.setAttribute(input, "type", "text")
  r.setAttribute(input, "name", "command-query")
  r.setAttribute(input, "placeholder", "Navigate to file or run a :command")
  let windowMenu = el(r, menu, "div", class = "window-menu")
  for cls in ["minimize", "maximize", "close"]:
    discard el(r, windowMenu, "div", class = "menu-button-svg " & cls)
  discard el(r, container, "div", id = "welcomeScreen")
  discard el(r, container, "div", id = "deepreview")
  let rootContainer = el(r, container, "div", id = "root-container",
    class = "container ct-storybook-root-container ct-storybook-karax-root-container")
  let root = el(r, rootContainer, "div", id = "ROOT")
  let contextMenu = el(r, root, "div", id = "context-menu-container")
  r.setStyle(contextMenu, "display", "none")
  let inactive = if variant.fixedSearchActive: "" else: "fixed-search-non-active"
  let fixedSearch = el(r, root, "div", id = "fixed-search", class = inactive)
  let queryField = el(r, fixedSearch, "div", class = "fixed-search-query-field")
  let q = el(r, queryField, "input", id = "fixed-search-query", class = "mousetrap")
  r.setAttribute(q, "type", "text")
  r.setAttribute(q, "name", "search-query")
  for (kindName, field) in [("include", "fixed-search-include-field"),
                            ("exclude", "fixed-search-exclude-field")]:
    let holder = el(r, fixedSearch, "div", class = field & " " & inactive)
    let i = el(r, holder, "input", id = "fixed-search-" & kindName)
    r.setAttribute(i, "type", "text")
    r.setAttribute(i, "placeholder", kindName)
  let session = el(r, root, "div", id = "session-container-0", class = "session-container")
  discard el(r, session, "section", id = "main")
  let footer = el(r, container, "footer")
  let status = el(r, footer, "div", id = "status")
  discard el(r, status, "div", id = "active-notifications")
  let statusBase = el(r, status, "div", id = "status-base")
  let fileInfo = el(r, statusBase, "div", id = "file-info-status")
  for label in ["Noir", "UTF-8"]:
    text(r, el(r, fileInfo, "span", class = "status-inline"), label)
    discard el(r, fileInfo, "div", class = "separate-bar")
  let operation = el(r, fileInfo, "span", id = "operation-status")
  text(r, el(r, operation, "span", id = "stable-status", class = "ready-status"), "stable: ready")
  text(r, el(r, statusBase, "span", class = "test-movement"), "1")
  let statusRight = el(r, statusBase, "span", class = "status-right")
  let location = el(r, statusRight, "span", id = "location-status")
  text(r, el(r, location, "span", class = "location-path status-inline"),
    "/home/user/metacraft/codetracer-main/test-programs/noir_space_ship/src/shield.nr:7#0")
  discard el(r, location, "button", id = "copy-path-image",
             class = "ct-button-image-md-secondary ct-button-no-border")
  text(r, el(r, location, "div", class = "custom-tooltip "), "Path copied to clipboard")
  root

proc appendDefaultDebugLayout[R, N](r: R; f: var DefaultDebugFrame[N]; shellRoot, session: N;
                                    variant: DefaultDebugVariant) =
  ## `surfaces.js` `appendDefaultDebugLayout`, without the geometry: that is
  ## `syncDefaultLayoutGeometry`, once the frame has been laid out.
  let layoutRoot = el(r, session, "div",
    class = "lm_goldenlayout lm_item lm_root ct-storybook-default-layout")
  f.layout = layoutRoot
  let row = el(r, layoutRoot, "div", class = "lm_item lm_row")
  f.boxes.add ("outerRow", row)
  proc box(cls, name: string): N =
    result = r.createElement("div")
    r.setAttribute(result, "class", cls)
    r.setAttribute(result, "data-layout-box", name)
  let leftColumn = box("lm_item lm_column ct-storybook-layout-sidebar", "sidebar")
  let editorParent = box("lm_item ct-storybook-layout-editor", "editor")
  let rightColumn = box("lm_item lm_column ct-storybook-layout-right", "right")
  let rightTop = box("lm_item lm_row ct-storybook-layout-right-top", "rightTop")
  let rightTopLeft = box("lm_item", "rightTopLeft")
  let rightTopRight = box("lm_item", "rightTopRight")
  let rightBottom = box("lm_item lm_column ct-storybook-layout-right-bottom", "rightBottom")
  for (name, e) in [("sidebar", leftColumn), ("editor", editorParent), ("right", rightColumn),
                    ("rightTop", rightTop), ("rightTopLeft", rightTopLeft),
                    ("rightTopRight", rightTopRight), ("rightBottom", rightBottom)]:
    f.boxes.add (name, e)
  let rightTopRightTabs = @[("CALLTRACE", "calltrace"), ("AGENT ACTIVITY", "agent-activity")] &
    variant.rightTopRightExtraTabs
  let sidebarTabs = if variant.sidebarTabs.len > 0: variant.sidebarTabs
                    else: @[("FILESYSTEM", "filesystem")]
  let panels = [
    (leftColumn, "sidebar", sidebarTabs, "", ""),
    (editorParent, "editor", @[("src/shield.nr", "editor")], "", ""),
    (rightTopLeft, "rightTopLeft", @[("VARIABLES", "state"), ("SCRATCHPAD", "scratchpad")], "", ""),
    (rightTopRight, "rightTopRight", rightTopRightTabs,
     (if variant.calltraceFixture.len > 0: variant.calltraceFixture else: "reference"),
     (if variant.rightTopRightActive.len > 0: variant.rightTopRightActive else: "calltrace")),
    (rightBottom, "rightBottom", @[("EVENT LOG", "event-log"), ("TERMINAL OUTPUT", "terminal-output")], "", ""),
  ]
  for (parent, layoutBox, tabs, fixture, activeName) in panels:
    let stack = createGoldenStack(r, f, tabs, activeName, layoutBox == variant.focusedPanel,
                                  layoutBox, fixture)
    r.appendChild(parent, stack)
  r.appendChild(rightTop, rightTopLeft)
  r.appendChild(rightTop, createSplitter(r, f, "horizontal"))
  r.appendChild(rightTop, rightTopRight)
  r.appendChild(rightColumn, rightTop)
  r.appendChild(rightColumn, createSplitter(r, f, "vertical"))
  r.appendChild(rightColumn, rightBottom)
  r.appendChild(row, leftColumn)
  r.appendChild(row, createSplitter(r, f, "horizontal"))
  r.appendChild(row, editorParent)
  r.appendChild(row, createSplitter(r, f, "horizontal"))
  r.appendChild(row, rightColumn)
  discard shellRoot

proc buildDefaultDebugFrame*[R, N](r: R; container, body: N; fixture: string): DefaultDebugFrame[N] =
  ## The default debugging layout's frame for `fixture`, as
  ## `surfaces.js` `renderDefaultDebugLayout` builds it, before its geometry
  ## (`syncDefaultLayoutGeometry`) and its panels.
  let variant = defaultDebugVariant(fixture)
  var f: DefaultDebugFrame[N]
  let root = createKaraxReferenceShell(r, f, container, body, variant)
  f.root = root
  # `#session-container-0` is `#ROOT`'s last child.
  var session = r.firstChild(root)
  while not r.nextSibling(session).isNil: session = r.nextSibling(session)
  appendDefaultDebugLayout(r, f, root, session, variant)
  if variant.commandPaletteOpen:
    f.commandOverlay = el(r, root, "div", class = "ct-storybook-command-overlay")
  f

proc setBox[R, N](r: R; e: N; w, h: float) =
  r.setStyle(e, "width", $max(0, int(round(w))) & "px")
  r.setStyle(e, "height", $max(0, int(round(h))) & "px")

proc syncDefaultLayoutGeometry*[R, N](r: R; f: DefaultDebugFrame[N];
                                      rootWidth, rootHeight: float) =
  ## `surfaces.js` `syncDefaultLayoutGeometry`, given `#ROOT`'s laid-out
  ## size: the golden-layout proportions the app opens with.
  const splitterSize = 4.0
  let width = rootWidth
  let height = rootHeight
  setBox(r, f.layout, width, height)
  let leftWidth = max(120.0, round(width * 0.133))
  let editorWidth = max(240.0, round(width * 0.332))
  let rightWidth = max(240.0, width - leftWidth - editorWidth - splitterSize * 2)
  let rightTopHeight = round((height - splitterSize) / 2)
  let rightBottomHeight = height - rightTopHeight - splitterSize
  let rightTopLeftWidth = floor((rightWidth - splitterSize) / 2)
  let rightTopRightWidth = rightWidth - rightTopLeftWidth - splitterSize
  proc boxOf(name: string): (float, float) =
    case name
    of "outerRow": (width, height)
    of "sidebar": (leftWidth, height)
    of "editor": (editorWidth, height)
    of "right": (rightWidth, height)
    of "rightTop": (rightWidth, rightTopHeight)
    of "rightTopLeft": (rightTopLeftWidth, rightTopHeight)
    of "rightTopRight": (rightTopRightWidth, rightTopHeight)
    of "rightBottom": (rightWidth, rightBottomHeight)
    else: (-1.0, -1.0)
  for (name, e) in f.boxes:
    let (w, h) = boxOf(name)
    if w >= 0: setBox(r, e, w, h)
  const headerHeight = 32.0
  for s in f.stacks:
    let (w, h) = boxOf(s.name)
    if w < 0: continue
    let contentHeight = max(0.0, h - headerHeight)
    setBox(r, s.stack, w, h)
    r.setStyle(s.header, "height", $int(headerHeight) & "px")
    setBox(r, s.items, w, contentHeight)
    for e in s.activeItems: setBox(r, e, w, contentHeight)
  # A splitter takes its parent's other extent: the rows' are the window's
  # height, or the right column's top row's.
  for i, s in f.hSplitters:
    setBox(r, s, splitterSize, if i == 0: rightTopHeight else: height)
  for s in f.vSplitters:
    setBox(r, s, rightWidth, splitterSize)
