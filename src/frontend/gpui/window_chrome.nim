## window_chrome.nim — PLAT-69: THE GPUI WINDOW AS A DESKTOP WINDOW.
##
## The one module of this front-end that speaks to the renderer's WINDOW
## (isonim-gpui's `window` and `window_environment`): the window `gpui_launch`
## opens, never the window registry (`createWindow` / `show` / `destroy`, which
## no renderer reads — see `test_gpui_window_frame.nim`'s registry scan). It
## answers five questions for `main.nim`, and does nothing else:
##
##   * WHO IS DRAWING THE FRAME, and so whether the top bar is the title bar —
##     `WindowChrome`: the decoration mode the compositor granted, which
##     buttons the platform supports, where the desktop wants them, and
##     whether the window is maximized (the maximize button then restores).
##   * WHAT TO ASK FOR at launch — the minimum size, the initial state and
##     the app id (`prepareWindowLaunch`).
##   * WHEN TO DRAW AGAIN — the content size changed, or the chrome did
##     (`subscribeWindow`).
##   * WHEN TO READ AGAIN — the user came back to the window from another
##     program (`subscribeWindow`'s `activated`): the desktop's window
##     `focus` event, which the VCS pane re-reads its repository on.
##   * WHAT THE WINDOW IS CALLED — its title (`setWindowTitle`).
##
## THE CHROME HAS A STAND-IN. `--report-window-plan` draws the window with no
## window open, so there is no decoration mode to read; `--window-chrome`
## names one (`windowChromeOfSpec`), resolved through the same
## `resolveWindowEnvironment` policy a live window's is, so the plan suites
## grade the drawing of a client-decorated bar without a compositor.

import std/[strutils]
import isonim_gpui/[window, window_environment]
import ../../common/window_policy
import ./window_top_bar

export WindowRegion

const WindowRegionAttribute* = windowRegionAttribute
  ## `data-window-region`: how an element of the tree declares itself part of
  ## the title bar (`drag`), not part of it (`no-drag`), or a window button.

type
  WindowChrome* = object
    ## The window's frame as the renderer reports it (or as `--window-chrome`
    ## stands in for it).
    clientDecorated*: bool
      ## The compositor draws no frame; the application's top bar is the
      ## title bar (GNOME, or sway when asked with
      ## `ISONIM_GPUI_DECORATIONS=client`).
    maximized*: bool
    buttons*: GWindowButtons
      ## The buttons the environment prefers on each side, filtered by what
      ## the platform supports — whether or not they are drawn (`shownButtons`).
    supported*: seq[GWindowButton]
    buttonLayout*: string
      ## The desktop's configured layout (GNOME `button-layout` syntax), ""
      ## when none was read.
    placementSource*: string
      ## "portal" (the desktop's setting) or "platform-default".
    platform*, desktop*: string
    live*: bool
      ## Read from an open window, not stood in for.

const
  CodeTracerWaylandAppId* = "codetracer"
    ## `resources/codetracer.desktop`'s basename: what a Wayland compositor
    ## matches a window's `app_id` against.
  CodeTracerX11WmClass* = "CodeTracer"
    ## That file's `StartupWMClass`: what an X11 desktop matches `WM_CLASS`'s
    ## class against.

func toGButton(b: WindowButton): GWindowButton =
  case b
  of wbMinimize: gwbMinimize
  of wbMaximize: gwbMaximize
  of wbClose: gwbClose

func toGButtons(s: seq[WindowButton]): seq[GWindowButton] =
  for b in s: result.add toGButton(b)

func chromeOfEnvironment*(env: WindowEnvironment; maximized: bool;
                          live: bool): WindowChrome =
  ## The chrome a resolved environment describes.
  result = WindowChrome(clientDecorated: env.clientDecorated,
                        maximized: maximized, live: live,
                        platform: env.platform, desktop: env.desktop,
                        placementSource: $env.placementSource)
  result.buttons = (toGButtons(env.preferredLeft), toGButtons(env.preferredRight))
  for b in WindowButton:
    if b in env.supported: result.supported.add toGButton(b)

proc shownButtons*(c: WindowChrome): GWindowButtons =
  ## The buttons the top bar DRAWS: the preferred ones where the application
  ## decorates the window, and none where the platform draws the frame
  ## (PLAT-69-AREQ3 — a second set of buttons beside the compositor's would
  ## be the defect, not a feature).
  if c.clientDecorated: c.buttons else: (@[], @[])

proc launchedWindow(): GpuiWindow = window.launchWindow()

proc liveWindowChrome*(): WindowChrome =
  ## The chrome of the window `gpui_launch` opened. With no window open
  ## (`--report-window-plan`, `--pixels-out`), the server-side answer: no
  ## buttons and no drag strip, which is exactly what those paths drew before.
  let win = launchedWindow()
  if win.id == 0:
    return WindowChrome(placementSource: $psPlatformDefault,
                        platform: currentPlatform())
  result = chromeOfEnvironment(windowEnvironment(win), win.isMaximized,
                               live = true)
  result.buttonLayout = win.buttonLayout

proc windowChromeOfSpec*(spec: string): tuple[ok: bool; chrome: WindowChrome;
                                               message: string] =
  ## `--window-chrome=<server|client>[+maximized][+no-minimize][+no-maximize]
  ## [+layout=<left>:<right>]` — the stand-in for a live window's chrome in
  ## `--report-window-plan`. The layout is GNOME `button-layout` syntax, e.g.
  ## `layout=close,minimize,maximize:`. `+` separates the parts because the
  ## layout itself holds commas and a colon.
  let parts = spec.split('+')
  var clientDecorated = false
  case parts[0]
  of "client": clientDecorated = true
  of "server": clientDecorated = false
  else:
    return (false, WindowChrome(), "--window-chrome: '" & parts[0] &
            "' is not one of client, server")
  var controls = {wcMinimize, wcMaximize, wcFullscreen, wcWindowMenu}
  var maximized = false
  var layout = ""
  for p in parts[1 .. ^1]:
    if p == "maximized": maximized = true
    elif p == "no-minimize": controls.excl wcMinimize
    elif p == "no-maximize": controls.excl wcMaximize
    elif p.startsWith("layout="):
      layout = p["layout=".len .. ^1]
      if not parseButtonLayout(layout).ok:
        return (false, WindowChrome(), "--window-chrome: '" & layout &
                "' is not a button layout (<left>:<right>)")
    else:
      return (false, WindowChrome(), "--window-chrome: unknown part '" & p & "'")
  let env = resolveWindowEnvironment("linux-wayland", "", clientDecorated,
                                     controls, layout)
  var chrome = chromeOfEnvironment(env, maximized, live = false)
  chrome.buttonLayout = layout
  (true, chrome, "")

proc windowAppId*(platform = currentPlatform()): string =
  ## PLAT-69 (C4): THE APP ID SHARED WITH THE DESKTOP FRONT-END.
  ##
  ## `gpui_set_app_id` takes ONE string, which GPUI uses as the Wayland
  ## `app_id` AND as both halves of the X11 `WM_CLASS`, while the `.desktop`
  ## file names the window two ways: `codetracer` (its basename, which Wayland
  ## compositors match) and `CodeTracer` (its `StartupWMClass`, which X11
  ## desktops match). So the string follows the display GPUI is about to open
  ## — the same choice GPUI makes, `WAYLAND_DISPLAY` set or not
  ## (`window_environment.currentPlatform`). The desktop (Electron) reports
  ## `codetracer` on Wayland and `WM_CLASS` `codetracer` / `CodeTracer` on
  ## X11, so the two front-ends share the Wayland id and the X11 class — the
  ## halves a desktop matches a `.desktop` file by. Only GPUI's X11 instance
  ## half differs (`CodeTracer`, Electron's `codetracer`), which one string
  ## cannot avoid.
  if platform == "linux-x11": CodeTracerX11WmClass
  else: CodeTracerWaylandAppId

proc prepareWindowLaunch*(launch: WindowLaunch) =
  ## Before `gpui_launch`: the minimum size, the initial state and the app id.
  window.setMinWindowSize(float(launch.minWidth), float(launch.minHeight))
  window.setInitialWindowState(launch.maximized)
  window.setAppId(windowAppId())

proc subscribeWindowOn*(win: GpuiWindow;
                        resized: proc(width, height: int);
                        chromeChanged: proc();
                        activated: proc()): bool =
  ## `subscribeWindow` for a named window: what `main.nim`'s root builder
  ## registers on the launched one, and what a suite registers on a window
  ## it created to drive the same subscriptions through the shim's bridging
  ## entry points (`gpui_notify_window_state`). False for window id 0.
  ##
  ## `activated` runs when the window is ACTIVATED — inactive, then active:
  ## the user came back to it from another program (`onWindowActivated`, the
  ## renderer's inactive-to-active edge). It is the window's equivalent of
  ## the desktop's window `focus` event, which its VCS panel re-reads the
  ## repository on (VCS-Panel.md's focus-gain refresh); `nil` subscribes
  ## nothing.
  if win.id == 0:
    return false
  window.onResize(win, proc(w, h: float) = resized(int(w + 0.5), int(h + 0.5)))
  window.onWindowState(win, chromeChanged)
  if not activated.isNil:
    window.onWindowActivated(win, activated)
  true

proc subscribeWindow*(resized: proc(width, height: int);
                      chromeChanged: proc();
                      activated: proc()): bool =
  ## From inside the root builder: be told when the launched window's content
  ## size changes (before the frame at the new size is built), when its
  ## chrome does — the decoration mode granted after mapping, maximize and
  ## restore, the desktop's button layout changed while the window is open —
  ## and when it is activated (see `subscribeWindowOn`).
  ## False when no window is being launched (the plan and capture paths).
  subscribeWindowOn(launchedWindow(), resized, chromeChanged, activated)

proc setWindowTitle*(title: string): bool {.discardable.} =
  ## The launched window's title, changed while it is open (a session tab
  ## shown). False with no window.
  let win = launchedWindow()
  if win.id == 0:
    return false
  win.setTitle(title)
