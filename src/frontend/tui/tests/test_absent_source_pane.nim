## test_absent_source_pane.nim — **a file the recording does not hold is
## SAID to be missing, by name, and is not drawn as rows that never load.**
##
## When the source provider answers `sfsPathUnavailable` (§14's `savAbsent`)
## the terminal's editor used to draw every visible line as `⋯ loading` under
## "No verified source for this revision — showing what is available." — a
## promise of text that will never arrive, and no word of which file was
## missing. The pane now draws no rows for an absent file and prints
## `editor_surface.absentSourceMessageFor(path)` instead, WRAPPED over the
## free rows so a narrow pane still shows the path's tail (the file's name).
##
## The real-stack half is `real_terminal/test_stop_path_parent_component.nim`
## ("a stop in a file the recording lacks says so, naming the path"). This one
## paints the pane directly so the narrow-pane wrap and the ordinary-loading
## control are asserted at widths a 200-column terminal never reaches.
##
## No mocks: the product's own pane painter, over a real styled grid.

import std/[strutils, unittest]

import ../../view_vocabulary/editor_surface
import ../app/views/source_pane
import ../app/views/gutter
import ../app/views/styled_row

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 7

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  MissingPath = "/home/u/project/app/../shared/helpers.py"
  Width = 36
  Height = 8

proc painted(model: SourcePaneModel): (StyledGrid, SourcePaneScreen) =
  var g = newStyledGrid(Width, Height)
  let screen = paintSourcePane(g, CellArea(col: 0, row: 0, width: Width,
                                           height: Height), model)
  (g, screen)

proc allText(g: StyledGrid): string =
  for r in 0 ..< Height:
    result.add g.rowText(r).strip(leading = false)

suite "an absent source file, in the terminal's editor":

  test "the message names the file, wrapped whole over a narrow pane":
    let message = absentSourceMessageFor(MissingPath)
    ck message.contains(MissingPath)
    ck message.len > Width   # the narrow pane really has to wrap it
    let (g, screen) = painted(initSourcePaneModel(
      path = MissingPath, provenance = gpAbsent, viewportTop = 1,
      executionLine = 4, degradedMessage = message))
    ck screen.loadingLines == 0
    ck not g.allText.contains(SourceLoadingText)
    # Every character of the message is on screen, in order: rejoined from the
    # rows it was wrapped over, it is the message.
    ck g.allText.replace(" ", "").contains(message.replace(" ", ""))

  test "a file that IS on its way still draws its unheld lines as loading":
    # The control: the absent rule must not swallow ordinary loading.
    let (g, screen) = painted(initSourcePaneModel(
      path = MissingPath, provenance = gpVerified, viewportTop = 1))
    ck screen.loadingLines > 0
    ck g.allText.contains(SourceLoadingText)

  test "the assertion count matches the declared constant":
    check countedAssertions == ExpectedAssertions
