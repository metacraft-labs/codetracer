## ui/presented_value.nim — the desktop renderer's ONE door to PLAT-2's
## value-presentation pipeline.
##
## ## WHY A DOOR RATHER THAN SIX IMPORTS
##
## Before PLAT-2 the five desktop surfaces each reached
## `common_types/utils/text_representation.textRepr` directly, each with its own
## arguments, and each then did its own truncating: `flow.nim` measured the
## returned string's `.len` against `FLOW_VALUE_LIMIT` (and rendered the same
## value twice to do it), `state.nim` fell back to `$v` when `textRepr` returned
## "", `trace.nim` and `trace_log.nim` interpolated `<span class=error-trace>`
## into the value itself, and `scratchpad.nim` special-cased `Error` and
## `isLiteral` before delegating.
##
## The point of one door is that `ci/test/value-presentation-boundary.sh` can
## say a true thing about it: every desktop surface reaches the pipeline through
## this module and reaches nothing else, and the check is an import lint rather
## than a reviewer's memory.
##
## ## THE LANGUAGE IS READ HERE, EXPLICITLY, AND ONLY HERE
##
## `textRepr`'s default argument was `LangUnknown`, which made it read
## `common_lang.CURRENT_LANG` — a module-level `var` written by `ui_js.nim` when
## a session opens. Every desktop rendering therefore depended on ambient
## state, which is what PLAT-2's byte-identity requirement forbids and what
## `presentValue` no longer permits: its `lang` is a parameter with no ambient
## fallback.
##
## So the ambient read happens exactly once, HERE, in `sessionLang`, where it is
## visible — and it is a read of the loaded trace's own metadata rather than of
## a formatter's private global. Everything below passes it as an argument.

import ../types
import ../lang

func presentationClassName*(class: PresentationClass): string =
  ## The CSS class name the legacy `ValueComponent` DOM keys on.
  ##
  ## THE STRINGS ARE THE ONES ALREADY IN THE STYLESHEETS — `int`, `string`,
  ## `seq`, `instance`, `pointer`, `table`, `variant`, `enum`, `function`,
  ## `nil`, `empty` — so this is a change of SOURCE, not of markup: they used
  ## to come from `toLowerAscii($value.kind)` and from hand-written literals in
  ## `ui/value.nim`'s two `case` statements, and they now come from the same
  ## `PresentationClass` the terminal colours by.
  case class
  of pcInteger, pcHexLiteral: "int"
  of pcFloat: "float"
  of pcBoolean: "bool"
  of pcString: "string"
  of pcChar: "char"
  of pcEnum: "enum"
  of pcPointer: "pointer"
  of pcRecord: "instance"
  of pcSequence, pcByteBuffer: "seq"
  of pcTuple: "instance"
  of pcMap: "table"
  of pcVariant: "variant"
  of pcFunction: "function"
  of pcNone: "nil"
  of pcError: "error"
  of pcMedia: "media"
  of pcOpaque, pcUnknown: "empty"

proc sessionLang*(): Lang =
  ## The loaded recording's language.
  ##
  ## Defensive because `data.trace` is nil before a trace opens and several of
  ## the surfaces below render placeholder rows in that window.
  if data.isNil or data.trace.isNil: LangUnknown
  else: data.trace.lang

proc statePanelValue*(value: Value): Presentation =
  ## The state panel: a TREE, seven levels deep, 200 members per node.
  presentValue(value, StatePanelBudget, sessionLang())

proc tracepointValue*(value: Value): Presentation =
  ## A tracepoint result row: ONE line.
  presentValue(value, TracepointBudget, sessionLang())

proc eventLogValue*(value: Value): Presentation =
  ## The trace-log / event-log locals column: ONE line.
  presentValue(value, EventLogBudget, sessionLang())

proc scratchpadValue*(value: Value): Presentation =
  ## A scratchpad row: ONE line, expandable into children.
  presentValue(value, ScratchpadBudget, sessionLang())

proc flowValue*(value: Value): Presentation =
  ## A flow chip: ONE line, THIRTY CELLS.
  ##
  ## The 30 is `FLOW_VALUE_LIMIT`, moved into `surfaces.FlowBudget`. It used to
  ## be a CSS `max-width: 30ch` — a CLIP, not a truncation — so the whole
  ## rendering of a 600-entry mapping crossed into the DOM and was hidden by the
  ## browser. `Presentation.truncated` is now what decides whether the
  ## "view more" affordance appears, which is the same question asked of the
  ## presenter instead of re-derived by measuring a string the surface rendered
  ## twice.
  presentValue(value, FlowBudget, sessionLang())

proc callArgValue*(value: Value): Presentation =
  ## One call-trace argument chip: ONE line.
  ##
  ## This is the surface the FIRST pass of PLAT-2 missed. `ui/calltrace.nim`
  ## carried `safeCallArgText` — a thirty-line `case` over ten scalar
  ## `TypeKind`s with `else: ""` — and its output is written into the
  ## ViewModel store and, via "Add value to scratchpad", into the SCRATCHPAD,
  ## which was already on the pipeline. Two spellings of one value in one pane
  ## is the specific failure PLAT-2's risk section names, so the fix is
  ## migration and not a narrower claim.
  ##
  ## The behaviour CHANGES for containers, deliberately: `safeCallArgText`
  ## rendered a `Seq`, an `Instance`, a `Tuple`, a `Table`, a `Variant`, a
  ## `Pointer` or an `Enum` argument as the empty string, so those chips were
  ## blank. They now read the same as they do everywhere else.
  presentValue(value, CalltraceArgBudget, sessionLang())
