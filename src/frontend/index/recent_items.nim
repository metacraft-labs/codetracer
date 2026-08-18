## Pure model of *how the renderer's recent-traces / recent-folders cache is
## filled*, per startup path.
##
## Everything here is deliberately free of JS/DOM/IPC dependencies so it can be
## compiled and exercised natively (and under `nim js`) by
## `src/tests/gui/tests/welcome-screen/recent_items_startup_vm_test.nim`, the
## same way `index/bootstrap_cache.nim` is exercised by
## `page-objects-tests/reload_reconnect_vm_test.nim`.  `index/startup.nim` is
## the adapter: it asks this module which channel the current startup path uses
## and performs the fetch/send.
##
## Why this exists (issue #568): the lists used to be fetched *only* inside the
## welcome-screen branch of `index/startup.nim`, and the renderer only ever set
## `data.recentTraces` from the `CODETRACER::welcome-screen` message that branch
## sends.  A process started with `ct run <program>` therefore never had them,
## so the welcome surface opened by the session tab bar's "+" button showed an
## empty Recent Traces panel for the whole lifetime of that process.
##
## The contract the model encodes, and that the test asserts exhaustively over
## `StartupPath`: **every startup path that can put the welcome surface on
## screen must deliver the recent lists over some channel.**  The specs it rests
## on are
##
##   - `codetracer-specs/GUI/Welcome-And-Sessions/Welcome-Screen.md`: "It
##     provides quick access to recent traces, recent folders, and options to
##     start new recordings or open existing projects", and "### Right Panel:
##     Recent Traces — Lists recently opened trace recordings".  The spec
##     describes a single Welcome Screen whose Recent Traces panel is not
##     conditioned on how the process was started.
##   - `codetracer-specs/GUI/Multi-Window-Tab-Management.md`: "The \"+\" button
##     opens a new empty tab (for loading a new trace)" and "Closing the last
##     tab shows the welcome screen" — i.e. the welcome surface is reachable
##     from *any* windowed session, not only from a welcome-screen launch.

type
  StartupPath* = enum
    ## The mutually exclusive startup paths `index/startup.nim`'s `init`
    ## dispatches on, in the order it tests them.
    spShellUi     ## `--shell-ui`: mounts the CodeTracer shell surface.
    spDeepReview  ## `--deep-review`: adds the review surface to the layout.
    spReplay      ## `ct run <program>` / `ct replay <trace>`: opens a trace.
    spEdit        ## `ct edit <folder>`: opens a workspace with no trace.
    spWelcome     ## no target: the welcome screen is the initial view.

  RecentItemsChannel* = enum
    ## Which IPC message carries the recent-traces / recent-folders lists to
    ## the renderer for a given startup path.
    ricNone           ## No welcome surface is reachable; nothing to deliver.
    ricWelcomeScreen  ## Inline in `CODETRACER::welcome-screen`.
    ricRecentItems    ## Separate `CODETRACER::recent-items` push.

const
  RecentItemsMessage* = cstring"CODETRACER::recent-items"
    ## Index -> renderer push used by every startup path that does not already
    ## carry the lists inline in its own startup message.

  WelcomeScreenMessage* = cstring"CODETRACER::welcome-screen"
    ## Index -> renderer startup message of the welcome-screen path; it carries
    ## the recent lists inline, together with the layout and start options.

proc startupPath*(shellUi, withDeepReview, edit, welcomeScreen: bool): StartupPath =
  ## Classify a `StartOptions` flag combination into the branch
  ## `index/startup.nim`'s `init` will take.  The order of the tests mirrors
  ## that `if`/`elif` chain exactly, including the case where both `edit` and
  ## `welcomeScreen` are set (the edit branch wins).
  if shellUi:
    spShellUi
  elif withDeepReview:
    spDeepReview
  elif not edit and not welcomeScreen:
    spReplay
  elif edit:
    spEdit
  else:
    spWelcome

proc showsWelcomeSurface*(path: StartupPath): bool =
  ## Can this startup path ever put the welcome surface on screen?
  ##
  ## Every windowed path can: the session tab bar's "+" opens a new empty tab
  ## whose surface *is* the welcome screen, and closing the last tab returns to
  ## it (`GUI/Multi-Window-Tab-Management.md`).  The shell UI is the single
  ## exception — `ui_js.onStartShellUi` calls `hideWelcomeScreenSurface()` and
  ## mounts the shell component instead, so there is no welcome surface to fill.
  path != spShellUi

proc recentItemsChannel*(path: StartupPath): RecentItemsChannel =
  ## The channel that delivers the recent lists for `path`.
  ##
  ## This is the decision `index/startup.nim` acts on.  Note that no
  ## welcome-surface-capable path maps to `ricNone`; that invariant is what the
  ## regression test for #568 asserts, exhaustively over `StartupPath`, so a
  ## future startup path cannot be added without deciding how it gets its
  ## recent lists.
  case path
  of spShellUi:
    ricNone
  of spWelcome:
    ricWelcomeScreen
  of spDeepReview, spReplay, spEdit:
    ricRecentItems

proc needsRecentItemsPush*(path: StartupPath): bool =
  ## True when `index/startup.nim` must fetch the recent lists and send them
  ## over `RecentItemsMessage` because no other startup message carries them.
  recentItemsChannel(path) == ricRecentItems
