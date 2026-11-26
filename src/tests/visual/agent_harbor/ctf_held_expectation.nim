## ctf_held_expectation.nim — what the GPUI control center's held overview
## must measure, computed from the view code and the story's own data, never
## from a capture.
##
## The layout judge (`ctf_layout_judge.heldOverviewOf`) anchors the
## Initiatives panel to what GPUI drew above it. Two of those anchors are
## sizes a capture could misstate while every link of the chain still holds:
## the Initiatives panel's head band (a head 40px taller moves the list 40px
## lower and keeps "the list starts under the head") and the waiting rows
## drawn (two rows claimed, the second as tall as anything). The web record
## holds neither: it records the first waiting row only, and no head band of
## the Initiatives panel inside the control center. So the judge holds them
## to the heights the GPUI views compute for the story's data at that width
## -- `ah_initiative_panels.initiativesHeadPx` and
## `ah_control_center.waitingRowHeightPx`, the very procs the views size the
## parts with -- over the story's own view model
## (`createControlCenterStoryVM`), built here the way the story host builds it.
##
## Only pure arithmetic of the views is called (text widths from the face's
## metrics, line packing): nothing that needs a GPUI window.

import isonim/core/owner
import nim_agents_isonim_viewmodels/agent_harbor/control_center_vm
import ../../../frontend/stories/agent_harbor_control_center_stories
from ../../../frontend/stories/agent_harbor_playback import isPlaybackFixture
from ../../../frontend/gpui/agent_harbor/ah_initiative_panels import initiativesHeadPx
from ../../../frontend/gpui/agent_harbor/ah_control_center import waitingRowHeightPx,
  TabLinePx, PadXPx, MoreLinePx

type HeldExpectation* = object
  known*: bool
    ## False for a story the expectation cannot be built for (a playback
    ## story's first frame needs its playback; no such capture holds its
    ## overview).
  headPx*: int
    ## The Initiatives panel's head band, as the view draws it at the width.
  waitingRowPx*: seq[int]
    ## Each waiting row's height, in the list's order, as the view draws it.
  morePx*: int
    ## The waiting list's `+N more` line, as tall as the view draws it (a
    ## fixed line height): a taller line would move the panel under it while
    ## every link of the judge's chain still held.

proc heldExpectationOf*(surface, fixture: string; widthPx: int): HeldExpectation =
  ## The heights for the story `surface`/`fixture` at `widthPx`: the control
  ## center's own stories, and the gaze stories, which draw the control
  ## center of the populated fixture over the status line
  ## (`ah_stories.mountAgentHarborStoryGpui`).
  let ccFixture =
    case surface
    of "agent-harbor-control-center": fixture
    of "agent-harbor-status-gaze": "populated"
    else: ""
  if ccFixture.len == 0 or isPlaybackFixture(ccFixture): return
  var res: HeldExpectation
  createRoot proc(dispose: proc()) =
    let vm = createControlCenterStoryVM(ccFixture)
    res.known = true
    res.morePx = MoreLinePx
    res.headPx = vm.initiatives.initiativesHeadPx(widthPx, TabLinePx)
    for row in vm.waiting:
      res.waitingRowPx.add waitingRowHeightPx(row, widthPx - 2 * PadXPx)
    dispose()
  res
