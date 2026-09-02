## views/debug_control_marks.nim
##
## The debugger toolbar's marks, as inline SVG that inherits the button's
## `color`.
##
## ## Why this module exists
##
## These twelve marks used to be twelve `.svg` files pulled in by
## `background-image` through `ct-images-*` variables that ONLY
## `default_dark_theme.styl` defined, each painting `#DDDDDD` — a near-white
## chosen for a dark background.
##
## Two things were wrong with that, and the second is worse than reported.
## The colour was inside the asset, so it could not follow a theme; and the
## white theme defined none of the twelve variables. Stylus passes an unknown
## identifier through as a bare literal rather than failing, so the built
## white stylesheet carried `background-image: ct-images-continue` — a
## declaration no browser can parse and every browser drops. Measured on the
## compiled CSS: 33 such declarations in the white theme, twelve of them this
## strip's. So the most-used control strip in the product did not render
## faint marks on that theme. It rendered twelve blank buttons.
##
## Ten were named `*_dark`, which at least admitted what they were for. The
## other two were named `*_black` and stroked `#DDDDDD` anyway, so the
## filename said the opposite of the file. That is the second reason not to
## fix this with a `*_light` twin: it keeps the colour in a place whose only
## label is a filename, two sets drift, and the next theme needs a third. So
## the marks are drawn HERE, as SVG whose `fill`/`stroke` is
## `currentColor` — no colour in the file at all. The button
## already has a themed `color` (`components/button.styl`: the `-secondary`
## rule sets `colors-ui-text-primary-body-subtle`, `:hover` and
## `:focus-visible` raise it to `colors-ui-text-primary-body`, and `:disabled`
## drops it to `colors-ui-text-disabled-default`). Inheriting that colour is
## what gives the marks a themed appearance AND the enabled-versus-inert
## contrast treatment, with no second rule and no second asset.
##
## BlockTracer's control strip was reworked the same way and for the same
## reason (`client/src/components/icons.nim`, `dev` e8c8f34). The two products
## share a user who moves between them, so the geometry below is byte-identical
## to BlockTracer's.
##
## ## What the marks are
##
## Five are VS Code codicons, `d` verbatim (CC BY 4.0, microsoft/vscode-
## codicons): `debug-continue`, `debug-reverse-continue`, `debug-step-over`,
## `debug-step-back` and `debug-restart`. Four are drawn, because no product
## ships a reverse step in/out — DAP defines only `stepBack` and
## `reverseContinue`, so the gap propagates everywhere, and CodeTracer has all
## four controls. They put the arrow on a diagonal so the family's rule ("a
## reverse mark is its forward partner reflected", microsoft/vscode#85111) has
## a handedness to act on, and they share `debug-step-over`'s dot — Microsoft's
## "modifier badge" — so the six step marks have one anchor.
##
## The remaining three — the two history chevrons and the reset arc — keep
## their existing geometry exactly. They are here because they sit on the same
## strip and had the same defect, not because their shapes were wrong.
##
## ## `run-to-entry` is a restart, so it wears a restart's mark
##
## It used to be a play triangle beside a stack of lines: a transport control,
## and the last one on this bar. That is the same reading a user reported
## against BlockTracer's Continue — "continue looks like the standard icon of
## music/video players for 'rewind to the end'". A bar-plus-triangle carries
## its meaning in the ARRANGEMENT: across VS Code, Chrome DevTools, JetBrains,
## Visual Studio, Xcode and Eclipse CDT the bar sits BEHIND the direction of
## travel, marking where execution is stopped, and no product puts it ahead —
## which is exactly what makes the media glyph mean "skip to the end".
##
## But `run-to-entry` is not a resume at all. It is DAP `restart` (`ct-dap.md`:
## "`restart` | none | `{}` | Mapped to `ct/run-to-entry`"), and the mark for a
## restart is a circular arrow in every product surveyed: VS Code binds Restart
## to `debug-restart`, which carries no triangle geometry whatsoever; JetBrains'
## `actions/restart.svg` is a triangle wrapped in a ~270° arc; Visual Studio's
## Restart is a curved arrow; and the circular arrow in Chrome's chrome is
## reload. The codicon set keeps the two apart deliberately — `debug-start` is
## a bare triangle, `debug-restart` is a bare arc — so a bare triangle here
## would read as "start/continue" and collide with `debug-continue` two buttons
## away. `debug-restart` it is.

import std/strutils

# ---------------------------------------------------------------------------
# The marks
# ---------------------------------------------------------------------------

type
  ControlShape* = object
    ## One `<path>` of a mark.
    ##
    ## `stroked` picks which channel `currentColor` lands in, because the
    ## marks below are built two ways: the codicons are solid outlines
    ## (filled), and the drawn ones are strokes, sometimes over a filled dot.
    ## Neither ever names a colour — that is the whole point of this module —
    ## so the channel and the width are the only things that vary.
    d*: string
    stroked*: bool
    strokeWidth*: string

  ControlMark* = object
    ## A mark, and the control it belongs on.
    ##
    ## `buttonId` is the element id in `isonim_debug_controls_view`, and
    ## `action` is the command that button sends. Keeping them in one record
    ## is what lets a check say "this glyph is on the control that sends this
    ## command" rather than "the bar has twelve glyphs" — a bar of twelve
    ## correct-looking buttons can still carry a mark on the wrong one, and
    ## that is invisible from the shapes alone.
    ##
    ## `viewBox` is per-mark because one of them is not square: the reset
    ## mark was drawn `0 0 16 17` and is carried across verbatim rather than
    ## redrawn, since this change is about where its COLOUR comes from.
    buttonId*: string
    action*: string
    viewBox*: string
    shapes*: seq[ControlShape]

const DefaultViewBox = "0 0 16 16"

func filled(d: string): ControlShape =
  ControlShape(d: d, stroked: false)
func stroked(d: string; width = "1.6"): ControlShape =
  ControlShape(d: d, stroked: true, strokeWidth: width)

const
  StepBadgePath = "M10 13C10 14.103 9.103 15 8 15C6.897 15 6 14.103 6 13C6 " &
    "11.897 6.897 11 8 11C9.103 11 10 11.897 10 13Z"
    ## The dot the six step marks share — `debug-step-over`'s "modifier
    ## badge", recentred. It is the family's one anchor: it is what says
    ## "this control moves by a step" before the arrow says which way.

  ContinuePath = "M14.578 7.149L7.578 2.186C7.397 2.058 7.198 2 7.003 2C6.4" &
    "84 2 6 2.411 6 3.002V13.003C6 13.594 6.485 14.005 7.004 14.005C7.201 1" &
    "4.005 7.403 13.946 7.585 13.815L14.585 8.777C15.142 8.376 15.139 7.546" &
    " 14.579 7.15L14.578 7.149ZM7.5 12.027V3.969L13.14 7.968L7.5 12.027ZM3." &
    "5 2.75V13.25C3.5 13.664 3.164 14 2.75 14C2.336 14 2 13.664 2 13.25V2.7" &
    "5C2 2.336 2.336 2 2.75 2C3.164 2 3.5 2.336 3.5 2.75Z"
    ## `debug-continue`. A triangle with the bar at the TAIL — behind the
    ## direction of travel, marking where execution is stopped.

  ReverseContinuePath = "M8.99688 2C8.80188 2 8.60288 2.058 8.42188 2.186L1." &
    "42188 7.149C0.861882 7.546 0.858882 8.376 1.41588 8.776L8.41588 13.814" &
    "C8.59788 13.945 8.79988 14.004 8.99688 14.004C9.51588 14.004 10.0009 1" &
    "3.593 10.0009 13.002V3.002C10.0009 2.412 9.51688 2 8.99788 2H8.99688ZM" &
    "8.49988 12.027L2.85988 7.968L8.49988 3.969V12.027ZM13.9999 2.75V13.25C" &
    "13.9999 13.664 13.6639 14 13.2499 14C12.8359 14 12.4999 13.664 12.4999" &
    " 13.25V2.75C12.4999 2.336 12.8359 2 13.2499 2C13.6639 2 13.9999 2.336 " &
    "13.9999 2.75Z"
    ## `debug-reverse-continue`, the reflection of the above.

  NextPath = "M9.99993 13C9.99993 14.103 9.10293 15 7.99993 15C6.89693 15 5." &
    "99993 14.103 5.99993 13C5.99993 11.897 6.89693 11 7.99993 11C9.10293 1" &
    "1 9.99993 11.897 9.99993 13ZM13.2499 2C12.8359 2 12.4999 2.336 12.4999" &
    " 2.75V4.027C11.3829 2.759 9.75993 2 7.99993 2C5.03293 2 2.47993 4.211 " &
    "2.06093 7.144C2.00193 7.554 2.28793 7.934 2.69793 7.993C2.73393 7.999 " &
    "2.76993 8.001 2.80493 8.001C3.17193 8.001 3.49293 7.731 3.54693 7.357C" &
    "3.86093 5.159 5.77593 3.501 8.00093 3.501C9.52993 3.501 10.9199 4.264 " &
    "11.7439 5.501H9.75093C9.33693 5.501 9.00093 5.837 9.00093 6.251C9.0009" &
    "3 6.665 9.33693 7.001 9.75093 7.001H13.2509C13.6649 7.001 14.0009 6.66" &
    "5 14.0009 6.251V2.751C14.0009 2.337 13.6649 2.001 13.2509 2.001L13.249" &
    "9 2Z"
    ## `debug-step-over`. The arc hops OVER the dot — the whole-line move.

  ReverseNextPath = "M8 11C6.897 11 6 11.897 6 13C6 14.103 6.897 15 8 15C9.1" &
    "03 15 10 14.103 10 13C10 11.897 9.103 11 8 11ZM13.939 7.144C13.52 4.21" &
    "1 10.966 2 8 2C6.24 2 4.617 2.758 3.5 4.027V2.75C3.5 2.336 3.164 2 2.7" &
    "5 2C2.336 2 2 2.336 2 2.75V6.25C2 6.664 2.336 7 2.75 7H6.25C6.664 7 7 " &
    "6.664 7 6.25C7 5.836 6.664 5.5 6.25 5.5H4.257C5.081 4.263 6.471 3.5 8 " &
    "3.5C10.225 3.5 12.14 5.158 12.454 7.356C12.508 7.73 12.829 8 13.196 8C" &
    "13.231 8 13.267 7.998 13.303 7.992C13.713 7.933 13.998 7.554 13.94 7.1" &
    "43L13.939 7.144Z"
    ## `debug-step-back`, `debug-step-over` reflected about x=8.

  StepInArrowPath = "M4.6 3.6L10.4 9.4M10.4 6.2L10.4 9.4L7.2 9.4"
    ## Drawn. Head DOWN at the dot ("into"), in the RIGHT half (forward).
  ReverseStepInArrowPath = "M11.4 3.6L5.6 9.4M5.6 6.2L5.6 9.4L8.8 9.4"
    ## `StepInArrowPath` reflected about x=8.
  StepOutArrowPath = "M5.6 9.4L11.4 3.6M8.2 3.6L11.4 3.6L11.4 6.8"
    ## Drawn. Head UP and away from the dot ("out of"), in the RIGHT half.
  ReverseStepOutArrowPath = "M10.4 9.4L4.6 3.6M7.8 3.6L4.6 3.6L4.6 6.8"
    ## `StepOutArrowPath` reflected about x=8.

  RunToEntryPath = "M14 8C14 8.81 13.842 9.596 13.528 10.336C13.224 11.053 1" &
    "2.791 11.694 12.241 12.243C11.694 12.791 11.053 13.224 10.337 13.528C9" &
    ".59602 13.841 8.81002 14 8.00002 14C7.19002 14 6.40402 13.842 5.66402 " &
    "13.528C4.94702 13.224 4.30602 12.791 3.75702 12.242C3.20802 11.693 2.7" &
    "7602 11.053 2.47202 10.337C2.31002 9.956 2.48802 9.516 2.86902 9.354C3" &
    ".25102 9.19 3.69002 9.37 3.85202 9.751C4.08102 10.288 4.40502 10.77 4." &
    "81802 11.181C5.23002 11.595 5.71202 11.919 6.24902 12.148C7.35602 12.6" &
    "15 8.64302 12.615 9.75202 12.148C10.288 11.919 10.77 11.595 11.181 11." &
    "183C11.595 10.77 11.919 10.288 12.148 9.751C12.381 9.197 12.501 8.608 " &
    "12.501 8C12.501 7.392 12.382 6.803 12.148 6.248C11.919 5.712 11.595 5." &
    "23 11.182 4.819C10.77 4.405 10.288 4.081 9.75102 3.852C8.64402 3.385 7" &
    ".35702 3.385 6.24802 3.852C5.71202 4.081 5.23002 4.405 4.81902 4.817C4" &
    ".60802 5.027 4.42002 5.256 4.25702 5.5H6.24902C6.66302 5.5 6.99902 5.8" &
    "36 6.99902 6.25C6.99902 6.664 6.66302 7 6.24902 7H2.74902C2.33502 7 1." &
    "99902 6.664 1.99902 6.25V2.75C1.99902 2.336 2.33502 2 2.74902 2C3.1630" &
    "2 2 3.49902 2.336 3.49902 2.75V4.032C3.58202 3.938 3.66802 3.845 3.758" &
    "02 3.757C4.30502 3.209 4.94602 2.776 5.66202 2.472C7.14402 1.845 8.854" &
    "02 1.845 10.335 2.472C11.052 2.776 11.693 3.209 12.242 3.758C12.791 4." &
    "307 13.223 4.947 13.527 5.663C13.84 6.404 13.999 7.19 13.999 8H14Z"
    ## `debug-restart`. One subpath: a near-full circular sweep that breaks at
    ## the upper left into the arrowhead bracket. No triangle anywhere in it,
    ## which is the point — see the note at the top of this file.

  HistoryBackPath = "M11.5 15L4.5 8L11.5 1"
  HistoryForwardPath = "M4.5 1L11.5 8L4.5 15"
    ## The two history chevrons, carried across from
    ## `history_back_black.svg` / `history_forward_black.svg` unchanged.
    ##
    ## Those two files are the reason this module covers the whole strip and
    ## not just the eight `_dark` marks. Their names say `_black`, but both
    ## stroke `#DDDDDD` — the same near-white as their neighbours, so they
    ## were invisible on the white theme too, and a reader trusting the
    ## filename would have concluded the opposite. A name cannot be relied on
    ## to say what colour is inside a file; not having a colour inside the
    ## file is the fix.

  ResetOperationArrowPath = "M9.38451 0.379639L12.6153 3.14882L9.38451 5.918" &
    "01M12.6153 3.14882H8"
  ResetOperationArcPath = "M14 9.14907C14 12.4627 11.3138 15.149 8.00011 15." &
    "149C4.68646 15.149 2.00021 12.4627 2.00021 9.14907C2.00021 5.83542 4.68" &
    "646 3.14917 8.00011 3.14917"
    ## The reset mark, from `reset_operation_dark.svg`, geometry unchanged —
    ## an open arc with an arrowhead re-entering at the top. It keeps its own
    ## `0 0 16 17` box.

const ControlMarks*: seq[ControlMark] = @[
  ControlMark(buttonId: "history-back-image", action: "history-back",
              viewBox: DefaultViewBox,
              shapes: @[stroked(HistoryBackPath, "1")]),
  ControlMark(buttonId: "history-forward-image", action: "history-forward",
              viewBox: DefaultViewBox,
              shapes: @[stroked(HistoryForwardPath, "1")]),
  ControlMark(buttonId: "reverse-next-image", action: "reverse-next",
              viewBox: DefaultViewBox,
              shapes: @[filled(ReverseNextPath)]),
  ControlMark(buttonId: "next-image", action: "next",
              viewBox: DefaultViewBox,
              shapes: @[filled(NextPath)]),
  ControlMark(buttonId: "reverse-step-in-image", action: "reverse-step-in",
              viewBox: DefaultViewBox,
              shapes: @[filled(StepBadgePath),
                        stroked(ReverseStepInArrowPath)]),
  ControlMark(buttonId: "step-in-image", action: "step-in",
              viewBox: DefaultViewBox,
              shapes: @[filled(StepBadgePath), stroked(StepInArrowPath)]),
  ControlMark(buttonId: "reverse-step-out-image", action: "reverse-step-out",
              viewBox: DefaultViewBox,
              shapes: @[filled(StepBadgePath),
                        stroked(ReverseStepOutArrowPath)]),
  ControlMark(buttonId: "step-out-image", action: "step-out",
              viewBox: DefaultViewBox,
              shapes: @[filled(StepBadgePath), stroked(StepOutArrowPath)]),
  ControlMark(buttonId: "reverse-continue-image", action: "reverse-continue",
              viewBox: DefaultViewBox,
              shapes: @[filled(ReverseContinuePath)]),
  ControlMark(buttonId: "continue-image", action: "continue",
              viewBox: DefaultViewBox,
              shapes: @[filled(ContinuePath)]),
  ControlMark(buttonId: "run-to-entry-image", action: "run-to-entry",
              viewBox: DefaultViewBox,
              shapes: @[filled(RunToEntryPath)]),
  ControlMark(buttonId: "reset-operation-image", action: "reset-operation",
              viewBox: "0 0 16 17",
              shapes: @[stroked(ResetOperationArrowPath, "1"),
                        stroked(ResetOperationArcPath, "1")]),
]
  ## Every mark on the debugger control strip, in the order it is drawn.
  ##
  ## This is the ONE place they are written down. The view attaches them by
  ## walking this table and the checks read the same table, so a control
  ## cannot be given a mark in one place and not the other.
  ##
  ## The strip's remaining button, `run-tests-image`, is deliberately absent:
  ## its asset is shared with other surfaces and has a paired loading
  ## animation, which is a picture rather than a mark and has no business
  ## following a text colour.

const ControlMarkCount* = 12
  ## How many marks this bar has, stated independently of `ControlMarks`.
  ##
  ## Deliberately a literal rather than `ControlMarks.len`, which would be a
  ## tautology: comparing a collection's length to itself passes for every
  ## collection, so it could never notice a mark being dropped from the
  ## table. The checks assert BOTH that `ControlMarks.len == ControlMarkCount`
  ## and that the DOM carries this many marks, and
  ## `tests/test_debug_control_marks` runs the same count assertion over a
  ## deliberately short table to prove it can fail.

const MarkClass* = "ct-control-mark"
  ## The class `components/button.styl` sizes these with. The mark takes no
  ## `width`/`height` attribute here for the same reason the old assets should
  ## not have: the size is a design value and belongs in the stylesheet, which
  ## already sized the old `background-image` at `auto 1em`.

func markFor*(action: string): ControlMark =
  ## The mark for a command, or a mark with an empty `buttonId` if the bar has
  ## no such control. Callers that must not miss check `buttonId.len > 0`.
  for m in ControlMarks:
    if m.action == action:
      return m
  ControlMark()

func svgMarkup*(m: ControlMark): string =
  ## The mark as an SVG fragment.
  ##
  ## `currentColor` in both channels and no colour literal anywhere: that is
  ## the property the white theme was missing, and writing a hex here would
  ## reintroduce it. `aria-hidden` because the button already carries its own
  ## accessible name in `.custom-tooltip` — a second name is a control
  ## announced twice.
  var parts = newSeq[string]()
  parts.add "<svg class=\"" & MarkClass & "\" viewBox=\"" & m.viewBox &
    "\" data-mark=\"" & m.action & "\" aria-hidden=\"true\" " &
    "focusable=\"false\" xmlns=\"http://www.w3.org/2000/svg\">"
  for s in m.shapes:
    if s.stroked:
      parts.add "<path d=\"" & s.d & "\" fill=\"none\" " &
        "stroke=\"currentColor\" stroke-width=\"" & s.strokeWidth & "\" " &
        "stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
    else:
      parts.add "<path d=\"" & s.d & "\" fill=\"currentColor\"/>"
  parts.add "</svg>"
  parts.join("")

# ---------------------------------------------------------------------------
# Attaching the marks to a rendered toolbar
# ---------------------------------------------------------------------------

when defined(js):
  import isonim/web/dom_api as isonim_dom

  const SvgNamespace = "http://www.w3.org/2000/svg"

  proc createElementNS(d: isonim_dom.Document; ns, tag: cstring):
      isonim_dom.Element {.importcpp: "#.createElementNS(#, #)".}
    ## SVG elements are only SVG elements if they are created in the SVG
    ## namespace — `createElement("svg")` yields an unknown HTML element that
    ## lays out as an inline box and paints nothing. `isonim/web/dom_api`
    ## binds only `createElement`, and isonim is a sibling repo pinned by the
    ## flake, so the namespaced form is bound here rather than there.

  proc querySelector(e: isonim_dom.Element; sel: cstring): isonim_dom.Element
    {.importcpp: "#.querySelector(#)".}
    ## Scoped to the panel root on purpose. `#isonim-debug-controls` can hold
    ## either this toolbar or the edit-mode one and they share button ids, so
    ## a document-wide lookup could attach a stepping mark to the wrong
    ## surface's button.

  proc firstElementChild(e: isonim_dom.Element): isonim_dom.Element
    {.importcpp: "#.firstElementChild".}

  proc consoleError(msg: cstring) {.importjs: "console.error(#)".}

  proc buildMark(m: ControlMark): isonim_dom.Element =
    ## Build one mark as real namespaced SVG nodes.
    let svg = isonim_dom.document.createElementNS(cstring(SvgNamespace),
                                                 cstring"svg")
    svg.setAttribute(cstring"class", cstring(MarkClass))
    svg.setAttribute(cstring"viewBox", cstring(m.viewBox))
    svg.setAttribute(cstring"aria-hidden", cstring"true")
    svg.setAttribute(cstring"focusable", cstring"false")
    # `data-action` names the command this mark belongs to, so a check can
    # read the glyph back and say WHICH control it is on. A bar of nine
    # correct-looking buttons can still carry a mark on the wrong one, and
    # that is not visible from the shapes alone.
    svg.setAttribute(cstring"data-mark", cstring(m.action))
    for s in m.shapes:
      let p = isonim_dom.document.createElementNS(cstring(SvgNamespace),
                                                  cstring"path")
      p.setAttribute(cstring"d", cstring(s.d))
      if s.stroked:
        p.setAttribute(cstring"fill", cstring"none")
        p.setAttribute(cstring"stroke", cstring"currentColor")
        p.setAttribute(cstring"stroke-width", cstring(s.strokeWidth))
        p.setAttribute(cstring"stroke-linecap", cstring"round")
        p.setAttribute(cstring"stroke-linejoin", cstring"round")
      else:
        p.setAttribute(cstring"fill", cstring"currentColor")
      svg.appendChild(p)
    svg

  proc attachControlMarks*(panel: isonim_dom.Element): int {.discardable.} =
    ## Put every mark in `ControlMarks` on its button, and answer how many
    ## were placed.
    ##
    ## Done here, by walking the table, rather than by writing nine SVG
    ## fragments into the nine `button(...)` calls: the toolbar's `ui()` block
    ## is the one place the bar's structure is readable at a glance, and nine
    ## inlined glyphs would bury it. It also keeps this change off the button
    ## call sites, which `dev` and `cloud` have already diverged on.
    ##
    ## The count is RETURNED rather than assumed so the caller — and the
    ## checks — can tell "nine marks attached" from "the lookup missed and the
    ## bar is silently bare", which counting the buttons cannot.
    var placed = 0
    for m in ControlMarks:
      let btn = panel.querySelector(cstring("#" & m.buttonId))
      if btn.isNil:
        continue
      # First child, so the mark sits before `.custom-tooltip`. The tooltip is
      # `position: absolute` and takes no space in the button's flex line, but
      # keeping the mark first means the painted glyph is the button's first
      # box in every surface that renders this markup.
      let existing = btn.firstElementChild
      if existing.isNil:
        btn.appendChild(buildMark(m))
      else:
        discard btn.insertBefore(buildMark(m), existing)
      inc placed
    if placed != ControlMarkCount:
      consoleError(cstring("debug controls: attached " & $placed & " of " &
                           $ControlMarkCount & " marks — the toolbar is " &
                           "missing a glyph"))
    placed
