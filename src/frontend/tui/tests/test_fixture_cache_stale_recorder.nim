## test_fixture_cache_stale_recorder.nim — a cached recording made by a
## different recorder is KEPT, and named, when nothing here can re-record it.
##
## ## The defect
##
## `fixtures/fixture_provider.resolveFixture` compares a cache entry's stamped
## recorder identity with the recorder installed now, and a mismatch is a
## decision to re-record. It used to carry that decision out with
## `removeDir(cached)` BEFORE asking whether `ct` was built. On a host with no
## `ct`, the result was a MISSING-PREREQ skip and an empty cache: a recording
## every later suite in the lane could have used was destroyed, and nothing
## could replace it (codetracer-pm `issues/2026-10-21-tui-fixture-provider-
## deletes-a-stale-fixture-it-cannot-re-record.md`). The skip then said
## "nothing usable is cached at …", which was false.
##
## The rule, `codetracer-pm spec/Testing/Testing-Guidelines.md` ("A cached
## recording is adopted only if this build can read it", the stale-recorder
## paragraph): with no `ct` or no recorder, such an entry is a counted
## MISSING-PREREQ skip naming the cached path and both identities, and the
## entry is left in place. It is removed only once a re-recording is certain
## to be attempted.
##
## ## What is real and what is staged, and why
##
## The container is a REAL recording committed to this repository
## (`src/tests/gui/tests/request-panel/fixtures/python_flask/serve.ct`, a
## Python-recorder container at version 5, which this build reads), resolved
## through the production `resolveFixture` against the real
## `test-logs/tui-fixtures/` cache root, under this file's own fixture name
## (`stale_recorder_probe`) so the real corpus's entries are never touched.
## The recorder identity is computed by the provider's own identity program,
## run by a real python3. Two things are staged, and each is the only way to
## put this host into the state the defect needs:
##
##   * **`ct` is absent through `resolveFixture`'s `locateCt` parameter.**
##     `findCtBinary` falls back to paths inside the checkout
##     (`src/build-debug/bin/ct`, beside the resolved `replay-server`), so no
##     environment variable hides a built `ct`; on a developer host with `ct`
##     built, the case would otherwise attempt a recording and never reach the
##     branch under test. Only the LOOKUP is replaced — the parameter's
##     default is `findCtBinary`, the one every production caller uses.
##   * **The installed recorder is a stand-in `codetracer_python_recorder`
##     package** (one `__init__.py`), put first on `PYTHONPATH` for the real
##     python3 that `CODETRACER_PYTHON_INTERPRETER` names. The defect needs the
##     installed identity to be KNOWN and DIFFERENT from the stamp — an
##     unknown one means "keep" and never reaches the deletion — and the
##     provider defines identity as the content hash of whatever package that
##     interpreter imports. A stand-in gives a known identity on every host,
##     whether or not the real recorder is installed, and it is never asked
##     to record anything: with no `ct`, resolution stops before recording.

import std/[os, strutils, unittest]

import fixtures/fixture_provider

const
  ProbeName = "stale_recorder_probe"
  ReadableSource = "src/tests/gui/tests/request-panel/fixtures/python_flask/serve.ct"
  StampFile = ".ctui-fixture-complete"
    ## `fixture_provider.FixtureStampFile`, which the provider keeps private.
    ## A provider that renamed it would make every case below a plain miss,
    ## and the "entry is kept" checks would then fail rather than pass.
  StampedElsewhere = "py-recorded-elsewhere"
  StagedVars = ["CODETRACER_PYTHON_INTERPRETER", "PYTHONPATH"]

proc probeSpec(): FixtureSpec =
  result = fixtureSpec("calc")
  result.name = ProbeName

proc cachedDir(): string =
  let root = repoRoot()
  fixtureCacheRoot(root) / (ProbeName & "-" & fixtureKey(root, probeSpec()))

proc stageCache(stampLines: string): string =
  ## A complete, stamped, READABLE cache entry under the probe's key.
  result = cachedDir()
  removeDir(result)
  createDir(result)
  let bytes = readFile(repoRoot() / ReadableSource)
  doAssert bytes.len > 16 and bytes[5] == char(5),
    ReadableSource & " is no longer a version 5 container; pick another " &
    "committed recording this build reads"
  writeFile(result / "trace.ct", bytes)
  writeFile(result / StampFile, ProbeName & "\n" & stampLines)
  doAssert cachedRecordingRefusal(result) == "",
    "the staged container must be one this build reads, or the case tests " &
    "the readability gate instead of the recorder-identity one"

proc noCt(): string {.nimcall.} = ""

template withStandInRecorder(body: untyped) =
  ## Run `body` with a known installed-recorder identity: a real python3 that
  ## imports a one-file `codetracer_python_recorder`.
  var saved: seq[(string, bool, string)]
  for name in StagedVars:
    saved.add((name, existsEnv(name), getEnv(name)))
  let pkgRoot = getTempDir() / ("ct-" & ProbeName & "-" & $getCurrentProcessId())
  try:
    let python = findExe("python3")
    doAssert python.len > 0, "this suite needs a python3 on PATH"
    createDir(pkgRoot / "codetracer_python_recorder")
    writeFile(pkgRoot / "codetracer_python_recorder" / "__init__.py",
              "# stand-in for " & ProbeName & "\n")
    putEnv("CODETRACER_PYTHON_INTERPRETER", python)
    putEnv("PYTHONPATH", pkgRoot)
    body
  finally:
    for (name, had, value) in saved:
      if had: putEnv(name, value) else: delEnv(name)
    removeDir(pkgRoot)

proc installedIdentity(): string =
  result = recorderIdentity(probeSpec().probe)
  doAssert result.len > 0 and result != StampedElsewhere,
    "precondition: the installed recorder identity must be known and differ " &
    "from the stamp, or this case cannot reach the stale-recorder branch " &
    "(got '" & result & "')"

suite "fixture cache: a stale-recorder entry is kept when it cannot be re-recorded":

  teardown:
    removeDir(cachedDir())

  test "a different stamped recorder and no `ct`: a named skip, and the entry survives":
    let cached = stageCache("recorder-identity=" & StampedElsewhere & "\n")
    withStandInRecorder:
      let current = installedIdentity()
      let res = resolveFixture(probeSpec(), locateCt = noCt)
      check res.outcome == foMissingPrereq
      check res.tracePath == ""
      # Before the fix: the directory was removed here, before `ct` was asked
      # for, and every later suite found an empty cache.
      check dirExists(cached)
      check fileExists(cached / "trace.ct")
      check fileExists(cached / StampFile)
      # The skip names the staleness, not "nothing usable is cached".
      check cached in res.detail
      check StampedElsewhere in res.detail
      check current in res.detail
      check "nothing usable is cached" notin res.detail
      check "`ct` is not built" in res.detail
      let line = missingPrereqMessage(res.spec, res.detail)
      check line.startsWith(MissingPrereqSkipPrefix & " " & ProbeName)

  test "a stamp with no recorder identity and no `ct`: a named skip, and the entry survives":
    # A stamp written before identities were recorded. The provider re-records
    # it when it can (the asymmetry documented at step 2) — and here it cannot.
    let cached = stageCache("")
    withStandInRecorder:
      let current = installedIdentity()
      let res = resolveFixture(probeSpec(), locateCt = noCt)
      check res.outcome == foMissingPrereq
      check fileExists(cached / "trace.ct")
      check fileExists(cached / StampFile)
      check cached in res.detail
      check "its stamp does not identify" in res.detail
      check current in res.detail

  test "control: a matching stamped recorder is adopted with no `ct`":
    withStandInRecorder:
      let current = installedIdentity()
      let cached = stageCache("recorder-identity=" & current & "\n")
      let res = resolveFixture(probeSpec(), locateCt = noCt)
      check res.outcome == foRecorded
      check res.tracePath == cached
