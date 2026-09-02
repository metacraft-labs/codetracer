## Build and Run, in a browser tab — the call path that did not exist.
##
## ## What was actually missing
##
## Everything either side of this file worked and was tested. The deployment
## serves ~19 MB of Noir wasm; `wasm_worker_browser.js` drives both modules'
## C ABIs; `platform/wasm_worker.nim` speaks the protocol; NS9 merged the
## bundles so the renderer's own `ctPlatform()` is the platform `boot()`
## installed, and `capProcessSpawn` is granted exactly when the wasm registry
## is non-empty. And **nothing called any of it**: instrumenting
## `Worker.postMessage` before page scripts ran and then exercising Run test,
## the BUILD pane's ▶ and ■, a test row, F5, Ctrl+B, Ctrl+Shift+B and Ctrl+R
## produced one `configure` message, zero `start` messages, and zero `.wasm`
## network requests. The compilers had never been fetched by the product.
##
## This module is the caller. It is deliberately thin: the marshalling is
## `platform/noir_build.nim` and the pane-driving is
## `viewmodels/noir_build_producer.nim`, both pure and both exercised on the C
## backend by `vm-unit` and on the renderer's own backend by `vm-unit-js`. What
## is left here is the part that genuinely needs a browser — reaching
## `ctPlatform()`, opening a pane, and holding a `ProcessHandle` between two
## user gestures.
##
## ## Why BUILD compiles in `program` mode and RUN compiles in `debug`
##
## They are different questions and the compiler answers them differently.
##
## `nargo compile` means "produce the circuit", and warnings are part of that
## answer. `nargo trace` needs an instrumented, `force_brillig` artifact —
## `vfs.rs::context_for` records the measurement that an uninstrumented one
## traces to **one event and no steps** while both modules report `ok`.
##
## The two modes are NOT interchangeable in the other direction either:
## `debugging_compile_options()` sets `silence_warnings: true` (nargo's own
## choice, because the instrumenter imports `__debug` functions the user did
## not write), so a Build that asked for `debug` would drop every warning
## silently. Measured over one program carrying both an unused expression and
## an unresolved path: `program` reports 2 diagnostics, `debug` reports 1.
##
## So Run compiles a SECOND time rather than reusing Build's artifact. That is
## not waste — it is a different program — and it costs ~0.4 s on the bundled
## template against a ~2.5 s first-fetch of the compiler.
##
## ## Why the BUILD pane is opened rather than added to the layout
##
## `src/config/default_layout.json` has no Build pane, and adding one would put
## an empty panel on every first screen for a feature most sessions never use.
## `build.focusBuild` already does the right thing on the desktop —
## `data.openLayoutTab(Content.Build)`, which CREATES the container when the
## layout has none — and `onBuildCode` uses the same call to open the Problems
## panel when a build fails. This takes that path, so the pane appears for the
## same reason and by the same mechanism on both platforms.
##
## THE TOPBAR IS DELIBERATELY UNTOUCHED. `ui/menu_render_gate.menuRenderSignature`
## must be injective over everything the shell reads, and a new state-dependent
## topbar element that is not added to the signature silently never re-renders.
## Nothing here is in the menu model, so the signature is complete for the same
## reason it was before.

import
  std/[ strutils ],
  ui_imports

# `$` only, and `#` rather than `##` for the reason `platform_host.nim`'s own
# header records: a `##` block after an import is `Error: invalid indentation`,
# which is the exact defect that reached `dev` at ed9d6021 and sat there.
#
# A bare `import std/json` into a module that already has `ui_imports` brings
# `%` and `parseJson` into a namespace that has its own. This module needs
# exactly one thing from `json`: rendering a composed request as the text the
# worker's `stdin` carries. The shapes themselves are
# `platform/noir_build.nim`'s job.
from std/json import JsonNode, `$`

# `Signal.val` is a template on `isonim/core/signals`, and reading one from
# here needs the module in scope even though the `BuildVM` type comes from
# `build_vm`. Imported explicitly rather than relied on through a transitive
# export, so a future narrowing of `build_vm`'s imports cannot silently break
# `paneRowCounts`.
import isonim/core/signals

import ../platform_host
import ../viewmodel/platform/noir_template
# THE ONE MUTABLE PROJECT. `currentProject()` is what a save mutates, and
# reading it here rather than a module-local copy is the whole of this file's
# half of the edits-are-discarded defect. `templateProjectRoot` comes with it
# so the project's root has one spelling in the tree instead of four.
import ./web_project_store
import ../viewmodel/platform/noir_build
import ../viewmodel/viewmodels/noir_build_producer
from ../viewmodel/viewmodels/build_vm import BuildVM
import ./build as build_pane
# The PROBLEMS pane's mirror of the same diagnostics. `from ... import` to keep
# this module's import surface narrow — it needs three procs, not the module.
from ./errors import
  syncErrorsAppendProblem, syncErrorsClear, highlightFirstBuildError
from ../viewmodel/store/types import BuildProblemLine

export noir_build_producer

type
  NoirRunIntent* = enum
    ## Which gesture started this. One producer and one handle serve both, so
    ## the difference has to be a value: a Build stops after the compile, a
    ## Run continues into the tracer with the artifact the compile produced.
    nriBuild
    nriRun
    nriTest
      ## `nargo test`. One phase, not two: the module compiles each test
      ## function and executes it inside one `nv_test_vfs` call, so there is
      ## nothing for this module to chain.

var
  noirTestRunSink*: proc(response: NoirTestResponse; packageDir: string)
    ## Where a finished test run's verdicts go, besides the build pane.
    ##
    ## A CALLBACK and not a direct call into `ui/test_results`, for
    ## `noir_build_producer.onProblem`'s reason one layer up: this module talks
    ## to the wasm toolchain, and the Test Results pane is a second surface
    ## over the same run. `ui_js` installs it, which is the one place that can
    ## see the pane, the catalog and this module at once.
    ##
    ## Nil is a real state and not a defect: a build with no Test Results pane
    ## mounted still runs the tests and still paints them into the build pane.

  noirTestRunStarted*: proc()
    ## Told at DISPATCH, before the worker has answered. The pane needs it to
    ## clear the previous run and disable its ▶; see
    ## `test_results_vm.inFlight` for why the event stream cannot supply this.

  noirTestRunSettled*: proc()
    ## Told when the run settles, however it settled — including a refusal that
    ## never reached the worker. Paired with `noirTestRunStarted`, because a
    ## pane left `inFlight` would disable its own button permanently.

var
  activeProducer: NoirBuildProducer
  activeHandle: ProcessHandle
  activeIntent: NoirRunIntent
  activeInFlight = false
  lastStartCount = 0
    ## How many `start` messages this module has caused the worker to be sent.
    ##
    ## Counted because "the compiler is now reachable" is exactly the claim a
    ## chain of green checks cannot support: the state this replaces produced
    ## ZERO `start` messages while every check passed. It rides on every
    ## `codetracer-noir-build:` line, so a log records how many dispatches a
    ## session made — beside `ci/test/noir-build-in-browser.sh`'s independent
    ## count, taken by wrapping `Worker.postMessage` before any page script
    ## runs. Two instruments, one fact; the gate reads the second, and this one
    ## is what a support question is answered from.

proc jsNowMs(): float {.importjs: "Date.now()".}

proc reportBuildDiagnostic(line: cstring) {.importjs: """
(function (s) {
  try { if (typeof console !== 'undefined') { console.log(s); } } catch (e) {}
})(#)""".}
  ## One line per phase transition, on the console.
  ##
  ## Not a substitute for the pane — the pane is the product — but the pane is
  ## a DOM assertion away and a phase that never started is not. The browser
  ## gate reads these to tell "the compile was dispatched and refused" from
  ## "the compile was never dispatched", which are the two states this whole
  ## change exists to separate and which look identical in an empty panel.

const noirBuildLinePrefix* = "codetracer-noir-build:"

proc paneRowCounts(): string =
  ## How many rows the PRODUCER's view model holds, and how many the pane's
  ## does.
  ##
  ## Two numbers rather than one, because they are two different objects and a
  ## disagreement between them is a specific, silent defect:
  ## `initBuildVMWithStore` REPLACES `build.buildVMInstance` when the shared
  ## store arrives, and a producer captured before that would write rows into a
  ## view model no mounted view is bound to — a build that ran, succeeded, and
  ## painted nothing. `producerFor` rebuilds the producer to prevent it; this
  ## is how a run says whether the prevention held.
  if activeProducer.isNil: return " rows=(no-producer)"
  let mine = activeProducer.vm.output.val.len
  let pane =
    if build_pane.buildVMInstance.isNil: -1
    else: build_pane.buildVMInstance.output.val.len
  " rows=" & $mine & " paneRows=" & $pane

proc report(phase, detail: string) =
  reportBuildDiagnostic(cstring(
    noirBuildLinePrefix & " " & phase & " starts=" & $lastStartCount &
    (if detail.len > 0: " " & detail else: "") & paneRowCounts()))

# ---------------------------------------------------------------------------
# The VFS, marshalled
# ---------------------------------------------------------------------------

proc templateVfsEntries*(tmpl: ProjectTemplate): seq[NoirSourceEntry] =
  ## The open project as the compiler's virtual filesystem.
  ##
  ## ## THE DEFECT THIS PROC WAS THE FAR END OF
  ##
  ## It still reads `tmpl.files`, and that is correct — what changed is WHICH
  ## value its callers hand it. `startNoirBuild` and `startNoirRun` used to
  ## pass `buildTemplate`, a module-level copy taken once at
  ## `installNoirBuildCommands` time from the compile-time bundled template.
  ## Nothing mutated it, and nothing could: `ProjectTemplate` is an `object`,
  ## so the assignment was a copy.
  ##
  ## The result was that Build and Run compiled the BUNDLED template no matter
  ## what the visitor had typed. Editing `main.nr` into something that cannot
  ## compile and pressing Ctrl+B produced a clean, green, successful build — of
  ## code the user had not written. They now pass
  ## `web_project_store.currentProject()`, which the save host mutates.
  ##
  ## THE CONVERTER THAT DID NOT EXIST. `nv_compile_vfs` wants
  ## `{files:{path:content}, package_dir, mode}`; the web project store holds
  ## `TemplateFile(path, content)` keyed project-relative, and nothing turned
  ## one into the other — `package_dir` appeared in exactly one place in the
  ## whole tree before this, and it was a JavaScript literal in a CI script.
  ##
  ## The package directory is a PREFIX of every key rather than a root they
  ## hang off: `resolve_vfs(&tree, "hello_noir")` looks up the literal key
  ## `hello_noir/Nargo.toml`. `noirVfsPath` is the one place that knows it.
  ##
  ## `Prover.toml` is included even though the compiler ignores it. Filtering
  ## it out would mean this proc had a list of which files matter, which is a
  ## second statement of what a Noir package is — and a wrong one the day a
  ## project carries a `.toml` the toolchain does read.
  for file in tmpl.files:
    result.add NoirSourceEntry(
      path: noirVfsPath(tmpl.name, file.path),
      content: file.content)

proc templateInputs*(tmpl: ProjectTemplate): string =
  ## The project's `Prover.toml`, or the empty string.
  ##
  ## `fileContent` answers "" for a file the template does not carry, and that
  ## is the case `traceInputsMissing` reports by name. A default is NOT
  ## invented here — see that proc for why zeroes would be worse than a
  ## refusal.
  fileContent(tmpl, noirInputsFile)

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc ensureBuildPaneVisible() =
  ## Open the BUILD pane and make sure the IsoNim view is mounted into it.
  ##
  ## BOTH CALLS ARE NEEDED, and the second is the one that was missing — this
  ## is measured rather than defensive.
  ##
  ## `ui/layout.nim` registers BUILD as a **standalone auto-hide panel**: it is
  ## not in `default_layout.json` at all, its DOM lives in
  ## `#auto-hide-standalone-host` (parked at `left: -9999px`), and it appears
  ## to a user as a label in the status-bar strip. `openLayoutTab` has an
  ## auto-hide branch for exactly this, but it routes through
  ## `findPanelToRevealOnOpen`, which keys on a *document* path and answers nil
  ## for a standalone singleton with none — measured, with the pane still at
  ## x = -9999 after a compile that had already painted its result into it.
  ##
  ## `autoRevealBuildPanel` is the pane's own accessor for the same question
  ## (`findPanelByContent` + `revealOverlay`) and is what the desktop's
  ## `onBuildCommand` calls beside `focusBuild`. Calling both here is not
  ## belt-and-braces: `openLayoutTab` is what shows the pane on a layout that
  ## DOES carry it as a tab, and `autoRevealBuildPanel` is what shows it on one
  ## that carries it as a strip label. A browser gets the second; a user who
  ## has dragged BUILD into the layout gets the first.
  ##
  ## `tryMountIsoNimBuildPanel` is called again rather than relied upon from
  ## start-up: it retries for ~2 s after `initBuildVMWithStore` and then gives
  ## up, which is long expired by the time a user clicks anything. It is
  ## idempotent (`isoNimBuildMounted` guards it), so calling it here costs
  ## nothing when the pane was already mounted and is the difference between a
  ## painted result and an empty container when it was not.
  if not data.isNil and not data.ui.layout.isNil:
    data.openLayoutTab(Content.Build)
  build_pane.autoRevealBuildPanel()
  build_pane.tryMountIsoNimBuildPanel()

proc producerFor(tmpl: ProjectTemplate): NoirBuildProducer =
  ## One producer per pane, rebuilt if the VM was replaced underneath it.
  ##
  ## `initBuildVMWithStore` replaces `buildVMInstance` when the shared store
  ## arrives, so a producer captured earlier would be writing into a VM no
  ## view is bound to — a build that ran, succeeded, and painted nothing.
  if build_pane.buildVMInstance.isNil:
    return nil
  if activeProducer.isNil or activeProducer.vm != build_pane.buildVMInstance:
    activeProducer = newNoirBuildProducer(
      build_pane.buildVMInstance,
      projectRoot = templateProjectRoot(tmpl),
      packageDir = tmpl.name)
    # FEED THE PROBLEMS PANE TOO. Without these two the browser arm painted
    # diagnostics in the BUILD pane and left PROBLEMS empty, so error
    # navigation — which ranges over the PROBLEMS list — would have had
    # nothing to range over, and would have looked like a broken shortcut
    # rather than a missing producer.
    activeProducer.onProblem = proc(problem: BuildProblemLine) =
      syncErrorsAppendProblem(problem)
    activeProducer.onProblemsCleared = proc() =
      syncErrorsClear()
  activeProducer

proc startTrace(producer: NoirBuildProducer; tmpl: ProjectTemplate)

proc onPhaseExit(producer: NoirBuildProducer; tmpl: ProjectTemplate;
                 exit: ProcessExit) =
  ## The worker's `exit`, and the one place the two phases are chained.
  let phase = producer.phase
  let verdict = producer.onExit(exit)
  activeInFlight = false
  report($phase & "-exit", "verdict=" & $verdict & " code=" & $exit.exitCode)
  if phase == nbpCompile and verdict == npvSucceeded and
     activeIntent == nriRun:
    startTrace(producer, tmpl)
    return

  if phase == nbpTest:
    # THE VERDICTS, HANDED ON WHILE THEY EXIST — the same rule the trace arm
    # states in `noir_build_producer.onExit`. `beginPhase` clears `lastTests`,
    # so a pane that asked for them after the next run would read an empty
    # response and paint a suite of nothing.
    if not noirTestRunSink.isNil:
      noirTestRunSink(producer.lastTests, tmpl.name)
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()
    report("test-results",
           "ok=" & $producer.lastTests.ok &
           " passed=" & $producer.lastTests.passed &
           " failed=" & $producer.lastTests.failed &
           " skipped=" & $producer.lastTests.skipped &
           " tests=" & $producer.lastTests.tests.len)

  # REVEALED AGAIN WHEN THE RESULT LANDS, and this is not belt-and-braces.
  #
  # A first compile takes seconds — the compiler is 16 MB and has to be fetched
  # and instantiated before the project is touched — and the auto-hide overlay
  # is DISMISSIBLE by design: `Planned-Features/Auto-Hide-Panes.md` §3.3 lists
  # a pointer leaving it, a backdrop click and Escape, and late layout work
  # rebuilds the strip through `autoHideState.onChanged`. Any of those between
  # the gesture and the answer leaves a user looking at the editor while the
  # result they asked for is painted into a pane parked at `left: -9999px`.
  # Measured exactly that way: `starts=1`, `verdict=npvSucceeded`, one row of
  # output, and the row's rect at x = -9999.
  #
  # The desktop does the same thing for the same reason and from the same
  # place: `build.processBuildOutput` calls `focusBuild()` on the first line of
  # output, and `onBuildCode` calls `autoRevealBuildPanel()` again when the
  # exit code is non-zero. This is one pane with two producers, so it gets one
  # behaviour.
  ensureBuildPaneVisible()

  # AND, ON A REFUSAL, SELECT THE FIRST ERROR WITHOUT FOCUSING IT (EMT-D21).
  #
  # `npvRefused` and not `npvFaulted`: a refusal means the toolchain answered
  # and the user has something to fix, so there are diagnostics to select. A
  # fault means the toolchain did not answer, in which case there is nothing
  # about the user's program to navigate to and selecting a row would be
  # inventing one.
  if verdict == npvRefused:
    highlightFirstBuildError()

proc dispatch(producer: NoirBuildProducer; tmpl: ProjectTemplate;
              phase: NoirBuildPhase; args: seq[string]; stdin: string;
              label: string) =
  ## Post one `start` to the worker, through the platform facade.
  ##
  ## `ctPlatform().process.start` and not `run`, because a Run has to be
  ## stoppable: `start` yields a `ProcessHandle` and `run` does not, and the ■
  ## in the pane needs one to pass to `signal`.
  ##
  ## `ctAwaitSync` is correct here and is not the bridge's usual compromise:
  ## every branch of `web_platform.buildProcess.start` settles synchronously —
  ## a registry refusal is `resolved(...)` and `wasm_worker.startOnWorker`
  ## returns `resolvedOk(handle)` before the worker has done anything. The
  ## LATENCY is in the callbacks, which are not a future. If a remote
  ## instantiation ever supplies this facade, `ctAwaitSync` reports
  ## `pkTimeout` naming this call site rather than silently reading a default,
  ## which is the property it exists for.
  let platform = ctPlatform()
  # State first, then reveal — the order `build.onBuildCommand` uses on the
  # desktop, and for its reason: `beginPhase` sets `running` and clears, and a
  # pane revealed before it would flash the previous build's rows.
  producer.beginPhase(phase, label, jsNowMs())
  ensureBuildPaneVisible()

  if not platform.can(capProcessSpawn):
    # The registry is empty, so `newWebPlatform` subtracted the capability and
    # attached `webNoModulesLoaded` as its degradation. That sentence names
    # the deployment rather than the command, which is the true statement
    # here, so it is shown instead of a generic refusal.
    discard producer.onRefusal(
      degradedBehaviour(platform.profile, capProcessSpawn))
    report($phase & "-refused", "reason=no-spawn")
    return

  proc onOutput(chunk: ProcessOutputChunk) =
    producer.onOutput(chunk)

  proc onExit(exit: ProcessExit) =
    onPhaseExit(producer, tmpl, exit)

  let started = ctAwaitSync(platform.process.start(
    ProcessSpec(
      command: "nargo",
      args: args,
      workingDir: templateProjectRoot(tmpl),
      stdinText: stdin),
    onOutput, onExit))

  if not started.ok:
    # `wasm_registry.refusal`'s four-case sentence, which always names the
    # command. Reported through `onRefusal` and not through `onExit`, because
    # nothing ran: a build that never started is not a build that failed, and
    # `onExit` would settle the pane at `bsFailed` with an exit code that
    # describes nothing.
    discard producer.onRefusal($started.error)
    report($phase & "-refused", "reason=" & $started.error.kind)
    return

  activeHandle = started.value
  activeInFlight = true
  inc lastStartCount
  report($phase & "-started", "handle=" & $activeHandle)

proc startTrace(producer: NoirBuildProducer; tmpl: ProjectTemplate) =
  let inputs = templateInputs(tmpl)
  if inputs.len == 0:
    producer.beginPhase(nbpTrace, "nargo trace", jsNowMs())
    discard producer.traceInputsMissing(noirInputsFile)
    report("trace-refused", "reason=no-inputs")
    return
  dispatch(producer, tmpl, nbpTrace, noirTraceArgs(),
           $noirTraceRequest(producer.artifact, inputs), "nargo trace")

proc startNoirBuild*(saved: seq[string] = @[]) =
  ## BUILD — compile the open project, report warnings and errors.
  ##
  ## `saved` names the editors the caller wrote out before calling, for the
  ## header. The SAVING is the caller's job rather than this module's: it needs
  ## `data.saveFiles`, which lives in `renderer.nim`, and reaching it from here
  ## would put a renderer dependency into the module that talks to the wasm
  ## toolchain. `ui_js`'s web arm owns both and does it there.
  if activeInFlight:
    report("build-ignored", "reason=already-running")
    return
  let tmpl = currentProject()
  if not tmpl.hasFiles:
    report("build-refused", "reason=no-project")
    return
  let producer = producerFor(tmpl)
  if producer.isNil:
    report("build-refused", "reason=no-build-vm")
    return
  activeIntent = nriBuild
  dispatch(producer, tmpl, nbpCompile, noirCompileArgs(),
           $noirVfsRequest(templateVfsEntries(tmpl), tmpl.name, nbmProgram),
           savedFilesLabel("nargo compile", saved))

proc startNoirRun*(saved: seq[string] = @[]) =
  ## RUN — compile for debugging, then trace.
  ##
  ## WHAT A USER SEES AT THE END OF THIS, stated plainly because it is easy to
  ## overclaim: the BUILD pane paints the compile's result and then the
  ## trace's shape — how many events, steps and calls it contains and which
  ## source files it covers, each as a clickable row. **It does not open a
  ## replay session.** There is no replay engine in this deployment — the
  ## db-backend wasm is absent from `webRuntimeAssets()` and every ViewModel
  ## logs `(stub backend)` — and the tracer emits a `MemoryTrace` document
  ## rather than a `.ct` container, so whether that engine would even accept
  ## it is an open question and not one this path answers. Painting a session
  ## that is not there would be the chain-of-agreements failure this campaign
  ## keeps finding, one layer up.
  if activeInFlight:
    report("run-ignored", "reason=already-running")
    return
  let tmpl = currentProject()
  if not tmpl.hasFiles:
    report("run-refused", "reason=no-project")
    return
  let producer = producerFor(tmpl)
  if producer.isNil:
    report("run-refused", "reason=no-build-vm")
    return
  activeIntent = nriRun
  dispatch(producer, tmpl, nbpCompile, noirCompileArgs(),
           $noirVfsRequest(templateVfsEntries(tmpl), tmpl.name, nbmDebug),
           savedFilesLabel("nargo compile --debug", saved))

proc noirTestRunAbsence*(): string =
  ## Why this deployment cannot run the tests, or "" when it can.
  ##
  ## THE FIELD THIS FILLS USED TO CARRY A PARAGRAPH SAYING NO DEPLOYMENT COULD.
  ## Every clause of it has since become false — `nv_test_vfs` is an export of
  ## `noir_wasm.wasm`, `wasm_worker_browser.js` routes `test` to it, and
  ## `nargo::ops::run_test` reaches the verdicts — so what is left is a
  ## question about THIS bundle, which is a question with a real answer either
  ## way.
  ##
  ## Asked of the platform rather than answered from a constant, because the
  ## answer genuinely varies: `webRuntimeAssets()` marks both Noir modules
  ## `required: false`, so a deployment that placed neither has no
  ## `capProcessSpawn` at all and `degradedBehaviour` already carries the
  ## sentence explaining it. A bundle missing only the TRACER can still run
  ## tests, which is why this asks about the capability and not about the
  ## tracer.
  ##
  ## A delivery that placed only the tracer is not detected here and does not
  ## need to be: the dispatch is refused by `wasm_registry` with
  ## `wrSubcommandNotBuilt`'s sentence, which names `nargo test` and lists what
  ## the module does provide — a better message than anything this proc could
  ## compose in advance, and one the pane shows through the ordinary run path.
  let platform = ctPlatform()
  if not platform.can(capProcessSpawn):
    return degradedBehaviour(platform.profile, capProcessSpawn)
  ""

proc startNoirTests*(saved: seq[string] = @[]) =
  ## TEST — run the open project's `#[test]` functions and report each verdict.
  ##
  ## ONE DISPATCH, not a compile followed by anything: `nv_test_vfs` resolves
  ## the tree, elaborates the crate, discovers the tests with
  ## `get_all_test_functions_in_crate_matching` and runs each through
  ## `nargo::ops::run_test`, which is the same function `nargo test` calls. So
  ## `#[test(should_fail)]`'s inversion — an assertion failure is a pass — is
  ## decided by nargo and not by anything in this repository.
  ##
  ## No `mode` is sent. `nargo test` compiles with `CompileOptions::default()`,
  ## and asking for `debug` would run an INSTRUMENTED program, which is not the
  ## one the user tests locally; two runners disagreeing about the same suite
  ## is the single outcome this whole path exists to avoid.
  if activeInFlight:
    report("test-ignored", "reason=already-running")
    return
  let tmpl = currentProject()
  if not tmpl.hasFiles:
    report("test-refused", "reason=no-project")
    return
  let producer = producerFor(tmpl)
  if producer.isNil:
    report("test-refused", "reason=no-build-vm")
    return
  activeIntent = nriTest
  if not noirTestRunStarted.isNil:
    noirTestRunStarted()
  dispatch(producer, tmpl, nbpTest, noirTestArgs(),
           $noirTestRequest(templateVfsEntries(tmpl), tmpl.name),
           savedFilesLabel("nargo test", saved))
  if not activeInFlight:
    # `dispatch` refused before the worker saw anything — no `onExit` will
    # arrive, so the pane would sit `inFlight` forever behind a disabled ▶.
    # The refusal itself is already painted in the build pane by `onRefusal`.
    if not noirTestRunSink.isNil:
      noirTestRunSink(producer.lastTests, tmpl.name)
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()

proc stopNoirBuild*() =
  ## STOP — terminate the worker.
  ##
  ## `sigTerminate` and never `sigInterrupt`: `web_platform.buildProcess`
  ## refuses the latter by name, because `worker.terminate()` is immediate and
  ## uninterceptable and there is no honest implementation of "ask it to
  ## stop". The refusal is the correct answer and answering it by terminating
  ## anyway would tell a caller a cooperative shutdown had been requested.
  ##
  ## The run settles through `onExit` with `signalled: true`, which
  ## `noir_build_producer.onExit` reports as `npvCancelled` rather than as a
  ## failure — `process.nim`'s own distinction, and the reason a stopped Run
  ## does not paint a red pane about a program that is fine.
  if not activeInFlight or activeProducer.isNil:
    report("stop-ignored", "reason=nothing-running")
    return
  # A terminate cancels the whole Run, not just its current phase.
  activeIntent = nriBuild
  discard ctAwaitSync(ctPlatform().process.signal(activeHandle, sigTerminate))
  report("stop-requested", "")

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

proc installNoirBuildCommands*(tmpl: ProjectTemplate) =
  ## Point the BUILD pane's ▶ and ■ at the wasm toolchain.
  ##
  ## Called after `enterTemplateEditMode`, which is when `buildVMInstance`
  ## exists: `onNoTrace` runs `configureMiddleware()`, and that is what calls
  ## `initBuildVMWithStore` and installs the DESKTOP `runBuild`
  ## (`data.update(build=true)`, which sends `CODETRACER::update` to a host
  ## this tab does not have). Overwriting it here rather than branching inside
  ## `ui_js.nim` keeps the desktop's wiring exactly as it was.
  ##
  ## `cancelBuildProc` likewise, and it is now the *only* way a build stops.
  ## `build_vm.cancelBuild` used to fall back to dispatching `ct/build-cancel`
  ## on the backend, described there as "the desktop's channel"; it was no
  ## such thing — `backend/dap_dialect.md` §7 records it as having no engine
  ## implementation, and no view sends any build-cancel channel either. A
  ## browser's stub backend resolved it `{}`, making a Stop that did nothing
  ## look like one that worked. The fallback is gone, so `cancelBuildProc` —
  ## registered just above — is what makes ■ Stop terminate the Worker.
  # NO LONGER CACHES THE TEMPLATE. It used to do `buildTemplate = tmpl`, and
  # that assignment WAS the defect: a copy of a value type, frozen here, read
  # by every later Build. The pane's callbacks below take no template at all —
  # they read `currentProject()` when they fire, so a Build always compiles
  # what the editor last saved.
  if build_pane.buildVMInstance.isNil:
    report("install-skipped", "reason=no-build-vm")
    return
  build_pane.buildVMInstance.runBuild = proc() = startNoirBuild()
  build_pane.buildVMInstance.cancelBuildProc = proc() = stopNoirBuild()
  report("installed", "files=" & $tmpl.files.len & " package=" & tmpl.name)
