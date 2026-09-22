## PLAT-39 — emit the oracle's readings as a committed record.
##
## **WHY A RECORD EXISTS AT ALL, AND WHY IT IS NOT A GOLDEN SNAPSHOT.**
##
## The frames this oracle reads are gitignored. PLAT-35 measured the reason —
## five of six frames differ between runs, worst 78,960 pixels, and `entry-shell`
## moves 0.9% of its pixels while its eight answers stay byte-identical — so a
## committed FRAME would pin whichever run produced it.
##
## But that objection is about pixels, and this milestone's output is not pixels.
## It is a handful of domain values: a highlighted line number, a row count, a
## set of variable names. Those are exactly as stable as the scenario is, and the
## scenario is deterministic. So the same split the rest of this repository
## already uses applies here — **pixels are intermediates, derived values are the
## artefact**:
##
##     src/tests/visual/captures/        gitignored   (the frames)
##     src/tests/visual/answers/         tracked      (what the DOM produced)
##     src/tests/visual/plat37-measurements.json  tracked
##     src/tests/visual/plat38-keystrokes.json    tracked
##     src/tests/visual/plat39-readings.json      tracked   <- this file writes it
##
## PLAT-37 and PLAT-38 already do this: they capture locally and commit the
## MEASUREMENTS, so their suites assert in CI without needing a compositor. This
## milestone was the only one that tried to make the pixels themselves durable,
## which is why it was the only one that had to be deferred in CI.
##
## **WHAT THE RECORD DOES NOT BUY.** Asserting the record alone is weaker than
## re-deriving from pixels, and the suite says so rather than pretending
## otherwise. What it still buys is real: the recorded PIXEL-derived value is
## compared against the committed DOM-derived `stoppedLine`, and those two came
## from paths that share no code. A record that disagreed with the DOM answers
## would redden CI. What CI cannot do is notice that the reader has stopped
## working — only a live run does that, which is why the suite prefers live
## pixels whenever they are present and prints which mode it used.
##
## **PROVENANCE IS MANDATORY.** A recorded capture with no date is a capture
## nobody can age, so `takenAt`, `host` and a digest per frame are written and
## the suite PRINTS them. The digests are what make a stale record visible: if
## the corpus is recaptured and a reading changes, the digest changed too and the
## disagreement is attributable rather than mysterious.

import std/[algorithm, json, nativesockets, os, sequtils, strutils, times]
import std/sha1
import ./screen_reading
import ./domain_models
import ./vision_producer

const Scenarios* = ["entry-shell", "stepped-editor", "advanced-state",
                    "returned-calltrace", "continued-event-log",
                    "breakpoint-editor"]

const GpuiScenarios* = ["stepped-editor", "advanced-state"]

proc kindName(k: ScreenReadingKind): string =
  case k
  of srRead: "read"
  of srEmpty: "empty"
  of srUnreadable: "unreadable"

proc digestOf(path: string): string =
  if not fileExists(path): return ""
  $secureHashFile(path)

proc readingToJson(r: FrameReading): JsonNode =
  result = %*{
    "width": r.width,
    "height": r.height,
    "programState": {"kind": kindName(r.programState.kind)},
    "eventLog": {"kind": kindName(r.eventLog.kind)},
    "editor": {"kind": kindName(r.editor.kind)},
  }
  if r.programState.isRead:
    var names = r.programState.value.variableStates.mapIt(it.name)
    names.sort()
    result["programState"]["variableNames"] = %names
    result["programState"]["count"] = %names.len
  elif r.programState.isUnreadable:
    result["programState"]["reason"] = %($r.programState.reason)
  if r.eventLog.isRead:
    result["eventLog"]["events"] = %r.eventLog.value.events.len
    result["eventLog"]["ofRows"] = %r.eventLog.value.ofRows
  elif r.eventLog.isUnreadable:
    result["eventLog"]["reason"] = %($r.eventLog.reason)
  if r.editor.isRead:
    result["editor"]["highlightedLine"] = %r.editor.value.higlitedLineNumber
  elif r.editor.isUnreadable:
    result["editor"]["reason"] = %($r.editor.reason)

proc buildRecord*(repoRoot, scratch: string): JsonNode =
  let capDir = repoRoot / "src/tests/visual/captures/electron"
  let gpuiDir = repoRoot / GpuiCaptureDir
  createDir(scratch)

  var electron = newJObject()
  var digests = newJObject()
  for s in Scenarios:
    let path = capDir / (s & ".png")
    electron[s] = readingToJson(readFrame(path, scratch))
    digests["electron/" & s] = %digestOf(path)

  var gpui = newJObject()
  for s in GpuiScenarios:
    let path = gpuiDir / (s & ".png")
    gpui[s] = readingToJson(readFrame(path, scratch))
    digests["gpui/" & s] = %digestOf(path)

  %*{
    "_comment": [
      "PLAT-39 — the oracle's readings, recorded so the suite can assert in CI.",
      "",
      "The frames these were derived from are GITIGNORED: PLAT-35 measured that",
      "five of six differ between runs, so a committed frame would pin whichever",
      "run produced it. The derived VALUES do not have that property — they are",
      "as stable as the scenario, and the scenario is deterministic.",
      "",
      "This is the same split the rest of this directory already uses: pixels",
      "are intermediates, derived values are the artefact. plat37-measurements",
      ".json and plat38-keystrokes.json are the same shape.",
      "",
      "REGENERATE with `just plat39-record` after a recapture. If a reading here",
      "changes, the matching digest below changed too, so the disagreement is",
      "attributable rather than mysterious.",
      "",
      "Asserting this record is WEAKER than re-deriving from pixels and the",
      "suite says so: it cannot notice that the reader stopped working. What it",
      "does catch is a recorded pixel-derived value disagreeing with the",
      "committed DOM-derived answers, and those two share no code.",
    ],
    "takenAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    # The real hostname, not $HOSTNAME — that variable is unset inside the
    # nix dev shell, so reading it recorded "unknown" and the provenance said
    # nothing. Provenance that cannot identify the machine is decoration.
    "host": (try: getHostname() except CatchableError: "unknown"),
    "expectedScenarios": Scenarios.len,
    "expectedGpuiScenarios": GpuiScenarios.len,
    "frameDigests": digests,
    "electron": electron,
    "gpui": gpui,
  }

when isMainModule:
  let repoRoot = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  let scratch = getEnv("TMPDIR", "/tmp") / "plat39-record"
  let capDir = repoRoot / "src/tests/visual/captures/electron"
  # **A RECORD WRITTEN FROM AN ABSENT CORPUS WOULD BE A RECORD OF NOTHING.**
  # Every reading would be `urFrameMissing` and the file would look like a
  # legitimate answer. Refuse loudly instead.
  var present = 0
  for s in Scenarios:
    if fileExists(capDir / (s & ".png")): inc present
  if present != Scenarios.len:
    stderr.writeLine "PLAT-39: refusing to write a record from an absent corpus."
    stderr.writeLine "  found " & $present & " of " & $Scenarios.len &
                     " frames under " & capDir
    stderr.writeLine "  remedy: just plat35-capture-electron"
    quit 1
  let outPath = repoRoot / "src/tests/visual/plat39-readings.json"
  writeFile(outPath, pretty(buildRecord(repoRoot, scratch)) & "\n")
  echo "wrote ", outPath
