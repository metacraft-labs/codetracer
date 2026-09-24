## recognize_vocabulary_pin_test.nim
##
## **The frozen vocabularies `ct-native-replay recognize` emits are ones this
## build can parse** -- a build-time pin across the repository boundary, read
## from the sibling's SOURCE.  Registered by LRS-2P's review as XRC-CT-CORE-17's
## gap, and closed by LRS-6 (2026-09-23).
##
## ## The gap this closes
##
## Two vocabularies are spelled independently on the two sides of the
## `codetracer.target-recognition.v2` document:
##
## | vocabulary | producer (Rust, `codetracer-native-backend`) | consumer (Nim, here) |
## |------------|----------------------------------------------|----------------------|
## | the family | `src/recognize.rs`, `pub mod family` constants | `TargetFamily` / `parseTargetFamily` (`src/common/target_assessment.nim`) |
## | the census language | `src/recognize.rs`, `assessment_language_name`'s `Some("…")` arms | `SourceLanguage` / `parseSourceLanguage` (`src/common/target_axes.nim`) |
##
## Each side pins its own literals against ITSELF, so a one-character
## divergence leaves both repositories green.  LRS-2P's review measured it:
## `prebuilt-artefact` -> `prebuilt-artifact` on one side, every in-repo suite
## still passing, and every native `ct record` stopping before it records,
## because rule K3 refuses a family the consumer cannot parse (loudly, as
## designed -- but only at run time, on a user's machine).
##
## ## What is checked, and in which direction
##
## ONE-WAY, on purpose: every literal the Rust side EMITS must parse on the Nim
## side and spell back to the same bytes (`token(parsed) == literal`, because
## both parsers lower-case and strip their input and would otherwise forgive a
## case or whitespace difference the wire would not).  A value the Nim side
## knows and the Rust side never emits is fine: the producer names only what
## it can justify, and the consumer's vocabulary is the authority (the Rust
## module says so in its own doc comment).
##
## Specific KINDS (`pub mod kind`) are deliberately not pinned: an unknown
## specific kind degrades to its family out loud (`degradationDiagnostic`;
## specific kinds are additive within a schema major version, design §9.4), it
## does not stop a recording, so it is not the failure this suite exists for.
##
## ## Finding the sibling
##
## The same resolution `scripts/detect-siblings.sh` performs, which
## `just test-cli-record` sources before running this lane:
##
## 1. `CT_CODETRACER_NATIVE_BACKEND_SIBLING`, when set.  If it is set and does
##    not name a checkout, that is a failure naming the variable -- an
##    explicit setting is never silently replaced by a guess.
## 2. Otherwise `<parent>/codetracer-native-backend` (the standard workspace
##    layout), then `<grandparent>/codetracer-native-backend` (the worktree
##    layout), exactly as the script tries them.
##
## Pure `std/os` path handling, so it resolves on Windows the same way.
##
## **A missing sibling FAILS, it does not skip** -- the precedent is
## `ci/test/desktop_component_caps_check.nim` (XRC-CT-CORE-12), which likewise
## refuses to pass without the sibling checkout it reads.  A skip here would be
## the exact "both sides green, product broken" state this suite removes.

import std/[os, strutils, unittest]
import ../../common/target_axes        # SourceLanguage, parseSourceLanguage, token
import ../../common/target_assessment  # TargetFamily, parseTargetFamily, token

const
  ThisFile = currentSourcePath()
  RepoRoot = ThisFile.parentDir.parentDir.parentDir.parentDir
    ## src/tests/cli/<this> -> src/tests/cli -> src/tests -> src -> <repo>
  SiblingEnv = "CT_CODETRACER_NATIVE_BACKEND_SIBLING"
  SiblingName = "codetracer-native-backend"
  RecognizeRel = "src" / "recognize.rs"
  NimFamilySide = "TargetFamily (codetracer/src/common/target_assessment.nim)"
  NimLanguageSide = "SourceLanguage (codetracer/src/common/target_axes.nim)"

type
  RustLiteral = object
    name: string   ## the Rust-side name: a const identifier, or the match arm
    value: string  ## the string literal the producer puts on the wire

proc resolveSibling(): tuple[path: string, how: string, error: string] =
  ## Where the native-backend checkout is, how that was decided, or why it
  ## could not be found.  Never answers a path that does not exist.
  let fromEnv = getEnv(SiblingEnv)
  if fromEnv.len > 0:
    if dirExists(fromEnv):
      return (fromEnv, "$" & SiblingEnv, "")
    return ("", "", "$" & SiblingEnv & " is set to '" & fromEnv &
      "', which is not a directory.  An explicit setting is not replaced " &
      "by a guess; fix or unset it.")
  let candidates = [RepoRoot.parentDir / SiblingName,
                    RepoRoot.parentDir.parentDir / SiblingName]
  for candidate in candidates:
    if dirExists(candidate):
      return (candidate, "workspace layout (" & candidate & ")", "")
  ("", "", "the " & SiblingName & " sibling checkout was not found: $" &
    SiblingEnv & " is unset and neither " & candidates[0] & " nor " &
    candidates[1] & " exists.  Clone it beside this repository (see " &
    "scripts/detect-siblings.sh).  This is a hard failure, not a skip: " &
    "without the sibling, nothing compares the two vocabularies.")

proc blockAfter(source, opener: string): string =
  ## The text from `opener` to the first line that is exactly `}` at the
  ## opener's own indentation (column 0 for the items read here).  `""` when
  ## `opener` does not occur.
  let at = source.find(opener)
  if at < 0:
    return ""
  let close = source.find("\n}", at)
  if close < 0:
    return source[at .. ^1]
  source[at .. close + 1]

proc familyLiterals(source: string): seq[RustLiteral] =
  ## `pub const NAME: &str = "value";` inside `pub mod family { … }`.
  let body = blockAfter(source, "pub mod family {")
  for raw in body.splitLines():
    let line = raw.strip()
    if not line.startsWith("pub const "):
      continue
    let colon = line.find(':')
    let q1 = line.find('"')
    let q2 = if q1 >= 0: line.find('"', q1 + 1) else: -1
    if colon < 0 or q1 < 0 or q2 < 0:
      continue
    result.add(RustLiteral(name: line["pub const ".len ..< colon].strip(),
                           value: line[q1 + 1 ..< q2]))

proc censusLiterals(source: string): seq[RustLiteral] =
  ## Every `Some("value")` in `fn assessment_language_name`, named by its
  ## match arm (the text before `=>`).
  let body = blockAfter(source, "fn assessment_language_name(")
  for raw in body.splitLines():
    let line = raw.strip()
    var start = line.find("Some(\"")
    while start >= 0:
      let valueStart = start + "Some(\"".len
      let valueEnd = line.find('"', valueStart)
      if valueEnd < 0:
        break
      let arrow = line.find("=>")
      let arm = if arrow > 0: line[0 ..< arrow].strip() else: line
      result.add(RustLiteral(name: arm, value: line[valueStart ..< valueEnd]))
      start = line.find("Some(\"", valueEnd)

proc knownLanguageTokens(): string =
  var parts: seq[string] = @[]
  for v in SourceLanguage:
    parts.add(token(v))
  parts.join(", ")

let sibling = resolveSibling()
let recognizePath =
  if sibling.path.len > 0: sibling.path / RecognizeRel else: ""

proc readRecognize(): string =
  ## The producer's source, or a raised error naming what is missing.  Raising
  ## (rather than returning `""`) is what makes a missing sibling FAIL every
  ## case below instead of letting a scrape of nothing pass them.
  if sibling.error.len > 0:
    raise newException(IOError, "recognize_vocabulary_pin_test: " & sibling.error)
  if not fileExists(recognizePath):
    raise newException(IOError, "recognize_vocabulary_pin_test: the " &
      SiblingName & " checkout at " & sibling.path & " (found via " &
      sibling.how & ") has no " & RecognizeRel & ".  The producer moved or " &
      "the checkout is not the one this suite pins; this is a hard failure.")
  readFile(recognizePath)

suite "ct-native-replay recognize emits only vocabulary this build parses (LRS-6; XRC-CT-CORE-17's gap)":

  test "the native-backend sibling is found (a missing sibling FAILS, never skips)":
    if sibling.error.len > 0:
      checkpoint(sibling.error)
    check sibling.error.len == 0
    check sibling.path.len > 0
    if sibling.path.len > 0:
      checkpoint("sibling: " & sibling.path & " (via " & sibling.how & ")")
      check fileExists(recognizePath)

  test "every family the producer emits parses as a TargetFamily, byte for byte":
    let literals = familyLiterals(readRecognize())
    # Anti-vacuity: the scrape found the module.  A renamed `mod family`
    # would otherwise pass this case with nothing checked.
    check literals.len > 0
    if literals.len == 0:
      checkpoint("no `pub const` found in `pub mod family { … }` of " &
                 recognizePath & "; the scrape needs updating to the " &
                 "producer's current shape")
    echo "    [scraped] ", literals.len, " family literal(s) from ", recognizePath
    for literal in literals:
      var parsed: TargetFamily
      let ok = parseTargetFamily(literal.value, parsed)
      if not ok or token(parsed) != literal.value:
        checkpoint("VOCABULARY DIVERGENCE: the Rust producer " & recognizePath &
          " (`family::" & literal.name & "`) emits the family `" &
          literal.value & "`, which the Nim consumer " & NimFamilySide &
          " does not spell that way.  Nim knows: " & knownFamilyTokens() &
          ".  Every `ct record` that receives it is refused by rule K3.")
      check ok
      check ok and token(parsed) == literal.value

  test "every census language the producer emits parses as a SourceLanguage, byte for byte":
    let literals = censusLiterals(readRecognize())
    check literals.len > 0
    if literals.len == 0:
      checkpoint("no `Some(\"…\")` arm found in `fn assessment_language_name` " &
                 "of " & recognizePath & "; the scrape needs updating")
    echo "    [scraped] ", literals.len, " census literal(s) from ", recognizePath
    for literal in literals:
      var parsed: SourceLanguage
      let ok = parseSourceLanguage(literal.value, parsed)
      if not ok or token(parsed) != literal.value:
        checkpoint("VOCABULARY DIVERGENCE: the Rust producer " & recognizePath &
          " (`assessment_language_name`, arm `" & literal.name & "`) emits " &
          "the census language `" & literal.value & "`, which the Nim " &
          "consumer " & NimLanguageSide & " does not spell that way.  Nim " &
          "knows: " & knownLanguageTokens() & ".")
      check ok
      check ok and token(parsed) == literal.value
