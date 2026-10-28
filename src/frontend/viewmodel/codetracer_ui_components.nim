## codetracer_ui_components.nim — the CodeTracer UI Components package: the
## rendered debugger panes, for a host other than the desktop.
##
## [CodeTracer-UI-Components.md](../../../../codetracer-specs/Planned-Features/CodeTracer-UI-Components.md)
## defines the package; this module is its Nim surface. It sits BESIDE
## `codetracer_embed`, never inside it: the Embed SDK is the rendering-free
## replay core (CodeTracer-Embed-SDK.md §3.2 row 1, "any rendering, any CSS,
## any component" belongs here instead), and an embedder that renders its own
## panes keeps importing only that.
##
## What is exported are the panes' generic views — one proc each, generic over
## the renderer (Shared-DOM-Front-Ends D3), the very procs the desktop, the web
## page and the VS Code webviews render: `renderCalltracePanel[R, N](r, vm)`,
## `renderStatePanel[R, N](r, vm)`, `renderEventLogPanel[R, N](r, vm)`, over
## the panel ViewModels `codetracer_embed` exports. They are the first pane
## components this package carries (UI-Components §6 step 4), exported for
## BlockTracer's live debugger panes: Shared-DOM-Front-Ends Q6 (decided
## 2026-10-19) — "exported through a facade it can import; its static build
## keeps compiling without codetracer (Mode ∅), with the views only in the
## live build" (HSF-B2).
##
## A consumer writes:
##
## ```nim
## import codetracer_embed, codetracer_ui_components
## import isonim/web/[web_renderer, dom_api]
##
## let panel = renderCalltracePanel[WebRenderer, Element](
##   WebRenderer(), session.session.calltraceVM)
## discard host.appendChild(panel)
## ```
##
## The host arranges and measures (UI-Components §3.2: no layout engine here):
## it tells each ViewModel what its pane shows (`setViewport`,
## Viewport-Driven-Loading V3), as the desktop's panel host does, converting
## the pixels it measures with `pane_viewport`, exported below so every DOM host
## asks for the same window from a pane of the same shape. The views emit
## CodeTracer's class names; the host supplies the stylesheet that draws them.
##
## `ci/test/sdk-facade-boundary.sh` holds this module to its own rule set:
## rendering is what it is for; the desktop is not — no `ui/` module, no
## `frontend/types.nim`, no Electron transport, no Monaco, no GoldenLayout, no
## process spawning and no chain concept may be reachable from it.

const CodeTracerUiComponentsModule* = "codetracer_ui_components"
  ## The module name the boundary guard checks this file declares.

import views/isonim_calltrace_view
export isonim_calltrace_view

import views/isonim_state_view
export isonim_state_view

import views/isonim_event_log_view
export isonim_event_log_view

# A row's logical address and the link builder a host passes the Call Trace
# and Event Log views (Shared-DOM-Front-Ends D10). Rendering-free.
import store/row_address
export row_address

# The conversion a host makes from the pixels it measures on a mounted pane to
# the `Viewport` its ViewModel is told (`pixelPaneViewport`). Rendering-free
# arithmetic; exported here because measuring is the host's half of mounting.
import pane_viewport
export pane_viewport
