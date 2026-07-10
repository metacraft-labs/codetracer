include ../common/common_lang
import
  std/jsffi,
  lib/jslib

proc toLang*(lang: cstring): Lang =
  var langs = JsAssoc[cstring, Lang]{
    c: LangC,
    cpp: LangCpp,
    h: LangC,
    hpp: LangCpp,
    rs: LangRust,
    nim: LangNim,
    go: LangGo,
    pas: LangPascal,
    f90: LangFortran,
    d: LangD,
    cr: LangCrystal,
    lean: LangLean,
    jl: LangJulia,
    adb: LangAda,
    py: LangPythonDb,
    python: LangPythonDb,
    rb: LangRubyDb, # default for ruby for now
    ruby: LangRuby,
    js: LangJavascript,
    `asm`: LangAsm,
    s: LangAsm,
    lua: LangLua,
    nr: LangNoir,
    noir: LangNoir,
    sol: LangSolidity,
    masm: LangMasm,
    sw: LangSway,
    move: LangMove,
    cairo: LangCairo,
    circom: LangCircom,
    leo: LangLeo,
    tolk: LangTolk,
    ak: LangAiken,
    cdc: LangCadence,
    ex: LangElixir,
    exs: LangElixir,
    elixir: LangElixir,
    erl: LangErlang,
    hrl: LangErlang,
    erlang: LangErlang,
    php: LangPhp,
  }
  if langs.hasKey(lang):
    result = langs[lang]
  else:
    result = LangUnknown

proc toLang*(lang: string): Lang =
  result = toLang(cstring(lang))

proc toLangFromFilename*(location: cstring): Lang =
  try:
    let extensionWithDot = ($location).splitFile()[2]
    if extensionWithDot.len > 0:
      let extension = extensionWithDot[1..^1]
      result = toLang(extension)
    else:
      result = LangUnknown
  except:
    result = LangUnknown

proc toJsLang*(lang: Lang): cstring =
  var langs: array[Lang, cstring] = [
    cstring"c", cstring"cpp", cstring"rust", cstring"nim", cstring"go",
    cstring"pascal", cstring"fortran", cstring"d", cstring"crystal",
    cstring"lean", cstring"julia", cstring"ada",
    cstring"python", cstring"ruby", cstring"ruby",
    cstring"javascript", cstring"lua", cstring"assembler", cstring"noir",
    cstring"rust", cstring"cpp",
    cstring"python",
    cstring"unknown",
    cstring"bash",
    cstring"zsh",
    cstring"solidity",
    cstring"masm",
    cstring"sway",
    cstring"move",
    cstring"polkavm",
    cstring"cairo",
    cstring"circom",
    cstring"leo",
    cstring"tolk",
    cstring"aiken",
    cstring"cadence",
    cstring"solana",
    cstring"elixir",
    cstring"erlang",
    cstring"php"
  ]
  result = langs[lang]

proc toSet(names: seq[cstring]): JsAssoc[cstring, bool] =
  result = JsAssoc[cstring, bool]{}
  for name in names:
    result[name] = true

let SUPPORTED_LANGS* = @[
  LangC, LangCpp, LangRust, LangNim, LangGo,
  LangPascal, LangFortran, LangD, LangCrystal, LangLean, LangAda,
  LangRubyDb, LangNoir, LangRustWasm, LangCppWasm,
  LangSolidity, LangMasm, LangSway, LangMove, LangPolkavm,
  LangCairo, LangCircom, LangLeo, LangTolk, LangAiken, LangCadence,
  LangSolana, LangElixir, LangErlang
]

let RESERVED_NAMES*: array[Lang, JsAssoc[cstring, bool]] = [
  toSet(@[]),  # LangC
  toSet(@[]),  # LangCpp
  toSet(@[]),  # LangRust
  toSet(@[cstring"if", cstring"elif", cstring"else", cstring"when", cstring"case", cstring"of",
          cstring"for", cstring"while", cstring"block", cstring"try", cstring"except", cstring"finally",
          cstring"proc", cstring"func", cstring"method", cstring"iterator", cstring"template", cstring"macro", cstring"converter",
          cstring"var", cstring"let", cstring"const", cstring"type",
          cstring"return", cstring"yield", cstring"discard", cstring"break", cstring"continue",
          cstring"and", cstring"or", cstring"not", cstring"xor", cstring"in", cstring"notin", cstring"is", cstring"isnot",
          cstring"nil", cstring"true", cstring"false", cstring"result"]),  # LangNim
  toSet(@[]),  # LangGo: TODO
  toSet(@[]),  # LangPascal
  toSet(@[]),  # LangFortran
  toSet(@[]),  # LangD
  toSet(@[]),  # LangCrystal
  toSet(@[]),  # LangLean
  toSet(@[]),  # LangJulia
  toSet(@[]),  # LangAda
  toSet(@[]),  # LangPython
  toSet(@[]),  # LangRuby
  toSet(@[]),  # LangRubyDb
  toSet(@[]),  # LangJavascript
  toSet(@[]),  # LangLua
  toSet(@[]),  # LangAsm
  toSet(@[]),  # LangNoir
  toSet(@[]),  # LangRustWasm
  toSet(@[]),  # LangCppWasm
  toSet(@[]),  # LangPythonDb
  toSet(@[]),  # LangUnknown
  toSet(@[]),  # LangBash
  toSet(@[]),  # LangZsh
  toSet(@[]),  # LangSolidity
  toSet(@[]),  # LangMasm
  toSet(@[]),  # LangSway
  toSet(@[]),  # LangMove
  toSet(@[]),  # LangPolkavm
  toSet(@[]),  # LangCairo
  toSet(@[]),  # LangCircom
  toSet(@[]),  # LangLeo
  toSet(@[]),  # LangTolk
  toSet(@[]),  # LangAiken
  toSet(@[]),  # LangCadence
  toSet(@[]),  # LangSolana
  toSet(@[]),  # LangElixir
  toSet(@[]),  # LangErlang
  toSet(@[])   # LangPhp
]

proc getExtension*(lang: Lang): cstring =
  var extensions: array[Lang, string] = [
    "c",      # LangC
    "cpp",    # LangCpp
    "rs",     # LangRust
    "nim",    # LangNim
    "go",     # LangGo
    "pas",    # LangPascal
    "f90",    # LangFortran
    "d",      # LangD
    "cr",     # LangCrystal
    "lean",   # LangLean
    "jl",     # LangJulia
    "adb",    # LangAda
    "py",     # LangPython
    "rb",     # LangRuby
    "rb",     # LangRubyDb
    "js",     # LangJavascript
    "lua",    # LangLua
    "asm",    # LangAsm
    "nr",     # LangNoir
    "rs",     # LangRustWasm
    "cpp",    # LangCppWasm
    "py",     # LangPythonDb
    "",       # LangUnknown
    "sh",     # LangBash
    "zsh",    # LangZsh
    "sol",    # LangSolidity
    "masm",   # LangMasm
    "sw",     # LangSway
    "move",   # LangMove
    "",       # LangPolkavm (folder-based)
    "cairo",  # LangCairo
    "circom", # LangCircom
    "leo",    # LangLeo
    "tolk",   # LangTolk
    "ak",     # LangAiken
    "cdc",    # LangCadence
    "",       # LangSolana (folder-based)
    "ex",     # LangElixir
    "erl",    # LangErlang
    "php"     # LangPhp
  ]
  result = cstring(extensions[lang])

proc fromPath*(path: cstring): Lang =
  # TODO: replace with toLangFromFilename fully?
  # assume file.name.ext
  let tokens = path.split(cstring".")
  echo tokens
  let ext = tokens[tokens.len - 1]
  echo ext
  var extensions = JsAssoc[cstring, Lang]{
    "c": LangC,
    "cpp": LangCpp,
    "h": LangC,
    "hpp": LangCpp,
    "pas": LangPascal,
    "f90": LangFortran,
    "d": LangD,
    "cr": LangCrystal,
    "lean": LangLean,
    "jl": LangJulia,
    "adb": LangAda,
    "rs": LangRust,
    "go": LangGo,
    "py": LangPythonDb,
    "rb": LangRubyDb,
    "js": LangJavascript,
    "lua": LangLua,
    "nim": LangNim,
    "asm": LangAsm,
    "s": LangAsm,
    "nr": LangNoir,
    "sol": LangSolidity,
    "masm": LangMasm,
    "sw": LangSway,
    "move": LangMove,
    "cairo": LangCairo,
    "circom": LangCircom,
    "leo": LangLeo,
    "tolk": LangTolk,
    "ak": LangAiken,
    "cdc": LangCadence,
    "ex": LangElixir,
    "exs": LangElixir,
    "erl": LangErlang,
    "hrl": LangErlang,
    "php": LangPhp,
  };
  if not extensions.hasKey(ext):
    LangUnknown
  else:
    extensions[ext]
