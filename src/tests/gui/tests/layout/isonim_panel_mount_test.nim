## isonim_panel_mount_test.nim
##
## Headless tests for `src/frontend/ui/isonim_panel_mount.nim`, the guard the
## FILES, VCS and TESTS panes consult before mounting their IsoNim view.
##
## Reported: *"when I enter debug mode and then hit the Stop button, the FILES,
## VCS and TESTS panels become empty."*
##
## The panes are mounted and hold nothing. Not a fetch failure: the components
## are reused rather than rebuilt, the ViewModels keep their data, and
## `genericUiComponent` re-syncs them and calls each `tryMountIsoNimPanel` on
## the new layout. Each of those calls returned at a write-once table of
## component ids — a latch describing a container that `swapLayout` had already
## destroyed, and that nothing cleared because `layout.nim` suppresses
## `itemDestroyed` for the duration of a layout swap.
##
## THE CONTROL-DATA RUN. The pre-fix answer is carried rather than deleted:
##
##     nim c -r -d:ctIsoNimPanelIdLatch \
##       --path:src src/tests/gui/tests/layout/isonim_panel_mount_test.nim
##
## restores `isoNimPanelNeedsMount` to `not idLatchSaysMounted`, the expression
## all three panes were guarded on. Nothing in the product defines that symbol.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/layout/isonim_panel_mount_test.nim

import std/unittest

import ../../../../frontend/ui/isonim_panel_mount

suite "the latch describes a container, not a name":

  test "AFTER A MODE SWAP: the id was mounted once, this container never was":
    # THE REPORTED DEFECT. `swapLayout` destroyed the element the latch was
    # about and GoldenLayout built a fresh one carrying the same id, so:
    #
    #   * the module's table still says "id 0 is mounted"  -> true
    #   * the element now in the document carries no mark  -> false
    #
    # The pane must mount. Under the id latch it did not, and the user saw an
    # empty FILES panel after pressing Stop.
    check isoNimPanelNeedsMount(idLatchSaysMounted = true,
                                containerCarriesMark = false)

  test "a container that really does carry the view is not mounted twice":
    # The other half, and the reason this is not simply "always mount".
    # `tryMountIsoNimPanel` is called on every registration and re-registration
    # and its first act is to delete the container's children — mounting on top
    # of a live view would tear down a rendered tree and rebuild it on every
    # redraw, and would discard the DOM state the view holds.
    check not isoNimPanelNeedsMount(idLatchSaysMounted = true,
                                    containerCarriesMark = true)

  test "the id latch does not decide, in either direction":
    # Stated as the pair, because "the container decides" is the whole change
    # and a rule that still consulted the id for one of the two answers would
    # keep the defect on that side. The id is now bookkeeping; the mark is the
    # fact.
    for idLatch in [false, true]:
      check isoNimPanelNeedsMount(idLatch, containerCarriesMark = false)
      check not isoNimPanelNeedsMount(idLatch, containerCarriesMark = true)

  test "a first mount still happens":
    # The boot case, which the id latch got right and which must survive.
    check isoNimPanelNeedsMount(idLatchSaysMounted = false,
                                containerCarriesMark = false)

  test "the attribute is one name, and the three panes share it":
    # The mark has to be the same string in every pane or each pane gets a
    # private latch again, which is the shape that produced three copies of one
    # defect. Asserted literally because it is what reaches the DOM and what a
    # browser assertion reads back.
    check IsoNimPanelMountedAttr == cstring"data-ct-isonim-mounted"

suite "the single-instance panes ask the document, not their memory":
  ## `isoNimPanelMountIsLive` is the same change of subject one shape further
  ## along. State, Call Trace and Timeline never had the id-keyed table above;
  ## each kept one module-level `isoNimXMounted: bool`, set on mount and cleared
  ## at exactly one site — the pane's `initXVMWithStore`, when the stub-backed
  ## ViewModel is replaced by the real one.
  ##
  ## THE CONTROL-DATA RUN is the same symbol as above:
  ##
  ##     nim c -r -d:ctIsoNimPanelIdLatch \
  ##       --path:src src/tests/gui/tests/layout/isonim_panel_mount_test.nim
  ##
  ## restores the answer to `mountedVMIsCurrent` alone, which is exactly what
  ## the deleted boolean computed. The first test below is written so that it
  ## FAILS under that define, naming the pane state that produced a blank panel.

  test "AFTER A LAYOUT SWAP: the flag says mounted, the host is gone":
    # THE CASE THE BOOLEAN COULD NOT SEE, and the one this suite exists for.
    #
    # `layout.swapLayout` hands GoldenLayout a whole new tree. The host the
    # pane mounted into is destroyed, and `itemDestroyed` is suppressed for the
    # duration of the swap — deliberately, because that suppression is what
    # stops a mode switch throwing away Monaco buffers. So no reset runs:
    #
    #   * the ViewModel has not been replaced, so the old flag stays true
    #   * `document.contains(host)` is false — that element is not in the page
    #
    # The pane must mount. Under the boolean it did not, and the pane came back
    # blank with no error, no exception and no log.
    #
    # THIS IS THE ASSERTION THAT FAILS UNDER `-d:ctIsoNimPanelIdLatch`.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = true,
                                     hostCarriesMark = false)

  test "a live host holding the current ViewModel is not remounted":
    # The other half, and the reason this is not simply "always mount". Every
    # mount's first act is to delete the host's children, so remounting over a
    # live view tears down a rendered tree on every registration.
    check isoNimPanelMountIsLive(mountedVMIsCurrent = true,
                                 hostCarriesMark = true)

  test "a live host holding a REPLACED ViewModel is remounted":
    # The case the deleted flag's single reset site existed for: the stub
    # backend's ViewModel is swapped for the real one while the host is
    # perfectly alive. Without this half the pane would keep showing the stub's
    # rows after the real backend arrived, and deleting the flag would have
    # been a regression rather than a fix.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = false,
                                     hostCarriesMark = true)

  test "a pane that has never mounted is never live":
    # The boot case. The host carries no mark and no recorded ViewModel, so
    # both halves agree.
    check not isoNimPanelMountIsLive(mountedVMIsCurrent = false,
                                     hostCarriesMark = false)

  test "both halves decide, and neither subsumes the other":
    # Stated as the matrix because a predicate that ignored one input would
    # still pass three of the four cases above by accident. Live is exactly the
    # top-right corner.
    var liveCount = 0
    for vmCurrent in [false, true]:
      for inDocument in [false, true]:
        if isoNimPanelMountIsLive(vmCurrent, inDocument):
          inc liveCount
          check vmCurrent
          check inDocument
    check liveCount == 1

suite "a pane mounts into its own tab's host, not the first in the document":
  ## Issue (codetracer-pm) `2026-10-21-isonim-panes-stay-blank-in-every-desktop-tab-but-the-first.md`.
  ##
  ## Every tab's DOM lives in one document — tab <n> in
  ## `.session-container#session-container-<n>`, hidden or shown by
  ## `ui/session_switch.nim` — and the singleton panes keep component id 0 in
  ## every tab. So `stateComponent-0` is the id of one host PER TAB, and
  ## `getElementById` answered every tab with tab 0's. The later tab's own
  ## host was never mounted: its State, Call Trace, Event Log, Terminal, VCS,
  ## Test Results and Constraints stayed blank.
  ##
  ## `isoNimPaneHostChoice` is the rule `findIsoNimPaneHost` applies to the
  ## hosts carrying the id, in document order, each described by the tab whose
  ## container holds it (`NotInAnyTab` for a host outside every container: the
  ## auto-hide standalone host, a VS Code webview, a page with no tabs).
  ##
  ## THE CONTROL-DATA RUN:
  ##
  ##     nim c -r -d:ctIsoNimPaneHostDocumentWide \
  ##       --path:src src/tests/gui/tests/layout/isonim_panel_mount_test.nim
  ##
  ## restores the pre-fix answer — the first host in the document, whatever tab
  ## holds it — and the first two tests below fail under it.

  test "THE REPORTED DEFECT: the second tab gets its own host, not tab 0's":
    # Document order is tab 0's host, then tab 1's. Tab 1 is active.
    check isoNimPaneHostChoice([0, 1], activeTab = 1) == 1

  test "a host held only by ANOTHER tab is not this tab's: wait, do not borrow it":
    # Tab 1's container is being built and its host does not exist yet. The
    # caller must retry until it does. Taking tab 0's host here is exactly the
    # defect: that host is already mounted, so the mount declines and tab 1
    # never gets one.
    check isoNimPaneHostChoice([0], activeTab = 1) == -1
    check isoNimPaneHostChoice([0, 2], activeTab = 1) == -1

  test "the first tab still finds its own host":
    check isoNimPaneHostChoice([0, 1], activeTab = 0) == 0
    check isoNimPaneHostChoice([1, 0], activeTab = 0) == 1

  test "a host outside every tab is still found: standalone, extension, no tabs":
    # The auto-hide standalone host is appended to `document.body`, a VS Code
    # webview and a page that never created a session container have no tab
    # containers at all. Those panes are window-wide by construction.
    check isoNimPaneHostChoice([NotInAnyTab], activeTab = 0) == 0
    check isoNimPaneHostChoice([NotInAnyTab], activeTab = 3) == 0
    # The active tab's own host wins over an outside one with the same id.
    check isoNimPaneHostChoice([NotInAnyTab, 2], activeTab = 2) == 1
    # And an outside host wins over another tab's.
    check isoNimPaneHostChoice([0, NotInAnyTab], activeTab = 1) == 1

  test "no host anywhere is no host":
    check isoNimPaneHostChoice([], activeTab = 0) == -1

suite "a latch kept by a module describes one host, not every tab's":
  ## The panes that keep a module-level latch — a `bool` (Event Log,
  ## Terminal, Build, …) or a table keyed by the bare component id
  ## (Constraints, Scratchpad, Agent Activity, …) — set it when tab 0 mounts.
  ## Tab 1's host has the same id, so the latch said "mounted" for a host that
  ## never was. `isoNimPanelNeedsMountInHost` asks the host as well: the latch
  ## still forces a remount when a module clears it (a ViewModel swap, an
  ## unregister), and the mark on the element says whether THIS host carries
  ## the view.
  ##
  ## Under `-d:ctIsoNimPanelIdLatch` the answer is the latch alone, and the
  ## first test fails.

  test "THE REPORTED DEFECT: tab 0 mounted, tab 1's host is still empty":
    check isoNimPanelNeedsMountInHost(latchSaysMounted = true,
                                      hostCarriesMark = false)

  test "a host that carries the view is not mounted twice":
    check not isoNimPanelNeedsMountInHost(latchSaysMounted = true,
                                          hostCarriesMark = true)

  test "a cleared latch still forces the remount its module asked for":
    # `initXVMFromSession` / `unregister` / the auto-hide refresh clear the
    # latch precisely to have the live host rebuilt on the current ViewModel.
    check isoNimPanelNeedsMountInHost(latchSaysMounted = false,
                                      hostCarriesMark = true)
    check isoNimPanelNeedsMountInHost(latchSaysMounted = false,
                                      hostCarriesMark = false)
