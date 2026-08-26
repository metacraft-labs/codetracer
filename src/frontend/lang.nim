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
  ## Exhaustive ``case`` rather than a positional ``array[Lang, cstring]``.
  ##
  ## Deliberately NOT folded into ``toCLang``: the two disagree on two members
  ## (``LangAsm`` is ``assembler`` here and ``assembly`` there, ``LangCppWasm``
  ## is ``cpp`` here and ``c++`` there), so they are two mappings that happen to
  ## agree 38 times, not one mapping written twice.
  case lang
  of LangC: cstring"c"
  of LangCpp: cstring"cpp"
  of LangRust: cstring"rust"
  of LangNim: cstring"nim"
  of LangGo: cstring"go"
  of LangPascal: cstring"pascal"
  of LangFortran: cstring"fortran"
  of LangD: cstring"d"
  of LangCrystal: cstring"crystal"
  of LangLean: cstring"lean"
  of LangJulia: cstring"julia"
  of LangAda: cstring"ada"
  of LangPython: cstring"python"
  of LangRuby: cstring"ruby"
  of LangRubyDb: cstring"ruby"
  of LangJavascript: cstring"javascript"
  of LangLua: cstring"lua"
  of LangAsm: cstring"assembler"
  of LangNoir: cstring"noir"
  of LangRustWasm: cstring"rust"
  of LangCppWasm: cstring"cpp"
  of LangPythonDb: cstring"python"
  of LangUnknown: cstring"unknown"
  of LangBash: cstring"bash"
  of LangZsh: cstring"zsh"
  of LangSolidity: cstring"solidity"
  of LangMasm: cstring"masm"
  of LangSway: cstring"sway"
  of LangMove: cstring"move"
  of LangPolkavm: cstring"polkavm"
  of LangCairo: cstring"cairo"
  of LangCircom: cstring"circom"
  of LangLeo: cstring"leo"
  of LangTolk: cstring"tolk"
  of LangAiken: cstring"aiken"
  of LangCadence: cstring"cadence"
  of LangSolana: cstring"solana"
  of LangElixir: cstring"elixir"
  of LangErlang: cstring"erlang"
  of LangPhp: cstring"php"
  of LangGdScript: cstring"gdscript"

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
  LangSolana, LangElixir, LangErlang, LangPhp
]

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
