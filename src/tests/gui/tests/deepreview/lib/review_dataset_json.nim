## The one decode of an exported review dataset, shared by the headless suites.
##
## ## Why this exists as a module rather than a proc in one test
##
## The renderer decodes a dataset with `cast[DeepReviewData](JSON.parse(...))`
## (`src/frontend/index/args.nim`), which is a JavaScript-only no-op cast: no
## native test can perform it, and it validates nothing, so there is no
## production routine a headless test could call to "read a dataset".  This is
## that cast written out field-for-field.
##
## RV-4 is what made it worth sharing.  There are now **two** collectors —
## `ct-native-replay review-data collect` for rr recordings and
## `replay-server review-collect` for materialized ones — and the milestone's
## deliverable is that the GUI reader accepts both.  A claim like that is only
## worth something if the *same* reader is fed both datasets, so the decode
## lives here and both `deepreview_entry_test.nim` (native-collector-shaped
## fixture) and `materialized_review_dataset_test.nim` (real materialized
## collector output) instantiate it.  Everything downstream of it —
## `reviewDatasetFrom`, `reviewHunksFor`, `enterReview` — is production code.
##
## ## What it decodes, and why all of it
##
## Every field the GUI type declares, including the ones no consumer reads
## today (`symbols`, `loops`, `functions`, `callTrace`).  A decoder that
## silently dropped them would let a collector write nonsense there and still
## pass "the reader accepts it", which is precisely the claim RV-4 needs to be
## true.  Absent keys decode to the zero value rather than raising, because
## that is what the renderer's cast does: an absent key is `undefined` in JS
## and reads as empty.  The `has*` helpers below let a test assert absence
## explicitly where absence is the point.

import std/json

import ../../../../../common/types as ct_types

export ct_types

proc decodeHunkLines(node: JsonNode): seq[ct_types.DeepReviewHunkLine] =
  result = @[]
  if node == nil or node.kind != JArray:
    return
  for line in node.items:
    result.add(ct_types.DeepReviewHunkLine(
      `type`: line{"type"}.getStr(""),
      content: line{"content"}.getStr(""),
      oldLine: line{"oldLine"}.getInt(0),
      newLine: line{"newLine"}.getInt(0)))

proc decodeDiff(node: JsonNode): ct_types.DeepReviewFileDiff =
  ## A file with no `diff` record is reported as modified with no counts —
  ## the same reading `reviewDatasetFrom` gives it — rather than dropped.
  if node == nil:
    return ct_types.DeepReviewFileDiff(status: "M", linesAdded: 0,
      linesRemoved: 0, hunks: @[])
  var hunks: seq[ct_types.DeepReviewHunk] = @[]
  if node.hasKey("hunks"):
    for hunk in node["hunks"].items:
      hunks.add(ct_types.DeepReviewHunk(
        oldStart: hunk{"oldStart"}.getInt(0),
        oldCount: hunk{"oldCount"}.getInt(0),
        newStart: hunk{"newStart"}.getInt(0),
        newCount: hunk{"newCount"}.getInt(0),
        lines: decodeHunkLines(hunk{"lines"})))
  ct_types.DeepReviewFileDiff(
    status: node{"status"}.getStr("M"),
    linesAdded: node{"linesAdded"}.getInt(0),
    linesRemoved: node{"linesRemoved"}.getInt(0),
    hunks: hunks)

proc decodeValues(node: JsonNode): seq[ct_types.DeepReviewVariableValue] =
  result = @[]
  if node == nil or node.kind != JArray:
    return
  for value in node.items:
    result.add(ct_types.DeepReviewVariableValue(
      name: value{"name"}.getStr(""),
      value: value{"value"}.getStr(""),
      kind: value{"kind"}.getStr(""),
      truncated: value{"truncated"}.getBool(false)))

proc decodeFlow(node: JsonNode): seq[ct_types.DeepReviewFunctionFlow] =
  result = @[]
  if node == nil or node.kind != JArray:
    return
  for entry in node.items:
    var steps: seq[ct_types.DeepReviewFlowStep] = @[]
    if entry.hasKey("steps"):
      for step in entry["steps"].items:
        steps.add(ct_types.DeepReviewFlowStep(
          line: step{"line"}.getInt(0),
          stepCount: step{"stepCount"}.getInt(0),
          rrTicks: step{"rrTicks"}.getInt(0),
          # `loopId` and `iteration` carry -1 for "not in a loop", so they are
          # read as signed rather than defaulted to 0, which would claim
          # iteration zero of loop zero.
          loopId: step{"loopId"}.getInt(-1),
          iteration: step{"iteration"}.getInt(-1),
          values: decodeValues(step{"values"})))
    result.add(ct_types.DeepReviewFunctionFlow(
      functionKey: entry{"functionKey"}.getStr(""),
      executionIndex: entry{"executionIndex"}.getInt(0),
      steps: steps))

proc decodeCallNodes(node: JsonNode): seq[ct_types.DeepReviewCallNode] =
  result = @[]
  if node == nil or node.kind != JArray:
    return
  for entry in node.items:
    result.add(ct_types.DeepReviewCallNode(
      name: entry{"name"}.getStr(""),
      executionCount: entry{"executionCount"}.getInt(0),
      children: decodeCallNodes(entry{"children"})))

proc decodeReviewDatasetJson*(fixture: string): ct_types.DeepReviewData =
  ## Decode `review.json` the way the renderer's cast does.
  ##
  ## Raises whatever `parseJson` raises for malformed input: a dataset that is
  ## not JSON is not a dataset, and a test that swallowed that would report a
  ## broken collector as an empty review.
  let node = parseJson(fixture)
  result = ct_types.DeepReviewData(
    commitSha: node{"commitSha"}.getStr(""),
    baseCommitSha: node{"baseCommitSha"}.getStr(""),
    collectionTimeMs: node{"collectionTimeMs"}.getInt(0),
    recordingCount: node{"recordingCount"}.getInt(0),
    sessionTitle: node{"sessionTitle"}.getStr(""),
    traceContexts: @[],
    files: @[],
    callTrace: ct_types.DeepReviewCallTrace(
      nodes: decodeCallNodes(node{"callTrace"}{"nodes"})))

  # RV-6 — the optional reference to the agent session that produced the
  # dataset.  Absent is the ordinary case and decodes to nil, which is what
  # the renderer's cast produces for a missing key; a *present* reference must
  # survive the reader intact, because the whole point is that the dataset
  # carries the id rather than the conversation.
  if node.hasKey("session") and node["session"].kind == JObject:
    let session = node["session"]
    var agentArgs: seq[string] = @[]
    for arg in session{"agentArgs"}.items:
      agentArgs.add arg.getStr("")
    result.session = ct_types.DeepReviewSessionRef(
      sessionId: session{"sessionId"}.getStr(""),
      backend: session{"backend"}.getStr(""),
      workspacePath: session{"workspacePath"}.getStr(""),
      taskId: session{"taskId"}.getStr(""),
      agentCommand: session{"agentCommand"}.getStr(""),
      agentArgs: agentArgs,
      endpoint: session{"endpoint"}.getStr(""))

  if node.hasKey("traceContexts"):
    for ctx in node["traceContexts"].items:
      result.traceContexts.add(ct_types.DeepReviewTraceContext(
        id: ctx{"id"}.getInt(0),
        label: ctx{"label"}.getStr(""),
        recordingId: ctx{"recordingId"}.getStr("")))

  if not node.hasKey("files"):
    return
  for file in node["files"].items:
    var coverage: seq[ct_types.DeepReviewLineCoverage] = @[]
    if file.hasKey("coverage"):
      for cov in file["coverage"].items:
        coverage.add(ct_types.DeepReviewLineCoverage(
          line: cov{"line"}.getInt(0),
          executionCount: cov{"executionCount"}.getInt(0),
          sampleCount: cov{"sampleCount"}.getInt(0),
          executed: cov{"executed"}.getBool(false),
          unreachable: cov{"unreachable"}.getBool(false),
          partial: cov{"partial"}.getBool(false)))

    var symbols: seq[ct_types.DeepReviewSymbol] = @[]
    if file.hasKey("symbols"):
      for symbol in file["symbols"].items:
        symbols.add(ct_types.DeepReviewSymbol(
          name: symbol{"name"}.getStr(""),
          typeDesc: symbol{"typeDesc"}.getStr(""),
          kind: symbol{"kind"}.getStr(""),
          visibility: symbol{"visibility"}.getStr(""),
          startLine: symbol{"startLine"}.getInt(0),
          endLine: symbol{"endLine"}.getInt(0)))

    var functions: seq[ct_types.DeepReviewFunctionCoverage] = @[]
    if file.hasKey("functions"):
      for function in file["functions"].items:
        functions.add(ct_types.DeepReviewFunctionCoverage(
          name: function{"name"}.getStr(""),
          startLine: function{"startLine"}.getInt(0),
          endLine: function{"endLine"}.getInt(0),
          callCount: function{"callCount"}.getInt(0),
          executionCount: function{"executionCount"}.getInt(0)))

    var loops: seq[ct_types.DeepReviewLoop] = @[]
    if file.hasKey("loops"):
      for entry in file["loops"].items:
        loops.add(ct_types.DeepReviewLoop(
          loopId: entry{"loopId"}.getInt(0),
          headerLine: entry{"headerLine"}.getInt(0),
          startLine: entry{"startLine"}.getInt(0),
          endLine: entry{"endLine"}.getInt(0),
          totalIterations: entry{"totalIterations"}.getInt(0)))

    let flagsNode = file{"flags"}
    result.files.add(ct_types.DeepReviewFileData(
      path: file{"path"}.getStr(""),
      contentHash: file{"contentHash"}.getStr(""),
      sourceContent: file{"sourceContent"}.getStr(""),
      symbols: symbols,
      coverage: coverage,
      functions: functions,
      loops: loops,
      flow: decodeFlow(file{"flow"}),
      flags: ct_types.DeepReviewFileFlags(
        hasSymbols: flagsNode{"hasSymbols"}.getBool(false),
        hasCoverage: flagsNode{"hasCoverage"}.getBool(false),
        hasFlow: flagsNode{"hasFlow"}.getBool(false),
        isUnreachable: flagsNode{"isUnreachable"}.getBool(false),
        isPartial: flagsNode{"isPartial"}.getBool(false)),
      diff: decodeDiff(file{"diff"})))

proc datasetDeclaresKey*(fixture: string; key: string): bool =
  ## Whether the dataset's top level actually carries `key`.
  ##
  ## The decoder above turns an absent key into a zero value, which is what the
  ## renderer does; a test that wants to assert a producer *omitted* a field
  ## (rather than wrote an empty one) needs to see the raw document.
  parseJson(fixture).hasKey(key)

proc decodeReviewSessionTranscript*(fixture: string):
    ct_types.DeepReviewSessionTranscript =
  ## Decode the resolved-session document `ct` hands the renderer
  ## (`--review-session`), the way `frontend/index/args.nim`'s cast does.
  ##
  ## It lives beside the dataset decode, and is deliberately *separate* from
  ## it: the dataset carries the reference, this carries the conversation, and
  ## the two are different files precisely so a shared dataset never carries
  ## the conversation (DeepReview-GUI.md §2.1).
  let node = parseJson(fixture)
  result = ct_types.DeepReviewSessionTranscript(
    state: node{"state"}.getStr(""),
    sessionId: node{"sessionId"}.getStr(""),
    backend: node{"backend"}.getStr(""),
    message: node{"message"}.getStr(""),
    events: @[])
  for event in node{"events"}.items:
    result.events.add ct_types.DeepReviewSessionEvent(
      kind: event{"kind"}.getStr(""),
      text: event{"text"}.getStr(""),
      status: event{"status"}.getStr(""),
      toolName: event{"toolName"}.getStr(""),
      toolCallId: event{"toolCallId"}.getStr(""),
      filePath: event{"filePath"}.getStr(""))
