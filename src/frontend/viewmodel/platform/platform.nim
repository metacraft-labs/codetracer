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

proc installPlatform*(newPlatform: Platform) =
  installedPlatform = newPlatform

proc platform*(): Platform =
  if installedPlatform.isNil:
    installedPlatform = newPlatform(headlessProfile)
  installedPlatform

proc platformInstalled*(): bool =
  not installedPlatform.isNil

proc resetPlatformForTesting*() =
  ## Only tests call this. Named so that a production caller reads as wrong.
  installedPlatform = nil
