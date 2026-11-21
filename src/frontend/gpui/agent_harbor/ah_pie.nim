## gpui/agent_harbor/ah_pie.nim — the progress pie in GPUI: an item's state
## by its colour, its progress by a wedge of the same colour
## (`nim_agents_isonim_viewmodels/agent_harbor/progress_pie`).
##
## `drawPie` draws one pie as the web's `span.ah-pie` is drawn
## (`isonim_agent_harbor_pie_view.pieIndicator`), from the same style
## string: a round element whose `background-image` is the palette's
## two-stop conic gradient (`pieConicGradient`: the wedge from twelve
## o'clock clockwise to the share done, hard against the rest of the disc),
## which isonim-gpui paints as a sector over a disc, and over it a 1px ring
## in the edge's ink (the web's inset box-shadow). The inks are the
## palette's `pieInks` for the ground the pie sits on, the ones the web's
## stylesheet and the terminal use.
##
## Facts for a reader of the render plan: `data-ah-pie` (the role),
## `data-ah-pie-fraction` (the share done, or `unknown`), `data-ah-pie-label`
## and the `aria-label` (the pie's words), and the inks it was drawn in on
## its ground (`data-ah-pie-wedge`, `-rest`, `-edge`, `-ground`).
##
## `drawPieStory` draws the story `Pie Indicator: Every State` on the grid
## `stories/agent_harbor_pie_stories` states.

import std/[math, strutils]

import ./ah_theme
import ../../stories/agent_harbor_pie_stories

export agent_harbor_pie_stories

proc pieFractionFact*(pie: ProgressPie): string =
  ## The share a pie draws, as its fact says it: `unknown`, or the stop.
  if pie.known: pie.pieStopPercent else: "unknown"

proc drawPie*(r: GpuiRenderer; p: AhPalette; pie: ProgressPie; ground: string;
              sizePx = PieStorySizePx): GpuiElement =
  ## One pie on `ground` (`#rrggbb`), `sizePx` across, in its shape
  ## (`pieShapeOf`): a disc (the rest disc with the wedge as a two-stop conic
  ## gradient), hollow (idle: the gradient on a disc inset inside the ring,
  ## the ground between), or unknown (the ring and a centred dot, no rest).
  ## The edge ring is drawn over all three, as the web's inset box-shadow.
  let inks = p.pieInks(pie.role, ground)
  let shape = pie.pieShapeOf
  result = r.createElement("div")
  r.styles(result, [("width", $sizePx & "px"), ("height", $sizePx & "px"),
                    ("min-width", $sizePx & "px"), ("flex-shrink", "0"),
                    ("position", "relative"), ("border-radius", "50%")])
  proc pxOf(v: float): string =
    var t = formatFloat(v, ffDecimal, 2)
    t.trimZeros()
    if t.endsWith("."): t.setLen(t.len - 1)
    t & "px"
  proc layer(r: GpuiRenderer; inset, side: float): GpuiElement =
    result = r.createElement("div")
    r.styles(result, [("position", "absolute"), ("top", pxOf(inset)),
                      ("left", pxOf(inset)), ("width", pxOf(side)),
                      ("height", pxOf(side)), ("border-radius", "50%")])
  case shape
  of psDisc:
    r.setStyle(result, "background-image", inks.pieConicGradient(pie))
  of psHollow:
    let inset = round(sizePx.float * PieHollowInsetFraction)
    let disc = r.layer(inset, sizePx.float - 2.0 * inset)
    r.setStyle(disc, "background-image", inks.pieConicGradient(pie))
    r.appendChild(result, disc)
  of psUnknown:
    # Snapped to whole pixels, as the browser lays out the web's dot: a
    # 12 px pie's 3 px dot sits at 5 px (4.5 rounded half up), so its centre
    # row draws three pixels of the full ink. A dot at 4.5 px straddles four
    # pixels and draws about two.
    let side = round(sizePx.float * PieDotFraction)
    let dot = r.layer(floor((sizePx.float - side) / 2.0 + 0.5), side)
    # GPUI rounds a corner by a length, not a percentage: half the side.
    r.styles(dot, [("border-radius", pxOf(side / 2.0)), ("background", inks.wedge)])
    r.tag(dot, "pie-dot", "true")
    r.appendChild(result, dot)
  let edge = r.layer(0.0, sizePx.float)
  r.styles(edge, [("border-radius", $(sizePx div 2) & "px"),
                  ("border-width", "1px"), ("border-color", inks.edge)])
  r.appendChild(result, edge)
  r.setAttribute(result, "aria-label", pie.label)
  r.setAttribute(result, "role", "img")
  r.tag(result, "pie", $pie.role)
  r.tag(result, "pie-shape", $shape)
  r.tag(result, "pie-fraction", pie.pieFractionFact)
  r.tag(result, "pie-label", pie.label)
  r.tag(result, "pie-wedge", inks.wedge)
  r.tag(result, "pie-rest", inks.rest)
  r.tag(result, "pie-edge", inks.edge)
  r.tag(result, "pie-ground", ground)

proc drawPieStory*(r: GpuiRenderer; host: GpuiElement; fixture: string;
                   p: AhPalette; widthPx, heightPx: int) =
  ## The story in `host`, `widthPx` × `heightPx`: a head naming the
  ## columns, then a band per ground, each a title and a row per role.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", p.ground), ("overflow", "hidden"),
                  ("padding", $PieStoryInsetPx & "px")])
  r.tag(host, "surface", PieStorySurface)
  proc column(r: GpuiRenderer; i: int): GpuiElement =
    # A pie column centres its pie, and in the head its words over the pie
    # (`PieStoryColumnsPx`; the web's `.ah-pie-col-<n>`).
    let w = PieStoryColumnsPx[i]
    r.box(pairs = [("width", $w & "px"), ("min-width", $w & "px"),
                   ("flex-shrink", "0"), ("height", $PieStoryRowPx & "px"),
                   ("items", "center"), ("justify", "center")])
  proc label(r: GpuiRenderer; text, colour: string; bold = false): GpuiElement =
    result = r.box(pairs = [("width", $PieStoryLabelPx & "px"),
                            ("min-width", $PieStoryLabelPx & "px"), ("flex-shrink", "0"),
                            ("height", $PieStoryRowPx & "px"), ("items", "center"),
                            ("overflow", "hidden")])
    r.appendChild(result, r.text(text, CaptionPx, colour, bold = bold))
  let head = r.box(pairs = [("height", $PieStoryRowPx & "px"), ("flex-shrink", "0"),
                            ("padding-left", $PieStoryInsetPx & "px"),
                            ("padding-right", $PieStoryInsetPx & "px")])
  r.tag(head, "pie-head", "")
  let headInk = p.readableInk(p.ground)
  r.appendChild(head, r.label("", headInk))
  for i, name in PieStoryColumns:
    let c = r.column(i)
    let word = r.text(name, CaptionPx, headInk, shrink = false)
    r.tag(word, "pie-head-word", name)
    r.appendChild(c, word)
    r.appendChild(head, c)
  r.appendChild(host, head)
  for band in pieStoryBands(fixture, p.mode):
    let ground = p.pieGroundColour(band.ground)
    let b = r.box(column = true, pairs = [("flex-shrink", "0"), ("background", ground),
                                          ("margin-top", $PieStoryBandGapPx & "px"),
                                          ("padding-left", $PieStoryInsetPx & "px"),
                                          ("padding-right", $PieStoryInsetPx & "px")])
    r.tag(b, "pie-ground", $band.ground)
    let title = r.box(pairs = [("height", $PieStoryRowPx & "px"), ("flex-shrink", "0"),
                               ("items", "center")])
    let ink = p.readableInk(ground)
    r.appendChild(title, r.text(band.bandTitle, CaptionPx, ink,
                                bold = true, shrink = false))
    r.appendChild(b, title)
    for row in band.rows:
      let line = r.box(pairs = [("height", $PieStoryRowPx & "px"), ("flex-shrink", "0"),
                                ("items", "center")])
      r.tag(line, "pie-row", $row.role)
      r.appendChild(line, r.label(row.word, ink))
      for i, pie in row.pies:
        let c = r.column(i)
        r.appendChild(c, r.drawPie(p, pie, ground))
        r.appendChild(line, c)
      r.appendChild(b, line)
    r.appendChild(host, b)
