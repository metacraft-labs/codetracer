type
  BreakpointState* = object ## State of the breakpoint at a location, either enabled or disabled
    location*: SourceLocation
    enabled*: bool

  # TODO QA Note: why not BreakpointSetup = seq[BreakpointState]?
  BreakpointSetup* = object ## State of a sequence of breakpoints
    breakpoints*: seq[BreakpointState]

  BreakpointInfo* = object
    path*: langstring
    line*: int
    id*: int