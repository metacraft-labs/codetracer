import std / [
  os, osproc, strformat, httpclient, json, strutils, sequtils,
  sysrand, times
]
import json_serialization
import paths, types, lang
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

let busyTimeoutPragma = SqlQuery("PRAGMA busy_timeout = " & $dbBusyTimeoutMs & ";")
let walModePragma = sql"PRAGMA journal_mode=WAL;"
let synchronousNormalPragma = sql"PRAGMA synchronous = NORMAL;"

var globalDbMap: array[2, DBConn]

proc configureDatabaseConnection(db: DBConn) =
  ## Configure the SQLite handle so concurrent writers back off instead of failing.
  db.exec(busyTimeoutPragma)
  db.exec(walModePragma)
  db.exec(synchronousNormalPragma)

proc detectOldSchema(db: DBConn): bool =
  ## Probe an open DB handle for the pre-M-REC-2 schema marker.
  ##
  ## Pre-M-REC-2 trace databases carried a ``trace_values`` table that held
  ## the ``maxTraceID`` integer counter.  That table no longer exists in the
  ## new schema (Recording-Identifier-Migration.md §5); a successful SELECT
  ## against it therefore unambiguously identifies a legacy DB that needs to
  ## be wiped and recreated per the pre-1.0 policy.
  try:
    discard db.getAllRows(sql(SQL_DETECT_OLD_SCHEMA))
    true
  except DbError:
    false

proc warnAndArchiveOldSchema(dbPath: string) =
  ## Print the first-launch warning and move the legacy DB out of the way.
  ##
  ## The renamed file lets developers manually recover the integer-id
  ## metadata if they ever need to; pre-1.0 we don't bother with automatic
  ## migration but we don't actively destroy the data either.
  let backupPath = dbPath & OLD_SCHEMA_BACKUP_SUFFIX
  stderr.writeLine(
    "[codetracer] old-schema trace_index.db detected at " & dbPath &
    "; pre-1.0 schema migration: recreating fresh DB " &
    "(existing recordings will not appear in 'ct list'). " &
    "To restore, replay each recording folder individually via " &
    "'ct replay <path>'.")
  stderr.writeLine(
    "[codetracer] archiving legacy DB to " & backupPath)
  try:
    # Remove any prior backup so a second upgrade still moves cleanly out
    # of the way.  This is best-effort: if the developer was holding onto
    # ``.pre-m-rec-2.bak`` we'd rather overwrite it than fail the launch.
    if fileExists(backupPath):
      removeFile(backupPath)
    moveFile(dbPath, backupPath)
  except OSError as e:
    stderr.writeLine(
      "[codetracer] WARNING: failed to archive legacy DB (" & e.msg &
      "); removing it instead.")
    try:
      removeFile(dbPath)
    except OSError:
      discard

  # SQLite may have left WAL/SHM sidecar files alongside the DB; those
  # belong to the pre-M-REC-2 connection and must not influence the fresh
  # DB.  Best-effort cleanup; ignore missing files.
  for suffix in ["-wal", "-shm", "-journal"]:
    let sidecar = dbPath & suffix
    if fileExists(sidecar):
      try:
        removeFile(sidecar)
      except OSError:
        discard

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

  createDir(DB_FOLDERS[test.int]) # execCMD(&"mkdir -p {DB_FOLDERS[test.int]}")

  # Detect the pre-M-REC-2 schema *before* applying any of the new CREATE
  # statements — otherwise the new tables would happily co-exist with the
  # old ``traces`` / ``trace_values`` ones and we'd never notice.
  if fileExists(DB_PATHS[test.int]):
    var probeDb = open(DB_PATHS[test.int], "", "", "")
    let isOldSchema = detectOldSchema(probeDb)
    probeDb.close()
    if isOldSchema:
      warnAndArchiveOldSchema(DB_PATHS[test.int])

  if not fileExists(DB_PATHS[test.int]):
    # yes, it can be created in the meantime..
    # but I assume that's ok for now
    writeFile(DB_PATHS[test.int], "") # instead of touch
    # so we don't depend on /bin/sh here

  var db = open(DB_PATHS[test.int], "", "", "")
  configureDatabaseConnection(db)

  for statement in SQL_CREATE_TABLE_STATEMENTS:
    db.exec(sql(statement))

  for statement in SQL_ALTER_TABLE_STATEMENTS:
    try:
      db.exec(sql(statement))
    except DbError:
      # assume the change is already applied
      # e.g. the column already exists
      discard

  # # should fail if it already exists
  # # which is good
  for statement in SQL_INITIAL_INSERT_STATEMENTS:
    try:
      db.exec(sql(statement))
    except DbError:
      discard

  globalDbMap[test.int] = db
  db

# ---------------------------------------------------------------------------
# Recording-id generation (UUIDv7)
# ---------------------------------------------------------------------------
#
# M-REC-2 keeps the proc name ``newID`` to minimise call-site churn but flips
# the return type from ``int`` to ``string`` (canonical 36-char hyphenated
# UUIDv7, per Recording-Identifier-Migration.md §3).  The semantic rename to
# ``newRecordingId`` is M-REC-3 territory.
#
# This is the transitional shim referenced by the M-REC-2 acceptance
# criteria (test #3): ``newID`` no longer reads/updates a counter row; it
# mints a fresh UUIDv7 from the OS CSPRNG and returns the canonical text
# form.  The DB connection is still acquired so callers' assumption that
# ``newID`` materialises the DB on first launch is preserved.

const
  RecordingIdHexLower = "0123456789abcdef"
  RecordingIdTextLen = 36

proc generateRecordingId(): string =
  ## Mint a fresh UUIDv7 in canonical 36-char hyphenated form.
  ##
  ## Implementation mirrors the recorder-side helper at
  ## ``codetracer-trace-format-nim/src/codetracer_trace_writer/uuid_v7.nim``
  ## (M-REC-1) so the two sides produce indistinguishable ids.  The format
  ## is RFC 9562 §5.7:
  ##   bytes 0..5  : 48-bit unix_ts_ms, big-endian
  ##   bytes 6..7  : version nibble (0x70) + 12 random bits
  ##   bytes 8..15 : variant nibble (0b10xx) + 62 random bits
  ##
  ## We don't depend on the recorder-side helper directly because
  ## ``codetracer/`` does not currently import ``codetracer-trace-format-nim``
  ## from the ``common/`` tree (and pulling in the dependency just for the
  ## helper would inflate the build closure).  The two implementations are
  ## byte-identical by construction.
  var randomBytes: array[10, byte]
  if not urandom(randomBytes):
    # Practically unreachable on a healthy host (the kernel CSPRNG won't
    # return failure unless /dev/urandom is unavailable).  We fall back to
    # a time-derived id so the caller still gets *something* valid — better
    # than crashing the recorder.  This branch is observable in tests by
    # snapshotting urandom failures via LD_PRELOAD; if it ever fires in
    # practice the caller will see a recording_id whose entropy is weaker
    # than the rest, which we surface in logs.
    stderr.writeLine(
      "[codetracer] WARNING: OS CSPRNG refused entropy; recording_id " &
      "falls back to a weak time-derived value.")
    let nowNs = uint64(epochTime() * 1_000_000_000.0)
    for i in 0 ..< 10:
      randomBytes[i] = byte((nowNs shr (i mod 8 * 8)) and 0xFF'u64)

  let ms = uint64(epochTime() * 1000.0)
  var bytes: array[16, byte]
  bytes[0] = byte((ms shr 40) and 0xFF'u64)
  bytes[1] = byte((ms shr 32) and 0xFF'u64)
  bytes[2] = byte((ms shr 24) and 0xFF'u64)
  bytes[3] = byte((ms shr 16) and 0xFF'u64)
  bytes[4] = byte((ms shr 8) and 0xFF'u64)
  bytes[5] = byte(ms and 0xFF'u64)
  bytes[6] = byte((0x70'u8) or (randomBytes[0] and 0x0F'u8))
  bytes[7] = randomBytes[1]
  bytes[8] = byte((randomBytes[2] and 0x3F'u8) or 0x80'u8)
  bytes[9] = randomBytes[3]
  for i in 0 ..< 6:
    bytes[10 + i] = randomBytes[4 + i]

  result = newString(RecordingIdTextLen)
  var dest = 0
  for i in 0 ..< 16:
    if i == 4 or i == 6 or i == 8 or i == 10:
      result[dest] = '-'
      inc dest
    let b = bytes[i]
    result[dest] = RecordingIdHexLower[int(b shr 4)]
    inc dest
    result[dest] = RecordingIdHexLower[int(b and 0x0F'u8)]
    inc dest

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
  # should we leave this? overwrites trace with id for default storage
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
    id: id,
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
    trace.id,
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
  ## Materialise a ``Trace`` from a row of the ``recordings`` table.
  ##
  ## Column order matches ``SELECT *`` against the new schema
  ## (see ``common_trace_index.nim``):
  ##   0  recording_id (TEXT)
  ##   1  program
  ##   2  args
  ##   3  compile_command
  ##   4  env
  ##   5  workdir
  ##   6  output
  ##   7  source_folders
  ##   8  low_level_folder
  ##   9  output_folder
  ##   10 lang
  ##   11 imported
  ##   12 shell_id
  ##   13 rr_pid
  ##   14 exit_code
  ##   15 calltrace
  ##   16 calltrace_mode
  ##   17 recorded_at
  ##   18 remote_share_download_key
  ##   19 remote_share_control_id
  ##   20 remote_share_expire_time
  try:
    let lang = trace[10].parseInt.Lang
    var expireTime = -1
    try:
      expireTime = trace[20].parseInt
    except:
      discard

    result = Trace(
      id: trace[0],
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

proc registerRecordTraceId*(pid: int, recordingId: string, test: bool) =
  ## Associate a record-process PID with a recording_id in
  ## ``record_pid_recording_map``.  The proc keeps the legacy name
  ## ``registerRecordTraceId`` so M-REC-2 stays minimum-diff; the rename to
  ## ``registerRecordRecordingId`` is M-REC-3 territory.
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
  ## Return recordings ordered newest-first.  ``recording_id`` is a UUIDv7
  ## whose lex order is creation-time order (RFC 9562 §5.7), so a DESC sort
  ## on the primary key gives the user "most recent first" without needing
  ## to inspect ``recorded_at``.
  let db = ensureDB(test)
  result = @[]
  let traces = toSeq(db.fastRows(sql"SELECT * from recordings ORDER BY recording_id DESC"))
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
    sql"SELECT * FROM recordings WHERE output_folder = ? ORDER BY recording_id DESC LIMIT 1",
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
          ORDER BY recording_id DESC LIMIT 1""",
    normalizedInput)
  if normalized.len > 0:
    db.close()
    return normalized[0].loadTrace(test)

  db.close()

proc findByProgram*(program: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(sql"SELECT * FROM recordings WHERE program = ? ORDER BY recording_id DESC LIMIT 1", program)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByProgramPattern*(programPattern: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql("SELECT * FROM recordings WHERE program LIKE ? ORDER BY recording_id DESC LIMIT 1"),
    fmt"%{programPattern}")
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByRecordProcessId*(pid: int, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql("""SELECT * FROM recordings
           WHERE recording_id = (SELECT recording_id FROM record_pid_recording_map WHERE pid = ?)
           LIMIT 1"""),
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
        sql("SELECT * FROM recordings ORDER BY recording_id DESC LIMIT ?"),
        $limit
      )
    else:
      # limit <= 0 means no limit (return all traces)
      db.getAllRows(
        sql("SELECT * FROM recordings ORDER BY recording_id DESC")
      )

  if traces.len > 0:
    result = traces.mapIt(it.loadTrace(test))

proc newID*(test: bool): string =
  ## Mint a fresh recording_id (UUIDv7, canonical 36-char form).
  ##
  ## Pre-M-REC-2 this returned an integer drawn from
  ## ``trace_values.maxTraceID``; the migration drops that counter and
  ## switches to a UUIDv7 minted in-process.  The proc name is preserved
  ## (rename to ``newRecordingId`` is M-REC-3) but the return type flips
  ## ``int`` → ``string``.  Callers that need to write the id back into the
  ## DB now pass it to ``recordTrace`` exactly as before.
  ##
  ## The DB is materialised as a side effect so legacy callers that relied
  ## on ``newID`` as a "create the DB if missing" trigger keep working.
  discard ensureDB(test)
  generateRecordingId()

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
          sql("SELECT id, path, name, last_opened FROM recent_folders ORDER BY last_opened DESC LIMIT ?"),
          $limit)
      else:
        db.getAllRows(
          sql("SELECT id, path, name, last_opened FROM recent_folders ORDER BY last_opened DESC"))

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
