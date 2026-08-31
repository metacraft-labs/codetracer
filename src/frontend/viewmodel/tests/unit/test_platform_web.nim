## The web instantiation of the platform facade, and the URL scheme it is
## entered through — NS2, Noir-Studio.md §3.1, §1b.
##
## Runs on **both** backends, by discovery, and the JS run is the load-bearing
## one: `platform/web_platform.nim` is the module a browser tab executes.
##
## ## Why the subject is present here rather than stubbed
##
## `web_platform.nim` reaches no browser API at all — every tab capability
## arrives as a `BrowserBridge` field. So the module under test below is the
## shipped one, unmodified, and what varies is the bridge: this suite supplies
## one whose clipboard and download record what they were given, and
## `host/web_browser.nim` supplies one wired to `navigator.clipboard` and a
## blob download. There is no second implementation of the facade wiring, which
## is the property that makes this a test of the instantiation rather than of a
## fixture.

import std/[unittest, strutils, algorithm]

import ../../platform/outcome
import ../../platform/capabilities
import ../../platform/platform
import ../../platform/download
import ../../platform/shell
import ../../platform/store_volume
import ../../platform/memory_volume
import ../../platform/project_store
import ../../platform/web_platform
import ../../platform/web_entry
import ../../platform/web_deployment
import ../../platform/archive

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
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

const t0: int64 = 1_700_000_000_000

type
  BridgeLog = ref object
    ## What the fake tab was asked to do. Assertions read this rather than
    ## trusting that a facade call "worked", because a facade whose download
    ## silently did nothing would satisfy an `ok` check.
    clipboardText: seq[string]
    downloads: seq[tuple[name: string, bytes: seq[byte], mime: string]]
    openedUrls: seq[string]
    fullscreenRequests: seq[bool]

proc newFakeBridge(volume: StoreVolume; log: BridgeLog;
                   granted = true; answered = true;
                   shareOrigin = ""): BrowserBridge =
  BrowserBridge(
    volume: volume,
    persistenceGranted: granted,
    persistenceAnswered: answered,
    ownerId: "tab-under-test",
    nowMs: proc(): int64 = t0,
    writeClipboardText: proc(text: string): auto =
      log.clipboardText.add text
      resolvedOk(),
    writeClipboardHtml: proc(html, plainText: string): auto =
      log.clipboardText.add plainText
      resolvedOk(),
    offerDownload: proc(suggestedName: string; content: seq[byte];
                        mimeType: string): auto =
      log.downloads.add (suggestedName, content, mimeType)
      resolvedOk(),
    pickFiles: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[seq[string]]("importing files from your computer"),
    pickDirectory: proc(options: OpenDialogOptions): auto =
      resolvedUnsupported[string]("importing a folder from your computer"),
    suggestSaveName: proc(options: SaveDialogOptions): auto =
      resolvedOk(options.suggestedName),
    openExternalUrl: proc(url: string): auto =
      log.openedUrls.add url
      resolvedOk(),
    setFullscreen: proc(fullscreen: bool): auto =
      log.fullscreenRequests.add fullscreen
      resolvedOk(),
    windowState: proc(): auto =
      resolvedOk(WindowState(maximized: false, minimized: false,
                             fullscreen: false, focused: true)),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard,
    shareLinkOrigin: shareOrigin,
    wasm: noWasmModules())
      # This suite's subject is the store, the entry layer and the shell
      # facades, none of which run a command. NS3's registry and its four
      # answers have their own suite — `test_platform_wasm_modules.nim` —
      # which builds bridges with populated hosts. An empty host here keeps
      # this suite asserting what it is about.

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = text[i].byte

proc textOf(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = bytes[i].char

proc bootFake(log: BridgeLog; durable = true; granted = true;
              answered = true; shareOrigin = ""
             ): tuple[web: WebPlatform, memory: MemoryVolume] =
  let memory = newMemoryVolume()
  var volume = memory.asVolume
  volume.durable = durable
  let bridge = newFakeBridge(volume, log, granted, answered, shareOrigin)
  let opened = awaitOutcome(openWebStore(bridge))
  doAssert opened.ok, "the fake store did not open: " & $opened.error
  opened.value.acknowledgeDurability()
  let web = newWebPlatform(bridge, opened.value)
  doAssert awaitOutcome(web.store.createProject("p1", "demo", t0)).ok
  doAssert awaitOutcome(web.activateProject("p1")).ok
  (web, memory)

# ---------------------------------------------------------------------------
suite "the web instantiation satisfies every facade — NS2, §3.1":
# ---------------------------------------------------------------------------

  setup:
    let log = BridgeLog()
    let booted = bootFake(log)
    let web = booted.web
    let memory = booted.memory

  test "all seven facades are present and none is nil":
    ## The shape check `{.requiresInit.}` makes cheap: a facade field added to
    ## any of the seven fails this build at `newWebPlatform`, exactly as NS1's
    ## `test_a_remote_instantiation_needs_no_signature_change` requires of the
    ## remote stub.
    check not web.platform.isNil
    check not web.platform.fs.isNil
    check not web.platform.process.isNil
    check not web.platform.vcs.isNil
    check not web.platform.settings.isNil
    check not web.platform.clipboard.isNil
    check not web.platform.download.isNil
    check not web.platform.shell.isNil
    check web.platform.kind == pkWeb

  test "the filesystem facade reads and writes the project store":
    check awaitOutcome(web.platform.fs.writeText("src/main.nr", "fn main(){}")).ok
    check awaitOutcome(web.platform.fs.readText("src/main.nr")).value ==
      "fn main(){}"
    check awaitOutcome(web.platform.fs.exists("src/main.nr")).value
    check not awaitOutcome(web.platform.fs.exists("src/absent.nr")).value

    let listed = awaitOutcome(web.platform.fs.listDir("src"))
    check listed.ok
    check listed.value.len == 1
    check listed.value[0].name == "main.nr"
    check listed.value[0].kind == fekFile

  test "the facade's writes really do go through the atomic replace":
    ## Otherwise the web instantiation could be honouring the facade while
    ## bypassing the store's §4.4 guarantees.
    let movesBefore = memory.moveCount
    check awaitOutcome(web.platform.fs.writeText("a.nr", "one")).ok
    check memory.moveCount == movesBefore + 1

  test "append is a read-modify-write, and creates a missing file":
    check awaitOutcome(web.platform.fs.appendText("log.txt", "a")).ok
    check awaitOutcome(web.platform.fs.appendText("log.txt", "b")).ok
    check awaitOutcome(web.platform.fs.readText("log.txt")).value == "ab"

  test "an absolute path is refused rather than reinterpreted":
    ## The failure this prevents: a desktop code path that was never migrated
    ## appearing to work on the web while writing somewhere else entirely.
    let refused = awaitOutcome(
      web.platform.fs.writeText("/etc/passwd", "nope"))
    check not refused.ok
    check refused.error.kind == pkInvalidArgument
    check "project store" in refused.error.message
    check awaitOutcome(web.platform.fs.readText("/etc/passwd")).ok == false

  test "a path climbing out of the store cannot express itself":
    check awaitOutcome(
      web.platform.fs.writeText("../../escape.nr", "nope")).ok
    # It landed INSIDE, at the clamped path, rather than outside.
    check awaitOutcome(web.platform.fs.readText("escape.nr")).value == "nope"
    for path in memory.fileNames():
      check path.startsWith("projects/") or path == "store"

  test "copy and move go through the store, not through the volume":
    check awaitOutcome(web.platform.fs.writeText("a.nr", "body")).ok
    check awaitOutcome(web.platform.fs.copy("a.nr", "b.nr")).ok
    check awaitOutcome(web.platform.fs.readText("b.nr")).value == "body"
    check awaitOutcome(web.platform.fs.move("b.nr", "c.nr")).ok
    check awaitOutcome(web.platform.fs.readText("c.nr")).value == "body"
    check not awaitOutcome(web.platform.fs.exists("b.nr")).value

  test "settings round-trip, and are scoped":
    check awaitOutcome(
      web.platform.settings.set(ssUser, "theme", "dark")).ok
    check awaitOutcome(
      web.platform.settings.set(ssWorkspace, "theme", "light")).ok
    check awaitOutcome(web.platform.settings.get(ssUser, "theme")).value ==
      "dark"
    check awaitOutcome(web.platform.settings.get(ssWorkspace, "theme")).value ==
      "light"
    check awaitOutcome(web.platform.settings.delete(ssUser, "theme")).ok
    check not awaitOutcome(web.platform.settings.get(ssUser, "theme")).ok

  test "clipboard writes reach the tab; reading is refused, not prompted":
    check awaitOutcome(web.platform.clipboard.writeText("a link")).ok
    check log.clipboardText == @["a link"]
    let read = awaitOutcome(web.platform.clipboard.readText())
    check not read.ok
    check read.error.kind == pkNotSupported

  test "download hands the bytes to the tab":
    check awaitOutcome(web.platform.download.offerText(
      "notes.txt", "hello", "text/plain")).ok
    check log.downloads.len == 1
    check log.downloads[0].name == "notes.txt"
    check textOf(log.downloads[0].bytes) == "hello"

  test "shell opens external URLs and refuses what a tab does not own":
    check awaitOutcome(
      web.platform.shell.openExternalUrl("https://example.test/")).ok
    check log.openedUrls == @["https://example.test/"]

  test "the web arm refuses every scheme that is not http, https or mailto":
    ## `ShellFacade.openExternalUrl`'s contract says implementations must
    ## refuse anything else.  It said so only in a doc comment, and this arm
    ## did not: the URL went straight to `window.open`.  The three allowed
    ## schemes are asserted alongside the refusals so a guard that refused
    ## EVERYTHING would fail here rather than pass as "secure".
    var refused = 0
    for hostile in [
        "javascript:alert(1)",
        "JavaScript:alert(1)",              # the check is case-insensitive
        "data:text/html,<script>alert(1)</script>",
        "file:///etc/passwd",
        "vscode://file/etc/passwd",         # an OS-registered handler scheme
        "  javascript:alert(1)"]:           # no trimming: still not allowed
      let outcome = awaitOutcome(web.platform.shell.openExternalUrl(hostile))
      check not outcome.ok
      check outcome.error.kind == pkInvalidArgument
      inc refused
    check refused == 6
    # The refusals must not have reached the tab at all.  `setup:` gives each
    # test a fresh bridge, so this is the whole log.
    check log.openedUrls.len == 0

    var allowed = 0
    for benign in ["http://example.test/a", "https://example.test/b",
                   "mailto:someone@example.test"]:
      check awaitOutcome(web.platform.shell.openExternalUrl(benign)).ok
      inc allowed
    check allowed == 3
    check log.openedUrls == @["http://example.test/a",
                              "https://example.test/b",
                              "mailto:someone@example.test"]
    check not awaitOutcome(web.platform.shell.minimizeWindow()).ok
    check not awaitOutcome(web.platform.shell.closeWindow()).ok
    check not awaitOutcome(web.platform.shell.revealInFileManager("a.nr")).ok
    check awaitOutcome(web.platform.shell.setFullscreen(true)).ok
    check log.fullscreenRequests == @[true]

# ---------------------------------------------------------------------------
suite "capability and refusal never disagree — the web profile":
# ---------------------------------------------------------------------------
#
# NS1's rule: a caller asks `can(...)` and then calls, and the two answers must
# match. NS1 found the default platform breaking it and fixed that one case.
# This checks the web instantiation over the WHOLE capability set, mechanically,
# which is what makes it a property rather than a spot check.

  setup:
    let log = BridgeLog()
    let booted = bootFake(log)
    let web = booted.web

  test "every absent capability has a degradation sentence":
    let profile = web.platform.profile
    check profile.undeclaredDegradations().len == 0
    check profile.staleDegradations().len == 0

  test "a claimed capability is not refused, and a refused one is not claimed":
    ## Sampled over the operations that have a one-to-one capability, in both
    ## directions — a one-directional check would pass on a profile that
    ## claimed nothing at all.
    let p = web.platform
    check p.can(capFilesystemRead)
    check awaitOutcome(p.fs.readText("src/main.nr")).error.kind != pkNotSupported

    check p.can(capFilesystemWrite)
    check awaitOutcome(p.fs.writeText("x.nr", "v")).ok

    check not p.can(capFilesystemWatch)
    check awaitOutcome(p.fs.watch("", true, proc(e: FsWatchEvent) = discard)
                      ).error.kind == pkNotSupported

    check not p.can(capFilesystemTemp)
    check awaitOutcome(p.fs.makeTempDir("x")).error.kind == pkNotSupported

    check not p.can(capProcessSpawn)
    check awaitOutcome(p.process.run(processSpec("nargo"))).error.kind ==
      pkNotSupported

    check not p.can(capSecretStore)
    check awaitOutcome(p.settings.getSecret("a", "k")).error.kind ==
      pkNotSupported

    check p.can(capClipboardWrite)
    check awaitOutcome(p.clipboard.writeText("x")).ok
    check not p.can(capClipboardRead)
    check awaitOutcome(p.clipboard.readText()).error.kind == pkNotSupported

    check not p.can(capWindowControls)
    check awaitOutcome(p.shell.minimizeWindow()).error.kind == pkNotSupported
    check p.can(capWindowFullscreen)
    check awaitOutcome(p.shell.setFullscreen(false)).ok

  test "capVcsRead and capVcsWrite are ABSENT, and say why":
    ## NS2's finding, asserted rather than left in a comment. `webProfile` as
    ## NS1 wrote it claims both; the engine that would honour them is NS5's,
    ## sequenced after launch. A profile claiming a capability its facade
    ## refuses is the exact disagreement `capabilities.nim` exists to remove.
    let p = web.platform
    check not p.can(capVcsRead)
    check not p.can(capVcsWrite)
    check "NS5" in p.degradedBehaviour(capVcsRead)
    check "no git binary" in p.degradedBehaviour(capVcsRead)
    check awaitOutcome(p.vcs.status(".")).error.kind == pkNotSupported
    check awaitOutcome(p.vcs.commit(".", "m", "a", "e")).error.kind ==
      pkNotSupported

  test "capFilesystemTemp is absent, and the sentence says where staging goes":
    let p = web.platform
    check not p.can(capFilesystemTemp)
    check "project store" in p.degradedBehaviour(capFilesystemTemp)

  test "capShareLink follows the configured origin, not the build":
    let quiet = BridgeLog()
    let unconfigured = bootFake(quiet).web
    check not unconfigured.platform.can(capShareLink)
    check "no sharing origin configured" in
      unconfigured.platform.degradedBehaviour(capShareLink)

    let loud = BridgeLog()
    let configured = bootFake(loud, shareOrigin = "https://ide.example.test").web
    check configured.platform.can(capShareLink)

# ---------------------------------------------------------------------------
suite "the durability gate stops the first keystroke — §4.2":
# ---------------------------------------------------------------------------

  test "an unacknowledged volatile session refuses writes through the facade":
    ## The gate is in the facade, not only in the store, because the facade is
    ## what a pane calls. A view that forgets to render the banner therefore
    ## gets a refusal it can show rather than silent loss.
    let log = BridgeLog()
    let memory = newMemoryVolume()
    var volume = memory.asVolume
    volume.durable = false
    let bridge = newFakeBridge(volume, log, false, false)
    let opened = awaitOutcome(openWebStore(bridge))
    check opened.ok
    check opened.value.durability.condition == scVolatile
    check not opened.value.readyForEditing

    let web = newWebPlatform(bridge, opened.value)
    check awaitOutcome(web.store.createProject("p1", "demo", t0)).ok
    check awaitOutcome(web.activateProject("p1")).ok

    let refused = awaitOutcome(web.platform.fs.writeText("a.nr", "x"))
    check not refused.ok
    check refused.error.kind == pkAccessDenied
    check "what will happen to your work" in refused.error.message

    opened.value.acknowledgeDurability()
    check awaitOutcome(web.platform.fs.writeText("a.nr", "x")).ok

  test "reading is never gated, so an unacknowledged session is not blank":
    ## §4.2: "Never a blank failure." The session RUNS.
    let log = BridgeLog()
    let memory = newMemoryVolume()
    var volume = memory.asVolume
    volume.durable = false
    let bridge = newFakeBridge(volume, log, false, false)
    let opened = awaitOutcome(openWebStore(bridge))
    let web = newWebPlatform(bridge, opened.value)
    discard awaitOutcome(web.store.createProject("p1", "demo", t0))
    discard awaitOutcome(web.activateProject("p1"))
    let listed = awaitOutcome(web.platform.fs.listDir(""))
    check listed.ok

# ---------------------------------------------------------------------------
suite "archive export, end to end through the facade — §6.2":
# ---------------------------------------------------------------------------

  test "the export reaches the tab and stops the never-exported warning":
    let log = BridgeLog()
    let booted = bootFake(log, durable = false)
    let web = booted.web
    check awaitOutcome(web.platform.fs.writeText("Nargo.toml", "[package]")).ok
    check awaitOutcome(web.platform.fs.writeText("src/main.nr", "fn m(){}")).ok

    check web.store.exportWarning("p1").len > 0
    check "will be lost when this tab closes" in web.store.exportWarning("p1")

    check awaitOutcome(web.exportProjectArchive("p1", "demo")).ok
    check log.downloads.len == 1
    check log.downloads[0].name == "demo.tar"
    check log.downloads[0].mime == "application/x-tar"

    var paths: seq[string] = @[]
    for entry in readArchive(log.downloads[0].bytes):
      paths.add entry.path
    paths.sort()
    check paths == @["demo/Nargo.toml", "demo/src/main.nr"]

    check web.store.exportWarning("p1") == ""

  test "a read-only tab does not delete the writer's build outputs":
    ## `activateProject` runs §4.4's discard, and it must be the OWNER's
    ## decision. A second tab clearing a compilation in progress would be a
    ## data-loss bug reachable by opening a URL twice.
    let log = BridgeLog()
    let memory = newMemoryVolume()
    let volume = memory.asVolume
    let bridgeA = newFakeBridge(volume, log)
    let openedA = awaitOutcome(openWebStore(bridgeA))
    openedA.value.acknowledgeDurability()
    let webA = newWebPlatform(bridgeA, openedA.value)
    discard awaitOutcome(webA.store.createProject("p1", "demo", t0))
    discard awaitOutcome(webA.activateProject("p1"))
    check awaitOutcome(webA.store.writeBuildOutput(
      "p1", "circuit.acir", bytesOf("compiled"))).ok

    var bridgeB = newFakeBridge(volume, log)
    bridgeB.ownerId = "second-tab"
    let openedB = awaitOutcome(openWebStore(bridgeB))
    openedB.value.acknowledgeDurability()
    let webB = newWebPlatform(bridgeB, openedB.value)
    let activated = awaitOutcome(webB.activateProject("p1"))
    check activated.ok
    check activated.value.role == wrReadOnly

    check textOf(memory.rawRead(buildOutputRoot("p1") & "/circuit.acir")) ==
      "compiled"

# ---------------------------------------------------------------------------
suite "test_every_entry_form_reaches_the_application — §1b.0, §1b.4":
# ---------------------------------------------------------------------------

  test "each of the five forms classifies, and nothing else does":
    check classifyPath("/noir").form == efBare
    check classifyPath("/noir/").form == efBare
    check classifyPath("/noir/new").form == efNew
    check classifyPath("/s/abc123").form == efSnapshot
    check classifyPath("/p/hello-world-3f9a2c").form == efProject
    check classifyPath("/projects").form == efProjectList
    check classifyPath("/collab/join/tok").form == efSession
    check classifyPath("/nope").form == efUnknown
    check classifyPath("/noir/nonsense").form == efUnknown

  test "every path a form can produce is covered by a rewrite prefix":
    ## The agreement §1b.4 needs and a hand-written host config cannot give:
    ## a form the application handles that the CDN 404s.
    let prefixes = rewritePrefixes()
    let addresses = @[
      "/noir", "/noir/", "/noir/new", "/s/abc123",
      "/p/hello-world-3f9a2c", "/projects", "/collab/join/tok"]
    for address in addresses:
      var covered = false
      for prefix in prefixes:
        if address == prefix or address.startsWith(prefix & "/"):
          covered = true
      check covered

  test "the rewrite check can fail":
    ## Otherwise it is a check that agrees with itself.
    var covered = false
    for prefix in rewritePrefixes():
      if "/not-a-prefix" == prefix or "/not-a-prefix".startsWith(prefix & "/"):
        covered = true
    check not covered

  test "the generated rewrite config serves 200, never a redirect":
    let contract = deploymentContract("https://ide.example.test")
    let rendered = renderRewriteConfig(contract)
    check "  200" in rendered
    check "301" notin rendered
    check "302" notin rendered
    for prefix in rewritePrefixes():
      check (prefix & "/*") in rendered

  test "the three cache classes are keyed on prefix, with distinct headers":
    let contract = deploymentContract("https://ide.example.test")
    check headerFor(ccImmutable) == "public, max-age=31536000, immutable"
    check "stale-while-revalidate" in headerFor(ccPointer)
    check "must-revalidate" in headerFor(ccEntryDocument)
    check headerFor(ccImmutable) != headerFor(ccEntryDocument)
    check headerFor(ccPointer) != headerFor(ccEntryDocument)
    let rendered = renderCacheConfig(contract)
    check "/s/*" in rendered
    check "/p/*" in rendered

  test "every cache class is reachable from a real address":
    ## Review found two that were not. `cacheClassFor` answered
    ## `ccEntryDocument` for everything under `/p/` and for `/assets/`, so
    ## `ccPointer` and `ccStaticAsset` were rows in a header table that no path
    ## ever selected — and the test above passes either way, because it calls
    ## `headerFor` directly. A class no address reaches is a class whose header
    ## is never applied.
    check cacheClassFor(pointerPath("hello-world", "3f9a2c")) == ccPointer
    check cacheClassFor("/p/hello-world-3f9a2c") == ccEntryDocument
    check cacheClassFor("/s/9f2b1c") == ccImmutable
    check cacheClassFor("/assets/app.9f2b1c.js") == ccStaticAsset
    check cacheClassFor("/noir") == ccEntryDocument
    var seen: set[CacheClass] = {}
    for address in ["/", "/noir", "/noir/new", "/s/9f2b1c",
                    "/p/hello-world-3f9a2c",
                    "/p/hello-world-3f9a2c/current.json",
                    "/assets/app.9f2b1c.js", "/projects"]:
      seen.incl cacheClassFor(address)
    for class in CacheClass:
      check class in seen

  test "the generated cache config agrees with cacheClassFor, address by address":
    ## The failure this prevents is the one review found: the classifier said
    ## the project address was an entry document and the generated file put the
    ## pointer's `stale-while-revalidate` on the whole `/p/` prefix, so a
    ## returning user could be served a day-old application bundle. Two
    ## descriptions of one table, disagreeing, with nothing comparing them.
    proc matchesPattern(pattern, path: string): bool =
      ## The `_redirects`/`_headers` glob: at most one `*`, matching any run.
      let star = pattern.find('*')
      if star < 0: return pattern == path
      let head = pattern[0 ..< star]
      let tail = pattern[star + 1 .. ^1]
      path.len >= head.len + tail.len and
        path.startsWith(head) and path.endsWith(tail)

    let contract = deploymentContract("https://ide.example.test")
    for address in ["/", "/noir", "/noir/new", "/s/9f2b1c",
                    "/p/hello-world-3f9a2c",
                    "/p/hello-world-3f9a2c/current.json",
                    "/assets/app.9f2b1c.js", "/projects"]:
      var applied = ""
      for rule in contract.caches:
        if matchesPattern(rule.pattern, address):
          applied = rule.headerValue
          break
      check applied == headerFor(cacheClassFor(address))

  test "the agreement check can fail":
    ## Without this, the check above would pass over an empty rule list.
    proc matchesPattern(pattern, path: string): bool =
      let star = pattern.find('*')
      if star < 0: return pattern == path
      let head = pattern[0 ..< star]
      let tail = pattern[star + 1 .. ^1]
      path.len >= head.len + tail.len and
        path.startsWith(head) and path.endsWith(tail)
    var contract = deploymentContract("https://ide.example.test")
    contract.caches = @[CacheRule(pattern: "/p/*", class: ccPointer,
                                  headerValue: pointerHeader)]
    let address = "/p/hello-world-3f9a2c"
    var applied = ""
    for rule in contract.caches:
      if matchesPattern(rule.pattern, address):
        applied = rule.headerValue
        break
    check applied != headerFor(cacheClassFor(address))

  test "there is no identifier allocation endpoint, and two write surfaces":
    let contract = deploymentContract("https://ide.example.test")
    check contract.identifierAllocationEndpoints.len == 0
    check contract.writeSurfaces.len == 2
    for surface in contract.writeSurfaces:
      check surface.needsAccount
      check "keep" in surface.outageDegrades or
            "keeps" in surface.outageDegrades

  test "the origin is never a constant":
    ## Two different origins produce two different contracts and neither is
    ## baked in. A default here is what the last two domain moves each had to
    ## hunt for.
    check deploymentContract("https://a.example").origin == "https://a.example"
    check deploymentContract("https://b.example").origin == "https://b.example"
    check absoluteUrl("https://ide.example.test", "/s/abc", "f=main.nr:4") ==
      "https://ide.example.test/s/abc#f=main.nr:4"

# ---------------------------------------------------------------------------
suite "test_bare_url_resolves_by_local_state — §1b.0 rule 5":
# ---------------------------------------------------------------------------

  test "no local workspace opens the bundled template":
    let resolved = resolveEntry(
      EntryRequest(path: "/noir"), LocalState(hasWorkspace: false))
    check resolved.verdict == evTemplate
    check resolved.languageEntry == "noir"
    check not resolved.replacesHistoryEntry

  test "a local workspace opens the most recent one":
    let resolved = resolveEntry(
      EntryRequest(path: "/noir"),
      LocalState(hasWorkspace: true, mostRecentProjectId: "local-7"))
    check resolved.verdict == evLocalWorkspace
    check resolved.locator == "local-7"

  test "/new always opens a template and replaces the history entry":
    let resolved = resolveEntry(
      EntryRequest(path: "/noir/new"),
      LocalState(hasWorkspace: true, mostRecentProjectId: "local-7"))
    check resolved.verdict == evTemplate
    check resolved.replacesHistoryEntry
    check resolved.opensAsNewProject

  test "the bare URL does not replace the history entry":
    ## The counter-check for the flag above.
    check not resolveEntry(EntryRequest(path: "/noir"),
                           LocalState(hasWorkspace: true)).replacesHistoryEntry

# ---------------------------------------------------------------------------
suite "§1b.3 precedence, and what a stale link does":
# ---------------------------------------------------------------------------

  test "a snapshot path wins over an inline fragment":
    let resolved = resolveEntry(
      EntryRequest(path: "/s/bundle1", fragment: "p=inlinepayload"),
      LocalState(hasWorkspace: true, mostRecentProjectId: "local-7"))
    check resolved.verdict == evSnapshot
    check resolved.locator == "bundle1"

  test "a project path wins over an inline fragment and a local workspace":
    let resolved = resolveEntry(
      EntryRequest(path: "/p/hello-3f9a", fragment: "p=inlinepayload"),
      LocalState(hasWorkspace: true, mostRecentProjectId: "local-7"))
    check resolved.verdict == evProjectPointer
    check resolved.locator == "3f9a"
    check resolved.projectSlug == "hello"

  test "an inline fragment wins over a local workspace":
    let resolved = resolveEntry(
      EntryRequest(path: "/noir", fragment: "p=inlinepayload"),
      LocalState(hasWorkspace: true, mostRecentProjectId: "local-7"))
    check resolved.form == efInline
    check resolved.verdict == evInlineProject
    check resolved.locator == "inlinepayload"

  test "an unreachable pointer degrades to a cached snapshot, and says so":
    let resolved = resolveEntry(
      EntryRequest(path: "/p/hello-3f9a"),
      LocalState(cachedSnapshotIds: @["3f9a"]),
      pointerReachable = false)
    check resolved.verdict == evSnapshot
    check resolved.mayBeStale
    check "out of date" in resolved.explanation

  test "an unreachable pointer with nothing cached opens a template, named":
    let resolved = resolveEntry(
      EntryRequest(path: "/p/hello-3f9a"), LocalState(),
      pointerReachable = false)
    check resolved.verdict == evTemplate
    check not resolved.mayBeStale
    check "could not be reached" in resolved.explanation

  test "an unresolvable path is never an error page":
    let resolved = resolveEntry(
      EntryRequest(path: "/rust/wat"), LocalState())
    check resolved.verdict == evTemplate
    check "is not an address this product serves" in resolved.explanation

  test "a project link carrying a replay coordinate says it may not fit":
    let resolved = resolveEntry(
      EntryRequest(path: "/p/hello-3f9a", fragment: "t=12345"), LocalState())
    check resolved.verdict == evProjectPointer
    check resolved.position.coordinate == "12345"
    check "may no longer fit" in resolved.explanation

  test "position keys degrade independently":
    let position = parsePosition("f=main.nr:42&view=constraints&t=c1&test=t_ov&session=2")
    check position.file == "main.nr"
    check position.line == 42
    check position.view == "constraints"
    check position.coordinate == "c1"
    check position.test == "t_ov"
    check position.session == 2

    let broken = parsePosition("f=main.nr:notanumber&session=notanumber&t=c1")
    check broken.file == "main.nr:notanumber"
    check broken.line == 0
    check broken.session == 0
    check broken.coordinate == "c1"     # the rest still resolves

# ---------------------------------------------------------------------------
suite "test_arrival_writes_nothing_and_mints_no_address — §1b.0 rules 1, 2, 4":
# ---------------------------------------------------------------------------

  test "no form writes on arrival or mints a server identifier":
    ## Asserted over every form at once, so a form added later is covered
    ## without anyone remembering to extend the list.
    for form in EntryForm:
      let path =
        case form
        of efBare: "/noir"
        of efNew: "/noir/new"
        of efInline: "/noir"
        of efSnapshot: "/s/abc"
        of efProject: "/p/hello-3f9a"
        of efProjectList: "/projects"
        of efSession: "/collab/join/tok"
        of efUnknown: "/nonsense"
      let fragment = if form == efInline: "p=payload" else: ""
      let resolved = resolveEntry(
        EntryRequest(path: path, fragment: fragment), LocalState())
      check not resolved.writesOnArrival
      check not resolved.mintsServerIdentifier

  test "test_opening_a_link_preserves_unsaved_local_work — rule 4":
    ## "A link opens as a new project in the store, always", with no prompt.
    ## Asserted as a property of the resolution rather than of a dialog,
    ## because §1b.0 is explicit that "the prompt is the defect".
    for path in ["/s/abc", "/p/hello-3f9a", "/noir/new"]:
      let resolved = resolveEntry(
        EntryRequest(path: path),
        LocalState(hasWorkspace: true, mostRecentProjectId: "unsaved-work"))
      check resolved.opensAsNewProject
      check resolved.locator != "unsaved-work"

  test "a link's project and the local workspace are different store rows":
    ## The store half of rule 4: opening the link's project cannot overwrite
    ## the local one, because they are separate ids in one store.
    let log = BridgeLog()
    let booted = bootFake(log)
    let web = booted.web
    check awaitOutcome(web.platform.fs.writeText("main.nr", "my work")).ok

    check awaitOutcome(web.store.createProject("p2", "from a link", t0)).ok
    check awaitOutcome(web.activateProject("p2")).ok
    check awaitOutcome(web.platform.fs.writeText("main.nr", "their work")).ok

    check awaitOutcome(web.activateProject("p1")).ok
    check awaitOutcome(web.platform.fs.readText("main.nr")).value == "my work"

# ---------------------------------------------------------------------------
suite "test_no_user_content_reaches_an_access_log — §1b.0 rule 2":
# ---------------------------------------------------------------------------

  test "the product declares no query parameters":
    check declaredQueryParameters.len == 0

  test "a query string changes nothing about how a URL resolves":
    let withQuery = resolveEntry(
      EntryRequest(path: "/s/abc", fragment: "f=main.nr:4",
                   query: "utm_source=x&ref=y"),
      LocalState())
    let without = resolveEntry(
      EntryRequest(path: "/s/abc", fragment: "f=main.nr:4"), LocalState())
    check withQuery.verdict == without.verdict
    check withQuery.locator == without.locator
    check withQuery.position.file == without.position.file
    check withQuery.position.line == without.position.line

  test "every piece of client state encodes into the fragment":
    let position = Position(
      file: "src/main.nr", line: 42, view: "constraints",
      coordinate: "c-1", test: "test_overflow", session: 2)
    let fragment = encodePosition(position)
    check fragment == "f=src/main.nr:42&view=constraints&t=c-1&test=test_overflow&session=2"
    # And it round-trips, so the fragment really is the whole state.
    let parsed = parsePosition(fragment)
    check parsed.file == position.file
    check parsed.line == position.line
    check parsed.view == position.view
    check parsed.coordinate == position.coordinate
    check parsed.test == position.test
    check parsed.session == position.session

  test "no built URL can carry a query string":
    ## `absoluteUrl` has no query parameter, so this is a property of the
    ## builder rather than an observation about today's call sites. Asserted
    ## over a file path and a replay coordinate, which are the two things §1b.0
    ## names as never reaching an access log.
    let url = absoluteUrl(
      "https://ide.example.test",
      snapshotPath("bundle-1"),
      encodePosition(Position(file: "src/secret_circuit.nr", line: 7,
                              coordinate: "c-9")))
    check "?" notin url
    let cut = url.find('#')
    check cut > 0
    check "secret_circuit" notin url[0 ..< cut]
    check "c-9" notin url[0 ..< cut]
    check "secret_circuit" in url[cut .. ^1]

# ---------------------------------------------------------------------------
suite "the language is an entry point, not a namespace — §1b.0 rule 0":
# ---------------------------------------------------------------------------

  test "projects and snapshots live at the language-neutral root":
    check projectPath("hello-world", "3f9a2c") == "/p/hello-world-3f9a2c"
    check snapshotPath("bundle1") == "/s/bundle1"
    check "noir" notin projectPath("hello-world", "3f9a2c")
    check "noir" notin snapshotPath("bundle1")

  test "the language entry sets the template and is carried nowhere else":
    let resolved = resolveEntry(EntryRequest(path: "/noir/new"), LocalState())
    check resolved.languageEntry == "noir"
    let neutral = resolveEntry(EntryRequest(path: "/s/abc"), LocalState())
    check neutral.languageEntry == ""

  test "a rename cannot break a project link, because only the suffix resolves":
    let before = splitProjectLocator("hello-world-3f9a2c")
    let after = splitProjectLocator("renamed-entirely-3f9a2c")
    check before.projectId == after.projectId
    check before.slug != after.slug
    check splitProjectLocator("3f9a2c").projectId == "3f9a2c"
    check splitProjectLocator("3f9a2c").slug == ""

  test "the pointer object sits under the project's own address":
    check pointerPath("hello-world", "3f9a2c") ==
      "/p/hello-world-3f9a2c/current.json"

# ---------------------------------------------------------------------------
# The delivery manifest — NS3's residual, which is DELIVERY and not loading.
#
# `host/web_browser.nim` says it plainly: the registry, the protocol, the
# transport and `newBrowserWasmHost` are all present and tested, and none of it
# is reachable because the worker script "is not in the bundle". These cases
# pin the manifest that says what a bundle must carry, so the assembly step and
# the gate read one declaration instead of three hand-written lists.
# ---------------------------------------------------------------------------

  test "the manifest carries the renderer, the entry and the worker as REQUIRED":
    # The renderer is the whole point of this milestone: a bundle that does not
    # carry it cannot show a pane, which is the half of
    # `test_one_codebase_two_platforms` NS2 left unasserted.
    let required = requiredRuntimeAssets()
    var ids: seq[string]
    for asset in required: ids.add asset.id
    check "renderer" in ids
    check "web-entry" in ids
    check "wasm-worker" in ids
    # Counted, so an asset silently losing `required` is caught. Asserting only
    # membership would pass over a manifest that had gained three more.
    check required.len == 3

  test "the renderer is BUNDLED and the worker is a separate ASSET":
    # Not a stylistic distinction. `new Worker(url)` takes a URL and
    # `newBrowserWasmHost(registry, scriptUrl)` already has the parameter, so
    # an inlined worker would have to be revived as a `blob:` URL — which a
    # real Content-Security-Policy rejects.
    var byId: seq[tuple[id: string, mode: DeliveryMode]]
    for asset in webRuntimeAssets(): byId.add (asset.id, asset.mode)
    check (id: "renderer", mode: damBundled) in byId
    check (id: "wasm-worker", mode: damAsset) in byId

  test "the two Noir modules are FETCHED, never bundled":
    # ~16 MB and ~4.6 MB. Bundling them inflates by a third as base64 and puts
    # the result in front of first paint, for a capability most sessions never
    # invoke.
    let fetched = fetchedRuntimeAssets()
    var ids: seq[string]
    for asset in fetched: ids.add asset.id
    check ids.sorted == @[noirCompilerModuleId, noirTracerModuleId].sorted
    for asset in fetched:
      check asset.mode == damFetched
      check asset.mode != damBundled

  test "a fetched module's id is the id the worker resolves":
    # `wasm_worker_browser.js` looks its URLs up by these exact strings
    # (`load('noir-compiler')`, `load('noir-tracer')`), so a rename here that
    # did not reach the worker would produce "no url declared for wasm module"
    # at run time and nowhere earlier.
    check noirCompilerModuleId == "noir-compiler"
    check noirTracerModuleId == "noir-tracer"

  test "every OPTIONAL asset says what its absence costs":
    # The same rule `capabilities.undeclaredDegradations` enforces one layer
    # up. A deployment shipping no wasm modules is a legitimate configuration —
    # `noWasmModules()` models exactly that — so the absence must be a
    # sentence a user can read, not a silent capability hole.
    check undeclaredAbsences().len == 0

  test "and a REQUIRED asset does not carry an absence story":
    # The mirror check, and it is not symmetry for its own sake: a required
    # asset with a degradation sentence is one somebody is about to make
    # optional. `staleDegradations` exists for the same reason.
    for asset in webRuntimeAssets():
      if asset.required:
        check asset.absenceBehaviour.len == 0

  test "the fetched modules and the worker are served as static assets":
    # They must land under the prefix whose cache rule is `immutable`, or a CDN
    # serves a 16 MB module with the entry document's 60-second TTL.
    for asset in webRuntimeAssets():
      if asset.mode != damBundled:
        check asset.path.startsWith(staticAssetPrefix[1 .. ^1])
        check cacheClassFor("/" & asset.path) == ccStaticAsset
        check headerFor(cacheClassFor("/" & asset.path)) == immutableHeader

  test "no two assets claim the same path":
    # A duplicate path is a build step that overwrites its own output, and it
    # would be invisible: the last writer wins and the bundle looks complete.
    var seen: seq[string]
    for asset in webRuntimeAssets():
      check asset.path notin seen
      check asset.path.len > 0
      seen.add asset.path
