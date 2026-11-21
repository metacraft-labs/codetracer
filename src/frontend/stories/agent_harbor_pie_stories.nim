## stories/agent_harbor_pie_stories.nim — the data of the progress pie's
## story, `Pie Indicator: Every State`, shared by the three hosts that draw
## it (the web, `isonim_agent_harbor_pie_view.nim`; GPUI,
## `gpui/agent_harbor/ah_pie.nim`; the terminal,
## `tui/agent_harbor/ah_tui_pie.nim`).
##
## Every role at 0, 16, 50, 84 and 100 % and with no known progress, on each
## ground a pie sits on. Each pie is built by the viewmodels' own
## constructor (`progress_pie.pieOf`), from a session state and its plan's
## steps (`done` of `PieStoryTotal`), so the story shows what a real session
## in that state would carry. Plain data: no renderer, no viewmodel.

import nim_agents_isonim_viewmodels/agent_harbor/progress_pie
import ../viewmodel/views/agent_harbor_palette

export progress_pie, agent_harbor_palette

const
  PieStorySurface* = "agent-harbor-pie"
  PieStoryTotal* = 50
    ## The plan's steps: 0, 8, 25, 42 and 50 of them are 0, 16, 50, 84 and
    ## 100 %.
  PieStoryDone* = [0, 8, 25, 42, 50]
  PieStoryColumns* = ["0%", "16%", "50%", "84%", "100%", "unknown"]
    ## The columns' heads: the five shares, then no known progress.
  PieStoryStates* = [saNeedsInput, saRunning, saQueued, saFailed, saIdle, saEnded]
    ## One state for each role (`pieRoleOf`), in the order the rows go.
  PieStoryRowWords* = ["needs input", "running/working", "queued", "failed/blocked",
                       "idle", "ended/done"]
    ## Each row's name: the operator's words for the states its role stands
    ## for, a session's and an initiative's (the pie design's role table:
    ## running and working are success, failed and blocked error, ended and
    ## done the ended grey).
  PieStorySizePx* = 12
    ## A pie on a line (the line size of the pie's design).
  # The story's grid, in CSS pixels; the terminal draws it in cells
  # (`ah_tui_pie`). The web's stylesheet (`agent_harbor_pie.styl`) states the
  # same numbers. The whole grid fits the brief's 360px sidebar (328px inside
  # the story's and the band's insets) and its 45-cell terminal.
  PieStoryInsetPx* = 8       ## the story's inset, and a band's
  PieStoryLabelPx* = 104     ## the state words' column
  PieStoryColumnsPx* = [24, 32, 32, 34, 40, 60]
    ## Each pie column's width, a pie and its head centred in it. The widths
    ## keep every two neighbouring heads (`PieStoryColumns`, set in the
    ## caption face) `PieStoryHeadGapPx` apart: `84%` and `100%`, and
    ## `100%` and `unknown`, need wider columns than `0%` and `16%` do. They
    ## sum to 222 px, inside the 224 px the sidebar leaves after the words.
  PieStoryHeadGapPx* = 8     ## the least space between two columns' heads
  PieStoryRowPx* = 16        ## a row, the head and a band's title
  PieStoryBandGapPx* = 4     ## between two bands

type
  PieStoryRow* = object
    word*: string            ## the state's word
    role*: PieRole
    pies*: seq[ProgressPie]  ## one per column

  PieStoryBand* = object
    ground*: PieGround
      ## The ground the band is drawn on: the first of `grounds`.
    grounds*: seq[PieGround]
      ## Every ground the band stands for: those the mode resolves to one
      ## colour (Dark's active tab and selected row are both `#3c3c3c`), so
      ## each distinct ground is shown once.
    rows*: seq[PieStoryRow]

proc pieColumnCentrePx*(column: int): float =
  ## Where a pie column's centre is, from the start of the first column: the
  ## pie and the column's head are both centred there.
  for i in 0 ..< column: result += PieStoryColumnsPx[i].float
  result += PieStoryColumnsPx[column].float / 2.0

proc pieStoryRows*(): seq[PieStoryRow] =
  for state in PieStoryStates:
    var row = PieStoryRow(word: PieStoryRowWords[result.len], role: pieRoleOf(state))
    for done in PieStoryDone: row.pies.add pieOf(state, done, PieStoryTotal)
    row.pies.add pieOf(state, 0, 0)
    result.add row

proc pieStoryBands*(fixture: string; mode: DesignMode): seq[PieStoryBand] =
  ## The story's bands in `mode`: one per distinct ground colour, in
  ## `PieGround`'s order, each naming every ground it stands for.
  ## `every-state` is the only fixture.
  if fixture != "every-state":
    raise newException(ValueError, "the pie story has no fixture '" & fixture & "'")
  let rows = pieStoryRows()
  let p = ahPalette(mode)
  for ground in PieGround:
    var merged = false
    for band in result.mitems:
      if p.pieGroundColour(band.ground) == p.pieGroundColour(ground):
        band.grounds.add ground
        merged = true
    if not merged:
      result.add PieStoryBand(ground: ground, grounds: @[ground], rows: rows)

proc bandShown*(ground: PieGround; mode: DesignMode): bool =
  ## Whether `ground` starts a band of its own in `mode` (else an earlier
  ## band of the same colour stands for it).
  ahPalette(mode).pieGroundShown(ground)

proc groundWord*(ground: PieGround): string =
  ## A band's name.
  case ground
  of pgWindow: "Window"
  of pgPanel: "Panel"
  of pgActiveTab: "Active tab"
  of pgSelectedRow: "Selected row"
  of pgMenu: "Menu"

proc bandTitle*(band: PieStoryBand): string =
  ## A band's title: every ground it stands for (`Active tab / Selected row`).
  for i, g in band.grounds:
    if i > 0: result.add " / "
    result.add groundWord(g)

proc bandOf*(ground: PieGround; mode: DesignMode): PieStoryBand =
  ## The band that stands for `ground` in `mode`.
  for band in pieStoryBands("every-state", mode):
    if ground in band.grounds: return band
