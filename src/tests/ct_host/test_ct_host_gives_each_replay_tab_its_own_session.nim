## test_ct_host_gives_each_replay_tab_its_own_session.nim
##
## One page of `ct host` holds a server session per replay tab
## (Shared-DOM-Front-Ends D2, owner decision 2026-10-30: "a webui instance
## should be able to work with multiple server sessions as the inner tab
## management of codetracer may be backed by separate sessions";
## `CLI/ct/host.md`, "Each of a client's replay tabs is a session of its own";
## `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rule 9).
##
## ## The defect this pins
##
## The server kept ONE replay and ONE session per client, and a page mirrored
## the server's session in its first tab only. A tab opened with "+" built a
## page-owned session, and the trace it loaded through the server replaced
## the client's one replay: the first tab's requests then ran on the new
## replay, every answer went back as the first tab's (the server stamped them
## all with tab 0), and nothing the server offers per session — relayed
## viewports, call-trace actions — reached the later tab.
##
## ## What runs
##
## The real `ct host --trace-path` on the materialized GDScript recording the
## admission suite uses (`ct_host_harness`): the real node index, the real
## Backend Manager and real `replay-server` processes. The page is
## socket.io's own client under node, speaking to the server exactly as the
## page does: the session secret, its client id (`ct_client`) and its document
## id (`ct_page`) in the handshake query, the page's `Origin`,
## `CODETRACER::started` answered; each tab's DAP handshake and steps as
## `CODETRACER::dap-raw-message` frames stamped with the tab's id
## (`sessionId`), as `dap.dispatchCtRequest` builds them; a "+" tab's trace
## opened with `CODETRACER::load-recent-trace` naming the tab, as the Welcome
## Screen sends it; each tab's mirror traffic on its own event
## (`CODETRACER::session-sync` for tab 0, `CODETRACER::session-sync/<tab>`
## otherwise), with the `hello`, `subscribe`, `viewport`/`set` and
## `calltrace` action frames `mirror_session` sends.
##
## No mocks: nothing in `ct host` is replaced. The node script plays the page
## because the property is about which server session each tab's traffic
## reaches, and a browser would add a renderer whose own state cannot tell us
## which session it was handed. The browser half (the page building one
## mirror per tab on its tab's event) is the same `sessionSyncEventFor` the
## server uses, in `ui_js.configureSessionMiddleware`.
##
## ## The arms
##
## 1. Tab 0 takes the client's startup replay. Tab 1's mirror says `hello`
##    BEFORE its tab has a session; tab 1 then opens the trace. Tab 2 opens it
##    and says `hello` AFTER. Each tab gets its own replay and is told to
##    follow its own server session, whichever order it came in.
##    Tab 2 begins as an edit session (a tab with no replay): its request to
##    the replay engine is dropped and it has no server session until it
##    opens the recording through the server's load path.
## 2. Tab 1 steps: only tab 1 is told of the move. Tab 2 steps twice.
## 3. A viewport relayed by tab 1 loads on tab 1's session only (only tab 1's
##    event carries batches); one relayed by tab 0 loads on tab 0's only.
## 4. A call-trace action relayed by tab 1 moves tab 1's replay, not another.
## 5. Tab 1 closes (`CODETRACER::close-replay-session` with its replay): its
##    session is closed — its `hello` is no longer answered, its requests are
##    dropped — and tabs 0 and 2 still step.
## 6. The same page reconnects (same `ct_page`, a network blip): tab 2's
##    session is kept, and steps.
## 7. The page reloads (another `ct_page`): tab 2's session is released, tab
##    0's is resumed, and the position replayed to the reloaded page is tab
##    0's, not tab 2's.
##
## Lane: `ct-host-admission` (`just test-ct-host-admission`).

import std/[json, os, strutils, unittest]

import ct_host_harness

# One line: `ci/lib/run-nim-test-lane.sh` reads this spelling as the runtime
# assertion count.
const ExpectedAssertions = 44

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ScenarioScript = """
'use strict';
// Plays one page with three replay tabs against one `ct host` and prints
// what each tab was told, as one JSON line.
const io = require('socket.io-client');
const port = process.env.CT_TEST_SOCKET_PORT;
const pageOrigin = process.env.CT_TEST_PAGE_ORIGIN;
const secret = process.env.CT_TEST_SECRET;
const WAIT_MS = 90000;
const QUIET_MS = 3000;

const delay = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, ms) {
  const deadline = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > deadline) return false;
    await delay(50);
  }
  return true;
}
const syncEvent = (tab) => tab === 0 ? 'CODETRACER::session-sync' : 'CODETRACER::session-sync/' + tab;

function position(body) {
  const loc = body && body.location ? body.location : {};
  return JSON.stringify([loc.path, loc.line, loc.rrTicks, loc.key]);
}

function newTab() {
  return { replayIds: [], positions: [], activates: [], batches: 0,
           responses: 0, recordingId: '', loadErrors: [] };
}

// A page: one socket, the tabs it has (by tab id).
function page(clientId, pageId, tabIds, launchOnSelection) {
  const p = { tabs: {}, seq: 0, errors: [], disconnected: [] };
  for (const t of tabIds) p.tabs[t] = newTab();
  const socket = io('http://127.0.0.1:' + port, {
    transports: ['websocket'], forceNew: true, reconnection: false, timeout: 20000,
    query: { ct_session: secret, ct_client: clientId, ct_page: pageId },
    extraHeaders: { Origin: pageOrigin },
  });
  p.socket = socket;
  p.send = (tab, command, args) => {
    socket.emit('CODETRACER::dap-raw-message', {
      seq: p.seq++, type: 'request', command, arguments: args || {}, sessionId: tab,
    });
  };
  p.sync = (tab, msg) => socket.emit(syncEvent(tab), JSON.stringify(msg));
  p.hello = (tab) => p.sync(tab, { type: 'hello' });
  socket.on('connect_error', (e) => p.errors.push('connect_error: ' + (e && e.message)));
  socket.on('CODETRACER::started', () => socket.emit('CODETRACER::started', {}));
  socket.on('CODETRACER::connection-disconnected', (x) => p.disconnected.push(String(x)));
  socket.on('CODETRACER::dap-replay-selected', (x) => {
    const v = JSON.parse(x);
    const tab = typeof v.tab === 'number' ? v.tab : 0;
    const t = p.tabs[tab];
    if (!t) { p.errors.push('a selection for an unknown tab ' + tab); return; }
    t.replayIds.push(v.replayId);
    t.recordingId = (v.trace && v.trace.recordingId) || '';
    if (launchOnSelection) {
      p.send(tab, 'initialize', { clientName: 'codetracer' });
      p.send(tab, 'configurationDone', {});
      p.send(tab, 'launch', { traceFolder: v.trace.outputFolder });
    }
  });
  socket.on('CODETRACER::trace-load-error', (x) => {
    let v = {};
    try { v = JSON.parse(x); } catch (e) { /* not ours */ }
    const t = p.tabs[typeof v.tab === 'number' ? v.tab : 0];
    if (t) t.loadErrors.push(String(v.error || x));
  });
  socket.on('CODETRACER::dap-receive-event', (x) => {
    const v = JSON.parse(x);
    const t = p.tabs[v.sessionId];
    if (!t) return;
    if (v.event === 'ct/complete-move') t.positions.push(position(v.body));
  });
  socket.on('CODETRACER::dap-receive-response', (x) => {
    const v = JSON.parse(x);
    const t = p.tabs[v.sessionId];
    if (t) t.responses += 1;
  });
  for (const tab of tabIds) {
    socket.on(syncEvent(tab), (frame) => {
      let m;
      try { m = JSON.parse(frame); } catch (e) { return; }
      const t = p.tabs[tab];
      if (m.type === 'activate') {
        t.activates.push(m.session);
        // As `mirror_session.switchTo` does: follow it, which the server
        // answers with a snapshot and then the session's batches.
        p.sync(tab, { type: 'subscribe', session: m.session });
      }
      if (m.type === 'signal-batch' || m.type === 'signal-snapshot') t.batches += 1;
    });
  }
  return p;
}

const last = (xs) => xs[xs.length - 1];

async function step(p, tab) {
  const t = p.tabs[tab];
  const before = t.positions.length;
  p.send(tab, 'next', { threadId: 1 });
  return await until(() => t.positions.length > before, WAIT_MS);
}

// How many moves and batches each tab is told of while `act` runs and the
// server settles.
async function observe(p, act) {
  const before = {};
  for (const k of Object.keys(p.tabs)) {
    before[k] = { moves: p.tabs[k].positions.length, batches: p.tabs[k].batches,
                  responses: p.tabs[k].responses };
  }
  await act();
  await delay(QUIET_MS);
  const seen = {};
  for (const k of Object.keys(p.tabs)) {
    seen[k] = { moves: p.tabs[k].positions.length - before[k].moves,
                batches: p.tabs[k].batches - before[k].batches,
                responses: p.tabs[k].responses - before[k].responses };
  }
  return seen;
}

function viewport(p, tab) {
  p.sync(tab, { type: 'action', session: last(p.tabs[tab].activates), vm: 'viewport',
                action: 'set', args: { pane: 'calltrace', rows: 30, depth: 8, firstRow: 0 } });
}

// Open the recording in `tab` as the Welcome Screen does. The server admits
// one load at a time and refuses another while one runs ("Another trace or
// session is loading", `index/load_admission`), which the startup's own load
// can still be when the page is first usable; a refused load is asked again,
// as a user would.
async function openTab(p, tab, recordingId) {
  const t = p.tabs[tab];
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    const errors = t.loadErrors.length;
    p.socket.emit('CODETRACER::load-recent-trace', { traceId: recordingId, tab });
    await until(() => t.positions.length >= 1 || t.loadErrors.length > errors,
                Math.max(0, deadline - Date.now()));
    if (t.positions.length >= 1) return true;
    await delay(1000);
  }
  return false;
}

(async () => {
  const out = { phases: {} };
  // 1. Tab 0, then tab 1 (mirror first), then tab 2 (mirror after).
  const a = page('client-tabs', 'doc-1', [0, 1, 2], true);
  out.phases.tab0Stopped = await until(
    () => a.tabs[0].positions.length >= 1 && a.tabs[0].activates.length >= 1, WAIT_MS);
  a.hello(0);
  const recordingId = a.tabs[0].recordingId;
  out.recordingId = recordingId;
  a.hello(1);
  await delay(500);
  out.tab1ActivatesBeforeItsSession = a.tabs[1].activates.length;
  out.phases.tab1Stopped = await openTab(a, 1, recordingId);
  out.phases.tab1Activated = await until(() => a.tabs[1].activates.length >= 1, WAIT_MS);
  // Tab 2 begins as an edit session: a tab with no replay, whose ViewModels
  // the page owns. What it sends the replay engine is dropped (no tab 2
  // replay exists yet), and the server has no session for it.
  out.tab2BeforeOpen = await observe(a, async () => {
    a.send(2, 'initialize', { clientName: 'codetracer' });
  });
  out.tab2ActivatesBeforeOpen = a.tabs[2].activates.length;
  // It opens a recording through the server's load path; the page then
  // mirrors the session the server opened for it (`adoptServerSession`),
  // whose first message is its `hello`.
  out.phases.tab2Stopped = await openTab(a, 2, recordingId);
  await delay(1500);
  a.hello(2);
  out.phases.tab2Activated = await until(() => a.tabs[2].activates.length >= 1, WAIT_MS);
  await delay(QUIET_MS);
  out.entry = last(a.tabs[0].positions);

  // 2. Tab 1 steps once; then tab 2 twice.
  out.tab1Step = await observe(a, async () => { out.phases.tab1Step = await step(a, 1); });
  out.tab1StepPosition = last(a.tabs[1].positions);
  out.phases.tab2Step1 = await step(a, 2);
  out.phases.tab2Step2 = await step(a, 2);
  out.tab2Position = last(a.tabs[2].positions);
  await delay(QUIET_MS);

  // 3. Viewports relayed by tab 1, then by tab 0.
  out.tab1Viewport = await observe(a, async () => viewport(a, 1));
  out.tab0Viewport = await observe(a, async () => viewport(a, 0));

  // 4. A call-trace action relayed by tab 1.
  out.tab1Calltrace = await observe(a, async () => {
    a.sync(1, { type: 'action', session: last(a.tabs[1].activates), vm: 'calltrace',
                action: 'doubleClickEntry', args: { lineIndex: 0 } });
  });

  // 5. Tab 1 closes.
  const tab1Replay = last(a.tabs[1].replayIds);
  a.socket.emit('CODETRACER::close-replay-session', { replayId: tab1Replay });
  await delay(1500);
  const activatesBefore = a.tabs[1].activates.length;
  out.tab1AfterClose = await observe(a, async () => {
    a.hello(1);
    a.send(1, 'next', { threadId: 1 });
    viewport(a, 1);
  });
  out.tab1ActivatedAfterClose = a.tabs[1].activates.length - activatesBefore;
  out.phases.tab0StepsAfterClose = await step(a, 0);
  out.tab0Position = last(a.tabs[0].positions);
  out.phases.tab2StepsAfterClose = await step(a, 2);
  out.tab2Position = last(a.tabs[2].positions);
  out.a = a.tabs; out.aErrors = a.errors; out.aDisconnected = a.disconnected;
  a.socket.close();
  await delay(1000);

  // 6. The same page reconnects.
  const b = page('client-tabs', 'doc-1', [0, 2], false);
  out.phases.bConnected = await until(() => b.socket.connected, WAIT_MS);
  await delay(1500);
  b.hello(2);
  out.phases.bTab2Activated = await until(() => b.tabs[2].activates.length >= 1, WAIT_MS);
  out.bTab2Session = last(b.tabs[2].activates) || '';
  out.phases.bTab2Steps = await step(b, 2);
  out.tab2Position = last(b.tabs[2].positions);
  out.b = b.tabs;
  b.socket.close();
  await delay(1000);

  // 7. The page reloads.
  const c = page('client-tabs', 'doc-2', [0, 2], false);
  out.phases.cResumed = await until(
    () => c.tabs[0].replayIds.length >= 1 && c.tabs[0].positions.length >= 1, WAIT_MS);
  await delay(1500);
  c.hello(0);
  c.hello(2);
  out.phases.cTab0Activated = await until(() => c.tabs[0].activates.length >= 1, WAIT_MS);
  await delay(QUIET_MS);
  out.cTab2Activates = c.tabs[2].activates.length;
  out.cTab2Step = await observe(c, async () => c.send(2, 'next', { threadId: 1 }));
  out.phases.cTab0Steps = await step(c, 0);
  out.c = c.tabs;
  c.socket.close();
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
  hostLog = ""

proc strs(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray: return @[]
  for item in node: result.add (if item.kind == JString: item.getStr else: $item)

proc ints(node: JsonNode): seq[int] =
  if node.isNil or node.kind != JArray: return @[]
  for item in node: result.add item.getInt(-1)

proc last[T](s: seq[T]; default: T): T =
  if s.len > 0: s[^1] else: default

proc tab(node: JsonNode; id: int): JsonNode =
  node{$id}

proc counts(node: JsonNode; id: int; what: string): int =
  node{$id}{what}.getInt(-1)

suite "ct host gives each replay tab of a page its own session":

  test "the prerequisites are present":
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & "; build it (`just build-once`) or " &
                 "set CODETRACER_CT_BIN")
    ck fileExists(ctBinary)
    ck findExe("node").len > 0
    ck dirExists(nodeModules / "socket.io-client")

  test "one page plays three replay tabs against one ct host":
    scratch = createHostScratch("ct-host-tabs-")
    host = startHost(scratch)
    started = host.secret.len > 0
    require started
    let script = scratch / "page.js"
    writeFile(script, ScenarioScript)
    let (output, _) = runNodeScript(host, script)
    for line in output.splitLines():
      if line.startsWith("{"):
        seen = parseJson(line)
    hostLog = readLog(host.logPath)
    if seen.isNil or seen.hasKey("fatal"):
      checkpoint("the page script printed:\n" & output)
      checkpoint("ct host log:\n" & hostLog)
    ck not seen.isNil and not seen.hasKey("fatal")
    if not seen.isNil:
      echo "result: ", $seen

  test "each tab has its own replay and is told to follow its own session":
    require not seen.isNil and not seen.hasKey("fatal")
    let ph = seen["phases"]
    ck ph["tab0Stopped"].getBool
    ck ph["tab1Stopped"].getBool and ph["tab1Activated"].getBool
    ck ph["tab2Stopped"].getBool and ph["tab2Activated"].getBool
    # Tab 1's mirror said hello before its tab had a session: unanswered,
    # then told once the session existed.
    ck seen["tab1ActivatesBeforeItsSession"].getInt(-1) == 0
    let a = seen["a"]
    let r0 = a.tab(0)["replayIds"].ints.last(-1)
    let r1 = a.tab(1)["replayIds"].ints.last(-2)
    let r2 = a.tab(2)["replayIds"].ints.last(-3)
    ck r0 >= 0 and r1 >= 0 and r2 >= 0
    ck r0 != r1 and r1 != r2 and r0 != r2
    let s0 = a.tab(0)["activates"].strs.last("")
    let s1 = a.tab(1)["activates"].strs.last("")
    let s2 = a.tab(2)["activates"].strs.last("")
    ck s0.len > 0 and s1.len > 0 and s2.len > 0
    ck s0 != s1 and s1 != s2 and s0 != s2
    ck seen["aErrors"].strs.len == 0 and seen["aDisconnected"].strs.len == 0

  test "a tab that begins without a replay gets a server session when it opens a recording":
    require not seen.isNil and not seen.hasKey("fatal")
    ck seen["tab2BeforeOpen"].counts(2, "responses") == 0
    ck seen["tab2ActivatesBeforeOpen"].getInt(-1) == 0
    ck seen["phases"]["tab2Stopped"].getBool and seen["phases"]["tab2Activated"].getBool

  test "a tab's step is told to that tab alone":
    require not seen.isNil and not seen.hasKey("fatal")
    ck seen["phases"]["tab1Step"].getBool
    let o = seen["tab1Step"]
    ck o.counts(1, "moves") >= 1
    ck o.counts(0, "moves") == 0 and o.counts(2, "moves") == 0
    ck seen{"tab1StepPosition"}.getStr != seen{"entry"}.getStr
    ck seen["phases"]["tab2Step1"].getBool and seen["phases"]["tab2Step2"].getBool

  test "a relayed viewport loads on the relaying tab's session only":
    require not seen.isNil and not seen.hasKey("fatal")
    let one = seen["tab1Viewport"]
    ck one.counts(1, "batches") >= 1
    ck one.counts(0, "batches") == 0 and one.counts(2, "batches") == 0
    let zero = seen["tab0Viewport"]
    ck zero.counts(0, "batches") >= 1
    ck zero.counts(1, "batches") == 0 and zero.counts(2, "batches") == 0

  test "a relayed call-trace action moves the relaying tab's replay only":
    require not seen.isNil and not seen.hasKey("fatal")
    let o = seen["tab1Calltrace"]
    ck o.counts(1, "moves") >= 1
    ck o.counts(0, "moves") == 0 and o.counts(2, "moves") == 0

  test "closing a tab releases its session and leaves the others working":
    require not seen.isNil and not seen.hasKey("fatal")
    let o = seen["tab1AfterClose"]
    # No session answers its mirror, and its requests run on no replay.
    ck seen["tab1ActivatedAfterClose"].getInt(-1) == 0
    ck o.counts(1, "batches") == 0
    ck o.counts(1, "responses") == 0 and o.counts(1, "moves") == 0
    ck "closed the session of tab 1" in hostLog
    ck seen["phases"]["tab0StepsAfterClose"].getBool
    ck seen["phases"]["tab2StepsAfterClose"].getBool

  test "the same page reconnecting keeps every tab's session":
    require not seen.isNil and not seen.hasKey("fatal")
    ck seen["phases"]["bTab2Activated"].getBool
    ck seen{"bTab2Session"}.getStr == seen["a"].tab(2)["activates"].strs.last("")
    ck seen["phases"]["bTab2Steps"].getBool

  test "a reloaded page resumes its first tab and releases the others":
    require not seen.isNil and not seen.hasKey("fatal")
    let c = seen["c"]
    ck seen["phases"]["cResumed"].getBool and seen["phases"]["cTab0Activated"].getBool
    ck c.tab(0)["replayIds"].ints == @[seen["a"].tab(0)["replayIds"].ints.last(-1)]
    # The position replayed is tab 0's own, not tab 2's (which differs).
    ck seen{"tab0Position"}.getStr != seen{"tab2Position"}.getStr
    ck c.tab(0)["positions"].strs.len > 0 and
       c.tab(0)["positions"].strs[0] == seen{"tab0Position"}.getStr
    ck seen["cTab2Activates"].getInt(-1) == 0
    ck seen["cTab2Step"].counts(2, "responses") == 0
    ck "released the session of tab 2" in hostLog
    ck seen["phases"]["cTab0Steps"].getBool

  if started:
    stopHost(host)
  if scratch.len > 0:
    removeDir(scratch)

suite "assertion count":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
