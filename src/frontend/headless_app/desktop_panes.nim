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
  ## The exact bytes `src/config/default_layout.json` must hold: the BUNDLED
  ## tree (`layout_model.sharedBundledLayout`), translated, pretty-printed
  ## with the four-space indent the hand-written file used, and a trailing
  ## newline.
  pretty(layoutNodeToGoldenConfig(sharedBundledLayout()), indent = 4) & "\n"

# ---------------------------------------------------------------------------
# The inverse translation: a GoldenLayout config the desktop loads, read back
# into the shared vocabulary (PLAT-47 deliverable 1)
# ---------------------------------------------------------------------------
#
# `layoutNodeToGoldenConfig` writes the BUNDLED tree; the desktop then derives
# each mode's default from it (`index/mode_default_layout.modeDefaultLayout`).
# The default every front-end opens with is the desktop's DEBUG-mode default,
# so the generator reads that config back through this function and writes the
# result as the shared default. It undoes exactly the three runtime facts the
# forward translation encodes (module header): top-level columns holding one
# region become that region, and the editor the runtime inserts at index 1 of
# the root row is put back there with the share the runtime gives it.

proc sizePercent(item: JsonNode): float =
  ## An item's declared `size` in percent, or 0 for none (an equal share).
  if item.isNil or item.kind != JObject or not item.hasKey("size"):
    return 0.0
  let raw = item["size"]
  case raw.kind
  of JString:
    var text = raw.getStr.strip
    if text.endsWith("%"):
      text.setLen(text.len - 1)
      try:
        return parseFloat(text)
      except ValueError:
        return 0.0
    0.0
  of JInt: float(raw.getInt)
  of JFloat: raw.getFloat
  else: 0.0

proc roundWeight(x: float): float =
  ## Two decimals, which is what `percentText` writes: a weight read back is
  ## the number the config said, not a binary neighbour of it.
  round(x * 100.0) / 100.0

proc goldenItemToNode(item: JsonNode): LayoutNode =
  if item.isNil or item.kind != JObject:
    raise newException(ValueError, "a layout item is not an object")
  let kind = item{"type"}.getStr
  case kind
  of "component":
    let content = item{"componentState", "content"}
    if content.isNil or content.kind != JInt:
      raise newException(ValueError, "a component names no content ordinal")
    let p = paneOfContent(content.getInt)
    if p.isNone:
      raise newException(ValueError, "content ordinal " & $content.getInt &
        " names no pane of the shared vocabulary")
    result = pane(p.get)
  of "stack":
    var kids: seq[LayoutNode] = @[]
    for c in item{"content"}.getElems:
      kids.add goldenItemToNode(c)
    let active = if item.hasKey("activeItemIndex"): item["activeItemIndex"].getInt
                 else: 0
    result = stack(kids, activeIndex = max(0, min(active, max(0, kids.high))))
  of "row", "column":
    var kids: seq[LayoutNode] = @[]
    let items = item{"content"}.getElems
    var explicit = false
    for c in items:
      if sizePercent(c) > 0.0: explicit = true
    for c in items:
      let child = goldenItemToNode(c)
      child.weight = if explicit: roundWeight(sizePercent(c)) else: 0.0
      kids.add child
    result = if kind == "row": row(kids) else: column(kids)
  else:
    raise newException(ValueError, "unknown layout item type '" & kind & "'")

proc unwrapRegion(n: LayoutNode): LayoutNode =
  ## A container of ONE child is that child, keeping the container's weight —
  ## rule 3's column around a top-level stack, undone.
  result = n
  while result.kind in {lnRow, lnColumn} and result.children.len == 1:
    let w = result.weight
    result = result.children[0]
    result.weight = w

proc goldenConfigToLayoutNode*(config: JsonNode): LayoutNode =
  ## **THE INVERSE TRANSLATION.** The arrangement a desktop user sees for
  ## `config` — the config plus what the runtime does with it — as a
  ## `LayoutNode`. Raises `ValueError` for a config that names a pane the
  ## shared vocabulary does not, or that has no root row.
  ##
  ## The editor's share is the runtime's (`utils.openNewLayoutContainer`):
  ## when the root row's declared sizes leave room
  ## (`unclaimedTopLevelPercent`, 0 < free < 100) the editor takes that room
  ## and the others keep their declared percentages; when they claim all of
  ## it, GoldenLayout's `addChild` gives the editor `1/n` and scales the rest
  ## by `(n-1)/n`.
  if config.isNil or config.kind != JObject:
    raise newException(ValueError, "the layout config is not an object")
  let root = if config.hasKey("root"): config["root"] else: config
  if root.isNil or root{"type"}.getStr != "row":
    raise newException(ValueError, "the layout config's root is not a row")
  let items = root{"content"}.getElems
  var declared: seq[float] = @[]
  var total = 0.0
  for c in items:
    let s = sizePercent(c)
    declared.add s
    total += s
  var regions: seq[LayoutNode] = @[]
  for c in items:
    regions.add unwrapRegion(goldenItemToNode(c))
  let free = 100.0 - total
  let n = items.len + 1
  let editorShare =
    if free > 0.0 and free < 100.0: round(free)
    else: 100.0 / float(n)
  var kids: seq[LayoutNode] = @[]
  for i, r in regions:
    if i == DesktopEditorIndex:
      kids.add pane(paneEditor, weight = roundWeight(editorShare))
    r.weight =
      if total > 0.0: roundWeight(declared[i] / total * (100.0 - editorShare))
      else: 0.0
    kids.add r
  if regions.len < DesktopEditorIndex + 1:
    kids.add pane(paneEditor, weight = roundWeight(editorShare))
  result = row(kids)

proc generatedSharedDefaultText*(debugModeConfig: JsonNode): string =
  ## The exact bytes `headless_app/shared_default_layout.generated.json` must
  ## hold, given the desktop's DEBUG-mode default config
  ## (`mode_default_layout.modeDefaultLayout(bundled, DebugMode)`): that
  ## config read back into the shared vocabulary, validated, as a layout
  ## document node.
  let tree = goldenConfigToLayoutNode(debugModeConfig)
  discard normaliseInPlace(tree)
  let problems = validate(tree)
  if problems.len > 0:
    raise newException(ValueError, "the debug-mode default does not " &
      "validate: " & $problems[0].kind & " at '" & problems[0].path & "'")
  pretty(toJson(tree), indent = 2) & "\n"
