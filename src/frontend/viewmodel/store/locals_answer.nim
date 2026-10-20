## store/locals_answer.nim
##
## The ONE decoder of a `ct/load-locals` answer into the store's `Variable`
## rows, for every front-end.
##
## It used to live in `headless_session.nim`, which is native-only (it spawns
## `replay-server`), so only the terminal and GPUI could decode an answer into
## the ViewModel layer; the web read its answers through the legacy
## `StateComponent`. Moving it here, beside the store it fills, is what lets
## the shared stop loader (`sdk/stop_loader.nim`) apply the answer on every
## backend.
##
## THIS MODULE DOES NOT RENDER VALUES. It decodes the wire into `PValue` and
## hands it to the one presenter (`common/value_presentation`, PLAT-2), at a
## budget it declares by name. The history of the renderer that used to stand
## here — the fourth of seven "value -> string" implementations — is kept in
## `src/common/value_presentation_bridge_test.nim`'s header.

import std/json

import ../../../common/value_presentation
import ../../../common/value_presentation/json_adapter
import types, stop_timeline
import ../viewmodels/origin_chain_types

type
  LocalsAnswer* = object
    ## One decoded `ct/load-locals` answer, not yet applied to a store.
    ok*: bool
      ## The backend answered with a locals list.
    rows*: seq[Variable]
      ## Locals and watch answers together, watches marked `isWatch`; the
      ## split is `ReplayDataStore.applyLocalsResponse`'s.
    requestedAt*: StopStamp
      ## The stop the request was SENT at, stamped by whoever sent it
      ## (`ReplayDataStore.stopStamp`, immediately before the send). It is
      ## what `applyLocalsResponse` reconciles against the stop the store is
      ## at when the answer is applied (PLAT-29).
    origins*: seq[(string, OriginSummary)]
      ## Each local's `originSummary` (Value Origin Tracking, spec §3.2.3),
      ## by expression — what the desktop's `state.syncOriginSummaries`
      ## reads off the same answer for the state rows' origin badges.

proc valueTypeName*(valueNode: JsonNode): string =
  ## `Value.typ.langType`, or "" when the response carries no type.
  json_adapter.typeNameOf(valueNode)

proc valuePresentation*(valueNode: JsonNode; budget: Budget): Presentation =
  ## One wire value, presented at `budget`. THE decoding entry point.
  present(json_adapter.toPValue(valueNode), budget)

proc presentedValueText*(valueNode: JsonNode;
                         budget: Budget = tuiValueBudget()): string =
  ## The single-line rendering a `store/types.Variable` carries.
  valuePresentation(valueNode, budget).root.text

proc variableFromPValue*(name: string; pv: PValue): Variable =
  ## One `Variable` and, RECURSIVELY, its members.
  ##
  ## THE RECURSION IS THE POINT: the engine's answer already carries the whole
  ## subtree (bounded by the request's `depthLimit`), and a decoder that built
  ## children without `hasChildren`/`children` turned every compound member —
  ## each `(key, value)` tuple of a mapping — into a leaf that could not be
  ## opened.
  ##
  ## PLAT-2: THE ROW CARRIES THE VALUE, NOT ONLY ITS RENDERING. `presented` is
  ## the normalised value, so a pane that knows its own width asks the
  ## presenter for a rendering that fits it; `value` is the presenter's answer
  ## at `tui-value`.
  result = Variable(name: name,
                    value: present(pv, tuiValueBudget()).root.text,
                    typeName: (if pv.isNil: "" else: pv.typeName),
                    presented: pv)
  if pv.isNil:
    return
  # A BUDGET CUT, not `pv.partial` (which says the RECORDING is short): the
  # engine held back elements past `elementsTotal`'s first ones.
  let held = (if pv.kind == pvkMap: pv.entries.len else: pv.members.len)
  result.moreElements = pv.elementsTotal > held
  result.elementsTotal = (if result.moreElements: pv.elementsTotal else: 0)
  if pv.kind == pvkMap:
    if pv.entries.len == 0:
      return
    result.hasChildren = true
    for entry in pv.entries:
      # A map's child is named by its KEY's own rendering, at the row's
      # budget; a `TableKind` carries `items`, not `elements`.
      result.children.add variableFromPValue(
        present(entry.key, tuiValueBudget()).root.text, entry.val)
    return
  if not isContainer(pv.kind) or pv.members.len == 0:
    return
  result.hasChildren = true
  for idx, m in pv.members:
    let childName = if m.label.len > 0: m.label else: "[" & $idx & "]"
    result.children.add variableFromPValue(childName, m.value)

proc variableFromValue*(name: string; valueNode: JsonNode): Variable =
  ## One wire variable, decoded and presented.
  variableFromPValue(name, json_adapter.toPValue(valueNode))

proc localsAnswerOf*(body: JsonNode): LocalsAnswer =
  ## Decode the `body` of a `ct/load-locals` response
  ## (`{"locals": [{"expression", "value", "originSummary"?}, …]}`). `ok` is
  ## false when the body carries no `locals` list.
  if body.isNil or body.kind != JObject:
    return
  let localsNode = body.getOrDefault("locals")
  if localsNode.isNil or localsNode.kind != JArray:
    return
  for localNode in localsNode:
    let valueNode = localNode.getOrDefault("value")
    var parsed = variableFromValue(
      localNode.getOrDefault("expression").getStr(""), valueNode)
    # Watch answers ride the same list, marked `value.isWatch`.
    parsed.isWatch = valueNode.getOrDefault("isWatch").getBool(false)
    result.rows.add(parsed)
    let origin = localNode.getOrDefault("originSummary")
    if not origin.isNil and origin.kind == JObject:
      result.origins.add((parsed.name, parseOriginSummary(origin)))
  result.ok = true
