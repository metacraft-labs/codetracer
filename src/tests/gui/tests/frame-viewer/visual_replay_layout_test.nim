import std/[sequtils, tables, unittest]

import ../../../../frontend/viewmodel/viewmodels/visual_replay_layout

suite "MCR visual replay layout capability":
  test "test_visual_replay_capability_drives_layout":
    let nonVisual = defaultLayoutForVisualReplayCapability(false)
    check not nonVisual.layoutContainsContentId(FrameViewerContentId)
    check not nonVisual.layoutContainsContentId(PixelHistoryContentId)
    check not nonVisual.layoutContainsContentId(ShaderDebugContentId)
    check nonVisual.layoutContainsContentId(StateContentId)
    check nonVisual.layoutContainsContentId(CalltraceContentId)
    check nonVisual.layoutContainsContentId(EventLogContentId)
    check nonVisual.layoutContainsContentId(TerminalOutputContentId)

    let visual = defaultLayoutForVisualReplayCapability(true)
    check visual.layoutContainsContentId(FrameViewerContentId)
    check visual.layoutContainsContentId(PixelHistoryContentId)
    check visual.layoutContainsContentId(ShaderDebugContentId)
    check visual.layoutContainsContentId(StateContentId)
    check visual.layoutContainsContentId(CalltraceContentId)
    check visual.layoutContainsContentId(EventLogContentId)
    check visual.layoutContainsContentId(TerminalOutputContentId)

    let ids = visual.contentIdsInLayout()
    check ids.find(FrameViewerContentId) >= 0
    check ids.count(FrameViewerContentId) == 1
    check ids.find(PixelHistoryContentId) >= 0
    check ids.count(PixelHistoryContentId) == 1
    check ids.find(ShaderDebugContentId) >= 0
    check ids.count(ShaderDebugContentId) == 1

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
