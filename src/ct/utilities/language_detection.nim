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
  elif fileExists(folder / "Cargo.toml"):
    LangRust
  elif fileExists(folder / "lakefile.lean"):
    LangLean
  elif fileExists(folder / "shard.yml"):
    LangCrystal
  else:
    # TODO: rust/ruby/others?
    LangUnknown


const LANGS = {
  "c": LangC,
  "cpp": LangCpp,
  "rs": LangRust,
  "nim": LangNim,
  "go": LangGo,
  "pas": LangPascal,
  "f90": LangFortran,
  "d": LangD,
  "cr": LangCrystal,
  "lean": LangLean,
  "adb": LangAda,
  "py": LangPythonDb,
  "rb": LangRubyDb, # default for ruby for now
  "nr": LangNoir,
  "small": LangSmall,
  "wasm": LangRustWasm, # TODO: can be Cpp or other as well, maybe pass
    # explicitly or check trace/other debug info?
}.toTable()

const WASM_LANGS = {
  "rs": LangRustWasm,
  "cpp": LangCppWasm,
  "c": LangCppWasm,
}.toTable()

proc detectLangFromPath*(path: string, isWasm: bool): Lang =
  let filename = path.extractFilename
  let tokens = rsplit(filename[1..^1], ".", 1)
  if tokens.len > 1:
    let extension = tokens[1].toLowerAscii()

    if isWasm and WASM_LANGS.hasKey(extension):
      return WASM_LANGS[extension]

    if LANGS.hasKey(extension):
      result = LANGS[extension] # TODO detectLangFromTrace(traceId) ?
      if result != LangUnknown:
        return result
  else:
    return LangUnknown


proc detectLang*(program: string, lang: Lang, isWasm: bool = false): Lang =
  # TODO: under a debug print flag?
  # echo "detectLang ", program, " ", lang, " isWasm: ", isWasm
  if lang != LangUnknown:
    return lang

  result = LangUnknown # by default

  var possiblyExpandedPath = ""
  try:
    possiblyExpandedPath = expandFileName(program)
  except CatchableError:
    possiblyExpandedPath = program

  let filename = possiblyExpandedPath.extractFilename
  let isFolder = dirExists(program)

  if isFolder:
    result = detectFolderLang(program)
    if result != LangUnknown:
      return result

  if not isFolder and "." in filename:
    result = detectLangFromPath(filename, isWasm)
    if result != LangUnknown:
      return result

  # try with the rr-backend
  let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
  if ctConfig.rrBackend.enabled:
    let rawLang = execProcess(
      ctConfig.rrBackend.path,
      args = @["debuginfo", "lang", program],
      options={}).strip
    result = toLang(rawLang)

  # echo "detectLang result ", result
