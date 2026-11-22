## IsoNim view of the status line's gaze mark, over `GazeStatusVM`
## (nim-agents-isonim-viewmodels): while gaze is tracked an eye and `Gaze`
## in the quiet role; while paused the eye struck through and `Gaze
## paused`; when off, nothing (the host stays empty). Its tooltip names the
## key that pauses and resumes tracking. GPUI
## (`gpui/agent_harbor/ah_gaze_mark.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_gaze_mark.nim`) draw the same viewmodel; what
## the three decide alike is in `agent_harbor_gaze_words`.
##
## The mark is a status-line item (`status-inline`), so it sits in the
## status bar's right-hand zone at the bar's own size and spacing
## (`agent_harbor_gaze_mark.styl`). A press on it is routed
## (Input-Routing-And-Keymaps.md §5.1): it carries `gaze.toggle-pause` and
## holds no handler.

import isonim/core/[signals, computation]
import isonim/dsl/ui
from ../input/element_press import OperationAttribute

import ./agent_harbor_gaze_words

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

  proc setInnerHtml(node: isonim_dom.Node; html: cstring) {.importjs: "#.innerHTML = #".}

export agent_harbor_gaze_words

static:
  doAssert OperationAttribute == "data-ct-operation"

const
  GazeMarkClass* = "ah-gaze-mark"

proc renderAgentHarborGazeMark*[R, N](r: R; vm: GazeStatusVM): N =
  ## A host that holds the mark while it is shown, redrawn as the state
  ## moves.
  mixin clearChildren, setAttribute, appendChild
  var host: N
  let root = ui(r):
    span(ref = host, class = "ah-gaze-host", `data-ah-surface` = GazeSurface)
  createRenderEffect proc() =
    discard vm.state.val
    r.clearChildren(host)
    for (k, v) in vm.markFacts: r.setAttribute(root, "data-ah-" & k, v)
    if not vm.shown: return
    var glyph: N
    let mark = ui(r):
      span(class = GazeMarkClass & " status-inline" &
                   (if vm.struck: " ah-gaze-paused" else: ""),
           role = "button", title = vm.tooltip, `aria-label` = vm.text,
           `data-ct-operation` = GazeTogglePauseOperation):
        span(ref = glyph, class = "ah-gaze-glyph")
        span(class = "ah-gaze-text"):
          text vm.text
    when defined(js):
      when N is isonim_dom.Element:
        setInnerHtml(isonim_dom.Node(glyph),
                     cstring(if vm.struck: GazeEyeStruckSvg else: GazeEyeSvg))
    r.appendChild(host, mark)
  root

when defined(js):
  proc mountAgentHarborGazeMark*(container: isonim_dom.Element; vm: GazeStatusVM) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborGazeMark[WebRenderer, isonim_dom.Element](WebRenderer(), vm)))
