## The wire encoding of the values a flow update carries (`ct/updated-flow`):
## default-valued fields elided by the replay server, restored here before a
## front end reads the update.
##
## The replay server elides, on the values of a flow's steps
## (`viewUpdates[].steps[].beforeValues` and `.afterValues`), every field whose
## value is its default, and marks the update `valueEncoding:
## "elided-defaults-1"` (`libs/ct-flow-wire`, which holds the same table). A
## front end restores the defaults before it reads the update, and refuses an
## encoding it does not know rather than read a value with fields missing as
## one whose fields are empty. An update without the marker carries its values
## whole and is read as it is.
##
## One table, two walks: `restoreElidedFlowValues` on a `JsonNode` (the view
## models, native and in the browser) and, in a JavaScript build,
## `restoreElidedFlowValuesJs` on the raw event object (the desktop front end,
## which reads the event without parsing it into a `JsonNode`).

import std/json

const
  FlowValueEncodingField* = "valueEncoding"
  ElidedDefaultsV1* = "elided-defaults-1"

  ## A `Value` node's fields and their defaults (`kind` and `typ` are always
  ## written).
  ValueDefaults* = [
    ("activeVariant", "\"\""), ("activeVariantValue", "null"),
    ("address", "\"\""), ("b", "false"), ("c", "\"\""), ("cText", "\"\""),
    ("elements", "[]"), ("elementsTotal", "0"), ("f", "\"\""), ("i", "\"\""),
    ("isMutable", "false"), ("isWatch", "false"), ("msg", "\"\""),
    ("r", "\"\""), ("refValue", "null"), ("text", "\"\"")]
  ## A `Type` node's fields and their defaults (`kind` is always written).
  TypeDefaults* = [
    ("cType", "\"\""), ("elementType", "null"), ("labels", "[]"),
    ("langType", "\"\""), ("memberTypes", "[]")]

proc restoreFields(node: JsonNode; table: openArray[(string, string)]) =
  for (key, default) in table:
    if not node.hasKey(key):
      node[key] = parseJson(default)

proc restoreType(node: JsonNode) =
  if node.isNil or node.kind != JObject: return
  restoreFields(node, TypeDefaults)
  restoreType(node{"elementType"})
  let members = node{"memberTypes"}
  if not members.isNil and members.kind == JArray:
    for member in members: restoreType(member)

proc restoreValue(node: JsonNode) =
  if node.isNil or node.kind != JObject: return
  restoreFields(node, ValueDefaults)
  let elements = node{"elements"}
  if not elements.isNil and elements.kind == JArray:
    for element in elements: restoreValue(element)
  restoreValue(node{"refValue"})
  restoreValue(node{"activeVariantValue"})
  restoreType(node{"typ"})

proc restoreElidedFlowValues*(update: JsonNode): string =
  ## Restore what the replay server elided from `update`'s step values, in
  ## place, and drop the marker. Returns "" when the update can be read, or
  ## why it cannot: an encoding this reader does not know.
  if update.isNil or update.kind != JObject or not update.hasKey(FlowValueEncodingField):
    return ""
  let encoding = update[FlowValueEncodingField]
  if encoding.kind != JString or encoding.getStr != ElidedDefaultsV1:
    return "a flow update encodes its values as " & $encoding &
      ", which this reader does not know (it reads \"" & ElidedDefaultsV1 & "\")"
  let views = update{"viewUpdates"}
  if not views.isNil and views.kind == JArray:
    for view in views:
      let steps = view{"steps"}
      if steps.isNil or steps.kind != JArray: continue
      for step in steps:
        for side in ["beforeValues", "afterValues"]:
          let values = step{side}
          if values.isNil or values.kind != JObject: continue
          for _, value in values.pairs: restoreValue(value)
  update.delete(FlowValueEncodingField)
  ""

when defined(js):
  import std/jsffi

  proc jsParse(text: cstring): JsObject {.importjs: "JSON.parse(#)".}
  proc jsHas(o: JsObject; key: cstring): bool {.importjs: "(Object.prototype.hasOwnProperty.call(#, #))".}
  proc jsIsObject(o: JsObject): bool {.importjs: "((o) => o !== null && typeof o === 'object' && !Array.isArray(o))(#)".}
  proc jsIsArray(o: JsObject): bool {.importjs: "Array.isArray(#)".}
  proc jsLen(o: JsObject): int {.importjs: "#.length".}
  proc jsKeys(o: JsObject): seq[cstring] {.importjs: "Object.keys(#)".}
  proc jsDelete(o: JsObject; key: cstring) {.importjs: "delete #[#]".}
  proc jsIsString(o: JsObject): bool {.importjs: "(typeof # === 'string')".}

  proc restoreFieldsJs(node: JsObject; table: openArray[(string, string)]) =
    for (key, default) in table:
      if not jsHas(node, cstring(key)):
        node[cstring(key)] = jsParse(cstring(default))

  proc restoreTypeJs(node: JsObject) =
    if node.isNil or not jsIsObject(node): return
    restoreFieldsJs(node, TypeDefaults)
    restoreTypeJs(node[cstring"elementType"])
    let members = node[cstring"memberTypes"]
    if jsIsArray(members):
      for i in 0 ..< jsLen(members): restoreTypeJs(members[i])

  proc restoreValueJs(node: JsObject) =
    if node.isNil or not jsIsObject(node): return
    restoreFieldsJs(node, ValueDefaults)
    let elements = node[cstring"elements"]
    if jsIsArray(elements):
      for i in 0 ..< jsLen(elements): restoreValueJs(elements[i])
    restoreValueJs(node[cstring"refValue"])
    restoreValueJs(node[cstring"activeVariantValue"])
    restoreTypeJs(node[cstring"typ"])

  proc restoreElidedFlowValuesJs*(update: JsObject): cstring =
    ## `restoreElidedFlowValues` on the raw event object.
    if update.isNil or not jsIsObject(update) or not jsHas(update, cstring(FlowValueEncodingField)):
      return cstring""
    let encoding = update[cstring(FlowValueEncodingField)]
    if not jsIsString(encoding) or encoding.to(cstring) != cstring(ElidedDefaultsV1):
      return cstring("a flow update encodes its values in an encoding this reader does not know (it reads \"" &
        ElidedDefaultsV1 & "\")")
    let views = update[cstring"viewUpdates"]
    if jsIsArray(views):
      for v in 0 ..< jsLen(views):
        let steps = views[v][cstring"steps"]
        if not jsIsArray(steps): continue
        for s in 0 ..< jsLen(steps):
          for side in ["beforeValues", "afterValues"]:
            let values = steps[s][cstring(side)]
            if values.isNil or not jsIsObject(values): continue
            for key in jsKeys(values): restoreValueJs(values[key])
    jsDelete(update, cstring(FlowValueEncodingField))
    cstring""
