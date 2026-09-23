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
## consults"*. Every one of those is a field below.
##
## **THE SEVENTH ARRIVED WITH PLAT-31 AND THE DELAY WAS DELIBERATE.** Until the
## resolver existed this header read *"the chord buffer belongs to PLAT-31's
## resolver, which does not exist, and a field nothing writes is a field that
## looks like coverage"*. The resolver exists now, it writes `pending`, and the
## field is here rather than in the resolver for §3's own second reason: *"a
## pending `d`, a pending count `12`, a recording macro and the active register
## are all things the STATUS LINE shows"*, and a keymap-private field would
## have to be surfaced through a second channel per front-end — one per keymap
## model, since a second keymap would otherwise need a second copy.
##
## **THE HISTORY WAS A SNAPSHOT STACK UNTIL PLAT-32, AND IT IS NOT ONE NOW.**
## This header said, at PLAT-30: *"`undo`, `redo`, `undo-selection` and
## `redo-selection` are four of the 224 published operations, so they have to be
## executable at this milestone or the vocabulary is not executed at all. What
## makes them executable here is a stack of (document, selection) snapshots —
## not event coalescing, not a mapped-away event inheriting its mapping, not
## `LAW-H1` … `LAW-H6`. Those are PLAT-32's deliverables and this module does
## not pretend to them."*
##
## PLAT-32 landed them. **The four fields — `undoStack`, `redoStack`,
## `selUndo`, `selRedo` — are gone**, replaced by one `history: HistoryState`
## from `editor/history.nim`, and the four operations are the four `pop*`
## routines there. The replacement is not an addition beside the old shape: a
## snapshot stack that survived the milestone meant to remove it would be a
## second history for the same four operations to disagree about, and the
## per-operation sweep would then be asserting about whichever one
## `commitChange` happened to write.
##
## What the old shape cost, recorded because it is what the replacement buys:
## a snapshot is O(document) per edit, there is no change set from the current
## document to a snapshot — so `restoreSnapshot` **discarded** the selection
## history on every undo, in a comment that said so — and thirty keystrokes
## were thirty undos.
##
## **THE WRAP CONFIGURATION IS NOT A FIELD AND THAT IS PLAT-27's DECISION.**
## `wrap.nim`'s header: *"the shared state is the document, the selection and
## the decorations; display geometry is a projection taken per renderer at that
## renderer's own settings"*. So a display-dependent operation takes its
## `WrapSettings` as a parameter, and the 24 operations that do are the only
## ones that can answer differently at two wrap columns — which is §2.3's
## two-sided equality having something to be about.

import std/[options, tables]

import ./history
import ./selection
import ./text_store

export history

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

  PendingChords* = object
    ## §3's seventh item: a partially typed chord sequence, as a value.
    ##
    ## THE TIMEOUT IS STORED AS THE MOMENT THE PREFIX STARTED rather than as a
    ## countdown, so PLAT-31's resolver stays a pure function of
    ## `(state, key, now)` and a suite drives it with a virtual clock instead
    ## of sleeping. `tui/app/input/keymap.PendingState` records the same
    ## decision for the debugger's prefixes; the two are the same shape for the
    ## same reason and neither is derived from the other, because the editing
    ## buffer is STATE (a status line reads it) and that one is the resolver's
    ## own scratch.
    ##
    ## **A `seq[string]` OF CANONICAL KEY NAMES AND NOT A KEY TYPE.** The
    ## import-closure gate refuses any keymap module in this directory's
    ## closure, so what a chord IS cannot be named here — and does not need to
    ## be: a chord's canonical name is a string on every front-end.
    chords*: seq[string]
    startedMs*: int64

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
    pending*: PendingChords
      ## §3's pending-chord buffer. PLAT-31's resolver reads it and returns the
      ## next one; nothing in THIS module writes it, which is why there is no
      ## `pushChord` beside `pushUndo`.

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
      ## `mark(id)`. A byte offset, and **PLAT-31 gave it PLAT-28's MAPPING
      ## without giving it PLAT-28's TYPE** — see `operations.commitChange`,
      ## which now advances every in-range mark and jump through the change set
      ## with `change_set.mapPosOr`, the same function `anchor.landingOf` is
      ## defined as.
      ##
      ## **WHY NOT `Table[string, Anchor]`, WHICH IS WHAT PLAT-30's RESIDUAL
      ## PROPOSED.** An `Anchor` carries four fields and a mark has a use for
      ## one of them. `surface` is a decoration's kind and a mark is not a
      ## decoration; `id` is a caller's handle and the mark's handle is the
      ## table key; `side` is constant for every mark there will ever be. Three
      ## unread fields would then be compared by `EditorState.==` — so two
      ## states whose marks are at the same offsets would be unequal because
      ## one recorded a different surface, and `settle` decides `ooActed` from
      ## that comparison. What marks needed from PLAT-28 was the mapping, and
      ## that is what they have.
    jumps*: seq[int]
      ## The jump list `jump-back` / `jump-forward` walk. Mapped with the
      ## marks, by the same call, for the same reason.
    jumpIndex*: int
      ## Where in `jumps` the cursor into the list currently sits.

    folded*: seq[int]
      ## Folded logical lines, ascending and distinct.
    breakpoints*: seq[int]
    tracepoints*: seq[int]
    flowOverlay*: bool
    trackedLines*: seq[int]
      ## PLAT-28 §8.2. Lines a FRONT-END asks the model to carry through the
      ## edits that follow — the terminal's project breakpoints, which belong
      ## to the session rather than to one buffer's state. ALIGNED BY INDEX
      ## with whatever the front-end handed in, and a line that was deleted
      ## becomes `-1` rather than disappearing, so the caller can tell WHICH of
      ## its points went. `folded`, `breakpoints` and `tracepoints` move by the
      ## same rule (`mapLinesThrough`) but, being this state's own sets, simply
      ## lose a deleted line.

    search*: SearchState
    comments*: LanguageComments
    indentUnit*: string
    parse*: ParseFreshness

    filters*: seq[TransactionFilter]
      ## PLAT-33. Local guards that refuse a LOCAL change — a read-only buffer
      ## or a protected range. Empty by default, so nothing in the 224-operation
      ## vocabulary changes behaviour when no filter is installed.
      ##
      ## **A REMOTE CHANGE DOES NOT CONSULT THEM** (§12.2): the authority's
      ## changes are not negotiable, and a guard that suppressed part of one
      ## would break convergence silently. `collab_text.applyRemoteChange` is
      ## the path that does not call `refusedBy`, and `LAW-X4`'s second arm is
      ## what makes that observable rather than stated.

    history*: HistoryState
      ## PLAT-32's event history: two branches, each event holding an INVERTED
      ## change set, the selection before it and the selections after it. One
      ## field where there were four, because `undo-selection` is not a second
      ## history — it is a walk over the selections hanging off the events of
      ## the same branch `undo` pops from. Two stacks made the two operations
      ## able to disagree about which edit came last.

const
  DefaultIndentUnit* = "    "

  PendingTimeoutMsDefault* = 1000'i64
    ## How long a pending chord sequence waits for its next chord. Vim's own
    ## `timeoutlen` default, which is also what `tui/app/input/keymap.nim` uses
    ## for the DEBUGGER's prefixes — a product that waited one length for
    ## `Ctrl+w` and another for `d` would be one whose timeout is a per-table
    ## accident. The number is named so a suite asserts the boundary at exactly
    ## it and at one past it rather than somewhere plausible.
    ##
    ## It lives beside the buffer it bounds, because the buffer is state and
    ## the bound is a property of the buffer rather than of one resolver.

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
    pending: PendingChords(chords: @[], startedMs: 0),
    recording: "", macros: initTable[string, seq[string]](), recorded: @[],
    lastChange: @[], marks: initTable[string, int](), jumps: @[], jumpIndex: 0,
    folded: @[], breakpoints: @[], tracepoints: @[], flowOverlay: false,
    trackedLines: @[],
    search: SearchState(pattern: "", direction: sdForward),
    comments: comments, indentUnit: indentUnit, parse: parse,
    filters: @[],
    history: initHistory())

func `==`*(a, b: Register): bool =
  a.text == b.text and a.kind == b.kind

func `==`*(a, b: SearchState): bool =
  a.pattern == b.pattern and a.direction == b.direction

func `==`*(a, b: LanguageComments): bool =
  a.lineToken == b.lineToken and a.blockOpen == b.blockOpen and
    a.blockClose == b.blockClose

func `==`*(a, b: PendingChords): bool =
  a.chords == b.chords and a.startedMs == b.startedMs

func `==`*(a, b: EditorState): bool =
  ## **FIELD BY FIELD, AND EVERY FIELD.** The display-dependence sweep (§2.3)
  ## compares two results of one operation at two wrap columns and asserts
  ## equality for 200 of the 224; a comparison that read only the document and
  ## the selection would call two states equal that differ in their mode, their
  ## count or their registers, and 200 negative controls would then be 200
  ## assertions about two of twenty-seven fields. (Twenty-six until PLAT-31
  ## added `pending`; the number is in prose and the FIELD LIST below is
  ## what is executed, so a field added and not compared is a field this
  ## comparison silently ignores — which is exactly what `M15` performs.)
  a.doc == b.doc and a.selection == b.selection and a.mode == b.mode and
    a.registers == b.registers and a.activeRegister == b.activeRegister and
    a.count == b.count and a.pendingOperator == b.pendingOperator and
    a.pending == b.pending and
    a.recording == b.recording and a.macros == b.macros and
    a.recorded == b.recorded and a.lastChange == b.lastChange and
    a.marks == b.marks and a.jumps == b.jumps and a.jumpIndex == b.jumpIndex and
    a.folded == b.folded and a.breakpoints == b.breakpoints and
    a.tracepoints == b.tracepoints and a.flowOverlay == b.flowOverlay and
    a.trackedLines == b.trackedLines and
    a.search == b.search and a.comments == b.comments and
    a.indentUnit == b.indentUnit and a.parse == b.parse and
    a.filters == b.filters and
    a.history == b.history

func primaryHead*(st: EditorState): int =
  ## The head of the primary range. Raises through `mainRange` on the zero
  ## value rather than inventing 0.
  st.selection.mainRange.head

proc lineOfOffset*(st: EditorState; offset: int): int =
  toTextStore(st.doc).posOf(offset).line

proc recordTransaction*(st: var EditorState; t: Transaction;
                        docBefore: string; selectionBefore: EditorSelection) =
  ## Offer a transaction to the history. Called by `commitChange`, in one
  ## place, so "an edit is undoable" stays a property of the dispatcher rather
  ## than of each of the fifty operations that edit.
  st.history = record(st.history, t, docBefore, selectionBefore)

proc mapLinesThrough*(doc: string; cs: ChangeSet;
                      lines: openArray[int]): seq[int] =
  ## **WHERE EACH LINE OF `doc` IS AFTER `cs`, OR `-1` IF IT WAS DELETED** —
  ## PLAT-28 §8.2's *"a breakpoint on a deleted line is not a breakpoint on the
  ## line that took its place"*, for everything in this state that names a
  ## line. Aligned by index with `lines`; lines are 0-based, as `text_store`'s.
  ##
  ## A line is carried as its byte RANGE — its first byte through its
  ## terminating newline — because a point anchor cannot tell the two edits
  ## apart that matter here: `dd` deletes the range whole, `J` deletes only its
  ## newline and keeps the text. The start maps `sideAfter` (text inserted AT
  ## the start of the line, an opened line above it, pushes it down) and the
  ## end `sideBefore` (text inserted at the start of the NEXT line is not this
  ## line's). The line is DELETED exactly when a non-empty range collapses to
  ## nothing; otherwise it is wherever its start landed.
  ##
  ## A line number that is not a line of `doc` is not a position the mapping
  ## is defined over, so it is returned unchanged — the same rule `marks`
  ## follow below, rather than a clamp that invents an answer.
  result = newSeq[int](lines.len)
  if lines.len == 0:
    return
  var starts = @[0]
  for i, ch in doc:
    if ch == '\n': starts.add i + 1
  let newDoc = cs.apply(doc)
  var newStarts = @[0]
  for i, ch in newDoc:
    if ch == '\n': newStarts.add i + 1
  for k, line in lines:
    if line < 0 or line >= starts.len:
      result[k] = line
      continue
    let a = starts[line]
    let b = if line + 1 < starts.len: starts[line + 1] else: doc.len
    let na = cs.mapPosOr(a, sideAfter)
    let nb = cs.mapPosOr(b, sideBefore)
    if b > a and nb <= na:
      result[k] = -1
      continue
    # The last start at or before `na`: a binary search, because a
    # 40,000-line file is a real document and this runs per edit.
    var lo = 0
    var hi = newStarts.len - 1
    while lo < hi:
      let mid = (lo + hi + 1) div 2
      if newStarts[mid] <= na: lo = mid else: hi = mid - 1
    result[k] = lo

func survivingLines(mapped: openArray[int]): seq[int] =
  ## A set of lines after `mapLinesThrough`: the deleted ones gone, and kept
  ## ascending and distinct (`toggleIn`'s invariant) — two breakpoints on lines
  ## an edit joined are one breakpoint on the joined line.
  for l in mapped:
    if l < 0: continue
    var i = 0
    while i < result.len and result[i] < l: inc i
    if i < result.len and result[i] == l: continue
    result.insert(l, i)

proc mapPositionTables*(st: var EditorState; before: EditorState;
                        cs: ChangeSet) =
  ## Advance `marks` and `jumps` through `cs`.
  ##
  ## **ONE FUNCTION, TWO CALLERS, SINCE PLAT-33.** `operations.commitChange`
  ## does this for a local edit and `collab_text.applyRemoteChange` does it
  ## for a remote one, and the two must agree exactly: a mark that moved
  ## differently under somebody else's edit than under your own is a mark that
  ## drifts by one every time the other person types.
  ## `Verification-Harness-Traps.md` §30 — extract the predicate, put the
  ## mutation on the function, and both callers' cases go red together.
  ##
  ## Only offsets that ARE positions of the old document are mapped: mapping
  ## one that is not would be inventing an answer for an input the mapping is
  ## not defined over, which is the clamp wearing a different function's name.
  ##
  ## `sideAfter` and not `sideBefore`: a mark names the start of the text that
  ## was there, so text inserted at exactly that offset is new text the mark
  ## never named, and the mark moves to stay in front of what it did.
  ## `st` is `var` and `before` is the pre-edit value; they are two values,
  ## never two names for one. The parameter was called `result` in the first
  ## draft — which SHADOWS Nim's magic identifier inside a proc that has its
  ## own — and that is the kind of name that compiles and then means something
  ## else in a context nobody re-read.
  for id, pos in before.marks:
    if pos >= 0 and pos <= before.doc.len:
      st.marks[id] = cs.mapPosOr(pos, sideAfter)
  for i in 0 ..< st.jumps.len:
    let pos = before.jumps[i]
    if pos >= 0 and pos <= before.doc.len:
      st.jumps[i] = cs.mapPosOr(pos, sideAfter)
  # PLAT-28 §8.2: every table that names a LINE moves with the text, by one
  # rule. Until 2026-09-23 these four held line numbers the edit did not touch,
  # so a breakpoint set on line 10 stayed on line 10 after a line was opened
  # above it — on different code.
  if before.folded.len > 0:
    st.folded = survivingLines(mapLinesThrough(before.doc, cs, before.folded))
  if before.breakpoints.len > 0:
    st.breakpoints = survivingLines(
      mapLinesThrough(before.doc, cs, before.breakpoints))
  if before.tracepoints.len > 0:
    st.tracepoints = survivingLines(
      mapLinesThrough(before.doc, cs, before.tracepoints))
  if before.trackedLines.len > 0:
    st.trackedLines = mapLinesThrough(before.doc, cs, before.trackedLines)

proc pushSelectionHistory*(st: var EditorState; nowMs: int64 = 0) =
  ## Record the selection the editor is ABOUT to leave. Called before the new
  ## selection is assigned, which is where PLAT-30's `st.selUndo.add
  ## st.selection` stood and where the reference records it too
  ## (`history.ts:344` passes `tr.startState.selection`).
  ##
  ## **IT IS NO LONGER A SECOND STACK.** The recorded selection hangs off the
  ## top event of the `done` branch, so `undo-selection` walks the SAME branch
  ## `undo` pops from. PLAT-30 kept `selUndo` and `selRedo` beside `undoStack`
  ## and `redoStack` on the stated grounds that *"folding them into one stack
  ## would make two of the four unreachable"* — which was true of two flat
  ## stacks and is not true of an event history, where a selection is not a
  ## stack entry but a field of the event it belongs to.
  st.history = recordSelectionChange(st.history, st.selection, nowMs)

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
