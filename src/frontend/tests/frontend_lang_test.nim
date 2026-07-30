import
  std/unittest,
  ../lang

suite "frontend language mappings":
  test "all language enum values have JS names and extensions":
    for lang in Lang:
      check ($toJsLang(lang)).len > 0
      discard getExtension(lang)
      discard RESERVED_NAMES[lang]

  test "PHP is exposed consistently by the frontend mappings":
    check toLang(cstring"php") == LangPhp
    check toLangFromFilename(cstring"example.php") == LangPhp
    check fromPath(cstring"example.php") == LangPhp
    check $toJsLang(LangPhp) == "php"
    check $getExtension(LangPhp) == "php"
    check LangPhp in SUPPORTED_LANGS
