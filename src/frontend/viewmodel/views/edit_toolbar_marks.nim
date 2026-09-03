## views/edit_toolbar_marks.nim
##
## The two marks the EDIT-mode topbar draws: Build and Run.
##
## ## Why this is not a table in `debug_control_marks`
##
## That module owns the DEBUGGER strip's twelve marks, and two things make
## sharing it the wrong call. Its `ControlMarkCount` is a deliberate literal
## that its checks assert against — adding two entries there would either
## break that count or force it to mean "marks on either surface", which is
## the kind of number that stops being able to fail. And the two surfaces are
## never mounted together, so a single table would be a list nobody can read
## as "what this bar has on it".
##
## It is also in flight: the eight stepping marks are being restored to
## CodeTracer's own pre-`93be377c` drawings. New artwork for a different
## surface has no business landing inside that change.
##
## ## The style, and where it comes from
##
## These are drawn to match the marks being restored, which are CodeTracer's
## originals from `src/public/resources/debug/*.svg`. Read off those files
## rather than guessed at:
##
##   * a 16x16 viewBox, all of it used — `continue`'s chevron runs x=1.44 to
##     x=14.56 and `next`'s rule x=1.5 to x=14.5, so a mark that sits timidly
##     in the middle reads as a different set;
##   * strokes 1 unit wide with SVG's OWN defaults for the joins — butt caps
##     and mitre — plus `stroke-miterlimit="10"`, exactly as the asset files
##     wrote them. This is the detail that separates the two families: the
##     codicon set that replaced them is 1.6-wide with round caps and round
##     joins, and `debug_control_marks.svgMarkup` hard-codes those round
##     values, which is the other reason this module emits its own SVG rather
##     than borrowing that one;
##   * a single solid fill per mark as the accent, against otherwise thin line
##     work — `continue` has its dot, `step-out` its block, `run-to-entry` its
##     triangle. Both marks here follow `step-out`'s composition exactly: one
##     filled body plus one 1-wide stroke.
##
## `currentColor` in both channels and no colour literal anywhere. The asset
## files baked `#DDDDDD` into every path, which is precisely why the strip was
## twelve blank buttons on the white theme; restoring the DRAWINGS is not a
## reason to restore that.
##
## ## What the two marks say
##
## **Run** is a play triangle, drawn as an outline. `93be377c` established that
## a bare triangle is the wrong mark for *continue*, because the media reading
## — "skip to the end" — is not what continuing does. Nothing of that applies
## here: this button starts a program that is not running, which is what the
## media triangle has always meant, and it is what Visual Studio, JetBrains
## and VS Code all put on Run. The debugger's own `continue` stays a chevron
## over a dot, so the two cannot be confused on a bar that never shows both.
## Why it is stroked rather than filled is argued at `RunTrianglePath`.
##
## **Build** is a hammer: a filled head with a 1-wide stroked handle. Hammer
## is the settled convention for Build across the IDEs a CodeTracer user
## arrives from — JetBrains, Eclipse and Xcode all use one — and the
## filled-body-plus-thin-stroke composition is `step-out`'s, so it sits in
## the family without being a member of the stepping set.

import std/strutils

type
  EditMarkShape* = object
    ## One path. Either filled, or stroked in the original files' manner.
    d*: string
    stroked*: bool
    strokeWidth*: string

  EditMark* = object
    buttonId*: string
    action*: string
    viewBox*: string
    shapes*: seq[EditMarkShape]

const
  EditMarkClass* = "edit-toolbar-mark"
    ## Its own class, not `ct-control-mark`. That one is sized by a rule in
    ## `components/button.styl` that belongs to the debugger strip and is being
    ## edited by the mark restoration; borrowing it would couple this surface's
    ## glyph size to a change about a different bar.

  EditMarkCount* = 2
    ## Stated independently of `EditToolbarMarks`, for the same reason
    ## `ControlMarkCount` is: comparing a table's length against itself passes
    ## for every table including an empty one, so it can never notice a mark
    ## being dropped.

func filled(d: string): EditMarkShape =
  EditMarkShape(d: d, stroked: false)

func drawn(d: string; width = "1"): EditMarkShape =
  ## A stroke in the original assets' manner: 1 unit wide, butt caps, mitre
  ## joins — SVG's defaults, which is what those files relied on.
  EditMarkShape(d: d, stroked: true, strokeWidth: width)

const
  RunTrianglePath = "M3.5 1.5L14.5 8L3.5 14.5Z"
    ## Apex at the right edge, base at the left, spanning 13 of the 16 units so
    ## it carries the same optical width as `continue`'s chevron. The centroid
    ## sits at x=7.17 rather than 8: a play triangle centred on its bounding
    ## box reads as sitting too far right, and every icon set nudges it left.
    ##
    ## STROKED, not filled, and that was the one judgement call in this change.
    ## A play triangle is conventionally solid, and the first version drew it
    ## that way — but rendered beside the restored set at 16px and 44px it was
    ## a solid mass, and a solid mass is the single thing no member of that set
    ## is. Ten of the twelve are hairline outline; `step-out`'s block and
    ## `continue`'s dot are ACCENTS inside a mark whose other element is a
    ## line, and `run-to-entry`'s solid triangle is one sub-element among six.
    ## None of them is a filled shape on its own.
    ##
    ## Outlined, it is the same hand as `next` and `history-forward` and still
    ## unmistakably a play triangle. The instruction was to emulate the style
    ## of these icons, so where the convention and the family disagreed, the
    ## family won.

  BuildHeadPath = "M7.48 1.12L1.12 7.48L3.52 9.88L9.88 3.52Z"
    ## The head: a 9.0 x 3.39 rectangle rotated 45 degrees, so its long axis is
    ## perpendicular to the handle. Written as four explicit corners rather
    ## than a `rect` with a transform, because every other mark in the family
    ## is plain path data and a transform would be the one thing here that a
    ## reader has to compose in their head.

  BuildHandlePath = "M6.7 6.7L13.5 13.5"
    ## From the head's lower edge to the bottom-right corner. It starts exactly
    ## on that edge — the head's centre is (5.5, 5.5) and its half-thickness
    ## 1.7 — so there is no seam at one size and an overlap at another.

const EditToolbarMarks*: seq[EditMark] = @[
  EditMark(buttonId: "build-image", action: "build", viewBox: "0 0 16 16",
           shapes: @[filled(BuildHeadPath), drawn(BuildHandlePath)]),
  EditMark(buttonId: "run-image", action: "run", viewBox: "0 0 16 16",
           shapes: @[drawn(RunTrianglePath)]),
]

func editMarkFor*(action: string): EditMark =
  ## The mark for `action`, or a zero `EditMark` whose `d`-less `shapes` make
  ## the miss visible rather than drawing something plausible.
  for m in EditToolbarMarks:
    if m.action == action:
      return m
  EditMark()

func hasEditMark*(buttonId: string): bool =
  for m in EditToolbarMarks:
    if m.buttonId == buttonId:
      return true
  false

func svgMarkup*(m: EditMark): string =
  ## The mark as an SVG fragment.
  ##
  ## `stroke-linecap` and `stroke-linejoin` are deliberately ABSENT rather than
  ## set to `butt`/`miter`: those are SVG's initial values, and the asset files
  ## this emulates got them by not saying anything either. `stroke-miterlimit`
  ## IS written, because those files wrote it.
  ##
  ## `aria-hidden`, because the button carries its own accessible name in its
  ## `title` — a mark that also announced itself would name the control twice.
  var parts = newSeq[string]()
  parts.add "<svg class=\"" & EditMarkClass & "\" viewBox=\"" & m.viewBox &
    "\" data-mark=\"" & m.action & "\" aria-hidden=\"true\" " &
    "focusable=\"false\" xmlns=\"http://www.w3.org/2000/svg\">"
  for s in m.shapes:
    if s.stroked:
      parts.add "<path d=\"" & s.d & "\" fill=\"none\" " &
        "stroke=\"currentColor\" stroke-width=\"" & s.strokeWidth & "\" " &
        "stroke-miterlimit=\"10\"/>"
    else:
      parts.add "<path d=\"" & s.d & "\" fill=\"currentColor\"/>"
  parts.add "</svg>"
  parts.join("")

when defined(js):
  import isonim/web/dom_api as isonim_dom

  const SvgNamespace = "http://www.w3.org/2000/svg"

  proc createElementNS(d: isonim_dom.Document; ns, tag: cstring):
      isonim_dom.Element {.importcpp: "#.createElementNS(#, #)".}
    ## SVG elements are only SVG elements if they are created in the SVG
    ## namespace — `createElement("svg")` yields an unknown HTML element that
    ## lays out as an inline box and paints nothing. `isonim/web/dom_api` binds
    ## only `createElement`, and isonim is a sibling repo pinned by the flake,
    ## so the namespaced form is bound here. Same binding as
    ## `debug_control_marks`; duplicated rather than exported from there
    ## because that module is being edited by the mark restoration and a new
    ## export is the kind of edit that turns into a conflict.

  proc querySelector(e: isonim_dom.Element; sel: cstring): isonim_dom.Element
    {.importcpp: "#.querySelector(#)".}
    ## Scoped to the panel root, not the document. `#isonim-debug-controls`
    ## holds either this toolbar or the debugger's, and the two share
    ## `run-tests-image`, so a document-wide lookup is how a mark reaches the
    ## wrong surface's button.

  proc firstElementChild(e: isonim_dom.Element): isonim_dom.Element
    {.importcpp: "#.firstElementChild".}

  proc consoleError(msg: cstring) {.importjs: "console.error(#)".}

  proc buildEditMark(m: EditMark): isonim_dom.Element =
    ## Build the mark as real namespaced SVG nodes.
    ##
    ## Node by node rather than by assigning `svgMarkup` to `innerHTML`: the
    ## string form exists for the tests and the mock, and routing shipped
    ## markup through `innerHTML` would add a sink to the very surface a
    ## parallel change is removing them from.
    let svg = isonim_dom.document.createElementNS(cstring(SvgNamespace),
                                                 cstring"svg")
    svg.setAttribute(cstring"class", cstring(EditMarkClass))
    svg.setAttribute(cstring"viewBox", cstring(m.viewBox))
    svg.setAttribute(cstring"aria-hidden", cstring"true")
    svg.setAttribute(cstring"focusable", cstring"false")
    svg.setAttribute(cstring"data-mark", cstring(m.action))
    for s in m.shapes:
      let p = isonim_dom.document.createElementNS(cstring(SvgNamespace),
                                                  cstring"path")
      p.setAttribute(cstring"d", cstring(s.d))
      if s.stroked:
        p.setAttribute(cstring"fill", cstring"none")
        p.setAttribute(cstring"stroke", cstring"currentColor")
        p.setAttribute(cstring"stroke-width", cstring(s.strokeWidth))
        # No `stroke-linecap`/`stroke-linejoin`. The debugger strip's
        # equivalent sets both to `round` because the codicon set it carries
        # is drawn that way; these marks emulate the ORIGINAL assets, which
        # relied on SVG's own butt/mitre defaults. Setting them here would be
        # the single edit that puts these glyphs in the other family.
        p.setAttribute(cstring"stroke-miterlimit", cstring"10")
      else:
        p.setAttribute(cstring"fill", cstring"currentColor")
      svg.appendChild(p)
    svg

  proc attachEditToolbarMarks*(panel: isonim_dom.Element): int {.discardable.} =
    ## Put each mark on its button, and answer how many were placed.
    ##
    ## The count is RETURNED, not assumed, for the reason
    ## `attachControlMarks` gives: a bar whose marks failed to attach still
    ## renders its buttons and they still click, so a caller that only checks
    ## "the toolbar mounted" cannot tell a drawn bar from a bare one.
    ##
    ## A miss is not an error here the way it is on the debugger strip: Build
    ## and Run are ABSENT in Debug mode by design (EMT-D12), so this walks the
    ## marks and skips the ones whose button is not on this panel. Only a
    ## button that IS present and did not receive its mark is worth a word.
    var placed = 0
    var present = 0
    for m in EditToolbarMarks:
      let btn = panel.querySelector(cstring("#" & m.buttonId))
      if btn.isNil:
        continue
      inc present
      let existing = btn.firstElementChild
      if existing.isNil:
        btn.appendChild(buildEditMark(m))
      else:
        discard btn.insertBefore(buildEditMark(m), existing)
      inc placed
    if placed != present:
      consoleError(cstring("edit toolbar: attached " & $placed & " of " &
                           $present & " marks — the bar is drawn short"))
    placed
