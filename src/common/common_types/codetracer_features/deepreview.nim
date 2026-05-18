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
