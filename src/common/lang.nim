include common_lang
import strutils
import tables

proc toLang*(lang: string): Lang =
  var langs = {
    "c": LangC,
    "cpp": LangCpp,
    "rust": LangRust,
    "rs": LangRust,
    "nim": LangNim,
    "nims": LangNim,
    "go": LangGo,
    "pascal": LangPascal,
    "fortran": LangFortran,
    "f90": LangFortran,
    "d": LangD,
    "dlang": LangD,
    "crystal": LangCrystal,
    "cr": LangCrystal,
    "lean": LangLean,
    "julia": LangJulia,
    "jl": LangJulia,
    "ada": LangAda,
    "adb": LangAda,
    "py": LangPythonDb,
    "python": LangPythonDb,
    "rb": LangRubyDb, # default for ruby for now
    "ruby": LangRuby,
    "ruby(db)": LangRubyDb,
    "javascript": LangJavascript,
    "lua": LangLua,
    "asm": LangAsm,
    "nr": LangNoir,
    "noir": LangNoir,
    "rust-wasm": LangRustWasm,
    "rustwasm": LangRustWasm,
    "cpp-wasm": LangCppWasm,
    "cppwasm": LangCppWasm,
    "sol": LangSolidity,
    "solidity": LangSolidity,
    "masm": LangMasm,
    "miden": LangMasm,
    "sw": LangSway,
    "sway": LangSway,
    "move": LangMove,
    "polkavm": LangPolkavm,
    "cairo": LangCairo,
    "circom": LangCircom,
    "leo": LangLeo,
    "tolk": LangTolk,
    "ak": LangAiken,
    "aiken": LangAiken,
    "cdc": LangCadence,
    "cadence": LangCadence,
    "solana": LangSolana,
    "ex": LangElixir,
    "exs": LangElixir,
    "elixir": LangElixir,
    "erl": LangErlang,
    "hrl": LangErlang,
    "erlang": LangErlang,
  }.toTable()
  if langs.hasKey(lang.toLowerAscii):
    result = langs[lang.toLowerAscii]
  else:
    result = LangUnknown

proc toLang*(lang: cstring): Lang =
  result = toLang($lang)

let SUPPORTED_LANGS* = @[
  LangC, LangCpp, LangRust, LangNim, LangGo,
  LangPascal, LangFortran, LangD, LangCrystal, LangLean, LangAda,
  LangRubyDb, LangNoir,
  LangSolidity, LangMasm, LangSway, LangMove, LangPolkavm,
  LangCairo, LangCircom, LangLeo, LangTolk, LangAiken, LangCadence,
  LangSolana, LangElixir, LangErlang
]

proc getExtension*(lang: Lang): string =
  let extensions: array[Lang, string] = [
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
    "erl"     # LangErlang
  ]
  result = extensions[lang]

proc toLangFromFilename*(location: string): Lang =
  try:
    let extensionWithDot = location.splitFile()[2]
    if extensionWithDot.len > 0:
      let extension = extensionWithDot[1..^1]
      # echo location, " ", extensionWithDot
      result = toLang(extension)
    else:
      result = LangUnknown
  except:
    result = LangUnknown
