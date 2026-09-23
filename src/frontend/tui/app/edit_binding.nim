## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and never `viewmodel/*` directly and never `host/`.
##
## app/edit_binding.nim — PLAT-16. The editing session: buffers, the caret, the
## mode register, and what a mode switch preserves.
##
## ## THE SUBSTRATE IS THE MODEL, AND `TextAreaWidget` IS GONE FROM THIS PATH
##
## **PLAT-34 retired `EditBuffer` as the source of truth.** Until this
## milestone this module held an `isonim-tui` `TextAreaWidget` and delegated
## every mutation to it through a fourteen-arm `case` over `EditBehaviour`.
## That widget was a SECOND mutable text buffer beside
## `viewmodel/editor/editor_state.EditorState`, and while it existed:
##
##   * PLAT-31's Vim and Kakoune models were *reachable from no key the
##     shipped binary accepts* — the terminal resolved keys through
##     `TuiEditBindings` directly, so the resolver had no caller;
##   * PLAT-32's history was not the history the terminal undid through —
##     `Ctrl+z` popped the WIDGET's delta stack;
##   * PLAT-33's collaborative rebase had nothing to rebase against, because
##     the bytes a user was typing were not in the model at all;
##   * and the operation name in `TuiEditBindings` was a JOIN between two
##     suites rather than a call: the ViewModel oracle ran the operation, this
##     module ran a widget method, and nothing executed the edge between them.
##
## `EditBuffer` now holds an `EditingDocument` — `codetracer_embed`'s
## `editing_core` — and every mutation is one of PLAT-30's 224 named
## operations, reached through PLAT-31's resolver. There is no second buffer
## and `test_editor_front_end_differential.nim`'s mutable-buffer scan is what
## says so, with a planted positive control rather than an absence grep.
##
## ## WHAT THE WIDGET WAS DOING THAT THE MODEL NOW DOES, NAMED
##
## PLAT-16's header claimed the substrate for *"grapheme-cluster columns, undo
## coalescing and the delta stack — exactly the parts a second implementation
## gets subtly wrong"*. That was the right reason in 2026-09 and each of the
## three has since been built, graded and published in the model:
##
##   * grapheme-cluster columns — PLAT-24's corpus and PLAT-27's
##     `wrap.lineMetrics`, which `editing_core.caretColumn` calls;
##   * undo coalescing — PLAT-32's `history.mayGroup`, one predicate with the
##     rule and every control calling it;
##   * the delta stack — PLAT-25's `ChangeSet`, with ten published laws.
##
## So this is not a reimplementation of the widget; it is the migration onto
## the layer the campaign built to replace it. The widget's own suites still
## cover the widget, in its own repository, for the front-ends that use it.
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
## Nothing here constructs a backend, a session or a fake editor. The text is
## whatever `host/` read off the disk and the editor is the shipped model.

import std/[algorithm, strutils]

import codetracer_embed

import ../../../common/editing_key_bindings

import ./source_binding
import ./views/edit_pane

export edit_pane
export source_binding
# The binding table is part of this module's contract now: a caller that wants
# to know which operation a key performs asks the TABLE, and
# `app/tests/test_edit_binding_vocabulary.nim` asks it exactly that.
export editing_key_bindings

type
  EditBuffer* = ref object
    ## One open file.
    path*: string
      ## The working-tree path, as the host resolved it.
    doc*: EditingDocument
      ## **THE BUFFER, AND IT IS THE MODEL.** `codetracer_embed.editing_core`'s
      ## `EditingDocument` — one `EditorState`, the keymap model it resolves
      ## keys through, and the wrap settings this medium reads its display
      ## geometry at.
      ##
      ## Public for the reason the widget was public: `app/tests/` asserts
      ## against the real editor's state rather than against a summary this
      ## module computed. What changed is that the real editor is now the one
      ## the ViewModel suites grade, so the two sides of `TuiEditBindings` are
      ## a call rather than a join.
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
      ## 1-based first line the pane shows. Held here and not on the MODEL
      ## because the pane's height is the shell's business and a viewport is
      ## per renderer — the same reason PLAT-27 keeps `WrapSettings` out of
      ## `EditorState`. Two front-ends looking at one document scroll
      ## independently and must.
      ##
      ## **FOLD STATE MOVED THE OTHER WAY AND IS NOT A FIELD HERE.** It was
      ## `EditBuffer.folded` until PLAT-34 and it is `EditorState.folded` now,
      ## reached through the `folded` accessors below. A fold is a property of
      ## the DOCUMENT rather than of a viewport: the collaboration stream and
      ## the GPUI front-end have the same claim on it this pane has, and a
      ## per-front-end copy is a second value for them to disagree about. The
      ## carried-and-not-yet-produced note PLAT-16 attached to it still holds
      ## — no gesture in this front-end closes a fold today, and
      ## `test_mode_transition_oracle.nim` sets one directly.

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
    model*: KeymapModel
      ## PLAT-43. The keymap model every buffer of this session resolves keys
      ## through — the one `:keymap <name>` selected, or the stored preference
      ## the host loaded. A SESSION field and not only a per-document one, so a
      ## file opened after the choice is opened under it.
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

proc newEditBuffer*(path, text: string;
                    viewportHeight = 20;
                    model = kmProductDefault): EditBuffer =
  ## A buffer over `text`, named `path`, with the caret at the top.
  ##
  ## SOFT WRAP IS OFF, and it is off in `editing_core.terminalWrapSettings`
  ## rather than here, so the terminal's wrap configuration is one value with
  ## one reader instead of a flag passed at a construction site. The reason is
  ## unchanged from PLAT-16: this pane sits in a column beside a file tree and
  ## a wrapped line would make the gutter's line numbers stop lining up with
  ## the rows they number, which is the one thing a debugger's source column
  ## may not do.
  ##
  ## `model` IS A PARAMETER AND ITS DEFAULT IS THE PRODUCT'S. PLAT-31 shipped
  ## Vim and Kakoune as `KeymapDefinition`s and left them reachable from no
  ## key the binary accepts, because the terminal dispatched through
  ## `TuiEditBindings` directly. This parameter is the caller a model needs;
  ## §4.4's *"the default does not move"* is what its default says.
  EditBuffer(path: path,
             doc: initEditingDocument(path, text, model,
                                      viewportRows = max(1, viewportHeight)),
             loadedText: text, recordedText: text, viewportTop: 1)

proc text*(buf: EditBuffer): string =
  if buf.isNil: "" else: buf.doc.text

proc isDirty*(buf: EditBuffer): bool =
  ## Whether the buffer differs from the bytes that were loaded. See
  ## `loadedText` on why this is a comparison and not a flag.
  not buf.isNil and buf.doc.text != buf.loadedText

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
  if buf.isNil:
    return false
  buf.doc.text != buf.recordedText or buf.loadedText != buf.recordedText

proc markSaved*(buf: EditBuffer) =
  ## The buffer was written to disk. `host/` does the writing; this records it.
  ##
  ## `recordedText` IS DELIBERATELY NOT TOUCHED. Writing a file does not make a
  ## recording newer, so a save must not be able to clear a staleness notice —
  ## which is exactly what it did before `recordedText` existed.
  if not buf.isNil:
    buf.loadedText = buf.doc.text

proc caretLine*(buf: EditBuffer): int =
  ## 1-BASED. The conversion from the model's 0-based line is
  ## `editing_core.caretLine`'s, in one place, for every front-end — this
  ## module used to do it here for one.
  if buf.isNil: 0 else: buf.doc.caretLine

proc caretColumn*(buf: EditBuffer): int =
  ## 0-based GRAPHEME-CLUSTER column. See `editing_core.caretColumn` for why
  ## the cluster and the CELL are two published numbers rather than one.
  if buf.isNil: 0 else: buf.doc.caretColumn

proc lineCount*(buf: EditBuffer): int =
  if buf.isNil: 0 else: buf.doc.lineCount

proc lines*(buf: EditBuffer): seq[string] =
  if buf.isNil: @[] else: buf.doc.lines

proc moveCaretTo*(buf: EditBuffer; line, column: int) =
  ## Place the caret at a 0-based (line, cluster column).
  ##
  ## The replacement for `buf.widget.moveCursorTo(Caret(...))`, which every
  ## caller of this module used to reach past the binding for. It is the
  ## model's `editing_core.moveCaretTo`, so a caret placed by a mouse click, by
  ## a build-error jump and by a test arranging a starting position all go
  ## through `selection.caretSelection` and all satisfy `FUZZ-3`.
  if buf.isNil:
    return
  buf.doc.moveCaretTo(line, column)

proc folded*(buf: EditBuffer): seq[int] =
  ## Folded logical lines. Held on the MODEL (`EditorState.folded`) rather
  ## than on this object, because a fold is editor state that the collaboration
  ## stream and the GPUI front-end have the same claim on as this pane does.
  if buf.isNil: @[] else: buf.doc.folded

proc `folded=`*(buf: EditBuffer; lines: seq[int]) =
  if not buf.isNil:
    buf.doc.folded = lines

proc followCaret*(buf: EditBuffer; rows: int) =
  ## Scroll the pane so the caret is visible, and no further.
  ##
  ## The pane's own scroll rather than the widget's: see `viewportTop`. A
  ## MINIMAL scroll — the caret entering from the bottom moves the window by
  ## one line, not to the middle — because a jump on every keystroke near an
  ## edge is what makes a terminal editor feel broken.
  ##
  ## The rule is `editing_core.followedViewportTop`, shared with GPUI.
  if buf.isNil:
    return
  buf.viewportTop = followedViewportTop(buf.viewportTop, buf.caretLine, rows)

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

proc editingScope*(buf: EditBuffer): EditingScope =
  ## **THE FIVE DIMENSIONS §4.3 NAMES, AS THIS FRONT-END SETS THEM.**
  ##
  ## `pmEdit` and `epEditor` because this function is only reached when
  ## `runtime.editorOwnsToken` has already established both — Edit product
  ## mode, NORMAL input mode, the editor pane focused, a buffer open. Those
  ## four conditions are already-modelled state and the scope is where they
  ## become the resolver's argument rather than a comment at a call site.
  ##
  ## `textEntry = true` IS THE TERMINAL'S EDIT MODE, and it is not a
  ## shortcut. §4.3's text-entry dimension means *"a printable key stands for
  ## itself"*, which is exactly what Edit mode is: `CodeTracer-TUI-Edit-Mode.md`
  ## §1.2 refuses to collapse the product mode into the pane mode, and the
  ## pane's NORMAL/COMMAND/SEARCH are navigation modes over PANES. A
  ## document opened under the Vim or Kakoune model opens in `emNormal` and
  ## `editing_core.initEditingDocument` is what decides that.
  ##
  ## **`textEntry` FOLLOWS THE DOCUMENT'S MODE, and until PLAT-43 it was
  ## `true` unconditionally.** That was right while the product default was
  ## the only model a key could reach — it opens and stays in `emInsert` — and
  ## it made the other two unusable the moment a selector reached them: under
  ## Vim in normal mode `d` `w` typed `dw` into the buffer instead of deleting
  ## a word, because the resolver's text-entry shadow answers a printable key
  ## with itself before the trie is consulted. Measured on the first run of
  ## `test_plat43_keymap_selector.nim`: Vim's `u` inserted a `u`, and all 38 of
  ## PLAT-31's divergent tasks produced identical documents under Vim and
  ## Kakoune. A printable key stands for itself exactly when the document is
  ## in insert mode, whichever model put it there.
  ##
  ## The rule itself is `editing_core.editScopeOf`, shared with GPUI.
  editScopeOf(buf.doc)

proc claimsEditKey*(buf: EditBuffer; key: string; nowMs: int64): bool =
  ## PLAT-43. Whether this buffer's model binds `key` in its current state —
  ## `editing_core.claimsKey` under this front-end's scope.
  not buf.isNil and buf.doc.claimsKey(buf.editingScope, key, nowMs)

proc applyEditKey*(buf: EditBuffer; key: string; nowMs: int64): EditKeyOutcome =
  ## One canonical key name (`key_names.keyName`'s vocabulary) applied to the
  ## buffer, **through PLAT-31's resolver and PLAT-30's vocabulary**.
  ##
  ## ## PLAT-34 RETIRED THE `case` OVER BEHAVIOURS THAT USED TO BE HERE
  ##
  ## PLAT-30 retired a `case` over KEY NAMES and replaced it with a lookup in
  ## `TuiEditBindings` plus a fourteen-arm `case` over `EditBehaviour` against
  ## an `isonim-tui` `TextAreaWidget`. That left the operation column of the
  ## table a JOIN rather than a call — the ViewModel oracle ran the named
  ## operation, this module ran a widget method, and `DIFF-1` is the axis
  ## PLAT-34 added because nothing executed the edge between them.
  ##
  ## What replaces it is ONE CALL. `product_keymap` LIFTS the same fourteen
  ## rows into the resolver's table (it does not transcribe them), the
  ## resolver walks the trie, and the operation that comes out is applied to
  ## the model. The table still decides which key does what; there is no
  ## longer a second implementation of what doing it MEANS.
  ##
  ## ## `character` IS GONE FROM THE SIGNATURE, AND THAT IS A REPAIR
  ##
  ## It used to be a second parameter the caller computed with
  ## `keyCharacter(name)` and handed back. Every call site therefore had the
  ## chance to hand back the wrong one — which is CTUI-10's measured defect
  ## (`keyName(" ")` is `"Space"`, and inserting the KEY types five letters
  ## into a user's file) sitting one argument away at every caller forever.
  ## `resolve` asks `key_names.keyCharacter` itself, under the text-entry
  ## dimension, so the answer is derived once from the key rather than passed
  ## alongside it. `Space` still inserts a space and never the word, and the
  ## case that asserts it is unchanged.
  ##
  ## ## `nowMs` IS REQUIRED
  ##
  ## PLAT-32's undo grouping reads elapsed time and PLAT-31 never supplied a
  ## clock, so every keystroke reached the model at time zero and grouping
  ## could not break. The runtime already threads `nowMs` through
  ## `handleToken`; this is the parameter that carries it the last step.
  if buf.isNil:
    return ekIgnored
  let applied = buf.doc.applyKey(buf.editingScope, key, nowMs)
  case applied.outcome
  of eoIgnored: ekIgnored
  of eoMoved: ekMoved
  of eoChanged: ekChanged

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc newEditSession*(model = kmProductDefault): EditSession =
  EditSession(buffers: @[], active: NoBuffer, points: @[], editedPaths: @[],
              staleNoticeShown: false, furnished: false, model: model)

proc selectModel*(s: EditSession; model: KeymapModel) =
  ## PLAT-43. Make `model` this session's keymap: every OPEN buffer is re-keyed
  ## through `editing_core.switchModel` (text and history kept) and every
  ## buffer opened later opens under it.
  if s.isNil:
    return
  s.model = model
  for buf in s.buffers:
    buf.doc.switchModel(model)

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
  s.buffers.add newEditBuffer(path, text, viewportHeight, s.model)
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
    # **READ OFF THE MODEL'S SELECTION, WHICH IS MORE THAN THE WIDGET COULD
    # SAY.** The widget carried one caret and one anchor; `EditorSelection`
    # carries N ranges with a primary index, so a multi-cursor edit survives a
    # mode switch or it does not, and this witness is what can tell. Rendered
    # as `anchor-head` per range, primary first in the count, because §5's
    # comparison is a string equality and a shape that dropped the extra
    # ranges would call two different selections preserved.
    var parts: seq[string] = @[]
    for b in s.buffers:
      let sel = b.doc.state.selection
      var ranges: seq[string] = @[]
      for i in 0 ..< sel.rangeCount:
        ranges.add $sel[i].anchor & "-" & $sel[i].head
      parts.add b.path & "@" & $sel.primaryIndex & ":" & ranges.join(",")
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
    selectionActive = buf.doc.hasSelection,
    dirty = buf.isDirty,
    marks = (if s.isNil: @[] else: marksForFile(s.points, buf.path)),
    language = "")
