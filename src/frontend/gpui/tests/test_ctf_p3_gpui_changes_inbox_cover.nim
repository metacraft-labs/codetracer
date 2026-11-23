## test_ctf_p3_gpui_changes_inbox_cover.nim — CTF-P3: **the GPUI views of the
## Changes panel, the Inbox and an inbox item's page draw what their
## viewmodels say, and the comparison that says so can fail.**
##
## The CTF-P1b coverage test (`test_ctf_p1b_gpui_views_cover_web_states.nim`)
## mounts every story of the Agent Harbor section in GPUI and compares the
## drawn tree with the story's viewmodel; for these three surfaces it runs
## the comparisons of `ctf_p3_gpui_cover.nim`. This suite holds those
## comparisons to account, without the story registry: each case builds a
## story's viewmodel with the same constructor the web and GPUI story hosts
## use (`stories/agent_harbor_changes_inbox_stories.nim`), draws it with the
## GPUI view into a real isonim-gpui shadow tree (the shim loaded in
## process; no window), and
##
##   * shows that the untouched drawing agrees with its viewmodel, at the
##     brief's three widths and in both colour modes, for a story of each
##     tab, an inbox mid-walk, an inbox emptied beside the gone item's page
##     and item pages of each kind; and
##   * plants one disagreement at a time and shows it is reported by name:
##     the spec card list drawn one card short, a card's state word drawn
##     but tagged with another, the item on screen moved after drawing, a
##     login's Continue missing, the full tab labels on a narrow panel, an
##     inbox step drawn in the wrong ink, a file row of the Code tab gone,
##     the inbox's hint gone, an approval's command run on into its purpose,
##     a Code-tab mark short where the row has room, a choice drawn with
##     another control, the reading column at another width, and the
##     keyboard's file scrolled out of its region's window; and
##   * mounts the keyboard stories in the GPUI story host at the brief's
##     sizes and shows their first frames scrolled to what the keyboard is
##     on, and the page keys scrolling a long list.
##
## No mocks: the viewmodels read the synthetic fixture sets of
## nim-agents-isonim-viewmodels through the production data-source seam,
## their writes go to its scripted action source, and the renderer is
## isonim-gpui's own.
##
## Trap 13 / §29 (`Verification-Harness-Traps.md`): every helper that calls
## `check` is a template; the procs return what they found.

import std/[strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_changes_inbox_stories
import ./ctf_p3_gpui_cover
import ../agent_harbor/ah_stories

const
  Widths = [("laptop", 1432), ("panel", 752), ("sidebar", 352)]
    ## The brief's sizes less the story frame's 4px sides (`ah_stories`).
  Modes = [dmDark, dmLight]

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

let r = GpuiRenderer()

proc host(): GpuiElement =
  gpui_reset_tree()
  r.createElement("div")

proc drawnChanges(fixture: string; widthPx: int; mode: DesignMode):
    tuple[view: GpuiElement, vm: ChangesVM] =
  let vm = createChangesStoryVM(fixture)
  let h = host()
  r.drawChangesPanel(h, vm, ahPalette(mode), widthPx, changesStoryContext(fixture))
  (h, vm)

proc drawnInbox(fixture: string; widthPx: int; mode: DesignMode):
    tuple[view: GpuiElement, vm: InboxVM] =
  let vm = createInboxStoryVM(fixture)
  let h = host()
  r.drawInboxPanel(h, vm, ahPalette(mode), widthPx, inboxStoryContext(fixture, StoryHostRequests()))
  (h, vm)

proc drawnItem(fixture: string; widthPx: int; mode: DesignMode):
    tuple[view: GpuiElement, page: InboxItemVM, ctx: AgentHarborInboxItemContext] =
  let page = createInboxItemStoryVM(fixture)
  let ctx = inboxItemStoryContext(fixture, StoryHostRequests())
  let h = host()
  r.drawInboxItemPage(h, page, ahPalette(mode), widthPx, ctx)
  (h, page, ctx)

proc changesProblems(view: GpuiElement; vm: ChangesVM; fixture: string; widthPx: int): seq[string] =
  checkChanges(view, vm, widthPx, changesStoryContext(fixture)) & p3DrawnTextProblems(view)

proc inboxProblems(view: GpuiElement; vm: InboxVM; fixture: string; widthPx: int;
                   mode: DesignMode): seq[string] =
  checkInbox(view, vm, widthPx, inboxStoryContext(fixture, StoryHostRequests())) &
    p3DrawnTextProblems(view) & inboxInkProblems(view, ahPalette(mode))

proc remove(e: GpuiElement) =
  ## Takes `e` out of the drawn tree, as a view that never drew it would.
  r.removeChild(r.parentNode(e), e)

suite "CTF-P3: the GPUI views draw what their viewmodels say":
  test "every Changes story fixture, at each width and in both modes":
    var failures: seq[string]
    var drawnCount = 0
    for fixture in changesStoryFixtures:
      for (name, w) in Widths:
        for mode in Modes:
          let (view, vm) = drawnChanges(fixture, w, mode)
          let problems = changesProblems(view, vm, fixture, w)
          if problems.len > 0:
            failures.add fixture & " @ " & name & "/" & $mode & ": " & problems.join("; ")
          else: inc drawnCount
          vm.dispose()
    if failures.len > 0: echo "  " & failures.join("\n  ")
    ck failures.len == 0
    ck drawnCount == changesStoryFixtures.len * Widths.len * Modes.len

  test "every Inbox story fixture but the playback, at each width and in both modes":
    var failures: seq[string]
    var drawnCount = 0
    for fixture in inboxStoryFixtures:
      if fixture == InboxPlaybackFixture: continue
      for (name, w) in Widths:
        for mode in Modes:
          let (view, vm) = drawnInbox(fixture, w, mode)
          let problems = inboxProblems(view, vm, fixture, w, mode)
          if problems.len > 0:
            failures.add fixture & " @ " & name & "/" & $mode & ": " & problems.join("; ")
          else: inc drawnCount
          vm.dispose()
    if failures.len > 0: echo "  " & failures.join("\n  ")
    ck failures.len == 0
    ck drawnCount == (inboxStoryFixtures.len - 1) * Widths.len * Modes.len

  test "the emptied inbox keeps the gone item's page beside its notice":
    # `emptied`: what the fixture claims, then that the panel draws both
    # the empty inbox and the page (the comparison above checks they agree).
    let (view, vm) = drawnInbox("emptied", 1432, dmDark)
    ck vm.isEmpty and vm.notice == EmptyInboxText
    ck not vm.canNext and not vm.canPrev
    ck not vm.current.val.isNone and not vm.page.isNil
    ck view.values("item").len == 0
    ck view.values("notice") == @["empty"] and view.values("page") == @["inbox"]
    vm.dispose()

  test "every item page story fixture, at each width and in both modes":
    var failures: seq[string]
    var drawnCount = 0
    for fixture in inboxItemStoryFixtures:
      for (name, w) in Widths:
        for mode in Modes:
          let (view, page, ctx) = drawnItem(fixture, w, mode)
          let problems = checkItemPage(view, page, ctx) & p3DrawnTextProblems(view)
          if problems.len > 0:
            failures.add fixture & " @ " & name & "/" & $mode & ": " & problems.join("; ")
          else: inc drawnCount
          page.dispose()
    if failures.len > 0: echo "  " & failures.join("\n  ")
    ck failures.len == 0
    ck drawnCount == inboxItemStoryFixtures.len * Widths.len * Modes.len

suite "CTF-P3: the comparison can fail (positive controls)":
  test "the spec card list drawn one card short is reported":
    let (view, vm) = drawnChanges("spec-changes", 1432, dmDark)
    ck changesProblems(view, vm, "spec-changes", 1432).len == 0
    let cards = view.all("card")
    ck cards.len == vm.specCards.len and cards.len > 1
    remove(cards[^1])
    let problems = changesProblems(view, vm, "spec-changes", 1432).join("; ")
    ck problems.contains("spec cards: drawn")
    vm.dispose()

  test "a state word tagged with one word and drawn with another is reported":
    let (view, vm) = drawnChanges("spec-changes", 1432, dmLight)
    let word = view.firstOf("state-word")
    ck word != nil
    r.setAttribute(word, "data-ah-state-word", "approved")
    let problems = changesProblems(view, vm, "spec-changes", 1432).join("; ")
    ck problems.contains("a state-word says 'approved' but draws")
    vm.dispose()

  test "the full tab labels on a narrow panel are reported":
    # Drawn at a laptop's width, compared as the sidebar's.
    let (view, vm) = drawnChanges("populated", 1432, dmDark)
    let problems = checkChanges(view, vm, 352, changesStoryContext("populated")).join("; ")
    ck problems.contains("tab labels: drawn")
    vm.dispose()

  test "a Code tab file row the view did not draw is reported":
    let (view, vm) = drawnChanges("code", 752, dmDark)
    ck changesProblems(view, vm, "code", 752).len == 0
    remove(view.firstOf("vcs-row"))
    ck changesProblems(view, vm, "code", 752).join("; ").contains("files: drawn")
    vm.dispose()

  test "the item on screen moved after drawing is reported until the view redraws":
    let (view, vm) = drawnInbox("prev-next", 1432, dmDark)
    ck inboxProblems(view, vm, "prev-next", 1432, dmDark).len == 0
    ck vm.prev()
    let stale = inboxProblems(view, vm, "prev-next", 1432, dmDark).join("; ")
    ck stale.contains("item on screen")
    r.drawInboxPanel(view, vm, ahPalette(dmDark), 1432,
                     inboxStoryContext("prev-next", StoryHostRequests()))
    ck inboxProblems(view, vm, "prev-next", 1432, dmDark).len == 0
    vm.dispose()

  test "an inbox step drawn in the wrong ink is reported":
    let (view, vm) = drawnInbox("prev-next-first", 752, dmLight)
    ck inboxProblems(view, vm, "prev-next-first", 752, dmLight).len == 0
    let p = ahPalette(dmLight)
    for e in view.all("inbox-step"):
      if e.fact("enabled") == "false": r.setAttribute(e, "data-ah-ink", p.textBody)
    ck inboxProblems(view, vm, "prev-next-first", 752, dmLight).join("; ").contains(
      "is drawn in " & p.textBody & ", not " & p.textDisabled)
    vm.dispose()

  test "a completed sign-in's Continue missing is reported":
    let (view, page, ctx) = drawnItem("login-completed", 752, dmDark)
    ck checkItemPage(view, page, ctx).len == 0
    var continueButton: GpuiElement
    for e in view.all("button"):
      if e.fact("button") == ContinueLabel: continueButton = e
    ck continueButton != nil
    remove(continueButton)
    ck checkItemPage(view, page, ctx).join("; ").contains("Continue: drawn false")
    page.dispose()

suite "CTF-P3: the keys (the catalogue's changes.* and inbox.*) in the GPUI story host":
  # The GPUI story host's own mount (`ah_stories.mountAgentHarborStoryGpui`):
  # a key's canonical name, routed in the panel's scope, runs the
  # operation the base keymap binds to it, and the view redraws to show it.
  test "Down, Enter and Right on the Changes panel; ] and 1 on the Inbox":
    gpui_reset_tree()
    let c = r.mountAgentHarborStoryGpui("agent-harbor-changes", "populated", 1440, 900)
    defer: c.dispose()
    let keys = c.changesInbox.changes.focusables
    ck c.changesKey("Down") == "changes.focus-next"
    ck c.changesInbox.changes.focus.val == keys[0]
    var focused: seq[string]
    for e in c.view.all("card"):
      if e.fact("focused") == "true": focused.add e.fact("card")
    ck focused == @[keys[0]]
    ck c.changesKey("Enter") == "changes.toggle"
    ck c.changesInbox.changes.specCards[0].open
    ck c.changesKey("Right") == "changes.next-tab"
    ck c.changesInbox.changes.activeTab.val == rtTests
    # A page key scrolls the tab only when it holds more than it shows
    # (the next suite); here it is routed either way.
    discard c.changesKey("PageDown")
    gpui_reset_tree()
    let i = r.mountAgentHarborStoryGpui("agent-harbor-inbox", "prev-next", 1440, 900)
    defer: i.dispose()
    let before = i.changesInbox.inbox.positionText
    ck i.inboxKey("]") == "inbox.next"
    ck i.changesInbox.inbox.positionText != before
    ck i.inboxKey("[") == "inbox.previous"
    ck i.inboxKey("1") == "inbox.priority-1"

suite "CTF-P3 step 3d: the review's follow-ups in GPUI":
  test "the keyboard stories' first frames show what the keyboard is on, at every size":
    for (surface, fixture) in [("agent-harbor-changes", "code-long-keyboard"),
                               ("agent-harbor-inbox", "long-keyboard")]:
      for (w, h) in [(1440, 900), (760, 640), (360, 900)]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui(surface, fixture, w, h, dmDark, frameTitle = "Story")
        let width = parseInt(m.view.fact("width-px"))
        let problems =
          if surface == "agent-harbor-changes":
            checkChanges(m.view, m.changesInbox.changes, width, changesStoryContext(fixture))
          else:
            checkInbox(m.view, m.changesInbox.inbox, width,
                       inboxStoryContext(fixture, StoryHostRequests()))
        if problems.len > 0: echo "  " & fixture & " @ " & $w & ": " & problems.join("; ")
        ck problems.len == 0
        var scrolled = false
        for region in m.view.all("scroll-region"):
          if parseInt(region.fact("scroll-top")) > 0: scrolled = true
        ck scrolled
        m.dispose()

  test "the page keys scroll a long list, and the keyboard's item stays in view after a step":
    gpui_reset_tree()
    let c = r.mountAgentHarborStoryGpui("agent-harbor-changes", "code-long", 760, 640)
    defer: c.dispose()
    ck c.changesInbox.changes.activeTab.val == rtCode
    let before = c.view.firstOf("scroll-region").fact("scroll-top")
    ck c.changesKey("PageDown") == "changes.page-down"
    ck c.view.firstOf("scroll-region").fact("scroll-top") != before
    ck c.changesKey("PageUp") == "changes.page-up"
    ck c.view.firstOf("scroll-region").fact("scroll-top") == before
    gpui_reset_tree()
    let i = r.mountAgentHarborStoryGpui("agent-harbor-inbox", "long-keyboard", 1440, 900)
    defer: i.dispose()
    let at = i.view.firstOf("scroll-region").fact("scroll-top")
    ck i.inboxKey("PageUp") == "inbox.page-up"
    ck i.view.firstOf("scroll-region").fact("scroll-top") != at
    # A step puts another item on screen: it is brought into view again.
    ck i.inboxKey("[") == "inbox.previous"
    let width = parseInt(i.view.fact("width-px"))
    ck checkInbox(i.view, i.changesInbox.inbox, width,
                  inboxStoryContext("long-keyboard", StoryHostRequests())).len == 0

  test "the inbox's hint gone is reported; the hint shows only with nothing on screen":
    let (view, vm) = drawnInbox("populated", 1432, dmDark)
    ck vm.current.val.isNone and vm.wantsItemHint
    ck view.values("item-hint") == @[itemHintText()]
    ck inboxProblems(view, vm, "populated", 1432, dmDark).len == 0
    # The hint not drawn: its fact gone with it (a fact that is empty is
    # not found).
    let hint = view.firstOf("item-hint")
    if hint != nil: r.setAttribute(hint, "data-ah-item-hint", "")
    ck inboxProblems(view, vm, "populated", 1432, dmDark).join("; ").contains("item hint: drawn")
    vm.dispose()
    let (walked, wvm) = drawnInbox("prev-next", 1432, dmDark)
    ck walked.values("item-hint").len == 0
    wvm.dispose()

  test "an approval's command run on into its purpose is reported":
    let (view, page, ctx) = drawnItem("sudo", 1432, dmLight)
    ck checkItemPage(view, page, ctx, 1432).len == 0
    let subject = view.firstOf("approval-subject")
    ck subject != nil
    if subject != nil:
      r.setAttribute(subject, "data-ah-approval-subject", approvalSummary(page.detail.approvals[0]))
    let problems = checkItemPage(view, page, ctx, 1432).join("; ")
    ck problems.contains("approval commands: drawn")
    ck problems.contains("runs on into its purpose")
    page.dispose()

  test "a Code-tab mark with no tooltip, or the legend gone, is reported":
    let (view, vm) = drawnChanges("code", 1432, dmDark)
    ck changesProblems(view, vm, "code", 1432).len == 0
    ck view.values("code-legend") == @[CodeMarksLegend]
    let mark = view.firstOf("mark-word")
    ck mark != nil
    if mark != nil: r.setAttribute(mark, "data-ah-mark-title", "")
    let legend = view.firstOf("code-legend")
    if legend != nil: r.setAttribute(legend, "data-ah-code-legend", "")
    let problems = changesProblems(view, vm, "code", 1432).join("; ")
    ck problems.contains("marks legend: drawn")
    ck problems.contains("has no tooltip")
    vm.dispose()
    let (narrow, nvm) = drawnChanges("code", 352, dmDark)
    ck narrow.values("code-legend") == @[CodeMarksLegend]
    nvm.dispose()

  test "a choice drawn with another control, or the reading column at another width, is reported":
    let (view, page, ctx) = drawnItem("question-multi", 1432, dmDark)
    ck checkItemPage(view, page, ctx, 1432).len == 0
    ck view.values("control") == @["checkbox", "checkbox", "checkbox"]
    let control = view.firstOf("control")
    if control != nil: r.setAttribute(control, "data-ah-control", "toggle")
    ck checkItemPage(view, page, ctx, 1432).join("; ").contains("choice controls: drawn")
    page.dispose()
    let (single, spage, sctx) = drawnItem("question-single", 1432, dmDark)
    ck single.values("control") == @["toggle", "toggle"]
    ck single.values("reading-width") == @[$ItemReadingMaxPx]
    let reading = single.firstOf("reading-width")
    if reading != nil: r.setAttribute(reading, "data-ah-reading-width", "1416")
    ck checkItemPage(single, spage, sctx, 1432).join("; ").contains("reading column: drawn")
    spage.dispose()

  test "the keyboard's file scrolled out of its region's window is reported":
    gpui_reset_tree()
    let m = r.mountAgentHarborStoryGpui("agent-harbor-changes", "code-long-keyboard", 760, 640)
    defer: m.dispose()
    let width = parseInt(m.view.fact("width-px"))
    let ctx = changesStoryContext("code-long-keyboard")
    ck checkChanges(m.view, m.changesInbox.changes, width, ctx).len == 0
    let region = m.view.firstOf("scroll-region")
    if region != nil: r.setAttribute(region, "data-ah-scroll-top", "0")
    ck checkChanges(m.view, m.changesInbox.changes, width, ctx).join("; ").contains(
      "the keyboard's item is out of view")

suite "CTF-P3: assertion count":
  test "every assertion ran":
    check countedAssertions == 39 + 12 + 9 + 5 + 4 + 6 + 6 + 2
