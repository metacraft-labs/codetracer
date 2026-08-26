## target_axes_js_test.nim
##
## The **JS-backend half** of the placement requirement for
## `src/common/target_axes.nim` and `src/common/target_assessment.nim`.
##
## The requirement is that these modules sit below the ViewModels core and are
## reachable by every current and future front end: the Electron renderer, which
## is the JS backend, and the planned Nim TUI on `isonim-tui`, which is the
## native backend.  `src/tests/cli/target_axes_test.nim` proves the native half.
## Neither test alone proves the property — a type that only builds on JS
## defeats the whole point of the placement, and one that only builds natively
## is unreachable from the renderer.
##
## This file therefore does two jobs:
##
## 1. **Compiling at all is the assertion.** If either module ever grows a
##    `std/jsffi` import, an `os` call the JS backend cannot honour, or a
##    `cstring`/`string` confusion, `nim js` fails here.
## 2. It re-runs the behavioural properties that could plausibly differ between
##    backends — enum iteration, `set` membership, string comparison and
##    `seq` equality — rather than assuming the C-backend run covers them.
##
## Run by `just test-frontend-js`.

import
  std/[strutils, unittest],
  ../../common/target_axes,
  ../../common/target_assessment

suite "the axis modules build and behave on the JS backend":

  test "every axis token is non-empty and round-trips":
    for v in SourceLanguage:
      check token(v).len > 0
      var got: SourceLanguage
      check parseSourceLanguage(token(v), got)
      check got == v
    for v in TargetIsa:
      check token(v).len > 0
      var got: TargetIsa
      check parseTargetIsa(token(v), got)
      check got == v
    for v in Toolchain:
      check token(v).len > 0
      var got: Toolchain
      check parseToolchain(token(v), got)
      check got == v
    for v in RecordingApproach:
      check token(v).len > 0
      var got: RecordingApproach
      check parseRecordingApproach(token(v), got)
      check got == v

  test "the sentinel is ordinal 0 and spells `unknown` on every axis":
    check ord(slUnknown) == 0
    check ord(tiUnknown) == 0
    check ord(tcUnknown) == 0
    check ord(raUnknown) == 0
    check token(slUnknown) == UnknownToken
    check token(tiUnknown) == UnknownToken
    check token(tcUnknown) == UnknownToken
    check token(raUnknown) == UnknownToken

  test "the parsers are total on the JS backend too":
    var sl = slNim
    check(not parseSourceLanguage("no-such-language", sl))
    check sl == slNim
    var ra = raRr
    check(not parseRecordingApproach("", ra))
    check ra == raRr

  test "the default relations are total":
    for v in SourceLanguage:
      if v == slUnknown:
        check fallbackTargetIsaForLanguage(v) == tiUnknown
      else:
        check fallbackTargetIsaForLanguage(v) != tiUnknown
    for v in TargetIsa:
      if v == tiUnknown:
        check defaultRecordingApproach(v) == raUnknown
      else:
        check defaultRecordingApproach(v) != raUnknown

  test "a kind chain round-trips through the protocol type":
    let original = TargetKind(
      specific: @[KindCargoProject, "rust-project"],
      family: tfProjectDirectory)
    let wire = original.chain()
    check wire.len == 3
    check wire[wire.high] == "project-directory"
    var decoded: TargetKind
    var diag = ""
    check parseKindChain(wire, decoded, diag)
    check diag == ""
    check decoded.family == tfProjectDirectory
    check decoded.specific == @[KindCargoProject, "rust-project"]

  test "an unknown family fails loudly, naming the chain and the vocabulary":
    var decoded: TargetKind
    var diag = ""
    check(not parseKindChain(
      @["cmake-project", "some-future-family"], decoded, diag))
    check "some-future-family" in diag
    check "cmake-project" in diag
    for v in TargetFamily:
      check token(v) in diag

  test "version skew: a consumer that knows nothing lands on the family":
    let k = TargetKind(specific: @["cmake-project"],
                       family: tfProjectDirectory)
    let nothing: seq[string] = @[]
    let r = k.resolveKind(nothing)
    check r.status == krFamilyOnly
    check r.token == "project-directory"
    check r.skipped == @["cmake-project"]

  test "`unassessable` refuses even a consumer that knows the token":
    let k = TargetKind(specific: @["licensed-thing"], family: tfUnassessable)
    let r = k.resolveKind(@["licensed-thing"])
    check r.status == krRefused
    check r.token == "unassessable"

  test "every `recognize` kind maps onto a family, and no other does":
    var fam: TargetFamily
    check familyFromRecognitionKind("executable", fam)
    check fam == tfPrebuiltArtefact
    check familyFromRecognitionKind("script", fam)
    check fam == tfSingleFile
    check familyFromRecognitionKind("directory", fam)
    check fam == tfProjectDirectory
    check familyFromRecognitionKind("unknown", fam)
    check fam == tfUnknown
    fam = tfCommand
    check(not familyFromRecognitionKind("bundle", fam))
    check fam == tfCommand

  test "the project-marker table is readable from the JS backend":
    check ProjectMarkerKinds.len == 10
    var kind = ""
    check projectKindForMarker("Cargo.toml", kind)
    check kind == KindCargoProject
    check(not projectKindForMarker("CMakeLists.txt", kind))

  test "the schema constant is present":
    check TargetAssessmentSchema == "codetracer.target-assessment.v1"
    check TargetAssessmentSchema in SupportedTargetAssessmentSchemas
