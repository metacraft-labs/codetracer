## gpui/app/pane_names.nim — PLAT-45. What the GPUI window calls a pane when
## its `LayoutNode` carries no title.
##
## Every pane of the shared default (`layout_model.sharedDefaultLayout`) is
## untitled on purpose: `LayoutNode.title` empty means "use the pane's own
## default, which this module does not decide", and what the products share is
## WHERE a pane is, not what its tab says. The terminal names its panes in
## `tui/app/layout/cells.terminalPaneName`; this is the GPUI window's table —
## the names its old default carried ("Editor", "Call Trace", "State",
## "Event Log", "Debug Controls"), extended to every `PaneKind`, with no `else`
## so a new pane cannot arrive nameless.

import headless_app/layout_model

func gpuiPaneName*(kind: PaneKind): string =
  case kind
  of paneEditor: "Editor"
  of paneCalltrace: "Call Trace"
  of paneState: "State"
  of paneEventLog: "Event Log"
  of paneDebugControls: "Debug Controls"
  of paneFlow: "Flow"
  of paneTimeline: "Timeline"
  of paneSearch: "Search"
  of panePointList: "Points"
  of paneScratchpad: "Scratchpad"
  of paneShell: "Shell"
  of paneFileTree: "Files"
  of paneBuildOutput: "Build Output"
  of paneVcs: "VCS"
  of paneAgentActivity: "Agent Activity"
  of paneTerminalOutput: "Terminal Output"
  of paneTestResults: "Test Results"
  of paneConstraints: "Constraints"
