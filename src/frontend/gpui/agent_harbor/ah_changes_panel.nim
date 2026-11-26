## gpui/agent_harbor/ah_changes_panel.nim — CTF-P3. The GPUI view of an Agent
## Harbor session's change: the Changes panel over `ChangesVM`
## (nim-agents-isonim-viewmodels `changes_vm`).
##
## The web prototype is `viewmodel/views/isonim_agent_harbor_changes_view.nim`,
## styled by `styles/components/agent_harbor_changes.styl`; this view draws
## the same parts, in the same order, at the stylesheet's sizes:
##
## - the header strip (`CHANGES`, the session, the session's `n files +a −r`
##   roll-up at the right), the Initiative Progress panel's
##   (`ah_initiative_panels.drawSectionHeader`);
## - the tab bar, each tab with its count, the active one raised with the
##   action-colour line under it; at a panel 30rem wide or narrower the
##   viewmodel's compact labels (`Specs`, `Tests`, `Details`, `Code`);
## - for a task with a plan and a record tab shown, the milestone selector;
## - the active tab's content, or its centred notice.
##
## Spec cards, tests and files are cardless rows on the panel's ground; an
## open card and the selected file carry the action-colour inset bar at
## their left, never a fill. A state is a word at the row's right with a dot
## in its colour.
##
## The Code tab draws each file from the VCS panel's row value
## (`agent_harbor_changes_code.vcsFileRow`, the adapter the web view's VCS
## row renderer is handed): the status letter (`vcs_vm.vcsStatusLabel`) in
## its colour, the path, and the counts at the right, with the committed /
## uncommitted mark, the key-file mark and a rename's old path beside it, as
## the web draws them.
##
## Every press calls the viewmodel (`selectTab`, `toggleCard`, `approve`,
## `requestRevert`, `confirmRevert`, …), whose writes leave only through the
## data source's `submitAction`. A press is routed: each pressable part
## carries its `changes.*` operation and the procedure that performs it
## (`ah_changes_inbox_parts.pressable`), and the panel's route resolves it
## through the pointer keymap in the `changes` scope (`panelPresses`). Nothing here talks to a server or decides a
## state: the words are the viewmodel's and those of
## `viewmodel/views/agent_harbor_changes_inbox_words.nim`, which the web view
## says too.
##
## Every element the CTF-P1b coverage test reads carries its `data-ah-*`
## fact: the tab (`changes-tab`, `count`, `active`), a spec card (`card`,
## `tier`, `card-state`, `open`), a test (`test`, `test-status`), a file
## (`file`, `origin`, `key-file`, `file-status`), a file's diff (`file-diff`).

import ../../../common/pointer_shape
import std/strutils

import isonim/core/[signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
import ../../viewmodel/views/agent_harbor_changes_inbox_words
import ../../viewmodel/views/agent_harbor_changes_code

import ../../viewmodel/keymap/user_keymap
from ../../viewmodel/keymap/scope_path import ChangesPanelScope
import ./ah_changes_inbox_parts
from ./ah_initiative_panels import drawSectionHeader

export changes_vm, ah_changes_inbox_parts

const
  CompactTabsMaxPx* = 480
    ## `@container ah-changes (max-width: 30rem)`: at this panel width and
    ## narrower the tabs show the viewmodel's compact labels.
  TabPx = 28               ## `.ah-changes-tab`: 1.75rem high
  TabPadPx = 10            ## 0 0.625rem; 0.5rem compact
  TabCompactPadPx = 8
  CardIndentPx = 20        ## AH_CARD_INDENT, 1.25rem
  CardHeadPx = 24          ## `.ah-spec-card-head`: min-height 1.5rem
  FoldPx = 14              ## `.ah-fold`: 0.875rem
  CodeRowPx = 30           ## a VCS changed-file row in the Code tab
  SearchPx = 26            ## the panel search input (`ct-input-panel`)
  FilledSearchIconInk* = "#f3f3f3"
    ## The magnifier of a search field holding a query: the fill of the
    ## image the web swaps in (`input_default_search_icon_dark.svg`, which
    ## `ct-images-default-search-icon` names in both themes; an asset's
    ## colour, not a design-system role).
  BarPx = 2                ## the focus inset bar, 0.125rem
  GroupHeadPx = 35         ## `.ah-changes-group-head`
  GroupGapPx = 4           ## `.ah-changes-group + .ah-changes-group`: 0.25rem
  TabBarPx = 4 + TabPx + 1 ## `.ah-changes-tabs`: 4px above, its hairline
  ScopePx = 6 + ControlPx + 6 + 1
    ## `.ah-changes-scope`: the milestone selector 6px above and below, its
    ## hairline.
  RenamedPx = 28           ## `.ah-renamed-from`: the 24px line and 4px below
  ToolbarPx = SearchPx + 6 + 1
    ## `.ah-code-toolbar`: the search, 6px below it, its hairline.
  ChangesRegionKey* = "changes"
    ## The scrolling region of a tab's content.

# ---------------------------------------------------------------------------
# The tab bar and the milestone selector
# ---------------------------------------------------------------------------

proc drawTab(r: GpuiRenderer; p: AhPalette; vm: ChangesVM; tab: ChangesTabView;
             compact: bool): GpuiElement =
  ## One tab (`.ah-changes-tab`): its label and its count 6px apart, 28px
  ## high, rounded on top; the active one on the secondary surface, its
  ## label in the body colour, a 2px line in the action border role along
  ## its foot; an empty tab's count in the disabled colour.
  let label = if compact: tab.compactLabel else: tab.label
  let pad = if compact: TabCompactPadPx else: TabPadPx
  # The tab as wide as the browser sets it, from the face's exact advances:
  # GPUI sizes each run of text to a whole pixel, which drifts a row of
  # tabs a pixel a run.
  let exact = float(2 * pad + 6) + textWidth(label, LabelPx) + textWidth($tab.count, LabelPx)
  let widthPx = int(exact)
  result = r.box(pairs = [("height", $TabPx & "px"), ("items", "center"), ("gap", "6px"),
                          ("width", formatFloat(exact, ffDecimal, 2) & "px"),
                          ("padding-left", $pad & "px"), ("padding-right", $pad & "px"),
                          ("flex-shrink", "0"), ("position", "relative"),
                          ("border-top-left-radius", "4px"),
                          ("border-top-right-radius", "4px"),
                          ("cursor", cursorOf(hkTab))])
  let which = tab.tab
  r.tag(result, "changes-tab", $tab.tab)
  r.tag(result, "count", $tab.count)
  r.tag(result, "active", $tab.active)
  let words = r.text(label, LabelPx, if tab.active: p.textBody else: p.textLabel,
                     shrink = false)
  r.tag(words, "tab-label", label)
  r.appendChild(result, words)
  r.appendChild(result, r.text($tab.count, LabelPx,
                               if tab.empty: p.textDisabled else: p.textCaption,
                               shrink = false))
  if tab.active:
    r.setStyle(result, "background", p.secondary)
    r.appendChild(result, r.underline(p.borderAction, 0, widthPx))
  r.pressable(result, ChangesSelectTabOperation, proc() = vm.selectTab(which))

proc drawTabBar(r: GpuiRenderer; p: AhPalette; vm: ChangesVM; widthPx: int): GpuiElement =
  ## `.ah-changes-tabs`: 4px above, 8px in, tabs 2px apart, over a hairline.
  result = r.box(pairs = [("gap", "2px"), ("padding-top", "4px"),
                          ("padding-left", $InsetPx & "px"), ("padding-right", $InsetPx & "px"),
                          ("flex-shrink", "0"), ("min-width", "0px"),
                          ("height", $(4 + TabPx + 1) & "px")])
  r.rule(result, p.borderSecondary)
  r.tag(result, "tabs", "changes")
  let compact = widthPx <= CompactTabsMaxPx
  for tab in vm.tabs: r.appendChild(result, r.drawTab(p, vm, tab, compact))

proc drawMilestoneSelector(r: GpuiRenderer; p: AhPalette; vm: ChangesVM): GpuiElement =
  ## `.ah-changes-scope`: the select 6px by 8px in, over a hairline.
  result = r.box(pairs = [("items", "center"), ("padding-top", "6px"),
                          ("padding-bottom", "6px"), ("padding-left", $InsetPx & "px"),
                          ("padding-right", $InsetPx & "px"), ("flex-shrink", "0"),
                          ("height", $(6 + ControlPx + 6 + 1) & "px")])
  r.rule(result, p.borderSecondary)
  let chosen = vm.milestone.val
  var shown = ""
  var labels: seq[string]
  for (id, label) in vm.milestoneChoices:
    labels.add label
    if id == chosen: shown = label
  r.appendChild(result, r.selectBox(p, shown, labels, "milestone-select"))

# ---------------------------------------------------------------------------
# Spec Changes
# ---------------------------------------------------------------------------

proc drawMeta(r: GpuiRenderer; p: AhPalette; label, text: string; monoText: bool): GpuiElement =
  ## A card's meta line (`.ah-card-meta`): a small-caps label, 8px, its text
  ## in the caption colour on a 16px line.
  result = r.box(pairs = [("gap", "8px"), ("items", "start"), ("min-width", "0px"),
                          ("flex-shrink", "0")])
  r.appendChild(result, r.sectionLabel(p, label))
  let t = r.wrapping(text, CaptionPx, ShortLinePx, p.textCaption)
  if monoText: discard r.mono(t)
  r.appendChild(result, t)

proc drawSideToggle(r: GpuiRenderer; p: AhPalette; vm: ChangesVM; card: SpecCardView): GpuiElement =
  ## Summary ⇄ Diff (`.ah-side-toggle`): two 24px toggles 4px apart, the
  ## shown side on the hover surface in a 1px primary border.
  let key = card.key
  let showsDiff = card.showsDiff
  result = r.box(pairs = [("gap", "4px"), ("flex-shrink", "0")])
  r.tag(result, "side", if showsDiff: "diff" else: "summary")
  for (label, isDiff) in [(SummaryLabel, false), (DiffLabel, true)]:
    let active = isDiff == showsDiff
    let b = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                           ("padding-left", "8px"), ("padding-right", "8px"),
                           ("rounded", $ControlRadiusPx & "px"), ("border-width", "1px"),
                           ("border-color", if active: p.borderPrimary else: "transparent"),
                           ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
    if active: r.setStyle(b, "background", p.hover)
    r.appendChild(b, r.text(label, LabelPx, if active: p.textBody else: p.textLabel,
                            shrink = false))
    r.tag(b, "button", label)
    if not active: r.pressable(b, ChangesShowSideOperation, proc() = vm.toggleDiff(key))
    r.appendChild(result, b)

proc actionRow(r: GpuiRenderer; buttons: seq[(GpuiElement, int)]; availPx: int): GpuiElement =
  ## `.ah-card-actions` / `.ah-item-actions`: buttons 6px apart, wrapping
  ## onto 24px lines 6px apart.
  var items: seq[FlowItem]
  for (b, w) in buttons: items.add FlowItem(el: b, widthPx: w)
  result = r.flowLines(items, availPx, 6, ControlPx, 6)
  r.setStyle(result, "flex-shrink", "0")

proc drawCardActions(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                     card: SpecCardView; availPx: int): GpuiElement =
  ## A card's buttons: the first the filled primary, the others outlined.
  let key = card.key
  let busy = card.action == astSubmitting
  var buttons: seq[(GpuiElement, int)]
  proc add(label: string; action: proc()) =
    buttons.add (r.actionButton(p, ink, label, buttons.len == 0, ChangesCardActionOperation,
                                action, busy),
                 actionButtonPx(label))
  if card.staged:
    add(ApproveApplyLabel, proc() = discard vm.applyStaged(key))
    add(DiscardLabel, proc() = discard vm.discardStaged(key))
  else:
    if card.canApprove: add(ApproveLabel, proc() = discard vm.approve(key))
    if card.tier == stSpec: add(RevertLabel, proc() = discard vm.requestRevert(key))
  add(RequestChangesLabel, proc() = vm.openRequestChanges(key))
  result = r.actionRow(buttons, availPx)
  r.tag(result, "card-actions", $buttons.len)

proc drawRevertConfirm(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                       card: SpecCardView; availPx: int): GpuiElement =
  ## Undo / Revert's question in place of the card's buttons
  ## (`.ah-revert-confirm`): the question, then `Revert` (filled) and
  ## `Cancel` (outlined), 6px apart.
  result = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(result, "confirm", "revert")
  let q = r.wrapping(revertQuestion(card), BodyPx, BodyLinePx, p.textBody)
  r.tag(q, "question", revertQuestion(card))
  r.appendChild(result, q)
  r.appendChild(result, r.actionRow(@[
    (r.actionButton(p, ink, ConfirmRevertLabel, true, ChangesCardActionOperation,
                    proc() = discard vm.confirmRevert()),
     actionButtonPx(ConfirmRevertLabel)),
    (r.actionButton(p, ink, CancelLabel, false, ChangesCardActionOperation,
                    proc() = vm.cancelRevert()),
     actionButtonPx(CancelLabel))], availPx))

proc drawRequestInput(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                      availPx: int): GpuiElement =
  ## The inline Request Changes input (`.ah-request-input`): the text the
  ## viewmodel keeps, then Submit and Cancel.
  result = r.box(column = true, pairs = [("gap", "6px"), ("flex-shrink", "0")])
  r.tag(result, "request-input", "open")
  r.appendChild(result, r.textField(p, ink, vm.requestText.val, RequestChangesPlaceholder,
                                    false))
  r.appendChild(result, r.actionRow(@[
    (r.actionButton(p, ink, SubmitLabel, true, ChangesCardActionOperation,
                    proc() = discard vm.submitRequestChanges()),
     actionButtonPx(SubmitLabel)),
    (r.actionButton(p, ink, CancelLabel, false, ChangesCardActionOperation,
                    proc() = vm.closeRequestChanges()),
     actionButtonPx(CancelLabel))], availPx))

proc metaPx(label, text: string; availPx: int): int =
  ## `drawMeta`'s height: its text's 16px lines beside its small-caps label
  ## (set semibold and spaced: a tenth wider than the face's metrics).
  ShortLinePx * max(1, textRows(text, CaptionPx,
                                availPx - textPx(label.toUpperAscii, LabelPx) * 11 div 10 - 8))

proc hunksPx(hunks: seq[DiffHunk]): int =
  ## `hunks`' height: each hunk's 20px head and its 16px lines; one 16px
  ## line when there is none.
  if hunks.len == 0: return ShortLinePx
  for h in hunks: result += 20 + ShortLinePx * vcsHunkRow(h).lines.len

proc actionRowPx(labels: seq[string]; availPx: int): int =
  ## `actionRow`'s height: its buttons' 24px lines, 6px apart.
  var items: seq[FlowItem]
  for l in labels: items.add FlowItem(widthPx: actionButtonPx(l))
  if items.len == 0: return 0
  let lines = flowLineCount(items, availPx, 6)
  lines * ControlPx + (lines - 1) * 6

proc cardActionLabels(card: SpecCardView): seq[string] =
  ## The buttons `drawCardActions` draws for `card`, in order.
  if card.staged: result.add @[ApproveApplyLabel, DiscardLabel]
  else:
    if card.canApprove: result.add ApproveLabel
    if card.tier == stSpec: result.add RevertLabel
  result.add RequestChangesLabel

proc gappedPx(parts: seq[int]; gap: int): int =
  ## Parts one under another, `gap` apart; a part of no height takes none.
  var n = 0
  for h in parts:
    if h > 0:
      result += h
      inc n
  if n > 1: result += (n - 1) * gap

proc drawSpecCard(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                  card: SpecCardView; widthPx: int): tuple[el: GpuiElement, heightPx: int] =
  ## One spec card (`.ah-spec-card`): 5px by 8px in; its head (fold glyph,
  ## title, the origin badge, the state word at the right) wraps as the
  ## web's does; open, the body under it, 20px in, and the inset bar.
  let key = card.key
  let cardEl = r.box(column = true, pairs = [("padding-top", "5px"), ("padding-bottom", "5px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("flex-shrink", "0"), ("position", "relative")])
  r.tag(cardEl, "card", key)
  r.tag(cardEl, "tier", $card.tier)
  r.tag(cardEl, "card-state", card.stateText)
  r.tag(cardEl, "open", $card.open)
  if card.open: r.appendChild(cardEl, r.insetBar(p.borderAction, BarPx))
  let avail = widthPx - 2 * InsetPx
  let isPath = card.tier == stSpec or card.title == card.path
  # The keyboard's card: its fold glyph in the action border colour, bold.
  let fold = r.text(if card.open: "\xE2\x96\xBE" else: "\xE2\x96\xB8", CaptionPx,
                    if card.focused: p.borderAction else: p.textCaption,
                    bold = card.focused, shrink = false, pairs = [("width", $FoldPx & "px")])
  r.tag(cardEl, "focused", $card.focused)
  let title = if isPath: r.pathText(card.title, BodyPx, p.textBody)
              else: r.text(card.title, BodyPx, p.textBody)
  r.setStyle(title, "line-height", $ShortLinePx & "px")
  r.tag(title, "card-title", card.title)
  # Each item's height on its line: the fold glyph and the origin badge
  # keep the panel's 24px line, the title and the state word their 16px one
  # (`.ah-spec-card-head` wraps, each line as high as its tallest item).
  var items = @[FlowItem(el: fold, widthPx: FoldPx),
                FlowItem(el: title, widthPx: textPx(card.title, BodyPx))]
  var heights = @[CardHeadPx, ShortLinePx]
  if card.origin.len > 0:
    let badge = r.box(pairs = [("padding-left", "6px"), ("padding-right", "6px"),
                               ("rounded", "4px"), ("background", p.secondary),
                               ("flex-shrink", "0"), ("items", "center")])
    r.appendChild(badge, r.text(card.origin, CaptionPx, p.textLabel, shrink = false))
    r.tag(badge, "origin", card.origin)
    items.add FlowItem(el: badge, widthPx: textPx(card.origin, CaptionPx) + 12)
    heights.add CardHeadPx
  let word = r.stateWord(p, ink, card.stateText, changeStateRole(card), pushEnd = false,
                         maxPx = avail)
  items.add FlowItem(el: word, widthPx: stateWordPx(card.stateText), alignEnd: true)
  heights.add ShortLinePx
  let head = r.flowLinesFit(items, heights, avail, 6, 2)
  r.setStyle(head, "cursor", cursorOf(hkRow))
  r.pressable(head, ChangesToggleCardOperation, proc() = vm.toggleCard(key))
  r.appendChild(cardEl, head)
  let headPx = flowFitHeightPx(items, heights, avail, 6, 2)
  if not card.open: return (cardEl, 10 + headPx)
  let bodyAvail = avail - CardIndentPx
  let body = r.box(column = true, pairs = [("gap", "6px"), ("padding-left", $CardIndentPx & "px"),
                                           ("padding-top", "4px"), ("padding-bottom", "6px"),
                                           ("min-width", "0px"), ("flex-shrink", "0")])
  if card.tier != stSpec and card.title != card.path:
    let path = r.mono(r.pathText(card.path, CaptionPx, p.textCaption))
    r.setStyle(path, "line-height", $ShortLinePx & "px")
    r.tag(path, "card-path", card.path)
    r.appendChild(body, path)
  if card.sections.len > 0:
    r.appendChild(body, r.drawMeta(p, SectionsLabel, sectionsText(card), false))
  if card.commits.len > 0:
    r.appendChild(body, r.drawMeta(p, CommitsLabel, commitsText(card), true))
  r.appendChild(body, r.drawSideToggle(p, vm, card))
  if card.showsDiff:
    r.appendChild(body, r.hunks(p, ink, vm.cardDiff(key)))
  elif card.summary.len > 0:
    let s = r.wrapping(card.summary, BodyPx, BodyLinePx, p.textBody)
    r.tag(s, "card-summary", card.summary)
    r.appendChild(body, s)
  if card.confirmingRevert:
    r.appendChild(body, r.drawRevertConfirm(p, ink, vm, card, bodyAvail))
  else:
    r.appendChild(body, r.drawCardActions(p, ink, vm, card, bodyAvail))
  if card.requestOpen:
    r.appendChild(body, r.drawRequestInput(p, ink, vm, bodyAvail))
  let status = actionStatusText(card.action, card.actionReason, card.actionKind)
  if status.len > 0:
    # `.ah-action-status`: the caption size on the panel's 24px line, wrapping.
    let line = r.wrapping(status, CaptionPx, BodyLinePx,
                          p.roleInk(ink, actionStatusRole(card.action)))
    r.tag(line, "action-status", $card.action)
    r.tag(line, "action-status-text", status)
    r.appendChild(body, line)
  r.appendChild(cardEl, body)
  # The body's height, part by part as drawn above, 6px apart, 4px above
  # and 6px below.
  var parts: seq[int]
  if card.tier != stSpec and card.title != card.path: parts.add ShortLinePx
  if card.sections.len > 0: parts.add metaPx(SectionsLabel, sectionsText(card), bodyAvail)
  if card.commits.len > 0: parts.add metaPx(CommitsLabel, commitsText(card), bodyAvail)
  parts.add ControlPx
  if card.showsDiff: parts.add hunksPx(vm.cardDiff(key))
  elif card.summary.len > 0: parts.add BodyLinePx * textRows(card.summary, BodyPx, bodyAvail)
  if card.confirmingRevert:
    parts.add gappedPx(@[BodyLinePx * textRows(revertQuestion(card), BodyPx, bodyAvail),
                         actionRowPx(@[ConfirmRevertLabel, CancelLabel], bodyAvail)], 6)
  else: parts.add actionRowPx(cardActionLabels(card), bodyAvail)
  if card.requestOpen:
    parts.add gappedPx(@[TextFieldRowsPx, actionRowPx(@[SubmitLabel, CancelLabel], bodyAvail)], 6)
  parts.add BodyLinePx * textRows(status, CaptionPx, bodyAvail)
  (cardEl, 10 + headPx + 4 + gappedPx(parts, 6) + 6)

proc specParts(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
               widthPx: int): seq[ScrollPart] =
  ## The cards, tier by tier, each tier under its head; tiers 4px apart.
  ## Each card is named by its key, so the keyboard's card is kept in view.
  let cards = vm.specCards
  var i = 0
  var first = true
  while i < cards.len:
    let tier = cards[i].tier
    var j = i
    while j < cards.len and cards[j].tier == tier: inc j
    let head = r.groupHead(p, tierHead(tier), j - i)
    r.tag(head, "tier-group", $tier)
    var headPx = GroupHeadPx
    if not first:
      r.setStyle(head, "margin-top", $GroupGapPx & "px")
      headPx += GroupGapPx
    first = false
    result.add ScrollPart(el: head, heightPx: headPx)
    for k in i ..< j:
      let (el, h) = r.drawSpecCard(p, ink, vm, cards[k], widthPx)
      result.add ScrollPart(el: el, heightPx: h, key: cards[k].key)
    i = j

# ---------------------------------------------------------------------------
# Tests and Implementation Details
# ---------------------------------------------------------------------------

proc drawFileLink(r: GpuiRenderer; ink: ChangesInboxInks; vm: ChangesVM; path: string): GpuiElement =
  ## A file the plan names (`.ah-file-link`): Space Mono at the caption size
  ## in the information colour, cut in its middle; a press asks the host to
  ## open it (`ChangesVM.openInEditor`).
  result = r.mono(r.pathText(path, CaptionPx, ink.textInfo))
  r.styles(result, [("line-height", $ShortLinePx & "px"), ("cursor", cursorOf(hkControl))])
  r.tag(result, "file-link", path)
  r.pressable(result, ChangesOpenFileOperation, proc() = vm.openInEditor(path))

proc testPx(entry: VerificationEntry; widthPx: int): int =
  ## `drawTest`'s height: 5px above and below, its lines 2px apart.
  let avail = widthPx - 2 * InsetPx
  let word = testStatusWord(entry)
  let first = flowFitHeightPx(@[FlowItem(widthPx: monoTextPx(entry.testName, BodyPx)),
                                FlowItem(widthPx: stateWordPx(word), alignEnd: true)],
                              @[ShortLinePx, ShortLinePx], avail, 8, 2)
  10 + gappedPx(@[first, ShortLinePx * textRows(entry.description, CaptionPx, avail),
                  (if entry.status != vsUnknown:
                     ShortLinePx * textRows(entry.annotation, CaptionPx, avail) else: 0),
                  (if entry.file.len > 0: ShortLinePx else: 0)], 2)

proc drawTest(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
              entry: VerificationEntry; widthPx: int): GpuiElement =
  ## One verification entry (`.ah-test-row`): 5px by 8px in, 2px between
  ## its lines: the name (Space Mono, body size) with its status word at the
  ## right, the description, the annotation, the file link.
  let word = testStatusWord(entry)
  result = r.box(column = true, pairs = [("gap", "2px"), ("padding-top", "5px"),
                                         ("padding-bottom", "5px"),
                                         ("padding-left", $InsetPx & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("flex-shrink", "0"), ("min-width", "0px")])
  r.tag(result, "test", entry.testName)
  r.tag(result, "test-status", $entry.status)
  let name = r.mono(r.text(entry.testName, BodyPx, p.textBody,
                           pairs = [("line-height", $ShortLinePx & "px")]))
  r.tag(name, "test-name", entry.testName)
  let state = r.stateWord(p, ink, word, testStatusRole(entry.status), pushEnd = false,
                          maxPx = widthPx - 2 * InsetPx)
  r.appendChild(result, r.flowLinesFit(@[FlowItem(el: name, widthPx: monoTextPx(entry.testName, BodyPx)),
                                         FlowItem(el: state, widthPx: stateWordPx(word), alignEnd: true)],
                                       @[ShortLinePx, ShortLinePx],
                                       widthPx - 2 * InsetPx, 8, 2))
  if entry.description.len > 0:
    r.appendChild(result, r.wrapping(entry.description, CaptionPx, ShortLinePx, p.textLabel))
  if entry.annotation.len > 0 and entry.status != vsUnknown:
    let a = r.wrapping(entry.annotation, CaptionPx, ShortLinePx, p.textCaption)
    r.tag(a, "annotation", entry.annotation)
    r.appendChild(result, a)
  if entry.file.len > 0:
    let f = r.box(pairs = [("min-width", "0px"), ("flex-shrink", "0")])
    r.appendChild(f, r.drawFileLink(ink, vm, entry.file))
    r.appendChild(result, f)

proc testParts(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
               widthPx: int): seq[ScrollPart] =
  ## Each milestone's tests under its head; milestones 4px apart.
  var first = true
  for group in vm.tests:
    let head = r.groupHead(p, group.milestoneId & ": " & group.title, group.entries.len,
                           "test-group")
    var headPx = GroupHeadPx
    if not first:
      r.setStyle(head, "margin-top", $GroupGapPx & "px")
      headPx += GroupGapPx
    first = false
    result.add ScrollPart(el: head, heightPx: headPx)
    for entry in group.entries:
      result.add ScrollPart(el: r.drawTest(p, ink, vm, entry, widthPx),
                            heightPx: testPx(entry, widthPx))

proc detailParts(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                 widthPx: int): seq[ScrollPart] =
  ## Each milestone's notes as written (`.ah-details-notes`, body text on
  ## 24px lines, 6px by 8px in) and its key source files under a small-caps
  ## label, each a link and what it does; milestones 4px apart. Each part
  ## is a part of the scrolling region.
  var first = true
  let avail = widthPx - 2 * InsetPx
  for d in vm.details:
    let head = r.groupHead(p, d.milestoneId & ": " & d.title, d.keySourceFiles.len,
                           "details-group")
    r.tag(head, "details", d.milestoneId)
    var headPx = GroupHeadPx
    if not first:
      r.setStyle(head, "margin-top", $GroupGapPx & "px")
      headPx += GroupGapPx
    first = false
    result.add ScrollPart(el: head, heightPx: headPx)
    if d.notes.len > 0:
      let notes = r.box(pairs = [("padding-top", "6px"), ("padding-bottom", "6px"),
                                 ("padding-left", $InsetPx & "px"),
                                 ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
      r.appendChild(notes, r.wrapping(d.notes, BodyPx, BodyLinePx, p.textBody))
      r.tag(notes, "notes", d.milestoneId)
      result.add ScrollPart(el: notes, heightPx: 12 + BodyLinePx * textRows(d.notes, BodyPx, avail))
    if d.keySourceFiles.len > 0:
      # `.ah-details-label`: 4px above, 2px below, on the panel's 24px line.
      let label = r.box(pairs = [("padding-top", "4px"), ("padding-bottom", "2px"),
                                 ("padding-left", $InsetPx & "px"), ("flex-shrink", "0"),
                                 ("height", "30px"), ("items", "center")])
      r.appendChild(label, r.sectionLabel(p, KeySourceFilesLabel))
      result.add ScrollPart(el: label, heightPx: 30)
      for k in d.keySourceFiles:
        # `.ah-key-file`: 2px above and below the panel's 24px line; what the
        # file does wraps onto more of them where the panel is narrow.
        let line = r.box(pairs = [("gap", "8px"), ("items", "start"), ("min-width", "0px"),
                                  ("min-height", "28px"),
                                  ("padding-top", "2px"), ("padding-bottom", "2px"),
                                  ("padding-left", $InsetPx & "px"),
                                  ("padding-right", $InsetPx & "px"), ("flex-shrink", "0")])
        r.tag(line, "key-file", k.path)
        let link = r.drawFileLink(ink, vm, k.path)
        r.setStyle(link, "line-height", $BodyLinePx & "px")
        r.appendChild(line, link)
        var purposePx = BodyLinePx
        if k.purpose.len > 0:
          r.appendChild(line, r.wrapping(k.purpose, CaptionPx, BodyLinePx, p.textCaption))
          purposePx = BodyLinePx * textRows(k.purpose, CaptionPx,
                                            avail - monoTextPx(k.path, CaptionPx) - 8)
        result.add ScrollPart(el: line, heightPx: 4 + max(BodyLinePx, purposePx))

# ---------------------------------------------------------------------------
# Code
# ---------------------------------------------------------------------------

proc smallMark(r: GpuiRenderer; p: AhPalette; text, colour, title: string): GpuiElement =
  ## A file row's mark (`.ah-origin-mark`, `.ah-key-mark`, `.ah-binary-mark`):
  ## the word at the small caption size on the raised ground, 4px in.
  result = r.box(pairs = [("padding-left", "4px"), ("padding-right", "4px"),
                          ("rounded", "3px"), ("background", p.secondary),
                          ("items", "center"), ("height", $ShortLinePx & "px"),
                          ("flex-shrink", "0")])
  r.appendChild(result, r.text(text, CaptionSmPx, colour, shrink = false))
  r.tag(result, "mark-word", text)
  r.tag(result, "mark-title", title)
  r.tag(result, "tooltip", title)

proc drawVcsRow(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                row: FileRow): GpuiElement =
  ## One file as the VCS panel's changed-file row draws it
  ## (`isonim_vcs_view.renderChangedFileRow` over `vcsFileRow(row)`): the
  ## status letter, bold, in its colour; the name (here the repository
  ## path, cut in its middle); the marks the VCS row has no field for; the
  ## `+a` and `-r` counts at the right.
  let vcs = vcsFileRow(row)
  let path = row.file.path
  result = r.box(pairs = [("height", $CodeRowPx & "px"), ("items", "center"), ("gap", "6px"),
                          ("padding-left", $InsetPx & "px"), ("padding-right", $InsetPx & "px"),
                          ("flex-shrink", "0"), ("min-width", "0px"),
                          ("cursor", cursorOf(hkRow))])
  if vcs.selected: r.setStyle(result, "background", p.hover)
  r.tag(result, "vcs-row", vcs.path)
  r.tag(result, "file", path)
  r.tag(result, "file-origin", $row.file.origin)
  r.tag(result, "key-file", $row.key)
  r.tag(result, "file-status", $row.file.status)
  r.tag(result, "file-selected", $vcs.selected)
  r.tag(result, "focused", $row.focused)
  if row.focused:
    # The keyboard's file: an inset bar in the action border colour.
    r.appendChild(result, r.insetBar(p.borderAction, BarPx))
  r.tag(result, "tooltip", fileRowTitle(row))
  let letter = vcsStatusLabel(vcs.status)
  let status = r.text(letter, 11, ink.vcsStatusInk(vcs.status), bold = true, shrink = false,
                      pairs = [("width", "11px"), ("text-align", "center")])
  r.tag(status, "vcs-file-status", letter)
  r.appendChild(result, status)
  let name = r.pathText(vcs.baseName, LabelPx, p.textBody)
  r.fillWidth(name)
  r.tag(name, "vcs-file-name", vcs.baseName)
  r.appendChild(result, name)
  # Each mark short, with its tooltip; the legend over the files says what
  # the short ones stand for.
  let marks = r.box(pairs = [("gap", "4px"), ("items", "center"), ("flex-shrink", "0")])
  r.appendChild(marks, r.smallMark(p, originShort(row.file.origin),
                                   if row.file.origin == coCommitted: p.textLabel
                                   else: p.textWarning, originMark(row.file.origin)))
  if row.key:
    r.appendChild(marks, r.smallMark(p, KeyFileMark, ink.textInfo, KeyFileTitle))
  if row.file.binary:
    r.appendChild(marks, r.smallMark(p, BinaryLabel, p.textLabel, BinaryTitle))
  r.appendChild(result, marks)
  if vcs.additions > 0 or vcs.deletions > 0:
    let stats = r.box(pairs = [("gap", "4px"), ("items", "center"), ("flex-shrink", "0")])
    var statsText = ""
    if vcs.additions > 0:
      r.appendChild(stats, r.text("+" & $vcs.additions, 10, ink.vcsAdded, shrink = false))
      statsText.add "+" & $vcs.additions
    if vcs.deletions > 0:
      r.appendChild(stats, r.text("-" & $vcs.deletions, 10, ink.vcsDeleted, shrink = false))
      statsText.add "-" & $vcs.deletions
    r.tag(stats, "vcs-file-stats", statsText)
    r.appendChild(result, stats)
  r.pressable(result, ChangesSelectFileOperation, proc() = vm.selectFile(path))

proc stepPress(vm: ChangesVM; step: int): proc() =
  ## Previous's or Next's press: a proc of its own so each closure owns its
  ## step (a closure made in a Nim loop body shares the body's variables
  ## with every other iteration's: Previous stepped forward).
  result = proc() = discard vm.stepFile(step)

proc drawFileDiff(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
                  path: string): GpuiElement =
  ## The selected file's diff under its row (`.ah-file-diff`): 4px above, 8px
  ## below, 28px in; its navigation (`n of m`, previous, next, Open in
  ## editor at the right), then its state: Load diff, loading, binary, the
  ## error, or its hunks.
  let view = vm.fileDiff(path)
  result = r.box(column = true, pairs = [("gap", "6px"), ("padding-top", "4px"),
                                         ("padding-bottom", "8px"),
                                         ("padding-left", $(InsetPx + CardIndentPx) & "px"),
                                         ("padding-right", $InsetPx & "px"),
                                         ("flex-shrink", "0"), ("min-width", "0px")])
  r.tag(result, "file-diff", $view.state)
  let nav = r.box(pairs = [("gap", "6px"), ("items", "center"), ("flex-shrink", "0")])
  let position = vm.selectedPosition
  let pos = r.text(position, CaptionPx, p.textCaption, shrink = false)
  r.tag(pos, "file-position", position)
  r.appendChild(nav, pos)
  for (arrow, title, delta) in [(PreviousArrow, PreviousFileLabel, -1),
                                (NextArrow, NextFileLabel, 1)]:
    let b = r.box(pairs = [("height", $ControlPx & "px"), ("min-width", $ControlPx & "px"),
                           ("items", "center"), ("justify", "center"),
                           ("border-width", "1px"), ("border-color", p.borderSecondary),
                           ("rounded", $ControlRadiusPx & "px"), ("background", p.secondary),
                           ("flex-shrink", "0"), ("cursor", cursorOf(hkControl))])
    r.appendChild(b, r.text(arrow, BodyPx, p.textLabel, shrink = false))
    r.tag(b, "file-step", title)
    r.pressable(b, ChangesStepFileOperation, vm.stepPress(delta))
    r.appendChild(nav, b)
  # `.ah-file-open`: pushed to the row's end (`margin-left: auto`).
  r.appendChild(nav, r.box(pairs = [("flex-grow", "1")]))
  r.appendChild(nav, r.actionButton(p, ink, OpenInEditorLabel, false, ChangesOpenFileOperation,
                                    proc() = vm.openInEditor(path)))
  r.appendChild(result, nav)
  case view.state
  of fdNotLoaded:
    let row = r.box(pairs = [("flex-shrink", "0")])
    r.appendChild(row, r.actionButton(p, ink, LoadDiffLabel, false, ChangesLoadDiffOperation,
                                      proc() = vm.loadFile(path)))
    r.appendChild(result, row)
  of fdLoading:
    r.appendChild(result, r.text(LoadingFileText, CaptionPx, p.textCaption))
  of fdBinary:
    r.appendChild(result, r.text(BinaryLabel, CaptionPx, p.textCaption))
  of fdFailed:
    let e = r.text(view.error, CaptionPx, p.textError)
    r.tag(e, "error", view.error)
    r.appendChild(result, e)
  of fdLoaded:
    r.appendChild(result, r.hunks(p, ink, view.file.hunks))

proc fileDiffPx(vm: ChangesVM; path: string): int =
  ## `drawFileDiff`'s height: 4px above, 8px below, its navigation and its
  ## state 6px apart.
  let view = vm.fileDiff(path)
  let state = case view.state
    of fdNotLoaded: ControlPx
    of fdLoaded: hunksPx(view.file.hunks)
    else: ShortLinePx
  4 + ControlPx + 6 + state + 8

proc codeParts(r: GpuiRenderer; p: AhPalette; ink: ChangesInboxInks; vm: ChangesVM;
               widthPx: int): seq[ScrollPart] =
  ## The Code tab: the base selector and the summary line, the legend of the
  ## short marks, the search and the status filter over a
  ## hairline, then the files, each named by its path, so the keyboard's
  ## file is kept in view.
  let summary = vm.summaryLine
  let avail = widthPx - 2 * InsetPx
  let bases = vm.bases
  var baseEl: GpuiElement
  var baseW = 0
  if bases.len > 1:
    var labels: seq[string]
    var shown = ""
    for b in bases:
      labels.add b.label
      if b.id == vm.base.val: shown = b.label
    baseEl = r.selectBox(p, shown, labels, "base")
    baseW = selectBoxPx(textPx(shown, LabelPx))
  else:
    baseEl = r.text(vm.baseLabel, LabelPx, p.textLabel, shrink = false)
    r.tag(baseEl, "base", vm.baseLabel)
    baseW = textPx(vm.baseLabel, LabelPx)
  let sum = r.text(summary, CaptionPx, p.textCaption, shrink = false)
  r.tag(sum, "code-summary", summary)
  let head = r.box(column = true, pairs = [("padding-top", "6px"), ("padding-bottom", "6px"),
                                           ("padding-left", $InsetPx & "px"),
                                           ("padding-right", $InsetPx & "px"),
                                           ("flex-shrink", "0")])
  let headItems = @[FlowItem(el: baseEl, widthPx: baseW),
                    FlowItem(el: sum, widthPx: textPx(summary, CaptionPx), alignEnd: true)]
  r.appendChild(head, r.flowLines(headItems, avail, 8, ControlPx, 6))
  let headLines = flowLineCount(headItems, avail, 8)
  result.add ScrollPart(el: head, heightPx: 12 + headLines * ControlPx + (headLines - 1) * 6)
  let notice = vm.filesNotice
  if notice.len == 0:
    # `.ah-code-legend`: what the short marks stand for, the caption size
    # on 16px lines, 6px below, above the toolbar's hairline.
    let legend = r.box(pairs = [("padding-left", $InsetPx & "px"),
                                ("padding-right", $InsetPx & "px"),
                                ("padding-bottom", "6px"), ("flex-shrink", "0"),
                                ("min-width", "0px")])
    let t = r.wrapping(CodeMarksLegend, CaptionPx, ShortLinePx, p.textCaption)
    r.tag(t, "code-legend", CodeMarksLegend)
    r.appendChild(legend, t)
    result.add ScrollPart(el: legend,
                          heightPx: 6 + ShortLinePx * textRows(CodeMarksLegend, CaptionPx, avail))
  # The search and the status filter (`.ah-code-toolbar`).
  let toolbar = r.box(pairs = [("gap", "8px"), ("items", "center"),
                               ("padding-left", $InsetPx & "px"),
                               ("padding-right", $InsetPx & "px"),
                               ("padding-bottom", "6px"), ("flex-shrink", "0")])
  r.rule(toolbar, p.borderSecondary)
  let query = vm.query.val
  # An `input` (`.ct-input-panel.ct-input-search-image`): holding a query,
  # the app's input rule draws it with the action border on the input
  # surface (`inputLook`).
  let look = inputLook(p, query, SearchFilesPlaceholder, p.borderSecondary, ink.inputSurface)
  let search = r.inputBox(look, pairs = [("height", $SearchPx & "px"), ("items", "center"),
                                         ("gap", "7.25px"),
                                         ("padding-left", "8px"), ("padding-right", "8px"),
                                         ("rounded", "4px")])
  r.fillWidth(search)
  r.tag(search, "search", query)
  # The search field's magnifier (`ct-input-search-image`): a ring and its
  # handle, drawn in the placeholder's colour; holding a query, in the
  # filled field's icon colour (`ct-images-default-search-icon`, which the
  # same has-value selector swaps in).
  let lens = r.box(pairs = [("width", "11px"), ("height", "11px"), ("rounded", "6px"),
                            ("border-width", "1.5px"),
                            ("border-color", if look.filled: FilledSearchIconInk
                                             else: ink.placeholder),
                            ("flex-shrink", "0")])
  r.appendChild(search, lens)
  r.appendChild(search, r.text(if query.len > 0: query else: SearchFilesPlaceholder, BodyPx,
                               if query.len > 0: p.textBody else: ink.placeholder))
  r.appendChild(toolbar, search)
  var filters: seq[string]
  for f in filterChoices(): filters.add $f
  r.appendChild(toolbar, r.selectBox(p, $vm.filter.val, filters, "status-filter"))
  result.add ScrollPart(el: toolbar, heightPx: ToolbarPx)
  if notice.len > 0:
    let files = r.box(column = true, pairs = [("flex-shrink", "0"), ("flex-grow", "1")])
    r.tag(files, "files", "code")
    r.appendChild(files, r.notice(p, notice, "filtered"))
    result.add ScrollPart(el: files, heightPx: 0)
    return
  for row in vm.files:
    let file = r.box(column = true, pairs = [("flex-shrink", "0"), ("position", "relative")])
    if row.selected: r.appendChild(file, r.insetBar(p.borderAction, BarPx))
    r.appendChild(file, r.drawVcsRow(p, ink, vm, row))
    var h = CodeRowPx
    if row.file.oldPath.len > 0:
      # `.ah-renamed-from`: 4px under the panel's 24px line.
      let old = r.box(pairs = [("gap", "6px"), ("items", "center"), ("height", $RenamedPx & "px"),
                               ("padding-left", $(InsetPx + CardIndentPx) & "px"),
                               ("padding-right", $InsetPx & "px"), ("padding-bottom", "4px"),
                               ("min-width", "0px"), ("flex-shrink", "0")])
      r.appendChild(old, r.text(RenamedFromLabel, CaptionPx, p.textCaption, shrink = false))
      let oldPath = r.mono(r.pathText(row.file.oldPath, CaptionPx, p.textCaption))
      r.tag(oldPath, "renamed-from", row.file.oldPath)
      r.appendChild(old, oldPath)
      r.appendChild(file, old)
      h += RenamedPx
    if row.selected:
      r.appendChild(file, r.drawFileDiff(p, ink, vm, row.file.path))
      h += fileDiffPx(vm, row.file.path)
    result.add ScrollPart(el: file, heightPx: h, key: row.file.path)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc changesHeaderPx(source, rollUp: string; widthPx: int): int =
  ## The header strip's height (`drawSectionHeader`): its 24px lines, 2px
  ## apart, 4px above and below, its hairline.
  let items = @[FlowItem(widthPx: textPx(ChangesSectionLabel.toUpperAscii, CaptionPx) * 11 div 10),
                FlowItem(widthPx: textPx(source, CaptionPx), grow: true),
                FlowItem(widthPx: textPx(rollUp, CaptionPx), alignEnd: true)]
  let lines = flowLineCount(items, max(1, widthPx - 2 * InsetPx), 8)
  8 + lines * 24 + (lines - 1) * 2 + 1

proc changesPresses*(vm: ChangesVM; keymap = UserKeymap()): PanelPress =
  ## The route for a press on the Changes panel over `vm`: resolved in the
  ## `changes` scope under `keymap`'s rows over the base keymap's; a user's
  ## row that names one of the panel's key operations runs it on `vm`.
  panelPresses(ChangesPanelScope, keymap,
               proc(operation: string): bool = vm.runChangesOperation(operation))

proc drawChangesPanelParts(r: GpuiRenderer; host: GpuiElement; vm: ChangesVM; p: AhPalette;
                           widthPx: int; context: AgentHarborChangesContext; heightPx: int;
                           scroll: P3Scroll) =
  scroll.beginDraw()
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", "100%"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-changes")
  r.tag(host, "width-px", $widthPx)
  r.tag(host, "state", stateName(vm.state.val))
  let ink = changesInboxInks(p.mode)
  let ready = vm.state.val == asReady
  let source = changesContextPhrase(context.sessionLabel)
  let rollUp = if ready: vm.rollUp(context.ended) else: ""
  let head = r.drawSectionHeader(p, ChangesSectionLabel, source, rollUp, widthPx)
  r.tag(head, "head", "section header")
  r.appendChild(host, head)
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, ChangesLoadingNotice, "loading"))
  of asError:
    let target = vm
    r.appendChild(host, r.routedErrorBlock(p, ChangesErrorTitle, vm.error.val,
                                           ChangesRetryOperation, proc() = target.restart()))
  of asReady:
    r.appendChild(host, r.drawTabBar(p, vm, widthPx))
    var used = changesHeaderPx(source, rollUp, widthPx) + TabBarPx
    let tab = vm.activeTab.val
    if vm.hasPlan and tab != rtCode:
      r.appendChild(host, r.drawMilestoneSelector(p, vm))
      used += ScopePx
    let list = r.box(column = true, pairs = [("flex-grow", "1"), ("min-height", "0px"),
                                             ("overflow", "hidden")])
    r.tag(list, "tab-shown", $tab)
    let notice = vm.notice
    if notice.len > 0:
      r.appendChild(list, r.notice(p, notice, "empty"))
    else:
      let parts = case tab
        of rtSpecChanges: r.specParts(p, ink, vm, widthPx)
        of rtTests: r.testParts(p, ink, vm, widthPx)
        of rtImplementation: r.detailParts(p, ink, vm, widthPx)
        of rtCode: r.codeParts(p, ink, vm, widthPx)
      if heightPx > 0 and (tab != rtCode or vm.filesNotice.len == 0):
        # The Code tab's head and toolbar stay; its file list scrolls (the
        # web's `.ah-code-files` is the VCS panel's `vcs-file-list`, a
        # scrolling list of its own). Every other tab scrolls whole.
        var region = parts
        if tab == rtCode:
          region = @[]
          for part in parts:
            if part.key.len == 0 and region.len == 0:
              r.appendChild(list, part.el)
              used += part.heightPx
            else: region.add part
        r.appendChild(list, r.scrollWindow(scroll, ChangesRegionKey, region,
                                           max(1, heightPx - used), vm.focus.val))
      else:
        for part in parts: r.appendChild(list, part.el)
        if tab == rtCode and vm.filesNotice.len > 0: r.setStyle(list, "flex-grow", "1")
    r.appendChild(host, list)

proc drawChangesPanel*(r: GpuiRenderer; host: GpuiElement; vm: ChangesVM; p: AhPalette;
                       widthPx: int; context = AgentHarborChangesContext(); heightPx = 0;
                       scroll: P3Scroll = nil; press: PanelPress = nil) =
  ## The Changes panel over `vm`, `widthPx` wide, the session `context`
  ## names; redrawn whole on each call. Given its `heightPx`, the tab's
  ## content scrolls as a region (`ChangesRegionKey`, its first pixel kept
  ## by `scroll`), the keyboard's card or file brought into view when it
  ## changes; without, it is clipped at the panel's foot. Its presses go
  ## through `press` (the base keymap's `changesPresses` when nil).
  drawingWith(if press.isNil: changesPresses(vm) else: press):
    drawChangesPanelParts(r, host, vm, p, widthPx, context, heightPx, scroll)

proc mountChangesPanel*(r: GpuiRenderer; host: GpuiElement; vm: ChangesVM; p: AhPalette;
                        widthPx: int; context = AgentHarborChangesContext(); heightPx = 0;
                        scroll: P3Scroll = nil; redraw: Signal[int] = nil;
                        press: PanelPress = nil) =
  ## Draws the panel and redraws it whenever what it reads changes (or the
  ## host moves `redraw`, after a scroll). Its presses go through `press`
  ## (the base keymap's `changesPresses` when nil).
  let route = if press.isNil: changesPresses(vm) else: press
  createRenderEffect proc() =
    if redraw != nil: discard redraw.val
    drawChangesPanel(r, host, vm, p, widthPx, context, heightPx, scroll, route)
