## The desktop instantiation, native (C) backend.
##
## This is the facade's **first and reference instantiation** — NS1: "it ships
## with the desktop product as its first and reference instantiation. Noir
## Studio is what makes it urgent; it is not what makes it valuable."
##
## ## This module is host-side by design
##
## It imports `std/os` and `std/osproc` and it is *supposed* to. It sits outside
## the host-free surface (`ci/test/hostfree-build.sh`), in the same relationship
## to it that `viewmodel/host/project_action_runner.nim` already has to
## `viewmodels/`: "a module in here may touch the platform, and a module in
## `viewmodels/` may not."
##
## ## Why the operations are synchronous underneath and async on the outside
##
## `readFile` on a desktop really is a blocking call, and pretending otherwise
## would cost a thread for nothing. So each operation does its work and returns
## an already-settled future through `outcome.resolved`. The *signature* is
## still the async one, because the signature is a contract with three
## instantiations and only one of them is in-process — NS1: "a facade that
## cannot express latency forces a second client later." The desktop pays one
## allocation to keep that contract; the container path is what it buys.
##
## The one exception is `start`, which is genuinely asynchronous everywhere: it
## returns a handle and streams output through callbacks. See the note there for
## why it is polled rather than threaded.

when defined(js):
  {.error: "desktop_native.nim is the C-backend desktop instantiation; " &
           "the JS/Electron renderer uses desktop_electron.nim".}

import std/[os, osproc, streams, strutils, tables, times, tempfiles, strtabs]

import ../platform/outcome
import ../platform/capabilities
import ../platform/fs
import ../platform/process
import ../platform/vcs
import ../platform/settings
import ../platform/clipboard
import ../platform/download
import ../platform/shell
import ../platform/platform
import ./native_vcs
import ../../../ct_test/certificate_store_roots_native

# ---------------------------------------------------------------------------
# Filesystem
# ---------------------------------------------------------------------------

proc toFsEntryKind(path: string): FsEntryKind =
  if symlinkExists(path): fekSymlink
  elif dirExists(path): fekDirectory
  elif fileExists(path): fekFile
  else: fekMissing

proc osErrorOutcome[T](action, path: string; err: ref Exception): PlatformOutcome[T] =
  ## One place decides which `PlatformErrorKind` an OS exception maps to, so the
  ## mapping cannot drift between operations. `pkNotFound` in particular has to
  ## be reliable: callers branch on it to distinguish "no file" from "cannot
  ## read the file", and the two want different UI.
  let detail = err.msg
  var kind = pkFailed
  if err of OSError:
    let code = (ref OSError)(err).errorCode
    when defined(windows):
      case code
      of 2, 3: kind = pkNotFound
      of 5: kind = pkAccessDenied
      of 80, 183: kind = pkAlreadyExists
      of 112: kind = pkQuotaExceeded
      else: kind = pkFailed
    else:
      case code
      of 2: kind = pkNotFound
      of 13, 1: kind = pkAccessDenied
      of 17: kind = pkAlreadyExists
      of 28: kind = pkQuotaExceeded
      else: kind = pkFailed
  elif err of IOError:
    kind = if not fileExists(path) and not dirExists(path): pkNotFound else: pkFailed
  failed[T](kind, action & " failed for " & path, detail)

proc desktopFileSystem(profile: PlatformProfile): FileSystemFacade =
  result = unavailableFileSystem(profile)

  result.readText = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    try: resolvedOk(readFile(path))
    except CatchableError as err: resolved(osErrorOutcome[string]("read", path, err))

  result.readBytes = proc(path: string): PlatformFuture[PlatformOutcome[seq[byte]]] =
    try:
      let text = readFile(path)
      var bytes = newSeq[byte](text.len)
      for i, c in text:
        bytes[i] = byte(c)
      resolvedOk(bytes)
    except CatchableError as err:
      resolved(osErrorOutcome[seq[byte]]("read", path, err))

  result.writeText = proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      writeFile(path, content)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("write", path, err))

  result.writeBytes = proc(path: string;
                           content: seq[byte]): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      var text = newString(content.len)
      for i, b in content:
        text[i] = char(b)
      writeFile(path, text)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("write", path, err))

  result.appendText = proc(path, content: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      let existing = if fileExists(path): readFile(path) else: ""
      writeFile(path, existing & content)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("append to", path, err))

  result.stat = proc(path: string): PlatformFuture[PlatformOutcome[FsStat]] =
    let kind = toFsEntryKind(path)
    if kind == fekMissing:
      return resolvedOk(FsStat(kind: fekMissing))
    try:
      let info = getFileInfo(path)
      resolvedOk(FsStat(
        kind: kind,
        size: info.size,
        modifiedMs: info.lastWriteTime.toUnix * 1000,
        readOnly: fpUserWrite notin info.permissions))
    except CatchableError as err:
      resolved(osErrorOutcome[FsStat]("stat", path, err))

  result.listDir = proc(path: string): PlatformFuture[PlatformOutcome[seq[FsDirEntry]]] =
    if not dirExists(path):
      return resolvedErr[seq[FsDirEntry]](pkNotFound, "no such directory: " & path)
    try:
      var entries: seq[FsDirEntry] = @[]
      for kind, entryPath in walkDir(path, relative = true):
        let entryKind =
          case kind
          of pcFile: fekFile
          of pcDir: fekDirectory
          of pcLinkToFile, pcLinkToDir: fekSymlink
        entries.add FsDirEntry(name: entryPath, kind: entryKind)
      resolvedOk(entries)
    except CatchableError as err:
      resolved(osErrorOutcome[seq[FsDirEntry]]("list", path, err))

  result.createDir = proc(path: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      createDir(path)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("create directory", path, err))

  result.remove = proc(path: string;
                       recursive: bool): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      if dirExists(path):
        if recursive: removeDir(path)
        else: removeDir(path, checkDir = true)
      elif fileExists(path) or symlinkExists(path):
        removeFile(path)
      else:
        return resolvedErr[Nothing](pkNotFound, "no such path: " & path)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("remove", path, err))

  result.copy = proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      if dirExists(source): copyDir(source, destination)
      else: copyFile(source, destination)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("copy", source, err))

  result.move = proc(source, destination: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      if dirExists(source): moveDir(source, destination)
      else: moveFile(source, destination)
      resolvedOk()
    except CatchableError as err:
      resolved(osErrorOutcome[Nothing]("move", source, err))

  result.realPath = proc(path: string): PlatformFuture[PlatformOutcome[string]] =
    try: resolvedOk(expandFilename(path))
    except CatchableError as err: resolved(osErrorOutcome[string]("resolve", path, err))

  result.makeTempDir = proc(prefix: string): PlatformFuture[PlatformOutcome[string]] =
    try: resolvedOk(createTempDir(prefix, ""))
    except CatchableError as err:
      resolved(osErrorOutcome[string]("create a temporary directory", prefix, err))

  result.certificateStoreRoots = proc(
      ): PlatformFuture[PlatformOutcome[CertificateStoreRoots]] =
    resolvedOk(nativeCertificateStoreRoots())

  # `watch` is deliberately left as the refusal `unavailableFileSystem` supplies
  # even though `capFilesystemWatch` is in the desktop profile. The desktop
  # watcher today is Electron's, in the renderer (index/config.nim's `fs.watch`),
  # and it belongs to `desktop_electron.nim`. Wiring a second, native watcher
  # here would put two implementations of one capability in the tree, which is
  # the drift this milestone exists to prevent. See the note in
  # desktop_electron.nim.

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------

type
  RunningChild = ref object
    child: Process
    onOutput: proc(chunk: ProcessOutputChunk)
    onExit: proc(exit: ProcessExit)
    reported: bool

var children: Table[string, RunningChild] = initTable[string, RunningChild]()
var nextChildId = 0

proc toStringTable(env: seq[tuple[key, value: string]];
                   clearEnv: bool): StringTableRef =
  if env.len == 0 and not clearEnv:
    return nil
  result = newStringTable(modeCaseSensitive)
  if not clearEnv:
    for key, value in envPairs():
      result[key] = value
  for (key, value) in env:
    result[key] = value

proc desktopProcess(profile: PlatformProfile): ProcessFacade =
  result = unavailableProcess(profile)

  result.run = proc(spec: ProcessSpec): PlatformFuture[PlatformOutcome[ProcessRunResult]] =
    let options = {poUsePath}
    try:
      let child = startProcess(
        spec.command, workingDir = spec.workingDir, args = spec.args,
        env = toStringTable(spec.env, spec.clearEnv), options = options)
      if spec.stdinText.len > 0:
        child.inputStream.write(spec.stdinText)
      child.inputStream.close()

      # `waitForExit` with a timeout is the whole reason `ProcessSpec` carries
      # `timeoutMs`: a front end that blocks forever on a wedged child is the
      # frozen-window failure §9.3 names, and it is not fixed by hoping the
      # child behaves.
      let code =
        if spec.timeoutMs > 0: child.waitForExit(spec.timeoutMs)
        else: child.waitForExit()
      let stdoutText = child.outputStream.readAll()
      let stderrText = child.errorStream.readAll()
      child.close()
      resolvedOk(ProcessRunResult(
        exit: ProcessExit(exitCode: code, signalled: false),
        stdout: stdoutText, stderr: stderrText))
    except OSError as err:
      resolvedErr[ProcessRunResult](
        pkNotFound, "cannot run " & spec.command, err.msg)
    except CatchableError as err:
      resolvedErr[ProcessRunResult](
        pkFailed, "running " & spec.command & " failed", err.msg)

  result.start = proc(spec: ProcessSpec;
                      onOutput: proc(chunk: ProcessOutputChunk);
                      onExit: proc(exit: ProcessExit)
                     ): PlatformFuture[PlatformOutcome[ProcessHandle]] =
    try:
      let child = startProcess(
        spec.command, workingDir = spec.workingDir, args = spec.args,
        env = toStringTable(spec.env, spec.clearEnv), options = {poUsePath})
      if spec.stdinText.len > 0:
        child.inputStream.write(spec.stdinText)
        child.inputStream.flush()
      inc nextChildId
      let id = "desktop-" & $nextChildId
      children[id] = RunningChild(
        child: child, onOutput: onOutput, onExit: onExit, reported: false)
      resolvedOk(ProcessHandle(id))
    except CatchableError as err:
      resolvedErr[ProcessHandle](
        pkNotFound, "cannot start " & spec.command, err.msg)

  result.signal = proc(handle: ProcessHandle;
                       signal: ProcessSignal): PlatformFuture[PlatformOutcome[Nothing]] =
    let id = string(handle)
    if id notin children:
      return resolvedErr[Nothing](pkNotFound, "no such process: " & id)
    try:
      case signal
      of sigInterrupt, sigTerminate: children[id].child.terminate()
      of sigKill: children[id].child.kill()
      resolvedOk()
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "signalling " & id & " failed", err.msg)

  result.writeStdin = proc(handle: ProcessHandle;
                           text: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let id = string(handle)
    if id notin children:
      return resolvedErr[Nothing](pkNotFound, "no such process: " & id)
    try:
      children[id].child.inputStream.write(text)
      children[id].child.inputStream.flush()
      resolvedOk()
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "writing to " & id & " failed", err.msg)

  result.closeStdin = proc(handle: ProcessHandle): PlatformFuture[PlatformOutcome[Nothing]] =
    let id = string(handle)
    if id notin children:
      return resolvedErr[Nothing](pkNotFound, "no such process: " & id)
    try:
      children[id].child.inputStream.close()
      resolvedOk()
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "closing stdin of " & id & " failed", err.msg)

  result.isRunning = proc(handle: ProcessHandle): PlatformFuture[PlatformOutcome[bool]] =
    let id = string(handle)
    if id notin children:
      return resolvedErr[bool](pkNotFound, "no such process: " & id)
    resolvedOk(children[id].child.running())

  result.which = proc(program: string): PlatformFuture[PlatformOutcome[string]] =
    let found = findExe(program)
    if found.len == 0:
      resolvedErr[string](pkNotFound, program & " is not on the search path")
    else:
      resolvedOk(found)

proc pumpDesktopProcesses*() =
  ## Drain finished children and fire their `onExit`.
  ##
  ## Called from the host's own event loop. This is a poll rather than a thread
  ## for the reason `viewmodel/host/project_action_runner.nim` gives: the
  ## caller's loop decides the cadence, so a long-running child never dictates
  ## when the UI gets to redraw.
  var finished: seq[string] = @[]
  for id, running in children:
    if running.reported:
      finished.add id
      continue
    if not running.child.running():
      let code = running.child.peekExitCode()
      running.reported = true
      if not running.onExit.isNil:
        running.onExit(ProcessExit(
          exitCode: code, signalled: code < 0,
          signalName: if code < 0: "terminated" else: ""))
  for id in finished:
    try:
      children[id].child.close()
    except CatchableError:
      discard
    children.del(id)

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

proc desktopSettings(profile: PlatformProfile): SettingsFacade =
  result = unavailableSettings(profile)

  proc scopeDir(scope: SettingsScope): string =
    case scope
    of ssUser: getConfigDir() / "codetracer"
    of ssWorkspace: getCurrentDir() / ".codetracer"
    of ssSession: getTempDir() / "codetracer-session"

  proc keyPath(scope: SettingsScope; key: string): string =
    # The key is a flat name, never a path fragment: a key containing `..`
    # would otherwise escape the settings directory, and a settings store that
    # can write anywhere is not a settings store.
    var safe = ""
    for c in key:
      safe.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: c else: '_')
    scopeDir(scope) / (safe & ".txt")

  result.get = proc(scope: SettingsScope;
                    key: string): PlatformFuture[PlatformOutcome[string]] =
    let path = keyPath(scope, key)
    if not fileExists(path):
      return resolvedErr[string](pkNotFound, "no setting named " & key)
    try: resolvedOk(readFile(path))
    except CatchableError as err:
      resolvedErr[string](pkFailed, "reading setting " & key & " failed", err.msg)

  result.set = proc(scope: SettingsScope; key,
                    value: string): PlatformFuture[PlatformOutcome[Nothing]] =
    try:
      createDir(scopeDir(scope))
      writeFile(keyPath(scope, key), value)
      resolvedOk()
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "writing setting " & key & " failed", err.msg)

  result.delete = proc(scope: SettingsScope;
                       key: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let path = keyPath(scope, key)
    if not fileExists(path):
      return resolvedOk()
    try:
      removeFile(path)
      resolvedOk()
    except CatchableError as err:
      resolvedErr[Nothing](pkFailed, "deleting setting " & key & " failed", err.msg)

  result.keys = proc(scope: SettingsScope;
                     prefix: string): PlatformFuture[PlatformOutcome[seq[string]]] =
    let dir = scopeDir(scope)
    if not dirExists(dir):
      return resolvedOk(newSeq[string]())
    var found: seq[string] = @[]
    try:
      for kind, path in walkDir(dir, relative = true):
        if kind == pcFile and path.endsWith(".txt"):
          let name = path[0 ..< path.len - 4]
          if prefix.len == 0 or name.startsWith(prefix):
            found.add name
    except CatchableError as err:
      return resolvedErr[seq[string]](pkFailed, "listing settings failed", err.msg)
    resolvedOk(found)

  result.environment = proc(name: string): PlatformFuture[PlatformOutcome[string]] =
    if not existsEnv(name):
      resolvedErr[string](pkNotFound, name & " is not set")
    else:
      resolvedOk(getEnv(name))

  # Secrets are left refusing. `capSecretStore` is in the desktop profile
  # because the desktop CAN have one, but there is no keychain binding in this
  # tree today and inventing one here would be a second, unowned credential
  # store. The refusal names the capability, which is the correct behaviour
  # until the binding exists — and `test_desktop_declares_no_capability_it_cannot_serve`
  # holds this honest.

# ---------------------------------------------------------------------------
# The instantiation
# ---------------------------------------------------------------------------

proc newDesktopNativePlatform*(): Platform =
  ## The desktop instantiation for the C backend: the ViewModel suites, the
  ## headless session, `ct host`'s own process, and anything else that runs the
  ## front-end logic natively.
  ##
  ## Clipboard, download and shell are NOT implemented here and refuse: on the
  ## desktop those are Electron's, and Electron is only reachable from the JS
  ## build. `desktop_electron.nim` supplies them. Declaring a narrower profile
  ## here rather than claiming the full desktop set is the whole point of
  ## capabilities being data — a native desktop process genuinely has no
  ## clipboard, and saying so is more useful than a facade that fails at run
  ## time.
  let profile = PlatformProfile(
    kind: pkDesktop,
    displayName: "desktop (native)",
    capabilities: desktopCapabilities - {
      capClipboardRead, capClipboardWrite,
      capDownloadFile, capOpenFileDialog, capSaveFileDialog, capDirectoryPicker,
      capOpenExternalUrl, capRevealInFileManager,
      capWindowControls, capWindowFullscreen, capNativeMenuBar, capMultiWindow,
      capSecretStore, capFilesystemWatch},
    degradations: @[
      DegradationRule(capability: capClipboardRead, behaviour:
        "a native desktop process has no clipboard; the Electron renderer has"),
      DegradationRule(capability: capClipboardWrite, behaviour:
        "a native desktop process has no clipboard; the Electron renderer has"),
      DegradationRule(capability: capDownloadFile, behaviour:
        "there is no browser to hand a file to; write it with the filesystem " &
        "facade instead"),
      DegradationRule(capability: capOpenFileDialog, behaviour:
        "no dialog can be shown from a native process; the path must be given"),
      DegradationRule(capability: capSaveFileDialog, behaviour:
        "no dialog can be shown from a native process; the path must be given"),
      DegradationRule(capability: capDirectoryPicker, behaviour:
        "no dialog can be shown from a native process; the path must be given"),
      DegradationRule(capability: capOpenExternalUrl, behaviour:
        "there is no window server to hand a URL to"),
      DegradationRule(capability: capRevealInFileManager, behaviour:
        "there is no file manager to reveal into"),
      DegradationRule(capability: capWindowControls, behaviour:
        "there is no window"),
      DegradationRule(capability: capWindowFullscreen, behaviour:
        "there is no window"),
      DegradationRule(capability: capNativeMenuBar, behaviour:
        "there is no menu bar"),
      DegradationRule(capability: capMultiWindow, behaviour:
        "there is no window"),
      DegradationRule(capability: capShareLink, behaviour:
        "a desktop project is a directory; the equivalent is an archive export"),
      DegradationRule(capability: capSecretStore, behaviour:
        "no keychain binding exists in this tree yet, so nothing is stored " &
        "rather than something being stored badly"),
      DegradationRule(capability: capFilesystemWatch, behaviour:
        "the desktop watcher is Electron's and lives in the renderer; a " &
        "second native watcher would be a second implementation of one " &
        "capability"),
    ])

  let procFacade = desktopProcess(profile)
  Platform(
    profile: profile,
    fs: desktopFileSystem(profile),
    process: procFacade,
    vcs: nativeVcs(profile),
    settings: desktopSettings(profile),
    clipboard: unavailableClipboard(profile),
    download: unavailableDownload(profile),
    shell: unavailableShell(profile))
