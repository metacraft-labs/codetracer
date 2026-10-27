## frontend/ui/calltrace_editor.nim
##
## The Calltrace Editor pane's component. Its view
## (``viewmodel/views/isonim_calltrace_editor_view.nim``, one generic proc
## for every renderer) is mounted by the panel host (``ui/panel_host``) into
## the container GoldenLayout creates — ``renderer.openCallViewer`` opens
## the pane with ``content = Content.CalltraceEditor`` and
## ``label = "calls"`` (single-instance) — over the session's
## ``CalltraceEditorVM``. The component only takes part in registration.
##
## The legacy Karax ``method render`` emitted only an empty container and
## its nested-editor helpers (``openNewCall`` / ``callView``) were
## unreachable, so both were removed.

import ui_imports, ../[ types, communication ]

method register*(self: CalltraceEditorComponent, api: MediatorWithSubscribers) =
  self.api = api
