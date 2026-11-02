## viewmodel/host/agent_session_files.nim — the files the Agent Activity pane
## reads, read by a NATIVE process (the terminal and the GPUI window).
##
## Two files, each read the way the desktop reads it, and each answered with
## an explicit state rather than an exception:
##
##   * the resolved agent session `ct review` hands a review window
##     (`ct/review_session.writeResolvedReviewSession`, passed as
##     `--review-session <path>`): the desktop's `index/args.nim` casts the
##     JSON to `DeepReviewSessionTranscript` and `review_session
##     .reviewSessionFrom` projects it; here the same projection runs over a
##     shape decoded from the same JSON, so the panel cannot read the file
##     differently on the two sides;
##   * a review dataset an evidence tool call names (AA-3): the desktop's main
##     process reads it with `index/review_dataset.readReviewDatasetFile` —
##     the path itself or the directory `ct review collect --output` wrote,
##     the shape (file count, commit) for a card, the whole dataset to enter a
##     review. `readDatasetShape` and `readReviewDataset` are that read; the
##     whole dataset goes through the production `review_entry
##     .reviewDatasetFrom`.

import std/[json, os]

import ../viewmodels/[evidence_call_vm, review_entry, review_session, vcs_vm]

const ReviewDatasetFileName* = "review.json"
  ## What `ct review collect --output DIR` writes beside its chunks.

# ---------------------------------------------------------------------------
# The resolved agent session
# ---------------------------------------------------------------------------

type
  TranscriptEvent = object
    kind, text, status, toolName, toolCallId, filePath: string
  Transcript = ref object
    ## `DeepReviewSessionTranscript`'s shape, as `reviewSessionFrom` reads it.
    state, sessionId, backend, message: string
    events: seq[TranscriptEvent]

proc transcriptOf(node: JsonNode): Transcript =
  result = Transcript(state: node{"state"}.getStr(""),
                      sessionId: node{"sessionId"}.getStr(""),
                      backend: node{"backend"}.getStr(""),
                      message: node{"message"}.getStr(""))
  let events = node{"events"}
  if events != nil and events.kind == JArray:
    for e in events:
      result.events.add TranscriptEvent(
        kind: e{"kind"}.getStr(""), text: e{"text"}.getStr(""),
        status: e{"status"}.getStr(""),
        toolName: e{"toolName"}.getStr(""),
        toolCallId: e{"toolCallId"}.getStr(""),
        filePath: e{"filePath"}.getStr(""))

proc parseReviewSessionJson*(text: string): ReviewSession =
  ## The session `text` (a resolved-session document) describes. A document
  ## that is not one reads as UNAVAILABLE with the reason — never as an empty
  ## loaded session, which would say the agent did nothing (§2.1).
  try:
    let node = parseJson(text)
    if node.kind != JObject:
      return ReviewSession(state: rssUnavailable,
                           message: "the session document is not an object")
    reviewSessionFrom(transcriptOf(node))
  except CatchableError as e:
    ReviewSession(state: rssUnavailable,
                  message: "the session document could not be read: " & e.msg)

proc readReviewSessionFile*(path: string): ReviewSession =
  if path.len == 0:
    return ReviewSession(state: rssAbsent)
  try:
    parseReviewSessionJson(readFile(path))
  except CatchableError as e:
    ReviewSession(state: rssUnavailable,
                  message: "could not read " & path & ": " & e.msg)

# ---------------------------------------------------------------------------
# Review datasets
# ---------------------------------------------------------------------------

proc resolveDatasetPath*(path: string): string =
  ## The JSON a dataset path names: the path itself, or `review.json` in the
  ## directory it names (the same two spellings `ct review <PATH>` takes).
  if dirExists(path): path / ReviewDatasetFileName else: path

type
  DatasetRead* = object
    ok*: bool
    message*: string
      ## The reader's own words when not ok.
    path*: string
    node*: JsonNode

proc readDatasetJson*(path: string): DatasetRead =
  let resolved = resolveDatasetPath(path)
  result.path = resolved
  if path.len == 0:
    result.message = "No dataset path was given."
    return
  if not fileExists(resolved):
    result.message = "no review dataset at " & resolved
    return
  try:
    result.node = parseJson(readFile(resolved))
    result.ok = true
  except CatchableError as e:
    result.message = e.msg

proc readDatasetShape*(path: string): EvidenceDataset =
  ## The card's answer about `path`: its file count and commit, or why it
  ## cannot be read.
  let read = readDatasetJson(path)
  if not read.ok:
    return EvidenceDataset(state: edsUnavailable, message: read.message)
  let files = read.node{"files"}
  EvidenceDataset(
    state: edsReady,
    fileCount: (if files != nil and files.kind == JArray: files.len else: 0),
    commit: abbreviatedCommit(read.node{"commitSha"}.getStr("")))

type
  JCoverage = object
    executed: bool
  JFlow = object
    functionKey: string
  JDiff = ref object
    status: string
    linesAdded, linesRemoved: int
  JFile = object
    path: string
    coverage: seq[JCoverage]
    flow: seq[JFlow]
    diff: JDiff
  JContext = object
    id: int
    label: string
  JDataset = ref object
    ## `DeepReviewData`'s shape, as `reviewDatasetFrom` reads it.
    sessionTitle, commitSha: string
    traceContexts: seq[JContext]
    files: seq[JFile]

proc datasetOf(node: JsonNode): JDataset =
  result = JDataset(sessionTitle: node{"sessionTitle"}.getStr(""),
                    commitSha: node{"commitSha"}.getStr(""))
  let contexts = node{"traceContexts"}
  if contexts != nil and contexts.kind == JArray:
    for c in contexts:
      result.traceContexts.add JContext(id: c{"id"}.getInt(0),
                                        label: c{"label"}.getStr(""))
  let files = node{"files"}
  if files != nil and files.kind == JArray:
    for f in files:
      var file = JFile(path: f{"path"}.getStr(""))
      let cov = f{"coverage"}
      if cov != nil and cov.kind == JArray:
        for c in cov:
          file.coverage.add JCoverage(executed: c{"executed"}.getBool(false))
      let flow = f{"flow"}
      if flow != nil and flow.kind == JArray:
        for fl in flow:
          file.flow.add JFlow(functionKey: fl{"functionKey"}.getStr(""))
      let d = f{"diff"}
      if d != nil and d.kind == JObject:
        file.diff = JDiff(status: d{"status"}.getStr(""),
                          linesAdded: d{"linesAdded"}.getInt(0),
                          linesRemoved: d{"linesRemoved"}.getInt(0))
      result.files.add file

proc readReviewDataset*(path: string): tuple[ok: bool, message: string,
                                             dataset: ReviewDataset] =
  ## The whole dataset, projected by the production `reviewDatasetFrom`.
  let read = readDatasetJson(path)
  if not read.ok:
    return (false, read.message, ReviewDataset())
  (true, "", reviewDatasetFrom(datasetOf(read.node)))
