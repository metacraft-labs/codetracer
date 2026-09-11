## plugin_distribution_e2e_test.nim — PLAT-10's verification gate, driven
## through the REAL `ct`.
##
## > "A plugin installs, pins, upgrades and uninstalls **through the existing
## >  commands**, with **no second package mechanism introduced**."
##
## Every state change below is made by `codetracer-launcher/out/launcher` — the
## `--os:standalone --mm:none` binary that repository's `just build` produces —
## running `install`, `update`, `uninstall` and `install --list`. This file
## creates no component directory, downloads nothing, and removes nothing. What
## it does is hand the resulting tree to `plugin_components.discoverPlugins`
## and assert that CodeTracer reads what the package manager wrote.
##
## ## NO MOCKS
##
## The launcher is the shipped binary. The mirror is a real directory served
## over `file://` by the launcher's own `curl`/`wget` probe — the same `dl()`
## the shipped install script uses over `https://`, with a different scheme, so
## the download, the `.sha256` verification, the `tar xzf` and the atomic
## rename are all the product's own code running unmodified. The archives are
## made with `tar` and hashed with `sha256sum`, which is what the script
## verifies against.
##
## One thing is deliberately NOT real and is named here rather than discovered:
## the `bin/` program inside the COMMAND component of suite B is a two-line
## shell script that prints a marker. The boundary under test there is
## `execv` — which path did the launcher choose — and a marker answers that
## exactly. It is the same justification `src/tests/launcher/
## test_launcher_routes_tui.nim` gives for its stubs, at the same boundary.
##
## ## THE PREREQUISITE IS LOUD, AND IT IS LOUD EXACTLY ONCE
##
## A missing launcher build FAILS by name with the recipe that produces it. It
## is never a skip: a suite whose whole subject is "the existing commands do
## this" reporting green because the existing command was absent is the
## silent self-pass this repository has an audit document about.
##
## It also stops there. `runLauncher` has no existence guard, so without the
## build the suite used to produce 18 red cases of 20 — sixteen of them an
## `execvpe` traceback — plus an assertion-count mismatch, and the one legible
## message was buried in the middle of them. A reader looking at that is being
## invited to suspect the suite. The prerequisite case runs, fails by name, and
## the module then `quit`s on `programResult`: one red case, rc 1, with the
## recipe in it. Failing loudly and failing NINETEEN TIMES are different things,
## and only the first of them is the point.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper here is a `template`.
##
## Compile and run:
##   nim c -r --mm:refc src/ct/launch/plugin_distribution_e2e_test.nim

import std/[algorithm, os, osproc, streams, strtabs, strutils, times,
            unittest]

import ./plugin_components
import ../../common/plugin_model

const ExpectedAssertions = 108
  ## Written from a run, and asserted against the tally at the end of the file.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const
  LauncherRecipe = "cd ../codetracer-launcher && just build"
  LauncherBinEnvVar = "CODETRACER_LAUNCHER_BIN"

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let
  root = repoRoot()
  launcherBin =
    if getEnv(LauncherBinEnvVar, "").len > 0: getEnv(LauncherBinEnvVar)
    else: root.parentDir / "codetracer-launcher" / "out" / "launcher"

const
  PlatformToken =
    when defined(macosx):
      when defined(arm64): "darwin-aarch64" else: "darwin-x86_64"
    elif defined(freebsd):
      when defined(arm64): "freebsd-aarch64" else: "freebsd-x86_64"
    else:
      when defined(arm64): "linux-aarch64" else: "linux-x86_64"
    ## `install.nim`'s `S_PLAT`, which is what the download URL carries. It is
    ## spelled here because the MIRROR has to publish under that name; a
    ## mismatch would make every install fail with "all mirrors failed", which
    ## is a legible failure rather than a silent pass.

type
  Run = object
    rc: int
    output: string

# ---------------------------------------------------------------------------
# Driving the real launcher
# ---------------------------------------------------------------------------

proc runLauncher(userRoot, mirror, workDir: string;
                 args: openArray[string]): Run =
  ## The shipped binary, with a controlled environment.
  ##
  ## `CODETRACER_USER_ROOT` is where `install`/`uninstall` write.
  ## `CODETRACER_COMPONENTS_ROOT` is what `install --list` and the ROUTER read,
  ## and it also suppresses the absolute system and distro levels so a
  ## developer's real install cannot answer for this suite.
  ## `CODETRACER_REGISTRY_PATH` and `CODETRACER_BOOTSTRAP_MIRROR` point the
  ## registry at the fixture, so no request leaves the machine.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k.startsWith("CODETRACER_"): continue
    env[k] = v
  env["CODETRACER_USER_ROOT"] = userRoot
  env["CODETRACER_COMPONENTS_ROOT"] = userRoot / "components" / "v1"
  env["CODETRACER_REGISTRY_PATH"] = mirror / "registry" / "v1" / "registry.txt"
  env["CODETRACER_BOOTSTRAP_MIRROR"] = "file://" & mirror
  let p = startProcess(launcherBin, workingDir = workDir, args = @args,
                       env = env, options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()

proc sh(workDir: string; command: string): Run =
  let p = startProcess("/usr/bin/env", workingDir = workDir,
                       args = @["bash", "-c", command],
                       options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()

# ---------------------------------------------------------------------------
# Building a mirror the launcher's own downloader can read
# ---------------------------------------------------------------------------

proc publish(mirror, stage, name, version: string) =
  ## Tar up `<stage>/<name>@<version>` and its checksum, where `install_one`
  ## looks for them: `$M/$C/$V/$C-$V-$PLAT.tar.gz{,.sha256}`.
  let dest = mirror / name / version
  createDir(dest)
  let archive = name & "-" & version & "-" & PlatformToken & ".tar.gz"
  let made = sh(stage, "tar czf " & quoteShell(dest / archive) & " " &
                       quoteShell(name & "@" & version))
  doAssert made.rc == 0, "tar failed: " & made.output
  let hashed = sh(dest,
    "if command -v sha256sum >/dev/null 2>&1; then sha256sum " &
    quoteShell(archive) & " > " & quoteShell(archive & ".sha256") &
    "; else shasum -a 256 " & quoteShell(archive) & " > " &
    quoteShell(archive & ".sha256") & "; fi")
  doAssert hashed.rc == 0, "sha256 failed: " & hashed.output
  # `$M/$C/latest`, which `ct update`'s per-component probe reads FIRST. Without
  # it the update branch falls through to the two hard-coded public mirrors and
  # this suite would depend on the network to answer "not found".
  writeFile(mirror / name / "latest", version & "\n")

proc writeRegistry(mirror: string;
                   components: openArray[tuple[name, latest: string]]) =
  createDir(mirror / "registry" / "v1")
  var text = "mirror file://" & mirror & "\n"
  for c in components:
    text.add "component " & c.name & "\n"
    text.add "latest " & c.latest & "\n"
  writeFile(mirror / "registry" / "v1" / "registry.txt", text)

proc pluginManifest(id, version: string; commands: openArray[string] = [];
                    caps: openArray[string] = []): string =
  var body = "{\n  \"id\": \"" & id & "\",\n  \"version\": \"" & version &
    "\",\n  \"activation\": [{\"event\": \"trace-opened\"}]"
  if caps.len > 0:
    var quoted: seq[string] = @[]
    for c in caps: quoted.add "\"" & c & "\""
    body.add ",\n  \"capabilities\": [" & quoted.join(", ") & "]"
  if commands.len > 0:
    var entries: seq[string] = @[]
    for c in commands:
      entries.add "{\"id\": \"" & c & "\", \"title\": \"" & c & "\"}"
    body.add ",\n  \"contributes\": {\"command\": [" & entries.join(", ") & "]}"
  body & "\n}\n"

proc stagePlugin(stage, name, version: string; commands: openArray[string] = [];
                 caps: openArray[string] = []) =
  let dir = stage / (name & "@" & version)
  createDir(dir)
  writeFile(dir / PluginManifestFile,
            pluginManifest(name, version, commands, caps))

proc stageCommandComponent(stage, name, version, word, marker: string) =
  ## A component of the kind that already exists: a `capabilities` file whose
  ## first token per line is a COMMAND WORD, and a `bin/` the launcher execs.
  let dir = stage / (name & "@" & version)
  createDir(dir / "bin")
  writeFile(dir / CapabilityFile,
            "name " & name & "\nbin " & name & "\n" & word & "\n")
  let binPath = dir / "bin" / name
  writeFile(binPath, "#!/usr/bin/env bash\necho MARKER=" & marker & "\n" &
                     "echo ARG0=\"${1-}\"\nexit 0\n")
  setFilePermissions(binPath, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupExec,
                               fpOthersRead, fpOthersExec})

proc installedDirs(userRoot: string): seq[string] =
  let comps = userRoot / "components" / "v1"
  if not dirExists(comps): return
  for kind, child in walkDir(comps):
    if kind == pcDir: result.add child.lastPathPart
  result.sort()

proc discoverIn(userRoot: string; pins: seq[CtrcPin]): PluginDiscovery =
  ## Discovery over the tree the LAUNCHER built, through the product's own
  ## level resolver. The override is set and restored around the call so this
  ## suite cannot leak a components root into the rest of the lane.
  let hadRoot = existsEnv(componentsRootEnvVar)
  let prior = getEnv(componentsRootEnvVar, "")
  let hadDir = existsEnv(componentDirEnvVar)
  let priorDir = getEnv(componentDirEnvVar, "")
  let hadPath = existsEnv(componentsPathEnvVar)
  let priorPath = getEnv(componentsPathEnvVar, "")
  putEnv(componentsRootEnvVar, userRoot / "components" / "v1")
  delEnv(componentDirEnvVar)
  delEnv(componentsPathEnvVar)
  result = discoverPlugins(collectComponentLevels(), pins)
  if hadRoot: putEnv(componentsRootEnvVar, prior) else: delEnv(componentsRootEnvVar)
  if hadDir: putEnv(componentDirEnvVar, priorDir) else: delEnv(componentDirEnvVar)
  if hadPath: putEnv(componentsPathEnvVar, priorPath)
  else: delEnv(componentsPathEnvVar)

# ---------------------------------------------------------------------------

suite "PLAT-10: the prerequisites are asserted, never skipped":

  test "the real launcher binary is present":
    if not fileExists(launcherBin):
      checkpoint("missing " & launcherBin & " — run `" & LauncherRecipe &
                 "`, or set " & LauncherBinEnvVar)
    ck fileExists(launcherBin)

# THE SHORT-CIRCUIT, AND IT IS NOT A SKIP.
#
# `runLauncher` calls `startProcess(launcherBin, …)` with no existence guard, so
# on a machine without the build every case that drives the launcher raised
# `OSError` and failed on its own — 17 of the 20 cases, sixteen of them with an
# opaque `execvpe` traceback rather than the recipe. The tally then failed too,
# because `countedAssertions` never reached 108, so a runner missing one file
# got **18 red cases and an assertion-count mismatch**, with the one legible
# message buried among them.
#
# That is not a false green — the suite was right to be red, and the loudness
# was deliberate (see this module's header). It is a DIAGNOSTIC failure: the
# transcript names the same missing file eighteen times in seventeen different
# vocabularies, and the tally mismatch invites the reader to suspect the suite
# rather than the machine.
#
# So the prerequisite case still runs, still fails by name, and then the run
# STOPS — one red case, rc 1, with the recipe in it. Nothing is skipped and
# nothing reports green: `programResult` is already 1 from the `check` above,
# and this exits on it.
#
# `quit` rather than a guard on every case, because a guard is a thing the
# NEXT case has to remember, and the twentieth one will not.
if not fileExists(launcherBin):
  echo ""
  echo "PREREQUISITE MISSING — the remaining 19 cases were not run, and that"
  echo "is the whole of this failure rather than the first of nineteen."
  echo "  needed: " & launcherBin
  echo "  build it: " & LauncherRecipe
  echo "  or point at one: " & LauncherBinEnvVar & "=<path>"
  echo ""
  echo "This suite's subject is \"the EXISTING commands do this\". It must not"
  echo "report green without the existing command, and it must not report the"
  echo "same missing file eighteen times either."
  quit(if programResult != 0: programResult else: 1)

suite "PLAT-10: the launcher answers, and the tools its install path needs":

  test "it is the launcher, and it answers":
    let tmp = getTempDir() / ("ct-plat10-ver-" & $getCurrentProcessId())
    createDir(tmp)
    let r = runLauncher(tmp, tmp, tmp, ["--version"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.startsWith("ct ")
    removeDir(tmp)

  test "tar and a sha256 tool are available, because the install path needs them":
    # `install_one` runs `tar xzf` and `$HASH -c`. Without them every install
    # below would fail inside the launcher with a message about mirrors, which
    # is a confusing way to learn that this machine has no `tar`.
    let tmp = getTempDir() / ("ct-plat10-tools-" & $getCurrentProcessId())
    createDir(tmp)
    ckEq sh(tmp, "command -v tar >/dev/null").rc, 0
    ckEq sh(tmp, "command -v sha256sum >/dev/null || " &
                 "command -v shasum >/dev/null").rc, 0
    ckEq sh(tmp, "command -v curl >/dev/null || command -v wget >/dev/null " &
                 "|| command -v fetch >/dev/null").rc, 0
    removeDir(tmp)

suite "PLAT-10: install, pin, upgrade and uninstall, through the real commands":

  setup:
    let tmp = getTempDir() / ("ct-plat10-e2e-" & $getCurrentProcessId() & "-" &
                              $epochTime().int64)
    let userRoot = tmp / "user"
    let mirror = tmp / "mirror"
    let stage = tmp / "stage"
    let project = tmp / "project"
    createDir(userRoot)
    createDir(stage)
    createDir(project)
    stagePlugin(stage, "demo-plugin", "1.0.0", commands = ["hello"])
    stagePlugin(stage, "demo-plugin", "1.1.0", commands = ["hello"])
    publish(mirror, stage, "demo-plugin", "1.0.0")
    publish(mirror, stage, "demo-plugin", "1.1.0")
    writeRegistry(mirror, [(name: "demo-plugin", latest: "1.1.0")])

  teardown:
    removeDir(tmp)

  test "`ct install <name>@<version>` puts a plugin in the component layout":
    let r = runLauncher(userRoot, mirror, project,
                        ["install", "demo-plugin@1.0.0"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("installed demo-plugin@1.0.0")
    # The launcher's layout, not one this file created.
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0"]
    ck fileExists(userRoot / "components" / "v1" / "demo-plugin@1.0.0" /
                  PluginManifestFile)
    # And CodeTracer reads what the package manager wrote.
    let d = discoverIn(userRoot, @[])
    ckEq d.problems.len, 0
    ckEq d.plugins.len, 1
    ckEq $d.plugins[0].component, "demo-plugin@1.0.0"
    ckEq d.plugins[0].level, "user"
    let parsed = parseManifest(d.plugins[0].manifestText,
                               d.plugins[0].manifestPath)
    ck parsed.isOk
    ckEq parsed.manifest.id, "demo-plugin"
    ckEq parsed.manifest.commandIds(), @["hello"]

  test "`ct install <name>` with no version takes the registry's latest":
    let r = runLauncher(userRoot, mirror, project, ["install", "demo-plugin"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("installed demo-plugin@1.1.0")
    ckEq installedDirs(userRoot), @["demo-plugin@1.1.0"]

  test "`ct install --list` is the inventory, and it agrees with discovery":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    let listed = runLauncher(userRoot, mirror, project, ["install", "--list"])
    checkpoint(listed.output)
    ckEq listed.rc, 0
    ck listed.output.contains("COMPONENT  VERSION  LEVEL  PATH")
    ck listed.output.contains("demo-plugin  1.0.0  user")
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 1
    ck listed.output.contains(d.plugins[0].dir)

  test "`ct update` upgrades it, and both versions remain installed":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ckEq discoverIn(userRoot, @[]).plugins[0].component.version, "1.0.0"
    let r = runLauncher(userRoot, mirror, project, ["update"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("demo-plugin")
    ck r.output.contains("1.0.0")
    ck r.output.contains("1.1.0")
    ck r.output.contains("updated demo-plugin@1.1.0")
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0", "demo-plugin@1.1.0"]
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 1
    ckEq d.plugins[0].component.version, "1.1.0"
    ckEq d.plugins[0].selection.rule, vsrHighest

  test "`ct update --check` reports the upgrade without taking it":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    let r = runLauncher(userRoot, mirror, project, ["update", "--check"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("1.1.0")
    ck not r.output.contains("updated demo-plugin")
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0"]

  test "a .ctrc pin decides which installed version CodeTracer loads":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project, ["update"]).rc, 0
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0", "demo-plugin@1.1.0"]
    # The control first: with no pin, the newer one wins.
    ckEq discoverIn(userRoot, @[]).plugins[0].component.version, "1.1.0"
    writeFile(project / ".ctrc", "demo-plugin = 1.0.0\n")
    var pins: seq[CtrcPin]
    let found = loadCtrcPins(project, pins)
    ckEq found.path, project / ".ctrc"
    ckEq pinFor(pins, "demo-plugin"), "1.0.0"
    let pinned = discoverIn(userRoot, pins)
    ckEq pinned.plugins.len, 1
    ckEq pinned.plugins[0].component.version, "1.0.0"
    ckEq pinned.plugins[0].selection.rule, vsrPinned

  test "`ct uninstall <name>@<version>` removes it, and discovery falls back":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project, ["update"]).rc, 0
    let r = runLauncher(userRoot, mirror, project,
                        ["uninstall", "demo-plugin@1.1.0"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("uninstalled demo-plugin@1.1.0")
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0"]
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 1
    ckEq d.plugins[0].component.version, "1.0.0"

  test "uninstalling the last version leaves nothing for CodeTracer to load":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project,
                     ["uninstall", "demo-plugin@1.0.0"]).rc, 0
    ckEq installedDirs(userRoot), newSeq[string]()
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 0
    ck d.report().contains("ct install")

  test "`ct uninstall` without a version is refused by the launcher itself":
    # The version is part of the identity `ct uninstall` takes, and nothing in
    # this repository re-implements that rule.
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    let r = runLauncher(userRoot, mirror, project,
                        ["uninstall", "demo-plugin"])
    checkpoint(r.output)
    ck r.rc != 0
    ck r.output.contains("name@version")
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0"]

  test "the `active` symlink the installer writes is NOT where the router looks":
    # A finding, recorded rather than worked around. `install_one` writes
    # `$R/active/$C` where `$R` is the USER ROOT, and `versionEligible` probes
    # `<level>/active/<name>` where `<level>` is `$R/components/v1`. The two
    # paths differ by one directory, so the launcher's own rule 2 never fires
    # on a tree the launcher itself created — every real install is decided by
    # rule 3, the highest version.
    #
    # `selectVersion` carries the ROUTER's rule, so CodeTracer and `ct` agree;
    # a reader that had followed the INSTALLER instead would disagree with the
    # dispatcher on the first machine that had two versions of anything.
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ck symlinkExists(userRoot / "active" / "demo-plugin")
    ck not symlinkExists(userRoot / "components" / "v1" / "active" /
                         "demo-plugin")
    ckEq activeVersionAt(userRoot / "components" / "v1", "demo-plugin"), ""
    ckEq runLauncher(userRoot, mirror, project, ["update"]).rc, 0
    ckEq discoverIn(userRoot, @[]).plugins[0].selection.rule, vsrHighest

suite "PLAT-10: a plugin component cannot be invoked as `ct <word>`":

  setup:
    let tmp = getTempDir() / ("ct-plat10-word-" & $getCurrentProcessId() & "-" &
                              $epochTime().int64)
    let userRoot = tmp / "user"
    let mirror = tmp / "mirror"
    let stage = tmp / "stage"
    let project = tmp / "project"
    createDir(userRoot)
    createDir(stage)
    createDir(project)
    # The PLUGIN contributes a command called `hello`, in its manifest.
    stagePlugin(stage, "demo-plugin", "1.0.0", commands = ["hello"])
    publish(mirror, stage, "demo-plugin", "1.0.0")
    # The COMMAND COMPONENT declares the same word in a `capabilities` file.
    stageCommandComponent(stage, "demo-tool", "1.0.0", "hello", "TOOL-RAN")
    publish(mirror, stage, "demo-tool", "1.0.0")
    writeRegistry(mirror, [(name: "demo-plugin", latest: "1.0.0"),
                           (name: "demo-tool", latest: "1.0.0")])

  teardown:
    removeDir(tmp)

  test "the plugin's contributed command word does NOT route":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 1
    let parsed = parseManifest(d.plugins[0].manifestText, "x")
    ckEq parsed.manifest.commandIds(), @["hello"]
    # ATTEMPTED, not reasoned about.
    let r = runLauncher(userRoot, mirror, project, ["hello", "an-argument"])
    checkpoint(r.output)
    ck r.rc != 0
    ck r.output.contains("no component handles 'hello'")
    ck not r.output.contains("MARKER=")

  test "neither does the plugin's own component name":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    let r = runLauncher(userRoot, mirror, project, ["demo-plugin"])
    checkpoint(r.output)
    ck r.rc != 0
    ck r.output.contains("no component handles 'demo-plugin'")

  test "THE POSITIVE TWIN: a capability file makes the same word route":
    # Verification-Harness-Traps §4a. Same binary, same components root, same
    # word, same argument — the only difference is which FILE the component
    # carries. Without this, "the launcher refused" would be satisfied by a
    # launcher that had stopped routing anything at all.
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-tool@1.0.0"]).rc, 0
    let r = runLauncher(userRoot, mirror, project, ["hello", "an-argument"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("MARKER=TOOL-RAN")
    ck r.output.contains("ARG0=hello")

  test "with BOTH installed, the word still reaches the tool and not the plugin":
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-plugin@1.0.0"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-tool@1.0.0"]).rc, 0
    ckEq installedDirs(userRoot), @["demo-plugin@1.0.0", "demo-tool@1.0.0"]
    let r = runLauncher(userRoot, mirror, project, ["hello"])
    checkpoint(r.output)
    ckEq r.rc, 0
    ck r.output.contains("MARKER=TOOL-RAN")
    # …and the plugin is still a plugin: discovery finds it and not the tool.
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 1
    ckEq d.plugins[0].component.name, "demo-plugin"
    ckEq d.problems.len, 0

  test "removing the tool takes the word away again":
    # The control for the control: the word routes BECAUSE of the capability
    # file, and stops when it is gone. A `hello` that kept working after the
    # tool was uninstalled would mean something else was answering.
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "demo-tool@1.0.0"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project, ["hello"]).rc, 0
    ckEq runLauncher(userRoot, mirror, project,
                     ["uninstall", "demo-tool@1.0.0"]).rc, 0
    let r = runLauncher(userRoot, mirror, project, ["hello"])
    checkpoint(r.output)
    ck r.rc != 0
    ck r.output.contains("no component handles 'hello'")

  test "a component carrying both files dispatches AND is refused as a plugin":
    # The state the `crAmbiguous` refusal exists for, produced by the real
    # installer: a tarball with both files in it. §8.3's rule is that such a
    # component is not a plugin — and it says so rather than silently
    # preferring one file.
    let dir = stage / "hybrid@1.0.0"
    createDir(dir / "bin")
    writeFile(dir / PluginManifestFile, pluginManifest("hybrid", "1.0.0"))
    writeFile(dir / CapabilityFile, "name hybrid\nbin hybrid\nhybridcmd\n")
    writeFile(dir / "bin" / "hybrid",
              "#!/usr/bin/env bash\necho MARKER=HYBRID-RAN\n")
    setFilePermissions(dir / "bin" / "hybrid",
                       {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                        fpGroupExec, fpOthersRead, fpOthersExec})
    publish(mirror, stage, "hybrid", "1.0.0")
    writeRegistry(mirror, [(name: "hybrid", latest: "1.0.0")])
    ckEq runLauncher(userRoot, mirror, project,
                     ["install", "hybrid@1.0.0"]).rc, 0
    let routed = runLauncher(userRoot, mirror, project, ["hybridcmd"])
    checkpoint(routed.output)
    ckEq routed.rc, 0
    ck routed.output.contains("MARKER=HYBRID-RAN")
    let d = discoverIn(userRoot, @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 1
    ckEq d.problems[0].code, pecPluginAlsoDispatchable
    ck d.problems[0].detail.contains(PluginManifestFile)
    ck d.problems[0].detail.contains(CapabilityFile)

# ---------------------------------------------------------------------------

suite "PLAT-10: the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
