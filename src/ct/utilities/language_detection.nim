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
}.toTable()

proc detectFileLang*(program: string): Lang =
  if "." in program:
    let extension = rsplit(program[1..^1], ".", 1)[1].toLowerAscii()
    if LANGS.hasKey(extension):
      return LANGS[extension]
  return LangUnknown

proc detectLang*(program: string, lang: Lang): Lang =
  echo "detectLang ", program

  if lang == LangUnknown:
    let absProgram = expandFileName(program)
    if "." in program:
      let extension = rsplit(absProgram[1..^1], ".", 1)[1].toLowerAscii()
      if LANGS.hasKey(extension):
        result = LANGS[extension]
      elif extension == "wasm":
        result = LangRustWasm # TODO detectLangFromTrace(traceId)
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
