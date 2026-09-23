## PLAT-34 — `DIFF-1`'s value half, the retirement scans, and the concern
## census.
##
## Spec: `Testing/Editor-Model-Conformance-Suite.md` §8 (`DIFF-1`) and §10
## (the counted target); `Architecture/Editor-ViewModel.md`;
## `Planned-Work/CodeTracer-Platform.milestones.org` under PLAT-34.
##
##     nim c -r --path:src/frontend/viewmodel \
##       src/frontend/viewmodel/tests/unit/test_editor_front_end_differential.nim
##
## =========================================================================
## WHAT THIS SUITE IS, AND WHAT IT DELIBERATELY IS NOT
## =========================================================================
##
## `DIFF-1` HAS TWO HALVES AND THE SECOND ONE IS NOT HERE. PLAT-34 spells it
## out: *"(1) the model states agree — cheap, and true by construction once
## the milestone lands; (2) both front-ends' observed output changes when the
## model changes, each read FROM A RUN."* This file is half 1 plus the scans
## that keep half 1 from being vacuous. Half 2 is
## `src/frontend/tui/tests/test_editor_front_end_observed.nim`, which reads
## the terminal's painted rows and the GPUI shadow tree through the real
## `isonim-gpui` shim — neither of which compiles on the JS or wasm32
## backends, which is why the split is a lane boundary and not a preference.
##
## **THIS SUITE CANNOT REACH EITHER FRONT-END'S OWN MODULE, AND THAT IS THE
## PROBLEM THE SCANS SOLVE.** `tui/app/edit_binding.nim` links the terminal's
## view tree; `gpui/main.nim` links the shim. Both are out of the `vm-unit`
## lane's file set by construction. So the two arms below drive the CORE's own
## entry points — `editing_core.applyKey` under the terminal's scope, and
## `editing_core.applyNamed` for the GPUI front-end, which has no keys to
## resolve (`PLAT21-VG1`) — and a SOURCE SCAN asserts that each front-end's
## own body reaches exactly that and nothing else. Without the scan the arms
## would be two calls this file made up.
##
## =========================================================================
## §30a IS THIS MILESTONE'S CENTRAL TRAP AND IT IS NAMED BEFORE THE CASES
## =========================================================================
##
## > **A differential measures only what its two sides compute DIFFERENTLY;
## > everything shared is invisible to it.**
##
## `DIFF-1` is the purest instance the campaign has produced, and PLAT-34's
## own deliverable says so: once both front-ends are thin derivations of one
## model, comparing their model states is two reads of one value and **cannot
## fail**. PLAT-31's `DIFF-4` ran 82 cells green against a feature no key
## could reach for exactly this reason, and PLAT-33's `G4` reproduced it
## purely. So the thirty cells below are NOT this suite's evidence about the
## wiring. Three other things are, and each has its own arm:
##
##   1. **THE PROVENANCE SCAN.** `edit_binding.applyEditKey`'s body must reach
##      `editing_core`'s `applyKey` and must reach NONE of the eight widget
##      spellings it used to dispatch through; `editorSurfaceForDocument`'s
##      body must read the document and must not split a string it was handed.
##      §30a's rule: *"when a differential's second side can be re-derived,
##      assert WHERE IT COMES FROM, not only what it says."*
##   2. **THE MUTABLE-BUFFER SCAN**, with a planted positive control, because
##      an absence grep with no positive control is §4.
##   3. **THE RETIREMENT SCAN** — `EditBuffer`'s measured blast radius, in
##      both directions, so "retired" is a checkable claim rather than a
##      status.
##
## =========================================================================
## §34 — THE POPULATION
## =========================================================================
##
## Thirty sequences that never exercise a divergent path are thirty green
## cells about one thing. `../generators/operation_sequence_corpus.nim` is
## split over six families with the per-family count asserted as an EQUALITY,
## the corpus-class coverage asserted from the realised document indices, and
## every row asserted to leave both media something to draw — PLAT-23's
## measurement, which is that two empty editors compare equal.
##
## =========================================================================
## §29 — `unittest.check` INSIDE A PLAIN `proc` SETS A GLOBAL
## =========================================================================
##
## `counted` is a template. Every helper below that is a `proc` asserts
## nothing and returns a value the case asserts on.

import std/[os, sets, strutils, tables]
import unittest

import ../../editing_core
import ../../../view_vocabulary/editor_surface
import ../generators/operation_sequence_corpus
import ../generators/vocabulary_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 420
  ## Asserted by the last case against the runtime tally. Written LAST, from a
  ## run. §10.1's *"a static one cannot see a case that returned early"* is why
  ## `CHECKS:` is printed as well.

const
  TerminalMedium = "terminal"
  GpuiMediumName = "gpui"
    ## The two media this milestone wires. Spelled as consts because
    ## `EditorSurface.medium` is compared against them and a literal in each
    ## case is a literal that can be typed differently in one of them —
    ## PLAT-21 planted exactly that mutation (`nativeMedium` hardcoded to one
    ## front-end while the `PaneView` said the other) and nothing in the tree
    ## could tell.

# ===========================================================================
# THE SOURCE SCANS — §30a, §35
# ===========================================================================

const
  BindingSource = staticRead("../../../tui/app/edit_binding.nim")
  SurfaceSource = staticRead("../../../view_vocabulary/editor_surface.nim")
  CoreSource = staticRead("../../editing_core.nim")
  KeymapSource = staticRead("../../keymap/editing_keymap.nim")
  GpuiMainSource = staticRead("../../../gpui/main.nim")
  GpuiArmSource = staticRead("../../../gpui/app/edit_arm.nim")
  # The retirement scan's subjects. `staticRead` is compile-time only, so a
  # case cannot call it inline; naming them here also means the list of
  # modules the retirement claim is about is one place a reader can count.
  DispatchSuiteSource =
    staticRead("../../../tui/app/tests/test_edit_binding_vocabulary.nim")
  EditModeSuiteSource =
    staticRead("../../../tui/app/tests/test_edit_mode_source.nim")
  TuiAppSource = staticRead("../../../tui/app/tui_app.nim")
  RuntimeSource = staticRead("../../../tui/app/runtime.nim")

const RetiredWidgetSpellings* = [
    ## **THE EIGHT SPELLINGS THE TERMINAL'S DISPATCH USED TO REACH.** Every
    ## one of them was a mutator on `isonim-tui`'s `TextAreaWidget` and every
    ## one of them was a write to a buffer that was not the model. They are a
    ## NAMED CONST whose cardinality a case asserts, because an empty list
    ## iterates nothing and satisfies every "must not contain" written over it
    ## (§4, and §30a's `LAW-D1` instance).
    "TextAreaWidget", "newTextArea", "moveCursorTo", "w.insertText",
    "w.backspace", "w.splitLine", "w.undo", "w.redo"]

const RetiredWidgetSpellingCount = 8

const RawSplitSpellings* = [
    ## What a surface derivation must NOT do to a string it was handed: split
    ## it into lines itself. `editorSurfaceForDocument` calls
    ## `row_projection.projectionLinesFor`, which is the one place PLAT-28's
    ## `TrailingLinePolicy` is applied; a `splitLines` in that body would be a
    ## THIRD spelling of a decision that enum exists to make once, and it is
    ## the one PLAT-28 filed as `PLAT28-DG3` and PLAT-34 closed.
    "splitLines", "readFile", "readProjectFile"]

const RawSplitSpellingCount = 3

proc codeOnly(src: string): string =
  ## Comments stripped, so prose in a doc comment cannot satisfy — or violate
  ## — a scan over code (§4d). This file's headers quote every forbidden
  ## spelling by name, so a scan that read comments would be a scan that
  ## reddened on its own documentation.
  for line in src.splitLines:
    let stripped = line.strip()
    if stripped.startsWith("#"):
      continue
    let hash = line.find('#')
    if hash >= 0 and line.count('"') mod 2 == 0:
      result.add line[0 ..< hash]
    else:
      result.add line
    result.add '\n'

proc bodyOf(src, opening: string): string =
  ## The body of the routine whose signature starts with `opening`, up to the
  ## next top-level declaration. Lifted from
  ## `test_editor_collab_laws.nim`, which is the third consumer of this shape;
  ## it is copied rather than hoisted because both copies are graded by their
  ## own suites and hoisting re-aims arms in two harnesses (§32a). The
  ## residual is stated rather than pretended away.
  let at = src.find(opening)
  if at < 0: return ""
  var i = src.find('\n', at)
  if i < 0: return ""
  while i < src.len:
    let nl = src.find('\n', i + 1)
    let stop = if nl < 0: src.len else: nl
    let line = src[i + 1 ..< stop]
    if line.len > 0 and line[0] notin {' ', '\t'} and not line.startsWith("#"):
      return src[at ..< i]
    if nl < 0: break
    i = nl
  src[at .. ^1]

proc mutableBufferSpellingsIn*(src: string): seq[string] =
  ## **THE ONE PREDICATE. THE RULE AND THE CONTROL BOTH CALL IT** (§30b).
  ##
  ## Which of the retired spellings a module's CODE reaches. The rule asserts
  ## the answer is empty for every module on either front-end's editing path;
  ## the positive control asserts it is non-empty for the dispatch PLAT-34
  ## retired, verbatim. One edit to this function reddens both at once, which
  ## is what makes each of them evidence about the other rather than a second
  ## opinion from the same mistake — PLAT-6's planted `readFile` passed with
  ## all eight checks green because a gate had two copies of its regex.
  let code = codeOnly(src)
  for spelling in RetiredWidgetSpellings:
    if spelling in code:
      result.add spelling

const RetiredDispatchControl* = """
proc performEditBehaviour(w: TextAreaWidget; b: EditBehaviour;
                          character: string): EditKeyOutcome =
  case b
  of ebMoveCharLeft: w.moveLeft(); ekMoved
  of ebDeleteCharBackward: w.backspace(); ekChanged
  of ebInsertNewline: w.splitLine(); ekChanged
  of ebUndo:
    if w.undo(): ekChanged else: ekMoved
  of ebRedo:
    if w.redo(): ekChanged else: ekMoved
  of ebInsertText:
    w.insertText(character); ekChanged

proc newEditBuffer*(path, text: string): EditBuffer =
  let w = newTextArea(TerminalRenderer(), text = text)
  w.moveCursorTo(Caret(line: 0, column: 0))
"""
  ## **THE POSITIVE TWIN, AND IT IS THE RETIRED CODE RATHER THAN A SPECIMEN.**
  ##
  ## Lifted from `edit_binding.nim` at `8f603d78`, trimmed to the arms that
  ## carry the spellings. It is a string const rather than a planted FILE for
  ## a measured reason: §35a establishes that Nim skips re-running its
  ## frontend when the named output exists and no tracked source's CONTENT has
  ## changed, so a file-adding plant is invisible to a `staticRead` scan
  ## unless something forces a rebuild — and a positive control that is
  ## sometimes not run is a control nobody can rely on. A const in the suite's
  ## own text is part of the suite's content by construction.
  ##
  ## It is not a claim that this text ever compiled in this file; it is a
  ## claim that the SCAN can find these spellings, which is the only thing a
  ## positive control for an absence grep has to establish.

# ---------------------------------------------------------------------------
# §35 — the subject list is compared against the DIRECTORY, not trusted.
#
# `staticRead` takes a string LITERAL, so a scan's subject list is frozen at
# the moment it was written and a new module in the same directory is not
# scanned, not counted and not missed. PLAT-25's enumeration over `editor/`
# has fired for real seven times. This milestone's own scan covers a
# directory nothing else enumerates — `viewmodel/keymap/` — because PLAT-31
# built it and enumerated nothing.
# ---------------------------------------------------------------------------

const ScannedKeymapModules = [
  "editing_keymap.nim", "kakoune_keymap.nim", "product_keymap.nim",
  "vim_keymap.nim", "vim_import.nim", "keymap_selection.nim"]

const ScannedKeymapModuleCount = 6
  ## **SIX SINCE 2026-09-23**: PLAT-43 added `keymap/keymap_selection.nim`,
  ## the one name→model selector, and this case went red by name — the
  ## enumeration doing its job a ninth time.
  ## A NAMED CARDINALITY so the set equality has something to disagree with.
  ##
  ## **IT WENT FROM FOUR TO FIVE ON 2026-09-22, AND THE ENUMERATION IS WHY.**
  ## PLAT-36 added `keymap/vim_import.nim` — a fifth module in the directory
  ## whose list named four — and this case went red BY NAME on the first run
  ## of the floor gate, from a milestone that had been green for two days and
  ## before either of PLAT-36's own suites existed. That is §35's eighth
  ## firing and the value of the mechanism is not that a defect was found
  ## (`vim_import.nim` spells no retired widget) — it is that the claim
  ## stopped being true of the directory and something said so.

const KeymapDirModules = block:
  var xs: seq[string] = @[]
  for path in walkDir(currentSourcePath().parentDir.parentDir.parentDir /
                      "keymap"):
    if path.kind == pcFile and path.path.endsWith(".nim"):
      xs.add path.path.extractFilename
  xs

# ===========================================================================
# THE TWO ARMS
# ===========================================================================

type
  Arm = enum
    ## **WHICH FRONT-END'S ENTRY POINT THIS DOCUMENT IS BEING DRIVEN
    ## THROUGH.** Not "which renderer": the renderers are half 2's subject.
    armTerminal = "terminal"
    armGpui = "gpui"

proc terminalScope(d: EditingDocument): EditingScope =
  ## The scope `edit_binding.editingScope` builds, and the scan below asserts
  ## that it is the same five values. Re-spelling it here is exactly the
  ## re-derivation §30a warns about; what makes it admissible is that the
  ## re-derivation is itself the thing under test and a case compares the two
  ## spellings as SOURCE.
  EditingScope(model: d.model, product: pmEdit, pane: epEditor,
               mode: d.state.mode, textEntry: true)

proc keyForOperation(name: string): string =
  ## The product keymap's key for `name`, or "" when it binds none.
  ##
  ## Read out of `productKeymap()`'s own table rather than out of a list here,
  ## so the terminal arm drives whatever the shipped default binds and a
  ## fifteenth row needs no edit in this file.
  for b in productKeymap().keymap.bindings:
    if b.operation == name and b.chords.len == 1:
      return b.chords[0]
  ""

proc runArm(arm: Arm; row: OperationSequence; doc: ScenarioDoc;
            nowMs: int64): (EditingDocument, seq[string], seq[EditingOutcome]) =
  ## Apply `row` to a fresh document through `arm`'s own entry point.
  ##
  ## **THE TWO ARMS ARE NOT TWO CALLS TO ONE FUNCTION, AND THE DIFFERENCE IS
  ## WHAT THE FRONT-ENDS ACTUALLY HAVE.** The terminal has keys and resolves
  ## them: its entry point is `applyKey`, and a named operation is driven
  ## through it by the operation's own route — there is no key for
  ## `select-inner-parens` under the product default, so the terminal arm
  ## reaches the vocabulary the way a front-end with a keymap does, through
  ## `applyNamed`, and uses `applyKey` for the steps its keymap binds.
  ##
  ## The GPUI front-end has NO keys at all — `PLAT21-VG1`: `addEventListener`
  ## takes a `proc()` with no parameter and `gpui_dispatch_event` carries no
  ## payload — so its only door is `applyNamed`, which is the same door the
  ## collaboration and scripting layers come through. That asymmetry is the
  ## honest statement of what "two front-ends" means today and it is why the
  ## enum exists rather than a bool.
  var d = initEditingDocument(doc.id, doc.text)
  d.moveCaretTo(0, 0)
  d.state.selection = caretSelection(startOffsetOf(doc, row.start))
  var performed: seq[string] = @[]
  var outcomes: seq[EditingOutcome] = @[]
  for step in row.steps:
    case arm
    of armTerminal:
      # The terminal's own two doors, in the order the front-end has them:
      # a key if its keymap binds the operation, the name otherwise.
      let key = keyForOperation(step.name)
      if key.len > 0:
        let applied = d.applyKey(terminalScope(d), key, nowMs)
        performed.add applied.operations
        outcomes.add applied.outcome
      else:
        outcomes.add d.applyNamed(step.name, step.args, nowMs)
        performed.add step.name
    of armGpui:
      outcomes.add d.applyNamed(step.name, step.args, nowMs)
      performed.add step.name
  (d, performed, outcomes)

proc surfaceOf(d: EditingDocument; medium: string): EditorSurface =
  ## The surface a medium draws this document through. **One function for both
  ## media**, which is the milestone's deliverable rather than this file's
  ## convenience: if the two media derived their surfaces through two
  ## functions the census below would be comparing two implementations.
  editorSurfaceForDocument(d, medium,
                           mutableHere = (medium == TerminalMedium))

# ===========================================================================
# THE POPULATION, BUILT AT MODULE SCOPE (§36a: a raise here prints nothing)
# ===========================================================================

type
  Cell = object
    row: OperationSequence
    doc: ScenarioDoc
    terminal: EditingDocument
    gpui: EditingDocument
    terminalOps: seq[string]
    gpuiOps: seq[string]
    terminalOutcomes: seq[EditingOutcome]
    gpuiOutcomes: seq[EditingOutcome]
    raised: string

let Docs = scenarioDocs()
let Rows = operationSequences()

let Cells = block:
  var xs: seq[Cell] = @[]
  for row in Rows:
    var c = Cell(row: row, doc: Docs[row.docIndex mod Docs.len])
    try:
      let (td, tops, touts) = runArm(armTerminal, row, c.doc, 1_000)
      let (gd, gops, gouts) = runArm(armGpui, row, c.doc, 1_000)
      c.terminal = td
      c.gpui = gd
      c.terminalOps = tops
      c.gpuiOps = gops
      c.terminalOutcomes = touts
      c.gpuiOutcomes = gouts
    except CatchableError as e:
      c.raised = e.msg
    xs.add c
  xs

# ===========================================================================

suite "PLAT-34: DIFF-1 — one editing core, two front-ends":

  test "the corpus is thirty sequences, six families, every class and every document":
    # §34. The cardinality in BOTH directions, the per-family counts as
    # EQUALITIES, and the realised corpus-class coverage read off the
    # documents the rows actually selected — never off the table.
    counted Rows.len == OperationSequenceCardinality
    let realised = realisedFamilies(Rows)
    var sum = 0
    for f in SeqFamily:
      checkpoint($f & ": declared " & $PerFamilySequences[f] &
                 " realised " & $realised[f])
      counted realised[f] == PerFamilySequences[f]
      counted realised[f] > 0
      sum += realised[f]
    counted sum == OperationSequenceCardinality
    # THE CLASSES. §5's nine, reached through the documents the rows name.
    var classes: HashSet[int] = initHashSet[int]()
    for c in Cells:
      classes.incl c.doc.cls
    checkpoint("corpus classes reached: " & $classes.len)
    counted classes.len == 9
    # **AND EVERY SCENARIO DOCUMENT, NOT ONLY EVERY CLASS.** The class count
    # alone is satisfied by a corpus that uses two documents of each class and
    # then loses one of them, because the other still carries the class —
    # measured: arm `G1` moves one row off its document and nine classes are
    # still reached. The generator's own comment claims *"every one of the
    # eighteen scenario documents is used at least once"*, and a claim in a
    # comment is a claim nothing re-takes (§36b).
    var docsUsed: HashSet[string] = initHashSet[string]()
    for c in Cells:
      docsUsed.incl c.doc.id
    checkpoint("scenario documents reached: " & $docsUsed.len &
               " of " & $Docs.len)
    counted docsUsed.len == Docs.len
    # Every row's id is distinct — a duplicated row is a sweep that ran one
    # sequence twice and counted two.
    var ids: HashSet[string] = initHashSet[string]()
    for row in Rows:
      ids.incl row.id
    counted ids.len == OperationSequenceCardinality

  test "nothing in the population raised":
    # §36a: the cells are built at module scope, so a raise would take the
    # binary down before `unittest` printed a verdict. The runner catches and
    # this asserts the total.
    var raises = 0
    for c in Cells:
      if c.raised.len > 0:
        checkpoint(c.row.id & " raised: " & c.raised)
        inc raises
    counted raises == 0

  # -------------------------------------------------------------------------
  # `DIFF-1`, HALF 1 — thirty cells.
  #
  # READ THE SUITE HEADER BEFORE READING A GREEN RUN OF THESE. They are true
  # by construction once the milestone lands and PLAT-34 says so in its own
  # deliverable; what makes them worth running is the two assertions BESIDE
  # the equality — that each arm actually acted, and that each leaves its
  # medium something to draw.
  # -------------------------------------------------------------------------
  for row in operationSequences():
    test "DIFF-1: " & row.id:
      var cell: Cell
      var found = false
      for c in Cells:
        if c.row.id == row.id:
          cell = c
          found = true
      counted found
      checkpoint(describe(row) & " over " & cell.doc.id)
      counted cell.raised.len == 0

      # (1) THE MODEL STATES AGREE, compared as a VALUE. `EditorState.==` is
      # field by field over every field, which is what makes this more than a
      # document comparison: a sequence that left the two arms in different
      # MODES, or with different registers, or with a different history, fails
      # here.
      counted cell.terminal.state == cell.gpui.state

      # (2) EACH ARM ACTED. A cell in which both arms refused everything
      # agrees perfectly and measures nothing — §34, and it is the shape
      # `FUZZ-8` found on four of nine classes.
      var terminalActed = 0
      var gpuiActed = 0
      for o in cell.terminalOutcomes:
        if o != eoIgnored: inc terminalActed
      for o in cell.gpuiOutcomes:
        if o != eoIgnored: inc gpuiActed
      checkpoint("acted: terminal " & $terminalActed & " gpui " & $gpuiActed)
      counted terminalActed > 0
      counted gpuiActed > 0

      # (3) BOTH MEDIA HAVE SOMETHING TO DRAW. PLAT-23's measurement: two
      # empty editors compare equal, so a sequence that emptied its document
      # would be a cell that cannot fail.
      let ts = surfaceOf(cell.terminal, TerminalMedium)
      let gs = surfaceOf(cell.gpui, GpuiMediumName)
      counted ts.rows.len > 0
      counted gs.rows.len > 0
      counted cell.terminal.text.len > 0

      # (4) AND THE CARET IS ON THE READ-ONLY MEDIUM'S ROWS. PLAT-28's rule —
      # *"a read-only editor that does not re-render is not a consumer"* — is
      # about MOTIONS as much as about edits: twenty-four of this corpus's
      # thirty rows end in a motion, and a surface that carried only text
      # would be byte-identical after every one of them. The caret arrives as
      # the INSPECTION cursor (CTUI-6's second pointer), which is what makes
      # the GPUI shadow tree move when the model moves.
      let caret = cell.gpui.caretLine
      counted gs.rowAt(caret).line == caret
      counted gs.rowAt(caret).pointer == eptInspection

  # -------------------------------------------------------------------------
  # THE PROVENANCE SCAN — §30a's rule: *"when a differential's second side can
  # be re-derived, assert WHERE IT COMES FROM, not only what it says."*
  #
  # This is the load-bearing half of the thirty cells above. Without it the two
  # arms are two calls this file invented, and the suite would be green against
  # a terminal that still drove a widget.
  # -------------------------------------------------------------------------

  test "the terminal's dispatch reaches the core and no widget":
    let body = codeOnly(bodyOf(BindingSource, "proc applyEditKey*("))
    counted body.len > 0
    # IT REACHES THE CORE. The one call, by name.
    checkpoint(body)
    counted "buf.doc.applyKey(" in body
    counted "buf.editingScope" in body
    # AND IT REACHES NONE OF THE EIGHT. The list is a named const whose
    # cardinality the non-vacuity case below asserts.
    for spelling in RetiredWidgetSpellings:
      checkpoint("forbidden in applyEditKey: " & spelling)
      counted spelling notin body

  test "the terminal's SCOPE is the five values the differential drives":
    # The arm above re-spells `edit_binding.editingScope` and §30a says a
    # re-derivation is invisible to every assertion about the ANSWER. So the
    # claim checked here is about the SOURCE: the front-end's own scope
    # builder names the same five dimensions with the same two constants.
    #
    # SINCE PLAT-43/44 (2026-09-23) THE BUILDER DELEGATES, and the facts moved
    # with it: `editingScope` is one call to `editing_core.editScopeOf`, the
    # rule GPUI's edit arm calls too, and `textEntry` is no longer the
    # constant `true` — it follows the document's mode (a printable key is text
    # only in insert mode; PLAT-43 measured the constant typing `dw` under
    # Vim). So the scan follows the delegation into the function that now
    # holds the five values.
    let body = codeOnly(bodyOf(BindingSource, "proc editingScope*("))
    counted body.len > 0
    counted "editScopeOf(buf.doc)" in body
    let rule = codeOnly(bodyOf(CoreSource, "func editScopeOf*("))
    counted rule.len > 0
    counted "product: pmEdit" in rule
    counted "pane: epEditor" in rule
    counted "textEntry: d.state.mode == emInsert" in rule
    counted "model: d.model" in rule
    counted "mode: d.state.mode" in rule

  test "the GPUI surface reads the DOCUMENT and splits no string":
    let body = codeOnly(bodyOf(SurfaceSource,
                               "proc editorSurfaceForDocument*("))
    counted body.len > 0
    # IT READS THE DOCUMENT, AND ITS LINE SET COMES FROM PLAT-28's OWN
    # POLICY FUNCTION RATHER THAN FROM A SPLITTER OF ITS OWN. The second half
    # is what `PLAT28-DG3`'s closure rests on: one splitter, one trailing-line
    # decision, two callers.
    counted "projectionLinesFor(d.text, trailing)" in body
    counted "d.caretLine" in body
    for spelling in RawSplitSpellings:
      checkpoint("forbidden in editorSurfaceForDocument: " & spelling)
      counted spelling notin body

  test "the GPUI front-end OPENS a document rather than passing bytes on":
    # PLAT-34's deliverable 3 from the front-end's own side. `editSurfaceFor`
    # used to read a file and hand the string to a derivation that split it;
    # it constructs the model now, which is the edge the thirty cells above
    # assume and cannot see.
    #
    # SINCE PLAT-44 the document is held by the EDIT ARM, because this
    # front-end writes it now; `editSurfaceFor` opens the arm and asks it for
    # the surface, and the arm is what constructs the model and derives from
    # it. The scan follows that one step.
    let body = codeOnly(bodyOf(GpuiMainSource, "proc editSurfaceFor("))
    counted body.len > 0
    counted "newGpuiEditArm(" in body
    counted "surfaceOf(" in body
    counted "editorSurfaceForProject(" notin body
    counted "initEditingDocument(" in
      codeOnly(bodyOf(GpuiArmSource, "proc newGpuiEditArm*("))
    counted "editorSurfaceForDocument(" in
      codeOnly(bodyOf(GpuiArmSource, "proc surfaceOf*("))

  test "the keymap layer threads the CLOCK into every operation it runs":
    # PLAT-32's residual, closed here, as a SOURCE fact because no answer
    # shows it: `applyResolution` ran `applyOperation` without `nowMs` until
    # this milestone, so `nowMs - prevTime` was `0 - 0` and grouping could
    # never break. The behaviour is asserted by the grouping case below; this
    # asserts that the argument is at the call site, which is what the arm
    # `M14` in `run-plat31-keymap-mutations.py` removes.
    let body = codeOnly(bodyOf(KeymapSource, "proc applyResolution*("))
    counted body.len > 0
    counted "applyOperation(state, name, args, settings, viewportRows, nowMs)" in body
    # AND THE PARAMETER HAS NO DEFAULT. A defaulted clock is
    # indistinguishable at every call site from a clock somebody passed, which
    # is exactly how the residual survived a milestone whose own suite drove
    # this function six times.
    let sig = codeOnly(bodyOf(KeymapSource, "proc applyResolution*("))
    counted "nowMs: int64;" in sig
    counted "nowMs: int64 = 0" notin sig

  test "UNDO GROUPING BREAKS ON THE CLOCK, through the terminal's own path":
    # The behaviour the residual was hiding. Two inserts a keystroke apart are
    # ONE undo; two inserts `NewGroupDelayMs` apart are TWO. Before PLAT-34
    # both were one, on every keystroke the product ever delivered, and no
    # case could see it because no case supplied a clock.
    var near = initEditingDocument("g.txt", "alpha\n")
    near.moveCaretTo(0, 0)
    discard near.applyKey(terminalScope(near), "a", 1_000)
    discard near.applyKey(terminalScope(near), "b", 1_010)
    let nearText = near.text
    discard near.applyNamed("undo", OpArgs(), 1_010)
    checkpoint("grouped: '" & nearText & "' -> '" & near.text & "'")
    counted near.text == "alpha\n"

    var far = initEditingDocument("g.txt", "alpha\n")
    far.moveCaretTo(0, 0)
    discard far.applyKey(terminalScope(far), "a", 1_000)
    discard far.applyKey(terminalScope(far), "b", 1_000 + NewGroupDelayMs)
    let farText = far.text
    discard far.applyNamed("undo", OpArgs(), 1_000 + NewGroupDelayMs)
    checkpoint("ungrouped: '" & farText & "' -> '" & far.text & "'")
    counted far.text != "alpha\n"
    counted far.text.len == "alpha\n".len + 1

  # -------------------------------------------------------------------------
  # THE MUTABLE-BUFFER SCAN — three cases, and the middle one is the control.
  #
  # PLAT-34's verification gate: *"the count of modules holding a mutable text
  # buffer other than the model is zero; the planted control proves the scan
  # can find one. An absence grep with no positive control is §4."*
  # -------------------------------------------------------------------------

  test "no module on either front-end's editing path holds a text buffer":
    for (name, src) in [("tui/app/edit_binding.nim", BindingSource),
                        ("view_vocabulary/editor_surface.nim", SurfaceSource),
                        ("viewmodel/editing_core.nim", CoreSource),
                        ("gpui/main.nim", GpuiMainSource)]:
      let found = mutableBufferSpellingsIn(src)
      checkpoint(name & ": " & $found)
      counted found.len == 0

  test "THE PLANTED POSITIVE CONTROL — the same predicate finds the retired one":
    # ONE PREDICATE, ONE FUNCTION, RULE AND CONTROL BOTH CALLING IT (§30b).
    # The control is the dispatch PLAT-34 retired, verbatim, so breaking
    # `mutableBufferSpellingsIn` reddens this case and the one above at once —
    # which is what makes each of them evidence about the other rather than a
    # second opinion from the same mistake.
    let found = mutableBufferSpellingsIn(RetiredDispatchControl)
    checkpoint("control found: " & $found)
    counted found.len > 0
    counted "TextAreaWidget" in found
    counted "w.insertText" in found
    counted "moveCursorTo" in found

  test "the forbidden list is not empty, and its cardinality is declared":
    # §4 one level up from the scan it guards: an empty list iterates nothing
    # and satisfies every "must not contain" written over it. Arm `U1`
    # empties it and both cases above must go red.
    counted RetiredWidgetSpellings.len == RetiredWidgetSpellingCount
    counted RawSplitSpellings.len == RawSplitSpellingCount
    counted RetiredWidgetSpellingCount > 0
    counted RawSplitSpellingCount > 0
    # §35 — the subject list is compared against the DIRECTORY. This
    # milestone's own scan covers `viewmodel/keymap/`, which PLAT-31 built and
    # enumerated nothing over.
    counted KeymapDirModules.len > 0
    counted ScannedKeymapModules.len == ScannedKeymapModuleCount
    for name in ScannedKeymapModules:
      counted name in KeymapDirModules
    for name in KeymapDirModules:
      checkpoint("in keymap/: " & name)
      counted name in ScannedKeymapModules

  # -------------------------------------------------------------------------
  # `EditBuffer`'s RETIREMENT — five cases, and the multipliers are MEASURED.
  #
  # PLAT-34: *"the last term's multipliers are the measured blast radius from
  # this milestone's own deliverable 1, not an estimate, which is what makes
  # 'retired' a checkable claim rather than a status."*
  #
  # **THE MILESTONE'S OWN FIGURE WAS RE-TAKEN AND IT MOVED** (§36b: re-derive
  # a quoted figure from its stated decomposition before believing it). The
  # milestone says *"two references outside `edit_binding.nim`, one a comment
  # and one a test helper"*. Measured with comments stripped, on the tree this
  # suite runs against: the comment is in `tui/host/edit_host.nim` and is
  # **not a reference in code at all**, and there are **two** test files that
  # name the type in code, not one. Two references stands; its composition
  # does not, and the cases below enumerate the files rather than restating
  # the sentence.
  # -------------------------------------------------------------------------

  test "EditBuffer reference 1 of 2 — the dispatch suite, in a test helper":
    let src = codeOnly(DispatchSuiteSource)
    counted "EditBuffer" in src
    counted mutableBufferSpellingsIn(src).len == 0
    counted "buf.doc" in src or "moveCaretTo" in src

  test "EditBuffer reference 2 of 2 — the edit-mode source suite":
    let src = codeOnly(EditModeSuiteSource)
    counted "EditBuffer" in src
    counted mutableBufferSpellingsIn(src).len == 0

  test "EditSession module 1 of 3 — its owner holds the model and no buffer":
    counted "EditSession" in codeOnly(BindingSource)
    counted "doc*: EditingDocument" in codeOnly(BindingSource)
    counted mutableBufferSpellingsIn(BindingSource).len == 0

  test "EditSession module 2 of 3 — the app value":
    let src = codeOnly(TuiAppSource)
    counted "editSession*: EditSession" in src
    counted mutableBufferSpellingsIn(src).len == 0

  test "EditSession module 3 of 3 — the runtime, which routes the keystroke":
    let src = codeOnly(RuntimeSource)
    # `newEditSession(rt.keymapModel)` since PLAT-43: a session opens under
    # the keymap the user chose (the stored preference, or `:keymap`).
    counted "newEditSession(rt.keymapModel)" in src
    # AND IT PASSES THE CLOCK. The last step of PLAT-32's residual: the
    # runtime has threaded `nowMs` through `handleToken` since CTUI-2 and the
    # editing path never asked for it.
    counted "rt.routeTokenToEditor(token, nowMs)" in src
    counted "buf.applyEditKey(keyName(token), nowMs)" in src
    counted mutableBufferSpellingsIn(src).len == 0

  # -------------------------------------------------------------------------
  # THE CONCERN CENSUS — four members x two media, taken FROM A RUN in both
  # directions (PLAT-21's escape-census shape).
  # -------------------------------------------------------------------------

  for concern in EditorConcern:
    for medium in [TerminalMedium, GpuiMediumName]:
      test "EditorConcern " & $concern & " on " & medium:
        # ONE DOCUMENT, TWO MEDIA, ONE DERIVATION. The support table is read
        # off the surface the run produced (§4a), never recomputed here.
        var d = initEditingDocument("census.txt", "alpha\nbeta\n")
        d.moveCaretTo(0, 0)
        let s = surfaceOf(d, medium)
        counted s.medium == medium
        let support = supportOf(s.support, concern)
        checkpoint(medium & " " & $concern & " -> " & $support)
        # THE TWO MEDIA MUST AGREE, or the gap is FILED BY NAME. Edit mode has
        # no recording, so three of the four concerns are `esAbsent` on both;
        # per-line status is `esDegraded` on both because
        # `FiledEditorGaps[pgMarksHaveNoProducer]` records that `points` has no
        # producer. A medium that answered differently would be a front-end
        # with its own opinion about a core question.
        let other = surfaceOf(d, if medium == TerminalMedium: GpuiMediumName
                                 else: TerminalMedium)
        counted supportOf(other.support, concern) == support
        # AND THE OTHER DIRECTION: a concern this surface reports as degraded
        # must be one the register files, and a filed gap must be one some
        # surface degrades. `reportedConcerns` reads the run.
        if support == esRendered:
          counted concern notin reportedConcerns(s)
        else:
          counted concern in reportedConcerns(s)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
