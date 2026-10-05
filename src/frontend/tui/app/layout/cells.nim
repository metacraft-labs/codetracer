## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/layout/cells.nim — PLAT-45. The terminal's CELL vocabulary: a
## rectangle of cells, the rows the shell's chrome takes, the body area, the
## minimum-size contract per pane, and the names the terminal gives panes.
##
## ## Why this module exists
##
## Until PLAT-45 these lived in `profile.nim`, and `project.nim` imported
## `profile.nim` for `CellArea`. PLAT-45 makes the terminal's default a FOLD of
## the one shared arrangement, and the fold depth is chosen by PROJECTING each
## candidate and checking every visible pane against its minimum — so
## `profile.nim` now needs `project.nim`, and the cycle is broken by moving
## what `project.nim` needed into a module both import. Everything here is a
## value or a pure function of integers; nothing projects, nothing draws.

import headless_app/layout_model

type
  CellArea* = object
    ## A rectangle of terminal cells, in ABSOLUTE screen coordinates.
    ##
    ## Distinct from `isonim_tui`'s `CellRect` on purpose: that one is a
    ## renderer's type and lives behind the layout engine, and this module —
    ## which is where the screen's shape is decided — must not need a renderer
    ## to say where the body is. `project.nim` converts.
    col*: int
    row*: int
    width*: int
    height*: int

const
  HeaderRows* = 1
    ## The session header (§3.3.1). One row: both ASCII drawings in §3.1 show
    ## one, and the session tabs share it rather than claiming a second — see
    ## `app/views/header.nim`.

  StatusRows* = 1
    ## The command line and status bar (§3.3.6).

  ChromeRows* = HeaderRows + StatusRows
    ## Everything the shell takes before the body gets a row.

  MinShellWidth* = 20
    ## Below this nothing can be laid out at all: the header needs something
    ## legible and the deepest fold still needs its widest pane's minimum.
    ## `project.nim` reports `prNoSpace` rather than drawing a hole.
  MinShellHeight* = ChromeRows + 2
    ## A header, a status bar, and at least a title row plus one content row.

proc bodyArea*(width, height: int): CellArea =
  ## The multi-pane region: everything between the header and the status bar.
  ##
  ## Clamped at zero rather than allowed to go negative, because a negative
  ## height would propagate into the projection as a rectangle that contains
  ## nothing and overlaps everything. A zero-height body is a reportable
  ## condition (`project.prNoSpace`); a negative one is a bug that hides.
  CellArea(col: 0, row: HeaderRows, width: max(0, width),
           height: max(0, height - ChromeRows))

proc contentMinWidth(kind: PaneKind): int =
  ## The narrowest column a pane's CONTENT can be given and still say
  ## anything. `minPaneWidth` below adds the one floor every pane shares.
  ##
  ## THE MINIMUM-SIZE CONTRACT IS EXPLICIT, which is CTUI-3's risk mitigation
  ## verbatim: "an explicit minimum-size contract per pane that the projection
  ## test enforces rather than discovers". PLAT-45 makes it the thing that
  ## DECIDES the terminal's arrangement: `profile.depthFor` folds the shared
  ## default exactly as far as these numbers require and no further.
  case kind
  # The source pane is the one a replay cannot be read without, so its
  # minimum is not "legible" but "usable": 60 is what the terminal's own
  # profiles gave it below ultra-wide before the shared default (56 at 80x24,
  # 60 at 120x40) — a six-cell gutter (four-digit line number, the
  # execution-point marker, a space) and fifty-four columns of source. The
  # fold goes as deep as it must to give it that, so no terminal narrower
  # than the old ultra-wide breakpoint shows less source than it did.
  of paneEditor: 60
  of paneCalltrace: 14  ## `#0 process_item()` truncated but still legible
  of paneState: 14      ## `ptr: 0x7ffd98`
  of paneEventLog: 12
  of paneTimeline: 20   ## a scrubber with two ends and a marker
  else: 8

proc minPaneHeight*(kind: PaneKind): int =
  ## The shortest a pane can be: a title row (or, for a tab, the tab strip that
  ## replaces it) plus at least one row of content.
  case kind
  of paneTimeline: 3    ## title, scrubber, one event line
  else: 2

proc terminalPaneName*(kind: PaneKind): string =
  ## What the terminal calls a pane when its `LayoutNode` carries no title —
  ## which is every pane of the shared default, whose titles are empty on
  ## purpose ("use the pane's own default"): what is shared is WHERE a pane is,
  ## and each front-end names its own tabs.
  case kind
  of paneEditor: "Source"
  of paneCalltrace: "Call Trace"
  of paneState: "Variables"
  of paneEventLog: "Event Log"
  of paneTimeline: "Timeline"
  of paneDebugControls: "Debug Controls"
  of paneFlow: "Flow"
  of paneSearch: "Search"
  of panePointList: "Points"
  of paneScratchpad: "Scratchpad"
  of paneShell: "Shell"
  of paneFileTree: "Files"
  of paneBuildOutput: "Build & Run"
  of paneVcs: "VCS"
  of paneAgentActivity: "Agent Activity"
  of paneTerminalOutput: "Terminal Output"
  of paneTestResults: "Tests"
  of paneConstraints: "Constraints"
  of paneProblems: "Problems"
  of paneRequests: "Requests"

proc minPaneWidth*(kind: PaneKind): int =
  ## The narrowest column a pane can be given: its content's minimum, and
  ## never less than its own bracketed tab label.
  ##
  ## THE LABEL FLOOR IS WHAT A REPORT LEAF NEEDS (PLAT-45 review). A pane the
  ## terminal cannot draw is placed as a report naming it; at a width below
  ## its name the report is a clipped fragment ("[Test Re") that names
  ## nothing, and a region that cannot say what it is has no reason to take
  ## the cells. With the floor, such a region FOLDS — its report still
  ## reachable as a tab — rather than being drawn illegibly, and a drawable
  ## pane's strip always spells the tab it is on.
  max(contentMinWidth(kind), terminalPaneName(kind).len + 2)
