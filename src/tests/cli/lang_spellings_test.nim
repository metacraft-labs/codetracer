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
import ../../ct/trace/recorder_dispatch  # the ISA-selected recorder (LRS-5)

suite "the spellings table is one exhaustive case, built once":

  test "every row of LANG_SPELLINGS is a row of langSpellings, in declaration order":
    var expected: seq[(string, Lang)] = @[]
    for lang in Lang:
      for spelling in langSpellings(lang):
        expected.add((spelling, lang))
    check LANG_SPELLINGS == expected
    # 64 at LRS-3; LRS-4 deleted `LangRuby`'s one row (`ruby`) and gave the
    # spelling to `LangRubyDb`, so the count was unchanged: the row MOVED.
    # LRS-5's second deletion round took 64 -> 62: the six rows of the four
    # deleted members (`rust-wasm`, `rustwasm`, `cpp-wasm`, `cppwasm`,
    # `polkavm`, `solana`) left this table, and FOUR came back on the members
    # whose language they actually name -- `LangRust` and `LangCpp` -- as
    # deprecated aliases.  `polkavm` and `solana` did NOT come back here,
    # because they name no language; they moved to `TargetIsaSpellings`, on
    # the axis they always belonged to.  Both halves are asserted below.
    check LANG_SPELLINGS.len == 62

  test "the two platform spellings name a TARGET ISA, not a language":
    ## The other half of the `rust-wasm` decision (LRS-5's second deletion
    ## round).  `rust-wasm` / `cpp-wasm` name a LANGUAGE plus an ISA, and the
    ## language half survives as a deprecated alias.  `polkavm` / `solana`
    ## named ONLY a target — `getExtensionName` was `""` for both, there is no
    ## `LANGS` row and no `detectFolderLang` arm — so `--lang polkavm` was the
    ## ONLY way to record such a target, and deleting the spelling with the
    ## member would have DELETED the route, not renamed it: the target would
    ## fall through to `detectFolderLang`, a Solana crate would read as plain
    ## Rust, and `ct record` would take the native path.  They are therefore
    ## `TargetIsaSpellings` rows, which override the assessment's ISA.
    check toLang("polkavm") == LangUnknown      # no language, and that is true
    check toLang("solana") == LangUnknown
    check targetIsaSpelling("polkavm") == tiPolkaVm
    check targetIsaSpelling("solana") == tiSolanaSbf
    check targetIsaSpelling("SOLANA") == tiSolanaSbf     # case-insensitive
    check targetIsaSpelling("solanasbf") == tiSolanaSbf
    check targetIsaSpelling("rust") == tiUnknown
    check targetIsaSpelling("") == tiUnknown
    # ...and no member claims either spelling as a LANGUAGE under any name.
    for lang in Lang:
      check "polkavm" notin langSpellings(lang)
      check "solana" notin langSpellings(lang)
    # The route survives: the ISA the spelling names selects the recorder the
    # deleted member used to select.
    for (spelling, isa) in [("polkavm", tiPolkaVm), ("solana", tiSolanaSbf)]:
      checkpoint("--lang " & spelling)
      let s = selector(slUnknown, targetIsaSpelling(spelling),
                       defaultRecordingApproach(targetIsaSpelling(spelling)))
      check s.targetIsa == isa
      check recorderToolFor(s).supported
      check recorderToolFor(s).recorderLabel == blockchainRecorderName(isa)

  test "the four wasm aliases carry an ISA as well as a language":
    ## Without the ISA half, `--lang rust-wasm ./crate` with no `wasm32`
    ## marker would resolve to `LangRust` and record NATIVELY — the one
    ## outcome the milestone said must not happen ("a wasm recording or a
    ## clear error, never a silent native one").
    for spelling in ["rust-wasm", "rustwasm", "cpp-wasm", "cppwasm"]:
      checkpoint("--lang " & spelling)
      check toLang(spelling) in {LangRust, LangCpp}
      check targetIsaSpelling(spelling) == tiWasm
    check toLang("rust-wasm") == LangRust
    check toLang("cpp-wasm") == LangCpp
    # `wasm` alone is the general ISA spelling, naming no language.
    check targetIsaSpelling("wasm") == tiWasm
    check toLang("wasm") == LangUnknown

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
    # 1 at LRS-4 (`ruby(db)`); 5 since LRS-5's second deletion round added
    # the four wasm aliases.
    check DeprecatedLangSpellings.len == 5
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
    # The four wasm aliases, and the second sentence that says where the ISA
    # comes from now -- without it "it selects Rust exactly as `--lang rust`
    # does" would read as "the wasm target was dropped".
    var wasmRows = 0
    for row in DeprecatedLangSpellings:
      if row.spelling in ["rust-wasm", "rustwasm", "cpp-wasm", "cppwasm"]:
        inc wasmRows
        check row.extra == WasmSpellingNote
        check WasmSpellingNote in deprecatedLangSpellingNote(row.spelling)
        check ".cargo/config.toml" in deprecatedLangSpellingNote(row.spelling)
        check "`.wasm`" in deprecatedLangSpellingNote(row.spelling)
      else:
        check row.extra == ""
    check wasmRows == 4
    check toLang("rust-wasm") == LangRust
    check toLang("cpp-wasm") == LangCpp

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
    # LRS-5's second deletion round: these are deprecated ALIASES of the
    # language now, not members of their own.  The wasm target rides on the
    # artefact (`KindWasmModule` / `KindWasmCargoProject`), so the spelling
    # keeps working and no invocation silently becomes native.
    check toLang("rust-wasm") == LangRust
    check toLang("rustwasm") == LangRust
    check toLang("cpp-wasm") == LangCpp
    check toLang("cppwasm") == LangCpp
    check deprecatedLangSpellingNote("rust-wasm").len > 0
    check WasmSpellingNote in deprecatedLangSpellingNote("rust-wasm")
    check WasmSpellingNote in deprecatedLangSpellingNote("CPP-WASM")
    check deprecatedLangSpellingNote("rust") == ""
    check toLang("gd") == LangGdScript
    check toLang("gdscript") == LangGdScript
    check toLang("hrl") == LangErlang
    check toLang("exs") == LangElixir

suite "the spellings agree with the other tables over Lang":

  test "a member's canonical extension names the member, except the conflations and the shells":
    ## `toLang(getExtensionName(lang)) == lang` for every member with an
    ## extension, except the two shells, which have no spelling here.  Pinned
    ## as an exact set so a new member cannot join it unnoticed.
    ##
    ## The set SHRANK at LRS-5's second deletion round, which is the property
    ## worth naming: `LangRustWasm` / `LangCppWasm` were in it because two
    ## members claimed one extension (`rs`, `cpp`) and the extension had to
    ## resolve to one of them.  With the wasm pair deleted no extension is
    ## claimed twice, so every member with an extension round-trips.
    ## (`LangPython` / `LangRuby` left the set the same way at LRS-4.)
    var exceptions: set[Lang] = {}
    for lang in Lang:
      let ext = getExtensionName(lang)
      if ext.len > 0 and toLang(ext) != lang:
        exceptions.incl(lang)
    check exceptions == {LangBash, LangZsh}

  test "a member's name (toCLang) names the member, except the folded, the shells and asm":
    ## `toLang(toCLang(lang)) == lang` except where the name is shared and
    ## resolves to the other member (`rust`/`cpp` -> the plain members), where
    ## the member has no spelling (the shells), and `assembly`, which has
    ## never been an input spelling of LangAsm on either side.  The sentinel
    ## is NOT an exception: `unknown` is a miss, and a miss is LangUnknown.
    ## Since LRS-4 `ruby` and `python` round-trip too: `toCLang(LangRubyDb)`
    ## is `ruby` and `toLang("ruby")` is LangRubyDb (it used to be the retired
    ## LangRuby, which put LangRubyDb in this set), and LangPython is gone.
    ## LRS-5's second deletion round removed the last two shared names: with
    ## the wasm pair gone, `rust` and `cpp` each name one member.
    var exceptions: set[Lang] = {}
    for lang in Lang:
      if toLang(toCLang(lang)) != lang:
        exceptions.incl(lang)
    check exceptions == {LangAsm, LangBash, LangZsh}
    check toLang("unknown") == LangUnknown
    check toLang(toCLang(LangRubyDb)) == LangRubyDb
    check toLang(toCLang(LangPythonDb)) == LangPythonDb

  test "the spellings do not disagree with `LANGS`, the ct record routing table":
    ## `LANGS` (`language_detection.nim`) is deliberately a separate,
    ## extension-only table (the desktop capability file is derived from it).
    ## The two may differ in COVERAGE but must not CONTRADICT: an extension
    ## both know resolves to the same member on both.  The one recorded
    ## exception is gone with LRS-5's second deletion round: `LANGS` used to
    ## route a bare `c` / `cpp` under `--wasm` to `LangCppWasm` through its
    ## own `WASM_LANGS` table, and that table -- an ISA written into a
    ## language answer -- was deleted with the members.
    var compared = 0
    for extension, routed in LANGS.pairs:
      let spelled = toLang(extension)
      if spelled != LangUnknown:
        check spelled == routed
        inc compared
    check compared >= 30   # anti-vacuity: the two tables overlap widely

  test "an unrecognised --lang spelling is recognisable AS unrecognised (LRS-5, at review)":
    ## The predicate `ct record` and `db-backend-record` refuse on.  Before it
    ## existed there was no way to tell "the user named a language I do not
    ## know" from "the user named no language": both are `LangUnknown` out of
    ## `toLang`, and `detectTarget`'s first line treats that as the latter --
    ## so `--lang typo` recorded the target as if the flag had been omitted.
    ##
    ## It cannot be written as `toLang(s) != LangUnknown`, and that is the
    ## whole subtlety this case exists to pin: `polkavm` and `solana` name a
    ## target ISA and NO language, and they are the only route to those two
    ## recorders now that `LangPolkavm` / `LangSolana` are deleted.
    check(not isKnownLangSpelling("definitely-not-a-language"))
    check(not isKnownLangSpelling("rust-wasm-typo"))
    check(not isKnownLangSpelling("c++"))        # `toCLang` says `cpp`; input is `cpp`
    for (spelling, _) in LANG_SPELLINGS:
      checkpoint("language spelling: " & spelling)
      check isKnownLangSpelling(spelling)
      check isKnownLangSpelling(spelling.toUpperAscii)   # case-insensitive
    for (spelling, _) in TargetIsaSpellings:
      checkpoint("ISA spelling: " & spelling)
      check isKnownLangSpelling(spelling)
      check toLang(spelling) == LangUnknown     # ...and names no language
    # The empty string is NOT this predicate's business: `--lang` absent is
    # the legitimate "no language given", and the callers test the length.
    check(not isKnownLangSpelling(""))

  test "the refusal names the spelling and every spelling that IS accepted":
    ## A refusal that does not say what to type instead is a worse defect than
    ## the fall-through it replaces.  The list is built from the same two
    ## tables the predicate consults, so it cannot drift from what is accepted.
    let lines = unknownLangSpellingLines("definitely-not-a-language")
    check lines.len == 2
    let text = lines.join("\n")
    check "definitely-not-a-language" in text
    check "neither a language nor a target" in text
    for spelling in ["rust", "ruby", "python", "polkavm", "solana",
                     "rust-wasm", "gdscript"]:
      checkpoint("must be offered: " & spelling)
      check spelling in text
    # Nothing that is NOT accepted may be offered.
    for (spelling, _) in LANG_SPELLINGS:
      check spelling in text
