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
##   2. **No grammar, but a lexer this module knows** — `.py`, `.rs`, `.nr`,
##      `.js`, `.ts`, `.c`, `.h`, `.cpp`, `.go`, `.rb`, `.sh`, `.json`, `.toml`,
##      `.yaml`. This is the "lexical fallback": strings, numbers, comments and
##      the language's own keyword set, found by scanning the line. It matters
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

  GrammarId* = enum
    ## Which of the ten vendored grammars a path selects, or neither of the two
    ## fallbacks.
    giNone
    giNim
    giAiken
    giCairo
    giCadence
    giCircom
    giLeo
    giMasm
    giMoveOnAptos
    giSway
    giTolk

  LexerId* = enum
    ## Which lexical fallback a path selects when no grammar claims it.
    lxNone
    lxPython
    lxRustLike     ## Rust, Noir — `//`, `/* */`, the same literal shapes
    lxCLike        ## C, C++, Go, JavaScript, TypeScript
    lxRuby
    lxShell
    lxData         ## JSON, TOML, YAML: strings, numbers, `#` comments

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

const GrammarExtensions*: seq[(string, GrammarId)] = @[
  (".nim", giNim), (".nims", giNim), (".nimble", giNim),
  (".ak", giAiken),
  (".cairo", giCairo),
  (".cdc", giCadence),
  (".circom", giCircom),
  (".leo", giLeo),
  (".masm", giMasm),
  (".move", giMoveOnAptos),
  (".sw", giSway),
  (".tolk", giTolk)]
  ## The ten vendored grammars, by the extension each language uses. A `seq` of
  ## pairs rather than a `case`, so `test_syntax_highlighting_ansi.nim` can
  ## assert the COUNT of grammars reached — ten, which is the number
  ## `scripts/build-tui-grammars.sh` archives — instead of testing whichever
  ## ones somebody remembered.

const LexerExtensions*: seq[(string, LexerId)] = @[
  (".py", lxPython), (".pyi", lxPython),
  (".rs", lxRustLike), (".nr", lxRustLike),
  (".c", lxCLike), (".h", lxCLike), (".cpp", lxCLike), (".cc", lxCLike),
  (".hpp", lxCLike), (".go", lxCLike), (".js", lxCLike), (".ts", lxCLike),
  (".java", lxCLike),
  (".rb", lxRuby),
  (".sh", lxShell), (".bash", lxShell), (".zsh", lxShell),
  (".json", lxData), (".toml", lxData), (".yaml", lxData), (".yml", lxData)]

func lowerExtension(path: string): string =
  ## The path's extension, lowercased, INCLUDING the dot; "" when it has none.
  ##
  ## Split on both separators, because a recorded path is whatever a recorder
  ## interned and a Windows recording carries backslashes on a Linux replay
  ## host — the same reason `ct/trace/ctfs_sources.safePayloadPath` splits on
  ## both.
  var base = path
  for i in countdown(base.high, 0):
    if base[i] == '/' or base[i] == '\\':
      base = base[i + 1 .. ^1]
      break
  let dot = base.rfind('.')
  if dot < 0 or dot == base.high:
    return ""
  base[dot .. ^1].toLowerAscii()

proc grammarForPath*(path: string): GrammarId =
  ## Which vendored grammar claims `path`, or `giNone`.
  let ext = lowerExtension(path)
  if ext.len == 0:
    return giNone
  for (candidate, grammar) in GrammarExtensions:
    if candidate == ext:
      return grammar
  giNone

proc lexerForPath*(path: string): LexerId =
  ## Which lexical fallback claims `path`, or `lxNone`.
  let ext = lowerExtension(path)
  if ext.len == 0:
    return lxNone
  for (candidate, lexer) in LexerExtensions:
    if candidate == ext:
      return lexer
  lxNone

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
# Tier 2: the lexical fallback
# ---------------------------------------------------------------------------

const
  PythonKeywords = ["False", "None", "True", "and", "as", "assert", "async",
                    "await", "break", "class", "continue", "def", "del",
                    "elif", "else", "except", "finally", "for", "from",
                    "global", "if", "import", "in", "is", "lambda", "nonlocal",
                    "not", "or", "pass", "raise", "return", "try", "while",
                    "with", "yield"]
  RustLikeKeywords = ["as", "assert", "break", "comptime", "const",
                      "constrain", "continue", "crate", "dep", "else", "enum",
                      "extern", "false", "fn", "for", "global", "if", "impl",
                      "in", "let", "loop", "match", "mod", "move", "mut",
                      "pub", "ref", "return", "self", "static", "struct",
                      "super", "trait", "true", "type", "unconstrained",
                      "unsafe", "use", "where", "while"]
  CLikeKeywords = ["break", "case", "char", "class", "const", "continue",
                   "default", "delete", "do", "double", "else", "enum",
                   "export", "extern", "false", "float", "for", "func",
                   "function", "go", "if", "import", "int", "interface", "let",
                   "long", "new", "package", "private", "public", "return",
                   "short", "sizeof", "static", "struct", "switch", "this",
                   "true", "type", "typedef", "union", "unsigned", "var",
                   "void", "while"]
  RubyKeywords = ["alias", "and", "begin", "break", "case", "class", "def",
                  "do", "else", "elsif", "end", "ensure", "false", "for", "if",
                  "in", "module", "next", "nil", "not", "or", "redo", "rescue",
                  "retry", "return", "self", "super", "then", "true", "undef",
                  "unless", "until", "when", "while", "yield"]
  ShellKeywords = ["case", "do", "done", "elif", "else", "esac", "export",
                   "fi", "for", "function", "if", "in", "local", "return",
                   "then", "until", "while"]
  DataKeywords = ["false", "null", "true"]

func keywordsFor(lexer: LexerId): seq[string] =
  case lexer
  of lxNone: @[]
  of lxPython: @PythonKeywords
  of lxRustLike: @RustLikeKeywords
  of lxCLike: @CLikeKeywords
  of lxRuby: @RubyKeywords
  of lxShell: @ShellKeywords
  of lxData: @DataKeywords

func lineCommentMarkers(lexer: LexerId): seq[string] =
  case lexer
  of lxNone: @[]
  of lxPython, lxRuby, lxShell, lxData: @["#"]
  of lxRustLike, lxCLike: @["//"]

func isIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_'}
func isIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc lexicalSpansForLine(lexer: LexerId; line: string): seq[SyntaxSpan] =
  ## Classify one line by scanning it.
  ##
  ## SINGLE-LINE ONLY, and deliberately: a pane holds a window, so a scanner
  ## that carried state across lines would produce different colours for the
  ## same line depending on how far the user had scrolled. A triple-quoted
  ## Python docstring is therefore coloured as a string on the lines that open
  ## and close it and as code in between — a visible limitation, written down
  ## rather than papered over, and the reason the ten grammars exist.
  result = @[]
  if lexer == lxNone or line.len == 0:
    return
  let keywords = keywordsFor(lexer)
  let comments = lineCommentMarkers(lexer)
  var raw: seq[SyntaxSpan] = @[]
  var i = 0
  while i < line.len:
    var isComment = false
    for marker in comments:
      if i + marker.len <= line.len and line[i ..< i + marker.len] == marker:
        raw.add SyntaxSpan(
          startCell: cellOffsetAtByte(line, i),
          endCell: cellOffsetAtByte(line, line.len),
          class: tcComment)
        isComment = true
        break
    if isComment:
      break
    let c = line[i]
    if c == '"' or c == '\'':
      let quote = c
      let start = i
      inc i
      while i < line.len:
        if line[i] == '\\' and i + 1 < line.len:
          i += 2
          continue
        if line[i] == quote:
          inc i
          break
        inc i
      raw.add SyntaxSpan(
        startCell: cellOffsetAtByte(line, start),
        endCell: cellOffsetAtByte(line, i),
        class: tcString)
      continue
    if c in {'0'..'9'}:
      let start = i
      while i < line.len and (line[i] in {'0'..'9', '.', '_'} or
                              line[i] in {'x', 'X', 'a'..'f', 'A'..'F'}):
        inc i
      raw.add SyntaxSpan(
        startCell: cellOffsetAtByte(line, start),
        endCell: cellOffsetAtByte(line, i),
        class: tcNumber)
      continue
    if isIdentStart(c):
      let start = i
      while i < line.len and isIdentChar(line[i]):
        inc i
      let word = line[start ..< i]
      var cls = tcIdentifier
      for kw in keywords:
        if kw == word:
          cls = tcKeyword
          break
      if cls == tcIdentifier and word.len > 0 and word[0] in {'A'..'Z'}:
        # A capitalised identifier is a TYPE in every language this lexer
        # covers. Not a grammar rule, a convention — and it is what makes the
        # `tcType` class reachable at all on the two fixtures in this
        # campaign's corpus, neither of which has a vendored grammar.
        cls = tcType
      raw.add SyntaxSpan(
        startCell: cellOffsetAtByte(line, start),
        endCell: cellOffsetAtByte(line, i),
        class: cls)
      continue
    let start = i
    inc i
    let sym = $c
    if sym.isIn(PunctuationTokens):
      raw.add SyntaxSpan(
        startCell: cellOffsetAtByte(line, start),
        endCell: cellOffsetAtByte(line, i),
        class: tcPunctuation)
    elif sym.isIn(OperatorTokens):
      raw.add SyntaxSpan(
        startCell: cellOffsetAtByte(line, start),
        endCell: cellOffsetAtByte(line, i),
        class: tcOperator)
  result = mergeSpans(raw)

# ---------------------------------------------------------------------------
# Tier 2, Python: the desktop's own tokenizer, ported
# ---------------------------------------------------------------------------
#
# PLAT-47 requires the terminal's editor to look like the desktop's, and the
# desktop colours Python with Monaco's Monarch tokenizer
# (`monaco-editor/esm/vs/basic-languages/python/python.js`, monaco-editor
# 0.54.0, the copy `src/public/third_party/monaco-editor` links). Sharing the
# THEME is not enough: the generic line scanner below classified 57% of the
# non-blank characters of the `calc` fixture differently from Monaco (every
# docstring line after the first, the builtins Monaco calls keywords, the
# operators Monaco leaves in the default colour, capitalised names), measured
# against `monaco.editor.tokenize` captured from the real Electron app.
#
# So Python is lexed by a port of THAT tokenizer: the same states, the same
# rules in the same order, the same keyword list, the same scopes. Each branch
# below cites the Monarch rule it implements. Monarch matches each rule at the
# current position of the line (`^(?:rule)` over `line.substr(pos)`), so a
# rule's `^` is "here" and its `$` is "the end of this line"; a position no
# rule matches is ONE character in the default scope (`defaultToken: ""`).
# The state survives the end of a line, which is how a docstring stays a
# string across lines.
#
# The class of each scope (`tcKeyword` for `keyword`, `tcStringEscape` for
# `string.escape`, ...) goes back to a scope through
# `editor_theme.TokenClassScope`, so a character's colour is the rule Monaco
# resolves for the scope the desktop gives it.
# `tests/test_plat47_editor_theme.nim` compares every character of `calc`
# with the desktop's capture.

type
  PyState = enum
    ## Monarch's tokenizer states for Python (the `tokenizer` object's keys).
    psRoot            ## `root` (with `whitespace`, `numbers`, `strings`)
    psDocSingle       ## `endDocString`
    psDocDouble       ## `endDblDocString`
    psStringSingle    ## `stringBody`
    psStringDouble    ## `dblStringBody`
    psFStringSingle   ## `fStringBody`
    psFStringDouble   ## `fDblStringBody`
    psFStringDetail   ## `fStringDetail`

  PythonLexState* = object
    ## Monarch's state stack, carried from one line to the next.
    stack: seq[PyState]

const
  MonacoPythonKeywords = [
    "False", "None", "True", "_", "and", "as", "assert", "async", "await",
    "break", "case", "class", "continue", "def", "del", "elif", "else",
    "except", "exec", "finally", "for", "from", "global", "if", "import",
    "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "print",
    "raise", "return", "try", "type", "while", "with", "yield", "int",
    "float", "long", "complex", "hex", "abs", "all", "any", "apply",
    "basestring", "bin", "bool", "buffer", "bytearray", "callable", "chr",
    "classmethod", "cmp", "coerce", "compile", "delattr", "dict", "dir",
    "divmod", "enumerate", "eval", "execfile", "file", "filter", "format",
    "frozenset", "getattr", "globals", "hasattr", "hash", "help", "id",
    "input", "intern", "isinstance", "issubclass", "iter", "len", "locals",
    "list", "map", "max", "memoryview", "min", "next", "object", "oct",
    "open", "ord", "pow", "property", "reversed", "range", "raw_input",
    "reduce", "reload", "repr", "round", "self", "set", "setattr", "slice",
    "sorted", "staticmethod", "str", "sum", "super", "tuple", "unichr",
    "unicode", "vars", "xrange", "zip", "__dict__", "__methods__",
    "__members__", "__class__", "__bases__", "__name__", "__mro__",
    "__subclasses__", "__init__", "__import__"]
    ## Monarch's `keywords` for Python, verbatim (it names builtins such as
    ## `len`, `print` and `self` too, and the desktop colours them as
    ## keywords). Its repeats (`complex`, `print`, `reversed`, `type`) are
    ## listed once here; membership is all that is asked.
  JsSpace = {' ', '\t', '\v', '\f', '\r'}
    ## JavaScript's `\s` over the bytes a source line can hold (a line has no
    ## `\n`); a non-ASCII space falls to the default scope, one rune.
  PyIdentStart = {'a'..'z', 'A'..'Z', '_'}
  PyWordChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  PyDetailStops = {'}', '\'', ':', '!', '='}

func initPythonLexState*(): PythonLexState =
  PythonLexState(stack: @[psRoot])

func oneChar(line: string; i: int): int =
  ## One rune's bytes at `i`: Monarch's "one character" default token (a
  ## UTF-16 unit there; the colour is the default either way).
  max(1, int(runeLenAt(line, i)))

func runUntil(line: string; start: int; stops: set[char]): int =
  var j = start
  while j < line.len and line[j] notin stops: inc j
  j - start

func charAt(line: string; i: int): char =
  if i >= 0 and i < line.len: line[i] else: '\0'

func matchPythonNumber(line: string; pos: int): int =
  ## The length of Monarch's `numbers` match at `pos`, or 0:
  ##   /-?0x([abcdef]|[ABCDEF]|\d)+[lL]?/            number.hex
  ##   /-?(\d*\.)?\d+([eE][+\-]?\d+)?[jJ]?[lL]?/     number
  ## (with JavaScript's backtracking out of the optional `(\d*\.)` group).
  var i = pos
  if charAt(line, i) == '-': inc i
  if charAt(line, i) == '0' and charAt(line, i + 1) == 'x':
    var j = i + 2
    while j < line.len and line[j] in {'0'..'9', 'a'..'f', 'A'..'F'}: inc j
    if j > i + 2:
      if charAt(line, j) in {'l', 'L'}: inc j
      return j - pos
  var ends = -1
  var k = i
  while k < line.len and line[k] in {'0'..'9'}: inc k
  if charAt(line, k) == '.':
    var m = k + 1
    while m < line.len and line[m] in {'0'..'9'}: inc m
    if m > k + 1: ends = m          # (\d*\.)\d+
  if ends < 0:
    if k > i: ends = k              # \d+
    else: return 0
  var e = ends
  if charAt(line, e) in {'e', 'E'}:
    var x = e + 1
    if charAt(line, x) in {'+', '-'}: inc x
    var y = x
    while y < line.len and line[y] in {'0'..'9'}: inc y
    if y > x: e = y
  if charAt(line, e) in {'j', 'J'}: inc e
  if charAt(line, e) in {'l', 'L'}: inc e
  e - pos

proc pythonLineSpans*(line: string; state: var PythonLexState): seq[SyntaxSpan] =
  ## One line of Python, classified as the desktop's Monaco tokenizer
  ## classifies it, starting in `state` and leaving `state` as the line
  ## leaves it.
  if state.stack.len == 0:
    state.stack = @[psRoot]
  var raw: seq[SyntaxSpan] = @[]
  var pos = 0
  template emit(n: int; cls: TokenClass) =
    let stop = min(line.len, pos + n)
    if cls != tcPlain:
      raw.add SyntaxSpan(startCell: cellOffsetAtByte(line, pos),
                         endCell: cellOffsetAtByte(line, stop), class: cls)
    pos = stop
  template popAll() = state.stack = @[psRoot]
  template push(s: PyState) = state.stack.add s

  while pos < line.len:
    let c = line[pos]
    case state.stack[^1]
    of psRoot:
      # ---- `whitespace` ----
      if c in JsSpace:                                   # /\s+/  white
        var j = pos
        while j < line.len and line[j] in JsSpace: inc j
        emit(j - pos, tcPlain)
      elif c == '#':                                     # /(^#.*$)/  comment
        emit(line.len - pos, tcComment)
      elif line.continuesWith("'''", pos):               # /'''/  @endDocString
        emit(3, tcString)
        push psDocSingle
      elif line.continuesWith("\"\"\"", pos):            # /"""/  @endDblDocString
        emit(3, tcString)
        push psDocDouble
      # ---- `numbers` ----
      elif matchPythonNumber(line, pos) > 0:             # number / number.hex
        emit(matchPythonNumber(line, pos), tcNumber)
      # ---- `strings` ----
      elif c == '\'' and pos == line.high:               # /'$/  string.escape, @popall
        emit(1, tcStringEscape)
        popAll()
      elif c == 'f' and charAt(line, pos + 1) == '\'':   # /f'{1,3}/  @fStringBody
        var n = 1
        while n < 3 and charAt(line, pos + 1 + n) == '\'': inc n
        emit(1 + n, tcStringEscape)
        push psFStringSingle
      elif c == '\'':                                    # /'/  @stringBody
        emit(1, tcStringEscape)
        push psStringSingle
      elif c == '"' and pos == line.high:                # /"$/  string.escape, @popall
        emit(1, tcStringEscape)
        popAll()
      elif c == 'f' and charAt(line, pos + 1) == '"':    # /f"{1,3}/  @fDblStringBody
        var n = 1
        while n < 3 and charAt(line, pos + 1 + n) == '"': inc n
        emit(1 + n, tcStringEscape)
        push psFStringDouble
      elif c == '"':                                     # /"/  @dblStringBody
        emit(1, tcStringEscape)
        push psStringDouble
      # ---- `root` ----
      elif c in {',', ':', ';'}:                         # /[,:;]/  delimiter
        emit(1, tcPunctuation)
      elif c in {'[', ']'}:                              # @brackets: delimiter.bracket
        emit(1, tcBracket)
      elif c in {'{', '}', '(', ')'}:                    # @brackets: .curly / .parenthesis
        emit(1, tcPunctuation)
      elif c == '@' and charAt(line, pos + 1) in PyIdentStart:   # /@[a-zA-Z_]\w*/  tag
        var j = pos + 2
        while j < line.len and line[j] in PyWordChars: inc j
        emit(j - pos, tcTag)
      elif c in PyIdentStart:                            # /[a-zA-Z_]\w*/  keyword | identifier
        var j = pos + 1
        while j < line.len and line[j] in PyWordChars: inc j
        let cls = if line[pos ..< j] in MonacoPythonKeywords: tcKeyword
                  else: tcIdentifier
        emit(j - pos, cls)
      else:                                              # no rule: defaultToken ""
        emit(oneChar(line, pos), tcPlain)
    of psDocSingle, psDocDouble:
      let q = if state.stack[^1] == psDocSingle: '\'' else: '"'
      if c != q:                                         # /[^']+/  string
        emit(runUntil(line, pos, {q}), tcString)
      elif charAt(line, pos + 1) == q and charAt(line, pos + 2) == q:
        emit(3, tcString)                                # /'''/  string, @popall
        popAll()
      else:                                              # /'/  string
        emit(1, tcString)
    of psStringSingle, psStringDouble:
      let q = if state.stack[^1] == psStringSingle: '\'' else: '"'
      let run = runUntil(line, pos, {'\\', q})
      if run > 0 and pos + run == line.len:              # /[^\\']+$/  string, @popall
        emit(run, tcString)
        popAll()
      elif run > 0:                                      # /[^\\']+/  string
        emit(run, tcString)
      elif c == '\\' and pos + 1 < line.len:             # /\\./  string
        emit(1 + oneChar(line, pos + 1), tcString)
      elif c == q:                                       # /'/  string.escape, @popall
        emit(1, tcStringEscape)
        popAll()
      else:                                              # /\\$/  string (state goes on)
        emit(1, tcString)
    of psFStringSingle, psFStringDouble:
      let q = if state.stack[^1] == psFStringSingle: '\'' else: '"'
      let run = runUntil(line, pos, {'\\', q, '{', '}'})
      if run > 0 and pos + run == line.len:              # /[^\\'\{\}]+$/  string, @popall
        emit(run, tcString)
        popAll()
      elif run > 0:                                      # /[^\\'\{\}]+/  string
        emit(run, tcString)
      elif c == '{' and pos + 1 < line.len and line[pos + 1] notin PyDetailStops:
        var j = pos + 1                                  # /\{[^\}':!=]+/  identifier, @fStringDetail
        while j < line.len and line[j] notin PyDetailStops: inc j
        emit(j - pos, tcIdentifier)
        push psFStringDetail
      elif c == '\\' and pos + 1 < line.len:             # /\\./  string
        emit(1 + oneChar(line, pos + 1), tcString)
      elif c == q:                                       # /'/  string.escape, @popall
        emit(1, tcStringEscape)
        popAll()
      elif c == '\\':                                    # /\\$/  string
        emit(1, tcString)
      else:                                              # no rule: defaultToken ""
        emit(1, tcPlain)
    of psFStringDetail:
      if c == ':' and pos + 1 < line.len and line[pos + 1] != '}':
        emit(1 + runUntil(line, pos + 1, {'}'}), tcString)   # /[:][^}]+/  string
      elif c == '!' and charAt(line, pos + 1) in {'a', 'r', 's'}:
        emit(2, tcString)                                # /[!][ars]/  string
      elif c == '=':                                     # /=/  string
        emit(1, tcString)
      elif c == '}':                                     # /\}/  identifier, @pop
        emit(1, tcIdentifier)
        state.stack.setLen(state.stack.len - 1)
      else:                                              # no rule: defaultToken ""
        emit(oneChar(line, pos), tcPlain)
  result = mergeSpans(raw)

# ---------------------------------------------------------------------------
# The public entry point
# ---------------------------------------------------------------------------

proc highlightWindow*(path: string; firstLine: int;
                      lines: seq[string]): FileHighlight =
  ## Classify `lines` (line `firstLine` onwards) of `path`. Never raises for a
  ## path this module does not recognise: the answer is `hmNone` and no spans.
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
    if result.lexer == lxPython:
      # The desktop's tokenizer, whose state runs on from line to line. It
      # starts at the WINDOW's first line in Monarch's initial state, which is
      # Monaco's state there whenever the window starts at line 1 or outside
      # a multi-line string (see `pythonLineSpans`).
      var state = initPythonLexState()
      for i, line in lines:
        result.lines[i] = pythonLineSpans(line, state)
    else:
      for i, line in lines:
        result.lines[i] = lexicalSpansForLine(result.lexer, line)

proc spansForLine*(h: FileHighlight; line: int): seq[SyntaxSpan] =
  ## The spans of one 1-based line, or none when it is outside the window.
  let idx = line - h.firstLine
  if idx < 0 or idx >= h.lines.len: @[]
  else: h.lines[idx]

# ---------------------------------------------------------------------------
# The cache
# ---------------------------------------------------------------------------

func textChecksum(lines: seq[string]): uint32 =
  ## A cheap FNV-1a over the window's bytes and its line boundaries.
  ##
  ## Not a cryptographic digest and not claimed to be one: its job is to make
  ## "the window scrolled" a cache MISS, and a scroll changes both the length
  ## and the content. `sourceDigest` — the identity triple's own field, carried
  ## in the key beside this — is what distinguishes two BUILDS.
  result = 2166136261'u32
  for line in lines:
    for ch in line:
      result = (result xor uint32(ord(ch))) * 16777619'u32
    result = (result xor 10'u32) * 16777619'u32

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
                   firstLine: int; lines: seq[string]): HighlightKey =
  var textLen = 0
  for line in lines:
    textLen += line.len + 1
  HighlightKey(path: path, sourceGeneration: sourceGeneration,
               sourceDigest: sourceDigest, firstLine: firstLine,
               textLen: textLen, textHash: textChecksum(lines))

proc highlight*(cache: HighlighterCache; path: string; sourceGeneration: int;
                sourceDigest: string; firstLine: int;
                lines: seq[string]): FileHighlight =
  ## The cached spans for this window of this revision, parsing only on a miss.
  ##
  ## This is the proc CTUI-5's latency gate is measured through, and
  ## `parseCount` is what makes "measured on the cached path" checkable rather
  ## than asserted.
  if cache.isNil:
    return highlightWindow(path, firstLine, lines)
  inc cache.lookupCount
  let key = highlightKey(path, sourceGeneration, sourceDigest, firstLine, lines)
  if cache.entries.hasKey(key):
    return cache.entries[key]
  inc cache.parseCount
  result = highlightWindow(path, firstLine, lines)
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
