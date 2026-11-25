import
  std/[unittest, os, osproc, net, monotimes, times, strutils],
  ../../common/paths

proc ensureProcessStopped(p: Process) =
  if not p.isNil:
    try:
      if p.running:
        p.terminate()
    except CatchableError:
      discard

proc waitForExitWithin(p: Process, timeoutMs: int): (bool, int) =
  var remaining = timeoutMs
  while p.running and remaining > 0:
    sleep(100)
    remaining -= 100
  if p.running:
    return (false, -1)
  (true, waitForExit(p))

# Wait until the host accepts TCP connections on `port`, instead of sleeping a
# fixed interval and hoping it has bound by then. The cases below used
# `sleep(300)` / `sleep(400)`; on a loaded host `node server_index.js` takes
# longer than that to start, the client then spends its budget retrying the
# connection, and "active connection activity prevents timeout" failed on
# `check clientExited` (twice in four runs on a heavily loaded 32-core host,
# 2026-10-23). A bare TCP connect is not a socket.io connection: the host's
# connection accounting (and its idle timer) only sees completed socket.io
# handshakes, so probing does not change what the cases measure.
proc waitForListening(port: int, timeoutMs: int): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let probe = newSocket()
    try:
      probe.connect("127.0.0.1", Port(port), timeout = 200)
      return true
    except OSError, TimeoutError:
      sleep(50)
    finally:
      probe.close()
  false

# FREE PORTS, NOT FIXED ONES (2026-11-25). The cases used to bind 12345-12350
# and 5000-5005. On a shared host 12345 was held by a process this suite could
# not see, so "exits with code 0 when no connection" ran a host that could not
# bind and failed three runs in three. Each case now asks the kernel for ports
# that are free when the suite starts.
proc freePort(): int =
  let s = newSocket()
  try:
    s.bindAddr(Port(0), "127.0.0.1")
    result = int(s.getLocalAddr()[1])
  finally:
    s.close()

var HttpPort: array[6, int]
var SockPort: array[6, int]
for i in 0 ..< 6:
  HttpPort[i] = freePort()
  SockPort[i] = freePort()

# The session secret a supervisor would give `ct host`. Every host and client
# below inherits it: the host admits a socket only with it
# (`index/host_session_guard.nim`), so without it the "connected" cases would
# have no connection to time out.
putEnv("CODETRACER_HOST_SESSION_SECRET", "idle-timeout-integration-test-session-secret")

suite "ct host idle timeout integration":
  let serverIndex = codetracerExeDir / "server_index.js"
  let node = nodeExe()
  let available = fileExists(serverIndex) and fileExists(node)

  # No "skips if server_index missing" case here any more. It asserted
  # `check available or true` -- a tautology, true for every possible value of
  # `available`, counted as a passing case forever. A test that cannot fail is
  # not coverage; it is a line in the tally.
  #
  # What the environment actually is gets REPORTED once, loudly, instead:
  if not available:
    echo "MISSING-HOST SKIP: ", serverIndex, " or ", node, " not found."
    echo "  Every case below is skipped. `just test-frontend-units` exports"
    echo "  CODETRACER_PREFIX so they run against the built tree."

  test "exits with code 0 when no connection and short timeout":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var p: Process
      try:
        let args = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[0],
          "--frontend-socket-port", $SockPort[0],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[0],
          "--caller-pid", "0",
          "--idle-timeout-ms", "1000"
        ]
        p = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = args,
          options = {poStdErrToStdOut})
        # A bound, not a schedule: the host must exit by itself, with code 0,
        # and a loaded host's `node` start-up can take several seconds before
        # the 1 s timeout even starts. Waiting for the port first is not an
        # option here: with nothing connecting, the host may time out before
        # a probe sees it listen (measured, load ~120).
        let (exited, code) = waitForExitWithin(p, 20_000)
        check exited
        check code == 0
      finally:
        ensureProcessStopped(p)

  test "disabled timeout keeps host alive beyond window":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var p: Process
      try:
        let args = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[1],
          "--frontend-socket-port", $SockPort[1],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[1],
          "--caller-pid", "0",
          "--idle-timeout-ms", "-1"
        ]
        p = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = args,
          options = {poStdErrToStdOut})
        # wait slightly longer than the previous timeout window; should still be running
        let (exitedEarly, _) = waitForExitWithin(p, 2_000)
        check exitedEarly == false
      finally:
        ensureProcessStopped(p)

  test "silent connection exits after inactivity window":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var host: Process
      var client: Process
      try:
        let hostArgs = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[2],
          "--frontend-socket-port", $SockPort[2],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[2],
          "--caller-pid", "0",
          "--idle-timeout-ms", "25000"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # allow the host to start before connecting
        check waitForListening(SockPort[2], 60_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:SOCKPORT', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
setTimeout(() => process.exit(0), 45000);
""".replace("SOCKPORT", $SockPort[2])
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        # Host should exit due to inactivity despite the connected socket: the
        # client stays connected (silently) for 45 s, past the 25 s window, so
        # the host's exit is the timeout and not the client leaving. The window
        # was 1.2 s, under a loaded host's 4-8 s start-up, so the host could
        # time out before it was listening at all.
        let (exited, code) = waitForExitWithin(host, 40_000)
        check exited
        check code == 0
      finally:
        ensureProcessStopped(client)
        ensureProcessStopped(host)

  test "active connection activity prevents timeout":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var host: Process
      var client: Process
      try:
        let hostArgs = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[4],
          "--frontend-socket-port", $SockPort[4],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[4],
          "--caller-pid", "0",
          "--idle-timeout-ms", "25000"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # wait for the host to bind its socket port
        check waitForListening(SockPort[4], 60_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:SOCKPORT', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  let sent = 0;
  const interval = setInterval(() => {
    socket.emit('test-event', { n: ++sent });
    if (sent >= 70) {
      clearInterval(interval);
      setTimeout(() => process.exit(0), 300);
    }
  }, 400);
});
""".replace("SOCKPORT", $SockPort[4])
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        # LONGER THAN THE IDLE WINDOW, SO ONLY THE ACTIVITY KEEPS THE HOST UP
        # (2026-11-25). The client is active for 28 s (70 x 400 ms) against a
        # 25 s idle timeout: a host that ignored the activity would exit while
        # the client is still sending. The windows used to be 3 s idle and
        # 1.05 s of activity. The host's idle clock starts before it listens,
        # and at load ~140 `node server_index.js` took 4.2-8.4 s to listen
        # (measured), so the host timed out before the client connected. Every
        # window that needs a client to connect first is now well above that.
        let (clientExited, _) = waitForExitWithin(client, 120_000)
        check clientExited

        # Host should still be alive because activity kept resetting idle timer.
        let (hostExited, _) = waitForExitWithin(host, 1_500)
        check hostExited == false
      finally:
        ensureProcessStopped(client)
        ensureProcessStopped(host)

  test "reconnect resets idle timer":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var host: Process
      var client1: Process
      var client2: Process
      try:
        let hostArgs = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[3],
          "--frontend-socket-port", $SockPort[3],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[3],
          "--caller-pid", "0",
          "--idle-timeout-ms", "25000"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        check waitForListening(SockPort[3], 60_000)

        # connect first socket and send one activity ping, then exit
        let clientScript1 = """
const io = require('socket.io-client');
const socket = io('ws://localhost:SOCKPORT', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  socket.emit('test-event', { source: 'first' });
  setTimeout(() => process.exit(0), 200);
});
""".replace("SOCKPORT", $SockPort[3])
        client1 = startProcess(
          node,
          args = @["-e", clientScript1],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client1, 2_000)

        # wait near the timeout but reconnect before it fires: 15 s of a 25 s
        # window, which leaves a loaded host 10 s to start the second client
        # and complete its handshake (the window was 1.5 s, with 0.6 s left).
        sleep(15_000)

        let clientScript2 = """
const io = require('socket.io-client');
const socket = io('ws://localhost:SOCKPORT', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  socket.emit('test-event', { source: 'second' });
  setTimeout(() => process.exit(0), 200);
});
""".replace("SOCKPORT", $SockPort[3])
        client2 = startProcess(
          node,
          args = @["-e", clientScript2],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client2, 2_000)

        # Host should survive past the original 25 s window because reconnect
        # reset the timer: 15 s + the second client + 12 s is past it.
        let (hostExited, _) = waitForExitWithin(host, 12_000)
        check hostExited == false
      finally:
        ensureProcessStopped(client1)
        ensureProcessStopped(client2)
        ensureProcessStopped(host)

  test "disconnect starts no-connection timer (no early exit)":
    if not available:
      # The `else` is load-bearing. `std/unittest`'s `skip()` MARKS this case
      # skipped; it does NOT leave the body. Without the arm below, every one
      # of these tests fell through into `startProcess` on a `node` that is not
      # there and reported a FAILURE where it meant to report a skip -- six of
      # them, measured. `return` is not an option: unittest rejects it inside a
      # test body ("'return' not allowed here").
      skip()
    else:
      var host: Process
      var client: Process
      try:
        let hostArgs = @[
          serverIndex,
          "-1",
          "--welcome-screen",
          "--port", $HttpPort[5],
          "--frontend-socket-port", $SockPort[5],
          "--frontend-socket-parameters", "",
          "--backend-socket-port", $SockPort[5],
          "--caller-pid", "0",
          "--idle-timeout-ms", "25000"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # wait for the host to start listening
        check waitForListening(SockPort[5], 60_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:SOCKPORT', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  const interval = setInterval(() => socket.emit('test-event', { tick: Date.now() }), 200);
  setTimeout(() => {
    clearInterval(interval);
    socket.disconnect();
    setTimeout(() => process.exit(0), 200);
  }, 2000);
});
""".replace("SOCKPORT", $SockPort[5])
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client, 3_000)

        # Host should not exit immediately after the long-lived connection closes.
        let (exitedEarly, _) = waitForExitWithin(host, 900)
        check exitedEarly == false

        # It should exit cleanly once the no-connection window (25 s, above a
        # loaded host's start-up time) elapses.
        let (exited, code) = waitForExitWithin(host, 40_000)
        check exited
        check code == 0
      finally:
        ensureProcessStopped(client)
        ensureProcessStopped(host)
