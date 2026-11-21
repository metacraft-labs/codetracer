## ct_lens_plugins.nim — the `ct-lens` plugin package: one native executable
## hosting three plugins, written against `codetracer_plugin_sdk`.
##
## `ct-lens.history` — LINE HISTORY. Wherever the debugger stops, it asks git
## which commits last changed the function the stop is in (`git log -L`), and
## shows them in a pane and a status item. git runs as a child process of the
## plugin, started in a handler and finished in the SDK's idle loop
## (`lens_tools`), so a slow repository never holds the other plugin.
##
## `ct-lens.watch` — CHANGED VALUES. It reads the core State ViewModel's own
## change set (`StateVM.valueChanges`) and the locals from the plugin's mirror
## of the session, and shows what the last step changed, old value and new.
## Its command, bound to `F7`, adds every changed value as a watch in
## the core State pane through the action relay (`state.addWatch`). The
## command's enablement and the context key its binding's `when` reads are
## pushed whenever the change set moves. It also publishes per-type
## visualisers, presented at the plugin tier.
##
## `ct-lens.jump` — JUMP TO CALL. `Shift+F7` pushes a modal layer over the
## window: the status line lists up to nine calls from the loaded calltrace,
## a digit jumps to one (`calltrace.doubleClickEntry`, relayed) and `q`
## cancels. Its docked pane lists the same calls at any time, and a row
## activated there (Enter, or a click: a `view-event`) is a jump too. Because
## it captures the window's keys, the host runs it in a process of its own,
## apart from the other two.
##
## Line history also decorates the editor: the first line of the function the
## debugger is in carries the commit that last changed it.

import std/[algorithm, os, sets, strutils, tables]

import codetracer_plugin_sdk
import lens_tools
import lens_watch

const
  HistoryId = "ct-lens.history"
  JumpId = "ct-lens.jump"
  PackageName = "ct-lens"
  Version = "0.1.0"

let runner = newToolRunner()

# ---------------------------------------------------------------------------
# Line history
# ---------------------------------------------------------------------------

type
  HistoryTarget = object
    file: string
    first, last: int
    function: string

  HistoryState = ref object
    key: string
    run: ToolRun
    target: HistoryTarget
    rows: seq[seq[string]]
    message: string
    running: bool
    decorated: string
      ## The document the last decoration went to, cleared when it moves.

proc targetOf(p: Plugin): HistoryTarget =
  ## The source range the debugger is stopped in: the stop's function when
  ## the stop knows one that holds the line, the line alone otherwise.
  let s = p.session
  if s.isNil or s.store.isNil: return
  let d = s.store.debugger.val
  result.file = d.location.file
  let line = d.location.line
  if result.file.len == 0 or line <= 0:
    return HistoryTarget()
  let st = s.store.stop.val
  if st.path == result.file and st.functionFirst > 0 and
     st.functionFirst <= line and line <= st.functionLast:
    result.first = st.functionFirst
    result.last = st.functionLast
    result.function = st.functionName
  else:
    result.first = line
    result.last = line
    result.function = st.functionName

proc keyOf(t: HistoryTarget): string =
  t.file & ":" & $t.first & "-" & $t.last

proc historyArgv(git, file: string; first, last, limit: int): seq[string] =
  ## `git log -L` over one range of one file, one commit per line, no diff.
  @[git, "-C", file.parentDir, "log", "-n", $limit, "--date=short",
    "--format=%h%x09%ad%x09%an%x09%s", "-s",
    "-L", $first & "," & $last & ":" & file.extractFilename]

proc parseHistory(output: string): seq[seq[string]] =
  for line in output.splitLines:
    let cols = line.split('\t')
    if cols.len >= 4:
      result.add @[cols[0], cols[1], cols[2], cols[3 .. ^1].join("\t")]

proc historyTitle(t: HistoryTarget): string =
  let where = t.file.extractFilename & ":" &
    (if t.first == t.last: $t.first else: $t.first & "-" & $t.last)
  if t.function.len > 0: "History of " & t.function & " (" & where & ")"
  else: "History of " & where

proc pushHistory(p: Plugin; h: HistoryState) =
  var kids: seq[ViewNode]
  if h.target.file.len == 0:
    kids.add viewText("history.message", "waiting for the debugger to stop")
  elif h.running:
    kids.add viewText("history.message", "asking git…")
  elif h.message.len > 0:
    kids.add viewText("history.message", h.message)
  elif h.rows.len == 0:
    kids.add viewText("history.message", "no commit changed these lines")
  else:
    kids.add viewTable("history.commits", @["commit", "date", "author", "subject"],
                       h.rows)
  p.pushView("history", viewTreeNode("history.root",
    (if h.target.file.len == 0: "Line history" else: historyTitle(h.target)),
    kids, expanded = true))
  let status =
    if h.target.file.len == 0 or h.running: "history: …"
    elif h.message.len > 0: "history: unavailable"
    elif h.rows.len == 0: "history: none"
    else: "history: " & h.rows[0][0] & " " & h.rows[0][1] &
          " (" & $h.rows.len & (if h.rows.len == 1: " commit)" else: " commits)")
  p.pushStatus("history.status", viewText("history.status", status))
  # The editor decoration: on the first line of the range, the commit that
  # last changed it, the way a blame lens reads.
  let doc = h.target.file
  if h.decorated.len > 0 and h.decorated != doc:
    p.pushDecorations(h.decorated, newJArray())
    h.decorated = ""
  if doc.len > 0:
    var items = newJArray()
    if not h.running and h.message.len == 0 and h.rows.len > 0:
      let r = h.rows[0]
      items.add %*{"line": h.target.first, "glyph": "±", "kind": "marker",
                   "text": "history: " & r[0] & " " & r[1] & " " & r[3]}
    p.pushDecorations(doc, items)
    h.decorated = doc

proc startHistory(p: Plugin; h: HistoryState; force = false) =
  let t = p.targetOf()
  let key = t.keyOf
  if not force and key == h.key: return
  h.key = key
  h.target = t
  if not h.run.isNil: h.run.cancel()
  h.run = nil
  h.rows = @[]
  h.message = ""
  h.running = false
  if t.file.len > 0:
    if not fileExists(t.file):
      h.message = "the source is not on this machine: " & t.file
    else:
      let git = p.settings{"git"}.getStr("git")
      let limit = max(1, p.settings{"limit"}.getInt(5))
      let timeout = max(100, p.settings{"timeoutMs"}.getInt(15_000))
      h.running = true
      let plugin = p
      let state = h
      h.run = runner.start(HistoryId,
        historyArgv(git, t.file, t.first, t.last, limit), t.file.parentDir,
        timeout, proc(r: ToolRun) =
          if r != state.run: return
          state.running = false
          state.run = nil
          if r.startError.len > 0:
            state.message = "could not run " & git & ": " & r.startError
          elif r.timedOut:
            state.message = git & " did not answer within " & $timeout & " ms"
          elif r.exitCode != 0:
            let first = r.output.strip.splitLines
            state.message = git & ": " &
              (if first.len > 0: first[0] else: "exit status " & $r.exitCode)
          else:
            state.rows = parseHistory(r.output)
          if plugin.active: plugin.pushHistory(state))
  p.pushEnablement("history.refresh", t.file.len > 0,
                   if t.file.len > 0: "" else: "the debugger has not stopped yet")
  p.pushHistory(h)

proc setupHistory(sdk: PluginSdk) =
  let h = sdk.addPlugin(HistoryId, Version)
  var state = HistoryState()
  h.onActivate = proc(p: Plugin) =
    state = HistoryState()
    p.pushEnablement("history.refresh", false, "the debugger has not stopped yet")
    p.startHistory(state, force = true)
  h.onSignals = proc(p: Plugin) =
    p.startHistory(state)
  h.onSettingsChanged = proc(p: Plugin) =
    p.startHistory(state, force = true)
  h.onDeactivate = proc(p: Plugin) =
    runner.stopOwnedBy(HistoryId)
  h.onInvoke("history.refresh", proc(p: Plugin; args: JsonNode; req: Request) =
    p.startHistory(state, force = true)
    p.done(req))

# ---------------------------------------------------------------------------
# Jump to call
# ---------------------------------------------------------------------------

type
  JumpChoice = object
    lineIndex: int64
    label: string

  JumpState = ref object
    token: string
    choices: seq[JumpChoice]
      ## What the open mode offers, fixed when it opened.
    listed: seq[JumpChoice]
      ## What the docked pane lists now; a row activated in it (Enter, or a
      ## click) is a jump.
    lastJump: string
    fingerprint: string

const JumpKeys = "123456789"

proc jumpChoices(p: Plugin): seq[JumpChoice] =
  ## Up to nine calls from the loaded calltrace: the calls after the one the
  ## debugger is in first, then the ones before it.
  let s = p.session
  if s.isNil or s.store.isNil: return
  let lines = s.store.calltrace.lines.val
  let start = s.store.calltrace.startLineIndex.val
  let current = s.store.calltrace.currentLineIndex.val
  var after, before: seq[JumpChoice]
  for i, l in lines:
    let idx = start + i.int64
    let name = if l.displayName.len > 0: l.displayName else: l.name
    let c = JumpChoice(lineIndex: idx, label: name & " (" &
      l.location.file.extractFilename & ":" & $l.location.line & ")")
    if idx > current: after.add c
    elif idx < current: before.add c
  for c in after & before:
    if result.len >= JumpKeys.len: break
    result.add c

proc showChoices(p: Plugin; j: JumpState)

proc pushJumpState(p: Plugin; j: JumpState) =
  let choices = p.jumpChoices()
  var fp = $choices.len & "|" & j.token
  for c in choices: fp.add "|" & $c.lineIndex & "=" & c.label
  if fp == j.fingerprint: return
  j.fingerprint = fp
  j.listed = choices
  p.pushEnablement("jump.open", choices.len > 0,
                   if choices.len > 0: "" else: "the calltrace has not loaded yet")
  p.showChoices(j)

proc showChoices(p: Plugin; j: JumpState) =
  var opts: seq[ViewOption]
  var line: seq[string]
  let open = j.token.len > 0
  let shown = if open: j.choices else: j.listed
  for i, c in shown:
    opts.add ViewOption(id: "call." & $i, label:
      (if open: $JumpKeys[i] & "  " else: "") & c.label)
  for i, c in j.choices:
    line.add $JumpKeys[i] & " " & c.label.split(' ')[0]
  p.pushView("calls", viewTreeNode("calls.root", "Jump to call",
    @[viewList("calls.list", opts),
      viewText("calls.hint", if open: "press a digit to jump, q to cancel"
                             else: "Enter on a call jumps to it; Shift+F7 numbers them")] &
      (if j.lastJump.len > 0: @[viewText("calls.last", "jumped to " & j.lastJump)]
       else: @[]),
    expanded = true))
  p.pushStatus("jump.status", viewText("jump.status",
    if j.token.len == 0: "" else: "jump: " & line.join("  ")))
  for op in ["jump.pick", "jump.close"]:
    p.pushEnablement(op, open, if open: "" else: "choose a call first (Shift+F7)")

proc closeJump(p: Plugin; j: JumpState) =
  if j.token.len > 0:
    p.popLayer(j.token)
  j.token = ""
  j.choices = @[]
  p.showChoices(j)

proc setupJump(sdk: PluginSdk) =
  let jp = sdk.addPlugin(JumpId, Version)
  var state = JumpState()
  jp.onActivate = proc(p: Plugin) =
    state = JumpState()
    p.pushEnablement("jump.open", false, "the calltrace has not loaded yet")
    p.showChoices(state)
    p.pushJumpState(state)
  jp.onSignals = proc(p: Plugin) =
    p.pushJumpState(state)
  jp.onViewEvent = proc(p: Plugin; surface: string; event: JsonNode) =
    # A row of the docked pane activated (Enter, or a click): jump to it.
    if surface != "calls" or event{"transition"}.getStr("") != "trActivate":
      return
    let shown = if state.token.len > 0: state.choices else: state.listed
    let at = event{"index"}.getInt(-1)
    if at >= 0 and at < shown.len:
      p.relay("calltrace", "doubleClickEntry",
              %*{"lineIndex": shown[at].lineIndex})
      state.lastJump = shown[at].label
      if state.token.len > 0: p.closeJump(state)
      else: p.showChoices(state)
  jp.onLayerPopped = proc(p: Plugin; token, reason: string) =
    if token == state.token:
      state.token = ""
      state.choices = @[]
      p.showChoices(state)
  jp.onInvoke("jump.open", proc(p: Plugin; args: JsonNode; req: Request) =
    if state.token.len > 0:
      p.done(req)
      return
    state.choices = p.jumpChoices()
    if state.choices.len == 0:
      p.fail(req, "the calltrace has not loaded yet")
      return
    var bs: seq[PluginBinding]
    for i in 0 ..< state.choices.len:
      bs.add PluginBinding(key: $JumpKeys[i], op: "jump.pick", scope: "window")
    bs.add PluginBinding(key: "q", op: "jump.close", scope: "window")
    state.token = p.pushLayer("window", bs, "jump")
    p.showChoices(state)
    p.done(req))
  jp.onInvoke("jump.pick", proc(p: Plugin; args: JsonNode; req: Request) =
    let key = args{"key"}.getStr("")
    let at = JumpKeys.find(key)
    if at >= 0 and at < state.choices.len:
      p.relay("calltrace", "doubleClickEntry",
              %*{"lineIndex": state.choices[at].lineIndex})
      state.lastJump = state.choices[at].label
    p.closeJump(state)
    p.done(req))
  jp.onInvoke("jump.close", proc(p: Plugin; args: JsonNode; req: Request) =
    p.closeJump(state)
    p.done(req))

when isMainModule:
  let sdk = newPluginSdk(PackageName)
  setupHistory(sdk)
  setupWatch(sdk)
  setupJump(sdk)
  runner.onError = proc(owner, message: string) =
    let p = sdk.plugins.getOrDefault(owner, nil)
    if not p.isNil: p.log(message, "error")
  sdk.idle.add proc() = runner.pump()
  sdk.run()
