## emit_manifest.nim — PLAT-24 deliverable 6: the computed half of the corpus
## manifest.
##
## NOT-A-TEST-LANE-FILE: a tool, run by hand, not a suite. The assertions live
## in `viewmodel/tests/unit/test_editor_unicode_corpus.nim`, which the `vm-unit`
## lane discovers; this only WRITES the numbers that suite asserts.
##
## Editor-Model-Conformance-Suite.md §5.2: *"Each document has a manifest row:
## its class, its provenance …, its byte length, its cluster count, and its
## display width at each `AmbiguousWidth` setting. The manifest figures are
## asserted, so a corpus file silently rewritten by an editor that normalises
## line endings — which is how corpora die — reddens the suite."*
##
## TWO HALVES, AND WHY THEY ARE SEPARATE FILES
## ===========================================
## `provenance.tsv` is what a HUMAN writes: the class, the kind, where the
## bytes came from, and — where one exists — an INDEPENDENT expected cluster
## count. `manifest.tsv` is what this tool COMPUTES from those rows plus the
## documents' bytes. Keeping them apart is what stops "regenerate the manifest"
## from being able to launder a corpus change into a green run: the independent
## column travels with the human half, and this tool REFUSES to write a manifest
## whose independent column disagrees with the bytes.
##
## That refusal is the whole point. A manifest a tool will happily rewrite to
## match whatever the corpus now says is a manifest that asserts nothing.
##
## Usage (from the repository root):
##   nim c -r --hints:off src/frontend/viewmodel/tests/corpus/unicode/emit_manifest.nim
##   nim c -r --hints:off .../emit_manifest.nim --check   # compare, write nothing

import std/[os, strformat, strutils, unicode]

import isonim_tui/text/width as widthMod

const Dir = "src/frontend/viewmodel/tests/corpus/unicode"

type Row = object
  id, kind, audit, provenance: string
  cls: int
  oracle: string

func fnv1a(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for ch in s:
    result = result xor uint64(uint8(ch))
    result = result * 0x100000001b3'u64

proc readProvenance(path: string): seq[Row] =
  result = @[]
  for raw in lines(path):
    if raw.len == 0 or raw.startsWith("#"): continue
    let f = raw.split('\t')
    if f.len < 6:
      quit(&"provenance.tsv: a row has {f.len} fields, expected 6: {raw}")
    result.add Row(id: f[0], cls: parseInt(f[1]), kind: f[2], oracle: f[3],
                   audit: f[4], provenance: f[5])

type Figures = object
  bytes, lines, runes, clusters, widthNarrow, widthWide: int

proc measure(text: string): Figures =
  ## Per-LINE sums for everything a line has (runes, clusters, width); the
  ## newline separators are not text and are excluded from all three. `bytes`
  ## and `lines` are over the document, which is what a corpus file's identity
  ## is made of.
  result.bytes = text.len
  let ls = text.split('\n')
  result.lines = ls.len
  for line in ls:
    for _ in runes(line): inc result.runes
    for c in graphemeClusters(line):
      inc result.clusters
      result.widthNarrow += clusterDisplayWidth(c.text, awNarrow)
      result.widthWide += clusterDisplayWidth(c.text, awWide)

proc main() =
  let check = "--check" in commandLineParams()
  if not dirExists(Dir):
    quit(&"run from the repository root; {Dir} is not here")
  let rows = readProvenance(Dir / "provenance.tsv")
  if rows.len != 18:
    quit(&"provenance.tsv holds {rows.len} rows; §5 says EIGHTEEN documents")

  var manifest = @[
    "# PLAT-24 corpus manifest — EMITTED by emit_manifest.nim from",
    "# provenance.tsv plus the documents' bytes. Asserted, per document, by",
    "# src/frontend/viewmodel/tests/unit/test_editor_unicode_corpus.nim.",
    "#",
    "# runes, clusters and the two widths are PER-LINE SUMS: the '\\n'",
    "# separators are not text and are counted in `lines` instead. `oracle` is",
    "# an INDEPENDENT expected cluster count — a hand audit, or Unicode's own",
    "# GraphemeBreakTest break data — and `-` where there is none.",
    "#",
    "# id\tclass\tkind\tbytes\tlines\trunes\tclusters\twidthNarrow" &
      "\twidthWide\tfnv1a\toracle\taudit\tprovenance"]
  # The per-line hand audit, checked HERE as well as in the suite. A document
  # whose TOTAL matches while two of its lines are wrong in opposite directions
  # is the shape a total cannot see, and the audit is per line precisely so that
  # shape is visible.
  var audited: seq[(string, int, string, string, string)] = @[]
  for raw in lines(Dir / "short-lines.tsv"):
    if raw.len == 0 or raw.startsWith("#"): continue
    let f = raw.split('\t')
    if f.len < 5:
      quit(&"short-lines.tsv: a row has {f.len} fields, expected >= 5: {raw}")
    audited.add (f[0], parseInt(f[1]), f[2], f[3], f[4])

  var disagreements = 0
  var lineChecks = 0
  for (id, no, c, wn, ww) in audited:
    let path = Dir / (id & ".txt")
    if not fileExists(path): quit(&"MISSING CORPUS DOCUMENT: {path}")
    let ls = readFile(path).split('\n')
    if no >= ls.len:
      inc disagreements
      echo &"DISAGREEMENT {id}: the audit names line {no}, the document has " &
           &"{ls.len} lines"
      continue
    if c == "MEASURED": continue
    let f = measure(ls[no])
    inc lineChecks
    if $f.clusters != c or $f.widthNarrow != wn or $f.widthWide != ww:
      inc disagreements
      echo &"DISAGREEMENT {id} line {no}: audited {c}/{wn}/{ww} " &
           &"(clusters/narrow/wide), measured " &
           &"{f.clusters}/{f.widthNarrow}/{f.widthWide}"
  echo &"per-line hand audit: {lineChecks} lines checked, " &
       &"{audited.len - lineChecks} recorded as MEASURED"

  var totals: Figures
  for r in rows:
    let path = Dir / (r.id & ".txt")
    if not fileExists(path):
      quit(&"MISSING CORPUS DOCUMENT: {path}")
    let text = readFile(path)
    let f = measure(text)
    totals.bytes += f.bytes
    totals.lines += f.lines
    totals.runes += f.runes
    totals.clusters += f.clusters
    if r.oracle != "-":
      let expected = parseInt(r.oracle)
      if expected != f.clusters:
        inc disagreements
        echo &"DISAGREEMENT {r.id}: the independent oracle says {expected} " &
             &"clusters, the segmenter counts {f.clusters}"
    manifest.add [r.id, $r.cls, r.kind, $f.bytes, $f.lines, $f.runes, $f.clusters,
             $f.widthNarrow, $f.widthWide, &"0x{fnv1a(text):016x}", r.oracle,
             r.audit, r.provenance].join("\t")
    echo &"{r.id:<26} class {r.cls}  {f.bytes:>7}B  {f.lines:>5}L  " &
         &"{f.runes:>7}r  {f.clusters:>7}c  w {f.widthNarrow:>7}/{f.widthWide:<7}"

  echo ""
  echo &"18 documents: {totals.bytes} bytes, {totals.lines} lines, " &
       &"{totals.runes} runes, {totals.clusters} clusters"
  if disagreements > 0:
    echo ""
    echo &"REFUSING TO WRITE THE MANIFEST: {disagreements} document(s) " &
         "disagree with their INDEPENDENT oracle."
    echo "A manifest regenerated to match a corpus it no longer describes is " &
         "a manifest that asserts nothing. Fix the corpus or the audit."
    quit(1)

  let blob = manifest.join("\n") & "\n"
  let target = Dir / "manifest.tsv"
  let old = if fileExists(target): readFile(target) else: ""
  if old == blob:
    echo "manifest.tsv is unchanged"
  elif check:
    echo &"manifest.tsv DIFFERS ({old.len} -> {blob.len} bytes) — not written"
    quit(1)
  else:
    writeFile(target, blob)
    echo &"wrote {target} ({blob.len} bytes)"

main()
