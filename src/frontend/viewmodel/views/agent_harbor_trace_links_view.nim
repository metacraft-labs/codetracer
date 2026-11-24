## views/agent_harbor_trace_links_view.nim
##
## The links in an agent's message and the test-run summary item of the
## Agent Harbor session timeline, over the timeline's link parts
## (nim-agents-isonim-viewmodels `session_timeline_vm`, `LinePart.links`)
## and the pane's `TraceOpenerVM`.
##
## **A part with links.** `renderLinkedPart` draws a line part's text as its
## pieces (nim-agents' `trace_links.LinkPart`), which join back to the part's
## text exactly, so a line with links reads, and copies, as the same line
## without them:
##
## - a trace Agent Harbor holds (`agent-harbor://trace/<id>`, or its https
##   form on the session's server) is a link in the palette's `link` role,
##   drawn as a short label (`trace 3f9b2c1e`, `trace 8d7e6f5a on <host>`:
##   the words module's `traceLinkLabel`) with the URL as written in its
##   tooltip, followed on the same line by its button: `Load trace`
##   (outlined, small), `Connecting to the replay…` while it connects (no
##   press), `Show trace` once it replays; `Replay unavailable: <reason>` in
##   the error role with `Retry` (none for a trace that is gone); and
##   `Download`, the same small secondary button, then `Downloading…`,
##   `Saved <name>` or `Download failed: <reason>`. The button's tooltip says
##   what it opens and where (the Test Results pane's placement sentence);
## - a recording on this machine (`codetracer://recordings/<test>`) is a link
##   labelled `recording <test>`, its URL in its tooltip, followed by `Open
##   recording`: no replay, no download, no action sent;
## - text that looks like a trace or recording link and is not one stays
##   plain text, its tooltip `Not a trace link: <why>`;
## - a plain https link is a link that asks the host to open it;
## - a file the message names is a link that asks the host to open it (one
##   target), a link that opens a small menu of its targets (several), or
##   plain text with its tooltip (missing: `File not found in this session`;
##   a directory: nothing to open). A long path is cut in its middle.
##
## Every link takes keyboard focus and is named by its target (`Trace
## <id>`, `Recording <test>`, `File <path>`, `Link <url>`: the timeline's
## `linkName`); nothing is added to the line's text or its copy. A trace
## link's label is drawn only: the line's `text` and `copyText` (what its
## Copy copies) keep the message's URL, and the link carries it as
## `data-ah-url`.
##
## **The test-run summary item** (`renderTestRunItem`): a cardless timeline
## line, `Ran 6 tests on 2 platforms: 4 passed, 1 failed, 1 skipped` in its
## role, with `Open in Test Results`; opened, one line per test (the Test
## Results pane's mark of its roll-up, its name, one mark per platform),
## and a test opened to each platform's failure and its trace's button, or
## `this test ran, but no recording was kept`.
##
## **The surface.** `renderAgentHarborTraceLinks` frames a session's
## timeline as the Agent Activity panel with its lines drawn through the
## two parts above: the trace-link stories' surface. The session activity
## view (`isonim_agent_harbor_session_activity_view.nim`) draws an agent's
## message with links through `renderLinkedPart` when its host hands it one
## (its `linkPart`); it draws a test-run item as its own lines, so
## `renderTestRunItem` is this surface's only.
##
## **Presses** (Input-Routing-And-Keymaps.md §5.1): every element a press
## acts on carries its operation (`trace-links.*`) and the procedure that
## performs it (`element_operations.bindOperation`); the view holds no press
## handler. The opener's presses go through its viewmodel to the data
## source's `submitAction` and nothing else; a file, a web link and `Open in
## Test Results` are the host's requests (`TraceLinkHostRequests`).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import ./ah_cut_text

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents/agent_harbor/[test_runs, trace_links]
import ./agent_harbor_tests_words
import ./agent_harbor_tests_rows
import ./isonim_agent_harbor_session_activity_view
import ../input/element_operations
from ../keymap/scope_path import SessionActivityScope

export signals, computation, components, agent_harbor_tests_words,
  isonim_agent_harbor_session_activity_view

const
  AgentHarborTraceLinksClass* = "component-container agent-harbor-activity agent-harbor-trace-links"
  TestRunItemPrefix* = "test-run:"
    ## A test-run item's id is its run's id after this
    ## (`activity_groups.applyTestRun`).

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

proc press[R, N](r: R; node: N; operation: string; run: proc()) =
  let act = run
  r.bindOperation(node, operation, proc(p: PressInfo) = act())

proc setFlag[R, N](r: R; node: N; name: string; on: bool) =
  mixin setAttribute
  if on: r.setAttribute(node, name, name)

# ---------------------------------------------------------------------------
# A trace and its button
# ---------------------------------------------------------------------------

proc renderTraceActions*[R, N](r: R; reference: TraceReference;
                               ctx: AgentHarborTraceLinksContext;
                               testId = ""; platform = ""): N =
  ## A trace's button and what follows it: its replay's state, Retry, and
  ## (a trace Agent Harbor holds) Download and its state. Read from the
  ## pane's opener, so every place that names the trace shows one state.
  let opener = ctx.opener
  var button, after: N
  let label = opener.buttonText(reference)
  let enabled = opener.canPress(reference)
  result = ui(r):
    span(class = "ah-trace-actions", `data-ah-trace` = reference.id,
         `data-ah-trace-kind` = $reference.kind,
         `data-ah-replay` = $opener.stateOf(reference).phase):
      button(ref = button, class = "ct-button-sm-secondary ah-trace-button",
             title = opener.titleText(reference), `data-ah-control` = label):
        text label
      span(ref = after, class = "ah-trace-after")
  r.setFlag(button, "disabled", not enabled)
  if enabled:
    r.press(button, TraceLoadOperation,
            proc() = opener.load(reference, testId, platform))
  let error = opener.errorText(reference)
  if error.len > 0:
    let e = ui(r):
      span(class = "ah-trace-error ah-role-error", title = error):
        text error
    r.appendRendered(after, e)
    if opener.canRetry(reference):
      var retry: N
      let b = ui(r):
        button(ref = retry, class = "ct-button-sm-secondary ah-trace-button ah-trace-retry",
               title = "Try the replay again"):
          text RetryText
      r.press(retry, TraceLoadOperation, proc() = opener.retry(reference))
      r.appendRendered(after, b)
  if reference.kind == trkAgentHarbor:
    let status = opener.downloadStatus(reference)
    let phase = opener.downloadOf(reference).phase
    if phase in {dpIdle, dpFailed}:
      var d: N
      let b = ui(r):
        button(ref = d, class = "ct-button-sm-secondary ah-trace-button ah-trace-download",
               title = "Download the trace to open it on this machine"):
          text DownloadText
      r.press(d, TraceDownloadOperation, proc() = opener.download(reference))
      r.appendRendered(after, b)
    if status.len > 0:
      let role = case phase
        of dpFailed: "error"
        of dpSaved: "success"
        else: "quiet"
      let s = ui(r):
        span(class = "ah-trace-download-status ah-role-" & role, title = status,
             `data-ah-download` = $phase):
          text status
      r.appendRendered(after, s)

proc renderTraceLink[R, N](r: R; link: LinkPart; ctx: AgentHarborTraceLinksContext): N =
  ## A trace link and its actions, kept together on the prose's line.
  var anchor: N
  let reference = link.reference
  result = ui(r):
    span(class = "ah-trace"):
      span(ref = anchor, class = "ah-link ah-trace-link", role = "link", tabindex = "0",
           `aria-label` = linkName(link), title = traceLinkTitle(link),
           `data-ah-link` = $reference.kind, `data-ah-url` = link.text):
        text traceLinkLabel(link)
  let opener = ctx.opener
  if opener.canPress(reference):
    r.press(anchor, TraceLoadOperation, proc() = opener.load(reference))
  r.appendRendered(result, renderTraceActions[R, N](r, reference, ctx))

proc filePress(ctx: AgentHarborTraceLinksContext; target: FileTarget): proc() =
  ## A target's press, as a proc of its own so each closure owns its target
  ## (https://nim-lang.org/docs/manual.html#closures-creating-closures-in-loops).
  let requests = ctx.requests
  result = proc() = requests.recordFile(target)

proc renderFileLink[R, N](r: R; link: LinkPart; ctx: AgentHarborTraceLinksContext): N =
  ## A file the message names (L12's four cases).
  mixin clearChildren, setAttribute
  let state = fileLinkState(link.targets)
  let title = fileLinkTitle(link.targets)
  case state
  of flMissing, flDirectory:
    result = ui(r):
      span(`data-ah-cut` = CutPathValue, class = "ah-link-none ah-mono", title = title,
           `data-ah-link` = "file", `data-ah-file` = $state):
        text link.text
  of flUnique:
    var target: FileTarget
    for t in link.targets:
      if t.exists: target = t
    result = ui(r):
      span(`data-ah-cut` = CutPathValue, class = "ah-link ah-file-link-target ah-mono",
           role = "link", tabindex = "0", title = title, `aria-label` = linkName(link),
           `data-ah-link` = "file", `data-ah-file` = $state):
        text link.text
    r.press(result, TraceOpenFileOperation, filePress(ctx, target))
  of flAmbiguous:
    let open = createSignal(ctx.fileMenuOpen.len > 0 and ctx.fileMenuOpen == link.text)
    var anchor, menuHost: N
    result = ui(r):
      span(class = "ah-file-menu-anchor"):
        span(ref = anchor, `data-ah-cut` = CutPathValue,
             class = "ah-link ah-file-link-target ah-mono", role = "link", tabindex = "0",
             title = title, `aria-label` = linkName(link), `aria-haspopup` = "menu",
             `data-ah-link` = "file", `data-ah-file` = $state):
          text link.text
        span(ref = menuHost, class = "ah-dropdown-menu-host ah-file-menu-host")
    r.press(anchor, TraceFileMenuOperation, proc() = open.val = not open.val)
    let targets = link.targets
    let c = ctx
    createRenderEffect proc() =
      let isOpen = open.val
      r.clearChildren(menuHost)
      r.setAttribute(anchor, "aria-expanded", if isOpen: "true" else: "false")
      if not isOpen: return
      var menu: N
      let m = ui(r):
        tdiv(ref = menu, class = "ah-dropdown-menu ah-file-menu", role = "menu",
             `data-ah-file-menu` = "open")
      r.appendRendered(menuHost, m)
      for tItem in targets:
        let t = tItem
        if not t.exists: continue
        let shown = t.path & (if t.line > 0: ":" & $t.line else: "")
        let row = ui(r):
          tdiv(class = "ah-dropdown-item ct-menu-item ah-mono", role = "menuitem",
               title = "Open " & shown, `data-ah-file-target` = t.path):
            span(class = "ct-menu-item-label"):
              text shown
        let run = filePress(c, t)
        r.press(row, TraceOpenFileOperation, proc() =
          open.val = false
          run())
        r.appendRendered(menu, row)

proc renderText[R](r: R; t: string): auto =
  ui(r):
    span(class = "ah-link-text"):
      text t

proc renderLinkedPart*[R, N](r: R; part: LinePart; ctx: AgentHarborTraceLinksContext): N =
  ## A line part as its pieces: plain text, and each link with what follows
  ## it. A part without links is its text, in its role.
  result = ui(r):
    span(class = "ah-activity-part " & roleClass(part.role) & " ah-linked-part")
  if part.links.len == 0:
    r.appendRendered(result, renderText(r, part.text))
    return
  for linkItem in part.links:
    let link = linkItem
    case link.kind
    of lpText:
      if link.reason.len > 0:
        let refused = ui(r):
          span(class = "ah-link-refused", title = link.reason, `data-ah-link` = "refused"):
            text link.text
        r.appendRendered(result, refused)
      else:
        r.appendRendered(result, renderText(r, link.text))
    of lpTrace:
      r.appendRendered(result, renderTraceLink[R, N](r, link, ctx))
    of lpUrl:
      let url = link.text
      let requests = ctx.requests
      let u = ui(r):
        span(class = "ah-link ah-url-link", role = "link", tabindex = "0",
             title = "Open " & url & " in the browser", `aria-label` = linkName(link),
             `data-ah-link` = "url"):
          text url
      r.press(u, TraceOpenUrlOperation, proc() = requests.recordUrl(url))
      r.appendRendered(result, u)
    of lpFile:
      r.appendRendered(result, renderFileLink[R, N](r, link, ctx))

# ---------------------------------------------------------------------------
# The test-run summary item
# ---------------------------------------------------------------------------

proc platformLabelOf(run: PlatformRun): string =
  if run.platform.label.len > 0: run.platform.label else: platformLabel(run.platform.features)

proc runMark(state: TestRunState): CellStatus =
  ## The run's own mark: running while a platform runs, else the worst of
  ## its tests (`rollupOf`'s order).
  if state.isActive: return tsRunning
  var seen: set[CellStatus]
  for t in state.order: seen.incl state.rollupOf(t)
  for s in [tsErrored, tsFailed, tsCancelled, tsPassed, tsSkipped]:
    if s in seen: return s
  tsNotRun

proc renderRunTest[R, N](r: R; state: TestRunState; testId: string; open: bool;
                         toggle: proc(); ctx: AgentHarborTraceLinksContext;
                         serverOrigin: string): N =
  ## One test of a summary: its mark, its name and one mark per platform;
  ## opened, each platform's failure and its trace's button.
  var head, marks, detail: N
  let rollup = state.rollupOf(testId)
  result = ui(r):
    tdiv(class = "ah-tr-test" & (if open: " ah-tr-test-open" else: ""),
         `data-ah-test` = testId, `data-ah-status` = $rollup):
      tdiv(ref = head, class = "ah-tr-test-head " & rowClass(rollup),
           `aria-expanded` = (if open: "true" else: "false")):
        span(class = "ah-fold", `aria-hidden` = "true"):
          text (if open: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
        span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
          text cellMark(rollup)
        span(`data-ah-cut` = "line", class = "ah-tr-test-name", title = testId):
          text testDisplayName(testId)
        span(ref = marks, class = "ah-tr-marks")
      tdiv(ref = detail, class = "ah-tr-test-detail")
  r.press(head, TraceToggleTestOperation, toggle)
  for pItem in state.platformRuns:
    let p = pItem
    let key = platformKey(p.platform)
    if not state.hasCell(key, testId): continue
    let c = state.cell(key, testId)
    let m = ui(r):
      span(class = cellClass(c), title = platformLabelOf(p) & ": " & statusWord(c.status),
           `data-ah-platform` = key):
        span(class = "ah-tests-cell-mark", `aria-hidden` = "true"):
          text cellMark(c.status)
        span(class = "ah-tr-mark-platform"):
          text platformLabelOf(p)
    r.appendRendered(marks, m)
  if not open: return
  for pItem in state.platformRuns:
    let p = pItem
    let key = platformKey(p.platform)
    if not state.hasCell(key, testId): continue
    let c = state.cell(key, testId)
    var line: N
    let l = ui(r):
      tdiv(ref = line, class = "ah-tr-platform " & rowClass(c.status),
           `data-ah-platform` = key):
        span(class = "ah-tr-platform-label"):
          text platformLabelOf(p)
        span(class = "test-results-mark ah-tests-mark", `aria-hidden` = "true"):
          text cellMark(c.status)
        span(class = "ah-role-" & statusRole(c.status)):
          text statusWord(c.status)
    if c.failure.len > 0:
      let f = ui(r):
        span(class = "ah-tr-failure ah-role-error", title = c.failure):
          text c.failure
      r.appendRendered(line, f)
    case c.recording
    of recRecorded:
      let reference = traceReferenceOf(c.trace, serverOrigin)
      if reference.id.len > 0:
        r.appendRendered(line, renderTraceActions[R, N](r, reference, ctx, testId, key))
    of recDiscarded:
      let gone = ui(r):
        span(class = "ah-tests-not-kept ah-role-quiet"):
          text RecordingDiscardedText
      r.appendRendered(line, gone)
    of recRecording:
      let rec = ui(r):
        span(class = "ah-role-info"):
          text RecordingWord
      r.appendRendered(line, rec)
    of recNone: discard
    r.appendRendered(detail, l)

proc testPress(open: Signal[seq[string]]; testId: string): proc() =
  ## A test line's press, as a proc of its own so each closure owns its id.
  result = proc() =
    var ids = open.val
    let at = ids.find(testId)
    if at >= 0: ids.delete(at) else: ids.add testId
    open.val = ids

proc renderTestRunItem*[R, N](r: R; timeline: SessionTimelineVM; line: TimelineLine;
                              state: TestRunState; ctx: AgentHarborTraceLinksContext;
                              openTests: Signal[seq[string]]): N =
  ## The test-run summary item: its line (which opens it) and, opened, its
  ## tests. `openTests` holds the tests opened under it.
  var head, tests: N
  let id = line.id
  let mark = runMark(state)
  let role = if line.parts.len > 0: line.parts[0].role else: "body"
  result = ui(r):
    tdiv(class = lineClass(line) & " ah-tr-item", `data-ah-test-run` = state.id):
      span(class = "ah-activity-glyph"):
        span(class = "ah-activity-mark"):
          text (if line.expanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
      tdiv(class = "ah-activity-text ah-tr-text"):
        tdiv(ref = head, class = "ah-tr-head"):
          span(class = "test-results-mark ah-tests-mark ah-role-" & statusRole(mark),
               `aria-hidden` = "true"):
            text cellMark(mark)
          span(`data-ah-cut` = "line", class = "ah-activity-part " & roleClass(role) &
                 " ah-tr-summary", title = runLineTitle(state)):
            text line.text
        tdiv(ref = tests, class = "ah-tr-tests")
  r.tagFacts(result, line.lineFacts)
  let t = timeline
  r.press(head, TraceToggleRunOperation, proc() =
    t.setFocus(id)
    t.toggle(id))
  let requests = ctx.requests
  let runId = state.id
  var go: N
  let link = ui(r):
    span(ref = go, class = "ah-link ah-tr-open-tests", role = "link", tabindex = "0",
         title = "Show this run in the Test Results panel"):
      text OpenInTestResultsLabel
  r.press(go, TraceOpenInTestsOperation, proc() = requests.recordTests(runId))
  r.appendRendered(head, link)
  if not line.expanded: return
  let opened = openTests.val
  for testId in state.order:
    r.appendRendered(tests, renderRunTest[R, N](r, state, testId, testId in opened,
      testPress(openTests, testId), ctx, timeline.serverOrigin))

# ---------------------------------------------------------------------------
# The trace-link stories' surface
# ---------------------------------------------------------------------------

proc renderPlainLine[R, N](r: R; line: TimelineLine; ctx: AgentHarborTraceLinksContext): N =
  ## A timeline line as the activity view lays it out (its classes and
  ## facts), its parts drawn by `renderLinkedPart`.
  mixin setAttribute
  var glyph, body: N
  result = ui(r):
    tdiv(class = lineClass(line)):
      span(ref = glyph, class = "ah-activity-glyph")
      tdiv(ref = body, class = "ah-activity-text")
  r.tagFacts(result, line.lineFacts)
  r.setAttribute(result, "style", "--ah-indent: " & $line.indent)
  let mark = if line.glyph.len > 0: line.glyph
             elif line.kind == tlkTurn: turnGlyph()
             else: ""
  if mark.len > 0:
    let g = ui(r):
      span(class = (if line.glyph.len > 0: "ah-activity-mark" else: "ah-activity-turn-mark")):
        text mark
    r.appendRendered(glyph, g)
  for i, part in line.parts:
    if i > 0:
      let gap = ui(r):
        span(class = "ah-activity-part"):
          text " "
      r.appendRendered(body, gap)
    let drawn = renderLinkedPart[R, N](r, part, ctx)
    if not line.isProse and part.links.len == 0:
      # A one-line line is cut by the views' one rule, as the activity
      # view cuts it (`data-ah-cut`).
      r.setAttribute(drawn, "data-ah-cut", "line")
      r.setAttribute(drawn, "title", part.text)
    r.appendRendered(body, drawn)

proc runOf(timeline: SessionTimelineVM; line: TimelineLine): TestRunState =
  if line.id.startsWith(TestRunItemPrefix):
    let id = line.id[TestRunItemPrefix.len .. ^1]
    for run in timeline.testRunsOf:
      if run.id == id: return run
  TestRunState()

proc renderAgentHarborTraceLinks*[R, N](r: R; timeline: SessionTimelineVM;
                                        ctx: AgentHarborTraceLinksContext): N =
  ## A session's timeline framed as the Agent Activity panel, its lines'
  ## links and its test runs drawn by this view: the trace-link stories'
  ## surface.
  mixin clearChildren
  var body: N
  let openTests = createSignal(ctx.openTests)
  let panel = ui(r):
    tdiv(class = AgentHarborTraceLinksClass, `data-ct-pane` = SessionActivityScope):
      tdiv(ref = body, class = "ah-activity-body")
  createRenderEffect proc() =
    discard ctx.opener.revision.val
    r.clearChildren(body)
    let head = ui(r):
      tdiv(class = "ah-activity-head"):
        span(`data-ah-cut` = "line", class = "ah-activity-status",
             `data-ah-status-label` = timeline.statusLabel):
          text timeline.statusLabel
    r.appendRendered(body, head)
    case timeline.state.val
    of asIdle, asLoading:
      let n = ui(r):
        tdiv(class = "empty-overlay ah-activity-notice", `data-ah-notice` = "loading"):
          text LoadingNotice
      r.appendRendered(body, n)
      return
    of asError:
      let n = ui(r):
        tdiv(class = "ah-activity-error", `data-ah-notice` = "error"):
          text timeline.error.val
      r.appendRendered(body, n)
      return
    of asReady: discard
    var list: N
    let listNode = ui(r):
      tdiv(ref = list, class = "ah-activity-lines", tabindex = "0")
    var skipBelow = -1
      ## Under an opened test-run item: its plain detail lines, which the
      ## item draws richly itself.
    for line in timeline.lines:
      if skipBelow >= 0:
        if line.indent > skipBelow: continue
        skipBelow = -1
      if line.itemKind == "test-run":
        let run = timeline.runOf(line)
        if run.id.len > 0:
          r.appendRendered(list, renderTestRunItem[R, N](r, timeline, line, run, ctx, openTests))
          skipBelow = line.indent
          continue
      r.appendRendered(list, renderPlainLine[R, N](r, line, ctx))
    r.appendRendered(body, listNode)
  panel

when defined(js):
  proc mountAgentHarborTraceLinksPanel*(container: isonim_dom.Element;
                                        timeline: SessionTimelineVM;
                                        ctx: AgentHarborTraceLinksContext) =
    ## Mounts the trace-link surface over `timeline` in `container`.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborTraceLinks[WebRenderer, isonim_dom.Element](WebRenderer(), timeline, ctx)))
