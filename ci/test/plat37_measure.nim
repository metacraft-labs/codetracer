## plat37_measure.nim — PLAT-37. **The capture's measurements, recorded.**
##
##   nim c -r --hints:off --path:src/frontend/viewmodel --path:../GuiAssert/src \
##       ci/test/plat37_measure.nim
##
## Reads `build/plat37/manifest.json` and the frames it names, measures every
## run through `plat37_vision.measureCorpus`, and writes
## `src/tests/visual/plat37-measurements.json`.
##
## ## Why the numbers are recorded at all, rather than re-taken by the gate
##
## **THIS IS THE SAME ARRANGEMENT PLAT-35's ELECTRON ARM ALREADY HAS, and it is
## adopted for the same reason rather than invented here.** That milestone
## drives the real Electron front-end under Playwright in its own lane and
## COMMITS the answers to `src/tests/visual/answers/<scenario>.electron.json`;
## `test_cross_renderer_visual_alignment.nim` reads those files and never
## re-drives a browser. The reason is that the capture needs a capability the
## gate's process does not have, and the alternatives are worse in a specific
## way: a gate that could not run without the capability would be a gate that
## does not run, and a gate that SKIPPED without it would be the
## Silent-Self-Pass shape this campaign exists against.
##
## Here the capability is a compositor. PLAT-37's own risk block says every
## measurement to date is *"x86-64 on one dev workstation"*, that `/dev/dri`
## inside the `eph-linux-*` guests is unchecked and that arm64 is entirely
## unverified — so a gate that required a window to open in the process that
## asserts would be a gate whose ability to run is exactly the open question
## the milestone is `partial` on.
##
## ## What that costs, said plainly
##
## A recorded measurement is only as current as the run that took it, and
## nothing in a file says it was taken this week. So the record carries its own
## PROVENANCE — when it was written, on which host, against which `sway`,
## `ffmpeg` and `tesseract`, and from which manifest — and the gate PRINTS all
## of it and asserts it is present and non-empty. A capture that never ran
## leaves no record at all, which the gate turns into a named failure; a
## capture that ran last year leaves a record whose date is in the run's own
## output.
##
## And the live path is not given up: when `build/plat37/manifest.json` and its
## frames ARE on disk, the gate calls `measureCorpus` itself and asserts over
## the numbers it just took, printing `source=live` instead of
## `source=recorded`. One predicate, two sources, and the source is never
## silent.
##
## ## What it does NOT do
##
## It does not decide anything. Every threshold lives in
## `src/tests/visual/plat37-thresholds.json`, every comparison lives in the
## gate, and the rejected threshold candidates live in
## `ci/test/plat37_threshold_probe.nim`. This file measures.

import std/[json, os, times]

import ../../src/frontend/gpui/tests/plat37_vision

const
  ManifestRel = "build/plat37/manifest.json"
  OutRel = "src/tests/visual/plat37-measurements.json"

proc main() =
  if not fileExists(ManifestRel):
    quit("plat37 measure: " & ManifestRel & " is not here.\n" &
         "  Run `bash ci/test/plat37-window-frame.sh` first. This program " &
         "measures REAL captures;\n  a record written from a constructed " &
         "image would be a fixture measuring itself.", 1)
  let manifest = parseJson(readFile(ManifestRel))

  # `corpusRecord` AND NOT A LOOP HERE. It is the same function the gate calls
  # to build its LIVE corpus, so the recorded and the live shapes cannot
  # diverge — a field the recorder never wrote is a field the gate asserts for
  # free (§4).
  var record = corpusRecord(manifest)

  record["schemaVersion"] = %1
  record["milestone"] = %"PLAT-37"
  # THE PROVENANCE. A recorded capture with no date is a capture nobody can
  # age; PLAT-35's `answers/*.electron.json` carry the same block and the gate
  # prints it for the same reason.
  record["provenance"] = %*{
    "writtenAt": $now().utc,
    "manifest": absolutePath(ManifestRel),
    "host": manifest{"host"},
    "note": "Measured by ci/test/plat37_measure.nim from the manifest named " &
            "above. The gate re-measures from the same frames when they are " &
            "still on disk and prints `source=live`; otherwise it asserts " &
            "over these numbers and prints `source=recorded`.",
  }

  createDir(OutRel.parentDir)
  writeFile(OutRel, record.pretty & "\n")

  var captured = 0
  var total = 0
  for id, entry in record["runs"]["windowed"]:
    inc total
    if entry{"outcome"}.getStr == "captured": inc captured
  echo "plat37 measure: ", captured, " of ", total,
       " windowed run(s) carry a frame; wrote ", OutRel

when isMainModule:
  main()
