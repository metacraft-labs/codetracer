## Module contains types and procedures for handling the various programming languages
## codetracer might support

# backend agnostic code, part of the lang module, should not be imported directly,
# use common/lang or frontend/lang instead.

import os

type
  Lang* = enum ## Identifies a programming language implementation
    LangC, LangCpp, LangRust, LangNim, LangGo,
    LangPascal, LangPython, LangRuby, LangRubyDb, LangJavascript,
    LangLua, LangAsm, LangNoir,
    LangRustWasm, LangCppWasm, # wasm
    LangSmall, LangPythonDb, LangUnknown

var CURRENT_LANG*: Lang = LangUnknown ## The current lang in the codetraces session

proc isVMLang*(lang: Lang): bool =
  ## return true if programming language implementation runs in a virtual machine
  false # lang in {LangRuby, LangPython, LangPythonDb, LangLua, LangJavascript, LangUnknown}

var IS_DB_BASED*: array[Lang, bool] = [
  false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false
]

IS_DB_BASED[LangRubyDb] = true
IS_DB_BASED[LangNoir] = true
IS_DB_BASED[LangSmall] = true
IS_DB_BASED[LangRustWasm] = true
IS_DB_BASED[LangCppWasm] = true
IS_DB_BASED[LangPythonDb] = true

proc isDbBased*(lang: Lang): bool =
  ## return true if `lang` uses the db backend
  IS_DB_BASED[lang]

proc toCLang*(lang: Lang): string =
  ## convert Lang_ to string
  let langs: array[Lang, string] = ["c", "cpp", "rust", "nim", "go", "pascal", "python", "ruby", "ruby", "javascript", "lua", "assembly", "noir", "rust", "c++", "small", "python", "uknown"]
  result = langs[lang]

proc toName*(lang: Lang): string =
  ## convert Lang_ to string
  let langs: array[Lang, string] = [
       "C", "C++", "Rust", "Nim", "Go",
       "Pascal", "Python", "Ruby", "Ruby(db)", "Javascript", "Lua", "assembly language", "Noir",
       "Rust(wasm)", "C++(wasm)",
       "Small", "Python(db)", "unknown"
  ]
  result = langs[lang]

proc toLang*(lang: string): Lang
proc toLang*(lang: cstring): Lang

proc isDbBasedForExtension*(extension: string): bool =
  ## return true if extention is for a language that uses the db backend
  let lang = toLang(extension)
  isDbBased(lang)
