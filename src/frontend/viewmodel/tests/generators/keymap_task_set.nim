## keymap_task_set.nim — PLAT-31's `DIFF-4` POPULATION: forty editing tasks,
## each expressed in BOTH keymaps.
##
## NOT-A-TEST-LANE-FILE: the task set and its constructor. The assertions are
## in `../unit/test_editor_keymap_differential.nim`.
##
## =========================================================================
## WHAT A TASK IS, AND WHY THE TWO KEY SEQUENCES ARE PART OF THE DATA
## =========================================================================
##
## A task is *a start document and an end document* — PLAT-31's own words —
## plus the two key sequences that are supposed to get from one to the other.
## Both sequences are HERE, in the row, rather than derived: the whole of
## `DIFF-4` is that two different paths reach one end, and a row that carried
## one sequence and derived the other would be the comparison asking one
## implementation twice (§30).
##
## =========================================================================
## §34 IS THIS MILESTONE'S MOST LIKELY TRAP AND IT IS IN THE POPULATION
## =========================================================================
##
## Six milestones of this campaign have now met §34 in a different place each
## time — the inputs, the landmarks, the parameters, the draws. Here it has one
## specific shape, and it is worth naming before the table rather than after:
##
## > **A task set in which both keymaps use the SAME key sequence compares a
## > thing with itself.**
##
## `d w` typed under the Vim keymap and `d w` typed under the Kakoune keymap
## would agree about the end document for a reason that has nothing to do with
## either keymap being right — and forty such rows are forty green cases that
## measured nothing at all. So:
##
##   * every row's two sequences are asserted **DISTINCT**, as an equality on
##     the count (`40 of 40`), not as a spot check;
##   * the rows whose two OPERATION sequences also differ are counted and the
##     count asserted as an equality against `DivergentOperationTasks`, because
##     two distinct KEY sequences can still drive one operation sequence (a
##     task using only keys both models spell the same way in the same order),
##     and that class is the one the differential is actually about.
##
## The second is the sharper of the two and is the one a reader should dispute
## first: it is what distinguishes *"the two keymaps are two tables"* from
## *"the two keymaps take different paths"*.
##
## **AND IT CAUGHT THREE ROWS ON ITS FIRST RUN.** The count was written as the
## whole set — *"it is the whole set today"* — before any of it had been
## executed. Three of the forty-one drive ONE operation sequence from two
## distinct key sequences, and they are named in `CoincidentOperationTasks`
## with the reason. A §34 mechanism whose own number was assumed rather than
## measured is the trap wearing the clothes of the check for it, which is
## worth recording here rather than quietly correcting.
##
## =========================================================================
## THE DOCUMENTS ARE THE CORPUS, THROUGH PLAT-30's SCENARIO FRAME
## =========================================================================
##
## PLAT-31: *"A task set over ASCII cannot distinguish a word motion that
## respects grapheme clusters from one that respects runes."* The eighteen
## scenario documents of `vocabulary_generator.nim` are corpus clusters framed
## in structure — which is the resolution PLAT-30 already paid for, and
## re-deriving a second framing here would be a second population to keep
## true. The landmarks come with them.

import std/strutils

import ./vocabulary_generator

import ../../keymap/editing_keymap

export vocabulary_generator
export editing_keymap

type
  TaskFamily* = enum
    ## What each row is FOR. Carried so the suite can assert each family is
    ## non-empty: a task set that drifted into forty operator-plus-motion rows
    ## would satisfy every count in this file and would not contain a single
    ## composed command with a count, which is the shape PLAT-31's risk section
    ## says gets approximated.
    tfOperatorMotion = "operator+motion"
    tfObject = "object"
    tfCount = "composed with a count"
    tfRegister = "register"
    tfCommand = "command"

  TaskCaret* = enum
    ## Where the task starts. A named landmark of the scenario document, never
    ## a literal offset — `vocabulary_generator.Landmarks`'s own rule.
    tcLine0Mid, tcLine1Mid, tcLine2Mid
    tcCamelStart, tcCamelMid, tcCamelEnd
    tcParensInner, tcBracketsInner, tcDoubleInner, tcTagInner

  EditingTask* = object
    id*: string
    family*: TaskFamily
    caret*: TaskCaret
    vimKeys*: seq[string]
    kakouneKeys*: seq[string]
    note*: string

const
  TaskSetCardinality* = 41
    ## **THE ONE TERM IN PLAT-31's FLOOR THAT IS CHOSEN RATHER THAN DERIVED**,
    ## and it is declared here so it can grow and cannot silently shrink. The
    ## milestone's words: *"the task set is a data file whose length is
    ## checked, so it can grow but cannot silently shrink to the four tasks
    ## somebody demoed."*
    ##
    ## **IT IS 41 AND THE MILESTONE PUBLISHED 40 — GROWN, DELIBERATELY, IN THE
    ## DIRECTION THE MECHANISM EXISTS TO ALLOW.** The table below was written
    ## with forty-one rows against a constant reading forty, which is the
    ## mismatch this constant exists to turn into a red gate rather than a
    ## silence; it did. The repair was to move the NUMBER rather than to delete
    ## a row, because the rule the milestone states about this set is that it
    ## *"can grow but cannot silently shrink"*, and dropping a task that
    ## exercises something no other row does — to make a count come out — is
    ## the shrink it forbids wearing the other direction's clothes. The
    ## milestone's derivation and its `FLOOR:` line move with it, in the same
    ## commit, which is what makes the growth visible rather than absorbed.

  CoincidentOperationTasks* = [
    ## **THE ROWS WHOSE TWO KEY SEQUENCES ARE DISTINCT AND WHOSE TWO OPERATION
    ## SEQUENCES ARE NOT.** Named, because this is the exact class the header's
    ## second §34 bullet says a count exists to separate — and the count was
    ## written as *"the whole set"* before anything had run, which is the
    ## assumption the mechanism was built to refuse. Measured: 38 of 41.
    ##
    ## All three are single operations both models bind, under different keys:
    ## Vim's `x` and Kakoune's `Ctrl+d` are both `delete-char-forward`, `X` and
    ## `Ctrl+f` are both `delete-char-backward`, and the third is those two
    ## behind a shared `J`. **They are not comparing a thing with itself** —
    ## two different keys resolve through two different tries in two different
    ## keymaps, and the check is that the two tables agree about what the key
    ## MEANS. What they are not is a PATH difference, which is what `DIFF-4` is
    ## about, so they are excluded from that assertion by name rather than by
    ## the assertion being weakened for everybody.
    "delete-char-forward",
    "delete-char-backward",
    "join-then-delete-char",
  ]

  DivergentOperationTasks* = 38
    ## How many of the forty-one drive two DIFFERENT operation sequences.
    ## Asserted as an equality — see the §34 note in the header — and equal to
    ## `TaskSetCardinality - CoincidentOperationTasks.len`, which is asserted
    ## too, so the two numbers cannot drift into agreeing about nothing.

let TaskSet*: seq[EditingTask] = @[
  # ---- operator + motion: the `dw` / `wd` shape, ten times over -----------
  EditingTask(id: "delete-word-forward", family: tfOperatorMotion,
              caret: tcCamelStart, vimKeys: @["d", "w"],
              kakouneKeys: @["w", "d"],
              note: "§2.1's own example. Vim: begin-operator, select, " &
                    "delete, cancel. Kakoune: select, delete"),
  EditingTask(id: "change-word-forward", family: tfOperatorMotion,
              caret: tcCamelStart, vimKeys: @["c", "w"],
              kakouneKeys: @["w", "c"],
              note: "the operator that also changes the MODE, so the two " &
                    "paths have to agree about more than the document"),
  EditingTask(id: "delete-word-backward", family: tfOperatorMotion,
              caret: tcCamelEnd, vimKeys: @["d", "b"],
              kakouneKeys: @["b", "d"], note: ""),
  EditingTask(id: "delete-to-line-end", family: tfOperatorMotion,
              caret: tcLine1Mid, vimKeys: @["d", "$"],
              kakouneKeys: @["S", "l", "d"],
              note: "one chord against two: Kakoune's goto family is a " &
                    "two-chord prefix, so the trie walks a node deeper"),
  EditingTask(id: "delete-to-line-start", family: tfOperatorMotion,
              caret: tcLine1Mid, vimKeys: @["d", "0"],
              kakouneKeys: @["S", "h", "d"], note: ""),
  EditingTask(id: "delete-to-first-non-blank", family: tfOperatorMotion,
              caret: tcLine1Mid, vimKeys: @["d", "^"],
              kakouneKeys: @["S", "i", "d"], note: ""),
  EditingTask(id: "delete-char-left", family: tfOperatorMotion,
              caret: tcCamelMid, vimKeys: @["d", "h"],
              kakouneKeys: @["Ctrl+Left", "d"],
              note: "the arrow spelling is what a REAL terminal sends; the " &
                    "pty suite drives this same pair from bytes"),
  EditingTask(id: "upper-case-word", family: tfOperatorMotion,
              caret: tcCamelStart, vimKeys: @["g", "U", "w"],
              kakouneKeys: @["w", "~"], note: ""),
  EditingTask(id: "lower-case-word", family: tfOperatorMotion,
              caret: tcCamelStart, vimKeys: @["g", "u", "w"],
              kakouneKeys: @["w", "`"], note: ""),
  EditingTask(id: "swap-case-word", family: tfOperatorMotion,
              caret: tcCamelStart, vimKeys: @["g", "~", "w"],
              kakouneKeys: @["w", "^"], note: ""),
  EditingTask(id: "indent-line-below", family: tfOperatorMotion,
              caret: tcLine1Mid, vimKeys: @[">", "j"],
              kakouneKeys: @["Ctrl+Down", ">"], note: ""),
  EditingTask(id: "dedent-line-below", family: tfOperatorMotion,
              caret: tcLine2Mid, vimKeys: @["<", "j"],
              kakouneKeys: @["Ctrl+Down", "<"], note: ""),

  # ---- text objects ------------------------------------------------------
  EditingTask(id: "inner-word", family: tfObject, caret: tcCamelMid,
              vimKeys: @["d", "i", "w"], kakouneKeys: @["[", "w", "d"],
              note: "Vim's `i`/`a` against Kakoune's object menu"),
  EditingTask(id: "around-word", family: tfObject, caret: tcCamelMid,
              vimKeys: @["d", "a", "w"], kakouneKeys: @["]", "w", "d"],
              note: ""),
  EditingTask(id: "inner-parens", family: tfObject, caret: tcParensInner,
              vimKeys: @["d", "i", "("], kakouneKeys: @["[", "(", "d"],
              note: ""),
  EditingTask(id: "around-parens", family: tfObject, caret: tcParensInner,
              vimKeys: @["d", "a", "("], kakouneKeys: @["]", "(", "d"],
              note: ""),
  EditingTask(id: "inner-double-quote", family: tfObject, caret: tcDoubleInner,
              vimKeys: @["d", "i", "\""], kakouneKeys: @["[", "Q", "d"],
              note: ""),
  EditingTask(id: "around-double-quote", family: tfObject, caret: tcDoubleInner,
              vimKeys: @["d", "a", "\""], kakouneKeys: @["]", "Q", "d"],
              note: ""),
  EditingTask(id: "inner-brackets", family: tfObject, caret: tcBracketsInner,
              vimKeys: @["d", "i", "["], kakouneKeys: @["[", "r", "d"],
              note: "`[` is the object KEY in Vim and the object PREFIX in " &
                    "Kakoune, which is the clearest demonstration that a " &
                    "chord means nothing outside its keymap"),
  EditingTask(id: "around-tag", family: tfObject, caret: tcTagInner,
              vimKeys: @["d", "a", "t"], kakouneKeys: @["]", "t", "d"],
              note: ""),
  EditingTask(id: "change-inner-parens", family: tfObject,
              caret: tcParensInner, vimKeys: @["c", "i", "("],
              kakouneKeys: @["[", "(", "c"],
              note: "the fused name §2.1 forbids (`change-inner-paren`) " &
                    "spelled as the three operations it actually is"),
  EditingTask(id: "upper-inner-word", family: tfObject, caret: tcCamelMid,
              vimKeys: @["g", "U", "i", "w"], kakouneKeys: @["[", "w", "~"],
              note: ""),

  # ---- composed commands with counts ------------------------------------
  EditingTask(id: "count-3-delete-word", family: tfCount, caret: tcCamelStart,
              vimKeys: @["3", "d", "w"], kakouneKeys: @["3", "w", "d"],
              note: "`3dw`. The count is EDITOR state, so the same digit " &
                    "means the same thing under both models"),
  EditingTask(id: "count-2-delete-line-down", family: tfCount,
              caret: tcLine1Mid, vimKeys: @["d", "2", "j"],
              kakouneKeys: @["2", "Ctrl+Down", "d"],
              note: "`d2j` — the count typed INSIDE operator-pending, which " &
                    "is the placement a keymap-private count cannot express"),
  EditingTask(id: "count-4-delete-char-right", family: tfCount,
              caret: tcCamelMid, vimKeys: @["4", "d", "l"],
              kakouneKeys: @["4", "Ctrl+Right", "d"], note: ""),
  EditingTask(id: "count-5-delete-char-left", family: tfCount,
              caret: tcCamelEnd, vimKeys: @["5", "d", "h"],
              kakouneKeys: @["5", "Ctrl+Left", "d"], note: ""),
  EditingTask(id: "count-2-change-word", family: tfCount, caret: tcCamelStart,
              vimKeys: @["2", "c", "w"], kakouneKeys: @["2", "w", "c"],
              note: ""),
  EditingTask(id: "count-3-delete-word-back", family: tfCount,
              caret: tcCamelEnd, vimKeys: @["3", "d", "b"],
              kakouneKeys: @["3", "b", "d"], note: ""),
  EditingTask(id: "count-2-upper-word", family: tfCount, caret: tcCamelStart,
              vimKeys: @["2", "g", "U", "w"], kakouneKeys: @["2", "w", "~"],
              note: "a count, a two-chord operator and a motion at once"),
  EditingTask(id: "count-3-indent-down", family: tfCount, caret: tcLine0Mid,
              vimKeys: @["3", ">", "j"], kakouneKeys: @["3", "Ctrl+Down", ">"],
              note: ""),

  # ---- registers ---------------------------------------------------------
  EditingTask(id: "register-a-yank-word-paste", family: tfRegister,
              caret: tcCamelStart, vimKeys: @["\"", "a", "y", "w", "P"],
              kakouneKeys: @["$", "a", "w", "y", "P"],
              note: "`\"ayw` then a paste, so the register's contents are " &
                    "observable in the DOCUMENT rather than only in a field"),
  EditingTask(id: "register-a-yank-5-words-paste", family: tfRegister,
              caret: tcCamelStart, vimKeys: @["\"", "a", "y", "5", "w", "P"],
              kakouneKeys: @["$", "a", "5", "w", "y", "P"],
              note: "**`\"ay5w`** — PLAT-31 names this sequence by hand as " &
                    "the composed command a keymap-private approximation " &
                    "cannot express: a register, an operator, a count and a " &
                    "motion, in one command"),
  EditingTask(id: "register-b-yank-to-eol-paste", family: tfRegister,
              caret: tcLine1Mid, vimKeys: @["\"", "b", "y", "$", "P"],
              kakouneKeys: @["$", "b", "S", "l", "y", "P"], note: ""),

  # ---- commands ----------------------------------------------------------
  EditingTask(id: "delete-line", family: tfCommand, caret: tcLine1Mid,
              vimKeys: @["d", "d"], kakouneKeys: @["Ctrl+x"],
              note: "**THE COMPOSED-AGAINST-ATOMIC ROW.** Vim reaches it as " &
                    "three operations and Kakoune as one published command, " &
                    "and the end documents are equal — which is what a " &
                    "vocabulary of parts buys"),
  EditingTask(id: "delete-char-forward", family: tfCommand, caret: tcCamelMid,
              vimKeys: @["x"], kakouneKeys: @["Ctrl+d"], note: ""),
  EditingTask(id: "delete-char-backward", family: tfCommand, caret: tcCamelMid,
              vimKeys: @["X"], kakouneKeys: @["Ctrl+f"], note: ""),
  EditingTask(id: "join-then-delete-char", family: tfCommand,
              caret: tcLine1Mid, vimKeys: @["J", "x"],
              kakouneKeys: @["J", "Ctrl+d"],
              note: "the two sequences SHARE their first chord and differ in " &
                    "their second — a row that would be invisible to a " &
                    "'the sequences are different lengths' check"),
  EditingTask(id: "change-word-then-normal", family: tfCommand,
              caret: tcCamelStart, vimKeys: @["c", "w", "Esc"],
              kakouneKeys: @["w", "c", "Esc"],
              note: "`Esc` means `enter-normal` in both, from two different " &
                    "modes reached by two different paths"),
  EditingTask(id: "delete-two-words", family: tfCommand, caret: tcCamelStart,
              vimKeys: @["d", "w", "d", "w"],
              kakouneKeys: @["w", "d", "w", "d"],
              note: "the operator-pending state entered and discharged TWICE"),
  EditingTask(id: "delete-word-then-char", family: tfCommand,
              caret: tcCamelStart, vimKeys: @["d", "w", "x"],
              kakouneKeys: @["w", "d", "Ctrl+d"], note: ""),
  EditingTask(id: "indent-then-dedent", family: tfCommand, caret: tcLine1Mid,
              vimKeys: @[">", ">", "<", "<"],
              kakouneKeys: @["X", ">", "X", "<"],
              note: "a task whose end document EQUALS its start document, " &
                    "deliberately: the two paths have to agree about the " &
                    "identity as well as about a change. **IT WAS `> j < j` " &
                    "AND THAT WAS NOT AN IDENTITY** — measured, on all " &
                    "eighteen documents. `select-line-down` spans the caret's " &
                    "line and the one below, the indent moves the caret, and " &
                    "the second pair is therefore a DIFFERENT pair of lines, " &
                    "so the dedent lands one line off and the net change is " &
                    "real. The row's note claimed the identity before anything " &
                    "had run it. The operator doubled (`>>`, `<<`) acts on ONE " &
                    "line and re-selects it, which is the shape that actually " &
                    "round-trips"),
]

proc caretOffset*(d: ScenarioDoc; c: TaskCaret): int =
  case c
  of tcLine0Mid: d.marks.line0Mid
  of tcLine1Mid: d.marks.line1Mid
  of tcLine2Mid: d.marks.line2Mid
  of tcCamelStart: d.marks.camelStart
  of tcCamelMid: d.marks.camelMid
  of tcCamelEnd: d.marks.camelEnd
  of tcParensInner: d.marks.parensInner
  of tcBracketsInner: d.marks.bracketsInner
  of tcDoubleInner: d.marks.doubleInner
  of tcTagInner: d.marks.tagInner

proc taskState*(d: ScenarioDoc; t: EditingTask): EditorState =
  ## The START state: the document, the caret at the task's landmark, and
  ## nothing else. No mode, no count, no pending operator — **the keymap is
  ## what puts the editor into those states**, and a task that pre-set them
  ## would be a task about a state the keys never produced.
  result = initEditorState(d.text)
  result.selection = caretSelection(caretOffset(d, t.caret))

proc distinctKeySequences*(): int =
  ## How many rows carry two DIFFERENT key sequences. Asserted equal to
  ## `TaskSetCardinality` — see the §34 note.
  for t in TaskSet:
    if t.vimKeys != t.kakouneKeys: inc result

proc familyCounts*(): array[TaskFamily, int] =
  for t in TaskSet:
    inc result[t.family]

proc duplicateTaskIds*(): seq[string] =
  ## Two rows under one id would make a per-task case name resolve to whichever
  ## the loop reached last — §2.4's `move-line-up`, in a different table.
  result = @[]
  var seen: seq[string] = @[]
  for t in TaskSet:
    if t.id in seen and t.id notin result: result.add t.id
    seen.add t.id

proc describeTask*(t: EditingTask): string =
  t.id & ": vim [" & t.vimKeys.join(" ") & "] vs kakoune [" &
    t.kakouneKeys.join(" ") & "]"
