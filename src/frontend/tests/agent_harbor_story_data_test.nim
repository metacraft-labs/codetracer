## agent_harbor_story_data_test.nim -- the Agent Harbor stories show coherent
## data.
##
## LANE: `frontend-native-units` (discovered). Compile and run:
##   nim c -r src/frontend/tests/agent_harbor_story_data_test.nim
##
## Every story of the sessions, initiatives, progress and initiative-tab
## families that does not name the captured real set runs over an invented
## working set (`agent_harbor_stories.nim`). Such a story is coherent when:
##
## - no session shows a captured scenario run's title (a scenario run is not
##   work of an invented initiative, so it is never shown under one);
## - no two sessions share a title;
## - a session shown under an invented initiative works on that initiative
##   (its title is one of the initiative's, `syntheticTitlesOf`).
##
## The real-data stories (`real`, `real-plan`, `blocked`, which read the
## captured fleet and plans) are exempt from the last two: they show what was
## captured. They must not show a scenario run either.
##
## Every invented story, and every moment of the full-window layouts
## (`layout_story_data.nim`), also gives each session its own last activity
## line (the line a row or tab shows): no two sessions of one story say the
## same thing. And the error stories of the initiatives, their progress and
## the initiative tab bar name no route: Agent Harbor's API has no
## initiatives list, so they say the server did not answer.
##
## A layout's editor replays a recording made before the clamp, so it shows
## `src/shield.nr` without it (`review_story_data.storyShieldSourceBefore`):
## the replay's stop line is the same statement, the clamp is missing, and the
## line a working clamp session names is the line the clamp replaces.
##
## No mocks: the stories' own data sources, read through the data-source
## seam the views read through.

import std/[sets, strutils, unittest]
import ../stories/[agent_harbor_stories, layout_story_data, review_story_data]
import nim_agents_isonim_viewmodels/agent_harbor/[fixture_source, synthetic_fleet]

const realFixtures = ["real", "real-plan", "blocked"]

proc scenarioTitles(): HashSet[string] =
  for session in newFixtureDataSource().workingSet(wsScenario).sessions:
    result.incl session.prompt

proc sessionsOf(source: AgentHarborDataSource): seq[FleetSession] =
  var sessions: seq[FleetSession]
  source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if answer.ok: sessions = answer.value.sessions
  sessions

proc storyFixtures(): seq[string] =
  ## Every fixture the session-shaped story families name, once.
  var seen = initHashSet[string]()
  for list in [@sessionTabsFixtures, @sessionListFixtures, @initiativesFixtures,
               @progressFixtures, @initiativeTabsFixtures]:
    for fixture in list:
      if fixture notin seen:
        seen.incl fixture
        result.add fixture

suite "the Agent Harbor stories show coherent data":
  let scenarios = scenarioTitles()

  test "the captured scenario runs are known (the check has something to compare)":
    check scenarios.len > 0

  test "no story shows a scenario run; invented stories are coherent":
    var populated = 0
    for fixture in storyFixtures():
      let sessions = sessionsOf(sessionsStorySource(fixture))
      if sessions.len > 0: inc populated
      var seen = initHashSet[string]()
      for session in sessions:
        if session.prompt in scenarios:
          echo "  story fixture ", fixture, " shows the scenario run ", session.prompt
        check session.prompt notin scenarios
        if fixture in realFixtures: continue
        if session.prompt in seen:
          echo "  story fixture ", fixture, " repeats ", session.prompt
        check session.prompt notin seen
        seen.incl session.prompt
        var belongs = false
        for title in syntheticTitlesOf(session.planId):
          if session.prompt == title or session.prompt.startsWith(title & " "):
            belongs = true
        if not belongs:
          echo "  story fixture ", fixture, ": ", session.prompt, " is not work of ", session.planId
        check belongs
    # The populated families were all read (a source that answered nothing
    # would pass every check above).
    check populated >= 6

  test "the fleet story whose filter leaves nothing is coherent too":
    let sessions = sessionsOf(fleetStorySource("filtered-empty"))
    check sessions.len > 0
    for session in sessions:
      check session.prompt notin scenarios
      check session.prompt in syntheticTitlesOf(session.planId)

# ---------------------------------------------------------------------------
# What each session last said, and the messages of the error stories
# ---------------------------------------------------------------------------

import isonim/core/[computation, owner, signals]

proc lastLinesRepeated(sessions: seq[FleetSession]; nowMs: int64): seq[string] =
  ## The last activity lines (the one line a session row or tab shows, the
  ## contract's `lastActivityLine`) that more than one session of a story
  ## says; empty when every session says its own.
  var seen = initHashSet[string]()
  for session in sessions:
    let last = sessionItemOf(session, nowMs, tabStripSessionPolicy()).lastActivityLine
    if last.len == 0: continue
    if last in seen: result.add last
    seen.incl last

proc layoutSessions(moment: string): seq[FleetSession] =
  projectWorkingSet(moment, 1_762_300_000_000'i64).snapshot.sessions

suite "every session of a story says its own last thing":
  # The rule for the invented sets: each session's last line
  # follows from its own title and state (the test it runs, the question only
  # its task raises, the failure it hit), so no two sessions of one story
  # read alike. The captured real-data stories show what was captured and are
  # exempt.

  test "the session-shaped stories over invented sets":
    var populated = 0
    for fixture in storyFixtures():
      if fixture in realFixtures: continue
      let sessions = sessionsOf(sessionsStorySource(fixture))
      if sessions.len > 1: inc populated
      let repeated = lastLinesRepeated(sessions, 1_762_300_000_000'i64)
      for line in repeated: echo "  story fixture ", fixture, " repeats ", line
      check repeated.len == 0
    check populated >= 6

  test "the fleet story whose filter leaves nothing":
    check lastLinesRepeated(sessionsOf(fleetStorySource("filtered-empty")),
                            1_762_300_000_000'i64).len == 0

  test "every full-window layout's project":
    check LayoutScenarios.len == 14
    for moment in LayoutScenarios:
      let sessions = layoutSessions(moment)
      check sessions.len >= 10
      let repeated = lastLinesRepeated(sessions, 1_762_300_000_000'i64)
      for line in repeated: echo "  layout ", moment, " repeats ", line
      check repeated.len == 0

  test "a layout's project is coherent: titles once, initiatives known":
    for moment in LayoutScenarios:
      let (snapshot, plans) = projectWorkingSet(moment, 1_762_300_000_000'i64)
      var titles = initHashSet[string]()
      var planIds = initHashSet[string]()
      for plan in plans:
        planIds.incl plan.id
        check plan.executiveSummary.len > 80
        check "milestones done" notin plan.executiveSummary
      for session in snapshot.sessions:
        check session.prompt notin titles
        titles.incl session.prompt
        check session.prompt notin scenarioTitles()
        if session.planId.len > 0: check session.planId in planIds
      # The session each moment's Agent Activity pane shows is one of them.
      var shown = false
      for session in snapshot.sessions:
        if session.id == projectConversation(moment).sessionId: shown = true
      check shown

suite "an error story names no route Agent Harbor does not have":
  # Agent Harbor's API has no initiatives list (only the per-task
  # milestones), so the initiatives, progress and initiative-tab error
  # stories say the server did not answer, and name no invented route.

  template checkGeneric(message: string) =
    check message.len > 0
    check message.startsWith("The Agent Harbor server did not answer")
    check "/api/" notin message
    check "GET " notin message

  test "the initiatives, progress and initiative tab bar error stories":
    # Read inside a reactive root, checked outside it: a `check` in a
    # closure would not fail this test.
    var messages: seq[string]
    createRoot proc(disposeRoot: proc()) =
      let initiatives = createInitiativesStoryVM("error")
      let progress = createProgressStoryVM("error")
      let tabs = createInitiativeTabsStoryVM("error")
      messages = @[initiatives.error.val, progress.error.val, tabs.error.val]
      initiatives.dispose()
      progress.dispose()
      tabs.dispose()
      disposeRoot()
    check messages.len == 3
    for message in messages: checkGeneric(message)

  test "the sessions error story names the sessions route it read":
    # The control: a read Agent Harbor does have is named.
    var error = ""
    sessionsStorySource("error").loadFleet proc(answer: DataResult[FleetSnapshot]) =
      if not answer.ok: error = answer.error
    check error.startsWith("GET /api/v1/sessions failed")

proc shieldLinesNamed(text: string): seq[int] =
  ## Every `src/shield.nr:<line>` a text names.
  const marker = "src/shield.nr:"
  var at = text.find(marker)
  while at >= 0:
    var i = at + marker.len
    var digits = ""
    while i < text.len and text[i] in Digits:
      digits.add text[i]
      inc i
    if digits.len > 0: result.add parseInt(digits)
    at = text.find(marker, i)

suite "a layout's editor shows the revision its recording was made of":
  const reviewedSource = staticRead("../../../test-programs/noir_space_ship/src/shield.nr")

  test "the replay's revision has no clamp; the stop line is the same statement":
    let before = storyShieldSourceBefore().splitLines
    let reviewed = reviewedSource.splitLines
    # Stopped at src/shield.nr:7 in both (`storybook_components.StoryStopLine`).
    check before[6] == reviewed[6]
    check before[6].strip == "remaining_shield -= damage;"
    # The change is +4 -1 (the Deep Review's hunk), so three lines shorter.
    check reviewed.len - before.len == 3
    var clamped = false
    for line in before:
      if line.strip.startsWith("if(damage as u32 > remaining_shield as u32)"): clamped = true
    check not clamped
    check "    damage" in before

  test "a working clamp session names the line the clamp replaces":
    let before = storyShieldSourceBefore().splitLines
    var named = 0
    for moment in LayoutScenarios:
      for message in projectConversation(moment).messages:
        for line in shieldLinesNamed(message.content):
          check line in 1 .. before.len
          if line in 1 .. before.len:
            check before[line - 1].strip == "damage"
          inc named
    # The check has something to check: the clamp session's working message.
    check named > 0
