## recorder_dispatch.nim
##
## The single source of truth for "which recorder does ``ct record`` run for
## this language, with which argv, and what do we tell the user when it is not
## installed".
##
## Before this module the answer lived inside one ``case lang`` in
## ``src/ct/db_backend_record.nim``'s ``recordDb`` and one ``if`` chain in its
## ``record``.  That worked as long as every language had a recorder — but the
## chain had no arm for PHP, Elixir or Erlang even though ``common/lang.nim``
## detects all three and marks them ``usesMaterializedTraces``, so
## ``ct record app.php`` fell through to ``ERROR: unsupported trace kind db``
## **and exited 0**.  Several other arms resolved their recorder through
## ``paths.nim`` and then spawned it without ever checking that the lookup had
## succeeded: with no recorder on PATH the exe was the empty string,
## ``startProcess`` raised, ``recordDb``'s caller swallowed the exception and
## ``ct`` cheerfully registered a trace for a recording that never happened.
##
## Splitting the table out fixes both classes of bug in one place and makes
## them testable without recording anything:
##
## * ``recorderToolFor`` is PURE — no environment, no filesystem — so a
##   table-driven test can assert "``.php`` selects the PHP extension, and the
##   remedy names codetracer-php-recorder" for every language at once.
## * ``recorderRequirements`` resolves the same table against the environment,
##   so ``ct`` can say precisely WHICH of a language's two artifacts (the
##   language runtime, or the recorder built from a sibling repo) is the one
##   that is missing.
## * ``recorderInvocation`` builds the argv, so the shape a recorder is
##   invoked with is asserted by a test rather than discovered in production.
##
## Discovery follows ``scripts/detect-siblings.sh``: every artifact has one
## ``CODETRACER_*`` environment variable that overrides it (which is what the
## dev shell exports for a sibling checkout), and otherwise falls back to the
## PATH search that end users get from the installed package.  No new
## convention is introduced here; the variable names below are the ones that
## script already exports, plus ``CODETRACER_PHP_RECORDER_EXTENSION`` for the
## PHP extension, which had no entry at all.

import std/[os]
import ../../common/[lang, paths]

type
  RecorderArtifactKind* = enum
    ## Which half of a language's recording toolchain an artifact is.  The
    ## distinction is what lets the diagnostic say "PHP is installed but the
    ## CodeTracer extension is not" instead of one undifferentiated
    ## "recorder not found".
    raRuntime      ## the language runtime `ct` executes (php, ruby, elixir …)
    raRecorder     ## the CodeTracer recorder itself (binary, script or .so)

  RecorderArtifact* = object
    kind*: RecorderArtifactKind
    label*: string      ## what the user should picture — a command or a file
    envVar*: string     ## the environment variable that overrides discovery
    path*: string       ## resolved absolute path, or "" when not found

  RecorderTool* = object
    ## The PURE description of a language's recorder: everything that can be
    ## said about it without looking at the machine.
    supported*: bool
      ## false for languages ``ct record`` has no materialized recorder for.
    runtimeLabel*: string
      ## "" when the recorder does not need a separate language runtime.
    runtimeEnvVar*: string
    recorderLabel*: string
    recorderEnvVar*: string
    sibling*: string
      ## the sibling repo that builds the recorder, per
      ## codetracer-specs/Working-with-the-CodeTracer-Repos.md.
    installHint*: seq[string]
      ## the "how do I get it" lines, printed verbatim under `help:`.

  RecorderOptions* = object
    ## The per-invocation extras that a few recorders take.  Everything here
    ## is already an argument of ``recordDb``; the object exists so
    ## ``recorderInvocation`` has one signature instead of nine.
    backend*: string
    stylusTrace*: string
    pythonActivationPath*: string
    pythonTestFramework*: string
    pythonTestArgs*: seq[string]
    server*: bool
      ## ``ct record --server``: the recorded program is a long-lived server
      ## rather than a run that ends on its own.  See ``serverSupport``.

  RecorderInvocation* = object
    exe*: string                  ## the process to spawn
    args*: seq[string]            ## argv after ``exe``
    env*: seq[(string, string)]   ## extra environment for the child
    workdir*: string              ## "" == inherit the caller's cwd

  ServerSupport* = enum
    ## What ``--server`` means for a language.  It is deliberately explicit:
    ## a recorder that cannot record a server must say so rather than record
    ## something subtly different.
    ssMiddleware
      ## The recorder invocation is unchanged — the server's own middleware
      ## (WSGI/ASGI, Rack, Plug, Express) publishes the request spans from
      ## inside the recorded process.  ``--server`` only changes ``ct``'s own
      ## behaviour: it announces the container up front and treats a
      ## termination signal as a normal stop.
    ssWorkerDir
      ## The recorder writes one container per worker process and needs to be
      ## told the *parent* directory instead of the container directory.
      ## (PHP: ``CODETRACER_OUTPUT_DIR`` vs ``CODETRACER_TRACE_DIR``.)
    ssSupervisor
      ## A different binary supervises the server recording.
      ## (native: ``codetracer-native-recorder`` rather than ``ct-mcr``.)
    ssUnsupported
      ## The language has a recorder, but nothing that survives a
      ## long-running process usefully.

const
  PhpExtensionEnvVar* = "CODETRACER_PHP_RECORDER_EXTENSION"
    ## The one variable this module adds to the ``detect-siblings.sh`` set.
    ## codetracer-php-recorder ships no wrapper executable — the recorder IS
    ## the Zend extension ``ext/modules/codetracer.so``, which `ct` loads with
    ## ``php -d extension=<so>`` — so there is nothing for ``findTool`` to
    ## find and the path has to be named explicitly.

proc blockchainRecorderName*(lang: Lang): string =
  ## The twelve blockchain / VM recorders share one CLI shape
  ## (``<binary> record --out-dir <dir> <program>``) and one naming scheme,
  ## so they are described by three small lookups rather than twelve
  ## near-identical table rows.
  case lang
  of LangMasm: "codetracer-miden-recorder"
  of LangMove: "codetracer-move-recorder"
  of LangSolana: "codetracer-solana-recorder"
  of LangSway: "codetracer-fuel-recorder"
  of LangCairo: "codetracer-cairo-recorder"
  of LangCircom: "codetracer-circom-recorder"
  of LangLeo: "codetracer-leo-recorder"
  of LangPolkavm: "codetracer-polkavm-recorder"
  of LangTolk: "codetracer-ton-recorder"
  of LangAiken: "codetracer-cardano-recorder"
  of LangCadence: "codetracer-flow-recorder"
  of LangSolidity: "codetracer-evm-recorder"
  else: ""

proc blockchainRecorderEnvVar*(lang: Lang): string =
  case lang
  of LangMasm: "CODETRACER_MIDEN_RECORDER_PATH"
  of LangMove: "CODETRACER_MOVE_RECORDER_PATH"
  of LangSolana: "CODETRACER_SOLANA_RECORDER_PATH"
  of LangSway: "CODETRACER_FUEL_RECORDER_PATH"
  of LangCairo: "CODETRACER_CAIRO_RECORDER_PATH"
  of LangCircom: "CODETRACER_CIRCOM_RECORDER_PATH"
  of LangLeo: "CODETRACER_LEO_RECORDER_PATH"
  of LangPolkavm: "CODETRACER_POLKAVM_RECORDER_PATH"
  of LangTolk: "CODETRACER_TON_RECORDER_PATH"
  of LangAiken: "CODETRACER_CARDANO_RECORDER_PATH"
  of LangCadence: "CODETRACER_FLOW_RECORDER_PATH"
  of LangSolidity: "CODETRACER_EVM_RECORDER_PATH"
  else: ""

proc blockchainRecorderSibling*(lang: Lang): string =
  ## The recorder binary name is also its repo name for every one of these.
  blockchainRecorderName(lang)

proc blockchainRecorderExe*(lang: Lang): string =
  case lang
  of LangMasm: midenRecorderExe
  of LangMove: moveRecorderExe
  of LangSolana: solanaRecorderExe
  of LangSway: fuelRecorderExe
  of LangCairo: cairoRecorderExe
  of LangCircom: circomRecorderExe
  of LangLeo: leoRecorderExe
  of LangPolkavm: polkavmRecorderExe
  of LangTolk: tonRecorderExe
  of LangAiken: cardanoRecorderExe
  of LangCadence: flowRecorderExe
  of LangSolidity: evmRecorderExe
  else: ""

proc recorderToolFor*(lang: Lang): RecorderTool =
  ## PURE: the recorder description for ``lang``, with no environment or
  ## filesystem access.  This is the table the dispatch test asserts.
  case lang
  of LangRubyDb:
    RecorderTool(
      supported: true,
      runtimeLabel: "ruby", runtimeEnvVar: "CODETRACER_RUBY_EXE_PATH",
      recorderLabel: "codetracer-ruby-recorder",
      recorderEnvVar: "CODETRACER_RUBY_RECORDER_PATH",
      sibling: "codetracer-ruby-recorder",
      installHint: @[
        "build it with `cd ../codetracer-ruby-recorder && just build-extension`,",
        "then put gems/codetracer-ruby-recorder/bin on PATH",
        "(the CodeTracer dev shell does both via scripts/detect-siblings.sh)"])
  of LangRuby:
    # Reachable only through an explicit ``--lang ruby``: ``.rb`` detection
    # yields LangRubyDb (see common/lang.nim's LANGS table).  LangRuby is the
    # retired rr/gdb-based Ruby backend, and it has no recorder at all — so
    # this arm exists to say that rather than to select something.
    RecorderTool(
      supported: false,
      recorderLabel: "the retired rr-based Ruby backend",
      sibling: "codetracer-ruby-recorder",
      installHint: @[
        "`--lang ruby` selects the retired rr/gdb Ruby backend, which no",
        "longer has a recorder. Drop the flag (`.rb` auto-detects) or pass",
        "`--lang ruby(db)` to use the codetracer-ruby-recorder path."])
  of LangPythonDb:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-python-recorder",
      recorderEnvVar: "CODETRACER_PYTHON_RECORDER_PATH",
      sibling: "codetracer-python-recorder",
      installHint: @[
        "install it with `python -m pip install codetracer_python_recorder`,",
        "or point CodeTracer at an interpreter that has it via",
        "CODETRACER_PYTHON_INTERPRETER=/path/to/python"])
  of LangPython:
    RecorderTool(
      supported: false,
      recorderLabel: "the retired rr-based Python backend",
      sibling: "codetracer-python-recorder",
      installHint: @[
        "`--lang python` used to select the rr/gdb Python backend, which no",
        "longer has a recorder. Drop the flag (`.py` auto-detects) or pass",
        "`--lang py` to use the codetracer-python-recorder path."])
  of LangJavascript:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-js-recorder",
      recorderEnvVar: "CODETRACER_JS_RECORDER_PATH",
      sibling: "codetracer-js-recorder",
      installHint: @[
        "build it with `cd ../codetracer-js-recorder && just build`,",
        "then put node_modules/.bin on PATH",
        "(the CodeTracer dev shell does both via scripts/detect-siblings.sh)"])
  of LangPhp:
    RecorderTool(
      supported: true,
      runtimeLabel: "php", runtimeEnvVar: "CODETRACER_PHP_EXE_PATH",
      recorderLabel: "codetracer.so (the CodeTracer PHP extension)",
      recorderEnvVar: PhpExtensionEnvVar,
      sibling: "codetracer-php-recorder",
      installHint: @[
        "build it with `cd ../codetracer-php-recorder && just build`;",
        "it produces ext/modules/codetracer.so.",
        "Point CodeTracer at it with",
        "  " & PhpExtensionEnvVar & "=/path/to/ext/modules/codetracer.so",
        "(the CodeTracer dev shell does this via scripts/detect-siblings.sh)"])
  of LangElixir:
    RecorderTool(
      supported: true,
      runtimeLabel: "elixir", runtimeEnvVar: "CODETRACER_ELIXIR_EXE_PATH",
      recorderLabel: "codetracer-beam-recorder",
      recorderEnvVar: "CODETRACER_BEAM_RECORDER_BIN",
      sibling: "codetracer-beam-recorder",
      installHint: @[
        "build it with `cd ../codetracer-beam-recorder && just build`;",
        "it produces target/debug/codetracer-beam-recorder.",
        "(the CodeTracer dev shell exports CODETRACER_BEAM_RECORDER_BIN via",
        "scripts/detect-siblings.sh)"])
  of LangErlang:
    RecorderTool(
      supported: true,
      runtimeLabel: "escript", runtimeEnvVar: "CODETRACER_ESCRIPT_EXE_PATH",
      recorderLabel: "codetracer-beam-recorder",
      recorderEnvVar: "CODETRACER_BEAM_RECORDER_BIN",
      sibling: "codetracer-beam-recorder",
      installHint: @[
        "build it with `cd ../codetracer-beam-recorder && just build`;",
        "it produces target/debug/codetracer-beam-recorder.",
        "(the CodeTracer dev shell exports CODETRACER_BEAM_RECORDER_BIN via",
        "scripts/detect-siblings.sh)"])
  of LangBash:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-bash-recorder",
      sibling: "codetracer-shell-recorders",
      installHint: @[
        "check out codetracer-shell-recorders next to codetracer and put",
        "its bash-recorder/ directory on PATH (the CodeTracer dev shell",
        "does this via scripts/detect-siblings.sh)"])
  of LangZsh:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-zsh-recorder",
      sibling: "codetracer-shell-recorders",
      installHint: @[
        "check out codetracer-shell-recorders next to codetracer and put",
        "its zsh-recorder/ directory on PATH (the CodeTracer dev shell",
        "does this via scripts/detect-siblings.sh)"])
  of LangNoir:
    RecorderTool(
      supported: true,
      recorderLabel: "nargo",
      recorderEnvVar: "CODETRACER_NOIR_EXE_PATH",
      sibling: "noir",
      installHint: @[
        "build the metacraft-labs noir fork with",
        "`cd ../noir && cargo build --release`, then put target/release on",
        "PATH or set CODETRACER_NOIR_EXE_PATH"])
  of LangRustWasm, LangCppWasm:
    RecorderTool(
      supported: true,
      recorderLabel: "wazero",
      recorderEnvVar: "CODETRACER_WASM_VM_PATH",
      sibling: "codetracer-wasm-recorder",
      installHint: @[
        "build it with `cd ../codetracer-wasm-recorder && just build`,",
        "then put the wazero binary on PATH or set CODETRACER_WASM_VM_PATH"])
  of LangNim:
    RecorderTool(
      supported: true,
      runtimeLabel: "nim", runtimeEnvVar: "CODETRACER_NIM_EXE_PATH",
      recorderLabel: "ct-mcr",
      recorderEnvVar: "CODETRACER_CT_MCR_CMD",
      sibling: "codetracer-native-recorder",
      installHint: @[
        "build it with `cd ../codetracer-native-recorder && just build-ct-mcr`,",
        "then put ct_cli/ on PATH or set CODETRACER_CT_MCR_PATH",
        "(the CodeTracer dev shell exports CODETRACER_CT_MCR_CMD via",
        "scripts/detect-siblings.sh)"])
  of LangMasm, LangMove, LangSolana, LangSway, LangCairo, LangCircom,
     LangLeo, LangPolkavm, LangTolk, LangAiken, LangCadence, LangSolidity:
    let name = blockchainRecorderName(lang)
    RecorderTool(
      supported: true,
      recorderLabel: name,
      recorderEnvVar: blockchainRecorderEnvVar(lang),
      sibling: blockchainRecorderSibling(lang),
      installHint: @[
        "build it with `cd ../" & blockchainRecorderSibling(lang) &
          " && just build`,",
        "then put the binary on PATH or set " &
          blockchainRecorderEnvVar(lang)])
  else:
    RecorderTool(supported: false, recorderLabel: "")

proc serverSupport*(lang: Lang): ServerSupport =
  ## PURE: what ``ct record --server`` does for ``lang``.
  ##
  ## The six languages listed here are exactly the six whose recorders gained
  ## web-request span recording, and the split matches how each one produces
  ## those spans: five publish them from middleware running inside the
  ## recorded process, PHP publishes them from the extension in each worker,
  ## and a native server has no middleware seam at all so the spans are
  ## discovered afterwards by a separate supervisor binary.
  case lang
  of LangPhp: ssWorkerDir
  of LangPythonDb, LangRubyDb, LangJavascript, LangElixir, LangErlang:
    ssMiddleware
  of LangNim:
    # `.nim` records through ct-mcr after a compile step; the supervisor
    # flow has not been wired through that compile, so say so rather than
    # silently recording a plain run.
    ssUnsupported
  else:
    # The native family (C, C++, Rust, Go, …) records through the rr/MCR
    # backend, and codetracer-native-recorder's `ct_server_record` is the
    # binary that supervises a long-running server recording for it.
    if not lang.usesMaterializedTraces and lang != LangUnknown: ssSupervisor
    else: ssUnsupported

proc serverUnsupportedMessage*(lang: Lang): seq[string] =
  ## What ``ct record --server`` prints for a language that has no
  ## server-recording story yet.  Never silently degrade to a plain run: a
  ## plain run of a server records a process that never returns and produces
  ## no request spans, which looks like a hang rather than an error.
  result.add("error: `ct record --server` is not supported for " &
    lang.toName & ".")
  result.add("help: --server is implemented for the languages whose " &
    "recorders publish web-request spans:")
  result.add("help:   Python, Ruby, PHP, Elixir, Erlang, JavaScript, and " &
    "native (C/C++/Rust) servers.")
  result.add("help: record the run without --server, or see " &
    "`just demo-request-panel` for the supported flows.")

proc recorderRequirements*(lang: Lang): seq[RecorderArtifact] =
  ## The same table, resolved against the environment.  A ``path`` of ""
  ## means "not installed", which is what the caller turns into the
  ## diagnostic.  Resolution order per artifact is the one
  ## ``scripts/detect-siblings.sh`` sets up: the ``CODETRACER_*`` override
  ## first, then the PATH search an installed package gets.
  let tool = recorderToolFor(lang)
  if not tool.supported:
    return @[]

  if tool.runtimeLabel.len > 0:
    var runtimePath = ""
    case lang
    of LangRubyDb: runtimePath = rubyExe
    of LangPhp: runtimePath = phpExe
    of LangElixir: runtimePath = elixirExe
    of LangErlang: runtimePath = escriptExe
    of LangNim: runtimePath = nimCompilerExe
    else: discard
    result.add(RecorderArtifact(
      kind: raRuntime, label: tool.runtimeLabel,
      envVar: tool.runtimeEnvVar, path: runtimePath))

  var recorderPath = ""
  case lang
  of LangRubyDb: recorderPath = rubyRecorderPath
  of LangPythonDb: recorderPath = pythonRecorderExe
  of LangJavascript: recorderPath = jsRecorderExe
  of LangPhp:
    # The PHP recorder is a shared object, not an executable, so the
    # existence check is fileExists rather than a PATH search.
    recorderPath = if phpRecorderExtension.len > 0 and
                      fileExists(phpRecorderExtension): phpRecorderExtension
                   else: ""
  of LangElixir, LangErlang: recorderPath = beamRecorderExe
  of LangBash: recorderPath = bashRecorderExe
  of LangZsh: recorderPath = zshRecorderExe
  of LangNoir: recorderPath = noirExe
  of LangRustWasm, LangCppWasm: recorderPath = wazeroExe
  of LangNim: recorderPath = mcrRecorderExe
  else: recorderPath = blockchainRecorderExe(lang)
  result.add(RecorderArtifact(
    kind: raRecorder, label: tool.recorderLabel,
    envVar: tool.recorderEnvVar, path: recorderPath))

proc missingArtifacts*(lang: Lang): seq[RecorderArtifact] =
  ## The artifacts of ``lang``'s toolchain that are NOT installed.
  for artifact in recorderRequirements(lang):
    if artifact.path.len == 0:
      result.add(artifact)

proc missingRecorderMessage*(lang: Lang, missing: seq[RecorderArtifact]):
    seq[string] =
  ## The message ``ct`` prints when a recording cannot even be attempted.
  ## Modelled on the Python path's ``checkPythonRecorder`` diagnostic, which
  ## is the quality bar: name the language, name the artifact, and give the
  ## command that installs it — never fall through to another backend.
  let tool = recorderToolFor(lang)
  if not tool.supported:
    result.add("error: CodeTracer has no recorder for " & lang.toName & ".")
    for line in tool.installHint:
      result.add("help: " & line)
    return

  var recorderMissing = false
  for artifact in missing:
    case artifact.kind
    of raRuntime:
      # The language's own toolchain, which CodeTracer does not ship. Saying
      # "build it with `cd ../codetracer-beam-recorder && just build`" here
      # would be wrong: that repo builds the recorder, not `elixir`.
      result.add("error: the " & lang.toName & " runtime `" & artifact.label &
        "` was not found, so `ct record` cannot record this " & lang.toName &
        " program.")
      result.add("help: install " & lang.toName &
        " and put `" & artifact.label & "` on PATH, or set " &
        artifact.envVar & "=/path/to/" & artifact.label & ".")
    of raRecorder:
      recorderMissing = true
      result.add("error: the " & lang.toName & " recorder `" &
        artifact.label & "` was not found, so `ct record` cannot record " &
        "this " & lang.toName & " program.")
      if artifact.envVar.len > 0:
        result.add("help: set " & artifact.envVar &
          "=/path/to/it to point CodeTracer at an existing build.")

  # The sibling remedy is about the RECORDER, so it is only printed when the
  # recorder is the thing that is missing — except that the sibling name is
  # still worth naming when only the runtime is absent, because that repo's
  # dev shell is where a working runtime lives.
  if tool.sibling.len > 0:
    if recorderMissing:
      result.add("help: it is built by the `" & tool.sibling & "` repo:")
      for line in tool.installHint:
        result.add("help:   " & line)
    else:
      result.add("help: the `" & tool.sibling & "` repo's dev shell provides " &
        "a working " & lang.toName & " toolchain:")
      result.add("help:   direnv exec ../" & tool.sibling & " <command>")

proc recorderInvocation*(lang: Lang, program: string, traceFolder: string,
                         opts: RecorderOptions = RecorderOptions()):
    RecorderInvocation =
  ## The exact process ``ct`` spawns for ``lang``.  ``exe`` is already
  ## resolved; an empty ``exe`` means the toolchain check should have
  ## rejected the run before getting here.
  ##
  ## Every recorder here follows the recorder convention
  ## (codetracer-specs/Recorders/Recorder-CLI-Convention.md): the output
  ## directory is named with ``--out-dir`` and the program is the last
  ## positional argument.  The three exceptions are called out inline.
  case lang
  of LangRubyDb:
    # `ruby <recorder-script> --out-dir <dir> <program>` — the Ruby recorder
    # is a Ruby script, so the process is the interpreter.
    RecorderInvocation(
      exe: rubyExe,
      args: @[rubyRecorderPath, "--out-dir", traceFolder, program])
  of LangPythonDb:
    var args = @["--out-dir", traceFolder]
    if opts.pythonActivationPath.len > 0:
      args.add("--activation-path")
      args.add(opts.pythonActivationPath)
    if opts.pythonTestFramework.len > 0:
      # pytest/unittest mode: the framework flag swallows the rest of argv,
      # so the program is NOT appended.
      args.add("--" & opts.pythonTestFramework)
      args = args & opts.pythonTestArgs
    else:
      args.add(program)
    RecorderInvocation(exe: pythonRecorderExe, args: args)
  of LangJavascript:
    RecorderInvocation(
      exe: jsRecorderExe,
      args: @["record", "--out-dir", traceFolder, program])
  of LangPhp:
    # EXCEPTION 1: codetracer-php-recorder ships no executable.  The recorder
    # is a Zend extension loaded into `php` itself, and it is configured
    # entirely through the environment (see ext/codetracer_php.c's
    # trace-directory selection): CODETRACER_TRACE_DIR names the output
    # directory verbatim — the single-process form a `ct record app.php`
    # wants — whereas CODETRACER_OUTPUT_DIR makes each worker write its own
    # `worker_<pid>/` beneath it, which is the form a recorded `php -S`
    # server needs.  `--server` is what picks between them.
    var env = @[("CODETRACER_ENABLED", "1")]
    if opts.server:
      env.add(("CODETRACER_OUTPUT_DIR", traceFolder))
    else:
      env.add(("CODETRACER_TRACE_DIR", traceFolder))
    RecorderInvocation(
      exe: phpExe,
      args: @["-d", "extension=" & phpRecorderExtension, program],
      env: env)
  of LangElixir:
    # EXCEPTION 2: the BEAM recorder wraps an arbitrary command rather than
    # taking a script path, because a BEAM program is started by its build
    # tool.  `--source-dir` is what makes the recorder instrument the
    # program's own sources instead of only the runtime's.
    RecorderInvocation(
      exe: beamRecorderExe,
      args: @["record", "--out-dir", traceFolder,
              "--source-dir", program.parentDir,
              "--", elixirExe, program])
  of LangErlang:
    RecorderInvocation(
      exe: beamRecorderExe,
      args: @["record", "--out-dir", traceFolder,
              "--source-dir", program.parentDir,
              "--", escriptExe, program])
  of LangBash:
    RecorderInvocation(
      exe: bashRecorderExe, args: @["--out-dir", traceFolder, program])
  of LangZsh:
    RecorderInvocation(
      exe: zshRecorderExe, args: @["--out-dir", traceFolder, program])
  of LangNoir:
    # EXCEPTION 3: nargo traces the package it is run INSIDE, so the program
    # is expressed as the working directory rather than an argument.
    let backendArgs = if opts.backend == "plonky2": @["--trace-plonky2"]
                      else: @[]
    RecorderInvocation(
      exe: noirExe,
      args: @["trace", "--out-dir", traceFolder] & backendArgs,
      workdir: if dirExists(program): program else: program.parentDir)
  of LangRustWasm, LangCppWasm:
    var args = @["run"]
    if opts.stylusTrace.len > 0:
      args.add("-stylus")
      args.add(opts.stylusTrace)
    args = args & @["--out-dir", traceFolder, program]
    RecorderInvocation(exe: wazeroExe, args: args)
  of LangMasm, LangMove, LangSolana, LangSway, LangCairo, LangCircom,
     LangLeo, LangPolkavm, LangTolk, LangAiken, LangCadence, LangSolidity:
    RecorderInvocation(
      exe: blockchainRecorderExe(lang),
      args: @["record", "--out-dir", traceFolder, program])
  else:
    RecorderInvocation()

proc serverGuidance*(lang: Lang, traceFolder: string): seq[string] =
  ## What ``ct record --server`` prints before handing control to the
  ## recorder.  The point of the flag is that the recording is watchable
  ## while it runs, so the very first thing the user needs is the path to
  ## watch and the command that watches it.
  result.add("recording " & lang.toName & " server into: " & traceFolder)
  case serverSupport(lang)
  of ssWorkerDir:
    result.add("each worker process writes its own container under it")
  of ssSupervisor:
    result.add("supervised by codetracer-native-recorder (time-sliced)")
  of ssMiddleware:
    result.add("request spans are published by the app's CodeTracer middleware")
  of ssUnsupported:
    discard
  result.add("watch requests arrive live with, in another terminal:")
  result.add("  ct replay -t " & traceFolder)
  result.add("stop the recording with Ctrl-C; the container stays readable")
