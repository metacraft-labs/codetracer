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
## The second suite holds the rest of that rule: a command is DESCRIBED by the
## component the launcher runs it from, not only found there. A command two
## different components declare runs from the first one -- the higher root,
## and within one root the one the directory listing returns first -- so its
## description, file types and flags must be that component's, though
## `runtime_surface.merge` lets the last surface win. Recorded as reprobuild-pm
## `issues/2026-11-21-ct-help-describes-a-command-with-a-component-the-launcher-does-not-run-for-it.md`.
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
## WHAT IS NOT CHECKED HERE: the launcher itself. These cases do not run it.
## The routing they assert is the launcher's as read in codetracer-launcher
## `src/launcher.nim` (`scanLevelForCommand`) and as measured against a build
## of codetracer-launcher `agents` cc04d24 on Linux/zfs: `ct shared` ran the
## user root's `foo@1` over the system root's `bar@1`, and of `aaa@1` and
## `zzz@1` in one root it ran whichever the listing returned first, in both
## creation orders. `plugin_distribution_e2e_test.nim` is the suite that
## drives the real `ct`.
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

proc install(root, name, version: string; commands: openArray[string];
             fileTypes: openArray[(string, string)] = [];
             extraCapabilities = "";
             capabilityLines: openArray[string] = [];
             withBin = true) =
  ## The layout `ct install` produces: `<root>/<name>@<version>/` holding
  ## `capabilities` and `bin/<name>`. The binary answers
  ## `ct-describe-commands` with the same commands the capabilities declare.
  ## `fileTypes` gives a command's `file-types` line in that output
  ## (`(command, ".ext1 .ext2")`); `extraCapabilities` is appended to the
  ## capabilities file verbatim (a `help-delegate` line, say).
  ## `capabilityLines`, when given, replace the one bare line per command
  ## (`record .py`, `record noext`); `withBin = false` leaves out the `bin`
  ## line.
  let dir = root / (name & "@" & version)
  createDir(dir / "bin")
  var describe = "#!/bin/sh\ncat <<'EOF'\n"
  for c in commands:
    describe.add "command " & c & "\ndescription " & c & " of " & name & "@" &
      version & "\n"
    for (fc, types) in fileTypes:
      if fc == c: describe.add "file-types " & types & "\n"
    describe.add "\n"
  describe.add "EOF\n"
  let bin = dir / "bin" / name
  writeFile(bin, describe)
  setFilePermissions(bin, {fpUserRead, fpUserWrite, fpUserExec})
  let lines = if capabilityLines.len > 0: @capabilityLines else: @commands
  writeFile(dir / "capabilities",
            "name " & name & "\nversion " & version & "\n" &
            (if withBin: "bin " & name & "\n" else: "") &
            lines.join("\n") & "\n" & extraCapabilities)

proc rawOrder(root: string): seq[string] =
  ## The root's entries in the order the directory listing returns them.
  ## This is the launcher's order within one root: its
  ## `scanLevelForCommand` (codetracer-launcher `src/launcher.nim`) walks
  ## `readdir` and keeps the FIRST component declaring the command, replacing
  ## it only for a more specific match or a higher root, never for a later
  ## entry of the same root. `walkDir` reads the same `readdir` stream, and an
  ## unchanged directory lists in the same order every time it is read.
  for _, child in walkDir(root):
    result.add child.lastPathPart

proc firstIn(order: openArray[string]; dirs: openArray[string]): string =
  ## Whichever of `dirs` comes first in `order`.
  for e in order:
    if e in dirs: return e
  ""

proc describedAs(screen, cmd: string): string =
  ## The description `ct --help` prints for `cmd` in its Commands section.
  var inCommands = false
  for line in screen.splitLines:
    if line == "Commands:": inCommands = true; continue
    if inCommands:
      if line.len == 0: break
      let cols = line.strip.splitWhitespace(maxsplit = 1)
      if cols.len == 2 and cols[0] == cmd: return cols[1]
  ""

proc mergedCommand(cmd: string): RuntimeCommand =
  for c in assembleHelp().merged.commands:
    if c.name == cmd: return c

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

suite "help_delegate: a command is described by the component the launcher runs for it":
  # reprobuild-pm issues/2026-11-21-ct-help-describes-a-command-with-a-
  # component-the-launcher-does-not-run-for-it.md. Measured on the real
  # launcher (codetracer-launcher `agents` cc04d24, Linux, zfs): with `foo@1`
  # declaring `shared` in the user root and `bar@1` declaring `shared` and
  # `baronly` in a system root, `ct shared` ran `foo@1` and `ct baronly` ran
  # `bar@1`; with `aaa@1` and `zzz@1` both declaring `shared` in ONE root,
  # `ct shared` ran whichever the directory listing returned first.

  test "two components, two roots: the higher root's component describes the shared command":
    let r = freshRoots()
    install(r.user, "foo", "1", ["shared"])
    install(r.system, "bar", "1", ["shared", "baronly"])
    withRoots(r):
      check findComponentForCommand("shared").name == "foo"
      check findComponentForCommand("baronly").name == "bar"
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check describedAs(screen, "shared") == "shared of foo@1"
      check "shared of bar@1" notin screen
      check describedAs(screen, "baronly") == "baronly of bar@1"

  test "the merged surface (what ct-complete reads) carries the routed component's file types":
    # `completionsForSubcommand` filters path completions by the merged
    # command's `fileTypes`, so a lower root's component must not lend
    # `shared` file types that `foo`, which runs it, does not declare.
    let r = freshRoots()
    install(r.user, "foo", "1", ["shared"], fileTypes = [("shared", ".foo")])
    install(r.system, "bar", "1", ["shared", "baronly"],
            fileTypes = [("shared", ".bar")])
    withRoots(r):
      let cmd = mergedCommand("shared")
      check cmd.description == "shared of foo@1"
      check cmd.fileTypes == @[".foo"]

  test "a lower root's component lends no file types to a command it does not run":
    let r = freshRoots()
    install(r.user, "foo", "1", ["shared"])
    install(r.system, "bar", "1", ["shared"], fileTypes = [("shared", ".bar")])
    withRoots(r):
      check mergedCommand("shared").fileTypes.len == 0

  for order in [["aaa", "zzz"], ["zzz", "aaa"]]:
    test "two components in one root, created " & order[0] & " first: the listing's first describes it":
      let r = freshRoots()
      for name in order:
        install(r.user, name, "1", ["shared"])
      let raw = rawOrder(r.user)
      checkpoint "raw order: " & $raw
      let winner = firstIn(raw, ["aaa@1", "zzz@1"])
      let winnerName = winner.split('@')[0]
      let loserName = if winnerName == "aaa": "zzz" else: "aaa"
      withRoots(r):
        check findComponentForCommand("shared").name == winnerName
        let screen = renderHelpScreen(assembleHelp())
        checkpoint screen
        check describedAs(screen, "shared") == "shared of " & winner
        check ("shared of " & loserName & "@1") notin screen

  test "within one root the SELECTED version's place in the listing orders components":
    # For each pair, `<x>@2` is created first, then `<y>@1`, then `<x>@1`.
    # The launcher considers only `<x>@2` (the highest) and `<y>@1`, in the
    # order the listing returns those two directories; where `<x>@1` sits is
    # irrelevant. Ordering components by the first directory seen for each
    # NAME puts `<x>` first whenever `<x>@1` is listed before `<y>@1`,
    # whatever `<x>@2`'s place. Whether a pair tells the two rules apart
    # depends on the filesystem's listing order (newest first on tmpfs, a
    # name hash on zfs and ext4), so several pairs are tried and the rule is
    # asserted for every one; the case reports how many discriminated.
    const pairs = [("xx", "yy"), ("pa", "qb"), ("m1", "n2"), ("kc", "ld"),
                   ("ra", "sb"), ("te", "uf"), ("vg", "wh"), ("bi", "cj")]
    var discriminating = 0
    for (x, y) in pairs:
      let r = freshRoots()
      install(r.user, x, "2", ["shared"])
      install(r.user, y, "1", ["shared"])
      install(r.user, x, "1", ["shared"])
      let raw = rawOrder(r.user)
      let winner = firstIn(raw, [x & "@2", y & "@1"])
      let byName = firstIn(raw, [x & "@1", x & "@2", y & "@1"]).split('@')[0]
      if byName != winner.split('@')[0]: inc discriminating
      checkpoint "raw order: " & $raw & "; launcher's choice " & winner &
        "; first name seen " & byName
      withRoots(r):
        let comp = findComponentForCommand("shared")
        check comp.name & "@" & comp.version == winner
        check describedAs(renderHelpScreen(assembleHelp()), "shared") ==
          "shared of " & winner
    checkpoint $discriminating & " of " & $pairs.len &
      " pairs discriminated on this filesystem"
    echo "    (", discriminating, " of ", pairs.len,
      " pairs discriminated between selected-directory and first-name order)"

  test "a component listed before the help delegate in its root describes their shared command":
    # The launcher routes `ct record` to whichever of the two the user root's
    # listing returns first; the help delegate's own description comes from
    # this binary's surface (`selfSurface`).
    let r = freshRoots()
    install(r.user, "aaa", "1", ["record"])
    install(r.user, helpDelegateComponentName, "1", ["record"],
            extraCapabilities = "help-delegate\n")
    let raw = rawOrder(r.user)
    let winner = firstIn(raw, ["aaa@1", helpDelegateComponentName & "@1"])
    checkpoint "raw order: " & $raw
    var selfRecord = ""
    for c in selfSurface().commands:
      if c.name == "record": selfRecord = c.description
    check selfRecord.len > 0
    check selfRecord != "record of aaa@1"
    withRoots(r):
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      if winner == "aaa@1":
        check describedAs(screen, "record") == "record of aaa@1"
        check findComponentForCommand("record").name == "aaa"
      else:
        check describedAs(screen, "record") == selfRecord
        check "record of aaa@1" notin screen
        # The help delegate runs it, so no other component is named for it.
        check findComponentForCommand("record").name == ""

  test "with no file argument a bare line outranks a higher root's extension-only line":
    # Measured on the real launcher: with `foo@1` declaring `record .py` in
    # the user root and `bar@1` declaring `record` in a system root,
    # `ct record` ran `bar@1` (an extension-only line does not match without
    # a file argument) and `ct record x.py` ran `foo@1`.
    let r = freshRoots()
    install(r.user, "foo", "1", ["record"], capabilityLines = ["record .py"])
    install(r.system, "bar", "1", ["record"])
    withRoots(r):
      check findComponentForCommand("record").name == "bar"
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check describedAs(screen, "record") == "record of bar@1"
      check "record of foo@1" notin screen

  test "with no file argument a lower root's noext line outranks a higher root's bare line":
    # Measured on the real launcher: `foo@1` `record` in the user root,
    # `bar@1` `record noext` in a system root: `ct record` ran `bar@1`.
    let r = freshRoots()
    install(r.user, "foo", "1", ["record"])
    install(r.system, "bar", "1", ["record"], capabilityLines = ["record noext"])
    withRoots(r):
      check findComponentForCommand("record").name == "bar"
      check describedAs(renderHelpScreen(assembleHelp()), "record") ==
        "record of bar@1"

  test "a command only extension lines declare is still described, by the first":
    # It runs only with a file argument, and is still a command of `ct`.
    let r = freshRoots()
    install(r.user, "foo", "1", ["record"], capabilityLines = ["record .py"])
    install(r.system, "bar", "1", ["record"], capabilityLines = ["record .rb"])
    withRoots(r):
      check findComponentForCommand("record").name == "foo"
      check describedAs(renderHelpScreen(assembleHelp()), "record") ==
        "record of foo@1"
      check "record" in fastTopLevelCommandNames()

  test "a component whose capabilities name no bin runs nothing":
    # Measured on the real launcher: `foo@1` declaring `record` without a
    # `bin` line in the user root, `bar@1` in a system root: `ct record` ran
    # `bar@1`.
    let r = freshRoots()
    install(r.user, "foo", "1", ["record"], withBin = false)
    install(r.system, "bar", "1", ["record"])
    withRoots(r):
      check findComponentForCommand("record").name == "bar"
      check describedAs(renderHelpScreen(assembleHelp()), "record") ==
        "record of bar@1"

  test "ct-complete completes a command where the launcher runs it":
    let r = freshRoots()
    install(r.user, "foo", "1", ["shared"])
    install(r.system, "bar", "1", ["shared", "baronly"])
    install(r.system, helpDelegateComponentName, "1", ["record", "shared"],
            extraCapabilities = "help-delegate\n")
    withRoots(r):
      let shared = completionTarget("shared")
      check not shared.local
      check shared.comp.name == "foo"
      let baronly = completionTarget("baronly")
      check not baronly.local
      check baronly.comp.name == "bar"
      # The help delegate runs `record`: complete it here.
      check completionTarget("record").local
      let unknown = completionTarget("no-such-command")
      check not unknown.local
      check unknown.comp.name == ""

  test "ct-complete delegates a command the help delegate also declares when another component runs it":
    let r = freshRoots()
    install(r.user, "aaa", "1", ["record"])
    install(r.system, helpDelegateComponentName, "1", ["record"],
            extraCapabilities = "help-delegate\n")
    withRoots(r):
      let t = completionTarget("record")
      check not t.local
      check t.comp.name == "aaa"

  test "a row does not offer as available a latest version that is installed below it":
    let r = freshRoots()
    install(r.user, "foo", "1", ["cmd-v1"])
    install(r.system, "foo", "3", ["cmd-v3"])
    writeFile(r.base / "registry" / "registry.txt",
              "component foo\nlatest 3\n  commands cmd-v1 cmd-v3\n")
    withRoots(r):
      check listed("foo") == @["1 (user)", "3 (system)"]
      let screen = renderHelpScreen(assembleHelp())
      checkpoint screen
      check "[3 available]" notin screen

removeDir(scratch)
