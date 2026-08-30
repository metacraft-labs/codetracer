## The front end's single entry point to the platform facade.
##
## ## Why front-end code imports this rather than `viewmodel/platform/platform`
##
## Two reasons, and the second is the one that matters.
##
## 1. **It picks the instantiation.** A `nim js` renderer gets the Electron one,
##    a native build gets the native one, and no caller has to know which. The
##    `when defined(js)` lives here, once, instead of at every call site — which
##    is the same argument the facade itself makes one level down.
##
## 2. **It renames the accessor.** `platform()` is a name several modules in
##    this tree already use for other things (`isonim/core/platform`,
##    `nim_everywhere/platform`), and `renderer.nim` imports enough of both
##    worlds that an unqualified `platform()` is an ambiguity waiting to
##    happen. `ctPlatform()` is unmistakable at a call site and does not
##    collide.
##
## ## Installation is lazy and idempotent
##
## The first `ctPlatform()` installs the right instantiation; every later call
## returns it. There is no start-up ordering to get wrong, and a module that
## reaches for the platform during its own initialisation gets a working one
## rather than a refusal — which matters because module init order in a `nim js`
## bundle is not something a caller controls.

import viewmodel/platform/platform as platform_facade
import viewmodel/viewmodels/topbar_actions

export platform_facade, topbar_actions

when defined(js):
  import viewmodel/host/desktop_electron
else:
  import viewmodel/host/desktop_native

proc ctPlatform*(): Platform =
  ## The platform this front end is running on.
  ##
  ## Ask it what you *can do* (`ctPlatform().can(capClipboardWrite)`), not what
  ## you are (`ctPlatform().kind == pkDesktop`). The first survives a fourth
  ## platform; the second is a `defined()` wearing a different hat.
  # Bootstrap a DESKTOP platform only if nobody has chosen one.
  #
  # Without the guard the web instantiation cannot survive its own start-up:
  # `web_platform.install()` calls `installPlatform` directly — it is in the
  # host-free surface and must not import this module — so the very next
  # `ctPlatform()` from anywhere in the front end overwrote the freshly booted
  # web platform with the Electron one. A browser tab would then hold a
  # platform claiming `capProcessSpawn`, `capFilesystemArbitraryPaths` and a
  # keychain, backed by `require('child_process')`. Nothing fails to compile,
  # nothing fails a suite, `boot()` reports success, and the product runs the
  # wrong instantiation — the shape of defect NS1's capability model exists to
  # remove, reintroduced one layer below it.
  #
  # THE CONDITION IS THE FACADE'S FLAG, NOT A LOCAL ONE. This proc used to keep
  # its own `bootstrapped` var, and keeping it alongside the guard was itself a
  # defect: `resetPlatformForTesting()` clears the facade and cannot reach a
  # private var here, so a suite that reset and then called `ctPlatform()` got
  # the refusing `uninstalledProfile` instead of a platform. That is not
  # hypothetical either — it is what the counter-check in
  # `tests/platform_bootstrap_test.nim` caught on its first run. Two flags for
  # one fact is one flag too many.
  #
  # `platformWasExplicitlyChosen()` and not `platformInstalled()`: the latter
  # is true after any bare `platform()` read has materialised the lazy default,
  # which would leave every desktop build with no instantiation at all.
  if not platformWasExplicitlyChosen():
    when defined(js):
      installPlatform(newDesktopElectronPlatform())
    else:
      installPlatform(newDesktopNativePlatform())
  platform_facade.platform()

proc ctAwaitSync*[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## Settle a facade call whose caller cannot yet be asynchronous.
  ##
  ## ## Why this exists, and why it is not a hole in the design
  ##
  ## NS1 requires facade *signatures* to express latency, and they do. It does
  ## not require every existing caller to be rewritten as a continuation in one
  ## pass, and pretending otherwise would mean either a much larger diff than
  ## anyone can review or a facade nobody adopts. This is the bridge: a caller
  ## that is synchronous today keeps its shape, and the facade keeps its
  ## contract.
  ##
  ## ## Why it fails loudly rather than blocking
  ##
  ## It drains nim-everywhere's callback queue once. That settles anything the
  ## *local* instantiations produce, because their work really is synchronous
  ## underneath. It cannot settle a genuinely remote call — and it does not try:
  ## there is no spin, no sleep and no event-loop reentry, because a renderer
  ## that spins on a network hop is a frozen window, which is the failure §9.3
  ## names.
  ##
  ## An unsettled future therefore returns `pkTimeout` naming this function. That
  ## is the point: the day one of these call sites runs against the container
  ## instantiation, it reports "this call site still needs converting" instead of
  ## silently reading a zero value. A bridge that returned a default here would
  ## hide exactly the work NS2 and WD1 need to find.
  var captured: PlatformOutcome[T]
  var settled = false

  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true

  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the platform call failed", message)
    settled = true

  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()

  if not settled:
    return failed[T](
      pkTimeout,
      "this call site needs an asynchronous caller",
      "ctAwaitSync drained once and the platform had not answered; the " &
      "instantiation is remote, so the caller must be converted to a " &
      "continuation (NS1)")
  captured

proc ctTopbar*(fullscreen = false): TopbarModel =
  ## The topbar's action set for the running platform.
  ##
  ## Exposed here rather than leaving `ui/menu.nim` to write
  ## `topbarModel(ctPlatform().profile, ...)` because `menu.nim` reaches the
  ## facade through `from ... import` (a plain `import` would pull the whole
  ## async surface into a module that already exports `std/asyncjs` through
  ## `ui_imports`), and a `from` import cannot see a field of a type it did not
  ## also import. One accessor is cheaper than that argument at each call site.
  topbarModel(ctPlatform().profile, fullscreen)

proc installFrontendPlatform*(replacement: Platform) =
  ## Override the instantiation. Tests and StoryBook use this to drive the UI
  ## against a web or container profile without a web or container build —
  ## which is the practical payoff of capabilities being data rather than
  ## `defined()`.
  ##
  ## Now exactly `installPlatform`, and kept as a named proc anyway: it is the
  ## spelling a front-end caller should reach for, and it stops the two
  ## flag-setting responsibilities this used to have from drifting apart again.
  installPlatform(replacement)
