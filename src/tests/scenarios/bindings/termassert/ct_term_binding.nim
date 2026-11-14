## ct_term_binding.nim — CodeTracer's TermAssert binding: the terminal
## front-end (`codetracer-tui`) flavour of the CodeTracer scenario pack
## (`../../pack/codetracer.pack.yaml`), for DemoVideoScript-TermAssert.
##
## * Stages: the pack's one implementation (`../../stages/ct_stages.nim`);
##   `open-recording` / `open-project` then start the shipped binary in a real
##   pty under TermAssert, with the run's isolated state.
## * The surface: the screen, read by `ct_tui_screen` — cells and colours
##   only.
## * Conditions: `replay-idle` — the top bar says the replay is paused and the
##   status line names where it is.
## * Actions (`act:` steps): `write-file` and `make-read-only` change a file
##   of the stage's project folder, as another program would.
## * The binding resolver: `../../resolver/ct_resolver.nim`, the shared
##   keymap router built as the terminal builds it, at the scope the screen
##   shows.
##
## No mocks: the binary, the pty, libvterm, the replay server and the
## recordings are the real ones.

import std/[exitprocs, json, options, os, strutils, tables]
from std/unicode import `$`
import term_assert
import demo_video_script_termassert
import ../../stages/ct_stages
import ../../resolver/ct_resolver
import ./ct_tui_screen
import ../../../../frontend/viewmodel/keymap/[context_keys, keymap_router]
import ../../../../frontend/viewmodel/viewmodels/product_mode
import ../../../../common/key_names

proc tuiBinary*(): string =
  result = getEnv("CODETRACER_TUI_BIN")
  if result.len == 0: result = repo() / "build" / "bin" / "codetracer-tui"
  if not fileExists(result):
    raise newException(IOError, "codetracer-tui is not built at " & result & " (just build-tui)")

proc colorKey(c: Color): string =
  case c.kind
  of ckDefault: "d"
  of ckIndexed: "i" & $c.idx
  of ckRgb: "#" & $c.r & "," & $c.g & "," & $c.b

proc grid*(ctx: TermContext): ScreenGrid =
  ## The screen as cells.
  result = ScreenGrid(width: ctx.width, height: ctx.height)
  let cur = ctx.sess.cursorPosition()
  result.cursorRow = cur.row
  result.cursorCol = cur.col
  result.cursorVisible = ctx.sess.cursorVisible()
  for r in 0 ..< ctx.height:
    var row: seq[GridCell]
    for c in 0 ..< ctx.width:
      let cell = ctx.sess.cellAt(r, c)
      let t = if cell.width == 0: "" elif int(cell.rune) == 0: " " else: $cell.rune
      row.add GridCell(text: t, bg: colorKey(cell.bg), fg: colorKey(cell.fg),
                       bold: caBold in cell.attrs, inverse: caReverse in cell.attrs)
    result.rows.add row

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["mode"], "affordances": []},
    "session-strip": {"properties": ["count", "active"], "affordances": []},
    "session-tab": {"properties": ["title", "active"], "affordances": ["click", "context-click"]},
    "pane-tab": {"properties": ["label", "active"], "affordances": ["click", "context-click", "drag-source"]},
    "editor": {"properties": ["file", "active", "focused", "current-line", "caret-line",
                              "first-visible", "last-visible", "text"],
               "affordances": ["click", "context-click", "wheel", "focusable", "text-entry"]},
    "line": {"properties": ["number", "text", "current", "caret", "breakpoint", "tracepoint"],
             "affordances": ["click", "double-click", "context-click"]},
    "call-trace": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "call": {"properties": ["name", "arguments", "current", "selected"],
             "affordances": ["click", "double-click", "context-click"]},
    "event-log": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "event": {"properties": ["text", "kind", "current"], "affordances": ["click", "double-click", "context-click"]},
    "variables": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "variable": {"properties": ["name", "value"], "affordances": ["click", "double-click", "context-click"]},
    "terminal-output": {"properties": ["text", "count"], "affordances": ["wheel", "focusable"]},
    "status-line": {"properties": ["message", "location", "mode"], "affordances": []},
    "omnibox": {"properties": ["query", "focused", "count"], "affordances": ["click", "text-entry", "focusable"]},
    # --- terminal ---
    "pane": {"properties": ["title", "text", "count", "tabs", "hbar"],
             "affordances": ["click", "wheel", "context-click", "drop-target"]},
    "row": {"properties": ["text", "first", "selected"], "affordances": ["click", "double-click", "context-click"]},
    "cell": {"properties": ["text"], "affordances": ["click", "double-click", "context-click"]},
    "popup": {"properties": ["title", "text"], "affordances": ["click"]},
    "context-menu": {"properties": ["count"], "affordances": []},
    "menu-item": {"properties": ["label", "enabled", "shortcut"], "affordances": ["click"]},
    "menu-bar": {"properties": [], "affordances": []},
    "menu": {"properties": ["label", "open"], "affordances": ["click"]},
    "dropdown": {"properties": ["level", "count"], "affordances": []},
    "dropdown-item": {"properties": ["label", "shortcut", "folder", "selected"], "affordances": ["click"]},
    "toolbar": {"properties": [], "affordances": []},
    "toolbar-button": {"properties": ["label", "enabled"], "affordances": ["click"]},
    "filesystem": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "file-node": {"properties": ["name", "kind", "expanded", "selected"],
                  "affordances": ["click", "double-click", "context-click"]},
    "dock-label": {"properties": ["label"], "affordances": ["click", "context-click"]},
    "welcome": {"properties": ["heading", "text"], "affordances": []},
    "welcome-action": {"properties": ["label"], "affordances": ["click"]},
    "replay-position": {"properties": ["tick", "total", "paused"], "affordances": []},
    "option": {"properties": ["label", "detail", "selected"], "affordances": ["click"]}}

var stageStates* = initTable[string, StageState]()
  ## The run's stage state, by its root (one run per process).

proc removeStageRoots() {.noconv.} =
  for _, s in stageStates: s.removeStage()

proc stageState(ctx: TermContext): StageState =
  if not ctx.state.hasKey("$stage"):
    let s = newStageState()
    ctx.state["$stage"] = %s.root
    if stageStates.len == 0: addExitProc(removeStageRoots)
    stageStates[s.root] = s
  stageStates[ctx.state["$stage"].getStr]

proc launchTui(ctx: TermContext; s: StageState) =
  var args = @["--theme=dark"]
  if s.launch.keymap.len > 0: args.add "--keymap=" & s.launch.keymap
  for f in s.launch.flags: args.add f
  if s.launch.recording.len > 0:
    args.add s.launch.recording
  else:
    args.add "--edit"
    args.add(if s.launch.file.len > 0: s.launch.project / s.launch.file else: s.launch.project)
  let w = if s.launch.width > 0: s.launch.width else: 200
  let h = if s.launch.height > 0: s.launch.height else: 50
  var env: seq[(string, string)] = @[("TERM", "xterm-256color"), ("LANG", "en_US.UTF-8"),
                                     ("COLORTERM", "truecolor")]
  for k, v in s.launch.env: env.add (k, v)
  var b = newTuiTest(tuiBinary(), args).width(w).height(h).transcript(true)
    .workDir(s.launch.workDir)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
  for (k, v) in env: b = b.envSet(k, v)
  ctx.sess = b.spawn()
  ctx.running = true
  ctx.width = w
  ctx.height = h

proc keyProtocolOf(ctx: TermContext): KeyProtocol =
  ## The key reporting the application turned on, read off the bytes it wrote
  ## to its terminal (nim-termctl's `KittyPushDisambiguateSeq` /
  ## `ModifyOtherKeysOnSeq`): a chord its keymap binds is deliverable or not
  ## by that, as the application itself decides (Base-Keymaps §7).
  let bytes = ctx.sess.transcriptBytes()
  let kitty = bytes.rfind("\e[>1u")
  let mok = bytes.rfind("\e[>4;2m")
  if kitty < 0 and mok < 0: kpLegacy
  elif kitty > mok: kpKitty
  else: kpModifyOtherKeys

proc scopeOf(tree: Tree): ResolverScope =
  ## What the router's facts need, read off the screen.
  result.product = if tree.root.props{"mode"}.getStr == "edit": pmEdit else: pmDebug
  result.replayLoaded = result.product == pmDebug
  for n in tree.kids(tree.root):
    case n.role
    of "editor":
      if n.focused:
        result.editorFocused = true
        result.editorReadOnly = result.product == pmDebug
    of "omnibox":
      if n.props{"focused"}.getBool: result.paletteOpen = true
    else: discard

proc ctTermBinding*(): TermBinding =
  TermBinding(
    name: "codetracer-terminal",
    tracking: mtMove,
    roles: roles(),
    stage: proc (ctx: TermContext; use: string; args: JsonNode) =
      let s = ctx.stageState()
      s.runStage(use, args)
      if use in ["open-recording", "open-project"]:
        ctx.launchTui(s),
    surface: proc (ctx: TermContext): Tree =
      readSurface(ctx.grid()),
    condition: proc (ctx: TermContext; name: string): Option[bool] =
      case name
      of "replay-idle":
        # the top bar's trace summary: the replay is paused at a tick
        let top = ctx.grid().rowText(0)
        some(top.contains("[ct]") and top.contains("tick: ") and top.contains("[PAUSED]") and
             not top.contains("trace: - "))
      of "ready":
        # --- terminal --- the front-end drew its first frame: the status
        # row carries the product mode
        let g = ctx.grid()
        let status = g.rowText(g.height - 1)
        some(status.contains("[DEBUG]") or status.contains("[EDIT]"))
      else: none(bool),
    resolveChord: proc (ctx: TermContext; operation: string): Option[string] =
      let s = ctx.stageState()
      let base = baseOf(s.launch.keymap)
      let router = routerFor(base, KeyDelivery(frontEnd: feTerminal, platform: hostPlatform(),
                                               keyProtocol: ctx.keyProtocolOf()),
                             s.configDir / "keybindings.json")
      router.resolveChord(operation, scopeOf(readSurface(ctx.grid()))),
    anchor: proc (ctx: TermContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      if n.role == "call" and anchor == "name":
        # --- terminal --- the call's name: the first letter after the
        # indentation and the fold glyph
        let row = int(n.y)
        let g = ctx.grid()
        var c = int(n.x)
        while c < int(n.x + n.w) - 1 and g.rows[row][c].text in [" ", "", "▾", "▸", "▼", "▶", "·", "•"]: inc c
        return some((row, c + 1))
      if n.role == "call" and anchor == "expander":
        # --- terminal --- the fold glyph before the call's name
        let row = int(n.y)
        let g = ctx.grid()
        for c in int(n.x) ..< int(n.x + n.w):
          if g.rows[row][c].text in ["▾", "▸", "▼", "▶"]: return some((row, c))
        return none((int, int))
      if n.role == "row" and anchor in ["text-start", "text-end"]:
        # --- terminal --- the first / last character of the row's text
        let row = int(n.y)
        let g = ctx.grid()
        var a = int(n.x)
        var b = int(n.x + n.w) - 1
        while a < b and g.rows[row][a].text in [" ", "", "▏"]: inc a
        while b > a and g.rows[row][b].text in [" ", "", "▏", "▕"]: dec b
        return some((row, if anchor == "text-start": a else: b))
      if n.role != "line": return none((int, int))
      let row = int(n.y)
      let g = ctx.grid()
      let text = g.rowText(row, int(n.x), int(n.x + n.w))
      # the text column: after the breakpoint lane, the number, two blanks,
      # the pointer lane and two blanks
      var i = 1
      let rs = text
      while i < rs.len and rs[i] == ' ': inc i
      while i < rs.len and rs[i] in Digits: inc i
      let textCol = int(n.x) + i + 5
      case anchor
      of "gutter": some((row, int(n.x)))
      of "text-start":
        var c = textCol
        while c < int(n.x + n.w) - 1 and g.rows[row][c].text == " ": inc c
        some((row, c))
      of "text-end":
        var c = int(n.x + n.w) - 1
        while c > textCol and g.rows[row][c].text in [" ", ""]: dec c
        some((row, c))
      else:
        if anchor.startsWith("column(") and anchor.endsWith(")"):
          some((row, textCol + parseInt(anchor[7 .. ^2]) - 1))
        else: none((int, int)),
    act: proc (ctx: TermContext; use: string; args: JsonNode) =
      # --- terminal --- the pack's actions: changes another program makes
      # in the stage's project folder while the front-end runs
      let s = ctx.stageState()
      let file = args{"file"}.getStr
      if file.len == 0 or file.isAbsolute or file.contains(".."):
        raise newException(ValueError, use & ": '" & file &
                           "' is not a file inside the stage's project folder")
      let path = s.launch.project / file
      case use
      of "write-file":
        createDir(path.parentDir)
        writeFile(path, args{"content"}.getStr)
      of "make-read-only":
        setFilePermissions(path, getFilePermissions(path) - {fpUserWrite, fpGroupWrite, fpOthersWrite})
      else:
        raise newException(ValueError, "the terminal binding performs no action '" & use & "'"))
