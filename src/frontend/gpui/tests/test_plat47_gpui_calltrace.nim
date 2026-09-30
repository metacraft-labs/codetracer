## test_plat47_gpui_calltrace.nim — PLAT-47 B3, below the window. **GPUI's
## call trace pages as the terminal's does: scrolled to the end, the last
## call is listed, more than one section was read, and back at the top the
## first call is listed again.**
##
## On the `call_pages` recording (603 calls — more than the desktop's own
## whole-trace window), opened through the GPUI host (`openGpuiTrace`, a real
## `replay-server`), with the recording's panes loaded as the window loads
## them (`loadRecordingPanes`: the first section). Every scroll goes through
## `gpui_host.pageCalltrace` — the procedure the window's wheel calls — and
## the pane's rows are read the way the window draws them: the vocabulary
## view of the session's own `CalltraceVM` (`pane_views.calltracePaneView`).
## The wheel itself, from a real pointer device, is
## `test_plat47_gpui_window.nim`'s.
##
## Needs `REPLAY_SERVER_BIN` and the `call_pages` recording under
## `test-logs/tui-fixtures/` (`just test-tui` records it). A missing
## prerequisite fails by name.
##
## No mocks: a real recording, a real replay-server, the real ViewModel.

import std/[os, strutils, unittest]

import gpui/host/gpui_host
import view_vocabulary/pane_views
import ../../../common/view_vocabulary
import isonim/core/signals

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  PagesFixture = "test-logs/tui-fixtures/call_pages-d6745afd1e2e"
  Rows = 15
  ExpectedAssertions = 10

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

proc labels(session: HeadlessDebugSession): seq[string] =
  let pv = calltracePaneView(session.session.calltraceVM)
  for n in walk(pv.root):
    if n.kind == pkList:
      for o in n.options:
        result.add o.label.strip()

suite "PLAT-47 B3: GPUI's call trace scrolls and pages":

  test "scrolled to the end the last call is listed; back at the top, the first":
    let trace = repo / PagesFixture
    if not dirExists(trace):
      raise newException(IOError, "prerequisite missing: " & trace &
                         " (run 'just test-tui' once)")
    let session = openGpuiTrace(trace)
    let loaded = session.loadRecordingPanes()
    ck loaded.calltrace
    let total = int(session.session.store.calltrace.totalCallsCount.val)
    checkpoint("total " & $total)
    ck total == 603
    # The first section is the one the window opened with: the head.
    discard session.pageCalltrace(Rows, 0)
    ck labels(session).len == Rows
    ck "#602" notin labels(session).join("|")
    var sections = 0
    var last = -1
    for _ in 0 ..< 100:
      let page = session.pageCalltrace(Rows, 30)
      if page.loaded: inc sections
      if page.top == last: break
      last = page.top
    checkpoint("sections read " & $sections & ", top " & $last)
    ck last == total - Rows
    ck sections > 1
    let atEnd = labels(session)
    checkpoint($atEnd)
    ck atEnd.len == Rows
    ck atEnd[^1] == "leaf #602"
    # Back to the top: the head is read again.
    for _ in 0 ..< 100:
      if session.pageCalltrace(Rows, -60).top == 0: break
    let atTop = labels(session)
    checkpoint($atTop[0 ..< 3])
    ck atTop.len == Rows
    ck atTop[0].endsWith("#0")

  test "assertion count":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
