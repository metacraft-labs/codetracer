## PLAT-39 — the domain types the two producers share.
##
## **NEITHER PRODUCER OWNS THESE TYPES.** `layout_extractors.ts` builds them out
## of the DOM; `vision_producer.nim` reconstructs them out of pixels. The types
## are the contract between them, which is what makes `LAW-R5` a real
## differential rather than a comparison of one module against itself.
##
## These mirror `src/tests/gui/page-objects/layout_models.ts` field for field.
## The mirroring is ASSERTED, not trusted: `test_screen_oracle.nim` parses the
## TypeScript interface declarations and compares the field-name sets in both
## directions, so a field added on either side fails the build. That is §7.1's
## two-way count applied to a type instead of to a table, and it is the
## mitigation for the stated risk that the two producers quietly stop being
## producers of one type.
##
## **WHY NOT GENERATE ONE FROM THE OTHER.** Because a generator makes the two
## sides one source, and `Verification-Harness-Traps.md` §30 is exactly the
## defect of two copies of one predicate: the comparison would then be
## guaranteed to agree and would measure nothing. Two hand-written declarations
## with an asserted correspondence is the shape that can actually disagree.

type
  VariableStateModel* = object
    name*: string
    valueType*: string
    value*: string

  ProgramStateModel* = object
    isVisible*: bool
    watchExpression*: string
    variableStates*: seq[VariableStateModel]

  EventDataModel* = object
    consoleOutput*: string

  EventLogModel* = object
    isVisible*: bool
    events*: seq[EventDataModel]
    ofRows*: int
    searchString*: string

  TracePointEditorModel* = object
    lineNumber*: int
    fileName*: string
    code*: string
    events*: seq[EventDataModel]

  EditorModel* = object
    isVisible*: bool
    # Spelled with the typo the TypeScript carries. The mirror assertion
    # compares NAMES, so "correcting" it here would fail the build — correctly,
    # because the two producers must answer in one vocabulary and this is the
    # vocabulary that exists. Renaming is a change to both sides at once, not a
    # tidy-up on one.
    higlitedLineNumber*: int
    tracePointEditorModels*: seq[TracePointEditorModel]

  CallRowModel* = object
    ## PLAT-40. One row of a call trace: the call's NAME, which is what every
    ## front-end draws and what survives a reading off the screen. Depth is
    ## indentation, which OCR discards, so it is not in the model.
    name*: string

  CalltraceModel* = object
    isVisible*: bool
    calls*: seq[CallRowModel]

  PointRowModel* = object
    ## PLAT-40. One row of the breakpoint and tracepoint list: its kind
    ## (`breakpoint` or `tracepoint`) and where it is, as the file's BASE name
    ## and the line — a pane draws the path at whatever width it has, so the
    ## directory part is what a reading cannot be sure of.
    kind*: string
    fileName*: string
    lineNumber*: int

  PointListModel* = object
    isVisible*: bool
    points*: seq[PointRowModel]

  LayoutPageModel* = object
    eventLogTabModels*: seq[EventLogModel]
    editorTabModels*: seq[EditorModel]
    programStateTabModels*: seq[ProgramStateModel]

  ModelKind* = enum
    ## The three declared model types, which are exactly `LayoutPageModel`'s
    ## three fields. The multiplier `3` in PLAT-39's counted target is this
    ## cardinality, and the suite asserts the two are the same fact rather than
    ## two numbers that happen to agree.
    mkProgramState = "ProgramStateModel"
    mkEventLog = "EventLogModel"
    mkEditor = "EditorModel"

const AllModelKinds* = [mkProgramState, mkEventLog, mkEditor]

func `==`*(a, b: VariableStateModel): bool =
  a.name == b.name and a.valueType == b.valueType and a.value == b.value

func `==`*(a, b: EventDataModel): bool =
  a.consoleOutput == b.consoleOutput

func `==`*(a, b: ProgramStateModel): bool =
  a.isVisible == b.isVisible and
    a.watchExpression == b.watchExpression and
    a.variableStates == b.variableStates

func `==`*(a, b: EventLogModel): bool =
  a.isVisible == b.isVisible and a.events == b.events and
    a.ofRows == b.ofRows and a.searchString == b.searchString

func `==`*(a, b: EditorModel): bool =
  a.isVisible == b.isVisible and
    a.higlitedLineNumber == b.higlitedLineNumber and
    a.tracePointEditorModels.len == b.tracePointEditorModels.len

func `==`*(a, b: CallRowModel): bool = a.name == b.name

func `==`*(a, b: CalltraceModel): bool =
  a.isVisible == b.isVisible and a.calls == b.calls

func `==`*(a, b: PointRowModel): bool =
  a.kind == b.kind and a.fileName == b.fileName and
    a.lineNumber == b.lineNumber

func `==`*(a, b: PointListModel): bool =
  a.isVisible == b.isVisible and a.points == b.points

func `$`*(v: VariableStateModel): string =
  v.name & ":" & v.value & " " & v.valueType

func `$`*(m: ProgramStateModel): string =
  result = "ProgramState(visible=" & $m.isVisible & ", vars=" &
    $m.variableStates.len
  for v in m.variableStates:
    result.add "\n    " & $v
  result.add ")"

func `$`*(m: EventLogModel): string =
  result = "EventLog(visible=" & $m.isVisible & ", events=" & $m.events.len &
    ", ofRows=" & $m.ofRows & ")"
  for e in m.events:
    result.add "\n    " & e.consoleOutput

func `$`*(m: EditorModel): string =
  "Editor(visible=" & $m.isVisible & ", highlighted=" &
    $m.higlitedLineNumber & ", tracePointEditors=" &
    $m.tracePointEditorModels.len & ")"

func `$`*(m: CalltraceModel): string =
  result = "Calltrace(visible=" & $m.isVisible & ", calls=" & $m.calls.len & ")"
  for c in m.calls:
    result.add "\n    " & c.name

func `$`*(m: PointListModel): string =
  result = "PointList(visible=" & $m.isVisible & ", points=" &
    $m.points.len & ")"
  for p in m.points:
    result.add "\n    " & p.kind & " " & p.fileName & ":" & $p.lineNumber
