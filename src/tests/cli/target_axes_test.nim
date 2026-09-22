## target_axes_test.nim
##
## The four-axis domain types (`src/common/target_axes.nim`) and the assessment
## protocol type (`src/common/target_assessment.nim`), asserted on the **C
## backend**.  The JS half is `src/frontend/tests/target_axes_js_test.nim`; both
## are required, because a type that only builds on JS defeats the placement
## requirement that a native-backend front end (the planned Nim TUI on
## `isonim-tui`) can reach these modules.
##
## Nothing here skips.  Where a test needs a file from the tree, a missing file
## is a hard failure with a named diagnostic — this repository has found nine
## "reports success while doing nothing" defects in the product and as many again
## in its verification tooling, and a skip is how they hide.
##
## ## What the decomposition suite pins, and why it is the important one
##
## The four axes are only worth having if the 35 values of `Lang` genuinely
## decompose onto them.  Until LRS-2B that decomposition lived HERE, in the
## test, as the safety net for the migration; it is now `axesOfLang` in
## `src/common/common_lang.nim` — the production table `recorder_dispatch.nim`
## selects on — and it must not survive in both places, so this file reads
## the production one and pins what it says.  `usesMaterializedTraces` is now
## DERIVED from it, with exactly two exceptions recorded in
## `MaterializedSummaryExceptions`, and this suite asserts that the exception
## list is exactly those two and that each is the deliberate decision the
## production comment claims:
##
## * `LangNim` is `true` although its per-value axes are `tiNative` / `raMcr`,
##   because BOTH Nim flows import their container as a materialized trace.
## * `LangLua` is `false` although its axes say instrumented runtime, because
##   no Lua recorder exists — the table declares it unsupported — so no
##   materialized Lua trace can exist.

import std/[algorithm, os, sets, strutils, unittest]
import ../../common/target_axes
import ../../common/target_assessment
import ../../common/lang
import ../../common/types   # tokenTextsFor / TOKEN_TEXTS (common_types)
import ../../ct/trace/recorder_dispatch
import ../../common/trace_index        # loadCalltraceMode, langForStorageAxes
import ../../ct/trace/storage_and_import  # detectTraceAxes (LRS-5, (d))

const
  ThisFile = currentSourcePath()
  RepoRoot = ThisFile.parentDir.parentDir.parentDir.parentDir
    ## src/tests/cli/<this> -> src/tests/cli -> src/tests -> src -> <repo>
  LanguageDetectionPath =
    RepoRoot / "src" / "ct" / "utilities" / "language_detection.nim"

proc readTreeFile(path: string, why: string): string =
  ## Read a file from the tree, or fail the run with a diagnostic that names
  ## the file and what the assertion needed it for.  Never returns `""` to a
  ## caller that would then assert nothing.
  if not fileExists(path):
    raise newException(IOError,
      "target_axes_test: required tree file is missing: " & path &
      " (needed for: " & why & "). This is a hard failure, not a skip.")
  result = readFile(path)
  if result.len == 0:
    raise newException(IOError,
      "target_axes_test: required tree file is empty: " & path &
      " (needed for: " & why & ").")

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

suite "every axis token is present, distinct and well-formed":

  test "SourceLanguage tokens are non-empty, lowercase and pairwise distinct":
    var seen = initHashSet[string]()
    for v in SourceLanguage:
      let t = token(v)
      check t.len > 0
      check t == t.toLowerAscii
      check t notin seen
      seen.incl(t)
    check seen.len == (ord(high(SourceLanguage)) - ord(low(SourceLanguage)) + 1)

  test "TargetIsa tokens are non-empty, lowercase and pairwise distinct":
    var seen = initHashSet[string]()
    for v in TargetIsa:
      let t = token(v)
      check t.len > 0
      check t == t.toLowerAscii
      check t notin seen
      seen.incl(t)

  test "Toolchain tokens are non-empty, lowercase and pairwise distinct":
    var seen = initHashSet[string]()
    for v in Toolchain:
      let t = token(v)
      check t.len > 0
      check t == t.toLowerAscii
      check t notin seen
      seen.incl(t)

  test "RecordingApproach tokens are non-empty, lowercase and pairwise distinct":
    var seen = initHashSet[string]()
    for v in RecordingApproach:
      let t = token(v)
      check t.len > 0
      check t == t.toLowerAscii
      check t notin seen
      seen.incl(t)

  test "no axis token contains a hyphen":
    # Reserved so that a later storage grammar can join axis tokens with `-`
    # without the join becoming ambiguous.  `TargetFamily` is deliberately
    # exempt (`single-file`, `project-directory`): families are never joined,
    # they are the terminal element of a kind chain.
    for v in SourceLanguage: check '-' notin token(v)
    for v in TargetIsa: check '-' notin token(v)
    for v in Toolchain: check '-' notin token(v)
    for v in RecordingApproach: check '-' notin token(v)

  test "each axis spells its sentinel `unknown`, and only its sentinel":
    check token(slUnknown) == UnknownToken
    check token(tiUnknown) == UnknownToken
    check token(tcUnknown) == UnknownToken
    check token(raUnknown) == UnknownToken
    for v in SourceLanguage:
      if v != slUnknown: check token(v) != UnknownToken
    for v in TargetIsa:
      if v != tiUnknown: check token(v) != UnknownToken
    for v in Toolchain:
      if v != tcUnknown: check token(v) != UnknownToken
    for v in RecordingApproach:
      if v != raUnknown: check token(v) != UnknownToken

  test "the sentinel is ordinal 0 on every axis":
    # `Lang` used to put `LangC` at ordinal 0, so a proc that fell off its end
    # answered "C" -- the defect documented on `detectLangFromPath` in
    # `src/ct/utilities/language_detection.nim`.  LRS-4 put `LangUnknown` at 0
    # (pinned by `lang_enum_contract_test`); these axes had the property from
    # the start.  A zero-initialised value on them says "not determined".
    check ord(slUnknown) == 0
    check ord(tiUnknown) == 0
    check ord(tcUnknown) == 0
    check ord(raUnknown) == 0

  test "`masm`, `gas` and `nasm` are reserved and spent by nothing":
    for reserved in ReservedSourceLanguageTokens:
      for v in SourceLanguage: check token(v) != reserved
      for v in TargetIsa: check token(v) != reserved
      for v in Toolchain: check token(v) != reserved
      for v in RecordingApproach: check token(v) != reserved
    # And the reason they are reserved: Miden holds the qualified name.
    check token(slMidenAsm) == "midenasm"
    check token(slAsm) == "asm"

# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

suite "parsers round-trip and are total":

  test "parse(token(v)) == v for every member of every axis":
    for v in SourceLanguage:
      var got: SourceLanguage
      check parseSourceLanguage(token(v), got)
      check got == v
    for v in TargetIsa:
      var got: TargetIsa
      check parseTargetIsa(token(v), got)
      check got == v
    for v in Toolchain:
      var got: Toolchain
      check parseToolchain(token(v), got)
      check got == v
    for v in RecordingApproach:
      var got: RecordingApproach
      check parseRecordingApproach(token(v), got)
      check got == v

  test "an unrecognised token returns false and does not mutate the output":
    # Totality is the property.  The recognition wire format made the same
    # choice deliberately (`src/ct/utilities/target_recognition.nim:93-95`):
    # an unknown enum value is carried, never a parse error.
    var sl = slRust
    check(not parseSourceLanguage("no-such-language", sl))
    check sl == slRust
    var ti = tiWasm
    check(not parseTargetIsa("no-such-isa", ti))
    check ti == tiWasm
    var tc = tcCargo
    check(not parseToolchain("no-such-toolchain", tc))
    check tc == tcCargo
    var ra = raMcr
    check(not parseRecordingApproach("no-such-approach", ra))
    check ra == raMcr

  test "the empty string is not a valid token on any axis":
    var sl: SourceLanguage
    var ti: TargetIsa
    var tc: Toolchain
    var ra: RecordingApproach
    check(not parseSourceLanguage("", sl))
    check(not parseTargetIsa("", ti))
    check(not parseToolchain("", tc))
    check(not parseRecordingApproach("", ra))

  test "parsers accept surrounding whitespace and upper case":
    var sl: SourceLanguage
    check parseSourceLanguage("  RUST  ", sl)
    check sl == slRust
    var ra: RecordingApproach
    check parseRecordingApproach("\tMcr\n", ra)
    check ra == raMcr

# ---------------------------------------------------------------------------
# The relations between the axes
# ---------------------------------------------------------------------------

suite "the default relations are total and say something":

  test "only the sentinel language defaults to the unknown ISA":
    for v in SourceLanguage:
      if v == slUnknown:
        check fallbackTargetIsaForLanguage(v) == tiUnknown
      else:
        check fallbackTargetIsaForLanguage(v) != tiUnknown

  test "only the unknown ISA defaults to the unknown approach":
    for v in TargetIsa:
      if v == tiUnknown:
        check defaultRecordingApproach(v) == raUnknown
      else:
        check defaultRecordingApproach(v) != raUnknown

  test "Rust and C++ default to native, and reach wasm only by assessment":
    # This is the `LangRustWasm` / `LangCppWasm` conflation, decomposed: the
    # language is unchanged and the ISA moves.  Since LRS-5's second deletion
    # round the two members are gone and the assessment is the ONLY way to
    # reach `tiWasm`: `isWasmCargoProject`
    # (`src/ct/utilities/language_detection.nim`) reading `.cargo/config.toml`
    # for `wasm32`, or the `.wasm` extension (`KindWasmModule`).
    check fallbackTargetIsaForLanguage(slRust) == tiNative
    check fallbackTargetIsaForLanguage(slCpp) == tiNative
    check defaultRecordingApproach(tiNative) == raMcr
    check defaultRecordingApproach(tiWasm) == raVmEmulation

  test "wasm is an ISA, and its approach is the one every VM recorder uses":
    # An earlier two-axis design put `wasm` on the recording-mode axis.  Under
    # this model it is a target ISA whose approach is VM emulation -- the same
    # approach `nargo` and every blockchain recorder use.
    check defaultRecordingApproach(tiWasm) ==
      defaultRecordingApproach(tiEvm)
    check defaultRecordingApproach(tiWasm) ==
      defaultRecordingApproach(tiAcir)
    check defaultRecordingApproach(tiWasm) == raVmEmulation

  test "producesMaterializedTrace and isNativeReplay are disjoint and total":
    for v in RecordingApproach:
      check(not (producesMaterializedTrace(v) and isNativeReplay(v)))
    check producesMaterializedTrace(raInstrumentedRuntime)
    check producesMaterializedTrace(raVmEmulation)
    check isNativeReplay(raMcr)
    check isNativeReplay(raRr)
    check isNativeReplay(raTtd)
    # `raUnknown` is in neither, which is the honest answer for "not determined".
    check(not producesMaterializedTrace(raUnknown))
    check(not isNativeReplay(raUnknown))

# ---------------------------------------------------------------------------
# The assessment protocol
# ---------------------------------------------------------------------------

suite "the kind set obeys K1..K4":

  test "TargetFamily tokens are distinct and round-trip":
    var seen = initHashSet[string]()
    for v in TargetFamily:
      let t = token(v)
      check t.len > 0
      check t notin seen
      seen.incl(t)
      var got: TargetFamily
      check parseTargetFamily(t, got)
      check got == v

  test "K1: the family is its own typed field, and the specific set never contains one":
    # Q10: the family is not "the last element" of anything.  The wire
    # spelling of the specific set is sorted and deduplicated, and a family
    # token among the specific kinds is refused at the parse boundary.
    let bare = TargetKind(specific: @[], family: tfSingleFile)
    check bare.specificKinds() == newSeq[string]()
    let both = TargetKind(
      specific: @[KindFoundryProject, KindCargoProject, KindCargoProject],
      family: tfProjectDirectory)
    check both.specificKinds() == @[KindCargoProject, KindFoundryProject]
    var decoded: TargetKind
    var diag = ""
    check(not parseKind([KindCargoProject, "project-directory"],
                        "project-directory", decoded, diag))
    check "project-directory" in diag
    check "K1" in diag

  test "a kind round-trips through parseKind, as a SET":
    # Order in `specific` carries no meaning: a producer that spells the same
    # facts in another order decodes to an equal set.
    let original = TargetKind(
      specific: @[KindCargoProject, "cmake-project"],
      family: tfProjectDirectory)
    var decoded: TargetKind
    var diag = ""
    check parseKind(["cmake-project", KindCargoProject, "cmake-project"],
                    token(original.family), decoded, diag)
    check diag == ""
    check decoded.family == original.family
    check decoded.specificKinds() == original.specificKinds()

  test "K3: an unknown family fails loudly, naming the token, the kinds and the known families":
    var decoded: TargetKind
    var diag = ""
    check(not parseKind([KindCargoProject], "some-future-family", decoded, diag))
    check "some-future-family" in diag
    check KindCargoProject in diag
    check "project-directory" in diag   # the known-family list is quoted back
    check "unassessable" in diag

  test "K3: an empty family token is not silently the unknown family":
    var decoded = TargetKind(specific: @["x"], family: tfSingleFile)
    var diag = ""
    check(not parseKind([KindCargoProject], "", decoded, diag))
    check diag.len > 0
    check decoded.family == tfSingleFile   # untouched on failure

  test "K2: a consumer that knows exactly one specific kind gets it exactly":
    let k = TargetKind(
      specific: @[KindCargoProject, "cmake-project"],
      family: tfProjectDirectory)
    let r = k.resolveKind([KindCargoProject, KindNoirProject])
    check r.status == krExact
    check r.token == KindCargoProject
    check r.candidates.len == 0
    check r.skipped == @["cmake-project"]

  test "K2: a consumer that knows TWO specific kinds is told so, loudly, and picks nothing":
    # The decision Q10 was about: a crate that is also a CMake project is
    # both.  A consumer with code for both is not handed the first one — it
    # is handed both names and an empty token.
    let k = TargetKind(
      specific: @[KindCargoProject, "cmake-project"],
      family: tfProjectDirectory)
    let r = k.resolveKind(["cmake-project", KindCargoProject])
    check r.status == krAmbiguous
    check r.token == ""
    check r.candidates == @[KindCargoProject, "cmake-project"]   # producer order
    check r.skipped.len == 0
    let text = r.ambiguityDiagnostic("ct-native-replay/0.6.3")
    check KindCargoProject in text
    check "cmake-project" in text
    check "ct-native-replay/0.6.3" in text
    check "silently" in text
    # …and an unambiguous resolution has no diagnostic to print.
    check k.resolveKind([KindCargoProject]).ambiguityDiagnostic("p") == ""

  test "K2: the answer does not depend on the producer's spelling order":
    let ab = TargetKind(specific: @[KindCargoProject, "cmake-project"],
                        family: tfProjectDirectory)
    let ba = TargetKind(specific: @["cmake-project", KindCargoProject],
                        family: tfProjectDirectory)
    for understood in [@[KindCargoProject], @["cmake-project"],
                       @[KindCargoProject, "cmake-project"]]:
      check ab.resolveKind(understood).status == ba.resolveKind(understood).status
      check ab.resolveKind(understood).token == ba.resolveKind(understood).token

  test "version skew: a consumer that knows nothing still lands on the family":
    # This is the deployment state the protocol exists for.  The launcher and
    # the installed component are PATH-discovered, not bundled, so an older
    # consumer meeting a newer producer is normal.  It must get a usable answer
    # AND be able to say what it passed over.
    let k = TargetKind(
      specific: @["cmake-project", "cxx-project"],
      family: tfProjectDirectory)
    let nothing: seq[string] = @[]
    let r = k.resolveKind(nothing)
    check r.status == krFamilyOnly
    check r.token == "project-directory"
    check r.skipped == @["cmake-project", "cxx-project"]

  test "K4: `unassessable` refuses rather than degrading":
    let k = TargetKind(specific: @["some-licensed-thing"],
                       family: tfUnassessable)
    let r = k.resolveKind(["some-licensed-thing"])
    check r.status == krRefused
    check r.token == "unassessable"
    check r.skipped == @["some-licensed-thing"]
    # Even a consumer that *does* know the token must refuse: the producer said
    # no version-1 consumer may act on it.

  test "the family vocabulary reported in a diagnostic is the whole vocabulary":
    let listed = knownFamilyTokens()
    for v in TargetFamily:
      check token(v) in listed

suite "the assessment composes with codetracer.target-recognition.v1":

  test "the schema string is a v1 name and is in the supported list":
    check TargetAssessmentSchema == "codetracer.target-assessment.v1"
    check TargetAssessmentSchema in SupportedTargetAssessmentSchemas

  test "every `recognize` kind maps onto a family":
    # `codetracer-native-backend/src/recognize.rs:74-81` declares
    # `enum TargetKind { Executable, Script, Directory, Unknown }` with
    # `rename_all = "lowercase"`.
    var fam: TargetFamily
    check familyFromRecognitionKind("executable", fam)
    check fam == tfPrebuiltArtefact
    check familyFromRecognitionKind("script", fam)
    check fam == tfSingleFile
    check familyFromRecognitionKind("directory", fam)
    check fam == tfProjectDirectory
    check familyFromRecognitionKind("unknown", fam)
    check fam == tfUnknown

  test "an unrecognised `recognize` kind is not silently `unknown`":
    # `tfUnknown` means "the recognizer said it could not tell".  A kind this
    # build has never heard of is a different fact and must stay
    # distinguishable, or a newer recognizer's answer would be indistinguishable
    # from a failure.
    var fam = tfSingleFile
    check(not familyFromRecognitionKind("bundle", fam))
    check fam == tfSingleFile

  test "an assessment defaults to all-sentinel, which is safe":
    var a: TargetAssessment
    check a.schema == ""
    check a.kind.family == tfUnknown
    check a.kind.specific.len == 0
    check a.toolchain == tcUnknown
    check a.targetIsa == tiUnknown
    check a.recordingApproach == raUnknown
    check a.languages.len == 0
    # An empty census means "not computed", never "the target had no
    # languages" -- the same distinction `DetectedTarget.recognitionRan` draws
    # at `src/ct/utilities/language_detection.nim:180-193`.

suite "the project-marker kinds match the algorithm they were read from":

  test "every marker resolves and an unknown marker does not":
    for row in ProjectMarkerKinds:
      var kind = ""
      check projectKindForMarker(row.marker, kind)
      check kind == row.kind
    var kind = ""
    check(not projectKindForMarker("CMakeLists.txt", kind))
    check kind == ""

  test "the marker SET is `detectFolderLang`'s marker set; order is not a property":
    # `detectFolderLang` (`src/ct/utilities/language_detection.nim:28-65`) is
    # the assessment algorithm in embryo, and it throws its answer away by
    # returning a `Lang`: `Cargo.toml` becomes `LangRust` and the fact that the
    # target is a *cargo project* -- the fact that decides whether to build
    # before recording -- is lost at the return statement.
    #
    # This test used to pin the ORDER of the two lists as well, because
    # `detectFolderLang`'s first-match precedence was being reproduced.  Q10
    # (decided 2026-09-20) makes `specific` a set and `projectKindsForMarkers`
    # emit every marker present, so the precedence is no longer a property of
    # the table and is deliberately not asserted.  What must still hold is
    # MEMBERSHIP: the table and the algorithm read the same ten markers, so a
    # marker added to one and not the other is caught here.  The markers are
    # read out of the source so the constant cannot drift.
    let source = readTreeFile(LanguageDetectionPath,
      "extracting detectFolderLang's project markers")
    let startIdx = source.find("proc detectFolderLang")
    check startIdx >= 0
    let endIdx = source.find("\nconst LANGS*", startIdx)
    check endIdx > startIdx
    let body = source[startIdx ..< endIdx]

    var found: seq[string] = @[]
    var searchFrom = 0
    const Needle = "fileExists(folder / \""
    while true:
      let hit = body.find(Needle, searchFrom)
      if hit < 0: break
      let nameStart = hit + Needle.len
      let nameEnd = body.find('"', nameStart)
      check nameEnd > nameStart
      found.add(body[nameStart ..< nameEnd])
      searchFrom = nameEnd

    var expected: seq[string] = @[]
    for row in ProjectMarkerKinds:
      expected.add(row.marker)
    found.sort()
    expected.sort()
    check found.len == 10
    if found != expected:
      checkpoint("markers read from detectFolderLang: " & found.join(", "))
      checkpoint("markers in ProjectMarkerKinds:      " & expected.join(", "))
    check found == expected

  test "projectKindsForMarkers emits EVERY kind whose marker is present (Q10)":
    # The defect the set model removes: a crate that also carries a
    # `foundry.toml` is BOTH a cargo project and a foundry project.  Nothing
    # here picks; `ProjectMarkerKinds`'s order is not consulted for meaning.
    let both = projectKindsForMarkers(["foundry.toml", "src", "Cargo.toml"])
    check both.len == 2
    check KindCargoProject in both
    check KindFoundryProject in both
    check projectKindsForMarkers(["README.md"]).len == 0
    check projectKindsForMarkers(["Cargo.toml", "Cargo.toml"]) == @[KindCargoProject]
    # Every marker in the table is found when present, none is invented.
    var names: seq[string] = @[]
    for row in ProjectMarkerKinds: names.add(row.marker)
    let all = projectKindsForMarkers(names)
    check all.len == ProjectMarkerKinds.len
    for row in ProjectMarkerKinds:
      check row.kind in all

  test "toolchainForKind is one toolchain, or unknown with the collision named":
    check toolchainForKind(TargetKind(specific: @[KindCargoProject],
                                      family: tfProjectDirectory)) == tcCargo
    # cargo-project beside wasm-cargo-project is ONE toolchain, not two.
    let wasmCrate = TargetKind(specific: @[KindCargoProject, KindWasmCargoProject],
                               family: tfProjectDirectory)
    check toolchainForKind(wasmCrate) == tcCargo
    check toolchainAmbiguity(wasmCrate).len == 0
    # Two manifests, two toolchains: unknown, and both are named.
    let clash = TargetKind(specific: @[KindCargoProject, KindFoundryProject],
                           family: tfProjectDirectory)
    check toolchainForKind(clash) == tcUnknown
    check toolchainAmbiguity(clash).sorted == @[KindCargoProject, KindFoundryProject].sorted
    # A kind that names no toolchain names none.
    check toolchainForKind(TargetKind(specific: @["cmake-project"],
                                      family: tfProjectDirectory)) == tcUnknown
    check toolchainForKind(TargetKind(specific: @[KindNimScript],
                                      family: tfSingleFile)) == tcNimScriptVm
    check toolchainForKind(TargetKind(specific: @[KindNimSource],
                                      family: tfSingleFile)) == tcNimC

  test "targetIsaForAssessment refuses two ISA-deciding kinds (K2), and names them":
    let clash = TargetKind(specific: @[KindNimScript, KindNimSource],
                           family: tfSingleFile)
    check targetIsaForAssessment(clash, slNim) == tiUnknown
    check targetIsaAmbiguity(clash).sorted == @[KindNimScript, KindNimSource].sorted
    check targetIsaAmbiguity(TargetKind(specific: @[KindNimScript],
                                        family: tfSingleFile)).len == 0

# ---------------------------------------------------------------------------
# The decomposition of `Lang`
# ---------------------------------------------------------------------------

type
  Decomposition = tuple[language: SourceLanguage, isa: TargetIsa,
                        approach: RecordingApproach]

func decompose(lang: Lang): Decomposition =
  ## The PRODUCTION decomposition, `axesOfLang` (`src/common/common_lang.nim`),
  ## in the tuple shape the assertions below were written against.  This used
  ## to be a second, test-local exhaustive `case` over all 41 (then) values; LRS-2B
  ## moved it into production so the dispatch table could select on it, and
  ## it must not survive in both places.  Everything the local copy asserted
  ## is asserted of the production one.
  let a = axesOfLang(lang)
  (a.language, a.targetIsa, a.approach)

const
  MaterializedFlagExceptions = {LangNim, LangLua}
    ## The only two `Lang` values whose `usesMaterializedTraces` answer is
    ## not `producesMaterializedTrace(decompose(lang).approach)`.  Since
    ## LRS-2B the predicate is DERIVED from the decomposition and these two
    ## are its stated exceptions (`MaterializedSummaryExceptions` in
    ## production); this set is the test's independent statement of which
    ## two, so the production list cannot quietly grow.
    ##
    ## LRS-5's second deletion round RE-KEYED the production list from `Lang`
    ## onto the SOURCE LANGUAGE axis, because the predicate is now asked of a
    ## decoded storage cell (a language plus an approach) as well as of a
    ## summary.  This set stays keyed by `Lang` on purpose: it is the
    ## independent statement, and asserting the two against each other is what
    ## the first case below does.

suite "all 35 Lang values decompose onto the four axes":

  test "the production exception list is exactly the two this file expects":
    var listed: set[Lang] = {}
    for exception in MaterializedSummaryExceptions:
      let lang = langForSourceLanguage(exception.language)
      check lang notin listed   # no duplicates
      listed.incl(lang)
    check listed == MaterializedFlagExceptions
    # …and each exception genuinely disagrees with the derivation; an entry
    # that agreed would be dead and would hide a later real drift.
    for exception in MaterializedSummaryExceptions:
      let lang = langForSourceLanguage(exception.language)
      check exception.materialized !=
        producesMaterializedTrace(decompose(lang).approach)
      check usesMaterializedTraces(lang) == exception.materialized

  test "the exception list keys onto exactly one Lang each, both ways":
    # What makes the re-keying safe: the language axis is a BIJECTION with
    # `Lang` after the second deletion round, so `slNim` is `LangNim`'s
    # language and no one else's.  Before it, `slRust` belonged to both
    # `LangRust` and `LangRustWasm` and an exception keyed on the axis would
    # have silently covered two members.
    for exception in MaterializedSummaryExceptions:
      var holders: seq[Lang] = @[]
      for lang in Lang:
        if sourceLanguageOf(lang) == exception.language:
          holders.add(lang)
      check holders.len == 1
      check langForSourceLanguage(exception.language) == holders[0]

  test "the decomposition agrees with usesMaterializedTraces on all but two":
    var disagreements: seq[string] = @[]
    for lang in Lang:
      let d = decompose(lang)
      let derived = producesMaterializedTrace(d.approach)
      if derived != usesMaterializedTraces(lang):
        disagreements.add($lang & " (flag=" & $usesMaterializedTraces(lang) &
          ", derived=" & $derived & " from " & token(d.approach) & ")")
    if disagreements.len > 0:
      checkpoint("disagreements: " & disagreements.join("; "))
    check disagreements.len == MaterializedFlagExceptions.card

  test "exactly LangNim and LangLua disagree, and each for a recorded reason":
    var disagreeing: set[Lang] = {}
    for lang in Lang:
      if producesMaterializedTrace(decompose(lang).approach) !=
         usesMaterializedTraces(lang):
        disagreeing.incl(lang)
    check disagreeing == MaterializedFlagExceptions

    # LangNim: `true` while its per-value axes are `tiNative` / `raMcr`.  The
    # decision (`MaterializedSummaryExceptions`): both Nim flows import their
    # container with `traceKind = "db"`, so every Nim recording in the index
    # opens as a materialized trace, and the per-value decomposition cannot
    # see the extension that separates them -- the record-side assessment can.
    check usesMaterializedTraces(LangNim)
    check decompose(LangNim).approach == raMcr
    check(not producesMaterializedTrace(raMcr))

    # LangLua: `false` while its axes say instrumented runtime.  The decision:
    # no Lua recorder exists -- the table now DECLARES that rather than
    # falling to a silent `else` -- so no materialized Lua trace can exist and
    # the replay-side answer stays false.  The record side reaches the
    # declared arm through the assessment instead of attempting a native
    # build of a script, which is the gap the axes make visible.
    check(not usesMaterializedTraces(LangLua))
    check decompose(LangLua).approach == raInstrumentedRuntime
    let lua = recorderToolFor(selectorOfLang(LangLua))
    check(not lua.supported)
    check lua.isDeclared
    check "Lua" in lua.recorderLabel

  test "the two surviving conflated pairs collapse to one language each":
    # Four pairs until LRS-4; the Python and Ruby pairs lost their retired
    # half (`LangPython`, `LangRuby`), so `LangPythonDb` / `LangRubyDb` stand
    # alone as the language and there is nothing left to collapse.  The wasm
    # pair stays until LRS-5 (see the `Lang` doc comment) and still collapses.
    # This used to compare `LangRust` against `LangRustWasm` and `LangCpp`
    # against `LangCppWasm` -- same language, different ISA -- which is the
    # decomposition of a conflation that no longer exists.  LRS-5's second
    # deletion round deleted both wasm members, so the same property is
    # stated where the ISA now lives: the language's fallback is native and
    # the assessment is what moves it.
    check decompose(LangRust).language == slRust
    check decompose(LangRust).isa == fallbackTargetIsaForLanguage(slRust)
    check decompose(LangCpp).language == slCpp
    check decompose(LangCpp).isa == fallbackTargetIsaForLanguage(slCpp)
    check targetIsaForAssessment(
      TargetKind(specific: @[KindWasmCargoProject],
                 family: tfProjectDirectory), slRust) == tiWasm
    check targetIsaForAssessment(
      TargetKind(specific: @[KindWasmModule],
                 family: tfPrebuiltArtefact), slCpp) == tiWasm
    # Each source language that had a retired partner is now reached by
    # exactly one Lang value.
    for language in [slPython, slRuby]:
      var members: seq[Lang] = @[]
      for lang in Lang:
        if decompose(lang).language == language:
          members.add(lang)
      checkpoint(token(language) & " members: " & $members)
      check members.len == 1
    check decompose(LangPythonDb).approach == raInstrumentedRuntime
    check decompose(LangRubyDb).approach == raInstrumentedRuntime

  test "the value renderer's bracket vocabulary follows the source language, not the ISA (LRS-4)":
    # `tokenTextsFor` used to put `LangRustWasm` / `LangCppWasm` in the
    # generic `[`/`]` row while `LangRust` got `vec![` and `LangCpp`
    # `vector[`: a wasm-recorded Rust sequence rendered with the wrong
    # brackets because the ISA had been welded onto the language.  Two
    # members that decompose to the same source language must spell the
    # same brackets, and the wasm members must equal their plain siblings.
    # LRS-5's second deletion round deleted both wasm members, so the two
    # equalities this case used to assert (`tokenTextsFor(LangRustWasm) ==
    # tokenTextsFor(LangRust)` and its C++ twin) cannot be written any more --
    # and the defect they guarded cannot be reintroduced without adding a
    # second member for one language, which the bijection case below forbids.
    check tokenTextsFor(LangRust)[SeqOpen] == "vec!["
    check TOKEN_TEXTS[LangRust][SeqOpen] == "vec!["
    check tokenTextsFor(LangCpp)[SeqOpen] == "vector["
    for a in Lang:
      for b in Lang:
        if a != b and decompose(a).language == decompose(b).language and
           decompose(a).language != slUnknown:
          checkpoint($a & " vs " & $b)
          check tokenTextsFor(a) == tokenTextsFor(b)

  test "NO Lang value is a platform pseudo-language any more":
    # This case used to read "exactly the two platform pseudo-languages have
    # no source language" and assert `languageless == {LangPolkavm,
    # LangSolana}`: two members that named a chain and a VM, decomposed to
    # `slUnknown`, and had no file extension -- the evidence that they were
    # never languages.  LRS-5's second deletion round deleted both, so the set
    # is EMPTY and the evidence became the deletion.
    var languageless: set[Lang] = {}
    for lang in Lang:
      if lang != LangUnknown and decompose(lang).language == slUnknown:
        languageless.incl(lang)
    check languageless == {}
    # Every non-sentinel member now has a file extension, which is the same
    # evidence read the other way: a member with no extension was a target,
    # not a language.
    for lang in Lang:
      if lang != LangUnknown:
        check getExtension(lang).len > 0
    # The two ISAs themselves are untouched and still route (the recorder was
    # always a property of the ISA) -- `record_dispatch_test` asserts that.
    check token(tiSolanaSbf) == "solanasbf"
    check token(tiPolkaVm) == "polkavm"

  test "Lang and SourceLanguage are in BIJECTION after the second deletion round":
    # The property the whole four-axis campaign converges on, and the one that
    # makes `langForSourceLanguage` (and therefore the storage decoder's
    # language-axis summary) well-defined rather than order-dependent.  Before
    # this round it was false four times over: `slRust` was claimed by
    # `LangRust` AND `LangRustWasm`, `slCpp` by `LangCpp` AND `LangCppWasm`,
    # and `slUnknown` by `LangUnknown`, `LangPolkavm` AND `LangSolana`.
    var seen: set[SourceLanguage] = {}
    var count = 0
    for lang in Lang:
      let language = sourceLanguageOf(lang)
      checkpoint($lang & " -> " & token(language))
      check language notin seen
      seen.incl(language)
      check langForSourceLanguage(language) == lang
      inc count
    check count == 35
    # ...and the inverse is total over the languages `Lang` covers.
    for language in seen:
      check sourceLanguageOf(langForSourceLanguage(language)) == language

  test "the dispatch selector of a Lang value IS its decomposition":
    # `selectorOfLang` is the per-value projection the dispatch table accepts
    # as a fallback; it must be the same three axes, not a fourth table.
    for lang in Lang:
      let d = decompose(lang)
      let s = selectorOfLang(lang)
      check s.language == d.language
      check s.targetIsa == d.isa
      check s.approach == d.approach

  test "every SourceLanguage member is reachable from some Lang value":
    # The axis was derived from `Lang` and must not have grown a member that
    # nothing in the tree can produce.  34 real languages plus the sentinel.
    var langs: set[SourceLanguage] = {}
    for lang in Lang:
      langs.incl(decompose(lang).language)
    check slUnknown in langs
    check langs.card == ord(high(SourceLanguage)) - ord(low(SourceLanguage)) + 1
    var unreached: seq[string] = @[]
    for v in SourceLanguage:
      if v notin langs:
        unreached.add(token(v))
    if unreached.len > 0:
      checkpoint("source languages no Lang value maps to: " &
        unreached.join(", "))
    check unreached.len == 0

  test "every decomposed ISA agrees with the language's default, except by design":
    # A language's default ISA must be the one its `Lang` value decomposes to,
    # unless the `Lang` value exists precisely to name a non-default ISA.
    # The set is EMPTY since LRS-5's second deletion round: it held exactly
    # the four members that round deleted (`LangRustWasm`, `LangCppWasm`,
    # `LangPolkavm`, `LangSolana`), each of which existed to name a
    # non-default ISA.  Every surviving member decomposes to its language's
    # own default, and the ISA is moved only by the assessment.
    const NonDefaultIsaByDesign: set[Lang] = {}
    for lang in Lang:
      let d = decompose(lang)
      if lang notin NonDefaultIsaByDesign:
        if fallbackTargetIsaForLanguage(d.language) != d.isa:
          checkpoint($lang & ": default " & token(fallbackTargetIsaForLanguage(d.language)) &
            " but decomposed " & token(d.isa))
        check fallbackTargetIsaForLanguage(d.language) == d.isa

  test "every decomposed approach is the ISA's default, except by design":
    # The approach axis, pinned the same way as the ISA axis above.  Since
    # LRS-2B `axesOfLang` is production (the dispatch table selects on it),
    # so a wrong approach for one value is a routing change, not a test-local
    # slip -- and the review's mutation run found that `LangC -> raRr`
    # survived every suite: the native family is "not declared" under raMcr
    # and under raRr alike, so nothing downstream noticed.  The only `Lang`
    # values that exist to name a NON-default approach are the retired rr
    # pair; everything else must decompose to `defaultRecordingApproach` of
    # its own ISA.  Since LRS-4 deleted that pair the exception set is EMPTY
    # and every value decomposes to its ISA's default -- which is also what
    # makes `record_assessment.nim`'s non-default-approach branch a rule with
    # no current instance.
    const NonDefaultApproachByDesign: set[Lang] = {}
    for lang in Lang:
      let d = decompose(lang)
      if lang in NonDefaultApproachByDesign:
        check d.approach == raRr
        check d.approach != defaultRecordingApproach(d.isa)
      else:
        if defaultRecordingApproach(d.isa) != d.approach:
          checkpoint($lang & ": ISA " & token(d.isa) & " defaults to " &
            token(defaultRecordingApproach(d.isa)) & " but decomposed " &
            token(d.approach))
        check defaultRecordingApproach(d.isa) == d.approach
    # No Lang value names the retired native-replay approaches at all.
    for lang in Lang:
      check decompose(lang).approach notin {raRr, raTtd}

# ---------------------------------------------------------------------------
# The `.nim` / `.nims` pair: the canonical proof that the axes are independent
# ---------------------------------------------------------------------------

suite "one source language, two artefacts: .nim versus .nims":
  ## This pair is the reason the four axes exist, stated as an assertion.
  ##
  ## `Lang` cannot express it at all: BOTH files are recorded as `LangNim`
  ## (`src/ct/db_backend_record.nim` calls `importTrace(..., LangNim, ...)` on
  ## the `.nims` path at `:140` and reaches the MCR path at `:143-188` for
  ## `.nim`), so the one value that is supposed to decide the recorder is the
  ## same value for two different recorders.  `usesMaterializedTraces(LangNim)`
  ## is a single bit that has to answer for both, which is why it cannot be
  ## right for either.
  ##
  ## On the axes the pair separates cleanly, and it separates on THREE of the
  ## four: same language, different ISA, different toolchain, different
  ## recording approach.  That is the whole model in one example — a per-file
  ## property (the notation) held constant while every per-artefact property
  ## moves.
  ##
  ## The kinds are the assessment's answer, not a language: "this is a
  ## nimscript" versus "this is a Nim source file".

  let nimScript = TargetKind(specific: @[KindNimScript], family: tfSingleFile)
  let nimSource = TargetKind(specific: @[KindNimSource], family: tfSingleFile)

  test "the source language is the SAME for both":
    # Per-file axis: `.nim` and `.nims` are both Nim.  Anything that made these
    # differ would have re-created `LangRustWasm` with different letters.
    check toLangFromFilename("a.nim") == LangNim
    check toLangFromFilename("a.nims") == LangNim
    # And on the new axis, both are `slNim` -- the language is not what
    # distinguishes them.
    const lang = slNim
    check targetIsaForAssessment(nimScript, lang) != tiUnknown
    check targetIsaForAssessment(nimSource, lang) != tiUnknown

  test "the target ISA DIFFERS: a nimscript runs on the Nim VM":
    check targetIsaForAssessment(nimScript, slNim) == tiNimVm
    check targetIsaForAssessment(nimSource, slNim) == tiNative
    check targetIsaForAssessment(nimScript, slNim) !=
          targetIsaForAssessment(nimSource, slNim)

  test "the recording approach DIFFERS: the Nim VM emits the trace itself":
    # `nim e --trace:<...>/trace.ct` (`db_backend_record.nim:119-141`) -- the VM
    # writes the container, so this is an instrumented runtime and it DOES
    # produce a materialized trace.  The compiled path is `ct-mcr`, which is
    # native replay and does not.
    check recordingApproachForAssessment(nimScript, slNim) ==
          raInstrumentedRuntime
    check recordingApproachForAssessment(nimSource, slNim) == raMcr
    check producesMaterializedTrace(recordingApproachForAssessment(nimScript, slNim))
    check(not producesMaterializedTrace(
      recordingApproachForAssessment(nimSource, slNim)))
    check isNativeReplay(recordingApproachForAssessment(nimSource, slNim))
    check(not isNativeReplay(recordingApproachForAssessment(nimScript, slNim)))

  test "the toolchains are two distinct members, both already named":
    # `tcNimScriptVm` was in the axis from the start; `tcNimC` is its pair.
    # Nothing derives the toolchain yet -- this asserts only that the axis can
    # say it, which is what `Lang` could not.
    check tcNimScriptVm != tcNimC
    check token(tcNimScriptVm) == "nimscriptvm"
    check token(tcNimC) == "nimc"

  test "no function of SourceLanguage alone could have answered this":
    # The signature defect, as an assertion.  `fallbackTargetIsaForLanguage` is
    # total over `SourceLanguage` and therefore returns ONE answer for `slNim`,
    # while the two artefacts genuinely have two ISAs.  So the fallback is
    # necessarily wrong for one of them -- which is why it is named a fallback
    # and why the assessment-derived path is the primary one.
    let fallback = fallbackTargetIsaForLanguage(slNim)
    let scriptIsa = targetIsaForAssessment(nimScript, slNim)
    let sourceIsa = targetIsaForAssessment(nimSource, slNim)
    check scriptIsa != sourceIsa
    check (fallback == scriptIsa) != (fallback == sourceIsa)

  test "an assessment with no specific kind falls back to the language":
    # The fallback is reachable and does what it says: a bare family with no
    # specific token has nothing to override with.
    let bare = TargetKind(specific: @[], family: tfSingleFile)
    check targetIsaForAssessment(bare, slNim) ==
          fallbackTargetIsaForLanguage(slNim)
    check targetIsaForAssessment(bare, slRust) ==
          fallbackTargetIsaForLanguage(slRust)

  test "an unknown specific kind does not override, it defers":
    # Forward compatibility: a kind this build has never heard of must not
    # break the derivation, and must not silently become `tiUnknown`.
    let future = TargetKind(specific: @["some-future-kind"],
                            family: tfSingleFile)
    check targetIsaForAssessment(future, slNim) ==
          fallbackTargetIsaForLanguage(slNim)
    check targetIsaForAssessment(future, slNim) != tiUnknown

  test "the wasm pair decomposes the same way, on the same axis":
    # `LangRustWasm` is the same defect as `.nims`, one axis over: one language,
    # two ISAs, decided by the assessment rather than by the file's notation.
    let wasmCrate = TargetKind(specific: @[KindWasmCargoProject],
                               family: tfProjectDirectory)
    let plainCrate = TargetKind(specific: @[KindCargoProject],
                                family: tfProjectDirectory)
    check targetIsaForAssessment(wasmCrate, slRust) == tiWasm
    check targetIsaForAssessment(plainCrate, slRust) == tiNative
    check recordingApproachForAssessment(wasmCrate, slRust) == raVmEmulation
    check recordingApproachForAssessment(plainCrate, slRust) == raMcr

  test "tiNimVm is a first-class ISA: token, parse, and both predicates":
    # Knock-on checks for the new member, so it cannot be half-added.
    check token(tiNimVm) == "nimvm"
    var got: TargetIsa
    check parseTargetIsa("nimvm", got)
    check got == tiNimVm
    check parseTargetIsa("  NimVM  ", got)   # the parser strips and lowercases
    check got == tiNimVm
    check defaultRecordingApproach(tiNimVm) == raInstrumentedRuntime
    check defaultRecordingApproach(tiNimVm) != raUnknown
    # It must not collide with a reserved source-language token.
    for reserved in ReservedSourceLanguageTokens:
      check token(tiNimVm) != reserved

  test "GDScript is a first-class language AND a first-class ISA":
    # The same knock-on checks for the GDScript pair, so neither half can be
    # half-added.  Both are needed and they are NOT the same axis: `slGdScript`
    # is what a `.gd` FILE is written in, `tiGdScriptVm` is the machine that
    # runs it, and the Godot process hosting that machine is `tiNative` — the
    # two altitudes of Mixed-Trace-GDScript.md §1.
    check token(slGdScript) == "gdscript"
    check token(tiGdScriptVm) == "gdscriptvm"
    var gotLang: SourceLanguage
    check parseSourceLanguage("gdscript", gotLang)
    check gotLang == slGdScript
    var gotIsa: TargetIsa
    check parseTargetIsa("  GDScriptVM  ", gotIsa)   # strips and lowercases
    check gotIsa == tiGdScriptVm

    # The engine's own VM emits the container, so the approach is the
    # instrumented-runtime one and the trace it produces is materialized.
    check fallbackTargetIsaForLanguage(slGdScript) == tiGdScriptVm
    check defaultRecordingApproach(tiGdScriptVm) == raInstrumentedRuntime
    check producesMaterializedTrace(defaultRecordingApproach(tiGdScriptVm))
    check(not isNativeReplay(defaultRecordingApproach(tiGdScriptVm)))

    # `tiInterpreted`'s list is closed on purpose; a new substrate gets its own
    # value rather than being filed there.  Assert GDScript took that route.
    check decompose(LangGdScript).isa != tiInterpreted
    check decompose(LangGdScript).isa != tiNative
    for reserved in ReservedSourceLanguageTokens:
      check token(slGdScript) != reserved
      check token(tiGdScriptVm) != reserved

# ---------------------------------------------------------------------------
# SUPPORTED_LANGS: derived from the axes, pinned against the dispatch table
# ---------------------------------------------------------------------------

suite "SUPPORTED_LANGS is recorderToolFor's domain plus the native family (LRS-3)":
  ## The design's derivation for the language list (§6.3) is "every language
  ## with a supported (language, defaultMode) pair, which is `recorderToolFor`'s
  ## domain plus the native family".  `isSupportedLang` (`common_lang.nim`)
  ## states that on the AXES so the JS front end can evaluate it; this suite
  ## is what keeps it honest: `recorderToolFor` is the authority on which
  ## recorders exist, and the two are compared member for member over all 39
  ## values.  A recorder that lands (`supported: false` -> `true`) without
  ## `DeclaredUnsupportedLangs` losing the member fails here, as does the
  ## reverse.

  proc derivedFromDispatch(lang: Lang): bool =
    ## The derivation, evaluated on the dispatch table itself: supported by a
    ## declared recorder, OR in the native family (a selector the table does
    ## not describe at all) -- less the sentinel, which is also undeclared.
    let tool = recorderToolFor(selectorOfLang(lang))
    if lang == LangUnknown: false
    elif tool.supported: true
    else: not tool.isDeclared

  test "isSupportedLang agrees with recorderToolFor on every one of the 35 values":
    var disagreements: seq[string] = @[]
    for lang in Lang:
      if isSupportedLang(lang) != derivedFromDispatch(lang):
        disagreements.add($lang & " (axes say " & $isSupportedLang(lang) &
          ", dispatch table says " & $derivedFromDispatch(lang) & ")")
    if disagreements.len > 0:
      checkpoint("disagreements: " & disagreements.join("; "))
    check disagreements.len == 0

  test "the declared-unsupported set is exactly the table's non-retired `supported: false` arms":
    # Members whose axes name a recorder the table DECLARES but does not
    # support.  (Until LRS-4 `LangPython`/`LangRuby` were declared-unsupported
    # too, but by `retiredNativeReplayTool` on the approach axis, which
    # `isSupportedLang` excludes as `raRr`; the filter below is kept so a
    # member that ever decomposes to a retired approach again is excluded the
    # same way rather than landing in this set.)
    var expected: set[Lang] = {}
    for lang in Lang:
      let tool = recorderToolFor(selectorOfLang(lang))
      if tool.isDeclared and not tool.supported and
         axesOfLang(lang).approach notin {raRr, raTtd}:
        expected.incl(lang)
    check expected == DeclaredUnsupportedLangs
    check DeclaredUnsupportedLangs == {LangLua, LangGdScript}

  test "the native family is exactly the undeclared, non-sentinel members":
    var native: set[Lang] = {}
    for lang in Lang:
      let tool = recorderToolFor(selectorOfLang(lang))
      if not tool.isDeclared and lang != LangUnknown:
        native.incl(lang)
    for lang in native:
      check axesOfLang(lang).approach == raMcr
      check axesOfLang(lang).targetIsa == tiNative
      check isSupportedLang(lang)
    check LangNim notin native     # Nim IS declared: ct-mcr
    check LangUnknown notin native

  test "the list is the predicate over the enum, in declaration order, 32 long":
    var expected: seq[Lang] = @[]
    for lang in Lang:
      if isSupportedLang(lang):
        expected.add(lang)
    check SUPPORTED_LANGS == expected
    # 36 after LRS-3; 32 since LRS-5's second deletion round removed four
    # SUPPORTED members (`LangRustWasm`, `LangCppWasm`, `LangPolkavm`,
    # `LangSolana` -- each had a `recorderToolFor` arm with `supported: true`).
    # Nothing became unrecordable: wazero still records a wasm module, and the
    # Solana / PolkaVM recorders are still selected, by their ISA rather than
    # by a `Lang`.  `record_dispatch_test` asserts both routes.
    check SUPPORTED_LANGS.len == 32
    # The three defects of the two hand-kept lists (design §1.2(e)), closed:
    check LangPythonDb in SUPPORTED_LANGS
    check LangJavascript in SUPPORTED_LANGS
    check LangGdScript notin SUPPORTED_LANGS   # the old core list offered it
    check LangUnknown notin SUPPORTED_LANGS

  test "the picker folds same-name members and is order-blind":
    # One entry per `toCLang` name, each in SUPPORTED_LANGS, and the
    # representative of a conflated pair is the plain member.
    var names: seq[string] = @[]
    for lang in LANG_PICKER_LANGS:
      check lang in SUPPORTED_LANGS
      check toCLang(lang) notin names
      names.add(toCLang(lang))
    for lang in SUPPORTED_LANGS:
      check toCLang(lang) in names
    # The FOLD IS NOW A NO-OP, which is what LRS-5's second deletion round
    # promised: with the wasm pair gone no two supported members share a
    # `toCLang` name, so the picker is exactly `SUPPORTED_LANGS`.  The fold is
    # kept because it is the rule that keeps the dropdown free of duplicate
    # `value` attributes, and a rule with no current instance is not dead.
    check LANG_PICKER_LANGS.len == SUPPORTED_LANGS.len
    for lang in SUPPORTED_LANGS:
      check lang in LANG_PICKER_LANGS
    check LangRust in LANG_PICKER_LANGS
    check LangCpp in LANG_PICKER_LANGS
    # The representative rule reads the fallback ISA, never the ordinal.
    for lang in LANG_PICKER_LANGS:
      let a = axesOfLang(lang)
      if lang in {LangRust, LangCpp}:
        check a.targetIsa == fallbackTargetIsaForLanguage(a.language)

# ---------------------------------------------------------------------------
# The persisted four-axis encoding — milestone LRS-5, design §5.2-§5.4
# ---------------------------------------------------------------------------
#
# `recordings.lang` holds ONE of these tokens per recording since trace_index
# schema version 2.  It is user data with no fixture and no rebuild, so the
# obligations below are asserted rather than argued.  Design §5.4 lists six;
# they are restated here for four axes, and the numbering is kept so a reader
# can match them up:
#
#   1. the slugs are pairwise distinct          -> "slugs are ... pairwise distinct"
#   2. each axis's tokens are pairwise distinct -> already asserted, first suite
#   3. no slug and no axis token contains `-`   -> "no slug contains the separator"
#   4. decode(encode(v)) == v over the legal domain
#   5. decode("unknown") is the sentinel and NO OTHER hyphen-free token decodes
#   6. every legacy `$lang` name has a distinct target
#      -> `trace_index_migration_test.nim`, which is where the frozen map lives
#
# Obligation 5 is the one design §5.4 calls "most likely to be lost in
# implementation, because a decoder that 'helpfully' applies the default table
# to a bare slug passes every other obligation on this list".  It gets its own
# test and the widest sweep of any assertion in this file.

suite "the persisted four-axis encoding (LRS-5)":

  test "slugs are non-empty, lowercase and pairwise distinct (obligation 1)":
    var seen = initHashSet[string]()
    for v in SourceLanguage:
      let slug = storageSlug(v)
      checkpoint($v & " -> " & slug)
      check slug.len > 0
      check slug == slug.toLowerAscii
      check slug notin seen
      seen.incl(slug)

  test "no slug contains the separator (obligation 3)":
    ## Load-bearing, not cosmetic: the grammar joins four tokens with `-` and
    ## decodes by splitting on it, so a token containing one would make the
    ## split ambiguous and a four-axis cell unparseable.  The three other axes
    ## are covered by "no axis token contains a hyphen" in the first suite.
    for v in SourceLanguage:
      checkpoint($v & " -> " & storageSlug(v))
      check AxisSeparator notin storageSlug(v)

  test "the slug table is seeded from the extensions, and says where it is not":
    ## Design question Q2, confirmed by the coordinator 2026-09-21: the slug
    ## is the primary file extension where that extension is unique and
    ## non-empty, and something else — stated, not silent — where it is not.
    ## Spot-checked against `getExtensionName`, which is the seed table.
    check storageSlug(slPython) == "py"
    check storageSlug(slRust) == "rs"
    check storageSlug(slJavaScript) == "js"
    check storageSlug(slBash) == "sh"        # `.sh`, not `bash`
    check storageSlug(slFortran) == "f90"
    check storageSlug(slAda) == "adb"
    check storageSlug(slGdScript) == "gd"
    check storageSlug(slAiken) == "ak"
    check storageSlug(slCadence) == "cdc"
    # And the storage vocabulary is NOT the wire/CLI one — that is the cost
    # Q2 accepts, and it is asserted so nobody "unifies" them by accident.
    check storageSlug(slPython) != token(slPython)
    check token(slPython) == "python"

  test "`midenasm` is the Miden slug, and `masm`/`gas`/`nasm` stay unspent":
    ## Design Q4a, decided by the user.  `getExtensionName(LangMasm)` IS
    ## `masm`, so this is the one row where the seed table is deliberately
    ## overridden — the reason is in the inline comment beside the entry in
    ## `target_axes.nim` and in design §2.5.  Assembler DIALECT is a language
    ## distinction, the axis is expected to grow `gas` / `nasm` / a Microsoft
    ## `masm`, and a PERSISTED token cannot be renamed afterwards.
    check storageSlug(slMidenAsm) == "midenasm"
    check storageSlug(slMidenAsm) != "masm"
    check storageSlug(slAsm) == "asm"        # dialect-unspecified, on purpose
    for reserved in ReservedSourceLanguageTokens:
      checkpoint("reserved: " & reserved)
      for v in SourceLanguage:
        check storageSlug(v) != reserved
        check token(v) != reserved
      for v in TargetIsa: check token(v) != reserved
      for v in Toolchain: check token(v) != reserved
      for v in RecordingApproach: check token(v) != reserved
    check "masm" in ReservedSourceLanguageTokens
    check "gas" in ReservedSourceLanguageTokens
    check "nasm" in ReservedSourceLanguageTokens

  test "only the sentinel language spells its slug `unknown`":
    for v in SourceLanguage:
      if v == slUnknown:
        check storageSlug(v) == UnknownToken
      else:
        checkpoint($v)
        check storageSlug(v) != UnknownToken

  test "decode(encode(v)) == v over the whole four-axis domain (obligation 4)":
    ## The legal domain, stated precisely, because design §5.4 warns that a
    ## round-trip written over the wrong domain "asserts something false".
    ##
    ## Under the TWO-axis grammar the encoder was not total: `(Unknown, rtMcr)`
    ## and its four siblings had no spelling, so the test had to be written
    ## over 35 x 6 + 1 rather than over 36 x 6.  Under FOUR axes the encoder
    ## IS total — every tuple has a spelling, because the sentinel is a value
    ## on each axis rather than a combination that cannot occur — so the legal
    ## domain for `encode` is the whole product and this test says so.
    ##
    ## What has no spelling by decision is on the DECODE side instead, and it
    ## is exactly one string: the long `unknown-unknown-unknown-unknown` form
    ## of the value the bare `unknown` already names.  The next two tests
    ## cover it.
    var checked = 0
    var failures: seq[string] = @[]
    var encodings = initHashSet[string]()
    var collisions: seq[string] = @[]
    for language in SourceLanguage:
      for targetIsa in TargetIsa:
        for toolchain in Toolchain:
          for approach in RecordingApproach:
            let value = TargetAxes(language: language, targetIsa: targetIsa,
                                   toolchain: toolchain, approach: approach)
            let encoded = encodeAxesToken(value)
            if encoded in encodings:
              if collisions.len < 5: collisions.add(encoded)
            encodings.incl(encoded)
            var decoded: TargetAxes
            if not parseAxesToken(encoded, decoded):
              if failures.len < 5:
                failures.add(encoded & " did not decode at all")
            elif decoded != value:
              if failures.len < 5:
                failures.add(encoded & " decoded to " & encodeAxesToken(decoded))
            inc checked
    checkpoint("first failures: " & $failures)
    check failures.len == 0
    # Obligations 1 and 2 again, but over the JOINED token rather than per
    # axis: distinct tokens per axis would still be useless if the join could
    # collide.  A `HashSet` the same size as the product is that property.
    checkpoint("first collisions: " & $collisions)
    check collisions.len == 0
    check encodings.len == checked
    # 35 languages x 20 ISAs x 24 toolchains x 6 approaches.  Written out so
    # a member added to any axis without a thought about storage shows up
    # here as an arithmetic failure rather than as silence.
    check checked == 35 * 20 * 24 * 6

  test "the all-sentinel tuple is the bare token, and nothing else is":
    ## Design Q3, decided by the user: the sentinel is stored as the bare
    ## `unknown`, never `unknown-unknown-unknown-unknown`, and this is the ONE
    ## documented exception to the grammar.
    check encodeAxesToken(UnknownTargetAxes) == UnknownToken
    check encodeAxesToken(UnknownTargetAxes) == "unknown"
    var bareCount = 0
    for language in SourceLanguage:
      for targetIsa in TargetIsa:
        for toolchain in Toolchain:
          for approach in RecordingApproach:
            let encoded = encodeAxesToken(
              TargetAxes(language: language, targetIsa: targetIsa,
                         toolchain: toolchain, approach: approach))
            if AxisSeparator notin encoded:
              inc bareCount
              check encoded == UnknownToken
    check bareCount == 1

  test "the long all-sentinel spelling is refused — one value, one spelling":
    ## The combination that has no spelling BY DECISION, and therefore the
    ## one a round-trip test must not assert.  `unknown-unknown-unknown-unknown`
    ## is well-formed under the grammar and still refused, because the value
    ## it names already has a spelling and admitting a second would mean
    ## `encode` is no longer the inverse of `decode`.  Nothing produces it.
    var decoded: TargetAxes
    check(not parseAxesToken("unknown-unknown-unknown-unknown", decoded))
    check decoded == UnknownTargetAxes   # untouched: the default is all-sentinel
    # Every OTHER token that mentions the sentinel on some axis is fine.
    check parseAxesToken("unknown-polkavm-unknown-vm", decoded)
    check decoded.language == slUnknown
    check decoded.targetIsa == tiPolkaVm
    check decoded.toolchain == tcUnknown
    check decoded.approach == raVmEmulation
    check parseAxesToken("py-unknown-unknown-unknown", decoded)
    check decoded.language == slPython

  test "decode accepts NO hyphen-free token other than `unknown` (obligation 5)":
    ## **The assertion design §5.4 says is most likely to be lost**, and the
    ## milestone entry names it as such too: a decoder that "helpfully"
    ## applied the per-language default tables to a bare slug would pass every
    ## other obligation on the list, and would reintroduce exactly the
    ## persisted-default contract question Q1 exists to forbid — *a default
    ## may be applied at parse time; a default may never be IMPLIED by a
    ## persisted value*.
    ##
    ## The sweep is deliberately wide: every slug, every token of every axis,
    ## every `Lang` member's file extension, and a hand-written list of the
    ## shapes a well-meaning decoder would most plausibly admit.  If any of
    ## them decodes, the exception has generalised.
    var candidates = initHashSet[string]()
    for v in SourceLanguage:
      candidates.incl(storageSlug(v))
      candidates.incl(token(v))
    for v in TargetIsa: candidates.incl(token(v))
    for v in Toolchain: candidates.incl(token(v))
    for v in RecordingApproach: candidates.incl(token(v))
    for lang in Lang:
      candidates.incl(getExtensionName(lang))
      candidates.incl($lang)
      candidates.incl(langWireName(lang))
    for extra in ["", " ", "py ", " py", "PY", "Py", "rs", "c", "cpp", "js",
                  "rb", "nim", "go", "sh", "midenasm", "masm", "gas", "nasm",
                  "python", "javascript", "mcr", "rr", "ttd", "db", "wasm",
                  "native", "interpreted", "vm", "instrumented", "cargo",
                  "0", "20", "37", "LangPythonDb", "LangRust", "unknwon"]:
      candidates.incl(extra)

    var admitted: seq[string] = @[]
    var sweptHyphenFree = 0
    for candidate in candidates:
      if AxisSeparator in candidate:
        continue
      inc sweptHyphenFree
      var decoded: TargetAxes
      if parseAxesToken(candidate, decoded):
        admitted.add(candidate)
    checkpoint("hyphen-free tokens swept: " & $sweptHyphenFree)
    checkpoint("admitted: " & $admitted)
    # Anti-vacuity: the sweep must actually contain a lot of bare words, or
    # "nothing was admitted" would be true because nothing was tried.
    check sweptHyphenFree > 100
    check admitted == @[UnknownToken]

  test "a bare slug does not acquire defaults, stated for the obvious cases":
    ## The same property as the sweep above, written out for the four tokens
    ## a reader would most expect to "just work" — because the sweep proves it
    ## in aggregate and this proves it readably.  `py` must NOT become
    ## `(slPython, tiInterpreted, tcNone, raInstrumentedRuntime)` through
    ## `fallbackTargetIsaForLanguage` / `defaultRecordingApproach`, even
    ## though both of those functions exist and would answer.
    var decoded: TargetAxes
    for bare in ["py", "rs", "nim", "js"]:
      checkpoint("bare slug: " & bare)
      check(not parseAxesToken(bare, decoded))
    # The default tables DO exist and DO answer — which is the point: they
    # are applied at parse time by the CLI, never implied by storage.
    check fallbackTargetIsaForLanguage(slPython) == tiInterpreted
    check defaultRecordingApproach(tiInterpreted) == raInstrumentedRuntime

  test "wrong arity, unknown parts and stray case are all refused":
    var decoded: TargetAxes
    for bad in [
        "py-interpreted",                        # two axes: the old grammar
        "py-interpreted-none",                   # three
        "py-interpreted-none-instrumented-x",    # five
        "py-interpreted-none-",                  # empty trailing part
        "-py-interpreted-none",                  # empty leading part
        "py--interpreted-none",                  # empty middle part
        "zz-interpreted-none-instrumented",      # unknown slug
        "py-zzz-none-instrumented",              # unknown ISA
        "py-interpreted-zzz-instrumented",       # unknown toolchain
        "py-interpreted-none-zzz",               # unknown approach
        "PY-interpreted-none-instrumented",      # a cell is not case-folded
        "py-INTERPRETED-none-instrumented",
        " py-interpreted-none-instrumented",     # nor whitespace-stripped
        "py-interpreted-none-instrumented ",
        "python-interpreted-none-instrumented",  # the WIRE spelling, not the slug
        "LangPythonDb",                          # a schema-version-1 cell
        "21"]:                                   # a schema-version-0 cell
      checkpoint("refused: " & bad.escape())
      check(not parseAxesToken(bad, decoded))

  test "the four axes a Lang summarises round-trip through the column form":
    ## `storageAxesOfLang` / `langForStorageAxes` are the bridge between the
    ## `Lang` summary and the four-axis cell.  Every live member must survive
    ## the trip, and the toolchain must be the honest `tcUnknown` rather than
    ## a guess — a `Lang` names no toolchain.
    for lang in Lang:
      checkpoint($lang)
      let axes = storageAxesOfLang(lang)
      check axes.toolchain == tcUnknown
      let encoded = encodeAxesToken(axes)
      var decoded: TargetAxes
      check parseAxesToken(encoded, decoded)
      check decoded == axes
      let summary = langForStorageAxes(decoded)
      check summary.found
      check summary.lang == lang

  test "the Lang summary is injective on the three axes Lang has":
    ## What makes the round-trip above possible: no two `Lang` members
    ## decompose to the same (language, ISA, approach).  If two ever did, one
    ## of them would be unreachable from a stored cell and the column would
    ## silently relabel it.
    var seen = initHashSet[string]()
    for lang in Lang:
      let axes = axesOfLang(lang)
      let key = token(axes.language) & "/" & token(axes.targetIsa) & "/" &
                token(axes.approach)
      checkpoint($lang & " -> " & key)
      check key notin seen
      seen.incl(key)

  test "a token no live Lang summarises decodes, and is not mistaken for one":
    ## The shape LRS-5's second deletion round will make ordinary: a cell that
    ## says more than any `Lang` member can. `py-interpreted-unknown-rr` is
    ## the retired Python rr backend, whose member LRS-4 deleted.
    var decoded: TargetAxes
    check parseAxesToken("py-interpreted-unknown-rr", decoded)
    check decoded.language == slPython
    check decoded.approach == raRr
    check(not langForStorageAxes(decoded).found)
    # And a toolchain the summary cannot carry does not stop it resolving.
    var withToolchain: TargetAxes
    check parseAxesToken("rs-native-cargo-mcr", withToolchain)
    check withToolchain.toolchain == tcCargo
    let summary = langForStorageAxes(withToolchain)
    check summary.found
    check summary.lang == LangRust

# ---------------------------------------------------------------------------
# LRS-5, second deletion round — precondition (b): the recording carries the
# approach, and the SIX sites that branch on "is this materialized?" read it
# ---------------------------------------------------------------------------
#
# Until this round the question was asked of a `Lang` summary.  For Rust and
# C++ the summary could only answer it because two members existed —
# `LangRustWasm` and `LangCppWasm` — so deleting them without moving the sites
# would have registered every new wasm recording as native.  That is the
# silent mislabel the whole series exists to prevent, and these cases are what
# make it a test failure instead.
#
# Four of the six read `Trace` / the decoded cell and are asserted
# behaviourally here.  All six are asserted STRUCTURALLY by the source sweep
# at the end, because five of them are renderer code that no lane in this
# repository can execute.

suite "the recording's approach decides materialized replay, not its language":

  test "materializedReplayFor answers per RECORDING, where the summary could not":
    # The exact pair the wasm members existed for: one language, two routes.
    check materializedReplayFor(slRust, raVmEmulation)      # a wasm recording
    check(not materializedReplayFor(slRust, raMcr))         # a native one
    check materializedReplayFor(slCpp, raVmEmulation)
    check(not materializedReplayFor(slCpp, raMcr))
    # ...and the `Lang` summary of BOTH is now the same member, which is why
    # asking it would be answering the wrong question.
    check langForStorageAxes(
      TargetAxes(language: slRust, targetIsa: tiWasm, toolchain: tcUnknown,
                 approach: raVmEmulation)).lang == LangRust
    check langForStorageAxes(
      TargetAxes(language: slRust, targetIsa: tiNative, toolchain: tcUnknown,
                 approach: raMcr)).lang == LangRust
    check(not usesMaterializedTraces(LangRust))

  test "the two stated exceptions survive the move onto the axes":
    # `LangNim`: both flows import a db container, so a Nim MCR recording IS
    # materialized even though `producesMaterializedTrace(raMcr)` is false.
    check materializedReplayFor(slNim, raMcr)
    check(not producesMaterializedTrace(raMcr))
    # `LangLua`: no Lua recorder exists, so no materialized Lua trace can.
    check(not materializedReplayFor(slLua, raInstrumentedRuntime))
    check producesMaterializedTrace(raInstrumentedRuntime)
    # Every other language follows the approach with no exception at all.
    for language in SourceLanguage:
      if language in {slNim, slLua}:
        continue
      for approach in RecordingApproach:
        check materializedReplayFor(language, approach) ==
          producesMaterializedTrace(approach)

  test "SITE 4: loadCalltraceMode's default reads the cell, not a Lang":
    ## `trace_index.loadCalltraceMode` — the fourth of the four sites the
    ## milestone names, and the only one reachable from a CLI lane.
    let wasm = TargetAxes(language: slRust, targetIsa: tiWasm,
                          toolchain: tcUnknown, approach: raVmEmulation)
    let native = TargetAxes(language: slRust, targetIsa: tiNative,
                            toolchain: tcUnknown, approach: raMcr)
    check loadCalltraceMode("", wasm) == CalltraceMode.FullRecord
    check loadCalltraceMode("", native) == CalltraceMode.NoInstrumentation
    # Both summarise as `LangRust`, so a default taken from the summary would
    # answer `NoInstrumentation` for the wasm recording — the mislabel.
    check langForStorageAxes(wasm).lang == langForStorageAxes(native).lang
    # A stored value always wins over the default, unchanged.
    check loadCalltraceMode("CallKeyOnly", native) == CalltraceMode.CallKeyOnly

  test "SITES 1-3 and 5-6: a Trace answers from its own approach":
    ## `Trace.usesMaterializedTraces` is what `ui/repl.nim`,
    ## `services/debugger_service.nim` `lineStepJump`, `index/traces.nim`,
    ## `ui/calltrace.nim` and `ui/event_log.nim` call.  The predicate is
    ## backend-agnostic and is asserted here; the call sites are pinned
    ## structurally below.
    let wasmTrace = Trace(lang: LangRust, approach: raVmEmulation)
    let nativeTrace = Trace(lang: LangRust, approach: raMcr)
    check wasmTrace.usesMaterializedTraces
    check(not nativeTrace.usesMaterializedTraces)
    # The Nim exception, through a Trace.
    check Trace(lang: LangNim, approach: raMcr).usesMaterializedTraces
    # A Python recording made by the RETIRED rr backend: the cell says `raRr`
    # and the summary says `LangPythonDb`, whose own approach is instrumented.
    # The recording is what is asked, so the answer is "native replay".
    check(not Trace(lang: LangPythonDb, approach: raRr).usesMaterializedTraces)
    check usesMaterializedTraces(LangPythonDb)
    # A nil trace is false rather than a crash: no recording is open.
    check(not Trace(nil).usesMaterializedTraces)

  test "the six sites read the RECORDING, and none reads a Lang summary":
    ## Structural, because five of the six are renderer code no lane here can
    ## run.  Two of those five — the Call Trace pane and the Event Log — were
    ## the DECISION this milestone had to take rather than inherit: they set
    ## their own `usesMaterializedTracesTrace` from
    ## `toLangFromFilename(self.location.path)`, the ACTIVE FILE's language,
    ## and therefore already answered "native" for a wasm-recorded `.rs`
    ## before this round (LRS-4's review found it and left it open).  The
    ## decision: read the recording, like the other four.  This case is what
    ## pins it.
    const Sites = [
      ("src/frontend/ui/repl.nim", "data.trace.usesMaterializedTraces()"),
      ("src/frontend/services/debugger_service.nim",
       "self.data.trace.usesMaterializedTraces"),
      ("src/frontend/index/traces.nim", "data.trace.usesMaterializedTraces"),
      ("src/frontend/ui/calltrace.nim",
       "self.usesMaterializedTracesTrace = self.data.trace.usesMaterializedTraces"),
      ("src/frontend/ui/event_log.nim",
       "self.usesMaterializedTracesTrace = self.data.trace.usesMaterializedTraces"),
    ]
    for (relative, needle) in Sites:
      let path = RepoRoot / relative
      check fileExists(path)
      let source = readFile(path)
      checkpoint(relative & " must contain: " & needle)
      check needle in source
      # ...and must NOT ask the question of a `Lang` any more.  This is the
      # assertion that fails if someone "simplifies" a site back onto the
      # summary, which for Rust and C++ cannot answer it.
      checkpoint(relative & " must not ask a Lang summary")
      # The two OLD shapes, matched as code rather than as prose (the
      # comments at each site quote them on purpose, which is why the needles
      # include the surrounding syntax).
      check "self.data.trace.lang.usesMaterializedTraces" notin source
      check "data.trace.lang.usesMaterializedTraces()" notin source
      check "usesMaterializedTracesTrace = lang != LangUnknown" notin source
      check "= toLangFromFilename(self.location.path)" notin source
    # `loadCalltraceMode` takes axes, not a `Lang` — the fourth site, pinned
    # in the same shape as the other five.
    let traceIndex = readFile(RepoRoot / "src" / "common" / "trace_index.nim")
    check "proc loadCalltraceMode*(raw: string, axes: TargetAxes)" in traceIndex
    check "materializedReplayFor(axes.language, axes.approach)" in traceIndex
    # The one place a `Lang` may still be asked is a target that has NO
    # recording yet — `index/traces.nim`'s "would a recording of this file be
    # materialized?" branch.  Assert it is still there, so the case above is
    # not passing merely because the whole branch was deleted.
    let traces = readFile(RepoRoot / "src" / "frontend" / "index" / "traces.nim")
    check "toLangFromFilename(selectedRecordTarget).usesMaterializedTraces" in traces

  test "Trace.approach crosses the ct trace-metadata hop as a NAME":
    ## The LRS-1 rule, applied to the field this round adds: no boundary
    ## carries an enum's ordinal.  `Trace` is encoded with
    ## `json_serialization`, which writes an enum as `ord(value)` unless the
    ## type opts in — the exact defect LRS-4 found on `Trace.lang` and fixed
    ## in this same module.
    let traceIndex = readFile(RepoRoot / "src" / "common" / "trace_index.nim")
    check "serializesAsTextInJson(Lang)" in traceIndex
    check "serializesAsTextInJson(RecordingApproach)" in traceIndex
    # ...and the renderer decodes the name with `parseEnum`, not with a
    # hand-written ordinal map (the map LRS-4 deleted for `lang`).
    let metadata = readFile(RepoRoot / "src" / "frontend" / "trace_metadata.nim")
    check "parseEnum[RecordingApproach]" in metadata
    check "approach: 0" notin metadata

  test "detectTraceAxes states the wasm target on the ISA axis (precondition d)":
    ## `storage_and_import.detectTraceLang` used to answer `LangRustWasm` /
    ## `LangCppWasm` for a db-kind C/C++/Rust container — the third of the
    ## three writers of those members.  It now answers AXES, and the two
    ## facts it was carrying are on their own axes.
    let rustDb = detectTraceAxes("main.rs", @[], "db")
    check rustDb.language == slRust
    check rustDb.targetIsa == tiWasm
    check rustDb.approach == raVmEmulation
    check materializedReplayFor(rustDb.language, rustDb.approach)
    # An rr/MCR container of the same sources is untouched: native, and NOT
    # materialized.  A `detectTraceAxes` that answered a native ISA for the
    # db-kind case above would make these two indistinguishable, which is
    # exactly the mislabel.
    let rustRr = detectTraceAxes("main.rs", @[], "rr")
    check rustRr.language == slRust
    check rustRr.targetIsa == tiNative
    check rustRr.approach == raMcr
    check(not materializedReplayFor(rustRr.language, rustRr.approach))
    check rustDb != rustRr
    # C and C++ keep the ISA and gain an accurate language: the old answer
    # for BOTH was `LangCppWasm`, because there was no `LangCWasm` member.
    check detectTraceAxes("main.c", @[], "db").language == slC
    check detectTraceAxes("main.cpp", @[], "db").language == slCpp
    check detectTraceAxes("main.c", @[], "db").targetIsa == tiWasm
    # A prebuilt module names its ISA outright, whatever the trace kind.
    check detectTraceAxes("app.wasm", @[], "db").targetIsa == tiWasm
    check detectTraceAxes("app.wasm", @[], "rr").targetIsa == tiWasm
    # An interpreted language is unaffected by the db-kind rule.
    check detectTraceAxes("main.py", @[], "db") == storageAxesOfLang(LangPythonDb)
    # Nothing recognisable: the all-sentinel value, never a guess.
    check detectTraceAxes("a.out", @[], "db") == storageAxesOfLang(LangUnknown)
    # The `Lang` wrapper is the SUMMARY of the axes and nothing else.
    check detectTraceLang("main.rs", @[], "db") == LangRust
    check detectTraceLang("main.rs", @[], "rr") == LangRust

  test "recordTrace persists the OBSERVED axes when the caller has them":
    ## The other half of (b): the record side writes what it assessed, so a
    ## wasm recording's cell says wasm.  Asserted on the encoder rather than
    ## against a database, because the cell is what the replay side reads.
    let assessed = TargetAxes(language: slRust, targetIsa: tiWasm,
                              toolchain: tcUnknown, approach: raVmEmulation)
    check encodeAxesToken(assessed) == "rs-wasm-unknown-vm"
    # ...and what the `Lang` summary alone would have written instead, which
    # is a NATIVE cell: the silent mislabel, stated as the value it produces.
    check encodeAxesToken(storageAxesOfLang(LangRust)) == "rs-native-unknown-mcr"
    check encodeAxesToken(assessed) != encodeAxesToken(storageAxesOfLang(LangRust))
    # `recordDb` is where the assessed selector becomes those axes.
    let record = readFile(RepoRoot / "src" / "ct" / "db_backend_record.nim")
    check "axesArg = some(TargetAxes(language: sel.language, targetIsa: sel.targetIsa," in record
    let storage = readFile(RepoRoot / "src" / "ct" / "trace" / "storage_and_import.nim")
    check "axesArg: Option[TargetAxes] = none(TargetAxes)" in storage
    check "axesArg = some(axes))" in storage

  test "the assessment reads a .wasm extension as an ISA (precondition c)":
    ## The artefact fact, and the mutation target: make `assessKind` ignore
    ## the extension and the prebuilt-module route silently becomes native.
    check targetIsaForAssessment(
      TargetKind(specific: @[KindWasmModule], family: tfPrebuiltArtefact),
      slRust) == tiWasm
    check targetIsaForAssessment(
      TargetKind(specific: @[KindWasmModule], family: tfPrebuiltArtefact),
      slCpp) == tiWasm
    # It is an ISA-deciding kind, so meeting a second one is an ambiguity
    # rather than a silent pick (rule K2).
    check KindWasmModule in targetIsaAmbiguity(
      TargetKind(specific: @[KindWasmModule, KindNimSource],
                 family: tfSingleFile))
    check targetIsaForAssessment(
      TargetKind(specific: @[KindWasmModule, KindNimSource],
                 family: tfSingleFile), slNim) == tiUnknown
    # Without the kind the language fallback answers, which is native — the
    # mutation's outcome, stated so the case says what it is guarding.
    check targetIsaForAssessment(
      TargetKind(specific: @[], family: tfPrebuiltArtefact), slRust) == tiNative
