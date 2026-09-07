## headless_app/layout_model.nim — the session/layout model that is not
## GoldenLayout-typed.
##
## ## Why this module exists
##
## `ReplaySession.savedLayoutConfig` is a `GoldenLayoutResolvedConfig`
## (`src/frontend/types.nim`), and tab switching runs through
## `src/frontend/ui/session_switch.nim`, which casts to and from that type and
## calls `callInitLayoutSafe`. That is the one place where a *session* — a
## concept the replay core owns — is spelled in terms of a *renderer*, and it
## is why BlockTracer.milestones.org M2a says "the shell is the part that is
## still renderer-bound, not the ViewModels".
##
## This module is the replacement shape: a description of what a replay
## session shows, carrying no renderer, no measurement and no engine.
##
## ## What it deliberately is NOT
##
## It is **not a layout engine**, and the distinction is the reason it can
## exist at all. CodeTracer-Embed-SDK.md §3.2 excludes "Monaco, GoldenLayout,
## the desktop layout engine" and "any rendering, any CSS, any component".
## Nothing here computes a pixel, a size in any unit, a class name or a style
## string. `weight` is a unitless relative share that a renderer divides its
## own axis by; this module never learns what that axis is measured in.
##
## For the same reason the model lives on the **consumer** side of the SDK
## boundary rather than inside `src/frontend/viewmodel/`: arranging panes is
## the embedder's job (§3.2 row 1), and `ci/test/sdk-facade-boundary.sh` names
## "a headless app entrypoint" as the example of a consumer tree. Keeping it
## out of the facade is the conservative reading of §3.2 and costs nothing —
## `headless_app.nim` composes the two.
##
## ## Why the node is not a variant object
##
## A `case kind` object would be the idiomatic tree, and it is wrong here for
## one concrete reason: restoring a saved layout has to *mutate* a node's kind
## when a stack collapses to a single pane, and Nim forbids assigning a new
## discriminator to an existing object. The cost of a flat record is that
## `pane` is meaningless on a container and `children` is meaningless on a
## pane; `validate` is what makes that cost visible rather than silent — a
## container with a `pane` set, or a pane with children, is a reported
## structural error, not something a reader has to remember.

import std/[json, options, strutils, tables]

type
  PaneKind* = enum
    ## Every pane the headless shell can place.
    ##
    ## An enum rather than an open string id, deliberately. A saved layout
    ## that names an unknown pane must be a *decodable, reportable* condition
    ## (`lpUnknownPane` below) rather than a silently empty slot — which is
    ## exactly the failure mode the GoldenLayout config has today, where an
    ## unrecognised `componentName` produces a blank tab.
    ##
    ## The set is the panes `SessionViewModel` actually owns, not a wish list:
    ## the eleven mounted by `viewmodel/app/isonim_app.nim` plus the editor
    ## and the debug controls, which that module mounts elsewhere. The five
    ## that make a replay navigable are the first five values, and
    ## `ReplayCorePanes` below names them.
    paneEditor = "editor"
    paneCalltrace = "calltrace"
    paneState = "state"
    paneEventLog = "eventLog"
    paneDebugControls = "debugControls"
    paneFlow = "flow"
    paneTimeline = "timeline"
    paneSearch = "search"
    panePointList = "pointList"
    paneScratchpad = "scratchpad"
    paneShell = "shell"

  LayoutNodeKind* = enum
    ## The four shapes a layout node can take.
    ##
    ## `lnStack` is the tabbed container: several panes occupy the same
    ## region and exactly one of them is active. It is the whole reason
    ## `visiblePanes` differs from `allPanes`, and the reason a shell can
    ## avoid loading data for a pane nobody can see.
    lnRow = "row"
    lnColumn = "column"
    lnStack = "stack"
    lnPane = "pane"

  LayoutNode* = ref object
    ## One node of a layout tree. See the module note for why this is a flat
    ## record rather than a variant object.
    kind*: LayoutNodeKind
    pane*: PaneKind
      ## Meaningful only when `kind == lnPane`.
    title*: string
      ## What a renderer would put on the tab. Free text; empty means "use
      ## the pane's own default", which this module does not decide either.
    weight*: float
      ## Relative share of the parent container's axis. Unitless: a renderer
      ## divides its own extent in these proportions. `0` means "equal share
      ## with the other zero-weighted siblings".
    activeIndex*: int
      ## Meaningful only when `kind == lnStack`: which child is the visible
      ## tab.
    children*: seq[LayoutNode]
      ## Meaningful only when `kind != lnPane`.

  LayoutProblemKind* = enum
    ## Every way a layout tree can be structurally wrong.
    ##
    ## Enumerated rather than reported as message strings for the same reason
    ## `DebuggerSessionErrorKind` is: a caller branches on the kind, and a
    ## test asserts on it, without matching on prose.
    lpEmptyContainer = "EmptyContainer"
      ## A row, column or stack with no children. A renderer would draw a
      ## hole; nothing can ever appear in it.
    lpPaneWithChildren = "PaneWithChildren"
      ## A leaf carrying children — the flat-record hazard, made visible.
    lpContainerWithPaneField = "ContainerWithPaneField"
      ## A container whose `pane` field was set. Harmless to a renderer and
      ## a reliable sign the tree was built by mistake, so it is reported
      ## rather than tolerated.
    lpStackChildNotPane = "StackChildNotPane"
      ## A stack holding a container. Tabs hold panes; nesting a row inside a
      ## tab is the GoldenLayout generality this model does not have.
    lpActiveIndexOutOfRange = "ActiveIndexOutOfRange"
      ## A stack whose active tab does not exist.
    lpDuplicatePane = "DuplicatePane"
      ## The same pane placed twice. Two views over one ViewModel is not a
      ## thing this shell supports, and a duplicate is far more often a
      ## restore bug than an intention.
    lpNegativeWeight = "NegativeWeight"
      ## A share smaller than nothing.

    # -- PLAT-4 / Layout-ViewModel §7. Everything above this line is about a
    # bare `LayoutNode` and is reported by `validate(LayoutNode)`. Everything
    # below needs the whole `Layout` — the tree AND its `docked` sibling list —
    # and is reported only by `validate(Layout)`. Keeping them in ONE enum is
    # Layout-ViewModel §2.3's instruction ("refusals reuse `LayoutProblemKind`
    # where the reason is structural and extend it where the reason is an
    # operation"), and it is what lets a caller branch on one kind rather than
    # on two.
    lpPaneBothPlacedAndDocked = "PaneBothPlacedAndDocked"
      ## A pane that is in the tree AND in `docked`. Docking means "not in the
      ## tree", so both at once makes `allPanes` ambiguous — the invariant
      ## §3.3 names.
    lpPaneNeitherPlacedNorDocked = "PaneNeitherPlacedNorDocked"
      ## A pane the shell says it owns that appears nowhere. Reported only
      ## when the caller passes the owned set to `validate`, because nothing
      ## in this module can know it otherwise — see that overload's note.
    lpSingleChildContainer = "SingleChildContainer"
      ## A row or column with exactly one child (§2.4 rule 1 not applied). A
      ## row holding a single column is a hole in the tree, not a layout.
      ##
      ## Stacks are deliberately exempt: a stack with one tab is an ordinary
      ## arrangement, and collapsing it would delete the tab strip a user is
      ## about to drop a second tab onto.
    lpDockOrderCollision = "DockOrderCollision"
      ## Two docked panes claiming the same `(edge, order)`. A strip whose
      ## order is ambiguous renders differently on two builds.
    lpEmptyRoot = "EmptyRoot"
      ## A layout with no panes at all. §2.4 rule 3: there is no valid layout
      ## with no panes, and a shell that reaches one has no way back through
      ## the UI.

    # -- Refusal-only kinds. `validate` never produces these; they exist so
    # that `apply` can say *why* it refused with the same vocabulary a
    # structural defect is reported in. `LayoutProblemSources` below records
    # which side of the line each kind falls on, and the model's own suite
    # asserts that partition rather than trusting this comment.
    lpPaneNotPlaced = "PaneNotPlaced"
      ## A command named a pane that is not in the tree.
    lpPaneNotDocked = "PaneNotDocked"
      ## `ahRestore` named a pane that is not in `docked`.
    lpTargetNotAStack = "TargetNotAStack"
      ## `lcMoveTab` named a destination whose enclosing node is not a stack.
    lpIndexOutOfRange = "IndexOutOfRange"
      ## `lcMoveTab` named an insertion index outside `0 .. len`.

  LayoutProblemSource* = enum
    ## Where a `LayoutProblemKind` can come from. A kind may have both
    ## sources — `lpDuplicatePane` is a defect when a saved tree contains one
    ## and a refusal when a command would create one — so this is used as a
    ## SET per kind (`problemSources`), never as a single answer.
    lpsStructural
      ## `validate` can report it about a tree or a layout that exists.
    lpsRefusal
      ## `apply` can produce it, about a command it declined to perform.

  LayoutProblem* = object
    ## One structural defect, with enough context to find it.
    kind*: LayoutProblemKind
    path*: string
      ## Slash-separated child indices from the root, e.g. `"0/2"`. The root
      ## itself is `""`.
    pane*: Option[PaneKind]
      ## Set when the problem is about a specific pane.

  LayoutEdge* = enum
    ## The four strips a pane can be auto-hidden to.
    leLeft = "left"
    leRight = "right"
    leTop = "top"
    leBottom = "bottom"

  DockedPane* = object
    ## An auto-hidden pane: one that is NOT in the tree, because that is what
    ## docking means (Layout-ViewModel §3.1).
    ##
    ## A SIBLING LIST RATHER THAN A FIFTH `LayoutNodeKind`, and the reason is
    ## the Yoga projection: `tui/app/layout/project.nim` asserts that the
    ## regions it produces are total and pairwise disjoint over the cell grid.
    ## A node that occupies no region would have to be special-cased in
    ## `visiblePanes`, `allPanes`, the projection and the partition check — four
    ## places, each of which is a chance to get it wrong. Keeping docked panes
    ## out of `LayoutNode` means the tree still describes PRECISELY the
    ## region-occupying panes and that projection is untouched by this
    ## milestone.
    pane*: PaneKind
    title*: string
    edge*: LayoutEdge
    order*: int
      ## Position within the strip. Unique per edge — `lpDockOrderCollision`.
    revealed*: bool
      ## Transiently shown as an overlay. **NOT PERSISTED** (§3.2): a restore
      ## that reopened four overlays would be a bug, and `toJson` omitting
      ## this field is what prevents it. It lives here for locality; it
      ## belongs to PLAT-5's transient state.

  Layout* = object
    ## The persisted unit: a tree, the panes docked beside it, and a version.
    ##
    ## `LayoutNode` stays exactly as it was, which is the point — see
    ## `DockedPane`.
    tree*: LayoutNode
    docked*: seq[DockedPane]
    version*: int

  PanePlacement* = enum
    ## Where a pane is, and the enumeration IS Layout-ViewModel §3A.2's
    ## floating-panel non-goal made structural.
    ##
    ## There are exactly three answers, and none of them is a coordinate. A
    ## floating panel would need a fourth — "somewhere, at (x, y), over the
    ## top" — and adding one is a visible change to an exhaustive `case` in
    ## every consumer rather than a field nobody notices. A placed pane owns a
    ## region of the split tree, and the projection's total-and-disjoint
    ## invariant is what makes that region real.
    plAbsent
    plPlaced
      ## In the tree. It has a path, and therefore a region.
    plDocked
      ## In `docked`. It has an edge and an order, and no region until it is
      ## revealed — at which point PLAT-5's transient state owns the overlay.

  LayoutCommandKind* = enum
    ## Layout-ViewModel §2.2. Every operation a front-end can perform on a
    ## layout, as a value that can be described, refused, logged and replayed
    ## without being performed.
    lcActivateTab = "activateTab"
    lcSetWeight = "setWeight"
    lcAddPane = "addPane"
    lcRemovePane = "removePane"
    lcMoveTab = "moveTab"
    lcSplit = "split"
    lcMergeIntoStack = "mergeIntoStack"
    lcSetAutoHide = "setAutoHide"
    lcRename = "rename"

  SplitAxis* = enum
    ## Which container a split creates.
    saRow = "row"
    saColumn = "column"

  SplitSide* = enum
    ## Where the new sibling lands relative to the node being split.
    ssBefore = "before"
    ssAfter = "after"

  AutoHideDirection* = enum
    ## `lcSetAutoHide` carries a direction (§3.3).
    ahDock = "dock"
      ## Remove the pane from the tree (applying §2.4) and append a
      ## `DockedPane`.
    ahRestore = "restore"
      ## Remove it from `docked` and place it back with `lcAddPane`'s
      ## semantics.

  LayoutCommand* = object
    ## A variant object, unlike `LayoutNode`, and for the reason the module
    ## header gives: the thing that forced `LayoutNode` flat is that a
    ## collapsing stack must change its own discriminator in place. A command
    ## is constructed once and never mutated, so nothing here has to.
    case kind*: LayoutCommandKind
    of lcActivateTab:
      activateTarget*: PaneKind
    of lcSetWeight:
      weightTarget*: PaneKind
      weightValue*: float
    of lcAddPane:
      addedPane*: PaneKind
      addedTitle*: string
      addedWeight*: float
      addAfter*: Option[PaneKind]
        ## The pane whose parent container receives the new leaf, appended
        ## after it. `none` means "the root container". When the receiving
        ## container is a stack the new tab is selected, which is what
        ## today's `addPane` does.
    of lcRemovePane:
      removedPane*: PaneKind
    of lcMoveTab:
      movedPane*: PaneKind
      moveBeside*: PaneKind
        ## A pane in the DESTINATION stack. Named by pane rather than by path
        ## because a path is a renderer's way of pointing and this module has
        ## no renderer.
      moveIndex*: int
    of lcSplit:
      splitTarget*: PaneKind
      splitNewPane*: PaneKind
      splitNewTitle*: string
      splitAxis*: SplitAxis
      splitSide*: SplitSide
      splitMovesPane*: bool
        ## PLAT-5. When false — every PLAT-4 caller — `splitNewPane` must NOT
        ## be in the tree and a duplicate is `lpDuplicatePane`. When true it
        ## must ALREADY be, and the split MOVES it: detach (§2.4's collapse
        ## rules), then split the target with the pane that came out.
        ##
        ## THE FLAG EXISTS BECAUSE `commit` YIELDS ONE COMMAND. Dragging a tab
        ## onto the edge of another pane is the headline drop gesture, and
        ## expressing it as remove-then-add would make the transient layer a
        ## second place that sequences layout changes — exactly what
        ## Layout-ViewModel §4.3 forbids by saying commit produces a
        ## `LayoutCommand` and `apply` remains the only thing that changes a
        ## layout. The same shape as `mergeWholeRegion`: a flag on the command
        ## rather than a tenth command kind, because it is the same operation
        ## with a different source of the pane.
    of lcMergeIntoStack:
      mergedPane*: PaneKind
      mergeBeside*: PaneKind
      mergeWholeRegion*: bool
        ## The §8-decision-1 gesture: drag a whole SPLIT into a tab, rather
        ## than one pane. Kept expressible so it can be REFUSED by kind
        ## (`lpStackChildNotPane`) instead of silently doing something else —
        ## "keep the restriction, and refuse that gesture with a typed
        ## outcome, until a user asks".
    of lcSetAutoHide:
      autoHideDirection*: AutoHideDirection
      autoHidePane*: PaneKind
      autoHideEdge*: LayoutEdge
      autoHideOrder*: int
        ## Negative means "append to the end of that edge's strip". An
        ## explicit index already taken is `lpDockOrderCollision`.
      autoHideTitle*: string
      autoHideRestoreBeside*: Option[PaneKind]
    of lcRename:
      renameTarget*: PaneKind
      renameTitle*: string

  LayoutOutcomeKind* = enum
    ## Layout-ViewModel §2.3.
    loApplied = "applied"
      ## The command produced a new layout.
    loNoOp = "noOp"
      ## Legal, but the layout is already in that state.
      ##
      ## DISTINCT FROM `loApplied` ON PURPOSE: a drag that lands a tab back
      ## where it started must not push an undo entry, and a caller that
      ## cannot tell the difference will push one. That is also why the new
      ## layout is reachable ONLY from the `loApplied` branch — a caller
      ## cannot read it without having branched.
    loRefused = "refused"
      ## Illegal; the layout is unchanged and `problem` says why.

  LayoutOutcome* = object
    case kind*: LayoutOutcomeKind
    of loApplied:
      layout*: Layout
    of loNoOp:
      discard
    of loRefused:
      problem*: LayoutProblem

  LayoutHistory* = object
    ## Undo/redo as a command log (§2.5): the layout the session started from,
    ## the commands applied to it, and how many of them are currently in
    ## effect.
    ##
    ## A replay of the prefix rather than a set of inverse commands, because
    ## an inverse-command scheme is a second thing to keep correct and this is
    ## not a performance-sensitive path — layouts are small and a user issues
    ## a handful of layout commands a minute.
    initial*: Layout
    log*: seq[LayoutCommand]
    cursor*: int
      ## How many entries of `log` are applied. `log.len` means "fully
      ## redone"; `0` means "back at `initial`".
    value*: Layout
      ## The layout at `cursor`. Cached so that reading it is not a replay;
      ## every mutation of `cursor` recomputes it from `initial`, so it can
      ## never disagree with the log.

  LayoutDecodeErrorKind* = enum
    ## Why a serialised layout could not be read back.
    ldeNotAnObject = "NotAnObject"
    ldeUnknownVersion = "UnknownVersion"
    ldeUnknownPane = "UnknownPane"
    ldeUnknownNodeKind = "UnknownNodeKind"
    ldeMissingField = "MissingField"
    ldeWrongFieldType = "WrongFieldType"
    ldeUnknownEdge = "UnknownEdge"
      ## A `docked` entry naming an edge this build does not have. The same
      ## rule `ldeUnknownPane` embodies, applied to the second persisted
      ## vocabulary: a decodable, reportable condition, never a silently
      ## dropped strip.
    ldeDockedPanesUnsupported = "DockedPanesUnsupported"
      ## A caller asked for the TREE of a document that carries docked panes.
      ## A bare `LayoutNode` cannot represent them, so handing one back would
      ## silently drop the panes — the blank-slot failure §1.3 exists to
      ## prevent, one level up. `restoreLayoutDocument` returns the whole
      ## `Layout` and has no such problem.

  LayoutDecodeError* = object of CatchableError
    ## A typed decode failure. Restoring a layout saved by a different build
    ## is a normal event, not a crash, and the kind is what lets a shell fall
    ## back to `defaultReplayLayout()` for the right reason.
    kind*: LayoutDecodeErrorKind
    detail*: string

const
  LayoutSchemaVersion* = 2
    ## Bumped when the serialised shape changes incompatibly. A decoder that
    ## meets a version it does not know raises `ldeUnknownVersion` rather than
    ## guessing — the failure mode `savedLayoutConfig` has no way to express,
    ## because a `GoldenLayoutResolvedConfig` is whatever GoldenLayout last
    ## wrote.
    ##
    ## ## The rule this constant now carries (Layout-ViewModel §6)
    ##
    ##   * **A version bump requires a migration from the immediately
    ##     preceding version.** `restoreLayoutDocument` migrates FORWARD
    ##     through the chain, one step at a time. There is no backward
    ##     migration: an older build refusing a newer layout is correct, and
    ##     must stay loud.
    ##   * **`PaneKind` is a persisted vocabulary.** Adding a value is a
    ##     version bump. Removing one requires a migration that decides what
    ##     happens to a saved layout mentioning it — `ldeUnknownPane` is the
    ##     floor, not the answer.
    ##   * **`docked` is part of the format from version 2 onwards even while
    ##     empty**, so a front-end gaining auto-hide later is not itself a
    ##     bump.
    ##
    ## ## Why the desktop is what makes this strict
    ##
    ## CTUI-3's review found the sharp edge: `PaneKind` is this module's and
    ## is persisted as JSON by the desktop, so widening it for an unrelated
    ## purpose changes a saved-layout format for a front-end that is not
    ## looking. Any change to that enum is a format change. The projection's
    ## `cpUncovered` sentinel in `tui/app/layout/project.nim` is the concrete
    ## case where that rule was applied and a sentinel member refused.
    ##
    ## ### Version history
    ##
    ## | Version | Change |
    ## |---|---|
    ## | 1 | `{version, layout}` — the bare tree. |
    ## | 2 | adds `docked: []` (PLAT-4). The tree encoding is unchanged, so
    ##       the v1→v2 migration only supplies the missing array. |

  FirstLayoutSchemaVersion* = 1
    ## The oldest document this build can still read. A document below it is
    ## `ldeUnknownVersion`, exactly as one above `LayoutSchemaVersion` is:
    ## "too old to migrate" and "too new to understand" are both "this build
    ## cannot read it", and a shell answers both by falling back.

  ReplayCorePanes* = {
    paneEditor, paneCalltrace, paneState, paneEventLog, paneDebugControls}
    ## The minimum set that makes a replay session navigable: source, the call
    ## structure, variable state, the event stream, and the controls that move
    ## through time. Named here so `defaultReplayLayout` and a consumer's own
    ## assertion read the same set rather than two hand-kept copies.
    ##
    ## Defined by what a replay needs, deliberately not by who consumes it.
    ## An earlier name tied this constant to one embedder; an exported symbol
    ## in this package naming a specific consumer is the boundary eroding from
    ## the inside, which no import lint would catch. See `.sdk-consumer`.

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc pane*(kind: PaneKind; title: string = ""; weight: float = 0.0):
    LayoutNode =
  ## A leaf.
  LayoutNode(kind: lnPane, pane: kind, title: title, weight: weight)

proc row*(children: openArray[LayoutNode]; weight: float = 0.0): LayoutNode =
  ## A left-to-right container.
  ##
  ## `openArray` rather than `varargs`, so the children are always written as
  ## a bracketed list. With `varargs` a trailing `weight = 2.0` is ambiguous
  ## against the variadic list and Nim rejects the call — the same reason
  ## `stack` takes one.
  LayoutNode(kind: lnRow, weight: weight, children: @children)

proc column*(children: openArray[LayoutNode]; weight: float = 0.0): LayoutNode =
  ## A top-to-bottom container.
  LayoutNode(kind: lnColumn, weight: weight, children: @children)

proc stack*(children: openArray[LayoutNode]; activeIndex: int = 0;
            weight: float = 0.0): LayoutNode =
  ## A tabbed container. `activeIndex` is which tab is visible.
  LayoutNode(kind: lnStack, activeIndex: activeIndex, weight: weight,
             children: @children)

proc defaultReplayLayout*(): LayoutNode =
  ## The arrangement a replay session opens with: the five panes of
  ## `ReplayCorePanes`, with State and Event Log sharing a tabbed region so
  ## that `visiblePanes` is smaller than `allPanes` in the default case too.
  ##
  ## A default that made every pane visible would let `visiblePanes` be wrong
  ## in the same direction everywhere and still look right in every test, so
  ## the default carries a stack on purpose.
  column([
    pane(paneDebugControls, "Debug Controls", weight = 1.0),
    row([
      pane(paneEditor, "Editor", weight = 3.0),
      column([
        pane(paneCalltrace, "Call Trace", weight = 1.0),
        stack([pane(paneState, "State"), pane(paneEventLog, "Event Log")],
              activeIndex = 0, weight = 1.0)],
        weight = 2.0)],
      weight = 9.0)])

proc clone*(node: LayoutNode): LayoutNode =
  ## A deep copy. Two sessions must never share a node: activating a tab in
  ## one would move it in the other, which is precisely the bug
  ## `savedLayoutConfig` exists to avoid and achieves only because
  ## GoldenLayout hands back a fresh config each time.
  if node.isNil:
    return nil
  result = LayoutNode(
    kind: node.kind, pane: node.pane, title: node.title, weight: node.weight,
    activeIndex: node.activeIndex, children: @[])
  for c in node.children:
    result.children.add(clone(c))

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

proc allPanes*(node: LayoutNode): seq[PaneKind] =
  ## Every pane in the tree, depth-first, whether or not it is visible.
  result = @[]
  if node.isNil:
    return
  if node.kind == lnPane:
    result.add(node.pane)
    return
  for c in node.children:
    result.add(allPanes(c))

proc visiblePanes*(node: LayoutNode): seq[PaneKind] =
  ## Every pane a user can currently see: the whole tree, minus the
  ## non-active members of every stack.
  ##
  ## This is the derivation a shell needs and `GoldenLayoutResolvedConfig`
  ## can only answer by asking the live layout object — which is to say, only
  ## when a renderer exists.
  result = @[]
  if node.isNil:
    return
  case node.kind
  of lnPane:
    result.add(node.pane)
  of lnStack:
    if node.activeIndex >= 0 and node.activeIndex < node.children.len:
      result.add(visiblePanes(node.children[node.activeIndex]))
  of lnRow, lnColumn:
    for c in node.children:
      result.add(visiblePanes(c))

proc contains*(node: LayoutNode; kind: PaneKind): bool =
  ## Whether `kind` is placed anywhere in the tree.
  for p in allPanes(node):
    if p == kind:
      return true
  false

proc isVisible*(node: LayoutNode; kind: PaneKind): bool =
  ## Whether `kind` is placed AND on the active side of every stack above it.
  for p in visiblePanes(node):
    if p == kind:
      return true
  false

proc find*(node: LayoutNode; kind: PaneKind): LayoutNode =
  ## The leaf holding `kind`, or nil.
  if node.isNil:
    return nil
  if node.kind == lnPane:
    return if node.pane == kind: node else: nil
  for c in node.children:
    let hit = find(c, kind)
    if not hit.isNil:
      return hit
  nil

proc equalTrees*(a, b: LayoutNode): bool =
  ## Structural equality over exactly the fields `toJson` writes.
  ##
  ## It exists so that "the command produced the layout it was already in" is
  ## answerable for the commands whose no-op case is not a single field
  ## comparison — `lcSplit` with `splitMovesPane`, where the pane is detached
  ## and re-attached and only the resulting SHAPE says whether anything moved.
  ## `apply` is the only caller, which is what keeps `loNoOp` a single
  ## authority rather than something a transient layer decides for itself.
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind or a.title != b.title or a.weight != b.weight:
    return false
  if a.kind == lnPane:
    return a.pane == b.pane
  if a.kind == lnStack and a.activeIndex != b.activeIndex:
    return false
  if a.children.len != b.children.len:
    return false
  for i in 0 ..< a.children.len:
    if not equalTrees(a.children[i], b.children[i]):
      return false
  true

# ---------------------------------------------------------------------------
# §2.4 — the collapse rules, stated once
#
# GoldenLayout's behaviour here is implicit and its edge cases are where its
# bugs live. These four rules are the model's answer, and there is exactly one
# implementation of them: `normaliseInPlace` below. Both front doors reach it —
# `apply` (on a copy, so it can refuse) and the legacy mutators (on the
# caller's own tree, so node identity survives for a caller holding a
# reference into it).
# ---------------------------------------------------------------------------

proc activate*(node: LayoutNode; kind: PaneKind): bool
  ## Forward-declared: `apply` selects a tab through the SAME routine
  ## `session_switch.nim` calls, rather than through a private copy of the
  ## index assignment. Two implementations of "make this tab visible" is one
  ## more than the number of behaviours the desktop and the terminal are
  ## allowed to have.

proc effectiveWeight*(n: LayoutNode): float =
  ## What a renderer would actually divide by. `layout_model` documents `0` as
  ## "equal share with the other zero-weighted siblings" and one is the
  ## neutral share, so that is what a zero means here — the same rule
  ## `tui/app/layout/project.nim`'s `weightShare` applies.
  if n.isNil or n.weight <= 0.0: 1.0 else: n.weight

proc renormalise(children: var seq[LayoutNode]; targetSum: float) =
  ## §2.4 rule 4: the surviving siblings' weights are rescaled so they still
  ## sum to what the whole child list summed to before the change.
  ##
  ## This is the rule most likely to be argued with, so what it does and does
  ## not promise is worth being exact about. It does NOT stop a survivor's
  ## share of ITS OWN container from growing — the space a removed neighbour
  ## held has to go somewhere, and the remaining siblings are where. What it
  ## keeps is the container's TOTAL, so that a weight read out of a saved
  ## layout still means the same fraction after an edit as before it, and so
  ## that a subsequent §2.4-rule-1 collapse hands the parent a node whose
  ## weight is still denominated in the parent's units.
  ##
  ## A container whose children are ALL implicit (every weight `0`) is left
  ## alone: `0` is a symbolic value, scaling it would materialise an
  ## arbitrary number into a persisted document, and equal shares of a
  ## smaller list are still equal shares.
  var allImplicit = true
  var have = 0.0
  for c in children:
    if c.weight > 0.0:
      allImplicit = false
    have += effectiveWeight(c)
  if allImplicit or have <= 0.0 or targetSum <= 0.0:
    return
  let factor = targetSum / have
  if abs(factor - 1.0) < 1e-12:
    return
  for c in children:
    c.weight = effectiveWeight(c) * factor

proc becomes(node: LayoutNode; other: LayoutNode) =
  ## Rewrite `node` IN PLACE so that it is structurally `other`.
  ##
  ## This is the operation the module header says forced `LayoutNode` to be a
  ## flat record rather than a variant object: a row that collapses to its
  ## only child has to change its own `kind`, and Nim forbids assigning a new
  ## discriminator. Every field is read into a local first, because `other` is
  ## routinely one of `node`'s own children and the assignment order would
  ## otherwise matter.
  let
    k = other.kind
    p = other.pane
    t = other.title
    w = other.weight
    a = other.activeIndex
    c = other.children
  node.kind = k
  node.pane = p
  node.title = t
  node.weight = w
  node.activeIndex = a
  node.children = c

proc normaliseInPlace*(node: LayoutNode): bool =
  ## Apply §2.4 rules 1, 2 and 4 bottom-up, in place. Returns `false` when the
  ## subtree has no panes left at all and the caller must drop it.
  ##
  ## Rule 3 — "a root that would become empty is refused, not emptied" — is
  ## deliberately NOT here: refusing needs a channel to refuse on, and only
  ## `apply` has one. This returns the fact and lets the caller decide.
  if node.isNil:
    return false
  if node.kind == lnPane:
    return true
  var kept: seq[LayoutNode] = @[]
  var totalBefore = 0.0
  for c in node.children:
    totalBefore += effectiveWeight(c)
    if normaliseInPlace(c):
      kept.add(c)
  if kept.len == 0:
    return false                                  # rule 2: emptied, drop me
  if kept.len != node.children.len and node.kind != lnStack:
    # Rule 4, on the same terms as `detachPane`'s: a stack is exempt because
    # its children are tabs sharing one region, so their weights divide
    # nothing. (Reachable only for a tree that already fails `validate` with
    # `lpStackChildNotPane` — a stack holding an emptied container — but the
    # two sites must agree or the rule depends on which door was used.)
    renormalise(kept, totalBefore)                # rule 4
  node.children = kept
  if node.kind == lnStack:
    # A stack with one tab is an ordinary arrangement, not a hole: rule 1 does
    # not apply to it. Collapsing it would delete the tab strip the user is
    # about to drop a second tab onto.
    if node.activeIndex < 0:
      node.activeIndex = 0
    if node.activeIndex >= kept.len:
      node.activeIndex = kept.len - 1
    return true
  if kept.len == 1:
    # Rule 1. The survivor takes the collapsed container's share, because that
    # share is what the PARENT knew about and the parent is not being changed.
    let inherited = node.weight
    node.becomes(kept[0])
    node.weight = inherited
  true

# ---------------------------------------------------------------------------
# Tree primitives the algebra is built out of
# ---------------------------------------------------------------------------

proc detachPane(node: LayoutNode; kind: PaneKind): bool =
  ## Remove the leaf holding `kind`, WITHOUT collapsing anything. Separated
  ## from the collapse so that a command which removes and re-inserts in one
  ## step does not collapse a container it is about to refill.
  ##
  ## §2.4 RULE 4 IS APPLIED HERE rather than in `normaliseInPlace`, and it has
  ## to be: by the time the collapse runs, the child is already gone and the
  ## total it contributed is unrecoverable. This is the only point in the pass
  ## that can see both sides of the removal.
  ##
  ## A STACK IS EXEMPT. Its children are tabs sharing one region, so their
  ## weights divide nothing; rescaling them would materialise arbitrary
  ## numbers into a persisted document for no visible change.
  if node.isNil or node.kind == lnPane:
    return false
  var kept: seq[LayoutNode] = @[]
  var removed = false
  var totalBefore = 0.0
  for c in node.children:
    totalBefore += effectiveWeight(c)
    if c.kind == lnPane and c.pane == kind:
      removed = true
      continue
    if detachPane(c, kind):
      removed = true
    kept.add(c)
  if removed:
    if kept.len != node.children.len and node.kind != lnStack:
      renormalise(kept, totalBefore)
    node.children = kept
  removed

proc parentOf*(root: LayoutNode; target: LayoutNode): LayoutNode =
  ## The node whose `children` contains `target`, or nil when `target` is the
  ## root or is not in the tree.
  if root.isNil or target.isNil or root.kind == lnPane:
    return nil
  for c in root.children:
    if c == target:
      return root
  for c in root.children:
    let hit = parentOf(c, target)
    if not hit.isNil:
      return hit
  nil

proc indexIn(parent: LayoutNode; child: LayoutNode): int =
  if parent.isNil:
    return -1
  for i, c in parent.children:
    if c == child:
      return i
  -1

proc copyOf(n: LayoutNode): LayoutNode =
  ## A shallow structural copy: the same fields, the same child refs. Used
  ## when a node is about to be rewritten by `becomes` but its old contents
  ## have to survive as a child of the replacement.
  LayoutNode(kind: n.kind, pane: n.pane, title: n.title, weight: n.weight,
             activeIndex: n.activeIndex, children: n.children)

proc wrapRootAround(root: LayoutNode; leaf: LayoutNode; leafFirst: bool) =
  ## Turn a root that has nowhere to put a new pane into a row that has. The
  ## root keeps its own weight (it is the whole area's share of nothing) and
  ## both children get equal shares.
  let inner = copyOf(root)
  inner.weight = 0.0
  let kids = if leafFirst: @[leaf, inner] else: @[inner, leaf]
  root.becomes(LayoutNode(kind: lnRow, weight: root.weight, children: kids))

proc insertBeside(root: LayoutNode; anchor: Option[PaneKind];
                  leaf: LayoutNode): bool =
  ## `lcAddPane`'s placement rule, shared by `ahRestore`.
  ##
  ## With an anchor: the new leaf joins the anchor's own container, directly
  ## after it — which is what makes "restore this docked pane next to where it
  ## came from" expressible without a second mechanism. Without one: the root
  ## container, which is today's `addPane`. A bare-pane root is wrapped in a
  ## row rather than refused, because "there is nowhere to put it" is not an
  ## answer a user can act on.
  if root.isNil or leaf.isNil:
    return false
  if anchor.isSome:
    let target = find(root, anchor.get)
    if target.isNil:
      return false
    let parent = parentOf(root, target)
    if parent.isNil:
      wrapRootAround(root, leaf, leafFirst = false)
      return true
    let at = indexIn(parent, target)
    parent.children.insert(leaf, at + 1)
    if parent.kind == lnStack:
      parent.activeIndex = at + 1
    return true
  if root.kind == lnPane:
    wrapRootAround(root, leaf, leafFirst = false)
    return true
  root.children.add(leaf)
  if root.kind == lnStack:
    root.activeIndex = root.children.len - 1
  true

# ---------------------------------------------------------------------------
# `Layout` — the persisted unit, and its queries
# ---------------------------------------------------------------------------

proc initLayout*(tree: LayoutNode; docked: seq[DockedPane] = @[]): Layout =
  ## A layout at THIS build's schema version. The version is never defaulted
  ## to zero by accident: an object initialised field-by-field would carry
  ## `version == 0`, which is not a version this build ever wrote.
  Layout(tree: tree, docked: docked, version: LayoutSchemaVersion)

proc defaultReplayLayoutValue*(): Layout =
  ## `defaultReplayLayout()` as a `Layout`, with no docked panes.
  initLayout(defaultReplayLayout())

proc clone*(layout: Layout): Layout =
  ## A deep copy. `docked` is a `seq` of values so it copies itself; the tree
  ## is a `ref` and does not, which is the whole reason this exists.
  Layout(tree: layout.tree.clone(), docked: layout.docked,
         version: layout.version)

proc dockedIndex*(layout: Layout; kind: PaneKind): int =
  ## Where `kind` sits in `docked`, or -1.
  for i, d in layout.docked:
    if d.pane == kind:
      return i
  -1

proc placement*(layout: Layout; kind: PaneKind): PanePlacement =
  ## Where `kind` is. Total, and three-valued — see `PanePlacement` for why
  ## the absence of a fourth answer is the floating-panel non-goal.
  let inTree = layout.tree.contains(kind)
  let docked = layout.dockedIndex(kind) >= 0
  if inTree and docked:
    # Both at once is `lpPaneBothPlacedAndDocked`, which `validate` reports.
    # This query answers with the placement that OCCUPIES A REGION, because a
    # caller asking "where is this" is usually about to draw it.
    plPlaced
  elif inTree: plPlaced
  elif docked: plDocked
  else: plAbsent

proc allPanes*(layout: Layout): seq[PaneKind] =
  ## Every pane the layout knows about, placed ones first then docked ones.
  result = allPanes(layout.tree)
  for d in layout.docked:
    result.add(d.pane)

proc visiblePanes*(layout: Layout): seq[PaneKind] =
  ## Every pane a user can currently see. A docked pane is not visible even
  ## when `revealed`: an overlay is PLAT-5's transient state, and a query on
  ## the committed layout must not depend on it.
  visiblePanes(layout.tree)

proc dockedAt*(layout: Layout; edge: LayoutEdge): seq[DockedPane] =
  ## The strip on one edge, in `order`.
  result = @[]
  for d in layout.docked:
    if d.edge == edge:
      result.add(d)
  # Insertion sort: strips are at most a handful of entries and this keeps
  # the module free of a comparator import.
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1].order > result[j].order:
      swap(result[j - 1], result[j])
      dec j

# ---------------------------------------------------------------------------
# §2.2 — the commands, as values
# ---------------------------------------------------------------------------

proc cmdActivateTab*(pane: PaneKind): LayoutCommand =
  LayoutCommand(kind: lcActivateTab, activateTarget: pane)

proc cmdSetWeight*(pane: PaneKind; weight: float): LayoutCommand =
  LayoutCommand(kind: lcSetWeight, weightTarget: pane, weightValue: weight)

proc cmdAddPane*(pane: PaneKind; title = ""; weight = 0.0;
                 after: Option[PaneKind] = none(PaneKind)): LayoutCommand =
  LayoutCommand(kind: lcAddPane, addedPane: pane, addedTitle: title,
                addedWeight: weight, addAfter: after)

proc cmdRemovePane*(pane: PaneKind): LayoutCommand =
  LayoutCommand(kind: lcRemovePane, removedPane: pane)

proc cmdMoveTab*(pane: PaneKind; beside: PaneKind; index: int): LayoutCommand =
  LayoutCommand(kind: lcMoveTab, movedPane: pane, moveBeside: beside,
                moveIndex: index)

proc cmdSplit*(target: PaneKind; newPane: PaneKind; axis: SplitAxis;
               side: SplitSide = ssAfter; title = ""): LayoutCommand =
  LayoutCommand(kind: lcSplit, splitTarget: target, splitNewPane: newPane,
                splitNewTitle: title, splitAxis: axis, splitSide: side,
                splitMovesPane: false)

proc cmdSplitMove*(target: PaneKind; movedPane: PaneKind; axis: SplitAxis;
                   side: SplitSide = ssAfter; title = ""): LayoutCommand =
  ## `lcSplit` over a pane that is ALREADY in the tree: the drop gesture
  ## "drag this tab to the right-hand edge of that pane". See
  ## `splitMovesPane`.
  LayoutCommand(kind: lcSplit, splitTarget: target, splitNewPane: movedPane,
                splitNewTitle: title, splitAxis: axis, splitSide: side,
                splitMovesPane: true)

proc cmdMergeIntoStack*(pane: PaneKind; beside: PaneKind;
                        wholeRegion = false): LayoutCommand =
  LayoutCommand(kind: lcMergeIntoStack, mergedPane: pane, mergeBeside: beside,
                mergeWholeRegion: wholeRegion)

proc cmdDock*(pane: PaneKind; edge: LayoutEdge; order = -1;
              title = ""): LayoutCommand =
  ## `ahDock` (§3.3). A negative `order` appends to the end of that edge's
  ## strip; an explicit one that is already taken is `lpDockOrderCollision`.
  LayoutCommand(kind: lcSetAutoHide, autoHideDirection: ahDock,
                autoHidePane: pane, autoHideEdge: edge, autoHideOrder: order,
                autoHideTitle: title,
                autoHideRestoreBeside: none(PaneKind))

proc cmdRestoreDocked*(pane: PaneKind;
                       beside: Option[PaneKind] = none(PaneKind)):
    LayoutCommand =
  ## `ahRestore` (§3.3): out of `docked`, back into the tree with
  ## `lcAddPane`'s placement semantics.
  LayoutCommand(kind: lcSetAutoHide, autoHideDirection: ahRestore,
                autoHidePane: pane, autoHideEdge: leLeft, autoHideOrder: -1,
                autoHideTitle: "", autoHideRestoreBeside: beside)

proc cmdRename*(pane: PaneKind; title: string): LayoutCommand =
  LayoutCommand(kind: lcRename, renameTarget: pane, renameTitle: title)

proc `$`*(cmd: LayoutCommand): string =
  ## One line for a failure message. Not a serialisation format.
  case cmd.kind
  of lcActivateTab: "activateTab(" & $cmd.activateTarget & ")"
  of lcSetWeight:
    "setWeight(" & $cmd.weightTarget & ", " & $cmd.weightValue & ")"
  of lcAddPane:
    "addPane(" & $cmd.addedPane & ", after=" &
      (if cmd.addAfter.isSome: $cmd.addAfter.get else: "root") & ")"
  of lcRemovePane: "removePane(" & $cmd.removedPane & ")"
  of lcMoveTab:
    "moveTab(" & $cmd.movedPane & " -> beside " & $cmd.moveBeside & " @" &
      $cmd.moveIndex & ")"
  of lcSplit:
    (if cmd.splitMovesPane: "splitMove(" else: "split(") &
      $cmd.splitTarget & ", " & $cmd.splitNewPane & ", " &
      $cmd.splitAxis & ", " & $cmd.splitSide & ")"
  of lcMergeIntoStack:
    "mergeIntoStack(" & $cmd.mergedPane & " -> " & $cmd.mergeBeside &
      (if cmd.mergeWholeRegion: ", wholeRegion" else: "") & ")"
  of lcSetAutoHide:
    case cmd.autoHideDirection
    of ahDock:
      "dock(" & $cmd.autoHidePane & ", " & $cmd.autoHideEdge & ", order=" &
        $cmd.autoHideOrder & ")"
    of ahRestore:
      "restoreDocked(" & $cmd.autoHidePane & ")"
  of lcRename: "rename(" & $cmd.renameTarget & ", '" & cmd.renameTitle & "')"

# ---------------------------------------------------------------------------
# §2.1 / §2.3 — `apply`
# ---------------------------------------------------------------------------

proc refused(kind: LayoutProblemKind; pane: Option[PaneKind];
             path = ""): LayoutOutcome =
  LayoutOutcome(kind: loRefused,
                problem: LayoutProblem(kind: kind, path: path, pane: pane))

proc refusedFor(kind: LayoutProblemKind; pane: PaneKind): LayoutOutcome =
  refused(kind, some(pane))

proc noOp(): LayoutOutcome = LayoutOutcome(kind: loNoOp)

proc appliedTo(l: Layout): LayoutOutcome =
  LayoutOutcome(kind: loApplied, layout: l)

proc maxOrderAt(layout: Layout; edge: LayoutEdge): int =
  result = -1
  for d in layout.docked:
    if d.edge == edge and d.order > result:
      result = d.order

proc orderTaken(layout: Layout; edge: LayoutEdge; order: int;
                excluding: PaneKind; hasExclusion: bool): bool =
  for d in layout.docked:
    if hasExclusion and d.pane == excluding:
      continue
    if d.edge == edge and d.order == order:
      return true
  false

proc apply*(layout: Layout; cmd: LayoutCommand): LayoutOutcome =
  ## Layout-ViewModel §2.1. **Never mutates its argument.**
  ##
  ## It returns either a new layout (`loApplied`), the statement that the
  ## layout is already in that state (`loNoOp`), or a typed refusal
  ## (`loRefused`) — and the new layout is reachable only from the first, so
  ## a caller physically cannot log an undo entry for a no-op.
  ##
  ## Purity is what makes undo a command log rather than a second mechanism
  ## (§2.5), and it is what lets a drag preview a drop without committing it.
  if layout.tree.isNil:
    return refused(lpEmptyRoot, none(PaneKind))

  var next = layout.clone()
  let tree = next.tree

  case cmd.kind

  of lcActivateTab:
    if not tree.contains(cmd.activateTarget):
      return refusedFor(lpPaneNotPlaced, cmd.activateTarget)
    if tree.isVisible(cmd.activateTarget):
      return noOp()
    discard tree.activate(cmd.activateTarget)
    return appliedTo(next)

  of lcSetWeight:
    if cmd.weightValue < 0.0:
      return refusedFor(lpNegativeWeight, cmd.weightTarget)
    let leaf = tree.find(cmd.weightTarget)
    if leaf.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.weightTarget)
    if leaf.weight == cmd.weightValue:
      return noOp()
    leaf.weight = cmd.weightValue
    return appliedTo(next)

  of lcAddPane:
    if tree.contains(cmd.addedPane):
      return refusedFor(lpDuplicatePane, cmd.addedPane)
    if next.dockedIndex(cmd.addedPane) >= 0:
      # Placing a pane that is docked would put it in both at once, which is
      # exactly the invariant §3.3 names. `ahRestore` is the way to move it.
      return refusedFor(lpPaneBothPlacedAndDocked, cmd.addedPane)
    if cmd.addAfter.isSome and not tree.contains(cmd.addAfter.get):
      return refusedFor(lpPaneNotPlaced, cmd.addAfter.get)
    let leaf = pane(cmd.addedPane, cmd.addedTitle, cmd.addedWeight)
    if not insertBeside(tree, cmd.addAfter, leaf):
      return refusedFor(lpPaneNotPlaced, cmd.addedPane)
    return appliedTo(next)

  of lcRemovePane:
    if not tree.contains(cmd.removedPane):
      return refusedFor(lpPaneNotPlaced, cmd.removedPane)
    if allPanes(tree).len <= 1:
      # §2.4 rule 3. Refused, not emptied: there is no valid layout with no
      # panes, and a shell that reaches one has no way back through the UI.
      return refusedFor(lpEmptyRoot, cmd.removedPane)
    discard detachPane(tree, cmd.removedPane)
    if not normaliseInPlace(tree):
      return refusedFor(lpEmptyRoot, cmd.removedPane)
    return appliedTo(next)

  of lcMoveTab:
    let source = tree.find(cmd.movedPane)
    if source.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.movedPane)
    let anchor = tree.find(cmd.moveBeside)
    if anchor.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.moveBeside)
    let destination = parentOf(tree, anchor)
    if destination.isNil or destination.kind != lnStack:
      return refusedFor(lpTargetNotAStack, cmd.moveBeside)
    let sourceParent = parentOf(tree, source)
    let sameStack = sourceParent == destination
    let finalLen =
      if sameStack: destination.children.len
      else: destination.children.len + 1
    if cmd.moveIndex < 0 or cmd.moveIndex >= finalLen:
      return refusedFor(lpIndexOutOfRange, cmd.movedPane)
    if sameStack:
      let at = indexIn(destination, source)
      if at == cmd.moveIndex:
        # A drag that lands where it started. §2.3's whole reason for
        # `loNoOp` being distinct.
        return noOp()
      destination.children.delete(at)
      destination.children.insert(source, cmd.moveIndex)
      destination.activeIndex = cmd.moveIndex
      return appliedTo(next)
    # Different stacks. Detach first, then collapse — and then RE-FIND the
    # destination, because collapsing can rewrite a container in place and
    # the ref taken above may no longer be in the tree. The anchor pane is
    # unique, so finding its parent again is exact.
    let moved = copyOf(source)
    discard detachPane(tree, cmd.movedPane)
    if not normaliseInPlace(tree):
      return refusedFor(lpEmptyRoot, cmd.movedPane)
    let anchorAgain = tree.find(cmd.moveBeside)
    if anchorAgain.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.moveBeside)
    let destAgain = parentOf(tree, anchorAgain)
    if destAgain.isNil or destAgain.kind != lnStack:
      return refusedFor(lpTargetNotAStack, cmd.moveBeside)
    let at = min(cmd.moveIndex, destAgain.children.len)
    destAgain.children.insert(moved, at)
    destAgain.activeIndex = at
    return appliedTo(next)

  of lcSplit:
    var movedTitle = cmd.splitNewTitle
    if cmd.splitMovesPane:
      # PLAT-5's drop gesture: the pane is already placed and the split MOVES
      # it. Every guard here is the mirror of the branch below — "must not be
      # in the tree" becomes "must be", and the detach brings §2.4's collapse
      # rules with it exactly as `lcMoveTab`'s cross-stack path does.
      if cmd.splitNewPane == cmd.splitTarget:
        return refusedFor(lpDuplicatePane, cmd.splitNewPane)
      if next.dockedIndex(cmd.splitNewPane) >= 0:
        return refusedFor(lpPaneBothPlacedAndDocked, cmd.splitNewPane)
      let moving = tree.find(cmd.splitNewPane)
      if moving.isNil:
        return refusedFor(lpPaneNotPlaced, cmd.splitNewPane)
      if tree.find(cmd.splitTarget).isNil:
        return refusedFor(lpPaneNotPlaced, cmd.splitTarget)
      if movedTitle.len == 0:
        movedTitle = moving.title
      discard detachPane(tree, cmd.splitNewPane)
      if not normaliseInPlace(tree):
        return refusedFor(lpEmptyRoot, cmd.splitNewPane)
    else:
      if tree.contains(cmd.splitNewPane):
        return refusedFor(lpDuplicatePane, cmd.splitNewPane)
      if next.dockedIndex(cmd.splitNewPane) >= 0:
        return refusedFor(lpPaneBothPlacedAndDocked, cmd.splitNewPane)
    # RE-FOUND AFTER THE DETACH, for `lcMoveTab`'s reason: collapsing can
    # rewrite a container in place, so a ref taken before it may no longer be
    # in the tree. The target pane is unique, so finding it again is exact.
    let leaf = tree.find(cmd.splitTarget)
    if leaf.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.splitTarget)
    # Splitting a TABBED pane splits the whole stack, not the tab: a user who
    # drags a new pane to the right of a tabbed region expects the region to
    # move, and a stack nested inside a row inside a stack is not a shape this
    # model has (`lpStackChildNotPane`).
    var replaced = leaf
    let leafParent = parentOf(tree, leaf)
    if not leafParent.isNil and leafParent.kind == lnStack:
      replaced = leafParent
    let share = replaced.weight
    let inner = copyOf(replaced)
    let fresh = pane(cmd.splitNewPane, movedTitle, share)
    let kids =
      if cmd.splitSide == ssBefore: @[fresh, inner] else: @[inner, fresh]
    let containerKind = if cmd.splitAxis == saRow: lnRow else: lnColumn
    replaced.becomes(LayoutNode(kind: containerKind, weight: share,
                                children: kids))
    if cmd.splitMovesPane and equalTrees(tree, layout.tree):
      # A drag that ended where it began. §2.3's `loNoOp`, decided HERE —
      # `apply` is the one authority on "nothing happened", so PLAT-5's
      # `commit` can define its `none` as "`apply` did not say `loApplied`"
      # rather than forming a second opinion.
      return noOp()
    return appliedTo(next)

  of lcMergeIntoStack:
    if cmd.mergedPane == cmd.mergeBeside:
      return refusedFor(lpDuplicatePane, cmd.mergedPane)
    let source = tree.find(cmd.mergedPane)
    if source.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.mergedPane)
    if tree.find(cmd.mergeBeside).isNil:
      return refusedFor(lpPaneNotPlaced, cmd.mergeBeside)
    if cmd.mergeWholeRegion:
      # Open decision 1 of §8, answered: stacks hold only panes, and dragging
      # a whole SPLIT into a tab is refused BY KIND rather than silently
      # reinterpreted as dragging the one pane under the cursor. The
      # restriction stays until a user asks for it to be lifted, and this is
      # the typed outcome that says so.
      return refusedFor(lpStackChildNotPane, cmd.mergedPane)
    let sourceParent = parentOf(tree, source)
    let anchorParent = parentOf(tree, tree.find(cmd.mergeBeside))
    if not anchorParent.isNil and anchorParent.kind == lnStack and
       sourceParent == anchorParent:
      return noOp()
    let moved = copyOf(source)
    discard detachPane(tree, cmd.mergedPane)
    if not normaliseInPlace(tree):
      return refusedFor(lpEmptyRoot, cmd.mergedPane)
    let anchorAgain = tree.find(cmd.mergeBeside)
    if anchorAgain.isNil:
      return refusedFor(lpPaneNotPlaced, cmd.mergeBeside)
    let destAgain = parentOf(tree, anchorAgain)
    if not destAgain.isNil and destAgain.kind == lnStack:
      let at = indexIn(destAgain, anchorAgain)
      destAgain.children.insert(moved, at + 1)
      destAgain.activeIndex = at + 1
      return appliedTo(next)
    # The anchor is a bare pane: it becomes a two-tab stack holding itself
    # and the newcomer. This is "drop a tab onto a pane", which is the same
    # gesture as "drop a tab onto a stack" from the user's side.
    let existing = copyOf(anchorAgain)
    let share = anchorAgain.weight
    existing.weight = 0.0
    moved.weight = 0.0
    anchorAgain.becomes(LayoutNode(kind: lnStack, weight: share,
                                   activeIndex: 1,
                                   children: @[existing, moved]))
    return appliedTo(next)

  of lcSetAutoHide:
    case cmd.autoHideDirection
    of ahDock:
      let already = next.dockedIndex(cmd.autoHidePane)
      if already >= 0:
        let d = next.docked[already]
        let wanted =
          if cmd.autoHideOrder < 0: d.order else: cmd.autoHideOrder
        if d.edge == cmd.autoHideEdge and d.order == wanted:
          return noOp()
        if orderTaken(next, cmd.autoHideEdge, wanted, cmd.autoHidePane, true):
          return refusedFor(lpDockOrderCollision, cmd.autoHidePane)
        next.docked[already].edge = cmd.autoHideEdge
        next.docked[already].order = wanted
        return appliedTo(next)
      let leaf = tree.find(cmd.autoHidePane)
      if leaf.isNil:
        return refusedFor(lpPaneNotPlaced, cmd.autoHidePane)
      if allPanes(tree).len <= 1:
        # Docking the last placed pane would empty the root — §2.4 rule 3
        # again, reached from the other direction.
        return refusedFor(lpEmptyRoot, cmd.autoHidePane)
      let order =
        if cmd.autoHideOrder < 0: maxOrderAt(next, cmd.autoHideEdge) + 1
        else: cmd.autoHideOrder
      if orderTaken(next, cmd.autoHideEdge, order, cmd.autoHidePane, false):
        return refusedFor(lpDockOrderCollision, cmd.autoHidePane)
      let title =
        if cmd.autoHideTitle.len > 0: cmd.autoHideTitle else: leaf.title
      discard detachPane(tree, cmd.autoHidePane)
      if not normaliseInPlace(tree):
        return refusedFor(lpEmptyRoot, cmd.autoHidePane)
      next.docked.add(DockedPane(pane: cmd.autoHidePane, title: title,
                                 edge: cmd.autoHideEdge, order: order,
                                 revealed: false))
      return appliedTo(next)
    of ahRestore:
      let at = next.dockedIndex(cmd.autoHidePane)
      if at < 0:
        return refusedFor(lpPaneNotDocked, cmd.autoHidePane)
      if tree.contains(cmd.autoHidePane):
        return refusedFor(lpPaneBothPlacedAndDocked, cmd.autoHidePane)
      if cmd.autoHideRestoreBeside.isSome and
         not tree.contains(cmd.autoHideRestoreBeside.get):
        return refusedFor(lpPaneNotPlaced, cmd.autoHideRestoreBeside.get)
      let entry = next.docked[at]
      let leaf = pane(entry.pane, entry.title)
      if not insertBeside(tree, cmd.autoHideRestoreBeside, leaf):
        return refusedFor(lpPaneNotPlaced, cmd.autoHidePane)
      next.docked.delete(at)
      return appliedTo(next)

  of lcRename:
    let leaf = tree.find(cmd.renameTarget)
    if not leaf.isNil:
      if leaf.title == cmd.renameTitle:
        return noOp()
      leaf.title = cmd.renameTitle
      return appliedTo(next)
    let at = next.dockedIndex(cmd.renameTarget)
    if at < 0:
      # Neither in the tree nor in `docked`: there is nothing to rename, and
      # saying so by kind is the difference between a reportable condition
      # and a rename that quietly did nothing.
      return refusedFor(lpPaneNeitherPlacedNorDocked, cmd.renameTarget)
    if next.docked[at].title == cmd.renameTitle:
      return noOp()
    next.docked[at].title = cmd.renameTitle
    return appliedTo(next)

proc apply*(node: LayoutNode; cmd: LayoutCommand): LayoutOutcome =
  ## Layout-ViewModel §2.1's literal signature, for a caller that has a bare
  ## tree and no docked panes. The tree is not mutated; the outcome's layout
  ## carries a new one.
  apply(initLayout(node), cmd)

proc layoutOr*(outcome: LayoutOutcome; fallback: Layout): Layout =
  ## The layout an outcome leaves in effect: the new one for `loApplied`, and
  ## `fallback` for the two outcomes that produced none. A convenience, NOT a
  ## way around §2.3 — the caller still had to name the fallback, so it
  ## still had to know the command might not have applied.
  if outcome.kind == loApplied: outcome.layout else: fallback

# ---------------------------------------------------------------------------
# Mutation — the tab switching `session_switch.nim` does through GoldenLayout
#
# These four are Layout-ViewModel §2.1's "the mutators stay, implemented in
# terms of the algebra". They share ITS primitives — `detachPane`,
# `normaliseInPlace`, `insertBeside` — rather than calling `apply`, and the
# difference is deliberate: `apply` works on a COPY, so the nodes it returns
# are not the nodes the caller is holding. `removePane` has callers that keep
# a reference to a node inside the tree and read it afterwards, so it mutates
# in place. Routing it through `apply` and grafting the result back would
# leave every such reference pointing at a detached subtree — a silent
# aliasing bug in exchange for one less line here.
# ---------------------------------------------------------------------------

proc activate*(node: LayoutNode; kind: PaneKind): bool =
  ## Make `kind` visible by selecting it in every stack that encloses it.
  ## Returns false, changing nothing, when the pane is not in the tree.
  ##
  ## This is the model's answer to `callInitLayoutSafe(session
  ## .savedLayoutConfig, targetContainer)`: selecting a tab is an index
  ## assignment, not a destroy-and-recreate of a renderer's DOM.
  if node.isNil:
    return false
  if node.kind == lnPane:
    return node.pane == kind
  for i, c in node.children:
    if activate(c, kind):
      if node.kind == lnStack:
        node.activeIndex = i
      return true
  false

proc setWeight*(node: LayoutNode; kind: PaneKind; weight: float): bool =
  ## Resize the region holding `kind`. False when the pane is absent, and —
  ## since PLAT-4 — false for a negative share, which `lcSetWeight` refuses
  ## with `lpNegativeWeight` and `validate` reports as a defect. Writing one
  ## through this door and reading it back through `validate` would have been
  ## the model contradicting itself.
  if weight < 0.0:
    return false
  let leaf = find(node, kind)
  if leaf.isNil:
    return false
  leaf.weight = weight
  true

proc removePane*(node: LayoutNode; kind: PaneKind): bool =
  ## Close a pane, applying §2.4's collapse rules to whatever the removal
  ## degenerates.
  ##
  ## Collapsing is what makes `lpEmptyContainer` unreachable through ordinary
  ## use, and it is also why `LayoutNode` is not a variant object: a stack
  ## that loses all but one child is rewritten in place.
  ##
  ## TWO BEHAVIOURS CHANGED IN PLAT-4, both of them the milestone's point:
  ##
  ##   * a row or column left with ONE child is now replaced by that child
  ##     (§2.4 rule 1), where before it was left as a single-child container.
  ##     A tree with one is now `lpSingleChildContainer` at the `Layout`
  ##     level, so leaving one behind would be writing a defect;
  ##   * removing the LAST pane is refused (§2.4 rule 3) rather than emptying
  ##     the tree. `false` here means the same thing `loRefused` means there.
  if node.isNil or node.kind == lnPane:
    return false
  if not node.contains(kind):
    return false
  if allPanes(node).len <= 1:
    return false
  discard detachPane(node, kind)
  discard normaliseInPlace(node)
  true

proc addPane*(node: LayoutNode; leaf: LayoutNode): bool =
  ## Append `leaf` to `node`, and select it if `node` is a stack. False when
  ## `node` is a bare pane, which has nowhere to put it, and — since PLAT-4 —
  ## false when the pane is already placed, which would be `lpDuplicatePane`.
  if node.isNil or leaf.isNil or node.kind == lnPane:
    return false
  if leaf.kind == lnPane and node.contains(leaf.pane):
    return false
  node.children.add(leaf)
  if node.kind == lnStack:
    node.activeIndex = node.children.len - 1
  true

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

proc validateNode(node: LayoutNode; path: string; seen: var Table[PaneKind, bool];
                  problems: var seq[LayoutProblem]) =
  if node.isNil:
    return
  if node.weight < 0.0:
    problems.add(LayoutProblem(kind: lpNegativeWeight, path: path,
                               pane: none(PaneKind)))
  if node.kind == lnPane:
    if node.children.len > 0:
      problems.add(LayoutProblem(kind: lpPaneWithChildren, path: path,
                                 pane: some(node.pane)))
    if seen.hasKeyOrPut(node.pane, true):
      problems.add(LayoutProblem(kind: lpDuplicatePane, path: path,
                                 pane: some(node.pane)))
    return
  # Containers. `pane` defaults to the enum's first value, so "was it set?"
  # is not answerable from the field alone — which is exactly the flat-record
  # cost. It IS answerable from the constructors, which never set it on a
  # container, so a non-default value here is unambiguous evidence of a
  # hand-built node and is reported; a container carrying the default value
  # is indistinguishable from one that never set it, and is not.
  if node.pane != PaneKind.low:
    problems.add(LayoutProblem(kind: lpContainerWithPaneField, path: path,
                               pane: some(node.pane)))
  if node.children.len == 0:
    problems.add(LayoutProblem(kind: lpEmptyContainer, path: path,
                               pane: none(PaneKind)))
  if node.kind == lnStack:
    if node.children.len > 0 and
       (node.activeIndex < 0 or node.activeIndex >= node.children.len):
      problems.add(LayoutProblem(kind: lpActiveIndexOutOfRange, path: path,
                                 pane: none(PaneKind)))
    for i, c in node.children:
      if c.kind != lnPane:
        problems.add(LayoutProblem(
          kind: lpStackChildNotPane,
          path: (if path.len == 0: $i else: path & "/" & $i),
          pane: none(PaneKind)))
  for i, c in node.children:
    validateNode(c, (if path.len == 0: $i else: path & "/" & $i), seen,
                 problems)

proc validate*(node: LayoutNode): seq[LayoutProblem] =
  ## Every structural defect in the tree, in depth-first order. Empty means
  ## the tree is well formed.
  result = @[]
  var seen = initTable[PaneKind, bool]()
  validateNode(node, "", seen, result)

proc isValid*(node: LayoutNode): bool =
  ## Convenience over `validate`.
  validate(node).len == 0

proc problemSources*(kind: LayoutProblemKind): set[LayoutProblemSource] =
  ## Which of the two producers can report `kind`. The model's own suite
  ## asserts this table against reality — a witness tree for every kind with
  ## `lpsStructural`, and a witness COMMAND for every kind with `lpsRefusal` —
  ## so it cannot drift into being a comment that used to be true.
  case kind
  of lpEmptyContainer, lpPaneWithChildren, lpContainerWithPaneField,
     lpActiveIndexOutOfRange, lpSingleChildContainer:
    {lpsStructural}
  of lpStackChildNotPane, lpDuplicatePane, lpNegativeWeight,
     lpPaneBothPlacedAndDocked, lpEmptyRoot, lpDockOrderCollision:
    ## Both: a saved layout can already contain one, and a command can be
    ## refused for proposing to create one.
    {lpsStructural, lpsRefusal}
  of lpPaneNeitherPlacedNorDocked:
    {lpsStructural, lpsRefusal}
  of lpPaneNotPlaced, lpPaneNotDocked, lpTargetNotAStack, lpIndexOutOfRange:
    {lpsRefusal}

proc singleChildContainers(node: LayoutNode; path: string;
                           problems: var seq[LayoutProblem]) =
  if node.isNil or node.kind == lnPane:
    return
  if node.kind in {lnRow, lnColumn} and node.children.len == 1:
    problems.add(LayoutProblem(kind: lpSingleChildContainer, path: path,
                               pane: none(PaneKind)))
  for i, c in node.children:
    singleChildContainers(c, (if path.len == 0: $i else: path & "/" & $i),
                          problems)

proc validate*(layout: Layout; owned: set[PaneKind] = {}): seq[LayoutProblem] =
  ## Every structural defect in a whole layout: the seven `validate(LayoutNode)`
  ## reports about the tree, plus Layout-ViewModel §7's five, which need the
  ## `docked` list and therefore cannot live on the node overload.
  ##
  ## `owned` is the set of panes the SHELL says this layout is responsible
  ## for, and it is what makes `lpPaneNeitherPlacedNorDocked` answerable.
  ## Nothing in this module can know it: a layout is a description of an
  ## arrangement, and "which panes should be arranged" is the shell's. The
  ## default is the empty set, which makes that one check VACUOUS — stated
  ## here rather than left to be discovered, because a check that cannot fail
  ## is worse than no check (Verification-Harness-Traps §4). The model's own
  ## suite passes a non-empty set.
  result = validate(layout.tree)
  singleChildContainers(layout.tree, "", result)
  if layout.tree.isNil or allPanes(layout.tree).len == 0:
    result.add(LayoutProblem(kind: lpEmptyRoot, path: "", pane: none(PaneKind)))
  var seenDocked = initTable[PaneKind, bool]()
  var seenSlot = initTable[string, bool]()
  for i, d in layout.docked:
    if layout.tree.contains(d.pane):
      result.add(LayoutProblem(kind: lpPaneBothPlacedAndDocked,
                               path: "docked/" & $i, pane: some(d.pane)))
    if seenDocked.hasKeyOrPut(d.pane, true):
      result.add(LayoutProblem(kind: lpDuplicatePane, path: "docked/" & $i,
                               pane: some(d.pane)))
    let slot = $d.edge & "#" & $d.order
    if seenSlot.hasKeyOrPut(slot, true):
      result.add(LayoutProblem(kind: lpDockOrderCollision,
                               path: "docked/" & $i, pane: some(d.pane)))
  for p in owned:
    if not layout.tree.contains(p) and layout.dockedIndex(p) < 0:
      result.add(LayoutProblem(kind: lpPaneNeitherPlacedNorDocked, path: "",
                               pane: some(p)))

proc isValid*(layout: Layout; owned: set[PaneKind] = {}): bool =
  validate(layout, owned).len == 0

# ---------------------------------------------------------------------------
# Serialisation — the replacement for `ReplaySession.savedLayoutConfig`
# ---------------------------------------------------------------------------

proc toJson*(node: LayoutNode): JsonNode =
  ## The node as JSON. Unset optional fields are omitted, so a hand-written
  ## fixture and a round-tripped one are the same document.
  if node.isNil:
    return newJNull()
  result = newJObject()
  result["kind"] = %($node.kind)
  case node.kind
  of lnPane:
    result["pane"] = %($node.pane)
  of lnStack:
    result["activeIndex"] = %node.activeIndex
  of lnRow, lnColumn:
    discard
  if node.title.len > 0:
    result["title"] = %node.title
  if node.weight != 0.0:
    result["weight"] = %node.weight
  if node.kind != lnPane:
    var kids = newJArray()
    for c in node.children:
      kids.add(toJson(c))
    result["children"] = kids

proc toJson*(d: DockedPane): JsonNode =
  ## One docked pane. `revealed` IS DELIBERATELY ABSENT (§3.2): a revealed
  ## strip is an overlay the user is currently looking at, it belongs to
  ## PLAT-5's transient state, and a restore that reopened four overlays would
  ## be a bug. The field not being written is what prevents it — a decoder
  ## cannot resurrect what an encoder never wrote.
  result = newJObject()
  result["pane"] = %($d.pane)
  result["edge"] = %($d.edge)
  result["order"] = %d.order
  if d.title.len > 0:
    result["title"] = %d.title

proc saveLayout*(layout: Layout): JsonNode =
  ## A versioned document, which is what a shell persists. `docked` is always
  ## written, even when empty (§6): a front-end gaining auto-hide later must
  ## not be a schema bump.
  result = newJObject()
  result["version"] = %LayoutSchemaVersion
  result["layout"] = toJson(layout.tree)
  var arr = newJArray()
  for d in layout.docked:
    arr.add(toJson(d))
  result["docked"] = arr

proc saveLayout*(node: LayoutNode): JsonNode =
  ## The tree alone, as the same document with an empty `docked`.
  saveLayout(initLayout(node))

proc raiseDecode(kind: LayoutDecodeErrorKind; detail: string) {.noreturn.} =
  var e = newException(LayoutDecodeError, $kind & ": " & detail)
  e.kind = kind
  e.detail = detail
  raise e

proc parsePaneKind(s: string): PaneKind =
  for p in PaneKind:
    if $p == s:
      return p
  raiseDecode(ldeUnknownPane, s)

proc parseNodeKind(s: string): LayoutNodeKind =
  for k in LayoutNodeKind:
    if $k == s:
      return k
  raiseDecode(ldeUnknownNodeKind, s)

proc fromJson*(j: JsonNode): LayoutNode =
  ## Decode one node. Raises `LayoutDecodeError` with a typed `kind`.
  if j.isNil or j.kind == JNull:
    return nil
  if j.kind != JObject:
    raiseDecode(ldeNotAnObject, "node is " & $j.kind)
  if not j.hasKey("kind"):
    raiseDecode(ldeMissingField, "kind")
  if j["kind"].kind != JString:
    raiseDecode(ldeWrongFieldType, "kind is " & $j["kind"].kind)
  let nodeKind = parseNodeKind(j["kind"].getStr)
  result = LayoutNode(kind: nodeKind, children: @[])
  if nodeKind == lnPane:
    if not j.hasKey("pane"):
      raiseDecode(ldeMissingField, "pane")
    if j["pane"].kind != JString:
      raiseDecode(ldeWrongFieldType, "pane is " & $j["pane"].kind)
    result.pane = parsePaneKind(j["pane"].getStr)
  if j.hasKey("title"):
    if j["title"].kind != JString:
      raiseDecode(ldeWrongFieldType, "title is " & $j["title"].kind)
    result.title = j["title"].getStr
  if j.hasKey("weight"):
    if j["weight"].kind notin {JInt, JFloat}:
      raiseDecode(ldeWrongFieldType, "weight is " & $j["weight"].kind)
    result.weight = j["weight"].getFloat
  if j.hasKey("activeIndex"):
    if j["activeIndex"].kind != JInt:
      raiseDecode(ldeWrongFieldType, "activeIndex is " & $j["activeIndex"].kind)
    result.activeIndex = j["activeIndex"].getInt
  if j.hasKey("children"):
    if j["children"].kind != JArray:
      raiseDecode(ldeWrongFieldType, "children is " & $j["children"].kind)
    for c in j["children"]:
      result.children.add(fromJson(c))

proc parseEdge(s: string): LayoutEdge =
  for e in LayoutEdge:
    if $e == s:
      return e
  raiseDecode(ldeUnknownEdge, s)

proc migrateV1toV2(doc: JsonNode): JsonNode =
  ## v1 → v2: `docked` did not exist, so a v1 document describes a layout with
  ## nothing docked. The tree encoding did not change, so this is the whole
  ## migration.
  result = copy(doc)
  result["docked"] = newJArray()
  result["version"] = %2

proc migrateDocument(doc: JsonNode): JsonNode =
  ## Walk a document forward, ONE VERSION AT A TIME, to this build's schema
  ## version (§6).
  ##
  ## One step at a time rather than a jump table from every old version to the
  ## current one: with N versions the chain is N-1 functions and the table is
  ## N(N-1)/2, and the second one is where a migration that nobody exercised
  ## since three releases ago lives. There is no backward migration — an older
  ## build refusing a newer layout is correct and must stay loud.
  let v = doc["version"].getInt
  if v > LayoutSchemaVersion or v < FirstLayoutSchemaVersion:
    raiseDecode(ldeUnknownVersion, $v)
  result = doc
  var at = v
  while at < LayoutSchemaVersion:
    case at
    of 1:
      result = migrateV1toV2(result)
    else:
      # Unreachable while the chain is complete, and this is what makes
      # "complete" checkable: a bump that forgets its migration lands here
      # rather than silently handing a decoder a shape it does not know.
      raiseDecode(ldeUnknownVersion, $at)
    inc at

proc restoreLayoutDocument*(j: JsonNode): Layout =
  ## Decode a versioned document into a whole `Layout`, migrating forward
  ## through the chain when it is older than this build (§6).
  ##
  ## A document from a schema version this build does not know raises
  ## `ldeUnknownVersion` — the caller's cue to fall back to
  ## `defaultReplayLayout()` rather than render a half-understood tree.
  if j.isNil or j.kind != JObject:
    raiseDecode(ldeNotAnObject, "document is " &
      (if j.isNil: "nil" else: $j.kind))
  if not j.hasKey("version"):
    raiseDecode(ldeMissingField, "version")
  if j["version"].kind != JInt:
    raiseDecode(ldeWrongFieldType, "version is " & $j["version"].kind)
  let doc = migrateDocument(j)
  if not doc.hasKey("layout"):
    raiseDecode(ldeMissingField, "layout")
  result = initLayout(fromJson(doc["layout"]))
  if not doc.hasKey("docked"):
    raiseDecode(ldeMissingField, "docked")
  if doc["docked"].kind != JArray:
    raiseDecode(ldeWrongFieldType, "docked is " & $doc["docked"].kind)
  for entry in doc["docked"]:
    if entry.kind != JObject:
      raiseDecode(ldeNotAnObject, "docked entry is " & $entry.kind)
    for field in ["pane", "edge", "order"]:
      if not entry.hasKey(field):
        raiseDecode(ldeMissingField, "docked." & field)
    if entry["pane"].kind != JString:
      raiseDecode(ldeWrongFieldType, "docked.pane is " & $entry["pane"].kind)
    if entry["edge"].kind != JString:
      raiseDecode(ldeWrongFieldType, "docked.edge is " & $entry["edge"].kind)
    if entry["order"].kind != JInt:
      raiseDecode(ldeWrongFieldType, "docked.order is " & $entry["order"].kind)
    var d = DockedPane(
      pane: parsePaneKind(entry["pane"].getStr),
      edge: parseEdge(entry["edge"].getStr),
      order: entry["order"].getInt,
      revealed: false)
        ## `revealed` is forced false rather than read. Even a document that
        ## somehow carries the field — hand-edited, or written by a build
        ## that regressed §3.2 — restores with every overlay closed.
    if entry.hasKey("title"):
      if entry["title"].kind != JString:
        raiseDecode(ldeWrongFieldType, "docked.title is " & $entry["title"].kind)
      d.title = entry["title"].getStr
    result.docked.add(d)

proc restoreLayout*(j: JsonNode): LayoutNode =
  ## The TREE of a versioned document, for the callers that predate `Layout`.
  ##
  ## A document carrying docked panes is refused with
  ## `ldeDockedPanesUnsupported` rather than decoded and truncated: a bare
  ## `LayoutNode` cannot represent a docked pane, so returning one would drop
  ## the panes silently — §1.3's blank-slot failure, one level up. Callers
  ## that can hold them use `restoreLayoutDocument`.
  let layout = restoreLayoutDocument(j)
  if layout.docked.len > 0:
    raiseDecode(ldeDockedPanesUnsupported,
      $layout.docked.len & " docked pane(s) cannot be represented by a bare " &
      "LayoutNode; use restoreLayoutDocument")
  layout.tree

proc `$`*(node: LayoutNode): string =
  ## A one-line rendering for test failure output. Not a serialisation
  ## format — `saveLayout` is.
  if node.isNil:
    return "<nil>"
  case node.kind
  of lnPane:
    "pane:" & $node.pane
  of lnStack:
    var parts: seq[string] = @[]
    for i, c in node.children:
      parts.add((if i == node.activeIndex: "*" else: "") & $c)
    "stack(" & parts.join(", ") & ")"
  of lnRow, lnColumn:
    var parts: seq[string] = @[]
    for c in node.children:
      parts.add($c)
    $node.kind & "(" & parts.join(", ") & ")"

proc `$`*(d: DockedPane): string =
  $d.pane & "@" & $d.edge & "#" & $d.order

proc `$`*(layout: Layout): string =
  ## A one-line rendering for test failure output. `revealed` is not printed
  ## for the same reason it is not persisted: it is not part of the layout.
  result = $layout.tree
  if layout.docked.len > 0:
    var parts: seq[string] = @[]
    for d in layout.docked:
      parts.add($d)
    result.add(" +docked[" & parts.join(", ") & "]")

proc `$`*(outcome: LayoutOutcome): string =
  case outcome.kind
  of loApplied: "applied: " & $outcome.layout
  of loNoOp: "noOp"
  of loRefused:
    "refused: " & $outcome.problem.kind &
      (if outcome.problem.pane.isSome: " (" & $outcome.problem.pane.get & ")"
       else: "")

# ---------------------------------------------------------------------------
# §2.5 — undo/redo as a command log
# ---------------------------------------------------------------------------

proc replayPrefix(h: LayoutHistory): Layout =
  var acc = h.initial.clone()
  for i in 0 ..< h.cursor:
    let outcome = apply(acc, h.log[i])
    # Only `loApplied` commands ever enter the log, and `apply` is pure, so a
    # replay of the same prefix from the same start reaches the same layout.
    # A `loRefused` here would mean the log had been edited from outside; the
    # replay keeps the layout it had rather than inventing one.
    if outcome.kind == loApplied:
      acc = outcome.layout
  acc

proc newLayoutHistory*(initial: Layout): LayoutHistory =
  ## Start a history at `initial`. The layout is cloned, so a caller that
  ## keeps mutating its own tree cannot move the history's floor underneath
  ## it.
  result = LayoutHistory(initial: initial.clone(), log: @[], cursor: 0)
  result.value = result.initial.clone()

proc dispatch*(h: var LayoutHistory; cmd: LayoutCommand): LayoutOutcome =
  ## Apply `cmd` to the current layout and, ONLY when it applied, append it to
  ## the log (§2.5).
  ##
  ## `loNoOp` is why this can be written at all: a drag that lands a tab where
  ## it started returns `loNoOp`, nothing is appended, and the user's next
  ## undo goes back to what they would expect rather than to the same screen.
  result = apply(h.value, cmd)
  if result.kind != loApplied:
    return
  # A new command after an undo discards the redo tail — the standard editor
  # rule, and the only one under which the log stays a straight line.
  if h.cursor < h.log.len:
    h.log.setLen(h.cursor)
  h.log.add(cmd)
  h.cursor = h.log.len
  h.value = result.layout

proc canUndo*(h: LayoutHistory): bool = h.cursor > 0
proc canRedo*(h: LayoutHistory): bool = h.cursor < h.log.len

proc undo*(h: var LayoutHistory): bool =
  ## Step back one command, by replaying the prefix before it. False when
  ## there is nothing to undo.
  if not h.canUndo():
    return false
  dec h.cursor
  h.value = h.replayPrefix()
  true

proc redo*(h: var LayoutHistory): bool =
  if not h.canRedo():
    return false
  inc h.cursor
  h.value = h.replayPrefix()
  true
