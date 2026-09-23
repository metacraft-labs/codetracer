## PLAT-41 — the pane parity table and DIFF-10's readings, recorded.
##
## Run (`just plat41-record`), after both capture lanes:
##   bash ci/test/plat41-panes-window.sh              # the native window
##   just plat41-capture-electron                     # the desktop
##
## Folds three measurements into `src/tests/visual/plat41-readings.json`:
##
##   * the NATIVE column of PLAT-23's parity table, from a RUN: the shipped
##     binary's `--plan-out` of a window holding all thirteen panes
##     (`build/plat41/all.plan.json`), each leaf's own `data-ct-state` and the
##     text it drew;
##   * the eight newly expressed panes READ OFF THE NATIVE WINDOW'S PIXELS by
##     `vision_producer.readNewPanes` (`build/plat41/panes.ppm`), with the
##     default layout and a blank compositor as the controls;
##   * the DESKTOP column, from the desktop's DOM at the same stop
##     (`answers/plat41-parity.electron.json`).
##
## Frames are gitignored; the values are the artefact. A record from absent
## inputs is REFUSED.

import std/[json, nativesockets, os, sequtils, strutils, times]
import std/sha1
import ./screen_reading
import ./domain_models
import ./vision_producer

const
  GpuiFrames* = ["panes", "default", "blank"]
  ElectronCensus* = "src/tests/visual/answers/plat41-parity.electron.json"
  PlanPath* = "build/plat41/all.plan.json"
  RecordPath* = "src/tests/visual/plat41-readings.json"

proc kindName(k: ScreenReadingKind): string =
  case k
  of srRead: "read"
  of srEmpty: "empty"
  of srUnreadable: "unreadable"

proc readingJson[T](r: ScreenReading[T]; values: proc (m: T): JsonNode): JsonNode =
  result = %*{"kind": kindName(r.kind)}
  if r.isRead: result["value"] = values(r.value)
  elif r.isUnreadable:
    result["reason"] = %($r.reason)
    result["detail"] = %r.detail

proc newPanesJson*(r: NewPanesReading): JsonNode =
  result = %*{
    "width": r.width, "height": r.height,
    "located": r.panes.mapIt($it.id),
    "debugControls": readingJson(r.transport, proc (m: TransportModel): JsonNode =
      %m.actions),
    "flow": readingJson(r.flow, proc (m: FlowPaneModel): JsonNode =
      %m.rows.mapIt(it.location)),
    "timeline": readingJson(r.timeline, proc (m: TimelineModel): JsonNode =
      %*{"currentTick": m.currentTick, "lastTick": m.lastTick}),
    "fileTree": readingJson(r.fileTree, proc (m: FileTreeModel): JsonNode =
      %m.entries),
  }
  for q in r.quiet:
    result[$q.pane] = readingJson(q.reading, proc (m: seq[string]): JsonNode = %m)

proc planText(n: JsonNode; acc: var seq[string]) =
  if n.kind != JObject: return
  let t = n{"text"}.getStr("")
  if t.len > 0: acc.add t
  for c in n{"children"}.getElems: planText(c, acc)

proc planCensus*(plan: JsonNode): JsonNode =
  ## Each leaf the shipped binary drew: its pane, its own `data-ct-state` and
  ## the text of its subtree — what a reader of the plan sees it say.
  result = newJObject()
  proc walk(n: JsonNode; res: JsonNode) =
    if n.kind != JObject: return
    let a = n{"attributes"}
    if not a.isNil and a.kind == JObject and a.hasKey("data-ct-pane"):
      var texts: seq[string] = @[]
      planText(n, texts)
      res[a["data-ct-pane"].getStr] = %*{
        "state": a{"data-ct-state"}.getStr(""),
        "text": texts,
      }
      return
    for c in n{"children"}.getElems: walk(c, res)
  walk(plan, result)

proc buildRecord*(repoRoot, scratch: string): JsonNode =
  createDir(scratch)
  var gpui = newJObject()
  var digests = newJObject()
  for f in GpuiFrames:
    let path = repoRoot / "build/plat41" / (f & ".ppm")
    gpui[f] = newPanesJson(readNewPanes(path, scratch))
    digests["gpui/" & f] = %($secureHashFile(path))
  var manifest = newJArray()
  let mf = repoRoot / "build/plat41/manifest.jsonl"
  if fileExists(mf):
    for line in lines(mf):
      if line.len > 0: manifest.add parseJson(line)
  %*{
    "_comment": [
      "PLAT-41 — the pane parity table from RUNS, and the eight newly",
      "expressed panes read OFF THE NATIVE WINDOW'S SCREEN. `gpuiCensus` is the",
      "shipped binary's own per-pane state; `gpui` holds the pixel readings;",
      "`electron` is the desktop's DOM census at the same stop. REGENERATE",
      "with `just plat41-record` after both captures.",
    ],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": (try: getHostname() except CatchableError: "unknown"),
    "scenario": parseJson(readFile(repoRoot / "src/tests/visual/plat41-scenario.json")),
    "frameDigests": digests,
    "gpuiRuns": manifest,
    "gpuiCensus": planCensus(parseJson(readFile(repoRoot / PlanPath))),
    "gpui": gpui,
    "electron": parseJson(readFile(repoRoot / ElectronCensus)),
  }

when isMainModule:
  let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  var missing: seq[string] = @[]
  for f in GpuiFrames:
    if not fileExists(repoRoot / "build/plat41" / (f & ".ppm")):
      missing.add "build/plat41/" & f & ".ppm"
  for p in [PlanPath, ElectronCensus]:
    if not fileExists(repoRoot / p): missing.add p
  if missing.len > 0:
    stderr.writeLine "PLAT-41: refusing to write a record from absent inputs: " &
                     missing.join(", ")
    stderr.writeLine "  remedy: just plat41-capture-window, then " &
                     "just plat41-capture-electron"
    quit 1
  let scratch = getEnv("TMPDIR", "/tmp") / "plat41-record"
  writeFile(repoRoot / RecordPath, pretty(buildRecord(repoRoot, scratch)) & "\n")
  echo "wrote ", RecordPath
