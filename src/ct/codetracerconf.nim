import
  std/options,
  confutils/defs,
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
    cwd* {.
      name: "cwd"
      desc: "Working directory for CodeTracer " &
        "(useful when launched via macOS " &
        "'open' which starts with cwd=/)"
    .} : Option[string]

    envFiles* {.
      name: "env-file"
      desc: "Environment file(s) to load " &
        "(newline-separated KEY=VALUE " &
        "format). Can be specified multiple " &
        "times; later files override " &
        "earlier ones."
      defaultValue: @[]
    .} : seq[string]

    env0Files* {.
      name: "env0-file"
      desc: "Environment file(s) to load " &
        "(null-separated KEY=VALUE format " &
        "from 'env -0'). Can be specified " &
        "multiple times; later files " &
        "override earlier ones."
      defaultValue: @[]
    .} : seq[string]

    tmpEnvFiles* {.
      name: "tmp-env-file"
      desc: "Temporary environment file(s) " &
        "to load (newline-separated " &
        "KEY=VALUE format). Files are " &
        "deleted after loading."
      defaultValue: @[]
    .} : seq[string]

    tmpEnv0Files* {.
      name: "tmp-env0-file"
      desc: "Temporary environment file(s) " &
        "to load (null-separated KEY=VALUE " &
        "format from 'env -0'). Files are " &
        "deleted after loading."
      defaultValue: @[]
    .} : seq[string]

    # These options are recognized directly because
    # Playwright injects them when launching Electron
    # apps for testing. They get forwarded to Electron.
    inspect* {.
      name: "inspect"
      desc: "Node.js inspector port " &
        "(injected by Playwright)"
    .} : Option[string]

    remoteDebuggingPort* {.
      name: "remote-debugging-port"
      desc: "Chrome remote debugging port " &
        "(injected by Playwright)"
    .} : Option[string]

    remoteDebuggingPipe* {.
      name: "remote-debugging-pipe"
      desc: "Chrome remote debugging pipe " &
        "(injected by Playwright for testing)"
      defaultValue: false
    .} : bool

    # Frontend flag forwarded to Electron as an
    # app argument. Parsed by the frontend's
    # src/frontend/index/args.nim.
    deepreview* {.
      name: "deepreview"
      desc: "Path to a DeepReview JSON " &
        "export file (forwarded to " &
        "Electron frontend)"
      defaultValue: ""
    .} : string

    # Tab-vs-window policy overrides.
    # These apply to replay, run, and any command that opens a trace.
    newTab* {.
      name: "new-tab",
      desc: "Open trace as a new tab " &
        "in the existing window " &
        "(overrides config)"
      defaultValue: false
    .}: bool
    newWindow* {.
      name: "new-window",
      desc: "Open trace in a new " &
        "Electron window " &
        "(overrides config)"
      defaultValue: false
    .}: bool

    case cmd* {.
      command,
      defaultValue: StartUpCommand.noCommand
    .}: StartUpCommand
    of StartUpCommand.noCommand:
      noCmdArgs* {.
        ignore
      .}: string
    # of `g++`:
    #   # forward the arguments to g++ compiler
    #   gppArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to g++"
    #   .}: seq[string]
    # of gcc:
    #   # forward the arguments to gcc compiler
    #   gccArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to gcc"
    #   .} : seq[string]
    # of rustc:
    #   # forward the arguments to rustc
    #   rustcArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to rustc"
    #   .} : seq[string]
    # of `cargo`:
    #   # forward the arguments to cargo,
    #   # which will forward them to rustc
    #   cargoArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to cargo"
    #   .} : seq[string]
    # of clang:
    #   # forward the arguments to clang
    #   clangArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to clang"
    #   .} : seq[string]
    # of ruby:
    #   # forward the arguments to ruby
    #   rubyArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to ruby"
    #   .} : seq[string]
    # of python:
    #   # forward the arguments to python
    #   pythonArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to python"
    #   .} : seq[string]
    # of lua:
    #   # forward the arguments to lua
    #   luaArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to lua"
    #   .} : seq[string]
    # of nim:
    #   # forward the arguments to nim compiler
    #   nimArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to nim"
    #   .} : seq[string]
    of install:
      installCtOnPath* {.
        name: "path",
        abbr: "p",
        desc: "Add ct to PATH " &
          "(pass --no-path to skip)"
        defaultValue: true
      .}: bool
      # TODO: This should be put behind a
      #       when defined(linux) condition,
      #       but Confutils doesn't support this.
      installCtDesktopFile* {.
        name: "desktop",
        abbr: "d",
        desc: "Install .desktop file " &
          "(pass --no-desktop to skip, " &
          "Linux only)"
        defaultValue: true
      .}: bool
      # BPF process monitoring setup. Enabled by
      # default -- all features are installed by
      # `ct install` unless explicitly opted out.
      # Pass --no-bpf to skip. Requires sudo for
      # setcap. On NixOS, BPF is managed via
      # security.wrappers and setup is skipped
      # automatically.
      installBpf* {.
        name: "bpf",
        desc: "Set up BPF monitoring " &
          "(--no-bpf to skip)"
        defaultValue: true
      .}: bool
      # Agent Harbor installation. Enabled by
      # default -- `ct install` downloads and runs
      # the official AH installer if `ah` is not
      # already on PATH.
      # Pass --no-agent-harbor to skip.
      installAgentHarbor* {.
        name: "agent-harbor",
        desc: "Install Agent Harbor " &
          "(pass --no-agent-harbor to skip)"
        defaultValue: true
      .}: bool
      # Machine-readable JSON output for GUI
      # progress reporting. When enabled, emits
      # newline-delimited JSON events instead of
      # human-readable text.
      installJson* {.
        name: "json",
        desc: "Output newline-delimited " &
          "JSON progress events"
        defaultValue: false
      .}: bool
    of list:
      listFormat* {.
        name: "format",
        desc: "text or json",
        defaultValue: "text"
      .} : string
      listTarget* {.
        argument,
        name: "target",
        defaultValue: "local",
        desc: "target for list: local or remote"
      .}: string
    of print:
      printPath* {.
        argument,
        desc: "Path to trace directory, " &
          ".ct file, or JSONL manifest"
      .}: string

      printFilter* {.
        name: "filter",
        abbr: "f",
        desc: "Filter events " &
          "(e.g. 'calls', 'steps', " &
          "'http', 'errors')"
      .}: Option[string]

      printFunction* {.
        name: "function",
        desc: "Show only events for " &
          "this function name"
      .}: Option[string]

      printLimit* {.
        name: "limit",
        abbr: "n",
        desc: "Maximum number of events " &
          "to print"
      .}: Option[int]

      printFormat* {.
        name: "format",
        desc: "Output format: " &
          "text (default), json, csv"
      .}: Option[string]

      printVerify* {.
        name: "verify",
        desc: "Verify recording quality " &
          "(exit 0 if valid, 1 if not). " &
          "Checks: trace files exist, " &
          "events present, " &
          "HTTP requests found."
      .}: Option[bool]

      printFollow* {.
        name: "follow",
        abbr: "F",
        desc: "Follow mode: watch for " &
          "new events (like tail -f)"
      .}: Option[bool]

    of help:
      helpArgs* {.
        ignore
      .} : seq[string]
    of console:
      consoleRecordingId* {.
        name: "id",
        # M-REC-6: UUIDv7 recording-id.  See replayRecordingId above.
        # ``--id=<uuid>`` accepts the canonical 36-char form or an 8+
        # hex-char short prefix (see ``trace_index.findByRecordingIdPrefix``).
        desc: "a recording id (UUIDv7) — accepts 8+ char short prefix"
      .}: Option[string]
      consoleTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder"
      .}: Option[string]
      consoleLastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the " &
          "name of the traced program"
      .}: Option[string]
      consoleInteractive* {.
        name: "interactive",
        abbr: "i",
        desc: "explicit flag for " &
          "interactively choosing a trace"
      .}: Option[bool]
    of host:
      # codetracer host --port <port>
      #        [--backend-socket-port <port>]
      #        [--frontend-socket <port>]
      #        [--frontend-socket-parameters
      #         <parameters>]
      #        <trace-id>/<trace-folder>
      hostPort* {.
        name: "port"
        desc: "Port to listen on"
      .} : int

      hostBackendSocketPort* {.
        name: "backend-socket-port"
        desc: "Port to listen on " &
          "for backend socket"
      .} : Option[int]

      hostFrontendSocketPort* {.
        name: "frontend-socket"
        desc: "Port to listen on " &
          "for frontend socket"
      .} : Option[int]

      hostFrontendSocketParameters* {.
        name: "frontend-socket-parameters"
        defaultValue: ""
        desc: "Parameters to forward " &
          "to frontend socket"
      .} : string

      hostIdleTimeout* {.
        name: "idle-timeout"
        defaultValue: ""
        desc: "Host idle timeout " &
          "(e.g., 30s, 5m, 1h). " &
          "Default 10m. " &
          "Use 0/never to disable."
      .} : string

      hostTracePath* {.
        name: "trace-path"
        defaultValue: ""
        desc: "Path to a .ct file, trace " &
          "folder, or local trace-storage " &
          "manifest to auto-import and " &
          "host. Skips the need for a " &
          "separate ct import."
      .} : string

      hostManifestPath* {.
        name: "manifest"
        defaultValue: ""
        desc: "Path to a local shared " &
          "trace-storage or recording " &
          "manifest to host."
      .} : string

      hostStorageBaseUrl* {.
        name: "storage-base-url"
        defaultValue: ""
        desc: "Base URL for storage-server " &
          "manifest object reads. Also " &
          "honors CODETRACER_STORAGE_BASE_URL."
      .} : string

      hostStorageTenantId* {.
        name: "storage-tenant-id"
        defaultValue: ""
        desc: "Tenant id for storage-server " &
          "object reads. Also honors " &
          "CODETRACER_STORAGE_TENANT_ID."
      .} : string

      hostStorageToken* {.
        name: "storage-token"
        defaultValue: ""
        desc: "Replay credential bearer token " &
          "for storage-server object reads. " &
          "Also honors " &
          "CODETRACER_STORAGE_REPLAY_TOKEN."
      .} : string

      hostStorageProtocol* {.
        name: "storage-protocol"
        defaultValue: ""
        desc: "Storage protocol selector " &
          "(default local-storage). Also " &
          "honors CODETRACER_STORAGE_PROTOCOL."
      .} : string

      hostTraceArg* {.
        argument
        defaultValue: ""
        desc: "Trace id to run. If not a " &
          "valid trace id, treats it " &
          "as a trace folder"
      .} : string
    of `import`:
      importTraceZipPath* {.
        argument
        desc: "Trace zip file to import"
      .} : string
      importOutputPath* {.
        argument
        defaultValue: ""
        desc: "Output folder for " &
          "the import command"
      .} : string
    of build:
      buildProgramPath* {.
        argument
        desc: "path to program source code"
      .} : string
      buildOutputPath* {.
        argument
        defaultValue: ""
        desc: "Output path"
      .} : string
    of StartupCommand.record:
      recordLang* {.
        name: "lang"
        defaultValue: ""
        desc: "Language of the recording " &
          "(auto-detected from the " &
          "program path)."
        longDesc:
          "Leave blank to auto-detect. " &
          "Python scripts use the db " &
          "backend and run with the same " &
          "interpreter you would get " &
          "from `python`, honoring " &
          "CODETRACER_PYTHON_INTERPRETER" &
          ", PYTHON_EXECUTABLE, " &
          "PYTHONEXECUTABLE, PYTHON, " &
          "or PATH. Ensure that " &
          "interpreter has the " &
          "codetracer_python_recorder " &
          "package installed."
      .} : string

      recordOutputFolder* {.
        name: "output-folder"
        abbr: "o"
        defaultValue: "."
        desc: "Output folder for " &
          "the recording"
      .} : string

      recordBackend* {.
        name: "backend"
        defaultValue: ""
        desc: "Record backend"
      .} : string

      recordExportFile* {.
        name: "export"
        abbr: "e"
        defaultValue: "",
        desc: "Export zip file for " &
          "the recording"
      .} : string

      recordStylusTrace* {.
        name: "stylus-trace"
        abbr: "t"
        defaultValue: ""
        desc: "Path to a stylus emv " &
          "trace json file"
      .} : string

      recordAddress* {.
        name: "address"
        abbr: "a"
        defaultValue: ""
        desc: "Address when we are " &
          "recording in ci " &
          "mode/environment"
      .}: string

      recordSocket* {.
        name: "socket"
        defaultValue: ""
        desc: "Path to socket for sending " &
          "the trace events metadata " &
          "when in ci mode/environment"
      .}: string

      recordWithDiff* {.
        name: "with-diff"
        defaultValue: ""
        desc: "Record a diff related to " &
          "this trace and produce a " &
          "multitrace. Arg can be " &
          "`last-commit`, path to a " &
          "diff file (must be from the " &
          "current repo!) or a valid " &
          "`git diff <arg>` arg"
      .}: string

      recordStoreTraceFolderForPid* {.
        name: "store-trace-folder-for-pid",
        defaultValue: 0,
        desc: "sets a pid, if we should " &
          "store the resulting trace " &
          "folder in a special tmp " &
          "file, grouping info for a " &
          "certain originating " &
          "codetracer pid. 0 means " &
          "'do not store in such a file'"
      .}: int

      recordUpload* {.
        name: "upload",
        desc: "upload the trace directly " &
          "after recording and " &
          "processing it"
      .}: bool

      recordProgram* {.
        argument
        desc: "Program to record"
      .} : string

      recordArgs* {.
        argument
        defaultValue: @[]
        desc: "Arguments for record",
        longDesc: "longer description " &
          "for record"
      .} : seq[string]

    of StartupCommand.`record-test`:
      recordTestTestName* {.
        argument,
        desc: "Test name",
      .}: string
      recordTestPath* {.
        argument,
        desc: "path to the test section"
      .}: string
      recordTestLine* {.
        argument,
        desc: "line number for " &
          "the test section"
      .}: int
      recordTestColumn* {.
        argument,
        desc: "column number " &
          "(can be 1 if nothing " &
          "applicable) for test section"
      .}: int
      recordTestWithDiff* {.
        name: "with-diff",
        defaultValue: "",
        desc: "Record a diff related to " &
          "this trace and produce a " &
          "multitrace. Arg can be " &
          "`last-commit`, path to a " &
          "diff file (must be from the " &
          "current repo!) or a valid " &
          "`git diff <arg>` arg"
      .}: string
      recordTestStoreTraceFolderForPid* {.
        name: "store-trace-folder-for-pid",
        defaultValue: 0,
        desc: "sets a pid, if we should " &
          "store the resulting trace " &
          "folder in a special tmp " &
          "file, grouping info for a " &
          "certain originating " &
          "codetracer pid. 0 means " &
          "'do not store in such a file'"
      .}: int
    of StartupCommand.replay:
      replayRecordingId* {.
        name: "id",
        # M-REC-6: ``--id`` is a UUIDv7 recording-id (lowercase
        # hyphenated 36-char form).  Accepts an 8+ hex-char short prefix
        # too; ambiguous prefixes error out with the list of matches
        # (see ``trace_index.findByRecordingIdPrefix``).
        desc: "a recording id (UUIDv7) — accepts 8+ char short prefix"
      .}: Option[string]
      replayTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder " &
          "or a multitrace archive"
      .}: Option[string]
      lastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the " &
          "name of the traced program"
      .}: Option[string]
      replayInteractive* {.
        name: "interactive",
        abbr: "i",
        desc: "explicit flag for " &
          "interactively choosing " &
          "a trace"
      .}: Option[bool]
    of StartupCommand.run:
      runTracePathOrId* {.
        argument
        desc: "If not a valid trace ID, " &
          "interpreted as a path to a " &
          "trace, if not a valid path, " &
          "interpreted as a program " &
          "to run"
      .} : string

      runArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Arguments to forward " &
          "to trace run command"
      .} : seq[string]
    of remote:
      remoteArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Trace sharing utilities"
      .}: seq[string]
    of upload:
      # same args as replay
      uploadRecordingId* {.
        name: "id",
        # M-REC-6: UUIDv7 recording-id.  See replayRecordingId above.
        # Short-prefix matching applies.
        desc: "a recording id (UUIDv7) — accepts 8+ char short prefix"
      .}: Option[string]
      uploadTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder"
      .}: Option[string]
      uploadLastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the " &
          "name of the traced program"
      .}: Option[string]
      uploadInteractive* {.
        name: "interactive",
        abbr: "i",
        desc: "explicit flag for " &
          "interactively choosing " &
          "a trace"
      .}: Option[bool]
      uploadOrg* {.
        name: "org",
        desc: "organization to upload to"
      .}: Option[string]
      uploadToken* {.
        name: "token",
        desc: "bearer token " &
          "(uses stored token if omitted)"
      .}: Option[string]
      uploadBaseUrl* {.
        name: "base-url",
        desc: "override the " &
          "remote server URL"
      .}: Option[string]
      uploadNoPortable* {.
        name: "no-portable",
        desc: "skip adding portable " &
          "binaries/symbols to MCR traces " &
          "before upload"
      .}: bool
      uploadNoSplitUpload* {.
        name: "no-split-upload",
        desc: "skip pre-split slice detection " &
          "and force full trace upload " &
          "even when slices are present"
      .}: bool
    of download:
      traceDownloadUrl* {.
        argument,
        desc: "an url for an uploaded trace"
      .}: string
      downloadToken* {.
        name: "token",
        desc: "bearer token " &
          "(uses stored token if omitted)"
      .}: Option[string]
      downloadBaseUrl* {.
        name: "base-url",
        desc: "override the " &
          "remote server URL"
      .}: Option[string]
      # for now not needed: we directly import it
      # and delete the zip as a temp artifact
      # traceDownloadOutput* {.
      #   name: "output",
      #   desc: "output path for the " &
      #     "archive. if not passed: " &
      #     "storing to an " &
      #     "autogenerated path"
      # .}: Option[string]
    of login:
      loginDefaultOrg* {.
        name: "default-org",
        desc: "set a default organization " &
          "for uploads",
      .}: Option[string]
      loginBaseUrl* {.
        name: "base-url",
        desc: "override the " &
          "remote server URL"
      .}: Option[string]
    of `set-default-org`:
      setDefaultOrgName* {.
        argument,
        desc: "the name of an " &
          "organization to be " &
          "updated as default"
      .}: string
    of `get-default-org`:
      discard
    of activate:
      activateToken* {.
        name: "token",
        desc: "bearer token " &
          "(uses stored token if omitted)"
      .}: Option[string]
      activateBaseUrl* {.
        name: "base-url",
        desc: "override the " &
          "remote server URL"
      .}: Option[string]
    of `check-license`:
      checkLicenseToken* {.
        name: "token",
        desc: "bearer token " &
          "(uses stored token if omitted)"
      .}: Option[string]
      checkLicenseBaseUrl* {.
        name: "base-url",
        desc: "override the " &
          "remote server URL"
      .}: Option[string]
    # of cmdDelete:
    #   traceId* {.
    #     name: "trace-id"
    #     desc: "trace trace unique id"
    #   .}: int
    #   controlId* {.
    #     name: "control-id",
    #     desc: "the trace control id " &
    #       "to delete the online trace"
    #   .}: string
    of arb:
      arbitrumRpcUrl* {.
        name: "arbitrum-rpc-url"
        desc: "Arbitrum Node JSON-RPC URL"
        defaultValue: "localhost"
      .}: string
      case arbCommand* {.
        command,
        defaultValue: ArbCommand.noCommand
      .}: ArbCommand
      of ArbCommand.noCommand:
        discard
      of explorer:
        discard
      of ArbCommand.record:
        arbRecordTransaction* {.
          argument
          desc: "Hex-encoded transaction hash"
        .}: string
      of ArbCommand.replay:
        arbReplayTransaction* {.
          argument
          desc: "Hex-encoded transaction hash"
        .}: string
      of deploy:
        discard
      of listRecentTx:
        discard
    of ci:
      ciToken* {.
        name: "token",
        desc: "CI API token " &
          "(uses CODETRACER_TOKEN " &
          "env var if omitted)"
      .}: Option[string]
      ciBaseUrl* {.
        name: "base-url",
        desc: "Override the " &
          "remote server URL"
      .}: Option[string]
      case ciCommand* {.
        command,
        defaultValue: CICommand.noCommand
      .}: CICommand
      of CICommand.noCommand:
        discard
      of CICommand.start:
        ciStartRepo* {.
          name: "repo",
          desc: "Repository URL " &
            "(auto-detected from " &
            "git remote if omitted)"
        .}: Option[string]
        ciStartCommit* {.
          name: "commit",
          desc: "Git commit SHA " &
            "(auto-detected from " &
            "HEAD if omitted)"
        .}: Option[string]
        ciStartBranch* {.
          name: "branch",
          desc: "Git branch name " &
            "(auto-detected if omitted)"
        .}: Option[string]
        ciStartBaseCommit* {.
          name: "base-commit",
          desc: "Base commit SHA " &
            "for diffing"
        .}: Option[string]
        ciStartLabel* {.
          name: "label",
          desc: "Human-readable label " &
            "for the run"
        .}: Option[string]
        ciStartMonitorProcesses* {.
          name: "monitor-processes",
          desc: "Enable BPF process " &
            "tree monitoring",
          defaultValue: false
        .}: bool
      of CICommand.attach:
        ciAttachRunId* {.
          argument,
          desc: "Run ID to attach to"
        .}: string
      of CICommand.exec:
        ciExecMonitorProcesses* {.
          name: "monitor-processes",
          desc: "Enable BPF-based " &
            "process tree monitoring",
          defaultValue: false
        .}: bool
        ciExecRecord* {.
          name: "record",
          desc: "Wrap command in " &
            "ct record and " &
            "auto-upload trace",
          defaultValue: false
        .}: bool
        ciExecProgram* {.
          argument,
          desc: "Command to execute"
        .}: string
        ciExecArgs* {.
          argument,
          defaultValue: @[],
          desc: "Arguments for " &
            "the command"
        .}: seq[string]
      of CICommand.finish:
        ciFinishStatus* {.
          name: "status",
          desc: "Override run status " &
            "(passed/failed/error)"
        .}: Option[string]
      of CICommand.run:
        ciRunRepo* {.
          name: "repo",
          desc: "Repository URL " &
            "(auto-detected from " &
            "git remote if omitted)"
        .}: Option[string]
        ciRunCommit* {.
          name: "commit",
          desc: "Git commit SHA " &
            "(auto-detected from " &
            "HEAD if omitted)"
        .}: Option[string]
        ciRunBranch* {.
          name: "branch",
          desc: "Git branch name " &
            "(auto-detected if omitted)"
        .}: Option[string]
        ciRunBaseCommit* {.
          name: "base-commit",
          desc: "Base commit SHA " &
            "for diffing"
        .}: Option[string]
        ciRunLabel* {.
          name: "label",
          desc: "Human-readable label " &
            "for the run"
        .}: Option[string]
        ciRunMonitorProcesses* {.
          name: "monitor-processes",
          desc: "Enable BPF process " &
            "tree monitoring",
          defaultValue: false
        .}: bool
        ciRunRecord* {.
          name: "record",
          desc: "Wrap command in " &
            "ct record and " &
            "auto-upload trace",
          defaultValue: false
        .}: bool
        ciRunProgram* {.
          argument,
          desc: "Command to execute"
        .}: string
        ciRunArgs* {.
          argument,
          defaultValue: @[],
          desc: "Arguments for " &
            "the command"
        .}: seq[string]
      of CICommand.log:
        ciLogMessage* {.
          argument,
          desc: "Log message to append"
        .}: string
      of CICommand.status:
        discard
      of CICommand.cancel:
        discard
    of `index-diff`:
      indexDiffTracePath* {.
        argument
        desc: "Path to a trace with " &
          "diffs: for now indexing " &
          "only a single trace"
      .}: string
    of edit:
      editPath* {.
        argument
        desc: "Path to a directory or " &
          "file to open for editing"
      .}: string

    # of `import`:
    #   importTraceZipPath* {.
    #     argument
    #     desc: "Trace zip file to import"
    #   .} : string
    #   importOutputPath* {.
    #     argument
    #     defaultValue: ""
    #     desc: "Output folder for " &
    #       "the import command"
    #   .} : string
    # of `import-db-trace`:
    #   importDbTracePath* {.
    #     argument
    #     desc: "Trace path to import"
    #   .}: string
    # of summary:
    #   summaryTraceId* {.
    #     argument
    #     desc: "Trace id to summarize"
    #   .} : int

    #   summaryOutputFolder* {.
    #     argument
    #     desc: "Output folder for " &
    #       "the summary command."
    #   .} : string
    # of `report-bug`:
    #   title* {.
    #     name: "title",
    #     defaultValue: "",
    #     desc: "Title for the bug " &
    #       "report message"
    #   .} : string
    #   description* {.
    #     name: "description",
    #     defaultValue: "",
    #     desc: "Description for the " &
    #       "bug report message"
    #   .} : string
    #   pid* {.
    #     argument,
    #     defaultValue: "last",
    #     desc: "PID number for " &
    #       "the process"
    #   .} : string
    #   confirmSend* {.
    #     name: "confirm-send",
    #     defaultValue: true,
    #     desc: "Warning message for " &
    #       "sensative data"
    #   .} : bool
    of electron:
      electronAppArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Arguments for electron",
        longDesc: "a wrapper to be able " &
          "to call directly the " &
          "electron in our distribution"
      .} : seq[string]
    of `trace-metadata`:
      recordingMetadataIdArg* {.
        name: "id",
        # M-REC-6: UUIDv7 recording-id string.  Accepts an 8+ char
        # short prefix; the lookup goes through
        # ``trace_index.findByRecordingIdPrefix``.
        desc: "a recording id (UUIDv7) — accepts 8+ char short prefix"
      .} : Option[string]
      traceMetadataPathArg* {.
        name: "path",
        desc: "path for a trace"
      .}: Option[string]
      traceMetadataRecordPidArg* {.
        name: "record-pid",
        abbr: "r",
        desc: "record pid for a trace"
      .}: Option[int]
      traceMetadataProgramArg* {.
        name: "program",
        desc: "program pattern to " &
          "find a trace with"
      .}: Option[string]
      traceMetadataRecent* {.
        name: "recent",
        desc: "return recent traces",
        defaultValue: false,
      .}: bool
      traceMetadataRecentFolders* {.
        name: "recent-folders",
        desc: "return recent folders",
        defaultValue: false,
      .}: bool
      traceMetadataAddRecentFolder* {.
        name: "add-recent-folder",
        desc: "add a folder to " &
          "recent folders"
      .}: Option[string]
      traceMetadataRecentLimit* {.
        name: "limit",
        desc: "recent traces/folders " &
          "limit",
        defaultValue: 4,
      .}: int
      traceMetadataTest* {.
        name: "test",
        defaultValue: false,
      .}: bool
    of start_backend:
      backendKind* {.
        argument
        desc: "This is the backend kind" &
          " - either 'db' or 'rr'"
      .}: string
      isStdio* {.
        name: "stdio",
        defaultValue: false,
      .}: bool
      socketPath* {.
        name: "socket-path",
      .}: Option[string]

    # M7: Help delegate subcommands. The full machinery lives in
    # ``src/ct/launch/help_delegate.nim``; here we just declare the
    # subcommand surfaces so confutils accepts them on the command
    # line. See spec §2.6 (Help Screen Assembly) for the protocol
    # the launcher uses to drive these subcommands.
    of `ct-describe-commands`:
      ctDescribeCommandsArgs* {.
        ignore
      .}: seq[string]
    of `ct-help`:
      ctHelpArgs* {.
        ignore
      .}: seq[string]
    of `ct-complete`:
      ctCompleteArgs* {.
        argument
        defaultValue: @[]
        desc: "Partial command line to complete"
      .}: seq[string]

    # M8: ``ct-completions <shell>`` emits the per-shell completion
    # script. The script content is hardcoded per-shell in
    # ``src/ct/launch/help_delegate.nim`` and printed to stdout.
    of `ct-completions`:
      ctCompletionsShell* {.
        argument
        defaultValue: ""
        desc: "Target shell (bash, zsh, fish)"
      .}: string

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
