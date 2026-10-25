## test_ct_host_killed_leaves_no_process_behind.nim
##
## `ct host` and everything it started end together (`CLI/ct/host.md`,
## "Responsibilities": "shut down cleanly, terminating backends"; "Corner
## Cases": "**`ct host` is stopped or killed.**").
##
## ## The defect this pins
##
## `ct host` started `node server_index.js` and waited for it, and nothing
## else. When `ct host` itself was signalled — the GUI test fixture ends a web
## test that way, as does a supervisor stopping a container's command — the
## node server was not told: it was re-parented to init and kept running, with
## its session-manager and replay-server beneath it. On a host running many GUI
## lanes these accumulated until something reaped them.
##
## ## What runs
##
## The real `ct host --trace-path` on the materialized GDScript recording the
## other suites in this directory use (`ct_host_harness`), which starts the
## real node index, the real session-manager and a real `replay-server` once a
## client launches a replay. The client is socket.io's own client under node,
## playing the page as `test_ct_host_sessions_are_isolated_per_client.nim`
## does, until its replay stops at the entry.
##
## The signal goes to the `ct host` process ALONE, never to its process group
## or session: a group kill is what the harness's `stopHost` does, and it is
## exactly the teardown that hid this defect. Every process `ct host` started
## is found in two ways that do not depend on each other: by descent from
## `ct host` (`/proc/<pid>/stat` field 4, snapshotted before the kill, since
## orphans are re-parented), and by membership of the session the harness put
## `ct host` in (field 6, which survives re-parenting). Each process is
## identified by pid AND start time, so a recycled pid cannot read as a
## survivor or hide one. A zombie counts as gone: it runs nothing and holds
## nothing open.
##
## No mocks: nothing in `ct host` is replaced. Linux only: it reads `/proc`.
##
## ## The arms
##
## For each of SIGTERM, SIGINT and SIGHUP (forwarded by `ct host` to the node
## server, which stops its session-manager, which stops its replays) and
## SIGKILL (which nothing can forward: the node server notices that its parent
## has gone): before the signal, the node server, the session-manager and a
## replay-server are running (the vacuity guard: an arm that killed nothing
## would pass trivially); after it, within `SurvivorDeadlineS`, none of the
## processes found before the signal is alive and the session holds no
## process.
##
## SIGTERM and SIGKILL again with `CODETRACER_NODE_EXE_PATH` naming a wrapper
## that forks node and waits for it instead of exec'ing it: the forwarded
## SIGTERM then ends only the wrapper, and node's parent is the wrapper, not
## `ct host`, so only a watch on `ct host` itself can end the server. Each
## wrapper arm also checks that node's parent really is not `ct host`. The
## SIGKILLed `ct host` is left an unreaped zombie for the whole arm, as it is
## under a supervisor slow to reap it.
##
## And `node server_index.js` started directly with a `--caller-pid` that is not
## its parent: naming a process that has already exited, the server exits (a
## `ct host` that died while node was starting); naming a live one, it keeps
## serving for five seconds (the control) and exits once that process is
## SIGKILLed and left unreaped.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[json, os, osproc, posix, strtabs, strutils, times, unittest]

import ct_host_harness

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 49

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  SurvivorDeadlineS = 20.0
    ## How long the processes `ct host` started have to end. Far above what
    ## the shutdown takes (the node server polls for its parent's death once
    ## a second); the bound exists so a leak fails the arm instead of hanging
    ## it.

  LaunchScript = """
'use strict';
// Plays one page until its replay stops at the entry, then reports and leaves.
// The replay outlives the page: the server keeps a client's session for the
// idle timeout, which is what puts a replay-server under `ct host` for the
// kill that follows.
const io = require('socket.io-client');
const port = process.env.CT_TEST_SOCKET_PORT;
const pageOrigin = process.env.CT_TEST_PAGE_ORIGIN;
const secret = process.env.CT_TEST_SECRET;
const out = { replayIds: [], stopped: false, errors: [] };
let seq = 0;
const socket = io('http://127.0.0.1:' + port, {
  transports: ['websocket'], forceNew: true, reconnection: false, timeout: 20000,
  query: { ct_session: secret, ct_client: 'kill-test' },
  extraHeaders: { Origin: pageOrigin },
});
const send = (command, args) => socket.emit('CODETRACER::dap-raw-message',
  { seq: seq++, type: 'request', command, arguments: args || {}, sessionId: 0 });
const done = () => { clearTimeout(timer); socket.close(); console.log(JSON.stringify(out)); };
const timer = setTimeout(() => { out.errors.push('timeout'); done(); }, 90000);
socket.on('connect_error', (e) => { out.errors.push('connect_error: ' + (e && e.message)); done(); });
socket.on('connect', () => socket.emit('CODETRACER::session-sync', JSON.stringify({ type: 'hello' })));
socket.on('CODETRACER::started', () => socket.emit('CODETRACER::started', {}));
socket.on('CODETRACER::dap-replay-selected', (p) => {
  const v = JSON.parse(p);
  out.replayIds.push(v.replayId);
  send('initialize', { clientName: 'codetracer' });
  send('configurationDone', {});
  send('launch', { traceFolder: v.trace.outputFolder });
});
socket.on('CODETRACER::dap-receive-event', (p) => {
  const v = JSON.parse(p);
  if (v.event === 'ct/complete-move' && !out.stopped) { out.stopped = true; done(); }
});
"""

type
  ProcId = object
    ## A process, as pid and start time (`/proc/<pid>/stat` field 22): a pid
    ## alone may have been recycled by the time it is looked at again.
    pid: int
    start: string
    name: string
    ppid: int

  ProcStat = object
    ok: bool
    name: string
    state: char
    ppid: int
    session: int
    start: string

proc readStat(pid: int): ProcStat =
  ## `/proc/<pid>/stat`, parsed after the LAST `)`: the command name inside
  ## the parentheses may itself contain spaces and parentheses.
  var raw = ""
  try:
    raw = readFile("/proc" / $pid / "stat")
  except CatchableError:
    return
  let open = raw.find('(')
  let close = raw.rfind(')')
  if open < 0 or close < open:
    return
  let fields = raw[close + 2 .. ^1].splitWhitespace()
  # `fields[0]` is field 3 (state); field N is `fields[N - 3]`.
  if fields.len < 20:
    return
  try:
    result = ProcStat(ok: true, name: raw[open + 1 ..< close],
      state: fields[0][0], ppid: parseInt(fields[1]),
      session: parseInt(fields[3]), start: fields[19])
  except ValueError:
    result.ok = false

proc allPids(): seq[int] =
  for kind, path in walkDir("/proc", relative = true):
    if kind == pcDir and path.len > 0 and path.allCharsInSet(Digits):
      result.add parseInt(path)

proc exeName(pid: int): string =
  ## The executable's base name: `/proc/<pid>/comm` truncates to 15 bytes,
  ## which turns `session-manager` and `replay-server` into ambiguous stems.
  try: expandSymlink("/proc" / $pid / "exe").extractFilename
  except CatchableError: readStat(pid).name

proc alive(p: ProcId): bool =
  let st = readStat(p.pid)
  st.ok and st.start == p.start and st.state notin {'Z', 'X'}

proc descendants(root: int): seq[ProcId] =
  ## Every live process below `root`, found by walking parent links.
  var parents: seq[(int, ProcStat)]
  for pid in allPids():
    let st = readStat(pid)
    if st.ok and st.state notin {'Z', 'X'}:
      parents.add (pid, st)
  var frontier = @[root]
  while frontier.len > 0:
    let parent = frontier.pop()
    for (pid, st) in parents:
      if st.ppid == parent:
        result.add ProcId(pid: pid, start: st.start, name: exeName(pid), ppid: st.ppid)
        frontier.add pid

proc inSession(session: int): seq[ProcId] =
  for pid in allPids():
    let st = readStat(pid)
    if st.ok and st.session == session and st.state notin {'Z', 'X'}:
      result.add ProcId(pid: pid, start: st.start, name: exeName(pid), ppid: st.ppid)

proc names(procs: seq[ProcId]): seq[string] =
  for p in procs:
    result.add p.name & "[" & $p.pid & "]"

proc hasNamed(procs: seq[ProcId]; name: string): bool =
  for p in procs:
    if p.name == name:
      return true

proc waitUntilNamed(root: int; name: string; timeoutS: float): seq[ProcId] =
  let deadline = epochTime() + timeoutS
  while true:
    result = descendants(root)
    if result.hasNamed(name) or epochTime() > deadline:
      return
    sleep(100)

proc runArm(signal: cint; forkingWrapper = false) =
  let scratch = createHostScratch("ct-host-killed-")
  var host: Host
  try:
    var extraEnv: seq[(string, string)]
    if forkingWrapper:
      # A `node` that FORKS the real one and waits, as a launcher script
      # without `exec` does: `ct host`'s child is then the wrapper, so a
      # forwarded signal stops only the wrapper and node is never re-parented
      # when `ct host` dies.
      let realNode = findExe("node")
      let wrapperPath = scratch / "node-wrapper.sh"
      writeFile(wrapperPath, "#!" & findExe("bash") & "\n\"" & realNode & "\" \"$@\"\n")
      setFilePermissions(wrapperPath, {fpUserRead, fpUserWrite, fpUserExec})
      extraEnv.add ("CODETRACER_NODE_EXE_PATH", wrapperPath)
    host = startHost(scratch, extraEnv)
    let hostPid = host.process.processID
    let hostStat = readStat(hostPid)
    let session = hostStat.session
    checkpoint "ct host pid " & $hostPid & " (" & hostStat.name & "), session " & $session

    let scriptPath = scratch / "launch.js"
    writeFile(scriptPath, LaunchScript)
    let (output, exitCode) = runNodeScript(host, scriptPath)
    checkpoint "launch client (exit " & $exitCode & "): " & output
    var launched = newJObject()
    for line in output.splitLines():
      if line.startsWith("{"):
        try: launched = parseJson(line) except CatchableError: discard
    ck launched{"stopped"}.getBool(false)

    # The vacuity guard: what the signal is supposed to end is running.
    let before = waitUntilNamed(hostPid, "replay-server", 30.0)
    checkpoint "before the signal: " & before.names.join(", ")
    ck before.hasNamed("node")
    ck before.hasNamed("session-manager")
    ck before.hasNamed("replay-server")
    if forkingWrapper:
      # The wrapper arm's own vacuity guard: node really is behind it.
      var nodeParent = -1
      for p in before:
        if p.name == "node": nodeParent = p.ppid
      ck nodeParent > 0 and nodeParent != hostPid

    # `ct host` ALONE: not its group, not its session.
    ck posix.kill(Pid(hostPid), signal) == 0

    let deadline = epochTime() + SurvivorDeadlineS
    var survivors, sessionLeft: seq[ProcId]
    while true:
      survivors = @[]
      for p in before:
        if p.alive:
          survivors.add p
      sessionLeft = inSession(session)
      if (survivors.len == 0 and sessionLeft.len == 0) or epochTime() > deadline:
        break
      sleep(200)
    checkpoint "still running after " & $SurvivorDeadlineS & "s: " &
      survivors.names.join(", ") & " | in the session: " & sessionLeft.names.join(", ")
    ck survivors.len == 0
    ck sessionLeft.len == 0
  finally:
    # Whatever the arm found, nothing of it outlives the suite.
    stopHost(host)
    removeDir(scratch)

when not defined(linux):
  {.error: "this suite reads /proc; it runs on Linux only".}

suite "ct host ends what it started when it is stopped or killed":
  test "SIGTERM to ct host alone ends the node server, the session-manager and the replay":
    runArm(SIGTERM)

  test "SIGINT to ct host alone ends the node server, the session-manager and the replay":
    runArm(SIGINT)

  test "SIGHUP to ct host alone ends the node server, the session-manager and the replay":
    runArm(SIGHUP)

  test "SIGKILL of ct host ends the node server, the session-manager and the replay":
    runArm(SIGKILL)

  test "SIGTERM to ct host alone, with node behind a forking wrapper, ends them all":
    runArm(SIGTERM, forkingWrapper = true)

  test "SIGKILL of ct host, with node behind a forking wrapper, ends them all":
    runArm(SIGKILL, forkingWrapper = true)

proc startServerFor(scratch: string; owner: int): Process =
  ## `node server_index.js` started directly, as `ct host` starts it, but with
  ## `--caller-pid` naming `owner`, which is NOT its parent: only the watch on
  ## the owner itself can end it. The idle timeout is far beyond the arm, so it
  ## cannot be what ends the server.
  let prefix = ctBinary.parentDir.parentDir
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["CODETRACER_PREFIX"] = prefix
  env["NODE_PATH"] = prefix / "node_modules"
  env["CODETRACER_HOME"] = scratch / HomeDirName
  env["TMPDIR"] = scratch
  startProcess(findExe("node"), workingDir = root, env = env,
    args = @[prefix / "server_index.js", "-1", "--welcome-screen",
             "--port", $freePort(), "--frontend-socket-port", $freePort(),
             "--frontend-socket-parameters", "",
             "--backend-socket-port", $freePort(),
             "--caller-pid", $owner, "--idle-timeout-ms", "600000"],
    options = {poParentStreams})

proc exitsWithin(p: Process; seconds: float): bool =
  let deadline = epochTime() + seconds
  while p.running:
    if epochTime() > deadline:
      return false
    sleep(100)
  true

suite "the server ends with its --caller-pid, which need not be its parent":
  test "an owner already gone when the server starts: the server exits":
    let scratch = createHostScratch("ct-host-owner-gone-")
    # A pid that named a process a moment ago and names none now.
    let gone = startProcess("/usr/bin/env", args = @["true"])
    let gonePid = gone.processID
    discard gone.waitForExit()
    gone.close()
    let server = startServerFor(scratch, gonePid)
    try:
      ck server.exitsWithin(SurvivorDeadlineS)
      # Status 0 is the lifetime watch's own exit (`shutDown`); a server that
      # crashed while starting would have exited too, with another status.
      ck server.peekExitCode == 0
    finally:
      if server.running:
        server.kill()
      discard server.waitForExit()
      server.close()
      removeDir(scratch)

  test "a live owner keeps the server; its death, not the server's parent's, ends it":
    let scratch = createHostScratch("ct-host-owner-live-")
    let owner = startProcess("/usr/bin/env", args = @["sleep", "600"])
    let server = startServerFor(scratch, owner.processID)
    try:
      # The control: with its owner alive, the watch leaves the server be.
      sleep(5_000)
      ck server.running
      discard posix.kill(Pid(owner.processID), SIGKILL)
      # Left an unreaped zombie for the rest of the case, as a SIGKILLed
      # `ct host` is under a supervisor slow to reap it.
      ck server.exitsWithin(SurvivorDeadlineS)
      ck server.peekExitCode == 0
    finally:
      if server.running:
        server.kill()
      discard server.waitForExit()
      server.close()
      discard owner.waitForExit()
      owner.close()
      removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
