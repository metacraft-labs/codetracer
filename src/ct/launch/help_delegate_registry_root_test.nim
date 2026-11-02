## `help_delegate.registryRoot` -- where `ct --help`'s "available" section and
## shell completion read the component registry -- follows the launcher's user
## root.
##
## The launcher keeps its registry inside its user root
## (`<root>/registry/v1/registry.txt`), and `CODETRACER_USER_ROOT` moves that
## root: its `ct install`, `ct update` and "Available (not installed)"
## suggestion all read the registry there (codetracer-launcher
## `src/ct_home.nim`, `ulRegistryFile`). `registryRoot` used to skip the
## variable and read `$CODETRACER_HOME/launcher/...` or `$HOME/.codetracer/...`
## instead -- another profile's registry, or none at all.
##
## Pure path resolution: each case sets exactly the variables it is about and
## restores them afterwards, and the only files written are under the temp
## directory (the process runs under the scratch `CODETRACER_HOME` that
## src/frontend/test_support/state_isolation.nim gives every test program).
##
## Build/run:
##   nim c -r --hints:off --warnings:off \
##       src/ct/launch/help_delegate_registry_root_test.nim

import std/[os, unittest]
import ../../common/ct_home
import help_delegate

const resolverVars = ["CODETRACER_REGISTRY_PATH", "CODETRACER_USER_ROOT",
                      "CODETRACER_HOME", "HOME"]

template withResolverEnv(settings: openArray[(string, string)],
                         body: untyped) =
  ## `body` with every variable `registryRoot` reads unset except `settings`;
  ## the process's own values come back afterwards.
  var saved: seq[(string, bool, string)]
  for v in resolverVars:
    saved.add((v, existsEnv(v), getEnv(v)))
    delEnv(v)
  for (k, val) in settings:
    putEnv(k, val)
  try:
    body
  finally:
    for (k, had, val) in saved:
      if had: putEnv(k, val) else: delEnv(k)

# state_isolation.nim set it before anything ran; the cases below unset it only
# inside `withResolverEnv`, which puts it back.
doAssert getEnv("CODETRACER_HOME").len > 0, "not running under a scratch CODETRACER_HOME"

let scratch = getTempDir() / ("ct-registry-root-test-" & $getCurrentProcessId())
let userRoot = scratch / "user root"
let home = scratch / "home"

suite "help_delegate.registryRoot: CODETRACER_USER_ROOT holds the registry":

  test "the registry is under CODETRACER_USER_ROOT, even with CODETRACER_HOME set":
    withResolverEnv({"CODETRACER_USER_ROOT": userRoot, "CODETRACER_HOME": home,
                     "HOME": scratch / "profile"}):
      check registryRoot() == userRoot / "registry" / "v1"
    withResolverEnv({"CODETRACER_USER_ROOT": userRoot}):
      check registryRoot() == userRoot / "registry" / "v1"

  test "readRegistry and readLatestVersion read it there":
    let dir = userRoot / "registry" / "v1"
    createDir(dir / "latest")
    writeFile(dir / "registry.txt",
              "component foo\nlatest 1.2.3\ndescription test component\n")
    writeFile(dir / "latest" / "foo", "1.2.4\n")
    defer: removeDir(scratch)
    withResolverEnv({"CODETRACER_USER_ROOT": userRoot, "CODETRACER_HOME": home}):
      let reg = readRegistry()
      check reg.len == 1
      if reg.len == 1:
        check reg[0].name == "foo"
        check reg[0].latest == "1.2.3"
      check readLatestVersion("foo") == "1.2.4"

  test "CODETRACER_REGISTRY_PATH -- a directory here -- still wins":
    withResolverEnv({"CODETRACER_REGISTRY_PATH": scratch / "regdir",
                     "CODETRACER_USER_ROOT": userRoot, "CODETRACER_HOME": home}):
      check registryRoot() == scratch / "regdir"

  test "unset: exactly the historical locations":
    withResolverEnv({"CODETRACER_HOME": home}):
      check registryRoot() == ctHomeArea(chaLauncher) / "registry" / "v1"
    withResolverEnv({"HOME": "/h"}):
      check registryRoot() == "/h" / ".codetracer" / "registry" / "v1"
    withResolverEnv(newSeq[(string, string)]()):
      check registryRoot() == ""
