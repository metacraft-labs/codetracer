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

proc assessmentDocument(target: string; specific: seq[string];
                        family = "project-directory";
                        producer = "ct-native-replay/0.9.0";
                        schema = TargetAssessmentSchema;
                        envelope = RecognitionSchemaV2): string =
  ## A `codetracer.target-recognition.v2` envelope carrying one embedded
  ## `codetracer.target-assessment.v1`, shaped exactly as
  ## `codetracer-native-backend/src/recognize.rs` emits it.  Every knob a skew
  ## case needs is a parameter, because the whole point of these cases is a
  ## producer this build was not compiled against.
  var kinds = newJArray()
  for k in specific:
    kinds.add(newJString(k))
  $ %*{
    "schema": envelope,
    "target": target,
    "kind": "directory",
    "primary": nil,
    "components": [],
    "interpreter": nil,
    "format": nil,
    "debug_info": {"present": false, "kind": nil},
    "recommended": nil,
    "diagnostics": [],
    "assessment": {
      "schema": schema,
      "producer": producer,
      "target": target,
      "kind": {"specific": kinds, "family": family},
      "toolchain": "unknown",
      "target_isa": "unknown",
      "arch": "",
      "recording_approach": "unknown",
      "languages": [],
      "diagnostics": []
    }
  }

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
    # LRS-2P made `v2` a schema this build DOES read (it is the envelope that
    # carries an embedded assessment), so the unknown version this case drives
    # with is `v3`.  The property under test is unchanged and the case is not
    # weakened: it still asserts that an unrecognised schema is refused before
    # any other key is read.  `v2`'s own refusal rules get their own cases
    # in the LRS-2P suite below.
    let future = goDocument("/tmp/whatever")
      .replace(RecognitionSchema, "codetracer.target-recognition.v3")
    let outcome = parseRecognitionDocument(future)
    checkpoint("failure: " & outcome.failure.join(" | "))
    check outcome.status == rsUnsupportedSchema
    let text = outcome.failure.join("\n")
    # Names what it found AND what it supports — both halves of Q5's rule.
    check "codetracer.target-recognition.v3" in text
    check RecognitionSchemaV1 in text
    check RecognitionSchemaV2 in text
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
    # will produce.  `toLang` used to be ASYMMETRIC about these — `"python"`
    # gave `LangPythonDb` but `"ruby"` gave `LangRuby`, the retired rr
    # backend, which did NOT use materialized traces and would have sent a
    # Ruby script down the NATIVE path.  LRS-4 deleted `LangRuby` (design
    # Q6), so `toLang` and the wire table now AGREE on both; the wire rows
    # stay explicit and this pins that they select the recorder AND that
    # they no longer shadow `toLang`.
    check langFromWireName("python") == LangPythonDb
    check langFromWireName("ruby") == LangRubyDb
    check toLang("ruby") == LangRubyDb
    check toLang("python") == LangPythonDb
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


# ---------------------------------------------------------------------------
# LRS-2P: the assessment on the wire, and the version skew it exists for
#
# The property this suite tests is NOT "a matched pair works".  It is what
# happens when the two halves of a PATH-discovered pair were built at
# different times, which design 9.2 records as a routine deployment state
# this project has already been bitten by twice.  Every case below drives the
# production parser with a document the CURRENT producer would never emit --
# which is exactly what an OLDER or NEWER producer does emit.
# ---------------------------------------------------------------------------

suite "LRS-2P: `codetracer.target-assessment.v1`, embedded and version-skewed":

  test "a v1 document MEANS no assessment was computed -- a fact, not a gap":
    # Design 9.5: the schema bump is spent so that `v1` can SAY something.
    # Without this, "the producer computed nothing" and "the producer predates
    # the field" are one state, which is the exact conflation `recognitionRan`
    # exists one layer up to prevent.
    let outcome = parseRecognitionDocument(goDocument("/tmp/whatever"))
    check outcome.status == rsOk
    check outcome.recognition.schema == RecognitionSchemaV1
    check(not outcome.recognition.assessmentComputed)
    # ...and BOTH versions are accepted, which is what the constant was made a
    # list for.  Dropping either one is a skew break in one direction.
    check RecognitionSchemaV1 in SupportedRecognitionSchemas
    check RecognitionSchemaV2 in SupportedRecognitionSchemas

  test "an `assessment` key in a v1 document is IGNORED, not sniffed":
    # The schema string is the only supported way to detect the version.  A
    # consumer that read the key when it was present would be guessing the
    # version from field presence, which this module refuses to do for the
    # envelope and must refuse to do here for the same reason.
    let sniffable = assessmentDocument("/tmp/whatever", @[KindCargoProject],
                                       envelope = RecognitionSchemaV1)
    let outcome = parseRecognitionDocument(sniffable)
    check outcome.status == rsOk
    check(not outcome.recognition.assessmentComputed)
    check outcome.recognition.assessment.kind.specific.len == 0

  test "a v2 document WITHOUT an assessment is refused, not read as empty":
    # The other half of the same rule.  A v2 that carries nothing would
    # re-create the ambiguity the bump was spent to remove, so it is
    # malformed.
    var document = parseJson(
      assessmentDocument("/tmp/whatever", @[KindCargoProject]))
    document.delete("assessment")
    let outcome = parseRecognitionDocument($document)
    check outcome.status == rsMalformedOutput
    let text = outcome.failure.join("\n")
    check RecognitionSchemaV2 in text
    check RecognitionSchemaV1 in text
    check "assessment" in text

  test "a matched pair reads the kind, the producer and the axes":
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/crate", @[KindCargoProject]))
    check outcome.status == rsOk
    check outcome.recognition.assessmentComputed
    let a = outcome.recognition.assessment
    check a.schema == TargetAssessmentSchema
    check a.producer == "ct-native-replay/0.9.0"
    check a.kind.family == tfProjectDirectory
    check a.kind.specificKinds == @[KindCargoProject]
    check a.kind.understand(UnderstoodSpecificKinds, a.producer).ok
    check a.kind.understand(UnderstoodSpecificKinds, a.producer).status == krExact
    check a.kind.understand(UnderstoodSpecificKinds, a.producer).diagnostic == ""

  test "SKEW (a): a specific kind this build never heard of DEGRADES, and says so":
    # The producer is newer.  `cmake-project` is design 9.3's own example of a
    # kind that needs no schema bump, so the document is valid and the
    # consumer must act on the family -- OUT LOUD.  The failure this case
    # exists to catch is the silent version: acting on the family and saying
    # nothing, which works, records something plausible, and leaves the user
    # with no clue that their core is behind their recognizer.
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/proj", @["cmake-project"]))
    check outcome.status == rsOk          # additive: NOT an error
    let a = outcome.recognition.assessment
    let verdict = a.kind.understand(UnderstoodSpecificKinds, a.producer)
    check verdict.status == krFamilyOnly
    check verdict.ok                       # it may proceed ...
    check verdict.token == token(tfProjectDirectory)
    check verdict.diagnostic.len > 0       # ... but not silently
    check "cmake-project" in verdict.diagnostic
    check "project-directory" in verdict.diagnostic
    check "ct-native-replay/0.9.0" in verdict.diagnostic   # THE PRODUCER

  test "SKEW (a): the degradation names the producer even when it is absent":
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/proj", @["cmake-project"], producer = ""))
    let a = outcome.recognition.assessment
    let verdict = a.kind.understand(UnderstoodSpecificKinds, a.producer)
    check verdict.diagnostic.len > 0
    check "(unnamed)" in verdict.diagnostic

  test "SKEW (a): a kind the build DOES know is not reported as a degradation":
    # The control that stops the case above being vacuous: if every document
    # produced a degradation line the line would carry no information.
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/crate", @[KindCargoProject]))
    let a = outcome.recognition.assessment
    check a.kind.understand(UnderstoodSpecificKinds, a.producer).diagnostic == ""

  test "SKEW (b): a family this build never heard of REFUSES, naming the producer":
    # Families are frozen for the life of a schema major version (design 9.4),
    # so a token outside the vocabulary is rule K3's protocol error and not an
    # additive change.  It is refused BEFORE anything else in the assessment
    # is trusted.
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/thing", @["container-layer"],
                         family = "container-image"))
    check outcome.status == rsUnsupportedAssessment
    let text = outcome.failure.join("\n")
    check "container-image" in text                        # the token
    check "ct-native-replay/0.9.0" in text                 # THE PRODUCER
    check "project-directory" in text                      # the vocabulary
    check "prebuilt-artefact" in text
    check "single-file" in text
    # Refused, not partly read: nothing from the assessment leaked out.
    check(not outcome.recognition.assessmentComputed)
    check outcome.recognition.assessment.kind.specific.len == 0
    # ...and it is a PROTOCOL ERROR, not a degradation: design 10.4's
    # asymmetry, where the launcher ignores what it cannot read and the
    # assessment refuses it.
    let decision = decideFromRecognition(outcome, "/tmp/thing")
    check decision.kind == rdProtocolError

  test "SKEW (b): an assessment schema this build does not read is refused too":
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/thing", @[KindCargoProject],
                         schema = "codetracer.target-assessment.v2"))
    check outcome.status == rsUnsupportedAssessment
    let text = outcome.failure.join("\n")
    check "codetracer.target-assessment.v2" in text
    check TargetAssessmentSchema in text
    check "ct-native-replay/0.9.0" in text

  test "K4: `unassessable` refuses rather than degrading, and names the producer":
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/thing", @["licensed-blob"],
                         family = "unassessable"))
    check outcome.status == rsOk       # the FAMILY is known; K4 is a verdict
    let a = outcome.recognition.assessment
    let verdict = a.kind.understand(UnderstoodSpecificKinds, a.producer)
    check verdict.status == krRefused
    check(not verdict.ok)
    check "licensed-blob" in verdict.diagnostic
    check "ct-native-replay/0.9.0" in verdict.diagnostic

  test "K2: two known kinds that dispatch differently are a loud ambiguity":
    let outcome = parseRecognitionDocument(
      assessmentDocument("/tmp/proj", @[KindCargoProject, KindFoundryProject]))
    let a = outcome.recognition.assessment
    let verdict = a.kind.understand(UnderstoodSpecificKinds, a.producer)
    check verdict.status == krAmbiguous
    check(not verdict.ok)
    check verdict.token == ""
    check KindCargoProject in verdict.diagnostic
    check KindFoundryProject in verdict.diagnostic
    check "ct-native-replay/0.9.0" in verdict.diagnostic

  test "an axis value this build does not know degrades and is RECORDED":
    # Unlike the family, the four axes are open at the value level: Q5's
    # consumer obligation says an unknown enum value is never a parse error.
    # It is still not silent -- it lands in `diagnostics`.
    var raw = parseJson(assessmentDocument("/tmp/proj", @[KindCargoProject]))
    raw["assessment"]["target_isa"] = newJString("risc-v-128")
    let outcome = parseRecognitionDocument($raw)
    check outcome.status == rsOk
    let a = outcome.recognition.assessment
    check a.targetIsa == tiUnknown
    check a.diagnostics.join("\n").contains("risc-v-128")
    check a.diagnostics.join("\n").contains("ct-native-replay/0.9.0")

  test "the skew is visible through the REAL spawned delegation, not only the parser":
    # `detectTarget` spawns a process, reads its stdout and version-checks the
    # document -- the same code path the shipped `ct` runs against a real
    # `ct-native-replay`.  Only the document's contents come from the stub.
    let stub = setupStub("skew-degrade",
      assessmentDocument("__TARGET__", @["cmake-project"]))
    let detected = detectTarget(stub.target, LangUnknown, backend = stubBackend())
    check detected.recognitionRan
    check detected.recognition.isSome
    check detected.recognition.get.assessmentComputed
    let a = detected.recognition.get.assessment
    check a.kind.specificKinds == @["cmake-project"]
    check a.kind.understand(UnderstoodSpecificKinds, a.producer).status ==
      krFamilyOnly
    check spawnLines(stub.logPath).len == 1
