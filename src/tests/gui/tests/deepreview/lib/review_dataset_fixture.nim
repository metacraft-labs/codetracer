## Write a review dataset, for suites whose subject is what happens *after*
## one exists.
##
## The sibling of `review_dataset_json.nim`, which reads a dataset the way the
## renderer does.  This writes one in the shape both collectors emit
## (`fixtures/sample-review.json` from the native collector,
## `fixtures/materialized-review.json` from the db-backend one), so a suite
## that needs "a dataset with these two files and this recording" does not
## have to hand-assemble a JSON document and get the field names subtly wrong.
##
## ## Why this is not a mock
##
## It produces *data*, not behaviour: no collector is simulated and no
## interface is stubbed.  The suites that use it — RV-7's evidence handoff and
## the agentic-coding M5/M6/M7 handoffs — assert what CodeTracer does with a
## dataset, and running a real collector to obtain one would make each of them
## a test of whether this machine has an rr replay or a recorder toolchain.
## That the *collectors* produce datasets of exactly this shape is asserted
## elsewhere, against their real output: `materialized_review_dataset_test.nim`
## reads a checked-in real collection, and
## `fixtures/regenerate-materialized-review.sh` is how that file is produced.
##
## The one thing this must not drift from is the field spelling, which is
## pinned by `review_dataset_json.nim` reading fixtures written by the real
## collectors.

import std/[json, os]

type
  FixtureHunkLine* = object
    ## One line of a file's diff.  `kind` is `DeepReviewHunkLine.type`'s
    ## vocabulary — "context", "added" or "removed" — and `content` carries
    ## the diff marker for the latter two, exactly as both collectors write
    ## it.
    kind*: string
    content*: string

  FixtureFile* = object
    path*: string
    status*: string
    linesAdded*: int
    linesRemoved*: int
    lines*: seq[FixtureHunkLine]

  FixtureRecording* = object
    ## A `traceContexts` entry: the recording a review can be read against.
    recordingId*: string
    label*: string

func hunkLine*(kind, content: string): FixtureHunkLine =
  FixtureHunkLine(kind: kind, content: content)

func fixtureFile*(path: string; lines: seq[FixtureHunkLine];
                  status = "M"): FixtureFile =
  ## A changed file whose add/remove counts are *derived* from its lines, so a
  ## fixture cannot claim a count its own diff contradicts.
  result = FixtureFile(path: path, status: status, lines: lines)
  for line in lines:
    case line.kind
    of "added": inc result.linesAdded
    of "removed": inc result.linesRemoved
    else: discard

func fixtureRecording*(recordingId, label: string): FixtureRecording =
  FixtureRecording(recordingId: recordingId, label: label)

proc reviewDatasetJson*(files: openArray[FixtureFile];
                        recordings: openArray[FixtureRecording];
                        sessionTitle = "Review fixture";
                        session: JsonNode = nil): JsonNode =
  ## A dataset document.  `session` is the optional RV-6 reference; omitted
  ## rather than written as null when absent, which is what
  ## `withSessionRef` does and what the reader distinguishes.
  var contexts = newJArray()
  for i, recording in recordings:
    contexts.add %*{
      "id": i,
      "label": recording.label,
      "recordingId": recording.recordingId
    }
  var fileNodes = newJArray()
  for file in files:
    var lines = newJArray()
    var oldLine = 1
    var newLine = 1
    for line in file.lines:
      var node = %*{"type": line.kind, "content": line.content}
      case line.kind
      of "added":
        node["oldLine"] = %0
        node["newLine"] = %newLine
        inc newLine
      of "removed":
        node["oldLine"] = %oldLine
        node["newLine"] = %0
        inc oldLine
      else:
        node["oldLine"] = %oldLine
        node["newLine"] = %newLine
        inc oldLine
        inc newLine
      lines.add node
    fileNodes.add %*{
      "path": file.path,
      "contentHash": "",
      "sourceContent": "",
      "diff": {
        "status": file.status,
        "linesAdded": file.linesAdded,
        "linesRemoved": file.linesRemoved,
        "hunks": [{
          "oldStart": 1,
          "oldCount": max(oldLine - 1, 0),
          "newStart": 1,
          "newCount": max(newLine - 1, 0),
          "lines": lines
        }]
      },
      "symbols": [],
      "coverage": [],
      "functions": [],
      "loops": [],
      "flow": [],
      "flags": {
        "hasSymbols": false, "hasCoverage": false, "hasFlow": false,
        "isUnreachable": false, "isPartial": false
      }
    }
  result = %*{
    "commitSha": "0000000000000000000000000000000000000000",
    "baseCommitSha": "1111111111111111111111111111111111111111",
    "collectionTimeMs": 0,
    "recordingCount": recordings.len,
    "sessionTitle": sessionTitle,
    "traceContexts": contexts,
    "files": fileNodes,
    "callTrace": {"nodes": []}
  }
  if session != nil:
    result["session"] = session

proc writeReviewDataset*(path: string; files: openArray[FixtureFile];
                         recordings: openArray[FixtureRecording];
                         sessionTitle = "Review fixture";
                         session: JsonNode = nil): string =
  ## Write a dataset and return the path — the same `review.json` name
  ## `ct review collect` writes, so `ct agent evidence <DIR>` resolves it the
  ## way it resolves a real collection's output.
  createDir(path.parentDir)
  writeFile(path, pretty(reviewDatasetJson(files, recordings, sessionTitle,
    session)))
  path
