## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. This module reaches `std/*` and its sibling
## `js_regex` and nothing else; it opens no file (the definitions are compiled
## in with `staticRead`).
##
## app/syntax/monarch.nim — Monaco's Monarch tokenizer, run in the terminal
## over Monaco's OWN language definitions (PLAT-47, B4).
##
## ## Why an interpreter rather than ports
##
## The desktop colours source with Monaco's Monarch tokenizers. Part A ported
## the Python one by hand (`highlighter.pythonLineSpans`, still the Python
## path); B4 asks the same of Rust (and Noir, which the desktop opens as Rust),
## the C family, Go, JavaScript and TypeScript, Java, Ruby, shell and YAML —
## about 2,500 lines of definitions with 110 states. Hand ports of that much
## drift from the source the first time Monaco changes a rule. So the
## definitions themselves are exported as JSON
## (`scripts/monarch-languages.mjs` → `monarch_languages.json`, from the
## pinned `monaco-editor`) and this module runs them the way
## `monarchLexer._myTokenize` does:
##
##   * at each position the current state's rules are tried IN ORDER, each
##     regex anchored at the position (`^(?:rule)` over `line.substr(pos)`),
##     a rule written with a leading `^` only at column 0;
##   * no rule matching consumes ONE character with the definition's
##     `defaultToken`;
##   * an action is a token, a group (one action per capture group, emitted in
##     turn), or a `cases` table whose guards are evaluated as `createGuard`
##     compiles them (`$#`, `$n`, `$Sn` scrutinees; `==`, `!=`, `~regex`,
##     `@words`, `@default`, `@eos`);
##   * `next` pushes (`@push` the current state, `@pop`, `@popall`),
##     `switchTo` replaces the top, `goBack` backs up; `$n`/`$Sn`/`$#`/`@attr`
##     are substituted into tokens and state names (`substituteMatches`), and a
##     `$Sn` in a REGEX is substituted per state, escaped
##     (`substituteMatchesRe`);
##   * `@brackets` resolves through the definition's bracket table,
##     `@rematch` re-runs the position in the new state;
##   * the token TYPE is the action's token plus the definition's
##     `tokenPostfix` (the bracket table's tokens already carry it), with
##     `&<>'"_` replaced by `-` (`sanitize`);
##   * the state stack survives the end of a line, which is how a block
##     comment or a heredoc stays one across lines;
##   * a rule that throws (no progress, an undefined state) makes the whole
##     line ONE default token and leaves the state as it was — Monaco's
##     `safeTokenize` / `nullTokenize`.
##
## The token types go to colours through the same resolution the desktop's
## theme uses (`editor_theme.classForMonacoToken`).
##
## ## No mocks
##
## `tests/test_plat47_monaco_lexers.nim` runs the real definitions over sample
## files and compares every character with `monaco.editor.tokenize`, captured
## from the real Electron app.

import std/[json, strutils, tables, unicode]

import ./js_regex

type
  MonarchToken* = object
    ## One token: its first byte in the line and its Monaco token type.
    start*: int
    tokenType*: string

  GuardOp = enum
    goAlways, goEos, goEquals, goNotEquals, goWords, goNotWords,
    goRegex, goNotRegex

  MonarchCase = object
    op: GuardOp
    scrut: int             ## -1: the matched text; 0..99 `$n`; 100+n `$Sn`
    pat: string
    words: seq[string]     ## goWords / goNotWords (case-folded if ignoreCase)
    re: JsRegex            ## goRegex without `$` in the pattern
    reCompiled: bool
    value: MonarchAction

  MonarchActionKind = enum
    makToken, makGroup, makCases

  MonarchAction = ref object
    case kind: MonarchActionKind
    of makToken:
      token: string
      tokenSubst: bool
      next: string
      switchTo: string
      goBack: int
    of makGroup:
      group: seq[MonarchAction]
    of makCases:
      cases: seq[MonarchCase]

  MonarchRule = object
    source: string
    hasSn: bool
    re: JsRegex
    atStart: bool
    action: MonarchAction

  MonarchLanguage* = ref object
    ## One compiled definition.
    id*: string
    ignoreCase: bool
    tokenPostfix: string
    defaultToken: string
    start*: string
    brackets: seq[tuple[open, close, token: string]]
    words: Table[string, seq[string]]
    strings: Table[string, string]
      ## String attributes (`substituteMatches`'s `@attr`).
    regexAttrs: Table[string, string]
      ## String AND regex attributes (`compileRegExp`'s `@attr`).
    states: Table[string, seq[MonarchRule]]
    snCache: Table[string, JsRegex]

  MonarchState* = seq[string]
    ## The tokenizer's state stack, bottom first; `[^1]` is the current state.

  MonarchError = object of CatchableError

const
  MonarchJson = staticRead("monarch_languages.json")
    ## The exported definitions (`scripts/monarch-languages.mjs`). Parsed on
    ## first use, one language at a time.
  MonarchStackLimit = 100
    ## `lexer.maxStack`.

var languageCache {.threadvar.}: Table[string, MonarchLanguage]
var parsedDefinitions {.threadvar.}: JsonNode
  ## Per-thread: the host highlights on a worker thread (PLAT-29), and a
  ## compiled definition holds `ref`s.

proc definitions(): JsonNode =
  if parsedDefinitions.isNil:
    parsedDefinitions = parseJson(MonarchJson)
  parsedDefinitions

proc monacoVersion*(): string =
  ## The `monaco-editor` version the definitions were exported from.
  definitions(){"monacoVersion"}.getStr("")

proc fixCase(lang: MonarchLanguage; s: string): string =
  if lang.ignoreCase: s.toLowerAscii else: s

# ---------------------------------------------------------------------------
# Compilation (monarchCompile.js)
# ---------------------------------------------------------------------------

proc compileAction(lang: MonarchLanguage; n: JsonNode): MonarchAction

proc parseGuard(lang: MonarchLanguage; key: string;
                value: MonarchAction): MonarchCase =
  ## `createGuard`.
  result.value = value
  if key == "@default" or key == "@" or key == "":
    result.op = goAlways
    return
  if key == "@eos":
    result.op = goEos
    return
  result.scrut = -1
  var oppat = key
  if key.len >= 2 and key[0] == '$':
    # /^\$(([sS]?)(\d\d?)|#)(.*)$/
    var i = 1
    var isState = false
    if key[i] in {'s', 'S'} and i + 1 < key.len and key[i + 1] in {'0'..'9'}:
      isState = true
      inc i
    if key[i] == '#':
      oppat = key[i + 1 .. ^1]
    elif key[i] in {'0'..'9'}:
      var n = ord(key[i]) - ord('0')
      inc i
      if i < key.len and key[i] in {'0'..'9'}:
        n = n * 10 + ord(key[i]) - ord('0')
        inc i
      result.scrut = if isState: n + 100 else: n
      oppat = key[i .. ^1]
  var op = "~"
  var pat = oppat
  if oppat.len == 0:
    op = "!="
    pat = ""
  elif oppat.allCharsInSet(IdentChars):
    op = "=="
  else:
    for candidate in ["!@", "@", "!~", "~", "==", "!="]:
      if oppat.startsWith(candidate):
        op = candidate
        pat = oppat[candidate.len .. ^1]
        break
  if (op == "~" or op == "!~") and pat.allCharsInSet(IdentChars + {'|'}):
    result.op = if op == "~": goWords else: goNotWords
    for w in pat.split('|'):
      result.words.add lang.fixCase(w)
  elif op == "@" or op == "!@":
    result.op = if op == "@": goWords else: goNotWords
    if not lang.words.hasKey(pat):
      raise newException(MonarchError, "no word list '" & pat & "'")
    for w in lang.words[pat]:
      result.words.add lang.fixCase(w)
  elif op == "~" or op == "!~":
    result.op = if op == "~": goRegex else: goNotRegex
    result.pat = pat
  else:
    result.op = if op == "==": goEquals else: goNotEquals
    result.pat = lang.fixCase(pat)

proc compileAction(lang: MonarchLanguage; n: JsonNode): MonarchAction =
  case n.kind
  of JString:
    result = MonarchAction(kind: makToken, token: n.getStr)
  of JObject:
    if n.hasKey("group"):
      result = MonarchAction(kind: makGroup)
      for g in n["group"]:
        result.group.add lang.compileAction(g)
    elif n.hasKey("cases"):
      result = MonarchAction(kind: makCases)
      for pair in n["cases"]:
        let value = lang.compileAction(pair[1])
        result.cases.add lang.parseGuard(pair[0].getStr, value)
    else:
      let token = n{"token"}.getStr("")
      result = MonarchAction(kind: makToken, token: token,
                             tokenSubst: '$' in token,
                             next: n{"next"}.getStr(""),
                             switchTo: n{"switchTo"}.getStr(""),
                             goBack: n{"goBack"}.getInt(0))
  else:
    result = MonarchAction(kind: makToken, token: "")

proc expandAttrs(lang: MonarchLanguage; str: string): string =
  ## `compileRegExp`'s `@attr` expansion for a guard's regex (rule regexes
  ## arrive expanded).
  result = str.replace("@@", "\x01")
  for _ in 0 ..< 5:
    var had = false
    var outp = ""
    var i = 0
    while i < result.len:
      if result[i] == '@' and i + 1 < result.len and result[i + 1] in IdentChars:
        var j = i + 1
        while j < result.len and result[j] in IdentChars: inc j
        let attr = result[i + 1 ..< j]
        had = true
        let sub = lang.regexAttrs.getOrDefault(attr, "")
        if sub.len > 0:
          outp.add "(?:" & sub & ")"
        i = j
      else:
        outp.add result[i]
        inc i
    result = outp
    if not had:
      break
  result = result.replace("\x01", "@")

proc loadLanguage(id: string): MonarchLanguage =
  let d = definitions(){"languages"}{id}
  if d.isNil:
    return nil
  result = MonarchLanguage(
    id: id,
    ignoreCase: d{"ignoreCase"}.getBool(false),
    tokenPostfix: d{"tokenPostfix"}.getStr("." & id),
    defaultToken: d{"defaultToken"}.getStr("source"),
    start: d{"start"}.getStr("root"))
  for b in d{"brackets"}:
    result.brackets.add (open: result.fixCase(b{"open"}.getStr),
                         close: result.fixCase(b{"close"}.getStr),
                         token: b{"token"}.getStr)
  for k, v in d{"words"}.pairs:
    var ws: seq[string] = @[]
    for w in v: ws.add w.getStr
    result.words[k] = ws
  for k, v in d{"strings"}.pairs:
    result.strings[k] = v.getStr
    result.regexAttrs[k] = v.getStr
  for k, v in d{"regexes"}.pairs:
    result.regexAttrs[k] = v.getStr
  for state, rules in d{"states"}.pairs:
    var compiled: seq[MonarchRule] = @[]
    for r in rules:
      let src = r{"re"}.getStr
      let hasSn = src.contains("$S") or src.contains("$s")
      var rule = MonarchRule(source: src, hasSn: hasSn,
                             atStart: r{"atStart"}.getBool(false),
                             action: result.compileAction(r{"action"}))
      if not hasSn:
        rule.re = compileJsRegex("^(?:" & src & ")", result.ignoreCase)
      compiled.add rule
    result.states[state] = compiled

proc monarchLanguage*(id: string): MonarchLanguage =
  ## The compiled definition for a Monaco language id, or nil when none was
  ## exported.
  if languageCache.hasKey(id):
    return languageCache[id]
  result = loadLanguage(id)
  languageCache[id] = result

# ---------------------------------------------------------------------------
# Substitution (monarchCommon.js)
# ---------------------------------------------------------------------------

proc stateParts(state: string): seq[string] =
  result = @[state]
  result.add state.split('.')

proc substituteMatches(lang: MonarchLanguage; str, id: string;
                       matches: seq[string]; state: string): string =
  ## `substituteMatches`: `$$`, `$#`, `$n`, `$Sn`, `$@attr`.
  var i = 0
  while i < str.len:
    if str[i] != '$' or i + 1 >= str.len:
      result.add str[i]
      inc i
      continue
    let c = str[i + 1]
    if c == '$':
      result.add '$'
      i += 2
    elif c == '#':
      result.add lang.fixCase(id)
      i += 2
    elif c in {'0'..'9'}:
      var j = i + 1
      var n = 0
      var digits = 0
      while j < str.len and str[j] in {'0'..'9'} and digits < 2:
        n = n * 10 + ord(str[j]) - ord('0')
        inc j
        inc digits
      if n < matches.len:
        result.add lang.fixCase(matches[n])
      i = j
    elif c in {'s', 'S'} and i + 2 < str.len and str[i + 2] in {'0'..'9'}:
      var j = i + 2
      var n = 0
      var digits = 0
      while j < str.len and str[j] in {'0'..'9'} and digits < 2:
        n = n * 10 + ord(str[j]) - ord('0')
        inc j
        inc digits
      let parts = stateParts(state)
      if n < parts.len:
        result.add lang.fixCase(parts[n])
      i = j
    elif c == '@':
      var j = i + 2
      while j < str.len and str[j] in IdentChars: inc j
      let attr = str[i + 2 ..< j]
      result.add lang.strings.getOrDefault(attr, "")
      i = j
    else:
      result.add '$'
      inc i

proc ruleRegex(lang: MonarchLanguage; rule: MonarchRule;
               state: string): JsRegex =
  ## A `$Sn` rule's regex for `state` (`substituteMatchesRe`), cached.
  if not rule.hasSn:
    return rule.re
  var src = ""
  var i = 0
  let s = rule.source
  while i < s.len:
    if s[i] == '$' and i + 2 < s.len and s[i + 1] in {'s', 'S'} and
        s[i + 2] in {'0'..'9'}:
      var j = i + 2
      var n = 0
      var digits = 0
      while j < s.len and s[j] in {'0'..'9'} and digits < 2:
        n = n * 10 + ord(s[j]) - ord('0')
        inc j
        inc digits
      let parts = stateParts(state)
      if n < parts.len:
        src.add escapeRegExpCharacters(lang.fixCase(parts[n]))
      i = j
    else:
      src.add s[i]
      inc i
  let key = src
  if not lang.snCache.hasKey(key):
    lang.snCache[key] = compileJsRegex("^(?:" & src & ")", lang.ignoreCase)
  lang.snCache[key]

proc findRules(lang: MonarchLanguage; inState: string): seq[MonarchRule] =
  ## `findRules`: the state, else its dotted parents.
  var state = inState
  while state.len > 0:
    if lang.states.hasKey(state):
      return lang.states[state]
    let idx = state.rfind('.')
    if idx < 0:
      break
    state = state[0 ..< idx]
  raise newException(MonarchError, "tokenizer state is not defined: " & inState)

proc hasRules(lang: MonarchLanguage; inState: string): bool =
  try:
    discard lang.findRules(inState)
    true
  except MonarchError:
    false

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

proc selectScrutinee(scrut: int; id: string; matches: seq[string];
                     state: string): string =
  if scrut < 0:
    return id
  if scrut < matches.len:
    return matches[scrut]
  if scrut >= 100:
    let parts = stateParts(state)
    if scrut - 100 < parts.len:
      return parts[scrut - 100]
  ""

proc test(lang: MonarchLanguage; c: var MonarchCase; id: string;
          matches: seq[string]; state: string; eos: bool): bool =
  case c.op
  of goAlways: return true
  of goEos: return eos
  else: discard
  let s = selectScrutinee(c.scrut, id, matches, state)
  case c.op
  of goWords, goNotWords:
    let key = lang.fixCase(s)
    let hit = key in c.words
    if c.op == goWords: hit else: not hit
  of goEquals, goNotEquals:
    let expected =
      if '$' in c.pat: lang.substituteMatches(c.pat, id, matches, state)
      else: c.pat
    if c.op == goEquals: s == expected else: s != expected
  of goRegex, goNotRegex:
    var re: JsRegex
    if '$' in c.pat:
      re = compileJsRegex("^" & lang.expandAttrs(
        lang.substituteMatches(c.pat, id, matches, state)) & "$", lang.ignoreCase)
    else:
      if not c.reCompiled:
        c.re = compileJsRegex("^" & lang.expandAttrs(c.pat) & "$",
                              lang.ignoreCase)
        c.reCompiled = true
      re = c.re
    var caps: Captures
    let hit = re.matchAt(s, 0, caps) and caps[0][1] == s.len
    if '$' in c.pat:
      # createGuard's substituting tester is `return re.test(s)` for BOTH
      # `~` and `!~` — kept as Monaco has it.
      hit
    elif c.op == goRegex: hit
    else: not hit
  else: false

# ---------------------------------------------------------------------------
# Tokenizing (monarchLexer._myTokenize)
# ---------------------------------------------------------------------------

proc sanitize(s: string): string =
  result = s
  for ch in result.mitems:
    if ch in {'&', '<', '>', '\'', '"', '_'}:
      ch = '-'

proc initialState*(lang: MonarchLanguage): MonarchState =
  @[lang.start]

proc tokenizeLineUnsafe(lang: MonarchLanguage; line: string;
                        stack: var MonarchState): seq[MonarchToken] =
  type Pending = object
    action: MonarchAction
    matched: string
  var pos = 0
  var groups: seq[Pending] = @[]
  var groupMatches: seq[string] = @[]
  var forceEvaluation = true
  var lastType = "\x00"
  proc emit(res: var seq[MonarchToken]; at: int; t: string) =
    if t != lastType:
      res.add MonarchToken(start: at, tokenType: t)
      lastType = t
  while forceEvaluation or pos < line.len:
    let pos0 = pos
    let stackLen0 = stack.len
    let groupLen0 = groups.len
    let state = stack[^1]
    var matches: seq[string] = @[]
    var matched = ""
    var action: MonarchAction = nil
    var haveMatch = false
    if groups.len > 0:
      matches = groupMatches
      let g = groups[0]
      groups.delete(0)
      matched = g.matched
      action = g.action
      haveMatch = true
    else:
      if not forceEvaluation and pos >= line.len:
        break
      forceEvaluation = false
      let rules = lang.findRules(state)
      for rule in rules:
        if pos == 0 or not rule.atStart:
          let re = lang.ruleRegex(rule, state)
          var caps: Captures
          if re.matchAt(line, pos, caps):
            matches = @[]
            for (a, b) in caps:
              matches.add(if a < 0: "" else: line[a ..< b])
            matched = matches[0]
            action = rule.action
            haveMatch = true
            break
    if not haveMatch:
      matches = @[""]
      matched = ""
    var resultToken = ""
    var resultGroup: seq[MonarchAction] = @[]
    var isGroup = false
    var nextState = ""
    if action.isNil:
      if pos < line.len:
        let n = max(1, int(runeLenAt(line, pos)))
        matched = line[pos ..< pos + n]
        matches = @[matched]
      action = MonarchAction(kind: makToken, token: lang.defaultToken)
    pos += matched.len
    # `cases` resolve to an action.
    while action.kind == makCases:
      var picked: MonarchAction = nil
      for c in action.cases.mitems:
        if lang.test(c, matched, matches, state, pos == line.len):
          picked = c.value
          break
      if picked.isNil:
        picked = MonarchAction(kind: makToken, token: lang.defaultToken)
      action = picked
    case action.kind
    of makGroup:
      isGroup = true
      resultGroup = action.group
    of makToken:
      resultToken =
        if action.tokenSubst:
          lang.substituteMatches(action.token, matched, matches, state)
        else: action.token
      if action.goBack > 0:
        pos = max(0, pos - action.goBack)
      if action.switchTo.len > 0:
        var s = lang.substituteMatches(action.switchTo, matched, matches, state)
        if s.len > 0 and s[0] == '@':
          s = s[1 .. ^1]
        if not lang.hasRules(s):
          raise newException(MonarchError, "switch to undefined state " & s)
        stack[^1] = s
      elif action.next.len > 0:
        case action.next
        of "@push":
          if stack.len >= MonarchStackLimit:
            raise newException(MonarchError, "maximum tokenizer stack size")
          stack.add state
        of "@pop":
          if stack.len <= 1:
            raise newException(MonarchError, "trying to pop an empty stack")
          stack.setLen(stack.len - 1)
        of "@popall":
          stack.setLen(1)
        else:
          var s = lang.substituteMatches(action.next, matched, matches, state)
          if s.len > 0 and s[0] == '@':
            s = s[1 .. ^1]
          if not lang.hasRules(s):
            raise newException(MonarchError, "next state undefined " & s)
          nextState = s
          if stack.len >= MonarchStackLimit:
            raise newException(MonarchError, "maximum tokenizer stack size")
          stack.add nextState
    of makCases:
      discard
    if isGroup:
      if groups.len > 0:
        raise newException(MonarchError, "groups cannot be nested")
      if matches.len != resultGroup.len + 1:
        raise newException(MonarchError, "group count mismatch")
      var total = 0
      for i in 1 ..< matches.len: total += matches[i].len
      if total != matched.len:
        raise newException(MonarchError, "groups do not cover the match")
      groupMatches = matches
      groups = @[]
      for i, a in resultGroup:
        groups.add Pending(action: a, matched: matches[i + 1])
      pos -= matched.len
      continue
    if resultToken == "@rematch":
      pos -= matched.len
      matched = ""
      resultToken = ""
    if matched.len == 0:
      if line.len == 0 or stackLen0 != stack.len or state != stack[^1] or
          groups.len != groupLen0:
        continue
      raise newException(MonarchError, "no progress in tokenizer")
    var tokenType: string
    if resultToken.startsWith("@brackets"):
      let rest = resultToken["@brackets".len .. ^1]
      let key = lang.fixCase(matched)
      var found = ""
      for b in lang.brackets:
        if b.open == key or b.close == key:
          found = b.token
          break
      if found.len == 0:
        raise newException(MonarchError, "no bracket for " & matched)
      tokenType = sanitize(found & rest)
    else:
      tokenType = sanitize(if resultToken.len == 0: "" else: resultToken &
                                                         lang.tokenPostfix)
    if pos0 < line.len:
      result.emit(pos0, tokenType)

proc tokenizeLine*(lang: MonarchLanguage; line: string;
                   state: var MonarchState): seq[MonarchToken] =
  ## One line's tokens, starting in `state` and leaving `state` as the line
  ## leaves it. A definition error makes the line one default token and
  ## leaves `state` unchanged (Monaco's `nullTokenize`).
  if state.len == 0:
    state = lang.initialState()
  var working = state
  try:
    result = lang.tokenizeLineUnsafe(line, working)
    state = working
  except MonarchError, JsRegexError:
    result = @[MonarchToken(start: 0, tokenType: "")]

proc encodeState*(s: MonarchState): string =
  ## A state as one opaque string (the stack, bottom first).
  s.join("\x1f")

proc decodeState*(s: string): MonarchState =
  if s.len == 0: @[] else: s.split('\x1f')
