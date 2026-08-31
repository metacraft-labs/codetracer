## Measuring what this host can actually do, for ID2's flow selection.
##
## `viewmodel/identity/device_grant.nim` decides WHICH sign-in flow to use.
## This decides nothing. It measures the two capabilities that decision names,
## and it lives here — outside `viewmodel/identity/` — for a reason worth
## stating: the decision layer is asserted to read no environment variable at
## all (`ci/test/identity-no-escape-hatch.sh`), and measuring a host means
## reading the environment. Separating them is what lets the first assertion
## be absolute while the second does its job.
##
## ## Two capabilities, and not one more
##
## `DesktopCapability` has exactly two fields and `test_device_grant.nim`
## asserts that count at compile time. The value of that is lost if the probe
## grows a third input on the way in, so this module measures exactly:
##
##   loopback  can a listener be bound on 127.0.0.1?
##   browser   is there a browser this process can launch?
##
## Nothing here reads a preference, a flag or a "which flow" setting. There is
## no such thing to read — §5.3 of `CodeTracer-Identity.md`, and the reason is
## that an environment variable which changes an authentication path is one
## line from one that disables authentication.
##
## ## The loopback half is a real bind, not an inference
##
## It opens a socket and binds an ephemeral port on 127.0.0.1, then closes it.
## That is the same operation `authenticate.nim` performs for real, so a `yes`
## here means the thing itself worked rather than that some proxy for it looked
## plausible. It cannot be forced by configuration: there is no environment
## variable that makes a bind succeed.
##
## ## The browser half must read the environment, and that is a measurement
##
## On Linux there is no way to know whether a browser can be launched without
## looking at `DISPLAY` / `WAYLAND_DISPLAY` and the opener on `PATH`. Someone
## could clear `DISPLAY` to push themselves onto the device grant — and that is
## fine, because it is TRUE when they do: with no display there is no browser
## to open. The direction that would matter is the other one, forcing loopback
## where it cannot work, and that fails closed by simply not working. Neither
## direction grants any access, which is the property that makes this a
## measurement rather than a switch.
##
## ## Undetermined is a real answer
##
## A platform this module has no rule for answers `paUndetermined`, and so does
## a socket failure it cannot classify. It never guesses, and it never defaults
## to yes: `device_grant.determinedCapability` refuses to turn an undetermined
## probe into a flow, so the caller is forced to handle "we do not know"
## instead of silently signing the user into a path that cannot run.

import std/[net, os, strutils]

import ../../frontend/viewmodel/identity/device_grant

export device_grant

proc probeLoopback*(): ProbeAnswer =
  ## Bind an ephemeral port on 127.0.0.1 and release it. The same operation
  ## `authenticate.nim` does for real.
  var socket: Socket
  try:
    socket = newSocket()
  except CatchableError:
    # We could not even create a socket. That is not "loopback is unavailable";
    # it is "we could not find out", and the difference decides whether a user
    # is told the fallback engaged or told nothing could be determined.
    return paUndetermined
  except:
    return paUndetermined

  try:
    socket.bindAddr(Port(0), "127.0.0.1")
    let bound = socket.getLocalAddr()
    socket.close()
    # A bind that reports port 0 bound nothing; treat it as unmeasured rather
    # than as success, because the port is the evidence.
    if bound[1] == Port(0):
      return paUndetermined
    paYes
  except OSError:
    # A refused bind IS a measurement: this host cannot do it.
    try: socket.close() except CatchableError: discard except: discard
    paNo
  except CatchableError:
    try: socket.close() except CatchableError: discard except: discard
    paUndetermined
  except:
    paUndetermined

proc probeBrowser*(): ProbeAnswer =
  ## Is there a browser this process can launch? Platform rules, and an honest
  ## `paUndetermined` for anything not covered.
  when defined(windows):
    # `start` is a shell builtin and `rundll32` is always present; there is no
    # headless Windows desktop session this product supports.
    paYes
  elif defined(macosx):
    # `open` is part of the base system. Its absence means something is very
    # wrong rather than that a browser is missing, so it is a measurement
    # either way.
    if fileExists("/usr/bin/open"): paYes else: paNo
  elif defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    # Two things are needed and BOTH are checked: an opener on PATH, and a
    # graphical session for it to open into. `xdg-open` with no display exits
    # non-zero and opens nothing, which is exactly the SSH and container case
    # the device grant exists for.
    var opener = false
    for candidate in ["xdg-open", "gio", "gnome-open", "kde-open", "x-www-browser",
                      "sensible-browser", "firefox", "chromium", "google-chrome"]:
      if findExe(candidate).len > 0:
        opener = true
        break
    let display = getEnv("DISPLAY").strip().len > 0 or
                  getEnv("WAYLAND_DISPLAY").strip().len > 0
    if opener and display: paYes else: paNo
  else:
    # A platform with no rule here. Saying "no" would push every user of it
    # onto the fallback on no evidence; saying "yes" would strand them. Saying
    # "we did not check" is the only honest answer, and the decision layer
    # knows what to do with it.
    paUndetermined

proc probeDesktopCapabilities*(): CapabilityProbe =
  ## The whole measurement. Exactly two probes, matching the two fields the
  ## decision record names.
  CapabilityProbe(loopback: probeLoopback(), browser: probeBrowser())
