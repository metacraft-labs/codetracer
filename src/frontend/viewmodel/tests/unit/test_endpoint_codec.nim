## Every facade value type survives the wire, on both backends.
##
## `endpoint_codec.nim` is used by BOTH ends of the endpoint contract — the
## client encodes arguments and decodes payloads, the server does the reverse —
## so a codec that loses a field loses it symmetrically and nothing downstream
## notices. What catches that is a round trip over values chosen to be
## awkward: every enum value rather than one, empty and non-empty sequences,
## text with quotes and newlines and non-ASCII, negative and large integers,
## and bytes that are not printable characters.
##
## The two claims the module's header makes that are only observable here:
##
##   1. **An unknown enum name RAISES.** `vfsDeleted` decoded as
##      `vfsUnmodified` would show a deleted file as unchanged; `psStderr` as
##      `psStdout` would put a compiler's diagnostics in the wrong stream. A
##      value that is silently wrong is worse than a refusal that says so.
##      This is deliberately the opposite of `endpoint_protocol`'s treatment of
##      an unknown *capability*, which is kept and reported.
##   2. **Bytes survive as bytes.** Base64 rather than a JSON string, because a
##      string would have to be valid UTF-8 and a `.wasm` is not.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[json, strutils, unittest]

import ../../platform/fs
import ../../platform/process
import ../../platform/vcs
import ../../platform/settings
import ../../platform/download
import ../../platform/shell
import ../../platform/endpoint_codec

const ExpectedAssertions = 111
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

template raisesProtocolError(body: untyped) =
  inc counted
  var raised = false
  try:
    body
  except ProtocolError:
    raised = true
  except CatchableError:
    raised = false
  check raised

## Text chosen to break a codec that concatenates rather than encodes.
const Awkward = "a \"quoted\" line\nwith \\ backslash and é, 日本語, \t tab"

suite "enums travel by name, exhaustively":
  test "every value of every enum round-trips":
    # Exhaustive rather than representative: a codec that mapped one value
    # wrong would pass a spot check, and these enums are what decide whether a
    # file is shown as deleted or unchanged.
    for v in FsEntryKind: ck decodeFsEntryKind(encodeFsEntryKind(v)) == v
    for v in FsWatchEventKind: ck decodeFsWatchEventKind(encodeFsWatchEventKind(v)) == v
    for v in ProcessStream: ck decodeProcessStream(encodeProcessStream(v)) == v
    for v in ProcessSignal: ck decodeProcessSignal(encodeProcessSignal(v)) == v
    for v in VcsFileStatus: ck decodeVcsFileStatus(encodeVcsFileStatus(v)) == v
    for v in VcsBlobSource: ck decodeVcsBlobSource(encodeVcsBlobSource(v)) == v
    for v in SettingsScope: ck decodeSettingsScope(encodeSettingsScope(v)) == v

  test "a name this build does not know RAISES, rather than defaulting":
    raisesProtocolError: discard decodeVcsFileStatus(%"vfsHaunted")
    raisesProtocolError: discard decodeProcessStream(%"psTelepathy")
    raisesProtocolError: discard decodeFsEntryKind(%"")
    raisesProtocolError: discard decodeSettingsScope(newJNull())
    raisesProtocolError: discard decodeFsWatchEventKind(%7)

suite "bytes":
  test "arbitrary bytes survive, including 0x00 and 0xFF":
    let bytes = @[byte 0, 1, 127, 128, 200, 255, 0, 65]
    ck decodeBytes(encodeBytes(bytes)) == bytes
    ck decodeBytes(encodeBytes(@[])) == newSeq[byte]()

  test "a byte sequence is NOT sent as a JSON string":
    # A `.wasm` is not valid UTF-8, and a JSON string has to be. The encoding
    # is base64 for that reason, so the encoded form must not be the bytes.
    let bytes = @[byte 0xC3, 0x28]  # invalid UTF-8 on purpose
    ck encodeBytes(bytes).getStr != "\xC3\x28"
    ck decodeBytes(encodeBytes(bytes)) == bytes

  test "text that is not base64 is refused":
    raisesProtocolError: discard decodeBytes(%"not base64 !!!")

suite "filesystem values":
  test "FsStat, including a large timestamp and a negative size":
    let v = FsStat(kind: fekSymlink, size: -1, modifiedMs: 1790762513000'i64,
                   readOnly: true)
    let got = decodeFsStat(encodeFsStat(v))
    ck got.kind == v.kind
    ck got.size == v.size
    ck got.modifiedMs == v.modifiedMs
    ck got.readOnly == v.readOnly

  test "directory entries, empty and not":
    ck decodeFsDirEntries(encodeFsDirEntries(@[])).len == 0
    let entries = @[FsDirEntry(name: Awkward, kind: fekDirectory),
                    FsDirEntry(name: "b.nim", kind: fekFile)]
    let got = decodeFsDirEntries(encodeFsDirEntries(entries))
    ck got.len == 2
    ck got[0].name == Awkward
    ck got[0].kind == fekDirectory
    ck got[1].kind == fekFile

  test "a watch event, and a rename's previous path":
    let v = FsWatchEvent(kind: fwkRenamed, path: "/new", previousPath: "/old")
    let got = decodeFsWatchEvent(encodeFsWatchEvent(v))
    ck got.kind == fwkRenamed
    ck got.path == "/new"
    ck got.previousPath == "/old"

  test "handles are opaque and survive verbatim":
    ck string(decodeFsWatchHandle(encodeFsWatchHandle(FsWatchHandle("w-3")))) == "w-3"
    ck string(decodeProcessHandle(encodeProcessHandle(ProcessHandle("p-9")))) == "p-9"

suite "process values":
  test "a spec with environment additions and no working directory":
    let v = ProcessSpec(
      command: "git", args: @["log", "--format=%H", Awkward],
      workingDir: "", env: @[(key: "GIT_PAGER", value: "cat"),
                             (key: "LC_ALL", value: "C")],
      clearEnv: true, stdinText: Awkward, timeoutMs: 5000)
    let got = decodeProcessSpec(encodeProcessSpec(v))
    ck got.command == v.command
    ck got.args == v.args
    ck got.workingDir == ""
    ck got.env.len == 2
    ck got.env[0].key == "GIT_PAGER"
    ck got.env[1].value == "C"
    ck got.clearEnv
    ck got.stdinText == Awkward
    ck got.timeoutMs == 5000

  test "an empty spec is still a spec":
    let got = decodeProcessSpec(encodeProcessSpec(ProcessSpec()))
    ck got.args.len == 0
    ck got.env.len == 0
    ck not got.clearEnv

  test "a signalled exit is distinguishable from a non-zero one":
    # `ProcessExit`'s own comment: a cancelled run establishes nothing, and a
    # caller that conflates the two reports a cancellation as a failure. A
    # codec that dropped `signalled` would do the conflating.
    let killed = decodeProcessExit(encodeProcessExit(
      ProcessExit(exitCode: -1, signalled: true, signalName: "SIGKILL")))
    let failed = decodeProcessExit(encodeProcessExit(
      ProcessExit(exitCode: 1, signalled: false)))
    ck killed.signalled
    ck killed.signalName == "SIGKILL"
    ck killed.exitCode == -1
    ck not failed.signalled
    ck failed.exitCode == 1

  test "a run result carries both streams separately":
    let v = ProcessRunResult(exit: ProcessExit(exitCode: 2),
                             stdout: "out " & Awkward, stderr: "err")
    let got = decodeProcessRunResult(encodeProcessRunResult(v))
    ck got.stdout == "out " & Awkward
    ck got.stderr == "err"
    ck got.exit.exitCode == 2

  test "an output chunk keeps its stream":
    let got = decodeProcessOutputChunk(encodeProcessOutputChunk(
      ProcessOutputChunk(stream: psStderr, text: Awkward)))
    ck got.stream == psStderr
    ck got.text == Awkward

suite "version control values":
  test "a status with a rename, ahead and behind":
    let v = VcsStatus(
      branch: "agents", upstream: "origin/agents", ahead: 3, behind: 0,
      detached: false,
      changes: @[VcsFileChange(path: "b.nim", previousPath: "a.nim",
                               indexStatus: vfsRenamed,
                               workingTreeStatus: vfsModified)])
    let got = decodeVcsStatus(encodeVcsStatus(v))
    ck got.branch == "agents"
    ck got.upstream == "origin/agents"
    ck got.ahead == 3
    ck got.behind == 0
    ck not got.detached
    ck got.changes.len == 1
    ck got.changes[0].previousPath == "a.nim"
    ck got.changes[0].indexStatus == vfsRenamed
    ck got.changes[0].workingTreeStatus == vfsModified

  test "a detached status with no changes":
    let got = decodeVcsStatus(encodeVcsStatus(
      VcsStatus(detached: true, branch: "")))
    ck got.detached
    ck got.changes.len == 0

  test "commits, including a merge's two parents and a multi-line body":
    let v = @[VcsCommit(id: "a" & "0".repeat(39), shortId: "a000000",
                        parents: @["p1", "p2"], authorName: "Ada",
                        authorEmail: "ada@isonim.test",
                        authoredAtMs: 1790762513000'i64,
                        subject: "merge", body: "line one\nline two"),
              VcsCommit(id: "b", parents: @[])]
    let got = decodeVcsCommits(encodeVcsCommits(v))
    ck got.len == 2
    ck got[0].parents == @["p1", "p2"]
    ck got[0].authoredAtMs == 1790762513000'i64
    ck got[0].body == "line one\nline two"
    ck got[1].parents.len == 0

suite "dialog and window values":
  test "filters keep their extensions":
    let v = @[FileFilter(name: "Noir sources", extensions: @["nr"]),
              FileFilter(name: "Everything", extensions: @["*"])]
    let got = decodeFileFilters(encodeFileFilters(v))
    ck got.len == 2
    ck got[0].extensions == @["nr"]
    ck got[1].extensions == @["*"]

  test "open and save options are not interchangeable":
    # `SaveDialogOptions` has `suggestedName` where `OpenDialogOptions` has
    # `defaultPath`, and its own comment says why: the web has no path to
    # default to. A codec that reused one shape would quietly make them the
    # same type.
    let open = decodeOpenDialogOptions(encodeOpenDialogOptions(
      OpenDialogOptions(title: "t", defaultPath: "/p", allowMultiple: true)))
    ck open.defaultPath == "/p"
    ck open.allowMultiple
    let save = decodeSaveDialogOptions(encodeSaveDialogOptions(
      SaveDialogOptions(title: "t", suggestedName: "n.nr",
                        defaultDirectory: "/d")))
    ck save.suggestedName == "n.nr"
    ck save.defaultDirectory == "/d"

  test "window state carries four independent flags":
    let v = WindowState(maximized: true, minimized: false, fullscreen: true,
                        focused: false)
    let got = decodeWindowState(encodeWindowState(v))
    ck got.maximized
    ck not got.minimized
    ck got.fullscreen
    ck not got.focused

suite "scalars":
  test "text with anything in it":
    ck decodeText(encodeText(Awkward)) == Awkward
    ck decodeText(encodeText("")) == ""
    ck decodeTextSeq(encodeTextSeq(@[Awkward, ""])) == @[Awkward, ""]
    ck decodeTextSeq(encodeTextSeq(@[])).len == 0

  test "a missing or wrongly-typed scalar does not become a plausible value":
    ck decodeText(newJNull()) == ""
    ck decodeText(%7) == ""
    ck not decodeFlag(newJNull())
    ck not decodeFlag(%"true")
    ck decodeFlag(%true)

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
