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
## There is exactly one process-wide platform, installed once at start-up by
## whichever instantiation this build is, and readable everywhere. That is a
## global, deliberately: the alternative is threading a `Platform` through
## every ViewModel constructor in the tree, which is a large mechanical change
## that buys nothing — the platform genuinely is process-wide, and the thing
## tests need is not injection at every call site but the ability to *install*
## a different one, which `installPlatform` gives them.
##
## ## What `nil` means here, and why it is a defect rather than a state
##
## `platform()` before `installPlatform` returns the headless platform: every
## capability absent, every operation refusing with `pkNotSupported`. It does
## not return `nil` and it does not raise. A front end that reads a setting
## before start-up finished should get a refusal it can render, not a crash —
## and a test that forgot to install a platform should see its assertions fail
## on the refusal rather than on a segfault three frames away.

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

var installedPlatform: Platform = nil

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
  ## `installedPlatform.isNil` cannot answer that question, and the difference
  ## is not academic: `platform()` fills the field in with
  ## `newPlatform(uninstalledProfile)` on its first call, so after any bare
  ## read `platformInstalled()` is true while nothing has been installed at
  ## all. A caller asking "has a real platform been chosen yet" — and
  ## `platform_host.ctPlatform()` is exactly such a caller — needs the other
  ## answer, so it gets its own flag rather than a heuristic over the profile.

proc installPlatform*(newPlatform: Platform) =
  installedPlatform = newPlatform
  platformWasChosen = true

proc platform*(): Platform =
  if installedPlatform.isNil:
    installedPlatform = newPlatform(uninstalledProfile)
  installedPlatform

proc platformInstalled*(): bool =
  not installedPlatform.isNil

proc platformWasExplicitlyChosen*(): bool =
  ## True once `installPlatform` has run, and **not** made true by `platform()`
  ## materialising its default. See `platformWasChosen`.
  platformWasChosen

proc resetPlatformForTesting*() =
  ## Only tests call this. Named so that a production caller reads as wrong.
  installedPlatform = nil
  platformWasChosen = false
