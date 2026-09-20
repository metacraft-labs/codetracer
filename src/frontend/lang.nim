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

proc langPickerOptions*(): string =
  ## The `<option>` list of the language dropdown, rendered from
  ## `LANG_PICKER_LANGS` (`common_lang.nim`) and nothing else -- one option per
  ## distinct `toCLang` name, labelled by `toName`.  It lives here, in a leaf
  ## the `test-frontend-js` lane can import, rather than in `renderer.nim`
  ## where `langs` used to build it inline: no runnable lane can import the
  ## renderer (`nim js` on it pulls the Karax/Monaco tree), so the rendering
  ## is asserted on THIS proc and the renderer is a one-line caller.
  ##
  ## `SUPPORTED_LANGS` is deliberately not iterated directly: it holds both
  ## members of each conflated pair, and `toCLang` folds a pair onto one
  ## name, which is how the old loop emitted `<option value='rust'>` twice.
  result = ""
  for lang in LANG_PICKER_LANGS:
    result.add("<option value='" & toCLang(lang) & "'>" & toName(lang) & "</option>")

proc toSet(names: seq[cstring]): JsAssoc[cstring, bool] =
  result = JsAssoc[cstring, bool]{}
  for name in names:
    result[name] = true

let RESERVED_NAMES*: array[Lang, JsAssoc[cstring, bool]] = block:
  ## Built at module init from `reservedNames` in `common_lang.nim`, which is
  ## the exhaustive `case` holding the data.  The container is assembled here
  ## because `JsAssoc` is a JS-backend type and the shared floor must not
  ## mention one; this is the boundary that wraps `string` into `cstring`.
  ## Existing `RESERVED_NAMES[lang]` call sites are unaffected.
  var table: array[Lang, JsAssoc[cstring, bool]]
  for lang in Lang:
    var names: seq[cstring] = @[]
    for name in reservedNames(lang):
      names.add(cstring(name))
    table[lang] = toSet(names)
  table

proc getExtension*(lang: Lang): cstring =
  ## The JS front end's spelling: this is the boundary that wraps into a
  ## ``cstring``.  The table is the exhaustive ``case`` ``getExtensionName`` in
  ## ``common_lang.nim``, shared with the native side so the two cannot drift.
  cstring(getExtensionName(lang))

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
