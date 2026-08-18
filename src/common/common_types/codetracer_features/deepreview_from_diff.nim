## Assembling a review dataset from the structured diff a trace carries.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §1 lists three ways into a
## review, and the second is "open a trace that is associated with a diff".
## The association is `ct record --with-diff`, which writes `diff.json` into
## the trace's output folder (`ct/trace/multitrace.nim`, `addDiffToTrace`);
## `ct run` / `ct replay` then pass it as `--diff <path>`
## (`ct/trace/run.nim`), the index process parses it into
## `StartOptions.diff` (`frontend/index/args.nim`) and forwards it with
## `CODETRACER::trace-loaded` (`frontend/index/traces.nim`).
##
## Every stage of that pipeline already existed; the renderer used to drop the
## diff on the floor, so the launch method existed on paper only.  This module
## is the missing conversion: a structured `Diff` becomes the same
## `DeepReviewData` that `ct review` loads from disk and that the
## agentic handoff assembles from its session, so from the renderer's point of
## view the three launch paths differ only in where the dataset came from
## (§7: "All three entry points converge on the same routine").
##
## It lives in `common_types` rather than in the renderer because both of the
## types it maps between are `common_types` types: included once with
## `langstring = cstring` through `frontend/types` and once with
## `langstring = string` through `common/types`, it gives the renderer and the
## headless ViewModel tests the *same* projection code rather than two copies
## to keep in sync.
##
## What it cannot carry is coverage or flow: those come from a review dataset
## collected by `ct-rr-support deepreview collect`, and a `--with-diff`
## recording has only the diff.  A review opened this way is therefore a real,
## navigable changeset with an honestly empty coverage table rather than an
## invented one.

proc reviewLineKind(kind: DiffLineKind): langstring =
  ## `DeepReviewHunkLine.type` is documented as one of "context" / "added" /
  ## "removed"; `DiffLineKind` spells the same three as an enum.
  case kind
  of Added: langstring("added")
  of Deleted: langstring("removed")
  of NonChanged: langstring("context")

proc reviewFileStatus(change: FileChange): langstring =
  ## §3: "Diff status (`A` added, `M` modified, `D` deleted, `R` renamed)".
  case change
  of FileAdded: langstring("A")
  of FileDeleted: langstring("D")
  of FileRenamed: langstring("R")
  of FileChanged: langstring("M")

proc reviewDataForTraceDiff*(diff: Diff; title: string;
                            traceLabel = "recorded run";
                            recordingId = ""): DeepReviewData =
  ## Project a trace's associated structured diff into a review dataset.
  ##
  ## A structured `Diff` carries no summary counts, so each file's "+N -M"
  ## comes from counting the chunk lines themselves.  Line numbers are taken
  ## from the chunk, and the side a line does not exist on is left at 0, which
  ## is what `DeepReviewHunkLine` documents ("added lines only have
  ## `newLine`").
  ##
  ## The review has exactly one trace context, and it is the trace that is
  ## open: that recording *is* the run being reviewed.  A single context means
  ## the header's selector has nothing to choose between and stays hidden
  ## (`VCSVM.hasTraceContextChoice`), but the review still knows which run its
  ## data belongs to rather than resolving to "no context selected".
  result = DeepReviewData(
    commitSha: langstring(""),
    baseCommitSha: langstring(""),
    collectionTimeMs: 0,
    recordingCount: 1,
    sessionTitle: langstring(title),
    traceContexts: @[DeepReviewTraceContext(
      id: 0,
      label: langstring(traceLabel),
      recordingId: langstring(recordingId))],
    files: @[],
    callTrace: DeepReviewCallTrace(nodes: @[]))
  if diff.isNil:
    return
  for fileDiff in diff.files:
    if fileDiff.isNil:
      continue
    var hunks: seq[DeepReviewHunk] = @[]
    var additions = 0
    var deletions = 0
    for chunk in fileDiff.chunks:
      var lines: seq[DeepReviewHunkLine] = @[]
      for line in chunk.lines:
        case line.kind
        of Added: additions += 1
        of Deleted: deletions += 1
        of NonChanged: discard
        lines.add(DeepReviewHunkLine(
          `type`: reviewLineKind(line.kind),
          content: langstring(line.text),
          oldLine: if line.kind == Added: 0 else: line.previousLineNumber,
          newLine: if line.kind == Deleted: 0 else: line.currentLineNumber))
      hunks.add(DeepReviewHunk(
        oldStart: chunk.previousFrom,
        oldCount: chunk.previousCount,
        newStart: chunk.currentFrom,
        newCount: chunk.currentCount,
        lines: lines))
    # A deleted file's `currentPath` is empty in some producers, so the path
    # falls back to where the file used to be: a review row with no path at
    # all would be unclickable.
    let path =
      if ($fileDiff.currentPath).len > 0: fileDiff.currentPath
      else: fileDiff.previousPath
    result.files.add(DeepReviewFileData(
      path: path,
      contentHash: langstring(""),
      sourceContent: langstring(""),
      symbols: @[],
      coverage: @[],
      functions: @[],
      loops: @[],
      flow: @[],
      flags: DeepReviewFileFlags(),
      diff: DeepReviewFileDiff(
        status: reviewFileStatus(fileDiff.change),
        linesAdded: additions,
        linesRemoved: deletions,
        hunks: hunks)))
