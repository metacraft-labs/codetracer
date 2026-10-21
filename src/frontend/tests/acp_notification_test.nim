## The transport double rejects deterministically: a real agent exit is racy
## and requires an installed agent/account. The window double records IPC
## without Electron/display. The production handler, errorPrint and Node's
## promise scheduling are unchanged. Include keeps private session state private.
## An active session receives a permission-like tool call. Assert the exact
## outgoing notification (positive control), no unhandled rejection and one
## errorPrint diagnostic when its promise rejects on a later event-loop turn.
## Then verify successful sends, synchronous throws, a chunk arriving while a
## send is pending, fallback option selection and an empty option list. Every
## assertion failure propagates to Node's exit status; no test arm skips.
include ../index/ipc_subsystems/acp_ipc

{.emit: """
const assert = require('node:assert/strict');
const notificationCalls = [], forwarded = [], diagnosticLines = [], unhandled = [];
const originalLog = console.log;
console.log = (...args) => { diagnosticLines.push(args.join('')); originalLog(...args); };
process.on('unhandledRejection', error => unhandled.push(error));
let notificationFailure = true;
let synchronousFailure = false;
let deferredNotification = false;
let completeNotification;
""".}

proc fakeWindow(): JsObject {.importjs: "({webContents: {send: (...args) => forwarded.push(args)}})".}
proc fakeConnection(): ClientSideConnection {.importjs: """
({extNotification: (method, params) => {
  notificationCalls.push({method, params});
  if (synchronousFailure) throw new Error('synchronous transport failure');
  if (deferredNotification) return new Promise(resolve => { completeNotification = resolve; });
  return new Promise((resolve, reject) => setImmediate(() => {
    if (notificationFailure) reject(new Error('notification transport closed'));
    else resolve();
  }));
}})
""".}
proc drainEvents(): Future[void] {.importjs: "new Promise(resolve => setImmediate(() => setImmediate(resolve)))".}
proc invokeUpdate(params: JsObject): Future[void] =
  jsAsFunction[proc(params: JsObject): Future[void]](handleSessionUpdate)(params)

proc run() {.async.} =
  mainWindow = fakeWindow()
  acpClient = fakeConnection()
  clientSessionIdsByAcp[cstring"agent-session"] = cstring"client-session"
  saveSessionState(cstring"agent-session", SessionState(
    activePrompt: true, currentMessageId: cstring"message-1"))
  let update = js{
    "sessionId": cstring"agent-session",
    "update": js{
      "sessionUpdate": cstring"tool_call",
      "toolCallId": cstring"call-1",
      "title": cstring"Read file",
      "options": @[js{"kind": cstring"allow_once", "optionId": cstring"once"},
                   js{"kind": cstring"allow_always", "optionId": cstring"always"}]
    }
  }
  await invokeUpdate(update)
  await drainEvents()
  {.emit: """
  assert.equal(notificationCalls.length, 1, 'positive control: notification was attempted');
  assert.deepEqual(notificationCalls[0], {method: 'tool_permission', params: {
    sessionId: 'agent-session', toolCallId: 'call-1',
    outcome: {outcome: 'selected', optionId: 'always'}
  }});
  assert.equal(unhandled.length, 0, 'notification rejection must have a handler');
  assert.equal(diagnosticLines.filter(line => line.includes('ERROR [ct]') &&
    line.includes('auto-allow tool permission failed: notification transport closed')).length, 1,
    'failed notification must be logged once through errorPrint');
  notificationFailure = false;
  """.}
  await invokeUpdate(update)
  await drainEvents()
  doAssert sessionsById[cstring"agent-session"].activePrompt
  doAssert sessionsById[cstring"agent-session"].collectedUpdates.len == 2
  {.emit: """
  assert.equal(notificationCalls.length, 2, 'the next notification must still be sent');
  assert.equal(forwarded.filter(item => item[0] === 'CODETRACER::acp-tool-call').length, 2);
  assert.equal(unhandled.length, 0);
  assert.equal(diagnosticLines.filter(line => line.includes('ERROR [ct]')).length, 1,
    'successful notification must not log another failure');
  synchronousFailure = true;
  """.}
  await invokeUpdate(update)
  await drainEvents()
  {.emit: """
  assert.equal(unhandled.length, 0);
  assert.equal(diagnosticLines.filter(line => line.includes('auto-allow tool permission failed: synchronous transport failure')).length, 1);
  synchronousFailure = false;
  deferredNotification = true;
  """.}
  let pendingUpdate = invokeUpdate(update)
  await invokeUpdate(js{
    "sessionId": cstring"agent-session",
    "update": js{"sessionUpdate": cstring"agent_message_chunk",
                 "content": js{"text": cstring"interleaved message"}}
  })
  {.emit: "completeNotification(); deferredNotification = false;".}
  await pendingUpdate
  await drainEvents()
  doAssert sessionsById[cstring"agent-session"].aggregatedContent == cstring"interleaved message"
  doAssert sessionsById[cstring"agent-session"].collectedUpdates.len == 5
  update[cstring"update"][cstring"options"] = toJs(@[
    js{"kind": cstring"allow_once", "optionId": cstring"fallback"}])
  await invokeUpdate(update)
  await drainEvents()
  update[cstring"update"][cstring"options"] = toJs(newSeq[JsObject]())
  await invokeUpdate(update)
  await drainEvents()
  {.emit: """
  assert.equal(notificationCalls.length, 5, 'empty options must not send a notification');
  assert.equal(notificationCalls[4].params.outcome.optionId, 'fallback');
  assert.equal(unhandled.length, 0);
  console.log('PASS: ACP notification rejection, synchronous errors, overlapping updates and option selection');
  """.}

proc checkRun(future: Future[void]) {.
  importjs: "(#).catch(error => { console.error(error); process.exitCode = 1; })".}
checkRun(run())
