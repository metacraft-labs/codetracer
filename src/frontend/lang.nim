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
    py: LangPythonDb,
    python: LangPythonDb,
    rb: LangRubyDb, # default for ruby for now
    ruby: LangRuby,
    js: LangJavascript,
    `asm`: LangAsm,
    s: LangAsm,
    lua: LangLua,
    nr: LangNoir,
    small: LangSmall,
    noir: LangNoir,
    d: LangC, # TODO
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
    cstring"pascal", cstring"python", cstring"ruby", cstring"ruby",
    cstring"javascript", cstring"lua", cstring"assembler", cstring"noir",
    cstring"rust", cstring"cpp",
    cstring"small",
    cstring"python",
    cstring"unknown"
  ]
  result = langs[lang]

proc toSet(names: seq[cstring]): JsAssoc[cstring, bool] =
  result = JsAssoc[cstring, bool]{}
  for name in names:
    result[name] = true

let SUPPORTED_LANGS* = @[LangC, LangCpp, LangRust, LangNim, LangGo, LangRubyDb, LangNoir, LangRustWasm, LangCppWasm, LangSmall]

let RESERVED_NAMES*: array[Lang, JsAssoc[cstring, bool]] = [
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[cstring"for", cstring"if", cstring"while", cstring"proc"]),
  toSet(@[]),
  toSet(@[]), # LangGo: TODO
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[]),
  toSet(@[])
]

proc getExtension*(lang: Lang): cstring =
  var extensions: array[Lang, string] = [
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
    "py",
    ""
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
    "small": LangSmall,
  };
  if not extensions.hasKey(ext):
    LangUnknown
  else:
    extensions[ext]
