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
proc isWasmCargoProject*(folder: string): bool =
  ## Exported for `src/ct/trace/record_assessment.nim`, which reads this marker
  ## to assert `wasm-cargo-project` as a target KIND.  Since LRS-5's second
  ## deletion round that is the ONLY reader of it: `detectFolderLang` below
  ## used to weld the ISA onto a `Lang` value (`LangRustWasm`) and no longer
  ## can, because the member is gone.
  let configPath = folder / ".cargo" / "config.toml"
  if fileExists(configPath):
    try:
      let content = readFile(configPath)
      return "wasm32" in content
    except CatchableError:
      discard
  false

proc detectFolderLang(folder: string): Lang =
  if fileExists(folder / "Nargo.toml"):
    LangNoir
  elif fileExists(folder / "Scarb.toml"):
    LangCairo
  elif fileExists(folder / "aiken.toml"):
    LangAiken
  elif fileExists(folder / "Move.toml"):
    LangMove
  elif fileExists(folder / "Forc.toml"):
    LangSway
  elif fileExists(folder / "foundry.toml"):
    LangSolidity
  elif fileExists(folder / "Cargo.toml"):
    # A wasm crate and a plain crate are both Rust.  What tells them apart is
    # the `.cargo/config.toml` `wasm32` marker, which `assessKind` reads as
    # `KindWasmCargoProject` and `targetIsaForAssessment` turns into `tiWasm`
    # -- an ISA on its own axis.  Until LRS-5's second deletion round this
    # answered `LangRustWasm` here, which is the same fact spelled as a
    # language, and was one of the three writers of that member.
    LangRust
  elif fileExists(folder / "lakefile.lean"):
    LangLean
  elif fileExists(folder / "shard.yml"):
    LangCrystal
  elif fileExists(folder / "program.json"):
    # Leo projects typically have a program.json at the root
    LangLeo
  else:
    # Check for projects identifiable by file extensions in the folder
    for kind, path in walkDir(folder):
      if kind == pcFile:
        let ext = path.splitFile()[2]
        case ext
        of ".masm": return LangMasm
        of ".circom": return LangCircom
        of ".leo": return LangLeo
        of ".sol": return LangSolidity
        of ".tolk": return LangTolk
        else: discard
    LangUnknown


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
    let folderLang = detectFolderLang(program)
    if folderLang != LangUnknown:
      return DetectedTarget(lang: folderLang, recognitionRan: false)

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

  case decision.kind
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
