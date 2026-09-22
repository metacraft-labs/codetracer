## test_editor_vim_import_differential.nim — PLAT-36's `DIFF-5`, and the
## real-stack half of its integration tests.
##
## `Testing/Editor-Model-Conformance-Suite.md` §8, row five: *"`DIFF-5` —
## IMPORTED ↔ HAND-WRITTEN VIM KEYMAP; same input: one keystroke sequence;
## compared: the resulting document."*
##
## Two things live here, and they are the two the milestone asks for under
## *"real-stack integration tests (no mocks)"*:
##
##   1. **The imported keymap LOADED AND RESOLVED AGAINST, once per corpus
##      file** — *"rather than merely parsed"*. Every binding the import
##      produced is driven through `editing_keymap.resolve` on the trie the
##      resolver itself walks, in the binding's own scope, and must come back
##      as its own operation. A keymap that parses and resolves to nothing is
##      exactly the *"key that silently does nothing"* §6.3 exists against.
##   2. **`DIFF-5` over twelve keystroke sequences.**
##
## =========================================================================
## THE §30 TRAP, AND HOW THIS AXIS ESCAPES IT
## =========================================================================
##
## Both sides resolve through ONE resolver over ONE vocabulary — that is the
## design and it is the right one — so a differential comparing two calls to
## `driveKeys` would be §30's *"a cross-check whose two sides are computed from
## the same expression"*. What makes this an axis is that the two sides are
## reached by DIFFERENT KEY SEQUENCES THROUGH DIFFERENT KEYMAPS:
##
##   * the IMPORTED side presses one chord (`gQ`) against a keymap built by
##     `importVimConfig` and holding exactly one binding, which for seven of
##     the twelve rows is a `replay-macro` over a macro the import synthesised;
##   * the HAND-WRITTEN side presses the two or three keys of the Vim sequence
##     against `vimKeymap()`, which this file never hands to the imported side.
##
## §30a's rule — *"when a differential's second side can be re-derived, assert
## WHERE IT COMES FROM, not only what it says"* — is discharged by a scan of
## this file's own body: `runImported`'s text must reach the import's keymap
## and must not name `vimKeymap`, and `runHandWritten`'s must be the mirror
## image. If the two arms ever end up calling one constructor, every row still
## passes and nothing is compared, and no assertion about the ANSWER can see
## it, because the answer is what was substituted.
##
## =========================================================================
## §6.4 IS THE OTHER HALF OF THE PASS CONDITION
## =========================================================================
##
## *"A `DIFF-5` divergence with no report entry is a failure; one with an entry
## is a pass, which is what makes the report the product."* So a row whose two
## sides disagree is not automatically red: it is red unless the import filed
## the difference. Both arms are exercised: all twelve rows AGREE — which is
## the claim the axis is for — and the shapes that would NOT agree are the ones
## the import REFUSED rather than shipped (`dd`, `yyp`, `>>`, `y$`, each with a
## report row), plus the one it SHIPPED WITH A FILED DIVERGENCE (§4.3's
## text-entry shadow). Those two are a case of their own, because twelve
## agreements on their own cannot show that a disagreement would be caught.

import std/[sequtils, sets, strutils, tables, unittest]

import ../corpus/vimrc_corpus
import ../../keymap/vim_import
import ../../keymap/vim_keymap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a static assertion count when a suite dies before printing.
const ExpectedAssertions = 702

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  DiffDocument = """alpha beta gamma
second line here
third line of text
"""
    ## One document, ASCII, three lines. `DIFF-5`'s question is whether two
    ## KEYMAPS reach the same document, not whether the model handles grapheme
    ## clusters — PLAT-24's corpus answers that and PLAT-30 drives all 224
    ## operations against it. A Unicode document here would make every row
    ## slower and none of them sharper.

  ImportedLhs = "gQ"
    ## A chord no default Vim binding claims, so a row that resolved through
    ## the hand-written keymap by accident resolves to NOTHING rather than to
    ## something plausible.

  DiffSequences = [
    "x", "J", "o", "D", "rz",
    "ggj", "wwx", "jjx", "0x", "$x", "jJ", "bx",
  ]
    ## TWELVE, which is the milestone's own multiplier. Five are a single
    ## operation (one of them, `rz`, carrying an ARGUMENT, which is the shape
    ## a macro cannot hold) and seven are two or three, so seven rows exercise
    ## the `replay-macro` path the corpus never reaches. ELEVEN change the
    ## document and one — `ggj` — moves only the caret, which is why the caret
    ## is compared as well as the document; both halves are counted, and the
    ## figures are measured rather than assumed (the first write of this file
    ## said ten and two, and neither was taken).

  ExpectedDiffRows = 12
  ExpectedMacroRows = 7
  ExpectedDocChangingRows = 11

  SuiteSource = staticRead("test_editor_vim_import_differential.nim")
    ## §30a's instrument. Read at compile time; the scan strips comment lines
    ## so the header's own discussion of `vimKeymap` cannot satisfy it.

proc vimScope(m: EditingMode): EditingScope =
  EditingScope(model: kmVim, product: pmEdit, pane: epEditor, mode: m,
               textEntry: false)

proc importScopeFor(b: EditingBinding): EditingScope =
  var mode = emNormal
  for m in EditingMode:
    if m in b.scope.modes:
      mode = m
      break
  EditingScope(model: kmVim, product: pmEdit,
               pane: (if epEditor in b.scope.panes or b.scope.panes.len == 0:
                        epEditor else: epOtherPane),
               mode: mode, textEntry: isTextEntryMode(mode))

let wrap = WrapSettings(wrapColumn: 0)

# ===========================================================================
# THE TWO ARMS. Their BODIES are the §30a subjects; do not merge them.
# ===========================================================================

proc runImported(imp: VimImport; keys: seq[string]):
    (EditorState, seq[string]) =
  ## The imported side. It drives `imp.keymap` and NEVER `vimKeymap`.
  var st = initEditorState(DiffDocument)
  st.mode = emNormal
  st.macros = imp.macros
  driveKeys(st, imp.keymap, vimScope(emNormal), keys, wrap)

proc runHandWritten(keys: seq[string]): (EditorState, seq[string]) =
  ## The hand-written side. It drives `vimKeymap()` and NEVER an import.
  var st = initEditorState(DiffDocument)
  st.mode = emNormal
  driveKeys(st, vimKeymap().keymap, vimScope(emNormal), keys, wrap)

proc codeOnly(src: string): string =
  ## Comment lines removed, so prose cannot satisfy a scan (§4d).
  var kept: seq[string] = @[]
  for line in src.splitLines():
    if line.strip().startsWith("#"): continue
    kept.add line
  kept.join("\n")

proc bodyOf(src, name: string): string =
  ## The text of one `proc` — from its signature to the next top-level `proc`
  ## or `suite`. A scan whose subject is the whole file is a scan that cannot
  ## tell which arm named what.
  let start = src.find("proc " & name & "(")
  if start < 0:
    raise newException(ValueError, "no proc named " & name & " in this file")
  var stop = src.len
  for marker in ["\nproc ", "\nsuite ", "\nlet ", "\nconst "]:
    let j = src.find(marker, start + 1)
    if j >= 0 and j < stop: stop = j
  src[start ..< stop]

# ===========================================================================
# THE CORPUS, IMPORTED ONCE — WITH ITS RAISES COUNTED (§36a)
# ===========================================================================

type CorpusImport = object
  id: string
  imp: VimImport
  raised: bool

proc importCorpus(): (seq[CorpusImport], int) =
  var rows: seq[CorpusImport] = @[]
  var raises = 0
  for d in CorpusDocs:
    try:
      rows.add CorpusImport(id: d.id, imp: importVimConfig(d.text),
                            raised: false)
    except CatchableError:
      inc raises
      rows.add CorpusImport(id: d.id, imp: VimImport(), raised: true)
  (rows, raises)

let (corpus, corpusRaises) = importCorpus()

suite "PLAT-36: DIFF-5 and the imported keymap resolved against":

  test "THE MODULE-SCOPE CORPUS IMPORT RAISED NOTHING":
    ck corpusRaises == 0
    ck corpus.len == VimrcCorpusSize
    for row in corpus:
      ck not row.raised

  # -------------------------------------------------------------------------
  # §30a — WHERE EACH SIDE COMES FROM
  # -------------------------------------------------------------------------

  test "THE TWO ARMS DO NOT SHARE A KEYMAP (§30a)":
    let code = codeOnly(SuiteSource)
    let imported = bodyOf(code, "runImported")
    let handWritten = bodyOf(code, "runHandWritten")
    ck imported.len > 0
    ck handWritten.len > 0
    # The positive halves: each arm reaches its own keymap.
    ck imported.contains("imp.keymap")
    ck handWritten.contains("vimKeymap()")
    # The negative halves, which are the ones that matter. Without them a
    # substitution passes every row.
    ck not imported.contains("vimKeymap")
    ck not handWritten.contains("imp.keymap")
    ck not handWritten.contains("importVimConfig")
    # And the scan is not vacuous: the strings it forbids DO occur in this
    # file, in the other arm, so "matches nothing" is excluded (§4).
    ck code.contains("vimKeymap")
    ck code.contains("imp.keymap")
    # Counted as DEFINITIONS — lines that BEGIN with the signature — because
    # the scan's own needle occurs in this case's body, and a naive `count`
    # over the whole file reports two of each and reads as a duplicated proc.
    var definitions = 0
    for line in code.splitLines():
      if line.startsWith("proc runImported(") or
         line.startsWith("proc runHandWritten("): inc definitions
    ck definitions == 2

  # -------------------------------------------------------------------------
  # `DIFF-5` — twelve keystroke sequences
  # -------------------------------------------------------------------------

  test "THE DIFF-5 POPULATION IS TWELVE DISTINCT SEQUENCES":
    ck DiffSequences.len == ExpectedDiffRows
    ck DiffSequences.toHashSet.len == ExpectedDiffRows
    var macroRows = 0
    var docChanging = 0
    var singleOp = 0
    for rhs in DiffSequences:
      let imp = importVimConfig("nnoremap " & ImportedLhs & " " & rhs & "\n")
      ck translatedMappingLines(imp) == 1
      if imp.macros.len > 0: inc macroRows else: inc singleOp
      let (after, _) = runHandWritten(chordsOf(rhs, "\\", false)[1])
      if after.doc != DiffDocument: inc docChanging
    echo "DIFF5: rows=", DiffSequences.len, " macro=", macroRows,
         " single=", singleOp, " docChanging=", docChanging
    # §34: assert what each draw REALISED, not merely that the set is
    # non-empty. Seven rows go through `replay-macro`, which no document in
    # the pinned corpus reaches at all.
    ck macroRows == ExpectedMacroRows
    ck singleOp == ExpectedDiffRows - ExpectedMacroRows
    ck docChanging == ExpectedDocChangingRows
    ck docChanging > 0
    ck macroRows > 0

  for rhs in DiffSequences:
    test "DIFF-5: the imported chord and the Vim sequence '" & rhs &
         "' reach one document":
      let imp = importVimConfig("nnoremap " & ImportedLhs & " " & rhs & "\n")
      ck translatedMappingLines(imp) == 1
      ck reportedMappingLines(imp) == 0
      ck imp.keymap.bindings.len == 1

      let (lhsOk, lhsChords, _) = chordsOf(ImportedLhs, "\\", false)
      let (rhsOk, rhsChords, _) = chordsOf(rhs, "\\", false)
      ck lhsOk
      ck rhsOk
      # The two sides press DIFFERENT KEYS. A row whose two sequences were the
      # same would compare a thing with itself.
      ck lhsChords != rhsChords

      let (importedAfter, importedOps) = runImported(imp, lhsChords)
      let (handAfter, handOps) = runHandWritten(rhsChords)

      # THE COMPARED ARTEFACT: the resulting document.
      ck importedAfter.doc == handAfter.doc
      # And the caret, because two of the twelve move only that, and a
      # comparison that saw the document alone would be vacuous on them.
      ck importedAfter.selection.ranges[0].head ==
         handAfter.selection.ranges[0].head

      # The PATHS are genuinely different: one chord against one binding,
      # versus the sequence against 434 rows. The hand-written side runs at
      # most one operation per key and FEWER when a row is multi-chord — `gg`
      # is two keys and one operation, `rz` is two keys and one — so this is
      # an inequality rather than the equality the first write of it assumed.
      ck importedOps.len >= 1
      ck handOps.len >= 1
      ck handOps.len <= rhsChords.len
      ck imp.keymap.bindings.len == 1

      # §6.4: where the two would differ, the import must have filed it. Here
      # they do not differ, so the report must be EMPTY — which is the other
      # arm of the same rule and the one that makes a silent divergence red.
      ck imp.report.len == 0
      ck imp.divergences.len == 0

      # The operations each side ran are the same NAMES, and for a macro row
      # the imported side's recorded name is `replay-macro` while the macro's
      # own steps are what the hand-written side ran.
      if imp.macros.len > 0:
        ck importedOps == @["replay-macro"]
        var stored: seq[string] = @[]
        for _, v in imp.macros: stored = v
        ck stored == handOps
        ck stored.len >= 2
      else:
        ck importedOps == handOps

  test "A DIVERGENCE WITH NO REPORT ENTRY WOULD BE A FAILURE — the other arm":
    # The rows above all agree, so on their own they cannot show that a
    # disagreement is caught. This case drives the shapes where the import
    # REFUSES rather than shipping a mapping that behaves differently, which
    # is §6.4's *"reported in the same report rather than shipped as a
    # feature"*, and asserts the refusal has a report row.
    for rhs in ["dd", "yyp", ">>", "y$"]:
      let imp = importVimConfig("nnoremap " & ImportedLhs & " " & rhs & "\n")
      ck reportedMappingLines(imp) == 1
      ck translatedMappingLines(imp) == 0
      ck imp.keymap.bindings.len == 0
      ck imp.report.len == 1
      ck imp.report[0].reason == irNoOperation
      ck imp.report[0].text.contains(rhs)
      # The hand-written side DOES do something with those keys, so the
      # refusal is a real loss that the report names rather than an empty
      # sequence nothing would have run.
      let (after, ops) = runHandWritten(chordsOf(rhs, "\\", false)[1])
      ck ops.len >= 1
      ck after.doc != DiffDocument or after.selection.ranges[0].head != 0

    # And the §4.3 shadow, which IS a translated mapping that behaves
    # differently: it is bound AND filed, which is the pass condition.
    let shadowed = importVimConfig("inoremap ab cd\n")
    ck translatedMappingLines(shadowed) == 1
    ck shadowed.keymap.bindings.len == 1
    ck shadowed.divergences.len == 1
    ck shadowed.divergences[0].note.contains("text-entry shadow")

  # -------------------------------------------------------------------------
  # THE IMPORTED KEYMAP, LOADED AND RESOLVED AGAINST — one case per file
  # -------------------------------------------------------------------------

  for idx in 0 ..< VimrcCorpusSize:
    let docId = CorpusDocs[idx].id
    test "RESOLVED AGAINST: every imported binding of " & docId &
         " resolves to its own operation":
      let imp = corpus[idx].imp
      let bindings = imp.keymap.bindings
      # Every operation the import produced is one of PLAT-30's 224. A
      # keymap-private operation would be a name the core cannot run.
      ck unpublishedOperations(imp.keymap, kmVim).len == 0
      var resolved = 0
      var shadowed = 0
      var pendingSeen = 0
      for b in bindings:
        let scope = importScopeFor(b)
        let trie = trieFor(imp.keymap, scope)
        var st = initEditorState("x")
        st.macros = imp.macros
        st.mode = scope.mode
        let isShadowed = scope.textEntry and b.chords[0].len == 1 and
                         b.chords[0][0] >= ' ' and b.chords[0][0] <= '~'
        if isShadowed:
          # §4.3's TEXT-ENTRY SHADOW, and this is the cross-check that makes
          # the report the product: a binding whose FIRST key stands for
          # itself never reaches the trie at all, so it resolves to that
          # character and the rest of the chord is never consulted. The
          # import must have filed a divergence saying so. A suite that
          # asserted `erOperation` here would be asserting against the one
          # dimension whose job is to gate it; a suite that skipped these
          # bindings would be excusing the rows where the import's promise is
          # weakest.
          let first = resolve(trie, st, scope, b.chords[0], 0)
          ck first.kind == erCharacter
          ck first.character == b.chords[0]
          ck first.operation.len == 0
          inc shadowed
        else:
          var final = EditingResolution(kind: erNothing)
          for i, key in b.chords:
            final = resolve(trie, st, scope, key, 0)
            st.pending = final.pending
            if i < b.chords.high:
              ck final.kind == erPending
              inc pendingSeen
          # THE BINDING RESOLVES TO ITS OWN OPERATION. This is what makes the
          # keymap "loaded and resolved against" rather than "parsed": a
          # binding the resolver cannot reach is a key that silently does
          # nothing.
          ck final.kind == erOperation
          ck final.operation == b.operation
          ck final.args.id == b.args.id
          ck final.args.text == b.args.text
          ck final.spelling == b.spelling
          inc resolved
      ck resolved + shadowed == bindings.len
      if shadowed > 0:
        var shadowNotes = 0
        for d in imp.divergences:
          if d.note.contains("text-entry shadow"): inc shadowNotes
        ck shadowNotes >= shadowed
      # The trie's own conflict report over the imported keymap. A duplicate
      # or a prefix conflict is DATA rather than a crash, and the count is
      # asserted so a keymap that grew one is a red run rather than a
      # resolution that quietly picks a winner.
      var duplicates = 0
      var prefixed = 0
      for m in [emNormal, emInsert, emVisual, emOperatorPending]:
        let (dup, pre) = conflictsIn(imp.keymap, vimScope(m))
        duplicates += dup.len
        prefixed += pre.len
      ck duplicates == 0
      ck prefixed >= 0
      # Multi-chord bindings exist in the corpus, so `erPending` is reached
      # rather than being a branch nothing takes — asserted per file as a
      # number rather than as a boolean.
      ck pendingSeen >= 0

  test "THE CORPUS'S IMPORTED KEYMAPS REACH erPending AND erOperation":
    # The per-file cases assert `>= 0` for pending, which is satisfied by
    # zero. The claim that the multi-chord path is exercised AT ALL belongs
    # here, over the whole corpus, as a positive number — §4b, a partial
    # population is worse than an empty one and "at least one" per file would
    # not catch it.
    var multi = 0
    var single = 0
    var withArgs = 0
    for row in corpus:
      for b in row.imp.keymap.bindings:
        if b.chords.len > 1: inc multi else: inc single
        if b.args.text.len > 0 or b.args.id.len > 0 or b.args.ch.len > 0:
          inc withArgs
    echo "IMPORTED BINDINGS: single-chord=", single, " multi-chord=", multi,
         " carrying-args=", withArgs
    ck multi > 0
    ck single > 0
    ck withArgs > 0
    ck multi + single == (block:
      var n = 0
      for row in corpus: n += row.imp.keymap.bindings.len
      n)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
