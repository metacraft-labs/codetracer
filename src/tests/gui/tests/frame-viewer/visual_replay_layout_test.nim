import std/[json, sequtils, tables, unittest]

import ../../../../frontend/viewmodel/viewmodels/visual_replay_layout

## Helpers shared by the additive-tab tests.

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

proc findFirstStackContaining(node: JsonNode; contentId: int): JsonNode =
  ## Tiny test-only finder so the assertions can describe the result in terms
  ## of "the stack with the editor in it" instead of brittle path indices.
  if node.isNil or node.kind != JObject:
    return nil
  if node{"type"}.getStr("") == "stack" and node.hasKey("content"):
    for child in node["content"].items:
      if child{"componentState"}{"content"}.getInt(-1) == contentId:
        return node
  if node.hasKey("content") and node["content"].kind == JArray:
    for child in node["content"].items:
      let hit = findFirstStackContaining(child, contentId)
      if not hit.isNil:
        return hit
  nil

proc stackContentIds(stack: JsonNode): seq[int] =
  if stack.isNil or not stack.hasKey("content"):
    return @[]
  for child in stack["content"].items:
    result.add(child{"componentState"}{"content"}.getInt(-1))

suite "MCR visual replay layout — additive tab placement":

  test "visual-replay-layout/additive-tabs-on-default-layout":
    ## The bundled default layout exposes only a state/calltrace stack and an
    ## eventlog/terminal stack — there is no editor stack.  The walker should
    ## still place all three tabs (Pixel History + Shader Debug in the state
    ## stack; Video Player as a leftover into the same stack).
    let original = bundledDefaultLayout()
    let originalIds = contentIdsInLayout(original)
    let updated = addVisualReplayTabs(original)

    # Originals untouched: the additive helper must be pure.
    check contentIdsInLayout(original) == originalIds

    check updated.layoutContainsContentId(VideoPlayerContentId)
    check updated.layoutContainsContentId(PixelHistoryContentId)
    check updated.layoutContainsContentId(ShaderDebugContentId)
    check updated.layoutContainsContentId(StateContentId)
    check updated.layoutContainsContentId(CalltraceContentId)
    check updated.layoutContainsContentId(EventLogContentId)
    check updated.layoutContainsContentId(TerminalOutputContentId)

    let stateStack = findFirstStackContaining(updated["root"], StateContentId)
    let stateIds = stackContentIds(stateStack)
    check stateIds.contains(PixelHistoryContentId)
    check stateIds.contains(ShaderDebugContentId)

    # Idempotency: re-running the walker must not duplicate any tab.
    let twice = addVisualReplayTabs(updated)
    let twiceIds = contentIdsInLayout(twice)
    check twiceIds.count(VideoPlayerContentId) == 1
    check twiceIds.count(PixelHistoryContentId) == 1
    check twiceIds.count(ShaderDebugContentId) == 1

  test "visual-replay-layout/additive-tabs-on-user-custom-layout":
    ## A realistic user layout: split editor area (left column hosts both an
    ## editor and a low-level-code stack), state/filesystem sharing a stack
    ## on the right with calltrace below.  The walker must land the Video
    ## Player on the editor stack and the state-view tabs on the state
    ## stack — without disturbing any other pane.
    let editorStack = makeStack([
      makeComponent(EditorViewContentId, "editor-main.py", "editorComponent"),
      makeComponent(LowLevelCodeContentId, "lowLevelCodeComponent-0")
    ])
    let stateStack = makeStack([
      makeComponent(StateContentId, "stateComponent-0"),
      makeComponent(FilesystemContentId, "filesystemComponent-0")
    ])
    let eventLogStack = makeStack([
      makeComponent(EventLogContentId, "eventLogComponent-0"),
      makeComponent(TerminalOutputContentId, "terminalComponent-0")
    ])
    let calltraceStack = makeStack([
      makeComponent(CalltraceContentId, "calltraceComponent-0")
    ])

    let layout = wrap(makeRow("100%", [
      makeColumn("60%", [editorStack, eventLogStack]),
      makeColumn("40%", [stateStack, calltraceStack])
    ]))

    let originalIds = contentIdsInLayout(layout)
    let updated = addVisualReplayTabs(layout)

    # The original layout must not be mutated.
    check contentIdsInLayout(layout) == originalIds

    # Editor stack now hosts the Video Player.
    let updatedEditor = findFirstStackContaining(
      updated["root"], EditorViewContentId)
    let editorIds = stackContentIds(updatedEditor)
    check editorIds.contains(VideoPlayerContentId)
    check editorIds.contains(EditorViewContentId)
    check editorIds.contains(LowLevelCodeContentId)

    # State stack now hosts Pixel History + Shader Debug.
    let updatedState = findFirstStackContaining(
      updated["root"], StateContentId)
    let stateIds = stackContentIds(updatedState)
    check stateIds.contains(PixelHistoryContentId)
    check stateIds.contains(ShaderDebugContentId)
    check stateIds.contains(StateContentId)
    check stateIds.contains(FilesystemContentId)

    # Unrelated stacks must remain untouched.
    let updatedEventLog = findFirstStackContaining(
      updated["root"], EventLogContentId)
    check stackContentIds(updatedEventLog) ==
      @[EventLogContentId, TerminalOutputContentId]
    let updatedCalltrace = findFirstStackContaining(
      updated["root"], CalltraceContentId)
    check stackContentIds(updatedCalltrace) == @[CalltraceContentId]

  test "visual-replay-layout/tabs-removed-on-plain-trace":
    ## After adding the tabs and then removing them, the resulting layout
    ## must be structurally identical to the original — and removal must
    ## tolerate the no-op case where the tabs were never present.
    let editorStack = makeStack([
      makeComponent(EditorViewContentId, "editor-main.py", "editorComponent")
    ])
    let stateStack = makeStack([
      makeComponent(StateContentId, "stateComponent-0")
    ])
    let layout = wrap(makeRow("100%", [
      makeColumn("60%", [editorStack]),
      makeColumn("40%", [stateStack])
    ]))

    let originalIds = contentIdsInLayout(layout)
    let added = addVisualReplayTabs(layout)
    let removed = removeVisualReplayTabs(added)
    check contentIdsInLayout(removed) == originalIds

    # No-op removal is safe.
    let removedAgain = removeVisualReplayTabs(layout)
    check contentIdsInLayout(removedAgain) == originalIds

    # If only some tabs are present, the remover still cleans them up
    # without touching siblings.
    let partial = wrap(makeRow("100%", [
      makeColumn("60%", [
        makeStack([
          makeComponent(EditorViewContentId, "editor-main.py",
            "editorComponent"),
          makeComponent(VideoPlayerContentId, "videoPlayerComponent-0")
        ])
      ]),
      makeColumn("40%", [
        makeStack([
          makeComponent(StateContentId, "stateComponent-0"),
          makeComponent(PixelHistoryContentId, "pixelHistoryComponent-0")
        ])
      ])
    ]))
    let cleaned = removeVisualReplayTabs(partial)
    let cleanedIds = contentIdsInLayout(cleaned)
    check not cleanedIds.contains(VideoPlayerContentId)
    check not cleanedIds.contains(PixelHistoryContentId)
    check not cleanedIds.contains(ShaderDebugContentId)
    check cleanedIds.contains(EditorViewContentId)
    check cleanedIds.contains(StateContentId)

  test "visual-replay-layout/additive-tabs-with-no-matching-stacks":
    ## Extreme corner case: a layout with neither an editor stack nor a
    ## state stack.  The walker falls back to wrapping the layout in a row
    ## that hosts the original layout plus a new column for the tabs.
    let onlyEventLog = wrap(makeRow("100%", [
      makeStack([
        makeComponent(EventLogContentId, "eventLogComponent-0")
      ])
    ]))
    let updated = addVisualReplayTabs(onlyEventLog)
    let ids = contentIdsInLayout(updated)
    check ids.contains(VideoPlayerContentId)
    check ids.contains(PixelHistoryContentId)
    check ids.contains(ShaderDebugContentId)
    check ids.contains(EventLogContentId)

suite "MCR visual replay layout — capability detection":

  test "metadata and artifact detection distinguish visual sessions":
    check metadataAdvertisesVisualReplay("""{"capabilities":{"visualReplay":true}}""")
    check metadataAdvertisesVisualReplay("""{"capabilities":["visual_replay"]}""")
    check metadataAdvertisesVisualReplay("""{"mcr":{"visualReplay":true}}""")
    check not metadataAdvertisesVisualReplay("""{"capabilities":{"visualReplay":false}}""")
    check not metadataAdvertisesVisualReplay("""not-json""")

    var files = initTable[string, string]()
    var dirs = initTable[string, seq[string]]()

    proc pathExists(path: string): bool =
      files.hasKey(path) or dirs.hasKey(path)

    proc readFile(path: string): string =
      files[path]

    proc readDir(path: string): seq[string] =
      dirs.getOrDefault(path, @[])

    dirs["/plain"] = @[]
    check not detectVisualReplayAvailability("/plain", pathExists, readFile, readDir)

    # M-REC-1.5 retired the legacy `trace_metadata.json` /
    # `trace_db_metadata.json` sidecars that used to carry the
    # `visualReplay` capability flag.  Detection is now driven entirely
    # by the on-disk artefacts.

    dirs["/visual-artifacts"] = @["capture"]
    dirs["/visual-artifacts/capture"] = @[]
    files["/visual-artifacts/capture/gfx_commands.dat"] = ""
    check detectVisualReplayAvailability(
      "/visual-artifacts", pathExists, readFile, readDir)
