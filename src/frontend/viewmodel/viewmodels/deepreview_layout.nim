## GoldenLayout focus preset for a DeepReview session.
##
## DeepReview (``ct review <export.json>``) used to *replace* the
## user's GoldenLayout with a hand-rolled three-panel preset (VCS +
## DeepReview + CALLTRACE).  Everything else — FILES, STATE, SCRATCHPAD,
## AGENT ACTIVITY, EVENT LOG, TIMELINE, TERMINAL OUTPUT — simply vanished
## for the whole session, and the preset then had to be defended against
## with workarounds elsewhere (the renderer refuses to persist a layout
## while ``deepReviewActive``; the index-side layout loader rejects any
## saved layout that lost its Filesystem panel).  See issue #610.
##
## What replaced it is *nothing at all*: a review adds no component to the
## layout.  DeepReview-GUI.md §7 — "There is no separate 'DeepReview mode'
## that replaces the UI.  The same GL layout is used with different data
## displayed in the existing panels" — and the review's three surfaces (the
## Editor, the VCS panel and the Agent Activity panel) all exist
## independently of it.  Until DR-R8 this module also *inserted* a
## standalone ``Content.DeepReview`` surface into the editor area; that
## panel and its insertion are gone.
##
## What remains is obligation 2 of
## ``codetracer-specs/GUI/Layout-And-Navigation/Layout-System.md``,
## "DeepReview and the Layout" — "Focus, not relocation": the stack hosting
## each review panel is retargeted at it so the changed-file list and the
## review's coverage/test summary are the visible tabs rather than being
## hidden behind siblings.  No panel is added, moved or removed.
##
## All helpers operate on parsed ``JsonNode`` trees, so the rules are
## testable headlessly — no Electron, no GoldenLayout, no DOM.  The bridge
## to the live JS config object is ``ui_js.resolvedConfigToJsonNode`` /
## ``jsonNodeToResolvedConfig``.
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
  ## The ordinal a *retired* ``Content.DeepReview`` had in
  ## ``common/common_types/codetracer_features/frontend.nim``.  The enum
  ## member is gone (DR-R8) and nothing produces this id any more; the
  ## constant survives only so the regression tests can assert that a
  ## review adds no component carrying it, and so a layout persisted by an
  ## older build is recognisably stale rather than mysterious.
  RetiredDeepReviewContentId* = 36

  ## ``Content.Scratchpad``, ``Content.AgentActivity``, ``Content.Timeline``
  ## and ``Content.TerminalOutput`` — exported so tests can assert the full
  ## standard panel set survives a review.
  ScratchpadContentId* = 17
  AgentActivityContentId* = 35
  TimelineContentId* = 19
  TerminalOutputContentId* = 24
  VcsContentId* = 41

proc isComponentNode(node: JsonNode): bool {.inline.} =
  node.kind == JObject and node{"type"}.getStr("") == "component"

proc componentContentId(node: JsonNode): int {.inline.} =
  if not isComponentNode(node):
    -1
  else:
    node{"componentState"}{"content"}.getInt(-1)

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

proc focusReviewActivityPane*(layout: JsonNode): bool {.discardable.} =
  ## Make the Agent Activity panel the *visible* tab of whichever stack hosts
  ## it — DeepReview's third pillar.
  ##
  ## `codetracer-specs/GUI/Layout-And-Navigation/Layout-System.md`, "DeepReview
  ## and the Layout", obligation 2: "the three review panels stay wherever the
  ## user put them, but the stack hosting each is retargeted at it so the
  ## changed-file list, the diff tab and the review's coverage/test summary are
  ## the visible tabs rather than being hidden behind siblings.  No panel is
  ## moved between stacks and no stack is created for one."
  ##
  ## This is the coverage/test summary half.  In the bundled default layout the
  ## Agent Activity panel is the second tab of the CALLTRACE stack, so a review
  ## came up with its coverage summary hidden behind the call trace.
  ##
  ## Only the *focus* is changed: no panel is added, moved or removed, and a
  ## layout with no Agent Activity panel is left alone (obligation 4's
  ## materialisation case is deliberately not taken here — DR-R3 is scoped to
  ## focus).  Mutates ``layout`` in place; returns true when a panel was found
  ## and focused.
  if layout.isNil or layout.kind != JObject:
    return false
  if layout{"type"}.getStr("") == "stack" and
      focusStackChildWithContent(layout, AgentActivityContentId):
    return true
  if layout.hasKey("content") and layout["content"].kind == JArray:
    for child in layout["content"].items:
      if focusReviewActivityPane(child):
        return true
  if layout.hasKey("root"):
    return focusReviewActivityPane(layout["root"])
  false

proc focusReviewPanels*(layout: JsonNode): JsonNode =
  ## The whole of what starting a review does to a layout: bring the VCS
  ## panel and the Agent Activity panel to the front of the stacks that
  ## already host them.  Nothing is added, moved or removed.
  ##
  ## This is the "focus-and-populate preset" the reconciled
  ## ``Layout-System.md`` permits — "a preset that brings the three review
  ## panels (Editor, VCS, Agent Activity) to the front.  What there is not,
  ## and must never be, is a preset that installs a bespoke review surface
  ## or substitutes a reduced layout."  The Editor half is not a layout
  ## operation at all: the review opens its first modified file as an
  ## ordinary editor document (``review_entry.openFirstReviewFile``), which
  ## GoldenLayout focuses the way it focuses any newly opened tab.
  ##
  ## Pure: ``layout`` is not mutated and the returned tree is a deep copy
  ## carrying the retargeting.  Idempotent by construction — writing the
  ## same ``activeItemIndex`` twice is the same layout.
  ##
  ## Until DR-R8 this routine was ``addDeepReviewSurface`` and *also*
  ## inserted a standalone ``Content.DeepReview`` component into the editor
  ## area.  That panel is deleted (DeepReview-GUI.md §7: "There is no
  ## separate 'DeepReview mode' that replaces the UI"), so there is nothing
  ## left to place.
  if layout.isNil:
    return layout
  result = copy(layout)
  if not result.hasKey("root") or result["root"].kind != JObject:
    return
  focusReviewFileList(result)
  focusReviewActivityPane(result)

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
