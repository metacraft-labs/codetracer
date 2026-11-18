## test_plat62_constraints.nim — the Constraints pane's shared pieces, which
## the desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `Planned-Features/Noir-Studio.md` § "The Constraints pane on the
## terminal and the GPUI window (PLAT-62)".
##
## Asserted, over the PLAT-62 crate (`tui/tests/fixtures/plat62_noir_circuit`
## — its real sources and what the pinned `nargo info --json` printed for it):
##
##   * WHERE A FUNCTION IS DECLARED (`noirFunctionDeclarations`): every `fn`
##     with its line and column, a `#[test]` marked, a commented-out `fn` and
##     a function TYPE not declarations;
##   * THE LINK RULES (`linkFunction`): a name declared once is placed on its
##     line; a compiler directive, a name nobody declares, a name declared
##     twice and a listing's `func N` are placed nowhere, each with its
##     reason; `main` declared twice is the crate root's; a test of the same
##     name is not the function;
##   * THE ROWS (`ConstraintsVM.rows`): the crate's four rows in the report's
##     order, each name, kind, count and place; a listing's opcodes under their
##     function, placed nowhere; no sources read yet says so;
##   * THE SELECTION AND THE KEYS (`selectRow`, `moveSelection`);
##   * ACTIVATION (`activateRow`): the host asked to open the declaring line;
##     a row placed nowhere opens nothing and says why; a window with no host
##     says it cannot open files;
##   * THE ROW MENU (`rowMenu` / `runRowMenu`): Go to Source, Copy Name and
##     Copy Source Location, disabled with the row's reason where they cannot
##     act, and what each does;
##   * THE MEASUREMENT RULE (`constraintsAnswer`): no folder, not a crate, no
##     `nargo`, a failed run (with and without its error text), unreadable
##     output, and a report;
##   * THE COLUMNS (`constraintsFit`);
##   * THE DESKTOP'S VIEW draws exactly `rows`: each row's `data-ct-row`, its
##     words, its place, its title, `linked` and `selected`, and a press on a
##     row opens its source.
##
## NO MOCKS of anything under test. The ViewModel runs for real over the real
## crate's sources and the real `nargo` output for them (the native suites run
## `nargo` itself and assert it prints exactly this). Two stand-ins, and why
## neither is a mock:
##   * the host's `onOpenSource` is a closure that records what it was asked
##     to open — the unit under test is WHICH file and line a row leads to,
##     and opening it is each front-end's editor, asserted by the `tui`,
##     `tui-real-terminal` and `gpui-shell` suites against the real editors;
##   * the desktop's view is rendered with IsoNim's headless DOM
##     (`MockRenderer`), the renderer the view is written against without a
##     browser; the browser half is the Electron capture
##     (`just plat62-capture-electron`).

import std/[strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../viewmodels/constraints_vm
import ../../viewmodels/constraints_answer
import ../../viewmodels/table_fit
from ../../viewmodels/no_project_folder import NoProjectFolderText
import ../../views/isonim_constraints_view
import ../../../../ct_test/frameworks/noir_test_syntax
import ../../../tui/tests/fixtures/plat62_noir_circuit

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 114
  ## Measured: every `ck` below, counted, so a case that silently stops
  ## asserting is caught.

proc crateSources(): seq[NoirSourceFile] =
  for (path, content) in Plat62Files:
    result.add NoirSourceFile(path: path, content: content)

proc measured(): ConstraintReport =
  parseNargoInfoJson(Plat62NargoInfoJson, NargoInfoProvenance)

proc fn(name: string; kind = cfkUnconstrained): ConstraintFunction =
  ConstraintFunction(name: name, kind: kind, opcodes: 1)

proc walk(node: MockNode; acc: var seq[MockNode]) =
  if node.kind == mnkElement and node.attributes.hasKey("data-ct-row"):
    acc.add node
  for child in node.children:
    walk(child, acc)

proc rowsOf(panel: MockNode): seq[MockNode] =
  walk(panel, result)

proc partText(node: MockNode; className: string): string =
  for child in node.children:
    if child.kind == mnkElement and
       className in child.attributes.getOrDefault("class", ""):
      return child.textContent.strip()
  ""

suite "PLAT-62: the Constraints pane's shared model":

  test "where each function is declared":
    let decls = noirFunctionDeclarations(crateSources())
    var seen: seq[string] = @[]
    for d in decls:
      seen.add d.name & "@" & d.path & ":" & $d.line & ":" & $d.column &
               (if d.isTest: ":test" else: "") &
               (if d.unconstrained: ":unconstrained" else: "")
    ck seen == @["main@src/main.nr:3:1", "halve@src/main.nr:11:15:unconstrained",
                 "test_main@src/main.nr:16:1:test",
                 "in_range@src/checks.nr:1:5"]
    let tricky = noirFunctionDeclarationsRelative("src/lib.nr",
      "// fn commented() {}\nfn apply(f: fn(Field) -> Field) {}\n" &
      "    #[test]\n    fn t() {}\n")
    ck tricky.len == 2
    ck tricky[0].name == "apply" and tricky[0].line == 2
    ck tricky[1].name == "t" and tricky[1].isTest and tricky[1].line == 4

  test "the link rules: placed once, refused otherwise":
    let decls = noirFunctionDeclarations(crateSources())
    let main = linkFunction(fn("main", cfkAcir), decls)
    ck main.linked and main.path == "src/main.nr" and
       main.line == Plat62MainLine and main.column == 1
    let halve = linkFunction(fn("halve"), decls)
    ck halve.linked and halve.line == Plat62HalveLine
    let directive = linkFunction(fn("directive_invert"), decls)
    ck not directive.linked and directive.reason == DirectiveReason
    let unknown = linkFunction(fn("vanished"), decls)
    ck not unknown.linked
    ck unknown.reason == "no function named vanished is declared in this " &
                         "project's sources"
    let numbered = linkFunction(fn("func 0", cfkAcir), decls)
    ck not numbered.linked and numbered.reason == NumberedCircuitReason
    # The test `test_main` is not a function a program names.
    ck not linkFunction(fn("test_main"), decls).linked
    # Twice: placed nowhere, with the count; `main` twice is the crate root's.
    let twice = noirFunctionDeclarations(crateSources() & @[
      NoirSourceFile(path: "src/other.nr",
                     content: "fn halve(v: Field) -> Field { v }\n" &
                              "fn main() {}\n")])
    let ambiguous = linkFunction(fn("halve"), twice)
    ck not ambiguous.linked
    ck ambiguous.reason == "2 functions in this project are named halve, " &
                           "and the report does not say which one this is"
    let root = linkFunction(fn("main", cfkAcir), twice)
    ck root.linked and root.path == "src/main.nr" and root.line == 3
    # Sources outside `src/` are not compiled, so they declare nothing.
    ck noirFunctionDeclarations(@[NoirSourceFile(path: "tests/x.nr",
                                                 content: "fn main() {}")]).len == 0

  test "the rows: the crate's four, in the report's order, each placed or not":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setSources(crateSources())
      vm.setReport(measured())
      ck vm.headline.val == Plat62Headline
      let rows = vm.rows.val
      ck rows.len == Plat62Rows.len
      for i, (name, kind, count, where) in Plat62Rows:
        ck rows[i].kind == crkFunction
        ck rows[i].function == i and rows[i].opcode == -1
        ck (rows[i].name, rows[i].kindLabel, rows[i].count,
            whereText(rows[i].source)) == (name, kind, count, where)
      ck rowTitle(rows[0]) == "Go to src/main.nr:3"
      ck rowTitle(rows[2]) == "No source: " & DirectiveReason
      ck rowText(rows[1]) == "halve"
      dispose()

  test "no sources read: every row says so":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setReport(measured())
      ck vm.rows.val.len == 4
      for row in vm.rows.val:
        ck not row.source.linked and row.source.reason == NoSourcesReason
      dispose()

  test "an absent report has no rows; a listing's opcodes sit under their function":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      ck vm.rows.val.len == 0
      ck vm.headline.val == "unavailable"
      vm.setSources(crateSources())
      vm.setReport(reportFromAcirListing(
        "func 0\nprivate parameters: [w0]\n" &
        "public parameters: [w1]\nreturn values: []\n" &
        "BRILLIG CALL func: 0, inputs: [], outputs: []\nASSERT w0 = w1\n" &
        "unconstrained func 0: halve\n0: CONST R0 = 2\n1: RETURN\n",
        "plat62_circuit", "the listing of this compile"))
      let rows = vm.rows.val
      var kinds: seq[string] = @[]
      for r in rows:
        kinds.add $r.kind & ":" & r.name
      ck kinds == @["function:func 0", "opcode:BRILLIG", "opcode:ASSERT",
                    "function:halve", "opcode:CONST", "opcode:RETURN"]
      ck not rows[0].source.linked and
         rows[0].source.reason == NumberedCircuitReason
      ck rows[1].count == "0" and
         rows[1].args == "CALL func: 0, inputs: [], outputs: []"
      ck not rows[1].source.linked and
         rows[1].source.reason == OpcodeHasNoSourceReason
      ck rows[3].source.linked and whereText(rows[3].source) == "src/main.nr:11"
      ck rowText(rows[2]) == "ASSERT w0 = w1"
      ck rows[4].opcode == 0 and rows[4].function == 1
      ck listingNoticeFor(vm.report.val) == ""
      dispose()

  test "the selection and the list keys":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setSources(crateSources())
      vm.setReport(measured())
      ck vm.selected.val == -1
      ck vm.moveSelection("list.focus-next")
      ck vm.selected.val == 0
      discard vm.moveSelection("list.focus-last")
      ck vm.selected.val == 3
      discard vm.moveSelection("list.focus-next")
      ck vm.selected.val == 3
      discard vm.moveSelection("list.focus-page-up", page = 2)
      ck vm.selected.val == 1
      discard vm.moveSelection("list.focus-first")
      ck vm.selected.val == 0
      ck not vm.moveSelection("list.activate")
      vm.selectRow(2)
      ck vm.selected.val == 2
      vm.selectRow(9)
      ck vm.selected.val == -1
      dispose()

  test "activation opens the declaring line, or says why not":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setSources(crateSources())
      vm.setReport(measured())
      # No host yet.
      let none = vm.activateRow(0)
      ck not none.opened and none.reason == CannotOpenReason
      var asked: seq[string] = @[]
      vm.onOpenSource = proc(path: string; line, column: int) =
        asked.add path & ":" & $line & ":" & $column
      let opened = vm.activateRow(1)
      ck opened.opened and opened.path == "src/main.nr" and
         opened.line == Plat62HalveLine
      ck asked == @["src/main.nr:11:15"]
      ck vm.selected.val == 1
      let refused = vm.activateRow(3)
      ck not refused.opened and refused.reason == DirectiveReason
      ck asked.len == 1
      ck vm.selected.val == 3
      ck vm.activateRow(7).reason == "no such row"
      dispose()

  test "the row menu: its entries, their reasons, what each does":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setSources(crateSources())
      vm.setReport(measured())
      var asked: seq[string] = @[]
      vm.onOpenSource = proc(path: string; line, column: int) =
        asked.add path & ":" & $line
      let linked = vm.rowMenu(0)
      var labels: seq[string] = @[]
      for e in linked:
        labels.add e.label & "=" & $e.enabled
      ck labels == @["Go to Source=true", "Copy Name=true",
                     "Copy Source Location=true"]
      let placedNowhere = vm.rowMenu(2)
      ck not placedNowhere[0].enabled and
         placedNowhere[0].reason == DirectiveReason
      ck placedNowhere[1].enabled
      ck not placedNowhere[2].enabled and
         placedNowhere[2].reason == DirectiveReason
      ck vm.rowMenu(-1).len == 0
      ck vm.runRowMenu(0, cmCopyName).copied == "main"
      ck vm.runRowMenu(1, cmCopySourceLocation).copied == "src/main.nr:11"
      let go = vm.runRowMenu(0, cmGoToSource)
      ck go.done and go.activation.opened and asked == @["src/main.nr:3"]
      let disabled = vm.runRowMenu(2, cmGoToSource)
      ck not disabled.done and asked.len == 1
      ck vm.runRowMenu(3, cmCopyName).copied == "directive_integer_quotient"
      ck vm.selected.val == 3
      dispose()

  test "the measurement rule, arm by arm":
    ck constraintsAnswer("", false, NargoInfoRun()).absence ==
       NoProjectFolderText
    ck constraintsAnswer("/p", false, NargoInfoRun()).absence ==
       NotANoirCrateText
    ck absenceBeforeRun("/p", true) == ""
    ck constraintsAnswer("/p", true,
                         NargoInfoRun(missing: true)).absence ==
       NargoMissingText
    ck constraintsAnswer("/p", true, NargoInfoRun(started: true, exitCode: 1,
         message: "error: cannot find function\n")).absence ==
       NargoFailedStem & "error: cannot find function"
    ck constraintsAnswer("/p", true, NargoInfoRun(started: true,
         exitCode: 2)).absence ==
       NargoFailedStem & "nargo info exited with status 2"
    ck constraintsAnswer("/p", true, NargoInfoRun(started: true,
         output: "not json")).absence.startsWith("nargo info did not produce")
    let ok = constraintsAnswer("/p", true, NargoInfoRun(started: true,
                               output: Plat62NargoInfoJson))
    ck ok.hasReport and ok.absence == ""
    ck ok.report.provenance == NargoInfoProvenance
    ck headlineFor(ok.report) == Plat62Headline

  test "the function row's columns":
    let fit = constraintsFit(26, 13, 2, 14, 80)
    ck fit.mode == fmFit
    ck fit.widths[1] == 13 and fit.widths[2] == 2 and fit.widths[3] == 14
    ck fit.widths[0] == 80 - 13 - 2 - 14 - 3
    let tight = constraintsFit(26, 13, 2, 14, 40)
    ck tight.mode == fmShrink
    ck tight.widths[1] == 13 and tight.widths[2] == 2
    ck tight.widths[0] >= ConstraintNameFloorCells
    ck constraintsFit(26, 13, 2, 14, 20).mode == fmScroll

  test "the desktop's view draws exactly the rows, and a press opens one":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setSources(crateSources())
      vm.setReport(measured())
      var asked: seq[string] = @[]
      vm.onOpenSource = proc(path: string; line, column: int) =
        asked.add path & ":" & $line
      let r = MockRenderer()
      let panel = renderConstraintsPanel[MockRenderer, MockNode](r, vm)
      var drawn = rowsOf(panel)
      ck drawn.len == 4
      for i, (name, kind, count, where) in Plat62Rows:
        ck drawn[i].attributes["data-ct-row"] == $i
        ck (partText(drawn[i], "constraints-name"),
            partText(drawn[i], "constraints-kind"),
            partText(drawn[i], "constraints-count"),
            partText(drawn[i], "constraints-where")) ==
           (name, kind, count, where)
        ck drawn[i].attributes["title"] == rowTitle(vm.rows.val[i])
      ck "linked" in drawn[0].attributes["class"]
      ck "linked" notin drawn[2].attributes["class"]
      ck "selected" notin drawn[0].attributes["class"]
      fireEvent(drawn[1], "click")
      ck asked == @["src/main.nr:11"]
      ck vm.selected.val == 1
      drawn = rowsOf(panel)
      ck "selected" in drawn[1].attributes["class"]
      ck "selected" notin drawn[0].attributes["class"]
      fireEvent(drawn[2], "click")
      ck asked.len == 1 and vm.selected.val == 2
      dispose()

  test "the assertion count":
    check asserted == ExpectedAssertions
