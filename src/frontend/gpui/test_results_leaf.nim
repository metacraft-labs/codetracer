## NOT-A-TEST-LANE-FILE: this is the GPUI window's Test Results LEAF —
## production frontend code named after the test results it draws, which is
## why its basename matches the guard's `test_*` name arm. It imports no
## `unittest` and declares no `suite`/`test` block. It is asserted by
## `src/frontend/gpui/tests/test_plat53_gpui_plan.nim` (the `gpui-shell`
## lane).

## gpui/test_results_leaf.nim — PLAT-53. The GPUI window's **Test Results**
## pane, drawn natively from the window's `TestResultsVM` (the model the
## desktop's pane and the terminal's draw).
##
## What the desktop's pane draws, in its order and words (`Test-Results-
## Pane.md` §8.4): the headline beside the ▶ (dimmed with its reason when it
## cannot run), one row per test — mark, name, location, duration, `⟳` and
## `⏵` — a failed test's message under it in the error colour, the failure
## block, the absence and the empty state. Every word is the ViewModel's. The
## rows have a fixed pitch so a press and the drawing go through one layout
## (`testsLayout`), as Find in Files' do; the list scrolls (the wheel) and its
## scrollbar is the shared list scrubber, moving the VIEW.
##
## Shift arms `⏵` here, as on the desktop: the window reads the modifier off
## its key and pointer events (`TestResultsVM.setShiftHeld`), so the glyph,
## the title and the press agree (§4.4).
##
## Every element carries what a reader of the window's render plan needs
## (`data-ct-tests-*`, `data-ct-test-*`).

import std/strutils

import isonim_gpui/renderer
import isonim/core/[signals, computation]

import codetracer_embed
import ./window_geometry
import ./chrome
import ./app/leaves
import ./list_scrubber
import ../viewmodel/viewmodels/test_results_vm
from ../../common/view_vocabulary/layout_questions import trEditorCode
import ../styles/generated/design_tokens

type
  GTestsPane* = object
    ## The window's own state for the pane: where the reader scrolled, the
    ## selected row and a held scrubber thumb.
    scrollTop*: int
    selected*: int
    dragging*: bool

  TestsLine* = object
    ## One row of the list as drawn: a test, or a wrapped line of text.
    kind*: TestResultsDisplayKind
    row*: int
    text*: string

  TestsLayout* = object
    body*: PxRect
    header*: PxRect
    run*: PxRect
      ## The ▶.
    list*: PxRect
    rows*: int
      ## How many list rows fit.
    overflow*: bool
    lines*: seq[TestsLine]
      ## The list, wrapped to the pane.
    fit*: TableFit
      ## The columns, in pixels from `list.x`.

  GTestsHitKind* = enum
    gtNone, gtRun, gtRow, gtRefresh, gtOpen, gtTrack, gtThumb, gtText

  GTestsHit* = object
    kind*: GTestsHitKind
    row*: int
    fraction*: float

const
  TestsRowPx* = 22
  TestsHeaderPx* = 26
  TestsRunPx* = 26
  TestsMarkPx = 14
  TestsActionPx* = 22
    ## Each of `⟳` and `⏵`.
  TestsGapPx = 6
  TestsAttribute* = "data-ct-tests"
    ## On the pane: its headline.
  TestsRunAttribute* = "data-ct-tests-run"
    ## On the ▶: its title; `data-ct-disabled` says whether it can run.
  TestRowAttribute* = "data-ct-test-id"
    ## On a test's row: its id; `data-ct-test-state`, `data-ct-recording-id`.
  TestControlAttribute* = "data-ct-test-control"
    ## On `⟳` / `⏵`: `refresh` / `open`, with `data-ct-title`,
    ## `data-ct-open-mode` and `data-ct-disabled`.
  TestLineAttribute* = "data-ct-tests-line"
    ## On a text line: `message`, `failure`, `absence` or `empty`.
  TestsTextColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  TestsMutedColour = DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark]
  TestsSuccessColour* = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
    ## The desktop's `.passed .test-results-mark`.
  TestsErrorColour* = DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
    ## The desktop's failed / errored mark, a message, a failure line.
  TestsSelectedGround =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
  TestsArmedColour =
    DesignTokenHex[dtColorsUiTextInformationPrimary][dmDark]
    ## `.test-results-open-btn.shift-armed`.

proc initGTestsPane*(): GTestsPane = GTestsPane(selected: -1)

proc cellsOf(px: int): int = int(float(px) / EditorColumnPx)

proc markColour(state: TestResultsRowState): string =
  case state
  of trsPassed: TestsSuccessColour
  of trsFailed, trsErrored: TestsErrorColour
  of trsNotRun, trsRunning, trsSkipped, trsCancelled: TestsTextColour

proc wrappedLines(vm: TestResultsVM; widthPx: int): seq[TestsLine] =
  ## The ViewModel's list (`displayRows`), its text lines wrapped to the
  ## pane in the monospace face they are drawn in; a message indented under
  ## its row's name.
  let indent = TestsMarkPx + TestsGapPx
  for d in vm.displayRows():
    case d.kind
    of tdRow:
      result.add TestsLine(kind: tdRow, row: d.row)
    of tdMessage:
      for part in wrapCells(d.text, max(1, cellsOf(widthPx - indent))):
        result.add TestsLine(kind: tdMessage, row: d.row, text: part)
    else:
      for part in wrapCells(d.text, max(1, cellsOf(widthPx))):
        result.add TestsLine(kind: d.kind, row: -1, text: part)

proc durationPx(vm: TestResultsVM): int =
  for row in vm.rows.val:
    result = max(result, int(float(rowDuration(row).len) * EditorColumnPx))

proc testsLayout*(vm: TestResultsVM; body: PxRect): TestsLayout =
  ## The pane's parts, in window pixels, inside `body` (its padding off).
  result.body = body
  let inner = PxRect(x: body.x + ChromePaddingPx, y: body.y + ChromePaddingPx,
                     w: max(0, body.w - 2 * ChromePaddingPx),
                     h: max(0, body.h - 2 * ChromePaddingPx))
  result.header = PxRect(x: inner.x, y: inner.y, w: inner.w, h: TestsHeaderPx)
  result.run = PxRect(x: inner.x + inner.w - TestsRunPx, y: inner.y,
                      w: TestsRunPx, h: TestsHeaderPx)
  let top = inner.y + TestsHeaderPx + 2
  let rest = max(0, inner.y + inner.h - top)
  result.rows = max(0, rest div TestsRowPx)
  var width = inner.w
  result.lines = vm.wrappedLines(width)
  result.overflow = result.lines.len > result.rows
  if result.overflow:
    width = max(0, inner.w - ListTrackPx - 2)
    result.lines = vm.wrappedLines(width)
  result.list = PxRect(x: inner.x, y: top, w: width,
                       h: result.rows * TestsRowPx)
  result.fit = testResultsFit(TestsMarkPx, vm.durationPx,
                              2 * TestsActionPx, width, TestsGapPx)

proc listBody(lay: TestsLayout): PxRect =
  PxRect(x: lay.body.x, y: lay.list.y - ChromePaddingPx, w: lay.body.w,
         h: lay.list.h + 2 * ChromePaddingPx)

proc visibleTop*(st: GTestsPane; total, rows: int): int =
  max(0, min(st.scrollTop, total - max(1, rows)))

proc scrubberOf*(st: GTestsPane; total, rows: int): ScrubberModel =
  scrubberModel(total, st.visibleTop(total, rows), rows)

proc lineOfRow*(lay: TestsLayout; row: int): int =
  for i, line in lay.lines:
    if line.kind == tdRow and line.row == row:
      return i
  -1

proc revealRow*(st: var GTestsPane; vm: TestResultsVM; body: PxRect;
                row: int) =
  ## Keep test `row` in view.
  let lay = testsLayout(vm, body)
  let at = lay.lineOfRow(row)
  if at < 0 or lay.rows <= 0:
    return
  let top = st.visibleTop(lay.lines.len, lay.rows)
  if at < top: st.scrollTop = at
  elif at >= top + lay.rows: st.scrollTop = at - lay.rows + 1

proc scrollBy*(st: var GTestsPane; vm: TestResultsVM; body: PxRect;
               delta: int) =
  let lay = testsLayout(vm, body)
  st.scrollTop = max(0, min(st.visibleTop(lay.lines.len, lay.rows) + delta,
                            lay.lines.len - max(1, lay.rows)))

proc textRun(r: GpuiRenderer; text, colour: string; widthPx = -1): GpuiElement =
  result = r.createElement("span")
  r.setStyle(result, "color", colour)
  r.setStyle(result, "white-space", "pre")
  r.setStyle(result, "flex-shrink", "0")
  if widthPx >= 0:
    r.setStyle(result, "width", $widthPx & "px")
    r.setStyle(result, "overflow", "hidden")
  r.appendChild(result, r.createTextNode(text))

proc rowElement(r: GpuiRenderer; widthPx: int): GpuiElement =
  result = r.createElement("div")
  for (k, v) in [("display", "flex"), ("white-space", "nowrap"),
                 ("overflow", "hidden"), ("flex-shrink", "0"),
                 ("items", "center")]:
    r.setStyle(result, k, v)
  r.setStyle(result, "height", $TestsRowPx & "px")
  r.setStyle(result, "width", $widthPx & "px")
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trEditorCode))

proc cut(text: string; px: int): string =
  ## `text` in a column `px` wide, ending in `…` when cut
  ## (`table_overflow.fitCell`, in the monospace face's cells).
  fitCell(text, cellsOf(px)).text

proc control(r: GpuiRenderer; which, label, title: string; enabled: bool;
             mode = ""; armed = false): GpuiElement =
  result = r.createElement("span")
  r.setAttribute(result, TestControlAttribute, which)
  r.setAttribute(result, "data-ct-title", title)
  r.setAttribute(result, "data-ct-disabled", $(not enabled))
  if mode.len > 0:
    r.setAttribute(result, "data-ct-open-mode", mode)
  r.setStyle(result, "width", $TestsActionPx & "px")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "color", if armed: TestsArmedColour
                              elif enabled: TestsMutedColour
                              else: TestsMutedColour & "80")
  r.appendChild(result, r.createTextNode(label))

proc drawTestResults*(r: GpuiRenderer; pane: GpuiElement; vm: TestResultsVM;
                      st: GTestsPane; body: PxRect): bool =
  ## Draw the pane into `pane` (its children replaced), its body at `body` in
  ## window pixels. False when there is nothing to draw it from.
  if pane.isNil or vm.isNil:
    return false
  while childCount(pane) > 0:
    r.removeChild(pane, nthChild(pane, childCount(pane) - 1))
  r.setStyle(pane, "position", "relative")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  let lay = testsLayout(vm, body)
  r.setAttribute(pane, TestsAttribute, vm.headline.val)
  # The headline and the ▶.
  let header = r.createElement("div")
  for (k, v) in [("display", "flex"), ("flex-shrink", "0"), ("items", "center")]:
    r.setStyle(header, k, v)
  r.setStyle(header, "height", $TestsHeaderPx & "px")
  let headline = textRun(r, vm.headline.val, TestsMutedColour,
                         max(0, lay.header.w - TestsRunPx))
  r.setAttribute(headline, "data-ct-tests-headline", vm.headline.val)
  r.appendChild(header, headline)
  let run = r.createElement("div")
  r.setAttribute(run, TestsRunAttribute, vm.runButtonTitle())
  r.setAttribute(run, "data-ct-disabled", $(not vm.canRun()))
  r.setStyle(run, "width", $TestsRunPx & "px")
  r.setStyle(run, "color", if vm.canRun(): TestsTextColour
                           else: TestsMutedColour & "80")
  r.appendChild(run, r.createTextNode(RunButtonLabel))
  r.appendChild(header, run)
  r.appendChild(pane, header)
  # The list.
  let rows = vm.rows.val
  let top = st.visibleTop(lay.lines.len, lay.rows)
  r.setAttribute(pane, "data-ct-tests-top", $top)
  r.setAttribute(pane, "data-ct-tests-rows", $lay.rows)
  r.setAttribute(pane, "data-ct-tests-total", $lay.lines.len)
  let f = lay.fit
  for k in 0 ..< lay.rows:
    let i = top + k
    if i >= lay.lines.len:
      break
    let line = lay.lines[i]
    let el = rowElement(r, lay.list.w)
    case line.kind
    of tdRow:
      let row = rows[line.row]
      r.setAttribute(el, TestRowAttribute, row.testId)
      r.setAttribute(el, "data-ct-test-state", $row.state)
      r.setAttribute(el, "data-ct-recording-id", row.recordingId)
      r.setAttribute(el, "data-ct-test-selector", row.selector)
      r.setStyle(el, "gap", $TestsGapPx & "px")
      if line.row == st.selected:
        r.setAttribute(el, "data-ct-selected", "true")
        r.setStyle(el, "background", TestsSelectedGround)
      let mark = textRun(r, stateMark(row.state), markColour(row.state),
                         f.widths[0])
      r.setAttribute(mark, "data-ct-test-mark", stateMark(row.state))
      r.appendChild(el, mark)
      let nameColour = if row.state == trsNotRun: TestsMutedColour
                       else: TestsTextColour
      let name = textRun(r, cut(row.name, f.widths[1]), nameColour,
                         f.widths[1])
      r.setAttribute(name, "data-ct-test-name", row.name)
      r.appendChild(el, name)
      let where = textRun(r, cut(rowWhere(row), f.widths[2]),
                          TestsMutedColour, f.widths[2])
      r.setAttribute(where, "data-ct-test-where", rowWhere(row))
      r.appendChild(el, where)
      let duration = textRun(r, rowDuration(row), TestsMutedColour,
                             f.widths[3])
      r.setAttribute(duration, "data-ct-test-duration", rowDuration(row))
      r.appendChild(el, duration)
      r.appendChild(el, control(r, "refresh", "⟳", vm.refreshButtonTitle(row),
                                vm.refreshAbsence().len == 0))
      r.appendChild(el, control(r, "open", vm.openButtonMark(row),
                                vm.openButtonTitle(row),
                                vm.openAbsence(row).len == 0,
                                $vm.openButtonMode(row),
                                armed = vm.openButtonMode(row) ==
                                        obmRefreshAndOpen))
    of tdMessage:
      r.setAttribute(el, TestLineAttribute, "message")
      r.setAttribute(el, "data-ct-test-row", $line.row)
      r.setStyle(el, "padding-left", $(TestsMarkPx + TestsGapPx) & "px")
      r.appendChild(el, textRun(r, line.text, TestsErrorColour))
    of tdFailure:
      r.setAttribute(el, TestLineAttribute, "failure")
      r.appendChild(el, textRun(r, line.text, TestsErrorColour))
    of tdAbsence, tdEmpty:
      r.setAttribute(el, TestLineAttribute, $line.kind)
      r.appendChild(el, textRun(r, line.text, TestsMutedColour))
    r.appendChild(pane, el)
  if lay.overflow:
    drawListScrubber(r, pane, lay.listBody, st.scrubberOf(lay.lines.len,
                                                           lay.rows), "tests")
  true

proc testsHitAt*(vm: TestResultsVM; st: GTestsPane; body: PxRect;
                 x, y: int): GTestsHit =
  ## What a press at window pixel `(x, y)` is on, by the drawing's layout.
  result = GTestsHit(kind: gtNone, row: -1)
  if vm.isNil or not body.contains(x, y):
    return
  let lay = testsLayout(vm, body)
  if lay.run.contains(x, y):
    return GTestsHit(kind: gtRun, row: -1)
  if lay.overflow:
    let hit = listScrubHit(lay.listBody, st.scrubberOf(lay.lines.len,
                                                       lay.rows), x, y)
    if hit.onTrack:
      return GTestsHit(kind: (if hit.onThumb: gtThumb else: gtTrack),
                       row: -1, fraction: hit.fraction)
  if not lay.list.contains(x, y):
    return
  let i = st.visibleTop(lay.lines.len, lay.rows) + (y - lay.list.y) div TestsRowPx
  if i < 0 or i >= lay.lines.len:
    return
  let line = lay.lines[i]
  case line.kind
  of tdRow:
    let actions = lay.list.x + lay.fit.starts[4]
    if x >= actions and x < actions + TestsActionPx:
      return GTestsHit(kind: gtRefresh, row: line.row)
    if x >= actions + TestsActionPx and x < actions + 2 * TestsActionPx:
      return GTestsHit(kind: gtOpen, row: line.row)
    return GTestsHit(kind: gtRow, row: line.row)
  of tdMessage:
    return GTestsHit(kind: gtRow, row: line.row)
  else:
    return GTestsHit(kind: gtText, row: -1)

proc scrubTests*(st: var GTestsPane; vm: TestResultsVM; body: PxRect;
                 y: int; dragging: bool) =
  ## The scrubber pressed (a jump) or its thumb held (the view follows).
  let lay = testsLayout(vm, body)
  if not lay.overflow:
    return
  let track = listTrackRect(lay.listBody)
  let sm = st.scrubberOf(lay.lines.len, lay.rows)
  st.scrollTop = sm.scrubTop(trackFractionAt(y - track.y, track.h), dragging)
