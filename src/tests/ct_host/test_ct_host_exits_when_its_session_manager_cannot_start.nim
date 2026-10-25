## test_ct_host_exits_when_its_session_manager_cannot_start.nim
##
## A `ct host` whose session manager cannot start EXITS non-zero, naming the
## socket path it waited for and the session manager's exit status, and tells
## the connected page why, instead of serving a page that never gets a
## session.
##
## ## Why the claim matters
##
## Under a `CODETRACER_HOME` deep enough that the session manager's socket
## (`<home>/tmp/session-manager/<pid>.sock`) is longer than a Unix socket
## address holds (`sockaddr_un.sun_path`), the session manager refuses to bind
## it, by name, and exits. `ct host`'s server waited for that socket for ever
## ("still waiting for session-manager socket (attempt 60)"), `ct host` kept
## running, and every client timed out without a cause; the `ct host` suites
## failed that way on macOS, whose default `TMPDIR` is deep.
##
## ## What runs
##
## The real `ct host` (`ct_host_harness.startHost`) on a recording checked
## into this repository, given a deliberately deep `CODETRACER_HOME` under
## `/tmp` (the harness's own bound check is what this suite bypasses: it tests
## the product's answer to that home). The server starts its session manager
## when the first client connects, so a real socket.io client connects, with
## the session secret, from the page's origin, and reports what it was told.
## No mocks.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[json, os, osproc, strutils, times, unittest]

import ct_host_harness

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 9

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  ExitDeadlineSeconds = 60.0
    ## The refusal is decided within a second or two of the client
    ## connecting; the deadline is what turns the defect (no exit) into a
    ## failure.

const Client = """
'use strict';
// One admitted client: what it is told before its connection ends.
const io = require('socket.io-client');
const socket = io('http://127.0.0.1:' + process.env.CT_TEST_SOCKET_PORT, {
  transports: ['websocket'], forceNew: true, reconnection: false, timeout: 5000,
  query: { ct_session: process.env.CT_TEST_SECRET },
  extraHeaders: { Origin: process.env.CT_TEST_PAGE_ORIGIN },
});
const out = { connected: false, disconnected: false, told: null };
const done = () => { socket.close(); process.stdout.write(JSON.stringify(out) + '\n'); process.exit(0); };
setTimeout(done, 60000);
socket.on('connect', () => { out.connected = true; });
socket.on('CODETRACER::connection-disconnected', (payload) => { out.told = JSON.parse(payload); });
socket.on('disconnect', () => { out.disconnected = true; setTimeout(done, 100); });
socket.on('connect_error', () => done());
"""

suite "ct host exits when its session manager cannot start":

  test "a home too deep for the session manager's socket ends ct host, naming it":
    let scratch = createHostScratch("ct-host-sm-")
    var host: Host
    try:
      # `<home>/tmp/session-manager/<pid>.sock` is past the bound for any pid
      # once `<home>` alone leaves fewer than 27 bytes.
      let max = maxUnixSocketPathBytes()
      let home = scratch / repeat('h', max - 20 - scratch.len - 1)
      createDir(home)
      host = startHost(scratch, home = home)
      let script = scratch / "client.js"
      writeFile(script, Client)
      let (output, _) = runNodeScript(host, script)
      checkpoint("client: " & output)

      let deadline = epochTime() + ExitDeadlineSeconds
      while host.process.running and epochTime() < deadline:
        sleep(100)
      let exited = not host.process.running
      let log = readLog(host.logPath)
      checkpoint("ct host log:\n" & log)
      ck exited
      ck host.process.peekExitCode() != 0
      let socketDir = home / "tmp" / "session-manager"
      # The session manager's own refusal, and the server's.
      ck log.contains("sun_path")
      ck log.contains("exited")
      ck log.contains(socketDir)

      var told = newJNull()
      for line in output.splitLines():
        if line.startsWith("{"):
          told = parseJson(line)
      ck told.kind == JObject and told["connected"].getBool
      ck told.kind == JObject and told["disconnected"].getBool
      ck told.kind == JObject and told["told"].kind == JObject and
        told["told"]{"reason"}.getStr == "server-error"
      ck told.kind == JObject and told["told"].kind == JObject and
        told["told"]{"message"}.getStr.contains(socketDir)
    finally:
      stopHost(host)
      removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
