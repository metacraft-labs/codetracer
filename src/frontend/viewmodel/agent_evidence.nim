## CodeTracer-owned agent evidence command/RPC helpers.
##
## Agent Harbor only sees ``ct agent evidence`` as a normal shell command.  The
## command records session-local metadata and notifies CodeTracer through this
## small JSON RPC payload so GUI and headless ViewModels can enter DeepReview.

import std/[json, strutils]

when not defined(js):
  import std/[os, osproc, sequtils, times]

type
  AgentEvidenceStatus* = enum
    aesReady
    aesNoRecording
    aesFailedTests
    aesMalformedMetadata
    aesDiffTraceMismatch

  AgentEvidenceFile* = object
    path*: string
    status*: string
    linesAdded*: int
    linesRemoved*: int
    diff*: string

  AgentEvidenceNotification* = object
    sessionId*: string
    taskId*: string
    tabId*: string
    workspacePath*: string
    traceId*: string
    tracePath*: string
    testName*: string
    testCommand*: string
    exitCode*: int
    status*: AgentEvidenceStatus
    statusMessage*: string
    createdAt*: string
    files*: seq[AgentEvidenceFile]
    rawMetadata*: JsonNode

  AgentEvidenceRpcSender* = proc(notification: AgentEvidenceNotification) {.gcsafe.}

  AgentEvidenceCliResult* = object
    handled*: bool
    exitCode*: int
    output*: string

proc statusString*(status: AgentEvidenceStatus): string =
  case status
  of aesReady: "ready"
  of aesNoRecording: "no_recording"
  of aesFailedTests: "failed_tests"
  of aesMalformedMetadata: "malformed_metadata"
  of aesDiffTraceMismatch: "diff_trace_mismatch"

proc parseEvidenceStatus*(value: string): AgentEvidenceStatus =
  case value
  of "ready", "passed", "pass", "ok": aesReady
  of "no_recording": aesNoRecording
  of "failed_tests", "failed", "failure": aesFailedTests
  of "malformed_metadata": aesMalformedMetadata
  of "diff_trace_mismatch", "mismatch": aesDiffTraceMismatch
  else: aesMalformedMetadata

proc `%`*(file: AgentEvidenceFile): JsonNode =
  %*{
    "path": file.path,
    "status": file.status,
    "linesAdded": file.linesAdded,
    "linesRemoved": file.linesRemoved,
    "diff": file.diff
  }

proc `%`*(notification: AgentEvidenceNotification): JsonNode =
  let metadata =
    if notification.rawMetadata.isNil: newJObject()
    else: notification.rawMetadata
  %*{
    "sessionId": notification.sessionId,
    "taskId": notification.taskId,
    "tabId": notification.tabId,
    "workspacePath": notification.workspacePath,
    "traceId": notification.traceId,
    "tracePath": notification.tracePath,
    "testName": notification.testName,
    "testCommand": notification.testCommand,
    "exitCode": notification.exitCode,
    "status": notification.status.statusString(),
    "statusMessage": notification.statusMessage,
    "createdAt": notification.createdAt,
    "files": notification.files,
    "metadata": metadata
  }

proc evidenceFileFromJson*(node: JsonNode): AgentEvidenceFile =
  AgentEvidenceFile(
    path: node{"path"}.getStr(),
    status: node{"status"}.getStr("modified"),
    linesAdded: node{"linesAdded"}.getInt(0),
    linesRemoved: node{"linesRemoved"}.getInt(0),
    diff: node{"diff"}.getStr())

proc evidenceNotificationFromJson*(node: JsonNode): AgentEvidenceNotification =
  var files: seq[AgentEvidenceFile] = @[]
  for item in node{"files"}.items:
    files.add item.evidenceFileFromJson()
  AgentEvidenceNotification(
    sessionId: node{"sessionId"}.getStr(),
    taskId: node{"taskId"}.getStr(),
    tabId: node{"tabId"}.getStr(),
    workspacePath: node{"workspacePath"}.getStr(),
    traceId: node{"traceId"}.getStr(),
    tracePath: node{"tracePath"}.getStr(),
    testName: node{"testName"}.getStr(),
    testCommand: node{"testCommand"}.getStr(),
    exitCode: node{"exitCode"}.getInt(0),
    status: parseEvidenceStatus(node{"status"}.getStr()),
    statusMessage: node{"statusMessage"}.getStr(),
    createdAt: node{"createdAt"}.getStr(),
    files: files,
    rawMetadata: node{"metadata"})

when not defined(js):
  proc parseArgs(args: openArray[string]): JsonNode =
    result = newJObject()
    var i = 0
    while i < args.len:
      let arg = args[i]
      if arg.startsWith("--") and i + 1 < args.len:
        result[arg[2 .. ^1]] = %args[i + 1]
        i += 2
      else:
        i += 1

  proc runGit(workspacePath: string; args: openArray[string]): string =
    let (output, code) = execCmdEx("git " & args.join(" "),
      workingDir = workspacePath)
    if code != 0:
      return ""
    output

  proc fileDiff(workspacePath, path: string): string =
    let quotedPath = "'" & path.replace("'", "'\\''") & "'"
    result = runGit(workspacePath, @["diff", "--", quotedPath])
    if result.len == 0:
      result = runGit(workspacePath, @["diff", "--cached", "--", quotedPath])

  proc collectChangedFiles*(workspacePath: string): seq[AgentEvidenceFile] =
    let statusOutput = runGit(workspacePath, @["status", "--porcelain"])
    let numstatOutput = runGit(workspacePath, @["diff", "--numstat"])
    var counts = newJObject()
    for line in numstatOutput.splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 3:
        let added = if parts[0] == "-": 0 else: parseInt(parts[0])
        let removed = if parts[1] == "-": 0 else: parseInt(parts[1])
        counts[parts[^1]] = %*{"added": added, "removed": removed}

    for line in statusOutput.splitLines():
      if line.len < 4:
        continue
      let status = line[0 .. 1].strip()
      var path = line[3 .. ^1]
      if " -> " in path:
        path = path.split(" -> ")[^1]
      let stat = counts{path}
      result.add AgentEvidenceFile(
        path: path,
        status: if status.len == 0: "modified" else: status,
        linesAdded: stat{"added"}.getInt(0),
        linesRemoved: stat{"removed"}.getInt(0),
        diff: fileDiff(workspacePath, path))

  proc validateNotification(notification: var AgentEvidenceNotification) =
    if notification.status != aesReady:
      return
    if notification.traceId.len == 0 and notification.tracePath.len == 0:
      notification.status = aesNoRecording
      notification.statusMessage = "no recorded trace was supplied"
    elif notification.exitCode != 0:
      notification.status = aesFailedTests
      notification.statusMessage = "recorded test command failed with exit code " &
        $notification.exitCode
    elif notification.files.len == 0 or notification.files.allIt(it.diff.len == 0):
      notification.status = aesDiffTraceMismatch
      notification.statusMessage = "recording has no matching workspace diff"

  proc defaultRpcSender*(notification: AgentEvidenceNotification) {.gcsafe.} =
    let path = getEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH", "")
    if path.len == 0:
      return
    createDir(path.parentDir)
    writeFile(path, $(%notification))

  proc executeAgentEvidenceCommand*(args: openArray[string]; cwd = getCurrentDir(
      ); sendRpc: AgentEvidenceRpcSender = defaultRpcSender):
      AgentEvidenceNotification =
    let parsed = parseArgs(args)
    var metadata = newJObject()
    let metadataPath = parsed{"metadata"}.getStr()
    if metadataPath.len > 0:
      try:
        metadata = parseFile(metadataPath)
      except CatchableError:
        metadata = %*{"error": "malformed metadata", "path": metadataPath}

    result = AgentEvidenceNotification(
      sessionId: parsed{"session"}.getStr(),
      taskId: parsed{"task"}.getStr(),
      tabId: parsed{"tab"}.getStr(parsed{"session"}.getStr()),
      workspacePath: parsed{"workspace"}.getStr(cwd),
      traceId: parsed{"trace-id"}.getStr(metadata{"traceId"}.getStr()),
      tracePath: parsed{"trace-path"}.getStr(metadata{"tracePath"}.getStr()),
      testName: parsed{"test-name"}.getStr(metadata{"testName"}.getStr()),
      testCommand: parsed{"test-command"}.getStr(metadata{"testCommand"}.getStr()),
      exitCode: parseInt(parsed{"exit-code"}.getStr("0")),
      status: parseEvidenceStatus(parsed{"status"}.getStr("ready")),
      statusMessage: parsed{"message"}.getStr(),
      createdAt: $now().utc(),
      rawMetadata: metadata)
    if result.status == aesReady and metadata.hasKey("error"):
      result.status = aesMalformedMetadata
      result.statusMessage = metadata{"error"}.getStr()
    if result.workspacePath.len > 0 and dirExists(result.workspacePath):
      result.files = collectChangedFiles(result.workspacePath)
    result.validateNotification()
    sendRpc(result)

  proc dispatchAgentEvidenceCli*(args: openArray[string]; cwd = getCurrentDir();
      sendRpc: AgentEvidenceRpcSender = defaultRpcSender): AgentEvidenceCliResult =
    if args.len >= 2 and args[0] == "agent" and args[1] == "evidence":
      let notification = executeAgentEvidenceCommand(args[2 .. ^1],
        cwd = cwd, sendRpc = sendRpc)
      result = AgentEvidenceCliResult(
        handled: true,
        exitCode: if notification.status ==
        aesReady: QuitSuccess else: QuitFailure,
        output: $(%notification))

  proc runAgentEvidenceCli*(args: openArray[string]; cwd = getCurrentDir();
      sendRpc: AgentEvidenceRpcSender = defaultRpcSender): int =
    let dispatch = dispatchAgentEvidenceCli(args, cwd = cwd, sendRpc = sendRpc)
    if not dispatch.handled:
      return QuitFailure
    echo dispatch.output
    dispatch.exitCode
