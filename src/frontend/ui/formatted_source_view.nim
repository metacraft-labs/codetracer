## ui/formatted_source_view.nim — the desktop's toggle into a minified
## source's formatted view.
##
## Column-Aware-Navigation (codetracer-pm `milestones/Column-Aware-Navigation.status.org`
## §M3): a recording of a minified source whose source map is known to the
## replay server (a `.map` beside the source, or a view the recorder baked
## into the trace) can be replayed through that map. The view is per session
## on the replay server and the GUI sends `ct/set-active-source-view` on a
## view toggle. This module is that toggle's logic; the command palette's
## **View: Toggle Formatted Source View** (`aToggleFormattedSourceView`)
## runs it.
##
## While the view is on, the replay server translates every stop through the
## map, so the editor follows the formatted source, and Step Over advances one
## formatted line (Shift+F10 one formatted statement) instead of one minified
## line. Off, the replay is the recorded minified one again.
##
## The replay server only asks whether a view is active, and finds the map
## for each recorded path itself, so the request names the file the replay is
## stopped in; turning the view off sends no path.

const ToggleFormattedSourceViewLabel* = "View: Toggle Formatted Source View"
  ## The command palette's entry (`ui_js.refreshCommandPaletteMenuIndex`).

func formattedViewRequestPath*(on: bool; stoppedIn: string): string =
  ## The `viewPath` of the `ct/set-active-source-view` request that turns the
  ## view `on` (the file the replay is stopped in) or off ("").
  if on: stoppedIn else: ""

func formattedViewNotice*(on: bool): string =
  ## What the status bar says after a toggle.
  if on:
    "Formatted source view on: steps move by the formatted source's lines"
  else:
    "Formatted source view off: steps move by the recorded source's lines"

func toggledFormattedView*(on: bool; stoppedIn: string):
    tuple[on: bool; viewPath: string; notice: string] =
  ## One toggle from state `on`, stopped in `stoppedIn`: the new state, the
  ## request's path and the notice.
  let next = not on
  (next, formattedViewRequestPath(next, stoppedIn), formattedViewNotice(next))
