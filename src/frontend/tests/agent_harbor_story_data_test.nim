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
## No mocks: the stories' own data sources, read through the data-source
## seam the views read through.

import std/[sets, strutils, unittest]
import ../stories/agent_harbor_stories
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
