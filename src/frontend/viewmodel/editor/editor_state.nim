## editor_state.nim — PLAT-30: the state every named operation is pure over.
##
## Owns: the value an operation of `operations.nim` reads and returns. Nothing
## here knows about keys, and nothing here performs an effect.
##
## =========================================================================
## WHY THIS IS A SEPARATE MODULE FROM THE VOCABULARY
## =========================================================================
##
## `operations.nim` is a table of 140 declarations and their implementations;
## this is the value they are written against. Keeping them apart is what lets
## the vocabulary's own header make the claim it makes — *"every operation is a
## function of this type and of its arguments"* — without the type's definition
## being buried inside a 200-entry table. It is also what lets a front-end hold
## an `EditorState` without importing the vocabulary.
##
## =========================================================================
## WHAT IS HERE, AND WHAT IS DELIBERATELY NOT
## =========================================================================
##
## Editing-Operations-And-Keymaps.md §3 is explicit about what lives in the
## editor rather than in a keymap: *"Counts, the pending register, the
## operator-pending state, the recording macro, the last change (for `.`), the
## mode itself and the pending-chord buffer are editor state that the keymap
## consults"*. Every one of those except the pending-chord buffer is a field
## below; the chord buffer belongs to PLAT-31's resolver, which does not exist,
## and a field nothing writes is a field that looks like coverage.
##
## **THE HISTORY HERE IS A SNAPSHOT STACK AND PLAT-32 OWNS THE REAL ONE.** Said
## plainly rather than left to be discovered: `undo`, `redo`, `undo-selection`
## and `redo-selection` are four of the 224 published operations, so they have
## to be executable at this milestone or the vocabulary is not executed at all.
## What makes them executable here is a stack of (document, selection)
## snapshots — not event coalescing, not a mapped-away event inheriting its
## mapping, not `LAW-H1` … `LAW-H6`. Those are PLAT-32's deliverables and this
## module does not pretend to them. The cost is bounded and stated: a snapshot
## stack is O(document) per edit, which is why `HistoryLimit` exists.
##
## **THE WRAP CONFIGURATION IS NOT A FIELD AND THAT IS PLAT-27's DECISION.**
## `wrap.nim`'s header: *"the shared state is the document, the selection and
## the decorations; display geometry is a projection taken per renderer at that
## renderer's own settings"*. So a display-dependent operation takes its
## `WrapSettings` as a parameter, and the 24 operations that do are the only
## ones that can answer differently at two wrap columns — which is §2.3's
## two-sided equality having something to be about.

import std/tables

import ./selection
import ./text_store

type
  EditingMode* = enum
    ## §4.3's third scope dimension. It is NOT the product mode (Debug/Edit)
    ## and it is NOT the pane mode (NORMAL/COMMAND/SEARCH/…):
    ## `CodeTracer-TUI-Edit-Mode.md` §1.2 refuses that collapse, and §3 of this
    ## milestone's spec repeats the refusal for this dimension.
    emNormal = "normal"
    emInsert = "insert"
    emVisual = "visual"
    emVisualLine = "visual-line"
    emVisualBlock = "visual-block"
    emReplace = "replace"
    emOperatorPending = "operator-pending"

  RegisterKind* = enum
    ## Whether a register's payload was taken linewise. `paste-after` puts a
    ## linewise payload on the NEXT line and a charwise one after the caret,
    ## which is the one place the distinction is observable.
    rkCharwise = "charwise"
    rkLinewise = "linewise"

  Register* = object
    text*: string
    kind*: RegisterKind

  SearchDirection* = enum
    sdForward = "forward"
    sdBackward = "backward"

  SearchState* = object
    ## What `search-next` / `search-prev` consult and what `search-forward` /
    ## `search-backward` / `search-selection` / `search-clear` write. A literal
    ## pattern, not a regular expression: §5.1 forbids an operation that waits,
    ## and nothing here needs a regex engine to make the four operations
    ## executable and total.
    pattern*: string
    direction*: SearchDirection

  LanguageComments* = object
    ## §2.2 C: *"comment tokens are per-language data, not a constant"*. They
    ## are data HERE — on the state, supplied by whoever opened the document —
    ## rather than a constant inside `toggle-comment`.
    lineToken*: string
    blockOpen*, blockClose*: string

  ParseFreshness* = enum
    ## §5.1: *"`syntax-left` on a document whose parse is stale produces a
    ## defined, reported outcome rather than a pause."* This field is what
    ## makes "reported" possible: the syntax-dependent operations read it and
    ## refuse by name when it is not `pfFresh`.
    ##
    ## **NOTHING IN THIS MILESTONE EVER SETS IT TO `pfFresh`, AND THAT IS
    ## STATED RATHER THAN HIDDEN.** There is no parse in the editor model yet;
    ## the operations that need one are in the vocabulary because the published
    ## table has them, and they refuse with a typed reason. A field that could
    ## never be anything but stale would be a lie, so the enum carries both
    ## arms and the suite drives BOTH — the refusal on `pfStale` and the
    ## defined behaviour on `pfFresh` for the operations that can still answer.
    pfAbsent = "absent"
    pfStale = "stale"
    pfFresh = "fresh"

  Snapshot* = object
    ## One undoable point. See the header on why this is a snapshot.
    doc*: string
    selection*: EditorSelection

  EditorState* = object
    ## **THE VALUE EVERY OPERATION IS PURE OVER.**
    doc*: string
    selection*: EditorSelection
    mode*: EditingMode

    registers*: Table[string, Register]
    activeRegister*: string
      ## `set-register(id)`'s answer. `""` is the unnamed register.
    count*: int
      ## `push-count-digit(d)`'s accumulator. 0 means "no count given", which
      ## is not the same as 1 — a keymap multiplies by `max(1, count)` and must
      ## still be able to tell whether the user typed anything.
    pendingOperator*: string
      ## `begin-operator(op)`'s argument, `""` when none. It names an entry of
      ## category C, which `operations.nim` checks rather than assumes.

    recording*: string
      ## The macro id being recorded, `""` when none.
    macros*: Table[string, seq[string]]
      ## Recorded operation NAMES, which is the whole point of a named
      ## vocabulary: a macro is a list of names rather than a list of chords,
      ## so it replays identically under either keymap.
    recorded*: seq[string]
      ## The in-progress recording.
    lastChange*: seq[string]
      ## What `repeat-last-change` repeats: the names of the operations of the
      ## most recent document-changing burst.

    marks*: Table[string, int]
      ## `mark(id)`. **A byte offset and not an anchor, at this milestone**, and
      ## the difference is real: PLAT-28's anchors survive an edit and these do
      ## not. Recorded rather than glossed — `mark(id)` is a published motion
      ## and it has to be executable; promoting the table to anchors is a
      ## change to this field's type and to nothing else.
    jumps*: seq[int]
      ## The jump list `jump-back` / `jump-forward` walk.
    jumpIndex*: int
      ## Where in `jumps` the cursor into the list currently sits.

    folded*: seq[int]
      ## Folded logical lines, ascending and distinct.
    breakpoints*: seq[int]
    tracepoints*: seq[int]
    flowOverlay*: bool

    search*: SearchState
    comments*: LanguageComments
    indentUnit*: string
    parse*: ParseFreshness

    undoStack*: seq[Snapshot]
    redoStack*: seq[Snapshot]
    selUndo*: seq[EditorSelection]
    selRedo*: seq[EditorSelection]

const
  HistoryLimit* = 128
    ## How many snapshots the stacks keep. A bound rather than a growth
    ## policy, because the growth policy is PLAT-32's.

  DefaultIndentUnit* = "    "

func defaultComments*(): LanguageComments =
  ## Nim's, because this repository's documents are Nim and a default that
  ## matches nothing would make `toggle-comment` a no-op everywhere.
  LanguageComments(lineToken: "#", blockOpen: "#[", blockClose: "]#")

proc initEditorState*(doc: string; selection = default(EditorSelection);
                      comments = defaultComments();
                      indentUnit = DefaultIndentUnit;
                      parse = pfStale): EditorState =
  ## A state over `doc` with one caret at 0 unless a selection is supplied.
  ##
  ## The selection defaults to the type's ZERO VALUE only so the parameter can
  ## be optional; it is replaced here, never stored. `selection.nim`'s header
  ## records that the zero value is the one un-normalised inhabitant and that
  ## every consumer of it raises by name — so handing one on is not an option.
  var sel = selection
  if sel.rangeCount == 0:
    sel = caretSelection(0)
  EditorState(
    doc: doc, selection: sel, mode: emNormal,
    registers: initTable[string, Register](),
    activeRegister: "", count: 0, pendingOperator: "",
    recording: "", macros: initTable[string, seq[string]](), recorded: @[],
    lastChange: @[], marks: initTable[string, int](), jumps: @[], jumpIndex: 0,
    folded: @[], breakpoints: @[], tracepoints: @[], flowOverlay: false,
    search: SearchState(pattern: "", direction: sdForward),
    comments: comments, indentUnit: indentUnit, parse: parse,
    undoStack: @[], redoStack: @[], selUndo: @[], selRedo: @[])

func `==`*(a, b: Register): bool =
  a.text == b.text and a.kind == b.kind

func `==`*(a, b: SearchState): bool =
  a.pattern == b.pattern and a.direction == b.direction

func `==`*(a, b: LanguageComments): bool =
  a.lineToken == b.lineToken and a.blockOpen == b.blockOpen and
    a.blockClose == b.blockClose

func `==`*(a, b: Snapshot): bool =
  a.doc == b.doc and a.selection == b.selection

func `==`*(a, b: EditorState): bool =
  ## **FIELD BY FIELD, AND EVERY FIELD.** The display-dependence sweep (§2.3)
  ## compares two results of one operation at two wrap columns and asserts
  ## equality for 200 of the 224; a comparison that read only the document and
  ## the selection would call two states equal that differ in their mode, their
  ## count or their registers, and 200 negative controls would then be 200
  ## assertions about two of twenty-six fields.
  a.doc == b.doc and a.selection == b.selection and a.mode == b.mode and
    a.registers == b.registers and a.activeRegister == b.activeRegister and
    a.count == b.count and a.pendingOperator == b.pendingOperator and
    a.recording == b.recording and a.macros == b.macros and
    a.recorded == b.recorded and a.lastChange == b.lastChange and
    a.marks == b.marks and a.jumps == b.jumps and a.jumpIndex == b.jumpIndex and
    a.folded == b.folded and a.breakpoints == b.breakpoints and
    a.tracepoints == b.tracepoints and a.flowOverlay == b.flowOverlay and
    a.search == b.search and a.comments == b.comments and
    a.indentUnit == b.indentUnit and a.parse == b.parse and
    a.undoStack == b.undoStack and a.redoStack == b.redoStack and
    a.selUndo == b.selUndo and a.selRedo == b.selRedo

func primaryHead*(st: EditorState): int =
  ## The head of the primary range. Raises through `mainRange` on the zero
  ## value rather than inventing 0.
  st.selection.mainRange.head

proc lineOfOffset*(st: EditorState; offset: int): int =
  toTextStore(st.doc).posOf(offset).line

proc pushUndo*(st: var EditorState) =
  ## Snapshot the current document and selection, and clear the redo stack.
  ## Called by every operation that changes the document, in one place, so
  ## "an edit is undoable" is a property of the dispatcher rather than of each
  ## of the fifty operations that edit.
  st.undoStack.add Snapshot(doc: st.doc, selection: st.selection)
  if st.undoStack.len > HistoryLimit:
    st.undoStack.delete(0)
  st.redoStack.setLen(0)

proc pushSelectionHistory*(st: var EditorState) =
  ## The selection's own history, which `undo-selection` / `redo-selection`
  ## walk. It is a SECOND stack and not the same one: the published vocabulary
  ## has four history operations, two of which are about the selection alone,
  ## and folding them into one stack would make two of the four unreachable.
  st.selUndo.add st.selection
  if st.selUndo.len > HistoryLimit:
    st.selUndo.delete(0)
  st.selRedo.setLen(0)

func hasMark*(st: EditorState; id: string): bool =
  st.marks.hasKey(id)

func registerOf*(st: EditorState; id: string): Register =
  if st.registers.hasKey(id): st.registers[id] else: Register(text: "", kind: rkCharwise)

proc setRegister*(st: var EditorState; id: string; r: Register) =
  st.registers[id] = r

func isFolded*(st: EditorState; line: int): bool =
  line in st.folded

proc toggleIn*(xs: var seq[int]; line: int) =
  ## Add `line` if absent, remove it if present, keeping `xs` ascending and
  ## distinct. One function for `folded`, `breakpoints` and `tracepoints`
  ## rather than three copies of a two-line loop.
  let idx = xs.find(line)
  if idx >= 0:
    xs.delete(idx)
  else:
    var i = 0
    while i < xs.len and xs[i] < line: inc i
    xs.insert(line, i)
