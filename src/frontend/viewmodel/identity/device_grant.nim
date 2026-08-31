## The device authorization grant, and when it engages — ID2.
##
## `CodeTracer-Identity.md` §5, as rewritten on 2026-08-31: desktop CodeTracer
## and the `ct` CLI sign in by **loopback redirect**, and fall back to the
## **device authorization grant** (RFC 8628) only where loopback *cannot run*.
##
## ## This is the flow for when the better flow cannot run
##
## It is not a better flow. It is strictly worse to use — the person copies a
## short code into a browser by hand and the application polls — and it exists
## because it is the only one that works with no launchable browser and no
## shared loopback address. `ct` over SSH, inside a container, on a headless
## build machine: there the user's browser is on a different computer, so
## `127.0.0.1` means a different machine entirely.
##
## §5 was previously titled "Desktop Cannot Redirect" and prescribed this flow
## unconditionally. That was overtaken by code shipping on `stable`:
## `src/ct/online_sharing/authenticate.nim` binds a loopback socket and
## redirects through the user's own browser, which is RFC 8252 §7.3 — the
## pattern the native-apps BCP recommends — and it keeps credentials out of our
## process exactly as well as this one does.
##
## ## Selection is MEASURED, never configured
##
## `selectFlow` takes a `DesktopCapability` and nothing else. There is no flag,
## no environment variable and no configuration key that can choose the flow,
## and that absence is a hard requirement rather than a preference:
##
##   * an environment variable that changes which authentication path runs is
##     one line from one that disables authentication, and the two are
##     indistinguishable to a reviewer reading the call site. This codebase
##     already carries `CT_LICENSE_DEV_NO_FFI`, which disables licensing
##     enforcement at runtime, so the pattern is not hypothetical here;
##   * a knob saying "use the device grant" would make the weaker flow
##     reachable while the stronger one works, which is the one state neither
##     flow's threat model covers.
##
## `DesktopCapability` therefore has exactly TWO fields, both of them
## measurements, and `test_device_grant.nim` asserts that count — a third field
## called anything like `forceDeviceGrant` fails the suite rather than shipping.
## `ci/test/identity-no-escape-hatch.sh` asserts the other half: nothing in this
## directory reads the environment at all.
##
## ## What is pure here and what is not
##
## Everything. Parsing a response, classifying a poll, computing the next
## interval and deciding whether the window has closed are all functions of
## their arguments — including the clock, which is passed in. The polling loop
## and the HTTP calls belong to the caller, for the reason `session.nim` gives:
## a module that can await can be handed something that fetches, and this one
## must not be.

import std/[json, strutils]

const
  DefaultPollInterval* = 5
    ## RFC 8628 §3.2: "interval — OPTIONAL. The minimum amount of time in
    ## seconds that the client SHOULD wait between polling requests... If no
    ## value is provided, clients MUST use 5 as the default."
  SlowDownIncrement* = 5
    ## RFC 8628 §3.5: on `slow_down` the client "MUST increase the polling
    ## interval by 5 seconds for this and all subsequent requests".
  MaxPollInterval* = 60
    ## Not in the RFC. A server that answers `slow_down` forever would
    ## otherwise drive the interval up without bound; capping it keeps the
    ## deadline check below meaningful rather than letting a single sleep
    ## outlast the whole window.

type
  DesktopCapability* = object
    ## What the host can actually do. Both fields are MEASUREMENTS — the
    ## result of trying to bind a loopback listener and of looking for a
    ## browser this process can launch — never settings.
    ##
    ## EXACTLY TWO FIELDS, ASSERTED. A third one would be the configuration
    ## this design exists to refuse.
    canBindLoopback*: bool
    canLaunchBrowser*: bool

  SignInFlow* = enum
    sfLoopbackRedirect
      ## The default. RFC 8252 §7.3.
    sfDeviceGrant
      ## The fallback, for hosts where loopback cannot run.

  DeviceAuthorization* = object
    ## RFC 8628 §3.2's response. Fields unexported: the device code is a
    ## SECRET and the user code is not, and a type whose fields are all equally
    ## reachable invites showing the wrong one.
    deviceCodeField: string
    userCodeField: string
    verificationUriField: string
    verificationUriCompleteField: string
    expiresAtField: int64
    intervalField: int

  PollOutcome* = enum
    poPending
      ## `authorization_pending`. Keep polling at the current interval.
    poSlowDown
      ## `slow_down`. Keep polling, but slower — and the increase PERSISTS.
    poComplete
      ## A token was issued.
    poDenied
      ## `access_denied`. The person said no; stop.
    poExpired
      ## `expired_token`, or our own clock says the window closed.
    poMalformed
      ## Not a shape RFC 8628 defines. Stop, rather than guess.

# ---------------------------------------------------------------------------
# THE SELECTION. One function, two measurements, no configuration.
# ---------------------------------------------------------------------------
func selectFlow*(capability: DesktopCapability): SignInFlow =
  ## Loopback needs BOTH a browser this process can launch and a loopback
  ## address the user's browser can reach. Either one missing takes the
  ## fallback; nothing else participates.
  if capability.canBindLoopback and capability.canLaunchBrowser:
    sfLoopbackRedirect
  else:
    sfDeviceGrant

func fallbackReason*(capability: DesktopCapability): string =
  ## Why the fallback engaged, for the message the user sees. Empty when it did
  ## not. A fallback that cannot say why it happened is indistinguishable to a
  ## user from one that happened for no reason.
  if selectFlow(capability) == sfLoopbackRedirect:
    return ""
  if not capability.canBindLoopback and not capability.canLaunchBrowser:
    return "no loopback address could be bound and no browser could be launched"
  if not capability.canBindLoopback:
    return "no loopback address could be bound"
  "no browser could be launched"

# ---------------------------------------------------------------------------
# Accessors. The device code is deliberately awkward to reach.
# ---------------------------------------------------------------------------
func userCode*(a: DeviceAuthorization): string = a.userCodeField
func verificationUri*(a: DeviceAuthorization): string = a.verificationUriField
func verificationUriComplete*(a: DeviceAuthorization): string =
  a.verificationUriCompleteField
func expiresAt*(a: DeviceAuthorization): int64 = a.expiresAtField
func pollInterval*(a: DeviceAuthorization): int = a.intervalField

func secretDeviceCode*(a: DeviceAuthorization): string =
  ## Named to be conspicuous at every call site. This is the bearer secret the
  ## client exchanges for a token; it is NOT the code the person types, and
  ## showing it — on screen, in a log, in a screenshot of a terminal — hands
  ## the session to anyone who can read it.
  a.deviceCodeField

func displayPrompt*(a: DeviceAuthorization): string =
  ## The whole user-facing text, built here so that no caller has to decide
  ## which code is safe to show. `test_device_grant.nim` asserts this never
  ## contains the device code — a behavioural check rather than a naming
  ## convention, because a naming convention is not enforcement.
  "To sign in, visit " & a.verificationUriField &
    " and enter the code " & a.userCodeField

# ---------------------------------------------------------------------------
# Parsing. Both parsers use a BARE `except:`, and CONTRIBUTING.md says why: on
# the C backend `parseJson` raises `JsonParsingError`, a `CatchableError`; on
# the JS backend it defers to V8's `JSON.parse`, which throws a raw
# `SyntaxError` that no Nim exception type matches. This module runs on both
# backends and parses input that arrives over the network, so the narrow form
# would be a crash on the backend the renderer ships on.
# ---------------------------------------------------------------------------
proc parseDeviceAuthorization*(payload: string; nowUnix: int64;
                               auth: var DeviceAuthorization): string =
  ## Returns an error sentence, or "" and fills `auth`. `expires_in` is
  ## converted to an ABSOLUTE deadline here, against the clock passed in, so
  ## that nothing downstream has to remember when polling started.
  var node: JsonNode
  try:
    node = parseJson(payload)
  except:
    return "the device authorization response is not valid JSON"
  if node.kind != JObject:
    return "the device authorization response is not a JSON object"

  func str(n: JsonNode; key: string): string =
    let f = n{key}
    if f.isNil or f.kind != JString: "" else: f.getStr

  func num(n: JsonNode; key: string): int64 =
    let f = n{key}
    if f.isNil or f.kind != JInt: 0'i64 else: f.getBiggestInt

  auth.deviceCodeField = str(node, "device_code")
  auth.userCodeField = str(node, "user_code")
  auth.verificationUriField = str(node, "verification_uri")
  auth.verificationUriCompleteField = str(node, "verification_uri_complete")

  if auth.deviceCodeField.len == 0:
    return "the response carries no device_code"
  if auth.userCodeField.len == 0:
    return "the response carries no user_code"
  if auth.verificationUriField.len == 0:
    return "the response carries no verification_uri"

  let expiresIn = num(node, "expires_in")
  if expiresIn <= 0:
    return "the response carries no expires_in, so the poll would never end"
  auth.expiresAtField = nowUnix + expiresIn

  let interval = num(node, "interval")
  auth.intervalField =
    if interval <= 0: DefaultPollInterval else: int(interval)
  ""

proc classifyPollResponse*(payload: string): PollOutcome =
  ## RFC 8628 §3.5's four error codes, plus success. Anything else is
  ## `poMalformed` and stops the loop: a poll that cannot understand the answer
  ## must not keep asking.
  var node: JsonNode
  try:
    node = parseJson(payload)
  except:
    return poMalformed
  if node.kind != JObject:
    return poMalformed

  let errorNode = node{"error"}
  if errorNode.isNil or errorNode.kind != JString:
    # Success is the absence of an error AND the presence of a token. A
    # response with neither is malformed rather than complete — an empty JSON
    # object must never read as "signed in".
    let token = node{"access_token"}
    if token.isNil or token.kind != JString or token.getStr.len == 0:
      return poMalformed
    return poComplete

  case errorNode.getStr
  of "authorization_pending": poPending
  of "slow_down": poSlowDown
  of "access_denied": poDenied
  of "expired_token": poExpired
  else: poMalformed

# ---------------------------------------------------------------------------
# The polling rules.
# ---------------------------------------------------------------------------
func nextInterval*(current: int; outcome: PollOutcome): int =
  ## RFC 8628 §3.5: `slow_down` increases the interval "for this and all
  ## subsequent requests" — so the increase PERSISTS, and returning to the
  ## original interval on the next `authorization_pending` would be the common
  ## implementation of this rule and the wrong one.
  if outcome != poSlowDown:
    return current
  min(current + SlowDownIncrement, MaxPollInterval)

func windowClosed*(auth: DeviceAuthorization; nowUnix: int64): bool =
  ## Our own clock, not only the server's `expired_token`. A client that polls
  ## a dead device code until the server bothers to say so is a loop with no
  ## end condition of its own.
  nowUnix >= auth.expiresAtField

func shouldKeepPolling*(outcome: PollOutcome; auth: DeviceAuthorization;
                        nowUnix: int64): bool =
  ## The only two outcomes that continue are the two RFC 8628 defines as
  ## continuations — and neither continues past the deadline.
  if windowClosed(auth, nowUnix):
    return false
  outcome in {poPending, poSlowDown}

func terminalDetail*(outcome: PollOutcome): string =
  case outcome
  of poComplete: ""
  of poDenied: "the sign-in was declined"
  of poExpired: "the code expired before it was entered"
  of poMalformed: "the authorization server sent a response this client does not understand"
  of poPending, poSlowDown: ""
