## tui/agent_harbor/ah_tui_suggested_actions.nim — CTF-P2c step 3. The
## terminal's suggested-actions block: an agent's suggested UI actions
## waiting on the operator, beneath a session timeline's list
## (`ah_tui_session_activity.drawSessionActivity`, `tail`), over
## `SuggestedActionsVM` (nim-agents-isonim-viewmodels), as the web
## (`isonim_agent_harbor_suggested_actions_view`) and GPUI
## (`gpui/agent_harbor/ah_suggested_actions.nim`) draw it; the words and
## rules the three share are `agent_harbor_suggested_actions_words`.
##
## The block is an area of its own, one ground step off the panel
## (`surface/primary/secondary-hover`, as the web's; study D56), with no
## frame or rule, under the timeline's last line or at the panel's foot
## once the lines fill the rest (D55). Top to bottom, inset one cell: the label
## `SUGGESTED UI ACTIONS` in the label ink and bold; the agent's reason in
## the body ink, wrapped; one row per action, `[x]` or `[ ]` and what it
## does, wrapped, never cut -- `[x]`, its brackets in the action border
## role and the check in the body role; an action the operator unchecked in
## the caption ink, one CodeTracer cannot perform in the caption-subtle
## role (D57), its reason under it in the caption ink; then ` Approve ` (CodeTracer's primary button: the on-action text on
## the action ground; disabled, the disabled text on the controls' ground)
## and ` Dismiss ` (the body ink on the panel's ground), and, when
## Approve cannot be pressed, why; then one row of the block's own ground.
##
## That last row is the web's padding under its buttons (`.ah-suggested`,
## `padding: 0.5rem`), and the terminal needs it for more than looks:
## Dismiss is drawn on the panel's ground, which is the timeline's, so a
## Dismiss on the block's last row would touch the timeline's ground under
## a block that follows the last line -- two areas on one ground, which
## CodeTracer-TUI §3.4 forbids (codetracer-pm
## issues/2026-11-21-suggested-actions-tui-stories-fail-the-no-box-borders-test.md).
##
## Presses are routed: each row, Approve and Dismiss carry their operation
## and target (`operation`, `target` facts) and a press hands both to the
## host's `ActivityPress`, which resolves and runs it
## (`runSuggestedActionsPress`). A disabled row carries none.
##
## Facts (`AhNode`): `blockFacts` on the block, `rowFacts` on each row,
## `suggested-button` on the two buttons, `approve-why` on the reason Approve cannot
## be pressed.

from std/unicode import runes, `$`
import ../../viewmodel/views/agent_harbor_suggested_actions_words
import ../../viewmodel/views/agent_harbor_activity_words
import ./ah_tui_canvas

export agent_harbor_suggested_actions_words

const
  BoxCells = 4    ## `[x] `
  FootRows = 1    ## the block's own ground under its buttons

proc blockGround*(c: AhCanvas): string =
  ## The block's ground: a step off the panel in both modes, as the web's
  ## (D56): Dark's `surface/primary/secondary-hover`, Light's
  ## `surface/base/card` (clay/300 read as a heavy band, and pulled every
  ## caption in the block under 3:1).
  if c.p.mode == dmDark: tokenHexOf(dtColorsUiSurfacePrimarySecondaryHover, c.p.mode)
  else: tokenHexOf(dtColorsUiSurfaceBaseCard, c.p.mode)

proc dimInk*(c: AhCanvas): string =
  ## An unchecked action's words: the caption role (D57).
  c.p.textCaption

proc disabledInk*(c: AhCanvas): string =
  ## The words of an action CodeTracer cannot perform: caption-subtle, a
  ## step under the caption-role reason drawn under them (D57).
  c.p.editedOut

proc textCells(width: int): int = max(1, width - 2 - BoxCells)

proc rowLines(row: SuggestedActionRow; width: int): (seq[string], seq[string]) =
  (wrapCells(row.description, textCells(width)),
   (if row.reason.len > 0: wrapCells(row.reason, textCells(width)) else: @[]))

proc blockRows*(vm: SuggestedActionsVM; width: int): int =
  ## The rows the block takes at `width` cells: the label, the reason, each
  ## action with its reason, a blank row above the buttons, the buttons, and
  ## the block's own ground under them (`FootRows`).
  result = 1 + wrapCells(vm.reasonText, max(1, width - 2)).len
  for row in vm.rows:
    let (words, why) = rowLines(row, width)
    result += words.len + why.len
  result += 2 + FootRows

proc pressOf(press: ActivityPress; operation, target: string): proc() =
  result = proc() =
    if press != nil: press(operation, target)

proc drawSuggestedActions*(c: var AhCanvas; parent: AhNode; vm: SuggestedActionsVM;
                           row, col, width, height: int; press: ActivityPress) =
  ## The block at (`row`, `col`), `width` × `height` cells. What does not fit
  ## the height is left out from the bottom up, the buttons and the row of
  ## the block's ground under them last (that row is kept whenever the
  ## block has three rows, so a button never touches the ground below it).
  let ground = c.blockGround
  c.area("suggested-actions", row, col, width, height, ground)
  let host = c.node(parent, row, col, width, height, vm.blockFacts)
  let bottom = row + height
  let inner = max(1, width - 2)
  var r = row
  # The buttons' row is the block's last but its foot row.
  let buttonsRow = if height >= 3: bottom - 1 - FootRows else: bottom - 1
  discard c.put(r, col + 1, elide(SuggestedActionsLabel, inner), c.p.textLabel, bold = true)
  discard c.node(host, r, col + 1, widthOf(SuggestedActionsLabel), 1,
                 [("suggested-label", SuggestedActionsLabel)])
  inc r
  for line in wrapCells(vm.reasonText, inner):
    if r >= buttonsRow - 1: break
    discard c.put(r, col + 1, line, c.p.textBody)
    inc r
  discard c.node(host, row + 1, col + 1, inner, max(0, r - row - 1),
                 [("suggestion-reason-shown", vm.reasonText)])
  for item in vm.rows:
    if r >= buttonsRow - 1: break
    let (words, why) = rowLines(item, width)
    let ink = if item.checked: c.p.textBody
              elif item.disabled: c.disabledInk
              else: c.dimInk
    let rowNode = c.node(host, r, col, width, words.len + why.len, item.rowFacts)
    # The box: its brackets in the action border role when checked, the
    # check itself in the body role (the action border alone is about
    # 2.5:1 on the block); the caption role when it can be checked, the
    # caption-subtle role when it cannot.
    if item.checked:
      discard c.put(r, col + 1, "[", c.p.borderAction)
      discard c.put(r, col + 2, "x", c.p.textBody, bold = true)
      discard c.put(r, col + 3, "]", c.p.borderAction)
    else:
      discard c.put(r, col + 1, UncheckedTerminalGlyph,
                    if item.disabled: c.disabledInk else: c.p.textCaption)
    let top = r
    for line in words:
      if r >= buttonsRow - 1: break
      discard c.put(r, col + 1 + BoxCells, line, ink)
      inc r
    for line in why:
      if r >= buttonsRow - 1: break
      # The reason in the caption role, in italics, so it stands apart from
      # the caption-subtle words above it (a terminal cell has no smaller
      # size to set it in).
      var at = col + 1 + BoxCells
      for ru in line.runes:
        c.grid.paint(r, at, $ru, CellStyle(fg: c.p.textCaption, bg: c.bgAt(r, at),
                                           italic: true))
        at += max(1, cellsOfRune(ru, awNarrow))
      inc r
    if not item.disabled:
      rowNode.tag("operation", SuggestedToggleOperation)
      rowNode.tag("target", item.id)
      c.target(top, col, width, max(1, r - top),
               pressOf(press, SuggestedToggleOperation, item.id))
  # The buttons.
  var at = col + 1
  let approve = " " & vm.approveLabel & " "
  let (fg, bg) = if vm.canApprove: (c.p.onAction, c.p.action)
                 else: (c.p.textDisabled, c.tone.chip)
  at += c.put(buttonsRow, at, approve, fg, bg = bg)
  let a = c.node(host, buttonsRow, col + 1, widthOf(approve), 1,
                 [("suggested-button", "approve"), ("button-label", vm.approveLabel)])
  if vm.canApprove:
    a.tag("operation", SuggestedApproveOperation)
    c.target(buttonsRow, col + 1, widthOf(approve), 1,
             pressOf(press, SuggestedApproveOperation, ""))
  at += 1
  let dismiss = " " & DismissLabel & " "
  let dismissAt = at
  # Dismiss is quieter than Approve: the panel's own ground, a step off the
  # block's, where the controls' ground (`tone.chip`) outweighed Light's pale
  # primary.
  at += c.put(buttonsRow, at, dismiss,
              if vm.canDismiss: c.p.textBody else: c.p.textDisabled, bg = c.p.panel)
  let d = c.node(host, buttonsRow, dismissAt, widthOf(dismiss), 1, [("suggested-button", "dismiss")])
  if vm.canDismiss:
    d.tag("operation", SuggestedDismissOperation)
    c.target(buttonsRow, dismissAt, widthOf(dismiss), 1,
             pressOf(press, SuggestedDismissOperation, ""))
  let why = vm.approveDisabledReason
  if why.len > 0 and at + 2 < col + width - 1:
    discard c.text(host, buttonsRow, at + 2, col + width - 1 - at - 2, why, c.p.textCaption,
                   fact = "approve-why")
