## AN EDIT MUST MAKE THE CONSTRAINTS PANE SAY ITS COUNT IS STALE.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_constraints_stale_on_edit.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_constraints_stale_on_edit.nim
##
## ## The defect
##
## `constraints_vm.markStale` and the `(stale)` suffix `headlineFor` appends
## for it were implemented, documented and GREEN, and `markStale` had ZERO CALL
## SITES tree-wide. So the pane never labelled anything: it showed the bundle's
## counts, or the last compile's, beside sources the visitor had since
## rewritten, with nothing to say so. The pane's own header argues that an
## unlabelled stale count is worse than no count at all, because the reader
## cannot tell which they are looking at — and that was the pane's behaviour,
## not the behaviour it avoided.
##
## ## Why the checks are shaped the way they are
##
## **They do NOT spy on `markStale`.** A spy on the function under test is a
## relational blind spot: it moves with the thing it measures, so it stays
## green if `markStale` is called from somewhere that no longer reaches the
## pane, and it says nothing about whether a reader would see anything. These
## checks start from an edit and end at PAINTED TEXT.
##
## **They do NOT set `report.stale` themselves.** That is exactly how the
## existing `ns9_constraints_staleness_is_labelled…` case stayed green over
## a pane with no caller: it assigns the flag and checks the suffix, which
## covers `headlineFor` and cannot cover a trigger that is absent.
##
## **They print the headline before and after and assert the two differ**, so a
## pane that always said `(stale)` would fail as loudly as one that never did.
##
## The one seam these cannot cross is Monaco itself. `noteSourceEdited` is
## reached from `ui/constraints.noteEditorSourceChanged`, which `ui_js`
## installs into `ui/editor.editorSourceChangedHook`, which
## `initMonacoForEditor` fires from `onDidChangeContent` — three `when
## defined(js)` renderer modules no headless lane can load. What is asserted
## here is everything from the hook's payload inward; the browser half is held
## by the renderer lanes compiling those three modules together.

import std/[strutils, tables, unittest]

import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

import ../../../../common/noir_constraints
import ../../viewmodels/constraints_vm
import ../../views/isonim_constraints_view

# ---------------------------------------------------------------------------
# A counted `check` — Verification-Harness-Traps.md §4c.
# ---------------------------------------------------------------------------

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

template startCount() =
  asserted = 0

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

# ---------------------------------------------------------------------------
# Reading the painted pane
# ---------------------------------------------------------------------------

proc findAllByClass(node: MockNode; className: string;
                    acc: var seq[MockNode]) =
  if node.kind == mnkElement and
      className in node.attributes.getOrDefault("class", ""):
    acc.add(node)
  for child in node.children:
    findAllByClass(child, className, acc)

proc allByClass(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

proc collectText(node: MockNode; acc: var string) =
  if node.kind == mnkText:
    acc.add node.text
  for child in node.children:
    collectText(child, acc)

proc textOf(node: MockNode): string =
  collectText(node, result)

proc paneText(panel: MockNode; className: string): string =
  let nodes = allByClass(panel, className)
  if nodes.len == 0: "" else: textOf(nodes[0]).strip()

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const NargoInfoTemplate = """{"programs":[{"package_name":"hello_noir","functions":[{"name":"main","opcodes":17}],"unconstrained_functions":[{"name":"directive_invert","opcodes":9},{"name":"directive_integer_quotient","opcodes":8}]}]}"""
  ## The exact stdout of `nargo info --json` over the bundled template — the
  ## same fixture `test_ns9_panes_vm` uses, and the same numbers the pane shows
  ## a visitor on their first screen.

proc paneWithCounts(vm: ConstraintsVM) =
  vm.setReport(parseNargoInfoJson(NargoInfoTemplate,
                                  "shipped with this bundle"))

# ---------------------------------------------------------------------------

suite "the Constraints pane marks a count stale when the sources move":

  test "editing a .nr source relabels the headline the visitor is looking at":
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      # BEFORE THE EDIT, by value. These are the counts and this is the
      # sentence; both are asserted so the comparison below is between two
      # known strings rather than between two unknowns.
      let before = paneText(panel, "constraints-headline")
      ck before == "17 ACIR opcodes, 17 unconstrained"

      # THE EDIT. This is the hook's payload, delivered the way
      # `ui/constraints.noteEditorSourceChanged` delivers it — a path, from the
      # editor, for a file the visitor just typed into.
      vm.noteSourceEdited("src/main.nr")

      let after = paneText(panel, "constraints-headline")
      ck after != before
      ck after == "17 ACIR opcodes, 17 unconstrained (stale)"

      # The counts are KEPT, not cleared. Decision 2: the last number the
      # project actually had is still the best answer available, and the label
      # is what makes keeping it honest.
      ck allByClass(panel, "constraints-row").len == 3
      ck paneText(panel, "constraints-body").contains("17")

      dispose()
    expectCount(5)

  test "a second keystroke does not re-announce what is already stale":
    ## `markStale`'s idempotence, observed at the pane rather than counted at
    ## the call. A headline that grew a second `(stale)` would be the visible
    ## form of a signal written on every keystroke.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      for _ in 0 ..< 5:
        vm.noteSourceEdited("src/main.nr")

      let headline = paneText(panel, "constraints-headline")
      ck headline == "17 ACIR opcodes, 17 unconstrained (stale)"
      ck headline.count("(stale)") == 1

      dispose()
    expectCount(2)

  test "editing a file that cannot change the circuit leaves the count alone":
    ## Decision 1. A label that appears when nothing is wrong is one a reader
    ## learns to skip, which costs the credibility the whole mechanism is for.
    ## `Prover.toml` is the interesting case: it is a real project file that a
    ## visitor really edits, and it carries witness INPUTS — what a proof is
    ## about, not how big it is.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)
      let before = paneText(panel, "constraints-headline")

      for path in ["README.md", "Prover.toml", "notes.txt", ".gitignore"]:
        vm.noteSourceEdited(path)
        ck paneText(panel, "constraints-headline") == before

      # And the rule itself, stated directly, so a reader of the suite can see
      # which side of the line each name falls on.
      ck editInvalidatesCounts("src/main.nr")
      ck editInvalidatesCounts("Nargo.toml")
      ck editInvalidatesCounts("crates/foo/Nargo.toml")
      ck editInvalidatesCounts("SRC/MAIN.NR")          # case-insensitive
      ck not editInvalidatesCounts("Prover.toml")
      ck not editInvalidatesCounts("README.md")
      # Not a substring match: a file merely NAMED after the manifest is not it.
      ck not editInvalidatesCounts("Nargo.toml.bak")

      dispose()
    expectCount(11)

  test "editing the manifest is an edit to the circuit's dependency set":
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)
      let before = paneText(panel, "constraints-headline")

      vm.noteSourceEdited("Nargo.toml")

      let after = paneText(panel, "constraints-headline")
      ck after != before
      ck after.endsWith("(stale)")

      dispose()
    expectCount(2)

  test "a new report clears the mark, and only a new report does":
    ## Decision 3, as painted text. While a recompile is in flight the numbers
    ## on screen still describe the superseded sources, so the label must
    ## survive until something replaces them — clearing at dispatch would show
    ## an unlabelled stale count for exactly the seconds a compile takes.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      vm.noteSourceEdited("src/main.nr")
      ck paneText(panel, "constraints-headline").endsWith("(stale)")

      # More edits while a compile is imagined to be running: still stale.
      vm.noteSourceEdited("src/main.nr")
      ck paneText(panel, "constraints-headline").endsWith("(stale)")

      # THE COMPILE LANDS. `setReport` writes a report whose `stale` is false,
      # which is the only thing in the product that unsets the mark.
      vm.setReport(parseNargoInfoJson(NargoInfoTemplate,
                                      "compiled in this tab at 12:00:00"))
      let cleared = paneText(panel, "constraints-headline")
      ck cleared == "17 ACIR opcodes, 17 unconstrained"
      ck not cleared.contains("stale")
      # And the pane says which compile it now describes.
      ck paneText(panel, "constraints-provenance") ==
        "compiled in this tab at 12:00:00"

      # A fresh edit after the fresh report marks it again — the mechanism is
      # not one-shot.
      vm.noteSourceEdited("src/main.nr")
      ck paneText(panel, "constraints-headline").endsWith("(stale)")

      dispose()
    expectCount(6)

  test "an absent report cannot become a stale one":
    ## "There are no counts" cannot turn into "the counts are old". The pane
    ## must keep stating the absence, in full, rather than appending a suffix
    ## to it.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      vm.setAbsence("This build's Noir compiler does not report a " &
                    "constraint listing.")

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)
      let before = paneText(panel, "constraints-headline")
      ck before == "unavailable"

      vm.noteSourceEdited("src/main.nr")

      ck paneText(panel, "constraints-headline") == before
      ck not paneText(panel, "constraints-headline").contains("stale")
      # The absence itself is untouched and still the pane's whole content.
      ck paneText(panel, "constraints-absence").contains(
        "does not report a constraint listing")

      dispose()
    expectCount(4)

  test "the dimming and the label agree about which state the pane is in":
    ## The class exists so CSS can dim the rows; the label is what a reader
    ## without CSS gets. Asserted TOGETHER, because a pane that dimmed without
    ## labelling would be a change nobody can name, and one that labelled
    ## without dimming leaves a column of confident numbers at full contrast.
    ##
    ## Note which of the two is the evidence: the headline TEXT is checked by
    ## value, and the class is checked only for agreeing with it.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = createConstraintsVM()
      paneWithCounts(vm)

      let r = MockRenderer()
      let panel = renderConstraintsPanel(r, vm)

      ck not paneText(panel, "constraints-headline").contains("(stale)")
      ck allByClass(panel, "stale").len == 0

      vm.noteSourceEdited("src/main.nr")

      ck paneText(panel, "constraints-headline").contains("(stale)")
      ck allByClass(panel, "stale").len == 1

      dispose()
    expectCount(4)
