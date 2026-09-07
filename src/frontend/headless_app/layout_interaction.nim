## headless_app/layout_interaction.nim — Layout-ViewModel §4, the TRANSIENT
## interaction machine (PLAT-5).
##
## ## What this module is, in one sentence
##
## A drag in progress is not a layout; it is a gesture that MAY produce a
## `LayoutCommand`, and this module is the value that describes such a gesture
## while it is still in the air.
##
## ## The design constraint, and how it is enforced rather than promised
##
## §4.1: "It is a separate machine and never touches the committed layout."
## Three mechanisms hold that up, and none of them is a convention a later
## edit could quietly break:
##
##   1. **`Interaction` lives HERE, and `Layout` lives in `layout_model`.**
##      This module imports that one; the reverse import would be a cycle Nim
##      rejects outright. So a `Layout` field of type `Interaction`,
##      `DropTarget` or `LayoutPointer` is not something a reviewer has to
##      catch — it does not compile. `test_layout_interaction.nim` also walks
##      the persisted types' field NAMES, which catches the weaker leak (a
##      `hover: string`) that would compile.
##   2. **Every routine here takes the layout by value and returns a value.**
##      Nothing takes `var Layout`. `cancel` takes no layout at all, which is
##      the strongest form of "a cancelled gesture cannot have changed the
##      layout": there is no layout in scope to change.
##   3. **`commit` yields an `Option[LayoutCommand]`, never a `Layout`.**
##      §4.3: "Neither can produce an invalid tree, because both route through
##      `apply`." The transient layer produces a COMMAND; `layout_model.apply`
##      remains the only thing in the system that turns one layout into
##      another.
##
## ## `commit`'s `none` and `apply`'s `loNoOp` agree BY CONSTRUCTION
##
## `commit` does not decide what "nothing happened" means. It builds the
## command the hovered target names, hands it to `apply`, and yields `some`
## only on `loApplied`. So the set of gestures that commit `none` is exactly
## the set of commands `apply` answers `loNoOp` or `loRefused` for — there is
## no second opinion to drift. That is why `lcSplit`'s move arm gained its own
## `loNoOp` in `layout_model` rather than a shape comparison here: the
## authority on "already in that state" is `apply`, and this module asks it.
##
## ## Why `dropTargetsFor` is pure, and what purity buys
##
## §4.2: it is "a pure function of the committed layout and a pointer
## position". The pointer this module accepts is a `LayoutPointer` — a node
## PATH and a symbolic ZONE, with no numeric field of any kind. A front-end's
## hit-test is what turns its own medium into one (a pixel rectangle test, or
## a cell-grid one); from here down there is no medium left to disagree about,
## so one implementation serves both and the terminal can be tested without a
## pointing device. `DropRegion` is the same idea in the other direction: a
## path and a side, which each renderer resolves into its own rectangle.

import std/[options, strutils]

import ./layout_model

type
  InteractionKind* = enum
    ## Layout-ViewModel §4.1.
    ikNone = "none"
    ikDraggingTab = "draggingTab"
    ikResizingSplit = "resizingSplit"
    ikRevealingDock = "revealingDock"

  DropTargetKind* = enum
    ## §4.2. "Everything a user perceives about drag-and-drop is which drop
    ## target is highlighted."
    dtIntoStack = "intoStack"
      ## Become a tab of this stack, at `index`.
    dtSplitBefore = "splitBefore"
      ## Split the target; the dragged pane lands before it on the axis.
    dtSplitAfter = "splitAfter"
    dtDockEdge = "dockEdge"
      ## Become an auto-hidden pane on this edge of the whole layout.

  DropZone* = enum
    ## Which part of a node's region — or of the window's border — a pointer
    ## is over. **Symbolic, and that is the point**: a front-end's hit-test
    ## answers in these terms, and everything below this line is medium-free.
    dzTabStrip = "tabStrip"
      ## Over the tab strip of the stack the pointer's node belongs to.
    dzCentre = "centre"
      ## Over the body of the node.
    dzLeftEdge = "leftEdge"
    dzRightEdge = "rightEdge"
    dzTopEdge = "topEdge"
    dzBottomEdge = "bottomEdge"
    dzOutsideLeft = "outsideLeft"
      ## Past the left border of the whole layout — the dock strip. The four
      ## `dzOutside*` values are the only ones that do not name a node.
    dzOutsideRight = "outsideRight"
    dzOutsideTop = "outsideTop"
    dzOutsideBottom = "outsideBottom"

  LayoutPointer* = object
    ## Where a gesture currently is, in the LAYOUT's own vocabulary.
    ##
    ## **It has no numeric field, deliberately.** A pixel pointer and a cell
    ## cursor are different measurements of the same thing, and a type that
    ## could hold either would have to pick one to be wrong about. The
    ## conversion is the front-end's hit-test (§5's second obligation), and it
    ## happens above this module — which is what lets `dropTargetsFor` be
    ## tested with no pointing device at all.
    path*: string
      ## The node the hit-test resolved to, spelled the way
      ## `LayoutProblem.path` spells one: slash-separated child indices from
      ## the root, `""` for the root itself. Ignored — and conventionally
      ## empty — for the four `dzOutside*` zones, which are not over a node.
    zone*: DropZone

  DropRegionKind* = enum
    ## What shape of region a drop target occupies. Resolved by a renderer
    ## against its own geometry; nothing here is measured.
    drWholeNode = "wholeNode"
    drNodeStrip = "nodeStrip"
      ## A strip along one side of the node's region.
    drTabSlot = "tabSlot"
      ## One insertion slot of a stack's tab strip.
    drLayoutStrip = "layoutStrip"
      ## A strip along one edge of the whole layout.

  DropRegion* = object
    ## §4.2's "the region each occupies", in the only terms this module has:
    ## a node path plus which part of it. **No extent, no coordinate** — a
    ## front-end already knows where the node at `path` is, because it drew
    ## it.
    path*: string
    case kind*: DropRegionKind
    of drNodeStrip, drLayoutStrip:
      side*: LayoutEdge
    of drTabSlot:
      slot*: int
        ## An INDEX INTO THE MODEL, not a measurement: which insertion point
        ## of the tab strip, counted the way `stack.children` is.
    of drWholeNode:
      discard

  DropTarget* = object
    ## A candidate landing place, and the region a renderer highlights for it.
    region*: DropRegion
    case kind*: DropTargetKind
    of dtIntoStack:
      stackAnchor*: PaneKind
        ## A pane in the destination stack. Named by pane rather than by path
        ## for `lcMoveTab`'s reason: a path is a renderer's way of pointing.
      index*: int
        ## Which slot of the tab strip. Meaningful when the anchor is already
        ## in a stack; when it is a BARE pane the drop turns it into a two-tab
        ## stack and the newcomer is always the second tab, so the index is
        ## `1` and `lcMergeIntoStack` — which has no index — is what commits.
    of dtSplitBefore, dtSplitAfter:
      splitTarget*: PaneKind
      axis*: SplitAxis
    of dtDockEdge:
      edge*: LayoutEdge

  DragOriginKind* = enum
    ## Where a dragged pane came from. §4.1 names the stack case ("which stack
    ## and index it left"); the other two are the same question answered for
    ## the shapes a pane can also be dragged out of.
    doStack = "stack"
    doRegion = "region"
      ## A pane that owns a region on its own, not a tab of anything.
    doDock = "dock"
      ## An auto-hidden pane, dragged out of its strip.

  DragOrigin* = object
    case kind*: DragOriginKind
    of doStack:
      stackPath*: string
      index*: int
    of doRegion:
      regionPath*: string
    of doDock:
      dockEdge*: LayoutEdge
      dockOrder*: int

  Interaction* = object
    ## Layout-ViewModel §4.1, verbatim in its field set.
    case kind*: InteractionKind
    of ikDraggingTab:
      source*: PaneKind
      origin*: DragOrigin
      hover*: Option[DropTarget]
        ## Where it would land right now. `none` while the pointer is over
        ## nothing droppable, which is also how a drag released there commits
        ## nothing.
    of ikResizingSplit:
      node*: string
        ## Path, as `LayoutProblem.path` spells it.
      proposed*: seq[float]
        ## Candidate weights for the affected siblings — the whole child list
        ## of the resized node's parent, in its own order, so index `i` here
        ## is child `i` there.
    of ikRevealingDock:
      edge*: LayoutEdge
      pane*: PaneKind
    of ikNone:
      discard

const
  MinResizeShare = 0.02
    ## A resize proposal is clamped into `(MinResizeShare, 1 - MinResizeShare)`
    ## so a divider dragged to the border cannot ask for a zero or an infinite
    ## weight. It is a share of the parent, so it is unitless, and it is here
    ## rather than in a front-end because a second front-end would otherwise
    ## pick a different floor.

# ---------------------------------------------------------------------------
# Paths. §5's second obligation ("hit-test — turn a pointer into a node path")
# needs both directions, and both are pure walks over the tree.
# ---------------------------------------------------------------------------

proc childPath(prefix: string; index: int): string =
  if prefix.len == 0: $index else: prefix & "/" & $index

proc parentIndex*(node: LayoutNode; parent: LayoutNode): int =
  ## Where `node` sits in `parent.children`, or -1. `layout_model` has the
  ## same walk privately; it is repeated rather than exported because this
  ## module needs it for a DIFFERENT purpose — spelling a path and a tab slot,
  ## neither of which is a layout operation.
  if parent.isNil or node.isNil:
    return -1
  for i, c in parent.children:
    if c == node:
      return i
  -1

proc nodePathAux(node, target: LayoutNode; prefix: string;
                 found: var string; ok: var bool) =
  if node.isNil or ok:
    return
  if node == target:
    found = prefix
    ok = true
    return
  for i, c in node.children:
    nodePathAux(c, target, childPath(prefix, i), found, ok)

proc nodePath*(root, target: LayoutNode): Option[string] =
  ## The path of `target` within `root`, or `none` when it is not in the tree.
  ## The root's own path is `""`, which is the same spelling
  ## `LayoutProblem.path` uses for it.
  var found = ""
  var ok = false
  nodePathAux(root, target, "", found, ok)
  if ok: some(found) else: none(string)

proc nodeAtPath*(root: LayoutNode; path: string): LayoutNode =
  ## The node a path names, or nil. The inverse of `nodePath`, and the routine
  ## a front-end's hit-test result is resolved through.
  if root.isNil:
    return nil
  if path.len == 0:
    return root
  var current = root
  for part in path.split('/'):
    if current.isNil or current.kind == lnPane:
      return nil
    var index = -1
    try:
      index = parseInt(part)
    except ValueError:
      return nil
    if index < 0 or index >= current.children.len:
      return nil
    current = current.children[index]
  current

type
  NodeInfo* = object
    ## What a node at a path IS, as a **value**, with no way back to the tree.
    ##
    ## ## Why this exists, and what it closes
    ##
    ## `nodeAtPath` hands out a live `ref` into the committed tree, so a caller
    ## holding one can write through it — `node.weight = 3.0` mutates the very
    ## layout every routine in this module promises not to touch. That is the
    ## same exposure `layout_model.find` has, and it was recorded rather than
    ## closed in PLAT-4/PLAT-5 because until PLAT-6 nothing outside the model's
    ## own suites called either.
    ##
    ## PLAT-6 is the first real caller, and it takes this door instead. Every
    ## field below is a copy of a scalar: there is no `LayoutNode`, no `ref`,
    ## and no `seq` of children, so `not compiles(info.node)` and a front-end
    ## PHYSICALLY CANNOT reach the tree through what it was handed. The
    ## structure of the type is the guarantee, rather than a rule a reviewer
    ## has to enforce; `app/tests/test_layout_binding.nim` walks the fields and
    ## asserts none of them is a reference, with a counted control so a walk
    ## that found nothing cannot pass.
    ##
    ## **What this does NOT close, stated rather than implied.** `Layout.tree`
    ## is itself a public `ref` field, so anybody holding a `Layout` can still
    ## write `layout.tree.children[0].weight = 3.0` without calling anything
    ## here. Making `nodeAtPath` private would move that exposure, not remove
    ## it. Removing it needs `Layout` to stop publishing a mutable tree — a
    ## change to the persisted model's representation, which is PLAT-4's
    ## decision and not a binding's to take. What IS true, and is what this
    ## type buys, is that the terminal binding never holds a node reference at
    ## all: it resolves paths to `NodeInfo` and panes to `PaneKind`, and its
    ## whole public surface is free of `LayoutNode`.
    path*: string
      ## The path this describes, echoed back so a caller that resolved a
      ## pointer keeps the two together.
    kind*: LayoutNodeKind
    pane*: PaneKind
      ## Meaningful only when `kind == lnPane`; `PaneKind.low` otherwise, and a
      ## caller must branch on `kind` first. Not an `Option` because the branch
      ## is already mandatory for every other field here.
    title*: string
    weight*: float
    childCount*: int
    activeIndex*: int
      ## The stack's active child, or -1 for every other kind.

proc nodeInfoAtPath*(root: LayoutNode; path: string): Option[NodeInfo] =
  ## The node a path names, **copied out**. `none` when the path names
  ## nothing.
  ##
  ## The routine a front-end's hit-test result should be resolved through —
  ## see `NodeInfo`'s own documentation for why, and for the one exposure this
  ## does not close.
  let node = nodeAtPath(root, path)
  if node.isNil:
    return none(NodeInfo)
  some(NodeInfo(
    path: path, kind: node.kind,
    pane: (if node.kind == lnPane: node.pane else: PaneKind.low),
    title: node.title, weight: node.weight, childCount: node.children.len,
    activeIndex: (if node.kind == lnStack: node.activeIndex else: -1)))

proc parentPath*(path: string): Option[string] =
  ## The path of the node one level up, or `none` for the root — which has no
  ## parent and whose path is `""`.
  ##
  ## A pure string operation, deliberately: a caller that has a path and wants
  ## its container should not have to walk the tree (and therefore hold a
  ## reference) to get one.
  if path.len == 0:
    return none(string)
  let at = path.rfind('/')
  if at < 0: some("") else: some(path[0 ..< at])

proc childPathOf*(path: string; index: int): string =
  ## The path of child `index` of the node at `path`. The inverse of
  ## `parentPath`, and what lets a binding name a stack's HIDDEN tabs — which
  ## have paths but no projected region, so nothing on screen can point at
  ## them.
  childPath(path, index)

proc panePath*(layout: Layout; kind: PaneKind): Option[string] =
  ## The path of the leaf holding `kind`, or `none` when it is not placed.
  let leaf = layout.tree.find(kind)
  if leaf.isNil: none(string) else: nodePath(layout.tree, leaf)

# ---------------------------------------------------------------------------
# Equality and rendering. Written out rather than relied upon, because these
# are variant objects and a test compares whole candidate lists.
# ---------------------------------------------------------------------------

proc `==`*(a, b: DropRegion): bool =
  if a.kind != b.kind or a.path != b.path:
    return false
  case a.kind
  of drNodeStrip, drLayoutStrip: a.side == b.side
  of drTabSlot: a.slot == b.slot
  of drWholeNode: true

proc `==`*(a, b: DropTarget): bool =
  if a.kind != b.kind or not (a.region == b.region):
    return false
  case a.kind
  of dtIntoStack: a.stackAnchor == b.stackAnchor and a.index == b.index
  of dtSplitBefore, dtSplitAfter:
    a.splitTarget == b.splitTarget and a.axis == b.axis
  of dtDockEdge: a.edge == b.edge

proc `$`*(r: DropRegion): string =
  case r.kind
  of drWholeNode: "whole('" & r.path & "')"
  of drNodeStrip: "strip('" & r.path & "', " & $r.side & ")"
  of drTabSlot: "tabSlot('" & r.path & "', " & $r.slot & ")"
  of drLayoutStrip: "layoutStrip(" & $r.side & ")"

proc `$`*(t: DropTarget): string =
  case t.kind
  of dtIntoStack:
    "intoStack(" & $t.stackAnchor & ", " & $t.index & ") @" & $t.region
  of dtSplitBefore, dtSplitAfter:
    $t.kind & "(" & $t.splitTarget & ", " & $t.axis & ") @" & $t.region
  of dtDockEdge:
    "dockEdge(" & $t.edge & ") @" & $t.region

proc `$`*(o: DragOrigin): string =
  case o.kind
  of doStack: "stack('" & o.stackPath & "'@" & $o.index & ")"
  of doRegion: "region('" & o.regionPath & "')"
  of doDock: "dock(" & $o.dockEdge & "#" & $o.dockOrder & ")"

proc `$`*(i: Interaction): string =
  case i.kind
  of ikNone: "none"
  of ikDraggingTab:
    "draggingTab(" & $i.source & " from " & $i.origin & ", hover=" &
      (if i.hover.isSome: $i.hover.get else: "-") & ")"
  of ikResizingSplit:
    var parts: seq[string] = @[]
    for w in i.proposed:
      parts.add($w)
    "resizingSplit('" & i.node & "', [" & parts.join(", ") & "])"
  of ikRevealingDock:
    "revealingDock(" & $i.pane & "@" & $i.edge & ")"

# ---------------------------------------------------------------------------
# §4.2 — the drop-target model
# ---------------------------------------------------------------------------

proc edgeOfZone(zone: DropZone): Option[LayoutEdge] =
  case zone
  of dzOutsideLeft: some(leLeft)
  of dzOutsideRight: some(leRight)
  of dzOutsideTop: some(leTop)
  of dzOutsideBottom: some(leBottom)
  else: none(LayoutEdge)

proc commandFor*(layout: Layout; source: PaneKind;
                 target: DropTarget): Option[LayoutCommand] =
  ## The command a drop on `target` would issue. **Pure, and the only place
  ## the target vocabulary meets the command vocabulary** — `commit` is this
  ## plus one call to `apply`.
  ##
  ## `none` means the target is not EXPRESSIBLE for this source, which is a
  ## different statement from "the command would be refused". The refusals
  ## belong to `apply` and are asked for separately, so that a target which is
  ## merely illegal right now still has a command to be refused by kind.
  let placed = layout.tree.contains(source)
  let docked = layout.dockedIndex(source) >= 0
  if not placed and not docked:
    return none(LayoutCommand)
  case target.kind
  of dtIntoStack:
    if placed:
      # The anchor's parent decides which command says "become a tab here":
      # a stack takes `lcMoveTab` at an index, a bare pane has to BECOME a
      # stack first and that is `lcMergeIntoStack`.
      let anchorLeaf = layout.tree.find(target.stackAnchor)
      if anchorLeaf.isNil:
        return none(LayoutCommand)
      let parent = parentOf(layout.tree, anchorLeaf)
      if not parent.isNil and parent.kind == lnStack:
        return some(cmdMoveTab(source, target.stackAnchor, target.index))
      return some(cmdMergeIntoStack(source, target.stackAnchor))
    # A DOCKED source rejoins the tree through `ahRestore`, which places it
    # with `lcAddPane`'s semantics — beside the anchor, inside the anchor's
    # own container. `dropTargetsFor` only offers this when that container is
    # a stack, so "beside" and "a tab of" are the same placement.
    some(cmdRestoreDocked(source, some(target.stackAnchor)))
  of dtSplitBefore, dtSplitAfter:
    let side = if target.kind == dtSplitBefore: ssBefore else: ssAfter
    if placed:
      return some(cmdSplitMove(target.splitTarget, source, target.axis, side))
    # A docked pane cannot be split into the tree in one command: `lcSplit`
    # refuses a pane that is in `docked` (`lpPaneBothPlacedAndDocked`), and
    # restoring it first would make this layer sequence two commands — which
    # §4.3 does not allow. Restore it, then drag it.
    none(LayoutCommand)
  of dtDockEdge:
    some(cmdDock(source, target.edge))

proc intoStackCandidates(layout: Layout; source: PaneKind; leaf: LayoutNode;
                         leafPath: string): seq[DropTarget] =
  ## Every "become a tab here" target the node under the pointer offers.
  result = @[]
  let parent = parentOf(layout.tree, leaf)
  let placed = layout.tree.contains(source)
  if not parent.isNil and parent.kind == lnStack:
    let anchor = parent.children[0].pane
    let stackPath = nodePath(layout.tree, parent)
    if stackPath.isNone:
      return
    if placed:
      # One slot per insertion point. `apply` decides which of them are legal
      # — dragging within the source's own stack has one fewer.
      for slot in 0 .. parent.children.len:
        result.add(DropTarget(
          kind: dtIntoStack, stackAnchor: anchor, index: slot,
          region: DropRegion(kind: drTabSlot, path: stackPath.get,
                             slot: slot)))
    else:
      # `ahRestore` inserts AFTER its anchor, so a docked pane can name every
      # slot EXCEPT THE VERY FIRST: slot `i` is "after tab `i - 1`". Slot 0
      # is not offered rather than offered and refused, because there is no
      # command that reaches it — advertising it would be a highlighted drop
      # zone that does nothing.
      for slot in 1 .. parent.children.len:
        result.add(DropTarget(
          kind: dtIntoStack, stackAnchor: parent.children[slot - 1].pane,
          index: slot,
          region: DropRegion(kind: drTabSlot, path: stackPath.get,
                             slot: slot)))
    return
  if placed:
    # A bare pane: dropping onto its body turns it into a two-tab stack.
    result.add(DropTarget(
      kind: dtIntoStack, stackAnchor: leaf.pane, index: 1,
      region: DropRegion(kind: drWholeNode, path: leafPath)))

proc splitCandidates(leaf: LayoutNode; leafPath: string): seq[DropTarget] =
  ## The four edge strips of a node's region, as split targets. The mapping
  ## from a side to an (axis, side) pair is stated once, here, because two
  ## front-ends disagreeing about which way "left" splits is precisely the
  ## "a binding never decides layout semantics" failure §5 names.
  @[DropTarget(kind: dtSplitBefore, splitTarget: leaf.pane, axis: saRow,
               region: DropRegion(kind: drNodeStrip, path: leafPath,
                                  side: leLeft)),
    DropTarget(kind: dtSplitAfter, splitTarget: leaf.pane, axis: saRow,
               region: DropRegion(kind: drNodeStrip, path: leafPath,
                                  side: leRight)),
    DropTarget(kind: dtSplitBefore, splitTarget: leaf.pane, axis: saColumn,
               region: DropRegion(kind: drNodeStrip, path: leafPath,
                                  side: leTop)),
    DropTarget(kind: dtSplitAfter, splitTarget: leaf.pane, axis: saColumn,
               region: DropRegion(kind: drNodeStrip, path: leafPath,
                                  side: leBottom))]

proc isLegal(layout: Layout; source: PaneKind; target: DropTarget): bool =
  ## Whether a drop here would be accepted. **Answered by `apply`, never by a
  ## rule restated here**: a candidate list built from its own idea of what is
  ## legal would drift from the algebra the moment either changed.
  let cmd = commandFor(layout, source, target)
  if cmd.isNone:
    return false
  apply(layout, cmd.get).kind != loRefused

proc dropTargetsFor*(layout: Layout; source: PaneKind;
                     pointer: LayoutPointer): seq[DropTarget] =
  ## Layout-ViewModel §4.2. **A pure function of the committed layout, the
  ## pane being dragged, and a pointer** — returning the candidate targets
  ## with the region each occupies.
  ##
  ## Illegal candidates are dropped, and `isLegal` is what drops them, so the
  ## list is exactly "the places this drag can land". A caller may therefore
  ## highlight everything it gets back without re-checking anything.
  result = @[]
  if layout.tree.isNil:
    return
  if layout.placement(source) == plAbsent:
    return
  let outside = edgeOfZone(pointer.zone)
  if outside.isSome:
    let candidate = DropTarget(
      kind: dtDockEdge, edge: outside.get,
      region: DropRegion(kind: drLayoutStrip, path: "", side: outside.get))
    if isLegal(layout, source, candidate):
      result.add(candidate)
    return
  let node = nodeAtPath(layout.tree, pointer.path)
  # A hit-test resolves to the pane whose region the pointer is in. A path
  # naming a container is not a drop location: containers have no region of
  # their own that is not some pane's.
  if node.isNil or node.kind != lnPane:
    return
  for candidate in intoStackCandidates(layout, source, node, pointer.path):
    if isLegal(layout, source, candidate):
      result.add(candidate)
  for candidate in splitCandidates(node, pointer.path):
    if isLegal(layout, source, candidate):
      result.add(candidate)

proc regionForZone(layout: Layout; pointer: LayoutPointer): Option[DropRegion] =
  ## Which region of the pointer's node the pointer's zone selects. The
  ## inverse of the region each candidate carries, and the reason
  ## `hoveredTarget` is a SELECTION from `dropTargetsFor` rather than a second
  ## computation of it.
  let outside = edgeOfZone(pointer.zone)
  if outside.isSome:
    return some(DropRegion(kind: drLayoutStrip, path: "", side: outside.get))
  let node = nodeAtPath(layout.tree, pointer.path)
  if node.isNil or node.kind != lnPane:
    return none(DropRegion)
  let parent = parentOf(layout.tree, node)
  let inStack = not parent.isNil and parent.kind == lnStack
  case pointer.zone
  of dzTabStrip:
    if not inStack:
      return none(DropRegion)
    let stackPath = nodePath(layout.tree, parent)
    if stackPath.isNone:
      return none(DropRegion)
    some(DropRegion(kind: drTabSlot, path: stackPath.get,
                    slot: node.parentIndex(parent)))
  of dzCentre:
    if inStack:
      let stackPath = nodePath(layout.tree, parent)
      if stackPath.isNone:
        return none(DropRegion)
      # The body of a tabbed region means "append a tab", which is the slot
      # past the last one.
      return some(DropRegion(kind: drTabSlot, path: stackPath.get,
                             slot: parent.children.len))
    some(DropRegion(kind: drWholeNode, path: pointer.path))
  of dzLeftEdge:
    some(DropRegion(kind: drNodeStrip, path: pointer.path, side: leLeft))
  of dzRightEdge:
    some(DropRegion(kind: drNodeStrip, path: pointer.path, side: leRight))
  of dzTopEdge:
    some(DropRegion(kind: drNodeStrip, path: pointer.path, side: leTop))
  of dzBottomEdge:
    some(DropRegion(kind: drNodeStrip, path: pointer.path, side: leBottom))
  else:
    none(DropRegion)

proc hoveredTarget*(layout: Layout; source: PaneKind;
                    pointer: LayoutPointer): Option[DropTarget] =
  ## The ONE candidate the pointer is currently on, or `none`. Always a member
  ## of `dropTargetsFor(layout, source, pointer)` — it is selected from that
  ## list, so a target that is highlighted is by construction a target that
  ## can be dropped on.
  let wanted = regionForZone(layout, pointer)
  if wanted.isNone:
    return none(DropTarget)
  for candidate in dropTargetsFor(layout, source, pointer):
    if candidate.region == wanted.get:
      return some(candidate)
  none(DropTarget)

# ---------------------------------------------------------------------------
# §4.1 — the machine
# ---------------------------------------------------------------------------

proc noInteraction*(): Interaction =
  ## The resting state. `ikNone` is a value rather than an `Option[Interaction]`
  ## so that a front-end always has an interaction to read and never has to
  ## branch on "is there one" before branching on "which".
  Interaction(kind: ikNone)

proc originOf(layout: Layout; source: PaneKind): Option[DragOrigin] =
  let at = layout.dockedIndex(source)
  if at >= 0:
    let d = layout.docked[at]
    return some(DragOrigin(kind: doDock, dockEdge: d.edge, dockOrder: d.order))
  let leaf = layout.tree.find(source)
  if leaf.isNil:
    return none(DragOrigin)
  let parent = parentOf(layout.tree, leaf)
  if not parent.isNil and parent.kind == lnStack:
    let stackPath = nodePath(layout.tree, parent)
    if stackPath.isNone:
      return none(DragOrigin)
    return some(DragOrigin(kind: doStack, stackPath: stackPath.get,
                           index: leaf.parentIndex(parent)))
  let leafPath = nodePath(layout.tree, leaf)
  if leafPath.isNone:
    return none(DragOrigin)
  some(DragOrigin(kind: doRegion, regionPath: leafPath.get))

proc beginDragTab*(layout: Layout; source: PaneKind): Option[Interaction] =
  ## Start dragging `source`. `none` when the pane is in neither the tree nor
  ## `docked` — there is nothing to pick up, and saying so here means every
  ## later routine can assume the gesture is well formed.
  let origin = originOf(layout, source)
  if origin.isNone:
    return none(Interaction)
  some(Interaction(kind: ikDraggingTab, source: source, origin: origin.get,
                   hover: none(DropTarget)))

proc hoverAt*(interaction: Interaction; layout: Layout;
              pointer: LayoutPointer): Interaction =
  ## Move the pointer. Returns a NEW interaction; the argument is untouched,
  ## and so is the layout — hovering is the operation most likely to be
  ## written as a mutation, so it is the one most worth having as a value.
  if interaction.kind != ikDraggingTab:
    return interaction
  Interaction(kind: ikDraggingTab, source: interaction.source,
              origin: interaction.origin,
              hover: hoveredTarget(layout, interaction.source, pointer))

proc beginResize*(layout: Layout; pane: PaneKind): Option[Interaction] =
  ## Start resizing the region holding `pane` against its siblings.
  ##
  ## `none` when there is nothing to resize: the pane is not placed, it is the
  ## whole root, or its parent is a STACK — tabs share one region, so there is
  ## no divider between them and no share to move.
  let leaf = layout.tree.find(pane)
  if leaf.isNil:
    return none(Interaction)
  let parent = parentOf(layout.tree, leaf)
  if parent.isNil or parent.kind == lnStack or parent.children.len < 2:
    return none(Interaction)
  let path = nodePath(layout.tree, leaf)
  if path.isNone:
    return none(Interaction)
  var weights: seq[float] = @[]
  for c in parent.children:
    weights.add(effectiveWeight(c))
  some(Interaction(kind: ikResizingSplit, node: path.get, proposed: weights))

proc proposeShare*(interaction: Interaction; layout: Layout;
                   share: float): Interaction =
  ## Propose that the resized node take `share` of its parent's axis, as a
  ## fraction. Returns a new interaction whose `proposed` differs from the
  ## committed weights in EXACTLY ONE entry.
  ##
  ## One entry and not two, because `lcSetWeight` changes one node's share and
  ## `commit` yields one command. The siblings keep their weights and
  ## therefore their proportions relative to each other, which is what a
  ## divider drag means when there are exactly two of them and is the
  ## documented generalisation when there are more.
  if interaction.kind != ikResizingSplit:
    return interaction
  let leaf = nodeAtPath(layout.tree, interaction.node)
  if leaf.isNil:
    return interaction
  let parent = parentOf(layout.tree, leaf)
  if parent.isNil or parent.children.len < 2:
    return interaction
  var clamped = share
  if clamped < MinResizeShare:
    clamped = MinResizeShare
  if clamped > 1.0 - MinResizeShare:
    clamped = 1.0 - MinResizeShare
  var others = 0.0
  var at = -1
  for i, c in parent.children:
    if c == leaf:
      at = i
    else:
      others += effectiveWeight(c)
  if at < 0 or others <= 0.0:
    return interaction
  var weights: seq[float] = @[]
  for c in parent.children:
    weights.add(effectiveWeight(c))
  weights[at] = clamped / (1.0 - clamped) * others
  Interaction(kind: ikResizingSplit, node: interaction.node, proposed: weights)

proc beginReveal*(layout: Layout; pane: PaneKind): Option[Interaction] =
  ## Reveal a docked pane as an overlay. `none` when the pane is not docked.
  ##
  ## **The reveal lives here and nowhere else.** `DockedPane.revealed` exists
  ## on the committed layout for locality (§3.2) and is not written by this
  ## module: a revealed strip is something the user is looking at right now,
  ## and a `Layout` that recorded it would carry it into a save.
  let at = layout.dockedIndex(pane)
  if at < 0:
    return none(Interaction)
  some(Interaction(kind: ikRevealingDock, edge: layout.docked[at].edge,
                   pane: pane))

proc isRevealed*(interaction: Interaction; pane: PaneKind): bool =
  ## Whether a renderer should be drawing `pane`'s overlay. The query that
  ## replaces reading `DockedPane.revealed`.
  interaction.kind == ikRevealingDock and interaction.pane == pane

# ---------------------------------------------------------------------------
# §4.3 — commit and cancel
# ---------------------------------------------------------------------------

proc pendingCommand*(layout: Layout;
                     interaction: Interaction): Option[LayoutCommand] =
  ## The command this gesture WOULD issue, before asking whether it would do
  ## anything. Split out from `commit` so that the difference between the two
  ## — one call to `apply` — is visible rather than buried.
  case interaction.kind
  of ikNone:
    none(LayoutCommand)
  of ikDraggingTab:
    if interaction.hover.isNone:
      none(LayoutCommand)
    else:
      commandFor(layout, interaction.source, interaction.hover.get)
  of ikResizingSplit:
    let leaf = nodeAtPath(layout.tree, interaction.node)
    if leaf.isNil or leaf.kind != lnPane:
      return none(LayoutCommand)
    let parent = parentOf(layout.tree, leaf)
    if parent.isNil or parent.children.len != interaction.proposed.len:
      return none(LayoutCommand)
    var at = -1
    for i, c in parent.children:
      if c == leaf:
        at = i
    if at < 0:
      return none(LayoutCommand)
    some(cmdSetWeight(leaf.pane, interaction.proposed[at]))
  of ikRevealingDock:
    # A reveal commits nothing. It is an overlay the user looked at; PINNING
    # the pane back into the tree is `cmdRestoreDocked`, an explicit command
    # a front-end issues on its own, not something a hover can decide.
    none(LayoutCommand)

proc commit*(layout: Layout;
             interaction: Interaction): Option[LayoutCommand] =
  ## Layout-ViewModel §4.3. The command this gesture produces, or `none` when
  ## it produces nothing.
  ##
  ## **`none` MEANS `apply` DID NOT SAY `loApplied`, AND NOTHING ELSE.** The
  ## gesture's command is handed to `apply` and the answer is what decides:
  ## `loApplied` yields the command, `loNoOp` and `loRefused` yield `none`. So
  ## a drag that lands a tab back where it started commits `none` for exactly
  ## the reason §2.3 gives for `loNoOp` existing — the two cannot disagree,
  ## because only one of them is deciding.
  let cmd = pendingCommand(layout, interaction)
  if cmd.isNone:
    return none(LayoutCommand)
  if apply(layout, cmd.get).kind != loApplied:
    return none(LayoutCommand)
  cmd

proc cancel*(interaction: Interaction): Interaction =
  ## Discard the gesture. **It takes no layout**, which is the whole
  ## statement: a cancelled drag cannot have changed the committed layout
  ## because this routine has no layout to change.
  Interaction(kind: ikNone)
