## M-REC-2 acceptance tests for the local trace index.
##
## Covers the three deliverables in §M-REC-2 of
## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.status.org``:
##
## 1. Schema integrity — fresh DB has the new ``recordings``,
##    ``record_pid_recording_map``, ``recent_folders`` tables (with the
##    right columns) and the two indexes on ``recordings``.
## 2. Old-schema detection + recreation — a hand-built pre-M-REC-2 DB
##    (``traces`` + ``trace_values``) is detected, archived to
##    ``.pre-m-rec-2.bak``, and replaced by a fresh new-schema DB.  A
##    warning is emitted on stderr.
## 3. ``newID`` returns canonical UUIDv7 strings, two calls produce
##    different ids that sort lex-ascending.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/trace_index_test \
##       src/common/trace_index_test.nim
##
## Each test spawns ``trace_index_test_helper`` as a fresh subprocess
## with ``XDG_DATA_HOME`` (and friends) pre-pointed at a tmpdir.  This
## is necessary because ``trace_index`` resolves ``paths.app`` once at
## module-load time via ``let defaultPath = app`` — the test process
## itself cannot relocate the DB after that resolution has happened.

import std/[os, osproc, streams, strtabs, strutils, unittest, tempfiles]

# ---------------------------------------------------------------------------
# Helper subprocess builder
# ---------------------------------------------------------------------------

let helperSource = currentSourcePath.parentDir / "trace_index_test_helper.nim"

# Compile the helper once; cache the binary path so the three test
# cases share the build cost.
let helperCache = getTempDir() / "ct-trace-index-helper-cache"

proc compileHelper(): string =
  ## Compile the subprocess helper and return the path to the binary.
  ## Returns "" if compilation failed (the caller fails the test).
  removeDir(helperCache)
  createDir(helperCache)
  let bin = helperCache / "trace_index_test_helper"
  ## ``trace_index`` imports ``std/httpclient`` for online-sharing
  ## helpers (``Uploader``) but the test never exercises HTTPS, so we
  ## skip ``-d:ssl`` here.  This keeps the test runnable in dev-shells
  ## without an OpenSSL toolchain.
  let cmd = "nim c --hints:off --warnings:off --mm:refc " &
            "--nimcache:" & quoteShell(helperCache) & " " &
            "--out:" & quoteShell(bin) & " " &
            quoteShell(helperSource)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "trace_index_test: helper compile FAILED:"
    echo output
    return ""
  return bin

let helperBin = compileHelper()

proc makeTmpHome(name: string): string =
  ## Create a fresh tmpdir for a single test run.  Caller cleans up.
  createTempDir("ct-trace-index-test-" & name & "-", "")

proc runScenario(bin, scenario, homeDir: string):
    tuple[ok: bool, stdoutStr: string, stderrStr: string] =
  ## Run the helper for ``scenario`` with the env scrubbed to ``homeDir``.
  ## Returns (success, stdout, stderr).  Each scenario gets its own
  ## tmpdir so the cases are independent.
  ##
  ## In Nix dev-shell, ``libsqlite3.so`` lives on ``CT_LD_LIBRARY_PATH``
  ## (set by ``nix/shells/main.nix``) rather than the default
  ## ``LD_LIBRARY_PATH``.  We splice the codetracer-specific path onto
  ## the dynamic-loader path so the dlopen in ``db_sqlite`` finds the
  ## shared object regardless of how the test was launched.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["XDG_DATA_HOME"] = homeDir
  env["TMPDIR"] = homeDir
  env["HOME"] = homeDir
  let ctLd = getEnv("CT_LD_LIBRARY_PATH")
  if ctLd.len > 0:
    let existing = getEnv("LD_LIBRARY_PATH")
    env["LD_LIBRARY_PATH"] =
      if existing.len > 0: ctLd & ":" & existing
      else: ctLd

  let p = startProcess(
    bin,
    args = @[scenario],
    env = env,
    options = {})
  defer: p.close()
  let stdoutStr = p.outputStream.readAll()
  let stderrStr = p.errorStream.readAll()
  let code = p.waitForExit()
  (code == 0, stdoutStr, stderrStr)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

proc runHelperScenario(scenario, name: string):
    tuple[ok: bool, stdoutStr: string, stderrStr: string] =
  ## Run ``helperBin`` for ``scenario`` in a fresh tmpdir.  Cleans up
  ## the tmpdir before returning.  Caller passes ``helperBin`` length
  ## check at the test level so we don't crash on a missing binary.
  let home = makeTmpHome(name)
  defer: removeDir(home)
  runScenario(helperBin, scenario, home)

suite "M-REC-2 — trace_index schema and UUIDv7 newID":

  test "helper compiles":
    check helperBin.len > 0

  test "fresh DB has the new schema (recordings + indexes + helper tables)":
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario("schema", "schema")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "old-schema DB is detected, archived to .bak, and recreated fresh":
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario("old-schema", "oldschema")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr
      # The first-launch warning is printed on stderr.  Match a stable
      # substring so the test does not pin to the full message wording.
      check "old-schema trace_index.db detected" in stderrStr
      check ".pre-m-rec-2.bak" in stderrStr

  test "newID returns canonical UUIDv7s that sort lex-ascending":
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario("newid-uuidv7", "newid")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr
