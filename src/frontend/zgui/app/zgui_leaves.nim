## zgui/app/zgui_leaves.nim — the leaves of the zgui front-end: the editor's
## rows, the debugger panes through the vocabulary binding, and the dock
## projection drawn as flex containers.
##
## ## WHAT IS SHARED WITH THE GPUI FRONT-END, AND WHAT IS NOT
##
## Shared, imported unchanged, because it is renderer-free:
##   * the shell's leaves (`gpui/app/shell.leavesFor`): which pane is drawn
##     where, with which ViewModel;
##   * the dock projection (`gpui/app/dock_projection.projectDock`): the
##     arrangement as a document of stack and tab panels;
##   * the pane views (`view_vocabulary/pane_views.paneView`) and the editor's
##     row model (`view_vocabulary/editor_surface`), with its per-line flow
##     state and inline values.
##
## This module's own: turning each of those into zgui elements. Where GPUI
## spells a layout as a style per element, this module writes classes and
## lets one stylesheet (`ZguiLeavesCss`) lay them out — zgui runs CSS.
##
## ## ONLY WHAT CHANGED IS WRITTEN
##
## A pane is drawn once and then updated in place (`zgui_binding.update`); an
## editor row is replaced only when the row model says something different
## about it. So a step writes the rows whose pointer, values or flow moved and
## the cells of the panes that changed. The counters (`ZguiLeaves.rowsWritten`,
## the bindings' `replaced` / `written`) let a test hold that to account.

import std/[json, strutils, tables]

import isonim_zgui/renderer

import ../../gpui/app/shell
import ../../gpui/app/dock_projection
import ../../gpui/app/pane_names
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/editor_surface
import ../../view_vocabulary/zgui_binding
import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../../tui/app/syntax/lexical
import ../../tui/app/theme/editor_theme
import ../../styles/generated/design_tokens
import headless_app/layout_model

const
  ZguiMedium* = "zgui"
    ## The name this front-end answers to in `EditorSurface.medium`.

  PaneRoleAttribute* = "data-ct-pane"
  StateAttribute* = "data-ct-state"
  EditorRowAttribute* = "data-ct-row"
  EditorPointerAttribute* = "data-ct-pointer"
  EditorMarkAttribute* = "data-ct-mark"
  EditorFlowAttribute* = "data-ct-flow"
  EditorHeldAttribute* = "data-ct-held"
  EditorValuesAttribute* = "data-ct-values"
  InlineValuesAttribute* = "data-ct-inline-values"
    ## The attribute names the GPUI leaves write, spelled the same, so a reader
    ## of either front-end's tree asks the same question.

  EditorLinePx* = 20

proc hex(t: DesignToken): string = DesignTokenHex[t][dmDark]

let ZguiLeavesCss* = """
.ct-window { display: flex; flex-direction: column; width: 100%; height: 100%;
  background-color: """ & hex(dtEditorThemeGround) & """; color: #cccccc;
  font-family: sans-serif; font-size: 13px; }
.ct-body { display: flex; flex-direction: row; flex: 1 1 0; min-height: 0; }
.ct-centre { display: flex; flex: 1 1 0; min-width: 0; min-height: 0; }
.ct-stack { display: flex; flex: 1 1 0; min-width: 0; min-height: 0; }
.ct-stack-row { flex-direction: row; }
.ct-stack-column { flex-direction: column; }
.ct-tabs { display: flex; flex-direction: column; min-width: 0; min-height: 0;
  border: 1px solid #3c3c3c; }
.ct-tabstrip { display: flex; flex-direction: row; flex-shrink: 0;
  background-color: #252526; }
.ct-tab { padding: 3px 10px; color: #9d9d9d; white-space: nowrap; }
.ct-tab-active { color: #ffffff; background-color: """ & hex(dtEditorThemeGround) & """; }
.ct-pane { display: flex; flex-direction: column; flex: 1 1 0; min-height: 0;
  min-width: 0; overflow: hidden; }
.ct-pane-body { flex: 1 1 0; min-height: 0; overflow: hidden; padding: 2px 4px; }
.ct-dock-strip { display: flex; flex-direction: column; flex-shrink: 0;
  background-color: #252526; color: #9d9d9d; padding: 4px 2px; }
.ct-dock-strip-bottom { flex-direction: row; }
.ct-editor-rows { display: flex; flex-direction: column; flex: 1 1 0;
  min-height: 0; overflow: hidden; font-family: monospace; font-size: 13px; }
.ct-row { display: flex; flex-direction: row; flex-shrink: 0; height: """ &
  $EditorLinePx & """px; line-height: """ & $EditorLinePx & """px;
  white-space: nowrap; overflow: hidden; }
.ct-gutter { display: flex; flex-direction: row; flex-shrink: 0; width: 64px;
  color: """ & hex(dtEditorThemeLineNumber) & """; }
.ct-ptr { width: 14px; flex-shrink: 0; color: #ffcc00; }
.ct-mark { width: 14px; flex-shrink: 0; color: #e51400; }
.ct-num { flex: 1 1 0; text-align: right; padding-right: 8px; }
.ct-code { display: block; flex: 1 1 0; min-width: 0; white-space: pre;
  overflow: hidden; }
.ct-row-exec .ct-code { background-color: """ & hex(dtEditorThemeExecutionLine) & """; }
.ct-row-exec .ct-num { color: """ & hex(dtEditorThemeActiveLineNumber) & """; }
.ct-row-skip .ct-code { opacity: 0.5; }
.ct-flow { display: inline-block; padding-left: 18px; font-family: sans-serif;
  font-size: 12px; }
.ct-chip { display: inline-block; margin-right: 7px; padding: 0 7px; height: 18px;
  line-height: 18px; margin-top: 1px; border-radius: 4px;
  background-color: #3a3d41; white-space: nowrap; }
.ct-chip-name { color: #9d9d9d; padding-right: 7px; }
.ct-chip-value { color: #e8e8e8; font-weight: bold; }
.ct-report { color: #9d9d9d; padding: 6px; }
"""
  ## The leaves' layout and look. The colours are the design system's dark
  ## editor theme, the tokens the GPUI leaves paint with.

type
  PaneHost* = ref object
    ## One drawn pane: its element, its body and how the body is kept up to
    ## date.
    leaf*: GpuiLeaf
    el*: ZguiNode
    body*: ZguiNode
    binding*: ZguiBinding
      ## the vocabulary pane's binding; nil for the editor and a report.

  EditorHost* = ref object
    el*: ZguiNode
    rowsEl*: ZguiNode
    rows*: seq[EditorRow]
    rowEls*: seq[ZguiNode]
    path*: string

  ZguiLeaves* = ref object
    ## Everything this front-end drew for one window.
    renderer*: ZguiRenderer
    root*: ZguiNode
      ## the `.ct-window` element.
    body*: ZguiNode
      ## the dock area, below the top bar.
    panes*: Table[string, PaneHost]
      ## by pane id (`$PaneKind`).
    editor*: EditorHost
    leafSet*: GpuiLeafSet
    rowsWritten*: int
      ## Editor rows created since the counters were last reset.
    onTab*: proc(paneId: string) {.closure.}
      ## A tab's press, for the host to bring that pane to the front.
    onViewKey*: proc(paneId: string; binding: ZguiBinding) {.closure.}
      ## A key a pane's view consumed (a list's highlight, a table's row),
      ## after the view wrote its new state, for the host's timing record.

# ---------------------------------------------------------------------------
# The editor
# ---------------------------------------------------------------------------

func markGlyph(m: EditorMark): string =
  case m
  of emNone: ""
  of emBreakpoint: "●"
  of emTracepoint: "◆"
  else: "○"

func structuredValues*(values: openArray[EditorValue]): string =
  ## `name=value|name=value`, in draw order — the GPUI leaves' spelling.
  var parts: seq[string] = @[]
  for v in values: parts.add v.name & "=" & v.value
  parts.join("|")

func inlineValueText*(values: openArray[EditorValue]): string =
  ## `/* x: 42, str: "ready" */`, or "" for no values.
  if values.len == 0: return ""
  var parts: seq[string] = @[]
  for v in values: parts.add v.name & ": " & v.value
  "/* " & parts.join(", ") & " */"

func sameRow(a, b: EditorRow): bool =
  a.line == b.line and a.text == b.text and a.held == b.held and
    a.pointer == b.pointer and a.mark == b.mark and a.flow == b.flow and
    a.values == b.values

proc span(r: ZguiRenderer; cls, text: string): ZguiNode =
  result = r.createElement("span")
  if cls.len > 0: r.setAttribute(result, "class", cls)
  r.appendChild(result, r.createTextNode(text))

proc renderEditorRow*(r: ZguiRenderer; row: EditorRow;
                      runs: seq[TokenRun]): ZguiNode =
  ## One row of the source editor. Every attribute is the row model's own
  ## field stringified; the look is the stylesheet's, chosen by class.
  result = r.createElement("div")
  var cls = "ct-row"
  if row.pointer == eptExecution: cls.add " ct-row-exec"
  if row.flow == efsNotTaken: cls.add " ct-row-skip"
  r.setAttribute(result, "class", cls)
  r.setAttribute(result, EditorRowAttribute, $row.line)
  r.setAttribute(result, EditorPointerAttribute, $row.pointer)
  r.setAttribute(result, EditorMarkAttribute, $row.mark)
  r.setAttribute(result, EditorFlowAttribute, $row.flow)
  r.setAttribute(result, EditorHeldAttribute, $row.held)
  r.setAttribute(result, EditorValuesAttribute, structuredValues(row.values))

  let gutter = r.createElement("div")
  r.setAttribute(gutter, "class", "ct-gutter")
  r.appendChild(gutter, span(r, "ct-ptr",
    if row.pointer == eptExecution: "▶" else: " "))
  r.appendChild(gutter, span(r, "ct-mark", markGlyph(row.mark)))
  r.appendChild(gutter, span(r, "ct-num", $row.line))
  r.appendChild(result, gutter)

  let code = r.createElement("div")
  r.setAttribute(code, "class", "ct-code")
  if not row.held:
    r.appendChild(code, span(r, "", "…"))
  elif runs.len == 0:
    r.appendChild(code, span(r, "", row.text))
  else:
    for run in runs:
      let s = span(r, "", run.text)
      r.setStyle(s, "color", DesignTokenHex[tokenClassToken(run.class)][dmDark])
      r.appendChild(code, s)

  # The flow's inline values, as the desktop draws them: one chip per value
  # after the code, the name subdued and the value bold.
  if row.values.len > 0:
    let flow = r.createElement("div")
    r.setAttribute(flow, "class", "ct-flow")
    r.setAttribute(flow, InlineValuesAttribute, inlineValueText(row.values))
    for v in row.values:
      let chip = r.createElement("div")
      r.setAttribute(chip, "class", "ct-chip")
      r.appendChild(chip, span(r, "ct-chip-name", v.name))
      r.appendChild(chip, span(r, "ct-chip-value", v.value))
      r.appendChild(flow, chip)
    r.appendChild(code, flow)
  r.appendChild(result, code)

proc editorRunsOf*(surface: EditorSurface): seq[seq[TokenRun]] =
  ## Every row's text classified as the terminal and GPUI classify it.
  let lexer = if grammarForPath(surface.path) != giNone: lxNone
              else: lexerForPath(surface.path)
  var context = if surface.entryContext.len > 0: surface.entryContext
                else: initialContext(lexer)
  for row in surface.rows:
    if lexer == lxNone or not row.held: result.add @[]
    else: result.add tokenRuns(lexer, row.text, context)

proc updateEditor*(z: ZguiLeaves; surface: EditorSurface) =
  ## Show `surface`'s rows, creating only the rows that differ from what is
  ## drawn.
  let e = z.editor
  if e.isNil: return
  let r = z.renderer
  let runs = editorRunsOf(surface)
  if surface.path != e.path:
    # Another file: no row of the old one says anything about the new one.
    for el in e.rowEls: el.release()
    e.rowEls = @[]
    e.rows = @[]
    e.path = surface.path
  for i, row in surface.rows:
    if i < e.rows.len and sameRow(e.rows[i], row):
      continue
    let fresh = renderEditorRow(r, row, runs[i])
    inc z.rowsWritten
    if i < e.rowEls.len:
      r.insertBefore(e.rowsEl, fresh, e.rowEls[i])
      e.rowEls[i].release()
      e.rowEls[i] = fresh
      e.rows[i] = row
    else:
      r.appendChild(e.rowsEl, fresh)
      e.rowEls.add fresh
      e.rows.add row
  while e.rowEls.len > surface.rows.len:
    e.rowEls[^1].release()
    e.rowEls.setLen(e.rowEls.len - 1)
    e.rows.setLen(e.rows.len - 1)
  if surface.rows.len == 0 and surface.report.len > 0:
    r.setAttribute(e.el, StateAttribute, "editor-report")
  else:
    r.setAttribute(e.el, StateAttribute, "live")

# ---------------------------------------------------------------------------
# Panes
# ---------------------------------------------------------------------------

proc titleOf(leaf: GpuiLeaf): string =
  if leaf.title.len > 0: leaf.title
  elif leaf.kind == glkBuiltin: gpuiPaneName(leaf.builtin)
  else: leaf.paneId

proc paneModel(leaf: GpuiLeaf): (ViewNode, string) =
  ## The pane's vocabulary tree, or the report it shows instead.
  if leaf.kind != glkBuiltin:
    return (nil, "This pane is provided by an extension that is not loaded: " &
                 leaf.paneId)
  if not leaf.live and leaf.builtin notin PaneAcceptedExceptions:
    # The session supplies the debugger panes' ViewModels; a pane whose
    # ViewModel a host attaches (VCS, tests, build) has none in this
    # proof of concept, and says so rather than promising one.
    return (nil, titleOf(leaf) & " — not available in the zgui front-end yet")
  let pv = paneView(leaf.builtin, leaf.vm, GpuiPanelBudget, ZguiMedium)
  (pv.root, pv.report)

proc renderPane(z: ZguiLeaves; leaf: GpuiLeaf): PaneHost =
  let r = z.renderer
  result = PaneHost(leaf: leaf)
  result.el = r.createElement("div")
  r.setAttribute(result.el, "class", "ct-pane")
  r.setAttribute(result.el, PaneRoleAttribute, leaf.paneId)
  result.body = r.createElement("div")
  r.setAttribute(result.body, "class",
    if leaf.kind == glkBuiltin and leaf.builtin == paneEditor:
      "ct-editor-rows" else: "ct-pane-body")
  r.appendChild(result.el, result.body)
  if leaf.kind == glkBuiltin and leaf.builtin == paneEditor:
    z.editor = EditorHost(el: result.el, rowsEl: result.body)
    r.setAttribute(result.el, StateAttribute, "live")
    return
  let (model, report) = paneModel(leaf)
  if model.isNil:
    r.setAttribute(result.el, StateAttribute, "pane-report")
    r.appendChild(result.body, span(r, "ct-report", report))
    return
  r.setAttribute(result.el, StateAttribute,
                 if report.len > 0: "pane-report" else: "live")
  result.binding = renderZgui(r, model)
  let binding = result.binding
  let paneId = leaf.paneId
  binding.onKeyHandled = proc(id: string) =
    if not z.onViewKey.isNil: z.onViewKey(paneId, binding)
  r.appendChild(result.body, result.binding.root)

proc refreshPane*(z: ZguiLeaves; paneId: string) =
  ## Bring one pane up to date with its ViewModel, in place.
  let host = z.panes.getOrDefault(paneId)
  if host.isNil or host.binding.isNil: return
  let (model, report) = paneModel(host.leaf)
  if model.isNil: return
  host.binding.update(model)
  z.renderer.setAttribute(host.el, StateAttribute,
                          if report.len > 0: "pane-report" else: "live")

proc refreshPanes*(z: ZguiLeaves) =
  for id, host in z.panes:
    if not host.binding.isNil: z.refreshPane(id)

proc resetCounters*(z: ZguiLeaves) =
  z.rowsWritten = 0
  for _, host in z.panes:
    if not host.binding.isNil: host.binding.resetCounters()

proc paneWork*(z: ZguiLeaves): tuple[replaced, written: int] =
  for _, host in z.panes:
    if not host.binding.isNil:
      result.replaced += host.binding.replaced
      result.written += host.binding.written

# ---------------------------------------------------------------------------
# The dock projection, as flex containers
# ---------------------------------------------------------------------------

proc paneIdOf(panel: JsonNode): string =
  let info = panel{"info", "panel"}
  if info.isNil: return panel{"panel_name"}.getStr("")
  if info.hasKey(PaneInfoKey): info[PaneInfoKey].getStr("")
  else: info{ContributedPaneInfoKey}.getStr("")

proc leafFor(z: ZguiLeaves; paneId: string): (bool, GpuiLeaf) =
  for leaf in z.leafSet.leaves:
    if leaf.paneId == paneId and not leaf.topStrip: return (true, leaf)
  (false, GpuiLeaf())

proc paneElement(z: ZguiLeaves; paneId: string): ZguiNode =
  let (ok, leaf) = z.leafFor(paneId)
  if not ok: return span(z.renderer, "ct-report", paneId)
  let host = z.renderPane(leaf)
  z.panes[paneId] = host
  host.el

proc renderPanel(z: ZguiLeaves; panel: JsonNode): ZguiNode

proc onTabClick(z: ZguiLeaves; id: string): ZguiHandler =
  ## Made outside the loop that installs it, so each tab answers for itself.
  result = proc(ev: ZguiEvent): uint32 =
    if not z.onTab.isNil: z.onTab(id)
    0'u32

proc renderTabs(z: ZguiLeaves; panel: JsonNode): ZguiNode =
  let r = z.renderer
  result = r.createElement("div")
  r.setAttribute(result, "class", "ct-tabs")
  let kids = panel{"children"}.getElems
  let active = clamp(panel{"info", "tabs", "active_index"}.getInt(0), 0,
                     max(0, kids.len - 1))
  let strip = r.createElement("div")
  r.setAttribute(strip, "class", "ct-tabstrip")
  for i, k in kids:
    let id = paneIdOf(k)
    let (ok, leaf) = z.leafFor(id)
    let tab = span(r, if i == active: "ct-tab ct-tab-active" else: "ct-tab",
                   if ok: titleOf(leaf) else: id)
    r.setAttribute(tab, "data-ct-tab", id)
    addListener(tab, "click", z.onTabClick(id))
    r.appendChild(strip, tab)
  r.appendChild(result, strip)
  if kids.len > 0:
    r.appendChild(result, z.paneElement(paneIdOf(kids[active])))

proc renderPanel(z: ZguiLeaves; panel: JsonNode): ZguiNode =
  let r = z.renderer
  case panel{"panel_name"}.getStr("")
  of "StackPanel":
    result = r.createElement("div")
    let axis = panel{"info", "stack", "axis"}.getInt(0)
    r.setAttribute(result, "class",
      "ct-stack " & (if axis == 0: "ct-stack-row" else: "ct-stack-column"))
    let sizes = panel{"info", "stack", "sizes"}.getElems
    for i, c in panel{"children"}.getElems:
      let child = z.renderPanel(c)
      # The projected extents become flex weights, so the arrangement keeps
      # its proportions at whatever size the window is.
      let grow = if i < sizes.len: max(1.0, sizes[i].getFloat) else: 1.0
      r.setStyle(child, "flex", $grow & " 1 0px")
      r.setStyle(child, "min-width", "0")
      r.setStyle(child, "min-height", "0")
      r.appendChild(result, child)
  of "TabPanel":
    result = z.renderTabs(panel)
  else:
    result = z.paneElement(paneIdOf(panel))

proc renderDockStrip(z: ZguiLeaves; dock: JsonNode; bottom: bool): ZguiNode =
  ## A docked edge, drawn closed as the projection says (`open: false`): a
  ## strip naming its panes.
  let r = z.renderer
  result = r.createElement("div")
  r.setAttribute(result, "class",
    if bottom: "ct-dock-strip ct-dock-strip-bottom" else: "ct-dock-strip")
  r.setAttribute(result, "data-ct-dock-placement", dock{"placement"}.getStr(""))
  for k in dock{"panel", "children"}.getElems:
    let id = paneIdOf(k)
    let (ok, leaf) = z.leafFor(id)
    r.appendChild(result, span(r, "ct-tab", if ok: titleOf(leaf) else: id))

proc renderLeaves*(r: ZguiRenderer; leafSet: GpuiLeafSet;
                   projection: DockProjection; topBar: ZguiNode): ZguiLeaves =
  ## The window's whole tree: the top bar, then the projected arrangement.
  result = ZguiLeaves(renderer: r, leafSet: leafSet)
  result.root = r.createElement("div")
  r.setAttribute(result.root, "class", "ct-window")
  r.setAttribute(result.root, "data-ct-window", $int(leafSet.windowId))
  if not topBar.isNil: r.appendChild(result.root, topBar)
  if projection.status == dpsRefused or leafSet.refused.len > 0:
    r.setAttribute(result.root, StateAttribute, "refused")
    r.appendChild(result.root, span(r, "ct-report",
      "layout refused: " & describe(leafSet.refused)))
    return
  let doc = projection.state
  let body = r.createElement("div")
  r.setAttribute(body, "class", "ct-body")
  result.body = body
  if doc.hasKey("left_dock"):
    r.appendChild(body, result.renderDockStrip(doc["left_dock"], false))
  let centre = r.createElement("div")
  r.setAttribute(centre, "class", "ct-centre")
  r.appendChild(centre, result.renderPanel(doc["center"]))
  r.appendChild(body, centre)
  if doc.hasKey("right_dock"):
    r.appendChild(body, result.renderDockStrip(doc["right_dock"], false))
  r.appendChild(result.root, body)
  if doc.hasKey("bottom_dock"):
    r.appendChild(result.root, result.renderDockStrip(doc["bottom_dock"], true))

proc rebuildArrangement*(z: ZguiLeaves; leafSet: GpuiLeafSet;
                         projection: DockProjection) =
  ## The arrangement changed (a tab was brought to the front): draw it again.
  ## The panes are drawn again with it; their ViewModels are unchanged.
  let r = z.renderer
  z.leafSet = leafSet
  z.panes = initTable[string, PaneHost]()
  let oldEditor = z.editor
  z.editor = nil
  if projection.status == dpsRefused: return
  let centre = r.createElement("div")
  r.setAttribute(centre, "class", "ct-centre")
  r.appendChild(centre, z.renderPanel(projection.state["center"]))
  var old = r.firstChild(z.body)
  while not old.isNil:
    if getAttribute(old, "class") == "ct-centre": break
    old = r.nextSibling(old)
  if not old.isNil:
    r.insertBefore(z.body, centre, old)
    old.release()
  discard oldEditor
