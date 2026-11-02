## host/text_match.nim — where a pattern occurs in one line of text.
##
## The matching rule Find in Files uses (Find-And-Incremental-Search.md §5.1:
## *"matched literally … fixed string, case-insensitive"*, with the pane's
## Match Case, Whole Word and Use Regular Expression toggles). It is pure — no
## filesystem, no process — so the in-process walker of `find_in_files.nim`
## beside it runs it on the C backend (terminal, GPUI) and on the JS backend
## (Electron's main process) alike, and it is the rule the walker is graded
## against `rg` with (FS-8).
##
## It sits beside the runner, its one caller, and NOT in `editor/`: it is
## built on a third-party engine, and the editor core's import closure is an
## allow-list of `std/` modules (`ci/test/editor-import-closure.sh`, PLAT-29)
## that a regular-expression library does not belong in. The pane's toggles,
## `TextMatchOptions`, are a value of `store/types`, so the ViewModel that
## holds them imports no matcher.
##
## ## One engine, built the way `rg` builds its own
##
## A pattern and its options are compiled once (`compileTextMatcher`) into a
## regular expression of nim-regex (`libs/nim-regex`), a pure-Nim engine
## modelled on Rust's `regex` crate — the engine and the syntax `rg` uses —
## that compiles to C and to JS. The expression is the one `rg` builds from
## the same flags:
##
## * **Literal** (the default, `rg -F`): the pattern escaped, so every
##   character stands for itself.
## * **Regular expression** (`rg` without `-F`): the pattern as written, in
##   the syntax the two engines share. What only nim-regex accepts is refused
##   here with `rg`'s reason (`refusalOf`), so a pattern either runs on both
##   engines or on neither.
## * **Case** (`rg -i` by default, `--case-sensitive` with Match Case): Unicode
##   simple case folding, as the `regex` crate folds — `ς`, `σ` and `Σ` are
##   one letter, as are `k`, `K` and the Kelvin sign.
## * **Whole word** (`rg -w`): a match with no word character immediately
##   before or after it. `rg` writes that as `\b{start-half}` and
##   `\b{end-half}` around the pattern; nim-regex spells the same assertions
##   as a negative look-behind and look-ahead of `\w`. The assertions are part
##   of the expression, so a pattern with alternatives finds the alternative
##   that stands as a word (`foo|foobar` in `foobar`), as `rg`'s does.
##
## Offsets are bytes of the ORIGINAL line, as `rg --json` reports them.
##
## ## Where nim-regex reads a regular expression differently, and what happens
##
## Measured against `rg` 15 (the agreement suite, FS-8, runs the corpus
## under every combination of the toggles):
##
## * **refused here, accepted by `rg`:** a Unicode class names a general
##   category only (`\p{L}`, `\p{Lu}`, `\pN`); a script or a binary
##   property (`\p{Greek}`, `\p{Uppercase}`) does not compile, and the search
##   says so rather than running on either engine;
## * **matched differently, case-insensitively only:** nim-regex does not
##   fold a POSIX or Unicode CLASS (`[[:upper:]]`, `\p{Lu}`), and a bracket
##   RANGE (`[a-z]`) misses the third case form of the two ASCII letters that
##   have one — the Kelvin sign of `k` and the long `ſ` of `s` (a single
##   letter in brackets, `[k]`, folds fully). `rg` folds all of them. Literal characters — every literal search, and the letters
##   of an expression — fold as `rg` folds them. The walker answers only
##   where `rg` is not installed; with Match Case on, or `(?-i)` in the
##   pattern, the two read every such class alike.
##
## PLAT-70 Part C's document find (`matchesOf`, FS-1) is a matcher over a
## whole document with the find session's options; it decides whether the
## editor core may take this engine or keeps a literal matcher of its own.

import regex

import ../store/types

export types.TextMatchOptions

type
  TextMatcher* = object
    ## A pattern compiled with its options. An empty pattern occurs nowhere.
    empty: bool
    rx: Regex2

  CompiledMatcher* = tuple[ok: bool, matcher: TextMatcher, error: string]
    ## `compileTextMatcher`'s answer: the matcher, or why the pattern is not
    ## one (`error`, the words a pane shows).

func refusalOf*(pattern: string): string =
  ## Why `rg` refuses a regular expression that nim-regex would accept — ""
  ## when it does not. The `regex` crate has no look-around and no
  ## back-reference (nim-regex reads `\1` as an octal escape), and `rg`
  ## refuses a pattern that names a line terminator, since it searches line
  ## by line. A character class is no exception to any of them.
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '\\' and i + 1 < pattern.len:
      let next = pattern[i + 1]
      if next in {'0' .. '9'}:
        return "back-references are not supported"
      if next == 'n':
        return "a pattern cannot match a line break"
      i += 2
      continue
    if c == '(' and i + 2 < pattern.len and pattern[i + 1] == '?':
      let k = pattern[i + 2]
      if k in {'=', '!'} or
         (k == '<' and i + 3 < pattern.len and pattern[i + 3] in {'=', '!'}):
        return "look-around, including look-ahead and look-behind, " &
               "is not supported"
    inc i
  ""

func expressionOf*(pattern: string; options: TextMatchOptions): string =
  ## The regular expression `pattern` is searched with under `options`,
  ## written as `rg` writes its own: the literal escaped, the whole-word
  ## assertions around it. (Case is a flag of the compile, not a prefix, so
  ## a pattern's own `(?-i)` still wins, as it does in `rg`.)
  result = if options.regex: pattern else: escapeRe(pattern)
  if options.wholeWord:
    result = "(?<!\\w)(?:" & result & ")(?!\\w)"

proc compileTextMatcher*(pattern: string;
                         options: TextMatchOptions): CompiledMatcher =
  ## Compile `pattern` once for a search. Not ok — with the reason — when it
  ## is a regular expression the two engines do not both accept.
  if pattern.len == 0:
    return (true, TextMatcher(empty: true), "")
  if options.regex:
    let refused = refusalOf(pattern)
    if refused.len > 0:
      return (false, TextMatcher(empty: true),
              "invalid regular expression: " & refused)
  let flags = if options.caseSensitive: RegexFlags({})
              else: {regexCaseless}
  try:
    (true, TextMatcher(rx: re2(expressionOf(pattern, options), flags)), "")
  except RegexError as e:
    (false, TextMatcher(empty: true), "invalid regular expression: " & e.msg)

func firstMatch*(m: TextMatcher; line: string):
    tuple[found: bool, first, stop: int] =
  ## The leftmost match in `line`, which is the one a Find in Files row opens
  ## at: its byte range `first ..< stop` (`stop == first` for an empty
  ## match, which a regular expression like `a*` can make).
  if m.empty:
    return (false, 0, 0)
  var found: RegexMatch2
  if not line.find(m.rx, found):
    return (false, 0, 0)
  (true, found.boundaries.a, found.boundaries.b + 1)

func matchSpans*(m: TextMatcher; line: string): seq[Slice[int]] =
  ## Every non-empty, non-overlapping match in `line`, left to right, as
  ## inclusive byte ranges (`s.a` the first byte, `s.b` the last).
  if m.empty:
    return
  for found in line.findAll(m.rx):
    if found.boundaries.b >= found.boundaries.a:
      result.add found.boundaries

proc matchSpans*(line, pattern: string;
                 options: TextMatchOptions): seq[Slice[int]] =
  ## `matchSpans` of `pattern` compiled with `options`; none when it does not
  ## compile.
  let c = compileTextMatcher(pattern, options)
  if c.ok: c.matcher.matchSpans(line) else: @[]
