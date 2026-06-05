## viewmodels/origin_chain_types.nim
##
## Plain-data value types for Value Origin Tracking on the ViewModel
## layer. Mirrors the wire shape produced by the M2 db-backend
## (`src/db-backend/src/task.rs` — `OriginChain`, `OriginHop`,
## `OriginSummary`, `TerminatorKind`, `OriginKind`,
## `FrameTransition`, `OperandSnapshot`).
##
## Decoupling the wire shape from the JS-only `frontend/dap.nim` /
## `frontend/types.nim` lets the ViewModel layer stay platform-neutral
## (`test-vm-native` + `test-vm-js`) and lets the headless tests assert
## directly on plain Nim objects.
##
## These types deliberately use `string` / `int` / `float` / `seq` /
## `Option[T]` so the same value compiles on both the JS renderer and
## the native unittest backends without `cstring` / `langstring`
## conversion noise.
##
## See spec sections (linked at every site):
## - §3.2.1 inline origin badge — `OriginSummary` powers it.
## - §3.2.2 expanded chain      — `OriginChain` / `OriginHop` power it.
## - §4.1 core types            — wire-shape mirror.
## - §5.3 DAP request           — `originChainArgs` / `originSummaryArgs`.

import std/[json, options, tables, hashes, strutils]

# Re-export ``std/options`` so downstream modules that import
# ``origin_chain_types`` reach ``Option`` / ``some`` / ``none`` /
# ``isSome`` / ``get`` without an extra ``import std/options`` line.
# This keeps host bridges in ``ui/state.nim`` legible without pulling
# the full ``std/options`` namespace into the legacy file (where the
# ``data`` global from ``frontend/types.nim`` lives).
export options


type
  # ---------------------------------------------------------------------
  # Closed enums mirror the wire-side serde enums in `task.rs`.
  # Wire JSON uses camelCase ASCII identifiers, so the helpers below do
  # case-insensitive matches and accept any of the spelling variations
  # the backend may emit while we drift through M2 → M4.
  # ---------------------------------------------------------------------
  TerminatorKindWire* = enum
    ## Wire-side terminator kind (spec §4.1 `TerminatorKindWire`).
    tkwUnknownSource         ## default — placeholder summaries land here
    tkwLiteral
    tkwComputational
    tkwParameterAtRecordStart
    tkwReadFromExternal
    tkwRecordingStart
    tkwUnknownVariable
    tkwDepthLimit
    tkwOutOfBudget

  OriginKind* = enum
    ## Per-hop classification (spec §4.1 `OriginKind`).
    okTrivialCopy
    okFieldAccess
    okIndexAccess
    okComputational
    okFunctionCall
    okLiteral
    okReturnCapture
    okFunctionReturn
    okParameterPass
    okCrossThreadCopy
    okUnknown

  FrameTransitionKind* = enum
    ## Per-hop frame-transition kind (spec §4.1 `FrameTransitionKind`).
    ftkParameterPass    ## ↘ entering callee
    ftkReturnCapture    ## ↗ returning to caller

  OperandSnapshot* = object
    ## Per-operand snapshot attached to Computational hops (spec §4.1).
    name*: string
    value*: string        ## pre-rendered textRepr of the value
    typeName*: string     ## original-language type name
    sourceStep*: int64    ## step the operand was sampled at

  FrameTransition* = object
    ## Per-hop frame-transition descriptor (spec §4.1).
    kind*: FrameTransitionKind
    fromFunction*: string
    toFunction*: string
    callKey*: int64

  OriginLocation* = object
    ## `(path, line)` of an origin hop. Mirrors db-backend
    ## `task::Location`. Column is omitted today; spec §4.1
    ## OriginHop.location.
    path*: string
    line*: int
    rrTicks*: uint64

  VariableId* = object
    ## Per-row identity used to track inline expansion state in
    ## `expandedOrigins`. Composite key `(name + scopePath)` keeps
    ## shadowed identifiers distinct.
    name*: string
    scopePath*: string

  OriginHop* = object
    ## One hop in the chain (spec §4.1 `OriginHop`).
    kind*: OriginKind
    targetExpr*: string
    sourceExpr*: string
    sourceVariable*: Option[string]
    location*: OriginLocation
    sourceText*: string
    stepId*: int64
    frameTransition*: Option[FrameTransition]
    operandSnapshots*: seq[OperandSnapshot]
    truncatedOperands*: bool
    confidence*: float
    classificationProvenance*: Option[string]

  Terminator* = object
    ## Final-hop descriptor surfaced in `OriginChain.terminator`
    ## (spec §4.1 `Terminator`).
    kind*: TerminatorKindWire
    expression*: string
    function*: Option[string]
    sourceLine*: Option[string]

  OriginMetrics* = object
    ## Per-chain metrics (spec §4.1 `OriginMetrics`).
    stepsScanned*: uint64
    elapsedMs*: uint64
    classifierHits*: uint32

  OriginChain* = object
    ## Canonical origin chain (spec §4.1 `OriginChain`).
    queryVariable*: string
    queryStepId*: int64
    hops*: seq[OriginHop]
    terminator*: Terminator
    truncated*: bool
    continuationToken*: Option[string]
    metrics*: OriginMetrics
    confidence*: float

  OriginSummary* = object
    ## Compact summary embedded in `ct/load-locals`,
    ## `ct/load-history`, `ct/load-flow`, watch responses (spec §4.1
    ## `OriginSummary`).
    terminatorKind*: TerminatorKindWire
    terminatorExpr*: string
    terminatorFunction*: Option[string]
    hopCount*: uint32
    confidence*: float
    isPlaceholder*: bool
    placeholderToken*: Option[string]

  BreadcrumbEntry* = object
    ## One `(variable, step)` entry in the breadcrumb stack
    ## (spec §3.3 navigation breadcrumbs).
    variableName*: string
    stepId*: int64

  ScratchpadChainEntry* = object
    ## Sibling variant of `ScratchpadValueEntry` for pinned origin
    ## chains (M4 deliverable §3.5 + spec §8.1 "Scratchpad data
    ## model (new entry kind)").
    chain*: OriginChain

  OriginExpressionStyle* = enum
    ## User preference `originBadge.expressionStyle` (spec §3.7).
    oesFull         ## middle-ellipsis preserving start + end
    oesAbbreviated  ## first ~16 chars
    oesHash         ## short SHA-style hash for ultra-narrow contexts

  OriginEagerMode* = enum
    ## Per-surface eager/placeholder/hidden tri-state mirroring
    ## the §3.7 `originDisplay.eagerMode.<surface>` preference.
    oemEager
    oemPlaceholder
    oemHidden

  OriginPaneSurface* = enum
    ## Surfaces enumerated in spec §3.2.3 V1 defaults table.
    opsStateLocals
    opsStateWatches
    opsHistoryPopover
    opsFlowOverlay
    opsScratchpad
    opsEditorHover

  OriginPreferences* = object
    ## In-memory preferences shared by every surface. Reads go through
    ## the same view-model layer that already serves "flow mode" /
    ## "auto-hide panes" preferences (spec §3.7 closing paragraph).
    showContainingFunctionInline*: bool   ## inline State-Pane default off
    showContainingFunctionPanel*: bool    ## side-panel default on
    expressionStyle*: OriginExpressionStyle
    eagerMode*: Table[OriginPaneSurface, OriginEagerMode]
    batchFillVisible*: bool
    batchFillThrottleMs*: int
    defaultMaxHops*: int
    collapseTrivialChainsThreshold*: int

# ---------------------------------------------------------------------------
# Equality + hashing — required so the wire-types compile under Nim's
# side-effect inference when carried inside `Signal[T]` / `HashSet[T]`.
# Match the pattern used by `ScratchpadValueEntry` / `FilesystemDiffEntry`
# in `store/types.nim`.
# ---------------------------------------------------------------------------

proc `==`*(a, b: OperandSnapshot): bool {.noSideEffect.} =
  a.name == b.name and a.value == b.value and
    a.typeName == b.typeName and a.sourceStep == b.sourceStep

proc `==`*(a, b: FrameTransition): bool {.noSideEffect.} =
  a.kind == b.kind and a.fromFunction == b.fromFunction and
    a.toFunction == b.toFunction and a.callKey == b.callKey

proc `==`*(a, b: OriginLocation): bool {.noSideEffect.} =
  a.path == b.path and a.line == b.line and a.rrTicks == b.rrTicks

proc `==`*(a, b: VariableId): bool {.noSideEffect.} =
  a.name == b.name and a.scopePath == b.scopePath

proc hash*(v: VariableId): Hash =
  var h: Hash = 0
  h = h !& hash(v.name)
  h = h !& hash(v.scopePath)
  !$h

proc `==`*(a, b: OriginHop): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  if a.targetExpr != b.targetExpr: return false
  if a.sourceExpr != b.sourceExpr: return false
  if a.sourceVariable != b.sourceVariable: return false
  if a.location != b.location: return false
  if a.sourceText != b.sourceText: return false
  if a.stepId != b.stepId: return false
  if a.frameTransition != b.frameTransition: return false
  if a.truncatedOperands != b.truncatedOperands: return false
  if a.confidence != b.confidence: return false
  if a.classificationProvenance != b.classificationProvenance: return false
  if a.operandSnapshots.len != b.operandSnapshots.len: return false
  for i in 0 ..< a.operandSnapshots.len:
    if a.operandSnapshots[i] != b.operandSnapshots[i]: return false
  true

proc `==`*(a, b: Terminator): bool {.noSideEffect.} =
  a.kind == b.kind and a.expression == b.expression and
    a.function == b.function and a.sourceLine == b.sourceLine

proc `==`*(a, b: OriginMetrics): bool {.noSideEffect.} =
  a.stepsScanned == b.stepsScanned and a.elapsedMs == b.elapsedMs and
    a.classifierHits == b.classifierHits

proc `==`*(a, b: OriginChain): bool {.noSideEffect.} =
  if a.queryVariable != b.queryVariable: return false
  if a.queryStepId != b.queryStepId: return false
  if a.terminator != b.terminator: return false
  if a.truncated != b.truncated: return false
  if a.continuationToken != b.continuationToken: return false
  if a.metrics != b.metrics: return false
  if a.confidence != b.confidence: return false
  if a.hops.len != b.hops.len: return false
  for i in 0 ..< a.hops.len:
    if a.hops[i] != b.hops[i]: return false
  true

proc `==`*(a, b: OriginSummary): bool {.noSideEffect.} =
  a.terminatorKind == b.terminatorKind and
    a.terminatorExpr == b.terminatorExpr and
    a.terminatorFunction == b.terminatorFunction and
    a.hopCount == b.hopCount and
    a.confidence == b.confidence and
    a.isPlaceholder == b.isPlaceholder and
    a.placeholderToken == b.placeholderToken

proc `==`*(a, b: BreadcrumbEntry): bool {.noSideEffect.} =
  a.variableName == b.variableName and a.stepId == b.stepId

proc `==`*(a, b: ScratchpadChainEntry): bool {.noSideEffect.} =
  a.chain == b.chain

# ---------------------------------------------------------------------------
# Constructors / helpers
# ---------------------------------------------------------------------------

const
  DEFAULT_ORIGIN_MAX_HOPS* = 16
    ## Spec §3.7 default for `originChain.defaultMaxHops` (mirrors
    ## the db-backend `DEFAULT_ORIGIN_MAX_HOPS` constant).
  DEFAULT_BATCH_FILL_THROTTLE_MS* = 100
    ## M4 deliverable default for `originDisplay.batchFillThrottleMs`.
    ## (Spec §3.7 quotes 250 ms; the M4 default is tighter to make
    ## scroll-triggered fills feel responsive — overridable by the
    ## user preference, see `OriginPreferences`.)
  DEFAULT_COLLAPSE_TRIVIAL_THRESHOLD* = 5
    ## Spec §3.7 default for `originChain.collapseTrivialChainsThreshold`.

proc defaultOriginPreferences*(): OriginPreferences =
  ## Defaults per the spec §3.2.3 V1 table + §3.7 preference rows.
  var eagerMode = initTable[OriginPaneSurface, OriginEagerMode]()
  eagerMode[opsStateLocals]    = oemEager
  eagerMode[opsStateWatches]   = oemEager
  eagerMode[opsHistoryPopover] = oemPlaceholder
  eagerMode[opsFlowOverlay]    = oemPlaceholder
  eagerMode[opsScratchpad]     = oemEager
  eagerMode[opsEditorHover]    = oemEager
  OriginPreferences(
    showContainingFunctionInline: false,
    showContainingFunctionPanel: true,
    expressionStyle: oesFull,
    eagerMode: eagerMode,
    batchFillVisible: true,
    batchFillThrottleMs: DEFAULT_BATCH_FILL_THROTTLE_MS,
    defaultMaxHops: DEFAULT_ORIGIN_MAX_HOPS,
    collapseTrivialChainsThreshold: DEFAULT_COLLAPSE_TRIVIAL_THRESHOLD,
  )

proc placeholderSummary*(token: string): OriginSummary =
  ## Convenience constructor for a placeholder badge.
  OriginSummary(
    terminatorKind: tkwUnknownSource,
    isPlaceholder: true,
    placeholderToken: some(token),
  )

# ---------------------------------------------------------------------------
# JSON → typed-value parsers. The backend emits camelCase keys; the
# parsers accept missing optional fields per the `#[serde(default)]`
# attributes on the Rust side so the frontend tolerates wire drift.
# ---------------------------------------------------------------------------

proc parseTerminatorKind*(s: string): TerminatorKindWire =
  ## Case-insensitive parse of the camelCase wire string. Unknown
  ## strings fall back to `UnknownSource` so the UI never crashes on
  ## a forward-compatibility serialisation.
  let normalised = s.toLowerAscii
  case normalised
  of "literal": tkwLiteral
  of "computational": tkwComputational
  of "parameteratrecordstart": tkwParameterAtRecordStart
  of "readfromexternal": tkwReadFromExternal
  of "recordingstart": tkwRecordingStart
  of "unknownvariable": tkwUnknownVariable
  of "depthlimit": tkwDepthLimit
  of "outofbudget": tkwOutOfBudget
  else: tkwUnknownSource

proc `$`*(k: TerminatorKindWire): string =
  case k
  of tkwUnknownSource: "unknownSource"
  of tkwLiteral: "literal"
  of tkwComputational: "computational"
  of tkwParameterAtRecordStart: "parameterAtRecordStart"
  of tkwReadFromExternal: "readFromExternal"
  of tkwRecordingStart: "recordingStart"
  of tkwUnknownVariable: "unknownVariable"
  of tkwDepthLimit: "depthLimit"
  of tkwOutOfBudget: "outOfBudget"

proc parseOriginKind*(s: string): OriginKind =
  let normalised = s.toLowerAscii
  case normalised
  of "trivialcopy": okTrivialCopy
  of "fieldaccess": okFieldAccess
  of "indexaccess": okIndexAccess
  of "computational": okComputational
  of "functioncall": okFunctionCall
  of "literal": okLiteral
  of "returncapture": okReturnCapture
  of "functionreturn": okFunctionReturn
  of "parameterpass": okParameterPass
  of "crossthreadcopy": okCrossThreadCopy
  else: okUnknown

proc `$`*(k: OriginKind): string =
  case k
  of okTrivialCopy: "trivialCopy"
  of okFieldAccess: "fieldAccess"
  of okIndexAccess: "indexAccess"
  of okComputational: "computational"
  of okFunctionCall: "functionCall"
  of okLiteral: "literal"
  of okReturnCapture: "returnCapture"
  of okFunctionReturn: "functionReturn"
  of okParameterPass: "parameterPass"
  of okCrossThreadCopy: "crossThreadCopy"
  of okUnknown: "unknown"

proc parseFrameTransitionKind*(s: string): FrameTransitionKind =
  ## Defaults to ParameterPass on unknown to avoid raising during
  ## reactive parsing. Wire shape is one of {"parameterPass",
  ## "returnCapture"}.
  if s.toLowerAscii == "returncapture": ftkReturnCapture
  else: ftkParameterPass

proc getOptString(j: JsonNode; key: string): Option[string] =
  if not j.isNil and j.kind == JObject and j.hasKey(key) and
     j[key].kind == JString:
    some(j[key].getStr)
  else:
    none(string)

proc getOptStr(j: JsonNode): Option[string] =
  if j.isNil or j.kind == JNull: none(string)
  elif j.kind == JString: some(j.getStr)
  else: none(string)

proc parseOriginLocation*(j: JsonNode): OriginLocation =
  if j.isNil or j.kind != JObject:
    return OriginLocation()
  result.path = j{"path"}.getStr("")
  result.line = j{"line"}.getInt(0)
  result.rrTicks = uint64(j{"rrTicks"}.getInt(0))

proc parseOperandSnapshot*(j: JsonNode): OperandSnapshot =
  if j.isNil or j.kind != JObject:
    return OperandSnapshot()
  result.name = j{"name"}.getStr("")
  let val = j{"value"}
  if not val.isNil and val.kind != JNull:
    if val.kind == JString:
      result.value = val.getStr
    else:
      result.value = $val
  let typeNode = j{"value"}{"typ"}{"langType"}
  if not typeNode.isNil and typeNode.kind == JString:
    result.typeName = typeNode.getStr
  result.sourceStep = int64(j{"sourceStep"}.getInt(0))

proc parseFrameTransition*(j: JsonNode): Option[FrameTransition] =
  if j.isNil or j.kind != JObject:
    return none(FrameTransition)
  some(FrameTransition(
    kind: parseFrameTransitionKind(j{"kind"}.getStr("parameterPass")),
    fromFunction: j{"fromFunction"}.getStr(""),
    toFunction: j{"toFunction"}.getStr(""),
    callKey: int64(j{"callKey"}.getInt(0)),
  ))

proc parseOriginHop*(j: JsonNode): OriginHop =
  if j.isNil or j.kind != JObject:
    return OriginHop()
  result.kind = parseOriginKind(j{"kind"}.getStr(""))
  result.targetExpr = j{"targetExpr"}.getStr("")
  result.sourceExpr = j{"sourceExpr"}.getStr("")
  result.sourceVariable = getOptStr(j{"sourceVariable"})
  result.location = parseOriginLocation(j{"location"})
  result.sourceText = j{"sourceText"}.getStr("")
  result.stepId = int64(j{"stepId"}.getInt(0))
  let ft = j{"frameTransition"}
  if not ft.isNil and ft.kind == JObject:
    result.frameTransition = parseFrameTransition(ft)
  let snapshots = j{"operandSnapshots"}
  if not snapshots.isNil and snapshots.kind == JArray:
    for n in snapshots:
      result.operandSnapshots.add(parseOperandSnapshot(n))
  result.truncatedOperands = j{"truncatedOperands"}.getBool(false)
  result.confidence = j{"confidence"}.getFloat(0.0)
  result.classificationProvenance = getOptStr(j{"classificationProvenance"})

proc parseTerminator*(j: JsonNode): Terminator =
  if j.isNil or j.kind != JObject:
    return Terminator()
  result.kind = parseTerminatorKind(j{"kind"}.getStr(""))
  result.expression = j{"expression"}.getStr("")
  result.function = getOptStr(j{"function"})
  result.sourceLine = getOptStr(j{"sourceLine"})

proc parseOriginMetrics*(j: JsonNode): OriginMetrics =
  if j.isNil or j.kind != JObject:
    return OriginMetrics()
  result.stepsScanned = uint64(j{"stepsScanned"}.getInt(0))
  result.elapsedMs = uint64(j{"elapsedMs"}.getInt(0))
  result.classifierHits = uint32(j{"classifierHits"}.getInt(0))

proc parseOriginChain*(j: JsonNode): OriginChain =
  if j.isNil or j.kind != JObject:
    return OriginChain()
  result.queryVariable = j{"queryVariable"}.getStr("")
  result.queryStepId = int64(j{"queryStepId"}.getInt(0))
  let hops = j{"hops"}
  if not hops.isNil and hops.kind == JArray:
    for n in hops:
      result.hops.add(parseOriginHop(n))
  result.terminator = parseTerminator(j{"terminator"})
  result.truncated = j{"truncated"}.getBool(false)
  result.continuationToken = getOptStr(j{"continuationToken"})
  result.metrics = parseOriginMetrics(j{"metrics"})
  result.confidence = j{"confidence"}.getFloat(0.0)

proc parseOriginSummary*(j: JsonNode): OriginSummary =
  if j.isNil or j.kind != JObject:
    return OriginSummary()
  result.terminatorKind = parseTerminatorKind(j{"terminatorKind"}.getStr(""))
  result.terminatorExpr = j{"terminatorExpr"}.getStr("")
  result.terminatorFunction = getOptStr(j{"terminatorFunction"})
  result.hopCount = uint32(j{"hopCount"}.getInt(0))
  result.confidence = j{"confidence"}.getFloat(0.0)
  result.isPlaceholder = j{"isPlaceholder"}.getBool(false)
  result.placeholderToken = getOptStr(j{"placeholderToken"})

# ---------------------------------------------------------------------------
# Outbound payload builders. Centralised here so every surface that
# fires a `ct/originChain` / `ct/originSummary` request emits the same
# camelCase JSON the backend expects.
# ---------------------------------------------------------------------------

proc originChainArgs*(expression: string;
                      stepId: int64 = -1;
                      frameId: int64 = -1;
                      threadId: int64 = 0;
                      maxHops: int = DEFAULT_ORIGIN_MAX_HOPS;
                      lazy: bool = false;
                      continuationToken: Option[string] = none(string);
                      sessionId: string = "";
                      classifySource: bool = true): JsonNode =
  ## Build the `ct/originChain` request body — see
  ## `task::CtOriginChainArguments` in `src/db-backend/src/task.rs`.
  result = %*{
    "variableName": expression,
    "variablePath": newSeq[string](),
    "frameId": frameId,
    "stepId": stepId,
    "threadId": threadId,
    "maxHops": maxHops,
    "lazy": lazy,
    "sessionId": sessionId,
    "classifySource": classifySource,
  }
  if continuationToken.isSome:
    result["continuationToken"] = %continuationToken.get

proc originSummaryArgs*(tokens: openArray[string]): JsonNode =
  ## Build the batched `ct/originSummary` request body — see
  ## `task::CtOriginSummaryArguments` in `src/db-backend/src/task.rs`.
  var arr = newJArray()
  for t in tokens:
    arr.add(%t)
  result = %*{"tokens": arr}

proc parseOriginSummariesResponse*(j: JsonNode): seq[OriginSummary] =
  ## Decode the response body of `ct/originSummary` (parallel array of
  ## filled summaries — see `task::CtOriginSummaryResponse`).
  result = @[]
  if j.isNil or j.kind != JObject:
    return
  let summaries = j{"summaries"}
  if summaries.isNil or summaries.kind != JArray:
    return
  for n in summaries:
    result.add(parseOriginSummary(n))

# ---------------------------------------------------------------------------
# Pure-logic helpers exercised by the headless tests
# ---------------------------------------------------------------------------

proc abbreviateExpr*(s: string; style: OriginExpressionStyle;
                     maxLen: int = 32): string =
  ## Apply the user `originBadge.expressionStyle` preference
  ## (spec §3.7). `full` uses a middle ellipsis; `abbreviated` keeps
  ## the first ~16 characters; `hash` emits a short SHA-style hash for
  ## ultra-narrow contexts. The legacy renderer applies the same
  ## function before painting the badge text so the user-visible string
  ## drifts in lock-step with the preference.
  if s.len == 0:
    return s
  case style
  of oesFull:
    if s.len <= maxLen: return s
    let keep = (maxLen - 1) div 2
    let tailStart = s.len - keep
    if keep <= 0 or tailStart <= keep + 1: return s
    s[0 ..< keep] & "…" & s[tailStart .. ^1]
  of oesAbbreviated:
    if s.len <= 16: return s
    s[0 ..< 16] & "…"
  of oesHash:
    # Short SHA-style — `hash[$Hash]` is deterministic and avoids
    # pulling crypto into the renderer. Eight hex digits is enough
    # for the ultra-narrow case (column < 64 px) the §3.7 cell
    # mentions.
    let h = hash(s)
    let asU = cast[uint](h)
    var hex = newStringOfCap(10)
    hex.add('#')
    for shift in countdown(28, 0, 4):
      let nibble = int((asU shr shift.uint) and 0xF.uint)
      const digits = "0123456789abcdef"
      hex.add(digits[nibble])
    hex

proc badgeTextForSummary*(summary: OriginSummary;
                          prefs: OriginPreferences;
                          atSidePanel: bool = false): string =
  ## Render the visible badge text per spec §3.2.1: the (possibly
  ## abbreviated) terminator expression, optionally followed by
  ## `@ <function_name>` when the relevant
  ## `originBadge.showContainingFunction` cell of §3.7 is on.
  if summary.isPlaceholder:
    return "[?]"
  result = abbreviateExpr(summary.terminatorExpr, prefs.expressionStyle)
  let wantFunction =
    if atSidePanel: prefs.showContainingFunctionPanel
    else: prefs.showContainingFunctionInline
  if wantFunction and summary.terminatorFunction.isSome and
     summary.terminatorFunction.get.len > 0:
    result &= " @ "
    result &= summary.terminatorFunction.get

proc iconClassForTerminator*(k: TerminatorKindWire): string =
  ## Return the SVG icon class corresponding to the terminator. The
  ## seven 14×14 SVGs ship under `src/frontend/assets/origin-icons/`
  ## (created by M4); CSS in the IsoNim view applies the matching
  ## class as a background-image url so the badge can be rendered with
  ## zero JS-side `<svg>` markup.
  case k
  of tkwComputational: "ct-origin-icon-sigma"
  of tkwLiteral: "ct-origin-icon-quotation"
  of tkwParameterAtRecordStart: "ct-origin-icon-door"
  of tkwReadFromExternal: "ct-origin-icon-globe"
  of tkwRecordingStart: "ct-origin-icon-clock-rewind"
  of tkwUnknownSource, tkwUnknownVariable: "ct-origin-icon-question"
  of tkwDepthLimit, tkwOutOfBudget: "ct-origin-icon-hourglass"

proc iconClassForKind*(k: OriginKind): string =
  ## Per-hop classification icon (spec §3.2.2 Line 1). Used in the
  ## in-row expanded chain.
  case k
  of okTrivialCopy: "ct-origin-icon-trivial"
  of okFieldAccess: "ct-origin-icon-field"
  of okIndexAccess: "ct-origin-icon-index"
  of okComputational: "ct-origin-icon-sigma"
  of okFunctionCall: "ct-origin-icon-function-call"
  of okLiteral: "ct-origin-icon-quotation"
  of okReturnCapture, okFunctionReturn: "ct-origin-icon-return"
  of okParameterPass: "ct-origin-icon-param"
  of okCrossThreadCopy: "ct-origin-icon-cross-thread"
  of okUnknown: "ct-origin-icon-question"

proc iconClassForFrameTransition*(k: FrameTransitionKind): string =
  ## Frame-transition arrow (spec §3.2.2 Line 1: ↘ entering callee,
  ## ↗ returning to caller).
  case k
  of ftkParameterPass: "ct-origin-icon-frame-enter"
  of ftkReturnCapture: "ct-origin-icon-frame-return"

const
  BadgeBaseClass* = "ct-origin-badge"
  BadgePlaceholderClass* = "ct-origin-badge-placeholder"
  BadgeIconClass* = "ct-origin-badge-icon"
  BadgeTextClass* = "ct-origin-badge-text"
  BadgeFunctionSuffixClass* = "ct-origin-badge-fn"
  BadgeIconOnlyClass* = "ct-origin-badge-icon-only"
    ## Modifier applied to the omniscience-flow overlay (spec §3.2.3
    ## row "Omniscience-Flow editor overlay" — icon-only badge).

proc ariaLabelForSummary*(summary: OriginSummary; prefs: OriginPreferences;
                          atSidePanel: bool = false): string =
  ## ARIA label for the badge button. Mirrors the visible badge text
  ## but adds a verbose prefix so screen-reader announcements are
  ## self-contained (spec §13.0). Pure helper — kept here so the
  ## renderer-agnostic IsoNim views can call it without pulling
  ## ``ui/origin_badge`` (which imports ``std/dom`` on the JS target).
  if summary.isPlaceholder:
    return "Resolve origin summary"
  let visible = badgeTextForSummary(summary, prefs, atSidePanel)
  "Value origin: " & visible

proc badgeClassFor*(summary: OriginSummary;
                    iconOnly: bool = false): string =
  ## Compute the full space-separated CSS class string for the badge
  ## button. Combines the base class, the per-terminator icon class,
  ## and the placeholder / icon-only modifiers. Pure helper.
  result = BadgeBaseClass
  if summary.isPlaceholder:
    result &= " "
    result &= BadgePlaceholderClass
    return
  if iconOnly:
    result &= " "
    result &= BadgeIconOnlyClass
  result &= " "
  result &= iconClassForTerminator(summary.terminatorKind)

proc tokenForSummary*(summary: OriginSummary): string =
  ## Return the placeholder token attached to a placeholder summary.
  ## Returns an empty string for fully-resolved summaries (the badge
  ## omits the `data-token` attribute for those).
  if summary.placeholderToken.isSome:
    summary.placeholderToken.get
  else:
    ""

proc keyToSurface*(key: string): Option[OriginPaneSurface] =
  ## Parse a `originDisplay.eagerMode.<surface>` preference key into a
  ## typed enum value. Used by the preferences plumbing so callers can
  ## subscribe to per-surface eagerness changes by enum rather than
  ## string.
  case key.toLowerAscii
  of "statelocals": some(opsStateLocals)
  of "statewatches": some(opsStateWatches)
  of "historypopover": some(opsHistoryPopover)
  of "flowoverlay": some(opsFlowOverlay)
  of "scratchpad": some(opsScratchpad)
  of "editorhover": some(opsEditorHover)
  else: none(OriginPaneSurface)
