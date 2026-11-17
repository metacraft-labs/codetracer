## test_plat64_operation_mapping.nim — Input-Routing-And-Keymaps.md §3.2's
## mapping table, asserted complete in BOTH directions.
##
## The four action vocabularies dissolve into one naming scheme. This suite is
## what keeps that true while the vocabularies still exist:
##
##   * every `KeyAction` member but `kaNone` is one operation, and the table
##     runs both ways (`operation_dispatch`);
##   * every `ContextAction` member but `caNone` is one operation, and no two
##     members run one;
##   * every `ClientAction` member is an operation, or a Monaco command, or
##     retired, and exactly one of those;
##   * nothing in the three tables names an operation the catalogue does not
##     have, nor a member the enums do not have (the other direction);
##   * an operation table refuses a name no catalogue has, and refuses a name
##     twice.
##
## No mocks: the tables are the shipped constants, the enums the shipped enums.

import std/[sets, strutils, unittest]

import ../app/input/keymap
import ../app/input/operation_dispatch
import ../../headless_app/pane_clicks
import ../../viewmodel/keymap/[client_actions, operation_catalogue, base_rows]
import ../../viewmodel/input/operation_table

const FrontendSource = staticRead(
  "../../../common/common_types/codetracer_features/frontend.nim")

proc clientActionMembers(): seq[string] =
  ## `ClientAction`'s members, read off the enum's source: the module that
  ## declares it is a fragment of `common_types`, compiled with the whole
  ## desktop's types. The members are the only thing this suite needs.
  var inside = false
  for raw in FrontendSource.splitLines:
    let line = raw.strip
    if line.startsWith("ClientAction* = enum"):
      inside = true
      continue
    if not inside or line.len == 0 or line.startsWith("#"): continue
    let first = line.split({',', ' ', '='})[0]
    if first.len == 0 or not first[0].isLowerAscii or
       not first.allCharsInSet(IdentChars):
      break
    result.add first

proc named(text: string): bool =
  ## `text`, with its argument, names something a binding can run.
  operationProblem(text).len == 0

suite "the mapping table (Input-Routing §3.2)":
  test "every KeyAction is one operation, both directions":
    var seen = initHashSet[string]()
    for a in KeyAction:
      if a == kaNone: continue
      let op = operationOfAction(a)
      check op.len > 0
      if op.len == 0: checkpoint($a & " names no operation")
      check named(op)
      check not seen.containsOrIncl(op)
      check actionOfOperation(op) == a
    for (op, a) in OperationActions:
      check operationOfAction(a) == op

  test "every ContextAction is one operation, and no two members share it":
    var seen = initHashSet[string]()
    for a in ContextAction:
      let op = ContextActionOperations[a]
      if a == caNone:
        check op.len == 0
        continue
      check op.len > 0
      check named(op)
      if op in seen: checkpoint($a & " repeats " & op)
      check not seen.containsOrIncl(op)

  test "every ClientAction is an operation, a Monaco command or retired":
    var members = initHashSet[string]()
    check clientActionMembers().len > 150
    for name in clientActionMembers():
      members.incl name
      let mapped = operationOfClientAction(name).len > 0
      let monaco = name in MonacoClientActions
      let retired = name in RetiredClientActions
      if int(mapped) + int(monaco) + int(retired) != 1:
        checkpoint(name & ": mapped=" & $mapped & " monaco=" & $monaco &
                   " retired=" & $retired)
      check int(mapped) + int(monaco) + int(retired) == 1
    # The other direction: no table names a member that does not exist.
    for (op, action) in ClientActionOperations:
      if action notin members: checkpoint(action & " is no ClientAction")
      check action in members
      if not named(op): checkpoint(op & ": " & operationProblem(op))
      check named(op)
    for (op, action) in LegacyAliases:
      check action in members
      check named(op)
    for action in MonacoClientActions: check action in members
    for action in RetiredClientActions: check action in members

  test "an action is one operation, except the one named twice on purpose":
    # `findOrFilter` is the editor's find and the list's filter: one desktop
    # action the focus tells apart.
    var seen = initHashSet[string]()
    for (op, action) in ClientActionOperations:
      if action in seen:
        check action == "findOrFilter"
      seen.incl action
    for (op, action) in LegacyAliases:
      check action notin seen
      seen.incl action

suite "clicks as element references (§5.1)":
  test "every behaviour a front-end implements declares an operation":
    for b in ClickInventory:
      let implemented = b.terminal in {nsDone, nsExisting} or
                        b.gpui in {nsDone, nsExisting}
      let op = clickOperationOf(b.id)
      if implemented and op.len == 0:
        checkpoint(b.id & " " & b.target & " declares no operation")
      check (not implemented) or op.len > 0
      if op.len > 0 and op != GestureMachine:
        if not named(op): checkpoint(b.id & ": " & operationProblem(op))
        check named(op)

  test "the table names only rows of the inventory":
    for (id, _) in ClickOperations:
      check behaviour(id).id == id

suite "the operation table's shape (§3.1)":
  type Ctx = object
    ran: seq[string]

  proc hubOf(): OperationHub[int, Ctx] = newOperationHub[int, Ctx]()

  test "a name no catalogue has does not bind":
    let t = newOperationTable[int, Ctx]("test")
    expect OperationTableError:
      t.bindOp("debugger.no-such-operation",
           proc(c: OperationCall[int]; x: var Ctx): bool = true)

  test "a name bound twice does not bind":
    let t = newOperationTable[int, Ctx]("test")
    t.bindOp("debugger.step-over",
         proc(c: OperationCall[int]; x: var Ctx): bool = true)
    expect OperationTableError:
      t.bindOp("debugger.step-over",
           proc(c: OperationCall[int]; x: var Ctx): bool = true)

  test "the walk is innermost first, and an inactive table is passed over":
    let hub = hubOf()
    var overlayOpen = true
    let overlay = newOperationTable[int, Ctx]("overlay",
      proc(): bool = overlayOpen)
    overlay.bindOp("list.activate", proc(c: OperationCall[int]; x: var Ctx): bool =
      x.ran.add "overlay"
      true)
    let pane = newOperationTable[int, Ctx]("pane")
    pane.bindOp("list.activate", proc(c: OperationCall[int]; x: var Ctx): bool =
      x.ran.add "pane"
      true)
    hub.add overlay
    hub.add pane
    var ctx = Ctx()
    check hub.invoke(OperationCall[int](name: "list.activate"), ctx).table ==
      "overlay"
    overlayOpen = false
    check hub.invoke(OperationCall[int](name: "list.activate"), ctx).table ==
      "pane"
    check ctx.ran == @["overlay", "pane"]

  test "a procedure that declines passes the call on":
    let hub = hubOf()
    let inner = newOperationTable[int, Ctx]("inner")
    inner.bindOp("list.copy", proc(c: OperationCall[int]; x: var Ctx): bool = false)
    let outer = newOperationTable[int, Ctx]("outer")
    outer.bindOp("list.copy", proc(c: OperationCall[int]; x: var Ctx): bool =
      x.ran.add "outer"
      true)
    hub.add inner
    hub.add outer
    var ctx = Ctx()
    let r = hub.invoke(OperationCall[int](name: "list.copy"), ctx)
    check r.kind == oiRan
    check r.table == "outer"

  test "a disabled operation does not run and gives its reason (IR-6)":
    let hub = hubOf()
    let t = newOperationTable[int, Ctx]("t")
    t.bindOp("debugger.step-over",
         proc(c: OperationCall[int]; x: var Ctx): bool =
           x.ran.add "ran"
           true,
         proc(): Enablement = operationDisabled("no recording is loaded"))
    hub.add t
    var ctx = Ctx()
    let r = hub.invoke(OperationCall[int](name: "debugger.step-over"), ctx)
    check r.kind == oiDisabled
    check r.reason == "no recording is loaded"
    check ctx.ran.len == 0
    check hub.enablementOf("debugger.step-over").reason ==
      "no recording is loaded"

  test "an operation no table holds is absent, and says it is not available":
    let hub = hubOf()
    var ctx = Ctx()
    check hub.invoke(OperationCall[int](name: "list.copy"), ctx).kind == oiAbsent
    check "not available" in hub.enablementOf("list.copy").reason
