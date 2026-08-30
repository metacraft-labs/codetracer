## The Electron desktop's capability profile, as a pure function of the window
## system it is running on.
##
## ## Why this is not inside `desktop_electron.nim`
##
## Because that module is `{.error.}` on the native target — it binds
## `require('fs')` and `electron` — so nothing outside a `nim js` build can ask
## it what its profile looks like, and the profile is the part with an invariant
## worth checking. NS1 requires every capability a profile lacks to carry its
## degraded behaviour, checked in both directions; a review pass found that the
## check ran over the four *reference* profiles only, and that the shape this
## file now owns was already violating it: the Linux/Windows desktop lacks
## `capNativeMenuBar` and, until this extraction, explained nothing about it.
##
## Split out, the profile is pure data, `test_platform_facade.nim` asserts the
## invariant over both shapes on both backends, and `desktop_electron.nim`
## keeps exactly one thing: the bindings.

import ../platform/capabilities

const electronDesktopCapabilities*: CapabilitySet =
  desktopCapabilities - {
    # The renderer supervises no long-running children of its own — those live
    # in the Electron main process behind IPC — so the watchable half of process
    # execution is not claimed here. Claiming it and then refusing at run time
    # is exactly the "shows a button that cannot work" failure capabilities
    # exist to prevent.
    capProcessSignal, capProcessGracefulSignal,
    capProcessInteractiveStdin, capProcessTerminal,
    capSecretStore, capFilesystemWatch}
    ## `capProcessGracefulSignal` goes with `capProcessSignal` and not on its
    ## own: a renderer that cannot stop a child at all certainly cannot ask it
    ## politely, and a profile claiming the second without the first would
    ## describe a platform that does not exist.

proc electronDesktopProfile*(onMacOS: bool): PlatformProfile =
  ## The profile `newDesktopElectronPlatform` installs, given the window system
  ## it found at run time. `onMacOS` comes from `process.platform`, never from
  ## `defined(ctmacos)` — Noir-Studio.md §1a.2: the same bundle rendering into a
  ## browser tab has no traffic lights to avoid, and a build check cannot tell.
  var capabilities = electronDesktopCapabilities
  if onMacOS:
    # The only desktop with an OS menu bar we mirror into. See the note on
    # `desktopCapabilities` for why this is added here rather than there.
    capabilities.incl capNativeMenuBar

  var degradations = @[
    DegradationRule(capability: capProcessSignal, behaviour:
      "long-running children are supervised by the Electron main process; " &
      "cancel through the process pane rather than from the renderer"),
    DegradationRule(capability: capProcessGracefulSignal, behaviour:
      "the renderer signals no child at all, politely or otherwise; the " &
      "process pane in the main process is where a run is interrupted"),
    DegradationRule(capability: capProcessInteractiveStdin, behaviour:
      "input must be supplied before a command starts; interactive " &
      "sessions belong to the terminal pane"),
    DegradationRule(capability: capProcessTerminal, behaviour:
      "the renderer captures output through pipes; the pty is the terminal " &
      "pane's"),
    DegradationRule(capability: capSecretStore, behaviour:
      "no keychain binding exists in this tree yet, so nothing is stored " &
      "rather than something being stored badly"),
    DegradationRule(capability: capFilesystemWatch, behaviour:
      "the tree watcher runs in the Electron main process and reaches the " &
      "renderer as an IPC message, so the renderer registers no watch of " &
      "its own"),
    DegradationRule(capability: capShareLink, behaviour:
      "a desktop project is a directory; the equivalent is an archive export"),
  ]
  if not onMacOS:
    # Conditional because the capability is. A rule that stayed in the list on
    # macOS would be a *stale* rule — a sentence explaining the absence of
    # something the platform has — and `staleDegradations` is the other half of
    # the same check.
    degradations.add DegradationRule(capability: capNativeMenuBar, behaviour:
      "Windows and Linux windows have no application menu bar to mirror " &
      "into, so the menu is drawn in the page; only the macOS window has one")

  PlatformProfile(
    kind: pkDesktop,
    displayName: "desktop (Electron)",
    capabilities: capabilities,
    overlaysCaptionBar: onMacOS,
    degradations: degradations)
