## The front end's single entry point to the platform facade.
##
## ## Why front-end code imports this rather than `viewmodel/platform/platform`
##
## Two reasons, and the second is the one that matters.
##
## 1. **It picks the instantiation.** A `nim js` renderer gets the Electron one,
##    a `nim js -d:ctWeb` build gets whatever `boot()` installed, and a native
##    build gets the native one. No caller has to know which. The `when` lives
##    here, once, instead of at every call site — which is the same argument the
##    facade itself makes one level down.
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

# THE THREE-WAY SWITCH — Noir-Studio.md §3.1, and the whole of what stood
# between the front end and a browser tab.
#
# This used to be two arms, `js` and everything else, with `js` meaning
# Electron. That made `platform_host` un-importable from a web build: the
# import is unconditional within its arm, so ANY `nim js` compile of anything
# that reaches this module linked `require('fs')` and
# `require('child_process')`. Measured, on `web_main.nim`: importing and using
# this module put 43 `require(` calls and 4 `child_process` mentions into the
# bundle. That is why `web_main.nim` had to route around the front end's own
# platform accessor, which is not a thing a second platform should have to do.
#
# `ctWeb` is a build of the SAME sources for a different host, exactly as
# `ctmacos` and `ctInExtension` are. It is not a fourth product and it does not
# select a different front end; it selects which host module gets linked, which
# is the one thing a browser genuinely constrains.
when defined(js) and defined(ctWeb):
  # Deliberately no host import at all.
  #
  # The web instantiation is `platform/web_platform.nim`, and it is constructed
  # by `host/web_browser.nim`'s `boot()` — asynchronously, over a store that
  # must be OPENED first and that may refuse (§4.5). There is nothing to import
  # here that could be installed synchronously, and inventing one would mean a
  # platform that exists before its store, which §4.5 exists to forbid.
  #
  # So on this arm `ctPlatform()` installs nothing and hands back whatever
  # `boot()` installed. Before `boot()` completes that is the
  # `uninstalledProfile` platform, which is the correct answer and already
  # carries the right sentence — "whichever build this is must call
  # installPlatform at start-up" — with every capability absent and every
  # operation refusing. A caller that runs before boot gets a refusal it can
  # show, not a desktop platform that lies.
  #
  # `#` and not `##`, and that is not a style preference: a `##` block after a
  # `discard` is `Error: invalid indentation`, which is the exact defect that
  # reached `dev` at ed9d6021 in `web_browser.nim` and sat there for days. It
  # was caught here in seconds because this arm is compiled by a gate now.
  discard
elif defined(js):
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
    when defined(js) and defined(ctWeb):
      # Nothing to bootstrap; see the import switch above. The web platform
      # cannot be built synchronously, so the honest answer before `boot()` is
      # the refusing default rather than a stand-in.
      discard
    elif defined(js):
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
