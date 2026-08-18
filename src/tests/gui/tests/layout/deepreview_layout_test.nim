## Headless regression tests for DeepReview layout placement — issue #610
## (milestone M42a).
##
## The reported symptom: launching ``ct --deepreview <export.json>`` replaced
## the whole workspace with three panels (VCS, the DeepReview diff, CALLTRACE).
## FILES, STATE, SCRATCHPAD, AGENT ACTIVITY, EVENT LOG, TIMELINE and TERMINAL
## OUTPUT were gone for the entire session, and the user's own layout was
## ignored.
##
## The cause was a hard-coded three-panel GoldenLayout literal in
## ``ui_js.onStartDeepReview`` assigned straight to ``data.ui.resolvedConfig``.
## The fix makes placement additive, exactly like the visual-replay tabs:
## ``viewmodel/viewmodels/deepreview_layout.addDeepReviewSurface`` inserts ONE
## component into the layout the index process loaded and removes nothing.
##
## Two layers are guarded here, because the placement rules alone would not
## have caught the bug — the old code never called any placement helper at all:
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
## §7 panel placement)

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

suite "#610 DeepReview layout — additive placement on the bundled default":

  test "the whole standard panel set survives DeepReview startup":
    ## The regression this milestone is about: DeepReview used to drop seven
    ## of these nine panels.
    let original = bundledLayout()
    let updated = addDeepReviewSurface(original)
    let ids = contentIdsInLayout(updated)

    for contentId in StandardPanelContentIds:
      check ids.contains(contentId)
    check ids.contains(DeepReviewContentId)

    # Nothing was dropped and nothing but the review surface was added.
    let originalIds = contentIdsInLayout(original)
    check ids.len == originalIds.len + 1

  test "placement is pure — the caller's layout is not mutated":
    let original = bundledLayout()
    let before = contentIdsInLayout(original)
    discard addDeepReviewSurface(original)
    check contentIdsInLayout(original) == before
    check not original.layoutHasContent(DeepReviewContentId)

  test "exactly one review surface is added, in the editor area":
    let updated = addDeepReviewSurface(bundledLayout())
    check contentIdsInLayout(updated).count(DeepReviewContentId) == 1

    # The bundled layout has no editor stack, so the surface becomes a new
    # stack at root-row index 1 — where `openNewLayoutContainer(..., isEditor
    # = true)` creates the editor area, i.e. right of the FILES/VCS sidebar.
    let rootChildren = updated["root"]["content"]
    check rootChildren.len == 3
    let editorArea = rootChildren[EditorAreaRootIndex]
    check editorArea{"type"}.getStr("") == "stack"
    check stackContentIds(editorArea) == @[DeepReviewContentId]

    # The sidebar stays first, the debug column stays last.
    check contentIdsInLayout(%*{"root": rootChildren[0]}) ==
      @[FilesystemContentId, VcsContentId]

  test "insertion is idempotent":
    ## A layout persisted from a previous review session already carries the
    ## tab; re-running placement must not accumulate duplicates.
    let once = addDeepReviewSurface(bundledLayout())
    let twice = addDeepReviewSurface(once)
    let thrice = addDeepReviewSurface(twice)
    check contentIdsInLayout(twice).count(DeepReviewContentId) == 1
    check contentIdsInLayout(thrice) == contentIdsInLayout(once)
    check thrice == once

  test "VCS stays in the same stack as FILES":
    ## DeepReview-GUI.md §7: the review file list is the VCS panel docked
    ## beside the file explorer, not a column of its own.
    let updated = addDeepReviewSurface(bundledLayout())
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
    ## In the bundled layout VCS is the SECOND tab of the sidebar stack, so
    ## additive placement on its own left the review's only navigation surface
    ## behind an explorer that ``--deepreview`` never populates: every
    ## ``.vcs-file-item`` was in the DOM but `display: none`.
    let updated = addDeepReviewSurface(bundledLayout())
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
    let once = addDeepReviewSurface(original)
    # Same panel multiset, plus the one review surface (document order
    # differs — the surface is inserted at the editor-area index).
    check sorted(contentIdsInLayout(once)) ==
      sorted(contentIdsInLayout(original) & @[DeepReviewContentId])
    check addDeepReviewSurface(once) == once

  test "a sidebar that already shows VCS first is focused at index 0":
    let layout = wrap(makeRow("100%", [
      makeColumn("20%", [makeStack([
        makeComponent(VcsContentId, "vCSComponent-0"),
        makeComponent(FilesystemContentId, "filesystemComponent"),
      ])]),
    ]))
    let updated = addDeepReviewSurface(layout)
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
    let updated = addDeepReviewSurface(bundledLayout())
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
    let once = addDeepReviewSurface(original)
    check sorted(contentIdsInLayout(once)) ==
      sorted(contentIdsInLayout(original) & @[DeepReviewContentId])
    # The Agent Activity panel is still in the stack the user's layout put it
    # in, with the same siblings in the same order.
    check stackContentIds(once.findStackWithContent(AgentActivityContentId)) ==
      stackContentIds(original.findStackWithContent(AgentActivityContentId))
    check addDeepReviewSurface(once) == once

  test "a layout with no Agent Activity panel is left alone":
    ## Focus only: DR-R3 does not materialise a missing pane, and must not
    ## invent an activeItemIndex for a stack it does not own.
    let layout = wrap(makeRow("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent"),
                 makeComponent(VcsContentId, "vCSComponent-0")]),
      makeStack([
        makeComponent(EditorViewContentId, "main.rs", EditorComponentName),
        makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0"),
      ]),
    ]))
    let updated = addDeepReviewSurface(layout)
    check updated.findStackWithContent(AgentActivityContentId).isNil
    check not layoutHasContent(updated, AgentActivityContentId)
    check updated.findStackWithContent(EditorViewContentId){
      "activeItemIndex"}.isNil

  test "a layout without a VCS panel is left alone":
    ## ``focusReviewFileList`` must not invent an activeItemIndex for stacks
    ## it does not own — that would silently re-target the user's editor.
    let layout = wrap(makeRow("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent")]),
      makeStack([
        makeComponent(EditorViewContentId, "main.rs", EditorComponentName),
        makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0"),
      ]),
    ]))
    let updated = addDeepReviewSurface(layout)
    for stack in [updated.findStackWithContent(FilesystemContentId),
                  updated.findStackWithContent(EditorViewContentId)]:
      check stack{"activeItemIndex"}.isNil

  test "the result still satisfies the saved-layout invariant":
    ## `isValidLayoutConfig` rejects a layout without a Filesystem panel, so
    ## a DeepReview session can no longer produce a config that the next
    ## ordinary launch would have to throw away.
    let updated = addDeepReviewSurface(bundledLayout())
    check isValidLayoutShape(updated)

suite "#610 DeepReview layout — placement rules on other layouts":

  test "an existing editor stack hosts the review surface":
    ## When the user's layout already has an editor area, the diff joins it
    ## as another tab instead of splitting the editor area in two — the same
    ## grouping `openLayoutTab(..., isEditor = true)` performs at runtime.
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

    let updated = addDeepReviewSurface(layout)
    check contentIdsInLayout(updated).count(DeepReviewContentId) == 1
    let hostStack = updated.findStackWithContent(DeepReviewContentId)
    check stackContentIds(hostStack) == @[
      EditorViewContentId, LowLevelCodeContentId, DeepReviewContentId]
    # No extra container was introduced.
    check updated["root"]["content"].len == 2

  test "a non-row root is wrapped so the editor area still exists":
    let layout = wrap(makeColumn("100%", [
      makeStack([makeComponent(FilesystemContentId, "filesystemComponent")]),
    ]))
    let updated = addDeepReviewSurface(layout)
    check updated["root"]{"type"}.getStr("") == "row"
    check updated["root"]["content"].len == 2
    check contentIdsInLayout(updated) ==
      @[FilesystemContentId, DeepReviewContentId]

  test "an empty root row still receives the surface":
    let layout = wrap(makeRow("100%", []))
    let updated = addDeepReviewSurface(layout)
    check contentIdsInLayout(updated) == @[DeepReviewContentId]

  test "a nil or rootless layout is handled without raising":
    check addDeepReviewSurface(nil).isNil
    let rootless = %*{"settings": {}, "openPopouts": []}
    check addDeepReviewSurface(rootless) == rootless

when not defined(js):
  ## Source contract.  The behavioural suite above describes the placement
  ## helper; these tests describe the WIRING, which is what actually broke:
  ## the old startup path called no placement helper at all, it pasted a
  ## layout literal over `data.ui.resolvedConfig`.  Reading the production
  ## sources is the only way to assert that headlessly — `ui_js.nim` needs
  ## Electron, GoldenLayout and the DOM to run.
  import std/strutils

  const
    UiJsPath = "src/frontend/ui_js.nim"
    StartupPath = "src/frontend/index/startup.nim"
    DeepReviewViewPath =
      "src/frontend/viewmodel/views/isonim_deepreview_view.nim"

  proc source(path: string): string =
    ## `readFile` raising here is the right failure: it means the production
    ## file this contract describes was moved or deleted.
    readFile(path)

  proc deepReviewStartupBody(): string =
    ## The body of `onStartDeepReview`, up to the next top-level `proc`.
    let body = source(UiJsPath)
    let start = body.find("proc onStartDeepReview*")
    check start >= 0
    let rest = body[start .. ^1]
    let stop = rest.find("\nproc ", 1)
    if stop < 0: rest else: rest[0 ..< stop]

  suite "#610 DeepReview layout (source contract)":

    test "the index process forwards the loaded layout to the renderer":
      ## Without this the renderer has nothing to add the review surface to.
      let body = source(StartupPath)
      let start = body.find("CODETRACER::start-deepreview")
      check start >= 0
      let payload = body[start ..< min(start + 400, body.len)]
      check payload.contains("layout: layout")

    test "the renderer derives the DeepReview layout additively":
      let body = deepReviewStartupBody()
      check body.contains("addDeepReviewSurface(")
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

    test "the view mode toggle is not suppressed for GL-embedded panels":
      ## `glEmbedded` is true for the whole `--deepreview` session, so the
      ## `if not vm.glEmbedded.val:` guard made Full Files mode unreachable.
      let body = source(DeepReviewViewPath)
      check body.contains("deepreview-mode-toggle")
      check not body.contains("if not vm.glEmbedded.val:")
