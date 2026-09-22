import
  std/[options, os, strutils, tables],
  ../../common/[lang, config],
  ./target_recognition

export target_recognition

# detect the lang of the source for a binary
#   based on folder/filename/files and if not possible on symbol patterns
#   in the binary
#   for scripting languages on the extension
#   for folders, we search for now for a special file
#   like `Nargo.toml`
#   just analyzing debug info might be best
#   TODO: a project can have sources in multiple languages
#   so the assumption it has a single one is not always valid
#   but for now are not reforming that yet
type
  CargoProjectAssessment* = object
    ## What a `Cargo.toml` directory IS, as three facts on three axes.
    ##
    ## `isWasmCargoProject` used to answer this question as a single `bool`,
    ## and before LRS-5's second deletion round it answered it as a single
    ## `Lang` value, `LangRustWasm` -- *"kind = cargo project, source language
    ## = Rust, target ISA = wasm"* compressed into one enum member, which is
    ## design 1.1's conflation in miniature.  LRS-2P separates them: the three
    ## facts travel on the three axes that own them, and nothing downstream
    ## has to unpack a member name to recover one of them.
    ##
    ## (Milestone rule 7: LRS-2P's deliverable was written against the
    ## pre-LRS-4 tree and says this proc "stops answering `LangRustWasm`".
    ## LRS-5's second deletion round had already taken the `Lang` away and
    ## left a `bool`; the deliverable is met by answering the triple, which is
    ## what the text asked for and what the bool still was not.)
    present*: bool
      ## Is there a `Cargo.toml` here at all?  `false` makes every other field
      ## meaningless -- distinguishing "not a cargo project" from "a native
      ## cargo project" is why this is not an `Option[TargetIsa]`.
    kind*: TargetKind
      ## `cargo-project`, plus `wasm-cargo-project` when the marker says so.
      ## BOTH, not one: a wasm crate is still a cargo crate, and Q10's set
      ## model exists so a producer never has to choose between two true
      ## facts.  `toolchainForKind` reads the pair as ONE toolchain (`tcCargo`)
      ## and `toolchainAmbiguity` is empty for it, which is what says the pair
      ## is not being read as a collision.
    sourceLanguage*: SourceLanguage
      ## `slRust`.  A property of the FILES, and the same for both flavours --
      ## which is exactly why it cannot carry the ISA.
    targetIsa*: TargetIsa
      ## `tiWasm` or `tiNative`.  A property of the ARTEFACT.

proc cargoTargetIsa(folder: string): TargetIsa =
  ## The ISA a cargo project builds for, read from `.cargo/config.toml`.
  ##
  ## The same file and the same `wasm32` substring `isWasmCargoProject` read
  ## before LRS-2P: the evidence has not changed, only what is done with it.
  ## One reader, so the marker cannot be interpreted two ways in one build.
  let configPath = folder / ".cargo" / "config.toml"
  if fileExists(configPath):
    try:
      let content = readFile(configPath)
      if "wasm32" in content:
        return tiWasm
    except CatchableError:
      discard
  tiNative

proc assessCargoProject*(folder: string): CargoProjectAssessment =
  ## Assess a directory as a cargo project: the kind set, the language and the
  ## ISA, each on the axis that owns it.
  if not fileExists(folder / "Cargo.toml"):
    return CargoProjectAssessment(
      present: false,
      kind: TargetKind(specific: @[], family: tfProjectDirectory),
      sourceLanguage: slUnknown,
      targetIsa: tiUnknown)
  let isa = cargoTargetIsa(folder)
  CargoProjectAssessment(
    present: true,
    kind: TargetKind(
      specific: if isa == tiWasm: @[KindCargoProject, KindWasmCargoProject]
                else: @[KindCargoProject],
      family: tfProjectDirectory),
    sourceLanguage: slRust,
    targetIsa: isa)

func langForProjectKind*(kind: string): Lang =
  ## The `Lang` summary a project kind implies, or `LangUnknown` for a kind
  ## that names no single language.
  ##
  ## This is the map that used to be written inline in `detectFolderLang`'s
  ## `elif` ladder, where each arm converted a kind into a language AT THE
  ## `return` and threw the kind away (design 9.1).  Pulled out so the kind
  ## survives and the language is derived FROM it rather than instead of it.
  ## Deliberately NOT total over the open specific-kind vocabulary: a kind
  ## this build has never heard of names no language here, which is the
  ## additive-within-a-major rule (design 9.4) and not a gap.
  case kind
  of KindNoirProject: LangNoir
  of KindCairoProject: LangCairo
  of KindAikenProject: LangAiken
  of KindMoveProject: LangMove
  of KindSwayProject: LangSway
  of KindFoundryProject: LangSolidity
  of KindCargoProject, KindWasmCargoProject: LangRust
  of KindLeanProject: LangLean
  of KindCrystalProject: LangCrystal
  of KindLeoProject: LangLeo
  else: LangUnknown

proc assessFolderKind*(folder: string): TargetKind =
  ## **The assessment algorithm, answering with a KIND** -- LRS-2P's third
  ## deliverable, and the proc `detectFolderLang` used to be.
  ##
  ## `detectFolderLang` tested the ten markers below in an `elif` ladder and
  ## converted the FIRST hit into a `Lang` at the `return`.  Two facts died
  ## there: *"this is a cargo project"*, which is what decides whether to
  ## build before recording (design 9.1), and *"it is ALSO a foundry
  ## project"*, which Q10 -- decided 2026-09-20 by the user -- names as the
  ## defect: /"a crate that is also a Foundry project silently becomes
  ## Foundry"/.
  ##
  ## So the ladder is ten independent `if`s, and the ORDER of the markers is
  ## no longer a property of this algorithm.  That is the point rather than an
  ## omission: every marker present is reported, and the consumer resolves the
  ## set or refuses naming both (rule K2).  `assessFolder` below is where the
  ## `Lang` summary is derived from the set, and it refuses rather than picks.
  ##
  ## The ten marker tests below are written out rather than looped over
  ## `ProjectMarkerKinds`, because `target_axes_test.nim` reads
  ## the marker names back out of THIS source text and pins them against that
  ## constant -- a loop would make the constant assert itself.  The pin is by
  ## MEMBERSHIP (order is not a property), and it is backed by a behavioural
  ## pin over a real directory that two markers yield two kinds, which is
  ## strictly stronger than the order assertion it replaced: an order pin
  ## cannot catch a reintroduced first-match `return`, and the behavioural one
  ## does.
  var specific: seq[string] = @[]
  if fileExists(folder / "Nargo.toml"): specific.add(KindNoirProject)
  if fileExists(folder / "Scarb.toml"): specific.add(KindCairoProject)
  if fileExists(folder / "aiken.toml"): specific.add(KindAikenProject)
  if fileExists(folder / "Move.toml"): specific.add(KindMoveProject)
  if fileExists(folder / "Forc.toml"): specific.add(KindSwayProject)
  if fileExists(folder / "foundry.toml"): specific.add(KindFoundryProject)
  if fileExists(folder / "Cargo.toml"):
    # `cargo-project` AND, when `.cargo/config.toml` says `wasm32`,
    # `wasm-cargo-project`.  Both: one names the toolchain, the other the
    # ISA, and `targetIsaForAssessment` / `toolchainForKind` read one each.
    specific.add(KindCargoProject)
    if cargoTargetIsa(folder) == tiWasm: specific.add(KindWasmCargoProject)
  if fileExists(folder / "lakefile.lean"): specific.add(KindLeanProject)
  if fileExists(folder / "shard.yml"): specific.add(KindCrystalProject)
  if fileExists(folder / "program.json"): specific.add(KindLeoProject)
  TargetKind(specific: specific, family: tfProjectDirectory)

type
  FolderAssessment* = object
    ## What `detectTarget` learns about a directory.
    kind*: TargetKind
      ## The answer, carried forward instead of discarded.
    lang*: Lang
      ## The `Lang` SUMMARY the kind implies, for the callers that still take
      ## one.  `LangUnknown` when the kind names no language -- and when the
      ## kinds name two DIFFERENT ones, which is `ambiguity` below.
    ambiguity*: seq[string]
      ## The kinds that named two or more different languages.  Non-empty
      ## means the summary is `LangUnknown` BECAUSE there were too many
      ## answers, not because there were none -- rule K2: nothing picks one
      ## silently.  `cargo-project` beside `wasm-cargo-project` names one
      ## language and is not an ambiguity, the same way it is one toolchain.

proc assessFolder*(folder: string): FolderAssessment =
  ## Assess a directory, and derive the `Lang` summary FROM the kind.
  ##
  ## When the markers name nothing, the in-folder extension scan below is the
  ## fallback -- unchanged from `detectFolderLang`, and reached under exactly
  ## the same condition (no project marker matched).  It answers a language
  ## and no kind, honestly: a directory holding a `.circom` file is not a
  ## "circom project", no manifest says so, and minting a kind for it would
  ## assert more than the evidence supports.
  result.kind = assessFolderKind(folder)
  var langs: seq[Lang] = @[]
  var namedBy: seq[string] = @[]
  for specific in result.kind.specific:
    let named = langForProjectKind(specific)
    if named == LangUnknown: continue
    if named notin langs:
      langs.add(named)
      namedBy.add(specific)
  if langs.len == 1:
    result.lang = langs[0]
    return
  if langs.len >= 2:
    result.lang = LangUnknown
    result.ambiguity = namedBy
    return
  for entryKind, path in walkDir(folder):
    if entryKind == pcFile:
      case path.splitFile()[2]
      of ".masm": result.lang = LangMasm; return
      of ".circom": result.lang = LangCircom; return
      of ".leo": result.lang = LangLeo; return
      of ".sol": result.lang = LangSolidity; return
      of ".tolk": result.lang = LangTolk; return
      else: discard
  result.lang = LangUnknown

func folderAmbiguityLines*(folder: string, assessment: FolderAssessment): seq[string] =
  ## The refusal a directory whose manifests name two languages earns.
  ##
  ## Named here, beside the algorithm that produces the ambiguity, so the
  ## wording cannot drift from the fact.  `ct record` prints these and stops;
  ## before LRS-2P `detectFolderLang` answered such a directory with whichever
  ## language its ladder reached first and said nothing at all.
  if assessment.ambiguity.len == 0:
    return @[]
  @["error: '" & folder & "' carries more than one project manifest, and " &
      "they name different languages -- " & assessment.ambiguity.join(" and ") &
      " -- so nothing may pick one silently.",
    "help: pass --lang <language> to say which one to record, or record from " &
      "inside the project you mean."]


# The extension -> language table `ct record` / `ct run` detect with, via
# `detectLangFromPath` below.  Exported so that the capability-file
# conformance check (ci/test/desktop_capabilities_dispatch_check.nim) can
# recompute the set of extensions codetracer-desktop is allowed to declare
# in `resources/codetracer-desktop-capabilities` from THIS table, rather
# than from a second, drift-prone copy of it.
const LANGS* = {
  "c": LangC,
  "cpp": LangCpp,
  "rs": LangRust,
  "nim": LangNim,
  "nims": LangNim,
  "go": LangGo,
  "pas": LangPascal,
  "f90": LangFortran,
  "d": LangD,
  "cr": LangCrystal,
  "lean": LangLean,
  "adb": LangAda,
  "py": LangPythonDb,
  "rb": LangRubyDb, # default for ruby for now
  "nr": LangNoir,
  # A prebuilt `.wasm` module.  The LANGUAGE here is a guess and is marked as
  # one: a module may have been compiled from Rust, C++, or anything else, and
  # nothing in the container says which.  Rust is the guess because it is the
  # only wasm toolchain `ct record` builds for (`--target wasm32-wasip1`).
  # What is NOT a guess is the ISA: `assessKind` reads the `.wasm` extension as
  # `KindWasmModule` and `targetIsaForAssessment` answers `tiWasm` from the
  # kind, so the route to `wazero` rides on the ARTEFACT.  Before LRS-5's
  # second deletion round this row was `LangRustWasm` and the ISA came from
  # the member -- see `record_dispatch_test`, "a prebuilt .wasm module
  # dispatches to wazero, and the route rides on the ARTEFACT".
  "wasm": LangRust,
  "sol": LangSolidity,
  "masm": LangMasm,
  "sw": LangSway,
  "move": LangMove,
  "cairo": LangCairo,
  "circom": LangCircom,
  "leo": LangLeo,
  "tolk": LangTolk,
  "ak": LangAiken,
  "cdc": LangCadence,
  "sh": LangBash,
  "bash": LangBash,
  "zsh": LangZsh,
  "js": LangJavascript,
  "mjs": LangJavascript,
  "ts": LangJavascript,
  "ex": LangElixir,
  "exs": LangElixir,
  "erl": LangErlang,
  "hrl": LangErlang,
  "php": LangPhp,
  # `.gd` was missing here while `src/common/lang.nim`'s `toLang` map already
  # knew both `gd` and `gdscript`.  Two extension tables, only one of them
  # updated, is drift this enum has suffered before — and the consequence was
  # not a missing feature but a WRONG diagnostic.  Measured on the shipped
  # binary: `ct record player.gd` fell through to `LangUnknown`, took the
  # NATIVE branch of `src/ct/trace/record.nim`, and printed "Assuming recording
  # language LangUnknown" followed by a complaint that `ct-native-replay` is
  # not installed.  Installing it would not have helped, and nothing about the
  # failure named GDScript.  With this entry the file reaches `LangGdScript`,
  # whose `recorderToolFor` arm says what is actually missing — the patched
  # Godot engine — see `src/ct/trace/recorder_dispatch.nim`.
  "gd": LangGdScript,
}.toTable()

proc detectLangFromPath*(path: string): Lang =
  ## Map a path's file extension onto a `Lang`, or `LangUnknown` when the
  ## extension is not one this build knows.
  ##
  ## ## Why the final `return LangUnknown` is written out
  ##
  ## It used to be absent.  Nim initialises `result` to the enum's **zero
  ## value**, and `LangC` was ordinal 0 until LRS-4 moved `LangUnknown` there
  ## (2026-09-21; `LangC` is 1 now), so every path whose extension was not
  ## in `LANGS` fell off the end of this proc and was reported as **C**.  That
  ## is not a hypothetical: `a.out`, `my.project`, `python3.11`, `libfoo.so.1`,
  ## `data.json`, `notes.txt` and `archive.tar.gz` all resolved to `LangC`.
  ## Only a name with no dot at all reached the `ext.len <= 1` guard above and
  ## produced `LangUnknown`.
  ##
  ## The damage was not cosmetic.  `detectTarget` treats any non-`LangUnknown`
  ## answer as "detection succeeded" and stops the ladder there, so a confident
  ## wrong `LangC` for an extensionless-but-dotted native binary pre-empted the
  ## `ct-native-replay recognize` delegation entirely — `ct record ./a.out`
  ## printed "Assuming recording language LangC" and never spawned the
  ## recognizer.
  ##
  ## The explicit return is required **regardless of which value is ordinal
  ## zero**.  A proc whose correctness depends on the enum's declaration order
  ## is not correct; it is merely lucky, and the luck is invisible at the call
  ## site.  `src/tests/cli/lang_enum_contract_test.nim` asserts the returned
  ## value directly so a future reordering of `Lang` cannot quietly reintroduce
  ## the defect.
  ##
  ## ## The `isWasm` parameter is gone (LRS-5, second deletion round)
  ##
  ## It used to route `.rs` / `.cpp` / `.c` through a second table,
  ## `WASM_LANGS`, onto `LangRustWasm` / `LangCppWasm` whenever the recorded
  ## artefact was a `.wasm` module.  That was an ISA fact written into a
  ## language answer.  The ISA now has an axis of its own:
  ## `targetIsaForArtefactPath` below is the same fact, stated as an ISA, and
  ## the assessment reads the `.wasm` extension as `KindWasmModule`.  The
  ## quirk that went with the second table -- a `.c` source in a wasm
  ## recording was reported as C++, because there was no `LangCWasm` member to
  ## report -- goes with it, deliberately: `.c` is `slC` on the language axis
  ## and `tiWasm` on the ISA axis, which is what it always was.
  let ext = path.splitFile.ext
  if ext.len <= 1:
    return LangUnknown

  let extension = ext[1..^1].toLowerAscii()
  if LANGS.hasKey(extension):
    let known = LANGS[extension] # TODO detectLangFromTrace(traceId) ?
    if known != LangUnknown:
      return known

  LangUnknown


type
  RecognitionBackend* = object
    ## Where the recognizer lives.  `resolved == false` means "look it up from
    ## the user's configuration at the point of use", which is what every
    ## production caller wants and what the code did before NTR-2; a resolved
    ## value is what a test passes when it needs to drive a specific binary
    ## (a stub recognizer, a spawn counter) without editing the user's config.
    resolved*: bool
    enabled*: bool
    path*: string

  DetectedTarget* = object
    ## The result of recognizing one target.
    ##
    ## NTR-2 deliverable: "the core consumes `primary` for its `Lang` decision
    ## and carries `components`, `kind`, `interpreter` and `format` forward,
    ## even while it still dispatches on `primary` alone".  `recognition` is
    ## that carry.  It is `none` in exactly two cases and they are different
    ## facts a consumer must not conflate:
    ##
    ## * `recognitionRan == false` — recognition was **not computed**, either
    ##   because `--lang` was given (Q8) or because an earlier signal answered
    ##   first.  Q8 is explicit that a consumer of trace metadata must read the
    ##   absence of `components` / `format` / `interpreter` / `debug_info` as
    ##   "not computed", never as "the target had none".
    ## * `recognitionRan == true` with `recognition.isNone` — the delegation was
    ##   attempted and could not be trusted; `diagnosticLines` says why.
    lang*: Lang
    recognitionRan*: bool
    recognition*: Option[Recognition]
    diagnosticLines*: seq[string]
    folderKind*: TargetKind
      ## The assessed kind of a DIRECTORY target -- LRS-2P's third
      ## deliverable, carried instead of discarded.  `family` is
      ## `tfProjectDirectory` whenever the target was a directory at all, so
      ## `specific.len == 0` with that family means "a directory carrying no
      ## manifest this build knows", which is a different fact from "not a
      ## directory" (`tfUnknown`, the zero value of the field).
    folderKindAmbiguity*: seq[string]
      ## Non-empty when the directory's manifests named two different
      ## languages: `lang` is then `LangUnknown` because there were too MANY
      ## answers, not because there were none (rule K2).

proc configuredRecognitionBackend*(): RecognitionBackend =
  ## Resolve the recognizer from the user's configuration.
  ##
  ## `loadConfig` auto-discovers `ct-native-replay` from `PATH` when no path is
  ## configured (`src/common/config.nim`), which is exactly the discovery that
  ## makes the recognition schema a cross-repository contract (Q5).
  let ctConfig = loadConfig(folder = getCurrentDir(), inTest = false)
  RecognitionBackend(
    resolved: true,
    enabled: ctConfig.rrBackend.enabled,
    path: ctConfig.rrBackend.path)

func targetIsaForArtefactPath*(path: string): TargetIsa =
  ## The target ISA an ARTEFACT's own path states, or `tiUnknown` when it
  ## states none.  The import side's counterpart to `assessKind`'s
  ## `KindWasmModule` (LRS-5, precondition (c)): `ct import` and the
  ## online-sharing download path have no assessment to consult, only the
  ## recorded `program` string, and a `.wasm` there is exactly as much of an
  ## artefact fact as it is for `ct record`.
  if path.splitFile.ext.toLowerAscii == ".wasm": tiWasm else: tiUnknown

proc detectTarget*(program: string,
                   lang: Lang,
                   backend: RecognitionBackend = RecognitionBackend()):
    DetectedTarget =
  ## Recognize `program`, delegating the native question to
  ## `ct-native-replay recognize` (NTR-2, design §6).
  ##
  ## ### `--lang` skips recognition entirely (Q8)
  ##
  ## The early return below is not "run recognition and let `--lang` win" — the
  ## recognizer is **not spawned at all**.  An explicit user instruction is not
  ## second-guessed; the accepted trade-off is that a *wrong* `--lang` fails
  ## later and with a less specific error, and that a `--lang` recording's trace
  ## metadata is thinner because nothing computed the missing parts.
  ##
  ## ### The delegation (Q4)
  ##
  ## The last step used to shell out to `<rrBackend.path> debuginfo lang
  ## <program>` — a subcommand `ct-native-replay` has never had.  `clap` failed,
  ## stdout was empty, `toLang("")` returned `LangUnknown`, and the whole
  ## delegation was dead code that could not be told apart from a genuine "I
  ## could not tell".  It now invokes `recognize --format=json` and consumes the
  ## `codetracer.target-recognition.v1` document.
  ##
  ## ### No cache (Q7)
  ##
  ## Every call spawns the recognizer and stores nothing.  Passing the returned
  ## `DetectedTarget` along one invocation's call chain is expected; persisting
  ## it is what Q7 forbids.
  if lang != LangUnknown:
    return DetectedTarget(lang: lang, recognitionRan: false)

  var possiblyExpandedPath = ""
  try:
    possiblyExpandedPath = expandFileName(program)
  except CatchableError:
    possiblyExpandedPath = program

  let filename = possiblyExpandedPath.extractFilename
  let isFolder = dirExists(program)

  if isFolder:
    # LRS-2P: the folder is ASSESSED, and the assessment's kind is carried
    # forward.  `detectFolderLang` used to return a `Lang` and nothing else,
    # so the kind -- the fact that decides whether to build before recording
    # -- was recomputed later or lost.
    let folder = assessFolder(program)
    if folder.ambiguity.len > 0:
      # Two manifests naming two languages.  Refuse here rather than
      # delegating to a recognizer that reads object bytes and cannot answer a
      # manifest question anyway; `ct record` prints `diagnosticLines` and
      # stops.  Before LRS-2P this directory silently became whichever
      # language the `elif` ladder reached first.
      return DetectedTarget(
        lang: LangUnknown, recognitionRan: false, folderKind: folder.kind,
        folderKindAmbiguity: folder.ambiguity,
        diagnosticLines: folderAmbiguityLines(program, folder))
    if folder.lang != LangUnknown:
      return DetectedTarget(lang: folder.lang, recognitionRan: false,
                            folderKind: folder.kind)

  if not isFolder and "." in filename:
    let extensionLang = detectLangFromPath(filename)
    if extensionLang != LangUnknown:
      return DetectedTarget(lang: extensionLang, recognitionRan: false)

  # Nothing to delegate about a target that is not there.  `recognize` would
  # only report the I/O error the caller is about to report anyway, and the
  # existing "folder/path doesn't exist?" message already names this case.
  if not isFolder and not fileExists(program):
    return DetectedTarget(lang: LangUnknown, recognitionRan: false)

  let resolvedBackend =
    if backend.resolved: backend else: configuredRecognitionBackend()
  if not resolvedBackend.enabled or resolvedBackend.path.len == 0:
    return DetectedTarget(lang: LangUnknown, recognitionRan: false)

  let outcome = recognizeTarget(resolvedBackend.path, program)
  let decision = decideFromRecognition(outcome, program)
  result = DetectedTarget(
    lang: decision.lang,
    recognitionRan: true,
    recognition:
      if outcome.status == rsOk: some(outcome.recognition)
      else: none(Recognition),
    diagnosticLines: decision.lines)

  # LRS-2P: the embedded assessment's kind, resolved against the vocabulary
  # this build actually has code for (rule K2).  This is where a version-
  # skewed pair becomes visible instead of silent, and it runs on the real
  # delegation -- not only in a test -- because that is the only place the
  # skew can happen.
  if outcome.status == rsOk and outcome.recognition.assessmentComputed:
    let verdict = outcome.recognition.assessment.kind.understand(
      UnderstoodSpecificKinds, outcome.recognition.assessment.producer)
    if verdict.diagnostic.len > 0:
      # Non-empty for every outcome that is not an exact, undegraded match:
      # a degradation to the family, an ambiguity, or a K4 refusal.  Printing
      # it is not optional -- that is the "never silently" half of design 9.3.
      stderr.writeLine(
        (if verdict.ok: "note: " else: "error: ") & verdict.diagnostic)
    if not verdict.ok:
      quit(1)

  case decision.kind
  of rdProtocolError:
    # Rule K3.  The assessment's vocabulary could not be read, so nothing
    # about this target may be acted on.
    for line in decision.lines:
      stderr.writeLine(line)
    quit(1)
  of rdAmbiguous:
    # Design rule C2 / `record.md`'s standing "never a silent pick": the
    # recognizer could not decide between two equally-supported languages, so
    # `ct record` refuses and names the flag that disambiguates.
    for line in decision.lines:
      stderr.writeLine(line)
    quit(1)
  of rdDegraded:
    # The delegation itself failed.  Say so — on stderr, because `ct record`'s
    # stdout carries the `recordingId:` marker other parts of the product
    # parse.  Recognition falling through to `LangUnknown` is then the caller's
    # existing, actionable error path rather than an invisible downgrade.
    #
    # ⚠ Only THIS process's copy lands on stderr.  Q7's measured double spawn
    # means `db-backend-record` recognizes again in its own process, and
    # `recordInternal` starts it with `poStdErrToStdOut` and relays every line
    # to `ct`'s STDOUT (`../trace/record.nim`), so a user sees the same warning
    # once per stream.  Nothing breaks — the marker parser scans every line for
    # the `recordingId:` prefix rather than reading the last one — but stdout is
    # TOLERATED, not clean, and it stops being so only when the recognition
    # result is passed across the process boundary instead of recomputed.
    for line in decision.lines:
      stderr.writeLine(line)
  of rdLanguage, rdNoLanguage:
    discard

proc detectLang*(program: string, lang: Lang): Lang =
  ## The single-`Lang` view of `detectTarget`, for callers that cannot yet
  ## carry the rest of the recognition result.
  detectTarget(program, lang).lang
