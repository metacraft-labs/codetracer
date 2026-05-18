import std / [
  os, osproc, strformat, httpclient, json, strutils, sequtils,
  times
]
import results
import json_serialization
import paths, types, lang
import recording_id
include common_trace_index

when NimMajor >= 2:
  import ../db_connector/db_sqlite
else:
  import impure/db_sqlite


type
  Uploader* = object
    path*: string
    address*: string
    archiveServer*: string
    archiveID*: int
    buildID*: int
    client*: HttpClient


let defaultPath = app

const
  dbBusyTimeoutMs = 60_000
  # Marker file pinned next to the .bak so we never warn twice for the
  # same legacy database.  The first-launch warning is a one-shot UX
  # courtesy; it is not load-bearing for correctness.
  oldSchemaBakSuffix = ".pre-m-rec-2.bak"

let busyTimeoutPragma = SqlQuery("PRAGMA busy_timeout = " & $dbBusyTimeoutMs & ";")
let walModePragma = sql"PRAGMA journal_mode=WAL;"
let synchronousNormalPragma = sql"PRAGMA synchronous = NORMAL;"

var globalDbMap: array[2, DBConn]

proc configureDatabaseConnection(db: DBConn) =
  ## Configure the SQLite handle so concurrent writers back off instead of failing.
  db.exec(busyTimeoutPragma)
  db.exec(walModePragma)
  db.exec(synchronousNormalPragma)

proc isOldSchemaDb(dbPath: string): bool =
  ## Detect a pre-M-REC-2 ``trace_index.db`` by probing for the retired
  ## ``trace_values`` table.  We open a short-lived read-only handle so
  ## the check works even if a writer holds the WAL.
  if not fileExists(dbPath):
    return false
  var probe: DBConn
  try:
    probe = open(dbPath, "", "", "")
  except DbError:
    return false
  defer:
    try: probe.close() except DbError: discard
  try:
    discard probe.getAllRows(sql"SELECT 1 FROM trace_values LIMIT 1")
    return true
  except DbError:
    # ``trace_values`` is gone — this is either a fresh DB or a new-schema DB.
    return false

proc warnAndArchiveOldSchemaDb(dbPath: string) =
  ## Pre-1.0 schema migration: rename the legacy DB so callers get a
  ## fresh ``recordings`` table.  See parent spec §5 — there is no
  ## in-place migration; the old recordings are preserved on disk and
  ## remain individually replayable via ``ct replay <folder>``.
  let bakPath = dbPath & oldSchemaBakSuffix
  stderr.writeLine(
    "[codetracer] old-schema trace_index.db detected at " & dbPath & "; " &
    "pre-1.0 schema migration: recreating fresh DB " &
    "(existing recordings will not appear in 'ct list'). " &
    "The old DB is preserved at " & bakPath &
    " for manual recovery via 'ct replay <folder>'.")
  try:
    if fileExists(bakPath):
      # A previous run already archived a copy.  Avoid clobbering it;
      # append a numeric suffix so we keep both.
      var suffix = 1
      while fileExists(bakPath & "." & $suffix):
        inc suffix
      moveFile(dbPath, bakPath & "." & $suffix)
    else:
      moveFile(dbPath, bakPath)
  except OSError as e:
    stderr.writeLine("[codetracer] could not archive old DB: " & e.msg)
    # Best-effort: if the rename failed, try deletion so we don't keep
    # serving the legacy schema on every launch.
    try: removeFile(dbPath) except OSError: discard
  # WAL/shm sidecars may exist; rename them too so SQLite does not
  # pick up the old journal when we create the fresh database.
  for sidecarSuffix in ["-wal", "-shm"]:
    let sidecar = dbPath & sidecarSuffix
    if fileExists(sidecar):
      try:
        moveFile(sidecar, sidecar & oldSchemaBakSuffix)
      except OSError:
        try: removeFile(sidecar) except OSError: discard

proc ensureDB(test: bool): DBConn =
  # useful when debugging where it is called from: writeStackTrace()
  if not globalDbMap[1 - test.int].isNil:
    echo fmt"error: calling ensureDB with test={test}, but it was probably already called with test={(1 - test.int).bool}"
    quit(1)
  if not globalDbMap[test.int].isNil:
    # echo "db ", DB_PATHS[test.int]
    globalDbMap[test.int] = open(DB_PATHS[test.int], "", "", "")
    configureDatabaseConnection(globalDbMap[test.int])
    return globalDbMap[test.int]

  createDir(DB_FOLDERS[test.int])

  # M-REC-2: detect a pre-existing pre-1.0 DB and archive it.  This
  # must happen BEFORE we open the connection so the on-disk file is
  # fresh.  Concurrent processes may both observe the old file; the
  # SQLite ``open`` below tolerates the race because the loser just
  # creates the new schema on an empty file.
  if isOldSchemaDb(DB_PATHS[test.int]):
    warnAndArchiveOldSchemaDb(DB_PATHS[test.int])

  if not fileExists(DB_PATHS[test.int]):
    # yes, it can be created in the meantime..
    # but I assume that's ok for now
    writeFile(DB_PATHS[test.int], "") # instead of touch
    # so we don't depend on /bin/sh here

  var db = open(DB_PATHS[test.int], "", "", "")
  configureDatabaseConnection(db)

  for statement in SQL_CREATE_TABLE_STATEMENTS:
    db.exec(sql(statement))

  globalDbMap[test.int] = db
  db

proc newID*(test: bool): string =
  ## Mint a fresh UUIDv7 ``recording_id`` (canonical lowercase
  ## hyphenated 36-char form).  The previous ``int`` counter is gone;
  ## see ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
  ## §5.  Opening the DB connection is preserved as a side effect so
  ## existing call patterns ("ensure the DB is materialized before the
  ## first INSERT") continue to work.
  discard ensureDB(test)
  let res = newRecordingId()
  if res.isErr:
    # The OS CSPRNG is required; if it refuses, there is no safe
    # fallback for a recording identifier.  Surface a fatal error in
    # the same shape callers expect from a DB failure.
    raise newException(IOError,
      "trace_index.newID: could not generate UUIDv7 recording_id: " &
        res.error)
  res.value

proc updateField*(
  id: string,
  fieldName: string,
  fieldValue: string,
  test: bool
) =
  let db = ensureDB(test)
  db.exec(
    sql(&"UPDATE recordings SET {fieldName} = ? WHERE recording_id = ?"),
    fieldValue, id
  )
  db.close()

proc updateField*(
  id: string,
  fieldName: string,
  fieldValue: int,
  test: bool
) =
  let db = ensureDB(test)
  db.exec(
    sql(&"UPDATE recordings SET {fieldName} = ? WHERE recording_id = ?"),
    fieldValue, id
  )
  db.close()

proc getField*(
  id: string,
  fieldName: string,
  test: bool
): string =
  let db = ensureDB(test)
  let res = db.getAllRows(
    sql(&"SELECT {fieldName} FROM recordings WHERE recording_id = ? LIMIT 1"),
    id
  )
  db.close()
  if res.len > 0:
    return res[0][0]
  return ""

proc recordTrace*(
    id: string,
    program: string,
    args: seq[string],
    compileCommand: string,
    env: string,
    workdir: string,
    lang: Lang,
    sourceFolders: string,
    lowLevelFolder: string,
    outputFolder: string,
    imported: bool,
    shellID: int,
    rrPid: int,
    exitCode: int,
    calltrace: bool,
    calltraceMode: CalltraceMode,
    test: bool,
    fileId: string = ""): Trace =
  # TODO pass here a Trace value and instead if neeeded construct it from other helpers

  let currentDate: DateTime = now()
  var traceDate: string = ""
  traceDate.formatValue(currentDate, "yyyy/MM/dd")
  let db = ensureDB(test)
  # Pre-1.0: ``recordTrace`` overwrites any prior row with the same
  # ``recording_id``.  The new schema enforces uniqueness via the TEXT
  # PRIMARY KEY, so a stale collision would fail the INSERT; we DELETE
  # first to preserve the "last writer wins" semantics callers rely on
  # when re-recording into the same trace folder.
  while true:
    try:
      db.exec(sql"DELETE FROM recordings WHERE recording_id = ?", id)
      break
    except DbError:
      echo "error: ", getCurrentExceptionMsg()
      sleep 100

  while true:
    try:
      db.exec(
        sql"""
          INSERT INTO recordings
            (recording_id, program, args,
            compile_command, env, workdir, output,
            source_folders, low_level_folder, output_folder,
            lang, imported, shell_id,
            rr_pid, exit_code,
            calltrace, calltrace_mode, recorded_at, remote_share_download_key)
          VALUES (?, ?, ?,
             ?, ?, ?, ?,
             ?, ?, ?,
             ?, ?, ?,
             ?, ?,
             ?, ?, ?, ?)""",
            id, program, args.join(" "),
            compileCommand, env, workdir, "", # <- output
            sourceFolders, lowLevelFolder, outputFolder,
            $(lang.int), $(imported.int), $shellID,
            $rrPid, $exitCode,
            ord(calltrace), $calltraceMode, $traceDate, fileId)
      break
    except DbError:
      echo "error: ", getCurrentExceptionMsg()
      sleep 100
  db.close()
  Trace(
    recordingId: id,
    program: program,
    args: args,
    sourceFolders: sourceFolders.splitWhitespace(),
    compileCommand: compileCommand,
    outputFolder: outputFolder,
    env: env,
    workdir: workdir,
    lang: lang,
    output: "",
    imported: imported,
    shellID: shellID,
    rrPid: rrPid,
    exitCode: exitCode,
    calltrace: calltrace,
    calltraceMode: calltraceMode,
    date: traceDate)

proc recordTrace*(trace: Trace, test: bool): Trace =
  # TODO pass here a Trace value and instead if neeeded construct it from other helpers
  recordTrace(
    trace.recordingId,
    trace.program,
    trace.args,
    trace.compileCommand,
    trace.env,
    trace.workdir,
    trace.lang,
    trace.sourceFolders.join(" "),
    trace.lowLevelFolder,
    trace.outputFolder,
    trace.imported,
    trace.shellID,
    trace.rrPid,
    trace.exitCode,
    trace.calltrace,
    trace.calltraceMode,
    test)

proc loadCalltraceMode*(raw: string, lang: Lang): CalltraceMode =
  if raw.len == 0: # default, or missing calltrace mode(e.g. from a trace before altering table/update)
    if not lang.usesMaterializedTraces:
      CalltraceMode.NoInstrumentation # conservative default
    else:
      CalltraceMode.FullRecord
  else:
    parseEnum[CalltraceMode](raw)

proc loadTrace(trace: Row, test: bool): Trace =
  # M-REC-2: column order matches ``SQL_CREATE_TABLE_STATEMENTS`` in
  # ``common_trace_index.nim`` exactly:
  #   0  recording_id (TEXT)              11 imported
  #   1  program                          12 shell_id
  #   2  args                             13 rr_pid
  #   3  compile_command                  14 exit_code
  #   4  env                              15 calltrace
  #   5  workdir                          16 calltrace_mode
  #   6  output                           17 recorded_at
  #   7  source_folders                   18 remote_share_download_key
  #   8  low_level_folder                 19 remote_share_control_id
  #   9  output_folder                    20 remote_share_expire_time
  #  10  lang
  try:
    let lang = trace[10].parseInt.Lang
    var expireTime = -1
    try:
      expireTime = trace[20].parseInt
    except CatchableError:
      discard

    result = Trace(
      recordingId: trace[0],
      program: trace[1],
      args: trace[2].splitWhitespace,
      compileCommand: trace[3],
      env: trace[4],
      workdir: trace[5],
      output: trace[6],
      sourceFolders: trace[7].splitWhitespace(),
      lowLevelFolder: trace[8],
      outputFolder: trace[9],
      lang: lang,
      test: test,
      imported: trace[11].parseInt != 0,
      shellID: trace[12].parseInt,
      rrPid: trace[13].parseInt,
      exitCode: trace[14].parseInt,
      calltrace: trace[15].parseInt != 0,
      calltraceMode: loadCalltraceMode(trace[16], lang),
      date: trace[17],
      downloadKey: trace[18],
      controlId: trace[19],
      onlineExpireTime: expireTime)
  except CatchableError as e:
    # assume db schema change?
    echo "internal error: ", e.msg
    echo """
    ========
    error: can't load the trace: maybe the db schema is changed?
      * try to check if correct args are passed
      * maybe there is a db schema change or other db issue?
        if so, delete the db and re-record again: using:

        `just reset-db` # deleting the db
        # or
        `just clear-local-traces` # deleting all local traces and the db

      (the db is usually saved as
        * $HOME/.local/share/codetracer/trace_index.db for normal records
        * <install dir>/src/tests/trace_index.db for test records
      if those are tests,
      you can re-record the tests with `tester build` after deleting the db)
    """
    quit(1)


proc sendEvent(socketPath: string, address: string, rawEvent: string) =
  let debugCtSendWithCurl = getEnv("CODETRACER_DEBUG_CURL", "0") == "1"

  if debugCtSendWithCurl:
    echo fmt"sending with curl to {socketPath} and {address}:"
    echo rawEvent
    echo "===="

  # example: curl --unix-socket /tmp/my_socket.sock http://localhost/api/ping
  let process = startProcess(
    curlExe,
    args = @[
      "--header", "Content-Type: application/json",
      "--data", rawEvent,
      "--request", "POST",
      "--unix-socket", socketPath, address],
    options = {}) # poParentStreams})
  let code = waitForExit(process)
  if code != 0:
    stderr.writeLine(fmt"WARNING: couldn't send event to codetracer-web: exit-code {code} from curl")

# CODE REVIEW question: should we use a register event object which can include
#   reportFile / socketPath / address / others for better maintanance/code?
#   or is separate params everywhere ok for now?
proc registerEvent*(reportFile: string, socketPath: string, address: string, event: SessionEvent) =
  if socketPath.len > 0:
    sendEvent(socketPath, address, Json.encode(event))
  else:
    discard # not implemented for this backend for now

proc registerRecordingForPid*(pid: int, recordingId: string, test: bool) =
  ## Map a recorder process pid to the ``recording_id`` of the trace it
  ## produced.  Pre-M-REC-2 this used an integer trace id and the proc
  ## was named ``registerRecordTraceId``; M-REC-3 renamed both the proc
  ## and its parameter so callers speak "recording" rather than the
  ## overloaded "trace_id".
  let db = ensureDB(test=test)
  db.exec(sql"""
    INSERT INTO record_pid_recording_map
    (pid, recording_id)
    VALUES (?, ?)""",
    pid,
    recordingId
  )
  db.close()

proc find*(id: string, test: bool): Trace

proc registerRecordingCommandForCI*(
    socketPath: string, address: string,
    recordPid: int, traceArchivePath: string,
    langName: string) =
  sendEvent(
    socketPath,
    address,
    Json.encode(
      CITraceEvent(
        recordPid: recordPid,
        traceArchivePath: traceArchivePath,
        langName: langName)))

proc registerRecordingCommand*(
    reportFile: string, socketPath: string, address: string,
    sessionId: int, actionId: int, recordPid: int, traceArchivePath: string,
    command: string,
    status: SessionEventStatus, errorMessage: string,
    firstLine: int, lastLine: int = -1) =
  registerEvent(
    reportFile,
    socketPath,
    address,
    SessionEvent(
     kind: RecordingCommand,
     sessionId: sessionId,
     recordPid: recordPid,
     traceArchivePath: traceArchivePath,
     command: command,
     status: status,
     errorMessage: errorMessage,
     firstLine: firstLine,
     lastLine: lastLine,
     actionId: actionId))


proc all*(test: bool): seq[Trace] =
  ## Return every recording in the local index, newest-first.  Pre-M-REC-2
  ## "newest" was the largest integer id; with UUIDv7 the canonical text
  ## form sorts lex-ascending by ms-precision creation time, so DESC on
  ## ``recording_id`` is the natural newest-first ordering.  We use
  ## ``recorded_at`` for the SQL ORDER BY to remain robust against
  ## fictional fixture UUIDs whose embedded timestamps may not match
  ## reality.
  let db = ensureDB(test)
  result = @[]
  let traces = toSeq(db.fastRows(sql"SELECT * FROM recordings ORDER BY recorded_at DESC, recording_id DESC"))
  db.close()
  for trace in traces:
    result.add(trace.loadTrace(test))


proc find*(id: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(sql"SELECT * FROM recordings WHERE recording_id = ? LIMIT 1", id)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByPath*(path: string, test: bool): Trace =
  let db = ensureDB(test)
  let exact = db.getAllRows(
    sql"SELECT * FROM recordings WHERE output_folder = ? ORDER BY recorded_at DESC LIMIT 1",
    path)
  if exact.len > 0:
    db.close()
    return exact[0].loadTrace(test)

  let slashNormalizedPath = path.replace("\\", "/")
  let normalizedInput =
    if slashNormalizedPath.endsWith("/"):
      slashNormalizedPath[0 .. ^2]
    else:
      slashNormalizedPath

  let normalized = db.getAllRows(
    sql"""SELECT * FROM recordings
          WHERE rtrim(replace(output_folder, char(92), '/'), '/') = ?
          ORDER BY recorded_at DESC LIMIT 1""",
    normalizedInput)
  if normalized.len > 0:
    db.close()
    return normalized[0].loadTrace(test)

  db.close()

proc findByProgram*(program: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql"SELECT * FROM recordings WHERE program = ? ORDER BY recorded_at DESC LIMIT 1",
    program)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByProgramPattern*(programPattern: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql"SELECT * FROM recordings WHERE program LIKE ? ORDER BY recorded_at DESC LIMIT 1",
    fmt"%{programPattern}")
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByRecordProcessId*(pid: int, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql"""SELECT * FROM recordings
          WHERE recording_id = (
            SELECT recording_id FROM record_pid_recording_map WHERE pid = ?
          ) LIMIT 1""",
    pid)
  db.close()
  if traces.len > 0:
    var trace = traces[0].loadTrace(test)
    return trace

proc findRecentTraces*(limit: int, test: bool): seq[Trace] =
  let db = ensureDB(test)
  let traces =
    if limit > 0:
      db.getAllRows(
        sql"SELECT * FROM recordings ORDER BY recorded_at DESC, recording_id DESC LIMIT ?",
        $limit
      )
    else:
      # limit <= 0 means no limit (return all traces)
      db.getAllRows(
        sql"SELECT * FROM recordings ORDER BY recorded_at DESC, recording_id DESC"
      )

  if traces.len > 0:
    result = traces.mapIt(it.loadTrace(test))

proc addRecentFolder*(path: string, test: bool) =
  ## Add or update a recent folder entry
  let currentDate: DateTime = now()
  var lastOpenedStr: string = ""
  lastOpenedStr.formatValue(currentDate, "yyyy/MM/dd HH:mm:ss")

  let folderName = extractFilename(path)
  let db = ensureDB(test)

  # Use INSERT OR REPLACE to handle both new and existing entries
  try:
    db.exec(
      sql"""INSERT OR REPLACE INTO recent_folders (path, name, last_opened)
            VALUES (?, ?, ?)""",
      path, folderName, lastOpenedStr)
  except DbError:
    echo "error: addRecentFolder: ", getCurrentExceptionMsg()

  db.close()

proc findRecentFolders*(limit: int, test: bool): seq[RecentFolder] =
  ## Find recent folders ordered by last opened (most recent first)
  let db = ensureDB(test)
  result = @[]

  try:
    let folders =
      if limit > 0:
        db.getAllRows(
          sql"SELECT id, path, name, last_opened FROM recent_folders ORDER BY last_opened DESC LIMIT ?",
          $limit)
      else:
        db.getAllRows(
          sql"SELECT id, path, name, last_opened FROM recent_folders ORDER BY last_opened DESC")

    for folder in folders:
      result.add(RecentFolder(
        id: folder[0].parseInt,
        path: folder[1],
        name: folder[2],
        lastOpened: folder[3]))
  except DbError:
    echo "error: findRecentFolders: ", getCurrentExceptionMsg()

  db.close()

proc updateRecentFolder*(path: string, test: bool) =
  ## Update the lastOpened timestamp for an existing folder
  let currentDate: DateTime = now()
  var lastOpenedStr: string = ""
  lastOpenedStr.formatValue(currentDate, "yyyy/MM/dd HH:mm:ss")

  let db = ensureDB(test)

  try:
    db.exec(
      sql"UPDATE recent_folders SET last_opened = ? WHERE path = ?",
      lastOpenedStr, path)
  except DbError:
    echo "error: updateRecentFolder: ", getCurrentExceptionMsg()

  db.close()

proc removeRecentFolder*(path: string, test: bool) =
  ## Remove a folder from recent folders
  let db = ensureDB(test)

  try:
    db.exec(
      sql"DELETE FROM recent_folders WHERE path = ?",
      path)
  except DbError:
    echo "error: removeRecentFolder: ", getCurrentExceptionMsg()

  db.close()
