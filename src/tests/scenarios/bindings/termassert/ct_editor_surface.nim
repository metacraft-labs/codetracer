## ct_editor_surface.nim — the surface of CodeTracer hosted in a terminal
## editor (codetracer.nvim, codetracer.el), read from the screen.
##
## The editor says where its windows are and what each shows: `layoutOf`'s
## JSON, which the binding asks the running editor for (`ct_editor_binding`).
## Everything a scenario checks is then read off the screen's cells inside
## those windows, as a person reads it:
##
## * the source window: each row's line number and the execution sign (`▶`)
##   in the columns before the text (the sign column and the number column);
## * a pane window (a `ct://{session}/{pane}` buffer): its rows, read as the
##   terminal front-end's panes are (`ct_tui_screen.readList`), since the pane
##   server draws them with the same painters;
## * the debugger controls in the tab line (codetracer.nvim) or the tab bar
##   (codetracer.el): the transport glyphs, by the desktop's labels.
##
## The layout JSON: `{ mode, windows: [{ buf, file, row, col, width, height,
## textoff, topline, botline, cursor, editor, selected }] }` — 0-based screen
## cells; `row`/`height` the window's text rows (no tab strip, winbar or
## status line); `col`/`width` its columns from the first of the sign and
## number columns; `textoff` how many of them come before the text.

import std/[json, strutils, options, tables]
from std/unicode import toRunes, runeLen, `$`
import demo_video_script/surface
import ./ct_tui_screen

proc fl(i: int): float = float(i)

proc paneOf*(buf: string): (int, string) =
  ## `ct://3/calltrace` -> (3, "calltrace"); (0, "") for any other buffer.
  if not buf.startsWith("ct://"): return (0, "")
  let rest = buf["ct://".len .. ^1]
  let slash = rest.find('/')
  if slash <= 0: return (0, "")
  try: (parseInt(rest[0 ..< slash]), rest[slash + 1 .. ^1])
  except ValueError: (0, "")

proc paneRoles*(pane: string): Option[(string, string, string)] =
  ## The pack's role for a pane, its rows' role and their key.
  case pane.toLowerAscii
  of "calltrace": some(("call-trace", "call", "name"))
  of "eventlog": some(("event-log", "event", "text"))
  of "state": some(("variables", "variable", "name"))
  of "terminaloutput": some(("terminal-output", "row", "text"))
  else: none((string, string, string))

proc fileName(path: string): string =
  let i = path.rfind('/')
  if i >= 0: path[i + 1 .. ^1] else: path

proc readSourceWindow(g: ScreenGrid; w: JsonNode; t: var Tree; root: SurfaceNode) =
  let row = w["row"].getInt
  let col = w["col"].getInt
  let width = w["width"].getInt
  let height = w["height"].getInt
  let textoff = w{"textoff"}.getInt
  let file = w{"file"}.getStr
  let ed = node("editor", fl(col), fl(row), fl(width), fl(height))
  t.add(root, ed)
  var current = 0
  var marked: seq[(int, int)]     # lines with a ▶ in their sign column, and their rows
  var texts: seq[string]
  var shown: seq[int]
  for r in row ..< min(g.height, row + height):
    let prefix = g.rowText(r, col, col + textoff)
    var digits = ""
    for ch in prefix:
      if ch in Digits: digits.add ch
      elif digits.len > 0: break
    if digits.len == 0: continue       # a wrapped line's continuation, or past the end
    let n = parseInt(digits)
    let text = g.rowText(r, col + textoff, col + width).strip(leading = false)
    if prefix.contains("▶"): marked.add (n, r)
    shown.add n
    texts.add text
    t.add(ed, node("line", fl(col), fl(r), fl(width), 1,
                   %*{"number": n, "text": text, "current": false,
                      "caret": n == w{"cursor"}.getInt, "$text-column": col + textoff},
                   @[("number", $n)]))
  # The execution line is the ▶ whose line is highlighted: codetracer.nvim
  # draws a test's sign as ▶ too (a test not yet run), on an unhighlighted
  # line. A lone ▶ is the execution line.
  let textCol = min(col + textoff + 1, col + width - 1)
  var grounds = initCountTable[string]()
  for r in row ..< min(g.height, row + height): grounds.inc g.rows[r][textCol].bg
  let usual = if grounds.len > 0: grounds.largest.key else: ""
  var lit: seq[int]
  for (n, r) in marked:
    if g.rows[r][textCol].bg != usual: lit.add n
  current = if lit.len == 1: lit[0] elif marked.len == 1: marked[0][0] else: 0
  for l in t.kids(ed):
    if l.props["number"].getInt == current and current > 0: l.props["current"] = %true
  let name = fileName(file)
  let caret = w{"cursor"}.getInt
  let first = if shown.len > 0: shown[0] else: 0
  let last = if shown.len > 0: shown[^1] else: 0
  ed.props = %*{"file": name, "active": true, "focused": w{"selected"}.getBool,
                "current-line": current, "caret-line": caret,
                "first-visible": first, "last-visible": last, "text": texts.join("\n")}
  ed.keys = @[("file", name)]

proc readPaneWindow(g: ScreenGrid; w: JsonNode; pane: string; t: var Tree; root: SurfaceNode) =
  let row = w["row"].getInt
  let col = w["col"].getInt
  let box = Box(left: col, right: col + w["width"].getInt, strip: row - 1,
                bottom: min(g.height, row + w["height"].getInt))
  let roles = paneRoles(pane)
  if roles.isSome:
    let (role, child, key) = roles.get
    readList(g, box, t, root, role, child, key)
  else:
    readList(g, box, t, root, "pane", "row", "text")
    let n = t.kids(root)[^1]
    var lines: seq[string]
    for r in t.kids(n):
      lines.add r.props{"text"}.getStr
      r.props["first"] = %r.props{"text"}.getStr.splitWhitespace()[0]
      r.props["selected"] = %false
    n.props["title"] = %pane
    n.props["text"] = %lines
    n.keys = @[("title", pane)]

proc readControls(g: ScreenGrid; rows: openArray[int]; t: var Tree; root: SurfaceNode) =
  ## The transport strip, by the desktop's labels: its controls drawn as
  ## glyphs (`↶ ↷ …`, the plugins' default) or as words (`Rev next  Next …`,
  ## their text tier), in the toolbar's order.
  for r in rows:
    if r < 0 or r >= g.height: continue
    var found: seq[(int, int, string)]        # column, width, label
    for c in 0 ..< g.width:
      for (glyph, label) in TransportGlyphs:
        if g.rows[r][c].text == glyph: found.add (c, 1, label)
    if found.len < 4:
      # the words: each one after the last, starting at the strip's first
      found.setLen(0)
      var cells: seq[string]
      for c in 0 ..< g.width: cells.add g.rows[r][c].text
      proc wordAt(c: int; w: string): bool =
        let rs = w.toRunes
        if c + rs.len > cells.len: return false
        for i, ch in rs:
          if cells[c + i] != $ch: return false
        (c == 0 or cells[c - 1] in [" ", ""]) and
          (c + rs.len == cells.len or cells[c + rs.len] in [" ", ""])
      var c = 0
      for (word, label) in TransportWords:
        var at = -1
        for x in c ..< cells.len:
          if wordAt(x, word):
            at = x
            break
        if at < 0: break
        found.add (at, word.runeLen, label)
        c = at + word.runeLen
      if found.len < TransportWords.len: found.setLen(0)
    if found.len < 4: continue
    let tb = node("toolbar", fl(found[0][0]), fl(r), fl(found[^1][0] + found[^1][1] - found[0][0]), 1)
    t.add(root, tb)
    for (c, w, label) in found:
      t.add(tb, node("toolbar-button", fl(c), fl(r), fl(w), 1,
                     %*{"label": label, "enabled": true}, @[("label", label)]))
    return

proc readEditorSurface*(g: ScreenGrid; layout: JsonNode; controlRows: openArray[int]): Tree =
  ## The tree of role instances: the window, the source editor, the panes
  ## and the debugger controls.
  result.root = node("window", 0, 0, fl(g.width), fl(g.height),
                     %*{"mode": layout{"mode"}.getStr})
  result.root.visible = true
  let root = result.root
  # the sessions: a tab page (Neovim) or a tab-bar tab (Emacs) each
  let sessions = layout{"sessions"}.getInt
  result.add(root, node("session-strip", 0, 0, fl(g.width), 1,
                        %*{"count": sessions, "active": 1}))
  # The source window: the one the plugin names; when it names none in this
  # tab page (a session the server opened, before the plugin noted its
  # window), the largest window showing a file.
  var source = -1
  var best = 0
  let wins = layout{"windows"}.getElems
  for i, w in wins:
    if w{"editor"}.getBool: source = i
  if source < 0:
    for i, w in wins:
      let area = w{"width"}.getInt * w{"height"}.getInt
      if paneOf(w{"buf"}.getStr)[1].len == 0 and w{"file"}.getStr.len > 0 and area > best:
        best = area
        source = i
  for i, w in wins:
    let (_, pane) = paneOf(w{"buf"}.getStr)
    if pane.len > 0:
      readPaneWindow(g, w, pane, result, root)
    elif i == source:
      readSourceWindow(g, w, result, root)
  readControls(g, controlRows, result, root)

proc hasExecutionLine*(t: Tree): bool =
  ## The source window marks a line as the one the replay is stopped on.
  for n in t.kids(t.root):
    if n.role == "editor" and n.props{"current-line"}.getInt > 0: return true
  false
