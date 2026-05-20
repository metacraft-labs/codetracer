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

const
  TOKEN_TEXTS*: array[Lang, array[TokenText, string]] = [
    # InstanceOpen InstanceClose ArrayOpen ArrayClose SeqOpen SeqClose
    ["{", "}", "[", "]", "vector[", "]"],       # LangC
    ["{", "}", "[", "]", "vector[", "]"],       # LangCpp
    ["{", "}", "[", "]", "vec![", "]"],         # LangRust
    ["(", ")", "[", "]", "@[", "]"],            # LangNim
    ["{", "}", "[", "]", "vector[", "]"],       # LangGo
    ["{", "}", "[", "]", "vector[", "]"],       # LangPascal TODO
    ["{", "}", "[", "]", "[", "]"],             # LangFortran
    ["{", "}", "[", "]", "[", "]"],             # LangD
    ["{", "}", "[", "]", "[", "]"],             # LangCrystal
    ["{", "}", "[", "]", "[", "]"],             # LangLean
    ["{", "}", "[", "]", "[", "]"],             # LangJulia
    ["{", "}", "[", "]", "[", "]"],             # LangAda
    ["(", ")", "[", "]", "[", "]"],             # LangPython
    ["(", ")", "[", "]", "[", "]"],             # LangRuby
    ["(", ")", "[", "]", "[", "]"],             # LangRubyDb
    ["{", "}", "[", "]", "[", "]"],             # LangJavascript
    ["{", "}", "[", "]", "[", "]"],             # LangLua
    ["{", "}", "[", "]", "[", "]"],             # LangAsm
    ["{", "}", "[", "]", "[", "]"],             # LangNoir
    ["{", "}", "[", "]", "[", "]"],             # LangRustWasm
    ["{", "}", "[", "]", "[", "]"],             # LangCppWasm
    ["(", ")", "[", "]", "[", "]"],             # LangPythonDb
    ["", "", "", "", "", ""],                   # LangUnknown
    ["", "", "", "", "", ""],                   # LangBash
    ["", "", "", "", "", ""],                   # LangZsh
    ["{", "}", "[", "]", "[", "]"],             # LangSolidity
    ["{", "}", "[", "]", "[", "]"],             # LangMasm
    ["{", "}", "[", "]", "[", "]"],             # LangSway
    ["{", "}", "[", "]", "[", "]"],             # LangMove
    ["{", "}", "[", "]", "[", "]"],             # LangPolkavm
    ["{", "}", "[", "]", "[", "]"],             # LangCairo
    ["{", "}", "[", "]", "[", "]"],             # LangCircom
    ["{", "}", "[", "]", "[", "]"],             # LangLeo
    ["{", "}", "[", "]", "[", "]"],             # LangTolk
    ["{", "}", "[", "]", "[", "]"],             # LangAiken
    ["{", "}", "[", "]", "[", "]"],             # LangCadence
    ["{", "}", "[", "]", "[", "]"],             # LangSolana
    ["{", "}", "[", "]", "[", "]"],             # LangElixir
    ["{", "}", "[", "]", "[", "]"]              # LangErlang
  ]
