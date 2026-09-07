## value_presentation/json_adapter.nim — a `ct/load-locals` `Value` on the wire,
## normalised into `PValue`.
##
## ## WHY THIS EXISTS AS A SEPARATE ADAPTER
##
## `viewmodel/headless_session.nim` — the ONLY path by which the terminal
## front-end, the headless app and the Embed SDK see a value — cannot import
## `common_types`, because that module is `include`d twice under incompatible
## `langstring` bindings (see `value_model.nim`'s header, and
## `viewmodels/state_vm.nim`'s). Before PLAT-2 it answered that by
## reimplementing the whole renderer over `JsonNode` (`extractValueText`).
##
## This module is the same 1:1 wire decode WITHOUT the renderer: it produces a
## `PValue` and stops. The rendering it used to do is now `presenter.present`'s,
## which is the same function the desktop calls.
##
## ## THE ORDINALS ARE THE WIRE'S AND ARE WRITTEN OUT
##
## `TypeKind` is serialised as its ORDINAL, so this file has to know the
## enum's order. That is a wire contract, not an implementation detail, and it
## is the reason the constants below are duplicated from
## `common_types/language_features/type.nim` rather than imported: importing
## them is exactly what is impossible here. `src/common/
## value_presentation_bridge_test.nim` asserts the two tables agree — suite
## "PLAT-2: the wire ordinals in json_adapter ARE TypeKind's" — so a member
## inserted into `TypeKind` reddens a test instead of silently shifting every
## kind by one.

import std/json

import value_model

const
  tkSeq* = 0
  tkSet* = 1
  tkHashSet* = 2
  tkOrderedSet* = 3
  tkArray* = 4
  tkVarargs* = 5
  tkStruct* = 6      ## `Instance`
  tkInt* = 7
  tkFloat* = 8
  tkString* = 9
  tkCString* = 10
  tkChar* = 11
  tkBool* = 12
  tkLiteral* = 13
  tkRef* = 14
  tkRecursion* = 15
  tkRaw* = 16
  tkEnum* = 17
  tkEnum16* = 18
  tkEnum32* = 19
  tkC* = 20
  tkTable* = 21
  tkUnion* = 22
  tkPointer* = 23
  tkError* = 24
  tkFunction* = 25
  tkTypeValue* = 26
  tkTuple* = 27
  tkVariant* = 28
  tkHtml* = 29
  tkNone* = 30
  tkNonExpanded* = 31
  tkAny* = 32
  tkSlice* = 33

  WireKindNames*: array[34, string] = [
    "Seq", "Set", "HashSet", "OrderedSet", "Array", "Varargs", "Instance",
    "Int", "Float", "String", "CString", "Char", "Bool", "Literal", "Ref",
    "Recursion", "Raw", "Enum", "Enum16", "Enum32", "C", "TableKind", "Union",
    "Pointer", "Error", "FunctionKind", "TypeValue", "Tuple", "Variant",
    "Html", "None", "NonExpanded", "Any", "Slice"]
    ## `TypeKind`'s members, in ordinal order. The `sourceKind` a `PValue`
    ## carries comes from here, which is what lets the presenter pick `@[` for a
    ## `Seq` and `HashSet{` for a `HashSet` from a wire that only sent `0` and
    ## `2`.

  MaxWireDepth* = 32
    ## A guard against a CYCLIC response, not a display policy — the budget is
    ## the display policy and it is applied later, by the presenter. Set well
    ## above the engine's own `depthLimit` (7 in every request this repository
    ## makes) so it never truncates a well-formed answer.

func wireKindName*(kind: int): string =
  if kind >= 0 and kind < WireKindNames.len: WireKindNames[kind] else: ""

proc typeNameOf*(node: JsonNode): string =
  ## `Value.typ.langType`, or "" when the response carries no type.
  if node.isNil or node.kind != JObject:
    return ""
  let typ = node.getOrDefault("typ")
  if typ.isNil or typ.kind != JObject:
    return ""
  typ.getOrDefault("langType").getStr("")

proc labelsOf(node: JsonNode): seq[string] =
  result = @[]
  if node.isNil or node.kind != JObject:
    return
  let typ = node.getOrDefault("typ")
  if typ.isNil or typ.kind != JObject:
    return
  let labels = typ.getOrDefault("labels")
  if labels.isNil or labels.kind != JArray:
    return
  for label in labels:
    result.add label.getStr("")

proc elementsOf(node: JsonNode): JsonNode =
  if node.isNil or node.kind != JObject:
    return nil
  let elements = node.getOrDefault("elements")
  if elements.isNil or elements.kind != JArray: nil else: elements

proc toPValue*(node: JsonNode; depth: int = MaxWireDepth): PValue =
  ## One wire `Value` as a `PValue`. Total: an unrecognised kind becomes
  ## `pvkOpaque` carrying whatever scalar payload arrived, never nil.
  if node.isNil or node.kind != JObject:
    return PValue(kind: pvkNil)
  if depth <= 0:
    return PValue(kind: pvkNotExpanded, sourceKind: "NonExpanded")

  let kind = node.getOrDefault("kind").getInt(-1)
  let typeName = typeNameOf(node)
  let sourceKind = wireKindName(kind)
  let partial = node.getOrDefault("partiallyExpanded").getBool(false)

  template scalarOf(k: PValueKind; field: string): PValue =
    PValue(kind: k, typeName: typeName, sourceKind: sourceKind,
           text: node.getOrDefault(field).getStr(""))

  # `labelled` decides whether the members get names. `Instance` is the only
  # kind whose wire labels ARE its members' names: the wire fills a tuple's
  # labels with `["0", "1"]`, so honouring them everywhere would render a
  # dictionary entry as `(0: "key_000", 1: 0)` — a positional pair dressed up
  # as a record whose fields are named after their own indices. That was
  # `headless_session.memberLabels`'s decision and it is preserved here.
  proc membersOf(labelled: bool): seq[PMember] =
    result = @[]
    let elements = elementsOf(node)
    if elements.isNil:
      return
    let labels = if labelled: labelsOf(node) else: @[]
    for idx in 0 ..< elements.len:
      let label = if idx < labels.len: labels[idx] else: ""
      result.add PMember(label: label, value: toPValue(elements[idx], depth - 1))

  case kind
  of tkInt: scalarOf(pvkInt, "i")
  of tkFloat: scalarOf(pvkFloat, "f")
  of tkString, tkLiteral: scalarOf(pvkString, "text")
  of tkCString: scalarOf(pvkCString, "cText")
  of tkChar: scalarOf(pvkChar, "c")
  of tkBool:
    PValue(kind: pvkBool, typeName: typeName, sourceKind: sourceKind,
           text: (if node.getOrDefault("b").getBool(false): "true" else: "false"))
  of tkSeq, tkSet, tkHashSet, tkOrderedSet, tkArray, tkVarargs, tkSlice:
    PValue(kind: pvkSequence, typeName: typeName, sourceKind: sourceKind,
           members: membersOf(false), partial: partial)
  of tkStruct:
    PValue(kind: pvkRecord, typeName: typeName, sourceKind: sourceKind,
           members: membersOf(true), partial: partial)
  of tkTuple:
    PValue(kind: pvkTuple, typeName: typeName, sourceKind: sourceKind,
           members: membersOf(false), partial: partial)
  of tkTable:
    # `Value.items` is a list of two-element `[key, value]` arrays.
    var entries: seq[PEntry] = @[]
    let items = node.getOrDefault("items")
    if not items.isNil and items.kind == JArray:
      for item in items:
        if item.kind == JArray and item.len >= 2:
          entries.add PEntry(key: toPValue(item[0], depth - 1),
                             val: toPValue(item[1], depth - 1))
    PValue(kind: pvkMap, typeName: typeName, sourceKind: sourceKind,
           entries: entries, partial: partial)
  of tkUnion, tkVariant:
    let active = node.getOrDefault("activeVariantValue")
    var members: seq[PMember] = @[]
    if not active.isNil and active.kind == JObject:
      members.add PMember(label: "", value: toPValue(active, depth - 1))
    else:
      members = membersOf(true)
    PValue(kind: pvkVariant, typeName: typeName, sourceKind: sourceKind,
           variantName: node.getOrDefault("activeVariant").getStr(""),
           members: members, partial: partial)
  of tkEnum, tkEnum16, tkEnum32:
    # The ordinal rides `i` as a STRING and the member names ride `typ.labels`.
    # Out of range the ordinal is kept and `enumName` stays empty, which is what
    # makes the presenter print `Colour(7)` instead of a bare `7` that reads as
    # an integer variable beside a name-shaped column.
    let ordinalText = node.getOrDefault("i").getStr("")
    let labels = labelsOf(node)
    var enumName = ""
    var ordinal = -1
    if isDecimalIntegerText(ordinalText) and ordinalText[0] != '-':
      ordinal = 0
      for ch in ordinalText:
        ordinal = ordinal * 10 + (ord(ch) - ord('0'))
        if ordinal > 1_000_000:
          ordinal = -1
          break
    if ordinal >= 0 and ordinal < labels.len and labels[ordinal].len > 0:
      enumName = labels[ordinal]
    PValue(kind: pvkEnum, typeName: typeName, sourceKind: sourceKind,
           text: ordinalText, enumName: enumName)
  of tkRef:
    let target = node.getOrDefault("refValue")
    PValue(kind: pvkReference, typeName: typeName, sourceKind: sourceKind,
           target: (if target.isNil or target.kind != JObject: nil
                    else: toPValue(target, depth - 1)))
  of tkPointer:
    let target = node.getOrDefault("refValue")
    PValue(kind: pvkPointer, typeName: typeName, sourceKind: sourceKind,
           text: node.getOrDefault("address").getStr(""),
           target: (if target.isNil or target.kind != JObject: nil
                    else: toPValue(target, depth - 1)))
  of tkError:
    PValue(kind: pvkError, typeName: typeName, sourceKind: sourceKind,
           text: node.getOrDefault("msg").getStr(""))
  of tkFunction:
    PValue(kind: pvkFunction, typeName: typeName, sourceKind: sourceKind,
           text: node.getOrDefault("functionLabel").getStr(""))
  of tkRaw:
    PValue(kind: pvkRaw, typeName: typeName, sourceKind: sourceKind,
           text: node.getOrDefault("r").getStr(""))
  of tkRecursion:
    PValue(kind: pvkRecursion, typeName: typeName, sourceKind: sourceKind)
  of tkNone:
    PValue(kind: pvkNil, typeName: typeName, sourceKind: sourceKind)
  of tkNonExpanded:
    PValue(kind: pvkNotExpanded, typeName: typeName, sourceKind: sourceKind)
  else:
    # An unknown kind keeps whatever scalar payload arrived, for the reason
    # `extractValueText`'s `else` arm gave: "" is indistinguishable from "the
    # debugger has no value for this" everywhere downstream.
    let i = node.getOrDefault("i").getStr("")
    PValue(kind: pvkOpaque, typeName: typeName,
           sourceKind: (if sourceKind.len > 0: sourceKind else: "Unknown"),
           text: (if i.len > 0: i else: node.getOrDefault("text").getStr("")))
