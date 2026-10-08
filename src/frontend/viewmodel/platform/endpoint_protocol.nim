## THE WIRE BETWEEN A BUNDLE AND THE DEPLOYMENT SERVING IT.
##
## `Architecture/UI-Bundle-And-Endpoints.md` §6 is the contract; this module is
## its codec, and nothing else. It builds no platform, opens no socket and
## performs no call — every proc here is a function of its arguments, so the
## frame shapes and the version rule can be tested on both backends with no
## transport at all.
##
## ## Why the codec is separate from the transport AND from the facade
##
## Three parties have to agree on these bytes: the renderer (`nim js`, a
## browser), the index process (`nim js -d:ctIndex`, node) and the suites that
## grade both (`nim c`). A codec that lived with either end would be compiled
## by one of them and re-implemented by the other, which is the drift
## `Noir-Studio.md` §3 exists to prevent, arriving through packaging instead of
## through source.
##
## ## Capabilities travel BY NAME, and an unknown one is reported, not dropped
##
## `PlatformCapability` is an enum, and an ordinal on the wire would renumber
## the whole contract every time a value is inserted. Names cost bytes once per
## connection.
##
## A name this build does not know is kept in `unknownCapabilities` rather than
## discarded. Within a negotiated version the two ends agree by construction,
## so a name arriving here means something is wrong upstream — and a client
## that silently ignored it would present a narrower platform than the server
## serves, with nothing anywhere saying why.
##
## ## Several sessions on one connection — the `session` field
##
## One WebUI drives SEVERAL container sessions. The transport may or may not
## give each its own connection, and the contract must not depend on which:
## §6.1 already shares this connection with the index IPC surface, so "one
## connection carries traffic that is not this conversation's" is the existing
## shape rather than a new one.
##
## Every frame therefore carries a `session`, and a client accepts a frame only
## when it names the session that client is driving. **Without it the failure
## is silent and it is a WRONG ANSWER, not a dropped one:** `id` is allocated
## per client starting at 1, so two clients on one connection both have a call
## `1` outstanding, and whichever decodes a reply first retires its own call
## with the other's payload. Correlation "by `id` and by nothing else" (§6.2)
## is correct only within one session; the session is what makes `id` unique.
##
## It is OMITTED FROM THE JSON WHEN EMPTY, and empty is the default on both
## sides. A deployment serving one session is byte-identical on the wire to
## what it sent before this field existed, in both directions, which is why
## this is not a contract version bump: there is no frame a peer built against
## the older spelling can send that this one reads differently, and none this
## one sends that the older peer cannot read. A peer that never fills it in is
## a peer with one session, which is exactly what it had.
##
## ## What is deliberately NOT here
##
## No authentication. §6.6 says so plainly: the socket carries filesystem
## reads, process spawn and ripgrep and authenticates nothing. WD1a narrowed
## the binding, which makes that survivable behind a gateway and does not close
## it. Nothing in this module should be read as having addressed it.

import std/[json, strutils]

import ./capabilities
import ./outcome

const
  EndpointContractVersion* = 1
    ## What THIS bundle was built for. §6.5: a single integer, because the only
    ## question is whether this bundle and this server can talk, and a range of
    ## integers answers it without anyone having to decide what a minor version
    ## means for a facade verb.

  FrameHello* = "hello"
  FrameWelcome* = "welcome"
  FrameCall* = "call"
  FrameReply* = "reply"
  FrameEvent* = "event"

const FacadeChannel* = "CODETRACER::facade"
  ## The one transport message name the endpoint contract uses, in BOTH
  ## directions.
  ##
  ## One name rather than one per frame kind, because §6.2 already puts `kind`
  ## in the frame and a second dispatch on the message name would be the same
  ## decision made twice, in two places, able to disagree.
  ##
  ## Prefixed like the index IPC surface it shares the connection with (§6.1),
  ## so an operator reading a socket trace sees which subsystem a frame belongs
  ## to without decoding it.
  ##
  ## It lives HERE, with the codec, rather than in either end. The server side
  ## is `index/facade_endpoint.nim`, an Electron main-process module the
  ## renderer must not import; the client side is `host/container_boot.nim`,
  ## which the main process must not import. A name the two ends spell
  ## separately is a name they can spell differently, and the failure is
  ## silent — frames go out and nothing answers.

type
  ProtocolError* = object of CatchableError
    ## Raised by the decoders. A frame that cannot be read is not a value a
    ## caller should be able to forget to check: the alternative is a
    ## half-filled record reaching a facade.

  HelloFrame* = object
    contractVersion*: int
    session*: string
      ## Which session this client is driving. Empty is "the only one" and is
      ## omitted from the wire — see the header. In `hello` it is the client
      ## ASKING for a session, so a server multiplexing several knows which
      ## conversation the handshake opens.

  WelcomeFrame* = object
    session*: string
      ## Which session this welcome is for. A client ignores a `welcome` naming
      ## a session it is not driving, or two clients on one connection would
      ## each install the first profile that arrived — including the other's.
    contractMin*: int
    contractMax*: int
    profile*: PlatformProfile
    unknownCapabilities*: seq[string]
      ## Filled by the DECODER, never sent. See the header.
    deployment*: JsonNode
      ## §6.3's opaque half: the bundle URL, the session coordinates and the
      ## connection parameters `views/server_index.ejs` interpolates today.
      ## Opaque here on purpose — WD1c owns its shape, and a codec that
      ## validated it would have to be revised in lockstep with a document it
      ## does not own.

  CallFrame* = object
    session*: string
    id*: int
      ## Unique WITHIN A SESSION, not within a connection. See the header: the
      ## pair is what correlates a reply, and `id` alone does not.
    verb*: string
    args*: JsonNode

  ReplyFrame* = object
    session*: string
    id*: int
    ok*: bool
    payload*: JsonNode
    errorKind*: PlatformErrorKind
    errorMessage*: string
    detail*: string
      ## The ORIGINATING diagnostic — an errno's text, git's stderr — and a
      ## field of its own rather than something folded into `errorMessage`.
      ##
      ## `PlatformError` has carried `detail` since the facade was written, and
      ## the whole point of the pair is that `message` is neutral enough to show
      ## a user while `detail` is what a log needs. Merging them on the wire
      ## would discard in transit a distinction the type keeps in memory, and a
      ## container call would then be strictly less debuggable than the same
      ## call made in-process — which is the one thing a deployment must not be.

  EventFrame* = object
    session*: string
    handle*: string
    event*: string
    payload*: JsonNode

  Negotiation* = enum
    negOk
    negBundleTooOld
      ## The server no longer serves what this bundle speaks.
    negBundleTooNew
      ## This bundle speaks something the server does not serve yet — a
      ## deployment that has not been updated, which is the ordinary direction
      ## during a rollout.

# ---------------------------------------------------------------------------
# Version negotiation — §6.5. Pure, and the reason it is a named function
# rather than two inline comparisons is that the REFUSAL has to name both
# numbers, and a refusal assembled at the call site is a refusal each call site
# words differently.
# ---------------------------------------------------------------------------
func negotiate*(bundleVersion, serverMin, serverMax: int): Negotiation =
  if bundleVersion < serverMin: negBundleTooOld
  elif bundleVersion > serverMax: negBundleTooNew
  else: negOk

func negotiationMessage*(outcome: Negotiation; bundleVersion, serverMin,
                         serverMax: int): string =
  ## What the user is told. §5.2: the refusal is client-side because the stale
  ## artifact IS the client, and it must be legible — a cached bundle that
  ## refuses without saying which two numbers disagreed sends whoever is
  ## debugging it to the server logs, where the answer is not.
  case outcome
  of negOk: ""
  of negBundleTooOld:
    "This page was built for endpoint contract " & $bundleVersion &
      ", and this deployment now serves " & $serverMin & "-" & $serverMax &
      ". Reload to pick up the current version."
  of negBundleTooNew:
    "This page was built for endpoint contract " & $bundleVersion &
      ", and this deployment serves only " & $serverMin & "-" & $serverMax &
      ". The deployment has not been updated yet."

# ---------------------------------------------------------------------------
# Enum <-> name. `$` on a Nim enum yields the declared identifier, which is
# exactly the spelling §6.4 fixes, so there is no table to keep in step.
# ---------------------------------------------------------------------------
func capabilityName*(c: PlatformCapability): string = $c
func errorKindName*(k: PlatformErrorKind): string = $k
func platformKindName*(k: PlatformKind): string = $k

func parseCapability*(name: string; into: var PlatformCapability): bool =
  for c in PlatformCapability:
    if $c == name:
      into = c
      return true
  false

func parseErrorKind*(name: string): PlatformErrorKind =
  ## An unrecognised kind is `pkFailed` rather than a raise: the frame it
  ## arrived on already says the call FAILED, and refusing to decode the reason
  ## would turn a call that legitimately failed into a protocol error.
  for k in PlatformErrorKind:
    if $k == name: return k
  pkFailed

func parsePlatformKind*(name: string; into: var PlatformKind): bool =
  for k in PlatformKind:
    if $k == name:
      into = k
      return true
  false

# ---------------------------------------------------------------------------
# Small helpers. `requireX` raises rather than defaulting: a frame missing a
# field it needs is malformed, and a default would put a zero where the sender
# put nothing.
# ---------------------------------------------------------------------------
proc parseFrame(text: string; expected: string): JsonNode =
  var node: JsonNode
  try:
    node = parseJson(text)
  except:
    # THE BARE `except:` IS DELIBERATE and is the same one every parser in
    # `viewmodel/identity/` carries, for the same measured reason: on the C
    # backend `parseJson` raises `JsonParsingError`, a `CatchableError`; on the
    # JS backend it defers to V8's `JSON.parse`, which throws a raw
    # `SyntaxError` that no Nim exception type matches, so `except
    # CatchableError` catches nothing there and the exception escapes into the
    # renderer. This module decodes bytes that arrive over a socket.
    raise newException(ProtocolError, "the frame is not JSON")
  if node.kind != JObject:
    raise newException(ProtocolError, "the frame is not a JSON object")
  let kind = node{"kind"}
  if kind.isNil or kind.kind != JString:
    raise newException(ProtocolError, "the frame has no 'kind'")
  if kind.getStr != expected:
    raise newException(ProtocolError,
      "expected a '" & expected & "' frame and got '" & kind.getStr & "'")
  node

proc requireInt(node: JsonNode; key: string): int =
  let f = node{key}
  if f.isNil or f.kind != JInt:
    raise newException(ProtocolError, "the frame has no integer '" & key & "'")
  f.getInt

proc requireStr(node: JsonNode; key: string): string =
  let f = node{key}
  if f.isNil or f.kind != JString:
    raise newException(ProtocolError, "the frame has no string '" & key & "'")
  f.getStr

# ---------------------------------------------------------------------------
# The session discriminator. ABSENT MEANS EMPTY in both directions, and empty
# is omitted rather than sent as `""`, so a one-session deployment's bytes are
# the ones it sent before this field existed. See the header for why that is
# what makes this a non-breaking addition.
# ---------------------------------------------------------------------------
proc withSession(node: JsonNode; session: string): JsonNode =
  result = node
  if session.len > 0: result["session"] = %session

proc readSession(node: JsonNode): string =
  let f = node{"session"}
  if f.isNil or f.kind != JString: "" else: f.getStr

# ---------------------------------------------------------------------------
# Profiles on the wire.
# ---------------------------------------------------------------------------
proc encodeProfile*(p: PlatformProfile): JsonNode =
  result = %*{
    "kind": platformKindName(p.kind),
    "displayName": p.displayName,
    "overlaysCaptionBar": p.overlaysCaptionBar,
    "capabilities": newJArray(),
    "degradations": newJArray()}
  for c in p.capabilities:
    result["capabilities"].add(%capabilityName(c))
  for d in p.degradations:
    result["degradations"].add(%*{
      "capability": capabilityName(d.capability),
      "behaviour": d.behaviour})

proc decodeProfile*(node: JsonNode; unknown: var seq[string]): PlatformProfile =
  if node.isNil or node.kind != JObject:
    raise newException(ProtocolError, "the welcome frame carries no profile")
  var kind: PlatformKind
  if not parsePlatformKind(requireStr(node, "kind"), kind):
    raise newException(ProtocolError,
      "the server declares platform kind '" & requireStr(node, "kind") &
      "', which this bundle does not know")
  result.kind = kind
  result.displayName = requireStr(node, "displayName")
  let overlay = node{"overlaysCaptionBar"}
  result.overlaysCaptionBar = not overlay.isNil and overlay.kind == JBool and
    overlay.getBool

  for entry in node{"capabilities"}.getElems():
    if entry.kind != JString: continue
    var c: PlatformCapability
    if parseCapability(entry.getStr, c): result.capabilities.incl c
    else: unknown.add entry.getStr

  for entry in node{"degradations"}.getElems():
    if entry.kind != JObject: continue
    var c: PlatformCapability
    let name = entry{"capability"}
    if name.isNil or name.kind != JString: continue
    if not parseCapability(name.getStr, c):
      unknown.add name.getStr
      continue
    let behaviour = entry{"behaviour"}
    result.degradations.add DegradationRule(
      capability: c,
      behaviour: if behaviour.isNil or behaviour.kind != JString: ""
                 else: behaviour.getStr)

# ---------------------------------------------------------------------------
# Frames.
# ---------------------------------------------------------------------------
proc encodeHello*(f: HelloFrame): string =
  $withSession(%*{"kind": FrameHello,
                  "contractVersion": f.contractVersion}, f.session)

proc decodeHello*(text: string): HelloFrame =
  let node = parseFrame(text, FrameHello)
  HelloFrame(contractVersion: requireInt(node, "contractVersion"),
             session: readSession(node))

proc encodeWelcome*(f: WelcomeFrame): string =
  $withSession(%*{
    "kind": FrameWelcome,
    "contractMin": f.contractMin,
    "contractMax": f.contractMax,
    "profile": encodeProfile(f.profile),
    "deployment": if f.deployment.isNil: newJObject() else: f.deployment},
    f.session)

proc decodeWelcome*(text: string): WelcomeFrame =
  let node = parseFrame(text, FrameWelcome)
  result.session = readSession(node)
  result.contractMin = requireInt(node, "contractMin")
  result.contractMax = requireInt(node, "contractMax")
  if result.contractMin > result.contractMax:
    raise newException(ProtocolError,
      "the server declares an empty contract range " & $result.contractMin &
      "-" & $result.contractMax)
  result.profile = decodeProfile(node{"profile"}, result.unknownCapabilities)
  let deployment = node{"deployment"}
  result.deployment = if deployment.isNil: newJObject() else: deployment

proc encodeCall*(f: CallFrame): string =
  $withSession(%*{
    "kind": FrameCall,
    "id": f.id,
    "verb": f.verb,
    "args": if f.args.isNil: newJObject() else: f.args}, f.session)

proc decodeCall*(text: string): CallFrame =
  let node = parseFrame(text, FrameCall)
  result.session = readSession(node)
  result.id = requireInt(node, "id")
  result.verb = requireStr(node, "verb")
  if result.verb.len == 0 or not result.verb.contains('.'):
    # §6.2: verbs are the dotted names `container_platform.nim` already uses.
    # A server that dispatched on an undotted string would be answering
    # something this contract does not define.
    raise newException(ProtocolError,
      "'" & result.verb & "' is not a dotted facade verb")
  let args = node{"args"}
  result.args = if args.isNil: newJObject() else: args

proc encodeReply*(f: ReplyFrame): string =
  if f.ok:
    $withSession(%*{"kind": FrameReply, "id": f.id, "ok": true,
         "payload": if f.payload.isNil: newJNull() else: f.payload}, f.session)
  else:
    $withSession(%*{"kind": FrameReply, "id": f.id, "ok": false,
         "errorKind": errorKindName(f.errorKind),
         "errorMessage": f.errorMessage,
         "detail": f.detail}, f.session)

proc decodeReply*(text: string): ReplyFrame =
  let node = parseFrame(text, FrameReply)
  result.session = readSession(node)
  result.id = requireInt(node, "id")
  let ok = node{"ok"}
  if ok.isNil or ok.kind != JBool:
    raise newException(ProtocolError, "the reply frame has no boolean 'ok'")
  result.ok = ok.getBool
  if result.ok:
    let payload = node{"payload"}
    result.payload = if payload.isNil: newJNull() else: payload
  else:
    # A REFUSAL MUST NOT BE READABLE AS A SUCCESS. `errorKind` defaults to
    # `pkNone`, which is the enum's "nothing went wrong" value, so a failed
    # reply that omitted it would decode into a failure whose kind says there
    # was no failure. `pkFailed` is the floor.
    let kind = node{"errorKind"}
    result.errorKind =
      if kind.isNil or kind.kind != JString: pkFailed
      else: parseErrorKind(kind.getStr)
    if result.errorKind == pkNone:
      result.errorKind = pkFailed
    let message = node{"errorMessage"}
    result.errorMessage =
      if message.isNil or message.kind != JString: "" else: message.getStr
    # Absent is EMPTY, not an error. A server that has nothing more to say than
    # its message is the ordinary case, and a peer built before this field
    # existed is the other one; neither is a malformed frame.
    let detail = node{"detail"}
    result.detail =
      if detail.isNil or detail.kind != JString: "" else: detail.getStr

proc encodeEvent*(f: EventFrame): string =
  $withSession(%*{
    "kind": FrameEvent,
    "handle": f.handle,
    "event": f.event,
    "payload": if f.payload.isNil: newJNull() else: f.payload}, f.session)

proc decodeEvent*(text: string): EventFrame =
  let node = parseFrame(text, FrameEvent)
  result.session = readSession(node)
  result.handle = requireStr(node, "handle")
  result.event = requireStr(node, "event")
  let payload = node{"payload"}
  result.payload = if payload.isNil: newJNull() else: payload

proc frameKind*(text: string): string =
  ## Which kind a frame is, for a dispatcher that has not decided yet. Empty
  ## when the text is not a frame at all — a dispatcher reading a socket shared
  ## with the index IPC surface (§6.1) has to tolerate that rather than raise.
  var node: JsonNode
  try:
    node = parseJson(text)
  except:
    return ""
  if node.kind != JObject: return ""
  let kind = node{"kind"}
  if kind.isNil or kind.kind != JString: return ""
  kind.getStr
