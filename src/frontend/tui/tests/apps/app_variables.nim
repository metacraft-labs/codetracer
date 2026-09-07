## app_variables.nim — CTUI-7 snapshot app: the variables and scopes pane.
##
## One component tree, exported so the Tier-1 half of
## `tests/real_terminal/test_real_variables_pane.nim` composites the SAME proc
## in process that this binary composites in a pty. See
## `testing/test_app_runtime.nim` for the runtime and the frame barrier.
##
## ## WHY THE TREE IS A CONSTANT AND NOT A FIXTURE
##
## A snapshot app is a BINARY spawned in a pty; it cannot open a `.ct` container
## because `app/`'s facade withholds `headless_session` and `dual_snap` compiles
## this file with the Tier-1 flags. So the data is a constant — and that is the
## same arrangement CTUI-5's `app_source_pane.nim` and CTUI-6's
## `app_call_stack.nim` use, for the same reason. What the fixtures establish is
## asserted at Tier 1, where a real session exists; what a TERMINAL does with a
## painted screen is asserted here.
##
## The constant is chosen to put **every formatter arm on one real screen**,
## including the three CTUI-1's corpus does not produce — a byte buffer, a
## pointer with a dereferenced target, and a labelled struct. That asymmetry is
## deliberate and is recorded in `app/formatters/type_formatters.nim`'s header:
## no recorder in this workspace emits them, so they would otherwise be rendered
## by nothing.
##
## ## THE `[MOD]` BADGE IS ON EXACTLY ONE ROW, AND IT IS DRIVEN BY A REAL DIFF
##
## The badge is not set by hand. Two ticks are fed into a real `ValueTimeline`
## and `diffAt` decides — so the screen the Tier-2 case reads is produced by the
## same diff engine the Tier-1 suites drive against `calc`, and a mutation to
## that engine moves this screen too.
##
## ## THE TIER-1 HALF MUST NOT DRIVE INPUT
##
## `buildTree` is a pure function of `(cols, rows, step)` and nothing here holds
## mutable state between frames, so `runDualSnap`'s Tier-1 half and the child in
## the pty build the same tree at the same step. CTUI-6's app had to say this as
## a warning because its model was a `var`; this one cannot have the problem.

import std/[strutils, tables]

import isonim_tui

import ../../app/views/variables
import ../../../../common/value_presentation

## ## PLAT-2: THE CONSTANT IS A VALUE NOW, NOT A RENDERING OF ONE
##
## Every `VarNode` below used to carry a hand-written `value: string` — the
## rendering somebody typed out, which the pane then classified by looking at
## its brackets. The screen was therefore produced from bytes no decoder had
## ever emitted, and the one thing a snapshot app exists to check — that the
## pane draws what the product draws — was true only as far as the typing was.
##
## Each row now carries a `PValue`, built the same way
## `value_presentation/json_adapter.toPValue` builds one from a `ct/load-locals`
## response, and `value` is `presenter.present`'s answer at the `tui-value`
## budget: the same call `headless_session.variableFromPValue` makes. So a
## change to the presenter moves this screen, which is the property that makes
## the Tier-2 case evidence about the product rather than about this file.
const
  WideMemberCount* = 600
    ## The `wide_state` fixture's own member count, so the pagination the pane
    ## does on a real terminal is the pagination it does on the real trace.
  PointMemberCount* = 2
  ByteCount* = 12

  ModifiedName* = "total"
    ## The one variable whose value differs between the two ticks below.
  UnmodifiedName* = "counter"
  AnchorTick* = 100'u64
  CurrentTick* = 101'u64

  StructTypeName* = "Point"
  PointerAddress* = "0x7ffd0000"
  FieldText* = "0x00000000000000000000000000000000000000000000000000000000000007d0"
    ## A Noir field element, byte for byte as `noir_space_ship` records one —
    ## the raw payload, unquoted. `noir_space_ship` records it as a `String`,
    ## so the quotation marks on screen are the STRING presenter's and are not
    ## part of the value.

proc byteValues(): seq[int] =
  result = @[]
  for i in 0 ..< ByteCount:
    result.add(i * 17 mod 256)

proc intValue(text, typeName: string): PValue =
  PValue(kind: pvkInt, text: text, typeName: typeName, sourceKind: "Int")

proc pointerValueOf*(): PValue =
  ## A pointer with a dereferenced target. CTUI-1's corpus produces none, which
  ## is why it is constructed — see this module's header.
  PValue(kind: pvkPointer, typeName: "Pointer", sourceKind: "Pointer",
         text: PointerAddress, target: intValue("42", "Int"))

proc fieldValueOf*(): PValue =
  ## A Noir field element. Recorded as a `String` whose text is a `0x…` literal,
  ## which is why `value_model.classOf` reads the SPELLING for this one case.
  PValue(kind: pvkString, typeName: "Field", sourceKind: "String",
         text: FieldText)

let
  PointerValue* = present(pointerValueOf(), tuiValueBudget()).root.text
  FieldValue* = present(fieldValueOf(), tuiValueBudget()).root.text
    ## Exported for the Tier-2 case, which asserts these strings appear on a
    ## real terminal. DERIVED rather than written down: a hand-written copy
    ## would keep the case green through a change to the presenter, which is
    ## precisely the regression the case exists to catch.

proc bufferValueOf(): PValue =
  var members: seq[PMember] = @[]
  for b in byteValues():
    members.add member("", intValue($b, "Int"))
  PValue(kind: pvkSequence, typeName: "Bytes", sourceKind: "Seq",
         members: members)

proc pointValueOf(): PValue =
  PValue(kind: pvkRecord, typeName: StructTypeName, sourceKind: "Instance",
         members: @[member("x", intValue("10", "Int")),
                    member("y", intValue("20", "Int"))])

proc wideEntry(index: int): PValue =
  let key = "key_" & align($index, 3, '0')
  PValue(kind: pvkTuple, typeName: "Tuple", sourceKind: "Tuple",
         members: @[
           member("", PValue(kind: pvkString, text: key, typeName: "String",
                             sourceKind: "String")),
           member("", intValue($(index * 2), "Int"))])

proc wideValueOf(): PValue =
  ## The `wide_state` fixture's 600-entry mapping, on the wire as a `Seq` of
  ## `Tuple`s — which is how a Python dict actually arrives, measured rather
  ## than assumed (`headless_session`'s note on `SequenceKinds`).
  var members: seq[PMember] = @[]
  for i in 0 ..< WideMemberCount:
    members.add member("", wideEntry(i))
  PValue(kind: pvkSequence, typeName: "Dict", sourceKind: "Seq",
         members: members)

proc node(path, name: string; pv: PValue; memberCount = 0): VarNode =
  ## One row, with `value` DERIVED from `pv` by the same call the product makes.
  VarNode(path: path, name: name,
          typeName: (if pv.isNil: "" else: pv.typeName),
          value: present(pv, tuiValueBudget()).root.text,
          memberCount: memberCount, presented: pv)

proc localRoots(): seq[VarNode] =
  ## The top-level variables. One per presenter.
  @[
    node("@Locals.counter", "counter", intValue("41", "Int")),
    node("@Locals.total", "total", intValue("306", "Int")),
    node("@Locals.label", "label",
         PValue(kind: pvkString, text: "shield online", typeName: "String",
                sourceKind: "String")),
    node("@Locals.ratio", "ratio",
         PValue(kind: pvkFloat, text: "0.5", typeName: "Float",
                sourceKind: "Float")),
    node("@Locals.flag", "flag",
         PValue(kind: pvkBool, text: "true", typeName: "Bool",
                sourceKind: "Bool")),
    node("@Locals.missing", "missing",
         PValue(kind: pvkNil, typeName: "NoneType", sourceKind: "None")),
    node("@Locals.handle", "handle", pointerValueOf()),
    node("@Locals.field", "field", fieldValueOf()),
    node("@Locals.buffer", "buffer", bufferValueOf(), ByteCount),
    node("@Locals.point", "point", pointValueOf(), PointMemberCount),
    node("@Locals.wide", "wide", wideValueOf(), WideMemberCount),
  ]

proc pointMembers(): seq[VarNode] =
  @[
    node("@Locals.point.x", "x", intValue("10", "Int")),
    node("@Locals.point.y", "y", intValue("20", "Int")),
  ]

proc wideMember(index: int): VarNode =
  node("@Locals.wide.[" & $index & "]", "[" & $index & "]",
       wideEntry(index), 2)

proc byteMember(index: int): VarNode =
  node("@Locals.buffer.[" & $index & "]", "[" & $index & "]",
       intValue($byteValues()[index], "Int"))

proc sampleChildren*(): NodeChildren =
  ## The lazy-population seam, over the constant above.
  ##
  ## Answers a WINDOW, exactly as `app/variables_binding.nodeChildrenFor` does
  ## over a real `StateVM`: a 600-member node hands out one page and reports its
  ## total, so the `… N more` row on a real terminal is produced by the same
  ## arithmetic a real trace produces it by.
  result = proc(path: string; offset, limit: int):
      tuple[nodes: seq[VarNode]; total: int] =
    result = (nodes: @[], total: 0)
    var all: seq[VarNode] = @[]
    case path
    of "@Locals":
      all = localRoots()
    of "@Locals.point":
      all = pointMembers()
    of "@Locals.wide":
      result.total = WideMemberCount
      for i in max(0, offset) ..< min(WideMemberCount, offset + limit):
        result.nodes.add wideMember(i)
      return
    of "@Locals.buffer":
      for i in 0 ..< ByteCount:
        all.add byteMember(i)
    else:
      return
    result.total = all.len
    for i in max(0, offset) ..< min(all.len, offset + limit):
      result.nodes.add all[i]

proc sampleTimeline*(): ValueTimeline =
  ## Two observed ticks whose difference is exactly `total`.
  ##
  ## Fed through the real `ValueTimeline`, so the badge on screen is `diffAt`'s
  ## answer and not a flag this file set.
  result = initValueTimeline()
  var before = initTable[string, string]()
  var after = initTable[string, string]()
  for node in localRoots():
    let path = variablePathOf(node.path)
    before[path] = (if node.name == ModifiedName: "264" else: node.value)
    after[path] = node.value
  result.observe(AnchorTick, before)
  result.observe(CurrentTick, after)

proc modelFor*(step: int): VariablesModel =
  ## The pane at `step`. A pure function: step 0 shows the roots, step 1 opens
  ## the struct, step 2 also opens the 600-member node, and step 3 scrolls to
  ## the end of it — which is the only way the `… N more` affordance can be on
  ## screen, since a page of 100 members is four times taller than the terminal
  ## the Tier-2 case runs at.
  let timeline = sampleTimeline()
  result = initVariablesModel(
    scopes = @[
      Scope(kind: skLocals, availability: savaAvailable),
      Scope(kind: skArguments, availability: savaUnsupported,
            note: "no per-frame argument surface"),
      Scope(kind: skWatches, availability: savaAvailable),
    ],
    children = sampleChildren(),
    diff = timeline.diffAt(CurrentTick),
    tickLabel = "@" & $CurrentTick)
  result.expandNode("@Locals")
  result.selected = "@Locals." & ModifiedName
  result.focused = result.selected
  if step >= 1:
    result.expandNode("@Locals.point")
  if step >= 2:
    result.expandNode("@Locals.wide")
  if step >= 3:
    # Past the end on purpose: `variables.clampScrollTop` pins it to the last
    # full page, so the app does not have to know the terminal's height to ask
    # for its bottom.
    result.scrollTop = high(int) div 2

proc initialModel*(): VariablesModel =
  modelFor(0)

proc screenFor*(model: VariablesModel; cols, rows: int): VariablesScreen =
  ## The pane's screen at this geometry — where the `[MOD]` badge and the
  ## cursor are.
  variablesScreen(model, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
  ## The whole screen: this pane, over the full geometry.
  renderVariablesTree(modelFor(step), r, cols, rows)

proc buildTree*(r: TerminalRenderer; cols, rows: int): TerminalNode =
  ## The un-stepped shape, for `runDualSnap`'s sized overload.
  buildTree(r, cols, rows, 0)

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an unused
  # runtime with it.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(
    proc(r: TerminalRenderer; cols, rows, step: int): TerminalNode =
      buildTree(r, cols, rows, step),
    commandLineParams()))
