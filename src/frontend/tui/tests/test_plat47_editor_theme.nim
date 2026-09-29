## test_plat47_editor_theme.nim — PLAT-47 deliverable 2, Tier 1. **One editor
## theme, two renderers.**
##
## The desktop's editor colours are its Monaco theme documents
## (`src/public/third_party/monaco-themes/themes/customThemes/json/
## codetracerDark.json` / `codetracerWhite.json`, fed to `defineTheme`). The
## terminal's editor roles are GENERATED from the same two files
## (`scripts/tokens-to-styl.sh --editor-theme`, into `design_tokens.nim`), and
## its syntax classes reach them through ONE table
## (`app/theme/editor_theme.TokenClassScope`). This suite asserts:
##
##   * the generated tokens ARE the files' values: each rule's hex, resolved as
##     Monaco resolves a scope, read here from the JSON itself (parsed by this
##     file, not by the generator), and the `codetracer` block's colours;
##   * every syntax role and every editor surface role of the terminal is one
##     of those generated tokens — none is a design-system `colors/editor/*`
##     token any more (PLAT-46 used Dracula there);
##   * THE COVERAGE OF THE TABLE: every node type the terminal's ten
##     tree-sitter grammars can emit is classified, every class it reaches has
##     a Monaco scope, and every named node category that LOOKS lexical (a
##     literal, a string, a comment, an identifier, …) but reaches no class is
##     LISTED in `UnmappedCaptures` (below) rather than silently painted
##     plain — a new grammar category shows up here by name.
##
## No mocks: the real theme files, the real generated module, the real
## vendored grammars through the real tree-sitter runtime.

import std/[json, os, sets, strutils, tables, unicode, unittest]

import isonim_tui
import ../app/syntax/highlighter
import ../app/theme/editor_theme
import ../app/theme/roles

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  DarkTheme = staticRead("../../../public/third_party/monaco-themes/themes/" &
                         "customThemes/json/codetracerDark.json")
  LightTheme = staticRead("../../../public/third_party/monaco-themes/themes/" &
                          "customThemes/json/codetracerWhite.json")

const
  LexicalSuffixes = ["literal", "string", "comment", "escape",
                     "escape_sequence", "identifier", "boolean", "bool",
                     "number"]
    ## How a tree-sitter category's name ENDS when it names a TOKEN a reader
    ## would expect coloured (`boolean_literal`, `quoted_identifier`), rather
    ## than a structure (`call_expression`, `tuple_type`).

func looksLexical(nodeType: string): bool =
  ## Whether a named node category reads as a colourable token.
  let lower = nodeType.toLowerAscii
  for w in LexicalSuffixes:
    if lower.endsWith(w):
      return true
  false

const UnmappedCaptures: seq[string] = @[
    "address_literal", "affine_group_literal", "aleo_literal", "any_comment",
    "array_literal", "bool", "bool_literal", "boolean", "boolean_literal",
    "byte_string_literal", "bytearray_literal", "constant_identifier",
    "dictionary_literal", "escape", "escape_sequence", "field_literal",
    "fixed_point_literal", "hex_literal", "hex_string_literal",
    "int_literal", "literal", "macro_identifier", "negative_literal",
    "nil_literal", "null_literal", "object_literal", "path_literal",
    "product_group_literal", "program_name_literal", "property_identifier",
    "qualified_identifier", "quoted_identifier", "scalar_literal",
    "scoped_identifier", "scoped_type_identifier", "short_string",
    "shorthand_field_identifier", "signature_literal", "signed_literal",
    "triple_string_literal", "typed_identifier", "unsigned_literal"]
  ## THE LISTING (PLAT-47's risk mitigation: "an unmappable capture is listed,
  ## not silently coloured"). Named node categories of the terminal's ten
  ## grammars whose names read as tokens but which `classForNodeType` does not
  ## classify — each is painted in the default foreground, as the desktop
  ## paints a Monaco token no rule covers, and each is named here so the next
  ## one a grammar adds fails `test_plat47_editor_theme.nim` by name instead
  ## of being painted plain unnoticed. A structure node (a `string` whose
  ## children are the literal's parts) is listed too: its LEAVES are what the
  ## highlighter colours.
  ## (Kept in THIS file: the coverage check below is its only reader, and a
  ## product module exporting a list no product code reads is what the
  ## frontend-reachability ratchet exists to refuse.)

proc ts_language_symbol_count(l: ptr TSLanguage): uint32 {.importc, nodecl.}
proc ts_language_symbol_name(l: ptr TSLanguage; s: uint16): cstring
  {.importc, nodecl.}
proc ts_language_symbol_type(l: ptr TSLanguage; s: uint16): cint
  {.importc, nodecl.}
  ## tree-sitter's own C API (`tree_sitter/api.h`): a symbol's name and kind —
  ## 0 a named node, 1 an anonymous one (a literal token), 2 auxiliary.

proc rulesOf(doc: JsonNode): Table[string, string] =
  for r in doc["rules"]:
    if r.hasKey("foreground"):
      result[r{"token"}.getStr] = "#" & r["foreground"].getStr.toLowerAscii
          .strip(chars = {'#'})

proc monacoResolve(rules: Table[string, string]; scope: string): string =
  ## Monaco's reading, restated here: the scope's rule, else its longest
  ## dotted prefix's, else the default rule.
  var parts = if scope.len > 0: scope.split('.') else: @[]
  while parts.len > 0:
    let k = parts.join(".")
    if k in rules: return rules[k]
    parts.setLen(parts.len - 1)
  rules[""]

suite "PLAT-47: the terminal's editor is the desktop's Monaco theme":

  let docs = [dmDark: parseJson(DarkTheme), dmLight: parseJson(LightTheme)]

  test "every generated rule token is the theme file's rule, per mode":
    var seen = 0
    for r in EditorThemeRules:
      for mode in DesignMode:
        let want = monacoResolve(rulesOf(docs[mode]), r.scope)
        if DesignTokenHex[r.token][mode] != want:
          checkpoint(r.scope & " " & $mode & ": generated " &
                     DesignTokenHex[r.token][mode] & ", theme " & want)
        ck DesignTokenHex[r.token][mode] == want
      inc seen
    # Every rule of either file is there.
    var scopes = initHashSet[string]()
    for mode in DesignMode:
      for k in rulesOf(docs[mode]).keys: scopes.incl k
    ck seen == scopes.len

  test "the colours the desktop paints around Monaco come from the file's own block":
    for mode in DesignMode:
      let blk = docs[mode]["codetracer"]
      for (key, token) in [("ground", dtEditorThemeGround),
                           ("lineNumber", dtEditorThemeLineNumber),
                           ("activeLineNumber", dtEditorThemeActiveLineNumber),
                           ("executionLine", dtEditorThemeExecutionLine),
                           ("selection", dtEditorThemeSelection)]:
        let v = blk[key].getStr
        if v.startsWith("{"):
          # A reference into the design system (the dark file's ground and
          # active line number): the design system's own token, in this mode.
          let want = if key == "ground": dtColorsUiSurfaceBasePanel
                     else: dtColorsUiTextPrimaryLabel
          ck v == (if key == "ground": "{colors.ui.surface.base.panel}"
                   else: "{colors.ui.text.primary.label}")
          ck DesignTokenHex[token][mode] == DesignTokenHex[want][mode]
        else:
          ck DesignTokenHex[token][mode] == v.toLowerAscii

  test "the generated editor colours are the desktop's MEASURED ones, in both themes":
    ## The Electron capture launches the desktop in its dark and in its light
    ## theme (`plat47-desktop-parity-capture.spec.ts`) and reads what the eye
    ## sees: the ground behind Monaco, a keyword, a string, a comment, a name,
    ## a delimiter, the resting and the active line number, the execution
    ## line's band and the selection's. The terminal's generated tokens must
    ## BE those values — a composed value (a theme colour laid on a ground
    ## the desktop does not draw) fails here.
    let root = block:
      var r = getEnv("CODETRACER_REPO_ROOT")
      if r.len == 0:
        r = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
      r
    for (file, mode) in [("plat47-desktop-parity.electron.json", dmDark),
                         ("plat47-desktop-parity-light.electron.json", dmLight)]:
      let path = root / "src/tests/visual/answers" / file
      if not fileExists(path):
        checkpoint(file & " is absent: run `just plat47-capture-electron`")
        ck fileExists(path)
        continue
      let ed = parseJson(readFile(path))["editor"]
      for (key, token) in [
          ("background", dtEditorThemeGround),
          ("keyword", tokenClassToken(tcKeyword)),
          ("string", tokenClassToken(tcString)),
          ("comment", tokenClassToken(tcComment)),
          ("identifier", tokenClassToken(tcIdentifier)),
          ("delimiter", tokenClassToken(tcPunctuation)),
          ("lineNumber", dtEditorThemeLineNumber),
          ("activeLineNumber", dtEditorThemeActiveLineNumber),
          ("executionLine", dtEditorThemeExecutionLine),
          ("selection", dtEditorThemeSelection)]:
        let measured = ed[key].getStr
        if measured != DesignTokenHex[token][mode]:
          checkpoint($mode & " " & key & ": measured " & measured &
                     ", generated " & DesignTokenHex[token][mode])
        ck measured.len == 7
        ck measured == DesignTokenHex[token][mode]

  test "every syntax and editor role paints a generated editor-theme token":
    for c in TokenClass:
      ck TokenClassScope[c].len > 0 or c == tcPlain
    for (role, cls) in [(srSyntaxPlain, tcPlain),
                        (srSyntaxIdentifier, tcIdentifier),
                        (srSyntaxKeyword, tcKeyword), (srSyntaxType, tcType),
                        (srSyntaxString, tcString), (srSyntaxNumber, tcNumber),
                        (srSyntaxComment, tcComment),
                        (srSyntaxOperator, tcOperator),
                        (srSyntaxPunctuation, tcPunctuation)]:
      ck RoleSpecs[role].fg == tokenClassToken(cls)
      ck ($RoleSpecs[role].fg).startsWith("editor-theme/rule/")
    ck RoleSpecs[srSurfaceEditor].bg == dtEditorThemeGround
    ck RoleSpecs[srSurfaceEditor].fg == dtEditorThemeRuleDefault
    ck RoleSpecs[srLineNumber].fg == dtEditorThemeLineNumber
    ck RoleSpecs[srLineNumberActive].fg == dtEditorThemeActiveLineNumber
    ck RoleSpecs[srLineExecution].bg == dtEditorThemeExecutionLine
    ck RoleSpecs[srSurfaceCurrentLine].bg == dtEditorThemeExecutionLine
    ck RoleSpecs[srSurfaceSelection].bg == dtEditorThemeSelection

  test "a scope resolves as Monaco resolves it":
    ck editorScopeToken("keyword") == dtEditorThemeRuleKeyword
    ck editorScopeToken("keyword.control.flow") == dtEditorThemeRuleKeyword
    ck editorScopeToken("comment.doc") == dtEditorThemeRuleCommentDoc
    ck editorScopeToken("identifier") == dtEditorThemeRuleDefault
    ck editorScopeToken("") == dtEditorThemeRuleDefault
    # The desktop's measured identifier colour on `calc` is the default rule.
    ck DesignTokenHex[tokenClassToken(tcIdentifier)][dmDark] == "#f3f3f3"
    ck DesignTokenHex[tokenClassToken(tcKeyword)][dmDark] == "#5a9dd4"

  test "the table covers every capture the terminal's grammars emit":
    var reached: set[TokenClass] = {}
    var unlisted: seq[string] = @[]
    var symbols = 0
    for g in GrammarId:
      if g == giNone: continue
      let lang = languageFor(g).raw
      for s in 0'u32 ..< ts_language_symbol_count(lang):
        let kind = ts_language_symbol_type(lang, uint16(s))
        if kind == 2: continue
        inc symbols
        let name = $ts_language_symbol_name(lang, uint16(s))
        let cls = classForNodeType(name, kind == 0)
        reached.incl cls
        if kind == 0 and cls == tcPlain and looksLexical(name) and
           name notin UnmappedCaptures:
          unlisted.add $g & ":" & name
    checkpoint($symbols & " symbols over the ten grammars; classes reached " &
               $reached)
    if unlisted.len > 0:
      checkpoint("lexical-looking categories that reach no class and are " &
                 "not listed in UnmappedCaptures: " & $unlisted)
    ck unlisted.len == 0
    ck symbols > 1000
    # Every class the grammars reach is in the table, and its scope resolves
    # to a rule of the theme.
    for c in reached:
      ck tokenClassToken(c) in [dtEditorThemeRuleDefault,
                                editorScopeToken(TokenClassScope[c])]
    # And every entry of the listing is really unclassified — a listing that
    # outlived a fix would hide the next unmapped category behind it.
    for name in UnmappedCaptures:
      ck classForNodeType(name, true) == tcPlain

suite "PLAT-47: the terminal's Python is tokenised as the desktop's":

  let docs = [dmDark: parseJson(DarkTheme), dmLight: parseJson(LightTheme)]
  const
    Answers = ["src/tests/visual/answers/plat47-desktop-parity.electron.json",
               "src/tests/visual/answers/plat47-desktop-parity-light.electron.json"]
    CalcSource = "test-programs/calc/main.py"

  proc repoRoot(): string =
    ## The checkout: `CODETRACER_REPO_ROOT` when the lane exports it, else
    ## four levels above this file.
    result = getEnv("CODETRACER_REPO_ROOT")
    if result.len == 0:
      result = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir

  test "every character of calc has the desktop's colour, in both themes":
    ## The desktop's side is `monaco.editor.tokenize` over the editor model
    ## of `calc/main.py`, captured from the real Electron app
    ## (`just plat47-capture-electron`), as (start, scope) per line: each
    ## scope resolved against the theme file as Monaco resolves it. The
    ## terminal's side is `highlightWindow` over the same file from its first
    ## line — the call the source pane makes — each class resolved through
    ## `TokenClassScope` and the GENERATED tokens. Compared rune by rune,
    ## blanks included (a blank is painted too), in the dark and the light
    ## theme. Monaco's offsets are UTF-16 units and the terminal's are cells;
    ## both are walked rune by rune here.
    let root = repoRoot()
    let lines = readFile(root / CalcSource).split('\n')
    let h = highlightWindow(CalcSource, 1, lines)
    ck h.lexer == lxPython
    var compared = 0
    var mismatches: seq[string] = @[]
    for (file, mode) in [(Answers[0], dmDark), (Answers[1], dmLight)]:
      let path = root / file
      if not fileExists(path):
        checkpoint(file & " is absent: run `just plat47-capture-electron`")
        ck fileExists(path)
        continue
      let ans = parseJson(readFile(path))
      ck ans["theme"].getStr == (if mode == dmDark: "dark" else: "light")
      let tokens = ans["monacoTokens"]
      ck tokens["language"].getStr == "python"
      ck tokens["path"].getStr.endsWith("calc/main.py")
      let rules = rulesOf(docs[mode])
      # The capture tokenised the text the desktop opened; it is this file
      # (a trailing newline gives both one last empty line).
      ck tokens["lines"].len == lines.len
      for i in 0 ..< min(lines.len, tokens["lines"].len):
        let toks = tokens["lines"][i]
        var utf16 = 0
        var cell = 0
        var ti = 0
        let spans = h.spansForLine(i + 1)
        for r in lines[i].runes:
          while ti + 1 < toks.len and toks[ti + 1][0].getInt <= utf16:
            inc ti
          let scope = if toks.len > 0: toks[ti][1].getStr else: ""
          let desk = monacoResolve(rules, scope.replace(".python", ""))
          var cls = tcPlain
          for sp in spans:
            if cell >= sp.startCell and cell < sp.endCell:
              cls = sp.class
          let term = DesignTokenHex[tokenClassToken(cls)][mode]
          inc compared
          if desk != term and mismatches.len < 12:
            mismatches.add $mode & " " & $(i + 1) & ":" & $cell & " '" & $r &
                           "' desktop " & scope & " " & desk & ", terminal " &
                           $cls & " " & term
          utf16 += (if int(r) > 0xFFFF: 2 else: 1)
          cell += max(1, displayWidth($r))
    if mismatches.len > 0:
      checkpoint("characters coloured otherwise than the desktop's:\n  " &
                 mismatches.join("\n  "))
    ck mismatches.len == 0
    # The whole file, twice, was compared — not a prefix.
    ck compared > 2 * 3000

  test "a docstring stays a string on every line, as it does on the desktop":
    var st = initPythonLexState()
    let doc = ["def f():", "    \"\"\"First line", "    middle, with def and 1",
               "    last\"\"\"", "    return f\"{x:>5}\" + 'a'"]
    var spans: seq[seq[SyntaxSpan]] = @[]
    for l in doc:
      spans.add pythonLineSpans(l, st)
    ck spans[2].len == 1 and spans[2][0].class == tcString and
       spans[2][0].startCell == 0 and spans[2][0].endCell == doc[2].len
    # After the closing quotes the state is back at the root: `return` is a
    # keyword, the f-string's quote and prefix are `string.escape`, its
    # `{x` an identifier, `:>5` string, `+` the default colour.
    ck spans[4][0].class == tcKeyword
    ck spans[4][1].class == tcStringEscape and spans[4][1].startCell == 11
    ck spans[4][2].class == tcIdentifier
    ck spans[4][3].class == tcString
    let plus = doc[4].find('+')
    var covered = false
    for sp in spans[4]:
      if sp.startCell <= plus and sp.endCell > plus: covered = true
    ck plus > 0 and not covered

echo "CHECKS: ", CHECKS
