## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/syntax/token_class.nim — the syntax classes the terminal's highlighter
## sorts text into (CTUI-5), on their own. No imports: the theme
## (`app/theme/editor_theme.nim`, PLAT-47) maps each class to the desktop's
## Monaco token scope and needs the enum without the tree-sitter runtime the
## highlighter links. `highlighter.nim` re-exports it.

type
  TokenClass* = enum
    ## The palette a terminal source pane can actually distinguish.
    ##
    ## Deliberately small. §3.3.2 names "keywords, types, strings, comments,
    ## identifiers"; operators and punctuation are added because every grammar
    ## emits them as anonymous leaves and leaving them `tcPlain` makes a line
    ## of code read as one undifferentiated run.
    tcPlain
    tcKeyword
    tcType
    tcString
    tcNumber
    tcComment
    tcIdentifier
    tcOperator
    tcPunctuation
    tcStringEscape
      ## A string's quotes and prefix (`f"`) as the desktop's Monaco Python
      ## tokenizer scopes them: `string.escape`, which the desktop's theme
      ## colours apart from the string body. Produced by the Python lexer.
    tcBracket
      ## `[` / `]`, Monaco's `delimiter.bracket`, which the desktop's dark
      ## theme colours apart from other delimiters. Produced by the Python
      ## lexer.
    tcTag
      ## A decorator (`@name`), Monaco's `tag`. Produced by the Python lexer.
