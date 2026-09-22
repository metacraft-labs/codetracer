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
  ## ``array[Lang, array[TokenText, string]]`` of 40 rows (then), most of them
  ## identical, which made it the worst-case shape for a silent shift: a member
  ## removed anywhere above ``LangPhp`` would have moved Nim's ``@[`` or Rust's
  ## ``vec![`` onto a neighbouring language and left 37 look-alike rows in which
  ## to notice it.
  ##
  ## Order within each row is ``TokenText``'s own declaration order:
  ## InstanceOpen, InstanceClose, ArrayOpen, ArrayClose, SeqOpen, SeqClose.
  ##
  ## The vocabulary is a property of the SOURCE LANGUAGE, not of the target
  ## ISA: a Rust value is spelled `vec![` whether the program ran natively or
  ## as a wasm module.  Until LRS-4 `LangRustWasm` / `LangCppWasm` sat in the
  ## generic bracket row below and a wasm-recorded Rust sequence rendered as
  ## `[` while the same program recorded natively rendered `vec![` -- the
  ## conflation of language and ISA showing through the value renderer
  ## (design §1.2).  LRS-4 gave each wasm member its language's row; LRS-5's
  ## second deletion round deleted the members, and **the fold became a
  ## no-op**: a wasm recording of a Rust program summarises as `LangRust` and
  ## reaches the Rust row because there is no second Rust member to reach the
  ## wrong one.  `LangPolkavm` / `LangSolana` left the generic row the same
  ## way -- they named a VM, and a VM has no bracket vocabulary at all.
  case lang
  of LangRust:
    ["{", "}", "[", "]", "vec![", "]"]
  of LangNim:
    ["(", ")", "[", "]", "@[", "]"]
  of LangC, LangCpp, LangGo, LangPascal:  # LangPascal TODO
    ["{", "}", "[", "]", "vector[", "]"]
  of LangRubyDb, LangPythonDb:
    ["(", ")", "[", "]", "[", "]"]
  of LangUnknown, LangBash, LangZsh:
    ["", "", "", "", "", ""]
  of LangFortran, LangD, LangCrystal, LangLean, LangJulia, LangAda,
     LangJavascript, LangLua, LangAsm, LangNoir,
     LangSolidity, LangMasm, LangSway, LangMove, LangCairo,
     LangCircom, LangLeo, LangTolk, LangAiken, LangCadence,
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
