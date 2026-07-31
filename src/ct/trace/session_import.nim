## Opening a **multi-recording session** (`session.toml`) from `ct`.
##
## A session manifest lists every recording that participates in one
## debugging session — a browser front end, its WASM module, and the
## server it talks to, say — so the replay engine can route DAP requests
## across all of them and compose value-origin chains that cross process
## boundaries.  The format is specified in
## ``codetracer-specs/Trace-Files/Session-Manifest.md`` §5 and in
## ``GUI/Debugging-Features/Value-Origin-Tracking.md`` §14.
##
## ## Why this module shells out instead of parsing TOML
##
## The manifest is parsed by exactly one implementation:
## ``src/db-backend/src/session_manifest.rs``.  It defines the accepted
## grammar, the canonical role vocabulary, the per-session trace limit
## and every diagnostic.  A second, Nim-side reader would inevitably
## drift from it — and the drift would surface as "the GUI opened a
## session the replay engine then refused", which is the worst possible
## place to discover a schema disagreement.
##
## So `ct` delegates: it runs ``replay-server session <manifest>``, the
## read-only validation command M24 added for exactly this purpose, and
## parses its resolved listing.  Consequences:
##
## * any manifest `ct` accepts is one the replay engine has already
##   parsed with the same code it will use at launch time;
## * any manifest `ct` rejects is rejected with the engine's own
##   diagnostic, verbatim;
## * adding a field to the schema needs no change here.
##
## ## What "importing" a session means
##
## Unlike a single recording, a session is **not** copied into
## ``<codetracerTraceDir>/<recording_id>/``: its ``[[trace]]`` entries
## are relative paths that only resolve next to the manifest, and
## duplicating a multi-gigabyte recording set to open it would be a poor
## trade.  Instead the session folder is registered *in place* as one
## row in the recording index whose ``output_folder`` is the manifest's
## directory.
##
## The replay engine then recognises the session on its own: a DAP
## ``launch`` whose ``traceFolder`` contains a ``session.toml`` routes
## through ``dap_server.rs::setup_session``, which opens every
## ``[[trace]]`` and multiplexes them behind one `SessionHandler`.  The
## GUI needs no per-recording plumbing to *open* the session; the
## per-process surface is served by the ``ct/listProcesses`` DAP request.

import
  std / [ os, osproc, strutils, sets ],
  ../../common / [ trace_index, types, paths, lang ],
  trace_container,
  ctfs_sources,
  storage_and_import

type
  SessionTraceEntry* = object
    ## One resolved ``[[trace]]`` entry, as reported by
    ## ``replay-server session``.
    recordingId*: string
    role*: string
    threadPrefix*: string
    ## Absolute (or manifest-relative, already joined) path to the
    ## recording, as resolved by ``SessionManifest::resolved_trace_path``.
    path*: string

  SessionManifestInfo* = object
    ## The manifest as the replay engine sees it.
    manifestPath*: string
    traces*: seq[SessionTraceEntry]

  SessionManifestError* = object of CatchableError
    ## Raised when the manifest is absent, unparseable, or names a
    ## recording that is not on disk.  Carries the replay engine's own
    ## diagnostic whenever the failure came from the manifest parser.

proc findSessionManifest*(path: string): string =
  ## Resolve `path` to a ``session.toml``, or "" when it is not one.
  ##
  ## Accepts both the manifest file itself and a folder containing it,
  ## mirroring the replay engine's ``resolve_session_manifest_path``.
  if path.len == 0:
    return ""
  if fileExists(path) and path.lastPathPart == SESSION_MANIFEST_FILE:
    return path
  if dirExists(path):
    return findSessionManifestInFolder(path)
  ""

proc parseSessionListing*(manifestPath, output: string): SessionManifestInfo =
  ## Parse the listing ``replay-server session`` prints.
  ##
  ## The relevant lines have the shape
  ##
  ## ```
  ##   [0] recording_id=<id> role=<role> prefix=<prefix> path=<path>
  ## ```
  ##
  ## Everything else on the stream (the header line, and the replay
  ## engine's own startup chatter on stderr) is ignored, so this stays
  ## robust against unrelated logging changes.  ``path`` is taken as the
  ## rest of the line because a path may legitimately contain spaces,
  ## while the ids/roles/prefixes before it may not.
  ##
  ## Kept a pure function of its input so it is unit-testable without a
  ## built replay-server binary.
  result = SessionManifestInfo(manifestPath: manifestPath, traces: @[])
  for rawLine in output.splitLines:
    let line = rawLine.strip
    if not line.startsWith("["):
      continue
    let closing = line.find(']')
    if closing < 0:
      continue
    var entry = SessionTraceEntry()
    var rest = line[closing + 1 .. ^1].strip
    var sawRecordingId = false
    # Fields are emitted in a fixed order; `path=` is terminal.
    while rest.len > 0:
      let eq = rest.find('=')
      if eq < 0:
        break
      let key = rest[0 ..< eq]
      rest = rest[eq + 1 .. ^1]
      if key == "path":
        entry.path = rest
        rest = ""
      else:
        let space = rest.find(' ')
        let value = if space < 0: rest else: rest[0 ..< space]
        rest = if space < 0: "" else: rest[space + 1 .. ^1].strip
        case key
        of "recording_id":
          entry.recordingId = value
          sawRecordingId = true
        of "role":
          entry.role = value
        of "prefix":
          entry.threadPrefix = value
        else:
          discard
    if sawRecordingId:
      result.traces.add(entry)

proc loadSessionManifest*(manifestPath: string): SessionManifestInfo =
  ## Validate + resolve `manifestPath` through the replay engine's own
  ## parser (``replay-server session``) and return its trace listing.
  ##
  ## Raises `SessionManifestError` when the binary is unavailable, when
  ## the parser rejects the manifest (its diagnostic is propagated), or
  ## when the manifest resolves to no traces at all.
  if not fileExists(manifestPath):
    raise newException(SessionManifestError,
      "session manifest not found: " & manifestPath)
  if not fileExists(dbBackendExe):
    raise newException(SessionManifestError,
      "cannot read " & manifestPath & ": the replay engine binary is " &
      "missing at " & dbBackendExe & " (it owns the session.toml parser)")

  var output = ""
  var exitCode = 0
  try:
    (output, exitCode) = execCmdEx(
      quoteShellCommand(@[dbBackendExe, "session", manifestPath]))
  except CatchableError as e:
    raise newException(SessionManifestError,
      "failed to run the session-manifest parser (" & dbBackendExe &
      " session " & manifestPath & "): " & e.msg)

  if exitCode != 0:
    raise newException(SessionManifestError,
      "invalid session manifest " & manifestPath & ": " & output.strip)

  result = parseSessionListing(manifestPath, output)
  if result.traces.len == 0:
    raise newException(SessionManifestError,
      "session manifest " & manifestPath & " resolved to no recordings; " &
      "parser output was: " & output.strip)

proc validateSessionRecordings(info: SessionManifestInfo) =
  ## Fail early, and precisely, when a manifest points at a recording
  ## that is not on disk or is not a recognisable recording.
  ##
  ## Without this the failure surfaces much later as an opaque replay
  ## engine launch error, after the GUI window has already opened.
  for entry in info.traces:
    if not dirExists(entry.path) and not fileExists(entry.path):
      raise newException(SessionManifestError,
        "session manifest " & info.manifestPath & " references " &
        entry.path & " (role " & entry.role & ") which does not exist")
    if dirExists(entry.path):
      let shape = detectTraceFolderShape(entry.path, allowSession = false)
      if shape.kind == TraceShapeMissing:
        raise newException(SessionManifestError,
          "session manifest " & info.manifestPath & " references " &
          entry.path & " (role " & entry.role & "): " &
          describeMissingTraceContainer(entry.path))

proc describeSession*(info: SessionManifestInfo): string =
  ## Human-readable one-liner used both as the recording index's
  ## ``program`` field (what the trace list shows for the session) and in
  ## `ct host`'s progress output.
  let roles = block:
    var names: seq[string] = @[]
    for entry in info.traces:
      names.add(if entry.role.len > 0: entry.role else: entry.path.lastPathPart)
    names
  info.manifestPath.parentDir.lastPathPart & " session (" &
    roles.join(", ") & ")"

proc describeSessionMembers*(info: SessionManifestInfo): seq[string] =
  ## One ``<recording_id> (<role>) <path>`` line per ``[[trace]]``.
  ##
  ## Emitted by the open path so an operator can see, at the moment the
  ## session is registered, exactly which recordings it resolved to.
  ## Without this the only visible id is the session's own, and a
  ## manifest that quietly resolved to the wrong member would look
  ## identical to one that resolved correctly.
  for entry in info.traces:
    result.add(entry.recordingId & " (" & entry.role & ") " & entry.path)

type
  SessionProgressReporter* = proc (message: string) {.closure, gcsafe.}
    ## Optional sink for human-readable progress from the session open
    ## path.  Kept a callback rather than a hard-wired ``echo`` so the
    ## module stays usable as a library — a caller embedding it decides
    ## whether, and where, these lines go.

proc importSessionManifest*(manifestPath: string,
                            report: SessionProgressReporter = nil): Trace =
  ## Register the session described by `manifestPath` in the recording
  ## index and return its row.
  ##
  ## The session gets a freshly minted UUIDv7 of its own, distinct from
  ## the per-``[[trace]]`` recording ids: those identify the *members*,
  ## and the routing key the replay engine uses for them comes from the
  ## manifest, not from this index.  The row's ``output_folder`` is the
  ## manifest's directory — see the module docstring for why the session
  ## is registered in place rather than copied.
  let info = loadSessionManifest(manifestPath)
  validateSessionRecordings(info)
  if not report.isNil:
    report("session " & manifestPath & " resolves to " &
      $info.traces.len & " recording(s):")
    for line in describeSessionMembers(info):
      report("  " & line)

  let sessionFolder = manifestPath.parentDir
  let recordingId = trace_index.newID(test = false)

  # Classify the session by its first member, using the very same
  # heuristic single recordings go through, so a session's entry in the
  # trace list is labelled consistently with its members'.
  var lang = LangUnknown
  var sourcePathSet = initHashSet[string]()
  for entry in info.traces:
    let entryFolder = if dirExists(entry.path): entry.path
                      else: entry.path.parentDir
    var meta: CtfsMetaDat
    try:
      meta = readTraceFolderMeta(entryFolder)
    except CatchableError:
      # A member whose metadata cannot be read is not fatal for opening
      # the session: the replay engine reads the recordings themselves.
      # We just lose this member's contribution to the source folders.
      continue
    if lang == LangUnknown:
      lang = detectTraceLang(meta.program, meta.paths, "db")
    for path in meta.paths:
      if path.len > 0 and isAbsolute(path):
        sourcePathSet.incl(path.parentDir)

  let sourceFolders = processSourceFoldersList(sourcePathSet, sessionFolder)

  trace_index.recordTrace(
    recordingId,
    program = describeSession(info),
    args = @[],
    compileCommand = "",
    env = "",
    workdir = sessionFolder,
    lang = lang,
    sourceFolders = sourceFolders.join(" "),
    lowLevelFolder = "",
    outputFolder = sessionFolder,
    test = false,
    # The session is referenced in place, so it is not self-contained:
    # moving the recording-index row alone would not move the session.
    imported = false,
    shellID = -1,
    rrPid = NO_PID,
    exitCode = -1,
    calltrace = true,
    calltraceMode = CalltraceMode.FullRecord)
