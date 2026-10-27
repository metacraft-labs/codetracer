## test_event_log_kinds.nim — the terminal event log's reading of the wire's
## event kinds, Tier 1, on constructed kind ordinals.
##
## The pane receives an event's kind as the `EventLogKind` ordinal the
## db-backend sends (`trace-events.md` §"EventLogKind (u8 enum)"). Its `Kind*`
## constants are spelled out rather than imported, so this suite pins them to
## the spec's table, and pins which of §3.3.5's categories each kind is shown
## under. Every kind of the table is assigned a category; an ordinal past the
## table is UNKNOWN, never coloured like a known kind.
##
## No mocks: `categoryFor` is a pure function of the ordinal and the `stdout`
## flag, called here exactly as the pane calls it.

import std/unittest

import ../app/views/event_log

const SpecKinds = [
  (KindWrite, 0), (KindWriteFile, 1), (KindWriteOther, 2), (KindRead, 3),
  (KindReadFile, 4), (KindReadOther, 5), (KindReadDir, 6), (KindOpenDir, 7),
  (KindCloseDir, 8), (KindSocket, 9), (KindOpen, 10), (KindError, 11),
  (KindTraceLogEvent, 12), (KindEvmEvent, 13), (KindWriteStderr, 14),
  (KindExec, 15), (KindReadEnv, 16), (KindWriteEnv, 17), (KindStat, 18),
  (KindCreateDir, 19), (KindRemoveDir, 20), (KindRemoveFile, 21),
  (KindRename, 22), (KindChangeDir, 23),
]

suite "the terminal event log knows every EventLogKind":

  test "each Kind constant is its spec ordinal":
    for (constant, ordinal) in SpecKinds:
      check constant == ordinal

  test "every assigned kind has a category, and nothing past the table does":
    for (kind, _) in SpecKinds:
      check categoryFor(kind, stdout = true) != ecUnknown
      check categoryFor(kind, stdout = false) != ecUnknown
    for unassigned in [24, 25, 255]:
      check categoryFor(unassigned, stdout = true) == ecUnknown

  test "stderr is terminal output whatever the stdout flag says":
    check categoryFor(KindWriteStderr, stdout = true) == ecOutput
    check categoryFor(KindWriteStderr, stdout = false) == ecOutput

  test "a change to the filesystem or the environment is a mutation":
    for kind in [KindWriteEnv, KindCreateDir, KindRemoveDir, KindRemoveFile,
                 KindRename]:
      check categoryFor(kind, stdout = true) == ecMutation

  test "running a program, asking about an entry and moving are syscalls":
    for kind in [KindExec, KindReadEnv, KindStat, KindChangeDir]:
      check categoryFor(kind, stdout = true) == ecSyscall
