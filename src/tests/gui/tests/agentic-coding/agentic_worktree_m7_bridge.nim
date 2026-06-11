## External-action helper for the M7 Agentic worktree GUI E2E.
##
## The running CodeTracer renderer owns all GUI/service/VM state.  This helper
## is intentionally limited to actions that need native process access from the
## test: observing the Agent Harbor scenario-run ``ct agent evidence`` command,
## converting the resulting worktree state into the CodeTracer RPC payload, and
## calling the real Agent Harbor task cancellation REST endpoint.  It never
## creates a ReplayDataStore, ViewModel, fake transport, or GUI snapshot.

import std/[json, os, osproc, sequtils, strutils, times]

import nim_agent_harbor
import nim_agents
import nim_everywhere

import agent_evidence

const
  ChangedFile = "src/feature.nim"

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc commandWithInput(command: string; input: string): tuple[output: string;
    exitCode: int] =
  let tmp = getTempDir() / ("codetracer-m7-http-body-" &
    $getCurrentProcessId() & "-" & $epochTime().int & ".json")
  writeFile(tmp, input)
  try:
    result = execCmdEx(command & " < " & tmp.shellQuote())
  finally:
    if fileExists(tmp):
      removeFile(tmp)

proc headerArgs(headers: openArray[HttpHeader]): string =
  for h in headers:
    if h.name.len > 0:
      result.add " -H " & (h.name & ": " & h.value).shellQuote()

proc curlTransport(): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    let curl = findExe("curl")
    if curl.len == 0:
      raise newException(OSError,
        "curl is required for the M7 real Agent Harbor REST helper")
    let bodyFile = getTempDir() / ("codetracer-m7-http-response-" &
      $getCurrentProcessId() & "-" & $epochTime().int)
    var command = curl.shellQuote() & " -sS -L -X " &
      req.httpMethod.httpMethodName().shellQuote() &
      req.headers.headerArgs() &
      " -w " & ("%{http_code}").shellQuote() &
      " -o " & bodyFile.shellQuote()
    if req.body.len > 0:
      command.add " --data-binary @-"
    command.add " " & req.url.shellQuote()

    let (output, code) =
      if req.body.len > 0: commandWithInput(command, req.body)
      else: execCmdEx(command)
    if code != 0:
      raise newException(OSError, "curl request failed: " & req.url & "\n" &
        output)
    try:
      result.status = output.strip().parseInt()
      result.body = if fileExists(bodyFile): readFile(bodyFile) else: ""
    finally:
      if fileExists(bodyFile):
        removeFile(bodyFile)

proc requirePayloadField(payload: JsonNode; name: string): string =
  result = payload{name}.getStr()
  if result.len == 0:
    raise newException(ValueError, "M7 external helper requires payload field `" &
      name & "`")

proc scenarioEffect(payload: JsonNode): JsonNode =
  let workspace = payload.requirePayloadField("agentWorkspacePath")
  let featurePath = workspace / ChangedFile
  let testPath = workspace / "feature_test.nim"
  if not fileExists(featurePath) or not fileExists(testPath):
    raise newException(ValueError,
      "M7 scenario-effect expected feature fixture files in " & workspace)
  writeFile(featurePath, "proc featureValue*(): int =\n  42\n")
  writeFile(testPath, "import src/feature\n\ndoAssert featureValue() == 42\n")
  %*{
    "applied": true,
    "workspace": workspace,
    "changedFile": ChangedFile
  }

proc decodeJsonByteArray(node: JsonNode): string =
  if node.isNil or node.kind != JArray:
    return ""
  for item in node.items:
    if item.kind != JInt:
      return ""
    let value = item.getInt()
    if value < 0 or value > 255:
      return ""
    result.add chr(value)

proc jsonContains(node: JsonNode; needle: string): bool =
  case node.kind
  of JString:
    node.getStr().contains(needle)
  of JObject:
    for _, value in node.pairs:
      if value.jsonContains(needle):
        return true
    false
  of JArray:
    let decoded = node.decodeJsonByteArray()
    if decoded.len > 0 and decoded.contains(needle):
      return true
    for value in node.items:
      if value.jsonContains(needle):
        return true
    false
  else:
    false

proc eventSummary(node: JsonNode): string =
  for key in ["command", "cmd", "message", "tool_name", "toolName"]:
    let value = node{key}
    if not value.isNil and value.kind == JString and value.getStr().len > 0:
      return value.getStr()
    if not value.isNil and value.kind == JArray:
      let decoded = value.decodeJsonByteArray()
      if decoded.len > 0:
        return decoded
  $node

proc requireScenarioEvidenceCommand(payload: JsonNode): JsonNode =
  let baseUrl = payload.requirePayloadField("agentHarborBaseUrl")
  let sessionId = payload.requirePayloadField("sessionId")
  let apiKey = payload{"agentHarborApiKey"}.getStr()
  var headers = @[header("Accept", "application/json")]
  if apiKey.len > 0:
    headers.add header("X-API-Key", apiKey)

  var lastBody = ""
  for _ in 0 ..< 600:
    let response = curlTransport().request(newRequest(
      hmGet, baseUrl.strip(chars = {'/'}) & "/api/v1/sessions/" & sessionId &
        "/events/history?limit=200", "", headers))
    if response.status >= 200 and response.status < 300:
      lastBody = response.body
      let history = parseJson(response.body)
      let events =
        if history.kind == JArray: history
        else: history{"events"}
      if not events.isNil:
        var commands = newJArray()
        for event in events.items:
          let summary = event.eventSummary()
          if summary.len > 0:
            commands.add %summary
          if event.jsonContains("ct agent evidence"):
            return %*{
              "observed": true,
              "configured": true,
              "source": "agent-harbor-history",
              "sessionId": sessionId,
              "commands": commands
            }
    else:
      lastBody = response.body
    sleep(200)

  raise newException(ValueError,
    "M7 GUI integration did not observe `ct agent evidence` in Agent Harbor " &
    "durable history for session " & sessionId & ". Last history response: " &
    lastBody)

proc observeEvidence(payload: JsonNode): JsonNode =
  let scenarioCommand = payload.requireScenarioEvidenceCommand()
  let tabId = payload.requirePayloadField("tabId")
  let workspace = payload.requirePayloadField("agentWorkspacePath")
  let traceDir = workspace / ".codetracer"
  createDir(traceDir)
  let notification = executeAgentEvidenceCommand(@[
      "--session", tabId,
      "--tab", tabId,
      "--workspace", workspace,
      "--trace-id", "trace-m7-001",
      "--trace-path", traceDir / "trace-m7-001",
      "--test-name",
      "e2e_agentic_worktree_session_progress_workspace_and_deepreview",
      "--test-command", "nim c -r feature_test.nim",
      "--exit-code", "0"
    ],
    cwd = workspace,
    sendRpc = proc(notification: AgentEvidenceNotification) {.gcsafe.} =
      discard)
  if notification.status != aesReady:
    raise newException(ValueError,
      "ct agent evidence did not produce ready DeepReview evidence: " &
      notification.status.statusString())
  result = %notification
  result["scenarioEvidenceCommand"] = scenarioCommand

proc cancel(payload: JsonNode): JsonNode =
  let baseUrl = payload.requirePayloadField("agentHarborBaseUrl")
  let taskId = payload.requirePayloadField("taskId")
  let sessionId = payload.requirePayloadField("sessionId")
  let apiKey = payload{"agentHarborApiKey"}.getStr()
  var headers = @[header("Accept", "application/json")]
  if apiKey.len > 0:
    headers.add header("X-API-Key", apiKey)
  let response = curlTransport().request(newRequest(
    hmDelete, baseUrl.strip(chars = {'/'}) & "/api/v1/tasks/" & taskId,
    "", headers))
  if response.status < 200 or response.status >= 300:
    raise newException(ValueError,
      "Agent Harbor task cancellation failed: HTTP " & $response.status &
      "\n" & response.body)
  var finalStatus = ""
  for _ in 0 ..< 20:
    let infoResponse = curlTransport().request(newRequest(
      hmGet, baseUrl.strip(chars = {'/'}) & "/api/v1/sessions/" & sessionId &
        "/info", "", headers))
    if infoResponse.status >= 200 and infoResponse.status < 300:
      let info = parseJson(infoResponse.body)
      finalStatus = info{"status"}.getStr("")
      if finalStatus == "cancelled":
        break
    sleep(100)
  %*{
    "cancelled": true,
    "taskId": taskId,
    "sessionId": sessionId,
    "finalStatus": finalStatus,
    "status": response.status,
    "body": response.body
  }

proc main() =
  let args = commandLineParams()
  if args.len < 2:
    quit "usage: agentic_worktree_m7_bridge <scenario-effect|observe-evidence|cancel> <payload-json>", 2
  let payload = parseFile(args[1])
  let response =
    case args[0]
    of "scenario-effect": scenarioEffect(payload)
    of "observe-evidence": observeEvidence(payload)
    of "cancel": cancel(payload)
    else:
      raise newException(ValueError,
        "M7 helper only supports external scenario-effect/observe-evidence/cancel actions, got: " &
        args[0])
  echo $response

when isMainModule:
  main()
