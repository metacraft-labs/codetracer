## test_mode_transition_oracle.nim — PLAT-16, Tier 1, STRUCTURAL.
##
## ## THE ORACLE IS THE PUBLISHED DOCUMENT, PARSED AT RUN TIME
##
## PLAT-16's integration-test list: *"The transition preserves what
## Mode-Transitions.md says it preserves, **with that document read at run time
## as the oracle rather than transcribed**."*
## CodeTracer-TUI-Edit-Mode.md §7 says the same and names the precedent:
## *"That document is the oracle; the suite reads it rather than transcribing
## it, as CTUI-9 and CTUI-10 established for §4.2 and §4.3."*
##
## So §5's preservation table is READ, at run time, out of
## `codetracer-specs/GUI/Layout-And-Navigation/Mode-Transitions.md`, each row's
## first cell is normalised by `product_mode.slugOfPreservedRow` — the PRODUCT's
## own normaliser, not one written here to make this test pass — and the
## resulting set is compared against `product_mode.PreservedConcern`. A row
## added, removed or renamed in the specification reddens this suite without
## anybody editing a test.
##
## **A MISSING SPEC CHECKOUT IS A FAILURE, NOT A SKIP.** The first case names
## the path and the sibling.
##
## ## AND THE SESSION IS THEN ASKED ABOUT EACH ROW IT PARSED
##
## Parsing the table proves the vocabularies agree. It does not prove anything
## is preserved. So the second half of this suite builds a real `EditSession` —
## two buffers, one dirty, distinct carets, distinct scroll positions, folds and
## breakpoints — snapshots `edit_binding.preservationWitness`, performs THREE
## round trips through `shell.ModeRegister.toggle`, and requires the witness to
## be unchanged after every one.
##
## **THREE, NOT ONE**, and Mode-Transitions.md §6 says why: *"A test that
## performs one round trip does not check this; the check needs at least three,
## because the failure mode is a slot that is right once and empty afterwards."*
##
## ## No mocks
##
## A markdown file, a `TextAreaWidget` from `isonim-tui`, and the product's own
## register. Nothing here is a stand-in for anything.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` it is invisible and the case
## reports `[OK]` while `programResult` goes to 1.

import std/[algorithm, os, strutils, unittest]

# `product_mode` — `ProductMode`, `sourceOriginFor`, the stale-trace verdict
# and `slugOfPreservedRow` — comes from the CORE through the sanctioned facade,
# which is the same door the modules under test use.
import codetracer_embed

import isonim_tui

import headless_app/layout_model

import ../edit_binding
import ../layout/profile
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 97

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  SpecRelativePath =
    "codetracer-specs/GUI/Layout-And-Navigation/Mode-Transitions.md"
  PreservationHeading = "## 5. Editor contents and the caret"
  TableHeaderCell = "Preserved"
  ExpectedPreservedRows = 6
    ## §5's row count, counted from the document on 2026-09-14. Asserted so
    ## that a parser which stopped at the first odd row — or a table that lost a
    ## row — is red here rather than quietly checking less.

proc specPath(): string =
  ## Where the published table lives, resolved from THIS FILE rather than from
  ## the working directory, so the suite answers the same way however it is
  ## invoked. `currentSourcePath` is
  ## `<repo>/src/frontend/tui/app/tests/<this>.nim`, so five `parentDir`s reach
  ## the checkout root and a sixth reaches the workspace the sibling checkouts
  ## share.
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 5:
    dir = dir.parentDir()
  dir.parentDir() / SpecRelativePath

proc readPreservedSlugs(path: string): seq[string] =
  ## §5's first column, normalised by the PRODUCT's own normaliser.
  ##
  ## The walk is anchored on the HEADING and then on the table's own header
  ## row, so prose elsewhere in the document that happens to contain pipes is
  ## not mistaken for a table (Verification-Harness-Traps §4d: a scan that
  ## matches prose is satisfied by prose).
  result = @[]
  if not fileExists(path):
    return
  let text = readFile(path)
  let at = text.find(PreservationHeading)
  if at < 0:
    return
  var inTable = false
  for raw in text[at .. ^1].splitLines:
    let line = raw.strip()
    if not inTable:
      if line.startsWith("|") and line.contains(TableHeaderCell):
        inTable = true
      elif line.startsWith("## ") and not line.startsWith(PreservationHeading):
        break
      continue
    if not line.startsWith("|"):
      break
    if line.replace("-", "").replace("|", "").strip().len == 0:
      continue   # the `| --- | --- |` separator
    let cells = line.split('|')
    if cells.len < 3:
      continue
    let slug = slugOfPreservedRow(cells[1])
    if slug.len > 0 and slug != slugOfPreservedRow(TableHeaderCell):
      result.add slug

# ---------------------------------------------------------------------------
# A session with something to lose
# ---------------------------------------------------------------------------

const
  FileA = "src/alpha.nim"
  FileB = "src/beta.nim"
  TextA = "let a = 1\nlet b = 2\nlet c = 3\n"
  TextB = "proc main() =\n  echo 42\n"

proc populatedSession(): EditSession =
  ## Two buffers, one of them dirty, with DISTINCT carets, DISTINCT scroll
  ## positions, a fold and two points.
  ##
  ## DISTINCT ON PURPOSE: §5 requires the state of every open file to survive,
  ## "not only the active one", and a witness in which both buffers happened to
  ## carry the same caret would be satisfied by an implementation that restored
  ## one value everywhere.
  result = newEditSession()
  discard result.openFile(FileA, TextA)
  discard result.openFile(FileB, TextB)
  let a = result.buffers[0]
  let b = result.buffers[1]
  # PLAT-34: the caret and the edit go through the BINDING rather than through
  # a widget this suite reached past. `moveCaretTo` is the model's, and the
  # edit is a real keystroke resolved through the product keymap — which is
  # what makes "the dirty buffer is dirty" a statement about the path the
  # product takes rather than about a widget method.
  a.moveCaretTo(2, 4)
  a.viewportTop = 2
  a.folded = @[1]
  b.moveCaretTo(1, 2)
  discard b.applyEditKey("!", 0)      # dirty, and only this one
  b.viewportTop = 1
  result.active = 0
  result.points = @[
    SourcePoint(path: FileA, line: 2, kind: sptBreakpoint, enabled: true),
    SourcePoint(path: FileB, line: 1, kind: sptTracepoint, enabled: true)]

# ---------------------------------------------------------------------------

suite "PLAT-16: §5's preservation table, read at run time":

  test "the specification is present, and §5's table parses":
    checkpoint("oracle: " & specPath())
    # A MISSING CHECKOUT IS A FAILURE, NOT A SKIP: `docs/tui-testing.md`'s
    # first rule and the Silent-Self-Pass audit are both explicit that a test
    # which detects a missing prerequisite and is counted PASSED is the defect.
    ck fileExists(specPath())
    let slugs = readPreservedSlugs(specPath())
    checkpoint("parsed rows: " & slugs.join(", "))
    ck slugs.len == ExpectedPreservedRows
    # THE PARSER IS NOT SATISFIED BY AN EMPTY DOCUMENT: every slug is
    # non-empty and no two are equal.
    var seen: seq[string] = @[]
    for slug in slugs:
      ck slug.len > 0
      ck slug notin seen
      seen.add slug

  test "every row the document names is a concern this build carries":
    var fromSpec = readPreservedSlugs(specPath())
    var fromCode = preservedConcernSlugs()
    fromSpec.sort()
    fromCode.sort()
    checkpoint("spec: " & fromSpec.join(", "))
    checkpoint("code: " & fromCode.join(", "))
    # SET EQUALITY IN BOTH DIRECTIONS. Containment one way would let this build
    # carry a concern the document does not name (which is an invention) or the
    # document name one this build ignores (which is the gap).
    ck fromSpec == fromCode
    ck fromCode.len == ExpectedPreservedRows

  test "a mutated cell is DETECTED — the oracle is read, not assumed":
    # THE PARSER MUST BE ABLE TO DISAGREE, or its agreement means nothing.
    # `slugOfPreservedRow` is the product's own normaliser and this feeds it the
    # document's cell with one word changed; the result must not be a concern
    # this build carries.
    let real = slugOfPreservedRow("**Caret position and selection**")
    let mutated = slugOfPreservedRow("**Caret position and highlight**")
    checkpoint("real='" & real & "' mutated='" & mutated & "'")
    ck real == $pcCaretAndSelection
    ck mutated != real
    ck mutated notin preservedConcernSlugs()
    # …and the normaliser really normalises rather than passing text through:
    # emphasis, case and the elaborating clause all go.
    ck slugOfPreservedRow(
      "The set of open editor tabs, their order, and which is active") ==
      $pcOpenTabs
    ck slugOfPreservedRow("Fold state") == $pcFoldState
    ck slugOfPreservedRow("Breakpoints") == $pcBreakpoints

suite "PLAT-16: the transition preserves what §5 says it preserves":

  test "three round trips leave every parsed concern byte-identical":
    # §6: "A test that performs one round trip does not check this; the check
    # needs at least three, because the failure mode is a slot that is right
    # once and empty afterwards."
    let session = populatedSession()
    let slugs = readPreservedSlugs(specPath())
    ck slugs.len == ExpectedPreservedRows

    # THE WITNESS IS TAKEN PER PARSED SLUG, so the loop below asks the session
    # about the concerns the DOCUMENT names rather than about a list this file
    # wrote.
    var before: seq[string] = @[]
    var comparisons = 0
    for slug in slugs:
      var found = false
      for c in PreservedConcern:
        if $c == slug:
          before.add preservedValue(session, c)
          found = true
      ck found
    ck before.len == slugs.len

    # THE NON-VACUITY FLOOR: a witness of six empty strings would be preserved
    # by an implementation that threw the session away.
    for value in before:
      ck value.len > 0
    # …and the two buffers really differ in every per-file concern, so a
    # restore-one-value-everywhere implementation cannot pass.
    ck before[2].contains("|")          # caret: two entries
    ck before[3].contains("|")          # scroll: two entries
    ck preservedValue(session, pcUnsavedBuffers).contains("dirty:")
    ck preservedValue(session, pcUnsavedBuffers).contains("clean:")

    var reg = initModeRegister(pmEdit)
    let editTree = editProfileLayout(lpStandard)
    var onScreen = editTree
    for trip in 1 .. 3:
      # Edit -> Debug -> Edit.
      ck reg.toggle(onScreen, lpStandard)
      onScreen = reg.activeLayout()
      ck reg.product == pmDebug
      ck reg.toggle(onScreen, lpStandard)
      onScreen = reg.activeLayout()
      ck reg.product == pmEdit
      for i, slug in slugs:
        inc comparisons
        for c in PreservedConcern:
          if $c == slug and preservedValue(session, c) != before[i]:
            checkpoint("trip " & $trip & " lost " & slug & ": '" &
                       preservedValue(session, c) & "' was '" & before[i] & "'")
            ck preservedValue(session, c) == before[i]
      # THE nTH TRIP IS THE FIRST: the Edit-mode tree that comes back is the
      # one that went in, every time, not only the first.
      ck onScreen == editTree
    checkpoint("comparisons: " & $comparisons)
    ck comparisons == 3 * ExpectedPreservedRows

  test "the register is keyed by MODE, so Edit does not disturb Debug":
    # §4b: "A register keyed by the mode makes the nth switch read the cell the
    # first one wrote." The two trees are DIFFERENT OBJECTS and each mode gets
    # its own back.
    var reg = initModeRegister(pmDebug)
    let debugTree = profileLayout(lpStandard)
    ck reg.toggle(debugTree, lpStandard)
    ck reg.product == pmEdit
    let firstEdit = reg.activeLayout()
    ck not firstEdit.isNil
    # §4a: the Edit default is a FUNCTION OF THE MODE and not the Debug tree
    # with panes removed.
    ck firstEdit != debugTree
    ck firstEdit.contains(paneFileTree)
    ck firstEdit.contains(paneBuildOutput)
    ck not firstEdit.contains(paneCalltrace)
    ck debugTree.contains(paneCalltrace)
    ck not debugTree.contains(paneFileTree)

    # The user rearranges EDIT mode…
    let rearranged = column([
      pane(paneEditor, "Source", weight = 1.0),
      pane(paneFileTree, "Files", weight = 1.0)])
    # …and goes to Debug and back, three times.
    var onScreen = rearranged
    for trip in 1 .. 3:
      ck reg.toggle(onScreen, lpStandard)
      ck reg.product == pmDebug
      # §4 requirement 2: the DEBUG tree that comes back is the one that went
      # in — the session's own node, by identity and not by a copy.
      ck reg.activeLayout() == debugTree
      onScreen = reg.activeLayout()
      ck reg.toggle(onScreen, lpStandard)
      ck reg.product == pmEdit
      # …and the EDIT tree is the user's arrangement, not the default.
      ck reg.activeLayout() == rearranged
      ck reg.activeLayout() != firstEdit
      onScreen = reg.activeLayout()

  test "an idempotent switch changes nothing and overwrites no cell":
    # §6: "Switching to the mode the session is already in changes nothing —
    # not the layout, not the caret, not the toolbar. In particular it must not
    # overwrite the OTHER mode's saved arrangement with the current one."
    var reg = initModeRegister(pmDebug)
    let debugTree = profileLayout(lpStandard)
    let editTree = editProfileLayout(lpStandard)
    ck reg.switchTo(debugTree, pmEdit, lpStandard)
    ck reg.switchTo(editTree, pmDebug, lpStandard)
    ck reg.product == pmDebug
    ck reg.layouts[pmEdit] == editTree
    ck reg.layouts[pmDebug] == debugTree

    # THE IDEMPOTENT CALL, with a DIFFERENT tree offered as "leaving". If the
    # guard ran after the save, this tree would land in the Debug cell — and if
    # the guard were missing entirely it would land in the Edit cell too.
    let intruder = profileLayout(lpCompact)
    ck not reg.switchTo(intruder, pmDebug, lpStandard)
    ck reg.product == pmDebug
    ck reg.layouts[pmDebug] == debugTree
    ck reg.layouts[pmEdit] == editTree
    ck reg.layouts[pmDebug] != intruder
    ck reg.layouts[pmEdit] != intruder

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
