## Subprocess helper for ``cross_machine_replay_test.nim`` (M-REC-10).
##
## Each scenario runs in its own subprocess with ``XDG_DATA_HOME`` (and
## friends) pre-pointed at a tmpdir so the helper can play the role of a
## fresh host with its own ``trace_index.db`` and its own
## ``<codetracerTraceDir>/`` recording-folder tree.  The outer test
## orchestrates two such subprocesses (host A and host B) and verifies
## that a recording moved between them via the filesystem is loadable on
## host B without a DB-surgery / remap step.
##
## The contract under test is the parent spec's primary goal: recordings
## are portable across machines because the ``recording_id`` is minted
## by the recorder, embedded in ``meta.dat`` (M-REC-1), used as the
## folder name (M-REC-7), and preserved when imported on the other host
## (M-REC-10).  ``ct replay <recording_id>`` resolves the same id
## byte-for-byte on host A and host B.
##
## Scenarios:
##   record-host-a
##     Mint a recording_id, build a real meta.dat-bearing CTFS
##     ``trace.ct`` at ``<codetracerTraceDir>/<recording_id>/trace.ct``,
##     drop the matching DB row via ``trace_index.recordTrace``, and
##     print the recording_id (+ output folder, program, meta.dat id) to
##     stdout in a stable ``key=value`` shape that the parent process
##     parses.
##
##   replay-host-b <recording_id>
##     Simulate ``ct replay <recording_id>`` on a fresh host whose
##     ``trace_index.db`` was just initialised (no row for the moved
##     recording).  Performs the canonical lookup and asserts:
##       1. ``trace_index.find(recording_id)`` returns nil — proving the
##          gate (no DB row exists; this is what "no DB surgery" means).
##       2. The folder ``<codetracerTraceDir>/<recording_id>/`` exists
##          with a ``trace.ct`` inside — proving the user only copied
##          files, no extra setup.
##       3. ``importTrace(folder, NO_RECORDING_ID, ...)`` preserves the
##          recording_id from ``meta.dat``: the returned DB row has
##          ``recording_id`` equal to the host-A id.
##       4. The recording is now lookup-able by id: a second
##          ``trace_index.find`` returns a non-nil ``Trace`` with the
##          same id and ``output_folder``.
##       5. The ``recording_id`` printed to stdout is identical
##          byte-for-byte to the id host A emitted; the parent process
##          asserts this round-trip.
##
##   meta-dat-read <trace_ct_path> <expected_id>
##     Lightweight scenario: parse the ``meta.dat`` from a ``trace.ct``
##     via the production ``readCtfsMetaDat`` and assert the id matches.
##     The orchestrator uses this to verify the CTFS container survives
##     a ``tar`` + ``untar`` round-trip byte-for-byte.

import std/[os, strutils]

import paths
import recording_id
import types
import lang
import trace_index

# Pull in the real production importTrace plus its meta.dat reader.
# ``storage_and_import`` lives under ``../ct/trace`` relative to this
# helper; the relative import keeps the test self-contained.
import "../ct/trace/storage_and_import"
import "../ct/trace/ctfs_sources"

# ---------------------------------------------------------------------------
# Minimal meta.dat v3 + CTFS writer
# ---------------------------------------------------------------------------
#
# The codetracer source tree does NOT link against
# ``codetracer-trace-format-nim``'s ``multi_stream_writer`` (the
# recorder lives in a sibling repo); the production trace-write path is
# only available via ``ct-mcr``.  To keep the test self-contained and
# fast, we serialize a meta.dat v3 by hand following the spec at
# ``codetracer-trace-format-spec/internal-files.md`` § Metadata
# (meta.dat), and wrap it in the minimal CTFS layout already proven by
# the sibling ``ctfs_sources_test.nim`` writer.  The acceptance contract
# is on the *reader* side (``ctfs_sources.readCtfsMetaDat`` parses the
# bytes; ``ct/trace/storage_and_import.importTrace`` consumes the
# parsed value); the writer here is a test fixture, not production
# code.

const
  CtfsMagic = "\xC0\xDE\x72\xAC\xE2"
  CtfsVersion = 3
  CtmdMagic = "CTMD"
  MetaDatVersion: uint16 = 3
  BlockSize = 1024
  MaxEntries = 8
  Base40Alphabet = "\0" & "0123456789abcdefghijklmnopqrstuvwxyz./-"

proc putU16Le(buf: var string, value: uint16) =
  buf.add char(value and 0xff)
  buf.add char((value shr 8) and 0xff)

proc putU32Le(buf: var string, value: uint32) =
  for i in 0 ..< 4:
    buf.add char((value shr (8 * i)) and 0xff)

proc putU64Le(buf: var string, value: uint64) =
  for i in 0 ..< 8:
    buf.add char((value shr (8 * i)) and 0xff)

proc putLeb128(buf: var string, value: uint64) =
  ## LEB128 unsigned varint, matching the ``readLeb128`` decoder in
  ## ``ctfs_sources.nim`` (which is the byte-for-byte parser side).
  var remaining = value
  while true:
    var b = byte(remaining and 0x7f)
    remaining = remaining shr 7
    if remaining != 0:
      b = b or 0x80
    buf.add char(b)
    if remaining == 0:
      break

proc putVarString(buf: var string, value: string) =
  buf.putLeb128(uint64(value.len))
  buf.add value

proc base40Encode(name: string): uint64 =
  ## Same encoding the CTFS reader (``ctfs_sources.base40Decode``)
  ## inverts.  Names longer than 12 characters cannot round-trip in 64
  ## bits; ``meta.dat`` and ``trace.ct`` are short enough.
  var multiplier = uint64 1
  for c in name:
    let index = Base40Alphabet.find(c)
    doAssert index >= 0, "char '" & $c & "' not in base40 alphabet"
    result += uint64(index) * multiplier
    multiplier *= 40

proc buildMetaDat(recordingId, program, workdir, recorderId: string;
                  args, srcPaths: seq[string]): string =
  ## Serialize a meta.dat v3 with the minimum required fields and no
  ## extended-block flags set.  Field order matches the spec at
  ## ``codetracer-trace-format-spec/internal-files.md`` § Metadata
  ## (recording_id → program → args → workdir → recorder_id → paths).
  result.add CtmdMagic
  result.putU16Le(MetaDatVersion)
  result.putU16Le(0)  # flags=0 (no extended blocks).
  result.putVarString(recordingId)
  result.putVarString(program)
  result.putLeb128(uint64(args.len))
  for a in args:
    result.putVarString(a)
  result.putVarString(workdir)
  result.putVarString(recorderId)
  result.putLeb128(uint64(srcPaths.len))
  for p in srcPaths:
    result.putVarString(p)

proc writeMinimalCtfsContainer(path: string; files: openArray[(string, string)]) =
  ## Minimal CTFS layout: one mapping block + one data block per
  ## internal file, all ``BlockSize`` bytes.  Matches the
  ## ``write_minimal_ctfs`` writer in
  ## ``src/backend-manager/src/meta_dat.rs`` and the
  ## ``writeMinimalCtfs`` helper in ``ctfs_sources_test.nim``.  Use only
  ## for short inputs (<= ``BlockSize`` per file); both readers
  ## (Nim/Rust) accept this shape.
  doAssert files.len <= MaxEntries
  var root = ""
  root.add CtfsMagic
  root.add char(CtfsVersion)
  root.add char(0)
  root.add char(0)
  root.putU32Le(uint32(BlockSize))
  root.putU32Le(uint32(MaxEntries))
  for i, file in files:
    doAssert file[1].len <= BlockSize, "file " & file[0] & " too big for test fixture"
    let mapBlock = uint64(1 + i * 2)
    root.putU64Le(uint64(file[1].len))
    root.putU64Le(mapBlock)
    root.putU64Le(base40Encode(file[0]))
  for _ in files.len ..< MaxEntries:
    root.putU64Le(0)
    root.putU64Le(0)
    root.putU64Le(0)
  root.setLen(BlockSize)
  var data = root
  for i, file in files:
    let dataBlock = uint64(2 + i * 2)
    var mapping = ""
    mapping.putU64Le(dataBlock)
    mapping.setLen(BlockSize)
    data.add mapping
    var payload = file[1]
    payload.setLen(BlockSize)
    data.add payload
  writeFile(path, data)

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

proc fail(msg: string) =
  echo "FAIL: ", msg
  quit(1)

proc expectCanonicalUuidV7(id: string) =
  if id.len != 36:
    fail("expected canonical 36-char UUIDv7; got len=" & $id.len &
         " value=" & id)
  if not isCanonicalUuidV7(id):
    fail("expected canonical UUIDv7; got " & id)

proc writeRecordingFolder(folder, recordingId, program: string) =
  ## Lay down ``<folder>/trace.ct`` containing a real meta.dat v3 whose
  ## ``recording_id`` is ``recordingId``.  The orchestrator's ``tar`` of
  ## this folder is exactly what cross-machine ``scp`` would carry.
  let metaDatBytes = buildMetaDat(
    recordingId = recordingId,
    program = program,
    workdir = "/tmp",
    recorderId = "m-rec-10-test",
    args = @["--demo"],
    srcPaths = @["main.nim"])
  writeMinimalCtfsContainer(folder / "trace.ct",
                            [("meta.dat", metaDatBytes)])
  # Defensive: re-read what we just wrote and verify it parses through
  # the production CTFS reader path.  Catches encoder/decoder drift at
  # the *first* point of failure rather than letting host B blame
  # importTrace.
  let parsed = readCtfsMetaDat(folder / "trace.ct")
  if parsed.recordingId != recordingId:
    fail("self-check: meta.dat round-trip failed; wrote " & recordingId &
         " read " & parsed.recordingId)

proc scenarioRecordHostA(args: seq[string]) =
  ## Host A: mint a recording_id, lay down a real CTFS trace folder, and
  ## write the matching DB row.  Prints structured key=value output the
  ## parent process parses to drive host B.
  ##
  ## The output layout matches M-REC-7's contract:
  ##   <codetracerTraceDir>/<recording_id>/trace.ct
  ## with the DB row's ``output_folder`` pointing at the same path.
  let id = trace_index.newID(test = false)
  expectCanonicalUuidV7(id)

  let folder = paths.recordingFolder(codetracerTraceDir, id)
  createDir(folder)
  writeRecordingFolder(folder, id, "host-a-program")

  let trace = trace_index.recordTrace(
    id,
    program = "host-a-program",
    args = @["--demo"],
    compileCommand = "",
    env = "",
    workdir = "/tmp",
    lang = LangNoir,
    sourceFolders = "",
    lowLevelFolder = "",
    outputFolder = folder,
    test = false,
    imported = false,
    shellID = -1,
    rrPid = 0,
    exitCode = 0,
    calltrace = true,
    calltraceMode = CalltraceMode.FullRecord)
  if trace.isNil:
    fail("recordTrace returned nil")
  if trace.recordingId != id:
    fail("DB row id != minted id: db=" & trace.recordingId & " minted=" & id)

  # Sanity: meta.dat round-trips through the production reader (this is
  # the same call importTrace makes on the host-B side).
  let meta = readCtfsMetaDat(folder / "trace.ct")
  if meta.recordingId != id:
    fail("meta.dat recording_id mismatch: meta=" & meta.recordingId &
         " writer=" & id)

  echo "PASS"
  echo "recording_id=" & id
  echo "output_folder=" & folder
  echo "meta_program=" & meta.program
  echo "meta_recording_id=" & meta.recordingId
  echo "trace_ct=" & (folder / "trace.ct")

proc scenarioReplayHostB(args: seq[string]) =
  ## Host B: simulate ``ct replay <recording_id>`` on a host whose DB
  ## row for ``recording_id`` is absent (the parent process has not
  ## populated it; only the on-disk folder has been moved over).
  ##
  ## Asserts the M-REC-10 gate contract end-to-end (steps 1-5 in the
  ## module doc-comment).
  if args.len < 1:
    fail("usage: cross_machine_replay_test_helper replay-host-b <recording_id>")
  let recordingId = args[0]
  expectCanonicalUuidV7(recordingId)

  # M-REC-10 step 1: the gate is "no DB surgery".  Materialise the DB
  # (so ``find`` doesn't fault) and assert the row is genuinely absent.
  # ``newID`` is the cheapest way to bring up the DB without inserting
  # any rows that could mask the test.
  let dummyId = trace_index.newID(test = false)
  expectCanonicalUuidV7(dummyId)
  if dummyId == recordingId:
    fail("test environment bug: host-B newID collided with host-A id " &
         recordingId & " — should be astronomically improbable for UUIDv7")
  let pre = trace_index.find(recordingId, test = false)
  if not pre.isNil:
    fail("host B already has a DB row for " & recordingId &
         "; test environment is contaminated (output_folder=" &
         pre.outputFolder & ")")

  # M-REC-10 step 2: the folder must already be in place on disk — this
  # is the "tar + scp + place under <traces>/<recording_id>/" precondition.
  let expectedFolder = paths.recordingFolder(codetracerTraceDir, recordingId)
  if not dirExists(expectedFolder):
    fail("expected folder " & expectedFolder &
         " on host B; parent process should have placed it before " &
         "invoking the replay scenario")
  let expectedCt = expectedFolder / "trace.ct"
  if not fileExists(expectedCt):
    fail("expected trace.ct under " & expectedFolder & "; got nothing")

  # M-REC-10 step 3: the production importer
  # (``ct/trace/storage_and_import``) preserves the id from meta.dat.
  # Pre-M-REC-10 this branch minted a fresh UUIDv7, silently breaking
  # cross-machine identity.
  var imported: Trace
  try:
    imported = importTrace(
      expectedFolder,
      "",  # NO_RECORDING_ID — exercises the meta.dat-preserve branch.
      0,
      LangUnknown,
      traceKind = "db")
  except CatchableError as e:
    fail("importTrace raised: " & e.msg)
  if imported.isNil:
    fail("importTrace returned nil for " & expectedFolder)
  if imported.recordingId != recordingId:
    fail("M-REC-10 regression: importTrace minted a fresh id (" &
         imported.recordingId & ") instead of preserving the meta.dat id (" &
         recordingId & ")")
  if imported.outputFolder != expectedFolder:
    fail("importTrace output_folder mismatch: got " & imported.outputFolder &
         " expected " & expectedFolder)

  # M-REC-10 step 4: the recording is now lookup-able by id — the same
  # ``ct replay <recording_id>`` invocation would succeed on a second
  # call (the DB row is now populated, so ``resolveRecordingId``'s
  # ``trace_index.find`` returns non-nil).
  let post = trace_index.find(recordingId, test = false)
  if post.isNil:
    fail("post-import find returned nil for " & recordingId)
  if post.recordingId != recordingId:
    fail("post-import find returned wrong id: got " & post.recordingId &
         " expected " & recordingId)
  if post.outputFolder != expectedFolder:
    fail("post-import find returned wrong folder: got " & post.outputFolder &
         " expected " & expectedFolder)

  # M-REC-10 step 5: byte-for-byte equality.  The recording_id printed
  # to stdout here MUST match what host A emitted; the parent process
  # asserts this round-trip explicitly.
  echo "PASS"
  echo "recording_id=" & post.recordingId
  echo "output_folder=" & post.outputFolder
  echo "program=" & post.program

proc scenarioMetaDatRead(args: seq[string]) =
  ## Standalone post-tar sanity check: parse ``meta.dat`` from a path
  ## and assert the recording_id matches the expected value.  The
  ## orchestrator uses this to verify the CTFS container survives
  ## tar+untar without corruption (a strict subset of "the folder was
  ## moved verbatim").
  if args.len < 2:
    fail("usage: cross_machine_replay_test_helper meta-dat-read " &
         "<trace_ct_path> <expected_id>")
  let traceCt = args[0]
  let expectedId = args[1]
  expectCanonicalUuidV7(expectedId)
  if not fileExists(traceCt):
    fail("trace.ct missing at " & traceCt)
  let meta = readCtfsMetaDat(traceCt)
  if meta.recordingId != expectedId:
    fail("post-transfer meta.dat id mismatch: got " & meta.recordingId &
         " expected " & expectedId)
  echo "PASS"
  echo "recording_id=" & meta.recordingId

when isMainModule:
  if paramCount() < 1:
    fail("usage: cross_machine_replay_test_helper <scenario> [args...]")
  let scenario = paramStr(1)
  var rest: seq[string] = @[]
  for i in 2 .. paramCount():
    rest.add(paramStr(i))
  case scenario
  of "record-host-a": scenarioRecordHostA(rest)
  of "replay-host-b": scenarioReplayHostB(rest)
  of "meta-dat-read": scenarioMetaDatRead(rest)
  else:
    fail("unknown scenario: " & scenario)
