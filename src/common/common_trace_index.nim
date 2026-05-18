# backend agnostic code, part of the trace_index module, should not be imported directly,
# use common/trace_index or frontend/trace_index instead.
#
# Schema for ``<codetracerTraceDir>/trace_index.db`` (M-REC-2).  See
# ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
# §5 for the parent design and the rationale for the snake_case rename.
#
# Pre-1.0 policy: there is no schema-migration path from the pre-M-REC-2
# integer-id schema.  ``ensureDB`` (in ``trace_index.nim``) detects an
# old-schema DB at startup, renames it to ``<path>.bak`` so the user can
# still recover individual recordings with ``ct replay <folder>``, and
# creates a fresh DB matching ``SQL_CREATE_TABLE_STATEMENTS`` below.
type
  CodetracerNotImplementedError* = object of ValueError

const
  ## Sentinel returned when a caller asks for "no recording id".  Pre-M-REC-2
  ## this was the integer ``-1``; now it is the empty string, which is never
  ## a valid UUIDv7 (the canonical form is always 36 chars).
  NO_TRACE_ID* = ""

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
      remote_share_expire_time INTEGER DEFAULT -1
  );""",
  """CREATE INDEX IF NOT EXISTS idx_recordings_program ON recordings(program);""",
  """CREATE INDEX IF NOT EXISTS idx_recordings_recorded_at ON recordings(recorded_at DESC);""",
  """CREATE TABLE IF NOT EXISTS record_pid_recording_map (
      pid INTEGER,
      recording_id TEXT NOT NULL,
      FOREIGN KEY (recording_id) REFERENCES recordings(recording_id)
  );""",
  """CREATE TABLE IF NOT EXISTS recent_folders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT UNIQUE,
      name TEXT,
      last_opened TEXT
  );""",
]
