## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module reaches `std/*` and
## its own siblings and nothing else — in particular NOT `isonim_tui` and not
## the tree-sitter runtime — so a front-end that links no terminal renderer
## (GPUI's editor, PLAT-47 B1) classifies source with exactly the code the
## terminal does.
##
## app/syntax/lexical.nim — PLAT-47. The desktop's tokenizers, by path: which
## Monaco tokenizer lexes a file (`lexerForPath`), its tokens per line with the
## state running on from line to line (`monacoLineTokens`), the state each
## line of a window STARTS in (`lexerContexts`, `LexerContextCache`), and a
## line as classified runs of its own text (`tokenRuns`).
##
## Split out of `highlighter.nim`, which re-exports it: the terminal's cell
## spans (`lexicalLineSpans`) and GPUI's text runs are two renderings of one
## classification — `monacoLineTokens` resolved through
## `editor_theme.classForMonacoToken` — so the two editors cannot colour one
## token differently.

import std/[strutils]

import ./token_class
import ./monarch
import ./json_tokens
import ../theme/editor_theme

export token_class

func textChecksum*(lines: seq[string]): uint32
  ## A cheap FNV-1a over lines and their boundaries (defined below).

type
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
    ## Which of the desktop's Monaco tokenizers a path selects when no grammar
    ## claims it (see "Tier 2" below; `monacoLanguageOf` names each one's
    ## Monaco language).
    lxNone
    lxPython
    lxRust         ## Rust, and Noir — the desktop's editor opens `.nr` as Rust
    lxC
    lxCpp
    lxGo
    lxJavaScript
    lxTypeScript
    lxJava
    lxRuby
    lxShell
    lxJson
    lxYaml

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
  (".rs", lxRust), (".nr", lxRust),
  (".c", lxC), (".h", lxC),
  (".cpp", lxCpp), (".cc", lxCpp), (".hpp", lxCpp),
  (".go", lxGo),
  (".js", lxJavaScript), (".mjs", lxJavaScript), (".cjs", lxJavaScript),
  (".ts", lxTypeScript),
  (".java", lxJava),
  (".rb", lxRuby),
  (".sh", lxShell), (".bash", lxShell), (".zsh", lxShell),
  (".json", lxJson),
  (".yaml", lxYaml), (".yml", lxYaml)]
  ## TOML is absent on purpose: Monaco has no TOML tokenizer, so the desktop
  ## draws a `.toml` file plain and so does the terminal.

func lowerExtension*(path: string): string =
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


# ---------------------------------------------------------------------------
# Tier 2: the desktop's own tokenizers
# ---------------------------------------------------------------------------
#
# PLAT-47 requires the terminal's editor to look like the desktop's, and the
# desktop colours source with Monaco's tokenizers. Sharing the THEME is not
# enough: the generic line scanner this tier used to be classified most
# non-blank characters differently from Monaco (multi-line comments and
# strings, the keyword sets Monaco uses, the operators Monaco leaves in the
# default colour, capitalised names), measured against `monaco.editor.tokenize`
# captured from the real Electron app.
#
# So every language here is lexed by MONACO'S tokenizer for it: the Monarch
# definitions themselves, exported from the pinned `monaco-editor` and run by
# `monarch.nim` (Python, Rust — Noir too, which the desktop's editor opens as
# Rust —, C and C++, Go, JavaScript, TypeScript, Java, Ruby, shell, YAML), and
# the JSON language service's scanner, ported (`json_tokens.nim`). TOML has no
# Monaco tokenizer at all and is drawn plain, as the desktop draws it.
#
# A token's colour is the rule the desktop's theme applies to its type
# (`editor_theme.classForMonacoToken`), and the tokenizer's state runs on from
# line to line — which is how a docstring or a block comment stays one. A
# WINDOW that starts inside such a construct starts in the state the file's
# earlier lines leave (`lexerContexts`, carried with the window by
# `SourceVM.heldLineContexts`), not in the tokenizer's initial state.
#
# `tests/test_plat47_monaco_lexers.nim` compares every character of one sample
# per language with the desktop's capture, and `test_plat47_editor_theme.nim`
# every character of `calc`.

func monacoLanguageOf*(lexer: LexerId): string =
  ## The Monaco language whose tokenizer lexes `lexer`'s files. C is Monaco's
  ## `c` language, which Monaco registers with the C++ definition.
  case lexer
  of lxNone: ""
  of lxPython: "python"
  of lxRust: "rust"
  of lxC, lxCpp: "cpp"
  of lxGo: "go"
  of lxJavaScript: "javascript"
  of lxTypeScript: "typescript"
  of lxJava: "java"
  of lxRuby: "ruby"
  of lxShell: "shell"
  of lxJson: "json"
  of lxYaml: "yaml"

proc initialContext*(lexer: LexerId): string =
  ## The tokenizer state a file starts in, as the opaque context string.
  if lexer == lxJson:
    encodeJsonState(JsonLineState())
  elif lexer == lxNone:
    ""
  else:
    let lang = monarchLanguage(monacoLanguageOf(lexer))
    if lang.isNil: "" else: encodeState(lang.initialState())

proc monacoLineTokens*(lexer: LexerId; line: string;
                   context: var string): seq[MonarchToken] =
  ## One line's Monaco tokens, from `context` (the state the line starts in,
  ## "" for the file's first line), leaving `context` as the line leaves it.
  case lexer
  of lxNone:
    result = @[]
  of lxJson:
    var s = if context.len == 0: JsonLineState() else: decodeJsonState(context)
    result = jsonTokenizeLine(line, s)
    context = encodeJsonState(s)
  else:
    let lang = monarchLanguage(monacoLanguageOf(lexer))
    if lang.isNil:
      return @[]
    var s = decodeState(context)
    result = lang.tokenizeLine(line, s)
    context = encodeState(s)

proc lexerContexts*(path: string; allLines: seq[string];
                    firstLine, lastLine: int): seq[string] =
  ## The context each of lines `firstLine .. lastLine` (1-based) STARTS in:
  ## the tokenizer state the whole file's earlier lines leave. What a source
  ## provider, which holds the whole file when it slices a window, hands the
  ## window along with its text, so a window that opens inside a docstring or
  ## a block comment is coloured as the desktop colours those lines. Empty for
  ## a path no tokenizer claims.
  let lexer = if grammarForPath(path) != giNone: lxNone else: lexerForPath(path)
  if lexer == lxNone or lastLine < firstLine:
    return @[]
  var context = initialContext(lexer)
  let stopAt = min(lastLine, allLines.len)
  for i in 1 .. stopAt:
    if i >= firstLine:
      result.add context
    discard monacoLineTokens(lexer, allLines[i - 1], context)
  while result.len < lastLine - firstLine + 1:
    result.add context

type
  LexerContextCache* = ref object
    ## `lexerContexts` for the files a session keeps reopening windows of:
    ## the context of every line up to the furthest one asked for, per file
    ## text, so scrolling a window down a 10,000-line file lexes each line
    ## once rather than once per fetch. Bounded (`MaxContextFiles`), keyed by
    ## the path AND the text (length and checksum), so a new revision of a
    ## file is lexed afresh.
    files: seq[ContextEntry]

  ContextEntry = object
    path: string
    textLen: int
    textHash: uint32
    lexer: LexerId
    contexts: seq[string]   ## contexts[i]: the state line i + 1 starts in

const MaxContextFiles* = 4

proc newLexerContextCache*(): LexerContextCache =
  LexerContextCache(files: @[])


proc contextsFor*(cache: LexerContextCache; path: string;
                  allLines: seq[string]; firstLine, lastLine: int): seq[string] =
  ## `lexerContexts(path, allLines, firstLine, lastLine)`, served from and
  ## extended into `cache`.
  if cache.isNil:
    return lexerContexts(path, allLines, firstLine, lastLine)
  let lexer = if grammarForPath(path) != giNone: lxNone else: lexerForPath(path)
  if lexer == lxNone or lastLine < firstLine:
    return @[]
  var textLen = 0
  for l in allLines: textLen += l.len + 1
  let hash = textChecksum(allLines)
  var idx = -1
  for i, e in cache.files:
    if e.path == path and e.textLen == textLen and e.textHash == hash:
      idx = i
      break
  if idx < 0:
    cache.files.add ContextEntry(path: path, textLen: textLen, textHash: hash,
                                 lexer: lexer,
                                 contexts: @[initialContext(lexer)])
    if cache.files.len > MaxContextFiles:
      cache.files.delete(0)
    idx = cache.files.high
  let need = min(lastLine, allLines.len)
  var context = cache.files[idx].contexts[^1]
  while cache.files[idx].contexts.len < need:
    let line = cache.files[idx].contexts.len   # 1-based line to lex
    discard monacoLineTokens(lexer, allLines[line - 1], context)
    cache.files[idx].contexts.add context
  for line in firstLine .. lastLine:
    result.add(if line - 1 < cache.files[idx].contexts.len:
                 cache.files[idx].contexts[line - 1]
               else: cache.files[idx].contexts[^1])

type
  TokenRun* = object
    ## One run of a line's text in one class: `text` is a substring of the
    ## line, and the runs of a line concatenate to exactly the line.
    text*: string
    class*: TokenClass

proc tokenRuns*(lexer: LexerId; line: string;
                context: var string): seq[TokenRun] =
  ## One line as classified runs covering ALL of it — the plain text between
  ## tokens included, as `tcPlain` — starting in `context` and leaving
  ## `context` as the line leaves it. Adjacent runs of one class are joined.
  ## For a medium that draws text runs rather than cells (GPUI's editor).
  result = @[]
  if line.len == 0:
    discard monacoLineTokens(lexer, line, context)
    return
  let tokens = monacoLineTokens(lexer, line, context)
  var at = 0
  proc push(acc: var seq[TokenRun]; text: string; cls: TokenClass) =
    if text.len == 0: return
    if acc.len > 0 and acc[^1].class == cls:
      acc[^1].text.add text
    else:
      acc.add TokenRun(text: text, class: cls)
  for i, t in tokens:
    let start = max(at, min(t.start, line.len))
    if start > at:
      result.push(line[at ..< start], tcPlain)
      at = start
    let stop = if i + 1 < tokens.len: min(tokens[i + 1].start, line.len)
               else: line.len
    if stop <= at:
      continue
    result.push(line[at ..< stop], classForMonacoToken(t.tokenType))
    at = stop
  if at < line.len:
    result.push(line[at .. ^1], tcPlain)

func textChecksum*(lines: seq[string]): uint32 =
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
