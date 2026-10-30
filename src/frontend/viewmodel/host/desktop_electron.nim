## The desktop instantiation for the Electron renderer (JS backend).
##
## The shipped desktop product's front end is a `nim js` bundle running in an
## Electron renderer with node integration, so this — not `desktop_native.nim` —
## is the instantiation the user's window actually runs. The native one serves
## the ViewModel suites, `ct host` and anything driving the front-end logic out
## of process; between them they cover the two ways the desktop exists.
##
## ## This module is host-side by design
##
## It reaches `require('fs')`, `require('child_process')` and `electron`, and it
## is *supposed* to. It lives in `viewmodel/host/`, whose rule
## `project_action_runner.nim` already states: "a module in here may touch the
## platform, and a module in `viewmodels/` may not." It is outside the host-free
## surface for that reason, and `ci/test/hostfree-build.sh` does not compile it.
##
## ## Why the node calls are `importjs` rather than the existing wrappers
##
## `lib/electron_lib.nim` exposes `fs`, `nodeStartProcess` and `readProcessOutput`
## already, and importing it here would be the obvious move. It is the wrong
## one: `electron_lib` is compiled into the renderer bundle with `ui_imports`
## and drags most of the UI's type graph behind it, so the facade — which
## ViewModels must be able to import — would acquire a dependency on the views.
## The bindings below are two lines each and cost nothing.

when not defined(js):
  {.error: "desktop_electron.nim is the Electron renderer instantiation; " &
           "native builds use desktop_native.nim".}

import std/[jsffi, strutils]
import std/asyncjs

import ../platform/outcome
import ../platform/capabilities
import ./electron_profile
import ../platform/fs
import ../platform/process
import ../platform/vcs
import ../platform/settings
import ../platform/clipboard
import ../platform/download
import ../platform/shell
import ../platform/platform
import ../platform/paths
import ./node_certificate_host

# ---------------------------------------------------------------------------
# Node and Electron bindings
# ---------------------------------------------------------------------------

proc nodeReadFileSync(path: cstring): cstring
  {.importjs: "require('fs').readFileSync(#, 'utf8')".}
proc nodeWriteFileSync(path, content: cstring)
  {.importjs: "require('fs').writeFileSync(#, #, 'utf8')".}
proc nodeAppendFileSync(path, content: cstring)
  {.importjs: "require('fs').appendFileSync(#, #, 'utf8')".}
proc nodeExistsSync(path: cstring): bool
  {.importjs: "require('fs').existsSync(#)".}
proc nodeLstat(path: cstring): JsObject
  {.importjs: "require('fs').lstatSync(#)".}
proc nodeReaddir(path: cstring): seq[cstring]
  {.importjs: "require('fs').readdirSync(#)".}
proc nodeMkdirRecursive(path: cstring)
  {.importjs: "require('fs').mkdirSync(#, { recursive: true })".}
proc nodeRm(path: cstring; recursive: bool)
  {.importjs: "require('fs').rmSync(#, { recursive: #, force: true })".}
proc nodeCopy(source, destination: cstring)
  {.importjs: "require('fs').cpSync(#, #, { recursive: true })".}
proc nodeRename(source, destination: cstring)
  {.importjs: "require('fs').renameSync(#, #)".}
proc nodeRealpath(path: cstring): cstring
  {.importjs: "require('fs').realpathSync(#)".}
proc nodeMkdtemp(prefix: cstring): cstring
  {.importjs: "require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), #))".}
proc nodeHomedir(): cstring {.importjs: "require('os').homedir()".}
proc nodeEnv(name: cstring): cstring {.importjs: "process.env[#]".}

proc electronUserConfigDir(): string =
  ## `$CODETRACER_HOME/config`, else `~/.config/codetracer` —
  ## `common/ct_home.ctConfigDir`'s rule, spelt with this module's own node
  ## bindings because `ct_home` reads no environment in a renderer build.
  let ctHome = nodeEnv(cstring"CODETRACER_HOME")
  if not ctHome.isNil and ctHome.len > 0:
    $ctHome / "config"
  else:
    $nodeHomedir() / ".config" / "codetracer"

proc nodeExecFileSync(program: cstring; args: seq[cstring];
                      cwd: cstring; input: cstring): cstring
  {.importjs: "require('child_process').execFileSync(#, #, { cwd: (# || undefined), input: (# || undefined), encoding: 'utf8', windowsHide: true })".}

proc electronClipboardWrite(text: cstring)
  {.importjs: "require('electron').clipboard.writeText(#)".}
proc electronClipboardRead(): cstring
  {.importjs: "require('electron').clipboard.readText()".}
proc electronClipboardWriteHtml(html, text: cstring)
  {.importjs: "require('electron').clipboard.write({ html: #, text: # })".}
proc electronOpenExternal(url: cstring)
  {.importjs: "require('electron').shell.openExternal(#)".}
proc electronShowItemInFolder(path: cstring)
  {.importjs: "require('electron').shell.showItemInFolder(#)".}
proc electronAvailable(): bool =
  ## Whether `require('electron')` will work here.
  ##
  ## Checked by trying it rather than by reading a global the page set: the
  ## renderer's `inElectron` is injected by an inline `<script>` in index.html,
  ## which is a promise about the page rather than about the runtime, and a
  ## StoryBook or dev-server page that forgot the script would claim the wrong
  ## platform. This asks the runtime.
  var available = false
  {.emit: """
  try {
    `available` = (typeof require === 'function') && !!require('electron').clipboard;
  } catch (e) {
    `available` = false;
  }
  """.}
  available

proc nodePlatform(): cstring =
  ## `importjs` needs a call-shaped pattern, and `process.platform` is a
  ## property, so this is an emit rather than a binding.
  var value: cstring = ""
  {.emit: "`value` = (typeof process === 'undefined') ? '' : process.platform;".}
  value

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

var lastErrorText = ""
  ## The message from whatever JS last threw inside a `jsGuard`.
  ##
  ## Read by `errorText()` in the failure arm. A thread-local would be more
  ## fastidious; a renderer is single-threaded, and the value is consumed on the
  ## next line, so a module-level var is honest here in a way it would not be on
  ## the native side.

template jsGuard(body: untyped; onError: untyped): untyped =
  ## Node's sync APIs throw. Every operation below has to turn that into a
  ## `PlatformOutcome`, because the facade's contract is that failures are
  ## values — a rejected promise would mean three instantiations with three
  ## error channels.
  ##
  ## The message is captured into `lastErrorText` rather than discarded. An
  ## earlier draft read it back out of a global the runtime never sets, which
  ## would have made every `detail` field an empty string — a diagnostic that
  ## silently carries nothing is worse than none, because it looks like the
  ## error had no detail.
  ##
  ## ## THE BARE `except:` IS THE WHOLE GUARD, and it replaces two arms that
  ## ## caught nothing at all
  ##
  ## This template used to have exactly the two typed arms below and no bare
  ## one, and **it never caught a single node exception in its life.** Nim's JS
  ## backend compiles `except CatchableError` to a `catch (e)` that tests
  ## `e.m_type` and RE-THROWS when the test fails. A `TypeError` or an `Error`
  ## thrown by `require('fs')` is not a Nim exception object and has no
  ## `m_type`, so both arms re-threw it and every `do:` arm in this file — every
  ## `pkNotFound`, every `pkAccessDenied`, every `errorText()` — was dead code.
  ##
  ## Measured rather than reasoned about: `try: discard readdirSync("/nope")`
  ## with those two arms leaks the exception, and with a bare `except:` catches
  ## it and reports `getCurrentExceptionMsg()` as
  ## `ENOENT: no such file or directory, scandir '/nope'`.
  ##
  ## It went unnoticed because no caller had asked this facade for something
  ## that might not be there. SB-1's certificate indicator lists a store
  ## directory most workspaces do not have, and the ENOENT went straight past
  ## the facade to `window.onerror` — caught by
  ## `status-bar/status-bar-render-stability.spec.ts`'s
  ## `verify_clean_console_on_trace_open`, which is now this fix's regression
  ## test as well as SB-1's.
  ##
  ## The typed arms stay ahead of it so a Nim exception raised inside `body`
  ## still reports its own message; the bare arm is the one that makes the
  ## template's contract — "failures are values" — true.
  try:
    body
  except CatchableError:
    lastErrorText = getCurrentExceptionMsg()
    onError
  except Exception:
    lastErrorText = getCurrentExceptionMsg()
    onError
  except:
    lastErrorText = getCurrentExceptionMsg()
    onError

proc errorText(): string = lastErrorText

# ---------------------------------------------------------------------------
# Filesystem
# ---------------------------------------------------------------------------

proc electronFileSystem(profile: PlatformProfile): FileSystemFacade =
  result = unavailableFileSystem(profile)

  result.readText = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    jsGuard:
      resolvedOk($nodeReadFileSync(path.cstring))
    do:
      resolvedErr[string](
        if nodeExistsSync(path.cstring): pkAccessDenied else: pkNotFound,
        "cannot read " & path, errorText())

  result.readBytes = proc(path: string): PlatformFuture[PlatformOutcome[seq[byte]]] =
    jsGuard:
      let text = $nodeReadFileSync(path.cstring)
      var bytes = newSeq[byte](text.len)
      for i, c in text: bytes[i] = byte(c)
      resolvedOk(bytes)
    do:
      resolvedErr[seq[byte]](pkNotFound, "cannot read " & path, errorText())

  result.writeText = proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeWriteFileSync(path.cstring, content.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkAccessDenied, "cannot write " & path, errorText())

  result.writeBytes = proc(path: string;
                           content: seq[byte]): PlatformFuture[PlatformOutcome[Nothing]] =
    var text = newString(content.len)
    for i, b in content: text[i] = char(b)
    jsGuard:
      nodeWriteFileSync(path.cstring, text.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkAccessDenied, "cannot write " & path, errorText())

  result.appendText = proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeAppendFileSync(path.cstring, content.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkAccessDenied, "cannot append to " & path, errorText())

  result.stat = proc(path: string): PlatformFuture[PlatformOutcome[FsStat]] =
    if not nodeExistsSync(path.cstring):
      return resolvedOk(FsStat(kind: fekMissing))
    jsGuard:
      let raw = nodeLstat(path.cstring)
      var kind = fekOther
      if cast[bool](raw.isSymbolicLink()): kind = fekSymlink
      elif cast[bool](raw.isDirectory()): kind = fekDirectory
      elif cast[bool](raw.isFile()): kind = fekFile
      resolvedOk(FsStat(
        kind: kind,
        size: cast[int64](raw.size),
        modifiedMs: cast[int64](raw.mtimeMs),
        readOnly: false))
    do:
      resolvedErr[FsStat](pkAccessDenied, "cannot stat " & path, errorText())

  result.listDir = proc(path: string): PlatformFuture[PlatformOutcome[seq[FsDirEntry]]] =
    jsGuard:
      var entries: seq[FsDirEntry] = @[]
      for name in nodeReaddir(path.cstring):
        let child = path / $name
        var kind = fekOther
        if nodeExistsSync(child.cstring):
          let raw = nodeLstat(child.cstring)
          if cast[bool](raw.isSymbolicLink()): kind = fekSymlink
          elif cast[bool](raw.isDirectory()): kind = fekDirectory
          elif cast[bool](raw.isFile()): kind = fekFile
        entries.add FsDirEntry(name: $name, kind: kind)
      resolvedOk(entries)
    do:
      resolvedErr[seq[FsDirEntry]](pkNotFound, "cannot list " & path, errorText())

  result.createDir = proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeMkdirRecursive(path.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkAccessDenied, "cannot create " & path, errorText())

  result.remove = proc(path: string;
                       recursive: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    if not nodeExistsSync(path.cstring):
      return resolvedErr[Nothing](pkNotFound, "no such path: " & path)
    jsGuard:
      nodeRm(path.cstring, recursive)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkAccessDenied, "cannot remove " & path, errorText())

  result.copy = proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeCopy(source.cstring, destination.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot copy " & source, errorText())

  result.move = proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeRename(source.cstring, destination.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot move " & source, errorText())

  result.realPath = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    jsGuard:
      resolvedOk($nodeRealpath(path.cstring))
    do:
      resolvedErr[string](pkNotFound, "cannot resolve " & path, errorText())

  result.makeTempDir = proc(prefix: string): PlatformFuture[PlatformOutcome[string]] =
    jsGuard:
      resolvedOk($nodeMkdtemp(prefix.cstring))
    do:
      resolvedErr[string](pkFailed, "cannot create a temporary directory", errorText())

  result.certificateStoreRoots = proc(
      ): PlatformFuture[PlatformOutcome[CertificateStoreRoots]] =
    # Resolved from the renderer's own `process.env`, which Electron gives the
    # renderer from the process that launched it — the same environment the
    # producer that wrote the certificates resolved against.
    jsGuard:
      resolvedOk(nodeCertificateStoreRoots())
    do:
      resolvedErr[CertificateStoreRoots](pkFailed,
        "cannot resolve the local certificate store", errorText())

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------

proc electronProcess*(profile: PlatformProfile): ProcessFacade =
  ## The Electron renderer's process facade.
  ##
  ## Exported for the readers that run `ui/git_cli.nim` under node in the
  ## `renderer-dom` lane — `tests/git_cli_index_lock_test.nim` and
  ## `tests/vcs_panel_reload_test.nim` — for the reason `electronVcs` below
  ## is: there `newDesktopElectronPlatform` finds no `require('electron')` and
  ## falls back to the web profile, so the process facade the shipped window
  ## runs git through is reachable only by name.
  result = unavailableProcess(profile)

  result.run = proc(spec: ProcessSpec): PlatformFuture[PlatformOutcome[ProcessRunResult]] =
    var args: seq[cstring] = @[]
    for a in spec.args: args.add a.cstring
    jsGuard:
      let output = $nodeExecFileSync(
        spec.command.cstring, args, spec.workingDir.cstring,
        spec.stdinText.cstring)
      resolvedOk(ProcessRunResult(
        exit: ProcessExit(exitCode: 0, signalled: false),
        stdout: output, stderr: ""))
    do:
      # `execFileSync` throws on a non-zero exit, so a failed command and a
      # missing binary arrive the same way. Distinguishing them matters —
      # "git is not installed" and "git said no" want different UI — so the
      # exit status is recovered rather than flattened to an error.
      resolvedOk(ProcessRunResult(
        exit: ProcessExit(exitCode: 1, signalled: false),
        stdout: "", stderr: errorText()))

  # `run` without the wait: `child_process.spawn` through the runner the VCS
  # facade's asynchronous reads use (`node_certificate_host.nodeAsyncGitRunner`
  # — named for git, but it runs whatever argv it is given), the future
  # settled when the child closes. `run` above stays `execFileSync`: see
  # `ProcessFacade.runLater` for who relies on that.
  #
  # What it reports is what the child did — its exit status, stdout and
  # stderr — where `run` folds every failure into exit 1 with empty output.
  # A child that could not be launched (ENOENT, a missing working
  # directory), was killed, or wrote more than the runner captures, is a
  # `pkFailed` carrying node's account of why: there is no exit status to
  # report for it.
  #
  # `stdinText` and `clearEnv` are refused rather than dropped: the runner
  # gives the child `/dev/null` and the inherited environment, so a caller
  # that asked for either would otherwise get a different run from the one
  # it described. `timeoutMs` is not enforced, as it is not by `run`.
  let laterRunner = nodeAsyncGitRunner()
  result.runLater = proc(spec: ProcessSpec): PlatformFuture[PlatformOutcome[ProcessRunResult]] =
    if spec.stdinText.len > 0 or spec.clearEnv:
      return resolvedErr[ProcessRunResult](pkNotSupported,
        "runLater cannot feed stdin or clear the environment on this platform")
    let shown = spec.command
    var env: seq[(string, string)] = @[]
    for (key, value) in spec.env:
      env.add (key, value)
    jsGuard:
      settledLater(proc(settle: proc(value: PlatformOutcome[ProcessRunResult])) =
        laterRunner(GitCall(argv: @[spec.command] & spec.args,
                            cwd: spec.workingDir, env: env),
          proc(reply: GitReply) {.closure, gcsafe.} =
            {.cast(gcsafe).}:
              if reply.exitCode < 0 or not reply.complete:
                settle(failed[ProcessRunResult](pkFailed, "running " & shown & " failed",
                  if reply.stderr.strip().len > 0: reply.stderr.strip()
                  elif not reply.complete: "the output was more than could be captured"
                  else: "exit " & $reply.exitCode))
              else:
                settle(succeeded(ProcessRunResult(
                  exit: ProcessExit(exitCode: reply.exitCode, signalled: false),
                  stdout: reply.stdout, stderr: reply.stderr)))))
    do:
      resolvedErr[ProcessRunResult](pkFailed, "running " & shown & " failed", errorText())

  # `start`, `signal`, `writeStdin`, `closeStdin` and `isRunning` are left
  # refusing, and the profile below drops `capProcessSpawn`'s watchable half
  # accordingly. The renderer's long-running processes go through the Electron
  # main process over IPC (index/ipc_utils.nim), which is a supervisor this
  # module must not duplicate: two process tables in one product is the drift
  # NS1 exists to prevent. Wiring `start` to that IPC is the follow-up, and it
  # is an implementation behind an unchanged signature — which is the property
  # the facade was shaped for.

  result.which = proc(program: string): PlatformFuture[PlatformOutcome[string]] =
    var args: seq[cstring] = @[cstring(program)]
    jsGuard:
      let found = ($nodeExecFileSync(cstring"which", args, cstring"", cstring"")).strip()
      if found.len == 0:
        resolvedErr[string](pkNotFound, program & " is not on the search path")
      else:
        resolvedOk(found)
    do:
      resolvedErr[string](pkNotFound, program & " is not on the search path")

# ---------------------------------------------------------------------------
# VCS
# ---------------------------------------------------------------------------

const ElectronLogFormat =
  "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"
  ## One commit per `\x1e`-terminated record, its fields `\x1f`-separated:
  ## two bytes that cannot occur in a hash, a name, an address or a subject
  ## line, so no field can be split by its own content
  ## (https://git-scm.com/docs/pretty-formats).

proc parseElectronLog(output: string): seq[VcsCommit] =
  ## `ElectronLogFormat`'s output, read. A record with too few fields — which
  ## git never writes — is skipped rather than guessed at.
  for record in output.split('\x1e'):
    let trimmed = record.strip()
    if trimmed.len == 0: continue
    let f = trimmed.split('\x1f')
    if f.len < 7: continue
    var authoredAt: int64 = 0
    try: authoredAt = parseBiggestInt(f[5]) * 1000
    except ValueError: discard
    result.add VcsCommit(
      id: f[0], shortId: f[1],
      parents: if f[2].len > 0: f[2].split(' ') else: @[],
      authorName: f[3], authorEmail: f[4], authoredAtMs: authoredAt,
      subject: f[6])

proc gitReadLater[T](runner: AsyncContentGitRunner; repository: string;
                     args: seq[string]; parse: proc(output: string): T
                    ): PlatformFuture[PlatformOutcome[T]] =
  ## One git read that does not block the calling thread: `args` (the
  ## subcommand first) behind `noIndexLockGitArgs`, launched through
  ## `child_process.spawn`, the future settled with `parse(stdout)` when git
  ## exits 0 with its whole output.
  ##
  ## Every other ending is the failure `execFileSync` gave the same command:
  ## `pkFailed`, `git <args> failed`, and in `detail` git's own diagnostic —
  ## or, for a git that never ran (ENOENT, a missing working directory),
  ## node's account of why, which `node_certificate_host.replyOf` puts where
  ## git's stderr would be. One mapping for every asynchronous read below, so
  ## they cannot drift apart in what a failure looks like.
  let shown = "git " & args.join(" ")
  jsGuard:
    settledLater(proc(settle: proc(value: PlatformOutcome[T])) =
      runner(GitCall(argv: @["git"] & noIndexLockGitArgs(args), cwd: repository),
        proc(reply: GitReply) {.closure, gcsafe.} =
          {.cast(gcsafe).}:
            if reply.exitCode == 0 and reply.complete:
              settle(succeeded(parse(reply.stdout)))
            else:
              settle(failed[T](pkFailed, shown & " failed",
                if reply.stderr.strip().len > 0: reply.stderr.strip()
                elif not reply.complete: "the output was more than could be captured"
                else: "exit " & $reply.exitCode))))
  do:
    resolvedErr[T](pkFailed, shown & " failed", errorText())

proc electronVcs*(profile: PlatformProfile): VcsFacade =
  ## The Electron renderer's version-control facade.
  ##
  ## Exported for the suites that reach it under node:
  ## `tests/electron_vcs_content_id_async_test.nim`,
  ## `tests/electron_vcs_refresh_async_test.nim` and
  ## `tests/electron_vcs_index_lock_test.nim` in the `main-process` lane,
  ## and `tests/git_cli_refresh_snapshot_test.nim` in `renderer-dom`, which
  ## installs it behind `ui/git_cli`. Under plain node
  ## `newDesktopElectronPlatform` finds no `require('electron')` and —
  ## rightly, for a browser tab — falls back to the web profile, so this
  ## facade, the one the shipped window installs, is reachable from a Nim
  ## lane only by name.
  ##
  ## ## The reads a periodic refresh makes do not block
  ##
  ## `contentId`, `repositoryRoot`, `status` and `log` run git through
  ## `child_process.spawn` and settle their futures when it answers. The
  ## certificate indicator gathers W, H, S and the root on every refresh, and
  ## the VCS pane reads the status and the last 30 commit ids every 5 s and on
  ## focus (`ui/git_cli.readRefreshSnapshot`). Through `execFileSync` /
  ## `spawnSync` each of those froze the window: up to 1.2 s per indicator
  ## refresh, 150-185 ms per pane tick (Status-Bar.md, "A refresh never
  ## stalls the window"; VCS-Panel.md, "An auto-refresh never stalls the
  ## window"; codetracer-pm issue
  ## `2026-10-21-vcs-auto-refresh-runs-git-synchronously-on-the-renderer-main-thread`).
  ## No renderer code settles `status` or `log` with `ctAwaitSync`, so
  ## answering later changes no caller's answer.
  ##
  ## The other operations still use `execFileSync`. They run when the user
  ## acts (stage, a diff, a blob) rather than on a timer. The pane's own
  ## reload runs git through `ui/git_cli.gitReadLater` and the process
  ## facade's `runLater`, which does not block either.
  result = unavailableVcs(profile)

  proc git(repository: string; args: seq[string]): PlatformOutcome[string] =
    ## Every git call this facade makes is built by `noIndexLockGitArgs`, so
    ## the pane's refresh never writes the index nor takes its lock
    ## (`platform/vcs.NoIndexLockGitOptions`).
    var jsArgs: seq[cstring] = @[]
    for a in noIndexLockGitArgs(args): jsArgs.add a.cstring
    jsGuard:
      succeeded($nodeExecFileSync(cstring"git", jsArgs, repository.cstring, cstring""))
    do:
      failed[string](pkFailed, "git " & args.join(" ") & " failed", errorText())

  result.isRepository = proc(path: string): PlatformFuture[PlatformOutcome[bool]] =
    let res = git(path, @["rev-parse", "--is-inside-work-tree"])
    resolvedOk(res.ok and res.value.strip() == "true")

  # The three reads below settle later and share one runner and one outcome
  # mapping (`gitReadLater`), so a failure means the same on each.
  let readGit = nodeAsyncGitRunner()

  # `git rev-parse --show-toplevel`: the top level, without its line
  # terminator.
  result.repositoryRoot = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    gitReadLater(readGit, path, @["rev-parse", "--show-toplevel"],
      proc(output: string): string = output.strip())

  # Read by the porcelain-v2 reader every instantiation shares
  # (`platform/vcs.parsePorcelainV2`) rather than by one of this facade's
  # own. The one it replaces skipped unmerged (`u `) lines, so a conflict
  # starting or ending was invisible to the pane's refresh, and cut a path
  # at its first space.
  result.status = proc(repository: string): PlatformFuture[PlatformOutcome[VcsStatus]] =
    gitReadLater(readGit, repository, @["status", "--porcelain=v2", "--branch"],
      proc(output: string): VcsStatus = parsePorcelainV2(output))

  result.log = proc(repository: string; maxCount: int;
                    path: string): PlatformFuture[PlatformOutcome[seq[VcsCommit]]] =
    var args = @["log", "--max-count=" & $maxCount, ElectronLogFormat]
    if path.len > 0:
      args.add "--"
      args.add path
    gitReadLater(readGit, repository, args,
      proc(output: string): seq[VcsCommit] = parseElectronLog(output))

  result.readBlob = proc(repository, path: string;
                         source: VcsBlobSource): PlatformFuture[PlatformOutcome[string]] =
    case source
    of vbsWorkingTree:
      let full = repository / path
      if not nodeExistsSync(full.cstring):
        return resolvedErr[string](pkNotFound, "no working-tree copy of " & path)
      jsGuard:
        resolvedOk($nodeReadFileSync(full.cstring))
      do:
        resolvedErr[string](pkNotFound, "no working-tree copy of " & path, errorText())
    of vbsIndex:
      let res = git(repository, @["show", ":" & path])
      if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))
    of vbsHead:
      let res = git(repository, @["show", "HEAD:" & path])
      if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  result.readBlobAt = proc(repository, path,
                           revision: string): PlatformFuture[PlatformOutcome[string]] =
    let res = git(repository, @["show", revision & ":" & path])
    if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  result.diff = proc(repository: string; paths: seq[string]; staged: bool;
                     contextLines: int): PlatformFuture[PlatformOutcome[string]] =
    var args = @["diff", "--unified=" & $contextLines]
    if staged: args.add "--cached"
    if paths.len > 0:
      args.add "--"
      for p in paths: args.add p
    let res = git(repository, args)
    if res.ok: resolvedOk(res.value) else: resolved(failed[string](res.error))

  # The content-id recipe through node's `child_process.spawn`, its temporary
  # index under the OS temporary directory, settling when the last git call
  # answers (`contentIdOverAsync`). `node_certificate_host` returns every
  # failure as a value; `jsGuard` is the facade's own contract on top, so even
  # a lapse there — a throw before the first git call is launched — arrives
  # as an outcome rather than on `window.onerror`.
  let contentHost = nodeAsyncContentIdHost()
  result.contentId = proc(repository: string; state: VcsBlobSource;
                          algorithm: string; scope: seq[string]
                         ): PlatformFuture[PlatformOutcome[VcsContentId]] =
    jsGuard:
      contentIdOverAsync(contentHost, profile, repository, state, algorithm,
                         scope)
    do:
      resolvedErr[VcsContentId](pkFailed, "computing a content id failed",
                                errorText())
  result.declaredScopes = proc(repository: string
                              ): PlatformFuture[PlatformOutcome[VcsDeclaredScopes]] =
    jsGuard:
      declaredScopesOverAsync(contentHost, profile, repository)
    do:
      resolvedErr[VcsDeclaredScopes](pkFailed,
        "reading the declared certificate scopes failed", errorText())

  result.stage = proc(repository: string;
                      paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["add", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.unstage = proc(repository: string;
                        paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["restore", "--staged", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.discardChanges = proc(repository: string;
                               paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["restore", "--"] & paths)
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.applyPatch = proc(repository, patch: string;
                           reverse: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    var jsArgs: seq[cstring] = @[]
    for a in noIndexLockGitArgs(if reverse: @["apply", "--reverse", "-"]
                                else: @["apply", "-"]):
      jsArgs.add a.cstring
    jsGuard:
      discard nodeExecFileSync(cstring"git", jsArgs, repository.cstring, patch.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkConflict, "the patch did not apply", errorText())

  result.commit = proc(repository, message, authorName,
                       authorEmail: string): PlatformFuture[PlatformOutcome[VcsCommit]] =
    var args = @["commit", "-m", message]
    if authorName.len > 0 and authorEmail.len > 0:
      args.add "--author=" & authorName & " <" & authorEmail & ">"
    let res = git(repository, args)
    if not res.ok:
      return resolved(failed[VcsCommit](res.error))
    let head = git(repository, @["rev-parse", "HEAD"])
    if not head.ok:
      return resolved(failed[VcsCommit](head.error))
    resolvedOk(VcsCommit(id: head.value.strip(), subject: message))

  result.initRepository = proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(path, @["init", "-q"])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.fetch = proc(repository, remote: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["fetch", remote])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

  result.push = proc(repository, remote,
                     refspec: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let res = git(repository, @["push", remote, refspec])
    if res.ok: resolvedOk() else: resolved(failed[Nothing](res.error))

# ---------------------------------------------------------------------------
# Settings, clipboard, shell
# ---------------------------------------------------------------------------

proc electronSettings(profile: PlatformProfile): SettingsFacade =
  result = unavailableSettings(profile)

  proc scopeDir(scope: SettingsScope): string =
    case scope
    of ssUser: electronUserConfigDir()
    of ssWorkspace: ".codetracer"
    of ssSession: electronUserConfigDir() / "session"

  proc keyPath(scope: SettingsScope; key: string): string =
    var safe = ""
    for c in key:
      safe.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: c else: '_')
    scopeDir(scope) / (safe & ".txt")

  result.get = proc(scope: SettingsScope;
                    key: string): PlatformFuture[PlatformOutcome[string]] =
    let path = keyPath(scope, key)
    if not nodeExistsSync(path.cstring):
      return resolvedErr[string](pkNotFound, "no setting named " & key)
    jsGuard:
      resolvedOk($nodeReadFileSync(path.cstring))
    do:
      resolvedErr[string](pkFailed, "reading setting " & key & " failed", errorText())

  result.set = proc(scope: SettingsScope; key,
                    value: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      nodeMkdirRecursive(scopeDir(scope).cstring)
      nodeWriteFileSync(keyPath(scope, key).cstring, value.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "writing setting " & key & " failed", errorText())

  result.delete = proc(scope: SettingsScope;
                       key: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let path = keyPath(scope, key)
    if not nodeExistsSync(path.cstring):
      return resolvedOk()
    jsGuard:
      nodeRm(path.cstring, false)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "deleting setting " & key & " failed", errorText())

  result.keys = proc(scope: SettingsScope;
                     prefix: string): PlatformFuture[PlatformOutcome[seq[string]]] =
    let dir = scopeDir(scope)
    if not nodeExistsSync(dir.cstring):
      return resolvedOk(newSeq[string]())
    jsGuard:
      var found: seq[string] = @[]
      for name in nodeReaddir(dir.cstring):
        let entry = $name
        if entry.endsWith(".txt"):
          let stem = entry[0 ..< entry.len - 4]
          if prefix.len == 0 or stem.startsWith(prefix):
            found.add stem
      resolvedOk(found)
    do:
      resolvedErr[seq[string]](pkFailed, "listing settings failed", errorText())

  result.environment = proc(name: string): PlatformFuture[PlatformOutcome[string]] =
    let value = $nodeEnv(name.cstring)
    if value.len == 0: resolvedErr[string](pkNotFound, name & " is not set")
    else: resolvedOk(value)

proc electronClipboard(profile: PlatformProfile): ClipboardFacade =
  result = unavailableClipboard(profile)

  result.writeText = proc(text: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      electronClipboardWrite(text.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot write to the clipboard", errorText())

  result.readText = proc(): PlatformFuture[PlatformOutcome[string]] =
    jsGuard:
      resolvedOk($electronClipboardRead())
    do:
      resolvedErr[string](pkFailed, "cannot read the clipboard", errorText())

  result.writeHtml = proc(html, plainText: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      electronClipboardWriteHtml(html.cstring, plainText.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot write to the clipboard", errorText())

proc electronShell(profile: PlatformProfile): ShellFacade =
  result = unavailableShell(profile)

  result.openExternalUrl = proc(url: string): PlatformFuture[PlatformOutcome[Nothing]] =
    # The scheme allow-list is the facade's, not Electron's. `shell.openExternal`
    # with a `file:` or a registered handler scheme is a code-execution
    # primitive, and no front-end caller has a reason to reach one — so the
    # refusal lives in `platform/shell.allowedExternalUrlScheme` rather than
    # here.  It used to be inline, and inline meant `web_browser.nim` did not
    # have it.
    if not allowedExternalUrlScheme(url):
      return refuseExternalUrl(url)
    jsGuard:
      electronOpenExternal(url.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot open " & url, errorText())

  result.revealInFileManager = proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    jsGuard:
      electronShowItemInFolder(path.cstring)
      resolvedOk()
    do:
      resolvedErr[Nothing](pkFailed, "cannot reveal " & path, errorText())

# ---------------------------------------------------------------------------
# The instantiation
# ---------------------------------------------------------------------------

proc newDesktopElectronPlatform*(): Platform =
  ## The instantiation the shipped desktop window runs.
  ##
  ## `overlaysCaptionBar` is read from `process.platform` at run time rather
  ## than from `defined(ctmacos)`. That is not a stylistic preference: it is the
  ## §1a.2 deliverable. The same bundle rendering into a browser tab has no
  ## traffic lights to avoid, and a build check cannot tell the difference.
  let onMacOS = $nodePlatform() == "darwin"

  if not electronAvailable():
    # The same bundle also runs in a plain browser tab, under the
    # browsersync dev server (`browsersync_serv.nim`) and in StoryBook. There
    # is no `require` there, so every binding in this module would throw.
    #
    # `ui/menu.nim` used to handle that with `electron_lib.inElectron` — a
    # runtime check, but one made at each site that cared. Making it a
    # *profile* instead is the §1a.2 pattern applied honestly: a bundle with
    # no Electron under it genuinely has the web's capabilities, and saying so
    # once means no call site has to ask again. This is also what keeps the
    # migration behaviour-preserving: `showWindowMenu` was
    # `inElectron and not defined(ctmacos)`, and without this branch it would
    # have become `true` in the dev server.
    return newPlatform(webProfile)

  let profile = electronDesktopProfile(onMacOS)

  Platform(
    profile: profile,
    fs: electronFileSystem(profile),
    process: electronProcess(profile),
    vcs: electronVcs(profile),
    settings: electronSettings(profile),
    clipboard: electronClipboard(profile),
    download: unavailableDownload(profile),
    shell: electronShell(profile))
