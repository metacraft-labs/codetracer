import
  std/[unittest, os, osproc, net, monotimes, times],
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
          "--port", "12345",
          "--frontend-socket-port", "5000",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5000",
          "--caller-pid", "0",
          "--idle-timeout-ms", "1000"
        ]
        p = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = args,
          options = {poStdErrToStdOut})
        # allow up to 4 seconds for timeout exit
        let (exited, code) = waitForExitWithin(p, 4_000)
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
          "--port", "12346",
          "--frontend-socket-port", "5001",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5001",
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
          "--port", "12347",
          "--frontend-socket-port", "5002",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5002",
          "--caller-pid", "0",
          "--idle-timeout-ms", "1200"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # allow the host to start before connecting
        check waitForListening(5002, 10_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5002', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
setTimeout(() => process.exit(0), 4000);
"""
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        # Host should exit due to inactivity despite the connected socket.
        let (exited, code) = waitForExitWithin(host, 4_000)
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
          "--port", "12349",
          "--frontend-socket-port", "5004",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5004",
          "--caller-pid", "0",
          "--idle-timeout-ms", "3000"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # wait for the host to bind its socket port
        check waitForListening(5004, 10_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5004', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  let sent = 0;
  const interval = setInterval(() => {
    socket.emit('test-event', { n: ++sent });
    if (sent >= 5) {
      clearInterval(interval);
      setTimeout(() => process.exit(0), 300);
    }
  }, 150);
});
"""
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        # The client's own script takes ~1.05 s once connected (5 x 150 ms of
        # activity, then 300 ms); the rest of the budget is `node` start-up and
        # the handshake, which on a loaded host exceeded the 2 s this used to
        # allow. The host-side assertion below is unchanged.
        let (clientExited, _) = waitForExitWithin(client, 10_000)
        check clientExited

        # Host should still be alive because activity kept resetting idle timer.
        let (hostExited, _) = waitForExitWithin(host, 2_500)
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
          "--port", "12348",
          "--frontend-socket-port", "5003",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5003",
          "--caller-pid", "0",
          "--idle-timeout-ms", "1500"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        check waitForListening(5003, 10_000)

        # connect first socket and send one activity ping, then exit
        let clientScript1 = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5003', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  socket.emit('test-event', { source: 'first' });
  setTimeout(() => process.exit(0), 200);
});
"""
        client1 = startProcess(
          node,
          args = @["-e", clientScript1],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client1, 2_000)

        # wait near the timeout but reconnect before it fires
        sleep(900)

        let clientScript2 = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5003', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  socket.emit('test-event', { source: 'second' });
  setTimeout(() => process.exit(0), 200);
});
"""
        client2 = startProcess(
          node,
          args = @["-e", clientScript2],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client2, 2_000)

        # Host should survive past the original 1.5s window because reconnect reset the timer.
        let (hostExited, _) = waitForExitWithin(host, 1_200)
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
          "--port", "12350",
          "--frontend-socket-port", "5005",
          "--frontend-socket-parameters", "",
          "--backend-socket-port", "5005",
          "--caller-pid", "0",
          "--idle-timeout-ms", "1500"
        ]
        host = startProcess(
          node,
          workingDir = codetracerInstallDir,
          args = hostArgs,
          options = {poStdErrToStdOut})

        # wait for the host to start listening
        check waitForListening(5005, 10_000)

        let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5005', {transports: ['websocket'], forceNew: true, query: {ct_session: process.env.CODETRACER_HOST_SESSION_SECRET}});
socket.on('connect', () => {
  const interval = setInterval(() => socket.emit('test-event', { tick: Date.now() }), 200);
  setTimeout(() => {
    clearInterval(interval);
    socket.disconnect();
    setTimeout(() => process.exit(0), 200);
  }, 2000);
});
"""
        client = startProcess(
          node,
          args = @["-e", clientScript],
          options = {poStdErrToStdOut})

        discard waitForExitWithin(client, 3_000)

        # Host should not exit immediately after the long-lived connection closes.
        let (exitedEarly, _) = waitForExitWithin(host, 900)
        check exitedEarly == false

        # It should exit cleanly once the no-connection window elapses.
        let (exited, code) = waitForExitWithin(host, 3_000)
        check exited
        check code == 0
      finally:
        ensureProcessStopped(client)
        ensureProcessStopped(host)
