## test_expression_eval.nim — reading one expression's value out of a
## `ct/load-locals` answer (`sdk/expression_eval`), the watch path the
## editor's "Add to Scratchpad" evaluates through (Scratchpad-Pane.md § Adding
## Values, "An editor selection (VS Code)").
##
## No backend: `expressionAnswerOf` is pure over the response, and the
## responses below are the wire shapes the replay's watch evaluator writes
## (`db-backend/src/db.rs`: a value marked `isWatch`;
## `watch_expression::refusal_value`: an `Error` value carrying `msg`). The
## request itself is exercised over the VS Code host in `test_vscode_host`.

import std/[json, unittest]

import ../../sdk/expression_eval
import ../../store/types

proc answer(rows: JsonNode): JsonNode = %*{"locals": rows}

suite "an expression's answer":
  test "the watch row of that expression is its value":
    let a = expressionAnswerOf("p.x + 1", answer(%*[
      {"expression": "p.x + 1", "value": {"kind": 7, "i": "1"}},
      {"expression": "p.x + 1",
       "value": {"kind": 7, "i": "43", "isWatch": true}}]))
    check a.kind == eaValue
    check a.value.value == "43"
    let e = scratchpadEntryOf(a)
    check e.expression == "p.x + 1" and e.valueText == "43" and not e.isError

  test "a local of the same name is not the watch's answer":
    let a = expressionAnswerOf("x", answer(%*[
      {"expression": "x", "value": {"kind": 7, "i": "1"}}]))
    check a.kind == eaNoAnswer

  test "a refusal is an error value carrying the replay's reason":
    let a = expressionAnswerOf("q.z", answer(%*[{"expression": "q.z",
      "value": {"kind": 24, "msg": "no variable named `q`", "isWatch": true}}]))
    check a.kind == eaRefused
    check a.reason == "no variable named `q`"
    let e = scratchpadEntryOf(a)
    check e.isError and e.valueText == "no variable named `q`"

  test "a failed request and an answer without values are errors":
    check expressionAnswerOf("x", newJNull()).kind == eaFailed
    check expressionAnswerOf("x", %*{}).kind == eaFailed
    check scratchpadEntryOf(expressionAnswerOf("x", newJNull())).isError
