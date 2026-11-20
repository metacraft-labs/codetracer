## The Changes panel's and the Inbox's story constructors (CTF-P3).
##
## A story of the `agent-harbor-changes` surface is a `ChangesVM` built by
## `createChangesStoryVM` over the story's fixture and the production view
## `isonim_agent_harbor_changes_view` rendered over it; an
## `agent-harbor-inbox` story is an `InboxVM` (`createInboxStoryVM`) under
## `isonim_agent_harbor_inbox_view`'s panel, and an `agent-harbor-inbox-item`
## story one item's `InboxItemVM` (`createInboxItemStoryVM`) under its page.
## StoryBook and the IsoNim Editor instance reach them through
## `mountCodeTracerStory` (`storybook_components.nim`), so both surfaces
## build the same viewmodel for the same story.
##
## Every story shows invented data only: the synthetic changes and inboxes
## of nim-agents-isonim-viewmodels (`synthetic_changes.nim`,
## `synthetic_inbox.nim`, the `inbox-run` playback scenario). The sources
## that hold a change or an inbox are the viewmodels' scripted action
## source, so every press a story's reader makes is answered from its script
## and recorded, and nothing reaches a server. The states no data shows
## (`loading`, `error`) are the data-source seam's pending and failing
## sources.
##
## A story fixture names the viewmodel fixture it is built over and what the
## reader has done on it (a tab chosen, a card opened, a file selected, an
## answer sent): the constructor does that through the viewmodel's own
## calls, as a reader's presses would, so a story never shows a state the
## viewmodel cannot reach.
##
## This module only says which source and which reader state each fixture
## names; its constructors are called inside a reactive root and the caller
## disposes what they return.

import isonim/core/owner
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, scripted_actions,
  synthetic_changes, synthetic_inbox, changes_vm, inbox_vm, inbox_item_vm,
  inbox_playback]
import ./agent_harbor_playback
import ../viewmodel/views/agent_harbor_changes_inbox_words

export changes_vm, inbox_vm, inbox_item_vm, agent_harbor_changes_inbox_words

# ---------------------------------------------------------------------------
# The Changes panel
# ---------------------------------------------------------------------------

const
  ChangesSessionLabel* = "Relay backpressure: bound the relay queues"
    ## The invented session the synthetic change is of.
  changesStoryFixtures* = [
    "populated", "spec-changes", "staged", "request-open", "malformed",
    "tests", "all-passing", "all-pending", "implementation", "code",
    "code-file-open", "code-filtered", "code-long", "no-plan",
    "no-spec-changes", "milestone", "running", "empty", "loading", "error",
    "revert-confirm", "reverting", "revert-failed", "keyboard", "code-long-keyboard"]
    ## Every fixture an `agent-harbor-changes` story may name.
  CodeLongKeyboardSteps* = 120
    ## How far down the three hundred files `code-long-keyboard`'s reader
    ## walked with `Down` before `Enter`: far past the foot of every size,
    ## so the list is scrolled to keep the file in view.
  RevertFailedReason* = "the plan changed on the server since this change was read"
    ## The scripted refusal of `revert-failed` (invented).

proc changesSourceFixture(fixture: string): string =
  ## The viewmodel fixture (`synthetic_changes.ChangesFixtureNames`) a story
  ## fixture is built over.
  case fixture
  of "spec-changes", "request-open", "tests", "implementation", "code",
     "code-file-open", "code-filtered", "milestone", "running",
     "revert-confirm", "reverting", "revert-failed", "keyboard": "populated"
  of "code-long-keyboard": "code-long"
  else: fixture

proc changesStoryContext*(fixture: string): AgentHarborChangesContext =
  ## The session a Changes story shows: the invented session, ended (so its
  ## roll-up shows) except in `running`, where the roll-up is hidden.
  AgentHarborChangesContext(sessionLabel: ChangesSessionLabel,
                            ended: fixture != "running")

proc firstCard(vm: ChangesVM; tier: SpecTier): string =
  for card in vm.specCards:
    if card.tier == tier: return card.key
  ""

proc approvableCard(vm: ChangesVM): string =
  for card in vm.specCards:
    if card.canApprove: return card.key
  ""

proc createChangesStoryVM*(fixture: string): ChangesVM =
  ## The viewmodel of the Changes story named by `fixture`
  ## (`changesStoryFixtures`). Raises `ValueError` for an unknown fixture
  ## rather than showing some other state under the story's name.
  if fixture notin changesStoryFixtures:
    raise newException(ValueError, "no Agent Harbor Changes story fixture named " & fixture)
  let source = changesFixture(changesSourceFixture(fixture))
  # `reverting` holds the revert unanswered, `revert-failed` has it refused;
  # every other press is answered as the scripted source's default.
  case fixture
  of "reverting":
    ScriptedActionSource(source).script.setRule(oaRevertSpecChange, neverAnswered())
  of "revert-failed":
    ScriptedActionSource(source).script.setRule(oaRevertSpecChange,
                                                failedWith(RevertFailedReason))
  else: discard
  result = newChangesVM(source, relayScope())
  result.load()
  case fixture
  of "spec-changes":
    # A requirement's card open on its inline diff, and the spec whose
    # approval request is open, open on its summary with Approve.
    let requirement = result.firstCard(stRequirement)
    if requirement.len > 0:
      result.toggleCard(requirement)
      result.toggleDiff(requirement)
    let approvable = result.approvableCard
    if approvable.len > 0: result.toggleCard(approvable)
  of "staged":
    for card in result.specCards:
      if card.staged: result.toggleCard(card.key)
  of "request-open":
    let card = result.firstCard(stSpec)
    result.toggleCard(card)
    result.openRequestChanges(card)
    result.setRequestText("Say which frame is shed first when two queues fill at once.")
  of "tests", "all-passing", "all-pending":
    result.selectTab(rtTests)
  of "implementation":
    result.selectTab(rtImplementation)
  of "code", "code-long":
    result.selectTab(rtCode)
  of "code-file-open":
    result.selectTab(rtCode)
    let files = result.files
    if files.len > 1: result.selectFile(files[1].file.path)
  of "code-filtered":
    result.selectTab(rtCode)
    result.setQuery("no-such-file")
  of "milestone":
    let choices = result.milestoneChoices
    if choices.len > 1: result.selectMilestone(choices[1][0])
  of "revert-confirm", "reverting", "revert-failed":
    # A spec card open, its Undo / Revert pressed: `revert-confirm` waits
    # for the reader's answer (nothing sent); the other two were confirmed.
    let card = result.firstCard(stSpec)
    result.toggleCard(card)
    discard result.requestRevert(card)
    if fixture != "revert-confirm": discard result.confirmRevert()
  of "keyboard":
    # The reader's keys, run as a host runs them: `Down` twice puts the
    # keyboard on the second card, `Enter` opens it.
    discard result.runChangesOperation(ChangesFocusNextOperation)
    discard result.runChangesOperation(ChangesFocusNextOperation)
    discard result.runChangesOperation(ChangesToggleOperation)
  of "code-long-keyboard":
    # `Right` three times to Code, `Down` down the files, `Enter` opens the
    # file the keyboard is on: its row is far past the list's foot, so a
    # host keeps it in view by scrolling.
    for _ in 1 .. 3: discard result.runChangesOperation(ChangesNextTabOperation)
    for _ in 1 .. CodeLongKeyboardSteps:
      discard result.runChangesOperation(ChangesFocusNextOperation)
    discard result.runChangesOperation(ChangesToggleOperation)
  else: discard

# ---------------------------------------------------------------------------
# The Inbox panel
# ---------------------------------------------------------------------------

const
  InboxPlaybackFixture* = "playback-inbox-run"
    ## The Inbox's playback story: the `inbox-run` scenario.
  inboxStoryFixtures* = [
    "populated", "long", "fleet", "empty", "emptied", "prev-next", "prev-next-first",
    "prev-next-end", "manager-held", "loading", "error", InboxPlaybackFixture,
    "long-keyboard"]
    ## Every fixture an `agent-harbor-inbox` story may name.
  LongKeyboardAt* = 31
    ## Where `long-keyboard`'s operator is in the forty items before the key
    ## (0-based): far past the list's foot at every size.
  InboxScope* = ThisServerLabel
  FleetInboxScope* = "fleet: every server you can reach"

type
  StoryHostRequests* = ref object
    ## What a story's host was asked to do that has no viewmodel seam (the
    ## login request's `Open sign-in`, a completed sign-in's `Continue` on a
    ## page standing alone): counted, so the story's record shows the press
    ## arrived and nothing else happened.
    openSignIn*: int
    continued*: int

proc inboxStoryContext*(fixture: string; requests: StoryHostRequests = nil): AgentHarborInboxContext =
  ## The scope phrase and the moment the inbox stories are read at (the
  ## invented inbox's own moment, so a capture never moves).
  result = AgentHarborInboxContext(
    scope: (if fixture == "fleet": FleetInboxScope else: InboxScope), nowMs: InboxT0)
  if not requests.isNil:
    result.onOpenSignIn = proc() = inc requests.openSignIn

proc createInboxStoryVM*(fixture: string; playback: AhPlayback = nil): InboxVM =
  ## The viewmodel of the Inbox story named by `fixture`
  ## (`inboxStoryFixtures`). `prev-next` opens in the middle of a walk: the
  ## operator went through the first four items with Next and stepped back
  ## once, so the item on screen is the third (`3 of 5`, Previous enabled,
  ## the explanation strip shown); its page is under the rows.
  ## `prev-next-first` is the walk's first step: Next from no item lands on
  ## the top of the order (`1 of 5`, Previous disabled). `prev-next-end` is
  ## on the last item of the order, reached by stepping back (`5 of 5`): Next
  ## stays enabled while the inbox holds items. `emptied` is the inbox
  ## emptied under a walk: Next put the top item on screen, then every item
  ## was answered on another front-end, so the inbox reads empty with
  ## Previous and Next disabled while the gone item's page stays beside it
  ## (the item on screen stays whatever happens to it). The playback
  ## fixture reads `playback`'s source and replays the operator's presses
  ## through the viewmodel. Raises `ValueError` for an unknown fixture.
  if fixture notin inboxStoryFixtures:
    raise newException(ValueError, "no Agent Harbor Inbox story fixture named " & fixture)
  if fixture == InboxPlaybackFixture:
    if playback.isNil or playback.fixture != fixture:
      raise newException(ValueError, "the Inbox playback story needs its host's playback " &
                         "of " & InboxPlaybackFixture)
    result = newInboxVM(playback.source, clock = playback.source.clock, showPages = true)
    result.load()
    let operator = newInboxPlaybackOperator(playback.source, result)
    onCleanup proc() = operator.stop()
    return
  case fixture
  of "prev-next":
    let source = ScriptedActionSource(inboxFixture("populated"))
    let order = source.inbox.orderOf
    source.setCursor("default", InboxCursor(current: order[3],
                                            visited: @[order[0], order[1], order[2]]))
    result = newInboxVM(source, showPages = true)
    result.load()
    discard result.prev()
  of "prev-next-first":
    result = newInboxVM(inboxFixture("populated"), showPages = true)
    result.load()
    discard result.next()
  of "emptied":
    let source = ScriptedActionSource(inboxFixture("populated"))
    result = newInboxVM(source, showPages = true)
    result.load()
    discard result.next()
    # Answered elsewhere one at a time, each event carrying the order left,
    # as the server sends them.
    var left = source.inbox.orderOf
    while left.len > 0:
      let gone = left[0]
      left.delete(0)
      discard source.sendInbox(InboxEvent(kind: ieResolved, target: gone,
                                          hasOrder: true, order: left))
  of "prev-next-end":
    let source = ScriptedActionSource(inboxFixture("populated"))
    let order = source.inbox.orderOf
    source.setCursor("default", InboxCursor(current: order[0], visited: @[order[^1]]))
    result = newInboxVM(source, showPages = true)
    result.load()
    discard result.prev()
  of "long-keyboard":
    # Far down a walk of the long list (the server's cursor, as `prev-next`
    # sets it), then `[`, run as a host runs it: the item on screen is past
    # the list's foot, so a host keeps it in view by scrolling.
    let source = ScriptedActionSource(inboxFixture("long"))
    let order = source.inbox.orderOf
    source.setCursor("default", InboxCursor(current: order[LongKeyboardAt],
                                            visited: order[0 ..< LongKeyboardAt]))
    result = newInboxVM(source, showPages = true)
    result.load()
    discard runInboxOperation(result, result.page, InboxPreviousOperation)
  else:
    result = newInboxVM(inboxFixture(fixture))
    result.load()

# ---------------------------------------------------------------------------
# An item's page
# ---------------------------------------------------------------------------

const
  inboxItemStoryFixtures* = [
    "question", "question-single", "question-multi", "question-confirmation",
    "question-no-options", "ended-turn", "permission", "sudo", "network",
    "login", "feedback", "feedback-options", "feedback-expired",
    "feedback-invalid", "feedback-options-invalid", "draft", "unfamiliar",
    "answered", "answer-failed", "login-cancelling", "login-completed",
    "login-failed", "login-carry-error-pending", "login-none"]
    ## Every fixture an `agent-harbor-inbox-item` story may name.
  AnswerFailedReason* = "the session ended before the answer arrived"
    ## The scripted failure of `answer-failed` (invented).

proc itemSourceFixture(fixture: string): string =
  case fixture
  of "answered", "answer-failed": "question"
  of "feedback-invalid": "feedback"
  of "feedback-options-invalid": "feedback-options"
  else: fixture

proc inboxItemStoryContext*(fixture: string;
                            requests: StoryHostRequests = nil): AgentHarborInboxItemContext =
  ## The item page story's session label (as the invented inbox names the
  ## item's session; none for a session the inbox does not hold) and the
  ## moment it is read at.
  let (source, _, sessionId) = itemFixture(itemSourceFixture(fixture))
  result = AgentHarborInboxItemContext(nowMs: InboxT0)
  for i in source.inbox.items:
    if i.session.id == sessionId and result.sessionLabel.len == 0:
      result.sessionLabel = i.session.label
  if not requests.isNil:
    result.onOpenSignIn = proc() = inc requests.openSignIn
    result.onContinue = proc() = inc requests.continued

proc createInboxItemStoryVM*(fixture: string): InboxItemVM =
  ## The viewmodel of the item page story named by `fixture`
  ## (`inboxItemStoryFixtures`). `answered` and `answer-failed` show a
  ## question answered through the page, the scripted source confirming or
  ## refusing it; `feedback-invalid` a feedback request submitted empty,
  ## `feedback-options-invalid` an options request submitted with none chosen.
  ## Raises `ValueError` for an unknown fixture.
  if fixture notin inboxItemStoryFixtures:
    raise newException(ValueError, "no Agent Harbor inbox item story fixture named " & fixture)
  let (source, item, sessionId) = itemFixture(itemSourceFixture(fixture))
  if fixture == "answer-failed":
    source.script.setRule(oaAnswerQuestion, failedWith(AnswerFailedReason))
  result = newInboxItemVM(source, item, sessionId)
  result.load()
  case fixture
  of "answered", "answer-failed":
    result.setText("Keep the old order behind a flag for one release.")
    discard result.submit(InboxT0)
  of "feedback-invalid", "feedback-options-invalid":
    discard result.submit(InboxT0)
  else: discard
