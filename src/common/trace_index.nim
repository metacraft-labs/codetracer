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

# ---------------------------------------------------------------------------
# Schema versioning, and the ``lang`` ordinal → name migration
# ---------------------------------------------------------------------------
#
# ``isOldSchemaDb`` above answers one question: "is this database's *shape*
# from before M-REC-2?".  It answers it by probing for a table that no longer
# exists.  That works for a structural change and is useless for a change to
# the *meaning* of a value in a column that still has the same name and the
# same type — which is precisely what happened to ``recordings.lang``.
#
# ``lang`` used to be ``INTEGER NOT NULL`` holding ``ord(Lang)``.  That made
# the *declaration order* of a Nim enum into a persisted user-data format:
# inserting a variant anywhere but at the end silently re-pointed every stored
# row above it, with no error and no way for either side to notice.  The
# concrete trigger was the then-pending move of ``LangUnknown`` to ordinal 0
# (it was 22, while ``LangC`` was 0 — so Nim's zero-initialised ``result``
# meant "C", not "unknown", in any proc that fell off its end).  That move
# LANDED in LRS-4 on 2026-09-21, against a column that by then held names:
# which is the whole point of having done this first.
#
# This is not hypothetical.  A live developer database read (read-only, from a
# copy) on 2026-08-25 held 247 rows at exactly five ordinals: ``0`` ×3
# (``LangC``), ``14`` ×46 (``LangRubyDb``), ``15`` ×71 (``LangJavascript``),
# ``21`` ×101 (``LangPythonDb``) and ``37`` ×26 (``LangElixir``).  Inserting
# ``LangUnknown`` at 0 shifts every later variant up by one, so a renumber
# without this migration would have relabelled **all 247** of those rows —
# every C recording read back as "unknown", every Ruby recording as plain
# ``LangRuby``, and so on — with no error at any layer.
#
# The row count itself is volatile (ordinary development writes to that file;
# three readings during earlier work on this initiative gave 24, 25 and 26).
# The claim that matters is the shape: real rows, at high ordinals, that a
# renumber silently re-points.
#
# Two mechanisms are introduced here.
#
# **1. A schema version, carried in SQLite's ``PRAGMA user_version``.**
# Considered and rejected: a ``schema_version`` *column* on ``recordings``
# (wrong granularity — the property belongs to the database, not to a row, and
# nothing would keep the rows agreeing), and a dedicated ``schema_info`` table
# (needs its own bootstrap ordering relative to ``SQL_CREATE_TABLE_STATEMENTS``,
# and adds query surface for a single integer).  ``user_version`` wins on three
# properties that matter here:
#
#   - It is a 32-bit slot in the database *header*, so it exists before any
#     table does and reads without a schema.
#   - It reads back **0** for every database nobody ever stamped.  Every
#     pre-existing user database is therefore already correctly labelled
#     "version 0" with no backfill and no ambiguity.
#   - It is an ordinary page write, so it is **transactional** — it commits and
#     rolls back with the statements around it.  Verified on SQLite 3.50.4
#     rather than assumed; ``trace_index_migration_test.nim`` re-verifies it on
#     every run, because the all-or-nothing property below rests on it.
#
# It composes with ``isOldSchemaDb`` rather than replacing it: the structural
# archive-and-recreate runs first in ``ensureDB`` (it deletes the file, so
# migrating it would be wasted work), and the version gate then runs on
# whatever database results.  A downgrade is handled explicitly: a database
# whose ``user_version`` is *greater* than ``TRACE_INDEX_SCHEMA_VERSION`` is
# refused, loudly, instead of being read with the wrong assumptions.  A
# codetracer older than this change has no such guard — but it will read a
# name where it expects an integer and fail loudly in ``loadTrace`` rather than
# silently decoding the wrong language, which is strictly better than what an
# ordinal renumber would have done to it.
#
# **2. The column now stores the enum NAME.**  ``'LangElixir'``, not ``37``.
# This is a one-way door and is meant to be: after it, the ``Lang``
# declaration order is no longer a data format, the pending reorder touches no
# persisted data, and this is the last migration this column needs.  It costs
# nothing at read time — no query in this module filters, joins, orders or
# indexes on ``lang``; the only read is positional (``trace[10]``).  The same
# ordinal-to-name move was already made for the ``ct/load-locals`` DAP wire
# (see ``src/db-backend/src/query.rs``: *"ordinal leaked onto the wire"*), so
# this brings the persisted form in line with the wire form.

type
  TraceIndexSchemaError* = object of CatchableError
    ## The local recordings database does not match the schema this build
    ## expects, and the mismatch is not something a read can paper over.

  TraceIndexMigrationError* = object of TraceIndexSchemaError
    ## Raised by ``migrateTraceIndex`` when the database cannot be brought to
    ## ``TRACE_INDEX_SCHEMA_VERSION`` safely.  Every raise site names the
    ## check that failed.  It is never raised after a partial write: see
    ## ``applyLangNameMigration``.

const
  traceIndexMigrationFaultEnv* = "CODETRACER_TEST_TRACE_INDEX_MIGRATION_FAULT"
    ## **Test-only.**  Set to a fault-point name to make the migration raise
    ## at that point, so a test can prove the rollback rather than assert it.
    ## Unset (the normal case) costs one ``getEnv`` per fault point.  There is
    ## no other way to observe a mid-transaction abort from outside the
    ## process, and "the rollback works" is the single claim this change most
    ## needs to demonstrate rather than assert.
    ## Recognised points, in execution order.  **Version 0 → 1** (the table
    ## rebuild):
    ##   ``after-table-rewrite`` — scratch table filled, original untouched.
    ##   ``after-table-swap``    — original dropped, scratch renamed over it,
    ##                             indexes rebuilt.  Mid-transaction the
    ##                             database *is* migrated; a rollback here is
    ##                             the strongest available proof.
    ##   ``after-version-stamp`` — ``user_version`` written, not yet committed.
    ## **Version 1 → 2** (the value remap), added by LRS-5 so the newer step
    ## carries the same proof rather than inheriting the older step's:
    ##   ``after-token-remap``        — every cell rewritten from the name to
    ##                                  the four-axis token, not yet committed.
    ##                                  This is the 1 → 2 analogue of
    ##                                  ``after-table-swap``: mid-transaction
    ##                                  the column IS migrated.
    ##   ``after-token-version-stamp`` — ``user_version`` written to 2, not yet
    ##                                  committed.
    ##
    ## A step-specific name rather than a shared one on purpose: the 0 → 1 and
    ## 1 → 2 steps run back to back in the same call for a version-0 database,
    ## and a fault point named ``after-version-stamp`` for both would fire in
    ## the first step and never exercise the second.

  langNameMigrationBakSuffix* = ".pre-lang-name-migration.bak"
    ## Snapshot taken with ``VACUUM INTO`` immediately before the 0 → 1
    ## rebuild.  The transaction already makes the migration all-or-nothing
    ## against a crash or an error; the snapshot covers the case the
    ## transaction cannot — a migration that *succeeds* atomically while being
    ## logically wrong.  SQLite refuses to overwrite an existing
    ## ``VACUUM INTO`` target, so the suffix is bumped rather than a previous
    ## snapshot clobbered.

  langTokenMigrationBakSuffix* = ".pre-lang-token-migration.bak"
    ## The same, for the 1 → 2 value remap, and with its own suffix so a
    ## version-0 database that runs 0 → 1 → 2 in one call leaves **two**
    ## snapshots — one per step — rather than one step's snapshot being
    ## mistaken for the other's.  Restoring the 1 → 2 snapshot gives back a
    ## working version-1 database; restoring the 0 → 1 one gives back the
    ## original version-0 file.

proc migrationFault(point: string) =
  ## See ``traceIndexMigrationFaultEnv``.
  if getEnv(traceIndexMigrationFaultEnv) == point:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: injected fault at fault-point '" & point &
      "' (" & traceIndexMigrationFaultEnv & ")")

proc readSchemaVersion*(db: DBConn): int =
  ## Read ``PRAGMA user_version``.  Absent/unstamped reads back as 0, which is
  ## the pre-migration version; see ``TRACE_INDEX_SCHEMA_VERSION``.
  let raw = db.getValue(sql"PRAGMA user_version")
  if raw.len == 0:
    return 0
  try:
    raw.parseInt
  except ValueError:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: PRAGMA user_version returned " & raw.escape() &
      ", which is not an integer")

proc writeSchemaVersion*(db: DBConn; version: int) =
  ## ``PRAGMA`` does not accept bound parameters, so the value is
  ## interpolated; it is an ``int`` this module owns, never user input.
  db.exec(sql("PRAGMA user_version = " & $version))

proc tableExistsIn(db: DBConn; name: string): bool =
  db.getAllRows(
    sql"SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    name).len > 0

proc columnDefs(db: DBConn; table: string): seq[(string, string)] =
  ## ``(name, DECLARED TYPE)`` for every column of ``table``, in schema order.
  ## ``table`` is always one of this module's own constants.
  result = @[]
  for row in db.getAllRows(sql("PRAGMA table_info(" & table & ")")):
    result.add((row[1], row[2].toUpperAscii))

proc columnNames(defs: seq[(string, string)]): seq[string] =
  defs.mapIt(it[0])

proc declaredTypeOf(defs: seq[(string, string)]; column: string): string =
  for def in defs:
    if def[0] == column:
      return def[1]
  ""

# ---------------------------------------------------------------------------
# The frozen schema-version-0 ordinal → name table
# ---------------------------------------------------------------------------
#
# **A snapshot of a retired enum.  Never regenerate this from ``Lang``.**
#
# ``langV0OrdinalNames`` below is the ordinal → name mapping that schema
# version 0 databases were written against: ``Lang`` exactly as it stood while
# version-0 rows were being inserted.  It is a literal, and it is deliberately
# typed ``array[40, (int, string)]`` rather than ``array[Lang, string]`` or
# anything else that mentions ``Lang``, so that it keeps compiling — and keeps
# decoding old databases correctly — after ``Lang`` is renumbered, reordered
# or shrunk.
#
# This replaces a generator that built the same table with
# ``for lang in Lang: … $ord(lang) … $lang``, whose doc comment claimed that
# deriving it from the enum meant "the mapping cannot drift from the enum it
# maps".  **That reasoning was inverted.**  The thing being decoded is not a
# value of the current enum: it is an integer written to disk by an *older*
# build.  Deriving the decode table from the *current* enum is precisely what
# makes it drift, because the two are pinned together only by the coincidence
# that nobody has renumbered ``Lang`` yet.  On the first renumber a version-0
# database's ``lang = 21`` would decode against the new order and silently
# mislabel every Python recording — the exact defect this migration exists to
# prevent, reintroduced by the migration's own generator.  Nothing is wrong
# today; freezing the table is what makes that a recorded fact rather than a
# coincidence.
#
# Deliverable of milestone LRS-0 in
# ``codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.md`` §6.1,
# whose series rule 3 states that any mapping from a *historical* encoding must
# be a frozen literal annotated as a snapshot of a retired enum, and must never
# be generated from the live enum by iterating it.
#
# Entries are never removed, not even for a ``Lang`` member that is later
# deleted: a version-0 database on disk still holds that ordinal, and the name
# is what the migration must write.  ``langFromColumnValue`` then reads that
# name back through ``parseEnum[Lang]`` — which is why deleting members is a
# separate, later problem (LRS-4), and why this table must outlive them.
# Entries are never renumbered.  Appending would only be correct for a variant
# added to ``Lang`` *before* schema version 1 shipped, which is no longer
# possible, so in practice this table is closed.
#
# ``src/tests/cli/trace_index_migration_test.nim`` asserts its shape — 40
# entries, ordinals 0..39, no repeated ordinal, no repeated name — without
# mentioning ``Lang``, so those assertions still hold after ``Lang`` shrinks.
const
  langV0OrdinalNames*: array[40, tuple[ordinal: int, name: string]] = [
    (0, "LangC"),
    (1, "LangCpp"),
    (2, "LangRust"),
    (3, "LangNim"),
    (4, "LangGo"),
    (5, "LangPascal"),
    (6, "LangFortran"),
    (7, "LangD"),
    (8, "LangCrystal"),
    (9, "LangLean"),
    (10, "LangJulia"),
    (11, "LangAda"),
    (12, "LangPython"),
    (13, "LangRuby"),
    (14, "LangRubyDb"),
    (15, "LangJavascript"),
    (16, "LangLua"),
    (17, "LangAsm"),
    (18, "LangNoir"),
    (19, "LangRustWasm"),
    (20, "LangCppWasm"),
    (21, "LangPythonDb"),
    (22, "LangUnknown"),
    (23, "LangBash"),
    (24, "LangZsh"),
    (25, "LangSolidity"),
    (26, "LangMasm"),
    (27, "LangSway"),
    (28, "LangMove"),
    (29, "LangPolkavm"),
    (30, "LangCairo"),
    (31, "LangCircom"),
    (32, "LangLeo"),
    (33, "LangTolk"),
    (34, "LangAiken"),
    (35, "LangCadence"),
    (36, "LangSolana"),
    (37, "LangElixir"),
    (38, "LangErlang"),
    (39, "LangPhp"),
  ]

# The legal version-0 ordinal range, derived at compile time from the frozen
# table above and **not** from ``ord(low(Lang))`` / ``ord(high(Lang))``.  Those
# describe today's enum, not the one that wrote the data: ``ord(high(Lang))``
# is 39 today and becomes 35 after the language/recording-type split, which
# would start rejecting perfectly valid stored ordinals 36..39 as "out of
# range" — and, worse, would do so only after the ``CASE`` had already been
# built from the wrong list.  These bounds are 0 and 39 forever.
const
  langV0MinOrdinal* = static:
    var lo = langV0OrdinalNames[0].ordinal
    for entry in langV0OrdinalNames:
      if entry.ordinal < lo: lo = entry.ordinal
    lo

  langV0MaxOrdinal* = static:
    var hi = langV0OrdinalNames[0].ordinal
    for entry in langV0OrdinalNames:
      if entry.ordinal > hi: hi = entry.ordinal
    hi

# `Lang` is TEXT in every `json_serialization` encoding, not only in the
# persisted column (LRS-4, 2026-09-21).
#
# The vendored `json_serialization` writes an enum as `ord(value)` unless the
# type opts into text with `serializesAsTextInJson`.  Until this line
# `ct trace-metadata` (`src/ct/trace/metadata.nim`, `Json.encode(trace)`) put
# the INTEGER ordinal of `Trace.lang` on the hop to the Electron main process
# -- while the renderer's own comment, the inventory in
# Language-Enum-Ordinal-Contracts.md and the LRS series all believed that hop
# carried the name (the renderer's old `var LANG = {…}` map only ran for
# `typeof t.lang === 'string'`; the integer fell through `cast[Trace]`
# unchecked).  Found while collecting LRS-4's replay evidence:
# `ct trace-metadata --id=…` printed `"lang": 20`.  The two ends are one
# build, so a lockstep renumber never mislabelled a trace through it, but an
# ordinal on a subprocess boundary is exactly the contract this series exists
# to remove.
#
# It lives HERE, and not in `metadata.nim`, and the placement is LOAD-BEARING:
# `json_serialization`'s generic writer binds its `writeValue` overload set
# once, no later than this module, and a `serializesAsTextInJson(Lang)`
# declared in any module DOWNSTREAM of it is simply ignored.  Measured
# (2026-09-21, at review) with three scratch programs, each two encoder
# modules over this same `Trace`:
#
#   rule only here                          -> both encoders write "LangPythonDb"
#   rule removed here, declared in the 2nd  -> both write 20, the declaring
#     encoder module (the `metadata.nim` shape)  module included
#   rule removed here, declared in the 1st  -> both write 20
#     encoder module
#
# So the rule is NOT "whichever module encodes a `Trace` first" (the third
# arm refutes that): it has to be visible in THIS module, which every `Trace`
# encoder imports because it is where a `Trace` comes from.  The first draft
# of this change put it in `metadata.nim` and `trace_index_migration_test`
# showed it ignored.  The renderer decodes the name with
# `decodeLangName` (`parseEnum[Lang]`); a retired name -- which `loadTrace`
# already reports as `LangUnknown` beside `langRetiredName` -- reaches it as
# such.  `json_serialization`'s reader accepts an enum as int OR string, so
# nothing that reads an encoded `Trace` back had to change.  `calltraceMode`
# still crosses as an integer (its renderer map is LRS-6's).
serializesAsTextInJson(Lang)

proc langToColumnValue*(lang: Lang): string =
  ## The persisted form of ``lang`` since schema version **2**: the four-axis
  ## token (``target_axes.encodeAxesToken``).
  ##
  ## Version 1 wrote ``$lang``.  That is still what the frozen 1 → 2 map
  ## below decodes, and it is deliberately NOT what this proc produces any
  ## more: the enum name is one value answering four questions, and the column
  ## is the replay side's only per-recording fact.
  ##
  ## The toolchain axis is written as ``unknown`` on this path, because a
  ## ``Lang`` names no toolchain; see ``storageAxesOfLang``.
  encodeAxesToken(storageAxesOfLang(lang))

type
  LangColumn* = object
    ## What a ``recordings.lang`` cell decodes to.
    lang*: Lang
      ## The live member the stored cell denotes — or ``LangUnknown`` when no
      ## live member summarises it (see ``retiredName``).
    retiredName*: string
      ## Non-empty exactly when the cell was a legitimate persisted value that
      ## this build has no live ``Lang`` for: a four-axis token no member
      ## summarises, or the name of a member a later build removed.  Carried
      ## so the row is displayed by what it was recorded under and nothing is
      ## lost; ``lang`` is then the sentinel, never a guess at a neighbour.

# Retired-name policy (decided 2026-09-20, LRS-2B): a ``recordings.lang``
# cell holding the name of a member that a later build REMOVED decodes to
# ``LangUnknown`` with the name preserved in ``LangColumn.retiredName``.  It
# does not raise.  Raising here would turn every recording made before the
# removal into a hard failure the moment the index is opened — the frozen
# ``langV0OrdinalNames`` table below exists precisely so that old rows stay
# readable, and this is the same obligation one column-format later.
#
# The policy is scoped to names that WERE members: the decoder recognises a
# retired name by its presence in ``langNamesEverPersisted``, a frozen,
# append-only literal.  A string in neither the live enum nor that table was
# never written by any CodeTracer build, and a bare integer means an
# unmigrated version-0 database; both still raise, exactly as before, because
# admitting them would silently re-admit the ordinal format this migration
# retired (integers) or paper over corruption (arbitrary strings).
#
# Nothing rewrites the cell.  ``recordTrace`` inserts new rows only, and the
# two ``UPDATE recordings SET`` statements in this file touch the remote-share
# columns; a row decoded as retired therefore keeps its original name on disk
# for the schema-version-2 remap (LRS-5) to give a lossless target.

const
  langNamesAddedSinceV0*: array[1, string] = ["LangGdScript"]
    ## **Append-only.  Never regenerate this from ``Lang``.**  The names that
    ## schema version 1 has written that were NOT in the version-0 enum.  A
    ## member added to ``Lang`` is appended here when it lands (the test
    ## ``every live Lang name has been recorded as persisted`` fails until it
    ## is); a member REMOVED from ``Lang`` is never removed from here, which is
    ## what lets the decoder recognise its name as retired rather than foreign.

  # Every name a ``recordings.lang`` cell may legitimately hold: the frozen
  # version-0 table plus the frozen additions.  Derived at compile time from
  # two FROZEN literals and never from the live enum — rule 3 of the milestone
  # series.  ``retired`` = in this list and not in ``Lang``.
  langNamesEverPersisted*: seq[string] = static:
    var names: seq[string] = @[]
    for entry in langV0OrdinalNames:
      names.add(entry.name)
    for name in langNamesAddedSinceV0:
      names.add(name)
    names

# ---------------------------------------------------------------------------
# The frozen schema-version-1 name → schema-version-2 token table
# ---------------------------------------------------------------------------
#
# **A snapshot of a retired encoding.  Never regenerate this from ``Lang``.**
#
# Milestone rule 3: *any mapping from a historical encoding — an ordinal
# written by an older build, or a ``$lang`` name written by schema version 1 —
# must be a frozen literal annotated as a snapshot of a retired enum, and must
# never be generated from the live enum by iterating it.*  This is the second
# such table; ``langV0OrdinalNames`` above is the first, and its comment
# carries the full reasoning.
#
# The force of the rule here is not theoretical.  Two of the 41 names below —
# ``LangPython`` and ``LangRuby`` — were DELETED from ``Lang`` by LRS-4 on
# 2026-09-21, so ``parseEnum[Lang]("LangPython")`` *raises* in this build where
# it used to succeed.  A 1 → 2 map written as ``for lang in Lang: …`` would
# therefore not merely drift: it would silently omit both, the ``CASE`` would
# have no branch for their cells, the NULL would hit the column's ``NOT NULL``
# and the migration of any database holding one would abort.  A map written as
# ``parseEnum[Lang](storedName)`` would raise outright.  Neither name can be
# reached through the live enum at any point, and neither is.
#
# The set is exactly ``langNamesEverPersisted``: the 40 frozen version-0 names
# plus ``langNamesAddedSinceV0``.  That is 41, not the 40 the design and the
# milestone entry both say — corrected here (milestone rule 7): those two
# documents were counting the PRE-SPLIT enum, and ``LangGdScript`` was added to
# ``Lang`` while schema version 1 was the live format, so version 1 could and
# can write it.  ``trace_index_migration_test.nim`` asserts the two lists are
# the same set, so a member appended to ``langNamesAddedSinceV0`` without a
# token here is a test failure rather than a migration that maps it to NULL.
#
# Every target is DISTINCT — obligation 6 of the design's §5.4, the
# lossless-history obligation — and the four that are easiest to get wrong are
# called out in the milestone entry:
#
#   * ``LangUnknown`` → ``unknown``, the bare sentinel, NOT
#     ``unknown-unknown-unknown-unknown`` (design Q3);
#   * ``LangMasm``    → the ``midenasm`` form, NOT ``masm`` (design Q4a);
#   * ``LangPython`` / ``LangRuby``  → the ``rr`` approach, which is what those
#     two retired backends were, recorded as a fact rather than lost;
#   * ``LangRustWasm`` / ``LangCppWasm`` → ``tiWasm`` / ``raVmEmulation``,
#     re-derived under the four-axis grammar rather than copied from the
#     two-axis ``rs-wasm`` the design's §5.4 table still shows.  Under four
#     axes wasm is an ISA and the approach is VM emulation — the same approach
#     ``nargo`` and every blockchain recorder uses — so the token is
#     ``rs-wasm-unknown-vm``, not ``rs-wasm``.
#
# The toolchain axis is ``unknown`` in all 41 rows, and that is the honest
# answer rather than a gap: a schema-version-1 cell recorded no toolchain, so
# there is nothing to migrate onto that axis.  Inventing one — ``cargo`` for
# ``LangRust``, ``none`` for ``LangPythonDb`` — would be writing a DEFAULT into
# persisted data, which is precisely what design question Q1's rule forbids and
# what this whole encoding exists to stop.
const
  langV1NameToV2Token*: array[41, tuple[name: string, token: string]] = [
    ("LangC",          "c-native-unknown-mcr"),
    ("LangCpp",        "cpp-native-unknown-mcr"),
    ("LangRust",       "rs-native-unknown-mcr"),
    ("LangNim",        "nim-native-unknown-mcr"),
    ("LangGo",         "go-native-unknown-mcr"),
    ("LangPascal",     "pas-native-unknown-mcr"),
    ("LangFortran",    "f90-native-unknown-mcr"),
    ("LangD",          "d-native-unknown-mcr"),
    ("LangCrystal",    "cr-native-unknown-mcr"),
    ("LangLean",       "lean-native-unknown-mcr"),
    ("LangJulia",      "jl-native-unknown-mcr"),
    ("LangAda",        "adb-native-unknown-mcr"),
    # The two LRS-4 deleted.  `parseEnum[Lang]` cannot reach either name.
    ("LangPython",     "py-interpreted-unknown-rr"),
    ("LangRuby",       "rb-interpreted-unknown-rr"),
    ("LangRubyDb",     "rb-interpreted-unknown-instrumented"),
    ("LangJavascript", "js-interpreted-unknown-instrumented"),
    ("LangLua",        "lua-interpreted-unknown-instrumented"),
    ("LangAsm",        "asm-native-unknown-mcr"),
    ("LangNoir",       "nr-acir-unknown-vm"),
    # The wasm pair, re-derived: wasm is an ISA, the approach is emulation.
    ("LangRustWasm",   "rs-wasm-unknown-vm"),
    ("LangCppWasm",    "cpp-wasm-unknown-vm"),
    ("LangPythonDb",   "py-interpreted-unknown-instrumented"),
    # The sentinel: the bare token, the one documented exception (Q3).
    ("LangUnknown",    "unknown"),
    ("LangBash",       "sh-interpreted-unknown-instrumented"),
    ("LangZsh",        "zsh-interpreted-unknown-instrumented"),
    ("LangSolidity",   "sol-evm-unknown-vm"),
    # `midenasm`, not `masm`: `masm` is reserved and unallocated (Q4a).
    ("LangMasm",       "midenasm-midenvm-unknown-vm"),
    ("LangSway",       "sw-fuelvm-unknown-vm"),
    ("LangMove",       "move-movevm-unknown-vm"),
    # The platform pair: a chain and a VM, with no source language at all.
    ("LangPolkavm",    "unknown-polkavm-unknown-vm"),
    ("LangCairo",      "cairo-cairovm-unknown-vm"),
    ("LangCircom",     "circom-circomwitness-unknown-vm"),
    ("LangLeo",        "leo-aleovm-unknown-vm"),
    ("LangTolk",       "tolk-tonvm-unknown-vm"),
    ("LangAiken",      "ak-plutus-unknown-vm"),
    ("LangCadence",    "cdc-flowvm-unknown-vm"),
    ("LangSolana",     "unknown-solanasbf-unknown-vm"),
    ("LangElixir",     "ex-beam-unknown-instrumented"),
    ("LangErlang",     "erl-beam-unknown-instrumented"),
    ("LangPhp",        "php-interpreted-unknown-instrumented"),
    ("LangGdScript",   "gd-gdscriptvm-unknown-instrumented"),
  ]

proc langV2TokenForV1Name*(name: string): string =
  ## The schema-version-2 token for a schema-version-1 ``$lang`` name, or
  ## ``""`` when the frozen table has no entry.  Membership in the table — not
  ## anything about the live enum — is the definition of "a legal
  ## schema-version-1 cell".
  for entry in langV1NameToV2Token:
    if entry.name == name:
      return entry.token
  ""

proc decodeLangColumn*(raw: string,
                       everPersisted: openArray[string] = langNamesEverPersisted):
    LangColumn =
  ## Decode a ``recordings.lang`` cell.  Never raises for a value any
  ## CodeTracer build ever wrote; see the policy block above for what still
  ## does.
  ##
  ## Two formats are accepted and the ORDER IS THE DECISION:
  ##
  ## 1. **The schema-version-2 four-axis token** — the live format, decoded by
  ##    ``parseAxesToken``, which accepts exactly one hyphen-free token
  ##    (``unknown``) and otherwise requires all four axes spelled out.  A
  ##    token no live ``Lang`` summarises is the sentinel plus the token
  ##    itself as ``retiredName``: the cell already says everything the
  ##    summary cannot, so nothing is lost.
  ## 2. **A schema-version-1 ``Lang`` NAME** — the legacy branch, kept for
  ##    the same reason the retired-name policy exists: a row written by an
  ##    older build must not become a hard failure at open.  A live name
  ##    decodes to its member; a name in the frozen ``everPersisted`` list
  ##    that this build no longer has decodes to the sentinel plus the name.
  ##
  ## Everything else raises, including a bare integer (an unmigrated
  ## version-0 database) and a bare slug.  **A bare slug is the case this
  ## ordering is written for**: step 1 refuses it because the grammar has no
  ## hyphen-free token but ``unknown``, and step 2 refuses it because it is
  ## not a ``Lang`` name, so there is no path by which ``py`` acquires a
  ## default ISA, toolchain and approach.  That is design question Q1's rule
  ## — *a default may be applied at parse time; a default may never be
  ## IMPLIED by a persisted value* — enforced at the only place a persisted
  ## value is read.
  ##
  ## ``everPersisted`` is a parameter so the retired path can be exercised by
  ## a test independently of which members happen to be retired today;
  ## production callers take the default.
  var axes: TargetAxes
  if parseAxesToken(raw, axes):
    let summary = langForStorageAxes(axes)
    if summary.found:
      return LangColumn(lang: summary.lang, retiredName: "")
    return LangColumn(lang: LangUnknown, retiredName: raw)

  # --- the schema-version-1 legacy branch -----------------------------------
  try:
    return LangColumn(lang: parseEnum[Lang](raw), retiredName: "")
  except ValueError:
    discard
  for name in everPersisted:
    if name == raw:
      return LangColumn(lang: LangUnknown, retiredName: raw)
  raise newException(TraceIndexSchemaError,
    "trace_index: recordings.lang holds " & raw.escape() & ", which is " &
    "neither a four-axis token nor a Lang enum name.  Since trace_index " &
    "schema version " & $TRACE_INDEX_SCHEMA_VERSION & " this column stores " &
    "tokens such as 'rs-native-unknown-mcr' (or the bare sentinel " &
    "'unknown'); version " & $TRACE_INDEX_SCHEMA_VERSION_LANG_NAMES &
    " stored names such as 'LangRust' and those are still read.  An integer " &
    "here means the database was written before the lang-name migration and " &
    "was not migrated.  A bare slug such as 'py' is refused on purpose: a " &
    "stored value never implies a default for the axes it left out.")

proc langFromColumnValue*(raw: string): Lang =
  ## Inverse of ``langToColumnValue``, as a bare ``Lang``: a cell no live
  ## member summarises is ``LangUnknown`` (use ``decodeLangColumn`` to keep
  ## what it said).  Deliberately does **not** accept a bare integer:
  ## accepting one would silently re-admit the ordinal format the version-1
  ## migration exists to retire, and would then decode it against whatever
  ## the enum order happens to be today.
  decodeLangColumn(raw).lang

proc langLabel*(trace: Trace): string =
  ## The name to show for a recording's language: the live member's name, or
  ## — when no live member summarises the cell — what the cell itself said.
  ## Every listing that used to print ``$trace.lang`` prints this, so such a
  ## row keeps a meaningful label instead of reading "LangUnknown".
  ##
  ## Since schema version 2 that second case prints the four-axis token
  ## (``py-interpreted-unknown-rr`` for a recording made by the retired Python
  ## rr backend) where it used to print the retired enum name
  ## (``LangPython``).  That is a deliberate consequence of the column
  ## becoming self-describing: the token says more than the name did, and it
  ## says it without this build needing a member for it.
  if trace.langRetiredName.len > 0: $trace.langRetiredName
  else: $trace.lang


proc langV0NameForOrdinal*(ordinal: int): string =
  ## The version-0 name for ``ordinal``, or ``""`` if the frozen table has no
  ## entry for it.  Membership in the table — not ``low``/``high`` arithmetic
  ## — is the definition of "a legal version-0 ordinal".
  for entry in langV0OrdinalNames:
    if entry.ordinal == ordinal:
      return entry.name
  ""

proc langOrdinalToNameCaseSql(column: string): string =
  ## ``CASE lang WHEN 0 THEN 'LangC' ... END``, built from the **frozen**
  ## ``langV0OrdinalNames`` snapshot above rather than from the live ``Lang``
  ## enum.  The ordinals this decodes were written by an older build, so the
  ## enum as it is today is the wrong partner for them; see that constant's
  ## comment for what the previous, inverted, justification got wrong.
  ##
  ## Deliberately *not* ``CASE CAST(lang AS INTEGER)``: a cast would turn any
  ## non-numeric text into 0 and quietly relabel it ``LangC``.  Without the
  ## cast, a value that is not one of the listed ordinals falls through to a
  ## NULL, which the target column's ``NOT NULL`` rejects and which aborts the
  ## whole transaction.  ``validateLangOrdinals`` catches that case earlier
  ## and with a better message; the constraint is the backstop for anything it
  ## did not think of.
  result = "CASE " & column
  for entry in langV0OrdinalNames:
    result.add(" WHEN " & $entry.ordinal & " THEN '" & entry.name & "'")
  result.add(" END")

proc distinctLangValues(db: DBConn): seq[string] =
  result = @[]
  for row in db.getAllRows(
      sql("SELECT DISTINCT lang FROM " & RECORDINGS_TABLE & " ORDER BY lang")):
    result.add(row[0])

proc parsesAsLangName(raw: string): bool =
  ## A legitimate schema-version-**1** cell: a ``Lang`` name, live or retired
  ## (see the retired-name policy above).  Deliberately does NOT go through
  ## ``decodeLangColumn``, which since LRS-5 also accepts a version-2 token:
  ## this predicate is what the 0 → 1 step's pre- and post-conditions are
  ## written in terms of, and it has to keep meaning "a name", or the
  ## half-migrated detection at both ends stops detecting anything.
  if langV2TokenForV1Name(raw).len > 0:
    return true
  for name in langNamesEverPersisted:
    if name == raw:
      return true
  # A live member added to `Lang` but not yet appended to the frozen lists
  # would otherwise be reported as corruption by the verifier rather than by
  # the test that exists to force the append.
  try:
    discard parseEnum[Lang](raw)
    true
  except ValueError:
    false

proc parsesAsLangToken(raw: string): bool =
  ## A legitimate schema-version-**2** cell: the four-axis grammar, and
  ## nothing else.  A bare slug is not one; see ``parseAxesToken``.
  var axes: TargetAxes
  parseAxesToken(raw, axes)

proc countRecordings(db: DBConn): int =
  db.getValue(sql("SELECT count(*) FROM " & RECORDINGS_TABLE)).parseInt

proc foreignKeyViolationCount(db: DBConn): int =
  ## How many rows ``PRAGMA foreign_key_check`` reports for the whole
  ## database.
  ##
  ## **This number is normally not zero, and that is not a defect.**
  ## ``record_pid_recording_map`` declares
  ## ``FOREIGN KEY (recording_id) REFERENCES recordings(recording_id)``, but
  ## SQLite enforces foreign keys only when ``PRAGMA foreign_keys`` is ON and
  ## nothing in this module ever turns it on — so orphan pid rows accumulate
  ## as a matter of course, notably because ``recordTrace`` deletes and
  ## re-inserts a recording while the pid map keeps its old rows.  The
  ## developer database read on 2026-08-25 held **685 orphans among 932 pid
  ## rows** before this migration existed.
  ##
  ## The migration is therefore judged on the *delta*, never on the absolute
  ## value.  An earlier version of this code asserted the absolute value was
  ## zero and aborted a migration that had in fact succeeded, on the first
  ## real database it ever met.
  db.getAllRows(sql"PRAGMA foreign_key_check").len

proc validateLangOrdinals(db: DBConn) =
  ## Pre-flight for the 0 → 1 rebuild: every stored ``lang`` must be an
  ## integer that the frozen ``langV0OrdinalNames`` snapshot has a name for.
  ## Runs *before* any write, so a database this rejects is left exactly as it
  ## was found.  All offending values are collected, not just the first — a
  ## user fixing this by hand should not have to discover them one run at a
  ## time.
  ##
  ## The bound is membership in that snapshot, not ``ord(low(Lang))`` ..
  ## ``ord(high(Lang))``.  Those describe the enum this build was compiled
  ## with; the values on disk were written by an older one.  Checking a
  ## version-0 database against today's ``high(Lang)`` is the same inverted
  ## reasoning the frozen table exists to retire, and it would disagree with
  ## the ``CASE`` this check is a pre-flight for.
  var outOfRange: seq[string] = @[]
  var alreadyNames: seq[string] = @[]
  for raw in distinctLangValues(db):
    var ordinal = 0
    var isInteger = true
    try:
      ordinal = raw.parseInt
    except ValueError:
      isInteger = false
    if isInteger:
      if langV0NameForOrdinal(ordinal).len == 0:
        outOfRange.add(raw)
    elif parsesAsLangName(raw):
      alreadyNames.add(raw)
    else:
      outOfRange.add(raw)

  if alreadyNames.len > 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: recordings.lang already holds enum name(s) (" &
      alreadyNames.join(", ") & ") but PRAGMA user_version is 0.  That " &
      "combination cannot be produced by this code path and means the " &
      "database is half-migrated.  Refusing to rewrite it; restore the " &
      "snapshot written beside it (*" & langNameMigrationBakSuffix & ").")
  if outOfRange.len > 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: recordings.lang holds value(s) that are not " &
      "schema-version-0 Lang ordinals in " & $langV0MinOrdinal & ".." &
      $langV0MaxOrdinal & ": " &
      outOfRange.join(", ") & ".  Refusing to migrate: there is no name to " &
      "map them to and guessing one would mislabel the recording.")

proc validateLangNames(db: DBConn) =
  ## Post-condition for the 0 → 1 rebuild, and the whole check for a database
  ## that was created directly in the version-1 shape.
  var bad: seq[string] = @[]
  for raw in distinctLangValues(db):
    if not parsesAsLangName(raw):
      bad.add(raw.escape())
  if bad.len > 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: after the rebuild recordings.lang still holds " &
      "value(s) that are not Lang enum names: " & bad.join(", "))

proc migrationBackupPath(dbPath, bakSuffix: string): string =
  result = dbPath & bakSuffix
  if not fileExists(result):
    return
  var suffix = 1
  while fileExists(result & "." & $suffix):
    inc suffix
  result = result & "." & $suffix

# Forward-declared so each rebuild below can run it as its *last*
# in-transaction post-condition.  Its definition stays after
# ``applyLangNameMigration``, next to ``migrateTraceIndex``, because that is
# also where the tests reach for it.
proc verifyTraceIndexSchemaAt*(db: DBConn; version: int): seq[string]

proc applyLangNameMigration(db: DBConn; dbPath: string) =
  ## Schema version 0 → 1: rewrite ``recordings`` so ``lang`` is declared
  ## ``TEXT`` and holds ``Lang`` enum names.
  ##
  ## SQLite cannot change a column's declared type in place, so this is the
  ## documented "12-step ALTER TABLE" rebuild: create a scratch table from the
  ## canonical DDL, copy through a generated ``CASE``, drop, rename, recreate
  ## the indexes.  Every one of those steps plus the ``user_version`` stamp
  ## happens inside a single ``BEGIN IMMEDIATE`` transaction, so the database
  ## is only ever observed at version 0 with ordinals or at version 1 with
  ## names — never between.  ``IMMEDIATE`` (rather than a deferred ``BEGIN``)
  ## takes the write lock up front, so a second codetracer process cannot slip
  ## an INSERT in between the validation scan and the rebuild; with WAL and
  ## the 60s ``busy_timeout`` this module already sets, that process backs off
  ## rather than failing.
  ##
  ## **Two processes migrating at once**, which is reachable — the daemon and a
  ## CLI invocation both call ``ensureDB`` — resolves without corruption and
  ## deliberately without special handling.  The loser queues at
  ## ``BEGIN IMMEDIATE``; by the time it gets the lock the winner has committed,
  ## so the loser's ``CASE lang WHEN 0 …`` runs against a table that now holds
  ## *names*, every branch misses, the target column's ``NOT NULL`` rejects the
  ## resulting NULL, and the loser's whole transaction rolls back.  It then
  ## raises, and ``ensureDB`` stops with the named diagnostic; re-running
  ## succeeds, because the version gate now reads 1.  A double-checked
  ## "re-read the version under the lock and back out quietly" would make that
  ## nicer, and is intentionally *not* here: it cannot be tested deterministically
  ## without machinery that fakes the race, and untested concurrency handling in
  ## a user-data migration buys less than it costs.  The outcome as written is
  ## loud, lossless, and self-correcting on the next run — a stray
  ## ``*.pre-lang-name-migration.bak.1`` snapshot from the loser's aborted
  ## attempt is the only residue.
  if not tableExistsIn(db, RECORDINGS_TABLE):
    # Nothing to rewrite; the caller stamps the version.
    return

  let liveDefs = columnDefs(db, RECORDINGS_TABLE)
  let liveLangType = declaredTypeOf(liveDefs, "lang")
  if liveLangType.len == 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: table '" & RECORDINGS_TABLE & "' has no 'lang' " &
      "column (columns: " & columnNames(liveDefs).join(", ") & ")")

  if liveLangType == "TEXT":
    # A database created directly by the current DDL — typically a fresh one.
    # There are no ordinals to remap, but the values still have to be names.
    validateLangNames(db)
    return

  validateLangOrdinals(db)

  # Baselines for the post-conditions.  Both are captured *before* the
  # rebuild and re-checked inside the transaction, so the migration is judged
  # on what it changed rather than on the absolute state of a database it did
  # not create.  See ``foreignKeyViolationCount``.
  let recordingsBefore = countRecordings(db)
  let foreignKeyViolationsBefore = foreignKeyViolationCount(db)

  let backupPath = migrationBackupPath(dbPath, langNameMigrationBakSuffix)
  db.exec(sql"VACUUM INTO ?", backupPath)

  # Foreign-key enforcement must be off across a table rebuild, and cannot be
  # changed inside a transaction.  This module never turns it on, so this is
  # normally already a no-op; do it properly anyway.
  let foreignKeysWereOn = db.getValue(sql"PRAGMA foreign_keys") == "1"
  if foreignKeysWereOn:
    db.exec(sql"PRAGMA foreign_keys = OFF")

  var inTransaction = false
  try:
    db.exec(sql"BEGIN IMMEDIATE")
    inTransaction = true

    db.exec(sql("DROP TABLE IF EXISTS " & RECORDINGS_MIGRATION_TABLE))
    db.exec(sql(sqlCreateRecordingsTable(RECORDINGS_MIGRATION_TABLE)))

    let scratchCols = columnNames(columnDefs(db, RECORDINGS_MIGRATION_TABLE))
    let liveCols = columnNames(liveDefs)
    if scratchCols != liveCols:
      # A column added to the canonical DDL without a migration step for it
      # would otherwise be silently dropped or filled with NULL here.
      raise newException(TraceIndexMigrationError,
        "trace_index migration: the stored '" & RECORDINGS_TABLE & "' columns (" &
        liveCols.join(", ") & ") differ from the current schema's (" &
        scratchCols.join(", ") & ").  Version 0 → 1 only remaps 'lang'; a " &
        "column set change needs its own migration step.")

    let selectExprs = liveCols.mapIt(
      if it == "lang": langOrdinalToNameCaseSql("lang") else: it)
    db.exec(sql(
      "INSERT INTO " & RECORDINGS_MIGRATION_TABLE &
      " (" & liveCols.join(", ") & ") SELECT " & selectExprs.join(", ") &
      " FROM " & RECORDINGS_TABLE))
    migrationFault("after-table-rewrite")

    db.exec(sql("DROP TABLE " & RECORDINGS_TABLE))
    db.exec(sql("ALTER TABLE " & RECORDINGS_MIGRATION_TABLE &
                " RENAME TO " & RECORDINGS_TABLE))
    for statement in SQL_CREATE_RECORDINGS_INDEX_STATEMENTS:
      db.exec(sql(statement))
    migrationFault("after-table-swap")

    # Post-conditions, all *inside* the transaction.  That placement is the
    # whole point: a check that runs after COMMIT can only report a problem it
    # is powerless to undo, and the handler below would then describe the
    # database as unchanged when it is not.  Every assertion that can fail the
    # migration must be able to roll it back.
    validateLangNames(db)

    let recordingsAfter = countRecordings(db)
    if recordingsAfter != recordingsBefore:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: the rebuild changed the recording count from " &
        $recordingsBefore & " to " & $recordingsAfter &
        ".  The 0 -> 1 migration rewrites one column and must not add or " &
        "drop a row.")

    let foreignKeyViolationsAfter = foreignKeyViolationCount(db)
    if foreignKeyViolationsAfter > foreignKeyViolationsBefore:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: the rebuild introduced " &
        $(foreignKeyViolationsAfter - foreignKeyViolationsBefore) &
        " new foreign-key violation(s) (" & $foreignKeyViolationsBefore &
        " before, " & $foreignKeyViolationsAfter & " after).")

    # Stamps **1**, not `TRACE_INDEX_SCHEMA_VERSION`.  This step brings a
    # database to version 1 and no further; since LRS-5 the latest version is
    # 2 and the 1 -> 2 step below runs next.  Stamping "the latest" here would
    # declare the database fully migrated before the second step had run.
    writeSchemaVersion(db, TRACE_INDEX_SCHEMA_VERSION_LANG_NAMES)
    migrationFault("after-version-stamp")

    # The full schema post-condition, as the last thing before COMMIT.  It
    # used to run in ``migrateTraceIndex`` *after* this transaction had
    # committed, which made it the one failable check in the whole migration
    # that could not roll back the write it was judging — the same shape as
    # the bug this comment block warns about, one level up.  Running it here
    # costs a handful of reads against pages already in cache.
    let problems = verifyTraceIndexSchemaAt(db, TRACE_INDEX_SCHEMA_VERSION_LANG_NAMES)
    if problems.len > 0:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: post-condition failed for " & dbPath &
        " after the version 0 -> 1 rebuild: " & problems.join("; "))

    db.exec(sql"COMMIT")
    inTransaction = false
  except CatchableError as e:
    if inTransaction:
      try:
        db.exec(sql"ROLLBACK")
      except DbError:
        discard
    if foreignKeysWereOn:
      try:
        db.exec(sql"PRAGMA foreign_keys = ON")
      except DbError:
        discard
    # Every escape from this block is wrapped the same way, whatever raised.
    # The message a user sees after a failed migration has to say what state
    # their database is in, and "unchanged, snapshot here" is the only useful
    # thing to tell them; re-raising a bare cause would have left that out.
    raise newException(TraceIndexMigrationError,
      "trace_index migration: rolled back the lang ordinal->name rebuild of " &
      dbPath & "; the database is unchanged and a snapshot of it is at " &
      backupPath & ".  Cause: " & e.msg, e)

  if foreignKeysWereOn:
    db.exec(sql"PRAGMA foreign_keys = ON")

  # Nothing that can fail belongs after this point.  There used to be an
  # absolute ``PRAGMA foreign_key_check`` here; see ``foreignKeyViolationCount``
  # for why that was wrong twice over.
  stderr.writeLine(
    "[codetracer] trace_index.db migrated to schema version " &
    $TRACE_INDEX_SCHEMA_VERSION_LANG_NAMES &
    " (recordings.lang now stores language " &
    "names, not enum ordinals). Pre-migration snapshot: " & backupPath)

proc verifyTraceIndexSchemaAt*(db: DBConn; version: int): seq[string] =
  ## Return every way ``db`` fails to be a recordings database at schema
  ## version ``version``.  An empty result is the post-condition of each
  ## migration step and the thing tests assert on.  Returns problems rather
  ## than raising so a caller can report all of them at once.
  ##
  ## Parameterised on the version since LRS-5, because the 0 → 1 and 1 → 2
  ## steps run back to back and each must be able to judge ITSELF from inside
  ## its own transaction.  A verifier that only knew the latest version would
  ## fail the intermediate state the first step legitimately produces, and the
  ## first step would then have to check nothing at all.  What "a valid cell"
  ## means is the part that moves: version 1 says a ``Lang`` NAME, version 2
  ## says a four-axis TOKEN.
  result = @[]
  var stored = -1
  try:
    stored = readSchemaVersion(db)
  except TraceIndexMigrationError as e:
    result.add(e.msg)
  if stored != version:
    result.add("PRAGMA user_version is " & $stored & ", expected " & $version)
  if not tableExistsIn(db, RECORDINGS_TABLE):
    result.add("table '" & RECORDINGS_TABLE & "' is missing")
    return
  if tableExistsIn(db, RECORDINGS_MIGRATION_TABLE):
    result.add("migration scratch table '" & RECORDINGS_MIGRATION_TABLE &
               "' survived; the database is half-migrated")
  let declared = declaredTypeOf(columnDefs(db, RECORDINGS_TABLE), "lang")
  if declared != "TEXT":
    result.add("recordings.lang is declared " &
               (if declared.len == 0: "<missing>" else: declared) &
               ", expected TEXT")
  for raw in distinctLangValues(db):
    if version >= TRACE_INDEX_SCHEMA_VERSION:
      if not parsesAsLangToken(raw):
        result.add("recordings.lang holds " & raw.escape() &
                   ", which is not a four-axis language token")
    else:
      if not parsesAsLangName(raw):
        result.add("recordings.lang holds " & raw.escape() &
                   ", which is not a Lang enum name")

proc verifyTraceIndexSchema*(db: DBConn): seq[string] =
  ## ``verifyTraceIndexSchemaAt`` at the version this build writes.
  verifyTraceIndexSchemaAt(db, TRACE_INDEX_SCHEMA_VERSION)

proc langTokenRemapCaseSql(column: string): string =
  ## ``CASE lang WHEN 'LangC' THEN 'c-native-unknown-mcr' ... END``, built
  ## from the **frozen** ``langV1NameToV2Token`` literal and never from the
  ## live ``Lang`` enum.  Milestone rule 3, and here the rule has teeth: two
  ## of the names this table must map (``LangPython``, ``LangRuby``) are not
  ## members of ``Lang`` any more, so a generator over the enum would emit no
  ## branch for them at all.
  ##
  ## There is deliberately **no ``ELSE``**.  A cell the table does not cover
  ## falls through to NULL, which the column's ``NOT NULL`` rejects, which
  ## aborts the whole transaction — the same backstop the 0 → 1 ``CASE`` uses.
  ## ``validateLangV1Names`` below catches that case earlier and with a better
  ## message; this is what catches anything it did not think of.
  result = "CASE " & column
  for entry in langV1NameToV2Token:
    result.add(" WHEN '" & entry.name & "' THEN '" & entry.token & "'")
  result.add(" END")

proc validateLangV1Names(db: DBConn) =
  ## Pre-flight for the 1 → 2 remap: every stored ``lang`` must be a name the
  ## frozen ``langV1NameToV2Token`` table has a token for.  Runs *before* any
  ## write, so a database this rejects is left exactly as it was found.  All
  ## offending values are collected, not just the first.
  var alreadyTokens: seq[string] = @[]
  var unmappable: seq[string] = @[]
  for raw in distinctLangValues(db):
    if langV2TokenForV1Name(raw).len > 0:
      continue
    if parsesAsLangToken(raw):
      alreadyTokens.add(raw)
    else:
      unmappable.add(raw.escape())

  if alreadyTokens.len > 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: recordings.lang already holds four-axis " &
      "token(s) (" & alreadyTokens.join(", ") & ") but PRAGMA user_version " &
      "is below " & $TRACE_INDEX_SCHEMA_VERSION & ".  That combination " &
      "cannot be produced by this code path and means the database is " &
      "half-migrated.  Refusing to rewrite it; restore the snapshot written " &
      "beside it (*" & langTokenMigrationBakSuffix & ").")
  if unmappable.len > 0:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: recordings.lang holds value(s) that are not " &
      "schema-version-1 Lang names: " & unmappable.join(", ") & ".  " &
      "Refusing to migrate: the frozen version-1 name table has no token " &
      "for them and inventing one would mislabel the recording.")

proc applyLangAxesTokenMigration(db: DBConn; dbPath: string) =
  ## Schema version 1 → 2: remap every ``recordings.lang`` cell from the
  ## ``Lang`` enum NAME to the four-axis TOKEN (``target_axes.nim``).
  ##
  ## Unlike 0 → 1 this is **not** a table rebuild.  The column is already
  ## ``TEXT`` and stays ``TEXT``; only the values change.  So it is one
  ## ``UPDATE ... SET lang = CASE ... END`` inside a single ``BEGIN
  ## IMMEDIATE`` transaction, with the same ``VACUUM INTO`` snapshot and the
  ## same ``PRAGMA user_version`` stamp version 1 uses.  Everything the 0 → 1
  ## step's long comment says about ``IMMEDIATE``, about two processes
  ## migrating at once, and about every failable check living *inside* the
  ## transaction applies here verbatim and is not repeated.
  ##
  ## One difference worth naming: the loser of a concurrent race resolves
  ## here by the same mechanism but through a different door.  Its
  ## pre-flight scan runs before it takes the lock, so it may pass; by the
  ## time it holds the lock the winner has committed tokens, its ``CASE``
  ## matches no branch, the NULL hits ``NOT NULL`` and its whole transaction
  ## rolls back.  Loud, lossless, self-correcting on the next run.
  if not tableExistsIn(db, RECORDINGS_TABLE):
    # Nothing to remap; the caller stamps the version.
    return

  let liveDefs = columnDefs(db, RECORDINGS_TABLE)
  let liveLangType = declaredTypeOf(liveDefs, "lang")
  if liveLangType != "TEXT":
    raise newException(TraceIndexMigrationError,
      "trace_index migration: the version 1 -> 2 remap needs recordings.lang " &
      "declared TEXT and found " &
      (if liveLangType.len == 0: "<missing>" else: liveLangType) &
      ".  The version 0 -> 1 rebuild is what makes it TEXT and it did not run.")

  let storedValues = distinctLangValues(db)
  if storedValues.len == 0:
    # A database with no recordings — typically a fresh one.  There is
    # nothing to remap and nothing to validate; the caller stamps.
    return

  validateLangV1Names(db)

  # Baselines for the post-conditions.  Captured *before* the write and
  # re-checked inside the transaction, so the step is judged on what it
  # changed rather than on the absolute state of a database it did not
  # create.  See ``foreignKeyViolationCount``: that number is normally
  # non-zero, and an earlier version of the 0 -> 1 step aborted a successful
  # run by asserting otherwise.
  let recordingsBefore = countRecordings(db)
  let foreignKeyViolationsBefore = foreignKeyViolationCount(db)

  let backupPath = migrationBackupPath(dbPath, langTokenMigrationBakSuffix)
  db.exec(sql"VACUUM INTO ?", backupPath)

  var inTransaction = false
  try:
    db.exec(sql"BEGIN IMMEDIATE")
    inTransaction = true

    db.exec(sql("UPDATE " & RECORDINGS_TABLE & " SET lang = " &
                langTokenRemapCaseSql("lang")))
    migrationFault("after-token-remap")

    # Post-conditions, all *inside* the transaction, for the reason the
    # 0 -> 1 step records: a check that runs after COMMIT can only report a
    # problem it is powerless to undo.
    var stillNames: seq[string] = @[]
    for raw in distinctLangValues(db):
      if not parsesAsLangToken(raw):
        stillNames.add(raw.escape())
    if stillNames.len > 0:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: after the remap recordings.lang still holds " &
        "value(s) that are not four-axis tokens: " & stillNames.join(", "))

    let recordingsAfter = countRecordings(db)
    if recordingsAfter != recordingsBefore:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: the remap changed the recording count from " &
        $recordingsBefore & " to " & $recordingsAfter &
        ".  The 1 -> 2 migration rewrites one column's VALUES and must not " &
        "add or drop a row.")

    let foreignKeyViolationsAfter = foreignKeyViolationCount(db)
    if foreignKeyViolationsAfter > foreignKeyViolationsBefore:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: the remap introduced " &
        $(foreignKeyViolationsAfter - foreignKeyViolationsBefore) &
        " new foreign-key violation(s) (" & $foreignKeyViolationsBefore &
        " before, " & $foreignKeyViolationsAfter & " after).")

    writeSchemaVersion(db, TRACE_INDEX_SCHEMA_VERSION)
    migrationFault("after-token-version-stamp")

    let problems = verifyTraceIndexSchemaAt(db, TRACE_INDEX_SCHEMA_VERSION)
    if problems.len > 0:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: post-condition failed for " & dbPath &
        " after the version 1 -> 2 remap: " & problems.join("; "))

    db.exec(sql"COMMIT")
    inTransaction = false
  except CatchableError as e:
    if inTransaction:
      try:
        db.exec(sql"ROLLBACK")
      except DbError:
        discard
    raise newException(TraceIndexMigrationError,
      "trace_index migration: rolled back the lang name->token remap of " &
      dbPath & "; the database is unchanged and a snapshot of it is at " &
      backupPath & ".  Cause: " & e.msg, e)

  # Nothing that can fail belongs after this point.
  stderr.writeLine(
    "[codetracer] trace_index.db migrated to schema version " &
    $TRACE_INDEX_SCHEMA_VERSION & " (recordings.lang now stores four-axis " &
    "language tokens such as 'ex-beam-unknown-instrumented', not enum " &
    "names). Pre-migration snapshot: " & backupPath)

proc migrateTraceIndex*(db: DBConn; dbPath: string) =
  ## Bring ``db`` up to ``TRACE_INDEX_SCHEMA_VERSION``.
  ##
  ## Idempotent by construction: the only thing that decides whether any work
  ## happens is ``PRAGMA user_version``, and each step that does work stamps
  ## that value inside the same transaction.  A second call therefore reads
  ## the current version and returns without touching a page.
  ##
  ## The steps **compose** rather than replace one another: a version-0
  ## database runs 0 → 1 → 2 in this one call, each step gated on the version
  ## the previous one stamped, each with its own snapshot, its own fault
  ## points and its own in-transaction post-conditions.  Version 1 was
  ## deliberately not rewritten to emit the final token directly; databases
  ## already at version 1 exist, and code claiming version 1 meant tokens
  ## would meet a database the gate reports as done, holding values it cannot
  ## parse.
  let version = readSchemaVersion(db)
  if version == TRACE_INDEX_SCHEMA_VERSION:
    return
  if version > TRACE_INDEX_SCHEMA_VERSION:
    raise newException(TraceIndexMigrationError,
      "trace_index migration: " & dbPath & " reports schema version " &
      $version & ", newer than the " & $TRACE_INDEX_SCHEMA_VERSION &
      " this build understands.  Refusing to open it: a downgrade cannot " &
      "know what a newer release changed.  Use a codetracer at least as new " &
      "as the one that wrote it, or move the file aside.")
  if version < TRACE_INDEX_SCHEMA_VERSION_LANG_NAMES:
    applyLangNameMigration(db, dbPath)
  # Re-read rather than reusing `version`: the step above stamps 1 from
  # inside its own transaction when it rebuilds, and returns without stamping
  # on the two paths that have nothing to rebuild (no `recordings` table, and
  # a database already created in the version-1 TEXT shape).  Both of those
  # still have to reach the remap below.
  if readSchemaVersion(db) < TRACE_INDEX_SCHEMA_VERSION:
    applyLangAxesTokenMigration(db, dbPath)

  # The stamp, and the post-condition, in a transaction of their own.
  #
  # Each step stamps and verifies inside *its* transaction whenever it does
  # work.  Each also has paths that return without one — a database with no
  # ``recordings`` table at all, and a database with no rows (the ordinary
  # fresh-database case) — and those are what this stamps.  Wrapping it keeps
  # one invariant true with no exceptions: **no check that can fail this
  # migration ever runs outside a transaction able to undo the write it is
  # checking.**  This block used to sit bare after the commit, which made its
  # raise the only one in the module that could report a problem it was
  # powerless to do anything about.
  #
  # Reached only on a run that actually did work — the steady-state path
  # returned at the version check above — so it costs nothing after the first
  # launch.  A migration that reports success while leaving the database in
  # some other shape is the exact failure this whole change is written
  # against, so it is checked rather than trusted.
  db.exec(sql"BEGIN IMMEDIATE")
  var committed = false
  try:
    writeSchemaVersion(db, TRACE_INDEX_SCHEMA_VERSION)
    let problems = verifyTraceIndexSchema(db)
    if problems.len > 0:
      raise newException(TraceIndexMigrationError,
        "trace_index migration: post-condition failed for " & dbPath &
        " after migrating from schema version " & $version & ": " &
        problems.join("; "))
    db.exec(sql"COMMIT")
    committed = true
  finally:
    if not committed:
      try:
        db.exec(sql"ROLLBACK")
      except DbError:
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

  # Value-level schema migration.  Runs *after* the structural
  # archive-and-recreate above (which may have deleted the file outright) and
  # *after* the CREATE TABLE IF NOT EXISTS pass (which is a no-op on an
  # existing database, so a version-0 database still arrives here with its
  # INTEGER ``lang`` column intact).  Version-gated, so this is a single
  # header read on every launch after the first.
  try:
    migrateTraceIndex(db, DB_PATHS[test.int])
  except TraceIndexMigrationError as e:
    # Fail loud and stop.  A half-migrated recordings database is not
    # recoverable by rebuilding the product, so continuing on to serve reads
    # from a database we could not bring to a known state is the one thing
    # that must not happen here.
    stderr.writeLine("[codetracer] FATAL: " & e.msg)
    # Deliberately does NOT assert what state the database is in: only the
    # raise site knows that, and it says so in the message above.  This text
    # used to claim the index "was left unchanged", which was true for every
    # rollback path and false for anything raised after COMMIT — a wrong
    # recovery instruction on a user-data migration.  The post-conditions now
    # all run inside the transaction, but the message must not depend on that
    # staying true.
    stderr.writeLine(
      "[codetracer] refusing to serve the local recording index at " &
      DB_PATHS[test.int] & " in an unknown state.  The line above says what " &
      "failed and what state the database is in, INCLUDING the exact path " &
      "of the snapshot it took.  Each migration step writes one beside the " &
      "database before it touches a page: the version 0 -> 1 rebuild as " &
      "*" & langNameMigrationBakSuffix & " and the version 1 -> 2 remap as " &
      "*" & langTokenMigrationBakSuffix & " (a step that had nothing to do " &
      "writes neither, which is why the line above is the one to read and " &
      "not this one).  Restore the snapshot it names to recover, or run " &
      "`just reset-db` to discard the index (recordings stay replayable via " &
      "`ct replay <folder>`).")
    quit(1)

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
            langToColumnValue(lang), $(imported.int), $shellID,
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
    # Schema version 1: column 10 is the ``Lang`` enum *name*.  It used to be
    # ``trace[10].parseInt.Lang``, which reinterpreted whatever integer was
    # stored against today's enum order — the failure mode this migration
    # exists to remove.  ``decodeLangColumn`` raises rather than guessing for
    # anything that was never a name; a RETIRED name decodes to the sentinel
    # with the name preserved (``langRetiredName``).
    let column = decodeLangColumn(trace[10])
    let lang = column.lang
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
      langRetiredName: column.retiredName,
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
    curlExe(),
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

type
  RecordingIdPrefixError* = enum
    ## Outcome of a short-prefix lookup that did not return a unique match.
    ## ``rieTooShort``  — the user-supplied prefix is shorter than
    ##                    ``MIN_RECORDING_ID_PREFIX_LEN``.
    ## ``rieNotFound``  — no recording in the local DB matches the prefix.
    ## ``rieAmbiguous`` — more than one recording matches; caller must
    ##                    print the candidate list and ask the user to
    ##                    disambiguate.
    rieTooShort
    rieNotFound
    rieAmbiguous

  RecordingIdPrefixResult* = object
    ## Result of ``findByRecordingIdPrefix``.  ``trace`` is populated only
    ## when the lookup resolved to exactly one recording (``isOk == true``);
    ## otherwise ``error`` describes why and ``matches`` carries the
    ## first few canonical recording-ids that share the prefix (cap of
    ## ``RECORDING_ID_PREFIX_MATCH_CAP``).
    case isOk*: bool
    of true:
      trace*: Trace
    of false:
      error*: RecordingIdPrefixError
      matches*: seq[string]

const
  MIN_RECORDING_ID_PREFIX_LEN* = 8
    ## Minimum number of leading hex characters accepted by short-prefix
    ## lookup.  UUIDv7's first 48 bits encode the millisecond timestamp,
    ## so two recordings made in the same ms share a 12-hex-char prefix;
    ## 8 chars (≈ 1/65536 collision chance after a single same-second
    ## burst) is the documented floor in the parent spec §8.

  RECORDING_ID_PREFIX_MATCH_CAP* = 5
    ## When a prefix is ambiguous we surface at most this many candidate
    ## ids in the error so the terminal output stays readable.

proc isPrefixCharsOnly(s: string): bool =
  ## A canonical UUIDv7 prefix is lowercase hex digits plus optional
  ## hyphens at the standard positions (8-4-4-4-12).  We accept any
  ## lowercase ``[0-9a-f-]`` characters here and let the database lookup
  ## be the source of truth — a syntactically invalid prefix will simply
  ## fail to match.
  for c in s:
    if not (c in {'0'..'9', 'a'..'f', '-'}):
      return false
  true

proc findByRecordingIdPrefix*(prefix: string, test: bool): RecordingIdPrefixResult =
  ## Resolve a user-supplied short prefix to a unique recording-id.
  ##
  ## Pre-1.0 behaviour:
  ##
  ## - Prefix < ``MIN_RECORDING_ID_PREFIX_LEN`` chars → ``rieTooShort``.
  ## - Exactly one recording matches → ``isOk = true``, ``trace`` set.
  ## - Zero recordings match → ``rieNotFound``.
  ## - More than one match → ``rieAmbiguous``; ``matches`` carries up to
  ##   ``RECORDING_ID_PREFIX_MATCH_CAP`` canonical recording-ids.
  ##
  ## Callers (``ct replay`` / ``ct upload`` / ``ct trace-metadata``) decide
  ## how to render the disambiguation error.  See parent spec
  ## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
  ## §8 for the design rationale.
  let normalized = prefix.toLowerAscii
  if normalized.len < MIN_RECORDING_ID_PREFIX_LEN:
    return RecordingIdPrefixResult(
      isOk: false, error: rieTooShort, matches: @[])
  if not isPrefixCharsOnly(normalized):
    # Non-hex characters cannot match a canonical UUIDv7; surface as
    # "not found" rather than a syntactic error.  The CLI surface gates
    # on validity (``recording_id.isCanonicalUuidV7``) only for the
    # full-form path.
    return RecordingIdPrefixResult(
      isOk: false, error: rieNotFound, matches: @[])

  let db = ensureDB(test)
  # Cap at ``cap + 1`` so we can distinguish "exactly N matches" from
  # "more than N matches" without scanning the whole table.  The result
  # presented to the user is capped at ``cap``.
  let cap = RECORDING_ID_PREFIX_MATCH_CAP
  let pattern = normalized & "%"
  let rows = db.getAllRows(
    sql(
      "SELECT * FROM recordings WHERE recording_id LIKE ? " &
      "ORDER BY recording_id ASC LIMIT " & $(cap + 1)
    ),
    pattern)
  db.close()
  if rows.len == 0:
    return RecordingIdPrefixResult(
      isOk: false, error: rieNotFound, matches: @[])
  if rows.len == 1:
    return RecordingIdPrefixResult(
      isOk: true, trace: rows[0].loadTrace(test))
  var matches: seq[string] = @[]
  for row in rows:
    if matches.len >= cap:
      break
    matches.add(row[0])
  RecordingIdPrefixResult(
    isOk: false, error: rieAmbiguous, matches: matches)

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

  var cleanPath = path
  while cleanPath.len > 1 and (cleanPath[^1] == '/' or cleanPath[^1] == '\\'):
    cleanPath.setLen(cleanPath.len - 1)

  var lastSep = -1
  for i in 0 ..< cleanPath.len:
    if cleanPath[i] == '/' or cleanPath[i] == '\\':
      lastSep = i
  let folderName = if lastSep == -1: cleanPath else: cleanPath[(lastSep + 1) .. ^1]

  let db = ensureDB(test)

  # Use INSERT OR REPLACE to handle both new and existing entries
  try:
    db.exec(
      sql"""INSERT OR REPLACE INTO recent_folders (path, name, last_opened)
            VALUES (?, ?, ?)""",
      cleanPath, folderName, lastOpenedStr)
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

  var cleanPath = path
  while cleanPath.len > 1 and (cleanPath[^1] == '/' or cleanPath[^1] == '\\'):
    cleanPath.setLen(cleanPath.len - 1)

  let db = ensureDB(test)

  try:
    db.exec(
      sql"UPDATE recent_folders SET last_opened = ? WHERE path = ?",
      lastOpenedStr, cleanPath)
  except DbError:
    echo "error: updateRecentFolder: ", getCurrentExceptionMsg()

  db.close()

proc removeRecentFolder*(path: string, test: bool) =
  ## Remove a folder from recent folders
  var cleanPath = path
  while cleanPath.len > 1 and (cleanPath[^1] == '/' or cleanPath[^1] == '\\'):
    cleanPath.setLen(cleanPath.len - 1)

  let db = ensureDB(test)

  try:
    db.exec(
      sql"DELETE FROM recent_folders WHERE path = ?",
      cleanPath)
  except DbError:
    echo "error: removeRecentFolder: ", getCurrentExceptionMsg()

  db.close()
