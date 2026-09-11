## test_plugin_surfaces.nim — PLAT-9's three real-stack integration tests, plus
## the `--no-extensions` recovery route.
##
## ## WHAT THIS SUITE ASSERTS THAT THE PURE ONE CANNOT
##
## `src/common/plugin_surfaces_test.nim` asserts the DECISIONS: which view
## serves a surface, which refusal a required one produces, what a manifest is
## allowed to declare. A decision function that returns the right answer and a
## host that ignores it are indistinguishable from there.
##
## This suite asserts the EFFECT, against the real host, the real `isonim`
## graph, the real `ReplayDataStore` and the real `PATH`:
##
##   * §6.3 — the plugin's own `activations` counter is ZERO under `--ui=tui`
##     and ONE under `--ui=electron`, from one manifest. "It does not load and
##     silently do nothing" is a claim about whether the plugin's code ran, so
##     the assertion is on a counter the plugin increments itself.
##   * §8.2 — the degraded surface's view proc is never entered while its tool
##     is missing (`disassemblyRenders == 0`), the rendered node names the tool
##     AND the install action, and the sibling surface renders its real
##     content. Then a real executable appears on a real `PATH`, the declared
##     trigger fires, and the same surface renders for real.
##   * §7 — a view that throws is contained, attributed, and after the third
##     fault the host stops CALLING it (`explodeCalls` stops moving); the
##     debugger's own panes keep working across all of it.
##
## ## NO MOCKS, WITH ONE NAMED EXCEPTION AND ITS JUSTIFICATION
##
## Everything PLAT-9 owns is real here. The plugins are ordinary Nim modules
## under `plugin_fixtures/` (a declared `.ct-plugin` and `.sdk-consumer` tree,
## so `ci/test/plugin-reactive-boundary.sh` holds them to the plugin surface).
## The dependency probe is PLAT-8's `resolveExecutable`, which is `findExe`
## over this process's real environment, and the re-probe case writes a real
## executable into a real temporary directory and puts it on `PATH`. The
## reactive graph, the signals and the memos are `isonim`'s own.
##
## **The one exception is `MockBackendService`**, in the `--no-extensions`
## cases and in the "the debugger survives" case. It is this repository's
## established injected `BackendService` — `DebuggerSession` and
## `ReplayDataStore` take one by construction, and every headless ViewModel
## suite in this directory uses it. It is admitted here because the SUBJECT of
## those cases is the extension system's absence and the panes' continued
## operation, and the backend protocol is neither: substituting a real
## `replay-server` would add a child process and a built sibling to a suite
## that is about whether a plugin ran. Nothing about a plugin, a surface, a
## probe, a degradation or a fault goes through it.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`. There are two (`ck`
## and `ckHas`), and both expand inside the test body — a `check` inside a
## plain `proc` sets a module-level global and the case reports `[OK]` with the
## failed comparison printed above it.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_surfaces.nim

import std/[json, options, os, sets, strutils, tables, unittest]

import codetracer_embed
import headless_app/layout_model
import plugin_host/host

import plugin_fixtures/desktop_only_plugin
import plugin_fixtures/tool_surface_plugin
import plugin_fixtures/throwing_view_plugin

const ExpectedAssertions = 213
  ## Written from a run, and asserted against the tally below.
  ## `ci/lib/run-nim-test-lane.sh` READS this name: a file that declares
  ## it AND fails when its own tally disagrees is a file whose assertion
  ## count the lane can report, which is what keeps `OK (n tests)` from
  ## being the only evidence a suite produces.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckHas(haystack, needle: string) =
  ## `needle in haystack`, with the haystack printed on failure. A substring
  ## assertion whose failure says only `false` is one nobody can debug.
  ##
  ## BOTH ARGUMENTS ARE BOUND TO LOCALS FIRST, and that is a correctness
  ## requirement rather than tidiness. A template substitutes its arguments as
  ## EXPRESSIONS, and this one uses `haystack` twice — once in the checkpoint
  ## and once in the comparison — so `ckHas textOf(host.renderSurface(...)),
  ## x` rendered the surface two or three times. Every case that counts how
  ## often a plugin's view was entered was measuring the assertion helper.
  ## Found by `notesRenders was 3`.
  block:
    let hay = haystack
    let nee = needle
    inc countedAssertions
    checkpoint("looking for '" & nee & "' in: " & hay)
    check nee in hay

proc textOf(n: ViewNode): string =
  ## Every piece of text in a rendered tree, concatenated. The assertions
  ## below are about what a user CAN SEE, so they read the whole tree rather
  ## than one field of the root — a report moved into a child would otherwise
  ## silently stop being asserted.
  for node in walk(n):
    if node.text.len > 0: result.add node.text & "\n"
    if node.label.len > 0: result.add node.label & "\n"
    for row in node.rows:
      result.add row.join(" ") & "\n"

const TraceOpened = ActivationEvent(kind: aeTraceOpened)

# ---------------------------------------------------------------------------
# §6.3 — a required surface with no view for this front-end
# ---------------------------------------------------------------------------

suite "PLAT-9 §6.3: an Electron-only required surface under --ui=tui":

  test "the plugin fails activation, and the refusal names the front-end and the surface":
    let plugin = newDesktopOnlyPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(desktop_only_plugin.ManifestJson, "acme.flame",
                          plugin.activator())
    host.resolveAll()

    ck not host.isLoadable("acme.flame")
    ck host.failureCodeFor("acme.flame") == pecSurfaceUnavailableOnFrontEnd

    # THE EFFECT, not the report. §6.3's "What must not happen is an extension
    # that appears to load and then silently does nothing" is a claim about
    # whether the plugin's code ran, and this fixture's `activate` increments
    # a counter as its first statement.
    discard host.activateFor(TraceOpened)
    ck not host.isActive("acme.flame")
    ck plugin.activations == 0
    ck plugin.viewRenders == 0

    # And nothing of it reached the layout: no surface, so no pane.
    ck host.surfaces.surfaceIds().len == 0

    # The user is told, with both names §6.3 asks for.
    let report = host.report()
    ckHas report, "acme.flame"
    ckHas report, "flamegraph"
    ckHas report, "terminal"
    ckHas report, "--ui=tui"

  test "the SAME manifest on the desktop activates and renders its native view":
    # The control for the case above. One manifest, two front-ends, opposite
    # outcomes — so the refusal is a statement about the front-end rather than
    # about this plugin.
    let plugin = newDesktopOnlyPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feWeb)
    discard host.register(desktop_only_plugin.ManifestJson, "acme.flame",
                          plugin.activator())
    host.resolveAll()
    ck host.isLoadable("acme.flame")
    ck host.activateFor(TraceOpened) == @[PluginId("acme.flame")]
    ck plugin.activations == 1
    ck host.surfaces.surfaceIds().len == 2

    let node = host.renderSurface("acme.flame/flamegraph")
    ck node.nativeMedium == "web"
    ck node.nativeView == "flamegraph-canvas"
    ck plugin.viewRenders == 1

  test "an abstract baseline beside the native view keeps the plugin on the terminal":
    # §6.2's "honest arrangement". The difference between this manifest and
    # the refused one is a `views` array, so the refusal above is about the
    # MISSING VIEW and not about required surfaces in general.
    let plugin = newDesktopOnlyPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(desktop_only_plugin.PortableManifestJson,
                          "acme.flame-portable", plugin.activator())
    host.resolveAll()
    ck host.isLoadable("acme.flame-portable")
    discard host.activateFor(TraceOpened)
    ck plugin.activations == 1
    let rec = host.surfaces.record("acme.flame-portable/flamegraph")
    ck not rec.isNil
    ck rec.choice.kind == vcAbstract
    # ... and the same surface, on the front-end it has a native view for,
    # takes the native one. "Preferred where supplied", measured.
    let webHost = newPluginHost(semver(1, 0, 0), frontEnd = feWeb)
    discard webHost.register(desktop_only_plugin.PortableManifestJson,
                             "acme.flame-portable",
                             newDesktopOnlyPlugin().activator())
    webHost.resolveAll()
    discard webHost.activateFor(TraceOpened)
    ck webHost.surfaces.record("acme.flame-portable/flamegraph").choice.kind ==
      vcNative

  test "an OPTIONAL surface with no view is simply absent, and the plugin runs":
    const OptionalOnly = """
    {
      "id": "acme.optional", "version": "1.0.0",
      "activation": [ { "event": "trace-opened" } ],
      "contributes": {
        "pane": [
          { "id": "canvas", "requirement": "optional",
            "nativeViews": ["electron"] },
          { "id": "notes", "requirement": "optional", "views": ["Text"] }
        ]
      }
    }
    """
    var noteRenders = 0
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(OptionalOnly, "acme.optional", proc(ctx: PluginContext) =
      ctx.contributeView("notes", proc(): ViewNode =
        inc noteRenders
        viewText("acme.optional.notes", "still here")))
    host.resolveAll()
    ck host.isLoadable("acme.optional")
    discard host.activateFor(TraceOpened)
    ck host.isActive("acme.optional")
    # The absent one is not in the registry ...
    ck host.surfaces.surfaceIds() == @["acme.optional/notes"]
    # ... and it is still NAMED, so a user asking why it is missing has an
    # answer. "Simply not present" must not mean "unaccounted for".
    let absent = host.surfaces.absentSurfaces(
      host.resolution.manifests["acme.optional"])
    ck absent.len == 1
    ck absent[0].id == "canvas"
    ckHas textOf(host.renderSurface("acme.optional/notes")), "still here"
    ck noteRenders == 1

# ---------------------------------------------------------------------------
# §8.2 — a missing external tool degrades THAT surface
# ---------------------------------------------------------------------------

proc toolHost(manifest: string; id: PluginId;
              p: ToolSurfacePlugin): PluginHost =
  result = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
  discard result.register(manifest, $id, p.activator())
  result.resolveAll()
  discard result.activateFor(TraceOpened)

suite "PLAT-9 §8.2: a missing tool degrades that surface, visibly":

  test "the degraded surface names the tool and the remedy; the sibling works":
    let p = newToolSurfacePlugin()
    let host = toolHost(tool_surface_plugin.ManifestJson, "acme.disasm", p)
    ck p.activations == 1

    # §8.2's reuse: the EXISTING model, the existing resolver, the existing
    # precedence. Not a second "plugin unavailable" concept.
    ck host.surfaces.surfaceDegradation("acme.disasm/disassembly",
                                        initDegradedStateSnapshot()) ==
      pdDependencyMissing
    ck host.surfaces.surfaceDegradation("acme.disasm/notes",
                                        initDegradedStateSnapshot()) == pdNone

    # "A degraded surface is VISIBLY degraded", and it says what is missing
    # and how to get it — not "unavailable".
    let degraded = textOf(host.renderSurface("acme.disasm/disassembly"))
    ckHas degraded, "ct-plat9-probe-tool"
    ckHas degraded, "ct install ct-plat9-probe-tool"
    ckHas degraded, "acme.disasm"
    ckHas degraded, "disassembly"

    # AND THE VIEW WAS NOT CALLED. A boundary that ran the plugin's view and
    # discarded the result would produce the same text and would have let the
    # surface reach a tool that is not there.
    ck p.disassemblyRenders == 0

    # "not the whole plugin, and not the application": the sibling surface
    # renders its real content, from the same plugin, in the same session.
    ckHas textOf(host.renderSurface("acme.disasm/notes")), NotesText
    ck p.notesRenders == 1

  test "the degradation goes through resolveDegradation's own precedence":
    # The reuse is only real if a contributed pane obeys the SAME precedence
    # every built-in pane obeys. A trace that will not replay at all outranks
    # a missing helper, and telling the user to install a tool there would be
    # an instruction that does not help.
    let p = newToolSurfacePlugin()
    let host = toolHost(tool_surface_plugin.ManifestJson, "acme.disasm", p)
    var core = initDegradedStateSnapshot()
    core.availability = raUnreplayable
    ck host.surfaces.surfaceDegradation("acme.disasm/disassembly", core) ==
      pdPermanentlyUnreplayable
    # ... and the row is in the shared catalogue's precedence array exactly
    # once, between the engine row and the divergence row.
    var seen = 0
    for i, d in DegradationPrecedence:
      if d == pdDependencyMissing:
        inc seen
        ck DegradationPrecedence[i - 1] == pdEngineUnavailable
        ck DegradationPrecedence[i + 1] == pdDivergenceDetected
    ck seen == 1
    # And it is a row SOMEBODY renders — the guard `degraded_state.nim`'s
    # header describes, from this side.
    ck pdDependencyMissing in ContributedPaneDegradations

  test "installing the tool and firing the declared trigger un-degrades it":
    # §8.2: "The dependency is re-probed on a declared trigger, so installing
    # the missing component does not require restarting CodeTracer." A REAL
    # executable, in a real directory, on the real PATH.
    let p = newToolSurfacePlugin()
    let host = toolHost(tool_surface_plugin.ManifestJson, "acme.disasm", p)
    let store = createReplayDataStore(
      newMockBackendService(autoRespond = true).toBackendService())

    var degradation: Memo[PaneDegradation]
    createRoot proc(disposeRoot: proc()) =
      degradation = host.surfaces.degradationMemo("acme.disasm/disassembly",
        proc(): DegradedStateSnapshot = store.degradedSnapshot())
      ck degradation.val == pdDependencyMissing

      let dir = getTempDir() / "plat9-probe-" & $getCurrentProcessId()
      createDir(dir)
      let exe = dir / "ct-plat9-probe-tool"
      writeFile(exe, "#!/bin/sh\nexit 0\n")
      setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
      let oldPath = getEnv("PATH")
      putEnv("PATH", dir & PathSep & oldPath)
      try:
        # The probe has not been re-run yet, so the pane is still degraded:
        # a probe that consulted the PATH on every read would make the trigger
        # meaningless, and this is the assertion that says it does not.
        ck degradation.val == pdDependencyMissing

        # An event this surface did NOT declare changes nothing.
        ck host.reprobeDependencies(
          ActivationEvent(kind: aeLanguage, value: "rust")).len == 0
        ck degradation.val == pdDependencyMissing

        # The DECLARED trigger re-probes it, and the memo re-runs because the
        # probe wrote a signal it reads.
        ck host.reprobeDependencies(TraceOpened) ==
          @["acme.disasm/disassembly"]
        ck degradation.val == pdNone

        # ... and the surface now renders the plugin's own view, for real.
        let rendered = textOf(host.renderSurface("acme.disasm/disassembly"))
        ckHas rendered, "push rbp"
        ck p.disassemblyRenders == 1
      finally:
        putEnv("PATH", oldPath)
        removeDir(dir)
      disposeRoot()

  test "a surface that declared NO trigger is not re-probed by the same event":
    # The control for the case above. Without it, "the declared trigger did
    # it" and "any event re-probes everything" are the same observation.
    let p = newToolSurfacePlugin()
    let host = toolHost(tool_surface_plugin.NoReprobeManifestJson,
                        "acme.disasm-static", p)
    let dir = getTempDir() / "plat9-probe-static-" & $getCurrentProcessId()
    createDir(dir)
    let exe = dir / "ct-plat9-probe-tool"
    writeFile(exe, "#!/bin/sh\nexit 0\n")
    setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
    let oldPath = getEnv("PATH")
    putEnv("PATH", dir & PathSep & oldPath)
    try:
      ck host.reprobeDependencies(TraceOpened).len == 0
      ck host.surfaces.surfaceDegradation(
        "acme.disasm-static/disassembly", initDegradedStateSnapshot()) ==
        pdDependencyMissing
      # ... and the user's explicit "check again" DOES reach it, because the
      # user's request is the trigger. A surface with no declaration would
      # otherwise have no way back short of a restart.
      ck host.surfaces.reprobeAll() == @["acme.disasm-static/disassembly"]
      ck host.surfaces.surfaceDegradation(
        "acme.disasm-static/disassembly", initDegradedStateSnapshot()) == pdNone
    finally:
      putEnv("PATH", oldPath)
      removeDir(dir)

# ---------------------------------------------------------------------------
# §7 — a view that throws on every frame
# ---------------------------------------------------------------------------

suite "PLAT-9 §7: a view that throws is contained, attributed and disabled":

  test "the first fault is contained and attributed; the sibling surface renders":
    let p = newThrowingViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          p.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)

    let node = host.renderSurface("acme.unstable/explodes")
    ck not node.isNil
    let text = textOf(node)
    # §7: "the name, the surface and the error are the minimum."
    ckHas text, "acme.unstable"
    ckHas text, "explodes"
    ckHas text, "ThrowingViewError"
    ckHas text, ExplosionMessage
    ck p.explodeCalls == 1
    ck host.surfaces.faults.len == 1
    ck host.surfaces.faults[0].ordinal == 1

    # Contained to that surface: the sibling renders its real content.
    ckHas textOf(host.renderSurface("acme.unstable/steady")), SteadyText
    ck p.steadyCalls == 1

  test "repeated faults disable the plugin, and the host STOPS calling the view":
    let p = newThrowingViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          p.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)

    for i in 1 .. DefaultSurfaceFaultLimit:
      discard host.renderSurface("acme.unstable/explodes")
    ck p.explodeCalls == DefaultSurfaceFaultLimit
    ck host.surfaces.isPluginDisabled("acme.unstable")
    ck host.surfaces.disabledPluginList() == @[PluginId("acme.unstable")]

    # "A view that throws on every frame is worse than one that is absent."
    # Ten more frames must cost nothing: the count is what says the host
    # stopped ENTERING the view rather than merely stopped propagating.
    for i in 1 .. 10:
      discard host.renderSurface("acme.unstable/explodes")
    ck p.explodeCalls == DefaultSurfaceFaultLimit

    # The whole PLUGIN is disabled, which is what §7 says, so its healthy
    # sibling stops too — and says why rather than going blank.
    let steady = textOf(host.renderSurface("acme.unstable/steady"))
    ckHas steady, "disabled for this session"
    ckHas steady, "acme.unstable"
    ck p.steadyCalls == 0

    let report = host.report()
    ckHas report, "acme.unstable"
    ckHas report, "faulted"

  test "the debugger survives it — a real store and real panes keep working":
    # §7's headline: "A failing extension must not take down the debugger."
    # The panes below are the product's own ViewModels over the product's own
    # store, driven across the faults.
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    createRoot proc(disposeRoot: proc()) =
      let editor = createEditorVM(store)
      let controls = createDebugControlsVM(store)
      let p = newThrowingViewPlugin()
      let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
      discard host.register(throwing_view_plugin.ManifestJson,
                            "acme.unstable", p.activator())
      host.resolveAll()
      discard host.activateFor(TraceOpened)

      ck editor.degradedState.val == pdNone
      for i in 1 .. 6:
        discard host.renderSurface("acme.unstable/explodes")
      ck p.explodeCalls == DefaultSurfaceFaultLimit

      # The store still propagates, and the panes still resolve — after six
      # faults, with the plugin disabled.
      store.setTraceIntegrity(tiTruncated)
      ck controls.degradedState.val == pdTraceTruncated
      ck editor.degradedState.val == pdNone
      store.setReplayAvailability(raUnreplayable)
      ck editor.degradedState.val == pdPermanentlyUnreplayable
      editor.dispose()
      controls.dispose()
      disposeRoot()
    store.dispose()

  test "a view raising IndexDefect is contained, disabled, and the debugger survives":
    # THE FAULT CLASS THE BOUNDARY USED TO MISS. `renderSurface` caught
    # `CatchableError`; `IndexDefect` is not one, so an ordinary out-of-range
    # read in a plugin view went past the boundary, past the host and out of
    # whatever was drawing the frame. §7's "a failing extension must not take
    # down the debugger" did not hold for the commonest Nim runtime failure.
    #
    # Before the repair THIS CASE DID NOT FAIL — it terminated the suite on its
    # first `renderSurface`, which is why the assertion that matters most is
    # the one that comes after ten more frames.
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let p = newDefectViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(throwing_view_plugin.DefectViewManifestJson,
                          "acme.defect", p.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    ck p.activations == 1

    createRoot proc(disposeRoot: proc()) =
      let editor = createEditorVM(store)
      let controls = createDebugControlsVM(store)
      ck editor.degradedState.val == pdNone

      # 1. CONTAINED. A node comes back rather than an exception going out.
      let first = host.renderSurface("acme.defect/outofrange")
      ck not first.isNil
      # 2. ATTRIBUTED — §7's stated minimum, plus the fault's class, because
      #    "it will not be retried" is only readable if the report says why.
      let text = textOf(first)
      ckHas text, "acme.defect"
      ckHas text, "outofrange"
      ckHas text, "IndexDefect"
      ckHas text, "Defect"
      ck host.surfaces.faults.len == 1
      ck host.surfaces.faults[0].defect
      ck host.surfaces.faults[0].ordinal == 1
      ck p.calls == 1

      # 3. NEVER RE-ARMED, which is where the two fault classes part company.
      #    A `CatchableError` gets `DefaultSurfaceFaultLimit` frames because it
      #    may be a transient; a broken invariant is not one. Ten more frames
      #    must cost nothing, and the COUNTER is what says the host stopped
      #    entering the view rather than merely stopped propagating.
      for i in 1 .. 10:
        discard host.renderSurface("acme.defect/outofrange")
      ck p.calls == 1
      ck host.surfaces.isSurfaceDisabled("acme.defect/outofrange")
      ckHas textOf(host.renderSurface("acme.defect/outofrange")),
        "disabled for this session"

      # 4. CONTAINED TO THE SURFACE, not to the plugin. The positive twin:
      #    the sibling of a defected surface still renders its real content,
      #    which is what makes "the surface is disabled" a narrower claim than
      #    the `CatchableError` path's plugin-wide disable rather than the
      #    same claim differently spelled.
      ck not host.surfaces.isPluginDisabled("acme.defect")
      ckHas textOf(host.renderSurface("acme.defect/steady")), DefectSteadyText
      ck p.steadyCalls == 1

      # 5. THE DEBUGGER SURVIVES — the product's own store and panes, driven
      #    across the faults, which is §7's headline at the effect level.
      store.setTraceIntegrity(tiTruncated)
      ck controls.degradedState.val == pdTraceTruncated
      ck editor.degradedState.val == pdNone
      store.setReplayAvailability(raUnreplayable)
      ck editor.degradedState.val == pdPermanentlyUnreplayable

      # 6. And the report names it as a Defect, so a user is not left asking
      #    why a surface with one fault stopped.
      let report = host.report()
      ckHas report, "raised a Defect"
      ckHas report, "outofrange"
      ckHas report, "the rest of the plugin is unaffected"
      editor.dispose()
      controls.dispose()
      disposeRoot()
    store.dispose()

  test "a view that returns nil is a fault too, not a blank region":
    let p = newNilViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(throwing_view_plugin.NilViewManifestJson,
                          "acme.nilview", p.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    let node = host.renderSurface("acme.nilview/empty")
    ck not node.isNil
    ckHas textOf(node), "acme.nilview"
    ck host.surfaces.faults.len == 1
    ck p.calls == 1

  test "a plugin whose activate() raises is contained, and its neighbour still loads":
    # §7 applied to the plugin's FIRST line: there is no surface yet, so the
    # host is the only thing that can contain it.
    let neighbour = newThrowingViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(throwing_view_plugin.RaisingActivateManifestJson,
                          "acme.badboot", raisingActivator())
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          neighbour.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    ck not host.isActive("acme.badboot")
    ck host.activationFaults.len == 1
    ckHas host.activationFaults[0], "acme.badboot"
    ckHas host.activationFaults[0], "ThrowingViewError"
    # The neighbour in the same registry, activated by the same event, is up.
    ck host.isActive("acme.unstable")
    ck neighbour.activations == 1

  test "a plugin contributing a view for a surface it never declared is refused":
    # §4.1's rule in the mirror direction. The refusal arrives as an
    # activation fault, so the plugin is not half-registered.
    const OneSurface = """
    {
      "id": "acme.typo", "version": "1.0.0",
      "activation": [ { "event": "trace-opened" } ],
      "contributes": { "pane": [ { "id": "notes", "views": ["Text"] } ] }
    }
    """
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(OneSurface, "acme.typo", proc(ctx: PluginContext) =
      ctx.contributeView("note", proc(): ViewNode =
        viewText("x", "y")))
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    ck not host.isActive("acme.typo")
    ck host.activationFaults.len == 1
    ckHas host.activationFaults[0], "note"
    ckHas host.activationFaults[0], "notes"

  test "a plugin whose activate() raises a Defect is contained and not retried":
    # The same repair one layer up. `activateOne`'s containment caught
    # `CatchableError` only, so a plugin whose FIRST line read past the end of
    # a sequence took the application down before any view existed to mount
    # inside a boundary — §7 applied to the plugin's first line, and missing
    # exactly the class that matters most.
    const BadBootDefect = """
    {
      "id": "acme.defectboot", "version": "1.0.0",
      "activation": [ { "event": "trace-opened" } ],
      "contributes": { "pane": [ { "id": "never", "views": ["Text"] } ] }
    }
    """
    var entered = 0
    let neighbour = newThrowingViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal)
    discard host.register(BadBootDefect, "acme.defectboot",
                          proc(ctx: PluginContext) =
      inc entered
      var rows: seq[int] = @[]
      discard rows[entered + 1])
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          neighbour.activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    ck entered == 1
    ck not host.isActive("acme.defectboot")
    ck host.activationFaults.len == 1
    ckHas host.activationFaults[0], "acme.defectboot"
    ckHas host.activationFaults[0], "IndexDefect"
    ckHas host.activationFaults[0], "will not be activated again"
    # NOT RETRIED. `activateFor` walks the plan on every declared event, so a
    # plugin left merely inactive is re-entered on the next one — which for a
    # broken invariant is a second run over state the language has just said
    # does not hold. The counter is what says it was not.
    discard host.activateFor(TraceOpened)
    ck entered == 1
    ck host.activationFaults.len == 1
    # The neighbour in the same registry, activated by the same event, is up —
    # the containment is to the plugin, not to the host.
    ck host.isActive("acme.unstable")
    ck neighbour.activations == 1

# ---------------------------------------------------------------------------
# §6.1 — the contributed pane identity, in a real layout
# ---------------------------------------------------------------------------

suite "PLAT-9 §6.1: a contributed pane in a persisted layout":

  test "the two namespaces are disjoint by construction, over the whole enum":
    # The compile-time guard in `layout_model.nim` asserts this at build time;
    # this is the same claim at run time, so a reader of the suite can see
    # which property is being relied on.
    for k in PaneKind:
      ck not isContributedPaneId($k)
      ck PaneIdSeparator notin $k

  test "a hostile id spelled like a built-in pane cannot become one":
    # The id below is attacker-controlled text from a third-party manifest.
    # It is refused by the command algebra ...
    let layout = defaultReplayLayoutValue()
    let refused = apply(layout, cmdAddContributedPane("editor"))
    ck refused.kind == loRefused
    ck refused.problem.kind == lpMalformedContributedPane
    # ... and a WELL-FORMED id that ends in the same word is a different pane
    # from the built-in one, in a separate JSON key, through a full round trip.
    let added = apply(layout, cmdAddContributedPane("hostile.ext/editor",
                                                    "Editor"))
    ck added.kind == loApplied
    let doc = saveLayout(added.layout)
    ckHas $doc, "contributedPane"
    let back = restoreLayoutDocument(doc)
    ck back.tree.allPanes().len == added.layout.tree.allPanes().len
    ck back.tree.containsContributed("hostile.ext/editor")
    # The built-in editor is still placed exactly once, and is still the
    # built-in one.
    var editors = 0
    for p in back.tree.allPanes():
      if p == paneEditor: inc editors
    ck editors == 1
    ck back.isValid(owned = ReplayCorePanes)

  test "a malformed contributed pane in a document is refused, with its kind":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "row", "children": [
        {"kind": "pane", "pane": "editor"},
        {"kind": "pane", "contributedPane": "not namespaced"}]},
      "docked": []}
    var kind = ldeNotAnObject
    try:
      discard restoreLayoutDocument(doc)
      ck false
    except LayoutDecodeError as e:
      kind = e.kind
    ck kind == ldeBadContributedPane

  test "a leaf claiming BOTH namespaces is refused":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "row", "children": [
        {"kind": "pane", "pane": "editor"},
        {"kind": "pane", "pane": "state",
         "contributedPane": "acme.ext/metrics"}]},
      "docked": []}
    var kind = ldeNotAnObject
    try:
      discard restoreLayoutDocument(doc)
      ck false
    except LayoutDecodeError as e:
      kind = e.kind
    ck kind == ldePaneAndContributedPane

  test "a well-formed id from an unloaded extension is a TYPED slot, not a blank one":
    # §6.1's whole requirement. The pane is decodable, the slot survives the
    # round trip, and the report names the EXTENSION — which is the thing a
    # user installs.
    let placed = apply(defaultReplayLayoutValue(),
                       cmdAddContributedPane("acme.disasm/disassembly",
                                             "Disassembly"))
    ck placed.kind == loApplied
    let back = restoreLayoutDocument(saveLayout(placed.layout))
    let leaf = back.tree.findContributed("acme.disasm/disassembly")
    ck not leaf.isNil
    ck leaf.isContributed
    ck leaf.title == "Disassembly"

    var loaded = initHashSet[string]()
    let unloaded = leaf.paneRefOf().classify(loaded)
    ck unloaded.kind == prUnloadedExtension
    ckHas describe(unloaded), "acme.disasm"
    ckHas describe(unloaded), "disassembly"
    ckHas describe(unloaded), "not loaded"

    # And the control: with the extension loaded, the SAME slot resolves to an
    # ordinary contributed pane.
    loaded.incl "acme.disasm/disassembly"
    ck leaf.paneRefOf().classify(loaded).kind == prContributed

  test "a contributed leaf is invisible to the PaneKind-typed algebra":
    # `pane` on a contributed leaf holds the enum's zero value. A walker that
    # read it would report `paneEditor` for somebody else's pane, and
    # `lcRemovePane(editor)` would delete it.
    let one = apply(initLayout(pane(paneState)),
                    cmdAddContributedPane("acme.ext/metrics"))
    ck one.kind == loApplied
    let tree = one.layout.tree
    ck tree.allPanes() == @[paneState]
    ck tree.allContributedPanes() == @["acme.ext/metrics"]
    ck not tree.contains(paneEditor)
    ck tree.find(paneEditor).isNil
    ck paneCount(tree) == 2
    # Removing the built-in pane leaves the contributed one, and the layout is
    # still a layout — §2.4 rule 3 counts leaves, not enum values.
    let removed = apply(one.layout, cmdRemovePane(paneState))
    ck removed.kind == loApplied
    ck removed.layout.tree.allContributedPanes() == @["acme.ext/metrics"]
    # And the contributed pane can be removed by its own verb, but not as the
    # last pane in the layout.
    ck apply(removed.layout,
             cmdRemoveContributedPane("acme.ext/metrics")).kind == loRefused
    ck apply(one.layout,
             cmdRemoveContributedPane("acme.ext/metrics")).kind == loApplied

  test "the same contributed pane twice is a duplicate, in its own namespace":
    let one = apply(initLayout(pane(paneState)),
                    cmdAddContributedPane("acme.ext/metrics"))
    ck one.kind == loApplied
    let twice = apply(one.layout, cmdAddContributedPane("acme.ext/metrics"))
    ck twice.kind == loRefused
    ck twice.problem.kind == lpDuplicatePane
    ck twice.problem.contributed == "acme.ext/metrics"
    ck twice.problem.pane.isNone
    # A DIFFERENT contributed pane is not a duplicate — the check is on the
    # id, and two contributed leaves share the `pane` field's zero value.
    ck apply(one.layout, cmdAddContributedPane("acme.ext/other")).kind ==
      loApplied

# ---------------------------------------------------------------------------
# §7's last bullet — `--no-extensions`
# ---------------------------------------------------------------------------

suite "PLAT-9 §7: --no-extensions produces a working debugger":

  test "no plugin code runs, nothing is registered, and the report names the flag":
    let flame = newDesktopOnlyPlugin()
    let tool = newToolSurfacePlugin()
    let unstable = newThrowingViewPlugin()
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feWeb,
                             extensionsEnabled = false)
    discard host.register(desktop_only_plugin.ManifestJson, "acme.flame",
                          flame.activator())
    discard host.register(tool_surface_plugin.ManifestJson, "acme.disasm",
                          tool.activator())
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          unstable.activator())
    host.resolveAll()
    discard host.activateEager()
    discard host.activateFor(TraceOpened)

    # 1. No plugin's `activate` was entered. Three fixtures, three counters.
    ck flame.activations == 0
    ck tool.activations == 0
    ck unstable.activations == 0
    # 2. No surface exists, so nothing can enter a layout.
    ck host.surfaces.surfaceIds().len == 0
    # 3. No dependency was probed — no PATH lookup on an extension's behalf.
    ck host.surfaces.gaps().len == 0
    # 4. Rendering refuses BEFORE any plugin code, and says why.
    let node = textOf(host.renderSurface("acme.disasm/notes"))
    ckHas node, "--no-extensions"
    ck tool.notesRenders == 0
    ck unstable.explodeCalls == 0
    # 5. The user is told, first, and the flag is named.
    let report = host.report()
    ckHas report, "--no-extensions"
    ckHas report, "3 manifest(s)"

  test "the debugger's own panes work with extensions off":
    # "A single flag must produce a working debugger, and that path is tested,
    # because it is the recovery route when an extension makes the product
    # unusable." The panes below are the product's own.
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal,
                             extensionsEnabled = false)
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          newThrowingViewPlugin().activator())
    host.resolveAll()
    discard host.activateFor(TraceOpened)
    createRoot proc(disposeRoot: proc()) =
      let editor = createEditorVM(store)
      let calltrace = createCalltraceVM(store)
      let state = createStateVM(store)
      let eventLog = createEventLogVM(store)
      let controls = createDebugControlsVM(store)
      ck editor.degradedState.val == pdNone
      ck calltrace.degradedState.val == pdNone
      ck state.degradedState.val == pdNone
      ck eventLog.degradedState.val == pdNone
      ck controls.degradedState.val == pdNone
      store.setTraceIntegrity(tiTruncated)
      ck controls.degradedState.val == pdTraceTruncated
      ck calltrace.degradedState.val == pdTraceTruncated
      ck editor.degradedState.val == pdNone
      editor.dispose()
      calltrace.dispose()
      state.dispose()
      eventLog.dispose()
      controls.dispose()
      disposeRoot()
    store.dispose()

  test "a layout written WITH extensions restores under --no-extensions, with every core pane":
    # The recovery route, end to end. A user whose extension made the product
    # unusable restarts with the flag; the layout they saved still holds the
    # extension's pane, every built-in pane is still placed, and the
    # extension's slot is a typed report rather than a blank region.
    let withExt = apply(defaultReplayLayoutValue(),
                        cmdAddContributedPane("acme.unstable/explodes",
                                              "Explodes"))
    ck withExt.kind == loApplied
    let saved = saveLayout(withExt.layout)

    let host = newPluginHost(semver(1, 0, 0), frontEnd = feTerminal,
                             extensionsEnabled = false)
    discard host.register(throwing_view_plugin.ManifestJson, "acme.unstable",
                          newThrowingViewPlugin().activator())
    host.resolveAll()

    let restored = restoreLayoutDocument(saved)
    # Every core pane is still there and the layout is still valid.
    ck restored.isValid(owned = ReplayCorePanes)
    for p in ReplayCorePanes:
      ck restored.tree.contains(p)
    # The extension's slot survived, and resolves to the typed value.
    var loaded = initHashSet[string]()
    for id in host.surfaces.contributedPaneIds(): loaded.incl id
    ck loaded.len == 0
    let leaf = restored.tree.findContributed("acme.unstable/explodes")
    ck not leaf.isNil
    ck leaf.paneRefOf().classify(loaded).kind == prUnloadedExtension
    # And what a front-end would draw there says which extension is missing.
    ckHas describe(leaf.paneRefOf().classify(loaded)), "acme.unstable"

# ---------------------------------------------------------------------------
# The counted-assertion tally (Verification-Harness-Traps §4c)
# ---------------------------------------------------------------------------

suite "PLAT-9: the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
