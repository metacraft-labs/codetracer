## host/nim_c_compile_plan.nim — WHAT Edit mode runs to see a Nim file's
## generated C, without running it: the compiler's arguments, the scratch
## nimcache's name, and the line of its output a refusal quotes
## (`GUI/Debugging-Features/Generated-Code-Listing.md` §13.4, "Where the C
## comes from").
##
## Two hosts run that compile: the native front-ends through
## `native_nim_c_compiler` (`std/osproc`, polled from their loop) and the
## desktop's main process through `index/nim_c_listing` (node's
## `child_process`). They run it differently and must run THE SAME compile,
## so what they share is here, in a module both backends can import: it asks
## nothing of the environment, the filesystem or a process. A flag added for
## one host and not the other would give the two a different listing of the
## same file.

import std/[hashes, strutils]

const NimCListingsDir* = "nim-c-listings"
  ## The folder under a host's state root that holds one scratch nimcache
  ## per compiled source.

proc compileArgumentsOf*(source, cache: string): seq[string] =
  ## `nim c`'s arguments for `source`'s C. `--compileOnly` stops before the C
  ## compiler runs, so the wait is the Nim front end's alone (§8.1);
  ## `--lineDir:on` writes the `#line` directives a stock compiler's listing
  ## is anchored by, `--sourcemap:on` the `.c.map` CodeTracer's own compiler
  ## writes instead (each compiler ignores the other's). `--hints:off` keeps
  ## the output to the errors a refusal quotes.
  @["c", "--compileOnly", "--lineDir:on", "--sourcemap:on", "--hints:off",
    "--nimcache:" & cache, source]

proc stemOf(path: string): string =
  ## The file name of `path` without its extension, on either separator —
  ## spelt out rather than taken from `std/os`, whose path procs this module
  ## does not need on the JS backend.
  var name = path
  let slash = max(name.rfind('/'), name.rfind('\\'))
  if slash >= 0:
    name = name[slash + 1 .. ^1]
  let dot = name.rfind('.')
  if dot > 0: name[0 ..< dot] else: name

proc cacheNameOf*(source: string): string =
  ## The scratch nimcache folder's name for `source` (absolute): one per
  ## file, named so a person can tell which (`<stem>-<hash of the path>`),
  ## reused by the next compile of the same file so Nim's own cache makes it
  ## faster.
  stemOf(source) & "-" & toHex(hash(source).uint32)

proc errorLineOf*(output: string): string =
  ## The compiler's first `Error:` line, else its last line — what a refusal
  ## quotes.
  var last = ""
  for raw in output.splitLines():
    let l = raw.strip
    if "Error:" in l:
      return l
    if l.len > 0:
      last = l
  last
