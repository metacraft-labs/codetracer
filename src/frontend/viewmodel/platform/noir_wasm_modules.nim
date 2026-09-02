## The Noir toolchain's wasm registry, derived from what a deployment
## ACTUALLY DELIVERED — NS3's residual switch.
##
## ## The one sentence this module exists for
##
## `host/web_browser.nim` supplied `noWasmModules()` as a constant, and its
## comment gave the reason: "the worker script that instantiates the Noir
## modules ... is not in the bundle". **That reason expired at `dev`
## 07926277**, which places the worker script as a required asset and the two
## Noir modules as optional fetched ones. What did not expire is the rule
## underneath it: declaring `nargo` over modules that were never placed would
## restore `capProcessSpawn` on a profile whose every run fails, which is the
## exact thing `wasm_registry.nim` exists to prevent.
##
## So the registry stops being a constant and becomes a **function of the
## delivery**. Empty is still the answer when nothing was delivered — but it is
## now a derived answer that would change if the modules appeared, rather than
## a literal that would not.
##
## ## Declaration is not delivery, and the two wasm modules are INDEPENDENT
##
## `webRuntimeAssets()` marks both Noir modules `required: false`, each with
## its own `absenceBehaviour`. That is not hedging — a deployment really can
## ship one and not the other, and the manifest already says what each absence
## costs. The registry has to honour that, because the worker routes **by
## subcommand**:
##
##   `wasm_worker_browser.js`   `compile` -> `compileVfs`  -> loads `noir-compiler`
##                              `trace`   -> `traceArtifact` -> loads `noir-tracer`
##
## A deployment carrying only the compiler can therefore run `nargo compile`
## and cannot run `nargo trace`. Declaring both would produce a run that dies
## inside the worker with "no url declared for wasm module"; declaring neither
## would refuse a `compile` that works. Both are the confident-answer-that-is-
## sometimes-wrong shape, one in each direction.
##
## The five-answer model in `wasm_registry.nim` already has the right slot for
## this and needs no sixth: a partial delivery is case (3),
## `wrSubcommandNotBuilt` — "a module is registered but was not built with this
## subcommand" — which is the case that "can usefully list what *is*
## available". So a compiler-only tab answers `nargo trace` with *"`nargo
## trace` is not part of the Noir toolchain wasm build. It provides:
## compile."* rather than with a blanket failure.
##
## ## Why provenance is a precondition of being registered at all
##
## `WasmModule.builtFrom` is not decoration, and its own comment says why: NS0
## closed on the finding that the Noir tracer's wasm build was proven but "not
## currently reproducible from published refs alone", which would make "what is
## actually running in this tab" unanswerable. It ends "a module that cannot
## say where it came from should not be in a registry a product ships."
##
## This module takes that literally: a delivered module with no provenance is
## **not registered**, and `modulesWithoutProvenance` names it. Dropping it
## silently would be worse than registering it, so the drop is always
## reportable — but registering an artefact we cannot identify would put
## `capProcessSpawn` on a tab running code of unknown origin, which is the
## worse of the two failures and the one a user cannot detect.
##
## ## Pure, and on both backends
##
## No browser, no worker, no `when defined(js)` — the same discipline
## `wasm_registry.nim` states in its own header, and for the same reason: the
## host-free gate type-checks it on C and `vm-unit-js` runs it on the backend
## the renderer ships on.

import ./wasm_registry
import ./web_deployment

export wasm_registry

type
  DeliveredWasmModule* = object
    ## One wasm module a deployment actually placed, as reported by whatever
    ## checked. `id` is a `webRuntimeAssets()` asset id, so this cannot drift
    ## from the manifest without `unknownDeliveredModules` saying so.
    id*: string
    builtFrom*: string
      ## Which repository, which published ref, which crate. See the header:
      ## empty means the module is not registered.

const
  noirToolchainCommand* = "nargo"
    ## The bare program name a project's scripts already write. Matching
    ## `noir_nargo.nim`'s provider, and the same string the Noir LSP's code
    ## lens uses, so the editor, the CLI and the tab cannot disagree.

  noirToolchainModuleId* = "noir-toolchain"
    ## Opaque at this layer, per `WasmModuleId`'s contract. Deliberately NOT
    ## one of the two asset ids: the worker selects its wasm module from the
    ## SUBCOMMAND, so a registry entry naming one file would be a claim about
    ## routing that is not true. This id identifies the toolchain, which is
    ## what `which nargo` is asking about.

  noirToolchainDisplayName* = "the Noir toolchain"
    ## For the refusal sentence, per `displayName`'s contract: a name a user
    ## recognises, not `noir_tracer_wasm.wasm`.

  compileSubcommand* = "compile"
  traceSubcommand* = "trace"

  transpilerCommand* = "avm-transpiler"
    ## The bare program name `aztec-nargo` invokes after `nargo compile`, and
    ## the name of upstream's own binary. NOT a `nargo` subcommand: there is no
    ## `nargo transpile` on any desktop, and inventing one here would make the
    ## tab disagree with every script a user already has — the exact drift
    ## `noirToolchainCommand`'s comment exists to prevent, one tool over.

  transpilerModuleId* = "avm-transpiler-toolchain"
    ## Opaque at this layer, and deliberately not the asset id, for the reason
    ## `noirToolchainModuleId` gives: this identifies the TOOL, which is what
    ## `which avm-transpiler` is asking about, while the asset id names a file.

  transpilerDisplayName* = "the Aztec AVM transpiler"

  transpileSubcommand* = "transpile"

proc subcommandForAsset*(assetId: string): string =
  ## Which subcommand each fetched module makes possible, and the empty string
  ## for an asset that enables none.
  ##
  ## This is the whole delivery-to-capability mapping, in one place, so the
  ## worker's routing and the registry's claim have a single point of
  ## agreement. `test_noir_wasm_delivery` pins both directions.
  if assetId == noirCompilerModuleId: compileSubcommand
  elif assetId == noirTracerModuleId: traceSubcommand
  elif assetId == avmTranspilerModuleId: transpileSubcommand
  else: ""

proc commandForAsset*(assetId: string): string =
  ## Which COMMAND the subcommand above belongs to.
  ##
  ## Split from `subcommandForAsset` rather than folded into it because a
  ## subcommand alone cannot say which tool runs it, and the registry's whole
  ## job is to answer `which <command>`. While every module belonged to `nargo`
  ## this was invisible; the moment a second tool arrived, a delivery that
  ## enabled `transpile` would otherwise have declared `nargo transpile` — a
  ## command that exists nowhere else, presented to the user as if it did.
  if assetId == noirCompilerModuleId or assetId == noirTracerModuleId:
    noirToolchainCommand
  elif assetId == avmTranspilerModuleId:
    transpilerCommand
  else: ""

proc registeredCommands*(): seq[string] =
  ## Every command a delivery could declare, in manifest order and without
  ## repeats. Derived from the manifest for the same reason
  ## `deliverableModuleIds` is: a second list is a thing that can disagree.
  for asset in fetchedRuntimeAssets():
    let command = commandForAsset(asset.id)
    if command.len > 0 and command notin result:
      result.add command

proc deliverableModuleIds*(): seq[string] =
  ## The asset ids a deployment MAY deliver, read from the manifest rather
  ## than restated — `web_deployment.nim`'s header makes this argument for
  ## `rewritePrefixes` and the assembly step makes it again.
  ##
  ## `noirWasmModuleAssets()` and NOT `fetchedRuntimeAssets()`. This registry
  ## resolves bare-ABI `nv_*` / `ct_*` modules and its whole output is a
  ## `nargo` claim; the replay engine is fetched for the same delivery reasons
  ## and is a wasm-bindgen module driven from its own worker, so a list keyed
  ## on "fetched" would have made the page declare `nargo` over it and
  ## `subcommandForAsset` answer the empty string for a module the registry
  ## had already counted.
  for asset in noirWasmModuleAssets():
    result.add asset.id

proc unknownDeliveredModules*(delivered: seq[DeliveredWasmModule]): seq[string] =
  ## Delivered ids the manifest does not declare. A typo here would otherwise
  ## present as "no modules were delivered", which is a true-looking sentence
  ## about a deployment that placed the files.
  let known = deliverableModuleIds()
  for module in delivered:
    if module.id notin known:
      result.add module.id

proc modulesWithoutProvenance*(delivered: seq[DeliveredWasmModule]): seq[string] =
  ## Delivered modules that cannot say where they came from. These are NOT
  ## registered — see the header — so this is the list that explains why a
  ## capability a deployment expected is missing.
  for module in delivered:
    if module.id in deliverableModuleIds() and module.builtFrom.len == 0:
      result.add module.id

proc registrableModules*(delivered: seq[DeliveredWasmModule]):
    seq[DeliveredWasmModule] =
  ## Delivered, declared by the manifest, and able to say where it came from.
  let known = deliverableModuleIds()
  for module in delivered:
    if module.id in known and module.builtFrom.len > 0:
      result.add module

proc deliveredSubcommands*(delivered: seq[DeliveredWasmModule],
                           command: string = noirToolchainCommand): seq[string] =
  ## The subcommands this delivery can actually run FOR ONE COMMAND, in
  ## manifest order so the refusal sentence's "It provides: ..." list is stable
  ## rather than dependent on the order a probe happened to report.
  ##
  ## `command` defaults to the Noir toolchain because that is what every
  ## existing caller means; it became a parameter when a second tool arrived,
  ## rather than the union it used to return, because a union would tell
  ## `avm-transpiler` it provides `compile`.
  let registrable = registrableModules(delivered)
  for asset in noirWasmModuleAssets():
    if commandForAsset(asset.id) != command: continue
    for module in registrable:
      if module.id == asset.id:
        let sub = subcommandForAsset(asset.id)
        if sub.len > 0 and sub notin result:
          result.add sub

proc deliveredProvenance*(delivered: seq[DeliveredWasmModule],
                          command: string = noirToolchainCommand): string =
  ## One command's registrable modules' provenance, in manifest order. One
  ## `nargo` entry stands for up to two artefacts, so it has to name both — a
  ## `builtFrom` that mentioned only the compiler would make the tracer's
  ## origin unanswerable while looking answered.
  let registrable = registrableModules(delivered)
  for asset in noirWasmModuleAssets():
    if commandForAsset(asset.id) != command: continue
    for module in registrable:
      if module.id == asset.id:
        if result.len > 0: result.add "; "
        result.add asset.id & ": " & module.builtFrom

proc noirWasmRegistry*(delivered: seq[DeliveredWasmModule]): WasmRegistry =
  ## The registry for a deployment that delivered `delivered`.
  ##
  ## An empty delivery produces an EMPTY registry, which `resolve` answers
  ## `wrNoModulesLoaded` for every command — case (0), a fact about the
  ## deployment rather than about the command, and the one case in which
  ## `capProcessSpawn` is correctly absent. That is the same answer the old
  ## `noWasmModules()` constant gave, reached by asking instead of by
  ## asserting.
  ## ONE ENTRY PER COMMAND, and only for commands this delivery can actually
  ## run. A deployment that placed the two Noir modules and no transpiler
  ## declares `nargo` and does not declare `avm-transpiler` — so `which
  ## avm-transpiler` answers case (0)'s "no module" rather than case (3)'s
  ## "registered, but not built with that subcommand", and those are different
  ## sentences about different deployments.
  for command in registeredCommands():
    let subcommands = deliveredSubcommands(delivered, command)
    if subcommands.len == 0: continue
    result.modules.add WasmModule(
      command: command,
      moduleId: WasmModuleId(
        if command == transpilerCommand: transpilerModuleId
        else: noirToolchainModuleId),
      displayName:
        if command == transpilerCommand: transpilerDisplayName
        else: noirToolchainDisplayName,
      subcommands: subcommands,
      builtFrom: deliveredProvenance(delivered, command))

proc deliveryDefects*(delivered: seq[DeliveredWasmModule]): seq[string] =
  ## Everything wrong with a delivery, as sentences. Empty is the assertion a
  ## deployment gate makes; the same shape as `undeclaredAbsences()`.
  for id in unknownDeliveredModules(delivered):
    result.add "delivered module `" & id &
      "` is not declared by the runtime asset manifest"
  for id in modulesWithoutProvenance(delivered):
    result.add "delivered module `" & id &
      "` does not say where it was built from, so it is not registered"
