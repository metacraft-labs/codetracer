## IsoNim view of an Agent Harbor session's change: the Changes panel over
## `ChangesVM` (nim-agents-isonim-viewmodels `changes_vm`), a REVIEW TABS
## pattern -- one change in four tabs, in the order a reviewer reads it:
## Spec Changes, Tests, Implementation Details and Code.
##
## Layout, top to bottom:
##
## - the header strip (the Initiative Progress panel's, `.ah-fleet-head`):
##   the small-caps section label `CHANGES`, the session the change is of
##   (the host's context), and the session's `n files +a −r` roll-up at the
##   right (shown for an ended session with changes only);
## - the tab bar, each tab with its count; at a narrow width the labels
##   shorten to the viewmodel's compact labels (`Specs`, `Tests`, `Details`,
##   `Code`) and nothing is hidden;
## - for a task with a plan, the milestone selector (`All milestones`, or one
##   milestone in scope), under the record tabs;
## - the active tab's content, or its centred notice (`No spec changes in
##   this scope.`, `No changes`, …).
##
## **Cardless.** A spec card, a test entry and a file row are rows on the
## panel's ground (`agent_harbor_changes.styl`): no border, box
## or background around an item; groups are set apart by small-caps heads
## with a count and by hairlines. An open card carries the focus inset bar,
## never a fill. A state is a coloured word at the row's right with a dot in
## its colour.
##
## **The Code tab is the VCS panel.** Each file is drawn by the VCS view's
## own changed-file row (`isonim_vcs_view.renderChangedFileRow`), through the
## adapter `agent_harbor_changes_code.nim`; this view adds only what that row
## has no field for: the committed / uncommitted mark, the key-file mark and
## a rename's old path. The selected file's hunks open under its row, with
## Previous / Next file and `n of m`.
##
## **Writes.** Approve, Request Changes, Undo / Revert, Approve & Apply and
## Discard call the viewmodel, which sends them through the data source's
## `submitAction` and nothing else; a card's last write's state is the
## tracker's, shown under it. Undo / Revert only asks: while the viewmodel
## says a card waits for confirmation (`confirmingRevert`), the card's
## buttons give way to the question and its `Revert` and `Cancel`, and the
## revert is sent on `Revert` alone. Nothing here talks to a server.
##
## Every element a host test reads carries its fact (`data-ah-*`): the tab
## (`data-ah-tab`, `data-ah-count`, `data-ah-active`), a card
## (`data-ah-card`, `data-ah-tier`, `data-ah-state`), a test row
## (`data-ah-test-status`), a file row (`data-ah-file`, `data-ah-origin`,
## `data-ah-key-file`).

import std/strutils

import isonim/core/[signals, computation, batch]
import isonim/dsl/[ui, components]
import ./ah_cut_text

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
import ./agent_harbor_changes_inbox_words
import ./agent_harbor_changes_code
import ./isonim_vcs_view
import ./agent_harbor_dropdown_view
from ../keymap/scope_path import ChangesPanelScope

export signals, computation, components, changes_vm, agent_harbor_changes_inbox_words

const
  AgentHarborChangesClass* = "component-container agent-harbor-changes"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc setFlag[R, N](r: R; node: N; name: string; on: bool) =
  ## A boolean attribute (`disabled`, `checked`, `selected`), present only
  ## when `on`: the DOM reads any value of it as true.
  mixin setAttribute
  if on: r.setAttribute(node, name, name)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

when defined(js):
  proc markPathCut(row: isonim_dom.Element; path: cstring) {.importjs: """
    (function (row, path) {
      // The VCS row's name cell holds the whole repository path here; it is
      // cut in its middle by the Agent Harbor views' one rule (ah_cut_text).
      var n = row.querySelector('.vcs-file-name');
      if (n) { n.setAttribute('data-ah-cut', 'path'); n.setAttribute('title', path); }
    })(#, #)""".}

# ---------------------------------------------------------------------------
# Shared parts
# ---------------------------------------------------------------------------

proc renderStateWord[R](r: R; text, role: string): auto =
  ## A state word at a row's right with a dot in its colour.
  ui(r):
    span(class = "ah-state-word " & roleClass(role), `data-ah-state-word` = text):
      span(class = "ah-state-dot"):
        discard
      span(`data-ah-cut` = "line", class = "ah-state-text", title = text):
        text text

proc renderOverlay[R](r: R; message, kind: string): auto =
  ui(r):
    tdiv(class = "empty-overlay ah-changes-notice", `data-ah-notice` = kind):
      text message

proc renderError[R](r: R; title, message: string; retry: proc()): auto =
  ## The Agent Harbor panels' error block: a red title, the reason (the
  ## failed read, named by its route), an outlined Retry.
  ui(r):
    tdiv(class = "ah-fleet-error", `data-ah-notice` = "error"):
      tdiv(class = "ah-fleet-error-title"):
        text title
      tdiv(class = "ah-fleet-error-message"):
        text message
      button(class = "ah-fleet-retry", onclick = retry):
        text RetryLabel

proc renderGroupHead[R](r: R; name: string; count: int): auto =
  ## A small-caps group head with its count, as the progress panel's.
  ui(r):
    tdiv(class = "ah-changes-group-head"):
      span(`data-ah-cut` = "line", class = "ah-changes-group-name", title = name):
        text name
      span(class = "ah-changes-group-count"):
        text "(" & $count & ")"

proc renderHunkHead[R](r: R; header: string): auto =
  ui(r):
    tdiv(class = "ah-hunk-head"):
      text header

proc renderHunkLine[R](r: R; line: VCSDiffLineRow): auto =
  ## One line with its marker, in its role (`ah-hunk-added`, …).
  ui(r):
    tdiv(class = "ah-hunk-line ah-hunk-" & line.lineType):
      span(class = "ah-hunk-marker"):
        text lineMarker(line)
      span(class = "ah-hunk-text"):
        text diffLineText(line)

proc renderHunks[R, N](r: R; hunks: seq[DiffHunk]): N =
  ## A file's hunks in the monospaced role: the hunk header, then each line
  ## with its marker, added and removed lines in their roles.
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-hunks")
  if hunks.len == 0:
    let none = ui(r):
      tdiv(class = "ah-hunks-none"):
        text NoHunksText
    r.appendRendered(host, none)
    return
  for hunk in hunks:
    let row = vcsHunkRow(hunk)
    r.appendRendered(host, renderHunkHead(r, hunkHeader(row) &
      (if hunk.section.len > 0: " " & hunk.section else: "")))
    for line in row.lines:
      r.appendRendered(host, renderHunkLine(r, line))

# ---------------------------------------------------------------------------
# The header strip and the tab bar
# ---------------------------------------------------------------------------

proc renderHead[R](r: R; vm: ChangesVM; context: AgentHarborChangesContext): auto =
  let rollUp = if vm.state.val == asReady: vm.rollUp(context.ended) else: ""
  let node = ui(r):
    tdiv(class = "ah-fleet-head"):
      tdiv(class = "ah-fleet-section-header"):
        span(class = "ah-fleet-title"):
          text ChangesSectionLabel
        span(`data-ah-cut` = "line", class = "ah-fleet-source",
             title = context.sessionLabel):
          text changesContextPhrase(context.sessionLabel)
        span(class = "ah-fleet-summary", `data-ah-rollup` = rollUp):
          text rollUp
  node

proc renderTab[R](r: R; vm: ChangesVM; tab: ChangesTabView): auto =
  let which = tab.tab
  let node = ui(r):
    button(class = "ah-changes-tab" & (if tab.active: " ah-changes-tab-active" else: "") &
                   (if tab.empty: " ah-changes-tab-empty" else: ""),
           role = "tab", title = tabTitle(tab),
           onclick = proc() = vm.selectTab(which)):
      span(class = "ah-changes-tab-label ah-changes-tab-full"):
        text tab.label
      span(class = "ah-changes-tab-label ah-changes-tab-compact"):
        text tab.compactLabel
      span(class = "ah-changes-tab-count"):
        text $tab.count
  r.tagFacts(node, [("tab", $tab.tab), ("count", $tab.count),
                    ("active", (if tab.active: "true" else: "false"))])
  node

proc renderTabBar[R, N](r: R; vm: ChangesVM): N =
  var bar: N
  result = ui(r):
    tdiv(ref = bar, class = "ah-changes-tabs", role = "tablist")
  for tab in vm.tabs:
    r.appendRendered(bar, renderTab(r, vm, tab))

proc renderMilestoneSelector[R, N](r: R; vm: ChangesVM): N =
  ## `All milestones` or one milestone in scope; every tab's counts follow it.
  ## The design system's dropdown, its trigger showing the chosen milestone
  ## whole.
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-changes-scope")
  let chosen = vm.milestone.val
  var shown = ""
  var choices: seq[DropdownChoice]
  for (id, label) in vm.milestoneChoices:
    choices.add DropdownChoice(id: id, label: label)
    if id == chosen: shown = label
  let pick = proc(id: string) = vm.selectMilestone(id)
  r.appendRendered(host, renderAgentHarborDropdown[R, N](r, shown, choices, chosen, pick,
    cls = "ah-changes-select", title = "Milestones in scope"))

# ---------------------------------------------------------------------------
# Spec Changes
# ---------------------------------------------------------------------------

proc renderCardActions[R, N](r: R; vm: ChangesVM; card: SpecCardView): N =
  ## A card's buttons: the first the filled primary, the others outlined.
  let key = card.key
  var row: N
  result = ui(r):
    tdiv(ref = row, class = "ah-card-actions")
  var first = true
  proc add(label: string; action: proc()) =
    let cls = if first: "ct-button-sm-primary" else: "ct-button-sm-secondary"
    first = false
    let busy = card.action == astSubmitting
    let b = ui(r):
      button(class = cls & " ah-card-action", `data-ah-action` = label,
             onclick = action):
        text label
    r.setFlag(b, "disabled", busy)
    r.appendRendered(row, b)
  if card.staged:
    add(ApproveApplyLabel, proc() = discard vm.applyStaged(key))
    add(DiscardLabel, proc() = discard vm.discardStaged(key))
  else:
    if card.canApprove:
      add(ApproveLabel, proc() = discard vm.approve(key))
    if card.tier == stSpec:
      add(RevertLabel, proc() = discard vm.requestRevert(key))
  add(RequestChangesLabel, proc() = vm.openRequestChanges(key))

proc renderRevertConfirm[R](r: R; vm: ChangesVM; card: SpecCardView): auto =
  ## The question Undo / Revert asks, in place of the card's buttons: the
  ## spec it would revert, `Revert` (the press that sends it) and `Cancel`.
  ui(r):
    tdiv(class = "ah-revert-confirm", `data-ah-confirm` = "revert"):
      tdiv(class = "ah-revert-question"):
        text revertQuestion(card)
      tdiv(class = "ah-card-actions"):
        button(class = "ct-button-sm-primary ah-card-action",
               `data-ah-action` = ConfirmRevertLabel,
               onclick = proc() = discard vm.confirmRevert()):
          text ConfirmRevertLabel
        button(class = "ct-button-sm-secondary ah-card-action", `data-ah-action` = CancelLabel,
               onclick = proc() = vm.cancelRevert()):
          text CancelLabel

proc renderRequestInput[R, N](r: R; vm: ChangesVM): N =
  ## The inline Request Changes input under a card: its text (kept by the
  ## viewmodel, not read by this render), Submit and Cancel.
  mixin inputValue
  var field: N
  let typed = untrack(proc(): string = vm.requestText.val)
  result = ui(r):
    tdiv(class = "ah-request-input"):
      textarea(ref = field, class = "ah-text-field", rows = "3",
               placeholder = RequestChangesPlaceholder,
               oninput = proc() = vm.setRequestText(r.inputValue(field))):
        text typed
      tdiv(class = "ah-card-actions"):
        button(class = "ct-button-sm-primary ah-card-action", `data-ah-action` = SubmitLabel,
               onclick = proc() = discard vm.submitRequestChanges()):
          text SubmitLabel
        button(class = "ct-button-sm-secondary ah-card-action", `data-ah-action` = CancelLabel,
               onclick = proc() = vm.closeRequestChanges()):
          text CancelLabel

proc renderSpecCard[R, N](r: R; vm: ChangesVM; card: SpecCardView): N =
  let key = card.key
  var head, body: N
  let chevron = if card.open: "\xE2\x96\xBE" else: "\xE2\x96\xB8"
  let isPath = card.tier == stSpec or card.title == card.path
  result = ui(r):
    tdiv(class = "ah-spec-card" & (if card.open: " ah-card-open" else: "") &
                 (if card.staged: " ah-card-staged" else: "") &
                 (if card.focused: " ah-card-focused" else: "")):
      tdiv(ref = head, class = "ah-spec-card-head", role = "button", tabindex = "0",
           title = (if card.open: "Close" else: "Open"),
           onclick = proc() = vm.toggleCard(key)):
        span(class = "ah-fold"):
          text chevron
        span(`data-ah-cut` = (if isPath: CutPathValue else: "line"),
             class = "ah-spec-card-title", title = card.title):
          text card.title
        if card.origin.len > 0:
          span(class = "ah-origin-badge", title = "Where the change came from"):
            text card.origin
      tdiv(ref = body, class = "ah-spec-card-body")
  r.tagFacts(result, [("card", key), ("tier", $card.tier), ("state", card.stateText),
                      ("focused", $card.focused)])
  # The state word sits at the head's right.
  r.appendRendered(head, renderStateWord(r, card.stateText, changeStateRole(card)))
  if not card.open: return
  # Open: what the record says, then the Summary ⇄ Diff side, the buttons,
  # the Request Changes input and the last write's state.
  if card.tier != stSpec and card.title != card.path:
    let p = ui(r):
      tdiv(class = "ah-card-meta"):
        span(`data-ah-cut` = CutPathValue, class = "ah-card-meta-path", title = card.path):
          text card.path
    r.appendRendered(body, p)
  if card.sections.len > 0:
    let s = ui(r):
      tdiv(class = "ah-card-meta"):
        span(class = "ah-card-meta-label"):
          text SectionsLabel
        span(class = "ah-card-meta-text"):
          text sectionsText(card)
    r.appendRendered(body, s)
  if card.commits.len > 0:
    let c = ui(r):
      tdiv(class = "ah-card-meta"):
        span(class = "ah-card-meta-label"):
          text CommitsLabel
        span(class = "ah-card-meta-text ah-mono"):
          text commitsText(card)
    r.appendRendered(body, c)
  let showsDiff = card.showsDiff
  let toggle = ui(r):
    tdiv(class = "ah-side-toggle", role = "group", `data-ah-side` = (if showsDiff: "diff" else: "summary")):
      button(class = "ah-side" & (if not showsDiff: " ah-side-active" else: ""),
             onclick = proc() =
               if showsDiff: vm.toggleDiff(key)):
        text SummaryLabel
      button(class = "ah-side" & (if showsDiff: " ah-side-active" else: ""),
             onclick = proc() =
               if not showsDiff: vm.toggleDiff(key)):
        text DiffLabel
  r.appendRendered(body, toggle)
  if showsDiff:
    r.appendRendered(body, renderHunks[R, N](r, vm.cardDiff(key)))
  elif card.summary.len > 0:
    let s = ui(r):
      tdiv(class = "ah-card-summary"):
        text card.summary
    r.appendRendered(body, s)
  if card.confirmingRevert:
    r.appendRendered(body, renderRevertConfirm(r, vm, card))
  else:
    r.appendRendered(body, renderCardActions[R, N](r, vm, card))
  if card.requestOpen:
    r.appendRendered(body, renderRequestInput[R, N](r, vm))
  let status = actionStatusText(card.action, card.actionReason, card.actionKind)
  if status.len > 0:
    let line = ui(r):
      tdiv(class = "ah-action-status " & roleClass(actionStatusRole(card.action)),
           `data-ah-action-status` = $card.action):
        text status
    r.appendRendered(body, line)

proc renderSpecChanges[R, N](r: R; vm: ChangesVM; list: N) =
  let cards = vm.specCards
  var tier = stSpec
  var started = false
  var groupHost: N
  for card in cards:
    if not started or card.tier != tier:
      tier = card.tier
      started = true
      var count = 0
      for c in cards:
        if c.tier == tier: inc count
      let group = ui(r):
        tdiv(ref = groupHost, class = "ah-changes-group ah-tier-" & $tier)
      r.appendRendered(group, renderGroupHead(r, tierHead(tier), count))
      r.appendRendered(list, group)
    r.appendRendered(groupHost, renderSpecCard[R, N](r, vm, card))

# ---------------------------------------------------------------------------
# Tests and Implementation Details
# ---------------------------------------------------------------------------

proc renderFileLink[R](r: R; vm: ChangesVM; path: string): auto =
  ## A file named by the plan, as a link that asks the host to open it.
  ui(r):
    span(`data-ah-cut` = CutPathValue, class = "ah-file-link ah-mono", title = path,
         role = "link", tabindex = "0",
         onclick = proc() = vm.openInEditor(path)):
      text path

proc renderTest[R](r: R; vm: ChangesVM; entry: VerificationEntry): auto =
  let word = testStatusWord(entry)
  var line: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = "ah-test-row", `data-ah-test-status` = $entry.status):
      tdiv(ref = line, class = "ah-test-head"):
        span(`data-ah-cut` = "line", class = "ah-test-name ah-mono", title = entry.testName):
          text entry.testName
      if entry.description.len > 0:
        tdiv(class = "ah-test-description"):
          text entry.description
      if entry.annotation.len > 0 and entry.status != vsUnknown:
        tdiv(class = "ah-test-annotation"):
          text entry.annotation
  r.appendRendered(line, renderStateWord(r, word, testStatusRole(entry.status)))
  if entry.file.len > 0:
    let f = ui(r):
      tdiv(class = "ah-test-file"):
        discard
    r.appendRendered(f, renderFileLink(r, vm, entry.file))
    r.appendRendered(node, f)
  node

proc renderTests[R, N](r: R; vm: ChangesVM; list: N) =
  for group in vm.tests:
    var rows: N
    let g = ui(r):
      tdiv(ref = rows, class = "ah-changes-group ah-test-group")
    r.appendRendered(g, renderGroupHead(r, group.milestoneId & ": " & group.title,
                                        group.entries.len))
    for entry in group.entries:
      r.appendRendered(g, renderTest(r, vm, entry))
    r.appendRendered(list, g)

proc renderKeyFile[R, N](r: R; vm: ChangesVM; k: KeySourceFile): N =
  ## One key source file: its path as a link, and what it does.
  var line: N
  result = ui(r):
    tdiv(ref = line, class = "ah-key-file")
  r.appendRendered(line, renderFileLink(r, vm, k.path))
  if k.purpose.len > 0:
    let p = ui(r):
      span(class = "ah-key-file-purpose"):
        text k.purpose
    r.appendRendered(line, p)

proc renderDetailsGroup[R, N](r: R; vm: ChangesVM; d: DetailsView): N =
  ## One milestone's notes, as written, and its key source files.
  result = ui(r):
    tdiv(class = "ah-changes-group ah-details-group")
  r.appendRendered(result, renderGroupHead(r, d.milestoneId & ": " & d.title,
                                           d.keySourceFiles.len))
  if d.notes.len > 0:
    let notes = ui(r):
      tdiv(class = "ah-details-notes"):
        text d.notes
    r.appendRendered(result, notes)
  if d.keySourceFiles.len > 0:
    let head = ui(r):
      tdiv(class = "ah-details-label"):
        text KeySourceFilesLabel
    r.appendRendered(result, head)
    for k in d.keySourceFiles:
      r.appendRendered(result, renderKeyFile[R, N](r, vm, k))

proc renderDetails[R, N](r: R; vm: ChangesVM; list: N) =
  for d in vm.details:
    r.appendRendered(list, renderDetailsGroup[R, N](r, vm, d))

# ---------------------------------------------------------------------------
# Code
# ---------------------------------------------------------------------------

proc renderFileDiff[R, N](r: R; vm: ChangesVM; path: string): N =
  ## The selected file's diff under its row: its state, its hunks, and the
  ## file navigation (`n of m`, previous, next, open in the editor).
  let view = vm.fileDiff(path)
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-file-diff", `data-ah-file-diff` = $view.state):
      tdiv(class = "ah-file-nav"):
        span(class = "ah-file-position"):
          text vm.selectedPosition
        button(class = "ah-file-step", title = PreviousFileLabel,
               onclick = proc() = discard vm.stepFile(-1)):
          text PreviousArrow
        button(class = "ah-file-step", title = NextFileLabel,
               onclick = proc() = discard vm.stepFile(1)):
          text NextArrow
        button(class = "ct-button-sm-secondary ah-file-open",
               onclick = proc() = vm.openInEditor(path)):
          text OpenInEditorLabel
  case view.state
  of fdNotLoaded:
    let b = ui(r):
      button(class = "ct-button-sm-secondary ah-load-diff",
             onclick = proc() = vm.loadFile(path)):
        text LoadDiffLabel
    r.appendRendered(host, b)
  of fdLoading:
    let l = ui(r):
      tdiv(class = "ah-file-diff-note"):
        text LoadingFileText
    r.appendRendered(host, l)
  of fdBinary:
    let l = ui(r):
      tdiv(class = "ah-file-diff-note"):
        text BinaryLabel
    r.appendRendered(host, l)
  of fdFailed:
    let l = ui(r):
      tdiv(class = "ah-file-diff-note " & roleClass("error")):
        text view.error
    r.appendRendered(host, l)
  of fdLoaded:
    r.appendRendered(host, renderHunks[R, N](r, view.file.hunks))

proc renderFileRow[R, N](r: R; vm: ChangesVM; index: int; row: FileRow): N =
  ## One file: the VCS panel's row, then the marks it has no field for.
  let callbacks = VCSCallbacks(
    onSelectFile: proc(i: int; path, target, status: string) = vm.selectFile(path),
    onOpenFileDiff: proc(target: string) =
      vm.openInEditor(if target.startsWith("file:"): target[5 .. ^1] else: target))
  let vcsRow = renderChangedFileRow(r, callbacks, index, vcsFileRow(row))
  r.tagFacts(vcsRow, [("file", row.file.path), ("origin", $row.file.origin),
                      ("key-file", (if row.key: "true" else: "false")),
                      ("status", $row.file.status)])
  mixin setAttribute
  r.setAttribute(vcsRow, "title", fileRowTitle(row))
  # Each mark short, with its tooltip; the legend over the files says what
  # the short ones stand for.
  let marks = ui(r):
    span(class = "ah-file-marks"):
      span(class = "ah-origin-mark ah-origin-" & $row.file.origin,
           title = originMark(row.file.origin), `data-ah-mark` = "origin"):
        text originShort(row.file.origin)
  if row.key:
    let k = ui(r):
      span(class = "ah-key-mark", title = KeyFileTitle, `data-ah-mark` = "key"):
        text KeyFileMark
    r.appendRendered(marks, k)
  if row.file.binary:
    let b = ui(r):
      span(class = "ah-binary-mark", title = BinaryTitle, `data-ah-mark` = "binary"):
        text BinaryLabel
    r.appendRendered(marks, b)
  r.appendRendered(vcsRow, marks)
  when defined(js):
    when N is isonim_dom.Element:
      markPathCut(vcsRow, cstring(row.file.path))
  var host: N
  result = ui(r):
    tdiv(ref = host, class = "ah-code-file" & (if row.selected: " ah-code-file-selected" else: "") &
                             (if row.focused: " ah-code-file-focused" else: ""))
  r.appendRendered(host, vcsRow)
  if row.file.oldPath.len > 0:
    let old = ui(r):
      tdiv(class = "ah-renamed-from"):
        span(class = "ah-renamed-label"):
          text RenamedFromLabel
        span(`data-ah-cut` = CutPathValue, class = "ah-renamed-path", title = row.file.oldPath):
          text row.file.oldPath
    r.appendRendered(host, old)
  if row.selected:
    r.appendRendered(host, renderFileDiff[R, N](r, vm, row.file.path))

proc renderCode[R, N](r: R; vm: ChangesVM; list: N) =
  mixin inputValue, clearChildren
  # The base selector and the summary line.
  var baseRow, search, filter, files: N
  let bases = vm.bases
  let summary = vm.summaryLine
  let head = ui(r):
    tdiv(ref = baseRow, class = "ah-code-head"):
      span(class = "ah-code-summary", `data-ah-summary` = summary):
        text summary
  if bases.len > 1:
    let current = vm.base.val
    var shown = ""
    var choices: seq[DropdownChoice]
    for b in bases:
      choices.add DropdownChoice(id: b.id, label: b.label)
      if b.id == current: shown = b.label
    let pick = proc(id: string) = vm.selectBase(id)
    r.appendRendered(baseRow, renderAgentHarborDropdown[R, N](r, shown, choices, current, pick,
      cls = "ah-changes-select ah-base-select", title = "Show the change against"))
  else:
    let label = ui(r):
      span(class = "ah-base-label"):
        text vm.baseLabel
    r.appendRendered(baseRow, label)
  r.appendRendered(list, head)
  # What the short marks stand for; hidden while no file is listed (the
  # files' effect below says).
  var legend: N
  let legendNode = ui(r):
    tdiv(ref = legend, class = "ah-code-legend", `data-ah-legend` = CodeMarksLegend):
      text CodeMarksLegend
  r.appendRendered(list, legendNode)
  # The search and the status filter: built once, outside the list's own
  # effect, so typing never rebuilds the field it types into.
  let query = untrack(proc(): string = vm.query.val)
  let current = untrack(proc(): StatusFilter = vm.filter.val)
  var filters: seq[DropdownChoice]
  for f in filterChoices(): filters.add DropdownChoice(id: $f, label: $f)
  let toolbar = ui(r):
    tdiv(ref = filter, class = "ah-code-toolbar"):
      input(ref = search, class = "ct-input-panel ct-input-search-image ah-code-search",
            `type` = "search", placeholder = SearchFilesPlaceholder, value = query,
            oninput = proc() = vm.setQuery(r.inputValue(search)))
  let pickFilter = proc(id: string) =
    for f in filterChoices():
      if $f == id: vm.setFilter(f)
  r.appendRendered(filter, renderAgentHarborDropdown[R, N](r, $current, filters, $current,
    pickFilter, cls = "ah-changes-select ah-status-filter", title = "Status"))
  r.appendRendered(list, toolbar)
  let listNode = ui(r):
    tdiv(ref = files, class = "ah-code-files vcs-file-list")
  r.appendRendered(list, listNode)
  createRenderEffect proc() =
    r.clearChildren(files)
    let notice = vm.filesNotice
    r.setAttribute(legend, "data-ah-hidden",
                   if notice.len > 0 or vm.files.len == 0: "true" else: "false")
    if notice.len > 0:
      r.appendRendered(files, renderOverlay(r, notice, "filtered"))
      return
    for i, row in vm.files:
      r.appendRendered(files, renderFileRow[R, N](r, vm, i, row))

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderAgentHarborChangesPanel*[R, N](r: R; vm: ChangesVM;
    context = AgentHarborChangesContext()): N =
  ## The Changes panel over `vm`, the session named by `context`.
  mixin clearChildren
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborChangesClass, `data-ct-pane` = ChangesPanelScope, tabindex = "0"):
      tdiv(ref = body, class = "ah-fleet-body ah-changes-body")
  createRenderEffect proc() =
    r.clearChildren(body)
    r.appendRendered(body, renderHead(r, vm, context))
    let target = vm
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderOverlay(r, ChangesLoadingNotice, "loading"))
    of asError:
      r.appendRendered(body, renderError(r, ChangesErrorTitle, vm.error.val,
                                         proc() = target.restart()))
    of asReady:
      r.appendRendered(body, renderTabBar[R, N](r, vm))
      let tab = vm.activeTab.val
      if vm.hasPlan and tab != rtCode:
        r.appendRendered(body, renderMilestoneSelector[R, N](r, vm))
      var list: N
      let listNode = ui(r):
        tdiv(ref = list, class = "ah-changes-content", role = "tabpanel",
             `data-ah-tab-shown` = $tab)
      r.appendRendered(body, listNode)
      let notice = vm.notice
      if notice.len > 0:
        r.appendRendered(list, renderOverlay(r, notice, "empty"))
      else:
        case tab
        of rtSpecChanges: renderSpecChanges[R, N](r, vm, list)
        of rtTests: renderTests[R, N](r, vm, list)
        of rtImplementation: renderDetails[R, N](r, vm, list)
        of rtCode: renderCode[R, N](r, vm, list)
  panel

when defined(js):
  proc mountAgentHarborChangesPanel*(container: isonim_dom.Element; vm: ChangesVM;
                                     context = AgentHarborChangesContext()) =
    ## Mounts the Changes panel over `vm` in `container`.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborChangesPanel[WebRenderer, isonim_dom.Element](WebRenderer(), vm, context)))
