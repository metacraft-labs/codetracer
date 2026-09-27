## headless_app/desktop_panes.nim — PLAT-45. **Where `PaneKind` meets the
## desktop's `Content` ordinals, and the translation of the shared default into
## the GoldenLayout config the desktop loads.**
##
## ## The one place the two id spaces meet
##
## The shared model names panes by `PaneKind`; the desktop names them by its
## `Content` enum (`common_types/codetracer_features/frontend.nim`), whose
## ordinals are what a GoldenLayout config's `componentState.content` carries.
## `PaneContent` below is the ONLY table that relates the two (PLAT-45
## deliverable 1). Everything that needs the relation — the generator of
## `src/config/default_layout.json`, the reducer that reads the desktop's loaded
## config back into the shared vocabulary, the desktop's capability — reads it
## from here, and `test_shared_default_layout.nim` asserts it is one-to-one.
##
## ## Why this is not in `layout_model.nim`
##
## `layout_model` is on the consumer side of the SDK boundary and imports no
## product type; `Content` is the desktop's. Keeping the table in its own module
## means the model never learns the desktop's ids, and the desktop's ids reach
## the shared vocabulary through exactly one import.
##
## ## What the translation does, and the three runtime facts it encodes
##
## `layoutNodeToGoldenConfig` turns a `LayoutNode` into the config the desktop
## loads. It is not a general `LayoutNode` → GoldenLayout mapping; it encodes
## what the desktop's runtime does with the config it is handed, because the
## ARRANGEMENT the user sees is the config plus that runtime:
##
##   1. **The editor is not in the config.** `utils.openNewLayoutContainer`
##      creates the editor's container at index 1 of the root row at runtime
##      (`sanitizeLayoutConfig` strips editor tabs on every save, so a declared
##      editor stack would be emptied and dropped). So the editor leaf is
##      skipped — and REFUSED anywhere but index 1 of the root row, because a
##      tree that put it elsewhere would render somewhere the tree does not say.
##   2. **The editor takes an equal share at runtime.** With the declared sizes
##      summing to 100%, `unclaimedTopLevelPercent` is 0 and GoldenLayout's
##      `addChild` gives the editor `1/n` of the row, scaling the rest by
##      `(n-1)/n`. The shared tree's weights are the RENDERED shares, so the
##      root row's declared percentages are the other children's weights
##      renormalised without the editor — which is what makes the runtime
##      arrive back at the shared tree's shares.
##   3. **Top-level regions are columns.** Every child of the desktop's root
##      row is a GoldenLayout column (the edit and review modes prune and hide
##      by column), so a top-level stack is emitted inside a column of its own.

import std/[json, math, options, strutils]

import layout_model
import ../../common/types

type
  DesktopPlacement* = enum
    ## How the desktop draws a pane.
    dpLayout = "layout"
      ## A GoldenLayout component in the config.
    dpRuntimeEditor = "runtime-editor"
      ## The editor: created by the runtime at index 1 of the root row.
    dpToolbar = "toolbar"
      ## Drawn as chrome outside GoldenLayout (the debug controls).
    dpNone = "none"
      ## Not a pane on the desktop at all.

  DesktopPane* = object
    placement*: DesktopPlacement
    content*: Content
      ## Meaningless when `placement == dpNone`.
    label*: string
      ## The `componentState.label` the desktop's config gives the pane. The
      ## labels are the desktop's own historical spellings (the Files pane is
      ## `filesystemComponent` with no `-0`, the Terminal Output pane is
      ## `terminalComponent-0`), and they are carried rather than derived
      ## because DeepReview and the auto-hide state look panes up by them.

const
  PaneContent*: array[PaneKind, DesktopPane] = [
    paneEditor: DesktopPane(placement: dpRuntimeEditor,
                            content: Content.EditorView,
                            label: "editorComponent-0"),
    paneCalltrace: DesktopPane(placement: dpLayout, content: Content.Calltrace,
                               label: "calltraceComponent-0"),
    paneState: DesktopPane(placement: dpLayout, content: Content.State,
                           label: "stateComponent-0"),
    paneEventLog: DesktopPane(placement: dpLayout, content: Content.EventLog,
                              label: "eventLogComponent-0"),
    paneDebugControls: DesktopPane(placement: dpToolbar, content: Content.Debug,
                                   label: "debugComponent-0"),
    paneFlow: DesktopPane(placement: dpNone, content: Content.History,
                          label: ""),
    paneTimeline: DesktopPane(placement: dpLayout, content: Content.Timeline,
                              label: "timelineComponent-0"),
    paneSearch: DesktopPane(placement: dpLayout,
                            content: Content.SearchResults,
                            label: "searchResultsComponent-0"),
    panePointList: DesktopPane(placement: dpLayout, content: Content.PointList,
                               label: "pointListComponent-0"),
    paneScratchpad: DesktopPane(placement: dpLayout,
                                content: Content.Scratchpad,
                                label: "scratchpadComponent-0"),
    paneShell: DesktopPane(placement: dpLayout, content: Content.Shell,
                           label: "shellComponent-0"),
    paneFileTree: DesktopPane(placement: dpLayout, content: Content.Filesystem,
                              label: "filesystemComponent"),
    paneBuildOutput: DesktopPane(placement: dpLayout, content: Content.Build,
                                 label: "buildComponent-0"),
    paneVcs: DesktopPane(placement: dpLayout, content: Content.VCS,
                         label: "vCSComponent-0"),
    paneAgentActivity: DesktopPane(placement: dpLayout,
                                   content: Content.AgentActivity,
                                   label: "agentActivityComponent-0"),
    paneTerminalOutput: DesktopPane(placement: dpLayout,
                                    content: Content.TerminalOutput,
                                    label: "terminalComponent-0"),
    paneTestResults: DesktopPane(placement: dpLayout,
                                 content: Content.TestResults,
                                 label: "testResultsComponent-0"),
    paneConstraints: DesktopPane(placement: dpLayout,
                                 content: Content.Constraints,
                                 label: "constraintsComponent-0")]
    ## **THE TABLE.** Indexed by `PaneKind`, so a `PaneKind` added without a
    ## row does not compile. One-to-one on the rows that have a `Content`
    ## (`dpNone` is the one row without), asserted by the suite.


proc desktopCapability*(): PaneCapability =
  ## PLAT-45 deliverable 2, the desktop's row: every pane with a desktop view,
  ## i.e. every row of `PaneContent` except `dpNone`, derived from the table
  ## rather than listed beside it.
  var drawable: set[PaneKind] = {}
  var reasons: seq[(PaneKind, string)] = @[]
  for p in PaneKind:
    if PaneContent[p].placement == dpNone:
      reasons.add (p, "the desktop draws " & $p & " inside another pane " &
                      "(flow is an overlay of the editor), not as a pane of " &
                      "its own")
    else:
      drawable.incl p
  paneCapability(feDesktop, drawable, reasons)

proc paneOfContent*(content: int): Option[PaneKind] =
  ## The inverse of `PaneContent`, over a config's raw `componentState.content`
  ## ordinal. `none` for an ordinal no pane maps to — a desktop-only content
  ## the shared vocabulary does not name.
  for p in PaneKind:
    let row = PaneContent[p]
    if row.placement != dpNone and ord(row.content) == content:
      return some(p)
  none(PaneKind)

const
  GoldenSettings = """{"constrainDragToContainer": true, "reorderEnabled": true,
    "popoutWholeStack": false, "blockedPopoutsThrowError": true,
    "responsiveMode": "always", "tabOverlapAllowance": 2,
    "tabControlOffset": 0}"""
  GoldenDimensions = """{"borderWidth": 4, "borderHeight": 4,
    "headerHeight": 32, "dragProxyWidth": 300, "dragProxyHeight": 200}"""
    ## GoldenLayout's own settings and dimensions, carried over verbatim from
    ## the hand-written file. They describe the ENGINE, not the arrangement,
    ## so they are constants of the translation rather than of the tree.
  GenericComponent = "genericUiComponent"

  DesktopEditorIndex* = 1
    ## Where `utils.openNewLayoutContainer` puts the editor: index 1 of the
    ## root row. The translation refuses a tree whose editor is anywhere else.

proc percentText*(x: float): string =
  ## `20%`, `55%`, `41.25%` — at most two decimals, no trailing zeros.
  var s = formatFloat(round(x * 100.0) / 100.0, ffDecimal, 2)
  s.trimZeros()
  if s.endsWith("."):
    s.setLen(s.len - 1)
  s & "%"

proc componentJson(kind: PaneKind): JsonNode =
  let row = PaneContent[kind]
  if row.placement != dpLayout:
    raise newException(ValueError,
      "the desktop cannot place '" & $kind & "' in its layout (" &
      $row.placement & ")")
  result = newJObject()
  result["type"] = %"component"
  result["componentType"] = %GenericComponent
  result["componentState"] = %*{"id": 0, "label": row.label,
                                "content": ord(row.content)}
  result["title"] = %GenericComponent

proc emitted(n: LayoutNode): bool =
  ## Whether a node produces any GoldenLayout item — false for the editor leaf
  ## and for a container holding nothing else.
  if n.isNil: return false
  case n.kind
  of lnPane:
    not n.isContributed and PaneContent[n.pane].placement != dpRuntimeEditor
  else:
    for c in n.children:
      if emitted(c): return true
    false

proc sizesOf(children: seq[LayoutNode]): seq[string] =
  ## The `size` each emitted child declares, or `""` for none. All-implicit
  ## weights (every one `0`) declare nothing: that is GoldenLayout's own
  ## "equal share", exactly as it is the model's.
  var kept: seq[LayoutNode] = @[]
  for c in children:
    if emitted(c): kept.add c
  var anyExplicit = false
  var total = 0.0
  for c in kept:
    if c.weight > 0.0: anyExplicit = true
    total += effectiveWeight(c)
  for c in kept:
    if anyExplicit and total > 0.0:
      result.add percentText(effectiveWeight(c) / total * 100.0)
    else:
      result.add ""

proc itemJson(n: LayoutNode; size: string): JsonNode

proc containerJson(kind: string; children: seq[LayoutNode];
                   size: string): JsonNode =
  result = newJObject()
  result["type"] = %kind
  if size.len > 0:
    result["size"] = %size
  var content = newJArray()
  let sizes = sizesOf(children)
  var i = 0
  for c in children:
    if not emitted(c): continue
    content.add itemJson(c, sizes[i])
    inc i
  result["content"] = content

proc itemJson(n: LayoutNode; size: string): JsonNode =
  case n.kind
  of lnRow: result = containerJson("row", n.children, size)
  of lnColumn: result = containerJson("column", n.children, size)
  of lnStack:
    result = newJObject()
    result["type"] = %"stack"
    if size.len > 0:
      result["size"] = %size
    var content = newJArray()
    var active = 0
    var at = 0
    for i, c in n.children:
      if c.kind != lnPane or c.isContributed:
        raise newException(ValueError,
          "a desktop stack holds built-in panes only")
      if PaneContent[c.pane].placement == dpRuntimeEditor:
        continue
      if i == n.activeIndex: active = at
      content.add componentJson(c.pane)
      inc at
    if active != 0:
      result["activeItemIndex"] = %active
    result["content"] = content
  of lnPane:
    # A bare leaf is a one-tab stack: GoldenLayout holds components in stacks.
    result = newJObject()
    result["type"] = %"stack"
    if size.len > 0:
      result["size"] = %size
    result["content"] = %*[componentJson(n.pane)]

proc layoutNodeToGoldenConfig*(tree: LayoutNode): JsonNode =
  ## **THE TRANSLATION** (PLAT-45 deliverable 7). The whole config the desktop
  ## loads — settings, dimensions, root and popouts — for `tree`. See the
  ## module header for the three runtime facts it encodes. Raises `ValueError`
  ## for a tree the desktop cannot render as the tree says.
  if tree.isNil:
    raise newException(ValueError, "no tree")
  let problems = validate(tree)
  if problems.len > 0:
    raise newException(ValueError, "the tree does not validate: " &
      $problems[0].kind & " at '" & problems[0].path & "'")
  # THE ROOT IS A ROW, because the desktop's runtime inserts the editor into
  # `groundItem.contentItems[0]` — the root row.
  let root = if tree.kind == lnRow: tree else: row([tree])
  let editor = find(root, paneEditor)
  if not editor.isNil:
    let at = block:
      var idx = -1
      for i, c in root.children:
        if c == editor: idx = i
      idx
    if at != DesktopEditorIndex:
      raise newException(ValueError,
        "the desktop places the editor at index " & $DesktopEditorIndex &
        " of the root row; this tree puts it elsewhere")
  var content = newJArray()
  let sizes = sizesOf(root.children)
  var i = 0
  for c in root.children:
    if not emitted(c): continue
    let item =
      if c.kind == lnColumn:
        itemJson(c, sizes[i])
      else:
        # Rule 3: every top-level region of the desktop is a column.
        var col = newJObject()
        col["type"] = %"column"
        if sizes[i].len > 0:
          col["size"] = %sizes[i]
        col["content"] = %*[itemJson(c, "")]
        col
    content.add item
    inc i
  result = newJObject()
  result["settings"] = parseJson(GoldenSettings)
  result["dimensions"] = parseJson(GoldenDimensions)
  var rootJson = newJObject()
  rootJson["type"] = %"row"
  rootJson["size"] = %"100%"
  rootJson["isClosable"] = %false
  rootJson["content"] = content
  result["root"] = rootJson
  result["openPopouts"] = newJArray()

proc generatedDefaultLayoutText*(): string =
  ## The exact bytes `src/config/default_layout.json` must hold: the shared
  ## default at depth 0, translated, pretty-printed with the four-space indent
  ## the hand-written file used, and a trailing newline.
  pretty(layoutNodeToGoldenConfig(sharedDefaultLayout().tree), indent = 4) &
    "\n"
