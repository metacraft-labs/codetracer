## record_dispatch_test.nim
##
## The dispatch table of `ct record`, asserted as data.
##
## `ct record <program>` detects a language (src/common/lang.nim,
## src/ct/utilities/language_detection.nim) and then has to reach the recorder
## that can actually record it.  Language detection and dispatch were two
## unconnected tables: detection mapped ``.php`` → ``LangPhp``, ``.ex``/``.exs``
## → ``LangElixir`` and ``.erl`` → ``LangErlang``, and ``USES_MATERIALIZED_TRACES``
## marked all three as having a dedicated recorder — but the dispatch chain in
## ``src/ct/db_backend_record.nim`` had no arm for any of them, so `ct record
## app.php` printed ``ERROR: unsupported trace kind db`` and exited **0**.
##
## This test is the thing that makes that class of gap impossible to
## reintroduce.  It is table-driven and records nothing: everything it
## exercises is the PURE half of ``src/ct/trace/recorder_dispatch.nim``, which
## exists precisely so the selection can be asserted without a toolchain.
##
## Three properties, in increasing order of strength:
##
## 1. Per-language rows: a ``.php`` program selects the PHP extension, a
##    ``.rb`` program selects codetracer-ruby-recorder, and so on — with the
##    exact argv each recorder is invoked with, so a silently-changed flag
##    name is a test failure rather than a runtime one.
## 2. The invariant that closes the gap: EVERY language marked
##    ``usesMaterializedTraces`` must have a supported recorder AND a
##    non-empty invocation.  A future language added to the ``Lang`` enum and
##    to ``USES_MATERIALIZED_TRACES`` but not to the dispatch table fails
##    here, at the table, instead of at a user's terminal.  The single
##    exception is ``RecorderPendingLanguages`` — a language whose recorder
##    does not EXIST yet, as opposed to existing and not being wired up — and
##    it is an exception only to the *selection* half: a pending language is
##    still required by (3) to name its recorder and its remedy.
## 3. Every language reachable from a file extension by ``detectLangFromPath``
##    either dispatches or is explicitly declared unsupported with a remedy —
##    there is no third, silent outcome.
##
## Mocking justification (workspace policy on mock objects): none. There is no
## mock in this file. It calls the production dispatch table directly and
## asserts what it returns; the only reason no recording happens is that
## selection is a pure function, which is the design this test is protecting.
##
## Compile and run:
##   nim c -r src/tests/cli/record_dispatch_test.nim

import std/[os, strutils, unittest]
import ../../common/lang
import ../../ct/utilities/language_detection
import ../../ct/trace/recorder_dispatch

const
  Program = "/tmp/ct-dispatch-test/app"
  TraceFolder = "/tmp/ct-dispatch-test/out"

type
  DispatchRow = object
    ## One expected row of the table: a language, the recorder that must be
    ## selected for it, and the shape of the argv it must be invoked with.
    lang: Lang
    extension: string        ## the extension a user types; "" when folder-based
    recorderLabel: string
    sibling: string
    argsContain: seq[string] ## substrings that MUST appear in argv
    server: ServerSupport

const DispatchRows = [
  DispatchRow(
    lang: LangPhp, extension: "php",
    recorderLabel: "codetracer.so (the CodeTracer PHP extension)",
    sibling: "codetracer-php-recorder",
    # codetracer-php-recorder ships no executable: the recorder is a Zend
    # extension loaded into `php` itself.
    argsContain: @["-d", "extension=", Program],
    server: ssWorkerDir),
  DispatchRow(
    lang: LangRubyDb, extension: "rb",
    recorderLabel: "codetracer-ruby-recorder",
    sibling: "codetracer-ruby-recorder",
    argsContain: @["--out-dir", TraceFolder, Program],
    server: ssMiddleware),
  DispatchRow(
    lang: LangPythonDb, extension: "py",
    recorderLabel: "codetracer-python-recorder",
    sibling: "codetracer-python-recorder",
    argsContain: @["--out-dir", TraceFolder, Program],
    server: ssMiddleware),
  DispatchRow(
    lang: LangJavascript, extension: "js",
    recorderLabel: "codetracer-js-recorder",
    sibling: "codetracer-js-recorder",
    argsContain: @["record", "--out-dir", TraceFolder, Program],
    server: ssMiddleware),
  DispatchRow(
    lang: LangElixir, extension: "exs",
    recorderLabel: "codetracer-beam-recorder",
    sibling: "codetracer-beam-recorder",
    # The BEAM recorder wraps the command that starts the BEAM program
    # rather than taking a script path, hence the `--`.
    argsContain: @["record", "--out-dir", TraceFolder, "--source-dir", "--",
                   Program],
    server: ssMiddleware),
  DispatchRow(
    lang: LangErlang, extension: "erl",
    recorderLabel: "codetracer-beam-recorder",
    sibling: "codetracer-beam-recorder",
    argsContain: @["record", "--out-dir", TraceFolder, "--source-dir", "--",
                   Program],
    server: ssMiddleware),
  DispatchRow(
    lang: LangBash, extension: "sh",
    recorderLabel: "codetracer-bash-recorder",
    sibling: "codetracer-shell-recorders",
    argsContain: @["--out-dir", TraceFolder, Program],
    server: ssUnsupported),
  DispatchRow(
    lang: LangZsh, extension: "zsh",
    recorderLabel: "codetracer-zsh-recorder",
    sibling: "codetracer-shell-recorders",
    argsContain: @["--out-dir", TraceFolder, Program],
    server: ssUnsupported),
  DispatchRow(
    lang: LangNoir, extension: "nr",
    recorderLabel: "nargo",
    sibling: "noir",
    # nargo traces the package it runs INSIDE, so the program is the
    # working directory rather than an argument.
    argsContain: @["trace", "--out-dir", TraceFolder],
    server: ssUnsupported),
  DispatchRow(
    lang: LangCairo, extension: "cairo",
    recorderLabel: "codetracer-cairo-recorder",
    sibling: "codetracer-cairo-recorder",
    argsContain: @["record", "--out-dir", TraceFolder, Program],
    server: ssUnsupported),
  DispatchRow(
    lang: LangSolidity, extension: "sol",
    recorderLabel: "codetracer-evm-recorder",
    sibling: "codetracer-evm-recorder",
    argsContain: @["record", "--out-dir", TraceFolder, Program],
    server: ssUnsupported),
  DispatchRow(
    lang: LangNim, extension: "nim",
    recorderLabel: "ct-mcr",
    sibling: "codetracer-native-recorder",
    argsContain: @[],  # recordNim owns the argv (compile step + ct-mcr)
    server: ssUnsupported),
]

const RecorderPendingLanguages = {LangGdScript}
  ## The materialized-trace languages whose RECORDER DOES NOT EXIST YET — as
  ## distinct from a recorder that exists and is merely not wired up, which is
  ## the PHP/Elixir/Erlang bug this file was written for and which this set must
  ## never be allowed to hide.  Membership is not a way to silence the invariant
  ## below: a member still has to be DECLARED, never silent, and "an unsupported
  ## language is declared, never silent" asserts exactly that for every one of
  ## them.
  ##
  ## `LangGdScript` is the only member, and it is the only kind of case that
  ## qualifies.  GDScript's recorder is not a `codetracer-*-recorder` sibling at
  ## all: the only per-line seam in GDScript is the `OPCODE_LINE` case inside
  ## Godot's own bytecode interpreter, which no GDExtension can reach, so the
  ## recorder IS a patched Godot engine
  ## (codetracer-specs/Recording-Backends/GDScript-Recorder.md, "Why a Godot
  ## Engine Fork"; Planned-Features/Mixed-Trace-GDScript.md §1).  CodeTracer
  ## does not ship that engine: the repo the spec names for it
  ## (`codetracer-engine-godot`) is not in the workspace, there is no sibling
  ## checkout of it, and `scripts/detect-siblings.sh` exports no variable for
  ## it.  There is therefore nothing for `ct` to select: a `supported: true` arm
  ## could only be written by inventing a discovery variable and an argv that
  ## the engine would afterwards have to honour, which is a worse failure than
  ## saying plainly that the recorder is not available.
  ##
  ## `usesMaterializedTraces(LangGdScript)` stays `true` because it is right
  ## about the ARTEFACT and is read on the REPLAY path, not only the record one:
  ## `loadCalltraceMode` (`src/common/trace_index.nim`) would default a stored
  ## GDScript trace to `NoInstrumentation`, `DebuggerService.lineStepJump`
  ## (`src/frontend/services/debugger_service.nim`) would degrade a jump into
  ## repeated `step-in`, and `ct record` itself would stop sending
  ## `--trace-kind db` (`src/ct/trace/record.nim`) and try to record a `.gd`
  ## file through the native rr/MCR path.  Flipping the flag to make this file
  ## green would break opening the very traces the language was added to open.
  ##
  ## WHAT FLIPS A LANGUAGE OUT OF THIS SET: its recorder becomes something `ct`
  ## can resolve and spawn — for GDScript, the patched engine is published and
  ## discoverable.  Then `recorderToolFor` gains a `supported: true` arm with a
  ## real invocation, and the entry is deleted from here; the invariant below
  ## goes back to being unconditional for it with no other change.

proc joinedArgs(lang: Lang): string =
  recorderInvocation(lang, Program, TraceFolder).args.join(" ")

suite "ct record dispatch table":

  test "each language selects its own recorder":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      let tool = recorderToolFor(row.lang)
      check tool.supported
      check tool.recorderLabel == row.recorderLabel
      check tool.sibling == row.sibling
      # Every supported recorder must document how to get it — the whole
      # point of the "honest failure" requirement is that the remedy exists.
      check tool.installHint.len > 0

  test "a source file extension reaches the language it dispatches to":
    # The bridge the gap lived in: detection produced these languages and
    # nothing consumed them.  Assert both halves agree.
    for row in DispatchRows:
      if row.extension.len == 0:
        continue
      checkpoint("extension: ." & row.extension)
      check detectLangFromPath("app." & row.extension, isWasm = false) ==
        row.lang

  test "each recorder is invoked with the argv it documents":
    for row in DispatchRows:
      if row.argsContain.len == 0:
        continue
      checkpoint("language: " & row.lang.toName)
      let args = joinedArgs(row.lang)
      for fragment in row.argsContain:
        checkpoint("  expected argv fragment: " & fragment)
        check fragment in args

  test "server support is declared per language":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      check serverSupport(row.lang) == row.server

  test "PHP server mode selects the worker-directory environment":
    # The PHP extension picks its output layout from the environment:
    # CODETRACER_TRACE_DIR is the verbatim single-process directory a plain
    # `ct record app.php` wants, CODETRACER_OUTPUT_DIR makes each worker
    # write its own `worker_<pid>/` beneath it, which is what a recorded
    # `php -S` server needs.  Getting this backwards silently produces a
    # container in the wrong place, so it is asserted rather than assumed.
    let plain = recorderInvocation(LangPhp, Program, TraceFolder)
    let server = recorderInvocation(
      LangPhp, Program, TraceFolder, RecorderOptions(server: true))

    var plainKeys, serverKeys: seq[string]
    for (name, _) in plain.env: plainKeys.add(name)
    for (name, _) in server.env: serverKeys.add(name)

    check "CODETRACER_TRACE_DIR" in plainKeys
    check "CODETRACER_OUTPUT_DIR" notin plainKeys
    check "CODETRACER_OUTPUT_DIR" in serverKeys
    check "CODETRACER_TRACE_DIR" notin serverKeys
    # The extension refuses to record at all without this.
    check "CODETRACER_ENABLED" in plainKeys
    check "CODETRACER_ENABLED" in serverKeys

  test "every materialized-trace language has a recorder and an invocation":
    # THE invariant.  `usesMaterializedTraces` is the flag that routes a
    # language to the recorder side of `ct record`; a language that claims it
    # but has no dispatch arm is exactly the PHP/Elixir/Erlang bug.
    for lang in Lang:
      if not lang.usesMaterializedTraces:
        continue
      checkpoint("materialized language: " & lang.toName)
      if lang in RecorderPendingLanguages:
        # There is no recorder to select yet, so there is nothing to assert an
        # invocation against.  The requirement that survives is the other one:
        # the language must still be declared rather than silent, which the
        # two tests below assert for exactly this set.  Pinning
        # `not supported` here is deliberate — it means a recorder that DOES
        # get wired up fails this line until it is removed from the set, so
        # the set cannot quietly outlive the gap it records.
        check(not recorderToolFor(lang).supported)
        continue
      check recorderToolFor(lang).supported
      let invocation = recorderInvocation(lang, Program, TraceFolder)
      if lang == LangNim:
        # recordNim owns its argv (it compiles first, then hands off to
        # ct-mcr), so the table only has to name the tool for it.
        check recorderToolFor(lang).recorderLabel.len > 0
      else:
        check invocation.args.len > 0
        # The recorder has to be TOLD where to write, one way or another:
        # most take `--out-dir` in argv, nargo is told by working directory,
        # and the PHP extension is configured purely through the
        # environment because it has no command line of its own.
        var envMentionsFolder = false
        for (_, value) in invocation.env:
          if value == TraceFolder:
            envMentionsFolder = true
        check invocation.args.contains(TraceFolder) or
          invocation.workdir.len > 0 or envMentionsFolder

  test "every dispatchable language names its recorder and its remedy":
    # Deliberately NOT skipped for `RecorderPendingLanguages`: a language whose
    # recorder does not exist yet still has to name what the recorder is, which
    # repo it comes from and how to get it.  "No recorder" is an answer; an
    # empty label with no remedy is the silence this file exists to forbid.
    for lang in Lang:
      if not lang.usesMaterializedTraces:
        continue
      checkpoint("materialized language: " & lang.toName)
      let tool = recorderToolFor(lang)
      check tool.recorderLabel.len > 0
      check tool.sibling.len > 0
      check tool.installHint.len > 0

  test "an unsupported language is declared, never silent":
    # LangRuby and LangPython are the retired rr/gdb backends: they are still
    # reachable through an explicit `--lang ruby` / `--lang python`, and the
    # only correct answer is to say so and point at the working spelling.
    #
    # `RecorderPendingLanguages` is held to the SAME bar, from the other
    # direction.  GDScript is reachable today through an explicit
    # `--lang gdscript` (`toLang` in `src/common/lang.nim` maps both `gd` and
    # `gdscript`), and before this arm existed that produced one bare
    # "error: CodeTracer has no recorder for GDScript." line with no help under
    # it and no way for the user to learn that the recorder is a patched Godot
    # engine.
    #
    # NOTE, and it is a SEPARATE gap from the one this arm closes: `.gd` is NOT
    # auto-detected.  `detectLangFromPath` reads `LANGS`
    # (`src/ct/utilities/language_detection.nim`), which has no `gd` entry, so a
    # bare `ct record foo.gd` resolves to `LangUnknown` and takes the native
    # build path instead of reaching this message at all.  That is a missing
    # extension registration in the language table, not a missing recorder, so
    # it is deliberately NOT fixed here; this arm is what makes the answer
    # correct the moment the extension is registered.
    const DeclaredUnsupported = {LangRuby, LangPython} + RecorderPendingLanguages
    for lang in DeclaredUnsupported:
      checkpoint("declared-unsupported language: " & lang.toName)
      let tool = recorderToolFor(lang)
      check not tool.supported
      check tool.installHint.len > 0
      let message = missingRecorderMessage(lang, @[]).join("\n")
      check "error:" in message
      check "help:" in message
      check lang.toName in message

  test "the missing-recorder message names the language and the remedy":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      # Simulate every artifact of this language being absent.
      var absent: seq[RecorderArtifact] = @[]
      for artifact in recorderRequirements(row.lang):
        absent.add(RecorderArtifact(
          kind: artifact.kind, label: artifact.label,
          envVar: artifact.envVar, path: ""))
      let message = missingRecorderMessage(row.lang, absent).join("\n")
      check message.startsWith("error:")
      check row.lang.toName in message
      check row.sibling in message
      # The remedy has to be actionable: either an env var to set or a
      # command to run.
      check ("help:" in message)

  test "the server-unsupported message names the flag and the alternatives":
    let message = serverUnsupportedMessage(LangNim).join("\n")
    check "--server" in message
    check LangNim.toName in message
    check "Python" in message
    check "PHP" in message

  test "server guidance tells the user where to watch the recording":
    for lang in [LangPhp, LangRubyDb, LangJavascript, LangElixir]:
      checkpoint("language: " & lang.toName)
      let guidance = serverGuidance(lang, TraceFolder).join("\n")
      check TraceFolder in guidance
      check "ct replay -t " & TraceFolder in guidance

  test "recorder discovery uses the documented environment variables":
    # `scripts/detect-siblings.sh` is what makes a sibling checkout usable,
    # and it works by exporting exactly these variables.  A rename on either
    # side silently disconnects the dev shell from `ct`, so the names are
    # pinned here.
    const Expected = {
      LangRubyDb: "CODETRACER_RUBY_RECORDER_PATH",
      LangJavascript: "CODETRACER_JS_RECORDER_PATH",
      LangPhp: "CODETRACER_PHP_RECORDER_EXTENSION",
      LangElixir: "CODETRACER_BEAM_RECORDER_BIN",
      LangErlang: "CODETRACER_BEAM_RECORDER_BIN",
      LangNim: "CODETRACER_CT_MCR_CMD",
      LangCairo: "CODETRACER_CAIRO_RECORDER_PATH",
    }
    for (lang, envVar) in Expected:
      checkpoint("language: " & lang.toName)
      check recorderToolFor(lang).recorderEnvVar == envVar

    let detectSiblings = currentSourcePath.parentDir.parentDir.parentDir
      .parentDir / "scripts" / "detect-siblings.sh"
    check fileExists(detectSiblings)
    let script = readFile(detectSiblings)
    # Only the variables that script is actually responsible for.  Ruby, the
    # JS CLI and the shell recorders are exposed through PATH instead, and
    # the Python recorder through its venv interpreter, so their names are
    # asserted above against the table but not against the script.
    for envVar in ["CODETRACER_PHP_RECORDER_EXTENSION",
                   "CODETRACER_BEAM_RECORDER_BIN",
                   "CODETRACER_CT_MCR_CMD",
                   "CODETRACER_NATIVE_SERVER_RECORDER_PATH"]:
      checkpoint("detect-siblings.sh must export " & envVar)
      check envVar in script
