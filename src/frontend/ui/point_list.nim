## The desktop's Point List pane (`Content.PointList`): breakpoints and
## tracepoints, drawn by the IsoNim view every front-end shares
## (`viewmodel/views/isonim_point_list_view`) over the ViewModel session's
## `PointListVM` — the SAME `store.pointList.rows` the native front-ends
## read, fed by one decoder (`ReplayDataStore.applyVerifiedBreakpoints` for
## breakpoints the engine verified, `applyTracepointResults` for sweeps,
## `point_collection_source` for project definitions).
##
## PLAT-40. Until 2026-09-23 `utils.makeComponent`'s arm for this pane was
## commented out and its `else` raised, so the pane could not be constructed
## at all, and its menu entry was commented out so nothing reached the raise.
## The component is stateless, like `ConstraintsComponent`: everything it
## draws lives in the ViewModel. It exists so the pane is constructed and
## registered the way every other pane is.

import
  ui_imports,
  ../[ types, communication ]

# The pane's view is mounted by the panel host (`ui/panel_host`), into the
# container GoldenLayout creates, over the session's `PointListVM`. The
# component only takes part in registration.

method register*(self: PointListComponent, api: MediatorWithSubscribers) =
  self.api = api

proc registerPointListComponent*(component: PointListComponent,
                                 api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
