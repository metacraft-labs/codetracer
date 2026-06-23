## Per-language function-body extraction — the M3 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign.
##
## M1 extracted a function's body with a single inline indentation heuristic
## tuned for the Ruby fixture. M3 generalises that into a *language-agnostic*
## `FunctionBodyExtractor` abstraction: a registry mapping a source-file
## extension to an extractor proc. The deep-hash engine (`engine.nim`) selects
## an extractor purely by file extension and otherwise contains NO per-language
## logic — adding a language means adding an extractor here, nothing else.
##
## An extractor is:
##
##   ExtractorProc = proc(sourceLines: seq[string]; defLine: int):
##       Result[string, string]
##
## It receives the source file already split on `\n` (1-based `defLine` is the
## function's definition line as the trace records it) and returns the captured
## body text, or an `Err` describing why extraction failed (line out of range,
## no opening brace found, …). The engine maps any `Err`/missing body to the
## reserved `"missing"` shallow hash, so a function the extractor cannot read is
## treated as *changed* and the test re-runs — never a silent wrong hash.
##
## Selection is by lowercased file extension (`.rb`, `.py`, `.js`). An UNKNOWN
## extension yields a clear `Err` from `extractorFor`, so an unsupported file
## can fail-safe to a re-run rather than being hashed with the wrong strategy.
##
## # Per-language extraction rules (documented)
##
## ## Ruby (`.rb`) — indentation heuristic (the M1 rule, preserved verbatim)
##
##   * The body starts at `defLine`. Let `indent` be the leading-whitespace
##     width of the `def` line.
##   * The body is the `def` line plus every following line up to but NOT
##     including the next *non-blank* line whose indentation is `<= indent`
##     (a sibling/closing construct, e.g. the matching `end` at the def's own
##     indent). Blank lines never terminate the body; trailing blank lines that
##     were carried along are dropped.
##   * Sufficient for change detection: any edit inside the body or to the `def`
##     signature changes the captured text; edits to sibling functions do not.
##
## ## Python (`.py`) — indentation heuristic (`def`)
##
##   Python suites are indentation-delimited, so the rule mirrors Ruby's: the
##   body is the `def` line through the last line more deeply indented than the
##   `def` (the next line at `<= def indent` ends the suite). Blank lines are
##   carried along and trailing blanks dropped. A decorator line ABOVE the `def`
##   is not part of the captured body (the trace records the `def` line itself),
##   which is acceptable — editing the function body or signature still changes
##   the captured text. Documented limitation: a continuation/blank-line layout
##   that dedents inside a multi-line expression is not specially handled; the
##   fixtures do not exercise that and any such edit only ever *over*-captures,
##   which stays conservative (it can cause a re-run, never a false skip).
##
## ## Nim (`.nim`) — indentation heuristic (`proc`/`func`/`method`/`template`/`macro`)
##
##   Nim routine bodies are indentation-delimited (like Python suites), so the
##   rule reuses the SAME `extractByIndentation` strategy as Ruby/Python: the
##   body is the routine's definition line through the last line indented more
##   deeply than the definition line — the next non-blank line at indentation
##   `<= def indent` (a sibling `proc`/`func`/`method`/`template`/`macro`, a
##   dedented top-level statement, or end-of-file) ends the routine. Blank lines
##   are carried along and trailing blanks dropped.
##
##   The `.nim` extension is registered to this strategy purely as a SOURCE-text
##   hasher. It is selected when a Nim trace was recorded the *materialized
##   source* way (CodeTracer emits canonical `Function`/`Call` records ⇒
##   `tbSourceInterpreted` ⇒ this extractor). When the SAME Nim program is
##   instead recorded the *native / compiled-via-C MCR* way the engine does NOT
##   reach this extractor at all: `detectBackend` selects `tbNativeDwarf` and the
##   function is hashed from its compiled instruction bytes
##   (`native_hash.shallowHashNative`) — never its source text. The per-trace
##   backend choice (NOT the language name) decides which hasher runs; this
##   extractor only handles the source-traced Nim case (M9).
##
##   The definition keyword itself is not matched specially — the trace records
##   the routine's `defLine`, and the indentation rule captures from there. Any
##   edit to the routine body or its signature line changes the captured text;
##   edits to sibling routines do not (function-level precision). Documented
##   limitation (shared with Python): a routine whose body dedents inside a
##   multi-line expression / continuation is not specially handled; the fixture
##   does not exercise that, and any such case only ever OVER-captures, which is
##   conservative (it can cause a re-run, never a false skip).
##
## ## JavaScript (`.js`) — brace matching (`function` / method)
##
##   JS bodies are brace-delimited, a genuinely different strategy: from the
##   first `{` at or after `defLine`, scan forward counting block/object `{`/`}`
##   until the matching `}` returns the depth to zero. The captured body is the
##   `def` line through that closing-brace line.
##
##   The scanner is a small JS lexer designed to be SAFE BY CONSTRUCTION rather
##   than precise. It does NOT count braces that appear inside:
##     * single/double-quoted string literals (`'…'`, `"…"`), honoring `\`
##       escapes;
##     * template literals (`` `…` ``), including nested `${ … }` interpolation
##       (the interpolation may itself contain braces, strings, or further
##       templates — an independent interpolation-depth stack pops correctly);
##     * regex literals (`/…/flags`), honoring `\` escapes and `[…]` character
##       classes;
##     * `//` line comments and `/* … */` block comments.
##
##   The classic JS `/` ambiguity (regex literal vs division operator) is NOT
##   resolved precisely — that is provably impossible without a full grammar and
##   was the source of three earlier under-capture bugs. Instead the decision is
##   BIASED TO REGEX (see `regexCanStartAfter`): a `/` is read as division only
##   when the previous significant token is UNAMBIGUOUSLY a value (a numeric
##   literal, a string/template literal, a completed regex, a *value*-`)`, `]`,
##   or a non-keyword identifier); in every other case — including after any
##   expression-introducing keyword (`return`, `void`, `typeof`, …), after `}`,
##   after a *control-head*-`)`, or whenever there is any doubt — it is read as a
##   regex.
##
##   `)` is NOT uniformly a value. A `)` that closes a CALL or a GROUPING
##   (`f(x)`, `(a + b)`) ends a value, so a following `/` is division. But a `)`
##   that closes the HEAD of a control-flow statement (`if (c)`, `while (c)`,
##   `for (;;)`, `switch (x)`, `with (o)`, `catch (e)`) is a STATEMENT boundary,
##   where `/` legally begins a regex (`if (c) /}/​.test(s)`). Counting the
##   in-regex `}` as a block-close there dropped the tail — the third rejection.
##   The two cases are told apart by an OPEN-BRACKET STACK: each `(` pushed
##   records whether the token immediately before it was a control-flow keyword.
##   The matching `)` pops that flag: control-head ⇒ regex-expecting (safe over-
##   capture if it is actually a value-`/`); call/grouping ⇒ value (`(a+b)/c`
##   stays precise division). `]` stays a value (so `arr[i] / 2` is division);
##   the only construct that could abuse that — a regex with a `}` after a `]`
##   division — is not valid JS either way, so it cannot cause a false skip.
##
##   GUARANTEE — no silent under-capture (the absolute invariant: NEVER return
##   `Ok` while under-capturing). The only `Ok` exit is reaching block-brace
##   depth 0 in plain-code context. A premature such exit would require an
##   in-string/template/regex/comment `}` to be mis-counted as a block-close.
##   Strings/templates/comments consume `}` as content (unterminated ⇒ `Err`).
##   For regexes, the only way to mis-count an in-regex `}` is to mistake a real
##   regex `/` for division — and division is now chosen ONLY when the previous
##   token is PROVABLY a value that cannot precede a regex: a numeric/string/
##   template/completed-regex literal, a non-keyword identifier, a `]`, or a
##   *value*-`)` (one whose matching `(` was NOT a control-flow head, tracked by
##   the open-bracket stack). A control-head-`)` and EVERY token kind not on that
##   provable-value list default to regex-expecting (bias to safety). The reverse
##   error (a real division read as a regex) only scans forward to the next `/`,
##   which over-captures or runs to EOF (⇒ `Err`); it can never reduce the brace
##   count. So every `}` counted as a block-close truly is one. The extractor
##   therefore either captures the exact body, OVER-captures (still safe — any
##   edit changes the hash ⇒ re-run), or returns `Err` (unbalanced braces, or an
##   unterminated string/template/regex/comment at EOF) ⇒ the engine's `"missing"`
##   shallow hash ⇒ a conservative re-run. No path returns `Ok` with edited tail
##   code dropped. A full tree-sitter-based extractor remains the production path
##   (a later milestone); this lexer is the prototype that meets the fail-safe
##   invariant.

import std/[strutils, tables, os]
import results

export results

type
  ExtractorProc* = proc(sourceLines: seq[string]; defLine: int):
      Result[string, string] {.nimcall, gcsafe.}
    ## Extract a function body from `sourceLines` (split on `\n`) given the
    ## 1-based `defLine`. Returns the captured text or an `Err`.

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

func leadingIndent(line: string): int =
  ## Number of leading whitespace characters (spaces/tabs) on a line.
  for ch in line:
    if ch == ' ' or ch == '\t': inc result
    else: break

func dropTrailingBlankLines(captured: var seq[string]) =
  ## Drop trailing blank lines carried past the last real statement, so blank
  ## padding between functions does not affect the captured body / its hash.
  while captured.len > 0 and captured[^1].strip().len == 0:
    captured.setLen(captured.len - 1)

func boundsCheck(sourceLines: seq[string]; defLine: int): Result[void, string] =
  if defLine < 1 or defLine > sourceLines.len:
    return err("defLine " & $defLine & " out of range (file has " &
      $sourceLines.len & " lines)")
  ok()

# ---------------------------------------------------------------------------
# Indentation extractor (Ruby + Python share this strategy)
# ---------------------------------------------------------------------------

proc extractByIndentation(sourceLines: seq[string]; defLine: int):
    Result[string, string] {.nimcall, gcsafe.} =
  ## Indentation-delimited body extraction (Ruby `def…end`, Python `def:`).
  ## See the module rules for Ruby/Python above.
  let bc = boundsCheck(sourceLines, defLine)
  if bc.isErr: return err(bc.error)
  let startIdx = defLine - 1
  let indent = leadingIndent(sourceLines[startIdx])
  var captured = @[sourceLines[startIdx]]
  var i = startIdx + 1
  while i < sourceLines.len:
    let line = sourceLines[i]
    if line.strip().len == 0:
      # Blank lines never terminate the body; carry them along so an interior
      # blank line does not truncate the function.
      captured.add line
      inc i
      continue
    if leadingIndent(line) <= indent:
      # First non-blank line at sibling-or-shallower indentation ends the body.
      break
    captured.add line
    inc i
  dropTrailingBlankLines(captured)
  ok(captured.join("\n"))

# ---------------------------------------------------------------------------
# Brace extractor (JavaScript)
# ---------------------------------------------------------------------------

type
  PrevTokenKind = enum
    ## What the previous significant token was, for the regex/division decision.
    ptNone        ## No token yet (start of input) — expression expected.
    ptValue       ## An UNAMBIGUOUS value: numeric literal, string/template
                  ## literal, completed regex, `]`, or a CALL/GROUPING `)`. A `/`
                  ## after one of these is division. NOTE: a control-head `)`
                  ## (closing `if (…)`, `while (…)`, …) is NOT a value — it sets
                  ## `ptOther` so a following `/` is a regex (statement boundary).
    ptIdentifier  ## A bare identifier or keyword (text in `prevIdent`); only a
                  ## NON-keyword identifier is a value.
    ptOther       ## Any other significant char (operator, `(`, `,`, `;`, `{`,
                  ## `}`, `:`, `=`, `.`, …) — expression expected ⇒ regex.

  PrevToken = object
    kind: PrevTokenKind
    ident: string   ## Text of the identifier when `kind == ptIdentifier`.

const
  ## Expression-introducing keywords: when one of these is the previous token, a
  ## following `/` begins a REGEX (e.g. `return /x/`, `typeof /x/`). These are
  ## NOT values even though they lex as identifiers. The set is deliberately
  ## inclusive: the safe direction is to treat MORE identifiers as non-values
  ## (⇒ regex ⇒ at worst over-capture / Err), never fewer.
  exprIntroKeywords = [
    "return", "typeof", "void", "delete", "new", "in", "of", "instanceof",
    "yield", "await", "case", "do", "else", "throw"]

  ## Control-flow keywords whose parenthesised HEAD is a statement, not an
  ## expression. The `)` closing `if (cond)`, `while (cond)`, `for (;;)`,
  ## `switch (x)`, `with (o)`, `catch (e)` is a STATEMENT BOUNDARY where a
  ## following `/` legally begins a regex (`if (c) /}/​.test(s)`). The
  ## open-bracket stack records when a `(` is immediately preceded by one of
  ## these, so the matching `)` can be classified as a control-head (⇒ regex)
  ## rather than a value (⇒ division). The list is inclusive on the safe side:
  ## misclassifying a value-`)` as a control-head only over-captures (⇒ re-run),
  ## while the reverse — missing a real control-head — is the false-skip we ban,
  ## so when in doubt a keyword belongs here.
  controlHeadKeywords = [
    "if", "while", "for", "switch", "with", "catch"]

func regexCanStartAfter(prev: PrevToken): bool =
  ## Decide the classic JS `/` ambiguity, BIASED TO REGEX so under-capture is
  ## impossible by construction. A `/` is treated as DIVISION *only* when the
  ## previous significant token is UNAMBIGUOUSLY a value:
  ##
  ##   * a numeric literal, a string/template literal, a completed regex, a `]`,
  ##     or a CALL/GROUPING `)`  (`prev.kind == ptValue`; a control-head `)` is
  ##     set to `ptOther` upstream, so it does NOT reach here as a value), OR
  ##   * a bare identifier that is NOT one of the expression-introducing
  ##     keywords (`return`, `typeof`, `void`, …).
  ##
  ## In EVERY other case — start of input, after any keyword, after any operator
  ## or `(`, `,`, `;`, `{`, `}`, `:`, `=`, `=>`, `.`, or anything we are unsure
  ## about — we treat `/` as starting a REGEX.
  ##
  ## Why this is SAFE (cannot under-capture): the only dangerous misjudgement is
  ## treating a *real regex* as division, because that resumes plain-code lexing
  ## inside regex text and could count an in-regex `}` as a block close. The bias
  ## above makes that impossible for any `/` that could plausibly be a regex —
  ## division is chosen only after a token that genuinely cannot be followed by a
  ## regex. The opposite misjudgement (treating a *real division* `/` as a regex)
  ## merely scans forward to the next `/` as "regex content", which can only
  ## swallow MORE characters (over-capture) or run to EOF unterminated (⇒ `Err`);
  ## neither ever drops block braces, so neither can cause a false skip.
  case prev.kind
  of ptNone, ptOther:
    return true                 # expression expected ⇒ regex
  of ptValue:
    return false                # unambiguous value ⇒ division
  of ptIdentifier:
    # A value ONLY if it is not an expression-introducing keyword.
    return prev.ident in exprIntroKeywords

proc extractByBraces(sourceLines: seq[string]; defLine: int):
    Result[string, string] {.nimcall, gcsafe.} =
  ## Brace-delimited body extraction (JavaScript `function`/method). Scans from
  ## the first `{` at or after `defLine` to the matching `}`, lexing past braces
  ## that appear inside string literals (`'`/`"`), template literals (backtick,
  ## including nested `${ … }` interpolation), regex literals (`/…/flags`), and
  ## `//` / `/* */` comments.
  ##
  ## PROOF — no `Ok` return can under-capture. The ONLY `Ok` exit is reaching
  ## block-brace depth 0 in plain-code context (the `}` that matches the
  ## function's own opening `{`). For that exit to be WRONG (premature), some
  ## earlier `}` would have had to be mis-counted as a block-close when it was
  ## really inside a string / template / regex / comment. We exclude each case:
  ##   * Strings / templates / `//` / `/* */`: handled by dedicated lexer states
  ##     that consume `}` as ordinary content; an unterminated one at EOF returns
  ##     `Err`, never `Ok`.
  ##   * Regex literals: the `/`→regex decision is BIASED TO REGEX (see
  ##     `regexCanStartAfter`). The only way an in-regex `}` could be counted as a
  ##     block-close is if we mistook a real regex `/` for division. The bias
  ##     makes that impossible: division is chosen only after an UNAMBIGUOUS value
  ##     token, after which a regex literal cannot legally begin. The reverse
  ##     error (a real division read as a regex) only ever scans forward to the
  ##     next `/` — swallowing MORE input (over-capture) or running unterminated
  ##     to EOF (⇒ `Err`); it can never *reduce* the brace count.
  ## Hence every `}` we count as a block-close truly is one, so depth-0 truly is
  ## the function's end: the `Ok` body is exact or a (safe) over-capture, and any
  ## construct we cannot lex to EOF yields `Err` ⇒ a conservative re-run. There
  ## is no path that returns `Ok` with edited tail code dropped.
  let bc = boundsCheck(sourceLines, defLine)
  if bc.isErr: return err(bc.error)
  let startIdx = defLine - 1
  var captured: seq[string]
  var depth = 0
  var sawOpen = false

  # Lexer state that must persist across lines.
  var inBlockComment = false
  # Active simple string-literal quote (`'` or `"`), or '\0' when not in one.
  var stringQuote = '\0'
  # Template-literal interpolation stack. Each backtick template that is open
  # pushes an entry recording the brace `depth` captured when its first `${`
  # was entered, so the matching `}` that closes the interpolation can be told
  # apart from ordinary block braces and pops us back into template-string text.
  # `inTemplate` (top-of-stack is a raw template, not inside its `${}`) is
  # tracked with `templateActive`.
  var templateActive = false          ## currently lexing raw template text
  var templateInterpDepths: seq[int]  ## brace depth at each open `${`
  # Previous significant TOKEN (for the regex/division decision). Updated only by
  # real code tokens, never by chars inside strings/comments/regex. Tracking the
  # whole token (not just the last char) lets us tell value identifiers apart
  # from expression-introducing keywords (`return /x/`, `void /x/`, …).
  var prev = PrevToken(kind: ptNone)
  # Open-bracket stack: one `bool` per currently-open `(`, recording whether the
  # token immediately before that `(` was a control-flow keyword (`if`, `while`,
  # …). When the matching `)` pops a `true`, the `)` closes a control-flow head
  # ⇒ statement boundary ⇒ a following `/` is a REGEX; a `false` (a call or a
  # plain grouping) makes the `)` a VALUE ⇒ a following `/` is division. This is
  # what tells `(a + b) / c` (division, precise) apart from `if (c) /}/.test(s)`
  # (regex, safe) without ever under-capturing.
  var parenIsControlHead: seq[bool]

  var i = startIdx
  while i < sourceLines.len:
    let line = sourceLines[i]
    captured.add line
    var j = 0
    while j < line.len:
      let ch = line[j]

      if inBlockComment:
        if ch == '*' and j + 1 < line.len and line[j + 1] == '/':
          inBlockComment = false
          j += 2
          continue
        inc j
        continue

      if stringQuote != '\0':
        if ch == '\\':
          # Skip the escaped character (covers \" \' \\ etc.). If the backslash
          # is the last char on the line it is a (technically invalid) escape of
          # the newline; just advance off the end.
          j += 2
          continue
        if ch == stringQuote:
          stringQuote = '\0'
          prev = PrevToken(kind: ptValue)  # a closed string is a value
        inc j
        continue

      if templateActive:
        # Inside raw template-literal text (between backticks, NOT inside `${}`).
        if ch == '\\':
          j += 2
          continue
        if ch == '`':
          templateActive = false
          prev = PrevToken(kind: ptValue)  # a closed template is a value
          inc j
          continue
        if ch == '$' and j + 1 < line.len and line[j + 1] == '{':
          # Enter an interpolation: remember the current brace depth so the
          # matching close `}` pops back into template text. We do NOT bump
          # `depth` — `depth` counts only block/object braces, and the
          # interpolation stack is matched independently.
          templateInterpDepths.add depth
          templateActive = false
          prev = PrevToken(kind: ptOther)  # an expression is expected inside `${`
          j += 2
          continue
        inc j
        continue

      # Not in a comment, string, or raw template text: ordinary code.
      if ch == ' ' or ch == '\t':
        inc j
        continue

      if ch == '/' and j + 1 < line.len and line[j + 1] == '/':
        # Line comment: the rest of this line is ignored. `prevSignificant`
        # is unchanged (a comment is not a token).
        break

      if ch == '/' and j + 1 < line.len and line[j + 1] == '*':
        inBlockComment = true
        j += 2
        continue

      if ch == '"' or ch == '\'':
        stringQuote = ch
        inc j
        continue

      if ch == '`':
        templateActive = true
        inc j
        continue

      if ch == '/' and regexCanStartAfter(prev):
        # Regex literal: consume `/ … /` honoring `\` escapes and `[ … ]`
        # character classes (a `/` inside a class is literal, not the closer).
        # If the line ends before the closing `/`, the regex is unterminated;
        # per the fail-safe guarantee we cannot trust the rest of the file, so
        # bail out to a conservative re-run rather than guessing.
        var k = j + 1
        var closed = false
        var inClass = false
        while k < line.len:
          let rc = line[k]
          if rc == '\\':
            k += 2
            continue
          if inClass:
            if rc == ']': inClass = false
            inc k
            continue
          if rc == '[':
            inClass = true
            inc k
            continue
          if rc == '/':
            closed = true
            inc k
            break
          inc k
        if not closed:
          return err("unterminated regex literal on line " & $(i + 1) &
            " for function at line " & $defLine &
            " (failing safe to a re-run)")
        # Skip any regex flags (identifier chars) following the closing `/`.
        while k < line.len and (line[k].isAlphaNumeric() or line[k] == '_'):
          inc k
        prev = PrevToken(kind: ptValue)  # a completed regex is a value
        j = k
        continue

      if ch == '{':
        inc depth
        sawOpen = true
        prev = PrevToken(kind: ptOther)
        inc j
        continue

      if ch == '}':
        # Is this `}` closing a template interpolation `${ … }`? It is iff the
        # top of the interpolation stack recorded exactly this brace depth.
        if templateInterpDepths.len > 0 and
            templateInterpDepths[^1] == depth:
          templateInterpDepths.setLen(templateInterpDepths.len - 1)
          templateActive = true   # resume raw template text after the `}`
          prev = PrevToken(kind: ptOther)  # template text isn't a code token
          inc j
          continue
        if depth > 0:
          dec depth
          # A block-close `}` is NOT treated as a value: a following `/` biases
          # to regex (the safe direction). See `regexCanStartAfter`.
          prev = PrevToken(kind: ptOther)
          if sawOpen and depth == 0:
            # Matched the function's opening brace: the body ends on this line.
            # If a string/template/regex/comment were still open we would not be
            # here (we'd be in the corresponding branch above), so reaching
            # depth 0 in plain-code context means the body is fully enclosed.
            return ok(captured.join("\n"))
        inc j
        continue

      # Identifier or keyword: accumulate the whole word so the regex/division
      # decision can tell value identifiers from expression-introducing keywords.
      if ch == '_' or ch == '$' or ch.isAlphaAscii():
        var k = j
        while k < line.len and (line[k] == '_' or line[k] == '$' or
            line[k].isAlphaNumeric()):
          inc k
        prev = PrevToken(kind: ptIdentifier, ident: line[j ..< k])
        j = k
        continue

      # Numeric literal: an unambiguous value (division follows, e.g. `4 / 2`).
      # Consume the run of digits / numeric chars so the token boundary is clean.
      if ch.isDigit():
        var k = j
        while k < line.len and (line[k].isAlphaNumeric() or line[k] == '.' or
            line[k] == '_'):
          inc k
        prev = PrevToken(kind: ptValue)
        j = k
        continue

      # Opening paren `(`: push the open-bracket stack, recording whether the
      # token immediately before it was a control-flow keyword. That flag decides
      # how the matching `)` is classified (control-head ⇒ regex; call/grouping
      # ⇒ value). After `(`, an expression is expected ⇒ a following `/` is regex.
      if ch == '(':
        let precededByControl =
          prev.kind == ptIdentifier and prev.ident in controlHeadKeywords
        parenIsControlHead.add precededByControl
        prev = PrevToken(kind: ptOther)
        inc j
        continue

      # Closing paren `)`: pop the open-bracket stack. A control-head `)` is a
      # STATEMENT boundary (a following `/` is a regex — `ptOther`, the safe
      # direction). A call/grouping `)` ENDS A VALUE (a following `/` is division
      # — `ptValue`, keeping `(a + b) / c` precise). An UNBALANCED `)` (empty
      # stack — should not happen inside a well-formed body, but be defensive)
      # biases to regex, the safe direction.
      if ch == ')':
        if parenIsControlHead.len > 0:
          let wasControlHead = parenIsControlHead[^1]
          parenIsControlHead.setLen(parenIsControlHead.len - 1)
          if wasControlHead:
            prev = PrevToken(kind: ptOther)   # statement boundary ⇒ regex
          else:
            prev = PrevToken(kind: ptValue)   # call/grouping value ⇒ division
        else:
          prev = PrevToken(kind: ptOther)     # unbalanced ⇒ bias to regex
        inc j
        continue

      # Any other significant character (operator, punctuation, `,`, `;`, `:`,
      # `=`, `.`, …). `]` ends a value ⇒ division may follow; everything else
      # expects an expression ⇒ a following `/` biases to regex.
      if ch == ']':
        prev = PrevToken(kind: ptValue)
      else:
        prev = PrevToken(kind: ptOther)
      inc j

    inc i

  if not sawOpen:
    return err("no opening '{' found for function at line " & $defLine)
  if inBlockComment:
    return err("unterminated block comment for function at line " & $defLine &
      " (failing safe to a re-run)")
  if stringQuote != '\0':
    return err("unterminated string literal for function at line " & $defLine &
      " (failing safe to a re-run)")
  if templateActive or templateInterpDepths.len > 0:
    return err("unterminated template literal for function at line " &
      $defLine & " (failing safe to a re-run)")
  err("unbalanced braces: no matching '}' for function at line " & $defLine)

# ---------------------------------------------------------------------------
# Registry: file extension -> extractor
# ---------------------------------------------------------------------------

const extractorRegistry: Table[string, ExtractorProc] = {
  ".rb": ExtractorProc(extractByIndentation),
  ".py": ExtractorProc(extractByIndentation),
  ".nim": ExtractorProc(extractByIndentation),  # M9: Nim's materialized-source path
  ".js": ExtractorProc(extractByBraces),
}.toTable

func normalizeExt(file: string): string =
  ## Lowercased file extension including the leading dot (e.g. `.py`).
  file.splitFile().ext.toLowerAscii()

proc extractorFor*(file: string): Result[ExtractorProc, string] =
  ## Select the function-body extractor for `file` by its extension. An unknown
  ## extension is a clear `Err` so the caller can fail-safe to a re-run — it is
  ## NEVER silently hashed with the wrong strategy.
  let ext = normalizeExt(file)
  if ext.len == 0:
    return err("no file extension on '" & file & "': cannot select an extractor")
  if not extractorRegistry.hasKey(ext):
    return err("unsupported source extension '" & ext & "' for '" & file &
      "': no function-body extractor registered")
  ok(extractorRegistry[ext])

proc extractFunctionBody*(file: string; sourceLines: seq[string];
                          defLine: int): Result[string, string] =
  ## Extract the body of the function at `defLine` (1-based) from `sourceLines`,
  ## choosing the extractor by `file`'s extension. Returns the captured text or
  ## an `Err` (unknown extension, line out of range, unmatched braces, …).
  let ex = extractorFor(file)
  if ex.isErr: return err(ex.error)
  let extractor = ex.value
  extractor(sourceLines, defLine)
