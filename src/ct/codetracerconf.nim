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
    install,
    upload,
    download,
    cmdDelete,
    build,
    record,
    console,
    host,
    `import`,
    arb,

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
        desc: "Output path"
      .} : string
    of StartupCommand.record:
      recordLang* {.
        name: "lang"
        defaultValue: ""
        desc: "Language of the recording. Supported languages: c, cpp, rust, ruby, python, lua, nim ???"
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
        desc: "Record a diff related to this trace and produce a multitrace"
      .}: string
      
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
    of download:
      traceDownloadKey* {.
        argument,
        desc: "the trace registry unique id: <program-name>//<downloadId>//<password> e.g. noir//1234//asd"
      .}: string
    of cmdDelete:
      traceId* {.
        name: "trace-id"
        desc: "trace trace unique id"
      .}: int
      controlId* {.
        name: "control-id",
        desc: "the trace control id to delete the online trace"
      .}: string
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
      electronArgs* {.
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
      traceMetadataRecentLimit* {.
        name: "limit",
        desc: "recent traces limit",
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
