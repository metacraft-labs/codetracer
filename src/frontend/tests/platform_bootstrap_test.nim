## `ctPlatform()`'s bootstrap must not overwrite an instantiation someone chose
## — Noir-Studio.milestones.org NS2, and the reason a web entry point can exist
## at all.
##
## ## What this is about
##
## `platform_host.ctPlatform()` lazily installs the desktop instantiation the
## first time anything asks. That is right for the desktop builds, where
## nothing else installs one, and it was the only case when it was written.
##
## The web instantiation breaks the assumption. `web_platform.install()` calls
## `platform.installPlatform` directly — it must, because `platform/` is the
## host-free surface and importing `platform_host` would drag
## `desktop_electron` and its `require('child_process')` into it. So it does
## not touch `platform_host`'s own `bootstrapped` flag, and before this suite
## the next `ctPlatform()` call from anywhere in the front end would replace
## the freshly booted web platform with the Electron one.
##
## **Nothing about that is visible to the compiler or to any other suite.**
## `boot()` returns `ok`, every type lines up, and the tab ends up holding a
## platform that claims `capProcessSpawn`, `capFilesystemArbitraryPaths` and a
## keychain, backed by node bindings that are not there. It is the same class
## of defect NS1's capability model was built to remove, reintroduced one layer
## below it — which is why the assertion is about *behaviour after a sequence*
## rather than about a signature.
##
## ## Why the assertions are shaped this way
##
## The obvious test — "install a platform, then check `ctPlatform()` returns
## it" — passes against the broken version too, because the clobber only
## happens on the FIRST `ctPlatform()` call in the process. `bootstrapped` is
## module-level and set once. So the order below is load-bearing: choose a
## platform, and only then make the very first `ctPlatform()` call. A suite
## that touched `ctPlatform()` earlier for any reason would disarm itself.
##
## For the same reason this file holds ONE case that matters and does its own
## bookkeeping, rather than a tidy set of cases sharing a fixture.

import std/[unittest, strutils]

import ../platform_host
import ../viewmodel/platform/capabilities as caps
import ../viewmodel/platform/platform as platform_facade

suite "ctPlatform's bootstrap respects an instantiation that was chosen":

  test "a platform installed before the first ctPlatform() call survives it":
    ## The regression. Against the version of `platform_host.nim` that
    ## bootstrapped unconditionally, `kind` below is `pkDesktop` and the
    ## capability checks report the desktop's answers — a browser tab holding
    ## the Electron platform.
    resetPlatformForTesting()

    # A stand-in for what `web_platform.install()` does: choose an
    # instantiation through the facade, without going through `platform_host`.
    # The profile is the real `webProfile` narrowed the way the web
    # instantiation narrows it, so this is the shape that actually occurs
    # rather than an invented one.
    let chosen = newPlatform(webProfile)
    platform_facade.installPlatform(chosen)

    # THE FIRST CALL. Everything above must happen before this line.
    let running = ctPlatform()

    check running.profile.kind == pkWeb
    check running.profile.displayName == webProfile.displayName

    # Named one by one rather than by identity, because `running == chosen`
    # would also hold if both were nil, and because these are the answers a
    # caller actually branches on. Each of the four is a different answer on
    # the desktop instantiation, so the clobber cannot hide behind any one.
    check not running.can(capFilesystemArbitraryPaths)
    check not running.can(capSecretStore)
    check not running.can(capWindowControls)
    check running.can(capShareLink)

    resetPlatformForTesting()

  test "with nothing chosen, the bootstrap still installs a real platform":
    ## The counter-check, and it is not decorative: the fix is a guard, and a
    ## guard that is always taken would leave every desktop build with the
    ## `uninstalledProfile` — every capability absent and every operation
    ## refusing. That would be a far worse failure than the one being fixed,
    ## and this is the only assertion that would notice.
    resetPlatformForTesting()

    let running = ctPlatform()
    check running.profile.kind != pkWeb
    check running.profile.capabilities != {}
    check running.profile.displayName != platform_facade.uninstalledProfile.displayName
    check running.can(capFilesystemRead)

    resetPlatformForTesting()

  test "ctOrRaise preserves the ERROR CONTRACT, not just the type":
    ## NS1's call-site migration, and the trap it nearly sprang.
    ##
    ## `renderer.nim`'s `readFileUtf8` was a rejecting
    ## `require('fs').promises.readFile`. All five of its callers wrap it in
    ## `except:` and log a warning naming the file. Migrating it onto the
    ## facade means turning a `PlatformOutcome` back into that contract, and
    ## the obvious conversion — `valueOr("")` — compiles, type-checks and
    ## satisfies four of the five. The fifth guards only on `isNil`, so an
    ## unreadable file would be cached as the file's contents and the editor
    ## would show it blank, with the warning no longer printed because nothing
    ## raised.
    ##
    ## So both directions are asserted here, and the failing direction is
    ## asserted to RAISE rather than to return anything at all — a check
    ## written as `check ctOrRaise(bad) != ""` would pass against the defect.
    let good = succeeded("file contents")
    check ctOrRaise(good) == "file contents"

    let bad = failed[string](pkNotFound, "no such file", "ENOENT")
    var raised = false
    var caughtKind = pkNone
    try:
      discard ctOrRaise(bad)
    except PlatformCallError as e:
      raised = true
      caughtKind = e.kind
    check raised
    check caughtKind == pkNotFound

    # The message survives, because the callers' `except` blocks print it and a
    # warning that names neither the file nor the reason is not worth printing.
    var message = ""
    try:
      discard ctOrRaise(bad)
    except PlatformCallError as e:
      message = e.msg
    check "no such file" in message

    # And a successful outcome must not raise even when its value is the empty
    # string — an empty file is a legitimate read, and conflating it with a
    # failure is the same defect in the other direction.
    var emptyRaised = false
    var emptyValue = "unset"
    try:
      emptyValue = ctOrRaise(succeeded(""))
    except PlatformCallError:
      emptyRaised = true
    check not emptyRaised
    check emptyValue == ""

  test "materialising the lazy default does not count as choosing one":
    ## `platformInstalled()` is true after any bare `platform()` read, because
    ## that call fills the field in with the uninstalled default. Had the guard
    ## been written against it instead of against
    ## `platformWasExplicitlyChosen()`, a single read anywhere before start-up
    ## would have left the desktop with no instantiation — so the distinction
    ## is pinned rather than left to the comment that explains it.
    resetPlatformForTesting()
    check not platform_facade.platformInstalled()
    check not platform_facade.platformWasExplicitlyChosen()

    discard platform_facade.platform()
    check platform_facade.platformInstalled()
    check not platform_facade.platformWasExplicitlyChosen()

    platform_facade.installPlatform(newPlatform(webProfile))
    check platform_facade.platformWasExplicitlyChosen()

    resetPlatformForTesting()
    check not platform_facade.platformWasExplicitlyChosen()
