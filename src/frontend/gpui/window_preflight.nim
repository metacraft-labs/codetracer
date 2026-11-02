## window_preflight.nim — can `codetracer-gpui` open a window at all?
##
## Asked once, by `main.launchWindow`, on the one path that is about to call
## `gpui_launch` — never by `--report-plan`, `--report-window-plan` or
## `--pixels-out`, which open no window and must keep working on any host.
##
## ## Why there is a question to ask
##
## Two configurations used to show NOTHING and say nothing
## (`codetracer-pm/issues/2026-10-01-gpui-launch-is-silent-when-no-window-can-open.md`):
##
##   1. **A featureless shim** — `isonim-gpui` built by a bare `cargo build`
##      (`just rust-build`), without `--features gpui-backend`, which is the
##      default and what the GPUI test lanes link. Its `gpui_launch` builds the
##      shadow tree, calls the root builder and RETURNS, so this binary exited
##      0 in a fraction of a second and the user saw no window and no word.
##   2. **No graphical session on Linux** — no `WAYLAND_DISPLAY` and no
##      `DISPLAY` (an SSH session, a bare tty). GPUI then picks its HEADLESS
##      platform, which opens no window and so never closes one:
##      `gpui_launch` blocks forever, silently.
##
## Both are now a refusal by kind, on stderr, with `ExitNoWindow` (3) — the
## same number and the same reasoning as the terminal front-end's
## `ExitNoTerminal` (`src/frontend/tui/app/cli.nim`): a trace and nothing to
## draw it on is a correct command line and an impossible request, which is
## neither a usage error (2) nor an unhandled one (1). The contract is
## `codetracer-pm/spec/CLI/ct/ui-selection.md` §8a.
##
## ## The decision is a pure function, on purpose
##
## `windowPreflight` takes what it decides on — whether the loaded shim has a
## window backend, an environment lookup and the target OS — as arguments, so
## every combination is tested in-process (`tests/test_gpui_window_preflight.nim`)
## without a display, without a shim of each kind and without mutating this
## process's environment. `currentWindowPreflight` only gathers the three live
## inputs. The rule for "will GPUI find a display" is not restated here: it is
## `isonim_gpui/display_session`'s mirror of GPUI's own `guess_compositor`,
## which owns that knowledge beside the GPUI pin it describes.
##
## ## When both problems apply, the featureless one is reported
##
## A featureless shim does not link GPUI at all, so it never consults the
## display; the rebuild is needed whatever the session, and it is the first
## thing the user has to do. The kind is therefore `wpNoWindowBackend`, and
## the message ALSO says that no graphical session was found, so the user is
## not sent round the loop twice (rebuild, run, be refused again).

import std/options
import isonim_gpui/display_session

const
  ExitNoWindow* = 3
    ## The recording opened and there is no window to show it in: the shim has
    ## no window backend, or there is no graphical session. Equal to the
    ## terminal front-end's `ExitNoTerminal` on purpose, so a script driving
    ## `ct replay --ui=<either>` reads one code for "this front-end cannot draw
    ## here".

  NoWindowBackendMessage* =
    "this build of the GPUI shim has no window backend; rebuild " &
    "isonim-gpui's shim with `--features gpui-backend`"
    ## The wording is the issue's, which the spec quotes; the integration
    ## test greps for "no window backend".
  NoGraphicalSessionMessage* =
    "no graphical session (DISPLAY / WAYLAND_DISPLAY unset)"
  ZedHeadlessMessage* =
    "no graphical session (ZED_HEADLESS is set, so GPUI runs without a " &
    "display)"
    ## GPUI honours `ZED_HEADLESS` by presence alone and then opens no window
    ## even when a display IS set; naming the variable is the only useful
    ## thing to say, because "DISPLAY unset" would be false.
  NoWindowHint* =
    "use --report-plan to check the build without a window"
    ## Appended to every refusal: the introspection path works on any host.

type
  WindowRefusal* = enum
    wpWindowCanOpen = "ok"
    wpNoWindowBackend = "no-window-backend"
      ## The loaded shim was built without `--features gpui-backend`.
    wpNoGraphicalSession = "no-graphical-session"
      ## Linux/FreeBSD, and GPUI would pick its headless platform.

  WindowPreflight* = object
    refusal*: WindowRefusal
    message*: string
      ## Empty for `wpWindowCanOpen`; otherwise the full sentence printed
      ## after `codetracer-gpui: `.

proc noSessionMessage(env: EnvLookup): string =
  ## The no-display sentence, naming `ZED_HEADLESS` when that is the cause.
  if env("ZED_HEADLESS").isSome: ZedHeadlessMessage
  else: NoGraphicalSessionMessage

proc windowPreflight*(hasWindowBackend: bool; env: EnvLookup;
                      targetOs: string): WindowPreflight =
  ## Whether a window can open, and if not, why — by kind, with the message.
  ## `targetOs` is spelled as Nim's `hostOS` ("linux", "macosx", "windows",
  ## …); only the targets where GPUI picks its platform from the environment
  ## consult `env` at all.
  let noSession = gpuiChoosesPlatformFromEnv(targetOs) and
                  gpuiLinuxPlatform(env) == glpHeadless
  if not hasWindowBackend:
    var message = NoWindowBackendMessage
    if noSession:
      # See the module header: the featureless kind wins, and the second
      # problem is still named so the rebuild is not followed by a surprise.
      message.add "; there is also " & noSessionMessage(env)
    return WindowPreflight(refusal: wpNoWindowBackend,
                           message: message & "; " & NoWindowHint)
  if noSession:
    return WindowPreflight(refusal: wpNoGraphicalSession,
                           message: noSessionMessage(env) & "; " & NoWindowHint)
  WindowPreflight(refusal: wpWindowCanOpen)

proc currentWindowPreflight*(hasWindowBackend: bool): WindowPreflight =
  ## `windowPreflight` over this process: its real environment and the OS it
  ## was compiled for. `hasWindowBackend` is the loaded shim's own answer
  ## (`gpui_has_window_backend() == 1`), passed in so this module links no
  ## shim and its tests need none.
  windowPreflight(hasWindowBackend, processEnv, hostOS)
