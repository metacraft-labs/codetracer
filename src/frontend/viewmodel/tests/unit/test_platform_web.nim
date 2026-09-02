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
import ../../platform/noir_template
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

# ---------------------------------------------------------------------------
# A deployment assembled the way the assembly step assembles one.
#
# WHY THIS FIXTURE EXISTS AT ALL, and it is the whole of a defect review found
# on 2026-09-01. The `/assets/` cache class used to be selected in this file
# with `/assets/app.9f2b1c.js` — a filename no assembly step had ever produced.
# The class was therefore validated on a fictional address while all three real
# published paths, every one of them stable-named, went unchecked and were
# served a year of `immutable`.
#
# So the names below are not written out. They are formed by
# `contentAddressedPath`, which is the same function `ci/test/web_asset_name.nim`
# calls for `ci/test/web-bundle-assets.sh` — one producer, so the example in a
# test and the output of an assembly cannot be different things. A change to
# the naming rule reddens these cases; it cannot quietly leave them describing
# a convention the deployment stopped using.
# ---------------------------------------------------------------------------

const
  digestOfBuildOne = "9f2b1c4d8e7a6b5c"
  digestOfBuildTwo = "0a1b2c3d4e5f6071"
    ## Two digests, because the property `immutable` rests on is that DIFFERENT
    ## BYTES GET A DIFFERENT ADDRESS. `assetDigestLength` characters each, which
    ## is what a real SHA-256 is truncated to.

proc publishedDeployment(digest: string): DeploymentDescriptor =
  ## What a bundle assembled by `web-bundle-assets.sh` declares: every
  ## `/assets/` row in the manifest, published under its content-addressed name.
  ##
  ## The split between `modules` and `assets` is the manifest's `DeliveryMode`,
  ## exactly as the assembly step splits it — a `damFetched` row is something a
  ## worker resolves by id, anything else under `/assets/` is a script loaded by
  ## URL.
  result.origin = "https://ide.example.test"
  result.revision = "abc1234"
  let prefix = staticAssetPrefix[1 .. ^1]
  for asset in webRuntimeAssets():
    if not asset.path.startsWith(prefix): continue
    let url = "/" & contentAddressedPath(asset.path, digest)
    if asset.mode == damFetched:
      result.modules.add DeployedModule(
        id: asset.id, url: url, bytes: 4096,
        builtFrom: "codetracer abc1234 test fixture")
    else:
      result.assets.add PublishedAsset(id: asset.id, url: url, bytes: 4096)

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
    let contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
    let rendered = renderRewriteConfig(contract)
    check "  200" in rendered
    check "301" notin rendered
    check "302" notin rendered
    for prefix in rewritePrefixes():
      check (prefix & "/*") in rendered

  test "the three cache classes are keyed on prefix, with distinct headers":
    let contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
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
    check cacheClassFor("/noir") == ccEntryDocument

    # THE TWO `/assets/` ADDRESSES ARE BOTH REAL, and neither is illustrative.
    #
    # `hashedWorker` is what the assembly step publishes — formed here by the
    # same `contentAddressedPath` that forms it there, so this line cannot go on
    # describing a convention the bundle has stopped using. It replaced
    # `/assets/app.9f2b1c.js`, a filename nothing has ever produced, whose
    # presence here was how `ccStaticAsset` came to be the only class anyone
    # checked while three stable-named files quietly carried its header.
    #
    # `wasmWorkerScriptPath` is the pre-rename manifest name, and it stays as
    # the `ccMutableAsset` example for a reason that is not symmetry: it is
    # exactly what a file added to `/assets/` WITHOUT going through the rename
    # would look like, and the class that answers for it is what stops the whole
    # directory promising more than it can keep.
    let hashedWorker = "/" & contentAddressedPath(wasmWorkerScriptPath,
                                                  digestOfBuildOne)
    check cacheClassFor(hashedWorker) == ccStaticAsset
    check cacheClassFor("/" & wasmWorkerScriptPath) == ccMutableAsset
    check hashedWorker != "/" & wasmWorkerScriptPath

    var seen: set[CacheClass] = {}
    for address in ["/", "/noir", "/noir/new", "/s/9f2b1c",
                    "/p/hello-world-3f9a2c",
                    "/p/hello-world-3f9a2c/current.json",
                    hashedWorker, "/" & wasmWorkerScriptPath,
                    "/projects"]:
      seen.incl cacheClassFor(address)
    for class in CacheClass:
      check class in seen

  test "no asset this deployment publishes is served `immutable` under a stable name":
    ## THE INVARIANT, over the paths a deployment actually ships rather than
    ## over an illustrative string.
    ##
    ## `immutable` tells a cache the bytes at a URL will never change. That is
    ## true of a content-addressed name and false of every other kind, and when
    ## it is false the cache is right and we are wrong: after deploy `2fb3afa6`
    ## both custom domains served a 36-hour-old `assets/wasm-worker.js` with
    ## `cf-cache-status: HIT`, through a deploy that had uploaded the new one.
    ##
    ## Checked in both directions so neither half can rot:
    ##   * every unhashed published asset resolves to a revalidating class, and
    ##   * the `/assets/*` rule the CDN actually receives carries that class.
    ## THE ARM THAT KEEPS THE RULE HONEST, over a deployment that publishes one
    ## stable name beside five hashed ones — which is what an asset added to
    ## `/assets/` without going through the rename produces.
    var mixed = publishedDeployment(digestOfBuildOne)
    mixed.assets.add PublishedAsset(
      id: "hand-added", url: "/assets/hand-added.js", bytes: 10)
    check unhashedStaticAssets(mixed) == @["/assets/hand-added.js"]
    for path in unhashedStaticAssets(mixed):
      check cacheClassFor(path) == ccMutableAsset
      check "immutable" notin headerFor(cacheClassFor(path))

    let mixedContract = deploymentContract("https://ide.example.test", mixed)
    for rule in mixedContract.caches:
      if "immutable" in rule.headerValue:
        # Whatever the glob covers must be content-addressed. `/s/*` is, by
        # construction — a snapshot id IS the digest. `/assets/*` is not, on a
        # deployment with one stable name in it, however many hashed files sit
        # beside it: a `_headers` glob has to be right for its weakest member.
        check rule.pattern == snapshotPrefix & "*"

  test "the `/assets/*` glob follows the digests, not the directory":
    ## The self-upgrading half, and it has now upgraded. Nobody had to remember
    ## to flip a header the day content-hashed filenames landed: the rule is
    ## derived from the published set, so it tightened on its own — this case
    ## was written when it answered `ccMutableAsset` and asserts `ccStaticAsset`
    ## today, over the same two lines of `staticAssetGlobClass`.
    check assetIsContentAddressed("/assets/ui.deadbeefcafe.js")
    check not assetIsContentAddressed("/assets/wasm-worker.js")
    check not assetIsContentAddressed("/assets/noir_wasm.wasm")
    check not assetIsContentAddressed("/index.html")
    # Too short to be a digest, and a version suffix must not be mistaken for
    # one — `immutable` on `app.v2.js` would be the same defect with a nicer
    # name.
    check not assetIsContentAddressed("/assets/app.v2.js")
    check not assetIsContentAddressed("/assets/app.1234.js")

    # THE PUBLISHED SET, COUNTED, AND THE COUNT ASSERTED. "Every published asset
    # carries a digest" is true of a deployment that published none, so the size
    # of the set is part of the claim rather than a preamble to it.
    let published = publishedDeployment(digestOfBuildOne)
    check publishedStaticAssets(published).len == declaredStaticAssetStems().len
    check publishedStaticAssets(published).len == 6
    for path in publishedStaticAssets(published):
      check assetIsContentAddressed(path)
    check unhashedStaticAssets(published).len == 0
    check staticAssetGlobClass(published) == ccStaticAsset
    check headerFor(staticAssetGlobClass(published)) == immutableHeader

    # AND BY NAME, because six of six is a number some other six files could
    # make. These are the files the 2026-09-01 staleness was found on, and the
    # two the engine needs; a rename that dropped one would keep the count.
    var byStem: seq[string]
    for path in publishedStaticAssets(published):
      byStem.add contentAddressedStem(path)
    for expected in ["/" & wasmWorkerScriptPath,
                     "/" & noirCompilerWasmPath,
                     "/" & noirTracerWasmPath,
                     "/" & replayWorkerScriptPath,
                     "/" & replayEngineGluePath,
                     "/" & replayEngineWasmPath]:
      check expected in byStem

    # THE EMPTY DEPLOYMENT DOES NOT EARN IT. Without this the derivation would
    # be satisfied by a descriptor whose `assets` array failed to parse — a
    # universal claim over nothing, answering `immutable`, which is the shape of
    # the check that reported `ok: 0/0 published files match` and exited 0.
    let nothingPublished = DeploymentDescriptor(origin: "https://ide.example.test")
    check publishedStaticAssets(nothingPublished).len == 0
    check unhashedStaticAssets(nothingPublished).len == 0
    check staticAssetGlobClass(nothingPublished) == ccMutableAsset

  test "a deploy changes the URL, which is what makes `immutable` true":
    ## THE PROPERTY THE WHOLE RENAME EXISTS FOR. `immutable` tells a cache the
    ## bytes at a URL never change; that is only safe if new bytes go to a new
    ## URL, and nothing else in this file would notice a naming scheme that
    ## returned a constant, hashed the FILENAME, or used the build revision —
    ## all of which satisfy `assetIsContentAddressed` while re-publishing over
    ## an address a CDN has been promised will never change.
    let one = publishedDeployment(digestOfBuildOne)
    let two = publishedDeployment(digestOfBuildTwo)
    check publishedStaticAssets(one).len == publishedStaticAssets(two).len
    check publishedStaticAssets(one).len > 0
    var moved = 0
    for i in 0 ..< publishedStaticAssets(one).len:
      let before = publishedStaticAssets(one)[i]
      let after = publishedStaticAssets(two)[i]
      check before != after
      # And it is the same FILE at a new address, not a different file: the
      # stems must agree, or this would pass over a scheme that renamed things
      # at random.
      check contentAddressedStem(before) == contentAddressedStem(after)
      check assetIsContentAddressed(after)
      inc moved
    check moved == publishedStaticAssets(one).len
    check moved == 6

    # Both deployments still earn `immutable` — the address moved, the promise
    # did not weaken.
    check staticAssetGlobClass(one) == ccStaticAsset
    check staticAssetGlobClass(two) == ccStaticAsset

  test "the published name and the manifest name convert both ways":
    ## `contentAddressedStem` is what every path-deriving check uses to find a
    ## file it knows by its manifest name, and a digest in the name is precisely
    ## where such a check stops matching — by finding nothing, which reads as
    ## nothing wrong. `deployGuardDefects`' published-but-undeclared arm is the
    ## one that would have gone silently vacuous.
    var round = 0
    for stem in declaredStaticAssetStems():
      let published = "/" & contentAddressedPath(stem[1 .. ^1], digestOfBuildOne)
      check contentAddressedStem(published) == stem
      inc round
    check round == declaredStaticAssetStems().len
    check round == 6
    # A path with no digest is its own stem, so a check that maps every served
    # path through this does not lose the ones that were never renamed.
    check contentAddressedStem("/index.html") == "/index.html"
    check contentAddressedStem("/" & wasmWorkerScriptPath) ==
      "/" & wasmWorkerScriptPath

  test "a name the producer forms is a name the predicate accepts":
    ## The two halves of the convention, compared on real inputs rather than on
    ## an illustrative one. `ci/test/web_asset_name.nim` makes the same
    ## assertion at assembly time and refuses to publish a name that fails it,
    ## so a change to either function fails a build rather than making a site
    ## quietly slower.
    var formed = 0
    for stem in declaredStaticAssetStems():
      let named = contentAddressedPath(stem[1 .. ^1], digestOfBuildOne)
      check named.len > 0
      check named != stem[1 .. ^1]
      check assetIsContentAddressed("/" & named)
      # The extension is preserved, because a static host reads it to choose a
      # `Content-Type` and `WebAssembly.instantiateStreaming` refuses anything
      # that is not `application/wasm` by name.
      check named.endsWith("." & stem.rsplit('.', 1)[1])
      inc formed
    check formed == 6
    # A digest that could not make the name content-addressed produces nothing,
    # rather than a plausible path that quietly fails to earn `immutable`.
    check contentAddressedPath("assets/wasm-worker.js", "abc") == ""
    check contentAddressedPath("assets/wasm-worker.js", "zzzzzzzzzzzzzzzz") == ""
    check contentAddressedPath("assets/noextension", digestOfBuildOne) == ""

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

    let contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
    # THE ADDRESSES THIS DEPLOYMENT CAN ACTUALLY SERVE, and the `/assets/` ones
    # are the published set rather than an illustrative hashed name.
    #
    # `/assets/app.9f2b1c.js` used to stand here, and it cannot: a `_headers`
    # glob applies ONE rule to the whole directory, so a per-path classifier
    # that answers `ccStaticAsset` for a hashed name and a table that must
    # cover the directory's weakest member will always disagree on a filename
    # the deployment does not contain. Asserting agreement on fiction forces
    # the table to be wrong about fact — which is the shape of the original
    # defect, not a fix for it: the hashed example is exactly what let
    # `immutable` sit on three stable-named files for a year.
    var addresses = @["/", "/noir", "/noir/new", "/s/9f2b1c",
                      "/p/hello-world-3f9a2c",
                      "/p/hello-world-3f9a2c/current.json",
                      "/projects"]
    addresses.add publishedStaticAssets(publishedDeployment(digestOfBuildOne))
    check publishedStaticAssets(publishedDeployment(digestOfBuildOne)).len == 6
      # The loop must not be vacuous, and the count is asserted rather than
      # merely non-zero: `> 0` is satisfied by one asset, and the whole point of
      # the glob is that it has to be right for all six at once.
    for address in addresses:
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
    var contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
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
    let contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
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
    check deploymentContract("https://a.example",
                             publishedDeployment(digestOfBuildOne)).origin ==
      "https://a.example"
    check deploymentContract("https://b.example",
                             publishedDeployment(digestOfBuildOne)).origin ==
      "https://b.example"
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
    check "wasm-worker" in ids
    # AND NOT A SECOND NIM BUNDLE. `web-entry` was a required asset until NS9:
    # `web.js` called `boot()` and `ui.js` rendered, in two separately compiled
    # programs, so the renderer's `ctPlatform()` was never the platform
    # `boot()` installed. The renderer boots itself now, and a `web-entry`
    # reappearing here is that defect coming back.
    check "web-entry" notin ids
    # The document itself is required too, and it is the one that was missing:
    # `renderRewriteConfig` has always emitted `/index.html` as the target of
    # every prefix while nothing produced such a file, so a deployment would
    # have served the rewrites and 404'd every one of them.
    check "entry-document" in ids
    # THE THREE THE RENDERER CANNOT RUN WITHOUT, and the reason they are
    # `required` rather than `optional` with a degradation sentence: there is
    # no degraded product without them, only a blank page. `ui.js` reads
    # `monaco` at module scope, so a deployment missing the third-party bundle
    # does not lose a feature — the renderer throws `ReferenceError` during
    # module initialisation and mounts nothing at all. That is what
    # `ide.codetracer.com` served for a week.
    check "third-party-bundle" in ids
    check "renderer-theme" in ids
    check "renderer-loader-styles" in ids
    # Counted, so an asset silently losing `required` is caught. Asserting only
    # membership would pass over a manifest that had gained three more —
    # which is exactly what happened here, and this line is what said so.
    #
    # 7 -> 6: `web-entry` left, and the count is lowered in the same commit
    # that removes it so the reduction is RECORDED rather than absorbed. A
    # count that quietly tracked the manifest would let the second bundle
    # return without anything noticing.
    check required.len == 6

  test "the renderer is BUNDLED and the worker is a separate ASSET":
    # Not a stylistic distinction. `new Worker(url)` takes a URL and
    # `newBrowserWasmHost(registry, scriptUrl)` already has the parameter, so
    # an inlined worker would have to be revived as a `blob:` URL — which a
    # real Content-Security-Policy rejects.
    var byId: seq[tuple[id: string, mode: DeliveryMode]]
    for asset in webRuntimeAssets(): byId.add (asset.id, asset.mode)
    check (id: "renderer", mode: damBundled) in byId
    check (id: "wasm-worker", mode: damAsset) in byId

  test "the two Noir modules and the replay engine are FETCHED, never bundled":
    # ~16 MB, ~4.6 MB and ~18 MB. Bundling any of them inflates it by a third
    # as base64 and puts the result in front of first paint, for a capability
    # most sessions never invoke.
    #
    # THE ENGINE IS A DECLARED ADDITION TO THIS LIST, not an accident of the
    # count. It was published at `/pkg/db_backend_bg.wasm` and `/worker.js`
    # and asserted by the deploy workflow while `webRuntimeAssets()` did not
    # name it — so the entry document carried no URL for it, and the one
    # function that turns an asset into something the browser can reach
    # (`declaredModuleUrls`) had nothing to hand over. `ide.codetracer.com`
    # served 18 MB of working engine that nothing could reference.
    let fetched = fetchedRuntimeAssets()
    var ids: seq[string]
    for asset in fetched: ids.add asset.id
    check ids.sorted == @[noirCompilerModuleId, noirTracerModuleId,
                          replayEngineGlueId, replayEngineModuleId].sorted
    for asset in fetched:
      check asset.mode == damFetched
      check asset.mode != damBundled

  test "a fetched asset says WHO fetches it, in both directions":
    # `damFetched` meant "a Noir wasm module" for as long as it had exactly
    # two members, because `deliverableModuleIds()` was `fetchedRuntimeAssets()`
    # spelled differently. A third fetched row would have joined the Noir
    # registry by arithmetic and the page would have claimed `nargo` over a
    # wasm-bindgen module with no `nv_*` ABI.
    check fetchedWithoutConsumer().len == 0
    var noirIds, engineIds: seq[string]
    for asset in noirWasmModuleAssets(): noirIds.add asset.id
    for asset in replayEngineAssets(): engineIds.add asset.id
    check noirIds.sorted == @[noirCompilerModuleId, noirTracerModuleId].sorted
    check engineIds.sorted == @[replayEngineGlueId, replayEngineModuleId].sorted
    # Counted, and disjoint: the two lists partition the fetched set, so an
    # asset joining one of them silently cannot also be leaving the other.
    check noirIds.len + engineIds.len == fetchedRuntimeAssets().len
    for id in engineIds:
      check id notin noirIds

  test "the engine is BOTH files or the deployment does not have one":
    # The glue without the wasm imports bytes that are not there; the wasm
    # without the glue is 18 MB nothing can call into. Declaring one is worse
    # than declaring neither, because the session would report an engine and
    # then fail inside `WebAssembly.compileStreaming`.
    check replayEngineAssets().len == 2
    var paths: seq[string]
    for asset in replayEngineAssets(): paths.add asset.path
    check replayEngineGluePath in paths
    check replayEngineWasmPath in paths
    # And the worker that instantiates them is an ASSET, not a fetched module:
    # `new Worker(url)` takes a same-origin URL and cannot take bytes.
    var workerMode = damBundled
    for asset in webRuntimeAssets():
      if asset.id == replayWorkerModuleId: workerMode = asset.mode
    check workerMode == damAsset

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

  test "the fetched modules and the worker are served under the asset prefix":
    # They must land under the prefix that has its OWN cache rule, or a CDN
    # serves a 16 MB module with the entry document's 60-second TTL. That was
    # this test's real subject and it is unchanged.
    #
    # WHAT CHANGED, and why the old assertion had to go. It also demanded
    # `ccStaticAsset` and `immutableHeader` by name — it required the bug. On
    # 2026-09-01 that year-long `immutable`, sitting on three STABLE filenames,
    # pinned a 36-hour-old `assets/wasm-worker.js` at both custom domains
    # through a deploy that had uploaded the new one; the CDN was entitled to
    # it, because `immutable` is a promise the bytes never change and these
    # names do not carry a digest to make that true.
    #
    # So the assertion is now the property actually wanted — a class of its
    # own, distinct from the document's — plus the invariant that `immutable`
    # is reserved for names that earn it. The assembly step emits digests now,
    # and this test did keep passing across that change: what moved is that the
    # class is read at the PUBLISHED address rather than at the manifest one,
    # because those are no longer the same string and the manifest one is served
    # by nobody.
    let deployed = publishedDeployment(digestOfBuildOne)
    var graded = 0
    for asset in webRuntimeAssets():
      if asset.mode notin {damBundled, damEntryDocument}:
        check asset.path.startsWith(staticAssetPrefix[1 .. ^1])
        let url = publishedUrl(deployed, asset.id)
        check url.len > 0
        let class = cacheClassFor(url)
        check class == staticAssetGlobClass(deployed)
        check class notin {ccEntryDocument, ccPointer}
        check headerFor(class) != entryDocumentHeader
        inc graded
        if "immutable" in headerFor(class):
          check assetIsContentAddressed(url)
    # Every non-bundled row was graded, and how many there are is part of the
    # claim: a `continue` that stopped matching would leave this loop silent.
    check graded == 6

  test "and the entry document is the one thing that must NOT be immutable":
    # The mirror of the case above, and the reason `damEntryDocument` is its
    # own mode rather than a `damAsset` that happens to sit at the root. Filing
    # the document under `/assets/` would have earned it
    # `max-age=31536000, immutable` — a year of a stale application shell, from
    # a cache nobody can reach to purge. `cacheClassFor`'s header already
    # records this exact mistake being made in the other direction.
    var found = false
    for asset in webRuntimeAssets():
      if asset.mode != damEntryDocument: continue
      found = true
      check asset.path == entryDocumentPath
      check not asset.path.startsWith(staticAssetPrefix[1 .. ^1])
      check cacheClassFor("/" & asset.path) == ccEntryDocument
      check headerFor(cacheClassFor("/" & asset.path)) == entryDocumentHeader
      check headerFor(cacheClassFor("/" & asset.path)) != immutableHeader
    check found

  test "no two assets claim the same path":
    # A duplicate path is a build step that overwrites its own output, and it
    # would be invisible: the last writer wins and the bundle looks complete.
    var seen: seq[string]
    for asset in webRuntimeAssets():
      check asset.path notin seen
      check asset.path.len > 0
      seen.add asset.path

# ---------------------------------------------------------------------------
# What a deployment SAYS it delivered.
#
# The manifest above is INTENT — what a bundle must carry. These cases pin the
# statement of FACT the entry document carries, which is what stops a page
# deriving its capabilities from the manifest and thereby claiming a toolchain
# on every build including the ones that ship none.
# ---------------------------------------------------------------------------

  test "the descriptor survives the document it travels in":
    # It is rendered into HTML and read back out of HTML, so the round trip is
    # the assertion — not `render` and `parse` agreeing in isolation, which
    # they would even if the document swallowed the element.
    let workerUrl = "/" & contentAddressedPath(wasmWorkerScriptPath,
                                               digestOfBuildOne)
    let descriptor = DeploymentDescriptor(
      origin: "https://ide.codetracer.com", revision: "abc1234",
      modules: @[
        DeployedModule(id: noirCompilerModuleId,
                       url: "/" & noirCompilerWasmPath, bytes: 15862494,
                       builtFrom: "noir@codetracer 6c590c7789 compiler/wasm")],
      assets: @[
        PublishedAsset(id: wasmWorkerAssetId, url: workerUrl, bytes: 35525)])
    let document = renderEntryDocument(descriptor)
    check document.contains("id=\"" & deploymentDescriptorElementId & "\"")
    # The page must reference the renderer, or it is a document that can never
    # boot whatever else is right about it.
    check document.contains("src=\"/" & rendererBundlePath & "\"")

    # AND IT MUST REFERENCE EXACTLY ONE NIM BUNDLE — NS9, asserted as a COUNT
    # rather than as an absence, because "does not contain web.js" would pass
    # just as happily over a document that referenced no bundle at all.
    #
    # The document used to load two: `web.js` called `boot()` and `ui.js`
    # rendered. `installPlatform` writes a module-level `var` in
    # `platform/platform.nim` and `nim js` gives each compiled program its own,
    # so the renderer's `ctPlatform()` was never the platform `boot()`
    # installed — it was `uninstalledProfile`, on every load, with the Noir
    # compiler this deployment serves sitting unreachable behind it.
    #
    # This case is the regression guard for the merge. A second Nim bundle
    # reappearing in this document is that defect returning, and it would
    # otherwise return silently: both bundles would load, both would be 200,
    # the boot line would still say `ok`, and only a Build button would know.
    var nimBundleRefs = 0
    for candidate in [rendererBundlePath, "web.js"]:
      if document.contains("src=\"/" & candidate & "\""): nimBundleRefs += 1
    check nimBundleRefs == 1
    check not document.contains("src=\"/web.js\"")

    let opened = document.find(">", document.find(
      "id=\"" & deploymentDescriptorElementId & "\"")) + 1
    let closed = document.find("</script>", opened)
    let parsed = parseDeploymentDescriptor(document[opened ..< closed])
    check parsed.origin == descriptor.origin
    check parsed.revision == descriptor.revision
    check parsed.modules.len == 1
    check parsed.modules[0].id == noirCompilerModuleId
    check parsed.modules[0].bytes == 15862494
    check parsed.modules[0].builtFrom.len > 0

    # AND THE WORKER SCRIPT'S URL, THROUGH THE ACCESSOR THE PRODUCT CALLS.
    #
    # This is the half of the round trip that would fail SILENTLY and that no
    # deploy gate looks at. `host/web_browser.nim` asks
    # `assetUrl(deployment, wasmWorkerAssetId)` and answers `noWasmModules()`
    # for an empty string — correct behaviour for a deployment that shipped no
    # worker, and indistinguishable from one whose `assets` array did not
    # survive the document. The deployed-page probe asserts a SURFACE (the
    # welcome screen, the template) and a page with no toolchain mounts exactly
    # the same surface, so the first report would be a user finding that Build
    # does nothing.
    #
    # Asserted through `assetUrl` rather than by reading `parsed.assets[0]`
    # because the accessor is what the product depends on; a field that
    # round-trips into a list nothing can look up is not delivery.
    check parsed.assets.len == 1
    check assetUrl(parsed, wasmWorkerAssetId) == workerUrl
    check assetIsContentAddressed(assetUrl(parsed, wasmWorkerAssetId))
    check parsed.assets[0].bytes == 35525
    # An id this deployment did not publish is "", which is the answer the
    # caller branches on. Checked here so the accessor cannot start inventing
    # a stem for a missing row.
    check assetUrl(parsed, "no-such-asset") == ""

  test "a document that could truncate itself does not":
    # `</script>` inside the JSON would end the element early and take the rest
    # of the page with it. The descriptor carries build-environment strings — a
    # branch name reaches `revision` — so this is reachable, and a page that
    # can be truncated by its own metadata fails with a syntax error naming
    # nothing.
    let hostile = DeploymentDescriptor(
      origin: "https://ide.codetracer.com",
      revision: "</script><script>alert(1)</script>")
    let document = renderEntryDocument(hostile)
    check not document.contains("<script>alert(1)")
    # And it is still readable: escaping must not cost the round trip.
    let opened = document.find(">", document.find(
      "id=\"" & deploymentDescriptorElementId & "\"")) + 1
    let closed = document.find("</script>", opened)
    check parseDeploymentDescriptor(document[opened ..< closed]).revision ==
      hostile.revision

  test "an unreadable descriptor is an empty deployment, never a crash":
    # A page that throws during boot is a blank screen; a page that reads no
    # modules says, by name, that it ships no toolchain. The second is better
    # AND true, so malformed input takes it.
    check parseDeploymentDescriptor("").modules.len == 0
    check parseDeploymentDescriptor("   ").modules.len == 0
    check parseDeploymentDescriptor("{not json").modules.len == 0
    check parseDeploymentDescriptor("[1,2,3]").modules.len == 0
    check parseDeploymentDescriptor("{\"modules\":\"nope\"}").modules.len == 0

  test "a module with no provenance is dropped rather than half-declared":
    # `registrableModules` discards a module with an empty `builtFrom`, so a
    # descriptor that kept one would advertise a module the tab then refuses —
    # the deployment and the product disagreeing quietly.
    let parsed = parseDeploymentDescriptor(
      "{\"modules\":[" &
      "{\"id\":\"noir-tracer\",\"url\":\"/a.wasm\",\"bytes\":1}," &
      "{\"id\":\"noir-compiler\",\"url\":\"/b.wasm\",\"bytes\":2," &
      "\"builtFrom\":\"noir@codetracer deadbeef compiler/wasm\"}]}")
    check parsed.modules.len == 1
    check parsed.modules[0].id == noirCompilerModuleId

  test "the deploy guard fails in BOTH directions":
    # The two failures a sibling campaign met in one day. A guard catching only
    # one of them would have been green on the other, and which one it met was
    # decided by which edit somebody made.
    #
    # THE URLS ARE THE PUBLISHED ONES, not the manifest ones. They used to be
    # `"/" & noirCompilerWasmPath` — the stems — and that stopped being a
    # description of any deployment when the assembly step began renaming what
    # it places. The guard's published-but-undeclared arm is matched through
    # `contentAddressedStem` for exactly this reason: it asked whether the STEM
    # was served, and once nothing serves a stem it would have found nothing
    # every time and reported no defects at all.
    let compilerUrl = "/" & contentAddressedPath(noirCompilerWasmPath,
                                                 digestOfBuildOne)
    let tracerUrl = "/" & contentAddressedPath(noirTracerWasmPath,
                                               digestOfBuildOne)
    let both = DeploymentDescriptor(modules: @[
      DeployedModule(id: noirCompilerModuleId, url: compilerUrl, bytes: 10,
                     builtFrom: "noir@codetracer deadbeef compiler/wasm"),
      DeployedModule(id: noirTracerModuleId, url: tracerUrl, bytes: 20,
                     builtFrom: "noir@codetracer deadbeef tooling/tracer_wasm")])

    # Agreement is silence.
    check deployGuardDefects(both, @[compilerUrl, tracerUrl]).len == 0

    # Declared and not published: the worker's fetch would 404.
    let missing = deployGuardDefects(both, @[compilerUrl])
    check missing.len == 1
    check missing[0].contains(tracerUrl)

    # Published and not declared: bytes nothing can reach — the still frame.
    # The served paths carry digests here, so this arm also proves the stem
    # match works: an equality test against the manifest path would find neither
    # file and report a clean deployment.
    let orphan = deployGuardDefects(DeploymentDescriptor(),
                                    @[compilerUrl, tracerUrl])
    check orphan.len == 2

    # PUBLISHED UNDER A STABLE NAME. Its own arm, reddening its own assertion:
    # the deployment is otherwise perfectly consistent — declared, served, sizes
    # agreeing — and the only thing wrong is that `immutable` cannot be promised
    # over it, which would otherwise show up as nothing but a slower site.
    let stableNamed = DeploymentDescriptor(modules: @[
      DeployedModule(id: noirCompilerModuleId, url: "/" & noirCompilerWasmPath,
                     bytes: 10,
                     builtFrom: "noir@codetracer deadbeef compiler/wasm")])
    let stableDefects = deployGuardDefects(stableNamed,
                                           @["/" & noirCompilerWasmPath])
    check stableDefects.len == 1
    check stableDefects[0].contains(noirCompilerWasmPath)
    check stableDefects[0].contains("stable name")

    # A WORKER SCRIPT DECLARED AND NOT PUBLISHED, which the guard could not see
    # at all before the descriptor carried `assets[]`: its URL was a constant,
    # so there was nothing for a deployment to be wrong about.
    let workerUrl = "/" & contentAddressedPath(wasmWorkerScriptPath,
                                               digestOfBuildOne)
    let workerMissing = deployGuardDefects(
      DeploymentDescriptor(assets: @[
        PublishedAsset(id: wasmWorkerAssetId, url: workerUrl, bytes: 7)]), @[])
    check workerMissing.len == 1
    check workerMissing[0].contains(workerUrl)

    # A deployment that ships nothing and declares nothing is CORRECT, and the
    # guard must not invent a defect for the supported configuration.
    check deployGuardDefects(DeploymentDescriptor(), @[]).len == 0

    # And the assembly step's own output is accepted, which is the arm that
    # would catch a rename the guard cannot follow.
    let real = publishedDeployment(digestOfBuildOne)
    var servedByReal: seq[string]
    for path in publishedStaticAssets(real): servedByReal.add path
    check servedByReal.len == 6
    check deployGuardDefects(real, servedByReal).len == 0

  test "modules with no worker to run them in are not a delivered toolchain":
    ## THE IMPLICATION CONTENT-ADDRESSED FILENAMES BROKE, restored as a value.
    ##
    ## `wasmWorkerScriptPath` was a compile-time constant, so "the descriptor
    ## names modules" entailed "there is a worker to run them in" — the second
    ## fact could not fail by itself. The worker is now published under a
    ## digest and declared like anything else, so a document can name two Noir
    ## modules and no worker; ungated, that tab reports
    ## `toolchain=nargo:compile+trace` on its boot line while every run
    ## refuses, which is the one thing `host/web_browser.nim`'s header forbids.
    ##
    ## Asserted here because `web_browser.nim` is compiled by a compile-ONLY
    ## lane and can host no assertion of its own.
    let workerUrl = "/" & contentAddressedPath(wasmWorkerScriptPath,
                                               digestOfBuildOne)
    let modules = @[
      DeployedModule(id: noirCompilerModuleId,
                     url: "/" & contentAddressedPath(noirCompilerWasmPath,
                                                     digestOfBuildOne),
                     bytes: 10, builtFrom: "noir@codetracer deadbeef c"),
      DeployedModule(id: noirTracerModuleId,
                     url: "/" & contentAddressedPath(noirTracerWasmPath,
                                                     digestOfBuildOne),
                     bytes: 20, builtFrom: "noir@codetracer deadbeef t")]

    # With a worker: everything the document declares is runnable.
    let withWorker = DeploymentDescriptor(
      modules: modules,
      assets: @[PublishedAsset(id: wasmWorkerAssetId, url: workerUrl, bytes: 7)])
    check declaresNoirWasmWorker(withWorker)
    check noirRunnableModules(withWorker).len == 2

    # WITHOUT ONE: none of them is, and the count is asserted on BOTH sides so
    # neither arm can be satisfied by an empty modules list.
    let withoutWorker = DeploymentDescriptor(modules: modules)
    check not declaresNoirWasmWorker(withoutWorker)
    check withoutWorker.modules.len == 2
    check noirRunnableModules(withoutWorker).len == 0

    # AND THE URLS STILL REACH A WORKER THAT DOES EXIST. `declaredModuleUrls`
    # is deliberately NOT gated: it is what a `configure` message carries, and
    # a worker that exists must be told about everything published. Gating it
    # would produce a worker running with no modules — a different defect
    # wearing the same fix.
    check declaredModuleUrls(withoutWorker).len == 2

    # The replay engine is a different consumer with its own script, so an
    # absent NOIR worker must not hide it; `ui/web_replay_host.nim` refuses by
    # name on its own row.
    let engineOnly = DeploymentDescriptor(
      modules: @[DeployedModule(id: replayEngineModuleId,
                                url: "/" & contentAddressedPath(
                                  replayEngineWasmPath, digestOfBuildOne),
                                bytes: 30, builtFrom: "codetracer abc1234")],
      assets: @[PublishedAsset(id: replayWorkerModuleId,
                               url: "/" & contentAddressedPath(
                                 replayWorkerScriptPath, digestOfBuildOne),
                               bytes: 9)])
    check assetUrl(engineOnly, replayWorkerModuleId).len > 0
    check declaredModuleUrls(engineOnly).len == 1

  test "the worker is configured with the urls the descriptor declares":
    # `declaredModuleUrls` is what reaches the worker's `configure` message.
    # The worker looks its modules up by these exact ids, so a rename that did
    # not reach both sides produces "no url declared for wasm module" in a
    # browser and nothing at all before that.
    let descriptor = DeploymentDescriptor(modules: @[
      DeployedModule(id: noirTracerModuleId, url: "/" & noirTracerWasmPath,
                     bytes: 1, builtFrom: "noir@codetracer deadbeef t")])
    let urls = declaredModuleUrls(descriptor)
    check urls.len == 1
    check urls[0].id == noirTracerModuleId
    check urls[0].url == "/" & noirTracerWasmPath

# ---------------------------------------------------------------------------
# The entry route — the layer that was correct, tested and never called
# ---------------------------------------------------------------------------
#
# Everything below `classifyPath` in this file already passed before
# `https://ide.codetracer.com/noir` opened the welcome screen, and that is the
# point of the block: a classifier can be right about every input while nothing
# asks it anything. These tests are over the two values the wiring added — the
# template a language selects, and the rewrite target a host is given — and the
# assertion that the product actually consults them is a DOM assertion in
# `ci/test/web-renderer-mounts.sh` (arms R and S), because it cannot be made
# here.

suite "the bundled template a language entry selects":
  test "rule 0: every known language entry has a template, and none is empty":
    ## The agreement rule 0 needs and `knownLanguageEntries` cannot state
    ## alone. Adding `"cairo"` to that array and stopping there resolves
    ## `/cairo` to `evTemplate` and then has nothing to open — a route that
    ## mounts a blank surface, which is the failure this campaign keeps
    ## finding one layer down.
    check languagesWithoutTemplate().len == 0
    # NON-VACUITY: the check above is also true of an empty language list.
    check knownLanguageEntries.len > 0
    for language in knownLanguageEntries:
      check templateFor(language).hasFiles

  test "the language-neutral root selects NO template, and that is rule 0":
    ## `/` classifies as `efBare` with an EMPTY `languageEntry`, and rule 0 —
    ## "the language is an entry point, not a namespace" — is why that must
    ## not fall back to Noir. Defaulting here would make Noir the product's
    ## default language, which is the permanent classification rule 0 refuses,
    ## and it is also what would have made the fix for `/noir` silently change
    ## what `/` does.
    check classifyPath("/").language.len == 0
    check not templateFor("").hasFiles
    check not templateFor("cairo").hasFiles
    check templateFor("noir").hasFiles

  test "the template is a directory tree, not a single file":
    ## §1a: "Noir projects are directory trees — `src/`, `tests/`,
    ## `Nargo.toml`, multiple modules ... A single-file playground would
    ## misrepresent the language." Asserted as a count and a shape rather than
    ## trusted to whoever edits `noir_template.nim` next.
    let tmpl = templateFor("noir")
    # FIVE, not four: three sources, a `Nargo.toml` and a `Prover.toml`.
    #
    # The inputs file was added when Run became reachable — a `bin` package
    # takes `main`'s arguments from it, and without one the tracer has nothing
    # to encode against the ABI, so the template shipped a project that could
    # be compiled and could not be run.
    # `test_noir_build_marshalling.nim` asserts what is in it.
    check tmpl.templateFileCount == 5
    check tmpl.language == "noir"
    check tmpl.entryFile == "src/main.nr"
    check tmpl.fileContent("src/main.nr").len > 0
    check "mod utils;" in tmpl.fileContent("src/main.nr")
    check tmpl.fileContent("Nargo.toml").len > 0
    let directories = tmpl.templateDirectories
    check directories.len == 1
    check "src" in directories
    # NOT a top-level `tests/` beside `src/`, which is what §1a's mock-up
    # draws. Nargo compiles `src/` and nothing else, so such a directory would
    # be SHOWN in the file tree and never built — measured on the first version
    # of this template: `nargo test` ran 3 of 4 tests and said nothing about
    # the fourth. A first screen teaching a layout that does not work is the
    # "misrepresents the language" failure §1a forbids, one level down.
    check "tests" notin directories
    check tmpl.fileContent("src/tests.nr").len > 0
    check "mod tests;" in tmpl.fileContent("src/main.nr")
    check "mod utils;" in tmpl.fileContent("src/main.nr")

  test "every module the template ships is DECLARED, so nargo compiles it":
    ## The check the `nargo test` count would have failed. A `.nr` file under
    ## `src/` that no `mod` statement names is dead: it appears in the file
    ## tree, contributes nothing, and its tests never run — silently, which is
    ## the whole problem.
    let tmpl = templateFor("noir")
    let root = tmpl.fileContent("src/main.nr")
    # THE SUBJECT IS THE SOURCES, and it has to be selected rather than
    # assumed. This loop used to skip two named files and require everything
    # else to be a module, which was true while the template carried only
    # `Nargo.toml` and three `.nr` files — and became wrong the moment it grew
    # a `Prover.toml`, which is a manifest-like part of a `bin` package and
    # not a crate module.
    #
    # COUNTED, because a selection that matched nothing would make the whole
    # case pass vacuously — which is exactly what a `continue` list does when
    # a file is renamed.
    var modules = 0
    var manifests = 0
    for file in tmpl.files:
      if not file.path.endsWith(".nr"):
        # `Nargo.toml` and `Prover.toml`: package metadata, not crate sources.
        check not file.path.contains("/")
        inc manifests
        continue
      check file.path[0 ..< 4] == "src/"
      if file.path == "src/main.nr": continue
      let module = file.path[4 ..< file.path.len - 3]
      check ("mod " & module & ";") in root
      inc modules
    check modules == 2
    check manifests == 2

  test "a file the template does not carry degrades rather than raising":
    ## §1b.3 step 5: each part of a link degrades independently. A fragment
    ## naming a file this template has no copy of opens the project at rest.
    check templateFor("noir").fileContent("src/nope.nr") == ""

  test "directories are DERIVED from the files, so none can be a phantom":
    ## A folder list written beside `files` is a second statement of the same
    ## project, and the panel would render a folder the project has no file in
    ## the moment the two disagreed.
    let made = ProjectTemplate(
      language: "x", name: "x", entryFile: "a/b.nr",
      files: @[TemplateFile(path: "a/b.nr", content: "")])
    check made.templateDirectories == @["a"]
    check ProjectTemplate().templateDirectories.len == 0

  test "arriving still writes nothing and mints no address":
    ## Rule 1 held before the template existed and must still hold now that
    ## `/noir` opens a project. `noirHelloWorld()` is a pure value: the same
    ## bytes for a first-time visitor, a returning one and a crawler.
    let first = templateFor("noir")
    let second = templateFor("noir")
    check first.templateFileCount == second.templateFileCount
    check first.fileContent("src/main.nr") == second.fileContent("src/main.nr")
    let resolved = resolveEntry(EntryRequest(path: "/noir"), LocalState())
    check resolved.verdict == evTemplate
    check resolved.languageEntry == "noir"
    check not resolved.writesOnArrival
    check not resolved.mintsServerIdentifier

suite "the rewrite target a static host is actually given":
  test "no rewrite targets a path the host normalises into a redirect":
    ## THE CDN HALF OF THE DEFECT, as a value.
    ##
    ## `renderRewriteConfig` emitted `/index.html` for every prefix, and
    ## Cloudflare Pages answers `/index.html` with a 308 to `/`. Measured on
    ## the live deployment 2026-09-01: `/noir`, `/s`, `/p`, `/projects` and
    ## `/collab/join` — every rule that MATCHED — were redirects, so §1b.4's
    ## "served **200 rather than 302**" was false of the whole table.
    ##
    ## Asserted over `rewriteTargets` rather than by grepping the rendered
    ## text, because the rendered text now contains the string `/index.html`
    ## in a comment explaining this, and a grep would fail for the wrong
    ## reason.
    let contract = deploymentContract("https://ide.example.test",
                                      publishedDeployment(digestOfBuildOne))
    check normalisedRewriteTargets(contract).len == 0
    # NON-VACUITY: an empty target list would also satisfy the check above.
    check rewriteTargets(contract).len == rewritePrefixes().len * 2
    for target in rewriteTargets(contract):
      check target == entryDocumentAddress
    check entryDocumentAddress == "/"
    check entryDocumentAddress != "/" & entryDocumentPath

  test "the rewrite table still covers every entry form, at the new target":
    ## The fix must not have narrowed the contract while changing where it
    ## points. `test_every_entry_form_reaches_the_application` above asserts
    ## the prefixes; this asserts they survived into the rendered file with a
    ## status of 200 and the canonical target.
    let rendered = renderRewriteConfig(
      deploymentContract("https://a.test", publishedDeployment(digestOfBuildOne)))
    for prefix in rewritePrefixes():
      check (prefix & "  " & entryDocumentAddress & "  200") in rendered
      check (prefix & "/*  " & entryDocumentAddress & "  200") in rendered

    # THE STATUS COLUMN, parsed — not a substring search over the whole file.
    #
    # The first version of this check was `"308" notin rendered`, and it failed
    # against a CORRECT table: the generated header comment now explains the
    # 308 this fix exists for, so the digits are in the text while every rule
    # is a 200. That is the "green/red for the wrong reason" shape in
    # miniature, caught by the test going red rather than by review, and the
    # honest instrument is the column a host actually reads.
    var ruleRows = 0
    for line in rendered.splitLines():
      let row = line.strip()
      if row.len == 0 or row[0] == '#': continue
      let columns = row.splitWhitespace()
      check columns.len == 3
      check columns[1] == entryDocumentAddress
      check columns[2] == "200"
      ruleRows += 1
    check ruleRows == rewritePrefixes().len * 2

# ---------------------------------------------------------------------------
# A HOST can be a language entry point — rule 0 on the other axis
# ---------------------------------------------------------------------------
#
# `noirstudio.dev` should mean what `ide.codetracer.com/noir` means: the same
# tree, the same bundle, no redirect, and the visitor stays on the domain they
# typed. Rule 0 already says "the language is an entry point, not a namespace";
# a hostname is another way to enter, and — critically — it must own no more
# than a path prefix does. Projects and snapshots stay language-neutral on both
# hosts, which the last test in this suite is entirely about.
#
# The classifier still contains no origin and matches none: it takes
# `hostLanguage` as a string, so every case below is decidable offline from two
# strings, which is why they can be a table rather than a browser test.

suite "a host can be the language entry point":
  const neutral = ""
  const noirHost = "noir"

  test "the root means the language on a language host, and nothing on the neutral one":
    check classifyPath("/", noirHost).form == efBare
    check classifyPath("/", noirHost).language == "noir"
    check classifyPath("/", neutral).form == efBare
    check classifyPath("/", neutral).language == ""
    # ...which is the whole mechanism: `languageEntry` was always the field
    # that selected the template, so the host changes one string and no branch.
    check resolveEntry(EntryRequest(path: "/"), LocalState(),
                       hostLanguage = noirHost).verdict == evTemplate
    check templateFor(classifyPath("/", noirHost).language).hasFiles
    check not templateFor(classifyPath("/", neutral).language).hasFiles

  test "/noir keeps working on the language host rather than 404ing":
    ## Decided rather than fallen into. `/noir` is a SPELLING of an entry point
    ## (rule 0), and links get pasted between hosts by people who do not know
    ## there are two — a `noirstudio.dev/noir` that failed would be a broken
    ## link produced by nobody making a mistake.
    check classifyPath("/noir", noirHost).form == efBare
    check classifyPath("/noir", noirHost).language == "noir"
    check classifyPath("/noir/", noirHost).form == efBare
    check classifyPath("/noir/new", noirHost).form == efNew
    check classifyPath("/noir/new", noirHost).language == "noir"
    # And it does NOT become a nested namespace.
    check classifyPath("/noir/noir", noirHost).form == efUnknown

  test "/new is the clean start on a language host and unknown on the neutral one":
    ## Rule 5's third row needs an address on a host whose root is already the
    ## language. `/new` is the string `newProjectPath("")` has always produced;
    ## it simply had no meaning until a host could supply the language.
    check classifyPath("/new", noirHost).form == efNew
    check classifyPath("/new", noirHost).language == "noir"
    check classifyPath("/new", neutral).form == efUnknown
    let fresh = resolveEntry(EntryRequest(path: "/new"), LocalState(),
                             hostLanguage = noirHost)
    check fresh.verdict == evTemplate
    check fresh.replacesHistoryEntry
    # §1b.3 step 6 on the neutral host: the template, and a sentence. Never an
    # error page — so this is a supported answer and not a hole.
    let onNeutral = resolveEntry(EntryRequest(path: "/new"), LocalState())
    check onNeutral.verdict == evTemplate
    check onNeutral.explanation.len > 0

  test "the history replacement lands on the root of the host it is on":
    ## Replacing `noirstudio.dev/new` with `/noir` would move the visitor off
    ## the root of the domain they came to — the one outcome "not a mere
    ## redirect, the user stays on this domain" rules out.
    check entryPathOnHost("noir", "noir") == "/"
    check entryPathOnHost("noir", "") == "/noir"
    check entryPathOnHost("", "") == "/"
    check newProjectPathOnHost("noir", "noir") == "/new"
    check newProjectPathOnHost("noir", "") == "/noir/new"

  test "PROJECTS AND SNAPSHOTS RESOLVE IDENTICALLY ON EVERY HOST":
    ## Rule 0's other half, and the one that would be expensive to get wrong:
    ## "Projects and snapshots therefore live at the root, language-neutral."
    ## A `/p/…` link that meant different things on two hosts would be rule 0's
    ## own failure mode — a link breaking because of a classification the
    ## project never asked for — reintroduced on the host axis.
    for path in ["/s/9f2b1c", "/p/hello-world-3f9a2c", "/projects",
                 "/collab/join/tok", "/nope"]:
      let onNeutral = classifyPath(path, neutral)
      let onNoirHost = classifyPath(path, noirHost)
      check onNeutral.form == onNoirHost.form
      check onNeutral.language == onNoirHost.language
      check onNeutral.locator == onNoirHost.locator
    # NON-VACUITY: the loop above would also pass if `hostLanguage` did nothing
    # at all. The root is the case that MUST differ.
    check classifyPath("/", neutral).language != classifyPath("/", noirHost).language

suite "which hosts are language entry points is deployment configuration":
  test "the descriptor carries the host map and survives a round trip":
    var descriptor = DeploymentDescriptor(
      origin: "https://ide.example.test", revision: "abc12345")
    descriptor.languageOrigins.add OriginLanguage(
      origin: "https://noirstudio.example", language: "noir")
    let parsed = parseDeploymentDescriptor(renderDeploymentDescriptor(descriptor))
    check parsed.languageOrigins.len == 1
    check parsed.languageOrigins[0].origin == "https://noirstudio.example"
    check parsed.languageOrigins[0].language == "noir"
    check declaredLanguageOrigins(parsed) == @["https://noirstudio.example=noir"]

  test "the origin is matched WHOLE, and an undeclared host is neutral":
    ## No normalisation, no suffix rule, no wildcard — every one of those is a
    ## place where the product would start deciding which hosts exist, and
    ## which hosts exist is the deployment's fact. A deployment serving `www.`
    ## declares `www.`.
    var descriptor = DeploymentDescriptor()
    descriptor.languageOrigins.add OriginLanguage(
      origin: "https://noirstudio.example", language: "noir")
    check languageForOrigin(descriptor, "https://noirstudio.example") == "noir"
    check languageForOrigin(descriptor, "https://www.noirstudio.example") == ""
    check languageForOrigin(descriptor, "http://noirstudio.example") == ""
    check languageForOrigin(descriptor, "https://ide.codetracer.com") == ""
    check languageForOrigin(descriptor, "") == ""
    # A deployment that declares nothing is a SINGLE-DOMAIN deployment, which
    # is a correct one and is what this product was until now.
    check languageForOrigin(DeploymentDescriptor(), "https://anything") == ""

  test "an origin claiming a language the product does not have is dropped":
    ## At the boundary, not at the mount. Carried through, it would resolve to
    ## `evTemplate` with a `languageEntry` no template answers to — a route
    ## that mounts nothing, which is this campaign's recurring shape.
    let text = """{"origin":"https://a.test","revision":"r","modules":[],
      "languageOrigins":[{"origin":"https://x.test","language":"cairo"},
                         {"origin":"https://y.test","language":"noir"},
                         {"origin":"","language":"noir"},
                         {"origin":"https://z.test","language":""}]}"""
    let parsed = parseDeploymentDescriptor(text)
    check parsed.languageOrigins.len == 1
    check parsed.languageOrigins[0].origin == "https://y.test"
    check languageForOrigin(parsed, "https://x.test") == ""
    check templateFor(languageForOrigin(parsed, "https://y.test")).hasFiles

  test "the rewrite table covers the language host's clean-start address":
    ## `/new` is reachable only on a language host, but there is ONE rewrite
    ## file for one tree serving every host, so the prefix must be in it or
    ## `noirstudio.dev/new` reaches the CDN and not the application.
    check "/new" in rewritePrefixes()
    let rendered = renderRewriteConfig(
      deploymentContract("https://a.test", publishedDeployment(digestOfBuildOne)))
    check "/new  " & entryDocumentAddress & "  200" in rendered

  test "a language origin that can never match is refused at build time":
    ## The typo whose symptom is success. `noirstudio.dev` declared with a
    ## trailing slash, without a scheme, or over http never equals
    ## `window.location.origin`, so the domain serves a working product at the
    ## language-neutral root and nothing says the map was ignored.
    var good = DeploymentDescriptor()
    good.languageOrigins.add OriginLanguage(
      origin: "https://noirstudio.dev", language: "noir")
    good.languageOrigins.add OriginLanguage(
      origin: "https://www.noirstudio.dev", language: "noir")
    check unmatchableLanguageOrigins(good).len == 0
    # NON-VACUITY: an empty descriptor also has nothing unmatchable.
    check good.languageOrigins.len == 2

    var bad = DeploymentDescriptor()
    bad.languageOrigins.add OriginLanguage(
      origin: "https://noirstudio.dev/", language: "noir")
    bad.languageOrigins.add OriginLanguage(
      origin: "noirstudio.dev", language: "noir")
    bad.languageOrigins.add OriginLanguage(
      origin: "http://noirstudio.dev", language: "noir")
    check unmatchableLanguageOrigins(bad).len == 3

    # And the PARSER stays tolerant of all three, deliberately: the mount
    # gate serves the bundle over plain HTTP on a loopback origin, and a
    # parser that dropped `http://` would make the two-domain routing
    # untestable without TLS. The build refuses the shape; the parser does not.
    let roundTripped = parseDeploymentDescriptor(renderDeploymentDescriptor(bad))
    check roundTripped.languageOrigins.len == 3
    check languageForOrigin(roundTripped, "http://noirstudio.dev") == "noir"
