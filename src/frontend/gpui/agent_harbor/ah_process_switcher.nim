## gpui/agent_harbor/ah_process_switcher.nim — CTF-P2c step 5. The GPUI
## multi-process recording session tab with its process switcher, over
## `ProcessSwitcherVM` (`viewmodel/process_switcher_vm.nim`), drawn as the
## web's `isonim_agent_harbor_process_switcher_view` draws it, from the same
## words (`agent_harbor_process_switcher_words`; codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83).
##
## The story draws the caption bar's line of tabs (34px, the bar's ground,
## as GPUI's own top bar, `window_top_bar.TopBarPx`, and the web's `#menu`;
## its 30px strip line 4px down, `StripTopPx`, so the tab is 6px down):
## the recording's tab, active (26px, the active tab's ground, 10px in), its
## name in the tab's 16px and, at its end, the recording switcher's numbered
## buttons for the processes; then a plain tab; an empty working area below.
##
## THE BUTTONS ARE THE INITIATIVE BAR'S OWN DRAWING. The tab takes a
## `SwitcherSlot`; `RecordingSwitcherSlot`, the default, draws the buttons
## with GPUI's recording button where it lives, in the initiative bar
## (`ah_initiative_tab_bar.drawRecordingButton` with the press reported
## here, and `drawRecordingsMore`; P1d site 19), which also draws the ring
## (D81). Moving that drawing to a module of its own comes after CTF-P1d
## step 5b (manager note 143).
##
## Facts (`data-ah-*`): `surface` on the story's root, `tabFacts`, `tab`,
## `active` and `tooltip` on the recording's tab.

import isonim/core/computation
import ../../viewmodel/views/agent_harbor_process_switcher_words
import ./ah_theme
import ./ah_initiative_tab_bar
from ./ah_session_views import StripTopPx
import ../../styles/generated/design_tokens

export agent_harbor_process_switcher_words

const
  TabPadPx* = 10            ## `.session-tab` padding: 0 0.625em
  TabGapPx* = 8             ## `.ah-ps-tab` gap: 0.5rem
  TabMarginPx* = 4          ## `.session-tab` margin-right: 0.25em
  OtherTabPx* = 96          ## a plain tab's `min-width: 6em`
  NarrowBelowPx* = 720      ## the narrow window draws two buttons before `+N`

type
  ProcessPress* = proc(operation, target: string)
    ## A host's route for a press: the operation and its target (the
    ## process's recording id).

  SwitcherSlot* = object
    ## How a tab draws the recording switcher's buttons.
    draw*: proc(r: GpuiRenderer; p: AhPalette; buttons: RecordingButtons;
                press: ProcessPress): GpuiElement
      ## The buttons' row (nil when it draws nothing); each button's press
      ## reports `process-switcher.select` with its process.

proc switcherDraw(r: GpuiRenderer; p: AhPalette; buttons: RecordingButtons;
                  press: ProcessPress): GpuiElement =
  ## The buttons 2px apart and `+N`, as the initiative tab draws them; a
  ## press reports `process-switcher.select`.
  result = r.box(pairs = [("gap", $RecordingButtonGapPx & "px"), ("items", "center"),
                          ("flex-shrink", "0")])
  r.tag(result, "process-recordings", $buttons.buttons.len)
  let route = press
  let select = proc(id: string) =
    if route != nil: route(ProcessSelectOperation, id)
  for rb in buttons.buttons:
    r.appendChild(result, r.drawRecordingButton(p, nil, "", rb, select))
  if buttons.hidden > 0:
    r.appendChild(result, r.drawRecordingsMore(p, buttons, "process", "processes"))

let RecordingSwitcherSlot* = SwitcherSlot(draw: switcherDraw)
  ## The recording switcher's own drawing (`ah_initiative_tab_bar`).

proc plainTabInk*(p: AhPalette): string =
  ## A plain session tab's name in the caption role, quiet beside the
  ## active tab's (brief, "The process switcher"). In Dark it is drawn as
  ## CodeTracer's own `.session-tab` draws it (session_tabs.styl): `#b0b0b0`
  ## (`activeTabOrigin`) dimmed by the tab's `opacity: 0.7` over the caption
  ## bar's ground, #838383 at 4.5:1; drawn at the caption token's full
  ## strength it was nearly as bright as the active tab's name (GPUI review
  ## of 2026-11-25). In Light the same opacity leaves the caption token at
  ## 2.5:1 on the bar, under the text floor, so Light keeps the caption
  ## token itself (4.2:1), already well under the active tab's body ink.
  if p.mode == dmDark: mixInk(p.activeTabOrigin, p.ground, 30)
  else: p.textCaption

proc slotsForPx*(widthPx: int): int =
  ## The buttons a tab draws before `+N`: two on a narrow window, else five
  ## (the web story's `slotsFor`).
  if widthPx < NarrowBelowPx: 2 else: 5

proc drawProcessSwitcherStory*(r: GpuiRenderer; host: GpuiElement; vm: ProcessSwitcherVM;
                               p: AhPalette; widthPx, heightPx: int; otherTab: string;
                               nextChord, previousChord: string;
                               slot = RecordingSwitcherSlot; press: ProcessPress = nil) =
  ## The story's window: the caption bar's line of tabs, an empty working
  ## area under it.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", DesignTokenHex[dtColorsUiSurfaceBaseCanvas][p.mode])])
  r.tag(host, "surface", ProcessSwitcherSurface)
  # The bar the web's caption bar is (`#menu`, 34px): its strip line
  # `StripTopPx` down, as the initiative bar's, so the tab sits 6px under the
  # window's top and the bar ends 2px under it. It was the 30px line alone,
  # the tab 2px under the top in a bar 4px shorter than the web's.
  let bar = r.box(column = true, pairs = [("padding-top", $StripTopPx & "px"),
                                          ("background", p.ground), ("flex-shrink", "0")])
  r.tag(bar, "caption-bar", "")
  let line = r.box(pairs = [("height", $StripLinePx & "px"), ("items", "center"),
                            ("padding-left", "8px"), ("padding-right", "4px"),
                            ("flex-shrink", "0"), ("overflow", "hidden")])
  r.appendChild(bar, line)
  let slots = slotsForPx(widthPx)
  let tab = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                           ("gap", $TabGapPx & "px"),
                           ("padding-left", $TabPadPx & "px"),
                           ("padding-right", $TabPadPx & "px"),
                           ("margin-right", $TabMarginPx & "px"),
                           ("rounded", $ControlRadiusPx & "px"),
                           ("background", p.activeTab), ("flex-shrink", "1"),
                           ("min-width", $OtherTabPx & "px"), ("overflow", "hidden")])
  r.tag(tab, "tab", vm.title)
  r.tag(tab, "active", "true")
  r.tag(tab, "tooltip", vm.tabTooltipOf(nextChord, previousChord))
  for (k, v) in vm.tabFacts(slots): r.tag(tab, k, v)
  let title = r.text(vm.title, BodyLargePx, p.activeTabText,
                     pairs = [("flex-shrink", "1"), ("min-width", "0px")])
  r.tag(title, "label", vm.title)
  r.appendChild(tab, title)
  let buttons = vm.buttons(slots)
  if buttons.buttons.len > 0:
    let row = slot.draw(r, p, buttons, press)
    if row != nil: r.appendChild(tab, row)
  r.appendChild(line, tab)
  let other = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                             ("padding-left", $TabPadPx & "px"),
                             ("padding-right", $TabPadPx & "px"),
                             ("min-width", $OtherTabPx & "px"), ("flex-shrink", "0")])
  r.tag(other, "tab", otherTab)
  r.tag(other, "active", "false")
  let otherInk = plainTabInk(p)
  r.tag(other, "ink", otherInk)
  r.appendChild(other, r.text(otherTab, BodyLargePx, otherInk, shrink = false))
  r.appendChild(line, other)
  r.appendChild(host, bar)
  r.appendChild(host, r.box(pairs = [("flex-grow", "1")]))

proc mountProcessSwitcherStory*(r: GpuiRenderer; host: GpuiElement; vm: ProcessSwitcherVM;
                                p: AhPalette; widthPx, heightPx: int; otherTab: string;
                                nextChord, previousChord: string;
                                slot = RecordingSwitcherSlot; press: ProcessPress = nil) =
  ## Draws the story, and again whenever the processes, the active one or
  ## the marker move.
  createRenderEffect proc() =
    discard vm.entries.val
    discard vm.activeId.val
    discard vm.correlation.val
    drawProcessSwitcherStory(r, host, vm, p, widthPx, heightPx, otherTab,
                             nextChord, previousChord, slot, press)
