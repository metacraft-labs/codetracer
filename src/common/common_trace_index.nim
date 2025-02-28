# backend agnostic code, part of the trace_index module, should not be imported directly,
# use common/trace_index or frontend/trace_index instead.
type
  CodetracerNotImplementedError* = object of ValueError

const NO_TRACE_ID* = -1

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
  """CREATE TABLE IF NOT EXISTS traces (
      id integer,
      program text,
      args text,
      compileCommand text,
      env text,
      workdir text,
      output text,
      sourceFolders text,
      lowLevelFolder text,
      outputFolder text,
      lang integer,
      imported integer,
      shellID integer,
      rrPid integer,
      exitCode integer,
      calltrace integer,
      calltraceMode string,
      date text,
      downloadId string,
      controlId string,
      key string);""",
  """CREATE TABLE IF NOT EXISTS trace_values (
      id integer,
      maxTraceID integer,
      UNIQUE(id));""",
  """CREATE TABLE IF NOT EXISTS record_pid_trace_id_map (
      pid integer,
      traceId integer);""",
]

const SQL_INITIAL_INSERT_STATEMENTS = @[
  """INSERT INTO trace_values (id, maxTraceID) VALUES (0, 0)""",
]

const SQL_ALTER_TABLE_STATEMENTS: seq[string] = @[
   # example: adding a new column
   """ALTER TABLE traces ADD COLUMN calltraceMode text;""",
   """ALTER TABLE traces RENAME COLUMN callgraph TO calltrace"""
   # """ALTER TABLE traces ADD COLUMN love integer;"""
]
