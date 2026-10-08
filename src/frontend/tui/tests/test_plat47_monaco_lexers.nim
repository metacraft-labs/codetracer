## test_plat47_monaco_lexers.nim — PLAT-47 B4. **Every terminal lexer
## tokenises as the desktop's Monaco does, character by character.**
##
## The desktop's side is `src/tests/visual/answers/plat47-monaco-lexers.electron.json`:
## the real Electron app's `monaco.editor.tokenize` over one sample file per
## language (`fixtures/monaco_lexers/`), captured by
## `plat47-monaco-lexers-capture.spec.ts` (`just plat47-capture-electron`).
## The terminal's side is its highlighter over the same files.
##
##   1. The TOKEN TYPES are equal at every character: the terminal runs the
##      desktop's own Monarch definitions (`monarch.nim`) and Monaco's JSON
##      scanner (`json_tokens.nim`), so a type that differs anywhere is a bug
##      in the interpreter, not a matter of taste.
##   2. The COLOURS are equal at every character, in both of the desktop's
##      themes: the terminal's span class through `tokenClassToken` and the
##      generated tokens, against the capture's type resolved against the
##      theme file the way Monaco resolves it.
##   3. COVERAGE: every token type the exported definitions can produce
##      (every literal token in every action, every bracket token, the JSON
##      scanner's types) resolves to a theme rule that
##      `editor_theme.MonacoScopeClass` maps, and the class it maps to is
##      painted that rule's colour in both themes. So a rule the samples do
##      not happen to exercise is still checked.
##   4. The path → tokenizer choice: every sample's extension selects the
##      tokenizer of the Monaco language it was captured in (C is Monaco's
##      `c` language, registered with the C++ definition; TOML has none and is
##      drawn plain, as on the desktop).
##   5. The DESKTOP'S EDITOR opens every sample in that same Monaco language
##      (`diff_document.editorLanguageForPath`, what `ui/editor.nim` passes to
##      `createMonacoEditor`), so a file the terminal colours is never one the
##      desktop draws plain — and every extension the terminal lexes resolves,
##      on the desktop, to the language the terminal lexes it as.
##
## No mocks: the real definitions, the real theme files, a real capture.

import std/[json, os, strutils, tables, unicode, unittest]

import isonim_tui
import ../app/syntax/highlighter
import ../app/syntax/monarch
import ../app/theme/editor_theme
import ../app/syntax/lexical
import ../../viewmodel/viewmodels/diff_document

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  DarkTheme = staticRead("../../../public/third_party/monaco-themes/themes/" &
                         "customThemes/json/codetracerDark.json")
  LightTheme = staticRead("../../../public/third_party/monaco-themes/themes/" &
                          "customThemes/json/codetracerWhite.json")
  Capture = "src/tests/visual/answers/plat47-monaco-lexers.electron.json"
  EditorLanguagesCapture =
    "src/tests/visual/answers/plat47-editor-languages.electron.json"
  Samples = "src/frontend/tui/tests/fixtures/monaco_lexers"
  MonarchDefinitions = staticRead("../app/syntax/monarch_languages.json")
  JsonTokenTypes = ["delimiter.bracket.json", "delimiter.array.json",
                    "delimiter.colon.json", "delimiter.comma.json",
                    "keyword.json", "string.value.json", "number.json",
                    "string.key.json", "comment.block.json",
                    "comment.line.json", ""]
    ## `jsonMode.js`'s `TOKEN_*` constants, and the untyped whitespace.

proc repoRoot(): string =
  result = getEnv("CODETRACER_REPO_ROOT")
  if result.len == 0:
    result = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

proc rulesOf(doc: JsonNode): Table[string, string] =
  for r in doc["rules"]:
    if r.hasKey("foreground"):
      result[r{"token"}.getStr] = "#" & r["foreground"].getStr.toLowerAscii
          .strip(chars = {'#'})

proc monacoResolve(rules: Table[string, string]; scope: string): string =
  ## Monaco's reading: the scope's rule, else its longest dotted prefix's,
  ## else the default rule.
  var parts = if scope.len > 0: scope.split('.') else: @[]
  while parts.len > 0:
    let k = parts.join(".")
    if k in rules: return rules[k]
    parts.setLen(parts.len - 1)
  rules[""]

proc typeAt(tokens: JsonNode; utf16: int): string =
  ## The capture's token type covering one UTF-16 offset of a line.
  var t = ""
  for tok in tokens:
    if tok[0].getInt <= utf16:
      t = tok[1].getStr
  t

proc termTypeAt(tokens: seq[MonarchToken]; byteOffset: int): string =
  var t = ""
  for tok in tokens:
    if tok.start <= byteOffset:
      t = tok.tokenType
  t

proc literalTokens(action: JsonNode; into: var seq[string]) =
  case action.kind
  of JString:
    into.add action.getStr
  of JObject:
    if action.hasKey("group"):
      for g in action["group"]: literalTokens(g, into)
    elif action.hasKey("cases"):
      for pair in action["cases"]: literalTokens(pair[1], into)
    else:
      into.add action{"token"}.getStr("")
  else:
    discard

suite "PLAT-47 B4: every terminal lexer tokenises as the desktop's Monaco does":

  let docs = [dmDark: parseJson(DarkTheme), dmLight: parseJson(LightTheme)]
  let root = repoRoot()
  let capturePath = root / Capture
  if not fileExists(capturePath):
    checkpoint(Capture & " is absent: run `just plat47-capture-electron`")
  let capture = if fileExists(capturePath): parseJson(readFile(capturePath))
                else: newJObject()

  test "the capture covers one sample per language, each tokenised in its Monaco language":
    ck fileExists(capturePath)
    var names: seq[string] = @[]
    for kind, path in walkDir(root / Samples):
      names.add path.extractFilename
    ck names.len == 14
    for name in names:
      ck capture{"samples"}.hasKey(name)
      let lexer = lexerForPath(name)
      let language = capture{"samples"}{name}{"language"}.getStr
      if language == "plaintext":
        # TOML: Monaco has no tokenizer, the desktop draws it plain.
        ck lexer == lxNone
        ck modeForPath(name) == hmNone
      else:
        ck monacoLanguageOf(lexer) ==
           (if language == "c": "cpp" else: language)
        # Every language the capture tokenised is registered in the
        # desktop's Monaco.
        var registered = false
        for id in capture{"registered"}:
          if id.getStr == language: registered = true
        ck registered

  test "every character has the desktop's token type":
    var compared = 0
    var mismatches: seq[string] = @[]
    for name, sample in capture{"samples"}.pairs:
      let lexer = lexerForPath(name)
      let lines = readFile(root / Samples / name).split('\n')
      ck sample["lines"].len == lines.len
      var context = initialContext(lexer)
      for i, line in lines:
        let toks = monacoLineTokens(lexer, line, context)
        var utf16 = 0
        var byteAt = 0
        for r in line.runes:
          let desk = typeAt(sample["lines"][i], utf16)
          let term = if lexer == lxNone: "" else: termTypeAt(toks, byteAt)
          inc compared
          if desk != term and mismatches.len < 20:
            mismatches.add name & ":" & $(i + 1) & ":" & $utf16 & " '" & $r &
                           "' desktop " & desk & ", terminal " & term
          utf16 += (if int(r) > 0xFFFF: 2 else: 1)
          byteAt += size(r)
    if mismatches.len > 0:
      checkpoint("token types that differ:\n  " & mismatches.join("\n  "))
    ck mismatches.len == 0
    checkpoint("characters compared: " & $compared)
    ck compared > 7000

  test "every character has the desktop's colour, in both themes":
    var compared = 0
    var mismatches: seq[string] = @[]
    for mode in [dmDark, dmLight]:
      let rules = rulesOf(docs[mode])
      for name, sample in capture{"samples"}.pairs:
        let lines = readFile(root / Samples / name).split('\n')
        let h = highlightWindow(name, 1, lines)
        for i, line in lines:
          let spans = h.spansForLine(i + 1)
          var utf16 = 0
          var cell = 0
          for r in line.runes:
            let desk = monacoResolve(rules, typeAt(sample["lines"][i], utf16))
            var cls = tcPlain
            for sp in spans:
              if cell >= sp.startCell and cell < sp.endCell:
                cls = sp.class
            let term = DesignTokenHex[tokenClassToken(cls)][mode]
            inc compared
            if desk != term and mismatches.len < 20:
              mismatches.add $mode & " " & name & ":" & $(i + 1) & ":" &
                             $cell & " '" & $r & "' desktop " & desk &
                             ", terminal " & $cls & " " & term
            utf16 += (if int(r) > 0xFFFF: 2 else: 1)
            cell += max(1, displayWidth($r))
    if mismatches.len > 0:
      checkpoint("characters coloured otherwise than the desktop's:\n  " &
                 mismatches.join("\n  "))
    ck mismatches.len == 0
    ck compared > 14000

  test "every token type the definitions can produce is painted its rule's colour":
    let defs = parseJson(MonarchDefinitions)
    var types: seq[string] = @[]
    for id, lang in defs["languages"].pairs:
      let postfix = lang["tokenPostfix"].getStr
      var raw: seq[string] = @[lang["defaultToken"].getStr]
      for state, rules in lang["states"].pairs:
        for r in rules:
          literalTokens(r["action"], raw)
      for t in raw:
        # `@brackets` resolves through the bracket table (below), `@rematch`
        # emits nothing; `$`-substituted tokens keep their literal prefix,
        # which is what their rule resolves by.
        if t.startsWith("@") or t.len == 0:
          continue
        let literal = if '$' in t: t[0 ..< t.find('$')].strip(chars = {'.'})
                      else: t
        types.add literal & postfix
      for b in lang["brackets"]:
        types.add b["token"].getStr
    for t in JsonTokenTypes:
      types.add t
    var unmapped: seq[string] = @[]
    var wrong: seq[string] = @[]
    for t in types:
      let rule = themeRuleOf(t)
      var mapped = false
      for (scope, _) in MonacoScopeClass:
        if scope == rule: mapped = true
      if not mapped:
        unmapped.add t & " -> " & rule
        continue
      let cls = classForMonacoToken(t)
      for mode in [dmDark, dmLight]:
        let want = monacoResolve(rulesOf(docs[mode]), t)
        let got = DesignTokenHex[tokenClassToken(cls)][mode]
        if want != got:
          wrong.add $mode & " " & t & ": rule " & want & ", class " & $cls &
                    " " & got
    checkpoint("token types checked: " & $types.len)
    if unmapped.len > 0:
      checkpoint("unmapped: " & unmapped.join(", "))
    if wrong.len > 0:
      checkpoint("painted otherwise: " & wrong.join(", "))
    ck types.len > 300
    ck unmapped.len == 0
    ck wrong.len == 0

  test "the desktop's editor opens every sample in the language the terminal lexes it as":
    # `ui/editor.nim` hands Monaco `editorLanguageForPath(path, toCLang(lang))`;
    # the fallback is spelled here as a value Monaco registers no tokenizer
    # for, so a sample that falls through is drawn plain.
    const Fallback = "unknown"
    for name, sample in capture{"samples"}.pairs:
      let language = sample{"language"}.getStr
      let opened = editorLanguageForPath("/src/" & name, Fallback)
      if language == "plaintext":
        ck opened == Fallback
      else:
        ck opened == language
    # And the other direction: every extension the terminal lexes with one of
    # the desktop's tokenizers opens in the desktop's editor in that
    # tokenizer's language (C and its header are Monaco's `c`, registered
    # with the C++ definition).
    for (ext, lexer) in LexerExtensions:
      let opened = editorLanguageForPath("/src/file" & ext, Fallback)
      checkpoint(ext & " -> " & opened)
      ck (if opened == "c": "cpp" else: opened) == monacoLanguageOf(lexer)
    # THE DESKTOP ITSELF: every sample opened from its Files pane in the real
    # Electron editor (`plat47-editor-languages-capture.spec.ts`) got a model
    # in exactly that language, and Monaco tokenised it (TOML: none, drawn
    # plain as in the terminal).
    let opened = root / EditorLanguagesCapture
    ck fileExists(opened)
    if fileExists(opened):
      let got = parseJson(readFile(opened))["samples"]
      ck got.len == capture{"samples"}.len
      for name, sample in capture{"samples"}.pairs:
        let language = sample{"language"}.getStr
        let desktop = got{name}{"language"}.getStr
        checkpoint(name & ": desktop editor " & desktop & ", tokens " &
                   $got{name}{"tokenTypes"}.getInt)
        if language == "plaintext":
          ck got{name}{"tokenTypes"}.getInt == 0
        else:
          ck desktop == language
          ck got{name}{"tokenTypes"}.getInt > 1

  test "the exported definitions are the desktop's monaco-editor":
    # The capture's Monaco and the exported JSON are one version: the desktop
    # links `node_modules/monaco-editor/min`, and the JSON was exported from
    # the same package (`ci/test/monarch-languages-fresh.sh` regenerates it).
    let pkg = root / "node_modules" / "monaco-editor" / "package.json"
    if fileExists(pkg):
      ck parseJson(readFile(pkg))["version"].getStr == monacoVersion()
    else:
      checkpoint("node_modules/monaco-editor is not installed here")
      ck monacoVersion().len > 0
    for id in ["python", "rust", "cpp", "go", "javascript", "typescript",
               "java", "ruby", "shell", "yaml"]:
      ck not monarchLanguage(id).isNil

echo "CHECKS: ", CHECKS
