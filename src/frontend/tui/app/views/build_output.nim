## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/build_output_source.paneModelOf` turns the
## window's shared `BuildVM` into the model below).
##
## app/views/build_output.nim — PLAT-16, PLAT-56. Edit mode's `paneBuildOutput`.
##
## A PANE AND NOT A MODAL, which is CodeTracer-TUI-Edit-Mode.md §5's decision
## verbatim: *"Failure output belongs in a pane, not a modal. A compiler error
## list is something a user navigates while editing, which is the argument for
## `paneBuildOutput` over an overlay."*
##
## ## PLAT-56: THE DESKTOP'S PANE, DRAWN (Build-Output-Pane.md §3.13)
##
## The desktop's BUILD panel (`viewmodel/views/isonim_build_view.nim`) draws a
## header — the verdict on the left ("running <command>", "build succeeded",
## "build failed (exit code N)", "build cancelled"), and on the right the
## history picker, Run, Stop, Clear, the auto-scroll toggle and the duration —
## over the output, each line in its compiler's colours (`BuildOutputLine.runs`,
## the SGR decoded by the shared scanner), a stderr line in the error colour,
## italic, and a line that names a location in its severity's colour, a jump
## target. With no build, "No build has run.". This pane draws the same parts
## in the same order with the same words — every one the ViewModel's
## (`build_output_model`) — the controls as words, since a terminal has no
## icon font (their titles are the desktop's tooltips). The history picker,
## opened, lists the builds under the header as the desktop's does.
##
## THE VERDICT IS IN WORDS AND IN A COLOUR, both. A `regionText` read carries
## no colour, so a verdict expressed only in the palette would be invisible to
## a Tier-2 read; a verdict expressed only in words would be invisible to
## somebody skimming.
##
## The rightmost column is the output's scrollbar when it overflows (the shared
## list scrubber, moving the VIEW); the bottom row its horizontal bar when a
## line is wider than the pane (PLAT-70).

import codetracer_embed

import ../build_session
import ../layout/profile
import ../layout/project
import ./styled_row
import ./scrubber_track

export styled_row, profile, build_session, scrubber_track

type
  BuildControl* = enum
    ## The header's controls, in the desktop's order.
    bcHistory, bcRun, bcStop, bcClear, bcFollow

  BuildPaneModel* = object
    ## Everything the build pane shows, as a value.
    loaded*: bool
      ## Whether a host filled it from the window's `BuildVM`
      ## (`host/build_output_source`); else the pane draws the runner's
      ## session directly (`buildPaneModelFor`).
    status*: BuildStatus
      ## The SHOWN build's verdict (the core's, `bsCancelled` included).
    headline*: string
      ## The header's words (`build_output_model.headerText`).
    duration*: string
      ## `durationText`: the elapsed time while running, "in 3.2s" after.
    output*: seq[BuildOutputLine]
      ## The shown build's lines: text, styled runs, stream, location.
    generation*: int
      ## Which build `output` is (its number) — a new build is measured from
      ## nothing again (PLAT-70 §4.1).
    truncated*: bool
      ## Whether the runner dropped the build's earliest output.
    running*: bool
      ## Whether the CURRENT build is running (Stop's state).
    follow*: bool
      ## The auto-scroll toggle (`BuildVM.autoScroll`).
    history*: seq[string]
      ## The picker's entries — the current build first, then the history,
      ## newest first — or none when no build ended before the current one.
    historyShown*: int
      ## Which entry of `history` the pane shows.
    historyOpen*: bool
    scrollTop*: int
      ## The first output line shown (the pane's own reading position).
    hview*: HorizontalView
      ## PLAT-70 (Horizontal-Overflow.md §4): the output's horizontal view —
      ## the pane's own (`BuildView`), its content the widest line measured
      ## so far of this build.
    overflowMarkers*: bool
      ## `view.overflow-markers` (§4.6).

  BuildView* = object
    ## PLAT-70: what the pane keeps across frames — the view, and the widest
    ## line measured so far of the build it is showing (§4.1).
    hview*: HorizontalView
    widths*: ContentWidth

  BuildPaneTargetKind* = enum
    btNone, btControl, btHistoryItem, btLine, btTrack, btText

  BuildPaneTarget* = object
    kind*: BuildPaneTargetKind
    control*: BuildControl
    index*: int
      ## btHistoryItem: the entry (0 the current build); btLine: the output
      ## line.

  BuildPaneCommandKind* = enum
    ## What the pane asks its host to do (`TuiApp.buildCommand`).
    bpcRun        ## run the build again (the desktop's Run)
    bpcStop       ## stop the running build
    bpcClear      ## clear the current build's output
    bpcFollow     ## toggle auto-scroll
    bpcHistory    ## open / close the history picker
    bpcShow       ## show history entry `index` (0 the current build)
    bpcOpen       ## open output line `index`'s location (K35)

  BuildPaneScreen* = object
    rows*: seq[StyledRow]
    controlsRow*: int
      ## The row the controls are drawn on (the verdict's, or the next), -1
      ## for none.
    area*: CellArea
    renderedLines*: int
    barRow*: int
      ## PLAT-70: the horizontal bar's row, -1 when the output fits.
    controls*: seq[tuple[control: BuildControl; col, width: int]]
      ## Each header control as drawn.
    menuTop*, menuRows*: int
      ## The open history picker's rows (0 when closed).
    listTop*, listRows*: int
      ## The output's rows.
    first*: int
      ## The first output line drawn.
    trackCol*: int
      ## The scrollbar's column, -1 when the output fits.
    painted*: seq[string]
      ## Every painted output row's text, in order (for the suites).

const
  BuildControlLabels*: array[BuildControl, string] =
    ["History ▾", "Run", "Stop", "Clear", "Follow"]
    ## The controls as words; their titles are the desktop's
    ## (`BuildControlTitles`).
  BuildControlGap = 1
  BuildOutputStyle* = CellStyle(role: srChromeText)
  BuildStderrStyle* = CellStyle(role: srChromeError, italic: true)
    ## The desktop's `.build-stderr`: the error text colour, italic.
  BuildTruncatedStyle* = CellStyle(role: srChromeNotification, italic: true)
  BuildControlStyle = CellStyle(role: srChromeText)
  BuildActiveControlStyle = CellStyle(role: srChromeText, bold: true)
  BuildDisabledControlStyle = CellStyle(role: srChromeMuted)
  BuildDurationStyle = CellStyle(role: srChromeMuted)
  BuildEmptyStyle = CellStyle(role: srChromeMuted)
  BuildMenuStyle = CellStyle(role: srChromeText)
  BuildMenuActiveStyle = CellStyle(role: srChromeText, bold: true)
  TruncatedNote* = canonical(grTruncation) & " earlier output dropped"

proc verdictStyle*(verdict: BuildVerdict): CellStyle =
  ## ONE COLOUR PER VERDICT, NO TWO THE SAME, on exactly the rule
  ## `status_bar.modeStyle` states: a Tier-2 case reads the cell's colour to
  ## say which verdict it is looking at, and two verdicts sharing a colour
  ## would be indistinguishable to that assertion.
  case verdict
  of bvIdle: CellStyle(role: srBuildIdle)
  of bvRunning: CellStyle(role: srBuildRunning)
  of bvSucceeded: CellStyle(role: srBuildSucceeded)
  of bvFailed: CellStyle(role: srBuildFailed)
  of bvCancelled: CellStyle(role: srBuildCancelled)

proc statusStyle*(status: BuildStatus): CellStyle =
  ## `verdictStyle` for the core's verdict.
  case status
  of bsIdle: verdictStyle(bvIdle)
  of bsRunning: verdictStyle(bvRunning)
  of bsSucceeded: verdictStyle(bvSucceeded)
  of bsFailed: verdictStyle(bvFailed)
  of bsCancelled: verdictStyle(bvCancelled)

proc lineStyle*(line: BuildOutputLine): CellStyle =
  ## A line's own colour (the desktop's line classes): a located line its
  ## severity's, stderr the error colour in italic, stdout the text colour.
  if line.located:
    case line.severity
    of blsError: CellStyle(role: srChromeError)
    of blsWarning: CellStyle(role: srChromeNotification)
    of blsInfo, blsNone: BuildOutputStyle
  elif line.isStdout: BuildOutputStyle
  else: BuildStderrStyle

proc runStyle*(line: BuildOutputLine; run: BuildRun): CellStyle =
  ## A run's cell style: the line's colour, under the colours and attributes
  ## the compiler wrote (a literal colour wins over the role, as `ansi_up`'s
  ## inline style wins over the line's class).
  result = lineStyle(line)
  let (fg, bg) = drawnColours(run.style)
  if fg.kind != tckDefault:
    result.fg = termHex(fg)
    result.role = srNone
  if bg.kind != tckDefault:
    result.bg = termHex(bg)
  if run.style.bold: result.bold = true
  if run.style.italic: result.italic = true
  if run.style.underline or run.style.strike: result.underline = true

proc snapshotOfSession*(s: BuildSession): BuildSnapshot =
  ## A `BuildSession` (the runner's) as the shared model's snapshot, its lines
  ## read by a fresh `BuildLineReader` — what a pane with no host ViewModel
  ## draws, in the same words.
  if s.isNil:
    return BuildSnapshot(status: bsIdle)
  var reader: BuildLineReader
  result = BuildSnapshot(number: 1, noun: $s.kind, command: s.command,
                         status: statusOf(s.verdict), code: s.exitCode,
                         startMs: float(s.startedMs),
                         endMs: float(s.endedMs), latest: true)
  for i, line in s.lines:
    let read = reader.read(line, isStdout = not s.isStderr(i))
    result.output.add read.line
    if read.fed.problem:
      result.problems.add read.fed.row

proc initBuildPaneModel*(): BuildPaneModel =
  BuildPaneModel(status: bsIdle, follow: true)

proc buildPaneModelFor*(s: BuildSession; nowMs = 0.0): BuildPaneModel =
  ## The pane for the runner's session when no host ViewModel is attached.
  let snap = snapshotOfSession(s)
  BuildPaneModel(status: snap.status, headline: snap.headerText,
                 duration: snap.durationText(nowMs), output: snap.output,
                 generation: (if s.isNil: 0 else: cast[int](s)),
                 truncated: not s.isNil and s.truncated,
                 running: snap.status == bsRunning, follow: true)

proc measureContent*(v: var BuildView; model: BuildPaneModel) =
  ## §4.1: the widest line measured so far of THIS build — a new build (a
  ## new generation) starts again from nothing; the same one only grows.
  var lines: seq[string] = @[]
  for line in model.output:
    lines.add line.text
  v.hview.setContent(v.widths.measureLines(model.generation, lines,
                                           cellWidthOf))

proc controlsWidth(model: BuildPaneModel; withDuration = true): int =
  for c in BuildControl:
    if c == bcHistory and model.history.len == 0:
      continue
    result += cellWidthOf(BuildControlLabels[c]) + BuildControlGap
  if withDuration and model.duration.len > 0:
    result += cellWidthOf(model.duration)
  else:
    result -= BuildControlGap

proc headerLayout*(model: BuildPaneModel; width, height: int):
    tuple[rows: int; controlsRow: int; withDuration: bool; cw: int] =
  ## The header: the verdict on the left, the controls (and the duration, the
  ## first to go when the row is short) on the right — on the verdict's row
  ## while the whole verdict fits beside them, else on a row of their own
  ## beneath it (a narrow pane keeps both, the verdict uncut). No controls at
  ## all when even their own row is too narrow.
  let room = width - 1 - cellWidthOf(model.headline)
  if model.controlsWidth(true) <= room:
    return (1, 0, true, model.controlsWidth(true))
  if model.controlsWidth(false) <= room:
    return (1, 0, false, model.controlsWidth(false))
  if height >= 4:
    if model.controlsWidth(true) <= width:
      return (2, 1, true, model.controlsWidth(true))
    if model.controlsWidth(false) <= width:
      return (2, 1, false, model.controlsWidth(false))
  (1, -1, false, 0)

proc outputGeometry*(model: BuildPaneModel; area: CellArea):
    tuple[menuTop, menuRows, top, rows: int; barShown: bool; barRow: int;
          trackCol, width: int; view: HorizontalView] =
  ## Where the pane's parts go inside `area`: the header row, the open
  ## picker's rows, the truncation note, the output's rows, its scrollbar
  ## column and its horizontal bar.
  var row = area.row + headerLayout(model, area.width, area.height).rows
  let menuRows = if model.historyOpen and model.history.len > 0:
                   min(model.history.len, max(0, area.height - 2))
                 else: 0
  result.menuTop = row
  result.menuRows = menuRows
  row += menuRows
  if model.truncated and row < area.row + area.height:
    inc row
  let idle = model.status == bsIdle and model.output.len == 0
  if idle and row < area.row + area.height:
    inc row
  var view = model.hview
  view.setViewport(area.width)
  let barShown = view.overflows and area.height >= 3
  let last = area.row + area.height - 1 - (if barShown: 1 else: 0)
  result.top = row
  result.rows = max(0, last - row + 1)
  result.barShown = barShown
  result.barRow = if barShown: area.row + area.height - 1 else: -1
  result.width = area.width
  result.trackCol = -1
  if model.output.len > result.rows and result.rows > 0:
    result.width = max(0, area.width - ScrubberTrackCells)
    result.trackCol = area.col + area.width - ScrubberTrackCells
    view.setViewport(result.width)
  result.view = view

proc clampBuildTop*(total, top, rows: int): int =
  clamp(top, 0, max(0, total - max(1, rows)))

proc buildBarOf*(model: BuildPaneModel; area: CellArea):
    tuple[shown: bool; row, left, cols: int; view: HorizontalView] =
  ## PLAT-70: where `paintBuildOutput` draws the horizontal bar in `area`
  ## (the rows below the strip), and the view it is drawn over.
  let geo = model.outputGeometry(area)
  (shown: geo.barShown, row: geo.barRow, left: area.col, cols: geo.width,
   view: geo.view)

proc paintBuildOutput*(g: var StyledGrid; area: CellArea;
                       model: BuildPaneModel): BuildPaneScreen =
  result = BuildPaneScreen(rows: @[], area: area, renderedLines: 0,
                           barRow: -1, trackCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0 (PLAT-49: no title bar — the tab strip names the pane): the
  # verdict on the left, the controls and the duration on the right, when
  # they fit beside the verdict.
  # (`headerLayout`: on the verdict's row, or on their own beneath it.)
  let hl = headerLayout(model, area.width, area.height)
  let withDuration = hl.withDuration
  let cw = hl.cw
  var leftCells = area.width
  let crow = area.row + hl.controlsRow
  if hl.controlsRow >= 0:
    if hl.controlsRow == 0:
      leftCells = area.width - cw - 1
    var col = area.col + area.width - cw
    for c in BuildControl:
      if c == bcHistory and model.history.len == 0:
        continue
      let label = BuildControlLabels[c]
      let w = cellWidthOf(label)
      let style =
        case c
        of bcStop: (if model.running: BuildControlStyle
                    else: BuildDisabledControlStyle)
        of bcFollow: (if model.follow: BuildActiveControlStyle
                      else: BuildControlStyle)
        of bcHistory: (if model.historyShown > 0 or model.historyOpen:
                         BuildActiveControlStyle
                       else: BuildControlStyle)
        else: BuildControlStyle
      g.paint(crow, col, label, style)
      result.controls.add (control: c, col: col, width: w)
      col += w + BuildControlGap
    if withDuration and model.duration.len > 0:
      g.paint(crow, col, model.duration, BuildDurationStyle)
  result.controlsRow = (if hl.controlsRow >= 0: crow else: -1)
  var head: seq[StyledSpan] = @[]
  if model.headline.len > 0:
    let t = truncateToCells(model.headline, leftCells)
    g.paint(area.row, area.col, t, statusStyle(model.status))
    head.add StyledSpan(text: t, style: statusStyle(model.status))
  result.rows.add head

  let geo = model.outputGeometry(area)
  # The history picker, open: the builds, the shown one marked.
  result.menuTop = geo.menuTop
  result.menuRows = geo.menuRows
  for k in 0 ..< geo.menuRows:
    let shown = k == model.historyShown
    let text = (if shown: "● " else: "  ") & model.history[k]
    let t = truncateToCells(text, area.width)
    g.paint(geo.menuTop + k, area.col, t,
            if shown: BuildMenuActiveStyle else: BuildMenuStyle)
    result.rows.add @[StyledSpan(text: t, style: BuildMenuStyle)]
  var row = geo.menuTop + geo.menuRows
  if model.truncated and row < geo.top:
    let note = g.glyphText(grTruncation) & " earlier output dropped"
    g.paint(row, area.col, truncateToCells(note, area.width),
            BuildTruncatedStyle)
    result.rows.add @[StyledSpan(text: note, style: BuildTruncatedStyle)]
    inc row
  if model.status == bsIdle and model.output.len == 0 and row < geo.top:
    let t = truncateToCells(BuildIdleText, area.width)
    g.paint(row, area.col, t, BuildEmptyStyle)
    result.rows.add @[StyledSpan(text: t, style: BuildEmptyStyle)]
  result.listTop = geo.top
  result.listRows = geo.rows
  result.trackCol = geo.trackCol
  let view = geo.view
  let first = clampBuildTop(model.output.len, model.scrollTop, geo.rows)
  result.first = first
  for k in 0 ..< geo.rows:
    let i = first + k
    if i >= model.output.len:
      break
    let line = model.output[i]
    let y = geo.top + k
    # The line's runs, cut to the view's columns [leftCol, leftCol + width).
    var at = 0
    var col = area.col
    var spans: seq[StyledSpan] = @[]
    var shownText = ""
    let lo = view.leftCol
    let hi = view.leftCol + geo.width
    for run in line.runs:
      let w = cellWidthOf(run.text)
      let s0 = max(at, lo)
      let s1 = min(at + w, hi)
      if s1 > s0:
        let piece = cellSlice(run.text, s0 - at, s1 - at)
        let style = runStyle(line, run)
        g.paint(y, col, piece, style)
        col += cellWidthOf(piece)
        shownText.add piece
        spans.add StyledSpan(text: piece, style: style)
      at += w
    if model.overflowMarkers:
      paintOverflowMarkers(g, y, area.col, cellWidthOf(line.text), view)
    result.rows.add spans
    result.painted.add shownText
    inc result.renderedLines
  if geo.trackCol >= 0:
    g.paintVerticalScrubber(geo.trackCol, geo.top, geo.rows,
      scrubberModel(model.output.len, first, geo.rows))
  if geo.barShown:
    result.barRow = geo.barRow
    paintHorizontalBar(g, geo.barRow, area.col, geo.width, view.barModel)

proc buildTargetAt*(model: BuildPaneModel; screen: BuildPaneScreen;
                    area: CellArea; row, col: int): BuildPaneTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return BuildPaneTarget(kind: btNone, index: -1)
  if row == screen.controlsRow:
    for c in screen.controls:
      if col >= c.col and col < c.col + c.width:
        return BuildPaneTarget(kind: btControl, control: c.control, index: -1)
  if row == area.row or row == screen.controlsRow:
    return BuildPaneTarget(kind: btNone, index: -1)
  if screen.menuRows > 0 and row >= screen.menuTop and
     row < screen.menuTop + screen.menuRows:
    return BuildPaneTarget(kind: btHistoryItem, index: row - screen.menuTop)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return BuildPaneTarget(kind: btTrack, index: -1)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return BuildPaneTarget(kind: btNone, index: -1)
  let i = screen.first + (row - screen.listTop)
  if i < 0 or i >= model.output.len:
    return BuildPaneTarget(kind: btNone, index: -1)
  if model.output[i].located:
    BuildPaneTarget(kind: btLine, index: i)
  else:
    BuildPaneTarget(kind: btText, index: i)
