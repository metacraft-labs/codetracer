## DeepReview data types for the CodeTracer GUI.
##
## These types map to the JSON export format produced by the ct-rr-support
## crate's ``json_export`` module. Field names use camelCase to match the
## JSON keys directly, so that Nim's ``cast[T](JSON.parse(...))`` pattern
## (used elsewhere in the frontend, e.g. for ``Diff``) works without any
## manual field-name mapping.
##
## Reference: codetracer-rr-backend/src/deepreview/json_export.rs

type
  DeepReviewData* = ref object
    ## Top-level container for a complete DeepReview export.
    commitSha*: langstring
    baseCommitSha*: langstring
    collectionTimeMs*: int
    recordingCount*: int
    files*: seq[DeepReviewFileData]
    callTrace*: DeepReviewCallTrace

  DeepReviewFileData* = ref object
    ## Per-file data including symbols, coverage, flow, and loops.
    path*: langstring
    contentHash*: langstring
    symbols*: seq[DeepReviewSymbol]
    coverage*: seq[DeepReviewLineCoverage]
    functions*: seq[DeepReviewFunctionCoverage]
    loops*: seq[DeepReviewLoop]
    flow*: seq[DeepReviewFunctionFlow]
    flags*: DeepReviewFileFlags

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
