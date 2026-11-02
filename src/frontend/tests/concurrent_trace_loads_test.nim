## Exercises the real IPC registration macro and load-tab stamping. The load
## handler is a controlled stand-in: a promise barrier makes the overlap
## deterministic without starting a recorder or depending on filesystem timing.
## The window send sink records the actual busy refusal delivered by the main
## process. No routing or exclusion logic is replaced.
import std/[asyncjs, jsffi, tables]
import ../index/[base_handlers, tab_answers, electron_vars]
import ../index/served_client
import ../lib/jslib

type TestIpc = object
var handlers = initTable[string, JsObject]()
proc on(ipc: TestIpc; name: cstring; handler: JsObject) =
  handlers[$name] = handler
var ipc: TestIpc
var release: proc()
var sent: seq[JsObject] = @[]
var runs: seq[int] = @[]
var failNext = false
var checks = 0
const ExpectedAssertions = 19
template ck(condition: untyped; message: string = "") =
  inc checks
  doAssert condition, message

proc onLoadRecentTrace(sender, request: JsObject): Future[void] {.async.} =
  startLoadFor(request)
  runs.add request["tab"].to(int)
  if request["tab"].to(int) == 1:
    await newPromise(proc(resolve: proc()) = release = resolve)
  if failNext:
    failNext = false
    raise newException(ValueError, "load failed")
  sent.add forLoadTab(js{kind: cstring"trace-loaded"})

proc onRunTest(sender, request: JsObject): Future[void] =
  onLoadRecentTrace(sender, request)

proc invoke(tab: int; channel = "CODETRACER::load-recent-trace"): Future[void] =
  let handler = jsAsFunction[proc(sender, request: JsObject): Future[void]](
    handlers[channel])
  handler(jsUndefined, js{tab: tab})

proc main(): Future[void] {.async.} =
  mainWindow = js{webContents: js{}}
  mainWindow.webContents["send"] = proc(channel: cstring; payload: JsObject) =
    payload["kind"] = channel
    sent.add payload
  indexIpcHandlers("CODETRACER::"):
    "load-recent-trace"
    "run-test"
  let first = invoke(1, "CODETRACER::run-test")
  await invoke(2)
  ck forLoadTab(js{})["tab"].to(int) == 1,
    "B must not overwrite A's load-tab marker while A is suspended"
  ck runs == @[1], "the second load must not enter shared load state"
  ck sent.len == 1, "the second load must receive a refusal"
  ck sent[0]["kind"].to(cstring) == cstring"CODETRACER::trace-load-error"
  ck sent[0]["tab"].to(int) == 2
  ck ($sent[0]["error"].to(cstring)).len > 0
  ck not sent[0]["preserveLoading"].to(bool)
  await invoke(1)
  ck runs == @[1], "a repeated request in the same tab is also refused"
  ck sent[^1]["preserveLoading"].to(bool),
    "a same-tab refusal must preserve the original load's spinner"
  let beforeRunRefusals = sent.len
  await invoke(1, "CODETRACER::run-test")
  ck sent.len == beforeRunRefusals + 1,
    "a same-tab refused test must not settle the original test's latch"
  await invoke(2, "CODETRACER::run-test")
  ck sent.len == beforeRunRefusals + 3,
    "a refused test in another tab gets an error and terminal settlement"
  ck sent[^1]["kind"].to(cstring) == cstring"CODETRACER::test-run-settled"
  release()
  await first
  ck sent[^1]["tab"].to(int) == 1, "A's delayed answer must still belong to A"
  await invoke(2)
  ck runs == @[1, 2], "retry must work after the first load completes"
  failNext = true
  var rejected = false
  try:
    await invoke(3)
  except:
    rejected = true
  ck rejected, "load exceptions must remain visible to the caller"
  await invoke(4)
  ck runs == @[1, 2, 3, 4], "a rejected load must release the guard"
  ck sent[^1]["tab"].to(int) == 4
  # Hosted pages both start their own tab numbering at zero (and may choose
  # any equal id): ownership includes the served client, not just that id.
  var hostedFirst, hostedSecond: Future[void]
  runAsClient(js{}, proc() = hostedFirst = invoke(1))
  runAsClient(js{}, proc() = hostedSecond = invoke(1))
  await hostedSecond
  ck not sent[^1]["preserveLoading"].to(bool),
    "the same tab id in another hosted client is a different load owner"
  ck sent[^1]["tab"].to(int) == 1
  release()
  await hostedFirst
  doAssert checks == ExpectedAssertions
  echo "CHECKS: ", checks
  echo "  [OK] concurrent trace loads: refusal, original routing, retry and rejection release"

discard main()
