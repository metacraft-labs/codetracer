## Subprocess helper for ``trace_index_test.nim``.
##
## ``trace_index`` evaluates ``paths.app`` (= ``XDG_DATA_HOME / "codetracer"``)
## once at module load via ``let defaultPath = app``.  To exercise the
## "fresh DB" and "old-schema detection" paths cleanly we run each
## scenario in a fresh subprocess with ``XDG_DATA_HOME`` pre-pointed at
## a tmpdir.  The helper prints ``PASS`` to stdout on success and exits
## with a non-zero status on failure; the parent test asserts on the
## wire-format result.
##
## Usage: ``trace_index_test_helper <scenario>``
## Scenarios: ``schema``, ``old-schema``, ``newid-uuidv7``, ``trace-recording-id``.

import std/[os, strutils, strformat]

when NimMajor >= 2:
  import ../db_connector/db_sqlite
else:
  import impure/db_sqlite

import recording_id
import types
import lang
import trace_index

proc fail(msg: string) =
  echo "FAIL: ", msg
  quit(1)

proc tableInfo(db: DBConn; name: string): seq[string] =
  ## Return ``column:TYPE`` strings for every column on ``table``.
  let rows = db.getAllRows(sql("PRAGMA table_info(" & name & ")"))
  for row in rows:
    result.add(row[1] & ":" & row[2])

proc indexNames(db: DBConn; table: string): seq[string] =
  let rows = db.getAllRows(sql("PRAGMA index_list(" & table & ")"))
  for row in rows:
    result.add(row[1])

proc tableExists(db: DBConn; name: string): bool =
  let rows = db.getAllRows(
    sql"SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    name)
  rows.len > 0

proc traceIndexDbPath(): string =
  ## Mirror ``paths.codetracerTraceDir`` so the test can locate the DB
  ## that ``trace_index`` just materialized.  ``paths.nim`` derives the
  ## path from ``getHomeDir()`` (= ``$HOME/.local/share/codetracer``)
  ## rather than ``XDG_DATA_HOME``, so we follow the same convention.
  getEnv("HOME") / ".local" / "share" / "codetracer" / "trace_index.db"

proc scenarioSchema() =
  ## Fresh tmpdir → newID materializes the DB → assert every required
  ## column and index exists, and that no legacy tables remain.
  let id = trace_index.newID(test = false)
  if id.len != 36:
    fail("newID returned len=" & $id.len & ": " & id)
  if not recording_id.isCanonicalUuidV7(id):
    fail("newID returned non-canonical UUIDv7: " & id)

  let dbPath = traceIndexDbPath()
  if not fileExists(dbPath):
    fail("expected DB at " & dbPath)
  var db = open(dbPath, "", "", "")
  defer: db.close()

  let recCols = tableInfo(db, "recordings")
  const required = [
    "recording_id:TEXT", "program:TEXT", "args:TEXT",
    "compile_command:TEXT", "env:TEXT", "workdir:TEXT", "output:TEXT",
    "source_folders:TEXT", "low_level_folder:TEXT", "output_folder:TEXT",
    "lang:INTEGER", "imported:INTEGER", "shell_id:INTEGER",
    "rr_pid:INTEGER", "exit_code:INTEGER", "calltrace:INTEGER",
    "calltrace_mode:TEXT", "recorded_at:TEXT",
    "remote_share_download_key:TEXT", "remote_share_control_id:TEXT",
    "remote_share_expire_time:INTEGER",
  ]
  for col in required:
    if col notin recCols:
      fail("recordings missing column " & col &
           " (have " & $recCols & ")")

  let recIdxs = indexNames(db, "recordings")
  if "idx_recordings_program" notin recIdxs:
    fail("missing idx_recordings_program (have " & $recIdxs & ")")
  if "idx_recordings_recorded_at" notin recIdxs:
    fail("missing idx_recordings_recorded_at (have " & $recIdxs & ")")

  let pidCols = tableInfo(db, "record_pid_recording_map")
  if "pid:INTEGER" notin pidCols or "recording_id:TEXT" notin pidCols:
    fail("record_pid_recording_map columns wrong: " & $pidCols)

  let folderCols = tableInfo(db, "recent_folders")
  if "id:INTEGER" notin folderCols or "path:TEXT" notin folderCols or
     "name:TEXT" notin folderCols or "last_opened:TEXT" notin folderCols:
    fail("recent_folders columns wrong: " & $folderCols)

  # Retired tables MUST be gone.
  if tableExists(db, "traces"):
    fail("legacy 'traces' table should not exist on fresh DB")
  if tableExists(db, "trace_values"):
    fail("legacy 'trace_values' table should not exist on fresh DB")
  if tableExists(db, "record_pid_trace_id_map"):
    fail("legacy 'record_pid_trace_id_map' should not exist on fresh DB")

  echo "PASS"

proc scenarioOldSchema() =
  ## Hand-build a pre-M-REC-2 DB → call newID → assert backup +
  ## fresh-schema DB.
  let dbPath = traceIndexDbPath()
  createDir(dbPath.parentDir)
  block:
    var db = open(dbPath, "", "", "")
    defer: db.close()
    db.exec(sql"CREATE TABLE traces (id integer, program text)")
    db.exec(sql("""CREATE TABLE trace_values (id integer, maxTraceID integer,
                                              UNIQUE(id))"""))
    db.exec(sql"INSERT INTO trace_values (id, maxTraceID) VALUES (0, 17)")
    db.exec(sql"INSERT INTO traces (id, program) VALUES (1, 'old-prog')")

  let id = trace_index.newID(test = false)
  if id.len != 36:
    fail("newID returned len=" & $id.len & ": " & id)

  if not fileExists(dbPath):
    fail("expected fresh DB at " & dbPath)
  let bakPath = dbPath & ".pre-m-rec-2.bak"
  if not fileExists(bakPath):
    fail("expected backup at " & bakPath)

  var db = open(dbPath, "", "", "")
  defer: db.close()
  if tableExists(db, "traces"):
    fail("'traces' table should not exist on recreated DB")
  if tableExists(db, "trace_values"):
    fail("'trace_values' table should not exist on recreated DB")
  if not tableExists(db, "recordings"):
    fail("'recordings' table missing on recreated DB")

  echo "PASS"

proc scenarioTraceRecordingId() =
  ## M-REC-3 acceptance: ``Trace.recordingId`` (renamed from ``Trace.id``)
  ## round-trips through ``recordTrace`` and ``find``.  The semantic
  ## rename only matters if the field is actually populated by the
  ## write path and read back by the read path, so we exercise both.
  let id = trace_index.newID(test = false)
  if id.len != 36:
    fail("newID returned len=" & $id.len & ": " & id)

  let recorded = trace_index.recordTrace(
    id,
    program = "/tmp/hello",
    args = @["arg1", "arg2"],
    compileCommand = "",
    env = "",
    workdir = "/tmp",
    lang = LangNoir,
    sourceFolders = "",
    lowLevelFolder = "",
    outputFolder = "/tmp/trace-" & id,
    test = false,
    imported = false,
    shellID = -1,
    rrPid = 12345,
    exitCode = 0,
    calltrace = true,
    calltraceMode = CalltraceMode.FullRecord)
  if recorded.isNil:
    fail("recordTrace returned nil")
  if recorded.recordingId != id:
    fail("Trace.recordingId not propagated: got " & recorded.recordingId &
         ", expected " & id)
  if recorded.program != "/tmp/hello":
    fail("Trace.program lost in recordTrace: " & recorded.program)

  let found = trace_index.find(id, test = false)
  if found.isNil:
    fail("find returned nil for freshly recorded id " & id)
  if found.recordingId != id:
    fail("find returned Trace with wrong recordingId: " & found.recordingId)
  if found.rrPid != 12345:
    fail("Trace.rrPid lost in find: " & $found.rrPid)

  echo "PASS"

proc scenarioNewIdUuidV7() =
  ## Two newID calls produce different canonical UUIDv7s and sort lex.
  let id1 = trace_index.newID(test = false)
  if id1.len != 36:
    fail("first newID returned len=" & $id1.len)
  if not recording_id.isCanonicalUuidV7(id1):
    fail("first newID non-canonical: " & id1)

  # Sleep past the next ms boundary so the embedded timestamp strictly
  # advances (RFC 9562 only guarantees inter-ms monotonicity for the
  # random sub-ms strategy this module uses).
  sleep(15)

  let id2 = trace_index.newID(test = false)
  if id2.len != 36:
    fail("second newID returned len=" & $id2.len)
  if not recording_id.isCanonicalUuidV7(id2):
    fail("second newID non-canonical: " & id2)
  if id1 == id2:
    fail("two newID calls returned the same id: " & id1)
  if id1 >= id2:
    fail("UUIDv7 ids should sort lex-ascending; got " & id1 &
         " >= " & id2)

  echo "PASS"

when isMainModule:
  if paramCount() < 1:
    fail("usage: trace_index_test_helper <scenario>")
  case paramStr(1)
  of "schema": scenarioSchema()
  of "old-schema": scenarioOldSchema()
  of "newid-uuidv7": scenarioNewIdUuidV7()
  of "trace-recording-id": scenarioTraceRecordingId()
  else:
    fail("unknown scenario: " & paramStr(1))
