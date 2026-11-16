## ct's command line as a clispec description (CS-M10, Clispec Library
## campaign).  Included by `codetracerconf.nim`, which fills `CodetracerConf`
## from what it parses (`toCodetracerConf`).
##
## Written from the confutils pragmas `CodetracerConf` carried before the
## move, one declaration per field: `{.desc.}`/`{.longDesc.}` are `help` /
## `longHelp`, `{.name.}` is `perSource = [cli = ...]`, `{.abbr.}` is `short`
## plus the alias `--<letter>` (confutils also accepted the letter as a long
## option), `{.defaultValue.}` is `default`, `{.argument.}` is `pos`,
## `{.restOfArgs.}` is `rest = true`, the enum subcommands are nested
## `subcmd`s in enum order, and `env` is the name confutils read the field
## from (`<app path>_<NAME>`; the prefix is added by `ctEnvSources`).
## `noCommand` is the `call:` and also a hidden subcommand, so the word keeps
## working; the `help` subcommand is `shadowedByWord`.
##
## The header keeps the parsing of nim-confutils' `codetracer` branch
## (172981d), which ct keeps (CS-M10's decision of 2026-11-16, option (a)):
## names compared as `cmpIgnoreStyle` compares them, except one-letter ones
## (`exactOneLetterFlags`: `-T` is not `-t`), `-o=v`, `--x:v`, `--x= v`,
## `--help=<anything>`, `h` in a cluster asks for help, a rejected value
## before a help request is reported, lenient switch values, the `help` and
## `version` words, and a lone `-` or `--` is an unknown option
## (`loneDashesAreFlags`; ct prints it as `Unrecognized option ''`).

cliConfiguration(CtCli, "ct", exported = true):
  flagMatching ignoreStyle
  commandMatching ignoreStyle
  parsing shortEquals, helpWithAnyValue, helpInCluster,
    valueErrorsBeforeHelp, lenientSwitchValues, colonValues,
    equalsTakesNext, helpWord, versionWord, loneDashesAreFlags,
    exactOneLetterFlags
  flag cwd is Option[string], help = "Working directory for CodeTracer " & "(useful when launched via macOS " & "'open' which starts with cwd=/)", env = ["CWD"]
  flag envFiles is seq[string], perSource = [cli = "env-file"], help = "Environment file(s) to load " & "(newline-separated KEY=VALUE " & "format). Can be specified multiple " & "times; later files override " & "earlier ones.", env = ["ENV_FILE"]
  flag env0Files is seq[string], perSource = [cli = "env0-file"], help = "Environment file(s) to load " & "(null-separated KEY=VALUE format " & "from 'env -0'). Can be specified " & "multiple times; later files " & "override earlier ones.", env = ["ENV0_FILE"]
  flag tmpEnvFiles is seq[string], perSource = [cli = "tmp-env-file"], help = "Temporary environment file(s) " & "to load (newline-separated " & "KEY=VALUE format). Files are " & "deleted after loading.", env = ["TMP_ENV_FILE"]
  flag tmpEnv0Files is seq[string], perSource = [cli = "tmp-env0-file"], help = "Temporary environment file(s) " & "to load (null-separated KEY=VALUE " & "format from 'env -0'). Files are " & "deleted after loading.", env = ["TMP_ENV0_FILE"]
  flag inspect is Option[string], help = "Node.js inspector port " & "(injected by Playwright)", env = ["INSPECT"]
  flag remoteDebuggingPort is Option[string], perSource = [cli = "remote-debugging-port"], help = "Chrome remote debugging port " & "(injected by Playwright)", env = ["REMOTE_DEBUGGING_PORT"]
  boolFlag remoteDebuggingPipe is bool, perSource = [cli = "remote-debugging-pipe"], default = false, help = "Chrome remote debugging pipe " & "(injected by Playwright for testing)", env = ["REMOTE_DEBUGGING_PIPE"]
  boolFlag newTab is bool, perSource = [cli = "new-tab"], default = false, help = "Open trace as a new tab " & "in the existing window " & "(overrides config)", env = ["NEW_TAB"]
  boolFlag newWindow is bool, perSource = [cli = "new-window"], default = false, help = "Open trace in a new " & "Electron window " & "(overrides config)", env = ["NEW_WINDOW"]
  call:
    discard
  subcmd "noCommand", visibility = hidden:
    discard
  subcmd "replay":
    flag replayRecordingId is Option[string], perSource = [cli = "id"], help = "a recording id (UUIDv7) — accepts 8+ char short prefix", env = ["ID"]
    flag replayTraceFolder is Option[string], perSource = [cli = "trace-folder"], short = 't', alias = "--t", help = "the trace output folder " & "or a multitrace archive", env = ["TRACE_FOLDER"]
    pos lastTraceMatchingPattern is Option[string], required = false, help = "a string matching the " & "name of the traced program", env = ["LASTTRACEMATCHINGPATTERN"]
    flag replayInteractive is Option[bool], optionalValue = some(true), perSource = [cli = "interactive"], short = 'i', alias = "--i", help = "explicit flag for " & "interactively choosing " & "a trace", env = ["INTERACTIVE"]
    flag replayThreadSyncOrder is Option[string], perSource = [cli = "thread-sync-order"], help = "Thread synchronization order the replay enforces on a " & "Windows native recording: 'total' or 'per-object' " & "(env CT_THREAD_SYNC_ORDER; the flag wins). " & "Unset: the replay backend's default", env = ["THREAD_SYNC_ORDER"]
    flag replayOsSimulation is Option[string], perSource = [cli = "os-simulation"], help = "Replay mode for a native recording: 'weak-userspace', " & "'strong-userspace' or 'strong-kernel' " & "(env CT_OS_SIMULATION; the flag wins). " & "Unset: the replay backend's default", env = ["OS_SIMULATION"]
    flag replayFollowRequestSpans is Option[string], perSource = [cli = "follow-request-spans"], help = "Follow requests in a growing container: '1' or '0' " & "(env CT_FOLLOW_REQUEST_SPANS; the flag wins). Default off", env = ["FOLLOW_REQUEST_SPANS"]
  subcmd "run":
    pos runTracePathOrId is string, help = "If not a valid trace ID, " & "interpreted as a path to a " & "trace, if not a valid path, " & "interpreted as a program " & "to run", env = ["RUNTRACEPATHORID"]
    pos runArgs is seq[string], rest = true, required = false, help = "Arguments to forward " & "to trace run command", env = ["RUNARGS"]
  subcmd "remote":
    pos remoteArgs is seq[string], rest = true, required = false, help = "Trace sharing utilities", env = ["REMOTEARGS"]
  subcmd "install":
    boolFlag installCtOnPath is bool, perSource = [cli = "path"], short = 'p', alias = "--p", default = true, help = "Add ct to PATH " & "(pass --no-path to skip)", env = ["PATH"]
    boolFlag installCtDesktopFile is bool, perSource = [cli = "desktop"], short = 'd', alias = "--d", default = true, help = "Install .desktop file " & "(pass --no-desktop to skip, " & "Linux only)", env = ["DESKTOP"]
    boolFlag installBpf is bool, perSource = [cli = "bpf"], default = true, help = "Set up BPF monitoring " & "(--no-bpf to skip)", env = ["BPF"]
    boolFlag installAgentHarbor is bool, perSource = [cli = "agent-harbor"], default = true, help = "Install Agent Harbor " & "(pass --no-agent-harbor to skip)", env = ["AGENT_HARBOR"]
    boolFlag installJson is bool, perSource = [cli = "json"], default = false, help = "Output newline-delimited " & "JSON progress events", env = ["JSON"]
  subcmd "upload":
    flag uploadRecordingId is Option[string], perSource = [cli = "id"], help = "a recording id (UUIDv7) — accepts 8+ char short prefix", env = ["ID"]
    flag uploadTraceFolder is Option[string], perSource = [cli = "trace-folder"], short = 't', alias = "--t", help = "the trace output folder", env = ["TRACE_FOLDER"]
    pos uploadLastTraceMatchingPattern is Option[string], required = false, help = "a string matching the " & "name of the traced program", env = ["UPLOADLASTTRACEMATCHINGPATTERN"]
    flag uploadInteractive is Option[bool], optionalValue = some(true), perSource = [cli = "interactive"], short = 'i', alias = "--i", help = "explicit flag for " & "interactively choosing " & "a trace", env = ["INTERACTIVE"]
    flag uploadOrg is Option[string], perSource = [cli = "org"], help = "organization to upload to", env = ["ORG"]
    flag uploadToken is Option[string], perSource = [cli = "token"], help = "bearer token " & "(uses stored token if omitted)", env = ["TOKEN"]
    flag uploadBaseUrl is Option[string], perSource = [cli = "base-url"], help = "override the " & "remote server URL", env = ["BASE_URL"]
    boolFlag uploadNoPortable is bool, perSource = [cli = "no-portable"], help = "skip adding portable " & "binaries/symbols to MCR traces " & "before upload", env = ["NO_PORTABLE"]
    boolFlag uploadNoSplitUpload is bool, perSource = [cli = "no-split-upload"], help = "skip pre-split slice detection " & "and force full trace upload " & "even when slices are present", env = ["NO_SPLIT_UPLOAD"]
    flag uploadOmniscientDbMode is OmniscientDbMode, perSource = [cli = "omniscient-db"], help = "how the server prepares the omniscient-DB " & "artefacts for the uploaded slice " & "(off | on | lazy | pre-prepared; default off). " & "See spec §6.8.6 / M31.", env = ["OMNISCIENT_DB"]
    flag uploadArtifactPath is Option[string], perSource = [cli = "artifact"], help = "path of a local artifact to share " & "(a recording folder, or a review dataset " & "directory produced by `ct review collect`)", env = ["ARTIFACT"]
    flag uploadArtifactKind is Option[string], perSource = [cli = "kind"], help = "what --artifact holds " & "(recording | review-dataset); " & "only needed when it cannot be " & "recognised from the path itself", env = ["KIND"]
    boolFlag uploadEncrypt is bool, perSource = [cli = "encrypt"], help = "encrypt the payload on this computer before uploading. " & "The password is never sent to the service, and a lost password " & "cannot be recovered — not by you and not by CodeTracer", env = ["ENCRYPT"]
    flag uploadPasswordFile is Option[string], perSource = [cli = "password-file"], help = "read the encryption password from this file instead of " & "prompting. Passing a password as a command-line argument is not " & "supported: it would be visible to every process on the machine", env = ["PASSWORD_FILE"]
    boolFlag uploadPasswordStdin is bool, perSource = [cli = "password-stdin"], help = "read the encryption password from standard input " & "(for scripts and CI). Mutually exclusive with --password-file", env = ["PASSWORD_STDIN"]
    flag uploadVisibility is Option[string], perSource = [cli = "visibility"], help = "who may read the stored artifact: 'tenant' (members of the " & "owning organisation, the default) or 'tenant-or-invite' (those, " & "plus anyone holding an invite link)", env = ["VISIBILITY"]
  subcmd "download":
    pos traceDownloadUrl is string, help = "an url for an uploaded trace", env = ["TRACEDOWNLOADURL"]
    flag downloadToken is Option[string], perSource = [cli = "token"], help = "bearer token " & "(uses stored token if omitted)", env = ["TOKEN"]
    flag downloadBaseUrl is Option[string], perSource = [cli = "base-url"], help = "override the " & "remote server URL", env = ["BASE_URL"]
    flag downloadPasswordFile is Option[string], perSource = [cli = "password-file"], help = "read the decryption password from this file, " & "when the artifact turns out to be encrypted", env = ["PASSWORD_FILE"]
    boolFlag downloadPasswordStdin is bool, perSource = [cli = "password-stdin"], help = "read the decryption password from standard input " & "(for scripts and CI). Mutually exclusive with --password-file", env = ["PASSWORD_STDIN"]
  subcmd "login":
    flag loginDefaultOrg is Option[string], perSource = [cli = "default-org"], help = "set a default organization " & "for uploads", env = ["DEFAULT_ORG"]
    flag loginBaseUrl is Option[string], perSource = [cli = "base-url"], help = "override the " & "remote server URL", env = ["BASE_URL"]
  subcmd "set-default-org":
    pos setDefaultOrgName is string, help = "the name of an " & "organization to be " & "updated as default", env = ["SETDEFAULTORGNAME"]
  subcmd "get-default-org":
    discard
  subcmd "activate":
    flag activateToken is Option[string], perSource = [cli = "token"], help = "bearer token " & "(uses stored token if omitted)", env = ["TOKEN"]
    flag activateBaseUrl is Option[string], perSource = [cli = "base-url"], help = "override the " & "remote server URL", env = ["BASE_URL"]
  subcmd "check-license":
    flag checkLicenseToken is Option[string], perSource = [cli = "token"], help = "bearer token " & "(uses stored token if omitted)", env = ["TOKEN"]
    flag checkLicenseBaseUrl is Option[string], perSource = [cli = "base-url"], help = "override the " & "remote server URL", env = ["BASE_URL"]
  subcmd "build":
    pos buildProgramPath is string, help = "path to program source code", env = ["BUILDPROGRAMPATH"]
    pos buildOutputPath is string, required = false, help = "Output path", env = ["BUILDOUTPUTPATH"]
  subcmd "record":
    flag recordLang is string, perSource = [cli = "lang"], help = "Language of the recording " & "(auto-detected from the " & "program path).", longHelp = "Leave blank to auto-detect. " & "Python scripts use the db " & "backend and run with the same " & "interpreter you would get " & "from `python`, honoring " & "CODETRACER_PYTHON_INTERPRETER" & ", PYTHON_EXECUTABLE, " & "PYTHONEXECUTABLE, PYTHON, " & "or PATH. Ensure that " & "interpreter has the " & "codetracer_python_recorder " & "package installed.", env = ["LANG"]
    flag recordOutputFolder is string, perSource = [cli = "output-folder"], short = 'o', alias = "--o", default = ".", help = "Output folder for " & "the recording", env = ["OUTPUT_FOLDER"]
    flag recordBackend is string, perSource = [cli = "backend"], help = "Native recording backend. " & "MCR is the default on every " & "host, and `mcr` also pins it. " & "Linux additionally accepts " & "`rr`; Windows accepts `ttd`. " & "A value this host cannot " & "honour is refused, never " & "silently downgraded. Not a " & "language selector: see --lang.", env = ["BACKEND"]
    flag recordExportFile is string, perSource = [cli = "export"], short = 'e', alias = "--e", help = "Export zip file for " & "the recording", env = ["EXPORT"]
    flag recordStylusTrace is string, perSource = [cli = "stylus-trace"], short = 't', alias = "--t", help = "Path to a stylus emv " & "trace json file", env = ["STYLUS_TRACE"]
    flag recordAddress is string, perSource = [cli = "address"], short = 'a', alias = "--a", help = "Address when we are " & "recording in ci " & "mode/environment", env = ["ADDRESS"]
    flag recordSocket is string, perSource = [cli = "socket"], help = "Path to socket for sending " & "the trace events metadata " & "when in ci mode/environment", env = ["SOCKET"]
    flag recordWithDiff is string, perSource = [cli = "with-diff"], help = "Record a diff related to " & "this trace and produce a " & "multitrace. Arg can be " & "`last-commit`, path to a " & "diff file (must be from the " & "current repo!) or a valid " & "`git diff <arg>` arg", env = ["WITH_DIFF"]
    flag recordStoreTraceFolderForPid is int, perSource = [cli = "store-trace-folder-for-pid"], default = 0, help = "sets a pid, if we should " & "store the resulting trace " & "folder in a special tmp " & "file, grouping info for a " & "certain originating " & "codetracer pid. 0 means " & "'do not store in such a file'", env = ["STORE_TRACE_FOLDER_FOR_PID"]
    boolFlag recordUpload is bool, perSource = [cli = "upload"], help = "upload the trace directly " & "after recording and " & "processing it", env = ["UPLOAD"]
    boolFlag recordUseInterpose is bool, perSource = [cli = "use-interpose"], default = false, help = "Record graphics API calls for " & "visual replay (MCR backend only).", env = ["USE_INTERPOSE"]
    boolFlag recordServer is bool, perSource = [cli = "server"], default = false, help = "Record a long-lived server. The recording stays readable " & "while it runs, so `ct replay -t <folder>` in another terminal " & "shows requests arriving live; stop it with Ctrl-C.", env = ["SERVER"]
    boolFlag recordPortable is bool, perSource = [cli = "portable"], default = false, help = "Make the trace replayable on another machine, or later " & "after its files change: the MCR backend bundles every file " & "the program mapped, their debug symbols and the platform " & "description into the trace, and the rr backend packs the " & "files the trace mapped into it. A backend that cannot do this " & "yet refuses the flag. Also honors CODETRACER_PORTABLE=on|off; " & "--upload implies it, and warns where it is not implemented.", env = ["PORTABLE"]
    pos recordProgram is string, help = "Program to record", env = ["RECORDPROGRAM"]
    pos recordArgs is seq[string], repeated = true, required = false, help = "Arguments for the recorded program", longHelp = "Everything after `--` is passed to the recorded " & "program unchanged, including flags.", env = ["RECORDARGS"]
  subcmd "record-test":
    pos recordTestTestName is string, help = "Test name", env = ["RECORDTESTTESTNAME"]
    pos recordTestPath is string, help = "path to the test section", env = ["RECORDTESTPATH"]
    pos recordTestLine is int, help = "line number for " & "the test section", env = ["RECORDTESTLINE"]
    pos recordTestColumn is int, help = "column number " & "(can be 1 if nothing " & "applicable) for test section", env = ["RECORDTESTCOLUMN"]
    flag recordTestWithDiff is string, perSource = [cli = "with-diff"], help = "Record a diff related to " & "this trace and produce a " & "multitrace. Arg can be " & "`last-commit`, path to a " & "diff file (must be from the " & "current repo!) or a valid " & "`git diff <arg>` arg", env = ["WITH_DIFF"]
    flag recordTestStoreTraceFolderForPid is int, perSource = [cli = "store-trace-folder-for-pid"], default = 0, help = "sets a pid, if we should " & "store the resulting trace " & "folder in a special tmp " & "file, grouping info for a " & "certain originating " & "codetracer pid. 0 means " & "'do not store in such a file'", env = ["STORE_TRACE_FOLDER_FOR_PID"]
  subcmd "console":
    flag consoleRecordingId is Option[string], perSource = [cli = "id"], help = "a recording id (UUIDv7) — accepts 8+ char short prefix", env = ["ID"]
    flag consoleTraceFolder is Option[string], perSource = [cli = "trace-folder"], short = 't', alias = "--t", help = "the trace output folder", env = ["TRACE_FOLDER"]
    pos consoleLastTraceMatchingPattern is Option[string], required = false, help = "a string matching the " & "name of the traced program", env = ["CONSOLELASTTRACEMATCHINGPATTERN"]
    flag consoleInteractive is Option[bool], optionalValue = some(true), perSource = [cli = "interactive"], short = 'i', alias = "--i", help = "explicit flag for " & "interactively choosing a trace", env = ["INTERACTIVE"]
  subcmd "host":
    flag hostPort is Option[int], perSource = [cli = "port"], help = "Port to listen on " & "(default: auto-assign; " & "CODETRACER_HOST_PORT)", env = ["PORT"]
    flag hostBind is string, perSource = [cli = "bind"], help = "Interface to bind " & "(default: 127.0.0.1; " & "CODETRACER_HOST_BIND)", env = ["BIND"]
    flag hostBackendSocketPort is Option[int], perSource = [cli = "backend-socket-port"], help = "Port to listen on " & "for backend socket", env = ["BACKEND_SOCKET_PORT"]
    flag hostFrontendSocketPort is Option[int], perSource = [cli = "frontend-socket"], help = "Port to listen on " & "for frontend socket", env = ["FRONTEND_SOCKET"]
    flag hostFrontendSocketParameters is string, perSource = [cli = "frontend-socket-parameters"], help = "Parameters to forward " & "to frontend socket", env = ["FRONTEND_SOCKET_PARAMETERS"]
    flag hostIdleTimeout is string, perSource = [cli = "idle-timeout"], help = "Host idle timeout " & "(e.g., 30s, 5m, 1h). " & "Default 10m. " & "Use 0/never to disable.", env = ["IDLE_TIMEOUT"]
    flag hostTracePath is string, perSource = [cli = "trace-path"], help = "Path to a .ct file, trace " & "folder, or local trace-storage " & "manifest to auto-import and " & "host. Skips the need for a " & "separate ct import.", env = ["TRACE_PATH"]
    flag hostManifestPath is string, perSource = [cli = "manifest"], help = "Path to a local shared " & "trace-storage or recording " & "manifest to host.", env = ["MANIFEST"]
    flag hostStorageBaseUrl is string, perSource = [cli = "storage-base-url"], help = "Base URL for storage-server " & "manifest object reads. Also " & "honors CODETRACER_STORAGE_BASE_URL.", env = ["STORAGE_BASE_URL"]
    flag hostStorageTenantId is string, perSource = [cli = "storage-tenant-id"], help = "Tenant id for storage-server " & "object reads. Also honors " & "CODETRACER_STORAGE_TENANT_ID.", env = ["STORAGE_TENANT_ID"]
    flag hostStorageToken is string, perSource = [cli = "storage-token"], help = "Replay credential bearer token " & "for storage-server object reads. " & "Also honors " & "CODETRACER_STORAGE_REPLAY_TOKEN.", env = ["STORAGE_TOKEN"]
    flag hostStorageProtocol is string, perSource = [cli = "storage-protocol"], help = "Storage protocol selector " & "(default local-storage). Also " & "honors CODETRACER_STORAGE_PROTOCOL.", env = ["STORAGE_PROTOCOL"]
    pos hostTraceArg is string, required = false, help = "Trace id to run. If not a " & "valid trace id, treats it " & "as a trace folder", env = ["HOSTTRACEARG"]
  subcmd "import":
    pos importTraceZipPath is string, help = "Trace zip file to import", env = ["IMPORTTRACEZIPPATH"]
    pos importOutputPath is string, required = false, help = "Output folder for " & "the import command", env = ["IMPORTOUTPUTPATH"]
  subcmd "arb":
    flag arbitrumRpcUrl is string, perSource = [cli = "arbitrum-rpc-url"], default = "localhost", help = "Arbitrum Node JSON-RPC URL", env = ["ARBITRUM_RPC_URL"]
    call:
      discard
    subcmd "noCommand", visibility = hidden:
      discard
    subcmd "explorer":
      discard
    subcmd "record":
      pos arbRecordTransaction is string, help = "Hex-encoded transaction hash", env = ["ARBRECORDTRANSACTION"]
    subcmd "replay":
      pos arbReplayTransaction is string, help = "Hex-encoded transaction hash", env = ["ARBREPLAYTRANSACTION"]
    subcmd "deploy":
      discard
    subcmd "listRecentTx":
      discard
  subcmd "ci":
    flag ciToken is Option[string], perSource = [cli = "token"], help = "CI API token " & "(uses CODETRACER_TOKEN " & "env var if omitted)", env = ["TOKEN"]
    flag ciBaseUrl is Option[string], perSource = [cli = "base-url"], help = "Override the " & "remote server URL", env = ["BASE_URL"]
    call:
      discard
    subcmd "noCommand", visibility = hidden:
      discard
    subcmd "start":
      flag ciStartRepo is Option[string], perSource = [cli = "repo"], help = "Repository URL " & "(auto-detected from " & "git remote if omitted)", env = ["REPO"]
      flag ciStartCommit is Option[string], perSource = [cli = "commit"], help = "Git commit SHA " & "(auto-detected from " & "HEAD if omitted)", env = ["COMMIT"]
      flag ciStartBranch is Option[string], perSource = [cli = "branch"], help = "Git branch name " & "(auto-detected if omitted)", env = ["BRANCH"]
      flag ciStartBaseCommit is Option[string], perSource = [cli = "base-commit"], help = "Base commit SHA " & "for diffing", env = ["BASE_COMMIT"]
      flag ciStartLabel is Option[string], perSource = [cli = "label"], help = "Human-readable label " & "for the run", env = ["LABEL"]
      boolFlag ciStartMonitorProcesses is bool, perSource = [cli = "monitor-processes"], default = false, help = "Enable BPF process " & "tree monitoring", env = ["MONITOR_PROCESSES"]
    subcmd "attach":
      pos ciAttachRunId is string, help = "Run ID to attach to", env = ["CIATTACHRUNID"]
    subcmd "exec":
      boolFlag ciExecMonitorProcesses is bool, perSource = [cli = "monitor-processes"], default = false, help = "Enable BPF-based " & "process tree monitoring", env = ["MONITOR_PROCESSES"]
      boolFlag ciExecRecord is bool, perSource = [cli = "record"], default = false, help = "Wrap command in " & "ct record and " & "auto-upload trace", env = ["RECORD"]
      pos ciExecProgram is string, help = "Command to execute", env = ["CIEXECPROGRAM"]
      pos ciExecArgs is seq[string], repeated = true, required = false, help = "Arguments for " & "the command", env = ["CIEXECARGS"]
    subcmd "finish":
      flag ciFinishStatus is Option[string], perSource = [cli = "status"], help = "Override run status " & "(passed/failed/error)", env = ["STATUS"]
    subcmd "run":
      flag ciRunRepo is Option[string], perSource = [cli = "repo"], help = "Repository URL " & "(auto-detected from " & "git remote if omitted)", env = ["REPO"]
      flag ciRunCommit is Option[string], perSource = [cli = "commit"], help = "Git commit SHA " & "(auto-detected from " & "HEAD if omitted)", env = ["COMMIT"]
      flag ciRunBranch is Option[string], perSource = [cli = "branch"], help = "Git branch name " & "(auto-detected if omitted)", env = ["BRANCH"]
      flag ciRunBaseCommit is Option[string], perSource = [cli = "base-commit"], help = "Base commit SHA " & "for diffing", env = ["BASE_COMMIT"]
      flag ciRunLabel is Option[string], perSource = [cli = "label"], help = "Human-readable label " & "for the run", env = ["LABEL"]
      boolFlag ciRunMonitorProcesses is bool, perSource = [cli = "monitor-processes"], default = false, help = "Enable BPF process " & "tree monitoring", env = ["MONITOR_PROCESSES"]
      boolFlag ciRunRecord is bool, perSource = [cli = "record"], default = false, help = "Wrap command in " & "ct record and " & "auto-upload trace", env = ["RECORD"]
      pos ciRunProgram is string, help = "Command to execute", env = ["CIRUNPROGRAM"]
      pos ciRunArgs is seq[string], repeated = true, required = false, help = "Arguments for " & "the command", env = ["CIRUNARGS"]
    subcmd "log":
      pos ciLogMessage is string, help = "Log message to append", env = ["CILOGMESSAGE"]
    subcmd "status":
      discard
    subcmd "cancel":
      discard
  subcmd "index-diff":
    pos indexDiffTracePath is string, help = "Path to a trace with " & "diffs: for now indexing " & "only a single trace", env = ["INDEXDIFFTRACEPATH"]
  subcmd "edit":
    pos editPath is string, help = "Path to a directory or " & "file to open for editing", env = ["EDITPATH"]
  subcmd "review":
    pos reviewPath is string, required = false, help = "Path to a review dataset: " & "a review.json file, or a " & "directory produced by " & "`ct review collect`", env = ["REVIEWPATH"]
  subcmd "list":
    flag listFormat is string, perSource = [cli = "format"], default = "text", help = "text or json", env = ["FORMAT"]
    pos target is string, default = "local", help = "target for list: local or remote", env = ["TARGET"]
  subcmd "print":
    pos printPath is string, help = "Path to trace directory, " & ".ct file, or JSONL manifest", env = ["PRINTPATH"]
    flag printFilter is Option[string], perSource = [cli = "filter"], short = 'f', alias = "--f", help = "Filter events " & "(e.g. 'calls', 'steps', " & "'http', 'errors')", env = ["FILTER"]
    flag printFunction is Option[string], perSource = [cli = "function"], help = "Show only events for " & "this function name", env = ["FUNCTION"]
    flag printLimit is Option[int], perSource = [cli = "limit"], short = 'n', alias = "--n", help = "Maximum number of events " & "to print", env = ["LIMIT"]
    flag printFormat is Option[string], perSource = [cli = "format"], help = "Output format: " & "text (default), json, csv", env = ["FORMAT"]
    boolFlag printVerify is bool, perSource = [cli = "verify"], default = false, help = "Verify recording quality " & "(exit 0 if valid, 1 if not). " & "Checks: trace files exist, " & "events present, " & "HTTP requests found.", env = ["VERIFY"]
    boolFlag printFollow is bool, perSource = [cli = "follow"], short = 'F', alias = "--F", default = false, help = "Follow mode: watch for " & "new events (like tail -f)", env = ["FOLLOW"]
  subcmd "help", shadowedByWord = true:
    discard
  subcmd "electron":
    pos electronAppArgs is seq[string], rest = true, required = false, help = "Arguments for electron", longHelp = "a wrapper to be able " & "to call directly the " & "electron in our distribution", env = ["ELECTRONAPPARGS"]
  subcmd "trace-metadata":
    flag recordingMetadataIdArg is Option[string], perSource = [cli = "id"], help = "a recording id (UUIDv7) — accepts 8+ char short prefix", env = ["ID"]
    flag traceMetadataPathArg is Option[string], perSource = [cli = "path"], help = "path for a trace", env = ["PATH"]
    flag traceMetadataRecordPidArg is Option[int], perSource = [cli = "record-pid"], short = 'r', alias = "--r", help = "record pid for a trace", env = ["RECORD_PID"]
    flag traceMetadataProgramArg is Option[string], perSource = [cli = "program"], help = "program pattern to " & "find a trace with", env = ["PROGRAM"]
    boolFlag traceMetadataRecent is bool, perSource = [cli = "recent"], default = false, help = "return recent traces", env = ["RECENT"]
    boolFlag traceMetadataRecentFolders is bool, perSource = [cli = "recent-folders"], default = false, help = "return recent folders", env = ["RECENT_FOLDERS"]
    flag traceMetadataAddRecentFolder is Option[string], perSource = [cli = "add-recent-folder"], help = "add a folder to " & "recent folders", env = ["ADD_RECENT_FOLDER"]
    flag traceMetadataRecentLimit is int, perSource = [cli = "limit"], default = 4, help = "recent traces/folders " & "limit", env = ["LIMIT"]
    flag traceMetadataImportCt is Option[string], perSource = [cli = "import-ct"], help = "register the .ct at this path as a Nim trace, laid out in a " & "folder of its own (the desktop's Trace Macro route); prints its row", env = ["IMPORT_CT"]
    flag traceMetadataImportSource is Option[string], perSource = [cli = "import-source"], help = "with --import-ct: the Nim source the trace was made from, " & "whose Nim files are copied beside it", env = ["IMPORT_SOURCE"]
    boolFlag traceMetadataTest is bool, perSource = [cli = "test"], default = false, env = ["TEST"]
  subcmd "start_backend":
    pos backendKind is string, help = "This is the backend kind" & " - either 'db' or 'rr'", env = ["BACKENDKIND"]
    boolFlag isStdio is bool, perSource = [cli = "stdio"], default = false, env = ["STDIO"]
    flag socketPath is Option[string], perSource = [cli = "socket-path"], env = ["SOCKET_PATH"]
  subcmd "trace":
    call:
      discard
    subcmd "noCommand", visibility = hidden:
      discard
    subcmd "extract-gfx":
      flag traceExtractGfxOutputDir is string, perSource = [cli = "output-dir"], short = 'o', alias = "--o", required = true, help = "Directory to extract the " & "graphics stream into. Required.", env = ["OUTPUT_DIR"]
      pos traceExtractGfxPath is string, help = "Path to the .ct trace " & "container to extract.", env = ["TRACEEXTRACTGFXPATH"]
    subcmd "export":
      boolFlag traceExportPortable is bool, perSource = [cli = "portable"], default = false, help = "Produce a portable export " & "with embedded binaries and " & "debug symbols.", env = ["PORTABLE"]
      flag traceExportOutput is string, perSource = [cli = "output"], short = 'o', alias = "--o", required = true, help = "Output path for the exported " & "trace (required).", env = ["OUTPUT"]
      pos traceExportPath is string, help = "Path to the source trace to " & "export.", env = ["TRACEEXPORTPATH"]
    subcmd "omniscient-prep":
      flag traceOmniscientPrepMode is string, perSource = [cli = "mode"], default = "on", help = "OmniscientDB preparation mode.", env = ["MODE"]
      pos traceOmniscientPrepPath is string, help = "Path to the trace or trace folder.", env = ["TRACEOMNISCIENTPREPPATH"]
  subcmd "gfx-replay":
    flag gfxReplayGfxStream is string, perSource = [cli = "gfx-stream"], required = true, help = "Path to the extracted " & "graphics-stream directory " & "(required).", env = ["GFX_STREAM"]
    boolFlag gfxReplayHttp is bool, perSource = [cli = "http"], default = false, help = "Start the player as an HTTP " & "server (used by the GUI).", env = ["HTTP"]
    flag gfxReplayPort is Option[int], perSource = [cli = "port"], help = "Port for the HTTP player " & "(only meaningful with --http).", env = ["PORT"]
    flag gfxReplayBackend is string, perSource = [cli = "backend"], help = "Rendering backend selector " & "(e.g. 'software' or 'hardware').", env = ["BACKEND"]
  subcmd "doctor":
    pos doctorLanguage is string, required = false, help = "Recorder to probe " & "(python, ruby, javascript, ...), or `terminal` for this " & "terminal's capability report and glyph test card. " & "Omit to probe every known recorder.", env = ["DOCTORLANGUAGE"]
  subcmd "ct-describe-commands":
    discard
  subcmd "ct-help":
    discard
  subcmd "ct-complete":
    pos ctCompleteArgs is seq[string], repeated = true, required = false, help = "Partial command line to complete", env = ["CTCOMPLETEARGS"]
  subcmd "ct-completions":
    pos ctCompletionsShell is string, required = false, help = "Target shell (bash, zsh, fish)", env = ["CTCOMPLETIONSSHELL"]
