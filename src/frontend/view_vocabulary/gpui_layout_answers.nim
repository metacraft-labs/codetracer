## view_vocabulary/gpui_layout_answers.nim — PLAT-35. **The GPUI front-end's
## answers to the eight layout questions, read out of ITS OWN rendered
## artefact.**
##
## ## The one rule this module exists to obey
##
## `Verification-Harness-Traps` §30a: *if one side's answer is derived from the
## other's, all questions agree and nothing is compared.* So nothing here reads
## the Electron front-end, the scenario's expected values, or the other
## producer. Every answer comes from one of exactly two artefacts this
## front-end produced:
##
##   * **the Rust shadow tree**, across the FFI boundary, through
##     `gpui_get_attribute` / `gpui_child_count` / `gpui_nth_child` — the same
##     surface `test_cross_renderer_panes.nim` and
##     `test_editor_front_end_observed.nim` already read;
##   * **the projected dock document**, the JSON `projectDock` emitted —
##     walked, never re-derived from the `Layout` it came from, which would be
##     comparing the model with itself (§4a).
##
## `ci/test/plat35-answer-independence.sh` is the scan that keeps it that way,
## and it is aimed at this file's BODY rather than at its header.
##
## ## What the independence of this arm is, and is not
##
## Said plainly, because an arm claiming more than it has is the weakest thing
## on this page. PLAT-21 wrote the sentence and it is true here unchanged: the
## GPUI arm's independence is in the **transport and the storage**, not in the
## decision. The row model this front-end draws from is the shared
## `EditorSurface`, and so is the Electron one's — that is PLAT-34's whole
## point. What this arm can catch is an attribute the renderer mangled, a node
## it dropped, a row it drew in the wrong order, a metric or a token this
## front-end resolves differently from the other, and a pane the dock
## projection placed somewhere the DOM does not.
##
## What it cannot catch is a defect in the shared row model, and that is
## `DIFF-1`'s model half — PLAT-34 — rather than this milestone's.

import std/[json, strutils]

import isonim_gpui/renderer
import isonim_gpui/bindings

import ../gpui/app/leaves
import ../gpui/app/dock_projection
import ../gpui/app/shell
import ../../common/view_vocabulary

const GpuiFrontEndName* = "gpui"
  ## The ONE place this front-end is named in PLAT-35's data. The scenario
  ## definition names no renderer; an answer set has to say whose it is.

# ---------------------------------------------------------------------------
# Q1 — pane rectangles, out of the PROJECTED DOCUMENT
# ---------------------------------------------------------------------------

proc walkRects(node: JsonNode; x, y, w, h: int; into: var seq[PaneRect]) =
  ## Divide a `DockAreaState` document's own `sizes` and `axis` back into
  ## rectangles.
  ##
  ## The document carries the split sizes `distributeExtent` produced and the
  ## axis `panelStateOf` chose; nothing here consults the `Layout`. A projection
  ## that placed a pane wrongly therefore reports the wrong rectangle, which is
  ## the only way this question can be worth asking.
  if node.isNil or node.kind != JObject or not node.hasKey("panel_name"):
    return
  let name = node["panel_name"].getStr
  let children = if node.hasKey("children"): node["children"] else: newJArray()
  if name == "StackPanel":
    let stack = node{"info", "stack"}
    let axis = if stack.isNil or not stack.hasKey("axis"): 0
               else: stack["axis"].getInt
    var sizes: seq[int] = @[]
    if not stack.isNil and stack.hasKey("sizes"):
      for s in stack["sizes"]: sizes.add int(s.getFloat)
    var offset = 0
    var i = 0
    for c in children:
      let extent = if i < sizes.len: sizes[i]
                   elif children.len > 0: (if axis == 0: w else: h) div children.len
                   else: 0
      if axis == 0:
        walkRects(c, x + offset, y, extent, h, into)
      else:
        walkRects(c, x, y + offset, w, extent, into)
      offset += extent
      inc i
    return
  if name == "TabPanel":
    let info = node{"info", "tabs", "active_index"}
    let active = if info.isNil: 0 else: info.getInt
    var i = -1
    for c in children:
      inc i
      if c.kind != JObject: continue
      # **ONLY THE ACTIVE TAB OCCUPIES A REGION.** A stack's non-active member
      # is placed and not visible — the same answer `visiblePanes` gives and
      # the same one the terminal projection gives — so reporting a rectangle
      # for it would make the two front-ends disagree about a pane neither
      # draws.
      if i != active: continue
      let panel = c{"info", "panel"}
      if panel.isNil or panel.kind != JObject: continue
      var paneId = ""
      if panel.hasKey(ContributedPaneInfoKey):
        paneId = panel[ContributedPaneInfoKey].getStr
      elif panel.hasKey(PaneInfoKey):
        paneId = panel[PaneInfoKey].getStr
      if paneId.len == 0: continue
      into.add PaneRect(pane: paneId, x: x, y: y, w: w, h: h)
    return

proc normalise(rects: seq[PaneRect]; viewport: DockViewport): seq[PaneRect] =
  ## Into hundredths of the viewport, so a 1920x1080 window and a 1440x900 one
  ## answer the same question.
  result = @[]
  if viewport.width <= 0 or viewport.height <= 0: return
  for r in rects:
    result.add PaneRect(
      pane: r.pane,
      x: (r.x * 100 + viewport.width div 2) div viewport.width,
      y: (r.y * 100 + viewport.height div 2) div viewport.height,
      w: (r.w * 100 + viewport.width div 2) div viewport.width,
      h: (r.h * 100 + viewport.height div 2) div viewport.height)

proc gpuiPaneRectangles*(projection: DockProjection;
                         viewport: DockViewport): string =
  if projection.status != dpsProjected: return Unanswered
  var rects: seq[PaneRect] = @[]
  if projection.state.hasKey("center"):
    walkRects(projection.state["center"], 0, 0, viewport.width,
              viewport.height, rects)
  if rects.len == 0: return Unanswered
  formatPaneRectangles(normalise(rects, viewport))

# ---------------------------------------------------------------------------
# Q2 and Q8 — presence / tab order and focus order, out of the SHADOW TREE
# ---------------------------------------------------------------------------

proc gpuiPanesPresent*(root: GpuiElement): string =
  ## Read back off the drawn leaves: `pane@activeIndex/tabCount` in the order
  ## the renderer appended them.
  ##
  ## `TabAttribute` is what `renderLeaf` stamped — `tabIndex/tabCount@active` —
  ## and only the ACTIVE member of a group is reported present, which is the
  ## same rule Q1 applies to the document and the same one
  ## `test_cross_frontend_layout.nim` already established for this pair.
  if root.isNil: return Unanswered
  var panes: seq[(string, int, int)] = @[]
  for i in 0 ..< childCount(root):
    let child = nthChild(root, i)
    if child.isNil: continue
    let pane = getAttribute(child, PaneRoleAttribute)
    if pane.len == 0: continue
    let tab = getAttribute(child, TabAttribute)
    var tabIndex = 0
    var tabCount = 1
    var active = 0
    let at = tab.find('@')
    if at > 0:
      let slash = tab.find('/')
      if slash > 0 and slash < at:
        try:
          tabIndex = parseInt(tab[0 ..< slash])
          tabCount = parseInt(tab[slash + 1 ..< at])
          active = parseInt(tab[at + 1 .. ^1])
        except ValueError:
          discard
    if tabIndex != active: continue
    panes.add (pane, active, tabCount)
  if panes.len == 0: return Unanswered
  formatPanesPresent(panes)

proc gpuiFocusOrder*(root: GpuiElement): string =
  ## The order `FocusIndexAttribute` records. **Declared, not enforced** —
  ## `PLAT35-VG4`, whose measurement and remedy are in the gap register.
  if root.isNil: return Unanswered
  var order: seq[(int, string)] = @[]
  for i in 0 ..< childCount(root):
    let child = nthChild(root, i)
    if child.isNil: continue
    let pane = getAttribute(child, PaneRoleAttribute)
    let idx = getAttribute(child, FocusIndexAttribute)
    if pane.len == 0 or idx.len == 0: continue
    try:
      order.add (parseInt(idx), pane)
    except ValueError:
      discard
  if order.len == 0: return Unanswered
  var names: seq[string] = @[]
  var wanted = 0
  while names.len < order.len:
    var found = false
    for (i, pane) in order:
      if i == wanted:
        names.add pane
        found = true
        break
    if not found: break
    inc wanted
  if names.len != order.len: return Unanswered
  formatFocusOrder(names)

# ---------------------------------------------------------------------------
# Q3..Q7 — the editor, out of the SHADOW TREE
# ---------------------------------------------------------------------------

proc editorRowNodes(root: GpuiElement): seq[GpuiElement] =
  ## Every node carrying `EditorRowAttribute`, in draw order. A stack walk
  ## rather than a positional read, because the editor's rows are preceded by
  ## a heading, a source statement and possibly a notice, and a positional
  ## reader would silently count one of those as row zero.
  result = @[]
  if root.isNil: return
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    if getAttribute(n, EditorRowAttribute).len > 0:
      result.add n
    var kids: seq[GpuiElement] = @[]
    for i in 0 ..< childCount(n):
      kids.add nthChild(n, i)
    for i in countdown(kids.high, 0):
      stack.add kids[i]

proc lineOf(node: GpuiElement): int =
  try: parseInt(getAttribute(node, EditorRowAttribute))
  except ValueError: -1

proc gpuiEditorRowCount*(root: GpuiElement): string =
  let rows = editorRowNodes(root)
  if rows.len == 0: return Unanswered
  var first = high(int)
  var last = low(int)
  for r in rows:
    let line = lineOf(r)
    if line < 0: continue
    if line < first: first = line
    if line > last: last = line
  if first > last: return Unanswered
  formatEditorRowCount(rows.len, first, last)

func gutterMarkName*(mark, pointer, provenance: string): string =
  ## **ONE naming function, called by this producer and by the Electron
  ## extractor's published mapping**, so the two answers are two readings of
  ## one alphabet rather than two dialects (§30's remedy).
  ##
  ## The precedence is the row model's own: an execution pointer outranks a
  ## mark on the same line, because a line that is both is a line the debugger
  ## is stopped on and a user reads the stop first. Provenance is reported only
  ## where it is not the ordinary case, for the same reason `EditorProvenance`
  ## exists at all — CTUI-5: *"a file served `savUnverified` must not look
  ## identical to one served `savVerified`"*.
  var parts: seq[string] = @[]
  if pointer == "eptExecution": parts.add "execution"
  elif pointer == "eptInspection": parts.add "inspection"
  case mark
  of "emBreakpoint": parts.add "breakpoint"
  of "emBreakpointDisabled": parts.add "breakpoint-disabled"
  of "emTracepoint": parts.add "tracepoint"
  else: discard
  if provenance == "epUnverified": parts.add "unverified"
  elif provenance == "epAbsent": parts.add "absent"
  parts.join("+")

proc gpuiGutterMarks*(root: GpuiElement): string =
  let rows = editorRowNodes(root)
  if rows.len == 0: return Unanswered
  # The provenance is a property of the SURFACE rather than of a row, and it is
  # stamped on the editor's container. Found by walking up is not possible
  # across this FFI without a parent pointer per node, so it is read off the
  # node that carries it and applied to every row — which is what it means.
  var provenance = ""
  var stack = @[root]
  while stack.len > 0 and provenance.len == 0:
    let n = stack.pop()
    if n.isNil: continue
    let p = getAttribute(n, EditorProvenanceAttribute)
    if p.len > 0:
      provenance = p
      break
    for i in 0 ..< childCount(n):
      stack.add nthChild(n, i)
  var marks: seq[(int, string)] = @[]
  for r in rows:
    let line = lineOf(r)
    if line < 0: continue
    let name = gutterMarkName(getAttribute(r, EditorMarkAttribute),
                              getAttribute(r, EditorPointerAttribute),
                              provenance)
    if name.len > 0:
      marks.add (line, name)
  # An empty mark set is a LEGITIMATE answer — a file with no breakpoints and
  # no stop has no marks — and it is deliberately not `Unanswered`. That
  # distinction is the whole reason `Unanswered` is not the empty string.
  formatGutterMarks(marks)

proc gpuiInlineValueRuns*(root: GpuiElement): string =
  let rows = editorRowNodes(root)
  if rows.len == 0: return Unanswered
  var runs: seq[(int, seq[(string, string)])] = @[]
  for r in rows:
    let line = lineOf(r)
    if line < 0: continue
    let raw = getAttribute(r, EditorValuesAttribute)
    if raw.len == 0: continue
    var values: seq[(string, string)] = @[]
    for part in raw.split('|'):
      let eq = part.find('=')
      if eq < 0: continue
      values.add (part[0 ..< eq], part[eq + 1 .. ^1])
    if values.len > 0:
      runs.add (line, values)
  formatInlineValueRuns(runs)

proc collectRoles(root: GpuiElement;
                  metrics: var seq[TextMetric];
                  tokens: var seq[(TextRole, string)]) =
  ## Walk once, reading `TextRoleAttribute` / `TextMetricAttribute` /
  ## `TokenAttribute` off whatever carries them. FIRST WINS per role: a role
  ## whose two occurrences disagree is a defect this front-end would have to
  ## answer for, and reporting the first makes the disagreement visible in the
  ## comparison rather than averaging it away.
  if root.isNil: return
  var seenMetric: array[TextRole, bool]
  var seenToken: array[TextRole, bool]
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    let roleName = getAttribute(n, TextRoleAttribute)
    if roleName.len > 0:
      for role in TextRole:
        if $role != roleName: continue
        let metric = getAttribute(n, TextMetricAttribute)
        if metric.len > 0 and not seenMetric[role]:
          let parts = metric.split('/')
          if parts.len == 3:
            var family = fcMono
            var size = sbBody
            var weight = wbRegular
            for f in FamilyClass:
              if $f == parts[0]: family = f
            for s in SizeBucket:
              if $s == parts[1]: size = s
            for w in WeightBucket:
              if $w == parts[2]: weight = w
            metrics.add TextMetric(role: role, family: family, size: size,
                                   weight: weight)
            seenMetric[role] = true
        let token = getAttribute(n, TokenAttribute)
        if token.len > 0 and not seenToken[role]:
          tokens.add (role, token)
          seenToken[role] = true
    var kids: seq[GpuiElement] = @[]
    for i in 0 ..< childCount(n):
      kids.add nthChild(n, i)
    for i in countdown(kids.high, 0):
      stack.add kids[i]

proc gpuiTextMetrics*(root: GpuiElement): string =
  var metrics: seq[TextMetric] = @[]
  var tokens: seq[(TextRole, string)] = @[]
  collectRoles(root, metrics, tokens)
  if metrics.len == 0: return Unanswered
  formatTextMetrics(metrics)

proc spanTokenOf(row: GpuiElement; role: TextRole): string =
  ## The token on the child of `row` that carries `role`, or "".
  if row.isNil: return ""
  for i in 0 ..< childCount(row):
    let child = nthChild(row, i)
    if child.isNil: continue
    if getAttribute(child, TextRoleAttribute) == $role:
      return getAttribute(child, TokenAttribute)
  ""

proc gpuiTokenColours*(root: GpuiElement): string =
  ## **THE ROW THAT MATTERS, NOT THE FIRST ROW**, and the distinction was
  ## measured rather than reasoned about.
  ##
  ## The first spelling of this took the first occurrence of each role and
  ## reported `editor.code.foreground` for a session stopped on line 44 — while
  ## the Electron arm, which looks for the stopped row and for the first MARKED
  ## gutter, reported `editor.executionLine.background`. That is a defect in
  ## THIS READER and not a divergence between the two front-ends, and filing it
  ## as one would have been a fabricated finding: both editors do draw the stop.
  ##
  ## So the rule here is the Electron extractor's own rule, arrived at
  ## independently on this side's own artefact: the code token comes from the
  ## row carrying the execution pointer when there is one, and the gutter token
  ## from the first row carrying a mark when there is one. Both fall back to the
  ## first drawn row, which is what a session with no stop and no breakpoint
  ## genuinely shows.
  var tokens: seq[(TextRole, string)] = @[]
  let rows = editorRowNodes(root)
  if rows.len > 0:
    var codeRow = rows[0]
    var gutterRow = rows[0]
    for r in rows:
      if getAttribute(r, EditorPointerAttribute) == "eptExecution":
        codeRow = r
        break
    for r in rows:
      let mark = getAttribute(r, EditorMarkAttribute)
      if mark.len > 0 and mark != "emNone":
        gutterRow = r
        break
    let codeToken = spanTokenOf(codeRow, trEditorCode)
    if codeToken.len > 0: tokens.add (trEditorCode, codeToken)
    let gutterToken = spanTokenOf(gutterRow, trGutterLineNumber)
    if gutterToken.len > 0: tokens.add (trGutterLineNumber, gutterToken)
  # Every OTHER role is read wherever it is stamped, first occurrence — the
  # pane title is one per leaf and the value roles are one per annotated row,
  # and none of them has a "which one matters" question the way the editor's
  # two do.
  var metrics: seq[TextMetric] = @[]
  var everything: seq[(TextRole, string)] = @[]
  collectRoles(root, metrics, everything)
  for (role, token) in everything:
    if role == trEditorCode or role == trGutterLineNumber: continue
    tokens.add (role, token)
  if tokens.len == 0: return Unanswered
  formatTokenColours(tokens)

# ---------------------------------------------------------------------------

proc gpuiLayoutAnswers*(scenario: string; root: GpuiElement;
                        projection: DockProjection;
                        viewport: DockViewport): LayoutAnswerSet =
  ## **All eight, always.** A question this front-end cannot answer produces a
  ## row carrying `Unanswered`, never a missing row: §3's *"a front-end that
  ## cannot answer one says so rather than omitting it"*, which is
  ## `Verification-Harness-Traps` §4 applied to an answer set.
  ##
  ## The tier is per row. `lqTextMetrics` is a SOURCE READING on this
  ## front-end and a capture on the other, because this shim is built without
  ## `--features gpui-backend` and has never asked a text system how tall a
  ## glyph is (`PLAT35-VG1`). An unlabelled source reading beside a captured
  ## one is the tier violation PLAT-23 wrote the rule for.
  result = LayoutAnswerSet(frontEnd: GpuiFrontEndName, scenario: scenario,
                           answers: @[])
  template row(q: LayoutQuestion; v: string; t: CaptureTier) =
    result.answers.add LayoutAnswer(question: q, value: v, tier: t)
  row lqPaneRectangles, gpuiPaneRectangles(projection, viewport), ctCaptured
  row lqPanesPresent, gpuiPanesPresent(root), ctCaptured
  row lqEditorRowCount, gpuiEditorRowCount(root), ctCaptured
  row lqGutterMarks, gpuiGutterMarks(root), ctCaptured
  row lqInlineValueRuns, gpuiInlineValueRuns(root), ctCaptured
  row lqTextMetrics, gpuiTextMetrics(root), ctSourceReading
  row lqTokenColour, gpuiTokenColours(root), ctCaptured
  row lqFocusOrder, gpuiFocusOrder(root), ctCaptured

proc unknownQuestionKeys*(node: JsonNode): seq[string] =
  ## **THE KEYS `answerSetFromJson` DROPPED, SO SOMEBODY CAN ASSERT THERE ARE
  ## NONE.**
  ##
  ## The reader below `continue`s past a question id it does not recognise,
  ## which is the right thing for a parser to do and the wrong thing for a
  ## parser to do SILENTLY: a question renamed on the Electron side and not
  ## here would simply stop arriving, and every check written over "the
  ## questions both sides have" is satisfied by the ones that still match
  ## (§4). This is the same defect shape as a scanner that finds nothing.
  ##
  ## So the drop is reported as a value. The suite asserts this is empty,
  ## which is what turns a rename into a named failure instead of a quietly
  ## shorter answer set.
  result = @[]
  if node.isNil or node.kind != JObject: return
  let answers = node{"answers"}
  if answers.isNil or answers.kind != JArray: return
  for a in answers:
    let key = a{"question"}.getStr("")
    if not questionFromKey(key)[0]: result.add key

proc answerSetFromJson*(node: JsonNode): LayoutAnswerSet =
  ## Unrecognised question ids are DROPPED here and REPORTED by
  ## `unknownQuestionKeys` above; the suite asserts that report is empty.
  result = LayoutAnswerSet(frontEnd: "", scenario: "", answers: @[])
  if node.isNil or node.kind != JObject: return
  result.frontEnd = node{"frontEnd"}.getStr("")
  result.scenario = node{"scenario"}.getStr("")
  let answers = node{"answers"}
  if answers.isNil or answers.kind != JArray: return
  for a in answers:
    let (ok, q) = questionFromKey(a{"question"}.getStr(""))
    if not ok: continue
    var tier = ctSourceReading
    for t in CaptureTier:
      if $t == a{"tier"}.getStr(""): tier = t
    result.answers.add LayoutAnswer(question: q,
                                    value: a{"value"}.getStr(Unanswered),
                                    tier: tier)
