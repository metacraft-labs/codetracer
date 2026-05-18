# Raw string concatenation here because there is no path concatenation on the JS side
let
  CT_SOCKET_PATH* = langstring(codetracerTmpPath & "/ct_socket")
  CT_CLIENT_SOCKET_PATH* = langstring(codetracerTmpPath & "/ct_client_socket")
  CT_DAP_SOCKET_PATH_BASE* = langstring(codetracerTmpPath & "/ct_dap_socket")
  CT_IPC_FILE_PATH* = langstring(codetracerTmpPath & "/ct_ipc")
  CT_PLUGIN_SOCKET_PATH* = langstring(codetracerTmpPath & "/codetracer_plugin_socket")
  CT_PYTHON_LOG_PATH_BASE* = langstring(codetracerTmpPath & "/log")

type
  RestartProcessArg* = object
    breakpoints*: BreakpointSetup
    resetLastLocation*: bool

  BugReportArg* = object
    title*: langstring
    description*: langstring

  UploadTraceArg* = object
    trace*: Trace
    programName*: langstring

  UploadedTraceData* = object
    downloadKey*: langstring
    controlId*: langstring
    expireTime*: langstring

  UploadProgress* = object
    # M-REC-2: ``id`` is the recording_id (UUIDv7 langstring).  The
    # rename to ``recordingId`` is M-REC-3 scope.
    id*: langstring
    progress*: int
    msg*: langstring

  DeleteTraceArg* = object
    # M-REC-2: ``traceId`` is the local recording_id (UUIDv7).
    traceId*: langstring
    controlId*: langstring

  SocketAddressInfo* = object
    host*: langstring
    port*: int
    parameters*: langstring

  LayoutMode* = enum ## Layout mode for component and project objects
    DebugMode,
    EditMode,
    QuickEditMode,
    InteractiveEditMode,
    CalltraceLayoutMode

  EditorView* = enum
    ViewSource,
    ViewTargetSource,
    ViewInstructions,
    ViewAst,
    ViewCfg,
    ViewMacroExpansion,
    ViewCalltrace,
    ViewNoSource,
    ViewLowLevelCode,
    ViewEventContent

  Project* = object
    date*: DateTime
    folders*: seq[langstring]
    name*: langstring
    lang*: Lang
    mode*: LayoutMode
    saveID*: int
    # M-REC-2: ``traceID`` is the recording_id (UUIDv7 langstring).
    traceID*: langstring

  SaveFile* = object
    path*: langstring
    line*: int

  Save* = object
    project*: Project
    files*: seq[SaveFile]
    fileMap*: TableLike[langstring, int]
    id*: int
