import std/[sequtils, tables, unittest]

import ../../../../frontend/viewmodel/viewmodels/visual_replay_layout
import ../../../../common/types

suite "MCR visual replay layout capability":
  test "test_visual_replay_capability_drives_layout":
    let nonVisual = defaultLayoutForVisualReplayCapability(false)
    check not nonVisual.layoutContainsContentId(ord(Content.FrameViewer))
    check not nonVisual.layoutContainsContentId(ord(Content.PixelHistory))
    check nonVisual.layoutContainsContentId(ord(Content.State))
    check nonVisual.layoutContainsContentId(ord(Content.Calltrace))
    check nonVisual.layoutContainsContentId(ord(Content.EventLog))
    check nonVisual.layoutContainsContentId(ord(Content.TerminalOutput))

    let visual = defaultLayoutForVisualReplayCapability(true)
    check visual.layoutContainsContentId(ord(Content.FrameViewer))
    check visual.layoutContainsContentId(ord(Content.PixelHistory))
    check visual.layoutContainsContentId(ord(Content.State))
    check visual.layoutContainsContentId(ord(Content.Calltrace))
    check visual.layoutContainsContentId(ord(Content.EventLog))
    check visual.layoutContainsContentId(ord(Content.TerminalOutput))

    let ids = visual.contentIdsInLayout()
    check ids.find(ord(Content.FrameViewer)) >= 0
    check ids.count(ord(Content.FrameViewer)) == 1
    check ids.find(ord(Content.PixelHistory)) >= 0
    check ids.count(ord(Content.PixelHistory)) == 1

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

    dirs["/visual-metadata"] = @[]
    files["/visual-metadata/trace_metadata.json"] =
      """{"capabilities":{"visualReplay":true}}"""
    check detectVisualReplayAvailability(
      "/visual-metadata", pathExists, readFile, readDir)

    dirs["/visual-artifacts"] = @["capture"]
    dirs["/visual-artifacts/capture"] = @[]
    files["/visual-artifacts/capture/gfx_commands.dat"] = ""
    check detectVisualReplayAvailability(
      "/visual-artifacts", pathExists, readFile, readDir)
