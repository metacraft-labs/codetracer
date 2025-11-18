import
  std/[unittest, os, osproc],
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

suite "ct host idle timeout integration":
  let serverIndex = codetracerExeDir / "server_index.js"
  let node = nodeExe
  let available = fileExists(serverIndex) and fileExists(node)

  test "skips if server_index missing":
    if not available:
      echo "skip: server_index.js or node not found"
    check available or true

  test "exits with code 0 when no connection and short timeout":
    if not available:
      skip()
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
      skip()
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

  test "active connection activity prevents timeout":
    if not available:
      skip()
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
        "--idle-timeout-ms", "3000"
      ]
      host = startProcess(
        node,
        workingDir = codetracerInstallDir,
        args = hostArgs,
        options = {poStdErrToStdOut})

      # give the host a moment to bind ports
      sleep(400)

      let clientScript = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5002', {transports: ['websocket'], forceNew: true});
socket.on('connect', () => {
  let sent = 0;
  const interval = setInterval(() => {
    socket.emit('__activity__');
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

      let (clientExited, _) = waitForExitWithin(client, 2_000)
      check clientExited

      # Host should still be alive because activity kept resetting idle timer.
      let (hostExited, _) = waitForExitWithin(host, 2_500)
      check hostExited == false
    finally:
      ensureProcessStopped(client)
      ensureProcessStopped(host)

  test "reconnect resets idle timer":
    if not available:
      skip()
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

      # connect first socket and send one activity ping, then exit
      let clientScript1 = """
const io = require('socket.io-client');
const socket = io('ws://localhost:5003', {transports: ['websocket'], forceNew: true});
socket.on('connect', () => {
  socket.emit('__activity__');
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
const socket = io('ws://localhost:5003', {transports: ['websocket'], forceNew: true});
socket.on('connect', () => {
  socket.emit('__activity__');
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
