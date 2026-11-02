## test_fixture_cache_readability.nim — a cached recording this build cannot
## read is a cache MISS, never a fixture.
##
## ## The defect
##
## `fixtures/fixture_provider.resolveFixture` adopted a cache hit on its key
## (schema, name, program sources), its completion stamp and its recorder
## identity — and "no recorder here" counts as no opinion, so keep. None of
## that asks whether the reader built from this checkout can OPEN the
## container. A shared cache holding CTFS container version 4 recordings,
## copied into a worktree whose `replay-server` reads versions 5 and 6, was
## therefore adopted, and every suite that resolved a fixture died at launch
## with `this recording cannot be opened by this build`, naming the suite
## rather than the stale cache (codetracer-pm
## `issues/2026-10-11-tui-fixture-cache-adopts-a-container-the-reader-refuses.md`).
##
## The rule, `codetracer-pm spec/Testing/Testing-Guidelines.md` ("A cached
## recording is adopted only if this build can read it"): such a recording is
## re-recorded when a recorder is here, a counted MISSING-PREREQ skip naming
## the refusal when none is, and in neither case a fixture.
##
## ## What is real and what is staged
##
## No mocks. The containers are REAL recordings committed to this repository
## (`src/tests/gui/tests/request-panel/fixtures/python_flask/serve.ct`, a
## Python-recorder container at version 5), read by the real
## `ctfs_sources.readCtfsMetaDat`, and resolved through the production
## `resolveFixture` against the real `test-logs/tui-fixtures/` cache root.
##
## The version-4 container is that same recording with byte 5 — the CTFS
## container version (`ctfs-container.md` §1) — set to 4. That is a faithful
## stand-in for a recording from an older writer AS THE READER SEES IT: the
## reader refuses on that byte before it reads anything else, which is the
## refusal the issue quotes. The fixture spec is this file's own
## (`cache_readability_probe`), so the real corpus's cache entries are never
## touched.
##
## "No recorder here" is staged by pointing `CODETRACER_PYTHON_INTERPRETER` at
## a path that does not exist, the first variable `ct record` and the
## provider's probe consult, so the result does not depend on what this host
## has installed.

import std/[os, strutils, unittest]

import fixtures/fixture_provider

const
  ProbeName = "cache_readability_probe"
  ReadableSource = "src/tests/gui/tests/request-panel/fixtures/python_flask/serve.ct"
  InterpreterVar = "CODETRACER_PYTHON_INTERPRETER"
  StampFile = ".ctui-fixture-complete"
    ## `fixture_provider.FixtureStampFile`. Spelled out because the provider
    ## keeps it private; a provider that renamed it would make every case
    ## below a cache miss, which the control case catches.

proc probeSpec(): FixtureSpec =
  ## A Python-recorder fixture over a program that is in the tree, under a name
  ## no other suite uses.
  result = fixtureSpec("calc")
  result.name = ProbeName

proc cachedDir(): string =
  let root = repoRoot()
  fixtureCacheRoot(root) / (ProbeName & "-" & fixtureKey(root, probeSpec()))

proc stageCache(version: byte; stampIdentity = "py-recorded-elsewhere"): string =
  ## Put a complete, stamped cache entry under the probe's key, holding the
  ## committed recording with its container version byte set to `version`.
  result = cachedDir()
  removeDir(result)
  createDir(result)
  var bytes = readFile(repoRoot() / ReadableSource)
  doAssert bytes.len > 16 and bytes[5] == char(5),
    ReadableSource & " is no longer a version 5 container; pick another " &
    "committed recording this build reads"
  bytes[5] = char(version)
  writeFile(result / "trace.ct", bytes)
  writeFile(result / StampFile,
            ProbeName & "\nrecorder-identity=" & stampIdentity & "\n")

template withoutRecorder(body: untyped) =
  let saved = getEnv(InterpreterVar)
  let hadIt = existsEnv(InterpreterVar)
  putEnv(InterpreterVar, getTempDir() / "no-such-python-for-" & ProbeName)
  try:
    body
  finally:
    if hadIt: putEnv(InterpreterVar, saved) else: delEnv(InterpreterVar)

suite "fixture cache: adopted only if this build can read it":

  teardown:
    removeDir(cachedDir())

  test "the reader's refusal is reported for an older container, and nothing for a readable one":
    let readable = stageCache(5)
    check cachedRecordingRefusal(readable) == ""
    let stale = stageCache(4)
    let refusal = cachedRecordingRefusal(stale)
    check "CTFS container version 4 is not readable" in refusal
    check "5 and 6" in refusal
    check (stale / "trace.ct") in refusal

  test "a shape the probe does not read has no refusal":
    let dir = cachedDir()
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "trace.bin", "not a CTFS container")
    check cachedRecordingRefusal(dir) == ""

  test "control: a readable warm cache is adopted with no recorder installed":
    let cached = stageCache(5)
    withoutRecorder:
      let res = resolveFixture(probeSpec())
      check res.outcome == foRecorded
      check res.tracePath == cached

  test "an unreadable cached container is a counted skip, not a fixture, when nothing can re-record it":
    let cached = stageCache(4)
    withoutRecorder:
      let res = resolveFixture(probeSpec())
      # Before the fix: foRecorded, tracePath == cached — handed to the suite,
      # which then died at `launch` on the engine's refusal.
      check res.outcome == foMissingPrereq
      check res.tracePath == ""
      check "CTFS container version 4 is not readable" in res.detail
      check cached in res.detail
      let line = missingPrereqMessage(res.spec, res.detail)
      check line.startsWith(MissingPrereqSkipPrefix & " " & ProbeName)
      # A skip discards nothing: the entry is replaced only by a recording.
      check fileExists(cached / "trace.ct")

  test "an unreadable cached container made by THIS recorder is re-recorded":
    # The other half: the stamp matches the installed recorder, so the
    # recorder-identity check alone would adopt it. Needs `ct` and the Python
    # recorder; without them the case is a named skip, never a pass.
    let identity = recorderIdentity(probeSpec().probe)
    if identity.len == 0 or findCtBinary().len == 0:
      echo "  ", MissingPrereqSkipPrefix, " ", ProbeName,
        " (codetracer-python-recorder) — re-recording needs `ct` and an ",
        "importable codetracer_python_recorder"
      skip()
    else:
      let cached = stageCache(4, stampIdentity = identity)
      let res = resolveFixture(probeSpec())
      check res.outcome == foRecorded
      check res.tracePath == cached
      check cachedRecordingRefusal(res.tracePath) == ""
