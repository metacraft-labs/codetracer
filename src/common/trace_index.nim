import std / [ 
  os, osproc, strformat, httpclient, json, strutils, sequtils, 
  times, db_sqlite
]
import json_serialization
import paths, types, lang
include common_trace_index


type
  Uploader* = object
    path*: string
    address*: string
    archiveServer*: string
    archiveID*: int
    buildID*: int
    client*: HttpClient


let defaultPath = app


var globalDbMap: array[2, DBConn]


proc ensureDB(test: bool): DBConn =
  # useful when debugging where it is called from: writeStackTrace()
  if not globalDbMap[1 - test.int].isNil:
    echo fmt"error: calling ensureDB with test={test}, but it was probably already called with test={(1 - test.int).bool}"
    quit(1)
  if not globalDbMap[test.int].isNil:
    # echo "db ", DB_PATHS[test.int]
    globalDbMap[test.int] = open(DB_PATHS[test.int], "", "", "")
    return globalDbMap[test.int]

  createDir(DB_FOLDERS[test.int]) # execCMD(&"mkdir -p {DB_FOLDERS[test.int]}")

  if not fileExists(DB_PATHS[test.int]):
    # yes, it can be created in the meantime..
    # but I assume that's ok for now
    writeFile(DB_PATHS[test.int], "") # instead of touch
    # so we don't depend on /bin/sh here

  var db = open(DB_PATHS[test.int], "", "", "")

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

proc updateField*(
  id: int,
  fieldName: string,
  fieldValue: string,
  test: bool
) =
  let db = ensureDB(test)
  db.exec(
    sql(&"UPDATE traces SET {fieldName} = ? WHERE id = ?"),
    fieldValue, id
  )
  db.close()

proc updateField*(
  id: int,
  fieldName: string,
  fieldValue: int,
  test: bool
) =
  let db = ensureDB(test)
  db.exec(
    sql(&"UPDATE traces SET {fieldName} = ? WHERE id = ?"),
    fieldValue, id
  )
  db.close()

proc getField*(
  id: int,
  fieldName: string,
  test: bool
): string =
  let db = ensureDB(test)
  let res = db.getAllRows(
    sql(&"SELECT {fieldName} FROM traces WHERE id = ? LIMIT 1"),
    id
  )
  db.close()
  if res.len > 0:
    return res[0][0]
  return ""

proc recordTrace*(
    id: int,
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
      db.exec(sql"DELETE FROM traces WHERE id = ?", $id)
      break
    except DbError:
      echo "error: ", getCurrentExceptionMsg()
      sleep 100

  while true:
    try:
      db.exec(
        sql"""
          INSERT INTO traces
            (id, program, args,
            compileCommand, env, workdir, output,
            sourceFolders, lowLevelFolder, outputFolder,
            lang, imported, shellID,
            rrPid, exitCode,
            calltrace, calltraceMode, date, remoteShareDownloadKey)
          VALUES (?, ?, ?,
             ?, ?, ?, ?,
             ?, ?, ?,
             ?, ?, ?,
             ?, ?,
             ?, ?, ?, ?)""",
            $id, program, args.join(" "),
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
    if not lang.isDbBased:
      CalltraceMode.NoInstrumentation # conservative default
    else:
      CalltraceMode.FullRecord
  else:
    parseEnum[CalltraceMode](raw)

proc loadTrace(trace: Row, test: bool): Trace =
  try:
    let lang = trace[10].parseInt.Lang
    var expireTime = -1
    try:
      expireTime = trace[20].parseInt
    except:
      discard

    result = Trace(
      id: trace[0].parseInt,
      program: trace[1],
      args: trace[2].splitWhitespace,
      compileCommand: trace[3],
      env: trace[4],
      workdir: trace[5],
      output: trace[6],
      sourceFolders: trace[7].splitWhitespace(), #if trace[6][^1] != '/': trace[6] & "/" else: trace[6],
      lowLevelFolder: trace[8],
      outputFolder: trace[9],
      lang: lang,
      test: test,
      imported: trace[11].parseInt != 0,
      rrPid: trace[12].parseInt,
      exitCode: trace[13].parseInt,
      shellID: trace[14].parseInt,

      calltrace: trace[15].parseInt != 0,
      calltraceMode: loadCalltraceMode(trace[16], lang),
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


proc sendEvent(socketPath: string, address: string, event: SessionEvent) =
  let raw = Json.encode(event)

  # echo fmt"sending with curl to {socketPath} and {address}:"
  # echo raw
  # echo "===="

  # example: curl --unix-socket /tmp/my_socket.sock http://localhost/api/ping
  let process = startProcess(
    curlExe,
    args = @[
      "--header", "Content-Type: application/json",
      "--data", raw,
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
    sendEvent(socketPath, address, event)
  else:
    discard # not implemented for this backend for now

proc registerRecordTraceId*(pid: int, traceId: int, test: bool) =
  let db = ensureDB(test=test)
  db.exec(sql"""
    INSERT INTO record_pid_trace_id_map
    (pid, traceId)
    VALUES (?, ?)""",
    pid,
    traceId
  )
  db.close()

proc find*(id: int, test: bool): Trace

proc registerRecordingCommand*(
    reportFile: string, socketPath: string, address: string,
    sessionId: int, actionId: int, trace: Trace, command: string,
    status: SessionEventStatus, errorMessage: string,
    firstLine: int, lastLine: int = -1) =
  registerEvent(
    reportFile,
    socketPath,
    address,
    SessionEvent(
      kind: RecordingCommand,
      sessionId: sessionId,
      trace: trace,
      command: command,
      status: status,
      errorMessage: errorMessage,
      firstLine: firstLine,
      lastLine: lastLine,
      actionId: actionId))


proc all*(test: bool): seq[Trace] =
  # ordered by id
  # returns the newest(biggest id) first
  let db = ensureDB(test)
  result = @[]
  let traces = toSeq(db.fastRows(sql"SELECT * from traces ORDER BY id DESC"))
  db.close()
  for trace in traces:
    result.add(trace.loadTrace(test))


proc find*(id: int, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(sql"SELECT * FROM traces WHERE id = ? LIMIT 1", $id)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByPath*(path: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(sql"SELECT * FROM traces WHERE outputFolder = ? ORDER BY id DESC LIMIT 1", path)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByProgram*(program: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(sql"SELECT * FROM traces WHERE program = ? ORDER BY id DESC LIMIT 1", program)
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByProgramPattern*(programPattern: string, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql("SELECT * FROM traces WHERE program LIKE ? ORDER BY id DESC LIMIT 1"),
    fmt"%{programPattern}")
  db.close()
  if traces.len > 0:
    result = traces[0].loadTrace(test)

proc findByRecordProcessId*(pid: int, test: bool): Trace =
  let db = ensureDB(test)
  let traces = db.getAllRows(
    sql("SELECT * FROM traces WHERE id = (SELECT traceId FROM record_pid_trace_id_map WHERE pid = ?) LIMIT 1"),
    pid)
  db.close()
  if traces.len > 0:
    var trace = traces[0].loadTrace(test)
    return trace

proc findRecentTraces*(limit: int, test: bool): seq[Trace] =
  let db = ensureDB(test)
  let traces =
    if limit == -1:
      db.getAllRows(
        sql("SELECT * FROM traces ORDER BY id DESC LIMIT ?"),
        $limit
      )
    else:
      db.getAllRows(
        sql("SELECT * FROM traces ORDER BY id DESC")
      )

  if traces.len > 0:
    result = traces.mapIt(it.loadTrace(test))

proc newID*(test: bool): int =
  let db = ensureDB(test)
  result = db.getRow(sql"SELECT maxTraceID from trace_values LIMIT 1")[0].parseInt
  while true:
    try:
      db.exec(sql"UPDATE trace_values SET maxTraceID = ? WHERE 1", $(result + 1))
      break
  # TODO: we had an error here : on db.close
  #   /home/al/CodeTracer/src/build-debug/codetracer.nim(975) codetracer
  #   /home/al/CodeTracer/src/build-debug/codetracer.nim(930) run
  #   /home/al/CodeTracer/src/build-debug/codetracer.nim(437) record
  #   /home/al/CodeTracer/src/build-debug/trace_index.nim(238) newID
  #   /home/al/CodeTracer/libs/nim/lib/impure/db_sqlite.nim(597) close
  #   /home/al/CodeTracer/libs/nim/lib/impure/db_sqlite.nim(142) dbError

  #   ERROR [codetracer.nim:979]:
  #   unhandled unable to close due to unfinalized statements or unfinished backups
  #

  # another one on ensureDB, when recording and maybe because of other record/replays at the same time


    except CatchableError as e:
      echo "error: newID : ", e.msg
      sleep 100

  db.close()
