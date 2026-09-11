## test_plugin_io_sdk.nim — PLAT-8's real-stack integration suite.
##
## ## THE FOUR THINGS THE MILESTONE ASKS THIS FILE TO PROVE
##
##   1. "A plugin drives a real external process over pipes, and a real local
##      socket, with framing, against a real tool."
##   2. "Arguments are a list: a plugin cannot reach a shell, **asserted by
##      attempting it**."
##   3. "A plugin without `socket:remote` cannot reach a non-loopback address,
##      **asserted by attempting it**."
##   4. "Deactivation closes every handle: **no surviving child, no leaked
##      socket**, asserted after a plugin is torn down mid-operation."
##
## ## NO MOCKS, AND NOTHING HERE STANDS IN FOR ANYTHING
##
## The child processes are `cat`, `env`, `pwd`, `printf` and `sleep` from
## coreutils, spawned through `std/osproc` onto the kernel's pipes. The socket
## peer is a real `python3` process speaking the same length-prefixed framing
## from the other side of a real `AF_UNIX` socket — a second implementation of
## the codec, in a different language, which is what makes the framing
## assertion a claim about the wire rather than about one function agreeing
## with itself. The reactive host is PLAT-7's real `PluginHost` over `isonim`'s
## real graph.
##
## Two names in this file could be mistaken for stand-ins and neither is:
##
##   * `backend/mock_backend.MockBackendService` — one of the four
##     `BackendService` implementations the ViewModel layer ships, exported
##     from the SDK facade as part of §3.1's `BackendService` row. It is here
##     only because a `ReplayDataStore` needs a transport and PLAT-7's host
##     suites use the same one. Nothing in this file asserts anything about it.
##   * the python peer is not a mock of a tool — it IS the tool. A plugin
##     integrating a daemon talks to somebody else's process, and that is
##     exactly the shape driven here.
##
## ## WHY THE REFUSALS ARE MEASURED AND NOT JUST READ
##
## Every escape defect in this campaign shared one shape: the report was
## unchanged while the state moved. So a refusal is asserted three ways
## wherever all three are available:
##
##   * the outcome says `ioRefused`, and its message names the capability;
##   * the plugin's handle accounting did not move, so nothing was opened and
##     then closed;
##   * and for the teardown case, the OPERATING SYSTEM agrees — `/proc/<pid>`
##     is gone and the process's socket file descriptors are back to what they
##     were.
##
## A test that asserted only the first would pass on a host that refused
## politely and spawned anyway.
##
## ## THE PROBES CAN ANSWER BOTH WAYS, AND THAT IS ASSERTED
##
## Verification-Harness-Traps §4: a scanner that finds nothing passes every
## "must not contain". `processIsAlive` and `openSocketCount` are read BEFORE
## the teardown as well as after, and the before-reading is asserted to be the
## other answer. A `/proc` probe that always said "gone" would otherwise make
## the teardown case unfalsifiable.
##
## And they do not match themselves: liveness is `[ -d /proc/<pid> ]` plus
## `kill(pid, 0)`, never a `pgrep -f` over a pattern that also matches the
## shell running the test.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`. There is exactly one
## (`ck`). `waitUntil` is a template too, because it takes a condition.
##
## ## PLATFORM
##
## The teardown case's OS measurement is `/proc`, so it is Linux. The suite
## says so out loud and FAILS rather than skipping if `/proc` is absent, per
## the silent-self-pass audit: a prerequisite that is missing must be loud.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_io_sdk.nim

import std/[asyncdispatch, os, osproc, posix, strutils, times, unittest]

import codetracer_embed
import plugin_host/host
# PLAT-8's primitives are NOT on the SDK facade — see `codetracer_plugin.nim`
# for why an embedder must not acquire process spawning by linking the SDK.
# This suite imports them the way the plugin surface does, directly.
import plugin_host/plugin_io
import plugin_fixtures/io_tool_plugin

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  CoreVersion = semver(1, 4, 0)
  PeerDeadlineMs = 20_000
    ## EVERY AWAIT ON A PLUGIN THAT TALKS TO A PEER IS BOUNDED, and that is a
    ## fix rather than defensive decoration.
    ##
    ## `runPipeline` closes the child's stdin to give it EOF and then reads
    ## until EOF. If a defect stops the close from reaching the descriptor, the
    ## child never finishes, nothing is ever readable, and the suite waits in
    ## `epoll_wait` forever — reporting the defect it was written to detect as
    ## its absence. Measured: mutation arm P24 (a `close` that does not run its
    ## closer) hung here until the harness's own timeout and scored
    ## `SURVIVED — no case noticed`.
    ##
    ## Twenty seconds is far outside any honest run of these exchanges — the
    ## whole suite takes under two — so this is a deadlock detector rather than
    ## a timing assertion, and Verification-Harness-Traps §12's coin-flip
    ## warning does not apply to a gap of that size.
  Unroutable = "203.0.113.9"
    ## RFC 5737 TEST-NET-3. A literal so nothing has to resolve, and one no
    ## machine is supposed to be able to reach, so a refusal here cannot be
    ## confused with a connection that happened to fail.

# ---------------------------------------------------------------------------
# What the OS says. None of these asserts; they answer, and `ck` decides.
# ---------------------------------------------------------------------------

proc processIsAlive(pid: int): bool =
  ## Alive AND not a zombie. A killed-but-unreaped child still answers
  ## `kill(pid, 0)` with success, so a teardown that killed without waiting
  ## would pass a liveness probe that asked only that — and a zombie is a
  ## process the OS still lists, which is precisely what "no surviving child"
  ## must exclude.
  if pid <= 0: return false
  if not dirExists("/proc/" & $pid): return false
  let statPath = "/proc/" & $pid & "/stat"
  if not fileExists(statPath): return false
  var state = ""
  try:
    let text = readFile(statPath)
    let close = text.rfind(')')
    if close >= 0 and close + 2 < text.len:
      state = $text[close + 2]
  except CatchableError:
    return false
  state != "Z" and state.len > 0

proc processState(pid: int): string =
  ## The single state letter out of `/proc/<pid>/stat`, or `""` when the
  ## process is gone entirely. `processIsAlive` folds "gone" and "zombie"
  ## together, which is right for its question and wrong for F5's.
  ##
  ## A GRANDCHILD CANNOT BE REAPED BY THIS PROCESS, and that is the whole
  ## reason this exists. `rawKill` reaps the child it spawned — `peekExitCode`
  ## is a `waitpid` and the child is ours. A grandchild is our child's child:
  ## once `killpg` kills both, the grandchild is reparented to `init` or to the
  ## session's subreaper, and IT does the reaping, on its own schedule. So
  ## "gone from /proc" is not an assertion this suite may make about a
  ## grandchild without racing the reaper; "dead rather than running" is, and
  ## it is the claim the finding is about.
  if pid <= 0: return ""
  let statPath = "/proc/" & $pid & "/stat"
  if not fileExists(statPath): return ""
  try:
    let text = readFile(statPath)
    let close = text.rfind(')')
    if close >= 0 and close + 2 < text.len:
      return $text[close + 2]
  except CatchableError:
    return ""
  ""

proc openSocketCount(): int =
  ## Every socket file descriptor this process holds, counted through
  ## `/proc/self/fd`. Sockets rather than all fds, because the nim dispatcher
  ## opens and closes epoll and eventfd descriptors on its own schedule and a
  ## raw fd count would be noise.
  for _, path in walkDir("/proc/self/fd"):
    try:
      let target = expandSymlink(path)
      if target.startsWith("socket:"): inc result
    except CatchableError:
      discard

template waitUntil(cond: untyped; timeoutMs: int): bool =
  ## Bounded polling for a condition the OS reaches on its own schedule.
  ## Returns whether it became true; the caller asserts, so a timeout is a
  ## red case rather than a hang.
  var deadline = epochTime() + float(timeoutMs) / 1000.0
  var reached = false
  while epochTime() < deadline:
    if cond:
      reached = true
      break
    sleep(5)
  if not reached and cond: reached = true
  reached

# ---------------------------------------------------------------------------
# Manifests. Every one of them is parsed by the real `parseManifest`, so a
# capability this suite grants is one a real manifest could grant.
# ---------------------------------------------------------------------------

proc hostWithBudget(impls: openArray[PluginImplementation];
                    budgetMs: int): PluginHost =
  result = newPluginHost(CoreVersion, initDuration(milliseconds = budgetMs))
  for impl in impls:
    let m = impl.manifest
    let capsJson = block:
      var parts: seq[string] = @[]
      for c in m.capabilities: parts.add "\"" & $c & "\""
      parts.join(", ")
    var body = "\"capabilities\": [" & capsJson & "]"
    if m.grants.executables.len > 0:
      var e: seq[string] = @[]
      for x in m.grants.executables: e.add "\"" & x & "\""
      body.add ", \"executables\": [" & e.join(", ") & "]"
    if m.grants.hosts.len > 0:
      var h: seq[string] = @[]
      for x in m.grants.hosts:
        h.add "\"" & x.host & (if x.port == AnyPort: "" else: ":" & $x.port) & "\""
      body.add ", \"hosts\": [" & h.join(", ") & "]"
    if m.grants.readPaths.len > 0 or m.grants.writePaths.len > 0:
      var parts: seq[string] = @[]
      if m.grants.readPaths.len > 0:
        var r: seq[string] = @[]
        for x in m.grants.readPaths: r.add "\"" & x & "\""
        parts.add "\"read\": [" & r.join(", ") & "]"
      if m.grants.writePaths.len > 0:
        var w: seq[string] = @[]
        for x in m.grants.writePaths: w.add "\"" & x & "\""
        parts.add "\"write\": [" & w.join(", ") & "]"
      body.add ", \"paths\": {" & parts.join(", ") & "}"
    if m.grants.traceEgress.acknowledged:
      body.add ", \"traceEgress\": {\"acknowledged\": true, \"statement\": \"" &
        m.grants.traceEgress.statement & "\"}"
    let text = "{\"id\": \"" & m.id & "\", \"version\": \"1.0.0\", " &
      "\"activation\": [{\"event\": \"trace-opened\"}], " & body & "}"
    let activate = impl.activate
    let parsed = result.register(text, m.id & ".json", activate)
    if not parsed.isOk:
      raise newException(ValueError, "the suite's own manifest for '" &
        m.id & "' does not parse: " & renderAll(parsed.errors))
  result.resolveAll()
  result.activateFor(occurrence(aeTraceOpened))

proc hostWith(impls: varargs[PluginImplementation]): PluginHost =
  hostWithBudget(@impls, 250)

const
  SuiteAck = "this suite's plugins spawn real tools and open real sockets, " &
             "which is the composition the grant exists to disclose"

func grantsFor(caps: set[Capability]; execs: seq[string] = @[];
               hosts: seq[DeclaredHost] = @[]; reads: seq[string] = @[];
               writes: seq[string] = @[];
               ack = true): GrantSet =
  ## THE ACKNOWLEDGEMENT IS ADDED AUTOMATICALLY FOR ANY COMPOSITION THAT NEEDS
  ## IT, and that is a decision about this helper rather than about the policy.
  ##
  ## Since 2026-09-09 `process` needs the trace-egress grant on its own
  ## (`needsTraceEgressGrant` asks the EFFECTIVE set, and `process` subsumes
  ## every capability). Fifteen manifests in this file grant `process` in
  ## order to drive `cat`, `env`, `pwd`, `printf` and `sleep`, and none of them
  ## is about the egress gate — threading an acknowledgement through each by
  ## hand would put fifteen copies of one fact in the file and make the next
  ## widening a fifteen-line edit.
  ##
  ## **The load-time refusal is not thereby untested.** It is asserted where it
  ## belongs, twice and deliberately without this helper: in
  ## `plugin_capabilities_test` over the real `parseManifest`, and in this
  ## file's own `F1` suite, which builds the verification pass's arm-C manifest
  ## with `ack = false` and asserts `register` REFUSES it. Passing `ack = false`
  ## is how a case opts into the refusal.
  var egress = TraceEgressGrant()
  if ack and needsTraceEgressGrant(caps):
    egress = TraceEgressGrant(acknowledged: true, statement: SuiteAck)
  GrantSet(capabilities: caps, executables: execs, hosts: hosts,
           readPaths: reads, writePaths: writes, traceEgress: egress)

func manifestFor(id: string; g: GrantSet): PluginManifest =
  PluginManifest(id: id, version: semver(1, 0, 0), capabilities: g.capabilities,
                 grants: g)

# ---------------------------------------------------------------------------
# The python peer. A REAL second implementation of the framing, in a language
# that is not this one.
# ---------------------------------------------------------------------------

const PeerSource = """
import socket, struct, sys, os

path = sys.argv[1]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
open(path + ".ready", "w").write("1")
conn, _ = srv.accept()
while True:
    hdr = b""
    while len(hdr) < 4:
        c = conn.recv(4 - len(hdr))
        if not c:
            break
        hdr += c
    if len(hdr) < 4:
        break
    n = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < n:
        c = conn.recv(n - len(body))
        if not c:
            break
        body += c
    reply = body.upper()
    conn.sendall(struct.pack(">I", len(reply)) + reply)
conn.close()
srv.close()
"""

var workDir = ""

proc setupWorkDir(): string =
  if workDir.len == 0:
    workDir = getTempDir() / "plat8-io-" & $getCurrentProcessId()
    createDir(workDir)
  workDir

proc reapPeer(p: Process) =
  ## The suite's own tidy-up. The suite is not a plugin, so it may block on a
  ## child; the SDK may not, which is what `awaitExit` is for.
  try:
    p.kill()
    discard p.waitForExit()
    p.close()
  except CatchableError:
    discard

proc requireTool(name: string): string =
  ## LOUD, never a skip. The silent-self-pass audit's rule: a test that
  ## detects a missing prerequisite and returns early is counted as passed.
  let p = findExe(name)
  if p.len == 0:
    raise newException(OSError,
      "PLAT-8's real-stack suite needs '" & name & "' on PATH and it is not " &
      "there. This suite drives real tools; skipping it would report a green " &
      "run for a sandbox nobody exercised.")
  p

# ---------------------------------------------------------------------------

suite "PLAT-8: there is no synchronous form of any I/O call":

  test "every entry point's result is a Future":
    # §8.1.3: "A read that could block is a read that returns a future."
    # Asserted in the TYPE SYSTEM: a proc that returned its value directly
    # would not compile this block, so the rule cannot decay into a
    # convention. `static:` rather than `check`, because a compile-time
    # property asserted at run time is asserted one build too late.
    static:
      doAssert typeof(spawnProcess(PluginContext(), "cat")) is Future[SpawnOutcome]
      doAssert typeof(connectTcp(PluginContext(), "127.0.0.1", 1)) is
        Future[SocketOutcome]
      doAssert typeof(connectUnixSocket(PluginContext(), "/x")) is
        Future[SocketOutcome]
      doAssert typeof(listenTcp(PluginContext(), "127.0.0.1", 0)) is
        Future[ListenOutcome]
      doAssert typeof(listenUnixSocket(PluginContext(), "/x")) is
        Future[ListenOutcome]
      doAssert typeof(acceptFrom(PluginListener())) is Future[SocketOutcome]
      doAssert typeof(read(PluginStream())) is Future[ReadOutcome]
      doAssert typeof(write(PluginStream(), "")) is Future[WriteOutcome]
      doAssert typeof(readFrame(PluginStream(), frDelimited)) is
        Future[FrameOutcome]
      doAssert typeof(writeFrame(PluginStream(), "", frDelimited)) is
        Future[WriteOutcome]
      doAssert typeof(awaitExit(PluginProcess())) is Future[ExitOutcome]
      doAssert typeof(signalProcess(PluginProcess(), psTerminate)) is
        Future[ExitOutcome]
      doAssert typeof(readPath(PluginContext(), PluginIoContext(), "/x")) is
        Future[ReadOutcome]
      doAssert typeof(writePath(PluginContext(), PluginIoContext(), "/x", "")) is
        Future[WriteOutcome]
    ck true

  test "the blocking drains are not in a plugin's scope":
    # The other half, and it is a NARROWING rather than a removal: `await` and
    # `sleepAsync` are in scope through the same re-export that filters these
    # out. The sanctioned path is asserted through the same `compiles` as the
    # denied one, so the control runs through the mechanism the rule uses.
    # Asserted from inside a PLUGIN's import list rather than from here: this
    # file imports `std/asyncdispatch` directly, so `waitFor` is in ITS scope
    # and a `compiles` here would be a claim about the suite. The two
    # constants below are evaluated in `io_tool_plugin.nim`, whose imports are
    # a plugin's, and the sanctioned half runs through the same `compiles` as
    # the denied half.
    ck SyncDrainsAreOutOfScope
    ck SanctionedAsyncIsInScope
    ck PluginDeniedSyncIo.len == 41
    var seen = 0
    var hostOnlyCount = 0
    for (primitive, replacement, hostOnly) in PluginDeniedSyncIo:
      ck primitive.len > 0
      ck replacement.len > 0
      if hostOnly: inc hostOnlyCount
      inc seen
    ck seen == PluginDeniedSyncIo.len
    # Exactly TWO entries are the host's to call, and the second one arrived
    # with the 2026-09-09 `system` sweep:
    #
    #   `startProcess` — the SDK creates the child whose pipes it then wraps;
    #   `open`         — `posix.open` inside `openVerified`, the mediated open
    #                    taken AFTER `decide`, on a path `canonicalPath` has
    #                    resolved.
    #
    # A count that drifted upward would be the SDK quietly exempting itself
    # from the rule the gate holds it to, so it is pinned rather than bounded.
    # `open` covers ONE line rather than six only because `handles.open` was
    # renamed to `registerHandle`: the exemption is as narrow as it is because
    # the collision was removed rather than accommodated.
    ck hostOnlyCount == 2

  test "F6: the fourth way to block, and WHICH HALF refuses each name":
    # A verification pass found five more routines that block or reach a shell
    # and that compile in a plugin's scope, none of them among the thirteen.
    # They are on the list now — and the useful part of this case is not that
    # they are on it, it is the COLUMN each one is in.
    #
    # THE LANGUAGE REFUSES: `waitFor`, `runForever`, `poll`, `drain`. Four
    # names, filtered out of `codetracer_plugin`'s re-export of
    # `std/asyncdispatch`, so the spelling a plugin author writes does not
    # compile. That is `SyncDrainsAreOutOfScope`, asserted above.
    #
    # THE SOURCE GATE ALONE REFUSES: everything else on `PluginDeniedSyncIo`.
    # `readFile`, `writeFile`, `readAll`, `readLine`, `readLines`, `readChar`,
    # `staticExec`, `gorge` and `gorgeEx` are in `system` — auto-imported,
    # exported by nothing, filterable by no `except` clause. Measured in
    # `io_tool_plugin.nim`, whose import list is a plugin's: every one of them
    # compiles there today.
    #
    # `sleep` IS A THIRD COLUMN and the measurement corrected the finding.
    # It is `std/os`'s, and it is NOT on the plugin facade — neither `sleep`
    # nor `os.sleep` compiles in a plugin's scope, asserted below. It is on
    # the denied list because a plugin may write `import std/os` itself and
    # nothing refuses that import, at which point it blocks the front-end.
    # The control for that claim is one line down, from THIS module, which
    # does import `std/os` and is therefore the scope such a plugin would have.
    #
    # This case ASSERTS both halves rather than describing them, because a
    # comment claiming "the compiler cannot stop these" is worth less than a
    # constant that goes red the day it can.
    ck SystemBlockersAreStillInScope
    ck OsSleepIsNotOnTheFacade
    ck compiles(os.sleep(0))
    # And every one of the five is on the list, by name, so the gate's scan
    # covers what the language cannot. `PluginDeniedSyncIo` is what
    # `ci/test/plugin-reactive-boundary.sh` parses; there is no second list.
    var present: seq[string] = @[]
    for (primitive, _, _) in PluginDeniedSyncIo: present.add primitive
    for name in ["sleep", "readLine", "readLines", "readChar", "staticExec",
                 "gorge", "gorgeEx"]:
      ck name in present
    # THE `system` FAMILY, ADDED 2026-09-09, AND THE LIST IS THE POINT.
    #
    # The residual used to be written down as ten names and this assertion used
    # to enumerate seven, while `system` actually re-exports the WHOLE of
    # `std/syncio` — so `open` was named in the prose and denied nowhere, and
    # `readBuffer` / `readBytes` / `readChars` / `writeBuffer` were named
    # nowhere at all. Together they are a complete unmediated file I/O API;
    # `plugin_probes/sysio_raw_plugin.nim.probe` is that program, and it
    # printed `SYSIO-READ[gpu-server-001]` and `SYSIO-WRITE-OK` from a module
    # whose entire import list is `import codetracer_plugin`.
    #
    # `reopen` and `lines` are on this list because the SWEEP found them and
    # nobody's enumeration had. `reopen(stdin, path, fmRead)` needs no `open`
    # at all, so denying only the name that WAS written down would have left
    # the hole where it was.
    for name in ["open", "reopen", "lines", "readBuffer", "readBytes",
                 "readChars", "writeBuffer", "writeBytes", "writeChars",
                 "writeLine", "getFileSize", "getFilePos", "setFilePos",
                 "endOfFile", "flushFile", "getFileHandle", "getOsFileHandle",
                 "setInheritable", "setStdIoUnbuffered", "slurp", "staticRead"]:
      ck name in present
    # THE CONTROL, over the same sequence: the async vocabulary a plugin MUST
    # use is not on it. A list that had grown to cover the whole language
    # would satisfy every assertion above.
    for name in ["read", "write", "close", "send", "sleepAsync", "await"]:
      ck name notin present

  test "the `system` surface is PARTITIONED by the two tables, not trimmed":
    ## THE COMPANION TABLE, AND WHY IT IS A TABLE.
    ##
    ## Before 2026-09-09 a `system` name that was not denied was simply absent
    ## from `PluginDeniedSyncIo`, and an absence is indistinguishable from an
    ## oversight — which is precisely what `open`, `readBuffer` and
    ## `writeBuffer` were. `PluginSystemSurfaceExempt` makes the exemption a
    ## ROW WITH A REASON, and `ci/test/plugin-reactive-boundary.sh`'s check 23
    ## requires the two tables to cover every name the compiler's own
    ## `std/syncio` and `system/compilation.nim` export.
    ##
    ## The SET is derived by `ci/lib/system-io-surface.sh` from the compiler in
    ## use — that is the half this suite cannot assert, because it is a
    ## property of the toolchain rather than of this tree. What IS asserted
    ## here is the half that lives in the tree: the two tables are well formed,
    ## every row carries a reason, and NOTHING IS ON BOTH. An overlap would let
    ## a name read as covered by whichever table a reader looked at first.
    ck PluginSystemSurfaceExempt.len == 27
    var exempt: seq[string] = @[]
    for (primitive, reason) in PluginSystemSurfaceExempt:
      ck primitive.len > 0
      # THE REASON IS THE DELIVERABLE. A blank right-hand column would be an
      # exemption with no argument, which is the absence this table replaced.
      ck reason.len > 20
      exempt.add primitive
    var denied: seq[string] = @[]
    for (primitive, _, _) in PluginDeniedSyncIo: denied.add primitive
    for name in exempt:
      ck name notin denied
    # The two rows the exemption actually rests on, named so a reader cannot
    # take the table for a list of inert things: these are the SDK's own
    # spellings, and they are exempt because denying them would deny the
    # sanctioned path.
    for name in ["write", "close"]:
      ck name in exempt
    # And the three File VALUES they can still reach — which is what the
    # residual now says, instead of claiming a closed surface.
    for name in ["stdin", "stdout", "stderr"]:
      ck name in exempt
    # The control: a name that IS denied must not be findable here.
    for name in ["open", "reopen", "readBuffer", "writeBuffer"]:
      ck name notin exempt

suite "PLAT-8: a plugin drives a real external process over pipes":

  test "delimiter framing round-trips through a real 'cat'":
    discard requireTool("cat")
    let g = grantsFor({capProcess}, execs = @["cat"])
    let p = newIoPipelinePlugin("cat", @["alpha", "beta", "gamma"])
    let h = hostWith(p.implementation(manifestFor("acme.pipeline", g)))
    ck h.isActive("acme.pipeline")
    ck p.activated == 1
    ck waitFor withTimeout(p.runPipeline(), PeerDeadlineMs)
    ck p.spawnStatus == ioOk
    ck p.received == @["alpha", "beta", "gamma"]
    ck p.exit.status == ioOk
    ck p.exit.code == 0
    ck not p.exit.signalled
    # Every handle the exchange opened was closed by the plugin itself.
    ck h.liveHandleCount("acme.pipeline") == 0

  test "the environment is what the plugin declared, not what the host holds":
    let envTool = requireTool("env")
    discard envTool
    putEnv("CT_PLAT8_HOST_ONLY", "host-secret")
    let g = grantsFor({capProcess}, execs = @["env"])
    let p = newIoPipelinePlugin("env", @[])
    p.env = @[("CT_PLAT8_PLUGIN", "plugin-value")]
    let h = hostWith(p.implementation(manifestFor("acme.env", g)))
    ck waitFor withTimeout(p.runPipeline(), PeerDeadlineMs)
    ck p.spawnStatus == ioOk
    let joined = p.received.join("\n")
    ck "CT_PLAT8_PLUGIN=plugin-value" in joined
    # The host's own environment does NOT reach the child. `startProcess`
    # inherits it when `env` is nil, and the host's environment is where a
    # token would be.
    ck "CT_PLAT8_HOST_ONLY" notin joined
    delEnv("CT_PLAT8_HOST_ONLY")
    ck h.liveHandleCount("acme.env") == 0

  test "the working directory reaches the child":
    discard requireTool("pwd")
    let dir = setupWorkDir()
    let g = grantsFor({capProcess}, execs = @["pwd"])
    let p = newIoPipelinePlugin("pwd", @[])
    p.workingDir = dir
    discard hostWith(p.implementation(manifestFor("acme.cwd", g)))
    ck waitFor withTimeout(p.runPipeline(), PeerDeadlineMs)
    ck p.spawnStatus == ioOk
    ck p.received.len == 1
    ck p.received[0] == expandFilename(dir)

  test "a partial read is normal and the framing helper hides it":
    # `cat` hands back whatever the pipe gives it, in whatever pieces the
    # kernel chose. The plugin above never sees a partial read because
    # `readFrame` owns the buffer — this case asserts the helper's own
    # behaviour directly, on a buffer that arrives in pieces.
    var buf = ""
    var frame = ""
    buf.add "he"
    ck takeFrame(buf, frDelimited, frame) == tsIncomplete
    buf.add "llo\nwor"
    ck takeFrame(buf, frDelimited, frame) == tsFrame
    ck frame == "hello"
    ck takeFrame(buf, frDelimited, frame) == tsIncomplete
    buf.add "ld\n"
    ck takeFrame(buf, frDelimited, frame) == tsFrame
    ck frame == "world"
    ck buf.len == 0

  test "a length-prefixed frame survives being cut anywhere":
    let wire = encodeFrame("payload", frLengthPrefixed)
    ck wire.len == 11
    for cut in 0 .. wire.len:
      var buf = wire[0 ..< cut]
      var frame = ""
      let status = takeFrame(buf, frLengthPrefixed, frame)
      if cut < wire.len:
        ck status == tsIncomplete
      else:
        ck status == tsFrame
        ck frame == "payload"

  test "an overlong announced frame is refused rather than allocated":
    var buf = "\xff\xff\xff\xff" & "x"
    var frame = ""
    ck takeFrame(buf, frLengthPrefixed, frame) == tsOverlong
    # ... and a delimited payload containing its own delimiter is refused at
    # encode time rather than escaped.
    ck encodeFrame("a\nb", frDelimited) == ""
    ck encodeFrame("a b", frDelimited) == "a b\n"

suite "PLAT-8: arguments are a list — a plugin cannot reach a shell":

  test "naming a shell is refused, and the attempt is what asserts it":
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.probe", g)))
    for shellName in ["sh", "bash", "zsh", "cmd"]:
      let outcome = waitFor probe.attemptSpawn(shellName, @["-c", "echo hi"])
      ck outcome.status == ioRefused
      ck outcome.process.isNil
      ck "process" in outcome.message
      ck shellName in outcome.message
    # Nothing was opened and then closed: the refusal happened before any
    # resource existed.
    ck h.liveHandleCount("acme.probe") == 0
    # The control, through the same call: a DECLARED program spawns.
    let ok = waitFor probe.attemptSpawn("cat")
    ck ok.status == ioOk
    ck not ok.process.isNil
    ck h.liveHandleCount("acme.probe") == 4   # process + three streams
    closeProcess(ok.process)
    ck h.liveHandleCount("acme.probe") == 0

  test "a path is refused even when the basename is declared":
    # §8.1.1: "A plugin does not hand over an absolute path of its choosing."
    let g = grantsFor({capProcess}, execs = @["sh"])
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.pathy", g)))
    for spelling in ["/bin/sh", "../../bin/sh", "./sh", "bin/sh"]:
      let outcome = waitFor probe.attemptSpawn(spelling, @["-c", "echo hi"])
      ck outcome.status == ioRefused
      ck "named, not pathed" in outcome.message

  test "shell metacharacters in an argument are one literal argument":
    # THE ASSERTION IS THE EFFECT, not the message. The sentinel file is the
    # thing a shell would have created; `printf` echoes the metacharacters
    # back as data because there was never a command line for them to be part
    # of.
    let dir = setupWorkDir()
    discard requireTool("printf")
    let sentinel = dir / "pwned-by-a-shell"
    removeFile(sentinel)
    let injected = "hello; touch " & sentinel & " #"
    let g = grantsFor({capProcess}, execs = @["printf"])
    let p = newIoPipelinePlugin("printf", @[])
    p.args = @["%s\n", injected]
    discard hostWith(p.implementation(manifestFor("acme.inject", g)))
    ck waitFor withTimeout(p.runPipeline(), PeerDeadlineMs)
    ck p.spawnStatus == ioOk
    ck p.received.len == 1
    ck p.received[0] == injected
    ck not fileExists(sentinel)
    # The probe can answer the other way: the same path, created by this test,
    # IS seen. Without this the last assertion would pass on a broken
    # `fileExists`.
    writeFile(sentinel, "x")
    ck fileExists(sentinel)
    removeFile(sentinel)

suite "PLAT-8: a plugin without socket:remote cannot reach a non-loopback address":

  test "the attempt is refused, and no socket was opened to make it":
    let g = grantsFor({capSocketLocal})
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.local", g)))
    let before = openSocketCount()
    let outcome = waitFor probe.attemptConnect(Unroutable, 80)
    ck outcome.status == ioRefused
    ck outcome.stream.isNil
    ck "socket:remote" in outcome.message
    ck h.liveHandleCount("acme.local") == 0
    # THE EFFECT, measured against the process: no descriptor was created.
    ck openSocketCount() == before

  test "TLS is not a way around the same declaration":
    let g = grantsFor({capSocketLocal})
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.tls", g)))
    let outcome = waitFor probe.attemptTlsConnect(Unroutable, 443)
    ck outcome.status == ioRefused
    ck "socket:remote" in outcome.message

  test "socket:remote without the host declared is still refused":
    let g = grantsFor({capSocketRemote},
                      hosts = @[DeclaredHost(host: "symbols.example.com",
                                             port: 443)])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.remote", g)))
    let before = openSocketCount()
    let outcome = waitFor probe.attemptConnect(Unroutable, 80)
    ck outcome.status == ioRefused
    ck "declared host set" in outcome.message
    ck openSocketCount() == before
    ck h.liveHandleCount("acme.remote") == 0

  test "the same plugin reaches loopback, so the refusal is about the address":
    # THE POSITIVE CONTROL, and it goes all the way to the kernel: the plugin
    # refused above listens on loopback and connects to itself, through real
    # sockets, and exchanges a length-prefixed frame.
    let g = grantsFor({capSocketLocal})
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.loop", g)))
    let listened = waitFor probe.attemptListen("127.0.0.1", 0)
    ck listened.status == ioOk
    let port = listened.listener.boundPort
    ck port > 0
    let accepting = acceptFrom(listened.listener)
    let connected = waitFor probe.attemptConnect("127.0.0.1", port)
    ck connected.status == ioOk
    let server = waitFor accepting
    ck server.status == ioOk
    ck (waitFor connected.stream.writeFrame("ping", frLengthPrefixed)).status == ioOk
    let got = waitFor server.stream.readFrame(frLengthPrefixed)
    ck got.status == ioOk
    ck got.frame == "ping"
    ck h.liveHandleCount("acme.loop") == 3   # listener + two ends
    closeStream(connected.stream)
    closeStream(server.stream)
    closeListener(listened.listener)
    ck h.liveHandleCount("acme.loop") == 0

  test "'localhost' is refused as a name, with the remedy in the message":
    let g = grantsFor({capSocketLocal})
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.name", g)))
    let outcome = waitFor probe.attemptConnect("localhost", 9)
    ck outcome.status == ioRefused
    ck "127.0.0.1" in outcome.message

suite "PLAT-8: a real local socket, with framing, against a real tool":

  test "a python peer echoes length-prefixed frames back uppercased":
    let python = requireTool("python3")
    let dir = setupWorkDir()
    let sockPath = dir / "peer-" & $epochTime().int & ".sock"
    let script = dir / "peer.py"
    writeFile(script, PeerSource)
    removeFile(sockPath)
    removeFile(sockPath & ".ready")
    # The suite is not a plugin, so it may spawn synchronously. The PLUGIN's
    # side of this exchange goes through the SDK and nothing else.
    let peer = startProcess(python, args = @[script, sockPath], options = {})
    try:
      ck waitUntil(fileExists(sockPath & ".ready"), 10000)

      let g = grantsFor({capSocketLocal})
      let p = newIoSocketPlugin(sockPath, "hello framing")
      let h = hostWith(p.implementation(manifestFor("acme.socket", g)))
      ck waitFor withTimeout(p.runSocketExchange(), PeerDeadlineMs)
      ck p.connectStatus == ioOk
      ck p.frameStatus == ioOk
      ck p.reply == "HELLO FRAMING"
      ck h.liveHandleCount("acme.socket") == 0
    finally:
      reapPeer(peer)
      removeFile(sockPath)

  test "a Unix socket without socket:local is refused":
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.nosock", g)))
    let before = openSocketCount()
    let outcome = waitFor probe.attemptUnixConnect("/run/anything.sock")
    ck outcome.status == ioRefused
    ck "socket:local" in outcome.message
    ck openSocketCount() == before
    ck h.liveHandleCount("acme.nosock") == 0

suite "PLAT-8: deactivation closes every handle, measured against the OS":

  test "no surviving child and no leaked socket, after a mid-operation teardown":
    if not dirExists("/proc"):
      raise newException(OSError,
        "this case measures the teardown against /proc and there is none. " &
        "Skipping would report a green run for the assertion the milestone " &
        "cares most about.")
    let python = requireTool("python3")
    discard requireTool("sleep")
    let dir = setupWorkDir()
    let sockPath = dir / "teardown-" & $epochTime().int & ".sock"
    let script = dir / "peer.py"
    writeFile(script, PeerSource)
    removeFile(sockPath)
    removeFile(sockPath & ".ready")
    let peer = startProcess(python, args = @[script, sockPath], options = {})
    ck waitUntil(fileExists(sockPath & ".ready"), 10000)

    let socketsAtStart = openSocketCount()

    # The plugin under test holds a long-running child AND a socket, and does
    # not close either.
    let procGrants = grantsFor({capProcess, capSocketLocal},
                               execs = @["sleep"])
    let child = newIoPipelinePlugin("sleep", @[])
    child.args = @["300"]
    child.keepOpen = true
    let sock = newIoSocketPlugin(sockPath, "held")
    sock.keepOpen = true

    # The CONTROL is a second plugin, holding its own long-running child,
    # deactivated by nobody. "Everything died" and "this plugin's things died"
    # are different facts.
    let survivor = newIoPipelinePlugin("sleep", @[])
    survivor.args = @["300"]
    survivor.keepOpen = true

    let h = hostWith(
      child.implementation(manifestFor("acme.torn", procGrants)),
      sock.implementation(manifestFor("acme.torn.sock",
                                      grantsFor({capSocketLocal}))),
      survivor.implementation(manifestFor("acme.survivor", procGrants)))

    waitFor child.startLongRunning()
    waitFor survivor.startLongRunning()
    waitFor sock.connectAndHold()
    ck child.spawnStatus == ioOk
    ck survivor.spawnStatus == ioOk
    ck sock.connectStatus == ioOk

    let tornPid = child.process.pid
    let survivorPid = survivor.process.pid
    ck tornPid > 0
    ck survivorPid > 0
    ck tornPid != survivorPid

    # THE PROBES CAN ANSWER BOTH WAYS. Asserted before the teardown, so a
    # `/proc` probe stuck on "gone" cannot make the case below vacuous.
    ck processIsAlive(tornPid)
    ck processIsAlive(survivorPid)
    ck openSocketCount() > socketsAtStart
    ck h.liveHandleCount("acme.torn") == 4       # process + three streams
    ck h.liveHandleCount("acme.torn.sock") == 1
    ck "acme.torn" in h.handleReport()
    ck "sleep (pid " & $tornPid & ")" in h.handleReport()

    # MID-OPERATION. A read is outstanding on the child's stdout — `sleep`
    # will never write — and on the socket, and the plugin is torn down
    # underneath both.
    let pendingChildRead = child.process.stdout.read()
    let pendingSocketRead = sock.stream.read()
    ck not pendingChildRead.finished
    ck not pendingSocketRead.finished

    ck h.deactivate("acme.torn")
    ck h.deactivate("acme.torn.sock")

    # The accounting says nothing is held...
    ck h.liveHandleCount("acme.torn") == 0
    ck h.liveHandleCount("acme.torn.sock") == 0
    ck h.reclaimFailures.len == 0
    # ... and the OPERATING SYSTEM agrees. A counter that reached zero is also
    # what a table that forgot a handle looks like.
    ck waitUntil(not processIsAlive(tornPid), 5000)
    ck not dirExists("/proc/" & $tornPid)
    ck posix.kill(Pid(tornPid), cint(0)) != 0

    # The control did NOT die, so the sweep released this plugin's things
    # rather than everything.
    ck processIsAlive(survivorPid)
    ck h.liveHandleCount("acme.survivor") == 4

    # No leaked socket: back to where we were before the plugin connected,
    # allowing for the surviving plugin's pipes (which are not sockets).
    ck waitUntil(openSocketCount() <= socketsAtStart, 5000)

    # And the plugin is genuinely deactivated, not merely stripped of handles.
    ck not h.isActive("acme.torn")
    ck h.isActive("acme.survivor")

    # Tidy the control up through the same mechanism, and check it too.
    ck h.deactivate("acme.survivor")
    ck waitUntil(not processIsAlive(survivorPid), 5000)
    reapPeer(peer)
    removeFile(sockPath)

  test "deactivateAll leaves nothing behind, for a plugin that closed nothing":
    discard requireTool("sleep")
    let g = grantsFor({capProcess}, execs = @["sleep"])
    let a = newIoPipelinePlugin("sleep", @[])
    a.args = @["300"]
    a.keepOpen = true
    let b = newIoPipelinePlugin("sleep", @[])
    b.args = @["300"]
    b.keepOpen = true
    let h = hostWith(a.implementation(manifestFor("acme.a", g)),
                     b.implementation(manifestFor("acme.b", g)))
    waitFor a.startLongRunning()
    waitFor b.startLongRunning()
    let pidA = a.process.pid
    let pidB = b.process.pid
    ck processIsAlive(pidA)
    ck processIsAlive(pidB)
    ck h.deactivateAll() == 2
    ck waitUntil(not processIsAlive(pidA), 5000)
    ck waitUntil(not processIsAlive(pidB), 5000)
    ck h.handleReport().len == 0

suite "PLAT-8: handle accounting, and reclaim without restarting":

  test "handles are attributable, per plugin, per kind":
    discard requireTool("cat")
    let g = grantsFor({capProcess, capSocketLocal}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.count", g)))
    let ctx = h.contextFor("acme.count")
    ck ctx.state.handles.liveCount == 0
    let spawned = waitFor probe.attemptSpawn("cat")
    ck spawned.status == ioOk
    ck ctx.state.handles.countOf(hkProcess) == 1
    ck ctx.state.handles.countOf(hkProcessStream) == 3
    let listened = waitFor probe.attemptListen("127.0.0.1", 0)
    ck listened.status == ioOk
    ck ctx.state.handles.countOf(hkListener) == 1
    ck ctx.state.handles.liveCount == 5
    let report = ctx.state.handles.describe()
    ck "acme.count" in report
    ck "cat (pid " in report
    ck "tcp:127.0.0.1:" in report
    ck ctx.state.handles.opened == 5
    closeProcess(spawned.process)
    closeListener(listened.listener)
    ck ctx.state.handles.liveCount == 0
    ck ctx.state.handles.closedCount == 5

  test "reclaim releases the resources and leaves the plugin ALIVE":
    # §8.1.1: "its resources are reclaimable without restarting CodeTracer".
    # Concretely: not the application, and not the plugin either.
    discard requireTool("sleep")
    let g = grantsFor({capProcess}, execs = @["sleep"])
    let p = newIoPipelinePlugin("sleep", @[])
    p.args = @["300"]
    p.keepOpen = true
    let h = hostWith(p.implementation(manifestFor("acme.hog", g)))
    waitFor p.startLongRunning()
    let pid = p.process.pid
    ck processIsAlive(pid)
    ck h.liveHandleCount("acme.hog") == 4
    ck h.reclaim("acme.hog") == 4
    ck waitUntil(not processIsAlive(pid), 5000)
    ck h.liveHandleCount("acme.hog") == 0
    # STILL ACTIVE. This is the difference from `deactivate`.
    ck h.isActive("acme.hog")
    # And the plugin can open a new one, because it was never torn down.
    waitFor p.startLongRunning()
    ck p.spawnStatus == ioOk
    let second = p.process.pid
    ck second != pid
    ck processIsAlive(second)
    ck h.deactivate("acme.hog")
    ck waitUntil(not processIsAlive(second), 5000)

  test "a stream whose handle was reclaimed answers ioClosed, not a crash":
    discard requireTool("cat")
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.reclaimed", g)))
    let spawned = waitFor probe.attemptSpawn("cat")
    ck spawned.status == ioOk
    let stdinStream = spawned.process.stdin
    ck h.reclaim("acme.reclaimed") == 4
    let w = waitFor stdinStream.write("anything")
    ck w.status == ioClosed

    # THE READ IS BOUNDED, and that is a fix rather than a decoration.
    #
    # `read` on a released stream answers `ioClosed` from `isOpen` WITHOUT
    # touching the descriptor — which is the whole assertion. If a defect
    # leaves the stream open, the same call reaches the descriptor, and this
    # one is a child's stdin: the WRITE end of a pipe. `asyncdispatch`
    # registers it for readability and epoll never reports a write end as
    # readable, so the future never completes and never fails.
    #
    # Measured, and it cost an hour: mutation arm P24 (a `close` that does not
    # run its closer) left the stream open here and the suite hung until the
    # harness's own timeout, scoring a mutation that had genuinely broken the
    # release as `SURVIVED — no case noticed`. A test that hangs on the defect
    # it is written to detect reports the defect as its absence.
    let readFut = stdinStream.read()
    ck waitFor withTimeout(readFut, 3000)
    if readFut.finished and not readFut.failed:
      ck readFut.read().status == ioClosed

  test "closing a handle twice is not an error":
    discard requireTool("cat")
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.twice", g)))
    let spawned = waitFor probe.attemptSpawn("cat")
    closeProcess(spawned.process)
    ck h.liveHandleCount("acme.twice") == 0
    closeProcess(spawned.process)
    ck h.liveHandleCount("acme.twice") == 0
    ck h.deactivate("acme.twice")
    ck h.reclaimFailures.len == 0

suite "PLAT-8: fs:read, fs:write, and the rule that neither reaches a recording":

  test "a declared path is readable and an undeclared one is not":
    let dir = setupWorkDir()
    let allowed = dir / "allowed"
    createDir(allowed)
    writeFile(allowed / "note.txt", "readable")
    let outside = dir / "outside.txt"
    writeFile(outside, "not for the plugin")
    let g = grantsFor({capFsRead}, reads = @[allowed])
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.fs", g)))
    let io = PluginIoContext()
    let ok = waitFor probe.attemptRead(io, allowed / "note.txt")
    ck ok.status == ioOk
    ck ok.data == "readable"
    let no = waitFor probe.attemptRead(io, outside)
    ck no.status == ioRefused
    ck "declared readable path" in no.message

  test "fs:read is not a way around 'trace'":
    # A recording under a declared readable directory is still recorded
    # program data, and §9 says what that contains.
    let dir = setupWorkDir()
    let root = dir / "readable-root"
    let recording = root / "trace-1"
    createDir(recording)
    writeFile(recording / "trace.bin", "recorded bytes")
    writeFile(root / "ordinary.txt", "ordinary bytes")
    let io = PluginIoContext(traceRoots: @[recording])

    let noTrace = newIoProbePlugin()
    discard hostWith(noTrace.implementation(manifestFor("acme.notrace",
      grantsFor({capFsRead}, reads = @[root]))))
    let refused = waitFor noTrace.attemptRead(io, recording / "trace.bin")
    ck refused.status == ioRefused
    ck "trace" in refused.message
    ck "inside a recording" in refused.message
    # The control, same plugin, same grant, a file one directory up.
    let allowed = waitFor noTrace.attemptRead(io, root / "ordinary.txt")
    ck allowed.status == ioOk
    ck allowed.data == "ordinary bytes"

    # And the control on the other axis: WITH 'trace', the same read succeeds.
    let withTrace = newIoProbePlugin()
    discard hostWith(withTrace.implementation(manifestFor("acme.trace",
      grantsFor({capFsRead, capTrace}, reads = @[root]))))
    let got = waitFor withTrace.attemptRead(io, recording / "trace.bin")
    ck got.status == ioOk
    ck got.data == "recorded bytes"

  test "a recording is never writable, under any grant":
    let dir = setupWorkDir()
    let root = dir / "writable-root"
    let recording = root / "trace-2"
    createDir(recording)
    let io = PluginIoContext(traceRoots: @[recording])
    let p = newIoProbePlugin()
    discard hostWith(p.implementation(manifestFor("acme.wtrace",
      grantsFor({capFsWrite, capTrace}, writes = @[root]))))
    let refused = waitFor p.attemptWrite(io, recording / "x.bin", "tamper")
    ck refused.status == ioRefused
    ck not fileExists(recording / "x.bin")
    # The control: outside the recording, the same plugin writes.
    let ok = waitFor p.attemptWrite(io, root / "ok.txt", "fine")
    ck ok.status == ioOk
    ck readFile(root / "ok.txt") == "fine"

# ---------------------------------------------------------------------------
# THE 2026-09-09 VERIFICATION ARMS. One suite per finding, each with a named
# control, each asserting the EFFECT rather than the report — because every
# escape this campaign found shared one shape: the report unchanged while the
# state moved. The sources these are built from are the verification pass's own
# arms A-D, re-run against the repaired tree.
# ---------------------------------------------------------------------------

proc registrationOf(text: string): auto =
  ## Register one manifest against a real host and hand back the parse result.
  ## `hostWithBudget` RAISES on a manifest that does not parse, which is right
  ## for the fifteen cases that are not about loading — and useless for the
  ## three that are.
  let host = newPluginHost(CoreVersion, initDuration(milliseconds = 250))
  host.register(text, "verification-arm.json", proc(ctx: PluginContext) = discard)

suite "PLAT-8 F1: 'process' is an exfiltration path, and it is disclosed":

  # THE VERIFICATION PASS'S ARM C, re-run. A plugin declaring `trace`,
  # `fs:read` and `process` with `env` as its one declared executable — no
  # socket capability, no declared host, no trace-egress grant — read a
  # recording and shipped it over TCP, and the user was shown nothing. The
  # milestone's "`process` is not the hole that would make it pointless" and
  # "a plugin cannot reach a shell" were both false.

  const ArmC = """{
  "id": "armc.exfil", "version": "1.0.0",
  "activation": [{"event": "trace-opened"}],
  "capabilities": ["process", "fs:read", "trace"],
  "executables": ["env"],
  "paths": {"read": ["/tmp"]}$1
}"""

  test "the arm's own manifest is REFUSED AT LOAD, and the error is the reach":
    let refused = registrationOf(ArmC % [""])
    ck not refused.isOk
    var found = false
    for e in refused.errors:
      if e.code == pecTraceEgressNotAcknowledged:
        found = true
        ck "SUBSUMES every other capability" in e.detail
        ck "any host this machine can reach" in e.detail
        ck "env" in e.detail
    ck found

    # THE CONTROL, and the other half of the acceptance test: with the
    # acknowledgement the SAME manifest loads. "Refused at load" is not the
    # answer "nothing with `process` may exist" — it is "nothing with
    # `process` may exist without the user being told".
    let acked = registrationOf(ArmC % [
      ",\n  \"traceEgress\": {\"acknowledged\": true, \"statement\": \"" &
      SuiteAck & "\"}"])
    if not acked.isOk:
      checkpoint renderAll(acked.errors)
    ck acked.isOk
    let shown = describeGrants("armc.exfil", acked.manifest.grants)
    ck "SUBSUMES every other capability" in shown
    ck "may spawn: env" in shown

  test "the exploit is REAL, and the only way to run it is with the disclosure":
    # THE EFFECT-LEVEL HALF, and it is arranged so that neither arm can stand
    # in for the other.
    #
    # The refusal is asserted at TWO layers, exactly as P12/P8 already are:
    # `parseManifest` refuses the composition at load (the case above), and
    # `capabilities.decide` refuses the spawn at runtime (asserted here,
    # directly, because a plugin that cannot load cannot be driven through the
    # SDK — the load gate is doing its job, and that is not the same as the
    # runtime gate having been tested).
    #
    # Then the EXPLOIT ITSELF runs, under the acknowledgement, and the
    # sentinel a shell would create is asserted to exist. Without that arm the
    # refusals above would be equally satisfied by an `env` that cannot reach a
    # shell at all, and the finding would read as fixed by something that
    # never worked — Verification-Harness-Traps §4a's positive twin, on an
    # exploit instead of on a scan.
    discard requireTool("env")
    discard requireTool("sh")
    let dir = setupWorkDir()
    let sentinel = dir / "f1-sentinel-" & $epochTime().int & ".txt"
    removeFile(sentinel)
    # ARGV ONLY. No metacharacter anywhere in anything the host parses: `env`
    # is the program, and `sh`, `-c` and the command are three list elements
    # that reach `execve` untouched. This is the shape "arguments are a list"
    # does not stop, and which the milestone read as though it did.
    let argv = @["sh", "-c", "echo EXFIL-VIA-DECLARED-PROGRAM > " & sentinel]

    let without = grantsFor({capTrace, capFsRead, capProcess},
                            execs = @["env"], reads = @[dir], ack = false)
    let runtime = decide(without, "armc.exfil",
                         IoRequest(kind: irSpawnProcess, target: "env"))
    ck not runtime.permitted
    ck runtime.capability == capProcess
    ck "subsumes every other capability" in runtime.reason
    # Nothing ran, so nothing was created.
    ck not fileExists(sentinel)

    # THE POSITIVE TWIN: the same plugin, the same argv, the same declared
    # `env`, plus the acknowledgement.
    let withAck = grantsFor({capTrace, capFsRead, capProcess},
                            execs = @["env"], reads = @[dir])
    ck decide(withAck, "armc.disclosed",
              IoRequest(kind: irSpawnProcess, target: "env")).permitted
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(
      manifestFor("armc.disclosed", withAck)))
    let ran = waitFor probe.attemptSpawn("env", argv)
    ck ran.status == ioOk
    ck waitFor withTimeout(ran.process.awaitExit(), PeerDeadlineMs)
    # THE EFFECT: a shell ran, from a plugin that declared `env` and nothing
    # else. This is the sentence "a plugin cannot reach a shell" being false.
    ck waitUntil(fileExists(sentinel), 5000)
    ck readFile(sentinel).strip() == "EXFIL-VIA-DECLARED-PROGRAM"
    # ... AND THE USER WAS TOLD. The invariant the whole finding is about: no
    # configuration lets a recording leave the machine without the disclosure
    # being in what a user reads before granting. `grantsReport` is that text.
    let report = h.grantsReport()
    ck "armc.disclosed" in report
    ck "SUBSUMES every other capability" in report
    ck "any host this machine can reach" in report
    ck "may spawn: env" in report
    closeProcess(ran.process)
    ck h.liveHandleCount("armc.disclosed") == 0
    removeFile(sentinel)

suite "PLAT-8 F2: a symlink is not a way around 'trace' or a declared root":

  # THE VERIFICATION PASS'S ARM B4, re-run. `normalisedFor` was
  # `absolutePath` + `normalizedPath`; neither resolves a symlink, and
  # `pathIsUnder` is textual:
  #
  #   direct read of the recording:               ioRefused   (the case that
  #                                                             was written)
  #   read via symlink into the recording:        ioOk  RECORDED-SECRETS
  #   read via symlink outside the declared root: ioOk  OUTSIDE-THE-ROOT
  #
  # It is repaired with realpath (`canonicalPath`), applied to the SUBJECT and
  # to the declared ROOTS through the same function.

  test "a link into a recording is refused, and the bytes do not come back":
    let base = setupWorkDir() / "f2-" & $epochTime().int
    let root = base / "root"
    let recording = base / "recording"
    let outside = base / "outside"
    createDir(root)
    createDir(recording)
    createDir(outside)
    writeFile(recording / "trace.bin", "RECORDED-SECRETS")
    writeFile(outside / "secret.txt", "OUTSIDE-THE-DECLARED-ROOT")
    writeFile(root / "plain.txt", "ORDINARY-DECLARED-DATA")
    createSymlink(recording / "trace.bin", root / "link-into-recording")
    createSymlink(outside / "secret.txt", root / "link-outside")
    createSymlink(recording, root / "dirlink")

    # `fs:read` over `root`, and NO `trace`. The host declares the recording.
    let io = PluginIoContext(traceRoots: @[recording])
    let g = grantsFor({capFsRead}, reads = @[root])
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.linky", g)))

    # THE POSITIVE CONTROL FIRST, so the three refusals below are not
    # satisfied by a reader that has stopped reading. Verification-Harness-
    # Traps §4a: a negative assertion needs a positive twin through the same
    # code path.
    let ok = waitFor probe.attemptRead(io, root / "plain.txt")
    ck ok.status == ioOk
    ck ok.data == "ORDINARY-DECLARED-DATA"

    # The case the milestone had: a direct read of the recording.
    let direct = waitFor probe.attemptRead(io, recording / "trace.bin")
    ck direct.status == ioRefused
    ck "trace" in direct.message

    # The three it did not have. Each asserts the STATUS and the BYTES,
    # because a refusal that still returned the data would satisfy the first.
    let viaFile = waitFor probe.attemptRead(io, root / "link-into-recording")
    ck viaFile.status == ioRefused
    ck "trace" in viaFile.message
    ck "RECORDED-SECRETS" notin viaFile.data
    ck viaFile.data.len == 0

    let viaDir = waitFor probe.attemptRead(io, root / "dirlink" / "trace.bin")
    ck viaDir.status == ioRefused
    ck "RECORDED-SECRETS" notin viaDir.data

    let viaOutside = waitFor probe.attemptRead(io, root / "link-outside")
    ck viaOutside.status == ioRefused
    ck "fs:read" in viaOutside.message
    ck "OUTSIDE-THE-DECLARED-ROOT" notin viaOutside.data
    removeDir(base)

  test "the declared root is canonicalised too, so a linked root still works":
    # THE HALF THAT IS EASY TO SKIP. Canonicalising the subject and not the
    # roots makes a declared root that is ITSELF reached through a symlink stop
    # containing its own children — `/tmp` on macOS, a bind-mounted trace
    # directory, a home under `/home/x` that is really `/data/home/x`. This is
    # the arm that would have caught a one-sided repair.
    let base = setupWorkDir() / "f2b-" & $epochTime().int
    createDir(base)
    let real = base / "real-root"
    createDir(real)
    writeFile(real / "data.txt", "REACHED-THROUGH-A-LINKED-ROOT")
    let linked = base / "linked-root"
    createSymlink(real, linked)

    # The plugin declares the LINKED spelling; the file is read through it.
    let g = grantsFor({capFsRead}, reads = @[linked])
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.linkroot", g)))
    let io = PluginIoContext(traceRoots: @[])
    let got = waitFor probe.attemptRead(io, linked / "data.txt")
    ck got.status == ioOk
    ck got.data == "REACHED-THROUGH-A-LINKED-ROOT"
    # ... and the same for a trace root declared through a link: the recording
    # is still refused when the HOST's spelling is the linked one and the
    # plugin's is the real one.
    let io2 = PluginIoContext(traceRoots: @[linked])
    let g2 = grantsFor({capFsRead}, reads = @[real])
    let probe2 = newIoProbePlugin()
    discard hostWith(probe2.implementation(manifestFor("acme.linkroot2", g2)))
    let blocked = waitFor probe2.attemptRead(io2, real / "data.txt")
    ck blocked.status == ioRefused
    ck "trace" in blocked.message
    removeDir(base)

  test "the HARD LINK residual, asserted so it cannot change in silence":
    # `canonicalPath` resolves symlinks; a hard link has nothing to resolve.
    # Two names, one inode, and every path-based policy — this one included —
    # sees only the name it was given. `openVerified`'s `(dev, ino)` check
    # cannot help either: the inode really is the one at that path.
    #
    # THIS IS ASSERTED RATHER THAN DESCRIBED because a residual in a comment
    # is a residual nobody re-measures. It is bounded by F1's repair rather
    # than by this file: making a hard link needs `link(2)`, the SDK offers
    # none, so it needs a spawned program — and `process` now requires the
    # trace-egress acknowledgement on its own.
    let base = setupWorkDir() / "f2c-" & $epochTime().int
    createDir(base)
    let root = base / "root"
    let recording = base / "recording"
    createDir(root)
    createDir(recording)
    writeFile(recording / "trace.bin", "HARDLINKED-SECRETS")
    var madeLink = true
    try:
      createHardlink(recording / "trace.bin", root / "hard.bin")
    except CatchableError:
      madeLink = false
    # LOUD, never a skip: if the filesystem refused the link the case has not
    # measured the residual and must say so rather than pass.
    ck madeLink

    let io = PluginIoContext(traceRoots: @[recording])
    let g = grantsFor({capFsRead}, reads = @[root])
    let probe = newIoProbePlugin()
    discard hostWith(probe.implementation(manifestFor("acme.hard", g)))
    let viaHard = waitFor probe.attemptRead(io, root / "hard.bin")
    # The residual, stated as an assertion. If a later milestone closes it —
    # by carrying a device/inode set for the trace roots, which is the only
    # way — this case goes red and the model's text is updated with it.
    ck viaHard.status == ioOk
    ck viaHard.data == "HARDLINKED-SECRETS"
    # The control, through the same reader: the SYMLINK spelling of the same
    # file is refused, so this is a fact about hard links and not about the
    # repair having been reverted.
    createSymlink(recording / "trace.bin", root / "soft.bin")
    let viaSoft = waitFor probe.attemptRead(io, root / "soft.bin")
    ck viaSoft.status == ioRefused
    removeDir(base)

suite "PLAT-8 F3: the SECOND capability pass, killed hermetically":

  test "'127.1' passes the first pass and is refused by the second":
    # THE ARM THAT REMOVES D1's DECLARED-SURVIVOR STATUS. PLAT-8 recorded that
    # the second capability pass could not be killed because "a hermetic suite
    # cannot make the resolver disagree with the literal", and that reaching
    # such a case "needs a target that classifies as loopback and resolves
    # elsewhere". Both clauses are wrong, and the MIRROR is the easy one:
    # `127.1` is not four octets, so `classifyHost` calls it `acRemote`, and
    # glibc resolves it to `127.0.0.1`. No /etc/hosts edit, no DNS.
    let server = newIoProbePlugin()
    discard hostWith(server.implementation(
      manifestFor("acme.f3.server", grantsFor({capSocketLocal}))))
    let listened = waitFor server.attemptListen("127.0.0.1", 0)
    ck listened.status == ioOk
    let port = listened.listener.boundPort
    ck port > 0
    # A REAL listener, so a refusal cannot be confused with a failed connect
    # to a closed port.
    let accepting = acceptFrom(listened.listener)

    let g = grantsFor({capSocketRemote},
                      hosts = @[DeclaredHost(host: "127.1", port: port)])
    # PASS ONE PERMITS. Asserted directly, because that is the whole content
    # of the arm: if the first pass refused this, the second would be
    # unreachable and the mutation removing it would be unkillable — which is
    # exactly what D1 claimed.
    ck decide(g, "acme.f3", IoRequest(kind: irConnectTcp, target: "127.1",
                                      port: port)).permitted

    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.f3", g)))
    let outcome = waitFor probe.attemptConnect("127.1", port)
    ck outcome.status == ioRefused
    ck "socket:local" in outcome.message
    ck "127.0.0.1" in outcome.message          # it names what it resolved to
    ck outcome.stream.isNil
    # THE EFFECT: the loopback daemon was never reached. A refusal taken after
    # the connect would leave this future finished.
    ck not accepting.finished
    ck h.liveHandleCount("acme.f3") == 0

    # THE CONTROL, through the same listener: a plugin holding `socket:local`
    # reaches it, so the refusal is about the GRANT and not about the daemon
    # being unreachable or the accept being broken.
    #
    # It writes `127.0.0.1` and not `127.1`, and that is the policy rather
    # than a convenience: `classifyHost` judges the LITERAL, and `127.1` is
    # not a literal loopback address, so a `socket:local` plugin naming it is
    # refused by the FIRST pass. Pass one is deliberately conservative about
    # spellings and pass two is the authority on the address; the arm above is
    # what proves pass two is live.
    let ctl = newIoProbePlugin()
    discard hostWith(ctl.implementation(
      manifestFor("acme.f3.ctl", grantsFor({capSocketLocal}))))
    let reached = waitFor ctl.attemptConnect("127.0.0.1", port)
    ck reached.status == ioOk
    # BOUNDED. A test that hangs on the defect it detects reports the defect
    # as its absence — and an unbounded `waitFor` on an accept that no
    # connection will ever satisfy is exactly that.
    ck waitFor withTimeout(accepting, PeerDeadlineMs)
    let served = accepting.read()
    ck served.status == ioOk
    closeStream(reached.stream)
    closeStream(served.stream)
    closeListener(listened.listener)

suite "PLAT-8 F4: the unspecified address is not a remote host":

  test "0.0.0.0 no longer reaches the loopback daemon with socket:remote":
    # THE VERIFICATION PASS'S ARM A/0.0.0.0, re-run. `0.0.0.0` classified
    # `acRemote`, RESOLVED to `0.0.0.0` so the second pass agreed, and
    # `connect(0.0.0.0)` reaches 127.0.0.1 on Linux — so a `socket:remote`-only
    # plugin reached a loopback daemon with both passes green, which falsifies
    # "neither grant implies the other, in both directions".
    let server = newIoProbePlugin()
    discard hostWith(server.implementation(
      manifestFor("acme.f4.server", grantsFor({capSocketLocal}))))
    let listened = waitFor server.attemptListen("127.0.0.1", 0)
    ck listened.status == ioOk
    let port = listened.listener.boundPort
    ck port > 0
    let accepting = acceptFrom(listened.listener)

    let g = grantsFor({capSocketRemote},
                      hosts = @[DeclaredHost(host: "0.0.0.0", port: port)])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.f4", g)))
    let outcome = waitFor probe.attemptConnect("0.0.0.0", port)
    ck outcome.status == ioRefused
    ck "UNSPECIFIED" in outcome.message
    ck outcome.stream.isNil
    # THE EFFECT — and it is what the finding was made of. The measurement
    # that killed the claim was not the outcome, it was that the loopback
    # daemon on the other end RECEIVED a frame from a plugin holding only
    # `socket:remote`. So the assertion is that no connection arrived.
    ck not accepting.finished
    ck h.liveHandleCount("acme.f4") == 0

    # THE CONTROL: the same daemon, the same port, reached by a plugin holding
    # the grant that covers loopback. The refusal is about the address.
    let ctl = newIoProbePlugin()
    discard hostWith(ctl.implementation(
      manifestFor("acme.f4.ctl", grantsFor({capSocketLocal}))))
    let reached = waitFor ctl.attemptConnect("127.0.0.1", port)
    ck reached.status == ioOk
    # BOUNDED, for the reason the F3 control states.
    ck waitFor withTimeout(accepting, PeerDeadlineMs)
    let served = accepting.read()
    ck served.status == ioOk
    ck (waitFor reached.stream.writeFrame("loopback-reached",
                                          frLengthPrefixed)).status == ioOk
    # BOUNDED, AND THIS ONE WAS MEASURED RATHER THAN ADDED FOR TIDINESS.
    # Verification-Harness-Traps §1a: a test that hangs on the defect it
    # detects reports the defect as its absence. With `acUnspecified` removed
    # — the mutation this arm exists to kill — the EXPLOIT's connection is the
    # one `accepting` completes with, the control's connection sits unaccepted
    # in the kernel backlog, and this read waits on a peer that will never
    # send. The pre-flight run hit exactly that and timed out at 500 s with
    # nothing reported.
    let gotF = served.stream.readFrame(frLengthPrefixed)
    ck waitFor withTimeout(gotF, PeerDeadlineMs)
    let got = gotF.read()
    ck got.status == ioOk
    ck got.frame == "loopback-reached"
    closeStream(reached.stream)
    closeStream(served.stream)
    closeListener(listened.listener)

  test "a plugin may not LISTEN on the unspecified address either":
    # The other verb, and the reason `acUnspecified` is its own class rather
    # than being folded into loopback: binding `0.0.0.0` publishes a service
    # from inside the debugger on every interface the machine has.
    let g = grantsFor({capSocketLocal, capSocketRemote},
                      hosts = @[DeclaredHost(host: "0.0.0.0", port: AnyPort)])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.f4.bind", g)))
    let outcome = waitFor probe.attemptListen("0.0.0.0", 0)
    ck outcome.status == ioRefused
    ck "UNSPECIFIED" in outcome.message
    ck outcome.listener.isNil
    ck h.liveHandleCount("acme.f4.bind") == 0
    # The control: the same plugin binds loopback, so the refusal is the
    # address and not the verb.
    let ok = waitFor probe.attemptListen("127.0.0.1", 0)
    ck ok.status == ioOk
    ck ok.listener.boundPort > 0
    closeListener(ok.listener)

suite "PLAT-8 F5: no surviving child means no surviving GRANDCHILD":

  test "a child that forks is killed with its process group, asserted at /proc":
    # THE VERIFICATION PASS'S ARM D2, re-run. `rawKill` sent SIGKILL to the
    # child pid and nothing else — no process group, no PR_SET_PDEATHSIG — so
    # for exactly the shape `startLongRunning`'s own comment names ("a
    # language server or an analyser daemon") the measurement was:
    #
    #     after deactivate: child alive=false grandchild alive=true
    #
    # The milestone's "no surviving child" was true of one process.
    if not dirExists("/proc"):
      raise newException(OSError,
        "this case measures the teardown against /proc and there is none. " &
        "Skipping would report a green run for the assertion the finding " &
        "is about.")
    discard requireTool("sh")
    # `sh` IS DECLARED, IN THE MANIFEST, and that is the honest way to build
    # this now: `process` subsumes every capability and says so, so a plugin
    # declaring a shell is not a special case to be smuggled — it is the model
    # working. The grandchild is backgrounded by the shell and stays in the
    # shell's process group, which is what `killpg` must reach.
    let script = "sleep 300 & echo $!; sleep 300"
    let g = grantsFor({capProcess}, execs = @["sh"])

    let torn = newIoPipelinePlugin("sh", @[])
    torn.args = @["-c", script]
    torn.keepOpen = true
    # THE CHILD NEEDS A `PATH`, AND THAT IS THE SDK WORKING RATHER THAN A
    # WORKAROUND. `spawnInner` gives the child the environment the PLUGIN
    # declared and nothing else, precisely so a child cannot inherit whatever
    # token CodeTracer was started with — so a shell spawned with no `env`
    # cannot find `sleep`, forks, fails to exec, and both generations exit at
    # once. Measured while writing this case: `/proc/<grandchild>` was gone
    # before the first probe, which reads exactly like the teardown having
    # worked. A case that had asserted only the AFTER state would have been
    # green over a grandchild that was never alive — which is why the probes
    # are asserted to answer BOTH ways.
    torn.env = @[("PATH", getEnv("PATH"))]
    # THE CONTROL is a second plugin with its own child AND grandchild, which
    # nobody deactivates. "Everything died" and "this plugin's tree died" are
    # different facts, and a killpg aimed at the wrong group produces the
    # first.
    let survivor = newIoPipelinePlugin("sh", @[])
    survivor.args = @["-c", script]
    survivor.keepOpen = true
    survivor.env = @[("PATH", getEnv("PATH"))]

    let h = hostWith(torn.implementation(manifestFor("armd.torn", g)),
                     survivor.implementation(manifestFor("armd.alive", g)))
    waitFor torn.startLongRunning()
    waitFor survivor.startLongRunning()
    ck torn.spawnStatus == ioOk
    ck survivor.spawnStatus == ioOk

    let tornPid = torn.process.pid
    let alivePid = survivor.process.pid
    ck tornPid > 0
    ck alivePid > 0

    # THE GRANDCHILD'S PID COMES FROM THE GRANDCHILD'S OWN PARENT, over the
    # SDK's streams, bounded — a test that hangs on the defect it detects
    # reports the defect as its absence.
    let tornF = torn.process.stdout.readFrame(frDelimited)
    ck waitFor withTimeout(tornF, PeerDeadlineMs)
    let tornGrand = tornF.read().frame.strip().parseInt()
    let aliveF = survivor.process.stdout.readFrame(frDelimited)
    ck waitFor withTimeout(aliveF, PeerDeadlineMs)
    let aliveGrand = aliveF.read().frame.strip().parseInt()
    ck tornGrand > 0
    ck aliveGrand > 0
    ck tornGrand != tornPid
    ck tornGrand != aliveGrand

    # THE ISOLATION IS ASSERTED, NOT ASSUMED. `killpg` is only correct if the
    # child really is its own group leader; if it were not, `rawKill`'s guard
    # falls back to killing one pid and this case would go red below for the
    # right reason — but it would be silent about WHY. So the precondition is
    # named here.
    ck getpgid(Pid(tornPid)) == Pid(tornPid)
    ck getpgid(Pid(tornGrand)) == Pid(tornPid)

    # The probes answer both ways, before the teardown.
    ck processIsAlive(tornPid)
    ck processIsAlive(tornGrand)
    ck processIsAlive(alivePid)
    ck processIsAlive(aliveGrand)

    ck h.deactivate("armd.torn")
    ck h.liveHandleCount("armd.torn") == 0
    ck h.reclaimFailures.len == 0

    # THE ASSERTION THE FINDING IS ABOUT, against the OS rather than the
    # report: the GRANDCHILD is gone too.
    ck waitUntil(not processIsAlive(tornPid), 5000)
    ck waitUntil(not processIsAlive(tornGrand), 5000)
    # The CHILD is ours, so `rawKill` reaped it and it is gone outright.
    ck not dirExists("/proc/" & $tornPid)
    ck posix.kill(Pid(tornPid), cint(0)) != 0
    # THE GRANDCHILD IS NOT OURS TO REAP, and the assertion says exactly what
    # is true rather than the strongest-looking thing. It is dead — its state
    # is `Z` (killed, awaiting the reparented reaper) or it is gone — and it
    # is emphatically not RUNNING, which is the state the finding measured:
    # `after deactivate: child alive=false grandchild alive=true`. Asserting
    # `/proc/<grandchild>` is gone would be asserting that `init` has already
    # run, which is a race this suite would lose intermittently and which is
    # not a property of the teardown at all.
    let grandState = processState(tornGrand)
    checkpoint "grandchild state after teardown: '" & grandState & "'"
    ck grandState in ["", "Z"]
    ck not processIsAlive(tornGrand)

    # THE CONTROL SURVIVES, BOTH GENERATIONS. A `killpg` that reached
    # CodeTracer's own group, or a sweep that killed every child of this
    # process, would satisfy every assertion above and fail here.
    ck processIsAlive(alivePid)
    ck processIsAlive(aliveGrand)
    ck h.isActive("armd.alive")

    ck h.deactivate("armd.alive")
    ck waitUntil(not processIsAlive(alivePid), 5000)
    ck waitUntil(not processIsAlive(aliveGrand), 5000)

suite "PLAT-8: the I/O API is a deadline checkpoint":

  test "an I/O call inside an overrunning effect stops the run mid-flight":
    # PLAT-7's layer (b), reaching the I/O API: "PLAT-8's I/O primitives are
    # required to be checkpoints for the same reason."
    #
    # The effect is created by the PLUGIN, inside its own activation scope,
    # because that is the only place `pluginEffect` is legal — a suite
    # creating it from outside would be refused by `requireScope` and would
    # measure the guard rather than the budget.
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    probe.burnMs = 40
    probe.burnTool = "cat"
    let h = hostWithBudget(
      [probe.implementation(manifestFor("acme.slow", g))], 5)
    let ctx = h.contextFor("acme.slow")
    ck probe.reachedIo
    ck not probe.completedIo
    ck ctx.state.violations.len == 1
    ck ctx.state.violations[0].abortedMidRun
    ck ctx.state.suspended
    ck "acme.slow" in describe(ctx.state.violations[0])
    # Nothing was spawned: the checkpoint fired before the resource existed.
    ck h.liveHandleCount("acme.slow") == 0

  test "the same plugin with a budget it can meet reaches the I/O call":
    # THE CONTROL, through the same fixture and the same effect: it is the
    # DEADLINE that stopped the run above, not the presence of an I/O call in
    # an effect body.
    let g = grantsFor({capProcess}, execs = @["cat"])
    let probe = newIoProbePlugin()
    probe.burnMs = 1
    probe.burnTool = "cat"
    let h = hostWithBudget(
      [probe.implementation(manifestFor("acme.quick", g))], 5000)
    let ctx = h.contextFor("acme.quick")
    ck probe.reachedIo
    ck probe.completedIo
    ck ctx.state.violations.len == 0
    ck not ctx.state.suspended
    ck h.reclaim("acme.quick") == 4

suite "PLAT-8: what a user is shown before granting":

  test "the host renders every plugin's grants with its declared sets":
    let g = grantsFor({capProcess, capSocketLocal}, execs = @["cat"])
    let probe = newIoProbePlugin()
    let h = hostWith(probe.implementation(manifestFor("acme.shown", g)))
    let text = h.grantsReport()
    ck "acme.shown" in text
    ck "may spawn: cat" in text
    ck "socket:local" in text

suite "PLAT-8: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c. Written from a run.
    # 241 before the 2026-09-09 verification repairs; 377 with the F1-F6 arms
    # and their controls.
    check countedAssertions == 531
