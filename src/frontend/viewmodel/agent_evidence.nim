## The agent-evidence **notification** — the payload `ct agent evidence` hands
## CodeTracer, and the only thing the ViewModels know about that command.
##
## Agent Harbor and ACP agents only see ``ct agent evidence`` as a normal shell
## command.  The command notifies CodeTracer through this small JSON RPC
## payload so GUI and headless ViewModels can enter DeepReview.
##
## ## What lives here and what does not (RV-7)
##
## This module is the **wire type plus its codec**, and nothing else.  The
## command that produces it is `src/ct/agent_cli.nim`, beside `review_cli.nim`,
## because after RV-7 the two are one workflow —
##
## ```sh
## ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
## ct agent evidence review.json
## ```
##
## — and `ct agent evidence` resolves the dataset with the same routine
## `ct review <PATH>` resolves it with, and the agent session with the same
## routine `ct review collect` stamps it with (`ct/review_session.nim`).  Both
## of those live under `src/ct`, and a CLI in `src/frontend/viewmodel` could
## reach neither without dragging the whole ct-side dependency set into every
## ViewModel test compile.
##
## The split is also what keeps this file importable from the JavaScript
## backend: the renderer decodes an RPC payload
## (`AgenticSessionVM.handleAgentEvidenceRpcPayload`), and a renderer must not
## need `std/osproc` to do it.

import std/json

when not defined(js):
  import std/[os]

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
    datasetPath*: string
      ## RV-7 — the review dataset this evidence *is*.
      ##
      ## The argument of `ct agent evidence <PATH>`, resolved to the
      ## `review.json` the GUI opens.  Every other descriptive field below is
      ## read out of that file, so this is the one field from which the rest
      ## can be re-derived, and the one a consumer should prefer when it wants
      ## the whole review rather than the summary.
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

proc statusString*(status: AgentEvidenceStatus): string =
  ## The wire spellings, which are part of the RPC contract and therefore
  ## unchanged by RV-7 even where the *trigger* moved.  `malformed_metadata`
  ## used to mean "the `--metadata` JSON file would not parse"; that flag is
  ## retired and the status now means "the review dataset would not parse",
  ## which is the same failure about the same kind of document.  Renaming it
  ## would break every consumer that already matches on the string, for a
  ## cosmetic gain.
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
    "datasetPath": notification.datasetPath,
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
  # `getElems` rather than `items`, which dereferences its argument: this
  # decodes a payload that arrived over RPC, and a notification carrying no
  # changed files at all is a legitimate one (`no_recording` sends exactly
  # that).  Crashing the renderer on it would be the worst possible reading.
  for item in node{"files"}.getElems:
    files.add item.evidenceFileFromJson()
  AgentEvidenceNotification(
    sessionId: node{"sessionId"}.getStr(),
    taskId: node{"taskId"}.getStr(),
    tabId: node{"tabId"}.getStr(),
    workspacePath: node{"workspacePath"}.getStr(),
    datasetPath: node{"datasetPath"}.getStr(),
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
  const AgentEvidenceRpcPathEnvVar* = "CODETRACER_AGENT_EVIDENCE_RPC_PATH"
    ## Where `ct agent evidence` drops the notification for a running
    ## CodeTracer to pick up.  Unset in the ordinary case: the command still
    ## prints the notification on stdout, which is what a hook or a CI job
    ## reads, and the RPC file is only written when a GUI asked for one.

  proc defaultRpcSender*(notification: AgentEvidenceNotification) {.gcsafe.} =
    ## Hand the notification to a running CodeTracer, if one asked to be told.
    ##
    ## Deliberately silent when the variable is unset: an agent running
    ## `ct agent evidence` outside a CodeTracer session has still produced
    ## valid evidence, and failing because nobody was listening would make the
    ## command useless in exactly the batch/CI case it is most wanted in.
    let path = getEnv(AgentEvidenceRpcPathEnvVar, "")
    if path.len == 0:
      return
    createDir(path.parentDir)
    writeFile(path, $(%notification))
