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
proc isWasmCargoProject(folder: string): bool =
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
    if isWasmCargoProject(folder):
      LangRustWasm
    else:
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
  "wasm": LangRustWasm, # TODO: can be Cpp or other as well, maybe pass
    # explicitly or check trace/other debug info?
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
}.toTable()

const WASM_LANGS = {
  "rs": LangRustWasm,
  "cpp": LangCppWasm,
  "c": LangCppWasm,
}.toTable()

proc detectLangFromPath*(path: string, isWasm: bool): Lang =
  ## Map a path's file extension onto a `Lang`, or `LangUnknown` when the
  ## extension is not one this build knows.
  ##
  ## ## Why the final `return LangUnknown` is written out
  ##
  ## It used to be absent.  Nim initialises `result` to the enum's **zero
  ## value**, and `LangC` is ordinal 0, so every path whose extension was not
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
  ## site.  `lang_detection_test.nim` asserts the returned value directly so a
  ## future reordering of `Lang` cannot quietly reintroduce the defect.
  let ext = path.splitFile.ext
  if ext.len <= 1:
    return LangUnknown

  let extension = ext[1..^1].toLowerAscii()
  if isWasm and WASM_LANGS.hasKey(extension):
    return WASM_LANGS[extension]

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

proc detectTarget*(program: string,
                   lang: Lang,
                   isWasm: bool = false,
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
    let extensionLang = detectLangFromPath(filename, isWasm)
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

proc detectLang*(program: string, lang: Lang, isWasm: bool = false): Lang =
  ## The single-`Lang` view of `detectTarget`, for callers that cannot yet
  ## carry the rest of the recognition result.
  detectTarget(program, lang, isWasm).lang
