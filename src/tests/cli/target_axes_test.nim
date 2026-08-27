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
## ## What the last suite pins, and why it is the important one
##
## The four axes are only worth having if the 41 values of `Lang` genuinely
## decompose onto them.  The last suite writes that decomposition out as an
## exhaustive `case` — so a new `Lang` member is a compile error here — and then
## checks it against `usesMaterializedTraces`, the one-bit projection the tree
## carries today.  It agrees on 39 of 41 values.  The two disagreements are
## named, explained and asserted individually, because each is a fact about the
## tree rather than an error in the decomposition:
##
## * `LangNim` is flagged materialized (`src/common/common_lang.nim:96`) while
##   its recorder is `ct-mcr` (`src/ct/trace/recorder_dispatch.nim:309-318`).
## * `LangLua` is flagged *not* materialized and has no recorder arm at all, so
##   the default relation's answer for an interpreted language is one the tree
##   cannot honour.  `src/ct/trace/native_backend_selection.nim:66-78` already
##   records this exact case: the GUI sends `--backend db` for a `.lua` script
##   and the core resolves it to `LangLua`, which does not use a materialized
##   trace.

import std/[os, sets, strutils, unittest]
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

suite "the kind chain obeys K1..K4":

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

  test "K1: a chain is never empty and always ends in the family token":
    let bare = TargetKind(specific: @[], family: tfSingleFile)
    check bare.chain() == @["single-file"]
    let deep = TargetKind(
      specific: @[KindCargoProject, "rust-project"],
      family: tfProjectDirectory)
    check deep.chain() ==
      @[KindCargoProject, "rust-project", "project-directory"]
    for v in TargetFamily:
      let k = TargetKind(specific: @["x"], family: v)
      let c = k.chain()
      check c.len == 2
      check c[c.high] == token(v)

  test "K1 round-trips through parseKindChain":
    let original = TargetKind(
      specific: @[KindCargoProject, "rust-project"],
      family: tfProjectDirectory)
    var decoded: TargetKind
    var diag = ""
    check parseKindChain(original.chain(), decoded, diag)
    check diag == ""
    check decoded.family == original.family
    check decoded.specific == original.specific

  test "K3: an empty chain fails loudly":
    var decoded: TargetKind
    var diag = ""
    let empty: seq[string] = @[]
    check(not parseKindChain(empty, decoded, diag))
    check diag.len > 0
    check "empty" in diag
    check "K1" in diag

  test "K3: a chain that does not end in a family token fails loudly, and the diagnostic names the chain and the known families":
    var decoded: TargetKind
    var diag = ""
    check(not parseKindChain(
      [KindCargoProject, "some-future-family"], decoded, diag))
    check "some-future-family" in diag
    check KindCargoProject in diag
    check "project-directory" in diag   # the known-family list is quoted back
    check "unassessable" in diag

  test "K3 is not silently repaired when the family is present but misplaced":
    # A producer that puts the family anywhere other than last has violated K1.
    # Searching the chain for *any* recognisable family would turn a protocol
    # bug into an invisible behaviour change, so the decoder refuses.
    var decoded: TargetKind
    var diag = ""
    check(not parseKindChain(
      ["project-directory", KindCargoProject], decoded, diag))
    check diag.len > 0

  test "K2: a consumer that knows the specific kind gets it exactly":
    let k = TargetKind(
      specific: @[KindCargoProject, "rust-project"],
      family: tfProjectDirectory)
    let r = k.resolveKind([KindCargoProject, KindNoirProject])
    check r.status == krExact
    check r.token == KindCargoProject
    check r.skipped.len == 0

  test "K2: a consumer that knows only the general kind degrades explicitly":
    let k = TargetKind(
      specific: @[KindCargoProject, "rust-project"],
      family: tfProjectDirectory)
    let r = k.resolveKind(["rust-project"])
    check r.status == krDegraded
    check r.token == "rust-project"
    check r.skipped == @[KindCargoProject]

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

  test "the marker list is `detectFolderLang`'s list, in `detectFolderLang`'s order":
    # `detectFolderLang` (`src/ct/utilities/language_detection.nim:28-65`) is
    # the assessment algorithm in embryo, and it throws its answer away by
    # returning a `Lang`: `Cargo.toml` becomes `LangRust` and the fact that the
    # target is a *cargo project* -- the fact that decides whether to build
    # before recording -- is lost at the return statement.
    #
    # Order is load-bearing there: the first marker that exists wins, so a
    # crate that is also a Foundry project is a Foundry project.  This test
    # reads the markers out of the source so the constant cannot drift away
    # from the algorithm it was derived from.
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

    if found != expected:
      checkpoint("markers read from detectFolderLang: " & found.join(", "))
      checkpoint("markers in ProjectMarkerKinds:      " & expected.join(", "))
    check found == expected

# ---------------------------------------------------------------------------
# The decomposition of `Lang`
# ---------------------------------------------------------------------------

type
  Decomposition = tuple[language: SourceLanguage, isa: TargetIsa,
                        approach: RecordingApproach]

func decompose(lang: Lang): Decomposition =
  ## Every one of the 41 current `Lang` values, on the four axes.
  ##
  ## This lives in the test, not in production, on purpose: this increment
  ## lands the types alongside `Lang` and migrates nothing.  Its job is to
  ## prove the decomposition is total and consistent, and to be the safety net
  ## for the increment that does migrate.
  ##
  ## An exhaustive `case`, so a new `Lang` member is a compile error here.
  case lang
  of LangC: (slC, tiNative, raMcr)
  of LangCpp: (slCpp, tiNative, raMcr)
  of LangRust: (slRust, tiNative, raMcr)
  of LangNim: (slNim, tiNative, raMcr)
  of LangGo: (slGo, tiNative, raMcr)
  of LangPascal: (slPascal, tiNative, raMcr)
  of LangFortran: (slFortran, tiNative, raMcr)
  of LangD: (slD, tiNative, raMcr)
  of LangCrystal: (slCrystal, tiNative, raMcr)
  of LangLean: (slLean, tiNative, raMcr)
  of LangJulia: (slJulia, tiNative, raMcr)
  of LangAda: (slAda, tiNative, raMcr)
  # `LangPython` and `LangRuby` are the retired rr/gdb backends.  On these axes
  # they are the *same language* as their `Db` siblings with a different
  # recording approach, which is the whole point: the pair was never two
  # languages.
  of LangPython: (slPython, tiInterpreted, raRr)
  of LangRuby: (slRuby, tiInterpreted, raRr)
  of LangRubyDb: (slRuby, tiInterpreted, raInstrumentedRuntime)
  of LangJavascript: (slJavaScript, tiInterpreted, raInstrumentedRuntime)
  of LangLua: (slLua, tiInterpreted, raInstrumentedRuntime)
  of LangAsm: (slAsm, tiNative, raMcr)
  of LangNoir: (slNoir, tiAcir, raVmEmulation)
  # The wasm pair: same language, different ISA.
  of LangRustWasm: (slRust, tiWasm, raVmEmulation)
  of LangCppWasm: (slCpp, tiWasm, raVmEmulation)
  of LangPythonDb: (slPython, tiInterpreted, raInstrumentedRuntime)
  of LangUnknown: (slUnknown, tiUnknown, raUnknown)
  of LangBash: (slBash, tiInterpreted, raInstrumentedRuntime)
  of LangZsh: (slZsh, tiInterpreted, raInstrumentedRuntime)
  of LangSolidity: (slSolidity, tiEvm, raVmEmulation)
  of LangMasm: (slMidenAsm, tiMidenVm, raVmEmulation)
  of LangSway: (slSway, tiFuelVm, raVmEmulation)
  of LangMove: (slMove, tiMoveVm, raVmEmulation)
  # `LangPolkavm` and `LangSolana` name a VM and a chain.  Neither is a
  # notation anyone writes a file in -- which is exactly why they are the two
  # `Lang` members with an empty `getExtension` entry
  # (`src/common/lang.nim:113,120`).  Their source language is genuinely
  # unknown until a file is looked at; the target ISA is what they were
  # standing in for.
  of LangPolkavm: (slUnknown, tiPolkaVm, raVmEmulation)
  of LangCairo: (slCairo, tiCairoVm, raVmEmulation)
  of LangCircom: (slCircom, tiCircomWitness, raVmEmulation)
  of LangLeo: (slLeo, tiAleoVm, raVmEmulation)
  of LangTolk: (slTolk, tiTonVm, raVmEmulation)
  of LangAiken: (slAiken, tiPlutus, raVmEmulation)
  of LangCadence: (slCadence, tiFlowVm, raVmEmulation)
  of LangSolana: (slUnknown, tiSolanaSbf, raVmEmulation)
  of LangElixir: (slElixir, tiBeam, raInstrumentedRuntime)
  of LangErlang: (slErlang, tiBeam, raInstrumentedRuntime)
  of LangPhp: (slPhp, tiInterpreted, raInstrumentedRuntime)
  # GDScript, decided from the recorder spec rather than by copying a
  # neighbouring scripting language:
  #
  # * `slGdScript` — `.gd` is a notation people write files in, so it is a real
  #   member of the language axis.  `slUnknown` is reserved for the two platform
  #   pseudo-languages (asserted below), and GDScript is not one of them.
  # * `tiGdScriptVm` — `.gd` is compiled to bytecode and executed by
  #   `GDScriptFunction::call` in `modules/gdscript/gdscript_vm.cpp`
  #   (GDScript-Recorder.md, "The interpreter is a single, well-bounded
  #   function" / "The blocked single-step route"), which is a VM with its own
  #   opcodes and not one of the seven runtimes `tiInterpreted` closes over.
  #   The ISA axis has to separate it from the Godot HOST for the mixed-trace
  #   design to be expressible at all: Mixed-Trace-GDScript.md §1 makes the
  #   native altitude the patched Godot recorded by `ct-mcr` and the VM altitude
  #   the GDScript trace the engine emits.
  # * `raInstrumentedRuntime` — the recorder IS the runtime.  The patched engine
  #   links `libcodetracer_trace_writer.a` and calls the writer's chokepoints
  #   itself (Mixed-Trace-GDScript.md §2; GDScript-Recorder.md "The writer
  #   (link, do not reimplement)").  Nothing emulates the artefact, so this is
  #   not `raVmEmulation`.
  #
  # This makes `producesMaterializedTrace` agree with
  # `usesMaterializedTraces(LangGdScript)`, which is why GDScript is NOT a third
  # member of `MaterializedFlagExceptions` below.  That CodeTracer does not ship
  # the patched engine yet is a fact about the RECORDER's availability, not
  # about these axes, and it is asserted where it belongs: `recorderToolFor`'s
  # `LangGdScript` arm (`src/ct/trace/recorder_dispatch.nim`), pinned by
  # `record_dispatch_test.nim`.
  of LangGdScript: (slGdScript, tiGdScriptVm, raInstrumentedRuntime)

const
  MaterializedFlagExceptions = {LangNim, LangLua}
    ## The only two `Lang` values whose `usesMaterializedTraces` flag disagrees
    ## with `producesMaterializedTrace(decompose(lang).approach)`.  Both
    ## disagreements are facts about the tree, asserted individually below.

suite "all 41 Lang values decompose onto the four axes":

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

    # LangNim: flagged materialized (`common_lang.nim:96`) while its recorder
    # is `ct-mcr` (`recorder_dispatch.nim:309-318`).  Under one bit that is a
    # contradiction; on these axes Nim is `tiNative` and therefore `raMcr`, and
    # the CTFS container MCR writes is a property of MCR, not of Nim.
    check usesMaterializedTraces(LangNim)
    check decompose(LangNim).approach == raMcr
    check(not producesMaterializedTrace(raMcr))

    # LangLua: flagged NOT materialized, and it has no recorder arm anywhere in
    # `recorder_dispatch.nim`.  The default relation answers "an interpreted
    # language is recorded by instrumenting its runtime", which is right in
    # general and unavailable for Lua in particular -- a gap the axes make
    # visible instead of hiding behind a `false`.
    # `native_backend_selection.nim:66-78` records the same case from the other
    # side: the GUI sends `--backend db` for a `.lua` script and the core
    # resolves it to `LangLua`, which does not use a materialized trace.
    check(not usesMaterializedTraces(LangLua))
    check decompose(LangLua).approach == raInstrumentedRuntime
    check(not recorderToolFor(LangLua).supported)

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
