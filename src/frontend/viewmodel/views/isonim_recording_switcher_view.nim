## IsoNim view of the recording switcher: numbered buttons `1 2 3 …` that
## select one of several recordings grouped for browsing together, over the
## switcher's contract (nim-agents-isonim-viewmodels
## `agent_harbor/recording_switcher.nim`).
##
## One control for both of its uses: inside an Agent Harbor initiative's tab
## it selects the replays loaded for the initiative; for a multi-process
## recording it selects the process. (The multi-process session keeps its
## process tree sidebar, `isonim_process_tree_view.nim`; drawing its
## processes with this control is a later slice.) The buttons are the
## caption bar's small square controls: the active one raised like the
## active session tab, a loading one quiet, a failed one in the error text
## colour, a missing one in the warning colour; each tooltip names the
## recording, its revision and its origin.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/recording_switcher

export signals, computation, components, recording_switcher

const
  RecordingSwitcherClass* = "ah-rec-switch"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

proc stateSuffix*(state: RecordingState): string =
  ## A recording's state as it reads on the button itself: still loading
  ## `2 …`, failed to load `3 ✕`, no longer there `4 ?`; a ready one is its
  ## number alone.
  case state
  of rsReady: ""
  of rsLoading: " \xE2\x80\xA6"
  of rsFailed: " \xE2\x9C\x95"
  of rsMissing: " ?"

proc invokeSelect(onSelect: proc(id: string); id: string) =
  if onSelect != nil: onSelect(id)

proc renderRecordingButton[R](r: R; rb: RecordingButton;
                              onSelect: proc(id: string)): auto =
  let id = rb.id
  var node: typeof(r.createElement("button"))
  let res = ui(r):
    button(ref = node,
           class = "ah-rec-button ah-rec-" & $rb.state &
                   (if rb.active: " ah-rec-active" else: ""),
           title = rb.tooltip,
           onclick = proc() = invokeSelect(onSelect, id)):
      text $rb.number & stateSuffix(rb.state)
  when defined(js):
    when typeof(node) is isonim_dom.Element:
      # Inside a tab: choosing a recording does not also re-activate the tab.
      isonim_dom.addEventListener(isonim_dom.Node(node), cstring"click",
        proc(ev: isonim_dom.Event) = ev.stopPropagation())
  res

proc renderRecordingSwitcher*[R, N](r: R; buttons: RecordingButtons;
                                    onSelect: proc(id: string) = nil): N =
  ## The buttons, and `+N` for the recordings beyond them.
  var host: N
  let res = ui(r):
    tdiv(ref = host, class = RecordingSwitcherClass, role = "group",
         title = "Recordings")
  for rb in buttons.buttons:
    r.appendRendered(host, renderRecordingButton(r, rb, onSelect))
  if buttons.hidden > 0:
    let more = ui(r):
      span(class = "ah-rec-more", title = $buttons.hidden & " more recordings"):
        text "+" & $buttons.hidden
    r.appendRendered(host, more)
  res
