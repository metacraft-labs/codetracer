## viewmodels/noir_anchor_producer.nim
##
## NS4's Noir producer: a `nargo compile` artefact in, `MappingAnchor`s out.
##
## `generated_code_anchors.nim` is the model — it says which mapping claims are
## structurally impossible and refuses them. This is the first thing that FILLS
## that model from a real compiler artefact, and it is where the temptation to
## overclaim actually lives: the model can only reject a claim that someone
## makes, and a producer with a real artefact in hand and a five-rung ladder in
## front of it is exactly the party inclined to reach for a higher rung than it
## can support.
##
## ## What a Noir artefact carries
##
## `nargo compile` writes a JSON program containing, among other things:
##
##   `file_map`       `{"0": {"path": "…/src/main.nr", "source": "fn main…"}}`
##   `debug_symbols`  per circuit, `{"locations": {"<opcode>": [{"span":
##                    {"start": N, "end": M}, "file": F}]}}`
##
## `debug_symbols` is base64'd deflate in the file on disk. THAT DECODING IS
## NOT THIS MODULE'S JOB — it is transport, and a caller that has the bytes has
## already done it. This module takes the decoded `JsonNode`s, so it can run in
## both ViewModel lanes with no compression library and no host reach.
##
## ## A span is a BYTE RANGE, and that is what makes support a real question
##
## Noir spans are byte offsets into the file, not line numbers. Resolving one
## needs the file's SOURCE TEXT, which `file_map` carries — and may not. So
## "can this artefact support a positional claim?" is not a fact about Noir, it
## is a fact about the artefact in hand:
##
##   * a span whose file has source text resolves to a line — positional
##   * a span whose file is missing from `file_map`, or whose entry has no
##     `source`, resolves to NOTHING. The file id is known and the line is not,
##     and a file without a line is not a position, nor a region in this
##     model's sense. It contributes no support at all.
##
## `ArtefactSupport` is therefore computed from the resolvable spans in THIS
## artefact, and `claimCeiling` does the rest. An artefact compiled without
## debug symbols yields `mfUnmapped` and the pane says so, which is the correct
## answer rather than a degraded one.
##
## ## THE THREE OVERCLAIMS THIS PRODUCER REFUSES
##
## 1. **An unlocated opcode is `mfUnmapped`, never `mfCompilerGenerated`.**
##    This is the subtle one. A prologue or a bounds check genuinely has no
##    user source, and the ladder has a rung that says exactly that — so it is
##    tempting. But `mfCompilerGenerated` is a POSITIVE claim ("there is no
##    source here"), and a Noir artefact does not distinguish a synthetic
##    opcode from one whose debug info was simply dropped. Both arrive here as
##    an absent `locations` entry. The artefact supports "I do not know", which
##    is `mfUnmapped`. Accordingly `marksCompilerGenerated` is FALSE for every
##    artefact this producer reads, and `validate` would reject the rung anyway
##    — belt and braces, because the field is the honest statement and the
##    rejection is only the enforcement.
##
## 2. **Two locations on one opcode is `mfMerged` over BOTH, never `mfExact`
##    over the first.** Noir emits a location list per opcode; after inlining
##    it has more than one entry. Picking one and calling it exact is precisely
##    the "confidently wrong mapping" §4 warns about, and it is the easiest bug
##    to write here because the first entry is right there. `adkExactOverMany`
##    exists for this moment.
##
## 3. **A fidelity is never emitted above the artefact's own ceiling** — and
##    that holds BY CONSTRUCTION rather than by a clamp, because support and
##    rung are read from the same resolved spans. See `produceAnchors`, which
##    states the invariant and records that the clamp which used to sit there
##    was unreachable. `validate` is the enforcement, from another module.
##
## ## Coalescing
##
## Consecutive opcodes with the same fidelity and the same sources become ONE
## anchor, because that is what an anchor is: a range of generated rows sharing
## a mapping. It also means a gap in the middle of a run splits the run, which
## is the behaviour `syncFromGenerated` needs in order to suspend over the gap
## rather than interpolate across it.

import std/[algorithm, json, strutils, tables]

import ./generated_code_anchors

type
  NoirSourceFile* = object
    ## One `file_map` entry, as far as this module cares.
    path*: string
    source*: string
      ## Empty when the artefact carried no text for this file. A span into
      ## such a file cannot be resolved to a line, and this module says so
      ## rather than guessing a line number.

  NoirSpan* = object
    ## One `{"span": {...}, "file": N}` location.
    fileId*: int
    startByte*: int
    endByte*: int

  NoirDebugArtefact* = object
    ## The decoded artefact, as much of it as anchoring needs.
    files*: Table[int, NoirSourceFile]
    locations*: Table[int, seq[NoirSpan]]
      ## Opcode index -> its location list. An opcode ABSENT from this table
      ## is unlocated; see overclaim 1.
    opcodeCount*: int
      ## How many generated rows the listing has. Taken from the caller rather
      ## than inferred from `locations`, because the highest LOCATED opcode is
      ## not the last opcode — trailing unlocated opcodes exist and must appear
      ## in the listing as unmapped rather than vanish from it.

  ArtefactReadOutcome* = enum
    aroOk
      ## The artefact parsed. This says nothing about whether it carried debug
      ## information — an artefact with no `debug_symbols` reads fine and
      ## yields `mfUnmapped`.
    aroUnparseable
      ## The text was not JSON, or the top level was not an object.
    aroMissingFileMap
      ## No `file_map`. Spans cannot be resolved to files at all.

  ArtefactRead* = object
    outcome*: ArtefactReadOutcome
    artefact*: NoirDebugArtefact
    detail*: string
      ## Non-empty whenever the outcome is not `aroOk`.

# ---------------------------------------------------------------------------
# Span resolution
# ---------------------------------------------------------------------------

proc lineStarts(source: string): seq[int] =
  ## Byte offset of the first character of each line. `result[0] == 0`.
  result = @[0]
  for i, c in source:
    if c == '\n':
      result.add i + 1

proc lineOf(starts: seq[int]; offset: int): int =
  ## 1-based line containing `offset`. Callers have already established that
  ## the offset is inside the file.
  ##
  ## `upperBound` returns the index of the first start GREATER than `offset`,
  ## which is exactly the 1-based line number of the line that contains it.
  result = starts.upperBound(offset)
  if result < 1:
    result = 1

proc resolve(a: NoirDebugArtefact; span: NoirSpan): (bool, SourceRegion) =
  ## `(resolved, region)`. Unresolved when the file is unknown to `file_map`,
  ## when its entry carried no source text, or when the span points outside
  ## the text — each of which is an artefact that cannot support a positional
  ## claim about this instruction, whatever Noir is capable of in general.
  if span.fileId notin a.files:
    return (false, SourceRegion())
  let f = a.files[span.fileId]
  if f.source.len == 0:
    return (false, SourceRegion())
  if span.startByte < 0 or span.startByte > f.source.len:
    return (false, SourceRegion())

  let starts = lineStarts(f.source)
  let endByte =
    if span.endByte < span.startByte: span.startByte
    elif span.endByte > f.source.len: f.source.len
    else: span.endByte
  # A span's end is EXCLUSIVE in Noir. `end == start` is an empty span, which
  # still sits on the start's line; otherwise the last byte covered is
  # `end - 1`, and using `end` itself would pull a span that stops exactly at a
  # newline onto the following line and report a region one line too tall.
  let lastByte = if endByte > span.startByte: endByte - 1 else: span.startByte
  (true, SourceRegion(
    path: f.path,
    startLine: lineOf(starts, span.startByte),
    endLine: lineOf(starts, lastByte)))

# ---------------------------------------------------------------------------
# Support
# ---------------------------------------------------------------------------

proc supportOf*(a: NoirDebugArtefact): ArtefactSupport =
  ## What THIS artefact can support, measured from its resolvable spans.
  ##
  ## `marksCompilerGenerated` is unconditionally false; see overclaim 1 in the
  ## header. It is a field about the artefact's expressiveness, and no Noir
  ## artefact distinguishes a synthetic opcode from one with dropped debug
  ## info.
  result = ArtefactSupport(
    hasSourcePositions: false,
    hasSourceRegions: false,
    hasInliningRecords: false,
    marksCompilerGenerated: false)

  for _, spans in a.locations:
    if spans.len >= 2:
      result.hasInliningRecords = true
    for s in spans:
      let (okResolved, region) = a.resolve(s)
      if not okResolved:
        continue
      result.hasSourceRegions = true
      if region.startLine == region.endLine:
        # A span confined to one line is what supports a POSITIONAL claim.
        result.hasSourcePositions = true

# ---------------------------------------------------------------------------
# Anchors
# ---------------------------------------------------------------------------

proc sameSources(a, b: seq[SourceRegion]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].path != b[i].path or a[i].startLine != b[i].startLine or
        a[i].endLine != b[i].endLine:
      return false
  true

proc rungFor(a: NoirDebugArtefact; opcode: int):
             (MappingFidelity, seq[SourceRegion]) =
  ## The rung this opcode's own evidence supports, before the ceiling clamp.
  if opcode notin a.locations:
    # Overclaim 1: unlocated is UNKNOWN, not "known to have no source".
    return (mfUnmapped, @[])

  var regions: seq[SourceRegion] = @[]
  for s in a.locations[opcode]:
    let (okResolved, region) = a.resolve(s)
    if okResolved:
      regions.add region

  if regions.len == 0:
    (mfUnmapped, @[])
  elif regions.len >= 2:
    # Overclaim 2: every contributing source is carried, none is elected.
    (mfMerged, regions)
  elif regions[0].startLine == regions[0].endLine:
    (mfExact, regions)
  else:
    (mfCoarse, regions)

proc produceAnchors*(a: NoirDebugArtefact):
                     (seq[MappingAnchor], ArtefactSupport) =
  ## The producer. Every generated row in `0 ..< opcodeCount` is covered by
  ## exactly one anchor, so the listing has no row whose fidelity is undefined
  ## — a row absent from the anchor set would read as a gap and suspend
  ## synchronisation for a reason that is not true of it.
  ##
  ## ## Overclaim 3 is prevented by CONSTRUCTION, not by a clamp
  ##
  ## There was a clamp here — emit `min(naturalRung, ceiling)`. It was
  ## unreachable, and a mutation arm proved it: removing it entirely changed
  ## no result, because `supportOf` and `rungFor` read THE SAME resolved
  ## spans. Every rung sets the support that admits it:
  ##
  ##   a single-line resolvable span  -> `mfExact`  and `hasSourcePositions`
  ##                                     -> ceiling `mfExact`
  ##   a multi-line resolvable span   -> `mfCoarse` and `hasSourceRegions`
  ##                                     -> ceiling at least `mfCoarse`
  ##   two or more resolvable spans   -> `mfMerged`, and each of them also
  ##                                     set `hasSourceRegions`
  ##                                     -> ceiling at least `mfCoarse`
  ##                                        > `mfMerged`
  ##   nothing resolvable             -> `mfUnmapped`, the floor
  ##
  ## So the natural rung is never above the ceiling, and dead code carrying a
  ## comment about the overclaim it prevents is a worse defence than the
  ## invariant written down. The ENFORCEMENT is `validate`, which is a
  ## different module and does check the ceiling — the suite asserts it comes
  ## back clean over every artefact shape, so if a future edit breaks the
  ## coupling above, that is what fails.
  let support = supportOf(a)
  var anchors: seq[MappingAnchor] = @[]

  for opcode in 0 ..< a.opcodeCount:
    let (fidelity, sources) = a.rungFor(opcode)

    if anchors.len > 0 and anchors[^1].fidelity == fidelity and
        sameSources(anchors[^1].sources, sources) and
        anchors[^1].generatedLast == opcode - 1:
      anchors[^1].generatedLast = opcode
    else:
      anchors.add MappingAnchor(
        generatedFirst: opcode,
        generatedLast: opcode,
        fidelity: fidelity,
        sources: sources,
        count: ExecutedCount(value: 0, provenance: cpNone))

  (anchors, support)

# ---------------------------------------------------------------------------
# Reading the artefact JSON
# ---------------------------------------------------------------------------

proc readFileMap(node: JsonNode; into: var Table[int, NoirSourceFile]) =
  if node.isNil or node.kind != JObject:
    return
  for key, entry in node:
    var id: int
    try:
      id = parseInt(key)
    except CatchableError:
      continue
    if entry.kind != JObject:
      continue
    var f = NoirSourceFile()
    if entry.hasKey("path") and entry["path"].kind == JString:
      f.path = entry["path"].getStr
    if entry.hasKey("source") and entry["source"].kind == JString:
      f.source = entry["source"].getStr
    into[id] = f

proc readLocations(node: JsonNode; into: var Table[int, seq[NoirSpan]]) =
  if node.isNil or node.kind != JObject:
    return
  for key, entry in node:
    var opcode: int
    try:
      opcode = parseInt(key)
    except CatchableError:
      continue
    if entry.kind != JArray:
      continue
    var spans: seq[NoirSpan] = @[]
    for loc in entry:
      if loc.kind != JObject or not loc.hasKey("span"):
        continue
      let span = loc["span"]
      if span.kind != JObject:
        continue
      var s = NoirSpan(fileId: -1, startByte: 0, endByte: 0)
      if loc.hasKey("file") and loc["file"].kind == JInt:
        s.fileId = loc["file"].getInt
      if span.hasKey("start") and span["start"].kind == JInt:
        s.startByte = span["start"].getInt
      if span.hasKey("end") and span["end"].kind == JInt:
        s.endByte = span["end"].getInt
      spans.add s
    # An opcode whose entry is an EMPTY list is recorded as present-with-no-
    # spans rather than dropped, so it reaches `rungFor` and becomes
    # `mfUnmapped` there by the same path as a resolvable-but-unresolved span.
    into[opcode] = spans

proc readArtefact*(fileMap: JsonNode; debugSymbols: JsonNode;
                   opcodeCount: int): ArtefactRead =
  ## Build the artefact from the two decoded nodes.
  ##
  ## `debugSymbols` is the decompressed per-circuit node — either the object
  ## with a `locations` key, or an array of them, in which case the FIRST
  ## circuit is read. Multi-circuit programs are out of scope and saying so
  ## beats silently merging opcode indices from different circuits, which
  ## would produce anchors that are confidently wrong in exactly §4's sense.
  var artefact = NoirDebugArtefact(
    files: initTable[int, NoirSourceFile](),
    locations: initTable[int, seq[NoirSpan]](),
    opcodeCount: max(opcodeCount, 0))

  if fileMap.isNil or fileMap.kind != JObject:
    return ArtefactRead(outcome: aroMissingFileMap, artefact: artefact,
      detail: "artefact has no file_map object; spans cannot be resolved to " &
        "files, so no positional claim is available from it")

  readFileMap(fileMap, artefact.files)

  var circuit = debugSymbols
  if not circuit.isNil and circuit.kind == JArray:
    circuit = if circuit.len > 0: circuit[0] else: nil
  if not circuit.isNil and circuit.kind == JObject and
      circuit.hasKey("locations"):
    readLocations(circuit["locations"], artefact.locations)

  ArtefactRead(outcome: aroOk, artefact: artefact, detail: "")

proc readArtefactJson*(text: string; opcodeCount: int): ArtefactRead =
  ## Parse a whole compile artefact and read it.
  ##
  ## The `except` is BARE on purpose. `CONTRIBUTING.md`, "Code compiled for
  ## both backends": on the C backend `parseJson` raises `JsonParsingError`,
  ## but on the JS backend it defers to `JSON.parse`, which throws a raw
  ## `SyntaxError` that no Nim exception type matches — so `except
  ## CatchableError` here would catch nothing and take down the renderer,
  ## which ships on `nim js`. This module is reachable from a pane that opens
  ## whatever artefact a project directory happens to contain, so malformed
  ## input is expected rather than exceptional.
  var parsed: JsonNode
  try:
    parsed = parseJson(text)
  except:
    return ArtefactRead(
      outcome: aroUnparseable,
      artefact: NoirDebugArtefact(
        files: initTable[int, NoirSourceFile](),
        locations: initTable[int, seq[NoirSpan]](),
        opcodeCount: 0),
      detail: "artefact is not valid JSON")

  if parsed.isNil or parsed.kind != JObject:
    return ArtefactRead(
      outcome: aroUnparseable,
      artefact: NoirDebugArtefact(
        files: initTable[int, NoirSourceFile](),
        locations: initTable[int, seq[NoirSpan]](),
        opcodeCount: 0),
      detail: "artefact top level is not a JSON object")

  let fileMap = if parsed.hasKey("file_map"): parsed["file_map"] else: nil
  let debugSymbols =
    if parsed.hasKey("debug_symbols"): parsed["debug_symbols"] else: nil
  readArtefact(fileMap, debugSymbols, opcodeCount)
