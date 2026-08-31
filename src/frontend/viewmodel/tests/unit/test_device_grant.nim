## Headless tests for the device authorization grant and the measured flow
## selection — ID2.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob. The JS arm is
## load-bearing rather than duplicative: both parsers here take attacker-shaped
## JSON off the network and guard with a bare `except:`, and CONTRIBUTING.md's
## portability rule is exactly about that — `parseJson` raises a
## `CatchableError` on C and V8 throws a raw `SyntaxError` on JS that no Nim
## type matches. `parses nothing that is not a device authorization response`
## is the case that would catch a narrowing.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_device_grant.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_device_grant.nim

import std/[json, strutils, unittest]

import ../../identity/device_grant

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 162
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

const T0 = 1_787_875_200'i64

proc authJson(deviceCode = "dev-secret-8f21";
              userCode = "WDJB-MJHT";
              verificationUri = "https://ide.codetracer.com/device";
              complete = "";
              expiresIn = 900;
              interval = 5): string =
  ## The issuer's shape, written out from RFC 8628 §3.2's field names rather
  ## than from the parser, so a parser that stopped reading a field could not
  ## make the two agree.
  var n = %*{
    "device_code": deviceCode,
    "user_code": userCode,
    "verification_uri": verificationUri
  }
  if complete.len > 0: n["verification_uri_complete"] = %complete
  if expiresIn != 0: n["expires_in"] = %expiresIn
  if interval != 0: n["interval"] = %interval
  $n

proc parsed(payload: string; nowUnix = T0): (string, DeviceAuthorization) =
  var a = DeviceAuthorization()
  let err = parseDeviceAuthorization(payload, nowUnix, a)
  (err, a)

suite "device authorization grant (ID2)":

  # -------------------------------------------------------------------------
  test "the fallback engages only when loopback cannot run":
    ## §5.3: measured, never configured. All four combinations, and the count
    ## asserted — a table with a missing row is how a rule comes to have an
    ## untested case.
    var combos = 0
    for bindOk in [true, false]:
      for browserOk in [true, false]:
        inc combos
        let cap = DesktopCapability(canBindLoopback: bindOk,
                                    canLaunchBrowser: browserOk)
        let want = if bindOk and browserOk: sfLoopbackRedirect else: sfDeviceGrant
        counted selectFlow(cap) == want
    counted combos == 4

    # The default is loopback, and it is the ONLY combination that gets it.
    counted selectFlow(DesktopCapability(canBindLoopback: true,
                                         canLaunchBrowser: true)) == sfLoopbackRedirect
    counted selectFlow(DesktopCapability(canBindLoopback: false,
                                         canLaunchBrowser: true)) == sfDeviceGrant
    counted selectFlow(DesktopCapability(canBindLoopback: true,
                                         canLaunchBrowser: false)) == sfDeviceGrant
    counted selectFlow(DesktopCapability(canBindLoopback: false,
                                         canLaunchBrowser: false)) == sfDeviceGrant

  # -------------------------------------------------------------------------
  test "nothing but a measurement can select the flow":
    ## THE STRUCTURAL HALF OF §5.3. A flag would make the weaker flow reachable
    ## while the stronger one works, and an environment variable that changes
    ## an auth path is one line from `CT_LICENSE_DEV_NO_FFI`.
    ##
    ## `DesktopCapability` must therefore have EXACTLY TWO FIELDS, both
    ## measurements. This is asserted at compile time: a third field — however
    ## it is spelled — makes the object constructor below fail to compile,
    ## and `fieldCount` moves.
    var fields = 0
    let cap = DesktopCapability(canBindLoopback: true, canLaunchBrowser: true)
    for _, _ in cap.fieldPairs:
      inc fields
    counted fields == 2

    # Both are booleans about what the HOST CAN DO. A field that named a
    # preference rather than a capability would not compile into this loop's
    # expectations, but the count is the guard that actually holds.
    counted compiles(DesktopCapability(canBindLoopback: true,
                                       canLaunchBrowser: false))
    counted not compiles(DesktopCapability(canBindLoopback: true,
                                           canLaunchBrowser: true,
                                           forceDeviceGrant: true))
    counted not compiles(DesktopCapability(preferDeviceGrant: true))

    # `selectFlow` takes the capability and nothing else — there is no overload
    # that accepts a setting alongside it.
    counted compiles(selectFlow(cap))
    counted not compiles(selectFlow(cap, true))

  # -------------------------------------------------------------------------
  test "the fallback says why it engaged":
    let both = DesktopCapability(canBindLoopback: true, canLaunchBrowser: true)
    counted fallbackReason(both).len == 0

    let noBind = DesktopCapability(canBindLoopback: false, canLaunchBrowser: true)
    counted fallbackReason(noBind).contains("loopback")
    counted not fallbackReason(noBind).contains("browser")

    let noBrowser = DesktopCapability(canBindLoopback: true, canLaunchBrowser: false)
    counted fallbackReason(noBrowser).contains("browser")
    counted not fallbackReason(noBrowser).contains("loopback address could be bound and")

    let neither = DesktopCapability(canBindLoopback: false, canLaunchBrowser: false)
    counted fallbackReason(neither).contains("loopback")
    counted fallbackReason(neither).contains("browser")
    # Every non-default combination has a reason; none is silent.
    var reasons = 0
    for bindOk in [true, false]:
      for browserOk in [true, false]:
        let cap = DesktopCapability(canBindLoopback: bindOk, canLaunchBrowser: browserOk)
        if selectFlow(cap) == sfDeviceGrant:
          inc reasons
          counted fallbackReason(cap).len > 0
    counted reasons == 3

  # -------------------------------------------------------------------------
  test "a device authorization response is parsed into an absolute deadline":
    let (err, a) = parsed(authJson())
    counted err.len == 0
    counted a.userCode == "WDJB-MJHT"
    counted a.verificationUri == "https://ide.codetracer.com/device"
    counted a.secretDeviceCode == "dev-secret-8f21"
    counted a.pollInterval == 5
    # expires_in is RELATIVE; the deadline stored is ABSOLUTE, so nothing
    # downstream has to remember when polling started.
    counted a.expiresAt == T0 + 900
    counted a.expiresAt != 900

    # Parsed against a different clock, the deadline moves with it.
    let (err2, a2) = parsed(authJson(), nowUnix = T0 + 1000)
    counted err2.len == 0
    counted a2.expiresAt == T0 + 1000 + 900

    # RFC 8628 §3.2: interval is OPTIONAL and defaults to 5.
    let (err3, a3) = parsed(authJson(interval = 0))
    counted err3.len == 0
    counted a3.pollInterval == DefaultPollInterval
    counted DefaultPollInterval == 5

    # verification_uri_complete is optional and carried when present.
    let (err4, a4) = parsed(authJson(complete = "https://ide.codetracer.com/device?user_code=WDJB-MJHT"))
    counted err4.len == 0
    counted a4.verificationUriComplete.contains("user_code=")
    counted parsed(authJson())[1].verificationUriComplete.len == 0

  # -------------------------------------------------------------------------
  test "the device code is never in what the user is shown":
    ## The user code is displayed; the device code is a bearer secret. Showing
    ## it — on screen, in a log, in a screenshot of a terminal — hands the
    ## session to whoever reads it. Asserted behaviourally rather than by
    ## naming convention, because a naming convention is not enforcement.
    let (_, a) = parsed(authJson())
    let prompt = a.displayPrompt()
    counted prompt.contains("WDJB-MJHT")
    counted prompt.contains("https://ide.codetracer.com/device")
    counted not prompt.contains("dev-secret-8f21")
    counted not prompt.contains(a.secretDeviceCode)

    # The positive twin: a device code that IS present would be found by the
    # same check. Without this, `not contains` would also pass over a prompt
    # that was empty, or a `contains` that could not match.
    counted ("prefix " & a.secretDeviceCode & " suffix").contains(a.secretDeviceCode)
    counted a.secretDeviceCode.len > 0
    counted prompt.len > 0

    # A distinctive device code, to rule out the codes coincidentally sharing
    # a substring.
    let (_, b) = parsed(authJson(deviceCode = "ZZZZ-UNIQUE-DEVICE-SECRET",
                                 userCode = "AAAA-BBBB"))
    counted not b.displayPrompt().contains("ZZZZ-UNIQUE-DEVICE-SECRET")
    counted b.displayPrompt().contains("AAAA-BBBB")

  # -------------------------------------------------------------------------
  test "a response missing a required field is refused, each by name":
    counted parsed(authJson(deviceCode = ""))[0].contains("device_code")
    counted parsed(authJson(userCode = ""))[0].contains("user_code")
    counted parsed(authJson(verificationUri = ""))[0].contains("verification_uri")
    counted parsed(authJson(expiresIn = 0))[0].contains("expires_in")
    # The positive twin for all four: unmutated, it parses.
    counted parsed(authJson())[0].len == 0

    # A missing expires_in is refused rather than defaulted, because the
    # default would be "poll forever".
    counted parsed(authJson(expiresIn = 0))[0].contains("never end")

  # -------------------------------------------------------------------------
  test "parses nothing that is not a device authorization response":
    ## THE BACKEND-PORTABILITY CASE, for the same reason
    ## `test_identity_token.nim` carries one: on C this exercises
    ## `JsonParsingError`; on JS it exercises V8's raw `SyntaxError`, which no
    ## Nim exception type matches. Narrowing either bare `except:` in
    ## `device_grant.nim` passes under `nim c` and CRASHES under `nim js`.
    counted parsed("not json at all {{{")[0].contains("not valid JSON")
    counted parsed("[1, 2, 3]")[0].contains("not a JSON object")
    counted parsed("")[0].len > 0
    counted classifyPollResponse("not json at all {{{") == poMalformed
    counted classifyPollResponse("[1,2,3]") == poMalformed
    counted classifyPollResponse("") == poMalformed

  # -------------------------------------------------------------------------
  test "poll responses classify to RFC 8628's outcomes":
    counted classifyPollResponse("""{"error":"authorization_pending"}""") == poPending
    counted classifyPollResponse("""{"error":"slow_down"}""") == poSlowDown
    counted classifyPollResponse("""{"error":"access_denied"}""") == poDenied
    counted classifyPollResponse("""{"error":"expired_token"}""") == poExpired
    counted classifyPollResponse("""{"access_token":"tok"}""") == poComplete

    # An unknown error code stops the loop rather than being guessed at.
    counted classifyPollResponse("""{"error":"something_new"}""") == poMalformed

    # AN EMPTY OBJECT MUST NOT READ AS SIGNED IN. Success is the presence of a
    # token, not the absence of an error — the same shape as trap 2, where a
    # chain of `success: true` was green over a session that opened nothing.
    counted classifyPollResponse("{}") == poMalformed
    counted classifyPollResponse("""{"access_token":""}""") == poMalformed
    counted classifyPollResponse("""{"scope":"all"}""") == poMalformed
    counted classifyPollResponse("""{"access_token":123}""") == poMalformed

    # Each of the five outcomes is produced by exactly one input above, so no
    # two collapse.
    var seen: set[PollOutcome] = {}
    for payload in ["""{"error":"authorization_pending"}""",
                    """{"error":"slow_down"}""",
                    """{"error":"access_denied"}""",
                    """{"error":"expired_token"}""",
                    """{"access_token":"tok"}"""]:
      seen.incl classifyPollResponse(payload)
    counted seen == {poPending, poSlowDown, poDenied, poExpired, poComplete}
    counted card(seen) == 5

  # -------------------------------------------------------------------------
  test "slow_down raises the interval and the rise persists":
    ## RFC 8628 §3.5: the client "MUST increase the polling interval by 5
    ## seconds for THIS AND ALL SUBSEQUENT requests". Returning to the original
    ## interval on the next `authorization_pending` is the obvious
    ## implementation and the wrong one, so the persistence is walked rather
    ## than asserted once.
    counted nextInterval(5, poSlowDown) == 10
    counted SlowDownIncrement == 5

    # Persistence: pending after a slow_down keeps the raised interval.
    var interval = 5
    interval = nextInterval(interval, poSlowDown)
    counted interval == 10
    interval = nextInterval(interval, poPending)
    counted interval == 10
    interval = nextInterval(interval, poSlowDown)
    counted interval == 15
    interval = nextInterval(interval, poPending)
    counted interval == 15

    # No other outcome moves it.
    for outcome in [poPending, poComplete, poDenied, poExpired, poMalformed]:
      counted nextInterval(15, outcome) == 15

    # And it is capped, so a server answering slow_down forever cannot drive a
    # single sleep past the whole window.
    var runaway = 5
    for _ in 0 ..< 50:
      runaway = nextInterval(runaway, poSlowDown)
    counted runaway == MaxPollInterval
    counted MaxPollInterval == 60
    counted runaway < 900

  # -------------------------------------------------------------------------
  test "polling stops at the deadline, on our own clock":
    let (_, a) = parsed(authJson(expiresIn = 900))
    counted not windowClosed(a, T0)
    counted not windowClosed(a, T0 + 899)
    counted windowClosed(a, T0 + 900)
    counted windowClosed(a, T0 + 901)

    # Pending keeps polling inside the window and stops outside it — even
    # though the server is still answering `authorization_pending`. A client
    # that waits for the server to say `expired_token` is a loop with no end
    # condition of its own.
    counted shouldKeepPolling(poPending, a, T0)
    counted shouldKeepPolling(poSlowDown, a, T0)
    counted not shouldKeepPolling(poPending, a, T0 + 900)
    counted not shouldKeepPolling(poSlowDown, a, T0 + 900)

    # The three terminal outcomes never continue, inside the window or out.
    var terminals = 0
    for outcome in [poComplete, poDenied, poExpired, poMalformed]:
      inc terminals
      counted not shouldKeepPolling(outcome, a, T0)
      counted not shouldKeepPolling(outcome, a, T0 + 1000)
    counted terminals == 4

    # Every terminal outcome except success can say why.
    counted terminalDetail(poComplete).len == 0
    counted terminalDetail(poDenied).len > 0
    counted terminalDetail(poExpired).len > 0
    counted terminalDetail(poMalformed).len > 0

  # -------------------------------------------------------------------------
  test "an unprobed capability reads as undetermined, never as yes":
    ## THE ZERO-VALUE PROPERTY, and it is a property of the enum's declaration
    ## order rather than of any code. Nim zero-initialises, so if `paYes` were
    ## first, a `CapabilityProbe` nobody filled in would read as "loopback
    ## works" — and every headless and SSH user would be handed a flow that
    ## cannot run, with nothing anywhere saying the probe never happened.
    ## An innocent-looking reorder of the enum would do it, so it is asserted.
    counted CapabilityProbe().loopback == paUndetermined
    counted CapabilityProbe().browser == paUndetermined
    counted CapabilityProbe().verdict == pvUndetermined
    counted CapabilityProbe().verdict != pvLoopback
    counted ord(paUndetermined) == 0
    counted ord(paUndetermined) < ord(paYes)

    # And the probe record carries no more than the decision record does.
    var probeFields = 0
    for _, _ in CapabilityProbe().fieldPairs:
      inc probeFields
    counted probeFields == 2
    counted not compiles(CapabilityProbe(loopback: paYes, browser: paYes,
                                         forceDeviceGrant: true))

  # -------------------------------------------------------------------------
  test "a probe that could not measure says so instead of defaulting":
    ## All nine combinations, with the count asserted — a three-valued pair has
    ## nine cases and a table with a missing row is how a rule comes to have an
    ## untested one.
    var combos = 0
    var loopbackVerdicts = 0
    var deviceVerdicts = 0
    var undeterminedVerdicts = 0
    for lb in [paUndetermined, paYes, paNo]:
      for br in [paUndetermined, paYes, paNo]:
        inc combos
        let p = CapabilityProbe(loopback: lb, browser: br)
        let want =
          if lb == paNo or br == paNo: pvDeviceGrant
          elif lb == paUndetermined or br == paUndetermined: pvUndetermined
          else: pvLoopback
        counted p.verdict == want
        case want
        of pvLoopback: inc loopbackVerdicts
        of pvDeviceGrant: inc deviceVerdicts
        of pvUndetermined: inc undeterminedVerdicts
    counted combos == 9
    counted loopbackVerdicts == 1
    counted deviceVerdicts == 5
    counted undeterminedVerdicts == 3

    # A definite NO outranks an unmeasured half: if the browser cannot be
    # launched it does not matter whether loopback binds. Reversing the two
    # checks would report "we do not know" about a case we do know.
    counted CapabilityProbe(loopback: paUndetermined, browser: paNo).verdict == pvDeviceGrant
    counted CapabilityProbe(loopback: paNo, browser: paUndetermined).verdict == pvDeviceGrant

    # An undetermined verdict names ITSELF and never borrows the fallback's
    # wording — "we did not check" must not read as "we checked and it failed".
    let unchecked = CapabilityProbe(loopback: paUndetermined, browser: paYes)
    counted unchecked.verdict == pvUndetermined
    counted unchecked.verdictReason().contains("could not be checked")
    counted not unchecked.verdictReason().contains("could be bound and")

    let measuredNo = CapabilityProbe(loopback: paNo, browser: paYes)
    counted measuredNo.verdictReason().contains("no loopback address could be bound")
    counted not measuredNo.verdictReason().contains("could not be checked")
    # The two are different sentences for the same half of the probe.
    counted unchecked.verdictReason() != measuredNo.verdictReason()

    # Every non-loopback verdict has a reason; the loopback one has none.
    counted CapabilityProbe(loopback: paYes, browser: paYes).verdictReason().len == 0
    var reasoned = 0
    for lb in [paUndetermined, paYes, paNo]:
      for br in [paUndetermined, paYes, paNo]:
        let p = CapabilityProbe(loopback: lb, browser: br)
        if p.verdict != pvLoopback:
          inc reasoned
          counted p.verdictReason().len > 0
    counted reasoned == 8

  # -------------------------------------------------------------------------
  test "an undetermined probe cannot become a flow":
    ## THE BRIDGE. `DesktopCapability` — the two booleans `selectFlow` consumes
    ## — is producible ONLY from a probe that determined both halves, so there
    ## is no path by which "we did not check" turns into a decision.
    var cap = DesktopCapability(canBindLoopback: true, canLaunchBrowser: true)

    counted not CapabilityProbe().determinedCapability(cap)
    counted not CapabilityProbe(loopback: paYes,
                                browser: paUndetermined).determinedCapability(cap)
    counted not CapabilityProbe(loopback: paUndetermined,
                                browser: paYes).determinedCapability(cap)

    # Determined probes DO produce one, and it carries the measurement.
    var got = DesktopCapability(canBindLoopback: false, canLaunchBrowser: false)
    counted CapabilityProbe(loopback: paYes, browser: paYes).determinedCapability(got)
    counted got.canBindLoopback
    counted got.canLaunchBrowser
    counted selectFlow(got) == sfLoopbackRedirect

    counted CapabilityProbe(loopback: paNo, browser: paYes).determinedCapability(got)
    counted not got.canBindLoopback
    counted got.canLaunchBrowser
    counted selectFlow(got) == sfDeviceGrant

    # A NO on one side with the other unmeasured is DETERMINED — the verdict is
    # device grant — so it does produce a capability.
    counted CapabilityProbe(loopback: paNo,
                            browser: paUndetermined).determinedCapability(got)
    counted selectFlow(got) == sfDeviceGrant

    # Count the determined ones: 6 of the 9 combinations.
    var determined = 0
    var scratch = DesktopCapability(canBindLoopback: false, canLaunchBrowser: false)
    for lb in [paUndetermined, paYes, paNo]:
      for br in [paUndetermined, paYes, paNo]:
        if CapabilityProbe(loopback: lb, browser: br).determinedCapability(scratch):
          inc determined
    counted determined == 6

  # -------------------------------------------------------------------------
  test "assertion count":
    check countedAssertions == ExpectedAssertions
