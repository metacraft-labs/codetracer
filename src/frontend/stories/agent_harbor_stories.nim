## The Agent Harbor stories' viewmodel constructors.
##
## A story of the `agent-harbor-fleet` surface (declared in
## `codetracer_stories.nim`) is a `FleetSnapshotVM` built by
## `createFleetStoryVM` over the story's fixture, and the production view
## `isonim_agent_harbor_fleet_view` rendered over it. StoryBook and the IsoNim
## Editor instance both reach this through `mountCodeTracerStory`
## (`storybook_components.nim`), so the two surfaces build the same viewmodel
## for the same story.
##
## The viewmodels and their data-source seam come from
## nim-agents-isonim-viewmodels; this module only says which source and which
## view state each fixture names.

import nim_agents_isonim_viewmodels/agent_harbor/[data_source, fixture_source,
                                                   fleet_vm, records]

const fleetFixtures* = ["snapshot", "needs-input", "failed", "selected",
                        "loading", "error", "empty"]
  ## Every fixture an `agent-harbor-fleet` story may name.

proc fleetStorySource*(fixture: string): AgentHarborDataSource =
  ## The data source a fleet story reads. Every populated state is the
  ## captured fleet snapshot; the states no capture shows come from the
  ## data-source seam's state sources, so the view is exercised through the
  ## same seam a live source will use.
  case fixture
  of "loading":
    newPendingDataSource("waiting for the Agent Harbor server")
  of "error":
    newFailingDataSource(
      "GET /api/v1/sessions failed: connection refused (the server is not " &
      "running, or its address is wrong)", "unreachable server")
  of "empty":
    newSnapshotDataSource(FleetSnapshot(sourceLabel: "empty server"),
                          "empty server")
  else:
    newFixtureDataSource()

proc createFleetStoryVM*(fixture: string): FleetSnapshotVM =
  ## The viewmodel of the fleet story named by `fixture`: `snapshot` (the
  ## captured fleet), `needs-input` and `failed` (the snapshot under that
  ## filter), `selected` (its first captured session selected), `loading`,
  ## `error`, `empty`. Call inside a reactive root; the caller disposes it.
  ## An unknown fixture raises rather than showing some other state under
  ## the story's name.
  if fixture notin fleetFixtures:
    raise newException(ValueError, "no Agent Harbor fleet story fixture named " & fixture)
  let source = fleetStorySource(fixture)
  result = newFleetSnapshotVM(source)
  result.load()
  case fixture
  of "needs-input": result.setFilter(ffNeedsInput)
  of "failed": result.setFilter(ffFailed)
  of "selected":
    if source of FixtureDataSource:
      let rows = result.rows
      if rows.len > 0: result.select(rows[0].id)
  else: discard
