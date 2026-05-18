# backend agnostic code, part of the trace_index module, should not be imported directly,
# use common/trace_index or frontend/trace_index instead.
#
# Schema reference: ~codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md~ §5.
# Column names are snake_case to follow SQLite norms; this is a hard break from the
# pre-M-REC-2 mixed-case schema (no backwards compatibility — see §5 of the spec).
type
  CodetracerNotImplementedError* = object of ValueError

const NO_TRACE_ID* = ""
  ## Sentinel value for "no recording_id" in API surface that allows it.
  ## Pre-M-REC-2 this was -1 (integer); now the empty string serves the same
  ## role for the string-typed recording id.  Producers that mean "mint a
  ## fresh id" should pass this value and call ``newID`` themselves.

### FREEZE for now the state of those
### schemas
### TODO:
###   eventually add ALTER statements
###   when we add new fields
###   as a minimal form of auto-migration
###   or implement a more advanced form of
###   migration logic/refactoring
###   (idea by Nikola)
### important: must keep in mind we
###   use indices for native nim
###   db row field extraction
###   so if we add/remove fields
###   we must update them accordingly

const SQL_CREATE_TABLE_STATEMENTS = @[
  """CREATE TABLE IF NOT EXISTS recordings (
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
      remote_share_expire_time INTEGER DEFAULT -1);""",
  """CREATE INDEX IF NOT EXISTS idx_recordings_program ON recordings(program);""",
  """CREATE INDEX IF NOT EXISTS idx_recordings_recorded_at ON recordings(recorded_at DESC);""",
  """CREATE TABLE IF NOT EXISTS record_pid_recording_map (
      pid INTEGER,
      recording_id TEXT NOT NULL,
      FOREIGN KEY (recording_id) REFERENCES recordings(recording_id));""",
  """CREATE TABLE IF NOT EXISTS recent_folders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT UNIQUE,
      name TEXT,
      last_opened TEXT);""",
]

# Pre-M-REC-2 the schema had a counter row that ``newID`` UPDATEd on every
# record-start.  The recording_id is now a UUIDv7 minted in-process, so the
# counter is gone — there are no initial inserts.
const SQL_INITIAL_INSERT_STATEMENTS: seq[string] = @[]

# Old `trace_index.db` shapes had to be patched with ALTER TABLE because the
# schema lived for a while in production-shaped dev environments.  M-REC-2
# starts fresh: ``ensureDB`` detects the old schema, renames the old file to
# ``trace_index.db.pre-m-rec-2.bak``, and recreates the DB from
# ``SQL_CREATE_TABLE_STATEMENTS``.  No ALTERs are needed.
const SQL_ALTER_TABLE_STATEMENTS*: seq[string] = @[]

# Marker query used to detect a pre-M-REC-2 schema.  ``trace_values`` is the
# table that held ``maxTraceID``; it exists only on old DBs and is dropped on
# M-REC-2.  If this query succeeds, the on-disk DB is the legacy shape and
# must be recreated.
const SQL_DETECT_OLD_SCHEMA* = "SELECT 1 FROM trace_values LIMIT 1"

# Suffix used when renaming a pre-M-REC-2 DB out of the way.  Kept distinct
# from ``.bak`` so manual recovery scripts can identify the source-of-change.
const OLD_SCHEMA_BACKUP_SUFFIX* = ".pre-m-rec-2.bak"
