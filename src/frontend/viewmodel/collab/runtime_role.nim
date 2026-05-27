## Runtime role design for collaborative ViewModel sessions.
##
## M0 only names the roles and their basic authority shape. Later milestones
## wire these roles into reducers, backend effects, and transports.

type
  ViewModelRuntimeRole* = enum
    ## Normal single-user CodeTracer session. It owns its backend and keeps
    ## enough local ViewState shape to become joinable later.
    vrrStandalone,
    ## Collaborative peer that owns/sequences backend commands for the room.
    vrrBackendOwner,
    ## Collaborative peer that receives backend-authoritative facts from the
    ## owner and may only publish permitted shared ViewState / awareness ops.
    vrrCollaborator

proc ownsBackend*(role: ViewModelRuntimeRole): bool =
  role in {vrrStandalone, vrrBackendOwner}

proc acceptsBackendSnapshots*(role: ViewModelRuntimeRole): bool =
  role in {vrrBackendOwner, vrrCollaborator}

proc mayIssueBackendCommands*(role: ViewModelRuntimeRole): bool =
  role in {vrrStandalone, vrrBackendOwner}
