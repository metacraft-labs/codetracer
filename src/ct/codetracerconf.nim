import
  std/options,
  confutils/defs,
  cli/logging,
  globals

# TODO check if the values with special characters are parsed correctly by confutils
# and consider a fix if not
type
  ArbCommand* {.pure.} = enum
    noCommand,
    explorer,
    record,
    replay,
    deploy,
    listRecentTx

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
    # cmdDelete,
    build,
    record,
    `record-test`,
    console,
    host,
    `import`,
    arb,
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

type
  # the following TODOs are for changes in confutils
  # TODO handle descriptions of commands
  CodetracerConf* = object
    cwd* {.
      name: "cwd"
      desc: "Working directory for CodeTracer (useful when launched via macOS 'open' which starts with cwd=/)"
    .} : Option[string]

    envFiles* {.
      name: "env-file"
      desc: "Environment file(s) to load (newline-separated KEY=VALUE format). Can be specified multiple times; later files override earlier ones."
      defaultValue: @[]
    .} : seq[string]

    env0Files* {.
      name: "env0-file"
      desc: "Environment file(s) to load (null-separated KEY=VALUE format from 'env -0'). Can be specified multiple times; later files override earlier ones."
      defaultValue: @[]
    .} : seq[string]

    tmpEnvFiles* {.
      name: "tmp-env-file"
      desc: "Temporary environment file(s) to load (newline-separated KEY=VALUE format). Files are deleted after loading."
      defaultValue: @[]
    .} : seq[string]

    tmpEnv0Files* {.
      name: "tmp-env0-file"
      desc: "Temporary environment file(s) to load (null-separated KEY=VALUE format from 'env -0'). Files are deleted after loading."
      defaultValue: @[]
    .} : seq[string]

    # These options are recognized directly because Playwright injects them
    # when launching Electron apps for testing. They get forwarded to Electron.
    inspect* {.
      name: "inspect"
      desc: "Node.js inspector port (injected by Playwright for debugging)"
    .} : Option[string]

    remoteDebuggingPort* {.
      name: "remote-debugging-port"
      desc: "Chrome remote debugging port (injected by Playwright for debugging)"
    .} : Option[string]

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
    #     desc: "Arguments to forward to g++ compiler"
    #   .}: seq[string]
    # of gcc:
    #   # forward the arguments to gcc compiler
    #   gccArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to gcc compiler"
    #   .} : seq[string]
    # of rustc:
    #   # forward the arguments to rustc compiler
    #   rustcArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to rustc compiler"
    #   .} : seq[string]
    # of `cargo`:
    #   # forward the arguments to cargo, which will, in turn, forward them to rustc
    #   cargoArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to cargo"
    #   .} : seq[string]
    # of clang:
    #   # forward the arguments to clang compiler
    #   clangArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to clang compiler"
    #   .} : seq[string]
    # of ruby:
    #   # forward the arguments to ruby interpreter
    #   rubyArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to ruby interpreter"
    #   .} : seq[string]
    # of python:
    #   # forward the arguments to python interpreter
    #   pythonArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to python interpreter"
    #   .} : seq[string]
    # of lua:
    #   # forward the arguments to lua interpreter
    #   luaArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to lua interpreter"
    #   .} : seq[string]
    # of nim:
    #   # forward the arguments to nim compiler
    #   nimArgs* {.
    #     restOfArgs
    #     defaultValue: @[]
    #     desc: "Arguments to forward to nim compiler"
    #   .} : seq[string]
    of install:
      installCtOnPath* {.
        name: "path",
        abbr: "p",
        desc: "Install CodeTracer on the PATH"
        defaultValue: true
       .}: bool
      # TODO: This should be put behind a when defined(linux) condition,
      #       but Confutils doesn't support this currently.
      installCtDesktopFile* {.
        name: "desktop",
        abbr: "d",
        desc: "Install CodeTracer .desktop file"
        defaultValue: true
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
    of help:
      helpArgs* {.
        ignore
      .} : seq[string]
    of console:
     consoleTraceId* {.
        name: "id",
        desc: "a trace id"
      .}: Option[int]
     consoleTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder"
      .}: Option[string]
     consoleLastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the name of the traced program"
      .}: Option[string]
     consoleInteractive* {.
       name: "interactive",
       abbr: "i",
       desc: "explicit flag for interactively choosing a trace"
      .}: Option[bool]
    of host:
      # codetracer host --port <port>
      #        [--backend-socket-port <port>]
      #        [--frontend-socket <port>]
      #        [--frontend-socket-parameters <parameters>]
      #        <trace-id>/<trace-folder>
      hostPort* {.
        name: "port"
        desc: "Port to listen on"
      .} : int

      hostBackendSocketPort* {.
        name: "backend-socket-port"
        desc: "Port to listen on for backend socket"
      .} : Option[int]

      hostFrontendSocketPort* {.
        name: "frontend-socket"
        desc: "Port to listen on for frontend socket"
      .} : Option[int]

      hostFrontendSocketParameters* {.
        name: "frontend-socket-parameters"
        defaultValue: ""
        desc: "Parameters to forward to frontend socket"
      .} : string

      hostIdleTimeout* {.
        name: "idle-timeout"
        defaultValue: ""
        desc: "Host idle timeout (e.g., 30s, 5m, 1h). Default 10m. Use 0/never to disable."
      .} : string

      hostTraceArg* {.
        argument
        desc: "Trace id to run. If not a valid trace id, treats it as a trace folder"
      .} : string
    of `import`:
      importTraceZipPath* {.
        argument
        desc: "Trace zip file to import"
      .} : string
      importOutputPath* {.
        argument
        defaultValue: ""
        desc: "Output folder for the import command"
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
        desc: "Language of the recording (auto-detected from the program path)."
        longDesc: "Leave blank to auto-detect. Python scripts use the db backend and run with the same interpreter " &
          "you would get from `python`, honoring CODETRACER_PYTHON_INTERPRETER, PYTHON_EXECUTABLE, PYTHONEXECUTABLE, PYTHON, or PATH. " &
          "Ensure that interpreter has the codetracer_python_recorder package installed."
      .} : string

      recordOutputFolder* {.
        name: "output-folder"
        abbr: "o"
        defaultValue: "."
        desc: "Output folder for the recording"
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
        desc: "Export zip file for the recording"
      .} : string

      recordStylusTrace* {.
        name: "stylus-trace"
        abbr: "t"
        defaultValue: ""
        desc: "Path to a stylus emv trace json file"
      .} : string

      recordAddress* {.
        name: "address"
        abbr: "a"
        defaultValue: ""
        desc: "Address when we are recording in ci mode/environment"
      .}: string

      recordSocket* {.
        name: "socket"
        defaultValue: ""
        desc: "Path to socket for sending the trace events metadata when in ci mode/environment"
      .}: string

      recordWithDiff* {.
        name: "with-diff"
        defaultValue: ""
        desc: "Record a diff related to this trace and produce a multitrace. " &
          "Arg can be `last-commit`, path to a diff file (must be from the current repo!) or a valid `git diff <arg>` arg"
      .}: string

      recordStoreTraceFolderForPid* {.
        name: "store-trace-folder-for-pid",
        defaultValue: 0,
        desc: "sets a pid, if we should store the resulting trace folder in a special tmp file, grouping info " &
          "  for a certain originating codetracer pid. 0 is interpreteded as 'do not store in such a file'"
      .}: int

      recordUpload* {.
        name: "upload",
        desc: "upload the trace directly after recording and processing it"
      .}: bool

      recordProgram* {.
        argument
        desc: "Program to record"
      .} : string

      recordArgs* {.
        argument
        defaultValue: @[]
        desc: "Arguments for record",
        longDesc: "longer description for record"
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
        desc: "line number for the test section"
      .}: int
      recordTestColumn* {.
        argument,
        desc: "column number(can be 1 if nothing applicable) for test section"
      .}: int
      recordTestWithDiff* {.
        name: "with-diff",
        defaultValue: "",
        desc: "Record a diff related to this trace and produce a multitrace. " &
          "Arg can be `last-commit`, path to a diff file (must be from the current repo!) or a valid `git diff <arg>` arg"
      .}: string
      recordTestStoreTraceFolderForPid* {.
        name: "store-trace-folder-for-pid",
        defaultValue: 0,
        desc: "sets a pid, if we should store the resulting trace folder in a special tmp file, grouping info " &
          "  for a certain originating codetracer pid. 0 is interpreteded as 'do not store in such a file'"
      .}: int
    of StartupCommand.replay:
     replayTraceId* {.
        name: "id",
        desc: "a trace id"
      .}: Option[int]
     replayTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder or a multitrace archive"
      .}: Option[string]
     lastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the name of the traced program"
      .}: Option[string]
     replayInteractive* {.
       name: "interactive",
       abbr: "i",
       desc: "explicit flag for interactively choosing a trace"
      .}: Option[bool]
    of run:
      runTracePathOrId* {.
        argument
        desc: "If not a valid trace ID, interpreted as a path to a trace, if not a valid path, interpreted as a program to run"
      .} : string

      runArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Arguments to forward to trace run command"
      .} : seq[string]
    of remote:
      remoteArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Trace sharing utilities"
      .}: seq[string]
    of upload:
      # same args as replay
      uploadTraceId* {.
        name: "id",
        desc: "a trace id"
      .}: Option[int]
      uploadTraceFolder* {.
        name: "trace-folder",
        abbr: "t",
        desc: "the trace output folder"
      .}: Option[string]
      uploadLastTraceMatchingPattern* {.
        argument,
        desc: "a string matching the name of the traced program"
      .}: Option[string]
      uploadInteractive* {.
        name: "interactive",
        abbr: "i",
        desc: "explicit flag for interactively choosing a trace"
      .}: Option[bool]
      uploadOrg* {.
        name: "org",
        desc: "organization to upload to"
      .}: Option[string]
    of download:
      traceDownloadUrl* {.
        argument,
        desc: "an url for an uploaded trace"
      .}: string
      # for now not needed: we directly import it and delete the zip as a temp artifact currently
      # traceDownloadOutput* {.
      #   name: "output",
      #   desc: "output path for the archive. if not passed: storing to  an autogenerated path"
      # .}: Option[string]
    of login:
      loginDefaultOrg* {.
        name: "default-org",
        desc: "set a default organization for uploads",
      .}: Option[string]
    of `set-default-org`:
      setDefaultOrgName* {.
        argument,
        desc: "the name of an organization to be updated as default"
      .}: string
    # of cmdDelete:
    #   traceId* {.
    #     name: "trace-id"
    #     desc: "trace trace unique id"
    #   .}: int
    #   controlId* {.
    #     name: "control-id",
    #     desc: "the trace control id to delete the online trace"
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
    of `index-diff`:
      indexDiffTracePath* {.
        argument
        desc: "Path to a trace with diffs: for now indexing only a single trace"
      .}: string
    of edit:
      editPath* {.
        argument
        desc: "Path to a directory or file to open for editing"
      .}: string

    # of `import`:
    #   importTraceZipPath* {.
    #     argument
    #     desc: "Trace zip file to import"
    #   .} : string
    #   importOutputPath* {.
    #     argument
    #     defaultValue: ""
    #     desc: "Output folder for the import command"
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
    #     desc: "Output folder for the summary command. If empty "
    #   .} : string
    # of `report-bug`:
    #   title* {.
    #     name: "title",
    #     defaultValue: "",
    #     desc: "Title for the bug report message"
    #   .} : string
    #   description* {.
    #     name: "description",
    #     defaultValue: "",
    #     desc: "Description for the bug report message"
    #   .} : string
    #   pid* {.
    #     argument,
    #     defaultValue: "last",
    #     desc: "PID number for the process"
    #   .} : string
    #   confirmSend* {.
    #     name: "confirm-send",
    #     defaultValue: true,
    #     desc: "Warning message for sensative data"
    #   .} : bool
    of electron:
      electronAppArgs* {.
        restOfArgs
        defaultValue: @[]
        desc: "Arguments for electron",
        longDesc: "a wrapper to be able to call directly the electron in our distribution"
      .} : seq[string]
    of `trace-metadata`:
      traceMetadataIdArg* {.
        name: "id",
        desc: "id of a trace"
      .} : Option[int]
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
        desc: "program pattern to find a trace with"
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
        desc: "add a folder to recent folders"
      .}: Option[string]
      traceMetadataRecentLimit* {.
        name: "limit",
        desc: "recent traces/folders limit",
        defaultValue: 4,
      .}: int
      traceMetadataTest* {.
        name: "test",
        defaultValue: false,
      .}: bool
    of start_backend:
      backendKind* {.
        argument
        desc: "This is the backend kind - either 'db' or 'rr'"
      .}: string
      isStdio* {.
        name: "stdio",
        defaultValue: false,
      .}: bool
      socketPath* {.
        name: "socket-path",
      .}: Option[string]

proc customValidateConfig*(conf: CodetracerConf) =
  case conf.cmd:
    of StartupCommand.replay, StartupCommand.console, StartupCommand.upload:
      let r = conf.cmd == StartupCommand.replay
      discard r
      let lastTraceMatchingPattern = case conf.cmd:
        of StartupCommand.replay:
          conf.lastTraceMatchingPattern
        of StartupCommand.console:
          conf.consoleLastTraceMatchingPattern
        else: # possible only StartupCommand.upload:
          conf.uploadLastTraceMatchingPattern


      let (traceId, traceFolder, interactive) =
        case conf.cmd:
        of StartupCommand.replay:
          (conf.replayTraceId,
           conf.replayTraceFolder,
           conf.replayInteractive)
        of StartupCommand.console:
          (conf.consoleTraceId,
           conf.consoleTraceFolder,
           conf.consoleInteractive)
        else: # possible only StartupCommand.upload:
          (conf.uploadTraceId,
           conf.uploadTraceFolder,
           conf.uploadInteractive)

      let isSetPattern = lastTraceMatchingPattern.isSome
      let isSetTraceId = traceId.isSome
      let isSetTraceFolder = traceFolder.isSome
      let isSetInteractive = interactive.isSome
      let setArgsCount = isSetPattern.int + isSetTraceId.int +
        isSetTraceFolder.int + isSetInteractive.int
      if setArgsCount > 1:
        errorMessage "configuration error: expected no more than one arg to command to be passed"
        echo "Try `ct --help` for more information"
        quit(1)
      if not isSetPattern and not isSetTraceId and not isSetTraceFolder:
        replayInteractive = true
      elif isSetInteractive:
        replayInteractive = interactive.get
      else:
        replayInteractive = false
    else:
      discard
