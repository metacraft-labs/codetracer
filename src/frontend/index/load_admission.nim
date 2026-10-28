## The index's trace, prefetched trace and replay selection are shared load
## state. Admit one complete IPC operation, not just its synchronous prefix:
## an await must not let another tab replace the first operation's state.
## Nested load steps are ordinary calls inside that operation, so they neither
## reacquire admission nor change its destination.
import std/[asyncjs, jsffi]
import ./[tab_answers, electron_vars, served_client]
import ../lib/jslib

var loading = false
var loadingClientKey: cstring

proc beginLoad*(request: JsObject): bool =
  ## Acquire shared load state before its first mutation. Startup uses the
  ## same admission as registered IPC handlers.
  if loading:
    return false
  loading = true
  loadingClientKey = currentClientKey()
  startLoadFor(request)
  true

proc finishLoad*() =
  ## Paired with a successful beginLoad, in a finally/defer arm.
  loading = false
  loadingClientKey = cstring""

proc isLoadOperation*(channel: string): bool =
  ## Every IPC entrypoint that can mutate the shared initialization state.
  ## Keep the admission at registration: record/dialog handlers call other
  ## load handlers internally and already own it for their entire lifetime.
  channel in [
    "CODETRACER::load-recent-trace", "CODETRACER::open-trace-in-tab",
    "CODETRACER::load-recent-transaction", "CODETRACER::load-trace-by-record-process-id",
    "CODETRACER::open-local-trace", "CODETRACER::load-trace-file",
    "CODETRACER::open-folder-dialog", "CODETRACER::load-recent-folder",
    "CODETRACER::open-trace-dialog", "CODETRACER::record-from-launch",
    "CODETRACER::record-with-launch-config", "CODETRACER::init-edit-mode",
    "CODETRACER::new-file", "CODETRACER::new-record", "CODETRACER::run-test",
    "CODETRACER::download-trace-file", "CODETRACER::restart-subsystem",
    "CODETRACER::load-codetracer-shell"]

proc sameTab(a, b: JsObject): bool {.importjs: "(# === #)".}

proc refuseLoad(channel: string; request: JsObject) =
  let reason = cstring"Another trace or session is loading. Wait for it to finish and try again."
  let preserveLoading = loadingClientKey == currentClientKey() and
    sameTab(askingTab(request), loadTab)
  # Answer from the refused request, never from loadTab: it still belongs
  # to the operation that was admitted. A same-tab second click must not
  # tear down that operation's spinner or recording latch.
  mainWindow.webContents.send "CODETRACER::trace-load-error",
    answerFor(request, js{error: reason, preserveLoading: preserveLoading})
  if channel == "CODETRACER::run-test" and not preserveLoading:
    mainWindow.webContents.send "CODETRACER::test-run-settled",
      answerFor(request, js{recordingId: cstring"", recordedAt: cstring"", errorMessage: reason})
  if not preserveLoading:
    if channel in ["CODETRACER::new-record", "CODETRACER::record-with-launch-config"]:
      mainWindow.webContents.send "CODETRACER::failed-record",
        answerFor(request, js{errorMessage: reason})
    elif channel == "CODETRACER::download-trace-file":
      mainWindow.webContents.send "CODETRACER::failed-download",
        answerFor(request, js{errorMessage: reason})

proc guardLoadHandler*(channel: string; handler: JsObject): JsObject =
  ## Used by the real IPC registration macro on both desktop and server.
  ## Non-load channels (including started and stop-recording-process) remain
  ## usable while the operation waits for them.
  if not isLoadOperation(channel):
    return handler
  let invoke = jsAsFunction[proc(sender, request: JsObject): Future[void]](handler)
  let guarded = proc(sender, request: JsObject): Future[void] {.async.} =
    if not beginLoad(request):
      refuseLoad(channel, request)
      return
    try:
      await invoke(sender, request)
    finally:
      finishLoad()
  guarded.toJs
