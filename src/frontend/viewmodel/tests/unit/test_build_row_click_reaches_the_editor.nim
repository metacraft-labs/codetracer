## test_build_row_click_reaches_the_editor.nim
##
## A BUILD diagnostic row is CLICKED, and the jump it promises is observed.
##
## ## Why this file exists, and why the two tests that already cover this
## ## class cannot
##
## `build-clickable` was a dead affordance. The Karax→IsoNim migration
## (commit `20e24939`) dropped the click handler and left `lineClass` still
## emitting the class and `status_bar.styl:106` still giving it
## `cursor: pointer` with a hover underline. For that whole period a
## diagnostic row looked clickable, invited the click, and did nothing.
## Commit `4c25190e` restored the handler on `cloud`; **on `dev` the rows are
## still dead today**, which is the divergence this file is also a statement
## about.
##
## The suite that was supposed to be watching is
## `src/tests/gui/tests/build/real-compiler-errors.spec.ts`. It has two tests
## over this exact class:
##
##     const clickableLines = ctPage.locator("#build .build-clickable");
##     expect(await clickableLines.count()).toBe(2);
##
## at line 688, and the same shape at line 307. Neither ever calls `.click()`
## — grep the file: the only `.click()` calls in it are on the Problems pane's
## filter buttons. **Both were green for the entire period the affordance was
## dead**, because both assert that a CSS class is PRESENT. That is the
## defect shape this campaign keeps meeting, arriving inside the test written
## to prevent it: presence is not reachability.
##
## So the assertions here drive the path. They render the real view with the
## real `BuildVM`, locate the row by the class a user's cursor is over, fire
## the click that a user's mouse fires, and observe the effect at the seam
## where the pane hands off to the editor — `BuildVM.onJumpToLine`, which
## `ui/build.nim:installBuildVMJumpCallback` fills with
## `data.openLocation(path, line)`.
##
## ## Why the callback and not the editor itself
##
## `data.openLocation` lives in `renderer.nim` and reaches Monaco, `utils.openTab`
## and the GoldenLayout container. `ui/*` cannot be imported into a headless
## suite at all — `frontend/tests/scratchpad_add_dispatch_test.nim:29` records
## the same constraint for `ui/scratchpad`: "cannot be imported into a plain
## node test (it pulls in the Karax/DOM `ui_imports` tree)". The seam is
## therefore the furthest point a headless test can observe, and it is the
## right one: every link past it is shared with Find in Files
## (`search_results.installSearchVMCallbacks`) and the Problems pane
## (`errors.installErrorsVMCallbacks`), both of which call the same
## `data.openLocation`. What was broken was never that shared tail. It was
## this pane having nothing attached to the row at all.
##
## ## The negative twin
##
## A row with no parsed location must NOT be clickable, or "clicking a row
## jumps" would be satisfied by a view that made every line of build output a
## jump target — including `   |` and the source-quote lines, which point
## nowhere. Both directions are pinned below.
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[unittest, tables, strutils]

import isonim/core/owner
import isonim/testing/mock_dom

import ../../store/types as store_types
import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../viewmodels/build_vm
import ../../views/isonim_build_view

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
# Node walking
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

proc newVM(): BuildVM =
  let backend = newMockBackendService().toBackendService()
  createBuildVM(createReplayDataStore(backend))

proc located(text, path: string; line: int;
             severity: BuildLineSeverity = blsError): BuildOutputLine =
  BuildOutputLine(htmlText: text, isStdout: false, severity: severity,
                  locationPath: path, locationLine: line)

proc plain(text: string): BuildOutputLine =
  BuildOutputLine(htmlText: text, isStdout: false, severity: blsNone,
                  locationPath: "", locationLine: 0)

# ---------------------------------------------------------------------------

suite "a BUILD diagnostic row is a place the caret can go":

  test "clicking a build-clickable row asks the editor for its location":
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = newVM()

      # THE SEAM, recorded rather than asserted inline, so the test can state
      # that the callback fired EXACTLY once. A handler wired twice — the
      # ordinary consequence of a render effect that re-attaches without
      # clearing — opens the tab, scrolls it, and opens it again; that is a
      # different defect with the same green "it jumped".
      var calls: seq[(string, int)] = @[]
      vm.onJumpToLine = proc(path: string; line: int) =
        calls.add((path, line))

      vm.appendLine(located("src/main.nr:1:9: warning: unused variable x",
                            "src/main.nr", 9, blsWarning))

      let r = MockRenderer()
      let panel = renderBuildPanel(r, vm)

      # Located by the class the USER's cursor is over. `status_bar.styl:106`
      # gives `.build-clickable` `cursor: pointer` and a hover underline, so
      # this class IS the promise being tested.
      let rows = allByClass(panel, "build-clickable")
      ck rows.len == 1

      # Nothing has been clicked yet. Without this the assertion below would
      # be green over a view that called `onJumpToLine` during render.
      ck calls.len == 0

      rows[0].fireEvent("click")

      ck calls.len == 1
      # Guarded, so the dead-affordance state FAILS with the sentence that
      # names it rather than with an IndexDefect three frames down. Measured:
      # with the handler removed this reported `calls.len was 0` and then
      # crashed the suite on `calls[0]`, which loses the two field assertions
      # below and the two cases after it.
      if calls.len == 1:
        ck calls[0][0] == "src/main.nr"
        ck calls[0][1] == 9
      else:
        checkpoint("the row carries `build-clickable` and no click handler — " &
                   "the affordance is dead, which is the state `dev` is in")
        ck false
        ck false

      dispose()
    expectCount(5)

  test "a row with no location is not clickable and clicking it jumps nowhere":
    ## The twin. Build output is mostly NOT diagnostics — `   |`, the quoted
    ## source line, the caret rule — and a view that made every line a jump
    ## target would satisfy the test above while sending a user to line 0 of
    ## nothing.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      var calls = 0
      vm.onJumpToLine = proc(path: string; line: int) = inc calls

      vm.appendLine(plain("   |"))
      vm.appendLine(plain(" 3 |     let b: bool = a;"))

      let r = MockRenderer()
      let panel = renderBuildPanel(r, vm)

      ck allByClass(panel, "build-clickable").len == 0

      # Fired anyway, on the node the row DID get, because "no class" and "no
      # handler" are two different claims and only the second one protects the
      # editor from being sent to line 0.
      let stderrRows = allByClass(panel, "build-stderr")
      ck stderrRows.len == 2
      for row in stderrRows:
        row.fireEvent("click")
      ck calls == 0

      dispose()
    expectCount(3)

  test "the severity a scanner recovered survives all the way onto the row":
    ## Ties this file to the defect one layer up. `ui/build.nim` now drives
    ## `BuildLocationScanner`, which carries `nargo`'s keyword down from the
    ## line above onto the location line; before that every Noir diagnostic
    ## arrived here as `blsError`. The view is what turns that into the colour
    ## a user sees, so a warning must reach `build-line-warning` and an error
    ## `build-line-error` — pinned in both directions, since a view that
    ## called everything a warning would pass a one-sided check.
    startCount()
    createRoot proc(dispose: proc()) =
      let vm = newVM()
      vm.appendLine(located("unused variable x", "src/main.nr", 1, blsWarning))
      vm.appendLine(located("Expected type bool, found type Field",
                            "src/main.nr", 3, blsError))

      let r = MockRenderer()
      let panel = renderBuildPanel(r, vm)

      ck allByClass(panel, "build-clickable").len == 2
      ck allByClass(panel, "build-line-warning").len == 1
      ck allByClass(panel, "build-line-error").len == 1

      dispose()
    expectCount(3)
