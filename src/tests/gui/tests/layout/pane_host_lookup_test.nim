## pane_host_lookup_test.nim
##
## The rule `ui/pane_host_lookup.findPaneHost` applies when a pane's host is
## found by its id: the active tab's own host, else a host outside every tab,
## never another tab's.
##
##   nim c -r src/tests/gui/tests/layout/pane_host_lookup_test.nim

import std/unittest

import ../../../../frontend/ui/pane_host_lookup

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
  ## `paneHostChoice` is the rule `findPaneHost` applies to the
  ## hosts carrying the id, in document order, each described by the tab whose
  ## container holds it (`NotInAnyTab` for a host outside every container: the
  ## auto-hide standalone host, a VS Code webview, a page with no tabs).
  ##
  ## THE CONTROL-DATA RUN:
  ##
  ##     nim c -r -d:ctIsoNimPaneHostDocumentWide \
  ##       --path:src src/tests/gui/tests/layout/pane_host_lookup_test.nim
  ##
  ## restores the pre-fix answer — the first host in the document, whatever tab
  ## holds it — and the first two tests below fail under it.

  test "THE REPORTED DEFECT: the second tab gets its own host, not tab 0's":
    # Document order is tab 0's host, then tab 1's. Tab 1 is active.
    check paneHostChoice([0, 1], activeTab = 1) == 1

  test "a host held only by ANOTHER tab is not this tab's: wait, do not borrow it":
    # Tab 1's container is being built and its host does not exist yet. The
    # caller must retry until it does. Taking tab 0's host here is exactly the
    # defect: that host is already mounted, so the mount declines and tab 1
    # never gets one.
    check paneHostChoice([0], activeTab = 1) == -1
    check paneHostChoice([0, 2], activeTab = 1) == -1

  test "the first tab still finds its own host":
    check paneHostChoice([0, 1], activeTab = 0) == 0
    check paneHostChoice([1, 0], activeTab = 0) == 1

  test "a host outside every tab is still found: standalone, extension, no tabs":
    # The auto-hide standalone host is appended to `document.body`, a VS Code
    # webview and a page that never created a session container have no tab
    # containers at all. Those panes are window-wide by construction.
    check paneHostChoice([NotInAnyTab], activeTab = 0) == 0
    check paneHostChoice([NotInAnyTab], activeTab = 3) == 0
    # The active tab's own host wins over an outside one with the same id.
    check paneHostChoice([NotInAnyTab, 2], activeTab = 2) == 1
    # And an outside host wins over another tab's.
    check paneHostChoice([0, NotInAnyTab], activeTab = 1) == 1

  test "no host anywhere is no host":
    check paneHostChoice([], activeTab = 0) == -1
