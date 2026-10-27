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
## The WEB front-end is neither arm. It EDITS through Monaco's own buffer, not
## through this module, and it READS the shared editor surface
## (`view_vocabulary/editor_surface.editorSurfaceForView`, through
## `ui/editor_points`) for the execution line, the gutter marks and the values
## — Shared-DOM-Front-Ends D7.4 (a). Whether web editing is routed through
## this core is PLAT-67's question (the shared editor on the desktop behind a
## developer flag) and is not decided here.
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
## keymaps are the shipped bases' own tables (`cua_keymap`, `emacs_keymap`,
## `vim_keymap`, `kakoune_keymap`) and
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
import ./editor/transaction
import ./viewmodels/horizontal_scroll

import ./keymap/editing_keymap
import ./keymap/base_rows
import ./keymap/base_keymaps
import ./keymap/cua_keymap
import ./keymap/emacs_keymap
import ./keymap/vim_keymap
import ./keymap/kakoune_keymap
import ./keymap/keymap_selection
from ./keymap/vim_import import VimImport, ImportReportEntry, ImportReason,
  importVimConfig, coverageFraction, describeReport

export editor_state, selection, wrap, horizontal_scroll
export editing_keymap, base_rows, base_keymaps, cua_keymap, emacs_keymap,
  vim_keymap, kakoune_keymap
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
    model*: BaseKeymap
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
    delivery*: KeyDelivery
      ## PLAT-68: how keys reach this document — the front-end, the platform
      ## and the negotiated key protocol, Base-Keymaps §4.2's three keys a
      ## front-end supplies. A field for `settings`' reason: a document is
      ## opened BY a front-end, and that front-end's delivery is what the
      ## `when` of a legacy-fallback row reads.
    imported*: ImportedKeymap
      ## PLAT-36. A user's Vim configuration, imported on top of the Vim
      ## keymap (`:source <file>` in the terminal). Nil — the common case —
      ## means the document resolves through `keymapOf(model)`, the shipped
      ## model. A `ref` so the one imported keymap is shared by every buffer
      ## of a session rather than copied into each, and because it never
      ## changes after the import: a new `:source` installs a new one.
    widths*: LineWidths
      ## Horizontal-Overflow.md §4.1: every line's width in view columns
      ## (`ViewColumnPolicy`) and the widest — the editor's EXACT content
      ## width, maintained per line by `drainJournal` as change sets arrive,
      ## never re-measured over the document on a frame (`contentCols`).

  LineWidths* = object
    ## The width of every line in view columns (`ViewColumnPolicy`), the
    ## widest, and how many lines are that wide — so a change re-measures only
    ## the lines it touched, and a shrinking widest line is found again from
    ## the stored numbers, not from the text.
    widths*: seq[int]
    widest*: int
    atWidest*: int
    valid*: bool
      ## Measured; until then the first `contentCols` measures every line.
    version*: DocumentVersion
      ## The timeline version the widths describe.
    docLen*: int

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

func initialModeFor*(model: BaseKeymap): EditingMode =
  ## The mode a document opens in under `model` — see `initEditingDocument` on
  ## why it is the base's to decide: the modal bases open in normal, the
  ## others ready to type (Editor-ViewModel §3.2 as amended by PLAT-68).
  if isModal(model): emNormal else: emInsert

proc dropImported(d: var EditingDocument) =
  ## Take an imported configuration off `d`, macros included: a macro id the
  ## import minted must not outlive the bindings that replay it.
  if d.imported.isNil:
    return
  for id in d.imported.macros.keys:
    d.state.macros.del id
  d.imported = nil

func searchCaseSensitiveFor*(model: BaseKeymap): bool =
  ## PLAT-70 Part C (Find-And-Incremental-Search.md §3.1): a base's default
  ## for Match Case. **Case-insensitive under CUA** (VS Code) and **under
  ## Emacs** (`case-fold-search`; the find session turns it on while the
  ## query has an upper-case letter, `find_vm.FindCaseRule`), **case-
  ## sensitive under Vim and Kakoune** (Vim's `noignorecase`, Kakoune's
  ## regex).
  model in {bkVim, bkKakoune}

proc installBaseDefaults(d: var EditingDocument) =
  ## What a document takes from its base when it opens under one (or is
  ## re-keyed to one): the search's Match Case default, and the base's
  ## macro rows' bodies (`KeymapDefinition.macros`), which the rows replay
  ## from `EditorState.macros` as PLAT-36's imported macros are replayed.
  d.state.search.options.caseSensitive = searchCaseSensitiveFor(d.model)
  for m in keymapOf(d.model).macros:
    d.state.macros[m.id] = m.steps

proc switchModel*(d: var EditingDocument; model: BaseKeymap) =
  ## PLAT-43. Re-key an OPEN document to `model`.
  ##
  ## The text, the selection, the registers, the marks, the undo history and
  ## the last change are the DOCUMENT and are kept. What belongs to the old
  ## model's grammar is reset: the mode (to the new model's opening mode, as
  ## `initEditingDocument` would choose it), a pending count, a pending
  ## operator, a half-typed chord and a macro being recorded — a Vim `d`
  ## waiting for its motion must not be completed by a Kakoune key.
  d.dropImported()
  for m in keymapOf(d.model).macros:
    d.state.macros.del m.id
  d.model = model
  d.state.mode = initialModeFor(model)
  d.state.count = 0
  d.state.pendingOperator = ""
  d.state.pending = PendingChords()
  d.state.recording = ""
  d.installBaseDefaults()

const TerminalLegacyDelivery* = KeyDelivery(
    frontEnd: feTerminal, platform: hostPlatform(), keyProtocol: kpLegacy)
  ## A terminal that negotiated no extended key reporting — the most
  ## conservative delivery, and the one a document opened with no front-end
  ## (a suite, a headless run) resolves under.

proc initEditingDocument*(path, text: string;
                          model = bkCua;
                          settings = terminalWrapSettings();
                          viewportRows = DefaultViewportRows;
                          delivery = TerminalLegacyDelivery): EditingDocument =
  ## A document over `text`, named `path`, with the caret at the top.
  ##
  ## **THE MODE IS THE BASE'S.** `initEditorState` opens at `emNormal`
  ## because that is the right default for a modal base; a CUA or Emacs
  ## document opens in `emInsert`, ready to type, and a Vim document must
  ## open in normal mode or `dd` is typed into the buffer (`initialModeFor`).
  result = EditingDocument(
    path: path,
    state: initEditorState(text),
    model: model,
    settings: settings,
    viewportRows: max(1, viewportRows),
    timeline: initVersionedDocument(text),
    delivery: delivery)
  result.state.mode = initialModeFor(model)
  result.installBaseDefaults()

const ViewColumnPolicy* = ColumnPolicy(tabSize: 1, ambiguous: awNarrow)
  ## THE COLUMNS OF THE HORIZONTAL VIEW (Horizontal-Overflow.md §4): the
  ## columns the native front-ends DRAW a line in. A tab is ONE column —
  ## neither the terminal's grid (`styled_row.cellWidthOf`) nor GPUI's rows
  ## (`leaves.dropColumns`, by rune) expand it — and a wide glyph two. The
  ## editing settings' `policy` (tabs to the next multiple of 4) decides goal
  ## columns; measuring the view with it would make a tabbed line's bar
  ## promise columns the pane never draws, and put the caret-follow's caret
  ## where the caret is not.

func lineViewWidth*(line: string): int =
  ## A line's width in view columns (`ViewColumnPolicy`): `selection.columnAt`
  ## at its end. A line of printable ASCII is its length, without segmenting
  ## it.
  for c in line:
    if ord(c) >= 0x80 or ord(c) < 0x20:
      return columnAt(line, line.len, ViewColumnPolicy)
  line.len

proc recountWidest(w: var LineWidths) =
  w.widest = 0
  w.atWidest = 0
  for x in w.widths:
    if x > w.widest:
      w.widest = x
      w.atWidest = 1
    elif x == w.widest:
      inc w.atWidest

proc measureLines(text: string; first, count: int): seq[int] =
  ## The widths of `count` lines of `text` from the line starting at byte
  ## `first`.
  var at = first
  for i in 0 ..< count:
    var stop = text.find('\n', at)
    if stop < 0: stop = text.len
    result.add lineViewWidth(text[at ..< stop])
    at = stop + 1

proc measureAll(d: var EditingDocument) =
  let text = d.state.doc
  var lines = 1
  for c in text:
    if c == '\n': inc lines
  d.widths = LineWidths(widths: measureLines(text, 0, lines),
                        valid: true, version: d.timeline.version,
                        docLen: text.len)
  d.widths.recountWidest()

proc remeasure(d: var EditingDocument; before, after: string; cs: ChangeSet) =
  ## The lines one change set touched, measured again: from the line its
  ## first change starts on to the line its last change ends on, in the old
  ## text, replaced by the same span of the new one.
  let ranges = cs.changedRangeSeq()
  if ranges.len == 0:
    return
  let aFrom = ranges[0].fromA
  var firstLine = 0
  var lineStart = 0
  for i in 0 ..< aFrom:
    if before[i] == '\n':
      inc firstLine
      lineStart = i + 1
  var oldLast = firstLine
  for i in aFrom ..< ranges[^1].toA:
    if before[i] == '\n': inc oldLast
  var newLast = firstLine
  for i in aFrom ..< ranges[^1].toB:
    if after[i] == '\n': inc newLast
  let fresh = measureLines(after, lineStart, newLast - firstLine + 1)
  var w = d.widths
  if oldLast >= w.widths.len:
    d.widths.valid = false
    return
  for i in firstLine .. oldLast:
    if w.widths[i] == w.widest: dec w.atWidest
  w.widths = w.widths[0 ..< firstLine] & fresh & w.widths[oldLast + 1 .. ^1]
  for x in fresh:
    if x > w.widest:
      w.widest = x
      w.atWidest = 1
    elif x == w.widest:
      inc w.atWidest
  if w.atWidest <= 0:
    w.recountWidest()
  d.widths = w

proc drainJournal*(d: var EditingDocument) =
  ## Move the change sets the last step applied from the model's journal onto
  ## the timeline, one version each. The ONLY writer of `timeline` besides the
  ## constructor, so the timeline's text and the model's `doc` cannot part.
  ## EVERY writer of `d.state` calls it — `applyKey`, `applyNamed`,
  ## `applyChangeSet` here, and the collaboration projection's two — so a
  ## document leaves each call with an empty journal.
  ##
  ## Each change set also re-measures the lines it touched (`widths`), once
  ## they have been measured at all.
  for cs in d.state.journal:
    let before = d.timeline.text
    discard d.timeline.applyChanges(cs)
    if d.widths.valid:
      d.remeasure(before, d.timeline.text, cs)
  d.state.journal.setLen(0)
  d.timeline.keepRecent(TimelineDepth)
  if d.widths.valid:
    d.widths.version = d.timeline.version
    d.widths.docLen = d.state.doc.len

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
  ## `bkVim` — the import is layered on the Vim keymap, so the grammar the
  ## document is in IS Vim's — through `switchModel`, which keeps the text and
  ## history and resets a half-typed chord exactly as a `:keymap` does. A nil
  ## `imported` leaves `d` under the plain Vim keymap.
  d.switchModel(bkVim)
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

func isReadOnly*(d: EditingDocument): bool =
  ## The document refuses local edits (PLAT-33's read-only filter) — the
  ## Debug-mode editor until `editor.toggle-read-only`, the desktop's
  ## `Ctrl+E`.
  isReadOnly(d.state)

proc setReadOnly*(d: var EditingDocument; readOnly: bool) =
  ## **THE EDITOR'S READ-ONLY OPERATION**, one place for every front-end: put
  ## PLAT-33's read-only filter on the document, or take it off. Selection,
  ## caret motion and copy are untouched by it — only edits are refused —
  ## which is Monaco's read-only mode and the user's requirement
  ## (2026-10-12: Shift+arrows select in the read-only editor).
  var kept: seq[TransactionFilter] = @[]
  for f in d.state.filters:
    if f.kind != tfReadOnly: kept.add f
  if readOnly: kept.add TransactionFilter(kind: tfReadOnly)
  d.state.filters = kept

func clipboardText*(d: EditingDocument): string =
  ## What the last `clipboard-copy` / `clipboard-cut` put on the clipboard
  ## register, for the host to hand to the platform's clipboard (§5.2: the
  ## core performs no I/O).
  d.state.registers.getOrDefault(ClipboardRegister).text

proc offerClipboard*(d: var EditingDocument; text: string) =
  ## The platform's clipboard, handed in by the host before a
  ## `clipboard-paste`: a payload ending in a newline is linewise, VS Code's
  ## whole-line copy coming back as whole lines.
  d.state.setRegister(ClipboardRegister, Register(
    text: text, kind: (if text.endsWith("\n"): rkLinewise else: rkCharwise)))

proc applyResolved*(d: var EditingDocument; res: EditingResolution;
                    nowMs: int64): KeyApplication =
  ## A resolution a ROUTER computed (`keymap_router.route`: every layer on the
  ## scope path, the user's rows, the pushed modes), executed on this
  ## document. The router owns the pending prefix, so the document's stays
  ## empty; everything else is `applyKey`'s reading of the answer.
  var local = res
  local.pending = PendingChords()
  let docBefore = d.state.doc
  let (next, ops) = applyResolution(d.state, local, d.settings, nowMs,
                                    d.viewportRows)
  d.state = next
  d.drainJournal()
  let outcome =
    case res.kind
    of erNothing: eoIgnored
    of erPending: eoMoved
    of erOperation, erCharacter:
      if d.state.doc != docBefore: eoChanged else: eoMoved
  KeyApplication(outcome: outcome, operations: ops, resolution: res.kind,
                 timedOut: res.timedOut)

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
  ## terminal and GPUI both call this; §30b). The front-end supplied only the
  ## document's `delivery` (Base-Keymaps §4.2's three keys); the context keys
  ## a `when` reads are `context_keys.editorContextKeys`'s.
  ##
  ## `textEntry` follows the document's MODE under a modal base — a printable
  ## key stands for itself exactly in insert mode (PLAT-43 measured the
  ## alternative: under Vim in normal mode `d` `w` typed `dw`) — and is always
  ## on under CUA and Emacs, which have no command mode.
  EditingScope(model: d.model, product: pmEdit, pane: epEditor,
               mode: d.state.mode,
               textEntry: not isModal(d.model) or d.state.mode == emInsert,
               context: editorContextKeys(d.state, pmEdit, d.delivery))

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

proc caretLineText(d: EditingDocument): tuple[text: string; byteCol: int] =
  ## The caret's line only — its start is `column` bytes back from the head,
  ## its end the next newline — rather than every line of the document; and
  ## the caret's byte offset in it.
  let pos = d.caretPos
  let head = clamp(d.state.primaryHead, 0, d.state.doc.len)
  let lineStart = head - pos.column
  var lineEnd = d.state.doc.find('\n', lineStart)
  if lineEnd < 0: lineEnd = d.state.doc.len
  (d.state.doc[lineStart ..< lineEnd], pos.column)

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
  ## **THE VIEW COLUMN IS A DIFFERENT NUMBER** — `caretViewColumn`. A wide
  ## CJK cluster is one cluster and two columns; the horizontal view
  ## (Horizontal-Overflow.md §4.5) scrolls in view columns
  ## (`ViewColumnPolicy`), so its caret-follow reads that one.
  let (text, byteCol) = d.caretLineText
  let metrics = lineMetrics(text, d.settings.policy)
  for i, c in metrics.clusters:
    if c.startByte >= byteCol:
      return i
  metrics.clusters.len

proc caretViewColumn*(d: EditingDocument): int =
  ## The caret's 0-based column in the horizontal view (`ViewColumnPolicy`):
  ## the column the view follows and the bar's mark.
  let (text, byteCol) = d.caretLineText
  columnAt(text, byteCol, ViewColumnPolicy)

proc contentCols*(d: var EditingDocument): int =
  ## Horizontal-Overflow.md §4.1: the editor's content width — its widest
  ## line in view columns, exact, from the per-line widths `drainJournal`
  ## maintains (measured once, the first time it is asked).
  if not d.widths.valid or d.widths.version != d.timeline.version or
     d.widths.docLen != d.state.doc.len:
    d.measureAll()
  d.widths.widest

proc followView*(d: var EditingDocument; v: var HorizontalView;
                 f: var CaretFollow; viewportCols: int): bool =
  ## THE EDITOR'S HORIZONTAL VIEW before a frame, one rule for every
  ## front-end: the content width and the view's width brought up to date,
  ## then §4.5's caret-follow when the caret moved since it was last
  ## followed (`horizontal_scroll.followCaret`). Answers whether the view
  ## moved.
  let before = v.leftCol
  v.setContent(d.contentCols)
  v.setViewport(viewportCols)
  let (text, byteCol) = d.caretLineText
  discard v.followCaret(f, d.caretLine, columnAt(text, byteCol, ViewColumnPolicy),
                        lineViewWidth(text))
  v.leftCol != before

proc caretFollowOf*(d: EditingDocument): CaretFollow =
  ## The caret as `followView` records it once followed — for a front-end
  ## that PUT the view somewhere on purpose (a find cancelled, §3.5 of
  ## Find-And-Incremental-Search.md: both offsets restored exactly), so the
  ## next frame's caret-follow does not move the view off it again.
  let (text, byteCol) = d.caretLineText
  CaretFollow(line: d.caretLine,
              column: columnAt(text, byteCol, ViewColumnPolicy), armed: true)

func offsetAt*(d: EditingDocument; line, column: int): int =
  ## The byte offset of the 0-based (line, cluster column), clamped into the
  ## document.
  let ls = d.lines
  if ls.len == 0:
    return 0
  let l = clamp(line, 0, ls.len - 1)
  let metrics = lineMetrics(ls[l], d.settings.policy)
  let byteInLine =
    if column <= 0: 0
    elif column >= metrics.clusters.len: metrics.byteLen
    else: metrics.clusters[column].startByte
  toTextStore(d.state.doc).offsetOf(TextPos(line: l, column: byteInLine))

proc moveCaretTo*(d: var EditingDocument; line, column: int) =
  ## Place the caret at a 0-based (line, cluster column).
  ##
  ## The one non-key, non-operation writer of the selection, and it exists for
  ## the reason every editor needs one: a mouse click, a jump from a build
  ## error and a test arranging a starting position are all "put the caret
  ## there" and none of them is a keystroke. It goes through
  ## `selection.caretSelection` rather than assigning a range, so the
  ## normalisation invariant `FUZZ-3` asserts holds by construction.
  d.state.selection = caretSelection(d.offsetAt(line, column))

proc extendSelectionTo*(d: var EditingDocument; line, column: int) =
  ## Keep the main selection's anchor and move its head to the 0-based
  ## (line, cluster column) — a pointer DRAG over the text, every
  ## front-end's (a press placed the anchor with `moveCaretTo`). Edits stay
  ## refused on a read-only document; selecting is not an edit.
  d.state.selection = singleSelection(d.state.selection.mainRange.anchor,
                                      d.offsetAt(line, column))

proc selectSpan*(d: var EditingDocument; anchor, head: int) =
  ## Select the bytes `[anchor, head)` (head may precede anchor) — the other
  ## non-key writer, for a find match and a pointer drag. Through
  ## `selection.singleSelection`, so the selection is normalised by
  ## construction, as `moveCaretTo`'s is.
  let n = d.state.doc.len
  d.state.selection = singleSelection(clamp(anchor, 0, n), clamp(head, 0, n))

type
  SelectionCells* = seq[tuple[line, fromColumn, toColumn: int]]
    ## A selection as a front-end paints it: per 1-based line, the 1-based
    ## display columns `[from, to)`.

proc spanCellsIn(text: string; ls: openArray[string]; a, b: int;
                 into: var SelectionCells) =
  ## The bytes `[a, b)` of `text` as painted cells, per line — one rule for
  ## a selection and a find match (PLAT-70 Part C), so the two cannot be
  ## drawn over different columns.
  let pa = caretPosOf(text, a)
  let pb = caretPosOf(text, b)
  for line in pa.line .. min(pb.line, ls.len - 1):
    let lineText = ls[line]
    let fromCol = if line == pa.line: columnAt(lineText, pa.column) else: 0
    let toCol = if line == pb.line: columnAt(lineText, pb.column)
                else: columnAt(lineText, lineText.len) + 1
    if toCol > fromCol:
      into.add (line + 1, fromCol + 1, toCol + 1)

proc selectionCells*(d: EditingDocument): SelectionCells =
  ## THE SELECTION AS EVERY FRONT-END PAINTS IT — the terminal's source pane
  ## and GPUI's editor rows read this one derivation: display columns from
  ## `selection.columnAt` (tabs expanded, wide glyphs two columns), and a
  ## range that continues past a line's end covers one cell for the line
  ## break, as Monaco's selection does.
  result = @[]
  let text = d.text
  let ls = d.lines
  for r in d.state.selection.ranges:
    if r.isEmpty: continue
    spanCellsIn(text, ls, r.rangeFrom, r.rangeTo, result)

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
