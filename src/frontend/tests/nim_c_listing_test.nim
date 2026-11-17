## The desktop main process's Edit-mode compile of a Nim file to C
## (`index/nim_c_listing`, Generated-Code-Listing.md §13.4, HSF-E11), run
## against the real Nim compiler on PATH and the real filesystem, through the
## same node `child_process` route the desktop runs it by. No mocks; the only
## thing not exercised is the IPC send of the answer, which needs a window.
import std/[asyncjs, jsffi, os, strutils]
import ../index/nim_c_listing
import ../viewmodel/host/nim_c_compile_plan
import ../lib/jslib

proc tempDir(): cstring {.importjs: "require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), 'ct-nim-c-listing-'))".}
proc write(path, text: cstring) {.importjs: "require('fs').writeFileSync(#, #)".}
proc readText(path: cstring): cstring {.importjs: "require('fs').readFileSync(#, 'utf8')".}
proc exists(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}
proc remove(path: cstring) {.importjs: "require('fs').rmSync(#, {recursive:true, force:true})".}
proc failProcess() {.importjs: "(process.exitCode = 1)".}

let scratch = $tempDir()
let good = scratch / "main.nim"
let broken = scratch / "broken.nim"

var failures = 0
var cases = 0
proc runCase(name: string; body: proc(): Future[void]): Future[void] {.async.} =
  inc cases
  try:
    await body()
    echo "  [OK] ", name
  except:
    inc failures
    echo "  [FAILED] ", name, ": ", getCurrentExceptionMsg()

proc main(): Future[void] {.async.} =
  try:
    write(cstring(good), cstring("proc twice(x: int): int =\n  result = x * 2\n\necho twice(21)\n"))
    write(cstring(broken), cstring("let answer: int = \"forty-two\"\necho answer\n"))
    let nim = nimCListingCompiler()

    await runCase("a file is compiled to its module's C, into the scratch nimcache", proc(): Future[void] {.async.} =
      let cache = nimCListingCacheOf(good, scratch / "state")
      doAssert cache == scratch / "state" / NimCListingsDir / cacheNameOf(good), cache
      let got = await compileNimCListing(nim, good, cache)
      doAssert got.ok, got.message
      doAssert got.message == ""
      let own = cache / "@mmain.nim.c"
      doAssert own in got.cFiles, "expected " & own & " among " & $got.cFiles
      for f in got.cFiles:
        doAssert f.startsWith(cache) and f.endsWith(".nim.c"), f
      # Anchorable by either form the shared producer reads: a stock
      # compiler's directives, CodeTracer's compiler's source map.
      let text = $readText(cstring(own))
      doAssert "#line " in text or exists(cstring(own & ".map")),
        own & " has neither #line directives nor a source map"
      # Nothing is written into the project.
      doAssert not exists(cstring(scratch / "nimcache"))
    )
    await runCase("a file that does not compile answers the compiler's error line", proc(): Future[void] {.async.} =
      let got = await compileNimCListing(nim, broken, nimCListingCacheOf(broken, scratch / "state"))
      doAssert not got.ok
      doAssert got.cFiles.len == 0
      doAssert "broken.nim(1, " in got.message and "Error: type mismatch" in got.message,
        got.message
    )
    await runCase("an unsaved file is refused before any compiler runs", proc(): Future[void] {.async.} =
      let got = await compileNimCListing(nim, scratch / "never-saved.nim", scratch / "unused")
      doAssert not got.ok
      doAssert got.message.endsWith("never-saved.nim is not a file: save it first"), got.message
      doAssert not exists(cstring(scratch / "unused"))
    )
    await runCase("a missing compiler is named, not thrown", proc(): Future[void] {.async.} =
      let got = await compileNimCListing(scratch / "no-such-nim", good, scratch / "state2")
      doAssert not got.ok
      doAssert got.message.startsWith("no `" & scratch / "no-such-nim" & "` to compile main.nim"),
        got.message
    )
    await runCase("the arguments are the native front-ends' own", proc(): Future[void] {.async.} =
      # One compile for every host: the desktop has no list of its own.
      let args = compileArgumentsOf(good, "/cache")
      doAssert args[0 .. 4] == @["c", "--compileOnly", "--lineDir:on", "--sourcemap:on", "--hints:off"]
      doAssert args[^2] == "--nimcache:/cache" and args[^1] == good
      doAssert errorLineOf("Hint: x\nfoo.nim(3, 1) Error: bad\nlater\n") == "foo.nim(3, 1) Error: bad"
      doAssert errorLineOf("only\nlast line\n") == "last line"
    )
    doAssert cases == 5
    if failures > 0:
      failProcess()
  finally:
    remove(cstring(scratch))

discard main()
