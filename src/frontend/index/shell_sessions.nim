## index/shell_sessions.nim — the desktop's Shell panes' shell sessions.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.2,
## §7.7.
##
## A Shell pane's model (`viewmodels/shell_vm.nim`) runs in the renderer; its
## shell needs a pseudo-terminal, which a JavaScript process cannot open. So
## for each pane the main process runs `ct shell-session` — the session the
## terminal and the GPUI window run in-process (`common/shell_session.nim`) —
## and relays its JSON lines both ways, untouched:
##
##   renderer → here: `CODETRACER::shell-session-start` `{id, cols, rows, cwd}`,
##                    `…-input` `{id, data}`, `…-resize` `{id, cols, rows}`,
##                    `…-stop` `{id}`;
##   here → renderer: `CODETRACER::shell-session-message` `{id, message}` —
##                    `message` one wire line (`{"output"}`, `{"event"}`,
##                    `{"exit"}`, `{"failed"}`), which the pane's model reads
##                    with `receiveUpdate`.
##
## The relay keeps the session's order: lines are forwarded as `ct
## shell-session` wrote them, so an event still follows the output written
## before it (§7.4).

import std/[asyncjs, jsffi, json, strutils]

import electron_vars
import ../lib/[jslib, electron_lib]
import ../../common/[ct_logging, paths]

type
  ShellSessionProcess = ref object
    child: JsObject
    pending: cstring

var shellSessions = JsAssoc[cstring, ShellSessionProcess]{}

proc nodeSpawn(exe: cstring; args: seq[cstring]; cwd: cstring): JsObject {.importjs: """
  (function (exe, args, cwd) {
    const cp = require('child_process');
    const opts = { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true };
    if (cwd && cwd.length > 0) { opts.cwd = cwd; }
    return cp.spawn(exe, args, opts);
  })(#, #, #)""".}

proc sendMessage(id: cstring; line: cstring) =
  mainWindow.webContents.send(cstring"CODETRACER::shell-session-message",
                              js{id: id, message: line})

proc writeTo(child: JsObject; line: cstring) {.importjs: """
  (function (child, line) {
    if (child.stdin && child.stdin.writable) { child.stdin.write(line + '\n'); }
  })(#, #)""".}

proc writeLine(s: ShellSessionProcess; line: cstring) =
  writeTo(s.child, line)

proc toB64(data: cstring): cstring {.importjs:
  "Buffer.from(#, 'utf8').toString('base64')".}

proc onShellSessionStart*(sender: js; request: JsObject) {.async.} =
  ## Run `ct shell-session` for the pane `request.id`, at its size.
  let id = request["id"].to(cstring)
  if shellSessions.hasKey(id):
    return
  let cols = request["cols"].to(int)
  let rows = request["rows"].to(int)
  let cwd = request["cwd"].to(cstring)
  var args = @[cstring"shell-session", cstring"--cols", cstring($cols),
               cstring"--rows", cstring($rows)]
  if not cwd.isNil and cwd.len > 0:
    args.add cstring"--cwd"
    args.add cwd
  let child = nodeSpawn(cstring(codetracerExe), args, cwd)
  let session = ShellSessionProcess(child: child, pending: cstring"")
  shellSessions[id] = session
  child["stdout"].toJs.on(cstring"data", proc(chunk: JsObject) =
    session.pending = session.pending & chunk.toString().to(cstring)
    var text = $session.pending
    while true:
      let nl = text.find('\n')
      if nl < 0: break
      let line = text[0 ..< nl].strip
      text = text[nl + 1 .. ^1]
      if line.len > 0:
        sendMessage(id, cstring(line))
    session.pending = cstring(text))
  child["stderr"].toJs.on(cstring"data", proc(chunk: JsObject) =
    warnPrint "shell-session " & $id & ": " & $chunk.toString().to(cstring))
  child.toJs.on(cstring"error", proc(err: JsObject) =
    sendMessage(id, cstring("{\"failed\": " &
      escapeJson("could not run ct shell-session: " &
                 $err["message"].to(cstring)) & "}"))
    shellSessions.del(id))
  child.toJs.on(cstring"exit", proc(code: JsObject) =
    shellSessions.del(id))

proc onShellSessionInput*(sender: js; request: JsObject) {.async.} =
  let id = request["id"].to(cstring)
  if not shellSessions.hasKey(id): return
  shellSessions[id].writeLine(cstring("{\"input\": \"" &
    $toB64(request["data"].to(cstring)) & "\"}"))

proc onShellSessionResize*(sender: js; request: JsObject) {.async.} =
  let id = request["id"].to(cstring)
  if not shellSessions.hasKey(id): return
  shellSessions[id].writeLine(cstring("{\"resize\": {\"cols\": " &
    $request["cols"].to(int) & ", \"rows\": " & $request["rows"].to(int) & "}}"))

proc onShellSessionStop*(sender: js; request: JsObject) {.async.} =
  let id = request["id"].to(cstring)
  if not shellSessions.hasKey(id): return
  shellSessions[id].writeLine(cstring("{\"close\": true}"))
