## The container deployment's start-up: open the channel, perform §6.5's
## handshake, install the platform the server described.
##
## ## The defect this exists to remove
##
## `container_platform.nim` has satisfied every field of all seven facades
## since codetracer `f892f9eea`, and `index/facade_endpoint.nim` has answered
## sixty-one verbs since `7739d096f`. **Nothing constructed the client.** A
## browser tab served by `ct host` took `desktop_electron.nim`'s
## `electronAvailable() == false` branch and got `newPlatform(webProfile)` — a
## profile advertising a filesystem, a process runner and a VCS, over facades
## that refuse every one of them. That is the "may I" / "did it work"
## disagreement `capabilities.nim` exists to prevent, and it is WD1b's opening
## sentence.
##
## ## The signal is the `welcome` frame, and nothing else — §6.3
##
## A tab cannot tell "served by a container" from "served by the browsersync
## dev server" by looking at itself: both are a page with no `require`, the
## same bundle, the same origin shape. Every property one might probe —
## `location`, a global, a build define — is a guess about the deployment made
## by the artefact being deployed.
##
## So this module does not guess. It sends `hello` and waits. A `welcome` means
## a container endpoint is on the other end AND says what it serves; silence
## means there is no endpoint and the page keeps the refusing platform it
## already had. The profile that arrives is the one the process that will
## answer the calls declares, which is the whole of why §6.3 put it in the
## frame rather than in a constant.
##
## ## Why a channel rather than a socket
##
## `ContainerChannel` is two procs. The real one is the socket.io connection
## `ui_js.nim` already opens — the page owns that, `ct host` already narrows
## it (WD1a), and §6.1 chose it over a second listener. A suite drives the
## same code with a pair of closures and no network, which is what lets the
## handshake, the version refusal and the reply correlation be tested on both
## Nim backends.
##
## ## Several sessions, and why a boot filters by one
##
## One WebUI drives several container sessions, so there is one `ContainerBoot`
## per session — the object is already per-connection and holds its own
## `pending` table, so that part needed nothing. What it did NOT have was a way
## to tell its own frames from another session's on a channel it shares.
##
## That is not a tidiness point. `nextId` starts at 1 in every boot, so two
## boots on one channel both have call `1` outstanding, and `deliverReply`
## retired a reply by `id` alone: whichever boot decoded it first would have
## completed its own call with the OTHER session's payload — a wrong value, not
## a dropped frame. Each boot now accepts only frames whose `session` is its
## own, and `""` (the default on both sides) is a session like any other, so a
## deployment serving one session behaves exactly as it did.
##
## ## What it does with a refusal
##
## §6.5 puts the version decision in the CLIENT, because the stale artefact is
## the client. A bundle outside the server's range installs NOTHING and reports
## `negotiationMessage`'s sentence: the platform stays the refusing default, so
## the page degrades to "this deployment cannot do that" rather than misreading
## replies from a contract it does not speak.

import std/[algorithm, json, tables]

import ../platform/outcome
import ../platform/platform
import ../platform/endpoint_protocol
import ../platform/browser_facades
import container_platform

export container_platform
# `FacadeChannel` above all: whoever opens the channel needs the message name,
# and it is the contract's rather than either end's.
#
# `#` and not `##`: a `##` block after an `export` is `Error: invalid
# indentation`, which is the trap `platform_host.nim`'s `ctWeb` arm already
# records — it reached `dev` in `web_browser.nim` and sat there for days.
export endpoint_protocol

type
  ContainerChannel* = object
    ## The page's connection, as the two operations this module needs.
    ##
    ## Not a socket.io type: this module is compiled into suites on both
    ## backends, and the one thing it must not require is a browser.
    send*: proc(frame: string)
      ## One frame's JSON, on the transport's single message name.
    subscribe*: proc(handler: proc(frame: string))
      ## Every inbound frame on that name. §6.1 shares the connection with the
      ## index IPC surface, so the handler is given text that is often not a
      ## frame at all, and drops it rather than raising.

  ContainerBootOutcome* = enum
    cbPending      ## `hello` sent, no `welcome` yet.
    cbInstalled    ## A platform was built from the server's profile.
    cbRefused      ## §6.5: the bundle and the server cannot talk.
    cbMalformed    ## A `welcome` arrived that this build cannot read.

  ContainerBoot* = ref object
    channel: ContainerChannel
    tab: BrowserTabBridge
    session: string
      ## The session this boot drives, stamped on every frame it sends and
      ## required on every frame it accepts. Empty is the single-session
      ## deployment and is omitted from the wire.
    nextId: int
    pending: Table[int, proc(response: RemoteResponse)]
    outcome*: ContainerBootOutcome
    message*: string
      ## Why, when `outcome` is not `cbInstalled`. Shown to the user for
      ## `cbRefused` — `negotiationMessage` writes that sentence — and logged
      ## for `cbMalformed`.
    platform*: Platform
      ## Valid only when `outcome == cbInstalled`.
    onSettled: proc(boot: ContainerBoot)
      ## Fired once, the moment `outcome` stops being `cbPending`.

# ---------------------------------------------------------------------------
# A future that is completed later.
#
# `outcome.nim` has `resolved*` and nothing that stays pending, because until
# now every instantiation settled its own calls. A reply arrives on the
# channel, so this one cannot.
# ---------------------------------------------------------------------------

type Completer[T] = object
  future: PlatformFuture[T]
  complete: proc(value: T)

proc newCompleter[T](): Completer[T] =
  when defined(js):
    # A Promise executor runs SYNCHRONOUSLY, so `resolveFn` is assigned before
    # `newPromise` returns and the completer is usable immediately. Written the
    # other way — capturing `resolve` from a `then` — a reply that arrived in
    # the same tick as the call would be dropped.
    var resolveFn: proc(value: T)
    let f = newPromise(proc(resolve: proc(value: T)) = resolveFn = resolve)
    result = Completer[T](future: f,
                          complete: proc(value: T) = resolveFn(value))
  else:
    let f = newFuture[T]("container_boot")
    result = Completer[T](future: f,
                          complete: proc(value: T) = f.complete(value))

# ---------------------------------------------------------------------------

proc transportFor(boot: ContainerBoot): RemoteTransport =
  ## One `call` frame out, one `reply` frame back, correlated by `id` — §6.2,
  ## which correlates them by `id` and by nothing else.
  result = proc(request: RemoteRequest): PlatformFuture[RemoteResponse] =
    let id = boot.nextId
    inc boot.nextId
    let completer = newCompleter[RemoteResponse]()
    boot.pending[id] = completer.complete
    boot.channel.send(encodeCall(
      CallFrame(session: boot.session, id: id, verb: request.verb,
                args: request.args)))
    completer.future

proc deliverReply(boot: ContainerBoot; text: string) =
  var reply: ReplyFrame
  try:
    reply = decodeReply(text)
  except ProtocolError:
    # A reply this build cannot read is not answerable: there is no id to fail
    # under. The call it belonged to stays pending, which is visible as a hung
    # operation rather than as a wrong value.
    return
  # THE SESSION TEST COMES FIRST, and it is not interchangeable with the `id`
  # test below. Ids are allocated per session from 1, so another session's
  # reply can carry an id this boot has outstanding — the `hasKey` check would
  # pass and complete the wrong call with the wrong payload.
  if reply.session != boot.session: return
  if not boot.pending.hasKey(reply.id): return
  let complete = boot.pending[reply.id]
  boot.pending.del(reply.id)
  if reply.ok:
    complete(remoteOk(reply.payload))
  else:
    complete(remoteErr(reply.errorKind, reply.errorMessage, reply.detail))

proc receiveWelcome(boot: ContainerBoot; text: string): bool =
  ## True when this welcome was ADDRESSED TO THIS BOOT and was acted on —
  ## which is what decides whether `onSettled` may fire. A welcome for another
  ## session is not this boot's business and must not settle it; a MALFORMED
  ## one is, and settles it as `cbMalformed`.
  if boot.outcome != cbPending:
    # A second `welcome` — a reconnect, most likely. Replacing the platform
    # under a running page would swap the facades out from under in-flight
    # calls; the profile is a property of the deployment and a reconnect to the
    # same deployment cannot have changed it.
    return false
  var welcome: WelcomeFrame
  try:
    welcome = decodeWelcome(text)
  except ProtocolError as err:
    boot.outcome = cbMalformed
    boot.message = "this deployment sent a welcome this build cannot read: " &
      err.msg
    return true

  # Another session's welcome. Not an error and not this boot's: it stays
  # `cbPending`, which is the same state silence leaves it in, because from
  # this boot's point of view nothing has answered it yet.
  if welcome.session != boot.session: return false

  let verdict = negotiate(EndpointContractVersion,
                          welcome.contractMin, welcome.contractMax)
  if verdict != negOk:
    boot.outcome = cbRefused
    boot.message = negotiationMessage(verdict, EndpointContractVersion,
                                      welcome.contractMin, welcome.contractMax)
    return true

  boot.platform = newContainerPlatform(transportFor(boot), boot.tab, welcome)
  boot.outcome = cbInstalled
  true

proc outstandingCalls*(boot: ContainerBoot): seq[int] =
  ## The ids of calls that have been sent and not yet answered, in ascending
  ## order.
  ##
  ## Public because it is the only synchronous statement anyone can make about
  ## correlation, and correlation is the one thing about this module that a
  ## suite cannot observe through a facade result.
  ##
  ## **Why not through the result.** A reply arrives on a socket, so the future
  ## a facade call returns is never `isSyncResolved` — `callRemote` decides
  ## that at call time, when nothing has arrived — and on the JS backend an
  ## unstamped future delivers through `then`, on V8's microtask queue, which
  ## `drainPlatformCallbacks` does not and cannot drain. A synchronous caller
  ## therefore cannot see a container reply at all, however long it has been
  ## sitting there.
  ##
  ## That is the DESIGNED behaviour and not a gap: `platform_host.ctAwaitSync`
  ## returns `pkTimeout` naming itself precisely so that a call site which has
  ## not been converted to a continuation reports "this still needs
  ## converting" the day it first runs against the container, instead of
  ## reading a zero value. `ui/git_cli.nim`'s three uses are exactly those call
  ## sites.
  for id in boot.pending.keys: result.add id
  result.sort()

proc receive*(boot: ContainerBoot; text: string) =
  ## One inbound frame. Public because the socket handler is in `ui_js.nim` and
  ## because a suite drives this directly.
  case frameKind(text)
  of FrameWelcome:
    let mine = boot.receiveWelcome(text)
    # The notification lives HERE rather than in a channel wrapper, so that a
    # channel which delivers the `welcome` synchronously from inside `send`
    # — every fake one in a suite does — is not a case the caller silently
    # never hears about.
    if mine and boot.outcome != cbPending and boot.onSettled != nil:
      let settled = boot.onSettled
      boot.onSettled = nil
      settled(boot)
  of FrameReply: boot.deliverReply(text)
  else:
    # §6.1: this connection carries the index IPC surface too. Anything that is
    # not a frame of ours belongs to somebody else.
    discard

proc session*(boot: ContainerBoot): string =
  ## Which session this boot drives. Public so a caller holding several can say
  ## which one settled — `onSettled` hands back the boot and nothing else.
  boot.session

proc beginContainerBoot*(channel: ContainerChannel; tab: BrowserTabBridge;
                         onSettled: proc(boot: ContainerBoot) = nil;
                         session = ""): ContainerBoot =
  ## Subscribe, send `hello`, and hand back the handle.
  ##
  ## Returns before the answer arrives — `outcome` is `cbPending` until one
  ## does — so `onSettled` is how a caller acts on it. It fires on `cbRefused`
  ## and `cbMalformed` too, deliberately: a caller that only heard about
  ## success would have no way to show §6.5's sentence, and that failure is
  ## exactly the one a user needs told about.
  ##
  ## If no `welcome` ever arrives, nothing fires and nothing is installed.
  ## That is the dev-server case and it is not an error: the page keeps the
  ## platform it already had.
  result = ContainerBoot(
    channel: channel, tab: tab, session: session, nextId: 1,
    pending: initTable[int, proc(response: RemoteResponse)](),
    outcome: cbPending, onSettled: onSettled)
  let boot = result
  channel.subscribe(proc(frame: string) = boot.receive(frame))
  channel.send(encodeHello(HelloFrame(
    contractVersion: EndpointContractVersion, session: session)))
