## The platform facade — one object, seven capabilities, three instantiations.
##
## ## How front-end code uses this
##
## ```nim
## import viewmodel/platform/platform
##
## if platform().can(capShareLink):
##   ...
## discard platform().fs.readText(path)
## ```
##
## ## One process, SEVERAL sessions
##
## There used to be exactly one process-wide platform. That was right while a
## page talked to the deployment serving it and to nothing else, and it stopped
## being right when one WebUI began driving several container-backed sessions
## at once: each session is a different process on the other end of a different
## connection, with its own filesystem, its own VCS and its own capability
## profile, so "the platform" is no longer a property of the process.
##
## So the global is NARROWED rather than removed. There is a registry keyed by
## session id, and `platform()` is the ACTIVE session's — which is what a view
## rendering one session at a time is asking for, and what every call site that
## predates sessions keeps meaning. The empty string is a session id like any
## other and is the default one, so a build that installs a single platform and
## never names a session behaves exactly as it did.
##
## That it is still a global is deliberate, for the original reason: the
## alternative is threading a `Platform` through every ViewModel constructor in
## the tree, which is a large mechanical change, and what tests need is not
## injection at every call site but the ability to *install* a different one.
## What changed is only that "install" now has a key.
##
## ```nim
## installPlatform("s-1", newContainerPlatform(...))   # a session's own
## installPlatform("s-2", newContainerPlatform(...))
## discard setActivePlatformSession("s-2")             # what platform() means
## discard platformFor("s-1").fs.readText(path)        # a specific one
## releasePlatformSession("s-1")                       # it ended
## ```
##
## ## What `nil` means here, and why it is a defect rather than a state
##
## `platform()` before `installPlatform` returns the headless platform: every
## capability absent, every operation refusing with `pkNotSupported`. It does
## not return `nil` and it does not raise. A front end that reads a setting
## before start-up finished should get a refusal it can render, not a crash —
## and a test that forgot to install a platform should see its assertions fail
## on the refusal rather than on a segfault three frames away.

import std/[algorithm, tables]

import ./outcome
import ./capabilities
import ./fs
import ./process
import ./vcs
import ./settings
import ./clipboard
import ./download
import ./shell

export outcome, capabilities, fs, process, vcs, settings, clipboard, download,
       shell

type
  Platform* = ref object
    profile*: PlatformProfile
    fs*: FileSystemFacade
    process*: ProcessFacade
    vcs*: VcsFacade
    settings*: SettingsFacade
    clipboard*: ClipboardFacade
    download*: DownloadFacade
    shell*: ShellFacade

proc can*(self: Platform; capability: PlatformCapability): bool =
  ## The only question front-end code should ask about the platform. Not
  ## "am I on the web", not "is this Electron" — *can I do this*.
  not self.isNil and capability in self.profile.capabilities

proc canAll*(self: Platform; required: CapabilitySet): bool =
  not self.isNil and required <= self.profile.capabilities

proc kind*(self: Platform): PlatformKind =
  ## Available, and almost always the wrong thing to branch on. Present for
  ## diagnostics, telemetry and the one legitimate case — choosing wording
  ## that names the platform ("your browser", "this container").
  self.profile.kind

proc degradedBehaviour*(self: Platform;
                        capability: PlatformCapability): string =
  self.profile.degradedBehaviour(capability)

proc newPlatform*(profile: PlatformProfile): Platform =
  ## A platform where every capability refuses. Instantiations build on this
  ## rather than on a zeroed object, so a facade field that a new instantiation
  ## has not implemented yet is a named refusal instead of a nil-call crash —
  ## and adding a field to a facade cannot silently break an instantiation that
  ## has not been updated.
  Platform(
    profile: profile,
    fs: unavailableFileSystem(profile),
    process: unavailableProcess(profile),
    vcs: unavailableVcs(profile),
    settings: unavailableSettings(profile),
    clipboard: unavailableClipboard(profile),
    download: unavailableDownload(profile),
    shell: unavailableShell(profile))

type PlatformSessionId* = string
  ## Which session a platform belongs to. The CLIENT's name for the
  ## conversation, the same string `container_boot`'s frames carry, so a
  ## session's platform and a session's transport are keyed alike.

const DefaultPlatformSession* = ""
  ## The single-session deployment, and the default everywhere. Not a sentinel
  ## for "none": it is an ordinary id that happens to be empty, which is what
  ## lets every pre-session call site keep working unchanged.

var sessions = initTable[PlatformSessionId, Platform]()
var activeSession: PlatformSessionId = DefaultPlatformSession

const noPlatformInstalled =
  "no platform has been installed in this process yet, so nothing can be " &
  "done through the facade; whichever build this is must call " &
  "installPlatform at start-up"

let uninstalledProfile* = headlessProfile.withNoCapabilities(noPlatformInstalled)
  ## The profile of the platform `platform()` hands back before
  ## `installPlatform` has run. Deliberately NOT `headlessProfile`: every
  ## operation of that default refuses, so a profile that declared the headless
  ## capability set would say `can(capFilesystemRead)` and then refuse the read
  ## — the disagreement between "may I" and "did it work" that capabilities
  ## exist to remove. `test_the_default_platform_promises_nothing_it_refuses`
  ## in `test_platform_facade.nim` pins it.

var platformWasChosen = false
  ## Whether an instantiation was *chosen*, as opposed to the lazy default
  ## below having been materialised.
  ##
  ## `platformInstalled()` cannot answer that question, and the difference
  ## is not academic: `platform()` fills the field in with
  ## `newPlatform(uninstalledProfile)` on its first call, so after any bare
  ## read `platformInstalled()` is true while nothing has been installed at
  ## all. A caller asking "has a real platform been chosen yet" — and
  ## `platform_host.ctPlatform()` is exactly such a caller — needs the other
  ## answer, so it gets its own flag rather than a heuristic over the profile.

proc installPlatform*(session: PlatformSessionId; newPlatform: Platform) =
  ## Register one session's platform, and make it the active one if nothing is
  ## active yet.
  ##
  ## It does NOT steal the active session from an already-installed one. A
  ## second session booting in the background while the user is looking at the
  ## first must not silently redirect every `platform()` read in the tree —
  ## switching is `setActivePlatformSession`, which is a decision a view makes
  ## and not a side effect of a handshake completing.
  sessions[session] = newPlatform
  if not platformWasChosen:
    activeSession = session
  platformWasChosen = true

proc installPlatform*(newPlatform: Platform) =
  ## The single-session spelling, unchanged in behaviour: it installs into
  ## `DefaultPlatformSession` and makes it active.
  sessions[DefaultPlatformSession] = newPlatform
  activeSession = DefaultPlatformSession
  platformWasChosen = true

proc platform*(): Platform =
  ## The ACTIVE session's platform, materialising the refusing default if
  ## nothing has been installed for it.
  ##
  ## The materialisation is why `platformInstalled()` is true after any bare
  ## read; `platformWasExplicitlyChosen()` is the question that survives it.
  ## `platformFor` deliberately does NOT do this — see there.
  if not sessions.hasKey(activeSession):
    sessions[activeSession] = newPlatform(uninstalledProfile)
  sessions[activeSession]

proc platformFor*(session: PlatformSessionId): Platform =
  ## One named session's platform, or the refusing default for a session that
  ## has none.
  ##
  ## IT DOES NOT REGISTER THE SESSION. `platform()` materialises because a
  ## process always has an active session and a test pins that it does; a
  ## lookup by name must not, or asking about a session would bring it into
  ## existence and `platformSessions()` would grow every time a caller checked.
  ## The answer is the same refusing platform either way, so a caller that
  ## names a session that has gone away gets `pkNotSupported` rather than a
  ## crash — which is the rule the header states for `nil`.
  if sessions.hasKey(session): sessions[session]
  else: newPlatform(uninstalledProfile)

proc hasPlatformSession*(session: PlatformSessionId): bool =
  sessions.hasKey(session)

proc platformSessions*(): seq[PlatformSessionId] =
  ## Every session with a platform installed, in a stable order so that a UI
  ## listing them does not reorder itself between renders.
  for id in sessions.keys: result.add id
  result.sort()

proc activePlatformSession*(): PlatformSessionId =
  ## Which session `platform()` means.
  activeSession

proc setActivePlatformSession*(session: PlatformSessionId): bool =
  ## Point `platform()` at another session. False — and NOTHING CHANGED — when
  ## that session has no platform.
  ##
  ## A refusal rather than a silent switch to the refusing default: a view
  ## asked to show a session that has not booted should say so, not render
  ## every panel as "unsupported" and leave whoever is looking at it to work
  ## out which of the two happened.
  if not sessions.hasKey(session): return false
  activeSession = session
  true

proc releasePlatformSession*(session: PlatformSessionId) =
  ## A session ended. Its platform goes with it, or a facade call made after
  ## the container is gone reaches a transport whose socket is closed and hangs
  ## pending for ever, instead of refusing.
  ##
  ## Releasing the ACTIVE session leaves it active and unregistered, so
  ## `platform()` materialises the refusing default for it — the page is
  ## between sessions, which is what it looks like. Choosing a successor is the
  ## caller's: this proc cannot know which of the remaining sessions the user
  ## was about to look at.
  sessions.del(session)

proc platformInstalled*(): bool =
  ## Whether the ACTIVE session has a platform object. True after any bare
  ## `platform()` read — see `platformWasChosen`.
  sessions.hasKey(activeSession)

proc platformWasExplicitlyChosen*(): bool =
  ## True once `installPlatform` has run for any session, and **not** made true
  ## by `platform()` materialising its default. See `platformWasChosen`.
  platformWasChosen

proc resetPlatformForTesting*() =
  ## Only tests call this. Named so that a production caller reads as wrong.
  sessions.clear()
  activeSession = DefaultPlatformSession
  platformWasChosen = false
