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
    ## BlockTracer renders (BlockTracer.milestones.org M2b) are the first
    ## five values, and `BlockTracerPanes` below names them.
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

  LayoutProblem* = object
    ## One structural defect, with enough context to find it.
    kind*: LayoutProblemKind
    path*: string
      ## Slash-separated child indices from the root, e.g. `"0/2"`. The root
      ## itself is `""`.
    pane*: Option[PaneKind]
      ## Set when the problem is about a specific pane.

  LayoutDecodeErrorKind* = enum
    ## Why a serialised layout could not be read back.
    ldeNotAnObject = "NotAnObject"
    ldeUnknownVersion = "UnknownVersion"
    ldeUnknownPane = "UnknownPane"
    ldeUnknownNodeKind = "UnknownNodeKind"
    ldeMissingField = "MissingField"
    ldeWrongFieldType = "WrongFieldType"

  LayoutDecodeError* = object of CatchableError
    ## A typed decode failure. Restoring a layout saved by a different build
    ## is a normal event, not a crash, and the kind is what lets a shell fall
    ## back to `defaultReplayLayout()` for the right reason.
    kind*: LayoutDecodeErrorKind
    detail*: string

const
  LayoutSchemaVersion* = 1
    ## Bumped when the serialised shape changes incompatibly. A decoder that
    ## meets a version it does not know raises `ldeUnknownVersion` rather than
    ## guessing — the failure mode `savedLayoutConfig` has no way to express,
    ## because a `GoldenLayoutResolvedConfig` is whatever GoldenLayout last
    ## wrote.

  BlockTracerPanes* = {
    paneEditor, paneCalltrace, paneState, paneEventLog, paneDebugControls}
    ## The five panes BlockTracer renders (BlockTracer.milestones.org M2b).
    ## Named here so `defaultReplayLayout` and a consumer's own assertion
    ## read the same set rather than two hand-kept copies.

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
  ## `BlockTracerPanes`, with State and Event Log sharing a tabbed region so
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

# ---------------------------------------------------------------------------
# Mutation — the tab switching `session_switch.nim` does through GoldenLayout
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
  ## Resize the region holding `kind`. False when the pane is absent.
  let leaf = find(node, kind)
  if leaf.isNil:
    return false
  leaf.weight = weight
  true

proc removePane*(node: LayoutNode; kind: PaneKind): bool =
  ## Close a pane, collapsing any container it leaves empty.
  ##
  ## Collapsing is what makes `lpEmptyContainer` unreachable through ordinary
  ## use, and it is also why `LayoutNode` is not a variant object: a stack
  ## that loses all but one child is rewritten in place.
  if node.isNil or node.kind == lnPane:
    return false
  var removed = false
  var kept: seq[LayoutNode] = @[]
  for c in node.children:
    if c.kind == lnPane and c.pane == kind:
      removed = true
      continue
    if removePane(c, kind):
      removed = true
    if not (c.kind != lnPane and c.children.len == 0):
      kept.add(c)
  if removed:
    node.children = kept
    if node.kind == lnStack and node.activeIndex >= node.children.len:
      node.activeIndex = max(0, node.children.len - 1)
  removed

proc addPane*(node: LayoutNode; leaf: LayoutNode): bool =
  ## Append `leaf` to the first container found depth-first, and select it if
  ## that container is a stack. False when `node` is a bare pane, which has
  ## nowhere to put it.
  if node.isNil or leaf.isNil or node.kind == lnPane:
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

proc saveLayout*(node: LayoutNode): JsonNode =
  ## A versioned document, which is what a shell persists.
  result = newJObject()
  result["version"] = %LayoutSchemaVersion
  result["layout"] = toJson(node)

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

proc restoreLayout*(j: JsonNode): LayoutNode =
  ## Decode a versioned document. A document from a schema version this build
  ## does not know raises `ldeUnknownVersion` — the caller's cue to fall back
  ## to `defaultReplayLayout()` rather than render a half-understood tree.
  if j.isNil or j.kind != JObject:
    raiseDecode(ldeNotAnObject, "document is " &
      (if j.isNil: "nil" else: $j.kind))
  if not j.hasKey("version"):
    raiseDecode(ldeMissingField, "version")
  if j["version"].kind != JInt:
    raiseDecode(ldeWrongFieldType, "version is " & $j["version"].kind)
  let v = j["version"].getInt
  if v != LayoutSchemaVersion:
    raiseDecode(ldeUnknownVersion, $v)
  if not j.hasKey("layout"):
    raiseDecode(ldeMissingField, "layout")
  fromJson(j["layout"])

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
