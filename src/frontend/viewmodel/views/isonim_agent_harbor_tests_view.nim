## IsoNim view of an Agent Harbor change's tests: the Test Results pane in
## its Agent Harbor mode over `TestRunsVM` (nim-agents-isonim-viewmodels
## `test_runs_vm`), a MATRIX OF TESTS BY PLATFORMS -- one row per test, one
## cell per platform switched on, the pane's marks in every cell.
##
## Layout, top to bottom:
##
## - the header strip (the Agent Harbor panels' `.ah-fleet-head`): the
##   small-caps label `TESTS`, the session the change is of (the host's
##   context), and `12 tests · 4 platforms` at the right;
## - the run band, on a ground of its own: the Test Results headline (its
##   arms: `running…`, the counts, `run failed, no tests ran`, `12 tests, not
##   run yet`, `no tests found`) and the controls: `Run`, `Record` with its
##   mode (the design system's Dropdown: failing tests, all tests), `Reuse
##   certified results` (the design system's Checkbox) and, while a run is
##   active, `Cancel run`, which asks first (`Cancel the run on 3
##   platforms?`, `Cancel run` / `Keep running`). Under it, in their roles,
##   whatever the run band has to say: a start the source refused (`Not
##   started: …`), a lost event stream (`Lost the run's events;
##   reconnecting…`), a Record waiting behind a Run being sent (`Waiting
##   for the Run on this platform, which is being sent`, study D31), the
##   platforms the header's Record skips and why;
## - the platform strip, on a ground of its own: per offered platform its
##   design-system Switch (in view and in the next run), its label, its
##   recordability mark, the backend that serves its run (a quiet chip) and
##   what its run or its catalog says (`queued on reprobuild`, `running on
##   ah-executors (pytest)`, `5 passed · 1 failed`, `not in this run` for a
##   platform switched on that the shown run does not include, `Discovering
##   tests on macOS arm64…`); its diagnostics under it. The legend (every mark, chip
##   and backend, with its meaning) opens from the strip's end;
## - the search (`Search tests…`) and the status filter (the design system's
##   Dropdown);
## - the matrix: a head naming each platform's column, then the tests by
##   file in the catalog's order, each file a group whose head folds it;
##   each test a row with the pane's mark of its roll-up, its name, the
##   milestones whose Verification entries name it, one cell per platform
##   (the pane's mark and the status word; a reused pass's `reused` chip; a
##   kept trace's open control) and its own Run and Record (icons, each named
##   by what it does: `Run <test> on the platforms switched on`). An opened row
##   shows one sub-row per platform: the backend chip, the runner, the
##   status and duration, `Run`, `Record` and the open control in its three
##   modes (a Record waiting behind a Run being sent says so beside it, or
##   once above the sub-rows when every platform's waits), then the failure (its message and where), the last output lines
##   with their stream, and the platform's diagnostics. The plan's
##   Verification entries no catalog test matches close the list, under
##   their milestone, `not in the catalog`.
##
## At a narrow panel (`sidebar`) each row keeps one mark per platform as a
## strip, each mark's platform in its tooltip and in the legend, and the
## opened row's sub-rows give each platform's words: nothing is hidden.
##
## **Cardless** (`agent_harbor_tests.styl`): no border, box or background
## around a test, a cell or a sub-row; bands and group heads are set apart by
## grounds; an opened row carries the focus inset bar, the selected test the
## selection's raised ground and bar, the keyboard's row and cell a focus
## ring.
##
## **The pane's look.** A cell's mark and class come from the adapter
## (`agent_harbor_tests_rows.nim`): the Test Results pane's `stateMark` and
## `stateClass`, one table. The open control is the pane's
## (`.test-results-open-btn`, its modes in `data-ct-open-mode`).
##
## **Presses** (Input-Routing-And-Keymaps.md §5.1): every element a press
## acts on carries its operation and the procedure that performs it
## (`element_operations.bindOperation`); the view holds no press handler.
## Every write goes through the viewmodel to the data source's
## `submitAction` and nothing else.
##
## Every element a host test reads carries its fact (`data-ah-*`): a row
## (`data-ah-test`, `data-ah-status`), a cell (`data-ah-platform`,
## `data-ah-status`, `data-ah-mark`), a platform head (`data-ah-platform`,
## `data-ah-enabled`, `data-ah-record`), the headline (`data-ah-headline`).

import std/strutils

import isonim/core/[signals, computation]
from isonim/core/batch import untrack
import isonim/dsl/[ui, components]
import ./ah_cut_text

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents/agent_harbor/test_runs
import ./agent_harbor_tests_words
import ./agent_harbor_tests_rows
import ./agent_harbor_dropdown_view
import ../input/element_operations

export signals, computation, components, agent_harbor_tests_words

const
  AgentHarborTestsClass* = "component-container agent-harbor-tests"
  TestsPaneName* = "tests"
    ## The pane's scope name (`data-ct-pane`): what a key pressed in it is
    ## resolved in.

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc setFlag[R, N](r: R; node: N; name: string; on: bool) =
  ## A boolean attribute, present only when `on`.
  mixin setAttribute
  if on: r.setAttribute(node, name, name)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

proc press[R, N](r: R; node: N; operation: string; run: proc()) =
  ## `node` carries `operation`; its press runs `run`.
  let act = run
  r.bindOperation(node, operation, proc(p: PressInfo) = act())

# ---------------------------------------------------------------------------
# Shared parts
# ---------------------------------------------------------------------------

proc renderNotice[R](r: R; message, hint, kind: string): auto =
  ## A centred notice, with the hint that says what would fill the pane.
  ui(r):
    tdiv(class = "empty-overlay ah-tests-notice", `data-ah-notice` = kind):
      tdiv(class = "ah-tests-notice-text"):
        text message
      if hint.len > 0:
        tdiv(class = "ah-tests-notice-hint"):
          text hint

proc renderLine[R](r: R; text, role, kind: string): auto =
  ## One sentence of the run band in its role.
  ui(r):
    tdiv(class = "ah-tests-say ah-role-" & role, `data-ah-say` = kind):
      text text

proc renderChip[R](r: R; text, title, cls: string): auto =
  ui(r):
    span(class = "ah-chip ah-tests-chip " & cls, title = title):
      text text

proc renderButton[R, N](r: R; label, title, cls, operation: string; enabled: bool;
                        run: proc()): N =
  ## A small design-system button carrying `operation`; disabled with its
  ## reason in its tooltip.
  result = ui(r):
    button(class = cls, title = title, `data-ah-control` = label):
      text label
  r.setFlag(result, "disabled", not enabled)
  r.setAttribute(result, "aria-disabled", if enabled: "false" else: "true")
  if enabled: r.press(result, operation, run)

proc renderIconButton[R, N](r: R; kind, name, title, operation: string; enabled: bool;
                            run: proc()): N =
  ## A row's Run (`play`) or Record (`record`), drawn as the pane's marks.
  ## The icon has no text, so `name` (what it does, enabled or not) is its
  ## accessible name, and `title` (that, and why not when it cannot) its
  ## tooltip.
  result = ui(r):
    button(class = "ah-tests-icon-btn ah-tests-icon-" & kind, title = title,
           `aria-label` = name, `data-ah-control` = kind):
      discard
  r.setFlag(result, "disabled", not enabled)
  r.setAttribute(result, "aria-disabled", if enabled: "false" else: "true")
  if enabled: r.press(result, operation, run)

proc renderOpenControl[R, N](r: R; vm: TestRunsVM; testId: string;
                             cell: TestCellView): N =
  ## The Test Results pane's open control in its mode (`⏵`, `⟳⏵`, `⏺⏵`):
  ## its glyph stays its text, drawn as the pane's marks; disabled with the
  ## reason in its tooltip, which otherwise ends with where the trace opens.
  let mode = cell.open
  let enabled = mode.absence.len == 0
  result = ui(r):
    span(class = "test-results-open-btn ah-tests-open" &
                 (if enabled: "" else: " disabled") &
                 (if mode.kind == omRefreshAndOpen: " shift-armed" else: ""),
         role = "button", tabindex = "-1", title = cell.openTitle,
         `aria-label` = cell.openTitle, `data-ct-open-mode` = $mode.kind,
         `data-ah-open` = $mode.kind):
      text openGlyph(mode.kind)
  if enabled:
    let platform = cell.platform
    r.press(result, TestsOpenOperation, proc() = discard vm.open(testId, platform))

proc renderMark[R](r: R; status: CellStatus): auto =
  ui(r):
    span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
      text cellMark(status)

# ---------------------------------------------------------------------------
# The header strip and the run band
# ---------------------------------------------------------------------------

proc renderHead[R](r: R; vm: TestRunsVM; ctx: AgentHarborTestsContext): auto =
  let counts = if vm.state == asReady: vm.countsPhrase else: ""
  ui(r):
    tdiv(class = "ah-fleet-head"):
      tdiv(class = "ah-fleet-section-header"):
        span(class = "ah-fleet-title"):
          text TestsSectionLabel
        span(`data-ah-cut` = "line", class = "ah-fleet-source", title = ctx.sessionLabel):
          text testsContextPhrase(ctx.sessionLabel)
        span(class = "ah-fleet-summary", `data-ah-counts` = counts):
          text counts

proc renderRecordMode[R, N](r: R; vm: TestRunsVM): N =
  ## The header Record's mode: the design system's Dropdown.
  let current = vm.recordMode.val
  var choices: seq[DropdownChoice]
  for m in [rmFailing, rmAll]:
    choices.add DropdownChoice(id: $m, label: RecordModeLabels[m])
  let pick = proc(id: string) =
    for m in [rmFailing, rmAll]:
      if $m == id: vm.setRecordMode(m)
  renderAgentHarborDropdown[R, N](r, RecordModeLabels[current], choices, $current, pick,
    cls = "ah-changes-select ah-tests-record-mode", title = RecordModeTitle)

proc renderCheckbox[R, N](r: R; label, title, operation: string; checked: bool;
                          run: proc()): N =
  ## The design system's Checkbox (`.ct-checkmark`, `checkmark.styl`): its
  ## box and its label, the whole a control carrying `operation`; no native
  ## input.
  result = ui(r):
    span(class = "ct-checkmark-field ah-tests-check", role = "checkbox",
         tabindex = "0", title = title,
         `aria-checked` = (if checked: "true" else: "false"),
         `data-ah-checked` = (if checked: "true" else: "false")):
      span(class = "ct-checkmark", `data-state` = (if checked: "checked" else: "unchecked"),
           `aria-hidden` = "true"):
        discard
      span(class = "ct-checkmark-label"):
        text label
  r.press(result, operation, run)

proc renderSwitch[R, N](r: R; on: bool; title, operation: string; run: proc()): N =
  ## The design system's Switch (`.ct-toggle`, `toggle.styl`), small: its
  ## track and thumb, carrying `operation`; no native input.
  result = ui(r):
    span(class = "ct-toggle ah-tests-switch", `data-size` = "sm",
         `data-checked` = (if on: "true" else: "false"), role = "switch",
         tabindex = "0", title = title, `aria-checked` = (if on: "true" else: "false")):
      span(class = "ct-toggle-thumb"):
        discard
  r.press(result, operation, run)

proc renderRunBand[R, N](r: R; vm: TestRunsVM): N =
  ## The headline and the run's controls, and what the run band says.
  var controls, says: N
  let headline = vm.headline
  result = ui(r):
    tdiv(class = "ah-tests-band ah-tests-run-band"):
      tdiv(class = "ah-tests-run-row"):
        span(`data-ah-cut` = "line", class = "test-results-headline ah-tests-headline ah-role-" &
               vm.headlineRole, title = headline, `data-ah-headline` = headline):
          text headline
        tdiv(ref = controls, class = "ah-tests-controls")
      tdiv(ref = says, class = "ah-tests-says")
  let target = vm
  if vm.confirming.val:
    # The question, in place of the controls: nothing is sent until
    # `Cancel run`.
    let q = ui(r):
      span(class = "ah-tests-confirm-question", `data-ah-confirm` = "cancel"):
        text vm.cancelQuestion
    r.appendRendered(controls, q)
    r.appendRendered(controls, renderButton[R, N](r, CancelRunLabel, CancelRunLabel,
      "ct-button-sm-primary ah-tests-button", TestsConfirmCancelOperation, true,
      proc() = discard target.confirmCancel()))
    r.appendRendered(controls, renderButton[R, N](r, KeepRunningLabel, KeepRunningLabel,
      "ct-button-sm-secondary ah-tests-button", TestsKeepRunningOperation, true,
      proc() = target.keepRunning()))
  else:
    let runWhy = vm.runAllAbsence
    r.appendRendered(controls, renderButton[R, N](r, RunLabel, vm.runAllTitle,
      "ct-button-sm-primary ah-tests-button", TestsRunAllOperation, runWhy.len == 0,
      proc() = discard target.run()))
    let recordWhy = vm.recordAllAbsence
    r.appendRendered(controls, renderButton[R, N](r, RecordLabel, vm.recordAllTitle,
      "ct-button-sm-secondary ah-tests-button", TestsRecordAllOperation, recordWhy.len == 0,
      proc() = discard target.record()))
    r.appendRendered(controls, renderRecordMode[R, N](r, vm))
    let reuse = vm.reuse.val
    r.appendRendered(controls, renderCheckbox[R, N](r, ReuseLabel, ReuseTitle,
      TestsReuseOperation, reuse, proc() = target.setReuse(not reuse)))
    if vm.cancelling:
      let c = ui(r):
        span(class = "ah-tests-cancelling ah-role-quiet", `data-ah-cancelling` = "true"):
          text CancellingText
      r.appendRendered(controls, c)
    elif vm.canCancel:
      r.appendRendered(controls, renderButton[R, N](r, CancelRunLabel, vm.cancelTitle,
        "ct-button-sm-secondary ah-tests-button ah-tests-cancel", TestsCancelOperation, true,
        proc() = target.cancel()))
  let refusal = vm.refusal.val
  if refusal.len > 0:
    r.appendRendered(says, renderLine(r, refusal,
      (if refusal.startsWith(NotStartedPrefix): "error" else: "warning"), "refusal"))
  let lost = vm.streamNotice
  if lost.len > 0:
    let reason = vm.feed.lostReason
    r.appendRendered(says, renderLine(r, lost & (if reason.len > 0: " (" & reason & ")" else: ""),
                                      "warning", "stream-lost"))
  if not vm.confirming.val and vm.recordAllAbsence == RecordWaitsForRunText:
    # The header's Record waits behind the header's Run being sent (D31):
    # said in words under the controls, as the sub-rows say it.
    r.appendRendered(says, renderLine(r, RecordWaitsForRunText, "quiet", "record-waiting"))
  let skips = vm.recordSkipsText
  if skips.len > 0:
    r.appendRendered(says, renderLine(r, skips, "quiet", "record-skips"))

# ---------------------------------------------------------------------------
# The platform strip and the legend
# ---------------------------------------------------------------------------

proc renderPlatformHead[R, N](r: R; vm: TestRunsVM; head: PlatformHeadView): N =
  var line, words: N
  let key = head.key
  let on = head.enabled
  result = ui(r):
    tdiv(class = "ah-tests-platform" & (if on: "" else: " ah-tests-platform-off"),
         title = vm.platformTitle(head)):
      tdiv(ref = line, class = "ah-tests-platform-line")
      tdiv(ref = words, class = "ah-tests-platform-words")
  r.tagFacts(result, [("platform", key), ("enabled", $on),
                      ("record", (if head.recordReason.len > 0: "no" else: "yes"))])
  let target = vm
  r.appendRendered(line, renderSwitch[R, N](r, on, switchTitle(head),
    TestsSwitchPlatformOperation, proc() = target.setPlatform(key, not on)))
  let label = ui(r):
    span(`data-ah-cut` = "line", class = "ah-tests-platform-label", title = head.label):
      text head.label
  r.appendRendered(line, label)
  let mark = ui(r):
    span(class = "ah-tests-record-mark" &
                 (if head.recordReason.len > 0: " ah-tests-record-mark-off" else: ""),
         title = recordMarkTitle(head), `aria-label` = recordMarkTitle(head)):
      text RecordMarkGlyph
  r.appendRendered(line, mark)
  if head.backend.len > 0:
    r.appendRendered(line, renderChip(r, backendLabel(head.backend),
      "The backend that serves this platform's run", "ah-tests-backend"))
  # What the platform's catalog or run says, in its role.
  if head.serveAbsence.len > 0:
    r.appendRendered(words, renderLine(r, head.serveAbsence, "error", "unservable"))
  if head.catalogWord.len > 0:
    let role = if head.catalogWord.startsWith(DiscoveringPrefix): "quiet" else: "error"
    r.appendRendered(words, renderLine(r, head.catalogWord, role, "catalog"))
  let runWord = vm.platformRunWord(head)
  if runWord.len > 0:
    # A run's word is quiet: its failures are the cells' marks. Running is
    # the one state said in its role. A platform switched on that the shown
    # run does not include says `not in this run`: never on and silent.
    let role = if runWord.startsWith("running"): "info" else: "quiet"
    r.appendRendered(words, renderLine(r, runWord, role,
      (if runWord == NotInThisRunText: "not-in-run" else: "run")))
  for d in head.diagnostics:
    r.appendRendered(words, renderLine(r, d.text, diagnosticRole(d.level), "diagnostic"))

proc renderLegend[R, N](r: R; vm: TestRunsVM; open: Signal[bool]): N =
  ## The legend's toggle and, open, every term with its meaning.
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-tests-legend")
  let toggle = ui(r):
    span(class = "ah-tests-legend-toggle", role = "button", tabindex = "0",
         `aria-expanded` = (if open.val: "true" else: "false")):
      span(class = "ah-fold"):
        text (if open.val: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
      span:
        text LegendLabel
  r.press(toggle, TestsLegendOperation, proc() = open.val = not open.val)
  r.appendRendered(host, toggle)
  if not open.val: return
  var list: N
  let l = ui(r):
    tdiv(ref = list, class = "ah-tests-legend-list", `data-ah-legend` = "open")
  for entryItem in vm.legend:
    let entry = entryItem
    var term: N
    let item = ui(r):
      tdiv(class = "ah-tests-legend-item"):
        span(ref = term, class = "ah-tests-legend-term")
        span(class = "ah-tests-legend-meaning"):
          text entry.meaning
    # A status's term is drawn as the cells draw it: its mark and its word.
    var drawn = false
    for s in CellStatus:
      if statusWord(s) == entry.term:
        r.appendRendered(term, renderMark(r, s))
        let w = ui(r):
          span(class = "ah-role-" & statusRole(s)):
            text entry.term
        r.appendRendered(term, w)
        r.setAttribute(term, "class", "ah-tests-legend-term " & rowClass(s))
        drawn = true
    if not drawn and entry.term == "record mark":
      # The recordability mark itself, as the platform strip draws it.
      let w = ui(r):
        span(class = "ah-tests-record-mark", `aria-label` = entry.term):
          text RecordMarkGlyph
      r.appendRendered(term, w)
    elif not drawn:
      let w = ui(r):
        span(class = "ah-chip ah-tests-chip"):
          text entry.term
      r.appendRendered(term, w)
    r.appendRendered(list, item)
  r.appendRendered(host, l)

proc renderPlatformStrip[R, N](r: R; vm: TestRunsVM; legendOpen: Signal[bool]): N =
  var heads: N
  result = ui(r):
    tdiv(class = "ah-tests-band ah-tests-platform-band"):
      tdiv(ref = heads, class = "ah-tests-platforms", role = "group",
           `aria-label` = PlatformsLabel)
  for head in vm.platformHeads:
    r.appendRendered(heads, renderPlatformHead[R, N](r, vm, head))
  r.appendRendered(result, renderLegend[R, N](r, vm, legendOpen))

# ---------------------------------------------------------------------------
# The matrix
# ---------------------------------------------------------------------------

proc renderColumnHead[R, N](r: R; vm: TestRunsVM): N =
  ## The matrix's head: each switched-on platform's column.
  var cells: N
  result = ui(r):
    tdiv(class = "ah-tests-columns", `aria-hidden` = "true"):
      span(class = "ah-tests-columns-name"):
        discard
      tdiv(ref = cells, class = "ah-tests-cells")
  for key in vm.enabledPlatforms:
    var label = key
    for h in vm.platformHeads:
      if h.key == key: label = h.label
    let c = ui(r):
      span(`data-ah-cut` = "line", class = "ah-tests-column", title = label):
        text label
    r.appendRendered(cells, c)

proc renderCell[R, N](r: R; vm: TestRunsVM; row: TestRowView; cell: TestCellView): N =
  ## One platform's cell of a closed row: the pane's mark and the word; a
  ## reused pass's chip; the open control where a trace is kept, or on a
  ## failure that can be recorded.
  let word = cell.cellWord
  let mark = cellMark(cell.cell.status)
  result = ui(r):
    span(class = cellClass(cell.cell) & (if cell.focused: " ah-tests-cell-keyboard" else: ""),
         title = cellTitle(cell, row.name)):
      span(class = "ah-tests-cell-mark", `aria-hidden` = "true"):
        text mark
      span(`data-ah-cut` = "line", class = "ah-tests-cell-word ah-role-" &
             statusRole(cell.cell.status)):
        text word
  r.tagFacts(result, [("platform", cell.platform), ("status", $cell.cell.status),
                      ("mark", mark)])
  if cell.cell.reused:
    r.appendRendered(result, renderChip(r, "reused", cell.reusedTitle, "ah-tests-reused"))
  elif cell.durationText.len > 0:
    let d = ui(r):
      span(class = "ah-tests-duration"):
        text cell.durationText
    r.appendRendered(result, d)
  if cell.showsOpenInCell:
    r.appendRendered(result, renderOpenControl[R, N](r, vm, row.testId, cell))

proc renderSubRow[R, N](r: R; vm: TestRunsVM; row: TestRowView; cell: TestCellView): N =
  ## One platform of an opened row: its words and controls, then the
  ## failure, the last output and the diagnostics.
  var head, actions, detail: N
  let c = cell.cell
  let mark = cellMark(c.status)
  result = ui(r):
    tdiv(class = "ah-tests-sub " & rowClass(c.status) &
                 (if cell.focused: " ah-tests-sub-keyboard" else: ""),
         title = cellTitle(cell, row.name)):
      tdiv(ref = head, class = "ah-tests-sub-head"):
        span(class = "ah-tests-sub-platform", title = cell.label):
          text cell.label
      tdiv(ref = detail, class = "ah-tests-sub-detail")
  r.tagFacts(result, [("platform", cell.platform), ("status", $c.status), ("mark", mark)])
  if c.backend.len > 0:
    r.appendRendered(head, renderChip(r, backendLabel(c.backend),
      "The backend that served this result", "ah-tests-backend"))
  if c.runner.len > 0:
    let runner = ui(r):
      span(class = "ah-tests-sub-runner"):
        text c.runner
    r.appendRendered(head, runner)
  let status = ui(r):
    span(class = "ah-tests-sub-status"):
      span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
        text mark
      span(class = "ah-role-" & statusRole(c.status)):
        text cell.cellWord
  r.appendRendered(head, status)
  if c.reused:
    r.appendRendered(head, renderChip(r, "reused", cell.reusedTitle, "ah-tests-reused"))
  elif cell.durationText.len > 0:
    let d = ui(r):
      span(class = "ah-tests-duration"):
        text cell.durationText
    r.appendRendered(head, d)
  let a = ui(r):
    tdiv(ref = actions, class = "ah-tests-sub-actions")
  r.appendRendered(head, a)
  let target = vm
  let testId = row.testId
  let platform = cell.platform
  r.appendRendered(actions, renderButton[R, N](r, RunLabel, cellRunTitle(cell),
    "ct-button-sm-secondary ah-tests-button", TestsRunOperation, cell.runAbsence.len == 0,
    proc() = discard target.run(RunScope(kind: scCell, testId: testId, platform: platform))))
  let recordButton = renderButton[R, N](r, RecordLabel, cellRecordTitle(cell),
    "ct-button-sm-secondary ah-tests-button" &
      (if cell.recordWaiting: " ah-tests-waiting" else: ""),
    TestsRecordOperation, cell.recordAbsence.len == 0,
    proc() = discard target.record(RunScope(kind: scCell, testId: testId, platform: platform)))
  r.appendRendered(actions, recordButton)
  if cellSaysRecordWaiting(row, cell):
    # Record waits behind the Run on this platform that is being sent
    # (study D31): said beside the control, never a silently inert button;
    # said once for the row instead when every platform waits.
    let waiting = ui(r):
      span(class = "ah-tests-waiting-word ah-role-quiet", `data-ah-waiting` = "record"):
        text cell.recordAbsence
    r.appendRendered(actions, waiting)
  if c.recording == recDiscarded:
    let gone = ui(r):
      span(class = "ah-tests-not-kept ah-role-quiet", title = RecordingDiscardedText):
        text RecordingDiscardedText
    r.appendRendered(actions, gone)
  else:
    r.appendRendered(actions, renderOpenControl[R, N](r, vm, testId, cell))
  # The failure, where it is, the last output, the diagnostics.
  if c.failure.len > 0:
    let where = locationText(c, row)
    var whereNode: N
    let f = ui(r):
      tdiv(class = "ah-tests-failure"):
        span(class = "ah-tests-detail-label"):
          text FailureLabel
        span(class = "ah-tests-failure-message ah-role-error"):
          text c.failure
        span(ref = whereNode, `data-ah-cut` = CutPathValue,
             class = "ah-tests-where ah-file-link ah-mono", role = "link", title = where):
          text where
    r.press(whereNode, TestsOpenLocationOperation, proc() = target.openLocation(testId))
    r.appendRendered(detail, f)
  let output = lastOutput(c)
  if output.len > 0:
    var lines: N
    let o = ui(r):
      tdiv(class = "ah-tests-output"):
        span(class = "ah-tests-detail-label"):
          text OutputLabel
        tdiv(ref = lines, class = "ah-tests-output-lines ah-mono")
    for lineItem in output:
      let line = lineItem
      let l = ui(r):
        tdiv(class = "ah-tests-output-line ah-tests-stream-" & line.stream):
          span(class = "ah-tests-stream"):
            text line.stream
          span(class = "ah-tests-output-text"):
            text line.text
      r.appendRendered(lines, l)
    r.appendRendered(detail, o)
  if c.diagnostics.len > 0:
    for d in c.diagnostics:
      r.appendRendered(detail, renderLine(r, d.text, diagnosticRole(d.level), "diagnostic"))

proc anyFocused(row: TestRowView): bool =
  ## Whether the keyboard is on one of the row's cells (not on the row).
  for c in row.cells:
    if c.focused: return true
  false

proc renderRow[R, N](r: R; vm: TestRunsVM; row: TestRowView): N =
  ## A test's row: its line (which opens it), and, opened, its sub-rows.
  var line, cells, tags, actions: N
  let id = row.testId
  result = ui(r):
    tdiv(class = "ah-tests-row" & (if row.open: " ah-tests-row-open" else: "") &
                 (if row.selected: " ah-tests-row-selected" else: "") &
                 (if row.focused and not anyFocused(row): " ah-tests-row-keyboard" else: "")):
      tdiv(ref = line, class = rowClass(row.status) & " ah-tests-line" &
                               (if row.selected: " selected" else: ""),
           `aria-expanded` = (if row.open: "true" else: "false")):
        span(class = "ah-fold", `aria-hidden` = "true"):
          text (if row.open: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
        span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
          text cellMark(row.status)
        span(class = "ah-tests-name-cell"):
          span(`data-ah-cut` = "line", class = "test-results-name ah-tests-name",
               title = row.testId):
            text row.name
          span(ref = tags, class = "ah-tests-tags")
        tdiv(ref = cells, class = "ah-tests-cells")
        span(ref = actions, class = "ah-tests-row-actions")
  r.tagFacts(result, [("test", id), ("status", $row.status),
                      ("open", $row.open), ("selected", $row.selected)])
  if row.line > 0:
    let at = ui(r):
      span(class = "test-results-where ah-tests-at"):
        text ":" & $row.line
    r.appendRendered(tags, at)
  for m in row.milestones:
    r.appendRendered(tags, renderChip(r, m, "Named by the Verification entries of " & m,
                                      "ah-tests-milestone"))
  for cell in row.cells:
    r.appendRendered(cells, renderCell[R, N](r, vm, row, cell))
  let target = vm
  r.appendRendered(actions, renderIconButton[R, N](r, "play", rowRunName(row),
    vm.rowRunTitle(row), TestsRunOperation, row.rowCanRun,
    proc() = discard target.run(RunScope(kind: scTest, testId: id))))
  r.appendRendered(actions, renderIconButton[R, N](r, "record", rowRecordName(row),
    vm.rowRecordTitle(row), TestsRecordOperation, row.rowCanRecord,
    proc() = discard target.record(RunScope(kind: scTest, testId: id))))
  r.press(line, TestsToggleOperation, proc() = target.toggleRow(id))
  if row.open:
    var subs: N
    let s = ui(r):
      tdiv(ref = subs, class = "ah-tests-subs")
    let waiting = rowRecordWaitingText(row)
    if waiting.len > 0:
      # Every platform's Record waits behind its Run (D31): said once for
      # the row, above its sub-rows, which then do not repeat it.
      let w = ui(r):
        tdiv(class = "ah-tests-subs-say ah-role-quiet", `data-ah-waiting` = "record-row"):
          text waiting
      r.appendRendered(subs, w)
    for cell in row.cells:
      r.appendRendered(subs, renderSubRow[R, N](r, vm, row, cell))
    r.appendRendered(result, s)

proc renderGroup[R, N](r: R; vm: TestRunsVM; group: TestGroupView): N =
  ## A file's tests: its head folds them.
  var head, rows: N
  let file = group.file
  result = ui(r):
    tdiv(class = "ah-tests-group" & (if group.folded: " ah-tests-group-folded" else: ""),
         `data-ah-group` = file):
      tdiv(ref = head, class = "ah-tests-group-head",
           `aria-expanded` = (if group.folded: "false" else: "true")):
        span(class = "ah-fold", `aria-hidden` = "true"):
          text (if group.folded: "\xE2\x96\xB8" else: "\xE2\x96\xBE")
        span(`data-ah-cut` = CutPathValue, class = "ah-tests-group-name ah-mono", title = file):
          text file
        span(class = "ah-tests-group-count"):
          text "(" & $group.count & ")"
      tdiv(ref = rows, class = "ah-tests-group-rows")
  let target = vm
  r.press(head, TestsToggleGroupOperation, proc() = target.toggleGroup(file))
  if group.folded: return
  for row in group.rows:
    r.appendRendered(rows, renderRow[R, N](r, vm, row))

proc renderNotInCatalog[R, N](r: R; vm: TestRunsVM): N =
  ## T14: the plan's Verification entries no catalog test matches, under
  ## their milestone, `not in the catalog`, with no Run or Record.
  let entries = vm.notInCatalog
  var rows: N
  result = ui(r):
    tdiv(class = "ah-tests-group ah-tests-unmatched", `data-ah-group` = "not-in-catalog"):
      tdiv(class = "ah-tests-group-head ah-tests-group-head-static"):
        span(class = "ah-tests-group-name"):
          text NotInCatalogHead
        span(class = "ah-tests-group-count"):
          text "(" & $entries.len & ")"
      tdiv(ref = rows, class = "ah-tests-group-rows")
  for jItem in entries:
    let j = jItem
    let e = ui(r):
      tdiv(class = "ah-tests-row ah-tests-row-unmatched", title = j.reason,
           `data-ah-unmatched` = j.entry.testName):
        tdiv(class = "test-results-row not-run ah-tests-line ah-tests-line-static"):
          span(class = "ah-fold", `aria-hidden` = "true"):
            discard
          span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
            text cellMark(tsNotRun)
          span(class = "ah-tests-name-cell"):
            span(`data-ah-cut` = "line", class = "test-results-name ah-tests-name",
                 title = j.entry.testName):
              text j.entry.testName
            span(class = "ah-tests-tags"):
              span(class = "ah-chip ah-tests-chip ah-tests-milestone",
                   title = "Named by the Verification entries of " & j.entry.milestoneId):
                text j.entry.milestoneId
          span(class = "ah-tests-unmatched-word ah-role-quiet", title = j.reason):
            text NotInCatalogText
    r.appendRendered(rows, e)

when defined(js):
  proc keepKeyboardRowInView(list: isonim_dom.Element) {.importjs: """
    (function (list) {
      // The keyboard's row (or cell) kept in view: the list scrolls the
      // least that shows it, once laid out, and again once the faces load.
      function keep() {
        var el = list.querySelector('.ah-tests-sub-keyboard, .ah-tests-cell-keyboard, .ah-tests-row-keyboard');
        if (!el || list.clientHeight === 0) return;
        var er = el.getBoundingClientRect(), lr = list.getBoundingClientRect();
        if (er.top < lr.top) list.scrollTop -= lr.top - er.top;
        else if (er.bottom > lr.bottom) list.scrollTop += Math.min(er.bottom - lr.bottom, er.top - lr.top);
      }
      keep();
      requestAnimationFrame(keep);
      setTimeout(keep, 120);
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(keep);
    })(#)""".}

proc renderList[R, N](r: R; vm: TestRunsVM; list: N) =
  ## The matrix, or the notice that stands in for it.
  mixin clearChildren, setAttribute
  r.clearChildren(list)
  # The groups are built once per drawing: with any row listed the
  # viewmodel's notice is empty (it names only the states with no row), so
  # it is asked only when there is none.
  let groups = vm.groups
  let notice = if groups.len > 0: "" else: vm.notice
  if notice.len > 0 and notice != NoMatchNotice:
    r.appendRendered(list, renderNotice(r, notice, vm.hint, "empty"))
    return
  r.setAttribute(list, "style", "--ah-tests-platforms: " & $max(1, vm.enabledPlatforms.len))
  r.appendRendered(list, renderColumnHead[R, N](r, vm))
  if notice == NoMatchNotice:
    r.appendRendered(list, renderNotice(r, notice, "", "filtered"))
  else:
    for group in groups:
      r.appendRendered(list, renderGroup[R, N](r, vm, group))
  if vm.notInCatalog.len > 0:
    r.appendRendered(list, renderNotInCatalog[R, N](r, vm))

proc renderFilters[R, N](r: R; vm: TestRunsVM): N =
  ## The search and the status filter, built once per ready panel: typing
  ## never rebuilds the field it types into.
  mixin inputValue
  var search, bar: N
  let query = untrack(proc(): string = vm.query.val)
  let current = untrack(proc(): TestFilter = vm.filter.val)
  result = ui(r):
    tdiv(ref = bar, class = "ah-tests-filters"):
      input(ref = search, class = "ct-input-panel ct-input-search-image ah-tests-search",
            `type` = "search", placeholder = SearchTestsPlaceholder, value = query,
            `aria-label` = SearchTestsPlaceholder,
            oninput = proc() = vm.setQuery(r.inputValue(search)))
  var choices: seq[DropdownChoice]
  for f in filterChoices(): choices.add DropdownChoice(id: $f, label: $f)
  let pick = proc(id: string) =
    for f in filterChoices():
      if $f == id: vm.setFilter(f)
  r.appendRendered(bar, renderAgentHarborDropdown[R, N](r, $current, choices, $current, pick,
    cls = "ah-changes-select ah-tests-filter", title = StatusFilterTitle))

proc renderAgentHarborTests*[R, N](r: R; vm: TestRunsVM;
                                   ctx = AgentHarborTestsContext()): N =
  ## The Tests panel over `vm`, for the session `ctx` names.
  mixin clearChildren, setAttribute
  var head, body: N
  let legendOpen = createSignal(ctx.legendOpen)
  let panel = ui(r):
    tdiv(class = AgentHarborTestsClass, `data-ct-pane` = TestsPaneName, tabindex = "0"):
      tdiv(ref = head, class = "ah-tests-head-host")
      tdiv(ref = body, class = "ah-fleet-body ah-tests-body")
  createRenderEffect proc() =
    r.clearChildren(head)
    r.appendRendered(head, renderHead(r, vm, ctx))
  createRenderEffect proc() =
    r.clearChildren(body)
    r.tagFacts(panel, [("state", (case vm.state
                                  of asIdle, asLoading: "loading"
                                  of asError: "error"
                                  of asReady: "ready"))])
    let target = vm
    case vm.state
    of asIdle, asLoading:
      r.appendRendered(body, renderNotice(r, TestsLoadingNotice, "", "loading"))
    of asError:
      var retry: N
      let e = ui(r):
        tdiv(class = "ah-fleet-error", `data-ah-notice` = "error"):
          tdiv(class = "ah-fleet-error-title"):
            text TestsErrorTitle
          tdiv(class = "ah-fleet-error-message"):
            text vm.error
          button(ref = retry, class = "ah-fleet-retry"):
            text RetryText
      r.press(retry, TestsRetryOperation, proc() = target.retry())
      r.appendRendered(body, e)
    of asReady:
      var band, strip, list: N
      let bands = ui(r):
        tdiv(class = "ah-tests-bands"):
          tdiv(ref = band, class = "ah-tests-band-host")
          tdiv(ref = strip, class = "ah-tests-band-host")
      r.appendRendered(body, bands)
      createRenderEffect proc() =
        r.clearChildren(band)
        r.appendRendered(band, renderRunBand[R, N](r, vm))
      createRenderEffect proc() =
        r.clearChildren(strip)
        r.appendRendered(strip, renderPlatformStrip[R, N](r, vm, legendOpen))
      if untrack(proc(): bool = vm.feed.offers.len > 0 and vm.testCount > 0):
        r.appendRendered(body, renderFilters[R, N](r, vm))
      let listNode = ui(r):
        tdiv(ref = list, class = "ah-tests-list", role = "grid")
      r.appendRendered(body, listNode)
      createRenderEffect proc() =
        renderList[R, N](r, vm, list)
        when defined(js):
          when typeof(list) is isonim_dom.Element:
            keepKeyboardRowInView(list)
  panel

when defined(js):
  proc mountAgentHarborTestsPanel*(container: isonim_dom.Element; vm: TestRunsVM;
                                   ctx = AgentHarborTestsContext()) =
    ## Mounts the Tests panel over `vm` in `container`.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborTests[WebRenderer, isonim_dom.Element](WebRenderer(), vm, ctx)))
