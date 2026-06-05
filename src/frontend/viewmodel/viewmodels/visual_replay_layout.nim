## Default GoldenLayout helpers for MCR visual replay sessions.
##
## All helpers operate on parsed JSON trees so headless tests can reason about
## layout decisions without booting Electron or GoldenLayout.
##
## M3 made tab placement *additive*: when a trace with visual replay artefacts
## loads, the Video Player, Pixel History and Shader Debug tabs are inserted
## into the user's existing layout rather than swapping it out for a hand-
## rolled "visual replay" layout.  The corresponding inverse is exposed for
## trace-unload paths.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md (Activation)
## Milestones: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org (M3)

import std/[json, strutils]

type
  PathExistsProc* = proc(path: string): bool
  ReadFileProc* = proc(path: string): string
  ReadDirProc* = proc(path: string): seq[string]

const visualReplayCapabilityNames = [
  "visualReplay",
  "visual_replay",
  "visual-replay",
  "mcrVisualReplay",
  "mcr_visual_replay",
]

const gfxStreamArtifactNames = [
  "gfx_commands.dat",
  "gfx_bulkdata.dat",
  "gfx_frames.idx",
  "gfx_commands.idx",
]

const
  EditorViewContentId* = 2
  StateContentId* = 4
  CalltraceContentId* = 6
  EventLogContentId* = 8
  FilesystemContentId* = 9
  LowLevelCodeContentId* = 18
  TerminalOutputContentId* = 24
  PixelHistoryContentId* = 43
  ShaderDebugContentId* = 44
  VideoPlayerContentId* = 45

  ## Component names used by GoldenLayout to dispatch panel rendering. The
  ## additive walker uses them as a secondary signal when locating the
  ## "editor stack" — some traces persist their editors as the dedicated
  ## ``editorComponent`` type rather than the generic component.
  EditorComponentName* = "editorComponent"

proc joinTracePath(dir, name: string): string =
  if dir.len == 0:
    name
  elif dir.endsWith("/") or dir.endsWith("\\"):
    dir & name
  else:
    dir & "/" & name

const bundledDefaultLayoutJson = """{
  "settings": {
    "constrainDragToContainer": true,
    "reorderEnabled": true,
    "popoutWholeStack": false,
    "blockedPopoutsThrowError": true,
    "responsiveMode": "always"
  },
  "dimensions": {
    "borderWidth": 4,
    "borderHeight": 4,
    "headerHeight": 32,
    "dragProxyWidth": 300,
    "dragProxyHeight": 200
  },
  "root": {
    "type": "row",
    "size": "100%",
    "isClosable": false,
    "content": [
      {
        "type": "column",
        "size": "50%",
        "content": [
          {
            "type": "stack",
            "content": [
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "stateComponent-0",
                  "content": 4
                },
                "title": "genericUiComponent"
              },
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "calltraceComponent-0",
                  "content": 6
                },
                "title": "genericUiComponent"
              }
            ]
          }
        ]
      },
      {
        "type": "column",
        "size": "50%",
        "content": [
          {
            "type": "stack",
            "content": [
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "eventLogComponent-0",
                  "content": 8
                },
                "title": "genericUiComponent"
              },
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "terminalComponent-0",
                  "content": 24
                },
                "title": "genericUiComponent"
              }
            ]
          }
        ]
      }
    ]
  },
  "openPopouts": []
}"""

proc bundledDefaultLayout*(): JsonNode =
  ## Returns the layout CodeTracer ships with for new sessions.  Tests use it
  ## as the canonical "default user layout" baseline when checking additive
  ## insertion behaviour.
  parseJson(bundledDefaultLayoutJson)

proc collectContentIds(node: JsonNode; ids: var seq[int]) =
  if node.kind != JObject:
    return
  if node{"type"}.getStr("") == "component":
    ids.add(node{"componentState"}{"content"}.getInt(-1))
  if node.hasKey("content"):
    for child in node["content"].items:
      collectContentIds(child, ids)

proc contentIdsInLayout*(layout: JsonNode): seq[int] =
  collectContentIds(layout{"root"}, result)

proc layoutContainsContentId*(layout: JsonNode; contentId: int): bool =
  contentIdsInLayout(layout).contains(contentId)

proc hasVisualReplayFlag(node: JsonNode): bool =
  if node.isNil:
    return false
  for name in visualReplayCapabilityNames:
    if node{name}.getBool(false):
      return true
  false

proc hasVisualReplayCapabilityList(node: JsonNode): bool =
  if node.isNil or node.kind != JArray:
    return false
  for item in node.items:
    if item.kind == JString and item.getStr("") in visualReplayCapabilityNames:
      return true
  false

proc hasVisualReplayCapabilityObject(node: JsonNode): bool =
  if node.isNil or node.kind != JObject:
    return false
  node.hasVisualReplayFlag() or
    node{"capabilities"}.hasVisualReplayCapabilityList() or
    node{"capabilities"}.hasVisualReplayCapabilityObject() or
    node{"features"}.hasVisualReplayCapabilityList() or
    node{"features"}.hasVisualReplayCapabilityObject() or
    node{"mcr"}.hasVisualReplayCapabilityObject()

proc metadataAdvertisesVisualReplay*(rawMetadata: string): bool =
  try:
    let node = parseJson(rawMetadata)
    node.hasVisualReplayCapabilityObject()
  except:
    false

proc directoryHasGfxStreamArtifacts*(dir: string; pathExists: PathExistsProc): bool =
  for name in gfxStreamArtifactNames:
    if pathExists(joinTracePath(dir, name)):
      return true
  false

proc traceHasVisualReplayArtifacts*(outputFolder: string;
                                    pathExists: PathExistsProc;
                                    readDir: ReadDirProc): bool =
  if outputFolder.len == 0 or not pathExists(outputFolder):
    return false
  if directoryHasGfxStreamArtifacts(outputFolder, pathExists) or
      directoryHasGfxStreamArtifacts(joinTracePath(outputFolder, "gfx_stream"), pathExists):
    return true

  try:
    for name in readDir(outputFolder):
      if directoryHasGfxStreamArtifacts(joinTracePath(outputFolder, name), pathExists):
        return true
  except CatchableError:
    return false
  false

proc detectVisualReplayAvailability*(outputFolder: string;
                                     pathExists: PathExistsProc;
                                     readFile: ReadFileProc;
                                     readDir: ReadDirProc): bool =
  ## M-REC-1.5 retired the legacy ``trace_metadata.json`` /
  ## ``trace_db_metadata.json`` JSON sidecars that historically carried
  ## a ``visualReplay`` capability flag.  Detection now reduces to the
  ## artefact-presence check; the CTFS ``meta.dat`` does not surface
  ## frontend-specific capability bits today, so traces relying on the
  ## legacy advertisement path must be regenerated.  ``readFile`` is
  ## kept in the signature for forwards compatibility — once meta.dat
  ## gains a capability slot, this proc will need it again — but is
  ## unused today.
  let _ = readFile
  traceHasVisualReplayArtifacts(outputFolder, pathExists, readDir)

# ---------------------------------------------------------------------------
# Additive tab placement (M3)
# ---------------------------------------------------------------------------

const
  videoPlayerLabel = "videoPlayerComponent-0"
  pixelHistoryLabel = "pixelHistoryComponent-0"
  shaderDebugLabel = "shaderDebugComponent-0"

  ## Tabs that the additive walker is responsible for inserting and removing.
  ## Listed in declaration order so the walker emits them in a stable order
  ## when falling back to a wrapper column.
  visualReplayTabContentIds = [
    VideoPlayerContentId,
    PixelHistoryContentId,
    ShaderDebugContentId,
  ]

proc isComponentNode(node: JsonNode): bool {.inline.} =
  node.kind == JObject and node{"type"}.getStr("") == "component"

proc componentName(node: JsonNode): string {.inline.} =
  ## Component name is stored under ``componentName`` in legacy persisted
  ## layouts and under ``componentType`` in GoldenLayout v2 — accept both.
  let name = node{"componentName"}.getStr("")
  if name.len > 0:
    name
  else:
    node{"componentType"}.getStr("")

proc componentContentId(node: JsonNode): int {.inline.} =
  if not isComponentNode(node):
    -1
  else:
    node{"componentState"}{"content"}.getInt(-1)

proc makeVisualReplayComponent(label: string; contentId: int): JsonNode =
  ## Build the GoldenLayout node for one of the three additive tabs.  The
  ## ``id`` is fixed at ``0`` because each tab is a singleton — keep this in
  ## sync with the ``Content`` enum values in
  ## ``common_types/codetracer_features/frontend.nim``.
  %*{
    "type": "component",
    "componentType": "genericUiComponent",
    "componentName": "genericUiComponent",
    "componentState": {
      "id": 0,
      "label": label,
      "content": contentId
    },
    "title": "genericUiComponent"
  }

proc stackContainsAnyContentId(stack: JsonNode; ids: openArray[int]): bool =
  ## True if any direct child of the stack is a component whose content id
  ## appears in ``ids``.  Stacks contain only components in GoldenLayout, but
  ## defensive — accept stacks that have been somehow nested by an extension.
  if stack.kind != JObject or stack{"type"}.getStr("") != "stack":
    return false
  if not stack.hasKey("content") or stack["content"].kind != JArray:
    return false
  for child in stack["content"].items:
    if not isComponentNode(child):
      continue
    let contentId = componentContentId(child)
    for wanted in ids:
      if contentId == wanted:
        return true
  false

proc stackContainsEditorContent(stack: JsonNode): bool =
  ## True if the stack hosts an editor tab — either the dedicated
  ## ``editorComponent`` type or a generic component whose content is
  ## ``EditorView`` (2) or ``LowLevelCode`` (18).
  if stack.kind != JObject or stack{"type"}.getStr("") != "stack":
    return false
  if not stack.hasKey("content") or stack["content"].kind != JArray:
    return false
  for child in stack["content"].items:
    if not isComponentNode(child):
      continue
    if componentName(child) == EditorComponentName:
      return true
    let contentId = componentContentId(child)
    if contentId == EditorViewContentId or contentId == LowLevelCodeContentId:
      return true
  false

proc findStackMatching(node: JsonNode;
                      predicate: proc(stack: JsonNode): bool): JsonNode =
  ## Depth-first search for the first stack node matching ``predicate``.
  ## Returns the matching JsonNode (a reference into ``node``) or ``nil``.
  if node.isNil or node.kind != JObject:
    return nil
  if node{"type"}.getStr("") == "stack" and predicate(node):
    return node
  if node.hasKey("content") and node["content"].kind == JArray:
    for child in node["content"].items:
      let hit = findStackMatching(child, predicate)
      if not hit.isNil:
        return hit
  nil

proc appendTabIfMissing(stack: JsonNode; label: string; contentId: int) =
  ## Append ``contentId`` to ``stack`` unless an entry with the same content
  ## id is already present.  Insertion is idempotent so the additive walker
  ## can be safely re-run (e.g. after a layout reload).
  if stack.isNil or not stack.hasKey("content"):
    return
  for child in stack["content"].items:
    if isComponentNode(child) and componentContentId(child) == contentId:
      return
  stack["content"].add(makeVisualReplayComponent(label, contentId))

proc wrapWithVisualReplayColumn(layout: JsonNode) =
  ## Fallback path: no stacks in the layout match our heuristics, so attach a
  ## fresh column on the right of the root that hosts all three tabs in a
  ## single stack.  This keeps the user's pane structure untouched but still
  ## surfaces the tabs.  Document this carefully because it should be hit
  ## only by exotic layouts (e.g. an editor-less workspace).
  if layout.isNil or not layout.hasKey("root"):
    return
  let root = layout["root"]
  if root.isNil or root.kind != JObject:
    return

  let visualStack = %*{
    "type": "stack",
    "content": [
      makeVisualReplayComponent(videoPlayerLabel, VideoPlayerContentId),
      makeVisualReplayComponent(pixelHistoryLabel, PixelHistoryContentId),
      makeVisualReplayComponent(shaderDebugLabel, ShaderDebugContentId),
    ]
  }
  let visualColumn = %*{
    "type": "column",
    "size": "30%",
    "content": [visualStack]
  }

  if root{"type"}.getStr("") == "row" and root.hasKey("content") and
      root["content"].kind == JArray:
    root["content"].add(visualColumn)
    return

  # Root is not a row — synthesise one wrapping the original root + the new
  # column so layout consumers can still rely on a row at the top level.
  let originalRoot = copy(root)
  layout["root"] = %*{
    "type": "row",
    "size": "100%",
    "isClosable": false,
    "content": [originalRoot, visualColumn]
  }

proc addVisualReplayTabs*(layout: JsonNode): JsonNode =
  ## Insert the Video Player, Pixel History and Shader Debug tabs into a
  ## GoldenLayout JSON tree.  The function is pure — the input is not
  ## mutated; the returned tree is a deep copy with the additions.
  ##
  ## Placement rules (matching Visual-Replay.md §Activation):
  ##   * Video Player goes into the first stack hosting an ``editorComponent``
  ##     or a ``Content.EditorView`` / ``Content.LowLevelCode`` entry.
  ##   * Pixel History and Shader Debug go into the first stack hosting a
  ##     ``Content.State`` or ``Content.Filesystem`` entry.  If the editor
  ##     stack happens to also contain a state/filesystem entry, the state
  ##     tabs still target that same stack rather than splitting them across
  ##     unrelated panes.
  ##   * If neither heuristic finds a host, fall back to wrapping the layout
  ##     in a row that contains the original layout plus a new column with
  ##     all three tabs.  This is exercised only by exotic user layouts.
  if layout.isNil:
    return layout
  result = copy(layout)
  if not result.hasKey("root"):
    return

  let editorStack = findStackMatching(result["root"], stackContainsEditorContent)
  if not editorStack.isNil:
    appendTabIfMissing(editorStack, videoPlayerLabel, VideoPlayerContentId)

  let stateStack = findStackMatching(result["root"], proc(stack: JsonNode): bool =
    stackContainsAnyContentId(stack, [StateContentId, FilesystemContentId]))
  if not stateStack.isNil:
    appendTabIfMissing(stateStack, pixelHistoryLabel, PixelHistoryContentId)
    appendTabIfMissing(stateStack, shaderDebugLabel, ShaderDebugContentId)

  if editorStack.isNil and stateStack.isNil:
    wrapWithVisualReplayColumn(result)
    return

  # Even when only one of the two stacks was found, we should still surface
  # any tab that has no home.  Prefer placing leftovers in the located stack
  # to keep the user's pane geometry stable.
  if editorStack.isNil and not stateStack.isNil:
    appendTabIfMissing(stateStack, videoPlayerLabel, VideoPlayerContentId)
  if stateStack.isNil and not editorStack.isNil:
    appendTabIfMissing(editorStack, pixelHistoryLabel, PixelHistoryContentId)
    appendTabIfMissing(editorStack, shaderDebugLabel, ShaderDebugContentId)

proc isVisualReplayContentId(contentId: int): bool {.inline.} =
  for wanted in visualReplayTabContentIds:
    if contentId == wanted:
      return true
  false

proc pruneVisualReplayTabs(node: JsonNode) =
  ## Recursive helper: drop visual-replay components from any stack and
  ## collapse stacks that become empty.  Operates in place; callers should
  ## hand it a freshly copied tree.
  if node.isNil or node.kind != JObject:
    return
  if not node.hasKey("content") or node["content"].kind != JArray:
    return

  if node{"type"}.getStr("") == "stack":
    var kept = newJArray()
    for child in node["content"].items:
      if isComponentNode(child) and isVisualReplayContentId(componentContentId(child)):
        continue
      kept.add(child)
    node["content"] = kept
    return

  var newChildren = newJArray()
  for child in node["content"].items:
    pruneVisualReplayTabs(child)
    # Drop empty stacks and empty rows/columns so the layout does not end up
    # with phantom containers after the visual tabs leave.
    if child.kind == JObject and child.hasKey("content") and
        child["content"].kind == JArray and child["content"].len == 0 and
        child{"type"}.getStr("") in ["stack", "row", "column"]:
      continue
    newChildren.add(child)
  node["content"] = newChildren

proc removeVisualReplayTabs*(layout: JsonNode): JsonNode =
  ## Inverse of ``addVisualReplayTabs``: returns a copy of ``layout`` with
  ## any Video Player, Pixel History and Shader Debug tabs stripped out, plus
  ## any container that becomes empty as a result.  Pure for tests.
  if layout.isNil:
    return layout
  result = copy(layout)
  if not result.hasKey("root"):
    return
  pruneVisualReplayTabs(result["root"])
