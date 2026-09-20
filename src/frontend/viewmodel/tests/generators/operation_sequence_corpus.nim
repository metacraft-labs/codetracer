## operation_sequence_corpus.nim — PLAT-34's `DIFF-1` POPULATION: **thirty
## pinned operation sequences over PLAT-30's vocabulary.**
##
## NOT-A-TEST-LANE-FILE: the corpus and its constructor. The assertions are in
## `../unit/test_editor_front_end_differential.nim`.
##
## =========================================================================
## WHY THIS IS A DATA FILE WHOSE LENGTH THE SUITE ASSERTS
## =========================================================================
##
## PLAT-34: *"It is a data file whose length the suite asserts, for the same
## reason PLAT-31's task set is: a sequence corpus that shrinks to the demo is
## the shape this whole campaign is written against."* So
## `OperationSequenceCardinality` is a const the suite compares against the
## built list in both directions, and every row carries the family it belongs
## to so a family that quietly emptied is a set difference rather than a
## smaller number.
##
## =========================================================================
## §34 IN THIS POPULATION, NAMED BEFORE THE TABLE
## =========================================================================
##
## Seven milestones of this campaign have met §34 in a different place each
## time. Here it has **two** shapes and they pull in opposite directions:
##
## > **1. A sequence that does not exercise a divergent path compares two
## > front-ends that were never going to disagree.** `DIFF-1`'s first half is
## > true by construction once the milestone lands (§30, and PLAT-34's own
## > deliverable says so), so thirty sequences that all end in "the caret moved
## > one cluster" would be thirty green cells measuring one thing. The corpus
## > is therefore spread over SIX FAMILIES — motions, selections, edits, undo,
## > multi-cursor and the debugger-surface operations — with the per-family
## > count asserted as an equality, not as a floor.
##
## > **2. EVERY SEQUENCE MUST END IN A STATE BOTH FRONT-ENDS HAVE SOMETHING TO
## > DRAW.** PLAT-23 measured why this is a prerequisite rather than a nicety:
## > *"a Python program at line 1 genuinely has no locals, and the pane census
## > moved from `locals=0` to `locals=8` on that one change. Two empty editors
## > compare equal."* A sequence ending in `select-all` + `delete-selection`
## > leaves an empty document, two empty surfaces and a cell that cannot fail.
## > Nothing here empties a document, and the suite asserts the realised row
## > count on BOTH media rather than trusting the table.
##
## =========================================================================
## THE DOCUMENTS ARE THE CORPUS, THROUGH PLAT-30's SCENARIO FRAME
## =========================================================================
##
## `vocabulary_generator.scenarioDocs()` is eighteen documents built from §5's
## corpus clusters — a `def` line, an indented body, bracket pairs, a camel
## identifier, a commented line — with the landmarks an operation needs already
## measured on each. The rows below index into it and the suite asserts the
## index set covers every one of the nine §5 CLASSES, because a corpus of
## thirty sequences that all ran over ASCII would not distinguish a group
## motion that respects grapheme clusters from one that respects runes.
##
## Rows do not carry a start CARET as an offset. They carry a named landmark
## from the same scenario frame, so a document whose clusters move does not
## silently start a sequence in the middle of a cluster — which is the class
## `snap` exists for on the other side of that file.

import std/strutils

import ../../editing_core
import ./vocabulary_generator

type
  SeqFamily* = enum
    ## §2.2's own grouping of what a sequence EXERCISES, which is not the same
    ## as the category each step belongs to: an edit sequence is mostly
    ## motions with one operator at the end, and classifying it by its last
    ## step is what makes the per-family counts mean something.
    sfMove = "move"
    sfSelect = "select"
    sfEdit = "edit"
    sfUndo = "undo"
    sfMultiCursor = "multi-cursor"
    sfSurface = "debugger-surface"

  SeqStart* = enum
    ## Where a sequence begins, by name. Resolved against the scenario
    ## document's own measured landmarks rather than against an offset written
    ## here, because an offset written here is an offset that stops being on a
    ## cluster boundary the day the corpus changes.
    ssDocStart = "doc-start"
    ssLine1Mid = "line-1-mid"
    ssLine2Mid = "line-2-mid"
    ssCamelStart = "camel-start"
    ssParensInner = "parens-inner"

  OperationStep* = object
    name*: string
    args*: OpArgs

  OperationSequence* = object
    id*: string
    family*: SeqFamily
    docIndex*: int
      ## Into `scenarioDocs()`. The suite asserts the realised class coverage.
    start*: SeqStart
    steps*: seq[OperationStep]

const
  OperationSequenceCardinality* = 30
    ## **THE FLOOR'S LARGEST TERM, AND IT IS AN ASSERTED CARDINALITY.**
    ## §10.4: *"a sweep's multiplier must be an asserted cardinality, not a
    ## round number"*. The suite compares this against `len(operationSequences())`
    ## and against the sum of the per-family counts below, in both directions.

  PerFamilySequences*: array[SeqFamily, int] = [
    sfMove: 6,
    sfSelect: 5,
    sfEdit: 6,
    sfUndo: 5,
    sfMultiCursor: 4,
    sfSurface: 4,
  ]
    ## Six families, and the split is deliberately uneven rather than five
    ## each. Edits and motions are where the two front-ends' derivations
    ## differ most (one re-renders text, the other re-renders a caret row);
    ## the debugger-surface family is four because there are four such
    ## operations a sequence can end in and still have something to draw.

func st(name: string; args = OpArgs()): OperationStep =
  OperationStep(name: name, args: args)

proc operationSequences*(): seq[OperationSequence] =
  ## **THE THIRTY, PINNED.** The `docIndex` values walk 0 … 17 and wrap, so
  ## every one of the eighteen scenario documents is used at least once and
  ## the nine corpus classes are all reached; the suite asserts that rather
  ## than this comment claiming it.
  ##
  ## No row empties its document and no row ends on a refusal that leaves the
  ## state untouched — both are asserted, per row, from the run.
  result = @[]

  # --- sfMove: 6 -----------------------------------------------------------
  result.add OperationSequence(id: "move-word-walk", family: sfMove,
    docIndex: 0, start: ssCamelStart, steps: @[
      st"move-group-right", st"move-group-right", st"move-group-left"])
  result.add OperationSequence(id: "move-line-ladder", family: sfMove,
    docIndex: 1, start: ssDocStart, steps: @[
      st"move-line-down", st"move-line-down", st"move-line-end",
      st"move-line-start"])
  result.add OperationSequence(id: "move-subword-camel", family: sfMove,
    docIndex: 2, start: ssCamelStart, steps: @[
      st"move-subword-forward", st"move-subword-forward",
      st"move-subword-backward"])
  result.add OperationSequence(id: "move-doc-ends", family: sfMove,
    docIndex: 3, start: ssLine1Mid, steps: @[
      st"move-doc-end", st"move-doc-start", st"move-line-down"])
  result.add OperationSequence(id: "move-smart-home", family: sfMove,
    docIndex: 4, start: ssLine2Mid, steps: @[
      st"move-line-end", st"move-line-start-smart", st"move-char-right"])
  result.add OperationSequence(id: "move-bracket-hop", family: sfMove,
    docIndex: 5, start: ssParensInner, steps: @[
      st"move-matching-bracket", st"move-char-left", st"move-line-start"])

  # --- sfSelect: 5 ---------------------------------------------------------
  result.add OperationSequence(id: "select-word-extend", family: sfSelect,
    docIndex: 6, start: ssCamelStart, steps: @[
      st"select-group-right", st"extend-group-right"])
  result.add OperationSequence(id: "select-inner-parens", family: sfSelect,
    docIndex: 7, start: ssParensInner, steps: @[
      st"select-inner-parens", st"extend-char-right"])
  result.add OperationSequence(id: "select-line-then-shrink", family: sfSelect,
    docIndex: 8, start: ssLine1Mid, steps: @[
      st"select-line", st"simplify-selection", st"move-char-right"])
  result.add OperationSequence(id: "select-all-then-collapse", family: sfSelect,
    docIndex: 9, start: ssDocStart, steps: @[
      st"select-all", st"collapse-to-cursors", st"move-line-down"])
  result.add OperationSequence(id: "select-inner-word-flip", family: sfSelect,
    docIndex: 10, start: ssCamelStart, steps: @[
      st"select-inner-word", st"flip-selections"])

  # --- sfEdit: 6 -----------------------------------------------------------
  result.add OperationSequence(id: "edit-insert-then-move", family: sfEdit,
    docIndex: 11, start: ssLine1Mid, steps: @[
      st("insert-text", OpArgs(text: "Q")), st"move-char-left"])
  result.add OperationSequence(id: "edit-delete-word", family: sfEdit,
    docIndex: 12, start: ssCamelStart, steps: @[
      st"select-group-right", st"delete-selection", st"move-line-start"])
  result.add OperationSequence(id: "edit-indent-line", family: sfEdit,
    docIndex: 13, start: ssLine1Mid, steps: @[
      st"select-line", st"indent-selection", st"move-line-start"])
  result.add OperationSequence(id: "edit-split-and-join", family: sfEdit,
    docIndex: 14, start: ssLine1Mid, steps: @[
      st"split-line", st"join-lines"])
  result.add OperationSequence(id: "edit-upper-case-word", family: sfEdit,
    docIndex: 15, start: ssCamelStart, steps: @[
      st"select-group-right", st"upper-case", st"move-line-start"])
  result.add OperationSequence(id: "edit-blank-line-below", family: sfEdit,
    docIndex: 16, start: ssLine1Mid, steps: @[
      st"insert-blank-line-below", st"move-line-up"])

  # --- sfUndo: 5 -----------------------------------------------------------
  result.add OperationSequence(id: "undo-one-insert", family: sfUndo,
    docIndex: 17, start: ssLine1Mid, steps: @[
      st("insert-text", OpArgs(text: "Z")), st"undo"])
  result.add OperationSequence(id: "undo-then-redo", family: sfUndo,
    docIndex: 0, start: ssLine1Mid, steps: @[
      st("insert-text", OpArgs(text: "Z")), st"undo", st"redo"])
  result.add OperationSequence(id: "undo-past-a-delete", family: sfUndo,
    docIndex: 1, start: ssCamelStart, steps: @[
      st"select-group-right", st"delete-selection", st"undo"])
  result.add OperationSequence(id: "undo-selection-walk", family: sfUndo,
    docIndex: 2, start: ssLine1Mid, steps: @[
      st"select-line", st"move-line-down", st"undo-selection"])
  result.add OperationSequence(id: "undo-two-bursts", family: sfUndo,
    docIndex: 3, start: ssLine1Mid, steps: @[
      st("insert-text", OpArgs(text: "A")), st("insert-text", OpArgs(text: "B")),
      st"undo"])

  # --- sfMultiCursor: 4 ----------------------------------------------------
  result.add OperationSequence(id: "multi-cursor-below", family: sfMultiCursor,
    docIndex: 4, start: ssLine1Mid, steps: @[
      st"add-cursor-below", st"move-char-right"])
  result.add OperationSequence(id: "multi-cursor-above-and-keep",
    family: sfMultiCursor, docIndex: 5, start: ssLine2Mid, steps: @[
      st"add-cursor-above", st"keep-primary-selection", st"move-char-right"])
  result.add OperationSequence(id: "multi-cursor-insert", family: sfMultiCursor,
    docIndex: 6, start: ssLine1Mid, steps: @[
      st"add-cursor-below", st("insert-text", OpArgs(text: "#"))])
  result.add OperationSequence(id: "multi-cursor-rotate",
    family: sfMultiCursor, docIndex: 7, start: ssLine1Mid, steps: @[
      st"add-cursor-below", st"rotate-primary-cursor", st"move-line-start"])

  # --- sfSurface: 4 --------------------------------------------------------
  # The four debugger-surface operations PLAT-30 published that a sequence can
  # end in and still leave both media something to draw. They are HERE and not
  # folded into `sfEdit` because they change the SURFACE rather than the text,
  # which is the one family whose observable is the row's `mark` and not its
  # characters — and therefore the family a comparison of documents alone
  # cannot see.
  result.add OperationSequence(id: "surface-breakpoint", family: sfSurface,
    docIndex: 8, start: ssLine1Mid, steps: @[
      st"toggle-breakpoint", st"move-line-down"])
  result.add OperationSequence(id: "surface-tracepoint", family: sfSurface,
    docIndex: 9, start: ssLine2Mid, steps: @[
      st"toggle-tracepoint", st"move-line-up"])
  result.add OperationSequence(id: "surface-fold-and-unfold", family: sfSurface,
    docIndex: 10, start: ssLine1Mid, steps: @[
      st"fold", st"toggle-fold", st"move-line-down"])
  result.add OperationSequence(id: "surface-flow-overlay", family: sfSurface,
    docIndex: 11, start: ssLine1Mid, steps: @[
      st"toggle-flow-overlay", st"move-char-right"])

proc startOffsetOf*(d: ScenarioDoc; s: SeqStart): int =
  ## A named start, resolved against the document's own measured landmarks.
  ##
  ## `vocabulary_generator` already snapped every landmark to a cluster
  ## boundary when it built the document, so nothing here re-derives one —
  ## which is §30a's rule applied to a five-line helper: a second snapping
  ## walk would agree with the first for the same reason the first agrees with
  ## itself.
  case s
  of ssDocStart: 0
  of ssLine1Mid: d.marks.line1Mid
  of ssLine2Mid: d.marks.line2Mid
  of ssCamelStart: d.marks.camelStart
  of ssParensInner: d.marks.parensInner

proc realisedFamilies*(rows: openArray[OperationSequence]):
                      array[SeqFamily, int] =
  ## The per-family counts READ BACK off the built list.
  ##
  ## **THE CLASSIFIER IS NOT THE CONSTRUCTOR** (§34's third rule) only in the
  ## weak sense available here: the family is a field the row declares, so
  ## this counts declarations rather than re-deriving them. What makes the
  ## count evidence is the OTHER assertion the suite makes beside it — that
  ## each family's rows reach operations of the categories the family names,
  ## read from the run's recorded operation list. Counting alone would be the
  ## table agreeing with itself, and that is said here rather than left for a
  ## reader to notice.
  for row in rows:
    inc result[row.family]

proc describe*(row: OperationSequence): string =
  var names: seq[string] = @[]
  for s in row.steps:
    names.add s.name
  row.id & " [" & $row.family & "] " & names.join(" -> ")
