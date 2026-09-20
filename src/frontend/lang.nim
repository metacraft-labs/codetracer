include ../common/common_lang
import std/jsffi

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
  ## The language of the file at `path`, by extension -- what the editor
  ## opens a tab as.  It used to carry its own 36-row extension table, the
  ## third copy of the input spellings (see `langSpellings` in
  ## `common_lang.nim`), and two `echo`s that printed every path opened; it is
  ## now `toLangFromFilename`, which resolves through the one shared table.
  toLangFromFilename(path)
