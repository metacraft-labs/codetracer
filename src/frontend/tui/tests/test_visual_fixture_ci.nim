## The Visual Replay suites' prerequisite check fails in CI instead of
## skipping (`fixtures/visual_fixture.visualFixtureSkip`).
##
## Both PLAT-59 terminal suites skipped every case in CI for want of the
## visual replay player ("OK (1 tests, 1 SKIPPED)", shards 2/8 and 8/8 of
## agents run 45471393785), and a skip reads as a pass. Outside CI a missing
## player is still a named skip; under `CI=true` it raises
## `MissingPrereqInCi`, so a job that runs these suites without the player
## turns red. This suite needs no player: it hides any there is.

import std/[os, strutils, unittest]

import ./fixtures/fixture_provider
import ./fixtures/visual_fixture

proc hideThePlayer() =
  ## No `CODETRACER_CT_GFX_PLAYER_CMD` and no `ct_gfx_player` on PATH: the
  ## player cannot be found, whatever this host has installed.
  putEnv("CODETRACER_CT_GFX_PLAYER_CMD", "/nonexistent/ct_gfx_player")
  putEnv("PATH", "/nonexistent")

suite "the visual fixture's prerequisites in and out of CI":
  test "outside CI a missing player is a named skip":
    hideThePlayer()
    delEnv("CI")
    let skip = visualFixtureSkip()
    check skip.startsWith(MissingPrereqSkipPrefix)

  test "under CI=true a missing player fails, naming what is missing":
    hideThePlayer()
    putEnv("CI", "true")
    var raised = ""
    try:
      discard visualFixtureSkip()
    except MissingPrereqInCi as e:
      raised = e.msg
    check raised.len > 0
    check MissingPrereqSkipPrefix in raised

  test "the scenario stage's check names what is missing in CI too, without raising":
    hideThePlayer()
    putEnv("CI", "true")
    check visualFixtureMissing().startsWith(MissingPrereqSkipPrefix)
