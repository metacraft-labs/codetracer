## plugin_host/plugin_api.nim — PLAT-7 deliverables 4, 5 and 6, from the
## PLUGIN's side: the activation scope a subscription is owned by, the two
## ways a plugin observes, and the synchronous-effect budget it is measured
## against.
##
## Re-exported from `codetracer_embed.nim`, because Extensibility-Model.md
## §2.1 makes the facade the surface an extension consumes and this is part of
## that surface. It is a DELIBERATE widening of the facade, which §2.1 asks
## for in as many words ("Where the facade is insufficient it must be widened
## deliberately"), and it widens it by nothing a plugin could not already
## reach: this module grants no access to any CodeTracer state. Everything a
## plugin can read still comes from the ViewModels the facade already exports.
##
## ## THE THREE RULES THIS FILE EXISTS TO MAKE STRUCTURAL
##
## ### 1. A subscription is owned by the activation scope, not by a teardown list
##
## §4.2: "Every subscription an extension creates is owned by its activation
## scope and released with it — `isonim`'s owner tree already provides this
## and it should be the mechanism rather than a convention."
##
## `pluginEffect` and `pluginMemo` call `isonim`'s `createEffect` /
## `createMemo`, which attach the new computation to the AMBIENT `Owner`. The
## host establishes that ambient owner with `runWithOwner(scope, ...)` before
## it calls a plugin's `activate`, so a plugin does not opt in to ownership —
## it cannot opt out. Deactivation is then `cleanNode(scope)`, whose loop over
## `comp.sources` REMOVES the computation from each signal's `observers`
## sequence. That is why deactivation is structural: the signal no longer has
## a reference to notify, so there is nothing left that could decide to run
## the effect anyway.
##
## And it is checked rather than trusted: `requireScope` refuses to create a
## computation when the ambient owner is not inside the plugin's own scope.
## A plugin that stashed its context and called `pluginEffect` from a timer
## callback would otherwise create an effect owned by whatever happened to be
## running — the one shape deactivation genuinely cannot release — and would
## get an orphan instead of an error. It gets an error.
##
## ### 1a. The reactive primitives are WRAPPED, and the raw ones are denied
##
## Rule 1 above is only true if a plugin cannot create a computation any other
## way. It could, and for a while it did: `codetracer_embed.nim` re-exports
## `isonim/core/[signals, computation, owner]` for §4.1's Mode N consumers, so
## a plugin that imported nothing but the blessed facade already had
## `createEffect`, `createMemo`, `createRoot` and `runWithOwner` in scope.
## Measured, on a plugin using only that facade: a raw `createEffect` in
## `activate` ran on every write, for 160 ms each time, was never attributed to
## the plugin and never suspended it.
##
## Two audiences, one of which is trusted:
##
##   * an **SDK consumer** embedding CodeTracer is application code. §4.1 says
##     "signals cross no boundary" and the facade's own docs promise
##     `createMemo` in scope. `codetracer_embed.nim` is unchanged for them.
##   * a **plugin** is not application code. It consumes
##     `codetracer_plugin.nim` — the same facade with the computation-creating
##     and owner-manipulating symbols filtered out by `export … except` — so
##     the unqualified `createEffect(…)` a plugin author would actually write
##     DOES NOT COMPILE. `plugin_fixtures/surface_probe_plugin.nim` asserts
##     that with `compiles`, in a module that imports the plugin surface and
##     nothing else, and asserts the sanctioned call through the SAME
##     `compiles` so the control runs through the mechanism the rule uses.
##
## `export … except` filters unqualified lookup and NOT module-qualified
## lookup — `computation.createEffect(…)` still resolves through the chain,
## measured rather than assumed. So the language half is narrowing, not the
## boundary, and the boundary is `ci/test/plugin-reactive-boundary.sh`: a
## declared plugin (a `.ct-plugin` marker, the same two spellings
## `ci/test/sdk-facade-boundary.sh` uses) may not import
## `isonim/core/computation`, `isonim/core/owner` or the wider
## `codetracer_embed`, and may not NAME any denied primitive in code by any
## spelling. That is the same kind of enforcement §3.2 of
## CodeTracer-Embed-SDK.md already rests the facade on — "Enforcement is an
## import lint, not discipline" — and it is why the budget is enforcement
## rather than advice.
##
## AND THAT LINT BINDS THE PLUGIN'S REACHABLE CLOSURE, NOT ITS OWN FILE. It did
## not for a day, and one module of indirection defeated it completely: a
## declared plugin importing only `codetracer_plugin`, plus one ordinary
## undeclared helper —
##
##   # raw_helper.nim — not a plugin, not an SDK consumer
##   import isonim/core/computation as c
##   proc rawEffect*(body: proc()) = c.createEffect(body)
##
## — measured `rawRuns=4  budgeted runs=0  violations=0  suspended=false`, with
## both mechanisms green and the gate reporting `12 checks, 0 failing`. So
## "every computation a plugin has is one the host created" was FALSE, and a
## boundary a helper module defeats is one a plugin author defeats by accident.
## The gate now walks each declared plugin's imports transitively, and the walk
## states three bounds rather than assuming them:
##
##   * **It terminates.** A visited set over repo-relative paths, each file
##     enqueued at most once, over the finite set of files that EXIST ON DISK
##     under the importing module's directory or one of the gate's search
##     roots — its resolver returns a candidate only when `[ -f … ]` holds. A
##     cycle between two modules — which nim permits — costs one visit and is a
##     contract-suite case, so "the lint hangs" is not a way this can fail.
##     (This said "the finite set `git ls-files` reports" until 2026-09-08.
##     That is the set the gate discovers SEEDS from, unioned with
##     `--others`, and it is not what bounds the walk: `git ls-files` reports
##     zero of the four modules in this milestone's plugin closure, so a walk
##     over it would have walked nothing.)
##   * **The sanctioned surface is a TERMINAL** — reached, reported, and not
##     entered, because entering it would find its `import codetracer_embed`
##     and report every plugin for using the surface correctly. It is bound by
##     the gate's surface-present, surface-narrows and denied-list-agrees
##     checks instead.
##   * **A spec it cannot read is refused rather than trusted**, because "I
##     could not read it" and "it is clean" are different facts. That covers a
##     module resolving to no repository file AND a line the import extractor
##     declines to analyse: the extractor is shared with the SDK facade lint
##     (`ci/lib/nim-imports.sh`), and it refuses three shapes rather than
##     guessing at them.
##
## The third bound is why the extractor is shared at all. This gate was first
## written with its own copy, which could not see nim's newline-continued
## `import` — 138 files in `src/` are written that way — so the helper-module
## exploit above, respelled across two lines, produced an identical
## `rawRuns=6 runs=0 violations=0 suspended=false` while the gate reported
## `15 checks, 0 failing` and said nothing about having failed to read
## anything. One predicate, one function.
##
## `PluginDeniedPrimitives` below is the single list both halves read: the gate
## parses it out of this file rather than hardcoding the names, and asserts
## that `codetracer_plugin.nim`'s `except` clause names exactly the same set.
##
## ### 2. Observation is a signal read; action is a ViewModel action proc
##
## §5.1 and §5.2. There is **no `dispatch`, no `emit`, no `send`, no command
## name and no event bus in this file or in `host.nim`**, and the absence is
## asserted rather than described: `test_plugin_lifecycle.nim` proves that
## `host.dispatch(...)` does not compile while `vm.stepForward()` does, so the
## same mechanism that reports the absence also reports the presence of the
## sanctioned path.
##
## `observe` exists not to mediate the read — a plugin may read a signal
## directly and that is the whole of §5.1 — but because a read is the natural
## place to put a deadline checkpoint. See rule 3.
##
## AND A RAW READ IS NOT ONE. `isonim.val` and `createSignal` are deliberately
## left in a plugin's scope by `codetracer_plugin.nim`, because a read is not a
## computation and a signal is not one either — neither can make work the host
## does not budget. What a raw read costs is layer (b): it is tracked exactly
## as `observe` is, but it does not consult the deadline, so a plugin whose
## loop reads raw is measured, attributed and suspended after ONE overrun
## rather than stopped inside it. §5.4 used to argue the limit was narrow
## because "a plugin doing real work reads, and a read is a checkpoint"; that
## was false for the same re-export reason rule 1a describes, and §5.4 now
## names `ctx.observe` specifically.
##
## ### 3. The budget is enforced, and where it cannot be, it says so
##
## §5.3: "Long-running extension work is asynchronous and cancellable, with a
## declared budget for synchronous effects that the host enforces rather than
## documents. An extension exceeding it is reported by name."
##
## Enforcement has three layers, and the third is the honest limit:
##
##   a. **Refusal.** A plugin that has exceeded the budget is SUSPENDED, and
##      the wrapper returns before calling the body. Not on the next event, on
##      every subsequent one — so an over-budget plugin costs the front-end
##      one overrun and never a second. This is the layer that makes "does not
##      freeze the UI" true for the whole rest of the session.
##   b. **Mid-run abort.** `observe` and `checkBudget` raise
##      `PluginBudgetExceeded` once the run is past its deadline, so a plugin
##      whose loop touches the host at all is stopped inside its first
##      overrun. PLAT-8's I/O primitives are required to be checkpoints for
##      the same reason.
##   c. **The limit, stated.** A plugin that spins without touching the host
##      completes its FIRST overrun. Nim offers no safe way to preempt a
##      synchronous call — an interval timer and a `longjmp` would skip every
##      `finally` between here and there — so the honest claim is "one
##      overrun, attributed, then never again", not "no overrun". PLAT-7's
##      status section says this in the same words rather than leaving a
##      reader to infer it from the code.
##
## ## NO MOCKS
##
## Nothing here stands in for anything. `MonoTime` is `std/monotimes`, the
## effects are `isonim`'s real effects on `isonim`'s real graph, and the
## budget is measured against a real monotonic clock.

import std/[monotimes, strutils, times]

import isonim/core/graph as isonim_graph
import isonim/core/signals as isonim_signals
import isonim/core/computation as isonim_computation
import isonim/core/owner as isonim_owner

import ../../../common/plugin_model

export plugin_model

type
  PluginBudgetExceeded* = object of CatchableError
    ## Raised INSIDE a plugin's own effect body by `checkBudget`/`observe`
    ## once the run is past its deadline. Caught by the wrapper, which turns
    ## it into a `BudgetViolation`; a plugin that catches it itself is still
    ## tripped, because the wrapper measures elapsed time regardless.

  PluginScopeError* = object of CatchableError
    ## Raised when a plugin tries to create a subscription outside its own
    ## activation scope — the one shape `cleanNode` cannot release.

  PluginAccountingError* = object of CatchableError
    ## Raised when the host CREATED a computation for a plugin and then could
    ## not identify it on the ambient owner's `owned` sequence.
    ##
    ## THIS REPLACES A SILENT SKIP. `pluginEffect` and `pluginMemo` read the
    ## new computation back off `owner.owned[^1]`, because `createEffect`
    ## returns nothing; the guard on that read used to be
    ## `if owner.owned.len == before + 1:` WITH NO `else`. A mismatch could not
    ## break the release — that is `cleanNode(scope)`, which walks `owned`
    ## itself and never consults this record — but it would silently drop the
    ## computation from `state.effects`, and `state.effects` is exactly what
    ## `host.deactivate` sweeps to `csClean` to stop an already-queued effect
    ## from running after its release. A dropped record is therefore a
    ## deactivation that is one already-queued run less complete than it
    ## reports, for a plugin nobody would think to look at.
    ##
    ## It is unreachable as the code stands: `createComputation` and
    ## `createMemo` both append exactly one node to `Owner.owned` when `Owner`
    ## is non-nil, and `requireScope` has already established that the ambient
    ## owner is inside the plugin's scope and therefore not nil. An invariant
    ## that cannot currently fail is precisely the kind that stops holding
    ## when somebody changes `isonim`, which is why it raises rather than
    ## shrugs.

  BudgetViolation* = object
    plugin*: PluginId
    effect*: string
      ## The name the plugin gave the effect. §5.3 asks for the offender to be
      ## reported BY NAME; the plugin id alone is not enough for an author
      ## with four effects.
    observed*: Duration
    budget*: Duration
    abortedMidRun*: bool
      ## `true` when a checkpoint stopped the run, `false` when the body ran
      ## to completion and was measured afterwards. The distinction is the
      ## difference between layer (b) and layer (c) above, and a report that
      ## collapsed them would hide which one a given plugin exercised.

  PluginRunState* = ref object
    ## Per-plugin accounting, owned by the host and reachable by the plugin
    ## only through its context. §8.1.1's "Accounting. Every handle is
    ## attributable to a plugin" begins here; PLAT-8 adds processes and
    ## sockets to the same record.
    id*: PluginId
    budget*: Duration
    suspended*: bool
    violations*: seq[BudgetViolation]
    runs*: int              ## bodies that were entered
    refusedRuns*: int       ## runs the suspension refused before the body
    checkpoints*: int       ## `checkBudget` calls, including those from `observe`
    lastElapsed*: Duration
    inRun*: bool
    runStarted*: MonoTime
    runEffect*: string
    effects*: seq[ComputationBase]
      ## Every computation created through this API, in creation order. Kept
      ## for accounting and because it is what lets `host.deactivate` close
      ## isonim's already-queued-effect hazard — see `host.nim`. It is NOT the
      ## release mechanism: `cleanNode(scope)` is.

  PluginContext* = ref object
    ## What a plugin's `activate` is handed. It carries the plugin's own
    ## manifest, its accounting, and its scope — and no CodeTracer state at
    ## all. Data reaches a plugin the way §2.1 says it must: through the
    ## ViewModels the facade exports, handed to the plugin's own constructor.
    manifest*: PluginManifest
    state*: PluginRunState
    scope*: OwnerBase

  PluginImplementation* = object
    ## An in-process Nim plugin. §10's open decision 1 lists three execution
    ## models and recommends specifying the API against WASM's constraints
    ## even if the first implementation is in-process; this is that first
    ## implementation, and the API it presents — a manifest, an `activate`
    ## taking a context, no synchronous I/O, no ambient authority — is one a
    ## WASM host could serve unchanged.
    manifest*: PluginManifest
    activate*: proc(ctx: PluginContext) {.closure.}

const
  PluginDeniedPrimitives*: array[10, tuple[primitive, replacement: string]] = [
    ## THE LIST BOTH HALVES OF THE DENIAL READ, in one place so they cannot
    ## drift apart — the same reason `CodeTracerEmbedFacadeModule` lives in the
    ## facade rather than in the lint that enforces it.
    ##
    ## Left: an `isonim` routine that either CREATES a computation whose body
    ## the plugin supplies, or MOVES the ambient owner. Either one produces
    ## work the host neither budgets nor releases. Right: what a plugin uses
    ## instead. Every entry has a replacement, which is the property that makes
    ## this a narrowing rather than a removal — a plugin author is never left
    ## with no way to say what they meant.
    ##
    ## `codetracer_plugin.nim`'s `export … except` clause names exactly this
    ## set, and `ci/test/plugin-reactive-boundary.sh` asserts the two agree
    ## rather than taking either one's word.
    ##
    ## `val`, `createSignal` and `update` are deliberately NOT here. A read is
    ## not a computation and a signal is not one either; §5.4's corrected
    ## wording says what a raw read does cost, which is the checkpoint and not
    ## the budget.
    ("createEffect",       "ctx.pluginEffect"),
    ("createRenderEffect", "ctx.pluginRenderEffect"),
    ("createComputed",     "ctx.pluginComputed"),
    ("createMemo",         "ctx.pluginMemo"),
    ("onMount",            "ctx.pluginOnMount"),
    ("createRoot",         "ctx.pluginRoot"),
    ("onCleanup",          "ctx.onPluginCleanup"),
    ("runWithOwner",       "ctx.pluginEffect (the host owns the scope)"),
    ("getOwner",           "ctx.scope"),
    ("updateComputation",  "ctx.observe (a read is what re-runs a memo)"),
  ]

  DefaultEffectBudget* = initDuration(milliseconds = 8)
    ## Eight milliseconds: half a 60 Hz frame. The number is a policy and the
    ## host takes it as a parameter, but a default that is not obviously
    ## generous is the point — a budget nobody ever hits is documentation.

func newRunState*(id: PluginId; budget: Duration): PluginRunState =
  PluginRunState(id: id, budget: budget)

func describe*(v: BudgetViolation): string =
  ## THE PLUGIN COMES FIRST, for the same reason `PluginError.render` puts it
  ## first: this line appears in a list beside other plugins' lines.
  "plugin '" & v.plugin & "': effect '" & v.effect & "' used " &
    $v.observed.inMilliseconds & " ms against a " &
    $v.budget.inMilliseconds & " ms budget" &
    (if v.abortedMidRun: " (stopped at a checkpoint mid-run)"
     else: " (ran to completion; measured afterwards)") &
    " — the plugin is suspended for this session"

func describeAll*(violations: seq[BudgetViolation]): string =
  var lines: seq[string] = @[]
  for v in violations:
    lines.add describe(v)
  lines.join("\n")

# ---------------------------------------------------------------------------
# The scope guard
# ---------------------------------------------------------------------------

proc withinScope*(scope: OwnerBase): bool =
  ## Is the AMBIENT owner `scope` itself, or a computation nested under it?
  ##
  ## Walks `Owner.owner` upward. That edge is set by `createComputation` and
  ## by `createRoot`, so a computation created under a plugin effect answers
  ## `true` and one created under an unrelated effect answers `false`.
  if scope.isNil: return false
  var cur = isonim_owner.getOwner()
  while not cur.isNil:
    if cur == scope: return true
    cur = cur.owner
  false

proc requireScope(ctx: PluginContext; what: string) =
  if ctx.isNil or ctx.scope.isNil:
    raise newException(PluginScopeError,
      "a plugin created " & what & " with no activation scope at all")
  if not withinScope(ctx.scope):
    raise newException(PluginScopeError,
      "plugin '" & ctx.state.id & "' created " & what & " outside its " &
      "activation scope. Every subscription must be owned by the scope so " &
      "that deactivation releases it; one created elsewhere would outlive " &
      "the plugin.")

# ---------------------------------------------------------------------------
# The budget
# ---------------------------------------------------------------------------

proc trip*(st: PluginRunState; effect: string; observed: Duration;
           abortedMidRun: bool) =
  ## Record a violation and suspend the plugin. Idempotent in effect: a second
  ## violation is still recorded (an author wants to see all of them) but the
  ## plugin is already suspended, and suspension is what stops the next run.
  st.violations.add BudgetViolation(plugin: st.id, effect: effect,
    observed: observed, budget: st.budget, abortedMidRun: abortedMidRun)
  st.suspended = true

proc checkBudget*(ctx: PluginContext) =
  ## The cooperative checkpoint. Raises once the current run is past its
  ## deadline; does nothing outside a run.
  ##
  ## Counting the checkpoints is not decoration: a test that asserts a plugin
  ## was stopped mid-run has to distinguish "the checkpoint fired" from "the
  ## body happened to finish", and a checkpoint tally that stayed at zero says
  ## the plugin never gave the host an opportunity.
  if ctx.isNil or ctx.state.isNil or not ctx.state.inRun: return
  inc ctx.state.checkpoints
  let elapsed = getMonoTime() - ctx.state.runStarted
  if elapsed > ctx.state.budget:
    raise newException(PluginBudgetExceeded,
      "plugin '" & ctx.state.id & "': effect '" & ctx.state.runEffect &
      "' passed its " & $ctx.state.budget.inMilliseconds &
      " ms budget at " & $elapsed.inMilliseconds & " ms")

proc runBudgeted*(ctx: PluginContext; effect: string; body: proc()) =
  ## The wrapper every plugin effect and memo body runs inside.
  ##
  ## Every computation a plugin can create through this module — `pluginEffect`,
  ## `pluginMemo`, `pluginComputed`, `pluginRenderEffect`, `pluginOnMount`,
  ## `pluginRoot` — enters its body through here. What makes that the ONLY way
  ## a plugin body is entered is not this proc: it is that the raw
  ## computation-creating primitives are out of a plugin's reach, and that is
  ## two mechanisms rather than one. `codetracer_plugin.nim` keeps them out of
  ## SCOPE, so the unqualified call does not compile;
  ## `ci/test/plugin-reactive-boundary.sh` keeps them out of the SOURCE — of the
  ## plugin AND of every module it can reach — so the module-qualified spelling
  ## `export … except` cannot filter is refused by name, in the plugin's own
  ## file or in a helper it imports. See rule 1a in this module's header: that
  ## second half is the boundary, without it the budget would be advice, and
  ## with it scoped to one file it was defeated by one `import`.
  ##
  ## AND "EVERY" IS GRADED SHAPE BY SHAPE, because for a day it was not. The
  ## case that makes this sentence a measurement — `every wrapped body enters
  ## through the budget wrapper`, which counts `state.runs` — created four of
  ## the five computation shapes and left out `pluginMemo`, so a mutation
  ## dropping the memo's wrapper survived every case in the tree. It creates
  ## five now, and `the body inside a plugin MEMO is budgeted like any other`
  ## asserts the memo's own violation by name.
  ## IT IS RE-ENTRANT, and that is a requirement rather than a nicety.
  ## `pluginRoot` runs its body budgeted, and the natural thing to do inside a
  ## root is create an effect — whose first run is immediate and budgeted too.
  ## A wrapper that cleared `inRun` in the inner `finally` would leave the OUTER
  ## run marked "not running", so every `observe` and `checkBudget` after it
  ## would return without checking a deadline: a plugin could put one wrapped
  ## call at the top of a loop and buy itself an unbounded, uninterruptible
  ## body. The previous run's fields are saved and restored instead.
  if ctx.state.suspended:
    inc ctx.state.refusedRuns
    return
  let st = ctx.state
  let prevInRun = st.inRun
  let prevStarted = st.runStarted
  let prevEffect = st.runEffect
  let started = getMonoTime()
  st.inRun = true
  st.runStarted = started
  st.runEffect = effect
  inc st.runs
  var aborted = false
  try:
    body()
  except PluginBudgetExceeded:
    aborted = true
  finally:
    st.inRun = prevInRun
    st.runStarted = prevStarted
    st.runEffect = prevEffect
  let elapsed = getMonoTime() - started
  st.lastElapsed = elapsed
  if elapsed > st.budget:
    st.trip(effect, elapsed, aborted)

# ---------------------------------------------------------------------------
# Observation (§5.1) — signals, read inside the plugin's own memos and effects
# ---------------------------------------------------------------------------

proc observe*[T](ctx: PluginContext; s: Signal[T]): T =
  ## Read a core signal. Tracked exactly as a direct read is — this calls
  ## `isonim`'s `val`, it does not reimplement tracking — and it checks the
  ## deadline first, so a loop that reads is a loop that can be stopped.
  ctx.checkBudget()
  isonim_signals.val(s)

proc observe*[T](ctx: PluginContext; m: Memo[T]): T =
  ctx.checkBudget()
  isonim_computation.val(m)

proc recordCreated(ctx: PluginContext; owner: OwnerBase; before: int;
                   what, name: string) =
  ## Read the just-created computation back off the ambient owner's `owned`
  ## sequence — the same sequence `createComputation` appended it to — and
  ## record it on the run state.
  ##
  ## THE `else` IS THE POINT. See `PluginAccountingError` for what a dropped
  ## record costs and why it is raised rather than skipped.
  if owner.owned.len != before + 1:
    raise newException(PluginAccountingError,
      "plugin '" & ctx.state.id & "': creating " & what & " '" & name &
      "' left the activation owner holding " & $owner.owned.len &
      " computation(s) where " & $(before + 1) & " was expected, so the host " &
      "cannot say which computation it just created. `cleanNode(scope)` still " &
      "releases it, but `deactivate`'s csClean sweep would silently skip it " &
      "and a run already queued inside a batch would survive the release.")
  ctx.state.effects.add owner.owned[^1]

proc pluginEffect*(ctx: PluginContext; name: string; body: proc()) =
  ## Create an effect owned by the plugin's activation scope, whose body runs
  ## inside the budget wrapper. `isonim.createEffect`, denied to plugins by
  ## `codetracer_plugin.nim` and by `ci/test/plugin-reactive-boundary.sh`.
  requireScope(ctx, "an effect")
  let owner = isonim_owner.getOwner()
  let before = owner.owned.len
  let c = ctx
  isonim_computation.createEffect(proc() = runBudgeted(c, name, body))
  recordCreated(ctx, owner, before, "an effect", name)

proc pluginRenderEffect*(ctx: PluginContext; name: string; body: proc()) =
  ## `isonim.createRenderEffect`. It differs from `createEffect` only in the
  ## scheduling `isonim` intends for it later (its own docstring: "Same as
  ## createEffect for now"), so it is wrapped rather than denied outright —
  ## every denied primitive has a replacement, which is what makes the denial
  ## a narrowing.
  requireScope(ctx, "a render effect")
  let owner = isonim_owner.getOwner()
  let before = owner.owned.len
  let c = ctx
  isonim_computation.createRenderEffect(proc() = runBudgeted(c, name, body))
  recordCreated(ctx, owner, before, "a render effect", name)

proc pluginComputed*(ctx: PluginContext; name: string; body: proc()) =
  ## `isonim.createComputed` — a PURE computation, which `isonim` runs ahead of
  ## the effects in a batch. That ordering is why it cannot be left raw: a pure
  ## computation blocking for a second delays every effect behind it, on the
  ## same thread, and §5.3's frozen screen does not care which queue the work
  ## was sitting in.
  requireScope(ctx, "a computed")
  let owner = isonim_owner.getOwner()
  let before = owner.owned.len
  let c = ctx
  isonim_computation.createComputed(proc() = runBudgeted(c, name, body))
  recordCreated(ctx, owner, before, "a computed", name)

proc pluginOnMount*(ctx: PluginContext; name: string; body: proc()) =
  ## `isonim.onMount`, which is `createEffect(untrack(fn))` — a computation, so
  ## it is a computation the host owns and budgets. It runs once because the
  ## untracked body subscribes to nothing, not because anything here stops it.
  requireScope(ctx, "an onMount")
  let owner = isonim_owner.getOwner()
  let before = owner.owned.len
  let c = ctx
  isonim_computation.onMount(proc() = runBudgeted(c, name, body))
  recordCreated(ctx, owner, before, "an onMount", name)

proc pluginMemo*[T](ctx: PluginContext; name: string;
                    body: proc(): T): Memo[T] =
  ## §5.1's other half: "an extension observes by reading signals inside its
  ## own memos". The memo's body is budgeted exactly as an effect's is,
  ## because a memo that takes a second to recompute freezes the same screen.
  ##
  ## THAT SENTENCE IS NOW GRADED, and for a day it was only promised — here, in
  ## §5.4's layer table and in PLAT-7's deliverable 6, three documents and no
  ## test. Replacing the `runBudgeted` below with a bare `inner()` SURVIVED all
  ## 23 lifecycle cases, all 6 budget cases, and the budget suite run alone: the
  ## property was true in this file and nothing measured it. The case is `the
  ## body inside a plugin MEMO is budgeted like any other` and the mutation is
  ## arm N6 of `run-plat7-boundary-mutations.py`.
  ##
  ## The reason it needed its own case rather than an assertion bolted onto the
  ## root's is in the shape below: an effect wraps the body isonim runs, and
  ## this wraps an INNER closure and returns a captured `latest` afterwards — so
  ## dropping the wrapper still produces the right value, and only a violation
  ## count notices.
  requireScope(ctx, "a memo")
  let owner = isonim_owner.getOwner()
  let before = owner.owned.len
  let c = ctx
  var latest: T
  let inner = proc() =
    latest = body()
  let compute = proc(): T =
    runBudgeted(c, name, inner)
    latest
  result = isonim_computation.createMemo(compute)
  recordCreated(ctx, owner, before, "a memo", name)

proc pluginRoot*(ctx: PluginContext; name: string;
                 body: proc(disposeRoot: proc())) =
  ## `isonim.createRoot`, and THE ESCAPE PLAT-7 LEFT OPEN.
  ##
  ## `createRoot` builds an `OwnerBase`, sets `root.owner` to the ambient owner
  ## and never adds the root to that owner's `owned` — it cannot, because
  ## `owned` is a `seq[ComputationBase]` and a root is a plain `OwnerBase`. So
  ## `cleanNode(scope)` walks straight past it and every computation created
  ## inside outlives the plugin. `requireScope` does not catch it: the root is
  ## created INSIDE the scope, which is exactly what that guard asks for.
  ##
  ## The fix is one line and it is the `cleanups` list rather than `owned`:
  ## `cleanNode` runs every cleanup registered on the scope, so registering the
  ## root's own `dispose` there makes deactivation release the root by the same
  ## single call that releases everything else. The plugin still gets
  ## `disposeRoot` to call earlier if it wants; disposing twice is
  ## `cleanNode(root)` over an already-emptied node, which is a no-op.
  ##
  ## The body is budgeted, because `createRoot` runs it synchronously and a
  ## plugin burning a second in there freezes the same screen as one burning it
  ## in an effect.
  requireScope(ctx, "a reactive root")
  let scope = ctx.scope
  let c = ctx
  isonim_owner.createRoot(proc(dispose: proc()) =
    scope.cleanups.add dispose
    runBudgeted(c, name, proc() = body(dispose)))

proc onPluginCleanup*(ctx: PluginContext; fn: proc()) =
  ## Register a cleanup on the plugin's scope. This is `isonim.onCleanup`, and
  ## it is exposed because a plugin holding a non-reactive resource (PLAT-8's
  ## processes and sockets) needs somewhere to release it.
  ##
  ## IT IS NOT THE DEACTIVATION MECHANISM AND MUST NOT BECOME ONE. A plugin
  ## that registered no cleanup at all is still fully released, because the
  ## release is `cleanNode(scope)` unlinking its computations. This is for
  ## what the reactive graph does not own.
  requireScope(ctx, "a cleanup")
  isonim_owner.onCleanup(fn)
