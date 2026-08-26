## `ct list` — the listing over every artifact kind CodeTracer holds (AS-4).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-4, second
## deliverable: "a recording and a review dataset should be recognisable in a
## list without opening them."
##
## Before AS-4 this command listed **recordings and nothing else** — it read
## `trace_index.all()` and printed the trace columns — so a review dataset that
## had been downloaded through `ct download` was on the machine, openable with
## `ct review`, and invisible to the only listing the CLI has.  That is not a
## cosmetic gap: a store that can hold two kinds and a listing that can show one
## is how the second kind becomes the one nobody maintains.
##
## The rows are built from the **artifact model** and rendered by
## `artifact_sharing.nim`, which is the same module `ct upload` and
## `ct download` render their views from, so what a listing calls a review
## dataset and what an upload calls one cannot diverge.  This module's whole job
## is the part that genuinely needs a filesystem: finding out what is here.

import std/[algorithm, json, os]

import
  ../../common/[ trace_index, paths ],
  ../online_sharing/artifact_sharing,
  logging

type
  ListFormat = enum FormatText, FormatJson
  ListTarget {.pure.} = enum Local, Remote

const
  ReviewDatasetJsonName = "review.json"
    ## The file `ct review collect` writes inside a dataset directory, and the
    ## evidence `classifyLocalArtifact` recognises a dataset by.  Named here
    ## rather than imported from the upload path so listing does not drag the
    ## sharing transport into every binary that can list.


proc parseListFormat(arg: string): ListFormat =
  if arg == "text":
    FormatText
  elif arg == "json":
    FormatJson
  else:
    errorMessage "error: expected --format text/json"
    quit(1)


proc parseListTarget(arg: string): ListTarget =
  if arg == "local":
    ListTarget.Local
  elif arg == "remote":
    ListTarget.Remote
  else:
    errorMessage "error: expected local or remote"
    quit(1)


proc localRecordingArtifacts(): seq[ArtifactListingRow] =
  ## Every recording in the local index, as artifacts of the recording kind.
  ##
  ## The tenant is deliberately left **empty**.  A locally recorded trace has
  ## no owning organisation, and filling in the model's default visibility
  ## would tell a user their recording is readable by an organisation that has
  ## never seen it — `ArtifactListingRow.accessLabel` says "local only" for
  ## exactly this case.
  result = @[]
  for trace in trace_index.all(test = false).reversed:
    let artifact = recordingArtifact(
      recordingId = $trace.recordingId,
      tenantId = "",
      program = $trace.program,
      langName = $trace.lang,
      byteSize = -1)
    # The locator is the recording id, which is what `ct replay` takes.
    result.add listingRow(artifact, locator = $trace.recordingId)


proc localReviewDatasetArtifacts(): seq[ArtifactListingRow] =
  ## Every review dataset `ct download` has unpacked, as artifacts of the
  ## review-dataset kind.
  ##
  ## Read from each dataset's own `review.json`, which is the same file
  ## `upload.reviewDatasetTarget` reads its metadata from — so a dataset is
  ## described in a listing by the same facts it is described by when it is
  ## shared.  A directory whose `review.json` is missing or unreadable is
  ## skipped rather than shown as an empty row: it is not a review dataset, and
  ## a listing is not the place to report a half-unpacked download.
  result = @[]
  let root = codetracerTraceDir / "review-datasets"
  if not dirExists(root):
    return
  var directories: seq[string] = @[]
  for entry in walkDir(root):
    if entry.kind == pcDir:
      directories.add entry.path
  # Newest first, matching the recording rows: the artifact id is a UUIDv7, so
  # descending lexicographic order IS descending creation order.
  directories.sort(SortOrder.Descending)
  for directory in directories:
    let jsonPath = directory / ReviewDatasetJsonName
    if not fileExists(jsonPath):
      continue
    var dataset: JsonNode
    try:
      dataset = parseJson(readFile(jsonPath))
    except CatchableError:
      continue
    let sessionNode = dataset{"session"}
    var fileCount = dataset{"files"}.getElems.len
    if fileCount == 0:
      fileCount = dataset{"fileCount"}.getInt()
    var recordingCount = dataset{"recordings"}.getElems.len
    if recordingCount == 0:
      recordingCount = dataset{"recordingCount"}.getInt()
    let artifact = reviewDatasetArtifact(
      artifactId = extractFilename(directory),
      tenantId = "",
      commitSha = dataset{"commitSha"}.getStr(dataset{"headCommit"}.getStr()),
      baseCommitSha = dataset{"baseCommitSha"}.getStr(
        dataset{"baseCommit"}.getStr()),
      byteSize = -1,
      fileCount = fileCount,
      recordingCount = recordingCount,
      sessionTitle =
        (if sessionNode.isNil: "" else: sessionNode{"title"}.getStr()))
    # The locator is the directory, which is what `ct review` takes.
    result.add listingRow(artifact, locator = directory)


proc localArtifactRows*(): seq[ArtifactListingRow] =
  ## Everything CodeTracer holds locally, of every declared kind.
  ##
  ## Recordings first, then review datasets, so the order is stable rather
  ## than dependent on how many of each there happen to be.  It is deliberately
  ## NOT an exhaustive `case` over `ArtifactKind`: a kind's *local storage
  ## layout* is not part of the model, and a kind that has no local landing
  ## place yet must not be forced to invent one to compile.  What is exhaustive
  ## is everything downstream of here — the row, the summary and the open
  ## command all come from `artifact_sharing.nim`.
  localRecordingArtifacts() & localReviewDatasetArtifacts()


proc listLocalArtifacts(format: ListFormat) =
  let rows = localArtifactRows()
  case format:
  of FormatText:
    if rows.len == 0:
      echo "No recordings or review datasets yet."
      echo "Record one with `ct record <PROGRAM>`, or open a shared link " &
        "with `ct download <LINK>`."
      return
    echo renderListing(rows)
  of FormatJson:
    echo listingJson(rows)


proc listCommand*(rawTarget: string, rawFormat: string) =
  # list [local/remote (default local)] [--format text/json (default text)]
  let target = parseListTarget(rawTarget)
  let format = parseListFormat(rawFormat)
  case target:
  of ListTarget.Local:
    listLocalArtifacts(format)
  of ListTarget.Remote:
    echo "error: unsupported currently!"
    # listRemoteArtifacts(format)
