## layer_stack.nim — MODES AS LAYERS a ViewModel operation pushes and pops.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §5.3–§5.4 — the stack of PUSHED
## layers, each naming the binding table it contributes, the element that
## owns it and the token that identifies it; push, pop by token, the pop of
## an owner's layers when the owner is unmounted, and which layers are
## active for a scope path.
##
## Refuses to own: what a layer binds (the base's table of that name, and the
## user's rows for it — `keymap_router`), when a mode starts or ends (the
## ViewModel operation that pushes, e.g. `find.open`), and the DERIVED
## layers of the modal bases (§5.5: Vim's insert mode is `EditorState.mode`,
## and the editor table is filtered by it at resolution — there is nothing
## here to push for it).
##
## ## THE DISCIPLINE (§5.4, KL-5)
##
##   * A push returns a TOKEN; a pop takes it. A layer is identified by its
##     token, never by its position.
##   * Popping a token that is not on top is a DEFECT, not a request: the
##     stack is left exactly as it was and the answer says why. Popping down
##     to the token would pop another mode's layer on its behalf.
##   * An owner's unmount pops exactly that owner's layers, newest first,
##     and answers them so each mode can leave its ViewModel consistent
##     (`onLayerPopped`) — the only pop a mode does not initiate itself.
##   * Focus moving away does NOT pop: a layer whose owner is off the scope
##     path is inactive and still there when the focus returns.
##
## The stack is a VALUE: every operation returns the new stack, so a test's
## reference model and the product's stack compare with `==`.
##
## Pure; compiles on C, JS and wasm32.

import ./scope_path

type
  LayerToken* = distinct int

  PushedLayer* = object
    token*: LayerToken
    table*: string
      ## The binding table this layer contributes (`find`, `palette`,
      ## `command-line`, `context-menu`, …): the base's rows of that name and
      ## the user's rows for its operations.
    owner*: string
      ## The `ScopeElement.id` of the owner. The layer is consulted only
      ## while an element with this id is on the scope path.
    label*: string
      ## What the status line names while this layer is on top (`FIND`,
      ## `PALETTE`, `COMMAND`).

  LayerStack* = object
    layers*: seq[PushedLayer]
      ## Oldest first; the top is the last.
    nextToken*: int

  PopOutcome* = enum
    poPopped = "popped"
    poNotOnTop = "not-on-top"
      ## The token is on the stack under another layer.
    poUnknown = "unknown"
      ## The token is not on the stack (never pushed, or already popped).

  PopResult* = object
    outcome*: PopOutcome
    stack*: LayerStack
      ## Unchanged unless `outcome == poPopped`.
    top*: LayerToken
      ## The token that WAS on top, for the report a mismatched pop owes.

proc `==`*(a, b: LayerToken): bool {.borrow.}

func initLayerStack*(): LayerStack = LayerStack(layers: @[], nextToken: 1)

func push*(s: LayerStack; table, owner, label: string):
          tuple[stack: LayerStack, token: LayerToken] =
  var next = s
  if next.nextToken < 1: next.nextToken = 1
  let token = LayerToken(next.nextToken)
  inc next.nextToken
  next.layers.add PushedLayer(token: token, table: table, owner: owner,
                              label: label)
  (next, token)

func pop*(s: LayerStack; token: LayerToken): PopResult =
  ## Pop `token` — only when it is on top (see the module header).
  let top = if s.layers.len > 0: s.layers[^1].token else: LayerToken(0)
  if s.layers.len > 0 and s.layers[^1].token == token:
    var next = s
    next.layers.setLen(next.layers.len - 1)
    return PopResult(outcome: poPopped, stack: next, top: top)
  for l in s.layers:
    if l.token == token:
      return PopResult(outcome: poNotOnTop, stack: s, top: top)
  PopResult(outcome: poUnknown, stack: s, top: top)

func unmount*(s: LayerStack; owner: string):
             tuple[stack: LayerStack, popped: seq[PushedLayer]] =
  ## The owner element is gone: its layers leave the stack, and are
  ## answered NEWEST FIRST so each mode is told in the order it was entered
  ## the other way round. Every other layer keeps its place.
  var next = s
  next.layers = @[]
  var popped: seq[PushedLayer] = @[]
  for l in s.layers:
    if l.owner == owner: popped.add l
    else: next.layers.add l
  var newestFirst: seq[PushedLayer] = @[]
  for i in countdown(popped.len - 1, 0): newestFirst.add popped[i]
  (next, newestFirst)

func activeLayers*(s: LayerStack; path: ScopePath): seq[PushedLayer] =
  ## The layers whose owner is on `path`, NEWEST FIRST — the order the
  ## resolver consults them in (§5.1).
  result = @[]
  for i in countdown(s.layers.len - 1, 0):
    if path.contains(s.layers[i].owner):
      result.add s.layers[i]

func topLabel*(s: LayerStack; path: ScopePath): string =
  ## The status line's name for the newest ACTIVE layer, or "".
  let active = activeLayers(s, path)
  if active.len > 0: active[0].label else: ""

func indexOfLayer*(s: LayerStack; table, owner: string): int =
  ## The index of the newest layer of `table` owned by `owner`, or -1 — how
  ## an operation that closes its own mode (`find.close`) finds the token
  ## its `find.open` received.
  for i in countdown(s.layers.len - 1, 0):
    if s.layers[i].table == table and s.layers[i].owner == owner:
      return i
  -1
