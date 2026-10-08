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

const ExpectedAssertions = 61
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

type Wire = ref object
  ## ONE connection with SEVERAL clients on it — the shape `channelOf` cannot
  ## express, because it stores a single handler and a second `subscribe`
  ## overwrites the first.
  ##
  ## `broadcast` delivers to every subscriber, which is not a simplification:
  ## a shared transport hands every frame to every client on it, and the client
  ## is what decides whether a frame is its own. A fake that routed by session
  ## would be implementing the thing under test.
  sent: seq[string]
  handlers: seq[proc(frame: string)]

proc newWire(): Wire = Wire(sent: @[], handlers: @[])

proc wireChannel(w: Wire): ContainerChannel =
  ContainerChannel(
    send: proc(frame: string) =
      # `add(frame)` and not `add frame`: command syntax would swallow the
      # comma that ends this field and read `subscribe:` as a second argument.
      w.sent.add(frame),
    subscribe: proc(handler: proc(frame: string)) =
      w.handlers.add(handler))

proc broadcast(w: Wire; frame: string) =
  for h in w.handlers: h(frame)

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

proc welcomeFor(session: string): string =
  ## A welcome addressed to one session, built with the REAL encoder so a field
  ## name that drifts fails here rather than being agreed on by two fakes.
  encodeWelcome(WelcomeFrame(
    session: session, contractMin: EndpointContractVersion,
    contractMax: EndpointContractVersion, profile: servedProfile,
    deployment: newJObject()))

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

suite "several sessions on ONE channel":
  # The WebUI drives several container sessions. Whether the transport gives
  # each its own connection is the transport's business — §6.1 already shares
  # this one with the index IPC surface — so the client has to be correct when
  # it does not.
  #
  # WITHOUT A SESSION ON THE FRAME THE FAILURE IS A WRONG VALUE, not a dropped
  # one, and that is why these cases exist rather than a comment. `nextId`
  # starts at 1 in every boot, so two boots on one channel both have call `1`
  # outstanding; `deliverReply` retired by `id` alone, so whichever decoded a
  # reply first completed ITS call with the OTHER session's payload. A test
  # that only asserted "frames arrive" could not see that.

  test "a `hello` asks for the session the caller named":
    let wire = newWire()
    discard beginContainerBoot(wireChannel(wire), inertTab(), session = "s-1")
    ck decodeHello(wire.sent[0]).session == "s-1"

  test "a `welcome` installs only into the session it names":
    let wire = newWire()
    let one = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-1")
    let two = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-2")
    wire.broadcast(welcomeFor("s-1"))
    ck one.outcome == cbInstalled
    # Still PENDING, not refused and not malformed: from `two`'s point of view
    # nothing has answered it yet, which is the state silence leaves it in.
    ck two.outcome == cbPending
    ck two.platform.isNil

  test "another session's welcome does not fire `onSettled`":
    # A caller that heard about a settlement which did not happen would show
    # §6.5's sentence, or mount an editor, for a session that has not answered.
    let wire = newWire()
    var settledFor: seq[string] = @[]
    # The handler is bound first rather than written inline: an anonymous proc
    # body inside an argument list runs to the end of the line, so `session =`
    # after it would be read as part of the body.
    let note = proc(b: ContainerBoot) = settledFor.add(b.session)
    discard beginContainerBoot(wireChannel(wire), inertTab(),
                               onSettled = note, session = "s-1")
    wire.broadcast(welcomeFor("s-2"))
    ck settledFor.len == 0
    wire.broadcast(welcomeFor("s-1"))
    ck settledFor == @["s-1"]

  test "a `call` carries the session that made it":
    let wire = newWire()
    let one = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-1")
    wire.broadcast(welcomeFor("s-1"))
    discard one.platform.fs.readText("/w/a.nr")
    ck decodeCall(wire.sent[^1]).session == "s-1"

  test "a reply is retired by (session, id) and NOT by id alone":
    let wire = newWire()
    let one = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-1")
    let two = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-2")
    wire.broadcast(welcomeFor("s-1"))
    wire.broadcast(welcomeFor("s-2"))
    discard one.platform.fs.readText("/w/a.nr")
    discard two.platform.fs.readText("/w/b.nr")
    let idOne = decodeCall(wire.sent[^2]).id
    let idTwo = decodeCall(wire.sent[^1]).id
    # THE COLLISION ITSELF, asserted rather than assumed: ids are allocated per
    # session from 1, so these ARE the same number. If they ever stop being,
    # this case stops exercising what it was written for and should be fixed
    # rather than deleted.
    ck idOne == idTwo
    ck one.outstandingCalls() == @[idOne]
    ck two.outstandingCalls() == @[idTwo]
    wire.broadcast(encodeReply(ReplyFrame(
      session: "s-2", id: idTwo, ok: true, payload: %"FOR-TWO")))
    # `two` answered, `one` untouched. Before the session field, `one` would
    # have completed its own read with "FOR-TWO".
    ck two.outstandingCalls().len == 0
    ck one.outstandingCalls() == @[idOne]

  test "a session that names one ignores an UNADDRESSED welcome":
    # The other direction of the same rule. A deployment that serves one
    # session sends no `session`, and a client driving several cannot tell
    # which of them such a welcome is for — so it is for the unnamed one, and
    # for no other.
    let wire = newWire()
    let named = beginContainerBoot(wireChannel(wire), inertTab(), session = "s-1")
    let unnamed = beginContainerBoot(wireChannel(wire), inertTab())
    wire.broadcast(welcomeFor(""))
    ck unnamed.outcome == cbInstalled
    ck named.outcome == cbPending

suite "the tally":
  test "assertion count":
    echo "CHECKS: " & $counted
    check counted == ExpectedAssertions
