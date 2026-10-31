## Exercises the shipped main-process discovery and renderer loader against real
## files, including .c.map output from the dev-shell Nim compiler. The reader is
## Node's real asynchronous filesystem operation, injected at the same boundary
## where the renderer supplies its platform-backed readFileUtf8. No mocks.
import std/[asyncjs, jsffi, os, json, strutils]
import ../index/nim_sourcemap_paths
import ../nim_sourcemap
import ../lib/jslib

proc tempDir(): cstring {.importjs: "require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), 'ct-nim-map-'))".}
proc mkdir(path: cstring) {.importjs: "require('fs').mkdirSync(#, {recursive:true})".}
proc write(path, text: cstring) {.importjs: "require('fs').writeFileSync(#, #)".}
proc remove(path: cstring) {.importjs: "require('fs').rmSync(#, {recursive:true, force:true})".}
proc readFile(path: cstring): Future[cstring] {.importjs: "require('fs').promises.readFile(#, 'utf8')".}
proc read(path: cstring): Future[cstring] = readFile(path)
proc compile(cache, source: cstring) {.importjs: "require('child_process').execFileSync('nim', ['c', '--compileOnly', '--hints:off', '--sourcemap:on', '--nimcache:' + #, #], {stdio:'inherit'})".}
proc failProcess() {.importjs: "(process.exitCode = 1)".}

let scratch = tempDir()
let cache = $scratch / "nimcache"
let first = cache / "@mmain.nim.c"
let second = cache / "@mhelper.nim.c"
const mainSource = "/src/main.nim"
const helperSource = "/src/helper.nim"

proc mapText(sources: seq[string]; mappings: string): cstring =
  cstring($(%*{"version": 3, "file": "/old/recording/module.c", "sources": sources,
    "names": [], "mappings": mappings}))

proc fixtures() =
  mkdir(cstring(cache))
  write(cstring(first), cstring("alpha\n  beta\n  gamma\ndelta\n"))
  write(cstring(first & ".map"), mapText(@[mainSource, helperSource], "AAAA;;EACA;ACAA"))
  write(cstring(second), cstring("helper\nmain\n"))
  write(cstring(second & ".map"), mapText(@[helperSource, mainSource], "AAEA;ACDA"))

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
    fixtures()
    await runCase("current per-module sidecars are discovered without retired aggregates", proc(): Future[void] {.async.} =
      let paths = findSourcemapPaths(scratch)
      doAssert paths.len == 2, "expected both current .c.map modules, got " & $paths
      doAssert cstring(first & ".map") in paths
      doAssert cstring(second & ".map") in paths
    )
    await runCase("V3 modules merge bidirectional mappings with independent source IDs", proc(): Future[void] {.async.} =
      let sm = await loadFrontendSourcemap(@[cstring(first & ".map"), cstring(second & ".map")], read)
      doAssert sm.loaded, "renderer must load Source Map V3 sidecars"
      let mainID = sm.cToNim[cstring(first)][1][0]
      let helperID = sm.cToNim[cstring(first)][4][0]
      doAssert sm.nimSources[mainID] == cstring(mainSource)
      doAssert sm.nimSources[helperID] == cstring(helperSource)
      doAssert sm.cToNim[cstring(second)][1] == [helperID, 3]
      doAssert sm.cToNim[cstring(second)][2] == [mainID, 2]
      let groups = sm.nimToC[cstring(mainSource)][2]
      doAssert groups.len == 2
      doAssert sm.cSources[groups[0][0][0]] == cstring(first)
      doAssert sm.cSources[groups[1][0][0]] == cstring(second)
    )
    await runCase("generated-line lookup carries segments and uses first nonblank column", proc(): Future[void] {.async.} =
      let sm = await loadFrontendSourcemap(@[cstring(first & ".map")], read)
      doAssert sm.loaded
      doAssert sm.cToNim[cstring(first)][1][1] == 1
      doAssert sm.cToNim[cstring(first)][2][1] == 1
      doAssert sm.cToNim[cstring(first)][3][1] == 2
      doAssert sm.cToNim[cstring(first)][4][1] == 2
    )
    await runCase("V3 columns, blank lines, unmapped segments and sourceRoot preserve navigation", proc(): Future[void] {.async.} =
      let cPath = cache / "columns.c"
      write(cstring(cPath), cstring("  first(); later();\n\nsecond();\nthird();\nfourth();\n"))
      write(cstring(cPath & ".map"), cstring($(%*{"version": 3,
        "sources": @["relative.nim"], "sourceRoot": "/src", "names": [],
        "mappings": "EAAA,SAEA;;;A;AACA"})))
      let sm = await loadFrontendSourcemap(@[cstring(cPath & ".map")], read)
      doAssert sm.loaded
      doAssert sm.cToNim[cstring(cPath)][1][1] == 1,
        "a later expression must not overwrite the first-code-column mapping"
      doAssert not sm.cToNim[cstring(cPath)].hasKey(2), "blank lines are not navigation targets"
      doAssert sm.cToNim[cstring(cPath)][3][1] == 3, "carry the last segment, including across a blank line"
      doAssert not sm.cToNim[cstring(cPath)].hasKey(4), "one-field segments terminate mapped ranges"
      doAssert sm.cToNim[cstring(cPath)][5][1] == 4
      let id = sm.cToNim[cstring(cPath)][1][0]
      doAssert sm.nimSources[id] == cstring"/src/relative.nim"
    )
    await runCase("missing and malformed maps do not mark an empty mapping loaded", proc(): Future[void] {.async.} =
      let absent = await loadFrontendSourcemap(@[], read)
      doAssert not absent.loaded
      doAssert findSourcemapPaths(cstring($scratch / "absent")).len == 0
      let bad = cache / "bad.c.map"
      write(cstring(cache / "bad.c"), cstring("first\nsecond\n"))
      write(cstring(bad), mapText(@["/poison.nim"], "AAAA;!"))
      let malformed = await loadFrontendSourcemap(@[cstring(bad)], read)
      doAssert not malformed.loaded
      let mixed = await loadFrontendSourcemap(@[cstring(bad), cstring(first & ".map")], read)
      doAssert mixed.loaded
      doAssert not mixed.cToNim.hasKey(cstring(cache / "bad.c"))
      doAssert not mixed.nimToC.hasKey(cstring"/poison.nim")
      doAssert mixed.cToNim[cstring(first)][3][1] == 2
    )
    await runCase("the current Nim compiler's actual sidecars load into the renderer", proc(): Future[void] {.async.} =
      let trace = $scratch / "real"
      let source = $scratch / "main.nim"
      write(cstring(source), cstring("proc twice(x: int): int =\n  result = x * 2\necho twice(3)\n"))
      compile(cstring(trace / "nimcache"), cstring(source))
      let paths = findSourcemapPaths(cstring(trace))
      doAssert paths.len > 0, "the compiler must emit current sidecars"
      let sm = await loadFrontendSourcemap(paths, read)
      doAssert sm.loaded
      doAssert sm.nimToC.hasKey(cstring(source))
      doAssert sm.nimToC[cstring(source)].hasKey(3)
      let pair = sm.nimToC[cstring(source)][3][0][0]
      let cPath = sm.cSources[pair[0]]
      doAssert sm.cToNim[cPath][pair[1]][1] == 3
    )
    doAssert cases == 6
    if failures > 0:
      failProcess()
  finally:
    remove(scratch)

discard main()
