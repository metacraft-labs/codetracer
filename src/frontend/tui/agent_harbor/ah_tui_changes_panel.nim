## tui/agent_harbor/ah_tui_changes_panel.nim — CTF-P3. The terminal's
## Changes panel: an Agent Harbor session's change over `ChangesVM`
## (nim-agents-isonim-viewmodels `changes_vm`), in four tabs in the order a
## reviewer reads it: Spec Changes, Tests, Implementation Details and Code.
##
## The same parts, order and words as the web view
## (`viewmodel/views/isonim_agent_harbor_changes_view.nim`) and GPUI's
## (`gpui/agent_harbor/ah_changes_panel.nim`), drawn in cells in the manner
## of CodeTracer-TUI §3.4: few borders, areas told apart by their ground,
## and everything that opens opens with a press on its line.
##
## Top to bottom:
##
## - the head band (`CHANGES`, the session, the session's `n files +a −r`
##   roll-up on the right, shown for an ended session with changes), the
##   Initiative Progress panel's (`ah_tui_initiative_panels.drawSectionHeader`);
## - the tab bar, a band on the raised ground: each tab its label and its
##   count, the active one on the active tab's grey with its label bold; on a
##   panel 30rem wide or narrower (60 cells) the viewmodel's compact labels
##   (`Specs`, `Tests`, `Details`, `Code`); a press selects a tab;
## - for a task with a plan and a record tab shown, the milestone selector;
## - the active tab's content on the panel's ground, or its centred notice.
##
## Spec cards, tests and files are rows striped as the fleet's are (the
## panel, then the stripe), under group heads on a ground of their own. A
## press on a card's line opens or closes it (`▸` / `▾`); an open card
## carries the action-colour inset bar `▎` down its left edge, never a fill,
## and shows its path, sections and commits, Summary ⇄ Diff, its buttons, the
## Request Changes input, the revert question and its last write's state.
## The selected file is a selection (the selection's ground and the bar) and
## its diff opens under it.
##
## **The Code tab is the terminal's VCS pane.** Each file is drawn with the
## spans the VCS pane draws a review's changed file with
## (`app/views/vcs_pane.reviewFileSpans`), from the VCS row value the web's
## and GPUI's Code tabs draw (`agent_harbor_changes_code.vcsFileRow`, the one
## adapter), turned into the pane's model by `vcsReviewLineOf`. Only what
## the VCS row has no field for is added at the row's end: the committed /
## uncommitted mark, the key-file mark and `binary`; a rename's old path is
## a line under it.
##
## Every press calls the viewmodel, which sends its writes only through the
## data source's `submitAction`. Nothing here decides a state: the words are
## the viewmodel's and `agent_harbor_changes_inbox_words`'.
##
## Facts (`AhNode`), named as GPUI's: `surface`, `state`, `width-px`; a tab
## (`changes-tab`, `count`, `active`, `tab-label`), `tab-shown`,
## `milestone-select`; a spec card (`card`, `tier`, `card-state`, `open`,
## `card-title`, `card-path`, `side`, `confirm`, `request-input`,
## `action-status`, `action-status-text`), a tier's head
## (`changes-group`); a test (`test`, `test-status`, `test-name`,
## `annotation`, `file-link`), a milestone's details (`details`, `key-file`);
## a file (`vcs-row`, `file`, `file-origin`, `key-file`, `file-status`,
## `file-selected`, `vcs-file-status`, `vcs-file-name`, `vcs-file-stats`,
## `vcs-name-shown`), its diff (`file-diff`, `file-position`).

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
import ../../viewmodel/views/agent_harbor_changes_inbox_words
import ../app/views/vcs_pane

import ./ah_tui_changes_inbox_parts
from ./ah_tui_initiative_panels import drawSectionHeader

export changes_vm, agent_harbor_changes_inbox_words, ah_tui_changes_inbox_parts

const
  CompactTabsMaxPx* = 30 * 16
    ## `@container ah-changes (max-width: 30rem)`: at this panel width and
    ## narrower the tabs show the viewmodel's compact labels.
  CardIndent* = 3
    ## An open card's body, and a file's diff, start under the title: the
    ## inset bar's cell and the fold glyph's two.
  ChangesScrollKey* = "changes"
    ## The scrolling region of the tab's content (`drawScrolled`).
  FoldOpen* = UnfoldedGlyph
  FoldClosed* = FoldedGlyph

type
  ChangesPress = object
    ## The panel's drawing context: where it is, its grounds, the host's
    ## state.
    vm: ChangesVM
    s: AhP3State
    g: P3Grounds
    col, width: int
    keySlot, binarySlot: bool
      ## The Code tab: some file is a key source file, some is binary; each
      ## mark then has a column of its own on every row, so the marks of
      ## the rows line up.
    originSlot: int
      ## The origin mark's column: its widest word among the files.

proc endArea(c: var AhCanvas; name: string; row, col, width, height: int; bg: string) =
  ## Records an area whose rows were filled as they were drawn (a row's
  ## height is known only once it is drawn).
  ## A row on the panel's own ground is the panel: it is not an area of its
  ## own, so it has no boundary with the panel around it.
  if height > 0 and bg != c.p3Grounds.panel:
    c.areas.add AhArea(name: name, row: row, col: col, width: width, height: height, bg: bg)

proc nextGround(g: P3Grounds; k: var int; previous: string): string =
  ## The next row's ground in a striped list: the stripe's next, flipped when
  ## it would be the ground just above (an open block, a toolbar), so two
  ## rows never share one.
  result = g.stripeOf(k)
  if result == previous:
    inc k
    result = g.stripeOf(k)
  inc k

# ---------------------------------------------------------------------------
# The tab bar and the milestone selector
# ---------------------------------------------------------------------------

# A press made in a loop is made by a proc of its own, so each closure owns
# its value: a closure in a Nim loop body shares the body's variables with
# every other iteration's (https://nim-lang.org/docs/manual.html#closures-creating-closures-in-loops).

proc tabPress(vm: ChangesVM; tab: ReviewTab): proc() =
  result = proc() = vm.selectTab(tab)

proc stepPress(vm: ChangesVM; delta: int): proc() =
  result = proc() = discard vm.stepFile(delta)

proc drawTabs(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: int) =
  ## The tab bar: a band on the raised ground, a cell in; each tab ` label
  ## count `, a cell apart; the active one on the active tab's grey, its
  ## label bold in the body ink; an empty tab's count in the disabled ink.
  c.area("tabs", row, p.col, p.width, 1, p.g.tabBand)
  let bar = c.node(parent, row, p.col, p.width, 1, [("tabs", "changes")])
  let compact = p.width * CellPx <= CompactTabsMaxPx
  var x = p.col + 1
  for tab in p.vm.tabs:
    let label = if compact: tab.compactLabel else: tab.label
    let count = $tab.count
    let w = 1 + widthOf(label) + 1 + widthOf(count) + 1
    if tab.active: c.area("tab-active", row, x, w, 1, p.g.tabActive)
    let n = c.node(bar, row, x, w, 1, [("changes-tab", $tab.tab), ("count", count),
                                       ("active", $tab.active), ("tooltip", tabTitle(tab))])
    discard c.text(n, row, x + 1, widthOf(label), label,
                   if tab.active: c.p.textBody else: c.p.textLabel,
                   bold = tab.active, fact = "tab-label")
    discard c.put(row, x + 1 + widthOf(label) + 1, count,
                  if tab.empty: c.p.textDisabled else: c.p.textCaption)
    c.target(row, x, w, 1, tabPress(p.vm, tab.tab))
    x += w + 1

proc drawMilestoneSelector(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: int) =
  ## `All milestones` or one milestone in scope (`.ah-changes-scope`), a
  ## select a cell in.
  var shown = ""
  var choices: seq[AhMenuChoice]
  for (id, label) in p.vm.milestoneChoices:
    choices.add AhMenuChoice(id: id, label: label)
    if id == p.vm.milestone.val: shown = label
  let vm = p.vm
  discard c.drawSelect(p.s, parent, row, p.col + 1, p.width - 2, "milestone", "milestone-select",
                       shown, choices, vm.milestone.val,
                       proc(id: string) = vm.selectMilestone(id))

# ---------------------------------------------------------------------------
# Spec Changes
# ---------------------------------------------------------------------------

proc fillRow(c: var AhCanvas; row, col, width: int; ground: string) =
  c.fill(row, col, width, 1, ground)

proc drawCardBody(c: var AhCanvas; p: ChangesPress; card: SpecCardView; n: AhNode;
                  row: int; ground: string): int =
  ## An open card's body under its head, `CardIndent` cells in, every row on
  ## the card's ground; returns the rows.
  let vm = p.vm
  let key = card.key
  let x = p.col + CardIndent
  let w = max(1, p.width - CardIndent - 1)
  var r = row
  template line(rows: int) =
    for k in 0 ..< rows: c.fillRow(r + k, p.col, p.width, ground)
  if card.tier != stSpec and card.title != card.path:
    line(1)
    let shown = elidePath(card.path, w)
    discard c.put(r, x, shown, c.p.textCaption)
    discard c.node(n, r, x, widthOf(shown), 1, [("card-path", card.path)])
    inc r
  for (label, text) in [(SectionsLabel, sectionsText(card)), (CommitsLabel, commitsText(card))]:
    if text.len == 0: continue
    let lw = widthOf(label) + 2
    let lines = wrapCells(text, max(1, w - lw))
    line(lines.len)
    discard c.drawSmallCaps(n, r, x, lw, label)
    discard c.para(n, r, x + lw, max(1, w - lw), text, c.p.textCaption,
                   fact = (if label == SectionsLabel: "card-sections" else: "card-commits"))
    r += lines.len
  # Summary ⇄ Diff: the side shown on the active tab's grey, bold.
  line(1)
  let side = c.node(n, r, x, w, 1, [("side", if card.showsDiff: "diff" else: "summary")])
  var sx = x
  for (label, isDiff) in [(SummaryLabel, false), (DiffLabel, true)]:
    let active = isDiff == card.showsDiff
    let text = " " & label & " "
    discard c.put(r, sx, text, if active: c.p.textBody else: c.p.textLabel, bold = active,
                  bg = (if active: p.g.activeTab else: ""))
    discard c.node(side, r, sx, widthOf(text), 1, [("button", label), ("active", $active)])
    if not active: c.target(r, sx, widthOf(text), 1, proc() = vm.toggleDiff(key))
    sx += widthOf(text) + 1
  inc r
  if card.showsDiff:
    let hunks = vm.cardDiff(key)
    var rows = 1
    for h in hunks: rows += 1 + h.lines.len
    line(rows)
    r += c.drawHunks(n, r, x, w, hunks)
  elif card.summary.len > 0:
    let lines = wrapCells(card.summary, w)
    line(lines.len)
    r += c.para(n, r, x, w, card.summary, c.p.textBody, fact = "card-summary")
  # The buttons, or the revert question in their place, a row apart from
  # what is above them.
  line(1)
  inc r
  let busy = card.action == astSubmitting
  var buttons: seq[AhButton]
  if card.confirmingRevert:
    let q = revertQuestion(card)
    let lines = wrapCells(q, w)
    line(lines.len)
    let confirm = c.node(n, r, x, w, lines.len + 1, [("confirm", "revert")])
    r += c.para(confirm, r, x, w, q, c.p.textBody, fact = "question")
    buttons = @[AhButton(label: ConfirmRevertLabel, primary: true,
                         press: proc() = discard vm.confirmRevert()),
                AhButton(label: CancelLabel, press: proc() = vm.cancelRevert())]
    line(2)
    r += c.drawButtons(confirm, r, x, w, buttons, "card-actions")
  else:
    if card.staged:
      buttons.add AhButton(label: ApproveApplyLabel, press: proc() = discard vm.applyStaged(key))
      buttons.add AhButton(label: DiscardLabel, press: proc() = discard vm.discardStaged(key))
    else:
      if card.canApprove:
        buttons.add AhButton(label: ApproveLabel, press: proc() = discard vm.approve(key))
      if card.tier == stSpec:
        buttons.add AhButton(label: RevertLabel, press: proc() = discard vm.requestRevert(key))
    buttons.add AhButton(label: RequestChangesLabel, press: proc() = vm.openRequestChanges(key))
    for i in 0 ..< buttons.len:
      buttons[i].primary = i == 0
      buttons[i].disabled = busy
    line(2)
    r += c.drawButtons(n, r, x, w, buttons, "card-actions")
  if card.requestOpen:
    line(FieldRows + 2)
    let input = c.node(n, r, x, w, FieldRows + 1, [("request-input", "open")])
    r += c.drawTextField(input, r, x, w, vm.requestText.val, RequestChangesPlaceholder, false)
    r += c.drawButtons(input, r, x, w, @[
      AhButton(label: SubmitLabel, primary: true,
               press: proc() = discard vm.submitRequestChanges()),
      AhButton(label: CancelLabel, press: proc() = vm.closeRequestChanges())])
  let status = actionStatusText(card.action, card.actionReason, card.actionKind)
  if status.len > 0:
    let lead = if busy: spinnerOf(p.s) & " " else: ""
    if busy and not p.s.isNil: p.s.spinning = true
    let lines = wrapCells(lead & status, w)
    line(lines.len)
    let ink = c.p.roleInk(c.inks, actionStatusRole(card.action))
    let st = c.node(n, r, x, w, lines.len, [("action-status", $card.action)])
    for i, l in lines: discard c.put(r + i, x, l, ink)
    discard c.node(st, r, x + widthOf(lead), widthOf(lines[0]) - widthOf(lead), lines.len,
                   [("action-status-text", status)])
    r += lines.len
  # A row of the card's ground closes it.
  line(1)
  inc r
  r - row

proc drawSpecCard(c: var AhCanvas; p: ChangesPress; parent: AhNode; card: SpecCardView;
                  row: int; ground: string): int =
  ## One spec card from `row`: its head line (fold, title, the origin badge,
  ## the state word at the right) and, open, its body. Returns the rows.
  let vm = p.vm
  let key = card.key
  c.fillRow(row, p.col, p.width, ground)
  let n = c.node(parent, row, p.col, p.width, 1,
                 [("card", key), ("tier", $card.tier), ("card-state", card.stateText),
                  ("open", $card.open)])
  discard c.put(row, p.col + 1, if card.open: FoldOpen else: FoldClosed, c.p.textCaption)
  # The state word at the line's end, two cells clear of the title; where
  # the line cannot hold it beside a title of a dozen cells, it takes the
  # line under the title, cut to the card's width (the web's head wraps).
  let word = stateWordCells(card.stateText)
  let avail = p.width - 1 - CardIndent
  let badge = if card.origin.len > 0: widthOf(card.origin) + 2 + 1 else: 0
  let beside = min(widthOf(card.title), 12) + badge + StatusWordGap + word <= avail
  let wordCol = if beside: p.col + p.width - 1 - word else: p.col + CardIndent
  let room = if beside: max(1, wordCol - StatusWordGap - (p.col + CardIndent) - badge)
             else: max(1, avail - badge)
  let isPath = card.tier == stSpec or card.title == card.path
  let title = if isPath: elidePath(card.title, room) else: elide(card.title, room)
  discard c.put(row, p.col + CardIndent, title, c.p.textBody)
  discard c.node(n, row, p.col + CardIndent, widthOf(title), 1,
                 [("card-title", card.title), ("title-shown", title)])
  if badge > 0:
    let bx = p.col + CardIndent + widthOf(title) + 1
    discard c.put(row, bx, " " & card.origin & " ", c.p.textLabel, bg = p.g.control)
    discard c.node(n, row, bx + 1, widthOf(card.origin), 1, [("origin", card.origin)])
  let headRows = if beside: 1 else: 2
  if not beside: c.fillRow(row + 1, p.col, p.width, ground)
  discard c.drawStateWord(n, row + headRows - 1, wordCol, card.stateText,
                          changeStateRole(card), maxCells = avail)
  c.target(row, p.col, p.width, headRows, proc() = vm.toggleCard(key))
  var rows = headRows
  if card.open:
    rows += c.drawCardBody(p, card, n, row + headRows, ground)
    # The inset bar down the open card's left edge.
    for k in 0 ..< rows: discard c.put(row + k, p.col, BarGlyph, c.p.borderAction)
  if card.focused:
    # The keyboard is on it: the fold glyph in the action ink, bold, as the
    # web (`.ah-card-focused`) and GPUI mark it; an open card's bar stays.
    discard c.put(row, p.col + 1, if card.open: FoldOpen else: FoldClosed, c.p.borderAction,
                  bold = true)
    n.tag("focused", "true")
  n.height = rows
  c.endArea("card", row, p.col, p.width, rows, ground)
  rows

proc drawSpecChanges(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: int): int =
  ## The cards tier by tier, each tier under its head.
  let cards = p.vm.specCards
  var r = row
  var i = 0
  while i < cards.len:
    let tier = cards[i].tier
    var j = i
    while j < cards.len and cards[j].tier == tier: inc j
    let group = c.node(parent, r, p.col, p.width, 1, [("tier-group", $tier)])
    discard c.drawGroupHead(group, r, p.col, p.width, tierHead(tier), j - i)
    inc r
    var k = 0
    var previous = p.g.groupHead
    for idx in i ..< j:
      let ground = p.g.nextGround(k, previous)
      r += c.drawSpecCard(p, group, cards[idx], r, ground)
      previous = ground
    group.height = r - group.row
    i = j
  r - row

# ---------------------------------------------------------------------------
# Tests and Implementation Details
# ---------------------------------------------------------------------------

proc drawFileLink(c: var AhCanvas; p: ChangesPress; parent: AhNode; row, col, cells: int;
                  path: string): int =
  ## A file the plan names, cut in its middle, in the information ink; a
  ## press asks the host to open it (`openInEditor`). Returns its cells.
  let shown = elidePath(path, cells)
  discard c.put(row, col, shown, c.inks.textInfo)
  discard c.node(parent, row, col, widthOf(shown), 1, [("file-link", path), ("link-shown", shown)])
  let vm = p.vm
  c.target(row, col, widthOf(shown), 1, proc() = vm.openInEditor(path))
  widthOf(shown)

proc drawTest(c: var AhCanvas; p: ChangesPress; parent: AhNode; entry: VerificationEntry;
              row: int; ground: string): int =
  ## One verification entry: its name with its status word at the right, its
  ## description, its annotation and its file, every row on its ground.
  let word = testStatusWord(entry)
  let x = p.col + 1
  let w = p.width - 2
  var r = row
  c.fillRow(r, p.col, p.width, ground)
  let n = c.node(parent, row, p.col, p.width, 1,
                 [("test", entry.testName), ("test-status", $entry.status)])
  let wordCells = stateWordCells(word)
  let wordCol = p.col + p.width - 1 - min(wordCells, w div 2)
  discard c.text(n, r, x, max(1, wordCol - StatusWordGap - x), entry.testName, c.p.textBody,
                 fact = "test-name", before = wordCol)
  discard c.drawStateWord(n, r, wordCol, word, testStatusRole(entry.status),
                          maxCells = p.col + p.width - 1 - wordCol)
  inc r
  proc block2(c: var AhCanvas; text, fg, fact: string; r: var int) =
    let lines = wrapCells(text, w)
    for k in 0 ..< lines.len: c.fillRow(r + k, p.col, p.width, ground)
    r += c.para(n, r, x, w, text, fg, fact = fact)
  if entry.description.len > 0: c.block2(entry.description, c.p.textLabel, "description", r)
  if entry.annotation.len > 0 and entry.status != vsUnknown:
    c.block2(entry.annotation, c.p.textCaption, "annotation", r)
  if entry.file.len > 0:
    c.fillRow(r, p.col, p.width, ground)
    discard c.drawFileLink(p, n, r, x, w, entry.file)
    inc r
  n.height = r - row
  c.endArea("test", row, p.col, p.width, r - row, ground)
  r - row

proc drawTests(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: int): int =
  var r = row
  for group in p.vm.tests:
    discard c.drawGroupHead(parent, r, p.col, p.width, group.milestoneId & ": " & group.title,
                            group.entries.len, "test-group")
    inc r
    var k = 0
    var previous = p.g.groupHead
    for entry in group.entries:
      let ground = p.g.nextGround(k, previous)
      r += c.drawTest(p, parent, entry, r, ground)
      previous = ground
  r - row

proc drawDetails(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: int): int =
  ## Each milestone's notes as written (a line of the notes a line here,
  ## each wrapped) and its key source files under a small-caps label, each a
  ## link and what it does.
  let x = p.col + 1
  let w = p.width - 2
  var r = row
  for d in p.vm.details:
    let g = c.node(parent, r, p.col, p.width, 1, [("details", d.milestoneId)])
    discard c.drawGroupHead(g, r, p.col, p.width, d.milestoneId & ": " & d.title,
                            d.keySourceFiles.len, "details-group")
    inc r
    if d.notes.len > 0:
      let notes = c.node(g, r, x, w, 1, [("notes", d.milestoneId)])
      for part in d.notes.splitLines:
        if part.strip.len == 0:
          inc r
          continue
        # A list item keeps its marker and hangs its wrapped lines under its
        # text, as the Org list it was written as.
        let indent = part.len - part.strip(trailing = false).len
        let hang = if part.strip.startsWith("- "): indent + 2 else: indent
        let lines = wrapCells(part.strip, max(1, w - hang))
        for k, l in lines:
          discard c.put(r + k, x + (if k == 0: indent else: hang), l, c.p.textBody)
        r += lines.len
      notes.height = r - notes.row
    if d.keySourceFiles.len > 0:
      inc r
      discard c.drawSmallCaps(g, r, x, w, KeySourceFilesLabel)
      inc r
      for k in d.keySourceFiles:
        let line = c.node(g, r, x, w, 1, [("key-file", k.path)])
        let half = if k.purpose.len > 0: max(8, w * 3 div 5) else: w
        let used = c.drawFileLink(p, line, r, x, half, k.path)
        if k.purpose.len > 0:
          let pw = max(1, w - used - 2)
          let rows = c.para(line, r, x + used + 2, pw, k.purpose, c.p.textCaption,
                            fact = "purpose")
          line.height = max(1, rows)
          r += max(1, rows)
        else:
          inc r
    g.height = r - g.row
    inc r
  r - row

# ---------------------------------------------------------------------------
# Code
# ---------------------------------------------------------------------------

proc vcsReviewLineOf*(row: FileRow; name: string): VcsReviewLine =
  ## One Code tab file as the terminal VCS pane's review row: the VCS row
  ## value the web's and GPUI's Code tabs draw (`vcsFileRow`, the adapter),
  ## its state letter as the VCS view model labels it, and `name` in place of
  ## the whole path when the row cuts it (in its middle) to fit.
  let vcs = vcsFileRow(row)
  VcsReviewLine(status: vcsStatusLabel(vcs.status), name: name, path: vcs.path,
                additions: vcs.additions, deletions: vcs.deletions,
                coverage: vcs.coverageText, selected: vcs.selected)

proc vcsInk*(c: AhCanvas; role: SemanticRole): string =
  ## The ink of a VCS pane span's role, from the roles the web's VCS row
  ## gives the same parts (`vcs.styl`, resolved by
  ## `agent_harbor_changes_inbox_palette`): an addition's green, a
  ## deletion's red, a modification's amber, the path in the body ink.
  let ink = c.inks
  case role
  of srChromeSuccess: ink.vcsAdded
  of srChromeError: ink.vcsDeleted
  of srChromeNotification: ink.vcsModified
  of srChromeMuted: c.p.textCaption
  of srChromeTitle: c.p.textLabel
  else: c.p.textBody

proc drawVcsSpans*(c: var AhCanvas; row, col: int; spans: seq[StyledSpan]): int =
  ## The VCS pane's spans at (`row`, `col`), each in its role's ink and
  ## weight. Returns the cells drawn.
  var x = col
  for s in spans:
    x += c.put(row, x, s.text, c.vcsInk(s.style.role), s.style.bold)
  x - col

proc originText(p: ChangesPress; origin: ChangeOrigin): string =
  ## The origin mark's words, short (`C`, `U`, `C+U`): the legend says what
  ## they stand for.
  originShort(origin)

proc keyText(p: ChangesPress): string = KeyFileMark

proc marksOf(p: ChangesPress; row: FileRow): seq[(string, string, string, int)] =
  ## The marks the VCS row has no field for, each in its column: (text, ink
  ## role, tooltip, column width); an empty text keeps its column.
  result.add (p.originText(row.file.origin),
              (if row.file.origin == coCommitted: "label" else: "warning"),
              originMark(row.file.origin), p.originSlot)
  if p.keySlot:
    result.add ((if row.key: p.keyText else: ""), "info", KeyFileTitle,
                widthOf(p.keyText))
  if p.binarySlot:
    result.add ((if row.file.binary: BinaryLabel else: ""), "label", BinaryTitle,
                widthOf(BinaryLabel))

proc drawFileDiff(c: var AhCanvas; p: ChangesPress; parent: AhNode; path: string;
                  row: int; ground: string): int =
  ## The selected file's diff under its row: its navigation (`n of m`,
  ## previous, next, Open in editor at the right), then its state: Load
  ## diff, loading, binary, the error, or its hunks.
  let vm = p.vm
  let view = vm.fileDiff(path)
  let x = p.col + CardIndent
  let w = max(1, p.width - CardIndent - 1)
  var r = row
  c.fillRow(r, p.col, p.width, ground)
  let n = c.node(parent, r, p.col, p.width, 1, [("file-diff", $view.state)])
  let position = vm.selectedPosition
  var at = x + c.text(n, r, x, w, position, c.p.textCaption, fact = "file-position") + 1
  for (arrow, title, delta) in [(PreviousArrow, PreviousFileLabel, -1),
                                (NextArrow, NextFileLabel, 1)]:
    discard c.put(r, at, " " & arrow & " ", c.p.textLabel, bg = p.g.control)
    discard c.node(n, r, at, 3, 1, [("file-step", title)])
    c.target(r, at, 3, 1, stepPress(vm, delta))
    at += 4
  let open = buttonCells(OpenInEditorLabel)
  discard c.drawButton(n, r, max(at, p.col + p.width - 1 - open), AhButton(
    label: OpenInEditorLabel, press: proc() = vm.openInEditor(path)))
  inc r
  case view.state
  of fdNotLoaded:
    c.fillRow(r, p.col, p.width, ground)
    discard c.drawButton(n, r, x, AhButton(label: LoadDiffLabel,
                                          press: proc() = vm.loadFile(path)))
    inc r
  of fdLoading, fdBinary:
    c.fillRow(r, p.col, p.width, ground)
    discard c.text(n, r, x, w, if view.state == fdLoading: LoadingFileText else: BinaryLabel,
                   c.p.textCaption)
    inc r
  of fdFailed:
    let lines = wrapCells(view.error, w)
    for k in 0 ..< lines.len: c.fillRow(r + k, p.col, p.width, ground)
    r += c.para(n, r, x, w, view.error, c.p.textError, fact = "error")
  of fdLoaded:
    var rows = 1
    for h in view.file.hunks: rows += 1 + h.lines.len
    for k in 0 ..< rows: c.fillRow(r + k, p.col, p.width, ground)
    r += c.drawHunks(n, r, x, w, view.file.hunks)
  c.fillRow(r, p.col, p.width, ground)
  inc r
  n.height = r - row
  r - row

proc drawFileRow(c: var AhCanvas; p: ChangesPress; parent: AhNode; row: FileRow;
                 r0: int; ground: string): int =
  ## One file: the VCS pane's row for it, its marks at the row's end, a
  ## rename's old path under it, and, selected, its diff.
  let vm = p.vm
  let path = row.file.path
  let vcs = vcsFileRow(row)
  let lineGround = if row.selected: p.g.selection else: ground
  var r = r0
  c.fillRow(r, p.col, p.width, lineGround)
  # The marks first, from the row's end: they say what the row cannot.
  let marks = p.marksOf(row)
  var marksW = 0
  for (_, _, _, w) in marks: marksW += w + 2
  let counts = (if vcs.additions > 0: 2 + widthOf($vcs.additions) else: 0) +
               (if vcs.deletions > 0: 2 + widthOf($vcs.deletions) else: 0)
  let x = p.col + 1
  let nameRoom = max(4, p.width - 1 - 3 - counts - marksW - 1)
  let name = elidePath(vcs.baseName, nameRoom)
  let line = vcsReviewLineOf(row, name)
  let n = c.node(parent, r, p.col, p.width, 1,
                 [("vcs-row", vcs.path), ("file", path), ("file-origin", $row.file.origin),
                  ("key-file", $row.key), ("file-status", $row.file.status),
                  ("file-selected", $vcs.selected), ("tooltip", fileRowTitle(row)),
                  ("vcs-name-shown", name)])
  let spans = reviewFileSpans(line)
  discard c.drawVcsSpans(r, x, spans)
  # The cells of the VCS row's parts, named as the web's are.
  discard c.node(n, r, x + 1, widthOf(line.status), 1,
                 [("vcs-file-status", line.status)])
  discard c.node(n, r, x + 1 + widthOf(line.status) + 1, widthOf(name), 1,
                 [("vcs-file-name", vcs.baseName)])
  var stats = ""
  if vcs.additions > 0: stats.add "+" & $vcs.additions
  if vcs.deletions > 0: stats.add "-" & $vcs.deletions
  if stats.len > 0: n.tag("vcs-file-stats", stats)
  # The marks are words in their inks with no ground of their own: two rows'
  # marks one above the other would otherwise be one ground across two rows.
  var mx = p.col + p.width - 1 - marksW + 2
  for (t, role, title, w) in marks:
    let ink = case role
      of "warning": c.p.textWarning
      of "info": c.inks.textInfo
      else: c.p.textCaption
    if t.len > 0:
      # The origin right-aligned in its column, the others at its start.
      let at = if role != "info" and t != BinaryLabel: mx + w - widthOf(t) else: mx
      discard c.put(r, at, t, ink)
      discard c.node(n, r, at, widthOf(t), 1, [("mark-word", t), ("mark-title", title),
                                                 ("tooltip", title)])
    mx += w + 2
  c.target(r, p.col, p.width, 1, proc() = vm.selectFile(path))
  inc r
  if row.file.oldPath.len > 0:
    c.fillRow(r, p.col, p.width, lineGround)
    let fx = p.col + CardIndent
    discard c.put(r, fx, RenamedFromLabel, c.p.textCaption)
    let room = max(1, p.width - CardIndent - widthOf(RenamedFromLabel) - 2)
    let shown = elidePath(row.file.oldPath, room)
    discard c.put(r, fx + widthOf(RenamedFromLabel) + 1, shown, c.p.textCaption)
    discard c.node(n, r, fx + widthOf(RenamedFromLabel) + 1, widthOf(shown), 1,
                   [("renamed-from", row.file.oldPath)])
    inc r
  if row.selected:
    r += c.drawFileDiff(p, n, path, r, lineGround)
    for k in r0 ..< r: discard c.put(k, p.col, BarGlyph, c.p.borderAction)
  if row.focused:
    # The keyboard is on it: the inset bar at its row's edge, as the web
    # (`.ah-code-file-focused`) and GPUI mark it.
    discard c.put(r0, p.col, BarGlyph, c.p.borderAction)
    n.tag("focused", "true")
  n.height = r - r0
  c.endArea("file", r0, p.col, p.width, r - r0, lineGround)
  r - r0

proc drawCode(c: var AhCanvas; p: ChangesPress; parent: AhNode; row, bottom: int): int =
  ## The Code tab: the base (a select when there are several) and the
  ## summary line at the right; the search and the status filter; the files.
  let vm = p.vm
  var r = row
  let summary = vm.summaryLine
  let bases = vm.bases
  let x = p.col + 1
  let sumCol = p.col + p.width - 1 - widthOf(summary)
  if bases.len > 1:
    var choices: seq[AhMenuChoice]
    var shown = ""
    for b in bases:
      choices.add AhMenuChoice(id: b.id, label: b.label)
      if b.id == vm.base.val: shown = b.label
    discard c.drawSelect(p.s, parent, r, x, max(6, sumCol - 2 - x), "base", "base", shown,
                         choices, vm.base.val, proc(id: string) = vm.selectBase(id))
  else:
    discard c.text(parent, r, x, max(1, sumCol - 2 - x), vm.baseLabel, c.p.textLabel,
                   fact = "base")
  if sumCol > x + 6:
    discard c.text(parent, r, sumCol, widthOf(summary), summary, c.p.textCaption,
                   fact = "code-summary")
  else:
    inc r
    discard c.text(parent, r, x, p.width - 2, summary, c.p.textCaption, fact = "code-summary")
  r += 2
  if vm.filesNotice.len == 0 and vm.files.len > 0:
    # What the short marks stand for (`.ah-code-legend`), a row apart from
    # the search under it.
    r += c.para(parent, r, x, max(1, p.width - 2), CodeMarksLegend, c.p.textCaption,
                fact = "code-legend")
    inc r
  # The search field (one row on the field's ground) and the status filter.
  let query = vm.query.val
  var filters: seq[AhMenuChoice]
  for f in filterChoices(): filters.add AhMenuChoice(id: $f, label: $f)
  # The status filter is the design system's dropdown, as wide as the value
  # it shows (`drawSelect`); the search takes the rest.
  let filterW = widthOf($vm.filter.val) + 4
  let searchW = max(8, p.width - 2 - filterW - 1)
  c.area("field", r, x, searchW, 1, p.g.field)
  let shown = if query.len > 0: query else: SearchFilesPlaceholder
  discard c.put(r, x + 1, elide(shown, searchW - 2),
                if query.len > 0: c.p.textBody else: c.inks.placeholder)
  discard c.node(parent, r, x, searchW, 1, [("search", query), ("input", shown)])
  discard c.drawSelect(p.s, parent, r, x + searchW + 1, filterW, "status-filter",
                       "status-filter", $vm.filter.val, filters, $vm.filter.val,
                       proc(id: string) =
                         for f in filterChoices():
                           if $f == id: vm.setFilter(f))
  r += 2
  let files = c.node(parent, r, p.col, p.width, 1, [("files", "code")])
  let notice = vm.filesNotice
  if notice.len > 0:
    c.notice(files, r, p.col, p.width, max(1, bottom - r), notice, "filtered")
    return bottom - row
  var k = 0
  var previous = p.g.panel
  var q = p
  for f in vm.files:
    if f.key: q.keySlot = true
    if f.file.binary: q.binarySlot = true
    q.originSlot = max(q.originSlot, widthOf(q.originText(f.file.origin)))
  let p = q
  for f in vm.files:
    let ground = p.g.nextGround(k, previous)
    let used = c.drawFileRow(p, files, f, r, ground)
    previous = if f.selected: p.g.selection else: ground
    r += used
  files.height = r - files.row
  r - row

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc drawChangesPanel*(c: var AhCanvas; vm: ChangesVM; row, col, width, height: int;
                       context = AgentHarborChangesContext(); state: AhP3State = nil) =
  ## The Changes panel over `vm` at (`row`, `col`), `width` × `height`
  ## cells, the session `context` names. `state` is the host's (the dropped
  ## select, the spinner's frame); nil draws every select closed.
  state.beginDraw()
  let root = c.node(nil, row, col, width, height,
                    [("surface", "agent-harbor-changes"), ("width-px", $(width * CellPx)),
                     ("state", stateName(vm.state.val))])
  let g = c.p3Grounds
  c.area("panel-body", row, col, width, height, g.panel)
  let ready = vm.state.val == asReady
  var r = row + c.drawSectionHeader(root, row, col, width, ChangesSectionLabel,
                                    changesContextPhrase(context.sessionLabel),
                                    if ready: vm.rollUp(context.ended) else: "")
  let bottom = row + height
  case vm.state.val
  of asIdle, asLoading:
    c.notice(root, r, col, width, bottom - r, ChangesLoadingNotice, "loading")
    return
  of asError:
    let target = vm
    c.errorBlock(root, r, col, width, bottom - r, ChangesErrorTitle, vm.error.val,
                 proc() = target.restart())
    return
  of asReady: discard
  let p = ChangesPress(vm: vm, s: state, g: g, col: col, width: width)
  c.drawTabs(p, root, r)
  inc r
  let tab = vm.activeTab.val
  let content = c.node(root, r, col, width, max(0, bottom - r), [("tab-shown", $tab)])
  if vm.hasPlan and tab != rtCode:
    c.drawMilestoneSelector(p, content, r)
    inc r
  let notice = vm.notice
  if notice.len > 0:
    c.notice(content, r, col, width, max(1, bottom - r), notice, "empty")
  else:
    # The tab's content scrolls in the rows under the bar (and the
    # selector): the keyboard's item, or else the selected file, is kept
    # in view when it changes.
    let height = max(1, bottom - r)
    let keepFact = if tab == rtCode: "file" else: "card"
    let keepValue = if vm.focus.val.len > 0: vm.focus.val
                    elif tab == rtCode: vm.selectedFile.val else: ""
    let base = p
    discard c.drawScrolled(state, ChangesScrollKey, content, r, col, width, height, g.panel,
                           keepFact, keepValue,
                           proc(sub: var AhCanvas; parent: AhNode; row, w: int): int =
      var q = base
      q.width = w
      case tab
      of rtSpecChanges: sub.drawSpecChanges(q, parent, row)
      of rtTests: sub.drawTests(q, parent, row)
      of rtImplementation: 1 + sub.drawDetails(q, parent, row + 1)
      of rtCode: 1 + sub.drawCode(q, parent, row + 1, row + height))
  c.drawMenus(state)
