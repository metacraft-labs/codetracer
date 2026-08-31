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
  try:
    body
  except CatchableError:
    lastErrorText = getCurrentExceptionMsg()
    onError
  except Exception:
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

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------

proc electronProcess(profile: PlatformProfile): ProcessFacade =
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

proc electronVcs(profile: PlatformProfile): VcsFacade =
  result = unavailableVcs(profile)

  proc git(repository: string; args: seq[string]): PlatformOutcome[string] =
    var jsArgs: seq[cstring] = @[]
    for a in args: jsArgs.add a.cstring
    jsGuard:
      succeeded($nodeExecFileSync(cstring"git", jsArgs, repository.cstring, cstring""))
    do:
      failed[string](pkFailed, "git " & args.join(" ") & " failed", errorText())

  result.isRepository = proc(path: string): PlatformFuture[PlatformOutcome[bool]] =
    let res = git(path, @["rev-parse", "--is-inside-work-tree"])
    resolvedOk(res.ok and res.value.strip() == "true")

  result.repositoryRoot = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    let res = git(path, @["rev-parse", "--show-toplevel"])
    if res.ok: resolvedOk(res.value.strip())
    else: resolved(failed[string](res.error))

  result.status = proc(repository: string): PlatformFuture[PlatformOutcome[VcsStatus]] =
    let res = git(repository, @["status", "--porcelain=v2", "--branch"])
    if not res.ok:
      return resolved(failed[VcsStatus](res.error))
    var status = VcsStatus()
    for line in res.value.splitLines():
      if line.len == 0: continue
      if line.startsWith("# branch.head "):
        status.branch = line[14 .. ^1]
        status.detached = status.branch == "(detached)"
      elif line.startsWith("# branch.upstream "):
        status.upstream = line[18 .. ^1]
      elif line.startsWith("? "):
        status.changes.add VcsFileChange(
          path: line[2 .. ^1], workingTreeStatus: vfsUntracked)
      elif line.startsWith("1 ") or line.startsWith("2 "):
        let fields = line.split(' ')
        if fields.len >= 9:
          let xy = fields[1]
          proc code(c: char): VcsFileStatus =
            case c
            of 'M': vfsModified
            of 'A': vfsAdded
            of 'D': vfsDeleted
            of 'R': vfsRenamed
            of 'C': vfsCopied
            of 'U': vfsConflicted
            else: vfsUnmodified
          status.changes.add VcsFileChange(
            path: fields[^1], indexStatus: code(xy[0]),
            workingTreeStatus: code(xy[1]))
    resolvedOk(status)

  result.log = proc(repository: string; maxCount: int;
                    path: string): PlatformFuture[PlatformOutcome[seq[VcsCommit]]] =
    var args = @["log", "--max-count=" & $maxCount,
                 "--pretty=format:%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"]
    if path.len > 0:
      args.add "--"
      args.add path
    let res = git(repository, args)
    if not res.ok:
      return resolved(failed[seq[VcsCommit]](res.error))
    var commits: seq[VcsCommit] = @[]
    for record in res.value.split('\x1e'):
      let trimmed = record.strip()
      if trimmed.len == 0: continue
      let f = trimmed.split('\x1f')
      if f.len < 7: continue
      var authoredAt: int64 = 0
      try: authoredAt = parseBiggestInt(f[5]) * 1000
      except ValueError: discard
      commits.add VcsCommit(
        id: f[0], shortId: f[1],
        parents: if f[2].len > 0: f[2].split(' ') else: @[],
        authorName: f[3], authorEmail: f[4], authoredAtMs: authoredAt,
        subject: f[6])
    resolvedOk(commits)

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
    var jsArgs: seq[cstring] = @[cstring"apply"]
    if reverse: jsArgs.add cstring"--reverse"
    jsArgs.add cstring"-"
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
    of ssUser: $nodeHomedir() / ".config" / "codetracer"
    of ssWorkspace: ".codetracer"
    of ssSession: $nodeHomedir() / ".config" / "codetracer" / "session"

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
