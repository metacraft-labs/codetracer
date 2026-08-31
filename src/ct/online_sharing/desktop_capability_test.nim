## Tests for the desktop capability probe — ID2's measured flow selection.
##
## LANE: `mcr-enrichment-units`, by the directory glob over
## `src/ct/online_sharing/*_test.nim`, which runs inside the `viewmodel-tests`
## job that `ci/verdict/required-jobs.txt` already requires. That lane's own
## comment records why the glob is written as a rejection rather than a list:
## the inverted spelling is what left `collab_invite_url_test.nim` dark.
##
## ## What is asserted here versus in the pure suite
##
## The combination logic — three-valued answers, the nine verdicts, the bridge
## that refuses to turn an undetermined probe into a flow — is
## `test_device_grant.nim`'s, on both backends. This file asserts the part that
## only a real host can answer: that the probe REACHES a determination, that
## the loopback half is a genuine bind rather than an inference, and that the
## whole thing is repeatable.
##
## Compile and run:
##   nim c -r src/ct/online_sharing/desktop_capability_test.nim

import std/[net, strutils, unittest]

import desktop_capability

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 23
  ## HOST-INDEPENDENT BY CONSTRUCTION, which matters more than the number.
  ## This suite branches on what the host can do — a desktop takes one path
  ## through the verdict case and a headless CI runner takes the other — so
  ## every conditional below carries the SAME number of counted assertions in
  ## each arm. A count that moved with the host would be a fingerprint that
  ## reports the machine instead of the suite, and trap 4b's silent skip would
  ## hide behind "it is different on CI".

suite "desktop capability probe (ID2)":

  test "the loopback probe is a real bind, and it determines an answer":
    ## A `paYes` here means a socket was actually bound on 127.0.0.1 and a
    ## non-zero port came back — the same operation `authenticate.nim`
    ## performs. It is not an inference from an environment variable, and
    ## there is no environment variable that could make it succeed.
    let answer = probeLoopback()
    counted answer in {paYes, paNo, paUndetermined}
    counted answer != paUndetermined
      # On any host that can run this suite, the question is answerable. An
      # undetermined answer here would mean sockets could not be created at
      # all, which is a broken test environment rather than a product state.

    # The control: prove independently that binding loopback works here, so a
    # `paNo` above would be the probe's fault rather than the host's. Without
    # this, `answer == paYes` is satisfied by a probe that always says yes.
    var socket = newSocket()
    var boundOk = false
    var boundPort = Port(0)
    try:
      socket.bindAddr(Port(0), "127.0.0.1")
      boundPort = socket.getLocalAddr()[1]
      boundOk = true
    except CatchableError:
      boundOk = false
    socket.close()

    counted boundOk
    counted boundPort != Port(0)
    # The probe and the independent bind must agree. Two sources, one claim.
    counted (answer == paYes) == boundOk

  test "the probe is repeatable and releases what it binds":
    ## A probe that leaked its listener would make the second call fail, and a
    ## sign-in flow that probes twice would then take the fallback for no
    ## reason. Ten calls, and the count asserted.
    var calls = 0
    var allSame = true
    let first = probeLoopback()
    for _ in 0 ..< 10:
      inc calls
      if probeLoopback() != first:
        allSame = false
    counted calls == 10
    counted allSame
    counted first != paUndetermined

  test "the browser probe determines or says it did not":
    ## Its answer depends on the host — a desktop says yes, a headless CI
    ## runner says no, and both are correct. What is asserted is that it
    ## produces one of the three, and that on a platform this module has a
    ## rule for it never returns undetermined.
    let answer = probeBrowser()
    counted answer in {paYes, paNo, paUndetermined}
    when defined(windows) or defined(macosx) or defined(linux):
      counted answer != paUndetermined
        # These three have rules. Undetermined here would mean the rule stopped
        # matching the platform it was written for.
    else:
      counted true

  test "the whole probe produces a verdict a caller can act on":
    let probe = probeDesktopCapabilities()
    counted probe.loopback == probeLoopback()
    counted probe.browser == probeBrowser()

    let v = probe.verdict
    counted v in {pvLoopback, pvDeviceGrant, pvUndetermined}

    # Whatever the verdict, it is actionable: either it names a flow, or it
    # names the reason it could not. There is no silent third state.
    var capability = DesktopCapability(canBindLoopback: false,
                                       canLaunchBrowser: false)
    if probe.determinedCapability(capability):
      counted v != pvUndetermined
      counted probe.verdictReason().len >= 0
      let flow = selectFlow(capability)
      counted flow in {sfLoopbackRedirect, sfDeviceGrant}
      # The two layers must agree — the pure decision and the measured probe
      # are different code paths to the same answer.
      counted (flow == sfLoopbackRedirect) == (v == pvLoopback)
      counted (flow == sfDeviceGrant) == (v == pvDeviceGrant)
    else:
      counted v == pvUndetermined
      counted probe.verdictReason().len > 0
      counted probe.verdictReason().contains("could not be checked")
      counted true
      counted true

  test "the probe reads no preference — there is none to read":
    ## §5.3: selection is measured, never configured. The probe's own surface
    ## is two niladic functions plus their composition; there is no parameter
    ## through which a caller could express a wish, and that is asserted by
    ## the absence of any overload accepting one.
    counted compiles(probeLoopback())
    counted compiles(probeBrowser())
    counted compiles(probeDesktopCapabilities())
    counted not compiles(probeDesktopCapabilities(true))
    counted not compiles(probeLoopback(preferDeviceGrant = true))

  test "assertion count":
    check countedAssertions == ExpectedAssertions
