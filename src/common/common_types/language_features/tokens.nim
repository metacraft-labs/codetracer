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

func tokenTextsFor*(lang: Lang): array[TokenText, string] =
  ## The bracket vocabulary the value renderer spells a language's aggregates
  ## with.
  ##
  ## Exhaustive ``case``.  This was a positional
  ## ``array[Lang, array[TokenText, string]]`` of 40 rows, most of them
  ## identical, which made it the worst-case shape for a silent shift: a member
  ## removed anywhere above ``LangPhp`` would have moved Nim's ``@[`` or Rust's
  ## ``vec![`` onto a neighbouring language and left 37 look-alike rows in which
  ## to notice it.
  ##
  ## Order within each row is ``TokenText``'s own declaration order:
  ## InstanceOpen, InstanceClose, ArrayOpen, ArrayClose, SeqOpen, SeqClose.
  case lang
  of LangRust:
    ["{", "}", "[", "]", "vec![", "]"]
  of LangNim:
    ["(", ")", "[", "]", "@[", "]"]
  of LangC, LangCpp, LangGo, LangPascal:  # LangPascal TODO
    ["{", "}", "[", "]", "vector[", "]"]
  of LangPython, LangRuby, LangRubyDb, LangPythonDb:
    ["(", ")", "[", "]", "[", "]"]
  of LangUnknown, LangBash, LangZsh:
    ["", "", "", "", "", ""]
  of LangFortran, LangD, LangCrystal, LangLean, LangJulia, LangAda,
     LangJavascript, LangLua, LangAsm, LangNoir, LangRustWasm, LangCppWasm,
     LangSolidity, LangMasm, LangSway, LangMove, LangPolkavm, LangCairo,
     LangCircom, LangLeo, LangTolk, LangAiken, LangCadence, LangSolana,
     LangElixir, LangErlang, LangPhp,
     LangGdScript:  # GDScript: Dictionary {} / Array []
    ["{", "}", "[", "]", "[", "]"]

const
  TOKEN_TEXTS*: array[Lang, array[TokenText, string]] = block:
    ## Materialised from ``tokenTextsFor`` at compile time so that existing
    ## ``TOKEN_TEXTS[lang][ArrayOpen]`` call sites keep working while the data
    ## itself is a compiler-checked total function.
    var table: array[Lang, array[TokenText, string]]
    for lang in Lang:
      table[lang] = tokenTextsFor(lang)
    table
