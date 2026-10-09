## The native host for ``certificate_content_id``: git through the shared
## process bridge (``runquota_process``), temporary files through ``std/os``.
##
## Kept apart from the recipe so the recipe imports no process or filesystem
## API and every other host (Electron, a facade endpoint) drives the same
## code. This module only answers the host's questions; it decides nothing.

import std/[os, tempfiles]

import runquota_process

import certificate_content_id

const
  ContentIdCaptureLimit* = 256 * 1024 * 1024
    ## Per-stream capture bound for one git call. Higher than the provider
    ## bound in ``process_exec`` because ``manifest-v1-sha256`` over a
    ## repository reads every blob through ``git cat-file``; a blob larger
    ## than this makes that computation FAIL (the reply is marked incomplete),
    ## never produce a digest over a prefix.

proc nativeGitRunner(captureLimit: int): ContentGitRunner =
  result = proc(call: GitCall): GitReply {.closure, gcsafe.} =
    var env: seq[string]
    for (key, value) in call.env:
      env.add key & "=" & value
    try:
      var child = launchProcess(commandSpec(
        argv = call.argv, cwd = call.cwd, env = env,
        stdoutLimit = captureLimit, stderrLimit = captureLimit))
      let completion = waitForCompletion(child)
      # The bridge counts bytes before applying its bound, so a count larger
      # than what was kept is exactly "the output was cut".
      GitReply(
        exitCode: (if completion.signaled: -1 else: completion.exitCode),
        stdout: completion.stdout,
        stderr: (if completion.signaled:
                   "git was terminated by signal " & $completion.signal
                 else: completion.stderr),
        complete: not completion.timedOut and
          completion.stdoutBytes == uint64(completion.stdout.len) and
          completion.stderrBytes == uint64(completion.stderr.len))
    except CatchableError as err:
      GitReply(exitCode: -1, stderr: err.msg, complete: true)

proc nativeContentIdHost*(captureLimit = ContentIdCaptureLimit): ContentIdHost =
  ## A host running git on this machine, with temporary indexes under the
  ## OS temporary directory (outside every repository).
  ContentIdHost(
    git: nativeGitRunner(captureLimit),
    makeTempDir: proc(): HostFileResult {.closure, gcsafe.} =
      try:
        HostFileResult(ok: true, path: createTempDir("ct-content-id-", ""))
      except CatchableError as err:
        HostFileResult(error: err.msg),
    copyFile: proc(source, destination: string): HostFileResult {.closure, gcsafe.} =
      if not fileExists(source):
        return HostFileResult(missing: true)
      try:
        copyFile(source, destination)
        HostFileResult(ok: true)
      except CatchableError as err:
        HostFileResult(error: err.msg),
    pathExists: proc(path: string): bool {.closure, gcsafe.} =
      # `symlinkExists` first: a dangling symlink is present in the working
      # tree although `fileExists` follows it and says no.
      symlinkExists(path) or fileExists(path) or dirExists(path),
    removeDir: proc(path: string) {.closure, gcsafe.} =
      if path.len > 0:
        try:
          removeDir(path, checkDir = false)
        except CatchableError:
          # A temporary directory that cannot be removed is litter, not a
          # wrong answer; the id has already been decided.
          discard)
