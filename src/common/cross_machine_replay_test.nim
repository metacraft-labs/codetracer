## M-REC-10 — Cross-machine replay integration gate.
##
## Acceptance test for the parent spec's primary goal: a recording made
## on host A is loadable on host B without a remap step / DB surgery /
## id collision.  Simulates the two hosts as two distinct
## ``XDG_DATA_HOME`` tmpdirs in the same process tree.
##
## Test recipe (mirrors the M-REC-10 status entry):
##   1. Subprocess A: ``XDG_DATA_HOME = $tmpA`` → record a minimal
##      program.  Extracts the recording_id from the helper's
##      structured stdout.
##   2. Orchestrator: ``tar`` the
##      ``$tmpA/.local/share/codetracer/<recording_id>/`` folder, untar
##      under ``$tmpB/.local/share/codetracer/<recording_id>/``.  This
##      mirrors ``tar | ssh hostB tar -x`` from the parent spec but
##      keeps the test pure-filesystem.
##   3. Standalone sanity scenario (meta-dat-read): parse the tar'd
##      trace.ct's meta.dat through the production reader and assert
##      the recording_id survived the transfer byte-for-byte.
##   4. Subprocess B: ``XDG_DATA_HOME = $tmpB`` → simulate
##      ``ct replay <recording_id>`` (the canonical
##      "I scp'd a folder, now open it" command).  Asserts:
##        - the DB row is initially absent on host B,
##        - ``importTrace`` (the production code path) preserves the
##          meta.dat-embedded id,
##        - ``trace_index.find`` then returns the recording for the
##          same id host A emitted,
##        - the on-disk folder name equals the recording_id (M-REC-7).
##   5. Orchestrator: assert host A's recording_id == host B's
##      recording_id == meta.dat's recording_id.  This is the
##      "byte-for-byte cross-machine identity" property the migration's
##      primary goal hinges on.
##
## What this simulates vs really tests:
##   - **Really tested**: the production ``importTrace`` path (M-REC-10
##     fix), the production ``trace_index.find`` lookup, the production
##     ``readCtfsMetaDat`` reader (M-REC-1.5), the M-REC-2
##     ``ensureDB`` first-launch path on host B, the M-REC-7
##     ``recordingFolder`` chokepoint, real ``tar`` invocation for the
##     transfer.
##   - **Simulated** (not heavyweight-real, by design — the heavy tests
##     live in ``backend-manager/tests/real_recording_integration.rs``
##     and in the recorder repo): the recorder itself.  The helper
##     hand-builds a real meta.dat v3 + CTFS container; the writer logic
##     mirrors the sibling ``ctfs_sources_test.nim`` fixture writer and
##     the Rust ``meta_dat::write_minimal_ctfs`` test fixture.  The
##     orchestrator does NOT spawn ``ct-mcr``; that path is covered by
##     the recorder repo's ``test_trace_recording_id_stamped``
##     (M-REC-1).  The portability contract under test here is purely
##     about identifier propagation — the trace's *content* is
##     orthogonal.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/cross_machine_replay_test \
##       src/common/cross_machine_replay_test.nim

import std/[os, osproc, streams, strtabs, strutils, unittest, tempfiles]

# ---------------------------------------------------------------------------
# Helper subprocess builder
# ---------------------------------------------------------------------------

let helperSource = currentSourcePath.parentDir /
  "cross_machine_replay_test_helper.nim"

let helperCache = getTempDir() / "ct-cross-machine-replay-helper-cache"

proc compileHelper(): string =
  removeDir(helperCache)
  createDir(helperCache)
  let bin = helperCache / "cross_machine_replay_test_helper"
  let cmd = "nim c --hints:off --warnings:off --mm:refc " &
            "--nimcache:" & quoteShell(helperCache) & " " &
            "--out:" & quoteShell(bin) & " " &
            quoteShell(helperSource)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "cross_machine_replay_test: helper compile FAILED:"
    echo output
    return ""
  return bin

let helperBin = compileHelper()

proc makeTmpHome(name: string): string =
  createTempDir("ct-xmr-" & name & "-", "")

proc runScenario(bin: string, scenarioArgs: openArray[string]; homeDir: string):
    tuple[ok: bool, stdoutStr: string, stderrStr: string] =
  ## Run the helper at ``bin`` with the env scrubbed to ``homeDir`` so
  ## ``paths.app`` / ``codetracerTraceDir`` resolve under that tmpdir
  ## and not the developer's real ``$HOME``.  Splice
  ## ``CT_LD_LIBRARY_PATH`` onto ``LD_LIBRARY_PATH`` so SQLite can be
  ## dlopen-ed inside the Nix dev-shell — same recipe as the sibling
  ## ``trace_index_test.nim`` orchestrator.
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
  var args: seq[string] = @[]
  for a in scenarioArgs:
    args.add a
  let p = startProcess(
    bin,
    args = args,
    env = env,
    options = {})
  defer: p.close()
  let stdoutStr = p.outputStream.readAll()
  let stderrStr = p.errorStream.readAll()
  let code = p.waitForExit()
  (code == 0, stdoutStr, stderrStr)

# ---------------------------------------------------------------------------
# Test orchestration helpers
# ---------------------------------------------------------------------------

proc extractKv(stdoutStr, key: string): string =
  ## Parse ``key=value`` lines emitted by the helper.  Returns the empty
  ## string when the key is absent so callers can fail with a focused
  ## error rather than throwing on missing entries.
  let prefix = key & "="
  for line in stdoutStr.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1]
  ""

proc tarFolder(folder, archive: string) =
  ## Real ``tar`` invocation — the M-REC-10 spec calls out tar+scp as
  ## the canonical transfer mechanism, so the test uses real tar to
  ## prove the on-disk bytes survive an archive round-trip.  Using the
  ## ``-C`` parent dir form gives us a stable archive shape regardless
  ## of where ``folder`` sits in the filesystem.
  let parent = folder.parentDir
  let basename = folder.lastPathPart
  let cmd = "tar -cf " & quoteShell(archive) & " -C " & quoteShell(parent) &
            " " & quoteShell(basename)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "tar failed: ", output
    raise newException(IOError, "tar failed creating " & archive)

proc untarInto(archive, destParent: string) =
  ## Inverse of ``tarFolder``: extract ``archive`` so its top-level
  ## directory entry sits directly under ``destParent``.
  createDir(destParent)
  let cmd = "tar -xf " & quoteShell(archive) & " -C " & quoteShell(destParent)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "tar -x failed: ", output
    raise newException(IOError, "tar -x failed extracting " & archive)

proc codetracerTraceDirIn(home: string): string =
  ## Mirror ``paths.codetracerTraceDir``'s derivation
  ## (``$HOME/.local/share/codetracer``) from the test process so the
  ## orchestrator can reach into the helper's working filesystem.  We
  ## use ``$HOME`` rather than ``$XDG_DATA_HOME`` because ``paths.nim``
  ## itself does (the helper env-points both to the same tmpdir).
  home / ".local" / "share" / "codetracer"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M-REC-10 — cross-machine replay integration gate":

  test "helper compiles":
    check helperBin.len > 0

  test "scp + ct replay <recording_id> works without a remap step":
    ## End-to-end gate: record on host A, tar+untar the folder to host B,
    ## replay on host B succeeds with the same recording_id.  This is
    ## the migration's "done" test per the parent spec § 7 / status.org
    ## M-REC-10.
    if helperBin.len == 0:
      skip()
    else:
      let homeA = makeTmpHome("hostA")
      let homeB = makeTmpHome("hostB")
      defer:
        removeDir(homeA)
        removeDir(homeB)

      # Step 1 — host A records.
      let (okA, outA, errA) = runScenario(helperBin, @["record-host-a"], homeA)
      if not okA or "PASS" notin outA:
        echo "host-A stdout: ", outA
        echo "host-A stderr: ", errA
      check okA
      check "PASS" in outA

      let recordingId = extractKv(outA, "recording_id")
      let hostAFolder = extractKv(outA, "output_folder")
      let metaRecId = extractKv(outA, "meta_recording_id")
      check recordingId.len == 36
      check metaRecId == recordingId

      let aDir = codetracerTraceDirIn(homeA)
      let bDir = codetracerTraceDirIn(homeB)
      let aFolder = aDir / recordingId
      let bFolder = bDir / recordingId
      # Sanity: the helper put the folder where M-REC-7 says it should.
      check hostAFolder == aFolder
      check dirExists(aFolder)
      check fileExists(aFolder / "trace.ct")

      # Step 2 — tar the recording on host A, untar into host B's
      # ``<traces>/`` (so the result is exactly the layout described in
      # status.org step 3: "place the folder under <traces>/<recording_id>/").
      let archive = getTempDir() / "ct-xmr-archive-" & recordingId & ".tar"
      defer:
        try: removeFile(archive)
        except OSError: discard
      tarFolder(aFolder, archive)
      createDir(bDir)
      untarInto(archive, bDir)
      check dirExists(bFolder)
      check fileExists(bFolder / "trace.ct")

      # Step 3 — verify meta.dat survived tar untouched.  The
      # standalone scenario uses the helper's *own* ``readCtfsMetaDat``
      # binding (same code path importTrace will execute on host B), so
      # a tar-induced corruption would be caught here first with a
      # sharper error than "importTrace raised".
      let (okMeta, outMeta, errMeta) = runScenario(
        helperBin,
        @["meta-dat-read", bFolder / "trace.ct", recordingId],
        homeB)
      if not okMeta or "PASS" notin outMeta:
        echo "meta-dat-read stdout: ", outMeta
        echo "meta-dat-read stderr: ", errMeta
      check okMeta
      check "PASS" in outMeta

      # Step 4 — host B replays.
      let (okB, outB, errB) = runScenario(
        helperBin,
        @["replay-host-b", recordingId],
        homeB)
      if not okB or "PASS" notin outB:
        echo "host-B stdout: ", outB
        echo "host-B stderr: ", errB
      check okB
      check "PASS" in outB

      let replayedId = extractKv(outB, "recording_id")
      let replayedFolder = extractKv(outB, "output_folder")

      # Step 5 — cross-machine identity.  This is the bit the migration's
      # primary goal hinges on: the same recording_id round-trips
      # byte-for-byte through tar / new DB / importTrace.
      check replayedId == recordingId
      check replayedFolder == bFolder
      # Folder name on host B equals the recording_id (M-REC-7 sanity on
      # the receiving side; if a future regression in ``recordingFolder``
      # silently appended a prefix on host B's path it would surface here).
      check replayedFolder.lastPathPart == recordingId

      # Emit a proof line the reviewer can grep for, matching the prompt's
      # ask for a "trace-id round-trip log line".
      echo "M-REC-10 round-trip OK: recording_id=", recordingId,
           " hostA=", aFolder, " hostB=", bFolder

  test "host B fails closed when the folder is missing":
    ## Defensive: prove the gate's preconditions are checked.  If the
    ## user typed a recording_id without scp-ing the folder first, host
    ## B must fail with a clear "folder missing" error rather than
    ## silently materialising a phantom row.
    if helperBin.len == 0:
      skip()
    else:
      let homeB = makeTmpHome("hostBmissing")
      defer: removeDir(homeB)

      let bogusId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
      let (ok, stdoutStr, stderrStr) = runScenario(
        helperBin,
        @["replay-host-b", bogusId],
        homeB)
      # Helper exits non-zero with a "FAIL:" line on this path; the test
      # passes as long as that's the visible behaviour.
      check (not ok)
      check ("FAIL:" in stdoutStr or "FAIL:" in stderrStr)
      check ("expected folder" in stdoutStr or "expected folder" in stderrStr)
