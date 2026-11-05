## record_lang_forwarding_test.nim
##
## `ct record` passes its recognizer's answer to `db-backend-record`, so the
## target is recognized once per recording, not twice — codetracer-specs
## `CLI/ct/record.md`, "Target Recognition", and Native-Target-Recognition §9
## Q7 (revised 2026-11-05). The end-to-end half, the shipped `ct` counting
## recognizer spawns, is the Q7 test in `record_recognition_e2e_test.nim`.
##
## Mocking justification (workspace policy on mock objects): none. The pure
## resolver is called with what `record()` hands it.
##
## Compile and run:
##   nim c -r src/tests/cli/record_lang_forwarding_test.nim

import std/unittest
import ../../ct/trace/record_lang_forwarding
import ../../common/lang

suite "ct record: the language arguments passed to db-backend-record":
  test "the user's own --lang is forwarded verbatim, as explicit":
    check forwardedLangArgs("ruby(db)", false, LangUnknown) == @["--lang", "ruby(db)"]
    check forwardedLangArgs("rust", true, LangC) == @["--lang", "rust"]

  test "a recognized language is forwarded as recognized, not as --lang":
    let args = forwardedLangArgs("", true, LangRust)
    check args.len == 2
    check args[0] == "--recognized-lang"
    check toLang(args[1]) == LangRust

  # The case that still recognized twice before: the recognizer ran and found
  # no language this build maps.
  test "a recognizer that found no language forwards `unknown`":
    check forwardedLangArgs("", true, LangUnknown) ==
      @["--recognized-lang", RecognizedUnknown]
    check toLang(RecognizedUnknown) == LangUnknown

  test "no recognition forwards nothing":
    check forwardedLangArgs("", false, LangRust).len == 0

  test "every language with a --lang spelling has a forwardable one":
    for lang in Lang:
      if lang != LangUnknown and langSpellings(lang).len > 0:
        let spelling = canonicalLangSpelling(lang)
        check spelling.len > 0
        check toLang(spelling) == lang
        check deprecatedLangSpellingNote(spelling).len == 0
