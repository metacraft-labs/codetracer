## test_gpui_child_env.nim — the contract of `gpui_child_env.gpuiChildEnv`
## and of `gpuiLibraryPath`: the environment GPUI suites give the
## `codetracer-gpui` they start.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_gpui_child_env.nim
##
## Why it is pinned on its own: the two PLAT-44 suites once started the binary
## with a FRESH environment holding only the shim's directory as
## `LD_LIBRARY_PATH`. That fails only where the shim's own libraries are found
## through the environment (NixOS); elsewhere the loader's default path hides
## it (codetracer-pm issue 2026-10-22, "plat44 gpui suites spawn the binary
## with only the shim dir on LD_LIBRARY_PATH"). These cases fail on ANY host
## when the inherited environment is dropped: they set the inherited values
## themselves, and the last case reads them back from a real child process
## started with the helper's table.
##
## The cases set and restore real variables of THIS process (`putEnv` /
## `delEnv`), since the helper's input is the process environment. Every
## `LD_LIBRARY_PATH` case sets or removes `CODETRACER_GPUI_RUNTIME_LIB_PATH`
## too, so the dev shell's own value cannot decide an expectation.
##
## No mocks: the real process environment and a real `/bin/sh` child.

import std/[os, osproc, streams, strtabs, strutils, tables, tempfiles,
            unittest]

import ./gpui_child_env

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 27
    ## Measured. 25 -> 27 (2026-10-26): the library-path rule became its own
    ## `gpuiLibraryPath`, and a case asserts `gpuiChildEnv` uses it (+2, one
    ## per environment shape). A case that stops asserting, or a child whose
    ## output is not the five lines it is asked for, moves it.
  Sentinel = "CT_GPUI_CHILD_ENV_SENTINEL"
  SentinelValue = "inherited value: with spaces, ':' and '='"
  ShimDir = "/nonexistent/isonim-gpui/rust/target/debug"
  InheritedLibs = "/nix/store/inherited-a/lib:/nix/store/inherited-b/lib"
  RuntimeLibs = "/nix/store/libxcb/lib:/nix/store/libxkbcommon/lib"

proc withEnv(vars: openArray[(string, string)]; unset: openArray[string];
             body: proc ()) =
  ## Runs `body` with `vars` set and `unset` removed from this process's
  ## environment, then puts every one of them back as it was (an inherited
  ## `LD_LIBRARY_PATH` included, so the next case and the next suite in the
  ## lane see the host's real value).
  var saved: seq[(string, bool, string)] = @[]
  for (k, _) in vars: saved.add (k, existsEnv(k), getEnv(k))
  for k in unset: saved.add (k, existsEnv(k), getEnv(k))
  try:
    for (k, v) in vars: putEnv(k, v)
    for k in unset: delEnv(k)
    body()
  finally:
    for (k, had, v) in saved:
      if had: putEnv(k, v) else: delEnv(k)

proc processEnv(): Table[string, string] =
  for k, v in envPairs(): result[k] = v

suite "gpuiChildEnv: the inherited environment survives":

  test "an inherited variable, PATH and HOME reach the child's table":
    withEnv([(Sentinel, SentinelValue)], []) do ():
      let state = createTempDir("gpui-child-env-", "")
      try:
        let env = gpuiChildEnv(ShimDir, state)
        ck env.hasKey(Sentinel)
        ck env.getOrDefault(Sentinel) == SentinelValue
        # PATH is what a shell-out of the child resolves through; HOME is
        # what any library under it falls back on. Both are inherited
        # unchanged.
        ck env.getOrDefault("PATH") == getEnv("PATH")
        ck env.getOrDefault("HOME") == getEnv("HOME")
      finally:
        removeDir(state)

  test "the call does not change this process's environment":
    withEnv([(Sentinel, SentinelValue), ("LD_LIBRARY_PATH", InheritedLibs),
             (RuntimeLibPathEnvVar, RuntimeLibs)], []) do ():
      let state = createTempDir("gpui-child-env-", "")
      try:
        let before = processEnv()
        discard gpuiChildEnv(ShimDir, state)
        ck processEnv() == before
        ck getEnv("LD_LIBRARY_PATH") == InheritedLibs
      finally:
        removeDir(state)

suite "gpuiLibraryPath: the child's LD_LIBRARY_PATH":

  test "the shim's directory is PREPENDED to an inherited value":
    withEnv([("LD_LIBRARY_PATH", InheritedLibs)], [RuntimeLibPathEnvVar]) do ():
      ck gpuiLibraryPath(ShimDir) == ShimDir & ":" & InheritedLibs

  test "unset inherited value: exactly the shim's directory":
    withEnv([], ["LD_LIBRARY_PATH", RuntimeLibPathEnvVar]) do ():
      ck gpuiLibraryPath(ShimDir) == ShimDir

  test "EMPTY inherited values: exactly the shim's directory, no empty element":
    # `shimDir & ":"` would end the list with an empty element, which ld.so
    # reads as the current directory.
    withEnv([("LD_LIBRARY_PATH", ""), (RuntimeLibPathEnvVar, "")], []) do ():
      let ld = gpuiLibraryPath(ShimDir)
      ck ld == ShimDir
      ck not ld.endsWith(":")

  test "the dev shell's GPUI runtime libraries follow the shim's directory":
    # The libraries a `gpui-backend` shim links (`libxcb`, `libxkbcommon`):
    # the dev shell keeps them off `LD_LIBRARY_PATH`, so the child gets them
    # from here, ahead of the inherited value.
    withEnv([("LD_LIBRARY_PATH", InheritedLibs),
             (RuntimeLibPathEnvVar, RuntimeLibs)], []) do ():
      ck gpuiLibraryPath(ShimDir) ==
        ShimDir & ":" & RuntimeLibs & ":" & InheritedLibs
    withEnv([(RuntimeLibPathEnvVar, RuntimeLibs)], ["LD_LIBRARY_PATH"]) do ():
      let ld = gpuiLibraryPath(ShimDir)
      ck ld == ShimDir & ":" & RuntimeLibs
      ck not ld.endsWith(":")

  test "gpuiChildEnv's LD_LIBRARY_PATH is gpuiLibraryPath's":
    # The two spellings the suites use (the whole table, or only this
    # variable in a table of their own) must not drift apart.
    withEnv([("LD_LIBRARY_PATH", InheritedLibs),
             (RuntimeLibPathEnvVar, RuntimeLibs)], []) do ():
      ck gpuiChildEnv(ShimDir, "/unused-state").getOrDefault(
        "LD_LIBRARY_PATH") == gpuiLibraryPath(ShimDir)
    withEnv([], ["LD_LIBRARY_PATH", RuntimeLibPathEnvVar]) do ():
      ck gpuiChildEnv(ShimDir, "/unused-state").getOrDefault(
        "LD_LIBRARY_PATH") == gpuiLibraryPath(ShimDir)

suite "gpuiChildEnv: the case's own state":

  test "layout dir, XDG_STATE_HOME and CODETRACER_HOME are the case's":
    # The parent's values are decoys: the child must get the case's, not
    # inherit these.
    withEnv([("CODETRACER_TUI_LAYOUT_DIR", "/decoy/layout"),
             ("XDG_STATE_HOME", "/decoy/xdg-state"),
             ("CODETRACER_HOME", "/decoy/ct-home")], []) do ():
      let state = createTempDir("gpui-child-env-", "")
      try:
        let env = gpuiChildEnv(ShimDir, state)
        ck env.getOrDefault("CODETRACER_TUI_LAYOUT_DIR") == state
        ck env.getOrDefault("XDG_STATE_HOME") == state
        let home = env.getOrDefault("CODETRACER_HOME")
        ck home == state / "ct-home"
        ck home.isRelativeTo(state)
        ck home != state
      finally:
        removeDir(state)

suite "gpuiChildEnv: what a real child sees":

  test "a /bin/sh child started with the table reads the inherited values":
    # The plat44 regression, detectable on any host: a child started with the
    # helper's table must see the inherited sentinel and the PREPENDED
    # library path, not a fresh environment.
    withEnv([(Sentinel, SentinelValue), ("LD_LIBRARY_PATH", InheritedLibs),
             (RuntimeLibPathEnvVar, RuntimeLibs)], []) do ():
      let state = createTempDir("gpui-child-env-", "")
      try:
        let p = startProcess("/bin/sh",
          args = @["-c", "printf '%s\\n' \"$" & Sentinel & "\" " &
                         "\"$LD_LIBRARY_PATH\" \"$CODETRACER_HOME\" " &
                         "\"$XDG_STATE_HOME\" \"$PATH\""],
          env = gpuiChildEnv(ShimDir, state), options = {})
        let output = p.outputStream.readAll()
        let rc = p.waitForExit()
        p.close()
        checkpoint("child output: " & output)
        ck rc == 0
        let lines = output.strip(leading = false, chars = {'\n'}).split('\n')
        ck lines.len == 5
        if lines.len == 5:
          ck lines[0] == SentinelValue
          ck lines[1] == ShimDir & ":" & RuntimeLibs & ":" & InheritedLibs
          ck lines[2] == state / "ct-home"
          ck lines[3] == state
          ck lines[4] == getEnv("PATH")
      finally:
        removeDir(state)

suite "gpuiChildEnv — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS == ExpectedAssertions
