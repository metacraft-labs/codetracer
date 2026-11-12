## viewmodels/nim_c_producer.nim
##
## THE NIM PRODUCER for the Generated Code Listing's `nim.c` target:
## `GUI/Debugging-Features/Generated-Code-Listing.md` §13.4.
##
## LANE: `vm-unit` AND `vm-unit-js`. A pure function of text — no host, no
## filesystem. The host hands over the generated C's text (a recording's
## bundled file, or Edit mode's scratch nimcache) and the file list to pick
## from.
##
## ## WHAT A NIM BUILD ALREADY SAYS ABOUT ITSELF
##
## A debug build (`--lineDir:on`, the default with `--debugger:native`)
## writes at the top of each generated C file one
##
##     #define FX_<n> "<path>"
##
## per source file it draws from, and before each C statement
##
##     #line <line> FX_<n>
##
## naming the Nim line the following C came from. That is the whole artefact:
## no source map (`--sourcemap`'s `.c.map`), no second compile, and it is in
## every native recording of a Nim program, bundled with the sources.
##
##   * ROWS are the C file's lines, as the compiler wrote them, directives
##     included (§13.1 (1); §14.3: the compiler's own annotations are kept).
##   * ANCHORS: each directive opens a run of rows — up to the row before the
##     next directive — mapped to `(path of FX_<n>, line)` (§13.1 (2)). The
##     claim is COARSE (`mfCoarse`): a directive marks the statement the C
##     came from, not each expression. Rows before the first directive (the
##     `#define`s, the `#include`s) are a gap, which suspends synchronisation
##     rather than borrowing the nearest anchor (`generated_code_anchors`).
##   * NO INLINING CHAIN (§13.1 (3)): Nim names one position per run, a
##     template's or an inline proc's body at the line the directive names.
##     The artefact's ceiling says so (`hasInliningRecords = false`).
##
## ## WHICH C FILE
##
## A Nim module's C draws from many sources (every `system` include names
## its own), so "a C file whose `FX_` table names `S`" is most of them. The
## module's own C file is the one whose DIRECTIVES name `S` most
## (`nimCFileFor`); the debugger's stop names one directly
## (`StopLocation.cPath`), which the host prefers when it has it.
import std/[strutils, tables]

import ./generated_code_vm
import ./generated_code_anchors

const
  NimCTargetId* = "nim.c"
    ## The ladder's id (`generated_code_operation.LadderRows`).
  NimCProducer* = "nim-line-directives"
    ## GCL-D23: the producer the listing states it was painted by.

  NimCSupport* = ArtefactSupport(hasSourceRegions: true)
    ## What a `#line` directive carries: a statement's region, resolved to a
    ## line, and nothing finer (§5.1's ceiling, `mfCoarse`).

type
  NimLineDirective* = object
    ## One `#line <line> FX_<n>` of a generated C file.
    row*: int
      ## Its 0-based row in the file.
    line*: int
    path*: string
      ## The source `FX_<n>` names; "" when the file defines no such macro.

proc unquote(s: string): string =
  let t = s.strip
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    t[1 .. ^2].replace("\\\\", "\\").replace("\\\"", "\"")
  else:
    t

proc fileTable*(lines: openArray[string]): Table[string, string] =
  ## The `FX_<n>` → path table of a generated C file's `#define`s.
  for l in lines:
    let t = l.strip
    if t.startsWith("#define FX_"):
      let rest = t["#define ".len .. ^1]
      let space = rest.find(' ')
      if space > 0:
        result[rest[0 ..< space]] = unquote(rest[space + 1 .. ^1])

proc lineDirectives*(lines: openArray[string]): seq[NimLineDirective] =
  ## Every `#line` directive, in file order, with the source it names.
  let files = fileTable(lines)
  for i, l in lines:
    let t = l.strip
    if not t.startsWith("#line "):
      continue
    let parts = t["#line ".len .. ^1].strip.splitWhitespace(maxsplit = 1)
    if parts.len == 0:
      continue
    let line = try: parseInt(parts[0]) except ValueError: -1
    if line <= 0:
      continue
    var path = ""
    if parts.len == 2:
      let name = parts[1].strip
      path = if name.startsWith("\""): unquote(name)
             else: files.getOrDefault(name, "")
    result.add NimLineDirective(row: i, line: line, path: path)

proc nimCListing*(cText, sourcePath: string): GeneratedListing =
  ## The `nim.c` listing of one generated C file, described as the listing of
  ## `sourcePath` (the file the cursor is in, which `GeneratedCodeVM`
  ## compares against). Every directive's run is an anchor, whichever source
  ## it names: a cursor in an included file's line still finds its C here.
  let lines = cText.splitLines()
  # `splitLines` gives a trailing "" for a file that ends in a newline: that
  # is not a row the compiler printed.
  let count = if lines.len > 0 and lines[^1].len == 0: lines.len - 1
              else: lines.len
  result = GeneratedListing(targetId: NimCTargetId, sourcePath: sourcePath,
                            producer: NimCProducer, support: NimCSupport)
  for i in 0 ..< count:
    result.rows.add GeneratedRow(index: i, text: lines[i])
  let directives = lineDirectives(lines.toOpenArray(0, count - 1))
  for k, d in directives:
    if d.path.len == 0:
      continue
    let last = if k + 1 < directives.len: directives[k + 1].row - 1
               else: count - 1
    result.anchors.add MappingAnchor(
      generatedFirst: d.row, generatedLast: max(d.row, last),
      fidelity: mfCoarse,
      sources: @[SourceRegion(path: d.path, startLine: d.line,
                              endLine: d.line)])

proc directiveCount*(cText, sourcePath: string): int =
  ## How many `#line` directives of `cText` name `sourcePath`.
  for d in lineDirectives(cText.splitLines()):
    if d.path == sourcePath:
      inc result

proc nimCFileFor*(sourcePath: string;
                  candidates: openArray[tuple[path, text: string]]): string =
  ## The generated C file of `sourcePath` among `candidates`: the one whose
  ## directives name it most — a module's own C file — or "" when none does.
  ## Ties keep the first candidate, so the answer does not depend on hashing.
  var best = 0
  for c in candidates:
    let n = directiveCount(c.text, sourcePath)
    if n > best:
      best = n
      result = c.path

proc isGeneratedNimC*(path: string): bool =
  ## Whether `path` names a Nim compiler's generated C file
  ## (`<nimcache>/@m<module>.nim.c`, or any `*.nim.c`).
  path.endsWith(".nim.c")
