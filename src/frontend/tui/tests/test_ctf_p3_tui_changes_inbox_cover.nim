## test_ctf_p3_tui_changes_inbox_cover.nim — CTF-P3: **the terminal views of
## the Changes panel, the Inbox and an inbox item's page draw what their
## viewmodels say, and the comparison that says so can fail.**
##
## The CTF-P1b coverage test (`real_terminal/test_ctf_p1b_tui_views_cover_web_states.nim`)
## mounts every story of the Agent Harbor section in the terminal story host
## and compares the drawing with the story's viewmodel and with a real
## terminal; for these three surfaces it runs the comparisons of
## `ctf_p3_tui_cover.nim`. This suite holds those comparisons to account in
## process (no pty), as GPUI's `test_ctf_p3_gpui_changes_inbox_cover.nim`
## does for its own: each case mounts a story with the terminal story host's
## mount (`ah_tui_stories.mountStory`, the story constructors the web and
## GPUI use) and
##
##   * shows that every story of the three surfaces agrees with its viewmodel
##     at the brief's three sizes (laptop 180×56, panel 95×40, sidebar 45×56
##     cells) and in both colour modes; and
##   * plants one disagreement at a time and shows it is reported by name: a
##     card opened after drawing, a state word drawn in another role's ink,
##     the full tab labels on a narrow panel, a Code tab file row drawn by a
##     copy of the VCS row rather than by the VCS pane's spans (broken copy B14,
##     in process), the item on screen moved after drawing, an inbox step in
##     the wrong ink, a text fact naming a word its cells do not show, the
##     inbox's hint gone, an approval's command run on into its purpose, a
##     Code-tab mark short where the row has room or with no tooltip, a
##     choice drawn with another control, a page wider than the reading
##     measure (step 3d).
##
## And it drives the views as a reader does, through the story host's press
## handling (`handleInput` with SGR mouse reports, as the terminal sends
## them): a press on a tab selects it, on a closed card opens it, on a
## select drops its menu and on a choice picks it, on a row of the inbox
## opens its item; every write a press makes reaches the scripted action
## source only.
##
## No mocks: the viewmodels read the synthetic fixture sets of
## nim-agents-isonim-viewmodels through the production data-source seam,
## their writes go to its scripted action source (the prototypes'
## no-write seam), and the views are the product's.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper that calls
## `check` is a template; the procs return what they found.

import std/[strutils, unittest]
import isonim/core/clock

import ../agent_harbor/ah_tui_stories
import ./ctf_p3_tui_cover

const
  Sizes = [("laptop", 180, 56), ("panel", 95, 40), ("sidebar", 45, 56)]
  Modes = [dmDark, dmLight]
  StepThreeD = 6 + 4 + 6 + 5 + 6
    ## The step-3d suite's assertions (the hint, the approval, the marks,
    ## the controls and the reading measure, the priority dropdown).
  ExpectedAssertions = 104 + 3 * (3 + 4 + 4) + StepThreeD

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

let section = agentHarborSection()

proc storyOf(surface, fixture: string): CodeTracerStory =
  for s in section.stories:
    if s.surface == surface and s.fixture == fixture: return s
  raise newException(KeyError, "no story " & surface & " " & fixture)

proc problemsOf(m: AhTuiMount): seq[string] =
  checkChangesInbox(m) & changesInboxStyleProblems(m, m.p3GridLook)

proc sgrPress(row, col: int): string =
  ## A left-button press at the 0-based (`row`, `col`), as SGR-1006 reports it.
  "\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M"

proc press(m: AhTuiMount; n: AhNode): bool =
  ## A press on the first cell of `n`, through the story host's input path.
  m.handleInput(sgrPress(n.row, n.col))

suite "CTF-P3: every Changes and Inbox story agrees with its viewmodel":
  test "every story of the three surfaces, at each size and in both modes":
    var failures: seq[string]
    var drawn = 0
    for story in section.stories:
      if story.surface notin TuiChangesInboxSurfaces: continue
      for (size, cols, rows) in Sizes:
        for mode in Modes:
          let m = mountStory(story, cols, rows, mode)
          let problems = m.problemsOf
          if problems.len > 0:
            failures.add storybookId(section, story) & " @ " & size & "/" & $mode & ": " &
                         problems.join("; ")
          inc drawn
          m.dispose()
    if failures.len > 0: echo "  ", failures.join("\n  ")
    ck failures.len == 0
    ck drawn >= 62 * Sizes.len * Modes.len
    echo "  compared ", drawn, " drawings"

suite "CTF-P3: the comparisons can fail":
  test "a card opened after drawing is reported until the view redraws":
    let m = mountStory(storyOf("agent-harbor-changes", "populated"), 180, 56, dmDark)
    defer: m.dispose()
    ck m.problemsOf.len == 0
    let card = m.changes.specCards[0]
    m.changes.toggleCard(card.key)
    let problems = checkChangesInbox(m)
    ck problems.join(" ").contains("open cards")
    m.draw()
    ck checkChangesInbox(m).len == 0

  test "a state word drawn in another role's ink is reported":
    let m = mountStory(storyOf("agent-harbor-changes", "spec-changes"), 180, 56, dmLight)
    defer: m.dispose()
    let w = m.view.first("state-word")
    ck w != nil
    let p = ahPalette(dmLight)
    discard m.canvas.put(w.row, w.col + 2, w.attr("state-word"), p.textError)
    ck changesInboxStyleProblems(m, m.p3GridLook).join(" ").contains("the state word")

  test "the full tab labels on a narrow panel are reported":
    let m = mountStory(storyOf("agent-harbor-changes", "populated"), 45, 56, dmDark)
    defer: m.dispose()
    ck checkChangesInbox(m).len == 0
    for t in m.view.all("tab-label"):
      let full = block:
        var label = ""
        for tab in m.changes.tabs:
          if tab.compactLabel == t.attr("tab-label"): label = tab.label
        label
      t.tag("tab-label", full)
    ck checkChangesInbox(m).join(" ").contains("tab labels")

  test "a Code tab file row drawn by a copy of the VCS row is reported (B14)":
    # The copy draws what the web's VCS row shows -- the state letter, the
    # path and the counts -- but not the terminal VCS pane's row (its
    # selection cell, its spacing and its inks): the cells are no longer the
    # pane's spans.
    let m = mountStory(storyOf("agent-harbor-changes", "code"), 180, 56, dmDark)
    defer: m.dispose()
    ck vcsRowProblems(m, m.p3GridLook).len == 0
    let row = m.view.first("vcs-row")
    ck row != nil
    let p = ahPalette(dmDark)
    let copy = row.attr("vcs-file-status") & "  " & row.attr("vcs-file-name") & "  " &
               row.attr("vcs-file-stats")
    discard m.canvas.put(row.row, row.col + 1, alignLeft(copy, 60), p.textBody)
    ck vcsRowProblems(m, m.p3GridLook).join(" ").contains("the VCS pane's row has")

  test "the item on screen moved after drawing is reported until the view redraws":
    let m = mountStory(storyOf("agent-harbor-inbox", "prev-next"), 95, 40, dmDark)
    defer: m.dispose()
    ck m.problemsOf.len == 0
    discard m.inbox.next()
    ck checkChangesInbox(m).join(" ").contains("item on screen")
    m.draw()
    ck checkChangesInbox(m).len == 0

  test "an inbox step drawn in the wrong ink is reported":
    let m = mountStory(storyOf("agent-harbor-inbox", "empty"), 95, 40, dmDark)
    defer: m.dispose()
    let s = m.view.first("inbox-step")
    ck s != nil and s.attr("enabled") == "false"
    discard m.canvas.put(s.row, s.col + 1, PreviousArrow, ahPalette(dmDark).textBody)
    ck changesInboxStyleProblems(m, m.p3GridLook).join(" ").contains("the inbox step")

  test "a text fact naming a word its cells do not show is reported":
    let m = mountStory(storyOf("agent-harbor-inbox", "populated"), 180, 56, dmDark)
    defer: m.dispose()
    ck p3TextProblems(m).len == 0
    m.view.first("item-label").tag("item-label", "Something else entirely")
    ck p3TextProblems(m).join(" ").contains("item-label")

suite "CTF-P3: a reader's presses reach the viewmodels":
  test "a press on a tab selects it, and on a closed card opens it":
    let m = mountStory(storyOf("agent-harbor-changes", "populated"), 180, 56, dmDark)
    defer: m.dispose()
    var tests: AhNode
    for t in m.view.all("changes-tab"):
      if t.attr("changes-tab") == $rtTests: tests = t
    ck tests != nil
    ck m.press(tests)
    ck m.changes.activeTab.val == rtTests
    ck m.problemsOf.len == 0
    let back = m.view.first("changes-tab")
    ck m.press(back)
    let card = m.view.first("card")
    ck card.attr("open") == "false"
    ck m.press(card)
    ck m.view.first("card").attr("open") == "true"
    ck m.problemsOf.len == 0

  test "a press on a select drops its menu, and on a choice picks it":
    let m = mountStory(storyOf("agent-harbor-changes", "populated"), 180, 56, dmLight)
    defer: m.dispose()
    let select = m.view.first("milestone-select")
    ck select != nil
    ck m.press(select)
    let menu = m.canvas.root.first("menu")
    ck menu != nil and menu.attr("menu") == "milestone"
    let choices = menu.all("menu-choice")
    ck choices.len == m.changes.milestoneChoices.len and choices.len > 1
    ck m.press(choices[1])
    ck m.changes.milestone.val == m.changes.milestoneChoices[1][0]
    ck m.canvas.root.first("menu").isNil
    ck m.problemsOf.len == 0

  test "a press on an inbox row asks the host for its session, and moves nothing":
    # A row pressed asks the host for the item's session tab (the role
    # P2a's tab strip's `showSession` plays); the cursor stays where the
    # server keeps it, as on the web.
    let m = mountStory(storyOf("agent-harbor-inbox", "prev-next"), 180, 56, dmDark)
    defer: m.dispose()
    let rows = m.view.all("item")
    ck rows.len > 1
    var other: AhNode
    var onScreen = ""
    for r in rows:
      if r.attr("current") == "false" and other.isNil: other = r
      if r.attr("current") == "true": onScreen = r.attr("item")
    let asked = m.inbox.requests.val
    ck m.press(other)
    ck m.inbox.requests.val == asked + 1
    ck m.inbox.requestedSession.val.len > 0
    var current = ""
    for r in m.view.all("item"):
      if r.attr("current") == "true": current = r.attr("item")
    ck current == onScreen
    ck m.problemsOf.len == 0

const
  KeyDown = "\e[B"
  KeyUp = "\e[A"
  KeyRight = "\e[C"
  KeyLeft = "\e[D"
  KeyEnter = "\r"
  KeyPageDown = "\e[6~"
  KeyPageUp = "\e[5~"

proc wheelDown(m: AhTuiMount; row, col: int): bool =
  ## A notch of the wheel down at the 0-based (`row`, `col`), as SGR reports it.
  m.handleInput("\x1b[<65;" & $(col + 1) & ";" & $(row + 1) & "M")

proc onScreen(m: AhTuiMount; fact, value: string): bool =
  ## The node carrying `fact` = `value` is drawn whole on the screen.
  for n in m.canvas.root.all(fact):
    if n.attr(fact) == value: return n.row < m.rows and n.row + max(1, n.height) <= m.rows

proc reachedBy(m: AhTuiMount; key, fact, value: string; presses = 200): int =
  ## How many presses of `key` bring the node to the screen; -1 for never.
  for i in 0 .. presses:
    if m.onScreen(fact, value): return i
    if not m.handleInput(key): return -1
  -1

suite "CTF-P3: the keys (the catalogue's changes.* and inbox.*)":
  test "Down and Up move the keyboard through the cards, Enter opens and closes, Right and Left the tabs":
    let m = mountStory(storyOf("agent-harbor-changes", "populated"), 95, 40, dmDark)
    defer: m.dispose()
    let keys = m.changes.focusables
    check keys.len > 2
    ck m.handleInput(KeyDown)
    ck m.lastOperation == "changes.focus-next"
    ck m.changes.focus.val == keys[0]
    ck m.handleInput(KeyDown)
    ck m.changes.focus.val == keys[1]
    ck m.handleInput(KeyUp)
    ck m.lastOperation == "changes.focus-previous"
    ck m.changes.focus.val == keys[0]
    ck m.problemsOf.len == 0
    ck m.handleInput(KeyEnter)
    ck m.lastOperation == "changes.toggle"
    ck m.view.first("focused").attr("open") == "true"
    ck m.problemsOf.len == 0
    ck m.handleInput(KeyEnter)
    ck m.view.first("focused").attr("open") == "false"
    ck m.handleInput(KeyRight)
    ck m.lastOperation == "changes.next-tab"
    ck m.changes.activeTab.val == rtTests
    ck m.handleInput(KeyLeft)
    ck m.lastOperation == "changes.previous-tab"
    ck m.changes.activeTab.val == rtSpecChanges

  test "in Code, Down walks the files and Enter opens and closes the one it is on":
    let m = mountStory(storyOf("agent-harbor-changes", "code"), 180, 56, dmLight)
    defer: m.dispose()
    ck m.handleInput(KeyDown)
    ck m.handleInput(KeyDown)
    let path = m.changes.focus.val
    ck path == m.changes.files[1].file.path
    ck m.handleInput(KeyEnter)
    ck m.changes.selectedFile.val == path
    ck m.view.first("file-diff") != nil
    ck m.problemsOf.len == 0
    ck m.handleInput(KeyEnter)
    ck m.changes.selectedFile.val == ""

  test "] and [ are Next and Previous over the server's cursor; 1-4 the priority; the tooltip names the key":
    let m = mountStory(storyOf("agent-harbor-inbox", "prev-next"), 180, 56, dmDark)
    defer: m.dispose()
    let before = m.inbox.positionText
    ck m.handleInput("]")
    ck m.lastOperation == "inbox.next"
    ck m.inbox.positionText != before
    ck m.problemsOf.len == 0
    ck m.handleInput("[")
    ck m.lastOperation == "inbox.previous"
    ck m.handleInput("1")
    ck m.lastOperation == "inbox.priority-1"
    ck stepperTitle(true).endsWith("(])") and stepperTitle(false).endsWith("([)")
    var titles: seq[string]
    for e in m.view.all("inbox-step"): titles.add e.attr("tooltip")
    ck titles == @[stepperTitle(false), stepperTitle(true)]

  test "a playback story keeps [ and ] for its bar":
    let m = mountStory(storyOf("agent-harbor-inbox", "playback-inbox-run"), 180, 56, dmDark,
                       newTestClock())
    defer: m.dispose()
    ck m.handleInput("]")
    ck m.lastOperation == "story-playback.next"

suite "CTF-P3: what is past the screen's foot can be reached":
  test "many files: Page Down, the wheel and the keyboard's item bring the last to the screen":
    let m = mountStory(storyOf("agent-harbor-changes", "code-long"), 45, 56, dmDark)
    defer: m.dispose()
    let last = m.changes.files[^1].file.path
    ck not m.onScreen("file", last)
    ck m.view.all("scrollbar").len == 1
    ck m.reachedBy(KeyPageDown, "file", last) > 0
    ck m.problemsOf.len == 0
    ck m.reachedBy(KeyPageUp, "file", m.changes.files[0].file.path) > 0
    let region = m.p3.regionOf(ChangesScrollKey)
    ck m.wheelDown(region.row + 2, region.col + 2)
    ck m.p3.regionOf(ChangesScrollKey).top == region.top + WheelRows
    # The keyboard's item is kept in view as it walks down.
    for i in 0 ..< 60: discard m.handleInput(KeyDown)
    ck m.onScreen("file", m.changes.focus.val)
    ck m.problemsOf.len == 0

  test "many cards and a long note scroll":
    let cards = mountStory(storyOf("agent-harbor-changes", "spec-changes"), 45, 24, dmLight)
    defer: cards.dispose()
    let lastCard = cards.changes.specCards[^1].key
    ck not cards.onScreen("card", lastCard)
    ck cards.reachedBy(KeyPageDown, "card", lastCard) > 0
    let notes = mountStory(storyOf("agent-harbor-changes", "implementation"), 45, 20, dmDark)
    defer: notes.dispose()
    var lastFile = ""
    for d in notes.changes.details:
      for k in d.keySourceFiles: lastFile = k.path
    ck not notes.onScreen("key-file", lastFile)
    ck notes.reachedBy(KeyPageDown, "key-file", lastFile) > 0

  test "many inbox items, and an item's page, scroll":
    let m = mountStory(storyOf("agent-harbor-inbox", "long"), 45, 56, dmDark)
    defer: m.dispose()
    let last = m.inbox.items[^1].id
    ck not m.onScreen("item", last)
    ck m.reachedBy(KeyDown, "item", last) > 0
    ck m.problemsOf.len == 0
    let page = mountStory(storyOf("agent-harbor-inbox-item", "sudo"), 45, 14, dmLight)
    defer: page.dispose()
    var lastApproval = ""
    for a in page.view.all("approval"): lastApproval = a.attr("approval")
    let buttons = page.view.all("button")
    ck buttons.len > 0
    let lastButton = buttons[^1].attr("button")
    proc lastButtonShown(p: AhTuiMount): bool =
      let all = p.view.all("button")
      all.len > 0 and all[^1].row < p.rows
    ck not page.lastButtonShown
    var presses = 0
    while not page.lastButtonShown and presses < 40:
      discard page.handleInput(KeyPageDown)
      inc presses
    ck page.lastButtonShown
    ck lastButton.len > 0 and lastApproval.len > 0

suite "CTF-P3: a story opened by the keys shows what the keyboard is on":
  test "the keyboard's card is marked and open (ChangesKeyboard)":
    for (size, cols, rows) in Sizes:
      let m = mountStory(storyOf("agent-harbor-changes", "keyboard"), cols, rows, dmDark)
      defer: m.dispose()
      let keys = m.changes.focusables
      ck keys.len > 1 and m.changes.focus.val == keys[1]
      let marked = m.view.all("focused")
      ck marked.len == 1 and marked[0].attr("card") == keys[1] and
         marked[0].attr("open") == "true"
      ck m.problemsOf.len == 0

  test "far down the files, the list is drawn scrolled to the opened file (ChangesCodeLongKeyboard)":
    for (size, cols, rows) in Sizes:
      let m = mountStory(storyOf("agent-harbor-changes", "code-long-keyboard"), cols, rows, dmLight)
      defer: m.dispose()
      let path = m.changes.focus.val
      ck path.len > 0 and m.changes.selectedFile.val == path
      ck m.p3.regionOf(ChangesScrollKey).top > 0
      ck m.onScreen("file", path)
      ck m.problemsOf.len == 0

  test "far down the inbox, the rows are drawn scrolled to the item on screen (InboxLongKeyboard)":
    for (size, cols, rows) in Sizes:
      let m = mountStory(storyOf("agent-harbor-inbox", "long-keyboard"), cols, rows, dmDark)
      defer: m.dispose()
      let current = m.inbox.current.val.id
      ck current.len > 0 and current != m.inbox.items[0].id
      var top = 0
      for key in [InboxScrollKey, InboxListScrollKey]:
        top = max(top, m.p3.regionOf(key).top)
      ck top > 0
      ck m.onScreen("item", current)
      ck m.problemsOf.len == 0

suite "CTF-P3 step 3d: the review's follow-ups in the terminal":
  test "the inbox's hint stands in the page's place, beside the rows at laptop, and opens nothing":
    let m = mountStory(storyOf("agent-harbor-inbox", "populated"), 180, 56, dmDark)
    defer: m.dispose()
    ck m.inbox.current.val.isNone and m.inbox.wantsItemHint
    ck m.view.values("item-hint") == @[itemHintText()]
    # Beside: the rows keep the list's 26rem; the hint is past the gap.
    let hint = m.view.first("item-hint")
    ck hint != nil and hint.col > ListBesideCells
    ck m.problemsOf.len == 0
    if hint != nil: hint.tag("item-hint", "")
    ck checkChangesInbox(m).join(" ").contains("item hint")
    let walked = mountStory(storyOf("agent-harbor-inbox", "prev-next"), 95, 40, dmDark)
    defer: walked.dispose()
    ck walked.view.values("item-hint").len == 0

  test "an approval's command stands on its own line, apart from its purpose":
    let m = mountStory(storyOf("agent-harbor-inbox-item", "sudo"), 180, 56, dmLight)
    defer: m.dispose()
    ck m.problemsOf.len == 0
    let subject = m.view.first("approval-subject")
    let purpose = m.view.first("approval-purpose")
    ck subject != nil and purpose != nil and purpose.row > subject.row
    if subject != nil:
      subject.tag("approval-subject", approvalSummary(m.inboxItem.detail.approvals[0]))
    let problems = checkChangesInbox(m).join(" ")
    ck problems.contains("approval commands")
    ck problems.contains("runs on into its purpose")

  test "the Code tab's marks carry their tooltips, and the legend says what they stand for":
    let m = mountStory(storyOf("agent-harbor-changes", "code"), 180, 56, dmDark)
    defer: m.dispose()
    ck m.problemsOf.len == 0
    ck m.view.values("code-legend") == @[CodeMarksLegend]
    let mark = m.view.first("mark-word")
    if mark != nil: mark.tag("mark-title", "")
    ck checkChangesInbox(m).join(" ").contains("has no tooltip")
    let narrow = mountStory(storyOf("agent-harbor-changes", "code"), 45, 56, dmDark)
    defer: narrow.dispose()
    ck narrow.view.values("code-legend") == @[CodeMarksLegend]
    ck narrow.problemsOf.len == 0
    let legend = narrow.view.first("code-legend")
    if legend != nil: legend.tag("code-legend", "")
    ck checkChangesInbox(narrow).join(" ").contains("marks legend")

  test "a choice drawn with another control, or a page past the reading measure, is reported":
    let m = mountStory(storyOf("agent-harbor-inbox-item", "question-single"), 180, 56, dmDark)
    defer: m.dispose()
    ck m.problemsOf.len == 0
    ck m.view.values("control") == @["toggle", "toggle"]
    let control = m.view.first("control")
    if control != nil: control.tag("control", "checkbox")
    ck checkChangesInbox(m).join(" ").contains("choice controls")
    let multi = mountStory(storyOf("agent-harbor-inbox-item", "question-multi"), 180, 56, dmDark)
    defer: multi.dispose()
    ck multi.view.values("control") == @["checkbox", "checkbox", "checkbox"]
    let reading = multi.view.first("reading-width")
    if reading != nil: reading.tag("reading-width", "178")
    ck checkChangesInbox(multi).join(" ").contains("past the reading measure")

  test "the priority dropdown reads its value whole and keeps the page's inset":
    for (size, cols, rows) in Sizes:
      let m = mountStory(storyOf("agent-harbor-inbox-item", "question"), cols, rows, dmDark)
      defer: m.dispose()
      let menu = m.view.first("priority-menu")
      ck menu != nil and menu.attr("priority-menu") == PriorityLabel
      ck menu.col + menu.width <= cols - 1
      discard size

suite "CTF-P3: assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
