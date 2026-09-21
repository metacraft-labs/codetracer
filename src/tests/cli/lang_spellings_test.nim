## lang_spellings_test.nim
##
## The one input-spelling table (`langSpellings` / `LANG_SPELLINGS` / `toLang`
## in `src/common/common_lang.nim`), asserted on the native backend.  The JS
## half is in `src/frontend/tests/frontend_lang_test.nim`.
##
## LRS-3 unified three hand-kept tables -- the core's `toLang`, the front end's
## `toLang` and its `fromPath` -- into one exhaustive `case` over `Lang`, and
## that CHANGED DETECTION BEHAVIOUR on both sides.  This file pins what the
## core side now answers, including every spelling it gained, so the change
## is a stated one rather than a side effect: the design's §2.5 recorded the
## asm divergence (`asm` only here, `asm` and `s` there; `miden` here and not
## there) and said no comment claimed it was deliberate.
##
## Nothing here skips.

import std/[sets, strutils, tables, unittest]
import ../../common/lang
import ../../ct/utilities/language_detection

suite "the spellings table is one exhaustive case, built once":

  test "every row of LANG_SPELLINGS is a row of langSpellings, in declaration order":
    var expected: seq[(string, Lang)] = @[]
    for lang in Lang:
      for spelling in langSpellings(lang):
        expected.add((spelling, lang))
    check LANG_SPELLINGS == expected
    # 64 at LRS-3; LRS-4 deleted `LangRuby`'s one row (`ruby`) and gave the
    # spelling to `LangRubyDb`, so the count is unchanged: the row MOVED.
    check LANG_SPELLINGS.len == 64

  test "no spelling is claimed twice, and every one is lower-case and non-empty":
    var seen = initHashSet[string]()
    for (spelling, lang) in LANG_SPELLINGS:
      check spelling.len > 0
      check spelling == spelling.toLowerAscii
      check spelling notin seen
      seen.incl(spelling)

  test "toLang is the table: every spelling resolves to its own member":
    for (spelling, lang) in LANG_SPELLINGS:
      check toLang(spelling) == lang
      check toLang(spelling.toUpperAscii) == lang   # case-insensitive
      check toLang(cstring(spelling)) == lang

  test "a miss is LangUnknown, never the zero value":
    for miss in ["", "assembler", "assembly", "c++", "unknown", "txt", "wasm",
                 "ts", "mjs", "sh", "bash", "zsh", "pythondb", "rubydb"]:
      check toLang(miss) == LangUnknown

  test "exactly three members have no spelling, each for a recorded reason":
    var silent: set[Lang] = {}
    for lang in Lang:
      if langSpellings(lang).len == 0:
        silent.incl(lang)
    # LangUnknown: the sentinel.  LangBash/LangZsh: reach `ct record` through
    # `LANGS`, which is not this table (see the `langSpellings` doc comment).
    # Until LRS-4 `LangPython` was the fourth -- unreachable from any input
    # (design §3.1) because `python`/`py` always named LangPythonDb -- and it
    # is gone.
    check silent == {LangUnknown, LangBash, LangZsh}

  test "the deprecated aliases are spellings of their member and name a preferred one (Q6)":
    ## `DeprecatedLangSpellings` is the alias table `ct record` announces
    ## from.  Each row must still RESOLVE (or the note would announce a
    ## deprecation of something that already broke), to the same member the
    ## preferred spelling names.
    check DeprecatedLangSpellings.len == 1
    for row in DeprecatedLangSpellings:
      checkpoint("deprecated: " & row.spelling)
      check toLang(row.spelling) == row.lang
      check toLang(row.preferred) == row.lang
      check row.spelling in langSpellings(row.lang)
      check row.preferred in langSpellings(row.lang)
      check row.spelling != row.preferred
    check DeprecatedLangSpellings[0].spelling == "ruby(db)"
    check DeprecatedLangSpellings[0].lang == LangRubyDb
    check DeprecatedLangSpellings[0].preferred == "ruby"

suite "the asm rows are unified (design §2.5): asm AND s, masm AND miden, on the core side":

  test "the core gained `s` for LangAsm":
    ## Before LRS-3 `src/common/lang.nim`'s table mapped only `asm`; the front
    ## end's mapped `asm` and `s`.  Both now do both.
    check toLang("asm") == LangAsm
    check toLang("s") == LangAsm
    check toLangFromFilename("boot.s") == LangAsm
    check toLangFromFilename("boot.S") == LangAsm
    check toLangFromFilename("boot.asm") == LangAsm

  test "the core keeps `miden` for LangMasm (the front end gained it)":
    check toLang("masm") == LangMasm
    check toLang("miden") == LangMasm
    check langSpellings(LangMasm) == @["masm", "miden"]
    check langSpellings(LangAsm) == @["asm", "s"]

  test "the other spellings the core gained from the front end's tables":
    ## `h`, `hpp`, `pas` and `js` were extension rows of the front end's
    ## `toLang` that the core's never had (with `s`, the five spellings the
    ## core gained -- the complete list, computed table against table).
    ## `--lang h` is now `C`, which is harmless; `js` matters more:
    ## `usesMaterializedTracesForExtension("js")` used to be `false` because
    ## the extension resolved to LangUnknown.
    check toLang("h") == LangC
    check toLang("hpp") == LangCpp
    check toLang("pas") == LangPascal
    check toLang("js") == LangJavascript
    check usesMaterializedTracesForExtension("js")
    check usesMaterializedTracesForExtension("s") == false

  test "the spellings the core already had are unchanged":
    # A sample across the table, one per row shape: name, extension, alias,
    # the parenthesised Ruby form, the two hyphen forms and the GDScript pair.
    check toLang("rust") == LangRust
    check toLang("rs") == LangRust
    check toLang("nims") == LangNim
    check toLang("dlang") == LangD
    check toLang("python") == LangPythonDb
    check toLang("py") == LangPythonDb
    check toLang("ruby") == LangRubyDb        # the working recorder since LRS-4 (Q6)
    check toLang("rb") == LangRubyDb
    check toLang("ruby(db)") == LangRubyDb    # deprecated alias, still resolves
    check toLang("rust-wasm") == LangRustWasm
    check toLang("cppwasm") == LangCppWasm
    check toLang("gd") == LangGdScript
    check toLang("gdscript") == LangGdScript
    check toLang("hrl") == LangErlang
    check toLang("exs") == LangElixir

suite "the spellings agree with the other tables over Lang":

  test "a member's canonical extension names the member, except the conflations and the shells":
    ## `toLang(getExtensionName(lang)) == lang` for every member with an
    ## extension, except: the two wasm members whose extension resolves to
    ## the plain sibling (`rs` -> LangRust, `cpp` -> LangCpp), and the two
    ## shells, which have no spelling here.  Pinned as an exact set so a new
    ## member cannot join it unnoticed.  (`LangPython` / `LangRuby` were two
    ## more exceptions -- `py` -> LangPythonDb, `rb` -> LangRubyDb -- until
    ## LRS-4 deleted them.)
    var exceptions: set[Lang] = {}
    for lang in Lang:
      let ext = getExtensionName(lang)
      if ext.len > 0 and toLang(ext) != lang:
        exceptions.incl(lang)
    check exceptions == {LangRustWasm, LangCppWasm, LangBash, LangZsh}

  test "a member's name (toCLang) names the member, except the folded, the shells and asm":
    ## `toLang(toCLang(lang)) == lang` except where the name is shared and
    ## resolves to the other member (`rust`/`cpp` -> the plain members), where
    ## the member has no spelling (the shells), and `assembly`, which has
    ## never been an input spelling of LangAsm on either side.  The sentinel
    ## is NOT an exception: `unknown` is a miss, and a miss is LangUnknown.
    ## Since LRS-4 `ruby` and `python` round-trip too: `toCLang(LangRubyDb)`
    ## is `ruby` and `toLang("ruby")` is LangRubyDb (it used to be the retired
    ## LangRuby, which put LangRubyDb in this set), and LangPython is gone.
    var exceptions: set[Lang] = {}
    for lang in Lang:
      if toLang(toCLang(lang)) != lang:
        exceptions.incl(lang)
    check exceptions == {LangAsm, LangRustWasm, LangCppWasm, LangBash, LangZsh}
    check toLang("unknown") == LangUnknown
    check toLang(toCLang(LangRubyDb)) == LangRubyDb
    check toLang(toCLang(LangPythonDb)) == LangPythonDb

  test "the spellings do not disagree with `LANGS`, the ct record routing table":
    ## `LANGS` (`language_detection.nim`) is deliberately a separate,
    ## extension-only table (the desktop capability file is derived from it).
    ## The two may differ in COVERAGE but must not CONTRADICT: an extension
    ## both know resolves to the same member on both, with the one recorded
    ## exception -- `LANGS` routes a bare `c` and `cpp` under `--wasm` to
    ## LangCppWasm through its own `WASM_LANGS`, which is not `LANGS`.
    var compared = 0
    for extension, routed in LANGS.pairs:
      let spelled = toLang(extension)
      if spelled != LangUnknown:
        check spelled == routed
        inc compared
    check compared >= 30   # anti-vacuity: the two tables overlap widely
