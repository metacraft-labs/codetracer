## test_editor_vocabulary_oracle.nim — PLAT-30's SPEC-AS-ORACLE half.
##
## §2.2 of `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` calls
## itself the test oracle. This is the program that takes it at its word: it
## parses the four category tables out of the published document, generates the
## 224 names from the 140 declarations by §2.2's own rules, and compares them
## with `operations.vocabulary()` row by row, in both directions, with the
## cardinality asserted on both sides.
##
## =========================================================================
## THE FIVE LINES OF §7.1, AND THE ONE THAT IS USUALLY OMITTED
## =========================================================================
##
## Editor-Model-Conformance-Suite.md §7.1 states the protocol exactly:
##
## ```
## assert parsedRows(T)      == ExpectedRows        # the parser reached the whole table
## assert cardinality(I)     == ExpectedOperations  # the implementation did not shrink
## assert names(T) - names(I) == {}                 # nothing published is unimplemented
## assert names(I) - names(T) == {}                 # nothing implemented is unpublished
## assert |names(T)| == |names(I)| == ExpectedNames # and neither set is empty
## ```
##
## **The last line is the one that is usually omitted, and without it the two
## set-differences are both satisfied by two empty sets** — a parser that read
## nothing and an implementation that declared nothing agree perfectly. All
## five are below, each as a case of its own, over BOTH of §7.2's oracle tables
## for this milestone: the vocabulary, and the `Display-dependent` column.
##
## =========================================================================
## THE PARSER IMPLEMENTS THE PUBLISHED GRAMMAR AND THE CENSUS IS NOT ITS CONTROL
## =========================================================================
##
## §2.4 publishes the grammar precisely so that whoever writes this parser does
## not have to infer one, and it also says what to do when the two independent
## parsers disagree: *"the grammar above is ambiguous and THE TABLE is what
## gets fixed — neither parser is adjusted to match the other."*
## `codetracer-specs/tools/editing-vocabulary-census.py` implements the same
## grammar in Python for a READER; this file implements it in Nim for the
## SUITE. Neither validates the other, and nothing here reads the census's
## output. Two copies of one predicate would be
## Verification-Harness-Traps §30; two independent implementations of one
## PUBLISHED grammar, compared against the same document, is the opposite.
##
## **THE DUPLICATE CHECK IS PART OF THE PARSER, NOT A NICETY.** §2.4 records
## that `move-line-up` was published twice with two different meanings,
## forty-six lines apart in two different tables. Without a duplicate check the
## two set differences above are both empty while `|names(T)|` is one smaller
## than the count claims — so the cardinality assertion passes against the
## wrong number, which is the exact failure the fifth line exists to prevent.
##
## =========================================================================
## `staticRead`, AND A MISSING CHECKOUT FAILS BY NAME
## =========================================================================
##
## `test_keymap_no_conflicts.nim` reads its oracle with `os.readFile` at run
## time. This suite cannot: it runs in `vm-unit`, `vm-unit-js` AND
## `vm-unit-wasm`, and `std/os`'s `readFile` does not exist on the JS backend —
## which is the reason `tests/corpus/unicode_corpus.nim` gives for its own
## `staticRead`, in this same directory. So the oracle is read at COMPILE time,
## from the sibling checkout, by a path this file states; a missing checkout is
## a compile error naming the path, which is louder than the runtime failure it
## replaces and is still the opposite of a skip. The document is never
## transcribed, which is the property §7 actually asks for.
##
## ## No mocks
## Two files: the published specification and the implementation's table.

import std/[algorithm, strutils, tables, unittest]

import ../../editor/operations
import ../../../../common/editing_key_bindings
import ../generators/vocabulary_generator

const ExpectedAssertions = 1038

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  SpecRelativePath = "codetracer-specs/GUI/Editing-Operations-And-Keymaps.md"
  SpecSource = staticRead(
    "../../../../../../codetracer-specs/GUI/Editing-Operations-And-Keymaps.md")
    ## **READ, NEVER TRANSCRIBED.** See the header on why this is `staticRead`.

  SectionStart = "### 2.2 The four categories"
  SectionEnd = "### 2.3 "

  ExpectedDeclarations = 140
  ExpectedOperations = 224
  ExpectedDisplayDependent = 24
  ExpectedDisplayIndependent = 200
  ExpectedPerCategory = [34, 16, 20, 70]      ## A, B, C, D
  ExpectedDisplayColumnRows = 50              ## A's 34 and B's 16 carry one

  # The forms each category generates. §2.2 A and §2.2 B state them; this is
  # the parser's side of the same rule, written from the DOCUMENT rather than
  # imported from `operations.FormsOf`, because an oracle that took its
  # generation rule from the implementation would be the implementation
  # agreeing with itself.
  FormsA = ["move-", "extend-", "select-"]
  FormsB = ["select-inner-", "select-around-"]

type
  SpecDeclaration = object
    category: char            ## 'A' … 'D'
    name: string              ## the token up to `(`
    hasArgument: bool         ## whether the published token carried `(`
    displayDependent: bool
    displayColumnPresent: bool

# ===========================================================================
# THE PARSER — §2.4's grammar, implemented here and nowhere else in this repo
# ===========================================================================

proc backtickedTokens(cell: string): seq[string] =
  ## Every `…`-quoted token of one markdown cell, in order.
  result = @[]
  var i = 0
  while i < cell.len:
    if cell[i] == '`':
      let close = cell.find('`', i + 1)
      if close < 0: break
      result.add cell[i + 1 ..< close]
      i = close + 1
    else:
      inc i

proc cellsOf(line: string): seq[string] =
  ## A markdown table row as trimmed cells. The leading and trailing `|` are
  ## dropped; everything between them is a cell, including empty ones, because
  ## a column index is what the grammar addresses.
  var body = line.strip()
  if body.startsWith("|"): body = body[1 .. ^1]
  if body.endsWith("|"): body = body[0 ..< body.len - 1]
  result = @[]
  for c in body.split('|'): result.add c.strip()

proc isSeparatorRow(cells: seq[string]): bool =
  if cells.len == 0: return false
  for ch in cells[0]:
    if ch notin {'-', ':', ' '}: return false
  cells[0].len > 0

proc parseSection(): seq[SpecDeclaration] =
  ## §2.4's grammar:
  ##   * a category is a `#### <LETTER>. <Title>` heading inside §2.2;
  ##   * every category is a table;
  ##   * declarations are the backticked tokens of the FIRST column for A, B
  ##     and C, and of the SECOND for D — D's first column is a group label;
  ##   * a declaration's NAME is the token up to `(`;
  ##   * display-dependence is the column headed exactly `Display-dependent`.
  let start = SpecSource.find(SectionStart)
  doAssert start >= 0,
    "the oracle section '" & SectionStart & "' is not in " & SpecRelativePath &
    ". The published table is this suite's expected value and there is " &
    "nothing to fall back to."
  var stop = SpecSource.find(SectionEnd, start)
  if stop < 0: stop = SpecSource.len
  let body = SpecSource[start ..< stop]

  result = @[]
  var category = '\0'
  var declColumn = -1
  var ddColumn = -1
  var sawHeader = false
  for raw in body.splitLines():
    let line = raw.strip()
    if line.startsWith("#### ") and line.len > 6 and line[6] == '.':
      category = line[5]
      declColumn = if category == 'D': 1 else: 0
      ddColumn = -1
      sawHeader = false
      continue
    if category == '\0' or not line.startsWith("|"): continue
    let cells = cellsOf(line)
    if isSeparatorRow(cells): continue
    if not sawHeader:
      # The header row: it names the columns, and one of them may be the
      # display-dependence column. It is never a declaration.
      sawHeader = true
      for i, h in cells:
        if h == "Display-dependent": ddColumn = i
      continue
    if declColumn >= cells.len: continue
    let dd = ddColumn >= 0 and ddColumn < cells.len and
             "yes" in cells[ddColumn].toLowerAscii()
    for token in backtickedTokens(cells[declColumn]):
      let paren = token.find('(')
      let name = if paren >= 0: token[0 ..< paren] else: token
      if name.len == 0: continue
      var whitespaced = false
      for ch in name:
        if ch in {' ', '\t'}: whitespaced = true
      doAssert not whitespaced,
        "category " & category & ": the declaration token '" & token &
        "' is not a name. §2.4's grammar reads the backticked tokens of one " &
        "column; a token with whitespace in it means that column is prose."
      result.add SpecDeclaration(category: category, name: name,
                                 hasArgument: paren >= 0,
                                 displayDependent: dd,
                                 displayColumnPresent: ddColumn >= 0)

proc generatedNamesOf(d: SpecDeclaration): seq[string] =
  case d.category
  of 'A':
    result = @[]
    for f in FormsA: result.add f & d.name
  of 'B':
    result = @[]
    for f in FormsB: result.add f & d.name
  else:
    result = @[d.name]

# ===========================================================================

let specDecls = parseSection()

proc specOperationNames(): seq[string] =
  result = @[]
  for d in specDecls:
    for n in generatedNamesOf(d): result.add n

proc specDisplayDependentNames(): seq[string] =
  result = @[]
  for d in specDecls:
    if d.displayDependent:
      for n in generatedNamesOf(d): result.add n

proc implOperationNames(): seq[string] =
  result = @[]
  for op in operations(): result.add op.name

proc implDisplayDependentNames(): seq[string] =
  result = @[]
  for op in operations():
    if op.displayDependent: result.add op.name

proc sortedUnique(xs: seq[string]): seq[string] =
  result = @[]
  for x in xs:
    if x notin result: result.add x
  result.sort()

proc difference(a, b: seq[string]): seq[string] =
  result = @[]
  for x in a:
    if x notin b and x notin result: result.add x
  result.sort()

let
  specNamesAll = specOperationNames()
  implNamesAll = implOperationNames()
  specDdAll = specDisplayDependentNames()
  implDdAll = implDisplayDependentNames()

# ===========================================================================
# THE PARSER'S OWN ASSERTIONS
# ===========================================================================

suite "PLAT-30: the oracle is PARSED, and the parser is asserted first":

  test "the published section was found and parsed, category by category":
    checkpoint("oracle: " & SpecRelativePath & ", " & $SpecSource.len & " bytes")
    ck SpecSource.len > 0
    ck SectionStart in SpecSource
    ck SectionEnd in SpecSource
    var perCategory = [0, 0, 0, 0]
    for d in specDecls:
      case d.category
      of 'A': inc perCategory[0]
      of 'B': inc perCategory[1]
      of 'C': inc perCategory[2]
      of 'D': inc perCategory[3]
      else: ck d.category in {'A', 'B', 'C', 'D'}
    checkpoint("A " & $perCategory[0] & " / B " & $perCategory[1] &
               " / C " & $perCategory[2] & " / D " & $perCategory[3])
    for i in 0 .. 3:
      ck perCategory[i] == ExpectedPerCategory[i]
    ck specDecls.len == ExpectedDeclarations

  test "a DUPLICATE-NAME CHECK is part of the parser, on both sides of it":
    # §2.4: without this, "every operation appears in the table and is
    # exercised" is satisfiable with 139 distinct names, and BOTH set
    # differences below stay empty while the cardinality is wrong.
    var declSeen = initTable[string, int]()
    for d in specDecls: declSeen[d.name] = declSeen.getOrDefault(d.name) + 1
    var declDupes: seq[string] = @[]
    for name, n in declSeen:
      if n > 1: declDupes.add name
    for d in declDupes: checkpoint("declared twice in the table: " & d)
    ck declDupes.len == 0

    var opSeen = initTable[string, int]()
    for n in specNamesAll: opSeen[n] = opSeen.getOrDefault(n) + 1
    var opDupes: seq[string] = @[]
    for name, n in opSeen:
      if n > 1: opDupes.add name
    for d in opDupes: checkpoint("two declarations generate it: " & d)
    ck opDupes.len == 0
    # …and the implementation's own two answers to the same question.
    ck duplicateDeclarationNames().len == 0
    ck duplicateOperationNames().len == 0
    # THE CHECK IS FALSIFIABLE. `move-line-up` is the collision §2.4 records;
    # planting it here makes the detector produce exactly one name, so a
    # detector that found nothing because it was looking in the wrong place is
    # not what the four assertions above are resting on.
    var planted = specNamesAll
    planted.add "move-line-up"
    var plantedSeen = initTable[string, int]()
    for n in planted: plantedSeen[n] = plantedSeen.getOrDefault(n) + 1
    var plantedDupes: seq[string] = @[]
    for name, n in plantedSeen:
      if n > 1: plantedDupes.add name
    ck plantedDupes == @["move-line-up"]

  test "the parser reads the DECLARED column and never the prose ones":
    # §2.4 records the defect that made this rule explicit: prose inside
    # category D's Operations cell made a backtick parser count 71 commands
    # where there are 70. Category D's FIRST column is a group label and is
    # never read, and the note column is never read in any category.
    var groupLabels = 0
    var noteTokens = 0
    for raw in SpecSource.splitLines():
      let line = raw.strip()
      if not line.startsWith("| Insertion") and not line.startsWith("| Deletion by unit"):
        continue
      inc groupLabels
      let cells = cellsOf(line)
      ck cells.len >= 3
      # The group label carries no backticks at all, which is what makes
      # "read column 1" well defined rather than lucky.
      ck backtickedTokens(cells[0]).len == 0
      noteTokens += backtickedTokens(cells[2]).len
    ck groupLabels == 2
    # `delete-char-backward`'s note quotes `*char*` and `ZWJ`; none of them is
    # a declaration, and the count of tokens the parser ignored is printed so
    # "the note column is never read" is a measurement.
    checkpoint("backticked tokens ignored in the two sampled note cells: " &
               $noteTokens)
    ck specDecls.len == ExpectedDeclarations

# ===========================================================================
# §7.1, TABLE 1 — THE EDITING VOCABULARY. Five lines, five cases.
# ===========================================================================

suite "PLAT-30: §7.1 over the editing vocabulary (§2.2)":

  test "§7.1 line 1 — parsedRows(T) == ExpectedRows":
    ck specDecls.len == ExpectedDeclarations
    ck specNamesAll.len == ExpectedOperations

  test "§7.1 line 2 — cardinality(I) == ExpectedOperations":
    ck operations().len == ExpectedOperations
    ck vocabulary().len == ExpectedDeclarations
    ck unimplementedDeclarations().len == 0

  test "§7.1 line 3 — names(T) - names(I) == {}":
    let missing = difference(specNamesAll, implNamesAll)
    for m in missing: checkpoint("published and unimplemented: " & m)
    ck missing.len == 0

  test "§7.1 line 4 — names(I) - names(T) == {}":
    let extra = difference(implNamesAll, specNamesAll)
    for e in extra: checkpoint("implemented and unpublished: " & e)
    ck extra.len == 0

  test "§7.1 line 5 — |names(T)| == |names(I)| == 224, WITHOUT WHICH THE PAIR IS NOT A GATE":
    let t = sortedUnique(specNamesAll)
    let i = sortedUnique(implNamesAll)
    checkpoint("|names(T)| = " & $t.len & ", |names(I)| = " & $i.len)
    ck t.len == ExpectedOperations
    ck i.len == ExpectedOperations
    ck t.len == i.len
    ck t == i
    # The line exists because two EMPTY sets satisfy both differences. This is
    # that statement made falsifiable rather than repeated: over two empty
    # sets, lines 3 and 4 pass and this one does not.
    let emptyT: seq[string] = @[]
    let emptyI: seq[string] = @[]
    ck difference(emptyT, emptyI).len == 0
    ck difference(emptyI, emptyT).len == 0
    ck emptyT.len != ExpectedOperations

# ===========================================================================
# §7.1, TABLE 2 — THE `Display-dependent` COLUMN. Five more.
# ===========================================================================

suite "PLAT-30: §7.1 over the display-dependence column (§2.3)":

  test "§7.1 line 1 — the Display-dependent column was found, on the rows that have one":
    var withColumn = 0
    for d in specDecls:
      if d.displayColumnPresent: inc withColumn
    checkpoint("declarations carrying a Display-dependent column: " & $withColumn)
    ck withColumn == ExpectedDisplayColumnRows
    # Categories C and D have no such column, and that is the grammar rather
    # than an accident: both are display-independent by construction.
    for d in specDecls:
      if d.category in {'C', 'D'}: ck not d.displayColumnPresent

  test "§7.1 line 2 — cardinality(I) == 24 dependent and 200 independent":
    ck displayDependentCount() == ExpectedDisplayDependent
    ck operations().len - displayDependentCount() == ExpectedDisplayIndependent

  test "§7.1 line 3 — dependent(T) - dependent(I) == {}":
    let missing = difference(specDdAll, implDdAll)
    for m in missing: checkpoint("published display-dependent, not declared: " & m)
    ck missing.len == 0

  test "§7.1 line 4 — dependent(I) - dependent(T) == {}":
    let extra = difference(implDdAll, specDdAll)
    for e in extra: checkpoint("declared display-dependent, not published: " & e)
    ck extra.len == 0

  test "§7.1 line 5 — |dependent(T)| == |dependent(I)| == 24, and the complement is 200":
    let t = sortedUnique(specDdAll)
    let i = sortedUnique(implDdAll)
    checkpoint("|dependent(T)| = " & $t.len & ", |dependent(I)| = " & $i.len)
    ck t.len == ExpectedDisplayDependent
    ck i.len == ExpectedDisplayDependent
    ck t == i
    # THE COMPLEMENT IS ASSERTED TOO. §2.3: *"a check on one direction only is
    # satisfied by declaring everything dependent"* — and a cardinality on the
    # dependent set alone is satisfied by a table with 24 rows in it.
    let independentT = difference(sortedUnique(specNamesAll), t)
    let independentI = difference(sortedUnique(implNamesAll), i)
    ck independentT.len == ExpectedDisplayIndependent
    ck independentI.len == ExpectedDisplayIndependent
    ck independentT == independentI

# ===========================================================================
# 140 CASES — the table compared row by row
# ===========================================================================

let implByName = block:
  var t = initTable[string, int]()
  for i, d in vocabulary(): t[d.name] = i
  t

suite "PLAT-30: the published table, compared row by row":
  for specDecl in specDecls:
    test "row: " & specDecl.name:
      checkpoint("category " & specDecl.category & ", display-dependent " &
                 $specDecl.displayDependent)
      ck implByName.hasKey(specDecl.name)
      if implByName.hasKey(specDecl.name):
        let d = vocabulary()[implByName[specDecl.name]]
        # The CATEGORY, because a motion implemented as a command would
        # generate one name where the table publishes three and both set
        # differences would still be empty… only if the other two names came
        # from somewhere. They cannot, so this is what makes that impossible.
        let wanted = case specDecl.category
                     of 'A': ocMotion
                     of 'B': ocObject
                     of 'C': ocOperator
                     else: ocCommand
        ck d.category == wanted
        ck d.displayDependent == specDecl.displayDependent
        # The ARGUMENT LIST. §2.4: *"a declaration's NAME is the token up to
        # `(`; what follows is its argument list and is not part of the
        # name"* — so the name comparison above cannot see an argument that
        # was published and not implemented, and this is the assertion that
        # can.
        ck (d.arg != akNone) == specDecl.hasArgument
        # …and every form the category generates exists.
        for n in generatedNamesOf(specDecl):
          ck operationNamed(n) >= 0

# ===========================================================================
# 14 CASES — `applyEditKey`'s behaviours, asserted to survive its retirement
# ===========================================================================

let scenarioDoc0 = scenarioDocs()[0]

suite "PLAT-30: the fourteen behaviours survive the retirement, by name":
  for row in TuiEditBindings:
    test "behaviour: " & $row.behaviour:
      checkpoint("key '" & row.key & "' -> " & row.operation & " (" &
                 $row.effect & ")")
      # 1. The row names a PUBLISHED operation. This is the join that stops
      #    the terminal's editing path being a third orphan vocabulary beside
      #    `ClientAction` and `KeyAction`.
      ck row.operation in implNamesAll
      ck row.operation in specNamesAll
      ck operationNamed(row.operation) >= 0
      # 2. The behaviour is bound exactly once.
      var bound = 0
      for other in TuiEditBindings:
        if other.behaviour == row.behaviour: inc bound
      ck bound == 1
      # 3. RUNNING the named operation over a real corpus document produces
      #    the effect the row declares. A row naming an operation whose
      #    behaviour is not the key's would otherwise read as a join and be a
      #    label.
      let opIdx = operationNamed(row.operation)
      let declName = vocabulary()[operations()[opIdx].decl].name
      let sc = scenarioFor(scenarioDoc0, specFor(declName))
      let res = applyOperationAt(sc.state, opIdx, sc.args,
                                 wrapSettings(DisplayWrapA), 4)
      ck res.outcome == ooActed
      case row.effect
      of eeMoved:
        ck res.state.doc == sc.state.doc
        ck res.state.selection != sc.state.selection
      of eeChanged:
        ck res.state.doc != sc.state.doc

# ===========================================================================
# THE BOUNDARY WITH THE TWO EXISTING VOCABULARIES
# ===========================================================================

suite "PLAT-30: three vocabularies, and the resolution order between them":

  test "the binding table answers the three questions a `case` could not":
    ck TuiEditBindings.len == EditBehaviourCount
    ck ord(high(EditBehaviour)) - ord(low(EditBehaviour)) + 1 == EditBehaviourCount
    ck duplicateEditKeys().len == 0
    ck unboundBehaviours().len == 0
    # The thirteen keys `applyEditKey` had an `of` arm for, by name, plus the
    # `else` arm as the default row. This is the "fourteen behaviours" claim
    # in the only form that can fail.
    let wanted = ["Left", "Right", "Up", "Down", "Home", "End", "Backspace",
                  "Delete", "Enter", "Tab", "Shift+Tab", "Ctrl+z", "Ctrl+y"]
    ck wanted.len == 13
    for k in wanted:
      checkpoint("key must still be bound: " & k)
      ck editBindingIndex(k) >= 0
    ck defaultEditBindingIndex() >= 0
    ck TuiEditBindings[defaultEditBindingIndex()].key == DefaultEditKey
    # A key the table does not bind resolves to nothing, which is what lets
    # `applyEditKey` hand it back to the keymap.
    ck editBindingIndex("F5") < 0
    ck editBindingIndex("Ctrl+w") < 0

  test "the two divergences are declared, counted, and are exactly two":
    let divs = declaredDivergences()
    for d in divs:
      checkpoint("divergent row: " & d)
    ck divs.len == 2
    ck "Home" in divs
    ck "Tab" in divs
    # …and every non-divergent row's operation is one whose published meaning
    # the row performs unchanged. Stated as a count so a third divergence
    # arriving without a note is red rather than unnoticed.
    var clean = 0
    for row in TuiEditBindings:
      if row.divergence.len == 0: inc clean
    ck clean == EditBehaviourCount - 2

  test "neither existing vocabulary is extended into this one":
    # §1.1: `ClientAction` (194 members, Monaco's names) and `KeyAction` (51
    # members, terminal, no editing operation) *"exist, are disjoint, and
    # neither is this one"*. The mechanical form of "not extended" is that no
    # generated name collides with either enum's spelling convention —
    # `ClientAction`'s members are `aCamelCase` and `KeyAction`'s are
    # `kaCamelCase`, and every one of the 224 is `lower-kebab-case`.
    var wrongShape: seq[string] = @[]
    for n in implNamesAll:
      var ok = n.len > 0
      for ch in n:
        if ch notin {'a' .. 'z', '-'}: ok = false
      if n.startsWith("-") or n.endsWith("-"): ok = false
      if not ok: wrongShape.add n
    for w in wrongShape: checkpoint("not a vocabulary name: " & w)
    ck wrongShape.len == 0
    ck implNamesAll.len == ExpectedOperations
    # The RESOLUTION ORDER, stated in code rather than left an accident
    # (§1.1's *"a chord may resolve to a debugger action or to an editing
    # operation, and which one it resolves to is decided by scope"*): at this
    # milestone the editing table is consulted FIRST for a key, and a key it
    # does not bind is handed back. `editBindingIndex` returning -1 is that
    # hand-back, and the two keys above are the evidence it happens.
    ck editBindingIndex("Left") >= 0
    ck editBindingIndex("F10") < 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
