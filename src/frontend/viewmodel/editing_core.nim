## editing_core.nim — PLAT-34: **THE ONE EDITING CORE, AND THE ONLY MUTABLE
## TEXT BUFFER IN THE PRODUCT.**
##
## Owns: the pairing of `editor/editor_state.EditorState` (the value every one
## of PLAT-30's 224 operations is pure over) with `keymap/` (the layer that
## turns a canonical key name into a sequence of those operations), plus the
## handful of derivations a front-end needs off the result — the text, the
## lines, the caret in the units a painter uses.
##
## =========================================================================
## WHY THIS MODULE IS NOT IN `viewmodel/editor/`
## =========================================================================
##
## `ci/test/editor-import-closure.sh` check 7 (PLAT-31) refuses **any** module
## of `viewmodel/keymap/` in the editing core's transitive closure, because
## `Editing-Operations-And-Keymaps.md` §1's word is *external*: the keymap
## imports the editor and the editor knows nothing about keys. This module
## imports both, so it belongs on the keymap's side of that boundary and not
## in the directory the gate walks. It is the front-end-facing composition,
## not a model module.
##
## =========================================================================
## WHAT "ONE EDITING CORE, TWO FRONT-ENDS" MEANS TODAY — READ THIS FIRST
## =========================================================================
##
## Both front-ends derive their editor from an `EditingDocument`, and **since
## PLAT-44 (2026-09-23) both can change it**, through the same `applyKey` under
## the same `editScopeOf`: the terminal from `edit_binding.applyEditKey`, GPUI
## from `gpui/app/edit_arm.applyGpuiKey`.
##
## Until then the GPUI arm was READ-ONLY, and the asymmetry was a measured
## property of `isonim-gpui` rather than of this model — `PLAT21-VG1` (no key
## payload could be delivered to a view) and `PLAT21-VG3` (no element focus).
## PLAT-38 closed both; PLAT-44 consumed them. The clause is retired here
## rather than deleted so the reason the two arms were ever different stays
## readable.
##
## The WEB front-end is neither arm. It is Monaco plus the legacy Karax path
## and it is not brought onto this model by this milestone;
## `view_vocabulary/editor_surface.nim`'s header carries the measurement and
## PLAT-34's status carries the boundary.
##
## =========================================================================
## THE CLOCK IS A PARAMETER AND IT HAS NO DEFAULT
## =========================================================================
##
## PLAT-32's grouping rule asks `nowMs - prevTime >= NewGroupDelayMs`. Until
## this milestone the keymap layer never supplied a clock, so that comparison
## was `0 - 0 >= 500` on every product keystroke and **undo grouping could not
## break**: an hour of typing was one undo. Every entry point here takes
## `nowMs` positionally and without a default, so a front-end cannot acquire
## the defect by omission — which is exactly how it was acquired.
##
## =========================================================================
## NO MOCKS
## =========================================================================
##
## Nothing here constructs a fake editor, a fake widget or a fake keymap. The
## keymaps are `product_keymap`/`vim_keymap`/`kakoune_keymap`'s own tables and
## the operations are the shipped vocabulary.

import std/[strutils, tables]

import ./editor/editor_state
import ./editor/operations
import ./editor/selection
import ./editor/text_store
import ./editor/wrap
import ./editor/change_set
import ./editor/document_version
import ./editor/reconcile

import ./keymap/editing_keymap
import ./keymap/product_keymap
import ./keymap/vim_keymap
import ./keymap/kakoune_keymap
import ./keymap/keymap_selection
from ./keymap/vim_import import VimImport, ImportReportEntry, ImportReason,
  importVimConfig, coverageFraction, describeReport

export editor_state, selection, wrap
export editing_keymap, product_keymap, vim_keymap, kakoune_keymap
export keymap_selection
export document_version, reconcile
export VimImport, ImportReportEntry, ImportReason, importVimConfig,
  coverageFraction, describeReport

# `Annotation` IS WITHHELD, and the reason is a name collision rather than a
# boundary. `operations` re-exports `editor/transaction`, whose `Annotation` is
# a transaction's typed metadata; `tui/app/views/inline_annotations` has had an
# `Annotation` of its own — an inline value beside a source line — since
# CTUI-5. A front-end that imported both through this facade would get an
# ambiguity error at every mention, in a file that had asked for neither. The
# type stays reachable as `transaction.Annotation` for anything that genuinely
# wants it; what is withheld is the UNQUALIFIED spelling, which no front-end
# has a use for. Stated here rather than fixed at the collision site, because
# moving somebody else's five-year-old name to make a new export fit is the
# wrong direction (§35's fifth firing decided the same question the other way,
# and the difference is that there the needle had EARNED its place).
export operations except Annotation

type
  EditingOutcome* = enum
    ## What one key did to the document, from the FRONT-END's point of view.
    ##
    ## THREE ANSWERS AND NOT A `bool`, carried across from
    ## `edit_binding.EditKeyOutcome` unchanged because the distinction is the
    ## same one and it is load-bearing in the same place: the first marks the
    ## file dirty, the second only repaints, and the third must be handed back
    ## to the PRODUCT keymap. A `bool` merges the first two and a caller then
    ## records an edit for every arrow key — which is the input
    ## `product_mode.assessTrace` must not get, because it would declare a
    ## recording stale because somebody scrolled.
    eoIgnored = "ignored"
    eoMoved = "moved"
    eoChanged = "changed"

  EditingDocument* = object
    ## **ONE OPEN FILE, AND THE MODEL IS THE FILE.**
    ##
    ## A VALUE and not a `ref`, which is what makes the differential possible
    ## at all: two front-ends applying one sequence to one document are two
    ## values a case can compare with `==`, and `EditorState.==` is field by
    ## field over every field. A `ref` would make that comparison an identity
    ## test that is either trivially true or trivially false.
    path*: string
    state*: EditorState
      ## **THE BUFFER.** There is no second one. `ci/test/editor-model-case-floor.sh`
      ## is not what enforces that — `test_editor_front_end_differential.nim`'s
      ## mutable-buffer scan is, with a planted positive control.
    model*: KeymapModel
      ## Which keymap this document resolves keys through. A document-level
      ## field rather than a global, because §4.2 makes the model the fifth
      ## scope dimension and a product that can only hold one model cannot
      ## have `DIFF-4` as a runtime property.
    settings*: WrapSettings
      ## The renderer's own wrap configuration. PLAT-27's settled decision is
      ## that this is a PARAMETER and never a field of `EditorState`; it is a
      ## field HERE because a document is opened *by* a front-end, and that
      ## front-end's settings are what its own derivations are taken at.
    viewportRows*: int
    timeline*: VersionedDocument
      ## PLAT-29 §11: *"edits apply synchronously and the resulting state
      ## carries a version"*. The document's text and the change sets that
      ## moved it, drained from `EditorState.journal` after every key — so an
      ## asynchronous producer (a highlight, a file read, a write's
      ## acknowledgement) can name the version it was computed against and be
      ## reconciled against this document rather than applied as though it had
      ## not moved. Bounded to `TimelineDepth` change sets.
    imported*: ImportedKeymap
      ## PLAT-36. A user's Vim configuration, imported on top of the Vim
      ## keymap (`:source <file>` in the terminal). Nil — the common case —
      ## means the document resolves through `keymapOf(model)`, the shipped
      ## model. A `ref` so the one imported keymap is shared by every buffer
      ## of a session rather than copied into each, and because it never
      ## changes after the import: a new `:source` installs a new one.

  ImportedKeymap* = ref object
    ## An imported configuration, reduced to what resolution needs: the
    ## bindings (the Vim keymap with the user's mappings layered on it) and
    ## the multi-operation right-hand sides those bindings replay, which
    ## `EditorState.macros` must hold before a key can resolve to one.
    source*: string
      ## Where it was read from, as the user spelled it — for the status line.
    keymap*: EditingKeymap
    macros*: Table[string, seq[string]]

  KeyApplication* = object
    ## The whole of what one key did, as a value.
    outcome*: EditingOutcome
    operations*: seq[string]
      ## The named operations that ran — §2.2's vocabulary, which is what
      ## makes a macro, a collaboration envelope and a `DIFF-4` row the same
      ## kind of thing.
    resolution*: EditingResolutionKind
    timedOut*: bool

const
  DefaultViewportRows* = 20
  TimelineDepth* = 256
    ## How many change sets a document's timeline remembers. A producer
    ## result older than that is `drVersionForgotten` — counted, not an error.
    ## Two hundred and fifty-six keystrokes is minutes of typing ahead of a
    ## parse that takes milliseconds; a result that far behind is one nobody
    ## wants mapped.

func terminalWrapSettings*(): WrapSettings =
  ## The configuration the TUI's edit pane runs at, in ONE place.
  ##
  ## `wrapColumn: 0` — soft wrap is OFF. `edit_binding.newEditBuffer` has
  ## passed `softWrap = false` since PLAT-16 and its reason is unchanged: this
  ## pane sits in a column beside a file tree, and a wrapped line would stop
  ## the gutter's line numbers lining up with the rows they number, which is
  ## the one thing a debugger's source column may not do.
  WrapSettings(wrapColumn: 0, policy: DefaultColumnPolicy)

func initialModeFor*(model: KeymapModel): EditingMode =
  ## The mode a document opens in under `model` — see `initEditingDocument` on
  ## why it is the model's to decide. One `case`, total over the enum, used by
  ## both the constructor and `switchModel`.
  case model
  of kmProductDefault: emInsert
  of kmVim, kmKakoune: emNormal

proc dropImported(d: var EditingDocument) =
  ## Take an imported configuration off `d`, macros included: a macro id the
  ## import minted must not outlive the bindings that replay it.
  if d.imported.isNil:
    return
  for id in d.imported.macros.keys:
    d.state.macros.del id
  d.imported = nil

proc switchModel*(d: var EditingDocument; model: KeymapModel) =
  ## PLAT-43. Re-key an OPEN document to `model`.
  ##
  ## The text, the selection, the registers, the marks, the undo history and
  ## the last change are the DOCUMENT and are kept. What belongs to the old
  ## model's grammar is reset: the mode (to the new model's opening mode, as
  ## `initEditingDocument` would choose it), a pending count, a pending
  ## operator, a half-typed chord and a macro being recorded — a Vim `d`
  ## waiting for its motion must not be completed by a Kakoune key.
  d.dropImported()
  d.model = model
  d.state.mode = initialModeFor(model)
  d.state.count = 0
  d.state.pendingOperator = ""
  d.state.pending = PendingChords()
  d.state.recording = ""

proc initEditingDocument*(path, text: string;
                          model = kmProductDefault;
                          settings = terminalWrapSettings();
                          viewportRows = DefaultViewportRows): EditingDocument =
  ## A document over `text`, named `path`, with the caret at the top.
  ##
  ## **THE MODE IS `emInsert` AND THAT IS NOT A DETAIL.** `initEditorState`
  ## opens at `emNormal` because that is the right default for a modal model,
  ## and `product_keymap`'s thirteen rows are scoped to `{emInsert}` — see
  ## `ProductDefaultModes`, whose reason is that *"the terminal's Edit mode
  ## has no modal editing at all"*. A product document left at `emNormal`
  ## resolves none of its own bindings, so `Left` does nothing and every
  ## printable key is handed back to the debugger's keymap. The mode is set
  ## from the MODEL rather than hardcoded, because a Vim document must open in
  ## normal mode or `dd` is typed into the buffer.
  result = EditingDocument(
    path: path,
    state: initEditorState(text),
    model: model,
    settings: settings,
    viewportRows: max(1, viewportRows),
    timeline: initVersionedDocument(text))
  result.state.mode = initialModeFor(model)

proc drainJournal*(d: var EditingDocument) =
  ## Move the change sets the last step applied from the model's journal onto
  ## the timeline, one version each. The ONLY writer of `timeline` besides the
  ## constructor, so the timeline's text and the model's `doc` cannot part.
  ## EVERY writer of `d.state` calls it — `applyKey`, `applyNamed`,
  ## `applyChangeSet` here, and the collaboration projection's two — so a
  ## document leaves each call with an empty journal.
  for cs in d.state.journal:
    discard d.timeline.applyChanges(cs)
  d.state.journal.setLen(0)
  d.timeline.keepRecent(TimelineDepth)

func version*(d: EditingDocument): DocumentVersion =
  ## The version an asynchronous producer names when it is handed this
  ## document's text.
  d.timeline.version

proc applyChangeSet*(d: var EditingDocument; cs: ChangeSet;
                     nowMs: int64): bool =
  ## A change that did NOT come from a key — a file read installing the
  ## disk's bytes after `reconcile` let it through. It goes through
  ## `operations.commitChange`, the one place the document moves, so it is
  ## undoable, maps every mark and line table, and is journaled onto the
  ## timeline like any keystroke. Returns whether the text moved.
  let before = d.state.doc
  d.state = commitChange(d.state, cs, userEvent = ueInput, nowMs = nowMs)
  d.drainJournal()
  d.state.doc != before

proc installImported*(d: var EditingDocument; imported: ImportedKeymap) =
  ## PLAT-36. Put `d` under an imported Vim configuration. The model becomes
  ## `kmVim` — the import is layered on the Vim keymap, so the grammar the
  ## document is in IS Vim's — through `switchModel`, which keeps the text and
  ## history and resets a half-typed chord exactly as a `:keymap` does. A nil
  ## `imported` leaves `d` under the plain Vim keymap.
  d.switchModel(kmVim)
  if imported.isNil:
    return
  d.imported = imported
  for id, steps in imported.macros:
    d.state.macros[id] = steps

type
  SourcedConfig* = object
    ## PLAT-36. What reading one Vim configuration produced, for a front-end
    ## to install and to report: the keymap, and §6.3's headline and report.
    imported*: ImportedKeymap
    translated*: int
      ## Mapping lines that became bindings (or deliberate unbinds).
    mappings*: int
      ## Every mapping line — the partition law's denominator.
    report*: seq[ImportReportEntry]
      ## Every line that could not be translated, with its reason.

proc sourceVimConfig*(source, text: string): SourcedConfig =
  ## Import `text` (a `.vimrc` / `init.vim`) ON TOP OF the shipped Vim
  ## keymap, which is what a Vim user's configuration assumes it is layered
  ## on: an `nnoremap Q dd` is written against Vim's `dd`, and an import over
  ## an empty keymap would leave every unmapped key dead. `source` is only
  ## carried for the status line.
  let imp = importVimConfig(text, vimKeymap().keymap)
  let (translated, mappings) = coverageFraction(imp)
  SourcedConfig(
    imported: ImportedKeymap(source: source, keymap: imp.keymap,
                             macros: imp.macros),
    translated: translated, mappings: mappings, report: imp.report)

func sourcedSummary*(c: SourcedConfig): string =
  ## One status line: §6.3's *"a count, not a list"* — N of M — and, when
  ## anything was reported, the FIRST reported line with its reason, so the
  ## gap is named at the moment the user asked rather than discovered later
  ## through muscle memory failing.
  let source = if c.imported.isNil: "" else: c.imported.source
  result = "sourced " & source & ": " & $c.translated & " of " &
           $c.mappings & " mapping line(s) translated"
  if c.report.len > 0:
    let first = c.report[0]
    result.add "; " & $c.report.len & " not translated, first at line " &
               $first.line & ": " & $first.reason

proc keymapOf*(model: KeymapModel): KeymapDefinition =
  ## The three shipped models, by name. **ONE `case`, and it is total over the
  ## enum**, so a fourth model does not compile rather than resolving to the
  ## default and looking like it works.
  case model
  of kmProductDefault: productKeymap()
  of kmVim: vimKeymap()
  of kmKakoune: kakouneKeymap()

proc applyKey*(d: var EditingDocument; scope: EditingScope; key: string;
               nowMs: int64): KeyApplication =
  ## **ONE KEY, THROUGH THE KEYMAP LAYER, ONTO THE MODEL.** This is the whole
  ## of what a front-end does with a keystroke, and there is no other route.
  ##
  ## It is one call to `editing_keymap.applyKey` and a three-way reading of
  ## the answer — never a second resolver. The reading is the only part that
  ## is this module's own:
  ##
  ##   * `erNothing` is **not the editor's key**. The product keymap gets it.
  ##     This is the one answer a front-end must not confuse with the next,
  ##     because it is the difference between `F10` stepping the debugger and
  ##     `F10` being swallowed by a buffer.
  ##   * anything else is the editor's; whether it CHANGED the document is a
  ##     comparison of the document, not a property of the behaviour's name.
  ##     `undo` with an empty history is `eoMoved`: the key was ours and the
  ##     buffer is clean.
  ##
  ## A pending prefix is `eoMoved` for the same reason — the user is part-way
  ## through spelling a command, the key was consumed, and the status line has
  ## something new to show.
  if key.len == 0:
    return KeyApplication(outcome: eoIgnored, operations: @[],
                          resolution: erNothing, timedOut: false)
  let docBefore = d.state.doc
  let step =
    if d.imported.isNil:
      editing_keymap.applyKey(d.state, keymapOf(d.model).keymap, scope,
                              key, d.settings, nowMs, d.viewportRows)
    else:
      editing_keymap.applyKey(d.state, d.imported.keymap, scope,
                              key, d.settings, nowMs, d.viewportRows)
  d.state = step.state
  d.drainJournal()
  let outcome =
    case step.kind
    of erNothing: eoIgnored
    of erPending: eoMoved
    of erOperation, erCharacter:
      if d.state.doc != docBefore: eoChanged else: eoMoved
  KeyApplication(outcome: outcome, operations: step.operations,
                 resolution: step.kind, timedOut: step.timedOut)

func followedViewportTop*(top, caretLine, rows: int): int =
  ## The first visible line after the minimal scroll that brings `caretLine`
  ## into a `rows`-high window starting at `top` — ONE rule for every
  ## front-end (the terminal's `edit_binding.followCaret` and GPUI's edit arm
  ## both call it). MINIMAL: the caret entering from the bottom moves the
  ## window by one line, not to the middle, because a jump on every keystroke
  ## near an edge is what makes an editor feel broken. 1-based lines.
  result = top
  if rows <= 0 or caretLine <= 0:
    return
  if caretLine < result:
    result = caretLine
  elif caretLine > result + rows - 1:
    result = caretLine - rows + 1
  if result < 1:
    result = 1

func editScopeOf*(d: EditingDocument): EditingScope =
  ## **THE SCOPE A FRONT-END'S EDITOR PANE RESOLVES KEYS IN**, for a focused
  ## editor in Edit product mode — one rule for every front-end (PLAT-44: the
  ## terminal and GPUI both call this; §30b).
  ##
  ## `textEntry` follows the document's MODE: a printable key stands for
  ## itself exactly in insert mode, whichever model put the document there.
  ## PLAT-43 measured the alternative: the terminal passed `true`
  ## unconditionally, and under Vim in normal mode `d` `w` typed `dw`.
  EditingScope(model: d.model, product: pmEdit, pane: epEditor,
               mode: d.state.mode, textEntry: d.state.mode == emInsert)

proc claimsKey*(d: EditingDocument; scope: EditingScope; key: string;
                nowMs: int64): bool =
  ## PLAT-43. Would `applyKey` treat `key` as the editor's? The same resolver,
  ## asked without executing: `erNothing` is the one answer that hands the key
  ## back to the product keymap, exactly as `applyKey` reads it.
  if key.len == 0:
    return false
  editing_keymap.resolveKey(d.state, keymapOf(d.model).keymap, scope, key,
                            nowMs).kind != erNothing

proc applyNamed*(d: var EditingDocument; name: string; args: OpArgs;
                 nowMs: int64): EditingOutcome =
  ## One NAMED operation, with no key involved.
  ##
  ## This is the door a collaboration peer, a script and a macro come through,
  ## and §2.2's own words for why it exists beside the key path: *"an
  ## operation a test can only reach through the keymap is an operation the
  ## collaboration and scripting layers cannot reach either"*. An unknown name
  ## RAISES, which is `applyOperation`'s published contract and is not
  ## softened here.
  let docBefore = d.state.doc
  let r = applyOperation(d.state, name, args, d.settings, d.viewportRows, nowMs)
  d.state = r.state
  d.drainJournal()
  if d.state.doc != docBefore: eoChanged
  elif r.outcome == ooRefused: eoIgnored
  else: eoMoved

# ---------------------------------------------------------------------------
# THE DERIVATIONS A FRONT-END PAINTS FROM
#
# Every one is a pure function of `EditingDocument` and holds nothing. Two
# frames are two values and the difference between them is exactly the
# difference on screen — which is the property `DIFF-1`'s second half is read
# against.
# ---------------------------------------------------------------------------

func text*(d: EditingDocument): string =
  d.state.doc

func lines*(d: EditingDocument): seq[string] =
  ## **THE BUFFER'S LINES — every position the caret can be on, including the
  ## empty one after a trailing terminator.**
  ##
  ## This is `wrap.documentLines`, called and not re-derived. §30a: a third
  ## spelling of "split a document into lines" would agree with the other two
  ## for the same reason each agrees with itself, and `documentLines`' own
  ## header records why it is not `strutils.splitLines` (which also splits on
  ## a lone CR and would give a different line count from the store it must
  ## agree with — PLAT-24's `unrepresentable.tsv`, row 1).
  ##
  ## ## THE OTHER COUNT IS A NAMED POLICY AND PLAT-28 ALREADY NAMED IT
  ##
  ## "How many lines" is two questions. Measured on
  ## `"proc alpha() =\n  echo 1\n  echo 2\n  echo 3\n"` (42 bytes):
  ##
  ## | asked | answer |
  ## | --- | --- |
  ## | `text_store.lineCount` / `wrap.documentLines` — the coordinate model | **5** |
  ## | `isonim-tui`'s `TextAreaWidget.lineCount` — the terminal, before PLAT-34 | **5** |
  ## | `editorSurfaceForProject` — the GPUI surface | **4** |
  ## | the caret after eight `move-line-down`s | offset 42, **line 5** |
  ##
  ## Both are right, and `row_projection.TrailingLinePolicy` is the enum
  ## PLAT-28 declared so that a caller says WHICH — `tlpKeep` is this
  ## function's answer and what the coordinate model counts, and
  ## `tlpDropFinalEmpty` is the number a user counts. A BUFFER is asked the
  ## first question: the caret reaches the end of the document and `posOf`
  ## puts that on the fifth line, so a `lines` that returned four would
  ## publish a `caretLine` its own `lineCount` cannot contain.
  ##
  ## **THIS FUNCTION HAD ITS OWN COPY OF THE POLICY FOR THE LENGTH OF ONE
  ## FLOOR-GATE RUN, AND PLAT-28's SUITE FAILED IT BY NAME.** The case is
  ## *"THE TRAILING-LINE POLICY IS A NAMED DECISION AND BOTH ARMS ARE
  ## REACHED"*, which pins `editorSurfaceForProject` to `tlpDropFinalEmpty`
  ## and `wrap.documentLines` to `tlpKeep`. A milestone that had quietly moved
  ## one of them would have been rewriting somebody else's decision; what it
  ## moved instead is which ENTRY POINT asks which question.
  wrap.documentLines(d.state.doc)

func lineCount*(d: EditingDocument): int =
  ## Buffer rows — the same number `lines.len` is, taken without building them.
  toTextStore(d.state.doc).lineCount

# **THE "NUMBER A USER COUNTS" RULE IS NOT A FUNCTION HERE, AND THAT IS A
# DECISION RATHER THAN AN OMISSION.** `editorSurfaceForProject` carried a
# `splitLines`-and-drop under the argument that *"a file of four lines that
# ends the way every text file ends would report five"*, and the honest
# reading of the measurement above is that the argument is about a FILE while
# this type is a BUFFER. A `fileLineCount` was written, and deleted before it
# landed, because nothing reached it: PLAT-31's reachability ratchet deleted
# three exports for exactly that reason (*"a public helper nobody calls is not
# a backlog item waiting for a caller; it is coverage-shaped dead code"*), and
# the rule is recorded where a reader needs it — in `lines` above — rather
# than as an export with no consumer. The day a status line wants it, it
# arrives with its caller.

func caretPosOf*(doc: string; head: int): TextPos =
  ## `toTextStore(doc).posOf(head)`, by ONE SCAN of the bytes before `head`
  ## — no rope built, nothing allocated. The same answer, and asserted to be
  ## by `test_plat29_highlight_producer.nim` over every offset of the corpus.
  ##
  ## Measured before it existed: `caretLine` and `caretColumn` each built a
  ## rope of the whole document, and every frame asks both — on a
  ## 24,000-line buffer that was tens of milliseconds a frame for two
  ## numbers.
  let off = clamp(head, 0, doc.len)
  var line = 0
  var lineStart = 0
  for i in 0 ..< off:
    if doc[i] == '\n':
      inc line
      lineStart = i + 1
  TextPos(line: line, column: off - lineStart)

proc caretPos(d: EditingDocument): TextPos =
  caretPosOf(d.state.doc, d.state.primaryHead)

proc caretLine*(d: EditingDocument): int =
  ## **1-BASED**, because the gutter, the pane and every message a user reads
  ## are 1-based and the model's positions are 0-based. Converted in exactly
  ## one place, which is here.
  d.caretPos.line + 1

proc caretColumn*(d: EditingDocument): int =
  ## **0-based GRAPHEME-CLUSTER column within the caret's line.**
  ##
  ## The unit is the cluster and not the byte, and that is a contract rather
  ## than a convenience: `views/edit_pane.EditPaneModel.caretColumn` has been
  ## documented as the cluster column since PLAT-16, and a byte column would
  ## put the caret three cells into a Devanagari cluster on the corpus's own
  ## documents. The clustering is `wrap.lineMetrics` — the same segmentation
  ## every display row is built from — rather than a second walk, because a
  ## second walk is §30a's whole subject.
  ##
  ## **THE CELL COLUMN IS A DIFFERENT NUMBER AND IT IS NOT PUBLISHED HERE.** A
  ## tab is one cluster and `policy.tabSize` cells, and a wide CJK cluster is
  ## one cluster and two cells, so a painter placing a cursor wants cells
  ## while a caller asking "which cluster is the caret on" wants this. A
  ## `caretDisplayColumn` was written and DELETED before it landed, because
  ## nothing reached it: `views/edit_pane` places the caret at
  ## `area.col + gutter + caretColumn`, which is the cells reading of a
  ## clusters number and agrees on ASCII. That disagreement is a real one and
  ## it is recorded HERE rather than as an export with no consumer (PLAT-31's
  ## ratchet rule: *"a public helper nobody calls is not a backlog item
  ## waiting for a caller; it is coverage-shaped dead code"*). The day a
  ## medium places a cursor on a tab, the function arrives with its caller.
  let pos = d.caretPos
  # The caret's line only — its start is `column` bytes back from the head,
  # its end the next newline — rather than every line of the document.
  let head = clamp(d.state.primaryHead, 0, d.state.doc.len)
  let lineStart = head - pos.column
  var lineEnd = d.state.doc.find('\n', lineStart)
  if lineEnd < 0: lineEnd = d.state.doc.len
  let metrics = lineMetrics(d.state.doc[lineStart ..< lineEnd],
                            d.settings.policy)
  for i, c in metrics.clusters:
    if c.startByte >= pos.column:
      return i
  metrics.clusters.len

proc moveCaretTo*(d: var EditingDocument; line, column: int) =
  ## Place the caret at a 0-based (line, cluster column).
  ##
  ## The one non-key, non-operation writer of the selection, and it exists for
  ## the reason every editor needs one: a mouse click, a jump from a build
  ## error and a test arranging a starting position are all "put the caret
  ## there" and none of them is a keystroke. It goes through
  ## `selection.caretSelection` rather than assigning a range, so the
  ## normalisation invariant `FUZZ-3` asserts holds by construction.
  let ls = d.lines
  if ls.len == 0:
    d.state.selection = caretSelection(0)
    return
  let l = clamp(line, 0, ls.len - 1)
  let metrics = lineMetrics(ls[l], d.settings.policy)
  let byteInLine =
    if column <= 0: 0
    elif column >= metrics.clusters.len: metrics.byteLen
    else: metrics.clusters[column].startByte
  let store = toTextStore(d.state.doc)
  d.state.selection = caretSelection(
    store.offsetOf(TextPos(line: l, column: byteInLine)))

func hasSelection*(d: EditingDocument): bool =
  ## Whether any range spans text. A caret is a range of zero length, so
  ## `rangeCount > 0` is not the question — every state has at least one.
  for i in 0 ..< d.state.selection.rangeCount:
    if not d.state.selection[i].isEmpty:
      return true
  false

func folded*(d: EditingDocument): seq[int] =
  ## Folded logical lines, 1-based, as the model holds them.
  d.state.folded

proc `folded=`*(d: var EditingDocument; lines: seq[int]) =
  d.state.folded = lines
