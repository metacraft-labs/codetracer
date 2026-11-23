## `ct --help`, `ct-describe-commands` and `ct-complete` take each installed
## component at the version the LAUNCHER would run, not at whichever
## `<name>@<version>` directory the listing happens to return first.
##
## `help_delegate.scanInstalledComponents` used to walk a components root and
## keep the first `<name>@<version>` it met for each name. With `foo@1` and
## `foo@2` in one root, readdir order decided: hash order on ext4, creation
## order on btrfs, newest first on tmpfs. Recorded as reprobuild-pm
## `issues/2026-11-18-ct-help-component-version-choice-depends-on-readdir-order.md`.
## The launcher's rule (`plugin_model.selectVersion`, read through
## `plugin_components.selectedVersionsAt`) is a `.ctrc` pin, then
## `<level>/active/<name>`, then the highest version, chosen per level before
## any `capabilities` file is opened.
##
## WHAT IS REAL: the component trees are real directories (on /dev/shm when it
## exists, because tmpfs lists newest first and so makes the old behaviour pick
## the OLDER version in one of the two creation orders), `active/foo` is a real
## symlink, the `.ctrc` is a real file, and the subject is the production
## `scanInstalledComponents` / `findComponentForCommand`, driven through the
## launcher's own `CODETRACER_COMPONENTS_ROOT`, `CODETRACER_COMPONENTS_PATH`
## and `CODETRACER_CTRC_PATH` overrides. No mocks.
##
## Every case is run with each version directory created in BOTH orders, so a
## result that depended on the listing order fails one of the two on any
## filesystem whose order follows creation (tmpfs, btrfs).
##
## Build/run:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       src/ct/launch/help_delegate_version_choice_test.nim

import std/[os, unittest]
import help_delegate

const envVars = ["CODETRACER_COMPONENTS_ROOT", "CODETRACER_COMPONENTS_PATH",
                 "CODETRACER_CTRC_PATH"]

let scratchBase =
  if dirExists("/dev/shm"): "/dev/shm" else: getTempDir()
let scratch = scratchBase / ("ct-help-version-choice-" & $getCurrentProcessId())

var caseNo = 0

proc freshDir(): string =
  inc caseNo
  result = scratch / $caseNo
  removeDir(result)
  createDir(result)

proc install(root, name, version, command: string) =
  ## The layout `ct install` produces: `<root>/<name>@<version>/capabilities`.
  ## Each version declares its OWN command, so the command that routes shows
  ## which version was taken. The `bin` line is there because the launcher
  ## passes over a component whose capabilities name none.
  let dir = root / (name & "@" & version)
  createDir(dir)
  writeFile(dir / "capabilities",
            "name " & name & "\nversion " & version & "\nbin " & name & "\n" &
            command & "\n")

template withLauncherEnv(settings: openArray[(string, string)], body: untyped) =
  var saved: seq[(string, bool, string)]
  for v in envVars:
    saved.add((v, existsEnv(v), getEnv(v)))
    delEnv(v)
  for (k, val) in settings:
    putEnv(k, val)
  try:
    body
  finally:
    for (k, had, val) in saved:
      if had: putEnv(k, val) else: delEnv(k)

template versionOf(compName: string): string =
  var v = "<not listed>"
  for c in scanInstalledComponents():
    if c.name == compName:
      v = c.version
      break
  v

const orders = [@["1", "2"], @["2", "1"]]

proc commandFor(v: string): string = "cmd-v" & v

suite "help_delegate: one root, two versions of a component":

  test "the highest version wins, whichever was created first":
    for order in orders:
      let root = freshDir()
      for v in order: install(root, "foo", v, commandFor(v))
      withLauncherEnv({"CODETRACER_COMPONENTS_ROOT": root,
                       "CODETRACER_CTRC_PATH": root / "no-such.ctrc"}):
        checkpoint "created in order " & $order
        check versionOf("foo") == "2"
        check findComponentForCommand(commandFor("2")).version == "2"
        check findComponentForCommand(commandFor("1")).name == ""

  test "an active/<name> symlink beats the highest version":
    for order in orders:
      let root = freshDir()
      for v in order: install(root, "foo", v, commandFor(v))
      createDir(root / "active")
      createSymlink(root / "foo@1", root / "active" / "foo")
      withLauncherEnv({"CODETRACER_COMPONENTS_ROOT": root,
                       "CODETRACER_CTRC_PATH": root / "no-such.ctrc"}):
        checkpoint "created in order " & $order
        check versionOf("foo") == "1"
        check findComponentForCommand(commandFor("1")).version == "1"
        check findComponentForCommand(commandFor("2")).name == ""

  test "a .ctrc pin beats both":
    for order in orders:
      let root = freshDir()
      for v in order: install(root, "foo", v, commandFor(v))
      writeFile(root / "pins.ctrc", "foo = 1\n")
      withLauncherEnv({"CODETRACER_COMPONENTS_ROOT": root,
                       "CODETRACER_CTRC_PATH": root / "pins.ctrc"}):
        checkpoint "created in order " & $order
        check versionOf("foo") == "1"
        check findComponentForCommand(commandFor("1")).version == "1"

  test "a pin absent from the first root falls through to the next root":
    for order in orders:
      let root = freshDir()
      let userRoot = root / "user"
      let systemRoot = root / "system"
      createDir(userRoot)
      createDir(systemRoot)
      install(userRoot, "foo", "2", commandFor("2"))
      for v in order: install(systemRoot, "foo", v, commandFor(v))
      writeFile(root / "pins.ctrc", "foo = 1\n")
      withLauncherEnv({"CODETRACER_COMPONENTS_ROOT": userRoot,
                       "CODETRACER_COMPONENTS_PATH": systemRoot,
                       "CODETRACER_CTRC_PATH": root / "pins.ctrc"}):
        checkpoint "created in order " & $order
        let comp = findComponentForCommand(commandFor("1"))
        check comp.version == "1"
        check comp.levelLabel == "system"

removeDir(scratch)
