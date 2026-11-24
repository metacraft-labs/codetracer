## IsoNim view of a multi-process recording's session tab with its process
## switcher, over `ProcessSwitcherVM` (`viewmodel/process_switcher_vm.nim`;
## CTF-P2c step 5, codetracer-pm `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83). GPUI (`gpui/agent_harbor/ah_process_switcher.nim`)
## and the terminal (`tui/agent_harbor/ah_tui_process_switcher.nim`) draw
## the same viewmodel; what the three decide alike is in
## `agent_harbor_process_switcher_words`.
##
## The tab is CodeTracer's own session tab (`.session-tab`,
## `session_tabs.styl`), active, with the recording's name and, inside it at
## its end, the recording switcher's numbered buttons for the processes --
## the control an initiative's tab draws for its recordings, drawn by its
## own view (`isonim_recording_switcher_view.renderRecordingSwitcher`,
## consumed unchanged; D25, AHF-AREQ2). A plain session tab follows it. The
## production session tab bar (`isonim_session_tabs_view`) is not changed:
## adopting the switcher there is the production slice (D76).
##
## The ring (D81) is the switcher's own (`ah-rec-ringed`, from the
## buttons' `ringed` and `hiddenRinged`); the ringed process is also a fact
## on the tab (`data-ah-process-ringed`, its number) and in that button's
## tooltip (the marker's words, `processButtons`).
##
## SEAM(press): the recording switcher's buttons carry no
## `data-ct-operation` (P1d site 19, left as it is by manager note 143), so
## a press reaches this view through the switcher's `onSelect`, and this
## view hands it to the host's `ProcessPress`, which routes it as the page's
## pointer listener would (`process-switcher.select` with the process as the
## target). Once the buttons carry the operation, the page's listener routes
## them and `onSelect` goes.

import isonim/core/[signals, computation]
import isonim/dsl/ui
from ../input/element_press import OperationAttribute
from ../keymap/scope_path import ProcessSwitcherScope

import ./agent_harbor_process_switcher_words
import ./isonim_recording_switcher_view
from ./isonim_session_tabs_view import SessionTabClass, SessionTabActiveClass,
  SessionTabLabelClass, SessionTabBarClass

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

export signals, computation, agent_harbor_process_switcher_words

static:
  doAssert OperationAttribute == "data-ct-operation"

const
  ProcessSwitcherBarClass* = "ah-ps-bar"
  ProcessSwitcherTabClass* = "ah-ps-tab"

type
  ProcessPress* = proc(operation, target: string)
    ## A host's route for a press: the operation and its target (the
    ## process's recording id).

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc renderAgentHarborProcessSwitcher*[R, N](r: R; vm: ProcessSwitcherVM;
                                            otherTab: string; slots: int;
                                            nextChord, previousChord: string;
                                            press: ProcessPress = nil): N =
  ## The caption bar's session tabs: the recording's tab, active, holding
  ## the switcher (`slots` buttons before `+N`), then `otherTab`. Redrawn as
  ## the processes, the active one and the marker move.
  mixin clearChildren, setAttribute
  var bar: N
  let root = ui(r):
    tdiv(ref = bar, class = SessionTabBarClass & " " & ProcessSwitcherBarClass,
         `data-ah-surface` = ProcessSwitcherSurface)
  createRenderEffect proc() =
    discard vm.entries.val
    discard vm.activeId.val
    discard vm.correlation.val
    r.clearChildren(bar)
    var tab, switchHost: N
    let tabNode = ui(r):
      tdiv(ref = tab, class = SessionTabActiveClass & " " & ProcessSwitcherTabClass,
           title = vm.tabTooltipOf(nextChord, previousChord)):
        span(`data-ah-cut` = "line", class = SessionTabLabelClass):
          text vm.title
        tdiv(ref = switchHost, class = "ah-tab-recordings ah-ps-processes",
             `data-ct-pane` = ProcessSwitcherScope)
    for (k, v) in vm.tabFacts(slots): r.setAttribute(tabNode, "data-ah-" & k, v)
    let buttons = vm.buttons(slots)
    if buttons.buttons.len > 0:
      let route = press
      # SEAM(press): the routed press arrives through the switcher's
      # `onSelect` until its buttons carry `data-ct-operation`.
      r.appendRendered(switchHost, renderRecordingSwitcher[R, N](r, buttons,
        proc(recordingId: string) =
          if route != nil: route(ProcessSelectOperation, recordingId)))
    r.appendRendered(bar, tabNode)
    let other = ui(r):
      tdiv(class = SessionTabClass):
        span(`data-ah-cut` = "line", class = SessionTabLabelClass):
          text otherTab
    r.appendRendered(bar, other)
  root

when defined(js):
  proc mountAgentHarborProcessSwitcher*(container: isonim_dom.Element; vm: ProcessSwitcherVM;
                                        otherTab: string; slots: int;
                                        nextChord, previousChord: string;
                                        press: ProcessPress = nil) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborProcessSwitcher[WebRenderer, isonim_dom.Element](WebRenderer(), vm,
        otherTab, slots, nextChord, previousChord, press)))
