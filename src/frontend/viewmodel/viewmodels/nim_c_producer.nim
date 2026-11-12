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
## ## THE CODETRACER COMPILER WRITES A SOURCE MAP INSTEAD
##
## CodeTracer's own Nim compiler (codetracer-nim, "V3") writes no `#line`
## directives and no `FX_` table: with `--sourcemap:on` it writes a Source
## Map v3 file beside each C file, `<module>.nim.c.map`
## (https://sourcemaps.info/spec.html; codetracer-nim `compiler/cgen.nim`),
## and `ct record` compiles every Nim program that way
## (`ct/trace/recorder_dispatch.nim`). The map is the same artefact in
## another form: each generated line's first mapped segment names the Nim
## position it came from, and a run of lines naming the same Nim line is
## one anchor, as a directive's run is (`mapRowsOf`, `nimCListing`'s
## `mapText`). A file with directives is read by them; one without is read
## by its map.
##
## ## WHICH C FILE
##
## A Nim module's C draws from many sources (every `system` include names
## its own), so "a C file whose `FX_` table names `S`" is most of them. The
## module's own C file is the one whose DIRECTIVES name `S` most
## (`nimCFileFor`); the debugger's stop names one directly
## (`StopLocation.cPath`), which the host prefers when it has it.
import std/[json, strutils, tables]

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

const
  Base64Digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    ## Source Map v3's VLQ digits (the spec's "Base64 VLQ").

proc vlqDigit(c: char): int =
  Base64Digits.find(c)

proc decodeVlq(s: string; i: var int; ok: var bool): int =
  ## One Base64 VLQ value of `s` from `i`: five bits per digit, the sixth the
  ## continuation, the sign in the result's lowest bit.
  var shift = 0
  var value = 0
  while true:
    if i >= s.len:
      ok = false
      return 0
    let d = vlqDigit(s[i])
    inc i
    if d < 0:
      ok = false
      return 0
    value += (d and 31) shl shift
    if (d and 32) == 0:
      break
    shift += 5
  if (value and 1) == 1: -(value shr 1) else: value shr 1

proc mapRowsOf*(mapText: string): seq[tuple[path: string, line: int]] =
  ## Per generated line of a Source Map v3, the Nim position its first mapped
  ## segment names (`line` 1-based; 0 for a line with no mapped segment).
  ## Empty when `mapText` is not a version-3 map.
  if not mapText.strip.startsWith("{"):
    return
  var doc: JsonNode
  try:
    doc = parseJson(mapText)
  except:
    # Bare: on the JS backend a malformed document can surface as a native
    # error that `CatchableError` does not match, and a broken map is no
    # map on every backend.
    return
  if doc.kind != JObject or doc{"version"}.getInt(0) != 3:
    return
  let root = doc{"sourceRoot"}.getStr("")
  var sources: seq[string] = @[]
  for src in doc{"sources"}.getElems:
    let p = src.getStr("")
    sources.add(if root.len > 0 and not p.startsWith("/"):
                  root.strip(leading = false, chars = {'/'}) & "/" & p
                else: p)
  let mappings = doc{"mappings"}.getStr("")
  # The fields after the column are relative to the previous segment's,
  # across lines; the column resets on each line.
  var source, origLine = 0
  for lineText in mappings.split(';'):
    var row = (path: "", line: 0)
    for segment in lineText.split(','):
      if segment.len == 0:
        continue
      var i = 0
      var ok = true
      discard decodeVlq(segment, i, ok)          # generated column
      if not ok or i >= segment.len:
        continue                                  # a 1-field segment: unmapped
      source += decodeVlq(segment, i, ok)
      origLine += decodeVlq(segment, i, ok)
      if not ok:
        return @[]
      if row.line == 0 and source >= 0 and source < sources.len:
        row = (path: sources[source], line: origLine + 1)
    result.add row

proc nimCListing*(cText, sourcePath: string;
                  mapText = ""): GeneratedListing =
  ## The `nim.c` listing of one generated C file, described as the listing of
  ## `sourcePath` (the file the cursor is in, which `GeneratedCodeVM`
  ## compares against). Every directive's run is an anchor, whichever source
  ## it names: a cursor in an included file's line still finds its C here.
  ## A file with no directives is anchored by its Source Map v3, `mapText`
  ## (the `.c.map` beside it), when there is one.
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
  if directives.len == 0 and mapText.len > 0:
    # A run is a stretch of lines whose first segments name one Nim line.
    let mapped = mapRowsOf(mapText)
    var i = 0
    while i < min(count, mapped.len):
      let at = mapped[i]
      if at.line <= 0:
        inc i
        continue
      var last = i
      while last + 1 < min(count, mapped.len) and mapped[last + 1] == at:
        inc last
      result.anchors.add MappingAnchor(
        generatedFirst: i, generatedLast: last, fidelity: mfCoarse,
        sources: @[SourceRegion(path: at.path, startLine: at.line,
                                endLine: at.line)])
      i = last + 1
    return
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

proc directiveCount*(cText, sourcePath: string; mapText = ""): int =
  ## How many `#line` directives of `cText` name `sourcePath` — or, for a
  ## file with none, how many of its map's runs do.
  for d in lineDirectives(cText.splitLines()):
    if d.path == sourcePath:
      inc result
  if result == 0 and mapText.len > 0:
    for a in nimCListing(cText, sourcePath, mapText).anchors:
      if a.sources[0].path == sourcePath:
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

proc nimCFileFor*(sourcePath: string;
                  candidates: openArray[tuple[path, text, map: string]]): string =
  ## `nimCFileFor` over C files with their source maps ("" for none).
  var best = 0
  for c in candidates:
    let n = directiveCount(c.text, sourcePath, c.map)
    if n > best:
      best = n
      result = c.path

proc mapPathOf*(cPath: string): string =
  ## Where the codetracer compiler writes `cPath`'s Source Map v3.
  cPath & ".map"

proc isGeneratedNimC*(path: string): bool =
  ## Whether `path` names a Nim compiler's generated C file
  ## (`<nimcache>/@m<module>.nim.c`, or any `*.nim.c`).
  path.endsWith(".nim.c")
