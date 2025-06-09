type
  TokenText* = enum
    InstanceOpen,
    InstanceClose,
    ArrayOpen,
    ArrayClose,
    SeqOpen,
    SeqClose

  WhitespaceCharacter* = enum
    WhitespaceSpaces,
    WhitespaceTabs

  Whitespace* = ref object
    character*: WhitespaceCharacter
    width*: int

  TokenKind* = enum
    EmptySymbol,
    TkSymbol,
    TkRegister,
    TkRegisterOrOffset,
    TkField,
    TkIndex,
    # those are not used in python
    TkComment,
    TkKeyword,
    TkLit,
    TkIntLit,
    TkDirective,
    TkIndent,
    TkWhitespace

  Token* = object
    kind*: TokenKind
    tokenName*: cstring
    raw*: langstring
    line*: int
    column*: int

  # support bytecode in general
  AssemblyToken* = ref object
    offset*:          int
    highLevelLine*:   int
    opcode*:          cstring
    address*:         cstring
    value*:           seq[Token]
    help*:            cstring

const
  TOKEN_TEXTS*: array[Lang, array[TokenText, string]] = [
    # InstanceOpen InstanceClose ArrayOpen ArrayClose SeqOpen SeqClose
    ["{", "}", "[", "]", "vector[", "]"],       # LangC
    ["{", "}", "[", "]", "vector[", "]"],       # LangCpp
    ["{", "}", "[", "]", "vec![", "]"],         # LangRust
    ["(", ")", "[", "]", "@[", "]"],            # LangNim
    ["{", "}", "[", "]", "vector[", "]"],       # LangGo
    ["{", "}", "[", "]", "vector[", "]"],       # LangPascal TODO
    ["(", ")", "[", "]", "[", "]"],             # LangPython
    ["(", ")", "[", "]", "[", "]"],             # LangRuby
    ["(", ")", "[", "]", "[", "]"],             # LangRubyDb
    ["{", "}", "[", "]", "[", "]"],             # LangJavascript
    ["{", "}", "[", "]", "[", "]"],             # LangLua
    ["{", "}", "[", "]", "[", "]"],             # LangAsm
    ["{", "}", "[", "]", "[", "]"],             # LangNoir
    ["{", "}", "[", "]", "[", "]"],             # LangRustWasm
    ["{", "}", "[", "]", "[", "]"],             # LangCppWasm
    ["{", "}", "[", "]", "[", "]"],             # LangSmall
    ["", "", "", "", "", ""]                    # LangUnknown
  ]