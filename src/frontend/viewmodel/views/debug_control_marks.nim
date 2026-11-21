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
## reason (`client/src/components/icons.nim`, `dev` e8c8f34). What is shared
## between the two products is that MECHANISM, and only that.
##
## ## The geometry
##
## The nine transport marks are drawn here to one grammar (see the constants
## below): the dot is where execution is, the arrow is what the operation does
## to it, and every reverse mark is its forward mark mirrored left to right.
## They replace the asset files CodeTracer shipped before `93be377c`
## (`src/public/resources/debug/*_dark.svg` at `1b898556`), whose forward and
## reverse members were told apart only by a dot, a rule or a filled box, which
## reviewers of both front-ends could not tell apart at toolbar size. The
## history chevrons and the reset arc are unchanged from their asset files.
##
## The terminal's text marks (`viewmodels/transport_icons`) and its pictures
## (`tui/host/control_icons`, which rasterises these same paths) follow the
## same grammar, and the GPUI window draws these same paths, so every front-end
## shows one set.

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
    ##
    ## `linecap`/`linejoin` are carried per-shape because the strip's stroked
    ## marks were not all drawn with the same ends. The asset files the
    ## stepping marks come from named neither, i.e. SVG's defaults — `butt`
    ## ends and `miter` corners — and a chevron given round ends instead is a
    ## visibly blunter mark at 16px. So the value travels with the shape rather
    ## than being a house style applied to all of them.
    d*: string
    stroked*: bool
    strokeWidth*: string
    linecap*: string
    linejoin*: string

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
    ## `viewBox` is per-mark because the strip's marks were not all drawn in
    ## the same box and are carried across verbatim rather than redrawn: the
    ## reset mark is `0 0 16 17`, the two step-in marks `0 0 17 17`, the two
    ## step-out marks `0 0 18 17`. Normalising them to 16 square would mean
    ## re-cutting the artwork, which is the designer's pass, not this one.
    ## `components/button.styl` sizes the mark by HEIGHT for the same reason —
    ## it is what `background-size: auto 1em` did for these files before.
    buttonId*: string
    action*: string
    viewBox*: string
    shapes*: seq[ControlShape]

const DefaultViewBox = "0 0 16 16"

func filled(d: string): ControlShape =
  ControlShape(d: d, stroked: false)
func stroked(d: string; width = "1.6"; cap = "round"; join = "round"):
    ControlShape =
  ControlShape(d: d, stroked: true, strokeWidth: width,
               linecap: cap, linejoin: join)
func line(d: string): ControlShape =
  ## A stroke of the transport marks: one weight, round ends and corners.
  ## 1.5, not the history chevrons' 1: at toolbar size a 1-unit arrow was
  ## the faintest thing on the strip (a blind reading of the nine marks).
  stroked(d, "1.5")

const
  ## THE NINE TRANSPORT MARKS, redrawn so each one reads as its operation and
  ## each reverse control is told apart from its forward twin at a glance.
  ##
  ## The marks this replaces were the asset files the strip shipped before
  ## `93be377c`: two shallow chevrons told apart only by a dot or a rule under
  ## them, and four step marks that were arrows beside boxes, two pairs of which
  ## carried the same arrow and differed only in whether the box was filled.
  ## Six of six reviewers of the GPUI and Electron captures independently said
  ## the forward and reverse members were not disambiguated and that none read
  ## as its operation, and one miscounted the nine as eight.
  ##
  ## ONE GRAMMAR, THE SAME ONE THE TERMINAL'S TEXT MARKS USE
  ## (`transport_icons`: `⏵ ⏴`, `↷ ↶`, `⏮`):
  ##
  ## * the dot is where execution is, and the arrow is where the operation
  ##   takes it: over the dot (next), down into it (step in), up out of it
  ##   (step out); continue is the play triangle beside a bar, run-to-entry is
  ##   the skip-to-start pair of triangles against a bar;
  ## * time runs left to right. Every reverse mark is its forward mark
  ##   MIRRORED about x = 8, so the one difference between a pair is the
  ##   direction it points, and `debug_control_marks_test` asserts the mirror
  ##   exactly rather than trusting these strings.
  ##
  ## Drawn in a 16-unit box with one stroke weight (`1.5`, which the
  ## stylesheet's `non-scaling-stroke` makes 1.5 CSS pixels) and round ends, filled where a
  ## shape is solid; colour is `currentColor`, the button's own text token, as
  ## for every mark here.
  NextArcPath = "M3 9.5C3 3.5 13 3.5 13 9.5"
  ReverseNextArcPath = "M13 9.5C13 3.5 3 3.5 3 9.5"
  NextHeadPath = "M10.75 7.5L13 9.75L15.25 7.5"
  ReverseNextHeadPath = "M5.25 7.5L3 9.75L0.75 7.5"
  NextDotPath = "M8 11.5C8.9665 11.5 9.75 12.2835 9.75 13.25C9.75 14.2165 8.9665 15 8 15C7.0335 15 6.25 14.2165 6.25 13.25C6.25 12.2835 7.0335 11.5 8 11.5Z"
  ReverseNextDotPath = "M8 11.5C7.0335 11.5 6.25 12.2835 6.25 13.25C6.25 14.2165 7.0335 15 8 15C8.9665 15 9.75 14.2165 9.75 13.25C9.75 12.2835 8.9665 11.5 8 11.5Z"
  StepInArrowPath = "M2.5 3H11V10"
  ReverseStepInArrowPath = "M13.5 3H5V10"
  StepInHeadPath = "M8.75 7.75L11 10L13.25 7.75"
  ReverseStepInHeadPath = "M7.25 7.75L5 10L2.75 7.75"
  StepInDotPath = "M11 11.5C11.9665 11.5 12.75 12.2835 12.75 13.25C12.75 14.2165 11.9665 15 11 15C10.0335 15 9.25 14.2165 9.25 13.25C9.25 12.2835 10.0335 11.5 11 11.5Z"
  ReverseStepInDotPath = "M5 11.5C4.0335 11.5 3.25 12.2835 3.25 13.25C3.25 14.2165 4.0335 15 5 15C5.9665 15 6.75 14.2165 6.75 13.25C6.75 12.2835 5.9665 11.5 5 11.5Z"
  StepOutArrowPath = "M6.5 13.25H11V3.5"
  ReverseStepOutArrowPath = "M9.5 13.25H5V3.5"
  StepOutHeadPath = "M8.75 5.75L11 3.5L13.25 5.75"
  ReverseStepOutHeadPath = "M7.25 5.75L5 3.5L2.75 5.75"
  StepOutDotPath = "M4 11.5C4.9665 11.5 5.75 12.2835 5.75 13.25C5.75 14.2165 4.9665 15 4 15C3.0335 15 2.25 14.2165 2.25 13.25C2.25 12.2835 3.0335 11.5 4 11.5Z"
  ReverseStepOutDotPath = "M12 11.5C11.0335 11.5 10.25 12.2835 10.25 13.25C10.25 14.2165 11.0335 15 12 15C12.9665 15 13.75 14.2165 13.75 13.25C13.75 12.2835 12.9665 11.5 12 11.5Z"
  ContinueBarPath = "M3.5 3V13"
  ReverseContinueBarPath = "M12.5 3V13"
  ContinueTrianglePath = "M6.5 3L13.5 8L6.5 13Z"
  ReverseContinueTrianglePath = "M9.5 3L2.5 8L9.5 13Z"
  RunToEntryBarPath = "M2.5 3V13"
  RunToEntryTrianglePaths = ["M8.5 3L3.5 8L8.5 13Z", "M14 3L9 8L14 13Z"]

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
              shapes: @[line(ReverseNextArcPath),
                        line(ReverseNextHeadPath),
                        filled(ReverseNextDotPath)]),
  ControlMark(buttonId: "next-image", action: "next",
              viewBox: DefaultViewBox,
              shapes: @[line(NextArcPath),
                        line(NextHeadPath),
                        filled(NextDotPath)]),
  ControlMark(buttonId: "reverse-step-in-image", action: "reverse-step-in",
              viewBox: DefaultViewBox,
              shapes: @[line(ReverseStepInArrowPath),
                        line(ReverseStepInHeadPath),
                        filled(ReverseStepInDotPath)]),
  ControlMark(buttonId: "step-in-image", action: "step-in",
              viewBox: DefaultViewBox,
              shapes: @[line(StepInArrowPath),
                        line(StepInHeadPath),
                        filled(StepInDotPath)]),
  ControlMark(buttonId: "reverse-step-out-image", action: "reverse-step-out",
              viewBox: DefaultViewBox,
              shapes: @[line(ReverseStepOutArrowPath),
                        line(ReverseStepOutHeadPath),
                        filled(ReverseStepOutDotPath)]),
  ControlMark(buttonId: "step-out-image", action: "step-out",
              viewBox: DefaultViewBox,
              shapes: @[line(StepOutArrowPath),
                        line(StepOutHeadPath),
                        filled(StepOutDotPath)]),
  ControlMark(buttonId: "reverse-continue-image", action: "reverse-continue",
              viewBox: DefaultViewBox,
              shapes: @[line(ReverseContinueBarPath),
                        filled(ReverseContinueTrianglePath)]),
  ControlMark(buttonId: "continue-image", action: "continue",
              viewBox: DefaultViewBox,
              shapes: @[line(ContinueBarPath),
                        filled(ContinueTrianglePath)]),
  ControlMark(buttonId: "run-to-entry-image", action: "run-to-entry",
              viewBox: DefaultViewBox,
              shapes: @[line(RunToEntryBarPath),
                        filled(RunToEntryTrianglePaths[0]),
                        filled(RunToEntryTrianglePaths[1])]),
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
        "stroke-linecap=\"" & s.linecap & "\" " &
        "stroke-linejoin=\"" & s.linejoin & "\"" &
        (if s.linejoin == "miter": " stroke-miterlimit=\"10\"" else: "") & "/>"
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
        p.setAttribute(cstring"stroke-linecap", cstring(s.linecap))
        p.setAttribute(cstring"stroke-linejoin", cstring(s.linejoin))
        # The asset files these come from carried `stroke-miterlimit="10"`.
        # SVG's default is 4, which is enough to clip a miter on a shallow
        # enough join, so the file's value travels with the file's corners.
        if s.linejoin == "miter":
          p.setAttribute(cstring"stroke-miterlimit", cstring"10")
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
