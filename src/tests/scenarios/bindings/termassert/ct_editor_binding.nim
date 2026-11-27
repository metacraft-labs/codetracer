## ct_editor_binding.nim — CodeTracer's TermAssert bindings for the editor
## front-ends: Neovim with codetracer.nvim and Emacs with codetracer.el, each
## the real editor in a real pty under TermAssert, its plugin driving the
## real pane server (`codetracer-tui --pane-server`) over a real recording.
##
## * Stages: the pack's one implementation (`../../stages/ct_stages.nim`);
##   `open-recording` / `open-project` start the editor on what the stage
##   prepared, as a user would: `:CodeTracer open <path>` in Neovim,
##   `M-x codetracer-open` in Emacs, from a small user configuration
##   (`NvimInit` / `EmacsInit`) that loads the plugin, turns on line numbers
##   and the mouse, and starts the editor's own server for the binding.
## * The surface: `ct_editor_surface` — the editor says where its windows are
##   (its server, `ctscenario.surface()` / `ctscenario-surface`), and every
##   property is read off the screen inside them.
## * Conditions: `replay-idle` — the source window marks the execution line
##   and the screen has gone quiet; `ready` — the session's panes are shown.
## * The binding resolver (`resolveChord`), per editor: the key the plugin
##   bound to the operation in the window that has the keys — Neovim's
##   buffer-local mapping described `codetracer: <operation>`, Emacs's
##   `where-is-internal` of the operation's command. What CodeTracer's keymap
##   binds is what the plugin binds, so the chord is the user's.
##
## Which editor: `CT_SCENARIO_NVIM` / `CT_SCENARIO_EMACS` (the binaries; else
## `nvim` / `emacs` on PATH, and `emacsclient` beside `emacs`), and the plugin
## checkouts `CODETRACER_NVIM_PLUGIN` / `CODETRACER_EL_PLUGIN` (else the
## workspace siblings `../codetracer.nvim`, `../codetracer.el`).
##
## No mocks: the editors, their plugins, the pty, libvterm, the pane server,
## the replay server and the recordings are the real ones.

import std/[json, options, os, osproc, streams, strutils, tables, times]
import term_assert
import demo_video_script_termassert
import ../../stages/ct_stages
import ./ct_tui_screen
import ./ct_editor_surface
from ./ct_term_binding import grid, tuiBinary, stageStates

type
  EditorKind* = enum
    ekNeovim = "nvim", ekEmacs = "emacs"

const
  NvimInit* = """
-- The scenario's user configuration: the plugin, line numbers, the mouse.
local dir = os.getenv("CT_SCENARIO_EDITOR_DIR")
package.path = dir .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(os.getenv("CT_SCENARIO_PLUGIN"))
vim.cmd("runtime plugin/codetracer.lua")
vim.o.number = true
vim.o.mouse = "a"
vim.o.termguicolors = true
vim.o.signcolumn = "yes"
vim.o.swapfile = false
vim.o.laststatus = 2
vim.o.shadafile = "NONE"
require("codetracer").setup({ cmd = { os.getenv("CODETRACER_TUI"), "--pane-server" } })
-- Edit mode on a project: open the folder, then the file in the session's
-- source window once its layout is up, as a user would with `:edit`.
local file = os.getenv("CT_SCENARIO_FILE") or ""
local function open_file(tries)
  local s = require("codetracer.state").current_session()
  local win = s and s.editor_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  elseif tries > 0 then
    vim.defer_fn(function() open_file(tries - 1) end, 200)
  end
end
vim.api.nvim_create_autocmd("VimEnter", { callback = function()
  vim.cmd("CodeTracer open " .. vim.fn.fnameescape(os.getenv("CT_SCENARIO_TARGET")))
  if file ~= "" then open_file(300) end
end })
"""
  NvimSurface* = """
-- What the binding asks Neovim: the current tab page's windows.
local M = {}
function M.surface()
  local out = { windows = {}, mode = "" }
  local editor_win
  local ok, st = pcall(require, "codetracer.state")
  if ok and st.current_session then
    local s = st.current_session()
    if s then
      out.mode = s.mode or ""
      editor_win = s.editor_win
    end
    out.sessions = vim.tbl_count(st.sessions or {})
  end
  local cur = vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local i = vim.fn.getwininfo(w)[1]
      local b = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(b)
      table.insert(out.windows, {
        buf = name, file = (vim.bo[b].buftype == "" and name or ""),
        row = i.winrow - 1 + (i.winbar or 0), col = i.wincol - 1,
        width = i.width, height = i.height, textoff = i.textoff,
        topline = i.topline, botline = i.botline,
        cursor = vim.api.nvim_win_get_cursor(w)[1],
        editor = (w == editor_win), selected = (w == cur),
      })
    end
  end
  return vim.json.encode(out)
end
--- The key bound to `operation` in the current window's buffer, or "".
function M.key(operation)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
    if m.desc == "codetracer: " .. operation then return m.lhs end
  end
  return ""
end
return M
"""
  EmacsInit* = """
;; The scenario's user configuration: the plugin, line numbers, the mouse.
(setq inhibit-startup-screen t make-backup-files nil auto-save-default nil
      create-lockfiles nil)
(add-to-list 'load-path (getenv "CT_SCENARIO_PLUGIN"))
;; line numbers in every buffer that shows a file, whatever its mode (a
;; .nim or .nr file has none without a package), and not in CodeTracer's panes
(defun ctscenario--line-numbers ()
  (when (and (or buffer-file-name (derived-mode-p 'prog-mode))
             (not (derived-mode-p 'codetracer-pane-mode)))
    (display-line-numbers-mode 1)))
(add-hook 'after-change-major-mode-hook #'ctscenario--line-numbers)
(xterm-mouse-mode 1)
(require 'codetracer)
(setq codetracer-server-program (getenv "CODETRACER_TUI"))
(load (expand-file-name "ctscenario.el" (getenv "CT_SCENARIO_EDITOR_DIR")))
(setq server-socket-dir (getenv "CT_SCENARIO_EDITOR_DIR"))
(server-start)
;; the binding's questions are not the user's business: a question that
;; outlived its time (Emacs busy with a long request) leaves "process server
;; <n> no longer connected to pipe" in the echo area otherwise
(advice-add 'server-sentinel :around
            (lambda (f &rest args) (let ((inhibit-message t)) (apply f args))))
(add-hook 'emacs-startup-hook
          (lambda ()
            (let ((session (codetracer-open (getenv "CT_SCENARIO_TARGET")))
                  (file (getenv "CT_SCENARIO_FILE")))
              ;; Edit mode on a project: the file, in the session's source window
              (when (and file (not (string-empty-p file)))
                (select-window (codetracer--source-window session))
                (find-file file)))))
"""
  EmacsSurface* = """
;;; What the binding asks Emacs: the selected frame's windows.
(require 'json)
(defun ctscenario--window (w source)
  (let* ((b (window-buffer w))
         (e (window-inside-edges w))
         (m (or (car (window-margins w)) 0))
         ;; The line numbers' columns without selecting the window: a
         ;; selection runs the plugin's window hooks, and run from the
         ;; server between the bytes of a mouse report it broke their
         ;; decoding ("m is undefined"). Emacs makes the column as wide as
         ;; the window's largest number, and two more.
         (ln (with-current-buffer b
               (if display-line-numbers
                   (+ 2 (length (number-to-string
                                 (line-number-at-pos (or (window-end w) (point-max))))))
                 0))))
    `((buf . ,(buffer-name b))
      (file . ,(or (buffer-file-name b)
                   (buffer-local-value 'codetracer--recorded-path b) ""))
      (row . ,(nth 1 e)) (col . ,(- (nth 0 e) m))
      (width . ,(+ m (- (nth 2 e) (nth 0 e)))) (height . ,(- (nth 3 e) (nth 1 e)))
      (textoff . ,(+ m ln))
      (topline . ,(with-current-buffer b (line-number-at-pos (window-start w))))
      (cursor . ,(with-current-buffer b (line-number-at-pos (window-point w))))
      (editor . ,(if (eq w source) t :json-false))
      (selected . ,(if (eq w (selected-window)) t :json-false)))))
(defun ctscenario-surface (out)
  "Write the selected frame's windows to OUT, as JSON."
  (let* ((session (ignore-errors (codetracer--current-tab-session)))
         (source (and session (codetracer--source-window session))))
    (with-temp-file out
      (insert (json-encode
               `((mode . ,(or (and session (codetracer-session-mode session)) ""))
                 (sessions . ,(hash-table-count codetracer--sessions))
                 (windows . ,(vconcat (mapcar (lambda (w) (ctscenario--window w source))
                                              (window-list nil 'nomini))))))))
    t))
(defun ctscenario-command (operation out)
  "Write the name of the command that runs OPERATION to OUT."
  (with-temp-file out (insert (symbol-name (codetracer--command-name operation))))
  t)
(defun ctscenario-key (operation out)
  "Write the key bound to OPERATION's command in the selected window to OUT."
  (let* ((cmd (codetracer--command-name operation))
         (k (with-current-buffer (window-buffer (selected-window))
              (where-is-internal cmd nil t))))
    (with-temp-file out (insert (if k (key-description k) "")))
    t))
"""

proc editorBinary(kind: EditorKind): string =
  let given = getEnv(if kind == ekNeovim: "CT_SCENARIO_NVIM" else: "CT_SCENARIO_EMACS")
  result = if given.len > 0: given else: findExe($kind)
  if result.len == 0 or not fileExists(result):
    raise newException(IOError, "the " & $kind & " flavour needs " & $kind &
                       " (CT_SCENARIO_" & ($kind).toUpperAscii & " or on PATH)")

proc pluginDir(kind: EditorKind): string =
  let given = getEnv(if kind == ekNeovim: "CODETRACER_NVIM_PLUGIN" else: "CODETRACER_EL_PLUGIN")
  let name = if kind == ekNeovim: "codetracer.nvim" else: "codetracer.el"
  result = if given.len > 0: given else: repo().parentDir / name
  if not dirExists(result):
    raise newException(IOError, "the " & $kind & " flavour needs the " & name &
                       " plugin at " & result)

proc editorDir(ctx: TermContext): string = ctx.state{"$editor-dir"}.getStr

proc stageState(ctx: TermContext): StageState =
  if not ctx.state.hasKey("$stage"):
    let s = newStageState()
    ctx.state["$stage"] = %s.root
    stageStates[s.root] = s
  stageStates[ctx.state["$stage"].getStr]

proc launchEditor(ctx: TermContext; kind: EditorKind; s: StageState) =
  let dir = s.root / "editor"
  createDir(dir)
  # the editors' servers listen here: Emacs refuses a socket directory others
  # can read
  setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
  ctx.state["$editor-dir"] = %dir
  let target = if s.launch.recording.len > 0: s.launch.recording else: s.launch.project
  let file = if s.launch.recording.len == 0 and s.launch.file.len > 0: s.launch.project / s.launch.file
             else: ""
  var args: seq[string]
  case kind
  of ekNeovim:
    writeFile(dir / "init.lua", NvimInit)
    writeFile(dir / "ctscenario.lua", NvimSurface)
    args = @["--clean", "-u", dir / "init.lua", "--listen", dir / "nvim.sock"]
  of ekEmacs:
    writeFile(dir / "init.el", EmacsInit)
    writeFile(dir / "ctscenario.el", EmacsSurface)
    args = @["-nw", "-Q", "-l", dir / "init.el"]
  let w = if s.launch.width > 0: s.launch.width else: 200
  let h = if s.launch.height > 0: s.launch.height else: 50
  # Neovim is not answered its terminal queries: answered, it finds the left
  # and right margins (DECSLRM, `CSI ? 69 h`) and scrolls a vertical split
  # with them, which asciinema's player and agg do not emulate, so the run's
  # cast and the video drawn from it showed the panes overwritten. Unanswered,
  # Neovim draws as it does on any terminal without them. (DemoVideoScript-pm
  # issues/2026-11-26-neovim-left-right-margins-are-not-reproduced-by-agg-or-asciinema-player.md)
  var b = newTuiTest(editorBinary(kind), args).width(w).height(h).transcript(true)
    .answerQueries(kind == ekEmacs)
    .workDir(if s.launch.workDir.len > 0: s.launch.workDir else: s.root)
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8").envSet("COLORTERM", "truecolor")
    .envSet("CODETRACER_TUI", tuiBinary()).envSet("CT_SCENARIO_TARGET", target)
    .envSet("CT_SCENARIO_FILE", file)
    .envSet("CT_SCENARIO_PLUGIN", pluginDir(kind)).envSet("CT_SCENARIO_EDITOR_DIR", dir)
    .envSet("HOME", s.root)
  for k, v in s.launch.env: b = b.envSet(k, v)
  ctx.sess = b.spawn()
  ctx.running = true
  ctx.width = w
  ctx.height = h

proc answerOf(cmd: seq[string]; timeoutMs = 5000): (string, int) =
  ## Runs one client command; a client still waiting after `timeoutMs` (an
  ## editor that is not reading its server, e.g. at a prompt) is killed and
  ## answers nothing.
  let p = startProcess(cmd[0], args = cmd[1 .. ^1], options = {poStdErrToStdOut})
  defer: p.close()
  let started = epochTime()
  while p.running:
    if (epochTime() - started) * 1000 > float(timeoutMs):
      p.kill()
      discard p.waitForExit()
      return ("", -1)
    sleep(10)
  (p.outputStream.readAll, p.peekExitCode)

proc ask(ctx: TermContext; kind: EditorKind; nvimExpr, emacsForm: string): string =
  ## One question to the running editor, through its own server.
  let dir = ctx.editorDir
  if dir.len == 0: return ""
  case kind
  of ekNeovim:
    # (a socket is no regular file: `fileExists` is false for it)
    let sock = dir / "nvim.sock"
    let (o, rc) = answerOf(@[editorBinary(kind), "--headless", "--clean",
                             "--server", sock, "--remote-expr", nvimExpr])
    if rc != 0: return ""
    result = o.strip
  of ekEmacs:
    # Not while Emacs is still reading what was typed or clicked: a question
    # answered from the server while a mouse report was half read broke its
    # decoding ("m is undefined", the click lost). Asked once the input is
    # read and the screen has been quiet for a moment.
    let started = epochTime()
    while epochTime() - started < 2.0:
      if ctx.sess.pendingInput() <= 0 and ctx.sess.drainOutput(50) == 0: break
    let sock = dir / "server"
    let answer = dir / "answer"
    removeFile(answer)
    let client = editorBinary(kind).parentDir / "emacsclient"
    let (_, rc) = answerOf(@[client, "-s", sock, "--eval",
                             emacsForm.replace("$OUT", escapeJson(answer))])
    if rc != 0 or not fileExists(answer): return ""
    result = readFile(answer)

proc layoutOf(ctx: TermContext; kind: EditorKind): JsonNode =
  let answer = ctx.ask(kind, "luaeval('require(\"ctscenario\").surface()')",
                       "(ctscenario-surface $OUT)")
  # CT_SCENARIO_EDITOR_LAYOUT_LOG: the last answer, kept for reading a failed run
  let log = getEnv("CT_SCENARIO_EDITOR_LAYOUT_LOG")
  if log.len > 0:
    try: writeFile(log, answer) except IOError: discard
  if answer.len == 0: return %*{"windows": [], "mode": ""}
  try: parseJson(answer) except JsonParsingError: %*{"windows": [], "mode": ""}

proc controlRows(kind: EditorKind): seq[int] =
  ## Where the plugin draws its debugger controls: the tab line (Neovim);
  ## the tab bar, under the menu bar (Emacs).
  if kind == ekNeovim: @[0] else: @[1, 0]

proc surfaceOf(ctx: TermContext; kind: EditorKind): Tree =
  readEditorSurface(ctx.grid(), ctx.layoutOf(kind), controlRows(kind))

proc chordOf*(kind: EditorKind; key: string): string =
  ## An editor's spelling of a key as a DemoVideoScript chord: Neovim's
  ## `<S-F10>`, Emacs's `S-<f10>`, both `Shift+F10`.
  var k = key.strip
  if k.len == 0: return ""
  var mods: seq[string]
  if kind == ekNeovim:
    if k.startsWith("<") and k.endsWith(">"): k = k[1 .. ^2]
    while k.len > 2 and k[1] == '-' and k[0] in {'S', 'C', 'M', 'A', 's', 'c', 'm', 'a'}:
      mods.add(case k[0].toUpperAscii
               of 'S': "Shift"
               of 'C': "Ctrl"
               else: "Alt")
      k = k[2 .. ^1]
  else:
    if k.contains(' '): return ""   # a key sequence, not one chord
    while k.len > 2 and k[1] == '-' and k[0] in {'S', 'C', 'M'}:
      mods.add(case k[0]
               of 'S': "Shift"
               of 'C': "Ctrl"
               else: "Alt")
      k = k[2 .. ^1]
    if k.startsWith("<") and k.endsWith(">"): k = k[1 .. ^2]
  if k.len >= 2 and k[0] in {'f', 'F'} and k[1 .. ^1].allCharsInSet(Digits):
    k = "F" & k[1 .. ^1]
  elif k.len > 1:
    k = k[0].toUpperAscii & k[1 .. ^1].toLowerAscii   # Up, Down, Home …
  (mods & @[k]).join("+")

const
  NvimCommands = {"view.generated-c-source": "generated-c", "view.low-level-code": "low-level",
                  "tests.record-at": "test-at-cursor",
                  "session.toggle-product-mode": "mode"}
    ## codetracer.nvim's `:CodeTracer` subcommands for an operation that has
    ## one; any other operation is `:CodeTracer <operation>`.
  EmacsCommands = {"view.generated-c-source": "codetracer-view-generated-c",
                   "view.disassembly": "codetracer-view-disassembly",
                   "editor.trace-static-block-at-cursor": "codetracer-trace-static-block-at-point",
                   "editor.trace-macro-at-cursor": "codetracer-trace-macro-at-point",
                   "editor.trace-constant-at-cursor": "codetracer-trace-constant-at-point",
                   "tests.record-at": "codetracer-test-at-point"}
    ## codetracer.el's commands for an operation that has its own; any other
    ## operation is the command the package defines for it.

proc typed(text: string): seq[string] =
  ## `text` as one chord per character.
  for ch in text:
    result.add(if ch == ' ': "Space" else: $ch)

proc commandChords*(kind: EditorKind; operation, emacsCommand: string): string =
  ## What a user types to run `operation` when no key is bound to it: the
  ## plugin's command, from the editor's command line.
  case kind
  of ekNeovim:
    var sub = operation
    for (op, name) in NvimCommands:
      if op == operation: sub = name
    (typed(":CodeTracer " & sub) & @["Enter"]).join(" ")
  of ekEmacs:
    var cmd = emacsCommand
    for (op, name) in EmacsCommands:
      if op == operation: cmd = name
    if cmd.len == 0: return ""
    (@["Alt+x"] & typed(cmd) & @["Enter"]).join(" ")

proc screenQuiet(ctx: TermContext): bool =
  for _ in 0 ..< 2:
    if ctx.sess.drainOutput(60) != 0: return false
  true

proc roles(): JsonNode =
  %*{
    "window": {"properties": ["mode"], "affordances": []},
    "session-strip": {"properties": ["count", "active"], "affordances": []},
    "editor": {"properties": ["file", "active", "focused", "current-line", "caret-line",
                              "first-visible", "last-visible", "text"],
               "affordances": ["click", "wheel", "focusable"]},
    "line": {"properties": ["number", "text", "current", "caret"],
             "affordances": ["click", "double-click"]},
    "call-trace": {"properties": ["count", "focused"], "affordances": ["wheel", "focusable"]},
    "call": {"properties": ["name", "arguments", "current", "selected"],
             "affordances": ["click", "double-click"]},
    "event-log": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "event": {"properties": ["text", "kind", "current"], "affordances": ["click", "double-click"]},
    "variables": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "variable": {"properties": ["name", "value"], "affordances": ["click", "double-click"]},
    "terminal-output": {"properties": ["count"], "affordances": ["wheel", "focusable"]},
    "pane": {"properties": ["title", "count"], "affordances": ["click", "wheel"]},
    "row": {"properties": ["text"], "affordances": ["click", "double-click"]},
    "toolbar": {"properties": [], "affordances": []},
    "toolbar-button": {"properties": ["label", "enabled"], "affordances": ["click"]}}

proc ctEditorBinding*(kind: EditorKind): TermBinding =
  TermBinding(
    name: "codetracer-" & $kind,
    tracking: mtDrag,
    roles: roles(),
    stage: proc (ctx: TermContext; use: string; args: JsonNode) =
      let s = ctx.stageState()
      s.runStage(use, args)
      if use in ["open-recording", "open-project"]:
        ctx.launchEditor(kind, s),
    surface: proc (ctx: TermContext): Tree =
      ctx.surfaceOf(kind),
    condition: proc (ctx: TermContext; name: string): Option[bool] =
      case name
      of "replay-idle":
        # quiet first: asking the editor makes it redraw (Emacs's echo area
        # and mode line), so a quiet window measured after the question can
        # never come
        some(ctx.screenQuiet() and ctx.surfaceOf(kind).hasExecutionLine)
      of "ready":
        var panes = 0
        for w in ctx.layoutOf(kind){"windows"}.getElems:
          if paneOf(w{"buf"}.getStr)[1].len > 0: inc panes
        some(panes > 0)
      else: none(bool),
    resolveChord: proc (ctx: TermContext; operation: string): Option[string] =
      let key = ctx.ask(kind, "luaeval('require(\"ctscenario\").key(_A)', '" & operation & "')",
                        "(ctscenario-key \"" & operation & "\" $OUT)")
      var chord = chordOf(kind, key)
      if chord.len == 0:
        # no key: the plugin's command for it, typed as a user would
        let cmd = if kind == ekEmacs:
                    ctx.ask(kind, "", "(ctscenario-command \"" & operation & "\" $OUT)")
                  else: ""
        chord = commandChords(kind, operation, cmd)
      if chord.len == 0: none(string) else: some(chord),
    anchor: proc (ctx: TermContext; n: SurfaceNode; anchor: string): Option[(int, int)] =
      let g = ctx.grid()
      let row = int(n.y)
      if n.role == "call" and anchor == "name":
        # the call's name: the first letter after the indentation and the
        # fold glyph
        var c = int(n.x)
        while c < int(n.x + n.w) - 1 and g.rows[row][c].text in [" ", "", "▾", "▸", "▼", "▶", "·", "•"]: inc c
        return some((row, c + 1))
      if n.role in ["line", "row"] and anchor in ["text-start", "text-end"]:
        # a line's text starts after its sign and number columns
        var a = (if n.role == "line": n.props{"$text-column"}.getInt else: int(n.x))
        var b = int(n.x + n.w) - 1
        while a < b and g.rows[row][a].text in [" ", ""]: inc a
        while b > a and g.rows[row][b].text in [" ", "", "▕"]: dec b
        return some((row, if anchor == "text-start": a else: b))
      if n.role == "line" and anchor == "gutter":
        return some((row, int(n.x)))
      none((int, int)),
    act: nil)
