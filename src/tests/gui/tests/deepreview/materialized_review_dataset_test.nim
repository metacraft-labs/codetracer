## RV-4 — a materialized (CTFS) recording yields a dataset the GUI reader takes.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §1.1: "DeepReview is **not**
## an rr-only feature.  Every language that produces a materialized trace —
## Python, Ruby, JavaScript, Noir, and the rest — must be reviewable."  RV-3
## built the dispatch and refused the materialized arm; RV-4 fills it in with a
## collector in the db-backend.  This suite is the GUI half of that milestone's
## first two verification entries:
##
##   * *a materialized trace yields a dataset the GUI reader accepts* — the two
##     collectors' datasets are fed through **one** reader
##     (`lib/review_dataset_json.decodeReviewDatasetJson`, the renderer's
##     `cast[DeepReviewData](JSON.parse(...))` written out) and then through
##     **one** production projection (`review_entry.reviewDatasetFrom` and
##     `review_entry.enterReview`), and both must arrive at a usable review.
##     Two decoders would make the claim vacuous, which is why the decode moved
##     into a shared module for this milestone.
##   * *coverage and flow survive the round trip* — the numbers asserted below
##     are the ones the Noir program actually produced, checked at the
##     collector's own level by
##     `src/db-backend/tests/deepreview_materialized_collector_test.rs` and
##     re-checked here after they have been through JSON and the reader.  The
##     two ends of the round trip are asserted independently on purpose: a
##     collector that computed the right numbers and a reader that lost them
##     would pass either test alone.
##
## ## The fixtures
##
## `fixtures/materialized-review.json` is real output of the real materialized
## collector over a real Noir recording — see
## `fixtures/regenerate-materialized-review.sh`, which is the script that
## produced it and the only supported way to change it.  Nothing in it is
## hand-written.
##
## `fixtures/sample-review.json` is the native-collector-shaped dataset the rest
## of the DeepReview suites already use.  It is the *other* side of the
## comparison: the milestone asks that both collectors' output be accepted by
## the same reader, so both are run through the same code here.
##
## ## No mocks beyond `MockBackendService`
##
## `MockBackendService` is what every ViewModel test uses to construct a
## `ReplayDataStore`; there is no replay in this suite to mock.  The decode,
## the projection, the review-entry routine and the datasets are all real.

import std/[json, strutils, unittest]

import isonim/core/signals

import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_deepreview_vm, review_entry, vcs_vm]

import lib/review_dataset_json

proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "fixtures/"

const
  MaterializedReviewJson = staticRead(fixtureDirPath() & "materialized-review.json")
    ## What `replay-server review-collect` wrote for the Noir fixture.
  NativeReviewJson = staticRead(fixtureDirPath() & "sample-review.json")
    ## The native-collector-shaped dataset the other DeepReview suites use.

  ReviewedFile = "src/main.nr"
    ## The one file of the fixture's changeset.

type
  EnteredReview = object
    ## What a reviewer can observe once a review has started.
    rows: seq[VCSFileRow]
    headerTitle: string
    documents: seq[string]
    deepReviewMode: bool
    coveragePaths: seq[string]
    coverageSummary: AgentDeepReviewCoverageSummary
    reviewActive: bool
    testResultsAvailable: bool

proc enterFrom(dataset: ReviewDataset): EnteredReview =
  ## Run the production review-entry routine over a dataset, on fresh
  ## ViewModels, and record what a reviewer would see.  Same shape as
  ## `deepreview_entry_test.nim`'s helper, and deliberately so: if a
  ## materialized dataset needed a different entry path it would not be the
  ## same feature.
  let mock = newMockBackendService()
  let store = createReplayDataStore(mock.toBackendService())
  let activity = createAgentActivityDeepReviewVM(store)
  let vcs = createVCSVM()
  var documents: seq[string] = @[]
  discard enterReview(
    vcs, activity, dataset,
    proc(action: VCSOpenAction) =
      if action.documentKey notin documents:
        documents.add(action.documentKey),
    nil)
  result.rows = vcs.changedFiles.val
  result.headerTitle = vcs.headerTitle.val
  result.deepReviewMode = vcs.deepReviewMode.val
  result.documents = documents
  for row in activity.fileCoverage.val:
    result.coveragePaths.add(row.path)
  result.coverageSummary = activity.coverageSummary.val
  result.reviewActive = activity.reviewActive.val
  result.testResultsAvailable = activity.testResultsAvailable.val

proc withoutTheFieldsTheNativeExporterOmits(fixture: string): string =
  ## The materialized dataset, reduced to the fields the NATIVE exporter
  ## actually writes.
  ##
  ## `codetracer-native-backend/src/deepreview/json_export.rs` declares no
  ## `sessionTitle`, no `traceContexts`, no `files[].sourceContent` and no
  ## `files[].diff`, so a native dataset arrives at the reader with those keys
  ## ABSENT rather than empty — and neither `sample-review.json` nor any other
  ## committed fixture is missing them, because they are hand-written in the
  ## GUI type's full shape.  Deleting them from real collector output is the
  ## nearest thing to native output this machine can produce: collecting from
  ## rr for real needs a replay, which needs `perf_event_paranoid < 2`.
  let node = parseJson(fixture)
  node.delete("sessionTitle")
  node.delete("traceContexts")
  for file in node["files"].items:
    file.delete("sourceContent")
    file.delete("diff")
  $node

proc reviewedFile(data: DeepReviewData): DeepReviewFileData =
  for file in data.files:
    if file.path == ReviewedFile:
      return file
  raise newException(ValueError, "the fixture must carry " & ReviewedFile)

suite "RV-4: a materialized dataset is a dataset the GUI reader accepts":

  test "both collectors' datasets load through the same reader":
    ## The milestone's first verification entry, stated as the comparison it
    ## actually is: one decode, one projection, two producers.
    let materialized = reviewDatasetFrom(
      decodeReviewDatasetJson(MaterializedReviewJson))
    let native = reviewDatasetFrom(decodeReviewDatasetJson(NativeReviewJson))

    for dataset in [materialized, native]:
      check dataset.files.len > 0
      for file in dataset.files:
        check file.path.len > 0
        check file.baseName.len > 0
        # "M" / "A" / "D" / "R" — never an empty status, which the VCS panel
        # would render as a blank badge.
        check file.status in ["M", "A", "D", "R"]

    # …and the materialized side is the one that did not exist before RV-4.
    check materialized.files.len == 1
    check materialized.files[0].path == ReviewedFile
    check materialized.files[0].status == "M"
    check materialized.files[0].additions == 3
    check materialized.files[0].deletions == 2

  test "a dataset missing the fields the native exporter omits still opens a review":
    ## The asymmetry the milestone records, asserted rather than only written
    ## down: the two producers are not the same shape, so the reader must take
    ## a document with those four keys ABSENT — which is what every dataset the
    ## native collector writes looks like — and still reach a usable review.
    ## An absent key is `undefined` to the renderer's `cast`, and the decode
    ## reads it as empty; nothing downstream may require it.
    let native = withoutTheFieldsTheNativeExporterOmits(MaterializedReviewJson)
    check not datasetDeclaresKey(native, "sessionTitle")
    check not datasetDeclaresKey(native, "traceContexts")

    let data = decodeReviewDatasetJson(native)
    check data.sessionTitle == ""
    check data.traceContexts.len == 0
    check data.files[0].sourceContent == ""
    # A file with no diff record is read as modified with no counts, not
    # dropped from the changeset.
    check data.files[0].diff.status == "M"

    let entered = enterFrom(reviewDatasetFrom(data))
    check entered.reviewActive
    check entered.rows.len == 1
    check entered.rows[0].path == ReviewedFile
    # The overlay data is untouched by the missing fields: coverage is what
    # the recordings measured either way.
    check entered.coverageSummary.totalLinesCovered == 10

  test "a review entered from a materialized dataset opens its file and populates the panels":
    let entered = enterFrom(
      reviewDatasetFrom(decodeReviewDatasetJson(MaterializedReviewJson)))
    check entered.deepReviewMode
    check entered.reviewActive
    check entered.rows.len == 1
    check entered.rows[0].path == ReviewedFile
    # DeepReview-GUI.md §7 step 2: "the first modified file opens in the
    # editor".
    check entered.documents.len == 1
    check entered.documents[0].contains(ReviewedFile)
    check entered.coveragePaths == @[ReviewedFile]

  test "a materialized review reports the same absence of test results as any other":
    ## RV-4 deliverable 4, at the GUI end.  `DeepReviewData` carries no
    ## test-result field for either collector, and the Agent Activity pane
    ## renders "not available" rather than a zeroed roll-up that would read as
    ## "all tests passed" (DR-R3).  A new collector must not quietly change
    ## that into a measurement.
    let materialized = enterFrom(
      reviewDatasetFrom(decodeReviewDatasetJson(MaterializedReviewJson)))
    let native = enterFrom(
      reviewDatasetFrom(decodeReviewDatasetJson(NativeReviewJson)))
    check not materialized.testResultsAvailable
    check not native.testResultsAvailable

  test "the header names the reviewed commit, which the collector read from git":
    let data = decodeReviewDatasetJson(MaterializedReviewJson)
    # A real 40-hex commit pair, resolved by the collector with `git
    # rev-parse` — not a run of zeros, which is a real git object and would
    # read as one.
    check data.commitSha.len == 40
    check data.baseCommitSha.len == 40
    check data.commitSha != data.baseCommitSha
    check data.commitSha != repeat('0', 40)

    let entered = enterFrom(reviewDatasetFrom(data))
    check entered.headerTitle.contains(data.commitSha[0 ..< 12])

  test "the dataset names every recording it was collected from":
    let data = decodeReviewDatasetJson(MaterializedReviewJson)
    check data.recordingCount == 2
    check data.traceContexts.len == 2
    var labels: seq[string] = @[]
    var ids: seq[int] = @[]
    for ctx in data.traceContexts:
      labels.add(ctx.label)
      ids.add(ctx.id)
      # The recording directories are not UUIDs, so the collector claims no
      # recording id for them rather than passing a folder name off as one.
      check ctx.recordingId == ""
    check labels == @["run-1", "run-2"]
    check ids == @[0, 1]
    # …and the projection carries them into the VCS panel's selector, which is
    # only offered when there IS a choice (`vcs_vm.hasTraceContextChoice`).
    let dataset = reviewDatasetFrom(data)
    check dataset.traceContexts.len == 2
    check dataset.traceContexts[0].label == "run-1"

suite "RV-4: coverage and flow survive the round trip":

  test "coverage is the recording's real per-line execution counts":
    ## The Noir fixture's program, with the reviewed revision's line numbers:
    ##
    ##   1  fn scale(i: Field, x: Field) -> Field {
    ##   2      let scaled = i * x;
    ##   3      scaled
    ##   4  }
    ##   6  fn main(x: Field) {
    ##   7      let mut sum: Field = 0;
    ##   8      for i in 0..4 {
    ##   9          let contribution = scale(i as Field, x);
    ##  10          sum = sum + contribution;
    ##  11      }
    ##  12      assert(sum == 30);
    ##  13  }
    ##
    ## `scale` is called four times per run, so its body lines are executed
    ## four times; the loop header runs five times (four iterations plus the
    ## exit test); line 9 is the call site *and* the callee's entry, which the
    ## recorder reports twelve times.  The fixture holds TWO recordings of the
    ## same revision, so every count is doubled — the merge adds up, it does
    ## not average or overwrite.
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    var counts: seq[(int, int)] = @[]
    for cov in file.coverage:
      counts.add((cov.line, cov.executionCount))
    check counts == @[(1, 8), (2, 8), (4, 8), (7, 2), (8, 10), (9, 24),
                      (10, 8), (11, 8), (12, 2), (13, 2)]

    for cov in file.coverage:
      check cov.executed
      # A materialized trace records every step, so samples == executions.
      check cov.sampleCount == cov.executionCount
      # RV-4 deliverable 4: a trace can say "not observed"; it cannot say
      # "unreachable".  And both recordings ran the same revision with the same
      # input, so no line is covered by only some of them — a merge must not
      # mark a line partial merely because there is more than one recording.
      check not cov.unreachable
      check not cov.partial

    check file.flags.hasCoverage
    check not file.flags.isUnreachable
    check not file.flags.isPartial

  test "the coverage roll-up the Agent Activity pane shows is derived from it":
    let entered = enterFrom(
      reviewDatasetFrom(decodeReviewDatasetJson(MaterializedReviewJson)))
    # Ten covered lines and none uncovered: the collector only writes coverage
    # records for lines it observed, so every record in the dataset is a line
    # that ran.  A collector that padded the file with zero-count records would
    # show a coverage percentage here instead.
    check entered.coverageSummary.totalLinesCovered == 10
    check entered.coverageSummary.totalLinesUncovered == 0
    # One function traced, across two executions of it: `reviewDatasetFrom`
    # counts distinct function keys, not flow entries.
    check entered.coverageSummary.functionsTraced == 1

  test "flow carries each invocation, its steps, its loop and its values":
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    # One invocation of `main` per recording, and they are DISTINCT
    # invocations: the GUI's invocation selector keys on
    # `(functionKey, executionIndex)`, so a per-recording counter that restarted
    # at 0 would give two executions the same identity.
    check file.flow.len == 2
    var identities: seq[(string, int)] = @[]
    for entry in file.flow:
      identities.add((entry.functionKey, entry.executionIndex))
      check entry.steps.len == 20
    check identities == @[("main", 0), ("main", 1)]
    let flow = file.flow[0]
    check flow.functionKey == "main"
    check flow.executionIndex == 0
    check flow.steps.len == 20

    # The four iterations of the loop body, each carrying the values the
    # debugger would annotate the line with.
    var iterations: seq[int] = @[]
    var contributions: seq[string] = @[]
    for step in flow.steps:
      if step.line != 9:
        continue
      iterations.add(step.iteration)
      check step.loopId >= 0
      for value in step.values:
        if value.name == "contribution":
          contributions.add(value.value)
    check iterations == @[0, 1, 2, 3]
    # `i * x` for x = 5.
    check contributions == @["0", "5", "10", "15"]

    # Step positions are the trace positions a reviewer can jump to; on a
    # materialized trace `rrTicks` carries the step id, and they are ordered.
    var previous = -1
    for step in flow.steps:
      check step.rrTicks > previous
      previous = step.rrTicks

    check file.flags.hasFlow
    check file.loops.len == 1
    check file.loops[0].startLine == 8
    check file.loops[0].endLine == 11
    # Four iterations in each of the two recorded executions.
    check file.loops[0].totalIterations == 8

  test "the projection counts the traced function once, not once per step":
    let dataset = reviewDatasetFrom(
      decodeReviewDatasetJson(MaterializedReviewJson))
    check dataset.functionsTraced == 1
    check dataset.files[0].hasFlow
    check dataset.files[0].coveredLines == 10

suite "RV-4: the fields a materialized trace cannot fill are empty, not zeroed":

  test "symbols carry the ranges the recording knows and no invented metadata":
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    check file.flags.hasSymbols
    var named: seq[(string, int, int)] = @[]
    for symbol in file.symbols:
      named.add((symbol.name, symbol.startLine, symbol.endLine))
      check symbol.kind == "function"
      # A materialized trace records that a function ran, not its declared
      # type or its visibility.  Both are empty, never a plausible-looking
      # "private" that a reviewer would read as fact.
      check symbol.typeDesc == ""
      check symbol.visibility == ""
      # 0 is the "not known" sentinel for a 1-based line; the fixture knows
      # both ends of both functions, so neither may be 0 here.
      check symbol.startLine > 0
      check symbol.endLine > 0
    check named == @[("main", 6, 13), ("scale", 1, 4)]

  test "a function that was called but not reviewed reports its calls and no flow":
    ## The collector scopes flow to the calls whose own steps land on the
    ## diff's lines, so `scale` — introduced by the change but itself unchanged
    ## — has a real call count and no flow.  Reported as zero *executions*
    ## beside a non-zero *call count*, which is the distinction that keeps it
    ## readable as "not collected" rather than "never ran".
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    var scaleFound = false
    for function in file.functions:
      if function.name != "scale":
        continue
      scaleFound = true
      check function.callCount == 8
      check function.executionCount == 0
    check scaleFound

  test "the dataset carries no session title rather than one the collector invented":
    let data = decodeReviewDatasetJson(MaterializedReviewJson)
    check data.sessionTitle == ""
    # The key is written, not omitted: the renderer reads it with a `cast`, and
    # an omitted key would arrive as `undefined` rather than as an empty
    # string.
    check datasetDeclaresKey(MaterializedReviewJson, "sessionTitle")
    # …and the reader falls back to naming the commit, so the header is never
    # blank.
    let dataset = reviewDatasetFrom(data)
    check dataset.title.startsWith("Review: ")

  test "the reviewed source travels with the dataset":
    ## The native exporter writes no `sourceContent`; the materialized
    ## collector can, because it read the file it is reviewing.  It is what
    ## lets the unified-diff tab expand context around a hunk without the
    ## repository.
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    check file.sourceContent.contains("fn scale(i: Field, x: Field) -> Field")
    check file.sourceContent.contains("let contribution = scale(i as Field, x);")
    # SHA-256 hex of that content — 64 characters, and not a run of zeros.
    check file.contentHash.len == 64
    check file.contentHash != repeat('0', 64)

  test "the diff the review renders is the patch the collection was given":
    let file = reviewedFile(decodeReviewDatasetJson(MaterializedReviewJson))
    check file.diff.status == "M"
    check file.diff.linesAdded == 3
    check file.diff.linesRemoved == 2
    check file.diff.hunks.len == 1
    var kinds: seq[string] = @[]
    for line in file.diff.hunks[0].lines:
      kinds.add(line.`type`)
    check "added" in kinds
    check "removed" in kinds
    check "context" in kinds
    # Added lines carry a new-side number and no old-side one, which is what
    # `ui/editor.nim`'s diff decorations key off.
    for line in file.diff.hunks[0].lines:
      if line.`type` == "added":
        check line.newLine > 0
        check line.oldLine == 0
      elif line.`type` == "removed":
        check line.oldLine > 0
        check line.newLine == 0
