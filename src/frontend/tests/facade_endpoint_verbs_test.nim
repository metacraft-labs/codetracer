## facade_endpoint_verbs_test.nim
##
## THE SERVER HALF OF THE ENDPOINT CONTRACT, DRIVEN AS A SERVER — a §6.2
## `call` frame in, a `reply` frame out, over a real temporary directory, real
## `git` repositories and real child processes.
##
## ## The three claims
##
##   1. **Each verb answers with the shape `container_platform.nim` will
##      decode.** Not "the handler returns something": the frame is encoded and
##      decoded through `endpoint_protocol`, so a payload the client cannot
##      read fails here rather than in a browser.
##   2. **`welcome.profile` is the table.** Every capability advertised has
##      every one of its verbs implemented; every refused verb's capabilities
##      are absent; every absence carries a degradation sentence.
##   3. **The two ends agree.** The last suite builds the real client —
##      `newContainerPlatform` — over a `RemoteTransport` that hands the
##      encoded `call` straight to `dispatch` and returns its `reply`, and
##      drives **every field of all seven facades** through it. This is the
##      cheapest possible proof that client and server agree on verb names,
##      argument field names and payload shapes, and it needs no socket.
##
## ## What this suite is NOT
##
## It is not WD1b's `test_container_platform_advertises_only_what_it_serves`.
## That test runs against **a real `ct host`** over a real connection, and it
## is step 4 of the milestone's sequence. Everything here runs in one node
## process with the dispatcher called directly, so it cannot see a `ct host`
## that fails to install the endpoint, a socket that never delivers a frame, or
## a deployment whose `git` is missing. Those are exactly the failures step 4
## exists for.
##
## ## What is real, and the one stand-in
##
## REAL: the dispatcher and every handler; node's synchronous `fs`; `git`
## itself, over repositories this suite creates, commits into, and pushes to a
## bare repository it also creates; `sh` as a child process; the codec on both
## sides; `newContainerPlatform` as the shipping client builds it.
##
## THE ONE STAND-IN is the transport, which is a function call instead of a
## socket. That is not a mock of the endpoint — the endpoint is the thing under
## test and nothing about it is replaced. It is the seam
## `container_platform.nim` was built with on purpose ("a suite can exercise
## every verb with a fake and no network at all"), and removing the socket is
## what makes a per-verb assertion affordable.
##
## Every path this suite touches is under one `fs.makeTempDir` directory, and
## the settings store is pointed at that directory too — a suite that proved
## `settings.set` works by writing into the developer's real
## `$XDG_CONFIG_HOME` would be proving it the wrong way.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, the defines
## `server_index.js` is built with, run under node.

import std/[json, jsffi, strutils, unittest]

import ../viewmodel/platform/capabilities
import ../viewmodel/platform/outcome
import ../viewmodel/platform/fs
import ../viewmodel/platform/process
import ../viewmodel/platform/vcs
import ../viewmodel/platform/settings
import ../viewmodel/platform/download
import ../viewmodel/platform/shell
import ../viewmodel/platform/platform
import ../viewmodel/platform/browser_facades
import ../viewmodel/host/container_platform
import ../index/facade_endpoint

const ExpectedAssertions = 1002
var counted = 0
var failedChecks = 0

template ck(cond: untyped) =
  ## EVALUATES `cond` EXACTLY ONCE, unlike the `ck` in
  ## `dap_session_routing_test.nim`, which evaluates it twice — once for the
  ## tally and once for `check`. That is harmless there because every condition
  ## in that suite is pure, and it is not harmless here: almost every condition
  ## below IS a call frame, so a double evaluation would apply a patch twice,
  ## add a git remote twice and append to a file twice. It cost an hour the
  ## first time, so the difference is written down rather than rediscovered.
  ##
  ## `checkpoint` keeps the expression's source text in the failure output,
  ## which is what `check cond` would otherwise have given for free.
  inc counted
  block:
    let outcome: bool = cond
    if not outcome:
      inc failedChecks
      checkpoint("failed: " & astToStr(cond))
    check outcome

# ---------------------------------------------------------------------------
# A hermetic workspace, and a hermetic `git`.
# ---------------------------------------------------------------------------

proc nodeRequire(module: cstring): JsObject {.importjs: "require(#)".}
proc setEnv(name, value: cstring) {.importjs: "process.env[#] = #".}

let nodeFs = nodeRequire("fs")
let nodeOs = nodeRequire("os")

# `git` reads the developer's own `~/.gitconfig` and `/etc/gitconfig` unless
# told not to, and this suite commits. A global `commit.gpgsign = true` or a
# `core.hooksPath` would make `vcs.commit` fail here for a reason that has
# nothing to do with the endpoint, on one machine and not another. Pointing
# both at a path that does not exist is git's own documented way to say "no
# configuration but the repository's".
let workspace = $(nodeFs.mkdtempSync(
  cstring($(nodeOs.tmpdir().to(cstring)) & "/ct-facade-endpoint-")).to(cstring))
setEnv(cstring"GIT_CONFIG_GLOBAL", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_SYSTEM", cstring(workspace & "/absent-gitconfig"))
setEnv(cstring"GIT_CONFIG_NOSYSTEM", cstring"1")
setEnv(cstring"CT_FACADE_ENDPOINT_PROBE", cstring"present")

let endpoint = newFacadeEndpoint(
  settingsRoot = workspace & "/settings",
  tempRoot = workspace,
  deployment = %*{"bundle": "/ui/", "session": {"traceId": 7}})

var nextCallId = 0

proc answer(verb: string; args: JsonNode): ReplyFrame =
  ## THROUGH THE WIRE, not around it: the call is encoded to frame text, the
  ## dispatcher is handed the text, and its answer is decoded back. A handler
  ## whose payload the client's decoder rejects fails here.
  inc nextCallId
  let request = encodeCall(CallFrame(id: nextCallId, verb: verb, args: args))
  let reply = decodeReply(endpoint.handleFrame(request))
  doAssert reply.id == nextCallId, "a reply carried another call's id"
  reply

proc payloadOf(verb: string; args: JsonNode): JsonNode =
  let reply = answer(verb, args)
  doAssert reply.ok, verb & " failed: " & reply.errorMessage
  reply.payload

proc runScript(workingDir, script: string): ProcessRunResult =
  ## `sh -c`, through the endpoint's own `process.run`. Setting a repository up
  ## with the verb under test rather than beside it means the setup itself is
  ## evidence.
  decodeProcessRunResult(payloadOf("process.run", %*{"spec": {
    "command": "sh", "args": ["-c", script], "workingDir": workingDir,
    "clearEnv": false, "stdinText": "", "timeoutMs": 0, "env": []}}))

let scratch = workspace & "/scratch"
discard payloadOf("fs.createDir", %*{"path": scratch})

# ---------------------------------------------------------------------------
# 1. The table, and the profile computed from it
# ---------------------------------------------------------------------------

suite "the dispatch table is complete and self-consistent":

  test "every verb is a dotted name, declared once":
    ck facadeVerbs.len == 63
    var seen: seq[string] = @[]
    for entry in facadeVerbs:
      ck entry.verb.contains('.')
      ck entry.verb notin seen
      seen.add entry.verb

  test "a refused verb says WHY, and a served verb does not pretend to":
    var servedCount = 0
    var refusedCount = 0
    for entry in facadeVerbs:
      if entry.handler.isNil:
        inc refusedCount
        ck entry.unservedBecause.len > 0
      else:
        inc servedCount
        ck entry.unservedBecause.len == 0
    ck servedCount == 37
    ck refusedCount == 26

  test "the served capability set is the table's, not a constant":
    # Spelled out rather than recomputed from `facadeVerbs`, deliberately: a
    # test that recomputed the thing under test would agree with any table at
    # all. This is the list a reviewer has to look at when it changes.
    ck servedCapabilities() == {
      capFilesystemRead, capFilesystemWrite, capFilesystemTemp,
      capFilesystemArbitraryPaths,
      capProcessSpawn, capProcessArbitraryPrograms,
      capVcsRead, capVcsWrite, capVcsRemote,
      capSettingsRead, capSettingsWrite}

  test "nothing a refused verb claims survives in the shipping table":
    var owed: CapabilitySet = {}
    for entry in facadeVerbs:
      if entry.handler.isNil: owed = owed + entry.serves
    for capability in owed:
      ck capability notin servedCapabilities()
    ck capFilesystemWatch in owed
    ck capProcessInteractiveStdin in owed
    ck capClipboardWrite in owed

  test "a refused verb withdraws a capability its served siblings still claim":
    # THE POSITIVE CONTROL for the rule above, and it is needed because the
    # test above cannot fail in the interesting direction: in the shipping
    # table no capability is claimed by both a served and a refused verb, so
    # `evidenced - owed` and a bare `evidenced` give the same answer and a
    # suite reading only `servedCapabilities()` would be grading a guard that
    # is inert.
    #
    # So the overlap is constructed. `fs.copy` is refused while the other six
    # `capFilesystemWrite` verbs stay: the capability must go, and
    # `capFilesystemRead` — which `fs.copy` does not claim — must stay.
    var mutated = facadeVerbs
    var found = false
    for i in 0 ..< mutated.len:
      if mutated[i].verb == "fs.copy":
        ck capFilesystemWrite in mutated[i].serves
        mutated[i].handler = nil
        found = true
    ck found
    ck capFilesystemWrite in servedCapabilities()
    ck capFilesystemWrite notin servedCapabilities(mutated)
    ck capFilesystemRead in servedCapabilities(mutated)
    ck capFilesystemWrite notin servedProfile(mutated).capabilities
    ck capFilesystemRead in servedProfile(mutated).capabilities

  test "the profile is containerProfile intersected with the table":
    let profile = servedProfile()
    ck profile.kind == pkContainer
    ck profile.capabilities <= containerProfile.capabilities
    ck profile.capabilities == containerProfile.capabilities * servedCapabilities()
    # The thirteen `containerProfile` claims and this endpoint does not serve.
    for capability in [capFilesystemWatch, capProcessSignal,
                       capProcessGracefulSignal, capProcessInteractiveStdin,
                       capProcessTerminal, capClipboardWrite, capDownloadFile,
                       capOpenFileDialog, capSaveFileDialog,
                       capDirectoryPicker, capOpenExternalUrl,
                       capWindowFullscreen, capShareLink]:
      ck capability in containerProfile.capabilities
      ck capability notin profile.capabilities

  test "every absence carries a degradation, and none is stale":
    # `capabilities.nim` requires both directions, and this profile is BUILT
    # rather than written, so it is the one most able to grow an absence
    # nobody explained.
    let profile = servedProfile()
    ck undeclaredDegradations(profile).len == 0
    ck staleDegradations(profile).len == 0
    for capability in containerProfile.capabilities - profile.capabilities:
      ck degradedBehaviour(profile, capability).len > 0
      ck not degradedBehaviour(profile, capability).contains("no degradation declared")

suite "the welcome frame declares what the table serves":

  test "the frame survives the codec the client will decode it with":
    let welcome = decodeWelcome(encodeWelcome(endpoint.welcomeFrame()))
    ck welcome.contractMin == 1
    ck welcome.contractMax == EndpointContractVersion
    ck welcome.contractMin <= welcome.contractMax
    ck welcome.unknownCapabilities.len == 0
    ck welcome.profile.kind == pkContainer
    ck welcome.profile.capabilities == servedProfile().capabilities
    ck welcome.profile.displayName == "container (ct host endpoint)"

  test "the deployment descriptor is carried and not interpreted":
    let welcome = decodeWelcome(encodeWelcome(endpoint.welcomeFrame()))
    ck welcome.deployment{"bundle"}.getStr == "/ui/"
    ck welcome.deployment{"session"}{"traceId"}.getInt == 7

  test "a hello frame is answered with welcome, whatever version it names":
    # §6.5 puts the refusal in the CLIENT. A server that refused a version it
    # does not serve would leave the page unable to name the two numbers.
    for version in [0, EndpointContractVersion, EndpointContractVersion + 5]:
      let reply = endpoint.handleFrame(encodeHello(HelloFrame(contractVersion: version)))
      ck frameKind(reply) == FrameWelcome
      ck decodeWelcome(reply).contractMax == EndpointContractVersion

  test "the welcome is addressed to the session the hello asked for":
    # ECHOED, never chosen here. A client driving several sessions cannot tell
    # two welcomes apart until after it has acted on one, so the endpoint
    # answers about the conversation it was asked about and names no other.
    let reply = endpoint.handleFrame(encodeHello(HelloFrame(
      contractVersion: EndpointContractVersion, session: "s-7")))
    ck decodeWelcome(reply).session == "s-7"
    # And a hello that names none is answered with none -- the single-session
    # wire, unchanged in both directions.
    let bare = endpoint.handleFrame(encodeHello(HelloFrame(
      contractVersion: EndpointContractVersion)))
    ck decodeWelcome(bare).session == ""

  test "a reply carries the session of the call it answers":
    # THE PAIR IS WHAT CORRELATES, not the id. Ids are allocated per client
    # from 1, so a reply carrying only an id can be claimed by a client waiting
    # on that number in a different session -- which completes the wrong call
    # with a payload that looks right. Echoing the session is this side's whole
    # part in preventing it, and it has to happen on the REFUSAL paths too:
    # a client whose unknown-verb refusal went unaddressed would hang instead.
    let served = endpoint.handleFrame(encodeCall(CallFrame(
      session: "s-7", id: 3, verb: "fs.readText",
      args: %*{"path": "/definitely/absent"})))
    ck decodeReply(served).session == "s-7"
    ck decodeReply(served).id == 3
    let unknown = endpoint.handleFrame(encodeCall(CallFrame(
      session: "s-7", id: 4, verb: "nosuch.verb", args: newJObject())))
    ck decodeReply(unknown).session == "s-7"
    ck not decodeReply(unknown).ok
    let bare = endpoint.handleFrame(encodeCall(CallFrame(
      id: 5, verb: "nosuch.verb", args: newJObject())))
    ck decodeReply(bare).session == ""

  test "a frame this endpoint does not own is left alone, not refused":
    # §6.1: the facade and the existing index IPC surface share ONE connection
    # and are told apart by frame kind. Raising on somebody else's message
    # would take the connection down.
    ck endpoint.handleFrame("""{"kind":"dap-raw-message","seq":3}""") == ""
    ck endpoint.handleFrame("not json at all") == ""
    ck endpoint.handleFrame("""{"kind":"reply","id":1,"ok":true}""") == ""
    ck endpoint.handleFrame("""{"kind":"call","verb":"fs.readText"}""") == ""

# ---------------------------------------------------------------------------
# 2. The filesystem, over a real directory
# ---------------------------------------------------------------------------

suite "the filesystem verbs, against a real temporary directory":

  test "text round-trips, and append appends":
    let path = scratch & "/hello.txt"
    ck answer("fs.writeText", %*{"path": path, "content": "one\n"}).ok
    ck decodeText(payloadOf("fs.readText", %*{"path": path})) == "one\n"
    ck answer("fs.appendText", %*{"path": path, "content": "two\n"}).ok
    ck decodeText(payloadOf("fs.readText", %*{"path": path})) == "one\ntwo\n"

  test "text that would break a concatenating codec survives":
    let path = scratch & "/awkward.txt"
    const awkward = "a \"quoted\" line\nwith \\ backslash and é, 日本語, \t tab"
    ck answer("fs.writeText", %*{"path": path, "content": awkward}).ok
    ck decodeText(payloadOf("fs.readText", %*{"path": path})) == awkward

  test "bytes are bytes, not a UTF-8 string":
    # The whole reason §6.2 makes these verbs base64: a `.wasm` is not valid
    # UTF-8, and a byte that is not a printable character must come back the
    # byte it was.
    let path = scratch & "/bytes.bin"
    var original: seq[byte] = @[]
    for value in 0 .. 255:
      original.add byte(value)
    ck answer("fs.writeBytes",
              %*{"path": path, "content": encodeBytes(original)}).ok
    let returned = decodeBytes(payloadOf("fs.readBytes", %*{"path": path}))
    ck returned.len == 256
    ck returned == original

  test "stat reports kind, size and writability":
    let path = scratch & "/hello.txt"
    let stat = decodeFsStat(payloadOf("fs.stat", %*{"path": path}))
    ck stat.kind == fekFile
    ck stat.size == 8
    ck stat.modifiedMs > 0
    ck not stat.readOnly
    let directory = decodeFsStat(payloadOf("fs.stat", %*{"path": scratch}))
    ck directory.kind == fekDirectory

  test "a missing path is a SUCCESSFUL stat reporting fekMissing":
    # `platform/fs.exists` is `stat` mapped through `kind != fekMissing`, so a
    # `pkNotFound` here would make "does this exist?" an error at every call
    # site that asks it.
    let reply = answer("fs.stat", %*{"path": scratch & "/nothing-here"})
    ck reply.ok
    ck decodeFsStat(reply.payload).kind == fekMissing

  test "listDir names entries and their kinds":
    let nested = scratch & "/tree"
    ck answer("fs.createDir", %*{"path": nested & "/deep"}).ok
    ck answer("fs.writeText", %*{"path": nested & "/leaf.txt", "content": "x"}).ok
    let entries = decodeFsDirEntries(payloadOf("fs.listDir", %*{"path": nested}))
    ck entries.len == 2
    var sawDirectory = false
    var sawFile = false
    for entry in entries:
      if entry.name == "deep" and entry.kind == fekDirectory: sawDirectory = true
      if entry.name == "leaf.txt" and entry.kind == fekFile: sawFile = true
    ck sawDirectory
    ck sawFile

  test "createDir makes parents and is idempotent":
    let deep = scratch & "/a/b/c"
    ck answer("fs.createDir", %*{"path": deep}).ok
    ck answer("fs.createDir", %*{"path": deep}).ok
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": deep})).kind == fekDirectory

  test "copy, move and remove":
    let source = scratch & "/copy-source.txt"
    let copied = scratch & "/copy-target.txt"
    let moved = scratch & "/moved.txt"
    ck answer("fs.writeText", %*{"path": source, "content": "payload"}).ok
    ck answer("fs.copy", %*{"source": source, "destination": copied}).ok
    ck decodeText(payloadOf("fs.readText", %*{"path": copied})) == "payload"
    ck answer("fs.move", %*{"source": copied, "destination": moved}).ok
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": copied})).kind == fekMissing
    ck decodeText(payloadOf("fs.readText", %*{"path": moved})) == "payload"
    ck answer("fs.remove", %*{"path": moved, "recursive": false}).ok
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": moved})).kind == fekMissing

  test "a recursive remove takes the tree; a non-recursive one refuses":
    let tree = scratch & "/removable"
    ck answer("fs.createDir", %*{"path": tree & "/inner"}).ok
    ck answer("fs.writeText", %*{"path": tree & "/inner/f.txt", "content": "x"}).ok
    let refused = answer("fs.remove", %*{"path": tree, "recursive": false})
    ck not refused.ok
    # `ERR_FS_EISDIR`, node's OWN code rather than an errno — the reason
    # `errorKindForNodeCode` has to cover both namespaces. The tree is intact
    # afterwards, which is the part that matters to a caller.
    ck refused.errorKind == pkInvalidArgument
    ck decodeFsStat(payloadOf("fs.stat",
      %*{"path": tree & "/inner/f.txt"})).kind == fekFile
    ck answer("fs.remove", %*{"path": tree, "recursive": true}).ok
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": tree})).kind == fekMissing

  test "realPath resolves a symlink to its target":
    let target = scratch & "/link-target.txt"
    ck answer("fs.writeText", %*{"path": target, "content": "t"}).ok
    discard runScript(scratch, "ln -s link-target.txt link")
    ck decodeText(payloadOf("fs.realPath", %*{"path": scratch & "/link"})) ==
      decodeText(payloadOf("fs.realPath", %*{"path": target}))
    # `stat` is an `lstat`, so a symlink reports as one rather than as its
    # target — the distinction a project tree needs to draw.
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": scratch & "/link"})).kind == fekSymlink

  test "makeTempDir creates a fresh directory under the endpoint's temp root":
    let first = decodeText(payloadOf("fs.makeTempDir", %*{"prefix": "run-"}))
    let second = decodeText(payloadOf("fs.makeTempDir", %*{"prefix": "run-"}))
    ck first != second
    ck first.startsWith(workspace)
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": first})).kind == fekDirectory

# ---------------------------------------------------------------------------
# 3. §6.4 — the error mapping, at the boundary and only there
# ---------------------------------------------------------------------------

suite "node errno becomes PlatformErrorKind once, at the boundary":

  test "the mapping is a function of the code":
    ck errorKindForNodeCode("ENOENT") == pkNotFound
    ck errorKindForNodeCode("ENOTDIR") == pkNotFound
    ck errorKindForNodeCode("EACCES") == pkAccessDenied
    ck errorKindForNodeCode("EPERM") == pkAccessDenied
    ck errorKindForNodeCode("EROFS") == pkAccessDenied
    ck errorKindForNodeCode("EEXIST") == pkAlreadyExists
    ck errorKindForNodeCode("ENOSPC") == pkQuotaExceeded
    ck errorKindForNodeCode("EDQUOT") == pkQuotaExceeded
    ck errorKindForNodeCode("ENOTEMPTY") == pkConflict
    ck errorKindForNodeCode("EBUSY") == pkConflict
    ck errorKindForNodeCode("EISDIR") == pkInvalidArgument
    ck errorKindForNodeCode("EINVAL") == pkInvalidArgument
    ck errorKindForNodeCode("ETIMEDOUT") == pkTimeout
    ck errorKindForNodeCode("ECANCELED") == pkCancelled
    ck errorKindForNodeCode("EIO") == pkFailed
    ck errorKindForNodeCode("") == pkFailed

  test "an OS 'not supported' is NOT pkNotSupported":
    # §6.3 gives `pkNotSupported` exactly one meaning — this deployment does
    # not serve this capability — and a client loops over `welcome.profile` on
    # it. An operating system refusing one operation on one filesystem must
    # not be readable as a capability absence.
    ck errorKindForNodeCode("ENOTSUP") == pkFailed
    ck errorKindForNodeCode("EOPNOTSUPP") == pkFailed

  test "a real ENOENT, ENOTDIR and EISDIR arrive as their kinds":
    let missing = answer("fs.readText", %*{"path": scratch & "/no-such-file"})
    ck not missing.ok
    ck missing.errorKind == pkNotFound
    # THE DIAGNOSTIC IS IN `detail`, AND THE MESSAGE IS NEUTRAL. §6.2 gained
    # the field on 2026-09-30 for exactly this; before it, the errno text was
    # appended to the message because the frame had nowhere else to put it,
    # which made a container failure read differently from the same failure
    # in-process. A bug report with only "read failed" in it is not one, so
    # the text is not dropped either — it moved.
    ck missing.detail.contains("ENOENT")
    ck not missing.errorMessage.contains("ENOENT")
    ck missing.errorMessage.contains("no-such-file")

    let notADirectory = answer("fs.listDir", %*{"path": scratch & "/hello.txt"})
    ck not notADirectory.ok
    ck notADirectory.errorKind == pkNotFound

    let copyingADirectory = answer("fs.copy",
      %*{"source": scratch & "/tree", "destination": scratch & "/tree-copy"})
    ck not copyingADirectory.ok
    ck copyingADirectory.errorKind == pkInvalidArgument

    let intoNowhere = answer("fs.writeText",
      %*{"path": scratch & "/absent-dir/f.txt", "content": "x"})
    ck not intoNowhere.ok
    ck intoNowhere.errorKind == pkNotFound

  test "a malformed argument is pkInvalidArgument, naming the field":
    let noPath = answer("fs.readText", %*{})
    ck not noPath.ok
    ck noPath.errorKind == pkInvalidArgument
    ck noPath.errorMessage.contains("path")

    let wrongType = answer("fs.remove", %*{"path": scratch, "recursive": "yes"})
    ck not wrongType.ok
    ck wrongType.errorKind == pkInvalidArgument

    let unknownEnum = answer("settings.get", %*{"scope": "ssTelepathy", "key": "k"})
    ck not unknownEnum.ok
    ck unknownEnum.errorKind == pkInvalidArgument

  test "the server never produces pkTransport":
    # §6.4: it is what the CLIENT reports when a reply never arrives, and a
    # server that answered cannot have observed that. Asserted over every
    # failure this suite has produced so far as well as over these.
    for probe in [answer("fs.readText", %*{"path": scratch & "/nope"}),
                  answer("fs.listDir", %*{"path": scratch & "/nope"}),
                  answer("vcs.status", %*{"repository": scratch & "/nope"}),
                  answer("settings.get", %*{"scope": "ssUser", "key": "nope"}),
                  answer("shell.closeWindow", %*{})]:
      ck probe.errorKind != pkTransport

# ---------------------------------------------------------------------------
# 4. Processes, with a real child
# ---------------------------------------------------------------------------

suite "process.run spawns a real child":

  test "stdout, stderr and a non-zero exit are all reported":
    let result = runScript(scratch, "printf hello; printf trouble >&2; exit 3")
    ck result.stdout == "hello"
    ck result.stderr == "trouble"
    ck result.exit.exitCode == 3
    ck not result.exit.signalled
    ck not succeededExit(result.exit)

  test "a non-zero exit is a SUCCESSFUL run":
    # The verb's subject is whether the command ran. A caller distinguishes
    # "the compiler said no" from "there is no compiler", and collapsing the
    # two would make a failing build indistinguishable from a broken image.
    let reply = answer("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "exit 9"], "workingDir": scratch,
      "clearEnv": false, "stdinText": "", "timeoutMs": 0, "env": []}})
    ck reply.ok
    ck decodeProcessRunResult(reply.payload).exit.exitCode == 9

  test "stdin, the working directory and the environment are honoured":
    let withStdin = decodeProcessRunResult(payloadOf("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "cat"], "workingDir": scratch,
      "clearEnv": false, "stdinText": "piped in", "timeoutMs": 0, "env": []}}))
    ck withStdin.stdout == "piped in"

    let inScratch = runScript(scratch, "pwd")
    ck inScratch.stdout.strip().endsWith("/scratch")

    let withEnv = decodeProcessRunResult(payloadOf("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "printf %s \"$CT_FACADE_TEST\""],
      "workingDir": scratch, "clearEnv": false, "stdinText": "", "timeoutMs": 0,
      "env": [{"key": "CT_FACADE_TEST", "value": "set-by-the-spec"}]}}))
    ck withEnv.stdout == "set-by-the-spec"

    # `clearEnv` must actually clear: an inherited variable that survived it
    # would be a leak a caller cannot see.
    let cleared = decodeProcessRunResult(payloadOf("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "printf %s \"$CT_FACADE_ENDPOINT_PROBE\""],
      "workingDir": scratch, "clearEnv": true, "stdinText": "", "timeoutMs": 0,
      "env": []}}))
    ck cleared.stdout == ""
    let inherited = decodeProcessRunResult(payloadOf("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "printf %s \"$CT_FACADE_ENDPOINT_PROBE\""],
      "workingDir": scratch, "clearEnv": false, "stdinText": "", "timeoutMs": 0,
      "env": []}}))
    ck inherited.stdout == "present"

  test "a command that is not there is pkNotFound, not a crash":
    let reply = answer("process.run", %*{"spec": {
      "command": "ct-no-such-program", "args": [], "workingDir": scratch,
      "clearEnv": false, "stdinText": "", "timeoutMs": 0, "env": []}})
    ck not reply.ok
    ck reply.errorKind == pkNotFound
    ck reply.errorMessage.contains("ct-no-such-program")

  test "timeoutMs bounds a child that would not stop":
    # The one thing standing between a synchronous dispatcher and a wedged
    # index process, so it is asserted rather than assumed.
    let reply = answer("process.run", %*{"spec": {
      "command": "sh", "args": ["-c", "sleep 30"], "workingDir": scratch,
      "clearEnv": false, "stdinText": "", "timeoutMs": 250, "env": []}})
    ck not reply.ok
    ck reply.errorKind == pkTimeout

  test "which finds a program on PATH and refuses one that is not":
    let git = decodeText(payloadOf("process.which", %*{"program": "git"}))
    ck git.len > 0
    ck git.contains("git")
    ck decodeFsStat(payloadOf("fs.stat", %*{"path": git})).kind != fekMissing

    let absent = answer("process.which", %*{"program": "ct-no-such-program"})
    ck not absent.ok
    ck absent.errorKind == pkNotFound

    # A directory on PATH named like a program must not be reported as one.
    ck not answer("process.which", %*{"program": scratch}).ok

# ---------------------------------------------------------------------------
# 5. Version control — real `git`, real repositories
# ---------------------------------------------------------------------------

let repository = workspace & "/repo"
let bareRemote = workspace & "/origin.git"

suite "vcs is served by running git, and reads back what git wrote":

  test "a repository is created, configured and recognised":
    ck answer("fs.createDir", %*{"path": repository}).ok
    ck answer("vcs.initRepository", %*{"path": repository}).ok
    let configured = runScript(repository,
      "git config user.name 'Facade Suite' && " &
      "git config user.email facade@example.invalid && " &
      "git symbolic-ref HEAD refs/heads/main")
    ck configured.exit.exitCode == 0
    ck decodeFlag(payloadOf("vcs.isRepository", %*{"path": repository}))
    ck not decodeFlag(payloadOf("vcs.isRepository", %*{"path": scratch}))
    ck decodeText(payloadOf("vcs.repositoryRoot", %*{"path": repository})).strip()
      .endsWith("/repo")

  test "an untracked file shows in status, and staging moves it":
    ck answer("fs.writeText",
              %*{"path": repository & "/a.txt", "content": "one\n"}).ok
    let untracked = decodeVcsStatus(
      payloadOf("vcs.status", %*{"repository": repository}))
    ck untracked.branch == "main"
    ck not untracked.detached
    ck untracked.changes.len == 1
    ck untracked.changes[0].path == "a.txt"
    ck untracked.changes[0].workingTreeStatus == vfsUntracked

    ck answer("vcs.stage", %*{"repository": repository, "paths": ["a.txt"]}).ok
    let staged = decodeVcsStatus(payloadOf("vcs.status", %*{"repository": repository}))
    ck staged.changes.len == 1
    ck staged.changes[0].indexStatus == vfsAdded

  test "commit returns the id git recorded, and log reads it back":
    let commit = decodeVcsCommit(payloadOf("vcs.commit", %*{
      "repository": repository, "message": "first commit",
      "authorName": "Facade Suite", "authorEmail": "facade@example.invalid"}))
    ck commit.id.len == 40
    ck commit.subject == "first commit"

    let log = decodeVcsCommits(payloadOf("vcs.log", %*{
      "repository": repository, "maxCount": 10, "path": ""}))
    ck log.len == 1
    ck log[0].id == commit.id
    ck log[0].shortId.len > 0
    ck log[0].subject == "first commit"
    ck log[0].authorName == "Facade Suite"
    ck log[0].authorEmail == "facade@example.invalid"
    ck log[0].authoredAtMs > 0
    ck log[0].parents.len == 0

  test "unstage puts a staged file back":
    # AFTER the first commit, deliberately: `git restore --staged` resolves
    # HEAD, so the same call in a repository with no commit yet fails for a
    # reason that is git's and not this endpoint's.
    ck answer("fs.writeText",
              %*{"path": repository & "/u.txt", "content": "u\n"}).ok
    ck answer("vcs.stage", %*{"repository": repository, "paths": ["u.txt"]}).ok
    let staged = decodeVcsStatus(payloadOf("vcs.status", %*{"repository": repository}))
    ck staged.changes.len == 1
    ck staged.changes[0].indexStatus == vfsAdded
    ck answer("vcs.unstage", %*{"repository": repository, "paths": ["u.txt"]}).ok
    let back = decodeVcsStatus(payloadOf("vcs.status", %*{"repository": repository}))
    ck back.changes.len == 1
    ck back.changes[0].workingTreeStatus == vfsUntracked
    ck answer("fs.remove",
              %*{"path": repository & "/u.txt", "recursive": false}).ok

  test "log's maxCount and path filters are the ones git applies":
    ck answer("fs.writeText",
              %*{"path": repository & "/b.txt", "content": "bee\n"}).ok
    ck answer("vcs.stage", %*{"repository": repository, "paths": ["b.txt"]}).ok
    discard payloadOf("vcs.commit", %*{
      "repository": repository, "message": "second commit",
      "authorName": "Facade Suite", "authorEmail": "facade@example.invalid"})

    let all = decodeVcsCommits(payloadOf("vcs.log",
      %*{"repository": repository, "maxCount": 10, "path": ""}))
    ck all.len == 2
    ck all[0].subject == "second commit"
    ck all[0].parents.len == 1

    let capped = decodeVcsCommits(payloadOf("vcs.log",
      %*{"repository": repository, "maxCount": 1, "path": ""}))
    ck capped.len == 1

    let filtered = decodeVcsCommits(payloadOf("vcs.log",
      %*{"repository": repository, "maxCount": 10, "path": "a.txt"}))
    ck filtered.len == 1
    ck filtered[0].subject == "first commit"

  test "the three blob sources are three different answers":
    ck answer("fs.writeText",
              %*{"path": repository & "/a.txt", "content": "working\n"}).ok
    ck answer("vcs.stage", %*{"repository": repository, "paths": ["a.txt"]}).ok
    ck answer("fs.writeText",
              %*{"path": repository & "/a.txt", "content": "working again\n"}).ok
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt",
      "source": "vbsWorkingTree"})) == "working again\n"
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt", "source": "vbsIndex"})) == "working\n"
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt", "source": "vbsHead"})) == "one\n"
    ck decodeText(payloadOf("vcs.readBlobAt", %*{
      "repository": repository, "path": "a.txt", "revision": "HEAD"})) == "one\n"

  test "diff distinguishes staged from unstaged":
    let unstaged = decodeText(payloadOf("vcs.diff", %*{
      "repository": repository, "paths": [], "staged": false,
      "contextLines": 3}))
    ck unstaged.contains("+working again")
    let staged = decodeText(payloadOf("vcs.diff", %*{
      "repository": repository, "paths": [], "staged": true,
      "contextLines": 3}))
    ck staged.contains("+working")
    ck not staged.contains("+working again")
    let scoped = decodeText(payloadOf("vcs.diff", %*{
      "repository": repository, "paths": ["b.txt"], "staged": false,
      "contextLines": 3}))
    ck scoped.len == 0

  test "a patch applies, and a patch that does not is pkConflict":
    ck answer("vcs.discardChanges",
              %*{"repository": repository, "paths": ["a.txt"]}).ok
    ck answer("vcs.unstage", %*{"repository": repository, "paths": ["a.txt"]}).ok
    ck answer("vcs.discardChanges",
              %*{"repository": repository, "paths": ["a.txt"]}).ok
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt",
      "source": "vbsWorkingTree"})) == "one\n"

    const patch = "diff --git a/a.txt b/a.txt\n" &
      "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+patched\n"
    ck answer("vcs.applyPatch", %*{
      "repository": repository, "patch": patch, "reverse": false}).ok
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt",
      "source": "vbsWorkingTree"})) == "patched\n"
    ck answer("vcs.applyPatch", %*{
      "repository": repository, "patch": patch, "reverse": true}).ok
    ck decodeText(payloadOf("vcs.readBlob", %*{
      "repository": repository, "path": "a.txt",
      "source": "vbsWorkingTree"})) == "one\n"

    let refused = answer("vcs.applyPatch", %*{
      "repository": repository, "patch": "this is not a patch\n",
      "reverse": false})
    ck not refused.ok
    ck refused.errorKind == pkConflict

  test "push and fetch reach a real remote":
    # A bare repository beside this one, so `capVcsRemote` is exercised for
    # real without a network: git's own transport is the same code path over a
    # local path as over a URL, and a suite that skipped this would advertise
    # the capability on nothing.
    ck runScript(workspace, "git init --bare -q origin.git").exit.exitCode == 0
    ck runScript(repository, "git remote add origin " & bareRemote)
      .exit.exitCode == 0
    ck answer("vcs.push", %*{
      "repository": repository, "remote": "origin",
      "refspec": "HEAD:refs/heads/main"}).ok
    ck runScript(bareRemote, "git rev-parse refs/heads/main").exit.exitCode == 0
    ck answer("vcs.fetch",
              %*{"repository": repository, "remote": "origin"}).ok
    let toNowhere = answer("vcs.fetch",
      %*{"repository": repository, "remote": "no-such-remote"})
    ck not toNowhere.ok
    ck toNowhere.errorKind == pkFailed

  test "git failing in a directory that is not a repository is not a crash":
    let reply = answer("vcs.status", %*{"repository": scratch})
    ck not reply.ok
    ck reply.errorKind == pkFailed
    let nowhere = answer("vcs.status", %*{"repository": workspace & "/absent"})
    ck not nowhere.ok
    ck nowhere.errorKind == pkNotFound

# ---------------------------------------------------------------------------
# 5b. vcs.contentId — SB-2a: the content facts W, H and S, and the store roots
# ---------------------------------------------------------------------------

let contentRepo = workspace & "/content-repo"

proc sh(dir, script: string): string =
  ## A script that must succeed; its stdout, trimmed.
  let ran = runScript(dir, script)
  doAssert ran.exit.exitCode == 0, script & " failed: " & ran.stderr
  ran.stdout.strip()

proc contentIdReply(ep: FacadeEndpoint; state, algorithm: string;
                    repo = contentRepo; scope = newJArray()): ReplyFrame =
  inc nextCallId
  decodeReply(ep.handleFrame(encodeCall(CallFrame(
    id: nextCallId, verb: "vcs.contentId",
    args: %*{"repository": repo, "state": state, "algorithm": algorithm,
             "scope": scope}))))

proc repoSnapshot(): string =
  ## Every ref, HEAD, a checksum of the index FILE, and status. Status runs
  ## with GIT_OPTIONAL_LOCKS=0 so the snapshot does not itself refresh the
  ## index it checksums.
  sh(contentRepo,
     "git for-each-ref --format='%(refname) %(objectname)'; cat .git/HEAD; " &
     "cksum < .git/index; " &
     "GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 --untracked-files=all")

suite "vcs.contentId round-trips over the facade endpoint":

  test "W, H and S are git's own trees, and nothing the user sees moved":
    discard sh(workspace,
      "git init -q content-repo && cd content-repo && " &
      "git config user.name 'Facade Suite' && " &
      "git config user.email facade@example.invalid && " &
      "printf 'base\n' > f.txt && printf 'g\n' > g.txt && " &
      "git add -A && git commit -q -m base && " &
      "printf 'staged\n' > f.txt && git add f.txt && " &
      "printf 'staged\nedited\n' > f.txt && printf 'u\n' > untracked.txt")
    let before = repoSnapshot()
    let w = decodeVcsContentId(contentIdReply(endpoint, "vbsWorkingTree",
                                              "git-tree-sha1").payload)
    let s = decodeVcsContentId(contentIdReply(endpoint, "vbsIndex",
                                              "git-tree-sha1").payload)
    let h = decodeVcsContentId(contentIdReply(endpoint, "vbsHead",
                                              "git-tree-sha1").payload)
    ck repoSnapshot() == before
    ck w.kind == vcikComputed and s.kind == vcikComputed and h.kind == vcikComputed
    ck h.id == "git-tree-sha1:" & sh(contentRepo, "git rev-parse 'HEAD^{tree}'")
    ck s.id == "git-tree-sha1:" & sh(contentRepo,
      "cp .git/index ../index-copy && GIT_INDEX_FILE=../index-copy " &
      "git write-tree; rm -f ../index-copy")
    # W is what `git commit -a` would record, measured on a throwaway clone.
    ck w.id == "git-tree-sha1:" & sh(workspace,
      "rm -rf w-clone && git clone -q content-repo w-clone && " &
      "cp content-repo/f.txt w-clone/f.txt && cd w-clone && " &
      "git -c user.name=x -c user.email=x@x.invalid commit -q -a -m w && " &
      "git rev-parse 'HEAD^{tree}' && cd .. && rm -rf w-clone")
    ck w.id != s.id
    ck s.id != h.id
    ck repoSnapshot() == before

  test "a state with no content id arrives as its condition, by name":
    discard sh(contentRepo, "git update-index --assume-unchanged g.txt")
    let reply = contentIdReply(endpoint, "vbsWorkingTree", "git-tree-sha1")
    ck reply.ok
    ck reply.payload["conditions"][0]["condition"].getStr == "ncAssumeUnchanged"
    let decoded = decodeVcsContentId(reply.payload)
    ck decoded.kind == vcikNoContentId
    ck decoded.id == ""
    ck decoded.conditions.len == 1
    ck decoded.conditions[0].condition == ncAssumeUnchanged
    ck decoded.conditions[0].paths == @["g.txt"]
    discard sh(contentRepo, "git update-index --no-assume-unchanged g.txt")

  test "cannot-compute is a value, a failure is an error, a bad scope is invalid":
    let other = decodeVcsContentId(contentIdReply(endpoint, "vbsHead",
                                                  "git-tree-sha256").payload)
    ck other.kind == vcikCannotCompute
    ck other.id == ""
    let unknown = decodeVcsContentId(contentIdReply(endpoint, "vbsHead",
                                                    "no-such-algorithm").payload)
    ck unknown.kind == vcikCannotCompute
    let outside = contentIdReply(endpoint, "vbsWorkingTree", "git-tree-sha1",
                                 repo = scratch)
    ck not outside.ok
    ck outside.errorKind == pkFailed
    ck outside.errorMessage.contains("not inside a git working tree")
    let badScope = contentIdReply(endpoint, "vbsHead", "git-tree-sha1",
                                  scope = %"src")
    ck not badScope.ok
    ck badScope.errorKind == pkInvalidArgument
    let scoped = decodeVcsContentId(contentIdReply(endpoint, "vbsHead",
      "git-tree-sha1", scope = %*["g.txt"]).payload)
    ck scoped.kind == vcikComputed
    ck scoped.id != decodeVcsContentId(contentIdReply(endpoint, "vbsHead",
      "git-tree-sha1").payload).id

  test "a caller holding capVcsRead gets an id; one without it is refused, by name":
    # Two endpoints over the SAME repository, differing only in what they
    # were granted. The one with capVcsRead alone — no write, no remote —
    # computes; the one with every other served capability is refused, and
    # the refusal names the capability it lacks.
    let readOnly = newFacadeEndpoint(settingsRoot = workspace & "/settings",
                                     tempRoot = workspace,
                                     granted = {capVcsRead})
    let granted = contentIdReply(readOnly, "vbsHead", "git-tree-sha1")
    ck granted.ok
    ck decodeVcsContentId(granted.payload).kind == vcikComputed

    let withoutRead = newFacadeEndpoint(settingsRoot = workspace & "/settings",
                                        tempRoot = workspace,
                                        granted = servedCapabilities() - {capVcsRead})
    let refused = contentIdReply(withoutRead, "vbsHead", "git-tree-sha1")
    ck not refused.ok
    ck refused.errorKind == pkNotSupported
    ck refused.errorMessage.contains("capVcsRead")
    ck refused.errorMessage.contains("vcs.contentId")
    # It does not advertise what it refuses, and still explains the absence.
    let narrowed = withoutRead.welcomeFrame()
    ck capVcsRead notin narrowed.profile.capabilities
    ck undeclaredDegradations(narrowed.profile).len == 0

    # A client built from that welcome refuses WITHOUT a round trip, naming
    # the capability too.
    var sent = 0
    let counting: RemoteTransport = proc(request: RemoteRequest
                                        ): PlatformFuture[RemoteResponse] =
      inc sent
      newCompletedFuture(remoteErr(pkFailed, "must not be reached"))
    let narrowClient = newContainerPlatform(counting, narrowed)
    let local = awaitSync(narrowClient.vcs.contentId(contentRepo, vbsHead,
                                                     "git-tree-sha1", @[]))
    ck not local.ok
    ck local.error.kind == pkNotSupported
    ck local.error.message.contains("capVcsRead")
    ck sent == 0

    # The narrowing is per capability, not per endpoint: what it WAS granted
    # it still serves.
    inc nextCallId
    let stat = decodeReply(withoutRead.handleFrame(encodeCall(CallFrame(
      id: nextCallId, verb: "fs.stat", args: %*{"path": contentRepo}))))
    ck stat.ok

  test "fs.certificateStoreRoots is the container process's own, per Transport §2.1":
    setEnv(cstring"TEST_CERTIFICATES_DIR", cstring(workspace & "/store"))
    let roots = decodeCertificateStoreRoots(payloadOf("fs.certificateStoreRoots",
                                                      newJObject()))
    ck roots.available
    ck roots.user == workspace & "/store"
    ck roots.system.len > 0
    setEnv(cstring"TEST_CERTIFICATES_DIR", cstring"relative/store")
    let ignored = decodeCertificateStoreRoots(payloadOf("fs.certificateStoreRoots",
                                                        newJObject()))
    ck ignored.user != "relative/store"
    var said = false
    for problem in ignored.problems:
      if problem.contains("TEST_CERTIFICATES_DIR") and problem.contains("ignored"):
        said = true
    ck said
    setEnv(cstring"TEST_CERTIFICATES_DIR", cstring(workspace & "/store"))

# ---------------------------------------------------------------------------
# 6. Settings
# ---------------------------------------------------------------------------

suite "settings keep three scopes apart, under the endpoint's own root":

  test "a value round-trips and the scopes do not see each other":
    ck answer("settings.set",
              %*{"scope": "ssUser", "key": "theme", "value": "dark"}).ok
    ck answer("settings.set",
              %*{"scope": "ssWorkspace", "key": "theme", "value": "light"}).ok
    ck decodeText(payloadOf("settings.get",
      %*{"scope": "ssUser", "key": "theme"})) == "dark"
    ck decodeText(payloadOf("settings.get",
      %*{"scope": "ssWorkspace", "key": "theme"})) == "light"
    let unset = answer("settings.get", %*{"scope": "ssSession", "key": "theme"})
    ck not unset.ok
    ck unset.errorKind == pkNotFound

  test "keys lists a scope and honours a prefix":
    ck answer("settings.set",
              %*{"scope": "ssUser", "key": "editor.font", "value": "Mono"}).ok
    ck answer("settings.set",
              %*{"scope": "ssUser", "key": "editor.size", "value": "13"}).ok
    let all = decodeTextSeq(payloadOf("settings.keys",
      %*{"scope": "ssUser", "prefix": ""}))
    ck all.len == 3
    let scoped = decodeTextSeq(payloadOf("settings.keys",
      %*{"scope": "ssUser", "prefix": "editor."}))
    ck scoped.len == 2
    ck "editor.font" in scoped
    ck "editor.size" in scoped
    # An unwritten scope lists nothing rather than failing.
    ck decodeTextSeq(payloadOf("settings.keys",
      %*{"scope": "ssSession", "prefix": ""})).len == 0

  test "delete is idempotent":
    ck answer("settings.delete", %*{"scope": "ssUser", "key": "theme"}).ok
    ck answer("settings.delete", %*{"scope": "ssUser", "key": "theme"}).ok
    ck not answer("settings.get", %*{"scope": "ssUser", "key": "theme"}).ok

  test "a key is a NAME, and cannot walk out of its scope":
    # The key arrives over a socket §6.6 says authenticates nothing, so this
    # is a containment property rather than a tidiness one.
    ck answer("settings.set", %*{
      "scope": "ssUser", "key": "../../escaped", "value": "no"}).ok
    # Nothing was written outside the scope directory: not two levels up, and
    # not one.
    ck decodeFsStat(payloadOf("fs.stat",
      %*{"path": workspace & "/escaped.txt"})).kind == fekMissing
    ck decodeFsStat(payloadOf("fs.stat",
      %*{"path": workspace & "/settings/escaped.txt"})).kind == fekMissing
    # The separator is what cannot survive into a key; a dot can, and does —
    # `editor.font` above is a real key.
    let keys = decodeTextSeq(payloadOf("settings.keys",
      %*{"scope": "ssUser", "prefix": ""}))
    var escaped = false
    for key in keys:
      if key.contains("/") or key.contains("\\"): escaped = true
    ck not escaped

  test "environment reads the process's own, and refuses what is unset":
    ck decodeText(payloadOf("settings.environment",
      %*{"name": "CT_FACADE_ENDPOINT_PROBE"})) == "present"
    let unset = answer("settings.environment",
      %*{"name": "CT_DEFINITELY_NOT_SET_ANYWHERE"})
    ck not unset.ok
    ck unset.errorKind == pkNotFound

# ---------------------------------------------------------------------------
# 7. Every refused verb refuses BY NAME
# ---------------------------------------------------------------------------

suite "a verb this endpoint does not serve refuses with pkNotSupported":

  test "every refused verb in the table, driven":
    # The failure mode this whole milestone exists to remove is a verb the
    # client can call and the server silently drops. So each one is CALLED,
    # not read out of the table.
    for entry in facadeVerbs:
      if not entry.handler.isNil: continue
      let reply = answer(entry.verb, newJObject())
      ck not reply.ok
      ck reply.errorKind == pkNotSupported
      ck reply.errorMessage.contains(entry.verb)

  test "an unknown verb is refused DIFFERENTLY from a declared one":
    # The two are different faults — a client speaking a vocabulary this build
    # does not have, against this build choosing not to serve a verb it knows.
    # A suite that could not tell them apart could not notice a verb missing
    # from the table, which is the whole point of the sweep below.
    let unknown = answer("fs.teleport", %*{})
    ck not unknown.ok
    ck unknown.errorKind == pkNotSupported
    ck unknown.errorMessage.contains("declares no verb named")
    let declared = answer("fs.watch", %*{"path": scratch, "recursive": false})
    ck declared.errorKind == pkNotSupported
    ck not declared.errorMessage.contains("declares no verb named")
    ck declared.errorMessage.contains("event")

# ---------------------------------------------------------------------------
# 8. The round trip: the REAL client, over the REAL dispatcher
# ---------------------------------------------------------------------------

var transportCalls = 0

let transport: RemoteTransport = proc(request: RemoteRequest
                                     ): PlatformFuture[RemoteResponse] =
  ## The one stand-in: a function call where the socket will be. Everything
  ## else is real — the request is ENCODED to a `call` frame, the dispatcher is
  ## handed the text, and its `reply` text is decoded back, so both directions
  ## of the codec are exercised on every verb.
  inc transportCalls
  inc nextCallId
  let text = encodeCall(CallFrame(
    id: nextCallId, verb: request.verb, args: request.args))
  let reply = decodeReply(endpoint.handleFrame(text))
  newCompletedFuture(
    if reply.ok: remoteOk(reply.payload)
    else: remoteErr(reply.errorKind, reply.errorMessage))

let client = newContainerPlatform(transport, endpoint.welcomeFrame())

type SweepEntry = tuple[label: string; ok: bool; kind: PlatformErrorKind;
                        message: string]
var sweep: seq[SweepEntry] = @[]

template record(verbName: string; call: untyped): untyped =
  let settled = awaitSync(call)
  sweep.add((verbName, settled.ok, settled.error.kind, settled.error.message))
  settled

let clientDir = workspace & "/client"

suite "the client and the server agree, verb by verb":

  test "the profile the client was built from is the server's":
    ck client.profile.kind == pkContainer
    ck client.profile.capabilities == servedProfile().capabilities
    ck client.can(capFilesystemRead)
    ck client.can(capVcsWrite)
    ck not client.can(capFilesystemWatch)
    ck not client.can(capClipboardWrite)

  test "every filesystem operation, through the real client":
    discard record("fs.createDir", client.fs.createDir(clientDir))
    ck record("fs.writeText",
              client.fs.writeText(clientDir & "/c.txt", "client\n")).ok
    let read = record("fs.readText", client.fs.readText(clientDir & "/c.txt"))
    ck read.ok
    ck read.value == "client\n"
    ck record("fs.appendText",
              client.fs.appendText(clientDir & "/c.txt", "more\n")).ok
    ck record("fs.readText", client.fs.readText(clientDir & "/c.txt")).value ==
      "client\nmore\n"

    let bytes = @[byte 0, 1, 127, 128, 255]
    ck record("fs.writeBytes",
              client.fs.writeBytes(clientDir & "/c.bin", bytes)).ok
    let readBack = record("fs.readBytes", client.fs.readBytes(clientDir & "/c.bin"))
    ck readBack.ok
    ck readBack.value == bytes

    let stat = record("fs.stat", client.fs.stat(clientDir & "/c.txt"))
    ck stat.ok
    ck stat.value.kind == fekFile
    ck stat.value.size == 12

    let listed = record("fs.listDir", client.fs.listDir(clientDir))
    ck listed.ok
    ck listed.value.len == 2

    ck record("fs.copy", client.fs.copy(clientDir & "/c.txt",
                                        clientDir & "/d.txt")).ok
    ck record("fs.move", client.fs.move(clientDir & "/d.txt",
                                        clientDir & "/e.txt")).ok
    ck record("fs.remove", client.fs.remove(clientDir & "/e.txt", false)).ok
    ck record("fs.realPath", client.fs.realPath(clientDir)).value.len > 0
    ck record("fs.makeTempDir", client.fs.makeTempDir("client-")).ok
    let roots = record("fs.certificateStoreRoots", client.fs.certificateStoreRoots())
    ck roots.ok
    ck roots.value.available
    ck roots.value.user == workspace & "/store"

    # `exists` is `stat` read through the facade's own helper, which is where
    # a `pkNotFound` for a missing path would have shown up as a false error.
    let present = record("fs.exists", client.fs.exists(clientDir & "/c.txt"))
    ck present.ok
    ck present.value
    let absent = record("fs.exists", client.fs.exists(clientDir & "/gone.txt"))
    ck absent.ok
    ck not absent.value

  test "every process operation the endpoint serves":
    let ran = record("process.run", client.process.run(ProcessSpec(
      command: "sh", args: @["-c", "printf via-client"],
      workingDir: clientDir, env: @[], clearEnv: false, stdinText: "",
      timeoutMs: 0)))
    ck ran.ok
    ck ran.value.stdout == "via-client"
    ck succeededExit(ran.value.exit)
    let located = record("process.which", client.process.which("git"))
    ck located.ok
    ck located.value.len > 0

  test "every vcs operation, through the real client":
    ck record("vcs.isRepository", client.vcs.isRepository(repository)).value
    ck record("vcs.repositoryRoot",
              client.vcs.repositoryRoot(repository)).ok
    let status = record("vcs.status", client.vcs.status(repository))
    ck status.ok
    ck status.value.branch == "main"
    let log = record("vcs.log", client.vcs.log(repository, 5, ""))
    ck log.ok
    ck log.value.len == 2
    ck record("vcs.readBlob",
              client.vcs.readBlob(repository, "a.txt", vbsHead)).value == "one\n"
    ck record("vcs.readBlobAt",
              client.vcs.readBlobAt(repository, "a.txt", "HEAD")).value == "one\n"
    ck record("vcs.diff", client.vcs.diff(repository, @[], false, 3)).ok
    let head = record("vcs.contentId", client.vcs.contentId(
      repository, vbsHead, "git-tree-sha1", @[]))
    ck head.ok
    ck head.value.kind == vcikComputed
    ck head.value.id == "git-tree-sha1:" & runScript(repository,
      "git rev-parse 'HEAD^{tree}'").stdout.strip()

    ck record("fs.writeText",
              client.fs.writeText(repository & "/c.txt", "third\n")).ok
    ck record("vcs.stage", client.vcs.stage(repository, @["c.txt"])).ok
    ck record("vcs.unstage", client.vcs.unstage(repository, @["c.txt"])).ok
    ck record("vcs.stage", client.vcs.stage(repository, @["c.txt"])).ok
    let commit = record("vcs.commit", client.vcs.commit(
      repository, "third commit", "Facade Suite", "facade@example.invalid"))
    ck commit.ok
    ck commit.value.id.len == 40
    ck record("vcs.discardChanges",
              client.vcs.discardChanges(repository, @["a.txt"])).ok
    ck record("vcs.applyPatch", client.vcs.applyPatch(
      repository,
      "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n" &
      "@@ -1 +1 @@\n-one\n+two\n", false)).ok
    ck record("vcs.applyPatch", client.vcs.applyPatch(
      repository,
      "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n" &
      "@@ -1 +1 @@\n-one\n+two\n", true)).ok
    ck record("vcs.initRepository",
              client.vcs.initRepository(repository)).ok
    ck record("vcs.push",
              client.vcs.push(repository, "origin", "HEAD:refs/heads/main")).ok
    ck record("vcs.fetch", client.vcs.fetch(repository, "origin")).ok

  test "every settings operation, through the real client":
    ck record("settings.set",
              client.settings.set(ssSession, "run", "42")).ok
    ck record("settings.get",
              client.settings.get(ssSession, "run")).value == "42"
    let keys = record("settings.keys", client.settings.keys(ssSession, ""))
    ck keys.ok
    ck keys.value == @["run"]
    ck record("settings.delete",
              client.settings.delete(ssSession, "run")).ok
    ck record("settings.environment",
              client.settings.environment("CT_FACADE_ENDPOINT_PROBE")).value ==
      "present"

  test "every operation the endpoint refuses, through the real client":
    # Driven from the CLIENT so that the refusal is what a caller of the facade
    # would actually get: `pkNotSupported`, not a transport error and not a
    # silently empty value.
    discard record("fs.watch", client.fs.watch(clientDir, false,
                                               proc(e: FsWatchEvent) = discard))
    discard record("fs.unwatch", client.fs.unwatch(FsWatchHandle("h")))
    discard record("process.start", client.process.start(
      processSpec("sh", @["-c", "true"]),
      proc(c: ProcessOutputChunk) = discard, proc(e: ProcessExit) = discard))
    discard record("process.signal",
                   client.process.signal(ProcessHandle("h"), sigTerminate))
    discard record("process.writeStdin",
                   client.process.writeStdin(ProcessHandle("h"), "x"))
    discard record("process.closeStdin",
                   client.process.closeStdin(ProcessHandle("h")))
    discard record("process.isRunning",
                   client.process.isRunning(ProcessHandle("h")))
    discard record("settings.getSecret", client.settings.getSecret("a", "k"))
    discard record("settings.setSecret",
                   client.settings.setSecret("a", "k", "v"))
    discard record("settings.deleteSecret",
                   client.settings.deleteSecret("a", "k"))
    discard record("clipboard.writeText", client.clipboard.writeText("x"))
    discard record("clipboard.readText", client.clipboard.readText())
    discard record("clipboard.writeHtml", client.clipboard.writeHtml("<p/>", "p"))
    discard record("download.offerFile",
                   client.download.offerFile("f.txt", @[byte 1], "text/plain"))
    discard record("download.offerText",
                   client.download.offerText("f.txt", "x", "text/plain"))
    discard record("download.openFileDialog",
                   client.download.openFileDialog(OpenDialogOptions()))
    discard record("download.saveFileDialog",
                   client.download.saveFileDialog(SaveDialogOptions()))
    discard record("download.pickDirectory",
                   client.download.pickDirectory(OpenDialogOptions()))
    discard record("shell.openExternalUrl",
                   client.shell.openExternalUrl("https://example.invalid"))
    discard record("shell.revealInFileManager",
                   client.shell.revealInFileManager(clientDir))
    discard record("shell.windowState", client.shell.windowState())
    discard record("shell.minimizeWindow", client.shell.minimizeWindow())
    discard record("shell.toggleMaximizeWindow",
                   client.shell.toggleMaximizeWindow())
    discard record("shell.closeWindow", client.shell.closeWindow())
    discard record("shell.setFullscreen", client.shell.setFullscreen(true))
    discard record("shell.openSessionWindow",
                   client.shell.openSessionWindow("s"))

    var refusals = 0
    for entry in sweep:
      if not entry.ok and entry.kind == pkNotSupported:
        inc refusals
    ck refusals == 26

  test "EVERY verb in the table was driven from the client, and no other":
    # This is the assertion that makes the sweep above worth its length, and it
    # runs in both directions.
    #
    # A verb missing from `facadeVerbs` refuses with a DIFFERENT message from
    # one that is declared and unserved, so a client operation the table forgot
    # shows up as "declares no verb named" — caught by driving the whole
    # client, rather than by a list of verb names in this file that could be
    # forgotten in exactly the same way. And a verb in the table that no client
    # operation reaches is caught by the coverage loop: it would be a verb this
    # endpoint answers that nothing can ask for.
    var driven: seq[string] = @[]
    for entry in sweep:
      ck not entry.message.contains("declares no verb named")
      if entry.label notin driven: driven.add entry.label
    for entry in facadeVerbs:
      ck entry.verb in driven
    # One extra label: `fs.exists`, which is not a verb at all — it is
    # `platform/fs.nim`'s helper over `fs.stat`, driven because it is the call
    # site a `pkNotFound` for a missing path would have broken.
    ck driven.len == facadeVerbs.len + 1
    ck "fs.exists" in driven

  test "no answer in the sweep is pkTransport, and none is silently empty":
    for entry in sweep:
      ck entry.kind != pkTransport
      if not entry.ok:
        ck entry.message.len > 0

  test "every operation the profile advertises SUCCEEDED in this sweep":
    # The in-process half of WD1b's agreement claim. It is not the milestone's
    # test — that one runs against a real `ct host` — but it holds the same
    # shape here for nothing: a verb wired to a handler that is broken shows up
    # as a failure in a sweep whose capability is advertised.
    var failures: seq[string] = @[]
    for entry in sweep:
      let index = findVerb(entry.label)
      if index < 0: continue
      if facadeVerbs[index].handler.isNil: continue
      if not entry.ok:
        failures.add entry.label & ": " & entry.message
    if failures.len > 0:
      echo "SERVED VERBS THAT FAILED: ", failures
    ck failures.len == 0
    # Every recorded outcome went over the transport; nothing was answered by
    # the client without a frame.
    ck transportCalls == sweep.len

# ---------------------------------------------------------------------------
# 9. §6.6 — the sixteen the TAB answers, against the profile this server serves
# ---------------------------------------------------------------------------
#
# Suite 8 above builds the client with the bridge-less constructor, which is
# what `ct host` shipped at `7739d096f`: every field over the wire, including
# the clipboard and the window. The server is right to refuse those and right
# to withdraw their capabilities — and the RESULT is a browser tab whose
# platform has no clipboard. §6.6 is the client-side half of the fix, and this
# is the one place both halves exist in the same process, so it is where the
# union can be asserted against the profile the server really computes rather
# than against a stand-in for it.

var tabbedTransportCalls = 0
var tabbedOps: seq[string] = @[]
var tabbedUrls: seq[string] = @[]

let tabbedTransport: RemoteTransport = proc(request: RemoteRequest
                                           ): PlatformFuture[RemoteResponse] =
  inc tabbedTransportCalls
  inc nextCallId
  let text = encodeCall(CallFrame(
    id: nextCallId, verb: request.verb, args: request.args))
  let reply = decodeReply(endpoint.handleFrame(text))
  newCompletedFuture(
    if reply.ok: remoteOk(reply.payload)
    else: remoteErr(reply.errorKind, reply.errorMessage))

# A tab that answers everything, so that a refusal below is the FACADE's and
# not this fixture's.
let tabbedBridge = BrowserTabBridge(
  writeClipboardText: proc(text: string): auto =
    tabbedOps.add "clipboard.writeText"
    resolvedOk(),
  writeClipboardHtml: proc(html, plainText: string): auto =
    tabbedOps.add "clipboard.writeHtml"
    resolvedOk(),
  offerDownload: proc(suggestedName: string; content: seq[byte];
                      mimeType: string): auto =
    tabbedOps.add "download.offer"
    resolvedOk(),
  pickFiles: proc(options: OpenDialogOptions): auto =
    tabbedOps.add "download.openFileDialog"
    resolvedOk(@["imported.nr"]),
  pickDirectory: proc(options: OpenDialogOptions): auto =
    tabbedOps.add "download.pickDirectory"
    resolvedOk("imported"),
  suggestSaveName: proc(options: SaveDialogOptions): auto =
    tabbedOps.add "download.saveFileDialog"
    resolvedOk(options.suggestedName),
  openExternalUrl: proc(url: string): auto =
    tabbedOps.add "shell.openExternalUrl"
    tabbedUrls.add url
    resolvedOk(),
  setFullscreen: proc(fullscreen: bool): auto =
    tabbedOps.add "shell.setFullscreen"
    resolvedOk(),
  windowState: proc(): auto =
    tabbedOps.add "shell.windowState"
    resolvedOk(WindowState(maximized: false, minimized: false,
                           fullscreen: false, focused: true)),
  onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard)

let tabbed = newContainerPlatform(tabbedTransport, tabbedBridge,
                                  endpoint.welcomeFrame())

suite "§6.6 — the deployment is a tab AND a container":

  test "the platform's profile is the union, not the served set":
    ck tabbed.profile.capabilities ==
      servedProfile().capabilities + browserTabCapabilities()
    ck servedProfile().capabilities < tabbed.profile.capabilities
    # The seven the server withdraws and the tab restores, named: a set
    # comparison passes when both sides are wrong in the same way.
    for capability in [capClipboardWrite, capDownloadFile, capOpenFileDialog,
                       capSaveFileDialog, capDirectoryPicker,
                       capOpenExternalUrl, capWindowFullscreen]:
      ck capability notin servedProfile().capabilities
      ck tabbed.can(capability)
    # And the SAME endpoint, through the bridge-less constructor, still has
    # none of them. This is the defect §6.6 was opened on, side by side with
    # its fix, in one process.
    ck not client.can(capClipboardWrite)
    ck not client.can(capOpenExternalUrl)
    # Neither side supplies these, so the union must not claim them either.
    for capability in [capClipboardRead, capRevealInFileManager,
                       capWindowControls, capMultiWindow, capSecretStore,
                       capShareLink, capFilesystemWatch]:
      ck not tabbed.can(capability)
    # The server's half is untouched by the composition.
    ck tabbed.can(capFilesystemRead)
    ck tabbed.can(capVcsRemote)

  test "the composed profile still explains every absence and no presence":
    ck undeclaredDegradations(tabbed.profile).len == 0
    ck staleDegradations(tabbed.profile).len == 0
    ck degradedBehaviour(tabbed.profile, capClipboardWrite) == ""
    ck degradedBehaviour(tabbed.profile, capClipboardRead).len > 20
    for capability in tabbed.profile.missing:
      ck degradedBehaviour(tabbed.profile, capability).len > 20
      ck not degradedBehaviour(tabbed.profile, capability).contains(
        "no degradation declared")

  test "none of the sixteen reaches the dispatcher":
    ## Asserted on the CALL COUNT rather than on the outcomes: a tab verb that
    ## was sent and refused satisfies "the outcome was not ok" and is exactly
    ## what this is about.
    let before = tabbedTransportCalls
    discard awaitSync(tabbed.clipboard.writeText("copied"))
    discard awaitSync(tabbed.clipboard.readText())
    discard awaitSync(tabbed.clipboard.writeHtml("<b>b</b>", "b"))
    discard awaitSync(tabbed.download.offerFile("a.tar", @[byte 1], "application/x-tar"))
    discard awaitSync(tabbed.download.offerText("a.txt", "t", "text/plain"))
    discard awaitSync(tabbed.download.openFileDialog(OpenDialogOptions()))
    discard awaitSync(tabbed.download.saveFileDialog(
      SaveDialogOptions(suggestedName: "a.txt")))
    discard awaitSync(tabbed.download.pickDirectory(OpenDialogOptions()))
    discard awaitSync(tabbed.shell.openExternalUrl("https://example.test/"))
    discard awaitSync(tabbed.shell.revealInFileManager("/w/a.nr"))
    discard awaitSync(tabbed.shell.windowState())
    discard awaitSync(tabbed.shell.minimizeWindow())
    discard awaitSync(tabbed.shell.toggleMaximizeWindow())
    discard awaitSync(tabbed.shell.closeWindow())
    discard awaitSync(tabbed.shell.setFullscreen(true))
    discard awaitSync(tabbed.shell.openSessionWindow("s1"))
    ck tabbedTransportCalls == before
    # And the tab WAS reached, so the count above is not zero for want of
    # anything happening.
    ck tabbedOps.len == 10

  test "the wire-owned verbs still reach it":
    let before = tabbedTransportCalls
    let dir = workspace & "/tabbed"
    ck awaitSync(tabbed.fs.createDir(dir)).ok
    ck awaitSync(tabbed.fs.writeText(dir & "/a.txt", "tab\n")).ok
    ck awaitSync(tabbed.fs.readText(dir & "/a.txt")).value == "tab\n"
    ck tabbedTransportCalls == before + 3

  test "the external-URL allow-list guards the container's bridge too":
    ## The guard lives in `platform/browser_facades.buildBrowserShell`, which
    ## is the same builder the web instantiation uses. A container deployment
    ## wires a THIRD bridge, and the one before it —
    ## `test_platform_web.nim`'s fake — accepted `javascript:` through a check
    ## that existed only in `host/web_browser.nim`.
    let before = tabbedUrls.len
    for hostile in ["javascript:alert(1)", "data:text/html,<script>x()</script>",
                    "file:///etc/passwd"]:
      let outcome = awaitSync(tabbed.shell.openExternalUrl(hostile))
      ck not outcome.ok
      ck outcome.error.kind == pkInvalidArgument
    ck tabbedUrls.len == before
    ck awaitSync(tabbed.shell.openExternalUrl("https://ok.test/")).ok
    ck tabbedUrls.len == before + 1

# ---------------------------------------------------------------------------
# Teardown and the tally
# ---------------------------------------------------------------------------

suite "the tally":
  test "assertion count":
    discard endpoint.dispatch(CallFrame(
      id: 0, verb: "fs.remove",
      args: %*{"path": workspace, "recursive": true}))
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
    if failedChecks > 0:
      {.emit: "process.exitCode = 1;".}
