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
  PointerValue* = "0x7ffd0000 -> (42)"
  FieldValue* = "\"0x00000000000000000000000000000000000000000000000000000000000007d0\""
    ## A Noir field element, byte for byte as `noir_space_ship` records one.

proc byteValues(): seq[string] =
  result = @[]
  for i in 0 ..< ByteCount:
    result.add $(i * 17 mod 256)

proc localRoots(): seq[VarNode] =
  ## The top-level variables. One per formatter arm.
  @[
    VarNode(path: "@Locals.counter", name: "counter", typeName: "Int",
            value: "41"),
    VarNode(path: "@Locals.total", name: "total", typeName: "Int",
            value: "306"),
    VarNode(path: "@Locals.label", name: "label", typeName: "String",
            value: "\"shield online\""),
    VarNode(path: "@Locals.ratio", name: "ratio", typeName: "Float",
            value: "0.5"),
    VarNode(path: "@Locals.flag", name: "flag", typeName: "Bool",
            value: "true"),
    VarNode(path: "@Locals.missing", name: "missing", typeName: "NoneType",
            value: "nil"),
    VarNode(path: "@Locals.handle", name: "handle", typeName: "Pointer",
            value: PointerValue),
    VarNode(path: "@Locals.field", name: "field", typeName: "Field",
            value: FieldValue),
    VarNode(path: "@Locals.buffer", name: "buffer", typeName: "Bytes",
            value: "[" & byteValues().join(", ") & "]",
            memberCount: ByteCount,
            byteBuffer: byteBufferOf(byteValues())),
    VarNode(path: "@Locals.point", name: "point", typeName: StructTypeName,
            value: "{x: 10, y: 20}", memberCount: PointMemberCount),
    VarNode(path: "@Locals.wide", name: "wide", typeName: "Dict",
            value: "[(\"key_000\", 0), (\"key_001\", 2)]",
            memberCount: WideMemberCount),
  ]

proc pointMembers(): seq[VarNode] =
  @[
    VarNode(path: "@Locals.point.x", name: "x", typeName: "Int", value: "10"),
    VarNode(path: "@Locals.point.y", name: "y", typeName: "Int", value: "20"),
  ]

proc wideMember(index: int): VarNode =
  let key = "key_" & align($index, 3, '0')
  VarNode(path: "@Locals.wide.[" & $index & "]", name: "[" & $index & "]",
          typeName: "Tuple",
          value: "(\"" & key & "\", " & $(index * 2) & ")",
          memberCount: 2)

proc byteMember(index: int): VarNode =
  VarNode(path: "@Locals.buffer.[" & $index & "]", name: "[" & $index & "]",
          typeName: "Int", value: byteValues()[index])

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
