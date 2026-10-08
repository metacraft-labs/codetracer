## test_platform_facade.nim
##
## NS1's platform facade — the parts that must hold on both backends.
##
## Three of the milestone's four verification tests live here; the fourth
## (`test_direct_host_access_fails_to_compile`) is a property of the *build*
## rather than of a value, so it lives in `ci/test/hostfree-build.sh`, which
## plants a `readFile` and a `startProcess` into a real front-end module and
## requires each to be rejected at compile time.
##
##   - test_topbar_actions_follow_capability_not_build
##   - test_a_remote_instantiation_needs_no_signature_change
##   - (plus the "capabilities the web cannot provide" enumeration, which NS1
##     asks for as a deliverable and which is checked here rather than written
##     as prose, so it cannot rot)
##
## This suite runs in `vm-unit` (C) and `vm-unit-js` (JS via node). Everything
## asserted is backend-independent by construction: the facade's whole point is
## that its shapes do not vary by platform, so a suite that could only run on
## one backend would be testing the wrong thing.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_platform_facade.nim

import std/[json, strutils, unittest]

import ../../platform/platform
import ../../platform/paths
import ../../viewmodels/topbar_actions
import ../../host/container_platform
import ../../host/electron_profile

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  ## Settle a facade future and hand back its outcome.
  ##
  ## Every assertion below goes through this rather than through a callback
  ## written at the call site, for a reason worth stating: `async_compat`
  ## queues even a synchronously resolved future's callback on the JS target
  ## while running it inline on native (that difference is what
  ## `vm-unit-js` caught in `DebuggerSession.launch`). A test that forgot the
  ## drain would pass on one backend and assert nothing on the other — a case
  ## that cannot fail, which is the defect class this suite must not join. So
  ## the drain is here, once, and `settled` is checked so a future that never
  ## completes fails loudly instead of leaving the assertions unexecuted.
  var captured: PlatformOutcome[T]
  var settled = false

  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true

  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true

  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled, "a facade future never settled"
  captured

# ---------------------------------------------------------------------------

suite "NS1 capabilities are data, and every absence is explained":

  test "every capability a profile lacks carries its degraded behaviour":
    ## NS1 deliverable: "Capabilities the web cannot provide enumerated, each
    ## with its degraded behaviour." Enumerated in prose it would be
    ## unverifiable; enumerated as data it is this assertion.
    for kind in allPlatformKinds:
      let profile = profileFor(kind)
      let undeclared = profile.undeclaredDegradations()
      check undeclared.len == 0
      if undeclared.len > 0:
        echo "  ", profile.displayName, " does not explain: ", $undeclared

  test "no profile carries a degradation for a capability it has":
    ## The other direction. A rule that survives the day its capability lands
    ## quietly misinforms, and a table guarded in one direction only is the
    ## shape of check that cannot fail.
    for kind in allPlatformKinds:
      let profile = profileFor(kind)
      let stale = profile.staleDegradations()
      check stale.len == 0
      if stale.len > 0:
        echo "  ", profile.displayName, " has stale rules for: ", $stale

  test "the profiles the INSTANTIATIONS build satisfy the table, in both directions":
    ## The two tests above run over `profileFor(kind)` — the four *reference*
    ## profiles. Those are not what the product installs. Review found the gap
    ## by checking the shipped shapes directly: the Linux/Windows Electron
    ## profile lacked `capNativeMenuBar` and explained nothing about it, so the
    ## deliverable "each absence with its degraded behaviour" was already untrue
    ## of a profile a user runs, while the suite reported green.
    ##
    ## `desktop_electron.nim` cannot be imported here — it is `{.error.}` on the
    ## native target — which is exactly why the profile now lives in the pure
    ## `host/electron_profile.nim` and can be asserted on both backends.
    for onMacOS in [false, true]:
      let profile = electronDesktopProfile(onMacOS)
      let undeclared = profile.undeclaredDegradations()
      let stale = profile.staleDegradations()
      check undeclared.len == 0
      check stale.len == 0
      if undeclared.len > 0:
        echo "  electron(onMacOS=", onMacOS, ") does not explain: ", $undeclared
      if stale.len > 0:
        echo "  electron(onMacOS=", onMacOS, ") has stale rules for: ", $stale

    # The macOS window is the one with a menu bar; nobody else has one. Named
    # rather than derived, because the conditional degradation above is only
    # correct if this is.
    check electronDesktopProfile(true).has(capNativeMenuBar)
    check not electronDesktopProfile(false).has(capNativeMenuBar)
    check electronDesktopProfile(true).overlaysCaptionBar
    check not electronDesktopProfile(false).overlaysCaptionBar

  test "the default platform promises nothing it will refuse":
    ## Before `installPlatform`, `newPlatform` builds every facade as a refusal.
    ## The profile must therefore declare no capability at all: a default that
    ## answered `can(capFilesystemRead)` with `true` and then refused the read
    ## is the disagreement between "may I" and "did it work" that the whole
    ## capability model exists to remove — and it was live, in the platform
    ## every caller gets before start-up finishes.
    resetPlatformForTesting()
    let default = platform()
    check default.profile.capabilities == {}
    for capability in default.profile.missing:
      check default.degradedBehaviour(capability).len > 20
    check default.profile.undeclaredDegradations().len == 0
    check default.profile.staleDegradations().len == 0

    # And the two answers agree, which is the point.
    check not default.can(capFilesystemRead)
    let outcome = awaitOutcome(default.fs.readText("/etc/hosts"))
    check not outcome.ok
    check outcome.error.kind == pkNotSupported
    resetPlatformForTesting()

  test "the web genuinely lacks the capabilities Noir-Studio.md says it lacks":
    ## Named one by one rather than by set difference: a set comparison passes
    ## when both sides are wrong in the same way.
    check not webProfile.has(capProcessArbitraryPrograms)
                                                   # §3.1 — wasm, not binaries
    check not webProfile.has(capProcessGracefulSignal)
                                                   # a worker cannot be asked
    check not webProfile.has(capSecretStore)       # §3.1, §8 — "no secrets"
    check not webProfile.has(capVcsRemote)         # §6.2a — CORS
    check not webProfile.has(capWindowControls)    # §1a.2 — the tab owns the frame
    check not webProfile.has(capNativeMenuBar)
    check not webProfile.has(capFilesystemWatch)
    check not webProfile.has(capClipboardRead)
    check not webProfile.has(capFilesystemArbitraryPaths)

    check webProfile.has(capFilesystemRead)        # §4 — the project store
    check webProfile.has(capFilesystemWrite)
    check webProfile.has(capProcessSpawn)          # NS3 §3.1 — declared modules
    check webProfile.has(capProcessSignal)         # worker.terminate()
    check webProfile.has(capVcsRead)               # §6.2a — local history
    check webProfile.has(capVcsWrite)
    check webProfile.has(capShareLink)             # §6.1 — the artifact is the link

  test "each web absence explains itself in a sentence a user could read":
    for capability in webProfile.missing:
      let behaviour = webProfile.degradedBehaviour(capability)
      check behaviour.len > 20
      check "no degradation declared" notin behaviour

  test "the container profile is the desktop's capabilities over a wire":
    ## §3.1a: "it is a third facade instantiation, not a third architecture."
    ## The container has the desktop's host capabilities and the web's shell
    ## constraints, because the backend is a container and the shell is a tab.
    check containerProfile.has(capProcessSpawn)
    check containerProfile.has(capVcsRemote)
    check containerProfile.has(capFilesystemWatch)
    check not containerProfile.has(capWindowControls)
    check not containerProfile.has(capNativeMenuBar)

# ---------------------------------------------------------------------------

suite "test_topbar_actions_follow_capability_not_build":

  test "window controls are absent on the web because the capability is":
    let web = topbarModel(webProfile)
    check not web.has(tbaWindowControls)
    check web.has(tbaInPageMenu)
    check web.has(tbaShare)
    check webProfile.absentBecause(tbaWindowControls).len > 0

  test "window controls are present on a desktop that owns its frame":
    ## Windows and Linux: the platform hands us the frame and paints nothing
    ## over it, so we draw the buttons.
    let framed = desktopProfile.withCaptionBarOverlay(false)
    let bar = topbarModel(framed)
    check bar.has(tbaWindowControls)
    check not bar.reserveWindowControlSpace

  test "a caption-bar overlay suppresses our buttons and reserves the space":
    ## macOS. This replaces `reserveWindowControls = defined(ctmacos)` in
    ## ui/menu.nim, and the assertion is that the SAME profile with the overlay
    ## flag flipped produces a different bar — which a `defined()` could not do
    ## in one process.
    let overlaid = desktopProfile.withCaptionBarOverlay(true)
    let bar = topbarModel(overlaid)
    check not bar.has(tbaWindowControls)
    check bar.reserveWindowControlSpace
    check overlaid.absentBecause(tbaWindowControls) ==
      "the window system paints its own controls over the caption bar"

  test "fullscreen releases the reserved space without changing the capability":
    let overlaid = desktopProfile.withCaptionBarOverlay(true)
    let bar = topbarModel(overlaid, fullscreen = true)
    check not bar.reserveWindowControlSpace
    check bar.captionBarFullscreen

  test "adding a platform adds an instantiation, not a branch":
    ## The load-bearing claim. A profile invented here — one this codebase has
    ## never heard of — produces a coherent topbar with no edit to
    ## topbar_actions.nim. If the decision were a `when defined(...)`, this
    ## test could not be written at all.
    let kiosk = PlatformProfile(
      kind: pkContainer,
      displayName: "kiosk",
      capabilities: {capFilesystemRead, capVcsRead, capOpenFileDialog},
      overlaysCaptionBar: false,
      degradations: @[])
    let bar = topbarModel(kiosk)
    check bar.has(tbaDebuggerControls)
    check bar.has(tbaInPageMenu)
    check bar.has(tbaOpenProjectDialog)
    check not bar.has(tbaWindowControls)
    check not bar.has(tbaShare)
    check not bar.has(tbaRevealProject)

  test "the debugger controls are on every bar, because they are the product":
    for kind in allPlatformKinds:
      let bar = topbarModel(profileFor(kind))
      check bar.has(tbaDebuggerControls)
      check bar.has(tbaOmnibar)
      check bar.has(tbaSessionTabs)

  test "the migration reproduces ui/menu.nim's three old build checks exactly":
    ## NS1: "the refactoring is provably a refactoring". These are the three
    ## expressions `ui/menu.nim` carried before the facade, evaluated against
    ## the profiles the instantiations now build, and required to agree.
    ##
    ##   reserveWindowControls = defined(ctmacos)
    ##   showNavigation        = ... and not defined(ctmacos)
    ##   showWindowMenu        = inElectron and not defined(ctmacos)
    ##
    ## Written as a table because the interesting property is that all three
    ## agree on all three platform shapes at once — checking them one at a time
    ## is how one of them ends up inverted without the suite noticing. Getting
    ## `showNavigation` wrong is not hypothetical: an earlier draft of
    ## `desktopCapabilities` claimed `capNativeMenuBar` for every desktop,
    ## which would have removed the in-page menu from every Linux and Windows
    ## window.
    type Shape = tuple[name: string; inElectron, isMacOS: bool]
    const shapes: seq[Shape] = @[
      (name: "macOS Electron", inElectron: true, isMacOS: true),
      (name: "Linux/Windows Electron", inElectron: true, isMacOS: false),
      (name: "browser dev server", inElectron: false, isMacOS: false),
    ]

    for shape in shapes:
      # Build the profile the instantiation would build for this shape.
      let profile =
        if not shape.inElectron:
          webProfile
        elif shape.isMacOS:
          desktopProfile
            .withCapabilities(
              desktopCapabilities + {capNativeMenuBar},
              desktopProfile.degradations)
            .withCaptionBarOverlay(true)
        else:
          desktopProfile.withCaptionBarOverlay(false)

      let bar = topbarModel(profile)

      # The old expressions, spelled out.
      let oldReserveWindowControls = shape.isMacOS
      let oldShowNavigation = not shape.isMacOS
      let oldShowWindowMenu = shape.inElectron and not shape.isMacOS

      check bar.reserveWindowControlSpace == oldReserveWindowControls
      check bar.has(tbaInPageMenu) == oldShowNavigation
      check bar.has(tbaWindowControls) == oldShowWindowMenu

# ---------------------------------------------------------------------------

suite "the facade refuses rather than crashing when a capability is absent":

  test "an uninstantiated platform answers every call with pkNotSupported":
    resetPlatformForTesting()
    let outcome = awaitOutcome(platform().fs.readText("/etc/hosts"))
    check not outcome.ok
    check outcome.error.kind == pkNotSupported

  test "a partially implemented instantiation refuses the rest by name":
    ## `newPlatform` builds every facade as a refusal, so an instantiation that
    ## has not implemented an operation yet produces a named `pkNotSupported`
    ## rather than a nil-call crash — and adding a field to a facade cannot
    ## silently break an instantiation that has not been updated.
    let partial = newPlatform(webProfile)
    let outcome = awaitOutcome(partial.process.run(processSpec("nargo", @["test"])))
    check not outcome.ok
    check outcome.error.kind == pkNotSupported
    check "running programs" in outcome.error.message

# ---------------------------------------------------------------------------

suite "test_a_remote_instantiation_needs_no_signature_change":

  setup:
    var seenVerbs: seq[string] = @[]
    var lastArgs: JsonNode = newJObject()

    let transport: RemoteTransport = proc(request: RemoteRequest
                                         ): PlatformFuture[RemoteResponse] =
      seenVerbs.add request.verb
      lastArgs = request.args
      # Answers written as the §6.2 payloads the server sends, so the
      # assertions below are about the codec both ends share rather than about
      # a shape invented in this file. `test_container_platform_verbs.nim`
      # drives every verb through a real `encodeCall`/`decodeCall` pair; this
      # fake stays small because its subject is the SIGNATURES.
      let answer =
        case request.verb
        of "fs.readText": remoteOk(%"fn main() {}")
        of "fs.stat": remoteOk(%*{"kind": "fekFile", "size": 42,
                                  "modifiedMs": 1700000000000,
                                  "readOnly": false})
        of "fs.listDir": remoteOk(%*[{"name": "main.nr", "kind": "fekFile"},
                                     {"name": "src", "kind": "fekDirectory"}])
        of "process.run": remoteOk(%*{"exit": {"exitCode": 0,
                                               "signalled": false,
                                               "signalName": ""},
                                      "stdout": "compiled", "stderr": ""})
        of "process.which": remoteErr(pkNotFound, "no nargo in the container")
        of "vcs.status": remoteOk(%*{
          "branch": "main", "upstream": "origin/main", "ahead": 0,
          "behind": 0, "detached": false,
          "changes": [{"path": "src/main.nr", "previousPath": "",
                       "indexStatus": "vfsModified",
                       "workingTreeStatus": "vfsUnmodified"}]})
        of "clipboard.readText": remoteOk(%"pasted")
        else: remoteOk(newJNull())
      # `newCompletedFuture`, not a bare promise. A real endpoint's answer
      # arrives on a later tick and this one does not, and nim-everywhere marks
      # the difference so a synchronous caller can still observe it. A plain
      # `newPromise` here would push the value onto V8's microtask queue, which
      # no headless test can drain — and every assertion below would quietly
      # not run on the JS backend while still reporting green.
      newCompletedFuture(answer)

    # The profile is named HERE rather than defaulted in the constructor, which
    # is §6.3 showing through into the suite: shipping code takes it from the
    # `welcome` frame, and a test that wants `containerProfile` has to say so.
    let remote = newContainerPlatform(transport, containerProfile)

  test "the container platform satisfies every facade with no signature altered":
    ## The compile is the assertion. `newContainerPlatform` assigns every field
    ## of all seven facades; if any operation had a signature that only made
    ## sense in-process — returning a `File`, a `Process`, a pointer or an
    ## iterator — this suite would not build.
    ##
    ## What makes that true is `{.requiresInit.}` on the seven facade types, not
    ## the four `isNil` checks below. Review established the difference by
    ## adding `openHandle*: proc(path: string): File` to `FileSystemFacade`:
    ## without the pragma it compiled cleanly on both backends, every
    ## instantiation quietly grew a nil field, and this suite still reported
    ## green. With it, the same edit fails the build at every construction site.
    ## The `isNil` checks stay because they are what fails if a *constructor* is
    ## ever replaced by something that hands back a nil facade.
    check not remote.fs.isNil
    check not remote.process.isNil
    check not remote.vcs.isNil
    check not remote.settings.isNil
    check not remote.clipboard.isNil
    check not remote.download.isNil
    check not remote.shell.isNil

  test "a read crosses the wire and comes back as the same outcome shape":
    let outcome = awaitOutcome(remote.fs.readText("src/main.nr"))
    check outcome.ok
    check outcome.value == "fn main() {}"
    check seenVerbs == @["fs.readText"]
    # The ARGUMENT IS NAMED, not positional. §6.2: the server reads
    # `args["path"]`, so two transposed strings are caught by the name they
    # arrived under rather than by an arity that would still match.
    check lastArgs["path"].getStr == "src/main.nr"

  test "a structured result survives the round trip":
    let outcome = awaitOutcome(remote.fs.listDir("src"))
    check outcome.ok
    let entries = outcome.value
    check entries.len == 2
    check entries[0].name == "main.nr"
    check entries[0].kind == fekFile
    check entries[1].name == "src"
    check entries[1].kind == fekDirectory

  test "a remote failure arrives as a value, not as an exception":
    let outcome = awaitOutcome(remote.process.which("nargo"))
    check not outcome.ok
    check outcome.error.kind == pkNotFound
    check outcome.error.message == "no nargo in the container"

  test "a process runs over the wire with an opaque, serialisable handle":
    let outcome = awaitOutcome(
      remote.process.run(processSpec("nargo", @["test"], workingDir = "/w")))
    check outcome.ok
    let run = outcome.value
    check run.exit.exitCode == 0
    check run.stdout == "compiled"
    check lastArgs["spec"]["command"].getStr == "nargo"
    check lastArgs["spec"]["workingDir"].getStr == "/w"

  test "version control is expressed in what the panel needs, not in git argv":
    let outcome = awaitOutcome(remote.vcs.status("/w"))
    check outcome.ok
    let status = outcome.value
    check status.branch == "main"
    check status.upstream == "origin/main"
    check status.changes.len == 1
    check status.changes[0].path == "src/main.nr"
    check status.changes[0].indexStatus == vfsModified

  test "the clipboard is reachable from a remote instantiation":
    ## Included because it is the operation most obviously "local": if the
    ## facade had made it synchronous, the container column would have needed
    ## its own client.
    let outcome = awaitOutcome(remote.clipboard.readText())
    check outcome.ok
    check outcome.value == "pasted"

# ---------------------------------------------------------------------------

suite "path arithmetic is host-free and behaves":

  test "splitting and joining round-trip":
    check parentDir("a/b/c") == "a/b"
    check parentDir("a/b/") == "a"
    check parentDir("/a") == "/"
    check extractFilename("a/b/c.nr") == "c.nr"
    check lastPathPart("a/b/") == "b"
    check splitFile("src/main.nr") == ("src", "main", ".nr")
    check splitFile("src/.bashrc") == ("src", ".bashrc", "")
    check changeFileExt("src/main.nr", "json") == "src/main.json"
    check addFileExt("src/main", ".nr") == "src/main.nr"
    check addFileExt("src/main.nr", ".json") == "src/main.nr"

  test "joining refuses to be surprised by separators":
    check "a" / "b" == "a/b"
    check "a/" / "b" == "a/b"
    check "a" / "/b" == "/b"
    check "" / "b" == "b"
    check "a" / "" == "a"
    check joinPath("a", "b", "c") == "a/b/c"

  test "normalisation resolves . and .. textually":
    check normalizePath("a/./b/../c") == "a/c"
    check normalizePath("/a/../..") == "/"
    check normalizePath("a/../../b") == "../b"
    check normalizePath("") == "."
    check normalizePath("a//b///c") == "a/b/c"

  test "relative paths are computed, and give up honestly across roots":
    check relativePath("/a/b/c", "/a/b") == "c"
    check relativePath("/a/b/c", "/a/d") == "../b/c"
    check relativePath("/a/b", "/a/b") == "."
    check relativePath("/a/b", "relative") == "/a/b"

  test "containment is decided on segments, not on string prefix":
    ## The prefix test answers yes for ("/a/b", "/a/bc"), which is how a
    ## directory sandbox leaks. This is the assertion that it does not.
    check isParentOf("/a/b", "/a/b/c")
    check not isParentOf("/a/b", "/a/bc")
    check not isParentOf("/a/b", "/a/b")
    check not isParentOf("/a/b/c", "/a/b")

  test "absoluteness understands both shapes a desktop can produce":
    check isAbsolute("/a")
    check isAbsolute("C:/a")
    check isAbsolute("C:\\a")
    check not isAbsolute("a/b")
    check not isAbsolute("")
    check splitDrive("C:/a/b") == ("C:", "/a/b")

# ---------------------------------------------------------------------------
# SEVERAL SESSIONS IN ONE PROCESS.
#
# One WebUI drives several container-backed sessions, each a different process
# on the other end of a different connection with its own filesystem, its own
# VCS and its own capability profile. "The platform" is therefore no longer a
# property of the process, and the single `installedPlatform` that used to hold
# it could only ever name one of them.
#
# The global is narrowed rather than removed — `platform()` is the ACTIVE
# session's — so what these cases are really pinning is that the narrowing did
# not change the single-session behaviour underneath it. That is where a
# regression would land: every pre-session call site still says `platform()`.
# ---------------------------------------------------------------------------

proc markedPlatform(name: string): Platform =
  ## Platforms distinguishable BY VALUE, so a lookup that returned the wrong
  ## session's is visible. Identity comparison would pass for two platforms a
  ## registry had aliased to one object, which is the mistake worth catching.
  newPlatform(PlatformProfile(kind: pkContainer, displayName: name,
                              capabilities: {capFilesystemRead},
                              degradations: @[]))

suite "several sessions, one process":
  setup:
    resetPlatformForTesting()

  teardown:
    resetPlatformForTesting()

  test "the single-session spelling is unchanged":
    # The whole compatibility claim, in one case: no session named anywhere,
    # and `platform()` is what was installed.
    installPlatform(markedPlatform("only"))
    check platform().profile.displayName == "only"
    check activePlatformSession() == DefaultPlatformSession
    check platformWasExplicitlyChosen()

  test "two sessions keep their own platforms":
    installPlatform("s-1", markedPlatform("one"))
    installPlatform("s-2", markedPlatform("two"))
    check platformFor("s-1").profile.displayName == "one"
    check platformFor("s-2").profile.displayName == "two"
    check platformSessions() == @["s-1", "s-2"]

  test "the first session installed becomes the active one":
    installPlatform("s-1", markedPlatform("one"))
    check activePlatformSession() == "s-1"
    check platform().profile.displayName == "one"

  test "a later session does NOT steal the active one":
    # A second session booting in the background while the user is looking at
    # the first must not redirect every `platform()` read in the tree. If this
    # ever fails, a handshake completing is silently switching the UI.
    installPlatform("s-1", markedPlatform("one"))
    installPlatform("s-2", markedPlatform("two"))
    check activePlatformSession() == "s-1"
    check platform().profile.displayName == "one"

  test "switching is explicit, and reported":
    installPlatform("s-1", markedPlatform("one"))
    installPlatform("s-2", markedPlatform("two"))
    check setActivePlatformSession("s-2")
    check platform().profile.displayName == "two"

  test "switching to a session that has not booted is REFUSED, not silent":
    # The refusal matters more than the switch. Pointing `platform()` at a
    # session with nothing installed would render every panel as "unsupported"
    # and leave the difference between "not booted" and "cannot do that"
    # invisible to whoever is looking at it.
    installPlatform("s-1", markedPlatform("one"))
    check not setActivePlatformSession("s-absent")
    check activePlatformSession() == "s-1"
    check platform().profile.displayName == "one"

  test "an unknown session refuses rather than crashing, and is not created":
    # Two assertions in one case because they are the same promise: the answer
    # is a refusing platform (the header's rule about `nil`), AND asking did
    # not bring the session into existence. A lookup that registered would make
    # `platformSessions()` grow every time a caller checked.
    installPlatform("s-1", markedPlatform("one"))
    let absent = platformFor("s-absent")
    check not absent.isNil
    check not absent.can(capFilesystemRead)
    check platformSessions() == @["s-1"]
    check not hasPlatformSession("s-absent")

  test "a released session's platform is gone":
    # A facade call made after the container is gone must refuse. Left
    # installed, it would reach a transport whose socket is closed and hang
    # pending for ever, which is the worse failure: no answer at all.
    installPlatform("s-1", markedPlatform("one"))
    installPlatform("s-2", markedPlatform("two"))
    releasePlatformSession("s-1")
    check platformSessions() == @["s-2"]
    check not platformFor("s-1").can(capFilesystemRead)

  test "releasing the ACTIVE session leaves the page between sessions":
    # Not a crash and not an automatic successor: this code cannot know which
    # of the remaining sessions the user was about to look at.
    installPlatform("s-1", markedPlatform("one"))
    installPlatform("s-2", markedPlatform("two"))
    releasePlatformSession("s-1")
    check activePlatformSession() == "s-1"
    check not platform().can(capFilesystemRead)
    check setActivePlatformSession("s-2")
    check platform().profile.displayName == "two"

  test "the empty session id is an ordinary session, not a sentinel":
    # This is what makes the compatibility claim structural rather than a
    # special case bolted on: `installPlatform(p)` and
    # `installPlatform("", p)` must be the same thing.
    installPlatform(DefaultPlatformSession, markedPlatform("default"))
    check platform().profile.displayName == "default"
    check hasPlatformSession(DefaultPlatformSession)
    check platformFor(DefaultPlatformSession).profile.displayName == "default"
