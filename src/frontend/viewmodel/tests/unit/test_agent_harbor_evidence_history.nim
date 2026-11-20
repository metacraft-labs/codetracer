## A worktree agent session's DeepReview evidence is read from Agent Harbor's
## event history (codetracer-pm DeepReview/Agentic-Coding-Integration.md
## §6.8): the session's agent runs `ct agent evidence`, which prints its
## notification on stdout, and Harbor keeps that output in the session's
## durable history. `agent_evidence.evidenceFromHarborHistory` finds it there.
##
## The histories below are written in the shapes Harbor's
## `GET /api/v1/sessions/<id>/events/history` answers with: an object holding
## `events`, or a bare array; tool output as a string, or as a JSON array of
## byte values. The notification is the JSON `ct agent evidence` prints
## (`$(%notification)`), so the found object decodes with
## `evidenceNotificationFromJson`.

import std/[json, options, strutils, unittest]

import ../../agent_evidence

proc bytes(text: string): JsonNode =
  result = newJArray()
  for ch in text:
    result.add %ord(ch)

const Notification = """{"sessionId":"s-1","taskId":"t-1","tabId":"agent:harbor:s-1","workspacePath":"/w","datasetPath":"/w/.ct/review/review.json","traceId":"trace-1","tracePath":"/w/.ct/runs/trace-1","testName":"feature","testCommand":"nim c -r feature_test.nim","exitCode":0,"status":"ready","statusMessage":"","files":[]}"""

suite "evidence from an Agent Harbor session's history":

  test "a tool call's stdout carrying the notification is found":
    let history = %*{"events": [
      {"type": "tool_use", "toolName": "runCmd",
       "args": {"command": "ct agent evidence .ct/review/review.json"}},
      {"type": "stdout", "content": "collecting...\n" & Notification & "\n"},
      {"type": "completion", "exitCode": 0}]}
    let found = evidenceFromHarborHistory(history)
    check found.isSome
    let n = evidenceNotificationFromJson(found.get)
    check n.sessionId == "s-1"
    check n.datasetPath == "/w/.ct/review/review.json"
    check n.status == aesReady

  test "output kept as a byte array, in a bare array of events, is found":
    let history = %*[{"type": "stdout", "content": bytes(Notification & "\n")}]
    let found = evidenceFromHarborHistory(history)
    check found.isSome and found.get["traceId"].getStr == "trace-1"

  test "the latest notification wins":
    let later = Notification.replace("trace-1", "trace-2")
    let history = %*{"events": [
      {"type": "stdout", "content": Notification},
      {"type": "stdout", "content": later}]}
    check evidenceFromHarborHistory(history).get["traceId"].getStr == "trace-2"

  test "a history with no notification has none":
    let history = %*{"events": [
      {"type": "stdout", "content": "ct agent evidence recorded trace-m7-001"},
      {"type": "stdout", "content": "{\"not\": \"evidence\"}"},
      {"type": "status", "status": "running"}]}
    check evidenceFromHarborHistory(history).isNone
    check evidenceFromHarborHistory(newJNull()).isNone
    check evidenceFromHarborHistory(%*{"events": "broken"}).isNone

  test "lines that open with a brace but are not JSON do not end the search":
    # Harbor's history keeps the agent's command text too: a heredoc of the
    # review dataset has lines such as `{` and `{"path": "src/feature.nim",`.
    # On the JavaScript backend `parseJson` reports them with JavaScript's
    # `SyntaxError`, which is not a `CatchableError`, and it ended the search
    # before the notification was reached (the `vm-unit-js` lane runs this).
    let command = "set -eu\ncat > .ct/review/review.json <<'JSON'\n{\n" &
      "  \"files\": [{\"path\": \"src/feature.nim\",\n}\nJSON\n" &
      "ct agent evidence .ct/review/review.json"
    let history = %*{"events": [
      {"type": "tool_result", "tool_output": Notification & "\n"},
      {"type": "tool_use", "tool_name": "runCmd",
       "tool_args": {"command": "{\n" & command}}]}
    let found = evidenceFromHarborHistory(history)
    check found.isSome
    check found.isSome and found.get["traceId"].getStr == "trace-1"

  test "a history handed over JSON-encoded, as a string, is read":
    # The renderer's transport can answer with the document as a JSON string
    # (`nim_agents.client.changedFiles` unwraps the same): the product found
    # no evidence in a history that held it.
    let document = %*{"events": [
      {"type": "tool_result", "tool_output": Notification & "\n"}]}
    let found = evidenceFromHarborHistory(%($document))
    check found.isSome and found.get["traceId"].getStr == "trace-1"
    check evidenceFromHarborHistory(%"not json").isNone
