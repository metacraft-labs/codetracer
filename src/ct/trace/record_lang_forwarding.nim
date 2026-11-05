## record_lang_forwarding — the language arguments `ct record` passes on to
## `db-backend-record`.
##
## NORMATIVE SOURCE: `codetracer-specs/CLI/ct/record.md`, "Target
## Recognition" (a native target is recognized once per `ct record`), and
## `Planned-Features/Native-Target-Recognition.md` §9 Q7 as revised by the user
## on 2026-11-05.
##
## `ct record` recognizes the target, then starts `db-backend-record`, which
## recognized the same file again in its own process because `ct` forwarded a
## language only when the user had typed one. On a 2.6 GB debug Rust binary
## that second recognition cost about ten minutes per recording. Q7 permits
## carrying a result within one invocation; this carries it across the process
## boundary of one `ct record`.
##
## Two flags, because the two facts differ:
##
## * `--lang X`: the user said X. `db-backend-record` treats it as explicit,
##   exactly as before.
## * `--recognized-lang X`: `ct`'s recognizer ran and answered X, a `--lang`
##   spelling or `unknown`. `db-backend-record` uses the answer instead of
##   recognizing again, and does NOT treat it as explicit, so a later consumer
##   of "was the language given?" (trace metadata, NTR-3) still sees the
##   truth. `unknown` is forwarded too: a binary whose language this build does
##   not map costs the same walk as any other.
##
## Nothing is forwarded when the recognizer did not run: a language from a
## folder manifest or a file extension is cheap, and `db-backend-record`
## re-derives it from the same signal.
##
## PURE: asserted by `src/tests/cli/record_lang_forwarding_test.nim`.

import ../../common/lang

const RecognizedUnknown* = "unknown"
  ## The `--recognized-lang` value for "the recognizer ran and found no
  ## language". Not a `--lang` spelling.

proc canonicalLangSpelling*(lang: Lang): string =
  ## The first `--lang` spelling that names `lang` and is not deprecated, or
  ## `""` when `lang` has none.
  for spelling in langSpellings(lang):
    if toLang(spelling) == lang and deprecatedLangSpellingNote(spelling).len == 0:
      return spelling
  ""

proc forwardedLangArgs*(userLang: string, recognitionRan: bool,
                        detected: Lang): seq[string] =
  ## The language arguments for `db-backend-record`: the user's own `--lang`,
  ## verbatim, when one was given; else `--recognized-lang` with the
  ## recognizer's answer when it ran; else nothing.
  if userLang.len > 0:
    return @["--lang", userLang]
  if not recognitionRan:
    return @[]
  let spelling =
    if detected == LangUnknown: "" else: canonicalLangSpelling(detected)
  @["--recognized-lang", if spelling.len > 0: spelling else: RecognizedUnknown]
