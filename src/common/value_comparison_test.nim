## value_comparison_test.nim — the scratchpad's comparison, as a project
## selects or supplies it (Project-Definitions §7).
##
## Pure: the declarations are parsed by the real loader from real TOML text,
## the values are real `PValue`s, and the executable comparisons are real
## WebAssembly modules (`project_wasm_fixtures`) run by the real sandbox under
## a real trust ledger value. NO MOCKS.
##
## Compile and run (lane `common-units`):
##   nim c -r src/common/value_comparison_test.nim

import std/[strutils, unittest]

import ./project_definitions
import ./project_executables
import ./project_wasm_fixtures
import ./value_comparison
import ./value_presentation

const Selections = """
schema = "codetracer.scratchpad.v1"

[[diff]]
match = "Matrix"
algorithm = "numeric-tolerance"
tolerance = "0.01"

[[diff]]
match = "Tags"
algorithm = "unordered-set"

[[diff]]
match = "Report"
algorithm = "text-lines"
"""

proc loaded(): LoadedProjectDefinitions =
  loadProjectDefinitions([DefinitionFile(kind: dfkScratchpad,
    origin: doProject, scope: "", path: ".codetracer/scratchpad.toml",
    text: Selections)])

proc num(t: string; typeName = "float"): PValue =
  PValue(kind: pvkFloat, typeName: typeName, text: t)

proc matrix(a, b: string): PValue =
  PValue(kind: pvkRecord, typeName: "Matrix", members: @[
    PMember(label: "a", value: num(a)), PMember(label: "b", value: num(b))])

proc tags(items: openArray[string]): PValue =
  result = PValue(kind: pvkSequence, typeName: "Tags")
  for i in items:
    result.members.add PMember(value: PValue(kind: pvkString, typeName: "str",
                                             text: i))

proc text(t: string; typeName = "Report"): PValue =
  PValue(kind: pvkString, typeName: typeName, text: t)

proc compareAs(a, b: PValue): Comparison =
  var sel: DiffSelection
  let found = selectDiff(loaded(), a, sel)
  compareValues(a, b, sel, found)

suite "the scratchpad compares the way the project selected":

  test "the selections load":
    let l = loaded()
    check l.problems.len == 0
    check l.project.diffs.len == 3

  test "numeric-tolerance reads its tolerance":
    # Within 0.01: equal. The SAME pair compared structurally is different,
    # which is what makes the tolerance the thing that decided.
    let c = compareAs(matrix("1.000", "2.0"), matrix("1.004", "2.0"))
    check c.verdict == cvEqual
    check c.algorithm == "numeric-tolerance 0.01"
    check c.selectedBy == ".codetracer/scratchpad.toml#0"
    check compareValues(matrix("1.000", "2.0"), matrix("1.004", "2.0"),
                        DiffSelection(), false).verdict == cvDifferent
    # Outside it: different.
    check compareAs(matrix("1.0", "2.0"), matrix("1.02", "2.0")).verdict ==
          cvDifferent
    # A differing STRUCTURE is different whatever the numbers say.
    var other = matrix("1.0", "2.0")
    other.members[1].label = "c"
    check compareAs(matrix("1.0", "2.0"), other).verdict == cvDifferent

  test "unordered-set ignores order and not membership":
    check compareAs(tags(["a", "b", "c"]), tags(["c", "a", "b"])).verdict ==
          cvEqual
    check compareAs(tags(["a", "b"]), tags(["a", "b", "b"])).verdict ==
          cvDifferent
    check compareValues(tags(["a", "b"]), tags(["b", "a"]), DiffSelection(),
                        false).verdict == cvDifferent

  test "text-lines ignores line endings and trailing space":
    check compareAs(text("one\r\ntwo  \n"), text("one\ntwo")).verdict == cvEqual
    check compareAs(text("one\ntwo"), text("one\nthree")).verdict == cvDifferent

  test "an algorithm that does not apply falls back, and says so":
    let c = compareAs(PValue(kind: pvkInt, typeName: "Tags", text: "1"),
                      PValue(kind: pvkInt, typeName: "Tags", text: "1"))
    check c.verdict == cvEqual
    check c.note.contains("compared structurally")

  test "a type nothing selected is compared structurally":
    let c = compareAs(num("1", "int"), num("1", "int"))
    check c.verdict == cvEqual
    check c.algorithm == "structural"
    check c.selectedBy == ""
    check describe(c).startsWith("= equal by structural")

  test "a comparison too large to walk is still answered":
    var big = PValue(kind: pvkSequence, typeName: "list")
    for i in 0 ..< MaxComparisonWork + 10:
      big.members.add PMember(value: num("1"))
    let c = compareValues(big, big, DiffSelection(), false)
    check c.verdict == cvEqual
    check c.note.contains("larger than one comparison may walk")

suite "a selection may match by shape (§5.3)":

  test "a tuple of two numbers is compared within the tolerance":
    let l = loadProjectDefinitions([DefinitionFile(kind: dfkScratchpad,
      origin: doProject, scope: "", path: ".codetracer/scratchpad.toml",
      text: "schema = \"codetracer.scratchpad.v1\"\n\n[[diff]]\n" &
            "matchKind = \"shape\"\nmatch = \"#2\"\n" &
            "algorithm = \"numeric-tolerance\"\ntolerance = \"0.5\"\n")])
    check l.problems.len == 0
    let a = PValue(kind: pvkTuple, typeName: "Tuple", members: @[
      PMember(value: num("1.0")), PMember(value: num("2.0"))])
    let b = PValue(kind: pvkTuple, typeName: "Tuple", members: @[
      PMember(value: num("1.2")), PMember(value: num("2.0"))])
    var sel: DiffSelection
    check selectDiff(l, a, sel)
    let c = compareValues(a, b, sel, true)
    check c.verdict == cvEqual
    check c.algorithm == "numeric-tolerance 0.5"
    # A three-member tuple does not have the shape.
    let three = PValue(kind: pvkTuple, typeName: "Tuple", members: a.members &
                       @[PMember(value: num("3"))])
    check not selectDiff(l, three, sel)

suite "the scratchpad runs the project's own comparison":

  proc admitted(bytes: string; ledger: var ProjectTrustLedger):
      ExecutableDefinition =
    let digest = "sha256:test-" & $bytes.len
    discard ledger.grant("fs2:1:2:3", dfkDiffCode, digest,
                         "2026-11-20T00:00:00Z", "/checkout")
    let a = admitExecutable(dfkDiffCode, ".codetracer/diff.wasm", digest,
                            bytes, admit(ledger, "fs2:1:2:3", dfkDiffCode,
                                         digest), "fs2:1:2:3")
    check a.ok
    a.definition

  test "a granted comparison decides":
    var ledger: ProjectTrustLedger
    let d = admitted(byteEqualityDiffModule(), ledger)
    let same = compareWithDefinition(d, ledger, num("1"), num("1"))
    check same.verdict == cvEqual
    check same.algorithm == "project code (.codetracer/diff.wasm)"
    let other = compareWithDefinition(d, ledger, num("1"), num("2"))
    check other.verdict == cvDifferent

  test "a comparison that never stops is bounded and named":
    var ledger: ProjectTrustLedger
    let d = admitted(nonTerminatingModule(), ledger)
    let c = compareWithDefinition(d, ledger, num("1"), num("1"))
    check c.verdict == cvEqual       # the structural answer
    check c.algorithm == "structural"
    check c.note.contains(".codetracer/diff.wasm#ct_diff")

  test "a revoked comparison does not run":
    var ledger: ProjectTrustLedger
    let d = admitted(byteEqualityDiffModule(), ledger)
    discard ledger.revoke("fs2:1:2:3", dfkDiffCode, "2026-11-20T00:00:01Z",
                          "/checkout")
    let c = compareWithDefinition(d, ledger, num("1"), num("2"))
    check c.verdict == cvDifferent   # structural
    check c.algorithm == "structural"
    check c.note.contains("NOT run")
