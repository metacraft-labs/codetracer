## recent_items_startup_vm_test.nim
##
## Regression test for issue #568 — "recent traces list not initialized when
## starting directly with `ct run`".
##
## The defect was a startup/IPC wiring hole, not a rendering bug: the
## recent-traces and recent-folders lists were fetched *only* inside the
## welcome-screen branch of `src/frontend/index/startup.nim`, and the renderer
## only ever assigned `data.recentTraces` from the `CODETRACER::welcome-screen`
## message that branch sends.  A process started with `ct run <program>` took a
## different branch, so `data.recentTraces` stayed empty for the lifetime of the
## process and `ui/welcome_screen.nim:syncLegacyWelcomeScreenIntoVM` mirrored an
## empty list into `WelcomeScreenVM` every time the "+" button opened an empty
## tab.
##
## The nearest pure module to that boundary is `frontend/index/recent_items.nim`
## (the same arrangement `page-objects-tests/reload_reconnect_vm_test.nim` uses
## for `frontend/index/bootstrap_cache.nim`): `startup.nim` is a thin adapter
## that asks it which channel carries the lists and then performs the fetch and
## the `webContents.send`.  What the tests below pin down is therefore the
## decision, plus a model of the index -> renderer handshake that shows the
## renderer's cache actually ends up populated on the `ct run` path.
##
## Spec grounding (the assertions are not a restatement of current behaviour —
## they are what these documents require):
##
##   - `codetracer-specs/GUI/Welcome-And-Sessions/Welcome-Screen.md`:
##     "The Welcome Screen ... provides quick access to recent traces, recent
##     folders, and options to start new recordings or open existing projects",
##     and "### Right Panel: Recent Traces — Lists recently opened trace
##     recordings".  One Welcome Screen, whose Recent Traces panel the spec
##     never conditions on how the process was launched.
##   - `codetracer-specs/GUI/Multi-Window-Tab-Management.md`: "The \"+\" button
##     opens a new empty tab (for loading a new trace)" and "Closing the last
##     tab shows the welcome screen".  The welcome surface is reachable from any
##     windowed session, so the data behind it has to exist in any windowed
##     session.
##
## The spec does *not* spell out "independently of the startup path" in those
## words — no document in `codetracer-specs/GUI/` discusses startup paths at
## all.  The contract asserted here is the composition of the two sentences
## above: the "+" tab shows the Welcome Screen, and the Welcome Screen lists
## recent traces.
##
## Not to be confused with `test_welcome_screen_loading`
## (`src/tests/gui/tests/views/isonim_views_test.nim`), which asserts that a
## *loading overlay* renders and is no evidence about this issue.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/welcome-screen/recent_items_startup_vm_test.nim

import std/unittest

import ../../../../frontend/index/recent_items

# ---------------------------------------------------------------------------
# A model of the index -> renderer handshake.
#
# `indexMessages` stands for `index/startup.nim`: it emits the startup messages
# that carry the recent lists for a given path.  `applyMessage` stands for the
# renderer's IPC handlers in `ui_js.nim` — deliberately keyed on the message
# names those handlers are actually registered for, so a channel whose message
# nobody handles leaves the cache empty and fails the test.
# ---------------------------------------------------------------------------

type
  RecentItemsPayload = object
    traces: seq[string]   ## recording ids, standing in for `seq[Trace]`
    folders: seq[string]  ## folder paths, standing in for `seq[RecentFolder]`

  StartupMessage = object
    id: cstring
    payload: RecentItemsPayload

  RendererCache = object
    ## The renderer-side model of `Data.recentTraces` / `Data.recentFolders`.
    recentTraces: seq[string]
    recentFolders: seq[string]

const OnDisk = RecentItemsPayload(
  traces: @["0197a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b",
            "0197a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c"],
  folders: @["/home/user/my-project", "/home/user/another-app"])

proc indexMessages(path: StartupPath): seq[StartupMessage] =
  ## What `index/startup.nim` sends on `path`, as far as the recent lists are
  ## concerned.  Mirrors the adapter: the welcome branch carries them inline in
  ## its own startup message, every other welcome-capable branch pushes them
  ## separately, and the shell UI sends nothing.
  result = @[]
  case recentItemsChannel(path)
  of ricNone:
    discard
  of ricWelcomeScreen:
    result.add(StartupMessage(id: WelcomeScreenMessage, payload: OnDisk))
  of ricRecentItems:
    result.add(StartupMessage(id: RecentItemsMessage, payload: OnDisk))

proc applyMessage(cache: var RendererCache, message: StartupMessage) =
  ## The renderer half: `ui_js.onWelcomeScreen` and `ui_js.onRecentItems` are
  ## the only two handlers that assign `data.recentTraces` /
  ## `data.recentFolders`.  Anything else is dropped on the floor, exactly as
  ## an unregistered IPC channel would be.
  if message.id == WelcomeScreenMessage or message.id == RecentItemsMessage:
    cache.recentTraces = message.payload.traces
    cache.recentFolders = message.payload.folders

proc simulateStartup(path: StartupPath): RendererCache =
  result = RendererCache()
  for message in indexMessages(path):
    result.applyMessage(message)

suite "Startup recent-items delivery (#568)":

  test "ct run is classified as the replay startup path":
    # `ct run <program>` reaches `init` with neither `edit` nor
    # `welcomeScreen` set — the branch at `startup.nim`'s
    # `if not data.startOptions.edit and not data.startOptions.welcomeScreen`.
    check startupPath(shellUi = false, withDeepReview = false,
                      edit = false, welcomeScreen = false) == spReplay
    check startupPath(shellUi = false, withDeepReview = false,
                      edit = false, welcomeScreen = true) == spWelcome
    check startupPath(shellUi = false, withDeepReview = false,
                      edit = true, welcomeScreen = false) == spEdit
    # `edit` wins over `welcomeScreen`, as in the `if`/`elif` chain.
    check startupPath(shellUi = false, withDeepReview = false,
                      edit = true, welcomeScreen = true) == spEdit
    check startupPath(shellUi = false, withDeepReview = true,
                      edit = false, welcomeScreen = false) == spDeepReview
    check startupPath(shellUi = true, withDeepReview = true,
                      edit = true, welcomeScreen = true) == spShellUi

  test "every startup path that can show the welcome surface delivers the lists":
    # The invariant #568 violated, asserted exhaustively so that adding a
    # startup path without deciding how it gets its recent lists fails here.
    for path in StartupPath:
      if path.showsWelcomeSurface:
        check path.recentItemsChannel != ricNone
      else:
        # Only the shell UI, which mounts the shell instead of the welcome
        # surface (`ui_js.onStartShellUi` -> `hideWelcomeScreenSurface()`).
        check path == spShellUi

  test "the ct run path needs its own recent-items push":
    # The welcome-screen path already carries the lists inline; every other
    # welcome-capable path has no startup message that does, so `startup.nim`
    # must send `CODETRACER::recent-items` itself.
    check spReplay.needsRecentItemsPush
    check spEdit.needsRecentItemsPush
    check spDeepReview.needsRecentItemsPush
    check not spWelcome.needsRecentItemsPush
    check not spShellUi.needsRecentItemsPush
    check spWelcome.recentItemsChannel == ricWelcomeScreen

  test "recentTraces is populated on the ct run path":
    # The reporter's Workflow 2: `ct run <program>`, then "+".  The renderer's
    # cache has to hold the recent traces at that point, because the welcome
    # surface of the new empty tab is rendered from it
    # (`ui/welcome_screen.nim:syncLegacyWelcomeScreenIntoVM` reads
    # `self.data.recentTraces`).
    let afterCtRun = simulateStartup(spReplay)
    check afterCtRun.recentTraces == OnDisk.traces
    check afterCtRun.recentFolders == OnDisk.folders

  test "recentTraces is populated on every welcome-capable startup path":
    # The reporter's Workflow 1 (welcome screen first) and Workflow 2 must end
    # in the same state; so must `ct edit` and DeepReview, which also carry a
    # session tab bar with a "+".
    for path in StartupPath:
      let cache = simulateStartup(path)
      if path.showsWelcomeSurface:
        check cache.recentTraces == OnDisk.traces
        check cache.recentFolders == OnDisk.folders
      else:
        check cache.recentTraces.len == 0
