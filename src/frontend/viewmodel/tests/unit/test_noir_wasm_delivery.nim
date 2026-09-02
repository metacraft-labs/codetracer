## Headless tests for the delivery-derived Noir wasm registry — NS3's switch.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob. The subject is
## pure — no browser, no worker, no `when defined(js)` — which is what
## `wasm_registry.nim`'s header asks of this layer and what lets the backend
## the renderer ships on run all of it.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_noir_wasm_delivery.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_noir_wasm_delivery.nim
##
## ## What this suite is for
##
## `newBrowserBridge` supplied `noWasmModules()` as a CONSTANT. The bundle now
## carries the worker script, so the reason that constant gave has expired —
## but the rule underneath it has not: declaring `nargo` over modules that were
## never placed restores `capProcessSpawn` on a profile whose every run fails.
##
## So every case below asserts a property of the DELIVERY, never of the
## declaration. The sharpest is the partial one: a deployment carrying the
## compiler and not the tracer must run `nargo compile` and must refuse
## `nargo trace` BY NAME, because both "declare both" and "declare neither" are
## confident answers that are wrong in one direction each.

import std/[strutils, unittest]

import ../../platform/noir_wasm_modules
import ../../platform/outcome
import ../../platform/web_deployment

# ---------------------------------------------------------------------------
# Counted assertions. `counted` is a TEMPLATE so that `check` is inlined into
# the `test` body where `testStatusIMPL` is in scope — inside a proc every
# check would print and still report [OK]. Same reasoning as
# `noir_providers_test.nim` and `test_generated_code_anchors.nim`.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 113
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  CompilerProvenance = "noir@codetracer 61960c8eec compiler/wasm"
  TracerProvenance = "noir@codetracer 61960c8eec tooling/tracer_wasm"

proc compilerOnly(): seq[DeliveredWasmModule] =
  @[DeliveredWasmModule(
    id: noirCompilerModuleId, builtFrom: CompilerProvenance)]

proc tracerOnly(): seq[DeliveredWasmModule] =
  @[DeliveredWasmModule(id: noirTracerModuleId, builtFrom: TracerProvenance)]

proc bothModules(): seq[DeliveredWasmModule] =
  compilerOnly() & tracerOnly()

const TranspilerProvenance =
  "aztec-avm-runtime@browser/vendor-aztec-nr f3e00ce avm-transpiler-wasm"
  ## Which repository, which published ref, which crate — the same three facts
  ## the two Noir strings above carry. The transpiler shim wraps upstream's
  ## `avm_transpile_bytecode` from `aztec-packages@233d8e0993`, and the ref
  ## named here is the one that carries the shim.

proc transpilerOnly(): seq[DeliveredWasmModule] =
  @[DeliveredWasmModule(
    id: avmTranspilerModuleId, builtFrom: TranspilerProvenance)]

proc full3(): seq[DeliveredWasmModule] =
  bothModules() & transpilerOnly()

suite "the Noir wasm registry follows the delivery (NS3)":

  test "an empty delivery is an EMPTY registry, not a declared toolchain":
    # Case (0) of `wasm_registry.nim`'s five: a fact about the deployment, not
    # about the command. This is the answer the old `noWasmModules()` constant
    # gave — reached by asking rather than by asserting, which is the whole
    # change.
    let registry = noirWasmRegistry(@[])
    counted registry.modules.len == 0

    let resolution = registry.resolve(noirToolchainCommand, @["compile"])
    counted resolution.kind == wrNoModulesLoaded
    # `pkNotSupported`, not `pkNotFound`: the capability is absent, and
    # "you typed the wrong thing" would be the wrong sentence for a build that
    # can run nothing at all.
    counted resolution.refusal().kind == pkNotSupported
    counted noirToolchainCommand in resolution.refusal().message

    # CONTROL ARM: the same call over a full delivery resolves. Without it this
    # case would pass for a function that returned an empty registry always.
    counted noirWasmRegistry(bothModules()).modules.len == 1
    counted noirWasmRegistry(bothModules()).resolve(
      noirToolchainCommand, @["compile"]).kind == wrResolved

  test "a full delivery declares exactly the two subcommands the worker routes":
    # `wasm_worker_browser.js` routes `compile` -> `compileVfs` and `trace` ->
    # `traceArtifact`, and nothing else. Declaring a third would produce a run
    # that reaches the worker and dies there.
    let registry = noirWasmRegistry(bothModules())
    counted registry.modules.len == 1

    let module = registry.modules[0]
    counted module.command == noirToolchainCommand
    counted module.subcommands == @[compileSubcommand, traceSubcommand]
    counted module.subcommands.len == 2
    counted "test" notin module.subcommands
    counted "fmt" notin module.subcommands

    # Manifest order, so the refusal sentence's "It provides:" list is stable
    # rather than dependent on the order a probe reported.
    counted deliveredSubcommands(bothModules()) ==
      @[compileSubcommand, traceSubcommand]
    counted deliveredSubcommands(tracerOnly() & compilerOnly()) ==
      @[compileSubcommand, traceSubcommand]

    # Both resolve; an unbuilt one does not.
    counted registry.resolve(noirToolchainCommand, @["compile"]).kind ==
      wrResolved
    counted registry.resolve(noirToolchainCommand, @["trace"]).kind ==
      wrResolved
    counted registry.resolve(noirToolchainCommand, @["fmt"]).kind ==
      wrSubcommandNotBuilt

  test "a compiler_only delivery runs compile and refuses trace BY NAME":
    # THE CASE THIS MODULE EXISTS FOR. Both wasm modules are `required: false`
    # with their own `absenceBehaviour`, so a one-module deployment is a real
    # configuration. "Declare both" would die inside the worker; "declare
    # neither" would refuse a `compile` that works. Case (3) is the slot that
    # already fits, and it is the only one that can list what IS available.
    let registry = noirWasmRegistry(compilerOnly())
    counted registry.modules.len == 1
    counted registry.modules[0].subcommands == @[compileSubcommand]

    counted registry.resolve(noirToolchainCommand, @["compile"]).kind ==
      wrResolved

    let refused = registry.resolve(noirToolchainCommand, @["trace"])
    counted refused.kind == wrSubcommandNotBuilt
    counted refused.available == @[compileSubcommand]
    let error = refused.refusal()
    counted error.kind == pkNotSupported
    # "reported as unavailable BY NAME, with the command shown" — the promise
    # `capabilities.webProfile` makes and the thing a generic
    # "not available on this platform" would break while satisfying every type.
    counted noirToolchainCommand in error.message
    counted traceSubcommand in error.message
    counted compileSubcommand in error.message
    # The display name must be a name a USER recognises, per `displayName`'s
    # contract. Asserting `noirToolchainDisplayName in error.message` alone
    # would be a tautology — an empty constant is `in` every string — so the
    # non-emptiness and the literal word are asserted too. A mutation emptying
    # the constant survived exactly that weaker form.
    counted noirToolchainDisplayName.len > 0
    counted noirToolchainDisplayName in error.message
    counted "Noir" in error.message

    # CONTROL ARM: the mirror delivery. `trace` runs and `compile` is the one
    # refused — so the asymmetry above is about which module was delivered and
    # not about `trace` being special.
    let mirror = noirWasmRegistry(tracerOnly())
    counted mirror.modules[0].subcommands == @[traceSubcommand]
    counted mirror.resolve(noirToolchainCommand, @["trace"]).kind == wrResolved
    let mirrorRefused = mirror.resolve(noirToolchainCommand, @["compile"])
    counted mirrorRefused.kind == wrSubcommandNotBuilt
    counted mirrorRefused.available == @[traceSubcommand]
    counted compileSubcommand in mirrorRefused.refusal().message

  test "a module that cannot say where it came from is not registered":
    # `WasmModule.builtFrom`'s own comment: "a module that cannot say where it
    # came from should not be in a registry a product ships." NS0 closed on
    # exactly this — a wasm build that was proven but not reproducible from
    # published refs, which makes "what is running in this tab" unanswerable.
    let anonymous = @[
      DeliveredWasmModule(id: noirCompilerModuleId, builtFrom: ""),
      DeliveredWasmModule(id: noirTracerModuleId, builtFrom: TracerProvenance)]

    counted modulesWithoutProvenance(anonymous) == @[noirCompilerModuleId]
    # Not registered: the delivery carried two files and the registry offers
    # one subcommand.
    let registry = noirWasmRegistry(anonymous)
    counted registry.modules[0].subcommands == @[traceSubcommand]
    counted compileSubcommand notin registry.modules[0].subcommands

    # And the drop is REPORTABLE rather than silent — that is what makes
    # refusing it better than registering it.
    let defects = deliveryDefects(anonymous)
    counted defects.len == 1
    counted noirCompilerModuleId in defects[0]
    counted "where it was built from" in defects[0]

    # Every registered module names its provenance, and one entry standing for
    # two artefacts must name BOTH — a `builtFrom` mentioning only the
    # compiler would make the tracer's origin unanswerable while looking
    # answered.
    let full = noirWasmRegistry(bothModules())
    counted full.modules[0].builtFrom.len > 0
    counted CompilerProvenance in full.modules[0].builtFrom
    counted TracerProvenance in full.modules[0].builtFrom

    # CONTROL ARM: the same two ids WITH provenance produce no defects and two
    # subcommands.
    counted deliveryDefects(bothModules()).len == 0
    counted modulesWithoutProvenance(bothModules()).len == 0
    counted noirWasmRegistry(bothModules()).modules[0].subcommands.len == 2

  test "a delivered id the manifest does not declare is named, not ignored":
    # A typo would otherwise present as "no modules were delivered", which is
    # a true-LOOKING sentence about a deployment that placed the files.
    let typo = @[
      DeliveredWasmModule(id: "noir-tracer-v2", builtFrom: TracerProvenance)]
    counted unknownDeliveredModules(typo) == @["noir-tracer-v2"]
    counted noirWasmRegistry(typo).modules.len == 0
    # `registrableModules` is asserted directly rather than only through the
    # registry: an id the manifest does not declare also fails to match any
    # fetched asset downstream, so the registry would come out empty even if
    # this filter were removed. A mutation dropping it survived until this
    # check named the contract it belongs to.
    counted registrableModules(typo).len == 0
    counted registrableModules(typo & bothModules()).len == 2

    let defects = deliveryDefects(typo)
    counted defects.len == 1
    counted "noir-tracer-v2" in defects[0]
    counted "not declared by the runtime asset manifest" in defects[0]

    # CONTROL ARM: the correct id, everything else identical.
    counted unknownDeliveredModules(tracerOnly()).len == 0
    counted noirWasmRegistry(tracerOnly()).modules.len == 1

  test "the deliverable ids come from the manifest, not from a second list":
    # `web_deployment.nim`'s header makes this argument for `rewritePrefixes`
    # and the assembly step makes it again: a hand-written copy cannot be made
    # to agree with the product.
    let ids = deliverableModuleIds()
    counted ids.len == 3
    counted noirCompilerModuleId in ids
    counted noirTracerModuleId in ids
    counted avmTranspilerModuleId in ids

    # Derived, not restated: the deliverable list IS the manifest's
    # `fcNoirWasmWorker` rows, and no bundled or asset-mode one.
    var noirIds: seq[string]
    for asset in noirWasmModuleAssets(): noirIds.add asset.id
    counted ids == noirIds
    counted "renderer" notin ids
    counted "wasm-worker" notin ids

    # AND NOT EVERY FETCHED ASSET. This used to be `ids == fetchedIds` and it
    # was true only while `damFetched` had exactly two members, both Noir
    # modules. The replay engine is fetched for the same delivery reasons and
    # is not a Noir module: it has no `nv_*` / `ct_*` ABI, `subcommandForAsset`
    # answers the empty string for it, and a registry that counted it would
    # make the page claim `nargo` over a wasm-bindgen debugger.
    var fetchedIds: seq[string]
    for asset in fetchedRuntimeAssets(): fetchedIds.add asset.id
    counted fetchedIds.len > ids.len
    counted replayEngineModuleId in fetchedIds
    counted replayEngineModuleId notin ids
    counted replayEngineGlueId notin ids

    # The mapping is total over the manifest and empty off it.
    counted subcommandForAsset(noirCompilerModuleId) == compileSubcommand
    counted subcommandForAsset(noirTracerModuleId) == traceSubcommand
    counted subcommandForAsset(avmTranspilerModuleId) == transpileSubcommand
    counted subcommandForAsset("renderer") == ""
    counted subcommandForAsset("wasm-worker") == ""
    for id in ids:
      counted subcommandForAsset(id).len > 0

    # And so is the COMMAND mapping, which is the half that keeps a subcommand
    # attributed to the tool that actually runs it.
    counted commandForAsset(noirCompilerModuleId) == noirToolchainCommand
    counted commandForAsset(noirTracerModuleId) == noirToolchainCommand
    counted commandForAsset(avmTranspilerModuleId) == transpilerCommand
    counted commandForAsset("renderer") == ""
    for id in ids:
      counted commandForAsset(id).len > 0
    counted registeredCommands() == @[noirToolchainCommand, transpilerCommand]

  test "a project's own nargo is never served the studio's module":
    # Case (1), and it must hold whatever was delivered: a project holding
    # `./tools/nargo` means ITS nargo, and running the studio's wasm module
    # instead would execute different code than the same command does on the
    # developer's desktop.
    let registry = noirWasmRegistry(bothModules())
    for command in ["./tools/nargo", "../bin/nargo", ".nargo"]:
      let resolution = registry.resolve(command, @["compile"])
      counted resolution.kind == wrPathQualified
      counted resolution.refusal().kind == pkNotSupported
      counted command in resolution.refusal().message

    # Case (2): a command with no module at all, over a NON-empty registry —
    # distinct from case (0) above.
    let unknown = registry.resolve("docker", @["run"])
    counted unknown.kind == wrNoModuleForCommand
    counted unknown.refusal().kind == pkNotFound

    # CONTROL ARM: the bare name resolves over the same registry, so the
    # refusals above are about the command's shape and not about the registry
    # refusing everything.
    counted registry.resolve(noirToolchainCommand, @["compile"]).kind ==
      wrResolved
    counted registry.describes(noirToolchainCommand) == noirToolchainModuleId

    # And the id must NOT name one of the two wasm files. The worker selects
    # its module from the SUBCOMMAND, so an entry naming `noir-compiler` would
    # be a claim about routing that is not true — and `which nargo` would
    # answer with a file that serves half the command. Comparing
    # `describes(...)` against the constant cannot see this, because a
    # mutation moves both sides; this asserts the property instead.
    counted noirToolchainModuleId notin deliverableModuleIds()
    counted noirToolchainModuleId != noirCompilerModuleId
    counted noirToolchainModuleId != noirTracerModuleId

  test "the transpiler is its OWN command, and a Noir-only delivery declares none":
    # The join this case exists for: a contract compiled in the tab is handed
    # to the transpiler in the tab. That needs a THIRD module, and it is not a
    # `nargo` subcommand — there is no `nargo transpile` on any desktop, and
    # declaring one would make the tab disagree with every script a user has.

    # A delivery with only the Noir modules declares `nargo` and NOT the
    # transpiler. This is the arm that fails if `registeredCommands` ever
    # declares a command whose module was not delivered.
    let noirOnly = noirWasmRegistry(bothModules())
    counted noirOnly.modules.len == 1
    counted noirOnly.resolve(transpilerCommand, @[transpileSubcommand]).kind ==
      wrNoModuleForCommand
    counted transpileSubcommand notin noirOnly.modules[0].subcommands

    # With the transpiler delivered there are TWO modules, each naming its own
    # command, and `nargo` has not grown a subcommand.
    let full = noirWasmRegistry(full3())
    counted full.modules.len == 2
    counted full.describes(noirToolchainCommand) == noirToolchainModuleId
    counted full.describes(transpilerCommand) == transpilerModuleId
    counted full.resolve(transpilerCommand, @[transpileSubcommand]).kind ==
      wrResolved
    counted full.resolve(noirToolchainCommand, @["compile"]).kind == wrResolved
    counted deliveredSubcommands(full3(), noirToolchainCommand) ==
      @[compileSubcommand, traceSubcommand]
    counted deliveredSubcommands(full3(), transpilerCommand) ==
      @[transpileSubcommand]

    # Provenance is per command, so the transpiler cannot borrow the compiler's.
    counted deliveredProvenance(full3(), transpilerCommand) ==
      avmTranspilerModuleId & ": " & TranspilerProvenance
    counted CompilerProvenance notin
      deliveredProvenance(full3(), transpilerCommand)

    # The transpiler ALONE: `avm-transpiler` resolves, `nargo` does not. The
    # mirror of the first arm, and it is what shows the two commands are
    # independent rather than one being a side effect of the other.
    let transpilerAlone = noirWasmRegistry(transpilerOnly())
    counted transpilerAlone.modules.len == 1
    counted transpilerAlone.modules[0].command == transpilerCommand
    counted transpilerAlone.resolve(noirToolchainCommand, @["compile"]).kind ==
      wrNoModuleForCommand

  test "noir_wasm_delivery_assertion_count_is_measured":
    # The count is asserted so that deleting or short-circuiting a check above
    # cannot pass silently: it has to move this number in the same commit.
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
