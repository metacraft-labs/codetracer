## Headless regression tests for what starting a DeepReview session does to
## the GoldenLayout — issue #610 (milestone M42a) and DR-R8.
##
## The reported symptom: launching ``ct review <export.json>`` replaced
## the whole workspace with three panels (VCS, the DeepReview diff, CALLTRACE).
## FILES, STATE, SCRATCHPAD, AGENT ACTIVITY, EVENT LOG, TIMELINE and TERMINAL
## OUTPUT were gone for the entire session, and the user's own layout was
## ignored.
##
## The cause was a hard-coded three-panel GoldenLayout literal in
## ``ui_js.onStartDeepReview`` assigned straight to ``data.ui.resolvedConfig``.
## M42a made placement *additive* — the literal went away and one review
## surface was inserted into the layout the index process loaded.  DR-R8 goes
## the rest of the way: there is no review surface to insert.  DeepReview
## introduces no panel of its own (DeepReview-GUI.md §7, "There is no separate
## 'DeepReview mode' that replaces the UI"), so the only thing left for the
## layout to do is obligation 2 of Layout-System.md, "DeepReview and the
## Layout" — "Focus, not relocation": retarget the stacks that already host
## the VCS and Agent Activity panels at them.  That is
## ``deepreview_layout.focusReviewPanels``.
##
## Two layers are guarded here, because the focus rules alone would not have
## caught the bug — the old code never called any layout helper at all:
##
##   * The behavioural suite runs on both backends against the REAL bundled
##     ``src/config/default_layout.json`` (embedded with ``staticRead`` so the
##     assertions describe the layout users actually get, not a fixture that
##     can drift away from it).
##   * The source-contract suite (native only, it reads production sources)
##     asserts that the startup path is wired through that helper: the index
##     process forwards the layout, and the renderer no longer carries a
##     layout literal of its own.
##
## Spec: codetracer-specs/DeepReview/DeepReview-GUI.md (§2 view modes,
## §7 panel placement); codetracer-specs/GUI/Layout-And-Navigation/
## Layout-System.md, "DeepReview and the Layout".

import std/[algorithm, json, sequtils, unittest]

import ../../../../frontend/viewmodel/viewmodels/deepreview_layout

## The layout CodeTracer ships with, embedded at compile time.  ``staticRead``
## rather than ``readFile`` so this suite also runs on the ``nim js`` backend,
## where ``std/os`` file reads do not exist.
const bundledDefaultLayoutJson =
  staticRead("../../../../config/default_layout.json")

## Every panel the bundled default layout declares.  This list IS the
## milestone's "full standard panel set" assertion — DeepReview mode must
## keep all of them.
const StandardPanelContentIds = [
  FilesystemContentId,      # 9  — FILES
  VcsContentId,             # 41 — VCS
  StateContentId,           # 4  — STATE
  ScratchpadContentId,      # 17 — SCRATCHPAD
  CalltraceContentId,       # 6  — CALLTRACE
  AgentActivityContentId,   # 35 — AGENT ACTIVITY
  EventLogContentId,        # 8  — EVENT LOG
  TimelineContentId,        # 19 — TIMELINE
  TerminalOutputContentId,  # 24 — TERMINAL OUTPUT
]

proc bundledLayout(): JsonNode =
  parseJson(bundledDefaultLayoutJson)

proc makeComponent(content: int; label: string;
                   componentName = "genericUiComponent"): JsonNode =
  %*{
    "type": "component",
    "componentType": componentName,
    "componentName": componentName,
    "componentState": {
      "id": 0,
      "label": label,
      "content": content
    },
    "title": componentName
  }

proc makeStack(children: openArray[JsonNode]): JsonNode =
  result = %*{"type": "stack", "content": []}
  for child in children:
    result["content"].add(child)

proc makeColumn(size: string; children: openArray[JsonNode]): JsonNode =
  result = %*{"type": "column", "size": size, "content": []}
  for child in children:
    result["content"].add(child)

proc makeRow(size: string; children: openArray[JsonNode]): JsonNode =
  result = %*{"type": "row", "size": size, "content": []}
  for child in children:
    result["content"].add(child)

proc wrap(root: JsonNode): JsonNode =
  %*{
    "settings": {"constrainDragToContainer": true},
    "dimensions": {"borderWidth": 4},
    "root": root,
    "openPopouts": []
  }

proc stackContentIds(stack: JsonNode): seq[int] =
  if stack.isNil or not stack.hasKey("content"):
    return @[]
  for child in stack["content"].items:
    result.add(child{"componentState"}{"content"}.getInt(-1))

proc isValidLayoutShape(layout: JsonNode): bool =
  ## The invariant ``index/config.isValidLayoutConfig`` enforces before a
  ## layout is handed to GoldenLayout: a root with a type, and a Filesystem
  ## panel present.  The Filesystem clause exists *because* of this bug — it
  ## was added to stop the DeepReview preset leaking into the saved
  ## ``default_layout.json`` — so a DeepReview layout must now satisfy it
  ## rather than be the thing it defends against.
  if layout.isNil or layout.kind != JObject:
    return false
  let root = layout{"root"}
  if root.isNil or root.kind != JObject:
    return false
  if root{"type"}.getStr("").len == 0:
    return false
  layout.layoutHasContent(FilesystemContentId)

suite "#610 DeepReview layout — the bundled default survives a review":

  test "the whole standard panel set survives DeepReview startup":
    ## The regression this milestone is about: DeepReview used to drop seven
    ## of these nine panels.  Rewritten for DR-R8 against the entry routine
    ## that replaced ``addDeepReviewSurface`` — the subject ("a review does
    ## not eat the user's layout") outlives the function.
    let original = bundledLayout()
    let updated = focusReviewPanels(original)
    let ids = contentIdsInLayout(updated)

    for contentId in StandardPanelContentIds:
      check ids.contains(contentId)

    # Nothing was dropped and — since DR-R8 — nothing was added either.
    check ids == contentIdsInLayout(original)

  test "test_review_startup_adds_no_review_panel":
    ## DR-R8.  DeepReview-GUI.md §7: "There is no separate 'DeepReview mode'
    ## that replaces the UI.  The same GL layout is used with different data
    ## displayed in the existing panels."  Starting a review must therefore
    ## produce a layout with no review surface in it at all, while still
    ## carrying every standard panel — AGENT ACTIVITY included, because it is
    ## the review's third pillar (§2.1) and lives in the standard layout —
    ## and with the VCS panel focused.
    ##
    ## Falsifiable against the code as it stood before DR-R8: the entry
    ## routine inserted exactly one ``Content.DeepReview`` component into the
    ## editor area, and the suite this replaces asserted its presence.
    let updated = focusReviewPanels(bundledLayout())
    let ids = contentIdsInLayout(updated)

    check not ids.contains(RetiredDeepReviewContentId)
    check not updated.layoutHasContent(RetiredDeepReviewContentId)
    check updated.findStackWithContent(RetiredDeepReviewContentId).isNil

    for contentId in StandardPanelContentIds:
      check ids.contains(contentId)
    check ids.contains(AgentActivityContentId)

    # ...and the VCS panel is the tab the reviewer actually sees.
    let vcsStack = updated.findStackWithContent(VcsContentId)
    check not vcsStack.isNil
    check vcsStack{"activeItemIndex"}.getInt(-1) ==
      stackContentIds(vcsStack).find(VcsContentId)

  test "no container is created, removed or re-shaped":
    ## The complement of the test above: "adds no panel" would still be true
    ## of a routine that split the editor area or wrapped the root.  Since
    ## DR-R8 the layout's *structure* is untouched; only ``activeItemIndex``
    ## fields differ.
    let original = bundledLayout()
    let updated = focusReviewPanels(original)

    check updated["root"]["content"].len == original["root"]["content"].len
    var stripped = copy(updated)
    proc dropActiveItemIndex(node: JsonNode) =
      if node.isNil or node.kind != JObject:
        return
      if node.hasKey("activeItemIndex"):
        node.delete("activeItemIndex")
      if node.hasKey("content") and node["content"].kind == JArray:
        for child in node["content"].items:
          dropActiveItemIndex(child)
      if node.hasKey("root"):
        dropActiveItemIndex(node["root"])
    dropActiveItemIndex(stripped)
    check stripped == original

  test "placement is pure — the caller's layout is not mutated":
    let original = bundledLayout()
    let before = contentIdsInLayout(original)
    discard focusReviewPanels(original)
    check contentIdsInLayout(original) == before
    check original.findStackWithContent(VcsContentId){"activeItemIndex"}.isNil

  test "re-entering a review is idempotent":
    ## A layout persisted from a previous review session must not accumulate
    ## anything, and re-focusing must converge rather than drift.
    let once = focusReviewPanels(bundledLayout())
    let twice = focusReviewPanels(once)
    let thrice = focusReviewPanels(twice)
    check twice == once
    check thrice == once

  test "VCS stays in the same stack as FILES":
    ## DeepReview-GUI.md §7: the review file list is the VCS panel docked
    ## beside the file explorer, not a column of its own.
    let updated = focusReviewPanels(bundledLayout())
    let vcsStack = updated.findStackWithContent(VcsContentId)
    check not vcsStack.isNil
    check stackContentIds(vcsStack).contains(FilesystemContentId)
    check updated.findStackWithContent(FilesystemContentId) == vcsStack

  test "the Modified Files list is the visible tab, not hidden behind FILES":
    ## DeepReview-GUI.md §2 puts the "Modified Files" panel side by side with
    ## the review surface; §3 makes it "shared by both DeepReview modes"; §5.2
    ## says "Full Files Mode relies on the Modified Files panel for cross-file
    ## navigation"; and §7 opens a session with "1. The VCS panel populates
    ## with the changeset data".  That panel is the VCS panel (§7 again:
    ## "DeepReview is built on the VCS panel").
    ##
    ## In the bundled layout VCS is the SECOND tab of the sidebar stack, so a
    ## review that only loaded the user's layout left its only navigation
    ## surface behind an explorer that ``--deepreview`` never populates: every
    ## ``.vcs-file-item`` was in the DOM but `display: none`.
    let updated = focusReviewPanels(bundledLayout())
    let vcsStack = updated.findStackWithContent(VcsContentId)
    check not vcsStack.isNil
    let ids = stackContentIds(vcsStack)
    let vcsIndex = ids.find(VcsContentId)
    check vcsIndex >= 0
    check vcsStack{"activeItemIndex"}.getInt(-1) == vcsIndex
    # Sanity: the bundled layout really does bury it, so this assertion is
    # about the fix and not about a stack that happened to hold VCS first.
    check vcsIndex > 0
    check bundledLayout().findStackWithContent(VcsContentId){
      "activeItemIndex"}.isNil

  test "focusing the file list adds no panel and stays idempotent":
    ## The focus step must not be a second, sneaky placement rule.
    let original = bundledLayout()
    let once = focusReviewPanels(original)
    check sorted(contentIdsInLayout(once)) ==
      sorted(contentIdsInLayout(original))
    check focusReviewPanels(once) == once

  test "a sidebar that already shows VCS first is focused at index 0":
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(VcsContentId, "vCSComponent-0"),
        makeComponent(FilesystemContentId, "filesystemComponent"),
      ])]),
    ]))
    let updated = focusReviewPanels(layout)
    check updated.findStackWithContent(VcsContentId){
      "activeItemIndex"}.getInt(-1) == 0

  test "the Agent Activity panel becomes the visible tab of its stack":
    ## DR-R3 / Layout-System.md, "DeepReview and the Layout", obligation 2:
    ## the stack hosting each of the three review panels is retargeted at it,
    ## "so the changed-file list, the diff tab and the review's coverage/test
    ## summary are the visible tabs rather than being hidden behind siblings".
    ##
    ## In the bundled layout AGENT ACTIVITY is the SECOND tab of the CALLTRACE
    ## stack, so DeepReview's third pillar came up hidden behind the call
    ## trace even once it had coverage data in it.
    let updated = focusReviewPanels(bundledLayout())
    let activityStack = updated.findStackWithContent(AgentActivityContentId)
    check not activityStack.isNil
    let ids = stackContentIds(activityStack)
    let activityIndex = ids.find(AgentActivityContentId)
    check activityIndex >= 0
    check activityStack{"activeItemIndex"}.getInt(-1) == activityIndex
    # Sanity: the bundled layout really does bury it, so this asserts the fix
    # rather than a stack that happened to hold AGENT ACTIVITY first.
    check activityIndex > 0
    check bundledLayout().findStackWithContent(AgentActivityContentId){
      "activeItemIndex"}.isNil

  test "focusing the activity pane adds no panel and moves none":
    ## "No panel is moved between stacks and no stack is created for one."
    let original = bundledLayout()
    let once = focusReviewPanels(original)
    check sorted(contentIdsInLayout(once)) ==
      sorted(contentIdsInLayout(original))
    # The Agent Activity panel is still in the stack the user's layout put it
    # in, with the same siblings in the same order.
    check stackContentIds(once.findStackWithContent(AgentActivityContentId)) ==
      stackContentIds(original.findStackWithContent(AgentActivityContentId))
    check focusReviewPanels(once) == once

  test "test_a_layout_with_no_agent_activity_panel_gets_the_pillar_back":
    ## Layout-System.md, "DeepReview and the Layout", obligation 4: "**Absent
    ## panels are materialised, not substituted** — if the user's layout has
    ## no VCS or Agent Activity panel at all, the review may add one ... It may
    ## not rebuild the layout around it."
    ##
    ## This test asserted the OPPOSITE until RV-2's follow-up ("a layout with
    ## no Agent Activity panel is left alone"), on the reasoning that DR-R3 was
    ## scoped to focus.  That was defensible while the review opened the
    ## DEBUGGING layout, which always declares the panel: the absent case was
    ## rare.  RV-2 moved the dataset launch onto `default_edit_layout.json`,
    ## and edit mode's save-side sanitiser DELETES `Content.AgentActivity`
    ## (`index/config.editModeHiddenContentIds`) — so for every user who has
    ## ever opened a folder in edit mode, the file a review reads has no Agent
    ## Activity panel in it at all, and "left alone" means the review comes up
    ## missing one of the three surfaces it is assembled from.
    ##
    ## Focusing cannot fix that: `focusReviewActivityPane` can only retarget a
    ## stack at a panel that is already there.  The pillar has to be put back.
    let layout = wrap(makeRow("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent"),
                 makeComponent(VcsContentId, "vCSComponent-0")]),
      makeStack([
        makeComponent(EditorViewContentId, "main.rs", EditorComponentName),
        makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0"),
      ]),
    ]))
    check not layoutHasContent(layout, AgentActivityContentId)

    let updated = focusReviewPanels(layout)
    check layoutHasContent(updated, AgentActivityContentId)

    # ...and it is the visible tab of wherever it landed, which is the whole
    # point of putting it back (obligation 2).
    let activityStack = updated.findStackWithContent(AgentActivityContentId)
    check not activityStack.isNil
    check activityStack{"activeItemIndex"}.getInt(-1) ==
      stackContentIds(activityStack).find(AgentActivityContentId)

    # Nothing the user arranged was displaced to make room (obligation 1) and
    # no stack the review does not own had an activeItemIndex invented for it.
    for contentId in contentIdsInLayout(layout):
      check contentIdsInLayout(updated).contains(contentId)
    check updated.findStackWithContent(EditorViewContentId){
      "activeItemIndex"}.isNil

  test "test_the_materialised_pillar_does_not_hide_the_vcs_panel":
    ## The trap in obligation 4's "add one as a tab in an existing stack".
    ##
    ## The saved edit layout is FILES + VCS in ONE stack and nothing else (it
    ## is the bundled default with every panel edit mode hides removed).  Drop
    ## AGENT ACTIVITY into that stack and the two obligations collide:
    ## `focusReviewActivityPane` runs after `focusReviewFileList`, so the last
    ## write to `activeItemIndex` wins and the VCS panel — which
    ## DeepReview-GUI.md §2 requires to be "the visible tab of whichever stack
    ## hosts it when a review starts" — ends up hidden behind the pillar that
    ## was just added.  Two panels in one stack cannot both be visible.
    ##
    ## So the materialised pillar gets a slot of its own beside the user's
    ## arrangement rather than inside the stack that hosts a sibling pillar.
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(FilesystemContentId, "filesystemComponent"),
        makeComponent(VcsContentId, "vCSComponent-0"),
      ])]),
    ]))
    let updated = focusReviewPanels(layout)

    let vcsStack = updated.findStackWithContent(VcsContentId)
    let activityStack = updated.findStackWithContent(AgentActivityContentId)
    check not vcsStack.isNil
    check not activityStack.isNil
    # Different stacks — the only arrangement in which both can be visible.
    check activityStack != vcsStack
    check not stackContentIds(vcsStack).contains(AgentActivityContentId)
    # Both are the visible tab of their own stack.
    check vcsStack{"activeItemIndex"}.getInt(-1) ==
      stackContentIds(vcsStack).find(VcsContentId)
    check activityStack{"activeItemIndex"}.getInt(-1) ==
      stackContentIds(activityStack).find(AgentActivityContentId)
    # FILES keeps its stack, its stack-mate and its order.
    check stackContentIds(vcsStack) == @[FilesystemContentId, VcsContentId]

  test "test_materialising_the_pillar_is_idempotent":
    ## Obligation 3: "re-entering a review on a layout persisted from an
    ## earlier review session must not accumulate duplicate tabs".  A second
    ## review over the same layout must find the pillar already there and add
    ## nothing.
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(FilesystemContentId, "filesystemComponent"),
        makeComponent(VcsContentId, "vCSComponent-0"),
      ])]),
    ]))
    let once = focusReviewPanels(layout)
    let twice = focusReviewPanels(once)
    check twice == once
    var activityCount = 0
    for contentId in contentIdsInLayout(twice):
      if contentId == AgentActivityContentId:
        activityCount += 1
    check activityCount == 1

  test "test_materialisation_leaves_a_loadable_layout":
    ## The result is handed straight to GoldenLayout, so it must satisfy the
    ## same invariants a saved layout does: a typed root, the Filesystem panel
    ## `index/config.isValidLayoutConfig` insists on, and stacks whose
    ## `activeItemIndex` is in range (`Stack.init` throws otherwise).
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(FilesystemContentId, "filesystemComponent"),
        makeComponent(VcsContentId, "vCSComponent-0"),
      ])]),
    ]))
    let updated = focusReviewPanels(layout)
    check isValidLayoutShape(updated)

    proc everyActiveItemIndexInRange(node: JsonNode): bool =
      if node.isNil or node.kind != JObject:
        return true
      if node{"type"}.getStr("") == "stack" and node.hasKey("activeItemIndex"):
        let count =
          if node.hasKey("content") and node["content"].kind == JArray:
            node["content"].len
          else:
            0
        let index = node["activeItemIndex"].getInt(-1)
        if index < 0 or index >= count:
          return false
      if node.hasKey("content") and node["content"].kind == JArray:
        for child in node["content"].items:
          if not everyActiveItemIndexInRange(child):
            return false
      if node.hasKey("root"):
        return everyActiveItemIndexInRange(node["root"])
      true
    check everyActiveItemIndexInRange(updated)

    # The materialised component carries everything `createUIComponents` and
    # GoldenLayout's `bindComponent` read off a node: a registered component
    # type, and a `componentState` with the content ordinal and a label.
    let activityStack = updated.findStackWithContent(AgentActivityContentId)
    check not activityStack.isNil
    var pane: JsonNode = nil
    if not activityStack.isNil:
      for child in activityStack{"content"}.getElems:
        if child{"componentState"}{"content"}.getInt(-1) == AgentActivityContentId:
          pane = child
    check not pane.isNil
    check pane{"type"}.getStr("") == "component"
    check pane{"componentType"}.getStr("") == "genericUiComponent"
    check pane{"componentState"}{"label"}.getStr("").len > 0

  test "test_a_rootless_stack_layout_still_gets_the_pillar":
    ## A user can close panes until the root itself is a single stack.  The
    ## pillar cannot go inside it — that is the VCS collision again — so the
    ## root is wrapped in a row, which is the same fallback
    ## `visual_replay_layout.wrapWithVisualReplayColumn` takes and is not
    ## "rebuilding the layout around it": every panel keeps its stack, its
    ## stack-mates and their order.
    let layout = wrap(makeStack([
      makeComponent(FilesystemContentId, "filesystemComponent"),
      makeComponent(VcsContentId, "vCSComponent-0"),
    ]))
    let updated = focusReviewPanels(layout)
    check layoutHasContent(updated, AgentActivityContentId)
    check updated["root"]["type"].getStr("") == "row"
    let vcsStack = updated.findStackWithContent(VcsContentId)
    check stackContentIds(vcsStack) == @[FilesystemContentId, VcsContentId]
    check updated.findStackWithContent(AgentActivityContentId) != vcsStack

  test "test_a_column_root_gets_the_pillar_as_a_strip_below":
    ## A root can just as well be a column — GoldenLayout's root is whatever
    ## the user's last drag left behind.  Adding a *column* to a column would
    ## nest a container for no reason, so the pillar joins it as a stack: a
    ## strip under the user's panes, which is the shape the bundled layout
    ## already uses for its EVENT LOG stack.
    let layout = wrap(makeColumn("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent"),
                 makeComponent(VcsContentId, "vCSComponent-0")]),
    ]))
    let updated = focusReviewPanels(layout)
    check updated["root"]["type"].getStr("") == "column"
    check updated["root"]["content"].len == 2
    check layoutHasContent(updated, AgentActivityContentId)
    let activityStack = updated.findStackWithContent(AgentActivityContentId)
    check activityStack != updated.findStackWithContent(VcsContentId)
    check stackContentIds(activityStack) == @[AgentActivityContentId]
    check isValidLayoutShape(updated)

  test "test_a_docked_review_section_pane_does_not_block_the_pillar":
    ## `Content.AgentActivityDeepReview` (39) is the review's coverage/test
    ## summary, which §2.1 renders INSIDE the Agent Activity panel — "It is not
    ## a separate panel and does not get its own layout slot".  A layout
    ## persisted by an older build may still host it as a pane of its own, and
    ## that pane is not the panel: `focusReviewActivityPane` looks for 35, so a
    ## layout carrying only 39 is still a layout with no third pillar.
    let layout = wrap(makeRow("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent"),
                 makeComponent(VcsContentId, "vCSComponent-0")]),
      makeStack([makeComponent(AgentActivityDeepReviewContentId, "review")]),
    ]))
    let updated = focusReviewPanels(layout)
    check layoutHasContent(updated, AgentActivityContentId)
    check layoutHasContent(updated, AgentActivityDeepReviewContentId)

  test "a layout without a VCS panel is left alone":
    ## ``focusReviewFileList`` must not invent an activeItemIndex for stacks
    ## it does not own — that would silently re-target the user's editor.
    ##
    ## The pillar IS materialised into this layout (it declares no Agent
    ## Activity panel either), so the assertion is specifically that the
    ## stacks the user arranged are untouched by it: only the stack the
    ## review added carries an ``activeItemIndex``.
    let layout = wrap(makeRow("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent")]),
      makeStack([
        makeComponent(EditorViewContentId, "main.rs", EditorComponentName),
        makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0"),
      ]),
    ]))
    let updated = focusReviewPanels(layout)
    for stack in [updated.findStackWithContent(FilesystemContentId),
                  updated.findStackWithContent(EditorViewContentId)]:
      check stack{"activeItemIndex"}.isNil
    check updated.findStackWithContent(AgentActivityContentId){
      "activeItemIndex"}.getInt(-1) == 0

  test "an existing editor area is left exactly as the user arranged it":
    ## Before DR-R8 the review surface joined the user's editor stack as an
    ## extra tab.  It no longer exists, so the editor area a review starts on
    ## is byte-for-byte the one the user saved — the review's own documents
    ## arrive later, as ordinary editor tabs opened by
    ## ``review_entry.openFirstReviewFile``.
    ##
    ## This layout declares no Agent Activity panel, so the review does add a
    ## container for the materialised pillar (obligation 4).  The assertion
    ## that used to read `root.content.len == 2` is therefore restated as what
    ## it was really guarding — the user's own containers survive unchanged,
    ## in place, in order — plus the new requirement that exactly ONE was
    ## added and that it holds nothing but the pillar.  Weaker would be to
    ## drop the count; this is the count plus their contents.
    let editorStack = makeStack([
      makeComponent(EditorViewContentId, "main.rs", EditorComponentName),
      makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0"),
    ])
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(FilesystemContentId, "filesystemComponent"),
        makeComponent(VcsContentId, "vCSComponent-0"),
      ])]),
      makeColumn("80%", [editorStack]),
    ]))

    let updated = focusReviewPanels(layout)
    # The user's two columns, still the first two children of the root and
    # still holding exactly what they held.  The editor column is compared
    # verbatim; the sidebar column differs only by the `activeItemIndex` the
    # review writes onto the VCS stack, so it is compared by contents.
    check updated["root"]["content"].len == 3
    check contentIdsInLayout(%*{"root": updated["root"]["content"][0]}) ==
      @[FilesystemContentId, VcsContentId]
    check updated["root"]["content"][1] == layout["root"]["content"][1]
    # The third is the review's, and holds the pillar and nothing else.
    check contentIdsInLayout(%*{"root": updated["root"]["content"][2]}) ==
      @[AgentActivityContentId]
    check stackContentIds(updated.findStackWithContent(EditorViewContentId)) ==
      @[EditorViewContentId, LowLevelCodeContentId]
    check not updated.layoutHasContent(RetiredDeepReviewContentId)

  test "the result still satisfies the saved-layout invariant":
    ## `isValidLayoutConfig` rejects a layout without a Filesystem panel, so
    ## a DeepReview session can no longer produce a config that the next
    ## ordinary launch would have to throw away.  Rewritten for DR-R8 against
    ## the entry routine; the invariant it names outlives the function.
    let updated = focusReviewPanels(bundledLayout())
    check isValidLayoutShape(updated)

  test "a nil or rootless layout is handled without raising":
    check focusReviewPanels(nil).isNil
    let rootless = %*{"settings": {}, "openPopouts": []}
    check focusReviewPanels(rootless) == rootless

when not defined(js):
  ## Source contract.  The behavioural suite above describes the focus
  ## helper; these tests describe the WIRING, which is what actually broke:
  ## the old startup path called no layout helper at all, it pasted a
  ## layout literal over `data.ui.resolvedConfig`.  Reading the production
  ## sources is the only way to assert that headlessly — `ui_js.nim` needs
  ## Electron, GoldenLayout and the DOM to run.
  import std/[os, strutils]

  const
    UiJsPath = "src/frontend/ui_js.nim"
    StartupPath = "src/frontend/index/startup.nim"
    LayoutHelperPath =
      "src/frontend/viewmodel/viewmodels/deepreview_layout.nim"
    DeletedPanelPath = "src/frontend/ui/deepreview.nim"
    DeletedPanelViewPath =
      "src/frontend/viewmodel/views/isonim_deepreview_view.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  proc deepReviewStartupBody(): string =
    ## The body of `onStartDeepReview`, up to the next top-level `proc`.
    ##
    ## A missing anchor raises with the anchor in the message rather than
    ## slicing at -1 and dying with a bare `IndexDefect` — same reasoning as
    ## `review_layout_test.sectionBetween`: the anchor is a production
    ## spelling, and renaming it is the routine change that breaks this.
    let body = source(UiJsPath)
    let start = body.find("proc onStartDeepReview*")
    if start < 0:
      raise newException(ValueError,
        "source-contract anchor not found in " & UiJsPath &
        ": \"proc onStartDeepReview*\" — renamed, moved or removed")
    let rest = body[start .. ^1]
    let stop = rest.find("\nproc ", 1)
    if stop < 0: rest else: rest[0 ..< stop]

  suite "#610 DeepReview layout (source contract)":

    test "the index process forwards the loaded layout to the renderer":
      ## Without this the renderer has no layout to focus.
      ##
      ## RV-2 changed *which* layout is loaded — the dataset launch loads the
      ## editor layout (`reviewLayout`) rather than forwarding the debugging
      ## layout `init` was handed — but not that one is loaded and forwarded,
      ## which is what this test is for.  Which loader produces it, and that
      ## the other two launch methods keep the debugging layout, is
      ## `review_layout_test.nim`'s subject.
      let body = source(StartupPath)
      let start = body.find("CODETRACER::start-deepreview")
      check start >= 0
      let payload = body[start ..< min(start + 400, body.len)]
      check payload.contains("layout: reviewLayout")

    test "the renderer derives the review layout from the loaded one":
      let body = deepReviewStartupBody()
      check body.contains("focusReviewPanels(")
      check body.contains("response.layout")
      check body.contains("jsonNodeToResolvedConfig(")

    test "the renderer no longer hard-codes a DeepReview layout preset":
      ## The defect itself: a three-panel GoldenLayout literal assigned
      ## straight to `data.ui.resolvedConfig`, which is why every other panel
      ## disappeared for the session.
      let body = deepReviewStartupBody()
      check not body.contains("standardLayoutJson")
      check not body.contains("JSON.parse(standardLayoutJson)")
      # The only remaining literal is the emergency fallback used when the
      # index sent no usable layout, and it must not name the panels the
      # preset used to pin down.
      check not body.contains("\"label\": \"deepReviewComponent-0\"")
      check not body.contains("\"label\": \"calltraceComponent-0\"")

    test "test_review_startup_inserts_no_review_surface_component":
      ## DR-R8's source half.  "Adds no review panel" must be true of the
      ## helper's *code*, not only of the bundled layout it was measured on:
      ## the helper builds no review surface, and the startup path opens none.
      ##
      ## RESTATED, not relaxed.  DR-R8 spelled this "builds no component node
      ## at all", which was an exact proxy while the helper only ever focused.
      ## Layout-System.md obligation 4 now requires it to build exactly ONE —
      ## the Agent Activity pillar, when the layout being reviewed has none —
      ## so the proxy is replaced by the property it stood for: every
      ## component this module constructs is a STANDARD panel, never a surface
      ## of DeepReview's own.  Counting the node literals is what keeps that
      ## from drifting: a second one cannot appear unnoticed.
      let helper = source(LayoutHelperPath)
      check not helper.contains("makeDeepReviewComponentNode")
      # The name may still appear in prose explaining what was removed; what
      # must not exist is a definition or a call.
      check not helper.contains("proc addDeepReviewSurface")
      check not helper.contains("addDeepReviewSurface(")
      check helper.count("\"type\": \"component\"") == 1
      check helper.contains("\"content\": AgentActivityContentId")
      check not helper.contains("\"content\": RetiredDeepReviewContentId")
      check helper.contains("proc focusReviewPanels*")
      # ...and the one node it builds is only ever reached from the
      # materialisation, which is itself gated on the pillar being absent.
      check helper.count("makeAgentActivityPane()") == 2
      check helper.contains("if layoutContainsContentId(layout, AgentActivityContentId):")

      let body = deepReviewStartupBody()
      check not body.contains("addDeepReviewSurface")
      check not body.contains("Content.DeepReview")

    test "the standalone DeepReview panel and its view are gone":
      ## The deletion itself, asserted where a stale checkout would notice:
      ## both modules must be absent, and no production module may import
      ## them.  `fileExists` rather than `readFile` because absence is the
      ## assertion here.
      check not fileExists(DeletedPanelPath)
      check not fileExists(DeletedPanelViewPath)
      for path in [UiJsPath, "src/frontend/ui/vcs.nim",
                   "src/frontend/ui/layout.nim",
                   "src/frontend/ui/agentic_session_launcher.nim",
                   "src/frontend/utils.nim"]:
        let body = source(path)
        check not body.contains("isonim_deepreview_view")
        check not body.contains("Content.DeepReview")

    test "Content.AgentActivityDeepReview — the OTHER DeepReview — stays":
      ## The trap DR-R8 names explicitly: `Content.AgentActivityDeepReview` is
      ## a different id from the deleted `Content.DeepReview`, and it is the
      ## review's third pillar (DeepReview-GUI.md §2.1).  Deleting it would
      ## delete a required surface.
      let contents = source(
        "src/common/common_types/codetracer_features/frontend.nim")
      check contents.contains("AgentActivityDeepReview = 39")
      check not contents.contains("DeepReview = 36")

      let config = source("src/frontend/index/config.nim")
      check config.contains("ord(Content.AgentActivityDeepReview)")
      check not config.contains("ord(Content.DeepReview)")

      let layout = source("src/frontend/ui/layout.nim")
      check layout.contains("Content.AgentActivityDeepReview")

      let utils = source("src/frontend/utils.nim")
      check utils.contains(
        "of Content.AgentActivityDeepReview: " &
        "data.makeAgentActivityDeepReviewComponent(id)")
