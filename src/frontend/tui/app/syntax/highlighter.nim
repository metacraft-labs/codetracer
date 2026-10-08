## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `isonim_tui` and `std/*` and nothing else:
## it opens no file, and the source text it highlights is handed to it by
## `SourceVM` through `app/views/source_pane.nim`.
##
## app/syntax/highlighter.nim — CTUI-5. Token spans for one revision of one
## file, over the ten tree-sitter grammars this repository vendors, with a
## lexical fallback and a do-nothing floor.
##
## ## THREE TIERS, AND CTUI-5's SENTENCE DESCRIBES TWO OF THEM
##
## The milestone asks for "tree-sitter highlighting over the grammars in
## `libs/`, with a lexical fallback for languages without one", and its test
## asks that "a file in a language with no grammar renders **unhighlighted**
## rather than failing". Read together those are two different requirements,
## and this module implements both by distinguishing three cases rather than
## two:
##
##   1. **A vendored tree-sitter grammar** — `.nim`, `.ak`, `.cairo`, `.cdc`,
##      `.circom`, `.leo`, `.masm`, `.move`, `.sw`, `.tolk`. Parsed, and the
##      leaves' node types mapped onto `TokenClass`.
##   2. **No grammar, but a tokenizer of the desktop's** — `.py`, `.rs`,
##      `.nr`, `.c`, `.h`, `.cpp`, `.go`, `.js`, `.ts`, `.java`, `.rb`, `.sh`,
##      `.json`, `.yaml`. This is the "lexical fallback", and since PLAT-47 it
##      is not an approximation: each language is lexed by the Monaco
##      tokenizer the desktop colours it with (Tier 2 below). It matters
##      because **neither fixture in this campaign's corpus has a grammar** —
##      `calc` is Python and `noir_space_ship` is Noir — so without it the one
##      pane CTUI-5 delivers would be unhighlighted on every trace the campaign
##      can open.
##   3. **Nothing recognised at all** — an unknown extension, or none. ZERO
##      spans, and no exception: the pane renders the text plain. That is the
##      "unhighlighted rather than failing" case, and it is the one a caller
##      cannot avoid, because a recorded path is whatever a recorder interned.
##
## `test_syntax_highlighting_ansi.nim` asserts all three, and asserts case 3 by
## its span COUNT (zero) rather than by "it did not crash".
##
## ## THE CACHE IS THE LATENCY GATE, AND IT IS KEYED BY REVISION
##
## CTUI-5's named risk is that "tree-sitter highlighting on every frame would
## dominate the latency budget", and its mitigation is to "parse once per
## (path, generation) and cache the token spans". `HighlighterCache` does
## exactly that, keyed on the identity triple `SourceVM` already carries —
## path, generation AND digest — rather than on path alone, because a live-HCR
## patch bumps the generation for the same path and the cached spans then
## belong to the previous build.
##
## The key also carries the TEXT's own length and a cheap checksum. That is not
## belt-and-braces: `SourceVM` holds a WINDOW, so two frames with the same
## revision can legitimately carry different text (the window scrolled), and a
## cache keyed on the triple alone would serve line 1's spans for line 400.
##
## `parseCount` is exported and asserted. A cache whose hit rate nothing checks
## is a cache that can silently stop caching, and the latency gate is measured
## on the CACHED path — so the number of parses a scroll performs is part of
## the evidence rather than an implementation detail.
##
## ## No mocks
##
## The tree-sitter path calls the real vendored grammars through
## `isonim_tui`'s `syntax/treesitter_ffi`, linked out of
## `build/grammars/libcodetracer_tui_grammars.a` — the archive
## `scripts/build-tui-grammars.sh` builds and
## `tests/test_tui_build_prerequisites.nim` gates. There is no stub grammar
## and no recorded parse tree.

import std/[strutils, tables, unicode]

import isonim_tui

import ./token_class
import ./monarch
import ./json_tokens
import ./lexical
import ../theme/editor_theme

export lexical

# `TokenClass` lives in `token_class.nim` (PLAT-47), a module with no imports,
# because the theme (`app/theme/editor_theme.nim`) maps each class to the
# desktop's Monaco token scope and must not pull the tree-sitter runtime in
# with it. Re-exported, so every caller that named it here still does.
export token_class

type
  SyntaxSpan* = object
    ## One classified run of a single line, in CELL columns relative to the
    ## line's first character.
    ##
    ## Cells rather than bytes, because the consumer is a cell grid: a line
    ## holding a CJK identifier has more bytes than columns and more columns
    ## than runes, and a span expressed in any unit but cells would colour the
    ## wrong columns of it.
    startCell*: int
    endCell*: int    ## exclusive
    class*: TokenClass

  HighlightMode* = enum
    ## How a file's spans were produced. Reported so a test — and a
    ## `--verbose` surface — can tell "this parsed" from "this was lexed" from
    ## "this was left alone", which are three different answers that all look
    ## like coloured text.
    hmNone         ## no spans at all; the text renders plain
    hmTreeSitter
    hmLexical

  FileHighlight* = object
    ## Per-line spans for one window of one revision.
    mode*: HighlightMode
    grammar*: GrammarId
    lexer*: LexerId
    firstLine*: int
      ## 1-based line number of `lines[0]`.
    lines*: seq[seq[SyntaxSpan]]

  HighlightKey* = object
    ## What a cached parse belongs to. See the module header on why the text's
    ## own shape is part of it.
    path*: string
    sourceGeneration*: int
    sourceDigest*: string
    firstLine*: int
    textLen*: int
    textHash*: uint32
    entryContext*: string
      ## The tokenizer state the window starts in (PLAT-47 B4): the same text
      ## entered from a different state is coloured differently.

  HighlighterCache* = ref object
    ## `(path, generation, digest, window)` -> spans, BOUNDED.
    ##
    ## The bound is not decoration. The key includes the window, so a long
    ## scroll produces one entry per window visited: a 12 000-line file
    ## scrolled end to end at a 80-line stride is 300 entries of ~35 lines of
    ## spans each, and an unbounded cache would make "the pane holds only its
    ## window" true of the TEXT and false of the process. `MaxCachedWindows`
    ## caps it; `test_source_virtualization.nim` asserts the cap holds across a
    ## scroll rather than trusting this comment.
    entries*: Table[HighlightKey, FileHighlight]
    order*: seq[HighlightKey]
      ## Insertion order, for eviction. A `seq` rather than a heap because the
      ## cap is small enough that a linear delete is cheaper than the
      ## bookkeeping a smarter structure would need.
    evictions*: int
    parseCount*: int
      ## How many times a real parse (tree-sitter OR lexical) was performed.
      ## Asserted by the virtualization and latency suites: the cached path is
      ## what the < 16 ms gate is measured on, so a cache that stopped caching
      ## has to redden a test rather than merely slow a frame down.
    lookupCount*: int

# ---------------------------------------------------------------------------
# Grammar entry points
#
# `isonim_tui/syntax/treesitter_ffi` declares `tree_sitter_nim` and
# `tree_sitter_aiken` privately and exposes only `nimLanguage()` /
# `aikenLanguage()`. The other eight symbols are in the SAME archive —
# `scripts/build-tui-grammars.sh` says so in its own header: "Building the
# archive from `libs/` ... gives the CTUI-5 highlighter eight more languages
# than isonim-tui has" — so they are declared here rather than upstream.
# ---------------------------------------------------------------------------

proc tree_sitter_cairo(): ptr TSLanguage {.importc.}
proc tree_sitter_cadence(): ptr TSLanguage {.importc.}
proc tree_sitter_circom(): ptr TSLanguage {.importc.}
proc tree_sitter_leo(): ptr TSLanguage {.importc.}
proc tree_sitter_masm(): ptr TSLanguage {.importc.}
proc tree_sitter_move_on_aptos(): ptr TSLanguage {.importc.}
proc tree_sitter_sway(): ptr TSLanguage {.importc.}
proc tree_sitter_tolk(): ptr TSLanguage {.importc.}

proc languageFor*(grammar: GrammarId): Language =
  ## The `TSLanguage*` handle for a grammar. `giNone` never reaches here — the
  ## caller branches on the mode first — and a `doAssert` says so rather than
  ## returning a null handle that `ts_parser_set_language` would refuse with an
  ## "ABI mismatch" that is not what happened.
  case grammar
  of giNone:
    doAssert false, "languageFor(giNone): the caller must branch on the mode"
    Language()
  of giNim: nimLanguage()
  of giAiken: aikenLanguage()
  of giCairo: Language(raw: tree_sitter_cairo())
  of giCadence: Language(raw: tree_sitter_cadence())
  of giCircom: Language(raw: tree_sitter_circom())
  of giLeo: Language(raw: tree_sitter_leo())
  of giMasm: Language(raw: tree_sitter_masm())
  of giMoveOnAptos: Language(raw: tree_sitter_move_on_aptos())
  of giSway: Language(raw: tree_sitter_sway())
  of giTolk: Language(raw: tree_sitter_tolk())

proc modeForPath*(path: string): HighlightMode =
  ## Which of the three tiers in this module's header `path` lands in.
  if grammarForPath(path) != giNone: hmTreeSitter
  elif lexerForPath(path) != lxNone: hmLexical
  else: hmNone

# ---------------------------------------------------------------------------
# Node type -> TokenClass
# ---------------------------------------------------------------------------

const
  CommentNodeTypes = ["comment", "line_comment", "block_comment",
                      "documentation_comment", "block_documentation_comment",
                      "doc_comment", "definition_comment", "module_comment"]
  StringNodeTypes = ["string", "string_literal", "long_string_literal",
                     "raw_string_literal", "char_literal", "char",
                     "interpreted_string_literal", "string_content",
                     "string_inner", "byte_string", "generalized_string",
                     "generalized_string_literal", "string_fragment",
                     "hex_string", "quoted_string"]
  NumberNodeTypes = ["integer_literal", "float_literal",
                     "custom_numeric_literal", "integer", "float", "decimal",
                     "number", "num_literal", "number_literal"]
  TypeNodeTypes = ["type_identifier", "primitive_type", "builtin_type",
                   "type", "constructor"]
  IdentifierNodeTypes = ["identifier", "accent_quoted", "field_identifier",
                         "function_identifier", "variable_identifier"]
  PunctuationTokens = ["(", ")", "[", "]", "{", "}", ",", ";", ".", ":",
                       "::", "|", "@", "#"]
  OperatorTokens = ["+", "-", "*", "/", "%", "=", "==", "!=", "<", ">",
                    "<=", ">=", "&", "^", "->", "=>", "..", "...", "+=",
                    "-=", "*=", "/=", ":=", "&&", "||", "!", "|>", "<-",
                    "?", "~", "**", "<<", ">>"]

func isIn(needle: string; haystack: openArray[string]): bool =
  for h in haystack:
    if h == needle:
      return true
  false

func isKeywordShaped(nodeType: string): bool =
  ## Anonymous tree-sitter leaves carry their literal source text as their node
  ## type, so `proc`, `if` and `pub` arrive here as themselves. A leaf whose
  ## type is entirely lowercase ASCII letters or underscores AND is not one of
  ## the semantic names above is a keyword in every one of the ten grammars.
  ##
  ## This replaces the per-grammar keyword tables `isonim_tui`'s own
  ## highlighter carries for its two languages. Ten hand-written tables would
  ## be ten things to keep true, and the shape test is what all ten grammars
  ## agree on: a NAMED leaf's type is a category (`identifier`,
  ## `string_literal`) and those are enumerated; an ANONYMOUS leaf's type is
  ## the token itself.
  if nodeType.len == 0:
    return false
  for ch in nodeType:
    if ch notin {'a'..'z', '_'}:
      return false
  true

proc classForNodeType*(nodeType: string; named: bool): TokenClass =
  ## Map one tree-sitter leaf onto the palette.
  ##
  ## `named` is the discriminator tree-sitter itself provides: a named leaf's
  ## type is a grammar CATEGORY, an anonymous leaf's type is the literal token.
  ## Without it `identifier` (a category) and a hypothetical keyword spelled
  ## `identifier` are the same string.
  if nodeType.isIn(CommentNodeTypes): return tcComment
  if nodeType.isIn(StringNodeTypes): return tcString
  if nodeType.isIn(NumberNodeTypes): return tcNumber
  if nodeType.isIn(TypeNodeTypes): return tcType
  if nodeType.isIn(IdentifierNodeTypes): return tcIdentifier
  if named:
    # A named leaf whose category this palette does not model. Left plain
    # rather than guessed at: colouring an unknown category as a keyword is how
    # a source pane comes to look wrong in one language and right in nine.
    return tcPlain
  if nodeType.isIn(PunctuationTokens): return tcPunctuation
  if nodeType.isIn(OperatorTokens): return tcOperator
  if isKeywordShaped(nodeType): return tcKeyword
  tcPlain

# ---------------------------------------------------------------------------
# Cell arithmetic
# ---------------------------------------------------------------------------

func isAsciiLine(line: string): bool =
  for ch in line:
    if ord(ch) >= 0x80: return false
  true

proc cellOffsetAtByte*(line: string; byteOffset: int): int =
  ## How many CELLS of `line` lie strictly before `byteOffset`.
  ##
  ## An ASCII prefix is one cell per byte, and that is the common case by a
  ## wide margin: the rune walk below allocates a string per rune, which is
  ## what dominated a whole-file highlight once the parse stopped being
  ## window-sized.
  if byteOffset <= 0:
    return 0
  var ascii = true
  for i in 0 ..< min(byteOffset, line.len):
    if ord(line[i]) >= 0x80:
      ascii = false
      break
  if ascii:
    return min(byteOffset, line.len)
  var bytes = 0
  for r in runes(line):
    if bytes >= byteOffset:
      break
    bytes += ($r).len
    result += max(1, displayWidth($r))

func mergeSpans(spans: seq[SyntaxSpan]): seq[SyntaxSpan] =
  ## Adjacent spans of the same class, joined; empty spans dropped.
  ##
  ## The cell grid is painted span by span, and two adjacent spans of one class
  ## would produce two `LayoutEntry`s where one would do. `styled_row.rowSpans`
  ## re-encodes by STYLE afterwards and would coalesce them anyway; doing it
  ## here as well keeps the span list a faithful description of the line rather
  ## than an artefact of the walk order.
  result = @[]
  for span in spans:
    if span.endCell <= span.startCell:
      continue
    if result.len > 0 and result[^1].class == span.class and
       result[^1].endCell == span.startCell:
      result[^1].endCell = span.endCell
    else:
      result.add span

# ---------------------------------------------------------------------------
# Tier 1: tree-sitter
# ---------------------------------------------------------------------------

proc treeSitterSpans(grammar: GrammarId; lines: seq[string]):
    seq[seq[SyntaxSpan]] =
  ## Parse the whole window at once and project each leaf onto its line.
  ##
  ## The WINDOW rather than the file, because `SourceVM` holds a window and
  ## this module performs no I/O. A construct straddling the window's edge —
  ## an unterminated block comment, say — parses as an error node, which
  ## tree-sitter reports as a leaf whose type is `ERROR`; that maps to
  ## `tcPlain`, so the pane renders it as text rather than colouring the rest
  ## of the window as a comment. Stated because the alternative reading (parse
  ## the file) is not available to a virtualized pane at all.
  result = newSeq[seq[SyntaxSpan]](lines.len)
  for i in 0 ..< lines.len:
    result[i] = @[]
  if lines.len == 0:
    return
  let source = lines.join("\n")
  if source.len == 0:
    return

  # Byte offset of each line's start within `source`.
  var lineStart = newSeq[int](lines.len + 1)
  var acc = 0
  for i, line in lines:
    lineStart[i] = acc
    acc += line.len + 1     # + the '\n' that `join` inserted
  lineStart[lines.len] = acc

  let parser = newParser()
  parser.setLanguage(languageFor(grammar))
  let tree = parser.parseString(source)
  var perLine = newSeq[seq[SyntaxSpan]](lines.len)
  for i in 0 ..< lines.len:
    perLine[i] = @[]
  # `leafFacts` and not `walkLeaves`: the second yields a `Node`, which
  # carries a copy of the source, so a whole-file walk copied the file once
  # per leaf — the other half of the sixty-five seconds (isonim-tui's
  # `leafFacts` header).
  for leaf in tree.rootNode.leafFacts:
    let cls = classForNodeType(leaf.nodeType, leaf.isNamed)
    if cls == tcPlain:
      continue
    let s = leaf.startByte
    let e = leaf.endByte
    if e <= s:
      continue
    # THE LINES THIS LEAF TOUCHES, AND ONLY THEM: a binary search to the line
    # holding its first byte, then forward while lines still overlap it. The
    # first spelling walked every line for every leaf — O(leaves x lines),
    # invisible on a forty-line window and sixty-five seconds on a 24,000-line
    # file once PLAT-29 moved the parse off the render path and gave it the
    # whole document (measured by `test_plat29_highlight_worker.nim`).
    var lo0 = 0
    var hi0 = lines.len - 1
    while lo0 < hi0:
      let mid = (lo0 + hi0 + 1) div 2
      if lineStart[mid] <= s: lo0 = mid else: hi0 = mid - 1
    var i = lo0
    while i < lines.len and lineStart[i] < e:
      let lo = lineStart[i]
      let hi = lo + lines[i].len
      if not (e <= lo or s >= hi):
        let localStart = max(s, lo) - lo
        let localEnd = min(e, hi) - lo
        if localEnd > localStart:
          perLine[i].add SyntaxSpan(
            startCell: cellOffsetAtByte(lines[i], localStart),
            endCell: cellOffsetAtByte(lines[i], localEnd),
            class: cls)
      inc i
  for i in 0 ..< lines.len:
    result[i] = mergeSpans(perLine[i])

# ---------------------------------------------------------------------------
# Tier 2: the desktop's own tokenizers (`lexical.nim`), as cell spans
# ---------------------------------------------------------------------------

proc spansOfTokens(line: string; tokens: seq[MonarchToken]): seq[SyntaxSpan] =
  var raw: seq[SyntaxSpan] = @[]
  for i, t in tokens:
    let stop = if i + 1 < tokens.len: tokens[i + 1].start else: line.len
    if stop <= t.start:
      continue
    let cls = classForMonacoToken(t.tokenType)
    if cls == tcPlain:
      continue
    raw.add SyntaxSpan(startCell: cellOffsetAtByte(line, t.start),
                       endCell: cellOffsetAtByte(line, min(stop, line.len)),
                       class: cls)
  mergeSpans(raw)

proc lexicalLineSpans*(lexer: LexerId; line: string;
                       context: var string): seq[SyntaxSpan] =
  ## One line classified as the desktop's Monaco classifies it, starting in
  ## `context` and leaving `context` as the line leaves it.
  spansOfTokens(line, monacoLineTokens(lexer, line, context))

# ---------------------------------------------------------------------------
# The public entry point
# ---------------------------------------------------------------------------

proc highlightWindow*(path: string; firstLine: int; lines: seq[string];
                      entryContext = ""): FileHighlight =
  ## Classify `lines` (line `firstLine` onwards) of `path`. Never raises for a
  ## path this module does not recognise: the answer is `hmNone` and no spans.
  ##
  ## `entryContext` is the tokenizer state line `firstLine` starts in
  ## (`lexerContexts`); "" means the file's initial state, which is right for
  ## a window that starts at line 1 and the best that can be done for one
  ## whose provider supplied no context.
  result = FileHighlight(
    mode: modeForPath(path),
    grammar: grammarForPath(path),
    lexer: lexerForPath(path),
    firstLine: firstLine,
    lines: @[])
  case result.mode
  of hmNone:
    result.lines = newSeq[seq[SyntaxSpan]](lines.len)
    for i in 0 ..< lines.len:
      result.lines[i] = @[]
  of hmTreeSitter:
    result.lines = treeSitterSpans(result.grammar, lines)
  of hmLexical:
    result.lines = newSeq[seq[SyntaxSpan]](lines.len)
    var context =
      if entryContext.len > 0: entryContext else: initialContext(result.lexer)
    for i, line in lines:
      result.lines[i] = lexicalLineSpans(result.lexer, line, context)

proc spansForLine*(h: FileHighlight; line: int): seq[SyntaxSpan] =
  ## The spans of one 1-based line, or none when it is outside the window.
  let idx = line - h.firstLine
  if idx < 0 or idx >= h.lines.len: @[]
  else: h.lines[idx]


# ---------------------------------------------------------------------------
# The cache
# ---------------------------------------------------------------------------


const MaxCachedWindows* = 16
  ## How many parsed windows a cache keeps.
  ##
  ## A pane needs the CURRENT window and, for the frame-to-frame comparison
  ## the emission budget is measured with, the previous one. Sixteen leaves
  ## room for a few panes and a scroll that oscillates, and is small enough
  ## that the spans a cache holds are a fixed cost rather than a function of
  ## how far the user has scrolled.

proc newHighlighterCache*(): HighlighterCache =
  HighlighterCache(entries: initTable[HighlightKey, FileHighlight](),
                   order: @[], evictions: 0, parseCount: 0, lookupCount: 0)

proc highlightKey*(path: string; sourceGeneration: int; sourceDigest: string;
                   firstLine: int; lines: seq[string];
                   entryContext = ""): HighlightKey =
  var textLen = 0
  for line in lines:
    textLen += line.len + 1
  HighlightKey(path: path, sourceGeneration: sourceGeneration,
               sourceDigest: sourceDigest, firstLine: firstLine,
               textLen: textLen, textHash: textChecksum(lines),
               entryContext: entryContext)

proc highlight*(cache: HighlighterCache; path: string; sourceGeneration: int;
                sourceDigest: string; firstLine: int;
                lines: seq[string]; entryContext = ""): FileHighlight =
  ## The cached spans for this window of this revision, parsing only on a miss.
  ##
  ## This is the proc CTUI-5's latency gate is measured through, and
  ## `parseCount` is what makes "measured on the cached path" checkable rather
  ## than asserted.
  if cache.isNil:
    return highlightWindow(path, firstLine, lines, entryContext)
  inc cache.lookupCount
  let key = highlightKey(path, sourceGeneration, sourceDigest, firstLine, lines,
                         entryContext)
  if cache.entries.hasKey(key):
    return cache.entries[key]
  inc cache.parseCount
  result = highlightWindow(path, firstLine, lines, entryContext)
  cache.entries[key] = result
  cache.order.add key
  while cache.order.len > MaxCachedWindows:
    let oldest = cache.order[0]
    cache.order.delete(0)
    if cache.entries.hasKey(oldest):
      cache.entries.del(oldest)
      inc cache.evictions

proc clear*(cache: HighlighterCache) =
  ## Forget every parse. The counters are NOT reset: a test that cleared the
  ## cache and then asserted a parse count needs the total across the run, and
  ## resetting here would make "it re-parsed" and "it never parsed" the same
  ## number.
  if not cache.isNil:
    cache.entries.clear()
    cache.order.setLen(0)
