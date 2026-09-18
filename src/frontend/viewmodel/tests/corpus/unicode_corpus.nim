## unicode_corpus.nim — PLAT-24 deliverable 6: the corpus, reachable from a
## suite on every backend this directory is compiled by.
##
## NOT-A-TEST-LANE-FILE: the corpus's loader, not a suite. The assertions are in
## `../unit/test_editor_unicode_corpus.nim` and `../unit/test_editor_text_store.nim`.
##
## Editor-Model-Conformance-Suite.md §5: nine classes, two documents each,
## eighteen documents, with a manifest recording each document's class,
## provenance, byte length, cluster count and display width at both
## `AmbiguousWidth` settings.
##
## `staticRead`, NEVER a runtime `readFile`
## ========================================
## `std/os`'s `readFile` DOES NOT EXIST on the JS backend, and this directory is
## compiled by three lanes — `vm-unit` (C), `vm-unit-js` (node) and
## `vm-unit-wasm`. PLAT-24's first suite was written with `readFile` and
## compiled on one of the three; that is recorded in the milestone as the thing
## to know before writing the next suite in here, and this is the next suite.
##
## The second reason is louder than convenience: a missing corpus document
## becomes a COMPILE error naming the path. A loader that returns "" for a file
## that has moved turns every law quantified over the corpus into a law about
## the empty string, and those pass.
##
## **Arbitrary bytes survive this, on both backends — measured, not assumed.**
## Class 7 is ill-formed input: bare continuation bytes, truncated sequences,
## overlong encodings, WTF-8 unpaired surrogates and an embedded NUL. All 21
## bytes of a probe carrying every one of those came back byte-identical from
## `staticRead` under `nim c` AND under `nim js` on 2026-09-18, which is why the
## class is in the corpus as bytes rather than in the manifest as an
## unrepresentable row.

import std/[strutils, unicode]

import isonim_tui/text/width as widthMod

export widthMod

type
  CorpusDoc* = object
    id*: string
    text*: string

  ManifestRow* = object
    ## One row of `unicode/manifest.tsv`, parsed at run time. The expected
    ## values are NEVER produced by the code under test: they are bytes on disk,
    ## written by `emit_manifest.nim` and compared here against a fresh
    ## measurement of the documents' bytes.
    id*, kind*, audit*, provenance*, oracle*, fingerprint*: string
    cls*, bytes*, lines*, runes*, clusters*, widthNarrow*, widthWide*: int

  ShortLineAudit* = object
    ## One row of `unicode/short-lines.tsv` — §5.1's *"each line's expected
    ## cluster count and display width recorded beside it"*, hand-worked by the
    ## corpus's author rather than read back out of the segmenter.
    id*: string
    line*: int
    clusters*, widthNarrow*, widthWide*: string   ## or the literal "MEASURED"

const
  CorpusDocs* = [
    CorpusDoc(id: "c1-zwj-short",
              text: staticRead("unicode/c1-zwj-short.txt")),
    CorpusDoc(id: "c2-combining-short",
              text: staticRead("unicode/c2-combining-short.txt")),
    CorpusDoc(id: "c3-regional-short",
              text: staticRead("unicode/c3-regional-short.txt")),
    CorpusDoc(id: "c4-ambiguous-short",
              text: staticRead("unicode/c4-ambiguous-short.txt")),
    CorpusDoc(id: "c5-cjk-short",
              text: staticRead("unicode/c5-cjk-short.txt")),
    CorpusDoc(id: "c6-terminators-short",
              text: staticRead("unicode/c6-terminators-short.txt")),
    CorpusDoc(id: "c7-illformed-short",
              text: staticRead("unicode/c7-illformed-short.txt")),
    CorpusDoc(id: "c8-tabs-short",
              text: staticRead("unicode/c8-tabs-short.txt")),
    CorpusDoc(id: "c9-ascii-control-short",
              text: staticRead("unicode/c9-ascii-control-short.txt")),
    CorpusDoc(id: "c1-zwj-long",
              text: staticRead("unicode/c1-zwj-long.txt")),
    CorpusDoc(id: "c2-combining-long",
              text: staticRead("unicode/c2-combining-long.txt")),
    CorpusDoc(id: "c3-regional-long",
              text: staticRead("unicode/c3-regional-long.txt")),
    CorpusDoc(id: "c4-ambiguous-long",
              text: staticRead("unicode/c4-ambiguous-long.txt")),
    CorpusDoc(id: "c5-cjk-long",
              text: staticRead("unicode/c5-cjk-long.txt")),
    CorpusDoc(id: "c6-terminators-long",
              text: staticRead("unicode/c6-terminators-long.txt")),
    CorpusDoc(id: "c7-illformed-long",
              text: staticRead("unicode/c7-illformed-long.txt")),
    CorpusDoc(id: "c8-tabs-long",
              text: staticRead("unicode/c8-tabs-long.txt")),
    CorpusDoc(id: "c9-ascii-control-long",
              text: staticRead("unicode/c9-ascii-control-long.txt")),
  ]
    ## §5: EIGHTEEN. The count is not written here as a number — the suite reads
    ## `CorpusDocs.len` and asserts it against the manifest's own row count, in
    ## both directions, so neither list can shrink without the other saying so.

  ManifestSource* = staticRead("unicode/manifest.tsv")
  ShortLinesSource* = staticRead("unicode/short-lines.tsv")
  ProvenanceSource* = staticRead("unicode/provenance.tsv")
  UnrepresentableSource* = staticRead("unicode/unrepresentable.tsv")

func fnv1a*(s: string): uint64 =
  ## The corpus's fingerprint. Spelled once, here, so the manifest emitter and
  ## the suite cannot disagree about what a fingerprint is.
  result = 0xcbf29ce484222325'u64
  for ch in s:
    result = result xor uint64(uint8(ch))
    result = result * 0x100000001b3'u64

func toHex16*(v: uint64): string =
  const Digits = "0123456789abcdef"
  result = "0x"
  for shift in countdown(60, 0, 4):
    result.add Digits[int((v shr uint64(shift)) and 0xF'u64)]

proc dataRows(src: string): seq[seq[string]] =
  ## Every non-comment, non-empty row of a corpus TSV, split on tabs.
  result = @[]
  for raw in src.splitLines():
    if raw.len == 0 or raw.startsWith("#"): continue
    result.add raw.split('\t')

proc manifestRows*(): seq[ManifestRow] =
  result = @[]
  for f in dataRows(ManifestSource):
    if f.len < 13:
      raise newException(ValueError,
        "manifest.tsv row has " & $f.len & " fields, expected 13: " & f.join("|"))
    result.add ManifestRow(
      id: f[0], cls: parseInt(f[1]), kind: f[2], bytes: parseInt(f[3]),
      lines: parseInt(f[4]), runes: parseInt(f[5]), clusters: parseInt(f[6]),
      widthNarrow: parseInt(f[7]), widthWide: parseInt(f[8]),
      fingerprint: f[9], oracle: f[10], audit: f[11], provenance: f[12])

proc shortLineAudits*(): seq[ShortLineAudit] =
  result = @[]
  for f in dataRows(ShortLinesSource):
    if f.len < 5:
      raise newException(ValueError,
        "short-lines.tsv row has " & $f.len & " fields, expected >= 5")
    result.add ShortLineAudit(id: f[0], line: parseInt(f[1]), clusters: f[2],
                              widthNarrow: f[3], widthWide: f[4])

proc unrepresentableRows*(): seq[(string, string, string)] =
  ## `(id, document, why)` — the cases this interface cannot express, recorded
  ## rather than omitted. Each one is demonstrated by a named case.
  result = @[]
  for f in dataRows(UnrepresentableSource):
    if f.len < 3:
      raise newException(ValueError,
        "unrepresentable.tsv row has " & $f.len & " fields, expected 3")
    result.add (f[0], f[1], f[2])

type Figures* = object
  bytes*, lines*, runes*, clusters*, widthNarrow*, widthWide*: int

proc measure*(text: string): Figures =
  ## The ONE measurement function. `emit_manifest.nim` computes the manifest
  ## with the same definition and this suite re-derives it here: per-LINE sums
  ## for runes, clusters and both widths, with `bytes` and `lines` over the
  ## document. Spelled once so the manifest and the assertion cannot mean two
  ## different things by "cluster count" (Verification-Harness-Traps §30).
  result.bytes = text.len
  let ls = text.split('\n')
  result.lines = ls.len
  for line in ls:
    for _ in runes(line): inc result.runes
    for c in graphemeClusters(line):
      inc result.clusters
      result.widthNarrow += clusterDisplayWidth(c.text, awNarrow)
      result.widthWide += clusterDisplayWidth(c.text, awWide)

proc docById*(id: string): string =
  for d in CorpusDocs:
    if d.id == id: return d.text
  raise newException(KeyError, "no corpus document named " & id)

iterator docsOfClass*(cls: int): CorpusDoc =
  ## The two documents of one class. Nine classes, two each — and the caller
  ## asserts it got two, because a filter that matched nothing satisfies every
  ## law written over it (Verification-Harness-Traps §4).
  for d in CorpusDocs:
    if d.id.len > 2 and d.id[0] == 'c' and parseInt($d.id[1]) == cls:
      yield d

func expandTabs*(line: string; tabSize: int; ambiguous: AmbiguousWidth): int =
  ## The display column a line ends at, with tabs advancing to the next tab
  ## stop. A tab is width 0 to `clusterDisplayWidth` — it is not a glyph — so
  ## expansion is a property of the LAYOUT and is computed here rather than
  ## inside the width primitive.
  result = 0
  for c in graphemeClusters(line):
    if c.text == "\t":
      result = ((result div tabSize) + 1) * tabSize
    else:
      result += clusterDisplayWidth(c.text, ambiguous)
