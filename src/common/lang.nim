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
    "small": LangSmall,
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
  LangRubyDb, LangNoir, LangSmall
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
    "small",  # LangSmall
    "py",     # LangPythonDb
    ""        # LangUnknown
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
