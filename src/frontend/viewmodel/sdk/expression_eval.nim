## sdk/expression_eval.nim — evaluate one expression at the current stop.
##
## THE SAME EVALUATOR AS A WATCH. The replay has no `evaluate` route: a watch
## expression is answered inside a `ct/load-locals` request, which carries the
## expressions in `watchExpressions` and returns each one's value marked
## `isWatch` (`db-backend/src/db.rs`, `watch_expression.rs`). This module sends
## exactly that request for ONE expression and reads exactly that answer, so a
## value obtained here and a watch of the same text in the State pane always
## agree. It does not touch the State pane's watch list and applies nothing to
## the store: the caller decides where the value goes.
##
## Its first caller is the VS Code editor's "Add to Scratchpad" on a selection
## that is not a local (Scratchpad-Pane.md § Adding Values, "An editor
## selection (VS Code)"); nothing in it is specific to that front-end.

import std/[json, strutils]

import isonim/core/[signals, async_compat]

import ../backend/backend_service
import ../store/[replay_data_store, types, locals_answer]
import ../../../common/value_presentation/value_model

type
  ExpressionAnswerKind* = enum
    eaValue     ## the replay evaluated the expression
    eaRefused   ## the replay answered with an error value (it cannot evaluate it)
    eaNoAnswer  ## the replay answered, but with no row for the expression
    eaFailed    ## the request failed, or its answer carried no values

  ExpressionAnswer* = object
    ## The outcome of one evaluation. `value` is the answer row for `eaValue`
    ## and `eaRefused`; `reason` says why there is no value for every kind
    ## but `eaValue`.
    expression*: string
    kind*: ExpressionAnswerKind
    value*: Variable
    reason*: string

proc isErrorValue*(v: Variable): bool =
  ## Whether the row is the replay's refusal (`watch_expression::refusal_value`,
  ## a value of kind `Error`) rather than a value.
  not v.presented.isNil and v.presented.kind == pvkError

proc expressionAnswerOf*(expression: string; response: JsonNode): ExpressionAnswer =
  ## Read `expression`'s answer out of a `ct/load-locals` response. Pure, so
  ## every outcome is testable without a backend.
  result = ExpressionAnswer(expression: expression)
  if not responseSucceeded(response):
    result.kind = eaFailed
    result.reason = "the replay could not evaluate it"
    return
  let answer = localsAnswerOf(responseBody(response))
  if not answer.ok:
    result.kind = eaFailed
    result.reason = "the replay answered without values"
    return
  for row in answer.rows:
    if row.isWatch and row.name == expression:
      result.value = row
      if row.isErrorValue:
        result.kind = eaRefused
        result.reason =
          if row.presented.text.len > 0: row.presented.text
          else: "the replay cannot evaluate it"
      else:
        result.kind = eaValue
      return
  result.kind = eaNoAnswer
  result.reason = "the replay gave no value for it at this stop"

proc evaluateAtStop*(store: ReplayDataStore; expression: string;
                     done: proc(answer: ExpressionAnswer)) =
  ## Evaluate `expression` at the stop the store is at, through the watch
  ## path, and call `done` once with the outcome. Sends one `ct/load-locals`
  ## whose only watch is `expression`; its locals are not applied.
  let expr = expression.strip
  let args = store.localsLoadArgs(store.debugger.val.rrTicks, @[expr])
  onComplete(store.backend.send("ct/load-locals", args),
    onSuccess = proc(response: JsonNode) =
      done(expressionAnswerOf(expr, response)),
    onError = proc(message: string) =
      done(ExpressionAnswer(expression: expr, kind: eaFailed,
        reason: "the replay could not evaluate it" &
                (if message.len > 0: ": " & message else: ""))))

proc scratchpadEntryOf*(answer: ExpressionAnswer): ScratchpadValueEntry =
  ## The scratchpad's entry for an evaluation: the value, or an ERROR VALUE
  ## (`isError`) whose text says why there is none — a miss is shown, not
  ## dropped (Scratchpad-Pane.md § Adding Values).
  if answer.kind == eaValue:
    let v = answer.value
    ScratchpadValueEntry(expression: answer.expression, valueText: v.value,
                         typeName: v.typeName, hasChildren: v.hasChildren,
                         children: v.children)
  else:
    ScratchpadValueEntry(expression: answer.expression,
                         valueText: answer.reason, isError: true)
