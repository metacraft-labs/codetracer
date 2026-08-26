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
#
# That "recreate from scratch" policy covers *structural* drift only: it is
# driven by ``isOldSchemaDb``, which probes for the retired ``trace_values``
# table.  A change to the *meaning of a value* in an otherwise-identical
# schema is invisible to it.  ``TRACE_INDEX_SCHEMA_VERSION`` below (carried in
# SQLite's ``PRAGMA user_version``) is the mechanism for that second class of
# change; see ``trace_index.nim``'s "schema versioning" section.
type
  CodetracerNotImplementedError* = object of ValueError

const
  ## Sentinel returned when a caller asks for "no recording id".  Pre-M-REC-2
  ## this was the integer ``-1``; M-REC-2 flipped it to the empty string
  ## (never a valid UUIDv7) and M-REC-3 renamed the sentinel from
  ## ``NO_TRACE_ID`` to ``NO_RECORDING_ID`` to match the wider recording-id
  ## semantic cleanup.
  NO_RECORDING_ID* = ""

const
  TRACE_INDEX_SCHEMA_VERSION* = 1
    ## Value stamped into SQLite's ``PRAGMA user_version`` for a database
    ## that matches the schema in this file.  History:
    ##
    ## - **0** — every database written before the ``lang``-as-name change.
    ##   ``recordings.lang`` is declared ``INTEGER`` and holds ``ord(Lang)``.
    ##   Zero is the value SQLite reports for a database nobody ever
    ##   stamped, which is exactly what every pre-existing user database is,
    ##   so version 0 needs no backfill to be correct.
    ## - **1** — ``recordings.lang`` is declared ``TEXT`` and holds the
    ##   ``Lang`` enum *name* (``'LangElixir'``), not its ordinal.
    ##
    ## A database whose ``user_version`` is *greater* than this constant was
    ## written by a newer codetracer; ``migrateTraceIndex`` refuses to touch
    ## it rather than guessing.

  RECORDINGS_TABLE = "recordings"
    ## Live name of the recordings table.

  RECORDINGS_MIGRATION_TABLE = "recordings_schema_migration_scratch"
    ## Scratch table used by the SQLite "12-step ALTER TABLE" rebuild in
    ## ``trace_index.nim``.  Never present outside a migration transaction:
    ## the rebuild creates it, fills it, and renames it over
    ## ``recordings`` inside a single transaction, so a rollback removes it.

  ## The two halves of the ``recordings`` DDL, split so the table name can be
  ## substituted: the migration rebuild in ``trace_index.nim`` creates its
  ## scratch table from *this* definition rather than a hand-copied second
  ## one.  A migration whose target schema can drift from the canonical schema
  ## is a migration that quietly produces a database no later release
  ## recognises.
  ##
  ## Joined with ``&`` rather than ``strutils.%`` on purpose.  This file says
  ## at the top that it should not be imported directly — and
  ## ``src/ct/trace/replay.nim`` imports it directly anyway, as a module
  ## rather than through ``trace_index``.  In that translation unit nothing
  ## has imported ``strutils``, so a ``%`` here fails the whole ``ct`` build
  ## with ``undeclared identifier: '%'`` while every test that goes through
  ## ``trace_index`` (which does import ``strutils``) compiles fine.  ``&`` on
  ## strings is in ``system``, so it works in both roles and adds no import to
  ## a file whose whole point is not to carry any.
  SQL_CREATE_RECORDINGS_TABLE_HEAD = "CREATE TABLE IF NOT EXISTS "

  SQL_CREATE_RECORDINGS_TABLE_BODY = """ (
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
      lang TEXT NOT NULL,
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
    ## ``lang`` is ``TEXT NOT NULL`` and holds the ``Lang`` enum name.  It
    ## used to be ``INTEGER NOT NULL`` holding ``ord(Lang)``, which made the
    ## enum's *declaration order* a persisted, user-visible data format:
    ## inserting a variant anywhere but the end silently re-pointed every
    ## row above it.  ``NOT NULL`` is also load-bearing for the migration —
    ## it is the constraint that aborts the rebuild if any ordinal in the
    ## old database falls outside the ``Lang`` range (see the probe in
    ## ``langOrdinalToNameCaseSql``'s doc comment).

  SQL_CREATE_RECORDINGS_INDEX_STATEMENTS = @[
    """CREATE INDEX IF NOT EXISTS idx_recordings_program ON recordings(program);""",
    """CREATE INDEX IF NOT EXISTS idx_recordings_recorded_at ON recordings(recorded_at DESC);""",
  ]
    ## Re-run verbatim after the migration rebuild: ``DROP TABLE recordings``
    ## takes its indexes with it.  Note that neither index covers ``lang`` —
    ## nor does any query in this module filter, join or order on it — which
    ## is why widening it from INTEGER to TEXT costs nothing at read time.

proc sqlCreateRecordingsTable(tableName: string): string =
  ## The canonical ``recordings`` DDL, targeted at ``tableName``.  Used with
  ## ``RECORDINGS_TABLE`` for the live table and ``RECORDINGS_MIGRATION_TABLE``
  ## for the migration rebuild's scratch table, so both come from one source.
  SQL_CREATE_RECORDINGS_TABLE_HEAD & tableName & SQL_CREATE_RECORDINGS_TABLE_BODY

const SQL_CREATE_TABLE_STATEMENTS = @[
  sqlCreateRecordingsTable(RECORDINGS_TABLE),
] & SQL_CREATE_RECORDINGS_INDEX_STATEMENTS & @[
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
