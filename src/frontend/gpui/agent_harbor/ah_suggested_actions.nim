## gpui/agent_harbor/ah_suggested_actions.nim — CTF-P2c step 3. The GPUI
## suggested-actions block: an agent's suggested UI actions waiting on the
## operator, beneath a session timeline's list, over `SuggestedActionsVM`
## (nim-agents-isonim-viewmodels), drawn as the web's
## `isonim_agent_harbor_suggested_actions_view` draws it; the words and
## rules the three hosts share are `agent_harbor_suggested_actions_words`.
##
## The timeline (`ah_session_activity.drawSessionActivity`) asks its tail
## (`suggestionTail`) at each draw: while the suggestion waits, the block and
## its height, pinned beneath the list; once decided, the record lines it
## draws after its own lines, with its own line renderer.
##
## The block (study D23, D54-D59), on the ground one step off the panel
## (`surface/primary/secondary-hover`, D56), 8px in, 6px between its parts:
## the label `SUGGESTED UI ACTIONS` (12px, the label ink, capitals); the
## agent's reason (14px on 20px, the body ink, wrapped); one row per action
## -- a 14px check box (checked: the action border with a ✓ in it;
## unchecked: the caption role; disabled: the caption-subtle role, a step
## quieter) and what the
## action does, wrapped, never cut, in the body ink, the caption ink when
## unchecked, the caption-subtle ink when it cannot be performed
## (`AhPalette.editedOut`, D57), with that action's reason under it (12px
## on 16px, the caption ink) -- then `Approve` (CodeTracer's
## primary button: the action fill with the on-action text) and `Dismiss`
## (the primary border with the body text), and, when Approve cannot be
## pressed, why.
##
## Presses are routed, as the timeline's: each row (not a disabled one),
## Approve and Dismiss carry their operation and target and report a press
## to the host's `ActivityPress`, which resolves and runs it
## (`runSuggestedActionsPress`).
##
## Facts (`data-ah-*`): `blockFacts` on the block, `rowFacts` on each row,
## `ground` (the block's ground), `suggested-button` on the buttons, `approve-why`.

import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ../../viewmodel/views/agent_harbor_suggested_actions_words
import ../../viewmodel/views/agent_harbor_activity_words
import ../../viewmodel/input/element_press
import ../chrome
import ./ah_theme
import ./ah_session_activity
import ../../../common/pointer_shape

export agent_harbor_suggested_actions_words

const
  PadPx* = 8          ## the block's inset
  GapPx* = 6          ## between its parts
  BoxPx* = 14         ## the check box
  BoxGapPx* = 8       ## between the box and the words
  ReasonLinePx = 20   ## the reason's and an action's lines (14px on 20px)

proc blockGround*(p: AhPalette): string =
  ## A step off the panel in both modes (D56), as the web's: Dark's
  ## `surface/primary/secondary-hover`, Light's `surface/base/card`.
  if p.mode == dmDark: DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][p.mode]
  else: DesignTokenHex[dtColorsUiSurfaceBaseCard][p.mode]

proc rowTextPx(widthPx: int): int = max(1, widthPx - 2 * PadPx - BoxPx - BoxGapPx)

proc rowHeightPx(row: SuggestedActionRow; widthPx: int): int =
  result = ReasonLinePx * wrappedRows(row.description, BodyPx, rowTextPx(widthPx))
  if row.reason.len > 0:
    result += CaptionLinePx * wrappedRows(row.reason, CaptionPx, rowTextPx(widthPx))

proc blockHeightPx*(vm: SuggestedActionsVM; widthPx: int): int =
  ## The block's height at `widthPx`: its inset, the label, the reason, each
  ## action, the buttons, and the gaps between them.
  let rows = vm.rows
  result = 2 * PadPx + CaptionLinePx + GapPx +
           ReasonLinePx * wrappedRows(vm.reasonText, BodyPx, widthPx - 2 * PadPx) + GapPx
  for i, row in rows:
    result += rowHeightPx(row, widthPx)
    if i < rows.high: result += 2
  result += GapPx + ControlPx

proc acts(r: GpuiRenderer; el: GpuiElement; operation, target: string;
          press: ActivityPress) =
  r.setAttribute(el, OperationAttribute, operation)
  r.setAttribute(el, PressTargetAttribute, target)
  if press != nil:
    r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(operation, target))

proc wrapped(r: GpuiRenderer; s: string; sizePx, linePx: int; ink: string): GpuiElement =
  r.text(s, sizePx, ink, shrink = false,
         pairs = [("white-space", "pre-wrap"), ("line-height", $linePx & "px"),
                  ("flex-shrink", "1"), ("min-width", "0px")])

proc drawRow(r: GpuiRenderer; p: AhPalette; row: SuggestedActionRow; widthPx: int;
             press: ActivityPress): GpuiElement =
  result = r.box(pairs = [("gap", $BoxGapPx & "px"), ("items", "flex-start"),
                          ("flex-shrink", "0")])
  for (k, v) in row.rowFacts: r.tag(result, k, v)
  let box = r.box(pairs = [("width", $BoxPx & "px"), ("height", $BoxPx & "px"),
                           ("min-width", $BoxPx & "px"), ("margin-top", "3px"),
                           ("items", "center"), ("justify", "center"),
                           ("rounded", "3px"), ("border-width", "1px"),
                           ("flex-shrink", "0")])
  if row.checked:
    # The action border role and the check in it, on the block's ground.
    r.setStyle(box, "border-color", p.borderAction)
    r.appendChild(box, r.text(CheckMarkGlyph, 10, p.borderAction, bold = true, shrink = false))
  elif row.disabled:
    r.setStyle(box, "border-color", p.editedOut)
  else:
    r.setStyle(box, "border-color", p.textCaption)
  r.tag(box, "check-box", $row.checked)
  r.appendChild(result, box)
  let words = r.box(column = true, pairs = [("flex-grow", "1"), ("min-width", "0px"),
                                            ("width", $rowTextPx(widthPx) & "px")])
  let ink = if row.checked: p.textBody
            elif row.disabled: p.editedOut
            else: p.textCaption
  let w = r.wrapped(row.description, BodyPx, ReasonLinePx, ink)
  r.tag(w, "ink", ink)
  r.appendChild(words, w)
  if row.reason.len > 0:
    r.appendChild(words, r.wrapped(row.reason, CaptionPx, CaptionLinePx, p.textCaption))
  r.appendChild(result, words)
  if not row.disabled:
    r.setStyle(result, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
    r.acts(result, SuggestedToggleOperation, row.id, press)

proc drawSuggestedActions*(r: GpuiRenderer; p: AhPalette; vm: SuggestedActionsVM;
                           widthPx: int; press: ActivityPress): GpuiElement =
  ## The block, `widthPx` wide (the timeline sets its height).
  result = r.box(column = true, pairs = [("width", $widthPx & "px"),
                                         ("padding-left", $PadPx & "px"),
                                         ("padding-right", $PadPx & "px"),
                                         ("padding-top", $PadPx & "px"),
                                         ("gap", $GapPx & "px"),
                                         ("background", blockGround(p)),
                                         ("overflow", "hidden")])
  for (k, v) in vm.blockFacts: r.tag(result, k, v)
  r.tag(result, "ground", blockGround(p))
  r.appendChild(result, r.text(SuggestedActionsLabel, CaptionPx, p.textLabel,
                               bold = true, pairs = [("letter-spacing", LabelTracking),
                                                     ("line-height", $CaptionLinePx & "px")]))
  r.appendChild(result, r.wrapped(vm.reasonText, BodyPx, ReasonLinePx, p.textBody))
  let rows = r.box(column = true, pairs = [("gap", "2px"), ("flex-shrink", "0")])
  for row in vm.rows: r.appendChild(rows, r.drawRow(p, row, widthPx, press))
  r.appendChild(result, rows)
  let buttons = r.box(pairs = [("gap", "8px"), ("items", "center"), ("flex-shrink", "0"),
                               ("height", $ControlPx & "px")])
  let approve = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                               ("padding-left", "12px"), ("padding-right", "12px"),
                               ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                               ("border-width", "1px")])
  if vm.canApprove:
    # CodeTracer's own primary button (study D39): the action fill with the
    # on-action text.
    r.styles(approve, [("border-color", p.action), ("background", p.action)])
    r.appendChild(approve, r.text(vm.approveLabel, CaptionPx, p.onAction, shrink = false))
    r.acts(approve, SuggestedApproveOperation, "", press)
    r.setStyle(approve, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
  else:
    r.setStyle(approve, "border-color", p.borderSecondary)
    r.appendChild(approve, r.text(vm.approveLabel, CaptionPx, p.textDisabled, shrink = false))
  r.tag(approve, "suggested-button", "approve")
  r.appendChild(buttons, approve)
  let dismiss = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                               ("padding-left", "12px"), ("padding-right", "12px"),
                               ("flex-shrink", "0"), ("rounded", $ControlRadiusPx & "px"),
                               ("border-width", "1px"), ("border-color", p.borderPrimary)])
  r.appendChild(dismiss, r.text(DismissLabel, CaptionPx,
                                if vm.canDismiss: p.textBody else: p.textDisabled,
                                shrink = false))
  if vm.canDismiss:
    r.acts(dismiss, SuggestedDismissOperation, "", press)
    r.setStyle(dismiss, "cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName)
  r.tag(dismiss, "suggested-button", "dismiss")
  r.appendChild(buttons, dismiss)
  let why = vm.approveDisabledReason
  if why.len > 0:
    let w = r.text(why, CaptionPx, p.textCaption)
    r.tag(w, "approve-why", why)
    r.appendChild(buttons, w)
  r.appendChild(result, buttons)

proc suggestionTail*(r: GpuiRenderer; p: AhPalette; vm: SuggestedActionsVM;
                     press: ActivityPress): ActivityTailOf =
  ## The timeline's tail for `vm`: its record lines once decided, its block
  ## while it waits.
  result = proc(widthPx: int): ActivityTail =
    discard vm.revision.val
    result.surface = SuggestedActionsSurface
    result.lines = vm.recordLines
    if vm.shown:
      result.blockPx = vm.blockHeightPx(widthPx)
      result.drawBlock = proc(): GpuiElement = r.drawSuggestedActions(p, vm, widthPx, press)
