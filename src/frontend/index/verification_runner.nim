## index/verification_runner.nim — **the desktop's Verification runner**
## (Verification-Payload-Contract-v1.md §11, "Who runs Verno").
##
## The terminal and the GPUI window run the project's declared Verno action
## through `host/project_action_runner` (a process launcher the renderer, a
## `nim js` program, cannot use). This is the desktop's launcher: the
## renderer (`ui/verification.nim`) reads the project's task files, picks the
## action, and asks for it (`CODETRACER::verification-start` — the argv
## `project_actions.launchArgv` made and the directory it runs in); the main
## process runs it and answers:
##
## * `CODETRACER::verification-running` — the process exists;
## * `CODETRACER::verification-output` {stream, data} — stdout and stderr on
##   two pipes, each delivered LINE BY LINE (a write that ends mid-line waits
##   for the rest), so the renderer's reader never sees half a line as a line;
## * `CODETRACER::verification-exit` {code, signaled, cancelled} — the exit
##   code (`null` when a signal ended it) and whether the user stopped it;
## * `CODETRACER::verification-failed-to-start` {reason} — nothing ran (the
##   commonest case: a verifier that is not installed). That is a fact about
##   this machine, not about the program, and the renderer says so.
##
## The argv is launched directly, never through a shell: a `tasks.json` task
## is a program plus arguments, and a `package.json` script already arrives
## as the platform shell's own argv (`/bin/sh -c <script>`).
##
## `CODETRACER::verification-cancel` stops it: the process and everything it
## started (its own process group, so a solver it spawned goes too) get
## SIGTERM, and SIGKILL two seconds later if any is still there. The app
## quitting stops it the same way: a proof attempt must not outlive the
## window that asked for it.
##
## One run at a time, as on every front-end: the renderer offers no Run while
## one is in flight, and a start that arrives anyway is refused here.
##
## The structured report (`target/verno-report.json`) is NOT read here: the
## renderer reads it when the exit arrives, by VN-M4's rule (only after the
## run, so an earlier run's file cannot pass for this one's).

import std / [ jsffi ]

import electron_vars

proc verificationRunnerStart(argv: JsObject; cwd: cstring;
                             send: proc(message: cstring; payload: JsObject))
  {.importjs: """(function(argv, cwd, send) {
    var g = globalThis.__ctVerificationRunner ||
            (globalThis.__ctVerificationRunner = {});
    if (g.child) {
      send('CODETRACER::verification-failed-to-start',
           {reason: 'a verification run is already in flight; Stop it first'});
      return;
    }
    if (!argv || argv.length === 0) {
      send('CODETRACER::verification-failed-to-start',
           {reason: 'the action names no program'});
      return;
    }
    var cp = require('child_process');
    var posix = process.platform !== 'win32';
    var child;
    g.cancelled = false;
    try {
      child = cp.spawn(argv[0], argv.slice(1),
                       {cwd: cwd || undefined, shell: false, detached: posix,
                        env: process.env, windowsHide: true});
    } catch (e) {
      send('CODETRACER::verification-failed-to-start', {reason: e.message});
      return;
    }
    g.child = child;
    var spawned = false;
    child.on('spawn', function() {
      spawned = true;
      send('CODETRACER::verification-running', {});
    });
    var pending = {stdout: '', stderr: ''};
    function feed(stream, chunk) {
      var text = pending[stream] + chunk.toString('utf8');
      var cut = text.lastIndexOf('\n');
      if (cut < 0) { pending[stream] = text; return; }
      pending[stream] = text.slice(cut + 1);
      send('CODETRACER::verification-output',
           {stream: stream, data: text.slice(0, cut + 1)});
    }
    child.stdout.on('data', function(c) { feed('stdout', c); });
    child.stderr.on('data', function(c) { feed('stderr', c); });
    function stopGroup() {
      try {
        if (posix) process.kill(-child.pid, 'SIGTERM'); else child.kill('SIGTERM');
      } catch (e) {}
    }
    process.once('exit', stopGroup);
    var ended = false;
    function end(code, signal) {
      if (ended) return;
      ended = true;
      process.removeListener('exit', stopGroup);
      ['stdout', 'stderr'].forEach(function(s) {
        if (pending[s].length > 0) {
          send('CODETRACER::verification-output',
               {stream: s, data: pending[s] + '\n'});
          pending[s] = '';
        }
      });
      if (g.killTimer) { clearTimeout(g.killTimer); g.killTimer = null; }
      g.child = null;
      send('CODETRACER::verification-exit',
           {code: (typeof code === 'number') ? code : null,
            signaled: typeof code !== 'number',
            cancelled: !!g.cancelled});
    }
    child.on('error', function(e) {
      if (!spawned && !ended) {
        // ENOENT and friends: the program never ran.
        ended = true;
        process.removeListener('exit', stopGroup);
        g.child = null;
        send('CODETRACER::verification-failed-to-start', {reason: e.message});
        return;
      }
      end(null, 'SIGTERM');
    });
    child.on('close', function(code, signal) { end(code, signal); });
  })(#, #, #)""".}

proc verificationRunnerCancel(): bool {.importjs: """(function() {
    var g = globalThis.__ctVerificationRunner;
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

proc onVerificationStart*(sender: JsObject; response: JsObject) =
  ## `CODETRACER::verification-start` {argv, cwd}: run it.
  let cwd = if response["cwd"].isUndefined or response["cwd"].isNull: cstring""
            else: response["cwd"].to(cstring)
  verificationRunnerStart(response["argv"], cwd, sendToRenderer)

proc onVerificationCancel*(sender: JsObject; response: JsObject) =
  ## `CODETRACER::verification-cancel`: stop the run in flight, if any.
  discard verificationRunnerCancel()
