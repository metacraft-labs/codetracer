## target_recognition_test.nim
##
## The core's delegation to `ct-native-replay recognize` — milestone **NTR-2**
## of `codetracer-specs/Planned-Features/Native-Target-Recognition.md`.
##
## ## What was broken, and why a test exists at all
##
## `src/ct/utilities/language_detection.nim` had *always* delegated its last
## detection step to the native backend, and had always delegated it to a
## subcommand that has never existed: `<ct-native-replay> debuginfo lang
## <program>`.  `clap` refused the argv, wrote to stderr, produced no stdout,
## `toLang("")` returned `LangUnknown`, and detection fell through exactly as
## if the recognizer had looked and found nothing.  A dead delegation and a
## working one that finds nothing were indistinguishable, which is precisely
## why nobody noticed for as long as it lasted.
##
## Every test below exists to make one of those two states distinguishable
## again, and to pin a decision that would otherwise be a claim about intent:
##
## * the delegation really spawns `recognize --format=json <target>` and really
##   consumes the `codetracer.target-recognition.v1` document (Q4);
## * a **non-zero exit** is a real failure and is reported, while `kind:
##   unknown` on a **zero exit** is a result and is not (design §6.2's
##   exit-status contract — the two are opposite conclusions from adjacent
##   inputs, so both are asserted);
## * an **unrecognised `schema`** is refused with a message naming what was
##   found and what is supported, and the document is not parsed (Q5's consumer
##   obligation, which exists because the core *discovers* `ct-native-replay`
##   on `PATH` rather than bundling it, so version skew is routine);
## * an unknown **enum value** is never a parse error (the other half of Q5,
##   without which every additive producer change is silently breaking);
## * **Q7 — there is no cache**: two consecutive recognitions of the same
##   target spawn the recognizer twice, counted;
## * **Q8 — `--lang` skips recognition entirely**, asserted in *both*
##   directions, because "we skip" is otherwise a claim about intent rather
##   than about behaviour;
## * an **ambiguous ledger** names `--lang` and never falls back silently
##   (design rule C2, `record.md`'s standing "never a silent pick").
##
## ## How a recognizer is simulated, and why it is not a mock
##
## Mocking justification (workspace policy on mock objects): **there is no mock
## object here.**  The delegation is a real `startProcess` of a real executable,
## and what it executes is *this test binary re-invoked with `recognize` as its
## first argument* — see `runStubRecognizer` below.  Nothing in
## `target_recognition.nim` or `language_detection.nim` is stubbed, replaced or
## compiled differently; the production code spawns a process, waits for it,
## reads its stdout and its exit status exactly as it does against the real
## `ct-native-replay`.  Only the *contents* of the document differ, which is the
## whole point: a real `ct-native-replay` cannot be made to emit an unrecognised
## schema, a malformed document, or an `ambiguous-language` diagnostic that
## NTR-3 has not shipped yet, so those contracts would otherwise be untestable
## until after they had already been broken in production.
##
## Re-invoking the test binary rather than writing a shell script is deliberate:
## a `#!/bin/sh` stub does not run on Windows, and skipping the suite there
## would be exactly the silent-self-pass this initiative exists to remove.
##
## Compile and run:
##   nim c -r src/tests/cli/target_recognition_test.nim

import std/[json, options, os, strutils, unittest]
import ../../common/lang
import ../../ct/utilities/target_recognition
import ../../ct/utilities/language_detection

# ---------------------------------------------------------------------------
# Stub-recognizer mode
#
# This block runs BEFORE any `suite`, because top-level statements execute in
# source order.  When the binary is invoked as `<self> recognize --format=json
# <target>` it behaves as a `ct-native-replay` would and exits; when it is
# invoked with no arguments (which is how `nim c -r` and `just test-cli-record`
# invoke it) it falls through to the suites.
# ---------------------------------------------------------------------------

const
  StubLogEnv = "CT_NTR2_STUB_LOG"
    ## Append one line per invocation: the argv, tab-separated.  Counting the
    ## lines is how Q7's "spawned twice" and Q8's "not spawned at all" are
    ## measured rather than asserted.
  StubStdoutFileEnv = "CT_NTR2_STUB_STDOUT_FILE"
  StubStderrEnv = "CT_NTR2_STUB_STDERR"
  StubExitEnv = "CT_NTR2_STUB_EXIT"

proc runStubRecognizer() =
  let logPath = getEnv(StubLogEnv, "")
  if logPath.len > 0:
    var argv: seq[string] = @[]
    for i in 1 .. paramCount():
      argv.add(paramStr(i))
    let f = open(logPath, fmAppend)
    f.writeLine(argv.join("\t"))
    f.close()

  let stdoutFile = getEnv(StubStdoutFileEnv, "")
  if stdoutFile.len > 0 and fileExists(stdoutFile):
    stdout.write(readFile(stdoutFile))
    stdout.flushFile()

  let stderrText = getEnv(StubStderrEnv, "")
  if stderrText.len > 0:
    stderr.writeLine(stderrText)

  quit(parseInt(getEnv(StubExitEnv, "0")))

if paramCount() >= 1 and paramStr(1) == RecognizeSubcommand:
  runStubRecognizer()

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

let scratch = getTempDir() / "ct-ntr2-target-recognition"

proc freshDir(name: string): string =
  result = scratch / name
  removeDir(result)
  createDir(result)

proc goDocument(target: string): string =
  ## A realistic `codetracer.target-recognition.v1` document, shaped exactly
  ## like the one `codetracer-native-backend/src/recognize.rs` emits for a
  ## compiled Go ELF (design §6.2's worked example).
  $ %*{
    "schema": RecognitionSchema,
    "target": target,
    "kind": "executable",
    "primary": {
      "language": "go",
      "confidence": "certain",
      "weight": 412,
      "evidence": ["section:.gopclntab", "symbol:runtime.main",
                   "dwarf:DW_LANG_Go"]
    },
    "components": [
      {"language": "go", "confidence": "certain", "weight": 412,
       "evidence": ["section:.gopclntab"]},
      {"language": "c", "confidence": "likely", "weight": 37,
       "evidence": ["dwarf:sources=37"]}
    ],
    "interpreter": nil,
    "format": {"container": "elf", "arch": "x86_64", "os": nil,
               "pie": true, "stripped": false},
    "debug_info": {"present": true, "kind": "dwarf"},
    "recommended": {"recorder": "ct-mcr", "backend": "mcr",
                    "strategy": "native-go"},
    "diagnostics": []
  }

proc unknownDocument(target: string): string =
  ## What NTR-0's recognizer really emits for a target it cannot classify:
  ## every key present, all of them null, exit status **0**.
  $ %*{
    "schema": RecognitionSchema,
    "target": target,
    "kind": "unknown",
    "primary": nil,
    "components": [],
    "interpreter": nil,
    "format": nil,
    "debug_info": {"present": false, "kind": nil},
    "recommended": nil,
    "diagnostics": [
      {"code": "not-an-object-file",
       "message": "the target is not a parseable object file"},
      {"code": "shebang-recognition-pending",
       "message": "shebang recognition is not implemented in this build"}
    ]
  }

type
  StubSetup = object
    dir: string
    target: string
    logPath: string
    documentPath: string

proc setupStub(name, document: string; exitCode = 0; stderrText = ""): StubSetup =
  ## Prepare a target, a canned document and a fresh spawn log, and point the
  ## stub's environment at them.  Returns the paths so a test can read the log
  ## back.
  let dir = freshDir(name)
  # No extension: an extension would answer before the delegation is reached,
  # which is the whole family of targets NTR-1's routing rule exists to let
  # through to the recognizer.
  let target = dir / "native-target"
  writeFile(target, "not really an ELF, the recognizer is the stub\n")
  let logPath = dir / "spawns.log"
  let documentPath = dir / "document.json"
  writeFile(documentPath, document.replace("__TARGET__", target))

  putEnv(StubLogEnv, logPath)
  putEnv(StubStdoutFileEnv, documentPath)
  putEnv(StubStderrEnv, stderrText)
  putEnv(StubExitEnv, $exitCode)
  StubSetup(dir: dir, target: target, logPath: logPath,
            documentPath: documentPath)

proc stubBackend(): RecognitionBackend =
  RecognitionBackend(resolved: true, enabled: true, path: getAppFilename())

proc spawnLines(logPath: string): seq[string] =
  result = @[]
  if fileExists(logPath):
    for line in readFile(logPath).splitLines:
      if line.strip.len > 0:
        result.add(line)

# ---------------------------------------------------------------------------

suite "NTR-2: the core delegates recognition to ct-native-replay":

  test "the stub recognizer this suite drives is a real, runnable process":
    # Every assertion below rests on `getAppFilename()` naming an executable
    # that can be spawned.  If it cannot, the delegation tests would report
    # "recognition was skipped" and pass for the wrong reason, so this is
    # checked once and loudly rather than assumed.
    let self = getAppFilename()
    check self.len > 0
    check fileExists(self)
    let probe = setupStub("stub-probe", goDocument("__TARGET__"))
    let outcome = recognizeTarget(self, probe.target)
    checkpoint("outcome status: " & $outcome.status &
      " failure: " & outcome.failure.join(" | "))
    check outcome.status == rsOk

  test "the delegation invokes `recognize --format=json <target>` and parses it":
    # Q4: the dead `debuginfo lang` call site is REPLACED, not restored.
    check recognizeArgs("/tmp/x") ==
      @["recognize", "--format=json", "/tmp/x"]

    let stub = setupStub("delegation", goDocument("__TARGET__"))
    let detected = detectTarget(stub.target, LangUnknown,
                                backend = stubBackend())

    # 1. It really ran, with the argv the design specifies.
    let spawns = spawnLines(stub.logPath)
    checkpoint("spawns: " & spawns.join(" / "))
    check spawns.len == 1
    check spawns[0] == @["recognize", "--format=json", stub.target].join("\t")

    # 2. `primary` really became the core's `Lang`.  This is the assertion the
    #    dead call site could never have passed.
    check detected.lang == LangGo
    check detected.recognitionRan
    check detected.recognition.isSome

    # 3. The rest of the document is carried forward rather than swallowed
    #    (NTR-2 dispatches on `primary` alone; NTR-3 records these).
    let recognition = detected.recognition.get
    check recognition.schema == RecognitionSchema
    check recognition.kind == "executable"
    check recognition.components.len == 2
    check recognition.components[0].language == "go"
    check recognition.components[0].confidence == "certain"
    check recognition.components[0].weight == 412
    check "section:.gopclntab" in recognition.components[0].evidence
    check recognition.components[1].language == "c"
    check recognition.format.isSome
    check recognition.format.get.container == "elf"
    check recognition.format.get.arch == "x86_64"
    # `format.os` is null for ELF, deliberately, and must survive as "".
    check recognition.format.get.os == ""
    check recognition.debugInfo.present
    check recognition.debugInfo.kind == "dwarf"
    check recognition.recommended.isSome
    # MCR is the default native recorder; the delegation must not change that.
    check recognition.recommended.get.recorder == "ct-mcr"
    check recognition.recommended.get.backend == "mcr"

  test "a non-zero recognize exit is a failure and is reported, not swallowed":
    # Design §6.2: non-zero is reserved for I/O and CLI errors.  Treating it as
    # "no language found" would restore exactly the indistinguishability the
    # dead `debuginfo lang` call site had.
    let stub = setupStub(
      "exit-non-zero", goDocument("__TARGET__"),
      exitCode = 1,
      stderrText = "cannot read target '/nope': No such file or directory")
    let outcome = recognizeTarget(getAppFilename(), stub.target)
    checkpoint("failure: " & outcome.failure.join(" | "))
    check outcome.status == rsExitedNonZero
    check outcome.exitCode == 1
    check outcome.failure.len > 0
    check "No such file or directory" in outcome.failure.join("\n")

    let decision = decideFromRecognition(outcome, stub.target)
    check decision.kind == rdDegraded
    check decision.lang == LangUnknown
    check decision.lines.len > 0

  test "`kind: unknown` on a zero exit is a result, not an error":
    # The opposite conclusion from the adjacent input above.  "I looked and
    # could not tell" is data the caller acts on; the query did not fail.
    let stub = setupStub("kind-unknown", unknownDocument("__TARGET__"))
    let outcome = recognizeTarget(getAppFilename(), stub.target)
    check outcome.status == rsOk
    check outcome.exitCode == 0
    check outcome.failure.len == 0
    check outcome.recognition.kind == "unknown"
    check outcome.recognition.primary.isNone
    # The informational diagnostics are carried, never acted on.
    check outcome.recognition.diagnostics.len == 2
    check outcome.recognition.hasDiagnostic("not-an-object-file")

    let decision = decideFromRecognition(outcome, stub.target)
    check decision.kind == rdNoLanguage
    check decision.lang == LangUnknown
    check decision.lines.len == 0

    let detected = detectTarget(stub.target, LangUnknown,
                                backend = stubBackend())
    check detected.lang == LangUnknown
    check detected.recognitionRan
    check detected.recognition.isSome
    check detected.diagnosticLines.len == 0

  test "an unrecognised schema is refused, and the document is not parsed":
    # Q5: `codetracer.target-recognition.v1` is a stable contract between two
    # INDEPENDENTLY RELEASED repositories — the core discovers ct-native-replay
    # on PATH rather than bundling it — so a version-skewed pair is a real
    # deployment state and mis-parsing one is a real risk.
    let future = goDocument("/tmp/whatever")
      .replace(RecognitionSchema, "codetracer.target-recognition.v2")
    let outcome = parseRecognitionDocument(future)
    checkpoint("failure: " & outcome.failure.join(" | "))
    check outcome.status == rsUnsupportedSchema
    let text = outcome.failure.join("\n")
    # Names what it found AND what it supports — both halves of Q5's rule.
    check "codetracer.target-recognition.v2" in text
    check RecognitionSchema in text
    # Refused, not parsed: nothing from the document leaked into the result.
    check outcome.recognition.primary.isNone
    check outcome.recognition.components.len == 0
    check outcome.recognition.kind == ""

    let decision = decideFromRecognition(outcome, "/tmp/whatever")
    check decision.kind == rdDegraded
    check decision.lang == LangUnknown

  test "a document with no schema field is refused rather than sniffed":
    var document = parseJson(goDocument("/tmp/whatever"))
    document.delete("schema")
    let outcome = parseRecognitionDocument($document)
    check outcome.status == rsMalformedOutput
    check "schema" in outcome.failure.join("\n")

  test "output that is not a document at all is refused with a diagnostic":
    for raw in ["", "not json at all", "[1, 2, 3]"]:
      checkpoint("raw stdout: " & raw)
      let outcome = parseRecognitionDocument(raw)
      check outcome.status == rsMalformedOutput
      check outcome.failure.len > 0

  test "an unknown enum value is not a parse error":
    # The other half of Q5's consumer obligation.  Without this, every
    # additively-added language on the producer side is a silently breaking
    # change on the consumer side.
    let exotic = goDocument("/tmp/whatever").replace("\"go\"", "\"zig\"")
    let outcome = parseRecognitionDocument(exotic)
    check outcome.status == rsOk
    check outcome.recognition.primary.isSome
    check outcome.recognition.primary.get.language == "zig"
    # "not recognised by me", never a failure.
    check langFromWireName("zig") == LangUnknown
    check decideFromRecognition(outcome, "/tmp/x").kind == rdNoLanguage

  test "the wire language names map onto the recorder-selecting Lang values":
    # `pythondb` and `rubydb` are the spellings that choose a RECORDER, and
    # `toLang` does not know either of them, so losing this mapping would be a
    # recorder change disguised as a parse gap.
    check langFromWireName("go") == LangGo
    check langFromWireName("rust") == LangRust
    check langFromWireName("c") == LangC
    check langFromWireName("ada") == LangAda
    check langFromWireName("pythondb") == LangPythonDb
    check langFromWireName("rubydb") == LangRubyDb
    check langFromWireName("") == LangUnknown
    check langFromWireName("no-such-language") == LangUnknown

    # The plain interpreter spellings, which are what NTR-3's shebang signal
    # will produce.  `toLang` is ASYMMETRIC about these — `"python"` gives
    # `LangPythonDb` but `"ruby"` gives `LangRuby`, which does NOT use
    # materialized traces and would therefore send a Ruby script down the
    # NATIVE path.  Both are pinned to the recorder-selecting value so the wire
    # mapping is uniform; without the second line, `recognize` reporting
    # `interpreter: ruby` would silently change which recorder runs.
    check langFromWireName("python") == LangPythonDb
    check langFromWireName("ruby") == LangRubyDb
    check langFromWireName("PythonDb") == LangPythonDb   # case-insensitive
    check langFromWireName("  ruby  ") == LangRubyDb     # and whitespace
    # Every value this table maps must select a recorder that actually uses a
    # materialized trace, or the mapping is not doing the job it exists for.
    for wire in ["python", "ruby", "pythondb", "rubydb"]:
      checkpoint("wire language: " & wire)
      check langFromWireName(wire).usesMaterializedTraces

  test "Q7: two consecutive recognitions of one target spawn the recognizer twice":
    # There is NO cache.  The `(path, mtime, size)` key was rejected precisely
    # because an mtime-preserving rebuild would return the previous answer for
    # a different binary — a confident wrong answer with no diagnostic
    # anywhere.  A cache introduced later fails this test by name.
    let stub = setupStub("no-cache", goDocument("__TARGET__"))
    let first = detectTarget(stub.target, LangUnknown, backend = stubBackend())
    let second = detectTarget(stub.target, LangUnknown, backend = stubBackend())
    check first.lang == LangGo
    check second.lang == LangGo

    let spawns = spawnLines(stub.logPath)
    checkpoint("spawns: " & $spawns.len & " -> " & spawns.join(" / "))
    check spawns.len == 2
    check spawns[0] == spawns[1]

    # And recognition writes nothing of its own next to the target.
    var produced: seq[string] = @[]
    for path in walkDirRec(stub.dir):
      produced.add(path.extractFilename)
    checkpoint("files under the target's directory: " & produced.join(", "))
    check produced.len == 3  # the target, the canned document, the spawn log

  test "Q8: --lang skips recognition entirely, in both directions":
    # Direction 1: with --lang, the recognizer is NOT SPAWNED AT ALL.  Not
    # "spawned and overruled" — an escape hatch that still runs the machinery
    # it escapes is not one.
    let withLang = setupStub("lang-given", goDocument("__TARGET__"))
    let pinned = detectTarget(withLang.target, LangRust,
                              backend = stubBackend())
    check pinned.lang == LangRust
    check not pinned.recognitionRan
    check pinned.recognition.isNone
    checkpoint("spawns with --lang: " & $spawnLines(withLang.logPath).len)
    check spawnLines(withLang.logPath).len == 0

    # Direction 2: without it, on the very same target, it IS spawned.  Both
    # halves are needed: direction 1 alone also passes if the delegation is
    # broken outright.
    let withoutLang = setupStub("lang-absent", goDocument("__TARGET__"))
    let recognizedTarget = detectTarget(withoutLang.target, LangUnknown,
                                        backend = stubBackend())
    check recognizedTarget.lang == LangGo
    check recognizedTarget.recognitionRan
    check spawnLines(withoutLang.logPath).len == 1

  test "Q8: the consequence is thinner metadata, and it is legible as such":
    # `recognitionRan == false` is what a consumer must read as "not computed",
    # rather than as "the target had no components/format/interpreter".
    let stub = setupStub("lang-metadata", goDocument("__TARGET__"))
    let pinned = detectTarget(stub.target, LangGo, backend = stubBackend())
    check not pinned.recognitionRan
    check pinned.recognition.isNone
    check pinned.diagnosticLines.len == 0

  test "an ambiguous ledger names --lang and never falls back silently":
    # Design rule C2 / record.md's standing "never a silent pick".  The
    # `ambiguous-language` code is the ONE acted-on diagnostic; NTR-3 is what
    # makes the recognizer emit it, and this pins the core's half in advance so
    # the two cannot land out of step.
    var document = parseJson(unknownDocument("/tmp/ambiguous"))
    document["diagnostics"] = %*[
      {"code": DiagAmbiguousLanguage,
       "message": "Cargo.toml claims rust; Nargo.toml claims noir"}
    ]
    let outcome = parseRecognitionDocument($document)
    check outcome.status == rsOk
    let decision = decideFromRecognition(outcome, "/tmp/ambiguous")
    check decision.kind == rdAmbiguous
    check decision.lang == LangUnknown
    let text = decision.lines.join("\n")
    checkpoint("ambiguity diagnostic:\n" & text)
    check "--lang" in text
    check "/tmp/ambiguous" in text
    check "Cargo.toml claims rust" in text

  test "every other diagnostic code is informational and is not acted on":
    # §6.2's two-class table: exactly one code is acted on.  A core that
    # escalated on `dwarf-read-failed` or `target-is-directory` would refuse to
    # record perfectly recordable programs.
    for code in ["target-is-directory", "not-an-object-file",
                 "no-language-evidence", "shebang-recognition-pending",
                 "dwarf-read-failed", "evidence-outranks-name",
                 "interpreter-refines-extension",
                 "interpreter-overrides-extension"]:
      checkpoint("informational code: " & code)
      var document = parseJson(unknownDocument("/tmp/informational"))
      document["diagnostics"] = %*[{"code": code, "message": "..."}]
      let outcome = parseRecognitionDocument($document)
      let decision = decideFromRecognition(outcome, "/tmp/informational")
      check decision.kind == rdNoLanguage

  test "an absent recognizer degrades without a crash and without a claim":
    # The verification row: with ct-native-replay absent AND disabled in the
    # config, `ct record` must still reach its existing actionable guidance
    # rather than a recognition crash.
    let dir = freshDir("absent-backend")
    let target = dir / "native-target"
    writeFile(target, "x\n")

    let disabled = detectTarget(
      target, LangUnknown,
      backend = RecognitionBackend(resolved: true, enabled: false, path: ""))
    check disabled.lang == LangUnknown
    check not disabled.recognitionRan

    let missing = recognizeTarget(dir / "no-such-binary", target)
    checkpoint("failure: " & missing.failure.join(" | "))
    check missing.status == rsSpawnFailed
    check missing.failure.len > 0
    check decideFromRecognition(missing, target).kind == rdDegraded

  test "an earlier signal still answers, and the recognizer is not consulted":
    # NTR-2 replaces the delegation; it does not move it.  The extension and
    # the project-manifest signals answer first exactly as before, so no
    # existing recording gains a process spawn.  (Combining every signal into
    # one ledger is §5 and belongs to NTR-3.)
    let stub = setupStub("extension-wins", goDocument("__TARGET__"))
    let script = stub.dir / "program.py"
    writeFile(script, "print('hi')\n")
    check detectTarget(script, LangUnknown, backend = stubBackend()).lang ==
      LangPythonDb
    check spawnLines(stub.logPath).len == 0

    let project = stub.dir / "project"
    createDir(project)
    writeFile(project / "Nargo.toml", "[package]\n")
    check detectTarget(project, LangUnknown, backend = stubBackend()).lang ==
      LangNoir
    check spawnLines(stub.logPath).len == 0

  test "a target that does not exist is not delegated about":
    # `recognize` would only report the I/O error the caller is about to report
    # anyway, and the existing "folder/path doesn't exist?" message already
    # names this case.
    let stub = setupStub("missing-target", goDocument("__TARGET__"))
    let detected = detectTarget(stub.dir / "no-such-file", LangUnknown,
                                backend = stubBackend())
    check detected.lang == LangUnknown
    check not detected.recognitionRan
    check spawnLines(stub.logPath).len == 0
