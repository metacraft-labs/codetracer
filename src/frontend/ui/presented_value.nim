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

# ---------------------------------------------------------------------------
# PLAT-12 — the checkout's per-type visualisers, read HERE and only here
# ---------------------------------------------------------------------------

var activeVisualisers: seq[Visualiser] = @[]
  ## The visualiser tier this session's checkout declared.
  ##
  ## ## WHY A MODULE-LEVEL `var` IS ADMISSIBLE HERE AND NOWHERE BELOW IT
  ##
  ## It is not admissible in the PIPELINE: `ci/test/value-presentation-boundary.sh`
  ## holds `common/value_presentation/`'s four core modules to `func`, and a
  ## module-scope `var` there would make every presentation impure — the one
  ## property PLAT-2 cannot trade. `PresenterSet` is a PARAMETER for that
  ## reason and `presenter.nim` has no registry.
  ##
  ## This module is the desktop's one DOOR, and it already holds exactly this
  ## shape for exactly this reason: `sessionLang` reads `data.trace.lang`,
  ## ambient session state, in one visible place, and everything below passes
  ## the answer as an argument. The visualiser list is the same kind of fact —
  ## a property of the open recording's checkout, not of the value — so it is
  ## read once, here, where a reader can see it, rather than threaded through
  ## six surfaces that would each have to remember to pass it.
  ##
  ## Private, so the only ways in are the two procs below.

proc setActiveVisualisers*(visualisers: seq[Visualiser]) =
  ## Install the tier for this session. Called when a recording opens and its
  ## checkout's `.codetracer/` has been read; `@[]` is the correct argument
  ## when it has not, and is the state every build is in until a caller
  ## supplies one.
  activeVisualisers = visualisers

proc activeVisualiserCount*(): int =
  ## How many rules are in force. For a diagnostics surface and for a caller
  ## that wants to say "no project definitions are loaded" rather than showing
  ## an empty list — the distinction `describeVisualisers` makes in words.
  activeVisualisers.len

proc valueProvenance*(presentation: Presentation): string =
  ## §5.4's "a user must be able to ask which visualiser rendered this value
  ## and get an answer", for the desktop.
  ##
  ## ## THE DESKTOP HAD NO AFFORDANCE FOR THIS, AND PLAT-9 RECORDED THAT
  ##
  ## The terminal's variables pane has named the winning presenter in its title
  ## row since PLAT-2's second pass; the desktop and the web did not, and a
  ## field only a test can reach does not satisfy a requirement about a reader.
  ## `ui/value.nim` puts this on the value span's `title`, which is the
  ## affordance a DOM already has for "what is this?" — hover, and it says.
  ##
  ## IT TAKES THE PRESENTATION RATHER THAN THE VALUE, so the answer describes
  ## the rendering the reader is looking at rather than a second one made for
  ## the purpose. The same value at two budgets is two byte strings, which is
  ## why `describeAttribution` prints the budget's name at all.
  let degradation = describeDegradation(presentation)
  if degradation.len == 0: describeAttribution(presentation)
  else: describeAttribution(presentation) & "\n" & degradation

proc sessionLang*(): Lang =
  ## The loaded recording's language.
  ##
  ## Defensive because `data.trace` is nil before a trace opens and several of
  ## the surfaces below render placeholder rows in that window.
  if data.isNil or data.trace.isNil: LangUnknown
  else: data.trace.lang

proc statePanelValue*(value: Value): Presentation =
  ## The state panel: a TREE, seven levels deep, 200 members per node.
  presentValue(value, StatePanelBudget, sessionLang(), activeVisualisers)

proc tracepointValue*(value: Value): Presentation =
  ## A tracepoint result row: ONE line.
  presentValue(value, TracepointBudget, sessionLang(), activeVisualisers)

proc eventLogValue*(value: Value): Presentation =
  ## The trace-log / event-log locals column: ONE line.
  presentValue(value, EventLogBudget, sessionLang(), activeVisualisers)

proc scratchpadValue*(value: Value): Presentation =
  ## A scratchpad row: ONE line, expandable into children.
  presentValue(value, ScratchpadBudget, sessionLang(), activeVisualisers)

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
  presentValue(value, FlowBudget, sessionLang(), activeVisualisers)

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
  presentValue(value, CalltraceArgBudget, sessionLang(), activeVisualisers)
