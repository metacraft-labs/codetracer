## index/nim_c_listing.nim — **Edit mode's generated C, on the desktop**
## (`GUI/Debugging-Features/Generated-Code-Listing.md` §13.4, "Where the C
## comes from"; Headless-SDK-Front-Ends HSF-E11).
##
## Debug mode reads the C a recording bundles. Edit mode has no recording, so
## View Generated C Source asks the main process to compile the edited file
## to C now — `CODETRACER::nim-c-listing-compile`, answered on every exit with
## `CODETRACER::nim-c-listing-compiled` (`traces.onNimCListingCompile`) —
## and the renderer shows the C files it names through the shared presenter
## (`ui/generated_code`). This module is the compile, with no window and no
## IPC, so `tests/nim_c_listing_test.nim` runs it as the desktop does.
##
## THE SAME COMPILE AS THE NATIVE FRONT-ENDS'. The arguments, the scratch
## nimcache's name and the line a refusal quotes are
## `viewmodel/host/nim_c_compile_plan`'s, which `native_nim_c_compiler` (the
## terminal's and GPUI's runner) uses too; only how the process is run
## differs. Here it is node's `child_process`, through `readProcessOutcome` —
## the route the edit-mode toolbar's Run (`traces.onRunProgram`) records
## through — so the main process never blocks while the compiler runs.
##
## The compiler: `$CODETRACER_NIM` (the native hosts' variable, so one setting
## serves every front-end), else `$CODETRACER_NIM_EXE_PATH` (`ct record`'s),
## else `nim` on the PATH. The nimcache: `<state dir>/nim-c-listings/<stem>-
## <hash>` (`ct_home.ctStateDir`, the desktop's state root); nothing is
## written into the project. The compile reads the SAVED file (the handler
## waits for a save the renderer started just before asking, as Run does).

import std / [ async, jsffi, strutils, algorithm ]
import ../lib/[ electron_lib, jslib ]
import ../../common/ct_home
import ../viewmodel/host/nim_c_compile_plan

const
  NimCListingTimeoutMs* = 120_000
    ## As long as the native runner waits (`native_nim_c_compiler`).

type
  NimCListingOutcome* = object
    ## One compile's answer.
    ok*: bool
    cFiles*: seq[string]
      ## The generated C files the compile left in the nimcache, sorted.
    message*: string
      ## Why it failed, "" when it compiled.

proc nodeEnvOf(name: cstring): cstring {.importjs: "(process.env[#] || '')".}
proc nodeMkdirRecursive(path: cstring) {.importjs: "require('fs').mkdirSync(#, {recursive: true})".}
proc nodeDirName(path: cstring): cstring {.importjs: "require('path').dirname(#)".}
proc nodeBaseName(path: cstring): cstring {.importjs: "require('path').basename(#)".}
proc nodeJoin(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}
proc nodeResolve(path: cstring): cstring {.importjs: "require('path').resolve(#)".}
proc nodeIsFile(path: cstring): bool {.importjs: """
  (function(p){ try { return require('fs').statSync(p).isFile(); }
                catch (e) { return false; } })(#)""".}
proc nodeReadDir(path: cstring): seq[cstring] {.importjs: """
  (function(p){ try { return require('fs').readdirSync(p); }
                catch (e) { return []; } })(#)""".}

proc nimCListingCompiler*(): string =
  ## The `nim` the compile runs (see the module doc).
  for name in [cstring"CODETRACER_NIM", cstring"CODETRACER_NIM_EXE_PATH"]:
    let path = ($nodeEnvOf(name)).strip
    if path.len > 0:
      return path
  "nim"

proc nimCListingCacheOf*(source: string; stateRoot = ""): string =
  ## The scratch nimcache of `source` under `stateRoot` (the desktop's state
  ## directory when "").
  let root = if stateRoot.len > 0: stateRoot else: ctStateDir()
  $nodeJoin(nodeJoin(cstring(root), cstring(NimCListingsDir)),
            cstring(cacheNameOf(source)))

proc generatedCIn(cache: string): seq[string] =
  ## The `*.nim.c` files Nim wrote into `cache` (a nimcache is flat).
  for entry in nodeReadDir(cstring(cache)):
    if ($entry).endsWith(".nim.c"):
      let path = $nodeJoin(cstring(cache), entry)
      if nodeIsFile(cstring(path)):
        result.add path
  result.sort()

proc compileNimCListing*(nim, source, cache: string;
                         timeoutMs = NimCListingTimeoutMs):
    Future[NimCListingOutcome] {.async.} =
  ## Compile `source` to C into `cache` with `nim` (`compileArgumentsOf`).
  ## Never rejects: every failure is an outcome carrying its sentence.
  let file = $nodeResolve(cstring(source))
  let name = $nodeBaseName(cstring(file))
  if not nodeIsFile(cstring(file)):
    return NimCListingOutcome(message: file & " is not a file: save it first")
  try:
    nodeMkdirRecursive(cstring(cache))
  except:
    return NimCListingOutcome(message: "could not create the nimcache " &
      cache & ": " & getCurrentExceptionMsg())
  var args: seq[cstring] = @[]
  for a in compileArgumentsOf(file, cache):
    args.add cstring(a)
  # `timeout` is node's own: past it the child gets SIGTERM, and `close`
  # reports the signal (https://nodejs.org/api/child_process.html).
  let run = await readProcessOutcome(cstring(nim), args,
    js{cwd: nodeDirName(cstring(file)), timeout: timeoutMs})
  if run.spawnError.len > 0:
    let why = $run.spawnError
    return NimCListingOutcome(message:
      if "ENOENT" in why:
        "no `" & nim & "` to compile " & name & " with (set CODETRACER_NIM, " &
          "or put `nim` on the PATH)"
      else: "could not start " & nim & ": " & why)
  if run.signal.len > 0:
    return NimCListingOutcome(message:
      if run.signal == cstring"SIGTERM":
        "nim did not finish within " & $(timeoutMs div 1000) & " s"
      else: "nim was ended by " & $run.signal)
  if run.exitCode != 0:
    # Nim prints its diagnostics on stdout; whatever reached stderr is read
    # after them.
    let why = errorLineOf($run.stdout & "\n" & $run.stderr)
    return NimCListingOutcome(message:
      if why.len > 0: why else: "nim exited " & $run.exitCode)
  let files = generatedCIn(cache)
  if files.len == 0:
    return NimCListingOutcome(message: "nim wrote no C for " & name)
  return NimCListingOutcome(ok: true, cFiles: files)
