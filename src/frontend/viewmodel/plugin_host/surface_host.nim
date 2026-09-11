## plugin_host/surface_host.nim — PLAT-9's runtime half: the contributed
## surfaces a host actually holds, the dependency probe behind them, the
## degradation they render when a dependency is absent, and the fault boundary
## that keeps a broken one from taking the debugger with it.
##
## This module is NOT on the Embed SDK facade and is not re-exported by it, for
## the same reason `host.nim` is not: a plugin does not manage plugins. What a
## PLUGIN sees of this milestone is `plugin_api.contributeView` and the view
## builders, and nothing here.
##
## ## THE FOUR THINGS THIS OWNS, AND THE SPEC SENTENCE FOR EACH
##
## 1. **Which surfaces exist here.** §6.3: a required surface with no view for
##    the active front-end fails the plugin (that refusal is
##    `plugin_model/surfaces.surfaceRefusals`, taken during resolution); an
##    optional one "is simply not present", which is this module leaving it out
##    of the registry. `absentSurfaces` still NAMES it, because a user asking
##    why a pane is missing is owed an answer and an empty list cannot give one.
##
## 2. **Whether each surface's dependencies are there.** §8.2: "A plugin
##    declares, per surface, which of its dependencies that surface needs. A
##    missing one degrades **that surface**, not the whole plugin, and not the
##    application."
##
## 3. **What a degraded surface renders.** §8.2: "The degradation says **what
##    is missing and how to get it** — a name and an install action, not
##    'unavailable'", and "A degraded surface is **visibly degraded**". The
##    value is `PaneDegradation.pdDependencyMissing` — the EXISTING model, per
##    §8.2's "inventing a parallel 'plugin unavailable' banner would be a
##    second mechanism saying the same thing worse" — and the detail rides
##    beside it as a `DependencyGap`, the way §14's actions ride beside
##    `ReplayAvailability`.
##
## 4. **What happens when a view throws.** §7: "an extension's view tree is
##    mounted inside one [an `errorBoundary`], and a fault renders a reported
##    failure in that surface, not a blank screen or a crash"; "A fault is
##    attributed"; "Repeated faults disable the extension for the session".
##
## ## WHY THE BOUNDARY IS NOT `isonim.errorBoundary` ITSELF
##
## `isonim/dsl/components.errorBoundary` is the containment primitive §7 names,
## and it is a MOUNT-time boundary: it calls `body()` once, appends the node or
## the fallback to a parent, and returns. §7's third bullet is about a view
## "that throws on every frame", which needs a boundary that re-arms — and a
## count, because "repeated" is a number. `renderSurface` below is that
## boundary: same containment, applied per render and carrying the attribution
## and the tally §7 asks for. It is also renderer- and node-agnostic, which
## `errorBoundary` cannot be: it takes a `renderer` and a `parent`, and a
## surface host that required one could not be exercised without a DOM.
##
## That difference is stated rather than glossed because it is the one place
## this milestone does not simply use the primitive the spec names.
##
## ## THE BOUNDARY CATCHES `Defect` TOO, AND PROMISES SOMETHING DIFFERENT ABOUT IT
##
## Nim splits `Exception` into `CatchableError` and `Defect`, and until
## 2026-09-11 this boundary caught only the first. That left §7's "a failing
## extension must not take down the debugger" false for **the commonest Nim
## runtime failure**: an ordinary out-of-range read in a plugin's view raises
## `IndexDefect`, which is not a `CatchableError`, so it went straight past the
## `except`, past the host, and out of whatever was drawing the frame.
## `FieldDefect`, `RangeDefect`, `DivByZeroDefect` and a nil dereference are
## the same shape. The measurement, taken here rather than reasoned about:
##
##   | raised inside a view          | before          | now                  |
##   | ----------------------------- | --------------- | -------------------- |
##   | `ThrowingViewError` (catchable) | contained       | contained, unchanged |
##   | `IndexDefect`                 | ESCAPED         | contained            |
##
## **A `Defect` does not re-arm, and that is the whole difference in policy.**
## A `CatchableError` is a handled failure: the view said "I cannot build this
## tree", nothing else is implied, and §7's `DefaultSurfaceFaultLimit` gives it
## three frames before the plugin is disabled, because one fault can be a
## transient. A `Defect` says the opposite — an assumption the program is built
## on did not hold, so the state the view was halfway through mutating may be
## arbitrary. Re-entering that view is not a retry, it is a second run over
## broken state. So the FIRST `Defect` disables **that surface** for the
## session: the fault is recorded and attributed exactly as any other, the
## surface renders a report saying it will not be retried, and `rec.view` is
## never entered again. The rest of the plugin is left alone — a surface's
## broken invariant is not evidence about its siblings, and widening the blast
## radius past what was measured is the failure §8.2 spends a paragraph on in
## the other direction.
##
## **`--panics:on` makes this boundary unreachable, and no repair here can
## change that.** Measured on nim 2.2.8:
##
##   | build                     | `nimPanics` | an `IndexDefect` in a view          |
##   | ------------------------- | ----------- | ----------------------------------- |
##   | `--panics:off` (default)  | undefined   | raised as an exception; caught here |
##   | `--panics:on`             | defined     | fatal at the raise site; the process |
##   |                           |             | prints `Unhandled exception … [IndexDefect]` and exits |
##
## **CodeTracer builds with `--panics:off`** — `config.nims` sets no `panics`
## switch and nothing else in the tree does, so `nimPanics` is undefined in
## every lane and in the product build, and the containment below is live. The
## `except Defect` clause still compiles under `--panics:on`; it is simply
## never reached, because the runtime aborts before unwinding. So the honest
## statement of what §7 buys is conditional and is written down rather than
## assumed: *with panics off, a `Defect` in a plugin view costs that surface
## and nothing else; with panics on, it costs the process, and the only
## remedies are at the language level.* Anyone turning the switch on is
## turning this guarantee off, which is why the switch is named here.
##
## ## NO MOCKS
##
## The probe is `plugin_io.resolveExecutable` — PLAT-8's own PATH policy,
## `findExe` over the process environment CodeTracer was started with — so a
## dependency is present exactly when a program is really on the real PATH.
## The revision signal is a real `isonim` signal and the degradation memo is a
## real `isonim` memo. There is nothing here standing in for anything.

import std/[sets, strutils, tables]

import isonim/core/signals as isonim_signals
import isonim/core/computation as isonim_computation

import ../store/degraded_state
import ./plugin_api
import ./plugin_io

export degraded_state

type
  DependencyProbe* = enum
    ## The answer to "is this surface's declared tool here?".
    ##
    ## `dpUnprobed` IS THE ZERO VALUE, so a record whose probe never ran reads
    ## as "nobody has asked" rather than as "present". An unprobed dependency
    ## degrades the surface exactly as an absent one does — the honest answer
    ## to "can this surface work?" before anybody looked is "we do not know",
    ## and rendering as though it could is the silent-completeness §8.2 calls
    ## "the plugin-model version of a green suite that asserts nothing".
    dpUnprobed
    dpPresent
    dpAbsent
    dpUnsupported
      ## PLAT-8's §8.1 primitives are absent on the JS backend ("a browser has
      ## no child processes"), so a declared tool cannot be resolved there
      ## however it is installed. A separate value because the REMEDY differs,
      ## and `install this` on a host that could not run it is the retry that
      ## cannot succeed.

  DependencyGap* = object
    ## §8.2's "what is missing and how to get it", as a value.
    plugin*: PluginId
    surface*: string
    qualifiedId*: string
    tool*: string
    probe*: DependencyProbe
    install*: string
      ## The manifest's own install action for this surface. Non-empty by
      ## construction: `parseManifest` refuses a `needs` without an `install`
      ## (`pecMissingInstallHint`), so a gap can always say how to close it.

  SurfaceFault* = object
    ## §7's "A fault is attributed. 'An extension failed' is useless; the name,
    ## the surface and the error are the minimum."
    plugin*: PluginId
    surface*: string
    qualifiedId*: string
    message*: string
      ## The exception's own message.
    exceptionName*: string
    ordinal*: int
      ## Which fault this was for this surface, 1-based. "Repeated faults
      ## disable the extension" is a statement about a count, and a report
      ## that cannot say WHICH repetition tripped the limit cannot be read.
    defect*: bool
      ## Whether this fault was a `Defect` rather than a `CatchableError`. A
      ## SEPARATE FIELD RATHER THAN A SUBSTRING OF `exceptionName`, because a
      ## consumer branches on it — the two have different consequences (see the
      ## module header) and "does the name end in `Defect`" is a second,
      ## weaker, string-matching copy of a question the boundary already
      ## answered by which `except` clause it entered.

  SurfaceRecord* = ref object
    plugin*: PluginId
    contribution*: Contribution
    qualifiedId*: string
      ## For a pane, `contributed_pane_id.qualifiedPaneId`. For a marker or a
      ## status item it is composed the same way, so every surface in the
      ## registry has one namespaced identity and the registry has one key.
    choice*: ViewChoice
      ## §6.2's decision for the ACTIVE front-end, taken once at registration.
    probes*: OrderedTable[string, DependencyProbe]
    view*: PluginViewProc
      ## `nil` until the plugin contributes one. A registered surface with no
      ## view is reported by `surfacesWithoutViews`, not rendered blank.
    faults*: int
    disabled*: bool
      ## Set when this surface's own fault count reaches the limit, and set on
      ## the FIRST `Defect` — see `defected`.
    defected*: bool
      ## A `Defect` was raised inside this surface's render. The surface is
      ## disabled for the session and is never re-armed, whatever the fault
      ## limit says: the limit exists because a `CatchableError` can be a
      ## transient, and a broken invariant is not one. Kept as its own flag
      ## rather than inferred from `faults >= faultLimit`, because a
      ## `Defect`-disabled surface can have exactly one fault.

  SurfaceHost* = ref object
    frontEnd*: FrontEnd
    extensionsEnabled*: bool
      ## `--no-extensions`. See `newSurfaceHost` for exactly what `false`
      ## guarantees.
    faultLimit*: int
      ## §7's "repeated", as a number the application chooses. The default is
      ## in `DefaultSurfaceFaultLimit`.
    records: OrderedTable[string, SurfaceRecord]
    order*: seq[string]
      ## Registration order, so every report is stable.
    faults*: seq[SurfaceFault]
    collisions*: seq[string]
      ## A registration whose qualified id was already taken. See `register`
      ## and `report`: the registry has ONE key per surface, so a second
      ## claimant has to be dropped, and a drop nobody can enumerate is the
      ## silently-missing contribution this milestone refuses everywhere else.
    disabledPlugins: HashSet[PluginId]
    probeRevision*: Signal[int]
      ## Bumped by `reprobe`. A surface's degradation memo reads it, so
      ## installing a missing tool and firing the declared trigger re-renders
      ## the pane — §8.2's "does not require restarting CodeTracer", as a
      ## dependency edge in the reactive graph rather than as a callback
      ## somebody has to remember to fire.

const
  DefaultSurfaceFaultLimit* = 3
    ## §7: "Repeated faults disable the extension for the session, with a
    ## report. A view that throws on every frame is worse than one that is
    ## absent."
    ##
    ## Three rather than one: a single fault can be a transient — a value that
    ## was not there yet on the first frame — and disabling a plugin for the
    ## session on one of those would make the containment worse than the fault.
    ## Three consecutive frames is not a transient.

  NoExtensionsFlag* = "--no-extensions"
    ## Spelled here, once, so the CLI's selector and the host's own report
    ## cannot disagree about what a user has to type.

proc newSurfaceHost*(frontEnd: FrontEnd; extensionsEnabled = true;
                     faultLimit = DefaultSurfaceFaultLimit): SurfaceHost =
  ## `extensionsEnabled = false` IS `--no-extensions`, AND THIS IS WHAT IT
  ## GUARANTEES (§7's last bullet — "a single flag must produce a working
  ## debugger, and that path is tested, because it is the recovery route when
  ## an extension makes the product unusable"):
  ##
  ##   * `register` records nothing, so the surface registry is empty and no
  ##     contributed pane can enter a layout;
  ##   * no dependency is probed, so no process, PATH lookup or filesystem
  ##     access happens on behalf of an extension;
  ##   * `renderSurface` refuses before calling any plugin code, so no
  ##     third-party line executes on a render path;
  ##   * `report` says so, and names the flag, so a user who forgot they
  ##     passed it is not left debugging their plugin.
  ##
  ## What it does NOT do is unload anything: a host is constructed with the
  ## flag, it is not toggled. `PluginHost` refuses to activate at all when
  ## extensions are off, which is the other half and is asserted there.
  SurfaceHost(frontEnd: frontEnd, extensionsEnabled: extensionsEnabled,
              faultLimit: faultLimit,
              records: initOrderedTable[string, SurfaceRecord](),
              disabledPlugins: initHashSet[PluginId](),
              probeRevision: createSignal(0))

# ---------------------------------------------------------------------------
# The probe (§8.2)
# ---------------------------------------------------------------------------

proc probeTool*(name: string): DependencyProbe =
  ## Is `name` on the host's PATH?
  ##
  ## `plugin_io.resolveExecutable` IS THE RESOLVER, not a second lookup written
  ## here. §8.1.1 gives the host one PATH policy and PLAT-8 implemented it —
  ## including the measured `followSymlinks = false`, without which a
  ## multi-call binary resolves to a different program. A surface host with its
  ## own `findExe` would be a second copy of that predicate, and the two would
  ## eventually disagree about whether a tool "is there"
  ## (Verification-Harness-Traps §14).
  when defined(js):
    dpUnsupported
  else:
    if resolveExecutable(name).len > 0: dpPresent else: dpAbsent

proc probeInto(rec: SurfaceRecord): bool =
  ## Re-probe every dependency of one surface. `true` when any answer changed.
  for tool in rec.contribution.needs:
    let before =
      if rec.probes.hasKey(tool): rec.probes[tool] else: dpUnprobed
    let now = probeTool(tool)
    if now != before:
      rec.probes[tool] = now
      result = true
    elif not rec.probes.hasKey(tool):
      rec.probes[tool] = now

# ---------------------------------------------------------------------------
# Registration (§6.1, §6.3)
# ---------------------------------------------------------------------------

proc register*(sh: SurfaceHost; m: PluginManifest): seq[string]
              {.discardable.} =
  ## Register every rendering surface of `m` that HAS a view on this host's
  ## front-end, and probe its dependencies. Returns the qualified ids
  ## registered.
  ##
  ## A required surface with no view never reaches here, because
  ## `resolve`'s phase 3b already failed the plugin and `PluginHost` never
  ## activates it. An OPTIONAL surface with no view is left out — §6.3's
  ## "simply not present" — and `absentSurfaces` names it.
  if not sh.extensionsEnabled: return
  for c in m.contributions:
    if c.kind notin RenderingContributionKinds: continue
    let choice = chooseView(c, sh.frontEnd)
    if choice.kind == vcNone: continue
    let qualified = qualifiedPaneId(m.id, c.id)
    if sh.records.hasKey(qualified):
      # THE LAST RESORT, NOT THE RULE. The rule is at load time:
      # `parseManifest` refuses two RENDERING surfaces of one manifest sharing
      # a local id (`pecDuplicateContribution`), naming both, because
      # `qualifiedPaneId` does not carry the contribution kind and a pane and a
      # marker called `metrics` would otherwise compose one key. Reaching here
      # means that refusal was bypassed, so the drop is RECORDED and printed by
      # `report` rather than being a `continue` nobody can observe.
      sh.collisions.add "plugin '" & m.id & "': " & $c.kind & " surface '" &
        c.id & "' was dropped — the qualified id '" & qualified &
        "' is already registered by " &
        $sh.records[qualified].contribution.kind & " surface '" &
        sh.records[qualified].contribution.id & "'"
      continue
    let rec = SurfaceRecord(plugin: m.id, contribution: c,
                            qualifiedId: qualified, choice: choice,
                            probes: initOrderedTable[string, DependencyProbe]())
    discard probeInto(rec)
    sh.records[qualified] = rec
    sh.order.add qualified
    result.add qualified

proc absentSurfaces*(sh: SurfaceHost; m: PluginManifest): seq[Contribution] =
  ## §6.3's "simply not present", NAMED. See `surfaces.absentOptionalSurfaces`.
  absentOptionalSurfaces(m, sh.frontEnd)

proc attachViews*(sh: SurfaceHost; ctx: PluginContext): int {.discardable.} =
  ## Join the views a plugin contributed during `activate` to the surfaces it
  ## declared. Returns how many surfaces got one.
  ##
  ## A view contributed for a surface that is NOT in the registry is silently
  ## unused here and reported by `viewsWithoutSurfaces` — it is the optional
  ## surface §6.3 left out, which is the one case where a plugin legitimately
  ## supplies a view nobody will render. `contributeView` has already refused
  ## the case where the manifest never declared the surface at all.
  if not sh.extensionsEnabled: return 0
  if ctx.isNil: return 0
  for surfaceId, view in ctx.views.pairs:
    let qualified = qualifiedPaneId(ctx.manifest.id, surfaceId)
    if not sh.records.hasKey(qualified): continue
    sh.records[qualified].view = view
    inc result

proc viewsWithoutSurfaces*(sh: SurfaceHost; ctx: PluginContext): seq[string] =
  ## Views the plugin supplied for surfaces this front-end does not render.
  if ctx.isNil: return
  for surfaceId in ctx.views.keys:
    let qualified = qualifiedPaneId(ctx.manifest.id, surfaceId)
    if not sh.records.hasKey(qualified): result.add surfaceId

proc surfacesWithoutViews*(sh: SurfaceHost): seq[string] =
  ## Registered surfaces no plugin ever supplied a view for. §6.1's blank
  ## region, as a list rather than as an empty pane.
  for id in sh.order:
    if sh.records[id].view.isNil: result.add id

proc has*(sh: SurfaceHost; qualifiedId: string): bool =
  sh.records.hasKey(qualifiedId)

proc record*(sh: SurfaceHost; qualifiedId: string): SurfaceRecord =
  if sh.records.hasKey(qualifiedId): sh.records[qualifiedId] else: nil

proc surfaceIds*(sh: SurfaceHost): seq[string] = sh.order

proc panesOf*(sh: SurfaceHost; plugin: PluginId): seq[string] =
  for id in sh.order:
    let rec = sh.records[id]
    if rec.plugin == plugin and rec.contribution.kind == ckPane:
      result.add id

proc contributedPaneIds*(sh: SurfaceHost): seq[string] =
  ## Every contributed PANE this host would let a layout place. The set a
  ## layout decoder resolves an unknown contributed pane against — see
  ## `layout_model.classifyContributedPane`.
  for id in sh.order:
    if sh.records[id].contribution.kind == ckPane: result.add id

# ---------------------------------------------------------------------------
# Degradation (§8.2), through the EXISTING model
# ---------------------------------------------------------------------------

proc dependencyState*(sh: SurfaceHost; qualifiedId: string):
                     PluginDependencyState =
  ## The fifth axis of `DegradedStateSnapshot`, for one surface.
  ##
  ## A surface with no declared dependency is `pdsSatisfied` — it declared
  ## nothing to be missing. Otherwise the WORST answer wins, and `dpUnprobed`
  ## counts as absent: see `DependencyProbe`.
  let rec = sh.record(qualifiedId)
  if rec.isNil: return pdsSatisfied
  for tool, probe in rec.probes.pairs:
    case probe
    of dpPresent: discard
    of dpUnsupported: return pdsUnsupported
    of dpAbsent, dpUnprobed: return pdsAbsent
  pdsSatisfied

proc snapshotFor*(sh: SurfaceHost; qualifiedId: string;
                  core: DegradedStateSnapshot): DegradedStateSnapshot =
  ## The session's four axes, plus this surface's dependency axis. ONE
  ## snapshot, so `resolveDegradation` is the same call a built-in pane makes.
  result = core
  result.dependency = sh.dependencyState(qualifiedId)

proc surfaceDegradation*(sh: SurfaceHost; qualifiedId: string;
                         core: DegradedStateSnapshot): PaneDegradation =
  ## §8.2's reuse, spelled out: `resolveDegradation`, the existing precedence,
  ## and `ContributedPaneDegradations` as this pane's sensitivity set. There is
  ## no second resolver and no second enum.
  resolveDegradation(sh.snapshotFor(qualifiedId, core),
                     ContributedPaneDegradations)

proc gapFor*(sh: SurfaceHost; qualifiedId: string): seq[DependencyGap] =
  ## Every unmet dependency of one surface, with the remedy.
  let rec = sh.record(qualifiedId)
  if rec.isNil: return
  for tool, probe in rec.probes.pairs:
    if probe == dpPresent: continue
    result.add DependencyGap(plugin: rec.plugin, surface: rec.contribution.id,
                             qualifiedId: qualifiedId, tool: tool,
                             probe: probe, install: rec.contribution.install)

proc gaps*(sh: SurfaceHost): seq[DependencyGap] =
  for id in sh.order:
    result.add sh.gapFor(id)

func describe*(g: DependencyGap): string =
  ## §8.2: "a name and an install action, not 'unavailable'". THE TOOL AND THE
  ## REMEDY ARE BOTH IN THE SENTENCE, and the suite asserts both substrings
  ## rather than that the string is non-empty.
  let cause =
    case g.probe
    of dpPresent: "is present"
    of dpAbsent: "is not on your PATH"
    of dpUnprobed: "has not been probed yet"
    of dpUnsupported:
      "cannot be run by this front-end, which has no process support"
  "plugin '" & g.plugin & "': surface '" & g.surface & "' needs '" & g.tool &
    "', which " & cause & ". To get it: " & g.install

# ---------------------------------------------------------------------------
# Rendering, and §7's fault containment
# ---------------------------------------------------------------------------

proc isPluginDisabled*(sh: SurfaceHost; plugin: PluginId): bool =
  plugin in sh.disabledPlugins

proc isSurfaceDisabled*(sh: SurfaceHost; qualifiedId: string): bool =
  let rec = sh.record(qualifiedId)
  if rec.isNil: return false
  rec.disabled or sh.isPluginDisabled(rec.plugin)

proc disablePlugin*(sh: SurfaceHost; plugin: PluginId) =
  ## Every surface this plugin owns stops rendering for the rest of the
  ## session. §7: "Repeated faults disable the extension for the session."
  sh.disabledPlugins.incl plugin
  for id in sh.order:
    if sh.records[id].plugin == plugin: sh.records[id].disabled = true

func faultNode(f: SurfaceFault): ViewNode =
  ## §7: "a fault renders a reported failure in that surface, not a blank
  ## screen or a crash", and the report names the plugin, the surface and the
  ## error — §7's stated minimum, all three in the text a user reads.
  ##
  ## A `Defect` additionally says that this surface is finished for the
  ## session, because a report that looks identical to a retryable fault while
  ## the surface is never retried is a report that answers the wrong question.
  let tail =
    if f.defect:
      " That is a Defect — a broken invariant rather than a handled error — " &
      "so this surface will not be rendered again this session."
    else:
      ""
  viewText("surface-fault:" & f.qualifiedId,
    "This view failed. plugin '" & f.plugin & "', surface '" & f.surface &
    "': " & f.exceptionName & ": " & f.message & tail)

proc disabledNode(sh: SurfaceHost; rec: SurfaceRecord): ViewNode =
  ## A `proc` rather than a `func` because it asks `isPluginDisabled`: the two
  ## ways a surface stops rendering are DIFFERENT FACTS and a reader is owed
  ## the right one. `disablePlugin` stops every surface the plugin owns; a
  ## `Defect` stops exactly the one that raised it.
  if rec.defected and not sh.isPluginDisabled(rec.plugin):
    viewText("surface-disabled:" & rec.qualifiedId,
      "surface '" & rec.contribution.id & "' of plugin '" & rec.plugin &
      "' is disabled for this session: it raised a Defect (" &
      $rec.faults & " fault(s)), which is contained but never retried, " &
      "because a broken invariant is not a transient. The rest of '" &
      rec.plugin & "' is still running. Restart CodeTracer to try it again.")
  else:
    viewText("surface-disabled:" & rec.qualifiedId,
      "plugin '" & rec.plugin & "' is disabled for this session after " &
      $rec.faults & " fault(s) in surface '" & rec.contribution.id &
      "'. Restart CodeTracer to try it again.")

func degradedNode*(sh: SurfaceHost; qualifiedId: string): ViewNode =
  ## §8.2's "A degraded surface is **visibly degraded**", as the node the
  ## surface renders instead of its own view. Every gap's name AND remedy is
  ## in the text: a pane that said "unavailable" would be the silent removal
  ## CTUI-11 forbids.
  var lines: seq[string] = @[]
  for g in sh.gapFor(qualifiedId):
    lines.add describe(g)
  viewText("surface-degraded:" & qualifiedId, lines.join("\n"))

proc containDefect(sh: SurfaceHost; rec: SurfaceRecord;
                   qualifiedId: string; d: ref Defect): ViewNode =
  ## §7's containment for the fault class the `CatchableError` arm cannot see.
  ## See this module's header for what the boundary promises after one, why it
  ## is different from the `CatchableError` promise, and what `--panics:on`
  ## does to both.
  ##
  ## It is a named proc rather than four lines inside the `except`, so the
  ## POLICY has one call site and one mutation target rather than being spread
  ## through a handler (Verification-Harness-Traps §14).
  inc rec.faults
  let fault = SurfaceFault(plugin: rec.plugin, surface: rec.contribution.id,
                           qualifiedId: qualifiedId, message: d.msg,
                           exceptionName: $d.name, ordinal: rec.faults,
                           defect: true)
  sh.faults.add fault
  # ORDER MATTERS AND IS NOT INCIDENTAL: the record is marked before the node
  # is built, so `faultNode` cannot describe a surface the host has not yet
  # stopped calling. The two must not be able to disagree.
  rec.defected = true
  rec.disabled = true
  faultNode(fault)

proc noExtensionsNode*(sh: SurfaceHost; qualifiedId: string): ViewNode =
  viewText("surface-no-extensions:" & qualifiedId,
    "Extensions are off for this session (" & NoExtensionsFlag &
    "). Restart without the flag to load them.")

proc renderSurface*(sh: SurfaceHost; qualifiedId: string;
                    core = initDegradedStateSnapshot()): ViewNode =
  ## Render one surface, inside the boundary. NEVER returns `nil` and never
  ## propagates — §7's "A failing extension must not take down the debugger."
  ##
  ## The order of the arms IS the policy, and each one is a §-sentence:
  ##
  ##   1. extensions off          — no plugin code runs at all (§7's flag)
  ##   2. unknown surface         — a typed report, not a blank region (§6.1)
  ##   3. already disabled        — "repeated faults disable it" (§7), and a
  ##                                surface that raised a `Defect` once
  ##   4. no view contributed     — a surface nobody renders is reported (§6.1)
  ##   5. degraded                — the dependency gap, visibly (§8.2)
  ##   6. the plugin's own view, inside `try` (§7), catching BOTH `Defect` and
  ##      `CatchableError` — see the module header for why the two promise
  ##      different things
  ##
  ## Arm 5 sits BEFORE arm 6 deliberately: a surface whose tool is missing must
  ## not be handed a chance to render as though it were complete, which §8.2
  ## calls "the plugin-model version of a green suite that asserts nothing".
  ##
  ## ARM 5 IS ONE TEST AND WAS WRITTEN AS TWO. It read
  ## `surfaceDegradation(...) != pdNone and dependencyState(...) !=
  ## pdsSatisfied`, and the first conjunct is IMPLIED by the second:
  ## `degradationPresent(pdDependencyMissing)` is exactly
  ## `dependency != pdsSatisfied`, `pdDependencyMissing` is in
  ## `ContributedPaneDegradations`, and `resolveDegradation` therefore cannot
  ## return `pdNone` while the dependency axis is unsatisfied — it returns that
  ## row or a higher-precedence one, and both are non-`pdNone`. So the conjunct
  ## could never be the reason this arm did not fire. It was not merely
  ## redundant on inspection: a mutation that removed it SURVIVED the suite, and
  ## 450 snapshots never reached a state in which the two halves disagreed. The
  ## remaining test is the one that is load-bearing — `degradedNode` renders the
  ## gap list, so firing on a degradation that is not a dependency gap would
  ## render an EMPTY report, which is §6.1's blank region.
  if not sh.extensionsEnabled:
    return sh.noExtensionsNode(qualifiedId)
  let rec = sh.record(qualifiedId)
  if rec.isNil:
    return viewText("surface-unknown:" & qualifiedId,
      "No extension in this session contributes the surface '" & qualifiedId &
      "'. It may come from an extension that is not installed or did not load.")
  if sh.isSurfaceDisabled(qualifiedId):
    return sh.disabledNode(rec)
  if rec.view.isNil:
    return viewText("surface-viewless:" & qualifiedId,
      "plugin '" & rec.plugin & "' declares surface '" & rec.contribution.id &
      "' but contributed no view for it.")
  if sh.dependencyState(qualifiedId) != pdsSatisfied:
    return sh.degradedNode(qualifiedId)
  try:
    result = rec.view()
    if result.isNil:
      # A view that returns nil is the blank region by another route, so it is
      # a FAULT rather than an empty pane. Counted like any other, because a
      # view that returns nil on every frame is exactly as bad as one that
      # throws on every frame.
      raise newException(PluginSurfaceError,
        "the view returned nil, which would render as a blank region")
  # NOT `CatchableError` ALONE, and not one wider `except Exception` either:
  # the two classes are contained the same way and promised different things,
  # so they are two clauses and the difference is visible at the boundary
  # rather than reconstructed from the exception's name. See `containDefect`.
  except Defect as d:
    return sh.containDefect(rec, qualifiedId, d)
  except CatchableError as e:
    inc rec.faults
    let fault = SurfaceFault(plugin: rec.plugin, surface: rec.contribution.id,
                             qualifiedId: qualifiedId, message: e.msg,
                             exceptionName: $e.name, ordinal: rec.faults)
    sh.faults.add fault
    if rec.faults >= sh.faultLimit:
      sh.disablePlugin(rec.plugin)
      return sh.disabledNode(rec)
    return faultNode(fault)

# ---------------------------------------------------------------------------
# Re-probing on a declared trigger (§8.2)
# ---------------------------------------------------------------------------

proc reprobe*(sh: SurfaceHost; occurred: ActivationEvent): seq[string]
             {.discardable.} =
  ## §8.2: "The dependency is re-probed on a declared trigger, so installing
  ## the missing component does not require restarting CodeTracer."
  ##
  ## A surface is re-probed only when it DECLARED this trigger. The comparison
  ## is `activation.matches` — §4.2's own matcher, exact on kind and on value —
  ## so a trigger cannot mean one thing in an activation and another here.
  ##
  ## Returns the surfaces whose answer CHANGED, and bumps `probeRevision` only
  ## when something did: a signal written on every trigger would re-run every
  ## contributed pane's memo whenever a trace opened.
  if not sh.extensionsEnabled: return
  for id in sh.order:
    let rec = sh.records[id]
    if rec.contribution.needs.len == 0: continue
    var declared = false
    for t in rec.contribution.reprobe:
      if t.matches(occurred):
        declared = true
        break
    if not declared: continue
    if probeInto(rec): result.add id
  if result.len > 0:
    sh.probeRevision.val = sh.probeRevision.val + 1

proc reprobeAll*(sh: SurfaceHost): seq[string] {.discardable.} =
  ## The user asked, explicitly — a "check again" action rather than a declared
  ## trigger. It ignores the declarations because the user's request IS the
  ## trigger, and a surface that declared none would otherwise have no way back
  ## from a missing dependency short of a restart, which is the thing §8.2 is
  ## about.
  if not sh.extensionsEnabled: return
  for id in sh.order:
    if sh.records[id].contribution.needs.len == 0: continue
    if probeInto(sh.records[id]): result.add id
  if result.len > 0:
    sh.probeRevision.val = sh.probeRevision.val + 1

proc degradationMemo*(sh: SurfaceHost; qualifiedId: string;
                      core: proc(): DegradedStateSnapshot): Memo[PaneDegradation] =
  ## A contributed pane's `degradedState`, with the same shape and the same
  ## resolver every built-in pane's has.
  ##
  ## IT READS `probeRevision` SO THE RE-PROBE REACHES THE PANE. That is the
  ## whole of "installing the missing component does not require restarting
  ## CodeTracer": the trigger writes a signal, the memo depends on it, and the
  ## pane re-renders. A `reprobe` that updated a table nobody observed would be
  ## a re-probe the user could not see.
  let host = sh
  let id = qualifiedId
  createMemo[PaneDegradation](proc(): PaneDegradation =
    discard isonim_signals.val(host.probeRevision)
    host.surfaceDegradation(id, core()))

# ---------------------------------------------------------------------------
# What a user is shown
# ---------------------------------------------------------------------------

func describe*(f: SurfaceFault): string =
  ## THE PLUGIN COMES FIRST, as in every other report in this subtree.
  ##
  ## A `Defect` is named as one. "faulted" and "raised a Defect" are different
  ## events with different consequences — the second is never retried — and a
  ## report that spelled them the same would leave a reader wondering why a
  ## surface with one fault stopped rendering.
  "plugin '" & f.plugin & "': surface '" & f.surface & "' " &
    (if f.defect: "raised a Defect" else: "faulted") & " (" & $f.ordinal &
    "): " & f.exceptionName & ": " & f.message

proc report*(sh: SurfaceHost): string =
  ## Everything this host has to say about its surfaces: whether extensions
  ## are on at all, then the dependency gaps, then the faults, then the
  ## plugins that were disabled. Every line names a plugin.
  var lines: seq[string] = @[]
  if not sh.extensionsEnabled:
    lines.add "extensions are disabled for this session (" &
      NoExtensionsFlag & "); no extension was loaded, probed or rendered"
    return lines.join("\n")
  for g in sh.gaps():
    lines.add describe(g)
  for f in sh.faults:
    lines.add describe(f)
  for id in sh.order:
    let rec = sh.records[id]
    if rec.disabled:
      lines.add "plugin '" & rec.plugin & "': surface '" &
        rec.contribution.id & "' is disabled for this session" &
        (if rec.defected:
           " because it raised a Defect; the rest of the plugin is unaffected"
         else: "")
  # A qualified id a second surface tried to claim. Unreachable by
  # construction — `parseManifest` refuses two rendering surfaces sharing a
  # local id (`pecDuplicateContribution`) and `resolve` refuses two manifests
  # sharing a plugin id (`pecDuplicatePlugin`), so the two segments that
  # compose the key are both unique — and REPORTED rather than trusted,
  # because the alternative is `register`'s `continue` dropping a contribution
  # in silence, which is `lpUnknownPane` in a different costume.
  for c in sh.collisions:
    lines.add c
  lines.join("\n")

proc disabledPluginList*(sh: SurfaceHost): seq[PluginId] =
  ## In registration order rather than hash order, so a report is stable.
  var seen = initHashSet[PluginId]()
  for id in sh.order:
    let rec = sh.records[id]
    if sh.isPluginDisabled(rec.plugin) and rec.plugin notin seen:
      seen.incl rec.plugin
      result.add rec.plugin
