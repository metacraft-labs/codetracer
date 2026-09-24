## lang_tables_reachability_test.nim
##
## **The per-language tables are reachable from a native-backend Nim program,
## without `std/jsffi`.**  LRS-6's first deliverable, stated as a test the
## `just test-cli-record` lane runs rather than as a one-off compile.
##
## ## Why this is its own suite
##
## The planned Nim TUI on `isonim-tui` is a native (C backend) front end.  It
## needs the same per-language data the Electron renderer has: the bracket
## vocabulary values are spelled with, the canonical extension, the reserved
## names and flow keywords, the input spellings `--lang` accepts, the
## supported/picker lists, the persisted slug and the wire name.  After LRS-3
## that data is a set of exhaustive `case` functions in
## `src/common/common_lang.nim`, which is `include`-d by BOTH
## `src/common/lang.nim` (native) and `src/frontend/lang.nim` (JS) -- so the
## shared home already exists, and the question is whether it stays reachable
## from the native side.
##
## LRS-2 proved the same property for the four AXIS modules
## (`target_axes.nim`, `target_assessment.nim`) in `target_axes_test.nim`, with
## a mutation showing an `import std/jsffi` breaks the native build.  That did
## not cover this file set.  Other native suites do happen to import
## `common/lang` (`target_axes_test.nim`, `lang_enum_contract_test.nim`), but
## each of them also imports `src/ct` modules, and none states the property.
## This one imports ONLY the shared floor -- the three modules a native front
## end would import -- so a dependency that crept into the floor and happened
## to be satisfied by a `src/ct` import elsewhere would still break here.
##
## ## What it asserts
##
## 1. *Reachability, by compiling.*  This file is built with `nim c`.  An
##    `import std/jsffi` in `common_lang.nim` fails the build outright ("Module
##    jsFFI is designed to be used with the JavaScript backend") -- that is the
##    milestone's mutation, and its evidence is in the tracker.
## 2. *Use, by value.*  Every exported table is called over every `Lang`
##    member (or every `SourceLanguage` member for `storageSlug`) and checked
##    against a property the table exists to have, and against the other
##    tables it must agree with.  Calling a function and discarding the
##    result would prove only that it links.
## 3. *No JS vocabulary in the floor's code lines.*  A native compile cannot
##    see a JS-only dependency hidden behind `when defined(js)`, and the floor
##    must not mention a JS type at all: `src/frontend/lang.nim` is where
##    `string` is wrapped into `JsAssoc` / `cstring` containers, by design.
##    So the code lines (comments excluded -- the prose explains the
##    boundary and names those types) of the included files are scanned for
##    `jsffi`, `JsAssoc`, `JsObject`, `importjs`, `kdom` and `std/dom`.
##
## ## The one table that is not in `common_lang.nim`
##
## `tokenTextsFor` (the bracket vocabulary) is in
## `src/common/common_types/language_features/tokens.nim`, because its result
## type `TokenText` is declared there; that file is `include`-d by
## `src/common/common_types.nim`, so a native front end reaches it through
## `common/types`, not `common/lang`.  It is covered here all the same, and
## `tokens.nim` is in the scanned set.
##
## Nothing here skips: a missing file is a hard failure with a named
## diagnostic.

import std/[os, sets, strutils, unittest]
import ../../common/lang          # includes common_lang.nim: the tables
import ../../common/target_axes   # storageSlug, token, SourceLanguage
import ../../common/types         # tokenTextsFor / TOKEN_TEXTS (tokens.nim)

when defined(js):
  {.error: "this suite is the NATIVE half of the placement property; " &
    "the JS half is src/frontend/tests/frontend_lang_test.nim".}

const
  ThisFile = currentSourcePath()
  RepoRoot = ThisFile.parentDir.parentDir.parentDir.parentDir
    ## src/tests/cli/<this> -> src/tests/cli -> src/tests -> src -> <repo>
  FloorFiles = [
    RepoRoot / "src" / "common" / "common_lang.nim",
    RepoRoot / "src" / "common" / "lang.nim",
    RepoRoot / "src" / "common" / "target_axes.nim",
    RepoRoot / "src" / "common" / "common_types" / "language_features" /
      "tokens.nim",
  ]
    ## The files a native front end compiles to reach the tables: the
    ## included table file, the native wrapper that includes it, the axis
    ## module it imports, and the bracket-vocabulary file.
  JsOnlyVocabulary = ["jsffi", "JsAssoc", "JsObject", "importjs", "kdom",
                      "std/dom"]
  UnspelledLangs = {LangUnknown, LangBash, LangZsh}
    ## The members `langSpellings` deliberately gives NO input spelling, as
    ## its doc comment in `common_lang.nim` records: the sentinel, and the two
    ## shells, which `ct record` reaches through `LANGS`
    ## (`src/ct/utilities/language_detection.nim`) instead -- "the gap is
    ## recorded, not closed".  So `toLang("sh")` is `LangUnknown` although
    ## `getExtensionName(LangBash)` is `"sh"`.  Found by this suite's first
    ## run; asserted as an exact set below so it cannot grow silently.

proc codeLinesOnly(source: string): seq[string] =
  ## The lines of `source` that are code: whole-line comments (`#`, `##`)
  ## dropped, and a trailing `# …` comment cut off.  Naive about `#` inside a
  ## string literal, which none of the floor files has on a line that matters;
  ## if one ever does, the cut makes the scan see LESS, never report a false
  ## hit.
  for line in source.splitLines():
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    let hash = line.find('#')
    result.add(if hash >= 0: line[0 ..< hash] else: line)

suite "the language tables are reachable from a native build (LRS-6)":

  test "the floor's code lines name no JS-only module or type":
    for path in FloorFiles:
      checkpoint("floor file: " & path)
      check fileExists(path)
      if not fileExists(path):
        continue
      let lines = codeLinesOnly(readFile(path))
      # Anti-vacuity: a file reduced to nothing by the comment filter would
      # pass any scan.
      check lines.len > 10
      for line in lines:
        for word in JsOnlyVocabulary:
          if word in line:
            checkpoint("`" & word & "` in a code line of " & path & ": " &
                       line.strip())
          check word notin line

  test "the per-member display tables are total and non-empty":
    for lang in Lang:
      checkpoint($lang)
      check toCLang(lang).len > 0
      check toName(lang).len > 0
      check langWireName(lang).len > 0

  test "getExtensionName: the sentinel alone is empty, and every extension names its own member":
    for lang in Lang:
      checkpoint($lang)
      let ext = getExtensionName(lang)
      # The native wrapper in `common/lang.nim` is the same table.
      check getExtension(lang) == ext
      if lang == LangUnknown:
        check ext == ""
      else:
        check ext.len > 0
        check ext == ext.toLowerAscii
        check '.' notin ext
        if lang in UnspelledLangs:
          # The recorded gap: the extension exists, `toLang` does not read it.
          check toLang(ext) == LangUnknown
        else:
          # The extension is an INPUT spelling of the same member, and a file
          # carrying it is recognised as that member.  Otherwise the table
          # that names a language's files and the table that reads them
          # disagree.
          check ext in langSpellings(lang)
          check toLang(ext) == lang
          check toLangFromFilename("main." & ext) == lang

  test "exactly the recorded members have no input spelling":
    var unspelled: set[Lang] = {}
    for lang in Lang:
      if langSpellings(lang).len == 0:
        unspelled.incl(lang)
    check unspelled == UnspelledLangs

  test "tokenTextsFor: total, materialised as TOKEN_TEXTS, and the known rows are what they say":
    for lang in Lang:
      checkpoint($lang)
      check TOKEN_TEXTS[lang] == tokenTextsFor(lang)
      let row = tokenTextsFor(lang)
      # Brackets are either all spelled or all empty: a half-empty row would
      # render `vec![1, 2` or `1, 2]`.
      var empty = 0
      for text in TokenText:
        if row[text].len == 0: inc empty
      check empty == 0 or empty == TokenText.high.ord + 1
    check tokenTextsFor(LangRust)[SeqOpen] == "vec!["
    check tokenTextsFor(LangNim)[SeqOpen] == "@["
    check tokenTextsFor(LangCpp)[SeqOpen] == "vector["
    for text in TokenText:
      check tokenTextsFor(LangUnknown)[text] == ""

  test "reservedNames and flowKeywords: Nim's rows are populated, and no other":
    check "proc" in reservedNames(LangNim)
    check "result" in reservedNames(LangNim)
    check "proc" in flowKeywords(LangNim)
    for lang in Lang:
      checkpoint($lang)
      for name in reservedNames(lang):
        check name.len > 0
      if lang != LangNim:
        check reservedNames(lang).len == 0
        check flowKeywords(lang).len == 0
    # No keyword listed twice within a row.
    check reservedNames(LangNim).toHashSet.len == reservedNames(LangNim).len
    check flowKeywords(LangNim).toHashSet.len == flowKeywords(LangNim).len

  test "langSpellings and LANG_SPELLINGS are one table, and toLang reads it":
    var rows = 0
    for lang in Lang:
      for spelling in langSpellings(lang):
        inc rows
        checkpoint(spelling & " -> " & $lang)
        check (spelling, lang) in LANG_SPELLINGS
        check toLang(spelling) == lang
        check toLang(spelling.toUpperAscii) == lang
        check isKnownLangSpelling(spelling)
    check rows == LANG_SPELLINGS.len
    check langSpellings(LangUnknown).len == 0
    check toLang("no-such-language") == LangUnknown
    check(not isKnownLangSpelling("no-such-language"))
    let lines = unknownLangSpellingLines("no-such-language")
    check lines.len == 2
    check "no-such-language" in lines[0]
    for (spelling, _) in LANG_SPELLINGS:
      check spelling in lines[1]

  test "the ISA spellings and the deprecated aliases resolve through the same floor":
    for (name, isa) in TargetIsaSpellings:
      checkpoint(name)
      check targetIsaSpelling(name) == isa
      check isKnownLangSpelling(name)
      check toLang(name) == LangUnknown
    for (name, isa) in WasmLangSpellingIsa:
      check targetIsaSpelling(name) == isa
      check toLang(name) != LangUnknown
    for row in DeprecatedLangSpellings:
      checkpoint(row.spelling)
      check toLang(row.spelling) == row.lang
      check deprecatedLangSpellingNote(row.spelling).len > 0
    check deprecatedLangSpellingNote("rust") == ""

  test "SUPPORTED_LANGS and LANG_PICKER_LANGS are derived from isSupportedLang":
    var expected: seq[Lang] = @[]
    for lang in Lang:
      if isSupportedLang(lang):
        expected.add(lang)
    check SUPPORTED_LANGS == expected
    check LangUnknown notin SUPPORTED_LANGS
    for lang in DeclaredUnsupportedLangs:
      check lang notin SUPPORTED_LANGS
    for lang in LANG_PICKER_LANGS:
      check lang in SUPPORTED_LANGS
    # No two picker entries share an `<option value>`.
    var values = initHashSet[string]()
    for lang in LANG_PICKER_LANGS:
      check toCLang(lang) notin values
      values.incl(toCLang(lang))
    # The counts, printed so a verification run can read them rather than
    # recount by hand.  Not asserted as literals: they move whenever a
    # language is added, and the relations above are what must hold.
    var members = 0
    for _ in Lang: inc members
    echo "    [counts] Lang members: ", members,
      ", SUPPORTED_LANGS: ", SUPPORTED_LANGS.len,
      ", LANG_PICKER_LANGS: ", LANG_PICKER_LANGS.len,
      ", LANG_SPELLINGS: ", LANG_SPELLINGS.len

  test "langWireName is unique and decodeLangName reads every member back":
    var wire = initHashSet[string]()
    for lang in Lang:
      checkpoint($lang)
      check langWireName(lang) notin wire
      wire.incl(langWireName(lang))
      let decoded = decodeLangName($lang)
      check decoded.lang == lang
      check decoded.retiredName == ""
    let retired = decodeLangName("LangRuby")
    check retired.lang == LangUnknown
    check retired.retiredName == "LangRuby"

  test "storageSlug and the axis projection are reachable for every member":
    var slugs = initHashSet[string]()
    for language in SourceLanguage:
      checkpoint($language)
      let slug = storageSlug(language)
      check slug.len > 0
      check slug notin slugs
      slugs.incl(slug)
    for lang in Lang:
      checkpoint($lang)
      let axes = axesOfLang(lang)
      check sourceLanguageOf(lang) == axes.language
      check langForSourceLanguage(axes.language) == lang
      let stored = langForStorageAxes(storageAxesOfLang(lang))
      check stored.found
      check stored.lang == lang
    # The two stated exceptions answer what their rows say, whatever the
    # approach axis alone would have answered.
    for row in MaterializedSummaryExceptions:
      checkpoint($row.language)
      check usesMaterializedTraces(langForSourceLanguage(row.language)) ==
        row.materialized
    for lang in SUPPORTED_LANGS:
      if lang in UnspelledLangs:
        continue  # the extension does not resolve; see UnspelledLangs
      let ext = getExtensionName(lang)
      check usesMaterializedTracesForExtension(ext) == usesMaterializedTraces(lang)
