## Every verb of the container platform, argument object and payload, over a
## real §6.2 frame pair.
##
## ## What this covers that `test_platform_facade.nim` does not
##
## That suite's `test_a_remote_instantiation_needs_no_signature_change` asks
## whether the SIGNATURES survive an out-of-process instantiation, and it
## answers it with seven verbs. The contract
## (`Architecture/UI-Bundle-And-Endpoints.md` §6) has sixty-one, and §6.2's
## change from `\x1f`-separated strings to named JSON fields moved the failure
## mode: a positional encoding gets its arity checked, a named one does not, so
## `fs.copy` sending `{"destination": src, "source": dst}` is a wire that
## type-checks, compiles, round-trips, and copies the wrong way. Nothing but a
## per-verb assertion on the NAMES catches that.
##
## ## The fake is a server, not a recorder of client objects
##
## The transport does not read `request.args` directly. It runs them through
## `encodeCall` and `decodeCall` — the real frame codec — and asserts against
## what comes back out, and it builds every reply with `encodeReply` and reads
## it with `decodeReply`. Reading the client's own `JsonNode` would pass for a
## codec that produced something no `$` / `parseJson` pair survives, which is
## the one property a wire has to have and an in-memory object never tests.
##
## ## Why the payload types are exercised through the facade
##
## `test_endpoint_codec.nim` already round-trips every value type directly.
## What it cannot say is that the *platform* reaches for the right one: a
## `fs.stat` decoded with the wrong decoder is a codec that is individually
## correct and collectively wrong. So every payload type here arrives as the
## return value of the facade call that is supposed to produce it.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[json, strutils, unittest]

import ../../platform/platform
import ../../platform/endpoint_codec
import ../../host/container_platform

const ExpectedAssertions = 365
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

## Text chosen to break a wire that concatenates rather than encodes — the
## record separators the old encoding used are in it deliberately.
const Awkward = "a \"quoted\" line\nwith \\ back\x1fslash and é, 日本語,\ttab"

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## Settle a facade future and hand back its outcome. The drain is here, once,
  ## and `settled` is checked, for the reason `test_platform_facade.nim` states
  ## at length: `async_compat` queues even a synchronously resolved future's
  ## callback on the JS target while running it inline on native, so a test
  ## that forgot it would pass on one backend and assert nothing on the other.
  var captured: PlatformOutcome[T]
  var settled = false

  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true

  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true

  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "a facade future never settled"
  captured

# ---------------------------------------------------------------------------

template withEndpoint(body: untyped) =
  ## One fake endpoint, shared by every case below.
  ##
  ## Written as a template rather than as `unittest`'s `setup:` because the
  ## suites are several and the fake is one thing; a `setup:` per suite is the
  ## same code four times over, which is how two of them end up disagreeing
  ## about what the server does.
  block:
    var seenVerb {.inject.} = ""
    var seenArgs {.inject.}: JsonNode = newJObject()
    var calls {.inject.} = 0
    var nextPayload {.inject.}: JsonNode = newJNull()
    var nextOk {.inject.} = true
    var nextErrorKind {.inject.} = pkFailed
    var nextErrorMessage {.inject.} = ""

    let transport: RemoteTransport = proc(request: RemoteRequest
                                         ): PlatformFuture[RemoteResponse] =
      inc calls
      # Out through the wire and back in, both directions. See the header.
      let heard = decodeCall(encodeCall(
        CallFrame(id: calls, verb: request.verb, args: request.args)))
      seenVerb = heard.verb
      seenArgs = heard.args
      let answered = decodeReply(encodeReply(
        if nextOk: ReplyFrame(id: calls, ok: true, payload: nextPayload)
        else: ReplyFrame(id: calls, ok: false, errorKind: nextErrorKind,
                         errorMessage: nextErrorMessage)))
      # `newCompletedFuture`, not a bare promise: a plain `newPromise` would
      # push the value onto V8's microtask queue, which no headless test can
      # drain, and every assertion would quietly stop running on the JS
      # backend while still reporting green.
      newCompletedFuture(RemoteResponse(
        ok: answered.ok, payload: answered.payload,
        errorKind: answered.errorKind, errorMessage: answered.errorMessage))

    # The profile is NAMED here. §6.3 gives shipping code the other overload,
    # which takes it from the `welcome` frame; a suite that wants
    # `containerProfile` has to say so, and that is the whole point of the
    # constructor no longer defaulting.
    let remote {.inject.} = newContainerPlatform(transport, containerProfile)
    body

# ---------------------------------------------------------------------------

suite "filesystem verbs":

  test "fs.readText names its path and returns the text unharmed":
    withEndpoint:
      nextPayload = encodeText(Awkward)
      let outcome = awaitOutcome(remote.fs.readText("/w/" & Awkward))
      ck seenVerb == "fs.readText"
      ck jstr(seenArgs, "path") == "/w/" & Awkward
      ck outcome.ok
      ck outcome.value == Awkward

  test "fs.readBytes carries bytes as base64, not as a JSON string of them":
    withEndpoint:
      let bytes = @[byte 0, 1, 127, 128, 200, 255, 0, 65]
      nextPayload = encodeBytes(bytes)
      let outcome = awaitOutcome(remote.fs.readBytes("/w/a.wasm"))
      ck seenVerb == "fs.readBytes"
      ck jstr(seenArgs, "path") == "/w/a.wasm"
      ck outcome.ok
      ck outcome.value == bytes

  test "fs.writeText names path and content separately":
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.writeText("/w/a.nr", Awkward))
      ck seenVerb == "fs.writeText"
      ck jstr(seenArgs, "path") == "/w/a.nr"
      ck jstr(seenArgs, "content") == Awkward
      ck outcome.ok

  test "fs.writeBytes sends base64 content, so a .wasm is not UTF-8 validated":
    withEndpoint:
      let bytes = @[byte 0, 97, 115, 109, 255, 0]
      let outcome = awaitOutcome(remote.fs.writeBytes("/w/a.wasm", bytes))
      ck seenVerb == "fs.writeBytes"
      ck jstr(seenArgs, "path") == "/w/a.wasm"
      ck seenArgs["content"].kind == JString
      ck decodeBytes(jrequire(seenArgs, "content")) == bytes
      ck outcome.ok

  test "fs.appendText names path and content separately":
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.appendText("/w/log", "line\n"))
      ck seenVerb == "fs.appendText"
      ck jstr(seenArgs, "path") == "/w/log"
      ck jstr(seenArgs, "content") == "line\n"
      ck outcome.ok

  test "fs.stat returns an FsStat with its int64 fields intact":
    withEndpoint:
      # A size and a timestamp that do not fit in 32 bits, because the whole
      # reason `FsStat` carries `int64` is that both routinely do not.
      let stat = FsStat(kind: fekSymlink, size: 5_000_000_000'i64,
                        modifiedMs: 1_700_000_000_000'i64, readOnly: true)
      nextPayload = encodeFsStat(stat)
      let outcome = awaitOutcome(remote.fs.stat("/w/link"))
      ck seenVerb == "fs.stat"
      ck jstr(seenArgs, "path") == "/w/link"
      ck outcome.ok
      ck outcome.value.kind == fekSymlink
      ck outcome.value.size == 5_000_000_000'i64
      ck outcome.value.modifiedMs == 1_700_000_000_000'i64
      ck outcome.value.readOnly

  test "fs.listDir returns entries, and an empty directory is not an error":
    withEndpoint:
      nextPayload = encodeFsDirEntries(@[
        FsDirEntry(name: "main.nr", kind: fekFile),
        FsDirEntry(name: Awkward, kind: fekDirectory)])
      let outcome = awaitOutcome(remote.fs.listDir("/w/src"))
      ck seenVerb == "fs.listDir"
      ck jstr(seenArgs, "path") == "/w/src"
      ck outcome.ok
      ck outcome.value.len == 2
      ck outcome.value[0].name == "main.nr"
      ck outcome.value[0].kind == fekFile
      ck outcome.value[1].name == Awkward
      ck outcome.value[1].kind == fekDirectory

      nextPayload = encodeFsDirEntries(@[])
      let empty = awaitOutcome(remote.fs.listDir("/w/empty"))
      ck empty.ok
      ck empty.value.len == 0

  test "fs.createDir names its path":
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.createDir("/w/out"))
      ck seenVerb == "fs.createDir"
      ck jstr(seenArgs, "path") == "/w/out"
      ck outcome.ok

  test "fs.remove carries the recursive flag as a boolean, both ways":
    withEndpoint:
      discard awaitOutcome(remote.fs.remove("/w/out", recursive = true))
      ck seenVerb == "fs.remove"
      ck jstr(seenArgs, "path") == "/w/out"
      ck seenArgs["recursive"].kind == JBool
      ck jbool(seenArgs, "recursive")
      discard awaitOutcome(remote.fs.remove("/w/one", recursive = false))
      ck not jbool(seenArgs, "recursive")

  test "fs.copy names source and destination, and does not transpose them":
    ## The named case for the transposition §6.2's named fields exist to make
    ## impossible. A positional encoding would have `@["/a", "/b"]` here and
    ## the two orders are indistinguishable.
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.copy("/w/from.nr", "/w/to.nr"))
      ck seenVerb == "fs.copy"
      ck jstr(seenArgs, "source") == "/w/from.nr"
      ck jstr(seenArgs, "destination") == "/w/to.nr"
      ck outcome.ok

  test "fs.move names source and destination, and does not transpose them":
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.move("/w/from.nr", "/w/to.nr"))
      ck seenVerb == "fs.move"
      ck jstr(seenArgs, "source") == "/w/from.nr"
      ck jstr(seenArgs, "destination") == "/w/to.nr"
      ck outcome.ok

  test "fs.realPath names its path and returns a path":
    withEndpoint:
      nextPayload = encodeText("/w/real")
      let outcome = awaitOutcome(remote.fs.realPath("/w/link"))
      ck seenVerb == "fs.realPath"
      ck jstr(seenArgs, "path") == "/w/link"
      ck outcome.ok
      ck outcome.value == "/w/real"

  test "fs.makeTempDir names its argument `prefix`, not `path`":
    ## Its parameter is a prefix and not a path, and the name is what says so
    ## to the dispatch on the other side.
    withEndpoint:
      nextPayload = encodeText("/tmp/ct-xyz")
      let outcome = awaitOutcome(remote.fs.makeTempDir("ct-"))
      ck seenVerb == "fs.makeTempDir"
      ck jstr(seenArgs, "prefix") == "ct-"
      ck seenArgs{"path"}.isNil
      ck outcome.ok
      ck outcome.value == "/tmp/ct-xyz"

  test "fs.watch returns an opaque handle and does not send the callback":
    ## The signature accommodating a callback is the claim NS1 made; what the
    ## wire carries is the path, the flag and nothing else, and the handle is
    ## what §6.2's `event` frames are keyed on.
    withEndpoint:
      var events = 0
      proc onEvent(event: FsWatchEvent) = inc events
      nextPayload = encodeFsWatchHandle(FsWatchHandle("watch-7"))
      let outcome = awaitOutcome(
        remote.fs.watch("/w/src", recursive = true, onEvent))
      ck seenVerb == "fs.watch"
      ck jstr(seenArgs, "path") == "/w/src"
      ck jbool(seenArgs, "recursive")
      ck seenArgs.len == 2
      ck outcome.ok
      ck outcome.value == FsWatchHandle("watch-7")
      # Nothing streams over a one-hop transport, so the callback must not
      # have been invoked. A fake that called it would be asserting a feature
      # this module deliberately does not have.
      ck events == 0

  test "fs.unwatch quotes the handle back":
    withEndpoint:
      let outcome = awaitOutcome(remote.fs.unwatch(FsWatchHandle("watch-7")))
      ck seenVerb == "fs.unwatch"
      ck decodeFsWatchHandle(jrequire(seenArgs, "handle")) ==
        FsWatchHandle("watch-7")
      ck outcome.ok

# ---------------------------------------------------------------------------

suite "process verbs":

  test "process.run sends the whole spec under one name, every field intact":
    withEndpoint:
      var spec = processSpec("nargo", @["test", Awkward], workingDir = "/w")
      spec.env = @[(key: "RUST_LOG", value: "debug"), (key: "X", value: "")]
      spec.clearEnv = true
      spec.stdinText = Awkward
      spec.timeoutMs = 30_000
      nextPayload = encodeProcessRunResult(ProcessRunResult(
        exit: ProcessExit(exitCode: 3, signalled: true, signalName: "SIGKILL"),
        stdout: "compiled", stderr: Awkward))
      let outcome = awaitOutcome(remote.process.run(spec))
      ck seenVerb == "process.run"
      let sent = decodeProcessSpec(jrequire(seenArgs, "spec"))
      ck sent.command == "nargo"
      ck sent.args == @["test", Awkward]
      ck sent.workingDir == "/w"
      ck sent.env == spec.env
      ck sent.clearEnv
      ck sent.stdinText == Awkward
      ck sent.timeoutMs == 30_000
      ck outcome.ok
      ck outcome.value.exit.exitCode == 3
      ck outcome.value.exit.signalled
      ck outcome.value.exit.signalName == "SIGKILL"
      ck outcome.value.stdout == "compiled"
      ck outcome.value.stderr == Awkward

  test "process.start returns an opaque handle and sends neither callback":
    withEndpoint:
      var chunks = 0
      var exits = 0
      proc onOutput(chunk: ProcessOutputChunk) = inc chunks
      proc onExit(exit: ProcessExit) = inc exits
      nextPayload = encodeProcessHandle(ProcessHandle("proc-2"))
      let outcome = awaitOutcome(remote.process.start(
        processSpec("nargo", @["build"]), onOutput, onExit))
      ck seenVerb == "process.start"
      ck decodeProcessSpec(jrequire(seenArgs, "spec")).command == "nargo"
      ck seenArgs.len == 1
      ck outcome.ok
      ck outcome.value == ProcessHandle("proc-2")
      ck chunks == 0
      ck exits == 0

  test "process.signal sends every signal by NAME, not by ordinal":
    ## Exhaustive over the enum, because an ordinal encoding renumbers the
    ## whole contract the day a value is inserted — which is the reason
    ## `endpoint_codec` spells enums out.
    withEndpoint:
      for signal in ProcessSignal:
        discard awaitOutcome(
          remote.process.signal(ProcessHandle("proc-2"), signal))
        ck seenVerb == "process.signal"
        ck decodeProcessHandle(jrequire(seenArgs, "handle")) ==
          ProcessHandle("proc-2")
        ck seenArgs["signal"].kind == JString
        ck decodeProcessSignal(jrequire(seenArgs, "signal")) == signal

  test "process.writeStdin names handle and text":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.process.writeStdin(ProcessHandle("proc-2"), Awkward))
      ck seenVerb == "process.writeStdin"
      ck decodeProcessHandle(jrequire(seenArgs, "handle")) ==
        ProcessHandle("proc-2")
      ck jstr(seenArgs, "text") == Awkward
      ck outcome.ok

  test "process.closeStdin quotes the handle back":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.process.closeStdin(ProcessHandle("proc-2")))
      ck seenVerb == "process.closeStdin"
      ck decodeProcessHandle(jrequire(seenArgs, "handle")) ==
        ProcessHandle("proc-2")
      ck outcome.ok

  test "process.isRunning returns a boolean, and false is not an absence":
    withEndpoint:
      nextPayload = encodeFlag(false)
      let outcome = awaitOutcome(
        remote.process.isRunning(ProcessHandle("proc-2")))
      ck seenVerb == "process.isRunning"
      ck decodeProcessHandle(jrequire(seenArgs, "handle")) ==
        ProcessHandle("proc-2")
      ck outcome.ok
      ck not outcome.value
      nextPayload = encodeFlag(true)
      ck awaitOutcome(remote.process.isRunning(ProcessHandle("p"))).value

  test "process.which names its argument `program`":
    withEndpoint:
      nextPayload = encodeText("/usr/bin/nargo")
      let outcome = awaitOutcome(remote.process.which("nargo"))
      ck seenVerb == "process.which"
      ck jstr(seenArgs, "program") == "nargo"
      ck outcome.ok
      ck outcome.value == "/usr/bin/nargo"

# ---------------------------------------------------------------------------

suite "version-control verbs":

  test "vcs.isRepository names its path and returns a boolean":
    withEndpoint:
      nextPayload = encodeFlag(true)
      let outcome = awaitOutcome(remote.vcs.isRepository("/w"))
      ck seenVerb == "vcs.isRepository"
      ck jstr(seenArgs, "path") == "/w"
      ck outcome.ok
      ck outcome.value

  test "vcs.repositoryRoot names its path and returns a path":
    withEndpoint:
      nextPayload = encodeText("/w")
      let outcome = awaitOutcome(remote.vcs.repositoryRoot("/w/src/main.nr"))
      ck seenVerb == "vcs.repositoryRoot"
      ck jstr(seenArgs, "path") == "/w/src/main.nr"
      ck outcome.ok
      ck outcome.value == "/w"

  test "vcs.status returns the panel's shape, every per-file status by name":
    withEndpoint:
      nextPayload = encodeVcsStatus(VcsStatus(
        branch: "main", upstream: "origin/main", ahead: 2, behind: 7,
        detached: true,
        changes: @[
          VcsFileChange(path: "src/main.nr", previousPath: "src/old.nr",
                        indexStatus: vfsRenamed,
                        workingTreeStatus: vfsModified),
          VcsFileChange(path: Awkward, previousPath: "",
                        indexStatus: vfsUnmodified,
                        workingTreeStatus: vfsDeleted)]))
      let outcome = awaitOutcome(remote.vcs.status("/w"))
      ck seenVerb == "vcs.status"
      ck jstr(seenArgs, "repository") == "/w"
      ck outcome.ok
      ck outcome.value.branch == "main"
      ck outcome.value.upstream == "origin/main"
      ck outcome.value.ahead == 2
      ck outcome.value.behind == 7
      ck outcome.value.detached
      ck outcome.value.changes.len == 2
      ck outcome.value.changes[0].previousPath == "src/old.nr"
      ck outcome.value.changes[0].indexStatus == vfsRenamed
      ck outcome.value.changes[0].workingTreeStatus == vfsModified
      ck outcome.value.changes[1].path == Awkward
      # The one that matters: a deleted file read as unmodified is a panel
      # showing a file that is not there.
      ck outcome.value.changes[1].workingTreeStatus == vfsDeleted

  test "vcs.log names repository, maxCount and path, and returns commits":
    withEndpoint:
      nextPayload = encodeVcsCommits(@[
        VcsCommit(id: "a".repeat(40), shortId: "aaaaaaa",
                  parents: @["b".repeat(40), "c".repeat(40)],
                  authorName: Awkward, authorEmail: "a@b.c",
                  authoredAtMs: 1_700_000_000_000'i64,
                  subject: "first", body: Awkward)])
      let outcome = awaitOutcome(remote.vcs.log("/w", 20, "src/main.nr"))
      ck seenVerb == "vcs.log"
      ck jstr(seenArgs, "repository") == "/w"
      ck seenArgs["maxCount"].kind == JInt
      ck jint(seenArgs, "maxCount") == 20
      ck jstr(seenArgs, "path") == "src/main.nr"
      ck outcome.ok
      ck outcome.value.len == 1
      ck outcome.value[0].parents.len == 2
      ck outcome.value[0].authorName == Awkward
      ck outcome.value[0].authoredAtMs == 1_700_000_000_000'i64
      ck outcome.value[0].body == Awkward

  test "vcs.readBlob sends every blob source BY NAME":
    ## The named case for the enum codec. Exhaustive over `VcsBlobSource`
    ## because the three differ by one word and an ordinal would make the
    ## working tree readable as the index.
    withEndpoint:
      for source in VcsBlobSource:
        nextPayload = encodeText(Awkward)
        let outcome = awaitOutcome(
          remote.vcs.readBlob("/w", "src/main.nr", source))
        ck seenVerb == "vcs.readBlob"
        ck jstr(seenArgs, "repository") == "/w"
        ck jstr(seenArgs, "path") == "src/main.nr"
        ck seenArgs["source"].kind == JString
        ck decodeVcsBlobSource(jrequire(seenArgs, "source")) == source
        ck outcome.value == Awkward

  test "vcs.readBlobAt names an arbitrary revision, distinct from readBlob":
    withEndpoint:
      nextPayload = encodeText("old text")
      let outcome = awaitOutcome(
        remote.vcs.readBlobAt("/w", "src/main.nr", "HEAD~3"))
      ck seenVerb == "vcs.readBlobAt"
      ck jstr(seenArgs, "repository") == "/w"
      ck jstr(seenArgs, "path") == "src/main.nr"
      ck jstr(seenArgs, "revision") == "HEAD~3"
      ck seenArgs{"source"}.isNil
      ck outcome.value == "old text"

  test "vcs.diff sends a path LIST, a flag and a count, each as its own type":
    withEndpoint:
      nextPayload = encodeText("@@ -1 +1 @@\n")
      let outcome = awaitOutcome(
        remote.vcs.diff("/w", @["a.nr", Awkward], staged = true,
                        contextLines = 5))
      ck seenVerb == "vcs.diff"
      ck jstr(seenArgs, "repository") == "/w"
      ck seenArgs["paths"].kind == JArray
      ck decodeTextSeq(jrequire(seenArgs, "paths")) == @["a.nr", Awkward]
      ck jbool(seenArgs, "staged")
      ck jint(seenArgs, "contextLines") == 5
      ck outcome.ok
      ck outcome.value == "@@ -1 +1 @@\n"

  test "vcs.stage sends a path list, and an empty one stays empty":
    withEndpoint:
      let outcome = awaitOutcome(remote.vcs.stage("/w", @["a.nr", "b.nr"]))
      ck seenVerb == "vcs.stage"
      ck jstr(seenArgs, "repository") == "/w"
      ck decodeTextSeq(jrequire(seenArgs, "paths")) == @["a.nr", "b.nr"]
      ck outcome.ok
      discard awaitOutcome(remote.vcs.stage("/w", @[]))
      ck seenArgs["paths"].kind == JArray
      ck decodeTextSeq(jrequire(seenArgs, "paths")).len == 0

  test "vcs.unstage sends a path list":
    withEndpoint:
      let outcome = awaitOutcome(remote.vcs.unstage("/w", @["a.nr"]))
      ck seenVerb == "vcs.unstage"
      ck jstr(seenArgs, "repository") == "/w"
      ck decodeTextSeq(jrequire(seenArgs, "paths")) == @["a.nr"]
      ck outcome.ok

  test "vcs.discardChanges sends a path list":
    withEndpoint:
      let outcome = awaitOutcome(remote.vcs.discardChanges("/w", @["a.nr"]))
      ck seenVerb == "vcs.discardChanges"
      ck jstr(seenArgs, "repository") == "/w"
      ck decodeTextSeq(jrequire(seenArgs, "paths")) == @["a.nr"]
      ck outcome.ok

  test "vcs.applyPatch carries the patch text and the reverse flag":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.vcs.applyPatch("/w", Awkward, reverse = true))
      ck seenVerb == "vcs.applyPatch"
      ck jstr(seenArgs, "repository") == "/w"
      ck jstr(seenArgs, "patch") == Awkward
      ck jbool(seenArgs, "reverse")
      ck outcome.ok

  test "vcs.commit names author and email apart, and returns the commit":
    withEndpoint:
      nextPayload = encodeVcsCommit(VcsCommit(
        id: "f".repeat(40), shortId: "fffffff", parents: @[],
        authorName: "A U Thor", authorEmail: "a@b.c",
        authoredAtMs: 1'i64, subject: "s", body: ""))
      let outcome = awaitOutcome(
        remote.vcs.commit("/w", Awkward, "A U Thor", "a@b.c"))
      ck seenVerb == "vcs.commit"
      ck jstr(seenArgs, "repository") == "/w"
      ck jstr(seenArgs, "message") == Awkward
      ck jstr(seenArgs, "authorName") == "A U Thor"
      ck jstr(seenArgs, "authorEmail") == "a@b.c"
      ck outcome.ok
      ck outcome.value.shortId == "fffffff"
      ck outcome.value.parents.len == 0

  test "vcs.initRepository names its path":
    withEndpoint:
      let outcome = awaitOutcome(remote.vcs.initRepository("/w"))
      ck seenVerb == "vcs.initRepository"
      ck jstr(seenArgs, "path") == "/w"
      ck outcome.ok

  test "vcs.fetch names repository and remote":
    withEndpoint:
      let outcome = awaitOutcome(remote.vcs.fetch("/w", "origin"))
      ck seenVerb == "vcs.fetch"
      ck jstr(seenArgs, "repository") == "/w"
      ck jstr(seenArgs, "remote") == "origin"
      ck outcome.ok

  test "vcs.push names repository, remote and refspec":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.vcs.push("/w", "origin", "HEAD:refs/heads/main"))
      ck seenVerb == "vcs.push"
      ck jstr(seenArgs, "repository") == "/w"
      ck jstr(seenArgs, "remote") == "origin"
      ck jstr(seenArgs, "refspec") == "HEAD:refs/heads/main"
      ck outcome.ok

# ---------------------------------------------------------------------------

suite "settings verbs":

  test "settings.get sends every scope BY NAME and returns the value":
    ## Exhaustive over `SettingsScope`: the three differ in durability, and a
    ## `ssSession` key written as `ssUser` outlives the session it belonged to.
    withEndpoint:
      for scope in SettingsScope:
        nextPayload = encodeText(Awkward)
        let outcome = awaitOutcome(remote.settings.get(scope, "editor.theme"))
        ck seenVerb == "settings.get"
        ck seenArgs["scope"].kind == JString
        ck decodeSettingsScope(jrequire(seenArgs, "scope")) == scope
        ck jstr(seenArgs, "key") == "editor.theme"
        ck outcome.value == Awkward

  test "settings.set names scope, key and value":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.settings.set(ssWorkspace, "editor.theme", Awkward))
      ck seenVerb == "settings.set"
      ck decodeSettingsScope(jrequire(seenArgs, "scope")) == ssWorkspace
      ck jstr(seenArgs, "key") == "editor.theme"
      ck jstr(seenArgs, "value") == Awkward
      ck outcome.ok

  test "settings.delete names scope and key":
    withEndpoint:
      let outcome = awaitOutcome(remote.settings.delete(ssSession, "k"))
      ck seenVerb == "settings.delete"
      ck decodeSettingsScope(jrequire(seenArgs, "scope")) == ssSession
      ck jstr(seenArgs, "key") == "k"
      ck outcome.ok

  test "settings.keys names its argument `prefix` and returns a list":
    withEndpoint:
      nextPayload = encodeTextSeq(@["editor.theme", "editor.font"])
      let outcome = awaitOutcome(remote.settings.keys(ssUser, "editor."))
      ck seenVerb == "settings.keys"
      ck decodeSettingsScope(jrequire(seenArgs, "scope")) == ssUser
      ck jstr(seenArgs, "prefix") == "editor."
      ck seenArgs{"key"}.isNil
      ck outcome.ok
      ck outcome.value == @["editor.theme", "editor.font"]

  test "settings.environment names its argument `name`":
    withEndpoint:
      nextPayload = encodeText("/home/x")
      let outcome = awaitOutcome(remote.settings.environment("HOME"))
      ck seenVerb == "settings.environment"
      ck jstr(seenArgs, "name") == "HOME"
      ck outcome.ok
      ck outcome.value == "/home/x"

  test "settings.getSecret names account and key":
    withEndpoint:
      nextPayload = encodeText("s3cret")
      let outcome = awaitOutcome(remote.settings.getSecret("github", "token"))
      ck seenVerb == "settings.getSecret"
      ck jstr(seenArgs, "account") == "github"
      ck jstr(seenArgs, "key") == "token"
      ck outcome.ok
      ck outcome.value == "s3cret"

  test "settings.setSecret names account, key and value":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.settings.setSecret("github", "token", "s3cret"))
      ck seenVerb == "settings.setSecret"
      ck jstr(seenArgs, "account") == "github"
      ck jstr(seenArgs, "key") == "token"
      ck jstr(seenArgs, "value") == "s3cret"
      ck outcome.ok

  test "settings.deleteSecret names account and key":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.settings.deleteSecret("github", "token"))
      ck seenVerb == "settings.deleteSecret"
      ck jstr(seenArgs, "account") == "github"
      ck jstr(seenArgs, "key") == "token"
      ck outcome.ok

# ---------------------------------------------------------------------------

suite "clipboard verbs":

  test "clipboard.writeText names its text":
    withEndpoint:
      let outcome = awaitOutcome(remote.clipboard.writeText(Awkward))
      ck seenVerb == "clipboard.writeText"
      ck jstr(seenArgs, "text") == Awkward
      ck outcome.ok

  test "clipboard.readText takes no arguments and still sends an object":
    ## §6.2's `args` is a JSON object per verb; a nullary verb sends an empty
    ## one rather than omitting the field, so the server's dispatch has one
    ## shape to read rather than two.
    withEndpoint:
      nextPayload = encodeText(Awkward)
      let outcome = awaitOutcome(remote.clipboard.readText())
      ck seenVerb == "clipboard.readText"
      ck seenArgs.kind == JObject
      ck seenArgs.len == 0
      ck outcome.ok
      ck outcome.value == Awkward

  test "clipboard.writeHtml names html and its plain-text fallback apart":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.clipboard.writeHtml("<b>x</b>", "x"))
      ck seenVerb == "clipboard.writeHtml"
      ck jstr(seenArgs, "html") == "<b>x</b>"
      ck jstr(seenArgs, "plainText") == "x"
      ck outcome.ok

# ---------------------------------------------------------------------------

suite "download and dialog verbs":

  test "download.offerFile sends base64 content beside its name and type":
    withEndpoint:
      let bytes = @[byte 137, 80, 78, 71, 0, 255]
      let outcome = awaitOutcome(
        remote.download.offerFile("trace.png", bytes, "image/png"))
      ck seenVerb == "download.offerFile"
      ck jstr(seenArgs, "suggestedName") == "trace.png"
      ck seenArgs["content"].kind == JString
      ck decodeBytes(jrequire(seenArgs, "content")) == bytes
      ck jstr(seenArgs, "mimeType") == "image/png"
      ck outcome.ok

  test "download.offerText sends text content, NOT base64":
    ## The two verbs differ only in the type of `content`, which is the whole
    ## reason both exist; a client that base64'd this one would hand the user
    ## a file of base64.
    withEndpoint:
      let outcome = awaitOutcome(
        remote.download.offerText("a.nr", Awkward, "text/plain"))
      ck seenVerb == "download.offerText"
      ck jstr(seenArgs, "suggestedName") == "a.nr"
      ck jstr(seenArgs, "content") == Awkward
      ck jstr(seenArgs, "mimeType") == "text/plain"
      ck outcome.ok

  test "download.openFileDialog sends the options object, filters included":
    withEndpoint:
      let options = OpenDialogOptions(
        title: Awkward, defaultPath: "/w",
        filters: @[FileFilter(name: "Noir sources", extensions: @["nr"]),
                   FileFilter(name: "All", extensions: @["*"])],
        allowMultiple: true)
      nextPayload = encodeTextSeq(@["/w/a.nr", "/w/b.nr"])
      let outcome = awaitOutcome(remote.download.openFileDialog(options))
      ck seenVerb == "download.openFileDialog"
      let sent = decodeOpenDialogOptions(jrequire(seenArgs, "options"))
      ck sent.title == Awkward
      ck sent.defaultPath == "/w"
      ck sent.filters.len == 2
      ck sent.filters[0].name == "Noir sources"
      ck sent.filters[0].extensions == @["nr"]
      ck sent.allowMultiple
      ck outcome.ok
      ck outcome.value == @["/w/a.nr", "/w/b.nr"]
      # An empty list is a CANCEL, not an error — the facade says so, and the
      # wire has to be able to express it.
      nextPayload = encodeTextSeq(@[])
      let cancelled = awaitOutcome(remote.download.openFileDialog(options))
      ck cancelled.ok
      ck cancelled.value.len == 0

  test "download.saveFileDialog sends a SAVE options object, not an open one":
    ## `SaveDialogOptions` carries `suggestedName` where the open one carries
    ## `defaultPath`, and its own comment says why. A client that reused one
    ## shape would make them the same type on the wire.
    withEndpoint:
      let options = SaveDialogOptions(
        title: "Save", suggestedName: "trace.json", defaultDirectory: "/w",
        filters: @[FileFilter(name: "JSON", extensions: @["json"])])
      nextPayload = encodeText("/w/trace.json")
      let outcome = awaitOutcome(remote.download.saveFileDialog(options))
      ck seenVerb == "download.saveFileDialog"
      let sent = decodeSaveDialogOptions(jrequire(seenArgs, "options"))
      ck sent.suggestedName == "trace.json"
      ck sent.defaultDirectory == "/w"
      ck sent.filters.len == 1
      ck outcome.ok
      ck outcome.value == "/w/trace.json"
      nextPayload = encodeText("")
      ck awaitOutcome(remote.download.saveFileDialog(options)).value == ""

  test "download.pickDirectory sends open options and returns one path":
    withEndpoint:
      nextPayload = encodeText("/w/project")
      let outcome = awaitOutcome(remote.download.pickDirectory(
        OpenDialogOptions(title: "Open project", defaultPath: "/w")))
      ck seenVerb == "download.pickDirectory"
      ck decodeOpenDialogOptions(jrequire(seenArgs, "options")).title ==
        "Open project"
      ck outcome.ok
      ck outcome.value == "/w/project"

# ---------------------------------------------------------------------------

suite "shell verbs":

  test "shell.openExternalUrl names its url":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.shell.openExternalUrl("https://codetracer.com/"))
      ck seenVerb == "shell.openExternalUrl"
      ck jstr(seenArgs, "url") == "https://codetracer.com/"
      ck outcome.ok

  test "shell.revealInFileManager names its path":
    withEndpoint:
      let outcome = awaitOutcome(
        remote.shell.revealInFileManager("/w/src/main.nr"))
      ck seenVerb == "shell.revealInFileManager"
      ck jstr(seenArgs, "path") == "/w/src/main.nr"
      ck outcome.ok

  test "shell.windowState returns four independent flags":
    withEndpoint:
      nextPayload = encodeWindowState(WindowState(
        maximized: true, minimized: false, fullscreen: true, focused: false))
      let outcome = awaitOutcome(remote.shell.windowState())
      ck seenVerb == "shell.windowState"
      ck seenArgs.len == 0
      ck outcome.ok
      ck outcome.value.maximized
      ck not outcome.value.minimized
      ck outcome.value.fullscreen
      ck not outcome.value.focused

  test "shell.minimizeWindow is nullary":
    withEndpoint:
      let outcome = awaitOutcome(remote.shell.minimizeWindow())
      ck seenVerb == "shell.minimizeWindow"
      ck seenArgs.len == 0
      ck outcome.ok

  test "shell.toggleMaximizeWindow is nullary":
    withEndpoint:
      let outcome = awaitOutcome(remote.shell.toggleMaximizeWindow())
      ck seenVerb == "shell.toggleMaximizeWindow"
      ck seenArgs.len == 0
      ck outcome.ok

  test "shell.closeWindow is nullary":
    withEndpoint:
      let outcome = awaitOutcome(remote.shell.closeWindow())
      ck seenVerb == "shell.closeWindow"
      ck seenArgs.len == 0
      ck outcome.ok

  test "shell.setFullscreen carries a boolean, both ways":
    withEndpoint:
      discard awaitOutcome(remote.shell.setFullscreen(true))
      ck seenVerb == "shell.setFullscreen"
      ck seenArgs["fullscreen"].kind == JBool
      ck jbool(seenArgs, "fullscreen")
      discard awaitOutcome(remote.shell.setFullscreen(false))
      ck not jbool(seenArgs, "fullscreen")

  test "shell.openSessionWindow names its session id":
    withEndpoint:
      let outcome = awaitOutcome(remote.shell.openSessionWindow("s-42"))
      ck seenVerb == "shell.openSessionWindow"
      ck jstr(seenArgs, "sessionId") == "s-42"
      ck outcome.ok

# ---------------------------------------------------------------------------

suite "what the client reports, and what it refuses to invent":

  test "a refusal arrives as a value with its kind and message":
    withEndpoint:
      nextOk = false
      nextErrorKind = pkNotFound
      nextErrorMessage = "no nargo in the container"
      let outcome = awaitOutcome(remote.process.which("nargo"))
      ck not outcome.ok
      ck outcome.error.kind == pkNotFound
      ck outcome.error.message == "no nargo in the container"

  test "a failed reply that named no kind is pkFailed, never pkNone":
    ## `decodeReply`'s floor, observed through the facade: `pkNone` is the
    ## enum's "nothing went wrong" value, so a refusal carrying it would decode
    ## into a failure whose kind says there was no failure.
    withEndpoint:
      nextOk = false
      nextErrorKind = pkNone
      nextErrorMessage = ""
      let outcome = awaitOutcome(remote.fs.readText("/w/a.nr"))
      ck not outcome.ok
      ck outcome.error.kind == pkFailed

  test "a payload this build cannot READ is pkTransport, not a zero value":
    ## `endpoint_codec`'s decoders raise on an unknown enum name, and the raise
    ## happens inside a completion callback where nothing on the JS backend is
    ## left to catch it. `callRemote` turns it into the outcome every caller
    ## already handles. `pkTransport` because the server did not fail — the two
    ## ends disagreed about the bytes, which only this side can observe.
    withEndpoint:
      nextPayload = %*{"kind": "fekHaunted", "size": 1, "modifiedMs": 1,
                       "readOnly": false}
      let outcome = awaitOutcome(remote.fs.stat("/w/a.nr"))
      ck not outcome.ok
      ck outcome.error.kind == pkTransport
      # And the FsStat is not silently `fekMissing`, which is what a decoder
      # that defaulted would have produced.
      ck "fekHaunted" in outcome.error.detail

  test "bytes that are not base64 are pkTransport, not an empty file":
    withEndpoint:
      nextPayload = %"not base64 !!!"
      let outcome = awaitOutcome(remote.fs.readBytes("/w/a.wasm"))
      ck not outcome.ok
      ck outcome.error.kind == pkTransport

  test "a synchronously answered call settles without a tick":
    ## The `isSyncResolved` branch of `callRemote`, named. Without it the JS
    ## arm chains `then`, which pushes the value onto V8's microtask queue —
    ## and no headless caller can drain that, so on the backend the web
    ## debugger ships on no facade future in this file settles at all.
    ##
    ## MEASURED rather than asserted: deleting the branch reddens 67 of this
    ## file's 68 cases on JS and none of them on native. So this case is not
    ## the only alarm, and it is not meant to be — it is the one that names the
    ## cause, because the other 66 report `awaitOutcome`'s `doAssert settled`
    ## and say nothing about why. That guard is also why the loss is loud
    ## rather than silent, and it is the reason `awaitOutcome` carries it.
    withEndpoint:
      nextPayload = encodeText("sync")
      let future = remote.fs.readText("/w/a.nr")
      when defined(js):
        # The claim itself: nim-everywhere MARKS a synchronously resolved
        # future, and `callRemote` has to propagate the mark rather than chain
        # `then`. Delete the branch and this is false.
        ck isSyncResolved(future)
      else:
        # Native carries no such mark and needs none — `std/asyncdispatch`
        # settles the promise from `addCallback`, which the drain below runs,
        # so the future is legitimately unfinished here. Asserted rather than
        # skipped so the two backends run the same number of checks, and so
        # that a native reader is told where the claim actually lives.
        ck not future.finished
      ck awaitOutcome(future).value == "sync"

  test "the profile is the one the caller supplied, not a compiled-in default":
    ## §6.3 made structural: `newContainerPlatform` has no default profile, so
    ## a platform built from a server that serves less advertises less. The
    ## kiosk set here is one this codebase has never heard of, which is what
    ## makes it a statement about the parameter rather than about the constant.
    withEndpoint:
      let kiosk = PlatformProfile(
        kind: pkContainer, displayName: "kiosk",
        capabilities: {capFilesystemRead},
        overlaysCaptionBar: false, degradations: @[])
      let idle: RemoteTransport = proc(request: RemoteRequest
                                      ): PlatformFuture[RemoteResponse] =
        newCompletedFuture(remoteOk(encodeText("")))
      let narrow = newContainerPlatform(idle, kiosk)
      ck narrow.can(capFilesystemRead)
      ck not narrow.can(capProcessSpawn)
      ck narrow.profile.displayName == "kiosk"
      # And the one a `welcome` frame declared, through the other overload.
      let welcomed = newContainerPlatform(idle,
        WelcomeFrame(contractMin: 1, contractMax: 1, profile: kiosk))
      ck welcomed.profile.displayName == "kiosk"
      ck welcomed.can(capFilesystemRead)

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
