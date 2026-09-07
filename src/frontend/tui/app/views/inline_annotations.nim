## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/inline_annotations.nim — CTUI-5. CodeTracer-TUI.md §3.3.2's
## "Inline Variable Annotations": the evaluated values at the current step,
## rendered beside the line they belong to, so a reader does not have to look
## across at the variables pane for an immediate value.
##
## ## THE FAILURE MODE IS A STALE ANNOTATION, AND EVERYTHING HERE IS SHAPED
## ## AROUND IT
##
## CTUI-5 names it: "annotations show the values the ViewModel reports at the
## current tick, and **clear** when stepping to a line with none. A stale
## annotation is the failure mode; the test asserts the clearing case
## explicitly."
##
## A stale annotation is worse than none, because it is indistinguishable from
## a correct one: `x: 42` beside a line where `x` is now 7 reads exactly like
## the truth. So this module is written as a PURE FUNCTION OF THE CURRENT
## TICK'S VALUES AND THE CURRENT LINE'S TEXT, with no state of any kind — no
## cache, no last-good value, no `var` at module scope. There is nothing here
## that can survive a step, which is the strongest form of "it clears" that a
## renderer can offer: not "it is cleared" but "there was never anywhere to
## keep it".
##
## `app/source_binding.nim` rebuilds the annotation list from
## `StateVM.currentVariables` on every frame for the same reason.
##
## ## WHICH VALUES BELONG TO A LINE
##
## The ViewModel layer reports the variables in scope at the stop; it does not
## report which of them the current STATEMENT touches. So the selection rule
## here is lexical: a variable is annotated on a line when its name appears on
## that line as a whole word. That is the same rule an editor's inline-value
## overlay uses, and it is stated as a rule rather than implied because it has
## two consequences a reader should know:
##
##   * a variable mentioned in a comment on the line is annotated — harmless,
##     and the alternative (parsing the line) would make the annotation depend
##     on the language having a grammar;
##   * a line that mentions no in-scope variable gets NO annotation, which is
##     precisely the clearing case CTUI-5 asks to be asserted. It is reachable
##     on the `calc` fixture at every `def`, `import` and bare `return` line.
##
## ## Truncation is explicit and lossy-marked
##
## An annotation is appended to the line's own text inside the pane's code
## column, so it competes for cells with the code. When it does not fit it is
## truncated with `…` — never dropped silently, because a value that vanished
## because the pane was narrow is indistinguishable from a value the debugger
## did not report.

import std/[strutils, unicode]

import isonim_tui

import ./styled_row

# `TerminalAmbiguousWidth` is the PINNED ambiguous-width policy. See
# `cellWidth` below: this front-end measures cells under one policy in one
# place, rather than under whatever `isonim_tui`'s `ambiguousWidth` threadvar
# happens to hold.
from ../formatters/type_formatters import TerminalAmbiguousWidth

type
  Annotation* = object
    ## One `name: value` pair as it will appear on screen.
    name*: string
    value*: string

const
  AnnotationOpen* = "/* "
  AnnotationClose* = " */"
    ## §3.3.2's own spelling: `/* x: 42, str: "ready" */`. A C-style comment
    ## whatever the language, because the point is that it is NOT part of the
    ## program — and a marker that changed per language would make the
    ## annotation look like code in the language that uses that marker.
  AnnotationSeparator* = ", "
  AnnotationEllipsis* = "…"
  AnnotationGap* = 2
    ## Cells between the end of the code and the start of the annotation.

  AnnotationStyle* = CellStyle(fg: "bright_black", italic: true)
    ## Muted and italic, so the annotation reads as commentary rather than as
    ## source. Distinct from the comment token class (`bright_black`, italic)
    ## ONLY by... nothing — and that is deliberate: an inline annotation IS a
    ## comment, visually, and §3.3.2 renders it as one. The pane distinguishes
    ## them by position, not by colour.

  MinAnnotationCells* = 8
    ## Below this there is no room for `/* x */` and the annotation is omitted
    ## entirely rather than rendered as a stub of a comment marker.

proc isWordChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc mentionsWord*(line, word: string): bool =
  ## Does `line` contain `word` delimited by non-word characters?
  ##
  ## Whole-word, not substring: `sum` must not match `summary`, and an
  ## annotation attached to the wrong identifier is a stale annotation by
  ## another route.
  if word.len == 0:
    return false
  var start = 0
  while true:
    let at = line.find(word, start)
    if at < 0:
      return false
    let beforeOk = at == 0 or not isWordChar(line[at - 1])
    let afterIdx = at + word.len
    let afterOk = afterIdx >= line.len or not isWordChar(line[afterIdx])
    if beforeOk and afterOk:
      return true
    start = at + 1

proc annotationsForLine*(lineText: string;
                         values: openArray[Annotation]): seq[Annotation] =
  ## The subset of `values` whose names appear on `lineText`, in the order
  ## `values` gave them.
  ##
  ## The ViewModel's order is kept rather than sorted, because
  ## `StateVM.currentVariables` reports arguments before locals and a reader
  ## scanning a line wants the same order twice running.
  result = @[]
  for v in values:
    if mentionsWord(lineText, v.name):
      result.add v

proc annotationText*(values: openArray[Annotation]): string =
  ## `/* x: 42, str: "ready" */`, or "" for no values.
  ##
  ## "" rather than `/* */` for the empty case: an empty comment on a line with
  ## no values is visual noise on most rows of most files, and the clearing
  ## case has to be observable as the ABSENCE of an annotation rather than as a
  ## different annotation.
  if values.len == 0:
    return ""
  var parts: seq[string] = @[]
  for v in values:
    parts.add v.name & ": " & v.value
  AnnotationOpen & parts.join(AnnotationSeparator) & AnnotationClose

func cellWidth(s: string): int =
  ## Cells, under the front-end's PINNED ambiguous-width policy.
  ##
  ## `displayWidth($r)` — the threadvar-reading spelling — was here until
  ## PLAT-2. It is the same divergence `type_formatters.TerminalAmbiguousWidth`
  ## records: `isonim_tui`'s no-policy overloads read
  ## `text/width.ambiguousWidth`, a thread-local anyone may set at runtime, so
  ## the number of cells a rendering was clipped at depended on mutable global
  ## state. `awNarrow` is both the library's default and the constant
  ## `terminalMeasure` pins, so nothing on screen moves; what changes is that
  ## the two cell measures this front-end uses can no longer disagree.
  ##
  ## THE STRING OVERLOAD, NOT THE `Rune` ONE, AND THAT IS NOT A STYLE CHOICE.
  ## `displayWidth($r, …)` is the only spelling that is MEASURABLY a no-op here.
  ## Swept over all 1 112 064 codepoints: `displayWidth($r, awNarrow)` agrees
  ## with the old `displayWidth($r)` on every one of them, while
  ## `displayWidth(r, awNarrow)` — the `Rune` overload — disagrees on
  ## TWENTY-SIX, U+1F1E6 … U+1F1FF, the regional indicators. The string overload
  ## runs the grapheme-cluster path and scores a lone flag letter 2; the `Rune`
  ## overload scores it 1. Neither is right for this loop, which iterates RUNES
  ## and so scores a two-letter flag 4 or 2 where the cluster is 2 — but
  ## changing WHICH way it is wrong is a rendering change, and moving off the
  ## threadvar is supposed not to be one. Making this loop cluster-correct is a
  ## separate change and needs its own test.
  for r in runes(s):
    result += max(1, displayWidth($r, TerminalAmbiguousWidth))

proc fitAnnotation*(text: string; room: int): string =
  ## `text` truncated to `room` cells, with `…` marking the loss.
  ##
  ## Returns "" when there is not room for a legible annotation at all
  ## (`MinAnnotationCells`), so a two-column remainder does not become `/`.
  ##
  ## ## THIS IS A TRUNCATION OF PRESENTER OUTPUT, AND IT IS RETAINED. WHY.
  ##
  ## PLAT-2's rule is "the presenter returns what fits; a surface never
  ## truncates afterwards", and `ci/test/value-presentation-boundary.sh` has a
  ## check (`budget-not-post-filter`) that fires on exactly this shape. This
  ## site is not in that gate's subject and would not pass it, so the reason it
  ## survives is written here rather than left to be discovered:
  ##
  ##   * WHAT IS CUT IS NOT A VALUE. `annotationText` above JOINS several
  ##     `name: value` pairs with `, ` and wraps the result in `/* */`. Each
  ##     `value` in it already came from the presenter at the `tui-row`
  ##     budget — the per-value truncation IS the budget's, and is not
  ##     duplicated here. What this cuts is the assembled COMMENT: the chrome,
  ##     the separators and however many pairs fit.
  ##   * THE BUDGET COULD NOT KNOW THE NUMBER. `room` is
  ##     `annotationRoom(codeWidth, renderedCells)` — what is left of the code
  ##     column AFTER the source line has been painted. It is not a property of
  ##     any value, it is a property of the line the value happens to sit
  ##     beside, and it is not known until the pane has drawn the code. A
  ##     `Budget` is resolved before the presenter runs.
  ##   * IT IS RUNE-INDEXED AND CELL-MEASURED, so it shares none of the defects
  ##     of the byte-indexed truncations PLAT-2's survey found: it cannot split
  ##     a UTF-8 sequence, and it cannot overrun the column by a wide glyph.
  ##
  ## If a second surface ever needs "clip a joined multi-value line to a width
  ## known only at paint time", that is a budget-shaped question and this
  ## should move into the pipeline. One is not a pattern.
  if text.len == 0 or room < MinAnnotationCells:
    return ""
  if cellWidth(text) <= room:
    return text
  var kept = ""
  var cells = 0
  let budget = room - cellWidth(AnnotationEllipsis)
  for r in runes(text):
    let w = max(1, displayWidth($r, TerminalAmbiguousWidth))
    if cells + w > budget:
      break
    kept.add $r
    cells += w
  kept & AnnotationEllipsis

proc annotationRoom*(codeWidth, renderedCells: int): int =
  ## Cells left for an annotation after the code has been drawn.
  ##
  ## `renderedCells` is what the pane ACTUALLY painted, which is the line
  ## clipped to the code column — not the line's own width. The two differ
  ## exactly when the code fills the column, and taking the second would put
  ## the annotation's start column past the pane's right edge while computing
  ## its room from a width the pane never drew. Exposed so a test can compute
  ## the same number the pane did instead of re-deriving it.
  codeWidth - max(0, renderedCells) - AnnotationGap

proc annotationSpan*(lineText: string; values: openArray[Annotation];
                     codeWidth, renderedCells: int): StyledSpan =
  ## The annotation for one line, as one styled span, or an empty span.
  ##
  ## `codeWidth` is the pane's whole code column and `renderedCells` is how
  ## much of it the code took; the annotation gets what is left after
  ## `AnnotationGap`. A caller renders the span immediately after the code,
  ## which is what "directly beside the expressions on the current line" means
  ## in a terminal.
  ##
  ## NAME MATCHING IS AGAINST THE WHOLE LINE, not against the clipped part. A
  ## variable whose name sits past the pane's right edge is still a variable
  ## this statement touches, and dropping it would make the annotation depend
  ## on the terminal's width in a way a reader cannot see.
  let selected = annotationsForLine(lineText, values)
  let text = annotationText(selected)
  if text.len == 0:
    return StyledSpan(text: "", style: AnnotationStyle)
  let fitted = fitAnnotation(text, annotationRoom(codeWidth, renderedCells))
  StyledSpan(text: fitted, style: AnnotationStyle)
