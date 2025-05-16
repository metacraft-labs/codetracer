import
  std/[os, osproc, strutils, tables],
  ../../common/[lang, config]

# detect the lang of the source for a binary
#   based on folder/filename/files and if not possible on symbol patterns
#   in the binary
#   for scripting languages on the extension
#   for folders, we search for now for a special file
#   like `Nargo.toml`
#   just analyzing debug info might be best
#   TODO: a project can have sources in multiple languages
#   so the assumption it has a single one is not always valid
#   but for now are not reforming that yet
proc detectFolderLang(folder: string): Lang =
  if fileExists(folder / "Nargo.toml"):
    LangNoir
  else:
    # TODO: rust/ruby/others?
    LangUnknown


const LANGS = {
  "c": LangC,
  "cpp": LangCpp,
  "rs": LangRust,
  "nim": LangNim,
  "go": LangGo,
  "py": LangPython,
  "rb": LangRubyDb, # default for ruby for now
  "nr": LangNoir,
  "small": LangSmall,
  "wasm": LangRustWasm,
}.toTable()

const WASM_LANGS = {
  "rs": LangRustWasm,
  "cpp": LangCppWasm,
  "c": LangCppWasm,
}.toTable()

proc detectLang*(program: string, lang: Lang, isWasm: bool = false): Lang =
  echo "detectLang ", program
  var possiblyExpandedPath = ""
  try:
    possiblyExpandedPath = expandFileName(program)
  except CatchableError:
    possiblyExpandedPath = program

  if lang == LangUnknown:
    if "." in possiblyExpandedPath:
      echo "in"
      let extension = rsplit(possiblyExpandedPath[1..^1], ".", 1)[1].toLowerAscii()
      if not isWasm:
        if LANGS.hasKey(extension):
          result = LANGS[extension] # TODO detectLangFromTrace(traceId)
      else:
        if WASM_LANGS.hasKey(extension):
          result = WASM_LANGS[extension]        
    elif dirExists(program):
      result = detectFolderLang(program)
    else:
      let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
      if ctConfig.rrBackend.enabled:
        let rawLang = execProcess(
          ctConfig.rrBackend.debuginfoToolPath,
          args = @["lang", program],
          options={}).strip
        result = toLang(rawLang)
      else:
        result = LangUnknown
  else:
    result = lang
  echo "result ", result
