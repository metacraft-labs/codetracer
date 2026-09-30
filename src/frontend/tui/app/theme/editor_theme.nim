## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/theme/editor_theme.nim — PLAT-47 deliverable 2. **One editor theme, two
## renderers: which of the desktop's Monaco token colours each of this
## front-end's syntax classes is painted with.**
##
## ## Where the colours come from
##
## The desktop's editor is Monaco, themed by `codetracerDark.json` /
## `codetracerWhite.json` (`src/public/third_party/monaco-themes/themes/
## customThemes/json/`, fed to `monaco.editor.defineTheme` by
## `renderer.ensureMonacoThemesDefined`). The same two files are read by
## `scripts/tokens-to-styl.sh --editor-theme`, which emits every token rule, and
## the colours the desktop paints around Monaco, as `DesignToken` members of
## `styles/generated/design_tokens.nim` (`dtEditorTheme…`), resolved per mode
## and checked fresh by `ci/test/design-tokens-fresh.sh`. So a colour here is a
## generated token, never a literal (`ci/test/tui-design-tokens-boundary.sh`
## still rejects any `#rrggbb` under `tui/app/`), and an edit of the desktop's
## theme moves the terminal's editor with it.
##
## PLAT-46 painted the editor from the design system's `colors/editor/*`
## (Dracula): keyword `#ff79c6` where the desktop shows `#5a9dd4`, the editor
## ground `#1b1b1b` where the desktop shows `#282828`. The user's requirement
## (2026-09-27) is that they MATCH; they now come from the same file.
##
## ## The one table: syntax class -> Monaco token scope
##
## The terminal classifies what it highlights into `TokenClass` (the tree-sitter
## grammars' node types through `highlighter.classForNodeType`, the lexical
## fallback directly). `TokenClassScope` names, for each class, the Monaco
## token scope the desktop's tokenizers give the same text, and
## `editorScopeToken` resolves it against the theme's rules exactly as Monaco
## does — the rule for the scope, else for its longest dotted prefix, else the
## default rule — so a class whose scope has no rule of its own (an
## identifier) takes the default foreground, as it does on the desktop.
## `tests/test_plat47_editor_theme.nim` asserts the table covers every class
## the TUI's grammars' node types reach, and lists (rather than silently
## colours) the node categories that reach none — that listing,
## `UnmappedCaptures`, lives in the test, because only the coverage check
## reads it.

import ../syntax/token_class
import ../../../styles/generated/design_tokens

export design_tokens, TokenClass

const
  TokenClassScope*: array[TokenClass, string] = [
    # Unclassified text: Monaco's default rule.
    tcPlain: "",
    tcKeyword: "keyword",
    tcType: "type",
    tcString: "string",
    tcNumber: "number",
    tcComment: "comment",
    # No theme has an `identifier` rule, so this is the default foreground —
    # which is what the desktop draws a name in (`mtk1`, measured `#f3f3f3`
    # on `calc`).
    tcIdentifier: "identifier",
    tcOperator: "operator",
    tcPunctuation: "delimiter",
    tcStringEscape: "string.escape",
    tcBracket: "delimiter.bracket",
    tcTag: "tag",
    # PLAT-47 B4: the scopes the other Monaco tokenizers (Rust, C/C++, Go,
    # JavaScript/TypeScript, Java, Ruby, shell, YAML) give text the desktop
    # colours on its own.
    tcTypeIdentifier: "type.identifier",
    tcKeywordType: "keyword.type",
    tcCommentDoc: "comment.doc",
    tcRegexp: "regexp",
    tcVariable: "variable",
    tcNamespace: "namespace",
    tcAttributeName: "attribute.name",
    tcMetatag: "metatag"]
    ## **THE TABLE.** Indexed by `TokenClass`, so a class added without a row
    ## does not compile.

func editorScopeToken*(scope: string): DesignToken =
  ## The generated token for `scope`, resolved as Monaco resolves a token
  ## scope against its theme: the scope's own rule, else its longest dotted
  ## prefix's, else the default rule.
  var s = scope
  while true:
    for r in EditorThemeRules:
      if r.scope == s:
        return r.token
    if s.len == 0:
      break
    var cut = -1
    for i in countdown(s.high, 0):
      if s[i] == '.':
        cut = i
        break
    s = if cut < 0: "" else: s[0 ..< cut]
  dtEditorThemeRuleDefault

func tokenClassToken*(c: TokenClass): DesignToken =
  ## The generated token a syntax class is painted with.
  editorScopeToken(TokenClassScope[c])


# ---------------------------------------------------------------------------
# PLAT-47 B4: a Monaco token TYPE -> the class that paints it
# ---------------------------------------------------------------------------

const MonacoScopeClass*: seq[(string, TokenClass)] = @[
  ("", tcPlain),
  ("keyword", tcKeyword), ("keyword.type", tcKeywordType),
  ("type", tcType), ("type.identifier", tcTypeIdentifier),
  ("string", tcString), ("string.escape", tcStringEscape),
  ("number", tcNumber), ("number.hex", tcNumber), ("number.octal", tcNumber),
  ("number.binary", tcNumber), ("number.float", tcNumber),
  ("comment", tcComment), ("comment.doc", tcCommentDoc),
  ("operator", tcOperator),
  ("delimiter", tcPunctuation), ("delimiter.bracket", tcBracket),
  ("tag", tcTag), ("regexp", tcRegexp), ("variable", tcVariable),
  ("namespace", tcNamespace), ("attribute.name", tcAttributeName),
  ("metatag", tcMetatag)]
  ## Every theme rule a token of the exported tokenizers can resolve to, and
  ## the class painted for it. A rule the tokenizers cannot reach has no row;
  ## `tests/test_plat47_monaco_lexers.nim` walks every token the definitions
  ## can produce and asserts each resolves to a rule with a row here whose
  ## class is painted the rule's colour in BOTH themes. (The number variants
  ## share `tcNumber` because both themes paint them the number colour; that
  ## test is what keeps it true.)

func themeRuleOf*(tokenType: string): string =
  ## The theme rule Monaco applies to a token type: the rule for the type,
  ## else for its longest dotted prefix, else the default (`""`). Monaco's
  ## theme trie matches a type segment by segment from the start, which picks
  ## the same rule.
  var s = tokenType
  while s.len > 0:
    for r in EditorThemeRules:
      if r.scope == s:
        return s
    var cut = -1
    for i in countdown(s.high, 0):
      if s[i] == '.':
        cut = i
        break
    s = if cut < 0: "" else: s[0 ..< cut]
  ""

func classForMonacoToken*(tokenType: string): TokenClass =
  ## The class that paints a Monaco token type as the desktop's theme does.
  ## An identifier (no rule of its own, the default colour) keeps its own
  ## class so the terminal can still tell a name from punctuation-free
  ## whitespace; it is painted the default colour.
  let rule = themeRuleOf(tokenType)
  if rule.len == 0:
    return (if tokenType.len >= 10 and tokenType[0 ..< 10] == "identifier":
              tcIdentifier
            else: tcPlain)
  for (scope, cls) in MonacoScopeClass:
    if scope == rule:
      return cls
  tcPlain
