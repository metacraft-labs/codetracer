## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade —
## and never `viewmodel/*` directly.
##
## app/variables_binding.nim — CTUI-7. The ONE place that turns `StateVM` into a
## `VariablesModel`, and the only module that builds the lazy-population seam.
##
## ## Why it exists as its own module
##
## The same split, and the same three reasons, as CTUI-5's `source_binding.nim`
## and CTUI-6's `call_stack_binding.nim`: the view stays a pure function of a
## value, two stops stay comparable, and the pane's memory ceiling stays a
## property of a field a reader can see. This module reads; `views/variables.nim`
## draws.
##
## ## WHAT `StateVM` ACTUALLY OWNS, MEASURED RATHER THAN ASSUMED
##
## Established by reading and grepping `src/frontend/viewmodel/` on 2026-09-06,
## and recorded here because a later reader would otherwise re-derive it:
##
## 1. **`currentVariables` is a memo over exactly three store signals** —
##    `store.locals.locals`, `store.locals.globals`, `store.locals.watches` —
##    selected by `activeTab`. It is not a fourth source, so a pane that wants
##    two of the three at once reads the store's signals for the ones the tab is
##    not on. `rootsFor` does that, and it deliberately goes through
##    `currentVariables` for the tab that IS active, so the memo is on the path
##    the product uses rather than bypassed.
##
## 2. **Nothing writes `store.locals.globals` from a backend response.** A grep
##    over the whole ViewModel layer finds one read (`state_vm`), one test
##    assignment and the collab signal serialiser. This is the shape CTUI-5
##    found in `PointListVM.points` — a signal a pane can bind to and that no
##    session ever fills — and it is why `views/variables.nim` renders that root
##    with a reason instead of as an empty tree.
##
## 3. **The variable tree arrives whole, bounded by the request's `depthLimit`.**
##    `ct/load-locals` answers `depthLimit: 7` levels in one response, so
##    "populated lazily on expansion" is about the ROWS and the NODES this pane
##    materialises, not about a second request. That is the real cost on
##    `wide_state`, where one node has 600 members: the seam below hands out one
##    page at a time and `collapseNode` drops what it handed out.
##
## 4. **Per-frame variables are still not fetchable, and CTUI-6 left the handle
##    for it.** `StackFrame.id` is carried, and DAP `variables` takes a
##    `variablesReference`. Measured: `Handler::variables`
##    (`src/db-backend/src/dap_handler.rs`) names its argument `_arg` and
##    answers `self.reader.variables_at_owned(self.step_id)` — the CURRENT
##    step's variables, whatever frame was asked for. Measured on `wide_state`
##    at `main` (2026-09-06): the two frames' ids `@[2, 0]` answer the SAME
##    sixteen variables, BYTE FOR BYTE, at a stop where `ct/load-locals` also
##    answers sixteen — which is a sharper statement than "the answer is empty"
##    and, unlike it, cannot be satisfied for free by a stop with no locals.
##    So this milestone does NOT fetch another frame's locals, and
##    `tests/test_variables_tree_expansion.nim` measures that limitation on
##    every run rather than quoting it.
##
## ## No mocks
##
## Nothing here constructs a ViewModel, a store or a backend. It takes the ones
## a real session built.

import std/[sets, strutils, tables]

import codetracer_embed

import ./views/variables

export variables

const
  SnapshotDepth* = 1
    ## How deep the diff's per-tick snapshot goes.
    ##
    ## TOP-LEVEL ONLY, and that is a measured trade rather than a shortcut. A
    ## compound value's rendering CONTAINS its members' renderings — `results`
    ## reads `[5, 7]` and then `[5, 7, 42]` — so a member's change already moves
    ## its ancestor's value and marks the ancestor's row. Going deeper would key
    ## the snapshot by every node in the tree, which on `wide_state` is 1801
    ## entries at EVERY tick the timeline holds; the badge gained would be on a
    ## row that is only on screen when its parent is already marked.
    ##
    ## Stated as a constant rather than left implicit so a host that wants
    ## per-member badges changes one number and pays for it knowingly.

  UnsupportedArguments* =
    "no per-frame argument surface: ct/load-locals does not separate " &
    "parameters from locals, and CallLine.args is never populated"
  UnsupportedGlobals* =
    "store.locals.globals is filled by nothing in this repository — the " &
    "engine folds module-level names into the locals answer"
  UnsupportedReturnValues* =
    "no return-value surface in the ViewModel layer or on the wire"
  UnsupportedRegisters* =
    "registers are projected only by the MCR emulator backend " &
    "(dap_handler.rs, TraceKind::Emulator); every fixture here is a CTFS trace"

proc scopeForTab*(tab: StateTab): ScopeKind =
  ## Which §3.3.4 root `StateVM.activeTab` is on.
  ##
  ## The tab is a real signal with a real writer (`selectTab`), and this is what
  ## makes it visible in a pane that has no tab strip: the root it names is the
  ## one the pane opens and puts its cursor in.
  case tab
  of stLocals: skLocals
  of stGlobals: skGlobals
  of stWatches: skWatches

proc declaredScopes*(vm: StateVM = nil): seq[Scope] =
  ## §3.3.4's five roots plus `Watches`, each with its availability.
  ##
  ## A `Scope` for a root nothing can fill still appears, carrying WHY. See
  ## `views/variables.nim`'s header: an empty tree and an unfillable one are
  ## different answers and only the second is true here.
  ##
  ## `Globals`'s availability is ASKED OF THE SESSION rather than written down,
  ## and that distinction matters more than it looks. Nothing in this repository
  ## fills `store.locals.globals` from a backend response today, so the root
  ## normally renders its reason — but an availability that were a CONSTANT
  ## would go on hiding the signal on the day a host started filling it, which
  ## is a silently wrong screen rather than an honest one. The other four
  ## unavailable roots have no signal at all to ask, so theirs is a constant and
  ## says so.
  let globalsFilled = not vm.isNil and vm.store.locals.globals.val.len > 0
  @[
    Scope(kind: skLocals, availability: savaAvailable),
    Scope(kind: skArguments, availability: savaUnsupported,
          note: UnsupportedArguments),
    Scope(kind: skGlobals,
          availability: (if globalsFilled: savaAvailable
                         else: savaUnsupported),
          note: (if globalsFilled: "" else: UnsupportedGlobals)),
    Scope(kind: skReturnValues, availability: savaUnsupported,
          note: UnsupportedReturnValues),
    Scope(kind: skRegisters, availability: savaUnsupported,
          note: UnsupportedRegisters),
    Scope(kind: skWatches, availability: savaAvailable),
  ]

proc rootsFor*(vm: StateVM; scope: ScopeKind): seq[Variable] =
  ## The top-level variables of one root, read from `StateVM`.
  ##
  ## THROUGH `currentVariables` FOR THE ACTIVE TAB. That memo is what the
  ## product renders, so a pane that always read the store's signals directly
  ## would be testing a path the desktop does not take — and would keep working
  ## if the memo broke.
  if vm.isNil:
    return @[]
  let active = scopeForTab(vm.activeTab.val)
  if scope == active:
    return vm.currentVariables.val
  case scope
  of skLocals: vm.store.locals.locals.val
  of skGlobals: vm.store.locals.globals.val
  of skWatches: vm.store.locals.watches.val
  else: @[]

# ---------------------------------------------------------------------------
# Variables -> VarNode
# ---------------------------------------------------------------------------

proc byteBufferFor(v: Variable): seq[int] =
  ## The bytes `v`'s members are, if they are bytes. See
  ## `formatters/type_formatters.byteBufferOf`.
  if v.children.len == 0:
    return @[]
  var members: seq[string] = @[]
  for child in v.children:
    members.add child.value
  byteBufferOf(members)

proc varNodeFor*(parentPath: string; v: Variable): VarNode =
  ## One `store/types.Variable` as a tree node. NOT its members — those arrive
  ## through the seam.
  VarNode(
    path: childPath(parentPath, v.name),
    name: v.name,
    typeName: v.typeName,
    value: v.value,
    memberCount: v.children.len,
    byteBuffer: byteBufferFor(v))

proc findVariable(roots: seq[Variable]; segments: openArray[string]): Variable =
  ## Walk `segments` down `roots` by NAME.
  ##
  ## By name and not by index, because an index would be a second coordinate
  ## system over the same tree and a page boundary would shift it. The one
  ## assumption is that a member's name carries no `.` — true for every name
  ## this corpus produces (identifiers, and the synthetic `[0]` … `[n]` the
  ## decoder generates for a sequence) and stated rather than left to be found.
  var level = roots
  var found = Variable(name: "")
  for segment in segments:
    var hit = -1
    for i, candidate in level:
      if candidate.name == segment:
        hit = i
        break
    if hit < 0:
      return Variable(name: "")
    found = level[hit]
    level = found.children
  found

proc nodeChildrenFor*(vm: StateVM): NodeChildren =
  ## THE LAZY-POPULATION SEAM, over a real `StateVM`.
  ##
  ## Answers one node's members over one window. A scope root's path is
  ## `@<Scope>`; below it the path is the dot-separated variable path the
  ## desktop already keys `expandedPaths` by.
  result = proc(path: string; offset, limit: int):
      tuple[nodes: seq[VarNode]; total: int] =
    result = (nodes: @[], total: 0)
    if vm.isNil or path.len == 0 or not path.startsWith(ScopePathPrefix):
      return
    let segments = path.split('.')
    var scope = skLocals
    var matched = false
    for kind in ScopeKind:
      if segments[0] == ScopePathPrefix & $kind:
        scope = kind
        matched = true
        break
    if not matched:
      return
    let roots = rootsFor(vm, scope)
    var members: seq[Variable]
    if segments.len == 1:
      members = roots
    else:
      let node = findVariable(roots, segments[1 .. ^1])
      if node.name.len == 0:
        return
      members = node.children
    result.total = members.len
    let first = max(0, offset)
    let last = min(members.len, first + max(0, limit))
    for i in first ..< last:
      result.nodes.add varNodeFor(path, members[i])

# ---------------------------------------------------------------------------
# The diff's per-tick snapshot
# ---------------------------------------------------------------------------

proc snapshotOf*(variables: seq[Variable];
                 depth = SnapshotDepth): Table[string, string] =
  ## Every variable's rendered value at one tick, keyed by the path the pane
  ## uses. See `SnapshotDepth`.
  ## Walked with an explicit stack rather than a nested closure: a closure that
  ## captured `result` would not compile under ORC's memory-safety analysis, and
  ## a `ref` wrapper to work around it would allocate on every stop.
  result = initTable[string, string]()
  var pending: seq[tuple[prefix: string; rows: seq[Variable]; left: int]] = @[]
  pending.add (prefix: "", rows: variables, left: max(1, depth))
  while pending.len > 0:
    let frame = pending.pop()
    for v in frame.rows:
      if v.name.len == 0:
        continue
      let path = childPath(frame.prefix, v.name)
      result[path] = v.value
      if frame.left > 1 and v.children.len > 0:
        pending.add (prefix: path, rows: v.children, left: frame.left - 1)

proc observeStop*(timeline: var ValueTimeline; tick: uint64;
                  variables: seq[Variable]) =
  ## Record this stop's variables against its tick.
  ##
  ## The caller has to do this on EVERY stop it wants a diff at, including the
  ## ones it passes through — that is what makes a backward step's anchor
  ## available. `diff_highlighter`'s header says what happens when it is not:
  ## nothing is marked, loudly, through `anchorKnown`.
  timeline.observe(tick, snapshotOf(variables))

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc variablesModelFor*(vm: StateVM;
                        timeline: ValueTimeline;
                        tick: uint64;
                        tickLabel = "";
                        pageSize: int = variables.DefaultPageSize;
                        scrollTop = 0): VariablesModel =
  ## The pane's model for the CURRENT stop.
  ##
  ## Everything is read at call time and nothing is retained beyond the model,
  ## so two stops are two values and the difference between them is exactly the
  ## difference on screen.
  ##
  ## The root `activeTab` names is OPENED and its first page materialised, which
  ## is the one expansion the pane does without being asked: a variables pane
  ## that opened to five closed roots would show a debugger's locals to nobody.
  result = initVariablesModel(
    scopes = declaredScopes(vm),
    children = nodeChildrenFor(vm),
    diff = timeline.diffAt(tick),
    tickLabel = tickLabel,
    pageSize = pageSize,
    scrollTop = scrollTop)
  if vm.isNil:
    return
  let openScope = scopePath(scopeForTab(vm.activeTab.val))
  result.expandNode(openScope)
  let selected = vm.selectedPath.val
  if selected.len > 0:
    result.selected = childPath(openScope, selected)
    result.focused = result.selected

proc publishSelection*(vm: StateVM; model: VariablesModel) =
  ## Put the pane's cursor where `StateVM` keeps it.
  ##
  ## `selectPath` writes ONE signal and issues no backend command, which is the
  ## same property CTUI-6 needed from `CalltraceVM.selectEntry`: a variables
  ## cursor must not move the program. The path published is the VARIABLE path,
  ## without this pane's `@Scope.` prefix, so a desktop reading the same session
  ## sees the key it already uses.
  if vm.isNil:
    return
  vm.selectPath(variablePathOf(model.selected))

proc publishExpansion*(vm: StateVM; model: VariablesModel) =
  ## Mirror the pane's open set into `StateVM.expandedPaths`, in the desktop's
  ## own keying — variable paths, no scope prefix, and no entry for a scope root
  ## (the desktop has tabs where this pane has roots).
  if vm.isNil:
    return
  var wanted: seq[string] = @[]
  for path in model.expanded:
    let variablePath = variablePathOf(path)
    if variablePath.len > 0:
      wanted.add variablePath
  # `toggleExpand` is the only writer, so the set is reconciled by toggling the
  # difference in both directions rather than by assigning the signal: the
  # collaborative arm of that proc dispatches an operation per change, and an
  # assignment would bypass it.
  let current = vm.expandedPaths.val
  for path in wanted:
    if path notin current:
      vm.toggleExpand(path)
  for path in current:
    if path notin wanted:
      vm.toggleExpand(path)
