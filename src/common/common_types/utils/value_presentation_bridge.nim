## common_types/utils/value_presentation_bridge.nim — `Value -> PValue`.
##
## ## WHY THIS FILE IS `include`d RATHER THAN `import`ed
##
## For the same reason `text_representation.nim` beside it is. `Value` is
## defined inside `common_types`'s include set and is instantiated TWICE, under
## `langstring = string` (`src/common/types.nim`) and `langstring = cstring`
## (`src/frontend/types.nim`). A module that `import`ed `Value` would get
## whichever of the two its own importer happened to bind, and would then be
## incompatible with the other half of the program. Being `include`d means this
## file is compiled once per binding, against the `Value` that binding defines
## — which is the only way one adapter can serve both.
##
## `PValue` itself has no such problem: it is a plain tree of `string`, imported
## normally at the top of `common_types.nim`. So the OUTPUT of this bridge is
## one type with one spelling, which is exactly the property that lets the
## terminal (whose values arrive as `JsonNode`) and the desktop (whose values
## arrive as `Value`) reach the same presenter.
##
## ## `$` IS THE CONVERSION, AND IT IS THE ONLY ONE
##
## `langstring` is `string` on one side and `cstring` on the other; `$` is
## defined for both and is identity on the first. Nothing else in this file
## depends on the binding, which is why it compiles unchanged under each.

func presentationLangOf*(lang: Lang): PresentationLang =
  ## `common/lang.Lang` narrowed to the distinction PRESENTATION makes.
  ##
  ## Only Rust renders differently today (`vec![…]`, `Type{…}`), which is what
  ## `text_representation.textRepr`'s three-arm `case` said before this
  ## milestone: `LangRust` -> `textReprRust`, everything else ->
  ## `textReprDefault`. The narrowing is recorded here rather than in the
  ## presenter so that the presenter — the pure package — never has to know how
  ## many languages CodeTracer supports.
  case lang
  of LangRust: plRust
  of LangUnknown: plUnknown
  else: plOther

func toPValue*(value: Value; depth: int = 32): PValue =
  ## One `Value` as a `PValue`. Total: never nil, never raises.
  ##
  ## `depth` is a CYCLE guard and not a display policy — the display policy is
  ## the budget, applied later by the presenter. It is set well above the
  ## engine's own `depthLimit` (7) so it never truncates a well-formed value.
  if value.isNil:
    return PValue(kind: pvkNil)
  if depth <= 0:
    return PValue(kind: pvkNotExpanded, sourceKind: "NonExpanded")

  let typeName = if value.typ.isNil: "" else: $value.typ.langType
  let sourceKind = $value.kind

  template positional(): seq[PMember] =
    var acc: seq[PMember] = @[]
    for element in value.elements:
      acc.add PMember(label: "", value: toPValue(element, depth - 1))
    acc

  template labelled(): seq[PMember] =
    # `typ.labels` names an `Instance`'s fields. Where the labels run short of
    # the elements — a malformed or partial type — the member is emitted
    # POSITIONALLY rather than dropped: losing a field is worse than losing its
    # name, and `textReprDefault` indexed `value.typ.labels[i]` unguarded and
    # would raise on exactly this shape.
    var acc: seq[PMember] = @[]
    let names = if value.typ.isNil: @[] else: value.typ.labels
    for i, element in value.elements:
      let label = if i < names.len: $names[i] else: ""
      acc.add PMember(label: label, value: toPValue(element, depth - 1))
    acc

  case value.kind
  of Int:
    PValue(kind: pvkInt, typeName: typeName, sourceKind: sourceKind,
           text: $value.i)
  of Float:
    PValue(kind: pvkFloat, typeName: typeName, sourceKind: sourceKind,
           text: $value.f)
  of String, Literal:
    PValue(kind: pvkString, typeName: typeName, sourceKind: sourceKind,
           text: $value.text)
  of CString:
    PValue(kind: pvkCString, typeName: typeName, sourceKind: sourceKind,
           text: $value.cText)
  of Char:
    PValue(kind: pvkChar, typeName: typeName, sourceKind: sourceKind,
           text: $value.c)
  of Bool:
    PValue(kind: pvkBool, typeName: typeName, sourceKind: sourceKind,
           text: (if value.b: "true" else: "false"))
  of Seq, Set, HashSet, OrderedSet, Array, Varargs, Slice:
    PValue(kind: pvkSequence, typeName: typeName, sourceKind: sourceKind,
           members: positional(), partial: value.partiallyExpanded)
  of Instance:
    PValue(kind: pvkRecord, typeName: typeName, sourceKind: sourceKind,
           members: labelled(), partial: value.partiallyExpanded)
  of Tuple:
    PValue(kind: pvkTuple, typeName: typeName, sourceKind: sourceKind,
           members: positional(), partial: value.partiallyExpanded)
  of TableKind:
    var entries: seq[PEntry] = @[]
    for item in value.items:
      if item.len >= 2:
        entries.add PEntry(key: toPValue(item[0], depth - 1),
                           val: toPValue(item[1], depth - 1))
    PValue(kind: pvkMap, typeName: typeName, sourceKind: sourceKind,
           entries: entries, partial: value.partiallyExpanded)
  of Variant, Union:
    var members: seq[PMember] = @[]
    if not value.activeVariantValue.isNil:
      members.add PMember(label: "",
                          value: toPValue(value.activeVariantValue, depth - 1))
    else:
      members = labelled()
    PValue(kind: pvkVariant, typeName: typeName, sourceKind: sourceKind,
           variantName: $value.activeVariant, members: members,
           partial: value.partiallyExpanded)
  of Enum, Enum16, Enum32:
    # `enumInt` is a `BiggestInt` here and a decimal STRING on the wire; both
    # sides put the ordinal in `text` so the presenter has one rule.
    var enumName = ""
    if not value.typ.isNil and value.enumInt >= 0 and
       value.enumInt <= value.typ.enumNames.high:
      enumName = $value.typ.enumNames[value.enumInt]
    PValue(kind: pvkEnum, typeName: typeName, sourceKind: sourceKind,
           text: $value.enumInt, enumName: enumName)
  of Ref:
    PValue(kind: pvkReference, typeName: typeName, sourceKind: sourceKind,
           target: (if value.refValue.isNil: nil
                    else: toPValue(value.refValue, depth - 1)))
  of Pointer:
    PValue(kind: pvkPointer, typeName: typeName, sourceKind: sourceKind,
           text: $value.address,
           target: (if value.refValue.isNil: nil
                    else: toPValue(value.refValue, depth - 1)))
  of TypeKind.Error:
    PValue(kind: pvkError, typeName: typeName, sourceKind: sourceKind,
           text: $value.msg)
  of FunctionKind:
    PValue(kind: pvkFunction, typeName: typeName, sourceKind: sourceKind,
           text: $value.functionLabel)
  of Raw:
    PValue(kind: pvkRaw, typeName: typeName, sourceKind: sourceKind,
           text: $value.r)
  of Recursion:
    PValue(kind: pvkRecursion, typeName: typeName, sourceKind: sourceKind)
  of TypeKind.None:
    PValue(kind: pvkNil, typeName: typeName, sourceKind: sourceKind)
  of NonExpanded:
    PValue(kind: pvkNotExpanded, typeName: typeName, sourceKind: sourceKind)
  of TypeValue:
    PValue(kind: pvkOpaque, typeName: typeName, sourceKind: sourceKind,
           text: $value.base)
  else:
    # `C`, `Html`, `Any` and anything a later engine adds. The payload is kept
    # rather than dropped, for the reason both prior decoders gave: "" is
    # indistinguishable from "the debugger has no value for this".
    PValue(kind: pvkOpaque, typeName: typeName, sourceKind: sourceKind,
           text: (if value.text.len > 0: $value.text
                  elif value.r.len > 0: $value.r
                  else: ""))

func presentValue*(value: Value; budget: Budget; lang: Lang = LangUnknown): Presentation =
  ## THE ENTRY POINT EVERY DESKTOP SURFACE CALLS.
  ##
  ## `lang` is a PARAMETER with an explicit default and no global fallback.
  ## `textRepr`, which this replaces, read `common_lang.CURRENT_LANG` — a
  ## module-level `var` — whenever it was called without one, which was nearly
  ## every call site. So the same value rendered before and after a session
  ## switch produced different bytes with no argument having changed, and that
  ## is precisely what PLAT-2's "byte-identical across runs and across
  ## front-ends" forbids. A caller that wants the session's language now passes
  ## it, visibly, at the call site.
  present(toPValue(value), budget, presentationLangOf(lang))

func presentValueText*(value: Value; budget: Budget;
                       lang: Lang = LangUnknown): string =
  ## The one-line rendering alone, for the surfaces that are a line.
  presentValue(value, budget, lang).root.text
