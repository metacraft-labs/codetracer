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
## Scenarios: ``schema``, ``old-schema``, ``newid-uuidv7``,
## ``trace-recording-id``, ``short-prefix-unique``, ``short-prefix-ambiguous``,
## ``short-prefix-too-short``, ``short-prefix-not-found``,
## ``recent-folder-trailing-separators``, ``lang-name-roundtrip``,
## ``migrate-legacy-db``.

import std/[algorithm, options, os, strutils, strformat]

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
    # ``lang`` is TEXT since trace_index schema version 1: it stores the
    # ``Lang`` enum name, not ``ord(Lang)``.  See the "Schema versioning"
    # section of ``trace_index.nim``.
    "lang:TEXT", "imported:INTEGER", "shell_id:INTEGER",
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

proc insertRecording(id: string) =
  ## Persist a minimal recording row so the prefix scenarios can vary
  ## the ``recording_id`` without having to thread every column through
  ## ``recordTrace``.
  discard trace_index.recordTrace(
    id,
    program = "/tmp/short-prefix-" & id,
    args = @[],
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
    rrPid = 0,
    exitCode = 0,
    calltrace = false,
    calltraceMode = CalltraceMode.NoInstrumentation)

proc scenarioShortPrefixUnique() =
  ## M-REC-6: an 8+ hex-char prefix that matches exactly one recording
  ## resolves to that recording.  Insert ids with distinct first bytes
  ## so the prefix is unambiguous.
  discard trace_index.newID(test = false) # materialize the DB
  insertRecording("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb")
  insertRecording("01949f00-1111-7e9c-aaaa-cccccccccccc")
  insertRecording("019aaaaa-2222-7e9c-aaaa-dddddddddddd")
  let res = trace_index.findByRecordingIdPrefix("01949fcc", test = false)
  if not res.isOk:
    fail("expected unique match for '01949fcc'; error=" & $res.error &
         " matches=" & $res.matches)
  if res.trace.recordingId != "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb":
    fail("unique match resolved to wrong id: " & res.trace.recordingId)
  echo "PASS"

proc scenarioShortPrefixAmbiguous() =
  ## Two recordings share an 8-char prefix → ambiguity error with the
  ## candidate list.  The list is capped at
  ## ``RECORDING_ID_PREFIX_MATCH_CAP``.
  discard trace_index.newID(test = false)
  let ids = @[
    "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
    "01949fcc-8888-7e9c-aaaa-cccccccccccc",
    "01949fcc-9999-7e9c-aaaa-dddddddddddd",
  ]
  for id in ids:
    insertRecording(id)
  let res = trace_index.findByRecordingIdPrefix("01949fcc", test = false)
  if res.isOk:
    fail("expected ambiguity for '01949fcc'; got match " & res.trace.recordingId)
  if res.error != trace_index.rieAmbiguous:
    fail("expected rieAmbiguous; got " & $res.error)
  if res.matches.len != ids.len:
    fail("expected " & $ids.len & " candidate ids; got " & $res.matches)
  # The candidate list is ASC-ordered by recording_id.  Verify ids are
  # present and surfaced in stable order so the CLI error is reproducible.
  for id in ids:
    if id notin res.matches:
      fail("ambiguous match missing id " & id & "; got " & $res.matches)
  if res.matches != res.matches.sorted:
    fail("candidate list not sorted ASC: " & $res.matches)
  echo "PASS"

proc scenarioShortPrefixTooShort() =
  ## Prefix shorter than ``MIN_RECORDING_ID_PREFIX_LEN`` → ``rieTooShort``
  ## regardless of how many recordings match.
  discard trace_index.newID(test = false)
  insertRecording("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb")
  let res = trace_index.findByRecordingIdPrefix("01949f", test = false)
  if res.isOk:
    fail("expected too-short error for '01949f'; got " & res.trace.recordingId)
  if res.error != trace_index.rieTooShort:
    fail("expected rieTooShort; got " & $res.error)
  echo "PASS"

proc scenarioShortPrefixNotFound() =
  ## Valid 8+ char prefix that matches zero recordings → ``rieNotFound``.
  discard trace_index.newID(test = false)
  insertRecording("01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb")
  let res = trace_index.findByRecordingIdPrefix("ffffffff", test = false)
  if res.isOk:
    fail("expected not-found error for 'ffffffff'; got " & res.trace.recordingId)
  if res.error != trace_index.rieNotFound:
    fail("expected rieNotFound; got " & $res.error)
  echo "PASS"

proc scenarioRecentFolderTrailingSeparators() =
  ## Issue #575: ``addRecentFolder`` must strip a trailing path separator —
  ## POSIX ``/`` or Windows ``\`` — before it derives the folder's display
  ## name, otherwise the name comes out empty and the same folder is stored
  ## twice (once with the separator, once without).
  ##
  ## The three inputs cover the three shapes a caller can hand in: a POSIX
  ## path with a trailing slash, a Windows path with a trailing backslash,
  ## and an already-clean path that must be left alone.
  ##
  ## Both the stored ``path`` and the derived ``name`` are asserted.  Only
  ## checking the name would pass an implementation that derived the name
  ## correctly while persisting the unnormalized path — which is the half of
  ## the defect that produces duplicate rows.
  ##
  ## ``/tmp/test_dir1`` is then added a SECOND time without the trailing
  ## slash.  ``recent_folders.path`` is ``UNIQUE`` and the insert is
  ## ``INSERT OR REPLACE``, so once both spellings normalize to the same
  ## string the second add replaces the first and the row count stays at 3.
  ## Without the stripping the two spellings are different keys and the same
  ## folder occupies two rows — the duplicate half of #575, which the row
  ## count below is what actually observes.  Adding only the trailing-slash
  ## spelling could never observe it.
  discard trace_index.newID(test = false) # materialize the DB

  trace_index.addRecentFolder("/tmp/test_dir1/", test = false)
  trace_index.addRecentFolder("C:\\tmp\\test_dir2\\", test = false)
  trace_index.addRecentFolder("/tmp/test_dir3", test = false)
  trace_index.addRecentFolder("/tmp/test_dir1", test = false)

  let folders = trace_index.findRecentFolders(limit = 10, test = false)
  var nameByPath: seq[(string, string)] = @[]
  for f in folders:
    nameByPath.add((f.path, f.name))

  proc nameFor(path: string): string =
    for (p, n) in nameByPath:
      if p == path:
        return n
    ""

  for (path, expectedName) in [
      ("/tmp/test_dir1", "test_dir1"),
      ("C:\\tmp\\test_dir2", "test_dir2"),
      ("/tmp/test_dir3", "test_dir3")]:
    let actual = nameFor(path)
    if actual.len == 0:
      fail("recent_folders has no row for the normalized path " & path &
           "; stored rows: " & $nameByPath)
    if actual != expectedName:
      fail("recent_folders row " & path & " has name " & actual.escape() &
           ", expected " & expectedName.escape())

  # ``/tmp/test_dir1`` was added twice — with and without the trailing
  # separator.  Normalized, those are one folder and must occupy one row.
  if folders.len != 3:
    fail("expected exactly 3 recent folders (the two spellings of " &
         "/tmp/test_dir1 are one folder), got " & $folders.len &
         ": " & $nameByPath)

  echo "PASS"

# ---------------------------------------------------------------------------
# trace_index schema versions 1 and 2 — what recordings.lang holds
#
# Version 1 stored the ``Lang`` enum NAME (``'LangElixir'``).  Version 2
# (LRS-5) stores the FOUR-AXIS TOKEN (``'ex-beam-unknown-instrumented'``), or
# the bare sentinel ``'unknown'``.  The two steps compose: a version-0
# database written with ordinals runs 0 -> 1 -> 2 on the next open, which is
# what ``scenarioMigrateLegacyDb`` below drives through the real ``ensureDB``.
# ---------------------------------------------------------------------------

const LEGACY_LANG_ORDINAL_DDL = """CREATE TABLE IF NOT EXISTS recordings (
      recording_id TEXT PRIMARY KEY,
      program TEXT NOT NULL,
      args TEXT,
      compile_command TEXT,
      env TEXT,
      workdir TEXT,
      output TEXT,
      source_folders TEXT,
      low_level_folder TEXT,
      output_folder TEXT,
      lang INTEGER NOT NULL,
      imported INTEGER DEFAULT 0,
      shell_id INTEGER,
      rr_pid INTEGER,
      exit_code INTEGER,
      calltrace INTEGER,
      calltrace_mode TEXT,
      recorded_at TEXT NOT NULL,
      remote_share_download_key TEXT,
      remote_share_control_id TEXT,
      remote_share_expire_time INTEGER DEFAULT -1
  );"""
  ## A frozen copy of the schema-version-0 ``recordings`` DDL.  It is a
  ## deliberate duplicate of what ``common_trace_index.nim`` used to say: a
  ## migration test that derived the *old* shape from the *current* source
  ## would stop testing the migration the moment the current source changed.

proc scenarioLangNameRoundTrip() =
  ## The production write path stores the four-axis TOKEN, the production
  ## read path reads it back as the same ``Lang``, and the freshly-created
  ## database is stamped at the current schema version.
  ##
  ## ``LangElixir`` is used on purpose: it is ordinal 37, a value the live
  ## developer database actually holds, and one that any reordering of the
  ## enum would re-point.  The scenario keeps its name (the suite refers to
  ## it by that string); what it asserts moved from the NAME to the token
  ## when schema version 2 landed.
  let id = trace_index.newID(test = false)
  discard trace_index.recordTrace(
    id,
    program = "/tmp/lang-name-roundtrip",
    args = @[],
    compileCommand = "",
    env = "",
    workdir = "/tmp",
    lang = LangElixir,
    sourceFolders = "",
    lowLevelFolder = "",
    outputFolder = "/tmp/trace-" & id,
    test = false,
    imported = false,
    shellID = -1,
    rrPid = 0,
    exitCode = 0,
    calltrace = false,
    calltraceMode = CalltraceMode.NoInstrumentation)

  var db = open(traceIndexDbPath(), "", "", "")
  defer: db.close()

  let raw = db.getValue(
    sql"SELECT lang FROM recordings WHERE recording_id = ?", id)
  # Written as a LITERAL rather than as `langToColumnValue(LangElixir)`: a
  # test that asked the production encoder what the production writer should
  # have written would agree with it by construction.
  if raw != "ex-beam-unknown-instrumented":
    fail("recordings.lang should hold the four-axis token " &
         "'ex-beam-unknown-instrumented'; got " & raw.escape())
  let version = db.getValue(sql"PRAGMA user_version")
  if version != $TRACE_INDEX_SCHEMA_VERSION:
    fail("fresh DB should be stamped at schema version " &
         $TRACE_INDEX_SCHEMA_VERSION & "; PRAGMA user_version = " & version)
  let declaredType = db.getValue(
    sql"SELECT type FROM pragma_table_info('recordings') WHERE name = 'lang'")
  if declaredType != "TEXT":
    fail("recordings.lang should be declared TEXT; got " & declaredType)

  let found = trace_index.find(id, test = false)
  if found.isNil:
    fail("find returned nil for " & id)
  if found.lang != LangElixir:
    fail("find decoded lang as " & $found.lang & ", expected LangElixir")

  echo "PASS"

proc scenarioRetiredLangRows() =
  ## LRS-4 deleted `LangPython` and `LangRuby`, and LRS-5's second deletion
  ## round deleted `LangRustWasm`, `LangCppWasm`, `LangPolkavm` and
  ## `LangSolana`; a `trace_index.db` written by an older build can still hold
  ## any of those NAMES in `recordings.lang`.  Through the PRODUCTION loader
  ## (`find`, `all`, `findRecentTraces`) such a row must keep the name in
  ## `langRetiredName`, must keep its label, and must not stop the rows beside
  ## it from loading (design §5.6; `decodeLangColumn`).  The rows are written
  ## with raw SQL because no production writer can spell a retired name any
  ## more -- that is what "retired" means.
  ##
  ## Still true, and deliberately unchanged, after schema version 2: a
  ## version-1 NAME is still decoded by ``decodeLangColumn``'s legacy branch,
  ## because a row written by an older build must not become a hard failure
  ## at open just because the column's live format moved on.
  ##
  ## **What LRS-5's second deletion round changed here, deliberately:** the
  ## summary is now the cell's LANGUAGE axis, so a retired `LangRuby` row
  ## loads as `LangRubyDb` (it IS a Ruby recording) rather than as the
  ## sentinel, and a retired `LangRustWasm` row loads as `LangRust` with
  ## `Trace.approach == raVmEmulation`.  Nothing is lost -- the label is still
  ## the retired name, asserted below -- and the row keeps its highlighting
  ## and its replay behaviour instead of degrading to "unknown".
  let live = trace_index.newID(test = false)
  insertRecording(live)
  let retiredRuby = trace_index.newID(test = false)
  insertRecording(retiredRuby)
  let retiredPython = trace_index.newID(test = false)
  insertRecording(retiredPython)
  let retiredWasm = trace_index.newID(test = false)
  insertRecording(retiredWasm)
  block:
    var db = open(traceIndexDbPath(), "", "", "")
    defer: db.close()
    db.exec(sql"UPDATE recordings SET lang = ? WHERE recording_id = ?",
            "LangRuby", retiredRuby)
    db.exec(sql"UPDATE recordings SET lang = ? WHERE recording_id = ?",
            "LangPython", retiredPython)
    db.exec(sql"UPDATE recordings SET lang = ? WHERE recording_id = ?",
            "LangRustWasm", retiredWasm)
    for (id, expected) in [(retiredRuby, "LangRuby"),
                           (retiredPython, "LangPython"),
                           (retiredWasm, "LangRustWasm")]:
      let raw = db.getValue(
        sql"SELECT lang FROM recordings WHERE recording_id = ?", id)
      if raw != expected:
        fail("fixture: recordings.lang should hold " & expected & "; got " & raw.escape())

  for (id, name, summary) in [(retiredRuby, "LangRuby", LangRubyDb),
                              (retiredPython, "LangPython", LangPythonDb),
                              (retiredWasm, "LangRustWasm", LangRust)]:
    let found = trace_index.find(id, test = false)
    if found.isNil:
      fail("find returned nil for the retired row " & id)
    if found.lang != summary:
      fail("retired row " & name & " decoded to " & $found.lang &
           ", expected " & $summary)
    if found.langRetiredName != name:
      fail("retired row " & name & " kept langRetiredName " &
           found.langRetiredName.escape() & ", expected " & name)
    if found.langLabel != name:
      fail("retired row " & name & " labels as " & found.langLabel & ", expected " & name)

  # THE assertion the second deletion round turns on: a row recorded under
  # `LangRustWasm` still replays as a MATERIALIZED recording in a build that
  # has no such member.  The approach comes from the frozen version-2 target
  # of the retired name, not from the summary -- which is `LangRust`, and
  # `usesMaterializedTraces(LangRust)` is `false`.
  block:
    let wasmRow = trace_index.find(retiredWasm, test = false)
    if wasmRow.approach != raVmEmulation:
      fail("retired row LangRustWasm has approach " & $wasmRow.approach &
           ", expected raVmEmulation")
    if not wasmRow.usesMaterializedTraces:
      fail("retired row LangRustWasm must still replay as a materialized trace")
    if usesMaterializedTraces(wasmRow.lang):
      fail("the Lang summary must NOT be what answers this -- " &
           "usesMaterializedTraces(LangRust) is expected to be false")
    # (The stored `calltrace_mode` cell of this fixture row is non-empty, so
    # `loadCalltraceMode`'s DEFAULT -- the fourth of the four sites -- is not
    # exercised here; `trace_index_migration_test` asserts it directly against
    # the decoded axes, which is where an empty cell is reachable.)

  let liveTrace = trace_index.find(live, test = false)
  if liveTrace.isNil or liveTrace.lang != LangNoir or liveTrace.langRetiredName.len > 0:
    fail("the live row beside the retired ones must still decode as LangNoir")

  # The listings that a retired row used to be able to take down.
  let everything = trace_index.all(test = false)
  var seen = 0
  for t in everything:
    if t.recordingId in [live, retiredRuby, retiredPython, retiredWasm]:
      inc seen
  if seen != 4:
    fail("all() returned " & $seen & " of the 4 rows; a retired name must not hide a row")
  let recent = trace_index.findRecentTraces(10, test = false)
  var labels: seq[string] = @[]
  for t in recent:
    labels.add(t.langLabel)
  if "LangRuby" notin labels or "LangPython" notin labels or
     "LangRustWasm" notin labels or "LangNoir" notin labels:
    fail("findRecentTraces labels were " & $labels &
         "; expected LangRuby, LangPython, LangRustWasm and LangNoir among them")

  # Nothing rewrote the cells: the raw names stay on disk for LRS-5's remap.
  block:
    var db = open(traceIndexDbPath(), "", "", "")
    defer: db.close()
    if db.getValue(sql"SELECT lang FROM recordings WHERE recording_id = ?",
                   retiredRuby) != "LangRuby":
      fail("the retired cell was rewritten; it must stay LangRuby on disk")
    if db.getValue(sql"SELECT lang FROM recordings WHERE recording_id = ?",
                   retiredWasm) != "LangRustWasm":
      fail("the retired cell was rewritten; it must stay LangRustWasm on disk")

  echo "PASS"

proc scenarioMigrateLegacyDb() =
  ## The end-to-end gate on ``ensureDB``: a hand-built schema-version-0
  ## database sitting at the real path is migrated on the next open, without
  ## the caller asking, and the rows survive with their language intact.
  ##
  ## This is the scenario the in-process tests cannot cover, because it is the
  ## *wiring* — a migration that is correct but never called is worth nothing.
  let dbPath = traceIndexDbPath()
  createDir(dbPath.parentDir)
  block:
    var db = open(dbPath, "", "", "")
    defer: db.close()
    db.exec(sql"PRAGMA journal_mode=WAL;")
    db.exec(sql(LEGACY_LANG_ORDINAL_DDL))
    db.exec(sql"""CREATE TABLE IF NOT EXISTS record_pid_recording_map (
        pid INTEGER,
        recording_id TEXT NOT NULL,
        FOREIGN KEY (recording_id) REFERENCES recordings(recording_id));""")
    db.exec(sql"""CREATE TABLE IF NOT EXISTS recent_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE, name TEXT, last_opened TEXT);""")
    # 37 = LangElixir, 0 = LangC, 22 = LangUnknown.  The last two are the pair
    # the pending reorder swaps, so they are the pair a value-blind renumber
    # would silently exchange.
    for (id, ordinal) in [
        ("01949fcc-7d92-7e9c-aaaa-00000000ex01", 37),
        ("01949fcc-7d92-7e9c-aaaa-00000000c001", 0),
        ("01949fcc-7d92-7e9c-aaaa-0000000unk22", 22)]:
      db.exec(sql"""INSERT INTO recordings
        (recording_id, program, args, compile_command, env, workdir, output,
         source_folders, low_level_folder, output_folder, lang, imported,
         shell_id, rr_pid, exit_code, calltrace, calltrace_mode, recorded_at)
        VALUES (?, ?, '', '', '', '/tmp', '', '', '', ?, ?, 0,
                -1, 0, 0, 0, 'NoInstrumentation', '2026/08/25')""",
        id, "/tmp/legacy-" & id, "/tmp/trace-" & id, $ordinal)
    if db.getValue(sql"PRAGMA user_version") != "0":
      fail("hand-built legacy DB should be at user_version 0")

  # Opening the index at all must migrate it.
  discard trace_index.newID(test = false)

  var db = open(dbPath, "", "", "")
  defer: db.close()
  if db.getValue(sql"PRAGMA user_version") != $TRACE_INDEX_SCHEMA_VERSION:
    fail("legacy DB not stamped after ensureDB; PRAGMA user_version = " &
         db.getValue(sql"PRAGMA user_version"))
  # 0 -> 1 -> 2 composed: the ordinals became names and the names became
  # four-axis tokens, in one `ensureDB` open.  `LangUnknown` becomes the BARE
  # sentinel, not `unknown-unknown-unknown-unknown` (design Q3).
  for (id, expected) in [
      ("01949fcc-7d92-7e9c-aaaa-00000000ex01", "ex-beam-unknown-instrumented"),
      ("01949fcc-7d92-7e9c-aaaa-00000000c001", "c-native-unknown-mcr"),
      ("01949fcc-7d92-7e9c-aaaa-0000000unk22", "unknown")]:
    let raw = db.getValue(
      sql"SELECT lang FROM recordings WHERE recording_id = ?", id)
    if raw != expected:
      fail("row " & id & ": expected lang " & expected & ", got " & raw.escape())

  let found = trace_index.find("01949fcc-7d92-7e9c-aaaa-00000000ex01", test = false)
  if found.isNil:
    fail("find returned nil for the migrated Elixir row")
  if found.lang != LangElixir:
    fail("migrated row decoded as " & $found.lang & ", expected LangElixir")

  # Both steps ran, so BOTH snapshots are on disk: restoring the first gives
  # back the original version-0 file, restoring the second a working
  # version-1 one.
  if not fileExists(dbPath & langNameMigrationBakSuffix):
    fail("expected a pre-migration snapshot at " &
         dbPath & langNameMigrationBakSuffix)
  if not fileExists(dbPath & langTokenMigrationBakSuffix):
    fail("expected a pre-remap snapshot at " &
         dbPath & langTokenMigrationBakSuffix)

  echo "PASS"

proc scenarioObservedAxesRoundTrip() =
  ## **LRS-5's second deletion round, precondition (b), asserted on the CELL
  ## rather than on the source text.**
  ##
  ## Deleting `LangRustWasm` removed the only way a one-`Lang` column could
  ## say "this Rust recording is a wasm one".  What replaces it is
  ## `recordTrace`'s `axesArg`: the record side passes the axes the assessment
  ## observed, and the column stores all four.  Get that wrong and `ct record`
  ## writes `rs-native-unknown-mcr` for a wasm recording -- a correct reader
  ## of a wrong cell, which is the silent mislabel the whole deferral existed
  ## to prevent, and which no amount of DECODER testing can catch.
  ##
  ## Added at review.  The suite already pinned this half by reading
  ## `db_backend_record.nim` and `storage_and_import.nim` as TEXT and checking
  ## for the `axesArg` substrings (`target_axes_test.nim`, "recordTrace
  ## persists the OBSERVED axes when the caller has them").  A source grep
  ## dies to a reformat and says nothing about what lands on disk; this drives
  ## the production writer and the production loader against a real SQLite
  ## database and reads the row back.
  let wasmAxes = TargetAxes(language: slRust, targetIsa: tiWasm,
                            toolchain: tcUnknown, approach: raVmEmulation)
  let wasmId = trace_index.newID(test = false)
  discard trace_index.recordTrace(
    wasmId,
    program = "/tmp/wasmdemo.wasm",
    args = @[], compileCommand = "", env = "", workdir = "/tmp",
    lang = LangRust,                      # the SUMMARY: a wasm Rust recording
    sourceFolders = "", lowLevelFolder = "",
    outputFolder = "/tmp/trace-" & wasmId,
    test = false, imported = false, shellID = -1, rrPid = 0, exitCode = 0,
    calltrace = true, calltraceMode = CalltraceMode.FullRecord,
    axesArg = some(wasmAxes))

  # The same summary with NO observed axes -- what every caller wrote before
  # this milestone, and what `recordDb` would write again if the plumbing were
  # reverted.  It is a NATIVE cell, and that is the mislabel.
  let nativeId = trace_index.newID(test = false)
  discard trace_index.recordTrace(
    nativeId,
    program = "/tmp/native-crate", args = @[], compileCommand = "", env = "",
    workdir = "/tmp", lang = LangRust, sourceFolders = "", lowLevelFolder = "",
    outputFolder = "/tmp/trace-" & nativeId,
    test = false, imported = false, shellID = -1, rrPid = 0, exitCode = 0,
    calltrace = true, calltraceMode = CalltraceMode.FullRecord)

  block:
    var db = open(traceIndexDbPath(), "", "", "")
    defer: db.close()
    let wasmCell = db.getValue(
      sql"SELECT lang FROM recordings WHERE recording_id = ?", wasmId)
    if wasmCell != "rs-wasm-unknown-vm":
      fail("the observed axes must reach the column: recordings.lang is " &
           wasmCell.escape() & ", expected rs-wasm-unknown-vm")
    let nativeCell = db.getValue(
      sql"SELECT lang FROM recordings WHERE recording_id = ?", nativeId)
    if nativeCell != "rs-native-unknown-mcr":
      fail("a summary-only write must stay the language's default cell; got " &
           nativeCell.escape())

  # ...and the production loader reads it back as a MATERIALIZED recording,
  # with no `Lang` member anywhere in the chain able to say so: the summary is
  # `LangRust`, whose own `usesMaterializedTraces` is false.
  let wasmRow = trace_index.find(wasmId, test = false)
  if wasmRow.isNil:
    fail("find returned nil for the wasm row")
  if wasmRow.lang != LangRust:
    fail("the wasm row summarises as " & $wasmRow.lang & ", expected LangRust")
  if wasmRow.approach != raVmEmulation:
    fail("the wasm row loaded approach " & $wasmRow.approach &
         ", expected raVmEmulation")
  if not wasmRow.usesMaterializedTraces:
    fail("a wasm recording must replay as a materialized trace")
  if usesMaterializedTraces(wasmRow.lang):
    fail("the Lang summary must NOT be what answers this")
  let nativeRow = trace_index.find(nativeId, test = false)
  if nativeRow.approach != raMcr:
    fail("the native row loaded approach " & $nativeRow.approach &
         ", expected raMcr")
  if nativeRow.usesMaterializedTraces:
    fail("a native Rust recording must not replay as a materialized trace")

  echo "PASS"

when isMainModule:
  if paramCount() < 1:
    fail("usage: trace_index_test_helper <scenario>")
  case paramStr(1)
  of "schema": scenarioSchema()
  of "old-schema": scenarioOldSchema()
  of "newid-uuidv7": scenarioNewIdUuidV7()
  of "trace-recording-id": scenarioTraceRecordingId()
  of "short-prefix-unique": scenarioShortPrefixUnique()
  of "short-prefix-ambiguous": scenarioShortPrefixAmbiguous()
  of "short-prefix-too-short": scenarioShortPrefixTooShort()
  of "short-prefix-not-found": scenarioShortPrefixNotFound()
  of "recent-folder-trailing-separators": scenarioRecentFolderTrailingSeparators()
  of "lang-name-roundtrip": scenarioLangNameRoundTrip()
  of "migrate-legacy-db": scenarioMigrateLegacyDb()
  of "retired-lang-rows": scenarioRetiredLangRows()
  of "observed-axes-round-trip": scenarioObservedAxesRoundTrip()
  else:
    fail("unknown scenario: " & paramStr(1))
