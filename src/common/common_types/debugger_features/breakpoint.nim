type
  BreakpointState* = object ## State of the breakpoint at a location, either enabled or disabled
    location*: SourceLocation
    enabled*: bool

  BreakpointSetup* = seq[BreakpointState]

  BreakpointInfo* = object
    path*: langstring
    line*: int
    id*: int