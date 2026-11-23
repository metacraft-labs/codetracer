## shim_free_exec.nim — run a recorder with nothing preloaded into it, and
## prove it.
##
## A library preloaded into a recorder is recorded with the program, and its
## recording does not replay (codetracer-pm issue
## `2026-11-12-rr-replay-of-a-c-program-that-uses-the-heap-fails-on-the-linux-workstation.md`).
## An agent session preloads agent-harbor's command-trace shim
## (`libah_command_trace_shim.so`) into every process it starts, and the shim
## hooks `execve` to put `LD_PRELOAD` back into each child's environment.
##
## So neither `unset LD_PRELOAD` in a shell nor `env -u LD_PRELOAD` drops it
## when that `env` is a dynamic binary: the shim loads into `env` itself, and
## `env`'s own `execve` re-inserts it. Measured 2026-11-23 on the Linux
## workstation (agent-harbor-cli 0.6.17, coreutils `env` from the Nix
## profile): `env -u LD_PRELOAD printenv LD_PRELOAD` still printed the shim,
## and the recording of the sudoku fixture failed to replay 4 times of 4
## ("Should have written 103 bytes ... only wrote -1"), against 4 of 4
## replays through a static busybox `env`, which never loads the shim
## (codetracer-pm issue
## `2026-11-23-env-u-ld-preload-does-not-drop-the-command-trace-shim-and-shimmed-native-recordings-do-not-replay.md`).
##
## `execShimFree` therefore does not go through libc's `execve`, which the
## shim intercepts in THIS process: it forks and issues the `execve` system
## call directly, with an environment that has no `LD_PRELOAD`. And because
## the dynamic loader can preload by other routes (`/etc/ld.so.preload`),
## `shimFreeEvidence` starts a probe exactly that way and reads its
## `/proc/self/environ` and `/proc/self/maps`: a recorder is started only when
## the probe shows no `LD_PRELOAD` and no command-trace library mapped, and
## `requireShimFree` refuses, naming what it found, otherwise.
##
## A recording made with the shim loaded shows it afterwards too: rr packs
## every mapped library into the trace, so its `rr/` directory holds a
## `mmap_pack_<n>_libah_command_trace_shim.so` (`packedShim`). The fixture
## checks a cached recording for one before reusing it, and a new one after
## recording it.
##
## Off Linux (no `/proc`, and no rr) it falls back to `env -u LD_PRELOAD`, and
## the proof is not available.

import std/[os, osproc, strutils]

when defined(linux):
  import std/posix

  proc rawSyscall(number: clong): clong {.importc: "syscall",
      header: "<unistd.h>", varargs.}
  var SYS_execve {.importc, header: "<sys/syscall.h>".}: clong

const ShimFreeRecipe* = "shim-free-raw-execve-v1"
  ## Part of a recording's cache key: recorded through `execShimFree`, after
  ## `requireShimFree` passed. A recording made any other way (the earlier
  ## `env -u LD_PRELOAD`, which let the shim back in) has a different key
  ## and is recorded again rather than reused.

proc shimFreeEnvironment*(scrub = true): seq[string] =
  ## This process's environment as `NAME=value` entries, without
  ## `LD_PRELOAD` when `scrub` is true.
  for name, value in envPairs():
    if scrub and name == "LD_PRELOAD":
      continue
    result.add name & "=" & value

proc execShimFree*(argv: seq[string]; workingDir = "";
                   scrub = true): tuple[output: string, exitCode: int] =
  ## Runs `argv` (its first entry looked up on PATH when it is not a path,
  ## and passed on as the program's name as written) and
  ## returns its combined stdout and stderr and its exit code. `scrub = false`
  ## keeps `LD_PRELOAD`; it exists so a test can show the refusal.
  doAssert argv.len > 0
  var exe = argv[0]
  if not exe.contains('/'):
    # Not through the symlink: a multi-call binary (coreutils) dispatches on
    # the name it was started by.
    exe = findExe(exe, followSymlinks = false)
    if exe.len == 0:
      raise newException(OSError, argv[0] & " was not found on PATH")
  when defined(linux):
    let cargv = allocCStringArray(argv)
    let cenv = allocCStringArray(shimFreeEnvironment(scrub))
    let cexe = exe.cstring
    let cdir = workingDir.cstring
    var fds: array[2, cint]
    if pipe(fds) != 0:
      raiseOSError(osLastError())
    let pid = fork()
    if pid < 0:
      raiseOSError(osLastError())
    if pid == 0:
      # The child: only async-signal-safe calls until the exec.
      discard close(fds[0])
      discard dup2(fds[1], 1)
      discard dup2(fds[1], 2)
      discard close(fds[1])
      if workingDir.len > 0 and chdir(cdir) != 0:
        exitnow(126)
      discard rawSyscall(SYS_execve, cexe, cargv, cenv)
      exitnow(127)
    discard close(fds[1])
    var buffer: array[8192, char]
    while true:
      let n = read(fds[0], addr buffer[0], buffer.len)
      if n > 0:
        let start = result.output.len
        result.output.setLen(start + n)
        copyMem(addr result.output[start], addr buffer[0], n)
      elif n == 0 or errno != EINTR:
        break
    discard close(fds[0])
    var status: cint
    while waitpid(pid, status, 0) < 0 and errno == EINTR:
      discard
    result.exitCode =
      if WIFEXITED(status): int(WEXITSTATUS(status))
      else: 128 + int(WTERMSIG(status))
    deallocCStringArray(cargv)
    deallocCStringArray(cenv)
  else:
    let prefix = if scrub: @["env", "-u", "LD_PRELOAD"] else: @[]
    result = execCmdEx(quoteShellCommand(prefix & @[exe] & argv[1 .. ^1]),
                       workingDir = workingDir)

proc shimEvidence*(environ, maps: string): string =
  ## What, in a process's `/proc/<pid>/environ` (NUL-separated) and
  ## `/proc/<pid>/maps`, says something was preloaded into it; "" when
  ## nothing does.
  for entry in environ.split('\0'):
    if entry.startsWith("LD_PRELOAD="):
      return "LD_PRELOAD is set in its environment (" & entry & ")"
  for line in maps.splitLines:
    if "command_trace" in line:
      let fields = line.splitWhitespace
      return "a command-trace library is mapped into it (" &
        (if fields.len > 0: fields[^1] else: line) & ")"
  ""

proc shimFreeEvidence*(scrub = true): string =
  ## Starts a probe the way `execShimFree` starts a recorder and returns
  ## what was preloaded into it, or "" when nothing was.
  when defined(linux):
    let environ = execShimFree(@["cat", "/proc/self/environ"], scrub = scrub)
    let maps = execShimFree(@["cat", "/proc/self/maps"], scrub = scrub)
    if environ.exitCode != 0 or maps.exitCode != 0:
      return "the probe could not read its own /proc entries:\n" &
        environ.output & maps.output
    shimEvidence(environ.output, maps.output)
  else:
    ""

proc requireShimFree*(what: string; scrub = true) =
  ## Raises, naming what was preloaded, unless a process started like the
  ## recorder `what` would be has nothing preloaded.
  let evidence = shimFreeEvidence(scrub)
  if evidence.len > 0:
    raise newException(IOError, "refusing to run " & what & ": a process " &
      "started for it is not shim-free: " & evidence & ". Its recording " &
      "would carry the preloaded library and not replay.")

proc packedShim*(rrDir: string): string =
  ## The command-trace library rr packed into the trace `rrDir`, "" when it
  ## packed none: a recording made with the shim loaded into rr.
  if dirExists(rrDir):
    for kind, path in walkDir(rrDir):
      if kind in {pcFile, pcLinkToFile} and "command_trace" in path.extractFilename:
        return path.extractFilename
  ""
