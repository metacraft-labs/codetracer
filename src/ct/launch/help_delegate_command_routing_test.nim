## `ct --help`, `ct-describe-commands` and `ct-complete` find a command where
## the LAUNCHER would run it: at the first components root whose selected
## version of some component declares it.
##
## As this repository describes the launcher (`plugin_components.nim`, "A NAME
## IS CLAIMED BY THE FIRST LEVEL THAT OFFERS IT"), it routes by COMMAND. At
## each root it chooses every component's version first and then opens that
## version's `capabilities`; a root whose chosen versions do not declare the
## command offers nothing, and the next root is searched. `help_delegate.scanInstalledComponents` used to keep
## one entry per component NAME, from the first root that held the name. With
## `foo@2` (declaring only `cmd-v2`) in the user root and `foo@1` (declaring
## `cmd-v1`) in a system root, help and completion left out `cmd-v1`, which the
## launcher so described runs from the system root. Recorded as reprobuild-pm
## `issues/2026-11-19-ct-help-claims-a-component-name-at-a-root-whose-version-lacks-the-command.md`.
##
## WHAT IS REAL: the component trees are real directories, each component's
## `bin` is a real executable script that answers `ct-describe-commands`, the
## registry is a real file, and the subjects are the production
## `scanInstalledComponents`, `findComponentForCommand`,
## `fastTopLevelCommandNames`, `assembleHelp` and `renderHelpScreen`, driven
## through the launcher's own `CODETRACER_COMPONENTS_ROOT`,
## `CODETRACER_COMPONENTS_PATH`, `CODETRACER_CTRC_PATH` and
## `CODETRACER_REGISTRY_PATH` overrides. No mocks.
##
## WHAT IS NOT CHECKED HERE: the launcher itself. Its routing is taken from
## this repository's description of it; `plugin_distribution_e2e_test.nim` is
## the suite that drives the real `ct`.
##
## Build/run:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       src/ct/launch/help_delegate_command_routing_test.nim

import std/[os, strutils, unittest]
import help_delegate

const envVars = ["CODETRACER_COMPONENTS_ROOT", "CODETRACER_COMPONENTS_PATH",
                 "CODETRACER_CTRC_PATH", "CODETRACER_REGISTRY_PATH"]

let scratch = getTempDir() / ("ct-help-command-routing-" & $getCurrentProcessId())

var caseNo = 0

type Roots = object
  base, user, system: string

proc freshRoots(): Roots =
  inc caseNo
  result.base = scratch / $caseNo
  removeDir(result.base)
  result.user = result.base / "user"
  result.system = result.base / "system"
  createDir(result.user)
  createDir(result.system)
  createDir(result.base / "registry")

proc install(root, name, version: string; commands: openArray[string]) =
  ## The layout `ct install` produces: `<root>/<name>@<version>/` holding
  ## `capabilities` and `bin/<name>`. The binary answers
  ## `ct-describe-commands` with the same commands the capabilities declare.
  let dir = root / (name & "@" & version)
  createDir(dir / "bin")
  var describe = "#!/bin/sh\ncat <<'EOF'\n"
  for c in commands:
    describe.add "command " & c & "\ndescription " & c & " of " & name & "@" &
      version & "\n\n"
  describe.add "EOF\n"
  let bin = dir / "bin" / name
  writeFile(bin, describe)
  setFilePermissions(bin, {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(dir / "capabilities",
            "name " & name & "\nversion " & version & "\nbin " & name & "\n" &
            commands.join("\n") & "\n")

template withRoots(r: Roots, body: untyped) =
  var saved: seq[(string, bool, string)]
  for v in envVars:
    saved.add((v, existsEnv(v), getEnv(v)))
    delEnv(v)
  putEnv("CODETRACER_COMPONENTS_ROOT", r.user)
  putEnv("CODETRACER_COMPONENTS_PATH", r.system)
  putEnv("CODETRACER_CTRC_PATH", r.base / "no-such.ctrc")
  putEnv("CODETRACER_REGISTRY_PATH", r.base / "registry")
  try:
    body
  finally:
    for (k, had, val) in saved:
      if had: putEnv(k, val) else: delEnv(k)

proc listed(name: string): seq[string] =
  ## `<version> (<level>)` for every entry the scan lists under `name`.
  for c in scanInstalledComponents():
    if c.name == name: result.add c.version & " (" & c.levelLabel & ")"

suite "help_delegate: a command is found at the root the launcher runs it from":

  test "a command only the lower root's version declares is found there":
    let r = freshRoots()
    install(r.user, "foo", "2", ["cmd-v2"])
    install(r.system, "foo", "1", ["cmd-v1"])
    withRoots(r):
      let lower = findComponentForCommand("cmd-v1")
      check lower.name == "foo"
      check lower.version == "1"
      check lower.levelLabel == "system"
      let upper = findComponentForCommand("cmd-v2")
      check upper.version == "2"
      check upper.levelLabel == "user"
      let names = fastTopLevelCommandNames()
      check "cmd-v1" in names
      check "cmd-v2" in names
      check listed("foo") == @["2 (user)", "1 (system)"]

  test "the help screen lists the lower root's command and both versions":
    let r = freshRoots()
    install(r.user, "foo", "2", ["cmd-v2"])
    install(r.system, "foo", "1", ["cmd-v1"])
    withRoots(r):
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check "cmd-v1 of foo@1" in screen
      check "cmd-v2 of foo@2" in screen
      var fooRows: seq[string]
      for line in screen.splitLines:
        let cols = line.splitWhitespace
        if cols.len >= 3 and cols[0] == "foo": fooRows.add cols[1] & " " & cols[2]
      check fooRows == @["2 (user)", "1 (system)"]

  test "a command both versions declare keeps the first root's description":
    # `shared` runs from the user root's `foo@2`, so the help screen must not
    # describe it with `foo@1`'s text, and `foo@1` is listed for `legacy` only.
    let r = freshRoots()
    install(r.user, "foo", "2", ["shared", "cmd-v2"])
    install(r.system, "foo", "1", ["shared", "legacy"])
    withRoots(r):
      check findComponentForCommand("shared").version == "2"
      check findComponentForCommand("legacy").version == "1"
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check "shared of foo@2" in screen
      check "shared of foo@1" notin screen
      check "legacy of foo@1" in screen

  test "the older row of a component does not offer the installed latest":
    let r = freshRoots()
    install(r.user, "foo", "3", ["cmd-v3"])
    install(r.system, "foo", "1", ["cmd-v1"])
    writeFile(r.base / "registry" / "registry.txt",
              "component foo\nlatest 3\n  commands cmd-v3\n")
    withRoots(r):
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check "cmd-v1 of foo@1" in screen
      check "[3 available]" notin screen

  test "the help delegate is listed once, whatever a lower root holds":
    let r = freshRoots()
    install(r.user, helpDelegateComponentName, "2", ["record"])
    install(r.system, helpDelegateComponentName, "1", ["record", "oldcmd"])
    withRoots(r):
      check listed(helpDelegateComponentName) == @["2 (user)"]

  test "a lower root's version that the launcher never reaches is not listed":
    # Both versions declare `cmd`, so the launcher stops at the user root.
    let r = freshRoots()
    install(r.user, "foo", "2", ["cmd"])
    install(r.system, "foo", "1", ["cmd"])
    withRoots(r):
      check findComponentForCommand("cmd").version == "2"
      check listed("foo") == @["2 (user)"]

  test "a command another component declares at a higher root is not reached":
    # `bar` in the user root declares `cmd-v1`, so `ct cmd-v1` never gets to
    # the system root's `foo@1`.
    let r = freshRoots()
    install(r.user, "foo", "2", ["cmd-v2"])
    install(r.user, "bar", "1", ["cmd-v1"])
    install(r.system, "foo", "1", ["cmd-v1"])
    withRoots(r):
      let comp = findComponentForCommand("cmd-v1")
      check comp.name == "bar"
      check comp.levelLabel == "user"
      check listed("foo") == @["2 (user)"]

  test "a lower version in the SAME root is still not consulted":
    # The version is chosen before `capabilities` is read, so `foo@1` beside
    # `foo@2` in one root offers nothing.
    let r = freshRoots()
    install(r.user, "foo", "1", ["cmd-v1"])
    install(r.user, "foo", "2", ["cmd-v2"])
    withRoots(r):
      check findComponentForCommand("cmd-v1").name == ""
      check listed("foo") == @["2 (user)"]

  test "an upgrade offers only commands no installed version runs":
    # The registry's latest `foo` has three commands. `cmd-v1` and `cmd-v2`
    # already run, from different roots; only `cmd-v3` needs the upgrade.
    let r = freshRoots()
    install(r.user, "foo", "2", ["cmd-v2"])
    install(r.system, "foo", "1", ["cmd-v1"])
    writeFile(r.base / "registry" / "registry.txt",
              "component foo\nlatest 3\n  commands cmd-v1 cmd-v2 cmd-v3\n")
    withRoots(r):
      var offered: seq[string]
      for u in assembleHelp().upgradeCommands:
        if u.component == "foo": offered.add u.cmd.name
      check offered == @["cmd-v3"]

  test "no upgrade is offered when the first root already has the latest":
    let r = freshRoots()
    install(r.user, "foo", "3", ["cmd-v3"])
    install(r.system, "foo", "1", ["cmd-v1"])
    writeFile(r.base / "registry" / "registry.txt",
              "component foo\nlatest 3\n  commands cmd-v1 cmd-v3 cmd-v4\n")
    withRoots(r):
      var offered: seq[string]
      for u in assembleHelp().upgradeCommands:
        if u.component == "foo": offered.add u.cmd.name
      check offered.len == 0

removeDir(scratch)
