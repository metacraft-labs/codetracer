## The shell-and-windowing facade.
##
## Desktop: Electron. Web: the tab. Container: the tab (Noir-Studio.md §3.1).
##
## ## This is the module that makes the topbar parametric
##
## §1a.2: "Window controls appear on desktop and not on the web, because the
## platform either owns the window frame or does not. Share and identity are
## the same slot from the other side." Today `ui/menu.nim` decides that with
## `defined(ctmacos)` and `electron_lib.inElectron` — two build checks. The
## capability queries here replace them, so an action is absent because its
## capability is, and a fourth platform is an instantiation rather than a
## fourth branch at every site.
##
## ## Window operations are requests, not commands
##
## `minimize` on the web is not "minimise, badly"; it is nothing at all, and
## `capWindowControls` is how the caller knows before it renders a button. The
## operations still return outcomes rather than nothing, because a container
## instantiation's window request crosses a wire and can fail in transit.

import ./outcome
import ./capabilities

export outcome

type
  WindowState* = object
    maximized*: bool
    minimized*: bool
    fullscreen*: bool
    focused*: bool

  ShellFacade* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason spelled out on `FileSystemFacade` in
    ## `fs.nim`: without it, an unassigned field is `nil` rather than a compile
    ## error, and an operation that only makes sense in-process could be added
    ## without `host/remote_stub.nim` noticing.
    profile*: PlatformProfile

    # -- external targets ---------------------------------------------------
    openExternalUrl*: proc(url: string): PlatformFuture[PlatformOutcome[Nothing]]
      ## Hand a URL to whatever opens URLs here. Implementations must refuse
      ## anything but `http`, `https` and `mailto`: `openExternal` with a
      ## `file:` or a shell-handler scheme is a code-execution primitive, and
      ## the front end never has a reason to reach one.
    revealInFileManager*: proc(path: string): PlatformFuture[PlatformOutcome[Nothing]]

    # -- window (capWindowControls / capWindowFullscreen) -------------------
    windowState*: proc(): PlatformFuture[PlatformOutcome[WindowState]]
    minimizeWindow*: proc(): PlatformFuture[PlatformOutcome[Nothing]]
    toggleMaximizeWindow*: proc(): PlatformFuture[PlatformOutcome[Nothing]]
    closeWindow*: proc(): PlatformFuture[PlatformOutcome[Nothing]]
    setFullscreen*: proc(fullscreen: bool): PlatformFuture[PlatformOutcome[Nothing]]

    onWindowStateChanged*: proc(handler: proc(state: WindowState))
      ## Subscription rather than polling, because the OS is the source of the
      ## fullscreen transition on the desktop and the browser is on the web.
      ## Returns nothing: unsubscription is not a thing any caller needs — the
      ## shell outlives them all.

    # -- multi-window (capMultiWindow) --------------------------------------
    openSessionWindow*: proc(sessionId: string): PlatformFuture[PlatformOutcome[Nothing]]

proc unavailableShell*(profile: PlatformProfile): ShellFacade =
  ShellFacade(
    profile: profile,
    openExternalUrl: proc(url: string): auto =
      resolvedUnsupported[Nothing]("opening external links"),
    revealInFileManager: proc(path: string): auto =
      resolvedUnsupported[Nothing]("revealing files"),
    windowState: proc(): auto =
      resolvedUnsupported[WindowState]("window state"),
    minimizeWindow: proc(): auto =
      resolvedUnsupported[Nothing]("window controls"),
    toggleMaximizeWindow: proc(): auto =
      resolvedUnsupported[Nothing]("window controls"),
    closeWindow: proc(): auto =
      resolvedUnsupported[Nothing]("window controls"),
    setFullscreen: proc(fullscreen: bool): auto =
      resolvedUnsupported[Nothing]("fullscreen"),
    onWindowStateChanged: proc(handler: proc(state: WindowState)) = discard,
    openSessionWindow: proc(sessionId: string): auto =
      resolvedUnsupported[Nothing]("additional windows"))
