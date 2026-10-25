## test_plat68_cua_oracle.nim — PLAT-68 deliverable 5's first half (KL-3): THE
## CUA AND EMACS DATA ARE THEIR DOCUMENTS, ROW BY ROW, BOTH DIRECTIONS.
##
## CUA-Keymap.md §1: *"This table is the oracle … PLAT-68's suite parses every
## table in §3 and §4 whose header row begins `| Chord |` and compares it with
## the shipped CUA data, row by row, both directions."* Emacs-Keymap.md §1 says
## the same of its own tables. The grammar this file implements is the one §1
## publishes — alternatives, alternative pairs, platform clauses, the `when`
## abbreviations — so a reader can re-derive any row the suite reads.
##
## WHAT IS COMPARED. Each table row becomes one or more BINDING TUPLES: the
## normalised chord sequence (`key_names.normalizeChordSequence`, the function
## a user's configuration goes through), the operation, the `when` with its
## abbreviations expanded and printed canonically (`when_expr.canonicalWhen`,
## so `ro || dl` and the data's parenthesised spelling are one condition),
## and the platform set. The shipped data (`cua_keymap.CuaRows`,
## `emacs_keymap.EmacsRows`) becomes tuples the same way, and the two SETS must
## be equal. A document row with no data row is a missing binding; a data row
## with no document row is an undocumented one; both are named.
##
## THE POPULATION IS EVERY TABLE (PLAT-68 Phase B). CUA's §3.1 – §3.9 and §4
## (and §3.10's fallbacks, which this suite checks by RESOLUTION for the
## editor's and by presence for the rest, as §3.10's own reading rule says),
## Emacs's §3.1 – §3.12. The cardinalities are asserted, so a table that lost
## a row is red rather than a smaller equality.
##
## The second half of KL-3 — the document's agreement with VS Code — is
## `ci/test/cua-keymap-extractor.sh`, in the lint lane; it needs VS Code's
## sources and a network fetch, which a unit suite on three backends must not.
##
## ## No mocks
## The published documents (`staticRead`, through `test_support/spec_documents`,
## at the path `CT_SPECS_DIR` or the sibling checkout gives) and the shipped
## tables. A missing document is a compile error naming its path.

import std/[algorithm, sequtils, strutils, unittest]

import ../../editing_core
import ../../../test_support/spec_documents

proc canonicalWhen(text: string): string =
  ## `text` in `$`'s canonical spelling, or the text itself when it does not
  ## parse (so a comparison against it fails visibly).
  let p = parseWhen(text)
  if p.ok: $p.expr else: text

const ExpectedAssertions = 39

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  CuaDoc = specDocument("GUI/CUA-Keymap.md")
  EmacsDoc = specDocument("GUI/Emacs-Keymap.md")

  Writable = "editorTextFocus && !editorReadOnly"
  Inactive = "editorTextFocus && editorMode != visual"
  Active = "editorTextFocus && editorMode == visual"
  Ro = "productMode == debug && editorFocus && editorReadOnly && !textInputFocus"
  Dl = "productMode == debug && listFocus && !textInputFocus"
  Inp = "textInputFocus && !editorTextFocus"

  CuaSections = ["3.1", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8",
                 "3.9", "4"]
  EmacsSections = ["3.1", "3.2", "3.3", "3.4", "3.5", "3.6", "3.7", "3.8",
                   "3.9", "3.10", "3.11", "3.12"]
  ExpectedCuaTuples = 314
    ## The binding tuples CUA-Keymap.md §3.1 – §3.9 and §4 publish (their
    ## legacy fallbacks are §3.10's), counted from the document on 2026-10-12
    ## (293, then +10 for §3.8's program-menu rows: `Alt`, `` Alt+` ``, `F10`
    ## in Edit mode and the seven mnemonics; +2 for §3.7's web Run and
    ## Export; +1 for §3.7's `Alt+1`, the low-level view, kept from §5;
    ## +2 for §3.7's `F4` / `Shift+F4`, the search results, PLAT-57;
    ## +3 for §3.7's `Alt+C` / `Alt+W` / `Alt+R` in Find in Files' field —
    ## the `Alt+C` pane-focus row and §3.8's mnemonics split by the field's
    ## `when`, their tuples unchanged in number; +2 for §3.6's `Left` /
    ## `Right` on the output panes, `view.scroll-left` / `-right`, PLAT-70;
    ## +1 for §3.6's `Ctrl+K Ctrl+I`, `list.show-detail`, PLAT-70 Part B).
  ExpectedEmacsTuples = 190
    ## 188 until PLAT-70 Part C moved isearch's `Ctrl+W` (§3.9) and `Alt+S .`
    ## (§3.6) into the oracle (`Ctrl+G` and `Enter` changed operation only).
    ## Emacs-Keymap.md §3.1 – §3.12's (+1: `` Alt+` ``, `tmm-menubar`; +1:
    ## §3.8's `Enter` in the read-only Debug editor, the tracepoint editor;
    ## +2: §3.6's `Alt+G N` / `Alt+G P`, `next-error` / `previous-error`;
    ## +3: §3.6's `Alt+C` / `Alt+W` / `Alt+R` in Find in Files' field; +2:
    ## §3.7's `Ctrl+X <` / `Ctrl+X >` on the output panes, PLAT-70; +1:
    ## §3.12's `Ctrl+H .`, `list.show-detail`, PLAT-70 Part B).

type
  Tuple = object
    chords: string
    operation: string
    whenText: string
    platforms: string
      ## `*` for every platform, else the sorted names joined by `,`.

func `$`(t: Tuple): string =
  t.chords & " -> " & t.operation & " [" & t.whenText & "] @" & t.platforms

proc codeSpans(cell: string): seq[string] =
  ## `x` and ``x`` spans, in order.
  result = @[]
  var i = 0
  while i < cell.len:
    if cell[i] == '`':
      var ticks = 1
      while i + ticks < cell.len and cell[i + ticks] == '`': inc ticks
      let fence = repeat('`', ticks)
      let close = cell.find(fence, i + ticks)
      if close < 0: break
      result.add cell[i + ticks ..< close].strip()
      i = close + ticks
    else:
      inc i

proc cellsOf(line: string): seq[string] =
  ## A markdown row as cells; `\|` is an escaped bar inside a cell.
  var t = line.strip()
  if t.startsWith("|"): t = t[1 .. ^1]
  if t.endsWith("|"): t = t[0 ..< t.len - 1]
  result = @[]
  var cur = ""
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len and t[i + 1] == '|':
      cur.add '|'
      i += 2
      continue
    if t[i] == '|':
      result.add cur.strip()
      cur = ""
    else:
      cur.add t[i]
    inc i
  result.add cur.strip()

proc tableRows(doc: string; sections: openArray[string]): seq[seq[string]] =
  ## The data rows of every `| Chord |` table under a `### <n>` heading in
  ## `sections`.
  result = @[]
  var section = ""
  var inTable = false
  for line in doc.splitLines():
    if line.startsWith("### "):
      section = line[4 .. ^1].split(' ')[0]
      inTable = false
      continue
    if line.startsWith("## "):
      # A top-level section is a section too (`## 4. The debugger layer`).
      let head = line[3 .. ^1].split(' ')[0].strip(chars = {'.'})
      section = if head.len > 0 and head[0] in {'0'..'9'}: head else: ""
      inTable = false
      continue
    if not line.startsWith("|"):
      inTable = false
      continue
    let cells = cellsOf(line)
    if not inTable:
      inTable = cells.len > 0 and cells[0] == "Chord"
      continue
    if line.replace("|", "").strip().allIt(it in {'-', ':', ' '}):
      continue
    if section notin sections: continue
    result.add cells

proc expandWhen(cell: string): string =
  ## The cell's condition, its abbreviations expanded (each in parentheses,
  ## so `ro || dl` stays one disjunction of two conjunctions), canonical.
  let spans = codeSpans(cell)
  if spans.len == 0: return ""
  var w = spans[0]
  if w == "—": return ""
  for (abbrev, full) in [("writable", Writable), ("inactive", Inactive),
                         ("active", Active), ("ro", Ro), ("dl", Dl),
                         ("inp", Inp)]:
    var words = w.split(' ')
    for i, word in words:
      if word == abbrev: words[i] = "(" & full & ")"
    w = words.join(" ")
  canonicalWhen(w)

const AllPlatforms = "*"

proc platformName(p: string): string =
  case p.toLowerAscii
  of "linux": "linux"
  of "windows": "windows"
  of "macos", "mac": "mac"
  else: "?" & p

proc positionsOf(text: string): seq[seq[string]] =
  ## §1's grammar: `A / B` positions, `A, B` alternatives at one position,
  ## `A / B, C / D` two alternative pairs.
  let parts = text.split(", `")
  var allPairs = parts.len > 1
  for p in parts:
    if " / " notin p: allPairs = false
  if allPairs:
    result = @[]
    for k, p in parts:
      let piece = if k == 0: p else: "`" & p
      for i, alts in positionsOf(piece):
        if i < result.len: result[i].add alts
        else: result.add alts
    return
  result = @[]
  for group in text.split(" / "):
    var alts: seq[string] = @[]
    for span in codeSpans(group):
      alts.add normalizeChordSequence(span)
    if alts.len > 0: result.add alts

proc tuplesOfRow(cells: seq[string]): seq[Tuple] =
  let chordCell = cells[0]
  let ops = codeSpans(cells[2])
  let whenText = expandWhen(cells[3])
  # (platforms, positions) pieces of the chord cell.
  var pieces: seq[(string, seq[seq[string]])] = @[]
  let clauses = chordCell.split(" · ")
  var base = clauses[0].strip()
  # `*Linux*` or `*Linux, Windows*` before the chord: the row is ONLY those
  # platforms' (its clauses' grammar, without `also`).
  var only: seq[string] = @[]
  if base.startsWith("*"):
    let close = base.find('*', 1)
    only = base[1 ..< close].split(',').mapIt(platformName(it.strip()))
    base = base[close + 1 .. ^1].strip()
  let basePositions = positionsOf(base)
  if only.len > 0:
    for n in only:
      pieces.add (n, basePositions)
  else:
    var overridden: seq[string] = @[]
    for c in clauses[1 .. ^1]:
      let close = c.find('*', 1)
      let names = c[1 ..< close].split(',').mapIt(platformName(it.strip()))
      var rest = c[close + 1 .. ^1].strip()
      let also = rest.startsWith("also ")
      if also: rest = rest[5 .. ^1]
      for n in names:
        if not also: overridden.add n
        pieces.add (n, positionsOf(rest))
    var basePlatforms: seq[string] = @[]
    for n in ["linux", "mac", "windows"]:
      if n notin overridden: basePlatforms.add n
    let bp = if basePlatforms.len == 3: AllPlatforms
             else: basePlatforms.join(",")
    pieces.add (bp, basePositions)
  result = @[]
  for (plats, positions) in pieces:
    for k, alts in positions:
      let op = if k < ops.len: ops[k] else: ops[^1]
      for a in alts:
        result.add Tuple(chords: a, operation: op, whenText: whenText,
                         platforms: plats)

proc platformsText(ps: set[PlatformKind]): string =
  if ps == {} or ps == {pkLinux, pkWindows, pkMac}: return AllPlatforms
  var names: seq[string] = @[]
  for p in ps: names.add $p
  names.sort()
  names.join(",")

proc dataTuples(rows: seq[BaseRow]): seq[Tuple] =
  for r in rows:
    result.add Tuple(chords: normalizeChordSequence(r.chords),
                     operation: r.operation,
                     whenText: canonicalWhen(r.whenText),
                     platforms: platformsText(r.platforms))

proc mergePlatforms(ts: seq[Tuple]): seq[Tuple] =
  ## One binding on two platforms is one tuple: `· *Linux, Windows* also X`
  ## and a data row with `platforms: {pkLinux, pkWindows}` are the same claim.
  result = @[]
  for t in ts:
    var merged = false
    for r in result.mitems:
      if r.chords == t.chords and r.operation == t.operation and
         r.whenText == t.whenText:
        if r.platforms == AllPlatforms or t.platforms == AllPlatforms:
          r.platforms = AllPlatforms
        else:
          var names = (r.platforms.split(',') & t.platforms.split(',')).deduplicate
          names.sort()
          r.platforms = if names.len == 3: AllPlatforms else: names.join(",")
        merged = true
    if not merged: result.add t

proc specTuples(doc: string; sections: openArray[string]): seq[Tuple] =
  for cells in tableRows(doc, sections):
    result.add tuplesOfRow(cells)
  result = mergePlatforms(result)

proc sortedStrings(ts: seq[Tuple]): seq[string] =
  result = ts.mapIt($it)
  result.sort()

proc difference(a, b: seq[string]): seq[string] =
  for x in a:
    if x notin b: result.add x

suite "PLAT-68 KL-3: the CUA data is CUA-Keymap.md §3 – §4, both directions":
  let spec = specTuples(CuaDoc, CuaSections).sortedStrings
  let data = mergePlatforms(
    dataTuples(CuaRows).filterIt(it.whenText != "keyProtocol == legacy")).sortedStrings

  test "the document's tuples are counted":
    checkpoint("spec tuples: " & $spec.len)
    ck spec.len == ExpectedCuaTuples
    ck spec.deduplicate.len == spec.len

  test "every documented row is in the data":
    let missing = difference(spec, data)
    for m in missing: checkpoint("documented, not shipped: " & m)
    ck missing.len == 0

  test "every shipped row is documented":
    let extra = difference(data, spec)
    for m in extra: checkpoint("shipped, not documented: " & m)
    ck extra.len == 0
    ck data.len == spec.len

suite "PLAT-68 KL-3: §3.10's legacy fallbacks, read the way §3.10 says":
  proc legacyResolves(chords, op: string): bool =
    ## Whether `chords` resolves to `op` in the shipped CUA data under
    ## `keyProtocol == legacy`, on Linux, in a writable editor.
    var d = initEditingDocument("t", "a\nb\n", bkCua,
      delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                             keyProtocol: kpLegacy))
    let keys = chords.splitWhitespace()
    var now = 1_000'i64
    for i, k in keys:
      let r = resolveKey(d.state, keymapOf(bkCua).keymap, editScopeOf(d), k, now)
      if i < keys.len - 1:
        if r.kind != erPending: return false
        d.state.pending = r.pending
      else:
        return r.kind == erOperation and r.operation == vocabularyName(op)
      now += 1

  test "every fallback resolves under legacy, and every legacy row is in §3.10":
    var editorRows = 0
    var otherRows = 0
    var documented: seq[string] = @[]
    var inTable = false
    for line in CuaDoc.splitLines():
      if line.startsWith("| Operation | CUA chord | Legacy fallback"):
        inTable = true
        continue
      if inTable and not line.startsWith("|"): break
      if not inTable or line.startsWith("|---"): continue
      let cells = cellsOf(line)
      let ops = codeSpans(cells[0])
      if ops.len == 0: continue
      let fallbacks = positionsOf(cells[2])
      for k, op in ops:
        let fallback = fallbacks[min(k, fallbacks.len - 1)][0]
        documented.add fallback
        checkpoint("fallback " & fallback & " -> " & op)
        if op.startsWith("editor.") and not isCatalogued(op):
          inc editorRows
          ck legacyResolves(fallback, op)
        else:
          # A pane, palette or workbench operation: the fallback chord is
          # bound in the CUA data — to the operation, or (§3.10's
          # `Ctrl+PageDown`, "adjacent meaning, already bound") to its
          # neighbour — so the operation's place is reachable in legacy.
          inc otherRows
          ck CuaRows.anyIt(normalizeChordSequence(it.chords) == fallback)
    checkpoint("editor fallbacks: " & $editorRows & ", others: " & $otherRows)
    ck editorRows == 12
    ck otherRows == 5
    for r in CuaRows:
      if r.whenText == "keyProtocol == legacy":
        checkpoint("legacy row " & r.chords)
        ck normalizeChordSequence(r.chords) in documented

suite "PLAT-68 KL-3: the Emacs data is Emacs-Keymap.md §3, both directions":
  let spec = specTuples(EmacsDoc, EmacsSections).sortedStrings
  let data = mergePlatforms(dataTuples(EmacsRows)).sortedStrings

  test "the document's tuples are counted":
    checkpoint("spec tuples: " & $spec.len)
    ck spec.len == ExpectedEmacsTuples

  test "every documented row is in the data, and every shipped row is documented":
    let missing = difference(spec, data)
    let extra = difference(data, spec)
    for m in missing: checkpoint("documented, not shipped: " & m)
    for m in extra: checkpoint("shipped, not documented: " & m)
    ck missing.len == 0
    ck extra.len == 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
