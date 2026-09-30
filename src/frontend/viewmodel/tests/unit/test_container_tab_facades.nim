## The container deployment's tab half — §6.6 of
## `Architecture/UI-Bundle-And-Endpoints.md`, driven end to end with a
## recording transport and a recording bridge.
##
## ## The claim
##
## "A facade operation whose subject is the BROWSER TAB is answered by the
## client, not sent." Sixteen operations have that subject, and at codetracer
## `7739d096f` the client sent every one of them: the server refused them
## (correctly — a container process has no clipboard and no window), withdrew
## their capabilities from the profile it declares, and the user was left in a
## browser that has a clipboard, holding a platform that does not.
##
## So there are four things to assert and they fail independently:
##
##   1. **The sixteen do not reach the transport.** Asserted against a
##      RECORDING fake rather than against an outcome: a tab verb that was sent
##      and happened to be answered would satisfy an `ok` check while being
##      exactly the defect.
##   2. **The wire-owned ones still do.** The mirror direction, and the one a
##      "route everything locally" mistake would break.
##   3. **The profile is the union.** `welcome.profile` is what the SERVER
##      serves; the capabilities the tab supplies are not the server's to
##      declare or to withhold. A client that took the served profile as final
##      would present a platform with no clipboard.
##   4. **The external-URL allow-list travels with the FACADE.** A container
##      deployment's bridge is a third implementation, and the guard was
##      already missing from one of the two that existed —
##      `test_platform_web.nim`'s fake accepted `javascript:` straight through.
##
## ## What is real here and what is not
##
## Real: `host/container_platform.nim`'s composed constructor,
## `platform/browser_facades.nim`'s three builders and its verb table,
## `capabilities.nim`'s degradation machinery. The two stand-ins are the
## transport (a function call where the socket will be, as every suite in this
## family has it) and the SERVED profile: `index/facade_endpoint.servedProfile`
## is the Electron main process's module and cannot be imported into a
## ViewModel suite, so `servedStandIn` below reproduces its SHAPE — container
## capabilities minus everything the endpoint refuses. The real one is composed
## against the real client in `src/frontend/tests/facade_endpoint_verbs_test.nim`,
## which runs in the `main-process` lane; this suite is what runs on both
## backends.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[json, unittest]

import ../../platform/platform
import ../../platform/browser_facades
import ../../host/container_platform

const ExpectedAssertions = 142
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## Settle a facade future and hand back its outcome. The drain is here, once,
  ## and `settled` is checked, for the reason `test_platform_facade.nim` states
  ## at length: `async_compat` queues even a synchronously resolved future's
  ## callback on the JS target while running it inline on native, so a test
  ## that forgot it would pass on one backend and assert nothing on the other.
  var captured: PlatformOutcome[T]
  var settled = false
  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true
  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true
  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "a facade future never settled"
  captured

# ---------------------------------------------------------------------------
# The two recorders
# ---------------------------------------------------------------------------

type Recorder = ref object
  ## What each side was asked to do. The VERB LIST is the subject of half this
  ## file: an operation that reached the wire is in `verbs`, an operation the
  ## tab answered is in `tabOps`, and §6.6 is the statement that the sixteen
  ## are in the second list and in neither part of the first.
  verbs: seq[string]
  tabOps: seq[string]
  openedUrls: seq[string]

proc recordingTransport(rec: Recorder): RemoteTransport =
  proc(request: RemoteRequest): PlatformFuture[RemoteResponse] =
    rec.verbs.add request.verb
    # Payloads written as the §6.2 shapes the server sends, for the four verbs
    # this suite drives over the wire. Everything else answers null, which the
    # decoders refuse — deliberately: a tab verb that leaked onto the transport
    # would fail loudly here as well as showing up in `rec.verbs`.
    let answer =
      case request.verb
      of "fs.readText": remoteOk(%"fn main() {}")
      of "process.which": remoteOk(%"/usr/bin/nargo")
      of "vcs.repositoryRoot": remoteOk(%"/w")
      of "settings.get": remoteOk(%"dark")
      else: remoteOk(newJNull())
    # `newCompletedFuture`, not a bare promise: a plain `newPromise` would push
    # the value onto V8's microtask queue, which no headless test can drain,
    # and every assertion would quietly stop running on the JS backend while
    # still reporting green.
    newCompletedFuture(answer)

proc recordingTab(rec: Recorder): BrowserTabBridge =
  ## A tab that ANSWERS EVERYTHING, which is what makes the table check below
  ## an assertion about the facades rather than about a bridge's own refusals:
  ## the real `host/web_browser.nim` picker refuses by name because import is a
  ## store operation NS6 owns, and that would mask the question being asked.
  BrowserTabBridge(
    writeClipboardText: proc(text: string): auto =
      rec.tabOps.add "clipboard.writeText"
      resolvedOk(),
    writeClipboardHtml: proc(html, plainText: string): auto =
      rec.tabOps.add "clipboard.writeHtml"
      resolvedOk(),
    offerDownload: proc(suggestedName: string; content: seq[byte];
                        mimeType: string): auto =
      rec.tabOps.add "download.offer"
      resolvedOk(),
    pickFiles: proc(options: OpenDialogOptions): auto =
      rec.tabOps.add "download.openFileDialog"
      resolvedOk(@["imported.nr"]),
    pickDirectory: proc(options: OpenDialogOptions): auto =
      rec.tabOps.add "download.pickDirectory"
      resolvedOk("imported"),
    suggestSaveName: proc(options: SaveDialogOptions): auto =
      rec.tabOps.add "download.saveFileDialog"
      resolvedOk(options.suggestedName),
    openExternalUrl: proc(url: string): auto =
      rec.tabOps.add "shell.openExternalUrl"
      rec.openedUrls.add url
      resolvedOk(),
    setFullscreen: proc(fullscreen: bool): auto =
      rec.tabOps.add "shell.setFullscreen"
      resolvedOk(),
    windowState: proc(): auto =
      rec.tabOps.add "shell.windowState"
      resolvedOk(WindowState(maximized: false, minimized: false,
                             fullscreen: false, focused: true)),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard)

# ---------------------------------------------------------------------------
# The served profile, in the shape `facade_endpoint.servedProfile` produces
# ---------------------------------------------------------------------------

const ServedByTheEndpoint: CapabilitySet = {
  capFilesystemRead, capFilesystemWrite, capFilesystemTemp,
  capFilesystemArbitraryPaths,
  capProcessSpawn, capProcessArbitraryPrograms,
  capVcsRead, capVcsWrite, capVcsRemote,
  capSettingsRead, capSettingsWrite}
  ## What `ct host`'s table evidences and owes nothing against, at
  ## codetracer `246660766`. NOT a copy of that computation — a copy would
  ## drift silently — but its ANSWER, so that this suite's subject is the
  ## union rather than the server's arithmetic. The arithmetic itself is
  ## asserted where it lives, in `facade_endpoint_verbs_test.nim`, and the
  ## union is asserted against the real `servedProfile()` there too.

proc servedStandIn(): PlatformProfile =
  result = containerProfile
  result.displayName = "container (ct host endpoint, stand-in)"
  result.capabilities = ServedByTheEndpoint
  for capability in containerProfile.capabilities - ServedByTheEndpoint:
    result.degradations.add DegradationRule(capability: capability, behaviour:
      "the container endpoint does not answer this verb, so the capability " &
      "is withdrawn from what the server serves")

proc composedPlatform(rec: Recorder): Platform =
  newContainerPlatform(recordingTransport(rec), recordingTab(rec),
                       servedStandIn())

# ---------------------------------------------------------------------------

suite "the tab's capabilities are derived from the verbs the tab answers":

  test "the table is the sixteen §6.6 enumerates, and no more":
    ## Named by count per facade rather than by a total, because a total of
    ## sixteen reached by nine `shell.*` and seven `download.*` would pass a
    ## single `len` check while describing a different split.
    var clipboardVerbs = 0
    var downloadVerbs = 0
    var shellVerbs = 0
    for entry in browserTabVerbs:
      if entry.verb.len > 10 and entry.verb[0 .. 9] == "clipboard.":
        inc clipboardVerbs
      elif entry.verb.len > 9 and entry.verb[0 .. 8] == "download.":
        inc downloadVerbs
      elif entry.verb.len > 6 and entry.verb[0 .. 5] == "shell.":
        inc shellVerbs
    ck browserTabVerbs.len == 16
    ck clipboardVerbs == 3
    ck downloadVerbs == 5
    ck shellVerbs == 8

  test "the seven the tab genuinely supplies, named one by one":
    ## A set comparison passes when both sides are wrong in the same way, so
    ## the membership is named and the equality is asserted as well.
    let tab = browserTabCapabilities()
    ck capClipboardWrite in tab
    ck capDownloadFile in tab
    ck capOpenFileDialog in tab
    ck capSaveFileDialog in tab
    ck capDirectoryPicker in tab
    ck capOpenExternalUrl in tab
    ck capWindowFullscreen in tab
    ck tab == {capClipboardWrite, capDownloadFile, capOpenFileDialog,
               capSaveFileDialog, capDirectoryPicker, capOpenExternalUrl,
               capWindowFullscreen}

  test "a capability every one of whose verbs refuses is not claimed":
    ## `capWindowControls` is owed three times and evidenced never;
    ## `capClipboardRead`, `capRevealInFileManager` and `capMultiWindow` once
    ## each. A tab that claimed any of them would answer "may I" with yes and
    ## the call with `pkNotSupported`.
    let tab = browserTabCapabilities()
    ck capWindowControls notin tab
    ck capClipboardRead notin tab
    ck capRevealInFileManager notin tab
    ck capMultiWindow notin tab
    # And nothing the CONTAINER owns leaks in from this side.
    ck capFilesystemRead notin tab
    ck capProcessSpawn notin tab
    ck capShareLink notin tab

  test "the subtraction is real: one refused verb withdraws the capability":
    ## The table is a parameter for exactly this. `download.offerFile` and
    ## `download.offerText` both serve `capDownloadFile`; refusing one has to
    ## take the capability away, because "at least one answered verb" would
    ## advertise a download facade half of which refuses.
    var mutated = browserTabVerbs
    var found = false
    for i in 0 ..< mutated.len:
      if mutated[i].verb == "download.offerFile":
        ck capDownloadFile in mutated[i].serves
        mutated[i].answered = false
        found = true
    ck found
    ck capDownloadFile in browserTabCapabilities()
    ck capDownloadFile notin browserTabCapabilities(mutated)
    # And only that one goes.
    ck capOpenFileDialog in browserTabCapabilities(mutated)
    ck capOpenExternalUrl in browserTabCapabilities(mutated)

  test "the other direction: answering a refused verb adds its capability":
    var mutated = browserTabVerbs
    for i in 0 ..< mutated.len:
      if mutated[i].verb == "clipboard.readText":
        mutated[i].answered = true
    ck capClipboardRead notin browserTabCapabilities()
    ck capClipboardRead in browserTabCapabilities(mutated)

# ---------------------------------------------------------------------------

suite "the profile is the union — §6.3 as §6.6 refines it":

  test "the stand-in for the served profile is itself coherent":
    ## A positive control on the fixture. If `servedStandIn` did not satisfy
    ## the degradation table, every union assertion below would be measuring
    ## the fixture's bug rather than `withBrowserTab`.
    let served = servedStandIn()
    ck served.capabilities == ServedByTheEndpoint
    ck served.capabilities < containerProfile.capabilities
    ck undeclaredDegradations(served).len == 0
    ck staleDegradations(served).len == 0
    ck not served.has(capClipboardWrite)
    ck not served.has(capOpenExternalUrl)
    ck not served.has(capWindowFullscreen)

  test "the union is what the server serves plus what the tab supplies":
    let composed = servedStandIn().withBrowserTab()
    ck composed.capabilities ==
      ServedByTheEndpoint + browserTabCapabilities()
    # Named, because the equality above is also satisfied by a
    # `withBrowserTab` that returned the served set when the tab set is empty.
    ck composed.has(capClipboardWrite)
    ck composed.has(capDownloadFile)
    ck composed.has(capOpenFileDialog)
    ck composed.has(capSaveFileDialog)
    ck composed.has(capDirectoryPicker)
    ck composed.has(capOpenExternalUrl)
    ck composed.has(capWindowFullscreen)
    # The server's half is untouched.
    ck composed.has(capFilesystemRead)
    ck composed.has(capVcsRemote)
    ck composed.has(capSettingsWrite)
    # And neither side supplies these, so the union must not either.
    ck not composed.has(capClipboardRead)
    ck not composed.has(capRevealInFileManager)
    ck not composed.has(capWindowControls)
    ck not composed.has(capMultiWindow)
    ck not composed.has(capSecretStore)
    ck not composed.has(capShareLink)
    ck not composed.has(capFilesystemWatch)

  test "the degradation table survives the union in both directions":
    ## `capabilities.nim`: "a rule that survives the day its capability lands
    ## quietly misinforms". Seven capabilities land here, all at once, and the
    ## server wrote a withdrawal sentence for each of them.
    let composed = servedStandIn().withBrowserTab()
    ck undeclaredDegradations(composed).len == 0
    ck staleDegradations(composed).len == 0
    # Present now, so there is no sentence to show.
    ck degradedBehaviour(composed, capClipboardWrite) == ""
    ck degradedBehaviour(composed, capOpenExternalUrl) == ""
    ck degradedBehaviour(composed, capWindowFullscreen) == ""
    # Still absent, so the server's own sentence is kept VERBATIM rather than
    # regenerated — the union has no business rewording the server's reasons.
    ck degradedBehaviour(composed, capClipboardRead) ==
      degradedBehaviour(containerProfile, capClipboardRead)
    ck degradedBehaviour(composed, capWindowControls) ==
      degradedBehaviour(containerProfile, capWindowControls)
    ck degradedBehaviour(composed, capMultiWindow) ==
      degradedBehaviour(containerProfile, capMultiWindow)
    # And the ones the SERVER withdrew and the tab does not supply keep the
    # server's withdrawal sentence.
    ck degradedBehaviour(composed, capShareLink).len > 20
    ck degradedBehaviour(composed, capFilesystemWatch).len > 20
    for capability in composed.missing:
      ck degradedBehaviour(composed, capability).len > 20

  test "the platform the constructor builds carries the union, not the served set":
    let rec = Recorder()
    let composed = composedPlatform(rec)
    ck composed.profile.capabilities ==
      ServedByTheEndpoint + browserTabCapabilities()
    ck composed.can(capClipboardWrite)
    ck composed.can(capOpenExternalUrl)
    ck composed.can(capFilesystemRead)
    ck not composed.can(capWindowControls)
    ck not composed.can(capClipboardRead)
    ck composed.profile.kind == pkContainer
    # The three tab facades carry the same profile the platform does, so a
    # caller that reads `platform.clipboard.profile` is told the same thing.
    ck composed.clipboard.profile.capabilities == composed.profile.capabilities
    ck composed.download.profile.capabilities == composed.profile.capabilities
    ck composed.shell.profile.capabilities == composed.profile.capabilities

  test "the bridge-less constructor is unchanged, and still serves less":
    ## `test_container_platform_verbs.nim` and
    ## `test_platform_facade.nim` both build platforms this way, and a suite
    ## that wants every verb on the transport must keep being able to.
    let rec = Recorder()
    let wireOnly = newContainerPlatform(recordingTransport(rec),
                                        servedStandIn())
    ck wireOnly.profile.capabilities == ServedByTheEndpoint
    ck not wireOnly.can(capClipboardWrite)

# ---------------------------------------------------------------------------

suite "a verb the tab can answer, the tab answers":

  test "none of the sixteen reaches the transport":
    ## The load-bearing case, and it is asserted on the VERB LIST the
    ## transport saw rather than on the outcomes: a tab verb that was sent and
    ## happened to be answered satisfies an `ok` check and is exactly the
    ## defect §6.6 was opened on.
    let rec = Recorder()
    let p = composedPlatform(rec)

    discard awaitOutcome(p.clipboard.writeText("copied"))
    discard awaitOutcome(p.clipboard.readText())
    discard awaitOutcome(p.clipboard.writeHtml("<b>b</b>", "b"))

    discard awaitOutcome(p.download.offerFile("a.tar", @[byte 1], "application/x-tar"))
    discard awaitOutcome(p.download.offerText("a.txt", "text", "text/plain"))
    discard awaitOutcome(p.download.openFileDialog(OpenDialogOptions()))
    discard awaitOutcome(p.download.saveFileDialog(
      SaveDialogOptions(suggestedName: "a.txt")))
    discard awaitOutcome(p.download.pickDirectory(OpenDialogOptions()))

    discard awaitOutcome(p.shell.openExternalUrl("https://example.test/"))
    discard awaitOutcome(p.shell.revealInFileManager("/w/a.nr"))
    discard awaitOutcome(p.shell.windowState())
    discard awaitOutcome(p.shell.minimizeWindow())
    discard awaitOutcome(p.shell.toggleMaximizeWindow())
    discard awaitOutcome(p.shell.closeWindow())
    discard awaitOutcome(p.shell.setFullscreen(true))
    discard awaitOutcome(p.shell.openSessionWindow("s1"))

    ck rec.verbs.len == 0
    if rec.verbs.len > 0:
      echo "  these tab verbs were SENT: ", $rec.verbs
    # And the tab was actually reached, so the count above is not zero because
    # nothing happened. Ten of the sixteen have a bridge operation behind
    # them; the other six are the facade's own refusals — `clipboard.readText`
    # and the five window verbs the tab does not own.
    ck rec.tabOps.len == 10
    ck "clipboard.writeText" in rec.tabOps
    ck "clipboard.writeHtml" in rec.tabOps
    ck "download.openFileDialog" in rec.tabOps
    ck "download.saveFileDialog" in rec.tabOps
    ck "download.pickDirectory" in rec.tabOps
    ck "shell.openExternalUrl" in rec.tabOps
    ck "shell.setFullscreen" in rec.tabOps
    ck "shell.windowState" in rec.tabOps
    # `offerFile` and `offerText` are the same bridge operation — `offerText`
    # converts to bytes and calls `offerDownload` — so ten bridge calls come
    # from ten operations, of which two land on the same field.
    var offers = 0
    for op in rec.tabOps:
      if op == "download.offer": inc offers
    ck offers == 2

  test "the wire-owned verbs still cross the wire":
    ## The mirror direction. Without it, "route everything locally" passes the
    ## case above and breaks the deployment.
    let rec = Recorder()
    let p = composedPlatform(rec)
    let text = awaitOutcome(p.fs.readText("src/main.nr"))
    ck text.ok
    ck text.value == "fn main() {}"
    ck awaitOutcome(p.process.which("nargo")).value == "/usr/bin/nargo"
    ck awaitOutcome(p.vcs.repositoryRoot("/w/src")).value == "/w"
    ck awaitOutcome(p.settings.get(ssUser, "theme")).value == "dark"
    ck rec.verbs == @["fs.readText", "process.which", "vcs.repositoryRoot",
                      "settings.get"]
    ck rec.tabOps.len == 0

  test "the bridge-less constructor still sends all sixteen":
    ## Not nostalgia: `test_container_platform_verbs.nim` drives every one of
    ## the sixteen over a real frame pair through this constructor, and §6.6
    ## is a rule about the CLIENT rather than about the wire — the verbs still
    ## exist and a server may still be asked for them by a deployment that is
    ## not a tab.
    let rec = Recorder()
    let p = newContainerPlatform(recordingTransport(rec), servedStandIn())
    discard awaitOutcome(p.clipboard.writeText("copied"))
    discard awaitOutcome(p.download.offerText("a.txt", "t", "text/plain"))
    discard awaitOutcome(p.shell.setFullscreen(true))
    ck rec.verbs == @["clipboard.writeText", "download.offerText",
                      "shell.setFullscreen"]

  test "every row of the table agrees with the facade that was built":
    ## This is what keeps `answered` from being a second source of truth. The
    ## bridge above answers everything, so a row marked `answered` must NOT
    ## come back `pkNotSupported` and a row marked refused must.
    let rec = Recorder()
    let p = composedPlatform(rec)

    proc unsupported(verb: string): bool =
      case verb
      of "clipboard.writeText":
        awaitOutcome(p.clipboard.writeText("x")).error.kind == pkNotSupported
      of "clipboard.readText":
        awaitOutcome(p.clipboard.readText()).error.kind == pkNotSupported
      of "clipboard.writeHtml":
        awaitOutcome(p.clipboard.writeHtml("<b/>", "b")).error.kind == pkNotSupported
      of "download.offerFile":
        awaitOutcome(p.download.offerFile("a", @[byte 1], "text/plain")).error.kind ==
          pkNotSupported
      of "download.offerText":
        awaitOutcome(p.download.offerText("a", "t", "text/plain")).error.kind ==
          pkNotSupported
      of "download.openFileDialog":
        awaitOutcome(p.download.openFileDialog(OpenDialogOptions())).error.kind ==
          pkNotSupported
      of "download.saveFileDialog":
        awaitOutcome(p.download.saveFileDialog(SaveDialogOptions())).error.kind ==
          pkNotSupported
      of "download.pickDirectory":
        awaitOutcome(p.download.pickDirectory(OpenDialogOptions())).error.kind ==
          pkNotSupported
      of "shell.openExternalUrl":
        awaitOutcome(p.shell.openExternalUrl("https://a.test/")).error.kind ==
          pkNotSupported
      of "shell.revealInFileManager":
        awaitOutcome(p.shell.revealInFileManager("/w")).error.kind == pkNotSupported
      of "shell.windowState":
        awaitOutcome(p.shell.windowState()).error.kind == pkNotSupported
      of "shell.minimizeWindow":
        awaitOutcome(p.shell.minimizeWindow()).error.kind == pkNotSupported
      of "shell.toggleMaximizeWindow":
        awaitOutcome(p.shell.toggleMaximizeWindow()).error.kind == pkNotSupported
      of "shell.closeWindow":
        awaitOutcome(p.shell.closeWindow()).error.kind == pkNotSupported
      of "shell.setFullscreen":
        awaitOutcome(p.shell.setFullscreen(false)).error.kind == pkNotSupported
      of "shell.openSessionWindow":
        awaitOutcome(p.shell.openSessionWindow("s")).error.kind == pkNotSupported
      else:
        doAssert false, "the table names a verb this case cannot drive: " & verb
        false

    for entry in browserTabVerbs:
      ck unsupported(entry.verb) == (not entry.answered)
    # Nothing crossed the wire while we did that, either.
    ck rec.verbs.len == 0

# ---------------------------------------------------------------------------

suite "the external-URL allow-list travels with the facade":

  test "the schemes a bridge must never be handed are refused before it":
    ## `test_platform_web.nim`'s fake bridge accepted `javascript:` through a
    ## guard that existed only in `host/web_browser.nim`. A container
    ## deployment wires a THIRD bridge, so the guard has to be in the builder
    ## that all three share — and the assertion is that the bridge never saw
    ## the string, not merely that the outcome was an error.
    let rec = Recorder()
    let p = composedPlatform(rec)
    for hostile in ["javascript:alert(1)", "JavaScript:alert(1)",
                    "data:text/html,<script>x()</script>",
                    "file:///etc/passwd", "vscode://x", "  https://a.test/"]:
      let outcome = awaitOutcome(p.shell.openExternalUrl(hostile))
      ck not outcome.ok
      ck outcome.error.kind == pkInvalidArgument
    ck rec.openedUrls.len == 0
    ck rec.verbs.len == 0

  test "and the three that are allowed reach the tab unchanged":
    let rec = Recorder()
    let p = composedPlatform(rec)
    for allowed in ["http://a.test/x", "https://a.test/x", "mailto:a@b.test",
                    "HTTPS://A.test/x"]:
      ck awaitOutcome(p.shell.openExternalUrl(allowed)).ok
    ck rec.openedUrls == @["http://a.test/x", "https://a.test/x",
                           "mailto:a@b.test", "HTTPS://A.test/x"]
    ck rec.verbs.len == 0

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
