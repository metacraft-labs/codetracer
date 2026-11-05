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

import std/[base64, json, strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../common/raw_inflate

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

const ExpectedAssertions = 159
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

  test "a real listing joins the totals, and each opcode leads to its source":
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      let answer = constraintsAnswer("/p", true, NargoInfoRun(started: true,
                                     output: Plat62InfoOutput))
      ck answer.hasReport and answer.infoJson == Plat62NargoInfoJson
      ck answer.listing == Plat62PrintedListing
      let placed = placeOpcodes(answer.report, plat62Artefact(), crateSources())
      vm.setSources(crateSources())
      vm.setReport(placed)
      let rows = vm.rows.val
      ck rows.len == Plat62RowTotal
      ck vm.headline.val == Plat62Headline
      ck listingNoticeFor(placed) == ""
      # The names are `nargo info`'s and the rows hang under them.
      ck rows[0].name == "main" and rows[0].kind == crkFunction
      ck rows[Plat62HalveRow].name == "halve"
      ck rows[Plat62InvertRow].name == "directive_invert"
      ck rows[Plat62QuotientRow].name == "directive_integer_quotient"
      ck rows[1].name == "BRILLIG" and rows[1].count == "0"
      ck rows[Plat62HalveRow + 13].count == "12"
      var bad = 0
      for (row, where) in Plat62OpcodePlaces:
        if whereText(rows[row].source) != where or rows[row].kind != crkOpcode:
          inc bad
          checkpoint($row & ": " & whereText(rows[row].source) & " vs " & where)
      ck bad == 0
      # A row placed by the debug symbols opens as a function's does: the
      # innermost frame, with its column.
      var asked: seq[string] = @[]
      vm.onOpenSource = proc(path: string; line, column: int) =
        asked.add path & ":" & $line & ":" & $column
      ck vm.activateRow(Plat62RangeOpcodeRow).opened
      ck asked == @["src/checks.nr:" & $Plat62RangeLine & ":12"]
      ck rowTitle(rows[Plat62RangeOpcodeRow]) ==
         "Go to src/checks.nr:" & $Plat62RangeLine
      ck vm.rowMenu(Plat62RangeOpcodeRow)[0].enabled
      ck vm.runRowMenu(Plat62RangeOpcodeRow, cmCopySourceLocation).copied ==
         "src/checks.nr:2"
      # An opcode the compiler left without a position says so.
      let bare = rows[Plat62UnlocatedOpcodeRow]
      ck not bare.source.linked and bare.source.reason == OpcodeHasNoSourceReason
      ck not vm.activateRow(Plat62UnlocatedOpcodeRow).opened
      ck not vm.rowMenu(Plat62UnlocatedOpcodeRow)[0].enabled
      dispose()

  test "what refuses a listing or a place, each with its reason":
    let report = measured()
    # A listing that does not add up to the totals: only the totals stand.
    let short = report.attachListing(
      Plat62PrintedListing.replace("ASSERT w10 = 0\n", ""))
    ck not short.hasListing() and short.listingAbsence == ListingDisagreesText
    ck headlineFor(short) == Plat62Headline
    let renamed = report.attachListing(
      Plat62PrintedListing.replace(": halve", ": other"))
    ck renamed.listingAbsence == ListingDisagreesText
    # A workspace prints one listing per package; the report reads the first.
    let workspace = report.attachListing(Plat62PrintedListing &
                                         Plat62PrintedListing)
    ck not workspace.hasListing() and
       workspace.listingAbsence == ListingOfWorkspaceText
    ck report.attachListing("").listingAbsence == NoListingText
    let listed = report.attachListing(Plat62PrintedListing)
    # No artefact, an unreadable one, debug symbols that do not inflate.
    for artefact in ["", "not json", "{\"debug_symbols\":\"AAAA\",\"file_map\":{}}"]:
      let unread = placeOpcodes(listed, artefact, crateSources())
      ck unread.functions[0].rows[0].place.reason == OpcodeNoDebugSymbolsReason
      ck not unread.functions[0].rows[0].place.placed
    # The text on disk moved on from the compile: nothing is placed on it.
    var edited = crateSources()
    edited[0].content = edited[0].content & "\n"
    let moved = placeOpcodes(listed, plat62Artefact(), edited)
    ck moved.functions[0].rows[0].place.reason == OpcodeOutsideProjectReason
    # A dependency's file with the same relative path is not the project's.
    let foreign = placeOpcodes(listed,
      plat62Artefact(mainPath = "/elsewhere/src/other.nr"), crateSources())
    ck foreign.functions[0].rows[0].place.reason == OpcodeOutsideProjectReason
    # A frame in the project behind one outside it is the one opcode leads to.
    let inner = placeOpcodes(listed,
      plat62Artefact(checksPath = "std/checks.nr"), crateSources())
    ck whereText(linkOpcode(inner.functions[0].rows[4].place)) == "src/main.nr:8"

  test "raw deflate: stored, fixed and dynamic blocks; a refusal is a reason":
    # Each block type: stored and fixed are small samples zlib produced, and
    # the debug symbols are a dynamic block.
    ck inflateRaw("\x01\x05\x00\xfa\xffhello").bytes == "hello"
    ck inflateRaw("\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x90\x5c\x00").bytes ==
       "hello hello hello\n"
    let dynamic = decode(Plat62DebugSymbols)
    let inflated = inflateRaw(dynamic)
    ck inflated.ok and inflated.bytes.startsWith("{\"debug_infos\":")
    ck parseJson(inflated.bytes)["debug_infos"].len == 1
    ck not inflateRaw("").ok
    ck not inflateRaw("\x07").ok                        # the reserved block type
    ck not inflateRaw("\x01\x05\x00\x00\x00hello").ok  # a bad complement
    ck not inflateRaw(dynamic[0 ..< dynamic.len div 2]).ok   # truncated
    ck not inflateRaw(dynamic, limit = 16).ok            # past the limit
    # A back-reference alone crossing the limit: "hello h" then a copy of ten.
    ck inflateRaw("\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x90\x00").bytes == "hello hello hello"
    ck not inflateRaw("\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x90\x00", limit = 10).ok

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
