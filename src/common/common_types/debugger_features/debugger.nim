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
    # M-REC-2: UUIDv7 recording-id string (wire-format DAP/MCP rename
    # is M-REC-5; for now we only flip the type to match Trace.recordingId).
    id*: langstring
    progress*: int
    msg*: langstring

  DeleteTraceArg* = object
    # M-REC-8: UUIDv7 ``recording_id`` string.  Field renamed in
    # M-REC-8 to align the JS IPC payload with the sharing-server wire
    # format ("recordingId" alongside "controlId" / "downloadKey").
    # ``controlId`` is a server-issued access token for the uploaded
    # copy and keeps its original name and semantics.
    recordingId*: langstring
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
    # M-REC-3: dormant field.  Pre-M-REC-2 this was an ``int`` named
    # ``traceID``; flipped to ``string`` and renamed for the
    # Recording-Identifier-Migration semantic cleanup.  Nothing in the
    # current codebase sets or reads it; the rename keeps the type
    # surface consistent with sibling structs (``Trace.recordingId`` /
    # ``StartOptions.recordingID``) so that any future wire-format
    # serialisation does not have to chase a stale name.
    recordingID*: langstring

  SaveFile* = object
    path*: langstring
    line*: int

  Save* = object
    project*: Project
    files*: seq[SaveFile]
    fileMap*: TableLike[langstring, int]
    id*: int
