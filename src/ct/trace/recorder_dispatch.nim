## recorder_dispatch.nim
##
## The single source of truth for "which recorder does ``ct record`` run for
## this target, with which argv, and what do we tell the user when it is not
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
##   remedy names codetracer-php-recorder" for every target at once.
## * ``recorderRequirements`` resolves the same table against the environment,
##   so ``ct`` can say precisely WHICH of a recorder's two artifacts (the
##   language runtime, or the recorder built from a sibling repo) is the one
##   that is missing.
## * ``recorderInvocation`` builds the argv, so the shape a recorder is
##   invoked with is asserted by a test rather than discovered in production.
##
## ## What the table is a function of — LRS-2B
##
## The table used to be indexed by ``Lang``, and ``Lang`` answers four
## questions with one value (``src/common/target_axes.nim``).  That is why it
## needed ``LangRustWasm`` beside ``LangRust`` (same language, different ISA),
## ``LangPython`` beside ``LangPythonDb`` (same language, different recording
## approach; LRS-4 deleted ``LangPython`` and ``LangRuby``, the retired
## halves), and why ``LangNim`` — one value — had to describe TWO recorders
## at once: ``nim c`` + ``ct-mcr`` for a ``.nim`` and the compiler's script VM
## for a ``.nims``.  ``requireRecorder(LangNim)`` therefore demanded ``ct-mcr``
## for a ``.nims`` that never uses it.
##
## Every entry point now takes a ``RecorderSelector`` — the three artefact
## axes an assessment settles: the target's source language, its target ISA
## and the recording approach.  ``src/ct/trace/record_assessment.nim`` derives
## one from the assessed target (``.nims`` is ``tiNimVm`` /
## ``raInstrumentedRuntime``; ``.nim`` is ``tiNative`` / ``raMcr``; a crate
## whose ``.cargo/config.toml`` names ``wasm32`` is ``tiWasm``), and the arms
## below dispatch on ISA and approach first and on the language only where the
## ISA is the language's own runtime.  ``selectorOfLang`` is the per-``Lang``
## projection for callers that have nothing but the summary value; it is a
## fallback and says so.
##
## Discovery follows ``scripts/detect-siblings.sh``: every artifact has one
## ``CODETRACER_*`` environment variable that overrides it (which is what the
## dev shell exports for a sibling checkout), and otherwise falls back to the
## PATH search that end users get from the installed package.  No new
## convention is introduced here; the variable names below are the ones that
## script already exports, plus ``CODETRACER_PHP_RECORDER_EXTENSION`` for the
## PHP extension, which had no entry at all.

import std/[os]
import ../../common/[lang, paths, target_assessment]

type
  RecorderArtifactKind* = enum
    ## Which half of a recorder's toolchain an artifact is.  The distinction
    ## is what lets the diagnostic say "PHP is installed but the CodeTracer
    ## extension is not" instead of one undifferentiated "recorder not found".
    raRuntime      ## the language runtime `ct` executes (php, ruby, elixir …)
    raRecorder     ## the CodeTracer recorder itself (binary, script or .so)

  RecorderArtifact* = object
    kind*: RecorderArtifactKind
    label*: string      ## what the user should picture — a command or a file
    envVar*: string     ## the environment variable that overrides discovery
    path*: string       ## resolved absolute path, or "" when not found

  RecorderTool* = object
    ## The PURE description of a recorder: everything that can be said about
    ## it without looking at the machine.
    supported*: bool
      ## false when ``ct record`` has no recorder for this selector.
    runtimeLabel*: string
      ## "" when the recorder does not need a separate language runtime.
    runtimeEnvVar*: string
    recorderLabel*: string
      ## "" ONLY for a selector this table has nothing to say about at all —
      ## the native family, which ``ct-native-replay`` records.  A selector
      ## that is unsupported but DECLARED (a retired backend, a recorder that
      ## does not exist yet) has a non-empty label and an ``installHint``.
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
    ## What ``--server`` means for a recorder.  It is deliberately explicit:
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
      ## The target has a recorder, but nothing that survives a long-running
      ## process usefully.

  RecorderSelector* = object
    ## What the dispatch table is a function of.
    ##
    ## Three of the four axes; the toolchain is not here because no recorder
    ## is selected by it (``cargo`` builds the crate, ``wazero`` records the
    ## result).  The language is consulted only where the ISA is the
    ## language's own runtime (``tiInterpreted``, ``tiBeam``) — for every VM
    ## ISA the recorder is a property of the ISA and the language is
    ## advisory, which is why ``LangSolana`` and ``LangPolkavm`` (no source
    ## language at all) still select a recorder.
    language*: SourceLanguage
    targetIsa*: TargetIsa
    approach*: RecordingApproach

const
  PhpExtensionEnvVar* = "CODETRACER_PHP_RECORDER_EXTENSION"
    ## The one variable this module adds to the ``detect-siblings.sh`` set.
    ## codetracer-php-recorder ships no wrapper executable — the recorder IS
    ## the Zend extension ``ext/modules/codetracer.so``, which `ct` loads with
    ## ``php -d extension=<so>`` — so there is nothing for ``findTool`` to
    ## find and the path has to be named explicitly.

  BlockchainIsas* = {tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm,
                     tiCairoVm, tiAleoVm, tiTonVm, tiPlutus, tiFlowVm,
                     tiSolanaSbf, tiCircomWitness}
    ## The twelve VM ISAs whose recorders share one CLI shape
    ## (``<binary> record --out-dir <dir> <program>``) and one naming scheme.

# ---------------------------------------------------------------------------
# Selectors
# ---------------------------------------------------------------------------

func selector*(language: SourceLanguage, targetIsa: TargetIsa,
               approach: RecordingApproach): RecorderSelector =
  RecorderSelector(language: language, targetIsa: targetIsa, approach: approach)

func selectorOfLang*(lang: Lang): RecorderSelector =
  ## **FALLBACK.**  The selector a bare ``Lang`` value projects to, via
  ## ``axesOfLang``.  It cannot tell ``.nims`` from ``.nim`` (both ``LangNim``
  ## → ``tiNative`` / ``raMcr``) or a wasm crate from a native one when the
  ## value is ``LangRust``; ``record_assessment.assessRecordingTarget`` can,
  ## and every production record path goes through it.  This exists for
  ## callers that genuinely have only the summary: messages about a stored
  ## ``Trace.lang``, and the table tests that sweep every ``Lang``.
  let a = axesOfLang(lang)
  selector(a.language, a.targetIsa, a.approach)

func selectorOf*(assessment: TargetAssessment,
                 language: SourceLanguage): RecorderSelector =
  ## The selector an assessment settles, for the target's primary language.
  ## The language comes from the caller because the census in
  ## ``assessment.languages`` is advisory and never routes; the PRIMARY
  ## language of the target the user named is what selects among the
  ## runtimes of ``tiInterpreted``.
  selector(language, assessment.targetIsa, assessment.recordingApproach)

func displayName*(sel: RecorderSelector): string =
  ## What a diagnostic calls the thing being recorded.  The language where
  ## there is one; the ISA where the target has no source language (a Solana
  ## or PolkaVM program is Rust or C, and which one is unknown until a file is
  ## looked at).
  if sel.language != slUnknown: displayName(sel.language)
  elif sel.targetIsa != tiUnknown: token(sel.targetIsa)
  else: "unknown"

func isDeclared*(tool: RecorderTool): bool =
  ## Does this table have ANYTHING to say about the selector?  ``true`` for
  ## every supported recorder AND for every declared-unsupported one (a retired
  ## backend, a recorder that does not exist yet, Lua).  ``false`` only for the
  ## native family, which ``ct-native-replay`` records and this table never
  ## describes.  This is the predicate ``ct record`` routes on: declared →
  ## through the dispatch table (``db-backend-record``), undeclared → native.
  tool.supported or tool.recorderLabel.len > 0

# ---------------------------------------------------------------------------
# The blockchain / VM recorders, by ISA
# ---------------------------------------------------------------------------

proc blockchainRecorderName*(isa: TargetIsa): string =
  ## The twelve blockchain / VM recorders share one CLI shape
  ## (``<binary> record --out-dir <dir> <program>``) and one naming scheme,
  ## so they are described by three small lookups rather than twelve
  ## near-identical table rows.  Keyed by ISA: the recorder observes the VM,
  ## and which language the program was written in is not its business.
  case isa
  of tiMidenVm: "codetracer-miden-recorder"
  of tiMoveVm: "codetracer-move-recorder"
  of tiSolanaSbf: "codetracer-solana-recorder"
  of tiFuelVm: "codetracer-fuel-recorder"
  of tiCairoVm: "codetracer-cairo-recorder"
  of tiCircomWitness: "codetracer-circom-recorder"
  of tiAleoVm: "codetracer-leo-recorder"
  of tiPolkaVm: "codetracer-polkavm-recorder"
  of tiTonVm: "codetracer-ton-recorder"
  of tiPlutus: "codetracer-cardano-recorder"
  of tiFlowVm: "codetracer-flow-recorder"
  of tiEvm: "codetracer-evm-recorder"
  else: ""

proc blockchainRecorderEnvVar*(isa: TargetIsa): string =
  case isa
  of tiMidenVm: "CODETRACER_MIDEN_RECORDER_PATH"
  of tiMoveVm: "CODETRACER_MOVE_RECORDER_PATH"
  of tiSolanaSbf: "CODETRACER_SOLANA_RECORDER_PATH"
  of tiFuelVm: "CODETRACER_FUEL_RECORDER_PATH"
  of tiCairoVm: "CODETRACER_CAIRO_RECORDER_PATH"
  of tiCircomWitness: "CODETRACER_CIRCOM_RECORDER_PATH"
  of tiAleoVm: "CODETRACER_LEO_RECORDER_PATH"
  of tiPolkaVm: "CODETRACER_POLKAVM_RECORDER_PATH"
  of tiTonVm: "CODETRACER_TON_RECORDER_PATH"
  of tiPlutus: "CODETRACER_CARDANO_RECORDER_PATH"
  of tiFlowVm: "CODETRACER_FLOW_RECORDER_PATH"
  of tiEvm: "CODETRACER_EVM_RECORDER_PATH"
  else: ""

proc blockchainRecorderSibling*(isa: TargetIsa): string =
  ## The recorder binary name is also its repo name for every one of these.
  blockchainRecorderName(isa)

proc blockchainRecorderExe*(isa: TargetIsa): string =
  case isa
  of tiMidenVm: midenRecorderExe()
  of tiMoveVm: moveRecorderExe()
  of tiSolanaSbf: solanaRecorderExe()
  of tiFuelVm: fuelRecorderExe()
  of tiCairoVm: cairoRecorderExe()
  of tiCircomWitness: circomRecorderExe()
  of tiAleoVm: leoRecorderExe()
  of tiPolkaVm: polkavmRecorderExe()
  of tiTonVm: tonRecorderExe()
  of tiPlutus: cardanoRecorderExe()
  of tiFlowVm: flowRecorderExe()
  of tiEvm: evmRecorderExe()
  else: ""

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

proc instrumentedRuntimeTool(language: SourceLanguage): RecorderTool =
  ## The ``(language, tiInterpreted, raInstrumentedRuntime)`` column: the
  ## recorders that run INSIDE the language's own runtime.  Dispatches on the
  ## language because here the ISA *is* the language's runtime.
  case language
  of slRuby:
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
  of slPython:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-python-recorder",
      recorderEnvVar: "CODETRACER_PYTHON_RECORDER_PATH",
      sibling: "codetracer-python-recorder",
      installHint: @[
        "install it with `python -m pip install codetracer_python_recorder`,",
        "or point CodeTracer at an interpreter that has it via",
        "CODETRACER_PYTHON_INTERPRETER=/path/to/python"])
  of slJavaScript:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-js-recorder",
      recorderEnvVar: "CODETRACER_JS_RECORDER_PATH",
      sibling: "codetracer-js-recorder",
      installHint: @[
        "build it with `cd ../codetracer-js-recorder && just build`,",
        "then put node_modules/.bin on PATH",
        "(the CodeTracer dev shell does both via scripts/detect-siblings.sh)"])
  of slPhp:
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
  of slBash:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-bash-recorder",
      sibling: "codetracer-shell-recorders",
      installHint: @[
        "check out codetracer-shell-recorders next to codetracer and put",
        "its bash-recorder/ directory on PATH (the CodeTracer dev shell",
        "does this via scripts/detect-siblings.sh)"])
  of slZsh:
    RecorderTool(
      supported: true,
      recorderLabel: "codetracer-zsh-recorder",
      sibling: "codetracer-shell-recorders",
      installHint: @[
        "check out codetracer-shell-recorders next to codetracer and put",
        "its zsh-recorder/ directory on PATH (the CodeTracer dev shell",
        "does this via scripts/detect-siblings.sh)"])
  of slLua:
    # The gap the axes make visible.  Lua is an interpreted language, so the
    # way it WOULD be recorded is by instrumenting its runtime — and no such
    # recorder exists anywhere: no sibling repo, no discovery variable, no
    # arm in any earlier version of this table.  Before LRS-2B `ct record
    # --lang lua app.lua` took the NATIVE path (`usesMaterializedTraces(LangLua)`
    # is false) and failed inside `ct-native-replay build`, blaming a build of
    # a script.  Declaring it here is what turns that into a diagnostic that
    # names Lua.  It is reached through `--lang lua` only: `.lua` is not in
    # `LANGS` (`src/ct/utilities/language_detection.nim`), so a bare `ct record
    # app.lua` resolves to `LangUnknown` first -- a separate gap in the
    # extension table, of the kind `.gd` had, recorded here and not closed.  `usesMaterializedTraces(LangLua)` stays `false`, deliberately
    # — see `MaterializedSummaryExceptions` in `common_lang.nim` — because no
    # materialized Lua trace can exist while this arm reads `supported: false`.
    #
    # No sibling is named, because there is no repo to name; inventing one
    # would read as a contract.  What flips this arm: a Lua recorder is
    # published and discoverable, at which point `supported: true`, a real
    # invocation, and the summary exception are all removed together.
    RecorderTool(
      supported: false,
      recorderLabel: "a Lua recorder (none exists yet)",
      installHint: @[
        "CodeTracer has no recorder for Lua: recording it would mean",
        "instrumenting the Lua runtime, and no codetracer-lua-recorder has",
        "been written.  Nothing to install; this is a missing feature."])
  of slUnknown, slC, slCpp, slRust, slNim, slGo, slPascal, slFortran, slD,
     slCrystal, slLean, slJulia, slAda, slElixir, slErlang, slSolidity,
     slMove, slSway, slCairo, slCircom, slLeo, slTolk, slAiken, slCadence,
     slNoir, slAsm, slMidenAsm, slGdScript:
    # Not an interpreted-runtime language: an assessment that puts one of
    # these on `tiInterpreted` is inconsistent, and the honest answer is that
    # no such recorder is described.
    RecorderTool(supported: false, recorderLabel: "")

proc retiredNativeReplayTool(sel: RecorderSelector): RecorderTool =
  ## The ``(language, non-native ISA, raRr | raMcr | raTtd)`` cells: a native
  ## replay approach asked of a target that is not native code.
  ##
  ## This is where the retired rr/gdb backends land -- until LRS-4 the
  ## ``Lang`` members ``LangRuby`` and ``LangPython`` decomposed here; since
  ## LRS-4 no ``Lang`` value does, and the cell is reached only by a selector
  ## that names a native-replay approach for an interpreted language
  ## outright.  The advice the two deleted members used to carry as two
  ## hand-written arms is ONE rule over the triple: no native-replay
  ## recorder exists for a runtime-hosted language, and the working recorder
  ## is the instrumented one.  ``supported: false`` and declared, never
  ## silent.
  let working = instrumentedRuntimeTool(sel.language)
  let name = displayName(sel)
  let spelling =
    case sel.language
    of slRuby: "`--lang ruby`"    # names the working recorder since LRS-4 (Q6)
    of slPython: "`--lang py`"
    else: "the file's own extension"
  RecorderTool(
    supported: false,
    recorderLabel: "a " & token(sel.approach) & "-based " & name &
      " backend (retired; no recorder)",
    sibling: working.sibling,
    installHint: @[
      name & " is recorded by instrumenting its runtime" &
        (if working.recorderLabel.len > 0: " (" & working.recorderLabel & ")"
         else: "") & ",",
      "not by " & token(sel.approach) & ".  Drop the flag so the file " &
        "auto-detects, or pass " & spelling & "."])

proc recorderToolFor*(sel: RecorderSelector): RecorderTool =
  ## PURE: the recorder description for ``sel``, with no environment or
  ## filesystem access.  This is the table the dispatch test asserts.
  ##
  ## Dispatch order is approach, then ISA, then language — the language only
  ## where the ISA is the language's own runtime.  An empty ``recorderLabel``
  ## with ``supported: false`` means "not this table's business" (the native
  ## family); every other unsupported cell is DECLARED with a remedy.
  case sel.approach
  of raUnknown:
    RecorderTool(supported: false, recorderLabel: "")

  of raMcr, raRr, raTtd:
    case sel.targetIsa
    of tiNative:
      if sel.language == slNim and sel.approach == raMcr:
        # A compiled `.nim`: `nim c`, then `ct-mcr record`.  The Nim compiler
        # is listed as the RUNTIME artifact although it is a toolchain
        # (`tcNimC`) — `RecorderArtifactKind` has no toolchain kind yet, and
        # the design (§2.3) records this as a known imprecision rather than
        # fixing it here.
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
      else:
        # C, C++, Rust, Go, …: recorded by `ct-native-replay` through
        # `src/ct/trace/record.nim`, not by anything this table names.
        RecorderTool(supported: false, recorderLabel: "")
    of tiUnknown:
      RecorderTool(supported: false, recorderLabel: "")
    of tiInterpreted, tiBeam, tiNimVm, tiGdScriptVm, tiWasm, tiAcir,
       tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm, tiCairoVm, tiAleoVm,
       tiTonVm, tiPlutus, tiFlowVm, tiSolanaSbf, tiCircomWitness:
      retiredNativeReplayTool(sel)

  of raInstrumentedRuntime:
    case sel.targetIsa
    of tiInterpreted:
      instrumentedRuntimeTool(sel.language)
    of tiBeam:
      case sel.language
      of slElixir:
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
      of slErlang:
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
      else:
        RecorderTool(supported: false, recorderLabel: "")
    of tiNimVm:
      # A `.nims`: `nim e --trace:<traceFolder>/trace.ct <program>`.  The
      # recorder IS the compiler's script VM (the codetracer-nim fork's
      # `optTraceVM`), so there is one artifact, not two, and `ct-mcr` is NOT
      # required — which `requireRecorder(LangNim)` used to demand anyway,
      # because one `Lang` value had to answer for both Nim flows.
      if sel.language == slNim:
        RecorderTool(
          supported: true,
          recorderLabel: "the Nim compiler's script VM (`nim e --trace:`)",
          recorderEnvVar: "CODETRACER_NIM_EXE_PATH",
          sibling: "codetracer-nim",
          installHint: @[
            "the tracing script VM lives in the metacraft-labs Nim fork",
            "(codetracer-nim); put its `nim` on PATH or set",
            "CODETRACER_NIM_EXE_PATH=/path/to/nim"])
      else:
        RecorderTool(supported: false, recorderLabel: "")
    of tiGdScriptVm:
      # GDScript's recorder is not a `codetracer-*-recorder` sibling: it IS a
      # patched Godot engine.  GDScript exposes no per-line hook a GDExtension
      # can reach — the only per-line seam is the `OPCODE_LINE` case inside the
      # engine's own bytecode interpreter (`GDScriptFunction::call`,
      # `modules/gdscript/gdscript_vm.cpp`) — so the instrumentation has to live
      # in the engine (codetracer-specs/Recording-Backends/GDScript-Recorder.md,
      # "Why a Godot Engine Fork"; Planned-Features/Mixed-Trace-GDScript.md §1).
      #
      # `supported: false` is a statement about that ARTEFACT's availability,
      # not about the trace it produces.  The patched engine links
      # `libcodetracer_trace_writer.a` and emits a genuine self-contained CTFS
      # container, which is why `usesMaterializedTraces(LangGdScript)` is
      # correctly `true` and a `.gd` trace REPLAYS: the flag is read on the
      # replay path by `loadCalltraceMode` (`src/common/trace_index.nim`),
      # `DebuggerService.lineStepJump` (`src/frontend/services/debugger_service.nim`)
      # and the Call Trace / Event Log panes.  Flipping it to silence the record
      # side would break opening the traces this language exists to open.
      #
      # What does not exist yet is anything for `ct` to spawn: the fork
      # `metacraft-labs/codetracer-engine-godot` is still a to-create
      # deliverable (GDScript-Recorder.milestones.org, G1), there is no sibling
      # checkout, and `scripts/detect-siblings.sh` exports no variable for it.
      # So `recorderEnvVar` is deliberately EMPTY rather than a plausible
      # `CODETRACER_GODOT_*`: no such discovery variable is named by the
      # recorder spec, and inventing one here would read as a contract the
      # engine fork must honour.  The one variable the spec DOES name is
      # `CT_GDSCRIPT_TRACE`, which the engine reads for its OUTPUT DIRECTORY
      # (G2, "record + verify"), so it belongs in the by-hand recipe below and
      # not in the discovery table.
      #
      # The arm exists so `ct record --lang gdscript <file>` is DECLARED rather
      # than silent: with no arm at all this fell through to
      # `RecorderTool(supported: false, recorderLabel: "")` and
      # `missingRecorderMessage` printed one bare "error: CodeTracer has no
      # recorder for GDScript." line with no remedy under it.
      RecorderTool(
        supported: false,
        recorderLabel: "a patched Godot engine (for GDScript the engine IS the recorder)",
        sibling: "codetracer-engine-godot",
        installHint: @[
          "GDScript has no standalone recorder binary: the per-line hook lives",
          "inside Godot's own GDScript VM, so recording needs a patched engine",
          "(a fork of godotengine/godot 4.6.2-stable). CodeTracer does not ship",
          "that engine yet, so `ct record` cannot record GDScript for you.",
          "If you already have a patched engine, record with it directly:",
          "  CT_GDSCRIPT_TRACE=/path/to/out godot --headless --script res://<file>.gd",
          "and then open the container with `ct replay -t /path/to/out`."])
    of tiUnknown, tiNative, tiWasm, tiAcir, tiEvm, tiMidenVm, tiMoveVm,
       tiFuelVm, tiPolkaVm, tiCairoVm, tiAleoVm, tiTonVm, tiPlutus, tiFlowVm,
       tiSolanaSbf, tiCircomWitness:
      RecorderTool(supported: false, recorderLabel: "")

  of raVmEmulation:
    case sel.targetIsa
    of tiWasm:
      # One arm for every language compiled to wasm.  This used to be TWO
      # `Lang` members (`LangRustWasm`, `LangCppWasm`) welding the ISA onto the
      # language; here the language is advisory and the ISA selects.
      RecorderTool(
        supported: true,
        recorderLabel: "wazero",
        recorderEnvVar: "CODETRACER_WASM_VM_PATH",
        sibling: "codetracer-wasm-recorder",
        installHint: @[
          "build it with `cd ../codetracer-wasm-recorder && just build`,",
          "then put the wazero binary on PATH or set CODETRACER_WASM_VM_PATH"])
    of tiAcir:
      RecorderTool(
        supported: true,
        recorderLabel: "nargo",
        recorderEnvVar: "CODETRACER_NOIR_EXE_PATH",
        sibling: "noir",
        installHint: @[
          "build the metacraft-labs noir fork with",
          "`cd ../noir && cargo build --release`, then put target/release on",
          "PATH or set CODETRACER_NOIR_EXE_PATH"])
    of tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm, tiCairoVm, tiAleoVm,
       tiTonVm, tiPlutus, tiFlowVm, tiSolanaSbf, tiCircomWitness:
      let name = blockchainRecorderName(sel.targetIsa)
      RecorderTool(
        supported: true,
        recorderLabel: name,
        recorderEnvVar: blockchainRecorderEnvVar(sel.targetIsa),
        sibling: blockchainRecorderSibling(sel.targetIsa),
        installHint: @[
          "build it with `cd ../" & blockchainRecorderSibling(sel.targetIsa) &
            " && just build`,",
          "then put the binary on PATH or set " &
            blockchainRecorderEnvVar(sel.targetIsa)])
    of tiUnknown, tiNative, tiInterpreted, tiNimVm, tiBeam, tiGdScriptVm:
      RecorderTool(supported: false, recorderLabel: "")

proc serverSupport*(sel: RecorderSelector): ServerSupport =
  ## PURE: what ``ct record --server`` does for ``sel``.
  ##
  ## The six recorders listed here are exactly the six that gained web-request
  ## span recording, and the split matches how each one produces those spans:
  ## five publish them from middleware running inside the recorded process,
  ## PHP publishes them from the extension in each worker, and a native server
  ## has no middleware seam at all so the spans are discovered afterwards by a
  ## separate supervisor binary.
  case sel.approach
  of raInstrumentedRuntime:
    case sel.targetIsa
    of tiInterpreted:
      case sel.language
      of slPhp: ssWorkerDir
      of slPython, slRuby, slJavaScript: ssMiddleware
      else: ssUnsupported
    of tiBeam:
      if sel.language in {slElixir, slErlang}: ssMiddleware else: ssUnsupported
    else: ssUnsupported
  of raMcr, raRr, raTtd:
    if sel.targetIsa != tiNative:
      ssUnsupported
    elif sel.language == slNim:
      # `.nim` records through ct-mcr after a compile step; the supervisor
      # flow has not been wired through that compile, so say so rather than
      # silently recording a plain run.
      ssUnsupported
    elif sel.language == slUnknown:
      ssUnsupported
    else:
      # The native family (C, C++, Rust, Go, …) records through the rr/MCR
      # backend, and codetracer-native-recorder's `ct_server_record` is the
      # binary that supervises a long-running server recording for it.
      ssSupervisor
  of raVmEmulation, raUnknown:
    ssUnsupported

proc serverUnsupportedMessage*(sel: RecorderSelector): seq[string] =
  ## What ``ct record --server`` prints for a target that has no
  ## server-recording story yet.  Never silently degrade to a plain run: a
  ## plain run of a server records a process that never returns and produces
  ## no request spans, which looks like a hang rather than an error.
  result.add("error: `ct record --server` is not supported for " &
    displayName(sel) & ".")
  result.add("help: --server is implemented for the languages whose " &
    "recorders publish web-request spans:")
  result.add("help:   Python, Ruby, PHP, Elixir, Erlang, JavaScript, and " &
    "native (C/C++/Rust) servers.")
  result.add("help: record the run without --server, or see " &
    "`just demo-request-panel` for the supported flows.")

proc recorderRequirements*(sel: RecorderSelector): seq[RecorderArtifact] =
  ## The same table, resolved against the environment.  A ``path`` of ""
  ## means "not installed", which is what the caller turns into the
  ## diagnostic.  Resolution order per artifact is the one
  ## ``scripts/detect-siblings.sh`` sets up: the ``CODETRACER_*`` override
  ## first, then the PATH search an installed package gets.
  let tool = recorderToolFor(sel)
  if not tool.supported:
    return @[]

  if tool.runtimeLabel.len > 0:
    var runtimePath = ""
    case sel.language
    of slRuby: runtimePath = rubyExe()
    of slPhp: runtimePath = phpExe()
    of slElixir: runtimePath = elixirExe()
    of slErlang: runtimePath = escriptExe()
    of slNim: runtimePath = nimCompilerExe()
    else: discard
    result.add(RecorderArtifact(
      kind: raRuntime, label: tool.runtimeLabel,
      envVar: tool.runtimeEnvVar, path: runtimePath))

  var recorderPath = ""
  case sel.approach
  of raInstrumentedRuntime:
    case sel.targetIsa
    of tiInterpreted:
      case sel.language
      of slRuby: recorderPath = rubyRecorderPath()
      of slPython: recorderPath = pythonRecorderExe()
      of slJavaScript: recorderPath = jsRecorderExe()
      of slPhp:
        # The PHP recorder is a shared object, not an executable, so the
        # existence check is fileExists rather than a PATH search.
        recorderPath = if phpRecorderExtension.len > 0 and
                          fileExists(phpRecorderExtension): phpRecorderExtension
                       else: ""
      of slBash: recorderPath = bashRecorderExe()
      of slZsh: recorderPath = zshRecorderExe()
      else: discard
    of tiBeam: recorderPath = beamRecorderExe()
    of tiNimVm: recorderPath = nimCompilerExe()
    else: discard
  of raVmEmulation:
    case sel.targetIsa
    of tiWasm: recorderPath = wazeroExe()
    of tiAcir: recorderPath = noirExe()
    else: recorderPath = blockchainRecorderExe(sel.targetIsa)
  of raMcr:
    if sel.targetIsa == tiNative and sel.language == slNim:
      recorderPath = mcrRecorderExe()
  of raRr, raTtd, raUnknown:
    discard
  result.add(RecorderArtifact(
    kind: raRecorder, label: tool.recorderLabel,
    envVar: tool.recorderEnvVar, path: recorderPath))

proc missingArtifacts*(sel: RecorderSelector): seq[RecorderArtifact] =
  ## The artifacts of ``sel``'s toolchain that are NOT installed.
  for artifact in recorderRequirements(sel):
    if artifact.path.len == 0:
      result.add(artifact)

proc missingRecorderMessage*(sel: RecorderSelector,
                             missing: seq[RecorderArtifact]): seq[string] =
  ## The message ``ct`` prints when a recording cannot even be attempted.
  ## Modelled on the Python path's ``checkPythonRecorder`` diagnostic, which
  ## is the quality bar: name the language, name the artifact, and give the
  ## command that installs it — never fall through to another backend.
  let tool = recorderToolFor(sel)
  let name = displayName(sel)
  if not tool.supported:
    result.add("error: CodeTracer has no recorder for " & name & ".")
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
      result.add("error: the " & name & " runtime `" & artifact.label &
        "` was not found, so `ct record` cannot record this " & name &
        " program.")
      result.add("help: install " & name &
        " and put `" & artifact.label & "` on PATH, or set " &
        artifact.envVar & "=/path/to/" & artifact.label & ".")
    of raRecorder:
      recorderMissing = true
      result.add("error: the " & name & " recorder `" &
        artifact.label & "` was not found, so `ct record` cannot record " &
        "this " & name & " program.")
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
        "a working " & name & " toolchain:")
      result.add("help:   direnv exec ../" & tool.sibling & " <command>")

proc recorderInvocation*(sel: RecorderSelector, program: string,
                         traceFolder: string,
                         opts: RecorderOptions = RecorderOptions()):
    RecorderInvocation =
  ## The exact process ``ct`` spawns for ``sel``.  ``exe`` is already
  ## resolved; an empty ``exe`` means the toolchain check should have
  ## rejected the run before getting here.
  ##
  ## Every recorder here follows the recorder convention
  ## (codetracer-specs/Recorders/Recorder-CLI-Convention.md): the output
  ## directory is named with ``--out-dir`` and the program is the last
  ## positional argument.  The three exceptions are called out inline.
  ##
  ## The two Nim flows are NOT here: ``recordNim`` in
  ## ``src/ct/db_backend_record.nim`` owns their argv (a compile step before
  ## ``ct-mcr``; ``nim e --trace:`` for the script VM), so their selectors
  ## return an empty invocation and the table only names the tool for them.
  case sel.approach
  of raInstrumentedRuntime:
    case sel.targetIsa
    of tiInterpreted:
      case sel.language
      of slRuby:
        # `ruby <recorder-script> --out-dir <dir> <program>` — the Ruby
        # recorder is a Ruby script, so the process is the interpreter.
        RecorderInvocation(
          exe: rubyExe(),
          args: @[rubyRecorderPath(), "--out-dir", traceFolder, program])
      of slPython:
        var args = @["--out-dir", traceFolder]
        if opts.pythonActivationPath.len > 0:
          args.add("--activation-path")
          args.add(opts.pythonActivationPath)
        if opts.pythonTestFramework.len > 0:
          # pytest/unittest mode: the framework flag swallows the rest of
          # argv, so the program is NOT appended.
          args.add("--" & opts.pythonTestFramework)
          args = args & opts.pythonTestArgs
        else:
          args.add(program)
        RecorderInvocation(exe: pythonRecorderExe(), args: args)
      of slJavaScript:
        RecorderInvocation(
          exe: jsRecorderExe(),
          args: @["record", "--out-dir", traceFolder, program])
      of slPhp:
        # EXCEPTION 1: codetracer-php-recorder ships no executable.  The
        # recorder is a Zend extension loaded into `php` itself, and it is
        # configured entirely through the environment (see
        # ext/codetracer_php.c's trace-directory selection):
        # CODETRACER_TRACE_DIR names the output directory verbatim — the
        # single-process form a `ct record app.php` wants — whereas
        # CODETRACER_OUTPUT_DIR makes each worker write its own
        # `worker_<pid>/` beneath it, which is the form a recorded `php -S`
        # server needs.  `--server` is what picks between them.
        var env = @[("CODETRACER_ENABLED", "1")]
        if opts.server:
          env.add(("CODETRACER_OUTPUT_DIR", traceFolder))
        else:
          env.add(("CODETRACER_TRACE_DIR", traceFolder))
        RecorderInvocation(
          exe: phpExe(),
          args: @["-d", "extension=" & phpRecorderExtension, program],
          env: env)
      of slBash:
        RecorderInvocation(
          exe: bashRecorderExe(), args: @["--out-dir", traceFolder, program])
      of slZsh:
        RecorderInvocation(
          exe: zshRecorderExe(), args: @["--out-dir", traceFolder, program])
      else:
        RecorderInvocation()
    of tiBeam:
      # EXCEPTION 2: the BEAM recorder wraps an arbitrary command rather than
      # taking a script path, because a BEAM program is started by its build
      # tool.  `--source-dir` is what makes the recorder instrument the
      # program's own sources instead of only the runtime's.
      case sel.language
      of slElixir:
        RecorderInvocation(
          exe: beamRecorderExe(),
          args: @["record", "--out-dir", traceFolder,
                  "--source-dir", program.parentDir,
                  "--", elixirExe(), program])
      of slErlang:
        RecorderInvocation(
          exe: beamRecorderExe(),
          args: @["record", "--out-dir", traceFolder,
                  "--source-dir", program.parentDir,
                  "--", escriptExe(), program])
      else:
        RecorderInvocation()
    else:
      RecorderInvocation()
  of raVmEmulation:
    case sel.targetIsa
    of tiAcir:
      # EXCEPTION 3: nargo traces the package it is run INSIDE, so the program
      # is expressed as the working directory rather than an argument.
      let backendArgs = if opts.backend == "plonky2": @["--trace-plonky2"]
                        else: @[]
      RecorderInvocation(
        exe: noirExe(),
        args: @["trace", "--out-dir", traceFolder] & backendArgs,
        workdir: if dirExists(program): program else: program.parentDir)
    of tiWasm:
      var args = @["run"]
      if opts.stylusTrace.len > 0:
        args.add("-stylus")
        args.add(opts.stylusTrace)
      args = args & @["--out-dir", traceFolder, program]
      RecorderInvocation(exe: wazeroExe(), args: args)
    of tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm, tiCairoVm, tiAleoVm,
       tiTonVm, tiPlutus, tiFlowVm, tiSolanaSbf, tiCircomWitness:
      RecorderInvocation(
        exe: blockchainRecorderExe(sel.targetIsa),
        args: @["record", "--out-dir", traceFolder, program])
    else:
      RecorderInvocation()
  of raMcr, raRr, raTtd, raUnknown:
    RecorderInvocation()

proc serverGuidance*(sel: RecorderSelector, traceFolder: string): seq[string] =
  ## What ``ct record --server`` prints before handing control to the
  ## recorder.  The point of the flag is that the recording is watchable
  ## while it runs, so the very first thing the user needs is the path to
  ## watch and the command that watches it.
  result.add("recording " & displayName(sel) & " server into: " & traceFolder)
  case serverSupport(sel)
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
