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
## The four axes are only worth having if the 41 values of `Lang` genuinely
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
import ../../ct/trace/recorder_dispatch

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
    # `Lang` puts `LangC` at ordinal 0, so a proc that falls off its end answers
    # "C" -- the defect documented at
    # `src/ct/utilities/language_detection.nim:125-146`.  A zero-initialised
    # value on these axes says "not determined".
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
    # language is unchanged and the ISA moves.  `isWasmCargoProject`
    # (`src/ct/utilities/language_detection.nim:18-26`) is the assessment step
    # that decides it today, by reading `.cargo/config.toml` for `wasm32`.
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
  ## to be a second, test-local exhaustive `case` over all 41 values; LRS-2B
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

suite "all 41 Lang values decompose onto the four axes":

  test "the production exception list is exactly the two this file expects":
    var listed: set[Lang] = {}
    for exception in MaterializedSummaryExceptions:
      check exception.lang notin listed   # no duplicates
      listed.incl(exception.lang)
    check listed == MaterializedFlagExceptions
    # …and each exception genuinely disagrees with the derivation; an entry
    # that agreed would be dead and would hide a later real drift.
    for exception in MaterializedSummaryExceptions:
      check exception.materialized !=
        producesMaterializedTrace(decompose(exception.lang).approach)
      check usesMaterializedTraces(exception.lang) == exception.materialized

  test "the decomposition agrees with usesMaterializedTraces on 39 of 41":
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

  test "the four conflated pairs collapse to one language each":
    check decompose(LangRust).language == decompose(LangRustWasm).language
    check decompose(LangRust).isa != decompose(LangRustWasm).isa
    check decompose(LangCpp).language == decompose(LangCppWasm).language
    check decompose(LangCpp).isa != decompose(LangCppWasm).isa
    check decompose(LangPython).language == decompose(LangPythonDb).language
    check decompose(LangPython).approach != decompose(LangPythonDb).approach
    check decompose(LangRuby).language == decompose(LangRubyDb).language
    check decompose(LangRuby).approach != decompose(LangRubyDb).approach

  test "exactly the two platform pseudo-languages have no source language":
    var languageless: set[Lang] = {}
    for lang in Lang:
      if lang != LangUnknown and decompose(lang).language == slUnknown:
        languageless.incl(lang)
    check languageless == {LangPolkavm, LangSolana}
    # And they are exactly the `Lang` values with no file extension, which is
    # the evidence that they were never languages.
    check getExtension(LangPolkavm).len == 0
    check getExtension(LangSolana).len == 0
    for lang in languageless:
      check decompose(lang).isa != tiUnknown

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
    const NonDefaultIsaByDesign = {LangRustWasm, LangCppWasm, LangPolkavm,
                                   LangSolana}
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
    # its own ISA.
    const NonDefaultApproachByDesign = {LangPython, LangRuby}
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
