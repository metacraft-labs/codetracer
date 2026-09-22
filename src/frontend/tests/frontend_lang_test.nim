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

  test "no two members share a toCLang name any more":
    ## This case used to be "LangCppWasm is named `cpp`, the same language as
    ## LangCpp" and asserted the fold LRS-3 landed: two members, one name.
    ## LRS-5's second deletion round deleted `LangCppWasm` / `LangRustWasm`,
    ## so the fold has nothing left to fold and the stronger property holds --
    ## `toCLang` is INJECTIVE over `Lang`, which is why the picker below is
    ## the supported list verbatim.
    check toCLang(LangCpp) == "cpp"
    check toCLang(LangRust) == "rust"
    var names: seq[string] = @[]
    for lang in Lang:
      check toCLang(lang) notin names
      names.add(toCLang(lang))

  test "the name folds exactly the conflated pairs, and nothing else":
    ## Two members share a `toCLang` name if and only if `axesOfLang` gives
    ## them the same source language -- the name is per LANGUAGE.  Since
    ## LRS-5's second deletion round both sides of that biconditional are
    ## EMPTY: no two members share a language (the bijection) and therefore
    ## none share a name.  `LangSolana` and `LangPolkavm`, which used to be
    ## the one place the two relations differed (both `slUnknown`, different
    ## names), are gone with the round.
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
    # 36 after LRS-3; 32 since LRS-5's second deletion round removed four
    # SUPPORTED members (the wasm pair and the platform pair).  The native
    # half of this count lives in `src/tests/cli/target_axes_test.nim`, which
    # says why nothing became unrecordable.
    check SUPPORTED_LANGS.len == 32

  test "Python and JavaScript are in: their recorders exist":
    check LangPythonDb in SUPPORTED_LANGS
    check LangJavascript in SUPPORTED_LANGS

  test "the sentinel and the declared-unsupported members are out":
    # (The retired backends `LangPython` / `LangRuby` were out too, until
    # LRS-4 deleted them; there is nothing left to exclude.)
    check LangUnknown notin SUPPORTED_LANGS
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
    check LANG_PICKER_LANGS.len == SUPPORTED_LANGS.len

  test "the fold is a no-op now, and every supported member is offered":
    ## It used to be "the plain member represents its pair; the wasm siblings
    ## are folded" and asserted `LangRustWasm notin LANG_PICKER_LANGS`.  With
    ## the wasm pair deleted there is no pair to represent, so the property is
    ## stated as what it has become: the picker IS the supported list.
    for lang in SUPPORTED_LANGS:
      check lang in LANG_PICKER_LANGS
    check LangRust in LANG_PICKER_LANGS
    check LangCpp in LANG_PICKER_LANGS
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

suite "the input spellings are one table (LRS-3, the asm unification), on the JS side":
  ## `src/frontend/lang.nim` used to carry its own `toLang` (a `JsAssoc` of
  ## extensions plus a few names) and a third table in `fromPath`.  Both now
  ## resolve through `langSpellings` in `common_lang.nim`, and that CHANGED
  ## what the front end detects; the native side's account is
  ## `src/tests/cli/lang_spellings_test.nim`.

  test "the front end gained `miden` for LangMasm (the core always had it)":
    check toLang(cstring"miden") == LangMasm
    check toLang(cstring"masm") == LangMasm
    check fromPath(cstring"prog.masm") == LangMasm

  test "`asm` and `s` both name LangAsm, as they always did here":
    check toLang(cstring"asm") == LangAsm
    check toLang(cstring"s") == LangAsm
    check fromPath(cstring"boot.s") == LangAsm
    check fromPath(cstring"boot.asm") == LangAsm
    check toLangFromFilename(cstring"boot.s") == LangAsm

  test "fromPath is toLangFromFilename: one answer per path, and no third table":
    for path in [cstring"a/b.c", cstring"x.rs", cstring"x.nims", cstring"dir.v2/Makefile",
                 cstring"noext", cstring"x.php", cstring"x.gd", cstring"x.S"]:
      check fromPath(path) == toLangFromFilename(path)
    check fromPath(cstring"x.nims") == LangNim       # the core's row, gained
    check fromPath(cstring"x.gd") == LangGdScript    # the core's row, gained
    check fromPath(cstring"dir.v2/Makefile") == LangUnknown
    check fromPath(cstring"noext") == LangUnknown

  test "the front end gained the core's `--lang` names and is case-insensitive":
    check toLang(cstring"rust") == LangRust
    check toLang(cstring"nims") == LangNim
    check toLang(cstring"gdscript") == LangGdScript
    # A deprecated alias of the LANGUAGE since LRS-5's second deletion round;
    # the wasm target rides on the artefact, not on the `--lang` spelling.
    check toLang(cstring"cpp-wasm") == LangCpp
    check toLang(cstring"rust-wasm") == LangRust
    check toLang(cstring"ruby(db)") == LangRubyDb
    check toLang(cstring"RS") == LangRust
    check toLang(cstring"Asm") == LangAsm

  test "the rows the front end always had are unchanged":
    check toLang(cstring"h") == LangC
    check toLang(cstring"hpp") == LangCpp
    check toLang(cstring"js") == LangJavascript
    check toLang(cstring"py") == LangPythonDb
    check toLang(cstring"python") == LangPythonDb
    check toLang(cstring"rb") == LangRubyDb
    check toLang(cstring"ruby") == LangRubyDb   # the working recorder since LRS-4 (Q6)
    check toLang(cstring"nope") == LangUnknown
    check toLang(cstring"") == LangUnknown

  test "the table is the same value on both backends: every spelling resolves to its member":
    for (spelling, lang) in LANG_SPELLINGS:
      check toLang(cstring(spelling)) == lang
      check toLang(spelling) == lang
    # 64 at LRS-3, unchanged by LRS-4 (a row MOVED); 62 since LRS-5's second
    # deletion round: six rows left with the four members and four came back
    # on `LangRust` / `LangCpp` as deprecated aliases, while `polkavm` and
    # `solana` were removed outright.  `lang_spellings_test.nim` is where the
    # decision is written down.
    check LANG_SPELLINGS.len == 62

suite "the renderer decodes `lang` by the enum's names on the JS backend (LRS-4)":
  ## `src/frontend/trace_metadata.nim` used to rewrite `ct trace-metadata`'s
  ## `"lang": "LangPythonDb"` into the JS-runtime ordinal through a hand-written
  ## `var LANG = {…}` map, pinned entry for entry by
  ## `lang_enum_contract_test.nim`.  LRS-4 deleted the map: the renderer calls
  ## `decodeLangName`, which is `parseEnum[Lang]` over the live enum.  This is
  ## the JS-backend proof that the mechanism works where the renderer runs --
  ## `trace_metadata.nim` itself is Electron-only and no lane can import it.

  test "every member round-trips through its own name, on the JS backend":
    for lang in Lang:
      let decoded = decodeLangName($lang)
      check decoded.lang == lang
      check decoded.retiredName == ""
      # And the value the renderer stores IS the JS-runtime ordinal, which is
      # what `cast[Trace]` reinterprets: assigning it and reading it back as
      # an int agrees with `ord`.
      check ord(decoded.lang) == ord(lang)

  test "the sentinel is ordinal 0 on this backend too":
    check ord(LangUnknown) == 0
    check Lang(0) == LangUnknown
    var zero: Lang
    check zero == LangUnknown

  test "a retired name is the sentinel with the name kept, never a throw":
    # The two members LRS-4 deleted; a `trace_index.db` written before it
    # can still hold either.
    for name in ["LangPython", "LangRuby"]:
      let decoded = decodeLangName(name)
      checkpoint(name)
      check decoded.lang == LangUnknown
      check decoded.retiredName == name
    check decodeLangName("LangUnknown") == (lang: LangUnknown, retiredName: "")
    check decodeLangName("") == (lang: LangUnknown, retiredName: "")
    check decodeLangName("LangNotAThing") ==
      (lang: LangUnknown, retiredName: "LangNotAThing")

  test "Ruby and Python display without the historical (db) suffix":
    check toName(LangRubyDb) == "Ruby"
    check toName(LangPythonDb) == "Python"
