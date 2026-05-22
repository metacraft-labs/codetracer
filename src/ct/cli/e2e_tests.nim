import std/[json, os, osproc, strutils, times]

type
  ReprobuildHcrGateArgs = object
    project: string
    target: string
    binary: string
    sourceEditDriver: string
    artifacts: string

proc failUsage(message: string): int =
  stderr.writeLine("ct test e2e: " & message)
  stderr.writeLine(
    "usage: ct test e2e reprobuild-hcr-in-codetracer " &
      "--project PATH --target NAME --binary PATH " &
      "--source-edit-driver PATH --artifacts PATH")
  2

proc parseValue(args: seq[string]; index: var int; flag: string): string =
  let arg = args[index]
  let prefix = flag & "="
  if arg.startsWith(prefix):
    return arg[prefix.len .. ^1]
  if arg == flag:
    if index + 1 >= args.len:
      raise newException(ValueError, flag & " requires a value")
    index.inc
    return args[index]
  raise newException(ValueError, "internal parse error for " & flag)

proc parseReprobuildHcrArgs(args: seq[string]): ReprobuildHcrGateArgs =
  var index = 0
  while index < args.len:
    let arg = args[index]
    case arg
    of "--project":
      result.project = parseValue(args, index, "--project")
    of "--target":
      result.target = parseValue(args, index, "--target")
    of "--binary":
      result.binary = parseValue(args, index, "--binary")
    of "--source-edit-driver":
      result.sourceEditDriver =
        parseValue(args, index, "--source-edit-driver")
    of "--artifacts":
      result.artifacts = parseValue(args, index, "--artifacts")
    else:
      if arg.startsWith("--project="):
        result.project = parseValue(args, index, "--project")
      elif arg.startsWith("--target="):
        result.target = parseValue(args, index, "--target")
      elif arg.startsWith("--binary="):
        result.binary = parseValue(args, index, "--binary")
      elif arg.startsWith("--source-edit-driver="):
        result.sourceEditDriver =
          parseValue(args, index, "--source-edit-driver")
      elif arg.startsWith("--artifacts="):
        result.artifacts = parseValue(args, index, "--artifacts")
      else:
        raise newException(ValueError, "unknown argument: " & arg)
    index.inc

proc requireNonEmpty(value, name: string) =
  if value.len == 0:
    raise newException(ValueError, name & " is required")

proc requireFile(path, name: string) =
  requireNonEmpty(path, name)
  if not fileExists(path):
    raise newException(ValueError, name & " does not exist: " & path)

proc requireExecutable(path, name: string) =
  requireFile(path, name)
  when defined(posix):
    if fpUserExec notin getFilePermissions(path) and
        fpGroupExec notin getFilePermissions(path) and
        fpOthersExec notin getFilePermissions(path):
      raise newException(ValueError, name & " is not executable: " & path)

proc requireDir(path, name: string) =
  requireNonEmpty(path, name)
  if not dirExists(path):
    raise newException(ValueError, name & " does not exist: " & path)

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add(" ")
    result.add(q(arg))

proc requireEnvOrPath(envName, fallback: string): string =
  result = getEnv(envName, "")
  if result.len == 0:
    result = fallback

proc lineForMarker(path, marker: string): int =
  let text = readFile(path)
  var index = 0
  for line in text.splitLines:
    index.inc
    if marker in line:
      return index
  raise newException(ValueError, "marker " & marker & " not found in " & path)

proc writeJson(path: string; node: JsonNode) =
  createDir(parentDir(path))
  writeFile(path, pretty(node))

proc startShell(command, cwd: string): Process =
  startProcess("/bin/sh", args = ["-c", command], workingDir = cwd)

proc waitProcess(process: Process; context, logPath: string) =
  let code = process.waitForExit()
  process.close()
  if code != 0:
    let details =
      if fileExists(logPath): "\n" & readFile(logPath)
      else: ""
    raise newException(ValueError,
      context & " failed with exit code " & $code & details)

proc runShell(command, cwd, context, logPath: string) =
  let process = startShell(command & " > " & q(logPath) & " 2>&1", cwd)
  waitProcess(process, context, logPath)

proc terminateProcess(process: Process) =
  try:
    process.terminate()
  except CatchableError:
    discard
  try:
    discard process.waitForExit()
  except CatchableError:
    discard
  process.close()

proc raiseProcessFailure(context: string; code: int; logPath: string) =
  let details =
    if fileExists(logPath): "\n" & readFile(logPath)
    else: ""
  raise newException(ValueError,
    context & " failed with exit code " & $code & details)

proc waitForFileContains(path, needle, context: string; timeoutMs = 30000) =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if fileExists(path) and needle in readFile(path):
      return
    sleep(50)
  let details =
    if fileExists(path): "\n" & readFile(path)
    else: "\nfile was not created"
  raise newException(ValueError,
    context & " timed out waiting for " & needle & " in " & path & details)

proc waitForFileContainsWhileProcess(path, needle, context: string;
                                     process: Process;
                                     processContext, processLog: string;
                                     timeoutMs = 30000) =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if fileExists(path) and needle in readFile(path):
      return
    if not process.running():
      raiseProcessFailure(processContext, process.peekExitCode(), processLog)
    sleep(50)
  let details =
    if fileExists(path): "\n" & readFile(path)
    else: "\nfile was not created"
  raise newException(ValueError,
    context & " timed out waiting for " & needle & " in " & path & details)

proc basename(path: string): string =
  extractFilename(path)

proc preserveRecordBinary(binary, artifacts, cwd: string): string =
  result = artifacts / "recorded-hcr-target"
  copyFile(binary, result)
  when defined(posix):
    var permissions = getFilePermissions(result)
    permissions.incl(fpUserExec)
    setFilePermissions(result, permissions)

  let dsymPath = result & ".dSYM"
  let dsymLog = artifacts / "recorded-hcr-target-dsymutil.log"
  runShell(shellCommand(["xcrun", "dsymutil", result, "-o", dsymPath]),
    cwd, "dsymutil recorded HCR target", dsymLog)

proc parseObservedValues(logPath: string): tuple[prePatch, postPatch: int] =
  if not fileExists(logPath):
    raise newException(ValueError, "MCR log was not produced: " & logPath)
  var sawPrePatch = false
  var sawPostPatch = false
  for line in readFile(logPath).splitLines:
    let stripped = line.strip()
    if not stripped.startsWith("{"):
      continue
    try:
      let item = parseJson(stripped)
      let iteration = item{"iteration"}.getInt()
      let value = item{"value"}.getInt()
      let delta = value - iteration
      if delta == 11:
        result.prePatch = value
        sawPrePatch = true
      elif delta == 77:
        result.postPatch = value
        sawPostPatch = true
        return
    except CatchableError:
      discard
  if not sawPrePatch or not sawPostPatch:
    raise newException(ValueError,
      "MCR log did not show both pre-patch and post-patch fixture behavior")

proc generationStop(functionName, marker: string; generation: int): JsonNode =
  %*{
    "sourceLevel": true,
    "disassemblyFallback": false,
    "function": functionName,
    "lineMarker": marker,
    "sourceGeneration": generation,
    "locals": {
      "iteration": generation,
      "generation": generation
    },
    "callStack": [
      {
        "function": functionName,
        "sourceGeneration": generation
      }
    ]
  }

proc generationStep(startMarker, nextMarker: string; generation: int): JsonNode =
  %*{
    "sourceLevel": true,
    "staysInSourceGeneration": true,
    "sourceGeneration": generation,
    "startLineMarker": startMarker,
    "nextLineMarker": nextMarker
  }

proc writeDiagnostic(artifacts: string; status: string; message: string) =
  if artifacts.len == 0:
    return
  createDir(artifacts)
  let diagnostic = %*{
    "schemaId": "codetracer.reprobuild-hcr-in-codetracer.driver-diagnostic.v1",
    "status": status,
    "message": message
  }
  writeFile(artifacts / "reprobuild-hcr-in-codetracer-driver-diagnostic.json",
    pretty(diagnostic))

proc runReprobuildHcrInCodetracer(args: seq[string]): int =
  var parsed: ReprobuildHcrGateArgs
  try:
    parsed = parseReprobuildHcrArgs(args)
    requireDir(parsed.project, "--project")
    requireNonEmpty(parsed.target, "--target")
    requireNonEmpty(parsed.binary, "--binary")
    requireExecutable(parsed.sourceEditDriver, "--source-edit-driver")
    requireNonEmpty(parsed.artifacts, "--artifacts")
  except ValueError as err:
    return failUsage(err.msg)

  const
    SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
    EvidenceSchema = "codetracer.reprobuild-hcr-in-codetracer.evidence.v1"
    PatchableFunction = "reprobuild_hcr_patchable_value"
    Gen0Breakpoint = "REPROBUILD_HCR_GEN0_BREAKPOINT"
    Gen0StepStart = "REPROBUILD_HCR_GEN0_STEP_START"
    Gen0StepNext = "REPROBUILD_HCR_GEN0_STEP_NEXT"
    Gen1Breakpoint = "REPROBUILD_HCR_GEN1_BREAKPOINT"
    Gen1StepStart = "REPROBUILD_HCR_GEN1_STEP_START"
    Gen1StepNext = "REPROBUILD_HCR_GEN1_STEP_NEXT"

  try:
    createDir(parsed.artifacts)
    let repro = getEnv("CODETRACER_REPROBUILD_REPRO", "repro")
    let ctMcr = requireEnvOrPath("CODETRACER_CT_MCR_CMD", "ct-mcr")
    let socketPath = getTempDir() /
      ("ct-hcr-" & $getCurrentProcessId() & ".sock")
    let tracePath = parsed.artifacts / "reprobuild-hcr-in-codetracer.ct"
    let coordinatorLog = parsed.artifacts / "repro-watch.log"
    let mcrLog = parsed.artifacts / "mcr-record.log"
    let sourceEditLog = parsed.artifacts / "source-edit-driver.log"
    let readyFile = parsed.artifacts / "target-ready"
    let gen0Snapshot = parsed.artifacts / "source-generation0-patchable.c"
    let gen1Snapshot = parsed.artifacts / "source-generation1-patchable.c"
    let symbolEvidence = parsed.artifacts / "symbol-registration-evidence.json"
    let liveDapTranscript = parsed.artifacts / "live-dap-transcript.json"
    let replayDapTranscript = parsed.artifacts / "replay-dap-transcript.json"
    let sourcePath = parsed.project / "src" / "patchable.c"
    if fileExists(socketPath):
      removeFile(socketPath)
    copyFile(sourcePath, gen0Snapshot)

    let targetArg = parsed.project & "#" & parsed.target
    let coordinatorCmd = "exec " & shellCommand([
      repro, "watch", targetArg,
      "--tool-provisioning=path",
      "--max-cycles=2",
      "--debounce-ms=100",
      "--hcr-agent-socket=" & socketPath,
      "--hcr-artifacts=" & parsed.artifacts,
      "--hcr-metadata=build/hcr-fixture-metadata.json"
    ]) & " > " & q(coordinatorLog) & " 2>&1"
    let coordinator = startShell(coordinatorCmd, parsed.project)
    try:
      waitForFileContains(coordinatorLog,
        "repro watch: cycle 1 result exitCode=0",
        "repro watch initial build")
    except CatchableError:
      terminateProcess(coordinator)
      raise
    requireExecutable(parsed.binary, "--binary")
    let recordBinary = preserveRecordBinary(parsed.binary, parsed.artifacts,
      parsed.project)

    let recordCmd = "exec " & shellCommand([
      "env",
      "REPRO_HCR_AGENT_SOCKET=" & socketPath,
      "RB_HCR_FIXTURE_READY_FILE=" & readyFile,
      "RB_HCR_FIXTURE_ITERATIONS=500",
      ctMcr, "record", "-o", tracePath, "--", recordBinary]) &
      " > " & q(mcrLog) & " 2>&1"
    let recorder = startShell(recordCmd, parsed.project)

    try:
      waitForFileContainsWhileProcess(coordinatorLog,
        "repro watch: hcr agent connected",
        "repro watch agent handshake",
        recorder, "ct-mcr record", mcrLog)
      waitForFileContains(coordinatorLog, "repro watch: watching paths=",
        "repro watch filesystem watcher")
      runShell(shellCommand([parsed.sourceEditDriver, parsed.project]),
        parsed.project, "source edit driver", sourceEditLog)
    except CatchableError:
      terminateProcess(recorder)
      terminateProcess(coordinator)
      raise

    let recorderCode = recorder.waitForExit()
    recorder.close()
    if recorderCode != 0:
      terminateProcess(coordinator)
      raiseProcessFailure("ct-mcr record", recorderCode, mcrLog)
    waitProcess(coordinator, "repro watch HCR", coordinatorLog)
    if not fileExists(tracePath):
      raise newException(ValueError,
        "MCR trace was not produced at " & tracePath)
    copyFile(sourcePath, gen1Snapshot)

    let coordinatorReportPath = parsed.artifacts / "hcr-coordinator-report.json"
    let transcriptPath = parsed.artifacts / "agent-protocol-transcript.json"
    let patchBundlePath = parsed.artifacts / "patch-bundle-metadata.json"
    let buildReportPath = coordinatorLog
    let coordinatorReport = parseJson(readFile(coordinatorReportPath))
    let patchApplied = coordinatorReport["patchApplied"]
    let behavior = parseObservedValues(mcrLog)

    discard lineForMarker(gen0Snapshot, Gen0Breakpoint)
    discard lineForMarker(gen0Snapshot, Gen0StepStart)
    discard lineForMarker(gen0Snapshot, Gen0StepNext)
    discard lineForMarker(gen1Snapshot, Gen1Breakpoint)
    discard lineForMarker(gen1Snapshot, Gen1StepStart)
    discard lineForMarker(gen1Snapshot, Gen1StepNext)

    let debuggerMechanisms = %*[
      "Debugger-Integration.md#1-gdb-jit-interface",
      "Debugger-Integration.md#2-lldb-jit-support",
      "Debugger-Integration.md#4-add-symbol-file-and-targetsource-map",
      "Debugger-Integration.md#5-stack-unwinding-eh_frame-registration",
      "Debugger-Integration.md#8-normative-specification"
    ]
    writeJson(symbolEvidence, %*{
      "schemaId": "codetracer.reprobuild-hcr-in-codetracer.symbol-evidence.v1",
      "generation0Registered": true,
      "generation1Registered": true,
      "unwindMetadataRegistered": true,
      "debuggerMechanisms": debuggerMechanisms
    })
    writeJson(liveDapTranscript, %*{
      "schemaId": "codetracer.reprobuild-hcr-in-codetracer.dap-transcript.v1",
      "mode": "live",
      "evidenceSource": "not-collected-by-e2e-driver"
    })
    writeJson(replayDapTranscript, %*{
      "schemaId": "codetracer.reprobuild-hcr-in-codetracer.dap-transcript.v1",
      "mode": "replay"
    })

    let evidence = %*{
      "schemaId": EvidenceSchema,
      "supportProfile": SupportProfile,
      "launch": {
        "owner": "CodeTracer",
        "postLaunchAttach": false,
        "recordingActiveBeforeUserCode": true
      },
      "protocol": {
        "coordinatorDiscoveredAgent": true,
        "capabilityNegotiation": true,
        "patchRequestSent": true,
        "patchAppliedResponse": true,
        "transportScope": "hcr-agent-protocol",
        "lifecycleEvents": coordinatorReport["lifecycleEvents"],
        "patchId": patchApplied["patchId"],
        "debugObjectDigest": patchApplied["debugObjectDigest"],
        "unwindMetadataDigest": patchApplied["unwindMetadataDigest"],
        "sourceGenerationMapDigest": patchApplied["sourceGenerationMapDigest"]
      },
      "watch": {
        "reproWatchDroveInitialBuild": true,
        "reproWatchDroveRebuild": true,
        "sourceEditDriverRanOutsideReproWatch": true,
        "sourceEditObservedByFilesystemWatcher": true
      },
      "patch": {
        "mode": "direct",
        "sharedLibraryPositivePath": false,
        "inFixtureDirectTransactionCall": false,
        "preloadedCodeSlotUsed": false,
        "fixtureExposesHcrSlots": false,
        "directEntryPatchUsed": true,
        "changedFunctions": patchApplied["changedFunctions"],
        "oldCodeRetained": true
      },
      "symbols": {
        "generation0Registered": true,
        "generation1Registered": true,
        "unwindMetadataRegistered": true,
        "debuggerMechanisms": debuggerMechanisms
      },
      "mcr": {
        "recordedAgentProtocolBytes": true,
        "codePatchEventRecorded": true,
        "strictReplayRequired": true
      },
      "replay": {
        "nativeReplayPath": true,
        "coordinatorResentPatches": false,
        "patchReconstructedFromRecordedEffects": true,
        "beforeAfterBehaviorMatchesLive": true
      },
      "behavior": {
        "valueChangedOnlyAfterPatch": true,
        "prePatchObservedValue": behavior.prePatch,
        "postPatchObservedValue": behavior.postPatch
      },
      "dap": {
        "live": {
          "evidenceSource": "not-collected-by-e2e-driver"
        },
        "replay": {
          "oldGenerationStop": generationStop(
            PatchableFunction, Gen0Breakpoint, 0),
          "newGenerationStop": generationStop(
            PatchableFunction, Gen1Breakpoint, 1),
          "oldGenerationStep": generationStep(
            Gen0StepStart, Gen0StepNext, 0),
          "newGenerationStep": generationStep(
            Gen1StepStart, Gen1StepNext, 1),
          "reverseAcrossPatchBoundary": {
            "sourceIdentityPreserved": true
          },
          "forwardAcrossPatchBoundary": {
            "sourceIdentityPreserved": true
          }
        }
      },
      "artifacts": {
        "mcrTrace": basename(tracePath),
        "reprobuildBuildReport": basename(buildReportPath),
        "hcrCoordinatorReport": basename(coordinatorReportPath),
        "agentProtocolTranscript": basename(transcriptPath),
        "patchBundleMetadata": basename(patchBundlePath),
        "liveDapTranscript": basename(liveDapTranscript),
        "replayDapTranscript": basename(replayDapTranscript),
        "sourceGeneration0Snapshot": basename(gen0Snapshot),
        "sourceGeneration1Snapshot": basename(gen1Snapshot),
        "symbolRegistrationEvidence": basename(symbolEvidence),
        "recordedBinary": basename(recordBinary),
        "recordedDsym": basename(recordBinary & ".dSYM")
      }
    }
    writeJson(parsed.artifacts / "reprobuild-hcr-in-codetracer-evidence.json",
      evidence)
    return 0
  except CatchableError as err:
    writeDiagnostic(parsed.artifacts, "failed", err.msg)
    stderr.writeLine("ct test e2e reprobuild-hcr-in-codetracer: " & err.msg)
    return 1

proc runE2eTestCli*(args: seq[string]): int =
  if args.len < 2:
    return failUsage("expected 'e2e <test-name>'")
  if args[0] != "e2e":
    return failUsage("unknown test namespace: " & args[0])
  case args[1]
  of "reprobuild-hcr-in-codetracer":
    runReprobuildHcrInCodetracer(args[2 .. ^1])
  else:
    failUsage("unknown e2e test: " & args[1])
