import
  std/[options, os, parseopt, strutils, tables],
  confutils/defs,
  confutils/clispec_config,
  confutils/shell_completion,
  cli/logging,
  globals

# TODO check if the values with special characters
# are parsed correctly by confutils
# and consider a fix if not
type
  ArbCommand* {.pure.} = enum
    noCommand,
    explorer,
    record,
    replay,
    deploy,
    listRecentTx

  CICommand* {.pure.} = enum
    ## Subcommands for ``ct ci``.
    noCommand,
    start,      ## Create a new CI run
    attach,     ## Attach to an existing run
    exec,       ## Execute a command and stream logs
    finish,     ## Complete a run
    run,        ## All-in-one: start + exec + finish
    log,        ## Append a manual log line
    status,     ## Print run status
    cancel      ## Cancel a run

  OmniscientDbMode* {.pure.} = enum
    ## M31 — client-controlled omniscient-DB upload mode for
    ## ``ct trace upload`` (Value-Origin-Tracking milestone M31).
    ##
    ## The recording client signals on the CS-M7 ``/finalize`` body
    ## how the cluster should prepare the M18 / M19 omniscient
    ## artefacts (``memwrites.tc`` / ``linehits.tc`` /
    ## ``originmeta.tc`` / ``varwrites.tc`` / ``source_exprs.tc``)
    ## for the uploaded slice. See spec §6.8.6 for the underlying
    ## V1 mode model and
    ## ``codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org``
    ## §M31 for the wire-contract extension.
    ##
    ## - ``off`` (default, CS-M7 legacy behaviour): server stores
    ##   the slice as-is, no omniscient namespaces; downstream
    ##   replay runs Mode 1.
    ## - ``on`` (eager): server enqueues a high-priority prep job
    ##   that re-emulates the slice and emits the omniscient
    ##   artefacts before the slice becomes replay-ready.
    ## - ``lazy``: slice becomes replay-ready immediately in
    ##   Mode 1; the omniscient build runs opportunistically.
    ## - ``pre-prepared``: the client uploads a slice that already
    ##   contains the omniscient namespaces; the server validates
    ##   and stores them as-is.
    off,
    on,
    lazy,
    `pre-prepared`

  TraceCommand* {.pure.} = enum
    ## Subcommands for ``ct trace``.
    ##
    ## Centralizes trace post-processing operations under a single
    ## verb. Each sub-subcommand forwards to the internal recorder
    ## binary that actually implements it (today this is ``ct-mcr``
    ## for MCR-format traces). Users should only ever invoke ``ct
    ## trace ...``; the direct ``ct-mcr`` calls are an implementation
    ## detail. See P7.1 of the Performance + E2E Coverage campaign.
    noCommand,
    `extract-gfx`, ## Extract a recorded graphics stream
    `export`,      ## Export a trace (e.g. ``--portable`` for upload-ready containers)
    `omniscient-prep` ## Prepare OmniscientDB artifacts for a trace

  StartupCommand* {.pure.} = enum
    noCommand,
    replay,
    run,
    remote,
    install,
    upload,
    download,
    login,
    `set-default-org`,
    `get-default-org`,
    activate,
    `check-license`,
    # cmdDelete,
    build,
    record,
    `record-test`,
    console,
    host,
    `import`,
    arb,
    ci,
    `index-diff`,
    edit,

    # RV-1 (`codetracer-specs/DeepReview/Review-Command.milestones.org`):
    # DeepReview's entire command-line surface.  `ct review <PATH>` is
    # declared here — as an ordinary command with one argument — so it keeps
    # ct's global options and appears in `ct --help` and shell completion.
    # `ct review collect …` and `ct review inspect …` never reach confutils:
    # they carry flags that are not ct's own, so `codetracer.nim` intercepts
    # them ahead of the parser (`review_cli.reviewNeedsRawDispatch`).
    review,

    # `g++`,
    # gcc,
    # rustc,
    # `cargo`,
    # clang,
    # ruby,
    # python,
    # lua,
    # nim,

    list,
    print,    ## Print trace events in human-readable format
    help,

    electron,

    # tail,
    # host,
    # `import`,
    # `import-db-trace`,
    # summary,
    # `report-bug`,

    `trace-metadata`, # TODO .hidden?
    start_backend,

    # P7.1: user-facing wrappers around recorder-internal tools.
    # The book sweep replaces direct ``ct-mcr`` / ``ct_gfx_player``
    # invocations with ``ct``-level subcommands so the documentation
    # only ever references the user-facing CLI. See P7.1 spec.
    trace,         ## ct trace <sub> — graphics extraction / portable export
    `gfx-replay`,  ## ct gfx-replay — forwards to ``ct_gfx_player``
    doctor,        ## ct doctor [<lang>] — recorder readiness probe
    plugins,       ## ct plugins [status] — installed plugins and their faults

    # M7 (CodeTracer Launcher campaign): help delegate subcommands.
    # These power the `help-delegate` protocol from the launcher
    # spec §2.6. The launcher detects `codetracer-desktop` as the
    # help delegate via its capabilities file and execs these
    # subcommands to assemble and surface help.
    `ct-describe-commands`,
    `ct-help`,
    `ct-complete`,

    # M8 (CodeTracer Launcher campaign): shell completion script
    # generator. Emits the per-shell completion script that the user
    # sources or installs into their shell. The generated script calls
    # back into ``codetracer ct-complete`` at runtime (see spec §2.7).
    `ct-completions`,

type
  # the following TODOs are for changes in confutils
  # TODO handle descriptions of commands
  CodetracerConf* = object
    cwd*: Option[string]

    envFiles*: seq[string]

    env0Files*: seq[string]

    tmpEnvFiles*: seq[string]

    tmpEnv0Files*: seq[string]

    # These options are recognized directly because
    # Playwright injects them when launching Electron
    # apps for testing. They get forwarded to Electron.
    inspect*: Option[string]

    remoteDebuggingPort*: Option[string]

    remoteDebuggingPipe*: bool

    # RV-1: the global `--deepreview <PATH>` option that used to live here is
    # RETIRED, not renamed.  DeepReview's whole command-line surface is the
    # `ct review` command group (`StartupCommand.review` below), per
    # `codetracer-specs/DeepReview/DeepReview-GUI.md` §1.1.  The retired
    # spelling is diagnosed deliberately in `codetracer.nim` — see
    # `review_cli.retiredDeepReviewMessage` — because confutils' default
    # "Unrecognized option" names no replacement.
    #
    # The frontend-side `--deepreview <PATH>` argument is a DIFFERENT thing
    # and stays: it is the internal ct -> Electron wire that
    # `src/frontend/index/args.nim` parses, not a user-facing option.

    # Tab-vs-window policy overrides.
    # These apply to replay, run, and any command that opens a trace.
    newTab*: bool
    newWindow*: bool

    case cmd*: StartUpCommand
    of StartUpCommand.noCommand:
      noCmdArgs*: string
    # of `g++`:
    #   # forward the arguments to g++ compiler
    #   gppArgs*: seq[string]
    # of gcc:
    #   # forward the arguments to gcc compiler
    #   gccArgs*: seq[string]
    # of rustc:
    #   # forward the arguments to rustc
    #   rustcArgs*: seq[string]
    # of `cargo`:
    #   # forward the arguments to cargo,
    #   # which will forward them to rustc
    #   cargoArgs*: seq[string]
    # of clang:
    #   # forward the arguments to clang
    #   clangArgs*: seq[string]
    # of ruby:
    #   # forward the arguments to ruby
    #   rubyArgs*: seq[string]
    # of python:
    #   # forward the arguments to python
    #   pythonArgs*: seq[string]
    # of lua:
    #   # forward the arguments to lua
    #   luaArgs*: seq[string]
    # of nim:
    #   # forward the arguments to nim compiler
    #   nimArgs*: seq[string]
    of StartUpCommand.install:
      installCtOnPath*: bool
      # TODO: This should be put behind a
      #       when defined(linux) condition,
      #       but Confutils doesn't support this.
      installCtDesktopFile*: bool
      # BPF process monitoring setup. Enabled by
      # default -- all features are installed by
      # `ct install` unless explicitly opted out.
      # Pass --no-bpf to skip. Requires sudo for
      # setcap. On NixOS, BPF is managed via
      # security.wrappers and setup is skipped
      # automatically.
      installBpf*: bool
      # Agent Harbor installation. Enabled by
      # default -- `ct install` downloads and runs
      # the official AH installer if `ah` is not
      # already on PATH.
      # Pass --no-agent-harbor to skip.
      installAgentHarbor*: bool
      # Machine-readable JSON output for GUI
      # progress reporting. When enabled, emits
      # newline-delimited JSON events instead of
      # human-readable text.
      installJson*: bool
    of StartUpCommand.list:
      listFormat*: string
      listTarget*: string
    of StartUpCommand.print:
      printPath*: string

      printFilter*: Option[string]

      printFunction*: Option[string]

      printLimit*: Option[int]

      printFormat*: Option[string]

      # `--verify` and `--follow` are flags, declared as plain `bool` with a
      # default like every other ct flag (`install --json`, `upload
      # --no-portable`); nothing here needs to tell "not given" from "false".
      # Declared `Option[bool]`, they once took the NEXT token as their value,
      # so `ct print --verify <path>` spent the path on it and
      # `ct print <path> --verify` dropped it. See
      # src/ct/cli/print_options_test.nim.
      printVerify*: bool

      printFollow*: bool

    of StartUpCommand.help:
      helpArgs*: seq[string]
    of StartUpCommand.console:
      consoleRecordingId*: Option[string]
      consoleTraceFolder*: Option[string]
      consoleLastTraceMatchingPattern*: Option[string]
      consoleInteractive*: Option[bool]
    of StartUpCommand.host:
      # codetracer host --port <port>
      #        [--bind <addr>]
      #        [--backend-socket-port <port>]
      #        [--frontend-socket <port>]
      #        [--frontend-socket-parameters
      #         <parameters>]
      #        <trace-id>/<trace-folder>
      # `-1` MEANS "THE OPERATOR SAID NOTHING", for the same reason
      # `hostBind`'s default is the empty string: without a value that means
      # absence, `CODETRACER_HOST_PORT` could never be consulted without also
      # overriding an explicit `--port`. `resolveHostPort` in
      # `trace/host.nim` turns absence into auto-assign and carries the
      # reasoning.
      #
      # It was MANDATORY until 2026-10-01 (no `defaultValue`, so confutils
      # required it), while `CLI/ct/host.md` §Options had always said
      # `auto-assign` — WD2's hosted path is exactly the case where the port is
      # the substrate's to allocate rather than the operator's to choose.
      hostPort*: int

      # EMPTY MEANS "THE OPERATOR SAID NOTHING", which is the only way
      # `CODETRACER_HOST_BIND` can be consulted without also overriding an
      # explicit `--bind 127.0.0.1`. `resolveHostBind` in `trace/host.nim`
      # turns absence into loopback and carries the reasoning.
      hostBind*: string

      hostBackendSocketPort*: Option[int]

      hostFrontendSocketPort*: Option[int]

      hostFrontendSocketParameters*: string

      hostIdleTimeout*: string

      hostTracePath*: string

      hostManifestPath*: string

      hostStorageBaseUrl*: string

      hostStorageTenantId*: string

      hostStorageToken*: string

      hostStorageProtocol*: string

      hostTraceArg*: string
    of StartUpCommand.`import`:
      importTraceZipPath*: string
      importOutputPath*: string
    of StartUpCommand.build:
      buildProgramPath*: string
      buildOutputPath*: string
    of StartupCommand.record:
      recordLang*: string

      recordOutputFolder*: string

      # The MCR default and the per-host value set are stated HERE, not only
      # in codetracer-specs: `ct record --help` is where a user looks, and
      # "Record backend" told them nothing about either.  A value this host
      # cannot honour is refused with a message naming the host and the valid
      # values (see src/ct/trace/native_backend_selection.nim).
      recordBackend*: string

      recordExportFile*: string

      recordStylusTrace*: string

      recordAddress*: string

      recordSocket*: string

      recordWithDiff*: string

      recordStoreTraceFolderForPid*: int

      recordUpload*: bool

      # P7.1: visual recording flag. When set, the recorder
      # captures graphics API activity in addition to the native
      # execution trace. Only supported by the MCR backend; the
      # ``record`` dispatcher rejects this flag for non-MCR
      # backends with a precise error message. The book references
      # ``ct record --use-interpose`` so users never have to call
      # ``ct-mcr record --use-interpose`` directly.
      recordUseInterpose*: bool

      # The recorded program is a long-lived server rather than a run that
      # ends on its own.  This is a FLAG on `record` rather than a new
      # subcommand on purpose: the unit of work is still "make one recording
      # of one process", and everything else on `ct record` (-o, --lang,
      # --backend, --upload, --with-diff, --export) applies unchanged.  A
      # separate subcommand would have to duplicate all of it.  `run` and
      # `host` are the wrong homes for the opposite reasons: `run` records a
      # program that terminates and then opens the desktop GUI on the
      # finished recording, and `host` serves an ALREADY-recorded trace over
      # HTTP.  Neither one records a process that outlives the command.
      #
      # See src/ct/trace/recorder_dispatch.nim's ServerSupport for what the
      # flag changes per language.
      recordServer*: bool

      # `--portable` (codetracer-specs CLI/ct/record.md, "Portable traces"):
      # a dispatcher-owned option, forwarded to the backend the dispatcher
      # selects; a backend that cannot honour it refuses it by name (see
      # src/ct/trace/portable_route.nim).
      recordPortable*: bool

      recordProgram*: string

      # NOTE: this cannot be `{.restOfArgs.}` even though that is exactly what
      # it is.  confutils rejects `restOfArgs` in any command that also has
      # flags: its check walks EVERY option, not just the positional ones, and
      # requires each to be a required Arg (nim-confutils.nim ~line 866 -- the
      # `previousOpt.kind == Arg` half of the condition is commented out).
      # `run` gets away with `restOfArgs` only because it declares no flags.
      #
      # So the child's argv is split off from ct's own BEFORE confutils sees
      # it, in `codetracer.nim` -- see `splitRecordChildArgv` there.
      recordArgs*: seq[string]

    of StartupCommand.`record-test`:
      recordTestTestName*: string
      recordTestPath*: string
      recordTestLine*: int
      recordTestColumn*: int
      recordTestWithDiff*: string
      recordTestStoreTraceFolderForPid*: int
    of StartupCommand.replay:
      replayRecordingId*: Option[string]
      replayTraceFolder*: Option[string]
      lastTraceMatchingPattern*: Option[string]
      replayInteractive*: Option[bool]
      # Replay-engine options for native (MCR) recordings.  They reach the
      # engine as their Rule 3 environment twins, which every process between
      # `ct` and the engine passes on unchanged; see
      # `trace/replay_backend_env.nim`.  Values are checked before anything is
      # launched.  When neither the flag nor its variable is given, nothing is
      # published and the engine's own default applies.
      replayThreadSyncOrder*: Option[string]
      replayOsSimulation*: Option[string]
      replayFollowRequestSpans*: Option[string]
    of StartupCommand.run:
      runTracePathOrId*: string

      runArgs*: seq[string]
    of StartUpCommand.remote:
      remoteArgs*: seq[string]
    of StartUpCommand.upload:
      # same args as replay
      uploadRecordingId*: Option[string]
      uploadTraceFolder*: Option[string]
      uploadLastTraceMatchingPattern*: Option[string]
      uploadInteractive*: Option[bool]
      uploadOrg*: Option[string]
      uploadToken*: Option[string]
      uploadBaseUrl*: Option[string]
      uploadNoPortable*: bool
      uploadNoSplitUpload*: bool
      # M31 — client-controlled omniscient-DB upload mode.
      # The recorder client picks how the cluster prepares the
      # M18 / M19 omniscient artefacts for the uploaded slice
      # (off / on / lazy / pre-prepared). Forwarded to the
      # CS-M7 ``/finalize`` body as the camelCase
      # ``omniscientDbMode`` field.  Default ``off`` matches
      # CS-M7 legacy behaviour so the server treats unsigned
      # uploads identically to pre-M31 clients.
      uploadOmniscientDbMode*: OmniscientDbMode
      # AS-2 — the kind-neutral half of `ct upload`.  `--artifact` names a
      # local path to share whatever kind it holds; the kind is recognised
      # from what is in it, and `--kind` is how you say so when it cannot be
      # recognised unambiguously (or when you want to be explicit).
      uploadArtifactPath*: Option[string]
      uploadArtifactKind*: Option[string]
      # AS-3 — client-side encryption.  One flag, for every kind, because the
      # encryption is a property of the *store* and not of what is being
      # stored: `ct upload --encrypt` means the same thing whether the artifact
      # is a recording or a review dataset, and there is one code path behind
      # it.  The password itself is never a command-line argument — see
      # `--password-file` and `readUploadPassword` in `upload.nim` for why.
      uploadEncrypt*: bool
      uploadPasswordFile*: Option[string]
      # A BOOLEAN flag rather than `--password-file -`, and that is a
      # correction rather than a preference.  With a value-taking option, a
      # bare `-` is parsed as the start of another option, so
      # `--password-file -` silently yielded no password at all: with
      # `--encrypt` it then reported "there is no terminal to ask on", and
      # without it the "you gave a password but not --encrypt" refusal never
      # fired.  A flag that takes no value cannot be swallowed that way.
      uploadPasswordStdin*: bool
      # AS-4 — access control, on the same one surface and by the same rule as
      # `--encrypt`: who may read is a property of the *store* and not of what
      # is being stored, so this flag means the same thing for every kind.  An
      # unrecognised value is refused against the closed set by name rather
      # than read as the default.
      #
      # Left as an `Option[string]` and parsed in `uploadCommand` rather than
      # typed as the enum here, because `confutils`' enum parsing is a
      # different door from `parseClosedEnumArgument` and the point of the
      # closed-set rule is that there is only one door.
      uploadVisibility*: Option[string]
    of StartUpCommand.download:
      traceDownloadUrl*: string
      downloadToken*: Option[string]
      downloadBaseUrl*: Option[string]
      # AS-3 — the reading half.  A download does not have to be told whether
      # the artifact is encrypted: the payload says so itself, and `ct download`
      # only needs to be told the password when it is.
      downloadPasswordFile*: Option[string]
      downloadPasswordStdin*: bool
      # for now not needed: we directly import it
      # and delete the zip as a temp artifact
      # traceDownloadOutput*: Option[string]
    of StartUpCommand.login:
      loginDefaultOrg*: Option[string]
      loginBaseUrl*: Option[string]
    of StartUpCommand.`set-default-org`:
      setDefaultOrgName*: string
    of StartUpCommand.`get-default-org`:
      discard
    of StartUpCommand.activate:
      activateToken*: Option[string]
      activateBaseUrl*: Option[string]
    of StartUpCommand.`check-license`:
      checkLicenseToken*: Option[string]
      checkLicenseBaseUrl*: Option[string]
    # of cmdDelete:
    #   traceId*: int
    #   controlId*: string
    of StartUpCommand.arb:
      arbitrumRpcUrl*: string
      case arbCommand*: ArbCommand
      of ArbCommand.noCommand:
        discard
      of ArbCommand.explorer:
        discard
      of ArbCommand.record:
        arbRecordTransaction*: string
      of ArbCommand.replay:
        arbReplayTransaction*: string
      of ArbCommand.deploy:
        discard
      of ArbCommand.listRecentTx:
        discard
    of StartUpCommand.ci:
      ciToken*: Option[string]
      ciBaseUrl*: Option[string]
      case ciCommand*: CICommand
      of CICommand.noCommand:
        discard
      of CICommand.start:
        ciStartRepo*: Option[string]
        ciStartCommit*: Option[string]
        ciStartBranch*: Option[string]
        ciStartBaseCommit*: Option[string]
        ciStartLabel*: Option[string]
        ciStartMonitorProcesses*: bool
      of CICommand.attach:
        ciAttachRunId*: string
      of CICommand.exec:
        ciExecMonitorProcesses*: bool
        ciExecRecord*: bool
        ciExecProgram*: string
        ciExecArgs*: seq[string]
      of CICommand.finish:
        ciFinishStatus*: Option[string]
      of CICommand.run:
        ciRunRepo*: Option[string]
        ciRunCommit*: Option[string]
        ciRunBranch*: Option[string]
        ciRunBaseCommit*: Option[string]
        ciRunLabel*: Option[string]
        ciRunMonitorProcesses*: bool
        ciRunRecord*: bool
        ciRunProgram*: string
        ciRunArgs*: seq[string]
      of CICommand.log:
        ciLogMessage*: string
      of CICommand.status:
        discard
      of CICommand.cancel:
        discard
    of StartUpCommand.`index-diff`:
      indexDiffTracePath*: string
    of StartUpCommand.edit:
      editPath*: string

    of StartUpCommand.review:
      reviewPath*: string

    # of `import`:
    #   importTraceZipPath*: string
    #   importOutputPath*: string
    # of `import-db-trace`:
    #   importDbTracePath*: string
    # of summary:
    #   summaryTraceId*: int

    #   summaryOutputFolder*: string
    # of `report-bug`:
    #   title*: string
    #   description*: string
    #   pid*: string
    #   confirmSend*: bool
    of StartUpCommand.electron:
      electronAppArgs*: seq[string]
    of StartUpCommand.`trace-metadata`:
      recordingMetadataIdArg*: Option[string]
      traceMetadataPathArg*: Option[string]
      traceMetadataRecordPidArg*: Option[int]
      traceMetadataProgramArg*: Option[string]
      traceMetadataRecent*: bool
      traceMetadataRecentFolders*: bool
      traceMetadataAddRecentFolder*: Option[string]
      traceMetadataRecentLimit*: int
      traceMetadataImportCt*: Option[string]
      traceMetadataImportSource*: Option[string]
      traceMetadataTest*: bool
    of StartUpCommand.start_backend:
      backendKind*: string
      isStdio*: bool
      socketPath*: Option[string]

    # P7.1 ``ct trace`` subcommand parent. Mirrors the ``ct ci``
    # multi-level pattern so each post-processing operation gets
    # its own help block and argument schema.
    of StartupCommand.trace:
      case traceCommand*: TraceCommand
      of TraceCommand.noCommand:
        discard
      of TraceCommand.`extract-gfx`:
        traceExtractGfxOutputDir*: string
        traceExtractGfxPath*: string
      of TraceCommand.`export`:
        traceExportPortable*: bool
        traceExportOutput*: string
        traceExportPath*: string
      of TraceCommand.`omniscient-prep`:
        traceOmniscientPrepMode*: string
        traceOmniscientPrepPath*: string

    # P7.1 ``ct gfx-replay`` forwards to ``ct_gfx_player``.  The
    # binary is resolved via ``CODETRACER_CT_GFX_PLAYER_CMD`` and
    # falls back to a sibling-of-ct lookup + PATH.
    of StartUpCommand.`gfx-replay`:
      gfxReplayGfxStream*: string
      gfxReplayHttp*: bool
      gfxReplayPort*: Option[int]
      gfxReplayBackend*: string

    # P7.1 ``ct doctor`` probes recorder readiness. When a
    # language argument is supplied (``ct doctor python``) the
    # probe is targeted; without an argument, every known
    # recorder is probed.
    of StartUpCommand.doctor:
      doctorLanguage*: string

    # Extensibility-Model.md §11.6.5: `ct plugins status` prints what the
    # Plugins pane shows, from what is on disk.
    of StartUpCommand.plugins:
      pluginsAction*: string

    # M7: Help delegate subcommands. The full machinery lives in
    # ``src/ct/launch/help_delegate.nim``; here we just declare the
    # subcommand surfaces so confutils accepts them on the command
    # line. See spec §2.6 (Help Screen Assembly) for the protocol
    # the launcher uses to drive these subcommands.
    of StartUpCommand.`ct-describe-commands`:
      ctDescribeCommandsArgs*: seq[string]
    of StartUpCommand.`ct-help`:
      ctHelpArgs*: seq[string]
    of StartUpCommand.`ct-complete`:
      ctCompleteArgs*: seq[string]

    # M8: ``ct-completions <shell>`` emits the per-shell completion
    # script. The script content is hardcoded per-shell in
    # ``src/ct/launch/help_delegate.nim`` and printed to stdout.
    of StartUpCommand.`ct-completions`:
      ctCompletionsShell*: string


# ─── ct's command line as a clispec description (CS-M10) ────────────────────
#
# `CodetracerConf` above is a plain case object.  ct's command line is the
# clispec description in `cli/ct_cli_description.nim`, instantiated through
# confutils' `cliConfiguration`; `toCodetracerConf` fills the object from what
# it parses, so `runInitial`, `customValidateConfig` and the launch code read
# the same fields as before.  `CodetracerConf.load` keeps the signature of
# confutils' loader and the parsing of nim-confutils' `codetracer` branch
# (172981d; CS-M10's decision of 2026-11-16, option (a)): its error texts on
# stderr and exit 1, its version text, and the `<app path>_<NAME>`
# environment variables.  Help is clispec's: the help screens are what
# clispec's printer prints for the description (`ctHelpScreen`: its default
# design, at the terminal's width and coloured on a terminal, without the
# environment suffixes and the `--<letter>` aliases the description declares
# only for parsing), not confutils' classic layout.

proc parseCliValue*(text: string; value: var int) {.raises: [CliValueError].} =
  ## confutils' `parseCmdArg(int)`, with its message.
  try:
    value = int(parseBiggestInt(text))
  except ValueError as e:
    raise (ref CliValueError)(msg: e.msg, expected: e.msg)

proc parseCliValue*(text: string; value: var bool) {.raises: [CliValueError].} =
  ## confutils' `parseCmdArg(bool)` (an empty value is true), with its
  ## message.
  try:
    value = text.len == 0 or parseBool(text)
  except ValueError:
    let msg = "'" & text & "' is not a valid boolean value. Supported " &
      "values are on/off, yes/no, true/false or 1/0"
    raise (ref CliValueError)(msg: msg, expected: msg)

proc parseCliValue*(text: string; value: var OmniscientDbMode) {.
    raises: [CliValueError].} =
  ## confutils' enum setter (`parseEnumNormalized`: case and `_` ignored in
  ## every letter), with its message.
  for v in OmniscientDbMode:
    if normalize($v) == normalize(text):
      value = v
      return
  let msg = "Invalid enum value: " & text
  raise (ref CliValueError)(msg: msg, expected: msg)

include cli/ct_cli_description

type
  CtCompOption = tuple[name, abbr: string, isBool: bool, values: seq[string]]
  CtCompCommand = tuple[path, subs: seq[string], opts: seq[CtCompOption]]
    ## A command as confutils' `COMP_LINE` protocol saw it: its fields in
    ## declaration order (arguments and the subcommand discriminator
    ## included), and its subcommands (the discriminator's values).

proc toCodetracerConf*(c: CtCli): CodetracerConf =
  ## The one place that knows the shape clispec generates: a plain
  ## `CodetracerConf`, field by field.
  case c.command
  of CtCliCommand.call, CtCliCommand.`noCommand`:
    result = CodetracerConf(cmd: StartUpCommand.`noCommand`)
  of CtCliCommand.`replay`:
    result = CodetracerConf(cmd: StartUpCommand.`replay`)
    result.replayRecordingId = c.`replay`.replayRecordingId
    result.replayTraceFolder = c.`replay`.replayTraceFolder
    result.lastTraceMatchingPattern = c.`replay`.lastTraceMatchingPattern
    result.replayInteractive = c.`replay`.replayInteractive
    result.replayThreadSyncOrder = c.`replay`.replayThreadSyncOrder
    result.replayOsSimulation = c.`replay`.replayOsSimulation
    result.replayFollowRequestSpans = c.`replay`.replayFollowRequestSpans
  of CtCliCommand.`run`:
    result = CodetracerConf(cmd: StartUpCommand.`run`)
    result.runTracePathOrId = c.`run`.runTracePathOrId
    result.runArgs = c.`run`.runArgs
  of CtCliCommand.`remote`:
    result = CodetracerConf(cmd: StartUpCommand.`remote`)
    result.remoteArgs = c.`remote`.remoteArgs
  of CtCliCommand.`install`:
    result = CodetracerConf(cmd: StartUpCommand.`install`)
    result.installCtOnPath = c.`install`.installCtOnPath
    result.installCtDesktopFile = c.`install`.installCtDesktopFile
    result.installBpf = c.`install`.installBpf
    result.installAgentHarbor = c.`install`.installAgentHarbor
    result.installJson = c.`install`.installJson
  of CtCliCommand.`upload`:
    result = CodetracerConf(cmd: StartUpCommand.`upload`)
    result.uploadRecordingId = c.`upload`.uploadRecordingId
    result.uploadTraceFolder = c.`upload`.uploadTraceFolder
    result.uploadLastTraceMatchingPattern = c.`upload`.uploadLastTraceMatchingPattern
    result.uploadInteractive = c.`upload`.uploadInteractive
    result.uploadOrg = c.`upload`.uploadOrg
    result.uploadToken = c.`upload`.uploadToken
    result.uploadBaseUrl = c.`upload`.uploadBaseUrl
    result.uploadNoPortable = c.`upload`.uploadNoPortable
    result.uploadNoSplitUpload = c.`upload`.uploadNoSplitUpload
    result.uploadOmniscientDbMode = c.`upload`.uploadOmniscientDbMode
    result.uploadArtifactPath = c.`upload`.uploadArtifactPath
    result.uploadArtifactKind = c.`upload`.uploadArtifactKind
    result.uploadEncrypt = c.`upload`.uploadEncrypt
    result.uploadPasswordFile = c.`upload`.uploadPasswordFile
    result.uploadPasswordStdin = c.`upload`.uploadPasswordStdin
    result.uploadVisibility = c.`upload`.uploadVisibility
  of CtCliCommand.`download`:
    result = CodetracerConf(cmd: StartUpCommand.`download`)
    result.traceDownloadUrl = c.`download`.traceDownloadUrl
    result.downloadToken = c.`download`.downloadToken
    result.downloadBaseUrl = c.`download`.downloadBaseUrl
    result.downloadPasswordFile = c.`download`.downloadPasswordFile
    result.downloadPasswordStdin = c.`download`.downloadPasswordStdin
  of CtCliCommand.`login`:
    result = CodetracerConf(cmd: StartUpCommand.`login`)
    result.loginDefaultOrg = c.`login`.loginDefaultOrg
    result.loginBaseUrl = c.`login`.loginBaseUrl
  of CtCliCommand.`setDefaultOrg`:
    result = CodetracerConf(cmd: StartUpCommand.`set-default-org`)
    result.setDefaultOrgName = c.`setDefaultOrg`.setDefaultOrgName
  of CtCliCommand.`getDefaultOrg`:
    result = CodetracerConf(cmd: StartUpCommand.`get-default-org`)
  of CtCliCommand.`activate`:
    result = CodetracerConf(cmd: StartUpCommand.`activate`)
    result.activateToken = c.`activate`.activateToken
    result.activateBaseUrl = c.`activate`.activateBaseUrl
  of CtCliCommand.`checkLicense`:
    result = CodetracerConf(cmd: StartUpCommand.`check-license`)
    result.checkLicenseToken = c.`checkLicense`.checkLicenseToken
    result.checkLicenseBaseUrl = c.`checkLicense`.checkLicenseBaseUrl
  of CtCliCommand.`build`:
    result = CodetracerConf(cmd: StartUpCommand.`build`)
    result.buildProgramPath = c.`build`.buildProgramPath
    result.buildOutputPath = c.`build`.buildOutputPath
  of CtCliCommand.`record`:
    result = CodetracerConf(cmd: StartUpCommand.`record`)
    result.recordLang = c.`record`.recordLang
    result.recordOutputFolder = c.`record`.recordOutputFolder
    result.recordBackend = c.`record`.recordBackend
    result.recordExportFile = c.`record`.recordExportFile
    result.recordStylusTrace = c.`record`.recordStylusTrace
    result.recordAddress = c.`record`.recordAddress
    result.recordSocket = c.`record`.recordSocket
    result.recordWithDiff = c.`record`.recordWithDiff
    result.recordStoreTraceFolderForPid = c.`record`.recordStoreTraceFolderForPid
    result.recordUpload = c.`record`.recordUpload
    result.recordUseInterpose = c.`record`.recordUseInterpose
    result.recordServer = c.`record`.recordServer
    result.recordPortable = c.`record`.recordPortable
    result.recordProgram = c.`record`.recordProgram
    result.recordArgs = c.`record`.recordArgs
  of CtCliCommand.`recordTest`:
    result = CodetracerConf(cmd: StartUpCommand.`record-test`)
    result.recordTestTestName = c.`recordTest`.recordTestTestName
    result.recordTestPath = c.`recordTest`.recordTestPath
    result.recordTestLine = c.`recordTest`.recordTestLine
    result.recordTestColumn = c.`recordTest`.recordTestColumn
    result.recordTestWithDiff = c.`recordTest`.recordTestWithDiff
    result.recordTestStoreTraceFolderForPid = c.`recordTest`.recordTestStoreTraceFolderForPid
  of CtCliCommand.`console`:
    result = CodetracerConf(cmd: StartUpCommand.`console`)
    result.consoleRecordingId = c.`console`.consoleRecordingId
    result.consoleTraceFolder = c.`console`.consoleTraceFolder
    result.consoleLastTraceMatchingPattern = c.`console`.consoleLastTraceMatchingPattern
    result.consoleInteractive = c.`console`.consoleInteractive
  of CtCliCommand.`host`:
    result = CodetracerConf(cmd: StartUpCommand.`host`)
    # -1: no `--port` (auto-assign); the description leaves it unset rather
    # than showing a `-1` default in help.
    result.hostPort = c.`host`.hostPort.get(-1)
    result.hostBind = c.`host`.hostBind
    result.hostBackendSocketPort = c.`host`.hostBackendSocketPort
    result.hostFrontendSocketPort = c.`host`.hostFrontendSocketPort
    result.hostFrontendSocketParameters = c.`host`.hostFrontendSocketParameters
    result.hostIdleTimeout = c.`host`.hostIdleTimeout
    result.hostTracePath = c.`host`.hostTracePath
    result.hostManifestPath = c.`host`.hostManifestPath
    result.hostStorageBaseUrl = c.`host`.hostStorageBaseUrl
    result.hostStorageTenantId = c.`host`.hostStorageTenantId
    result.hostStorageToken = c.`host`.hostStorageToken
    result.hostStorageProtocol = c.`host`.hostStorageProtocol
    result.hostTraceArg = c.`host`.hostTraceArg
  of CtCliCommand.`import`:
    result = CodetracerConf(cmd: StartUpCommand.`import`)
    result.importTraceZipPath = c.`import`.importTraceZipPath
    result.importOutputPath = c.`import`.importOutputPath
  of CtCliCommand.`arb`:
    case c.`arb`.command
    of CtCliArbCommand.call, CtCliArbCommand.`noCommand`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`noCommand`)
    of CtCliArbCommand.`explorer`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`explorer`)
    of CtCliArbCommand.`record`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`record`)
      result.arbRecordTransaction = c.`arb`.`record`.arbRecordTransaction
    of CtCliArbCommand.`replay`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`replay`)
      result.arbReplayTransaction = c.`arb`.`replay`.arbReplayTransaction
    of CtCliArbCommand.`deploy`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`deploy`)
    of CtCliArbCommand.`listRecentTx`:
      result = CodetracerConf(cmd: StartUpCommand.`arb`, arbCommand: ArbCommand.`listRecentTx`)
    result.arbitrumRpcUrl = c.`arb`.arbitrumRpcUrl
  of CtCliCommand.`ci`:
    case c.`ci`.command
    of CtCliCiCommand.call, CtCliCiCommand.`noCommand`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`noCommand`)
    of CtCliCiCommand.`start`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`start`)
      result.ciStartRepo = c.`ci`.`start`.ciStartRepo
      result.ciStartCommit = c.`ci`.`start`.ciStartCommit
      result.ciStartBranch = c.`ci`.`start`.ciStartBranch
      result.ciStartBaseCommit = c.`ci`.`start`.ciStartBaseCommit
      result.ciStartLabel = c.`ci`.`start`.ciStartLabel
      result.ciStartMonitorProcesses = c.`ci`.`start`.ciStartMonitorProcesses
    of CtCliCiCommand.`attach`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`attach`)
      result.ciAttachRunId = c.`ci`.`attach`.ciAttachRunId
    of CtCliCiCommand.`exec`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`exec`)
      result.ciExecMonitorProcesses = c.`ci`.`exec`.ciExecMonitorProcesses
      result.ciExecRecord = c.`ci`.`exec`.ciExecRecord
      result.ciExecProgram = c.`ci`.`exec`.ciExecProgram
      result.ciExecArgs = c.`ci`.`exec`.ciExecArgs
    of CtCliCiCommand.`finish`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`finish`)
      result.ciFinishStatus = c.`ci`.`finish`.ciFinishStatus
    of CtCliCiCommand.`run`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`run`)
      result.ciRunRepo = c.`ci`.`run`.ciRunRepo
      result.ciRunCommit = c.`ci`.`run`.ciRunCommit
      result.ciRunBranch = c.`ci`.`run`.ciRunBranch
      result.ciRunBaseCommit = c.`ci`.`run`.ciRunBaseCommit
      result.ciRunLabel = c.`ci`.`run`.ciRunLabel
      result.ciRunMonitorProcesses = c.`ci`.`run`.ciRunMonitorProcesses
      result.ciRunRecord = c.`ci`.`run`.ciRunRecord
      result.ciRunProgram = c.`ci`.`run`.ciRunProgram
      result.ciRunArgs = c.`ci`.`run`.ciRunArgs
    of CtCliCiCommand.`log`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`log`)
      result.ciLogMessage = c.`ci`.`log`.ciLogMessage
    of CtCliCiCommand.`status`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`status`)
    of CtCliCiCommand.`cancel`:
      result = CodetracerConf(cmd: StartUpCommand.`ci`, ciCommand: CICommand.`cancel`)
    result.ciToken = c.`ci`.ciToken
    result.ciBaseUrl = c.`ci`.ciBaseUrl
  of CtCliCommand.`indexDiff`:
    result = CodetracerConf(cmd: StartUpCommand.`index-diff`)
    result.indexDiffTracePath = c.`indexDiff`.indexDiffTracePath
  of CtCliCommand.`edit`:
    result = CodetracerConf(cmd: StartUpCommand.`edit`)
    result.editPath = c.`edit`.editPath
  of CtCliCommand.`review`:
    result = CodetracerConf(cmd: StartUpCommand.`review`)
    result.reviewPath = c.`review`.reviewPath
  of CtCliCommand.`list`:
    result = CodetracerConf(cmd: StartUpCommand.`list`)
    result.listFormat = c.`list`.listFormat
    result.listTarget = c.`list`.target
  of CtCliCommand.`print`:
    result = CodetracerConf(cmd: StartUpCommand.`print`)
    result.printPath = c.`print`.printPath
    result.printFilter = c.`print`.printFilter
    result.printFunction = c.`print`.printFunction
    result.printLimit = c.`print`.printLimit
    result.printFormat = c.`print`.printFormat
    result.printVerify = c.`print`.printVerify
    result.printFollow = c.`print`.printFollow
  of CtCliCommand.`help`:
    result = CodetracerConf(cmd: StartUpCommand.`help`)
  of CtCliCommand.`electron`:
    result = CodetracerConf(cmd: StartUpCommand.`electron`)
    result.electronAppArgs = c.`electron`.electronAppArgs
  of CtCliCommand.`traceMetadata`:
    result = CodetracerConf(cmd: StartUpCommand.`trace-metadata`)
    result.recordingMetadataIdArg = c.`traceMetadata`.recordingMetadataIdArg
    result.traceMetadataPathArg = c.`traceMetadata`.traceMetadataPathArg
    result.traceMetadataRecordPidArg = c.`traceMetadata`.traceMetadataRecordPidArg
    result.traceMetadataProgramArg = c.`traceMetadata`.traceMetadataProgramArg
    result.traceMetadataRecent = c.`traceMetadata`.traceMetadataRecent
    result.traceMetadataRecentFolders = c.`traceMetadata`.traceMetadataRecentFolders
    result.traceMetadataAddRecentFolder = c.`traceMetadata`.traceMetadataAddRecentFolder
    result.traceMetadataRecentLimit = c.`traceMetadata`.traceMetadataRecentLimit
    result.traceMetadataImportCt = c.`traceMetadata`.traceMetadataImportCt
    result.traceMetadataImportSource = c.`traceMetadata`.traceMetadataImportSource
    result.traceMetadataTest = c.`traceMetadata`.traceMetadataTest
  of CtCliCommand.`startBackend`:
    result = CodetracerConf(cmd: StartUpCommand.`start_backend`)
    result.backendKind = c.`startBackend`.backendKind
    result.isStdio = c.`startBackend`.isStdio
    result.socketPath = c.`startBackend`.socketPath
  of CtCliCommand.`trace`:
    case c.`trace`.command
    of CtCliTraceCommand.call, CtCliTraceCommand.`noCommand`:
      result = CodetracerConf(cmd: StartUpCommand.`trace`, traceCommand: TraceCommand.`noCommand`)
    of CtCliTraceCommand.`extractGfx`:
      result = CodetracerConf(cmd: StartUpCommand.`trace`, traceCommand: TraceCommand.`extract-gfx`)
      result.traceExtractGfxOutputDir = c.`trace`.`extractGfx`.traceExtractGfxOutputDir
      result.traceExtractGfxPath = c.`trace`.`extractGfx`.traceExtractGfxPath
    of CtCliTraceCommand.`export`:
      result = CodetracerConf(cmd: StartUpCommand.`trace`, traceCommand: TraceCommand.`export`)
      result.traceExportPortable = c.`trace`.`export`.traceExportPortable
      result.traceExportOutput = c.`trace`.`export`.traceExportOutput
      result.traceExportPath = c.`trace`.`export`.traceExportPath
    of CtCliTraceCommand.`omniscientPrep`:
      result = CodetracerConf(cmd: StartUpCommand.`trace`, traceCommand: TraceCommand.`omniscient-prep`)
      result.traceOmniscientPrepMode = c.`trace`.`omniscientPrep`.traceOmniscientPrepMode
      result.traceOmniscientPrepPath = c.`trace`.`omniscientPrep`.traceOmniscientPrepPath
  of CtCliCommand.`gfxReplay`:
    result = CodetracerConf(cmd: StartUpCommand.`gfx-replay`)
    result.gfxReplayGfxStream = c.`gfxReplay`.gfxReplayGfxStream
    result.gfxReplayHttp = c.`gfxReplay`.gfxReplayHttp
    result.gfxReplayPort = c.`gfxReplay`.gfxReplayPort
    result.gfxReplayBackend = c.`gfxReplay`.gfxReplayBackend
  of CtCliCommand.`doctor`:
    result = CodetracerConf(cmd: StartUpCommand.`doctor`)
    result.doctorLanguage = c.`doctor`.doctorLanguage
  of CtCliCommand.`plugins`:
    result = CodetracerConf(cmd: StartUpCommand.`plugins`)
    result.pluginsAction = c.`plugins`.pluginsAction
  of CtCliCommand.`ctDescribeCommands`:
    result = CodetracerConf(cmd: StartUpCommand.`ct-describe-commands`)
  of CtCliCommand.`ctHelp`:
    result = CodetracerConf(cmd: StartUpCommand.`ct-help`)
  of CtCliCommand.`ctComplete`:
    result = CodetracerConf(cmd: StartUpCommand.`ct-complete`)
    result.ctCompleteArgs = c.`ctComplete`.ctCompleteArgs
  of CtCliCommand.`ctCompletions`:
    result = CodetracerConf(cmd: StartUpCommand.`ct-completions`)
    result.ctCompletionsShell = c.`ctCompletions`.ctCompletionsShell
  result.cwd = c.cwd
  result.envFiles = c.envFiles
  result.env0Files = c.env0Files
  result.tmpEnvFiles = c.tmpEnvFiles
  result.tmpEnv0Files = c.tmpEnv0Files
  result.inspect = c.inspect
  result.remoteDebuggingPort = c.remoteDebuggingPort
  result.remoteDebuggingPipe = c.remoteDebuggingPipe
  result.newTab = c.newTab
  result.newWindow = c.newWindow

const CtCompletionTree: seq[CtCompCommand] = @[
  (path: @[], subs: @["noCommand", "replay", "run", "remote", "install", "upload", "download", "login", "set-default-org", "get-default-org", "activate", "check-license", "build", "record", "record-test", "console", "host", "import", "arb", "ci", "index-diff", "edit", "review", "list", "print", "help", "electron", "trace-metadata", "start_backend", "trace", "gfx-replay", "doctor", "plugins", "ct-describe-commands", "ct-help", "ct-complete", "ct-completions"], opts: @[
    (name: "cwd", abbr: "", isBool: false, values: @[]),
    (name: "env-file", abbr: "", isBool: false, values: @[]),
    (name: "env0-file", abbr: "", isBool: false, values: @[]),
    (name: "tmp-env-file", abbr: "", isBool: false, values: @[]),
    (name: "tmp-env0-file", abbr: "", isBool: false, values: @[]),
    (name: "inspect", abbr: "", isBool: false, values: @[]),
    (name: "remote-debugging-port", abbr: "", isBool: false, values: @[]),
    (name: "remote-debugging-pipe", abbr: "", isBool: true, values: @[]),
    (name: "new-tab", abbr: "", isBool: true, values: @[]),
    (name: "new-window", abbr: "", isBool: true, values: @[]),
    (name: "cmd", abbr: "", isBool: false, values: @["noCommand", "replay", "run", "remote", "install", "upload", "download", "login", "set-default-org", "get-default-org", "activate", "check-license", "build", "record", "record-test", "console", "host", "import", "arb", "ci", "index-diff", "edit", "review", "list", "print", "help", "electron", "trace-metadata", "start_backend", "trace", "gfx-replay", "doctor", "plugins", "ct-describe-commands", "ct-help", "ct-complete", "ct-completions"]),
  ]),
  (path: @["noCommand"], subs: @[], opts: @[
  ]),
  (path: @["replay"], subs: @[], opts: @[
    (name: "id", abbr: "", isBool: false, values: @[]),
    (name: "trace-folder", abbr: "t", isBool: false, values: @[]),
    (name: "lastTraceMatchingPattern", abbr: "", isBool: false, values: @[]),
    (name: "interactive", abbr: "i", isBool: false, values: @[]),
    (name: "thread-sync-order", abbr: "", isBool: false, values: @[]),
    (name: "os-simulation", abbr: "", isBool: false, values: @[]),
    (name: "follow-request-spans", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["run"], subs: @[], opts: @[
    (name: "runTracePathOrId", abbr: "", isBool: false, values: @[]),
    (name: "runArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["remote"], subs: @[], opts: @[
    (name: "remoteArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["install"], subs: @[], opts: @[
    (name: "path", abbr: "p", isBool: true, values: @[]),
    (name: "desktop", abbr: "d", isBool: true, values: @[]),
    (name: "bpf", abbr: "", isBool: true, values: @[]),
    (name: "agent-harbor", abbr: "", isBool: true, values: @[]),
    (name: "json", abbr: "", isBool: true, values: @[]),
  ]),
  (path: @["upload"], subs: @[], opts: @[
    (name: "id", abbr: "", isBool: false, values: @[]),
    (name: "trace-folder", abbr: "t", isBool: false, values: @[]),
    (name: "uploadLastTraceMatchingPattern", abbr: "", isBool: false, values: @[]),
    (name: "interactive", abbr: "i", isBool: false, values: @[]),
    (name: "org", abbr: "", isBool: false, values: @[]),
    (name: "token", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
    (name: "no-portable", abbr: "", isBool: true, values: @[]),
    (name: "no-split-upload", abbr: "", isBool: true, values: @[]),
    (name: "omniscient-db", abbr: "", isBool: false, values: @["off", "on", "lazy", "pre-prepared"]),
    (name: "artifact", abbr: "", isBool: false, values: @[]),
    (name: "kind", abbr: "", isBool: false, values: @[]),
    (name: "encrypt", abbr: "", isBool: true, values: @[]),
    (name: "password-file", abbr: "", isBool: false, values: @[]),
    (name: "password-stdin", abbr: "", isBool: true, values: @[]),
    (name: "visibility", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["download"], subs: @[], opts: @[
    (name: "traceDownloadUrl", abbr: "", isBool: false, values: @[]),
    (name: "token", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
    (name: "password-file", abbr: "", isBool: false, values: @[]),
    (name: "password-stdin", abbr: "", isBool: true, values: @[]),
  ]),
  (path: @["login"], subs: @[], opts: @[
    (name: "default-org", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["set-default-org"], subs: @[], opts: @[
    (name: "setDefaultOrgName", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["get-default-org"], subs: @[], opts: @[
  ]),
  (path: @["activate"], subs: @[], opts: @[
    (name: "token", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["check-license"], subs: @[], opts: @[
    (name: "token", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["build"], subs: @[], opts: @[
    (name: "buildProgramPath", abbr: "", isBool: false, values: @[]),
    (name: "buildOutputPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["record"], subs: @[], opts: @[
    (name: "lang", abbr: "", isBool: false, values: @[]),
    (name: "output-folder", abbr: "o", isBool: false, values: @[]),
    (name: "backend", abbr: "", isBool: false, values: @[]),
    (name: "export", abbr: "e", isBool: false, values: @[]),
    (name: "stylus-trace", abbr: "t", isBool: false, values: @[]),
    (name: "address", abbr: "a", isBool: false, values: @[]),
    (name: "socket", abbr: "", isBool: false, values: @[]),
    (name: "with-diff", abbr: "", isBool: false, values: @[]),
    (name: "store-trace-folder-for-pid", abbr: "", isBool: false, values: @[]),
    (name: "upload", abbr: "", isBool: true, values: @[]),
    (name: "use-interpose", abbr: "", isBool: true, values: @[]),
    (name: "server", abbr: "", isBool: true, values: @[]),
    (name: "portable", abbr: "", isBool: true, values: @[]),
    (name: "recordProgram", abbr: "", isBool: false, values: @[]),
    (name: "recordArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["record-test"], subs: @[], opts: @[
    (name: "recordTestTestName", abbr: "", isBool: false, values: @[]),
    (name: "recordTestPath", abbr: "", isBool: false, values: @[]),
    (name: "recordTestLine", abbr: "", isBool: false, values: @[]),
    (name: "recordTestColumn", abbr: "", isBool: false, values: @[]),
    (name: "with-diff", abbr: "", isBool: false, values: @[]),
    (name: "store-trace-folder-for-pid", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["console"], subs: @[], opts: @[
    (name: "id", abbr: "", isBool: false, values: @[]),
    (name: "trace-folder", abbr: "t", isBool: false, values: @[]),
    (name: "consoleLastTraceMatchingPattern", abbr: "", isBool: false, values: @[]),
    (name: "interactive", abbr: "i", isBool: false, values: @[]),
  ]),
  (path: @["host"], subs: @[], opts: @[
    (name: "port", abbr: "", isBool: false, values: @[]),
    (name: "bind", abbr: "", isBool: false, values: @[]),
    (name: "backend-socket-port", abbr: "", isBool: false, values: @[]),
    (name: "frontend-socket", abbr: "", isBool: false, values: @[]),
    (name: "frontend-socket-parameters", abbr: "", isBool: false, values: @[]),
    (name: "idle-timeout", abbr: "", isBool: false, values: @[]),
    (name: "trace-path", abbr: "", isBool: false, values: @[]),
    (name: "manifest", abbr: "", isBool: false, values: @[]),
    (name: "storage-base-url", abbr: "", isBool: false, values: @[]),
    (name: "storage-tenant-id", abbr: "", isBool: false, values: @[]),
    (name: "storage-token", abbr: "", isBool: false, values: @[]),
    (name: "storage-protocol", abbr: "", isBool: false, values: @[]),
    (name: "hostTraceArg", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["import"], subs: @[], opts: @[
    (name: "importTraceZipPath", abbr: "", isBool: false, values: @[]),
    (name: "importOutputPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["arb"], subs: @["noCommand", "explorer", "record", "replay", "deploy", "listRecentTx"], opts: @[
    (name: "arbitrum-rpc-url", abbr: "", isBool: false, values: @[]),
    (name: "arbCommand", abbr: "", isBool: false, values: @["noCommand", "explorer", "record", "replay", "deploy", "listRecentTx"]),
  ]),
  (path: @["arb", "noCommand"], subs: @[], opts: @[
  ]),
  (path: @["arb", "explorer"], subs: @[], opts: @[
  ]),
  (path: @["arb", "record"], subs: @[], opts: @[
    (name: "arbRecordTransaction", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["arb", "replay"], subs: @[], opts: @[
    (name: "arbReplayTransaction", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["arb", "deploy"], subs: @[], opts: @[
  ]),
  (path: @["arb", "listRecentTx"], subs: @[], opts: @[
  ]),
  (path: @["ci"], subs: @["noCommand", "start", "attach", "exec", "finish", "run", "log", "status", "cancel"], opts: @[
    (name: "token", abbr: "", isBool: false, values: @[]),
    (name: "base-url", abbr: "", isBool: false, values: @[]),
    (name: "ciCommand", abbr: "", isBool: false, values: @["noCommand", "start", "attach", "exec", "finish", "run", "log", "status", "cancel"]),
  ]),
  (path: @["ci", "noCommand"], subs: @[], opts: @[
  ]),
  (path: @["ci", "start"], subs: @[], opts: @[
    (name: "repo", abbr: "", isBool: false, values: @[]),
    (name: "commit", abbr: "", isBool: false, values: @[]),
    (name: "branch", abbr: "", isBool: false, values: @[]),
    (name: "base-commit", abbr: "", isBool: false, values: @[]),
    (name: "label", abbr: "", isBool: false, values: @[]),
    (name: "monitor-processes", abbr: "", isBool: true, values: @[]),
  ]),
  (path: @["ci", "attach"], subs: @[], opts: @[
    (name: "ciAttachRunId", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ci", "exec"], subs: @[], opts: @[
    (name: "monitor-processes", abbr: "", isBool: true, values: @[]),
    (name: "record", abbr: "", isBool: true, values: @[]),
    (name: "ciExecProgram", abbr: "", isBool: false, values: @[]),
    (name: "ciExecArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ci", "finish"], subs: @[], opts: @[
    (name: "status", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ci", "run"], subs: @[], opts: @[
    (name: "repo", abbr: "", isBool: false, values: @[]),
    (name: "commit", abbr: "", isBool: false, values: @[]),
    (name: "branch", abbr: "", isBool: false, values: @[]),
    (name: "base-commit", abbr: "", isBool: false, values: @[]),
    (name: "label", abbr: "", isBool: false, values: @[]),
    (name: "monitor-processes", abbr: "", isBool: true, values: @[]),
    (name: "record", abbr: "", isBool: true, values: @[]),
    (name: "ciRunProgram", abbr: "", isBool: false, values: @[]),
    (name: "ciRunArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ci", "log"], subs: @[], opts: @[
    (name: "ciLogMessage", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ci", "status"], subs: @[], opts: @[
  ]),
  (path: @["ci", "cancel"], subs: @[], opts: @[
  ]),
  (path: @["index-diff"], subs: @[], opts: @[
    (name: "indexDiffTracePath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["edit"], subs: @[], opts: @[
    (name: "editPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["review"], subs: @[], opts: @[
    (name: "reviewPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["list"], subs: @[], opts: @[
    (name: "format", abbr: "", isBool: false, values: @[]),
    (name: "target", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["print"], subs: @[], opts: @[
    (name: "printPath", abbr: "", isBool: false, values: @[]),
    (name: "filter", abbr: "f", isBool: false, values: @[]),
    (name: "function", abbr: "", isBool: false, values: @[]),
    (name: "limit", abbr: "n", isBool: false, values: @[]),
    (name: "format", abbr: "", isBool: false, values: @[]),
    (name: "verify", abbr: "", isBool: true, values: @[]),
    (name: "follow", abbr: "F", isBool: true, values: @[]),
  ]),
  (path: @["help"], subs: @[], opts: @[
  ]),
  (path: @["electron"], subs: @[], opts: @[
    (name: "electronAppArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["trace-metadata"], subs: @[], opts: @[
    (name: "id", abbr: "", isBool: false, values: @[]),
    (name: "path", abbr: "", isBool: false, values: @[]),
    (name: "record-pid", abbr: "r", isBool: false, values: @[]),
    (name: "program", abbr: "", isBool: false, values: @[]),
    (name: "recent", abbr: "", isBool: true, values: @[]),
    (name: "recent-folders", abbr: "", isBool: true, values: @[]),
    (name: "add-recent-folder", abbr: "", isBool: false, values: @[]),
    (name: "limit", abbr: "", isBool: false, values: @[]),
    (name: "import-ct", abbr: "", isBool: false, values: @[]),
    (name: "import-source", abbr: "", isBool: false, values: @[]),
    (name: "test", abbr: "", isBool: true, values: @[]),
  ]),
  (path: @["start_backend"], subs: @[], opts: @[
    (name: "backendKind", abbr: "", isBool: false, values: @[]),
    (name: "stdio", abbr: "", isBool: true, values: @[]),
    (name: "socket-path", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["trace"], subs: @["noCommand", "extract-gfx", "export", "omniscient-prep"], opts: @[
    (name: "traceCommand", abbr: "", isBool: false, values: @["noCommand", "extract-gfx", "export", "omniscient-prep"]),
  ]),
  (path: @["trace", "noCommand"], subs: @[], opts: @[
  ]),
  (path: @["trace", "extract-gfx"], subs: @[], opts: @[
    (name: "output-dir", abbr: "o", isBool: false, values: @[]),
    (name: "traceExtractGfxPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["trace", "export"], subs: @[], opts: @[
    (name: "portable", abbr: "", isBool: true, values: @[]),
    (name: "output", abbr: "o", isBool: false, values: @[]),
    (name: "traceExportPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["trace", "omniscient-prep"], subs: @[], opts: @[
    (name: "mode", abbr: "", isBool: false, values: @[]),
    (name: "traceOmniscientPrepPath", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["gfx-replay"], subs: @[], opts: @[
    (name: "gfx-stream", abbr: "", isBool: false, values: @[]),
    (name: "http", abbr: "", isBool: true, values: @[]),
    (name: "port", abbr: "", isBool: false, values: @[]),
    (name: "backend", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["doctor"], subs: @[], opts: @[
    (name: "doctorLanguage", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["plugins"], subs: @[], opts: @[
    (name: "pluginsAction", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ct-describe-commands"], subs: @[], opts: @[
  ]),
  (path: @["ct-help"], subs: @[], opts: @[
  ]),
  (path: @["ct-complete"], subs: @[], opts: @[
    (name: "ctCompleteArgs", abbr: "", isBool: false, values: @[]),
  ]),
  (path: @["ct-completions"], subs: @[], opts: @[
    (name: "ctCompletionsShell", abbr: "", isBool: false, values: @[]),
  ]),
]


const
  CtProgram = "ct"
  CtReset = "\e[0m"
  CtOption = "\e[34m"
  CtCommand = "\e[36m"

func ctEnvKey(prefix, name: string): string =
  ## confutils' `constructEnvKey`: the whole name upper-cased, `-` and ` `
  ## as `_` (the application path included).
  (prefix & "_" & name).toUpperAscii.multiReplace(("-", "_"), (" ", "_"))

proc ctEnvSources(): CliSources =
  ## confutils' default environment: a parameter that the command line does
  ## not give is read from `<getAppFilename()>_<NAME>`.  The description
  ## declares `<NAME>` as each parameter's `env`; here it gets the prefix.
  let prefix = getAppFilename()
  var env = initTable[string, string]()
  for p in CtCli.cliGrammar.params:
    for name in p.env:
      let key = ctEnvKey(prefix, name)
      if existsEnv(key):
        env[name] = getEnv(key)
  CliSources(env: env)

func ctCommandOf(g: CliGrammar; path: openArray[string]): int =
  ## The command reached by the canonical subcommand words `path`.
  result = 0
  for word in path:
    var found = -1
    for k in g.commands[result].children:
      if g.commands[k].name == word:
        found = k
        break
    if found < 0: return
    result = found

func ctHasPositionals(g: CliGrammar; command: int): bool =
  ## confutils' `hasAnyArgs`: the command declares an argument.
  var ids = g.commands[command].ownParams
  let call = g.commands[command].callChild
  if call >= 0:
    ids.add g.commands[call].ownParams
  for id in ids:
    if g.params[id].kind == cpkPositional:
      return true

func ctParamOf(g: CliGrammar; command: int; spelling: string): int =
  ## The parameter `spelling` (`--LIMIT`, `-n`, `<printPath>`) names in
  ## `command`, compared as `flagMatching ignoreStyle` compares, or -1.
  var ids = g.commands[command].params
  let call = g.commands[command].callChild
  if call >= 0:
    ids.add g.commands[call].params
  if spelling.startsWith("<") and spelling.endsWith(">"):
    let name = spelling[1 ..< ^1]
    for id in ids:
      if g.params[id].name == name: return id
    return -1
  for id in ids:
    let p = g.params[id]
    if p.longName.len > 0 and cmpIgnoreStyle(spelling, "--" & p.longName) == 0:
      return id
  for id in ids:
    let p = g.params[id]
    if p.short != '\0' and spelling.len == 2 and spelling[0] == '-' and
        spelling[1] == p.short:
      return id
  for id in ids:
    let p = g.params[id]
    if p.short != '\0' and spelling.len == 2 and spelling[0] == '-' and
        spelling[1].toLowerAscii == p.short.toLowerAscii:
      return id
  -1

func ctOptName(g: CliGrammar; id: int): string =
  ## The name confutils printed for a field: its `{.name.}` (the long
  ## flag), else the field's name.
  if g.params[id].longName.len > 0: g.params[id].longName
  else: g.params[id].name

func ctErrorText(e: ref CliUsageError): string =
  ## A clispec usage error in the words confutils printed, colours
  ## included (without the "Try ..." line).
  let g = CtCli.cliGrammar
  let command = ctCommandOf(g, e.commandPath)
  case e.kind
  of cekUnknownFlag:
    var key = e.spelling
    if key.startsWith("--"):
      key = key[2 .. ^1]
    elif key.startsWith("-") and key.len > 1:
      # confutils read a cluster letter by letter and named the first
      # letter no option of the command claims.
      key = $key[1]
      for ch in e.spelling[1 .. ^1]:
        if ctParamOf(g, command, "-" & ch) < 0:
          key = $ch
          break
    "Unrecognized option '" & key & "'" & CtReset
  of cekUnknownSubcommand, cekUnexpectedPositional, cekMissingSubcommand:
    if e.commandPath.len == 0 and not ctHasPositionals(g, command):
      CtProgram & " has no such subcommand" & CtReset
    else:
      let who =
        if e.commandPath.len == 0: CtProgram
        else: "The subcommand '" & e.commandPath[^1] & "'"
      who & " does not accept" &
        (if ctHasPositionals(g, command): " additional" else: "") &
        " arguments" & CtReset
  of cekMissingRequired:
    let id = ctParamOf(g, command, e.spelling)
    let name = if id >= 0: ctOptName(g, id) else: e.spelling.strip(chars = {'-', '<', '>'})
    "The required option '" & name & "' was not specified" & CtReset
  of cekMissingValue:
    "The option '" & CtOption & e.spelling & CtReset & "' requires a value" &
      CtReset
  of cekInvalidValue, cekSwitchFalseValue:
    let id = ctParamOf(g, command, e.spelling)
    let name = if id >= 0: ctOptName(g, id) else: e.spelling.strip(chars = {'-', '<', '>'})
    let msg =
      if id >= 0 and g.params[id].isSwitch:
        "'" & e.value & "' is not a valid boolean value. Supported values " &
          "are on/off, yes/no, true/false or 1/0"
      else: e.expected
    "Error while processing the " & CtOption & name & "=" & e.value & CtReset &
      " parameter: " & msg & CtReset
  of cekConflictingSources:
    e.msg & CtReset

func ctStartsWithIgnoreStyle(s, prefix: string): bool =
  ## confutils' `startsWithIgnoreStyle`.
  var i = 0
  var j = 0
  while true:
    while i < s.len and s[i] == '_': inc i
    while j < prefix.len and prefix[j] == '_': inc j
    if j == prefix.len: return true
    elif i == s.len: return false
    elif toLowerAscii(s[i]) != toLowerAscii(prefix[j]): return false
    inc i
    inc j

proc ctCompletionReply(): bool =
  ## confutils' bash `complete -C` protocol (`COMP_LINE`/`COMP_POINT`), as
  ## its loader answered it: print the candidates, one per line, and let
  ## the caller go on with a default configuration.  False when no
  ## completion was asked for.
  let completion = splitCompletionLine()
  if completion.len == 0: return false
  proc find(path: seq[string]): int =
    for i, c in CtCompletionTree:
      if c.path == path: return i
    -1
  var stack = @[0]
  for tok in completion[1 .. ^1]:
    if not tok.startsWith('-'):
      let top = CtCompletionTree[stack[^1]]
      for s in top.subs:
        if cmpIgnoreStyle(s, tok) == 0:
          stack.add find(top.path & s)
          break
  proc say(line: string) =
    try: stdout.writeLine(line)
    except IOError: discard
  proc showMatching(c: CtCompCommand; prefix: string; names, abbrs: bool) =
    var matching: seq[CtCompOption]
    if prefix.len > 0:
      for o in c.opts:
        if names and o.name.len > 0 and ctStartsWithIgnoreStyle(o.name, prefix):
          matching.add o
        if abbrs and o.abbr.len > 0 and ctStartsWithIgnoreStyle(o.abbr, prefix):
          matching.add o
    else:
      matching = c.opts
    for o in matching:
      let trailing = if o.isBool: "" else: "="
      if names and o.name.len > 0: say("--" & o.name & trailing)
      if abbrs and o.abbr.len > 0: say("-" & o.abbr & trailing)
  let cur = completion[^1]
  let prev = if completion.len > 2: completion[^2] else: ""
  let prevPrev = if completion.len > 3: completion[^3] else: ""
  if cur.startsWith('-'):
    let isFullName = cur.startsWith("--")
    var word = cur
    word.removePrefix('-')
    for i in countdown(stack.len - 1, 0):
      let (names, abbrs) =
        if isFullName: (true, false)
        elif cur.len > 1: (false, true)
        else: (true, true)
      showMatching(CtCompletionTree[stack[i]], word, names, abbrs)
  elif prev.startsWith('-') or (prev == "=" and prevPrev.startsWith('-')):
    var word = if prev.len == 1: prevPrev else: prev
    word.removePrefix('-')
    block found:
      for i in countdown(stack.len - 1, 0):
        for o in CtCompletionTree[stack[i]].opts:
          if cmpIgnoreStyle(o.name, word) == 0 or cmpIgnoreStyle(o.abbr, word) == 0:
            for v in o.values:
              if ctStartsWithIgnoreStyle(v, cur): say(v)
            break found
  elif CtCompletionTree[stack[^1]].subs.len > 0:
    for s in CtCompletionTree[stack[^1]].subs:
      if ctStartsWithIgnoreStyle(s, cur): say(s)
  else:
    for i in countdown(stack.len - 1, 0):
      showMatching(CtCompletionTree[stack[i]], "", true, true)
  try: stdout.flushFile()
  except IOError: discard
  true

proc ctConfutilsRest(cmdLine: openArray[string]; word: string;
                     fieldCount: int): tuple[found: bool, rest,
                                             positionals: seq[string]] =
  ## Where confutils' `{.restOfArgs.}` started: once as many parser tokens
  ## as the command has fields have been read (the subcommand word, flags
  ## and the words before it included), every remaining word is the rest.
  ## It counted tokens, so a flag before the command's positional shifts
  ## it (`ct run --new-tab prog a` gives no positional at all).  Read from
  ## `cmdLine` here, where confutils read the process's own arguments.
  var index = 0
  var active = false
  var pending = false
  for kind, key, val in getopt(@cmdLine, shortNoVal = {}, longNoVal = @[]):
    if active and index >= fieldCount:
      result.rest = @cmdLine[min(index, cmdLine.len) .. ^1]
      return
    inc index
    case kind
    of cmdLongOption, cmdShortOption:
      var isBool = false
      for c in CtCompletionTree:
        if c.path.len == 0 or (active and c.path == @[word]):
          for o in c.opts:
            if cmpIgnoreStyle(o.name, key) == 0 or cmpIgnoreStyle(o.abbr, key) == 0:
              isBool = o.isBool
      pending = val.len == 0 and not isBool
    of cmdArgument:
      if pending:
        pending = false
      elif not active:
        if cmpIgnoreStyle(key, word) == 0:
          active = true
          result.found = true
      else:
        result.positionals.add key
    of cmdEnd:
      discard

proc ctApplyConfutilsRest(conf: var CodetracerConf;
                          cmdLine: openArray[string]): string =
  ## `run`, `remote` and `electron` as confutils split them (see
  ## `ctConfutilsRest`); the error text when the split leaves a required
  ## positional without a word.
  case conf.cmd
  of StartUpCommand.run:
    let r = ctConfutilsRest(cmdLine, "run", 2)
    if r.found:
      conf.runArgs = r.rest
      if r.positionals.len > 0:
        conf.runTracePathOrId = r.positionals[0]
      else:
        return "The required option 'runTracePathOrId' was not specified"
  of StartUpCommand.remote:
    let r = ctConfutilsRest(cmdLine, "remote", 1)
    if r.found: conf.remoteArgs = r.rest
  of StartUpCommand.electron:
    let r = ctConfutilsRest(cmdLine, "electron", 1)
    if r.found: conf.electronAppArgs = r.rest
  else:
    discard

func ctConfutilsKind(k: CliErrorKind): ConfigurationErrorKind =
  ## The kind confutils' `ConfigurationError` gives the same refusal.
  case k
  of cekUnknownFlag: ConfigurationErrorKind.cekUnknownOption
  of CliErrorKind.cekMissingValue: ConfigurationErrorKind.cekMissingValue
  of CliErrorKind.cekInvalidValue, cekSwitchFalseValue:
    ConfigurationErrorKind.cekInvalidValue
  of cekUnexpectedPositional, cekUnknownSubcommand, cekMissingSubcommand:
    ConfigurationErrorKind.cekUnexpectedArgument
  of CliErrorKind.cekMissingRequired: ConfigurationErrorKind.cekMissingRequired
  of cekConflictingSources: ConfigurationErrorKind.cekOther

proc ctFirstValueError(argv: openArray[string]; options: CliOptions): string =
  ## The first value in `argv` (argv order) that its parameter rejects, in
  ## confutils' words, or "": confutils rejected a value at the option that
  ## took it, before it read any later word.  Clispec converts values only
  ## once the whole line is read.
  let g = CtCli.cliGrammar
  var tokens: CliTokens
  try:
    tokens = cliTokenize(g, argv, cliWithValueCheck(options, cliValueCheckOfCtCli))
  except CatchableError:
    return ""
  var first = -1
  var firstId = -1
  var firstText, firstProblem = ""
  for id, cands in tokens.candidates:
    for c in cands:
      if c.form == ccfValue and (first < 0 or c.argvIndex < first):
        let problem = cliValueCheckOfCtCli(id, c.text)
        if problem.len > 0:
          first = c.argvIndex
          firstId = id
          firstText = c.text
          firstProblem = problem
  if firstId < 0:
    return ""
  let msg =
    if g.params[firstId].isSwitch:
      "'" & firstText & "' is not a valid boolean value. Supported " &
        "values are on/off, yes/no, true/false or 1/0"
    else: firstProblem
  "Error while processing the " & CtOption & ctOptName(g, firstId) &
    "=" & firstText & CtReset & " parameter: " & msg & CtReset

proc ctConfutilsErrorOrder(e: ref CliUsageError; argv: openArray[string];
                           options: CliOptions; sources: CliSources): string =
  ## Which refusal confutils printed for a line clispec refuses with `e`,
  ## when the order differs.  confutils read the line word by word and
  ## rejected a value at the option that took it, so the first refusal in
  ## argv order is the one printed; clispec converts values only once the
  ## whole line is read.  So: a rejected value before the word clispec
  ## refuses (`ct print --limit --new-tab 5 t.jsonl`, `ct print --limit abc
  ## --bogus x`, `ct print --limit abc x --filter`); of several rejected
  ## values, the first (`ct install --json=maybe --bpf=nah`); and, for a
  ## missing required parameter, any rejected value, then the first missing
  ## one with the outermost command first and each command's in declaration
  ## order (clispec decides the missing ones before it converts a value,
  ## innermost first).  Empty: clispec's own error stands.
  case e.kind
  of cekUnexpectedPositional, cekUnknownSubcommand, cekUnknownFlag,
     CliErrorKind.cekMissingValue:
    if e.argvIndex > 0 and e.argvIndex <= argv.len:
      return ctFirstValueError(argv[0 ..< e.argvIndex], options)
    return ""
  of CliErrorKind.cekInvalidValue, cekSwitchFalseValue:
    return ctFirstValueError(argv, options)
  of CliErrorKind.cekMissingRequired:
    result = ctFirstValueError(argv, options)
    if result.len > 0:
      return
  else:
    return ""
  let g = CtCli.cliGrammar
  var tokens: CliTokens
  try:
    tokens = cliTokenize(g, argv, cliWithValueCheck(options, cliValueCheckOfCtCli))
  except CatchableError:
    return ""
  for command in tokens.selected:
    for id in g.commands[command].ownParams:
      let p = g.params[id]
      var fromEnv = false
      for name in p.env:
        if name in sources.env: fromEnv = true
      if p.required and not p.hasDefault and tokens.candidates[id].len == 0 and
          not fromEnv:
        return "The required option '" & ctOptName(g, id) &
          "' was not specified" & CtReset

func ctCliOptions*(version: string): CliOptions =
  ## The options ct parses its command line with (`version` is the text
  ## `--version` prints).  Exported for the CS-M10 surface test, which asks
  ## the description in-process which help a line requests.
  CliOptions(program: CtProgram, versionText: version, usageExitCode: 1,
             disableCompletionEntry: true)

func ctHelpGrammar(): CliGrammar =
  ## The grammar ct's help screens are rendered from: the description's,
  ## less two things the description declares for parsing that help must
  ## not advertise.
  ##
  ## * `env`: each name there is only the suffix of the variable confutils
  ##   read, `<getAppFilename()>_<NAME>` upper-cased (`ctEnvSources`), so
  ##   `[env: FILTER]` would name a variable ct never reads.  The real name
  ##   embeds the absolute path of the binary (a store path on a Nix
  ##   install), which no shell can `export` and which changes with every
  ##   install, so help names no variable at all, as confutils' help did not.
  ## * the `--<letter>` alias of a one-letter option (`-o` is also `--o`):
  ##   confutils accepted the letter as a long option, and ct keeps parsing
  ##   it, but it is not a spelling to teach; `-o, --output-folder` is listed.
  result = CtCli.cliGrammar
  for p in result.params.mitems:
    p.env = @[]
    if p.short != '\0' and p.alias == "--" & $p.short:
      p.alias = ""

proc ctHelpScreen*(e: ref CliHelpRequest; options: CliOptions;
                   width = CliDefaultWidth; styled = false): string {.
    raises: [].} =
  ## The help screen ct prints for the help request `e`: the page clispec's
  ## printer (`cliPrintHelp`, `e.render`) prints for it, rendered from
  ## `ctHelpGrammar` instead of the description's grammar.  It is the page
  ## `options` asks for (clispec's default design unless
  ## `options.helpLayout` says otherwise, with the `--version` row when
  ## `options.versionText` is set, as clispec adds it), short for `-h` and
  ## long for `--help` and the `help` word (`e.long`), `width` columns wide
  ## (at most `CliMaxWidth`) when the layout leaves the width to the
  ## printer, and styled when `styled` (a classic layout only under
  ## `ccmAlways`).  ct's loader passes the width and colour clispec's
  ## printer would choose for stdout (`cliOutputWidth`, `cliUseColor`).
  ## Exported for the CS-M10 surface test, which compares the screens ct
  ## prints with it.
  if e.json:
    return e.text
  var layout = options.helpLayout
  if layout.style == chsStandard and layout.versionFlag.len == 0 and
      options.versionText.len > 0:
    layout.versionFlag = "Print version"
  if layout.style == chsStandard and layout.width == 0:
    # As clispec's page sizes itself: at most `CliMaxWidth`, and
    # `CliDefaultWidth` for a width that is not positive.
    layout.width = if width > 0: min(width, CliMaxWidth) else: CliDefaultWidth
  let paint = styled and (layout.style == chsStandard or
    options.color == ccmAlways)
  let g = ctHelpGrammar()
  try:
    cliHelpText(g, cliHelpCommand(g, e.commandPath, options.program),
      options.program, layout, e.long, paint)
  except CliUsageError:
    e.text

proc load*(T: typedesc[CodetracerConf]; cmdLine = commandLineParams();
           version = ""; copyrightBanner = ""; printUsage = true;
           quitOnFailure = true): CodetracerConf {.
    raises: [ConfigurationError].} =
  ## ct's command line, parsed by the clispec description: confutils'
  ## `load` as ct called it.  Help (clispec's) and the version are printed to stdout
  ## and end the process with 0; a usage error is printed to stderr in
  ## confutils' words and ends it with 1 (`quitOnFailure`), or raises
  ## `ConfigurationError`.
  let options = ctCliOptions(version)
  if ctCompletionReply():
    return CodetracerConf(cmd: StartUpCommand.noCommand)
  var restError = ""
  let sources = ctEnvSources()
  try:
    result = toCodetracerConf(CtCli.load(cmdLine, sources, options))
    restError = ctApplyConfutilsRest(result, cmdLine)
  except CliVersionRequest as e:
    try:
      stdout.write e.text & "\n" & CtReset
      stdout.flushFile()
    except IOError:
      discard
    quit QuitSuccess
  except CliHelpRequest as e:
    # The help clispec prints for the request (its default design, not
    # confutils' classic screen: CS-M10's decision of 2026-11-16), at the
    # width and in the colours clispec's printer chooses for stdout
    # (`COLUMNS`, else the terminal's width, else 80, at most 100; styled
    # only on a terminal, without `NO_COLOR`, with `TERM` not `dumb`), ended
    # by a newline.  `copyrightBanner` is no longer printed with it.
    try:
      let text = ctHelpScreen(e, options, cliOutputWidth(stdout),
        cliUseColor(stdout, options.color))
      stdout.write text
      if not text.endsWith("\n"):
        stdout.write "\n"
      stdout.flushFile()
    except IOError:
      discard
    quit QuitSuccess
  except CliUsageError as e:
    var kind = ctConfutilsKind(e.kind)
    var text = ctConfutilsErrorOrder(e, cmdLine, options, sources)
    if text.len == 0:
      text = ctErrorText(e)
    elif text.startsWith("Error while processing"):
      # confutils' refusal is an earlier rejected value: its kind goes with
      # the text (the `record ... --` probe reads it).
      kind = ConfigurationErrorKind.cekInvalidValue
    else:
      kind = ConfigurationErrorKind.cekMissingRequired
    if not quitOnFailure:
      let err = newException(ConfigurationError,
        text.multiReplace((CtReset, ""), (CtOption, "")))
      err.kind = kind
      err.option = e.spelling
      err.value = e.value
      err.detail = e.expected
      raise err
    try:
      stderr.write text & "\n" & "Try " & CtCommand & CtProgram &
        " --help" & CtReset & " for more information.\n"
      stderr.flushFile()
    except IOError:
      discard
    quit QuitFailure
  except CliConfigError as e:
    raise newException(ConfigurationError, e.msg)
  if restError.len > 0:
    if not quitOnFailure:
      raise newException(ConfigurationError, restError)
    try:
      stderr.write restError & CtReset & "\n" & "Try " & CtCommand & CtProgram &
        " --help" & CtReset & " for more information.\n"
      stderr.flushFile()
    except IOError:
      discard
    quit QuitFailure

proc omniscientDbModeToWireString*(mode: OmniscientDbMode): string =
  ## M31 — converts the ``ct trace upload --omniscient-db=`` enum value
  ## into the canonical lowercase-with-hyphens wire string the CS-M7
  ## ``/finalize`` body carries on the camelCase ``omniscientDbMode``
  ## field.
  ##
  ## Nim's enum-with-backticks form means
  ## ``$OmniscientDbMode.pre-prepared`` would round-trip with backticks
  ## or other quirks attached on some stringifiers; emit the canonical
  ## wire spelling directly so the JSON body always matches the spec
  ## §6.8.6 grammar regardless of stringification.
  case mode
  of OmniscientDbMode.off: "off"
  of OmniscientDbMode.on: "on"
  of OmniscientDbMode.lazy: "lazy"
  of OmniscientDbMode.`pre-prepared`: "pre-prepared"

proc customValidateConfig*(
    conf: CodetracerConf) =
  case conf.cmd:
    of StartupCommand.replay,
        StartupCommand.console,
        StartupCommand.upload:
      let r = conf.cmd == StartupCommand.replay
      discard r
      let lastTraceMatchingPattern =
        case conf.cmd:
        of StartupCommand.replay:
          conf.lastTraceMatchingPattern
        of StartupCommand.console:
          conf.consoleLastTraceMatchingPattern
        else: # possible only upload:
          conf.uploadLastTraceMatchingPattern


      let (recordingId,
          traceFolder,
          interactive) =
        case conf.cmd:
        of StartupCommand.replay:
          (conf.replayRecordingId,
            conf.replayTraceFolder,
            conf.replayInteractive)
        of StartupCommand.console:
          (conf.consoleRecordingId,
            conf.consoleTraceFolder,
            conf.consoleInteractive)
        else: # possible only upload:
          (conf.uploadRecordingId,
            conf.uploadTraceFolder,
            conf.uploadInteractive)

      let isSetPattern =
        lastTraceMatchingPattern.isSome
      let isSetRecordingId = recordingId.isSome
      let isSetTraceFolder =
        traceFolder.isSome
      let isSetInteractive =
        interactive.isSome
      let setArgsCount =
        isSetPattern.int +
        isSetRecordingId.int +
        isSetTraceFolder.int +
        isSetInteractive.int
      if setArgsCount > 1:
        errorMessage(
          "configuration error: " &
          "expected no more than " &
          "one arg to command " &
          "to be passed")
        echo "Try `ct --help` " &
          "for more information"
        quit(1)
      if not isSetPattern and
          not isSetRecordingId and
          not isSetTraceFolder:
        replayInteractive = true
      elif isSetInteractive:
        replayInteractive = interactive.get
      else:
        replayInteractive = false
    else:
      discard
