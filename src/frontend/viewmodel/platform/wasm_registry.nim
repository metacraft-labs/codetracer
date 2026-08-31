## The wasm module registry the web instantiation runs commands through —
## NS3, Noir-Studio.md §3.1's web column for process execution: "wasm modules
## in the tab".
##
## ## Why this module exists rather than a `when defined(js)` in `process.nim`
##
## `platform/process.nim` already says what it is for:
##
##   "`which` — where the platform would find `program`, or `pkNotFound`. The
##   web instantiation answers from its wasm module registry, which is what
##   makes 'this project script has no wasm build' a nameable outcome rather
##   than a mid-run surprise."
##
## and `capabilities.webProfile` already carries the sentence a user reads:
##
##   "declared commands run as wasm modules in a worker; a project script with
##   no wasm build is reported as unavailable by name, with the command shown,
##   rather than failing silently mid-run"
##
## Both were written in NS1/NS2 against a `ProcessFacade` that refused
## everything. This module is the registry those two sentences describe, and
## it is deliberately **pure data plus resolution** — no browser, no worker, no
## `when defined(js)` — so the host-free gate type-checks all of it on the C
## backend and `vm-unit-js` runs all of it on the backend the renderer ships.
## The worker itself is `WasmHost`, four procs a host module fills in.
##
## ## The distinction that is the whole point: five answers, not two
##
## A run that cannot happen has four different causes here, and they are four
## different things to tell a user:
##
## 0. **This build ships no modules at all.** Not a fact about the command —
##    a fact about the deployment, and the one case in which the *capability*
##    `capProcessSpawn` is absent rather than a particular command being
##    unavailable. `outcome.nim` reserves `pkNotSupported` for exactly that
##    ("the capability is absent on this platform... this is the backstop"),
##    so this case answers `pkNotSupported` while the three below answer about
##    a command. Splitting it out was not a refinement: with it folded in, a
##    web platform correctly declaring no `capProcessSpawn` refused runs with
##    `pkNotFound`, which reads as "you typed the wrong thing" for a product
##    that cannot run anything at all.
## 1. **The command is path-qualified** — `./scripts/deploy.sh`, `../bin/x`.
##    That is the user's own file, not a toolchain program, and a tab has no
##    interpreter for it. Critically it must NOT resolve by basename: a project
##    holding `./tools/nargo` means *its* nargo, and running the studio's wasm
##    module instead would execute different code than the same command does on
##    the developer's desktop. That is the "types line up, behaviour is wrong"
##    shape, so it is the first case checked and it has its own test.
## 2. **No module is registered for the command at all** — `docker`, `python`.
## 3. **A module is registered but was not built with this subcommand** —
##    `nargo fmt` where the module implements `trace` and `compile`. This is
##    the case a naive implementation collapses into (2), and collapsing them
##    is a real loss: (2) says "this will never work here", (3) says "this part
##    of a tool you have is missing", and only (3) can usefully list what *is*
##    available.
## 4. Nothing is wrong and the module runs.
##
## `resolve` returns which of the four it is; `refusal` turns the first three
## into a `PlatformError` whose message names the command — the property
## §3.1's degradation sentence promises and the one
## `test_platform_wasm_modules.nim` pins.

import std/strutils

import ./outcome
import ./process

export process

type
  WasmModuleId* = distinct string
    ## Opaque to this layer, exactly like `ProcessHandle`. The host decides
    ## whether it names a URL, a cache key or an already-instantiated module;
    ## nothing here may look inside it.

  WasmModule* = object
    command*: string
      ## The bare program name a project's scripts already write — `nargo`,
      ## not a path and not a URL. A command carrying a path separator never
      ## matches one of these; see `resolve`.
    moduleId*: WasmModuleId
    displayName*: string
      ## For the refusal sentence and the status bar: "the Noir toolchain",
      ## not `noir_tracer_wasm.wasm`.
    subcommands*: seq[string]
      ## Which subcommands this build actually implements. **Empty means the
      ## module implements the whole command**, not "none of them" — a module
      ## for a program that has no subcommands (`ct-print`) would otherwise be
      ## unexpressible. The two readings differ by exactly one `.len == 0`, so
      ## `resolve` states which it takes and the suite pins both.
    builtFrom*: string
      ## Provenance: which repository, which published ref and which crate the
      ## module was built from.
      ##
      ## Not decoration. NS0 closed on the finding that the Noir tracer's wasm
      ## build was proven but "not currently reproducible from published refs
      ## alone", which would have made "what is actually running in this tab"
      ## unanswerable. A module that cannot say where it came from should not
      ## be in a registry a product ships.

  WasmRegistry* = object
    modules*: seq[WasmModule]

  WasmResolutionKind* = enum
    wrResolved
    wrNoModulesLoaded
      ## Case (0): a fact about the deployment, not about the command.
    wrPathQualified
      ## Case (1): the command names a file in the project, not a program.
    wrNoModuleForCommand
      ## Case (2).
    wrSubcommandNotBuilt
      ## Case (3).

  WasmResolution* = object
    kind*: WasmResolutionKind
    module*: WasmModule
      ## Meaningful for `wrResolved` and `wrSubcommandNotBuilt` — in the latter
      ## the command IS ours, which is why its subcommand list can be offered.
    command*: string
    subcommand*: string
    available*: seq[string]
      ## What the registered module does implement. Empty for every kind but
      ## `wrSubcommandNotBuilt`.

  WasmHost* {.requiresInit.} = ref object
    ## The worker half. `{.requiresInit.}` for the reason every facade carries
    ## it: an operation added here must fail the build at each host and each
    ## test that builds one, rather than defaulting to `nil` and crashing in a
    ## user's tab.
    ##
    ## Deliberately four operations and no more. There is no "load", no
    ## "preload" and no "unload": whether a module is fetched on first use or
    ## with the bundle is the host's business, and a caller that could ask
    ## would start depending on the answer.
    registry*: WasmRegistry

    run*: proc(module: WasmModuleId; spec: ProcessSpec
              ): PlatformFuture[PlatformOutcome[ProcessRunResult]]

    start*: proc(module: WasmModuleId; spec: ProcessSpec;
                 onOutput: proc(chunk: ProcessOutputChunk);
                 onExit: proc(exit: ProcessExit)
                ): PlatformFuture[PlatformOutcome[ProcessHandle]]

    terminate*: proc(handle: ProcessHandle
                    ): PlatformFuture[PlatformOutcome[Nothing]]
      ## Abrupt and complete — `worker.terminate()`. There is no cooperative
      ## stop, which is why the web profile lacks `capProcessGracefulSignal`
      ## and says so in a sentence.

    isRunning*: proc(handle: ProcessHandle
                    ): PlatformFuture[PlatformOutcome[bool]]

proc `==`*(a, b: WasmModuleId): bool {.borrow.}
proc `$`*(id: WasmModuleId): string {.borrow.}

const pathSeparators = {'/', '\\'}

proc isPathQualified*(command: string): bool =
  ## A command the platform must not resolve against its registry. Any
  ## separator makes it a path, and so does a leading `.` — `.` and `..` are
  ## path components even before a separator appears.
  for ch in command:
    if ch in pathSeparators: return true
  command.startsWith(".")

proc subcommandOf*(args: seq[string]): string =
  ## The first argument that is not a flag. `nargo --silence-warnings trace`
  ## is a `trace` run, and a resolver that read `args[0]` would call it
  ## `--silence-warnings` and refuse a command it can perfectly well run.
  ##
  ## `--` ends the search: everything after it is the program's own argument,
  ## never a subcommand.
  for arg in args:
    if arg == "--": return ""
    if arg.len > 0 and arg[0] == '-': continue
    return arg
  ""

proc find*(registry: WasmRegistry; command: string): int =
  ## The index of the module for `command`, or -1. Exact match on the bare
  ## name; see `isPathQualified` for why there is no basename fallback.
  for i in 0 ..< registry.modules.len:
    if registry.modules[i].command == command:
      return i
  -1

proc resolve*(registry: WasmRegistry; command: string;
              args: seq[string] = @[]): WasmResolution =
  ## Which of the five answers this command gets. Order matters twice over:
  ## the empty-registry check runs before anything, because "this build runs
  ## nothing" is true of every command and is a different sentence from any of
  ## the others; and the path-qualified check runs before the lookup, so a
  ## project that ships its own `./tools/nargo` is never silently served the
  ## studio's module.
  if registry.modules.len == 0:
    return WasmResolution(kind: wrNoModulesLoaded, command: command)

  if isPathQualified(command):
    return WasmResolution(kind: wrPathQualified, command: command)

  let index = registry.find(command)
  if index < 0:
    return WasmResolution(kind: wrNoModuleForCommand, command: command)

  let module = registry.modules[index]
  if module.subcommands.len == 0:
    # Empty means "implements the whole command". See the field's comment: the
    # opposite reading would make a subcommand-less program unexpressible.
    return WasmResolution(kind: wrResolved, module: module, command: command)

  let sub = subcommandOf(args)
  if sub.len == 0 or sub in module.subcommands:
    return WasmResolution(kind: wrResolved, module: module, command: command,
                          subcommand: sub)

  WasmResolution(kind: wrSubcommandNotBuilt, module: module, command: command,
                 subcommand: sub, available: module.subcommands)

proc refusal*(resolution: WasmResolution): PlatformError =
  ## The named refusal. Every message contains the command, because that is
  ## precisely what `webProfile`'s degradation sentence promises — "reported as
  ## unavailable by name, with the command shown" — and a generic
  ## "not available on this platform" would satisfy every type in this file
  ## while breaking the promise.
  case resolution.kind
  of wrResolved:
    platformError(pkNone, "")
  of wrNoModulesLoaded:
    # `pkNotSupported`, not `pkNotFound`: the capability is absent, and
    # `outcome.nim` reserves this kind for precisely that. The command is
    # still named — a user who typed it should see it — but the sentence is
    # about the build.
    platformError(pkNotSupported,
      "this build ships no wasm toolchain modules, so `" & resolution.command &
      "` — or anything else — cannot run in the tab.",
      detail = "empty wasm module registry")
  of wrPathQualified:
    platformError(pkNotSupported,
      "`" & resolution.command & "` is a file in this project, and a browser " &
      "tab has nothing to run it with. Only the toolchain commands built as " &
      "wasm modules run here.",
      detail = "path-qualified command")
  of wrNoModuleForCommand:
    platformError(pkNotFound,
      "`" & resolution.command & "` has no wasm build, so it cannot run in " &
      "the browser.",
      detail = "no module registered for " & resolution.command)
  of wrSubcommandNotBuilt:
    platformError(pkNotSupported,
      "`" & resolution.command & " " & resolution.subcommand & "` is not " &
      "part of the " & resolution.module.displayName & " wasm build. It " &
      "provides: " & resolution.available.join(", ") & ".",
      detail = "subcommand not built: " & resolution.command & " " &
               resolution.subcommand)

proc describes*(registry: WasmRegistry; command: string): string =
  ## What `which` answers with: the module id for a command that resolves, and
  ## the empty string otherwise. A separate proc rather than a field read, so
  ## the path-qualified rule cannot be forgotten at one call site.
  let resolution = registry.resolve(command)
  if resolution.kind == wrResolved: $resolution.module.moduleId else: ""

proc noWasmModules*(): WasmHost =
  ## A host with an empty registry that refuses every operation **by name**.
  ##
  ## This is the correct host wherever the modules have not been supplied, and
  ## it is not a stub: `resolve` over an empty registry answers
  ## `wrNoModuleForCommand` for every command, which is a true statement about
  ## that platform and produces the sentence a user should read. The four procs
  ## below are unreachable through `web_platform`, which never dispatches an
  ## unresolved run — they exist so a caller holding a `WasmHost` directly gets
  ## the same answer rather than a nil-call.
  WasmHost(
    registry: WasmRegistry(modules: @[]),
    run: proc(module: WasmModuleId; spec: ProcessSpec): auto =
      resolvedErr[ProcessRunResult](pkNotFound,
        "no wasm module `" & $module & "` is loaded in this tab"),
    start: proc(module: WasmModuleId; spec: ProcessSpec;
                onOutput: proc(chunk: ProcessOutputChunk);
                onExit: proc(exit: ProcessExit)): auto =
      resolvedErr[ProcessHandle](pkNotFound,
        "no wasm module `" & $module & "` is loaded in this tab"),
    terminate: proc(handle: ProcessHandle): auto =
      resolvedErr[Nothing](pkNotFound,
        "there is no running wasm module `" & $handle & "` to stop"),
    isRunning: proc(handle: ProcessHandle): auto =
      resolvedOk(false))
