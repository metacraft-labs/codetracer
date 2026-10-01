## THE HANDSHAKE THAT INSTALLS THE CONTAINER PLATFORM — `host/container_boot.nim`.
##
## ## The defect this is about
##
## Every piece of the container deployment existed and nothing joined them.
## `container_platform.nim` satisfied all seven facades, `facade_endpoint.nim`
## answered sixty-one verbs, and no code anywhere CONSTRUCTED the client: a
## browser tab served by `ct host` fell through
## `desktop_electron.electronAvailable() == false` to
## `newPlatform(webProfile)` — a profile claiming a filesystem, a process
## runner and a VCS over facades that refuse all three. The suites that existed
## could not see it, because each drove a piece directly.
##
## ## What is asserted, and why each case fails differently
##
## 1. **`hello` goes out first, unprompted.** §6.3 makes the welcome the
##    signal; a client that waits to be spoken to never learns what it is
##    running on.
## 2. **A `welcome` installs a platform whose profile is the one that
##    ARRIVED**, not `containerProfile` and not a constant. A boot that used a
##    compiled-in set would pass a "did it install something" check and be the
##    original defect.
## 3. **Calls made afterwards reach the channel as `call` frames, and a reply
##    retires the call that carries its `id` and no other.** Correlation is by
##    `id` and by nothing else (§6.2), so the case interleaves two calls and
##    answers them out of order — in order, a table lookup and a queue are
##    indistinguishable.
##
##    It reads `outstandingCalls()` rather than the facade's result, and that
##    is forced rather than chosen: a reply arrives on a socket, so the future
##    a container call returns is never `isSyncResolved`, and on the JS backend
##    an unstamped future delivers through V8's microtask queue, which
##    `drainPlatformCallbacks` cannot drain. **No synchronous caller can
##    observe a container reply at all** — which is the designed behaviour
##    (`ctAwaitSync` reports `pkTimeout` naming itself, so an unconverted call
##    site says so the day it first runs against a container) and is why
##    `ui/git_cli.nim`'s three uses are WD1b work rather than a detail. The
##    decoding of a reply's VALUE is asserted in
##    `test_container_platform_verbs.nim`, against a synchronous transport, and
##    is deliberately not re-asserted here where it could only be asserted on
##    one backend.
## 4. **A version outside the server's range installs NOTHING** and carries
##    §6.5's sentence. Installing a platform and hoping is the failure mode
##    that negotiation exists to replace.
## 5. **Silence installs nothing.** This is the dev server, and it must not be
##    an error: the page keeps whatever platform it had.
## 6. **Frames that are not ours are dropped, not raised on.** §6.1 shares the
##    connection with the index IPC surface.
##
## ## What is real
##
## `container_boot.nim`, `container_platform.nim`, `endpoint_protocol.nim`'s
## real codec and real `negotiate`, `browser_facades.nim`'s builders. The
## channel is two closures — it is the seam, and the module's whole shape
## exists so that a suite can be the other end of it on both Nim backends. The
## frames the fake server sends are built with the REAL encoders, so a field
## name that drifts fails here rather than being agreed on by two fakes.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (node).

import std/[json, strutils, unittest]

import ../../platform/outcome
import ../../platform/platform
import ../../platform/capabilities
import ../../platform/browser_facades
import ../../platform/endpoint_protocol
import ../../host/container_boot

const ExpectedAssertions = 47
var counted = 0
template ck(cond: untyped) =
  inc counted
  check cond

# ---------------------------------------------------------------------------
# The other end of the channel: a fake `ct host`.
# ---------------------------------------------------------------------------

type FakeServer = ref object
  sent: seq[string]            ## every frame the client emitted
  deliver: proc(frame: string) ## the client's own handler, captured on subscribe
  autoWelcome: bool
  contractMin, contractMax: int
  profile: PlatformProfile

proc channelOf(server: FakeServer): ContainerChannel =
  ContainerChannel(
    send: proc(frame: string) =
      server.sent.add frame
      # The welcome is sent from INSIDE `send`, synchronously, which is the
      # harder ordering: it is the one where a notification wired to a channel
      # wrapper rather than to the boot object would fire before the object
      # existed.
      if server.autoWelcome and frameKind(frame) == FrameHello:
        server.deliver(encodeWelcome(WelcomeFrame(
          contractMin: server.contractMin, contractMax: server.contractMax,
          profile: server.profile, deployment: newJObject()))),
    subscribe: proc(handler: proc(frame: string)) =
      server.deliver = handler)

proc newFakeServer(profile: PlatformProfile; min = EndpointContractVersion;
                   max = EndpointContractVersion;
                   autoWelcome = true): FakeServer =
  FakeServer(sent: @[], autoWelcome: autoWelcome,
             contractMin: min, contractMax: max, profile: profile)

proc inertTab(): BrowserTabBridge =
  ## Answers everything, because the tab's own behaviour is
  ## `test_container_tab_facades.nim`'s subject and not this file's.
  BrowserTabBridge(
    writeClipboardText: proc(text: string): auto = resolvedOk(),
    writeClipboardHtml: proc(html, plainText: string): auto = resolvedOk(),
    offerDownload: proc(suggestedName: string; content: seq[byte];
                        mimeType: string): auto = resolvedOk(),
    pickFiles: proc(options: OpenDialogOptions): auto = resolvedOk(@["a.nr"]),
    pickDirectory: proc(options: OpenDialogOptions): auto = resolvedOk("d"),
    suggestSaveName: proc(options: SaveDialogOptions): auto =
      resolvedOk(options.suggestedName),
    openExternalUrl: proc(url: string): auto = resolvedOk(),
    setFullscreen: proc(fullscreen: bool): auto = resolvedOk(),
    windowState: proc(): auto = resolvedOk(WindowState(
      maximized: false, minimized: false, fullscreen: false, focused: true)),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard)

## A deliberately ODD profile: it is neither `containerProfile` nor
## `webProfile`, so a boot that installed a compiled-in set could not
## accidentally match it.
let servedProfile = PlatformProfile(
  kind: pkContainer,
  displayName: "the fake container",
  capabilities: {capFilesystemRead, capVcsRead, capSettingsRead},
  degradations: @[])

# ---------------------------------------------------------------------------

suite "the handshake":
  test "`hello` is sent unprompted, before anything answers":
    let server = newFakeServer(servedProfile, autoWelcome = false)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    ck server.sent.len == 1
    ck frameKind(server.sent[0]) == FrameHello
    ck decodeHello(server.sent[0]).contractVersion == EndpointContractVersion
    ck boot.outcome == cbPending

  test "a `welcome` installs a platform carrying the profile that ARRIVED":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    ck boot.outcome == cbInstalled
    ck boot.message.len == 0
    ck boot.platform.profile.kind == pkContainer
    # The three the fake server serves, from the frame.
    ck boot.platform.can(capFilesystemRead)
    ck boot.platform.can(capVcsRead)
    ck boot.platform.can(capSettingsRead)
    # NOT `containerProfile`'s. A compiled-in set would claim these.
    ck not boot.platform.can(capFilesystemWrite)
    ck not boot.platform.can(capProcessSpawn)
    # The tab's, added by the composed constructor — the server never claimed
    # `capClipboardWrite` and cannot, because a container has no clipboard.
    ck boot.platform.can(capClipboardWrite)

  test "the settled callback fires even when the welcome arrives inside `send`":
    let server = newFakeServer(servedProfile)
    var notified = 0
    var seenOutcome = cbPending
    discard beginContainerBoot(channelOf(server), inertTab(),
      proc(b: ContainerBoot) =
        inc notified
        seenOutcome = b.outcome)
    ck notified == 1
    ck seenOutcome == cbInstalled

suite "calls travel, and replies find their own call":
  test "a facade call becomes a `call` frame on the channel":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    ck boot.outcome == cbInstalled
    discard boot.platform.fs.readText("/w/main.nr")
    ck server.sent.len == 2
    let call = decodeCall(server.sent[1])
    ck call.verb == "fs.readText"
    ck call.args{"path"}.getStr == "/w/main.nr"

  test "two outstanding calls, answered in the WRONG order, each retire their own":
    # In order, a table keyed on `id` and a FIFO queue behave identically, so
    # the replies come back reversed.
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    discard boot.platform.fs.readText("/w/first.nr")
    discard boot.platform.fs.readText("/w/second.nr")
    ck server.sent.len == 3
    let idFirst = decodeCall(server.sent[1]).id
    let idSecond = decodeCall(server.sent[2]).id
    ck idFirst != idSecond
    ck boot.outstandingCalls() == @[idFirst, idSecond]
    server.deliver(encodeReply(ReplyFrame(
      id: idSecond, ok: true, payload: %"SECOND")))
    # THE SECOND one retired, and the first untouched. A queue would have
    # retired the first.
    ck boot.outstandingCalls() == @[idFirst]
    server.deliver(encodeReply(ReplyFrame(
      id: idFirst, ok: true, payload: %"FIRST")))
    ck boot.outstandingCalls().len == 0

  test "a refusal retires its call too, rather than leaving it hung":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    discard boot.platform.fs.readText("/w/missing.nr")
    let id = decodeCall(server.sent[1]).id
    ck boot.outstandingCalls() == @[id]
    server.deliver(encodeReply(ReplyFrame(
      id: id, ok: false, errorKind: pkNotFound,
      errorMessage: "read /w/missing.nr failed", detail: "ENOENT")))
    ck boot.outstandingCalls().len == 0

  test "a reply for an id nobody is waiting on is dropped, not fatal":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    server.deliver(encodeReply(ReplyFrame(id: 9999, ok: true, payload: %"x")))
    ck boot.outcome == cbInstalled

suite "§6.5 — a bundle outside the range installs NOTHING":
  test "too new: the deployment has not been updated":
    let server = newFakeServer(servedProfile,
                               min = EndpointContractVersion - 2,
                               max = EndpointContractVersion - 1)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    ck boot.outcome == cbRefused
    ck boot.platform.isNil
    ck boot.message.len > 0
    ck boot.message.contains("has not been updated")
    # Both numbers, because §6.5's whole point is that a refusal naming one of
    # them sends the reader to the server logs.
    ck boot.message.contains($EndpointContractVersion)
    ck boot.message.contains($(EndpointContractVersion - 1))

  test "too old: reload to pick up the current version":
    let server = newFakeServer(servedProfile,
                               min = EndpointContractVersion + 1,
                               max = EndpointContractVersion + 2)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    ck boot.outcome == cbRefused
    ck boot.platform.isNil
    ck boot.message.contains("Reload")

  test "a welcome this build cannot read is `cbMalformed`, not an exception":
    let server = newFakeServer(servedProfile, autoWelcome = false)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    server.deliver("""{"kind":"welcome","contractMin":"one"}""")
    ck boot.outcome == cbMalformed
    ck boot.platform.isNil
    ck boot.message.len > 0

suite "silence, and somebody else's traffic":
  test "no welcome means no platform, and that is not an error":
    # The browsersync dev server. Nothing answers, and the page must keep the
    # platform it already had rather than being handed a container's.
    let server = newFakeServer(servedProfile, autoWelcome = false)
    var notified = 0
    let boot = beginContainerBoot(channelOf(server), inertTab(),
      proc(b: ContainerBoot) = inc notified)
    ck boot.outcome == cbPending
    ck boot.platform.isNil
    ck notified == 0

  test "frames belonging to the index IPC surface are dropped":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    server.deliver("""{"kind":"something-else"}""")
    server.deliver("not json at all")
    server.deliver("""{"id":7,"payload":"an index IPC response"}""")
    ck boot.outcome == cbInstalled
    ck boot.platform.can(capFilesystemRead)

  test "a second welcome does not swap the platform under a running page":
    let server = newFakeServer(servedProfile)
    let boot = beginContainerBoot(channelOf(server), inertTab())
    let installed = boot.platform
    server.deliver(encodeWelcome(WelcomeFrame(
      contractMin: EndpointContractVersion, contractMax: EndpointContractVersion,
      profile: PlatformProfile(kind: pkContainer, displayName: "other",
                               capabilities: {capProcessSpawn},
                               degradations: @[]),
      deployment: newJObject())))
    ck boot.platform == installed
    ck boot.platform.can(capFilesystemRead)
    ck not boot.platform.can(capProcessSpawn)

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
