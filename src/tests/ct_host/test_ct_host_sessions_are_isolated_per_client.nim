## test_ct_host_sessions_are_isolated_per_client.nim
##
## Two clients of one `ct host` get independent sessions (`CLI/ct/host.md`,
## "High-Level Rules": "**Sessions are isolated.** Two clients replaying the
## same trace get independent backends and cannot observe each other's
## position"; HSF-X3 deliverable 1: one `DebuggerSession` per connected client
## over a `BackendService` on that client's replay backend).
##
## ## The defect this pins
##
## The server kept ONE connection and ONE session. A second client sent the
## first `CODETRACER::connection-disconnected` with reason `superseded`, took
## over the index IPC surface, and continued the same replay; every page
## mirrored the one server-owned session (`ct-host`). So the second client was
## handed the first one's replay, its position and its moves.
##
## ## What runs
##
## The real `ct host --trace-path` on the materialized GDScript recording the
## admission suite uses (`ct_host_harness`), which starts the real node index,
## the real Backend Manager and real `replay-server` processes. Each client is
## socket.io's own client under node, speaking to the server exactly as the
## page does: the session secret and its client id (`ct_client`) in the
## handshake query, the page's `Origin`, `CODETRACER::started` answered, the
## DAP handshake (`initialize`, `configurationDone`, `launch` on the trace the
## server names in `CODETRACER::dap-replay-selected`) and the steps sent as
## `CODETRACER::dap-raw-message` frames shaped as `dap.dispatchCtRequest`
## builds them, the mirror's `hello` on `CODETRACER::session-sync`.
##
## No mocks: nothing in `ct host` is replaced. The node script plays the page
## because the property is about what the server gives each connection, and a
## browser would add a renderer whose own state cannot tell us which replay it
## was handed.
##
## ## The arms
##
## 1. Client A connects, launches its replay and stops at the entry. Client B
##    connects with another id. A is not superseded; A and B are handed
##    different replays and are told to follow different server sessions.
## 2. A steps twice. B receives none of A's replay events and none of A's
##    session's mirroring traffic.
## 3. B steps once, from where ITS replay was: it lands where A's first step
##    landed, not one step past A.
## 4. A reconnects with its id (a reload): it is handed its own replay again,
##    its own last position, and its own session, and B is not superseded.
## 5. A third client, C, gets a replay of its own, launches it and stops at
##    the entry: it is not shown A's position.
## 6. A asks the server to stop B's replay (`CODETRACER::close-replay-session`
##    with B's replay id): refused, so B still steps.
## 7. C stops its OWN replay. The Backend Manager then serves no replay at all,
##    whichever it was serving, so B — the replay it served last — still
##    steps only if the server selects B's replay again rather than assuming
##    it is still selected.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[json, os, strutils, unittest]

import ct_host_harness

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 29

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ScenarioScript = """
'use strict';
// Plays the pages of three clients against one `ct host` and prints what each
// was told, as one JSON line.
const io = require('socket.io-client');
const port = process.env.CT_TEST_SOCKET_PORT;
const pageOrigin = process.env.CT_TEST_PAGE_ORIGIN;
const secret = process.env.CT_TEST_SECRET;
const WAIT_MS = 90000;

const delay = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, ms) {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) return false;
    await delay(50);
  }
  return true;
}

function position(body) {
  const loc = body && body.location ? body.location : {};
  return JSON.stringify([loc.path, loc.line, loc.rrTicks, loc.key]);
}

function client(label, clientId, launch) {
  const c = {
    label, clientId, disconnected: [], replayIds: [], positions: [],
    activates: [], dapEvents: 0, syncMessages: 0, errors: [], seq: 0,
  };
  const socket = io('http://127.0.0.1:' + port, {
    transports: ['websocket'], forceNew: true, reconnection: false, timeout: 20000,
    query: { ct_session: secret, ct_client: clientId },
    extraHeaders: { Origin: pageOrigin },
  });
  c.socket = socket;
  c.send = (command, args) => {
    socket.emit('CODETRACER::dap-raw-message', {
      seq: c.seq++, type: 'request', command, arguments: args || {}, sessionId: 0,
    });
  };
  socket.on('connect_error', (e) => c.errors.push('connect_error: ' + (e && e.message)));
  socket.on('connect', () => {
    socket.emit('CODETRACER::session-sync', JSON.stringify({ type: 'hello' }));
  });
  socket.on('CODETRACER::started', () => socket.emit('CODETRACER::started', {}));
  socket.on('CODETRACER::connection-disconnected', (p) => {
    try { c.disconnected.push(JSON.parse(p).reason); } catch (e) { c.disconnected.push(String(p)); }
  });
  socket.on('CODETRACER::dap-replay-selected', (p) => {
    const v = JSON.parse(p);
    c.replayIds.push(v.replayId);
    if (launch) {
      c.send('initialize', { clientName: 'codetracer' });
      c.send('configurationDone', {});
      c.send('launch', { traceFolder: v.trace.outputFolder });
    }
  });
  socket.on('CODETRACER::dap-receive-event', (p) => {
    const v = JSON.parse(p);
    c.dapEvents += 1;
    if (v.event === 'ct/complete-move') c.positions.push(position(v.body));
  });
  socket.on('CODETRACER::session-sync', (frame) => {
    c.syncMessages += 1;
    try {
      const m = JSON.parse(frame);
      if (m.type === 'activate') c.activates.push(m.session);
    } catch (e) { /* not ours */ }
  });
  return c;
}

async function step(c) {
  const before = c.positions.length;
  c.send('next', { threadId: 1 });
  return await until(() => c.positions.length > before, WAIT_MS);
}

function report(c) {
  return {
    disconnected: c.disconnected, replayIds: c.replayIds, positions: c.positions,
    activates: c.activates, dapEvents: c.dapEvents, syncMessages: c.syncMessages,
    errors: c.errors,
  };
}

(async () => {
  const out = { phases: {} };
  // 1. A, then B.
  const a = client('A', 'client-a', true);
  out.phases.aStopped = await until(() => a.positions.length >= 1 && a.activates.length >= 1, WAIT_MS);
  const b = client('B', 'client-b', true);
  out.phases.bStopped = await until(() => b.positions.length >= 1 && b.activates.length >= 1, WAIT_MS);
  await delay(1500);
  out.aEntry = a.positions[a.positions.length - 1];
  out.bEntry = b.positions[b.positions.length - 1];

  // 2. A steps twice; B must hear nothing of it.
  const bEvents = b.dapEvents, bSync = b.syncMessages;
  out.phases.aStep1 = await step(a);
  out.aStep1 = a.positions[a.positions.length - 1];
  out.phases.aStep2 = await step(a);
  out.aStep2 = a.positions[a.positions.length - 1];
  await delay(2000);
  out.bEventsDuringA = b.dapEvents - bEvents;
  out.bSyncDuringA = b.syncMessages - bSync;

  // 3. B steps once, from where its own replay is.
  out.phases.bStep1 = await step(b);
  out.bStep1 = b.positions[b.positions.length - 1];

  // 4. A reloads: the same client id on a new connection.
  const aBefore = report(a);
  a.socket.close();
  await delay(1000);
  const a2 = client('A2', 'client-a', false);
  out.phases.aResumed = await until(
    () => a2.replayIds.length >= 1 && a2.positions.length >= 1 && a2.activates.length >= 1, WAIT_MS);
  await delay(1000);

  // 5. A new client.
  const c = client('C', 'client-c', true);
  out.phases.cStarted = await until(
    () => c.replayIds.length >= 1 && c.positions.length >= 1 && c.activates.length >= 1, WAIT_MS);
  await delay(1000);

  // 6. A cannot stop B's replay.
  a2.socket.emit('CODETRACER::close-replay-session', { replayId: b.replayIds[b.replayIds.length - 1] });
  await delay(1000);
  out.phases.bStepsAfterForeignStop = await step(b);

  // 7. C stops its own replay; B, the replay served last, still steps.
  c.socket.emit('CODETRACER::close-replay-session', { replayId: c.replayIds[c.replayIds.length - 1] });
  await delay(1000);
  out.phases.bStepsAfterOwnStop = await step(b);

  out.a = aBefore; out.b = report(b); out.a2 = report(a2); out.c = report(c);
  for (const s of [b, a2, c]) s.socket.close();
  process.stdout.write(JSON.stringify(out) + '\n');
  process.exit(0);
})().catch((e) => {
  process.stdout.write(JSON.stringify({ fatal: String(e && e.stack || e) }) + '\n');
  process.exit(0);
});
"""

var
  scratch = ""
  host: Host
  started = false
  seen: JsonNode

proc strs(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray: return @[]
  for item in node: result.add (if item.kind == JString: item.getStr else: $item)

proc ints(node: JsonNode): seq[int] =
  if node.isNil or node.kind != JArray: return @[]
  for item in node: result.add item.getInt(-1)

proc first[T](s: seq[T]; default: T): T =
  if s.len > 0: s[0] else: default

proc last[T](s: seq[T]; default: T): T =
  if s.len > 0: s[^1] else: default

suite "ct host gives each client its own session":

  test "the prerequisites are present":
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & "; build it (`just build-once`) or " &
                 "set CODETRACER_CT_BIN")
    ck fileExists(ctBinary)
    ck findExe("node").len > 0
    ck dirExists(nodeModules / "socket.io-client")

  test "three clients play their pages against one ct host":
    scratch = createHostScratch("ct-host-isolation-")
    host = startHost(scratch)
    started = host.secret.len > 0
    require started
    let script = scratch / "clients.js"
    writeFile(script, ScenarioScript)
    let (output, _) = runNodeScript(host, script)
    for line in output.splitLines():
      if line.startsWith("{"):
        seen = parseJson(line)
    if seen.isNil:
      checkpoint("the client script printed no result:\n" & output)
      checkpoint("ct host log:\n" & readLog(host.logPath))
    ck not seen.isNil and not seen.hasKey("fatal")
    if not seen.isNil:
      echo "result: ", $seen

  test "a second client does not take over the first, and each has its own replay and session":
    require not seen.isNil and not seen.hasKey("fatal")
    let a = seen["a"]
    let b = seen["b"]
    ck seen["phases"]["aStopped"].getBool
    ck seen["phases"]["bStopped"].getBool
    # The issue's symptom, verbatim: B's arrival superseded A.
    ck a["disconnected"].strs.len == 0
    ck b["disconnected"].strs.len == 0
    let aReplay = a["replayIds"].ints.first(-1)
    let bReplay = b["replayIds"].ints.first(-1)
    ck aReplay >= 0 and bReplay >= 0 and aReplay != bReplay
    let aSession = a["activates"].strs.first("")
    let bSession = b["activates"].strs.first("")
    ck aSession.len > 0 and bSession.len > 0 and aSession != bSession

  test "a move by one client is not observed by the other":
    require not seen.isNil and not seen.hasKey("fatal")
    ck seen["phases"]["aStep1"].getBool
    ck seen["phases"]["aStep2"].getBool
    let entry = seen{"aEntry"}.getStr
    let one = seen{"aStep1"}.getStr
    let two = seen{"aStep2"}.getStr
    ck entry != one and one != two and entry != two
    ck seen["bEventsDuringA"].getInt(-1) == 0
    ck seen["bSyncDuringA"].getInt(-1) == 0
    # B's replay stayed at its own entry: one step from there lands where A's
    # first step did, not one step past A.
    ck seen["phases"]["bStep1"].getBool
    ck seen{"bEntry"}.getStr == entry
    ck seen{"bStep1"}.getStr == one

  test "a client that reconnects with its id resumes its own session":
    require not seen.isNil and not seen.hasKey("fatal")
    let a = seen["a"]
    let a2 = seen["a2"]
    ck seen["phases"]["aResumed"].getBool
    ck a2["replayIds"].ints == @[a["replayIds"].ints.first(-1)]
    ck a2["positions"].strs.last("") == seen{"aStep2"}.getStr
    ck a2["activates"].strs.first("") == a["activates"].strs.first("")
    ck seen["b"]["disconnected"].strs.len == 0

  test "a new client gets a replay of its own and does not see another's position":
    require not seen.isNil and not seen.hasKey("fatal")
    let c = seen["c"]
    ck seen["phases"]["cStarted"].getBool
    let cReplay = c["replayIds"].ints.first(-1)
    ck cReplay >= 0 and cReplay notin [seen["a"]["replayIds"].ints.first(-1),
                                       seen["b"]["replayIds"].ints.first(-1)]
    ck seen{"aStep2"}.getStr notin c["positions"].strs
    ck c["positions"].strs.first("") == seen{"aEntry"}.getStr

  test "a client stops only its own replay, and stopping it leaves the others' working":
    require not seen.isNil and not seen.hasKey("fatal")
    ck seen["phases"]["bStepsAfterForeignStop"].getBool
    ck seen["phases"]["bStepsAfterOwnStop"].getBool

  if started:
    stopHost(host)
  if scratch.len > 0:
    removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
