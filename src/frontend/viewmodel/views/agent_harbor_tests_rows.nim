## views/agent_harbor_tests_rows.nim
##
## The adapter from the Agent Harbor Tests panel's cells to the Test Results
## pane's look: one mark table, the pane's.
##
## The Tests panel is the Test Results pane in its Agent Harbor mode, with a
## platform dimension added: each test is a row, as in the pane, and each
## platform a cell of that row. A cell's status (nim-agents' `CellStatus`) is
## mapped here to the pane's own row state (`TestResultsRowState`), so its
## mark is the pane's `stateMark` and its class the pane's `stateClass`
## (`isonim_test_results_view`), never a copied table: a reader who knows the
## pane reads the same `✓ ✗ – ! × … ·` in both, and a change to the pane's
## marks moves both.
##
## The states the pane has no member for are a modifier on the nearest one:
## `queued` is the pane's `not-run` with the modifier `queued` (nothing has
## run, and the platform's run has not started), and a reused pass is the
## pane's `passed` with the modifier `reused` (it passed; a certificate, not
## a run, says so).
##
## The open control's modes are the pane's too: their names
## (`open-existing`, `refresh-and-open`, `record-and-open`) are the values
## the pane's stylesheet draws its marks from (`data-ct-open-mode`,
## `ns9_panes.styl`), and its glyphs the pane's (`⏵`, `⟳⏵`, `⏺⏵`).
##
## It renders nothing, so the GPUI and terminal Tests views read the same
## table (the P3 words-module pattern); the pane's view it takes the class
## from is renderer-generic.

import nim_agents/agent_harbor/test_runs
from ../viewmodels/test_results_vm import TestResultsRowState, stateMark
from ./isonim_test_results_view import stateClass

export TestResultsRowState, stateMark, stateClass

const
  CellClass* = "ah-tests-cell"
    ## The web class of every platform cell, before its state.
  QueuedModifier* = "queued"
    ## The modifier a queued cell carries on the pane's `not-run`.
  ReusedModifier* = "reused"
    ## The modifier a reused pass carries on the pane's `passed`.
  OpenGlyphs*: array[OpenModeKind, string] = ["\xE2\x8F\xB5",
                                              "\xE2\x9F\xB3\xE2\x8F\xB5",
                                              "\xE2\x8F\xBA\xE2\x8F\xB5"]
    ## The open control's glyph per mode (`⏵`, `⟳⏵`, `⏺⏵`): the Test Results
    ## pane's `openButtonMark`, in its mode's order (`OpenModeKind`).

proc rowStateOf*(status: CellStatus): TestResultsRowState =
  ## The Test Results pane's row state of a cell's status: the pane's own
  ## member, or the nearest (`queued` is `not-run`).
  case status
  of tsNotRun, tsQueued: trsNotRun
  of tsRunning: trsRunning
  of tsPassed: trsPassed
  of tsFailed: trsFailed
  of tsSkipped: trsSkipped
  of tsErrored: trsErrored
  of tsCancelled: trsCancelled

proc cellMark*(status: CellStatus): string =
  ## The pane's mark of a cell's status (`stateMark`).
  stateMark(rowStateOf(status))

proc cellModifier*(cell: TestCell): string =
  ## The modifier a cell carries on the pane's state: `queued`, `reused`, or
  ## "" for none.
  if cell.status == tsQueued: QueuedModifier
  elif cell.status == tsPassed and cell.reused: ReusedModifier
  else: ""

proc cellClass*(cell: TestCell): string =
  ## A platform cell's web class: `ah-tests-cell <pane state>`, with its
  ## modifier (`ah-tests-cell not-run queued`).
  result = CellClass & " " & $rowStateOf(cell.status)
  let m = cell.cellModifier
  if m.len > 0: result.add " " & m

proc rowClass*(status: CellStatus): string =
  ## A test row's web class: the pane's own row class for its state
  ## (`isonim_test_results_view.stateClass`: `test-results-row <state>`),
  ## so the pane's mark colours apply to the row's mark.
  stateClass(rowStateOf(status))

proc openGlyph*(mode: OpenModeKind): string =
  ## The open control's glyph in `mode`.
  OpenGlyphs[mode]

proc statusRole*(status: CellStatus): string =
  ## The design-system role a status word is drawn in, as the pane's marks
  ## are coloured: passed green, failed and errored red, running blue,
  ## every other state quiet.
  case status
  of tsPassed: "success"
  of tsFailed, tsErrored: "error"
  of tsRunning: "info"
  else: "quiet"
