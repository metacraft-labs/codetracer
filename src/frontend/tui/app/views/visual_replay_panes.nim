## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/visual_replay_panes.nim — PLAT-59. The terminal's Pixel History
## and Shader Debug panes (Visual-Replay.md § Pixel History Tab, § Shader
## Debug Tab; CodeTracer-TUI-Graphics.md §6).
##
## Two panes of the state area, added with the Video Player when a recording
## carries graphics. Both are pure functions of a value, as every pane here
## is: the binding (`app/frame_viewer_binding.nim`) reads the ViewModels and
## fills the models below; this module paints them and answers what a press
## at a cell names.
##
##   * **Pixel History** — §6.1's "list with a status column": one row per
##     draw call that wrote the picked pixel, in the desktop's words (`Draw 9
##     GEID 902 Passed`, the three colours as swatches, the four tests), the
##     selected row's colour values under the list. A row's press navigates
##     (the host's `VisualReplayPanesVM.activateHistoryEntry`).
##   * **Shader Debug** — §6.3: the shader's source with the step's line
##     marked, the step's instruction, its variables and registers, and the
##     desktop's four step buttons (First / Back / Step / Last).

import std/strutils

import isonim_tui

import ../layout/cells
import ./styled_row
from ../../../../common/terminal_graphics import Rgb
from ./frame_viewer import rgbSpelling
from codetracer_embed import PixelHistoryLoadingText, ShaderDebugLoadingText,
  VideoPlayerAction, ScrubAxis

export styled_row

type
  HistoryPaneRow* = object
    ## One entry of the pixel history, in the desktop's words
    ## (`pixel_history_vm.drawText` / `geidText` / `passText` / `testsText`).
    index*: int
    draw*, geid*, pass*, tests*: string
    passed*: bool
    pre*, shader*, post*: Rgb
      ## The three colours (pre-modify, shader output, post-modify).
    preText*, shaderText*, postText*: string
      ## Their channel values, `0.94, 0.71, 0.13, 1.00`.

  PixelHistoryPaneModel* = object
    loaded*: bool
      ## A session supplied the pane (the recording carries graphics).
    header*: string
      ## `Pixel 12, 34 frame 2`, or that none is picked.
    loading*: bool
    error*: string
    empty*: string
      ## The words when the list is empty and nothing is loading.
    rows*: seq[HistoryPaneRow]
    selected*: int
      ## The selected row's index, -1 for none.
    scrollTop*: int

  ShaderValueRow* = object
    name*, valueType*, value*: string

  ShaderDebugPaneModel* = object
    loaded*: bool
    loading*: bool
    error*: string
    empty*: string
    context*: string
      ## `Pixel 12, 34 frame 2 draw 5 GEID 501`.
    stage*: string
      ## `fragment / main`.
    step*: string
      ## `Step 1 / 3`.
    stepIndex*, stepCount*: int
    sourceLines*: seq[string]
    currentLine*: int
      ## The step's source line (1-based), 0 for none.
    instruction*: string
    variables*, registers*: seq[ShaderValueRow]
    hasInfo*: bool
      ## A trace arrived (the body is drawn).

  ShaderButton* = enum
    sbFirst = "First"
    sbBack = "Back"
    sbStep = "Step"
    sbLast = "Last"
      ## The desktop's toolbar buttons, in its words and order.

  VisualPaneTargetKind* = enum
    vtNone
    vtHistoryRow     ## `index`: a pixel-history row
    vtShaderButton   ## `button`: a shader step button

  VisualPaneTarget* = object
    kind*: VisualPaneTargetKind
    index*: int
    button*: ShaderButton

  VisualActKind* = enum
    ## What a Visual Replay pane asks the HOST to do with the session's
    ## `VisualReplayPanesVM` (`TuiApp.visualAct`): this layer reads no
    ## ViewModel.
    vaPlayer        ## a transport control or key (`action`)
    vaScrubBegin    ## a press on a scrubber (`axis`, `position`)
    vaScrubDrag     ## the pointer moved while held
    vaScrubRelease  ## the release
    vaPickPixel     ## commit source pixel (`x`, `y`) — the magnifier's
    vaPickerState   ## the picker on (`on`) or off, without committing
    vaHistorySelect ## move the history's selection to row `index`
    vaHistoryActivate ## a history row's click: navigate (`index`)
    vaShaderStep    ## a shader step button (`button`)
    vaTick          ## the idle tick: answers, playback, a coalesced scrub

  VisualAct* = object
    kind*: VisualActKind
    action*: VideoPlayerAction
    axis*: ScrubAxis
    position*: int
    x*, y*: int
    index*: int
    on*: bool
    button*: ShaderButton
    nowMs*: float

  VisualActResult* = object
    note*: string
      ## The status line's words, "" for none.
    changed*: bool
      ## A pane's value changed: repaint.
    moved*: bool
      ## The debugger moved (the host has read every pane again).

  PixelHistoryPaneScreen* = object
    listTop*, listRows*: int
    top*: int
      ## The first row shown (the clamped scroll).
    painted*: seq[string]
      ## Every painted row's text, in order (for the suites).

  ShaderDebugPaneScreen* = object
    toolbarRow*: int
    buttons*: seq[tuple[button: ShaderButton, col, width: int]]
    sourceTop*, sourceRows*: int
    currentRow*: int
      ## The screen row of the step's source line, -1 when not shown.
    painted*: seq[string]

const
  HeaderStyle = CellStyle(role: srChromeTitle)
  MutedStyle = CellStyle(role: srChromeMuted)
  ErrorStyle = CellStyle(role: srChromeError)
  PassStyle = CellStyle(role: srChromeSuccess)
  RowSelectedStyle = CellStyle(role: srChromeText, surface: srSurfaceSelection,
                               bold: true)
  CurrentLineStyle = CellStyle(role: srChromeText,
                               surface: srSurfaceSelection, bold: true)
  SwatchText = "  "
    ## A swatch is two cells wide: a square on a 1:2 cell.

func clampHistoryTop*(rows, top, shown: int): int =
  if shown <= 0 or rows <= shown: 0
  else: max(0, min(top, rows - shown))

func revealHistoryRow*(m: PixelHistoryPaneModel; shown, row: int): int =
  ## The scroll that keeps `row` in view.
  if row < 0 or shown <= 0: return m.scrollTop
  if row < m.scrollTop: row
  elif row >= m.scrollTop + shown: row - shown + 1
  else: m.scrollTop

proc paintSpans(g: var StyledGrid; row, col, width: int;
                spans: seq[StyledSpan]): string =
  ## Paint `spans` from `col`, cut at `width` cells; the painted text.
  var at = col
  for span in spans:
    let room = col + width - at
    if room <= 0: break
    let fitted = truncateToCells(span.text, room)
    if fitted.len == 0: continue
    g.paint(row, at, fitted, span.style)
    at += cellWidthOf(fitted)
    result.add fitted

proc swatch(c: Rgb): StyledSpan =
  StyledSpan(text: SwatchText, style: CellStyle(bg: rgbSpelling(c)))

proc historyRowSpans*(r: HistoryPaneRow; selected: bool): seq[StyledSpan] =
  ## `Draw 9  GEID 902  Passed  ▉▉ ▉▉ ▉▉  Depth pass  Stencil pass …`
  let base = if selected: RowSelectedStyle else: DefaultCellStyle
  result.add StyledSpan(text: r.draw, style: base)
  result.add StyledSpan(text: "  " & r.geid, style: MutedStyle)
  result.add StyledSpan(text: "  " & r.pass,
                        style: (if r.passed: PassStyle else: ErrorStyle))
  result.add StyledSpan(text: "  ")
  result.add swatch(r.pre)
  result.add StyledSpan(text: " ")
  result.add swatch(r.shader)
  result.add StyledSpan(text: " ")
  result.add swatch(r.post)
  result.add StyledSpan(text: "  " & r.tests, style: MutedStyle)

proc paintPixelHistory*(g: var StyledGrid; area: CellArea;
                        m: PixelHistoryPaneModel): PixelHistoryPaneScreen =
  ## The pane: its header (the pixel), the loading / error / empty line, the
  ## rows, and the selected row's colour values on the last row.
  result.listTop = -1
  if area.width <= 0 or area.height <= 0:
    return
  var row = area.row
  let bottom = area.row + area.height
  result.painted.add g.paintSpans(row, area.col, area.width,
    @[StyledSpan(text: m.header, style: HeaderStyle)])
  inc row
  if m.loading and row < bottom:
    result.painted.add g.paintSpans(row, area.col, area.width,
      @[StyledSpan(text: PixelHistoryLoadingText, style: MutedStyle)])
    inc row
  if m.error.len > 0 and row < bottom:
    result.painted.add g.paintSpans(row, area.col, area.width,
      @[StyledSpan(text: m.error, style: ErrorStyle)])
    inc row
  if m.rows.len == 0:
    if not m.loading and m.error.len == 0 and row < bottom:
      result.painted.add g.paintSpans(row, area.col, area.width,
        @[StyledSpan(text: m.empty, style: MutedStyle)])
    return
  let detail = m.selected >= 0 and m.selected < m.rows.len
  let listRows = max(0, bottom - row - (if detail: 1 else: 0))
  result.listTop = row
  result.listRows = listRows
  result.top = clampHistoryTop(m.rows.len, m.scrollTop, listRows)
  var i = result.top
  while i < m.rows.len and row < area.row + area.height -
        (if detail: 1 else: 0):
    result.painted.add g.paintSpans(row, area.col, area.width,
      historyRowSpans(m.rows[i], i == m.selected))
    inc row
    inc i
  if detail and bottom - 1 > area.row:
    let r = m.rows[m.selected]
    result.painted.add g.paintSpans(bottom - 1, area.col, area.width,
      @[StyledSpan(text: "Pre " & r.preText & "  Shader " & r.shaderText &
                         "  Post " & r.postText, style: MutedStyle)])

func historyTargetAt*(s: PixelHistoryPaneScreen; m: PixelHistoryPaneModel;
                      row: int): VisualPaneTarget =
  ## What a press on screen row `row` names.
  if s.listTop < 0 or row < s.listTop or row >= s.listTop + s.listRows:
    return VisualPaneTarget(kind: vtNone)
  let i = s.top + (row - s.listTop)
  if i < 0 or i >= m.rows.len:
    return VisualPaneTarget(kind: vtNone)
  VisualPaneTarget(kind: vtHistoryRow, index: i)

proc paintShaderDebug*(g: var StyledGrid; area: CellArea;
                       m: ShaderDebugPaneModel): ShaderDebugPaneScreen =
  ## The pane: the context line, then — once a trace arrived — the toolbar
  ## (stage, step, the four buttons), the source with the step's line marked,
  ## the instruction, the variables and the registers.
  result.toolbarRow = -1
  result.currentRow = -1
  if area.width <= 0 or area.height <= 0:
    return
  var row = area.row
  let bottom = area.row + area.height
  result.painted.add g.paintSpans(row, area.col, area.width,
    @[StyledSpan(text: m.context, style: HeaderStyle)])
  inc row
  if m.loading and row < bottom:
    result.painted.add g.paintSpans(row, area.col, area.width,
      @[StyledSpan(text: ShaderDebugLoadingText, style: MutedStyle)])
    inc row
  if m.error.len > 0 and row < bottom:
    result.painted.add g.paintSpans(row, area.col, area.width,
      @[StyledSpan(text: m.error, style: ErrorStyle)])
    inc row
  if not m.hasInfo:
    if not m.loading and m.error.len == 0 and row < bottom:
      result.painted.add g.paintSpans(row, area.col, area.width,
        @[StyledSpan(text: m.empty, style: MutedStyle)])
    return
  if row >= bottom:
    return
  # The toolbar: stage, step, then the buttons.
  var col = area.col
  let right = area.col + area.width
  let head = m.stage & "  " & m.step & "  "
  let fitted = truncateToCells(head, right - col)
  g.paint(row, col, fitted, MutedStyle)
  col += cellWidthOf(fitted)
  var text = fitted
  # Every step button stays reachable: in a pane too narrow for the words and
  # the buttons on one row, the buttons take the next.
  var buttonsWidth = 0
  for b in ShaderButton:
    buttonsWidth += cellWidthOf("[" & $b & "]")
  if col + buttonsWidth > right and row + 1 < area.row + area.height:
    result.painted.add text
    text = ""
    inc row
    col = area.col
  result.toolbarRow = row
  for b in ShaderButton:
    let label = "[" & $b & "]"
    let w = cellWidthOf(label)
    if col + w > right: break
    g.paint(row, col, label)
    result.buttons.add (button: b, col: col, width: w)
    col += w
    text.add label
  result.painted.add text
  inc row
  # The inspector's rows: the instruction, then each value.
  var inspector: seq[seq[StyledSpan]] = @[]
  inspector.add @[StyledSpan(text: "Instruction ", style: MutedStyle),
                  StyledSpan(text: m.instruction)]
  inspector.add @[StyledSpan(text: "Variables", style: HeaderStyle)]
  if m.variables.len == 0:
    inspector.add @[StyledSpan(text: "No variables", style: MutedStyle)]
  for v in m.variables:
    inspector.add @[StyledSpan(text: v.name & "  "),
                    StyledSpan(text: v.valueType & "  ", style: MutedStyle),
                    StyledSpan(text: v.value)]
  inspector.add @[StyledSpan(text: "Registers", style: HeaderStyle)]
  if m.registers.len == 0:
    inspector.add @[StyledSpan(text: "No registers", style: MutedStyle)]
  for v in m.registers:
    inspector.add @[StyledSpan(text: v.name & "  "),
                    StyledSpan(text: v.valueType & "  ", style: MutedStyle),
                    StyledSpan(text: v.value)]
  # The source takes what the inspector leaves, at least half the rest.
  let rest = bottom - row
  let sourceRows = max(min(m.sourceLines.len, rest - inspector.len),
                       min(m.sourceLines.len, rest div 2))
  result.sourceTop = row
  result.sourceRows = sourceRows
  # Keep the step's line in view.
  var first = 0
  if m.currentLine > 0 and sourceRows > 0 and m.currentLine > sourceRows:
    first = min(m.currentLine - (sourceRows div 2) - 1,
                max(0, m.sourceLines.len - sourceRows))
  for k in 0 ..< sourceRows:
    let n = first + k + 1
    if n > m.sourceLines.len: break
    let current = n == m.currentLine
    if current: result.currentRow = row
    let mark = if current: ">" else: " "
    result.painted.add g.paintSpans(row, area.col, area.width,
      @[StyledSpan(text: mark & align($n, 3) & " ", style: MutedStyle),
        StyledSpan(text: m.sourceLines[n - 1],
                   style: (if current: CurrentLineStyle
                           else: DefaultCellStyle))])
    inc row
  for spans in inspector:
    if row >= bottom: break
    result.painted.add g.paintSpans(row, area.col, area.width, spans)
    inc row

func shaderTargetAt*(s: ShaderDebugPaneScreen; row, col: int):
    VisualPaneTarget =
  if row != s.toolbarRow or row < 0:
    return VisualPaneTarget(kind: vtNone)
  for b in s.buttons:
    if col >= b.col and col < b.col + b.width:
      return VisualPaneTarget(kind: vtShaderButton, button: b.button)
  VisualPaneTarget(kind: vtNone)
