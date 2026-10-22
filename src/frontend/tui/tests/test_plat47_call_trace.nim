## test_plat47_call_trace.nim — PLAT-47 deliverables 3 and 7, Tier 1. **The
## calltrace pane shows the recording's call TRACE, the FILES pane the
## recording's tree — on a real session, through the terminal's own paint and
## through the view GPUI renders.**
##
## A real `replay-server` on the real `calc` recording (a Python recording,
## whose materialised trace carries a call trace), opened by the terminal's
## own `openTuiSession`, refreshed by its own `refresh`, painted by its own
## `shellScreen`:
##
##   * the pane lists the trace's calls — every row the session's
##     `CalltraceVM` holds, `name #index` as the desktop's `.call-text`, not
##     the one-frame call STACK the pane drew before PLAT-47 — and marks the
##     call the debugger is in (the innermost frame's call at the stack's
##     depth), at the first stop and at a later one;
##   * a collapse that hides the current call leaves NO row marked, never an
##     earlier call of the same name that has returned (codetracer#845);
##   * GPUI's calltrace view (`pane_views.calltracePaneView`, over the same
##     VM) lists the same rows;
##   * the FILES pane lists the recording's tree (`source folders`, `calc`,
##     `main.py`) on the interactive path — `refresh` fills it, which is the
##     path the tty loop takes (before PLAT-47 only `--headless` did);
##   * THE FALLBACK: a recording that provides no call trace makes the pane
##     show the call STACK under a caption that says so, in both front-ends.
##
## ## The one stand-in, and why it is not a mock
##
## The fixture corpus has no recording without a call trace (Python, Noir and
## the wide-state program all carry one). So the fallback case EMPTIES the
## store's call-trace section after a real load — no rows and a call count of
## zero, the state a recording with no trace leaves the store in — and
## everything after it is real: the session's
## own `refreshCallStackFallback` asks the real backend for the real stack
## (`stackTrace`), and the real painters draw it. Nothing answers in the
## backend's place.

import std/[options, os, strutils, unittest]

import isonim/core/signals

import headless_session
import store/[replay_data_store, types]
import viewmodels/calltrace_vm
import view_vocabulary/pane_views
import ../../../common/view_vocabulary

import ../app/runtime
import codetracer_embed   # `bkVim`, `ksFlag`
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
from ../app/views/call_trace import StackFallbackTitle, paintCallTrace,
  currentTraceIndex
import ../host/native_host
from ../host/session_driver import jumpToCall
import ../host/tui_session
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 200
  Rows = 60

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  newTuiRuntime(newTuiApp(), caps, Cols, Rows)

proc screenText(rt: TuiRuntime): string =
  rt.shellScreenOf().rows.join("\n")

proc viewLabels(n: ViewNode; acc: var seq[string]) =
  ## Every option label and text under a view node, in order.
  if n.isNil: return
  for o in n.options: acc.add o.label
  if n.text.len > 0: acc.add n.text
  for c in n.children: viewLabels(c, acc)

suite "PLAT-47: the calltrace pane lists the call trace; FILES the tree":

  let resolved = resolveFixture("calc")

  test "a real session: the trace's calls, the current call marked, FILES filled":
    require resolved.outcome == foRecorded
    let rt = newRuntime()
    let session = openTuiSession(resolved.tracePath, viewportHeight = Rows - 6)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    let lines = session.session.getCalltraceLines()
    ck lines.len >= 20
    # The pane's model IS the VM's rows, as the desktop's `.call-text`.
    ck rt.app.callTrace.rows.len == lines.len
    for i, l in lines:
      ck rt.app.callTrace.rows[i].index == l.index
      ck rt.app.callTrace.rows[i].name ==
         (if l.displayName.len > 0: l.displayName else: l.name)
    let screen = screenText(rt)
    # PLAT-49: the pane's tab names it; there is no title row to count in.
    ck screen.contains(" Call Trace ")
    ck not screen.contains("CALL TRACE ")
    # The calls are found by WHAT they are, not by their number: the number
    # depends on the frames the recorder wraps the program in (the Python
    # recorder's `<toplevel>` root, which carries the exit code, then the
    # `<__main__>` module frame), so `main` is the first call named `main`
    # and `evaluate` the first named `evaluate`, and each is drawn with ITS
    # trace index.
    proc firstNamed(name: string): int =
      result = -1
      for l in lines:
        if l.name == name: return l.index
    let mainAt = firstNamed("main")
    let evaluateAt = firstNamed("evaluate")
    ck mainAt >= 0
    ck evaluateAt > mainAt
    ck screen.contains("main #" & $mainAt)
    ck screen.contains("evaluate #" & $evaluateAt)
    # At the first stop the debugger is at the program's entry: the call
    # that encloses `main` (the module's frame), which the trace's root — a
    # frame the recorder opens before the program runs — encloses in turn.
    ck rt.app.callTrace.current >= 0
    ck rt.app.callTrace.current == mainAt - 1
    ck lines[rt.app.callTrace.current].depth == lines[mainAt].depth - 1
    # FILES: the recording's tree, on the interactive path.
    ck screen.contains("source folders")
    ck screen.contains("main.py")
    # GPUI's view over the same VM lists the same calls — the ones the pane
    # shows (`visibleLines`: the viewport the terminal reported, HSF-V2),
    # each held row it shows once.
    let pv = calltracePaneView(session.calltrace)
    var labels: seq[string] = @[]
    viewLabels(pv.root, labels)
    ck labels.len > 0
    ck labels.len >= session.calltrace.visibleLines.val.len
    # A row is "callee #index(args) => return" (PLAT-49 part B); its head
    # names the call.
    let head = labels[0].strip().split('(')[0]
    ck head == "<__main__> #0" or head == lines[0].name & " #0"
    ck pv.report.len == 0

  test "at a later stop the current call is the one the debugger is in":
    require resolved.outcome == foRecorded
    let rt = newRuntime()
    let session = openTuiSession(resolved.tracePath, viewportHeight = Rows - 6)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    discard session.seekToStartupTick(rt, 25)
    let cur = rt.app.callTrace.current
    checkpoint("current " & $cur & " " &
      (if cur >= 0: $rt.app.callTrace.rows[cur] else: "") & " stack " &
      $rt.app.callStack.frames.len & " tick " & $rt.app.tick)
    for f in rt.app.callStack.frames: checkpoint("frame " & f.name)
    ck cur >= 0
    if cur >= 0:
      # `evaluate`'s loop: the innermost frame is `evaluate`, and its depth
      # in the trace is its depth in the call stack — one less than the
      # stack's frame count (`<toplevel>` > `<__main__>` > `main` >
      # `evaluate` with the current Python recorder), read from the stack
      # rather than from a number that depends on the recorder's wrapping
      # frames.
      ck rt.app.callTrace.rows[cur].name == "evaluate"
      ck rt.app.callStack.frames.len >= 3
      ck rt.app.callStack.frames[0].name == "evaluate"
      ck rt.app.callStack.frames[1].name == "main"
      ck rt.app.callTrace.rows[cur].depth == rt.app.callStack.frames.len - 1

  test "collapsing the current call's parent marks no call that returned (#845)":
    # codetracer#845: at a stop inside a later `apply_op`, collapsing the
    # `evaluate` that contains it hid the current call, and the pane then
    # marked an EARLIER `apply_op` — same name, same depth, already
    # returned. `calc` evaluates its expressions each in its own `evaluate`,
    # each with one or more `apply_op`s, so the trace has that shape.
    require resolved.outcome == foRecorded
    let rt = newRuntime()
    let session = openTuiSession(resolved.tracePath, viewportHeight = Rows - 6)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    let store = session.session.session.store
    let vm = session.session.session.calltraceVM
    # Found by what the calls are, not by number. The parent: the first
    # `evaluate` after an `apply_op`. The target: the first `apply_op`
    # inside it. The namesake: the last `apply_op` before the parent, which
    # returned before the parent was entered.
    var parent, target, namesake = -1'i64
    var targetDepth, namesakeDepth = -1
    var targetKey = ""
    for l in session.session.getCalltraceLines():
      if parent < 0:
        if l.name == "evaluate" and namesake >= 0:
          parent = l.index
          targetDepth = l.depth + 1
        elif l.name == "apply_op":
          namesake = l.index
          namesakeDepth = l.depth
      elif target < 0 and l.name == "apply_op" and l.depth == targetDepth:
        target = l.index
        targetKey = l.callKey
    checkpoint("parent " & $parent & ", target " & $target & ", namesake " &
               $namesake)
    require parent >= 0 and target > parent and namesake >= 0
    ck namesakeDepth == targetDepth   # the instrument: a true namesake
    ck targetKey.len > 0

    # ---- step into the later call, as a click on its row does ------------
    ck session.session.jumpToCall(target) == ""
    # The terminal's own path after a click moved the debugger: `refresh`,
    # which reads no section when the rows the pane shows are already held —
    # so the collapse below is the FIRST calltrace request at the new stop.
    # The engine must shape its listing for this stop before applying that
    # collapse, or the read the toggle makes after it re-expands every call
    # and the collapse is lost (codetracer-pm issue 2026-10-21, "a call-trace
    # collapse made after a move is undone by the next section read"). The
    # `parentCollapsed` instrument below fails if it is.
    session.refresh(rt)
    session.session.selectCurrentCall()
    ck rt.app.callStack.frames.len > 0
    ck rt.app.callStack.frames[0].name == "apply_op"
    # The control: expanded, the current call is the target, marked and
    # selected.
    ck rt.app.callTrace.currentTraceIndex == target.int
    ck vm.selectedEntry.val == some(target)
    let selectedBefore = vm.selectedEntry.val

    # ---- collapse its parent, as a click on the row's toggle does --------
    session.toggleCallChildren(rt, parent)
    checkpoint("notification: " & rt.app.notification)
    var targetListed, namesakeListed, parentCollapsed = false
    for l in store.calltrace.lines.val:
      if l.callKey == targetKey: targetListed = true
      if l.index == namesake and l.name == "apply_op": namesakeListed = true
      if l.index == parent and not l.isExpanded: parentCollapsed = true
    # The instrument: the parent is collapsed, so the current call is not
    # listed; its returned namesake still is.
    ck parentCollapsed
    ck not targetListed
    ck namesakeListed
    checkpoint("current row after the collapse: " & $rt.app.callTrace.current)
    # THE DEFECT: the returned namesake was the current row. No row is now.
    ck rt.app.callTrace.current == -1
    ck rt.app.callTrace.currentTraceIndex != namesake.int
    # And the painted pane carries no current-call ground on any row.
    var g = newStyledGrid(Cols, Rows)
    discard paintCallTrace(g, CellArea(col: 0, row: 0, width: Cols,
                                       height: Rows), rt.app.callTrace)
    var marked = 0
    for r in 0 ..< Rows:
      for sp in g.rowSpans(r):
        if sp.text.strip.len > 0 and sp.style.surface == srSurfaceActiveRow:
          inc marked
          break
    ck marked == 0
    # The collapse moved no selection.
    ck vm.selectedEntry.val == selectedBefore
    # GPUI selects by the same rule (`selectCurrentCall`): over the
    # collapsed listing it selects nothing rather than the returned
    # namesake.
    session.session.selectCurrentCall()
    ck vm.selectedEntry.val != some(namesake)
    ck vm.selectedEntry.val.isNone

  test "no call trace: the pane shows the call stack and says so, in both front-ends":
    require resolved.outcome == foRecorded
    let rt = newRuntime()
    let session = openTuiSession(resolved.tracePath, viewportHeight = Rows - 6)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    # THE STAND-IN (see the header): the store as a recording with no trace
    # leaves it — no rows AND no calls to page to (the terminal pages the
    # trace since PLAT-47, so a store with rows gone but a call count left
    # would, rightly, be read again).
    let store = session.session.session.store
    store.updateCalltraceSection(newSeq[CallLine](), 0, 0)
    session.refresh(rt)
    discard session.seekToStartupTick(rt, 25)
    ck rt.app.callTrace.isEmpty
    ck rt.app.callTraceLoaded
    let screen = screenText(rt)
    ck screen.contains(StackFallbackTitle)
    ck not screen.contains("CALL TRACE ")
    # The stack's frames are there: `evaluate` in `main` in `<__main__>`.
    ck screen.contains("evaluate")
    # GPUI's view: the same fallback, from the REAL backend's stack.
    # The SESSION's calltrace VM — the one GPUI's leaf renders
    # (`HeadlessDebugSession.session.calltraceVM`).
    let vm = session.session.session.calltraceVM
    refreshCallStackFallback(session.session)
    let stack = vm.fallbackStack.val
    checkpoint("fallback stack " & $stack)
    ck stack.len >= 3
    ck stack[0] == "evaluate"
    let pv = calltracePaneView(vm)
    ck pv.report == CalltraceFallbackCaption
    var labels: seq[string] = @[]
    viewLabels(pv.root, labels)
    ck labels.len >= 3
    ck "#0 evaluate" in labels

suite "PLAT-47: the call trace pages as it scrolls, as the desktop's does":

  # A recording with more calls than any one section: `call_pages` (601
  # calls below the module, more than the desktop's own whole-trace window).
  # Declared here rather than in the shared corpus, because only this suite
  # reads it; the provider records it on first use like every fixture.
  let resolved = resolveFixture(FixtureSpec(
    name: "call_pages",
    program: "test-programs/call_pages/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: ""))

  test "a trace longer than any section: scrolling loads the rest":
    require resolved.outcome == foRecorded
    let rt = newRuntime()
    let session = openTuiSession(resolved.tracePath, viewportHeight = Rows - 6)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    let store = session.session.session.store
    let total = int(store.calltrace.totalCallsCount.val)
    checkpoint("total " & $total & ", first section " &
               $store.calltrace.lines.val.len)
    # 1 + 2 * 300 calls under the recorder's own root frames.
    ck total >= 601
    # The store holds a SECTION, not the trace.
    ck store.calltrace.lines.val.len < total
    ck rt.app.callTrace.total == total
    ck rt.focus.focusPaneKind(paneCalltrace)
    let body = rt.paneBodyRows(paneCalltrace)
    ck body > 5

    # ---- scroll to the end with the page key, as a reader would ----
    # Until the pane stops moving: its last row is then the trace's last
    # call, whatever the backend counts there (a trace read to its end lists
    # the recorder's `<end of program>` too, one call more than the first
    # section's count).
    var now = 1_000'i64
    var pages = 0
    var sections: seq[int64] = @[store.calltrace.startLineIndex.val]
    var lastTop = -1
    while pages < 400:
      # PageDown: the list's `list.focus-page-down` (CUA; §4.2's `Ctrl+d`
      # under the Vim base).
      let outcome = rt.handleToken("\e[6~", now)
      ck outcome.pagesCallTrace
      session.applyOutcome(rt, outcome)
      now += 10
      inc pages
      let start = store.calltrace.startLineIndex.val
      if start != sections[^1]:
        sections.add start
      let top = rt.app.callTrace.visibleTop(body)
      if top == lastTop:
        break
      lastTop = top
    let screen = screenText(rt)
    let finalTotal = rt.app.callTrace.total
    checkpoint("pages " & $pages & ", sections loaded from " & $sections &
               ", total " & $finalTotal)
    ck finalTotal >= total
    # The model counts every call a section can reach: the backend's count,
    # or further when a section lists a row past it (the `<end of program>`).
    ck finalTotal == max(int(store.calltrace.totalCallsCount.val),
                         int(store.calltrace.startLineIndex.val) +
                           store.calltrace.lines.val.len)
    # The last round's call is on screen, and so is the trace's last call.
    ck screen.contains("leaf #602")
    ck screen.contains(" #" & $(finalTotal - 1))
    ck rt.app.callTrace.visibleTop(body) + body == finalTotal
    # More than one section was read, each one AFTER the first: the pane asked
    # for the rows it showed, rather than holding the whole trace.
    ck sections.len >= 2
    ck sections[^1] > 0
    ck store.calltrace.lines.val.len < finalTotal
    # No row is drawn as loading once its section has arrived.
    var loadingRows = 0
    for line in screen.splitLines:
      if line.contains("│" & CallTraceLoadingText): inc loadingRows
    ck loadingRows == 0
    # The model counts the whole trace (no title row shows the count since
    # PLAT-49; the strip names the pane).
    ck rt.app.callTrace.total == finalTotal

    # ---- the wheel over the pane's body scrolls it back ----------------
    discard rt.enableLayoutBinding()
    ck rt.focus.focusPaneKind(paneCalltrace)
    let geometry = rt.layoutGeometry()
    var at = (-1, -1)
    for r in geometry.projection.regions:
      if r.pane == paneCalltrace:
        at = (r.area.row + r.area.height div 2, r.area.col + 2)
    ck at[0] >= 0
    let before = rt.app.callTrace.visibleTop(body)
    let wheelUp = "\x1b[<64;" & $(at[1] + 1) & ";" & $(at[0] + 1) & "M"
    let o = rt.handleToken(wheelUp, now)
    ck o.pagesCallTrace
    session.applyOutcome(rt, o)
    ck rt.app.callTrace.visibleTop(body) == before - CallTraceWheelRows

    # ---- and back to the top: the first section is read again -----------
    var ups = 0
    while not screenText(rt).contains("main #2") and ups < 400:
      now += 10
      let outcome = rt.handleToken("\e[5~", now)      # PageUp
      session.applyOutcome(rt, outcome)
      inc ups
    ck screenText(rt).contains("main #2")
    ck store.calltrace.startLineIndex.val == 0

    # ---- `.` follows the current call again ------------------------------
    # (§3.3.5's `.` is the Vim base's; CUA's is the read-only editor's
    # `editor.center-on-pointer`, CUA-Keymap §4.)
    rt.selectBase(bkVim, ksFlag)
    let dot = rt.handleToken(".", now + 10)
    session.applyOutcome(rt, dot)
    ck not rt.app.callTraceScrolled
    ck rt.app.callTrace.follow

echo "CHECKS: ", CHECKS
