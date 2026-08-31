## NS3: the wasm module registry the web instantiation runs commands through —
## Noir-Studio.md §3.1's web column, "wasm modules in the tab".
##
## Runs on **both** backends by discovery, and the JS run is the load-bearing
## one: `platform/wasm_registry.nim` and `platform/web_platform.nim` are what a
## browser tab executes. Neither reaches a browser API, so the subject here is
## the shipped code and what varies is the `WasmHost`.
##
## ## What this suite is actually guarding
##
## Every assertion below was written against a deliberately broken version of
## the subject first, and each one names the version it fails against. The
## milestone file records why: the recurring defect in this tree is "types line
## up, the build stays green, the behaviour becomes wrong", and a test that
## passes against the broken code is worse than no test — it certifies the
## defect. Four shapes get that treatment here:
##
## 1. A resolver that answers `wrNoModuleForCommand` for a subcommand a
##    registered module does not implement. Types identical, one enum value
##    different, and the user is told `nargo` does not exist when they have it.
## 2. A resolver that falls back to the basename of a path-qualified command,
##    so `./tools/nargo` silently runs the studio's module instead of the
##    project's own file.
## 3. A `run` that hands the spec to the host without resolving, letting the
##    host answer. Green on the happy path; puts the mid-run surprise back.
## 4. A `newWebPlatform` that leaves `capProcessSpawn` on when the registry is
##    empty. Every type checks; the product shows a Run button that refuses.

import std/[unittest, strutils]

import ../../platform/outcome
import ../../platform/capabilities
import ../../platform/platform
import ../../platform/process
import ../../platform/wasm_registry
import ../../platform/store_volume
import ../../platform/memory_volume
import ../../platform/project_store
import ../../platform/web_platform

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  var captured: PlatformOutcome[T]
  var settled = false
  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true
  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true
  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "a facade future never settled"
  captured

const t0: int64 = 1_700_000_000_000

let nargoModule = WasmModule(
  command: "nargo",
  moduleId: WasmModuleId("noir-toolchain@1"),
  displayName: "the Noir toolchain",
  subcommands: @["trace", "compile", "test"],
  builtFrom: "noir@codetracer tooling/tracer_wasm")

let ctPrintModule = WasmModule(
  command: "ct-print",
  moduleId: WasmModuleId("ct-print@1"),
  displayName: "ct-print",
  subcommands: @[],
  builtFrom: "codetracer@dev src/ct")

let populated = WasmRegistry(modules: @[nargoModule, ctPrintModule])

# ---------------------------------------------------------------------------

type
  HostLog = ref object
    ## What the worker was actually asked to do. Assertions read this rather
    ## than trusting an `ok`: a facade whose `run` resolved correctly and then
    ## dispatched the wrong module would satisfy every status check.
    ran: seq[tuple[module: string, command: string, args: seq[string]]]
    started: seq[string]
    terminated: seq[string]

proc fakeWasmHost(registry: WasmRegistry; log: HostLog;
                  exitCode = 0; signalled = false): WasmHost =
  WasmHost(
    registry: registry,
    run: proc(module: WasmModuleId; spec: ProcessSpec): auto =
      log.ran.add ($module, spec.command, spec.args)
      resolvedOk(ProcessRunResult(
        exit: ProcessExit(exitCode: exitCode, signalled: signalled,
                          signalName: (if signalled: "terminate" else: "")),
        stdout: "ran " & spec.command,
        stderr: "")),
    start: proc(module: WasmModuleId; spec: ProcessSpec;
                onOutput: proc(chunk: ProcessOutputChunk);
                onExit: proc(exit: ProcessExit)): auto =
      log.started.add $module
      resolvedOk(ProcessHandle("worker-1")),
    terminate: proc(handle: ProcessHandle): auto =
      log.terminated.add $handle
      resolvedOk(),
    isRunning: proc(handle: ProcessHandle): auto =
      resolvedOk($handle in log.started and $handle notin log.terminated))

proc fakeBridge(volume: StoreVolume; host: WasmHost): BrowserBridge =
  BrowserBridge(
    volume: volume,
    persistenceGranted: true,
    persistenceAnswered: true,
    ownerId: "tab-under-test",
    nowMs: proc(): int64 = t0,
    writeClipboardText: proc(text: string): auto = resolvedOk(),
    writeClipboardHtml: proc(html, plainText: string): auto = resolvedOk(),
    offerDownload: proc(suggestedName: string; content: seq[byte];
                        mimeType: string): auto = resolvedOk(),
    pickFiles: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[seq[string]]("importing files"),
    pickDirectory: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[string]("importing a folder"),
    suggestSaveName: proc(options: SaveDialogOptions): auto =
      resolvedOk(options.suggestedName),
    openExternalUrl: proc(url: string): auto = resolvedOk(),
    setFullscreen: proc(fullscreen: bool): auto = resolvedOk(),
    windowState: proc(): auto =
      resolvedOk(WindowState(maximized: false, minimized: false,
                             fullscreen: false, focused: true)),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard,
    shareLinkOrigin: "",
    wasm: host)

proc bootWith(host: WasmHost): WebPlatform =
  let memory = newMemoryVolume()
  var volume = memory.asVolume
  volume.durable = true
  let bridge = fakeBridge(volume, host)
  let opened = awaitOutcome(openWebStore(bridge))
  doAssert opened.ok, "the fake store did not open: " & $opened.error
  opened.value.acknowledgeDurability()
  newWebPlatform(bridge, opened.value)

# ---------------------------------------------------------------------------

suite "test_a_command_with_no_wasm_build_is_refused_by_name":

  test "the four answers are four, and each names what it is about":
    ## Against broken version (1) — a resolver that collapses "not built" into
    ## "no such command" — the third block below fails on `kind` AND on the
    ## message, because a collapsed answer cannot list what IS available.
    let resolved = populated.resolve("nargo", @["trace"])
    check resolved.kind == wrResolved
    check resolved.module.moduleId == WasmModuleId("noir-toolchain@1")

    let unknown = populated.resolve("docker", @["run"])
    check unknown.kind == wrNoModuleForCommand
    check "docker" in unknown.refusal.message
    check unknown.refusal.kind == pkNotFound

    let notBuilt = populated.resolve("nargo", @["fmt"])
    check notBuilt.kind == wrSubcommandNotBuilt
    check "nargo fmt" in notBuilt.refusal.message
    # The distinguishing payload: only this case can say what you DO have.
    check "trace" in notBuilt.refusal.message
    check "compile" in notBuilt.refusal.message
    check notBuilt.available == @["trace", "compile", "test"]

    # And the two refusals are genuinely different, which is the whole reason
    # the enum has four values rather than two. Compared directly, because two
    # `check`s on separate messages both pass when the messages are identical.
    check notBuilt.refusal.message != unknown.refusal.message
    check notBuilt.refusal.kind != unknown.refusal.kind

  test "a path-qualified command is the project's own file, never our module":
    ## Against broken version (2) — a basename fallback — every check here
    ## fails: `./tools/nargo` resolves, and the studio's wasm module runs in
    ## place of a file the developer wrote. That is not a refused feature, it
    ## is a DIFFERENT PROGRAM running under the name the user typed, and it is
    ## the reason this check runs before the registry is consulted at all.
    for command in ["./tools/nargo", "tools/nargo", "../nargo",
                    "/usr/bin/nargo", ".\\tools\\nargo"]:
      let resolution = populated.resolve(command, @["trace"])
      check resolution.kind == wrPathQualified
      check command in resolution.refusal.message

    # The counter-check, without which the rule above could be "refuse
    # everything" and every assertion would still pass.
    check populated.resolve("nargo", @["trace"]).kind == wrResolved

  test "an empty subcommand list means the whole command, not none of it":
    ## The field's two readings differ by one `.len == 0`, and the wrong one
    ## makes every subcommand-less program permanently unavailable. Both
    ## directions, so the check cannot pass by refusing or by allowing all.
    check populated.resolve("ct-print", @["trace.ct"]).kind == wrResolved
    check populated.resolve("ct-print", @[]).kind == wrResolved
    check populated.resolve("nargo", @["fmt"]).kind == wrSubcommandNotBuilt

  test "the subcommand is the first non-flag argument, not argv[0]":
    ## `nargo --silence-warnings trace` is a trace run. A resolver reading
    ## `args[0]` calls it `--silence-warnings` and refuses a command it can run
    ## perfectly well — green against every happy-path test that passes no
    ## flags.
    check populated.resolve("nargo", @["--silence-warnings", "trace"]).kind ==
      wrResolved
    check populated.resolve("nargo", @["-q", "fmt"]).kind == wrSubcommandNotBuilt
    check populated.resolve("nargo", @["-q", "fmt"]).subcommand == "fmt"
    # `--` ends the search: what follows belongs to the program.
    check populated.resolve("nargo", @["--", "fmt"]).kind == wrResolved
    # Flags only, no subcommand at all: the module's own business.
    check populated.resolve("nargo", @["--version"]).kind == wrResolved

  test "an empty registry is a fact about the build, not about the command":
    ## The empty host is a real platform state — a deployment that ships no
    ## toolchain — not a stub. It answers for every command, and it answers
    ## `pkNotSupported` rather than `pkNotFound`, because that is the kind
    ## `outcome.nim` reserves for an absent capability. Folded into
    ## `wrNoModuleForCommand` (which is how this was first written, and what
    ## `test_platform_web.nim` caught on the JS run) a product that can run
    ## nothing tells the user they typed the wrong thing.
    let empty = noWasmModules().registry
    for command in ["nargo", "git", "docker", "./run.sh"]:
      let resolution = empty.resolve(command)
      check resolution.kind == wrNoModulesLoaded
      check resolution.refusal.kind == pkNotSupported
      check command in resolution.refusal.message

    # And the two are distinguishable, which is the point of separating them:
    # the same command gets a different kind and a different sentence
    # depending on whether the build has modules.
    let unknownInPopulated = populated.resolve("git")
    check unknownInPopulated.refusal.kind == pkNotFound
    check unknownInPopulated.refusal.kind != empty.resolve("git").refusal.kind
    check unknownInPopulated.refusal.message !=
      empty.resolve("git").refusal.message

suite "the web process facade dispatches only what it resolved":

  test "test_the_facade_never_dispatches_an_unresolved_command":
    ## Against broken version (3) — `run` forwarding the spec to the host
    ## unconditionally — `log.ran.len == 0` fails on all three refusals while
    ## the happy path stays green. That is exactly the shape the milestone
    ## warns about: a passing suite over a facade that reintroduced the
    ## mid-run surprise.
    let log = HostLog()
    let web = bootWith(fakeWasmHost(populated, log))
    let facade = web.platform.process

    let unknown = awaitOutcome(facade.run(processSpec("docker", @["run"])))
    check not unknown.ok
    check "docker" in unknown.error.message
    check log.ran.len == 0

    let notBuilt = awaitOutcome(facade.run(processSpec("nargo", @["fmt"])))
    check not notBuilt.ok
    check "nargo fmt" in notBuilt.error.message
    check log.ran.len == 0

    let ownScript = awaitOutcome(facade.run(processSpec("./run.sh")))
    check not ownScript.ok
    check log.ran.len == 0

    # And the resolvable one does reach the host — otherwise "never
    # dispatches" would be satisfied by a facade that dispatches nothing.
    let ok = awaitOutcome(facade.run(processSpec("nargo", @["trace"])))
    check ok.ok
    check log.ran.len == 1
    check log.ran[0].module == "noir-toolchain@1"
    check log.ran[0].args == @["trace"]

    # `start` resolves through the same gate. Asserted separately because
    # `run` and `start` are two fields and a fix applied to one is the most
    # likely way this property comes back half-true.
    proc noOutput(chunk: ProcessOutputChunk) = discard
    proc noExit(exit: ProcessExit) = discard
    let badStart = awaitOutcome(
      facade.start(processSpec("nargo", @["fmt"]), noOutput, noExit))
    check not badStart.ok
    check log.started.len == 0
    let goodStart = awaitOutcome(
      facade.start(processSpec("nargo", @["test"]), noOutput, noExit))
    check goodStart.ok
    check log.started == @["noir-toolchain@1"]

  test "which and run cannot disagree about the same command":
    ## `process.nim` says `which` is "what makes 'this project script has no
    ## wasm build' a nameable outcome rather than a mid-run surprise". That is
    ## only true if asking and doing give the same answer, so both are asked
    ## about the same commands here rather than about a convenient one each.
    let log = HostLog()
    let facade = bootWith(fakeWasmHost(populated, log)).platform.process

    for command in ["nargo", "ct-print", "docker", "./run.sh"]:
      let asked = awaitOutcome(facade.which(command))
      let did = awaitOutcome(facade.run(processSpec(command)))
      check asked.ok == did.ok
      if not asked.ok:
        check asked.error.kind == did.error.kind

    check awaitOutcome(facade.which("nargo")).value == "noir-toolchain@1"

  test "a cancelled run is signalled, and interrupting is refused by name":
    ## `process.nim`'s `ProcessExit.signalled`: "a cancelled run establishes
    ## nothing, and callers that conflate the two report a cancellation as a
    ## failure". The web's stop is `worker.terminate()`, which is why
    ## `capProcessGracefulSignal` is absent — and answering `sigInterrupt` by
    ## terminating anyway would be worse than refusing, since the caller would
    ## believe a cooperative shutdown had been requested.
    let log = HostLog()
    let web = bootWith(fakeWasmHost(populated, log, signalled = true))
    let facade = web.platform.process

    let polite = awaitOutcome(facade.signal(ProcessHandle("worker-1"),
                                            sigInterrupt))
    check not polite.ok
    check polite.error.kind == pkNotSupported
    check log.terminated.len == 0

    let stopped = awaitOutcome(facade.signal(ProcessHandle("worker-1"),
                                             sigTerminate))
    check stopped.ok
    check log.terminated == @["worker-1"]

    # A killed run reports itself as killed rather than as exit status 0.
    let killed = awaitOutcome(facade.run(processSpec("nargo", @["trace"])))
    check killed.ok
    check killed.value.exit.signalled
    check not killed.value.exit.succeededExit

suite "test_the_web_profile_follows_its_module_registry":

  test "no modules means no capProcessSpawn, and the absence explains itself":
    ## Against broken version (4) — a profile that claims `capProcessSpawn`
    ## unconditionally — the first three checks fail. This is the same
    ## correction NS2 made for `capVcsRead`, and it is here because a profile
    ## that promises what the instantiation refuses is the "may I" / "did it
    ## work" disagreement the whole capability model exists to remove.
    let empty = bootWith(noWasmModules())
    check not empty.platform.can(capProcessSpawn)
    check not empty.platform.can(capProcessSignal)
    check empty.platform.degradedBehaviour(capProcessSpawn) == webNoModulesLoaded

    # Both directions, over the profile the instantiation actually installs —
    # a table guarded one way is the shape of check that cannot fail.
    check empty.platform.profile.undeclaredDegradations().len == 0
    check empty.platform.profile.staleDegradations().len == 0

  test "modules present means the capability returns, with no stale sentence":
    ## The counter-check. Without it the narrowing above could be
    ## unconditional and every assertion in this file would still pass.
    let log = HostLog()
    let loaded = bootWith(fakeWasmHost(populated, log))
    check loaded.platform.can(capProcessSpawn)
    check loaded.platform.can(capProcessSignal)
    check loaded.platform.profile.undeclaredDegradations().len == 0
    check loaded.platform.profile.staleDegradations().len == 0

    # What the web still lacks either way. Named one by one: a set comparison
    # passes when both sides are wrong in the same way.
    check not loaded.platform.can(capProcessArbitraryPrograms)
    check not loaded.platform.can(capProcessGracefulSignal)
    check not loaded.platform.can(capProcessInteractiveStdin)
    check not loaded.platform.can(capProcessTerminal)

  test "asking the platform agrees with what the facade then does":
    ## The property `capabilities.nim` exists for, asserted across the seam
    ## rather than within it: `can` and the facade must not disagree.
    let log = HostLog()
    let empty = bootWith(noWasmModules())
    check not empty.platform.can(capProcessSpawn)
    check not awaitOutcome(empty.platform.process.run(
      processSpec("nargo", @["trace"]))).ok

    let loaded = bootWith(fakeWasmHost(populated, log))
    check loaded.platform.can(capProcessSpawn)
    check awaitOutcome(loaded.platform.process.run(
      processSpec("nargo", @["trace"]))).ok

suite "a wasm module can say where it came from":

  test "every registered module names its provenance":
    ## NS0 closed on the finding that the Noir tracer's wasm build was proven
    ## but "not currently reproducible from published refs alone". A module
    ## that cannot say which repository, ref and crate it was built from makes
    ## "what is running in this tab" unanswerable, so the field is required of
    ## every entry rather than recommended.
    for module in populated.modules:
      check module.builtFrom.len > 0
      check module.displayName.len > 0
      check not module.command.isPathQualified()
