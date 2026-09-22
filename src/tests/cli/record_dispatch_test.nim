## record_dispatch_test.nim
##
## The dispatch table of `ct record`, asserted as data.
##
## `ct record <program>` detects a language (src/common/lang.nim,
## src/ct/utilities/language_detection.nim), assesses the target
## (src/ct/trace/record_assessment.nim) and then has to reach the recorder
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
## ## The table is a function of the SELECTOR, not of `Lang` (LRS-2B)
##
## Every entry point takes a ``RecorderSelector`` — source language, target
## ISA, recording approach — because one ``Lang`` value cannot say which of two
## recorders a target needs.  The canonical case is Nim: ``a.nim`` is
## ``(slNim, tiNative, raMcr)`` and records through ``nim c`` + ``ct-mcr``;
## ``a.nims`` is ``(slNim, tiNimVm, raInstrumentedRuntime)`` and is recorded by
## the compiler's own script VM, which needs no ``ct-mcr`` at all.  Both were
## ``recorderToolFor(LangNim)``, and ``requireRecorder(LangNim)`` demanded
## ``ct-mcr`` for a script that never uses it.  The suite "one language, two
## recorders" below is that case, asserted on the real table.
##
## Three properties, in increasing order of strength:
##
## 1. Per-selector rows: a ``.php`` program selects the PHP extension, a
##    ``.rb`` program selects codetracer-ruby-recorder, and so on — with the
##    exact argv each recorder is invoked with, so a silently-changed flag
##    name is a test failure rather than a runtime one.
## 2. The invariant that closes the gap: EVERY language marked
##    ``usesMaterializedTraces`` must have a supported recorder AND a
##    non-empty invocation.  A future language added to the ``Lang`` enum and
##    marked materialized but not added to the dispatch table fails here, at
##    the table, instead of at a user's terminal.  The single exception is
##    ``RecorderPendingLanguages`` — a language whose recorder does not EXIST
##    yet, as opposed to existing and not being wired up — and it is an
##    exception only to the *selection* half: a pending language is still
##    required by (3) to name its recorder and its remedy.
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
import ../../common/target_assessment
import ../../ct/utilities/language_detection
import ../../ct/trace/recorder_dispatch
import ../../ct/trace/record_assessment

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
  ## repeated `step-in`, and the Call Trace / Event Log panes read it too.
  ## Flipping the flag to make this file green would break opening the very
  ## traces the language was added to open.
  ##
  ## Lua is deliberately NOT here even though it, too, has a declared
  ## unsupported arm: Lua is not a materialized-trace language
  ## (`MaterializedSummaryExceptions` in `common_lang.nim` says why), so the
  ## invariant below never reaches it, and the "declared, never silent" suite
  ## covers it directly by selector.
  ##
  ## WHAT FLIPS A LANGUAGE OUT OF THIS SET: its recorder becomes something `ct`
  ## can resolve and spawn — for GDScript, the patched engine is published and
  ## discoverable.  Then `recorderToolFor` gains a `supported: true` arm with a
  ## real invocation, and the entry is deleted from here; the invariant below
  ## goes back to being unconditional for it with no other change.

proc joinedArgs(sel: RecorderSelector): string =
  recorderInvocation(sel, Program, TraceFolder).args.join(" ")

func sel(lang: Lang): RecorderSelector =
  ## The per-`Lang` projection.  It is what a stored `Trace.lang` can offer;
  ## the assessment (`assessedSelector`) is what `ct record` actually uses.
  selectorOfLang(lang)

func label(lang: Lang): string = displayName(sel(lang))

suite "ct record dispatch table":

  test "each language selects its own recorder":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      let tool = recorderToolFor(sel(row.lang))
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
      check detectLangFromPath("app." & row.extension) ==
        row.lang

  test "each recorder is invoked with the argv it documents":
    for row in DispatchRows:
      if row.argsContain.len == 0:
        continue
      checkpoint("language: " & row.lang.toName)
      let args = joinedArgs(sel(row.lang))
      for fragment in row.argsContain:
        checkpoint("  expected argv fragment: " & fragment)
        check fragment in args

  test "server support is declared per language":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      check serverSupport(sel(row.lang)) == row.server

  test "PHP server mode selects the worker-directory environment":
    # The PHP extension picks its output layout from the environment:
    # CODETRACER_TRACE_DIR is the verbatim single-process directory a plain
    # `ct record app.php` wants, CODETRACER_OUTPUT_DIR makes each worker
    # write its own `worker_<pid>/` beneath it, which is what a recorded
    # `php -S` server needs.  Getting this backwards silently produces a
    # container in the wrong place, so it is asserted rather than assumed.
    let plain = recorderInvocation(sel(LangPhp), Program, TraceFolder)
    let server = recorderInvocation(
      sel(LangPhp), Program, TraceFolder, RecorderOptions(server: true))

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
    # THE invariant.  `usesMaterializedTraces` is the flag that says a
    # recording summarised as this language opens as a materialized trace; a
    # language that claims it but has no dispatch arm is exactly the
    # PHP/Elixir/Erlang bug.
    for lang in Lang:
      if not lang.usesMaterializedTraces:
        continue
      checkpoint("materialized language: " & lang.toName)
      let s = sel(lang)
      if lang in RecorderPendingLanguages:
        # There is no recorder to select yet, so there is nothing to assert an
        # invocation against.  The requirement that survives is the other one:
        # the language must still be declared rather than silent, which the
        # tests below assert for exactly this set.  Pinning `not supported`
        # here is deliberate — it means a recorder that DOES get wired up fails
        # this line until it is removed from the set, so the set cannot quietly
        # outlive the gap it records.
        check(not recorderToolFor(s).supported)
        continue
      check recorderToolFor(s).supported
      let invocation = recorderInvocation(s, Program, TraceFolder)
      if lang == LangNim:
        # recordNim owns its argv (it compiles first, then hands off to
        # ct-mcr), so the table only has to name the tool for it.
        check recorderToolFor(s).recorderLabel.len > 0
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
      let tool = recorderToolFor(sel(lang))
      check tool.recorderLabel.len > 0
      check tool.sibling.len > 0
      check tool.installHint.len > 0

  test "the summary predicate and the table agree on the materialized set":
    # `usesMaterializedTraces` is derived from the same axes the table
    # dispatches on, with two named exceptions.  Pin the relationship from
    # the table's side: a language whose per-value selector has a SUPPORTED
    # recorder that produces a materialized trace is flagged, and one that
    # is flagged has a declared arm.  The two exceptions are asserted by name
    # in `target_axes_test.nim`; here only their consequence shows.
    for lang in Lang:
      let s = sel(lang)
      let tool = recorderToolFor(s)
      if tool.supported and producesMaterializedTrace(s.approach):
        check lang.usesMaterializedTraces
      if lang.usesMaterializedTraces:
        check tool.isDeclared

  test "an unsupported language is declared, never silent":
    # The retired rr/gdb backends used to be `Lang` members -- `LangRuby` and
    # `LangPython` -- that decomposed to `(slRuby, tiInterpreted, raRr)` and
    # `(slPython, tiInterpreted, raRr)`: a native-replay approach asked of a
    # runtime-hosted language, whose only correct answer is to say so and
    # point at the working recorder.  LRS-4 (2026-09-21) DELETED both
    # members; the cell survives as a rule over the selector and is asserted
    # in the next test by constructing the selector, since no `Lang` value
    # reaches it any more.
    #
    # Correction history, kept because it is the claim this comment used to
    # make: an earlier version said both were "still reachable through an
    # explicit `--lang ruby` / `--lang python`".  The python half was always
    # wrong (`--lang python` mapped to `LangPythonDb`, so `LangPython` was
    # unreachable from any input, design §3.1); the ruby half was true until
    # LRS-4, when `--lang ruby` started naming `LangRubyDb`, the working
    # recorder (design Q6).  Neither is reachable now, and neither exists.
    #
    # `RecorderPendingLanguages` is held to the SAME bar, from the other
    # direction.  GDScript is reachable today through an explicit
    # `--lang gdscript` (`toLang` in `src/common/lang.nim` maps both `gd` and
    # `gdscript`), and before this arm existed that produced one bare
    # "error: CodeTracer has no recorder for GDScript." line with no help under
    # it and no way for the user to learn that the recorder is a patched Godot
    # engine.
    #
    # The SEPARATE gap this note used to record — "`.gd` is NOT auto-detected"
    # — is now closed, and the case below is the one that closes it.  The
    # extension is registered in `LANGS`
    # (`src/ct/utilities/language_detection.nim`), so a bare
    # `ct record foo.gd` reaches this message instead of resolving to
    # `LangUnknown` and taking the native build path.
    const DeclaredUnsupported = {LangLua} + RecorderPendingLanguages
    for lang in DeclaredUnsupported:
      checkpoint("declared-unsupported language: " & lang.toName)
      let tool = recorderToolFor(sel(lang))
      check not tool.supported
      check tool.isDeclared
      check tool.installHint.len > 0
      let message = missingRecorderMessage(sel(lang), @[]).join("\n")
      check "error:" in message
      check "help:" in message
      check label(lang) in message

  test "the retired rr pair points at the working recorder, as ONE rule":
    # The two hand-written `LangRuby` / `LangPython` arms became one cell
    # rule: `(lang, tiInterpreted, raRr)` has no recorder and the remedy names
    # the instrumented one.  Assert the rule, not the two instances -- and
    # since LRS-4 deleted the two members there ARE no instances: the
    # selectors below are constructed, which is the only way to reach the
    # cell now (`target_axes_test.nim` pins that no `Lang` value decomposes
    # to a non-default approach).
    for language in [slRuby, slPython]:
      for approach in [raRr, raMcr, raTtd]:
        let s = selector(language, tiInterpreted, approach)
        let tool = recorderToolFor(s)
        checkpoint(displayName(s) & " under " & token(approach))
        check(not tool.supported)
        check tool.isDeclared
        check token(approach) in tool.recorderLabel
        # …and the working recorder is the instrumented one, named in the
        # remedy so the user learns where it lives.
        let working = recorderToolFor(
          selector(language, tiInterpreted, raInstrumentedRuntime))
        check working.supported
        check tool.sibling == working.sibling
        check tool.installHint.join(" ").contains(working.recorderLabel)
    # The spellings the remedy names are the working recorders' -- `--lang
    # ruby` since LRS-4 made it name `LangRubyDb` (Q6), not the deprecated
    # `ruby(db)` the old arm advertised.
    let rubyHint = recorderToolFor(
      selector(slRuby, tiInterpreted, raRr)).installHint.join(" ")
    check "`--lang ruby`" in rubyHint
    check "ruby(db)" notin rubyHint
    check "`--lang py`" in
      recorderToolFor(selector(slPython, tiInterpreted, raRr)).installHint.join(" ")

  test "--lang ruby names the working recorder (Q6), and ruby(db) is its deprecated alias":
    # Through the same `toLang` that `ct record --lang` calls
    # (`src/ct/trace/record.nim`): `ruby`, `rb` and the deprecated `ruby(db)`
    # are ONE member with a supported instrumented-runtime recorder, so
    # `ct record --lang ruby foo.rb` records where it used to print "no
    # recorder for Ruby".  The deprecation note itself is pinned in
    # `record_backend_selection_test.nim` beside the other `--lang` /
    # `--backend` CLI-path checks.
    for spelling in ["ruby", "rb", "ruby(db)", "RUBY"]:
      checkpoint("--lang " & spelling)
      let lang = toLang(spelling)
      check lang == LangRubyDb
      let tool = recorderToolFor(sel(lang))
      check tool.supported
      check tool.recorderLabel == "codetracer-ruby-recorder"
    check deprecatedLangSpellingNote("ruby(db)").len > 0
    check deprecatedLangSpellingNote("ruby") == ""
    check deprecatedLangSpellingNote("rb") == ""

  test "a declared-unsupported language is reachable from a FILE, not just --lang":
    # The arm above is only worth having if a user reaches it the way a user
    # actually invokes `ct record`: by naming a file.  `.gd` was registered in
    # `src/common/lang.nim`'s `toLang` map and NOT in the CLI's own `LANGS`
    # table, so `--lang gdscript` reached the message and `player.gd` did not.
    # Measured on the shipped binary before the extension was registered:
    #
    #   $ ct record /tmp/ct-gd-probe/player.gd ; echo $?
    #   ERROR [ct](build.nim:60):This functionality requires a ct-native-replay installation.
    #   Assuming recording language LangUnknown:
    #   1
    #
    # Loud, but naming a component whose installation would not have helped,
    # and never mentioning GDScript.  That is the "confident wrong answer"
    # failure mode `detectLangFromPath`'s own doc comment was written about.
    #
    # Asserted here rather than only in `lang_enum_contract_test.nim`, whose
    # sweep over unknown extensions is GENERATED from `LANGS` and therefore
    # cannot notice a key that is missing from it.
    for lang in RecorderPendingLanguages:
      checkpoint("pending language: " & lang.toName)
      let extension = getExtension(lang)
      check extension.len > 0
      let reached = detectLangFromPath("program." & extension)
      check reached == lang
      # …and what it reaches is the declaration, not silence.
      check recorderToolFor(sel(reached)).installHint.len > 0
    # Both spellings of the explicit flag keep working, unchanged.
    check toLang("gd") == LangGdScript
    check toLang("gdscript") == LangGdScript

  test "the native family is the ONLY thing the table has nothing to say about":
    # `isDeclared` is what `ct record` routes on, so its complement must be
    # exactly the set `ct-native-replay` records: every `Lang` whose selector
    # is `tiNative` under a native replay approach, except Nim (ct-mcr).
    for lang in Lang:
      let s = sel(lang)
      let tool = recorderToolFor(s)
      checkpoint(lang.toName & " -> " & displayName(s) & "/" &
        token(s.targetIsa) & "/" & token(s.approach))
      if lang == LangUnknown:
        check(not tool.isDeclared)
      elif s.targetIsa == tiNative and s.approach in {raMcr, raRr, raTtd} and
           s.language != slNim:
        check(not tool.isDeclared)
      else:
        check tool.isDeclared

  test "the missing-recorder message names the language and the remedy":
    for row in DispatchRows:
      checkpoint("language: " & row.lang.toName)
      # Simulate every artifact of this language being absent.
      var absent: seq[RecorderArtifact] = @[]
      for artifact in recorderRequirements(sel(row.lang)):
        absent.add(RecorderArtifact(
          kind: artifact.kind, label: artifact.label,
          envVar: artifact.envVar, path: ""))
      let message = missingRecorderMessage(sel(row.lang), absent).join("\n")
      check message.startsWith("error:")
      check label(row.lang) in message
      check row.sibling in message
      # The remedy has to be actionable: either an env var to set or a
      # command to run.
      check ("help:" in message)

  test "the server-unsupported message names the flag and the alternatives":
    let message = serverUnsupportedMessage(sel(LangNim)).join("\n")
    check "--server" in message
    check label(LangNim) in message
    check "Python" in message
    check "PHP" in message

  test "server guidance tells the user where to watch the recording":
    for lang in [LangPhp, LangRubyDb, LangJavascript, LangElixir]:
      checkpoint("language: " & lang.toName)
      let guidance = serverGuidance(sel(lang), TraceFolder).join("\n")
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
      check recorderToolFor(sel(lang)).recorderEnvVar == envVar

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

# ---------------------------------------------------------------------------
# The ISA selects, the language is advisory
# ---------------------------------------------------------------------------

suite "the ISA selects the recorder; the language does not":

  test "wasm is one arm for every language, where it used to be two Lang members":
    # `LangRustWasm` and `LangCppWasm` welded the ISA onto the language.  On
    # the axes both are `(<lang>, tiWasm, raVmEmulation)` and select `wazero`;
    # so does a C wasm module, which never had a `Lang` value at all.  LRS-5's
    # second deletion round deleted both members: the selectors below are
    # unchanged, which is the point -- the dispatch table has not read the
    # members since LRS-2B, and now nothing can.
    for language in [slRust, slCpp, slC, slUnknown]:
      let s = selector(language, tiWasm, raVmEmulation)
      checkpoint("wasm from " & displayName(s))
      let tool = recorderToolFor(s)
      check tool.supported
      check tool.recorderLabel == "wazero"
      check "--out-dir" in joinedArgs(s)
    # No `Lang` value projects to a wasm selector any more.  This used to be
    # `check sel(LangRustWasm) == selector(slRust, tiWasm, raVmEmulation)` and
    # its C++ twin; LRS-5's second deletion round deleted both members, and the
    # property is stated over the whole enum instead of over the two rows that
    # used to satisfy it.
    for lang in Lang:
      check axesOfLang(lang).targetIsa != tiWasm

  test "a prebuilt .wasm module dispatches to wazero, and the route rides on the ARTEFACT":
    # **THE CASE THAT FLIPPED** (LRS-5, precondition (c)).  It used to be
    # called "...and the route rides on the Lang member" and to assert
    # `detectLang(module, LangUnknown) == LangRustWasm`, `a.kind.specific.len
    # == 0` ("nothing decides the ISA") and `a.targetIsa == tiWasm` with the
    # comment "...so the member does".  That was the last thing keeping
    # `LangRustWasm` alive on the RECORD side: road 3 below took its ISA from
    # `axesOfLang(LangRustWasm)`.
    #
    # The three roads to a wasm recording, and where each one's ISA comes
    # from NOW:
    #
    # 1. a Cargo crate whose `.cargo/config.toml` names `wasm32`: the
    #    assessment reads the MARKER (`wasm-cargo-project`) -- "a wasm crate
    #    is assessed as wasm, from the marker and not from a Lang member",
    #    below.  Unchanged since LRS-2B;
    # 2. `--lang rust-wasm` / `cpp-wasm`: a DEPRECATED ALIAS of the language
    #    (`LangRust` / `LangCpp`) that announces itself once and changes no
    #    route;
    # 3. a prebuilt `foo.wasm` handed to `ct record` (and what road 1 hands
    #    to `db-backend-record` after `cargo build`): `assessKind` reads the
    #    `.wasm` extension as `KindWasmModule` and `targetIsaForAssessment`
    #    answers `tiWasm` from THE KIND.  The `Lang` is `LangRust` -- a
    #    documented guess at the source language, which decides no route.
    let dir = getTempDir() / "ct-dispatch-test-wasm-module"
    removeDir(dir)
    createDir(dir)
    let module = dir / "app.wasm"
    writeFile(module, "stand-in for a wasm module; only the extension is read")
    let lang = detectLang(module, LangUnknown)
    check lang == LangRust                        # the LANGUAGE, a guess
    check axesOfLang(lang).targetIsa == tiNative  # ...and it says NATIVE
    let a = assessRecordingTarget(module, lang)
    check a.kind.family == tfPrebuiltArtefact
    check a.kind.specific == @[KindWasmModule]    # the artefact decides the ISA
    check a.targetIsa == tiWasm                   # ...and it is not the member's
    check a.recordingApproach == raVmEmulation
    let s = recorderSelectorFor(a, lang)
    check s == selector(slRust, tiWasm, raVmEmulation)
    check recorderToolFor(s).recorderLabel == "wazero"
    # The replay side must still see "materialized".  It no longer asks the
    # `Lang` summary -- which cannot answer it, and that was the OTHER half of
    # why the member was kept -- but the recording's own approach, which is
    # what `recordDb` registers the recording under.
    check producesMaterializedTrace(a.recordingApproach)
    check materializedReplayFor(slRust, a.recordingApproach)
    check(not materializedReplayFor(slRust, raMcr))

  test "the platform ISAs select a recorder with no source language at all":
    # `LangSolana` and `LangPolkavm` had no source language (`slUnknown`) and
    # still selected a recorder, because for a VM ISA the recorder is a
    # property of the ISA.  LRS-5's second deletion round deleted both
    # members; the selectors are constructed directly here, which is the only
    # way to reach these cells now and is exactly what the deletion asserts --
    # the routing never needed a `Lang`.
    for isa in [tiSolanaSbf, tiPolkaVm]:
      let s = selector(slUnknown, isa, raVmEmulation)
      checkpoint(token(isa))
      check s.language == slUnknown
      check recorderToolFor(s).supported
      check recorderToolFor(s).recorderLabel == blockchainRecorderName(isa)
      # …and the diagnostic still has something to call it.
      check displayName(s) == token(isa)
      check displayName(s) in missingRecorderMessage(s, @[]).join("\n")
    # No `Lang` value stands for a chain or a VM any more: every member has a
    # real source language, and only the sentinel is `slUnknown`.
    for lang in Lang:
      if lang != LangUnknown:
        check sourceLanguageOf(lang) != slUnknown

  test "every blockchain ISA names a recorder, an override and a sibling":
    for isa in BlockchainIsas:
      checkpoint(token(isa))
      check blockchainRecorderName(isa).len > 0
      check blockchainRecorderEnvVar(isa).len > 0
      check blockchainRecorderSibling(isa) == blockchainRecorderName(isa)
      let tool = recorderToolFor(selector(slUnknown, isa, raVmEmulation))
      check tool.supported
      check tool.recorderEnvVar == blockchainRecorderEnvVar(isa)

# ---------------------------------------------------------------------------
# One language, two recorders: `.nim` versus `.nims`
# ---------------------------------------------------------------------------

suite "one language, two recorders: .nim versus .nims":
  ## The canonical proof that the dispatch is a function of the assessment
  ## and not of the language.  Both files are `LangNim`; the assessment tells
  ## them apart on three axes and the table then selects two different
  ## recorders with two different requirement sets.

  let scratch = getTempDir() / "ct-dispatch-test-nim"
  removeDir(scratch)
  createDir(scratch)
  let nimFile = scratch / "a.nim"
  let nimsFile = scratch / "a.nims"
  writeFile(nimFile, "echo 1\n")
  writeFile(nimsFile, "echo 1\n")

  let sourceSel = assessedSelector(nimFile, LangNim)
  let scriptSel = assessedSelector(nimsFile, LangNim)

  test "the assessment separates them on ISA and approach, not on language":
    check sourceSel.language == slNim
    check scriptSel.language == slNim
    check sourceSel.targetIsa == tiNative
    check scriptSel.targetIsa == tiNimVm
    check sourceSel.approach == raMcr
    check scriptSel.approach == raInstrumentedRuntime
    check sourceSel != scriptSel
    # The per-`Lang` projection cannot make this distinction — which is why
    # it is a fallback and the assessment is the production path.
    check selectorOfLang(LangNim) == sourceSel
    check selectorOfLang(LangNim) != scriptSel

  test "the assessment names the kind and the toolchain the Lang value could not":
    let source = assessRecordingTarget(nimFile, LangNim)
    let script = assessRecordingTarget(nimsFile, LangNim)
    check KindNimSource in source.kind.specific
    check KindNimScript in script.kind.specific
    check source.kind.family == tfSingleFile
    check script.kind.family == tfSingleFile
    check source.toolchain == tcNimC
    check script.toolchain == tcNimScriptVm
    check(not source.isAmbiguous)
    check(not script.isAmbiguous)

  test "they select two different recorders":
    let source = recorderToolFor(sourceSel)
    let script = recorderToolFor(scriptSel)
    check source.supported
    check script.supported
    check source.recorderLabel == "ct-mcr"
    check source.sibling == "codetracer-native-recorder"
    check "nim e --trace:" in script.recorderLabel
    check script.sibling == "codetracer-nim"
    check source.recorderLabel != script.recorderLabel

  test "a .nims does NOT require ct-mcr; a .nim does":
    # The defect the axes fix: `requireRecorder(LangNim)` demanded `ct-mcr` for
    # both flows.  The requirement sets are read off the table, so this holds
    # with or without the tools installed.
    var sourceLabels, scriptLabels: seq[string]
    for artifact in recorderRequirements(sourceSel): sourceLabels.add(artifact.label)
    for artifact in recorderRequirements(scriptSel): scriptLabels.add(artifact.label)
    check "ct-mcr" in sourceLabels
    check "nim" in sourceLabels
    check "ct-mcr" notin scriptLabels
    for label in scriptLabels:
      check "nim" in label
    # And both route through the dispatch table rather than the native path.
    check recorderToolFor(sourceSel).isDeclared
    check recorderToolFor(scriptSel).isDeclared

  test "the replay-side summary is one bit for both, and says so":
    # `usesMaterializedTraces(LangNim)` is `true` for BOTH flows because both
    # import their container as a materialized trace — the exception recorded
    # in `MaterializedSummaryExceptions`.  The record side does not consult
    # it; the assessment's approach is what differs.
    check usesMaterializedTraces(LangNim)
    check producesMaterializedTrace(scriptSel.approach)
    check(not producesMaterializedTrace(sourceSel.approach))

# ---------------------------------------------------------------------------
# The assessment refuses what it may not decide (rule K2)
# ---------------------------------------------------------------------------

suite "the assessment is loud about two facts it may not choose between":

  let scratch = getTempDir() / "ct-dispatch-test-ambiguous"
  removeDir(scratch)
  createDir(scratch)
  writeFile(scratch / "Cargo.toml", "[package]\nname = \"x\"\n")
  writeFile(scratch / "foundry.toml", "[profile.default]\n")

  test "a crate that is also a Foundry project is BOTH, not Foundry":
    # The defect Q10 was decided against.  `detectFolderLang` answered
    # Solidity here by first match and discarded the Cargo fact; since LRS-2P
    # `assessFolderKind` reports both kinds and `assessFolder`'s `Lang`
    # summary is `LangUnknown` WITH an ambiguity rather than a silent pick,
    # so `detectLang` below now yields `LangUnknown` where it used to yield
    # `LangSolidity`.  Either way the assessment keeps both and refuses.
    let a = assessRecordingTarget(scratch, detectLang(scratch, LangUnknown))
    check KindCargoProject in a.kind.specific
    check KindFoundryProject in a.kind.specific
    check a.isAmbiguous
    check a.toolchain == tcUnknown
    check a.recordingApproach == raUnknown
    let text = a.diagnostics.join("\n")
    check KindCargoProject in text
    check KindFoundryProject in text
    check "nothing may pick one silently" in text
    # …and the selector it yields supports nothing, so a caller that ignores
    # `isAmbiguous` still cannot record by accident.
    check(not recorderToolFor(recorderSelectorFor(a, LangSolidity)).supported)

  test "an explicit --lang resolves it without refusing, and says so":
    let a = assessRecordingTarget(scratch, LangSolidity, languageWasExplicit = true)
    check(not a.isAmbiguous)
    check KindCargoProject in a.kind.specific
    check KindFoundryProject in a.kind.specific
    check a.targetIsa == tiEvm
    check a.recordingApproach == raVmEmulation
    check a.toolchain == tcUnknown            # left undetermined, not guessed
    check "--lang" in a.diagnostics.join("\n")
    check recorderToolFor(recorderSelectorFor(a, LangSolidity)).recorderLabel ==
      "codetracer-evm-recorder"

  test "a plain crate is one kind and is not ambiguous":
    let crate = getTempDir() / "ct-dispatch-test-crate"
    removeDir(crate)
    createDir(crate)
    writeFile(crate / "Cargo.toml", "[package]\nname = \"x\"\n")
    let a = assessRecordingTarget(crate, detectLang(crate, LangUnknown))
    check a.kind.specific == @[KindCargoProject]
    check(not a.isAmbiguous)
    check a.toolchain == tcCargo
    check a.targetIsa == tiNative
    check a.recordingApproach == raMcr
    # Native Rust: not the dispatch table's business.
    check(not recorderToolFor(recorderSelectorFor(a, LangRust)).isDeclared)

  test "a wasm crate is assessed as wasm, from the marker and not from a Lang member":
    let crate = getTempDir() / "ct-dispatch-test-wasm-crate"
    removeDir(crate)
    createDir(crate / ".cargo")
    writeFile(crate / "Cargo.toml", "[package]\nname = \"x\"\n")
    writeFile(crate / ".cargo" / "config.toml", "[build]\ntarget = \"wasm32-wasip1\"\n")
    let a = assessRecordingTarget(crate, detectLang(crate, LangUnknown))
    check KindWasmCargoProject in a.kind.specific
    check KindCargoProject in a.kind.specific
    check(not a.isAmbiguous)                  # one toolchain: cargo
    check a.toolchain == tcCargo
    check a.targetIsa == tiWasm
    check a.recordingApproach == raVmEmulation
    check recorderToolFor(recorderSelectorFor(a, LangRust)).recorderLabel == "wazero"

# ---------------------------------------------------------------------------
# LRS-5, second deletion round: a `--lang` spelling that names a TARGET ISA
# ---------------------------------------------------------------------------

suite "an ISA stated by --lang overrides the assessment, and keeps two routes alive":

  test "--lang polkavm and --lang solana still reach their recorders":
    # THE regression this exists for.  `LangPolkavm` / `LangSolana` had no
    # extension, no project marker and no `LANGS` row -- `--lang` was the ONLY
    # way to record such a target (the Edit-Mode Toolbar spec's EMT-F7 says
    # so).  Deleting the members WITHOUT moving the spellings to the ISA axis
    # would not have renamed that route, it would have deleted it: the target
    # falls through to `detectFolderLang`, a Solana crate reads as plain Rust,
    # and `ct record` takes the NATIVE path.  A silent one.
    let dir = getTempDir() / "ct-dispatch-test-isa-override"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "Cargo.toml", "[package]\nname = \"solprog\"\n")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", "// a Solana program is a Rust crate\n")
    # Without the override the crate is plain Rust and takes the native path.
    let bare = assessRecordingTarget(dir, detectLang(dir, LangUnknown))
    check bare.targetIsa == tiNative
    check bare.recordingApproach == raMcr
    check(not recorderToolFor(recorderSelectorFor(bare, LangRust)).isDeclared)
    # With it, the recorder the deleted member used to select.
    for (spelling, isa, sibling) in [("polkavm", tiPolkaVm, "codetracer-polkavm-recorder"),
                                     ("solana", tiSolanaSbf, "codetracer-solana-recorder")]:
      checkpoint("--lang " & spelling)
      let override = targetIsaSpelling(spelling)
      check override == isa
      let a = assessRecordingTarget(dir, detectLang(dir, LangUnknown),
                                    languageWasExplicit = true,
                                    isaOverride = override)
      check a.targetIsa == isa
      check a.recordingApproach == raVmEmulation
      let tool = recorderToolFor(recorderSelectorFor(a, detectLang(dir, LangUnknown)))
      check tool.supported
      check tool.sibling == sibling
      check tool.recorderLabel == blockchainRecorderName(isa)
    removeDir(dir)

  test "--lang rust-wasm means wasm even where nothing else says so":
    # The deprecated alias carries an ISA as well as a language.  Without the
    # ISA half a crate with no `wasm32` marker would record NATIVELY under a
    # flag whose whole point is to say "wasm" -- the silent native recording
    # the milestone forbids.
    let dir = getTempDir() / "ct-dispatch-test-wasm-alias"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "Cargo.toml", "[package]\nname = \"plain\"\n")
    check assessCargoProject(dir).targetIsa == tiNative  # no `wasm32` marker
    let bare = assessRecordingTarget(dir, LangRust)
    check bare.targetIsa == tiNative              # ...so the crate is native
    let a = assessRecordingTarget(dir, toLang("rust-wasm"),
                                  languageWasExplicit = true,
                                  isaOverride = targetIsaSpelling("rust-wasm"))
    check toLang("rust-wasm") == LangRust
    check a.targetIsa == tiWasm
    check a.recordingApproach == raVmEmulation
    check recorderToolFor(recorderSelectorFor(a, LangRust)).recorderLabel == "wazero"
    removeDir(dir)

  test "a stated ISA beats the kind, and an unstated one changes nothing":
    # Precedence, stated as a rule: the user's word is an instruction, the
    # kind is an observation, and Q8 already says an explicit `--lang` is not
    # second-guessed.  `tiUnknown` means "not stated" and must leave every
    # other answer exactly as it was.
    let dir = getTempDir() / "ct-dispatch-test-isa-precedence"
    removeDir(dir)
    createDir(dir)
    createDir(dir / ".cargo")
    writeFile(dir / "Cargo.toml", "[package]\nname = \"w\"\n")
    writeFile(dir / ".cargo" / "config.toml", "[build]\ntarget = \"wasm32-wasip1\"\n")
    check assessCargoProject(dir).targetIsa == tiWasm
    let fromMarker = assessRecordingTarget(dir, LangRust)
    check fromMarker.targetIsa == tiWasm          # the kind decides
    let overridden = assessRecordingTarget(dir, LangRust, languageWasExplicit = true,
                                           isaOverride = tiSolanaSbf)
    check overridden.targetIsa == tiSolanaSbf     # ...and the user overrides it
    check assessRecordingTarget(dir, LangRust, isaOverride = tiUnknown) == fromMarker
    removeDir(dir)
