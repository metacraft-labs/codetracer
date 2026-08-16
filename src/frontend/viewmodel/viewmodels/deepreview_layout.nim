## Additive GoldenLayout placement for the DeepReview review surface.
##
## DeepReview (``ct --deepreview <export.json>``) used to *replace* the
## user's GoldenLayout with a hand-rolled three-panel preset (VCS +
## DeepReview + CALLTRACE).  Everything else — FILES, STATE, SCRATCHPAD,
## AGENT ACTIVITY, EVENT LOG, TIMELINE, TERMINAL OUTPUT — simply vanished
## for the whole session, and the preset then had to be defended against
## with workarounds elsewhere (the renderer refuses to persist a layout
## while ``deepReviewActive``; the index-side layout loader rejects any
## saved layout that lost its Filesystem panel).  See issue #610.
##
## The fix mirrors what ``visual_replay_layout`` already does for the MCR
## visual-replay tabs: placement is **additive**.  The user's own layout is
## kept intact and a single DeepReview surface is inserted into the editor
## area, exactly where ``data.openLayoutTab(Content.DeepReview,
## DeepReviewId, isEditor = true)`` would put it when the agentic session
## launcher opens the same panel on a live debug layout
## (``ui/agentic_session_launcher.nim``).  That launcher is the reference
## implementation this module reproduces for the startup path.
##
## All helpers operate on parsed ``JsonNode`` trees, so the placement rules
## are testable headlessly — no Electron, no GoldenLayout, no DOM.  The
## bridge to the live JS config object is
## ``ui_js.resolvedConfigToJsonNode`` / ``jsonNodeToResolvedConfig``.
##
## Spec: codetracer-specs/DeepReview/DeepReview-GUI.md (§2 view modes,
## §7 panel placement)

import std/json

import visual_replay_layout

export
  # The generic layout-JSON vocabulary is shared with the visual-replay
  # walker rather than duplicated.  These primitives are not visual-replay
  # specific and should eventually move into a neutral ``layout_json``
  # module; re-exporting keeps consumers (and the tests) importing one
  # module until that refactor happens.
  contentIdsInLayout,
  layoutContainsContentId,
  EditorViewContentId,
  StateContentId,
  CalltraceContentId,
  EventLogContentId,
  FilesystemContentId,
  LowLevelCodeContentId,
  EditorComponentName

const
  ## ``Content.DeepReview`` in
  ## ``common/common_types/codetracer_features/frontend.nim``.  Kept as a
  ## literal because this module must stay compilable on both the native
  ## and the JavaScript backends without dragging in the frontend types.
  DeepReviewContentId* = 36

  ## ``Content.Scratchpad``, ``Content.AgentActivity``, ``Content.Timeline``
  ## and ``Content.TerminalOutput`` — exported so tests can assert the full
  ## standard panel set survives insertion.
  ScratchpadContentId* = 17
  AgentActivityContentId* = 35
  TimelineContentId* = 19
  TerminalOutputContentId* = 24
  VcsContentId* = 41

  ## Label GoldenLayout shows for the inserted tab.  Must match
  ## ``convertComponentLabel(Content.DeepReview, 0)`` in
  ## ``frontend/utils.nim`` — ``ui/deepreview.nim`` looks the mount
  ## container up by exactly this id (``deepReviewComponent-{id}``).
  DeepReviewComponentLabel* = "deepReviewComponent-0"

  ## Where a fresh editor-area container is inserted.  ``openNewLayoutContainer``
  ## (``frontend/utils.nim``) uses index 1 of the root row for
  ## ``isEditor = true``, i.e. immediately to the right of the sidebar
  ## column.  Mirroring the constant keeps startup placement and
  ## runtime tab opening in agreement.
  EditorAreaRootIndex* = 1

  ## Width given to a freshly inserted DeepReview column.  The bundled
  ## default layout sizes its sidebar at 20% and leaves the debug column
  ## unsized, so GoldenLayout distributes the remainder.
  DeepReviewStackSize* = "50%"

proc isComponentNode(node: JsonNode): bool {.inline.} =
  node.kind == JObject and node{"type"}.getStr("") == "component"

proc componentContentId(node: JsonNode): int {.inline.} =
  if not isComponentNode(node):
    -1
  else:
    node{"componentState"}{"content"}.getInt(-1)

proc componentNameOf(node: JsonNode): string {.inline.} =
  ## Component name lives under ``componentName`` in legacy persisted
  ## layouts and under ``componentType`` in GoldenLayout v2 — accept both.
  let name = node{"componentName"}.getStr("")
  if name.len > 0: name else: node{"componentType"}.getStr("")

proc makeDeepReviewComponentNode*(): JsonNode =
  ## The GoldenLayout node for the DeepReview review surface.  ``id`` is 0
  ## because the panel is a singleton in the layout; the agentic launcher
  ## uses its own ``DeepReviewId`` for the runtime-opened instance.
  %*{
    "type": "component",
    "componentType": "genericUiComponent",
    "componentName": "genericUiComponent",
    "componentState": {
      "id": 0,
      "label": DeepReviewComponentLabel,
      "content": DeepReviewContentId
    },
    "title": "genericUiComponent"
  }

proc containsDeepReview(node: JsonNode): bool =
  ## Depth-first search for an already-placed DeepReview component.  This is
  ## what makes ``addDeepReviewSurface`` idempotent: a layout persisted from
  ## a previous DeepReview session already carries the tab and must not gain
  ## a second one.
  if node.isNil or node.kind != JObject:
    return false
  if isComponentNode(node):
    return componentContentId(node) == DeepReviewContentId
  if node.hasKey("content") and node["content"].kind == JArray:
    for child in node["content"].items:
      if containsDeepReview(child):
        return true
  false

proc stackHostsEditor(stack: JsonNode): bool =
  ## True if the stack is an editor-area stack — it hosts either the
  ## dedicated ``editorComponent`` type or a generic component whose content
  ## is ``EditorView`` (2) or ``LowLevelCode`` (18).  Persisted layouts do
  ## carry editor tabs, so preferring an existing editor stack keeps the
  ## DeepReview diff beside the user's source tabs instead of splitting the
  ## editor area in two.
  if stack.kind != JObject or stack{"type"}.getStr("") != "stack":
    return false
  if not stack.hasKey("content") or stack["content"].kind != JArray:
    return false
  for child in stack["content"].items:
    if not isComponentNode(child):
      continue
    if componentNameOf(child) == EditorComponentName:
      return true
    let contentId = componentContentId(child)
    if contentId == EditorViewContentId or contentId == LowLevelCodeContentId:
      return true
  false

proc findEditorStack(node: JsonNode): JsonNode =
  ## Depth-first search for the first editor stack.  Returns a reference
  ## into ``node`` (so callers can append to it) or ``nil``.
  if node.isNil or node.kind != JObject:
    return nil
  if stackHostsEditor(node):
    return node
  if node.hasKey("content") and node["content"].kind == JArray:
    for child in node["content"].items:
      let hit = findEditorStack(child)
      if not hit.isNil:
        return hit
  nil

proc focusStackChildWithContent(stack: JsonNode; contentId: int): bool =
  ## Point a stack's ``activeItemIndex`` at the child hosting ``contentId``.
  ##
  ## ``activeItemIndex`` is a first-class stack-config field that round-trips
  ## verbatim through GoldenLayout's resolved config (see the field notes in
  ## ``frontend/index/layout_config_repair.nim``); ``Stack`` reads it as
  ## ``_initialActiveItemIndex`` and defaults it to 0 when absent, which is
  ## why an untouched FILES/VCS stack always comes up showing FILES.
  ##
  ## Returns true when the stack was retargeted.
  if stack.isNil or stack.kind != JObject:
    return false
  if not stack.hasKey("content") or stack["content"].kind != JArray:
    return false
  for i, child in stack["content"].getElems:
    if componentContentId(child) == contentId:
      stack["activeItemIndex"] = %i
      return true
  false

proc focusReviewFileList*(layout: JsonNode): bool {.discardable.} =
  ## Make the VCS panel the *visible* tab of whichever stack hosts it.
  ##
  ## DeepReview's Modified Files panel IS the VCS panel
  ## (DeepReview-GUI.md §7: "DeepReview is built on the VCS panel ... The VCS
  ## panel sits alongside FILESYSTEM as a tab in the same GL stack").  The
  ## spec's workspace structure (§2) puts that list side by side with the
  ## review surface, §3 calls it "shared by both DeepReview modes", §5.2 says
  ## "Full Files Mode relies on the Modified Files panel for cross-file
  ## navigation", and §7 "Transition from Normal Debugging" opens the session
  ## with "1. The VCS panel populates with the changeset data".
  ##
  ## Additive placement alone does not satisfy that: in the bundled default
  ## layout VCS is the *second* tab behind FILES, so a review session came up
  ## with its only navigation surface hidden behind a file tree that
  ## ``--deepreview`` never populates (the index process loads no recording).
  ## The reviewer saw an empty explorer and no changed-file list at all.
  ##
  ## Mutates ``layout`` in place; callers that must stay pure operate on a
  ## copy.  Returns true when a VCS panel was found and focused.
  if layout.isNil or layout.kind != JObject:
    return false
  if layout{"type"}.getStr("") == "stack" and
      focusStackChildWithContent(layout, VcsContentId):
    return true
  if layout.hasKey("content") and layout["content"].kind == JArray:
    for child in layout["content"].items:
      if focusReviewFileList(child):
        return true
  if layout.hasKey("root"):
    return focusReviewFileList(layout["root"])
  false

proc makeDeepReviewStack(withSize: bool): JsonNode =
  result = %*{
    "type": "stack",
    "content": [makeDeepReviewComponentNode()]
  }
  if withSize:
    result["size"] = %DeepReviewStackSize

proc addDeepReviewSurface*(layout: JsonNode): JsonNode =
  ## Insert the DeepReview review surface into ``layout``, additively.
  ##
  ## The function is pure: ``layout`` is not mutated and the returned tree
  ## is a deep copy carrying the addition.
  ##
  ## Placement rules:
  ##   * If the layout already hosts a DeepReview component anywhere, the
  ##     copy is returned untouched (idempotent — a layout persisted from a
  ##     previous review session must not accumulate duplicate tabs).
  ##   * If an editor stack exists, the surface joins it as another tab, the
  ##     way ``openLayoutTab(..., isEditor = true)`` groups editor-area
  ##     documents.
  ##   * Otherwise a new stack is inserted into the root row at
  ##     ``EditorAreaRootIndex``, which is where ``openNewLayoutContainer``
  ##     creates the editor area when none exists — to the right of the
  ##     FILES/VCS sidebar and to the left of the debug panels.
  ##   * A non-row root (a bare column or stack) is wrapped in a row so the
  ##     "editor area is root-row index 1" invariant continues to hold.
  ##   * The stack hosting the VCS panel is retargeted at it, so the review's
  ##     Modified Files list is the tab the reviewer actually sees — see
  ##     ``focusReviewFileList``.
  ##
  ## Nothing is ever removed, so every standard panel the user's layout
  ## declares survives the transition into DeepReview mode.
  if layout.isNil:
    return layout
  result = copy(layout)
  if not result.hasKey("root") or result["root"].kind != JObject:
    return
  # Applied before the early idempotent return: re-entering DeepReview on a
  # layout persisted from a previous review session must still bring the
  # Modified Files list to the front.
  focusReviewFileList(result)
  if containsDeepReview(result["root"]):
    return

  let editorStack = findEditorStack(result["root"])
  if not editorStack.isNil:
    editorStack["content"].add(makeDeepReviewComponentNode())
    return

  let root = result["root"]
  if root{"type"}.getStr("") == "row" and root.hasKey("content") and
      root["content"].kind == JArray:
    let children = root["content"]
    var inserted = newJArray()
    let target = min(EditorAreaRootIndex, children.len)
    for i, child in children.getElems:
      if i == target:
        inserted.add(makeDeepReviewStack(withSize = true))
      inserted.add(child)
    if target >= children.len:
      inserted.add(makeDeepReviewStack(withSize = true))
    root["content"] = inserted
    return

  # Root is not a row (a bare column or a single stack).  Synthesise a row
  # so the editor area still lands at root-row index 1.
  let originalRoot = copy(root)
  result["root"] = %*{
    "type": "row",
    "size": "100%",
    "isClosable": false,
    "content": [originalRoot, makeDeepReviewStack(withSize = true)]
  }

proc layoutHasContent*(layout: JsonNode; contentId: int): bool =
  ## Convenience predicate for tests and callers that only care whether a
  ## given ``Content`` ordinal is present anywhere in the tree.
  layoutContainsContentId(layout, contentId)

proc findStackWithContent*(layout: JsonNode; contentId: int): JsonNode =
  ## Return the stack node that directly hosts ``contentId``, or ``nil``.
  ## Used by the tests to assert co-location invariants (VCS must stay in
  ## the same stack as FILES — DeepReview-GUI.md §7).
  if layout.isNil or layout.kind != JObject:
    return nil
  if layout{"type"}.getStr("") == "stack" and layout.hasKey("content") and
      layout["content"].kind == JArray:
    for child in layout["content"].items:
      if componentContentId(child) == contentId:
        return layout
  if layout.hasKey("content") and layout["content"].kind == JArray:
    for child in layout["content"].items:
      let hit = findStackWithContent(child, contentId)
      if not hit.isNil:
        return hit
  if layout.hasKey("root"):
    return findStackWithContent(layout["root"], contentId)
  nil
