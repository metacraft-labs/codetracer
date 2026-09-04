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
# `join`, for the one-test command label. `ui_imports` does not bring it.
from std/strutils import join

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
# The one predicate this module asks of the replay host: can it hold a SECOND
# live session? `noir_build_producer` imports the service for the request type
# and does not re-export it, so the question is imported here directly rather
# than widening that module's export surface for one proc.
from ../viewmodel/backend/replay_session_service import
  canOpenSecondReplaySession
from ../viewmodel/viewmodels/build_vm import BuildVM
import ./build as build_pane
# The PROBLEMS pane's mirror of the same diagnostics. `from ... import` to keep
# this module's import surface narrow — it needs three procs, not the module.
from ./errors import
  syncErrorsAppendProblem, syncErrorsClear, highlightFirstBuildError
from ../viewmodel/store/types import BuildProblemLine
# THE EDIT-MODE TOPBAR. `editModeToolbar` composes the model, `debug` mounts
# it, and `currentWasmRegistry` is what lets the browser tier resolve
# `nargo compile` at subcommand granularity instead of refusing every command.
from ../viewmodel/viewmodels/edit_mode_toolbar import
  editModeToolbar, EditToolbarModel, ToolbarMode
from ../viewmodel/platform/web_platform import currentWasmRegistry
import ./debug

export noir_build_producer

type
  NoirRunIntent* = enum
    ## Which gesture started this. One producer and one handle serve both, so
    ## the difference has to be a value: a Build stops after the compile, a
    ## Run continues into the tracer with the artifact the compile produced.
    nriBuild
    nriRun
    nriTest
      ## `nargo test`. One phase: the module compiles each test function and
      ## executes it inside one `nv_test_vfs` call, so there is nothing for
      ## this module to chain.
    nriTestRecord
      ## RUN THIS TEST IN THE DEBUGGER — the editor's Run-test control, and
      ## what "running a test" means in this product.
      ##
      ## Three phases, chained here: the VERDICT (`nbpTest`, which fills the
      ## Test Results pane), the ARTIFACT (`nbpTestRecord`, which compiles that
      ## one test through the instrumented `force_brillig` path), and the TRACE
      ## (`nbpTrace`, whose existing exit path hands the recording to
      ## `requestReplaySession`). The debugger session is the product; the
      ## verdict is a by-product that arrives first because it is cheap and
      ## because a user who clicked Run on a test wants to know it failed even
      ## if the recording then cannot be opened.

var
  noirConstraintsSink*: proc(listing: string; packageDir: string;
                             provenance: string)
    ## Where a finished COMPILE's constraint listing goes.
    ##
    ## The Constraints pane used to be told a number: a compile-time constant
    ## of `nargo info --json`, measured on a developer's machine because a
    ## browser has no `nargo`. `Generated-Code-Listing.md` §15.4 records what
    ## that cost — the constant was produced by the NATIVE toolchain and
    ## rendered by the WEB engine, two compilers 3,699 commits apart in the
    ## ACIR-generating paths, so it was wrong by two opcodes for every visitor
    ## while a gate comparing it against the wrong `nargo` certified it.
    ##
    ## So the pane is no longer told. It is handed the listing THIS compile
    ## produced and counts the rows itself, because one opcode is one row. A
    ## number the pane computes cannot drift from the thing it describes.
    ##
    ## A CALLBACK for `noirTestRunSink`'s reason: this module talks to the
    ## wasm toolchain and the Constraints pane is a second surface over the
    ## same compile. `ui_js` installs it, being the one place that can see
    ## both.
    ##
    ## Nil is a real state — a build with no Constraints pane — and an empty
    ## `listing` is ordinary rather than a fault: a compiler module older than
    ## `VfsResponse.acir_listing` answers without it, and the pane must then
    ## say it has no counts rather than show a number from somewhere else.
  noirConstraintsCompileStarted*: proc()
    ## Told at DISPATCH of a COMPILE, before the worker has answered.
    ##
    ## `noirTestRunStarted`'s shape, one pane over, and for the reason that
    ## file gives: the pane needs the event, and the result stream cannot
    ## supply it — a compile that is running has produced nothing yet, so there
    ## is no message whose absence means "in flight" rather than "idle".
    ##
    ## COMPILE ONLY. `nbpTest`, `nbpTestRecord` and `nbpTrace` also run through
    ## `dispatch` and none of them produces a constraint listing, so a pane
    ## told about those would announce a compile and then never replace the
    ## counts it promised to replace. That is why this is not
    ## `BuildVM.isRunning`, which is true for all four.
  noirConstraintsCompileSettled*: proc(listingAbsence: string)
    ## Told when a COMPILE settles, however it settled — including a refusal
    ## that never reached the worker.
    ##
    ## Paired with the above for `noirTestRunSettled`'s reason: a pane left in
    ## flight over a run that is not would claim progress that stopped, and
    ## unlike a disabled button that state never corrects itself.
    ##
    ## `listingAbsence` is a SENTENCE ON FAILURE and empty on success. The
    ## caller states it rather than the pane inferring it, because only the
    ## caller knows which of the failures happened: a refusal names the
    ## capability the deployment lacks, and a rejected compile is the user's
    ## program. A pane that guessed would print the reassuring guess.
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
  activeRecordInNewTab = false
    ## Whether the in-flight `nriTestRecord` gesture asked for a NEW session
    ## tab. §9.1's interaction — "a developer comparing a passing and a failing
    ## case does not lose one to look at the other" — and a REQUEST rather than
    ## a command: `openReplaySession` refuses it by name on a host that holds
    ## one live session, and nothing is opened.

  activeRecordSelector = ""
    ## Which test the in-flight `nriTestRecord` gesture is about. Held here
    ## rather than derived from the response because the RECORD dispatch needs
    ## it after the VERDICT dispatch has already answered, and the verdict
    ## response names every test that ran rather than the one that was clicked.

  activeProducer: NoirBuildProducer
  activeHandle: ProcessHandle
  activeIntent: NoirRunIntent
  activeInFlight = false
  activeRevealsBuildPane = true
    ## Whether the run in flight is allowed to bring the BUILD pane forward.
    ##
    ## TRUE FOR EVERY GESTURE, and false for exactly one caller:
    ## `startNoirConstraintsCompile`, the compile the page runs by itself so
    ## that a visitor who lands and does nothing still sees a listing.
    ##
    ## THIS FLAG IS THE DIFFERENCE BETWEEN THAT FEATURE AND A REGRESSION.
    ## `dispatch` and `onPhaseExit` both call `ensureBuildPaneVisible`, and on
    ## a browser layout the BUILD pane is a standalone auto-hide OVERLAY drawn
    ## on top of the right-hand column — the column the CONSTRAINTS pane owns.
    ## Measured on the live deployment: after Ctrl+B, `elementFromPoint` over
    ## the CONSTRAINTS pane's centre returns `DIV.build-output-container` and
    ## the opcode rows are underneath it until Escape is pressed. An automatic
    ## compile that revealed the pane would therefore cover the listing it was
    ## started to produce, on every page load, for every visitor — a worse
    ## version of the defect it fixes.
    ##
    ## The output is NOT suppressed, only the reveal: the rows are painted into
    ## the BUILD pane as usual and are there for anyone who opens it. What a
    ## page does on its own account does not get to take the screen; what a
    ## user asked for does.
    ##
    ## Restored to true on every gesture entry point rather than on settle, so
    ## a run that never settles cannot leave a later gesture unable to show its
    ## own output.
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

proc jsLocalTimeText(): cstring {.importjs: "new Date().toLocaleTimeString()".}
  ## The wall-clock time a compile finished, in the visitor's own locale.
  ##
  ## For the Constraints pane's provenance, which must name WHICH compile a
  ## count came from rather than which command could have produced one.

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
  ##
  ## SUPPRESSED FOR THE AUTOMATIC COMPILE, and only for that one — see
  ## `activeRevealsBuildPane`, whose comment records what revealing it would
  ## cover. The MOUNT still happens: a pane that is not shown must still be
  ## able to paint, or the run's output would be lost rather than merely
  ## unrevealed, and a user who then opened BUILD would find it empty.
  if not activeRevealsBuildPane:
    build_pane.tryMountIsoNimBuildPanel()
    return
  if not data.isNil and not data.ui.layout.isNil:
    data.openLayoutTab(Content.Build)
  build_pane.autoRevealBuildPanel()
  build_pane.tryMountIsoNimBuildPanel()

proc producerFor(tmpl: ProjectTemplate): NoirBuildProducer =
  ## One producer per pane, rebuilt if the VM was replaced underneath it OR if
  ## it is holding a different project's paths.
  ##
  ## `initBuildVMWithStore` replaces `buildVMInstance` when the shared store
  ## arrives, so a producer captured earlier would be writing into a VM no
  ## view is bound to — a build that ran, succeeded, and painted nothing.
  ##
  ## THE SECOND CLAUSE IS THE SAME FROZEN-VALUE SHAPE, one layer down, and it
  ## is closed here rather than left latent. `projectRoot` and `packageDir` are
  ## COPIES of a `ProjectTemplate`'s fields taken at construction; a producer
  ## built for one project and reused for another would map every diagnostic's
  ## VFS path against the wrong root, so a click on an error would open nothing
  ## and the pane would look broken rather than wrong. Reachable only through a
  ## second `setCurrentProject` in one session — which today means a reload, so
  ## this is a latent member of the class rather than a live defect. It is
  ## still a member, and the test for it is one comparison.
  if build_pane.buildVMInstance.isNil:
    return nil
  let root = templateProjectRoot(tmpl)
  if activeProducer.isNil or
     activeProducer.vm != build_pane.buildVMInstance or
     activeProducer.projectRoot != root or
     activeProducer.packageDir != tmpl.name:
    activeProducer = newNoirBuildProducer(
      build_pane.buildVMInstance,
      projectRoot = root,
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

proc dispatch(producer: NoirBuildProducer; tmpl: ProjectTemplate;
              phase: NoirBuildPhase; args: seq[string]; stdin: string;
              label: string)
  ## Forward-declared because `onPhaseExit` chains — `nriTestRecord` runs three
  ## phases and each dispatch happens inside the previous one's exit — and the
  ## definition needs `onPhaseExit` for its own callbacks. `startTrace` above
  ## is forward-declared for the same reason, one gesture earlier.

proc onPhaseExit(producer: NoirBuildProducer; tmpl: ProjectTemplate;
                 exit: ProcessExit) =
  ## The worker's `exit`, and the one place the two phases are chained.
  let phase = producer.phase
  let verdict = producer.onExit(exit)
  activeInFlight = false
  report($phase & "-exit", "verdict=" & $verdict & " code=" & $exit.exitCode)

  # THE COUNTS COME OFF THIS COMPILE, before the phase chaining below decides
  # what happens next. Published on every successful `nbpCompile` regardless of
  # intent, because Build and Run compile the same program and a visitor who
  # pressed either has just produced the artefact the pane describes.
  #
  # NOT on `nbpTestRecord`, whose artifact is a single test compiled with
  # `force_brillig` — GCL-D9: that artefact has no located ACIR opcodes at all,
  # so counting it would replace the program's constraints with a test's, and
  # a `debug` compile's listing is one row.
  # THE CONSTRAINTS PANE STOPS SAYING "COMPILING", whatever the verdict was.
  #
  # BEFORE the sink below and before the phase chaining, so that every exit
  # path out of this proc has already cleared it — `nriRun` returns early into
  # `startTrace`, `nriTestRecord` returns early twice, and a settle placed
  # after any of them would be skipped on exactly the runs that take longest.
  #
  # On success the sentence is empty and the sink replaces the whole report a
  # line later; on a refusal or a rejected compile it is the pane's only
  # account of what happened, because `noirConstraintsSink` does not fire at
  # all on those and the pane would otherwise hold the bundled counts under a
  # caption promising a listing that is no longer coming.
  if phase == nbpCompile and not noirConstraintsCompileSettled.isNil:
    noirConstraintsCompileSettled(
      if verdict == npvSucceeded: ""
      else: "The compile this page started did not finish, so the generated " &
            "code cannot be shown. The BUILD pane has the compiler's output.")

  if phase == nbpCompile and verdict == npvSucceeded and
     not noirConstraintsSink.isNil:
    # THE PROVENANCE NAMES THE COMPILE, not the command that could produce one.
    # GCL-D10: the sentence it replaces was `"nargo info --json, run against
    # this template at build time"`, which named a command and left two counts
    # from two different compilers indistinguishable behind it. A wall-clock
    # time is what makes this name WHICH compile — §15.3's "one artefact, one
    # provenance, one timestamp", with the timestamp being the only part the
    # pane could not previously say.
    noirConstraintsSink(producer.acirListing, tmpl.name,
                        "compiled in this tab at " & $jsLocalTimeText())

  if phase == nbpCompile and verdict == npvSucceeded and
     activeIntent == nriRun:
    startTrace(producer, tmpl)
    return

  if phase == nbpTest and activeIntent == nriTestRecord and
     producer.lastTests.ok and activeRecordSelector.len > 0:
    # THE VERDICT LANDED; NOW RECORD IT. Published to the pane first — the
    # block below runs on the same exit — so a user sees the pass or the
    # failure while the recording compiles, rather than watching nothing for
    # the seconds an instrumented compile takes.
    if not noirTestRunSink.isNil:
      noirTestRunSink(producer.lastTests, tmpl.name)
    report("test-results",
           "ok=true passed=" & $producer.lastTests.passed &
           " failed=" & $producer.lastTests.failed &
           " recording=" & activeRecordSelector)
    dispatch(producer, tmpl, nbpTestRecord, noirTestArgs(),
             $noirTestRecordRequest(templateVfsEntries(tmpl), tmpl.name,
                                    activeRecordSelector),
             "nargo test --record " & activeRecordSelector)
    if not activeInFlight and not noirTestRunSettled.isNil:
      noirTestRunSettled()
    return

  if phase == nbpTestRecord:
    if verdict == npvSucceeded:
      # THE ARTIFACT IS THE TEST'S, so the trace is of the test and not of
      # `main`. Empty inputs: a `#[test]` takes no arguments and the module
      # refuses to record one that does, so its ABI has nothing to encode.
      producer.replayLabel = activeRecordSelector
      producer.replayInNewSessionTab = activeRecordInNewTab
      dispatch(producer, tmpl, nbpTrace, noirTraceArgs(),
               $noirTraceRequest(producer.artifact, noirTestRecordInputs),
               "nargo trace " & activeRecordSelector)
      if activeInFlight:
        return
    # Either the recording was refused, or the trace could not be dispatched.
    # Settling here is what releases the editor's Run-test button; without it
    # the gesture would end with a spinner over a run that is over.
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()
    return

  if phase == nbpTrace and activeIntent == nriTestRecord:
    # The trace arm of `noir_build_producer.onExit` has already offered the
    # recording to `requestReplaySession` and painted what it contains.
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()
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

  # ANNOUNCED BEFORE THE SPAWN IS ATTEMPTED, not after it succeeds.
  #
  # The two refusal branches below both return, and both settle the pane by
  # name; announcing first is what makes those settles meaningful instead of
  # clearing a flag that was never set. It also covers the case the automatic
  # compile makes ordinary — a deployment that shipped no wasm modules refuses
  # at `capProcessSpawn` synchronously, and the pane must say "the compile did
  # not start" rather than never having mentioned a compile at all.
  if phase == nbpCompile and not noirConstraintsCompileStarted.isNil:
    noirConstraintsCompileStarted()

  if not platform.can(capProcessSpawn):
    # The registry is empty, so `newWebPlatform` subtracted the capability and
    # attached `webNoModulesLoaded` as its degradation. That sentence names
    # the deployment rather than the command, which is the true statement
    # here, so it is shown instead of a generic refusal.
    discard producer.onRefusal(
      degradedBehaviour(platform.profile, capProcessSpawn))
    report($phase & "-refused", "reason=no-spawn")
    if phase == nbpCompile and not noirConstraintsCompileSettled.isNil:
      # THE DEPLOYMENT'S OWN SENTENCE, not one invented here. `webNoModulesLoaded`
      # names the modules this page did not load, which is the true statement —
      # a generic "the compile failed" would blame the project.
      noirConstraintsCompileSettled(
        degradedBehaviour(platform.profile, capProcessSpawn))
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
    if phase == nbpCompile and not noirConstraintsCompileSettled.isNil:
      noirConstraintsCompileSettled($started.error)
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
  activeRevealsBuildPane = true
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

proc startNoirConstraintsCompile*() =
  ## The compile the PAGE runs, so that a visitor who lands and does nothing
  ## still sees the generated code.
  ##
  ## ## Why this is not `startNoirBuild()`
  ##
  ## Two differences, and both are about it being the page's gesture rather
  ## than the user's.
  ##
  ## **It does not bring the BUILD pane forward.** `dispatch` and `onPhaseExit`
  ## both call `ensureBuildPaneVisible`, and on a browser layout that pane is a
  ## standalone auto-hide OVERLAY drawn over the right-hand column — the column
  ## CONSTRAINTS owns. Measured on the live deployment: after Ctrl+B,
  ## `elementFromPoint` at the CONSTRAINTS pane's centre returns
  ## `DIV.build-output-container`, and the probe has to press Escape before it
  ## can read the rows. A compile that ran on every page load and revealed that
  ## overlay would cover the listing it exists to produce. The output is still
  ## painted into the pane; only the reveal is suppressed.
  ##
  ## **It yields to any gesture rather than competing with one.** The
  ## `activeInFlight` check in `startNoirBuild` reports `already-running` and
  ## drops the request, which is right for a user who pressed a key twice and
  ## wrong as the only account of an automatic compile that never happened — so
  ## this reports under its own name. A user who presses Ctrl+B while this is
  ## in flight gets `build-ignored`, which is correct: the compile they would
  ## have started is the one already running, and its result lands in the same
  ## pane.
  ##
  ## ## What it does NOT do
  ##
  ## It does not save. Nothing is dirty at boot, and `saveThenCompile` exists
  ## to close the window where an unsaved buffer is not in `currentProject()`;
  ## there is no such window before the visitor has typed. Calling it here
  ## would send `CODETRACER::save-file` for zero editors and defer this compile
  ## by an extra macrotask for nothing.
  ##
  ## It does not retry. A refusal is reported to the pane through
  ## `noirConstraintsCompileSettled`, which states it; a page that quietly
  ## re-dispatched a compile the deployment cannot run would fetch nothing
  ## repeatedly and say nothing about it.
  activeRevealsBuildPane = false
  if activeInFlight:
    # NOT REACHABLE FROM THE BOOT PATH TODAY — this runs one macrotask after
    # the mount, and the only other dispatcher is a gesture a user has not had
    # time to make. Reported rather than asserted because the ordering that
    # makes it unreachable is not this proc's to guarantee, and a silent return
    # here would look exactly like a compile that ran.
    report("constraints-compile-ignored", "reason=already-running")
    activeRevealsBuildPane = true
    return
  let tmpl = currentProject()
  if not tmpl.hasFiles:
    report("constraints-compile-refused", "reason=no-project")
    activeRevealsBuildPane = true
    return
  let producer = producerFor(tmpl)
  if producer.isNil:
    report("constraints-compile-refused", "reason=no-build-vm")
    activeRevealsBuildPane = true
    return
  activeIntent = nriBuild
  report("constraints-compile-started", "package=" & tmpl.name)
  dispatch(producer, tmpl, nbpCompile, noirCompileArgs(),
           $noirVfsRequest(templateVfsEntries(tmpl), tmpl.name, nbmProgram),
           "nargo compile")

proc startNoirRun*(saved: seq[string] = @[]) =
  ## RUN — compile for debugging, then trace.
  ##
  ## WHAT A USER SEES AT THE END OF THIS: the BUILD pane paints the compile's
  ## result and then the trace's shape — how many events, steps and calls it
  ## contains and which source files it covers, each as a clickable row — and
  ## then **the tab leaves edit mode for the debugging surface**, with a live
  ## replay session over that trace.
  ##
  ## THIS PARAGRAPH SAID THE OPPOSITE FOR ONE DAY, and the way it went wrong is
  ## worth more than the correction. It read: "**It does not open a replay
  ## session.** There is no replay engine in this deployment — the db-backend
  ## wasm is absent from `webRuntimeAssets()` and every ViewModel logs `(stub
  ## backend)`". Every clause of that was true when it was written and false
  ## three commits later, on the same day:
  ##
  ## * `web_deployment.nim` now declares `replayEngineModuleId`,
  ##   `replayEngineGlueId` and `replayWorkerModuleId`, and `webRuntimeAssets()`
  ##   emits all three, so the db-backend wasm is IN the manifest.
  ## * `ui/web_replay_host.installReplayHost` answers
  ##   `CODETRACER::dap-raw-message` — the id `newWebIpc` used to log "no host
  ##   for this surface" against — and boots the engine in a worker.
  ## * `enterTemplateEditMode` calls it, so it is installed for every template
  ##   route including `/noir/demo`.
  ## * The `MemoryTrace`/`.ct` question it left open is answered:
  ##   `platform/replay_engine_vfs.replayVfsPayload` writes the trace and its
  ##   recorded `source_views` into the engine's VFS.
  ##
  ## THE COST OF LEAVING IT was not a broken feature, it was a false map. This
  ## is the most authoritative-looking prose in the file, and it told anyone
  ## reading it that the browser is a build-only surface — so work that
  ## depended on browser replay looked blocked when it was shipping. Read
  ## `web_replay_host.nim` and `web_deployment.webRuntimeAssets()` for what is
  ## true now, and do not restate their contents here; that is exactly the
  ## duplication that rotted.
  ##
  ## `noirTestRunAbsence` below opens with the same sentence about its own
  ## field, for the same reason, twenty lines down. When a paragraph here says
  ## a capability is impossible, suspect it.
  ##
  ## WHAT REMAINS TRUE is the fallback, and it is still reachable: a deployment
  ## that ships no worker or no engine cannot replay, and
  ## `noir_build_producer`'s trace arm says so by name and leaves the counted
  ## rows as the answer. That is a deployment property, asked of the descriptor
  ## — not a property of this product.
  # EVERY GESTURE RESTORES THE REVEAL, and it is restored on ENTRY rather
  # than when the automatic compile settles. A run that never settles —
  # a worker that dies, a page suspended mid-compile — would otherwise
  # leave the flag down, and the next thing a user pressed would run with
  # its output painted into a pane nothing brought forward.
  activeRevealsBuildPane = true
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

proc startNoirTests*(saved: seq[string] = @[]; only: seq[string] = @[]) =
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
  # EVERY GESTURE RESTORES THE REVEAL, and it is restored on ENTRY rather
  # than when the automatic compile settles. A run that never settles —
  # a worker that dies, a page suspended mid-compile — would otherwise
  # leave the flag down, and the next thing a user pressed would run with
  # its output painted into a pane nothing brought forward.
  activeRevealsBuildPane = true
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
  # `only` is a list of the runner's own fully-qualified names, matched
  # EXACTLY — `nargo test --exact`'s comparison, and the label says so, because
  # a pane headline reading "1 passed" over a project with five tests is only
  # honest if the command line beside it says one was asked for.
  let label =
    if only.len == 0: "nargo test"
    else: "nargo test --exact " & only.join(" ")
  dispatch(producer, tmpl, nbpTest, noirTestArgs(),
           $noirTestRequest(templateVfsEntries(tmpl), tmpl.name, only),
           savedFilesLabel(label, saved))
  if not activeInFlight:
    # `dispatch` refused before the worker saw anything — no `onExit` will
    # arrive, so the pane would sit `inFlight` forever behind a disabled ▶.
    # The refusal itself is already painted in the build pane by `onRefusal`.
    if not noirTestRunSink.isNil:
      noirTestRunSink(producer.lastTests, tmpl.name)
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()

proc canRecordTestInNewSessionTab*(): bool =
  ## Whether "run this test in a NEW session tab" can be offered.
  ##
  ## ASKED BEFORE THE GESTURE IS OFFERED, so a menu never shows an option that
  ## will be refused — which is the dead-affordance shape with a tab bar to
  ## make it convincing. `ui/web_replay_host` answers `false` today and its
  ## comment names exactly what would make it true.
  canOpenSecondReplaySession()

proc startNoirTestRecording*(selector: string;
                             newSessionTab: bool = false) =
  ## RUN ONE TEST IN THE DEBUGGER — the editor's Run-test control.
  ##
  ## "Running a test" in this product means recording it and replaying it: the
  ## test executes, its execution is captured, and the user lands in a
  ## time-travel session on it. The pass or fail is a by-product and arrives
  ## first; the session is what was asked for.
  ##
  ## THE VERDICT IS NOT SKIPPED to save a dispatch. A recording compiles the
  ## test through the instrumented `force_brillig` path, which is a DIFFERENT
  ## program from the one `nargo test` runs — so a session opened without the
  ## verdict would show an execution whose pass/fail nobody had established
  ## against the compile options a developer's own terminal uses.
  # EVERY GESTURE RESTORES THE REVEAL, and it is restored on ENTRY rather
  # than when the automatic compile settles. A run that never settles —
  # a worker that dies, a page suspended mid-compile — would otherwise
  # leave the flag down, and the next thing a user pressed would run with
  # its output painted into a pane nothing brought forward.
  activeRevealsBuildPane = true
  if activeInFlight:
    report("test-record-ignored", "reason=already-running")
    return
  if selector.len == 0:
    report("test-record-refused", "reason=no-selector")
    return
  let tmpl = currentProject()
  if not tmpl.hasFiles:
    report("test-record-refused", "reason=no-project")
    return
  let producer = producerFor(tmpl)
  if producer.isNil:
    report("test-record-refused", "reason=no-build-vm")
    return
  if newSessionTab and not canRecordTestInNewSessionTab():
    # REFUSED BEFORE ANYTHING RUNS. Compiling, running and tracing a test and
    # only then discovering the session cannot be opened where it was asked for
    # would spend seconds to reach a refusal that was knowable at the click.
    report("test-record-refused", "reason=no-second-session")
    return
  activeIntent = nriTestRecord
  activeRecordSelector = selector
  activeRecordInNewTab = newSessionTab
  if not noirTestRunStarted.isNil:
    noirTestRunStarted()
  dispatch(producer, tmpl, nbpTest, noirTestArgs(),
           $noirTestRequest(templateVfsEntries(tmpl), tmpl.name, @[selector]),
           "nargo test --exact " & selector)
  if not activeInFlight:
    if not noirTestRunSink.isNil:
      noirTestRunSink(producer.lastTests, tmpl.name)
    if not noirTestRunSettled.isNil:
      noirTestRunSettled()

proc startNoirTest*(selector: string) =
  ## Run ONE test — the editor's Run-test control, and the Test Results pane's
  ## per-row action when it grows one.
  ##
  ## The whole suite is not run and then filtered: `nv_test_vfs` takes the
  ## selection, so a project with a slow test does not pay for it to answer a
  ## question about a fast one. `TestVfsRequest.tests` is `FunctionNameMatch::
  ## Exact`, which is the same comparison `nargo test --exact` makes against
  ## the same strings.
  if selector.len == 0:
    report("test-refused", "reason=no-selector")
    return
  startNoirTests(only = @[selector])

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

var editToolbarInvoke: proc(id: string)
  ## The `invoke` the last `installEditModeToolbar` was given.
  ##
  ## Held so `refreshEditModeToolbar` can RECOMPOSE without the caller having
  ## to supply it again — and, more to the point, so a refresh is possible at
  ## all from a site that does not have it. `onSavedFile` is in `ui_js` and the
  ## thing a Build button must do lives there too, but the save handler has no
  ## reason to know about toolbar wiring.

proc installEditModeToolbar*(invoke: proc(id: string)) =
  ## Compose the edit-mode topbar from what this tab actually is, and hand it
  ## to the mount.
  ##
  ## `invoke` is the caller's, because the thing a Build button must do —
  ## SAVE, then compile — lives in `ui_js.nim` as `saveThenCompile`, which is
  ## also what `data.actions[ClientAction.build]` and Ctrl+B dispatch through.
  ## Reaching it from here would be an import cycle; reproducing it would be a
  ## second path to the same feature, and the two would drift on the first fix
  ## applied to one of them.
  ##
  ## THIS PROC IS THE WHOLE OF WHY THE FEATURE WAS INVISIBLE.
  ## `viewmodels/edit_mode_toolbar.nim` is 1043 lines, tested on both backends,
  ## and until now was imported by nothing outside its own two suites — a
  ## correct capability that nothing reached, which is this campaign's most
  ## common defect and was the user's bug report in its visible form.
  ##
  ## Composed HERE rather than in `ui/debug.nim` because a model needs three
  ## things only a platform knows, and `debug.nim` is shared with the desktop:
  ##
  ##   * the PROFILE — `capProcessArbitraryPrograms` vs the browser's
  ##     `capProcessSpawn`, which is what makes Build enabled or refused;
  ##   * the REGISTRY — resolved at subcommand granularity, so `nargo compile`
  ##     is allowed and a subcommand this build lacks is refused by name;
  ##   * the LISTING — `Nargo.toml` is what `projectKinds` recognises, and it
  ##     is read from `currentProject()` for the same reason the build
  ##     callbacks are: a frozen copy compiles a project the user has since
  ##     edited away from.
  ##
  ## Called on every install and after every save, so a file that adds a
  ## `Nargo.toml` changes the toolbar rather than waiting for a reload.
  ##
  ## THAT SENTENCE WAS FALSE WHEN IT WAS WRITTEN. This proc had exactly one
  ## call site — the one-shot `if wantsTemplate and mounted:` block in `ui_js`
  ## — and `EditToolbarModel` is a plain `object`, so `debug.editToolbarModel`
  ## held a snapshot composed from the startup listing and the startup mode.
  ## `debug.setEditModeToolbar`'s own comment made the matching assumption
  ## ("every change a user makes that could alter it... arrives as a NEW model")
  ## and no new model ever arrived. A visitor who created a `Nargo.toml`
  ## mid-session got a toolbar computed before it existed.
  ##
  ## `refreshEditModeToolbar` below is what makes the sentence true, and
  ## `onSavedFile` is what calls it — beside the `ns9-panes` re-ask it already
  ## makes, because a save is the same event for the same reason.
  let platform = ctPlatform()
  let project = currentProject()
  var listing: seq[string] = @[]
  for file in project.files:
    listing.add file.path

  let model = editModeToolbar(
    platform.profile,
    ToolbarMode(data.ui.mode.ord),
    listing = listing,
    wasm = currentWasmRegistry())

  editToolbarInvoke = invoke
  debug.setEditModeToolbar(model, invoke)
  report("edit-toolbar", "buttons=" & $model.buttons.len &
    " kinds=" & $model.kinds.len & " group=" & $model.commandGroupVisible)

proc refreshEditModeToolbar*() =
  ## Recompose the edit-mode topbar from the project as it is NOW.
  ##
  ## Every input `installEditModeToolbar` reads can change during a session:
  ## the LISTING (a save can add `Nargo.toml`, which is what `projectKinds`
  ## recognises), the MODE (a Run leaves edit mode and an explicit action
  ## returns), and the REGISTRY (a module can finish loading). The model is a
  ## value, so none of those reach a toolbar already mounted.
  ##
  ## A no-op before the first install, which is the honest answer rather than
  ## composing a toolbar for a session that has not started: `invoke` is the
  ## caller's and this module cannot invent one.
  if editToolbarInvoke.isNil:
    return
  installEditModeToolbar(editToolbarInvoke)

proc installNoirBuildCommands*() =
  ## TAKES NO PROJECT, and that is the point rather than a tidy-up.
  ##
  ## It used to take one and cache it (`buildTemplate = tmpl`), which was the
  ## frozen-value defect its own comment below records. The cure was applied by
  ## reading `currentProject()` in the callbacks instead — a HABIT, which is
  ## why the same defect then recurred in `installTemplatePaneHost`, 140 lines
  ## below an `installTemplateHost` whose header is entirely about it.
  ##
  ## A habit is not checkable. A SIGNATURE is: with no parameter there is
  ## nothing to capture, so the defect is unrepresentable here rather than
  ## merely absent, and a reader confirms it from one line instead of three
  ## headers.
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
  let project = currentProject()
  report("installed",
         "files=" & $project.files.len & " package=" & project.name)
