## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and `isonim_tui`, and never `viewmodel/*` directly and never `host/`.
##
## app/edit_binding.nim — PLAT-16. The editing session: buffers, the caret, the
## mode register, and what a mode switch preserves.
##
## ## THE SUBSTRATE IS `isonim-tui`'s TextArea, AND IT IS THE REAL ONE
##
## CodeTracer-TUI-Edit-Mode.md §3: *"`isonim-tui` already ships the substrate: a
## TextArea with tree-sitter syntax highlighting, undo/redo, grapheme-aware word
## wrap, and selection keybindings — all covered by that repo's own suites."*
##
## `EditBuffer` holds a `TextAreaWidget` and delegates every mutation to it:
## `insertText`, `backspace`, `deleteRight`, `splitLine`, `undo`, `redo`,
## `indent`, `dedent`, the eight cursor motions. **Not one of those operations
## is reimplemented here**, which is the point — grapheme-cluster columns,
## undo coalescing and the delta stack are exactly the parts a second
## implementation gets subtly wrong, and the sibling repository's suites are
## what cover them.
##
## THE WIDGET IS GIVEN A `TerminalRenderer` AND ITS NODE TREE IS NEVER
## COMPOSITED. Every public mutator on `TextAreaWidget` ends in `renderTree()`,
## which needs a renderer to build children into; `host/terminal_driver.nim`
## constructs one the same way (`TerminalRenderer()` is a plain object, no
## driver, no terminal, no I/O). This front-end paints through `StyledGrid`,
## so what reaches the screen is `views/edit_pane.paintEditPane` reading the
## widget's `lines` — the same bytes, through this front-end's own compositor,
## which is what keeps a Tier-1 cell read and a Tier-2 `cellAt` comparable.
##
## ## WHICH SOURCE THIS BINDING READS, AND WHY IT IS NOT `SourceVM`
##
## The working tree, because `product_mode.sourceOriginFor(pmEdit)` says so.
## That answer is the CORE's and this module asks for it rather than deciding
## it — §2 of the same document: the question *"is not a terminal problem"*.
## `sourceStatementFor(pmEdit)` is likewise read, not spelled, so the sentence
## the pane prints and the sentence the Electron front-end prints are one
## string in one place.
##
## ## No mocks
##
## Nothing here constructs a backend, a session or a fake editor. The
## `TextAreaWidget` is the shipping widget from `isonim-tui`, and the text it
## holds is whatever `host/` read off the disk.

import std/[algorithm, strutils]

import isonim_tui

import codetracer_embed

import ./source_binding
import ./views/edit_pane

export edit_pane
export source_binding

type
  EditBuffer* = ref object
    ## One open file.
    path*: string
      ## The working-tree path, as the host resolved it.
    widget*: TextAreaWidget
      ## The substrate. Public because `app/tests/` asserts against the real
      ## widget's state rather than against a summary this module computed.
    loadedText*: string
      ## What is on disk, as far as this session knows — the bytes that were
      ## read, and then the bytes that were last WRITTEN (`markSaved`).
      ## `isDirty` is a comparison against this rather than a flag set by a
      ## mutator, so an edit-then-undo leaves the buffer CLEAN — a flag would
      ## leave it dirty forever and the `[+]` marker would stop meaning
      ## anything.
    recordedText*: string
      ## What was on disk when this session FIRST opened the file, and never
      ## updated afterwards. The baseline a recording made before this session
      ## would have seen.
      ##
      ## ## WHY THIS IS A SECOND FIELD AND NOT `loadedText` READ TWICE
      ##
      ## PLAT-16's landing pass, and it is `Verification-Harness-Traps.md` §5a
      ## in the field: `isDirty` was being asked TWO questions — *"is there
      ## something unsaved"* (the `[+]` marker) and *"has this file outrun the
      ## recording"* (`refreshEditedPaths`) — and `markSaved` answers the first
      ## one `false`, which silently answered the second one `false` too.
      ## Measured before the split:
      ##
      ## ```
      ## A (edit, toggle):      "This recording predates your edits to 1 file…"
      ## B (edit, :w, toggle):  detail = 'switched to DEBUG mode'
      ##                        editedPaths: @[]   verdict: fresh
      ## ```
      ##
      ## Saving made the staleness notice go away, and saving is what makes a
      ## recording MORE stale, not less: after `:w` the bytes the recording was
      ## made from are gone from the disk as well as from the buffer. §5a's
      ## rule is that the fix is to split the value rather than to surface it —
      ## so the two questions now read two fields, and `outrunsRecording` is
      ## the one function both the notice and its arms go through.
    viewportTop*: int
      ## 1-based first line the pane shows. Held here and not in the widget
      ## because the pane's height is the shell's business and the widget's
      ## `scrollY` counts DISPLAY rows (wrapped), which is a different quantity.
    folded*: seq[int]
      ## 1-based lines whose folds are closed.
      ##
      ## CARRIED AND NOT YET PRODUCED, stated rather than implied: no gesture in
      ## this front-end closes a fold today. The field exists because
      ## Mode-Transitions.md §5 names fold state among what a transition
      ## preserves, and a preservation the session has no place to put is a
      ## preservation that cannot be asserted. `test_mode_transition_oracle.nim`
      ## sets one directly and requires the switch to return it.

  EditSession* = ref object
    ## Everything Edit mode holds across a mode switch.
    ##
    ## ONE OBJECT, LIVING ACROSS THE TRANSITION, which is Mode-Transitions.md
    ## §6's requirement met by construction rather than by a save/restore pair:
    ## *"the natural implementation is one that works once. The pattern that
    ## produces it is a single 'saved layout' slot filled on the way out and
    ## consumed on the way back."* There is no slot here. The session is not
    ## touched by the switch at all, so the *n*th transition behaves as the
    ## first for the same reason the first does.
    buffers*: seq[EditBuffer]
    active*: int
      ## Index into `buffers`, or -1 for none.
    points*: seq[SourcePoint]
      ## Breakpoints and tracepoints. §5: *"They belong to the project, not to
      ## the session."* Held at session level rather than per buffer for
      ## exactly that reason.
    editedPaths*: seq[string]
      ## Paths whose text this session actually CHANGED, in the order they were
      ## first changed. Feeds `product_mode.assessTrace`, and it is what makes
      ## the stale-trace notice a statement about the user's edits rather than
      ## about a file's mtime.
    staleNoticeShown*: bool
      ## §2.1: the user is told *"once"*. This is the once.
    furnished*: bool
      ## Whether `runtime.ensureEditWorkspace` has already walked the project
      ## for this session.
      ##
      ## A FLAG AND NOT `buffers.len > 0`, because a project with no files in
      ## it is a real state and the two must not be confused: on that project
      ## `buffers` stays empty for ever, and a `buffers.len > 0` guard would
      ## re-walk the filesystem on every single `Ctrl+F5`. It also keeps the
      ## §6 property the register has by construction — the *n*th transition
      ## behaves as the first — from being bought back with a filesystem walk.

const
  NoBuffer* = -1

proc newEditBuffer*(path, text: string; viewportHeight = 20): EditBuffer =
  ## A buffer over `text`, named `path`.
  ##
  ## `softWrap` is OFF. §3 names grapheme-aware word wrap as part of the
  ## substrate, and it is; but this pane sits in a column beside a file tree and
  ## a wrapped line would make the gutter's line numbers stop lining up with the
  ## rows they number, which is the one thing a debugger's source column may
  ## not do. The widget still owns the wrapping; this asks it not to.
  ##
  ## `border` is `bsNone`: the shell's projection owns pane separators
  ## (`views/shell.PaneSeparatorGlyph`) and a widget drawing its own box would
  ## be a second frame inside the first.
  let w = newTextArea(TerminalRenderer(), text = text, width = 80,
                      viewportHeight = max(1, viewportHeight),
                      border = bsNone, softWrap = false)
  # `newTextArea` leaves the caret at the END of the document; an editor opens
  # at the top. Moving it here rather than letting the pane show the tail is
  # what makes "open a file and the first line is line 1" true.
  w.moveCursorTo(Caret(line: 0, column: 0))
  EditBuffer(path: path, widget: w, loadedText: text, recordedText: text,
             viewportTop: 1, folded: @[])

proc text*(buf: EditBuffer): string =
  if buf.isNil or buf.widget.isNil: "" else: buf.widget.text

proc isDirty*(buf: EditBuffer): bool =
  ## Whether the buffer differs from the bytes that were loaded. See
  ## `loadedText` on why this is a comparison and not a flag.
  not buf.isNil and not buf.widget.isNil and buf.widget.text != buf.loadedText

proc outrunsRecording*(buf: EditBuffer): bool =
  ## Whether this session has moved the file away from the bytes it opened.
  ##
  ## THE STALENESS QUESTION, AND IT IS NOT `isDirty`. See `recordedText` for
  ## what the two were costing when they were one predicate. A file outruns the
  ## recording when EITHER end has moved off the baseline:
  ##
  ## | what happened | buffer | disk | outruns |
  ## | --- | --- | --- | --- |
  ## | opened, untouched | = | = | no |
  ## | edited | ≠ | = | **yes** |
  ## | edited, `:w` | ≠ | ≠ | **yes** — the fix; `isDirty` said no |
  ## | edited, undone | = | = | no — the case `refreshEditedPaths` exists for |
  ## | edited, `:w`, undone | = | ≠ | **yes** — the disk still holds the edit |
  ## | edited, `:w`, undone, `:w` | = | = | no — the file is back |
  ##
  ## The last two rows are why this is a disjunction rather than one
  ## comparison, and they are the arms that make the negative half falsifiable
  ## (§7a): row five would be green under a predicate that only looked at the
  ## buffer, and row six would be red under one that only looked at the disk.
  if buf.isNil or buf.widget.isNil:
    return false
  buf.widget.text != buf.recordedText or buf.loadedText != buf.recordedText

proc markSaved*(buf: EditBuffer) =
  ## The buffer was written to disk. `host/` does the writing; this records it.
  ##
  ## `recordedText` IS DELIBERATELY NOT TOUCHED. Writing a file does not make a
  ## recording newer, so a save must not be able to clear a staleness notice —
  ## which is exactly what it did before `recordedText` existed.
  if not buf.isNil and not buf.widget.isNil:
    buf.loadedText = buf.widget.text

proc caretLine*(buf: EditBuffer): int =
  ## 1-BASED, because the gutter, the pane and every message a user reads are
  ## 1-based and the widget's `Caret.line` is 0-based. Converted in exactly one
  ## place, which is here.
  if buf.isNil or buf.widget.isNil: 0 else: buf.widget.cursor.line + 1

proc caretColumn*(buf: EditBuffer): int =
  if buf.isNil or buf.widget.isNil: 0 else: buf.widget.cursor.column

proc lineCount*(buf: EditBuffer): int =
  if buf.isNil or buf.widget.isNil: 0 else: buf.widget.lineCount

proc lines*(buf: EditBuffer): seq[string] =
  if buf.isNil or buf.widget.isNil: @[] else: buf.widget.lines

proc followCaret*(buf: EditBuffer; rows: int) =
  ## Scroll the pane so the caret is visible, and no further.
  ##
  ## The pane's own scroll rather than the widget's: see `viewportTop`. A
  ## MINIMAL scroll — the caret entering from the bottom moves the window by
  ## one line, not to the middle — because a jump on every keystroke near an
  ## edge is what makes a terminal editor feel broken.
  if buf.isNil or rows <= 0:
    return
  let line = buf.caretLine
  if line <= 0:
    return
  if line < buf.viewportTop:
    buf.viewportTop = line
  elif line > buf.viewportTop + rows - 1:
    buf.viewportTop = line - rows + 1
  if buf.viewportTop < 1:
    buf.viewportTop = 1

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

type
  EditKeyOutcome* = enum
    ## What one key did to the buffer.
    ##
    ## THREE ANSWERS AND NOT A `bool`, because "the buffer changed", "the caret
    ## moved" and "this key is not the editor's" are three different things to
    ## a caller: the first marks the file dirty, the second only repaints, and
    ## the third must be handed back to the keymap. A `bool` would have merged
    ## the first two and a caller would have recorded an edit for every arrow
    ## key — which is exactly the input `assessTrace` must not get, because it
    ## would declare a recording stale because somebody scrolled.
    ekIgnored = "ignored"
    ekMoved = "moved"
    ekChanged = "changed"

proc applyEditKey*(buf: EditBuffer; key, character: string): EditKeyOutcome =
  ## One canonical key name (`keymap.keyName`'s vocabulary) applied to the
  ## buffer.
  ##
  ## `character` is `keymap.keyCharacter`'s answer and is what gets INSERTED —
  ## never `key`, which is `"Space"` for the space bar. That is the same
  ## distinction `keymap.keyCharacter`'s docstring records CTUI-10 measuring,
  ## and getting it wrong here would type the word "Space" into a user's file.
  if buf.isNil or buf.widget.isNil:
    return ekIgnored
  let w = buf.widget
  case key
  of "Left": w.moveLeft(); ekMoved
  of "Right": w.moveRight(); ekMoved
  of "Up": w.moveUp(); ekMoved
  of "Down": w.moveDown(); ekMoved
  of "Home": w.moveLineStart(); ekMoved
  of "End": w.moveLineEnd(); ekMoved
  of "Backspace": w.backspace(); ekChanged
  of "Delete": w.deleteRight(); ekChanged
  of "Enter": w.splitLine(); ekChanged
  of "Tab": w.indent(); ekChanged
  of "Shift+Tab": w.dedent(); ekChanged
  of "Ctrl+z":
    if w.undo(): ekChanged else: ekMoved
  of "Ctrl+y":
    if w.redo(): ekChanged else: ekMoved
  else:
    if character.len > 0:
      w.insertText(character)
      ekChanged
    else:
      ekIgnored

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc newEditSession*(): EditSession =
  EditSession(buffers: @[], active: NoBuffer, points: @[], editedPaths: @[],
              staleNoticeShown: false, furnished: false)

proc activeBuffer*(s: EditSession): EditBuffer =
  if s.isNil or s.active < 0 or s.active >= s.buffers.len: nil
  else: s.buffers[s.active]

proc indexOfPath*(s: EditSession; path: string): int =
  result = NoBuffer
  if s.isNil:
    return
  for i, b in s.buffers:
    if b.path == path:
      return i

proc openFile*(s: EditSession; path, text: string; viewportHeight = 20): int =
  ## Open `path`, or activate it if it is already open.
  ##
  ## AN ALREADY-OPEN FILE IS NOT RELOADED. Mode-Transitions.md §5: *"Reopening
  ## the file is not the same as never having closed it"*, and a re-open that
  ## replaced the text would silently discard an unsaved buffer — the one thing
  ## §5 calls data loss by name.
  if s.isNil:
    return NoBuffer
  let existing = s.indexOfPath(path)
  if existing >= 0:
    s.active = existing
    return existing
  s.buffers.add newEditBuffer(path, text, viewportHeight)
  s.active = s.buffers.high
  s.active

proc recordEdit*(s: EditSession; path: string) =
  ## Note that `path`'s text changed. Idempotent, and ORDER-PRESERVING so the
  ## notice names files in the order the user touched them.
  if s.isNil or path.len == 0:
    return
  if path notin s.editedPaths:
    s.editedPaths.add path

proc refreshEditedPaths*(s: EditSession) =
  ## Re-derive `editedPaths` from the buffers' actual contents.
  ##
  ## THE UNDO CASE IS WHY THIS EXISTS. `recordEdit` is called when a keystroke
  ## changes a buffer, but `Ctrl+z` back to the opened bytes leaves the file
  ## identical to the recording's — and a staleness notice for a file the user
  ## restored is a notice about nothing.
  ##
  ## **IT READS `outrunsRecording`, NOT `isDirty`**, and the difference is the
  ## whole of PLAT-16's F2. `isDirty` means *"differs from disk"*; this needs
  ## *"differs from what the recording saw"*, and reading the first as the
  ## second made `:w` SILENCE the notice — §5a's dangerous event read as the
  ## benign one. The `[+]` marker keeps `isDirty`, because the marker really is
  ## about unsaved work; the two predicates now disagree on purpose, in exactly
  ## the saved-but-edited case, and `test_edit_mode_source.nim` asserts the
  ## NOTICE rather than this list.
  if s.isNil:
    return
  var kept: seq[string] = @[]
  for path in s.editedPaths:
    let idx = s.indexOfPath(path)
    if idx >= 0 and s.buffers[idx].outrunsRecording:
      kept.add path
  s.editedPaths = kept

proc noticeForSwitchToDebug*(s: EditSession; hasTrace: bool): string =
  ## The stale-trace sentence, or "" — and **at most once per session**.
  ##
  ## §2.1 consequence 3: *"must be told, once, plainly."* The once is
  ## `staleNoticeShown`, and it is here rather than in the core because "have I
  ## already said this" is a property of a running session and
  ## `viewmodels/product_mode.nim` is a pure function of its arguments.
  ##
  ## The flag is set only when something was actually said, so a switch made
  ## before any edit does not consume the one notice the user gets.
  if s.isNil:
    return ""
  s.refreshEditedPaths()
  let switch = switchProductMode(pmEdit, pmDebug, hasTrace, s.editedPaths)
  if switch.notice.len == 0 or s.staleNoticeShown:
    return ""
  s.staleNoticeShown = true
  switch.notice

# ---------------------------------------------------------------------------
# §5 — the preservation witness
# ---------------------------------------------------------------------------

proc preservedValue*(s: EditSession; concern: PreservedConcern): string =
  ## A canonical rendering of everything `concern` covers, for comparison
  ## across a transition.
  ##
  ## ## WHY A STRING RATHER THAN SIX TYPED ACCESSORS
  ##
  ## Because the OTHER end of the comparison is a document. The suite parses
  ## `Mode-Transitions.md` §5 at run time, slugs each row, and walks the
  ## resulting set — so it needs to ask this session about a concern it
  ## discovered rather than about one it named, and that is a lookup by enum
  ## value. A typed accessor per concern could not be reached from a loop over
  ## parsed slugs without a second table mapping one to the other, which is the
  ## transcription the run-time oracle exists to avoid.
  ##
  ## Every rendering is TOTAL over what the concern covers — every buffer, not
  ## the active one. §5: *"Editor state is captured … for every file, not only
  ## the active one. … the failure is invisible for the active file if that
  ## file happens to be re-opened at the top."*
  if s.isNil:
    return ""
  case concern
  of pcOpenTabs:
    var parts: seq[string] = @[]
    for b in s.buffers:
      parts.add b.path
    "active=" & $s.active & " [" & parts.join("|") & "]"
  of pcUnsavedBuffers:
    var parts: seq[string] = @[]
    for b in s.buffers:
      parts.add b.path & "=" & (if b.isDirty: "dirty:" else: "clean:") & b.text
    parts.join("\x1f")
  of pcCaretAndSelection:
    var parts: seq[string] = @[]
    for b in s.buffers:
      let w = b.widget
      parts.add b.path & "@" & $w.cursor.line & "," & $w.cursor.column &
        "~" & $w.selection.anchor.line & "," & $w.selection.anchor.column
    parts.join("|")
  of pcScrollPosition:
    var parts: seq[string] = @[]
    for b in s.buffers:
      parts.add b.path & "@" & $b.viewportTop
    parts.join("|")
  of pcFoldState:
    var parts: seq[string] = @[]
    for b in s.buffers:
      var folds = b.folded
      folds.sort()
      parts.add b.path & "@" & folds.join(",")
    parts.join("|")
  of pcBreakpoints:
    var parts: seq[string] = @[]
    for p in s.points:
      parts.add p.path & ":" & $p.line & ":" & $p.kind & ":" & $p.enabled
    parts.sort()
    parts.join("|")

proc preservationWitness*(s: EditSession): seq[(string, string)] =
  ## Every concern and its value, in declaration order. What a test snapshots
  ## before a transition and compares after.
  result = @[]
  for c in PreservedConcern:
    result.add ($c, preservedValue(s, c))

# ---------------------------------------------------------------------------
# The pane model
# ---------------------------------------------------------------------------

proc marksForFile*(points: openArray[SourcePoint];
                   path: string): seq[(int, GutterMark)] =
  ## The gutter marks on `path`.
  ##
  ## THE SAME ORDER RULE `source_binding.marksForFile` STATES — tracepoints
  ## first, breakpoints second, so a line carrying both shows `●`. It is a
  ## second call site of one rule rather than a second rule: this overload
  ## exists only because `source_binding`'s is not visible through this
  ## module's re-exports under the same name without ambiguity, and it
  ## delegates.
  source_binding.marksForFile(points, path)

proc editPaneModelFor*(s: EditSession; buf: EditBuffer): EditPaneModel =
  ## The pane's model for the CURRENT frame.
  ##
  ## `sourceStatement` comes from the CORE — `sourceStatementFor(pmEdit)` —
  ## and is not spelled here. §2's Requirement is that the pane states which
  ## mode's source it shows always, and "always" is only checkable if there is
  ## one sentence rather than one per front-end.
  if buf.isNil:
    return initEditPaneModel(sourceStatement = sourceStatementFor(pmEdit))
  initEditPaneModel(
    path = buf.path,
    sourceStatement = sourceStatementFor(pmEdit),
    lines = buf.lines,
    viewportTop = buf.viewportTop,
    caretLine = buf.caretLine,
    caretColumn = buf.caretColumn,
    selectionActive = (not buf.widget.isNil and buf.widget.hasSelection),
    dirty = buf.isDirty,
    marks = (if s.isNil: @[] else: marksForFile(s.points, buf.path)),
    language = "")
