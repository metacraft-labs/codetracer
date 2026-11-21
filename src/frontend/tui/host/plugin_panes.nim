## host/plugin_panes.nim — a plugin's panes and editor decorations, as the
## terminal shows them (Extensibility-Model.md §6, §11.4.4).
##
## Everything here is drawn from what a plugin PUSHED: a pane is the last tree
## `Supervisor.renderSurface` holds (never plugin code), and a decoration is
## the last set the plugin sent for a document (`PluginSlot.decorations`). The
## one thing that goes the other way is `view-event`: a key or a click acting
## on a plugin pane's view runs the vocabulary's own `applyKey` on the pushed
## tree here, in the host, and the transition it produced is sent to the
## plugin through `Supervisor.viewEvent`, which answers it later with a new
## tree.
##
## The runtime (`app/`) reaches this module only through `PluginsService`'s
## closures (`plugin_service.service`), as plain strings and rows.

import std/[json, os, strutils, tables, unicode]

import ../../viewmodel/plugin_host/supervisor
import ../../../common/plugin_model
import ../../../common/view_vocabulary/[vocabulary, behaviour]
import ./plugin_processes

type
  PaneRow = object
    text: string
    node: ViewNode
      ## The interactive node this row acts on, or nil.
    option: int
      ## The option of `node` the row shows, or -1.

  PaneState = ref object
    target: string
      ## The id of the interactive node keys go to (the last one clicked),
      ## or "" for the first interactive node of the tree.

  PluginPanes* = ref object
    plugins*: SessionPlugins
    states: Table[string, PaneState]
    viewEventsSent*: int
      ## Counted for the status report and for a suite: every `view-event`
      ## this front-end sent.

  ContributedPaneInfo* = tuple[id, title: string; running: bool]

  SourceDecoration* = tuple[line: int; glyph, text, plugin: string]

proc newPluginPanes*(p: SessionPlugins): PluginPanes =
  PluginPanes(plugins: p, states: initTable[string, PaneState]())

proc contributedPanes*(pp: PluginPanes): seq[ContributedPaneInfo] =
  ## Every pane an INSTALLED plugin contributes, enabled or not — a disabled
  ## plugin's pane still names a loaded extension, and `renderSurface` says
  ## it is disabled — with whether its plugin is running (the panes the
  ## layout places when the plugin first activates).
  if pp.isNil or pp.plugins.isNil or pp.plugins.sup.isNil: return
  for s in pp.plugins.sup.slots.values:
    for c in s.spec.parsed.manifest.contributions:
      if c.kind == ckPane:
        result.add (id: s.id & "/" & c.id,
                    title: (if c.title.len > 0: c.title else: c.id),
                    running: s.active and s.enabled and not s.sessionDisabled)

proc stateOf(pp: PluginPanes; id: string): PaneState =
  if id notin pp.states: pp.states[id] = PaneState()
  pp.states[id]

proc collectRows(n: ViewNode; indent: int; rows: var seq[PaneRow]) =
  ## `plugin_processes.viewLines`' reading, with each row remembering the
  ## node (and option) it shows, so a click on it acts on that.
  if n.isNil: return
  let pad = repeat(' ', indent)
  let actsOn = if n.kind in InteractiveKinds and not n.disabled: n else: nil
  case n.kind
  of pkText, pkMarkdown:
    for line in n.text.splitLines:
      rows.add PaneRow(text: pad & line, node: nil, option: -1)
  of pkButton:
    rows.add PaneRow(text: pad & "[ " & n.label & " ]", node: actsOn, option: -1)
  of pkCheckbox, pkToggle:
    rows.add PaneRow(text: pad & (if n.checked: "[x] " else: "[ ] ") & n.label,
                     node: actsOn, option: -1)
  of pkInput:
    rows.add PaneRow(text: pad & n.label & ": " & n.text, node: actsOn,
                     option: -1)
  of pkProgressIndicator:
    rows.add PaneRow(text: pad & (if n.progress < 0: "…" else: $n.progress & "%"),
                     node: nil, option: -1)
  of pkImage:
    rows.add PaneRow(text: pad & "<" & n.mediaType & ", " & $n.mediaBytes &
                     " bytes> " & n.alt, node: nil, option: -1)
  of pkSelect, pkList, pkMenu, pkTabs:
    for i, o in n.options:
      let mark = if i == n.highlight or i == n.selected: "> " else: "  "
      rows.add PaneRow(text: pad & mark & o.label, node: actsOn, option: i)
  of pkTable:
    if n.columns.len > 0:
      rows.add PaneRow(text: pad & n.columns.join("  |  "), node: nil, option: -1)
    for i, r in n.rows:
      rows.add PaneRow(text: pad & r.join("  |  "), node: actsOn, option: i)
  of pkTree, pkCollapsible, pkModal:
    if n.label.len > 0:
      rows.add PaneRow(text: pad & (if n.children.len > 0:
        (if n.expanded: "▾ " else: "▸ ") else: "  ") & n.label,
        node: actsOn, option: -1)
    if n.expanded or n.kind == pkModal or n.label.len == 0:
      for c in n.children:
        collectRows(c, indent + 2, rows)

proc rowsOf(tree: ViewNode): seq[PaneRow] =
  collectRows(tree, 0, result)

proc findNode(n: ViewNode; id: string): ViewNode =
  if n.isNil: return nil
  if n.id == id: return n
  for c in n.children:
    let hit = findNode(c, id)
    if not hit.isNil: return hit
  nil

proc firstControl(n: ViewNode): ViewNode =
  ## The first node a key can act on, depth first — a `Tree`'s root counts
  ## only when nothing inside it is a control of its own (the metrics tree's
  ## children are text, so the tree takes the keys).
  if n.isNil: return nil
  for c in n.children:
    let hit = firstControl(c)
    if not hit.isNil: return hit
  if n.kind in InteractiveKinds and not n.disabled: n else: nil

proc indexOf(n: ViewNode): int =
  case n.kind
  of pkSelect, pkTabs: n.selected
  of pkList, pkMenu: n.highlight
  of pkTree, pkTable: n.cursor
  else: -1

proc eventFor(n: ViewNode; t: Transition): JsonNode =
  ## The `view-event` payload (§11.4.4): what the host's `applyKey` did, to
  ## which node, and the node's state after it.
  let idx = indexOf(n)
  result = %*{"transition": $t, "node": n.id, "kind": $n.kind, "index": idx,
              "checked": n.checked, "text": n.text}
  if idx >= 0 and idx < n.options.len:
    result["option"] = %n.options[idx].id
    result["label"] = %n.options[idx].label

proc keyPressOf*(name: string): (bool, KeyPress) =
  ## A terminal key's canonical name (`key_names.keyName`, lower-cased) as the
  ## vocabulary's medium-independent key, or false for a key no entry reads.
  case name
  of "enter", "return": (true, KeyPress(key: kEnter))
  of "space", " ": (true, KeyPress(key: kSpace))
  of "esc", "escape": (true, KeyPress(key: kEscape))
  of "up": (true, KeyPress(key: kUp))
  of "down": (true, KeyPress(key: kDown))
  of "left": (true, KeyPress(key: kLeft))
  of "right": (true, KeyPress(key: kRight))
  of "home": (true, KeyPress(key: kHome))
  of "end": (true, KeyPress(key: kEnd))
  of "backspace": (true, KeyPress(key: kBackspace))
  of "delete": (true, KeyPress(key: kDelete))
  else:
    if name.runeLen == 1:
      (true, KeyPress(key: kChar, ch: name.runeAt(0)))
    else:
      (false, KeyPress(key: kNone))

proc treeOf(pp: PluginPanes; id: string): ViewNode =
  pp.plugins.sup.renderSurface(id)

proc paneView*(pp: PluginPanes; id: string):
    tuple[lines: seq[string]; cursor: int; stale: bool] =
  ## The pane's rows and the row the reader's attention is on (the target
  ## node's highlighted option), or -1.
  if pp.isNil or pp.plugins.isNil:
    return (@[], -1, false)
  let tree = pp.treeOf(id)
  let rows = rowsOf(tree)
  let st = pp.stateOf(id)
  var target = if st.target.len > 0: findNode(tree, st.target) else: nil
  if target.isNil: target = firstControl(tree)
  result.cursor = -1
  for i, r in rows:
    result.lines.add r.text
    if not target.isNil and r.node == target and r.option >= 0 and
       r.option == indexOf(target):
      result.cursor = i
  result.stale = pp.plugins.sup.isStale(id)

proc send(pp: PluginPanes; id: string; n: ViewNode; t: Transition) =
  pp.plugins.sup.viewEvent(id, eventFor(n, t))
  inc pp.viewEventsSent

proc paneKey*(pp: PluginPanes; id, key: string): bool =
  ## A key on the focused plugin pane. The vocabulary's `applyKey` runs on the
  ## pushed tree's target node; when it handles the key, the transition goes
  ## to the plugin as `view-event`. An unhandled key is the terminal's.
  if pp.isNil or pp.plugins.isNil: return false
  let (known, kp) = keyPressOf(key.toLowerAscii)
  if not known: return false
  let tree = pp.treeOf(id)
  let st = pp.stateOf(id)
  var target = if st.target.len > 0: findNode(tree, st.target) else: nil
  if target.isNil: target = firstControl(tree)
  if target.isNil: return false
  let o = applyKey(target, kp)
  if not o.handled: return false
  pp.send(id, target, o.transition)
  true

proc paneClick*(pp: PluginPanes; id: string; row: int): bool =
  ## A click on content row `row` of a plugin pane: the row's node becomes
  ## the key target, its option is highlighted (or chosen, for `Tabs` and
  ## `Select`), and the node is activated — a list row activated, a checkbox
  ## toggled, a button pressed, a tab chosen — through `applyKey`'s own
  ## transition for Enter, sent as `view-event`.
  if pp.isNil or pp.plugins.isNil: return false
  let tree = pp.treeOf(id)
  let rows = rowsOf(tree)
  if row < 0 or row >= rows.len or rows[row].node.isNil: return false
  let r = rows[row]
  let n = r.node
  pp.stateOf(id).target = n.id
  if r.option >= 0:
    case n.kind
    of pkList, pkMenu: n.highlight = r.option
    of pkTabs:
      n.selected = r.option
      pp.send(id, n, trCommit)
      return true
    of pkSelect:
      n.selected = r.option
      n.highlight = r.option
      n.open = false
      pp.send(id, n, trCommit)
      return true
    of pkTable, pkTree: n.cursor = r.option
    else: discard
  let o = applyKey(n, KeyPress(key: kEnter))
  pp.send(id, n, if o.handled: o.transition else: trActivate)
  true

proc sameDocument(a, b: string): bool =
  a == b or (a.len > 0 and b.len > 0 and
             a.extractFilename == b.extractFilename and
             (a.endsWith("/" & b) or b.endsWith("/" & a) or
              a.isAbsolute != b.isAbsolute))

proc decorationsFor*(pp: PluginPanes; document: string): seq[SourceDecoration] =
  ## Every running plugin's decorations for `document`, as the plugin pushed
  ## them: `{"line": N, "text": "…", "glyph": "◆"}` items, a document being
  ## the path the mirrored session names (`location.file`). A plugin whose
  ## breaker is open or that is disabled draws none (§11.7.5).
  if pp.isNil or pp.plugins.isNil or pp.plugins.sup.isNil or document.len == 0:
    return
  for s in pp.plugins.sup.slots.values:
    if not s.active or not s.enabled or s.sessionDisabled: continue
    for doc, items in s.decorations:
      if not sameDocument(doc, document) or items.isNil or
         items.kind != JArray: continue
      for it in items:
        if it.kind != JObject: continue
        let line = it{"line"}.getInt(0)
        if line <= 0: continue
        result.add (line: line, glyph: it{"glyph"}.getStr("◆"),
                    text: it{"text"}.getStr(""), plugin: s.id)

proc markersFor*(pp: PluginPanes; document: string): seq[SourceDecoration] =
  ## Every running plugin's declared `marker` surfaces for `document`, read
  ## from the tree the plugin last pushed for that surface. A marker surface
  ## is a `Table` whose columns are `file`, `line`, `glyph` and `text` (any
  ## order; `glyph` and `text` optional) — data, never code — one row per
  ## marked line. A surface the plugin did not declare as a marker is never
  ## read here (the supervisor refuses a view for an undeclared surface).
  if pp.isNil or pp.plugins.isNil or pp.plugins.sup.isNil or document.len == 0:
    return
  for s in pp.plugins.sup.slots.values:
    if not s.active or not s.enabled or s.sessionDisabled: continue
    for c in s.spec.parsed.manifest.contributions:
      if c.kind != ckMarker: continue
      let entry = s.views.getOrDefault(c.id)
      let t = entry.tree
      if t.isNil or t.kind != pkTable: continue
      let fileCol = t.columns.find("file")
      let lineCol = t.columns.find("line")
      let glyphCol = t.columns.find("glyph")
      let textCol = t.columns.find("text")
      if fileCol < 0 or lineCol < 0: continue
      for r in t.rows:
        if r.len <= max(fileCol, lineCol): continue
        if not sameDocument(r[fileCol], document): continue
        var line = 0
        try: line = parseInt(r[lineCol])
        except ValueError: continue
        if line <= 0: continue
        result.add (line: line,
                    glyph: (if glyphCol >= 0 and glyphCol < r.len: r[glyphCol]
                            else: "▶"),
                    text: (if textCol >= 0 and textCol < r.len: r[textCol]
                           else: ""),
                    plugin: s.id)
