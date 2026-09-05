## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/frame_item.nim — CTUI-6. One row of the call stack pane:
## CodeTracer-TUI.md §3.3.3's "frame index, function signature, file basename,
## and line number" plus its "distinct icon/color indicating library code vs.
## user application code".
##
## ## THE TWO CURSORS ARE TWO COLUMNS, and that is the whole point of this file
##
## CTUI-6's contract: "Selecting an outer frame moves the INSPECTION cursor; the
## execution pointer is unchanged. The two cursors are distinct and are rendered
## distinctly — conflating them is the classic defect here."
##
## So they are not one marker in two colours, and they are not a single
## highlighted row. They are **two separate one-cell columns at the left edge**,
## with the group expander in a THIRD:
##
##     * > + #0  usr 49 x descend                    main.py:81
##     | | |
##     | | `- the EXPANDER (magenta, bold): `+` collapsed, `-` expanded, blank
##     | |    on an ordinary frame.
##     | `--- the INSPECTION cursor (cyan, bold). Which frame the source view is
##     |      showing. Moves with `j`/`k`/click.
##     `----- the EXECUTION frame (bright yellow, bold). Where the debugger is
##            stopped. Moves only when the debugger moves.
##
## The expander earned its own column rather than sharing the first: the first
## draft put it there, and a collapsed recursion holding the execution frame
## then showed `+` where `*` belonged — the pane losing the one fact it exists
## to show, on exactly the row a reader looks at first. The Tier-2 case found
## it by reading the cell.
##
## A reader of a `regionText` dump can tell them apart without colour, a reader
## of a screenshot can tell them apart without reading text, and a frame that is
## both carries both glyphs. A single marker whose colour changed would be
## invisible in the first case and ambiguous in the second, and the failure it
## produces — "the pane says the debugger is where I clicked" — is the one the
## contract is written against.
##
## ## The badge is a WORD and a COLOUR, for the same reason provenance is
##
## §3.3.3 asks for a "distinct icon/color indicating library code vs. user
## application code". CTUI-5 established the shape this repository uses for a
## two-signal distinction (`source_pane.nim`'s header: a marker in the title
## AND a tint on every row), because a colour alone is invisible in plaintext
## and a glyph alone is easy to miss. Here that is `usr` in green against `lib`
## in muted grey, plus the frame name itself muted for library frames.
##
## ## Classification takes ROOTS, it does not guess
##
## `classifyFrame` asks whether the frame's path sits under one of the recorded
## program's own directories. It contains no list of magic directory names
## (`site-packages`, `/usr/lib`, `node_modules`): such a list is wrong for every
## language nobody thought of, and silently wrong — a frame classified `usr`
## because the heuristic did not recognise a runtime looks exactly like a frame
## that really is the user's.
##
## `app/call_stack_binding.nim` derives the roots from the entry file the
## BACKEND reports, so the answer is a fact about the recording rather than
## about this machine. Every frame of every fixture in CTUI-1's corpus
## classifies as `foUser` under that rule, which the navigation suite asserts —
## the library arm is exercised at Tier 1 against constructed paths and at Tier
## 2 by the snapshot app, and that asymmetry is recorded here rather than
## hidden, because no recorder in this workspace yet produces a trace whose
## stack enters a library.

import std/[strutils, unicode]

import isonim_tui

import ./styled_row

type
  FrameOrigin* = enum
    ## §3.3.3's "library code vs. user application code".
    foUser
    foLibrary

  StackFrame* = object
    ## One frame as the backend reports it.
    ##
    ## A plain value with no ViewModel in it, for the reason
    ## `app/views/source_pane.nim`'s header gives about `SourcePaneModel`: the
    ## pane must be assertable without a debugger, and two frames of two
    ## different stops must be comparable as values.
    index*: int
      ## DAP frame index — 0 is the innermost, active call.
    id*: int
      ## The backend's own `stackFrames[].id`. Carried because it is the handle
      ## every later DAP request about this frame (`scopes`, `evaluate`) takes,
      ## and a pane that dropped it would make CTUI-7 re-fetch the stack.
    name*: string
      ## The function name the backend reported.
    path*: string
      ## The recorded path. Whatever the recorder interned; never rewritten.
    line*: int
      ## The line the backend reports FOR THIS FRAME. For frame 0 that is the
      ## current statement; for an outer frame it is whatever the engine says,
      ## which is the call site on the Python arm and the function's own first
      ## line on the Noir one — both measured, neither assumed.

  FrameRowKind* = enum
    frkFrame
    frkGroup
      ## A collapsed run of identical recursive frames.

  FrameRowSpec* = object
    ## Everything one row is drawn from.
    kind*: FrameRowKind
    index*: int
      ## The frame's own index; for a group, its innermost member's.
    name*: string
    path*: string
    line*: int
    origin*: FrameOrigin
    isExecution*: bool
      ## This row holds the frame the debugger is stopped in.
    isInspected*: bool
      ## This row holds the frame the source view is showing.
    indent*: int
      ## Cells the NAME field is indented by. Non-zero for the members of an
      ## expanded group, so a reader can see which rows belong to it.
      ##
      ## THE NAME, NOT THE ROW: indenting the whole row would move the marker
      ## columns, and a `*` that appears at column 0 on some rows and column 1
      ## on others is not a column a reader — or a Tier-2 `cellAt` — can read.
    groupCount*: int
      ## Members of the group. Zero for `frkFrame`.
    expanded*: bool
    indexWidth*: int
    width*: int

  FrameItem* = object
    ## One painted row, plus where its location field ended up.
    ##
    ## The column is REPORTED rather than recomputed by the caller, because the
    ## OSC 8 link over that field and the paint of that field have to agree
    ## exactly: a link computed from a second copy of this arithmetic would
    ## drift the first time the badge or the index field changed width.
    row*: StyledRow
    locationCol*: int
    locationWidth*: int

const
  ExecutionFrameGlyph* = "*"
  InspectedFrameGlyph* = ">"
  GroupCollapsedGlyph* = "+"
  GroupExpandedGlyph* = "-"
  NoMarkerGlyph* = " "

  UserBadge* = "usr"
  LibraryBadge* = "lib"
  BadgeCells* = 3

  ExecutionFrameStyle* = CellStyle(fg: "bright_yellow", bold: true)
  InspectedFrameStyle* = CellStyle(fg: "cyan", bold: true)
  GroupMarkerStyle* = CellStyle(fg: "magenta", bold: true)
  FrameIndexStyle* = CellStyle(fg: "bright_black")
  UserBadgeStyle* = CellStyle(fg: "green")
  LibraryBadgeStyle* = CellStyle(fg: "bright_black")
  UserFrameNameStyle* = CellStyle(fg: "white")
  LibraryFrameNameStyle* = CellStyle(fg: "bright_black")
  FrameLocationStyle* = CellStyle(fg: "blue")
  InspectedRowBackground* = "bright_black"
    ## THE INSPECTION CURSOR'S ROW HIGHLIGHT.
    ##
    ## Deliberately NOT `gutter.ExecutionLineBackground` (`blue`), which the
    ## source pane paints on the execution line. Two cursors that shared a
    ## background would be conflated on screen even with two distinct glyphs,
    ## and this pane exists to keep them apart.

  ReservedTrailingCells* = 1
    ## One cell at the right edge that no linked field may occupy. See
    ## `app/views/hyperlinks.nim`'s header: libvterm bounds an OSC 8 range by
    ## the cursor position at the CLOSE, and a run ending at the last column
    ## leaves the cursor in the pending-wrap state, so the final cell can fall
    ## outside the link.

proc frameIndexWidth*(frameCount: int): int =
  ## Cells the `#N` field needs for a stack of `frameCount` frames.
  ##
  ## Derived from the stack's own depth rather than fixed, so a 51-frame stack
  ## gets `#50` without the name column moving per row.
  var digits = 1
  var n = max(0, frameCount - 1)
  while n >= 10:
    inc digits
    n = n div 10
  1 + digits

proc normalisedRoot(root: string): string =
  ## A root with any trailing separator removed, so `/a/b` and `/a/b/` are one
  ## root and `/a/bc` is not under either.
  result = root
  while result.len > 0 and (result[^1] == '/' or result[^1] == '\\'):
    result.setLen(result.len - 1)

proc isUnderRoot*(path, root: string): bool =
  ## Whether `path` lies under directory `root`, by PATH COMPONENT.
  ##
  ## A plain `startsWith` would put `/home/user/projectile/x.py` under
  ## `/home/user/project`, so the character after the root must be a separator.
  let r = normalisedRoot(root)
  if r.len == 0 or path.len <= r.len:
    return path.len == r.len and path == r
  if not path.startsWith(r):
    return false
  path[r.len] == '/' or path[r.len] == '\\'

proc classifyFrame*(path: string; userRoots: openArray[string]): FrameOrigin =
  ## Whether a frame's file belongs to the recorded program.
  ##
  ## A frame with NO path is `foLibrary`: the engine reported a frame it cannot
  ## point at a file for, and calling that the user's code would put a `usr`
  ## badge on a row whose source can never be shown.
  if path.len == 0:
    return foLibrary
  for root in userRoots:
    if isUnderRoot(path, root):
      return foUser
  foLibrary

proc badgeText*(origin: FrameOrigin): string =
  case origin
  of foUser: UserBadge
  of foLibrary: LibraryBadge

proc badgeStyle*(origin: FrameOrigin): CellStyle =
  case origin
  of foUser: UserBadgeStyle
  of foLibrary: LibraryBadgeStyle

proc frameNameStyle*(origin: FrameOrigin): CellStyle =
  case origin
  of foUser: UserFrameNameStyle
  of foLibrary: LibraryFrameNameStyle

proc frameSignature*(frame: StackFrame): string =
  ## §3.3.3's "function signature".
  ##
  ## `name()` — the parentheses are added here because no DAP `stackFrame`
  ## carries an argument list (`dap_types.rs`'s `StackFrame` has `name`,
  ## `source`, `line`, `column` and `id` and nothing else), and a bare
  ## identifier beside a file name reads as a variable. A backend that grows
  ## real signatures would report them in `name` and this function would pass
  ## them through: a name that already ends in `)` is left alone.
  if frame.name.len == 0:
    return "<anonymous>"
  if frame.name.endsWith(")"):
    return frame.name
  frame.name & "()"

proc frameLocation*(frame: StackFrame): string =
  ## §3.3.3's "file basename, and line number".
  let base = pathBaseName(frame.path)
  if base.len == 0:
    return ""
  if frame.line <= 0:
    return base
  base & ":" & $frame.line

proc groupLabel*(count: int; name: string): string =
  ## What a collapsed recursion says about itself.
  ##
  ## CTUI-6: "Recursion collapses into a group row that REPORTS ITS COUNT." The
  ## count leads, because that is the fact the row exists to carry — a reader
  ## scanning the left edge of the pane sees `49 x descend` rather than a name
  ## they have to read to the end of.
  $count & " x " & name

proc markerGlyph(spec: FrameRowSpec): string =
  ## Column 0: the EXECUTION frame, on every kind of row.
  ##
  ## A GROUP CARRIES IT TOO, and the first draft did not — it put the expander
  ## here instead, so a collapsed recursion holding the execution frame showed
  ## `+` where `*` should have been and the pane lost the one fact it exists to
  ## show. Found by the Tier-2 case reading the cell, which is what that case is
  ## for. The expander has its own column below.
  if spec.isExecution: ExecutionFrameGlyph else: NoMarkerGlyph

proc markerStyle(spec: FrameRowSpec): CellStyle =
  if spec.isExecution: ExecutionFrameStyle else: DefaultCellStyle

proc expanderGlyph*(spec: FrameRowSpec): string =
  ## Column 2: whether this row is a collapsed or an expanded group.
  if spec.kind != frkGroup: NoMarkerGlyph
  elif spec.expanded: GroupExpandedGlyph
  else: GroupCollapsedGlyph

proc expanderStyle*(spec: FrameRowSpec): CellStyle =
  if spec.kind == frkGroup: GroupMarkerStyle else: DefaultCellStyle

proc indexText*(spec: FrameRowSpec): string =
  ## The index field's text: `#12`, for a group as much as for a frame.
  ##
  ## A GROUP SHOWS ITS INNERMOST MEMBER'S INDEX rather than repeating the
  ## expander glyph the marker column already carries. The first draft put the
  ## `+`/`-` here too; on a real pane that read `+>   + usr 49 x descend`, which
  ## says one thing twice and loses the only piece of information a reader needs
  ## to place the group in a stack they are also reading `#N` off.
  "#" & $spec.index

proc frameItemRow*(spec: FrameRowSpec): FrameItem =
  ## One row of the pane, exactly `spec.width` cells wide.
  ##
  ## Built as spans and fitted, never by string concatenation with a `align`
  ## call at the end: a span is what carries the style, and the location field's
  ## column — which the OSC 8 link is computed from — is the sum of the widths
  ## before it.
  result = FrameItem(row: @[], locationCol: -1, locationWidth: 0)
  let width = spec.width
  if width <= 0:
    return

  var spans: seq[StyledSpan] = @[]
  var used = 0

  # The parameters are NOT called `text` and `style`: a template substitutes
  # identifiers inside object-constructor field names too, so `StyledSpan(text:
  # …)` below would become `StyledSpan(<the argument>: …)` and fail to compile
  # with an error that names the argument rather than the cause.
  template put(spanText: string; spanStyle: CellStyle) =
    if used < width:
      let fitted = truncateToCells(spanText, width - used)
      if fitted.len > 0:
        spans.add StyledSpan(text: fitted, style: spanStyle)
        used += cellWidthOf(fitted)

  put(markerGlyph(spec), markerStyle(spec))
  put((if spec.isInspected: InspectedFrameGlyph else: NoMarkerGlyph),
      (if spec.isInspected: InspectedFrameStyle else: DefaultCellStyle))
  put(expanderGlyph(spec), expanderStyle(spec))
  put(padLeft(indexText(spec), max(1, spec.indexWidth)), FrameIndexStyle)
  put(" ", DefaultCellStyle)
  put(badgeText(spec.origin), badgeStyle(spec.origin))
  put(" ", DefaultCellStyle)

  let label =
    repeat(' ', max(0, spec.indent)) &
    (if spec.kind == frkGroup: groupLabel(spec.groupCount, spec.name)
     else: frameSignature(StackFrame(name: spec.name)))
  let location =
    frameLocation(StackFrame(path: spec.path, line: spec.line))

  # How the remaining cells are shared. The location is right-aligned against
  # the reserved trailing cell and the name takes what is left, because a name
  # is the field a reader scans and a location is the field they check.
  let remaining = width - used - ReservedTrailingCells
  var locationCells = cellWidthOf(location)
  var nameCells = cellWidthOf(label)
  if remaining <= 0:
    locationCells = 0
    nameCells = 0
  elif locationCells + nameCells + 1 > remaining:
    # Not enough room for both. The NAME wins the first `remaining div 2`
    # cells and the location keeps whatever is left, so a narrow pane degrades
    # to "which function" rather than to "which file".
    nameCells = min(nameCells, max(1, remaining - 1))
    locationCells = min(locationCells, max(0, remaining - nameCells - 1))

  if nameCells > 0:
    put(truncateToCells(label, nameCells), frameNameStyle(spec.origin))
  if locationCells > 0:
    let gap = width - ReservedTrailingCells - locationCells - used
    if gap > 0:
      put(repeat(' ', gap), DefaultCellStyle)
    result.locationCol = used
    result.locationWidth = locationCells
    put(truncateToCells(location, locationCells), FrameLocationStyle)
  if used < width:
    put(repeat(' ', width - used), DefaultCellStyle)

  if spec.isInspected:
    # THE INSPECTION CURSOR'S ROW HIGHLIGHT, applied last so it keeps every
    # foreground the fields above decided — the same order and the same reason
    # as `source_pane`'s execution-line highlight.
    for i in 0 ..< spans.len:
      spans[i].style = spans[i].style.withBackground(InspectedRowBackground)

  result.row = spans

proc frameItemText*(spec: FrameRowSpec): string =
  ## The row as text. Derived from the spans, so a Tier-2 `regionText` read and
  ## a Tier-1 cell read cannot disagree about what the row says.
  rowText(frameItemRow(spec).row)
