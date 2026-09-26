## gpui/dock_projection.nim — PLAT-20. **`Layout` / `WindowSet` projected onto
## gpui-kit's dock, in one direction only.**
##
## ## The direction is the deliverable
##
## PLAT-20 asks for *"a binding from `Layout` / `WindowSet` to gpui-kit's dock —
## `DockArea`, `DockState`, `PaneTree`, `TabGroup` — with **our model
## authoritative and `DockState` a projection**, in the same direction the Yoga
## projection already runs for the terminal"*, and the milestone's own risk note
## says why: *"`DockState` becomes the source of truth because it is the thing
## the library wants to own, and the model degrades into a serialisation
## format."*
##
## So this module is written the way `tui/app/layout/project.nim` is written. It
## takes a `Layout` and a viewport and RETURNS a document. It holds no state, it
## has no setter, and nothing anywhere in this repository turns a `DockAreaState`
## back into a `Layout` — `readDockArrangement` below exists to COMPARE two
## projections in a test and says so in its own doc comment, which is the only
## place a decode appears at all.
##
## ## WHAT IS BOUND, AND WHAT IS NOT — READ THIS BEFORE BELIEVING THE HEADER
##
## **gpui-kit is not a dependency of this workspace, and PLAT-20 did not make it
## one.** That was measured rather than assumed, and there are three independent
## blockers; they are recorded in the PLAT-20 status block of
## `codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org` with the
## commands that produced them. The consequence for this file:
##
##   * What IS bound is the **persisted schema** — `DockAreaState`, `PanelState`,
##     `PanelInfo::{Stack,Tabs,Panel}`, `DockState` and `DockPlacement` as
##     defined in `crates/base/src/dock/state.rs` at gpui-kit
##     `959ccc5ea1ec23be8283c2c326467699a9b44729`. Those serde tags are frozen
##     upstream and asserted there by `the_serde_tags_are_frozen`.
##   * What is NOT bound is a live `DockArea` ENTITY. Nothing here constructs
##     one, nothing here drives `PaneTree::insert_panel`, and no test in this
##     repository observes a GPUI dock rendering. A milestone that vendors
##     gpui-kit owes that half.
##
## Saying it here rather than only in the milestone is deliberate: a header that
## claimed a dock binding would be the most comfortable place for an
## unfalsifiable claim to live (Verification-Harness-Traps §7a).
##
## ## `TilesState`: PLAT-4's decision, APPLIED — and upstream reached it too
##
## PLAT-4 declined gpui-kit's `Tiles` container (free positioning with overlap
## and z-order, which Layout-ViewModel §3A.2 rules out) after reading
## `crates/base/src/dock/tiles_state.rs` upstream at `9796bb7c`. PLAT-20 re-took
## that read at `959ccc5e` and the file **is not there**: upstream removed the
## tiles canvas on 2026-09-11 in `3f1dda6ee9256ba317b19552999d130e3d078159`
## ("dock: Remove the tiles canvas (#3036)"), `Tiles` occurs zero times in the
## repository, `NodeKind` in `crates/base/src/dock/layout/node.rs` has exactly
## `Split` and `Tabs`, and `DropTarget` lost its `Canvas` variant.
##
## Applying the decision here therefore costs nothing and is structural rather
## than conventional: `panelStateOf` below is an exhaustive `case` over
## `LayoutNodeKind`, it emits exactly two container `panel_name`s —
## `StackPanel` and `TabPanel` — and there is no third branch to add one from.
## `projectedPanelNames` names the closed set so a test can assert it rather
## than read it.
##
## ## Pixels are DERIVED; weights are the model's
##
## `PanelInfo::Stack` carries `sizes: Vec<Pixels>` and it is not optional, so a
## projection cannot decline to produce one. The weights stay the proportion —
## exactly as `project.nim` keeps Yoga's floats the proportion — and the pixel
## extents are divided out of the viewport by
## `headless_app/extent_distribution.distributeExtent`, the SAME routine the
## terminal projection divides cells with. That sharing is what makes
## `test_cross_projection_arrangement.nim`'s agreement a property rather than a
## coincidence of two implementations (Verification-Harness-Traps §14).

import std/[json, strutils]

import headless_app/layout_model
import headless_app/window_set
import headless_app/extent_distribution

export layout_model, window_set

type
  DockPlacement* = enum
    ## `crates/base/src/dock/state.rs`'s `DockPlacement`, whose serde renames
    ## are frozen upstream. **There is no `top`**, and that is a fact about
    ## gpui-kit rather than an omission here — see `dppNoPlacementForEdge`.
    dpCenter = "center"
    dpLeft = "left"
    dpBottom = "bottom"
    dpRight = "right"

  DockViewport* = object
    ## The extent the arrangement is divided over, in device-independent
    ## pixels. A PARAMETER rather than a constant for the reason
    ## `projectLayout` takes a `CellArea`: the model is resolution-independent
    ## and the pixels belong to the host's window.
    width*: int
    height*: int
    dockExtent*: int
      ## How many pixels an auto-hide strip is given. **The model does not
      ## carry this** — `DockedPane` has an edge and an order and no size — so
      ## it is the host's, stated here rather than invented inside the
      ## projection. Recorded as a residue in PLAT-20's status block.

  DockProjectionProblemKind* = enum
    ## Why a `Layout` has no dock document. Enumerated rather than reported as
    ## prose because a test branches on the kind.
    dppInvalidLayout = "InvalidLayout"
      ## `validate(Layout)` reported at least one problem. A projection of an
      ## invalid tree is how a pane goes missing quietly.
    dppEmptyLayout = "EmptyLayout"
      ## Nil, or a tree with no pane in it at all.
    dppNoPlacementForEdge = "NoPlacementForEdge"
      ## A pane is docked to `leTop` and gpui-kit's `DockPlacement` has no
      ## `top`. **Refused rather than dropped, relocated or rounded to
      ## `bottom`.** A silently relocated pane is exactly the "I lost a pane"
      ## failure Layout-ViewModel §3A.2 is written against, and a projection
      ## that quietly moved one would be true of the document and false of the
      ## user's layout.
    dppViewportTooSmall = "ViewportTooSmall"
      ## The viewport cannot give every sibling at least one pixel.
      ## `distributeExtent` returns an empty seq there, and inventing a
      ## zero-width panel instead is the `cpEmptyRegion` defect one medium
      ## across.

  DockProjectionProblem* = object
    kind*: DockProjectionProblemKind
    detail*: string
      ## Enough to find it: a pane name, an edge, or a path.

  DockProjectionStatus* = enum
    dpsProjected
    dpsRefused

  DockProjection* = object
    ## The result. The document sits on the `dpsProjected` branch of the
    ## variant, so a caller physically cannot read it without having branched —
    ## the same device PLAT-4 used for `LayoutOutcome`.
    case status*: DockProjectionStatus
    of dpsProjected:
      state*: JsonNode
        ## A gpui-kit `DockAreaState` document.
    of dpsRefused:
      problems*: seq[DockProjectionProblem]

  DockPaneSlot* = object
    ## One pane as the PROJECTED DOCUMENT places it. This is the vocabulary
    ## PLAT-20's cross-front-end test compares on — *"pane placement and stack
    ## membership, not appearance"* — so it carries no pixel and no title.
    pane*: string
      ## The model's own persisted id: `$PaneKind` for a built-in pane, the
      ## qualified id for a contributed one.
    contributed*: bool
    region*: DockPlacement
    path*: seq[int]
      ## Child indices from the region's root to the enclosing `TabPanel`.
      ## Two panes in one tab group share this exactly.
    tabIndex*: int
      ## Position within that tab group.
    tabCount*: int
      ## How many panes the tab group holds. `1` for an unstacked pane, which
      ## is not a special case: gpui-kit has no bare-leaf container, so an
      ## unstacked pane is a tab group of one (`bare_tab_panel_root.json`).
    activeIndex*: int
      ## The tab group's active index, as `PanelInfo::Tabs` carries it.

  DockArrangement* = object
    ## Every slot of one projected document, in document order.
    slots*: seq[DockPaneSlot]

const
  ProjectedPanelNames* = ["StackPanel", "TabPanel"]
    ## **The closed set of CONTAINER names this projection can emit**, and the
    ## applied form of PLAT-4's `TilesState` decision. gpui-kit's own dock had
    ## three container shapes until `3f1dda6`; it has two now, and this
    ## projection could only ever produce these two, because `panelStateOf` is
    ## an exhaustive `case` over `LayoutNodeKind` and none of its four arms
    ## builds a third.
    ##
    ## A leaf's `panel_name` is the pane's own id and is NOT in this list;
    ## `isContainerName` is the predicate, and the floating-panel assertion in
    ## `tests/test_gpui_dock_projection.nim` calls the same one.

  PaneInfoKey* = "pane"
  ContributedPaneInfoKey* = "contributedPane"
    ## The two keys a leaf's `info.panel` object carries, and the reason the
    ## reader below cannot mistake somebody else's document for ours.
    ##
    ## They are SEPARATE KEYS for the same reason `LayoutNode` keeps `pane` and
    ## `contributedPane` apart on the wire: a contributed id spelled exactly
    ## `"editor"` must not read back as `paneEditor`.

  DockSchemaVersion* = 1
    ## `DockAreaState.version` is `Option<usize>` upstream and the shipped
    ## fixture omits it. We write one, because a document we produced and a
    ## document gpui-kit's own examples produced should be distinguishable.

func isContainerName*(name: string): bool =
  ## Whether `name` is one of the two container shapes this projection emits.
  ## ONE PREDICATE: the emitter's exhaustiveness argument, the floating-panel
  ## assertion and the reader's descent all ask through this function rather
  ## than spelling the two strings again (Verification-Harness-Traps §14).
  for n in ProjectedPanelNames:
    if name == n:
      return true
  false

func placementFor*(edge: LayoutEdge): (bool, DockPlacement) =
  ## gpui-kit's placement for one of our four edges, or `(false, …)` for the
  ## one it has no name for. Returning a pair rather than raising is what lets
  ## the caller report `dppNoPlacementForEdge` with the edge in it.
  case edge
  of leLeft: (true, dpLeft)
  of leRight: (true, dpRight)
  of leBottom: (true, dpBottom)
  of leTop: (false, dpCenter)

# ---------------------------------------------------------------------------
# The emitter
# ---------------------------------------------------------------------------

func leafName(n: LayoutNode): string =
  if n.isContributed: n.contributedPane else: $n.pane

func leafPanelState(n: LayoutNode): JsonNode =
  ## A pane, as gpui-kit spells a leaf: `panel_name`, no children, and an
  ## `info.panel` payload that is the panel's own data.
  var info = newJObject()
  if n.isContributed:
    info[ContributedPaneInfoKey] = %n.contributedPane
  else:
    info[PaneInfoKey] = %($n.pane)
  if n.title.len > 0:
    info["title"] = %n.title
  result = newJObject()
  result["panel_name"] = %leafName(n)
  result["children"] = newJArray()
  result["info"] = %*{"panel": info}

func tabPanelAround(children: openArray[JsonNode]; activeIndex: int): JsonNode =
  ## `TabPanel` with `PanelInfo::Tabs`. Every pane this projection emits is
  ## inside one of these, including an unstacked pane — gpui-kit has no
  ## bare-leaf container in a split, and its own `bare_tab_panel_root.json`
  ## fixture is a `TabPanel` wrapping a single leaf.
  var arr = newJArray()
  for c in children:
    arr.add c
  result = newJObject()
  result["panel_name"] = %"TabPanel"
  result["children"] = arr
  result["info"] = %*{"tabs": {"active_index": activeIndex}}

func stackPanelAround(children: openArray[JsonNode]; sizes: openArray[int];
                      axis: int): JsonNode =
  ## `StackPanel` with `PanelInfo::Stack`. `axis` is gpui-kit's own encoding:
  ## `0` horizontal, `1` vertical, as `PanelInfo::stack` writes it and as the
  ## upstream `the_serde_tags_are_frozen` test pins it.
  var arr = newJArray()
  for c in children:
    arr.add c
  var sizeArr = newJArray()
  for s in sizes:
    sizeArr.add %float(s)
  result = newJObject()
  result["panel_name"] = %"StackPanel"
  result["children"] = arr
  result["info"] = %*{"stack": {"sizes": sizeArr, "axis": axis}}

proc panelStateOf(n: LayoutNode; width, height: int;
                  problems: var seq[DockProjectionProblem];
                  path: string): JsonNode =
  ## One node, as a `PanelState`.
  ##
  ## **THE EXHAUSTIVE `case` IS THE FLOATING-PANEL NON-GOAL, STRUCTURALLY.**
  ## `LayoutNodeKind` has four values and this handles all four; a fifth shape
  ## — a canvas, a free-positioned tile, anything with an origin — would not
  ## compile without being added to the model's own enum first, which is where
  ## Layout-ViewModel §3A.2 already refuses it. There is no arm here that can
  ## emit a `panel_name` outside `ProjectedPanelNames`, and none that writes a
  ## coordinate.
  if n.isNil:
    problems.add DockProjectionProblem(kind: dppEmptyLayout, detail: path)
    return newJNull()
  case n.kind
  of lnPane:
    tabPanelAround([leafPanelState(n)], 0)
  of lnStack:
    var kids: seq[JsonNode] = @[]
    for c in n.children:
      # A stack's children are panes by `validate`'s own rule, so each one is a
      # leaf here rather than a nested container.
      kids.add leafPanelState(c)
    var active = n.activeIndex
    if active < 0 or active >= kids.len:
      active = 0
    tabPanelAround(kids, active)
  of lnRow, lnColumn:
    let horizontal = n.kind == lnRow
    let axis = if horizontal: 0 else: 1
    let total = if horizontal: width else: height
    var shares: seq[float] = @[]
    for c in n.children:
      shares.add effectiveWeight(c)
    let sizes = distributeExtent(total, shares)
    if sizes.len != n.children.len:
      problems.add DockProjectionProblem(
        kind: dppViewportTooSmall,
        detail: path & ": " & $total & " px for " & $n.children.len &
                " children")
      return newJNull()
    var kids: seq[JsonNode] = @[]
    for i, c in n.children:
      let childWidth = if horizontal: sizes[i] else: width
      let childHeight = if horizontal: height else: sizes[i]
      kids.add panelStateOf(c, childWidth, childHeight, problems,
                            path & "/" & $i)
    stackPanelAround(kids, sizes, axis)

func dockGroupsOf(layout: Layout; edge: LayoutEdge): seq[DockedPane] =
  ## The docked panes at one edge, in `order`. `dockedAt` already sorts.
  layout.dockedAt(edge)

proc dockStateFor(layout: Layout; edge: LayoutEdge; extent: int;
                  problems: var seq[DockProjectionProblem]): JsonNode =
  ## One `DockState`, or `nil` when the edge holds nothing.
  ##
  ## `open` IS ALWAYS `false`, and that is a statement about what a `Layout`
  ## is rather than a default. A docked pane is auto-hidden — that is what
  ## docking means (Layout-ViewModel §3.1) — and whether a strip is currently
  ## revealed is `DockedPane.revealed`, which §3.2 keeps out of the persisted
  ## document precisely so a restore cannot reopen four overlays. A projection
  ## of the COMMITTED layout therefore has nothing that could make this `true`,
  ## and inventing one would be the restore bug §3.2 forbids, arriving through
  ## a different door.
  let docked = dockGroupsOf(layout, edge)
  if docked.len == 0:
    return nil
  let (ok, placement) = placementFor(edge)
  if not ok:
    for d in docked:
      problems.add DockProjectionProblem(
        kind: dppNoPlacementForEdge,
        detail: $d.pane & " is docked to '" & $edge &
                "' and gpui-kit's DockPlacement has no 'top'")
    return nil
  var leaves: seq[JsonNode] = @[]
  for d in docked:
    var info = newJObject()
    info[PaneInfoKey] = %($d.pane)
    if d.title.len > 0:
      info["title"] = %d.title
    var leaf = newJObject()
    leaf["panel_name"] = %($d.pane)
    leaf["children"] = newJArray()
    leaf["info"] = %*{"panel": info}
    leaves.add leaf
  result = newJObject()
  result["panel"] = tabPanelAround(leaves, 0)
  result["placement"] = %($placement)
  result["size"] = %float(extent)
  result["open"] = %false

proc projectDock*(layout: Layout; viewport: DockViewport): DockProjection =
  ## `Layout` -> a gpui-kit `DockAreaState` document.
  ##
  ## Refuses rather than degrades. `projectLayout` has a `ppDegrade` policy
  ## because a terminal must paint SOMETHING; a dock projection has no such
  ## obligation — the host has not drawn yet — so an invalid layout comes back
  ## as `dpsRefused` with the model's own problems named, and there is no path
  ## through this routine that returns a document for a tree `validate`
  ## rejected.
  var problems: seq[DockProjectionProblem] = @[]
  if layout.tree.isNil:
    return DockProjection(status: dpsRefused,
      problems: @[DockProjectionProblem(kind: dppEmptyLayout,
                                        detail: "the layout has no tree")])
  if layout.tree.paneCount == 0 and layout.docked.len == 0:
    return DockProjection(status: dpsRefused,
      problems: @[DockProjectionProblem(kind: dppEmptyLayout,
                                        detail: "no pane is placed or docked")])
  # `{}`: a projection is not told which panes the shell owns, and says so
  # (`validate`'s `owned` has no default).
  let modelProblems = layout.validate({})
  if modelProblems.len > 0:
    var ps: seq[DockProjectionProblem] = @[]
    for p in modelProblems:
      ps.add DockProjectionProblem(kind: dppInvalidLayout,
                                   detail: $p.kind & " at '" & p.path & "'")
    return DockProjection(status: dpsRefused, problems: ps)

  var left = dockStateFor(layout, leLeft, viewport.dockExtent, problems)
  var right = dockStateFor(layout, leRight, viewport.dockExtent, problems)
  var bottom = dockStateFor(layout, leBottom, viewport.dockExtent, problems)
  # `leTop` has no placement; `dockStateFor` records one problem per pane.
  discard dockStateFor(layout, leTop, viewport.dockExtent, problems)

  var centreWidth = viewport.width
  var centreHeight = viewport.height
  if not left.isNil: centreWidth -= viewport.dockExtent
  if not right.isNil: centreWidth -= viewport.dockExtent
  if not bottom.isNil: centreHeight -= viewport.dockExtent

  let centre = panelStateOf(layout.tree, centreWidth, centreHeight, problems,
                            "")
  if problems.len > 0:
    return DockProjection(status: dpsRefused, problems: problems)

  var doc = newJObject()
  doc["version"] = %DockSchemaVersion
  # gpui-kit's `DockAreaState.center` is a `PanelState` and its own comment
  # requires it to be a `StackPanel` even when empty (`RootKind::Split`). A
  # single-pane root projects to a `TabPanel`, so it is wrapped rather than
  # emitted bare — which is also what `nested_splits.json` shows at every
  # level.
  if centre["panel_name"].getStr == "TabPanel":
    doc["center"] = stackPanelAround([centre], [centreWidth], 0)
  else:
    doc["center"] = centre
  if not left.isNil: doc["left_dock"] = left
  if not right.isNil: doc["right_dock"] = right
  if not bottom.isNil: doc["bottom_dock"] = bottom
  DockProjection(status: dpsProjected, state: doc)

proc projectWindowSet*(ws: WindowSet; viewport: DockViewport):
    seq[DockProjection] =
  ## One document per window, in the set's own order.
  ##
  ## A `WindowSet` of size one is NOT a degraded case (Layout-ViewModel §3A.1)
  ## and this returns a one-element seq for it, which is the whole of the
  ## special-casing.
  result = @[]
  for slot in ws.windows:
    result.add projectDock(slot.layout, viewport)

# ---------------------------------------------------------------------------
# The reader — FOR COMPARING TWO PROJECTIONS, AND FOR NOTHING ELSE
# ---------------------------------------------------------------------------

proc collectSlots(node: JsonNode; region: DockPlacement; path: seq[int];
                  into: var seq[DockPaneSlot]) =
  if node.isNil or node.kind != JObject or not node.hasKey("panel_name"):
    return
  let name = node["panel_name"].getStr
  let children = if node.hasKey("children"): node["children"] else: newJArray()
  if name == "StackPanel":
    var i = 0
    for c in children:
      var childPath = path
      childPath.add i
      collectSlots(c, region, childPath, into)
      inc i
    return
  if name == "TabPanel":
    let info = node{"info", "tabs", "active_index"}
    let active = if info.isNil: 0 else: info.getInt
    var i = -1
    for c in children:
      inc i
      if c.kind != JObject: continue
      let panel = c{"info", "panel"}
      var paneId = ""
      var contributed = false
      if not panel.isNil and panel.kind == JObject:
        if panel.hasKey(ContributedPaneInfoKey):
          paneId = panel[ContributedPaneInfoKey].getStr
          contributed = true
        elif panel.hasKey(PaneInfoKey):
          paneId = panel[PaneInfoKey].getStr
      if paneId.len == 0:
        # Not one of ours. A document gpui-kit's own examples produced reaches
        # this branch, and reporting nothing for it is the honest answer:
        # `panel_name` is a registered TYPE name upstream and guessing a pane
        # id out of it would be Verification-Harness-Traps §4d — matching
        # vocabulary rather than syntax.
        continue
      into.add DockPaneSlot(
        pane: paneId, contributed: contributed, region: region, path: path,
        tabIndex: i, tabCount: children.len, activeIndex: active)
    return

proc readDockArrangement*(state: JsonNode): DockArrangement =
  ## Read a projected document back into placement + stack membership.
  ##
  ## **THIS IS NOT A ROUTE INTO THE MODEL, AND THERE IS NO OTHER ONE.** It
  ## returns a `DockArrangement`, which is a comparison vocabulary: no
  ## `LayoutNode`, no `Layout`, no `WindowSet`, and nothing that can be handed
  ## to `HeadlessApp`. It exists because PLAT-20's cross-front-end test has to
  ## read what the projection actually SAID rather than re-derive it from the
  ## model the projection came from — which would compare the model with
  ## itself (Verification-Harness-Traps §4a).
  ##
  ## Its second use is the conformance case: pointed at gpui-kit's own
  ## committed fixtures it reports **no slots**, because those documents carry
  ## no `info.panel.pane`. That is the positive statement that the reader is
  ## reading OUR key rather than pattern-matching a shape.
  result = DockArrangement(slots: @[])
  if state.isNil or state.kind != JObject:
    return
  if state.hasKey("center"):
    collectSlots(state["center"], dpCenter, @[], result.slots)
  const dockKeys = [("left_dock", dpLeft), ("right_dock", dpRight),
                    ("bottom_dock", dpBottom)]
  for entry in dockKeys:
    let (key, placement) = entry
    if state.hasKey(key) and state[key].kind == JObject and
       state[key].hasKey("panel"):
      collectSlots(state[key]["panel"], placement, @[], result.slots)

proc slotFor*(a: DockArrangement; pane: string): (bool, DockPaneSlot) =
  for s in a.slots:
    if s.pane == pane:
      return (true, s)
  (false, DockPaneSlot())

proc panelNamesIn*(state: JsonNode): seq[string] =
  ## Every `panel_name` in a document, in document order. The floating-panel
  ## assertion reads this and checks each one against `isContainerName` or the
  ## model's own pane vocabulary; nothing else may appear.
  var names: seq[string] = @[]
  if state.isNil:
    return names
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.isNil: return
    case n.kind
    of JObject:
      if n.hasKey("panel_name"):
        acc.add n["panel_name"].getStr
      for _, v in n:
        walk(v, acc)
    of JArray:
      for v in n:
        walk(v, acc)
    else: discard
  walk(state, names)
  names

proc positionalKeysIn*(state: JsonNode): seq[string] =
  ## Every key anywhere in the document whose name is one a FREE-POSITIONING
  ## container would need. The list is `tiles_state.rs`'s own vocabulary —
  ## `TilePanel { panel, bounds, z_index }` and `TileMeta { bounds, z_index }`
  ## as PLAT-4 read them — plus the four coordinate names Layout-ViewModel's
  ## own field walk looks for.
  ##
  ## A projection that grew a floating panel would have to write one of these,
  ## and `sizes` is deliberately NOT among them: a stack's extents along its
  ## own axis are what a tiled split IS, and confusing the two would make this
  ## scan refuse the correct document.
  const positional = ["bounds", "z_index", "zIndex", "origin", "x", "y",
                      "left", "top", "position"]
  var found: seq[string] = @[]
  if state.isNil:
    return found
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.isNil: return
    case n.kind
    of JObject:
      for k, v in n:
        for p in positional:
          if k == p:
            acc.add k
        walk(v, acc)
    of JArray:
      for v in n:
        walk(v, acc)
    else: discard
  walk(state, found)
  found

func problemsOf*(p: DockProjection): seq[DockProjectionProblem] =
  ## The problems a projection carries, or `@[]` when it carried none.
  ##
  ## A NIL-SAFE ACCESSOR, and it exists for exactly the reason
  ## Verification-Harness-Traps §1a gives: reading `p.problems` on a
  ## `dpsProjected` value raises `FieldDefect`, so a case that asserts
  ## `status == dpsRefused` and then inspects the problems TAKES THE PROCESS
  ## DOWN under any mutation that makes the projection succeed. `unittest`
  ## catches the exception and prints `[FAILED]`, so the case is not lost —
  ## but the assertions after it never run, and the failure text becomes an
  ## `Unhandled exception` line rather than the comparison the arm is
  ## attributed to. §1a's own remedy is a nil-safe accessor rather than an
  ## `if`, because an `if` changes the assertion COUNT and §4c's counter then
  ## reports a second failure nobody asked about.
  ##
  ## Found by running arm G1, not by reading the suite.
  if p.status == dpsRefused: p.problems else: @[]

proc describe*(p: DockProjectionProblem): string =
  $p.kind & ": " & p.detail

proc describe*(ps: seq[DockProjectionProblem]): string =
  var parts: seq[string] = @[]
  for p in ps:
    parts.add describe(p)
  parts.join("; ")
