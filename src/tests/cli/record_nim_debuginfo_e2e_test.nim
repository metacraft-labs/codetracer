## record_nim_debuginfo_e2e_test.nim
##
## `ct record main.nim` must produce a recording the replay engine can OPEN —
## asserted end to end with the shipped `ct`, the real `ct-mcr` recorder and the
## real `replay-server`.
##
## ## The defect this guards
##
## codetracer-pm issue `2026-10-22-ct-record-compiles-a-nim-program-without-
## debug-info-so-its-replay-cannot-reach-entry.md`.  `recordNim`
## (`src/ct/db_backend_record.nim`) compiled the program with
## `nim c --hints:off -d:release -o:<trace>/<name> <program>`: no DWARF and no
## trace-local nimcache.  The recording itself succeeded, so every check that
## stops at "a CTFS container came out" (`record_dispatch_e2e_test.nim`) stayed
## green, while the replay of that container failed at launch with
## `ct/launch-failed` "MCR run-to-entry stopped without source location:
## <unknown>:0" — the engine cannot place the entry stop without line tables.
## In the GUI that was an empty editor and a 60 s wait timeout
## (`src/tests/gui/tests/nim-view-switching/stepping-through-views.spec.ts`).
##
## So this file asserts, in the order a reader would diagnose it:
##
## 1. `ct record` of a real Nim program exits 0 and leaves a CTFS container;
## 2. the compiled program in the trace folder carries DWARF (`.debug_info`
##    and `.debug_line` ELF sections) — the cause;
## 3. the trace folder has `nimcache/@m<name>.nim.c`, the generated C the DWARF
##    names (codetracer-pm `spec/Trace-Files/RR-Trace-Folders.md`
##    §"nimcache/ Directory (Nim only)") — without it, a C-level location has no
##    file to show — and the compiler's `macro_sourcemap_<name>.json` beside the
##    recording, where its readers look for it;
## 4. a DAP `launch` of the trace folder through `replay-server dap-server
##    --stdio` reaches the initial `stopped` event instead of `ct/launch-failed`,
##    and the `ct/complete-move` that follows names a `.nim` / `.nim.c` file and
##    a line > 0 — the symptom, which is what a user actually sees.
##
## ## Why DAP is driven by a small client here
##
## `src/frontend/viewmodel/headless_session.nim`'s `newHeadlessDebugSession`
## performs the same handshake (`initialize`, `configurationDone`, `launch`,
## then `stopped` or `ct/launch-failed`), but it builds the whole ViewModel/SDK
## session on top, which drags the IsoNim reactive layer and every view model
## into this lane's per-file compile for no assertion this file makes.  Its
## transport, `backend/stdio_backend.nim`, was the first choice and was tried:
## it starts `replay-server` with `poStdErrToStdOut`, and in the lane
## (`ci/lib/run-nim-test-lane.sh`) the engine's stderr diagnostics landed
## INSIDE a `Content-Length` body, so the read failed with a JSON parse error
## after a successful `stopped`.  A check of "the launch reaches its entry
## stop" cannot depend on how chatty the engine's logging is, so the client
## below keeps the engine's stderr in a file of its own and reads stdout as
## pure DAP (https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol).
##
## ## Gating
##
## Not run, with the workspace's uniform `MISSING-RECORDER SKIP:` marker, when
## `ct record` reports that `ct-mcr` (or the Nim compiler) was not found, or
## when no `replay-server` is built.  The case then passes and says why, as
## `record_dispatch_e2e_test.nim` does: this file is registered in
## `src/ct_test/release_gate.nim` `CliRecordGateTests`, whose contract forbids
## unittest's skip in these files.  Everything else is a failure.  In the
## CodeTracer dev shell `scripts/detect-siblings.sh` exports
## `CODETRACER_CT_MCR_CMD` from the codetracer-native-recorder sibling, and the
## replay-server comes from `just build-once`, so on a developer machine and in
## CI this runs for real.  The DWARF check reads ELF section headers and the
## DAP client starts the engine through `/bin/sh` and `timeout`, so the file
## runs on Linux only and says so by name elsewhere (`MISSING-PREREQ SKIP:`).
##
## Mocking justification (workspace policy on mock objects): none.  The `ct`
## binary, the Nim compiler, `ct-mcr`, `replay-server` (and the native replay
## engine it spawns) and the filesystem are all real.
##
## Compile and run (inside the dev shell, after `source scripts/detect-siblings.sh`):
##   nim c -r src/tests/cli/record_nim_debuginfo_e2e_test.nim

import std/[json, os, osproc, streams, strutils, unittest]
import ../../common/replay_server_path

const
  RecordTimeoutSeconds = 900
    ## Compile + MCR record of a small program. Generous, bounded.
  ReplayTimeoutSeconds = 900
    ## Bound on the whole replay-server run. The entry run of an MCR replay
    ## can take a while on a loaded host; a launch that never answers must
    ## still end the test rather than wedge the lane.
  CtfsMagic = "\xC0\xDE\x72\xAC\xE2"
    ## The CTFS container magic (src/backend-manager/src/meta_dat.rs CTFS_MAGIC).

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## Resolved exactly as `record_dispatch_e2e_test.nim` resolves it.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / "ct"

# ---------------------------------------------------------------------------
# ELF section names (enough of ELF64 to list section headers)
# Format: https://refspecs.linuxfoundation.org/elf/gabi4+/ch4.sheader.html
# ---------------------------------------------------------------------------

proc readLe(data: string; offset, size: int): uint64 =
  if offset < 0 or offset + size > data.len:
    raise newException(ValueError, "ELF read out of bounds at " & $offset)
  for i in countdown(size - 1, 0):
    result = (result shl 8) or uint64(ord(data[offset + i]))

proc elfSectionNames*(path: string): seq[string] =
  ## The section names of a little-endian ELF64 file, read from its section
  ## header table and section-name string table.  Raises `ValueError` on any
  ## other kind of file, so "not an ELF" is never mistaken for "no DWARF".
  let data = readFile(path)
  if data.len < 64 or data[0 ..< 4] != "\x7FELF":
    raise newException(ValueError, path & " is not an ELF file")
  if ord(data[4]) != 2 or ord(data[5]) != 1:
    raise newException(ValueError, path & " is not little-endian ELF64")
  let shoff = int(readLe(data, 0x28, 8))
  let shentsize = int(readLe(data, 0x3A, 2))
  let shnum = int(readLe(data, 0x3C, 2))
  let shstrndx = int(readLe(data, 0x3E, 2))
  if shnum == 0 or shstrndx >= shnum:
    raise newException(ValueError, path & " has no usable section table")
  let strtabHeader = shoff + shstrndx * shentsize
  let strtabOffset = int(readLe(data, strtabHeader + 0x18, 8))
  for i in 0 ..< shnum:
    let header = shoff + i * shentsize
    let nameOffset = strtabOffset + int(readLe(data, header, 4))
    var name = ""
    var p = nameOffset
    while p < data.len and data[p] != '\0':
      name.add data[p]
      inc p
    result.add name

# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

proc recorderMissing(output: string): bool =
  ## `requireRecorder`'s wording (src/ct/trace/recorder_dispatch.nim
  ## `missingRecorderMessage`) and `recordNim`'s compiler check.
  "was not found" in output or "Nim compiler not found" in output

# ---------------------------------------------------------------------------
# A minimal DAP client: stdout is the protocol, stderr goes to a file
# ---------------------------------------------------------------------------

type
  DapClient = ref object
    process: Process
    nextSeq: int

  LaunchOutcome = object
    launchResponse: JsonNode
    refusal: string       ## `ct/launch-failed`'s message; "" when none came
    stopped: bool         ## the initial `stopped` event arrived
    completeMove: JsonNode

proc startDap(replayServer, stderrLog: string): DapClient =
  ## `replay-server dap-server --stdio` with its stderr appended to
  ## `stderrLog`, bounded by `timeout` so a launch that never answers ends
  ## the read (end of stream) instead of wedging the lane.
  let script = "exec timeout " & $ReplayTimeoutSeconds &
    " \"$0\" dap-server --stdio 2>>\"$1\""
  DapClient(process: startProcess("/bin/sh",
    args = @["-c", script, replayServer, stderrLog], options = {}))

proc send(dap: DapClient; command: string; arguments = newJObject()) =
  inc dap.nextSeq
  let body = $(%*{"seq": dap.nextSeq, "type": "request", "command": command,
                  "arguments": arguments})
  let input = dap.process.inputStream
  input.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  input.flush()

proc read(dap: DapClient): JsonNode =
  ## One message, or nil at end of stream.
  let output = dap.process.outputStream
  var length = -1
  var line = ""
  while true:
    if not output.readLine(line):
      return nil
    line = line.strip(leading = false, chars = {'\r'})
    if line.len == 0:
      if length >= 0: break
      continue
    if line.toLowerAscii.startsWith("content-length:"):
      length = parseInt(line.split(':', 1)[1].strip)
  let body = output.readStr(length)
  if body.len < length:
    return nil
  parseJson(body)

proc waitForOutcome(dap: DapClient): LaunchOutcome =
  ## Read until the launch has said how it went: `ct/complete-move` after the
  ## initial `stopped`, or `ct/launch-failed`, or end of stream.
  while true:
    let msg = dap.read()
    if msg.isNil:
      return
    if msg{"type"}.getStr == "response" and msg{"command"}.getStr == "launch":
      result.launchResponse = msg
    elif msg{"type"}.getStr == "event":
      case msg{"event"}.getStr
      of "ct/launch-failed":
        result.refusal = msg{"body", "message"}.getStr("(no message)")
        return
      of "stopped":
        result.stopped = true
      of "ct/complete-move":
        if result.stopped:
          result.completeMove = msg
          return
      else:
        discard

proc show(node: JsonNode): string =
  ## `$` for a node that may be absent (`$nil` dereferences it).
  if node.isNil: "(none)" else: $node

proc close(dap: DapClient) =
  if dap.process.running:
    dap.process.terminate()
  discard dap.process.waitForExit()
  dap.process.close()

suite "ct record <file>.nim replays to its entry location":

  let ct = ctBinary()
  # Under the per-run scratch `CODETRACER_HOME` the harnesses set (AGENTS.md,
  # "Tests never touch your real CodeTracer state"), so concurrent runs from
  # different worktrees cannot clobber each other's recording.
  let scratchBase = getEnv("CODETRACER_HOME", getTempDir())
  let scratch = scratchBase / "ct-nim-debuginfo-e2e"
  let program = repoRoot() / "test-programs" / "nim_sudoku_solver" / "main.nim"
  let traceFolder = scratch / "trace"
  # A container came out (whether or not the DWARF checks passed): the replay
  # case below then has something to open.
  var recorded = false
  # `ct record` said the recorder or the compiler is not installed.
  var recorderAbsent = false

  test "the ct binary under test exists":
    if not fileExists(ct):
      echo "ERROR: no ct binary at ", ct
      echo "  build it with `just build-once`, or set CODETRACER_E2E_CT_PATH."
    check fileExists(ct)

  test "ct record compiles the program with DWARF and a trace-local nimcache":
    require fileExists(ct)
    require fileExists(program)
    when not defined(linux):
      echo "MISSING-PREREQ SKIP: Nim (MCR) — this check reads ELF and " &
        "runs on Linux only"
      recorderAbsent = true
    else:
      removeDir(scratch)
      createDir(scratch)
      let (output, exitCode) = execCmdEx(
        "timeout " & $RecordTimeoutSeconds & " " & quoteShell(ct) &
        " record -o " & quoteShell(traceFolder) & " " & quoteShell(program) &
        " 2>&1")
      checkpoint("ct output:\n" & output)
      if exitCode != 0 and recorderMissing(output):
        echo "MISSING-RECORDER SKIP: Nim (MCR) — ", output.strip.splitLines[^1]
        recorderAbsent = true
      else:
        check exitCode == 0
        let container = traceFolder / "trace.ct"
        check fileExists(container)
        if fileExists(container):
          check readFile(container)[0 ..< CtfsMagic.len] == CtfsMagic

        # The cause: the program in the trace folder must carry line tables.
        let binary = traceFolder / program.splitFile.name
        check fileExists(binary)
        if fileExists(binary):
          let sections = elfSectionNames(binary)
          checkpoint("ELF sections of " & binary & ": " & sections.join(" "))
          check ".debug_info" in sections
          check ".debug_line" in sections

        # The generated C the DWARF points at, kept in the trace
        # (RR-Trace-Folders.md, "nimcache/ Directory (Nim only)").
        let nimcache = traceFolder / "nimcache"
        let generatedMain = nimcache / ("@m" & program.splitFile.name & ".nim.c")
        checkpoint("expected generated C at " & generatedMain)
        check fileExists(generatedMain)

        # The compiler writes its macro sourcemap into the nimcache; every
        # reader of it (replay-server's `load_macro_sourcemaps`, the GUI's
        # `findMacroSourcemapPath`) looks in the trace folder root.
        let macroSourcemap = traceFolder /
          ("macro_sourcemap_" & program.splitFile.name & ".json")
        checkpoint("expected macro sourcemap at " & macroSourcemap)
        check fileExists(macroSourcemap)

        recorded = exitCode == 0 and fileExists(container)

  test "replay-server launches the recording and stops at the entry location":
    if recorderAbsent:
      echo "MISSING-RECORDER SKIP: Nim (MCR) — no recording to replay " &
        "(see the previous case)"
    elif not recorded:
      # A recorder that is installed and produced nothing is a failure, not a
      # skip: the previous case says why.
      checkpoint("ct record produced no container; see the previous case")
      check recorded
    else:
      let replayServer = locateReplayServer()
      if replayServer.len == 0:
        echo "MISSING-RECORDER SKIP: replay-server — ", missingReplayServerMessage()
      else:
        checkpoint("replay-server: " & replayServer)
        let engineLog = scratch / "replay-server.stderr.log"
        let dap = startDap(replayServer, engineLog)
        try:
          dap.send("initialize", %*{
            "clientID": "record-nim-debuginfo-e2e",
            "adapterID": "codetracer",
            "supportsProgressReporting": false,
          })
          dap.send("configurationDone")
          dap.send("launch", %*{"traceFolder": traceFolder})

          # THE CORE OF THE ISSUE. `launch` is answered `success: true` before
          # the engine opens anything; whether the recording can be replayed
          # is said afterwards, as `stopped` or as `ct/launch-failed`
          # (`stdio_backend.nim`'s `DapLaunchRefusedError` is the front-ends'
          # name for the second).
          let outcome = dap.waitForOutcome()
          checkpoint("replay-server stderr: " & engineLog)
          checkpoint("launch response: " & show(outcome.launchResponse))
          checkpoint("ct/launch-failed: " & outcome.refusal)
          check outcome.launchResponse{"success"}.getBool(false)
          check outcome.refusal.len == 0
          check outcome.stopped

          # `ct/complete-move` carries the stop's source location; it exists
          # only once the launch reached `stopped`.
          let location = outcome.completeMove{"body", "location"}
          checkpoint("ct/complete-move location: " & show(location))
          if outcome.stopped:
            check not location.isNil
          if not location.isNil:
            let path = location{"path"}.getStr("")
            let line = location{"line"}.getInt(0)
            echo "entry location: ", path, ":", line
            check path.endsWith(".nim") or path.endsWith(".nim.c")
            check line > 0
        finally:
          dap.close()
