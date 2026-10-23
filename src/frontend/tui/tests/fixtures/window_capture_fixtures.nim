## window_capture_fixtures.nim — the recordings `ci/test/gpui-window-captures.sh`
## opens, as specs, and the program that records them.
##
## The capture lane runs "from nothing but a checkout": every recording a
## driver opens is recorded by this provider when absent. Most of them are not
## in `DeclaredFixtures` — `call_pages`, `wide_lines` and `multi_root` are each
## read by a handful of suites that spell their own `FixtureSpec`, and adding
## them to the shared corpus would put them under `test_fixture_corpus.nim`'s
## navigability count. So the lane spells them here, once, the way those
## suites do. The lane used to write `resolveFixture("call_pages")`, the
## by-name overload, which raises `KeyError` for any name outside the corpus:
## it passed only on a host whose `test-logs/` already held a recording a
## terminal suite had made (codetracer-pm
## `issues/2026-10-21-gpui-window-captures-cannot-record-the-call-pages-fixture.md`).
##
## The cache key is the fixture's name and its program's content
## (`fixtureKey`), so a recording made here and one made by a suite that spells
## the same name and program are the same directory.
##
## Usage (from the repository root, inside the dev shell):
##
##   nim c -r --path:src/frontend/tui/tests \
##     src/frontend/tui/tests/fixtures/window_capture_fixtures.nim plat47 m71
##
## Records every fixture the named captures open (every capture's when none is
## named, as the script's default run does) and prints one trace path per
## line. Exits 1 naming the fixture when one cannot be recorded, and 2 on an
## unknown capture name.

import std/strutils

import fixture_provider

const WindowCaptures* = ["plat45", "plat47", "plat48", "plat68", "plat69",
                         "plat70a", "m71"]
  ## Every capture `gpui-window-captures.sh` accepts, in its default order.

proc pythonScript(name, program: string): FixtureSpec =
  FixtureSpec(
    name: name, program: program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: "")

proc windowCaptureFixtures*(capture: string): seq[FixtureSpec] =
  ## The recordings `capture` needs. `calc` is first for every capture: the
  ## lane's no-display refusal step opens it whichever captures run.
  ## Raises `KeyError` on a name outside `WindowCaptures`.
  if capture notin WindowCaptures:
    raise newException(KeyError, "unknown capture '" & capture & "' (" &
      WindowCaptures.join(", ") & ")")
  result.add(fixtureSpec("calc"))
  case capture
  of "plat47":
    # PLAT-47's driver scrolls a call trace longer than any section.
    result.add(pythonScript("call_pages", "test-programs/call_pages/main.py"))
  of "plat70a":
    # PLAT-70 Part A scrolls a line wider than any pane.
    result.add(pythonScript("wide_lines", "test-programs/wide_lines/main.py"))
  of "m71":
    # M71 overflows the State, Files and VCS panes of a two-root program.
    result.add(pythonScript("multi_root", "test-programs/multi_root/app/main.py"))
  else:
    discard

proc windowCaptureFixtures*(captures: openArray[string]): seq[FixtureSpec] =
  ## The union over `captures`, each fixture once, in first-needed order.
  for capture in captures:
    for spec in windowCaptureFixtures(capture):
      var seen = false
      for have in result:
        if have.name == spec.name:
          seen = true
          break
      if not seen:
        result.add(spec)

when isMainModule:
  import std/cmdline

  var captures = commandLineParams()
  if captures.len == 0:
    captures = @WindowCaptures
  var specs: seq[FixtureSpec]
  try:
    specs = windowCaptureFixtures(captures)
  except KeyError as e:
    quit(e.msg, 2)
  for spec in specs:
    let r = resolveFixture(spec)
    if r.outcome != foRecorded:
      quit("could not record the " & spec.name & " fixture: " &
           missingPrereqMessage(r.spec, r.detail), 1)
    echo r.tracePath
