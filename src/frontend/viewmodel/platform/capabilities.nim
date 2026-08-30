## What a platform can do — as data, so nothing has to ask which build it is.
##
## ## The rule this module enforces
##
## Noir-Studio.md §1a.2: "The topbar is already parametric, and nobody had to
## make it so. Window controls appear on desktop and not on the web, because the
## platform either owns the window frame or does not."
##
## That is the pattern, and until NS1 the code did not follow it: `ui/menu.nim`
## decided with `defined(ctmacos)` and `electron_lib.inElectron`. Two of those
## three were build checks. A build check cannot express "this desktop build is
## running in a browser tab", it cannot be varied by a test, and adding a
## platform means adding a branch at every site that asks — which is the drift
## §3 exists to prevent. `viewmodels/topbar_actions.nim` now answers all three
## from the profile below, and `test_platform_facade.nim` pins the answers
## against the old expressions so the change is provably a refactoring.
##
## So: an action is absent because its **capability** is absent. Adding a
## platform adds an instantiation, not a branch. That is
## `test_topbar_actions_follow_capability_not_build`.
##
## ## The degraded-behaviour table is a deliverable, not documentation
##
## NS1 asks for "capabilities the web cannot provide enumerated, each with its
## degraded behaviour". Written as prose in a design document, that list is
## unverifiable and rots. Written here it is a value: `degradedBehaviour` must
## answer for every capability a platform lacks, and a test asserts exactly
## that. A capability added without a degradation story fails the suite.

type
  PlatformKind* = enum
    ## The instantiations NS1 is shaped for. Three, not two — Noir-Studio.md
    ## §3.1a. `pkContainer` is post-MVP and deliberately present anyway: a
    ## capability whose signature only makes sense in-process is a design error
    ## to catch now, not after `ct host` is refactored.
    pkDesktop
    pkWeb
    pkContainer
    pkHeadless
      ## Tests, `ct host`'s own harness and the ViewModel suites. Not a
      ## product surface, but a real instantiation: it is the one that proves
      ## the front end can run with no host at all.

  PlatformCapability* = enum
    ## One entry per thing a caller might reasonably want and might not get.
    ## Deliberately finer-grained than the seven facade modules: a web build
    ## has filesystem *read* and *write* over the project store but no *watch*,
    ## and collapsing those into "filesystem" would either over- or
    ## under-promise.

    # -- filesystem ---------------------------------------------------------
    capFilesystemRead
    capFilesystemWrite
    capFilesystemWatch
    capFilesystemTemp
      ## A scratch directory the platform will reclaim.
    capFilesystemArbitraryPaths
      ## Any absolute path the user names, as opposed to a sandboxed store.

    # -- process ------------------------------------------------------------
    capProcessSpawn
    capProcessSignal
      ## Terminate / interrupt a running child.
    capProcessInteractiveStdin
    capProcessTerminal
      ## A pty, as opposed to pipes.

    # -- vcs ----------------------------------------------------------------
    capVcsRead
    capVcsWrite
    capVcsRemote
      ## Fetch and push, which needs a network peer that speaks git.

    # -- settings and secrets -----------------------------------------------
    capSettingsRead
    capSettingsWrite
    capSecretStore
      ## A real keychain. Noir-Studio.md §3.1: the web column is "**no
      ## secrets**", and that is a capability absence rather than a weaker
      ## implementation.

    # -- clipboard ----------------------------------------------------------
    capClipboardWrite
    capClipboardRead
      ## Separate from write because browsers gate reading behind a permission
      ## prompt and grant writing on a user gesture. A single `capClipboard`
      ## would make the paste path look available when it is not.

    # -- download and dialogs -----------------------------------------------
    capDownloadFile
    capOpenFileDialog
    capSaveFileDialog
    capDirectoryPicker

    # -- shell and windowing ------------------------------------------------
    capOpenExternalUrl
    capRevealInFileManager
    capWindowControls
      ## The platform owns the window frame, so the app draws minimise /
      ## maximise / close.
    capWindowFullscreen
    capNativeMenuBar
    capMultiWindow
    capShareLink
      ## Publish the current project as a URL. The mirror image of
      ## `capWindowControls`: it appears where the platform supplies sharing —
      ## Noir-Studio.md §1a.2.

  CapabilitySet* = set[PlatformCapability]

  DegradationRule* = object
    ## What the user gets instead, when `capability` is absent. Every absence a
    ## `PlatformProfile` declares must have one of these.
    capability*: PlatformCapability
    behaviour*: string
      ## Written for the person who will read it in a UI or a bug report:
      ## says what happens, not that something is missing.

  PlatformProfile* = object
    kind*: PlatformKind
    displayName*: string
    capabilities*: CapabilitySet
    degradations*: seq[DegradationRule]
    overlaysCaptionBar*: bool
      ## The window system paints its own controls over the application's
      ## caption bar, so the bar must start clear of them.
      ##
      ## This is macOS's traffic lights, and it is why `ui/menu.nim` carried
      ## `reserveWindowControls = defined(ctmacos)`. It is a fact about the
      ## *window system* rather than about the build: a macOS-built binary
      ## rendering into a browser tab has no overlay, and a compositor that
      ## grew one would want the same reservation without anyone editing a
      ## `when`. So it lives on the profile, and
      ## `viewmodels/topbar_actions.nim` reads it there.
      ##
      ## Not a `PlatformCapability`, because it is not something a caller can
      ## *do* — a capability set answers "may I", and this answers "where".

const
  allCapabilities*: CapabilitySet = {low(PlatformCapability) .. high(PlatformCapability)}

proc has*(profile: PlatformProfile; capability: PlatformCapability): bool =
  capability in profile.capabilities

proc hasAll*(profile: PlatformProfile; required: CapabilitySet): bool =
  required <= profile.capabilities

proc missing*(profile: PlatformProfile): CapabilitySet =
  allCapabilities - profile.capabilities

proc degradedBehaviour*(profile: PlatformProfile;
                        capability: PlatformCapability): string =
  ## What happens instead. Empty string means the capability is present.
  if capability in profile.capabilities:
    return ""
  for rule in profile.degradations:
    if rule.capability == capability:
      return rule.behaviour
  # Reaching here is a bug in the profile, not in the caller: NS1 requires each
  # unavailable capability to carry its degraded behaviour, and
  # `test_every_absence_has_a_degradation` fails the build when one does not.
  "unavailable on " & profile.displayName & " (no degradation declared)"

proc undeclaredDegradations*(profile: PlatformProfile): seq[PlatformCapability] =
  ## Every capability the profile lacks and does not explain. The assertion
  ## `test_every_absence_has_a_degradation` is `.len == 0` over this.
  result = @[]
  for capability in profile.missing:
    var found = false
    for rule in profile.degradations:
      if rule.capability == capability:
        found = true
        break
    if not found:
      result.add capability

proc staleDegradations*(profile: PlatformProfile): seq[PlatformCapability] =
  ## Degradation rules for capabilities the profile actually HAS. A stale rule
  ## is how a table stops describing the product: it survives the day the
  ## capability lands and then quietly misinforms. Checked in the same test as
  ## the missing direction, because a table guarded in one direction only is
  ## the shape of check that cannot fail.
  result = @[]
  for rule in profile.degradations:
    if rule.capability in profile.capabilities:
      result.add rule.capability

# ---------------------------------------------------------------------------
# The profiles
# ---------------------------------------------------------------------------

const desktopCapabilities*: CapabilitySet = {
  capFilesystemRead, capFilesystemWrite, capFilesystemWatch,
  capFilesystemTemp, capFilesystemArbitraryPaths,
  capProcessSpawn, capProcessSignal, capProcessInteractiveStdin,
  capProcessTerminal,
  capVcsRead, capVcsWrite, capVcsRemote,
  capSettingsRead, capSettingsWrite, capSecretStore,
  capClipboardWrite, capClipboardRead,
  capDownloadFile, capOpenFileDialog, capSaveFileDialog, capDirectoryPicker,
  capOpenExternalUrl, capRevealInFileManager,
  capWindowControls, capWindowFullscreen, capMultiWindow}
  ## `capNativeMenuBar` is deliberately NOT here, and getting this wrong would
  ## have been a shipped regression rather than a modelling quibble.
  ##
  ## The desktop product draws its own menu in the page on Windows and Linux —
  ## `ui/menu.nim`'s `showNavigation` was `not defined(ctmacos)` — and mirrors
  ## it into the OS menu bar only on macOS. A base profile that claimed a
  ## native menu bar for all desktops would have removed the in-page menu from
  ## every Linux and Windows window the moment the build check became a
  ## capability query. The macOS instantiation adds it; nobody else has one.

const webCapabilities*: CapabilitySet = {
  capFilesystemRead, capFilesystemWrite, capFilesystemTemp,
  capVcsRead, capVcsWrite,
  capSettingsRead, capSettingsWrite,
  capClipboardWrite,
  capDownloadFile, capOpenFileDialog, capSaveFileDialog, capDirectoryPicker,
  capOpenExternalUrl,
  capWindowFullscreen,
  capShareLink}

const containerCapabilities*: CapabilitySet = {
  capFilesystemRead, capFilesystemWrite, capFilesystemWatch,
  capFilesystemTemp, capFilesystemArbitraryPaths,
  capProcessSpawn, capProcessSignal, capProcessInteractiveStdin,
  capProcessTerminal,
  capVcsRead, capVcsWrite, capVcsRemote,
  capSettingsRead, capSettingsWrite,
  capClipboardWrite,
  capDownloadFile, capOpenFileDialog, capSaveFileDialog, capDirectoryPicker,
  capOpenExternalUrl,
  capWindowFullscreen,
  capShareLink}

const headlessCapabilities*: CapabilitySet = {
  capFilesystemRead, capFilesystemWrite, capFilesystemTemp,
  capFilesystemArbitraryPaths,
  capProcessSpawn, capProcessSignal, capProcessInteractiveStdin,
  capVcsRead, capVcsWrite,
  capSettingsRead, capSettingsWrite}

let desktopProfile* = PlatformProfile(
  kind: pkDesktop,
  displayName: "desktop",
  capabilities: desktopCapabilities,
  degradations: @[
    DegradationRule(capability: capShareLink, behaviour:
      "there is no link to share: a desktop project is a directory, so the " &
      "equivalent action is an archive export"),
    DegradationRule(capability: capNativeMenuBar, behaviour:
      "the window has no OS menu bar to mirror into, so the menu is drawn in " &
      "the page — which is what Windows and Linux windows already do; only " &
      "the macOS instantiation adds this capability"),
  ])

let webProfile* = PlatformProfile(
  kind: pkWeb,
  displayName: "web",
  capabilities: webCapabilities,
  degradations: @[
    # -- filesystem -------------------------------------------------------
    DegradationRule(capability: capFilesystemWatch, behaviour:
      "no external process can change the project store, so nothing needs " &
      "watching; edits made in the tab notify the store directly and the " &
      "'file changed on disk' banner never appears"),
    DegradationRule(capability: capFilesystemArbitraryPaths, behaviour:
      "paths are relative to the project store and an absolute path outside " &
      "it is refused; opening work from elsewhere goes through the import " &
      "path (upload or a shared link) rather than a path box"),
    # -- process ----------------------------------------------------------
    DegradationRule(capability: capProcessSpawn, behaviour:
      "declared commands run as wasm modules in a worker; a project script " &
      "with no wasm build is reported as unavailable by name, with the " &
      "command shown, rather than failing silently mid-run"),
    DegradationRule(capability: capProcessSignal, behaviour:
      "cancelling terminates the worker, which is abrupt but complete; a " &
      "cancelled run therefore establishes nothing and produces no report"),
    DegradationRule(capability: capProcessInteractiveStdin, behaviour:
      "a run's input must be supplied before it starts; a command that " &
      "prompts mid-run cannot be answered and is reported as needing input"),
    DegradationRule(capability: capProcessTerminal, behaviour:
      "output is a scrollback pane rather than a pty: colours survive, but " &
      "cursor addressing, resizing and interactive TUIs do not"),
    # -- vcs --------------------------------------------------------------
    DegradationRule(capability: capVcsRemote, behaviour:
      "fetch and push need a peer that speaks git over a CORS-permitting " &
      "endpoint; until one is configured, history is local and leaving with " &
      "your work means the archive export"),
    # -- settings ---------------------------------------------------------
    DegradationRule(capability: capSecretStore, behaviour:
      "no secret is ever stored: deployment is signed by the user's own " &
      "wallet, per request, and a key pasted into the product would be a " &
      "promise the platform cannot keep (Noir-Studio.md §8)"),
    # -- clipboard --------------------------------------------------------
    DegradationRule(capability: capClipboardRead, behaviour:
      "reading the clipboard needs a permission the product does not ask " &
      "for; paste is handled by the browser's own paste event on the focused " &
      "editor, so the Paste menu item is absent rather than inert"),
    # -- shell ------------------------------------------------------------
    DegradationRule(capability: capRevealInFileManager, behaviour:
      "there is no enclosing file manager; 'Reveal' selects the entry in the " &
      "project tree instead"),
    DegradationRule(capability: capWindowControls, behaviour:
      "the browser owns the window frame, so the caption bar renders without " &
      "minimise/maximise/close and reclaims the space for tabs"),
    DegradationRule(capability: capNativeMenuBar, behaviour:
      "the in-page menu is the only menu; there is no OS menu bar to mirror " &
      "it into, and the macOS-only application menu is absent"),
    DegradationRule(capability: capMultiWindow, behaviour:
      "a second window is a second tab with its own session; panels cannot " &
      "be torn off into an OS window"),
  ])

let containerProfile* = PlatformProfile(
  kind: pkContainer,
  displayName: "container",
  capabilities: containerCapabilities,
  degradations: @[
    DegradationRule(capability: capSecretStore, behaviour:
      "the container has no user keychain; credentials are supplied to the " &
      "deployment as short-lived, per-request grants"),
    DegradationRule(capability: capClipboardRead, behaviour:
      "the clipboard belongs to the browser tab, not the container, and " &
      "reading it needs a permission the product does not ask for"),
    DegradationRule(capability: capRevealInFileManager, behaviour:
      "the container's filesystem has no file manager; 'Reveal' selects the " &
      "entry in the project tree instead"),
    DegradationRule(capability: capWindowControls, behaviour:
      "the browser owns the window frame — identical to the web profile, " &
      "because the shell is the same tab"),
    DegradationRule(capability: capNativeMenuBar, behaviour:
      "the in-page menu is the only menu"),
    DegradationRule(capability: capMultiWindow, behaviour:
      "a second window is a second tab against the same container session"),
  ])

let headlessProfile* = PlatformProfile(
  kind: pkHeadless,
  displayName: "headless",
  capabilities: headlessCapabilities,
  degradations: @[
    DegradationRule(capability: capFilesystemWatch, behaviour:
      "nothing observes the tree; a suite that needs a change noticed must " &
      "drive the notification itself"),
    DegradationRule(capability: capProcessTerminal, behaviour:
      "child output is captured through pipes; there is no pty"),
    DegradationRule(capability: capVcsRemote, behaviour:
      "no network is available to a headless run by policy, so remote " &
      "operations are refused rather than attempted"),
    DegradationRule(capability: capSecretStore, behaviour:
      "a headless run holds no secrets"),
    DegradationRule(capability: capClipboardWrite, behaviour:
      "there is no clipboard; a copy action reports the text it would have " &
      "copied so a test can assert on it"),
    DegradationRule(capability: capClipboardRead, behaviour:
      "there is no clipboard"),
    DegradationRule(capability: capDownloadFile, behaviour:
      "a download writes to the run's output directory instead of prompting"),
    DegradationRule(capability: capOpenFileDialog, behaviour:
      "no dialog can be shown; the path must be supplied by the caller"),
    DegradationRule(capability: capSaveFileDialog, behaviour:
      "no dialog can be shown; the path must be supplied by the caller"),
    DegradationRule(capability: capDirectoryPicker, behaviour:
      "no dialog can be shown; the path must be supplied by the caller"),
    DegradationRule(capability: capOpenExternalUrl, behaviour:
      "there is no browser to hand the URL to; the URL is recorded so a test " &
      "can assert which one would have opened"),
    DegradationRule(capability: capRevealInFileManager, behaviour:
      "there is no file manager"),
    DegradationRule(capability: capWindowControls, behaviour:
      "there is no window"),
    DegradationRule(capability: capWindowFullscreen, behaviour:
      "there is no window"),
    DegradationRule(capability: capNativeMenuBar, behaviour:
      "there is no menu bar"),
    DegradationRule(capability: capMultiWindow, behaviour:
      "there is no window"),
    DegradationRule(capability: capShareLink, behaviour:
      "there is no sharing service configured for a headless run"),
  ])

proc withCaptionBarOverlay*(profile: PlatformProfile;
                            overlays: bool): PlatformProfile =
  ## Instantiations call this. The reference profiles above leave
  ## `overlaysCaptionBar` false because a *profile* describes a class of
  ## platform, while the overlay is a fact about the running window system —
  ## macOS paints traffic lights over the caption bar and Windows and Linux do
  ## not. The desktop instantiation knows which it is on; this module must not
  ## guess with a `when defined(macosx)`, because that is the build check
  ## §1a.2 asks us to stop making.
  result = profile
  result.overlaysCaptionBar = overlays

proc withCapabilities*(profile: PlatformProfile;
                       capabilities: CapabilitySet;
                       degradations: seq[DegradationRule]): PlatformProfile =
  ## Narrow or widen a reference profile. Used by instantiations that can serve
  ## only part of their class's set — a native desktop process has no
  ## clipboard, and saying so is more useful than a facade that fails at run
  ## time.
  result = profile
  result.capabilities = capabilities
  result.degradations = degradations

proc withNoCapabilities*(profile: PlatformProfile;
                         because: string): PlatformProfile =
  ## Every capability absent, and every absence explained by the same sentence.
  ##
  ## For the platform a build has before `installPlatform` has run. Review found
  ## the alternative — handing back `headlessProfile` — actively misleading:
  ## `newPlatform` builds every facade as a refusal, so the default answered
  ## `can(capFilesystemRead)` with `true` and `fs.readText` with
  ## `pkNotSupported` in the same process. A caller who does the capability
  ## check first and the call second, which is the shape this whole module asks
  ## for, got the one answer the model promises cannot happen.
  result = profile
  result.capabilities = {}
  result.degradations = @[]
  for capability in allCapabilities:
    result.degradations.add DegradationRule(
      capability: capability, behaviour: because)

proc profileFor*(kind: PlatformKind): PlatformProfile =
  case kind
  of pkDesktop: desktopProfile
  of pkWeb: webProfile
  of pkContainer: containerProfile
  of pkHeadless: headlessProfile

const allPlatformKinds* = [pkDesktop, pkWeb, pkContainer, pkHeadless]
