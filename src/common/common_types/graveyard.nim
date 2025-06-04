type
  DebugOutputKind* = enum
    DebugLoading,
    DebugResult,
    DebugMove,
    DebugError

  DebugOutput* = object
    kind*: DebugOutputKind
    output*: langstring

  DebugInteraction* = object ## Debug interaction object kept in the repl history
    input*: langstring
    output*: DebugOutput

  ShortCircuitGroup* = object
    left*:                    Boundary
    right*:                   Boundary

  BoundaryKind* = enum BBefore, BAfter, BAnd, BOr

  Boundary* = object
    # A boundary can be either before/after or n-th operator
    case kind*: BoundaryKind
    of BAnd, BOr:
      index*: int
    else: discard