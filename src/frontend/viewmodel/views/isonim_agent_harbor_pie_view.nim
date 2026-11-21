## IsoNim view of the progress pie (`nim_agents_isonim_viewmodels/
## agent_harbor/progress_pie`): one indicator that shows an item's state by
## its colour and its progress by a wedge of the same colour.
##
## - `pieIndicator`: one pie, a `span.ah-pie` drawn by the stylesheet
##   (`styles/components/agent_harbor_pie.styl`) as a two-stop conic gradient
##   over the disc (CSS Images Level 4 §3.3,
##   https://www.w3.org/TR/css-images-4/#conic-gradients): the wedge in the
##   role's ink from twelve o'clock clockwise to the share done
##   (`--ah-pie-p`), hard against the rest of the disc, with a 1px inset
##   edge. The inks are custom properties per ground and role
##   (`agent_harbor_pie_inks.styl`, written from the palette's `pieInks`), so
##   the web draws the inks GPUI and the terminal draw. It is an image with
##   the pie's words as its accessible name (`role="img"`, `aria-label`).
## - `renderAgentHarborPieStory`: the story `Pie Indicator: Every State`,
##   every role at each share and with no known progress, on each ground
##   (`stories/agent_harbor_pie_stories`).
##
## The pie is not yet drawn by any panel, tab or line; those take it from
## here.

import std/strutils
when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../../stories/agent_harbor_pie_stories

export agent_harbor_pie_stories

const
  AgentHarborPieStoryClass* = "ah-pie-story"

proc pieClass*(pie: ProgressPie; ground: PieGround): string =
  ## The pie's classes: its role and its ground pick its inks, its shape
  ## (`pieShapeOf`) how it is drawn: `ah-pie-disc`, `ah-pie-hollow` (idle:
  ## the wedge inside the ring) or `ah-pie-unknown` (the ring and a dot).
  "ah-pie ah-pie-" & $pie.role & " ah-pie-on-" & $ground & " ah-pie-" & $pie.pieShapeOf

proc pieColumnClass*(column: int): string =
  ## A pie column's classes: every column centres its pie and its head
  ## (`ah-pie-col`), and each has its own width (`ah-pie-col-<n>`,
  ## `PieStoryColumnsPx`).
  "ah-pie-col ah-pie-col-" & $column

proc remOf(px: int): string =
  ## A size in px as rem against the 16px root (UI-Design-Decisions.md,
  ## Units): 12 -> `0.75rem`.
  result = formatFloat(px.float / 16.0, ffDecimal, 4)
  result.trimZeros()
  if result.endsWith("."): result.setLen(result.len - 1)
  result.add "rem"

proc pieStyle*(pie: ProgressPie; sizePx: int): string =
  ## The pie's size (in rem) and where its wedge ends.
  "width: " & remOf(sizePx) & "; height: " & remOf(sizePx) & "; --ah-pie-p: " &
    pie.pieStopPercent & ";"

proc pieIndicator*[R, N](r: R; pie: ProgressPie; ground: PieGround;
                         sizePx = PieStorySizePx): N =
  ## One pie on `ground`, `sizePx` across.
  mixin createElement, setAttribute, appendChild
  result = r.createElement("span")
  r.setAttribute(result, "class", pieClass(pie, ground))
  r.setAttribute(result, "style", pieStyle(pie, sizePx))
  r.setAttribute(result, "role", "img")
  r.setAttribute(result, "aria-label", pie.label)
  r.setAttribute(result, "title", pie.label)
  r.setAttribute(result, "data-ah-pie-role", $pie.role)
  r.setAttribute(result, "data-ah-pie-p", pie.pieStopPercent)
  if pie.pieShapeOf == psUnknown:
    # No known progress: the ring and a centred dot of the full ink.
    let dot = r.createElement("span")
    r.setAttribute(dot, "class", "ah-pie-dot")
    r.appendChild(result, dot)

proc renderAgentHarborPieStory*[R, N](r: R; fixture: string): N =
  ## The story: a head naming the columns, then one band per ground, each a
  ## title and one row per role.
  mixin createElement, setAttribute, appendChild, createTextNode
  proc cell(r: R; cls, text: string): N =
    result = r.createElement("span")
    r.setAttribute(result, "class", cls)
    if text.len > 0: r.appendChild(result, r.createTextNode(text))
  result = r.createElement("div")
  r.setAttribute(result, "class", AgentHarborPieStoryClass)
  let head = r.createElement("div")
  r.setAttribute(head, "class", "ah-pie-row ah-pie-head")
  r.appendChild(head, r.cell("ah-pie-label", ""))
  for i, column in PieStoryColumns:
    # The head is its own span, centred in the column over the pie, so its
    # box is the words' (the `pie-head-*` regions compare it with GPUI's).
    let c = r.cell(pieColumnClass(i), "")
    let word = r.cell("ah-pie-head-word", column)
    r.setAttribute(word, "data-ah-pie-head-word", column)
    r.appendChild(c, word)
    r.appendChild(head, c)
  r.appendChild(result, head)
  # Every ground has its band, and the stylesheet shows each in the modes
  # where its colour is its own (`agent_harbor_pie_inks.styl`): Dark draws
  # one band for the active tab and the selected row, which share a ground
  # there, titled with both. Each band carries its title in either mode.
  discard pieStoryBands(fixture, dmDark)   # refuses an unknown fixture
  let rows = pieStoryRows()
  for ground in PieGround:
    let b = r.createElement("div")
    r.setAttribute(b, "class", "ah-pie-band ah-pie-band-" & $ground)
    r.setAttribute(b, "data-ah-pie-ground", $ground)
    r.appendChild(b, r.cell("ah-pie-band-title ah-pie-title-dark",
                            bandOf(ground, dmDark).bandTitle))
    r.appendChild(b, r.cell("ah-pie-band-title ah-pie-title-light",
                            bandOf(ground, dmLight).bandTitle))
    let band = PieStoryBand(ground: ground, grounds: @[ground], rows: rows)
    for row in band.rows:
      let line = r.createElement("div")
      r.setAttribute(line, "class", "ah-pie-row")
      r.appendChild(line, r.cell("ah-pie-label", row.word))
      for i, pie in row.pies:
        let c = r.cell(pieColumnClass(i), "")
        r.appendChild(c, pieIndicator[R, N](r, pie, band.ground))
        r.appendChild(line, c)
      r.appendChild(b, line)
    r.appendChild(result, b)

when defined(js):
  proc mountAgentHarborPieStory*(container: isonim_dom.Element; fixture: string) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborPieStory[WebRenderer, isonim_dom.Element](WebRenderer(), fixture)))
