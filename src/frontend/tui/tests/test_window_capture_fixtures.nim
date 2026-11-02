## test_window_capture_fixtures.nim — every recording the GPUI window capture
## lane opens can be recorded from a bare checkout.
##
## `ci/test/gpui-window-captures.sh` records the recordings its drivers open
## through `fixtures/window_capture_fixtures.nim`. That lane runs on a
## compositor and only in its own CI job, so a capture whose recording cannot
## be produced was found only by someone running it on a host without the
## recording cached: `plat47` asked for `call_pages` by name, which is outside
## the provider's declared corpus, and stopped with `KeyError` before any
## capture (codetracer-pm
## `issues/2026-10-21-gpui-window-captures-cannot-record-the-call-pages-fixture.md`).
## This suite asserts the same mapping in the Tier-1 lane, and RECORDS each
## recording through the real provider and a real `ct record` — no mocks — so
## a spec naming a program that is not in the tree, or a recording that does
## not finish, is red here and not on the compositor.
##
## A recorder that is absent is a counted `MISSING-PREREQ` skip, as in every
## suite over the provider; the last case fails a run in which every fixture
## skipped.

import std/[os, strutils, unittest]

import fixtures/fixture_provider
import fixtures/window_capture_fixtures

proc names(specs: seq[FixtureSpec]): seq[string] =
  for spec in specs:
    result.add(spec.name)

var examined, verified, skipped = 0

suite "the GPUI window capture lane's recordings":

  test "every capture's recordings resolve to specs, with programs in the tree":
    let root = repoRoot()
    for capture in WindowCaptures:
      let specs = windowCaptureFixtures(capture)
      check specs.len >= 1
      check specs[0].name == "calc"
      for spec in specs:
        check spec.blockedOn.len == 0
        # Raises when the program is not in the tree.
        check fixtureKey(root, spec).len > 0

  test "each capture opens the recording its driver reads":
    check windowCaptureFixtures("plat47").names == @["calc", "call_pages"]
    check windowCaptureFixtures("plat70a").names == @["calc", "wide_lines"]
    check windowCaptureFixtures("plat70b").names == @["calc", "wide_lines"]
    check windowCaptureFixtures("m71").names == @["calc", "multi_root"]
    for capture in ["plat45", "plat48", "plat68", "plat69"]:
      check windowCaptureFixtures(capture).names == @["calc"]

  test "the lane's default run records each recording once":
    check windowCaptureFixtures(WindowCaptures).names ==
      @["calc", "call_pages", "wide_lines", "multi_root"]

  test "an unknown capture is refused by name":
    expect KeyError:
      discard windowCaptureFixtures("plat99")
    try:
      discard windowCaptureFixtures(["plat47", "plat99"])
      fail()
    except KeyError as e:
      check "plat99" in e.msg

  for spec in windowCaptureFixtures(WindowCaptures):
    test "records " & spec.name & " from its spec":
      inc examined
      let r = resolveFixture(spec)
      if r.outcome == foMissingPrereq:
        inc skipped
        let message = missingPrereqMessage(r.spec, r.detail)
        echo "  ", message
        check message.startsWith(MissingPrereqSkipPrefix)
        skip()
      else:
        inc verified
        check r.spec.name == spec.name
        check dirExists(r.tracePath)
        check isUsableTraceDir(r.tracePath)
        check r.tracePath.lastPathPart.startsWith(spec.name & "-")

  test "every recording was examined, and at least one was recorded":
    check examined == windowCaptureFixtures(WindowCaptures).len
    check examined == verified + skipped
    check verified >= 1
