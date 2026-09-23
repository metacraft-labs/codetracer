## PLAT-40 — `DIFF-9`'s record: the three producer-fed panes, read off the
## screens of two front-ends into PLAT-39's domain types.
##
## Run (`just plat40-record`), after both capture lanes:
##   bash ci/test/plat40-panes-window.sh             # the native window
##   just test-gui-prebuilt tests/visual/plat40-panes-capture.spec.ts
##
## Reads, with `vision_producer.readProducerPanes` — pixels in, domain models
## out, no selector and no ViewModel:
##
##   build/plat40/panes.ppm       the native window, the three panes laid out
##   build/plat40/default.ppm     the same run under the DEFAULT layout — the
##                                negative control: it has no breakpoint list
##   build/plat40/blank.ppm       the compositor with no window
##   src/tests/visual/captures/electron/plat40-panes.png   the desktop
##
## and copies in the desktop capture's DOM reading of the same frame
## (`answers/plat40-panes.electron.json`), which shares no code with the pixel
## reader. Writes `src/tests/visual/plat40-readings.json`; the frames are
## gitignored (PLAT-35's reason: a committed frame pins whichever run produced
## it) and the VALUES are the artefact, exactly as `plat39-readings.json`.
##
## **A RECORD FROM AN ABSENT FRAME IS REFUSED**, not written: every reading
## would be `urFrameMissing` and the file would look like an answer.

import std/[json, nativesockets, os, sequtils, strutils, times]
import std/sha1
import ./screen_reading
import ./domain_models
import ./pane_grammar
import ./vision_producer

const
  GpuiFrames* = ["panes", "default", "blank"]
  ElectronFrame* = "src/tests/visual/captures/electron/plat40-panes.png"
  ElectronDom* = "src/tests/visual/answers/plat40-panes.electron.json"
  RecordPath* = "src/tests/visual/plat40-readings.json"

proc kindName(k: ScreenReadingKind): string =
  case k
  of srRead: "read"
  of srEmpty: "empty"
  of srUnreadable: "unreadable"

proc digestOf(path: string): string =
  if not fileExists(path): return ""
  $secureHashFile(path)

proc readingJson[T](r: ScreenReading[T]; values: proc (m: T): JsonNode): JsonNode =
  result = %*{"kind": kindName(r.kind)}
  if r.isRead: result["value"] = values(r.value)
  elif r.isUnreadable:
    result["reason"] = %($r.reason)
    result["detail"] = %r.detail

proc panesJson*(r: ProducerPanesReading): JsonNode =
  %*{
    "width": r.width,
    "height": r.height,
    "located": r.panes.mapIt($it.id),
    "calltrace": readingJson(r.calltrace, proc (m: CalltraceModel): JsonNode =
      %m.calls.mapIt(it.name)),
    "eventLog": readingJson(r.eventLog, proc (m: EventLogModel): JsonNode =
      %m.events.mapIt(eventText(it.consoleOutput))),
    "pointList": readingJson(r.pointList, proc (m: PointListModel): JsonNode =
      %m.points.mapIt(%*{"kind": it.kind, "fileName": it.fileName,
                         "lineNumber": it.lineNumber})),
  }

proc buildRecord*(repoRoot, scratch: string): JsonNode =
  createDir(scratch)
  var gpui = newJObject()
  var digests = newJObject()
  for f in GpuiFrames:
    let path = repoRoot / "build/plat40" / (f & ".ppm")
    gpui[f] = panesJson(readProducerPanes(path, scratch))
    digests["gpui/" & f] = %digestOf(path)
  let ePath = repoRoot / ElectronFrame
  digests["electron/plat40-panes"] = %digestOf(ePath)
  let dom = parseJson(readFile(repoRoot / ElectronDom))
  var manifest = newJArray()
  let mf = repoRoot / "build/plat40/manifest.jsonl"
  if fileExists(mf):
    for line in lines(mf):
      if line.len > 0: manifest.add parseJson(line)
  %*{
    "_comment": [
      "PLAT-40 — DIFF-9's readings: the call trace, the event log and the",
      "breakpoint list, read OFF THE SCREEN of the native window and of the",
      "desktop into PLAT-39's domain types, plus the desktop's DOM reading of",
      "the same frame. The frames are gitignored; these values are the",
      "artefact. REGENERATE with `just plat40-record` after both captures.",
    ],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": (try: getHostname() except CatchableError: "unknown"),
    "scenario": parseJson(readFile(repoRoot / "src/tests/visual/plat40-scenario.json")),
    "frameDigests": digests,
    "gpuiRuns": manifest,
    "gpui": gpui,
    "electron": {"panes": panesJson(readProducerPanes(ePath, scratch))},
    "electronDom": dom,
  }

when isMainModule:
  let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  var missing: seq[string] = @[]
  for f in GpuiFrames:
    if not fileExists(repoRoot / "build/plat40" / (f & ".ppm")):
      missing.add "build/plat40/" & f & ".ppm"
  for p in [ElectronFrame, ElectronDom]:
    if not fileExists(repoRoot / p): missing.add p
  if missing.len > 0:
    stderr.writeLine "PLAT-40: refusing to write a record from absent frames: " &
                     missing.join(", ")
    stderr.writeLine "  remedy: bash ci/test/plat40-panes-window.sh, then " &
                     "just test-gui-prebuilt tests/visual/plat40-panes-capture.spec.ts"
    quit 1
  let scratch = getEnv("TMPDIR", "/tmp") / "plat40-record"
  writeFile(repoRoot / RecordPath,
            pretty(buildRecord(repoRoot, scratch)) & "\n")
  echo "wrote ", RecordPath
