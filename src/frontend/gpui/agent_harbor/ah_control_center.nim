## gpui/agent_harbor/ah_control_center.nim — CTF-P2c step 4. The GPUI
## control center: the tab titled `Control Center` that fills the window,
## over `ControlCenterVM` (nim-agents-isonim-viewmodels), drawn as the web's
## `isonim_agent_harbor_control_center_view` draws it
## (`agent_harbor_control_center.styl`), from the same words
## (`agent_harbor_control_center_words`).
##
## Two columns on the canvas ground with the layout's 4px gap between them,
## the launch column `max(320px, 45%)` wide (the web's `minmax(20rem, 0.9fr)
## minmax(0, 1.1fr)`); one column below 720px, launching first (GPUI does not
## scroll a box: what is below the window is clipped, where the web's tab
## scrolls).
##
## - **Launch** (the panel's ground, 8px by 12px in, 8px between parts):
##   `LAUNCH`; the mode toggles; `For` and its toggles; the instruction's
##   field; the composer's own form (`ah_composer.drawLaunchForm`) and send
##   line (`sendLine`, bare); Agent Harbor's answer to the last launch;
##   `RECENT LAUNCHES`.
## - **Overview**: first, on the panel's ground under a panel's head band
##   and at most 45% of the height, `WAITING FOR YOU` and one row per
##   waiting session (study D73); then the Initiatives panel, the same
##   drawing as everywhere (`ah_initiative_panels.drawInitiativesPanel`,
##   unchanged; with an empty fleet `No initiatives yet.` in its place),
##   filling the rest. A waiting row: its title (14px on 20px), its state word in its role
##   and its initiative and age (12px on 16px), and why it waits (12px on
##   16px, at most two lines). A row draws no dot and no pie.
##
## Presses are routed, as the composer's: each element a press acts on
## carries its operation and target and reports both to the host's
## `ControlCenterPress` (the hit test), which resolves and runs it
## (`runControlCenterPress`).
##
## Facts (`data-ah-*`): `centerFacts` on the root (and `surface`),
## `cc-launch` and `cc-overview` on the columns, `waitingFacts` on each
## waiting row, `recentFacts` on each recent launch, `cc-notice-line`.

import isonim/core/computation
import nim_agents_isonim_viewmodels/agent_harbor/control_center_vm
import ../../styles/generated/design_tokens
import ../../viewmodel/views/agent_harbor_control_center_words
import ../../viewmodel/input/element_press
import ./ah_theme
import ./ah_composer
import ./ah_initiative_panels
from ./ah_session_activity import wrappedRows
import ../../../common/pointer_shape

export agent_harbor_control_center_words

const
  NarrowBelowPx* = ControlCenterNarrowBelow
  ColumnGapPx* = 4        ## the layout's splitter (AH_CC_GAP)
  PadXPx* = InsetPx       ## AH_CC_PAD: the panels' inset
  PadYPx* = 8
  PartGapPx* = 8          ## between the launch column's parts
  SectionPx* = 4 + 24     ## a section label: 0.25rem over a 1.5rem line
  TabLinePx* = 21
    ## The line the tab's parts inherit: `.ah-control-center` is set at the
    ## body size (14px) on 1.5 lines, where a panel on its own is set at
    ## 16px on 24px lines. The heads' spans are set on it
    ## (`agent_harbor_control_center.styl`), and the Initiatives panel and
    ## the form inherit it.
  HeadPx* = 4 + TabLinePx + 4 + 1
    ## A panel's head band (`drawSectionHeader`): 4px over and under the
    ## tab's line, and its hairline.
  ListPadPx = 4           ## the waiting list's rows' inset above and below
  PanelMinPx = 192        ## the panel's least height in one column (12rem)
  NoneLinePx = 4 + 16 + 4
    ## A "nothing here" line (`.ah-cc-none`): a caption line padded 0.25rem
    ## above and below.
  FieldLabelPx = 18
    ## A form field's label line: the caption (12px) on the tab's 1.5 lines,
    ## not the composer sheet's 24px (`LinePx`), which the sheet sets itself.
  TitleLinePx = 20        ## a waiting row's title, a recent launch's text
  RowPadPx = 6            ## a waiting row's padding
  RecentPadPx = 4         ## a recent launch's padding

proc renameFact(r: GpuiRenderer; e: GpuiElement; name, to: string) =
  ## Every `data-ah-<name>` in `e`'s tree moved to `data-ah-<to>` (the old
  ## one emptied: an empty fact reads as none).
  if e.isNil: return
  let v = getAttribute(e, "data-ah-" & name)
  if v.len > 0:
    r.setAttribute(e, "data-ah-" & name, "")
    r.tag(e, to, v)
  for i in 0 ..< childCount(e): r.renameFact(nthChild(e, i), name, to)

proc acts(r: GpuiRenderer; el: GpuiElement; operation, target: string;
          press: ControlCenterPress) =
  r.setAttribute(el, OperationAttribute, operation)
  r.setAttribute(el, "data-ah-target", target)
  r.setStyle(el, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
  if press != nil:
    r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(operation, target))

proc launchWidthPx*(widthPx: int): int =
  ## The launch column's width in two columns: 45% of the tab, never under
  ## 320px and never over 640px (the web's `minmax(20rem, min(45%, 40rem))`).
  max(320, min(640, widthPx * 45 div 100))

proc sectionLabel(r: GpuiRenderer; p: AhPalette; words: string): GpuiElement =
  result = r.text(words, CaptionPx, p.textLabel, bold = true, shrink = false,
                  pairs = [("letter-spacing", LabelTracking), ("height", $SectionPx & "px"),
                           ("padding-top", "4px"), ("line-height", "24px")])
  r.tag(result, "section", words)

proc toggleEl(r: GpuiRenderer; p: AhPalette; label, operation, target: string;
              on: bool; press: ControlCenterPress): (GpuiElement, int) =
  ## A toggle as the composer's form draws one: 24px, 8px each side, the
  ## chosen one in the action border.
  let el = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("padding-left", "8px"), ("padding-right", "8px"),
                          ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                          ("border-width", "1px"),
                          ("border-color", if on: p.borderAction else: p.borderSecondary)])
  r.appendChild(el, r.text(label, CaptionPx, if on: p.textBody else: p.textLabel,
                           shrink = false))
  r.tag(el, "toggle", label)
  r.tag(el, "chosen", $on)
  r.acts(el, operation, target, press)
  (el, textPx(label, CaptionPx) + 18)

proc toggleItem(el: GpuiElement; widthPx: int; label: string): FlowItem =
  ## A toggle in a wrapping row, with its exact width (the face's kerned
  ## advances), so the row breaks where the browser's does.
  FlowItem(el: el, widthPx: widthPx,
           exactPx: textWidth(label, CaptionPx, faceGlyphs = true) + 18)

proc toggleRow(r: GpuiRenderer; items: seq[FlowItem]; widthPx: int): (GpuiElement, int) =
  let lines = flowLineCount(items, widthPx, 4)
  (r.flowLines(items, widthPx, 4, ControlPx, 4), lines * ControlPx + (lines - 1) * 4)

proc caption(r: GpuiRenderer; s, ink: string; widthPx: int; maxLines = 0): (GpuiElement, int) =
  ## A caption wrapped at `widthPx` (12px on 16px), at most `maxLines`.
  var lines = wrappedRows(s, CaptionPx, widthPx)
  if maxLines > 0: lines = min(lines, maxLines)
  let el = r.text(s, CaptionPx, ink, shrink = false,
                  pairs = [("white-space", "pre-wrap"), ("line-height", "16px"),
                           ("width", $widthPx & "px"), ("height", $(16 * lines) & "px"),
                           ("overflow", "hidden")])
  (el, 16 * lines)

proc launchColumn(r: GpuiRenderer; p: AhPalette; vm: ControlCenterVM;
                  widthPx: int; press: ControlCenterPress): (GpuiElement, int) =
  ## The launch column's parts, `widthPx` wide, and the height they take.
  let inner = widthPx - 2 * PadXPx
  let c = vm.composer
  let col = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                          ("background", p.panel),
                                          ("overflow", "hidden"), ("flex-shrink", "0")])
  r.tag(col, "cc-launch", "launch")
  # The head band every panel of the tab has (the Initiatives panel's own),
  # so the columns' heads line up; the parts under it at the panel's inset.
  let head = r.drawSectionHeader(p, LaunchHeading, "", "", widthPx, linePx = TabLinePx)
  r.tag(head, "head", "launch")
  r.appendChild(col, head)
  let body = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                           ("padding-left", $PadXPx & "px"),
                                           ("padding-right", $PadXPx & "px"),
                                           ("padding-top", $PadYPx & "px"),
                                           ("gap", $PartGapPx & "px"), ("flex-shrink", "0")])
  r.appendChild(col, body)
  var h = HeadPx + 2 * PadYPx
  var parts = 0
  proc add(el: GpuiElement; px: int) =
    r.appendChild(body, el)
    h += px
    inc parts
  var modes: seq[FlowItem]
  for (_, label, operation, on) in vm.modeChoices:
    let (el, w) = r.toggleEl(p, label, operation, "", on, press)
    modes.add toggleItem(el, w, label)
  let (modesEl, modesH) = r.toggleRow(modes, inner)
  r.tag(modesEl, "cc-modes", $vm.mode)
  add(modesEl, modesH)
  # `For`: no initiative, or one of them.
  let forEl = r.box(column = true, pairs = [("gap", "3px"), ("width", $inner & "px")])
  r.tag(forEl, "field-label", ForLabel)
  r.appendChild(forEl, r.text(ForLabel, CaptionPx, p.textLabel, shrink = false,
                              pairs = [("height", $FieldLabelPx & "px"),
                                       ("line-height", $FieldLabelPx & "px")]))
  var choices: seq[FlowItem]
  for choice in vm.launchChoices:
    let (el, w) = r.toggleEl(p, choice.title, ControlCenterLaunchForOperation, choice.id,
                             choice.chosen, press)
    choices.add toggleItem(el, w, choice.title)
  let (choicesEl, choicesH) = r.toggleRow(choices, inner)
  r.appendChild(forEl, choicesEl)
  add(forEl, FieldLabelPx + 3 + choicesH)
  # The instruction's field: the composer's text, or the placeholder.
  let whole = c.text
  let fieldEl = r.box(column = true, pairs = [("gap", "3px"), ("width", $inner & "px")])
  r.tag(fieldEl, "field-label", InstructionLabel)
  r.appendChild(fieldEl, r.text(InstructionLabel, CaptionPx, p.textLabel, shrink = false,
                                pairs = [("height", $FieldLabelPx & "px"),
                                         ("line-height", $FieldLabelPx & "px")]))
  let box = r.box(pairs = [("height", $ControlPx & "px"), ("items", "start"),
                           ("padding-left", "8px"), ("padding-right", "8px"),
                           ("rounded", $ControlRadiusPx & "px"), ("border-width", "1px"),
                           ("border-color", p.borderSecondary), ("background", p.ground),
                           ("overflow", "hidden")])
  let shown = if whole.len > 0: inputValueShown(whole, inner) else: vm.instructionPlaceholder
  let t = r.text(shown, BodyPx, if whole.len > 0: p.textBody else: p.textCaption,
                 pairs = [("height", $ControlPx & "px"), ("line-height", $ControlPx & "px")])
  r.tag(t, "value", whole)
  r.appendChild(box, t)
  r.appendChild(fieldEl, box)
  add(fieldEl, FieldLabelPx + 3 + ControlPx)
  # The composer's own form, its parts padded to the column's sides: drawn
  # into the column's inner width, the padding taken back (the web's grid
  # sits in the column's padding box).
  if c.showsForm:
    let (form, formH) = r.drawLaunchForm(p, c, inner, inner < 480,
      proc(operation, target: string) =
        if press != nil: press(operation, target), padPx = 0,
      labelLinePx = FieldLabelPx, bodyLinePx = TabLinePx)
    r.tag(form, "form", $c.intent)
    add(form, formH)
  if c.showsSendLine:
    let line = r.sendLine(p, c, proc(operation, target: string) =
      if press != nil: press(operation, target), ruled = false)
    r.setStyle(line, "width", $inner & "px")
    r.tag(line, "send-for", launchForLabel(vm.launchForTitle))
    add(line, ControlPx)
  let (words, failed, pending) = vm.launchNotice
  if words.len > 0:
    let ink = if failed: p.textError elif pending: p.textCaption else: p.textBody
    let (n, nh) = r.caption(words, ink, inner)
    r.tag(n, "cc-notice-line", words)
    add(n, nh)
  # Recent launches, 8px further down.
  let recent = r.box(column = true, pairs = [("gap", "2px"), ("margin-top", "8px"),
                                             ("width", $inner & "px")])
  var rh = 8 + SectionPx
  r.appendChild(recent, r.sectionLabel(p, RecentLaunchesLabel))
  let launches = vm.recent
  if launches.len == 0:
    let (none, noneH) = r.caption(NoRecentLaunchesWords, p.textCaption, inner)
    r.styles(none, [("padding-top", "4px"), ("padding-bottom", "4px"),
                    ("height", $(noneH + 8) & "px")])
    r.appendChild(recent, none)
    rh += 2 + noneH + 8
  for launch in launches:
    let row = r.box(column = true, pairs = [("padding-top", $RecentPadPx & "px"),
                                            ("padding-bottom", $RecentPadPx & "px"),
                                            ("width", $inner & "px")])
    for (k, v) in launch.recentFacts: r.tag(row, k, v)
    r.appendChild(row, r.text(launch.text, BodyPx, p.textBody,
                              pairs = [("height", $TitleLinePx & "px"),
                                       ("line-height", $TitleLinePx & "px")]))
    r.appendChild(row, r.text(recentLine(launch), CaptionPx,
                              if launch.failed: p.textError else: p.textCaption,
                              pairs = [("height", "16px"), ("line-height", "16px")]))
    r.appendChild(recent, row)
    rh += 2 + 2 * RecentPadPx + TitleLinePx + 16
  add(recent, rh)
  h += PartGapPx * max(0, parts - 1)
  (col, h)

proc waitingRowHeightPx(row: WaitingRow; innerPx: int): int =
  let why = row.waitingWhy
  result = 2 * RowPadPx + TitleLinePx + 1 + 16
  if why.len > 0: result += 1 + 16 * min(2, wrappedRows(why, CaptionPx, innerPx))

proc waitingHeightPx*(vm: ControlCenterVM; innerPx: int): int =
  ## The waiting section's content height: its head band, its rows' inset,
  ## its rows (or its "nothing waits" line).
  result = HeadPx + 2 * ListPadPx
  let rows = vm.waiting
  if rows.len == 0: return result + NoneLinePx
  for row in rows: result += waitingRowHeightPx(row, innerPx)

proc stateInk(p: AhPalette; attention: SessionAttention): string =
  ## Needs input: the warning role, Light's readable hover step at caption
  ## size (the web's and the composer's rule); an ended turn: the caption.
  if attention != saNeedsInput: p.textCaption
  elif p.mode == dmDark: p.textWarning
  else: DesignTokenHex[dtColorsUiTextWarningPrimaryHover][p.mode]

proc drawWaitingRow(r: GpuiRenderer; p: AhPalette; row: WaitingRow; innerPx: int;
                    focused: bool; press: ControlCenterPress): GpuiElement =
  let h = waitingRowHeightPx(row, innerPx)
  # The row spans the column, its words inset by the panel's inset: the
  # web's row (`.ah-cc-waiting-row`, `padding: 0.375rem 0.5rem; margin: 0
  # -0.5rem`, 0.5rem being the list's side padding, `AH_CC_PAD`) takes that
  # padding back, so its ground and its focus bar reach the column's edges.
  result = r.box(column = true, pairs = [("height", $h & "px"),
                                         ("width", $(innerPx + 2 * PadXPx) & "px"),
                                         ("padding-left", $PadXPx & "px"),
                                         ("padding-right", $PadXPx & "px"),
                                         ("padding-top", $RowPadPx & "px"),
                                         ("gap", "1px"), ("flex-shrink", "0"),
                                         ("overflow", "hidden")])
  for (k, v) in row.waitingFacts(focused): r.tag(result, k, v)
  r.tag(result, "accessible-name", row.item.title & ", " & row.words)
  if focused: r.setStyle(result, "box-shadow", "inset 2px 0 0 " & p.borderAction)
  r.appendChild(result, r.text(row.item.title, BodyPx, p.textBody,
                               pairs = [("height", $TitleLinePx & "px"),
                                        ("line-height", $TitleLinePx & "px")]))
  let meta = r.box(pairs = [("gap", "8px"), ("height", "16px"), ("items", "center")])
  let word = r.text(row.stateWordOf, CaptionPx, stateInk(p, row.item.attention),
                    shrink = false, pairs = [("line-height", "16px")])
  r.tag(word, "ink", stateInk(p, row.item.attention))
  r.appendChild(meta, word)
  r.appendChild(meta, r.text(row.waitingMeta, CaptionPx, p.textCaption,
                             pairs = [("line-height", "16px")]))
  r.appendChild(result, meta)
  let why = row.waitingWhy
  if why.len > 0:
    let (w, _) = r.caption(why, p.textBody, innerPx, maxLines = 2)
    r.appendChild(result, w)
  r.acts(result, ControlCenterOpenSessionOperation, row.item.id, press)

proc overviewColumn(r: GpuiRenderer; p: AhPalette; vm: ControlCenterVM;
                    widthPx, heightPx: int; press: ControlCenterPress;
                    oneColumn = false): GpuiElement =
  ## The waiting sessions over the Initiatives panel, `widthPx` ×
  ## `heightPx` (study D73): the waiting list as tall as its rows and at
  ## most 45%, the panel filling the rest. In one column (`oneColumn`) the
  ## tab scrolls instead: the waiting list as tall as all its rows and the
  ## panel as tall as its rows, the column at least `heightPx` (what is left
  ## of the window) and at least 12rem of panel, as the web's one-column
  ## rules lay it out (`[data-ah-columns="one"]`: `.ah-cc-waiting
  ## max-height: none`, the panel `flex: 1 0 auto; min-height: 12rem`).
  result = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                         ("gap", $ColumnGapPx & "px"),
                                         ("overflow", "hidden"), ("flex-shrink", "0")])
  r.setStyle(result, if oneColumn: "min-height" else: "height", $heightPx & "px")
  r.tag(result, "cc-overview", "overview")
  let inner = widthPx - 2 * PadXPx
  let ready = vm.state == asReady
  let waitingH = if not ready: 0
                 elif oneColumn: vm.waitingHeightPx(inner)
                 else: min(heightPx * 45 div 100, vm.waitingHeightPx(inner))
  let restH0 = heightPx - (if waitingH > 0: waitingH + ColumnGapPx else: 0)
  let restH = if oneColumn: max(PanelMinPx, restH0) else: restH0
  if ready:
    let waiting = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                                ("height", $waitingH & "px"),
                                                ("background", p.panel),
                                                ("overflow", "hidden"), ("flex-shrink", "0")])
    r.tag(waiting, "waiting-section", $vm.waiting.len)
    let rows = vm.waiting
    let head = r.drawSectionHeader(p, WaitingHeading, "", waitingCountText(rows.len), widthPx,
                                   linePx = TabLinePx)
    r.tag(head, "head", "waiting")
    # The count sits where a panel has its summary, but the tab's summary is
    # the Initiatives panel's own: a reader of the tab finds that one.
    r.renameFact(head, "summary", "waiting-count")
    r.appendChild(waiting, head)
    # The rows span the column (`drawWaitingRow`); the "nothing waits"
    # line keeps the panel's inset.
    let list = r.box(column = true, pairs = [("padding-top", $ListPadPx & "px"),
                                             ("flex-shrink", "0")])
    if rows.len == 0:
      let (none, _) = r.caption(NothingWaitingWords, p.textCaption, inner)
      r.styles(none, [("margin-left", $PadXPx & "px"), ("padding-top", "4px"),
                      ("padding-bottom", "4px"), ("height", $NoneLinePx & "px")])
      r.appendChild(list, none)
    let focused = vm.focused.val
    for row in rows:
      r.appendChild(list, r.drawWaitingRow(p, row, inner, row.item.id == focused, press))
    r.appendChild(waiting, list)
    r.appendChild(result, waiting)
  if vm.isEmptyFleet:
    # An empty fleet's line in the panel's place, filling it.
    let empty = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                              ("background", p.panel),
                                              ("flex-shrink", "0")])
    # The 12rem least height is the Initiatives panel's (`.agent-harbor-
    # initiatives`), not this line's: it fills what is left, no more.
    r.setStyle(empty, if oneColumn: "min-height" else: "height", $max(0, restH0) & "px")
    # The panel's place keeps a panel's head band: the Initiatives panel's
    # title and source, then the line.
    let head = r.drawSectionHeader(p, "Initiatives", vm.initiatives.sourceLabel, "", widthPx,
                                   linePx = TabLinePx)
    r.tag(head, "head", "initiatives")
    r.appendChild(empty, head)
    let lineBox = r.box(pairs = [("padding-left", $PadXPx & "px"), ("padding-top", "12px")])
    let (line, _) = r.caption(NoInitiativesWords, p.textCaption, inner)
    r.tag(line, "cc-empty-line", NoInitiativesWords)
    r.appendChild(lineBox, line)
    r.appendChild(empty, lineBox)
    r.appendChild(result, empty)
  else:
    let host = r.createElement("div")
    r.styles(host, [("width", $widthPx & "px"), ("height", $restH & "px"),
                    ("flex-shrink", "0")])
    drawInitiativesPanel(r, host, vm.initiatives, p, widthPx, linePx = TabLinePx)
    # The panel sets its host to fill its parent (`height: 100%`, the
    # column's whole height): here it has the rest under the waiting list,
    # or, in one column, as tall as its rows and at least the rest of the
    # window.
    if oneColumn:
      r.styles(host, [("height", "auto"), ("min-height", $restH & "px")])
    else:
      r.setStyle(host, "height", $restH & "px")
    r.appendChild(result, host)

proc drawControlCenter*(r: GpuiRenderer; host: GpuiElement; vm: ControlCenterVM;
                        p: AhPalette; widthPx, heightPx: int;
                        press: ControlCenterPress = nil) =
  ## The control center in `host`, `widthPx` × `heightPx`; a press is
  ## reported to `press` (nil: nowhere).
  r.clearChildren(host)
  let layout = vm.layoutFor(widthPx)
  r.styles(host, [("display", "flex"),
                  ("flex-direction", if layout == clOneColumn: "column" else: "row"),
                  ("gap", $ColumnGapPx & "px"), ("width", $widthPx & "px"),
                  ("height", $heightPx & "px"), ("overflow", "hidden"),
                  ("background", DesignTokenHex[dtColorsUiSurfaceBaseCanvas][p.mode])])
  for (k, v) in vm.centerFacts(widthPx): r.tag(host, k, v)
  r.tag(host, "columns", $layout)
  if layout == clTwoColumns:
    let launchW = launchWidthPx(widthPx)
    let (launch, _) = r.launchColumn(p, vm, launchW, press)
    r.setStyle(launch, "height", $heightPx & "px")
    r.appendChild(host, launch)
    r.appendChild(host, r.overviewColumn(p, vm, widthPx - ColumnGapPx - launchW,
                                         heightPx, press))
  else:
    # One column, launching first; what is below the window is clipped.
    let (launch, launchH) = r.launchColumn(p, vm, widthPx, press)
    r.setStyle(launch, "height", $launchH & "px")
    r.appendChild(host, launch)
    let rest = max(0, heightPx - launchH - ColumnGapPx)
    r.appendChild(host, r.overviewColumn(p, vm, widthPx, rest, press, oneColumn = true))

proc mountControlCenter*(r: GpuiRenderer; host: GpuiElement; vm: ControlCenterVM;
                         p: AhPalette; widthPx, heightPx: int;
                         press: ControlCenterPress = nil) =
  ## Draws the control center, and again whenever what it shows moves.
  createRenderEffect proc() =
    discard vm.revision.val
    discard vm.composer.revision.val
    discard vm.composer.scheduleOpen.val
    discard vm.composer.optionsOpen.val
    discard vm.launchFor.val
    discard vm.focused.val
    discard vm.initiatives.revision.val
    discard vm.initiatives.state.val
    drawControlCenter(r, host, vm, p, widthPx, heightPx, press)
