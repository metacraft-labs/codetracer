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
## ## The geometry is CodeTracer's own, and stays that way
##
## For a few hours this module also carried BlockTracer's DRAWINGS. `93be377c`
## had replaced CodeTracer's eight stepping marks with VS Code codicons to make
## the two products' toolbars identical, and `a30f10cd` then moved the whole
## strip in here and brought those replacements with it.
##
## That alignment was not wanted. The intent was to change BlockTracer's marks
## only; CodeTracer's are to be reworked by a designer, from CodeTracer's own
## set as the starting point. So the eight stepping marks below are the drawings
## this product had before `93be377c` — traced from the asset files at
## `1b898556` (`93be377c^`), which is the named revision to start that rework
## from:
##
##   src/public/resources/debug/{continue,next,reverse_continue,reverse_next,
##     step-in,step-out,reverse_step-in,reverse_step-out}_dark.svg
##
## They are carried across the way the other four were: coordinates verbatim,
## `#DDDDDD` dropped, `currentColor` in its place. Two conversions were needed
## because this module draws `<path>` only, and both are exact rather than
## approximate:
##
## * `step-out` and `reverse_step-out` used `<rect rx="1">` under a transform.
##   The transform is a reflection of an axis-aligned rounded rect, so it is
##   folded into the corner coordinates and the rect is written out as its
##   equivalent path.
## * `step-in` and `reverse_step-in` used Figma's mask trick for an INSIDE
##   stroke: a 2-wide band centred on each edge, clipped to the rect's interior
##   by a `<mask>`. A 1-wide inside stroke is identical to a 1-wide centred
##   stroke on the rect inset by 0.5 with its radius reduced by 0.5, so that is
##   what they are here — one stroked path each, no mask, same pixels.
##
## The other four — the two history chevrons, the reset arc and `run-to-entry`
## — are unchanged from the asset files they came from and always were.
##
## ## What the old set looks like, so the rework is not walking in blind
##
## Reading the restored geometry back, two things are worth writing down for
## whoever picks this up. `continue`/`reverse-continue` and `next`/`reverse-
## next` are exact 180° rotations of one another about (8, 8) — that pairing is
## real and `debug_control_marks_test` now asserts it. The four step marks are
## NOT a comparable family: `step-in` and `reverse-step-out` carry the same
## arrow (to within the one-unit difference in their viewBoxes) and are told
## apart only by whether the box beside it is outlined or filled, and so do
## `step-out` and `reverse-step-in`. That is a property of the drawings, not a
## transcription error, and it is left exactly as it was found rather than
## quietly improved on the way past.

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
func drawn(d: string; width = "1"): ControlShape =
  ## A stroke from one of the original asset files: SVG's own defaults for the
  ## ends, which is what those files left unset.
  stroked(d, width, cap = "butt", join = "miter")

const
  ContinueDotPath = "M8 12C9.10457 12 10 12.8954 10 14C10 15.1046 9.10457 1" &
    "6 8 16C6.89543 16 6 15.1046 6 14C6 12.8954 6.89543 12 8 12Z"
  ContinueChevronPath = "M1.4375 1.3125L8 6L11.2812 3.65625L14.5625 1.3125"
    ## `continue_dark.svg`. A shallow V with its vertex at (8, 6) over a filled
    ## dot at the bottom of the box.

  ReverseContinueDotPath = "M8 4C9.10457 4 10 3.10457 10 2C10 0.89543 9.1045" &
    "7 -7.8281e-08 8 -1.74846e-07C6.89543 -2.7141e-07 6 0.89543 6 2C6 3.104" &
    "57 6.89543 4 8 4Z"
  ReverseContinueChevronPath = "M14.5625 14.6875L8 10L4.71875 12.3437L1.4375" &
    " 14.6875"
    ## `reverse_continue_dark.svg`: `continue_dark.svg` turned 180° about
    ## (8, 8) — dot to the top, vertex to (8, 10).

  NextRulePath = "M1.5 14.3438H14.5"
  NextChevronPath = "M1.4375 1.65619L8 6.34369L11.2812 3.99994L14.5625 1.656" &
    "19"
    ## `next_dark.svg`. The same shallow V as `continue`, over a rule instead
    ## of a dot — that single difference is the whole distinction between the
    ## two most-used controls on this bar, and is one of the things the rework
    ## is expected to look at.
    ##
    ## The middle point sits on the segment it interrupts; it is redundant and
    ## is kept because it is in the file.

  ReverseNextRulePath = "M1.5 1.65625H14.5"
  ReverseNextChevronPath = "M1.4375 14.3438L8 9.65625L11.2812 12L14.5625 14." &
    "3437"
    ## `reverse_next_dark.svg`: `next_dark.svg` turned 180° about (8, 8).

  StepInArrowPath = "M9.61338 14.4643L14.2933 9.49477L3.29443 9.49477C1.7672" &
    "4 9.49477 0.500001 8.34078 0.500001 6.92303L0.500001 9.17912e-06"
  StepInBoxPath = "M4.68835 0.929139H15.5A0.5 0.5 0 0 1 16 1.429139V5.42914" &
    "A0.5 0.5 0 0 1 15.5 5.92914H4.68835A0.5 0.5 0 0 1 4.18835 5.42914V1.42" &
    "9139A0.5 0.5 0 0 1 4.68835 0.929139Z"
    ## `step-in_dark.svg`, which is `0 0 17 17` and not `0 0 16 16`.
    ##
    ## The box is the file's masked inside-stroke written as a centred one:
    ## the mask's rect is x∈[3.68835, 16.5], y∈[0.429139, 6.42914] with r=1,
    ## and a 1-wide stroke inside that is a 1-wide stroke centred on the same
    ## rect inset by 0.5 with r=0.5. Outlined, where `step-out`'s is filled.

  ReverseStepInArrowPath = "M6.88662 0.342773L2.20669 5.3123H13.2056C14.7328" &
    " 5.3123 16 6.46628 16 7.88404V14.8071"
  ReverseStepInBoxPath = "M1 8.87793H11.8116A0.5 0.5 0 0 1 12.3116 9.37793V1" &
    "3.3779A0.5 0.5 0 0 1 11.8116 13.8779H1A0.5 0.5 0 0 1 0.5 13.3779V9.377" &
    "93A0.5 0.5 0 0 1 1 8.87793Z"
    ## `reverse_step-in_dark.svg`, `0 0 17 17`. Mask's rect x∈[0, 12.8116],
    ## y∈[8.37793, 14.3779], r=1, inset the same way.

  StepOutArrowPath = "M7.09078 0.349609L2.2299 5.31913H13.654C15.2403 5.3191" &
    "3 16.5565 6.47312 16.5565 7.89088V14.8139"
  StepOutBoxPath = "M1 8.24274H12.307A1 1 0 0 1 13.307 9.24274V13.38444A1 1 " &
    "0 0 1 12.307 14.38444H1A1 1 0 0 1 0 13.38444V9.24274A1 1 0 0 1 1 8.242" &
    "74Z"
    ## `step-out_dark.svg`, which is `0 0 18 17` — a third viewBox on this
    ## strip. Its box is a FILLED `<rect rx="1">` carried under
    ## `matrix(-1 0 0 1 13.307 8.24274)`; that maps the rect to
    ## x∈[0, 13.307], y∈[8.24274, 14.38444], and a rounded rect is symmetric
    ## under the reflection, so the transform folds into those corners exactly.

  ReverseStepOutArrowPath = "M9.96574 14.4643L14.8266 9.49477L3.40248 9.4947" &
    "7C1.81624 9.49477 0.500001 8.34078 0.500001 6.92303L0.500001 9.17912e-06"
  ReverseStepOutBoxPath = "M4.74939 0.42947H16.05639A1 1 0 0 1 17.05639 1.42" &
    "947V5.57117A1 1 0 0 1 16.05639 6.57117H4.74939A1 1 0 0 1 3.74939 5.571" &
    "17V1.42947A1 1 0 0 1 4.74939 0.42947Z"
    ## `reverse_step-out_dark.svg`, `0 0 18 17`. Filled rect under
    ## `matrix(1 ~0 ~0 -1 3.74939 6.57117)` — the off-diagonal 8.74228e-08 is
    ## Figma's rounding of zero — giving x∈[3.74939, 17.05639],
    ## y∈[0.42947, 6.57117].

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
              shapes: @[drawn(ReverseNextRulePath),
                        drawn(ReverseNextChevronPath)]),
  ControlMark(buttonId: "next-image", action: "next",
              viewBox: DefaultViewBox,
              shapes: @[drawn(NextRulePath), drawn(NextChevronPath)]),
  ControlMark(buttonId: "reverse-step-in-image", action: "reverse-step-in",
              viewBox: "0 0 17 17",
              shapes: @[drawn(ReverseStepInArrowPath),
                        drawn(ReverseStepInBoxPath)]),
  ControlMark(buttonId: "step-in-image", action: "step-in",
              viewBox: "0 0 17 17",
              shapes: @[drawn(StepInArrowPath), drawn(StepInBoxPath)]),
  ControlMark(buttonId: "reverse-step-out-image", action: "reverse-step-out",
              viewBox: "0 0 18 17",
              shapes: @[drawn(ReverseStepOutArrowPath),
                        filled(ReverseStepOutBoxPath)]),
  ControlMark(buttonId: "step-out-image", action: "step-out",
              viewBox: "0 0 18 17",
              shapes: @[drawn(StepOutArrowPath), filled(StepOutBoxPath)]),
  ControlMark(buttonId: "reverse-continue-image", action: "reverse-continue",
              viewBox: DefaultViewBox,
              shapes: @[filled(ReverseContinueDotPath),
                        drawn(ReverseContinueChevronPath)]),
  ControlMark(buttonId: "continue-image", action: "continue",
              viewBox: DefaultViewBox,
              shapes: @[filled(ContinueDotPath),
                        drawn(ContinueChevronPath)]),
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
