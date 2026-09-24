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
## It has since grown the short-recording-id-prefix resolver cases
## (M-REC-6) and the ``recent_folders`` path-normalization case (#575).
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

proc readToEof(s: Stream): string =
  ## Everything the helper wrote, up to end of file.  Not `streams.readAll`,
  ## which stops at the first SHORT read: a Windows pipe returns each of the
  ## child's writes separately, so `readAll` kept only its first line
  ## (LRS-6's review, 2026-09-24; the same defect is fixed in
  ## `src/ct/utilities/target_recognition.nim`).  POSIX pipe streams fill
  ## the buffer first, which is why no Linux run saw it.
  result = ""
  var buffer {.noinit.}: array[4096, char]
  while true:
    let n = s.readData(addr buffer[0], buffer.len)
    if n <= 0:
      break
    let start = result.len
    result.setLen(start + n)
    copyMem(addr result[start], addr buffer[0], n)

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
  # Case-INsensitive on Windows, where the OS treats `UserProfile` and
  # `USERPROFILE` as one variable: overriding it must replace the inherited
  # entry, not add a second one beside it.
  var env = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["XDG_DATA_HOME"] = homeDir
  env["TMPDIR"] = homeDir
  env["HOME"] = homeDir
  # WINDOWS: Nim's `getHomeDir` -- which `paths.codetracerTraceDir`, and so
  # the trace index, is derived from -- reads `USERPROFILE`, not `HOME`.
  # Without these three every scenario wrote into the developer's REAL
  # `%USERPROFILE%/.local/share/codetracer/trace_index.db` (LRS-6's review,
  # 2026-09-24).  Pinned by the "resolves inside its scratch profile" case.
  env["USERPROFILE"] = homeDir
  env["LOCALAPPDATA"] = homeDir / "AppData" / "Local"
  env["APPDATA"] = homeDir / "AppData" / "Roaming"
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
  let stdoutStr = p.outputStream.readToEof()
  let stderrStr = p.errorStream.readToEof()
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

  test "the helper resolves its trace index INSIDE its scratch profile, never the real one":
    ## The isolation pin (LRS-6's review, 2026-09-24).  Every case below
    ## writes a trace index; if the child resolves it anywhere but the
    ## scratch directory `runScenario` gave it, the suite is writing into
    ## the developer's own profile.  That happened on Windows, where the
    ## env set `HOME` and Nim's `getHomeDir` reads `USERPROFILE`.
    if helperBin.len == 0:
      check false
    else:
      let home = makeTmpHome("profile")
      defer: removeDir(home)
      let (ok, stdoutStr, stderrStr) = runScenario(helperBin, "profile", home)
      checkpoint("scratch profile: " & home)
      checkpoint("helper stdout: " & stdoutStr & "stderr: " & stderrStr)
      check ok
      var resolved = ""
      for line in stdoutStr.splitLines:
        if line.startsWith("TRACE-INDEX "):
          resolved = line["TRACE-INDEX ".len .. ^1].strip
      check resolved.len > 0
      let inside = when defined(windows):
          resolved.normalizedPath.toLowerAscii.startsWith(
            home.normalizedPath.toLowerAscii)
        else:
          resolved.normalizedPath.startsWith(home.normalizedPath)
      if not inside:
        checkpoint("the helper would write its trace index to " & resolved &
          ", OUTSIDE its scratch profile " & home & ".  runScenario is " &
          "missing the variable this OS derives the home directory from.")
      check inside

  test "every suite that redirects a child's HOME redirects USERPROFILE too":
    ## The same defect had four copies: this suite,
    ## `trace_index_migration_test`, `cross_machine_replay_test` and
    ## `recording_folder_layout_test` each spawned a helper with `HOME` /
    ## `XDG_DATA_HOME` redirected and `USERPROFILE` inherited, so on Windows
    ## each helper wrote the developer's real trace index.  The case above
    ## proves THIS suite's child lands in its scratch dir; this one catches
    ## the next suite written from the same template, on any OS, before
    ## anyone runs it on Windows.  It is a source check, so it complements
    ## the behavioural case rather than replacing it.
    const homeOverride = "env[\"HOME\"] ="
    const profileOverride = "env[\"USERPROFILE\"] ="
    let srcRoot = currentSourcePath.parentDir.parentDir
    var redirecting = 0
    for path in walkDirRec(srcRoot):
      if not path.endsWith("_test.nim"):
        continue
      # Sources only: a build tree (`src/build-debug`, …), a nimcache or
      # `node_modules` can hold copies that are not this repository's suites.
      var generated = false
      for part in path.relativePath(srcRoot).split({'/', '\\'}):
        if part.startsWith("build") or part == "node_modules" or
            "nimcache" in part:
          generated = true
      if generated:
        continue
      let text = readFile(path)
      if homeOverride in text:
        inc redirecting
        if profileOverride notin text:
          checkpoint(path & " sets `" & homeOverride & " …` for a child " &
            "process but never `" & profileOverride & " …`.  On Windows " &
            "the child's getHomeDir() is then the developer's real " &
            "profile, and whatever it writes lands there.")
        check profileOverride in text
    # Anti-vacuity: the four known suites were found.
    check redirecting >= 4

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

  test "Trace.recordingId round-trips through recordTrace + find (M-REC-3)":
    ## M-REC-3 acceptance: the rename of ``Trace.id`` → ``Trace.recordingId``
    ## is only meaningful if the field is populated by ``recordTrace`` and
    ## read back by ``find``.  The helper exercises both directions of the
    ## DB round-trip in a fresh subprocess.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "trace-recording-id", "tracerecid")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "findByRecordingIdPrefix resolves a unique 8+ char prefix (M-REC-6)":
    ## M-REC-6 acceptance: a prefix that matches exactly one recording
    ## returns ``isOk = true`` with the canonical id in
    ## ``trace.recordingId``.  Verifies the boundary at the minimum
    ## prefix length and the SQL ``LIKE`` query path.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "short-prefix-unique", "prefuniq")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "findByRecordingIdPrefix reports ambiguity with sorted candidate list (M-REC-6)":
    ## M-REC-6 acceptance: when two or more recordings share a prefix
    ## the resolver returns ``rieAmbiguous`` with the candidate ids in
    ## ASC order so the CLI error renders consistently.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "short-prefix-ambiguous", "prefambig")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "findByRecordingIdPrefix rejects prefixes shorter than the minimum (M-REC-6)":
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "short-prefix-too-short", "prefshort")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "findByRecordingIdPrefix reports rieNotFound for a non-matching prefix (M-REC-6)":
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "short-prefix-not-found", "prefnone")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "addRecentFolder handles paths with trailing slashes/backslashes (#575)":
    ## Issue #575.  ``addRecentFolder`` strips a trailing ``/`` or ``\``
    ## before deriving the folder's display name; without that the name is
    ## empty and the folder is stored twice.
    ##
    ## This case previously lived in
    ## ``src/tests/gui/tests/welcome-screen/welcome_screen_vm_test.nim``.
    ## It is not a ViewModel test — it drives ``src/common/trace_index``
    ## against a real SQLite database — and its presence there forced that
    ## whole ViewModel suite to import ``trace_index``, which transitively
    ## imports ``std/osproc`` and ``db_connector/db_sqlite``.  That made the
    ## entire 44-case file uncompilable under ``nim js`` (``cannot export:
    ## quoteShell``), so none of its cases ran on the JS backend at all.
    ## Here it also gains the isolation the rest of this suite has: it runs
    ## in a subprocess against a throwaway ``$HOME``, instead of writing to
    ## the shared ``test = true`` index the developer's other runs share.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "recent-folder-trailing-separators", "recentfolders")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr

  test "recordTrace persists the OBSERVED axes, and the row loads as materialized (LRS-5 (b))":
    ## The record side of LRS-5's second deletion round, through the real
    ## writer and the real loader.  A wasm Rust recording is registered with
    ## `axesArg = some(slRust / tiWasm / raVmEmulation)`, the cell on disk must
    ## read `rs-wasm-unknown-vm`, and `find` must bring it back with
    ## `approach == raVmEmulation` and `usesMaterializedTraces` true -- while
    ## its `Lang` summary, `LangRust`, answers false on its own.  Without the
    ## `axesArg` plumbing the same recording writes `rs-native-unknown-mcr`
    ## and every replay-side site reads it as native: the silent mislabel the
    ## wasm pair was kept to prevent.
    ##
    ## Added at review.  `target_axes_test.nim` pins the same fact by grepping
    ## the two source files for the `axesArg` call sites, which survives no
    ## reformat and observes no behaviour.
    if helperBin.len == 0:
      skip()
    else:
      let (ok, stdoutStr, stderrStr) = runHelperScenario(
        "observed-axes-round-trip", "observedaxes")
      if not ok or "PASS" notin stdoutStr:
        echo "stdout: ", stdoutStr
        echo "stderr: ", stderrStr
      check ok
      check "PASS" in stdoutStr
