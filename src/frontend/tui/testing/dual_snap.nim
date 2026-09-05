## LAYER RULE — `src/frontend/tui/testing/` is TEST-ONLY infrastructure. It is
## neither `app/` (which may not touch a process or a terminal) nor `host/`
## (which may, and is the release binary's only door to those): it needs both
## capabilities and the shipped binary links none of it. Nothing under this
## directory is reachable from `main.nim`, and
## `src/frontend/tui/tests/test_tui_build_prerequisites.nim` walks the release
## entrypoint's resolved import closure on every run to keep that a fact.
##
## testing/dual_snap.nim — CTUI-2. One component tree, two tiers, one verdict.
##
## ## The claim this module exists to test
##
## `TerminalTestHarness` composites a tree into a `ScreenBuffer` and records six
## golden formats from it. Every one of those six is derived from THE SAME
## in-process model that produced the ANSI, so Tier 1 cannot notice a
## disagreement between what the compositor thinks the screen is and what a
## terminal makes of the bytes it emitted. It will record and re-verify a wrong
## screen indefinitely.
##
## So: composite the tree in process, AND spawn a child that composites the same
## tree and writes the same bytes into a real pty, parse that with a real
## terminal state machine (libvterm), write both as six-format snapshot
## directories, and compare them cell for cell.
##
## THIS IS NOT A FORMALITY. The first run of it found two defects and a third
## in the encoders, all in sibling libraries, all invisible to either tier
## alone:
##
##   1. `isonim-tui`'s compositor never put a ghost cell in the composited
##      buffer. `paintEntryOnto` skipped the width-0 trailing half of every
##      wide glyph, leaving the buffer's initial `spaceCell()` (rune ' ',
##      width 1) in that column, so `encodeAnsi` wrote a REAL SPACE after every
##      wide glyph. Measured on "┌世界─┐" at 20x3: the buffer put `┐` at column
##      6 and the terminal put it at column 8 — one column of drift per wide
##      glyph, accumulating rightwards.
##   2. `nim-libvterm`'s `cellAt` raised `RangeDefect: value out of range:
##      4294967295` on the trailing half of any wide glyph. libvterm stamps
##      `chars[0] = (uint32_t)-1` there (`vendor/libvterm/src/screen.c:191`) and
##      the wrapper turned it into a `Rune`. Every consumer that walks a whole
##      screen went down with it, TermAssert's snapshot encoders included, so a
##      CJK glyph was not merely mis-rendered at Tier 2 — it was unobservable.
##   3. `TermAssert`'s `renderPlain` emitted a space for that trailing half
##      while isonim-tui's `encodePlaintext` skips it, and its `renderCellmap`
##      did not encode `underline` at all, so a compositor that emits `CSI 4 m`
##      and one that does not produced byte-identical `cellmap.json`.
##   4. `nim-libvterm` LOST A GLYPH whenever a multi-byte UTF-8 sequence
##      straddled a `feed` boundary and the run it belonged to had begun on an
##      ASCII byte. libvterm holds five UTF-8 decoder instances and
##      `state.c:on_text` picks between `encoding[gl_set]` and `encoding_utf8`
##      per text run from the high bit of the run's FIRST byte, so the two
##      halves of a split sequence are decoded by two different instances: one
##      keeps the stranded `bytes_remaining`, the other emits U+FFFD for the
##      orphaned continuation bytes, and the stranded half then corrupts the
##      next ASCII-initial run as well. Measured: a 40x120 screen of
##      box-drawing glyphs fed in 4096-byte chunks — which is exactly what
##      TermAssert's `pump` does with a pty — lost 3 cells; at 1024-byte
##      chunks, 12. `nim-libvterm`'s `feed` now holds an incomplete trailing
##      sequence back and prepends it to the next call.
##
## All four are fixed upstream. They are recorded here because they are the
## argument for the milestone: four defects, in the two libraries every later
## golden is recorded through, none of which any Tier-1 assertion could have
## reddened, and the fourth of which had nothing to do with the compositor at
## all — it was in the OBSERVER, which is the half of a cross-tier comparison
## nobody thinks to distrust.
##
## ## What is compared, and what is not
##
## `plaintext.txt` and `cellmap.json`. `svg.svg` and `annotated.svg` are
## renderings OF the cellmap and add nothing; `ansi.ansi` legitimately differs,
## because Tier 2 observes post-parse state and reconstructs a stream from it
## rather than replaying the emission; `treedump.txt` is an element tree on one
## side and a cell dump on the other. Each of those is enumerated below as a
## named exclusion with the evidence that established it, and so is every other
## difference the comparison does not fail on.
##
## ## THE RULE ABOUT EXCLUSIONS
##
## An exclusion is a named `NamedExclusion` in `CrossTierExclusions` carrying
## the evidence that established it, and `CrossTierExclusionCount` is asserted
## by the suite so one cannot be added quietly. The comparison itself is never
## loosened: there is no tolerance, no "close enough", no whitespace-insensitive
## mode. A difference is either a defect or a named entry in that list.
##
## A canonicalisation is NOT an exclusion and is kept in a separate list,
## `CrossTierCanonicalisations`, because the distinction is the whole
## discipline: a canonicalisation maps two spellings of one fact onto one
## representation and still fails when the fact differs; an exclusion stops
## comparing something. Confusing the two is how a comparison quietly stops
## checking.

import std/[json, monotimes, os, osproc, strutils, times, unicode]

import isonim_tui
import term_assert

# ---------------------------------------------------------------------------
# Canonical screen model
# ---------------------------------------------------------------------------
#
# Neither tier's cell type is a superset of the other's, and neither tier's
# `cellmap.json` dialect is the other's, so the comparison runs over a third
# representation both are projected onto. The projection is total and lossless
# for every field both tiers can express; what neither or only one can express
# is enumerated in `CrossTierExclusions`.

type
  CanonColorKind* = enum
    cckDefault, cckIndexed, cckRgb

  CanonColor* = object
    ## Tier 1 has a fourth colour kind, `ckAnsi`; see the `ansi16-is-indexed`
    ## canonicalisation below for why it lands here as `cckIndexed`.
    kind*: CanonColorKind
    idx*: int
    r*, g*, b*: int

  CanonAttr* = enum
    canBold, canItalic, canReverse, canBlink, canConceal, canStrike, canDim

  CanonUnderline* = enum
    cunNone, cunSingle, cunDouble, cunCurly, cunDotted, cunDashed

  CanonCell* = object
    rune*: string
      ## The cell's text, as UTF-8. A blank cell is a single space in BOTH
      ## dialects (each encoder writes `" "` for rune 0), so no normalisation
      ## is needed here.
    width*: int  ## 0 = the trailing half of a wide glyph, 1 narrow, 2 wide.
    fg*, bg*: CanonColor
    attrs*: set[CanonAttr]
    underline*: CanonUnderline

  CanonScreen* = object
    rows*, cols*: int
    dialect*: string  ## "tier1-isonim-tui" or "tier2-libvterm".
    cells*: seq[seq[CanonCell]]

  SnapshotDialect* = enum
    sdTier1  ## isonim-tui `testing/snapshot/cellmap.encodeCellMap`
    sdTier2  ## TermAssert `term_assert/snapshot.renderCellmap`

  DualSnapError* = object of CatchableError
    ## Anything that stops the comparison from happening at all — a snapshot
    ## file missing, a cellmap the parser will not guess at, a child that never
    ## finished a frame. Never folded into "the screens differ": a comparison
    ## that did not run is not a comparison that passed.

# ---------------------------------------------------------------------------
# Named exclusions and canonicalisations
# ---------------------------------------------------------------------------

type
  ExclusionScope* = enum
    esFormat         ## a whole snapshot file is not compared
    esNormalisation  ## a byte-level normalisation applied before comparing
    esField          ## one field of the cell model is not compared

  NamedExclusion* = object
    name*: string
    scope*: ExclusionScope
    subject*: string
    justification*: string
    evidence*: string
      ## HOW IT WAS ESTABLISHED, not why it sounds reasonable. A file and a
      ## line, or a measurement, or both.

  Canonicalisation* = object
    ## Two spellings of one fact, mapped onto one representation. Listed apart
    ## from the exclusions on purpose: a canonicalisation still FAILS when the
    ## fact differs.
    name*: string
    subject*: string
    mapping*: string
    evidence*: string

const
  CrossTierExclusions*: seq[NamedExclusion] = @[
    NamedExclusion(
      name: "ansi-is-emission-not-state",
      scope: esFormat,
      subject: "ansi.ansi",
      justification:
        "Tier 1's ansi.ansi IS the byte stream the compositor emitted; Tier " &
        "2's is a stream RECONSTRUCTED from post-parse screen state. They " &
        "describe the same screen in two encodings and a byte comparison of " &
        "them would be a comparison of two encoders. The screen itself is " &
        "compared through cellmap.json, which carries every attribute the " &
        "ansi encoding would have carried.",
      evidence:
        "isonim-tui/src/isonim_tui/testing/snapshot/ansi.nim emits SGR " &
        "TRANSITIONS via text/ansi.renderSgr and only where the style " &
        "changes; TermAssert/src/term_assert/snapshot.nim renderAnsi emits a " &
        "full `CSI 0 m` reset plus the whole pen before EVERY cell. Measured " &
        "on the colour-depth app at 80x24: 2_265 bytes against 20_246."),
    NamedExclusion(
      name: "svg-and-annotated-are-cellmap-renderings",
      scope: esFormat,
      subject: "svg.svg, annotated.svg",
      justification:
        "Both files are drawings of the same cell grid cellmap.json already " &
        "carries, so a difference in either is either a difference the " &
        "cellmap comparison already reports or a difference in the drawing.",
      evidence:
        "The two SVG encoders disagree on things that are not screen state " &
        "at all: isonim-tui's svg.nim emits per-cell <rect> fills and a " &
        "font-size the theme picks, TermAssert's renderSvg emits an 8x16 " &
        "cell box with one <text> per non-blank cell and no rects. Neither " &
        "reads anything cellmap.json does not."),
    NamedExclusion(
      name: "treedump-is-a-different-subject",
      scope: esFormat,
      subject: "treedump.txt",
      justification:
        "Tier 1's treedump is the ELEMENT TREE with computed styles — a " &
        "structure that exists only in process. Tier 2 has no element tree " &
        "to dump and writes a cell-by-cell screen dump under the same " &
        "filename. The two files answer different questions.",
      evidence:
        "isonim-tui/src/isonim_tui/testing/snapshot/treedump.nim calls " &
        "introspection.dumpTree(compositor, root); " &
        "TermAssert/src/term_assert/snapshot.nim renderTreedump writes " &
        "\"Screen RxC\", the cursor, the title, and one '.'-or-rune line per " &
        "row."),
    NamedExclusion(
      name: "plaintext-trailing-newline",
      scope: esNormalisation,
      subject: "plaintext.txt",
      justification:
        "One encoder terminates the last row and the other separates rows. " &
        "That is a property of the two writers, not of the screen: every row " &
        "of content, including the last, is compared unchanged.",
      evidence:
        "isonim-tui/src/isonim_tui/testing/snapshot/plaintext.nim ends with " &
        "`lines.join(\"\\n\") & \"\\n\"`; " &
        "TermAssert/src/term_assert/snapshot.nim renderPlain appends '\\n' " &
        "only `if r + 1 < rows`. Both strip each row's trailing whitespace " &
        "with the same call, so nothing else about the text is normalised."),
    NamedExclusion(
      name: "dim-has-no-tier-2-representation",
      scope: esField,
      subject: "CanonAttr.canDim",
      justification:
        "libvterm's cell model has no dim bit, so Tier 2 cannot observe SGR " &
        "2 at all. Excluding the attribute is the only alternative to " &
        "asserting a difference that is a property of the observer rather " &
        "than of the screen. Every other attribute both tiers can express is " &
        "compared, and the suite asserts that a dim cell IS present in the " &
        "Tier-1 canon so this exclusion is exercised rather than " &
        "hypothetical.",
      evidence:
        "nim-libvterm/src/nim_libvterm/screen.nim: `CellAttr* = enum " &
        "caBold, caItalic, caBlink, caReverse, caConceal, caStrike` — no " &
        "dim member, and `cellAt` sets no such flag. Measured on the " &
        "colour-depth app at 80x24: Tier 1 reports attrs=[\"attrDim\"] at " &
        "(5,0) over an emitted `CSI 2;35 m`, Tier 2 reports attrs=[] at the " &
        "same cell with the foreground colour from the same SGR intact " &
        "(both fg=5)."),
    NamedExclusion(
      name: "cellmap-tier-private-fields",
      scope: esField,
      subject: "nodeId (Tier 1); hyperlinkId, imageRef (Tier 2)",
      justification:
        "Each of these exists in exactly one dialect, so there is nothing to " &
        "compare it against. nodeId is additionally a constant: isonim-tui " &
        "writes 0 for every cell. A later milestone that asserts on OSC 8 " &
        "hyperlinks must assert on them at Tier 2 directly — this comparison " &
        "says nothing about them, which is why the gap is written down.",
      evidence:
        "isonim-tui/src/isonim_tui/testing/snapshot/cellmap.nim writes " &
        "`\\\"nodeId\\\":0` literally, with a comment saying the projection " &
        "lands in M3+; TermAssert's renderCellmap writes hyperlinkId and " &
        "imageRef and no nodeId.")]

  CrossTierExclusionCount* = 6
    ## Asserted by the suite. Adding an exclusion without updating this — and
    ## therefore without a reviewer seeing the number move — fails the run.

  CrossTierCanonicalisations*: seq[Canonicalisation] = @[
    Canonicalisation(
      name: "ansi16-is-indexed",
      subject: "CanonColor",
      mapping: "Tier 1 `ckAnsi n` and Tier 2 `ckIndexed n` both become " &
               "cckIndexed(n) for n in 0..15.",
      evidence:
        "isonim-tui/src/isonim_tui/text/ansi.nim fgParams renders ckAnsi n " &
        "as SGR 30+n (n<8) or 90+(n-8); libvterm reports exactly that as " &
        "VTERM_COLOR_INDEXED with idx n. Measured: a `color: red` row emits " &
        "`CSI 31 m` and Tier 2 reads idx=1, and `bright_cyan` emits " &
        "`CSI 96 m` and Tier 2 reads idx=14. The comparison still fails if " &
        "the INDEX differs."),
    Canonicalisation(
      name: "underline-is-a-field-on-one-side",
      subject: "CanonCell.underline",
      mapping: "Tier 1's `attrUnderline` in `attrs` and Tier 2's " &
               "`underline` style field both become CanonCell.underline; " &
               "Tier 1 can only express `single`.",
      evidence:
        "isonim-tui/src/isonim_tui/cells.nim carries attrUnderline in " &
        "`set[Attr]`; nim-libvterm/src/nim_libvterm/screen.nim carries " &
        "`underline*: UnderlineStyle` outside `attrs` because libvterm's is " &
        "a 2-bit style rather than a flag. Measured on the colour-depth app " &
        "at 80x24, cell (3,0) — the `underline` row: Tier 1 writes " &
        "attrs=[\"attrUnderline\"], Tier 2 writes attrs=[] with " &
        "underline=\"usSingle\". The same cell, and it compares equal only " &
        "because of this mapping — while dropping the underline from either " &
        "side still fails, as `the underline styles differ`.")]

proc renderExclusions*(): string =
  ## The exclusion register, as text.
  ##
  ## `report()` checkpoints it beside a divergence, which is where a reader of
  ## a FAILURE wants it; the suite additionally `echo`s it, because a reader of
  ## a GREEN run is the one who most needs to see what the comparison stopped
  ## checking, and `std/unittest` flushes checkpoints only from `fail()`.
  var parts: seq[string] = @[]
  parts.add "cross-tier comparison: " & $CrossTierExclusions.len &
            " named exclusion(s), " & $CrossTierCanonicalisations.len &
            " canonicalisation(s)"
  for e in CrossTierExclusions:
    parts.add "  EXCLUDED [" & $e.scope & "] " & e.name & " — " & e.subject
    parts.add "    why: " & e.justification
    parts.add "    evidence: " & e.evidence
  for c in CrossTierCanonicalisations:
    parts.add "  CANONICALISED " & c.name & " — " & c.subject
    parts.add "    mapping: " & c.mapping
    parts.add "    evidence: " & c.evidence
  parts.join("\n")

const ComparedAttrs* = {canBold, canItalic, canReverse, canBlink, canConceal,
                        canStrike}
  ## `canDim` is absent, and it is the ONLY absentee — see the
  ## `dim-has-no-tier-2-representation` exclusion. Written as the set that IS
  ## compared rather than as the one that is not, so a new attribute is
  ## excluded only by someone editing this line.

# ---------------------------------------------------------------------------
# cellmap.json parsing — two dialects, one canon
# ---------------------------------------------------------------------------

proc parseTier1Color(s: string): CanonColor =
  ## "default" | "ansi:N" | "idx:N" | "rgb:R,G,B"
  if s == "default": return CanonColor(kind: cckDefault)
  if s.startsWith("ansi:"):
    return CanonColor(kind: cckIndexed, idx: parseInt(s["ansi:".len .. ^1]))
  if s.startsWith("idx:"):
    return CanonColor(kind: cckIndexed, idx: parseInt(s["idx:".len .. ^1]))
  if s.startsWith("rgb:"):
    let parts = s["rgb:".len .. ^1].split(',')
    if parts.len != 3:
      raise newException(DualSnapError,
        "tier-1 cellmap: malformed rgb colour '" & s & "'")
    return CanonColor(kind: cckRgb, r: parseInt(parts[0]),
                      g: parseInt(parts[1]), b: parseInt(parts[2]))
  raise newException(DualSnapError,
    "tier-1 cellmap: unrecognised colour '" & s & "'")

proc parseTier2Color(n: JsonNode): CanonColor =
  ## {"kind":"default"} | {"kind":"indexed","idx":N} | {"kind":"rgb",...}
  if n.kind != JObject or not n.hasKey("kind"):
    raise newException(DualSnapError,
      "tier-2 cellmap: colour is not an object with a `kind`: " & $n)
  case n["kind"].getStr()
  of "default": CanonColor(kind: cckDefault)
  of "indexed": CanonColor(kind: cckIndexed, idx: n["idx"].getInt())
  of "rgb": CanonColor(kind: cckRgb, r: n["r"].getInt(), g: n["g"].getInt(),
                       b: n["b"].getInt())
  else:
    raise newException(DualSnapError,
      "tier-2 cellmap: unrecognised colour kind '" & n["kind"].getStr() & "'")

proc parseTier1Attrs(n: JsonNode; cell: var CanonCell) =
  for a in n:
    case a.getStr()
    of "attrBold": cell.attrs.incl canBold
    of "attrItalic": cell.attrs.incl canItalic
    of "attrUnderline": cell.underline = cunSingle
    of "attrStrike": cell.attrs.incl canStrike
    of "attrReverse": cell.attrs.incl canReverse
    of "attrDim": cell.attrs.incl canDim
    of "attrBlink": cell.attrs.incl canBlink
    of "attrInvisible": cell.attrs.incl canConceal
    else:
      # LOUD, not ignored. A new `Attr` member that fell through here would
      # silently drop out of the comparison, which is the class of quiet
      # weakening this whole module is written against.
      raise newException(DualSnapError,
        "tier-1 cellmap: unmapped attribute '" & a.getStr() &
        "' — add it to parseTier1Attrs and to ComparedAttrs")

proc parseTier2Attrs(n: JsonNode; cell: var CanonCell) =
  for a in n:
    case a.getStr()
    of "bold": cell.attrs.incl canBold
    of "italic": cell.attrs.incl canItalic
    of "blink": cell.attrs.incl canBlink
    of "reverse": cell.attrs.incl canReverse
    of "conceal": cell.attrs.incl canConceal
    of "strike": cell.attrs.incl canStrike
    else:
      raise newException(DualSnapError,
        "tier-2 cellmap: unmapped attribute '" & a.getStr() &
        "' — add it to parseTier2Attrs and to ComparedAttrs")

proc parseTier2Underline(s: string): CanonUnderline =
  case s
  of "usNone": cunNone
  of "usSingle": cunSingle
  of "usDouble": cunDouble
  of "usCurly": cunCurly
  of "usDotted": cunDotted
  of "usDashed": cunDashed
  else:
    raise newException(DualSnapError,
      "tier-2 cellmap: unrecognised underline style '" & s & "'")

proc detectDialect(root: JsonNode): SnapshotDialect =
  ## By the SHAPE of a colour, not by a filename or a directory name: the two
  ## directories are deliberately interchangeable, so which tier wrote one has
  ## to be read out of the file itself.
  if root.kind != JObject or not root.hasKey("cells"):
    raise newException(DualSnapError, "cellmap.json has no `cells` array")
  let cells = root["cells"]
  if cells.kind != JArray or cells.len == 0 or cells[0].kind != JArray or
     cells[0].len == 0:
    raise newException(DualSnapError, "cellmap.json `cells` is empty")
  let sample = cells[0][0]
  if not sample.hasKey("fg"):
    raise newException(DualSnapError, "cellmap.json cell has no `fg`")
  case sample["fg"].kind
  of JString: sdTier1
  of JObject: sdTier2
  else:
    raise newException(DualSnapError,
      "cellmap.json: `fg` is neither a Tier-1 string nor a Tier-2 object")

proc parseCellmap*(text: string): CanonScreen =
  ## Project either dialect of `cellmap.json` onto the canonical screen.
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    raise newException(DualSnapError, "cellmap.json does not parse: " & e.msg)
  let dialect = detectDialect(root)
  result.dialect = (if dialect == sdTier1: "tier1-isonim-tui"
                    else: "tier2-libvterm")
  result.rows = root["rows"].getInt()
  result.cols = root["cols"].getInt()
  result.cells = @[]
  for rowNode in root["cells"]:
    var row: seq[CanonCell] = @[]
    for cellNode in rowNode:
      var cell = CanonCell(rune: cellNode["rune"].getStr(),
                           width: cellNode["width"].getInt(),
                           underline: cunNone)
      case dialect
      of sdTier1:
        cell.fg = parseTier1Color(cellNode["fg"].getStr())
        cell.bg = parseTier1Color(cellNode["bg"].getStr())
        parseTier1Attrs(cellNode["attrs"], cell)
      of sdTier2:
        cell.fg = parseTier2Color(cellNode["fg"])
        cell.bg = parseTier2Color(cellNode["bg"])
        parseTier2Attrs(cellNode["attrs"], cell)
        if not cellNode.hasKey("underline"):
          raise newException(DualSnapError,
            "tier-2 cellmap has no `underline` key — the TermAssert " &
            "snapshot encoder that writes it is older than this comparison")
        cell.underline = parseTier2Underline(cellNode["underline"].getStr())
      row.add cell
    result.cells.add row
  if result.cells.len != result.rows:
    raise newException(DualSnapError,
      "cellmap.json declares " & $result.rows & " rows and holds " &
      $result.cells.len)

# ---------------------------------------------------------------------------
# Divergence
# ---------------------------------------------------------------------------

type
  DivergenceKind* = enum
    dkGeometry
    dkCell
    dkPlaintextRow

  Divergence* = object
    kind*: DivergenceKind
    row*, col*: int
    tier1*, tier2*: string
    summary*: string

proc describeColor(c: CanonColor): string =
  case c.kind
  of cckDefault: "default"
  of cckIndexed: "indexed:" & $c.idx
  of cckRgb: "rgb:" & $c.r & "," & $c.g & "," & $c.b

proc describeStyle*(c: CanonCell): string =
  ## Every field the comparison looks at, in one line — so a report never
  ## leaves a reader guessing which of them moved.
  var attrs: seq[string] = @[]
  for a in c.attrs * ComparedAttrs:
    attrs.add $a
  "fg=" & describeColor(c.fg) & " bg=" & describeColor(c.bg) &
    " attrs={" & attrs.join(",") & "}" &
    " underline=" & $c.underline & " width=" & $c.width

proc describeRune*(s: string): string =
  ## The rune AND its codepoints. "differs at (3,7): ' ' vs ' '" is not a
  ## diagnosis; U+0020 vs U+00A0 is.
  var points: seq[string] = @[]
  for r in runes(s):
    points.add "U+" & toHex(r.int32, 4)
  "'" & s & "' (" & (if points.len == 0: "empty" else: points.join(" ")) & ")"

proc describe*(d: Divergence): string =
  case d.kind
  of dkGeometry:
    "cross-tier geometry differs: " & d.summary &
      "\n  tier 1: " & d.tier1 & "\n  tier 2: " & d.tier2
  of dkCell:
    "cross-tier cellmap differs, first at (row " & $d.row & ", col " &
      $d.col & ")" &
      "\n  tier 1 rune " & d.tier1 &
      "\n  tier 2 rune " & d.tier2 &
      "\n  " & d.summary
  of dkPlaintextRow:
    "cross-tier plaintext differs, first at row " & $d.row &
      "\n  tier 1: " & d.tier1.escape() &
      "\n  tier 2: " & d.tier2.escape() &
      "\n  " & d.summary

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

proc sameCell(a, b: CanonCell): bool =
  a.rune == b.rune and a.width == b.width and a.fg == b.fg and a.bg == b.bg and
    (a.attrs * ComparedAttrs) == (b.attrs * ComparedAttrs) and
    a.underline == b.underline

proc compareCanon*(tier1, tier2: CanonScreen): seq[Divergence] =
  ## The FIRST differing cell in row-major order, plus the geometry check that
  ## has to come before it. Returns an empty seq when the screens are equal.
  result = @[]
  if tier1.rows != tier2.rows or tier1.cols != tier2.cols:
    result.add Divergence(
      kind: dkGeometry, row: -1, col: -1,
      tier1: $tier1.cols & "x" & $tier1.rows & " (" & tier1.dialect & ")",
      tier2: $tier2.cols & "x" & $tier2.rows & " (" & tier2.dialect & ")",
      summary: "the two tiers did not composite the same grid")
    return
  for r in 0 ..< tier1.rows:
    for c in 0 ..< tier1.cols:
      let a = tier1.cells[r][c]
      let b = tier2.cells[r][c]
      if not sameCell(a, b):
        result.add Divergence(
          kind: dkCell, row: r, col: c,
          tier1: describeRune(a.rune) & "  " & describeStyle(a),
          tier2: describeRune(b.rune) & "  " & describeStyle(b),
          summary: (
            if a.rune != b.rune: "the runes differ"
            elif a.width != b.width: "the cell widths differ"
            elif a.underline != b.underline: "the underline styles differ"
            elif (a.attrs * ComparedAttrs) != (b.attrs * ComparedAttrs):
              "the attribute sets differ"
            else: "the colours differ"))
        return

proc normalisePlaintext(s: string): string =
  ## The `plaintext-trailing-newline` exclusion, applied in exactly one place.
  ## Only a SINGLE trailing newline is removed: a second one would be a blank
  ## row the two tiers disagree about, and that must still fail.
  if s.endsWith("\n"): s[0 ..< s.len - 1] else: s

proc comparePlaintext*(tier1, tier2: string): seq[Divergence] =
  result = @[]
  let a = normalisePlaintext(tier1).split('\n')
  let b = normalisePlaintext(tier2).split('\n')
  if a.len != b.len:
    result.add Divergence(
      kind: dkPlaintextRow, row: -1, col: -1,
      tier1: $a.len & " row(s)", tier2: $b.len & " row(s)",
      summary: "the two plaintext renderings have different row counts")
    return
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      var col = 0
      while col < a[i].len and col < b[i].len and a[i][col] == b[i][col]:
        inc col
      result.add Divergence(
        kind: dkPlaintextRow, row: i, col: col,
        tier1: a[i], tier2: b[i],
        summary: "first differing byte at column " & $col)
      return

# ---------------------------------------------------------------------------
# Snapshot directories
# ---------------------------------------------------------------------------

const
  SnapPlaintext* = "plaintext.txt"
  SnapAnsi* = "ansi.ansi"
  SnapCellmap* = "cellmap.json"
  SnapSvg* = "svg.svg"
  SnapAnnotated* = "annotated.svg"
  SnapTreedump* = "treedump.txt"
  SnapAllFiles* = [SnapPlaintext, SnapAnsi, SnapCellmap, SnapSvg,
                   SnapAnnotated, SnapTreedump]

proc writeTier1Snapshot*(h: TerminalTestHarness; dir: string) =
  ## The six formats, through the six encoders `TerminalTestHarness.snap`
  ## composes.
  ##
  ## The encoders are called directly rather than through `h.snap(name)` for
  ## one reason: `snap` resolves its own directory (`tests/snapshots/<name>`
  ## relative to the process's cwd, creating it) and manages goldens. Here the
  ## directory is an argument and there is no golden — the OTHER TIER is the
  ## reference. Same bytes either way; `snapshot/runner.encodeAll` is the list
  ## being mirrored.
  createDir(dir)
  let buf = h.driver.buffer
  writeFile(dir / SnapPlaintext, encodePlaintext(buf))
  writeFile(dir / SnapAnsi, encodeAnsi(buf))
  writeFile(dir / SnapCellmap, encodeCellMap(buf))
  writeFile(dir / SnapSvg, encodeSvg(buf))
  writeFile(dir / SnapAnnotated,
            encodeAnnotatedSvg(buf, h.root, h.compositor, h.focusedId))
  writeFile(dir / SnapTreedump, encodeTreeDump(h.compositor, h.root))

proc writeTier2Snapshot*(sess: var TuiTestSession; dir: string) =
  ## The six formats, through `term_assert/snapshot.writeFiles` — the same proc
  ## `TuiTestSession.snap` composes, so the directory this writes is the one
  ## `snap` would have written.
  createDir(dir)
  writeFiles(sess.screen, dir)

proc readSnapshotFile(dir, name: string): string =
  let path = dir / name
  if not fileExists(path):
    raise newException(DualSnapError,
      "snapshot file missing: " & path &
      " — the tier that should have written it did not")
  readFile(path)

proc compareSnapshotDirs*(tier1Dir, tier2Dir: string): seq[Divergence] =
  ## Compare two six-format snapshot directories on `plaintext.txt` and
  ## `cellmap.json`.
  ##
  ## Every file of the six is required to EXIST in both directories, including
  ## the four that are not compared. A tier that stopped writing one of them
  ## would otherwise pass this silently, and "the directories are
  ## interchangeable" is the property the whole milestone rests on.
  result = @[]
  for name in SnapAllFiles:
    discard readSnapshotFile(tier1Dir, name)
    discard readSnapshotFile(tier2Dir, name)
  let canon1 = parseCellmap(readSnapshotFile(tier1Dir, SnapCellmap))
  let canon2 = parseCellmap(readSnapshotFile(tier2Dir, SnapCellmap))
  if canon1.dialect == canon2.dialect:
    raise newException(DualSnapError,
      "both snapshot directories were written by the same tier (" &
      canon1.dialect & ") — a comparison of a directory with itself is the " &
      "vacuous pass this suite exists to prevent")
  result.add compareCanon(canon1, canon2)
  result.add comparePlaintext(readSnapshotFile(tier1Dir, SnapPlaintext),
                              readSnapshotFile(tier2Dir, SnapPlaintext))

# ---------------------------------------------------------------------------
# Child apps
# ---------------------------------------------------------------------------

proc repoRoot*(): string =
  ## The codetracer checkout this module's source lives in.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(DualSnapError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc dualSnapWorkDir*(): string =
  ## Everything this module writes lands under `test-logs/`, which
  ## `.gitignore` covers, so a run never dirties the tree.
  let dir = repoRoot() / "test-logs" / "tui-dual-snap"
  createDir(dir)
  dir

proc appSourcePath*(stem: string): string =
  repoRoot() / "src" / "frontend" / "tui" / "tests" / "apps" / (stem & ".nim")

proc appBinaryPath*(stem: string): string =
  dualSnapWorkDir() / "bin" / stem

proc childCompileCommand*(stem: string): string =
  ## The command that turns `tests/apps/<stem>.nim` into a spawnable binary.
  ##
  ## The flags mirror `just build-tui` (`--mm:orc -d:release`) plus the two the
  ## `tui` lanes resolve in `ci/lib/test-lane-files.sh`: the grammar-archive
  ## define, without which `isonim_tui`'s `{.passl.}` hands the linker an
  ## absolute path inside the isonim-tui checkout, and the tree-sitter runtime
  ## `-L` / `-rpath` that `scripts/build-tui-grammars.sh` records.
  ##
  ## `--path:../TermAssertClient/src` and nothing else from the Tier-2 sibling
  ## set: the child talks to the harness, it does not host one.
  let root = repoRoot()
  var cmd = "nim c --styleCheck:usages --styleCheck:error --mm:orc -d:release"
  cmd.add " --path:" & (root / "src" / "frontend" / "viewmodel").quoteShell
  cmd.add " -d:isonimTuiGrammarArchive=" &
          (root / "build" / "grammars" / "libcodetracer_tui_grammars.a")
  let linkFlags = root / "build" / "grammars" / "tui-link-flags.txt"
  if fileExists(linkFlags):
    for flag in strutils.splitWhitespace(readFile(linkFlags)):
      cmd.add " --passL:" & flag
  cmd.add " --path:" & (root.parentDir / "TermAssertClient" / "src").quoteShell
  cmd.add " --nimcache:" & (dualSnapWorkDir() / "nimcache").quoteShell
  cmd.add " -o:" & appBinaryPath(stem).quoteShell
  cmd.add " " & appSourcePath(stem).quoteShell
  cmd

proc newestSourceTime*(stem: string): float =
  ## The newest modification time among everything a child app is built from.
  ##
  ## THE APP SOURCE AND THE RUNTIME ARE NOT ENOUGH, and that was measured
  ## rather than reasoned about. CTUI-5's `app_source_pane` is a thin wrapper
  ## over `app/views/source_pane.nim`; a mutation arm changed
  ## `app/views/gutter.nim`, rebuilt and ran the Tier-2 suite, restored the
  ## file — and the NEXT lane run reused the mutated binary, because neither
  ## the app source nor `test_app_runtime.nim` had been touched. The suite went
  ## red on the restored tree, reporting a defect that no longer existed.
  ##
  ## The failure mode this closes is worse than the false red that exposed it:
  ## a cross-tier comparison between a FRESH Tier-1 model and a STALE Tier-2
  ## binary is a comparison of two different programs, and it fails — or
  ## passes — for a reason that has nothing to do with the renderer.
  ##
  ## So the whole of `app/` is in the stamp. `app/` is what a child app draws;
  ## the sibling libraries are not, and a rebuild on every `isonim-tui` edit
  ## would cost the lane a link per case for a dependency that changes far less
  ## often — that residue is recorded here rather than papered over.
  result = 0.0
  let src = appSourcePath(stem)
  if fileExists(src):
    result = getFileInfo(src).lastWriteTime.toUnixFloat()
  let tui = repoRoot() / "src" / "frontend" / "tui"
  let runtime = tui / "testing" / "test_app_runtime.nim"
  if fileExists(runtime):
    result = max(result, getFileInfo(runtime).lastWriteTime.toUnixFloat())
  let appDir = tui / "app"
  if dirExists(appDir):
    for path in walkDirRec(appDir):
      if path.endsWith(".nim"):
        result = max(result, getFileInfo(path).lastWriteTime.toUnixFloat())

proc compileChildApp*(stem: string) =
  ## Compile `tests/apps/<stem>.nim` if the binary is missing or older than any
  ## of its sources. Never skips on failure: a child that will not compile is
  ## the defect, and it is reported with the compiler's own output.
  let src = appSourcePath(stem)
  if not fileExists(src):
    raise newException(DualSnapError, "child app source missing: " & src)
  let bin = appBinaryPath(stem)
  createDir(bin.parentDir)
  if fileExists(bin):
    let binTime = getFileInfo(bin).lastWriteTime.toUnixFloat()
    if binTime > newestSourceTime(stem): return
  let (output, code) = execCmdEx(childCompileCommand(stem))
  if code != 0:
    raise newException(DualSnapError,
      "child app '" & stem & "' failed to compile (exit " & $code & "):\n" &
      childCompileCommand(stem) & "\n" & output)

# ---------------------------------------------------------------------------
# Barriers
# ---------------------------------------------------------------------------

proc screenDigest(sess: var TuiTestSession): string =
  ## A short, quotable rendering of what the terminal currently holds. Used in
  ## every failure message: a barrier that timed out has to say what it DID
  ## see, or a hang and a wrong-screen are the same report.
  let text = sess.screenContents()
  var lines: seq[string] = @[]
  for line in text.splitLines():
    let stripped = line.strip(leading = false, trailing = true)
    if stripped.len > 0:
      lines.add stripped
    if lines.len >= 6: break
  if lines.len == 0: "<blank screen>" else: lines.join(" / ")

proc waitForCompleteFrame*(sess: var TuiTestSession; cols, rows: int;
                           timeoutMs = 15000) =
  ## Block until the child has painted a whole frame, using the cursor barrier
  ## `testing/test_app_runtime.nim` documents: the cursor comes to rest at
  ## `(rows-1, cols-1)` exactly when the last cell of the last row has been
  ## parsed, and cannot be there before.
  ##
  ## The failure is a DIAGNOSIS, not a timeout: it names the cursor position
  ## actually observed, whether the child is still alive, and what the screen
  ## holds — so "still painting", "died on startup" and "painted something
  ## else" are three different reports.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var lastPos = (row: -1, col: -1)
  while getMonoTime() < deadline:
    discard sess.drainOutput(20)
    lastPos = sess.cursorPosition()
    if lastPos.row == rows - 1 and lastPos.col == cols - 1:
      return
    if not sess.isAlive:
      discard sess.drainOutput(50)
      lastPos = sess.cursorPosition()
      if lastPos.row == rows - 1 and lastPos.col == cols - 1:
        return
      raise newException(DualSnapError,
        "the child exited before completing a frame: cursor rested at (" &
        $lastPos.row & "," & $lastPos.col & "), expected (" & $(rows - 1) &
        "," & $(cols - 1) & "); exit code " & $sess.exitCode() &
        "; screen: " & screenDigest(sess))
  raise newException(DualSnapError,
    "the child never completed a frame within " & $timeoutMs & " ms: cursor " &
    "rested at (" & $lastPos.row & "," & $lastPos.col & "), expected (" &
    $(rows - 1) & "," & $(cols - 1) & "); child alive=" & $sess.isAlive &
    "; screen: " & screenDigest(sess))

proc waitForSnapshotLabel*(sess: var TuiTestSession; label: string;
                           timeoutMs = 5000): ScreenSnapshot =
  ## Block until the child has asked the harness to record `label`.
  ##
  ## THE FAILURE SAYS "LABEL NEVER ARRIVED", NOT "TIMEOUT". Per
  ## codetracer-specs/Testing/Verification-Harness-Traps.md §3 a timeout is a
  ## symptom rather than a diagnosis, and the natural next move on reading one
  ## — raise the timeout — is the wrong move for every cause this can have. So
  ## the message carries the labels that DID arrive (none, versus the wrong
  ## one), whether the child is alive, and the screen, which is where the
  ## child prints a socket-connect failure.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    discard sess.drainOutput(20)
    let recorded = sess.snapshots()
    if recorded.hasKey(label):
      return recorded[label]
    if getMonoTime() >= deadline:
      var names: seq[string] = @[]
      for k in recorded.keys: names.add k
      raise newException(DualSnapError,
        "label never arrived: the child did not request a screenshot named " &
        label.escape() & " within " & $timeoutMs & " ms. Labels recorded: [" &
        names.join(", ") & "]; child alive=" & $sess.isAlive &
        "; screen: " & screenDigest(sess))

# ---------------------------------------------------------------------------
# The dual run
# ---------------------------------------------------------------------------

type
  DualSnapResult* = object
    caseName*: string
    cols*, rows*: int
    tier1Dir*, tier2Dir*: string
    divergences*: seq[Divergence]

proc dualSnapCaseDir*(caseName: string): string =
  dualSnapWorkDir() / "cases" / caseName

proc runDualSnap*(stem: string; build: proc(r: TerminalRenderer): TerminalNode;
                  cols, rows: int): DualSnapResult =
  ## ONE component tree, two tiers.
  ##
  ## `build` is the very proc the child's `apps/<stem>.nim` hands to
  ## `runSnapshotApp`; the test imports that module and passes it here. That is
  ## what makes the comparison a statement about the renderer rather than about
  ## two hand-written fixtures that happen to agree.
  result.caseName = stem & "-" & $cols & "x" & $rows
  result.cols = cols
  result.rows = rows
  let base = dualSnapCaseDir(result.caseName)
  removeDir(base)
  result.tier1Dir = base / "tier1"
  result.tier2Dir = base / "tier2"

  let h = newTerminalTestHarness(cols, rows)
  try:
    h.mount(build)
    h.flush()
    writeTier1Snapshot(h, result.tier1Dir)
  finally:
    h.dispose()

  compileChildApp(stem)
  var sess = newTuiTest(appBinaryPath(stem),
                        @["--cols=" & $cols, "--rows=" & $rows])
    .width(cols).height(rows)
    .spawn()
  try:
    waitForCompleteFrame(sess, cols, rows)
    writeTier2Snapshot(sess, result.tier2Dir)
    sess.send("q")
    discard sess.waitExit(initDuration(seconds = 5))
  finally:
    sess.terminate()
    sess.close()

  result.divergences = compareSnapshotDirs(result.tier1Dir, result.tier2Dir)

proc runDualSnap*(stem: string;
                  build: proc(r: TerminalRenderer;
                              cols, rows: int): TerminalNode;
                  cols, rows: int): DualSnapResult =
  ## The SIZED shape, for a tree that depends on the terminal's geometry.
  ##
  ## CTUI-3's shell composes each screen row for a known width, so the size is
  ## an input to the tree rather than something the compositor applies
  ## afterwards. The child receives the same numbers through `--cols` /
  ## `--rows`, so both tiers still run one `buildTree` at one geometry — which
  ## is what makes the comparison a statement about the renderer.
  runDualSnap(stem, proc(r: TerminalRenderer): TerminalNode =
    build(r, cols, rows), cols, rows)

proc report*(r: DualSnapResult): string =
  ## What a failing case prints. The exclusion register is included because a
  ## reader looking at a divergence needs to know what was NOT compared before
  ## deciding what the divergence means.
  var parts: seq[string] = @[]
  parts.add "cross-tier snapshot case '" & r.caseName & "' at " & $r.cols &
            "x" & $r.rows
  parts.add "  tier 1: " & r.tier1Dir
  parts.add "  tier 2: " & r.tier2Dir
  for d in r.divergences:
    parts.add indent(describe(d), 2)
  parts.add indent(renderExclusions(), 2)
  parts.join("\n")

# ---------------------------------------------------------------------------
# The mutation arm
# ---------------------------------------------------------------------------

proc mutateCellmapRune*(dir: string; row, col: int; newRune: string) =
  ## Change ONE cell's rune in a written `cellmap.json`.
  ##
  ## A deliverable, not a demonstration: a comparison that cannot be made to
  ## fail is indistinguishable from one that is not reading the files, and
  ## `test_cross_tier_snapshot_equivalence.nim` runs this against a directory
  ## it has just seen compare EQUAL, so the arm's control is the same pair of
  ## files in the same run.
  let path = dir / SnapCellmap
  let root = parseJson(readSnapshotFile(dir, SnapCellmap))
  if row < 0 or row >= root["cells"].len:
    raise newException(DualSnapError, "mutation row out of range: " & $row)
  if col < 0 or col >= root["cells"][row].len:
    raise newException(DualSnapError, "mutation col out of range: " & $col)
  root["cells"][row][col]["rune"] = %newRune
  writeFile(path, $root)

proc mutateCellmapAttr*(dir: string; row, col: int; attrName: string) =
  ## Add one attribute to one cell in a written `cellmap.json`. The rune stays
  ## put, so this arm can only be caught by the STYLE half of the comparison.
  let path = dir / SnapCellmap
  let root = parseJson(readSnapshotFile(dir, SnapCellmap))
  if row < 0 or row >= root["cells"].len or
     col < 0 or col >= root["cells"][row].len:
    raise newException(DualSnapError,
      "mutation cell out of range: (" & $row & "," & $col & ")")
  var attrs = root["cells"][row][col]["attrs"]
  if attrs.kind != JArray:
    raise newException(DualSnapError, "cellmap cell `attrs` is not an array")
  attrs.add %attrName
  root["cells"][row][col]["attrs"] = attrs
  writeFile(path, $root)

proc cellAtCanon*(dir: string; row, col: int): CanonCell =
  ## Read one canonical cell out of a written snapshot directory. Used by the
  ## mutation arms to state what the cell WAS before they changed it.
  let canon = parseCellmap(readSnapshotFile(dir, SnapCellmap))
  if row < 0 or row >= canon.rows or col < 0 or col >= canon.cols:
    raise newException(DualSnapError,
      "cell out of range: (" & $row & "," & $col & ") on a " & $canon.cols &
      "x" & $canon.rows & " screen")
  canon.cells[row][col]

proc firstCellWhere*(dir: string;
                     pred: proc(c: CanonCell): bool): tuple[row, col: int] =
  ## The first cell in row-major order satisfying `pred`, or (-1, -1).
  ##
  ## Mutation arms pick their target with this rather than hard-coding a
  ## coordinate: a hard-coded (0,0) would keep passing after a layout change
  ## moved the content, which is the arm silently mutating a blank cell.
  let canon = parseCellmap(readSnapshotFile(dir, SnapCellmap))
  for r in 0 ..< canon.rows:
    for c in 0 ..< canon.cols:
      if pred(canon.cells[r][c]):
        return (row: r, col: c)
  (row: -1, col: -1)

proc canonFromDir*(dir: string): CanonScreen =
  parseCellmap(readSnapshotFile(dir, SnapCellmap))

proc countCellsWhere*(canon: CanonScreen;
                      pred: proc(c: CanonCell): bool): int =
  for row in canon.cells:
    for cell in row:
      if pred(cell): inc result

proc harnessCanonFor*(build: proc(r: TerminalRenderer): TerminalNode;
                      cols, rows: int; caseName: string): CanonScreen =
  ## The Tier-1 reference on its own, for a suite that needs the harness's
  ## screen without spawning a child (the IPC suite compares the frame the
  ## CHILD declared final against this).
  ##
  ## It goes through the same six-format writer and the same parser as the full
  ## dual run, so the reference a labelled frame is compared against is the
  ## same artifact `runDualSnap` compares against — not a second path that
  ## could drift from it.
  let dir = dualSnapCaseDir(caseName) / "tier1"
  removeDir(dir)
  let h = newTerminalTestHarness(cols, rows)
  try:
    h.mount(build)
    h.flush()
    writeTier1Snapshot(h, dir)
  finally:
    h.dispose()
  canonFromDir(dir)
