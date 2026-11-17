## common/pointer_shape.nim — the pointer's shape, as ONE function of
## the element under the pointer (Pointer-Affordances.md §2 – §3).
##
## Each front-end hit-tests in its own medium (cells, pixels, the DOM) and
## answers a `HitTarget`; `pointerShapeOf` turns that and the gesture in flight
## into a `PointerShape`; the front-end projects the answer: `data-pointer` and
## eight stylesheet rules on the desktop, a `cursor` style in GPUI's render
## plan, OSC 22 in the terminal. No front-end names a shape for an element kind
## itself (PA-1's source gate).
##
## The names are CSS's. Each medium's spelling is a table below, not code.
##
## Pure: no signals, no I/O; C and JS. It sits in `common/` beside `key_names`
## because the terminal's capability layer needs the shapes, and that layer may
## depend on nothing behind the SDK facade.

type
  PointerShape* = enum
    psDefault = "default"
    psPointer = "pointer"
    psText = "text"
    psColResize = "col-resize"
    psRowResize = "row-resize"
    psGrab = "grab"
    psGrabbing = "grabbing"
    psNotAllowed = "not-allowed"

  HitKind* = enum
    ## The kinds of element a pointer can be over (§3.2's rows).
    hkNone = "none"
      ## Empty pane ground, status text, a label.
    hkControl = "control"
      ## A button, menu item, top-bar control, tab close, row control, link.
    hkTab = "tab"
      ## A pane or session tab: clicked more than dragged (OQ-P1).
    hkRow = "row"
      ## A navigation row: call trace, event log, search result, problem,
      ## value-history entry, origin hop, file (OQ-P2).
    hkExpander = "expander"
      ## A tree expander.
    hkLoadMore = "load-more"
    hkCell = "cell"
      ## A table cell; `truncated` says whether it shows a `…`.
    hkEditorText = "editor-text"
    hkTextInput = "text-input"
      ## The omnibar, the find field, a prompt, the rename box.
    hkGutterGlyph = "gutter-glyph"
      ## The editor gutter's glyph column: a click toggles a breakpoint.
    hkGutterLine = "gutter-line"
      ## The line numbers: a click selects the line (Monaco's own `default`).
    hkDividerVertical = "divider-vertical"
      ## Between panes side by side: dragged left and right.
    hkDividerHorizontal = "divider-horizontal"
      ## Between panes one above the other: dragged up and down.
    hkColumnSeparator = "column-separator"
      ## Variables name / value, Event Log headers.
    hkDragHandle = "drag-handle"
      ## Something that only drags: an auto-hide label's grip.
    hkScrubber = "scrubber"
      ## A scrollbar's track or thumb, horizontal or vertical.

  HitTarget* = object
    ## What a front-end's hit-test answers (Input-Routing §5.3).
    kind*: HitKind
    id*: string
      ## The element's identity, for a diagnostic. No rule reads it.
    disabled*: bool
      ## The element's operation is not enabled now (Input-Routing §3.1).
    truncated*: bool
      ## A table cell that shows a `…` (Horizontal-Overflow §5.1).

  PointerGestureKind* = enum
    pgNone = "none"
    pgTabDrag = "tab-drag"
      ## A tab or a pane dragged; `legalDrop` says what is under the pointer.
    pgColumnDrag = "column-drag"
      ## A vertical divider or a column separator held.
    pgRowDrag = "row-drag"
      ## A horizontal divider held.
    pgScrubberDrag = "scrubber-drag"
    pgTextSelection = "text-selection"
      ## A drag selecting text, by character, word, line or column.
    pgLineSelection = "line-selection"
      ## A drag that started on the line numbers.

  PointerGesture* = object
    ## The gesture in flight, read from the existing machines; no state here.
    kind*: PointerGestureKind
    legalDrop*: bool

const
  X11PointerNames*: array[PointerShape, string] = [
    psDefault: "left_ptr", psPointer: "hand2", psText: "xterm",
    psColResize: "sb_h_double_arrow", psRowResize: "sb_v_double_arrow",
    psGrab: "hand1", psGrabbing: "fleur", psNotAllowed: "X_cursor"]
    ## xterm's dialect of OSC 22: X11 cursor-font names (§2).

  FallbackShapes*: array[PointerShape, PointerShape] = [
    psDefault: psDefault, psPointer: psDefault, psText: psDefault,
    psColResize: psDefault, psRowResize: psDefault, psGrab: psPointer,
    psGrabbing: psGrab, psNotAllowed: psDefault]
    ## What stands in for a shape a terminal says it lacks (§5.2):
    ## `grabbing → grab → pointer`, the resizes and `not-allowed` → `default`.

func cssName*(shape: PointerShape): string =
  ## The name on the desktop, in GPUI's render plan, and to kitty, foot and
  ## Ghostty.
  $shape

func pointerShapeNamed*(name: string): (bool, PointerShape) =
  ## The shape a CSS name spells; false for a name outside the closed set.
  for shape in PointerShape:
    if $shape == name:
      return (true, shape)
  (false, psDefault)

func supportedFallback*(shape: PointerShape;
                        supported: set[PointerShape]): (bool, PointerShape) =
  ## `shape`, or the first of its fallbacks in `supported`. False when the
  ## chain ends with nothing supported: nothing may be written (PA-3).
  var s = shape
  while true:
    if s in supported:
      return (true, s)
    if FallbackShapes[s] == s:
      return (false, s)
    s = FallbackShapes[s]

func restShape(target: HitTarget): PointerShape =
  ## §3.2: the shape over an element when no gesture is in flight.
  if target.disabled and target.kind in {hkControl, hkTab, hkRow, hkExpander,
                                         hkLoadMore, hkGutterGlyph}:
    return psNotAllowed
  case target.kind
  of hkNone, hkScrubber, hkGutterLine: psDefault
  of hkControl, hkTab, hkRow, hkExpander, hkLoadMore, hkGutterGlyph: psPointer
  of hkCell: (if target.truncated: psPointer else: psDefault)
  of hkEditorText, hkTextInput: psText
  of hkDividerVertical, hkColumnSeparator: psColResize
  of hkDividerHorizontal: psRowResize
  of hkDragHandle: psGrab

func pointerShapeOf*(target: HitTarget;
                     gesture = PointerGesture()): PointerShape =
  ## THE function (§3.1). While a gesture is in flight the shape is the
  ## gesture's, whatever is under the pointer (§3.3).
  case gesture.kind
  of pgNone: target.restShape
  of pgTabDrag: (if gesture.legalDrop: psGrabbing else: psNotAllowed)
  of pgColumnDrag: psColResize
  of pgRowDrag: psRowResize
  of pgScrubberDrag, pgLineSelection: psDefault
  of pgTextSelection: psText

func cursorOf*(kind: HitKind; disabled = false): string =
  ## The CSS name a front-end's element style carries for an element of `kind`
  ## at rest: `pointerShapeOf`'s answer, spelled for a `cursor` style.
  pointerShapeOf(HitTarget(kind: kind, disabled: disabled)).cssName
