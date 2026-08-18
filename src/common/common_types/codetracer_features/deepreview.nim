## DeepReview data types for the CodeTracer GUI.
##
## These types map to the JSON export format produced by the ct-native-replay
## crate's ``json_export`` module. Field names use camelCase to match the
## JSON keys directly, so that Nim's ``cast[T](JSON.parse(...))`` pattern
## (used elsewhere in the frontend, e.g. for ``Diff``) works without any
## manual field-name mapping.
##
## Reference: codetracer-native-backend/src/deepreview/json_export.rs

type
  DeepReviewData* = ref object
    ## Top-level container for a complete DeepReview export.
    ##
    ## MISSING DATA — test results.  DeepReview-GUI.md §2.1 lists "Test
    ## results — tests run, passed, failed, and aggregate duration" among what
    ## the Agent Activity panel's DeepReview section shows, but this type
    ## carries no test-name, pass/fail or duration field anywhere, and neither
    ## does the exporter that produces it
    ## (``codetracer-native-backend/src/deepreview/json_export.rs``,
    ## ``DeepReviewData``).  A review launched from ``ct review`` over an
    ## exported dataset therefore has nothing to fill that row with, and the
    ## Agent Activity pane renders an explicit "not available for this
    ## dataset" state rather than a zeroed roll-up that would read as "all
    ## tests passed" (DR-R3 in
    ## ``codetracer-specs/DeepReview/DeepReview-GUI.milestones.org``).
    ##
    ## Closing the gap needs, in ``codetracer-native-backend``:
    ##   * a ``TestResultData { testName, passed, durationMs, traceContextId }``
    ##     record — the same four fields
    ##     ``Agentic-Coding-Integration.md`` §5.1's
    ##     ``DeepReviewUpdate::TestCompleted`` already streams during a live
    ##     agent session, so a dataset-backed review and a session-backed one
    ##     describe test runs identically;
    ##   * a ``testResults: Vec<TestResultData>`` field on the exported
    ##     ``DeepReviewData``, written by ``ct-rr-support deepreview collect``
    ##     from the runs it recorded;
    ##   * the mirrored ``testResults*: seq[DeepReviewTestResult]`` here, read
    ##     by ``vcs.reviewCoverageRows``' neighbour and pushed through
    ##     ``review_entry.populateReviewActivity``.
    ## Adjacent to M42b (``Pxor-Bugs.milestones.org``) — same repo, same
    ## neighbourhood — but a separate change: M42b is about loading the
    ## recordings, this is about carrying a fact the recordings already know.
    commitSha*: langstring
    baseCommitSha*: langstring
    collectionTimeMs*: int
    recordingCount*: int
    sessionTitle*: langstring
      ## Human-readable session title displayed in the header bar
      ## (e.g. "DeepReview: parser cleanup"). May be nil/empty.
    traceContexts*: seq[DeepReviewTraceContext]
      ## Available trace contexts for the review session. Each
      ## context maps to a different recording run. The first entry
      ## is selected by default.
    files*: seq[DeepReviewFileData]
    callTrace*: DeepReviewCallTrace
    session*: DeepReviewSessionRef
      ## RV-6 — the agent session that produced this dataset, or nil.
      ##
      ## **Optional.**  A dataset collected by a human, or by an agent
      ## whose backend cannot replay sessions, is a complete review; nil
      ## here is normal and is not an error (DeepReview-GUI.md §2.1).
      ##
      ## **A reference, never a transcript.**  See
      ## `DeepReviewSessionRef`'s own documentation for why.

  DeepReviewSessionRef* = ref object
    ## A pointer at the agent session a review dataset came from.
    ##
    ## DeepReview-GUI.md §2.1: "Loading is **by reference, never by
    ## copy**.  The dataset stores an identifier and enough context to
    ## resolve it; it does not embed a transcript."  Two consequences the
    ## shape of this type exists to guarantee:
    ##
    ##   * a dataset cannot go **stale** against the session it names — a
    ##     session that gained ten more turns after the dataset was
    ##     written reads back with all of them;
    ##   * no **conversation content** is duplicated into a file that may
    ##     be attached to a ticket, mailed around or committed, while the
    ##     session itself is behind whatever access control the agent
    ##     backend applies.
    ##
    ## Resolution happens through `nim-agents`
    ## (`AgentClient.loadSession`), which is why the fields below are
    ## exactly what that call needs and nothing more: the backend to
    ## speak, the id to ask for, and the workspace context an agent
    ## resolves a session against.  CodeTracer stores no session history
    ## of its own and must not start.
    sessionId*: langstring
      ## The backend's own id for the session.  Empty means "no
      ## reference", the same as a nil `DeepReviewSessionRef`.
    backend*: langstring
      ## `"acp"` or `"harbor"`.  Anything else is treated as `"acp"`,
      ## which is the backend that needs the most context and therefore
      ## fails loudest rather than silently reading the wrong thing.
    workspacePath*: langstring
      ## The directory the session ran in.  ACP agents resolve a session
      ## against a working directory, so this is what stops a session
      ## being replayed against a different tree — the "workspace is
      ## elsewhere" case §2.1 asks to be reported explicitly.
    taskId*: langstring
      ## Agent Harbor's task id, when the session belongs to one.  Empty
      ## for ACP.
    agentCommand*: langstring
      ## For `"acp"`: the stdio ACP binary to re-spawn in order to ask
      ## the agent for the session.  Empty means "the environment must
      ## supply it", and an unresolvable reference is reported rather
      ## than guessed at.
    agentArgs*: seq[langstring]
      ## Arguments for `agentCommand`.
    endpoint*: langstring
      ## For `"harbor"`: the base URL of the Agent Harbor instance that
      ## holds the session.

  DeepReviewSessionEvent* = ref object
    ## One entry of a **resolved** session's conversation.
    ##
    ## This type does *not* live in a review dataset — it is the shape
    ## `ct` hands the renderer after it has fetched the session from the
    ## backend, and it is a strict subset of `nim-agents`'
    ## `AgentEvent.toJson` so the two cannot drift.  It exists separately
    ## from `DeepReviewSessionRef` precisely to keep the "reference in
    ## the file, transcript only in memory" split visible in the types.
    kind*: langstring
    text*: langstring
    status*: langstring
    toolName*: langstring
    toolCallId*: langstring
    filePath*: langstring

  DeepReviewSessionTranscript* = ref object
    ## The outcome of resolving a `DeepReviewSessionRef`, as handed from
    ## `ct` to the renderer.
    ##
    ## `state` is the load result from `nim-agents`
    ## (`AgentSessionLoadState`): `"loaded"`, `"unsupported"` (the agent
    ## cannot replay sessions at all) or `"unavailable"` (this session
    ## could not be fetched — pruned, unknown, workspace elsewhere).  It
    ## travels *with* the events on purpose: without it, an empty
    ## `events` cannot be told from a failed fetch, and the panel would
    ## render "the agent did nothing" for both — the defect §2.1 names.
    state*: langstring
    sessionId*: langstring
    backend*: langstring
    message*: langstring
      ## The backend's own diagnostic for a non-`"loaded"` state.
    events*: seq[DeepReviewSessionEvent]

  DeepReviewFileData* = ref object
    ## Per-file data including symbols, coverage, flow, loops, and diff info.
    path*: langstring
    contentHash*: langstring
    sourceContent*: langstring
      ## Full source text of the file (new version for added/modified,
      ## old version for deleted). Used to expand context around diff
      ## hunks. May be empty/nil if the export did not include source.
    symbols*: seq[DeepReviewSymbol]
    coverage*: seq[DeepReviewLineCoverage]
    functions*: seq[DeepReviewFunctionCoverage]
    loops*: seq[DeepReviewLoop]
    flow*: seq[DeepReviewFunctionFlow]
    flags*: DeepReviewFileFlags
    diff*: DeepReviewFileDiff

  DeepReviewHunkLine* = ref object
    ## A single line within a diff hunk.
    ## ``type`` is one of "context", "added", "removed".
    ## ``oldLine`` / ``newLine`` are present depending on the line type:
    ## context lines have both, added lines only have ``newLine``,
    ## and removed lines only have ``oldLine``.
    `type`*: langstring
    content*: langstring
    oldLine*: int
    newLine*: int

  DeepReviewHunk* = ref object
    ## A contiguous diff hunk within a file.
    ## ``oldStart`` / ``oldCount`` refer to the base version line range.
    ## ``newStart`` / ``newCount`` refer to the new version line range.
    oldStart*: int
    oldCount*: int
    newStart*: int
    newCount*: int
    lines*: seq[DeepReviewHunkLine]

  DeepReviewFileDiff* = ref object
    ## Diff metadata for a file in the review.
    ## ``status`` is one of "A" (added), "M" (modified), "D" (deleted).
    ## ``linesAdded`` / ``linesRemoved`` count the changed lines.
    ## ``hunks`` contains the actual diff hunks with line-level data
    ## for unified diff rendering.
    status*: langstring
    linesAdded*: int
    linesRemoved*: int
    hunks*: seq[DeepReviewHunk]

  DeepReviewFileFlags* = ref object
    ## Boolean flags summarising the data availability and coverage
    ## status for a file.
    hasSymbols*: bool
    hasCoverage*: bool
    hasFlow*: bool
    isUnreachable*: bool
    isPartial*: bool

  DeepReviewSymbol* = ref object
    ## A symbol (function, variable, type, etc.) within a file.
    name*: langstring
    typeDesc*: langstring
    kind*: langstring
    visibility*: langstring
    startLine*: int
    endLine*: int

  DeepReviewLineCoverage* = ref object
    ## Coverage information for a single source line.
    line*: int
    executionCount*: int
    sampleCount*: int
    executed*: bool
    unreachable*: bool
    partial*: bool

  DeepReviewFunctionCoverage* = ref object
    ## Aggregated execution statistics for a function.
    name*: langstring
    startLine*: int
    endLine*: int
    callCount*: int
    executionCount*: int

  DeepReviewLoop* = ref object
    ## Loop metadata within a file.
    loopId*: int
    headerLine*: int
    startLine*: int
    endLine*: int
    totalIterations*: int

  DeepReviewFunctionFlow* = ref object
    ## A single execution trace of a function (one call/invocation).
    functionKey*: langstring
    executionIndex*: int
    steps*: seq[DeepReviewFlowStep]

  DeepReviewFlowStep* = ref object
    ## A single step in the execution flow of a function.
    ## ``rrTicks`` is safe as a JS ``int`` (Number) because JS integers
    ## are exact up to 2^53 and RR tick values do not exceed that range
    ## in practice.
    line*: int
    stepCount*: int
    rrTicks*: int
    loopId*: int
    iteration*: int
    values*: seq[DeepReviewVariableValue]

  DeepReviewVariableValue* = ref object
    ## A captured variable value at a specific execution step.
    name*: langstring
    value*: langstring
    kind*: langstring
    truncated*: bool

  DeepReviewCallTrace* = ref object
    ## Root of the call-trace tree.
    nodes*: seq[DeepReviewCallNode]

  DeepReviewCallNode* = ref object
    ## A node in the call-trace tree, representing a function and
    ## its callees.
    name*: langstring
    executionCount*: int
    children*: seq[DeepReviewCallNode]

  DeepReviewTraceContext* = ref object
    ## A selectable trace context that maps to a specific recording.
    ## Multiple trace contexts allow the user to switch between
    ## different runs (e.g. latest passing, previous failing) and
    ## see the overlay data (flow values, coverage) for that run.
    ##
    ## M-REC-3: ``recordingId`` was previously a dormant ``int`` named
    ## ``traceId`` (no consumer in the codebase set or read it).  The
    ## field is renamed and re-typed as a UUIDv7 string in lockstep
    ## with the wider recording-id migration so any future producer
    ## emits the canonical id directly.
    id*: int
    label*: langstring
    recordingId*: langstring
