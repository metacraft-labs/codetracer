## index/review_dataset.nim
##
## The **one** read of an exported review dataset, and the IPC handler that
## lets a running window ask for another one (AA-3).
##
## `ct review <PATH>` has always read the dataset here, in the Electron main
## process: `index/args.nim`'s `--deepreview` branch parsed the JSON and cast
## it to `DeepReviewData`, and `index/startup.nim` forwarded the result to the
## renderer.  AA-3 needs the same read at a different moment — a reviewer
## selecting an evidence tool call in the Agent Activity session feed
## (`codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1) — so the read
## moved here and `args.nim` calls it.  There is one reader, not two:
## "Selecting one enters a review over that dataset **through the ordinary
## review-entry routine**.  Not a second way to open a review; the same one,
## reached from the feed."
##
## Two other things belong to the main process and are therefore here:
##
##  * **path resolution**.  A review dataset is named either by its
##    `review.json` or by the directory `ct review collect --output` wrote it
##    into, and an agent's command line uses whichever it used.  `ct` resolves
##    that with `review_cli.resolveReviewDatasetJson`; the renderer cannot
##    call into `src/ct` (that module needs `std/osproc` and the native
##    backend), so `resolveReviewDatasetPath` below applies the same two
##    rules — the file as given, else `review.json` inside the directory.
##  * **keeping the main process's copy in step**.  `index/config`'s
##    `reviewSourceLookup` serves a reviewed file's text out of
##    `data.startOptions.deepReview`, so a window that switched datasets and
##    left this copy behind would open the *new* review's files and show the
##    *old* review's source.

import
  std / [ jsffi ],
  electron_vars, config,
  ../types,
  ../lib/[ jslib ],
  ../../common/ct_logging

type
  ReviewDatasetRead* = object
    ## The outcome of reading one dataset file.  A value rather than an
    ## exception because both callers have to *report* a failure rather than
    ## die of one: the launch path names the file the user typed, and the IPC
    ## path answers the panel so it can say the dataset is gone instead of
    ## entering an empty review.
    ok*: bool
    message*: cstring
      ## The reader's own diagnostic, never an invented one.  "" when `ok`.
    data*: DeepReviewData
    fileCount*: int
      ## How many files the dataset covers.  Meaningful only when `ok`; a
      ## genuine zero (an empty changeset) is a measurement and is rendered as
      ## "0 files", while an unreadable dataset carries `ok = false` and the
      ## panel prints no shape for it at all.
    commitSha*: cstring
      ## The reviewed commit, unabbreviated, or "" when the changeset names
      ## none.  A standalone patch has no commit, and an empty `commitSha` is
      ## absence rather than a value.

proc rawReadReviewDataset(path: cstring): JsObject {.importjs: """
(function (p) {
  var fs = require('fs');
  var pathModule = require('path');
  try {
    var resolved = p;
    if (fs.existsSync(p) && fs.statSync(p).isDirectory()) {
      resolved = pathModule.join(p, 'review.json');
    }
    if (!fs.existsSync(resolved)) {
      return { ok: false,
               message: 'no review dataset at ' + resolved,
               path: resolved,
               fileCount: 0,
               commitSha: '' };
    }
    var parsed = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    // The shape is read out here, where an absent key is simply `undefined`
    // and can be answered with the honest zero/empty.  A Nim-side `.len` on
    // a dataset that declares no `files` array would read `.length` off
    // `undefined` and take the main process down.
    var files = (parsed && parsed.files) || [];
    return { ok: true,
             message: '',
             path: resolved,
             fileCount: files.length,
             commitSha: (parsed && parsed.commitSha) || '',
             data: parsed };
  } catch (e) {
    return { ok: false,
             message: String((e && e.message) || e),
             path: p,
             fileCount: 0,
             commitSha: '' };
  }
})(#)
""".}
  ## Resolve, read and parse in one JS step.
  ##
  ## The happy path is byte-for-byte what `index/args.nim` did before AA-3 —
  ## `JSON.parse(fs.readFileSync(path, 'utf8'))`, whose result is cast
  ## straight to `DeepReviewData` because the exported field names are
  ## camelCase for exactly that reason (see the header of
  ## `common/common_types/codetracer_features/deepreview.nim`).  What is new
  ## is that a missing file and a malformed one come back as *values*.  They
  ## used to throw out of `parseArgs` and take the main process with them,
  ## which named neither the path nor the problem.

proc readReviewDatasetFile*(path: cstring): ReviewDatasetRead =
  ## Read the review dataset `path` names.
  ##
  ## `path` may be the `review.json` itself or the directory
  ## `ct review collect --output` wrote — the same two spellings
  ## `ct review <PATH>` accepts.
  let raw = rawReadReviewDataset(path)
  if not cast[bool](raw.ok):
    return ReviewDatasetRead(
      ok: false, message: cast[cstring](raw.message), data: nil,
      fileCount: 0, commitSha: cstring"")
  ReviewDatasetRead(
    ok: true, message: cstring"", data: cast[DeepReviewData](raw.data),
    fileCount: cast[int](raw.fileCount),
    commitSha: cast[cstring](raw.commitSha))

proc abbreviatedReviewCommit(sha: cstring): cstring =
  ## The dataset's commit, in the display form the VCS panel header uses
  ## (`review_entry.abbreviatedCommit`: twelve hex characters and an
  ## ellipsis), so the card and the header name a commit the same way.
  if sha.isNil or sha.len == 0:
    return cstring""
  let text = $sha
  if text.len > 12:
    cstring(text[0 ..< 12] & "...")
  else:
    sha

proc sendReviewDatasetRead(anchorId, datasetPath: cstring; kind: cstring;
                           ok: bool; message: cstring; fileCount: int;
                           commit: cstring; dataset: DeepReviewData) =
  if mainWindow.isNil:
    return
  mainWindow.webContents.send "CODETRACER::review-dataset-read", js{
    anchorId: anchorId,
    datasetPath: datasetPath,
    kind: kind,
    ok: ok,
    message: message,
    fileCount: fileCount,
    commit: commit,
    dataset: dataset
  }

proc onOpenReviewDataset*(sender: js,
    response: jsobject(anchorId=cstring, datasetPath=cstring, kind=cstring)) =
  ## Handler for ``CODETRACER::open-review-dataset`` (AA-3).
  ##
  ## `kind` is `review_open.ReviewDatasetRequestKind`, stringified:
  ##
  ##  * ``"inspect"`` — answer with the dataset's *shape* only.  The card
  ##    needs a file count and a commit to be "recognisable without opening
  ##    it" (§2.1.1), and that is all it needs; a dataset carries every
  ##    reviewed file's full source text, so shipping one across the process
  ##    boundary per evidence call would be paid on every session load.
  ##  * ``"open"`` — read it and hand the whole thing over, so the renderer
  ##    can enter a review through `vcs.openReviewDataset`.
  ##
  ## Every outcome is answered, including the failures: a click that produced
  ## silence would leave the card saying "Reading …" forever, which reads as
  ## a hang rather than as the missing file it is.
  let datasetPath = response.datasetPath
  let anchorId = response.anchorId
  let kind = if response.kind.isNil: cstring"inspect" else: response.kind
  if datasetPath.len == 0:
    errorPrint "onOpenReviewDataset: empty dataset path"
    sendReviewDatasetRead(anchorId, datasetPath, kind, false,
      cstring"No dataset path was given.", 0, cstring"", nil)
    return

  let read = readReviewDatasetFile(datasetPath)
  if not read.ok:
    infoPrint "index: review dataset unreadable at ", datasetPath
    sendReviewDatasetRead(anchorId, datasetPath, kind, false, read.message,
      0, cstring"", nil)
    return

  if kind == cstring"open":
    # The main process's own copy moves with the review, or
    # `index/config.reviewSourceLookup` would serve the previous dataset's
    # source text for the new review's files.
    data.startOptions.deepReview = read.data
    data.startOptions.withDeepReview = true

  sendReviewDatasetRead(anchorId, datasetPath, kind, true, cstring"",
    read.fileCount, abbreviatedReviewCommit(read.commitSha),
    if kind == cstring"open": read.data else: nil)
