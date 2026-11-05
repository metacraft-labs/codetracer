## viewmodels/origin_walk.nim — `o` / `O` (CodeTracer-TUI.md §4.2, "Jump to
## Value Origin" / "Reverse Origin") as a value: the origin chain in hand, how
## deep `o` has walked it, the ticks `O` returns through, and the
## notification lines that report each step.
##
## Moved here from the terminal's `app/origin_binding.nim` (PLAT-70 Part E) so
## that every native front-end walks a chain by the ONE rule: the terminal and
## the GPUI window both dispatch `editor.jump-to-value-origin` and
## `debugger.reverse-origin` (Variable-State-Pane.md § Value origin from the
## keyboard, item 4). The reading of §4.2 these procs implement — `o` walks
## one hop deeper (further back in time) and pushes the tick it left, `O` pops
## it — is recorded in `origin_binding.nim`'s header, beside the terminal's
## query plumbing that stayed there.
##
## Pure: no signals, no I/O; C and JS.

import std/strutils

import ./origin_chain_types

func pathBaseName(path: string): string =
  let slash = path.rfind('/')
  if slash >= 0: path[slash + 1 .. ^1] else: path

const
  OriginPendingText* = "origin: querying…"
    ## What the notification area reads while a query is in flight. THE VISIBLE
    ## PENDING STATE — see this module's header.

  OriginIdleText* = "origin: nothing selected"
  OriginEmptyChainText* = "origin: no recorded write for this value"
  OriginExhaustedText* = "origin: at the start of the chain"
  OriginAtQueryText* = "origin: back at the question"

  MaxOriginHops* = 16
    ## What `o` asks for. `origin_chain_types.DEFAULT_ORIGIN_MAX_HOPS` is the
    ## published default (spec §6.1 numerics) and this front-end does not
    ## second-guess it; the constant is named here so a test can assert the
    ## request carried it rather than whatever the VM's preferences happened to
    ## hold.

type
  OriginQueryState* = enum
    ## Where an origin query is, as ONE value a status bar can render.
    ##
    ## Derived from `OriginChainVM.loading` and `activeChain` rather than held,
    ## because a second copy of "is a query in flight" is a second thing that
    ## can be stale — and a stale "ready" is exactly the frozen screen the risk
    ## mitigation is about.
    oqIdle = "idle"
    oqPending = "pending"
    oqReady = "ready"

  OriginStep* = object
    ## One hop, as the navigator needs it: WHERE to go and WHY.
    tick*: uint64
    path*: string
    line*: int
    targetExpr*: string
    sourceExpr*: string
    sourceText*: string
    kind*: OriginKind
    confidence*: float

  OriginNavigator* = object
    ## `o` / `O` as a value. Holds the chain in hand, how deep `o` has walked,
    ## and the ticks `O` returns through.
    variable*: string
      ## The variable the chain in hand answers for. "" means no chain.
    queryTick*: uint64
      ## The tick the question was asked from — the bottom of the return stack.
    steps*: seq[OriginStep]
    depth*: int
      ## How many hops `o` has walked. 0 means "standing at the question".
    returnStack*: seq[uint64]
    terminator*: TerminatorKindWire
    truncated*: bool

proc initOriginNavigator*(): OriginNavigator =
  OriginNavigator(variable: "", queryTick: 0, steps: @[], depth: 0,
                  returnStack: @[], terminator: tkwUnknownSource,
                  truncated: false)

# ---------------------------------------------------------------------------
# The chain, as steps
# ---------------------------------------------------------------------------

proc stepsOf*(chain: OriginChain): seq[OriginStep] =
  ## The chain's hops as navigable steps, in chain order — nearest cause first.
  ##
  ## A hop whose `location.rrTicks` is 0 AND whose path is empty is DROPPED:
  ## it names no recorded step, so `o` has nowhere to go and a navigator that
  ## kept it would seek to tick 0 and call that the origin. That is codetracer
  ## #698's failure mode exactly, one layer up.
  result = @[]
  for hop in chain.hops:
    if hop.location.path.len == 0 and hop.location.rrTicks == 0'u64:
      continue
    result.add OriginStep(
      tick: hop.location.rrTicks,
      path: hop.location.path,
      line: hop.location.line,
      targetExpr: hop.targetExpr,
      sourceExpr: hop.sourceExpr,
      sourceText: hop.sourceText,
      kind: hop.kind,
      confidence: hop.confidence)

proc adopt*(nav: var OriginNavigator; chain: OriginChain;
            variable: string; queryTick: uint64) =
  ## Take a freshly arrived chain as the one `o` walks.
  ##
  ## The depth and the return stack are RESET, because a new question is a new
  ## walk: carrying a stack across two chains would let `O` return to a tick
  ## that belongs to a variable nobody is looking at.
  nav.variable = variable
  nav.queryTick = queryTick
  nav.steps = stepsOf(chain)
  nav.depth = 0
  nav.returnStack = @[]
  nav.terminator = chain.terminator.kind
  nav.truncated = chain.truncated

proc answersFor*(nav: OriginNavigator; variable: string;
                 tick: uint64): bool =
  ## Whether the chain in hand answers `o` for this (variable, tick).
  ##
  ## The tick comparison is against `queryTick` and NOT against the current
  ## position, because walking the chain moves the position: after one `o` the
  ## debugger is at the origin and the chain still answers for the question it
  ## was asked.
  nav.variable.len > 0 and nav.variable == variable and
    (nav.depth > 0 or nav.queryTick == tick)

proc advance*(nav: var OriginNavigator): (bool, OriginStep) =
  ## `o`: one hop deeper into the chain. Returns the step to seek to.
  ##
  ## `false` at the end of the chain — the caller REPORTS that (see
  ## `OriginExhaustedText`) rather than doing nothing, which is CTUI-10's
  ## second contract applied to a key instead of to a command.
  if nav.depth >= nav.steps.len:
    return (false, OriginStep())
  let from0 =
    if nav.depth == 0: nav.queryTick else: nav.steps[nav.depth - 1].tick
  nav.returnStack.add from0
  let step = nav.steps[nav.depth]
  inc nav.depth
  (true, step)

proc retreat*(nav: var OriginNavigator): (bool, uint64) =
  ## `O`: back the way `o` came. Returns the tick to seek to.
  if nav.returnStack.len == 0 or nav.depth == 0:
    return (false, 0'u64)
  let tick = nav.returnStack[^1]
  nav.returnStack.setLen(nav.returnStack.len - 1)
  dec nav.depth
  (true, tick)

proc currentStep*(nav: OriginNavigator): (bool, OriginStep) =
  ## The hop `o` last landed on, or `(false, …)` at the question.
  if nav.depth <= 0 or nav.depth > nav.steps.len:
    return (false, OriginStep())
  (true, nav.steps[nav.depth - 1])

# ---------------------------------------------------------------------------
# What the user sees
# ---------------------------------------------------------------------------

proc describeKind*(kind: OriginKind): string =
  ## The one-word account of a hop, for the notification area. §3.3.6's
  ## "transient status messages" is the whole of §4.2's origin UI in this
  ## front-end — there is no origin PANE in §3.3.
  case kind
  of okTrivialCopy: "copied from"
  of okFieldAccess: "field of"
  of okIndexAccess: "index of"
  of okComputational: "computed from"
  of okFunctionCall: "returned by"
  of okLiteral: "literal"
  of okReturnCapture: "captured from"
  of okFunctionReturn: "returned from"
  of okParameterPass: "passed as"
  of okCrossThreadCopy: "copied across threads"
  of okUnknown: "written at"

proc describeTerminator*(kind: TerminatorKindWire): string =
  ## Why the chain stopped. Rendered when `o` reaches the end, so "there is
  ## nothing before this" and "the budget ran out" are different reports.
  case kind
  of tkwUnknownSource: "the classifier could not name a source"
  of tkwLiteral: "a literal"
  of tkwComputational: "a computation"
  of tkwParameterAtRecordStart: "a parameter at the start of the recording"
  of tkwReadFromExternal: "a read from outside the recording"
  of tkwRecordingStart: "the start of the recording"
  of tkwUnknownVariable: "an unknown variable"
  of tkwDepthLimit: "the hop budget"
  of tkwOutOfBudget: "the scan budget"

proc originNotification*(nav: OriginNavigator;
                         state: OriginQueryState): string =
  ## The §3.3.6 notification line for the current origin state. NEVER EMPTY
  ## when something has been asked, because an empty notification and a
  ## finished query look the same on a terminal.
  case state
  of oqPending:
    OriginPendingText
  of oqIdle:
    if nav.variable.len == 0: OriginIdleText else: OriginEmptyChainText
  of oqReady:
    if nav.steps.len == 0:
      OriginEmptyChainText
    else:
      let (has, step) = nav.currentStep()
      if not has:
        OriginAtQueryText
      else:
        nav.variable & " " & describeKind(step.kind) & " " &
          step.sourceExpr.strip() & " @ " & pathBaseName(step.path) & ":" &
          $step.line & " (tick " & $step.tick & ", hop " & $nav.depth &
          "/" & $nav.steps.len & ")"

proc exhaustedNotification*(nav: OriginNavigator): string =
  ## What `o` reports when there is no hop left: the reason the ENGINE gave.
  OriginExhaustedText & " — " & describeTerminator(nav.terminator) &
    (if nav.truncated: " (truncated)" else: "")
