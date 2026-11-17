## operation_table.nim — THE OPERATION TABLE: a pane's or a session's named
## operations bound to the procedures that perform them, and the one route
## from a resolved name to one of those procedures.
##
## Owns: Input-Routing-And-Keymaps.md §3.1's table as a value — an entry names
## an operation, says whether it is enabled (with a reason when it is not), and
## names the action procedure that performs it — and `invoke`, which walks a
## session's tables innermost first and reports what happened.
##
## Refuses to own: the closed set of names, their argument schemas and labels
## (`keymap/operation_catalogue` and the editing vocabulary), keys and their
## resolution (`keymap/keymap_router`), and what an operation does: an entry
## only NAMES the procedure, which remains a ViewModel's or a host's and is
## still called directly by code (ViewModel-Architecture §9.3).
##
## ## WHY THE TABLE IS GENERIC
##
## The shared half of a call is its name and its binding's literal argument. A
## front-end adds two things only it can type: `T`, what a pointer or a context
## menu hit-tested the operation onto (the native front-ends use
## `headless_app/pane_clicks.ContextTarget`), and `C`, the mutable context of
## one dispatch (the terminal's `RuntimeOutcome`).
##
## ## THE WALK
##
## `hub.tables` is in precedence order, innermost first, the order the router's
## layers are consulted in: an overlay before the focused pane, the pane before
## the session. A table that is not `active` is passed over. The first entry
## found decides: disabled stops the walk and gives the reason (IR-6), an action
## answering `false` declines ("not on this row") and the walk goes on.
##
## Pure; compiles on C, JS and wasm32.

import std/[sets, strutils, tables]

import ../keymap/operation_catalogue
import ../editor/operations

type
  Enablement* = object
    ## An operation's answer to "can you run now?" A disabled answer carries
    ## what to tell the user (Keyboard-Shortcuts-System: *"inert and says so"*).
    enabled*: bool
    reason*: string

  OperationCall*[T] = object
    name*: string
      ## The operation, without its argument (`layout.focus-pane`).
    argument*: string
      ## The binding's literal argument (`file-tree`), or "".
    args*: OpArgs
      ## A vocabulary operation's typed arguments.
    nowMs*: int64
    target*: T
      ## What a pointer gesture or a context menu hit-tested this onto; the
      ## default value for a key.
    pointer*: bool
      ## Reached by a pointer gesture, so `target` is meaningful.
    menu*: bool
      ## Chosen from the element's context menu (`pointer` is set too): the
      ## entry's own procedure, not the element's press, performs it.

  OperationAction*[T, C] = proc(call: OperationCall[T]; ctx: var C): bool {.closure.}
    ## Performs the operation. `false`: not this table's after all; the walk
    ## goes on (a list pane's move while the pane is empty stays the pane's and
    ## answers `true`).

  EnablementProc* = proc(): Enablement {.closure.}

  OperationEntry*[T, C] = object
    name*: string
    enablement*: EnablementProc
      ## nil: always enabled.
    action*: OperationAction[T, C]

  OperationTable*[T, C] = ref object
    owner*: string
      ## Who publishes it: `palette`, `pane:problems`, `session`.
    active*: proc(): bool {.closure.}
      ## nil: always consulted. An overlay's table is active while it is open,
      ## a pane's while it has the focus.
    entries: Table[string, OperationEntry[T, C]]
    order: seq[string]

  OperationHub*[T, C] = ref object
    tables*: seq[OperationTable[T, C]]

  InvokeKind* = enum
    oiRan = "ran"
    oiDisabled = "disabled"
    oiAbsent = "absent"

  InvokeResult* = object
    kind*: InvokeKind
    table*: string
      ## The owner of the table that decided; "" when absent.
    reason*: string
      ## Why it is disabled.

  OperationTableError* = object of CatchableError

const
  AlwaysEnabled* = Enablement(enabled: true, reason: "")

  ListMoveOperations* = @[
    "list.focus-next", "list.focus-previous", "list.focus-first",
    "list.focus-last", "list.focus-page-down", "list.focus-page-up",
    "editor.scroll-line-down", "editor.scroll-line-up"]
    ## The moves a list pane takes: the list table's, and the modal bases' `j` /
    ## `k`, which a list pane reads as its next and previous row.

func operationDisabled*(reason: string): Enablement =
  Enablement(enabled: false, reason: reason)

proc isKnownOperation*(name: string): bool =
  ## A catalogued name (it has a namespace) or the editing vocabulary's.
  if '.' in name: isCatalogued(name) else: operationNamed(name) >= 0

proc newOperationTable*[T, C](owner: string;
                              active: proc(): bool {.closure.} = nil):
    OperationTable[T, C] =
  OperationTable[T, C](owner: owner, active: active,
                       entries: initTable[string, OperationEntry[T, C]]())

proc newOperationHub*[T, C](): OperationHub[T, C] =
  OperationHub[T, C](tables: @[])

proc add*[T, C](hub: OperationHub[T, C]; table: OperationTable[T, C]) =
  hub.tables.add table

proc bindOp*[T, C](table: OperationTable[T, C]; name: string;
               action: OperationAction[T, C];
               enablement: EnablementProc = nil) =
  ## Bind `name` to `action`. RAISES on a name no catalogue knows and on a
  ## second entry for one name: both are programming errors a table must not
  ## survive, and every suite that builds the table then fails by name.
  if not isKnownOperation(name):
    raise newException(OperationTableError, table.owner & ": '" & name &
                       "' is not an operation")
  if name in table.entries:
    raise newException(OperationTableError, table.owner & ": '" & name &
                       "' is bound twice")
  table.entries[name] = OperationEntry[T, C](name: name, action: action,
                                             enablement: enablement)
  table.order.add name

proc onEach*[T, C](table: OperationTable[T, C]; names: openArray[string];
                   action: OperationAction[T, C];
                   enablement: EnablementProc = nil) =
  ## One procedure for several names, told apart by `call.name`.
  for name in names:
    table.bindOp(name, action, enablement)

func holds*[T, C](table: OperationTable[T, C]; name: string): bool =
  name in table.entries

func operationNames*[T, C](table: OperationTable[T, C]): seq[string] =
  ## The names this table binds, in the order they were bound.
  table.order

proc isActive[T, C](table: OperationTable[T, C]): bool =
  table.active.isNil or table.active()

proc enablementOf*[T, C](hub: OperationHub[T, C]; name: string): Enablement =
  ## What `invoke` would say about `name` right now, for a surface that shows
  ## the operation (a menu entry greyed with its reason). An operation no
  ## active table holds is disabled, and says so.
  for table in hub.tables:
    if table.isActive and name in table.entries:
      let entry = table.entries[name]
      return if entry.enablement.isNil: AlwaysEnabled else: entry.enablement()
  operationDisabled("`" & name & "` (" & operationLabelOf(name) &
           ") is not available here")

proc invoke*[T, C](hub: OperationHub[T, C]; call: OperationCall[T];
                   ctx: var C): InvokeResult =
  ## THE ONE ROUTE from a resolved name to its procedure. See the module header.
  for table in hub.tables:
    if not table.isActive or call.name notin table.entries:
      continue
    let entry = table.entries[call.name]
    if not entry.enablement.isNil:
      let answer = entry.enablement()
      if not answer.enabled:
        return InvokeResult(kind: oiDisabled, table: table.owner,
                            reason: answer.reason)
    if entry.action(call, ctx):
      return InvokeResult(kind: oiRan, table: table.owner)
  InvokeResult(kind: oiAbsent)

proc boundOperations*[T, C](hub: OperationHub[T, C]): HashSet[string] =
  ## Every name some table binds, active or not: this front-end's half of the
  ## reachability census (IR-2).
  result = initHashSet[string]()
  for table in hub.tables:
    for name in table.order:
      result.incl name
