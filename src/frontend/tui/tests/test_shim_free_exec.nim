## test_shim_free_exec.nim — a native recorder starts with nothing preloaded,
## and the fixture refuses, naming the library, when something would be.
##
## `fixtures/native_recording` recorded through `env -u LD_PRELOAD`, which
## does not drop agent-harbor's command-trace shim (it loads into a dynamic
## `env` and re-inserts itself on `execve`), so its recordings carried the
## shim and did not replay (codetracer-pm issue
## `2026-11-23-env-u-ld-preload-does-not-drop-the-command-trace-shim-and-shimmed-native-recordings-do-not-replay.md`).
##
## The first suite checks the evidence rule on fake `/proc` contents. The
## second runs real processes with a FAKE `LD_PRELOAD` in this process's
## environment (a path that does not exist, so the loader only warns): the
## unscrubbed probe shows it and `requireShimFree` refuses by name; the
## scrubbed one, the way a recorder is started, is clean. In an agent session
## this process carries the real shim as well, and the scrubbed side is then
## also the proof that the shim's `execve` hook is bypassed.

import std/[os, strutils, unittest]

import ./fixtures/shim_free_exec

const FakeShim = "/nonexistent/libah_command_trace_shim.so"

suite "shimEvidence":
  test "an LD_PRELOAD entry in the environment is evidence":
    let e = shimEvidence("HOME=/h\0LD_PRELOAD=" & FakeShim & "\0PATH=/b\0", "")
    check "LD_PRELOAD" in e
    check FakeShim in e

  test "a mapped command-trace library is evidence, named by its path":
    let maps = "7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libc.so.6\n" &
      "7f02-7f03 r-xp 00000000 00:1f 43 /nix/store/x/lib/libah_command_trace_shim.so\n"
    let e = shimEvidence("HOME=/h\0", maps)
    check "/nix/store/x/lib/libah_command_trace_shim.so" in e

  test "a clean environment and map are no evidence":
    check shimEvidence("HOME=/h\0PATH=/b\0",
                       "7f00-7f01 r-xp 00000000 00:1f 42 /usr/lib/libc.so.6\n") == ""

suite "packedShim":
  test "an rr trace that packed the command-trace library names it":
    let dir = getTempDir() / "packed-shim-test"
    createDir(dir)
    writeFile(dir / "mmap_pack_0_libc.so.6", "")
    check packedShim(dir) == ""
    writeFile(dir / "mmap_pack_1_libah_command_trace_shim.so", "")
    check packedShim(dir) == "mmap_pack_1_libah_command_trace_shim.so"
    removeDir(dir)
    check packedShim(dir) == ""

when defined(linux):
  suite "a recorder's process, started for real":
    let saved = getEnv("LD_PRELOAD")
    let hadPreload = existsEnv("LD_PRELOAD")
    putEnv("LD_PRELOAD", FakeShim)

    test "the environment handed to a recorder has no LD_PRELOAD":
      for entry in shimFreeEnvironment():
        check not entry.startsWith("LD_PRELOAD=")
      check ("LD_PRELOAD=" & FakeShim) in shimFreeEnvironment(scrub = false)

    test "unscrubbed, the probe shows the preload and the fixture refuses by name":
      check FakeShim in shimFreeEvidence(scrub = false)
      expect IOError:
        requireShimFree("the test recorder", scrub = false)
      try:
        requireShimFree("the test recorder", scrub = false)
      except IOError as err:
        check "the test recorder" in err.msg
        check FakeShim in err.msg

    test "scrubbed, the probe is clean and the fixture lets the recorder run":
      check shimFreeEvidence() == ""
      requireShimFree("the test recorder")

    test "execShimFree returns the child's output, exit code and directory":
      let dir = getTempDir() / "shim-free-exec-test"
      createDir(dir)
      writeFile(dir / "probe.txt", "in the working directory\n")
      let r = execShimFree(@["cat", "probe.txt"], workingDir = dir)
      check r.exitCode == 0
      check r.output == "in the working directory\n"
      removeDir(dir)
      check execShimFree(@["false"]).exitCode == 1
      let env = execShimFree(@["cat", "/proc/self/environ"])
      check "LD_PRELOAD=" notin env.output

    if hadPreload: putEnv("LD_PRELOAD", saved) else: delEnv("LD_PRELOAD")
