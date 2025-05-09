include common_lang
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
    "py": LangPython,
    "python": LangPython,
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

let SUPPORTED_LANGS* = @[LangC, LangCpp, LangRust, LangNim, LangGo, LangRubyDb, LangNoir, LangSmall]

proc getExtension*(lang: Lang): string =
  let extensions: array[Lang, string] = [
    "c",
    "cpp",
    "rs",
    "nim",
    "go",
    "pas",
    "py",
    "rb",
    "rb",
    "js",
    "lua",
    "asm",
    "nr",
    "rs",
    "cpp",
    "small",
    ""
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
