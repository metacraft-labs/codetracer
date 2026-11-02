## index/build_runner.nim — **the desktop's build runner**
## (Build-Output-Pane.md §4.2, §3.2 Stop).
##
## Until this module the desktop's main process ran no build: the BUILD
## panel's `CODETRACER::build-*` messages had no producer, the toolbar's Build
## was refused, and ■ Stop stopped nothing. Now the renderer asks for a build
## (`CODETRACER::build-start` — a task's or a typed command, and the directory
## it runs in) and the main process runs it as the terminal's runner does
## (`tui/host/build_runner`): through the shell, stdout and stderr on two
## pipes, each delivered LINE BY LINE (a write that ends mid-line waits for
## the rest, so the renderer's reader never sees half a line as a line), and
## the exit code with whether the user stopped it.
##
## `CODETRACER::build-cancel` stops it: the shell and everything it started
## (its own process group, so `make`'s children go too) get SIGTERM, and
## SIGKILL two seconds later if any is still there. The verdict says
## "cancelled" (`build-code` carries `cancelled`).
##
## One build at a time, as on every front-end: a start while one runs is
## answered with a line on stderr and no second process.

import std / [ jsffi ]

import electron_vars

proc buildRunnerStart(command, cwd: cstring;
                      send: proc(message: cstring; payload: JsObject))
  {.importjs: """(function(command, cwd, send) {
    var g = globalThis.__ctBuildRunner || (globalThis.__ctBuildRunner = {});
    if (g.child) {
      send('CODETRACER::build-stderr',
           {data: 'a build is already running; stop it first\n'});
      return;
    }
    var cp = require('child_process');
    var posix = process.platform !== 'win32';
    var child;
    g.cancelled = false;
    send('CODETRACER::build-command', {command: command});
    try {
      child = cp.spawn(command, [], {cwd: cwd || undefined, shell: true,
                                     detached: posix, env: process.env,
                                     windowsHide: true});
    } catch (e) {
      send('CODETRACER::build-stderr', {data: 'could not start: ' + e.message + '\n'});
      send('CODETRACER::build-code', {code: 127, cancelled: false, runner: true});
      return;
    }
    g.child = child;
    var pending = {stdout: '', stderr: ''};
    function feed(stream, chunk) {
      var text = pending[stream] + chunk.toString('utf8');
      var cut = text.lastIndexOf('\n');
      if (cut < 0) { pending[stream] = text; return; }
      pending[stream] = text.slice(cut + 1);
      send('CODETRACER::build-' + stream, {data: text.slice(0, cut + 1)});
    }
    child.stdout.on('data', function(c) { feed('stdout', c); });
    child.stderr.on('data', function(c) { feed('stderr', c); });
    var ended = false;
    function end(code, signal) {
      if (ended) return;
      ended = true;
      ['stdout', 'stderr'].forEach(function(s) {
        if (pending[s].length > 0) {
          send('CODETRACER::build-' + s, {data: pending[s] + '\n'});
          pending[s] = '';
        }
      });
      if (g.killTimer) { clearTimeout(g.killTimer); g.killTimer = null; }
      g.child = null;
      var exit = (typeof code === 'number') ? code : (signal ? 128 + 15 : 1);
      send('CODETRACER::build-code', {code: exit, cancelled: !!g.cancelled,
                                      runner: true});
    }
    child.on('error', function(e) {
      send('CODETRACER::build-stderr', {data: 'could not start: ' + e.message + '\n'});
      end(127, null);
    });
    child.on('close', function(code, signal) { end(code, signal); });
  })(#, #, #)""".}

proc buildRunnerCancel(): bool {.importjs: """(function() {
    var g = globalThis.__ctBuildRunner;
    if (!g || !g.child) return false;
    var child = g.child;
    g.cancelled = true;
    function signal(name) {
      try {
        if (process.platform !== 'win32') process.kill(-child.pid, name);
        else child.kill(name);
      } catch (e) {
        try { child.kill(name); } catch (e2) {}
      }
    }
    signal('SIGTERM');
    g.killTimer = setTimeout(function() {
      if (g.child === child) signal('SIGKILL');
    }, 2000);
    return true;
  })()""".}

proc sendToRenderer(message: cstring; payload: JsObject) =
  if not mainWindow.isNil:
    mainWindow.webContents.send(message, payload)

proc onBuildStart*(sender: JsObject; response: JsObject) =
  ## `CODETRACER::build-start` {command, cwd}: run it.
  let command = response["command"].to(cstring)
  let cwd = if response["cwd"].isUndefined or response["cwd"].isNull: cstring""
            else: response["cwd"].to(cstring)
  buildRunnerStart(command, cwd, sendToRenderer)

proc onBuildCancel*(sender: JsObject; response: JsObject) =
  ## `CODETRACER::build-cancel`: stop the running build, if there is one.
  discard buildRunnerCancel()
