## viewmodels/scrollbar_scrubber.nim — a list pane's scrollbar as a SCRUBBER
## over the whole population it lists.
##
## Spec: `codetracer-specs/spec/GUI/Layout-And-Navigation/Scrollbar-Scrubbers.md`
## §3 — "One pure, medium-independent model in the ViewModel layer answers,
## for a pane: the population total, the first visible row, the visible row
## count, the thumb's start and length as fractions of the track, the row a
## fraction of the track names, and the window to fetch for it. Every
## front-end projects those fractions onto its own track ... and feeds pointer
## positions back as fractions. No front-end computes a row from a pointer
## itself."
##
## PLAT-52 is the first pane to adopt it (the Terminal Output pane's line
## view, whose population is the recorded output's lines). The Event Log and
## Call Trace adopt the same model (PLAT-51); nothing here is specific to a
## pane. The window to fetch and the drag's coalesced fetches (§3.3) arrive
## with the first pane that FETCHES its rows: the Terminal Output pane holds
## every line it lists.
##
## Pure, and compiled for both backends.

import std/math

type
  ScrubberModel* = object
    total*: int
      ## The WHOLE population (after the pane's filter) — never the rows a
      ## front-end happens to hold.
    totalKnown*: bool
      ## False until the backend has answered with a total: the track then
      ## draws an indeterminate thumb rather than pretending the loaded rows
      ## are the population (§3.1).
    firstVisible*: int
      ## The row at the top of the view.
    visible*: int
      ## How many rows the view shows.
    current*: int
      ## The row of the CURRENT recording position (§3.5's mark), -1 for none.

  ThumbSpan* = object
    ## The thumb in TRACK UNITS (pixels, or eighths of a cell).
    start*: int
    length*: int

func scrubberModel*(total, firstVisible, visible: int; current = -1;
                    totalKnown = true): ScrubberModel =
  ScrubberModel(total: max(0, total), totalKnown: totalKnown,
                firstVisible: max(0, firstVisible), visible: max(0, visible),
                current: current)

func maxFirstVisible*(m: ScrubberModel): int =
  max(0, m.total - m.visible)

func thumbStart*(m: ScrubberModel): float =
  ## Where the thumb starts, as a fraction of the track: `firstVisible /
  ## total`.
  if m.total <= 0 or not m.totalKnown: 0.0
  else: max(0.0, min(1.0, float(min(m.firstVisible, m.maxFirstVisible)) /
                           float(m.total)))

func thumbLength*(m: ScrubberModel): float =
  ## The thumb's length as a fraction of the track: `visible / total`.
  if m.total <= 0 or not m.totalKnown: 1.0
  else: max(0.0, min(1.0, float(m.visible) / float(m.total)))

func thumbSpan*(m: ScrubberModel; trackUnits, minUnits: int): ThumbSpan =
  ## The thumb projected onto a track of `trackUnits`, at least `minUnits`
  ## long (the smallest thumb the front-end can hit) and never leaving the
  ## track.
  if trackUnits <= 0:
    return ThumbSpan()
  let length = min(trackUnits,
                   max(min(minUnits, trackUnits),
                       int(round(m.thumbLength * float(trackUnits)))))
  var start = int(round(m.thumbStart * float(trackUnits)))
  start = max(0, min(trackUnits - length, start))
  ThumbSpan(start: start, length: length)

func rowAtFraction*(m: ScrubberModel; fraction: float): int =
  ## The row a pointer at `fraction` (0..1) of the track names:
  ## `round(fraction * (total - 1))`.
  if m.total <= 0: return 0
  let f = max(0.0, min(1.0, fraction))
  int(round(f * float(m.total - 1)))

func firstVisibleFor*(m: ScrubberModel; row: int): int =
  ## The first visible row that CENTRES `row` in the view, clamped at the ends
  ## (§3.2: a click on the track scrolls so that the row at the clicked
  ## fraction is centred).
  max(0, min(m.maxFirstVisible, row - m.visible div 2))

func clickAt*(m: ScrubberModel; fraction: float): int =
  ## §3.2 — a click on the track: the new first visible row.
  m.firstVisibleFor(m.rowAtFraction(fraction))

func dragTo*(m: ScrubberModel; thumbStartFraction: float): int =
  ## §3.3 — the thumb dragged so it starts at `thumbStartFraction`: the new
  ## first visible row, following the thumb continuously.
  if m.total <= 0: return 0
  let f = max(0.0, min(1.0, thumbStartFraction))
  max(0, min(m.maxFirstVisible, int(round(f * float(m.total)))))

func currentFraction*(m: ScrubberModel): float =
  ## Where the current-position mark sits on the track (the middle of its
  ## row's span), -1.0 when there is no current row.
  if m.current < 0 or m.total <= 0: -1.0
  else: max(0.0, min(1.0, (float(m.current) + 0.5) / float(m.total)))

func fractionAt*(pos, trackUnits: int): float =
  ## A pointer `pos` units into a track of `trackUnits`, as the fraction the
  ## model takes: the CENTRE of the unit it is on.
  if trackUnits <= 0: 0.0
  else: max(0.0, min(1.0, (float(pos) + 0.5) / float(trackUnits)))
