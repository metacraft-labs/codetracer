## Cross-process origin — headless ViewModel test.
##
## The headless-first policy in
## `codetracer-specs/Testing/Testing-Guidelines.md` requires every GUI
## test to have a ViewModel counterpart, so that a failing GUI test can
## be localised to either the view layer or the state layer in
## milliseconds instead of minutes.
##
## This is the counterpart to
## `src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts`.
## It asserts the state a three-recording session puts the view models
## into:
##
##   * `SessionViewModel.processTree` lists all three recordings,
##   * `OriginChainVM.activeChain` carries one `CrossProcessSpan` per
##     recording the chain visits,
##   * clicking a hop that belongs to another recording rotates
##     `activeProcessRecordingId`.
##
## Like `value_origin_test.nim`, the chain is **not** hand-written: it
## is produced by a real `ct/originChain` request against the real
## three-recording demo session, dumped to JSON by the Rust helper
## `origin_chain_dump_helper.rs`, and parsed here with the production
## `parseOriginChain`. Hand-authoring the chain would make this test
## agree with itself rather than with the backend.
##
## Compile + run:
##   nim c -r src/frontend/tests/cross_process_origin_vm_test.nim

import std/[json, options, os, osproc, streams, strtabs, strutils, unittest]

import isonim/core/[signals, owner]

import ../viewmodel/backend/[backend_service, mock_backend]
import ../viewmodel/session_vm
import ../viewmodel/viewmodels/[origin_chain_types, origin_chain_vm]

const
  ScenarioName = "cross_process_three_trace"
  DumpHelperTest = "origin_chain_dump_helper"

proc repoRoot(): string =
  ## `<repo>/src/frontend/tests/<this file>` → `<repo>`.
  currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc runDumpHelper(outDir: string): tuple[ok: bool, output: string] =
  ## Drive the Rust helper that produces the chain dump.
  ##
  ## Shelling out keeps one implementation of "ask the backend for a
  ## cross-process chain" — the helper uses the same DAP client the
  ## headless DAP test uses — rather than reimplementing the session
  ## launch in Nim and risking the two drifting apart.
  let dbBackend = repoRoot() / "src" / "db-backend"
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["ORIGIN_DUMP_OUT_DIR"] = outDir
  let process = startProcess(
    "cargo",
    workingDir = dbBackend,
    args = ["test", "--test", DumpHelperTest, "--", "--nocapture"],
    env = env,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  (code == 0, output)

suite "Cross-process origin — ViewModel":
  var chainJson: JsonNode = nil
  var failReason = ""

  setup:
    if chainJson.isNil and failReason.len == 0:
      let outDir = getTempDir() / "ct-cross-process-vm-" & $getCurrentProcessId()
      createDir(outDir)
      let (ok, output) = runDumpHelper(outDir)
      let jsonPath = outDir / (ScenarioName & ".json")
      if fileExists(jsonPath):
        chainJson = parseFile(jsonPath)
      elif not ok:
        failReason = "the origin-chain dump helper failed:\n" & output
      else:
        failReason = "the dump helper produced no chain and reported success"

  test "the process tree lists all three recordings":
    # Independent of the chain dump: this is the session shape the
    # renderer's process tree binds to.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      session.applyListProcessesResponse(%*{
        "processes": [
          {"recordingId": "fe-js", "role": "frontend-js",
           "displayName": "frontend", "defaultThreadPrefix": "fe",
           "threadCount": 1},
          {"recordingId": "fe-wasm", "role": "frontend-wasm",
           "displayName": "frontend-wasm", "defaultThreadPrefix": "wasm",
           "threadCount": 1},
          {"recordingId": "be", "role": "backend",
           "displayName": "backend", "defaultThreadPrefix": "be",
           "threadCount": 1},
        ]
      })
      let entries = session.processTree.entries.val
      check entries.len == 3
      check entries[0].role == "frontend-js"
      check entries[1].role == "frontend-wasm"
      check entries[2].role == "backend"
      # The first entry is selected automatically so panels have a
      # recording to render before the user clicks anything.
      check session.activeProcessRecordingId.val == "fe-js"

  test "the real chain carries one span per recording it visits":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      let chain = parseOriginChain(chainJson)
      check chain.crossProcessSpans.len >= 2
      var roles: seq[string] = @[]
      for span in chain.crossProcessSpans:
        roles.add(span.role)
      # The walk starts in the recording the query targeted.
      check roles[0] == "backend"
      check "frontend-js" in roles

  test "every span indexes a valid hop range or is a marked placeholder":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      let chain = parseOriginChain(chainJson)
      # A span whose hop range is inverted or runs off the end of the
      # chain would make a renderer that slices `hops[first..last]`
      # either crash or draw the wrong hops.
      #
      # A span with no hops of its own is legitimate: the walk really
      # did cross into that recording, but the sending side had nothing
      # further to say (a recording without value capture, say). The
      # convention for that is `first == last == hops.len` — the
      # breadcrumb chip still renders and still switches the active
      # recording, it just has no hop to scroll to.
      for span in chain.crossProcessSpans:
        check span.recordingId.len > 0
        check span.firstHopIndex.int <= span.lastHopIndex.int
        if span.firstHopIndex.int >= chain.hops.len:
          check span.firstHopIndex.int == chain.hops.len
          check span.lastHopIndex.int == chain.hops.len
        else:
          check span.lastHopIndex.int < chain.hops.len

  test "clicking a sibling hop rotates the active recording":
    # No skip. The demo is RECORDED by the dump helper when it runs
    # (`scripts/materialize-recording.sh`), so a helper that could not
    # deliver a chain means the recording pipeline is broken, not that
    # this machine is under-provisioned. Skipping here is what let this
    # counterpart assert nothing at all while the GUI spec it localises
    # went on being the campaign's only real evidence.
    if failReason.len > 0:
      checkpoint(failReason)
      fail()
    else:
      createRoot proc(dispose: proc()) =
        let chain = parseOriginChain(chainJson)
        let mock = newMockBackendService(autoRespond = true)
        let session = createSessionVM(mock.toBackendService())

        var entries: seq[ProcessTreeEntry] = @[]
        for span in chain.crossProcessSpans:
          entries.add(ProcessTreeEntry(
            recordingId: span.recordingId,
            role: span.role,
            displayName: span.role,
            defaultThreadPrefix: span.role,
            threadCount: 1,
          ))
        session.setProcessTree(entries)

        let startingRecording = session.activeProcessRecordingId.val
        check startingRecording.len > 0

        # Find a span belonging to a different recording — that is the
        # breadcrumb chip the user clicks to follow the value across the
        # boundary.
        var target = ""
        for span in chain.crossProcessSpans:
          if span.recordingId != startingRecording:
            target = span.recordingId
            break
        check target.len > 0

        session.onSwitchProcess(target)
        check session.activeProcessRecordingId.val == target
        # The per-recording StateVM alias must rotate too, otherwise the
        # editor and state panes keep rendering the previous recording's
        # position while the process tree claims otherwise.
        check not session.stateVM.isNil
