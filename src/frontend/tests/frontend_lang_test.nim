import
  std/[unittest, strutils],
  ../lang

suite "frontend language mappings":
  test "all language enum values have names and extensions":
    for lang in Lang:
      check toCLang(lang).len > 0
      discard getExtension(lang)
      discard RESERVED_NAMES[lang]

  test "PHP is exposed consistently by the frontend mappings":
    check toLang(cstring"php") == LangPhp
    check toLangFromFilename(cstring"example.php") == LangPhp
    check fromPath(cstring"example.php") == LangPhp
    check toCLang(LangPhp) == "php"
    check $getExtension(LangPhp) == "php"
    check LangPhp in SUPPORTED_LANGS

suite "toCLang is the one name table (LRS-3, the toJsLang merge)":
  ## `src/frontend/lang.nim` used to carry `toJsLang`, a second 40-slot copy
  ## of `toCLang` that disagreed on two members.  Both disagreements are now
  ## decided in `common_lang.nim` and pinned here from the JS backend, the
  ## side that used to hold the other answer.

  test "Q4b: LangAsm is `assembly`, the spelling the Monaco and LSP sites already receive":
    check toCLang(LangAsm) == "assembly"
    check toCLang(LangAsm) != "assembler"

  test "LangCppWasm is named `cpp`, the same language as LangCpp":
    check toCLang(LangCppWasm) == "cpp"
    check toCLang(LangCppWasm) == toCLang(LangCpp)
    check toCLang(LangRustWasm) == toCLang(LangRust)

  test "the name folds exactly the conflated pairs, and nothing else":
    ## Two members share a `toCLang` name if and only if `axesOfLang` gives
    ## them the same source language -- the name is per LANGUAGE.  `LangSolana`
    ## and `LangPolkavm` both decompose to `slUnknown` with `LangUnknown` but
    ## keep their own names, which is the one place the two relations differ,
    ## so it is stated rather than folded into the rule.
    for a in Lang:
      for b in Lang:
        if a == b: continue
        let sameName = toCLang(a) == toCLang(b)
        let sameLanguage = sourceLanguageOf(a) == sourceLanguageOf(b) and
                           sourceLanguageOf(a) != slUnknown
        check sameName == sameLanguage

suite "SUPPORTED_LANGS is derived, and the dropdown renders exactly LANG_PICKER_LANGS":
  ## The frontend half of the `SUPPORTED_LANGS` unification.  The list is
  ## computed at compile time from `isSupportedLang`; the native half
  ## (`src/tests/cli/target_axes_test.nim`) pins that predicate against
  ## `recorderToolFor` member for member.  What THIS side can see is the list
  ## itself and the HTML the renderer builds from it.

  test "the derived list is `isSupportedLang` over the enum, in declaration order":
    var expected: seq[Lang] = @[]
    for lang in Lang:
      if isSupportedLang(lang):
        expected.add(lang)
    check SUPPORTED_LANGS == expected
    check SUPPORTED_LANGS.len == 36

  test "Python and JavaScript are in: their recorders exist":
    check LangPythonDb in SUPPORTED_LANGS
    check LangJavascript in SUPPORTED_LANGS

  test "the sentinel, the retired backends and the declared-unsupported members are out":
    check LangUnknown notin SUPPORTED_LANGS
    check LangPython notin SUPPORTED_LANGS
    check LangRuby notin SUPPORTED_LANGS
    for lang in DeclaredUnsupportedLangs:
      check lang notin SUPPORTED_LANGS
    check DeclaredUnsupportedLangs == {LangLua, LangGdScript}

  test "the picker is a fold of the supported list: every name once, no name twice":
    var names: seq[string] = @[]
    for lang in LANG_PICKER_LANGS:
      check lang in SUPPORTED_LANGS
      check toCLang(lang) notin names
      names.add(toCLang(lang))
    for lang in SUPPORTED_LANGS:
      check toCLang(lang) in names
    check LANG_PICKER_LANGS.len == 34

  test "the plain member represents its pair; the wasm siblings are folded":
    check LangRust in LANG_PICKER_LANGS
    check LangRustWasm notin LANG_PICKER_LANGS
    check LangCpp in LANG_PICKER_LANGS
    check LangCppWasm notin LANG_PICKER_LANGS
    check LangRubyDb in LANG_PICKER_LANGS
    check LangPythonDb in LANG_PICKER_LANGS

  test "the rendered options are exactly the picker, and their values are unique":
    let html = langPickerOptions()
    var expected = ""
    var values: seq[string] = @[]
    for lang in LANG_PICKER_LANGS:
      expected.add("<option value='" & toCLang(lang) & "'>" & toName(lang) & "</option>")
      values.add(toCLang(lang))
    check html == expected
    # Independently of the loop above: parse the values back out of the HTML
    # and assert the property the design names -- no `value` twice.
    var seen: seq[string] = @[]
    for piece in html.split("<option value='"):
      if piece.len == 0: continue
      let value = piece[0 ..< piece.find("'")]
      check value notin seen
      seen.add(value)
    check seen == values
    check html.count("value='rust'") == 1
    check html.count("value='cpp'") == 1
    check html.count("value='python'") == 1
    check html.count("value='javascript'") == 1
    check "value='unknown'" notin html
