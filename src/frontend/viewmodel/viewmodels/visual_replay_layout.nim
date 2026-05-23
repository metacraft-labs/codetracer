## Default GoldenLayout selection for MCR visual replay sessions.
##
## The layout helpers are intentionally pure so headless tests can assert the
## capability decision without needing Electron or GoldenLayout.

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
  StateContentId* = 4
  CalltraceContentId* = 6
  EventLogContentId* = 8
  TerminalOutputContentId* = 24
  FrameViewerContentId* = 42
  PixelHistoryContentId* = 43
  ShaderDebugContentId* = 44

proc joinTracePath(dir, name: string): string =
  if dir.len == 0:
    name
  elif dir.endsWith("/") or dir.endsWith("\\"):
    dir & name
  else:
    dir & "/" & name

const defaultVisualReplayLayoutJson* = """{
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
        "size": "58%",
        "content": [
          {
            "type": "stack",
            "size": "62%",
            "content": [
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "frameViewerComponent-0",
                  "content": 42
                },
                "title": "genericUiComponent"
              },
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "pixelHistoryComponent-0",
                  "content": 43
                },
                "title": "genericUiComponent"
              },
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "shaderDebugComponent-0",
                  "content": 44
                },
                "title": "genericUiComponent"
              }
            ]
          },
          {
            "type": "stack",
            "size": "38%",
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
      },
      {
        "type": "column",
        "size": "42%",
        "content": [
          {
            "type": "row",
            "content": [
              {
                "type": "stack",
                "size": "50%",
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
                      "label": "filesystemComponent-0",
                      "content": 9
                    },
                    "title": "genericUiComponent"
                  }
                ]
              },
              {
                "type": "stack",
                "size": "50%",
                "content": [
                  {
                    "type": "component",
                    "componentType": "genericUiComponent",
                    "componentState": {
                      "id": 0,
                      "label": "calltraceComponent-0",
                      "content": 6
                    },
                    "title": "genericUiComponent"
                  },
                  {
                    "type": "component",
                    "componentType": "genericUiComponent",
                    "componentState": {
                      "id": 0,
                      "label": "scratchpadComponent-0",
                      "content": 17
                    },
                    "title": "genericUiComponent"
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  },
  "openPopouts": []
}"""

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

proc defaultLayoutForVisualReplayCapability*(visualReplayAvailable: bool): JsonNode =
  if visualReplayAvailable:
    parseJson(defaultVisualReplayLayoutJson)
  else:
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
