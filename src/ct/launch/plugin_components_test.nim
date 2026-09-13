## plugin_components_test.nim — PLAT-10's discovery half, against a REAL
## filesystem.
##
## ## WHAT IS REAL HERE
##
## Every directory below is created on disk, every `.ctrc` is a file the walk
## finds by walking, and `active/<name>` is a symlink the KERNEL resolves —
## `activeVersionAt` calls `expandSymlink`, so a case asserting the
## active-symlink rule is asserting something about a link and not about a
## string. The component trees have the layout `ct install` produces, and
## `plugin_distribution_e2e_test.nim` is the suite that proves that by making
## the real `ct` produce one.
##
## ## NO MOCKS
##
## There is no filesystem stand-in, no fake level list and no injected clock.
## `collectComponentLevels()` is the product's own resolver, driven through the
## same `CODETRACER_COMPONENTS_ROOT` / `CODETRACER_COMPONENTS_PATH` overrides
## the launcher itself honours — which is why the override exists, and is what
## `component_roots.nim`'s header calls "a test isolation switch".
##
## ## THE ENVIRONMENT IS SAVED AND RESTORED
##
## These cases `putEnv` four variables the rest of the process also reads. Each
## fixture records the prior values and puts them back, because a suite that
## left `CODETRACER_COMPONENTS_ROOT` pointing at a deleted temporary directory
## would make every later case in the same lane silently discover nothing —
## which is Verification-Harness-Traps §4's empty set, arriving through the
## environment.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper here is a `template`. A `check` inside a plain `proc`
## assigns a module-level `testStatusIMPL` and the case prints the failed
## comparison and then reports `[OK]`.
##
## Compile and run:
##   nim c -r --mm:refc src/ct/launch/plugin_components_test.nim

import std/[algorithm, os, osproc, random, strutils, times, unittest]

import ./plugin_components
import ./grant_store
import ../../common/plugin_model

# ---------------------------------------------------------------------------
# CHILD MODE — this binary is its own fixture for the concurrency case
# ---------------------------------------------------------------------------
#
# "Two writers race" is not a property a single process can measure, and it is
# not a property a mock can measure either: the thing under test is what the
# KERNEL does when two `open`/`write`/`rename` sequences interleave, and a
# stand-in for the filesystem would be a stand-in for the entire subject.
#
# So the case spawns THIS BINARY, several times, with an argv that makes it do
# one read-modify-write of the ledger and exit. Real processes, real
# descriptors, a real advisory lock — and no second program to build, which is
# what keeps the suite runnable from `nim c -r` with nothing staged.
#
# IT RUNS BEFORE `unittest` SEES argv, and exits, so the suites below are never
# entered in a child. `unittest` reads the command line for case-name filters;
# a child that fell through to it would run the whole suite recursively.

const
  LedgerWriterFlag = "--plat10-ledger-writer"
  ConcurrentWriters = 4
  GrantsPerWriter = 8
    ## Eight, not one. A single grant each is a race a no-lock implementation
    ## can WIN by accident — the window is microseconds wide — and a case that
    ## passes sometimes is worse than no case. Measured with the lock removed,
    ## 32 interleaved read-modify-writes lost entries on every run (8, 8 and 25
    ## survived); one each would not have. See the case for the full numbers.

if paramCount() == 3 and paramStr(1) == LedgerWriterFlag:
  let childPath = paramStr(2)
  let childName = paramStr(3)
  for i in 0 ..< GrantsPerWriter:
    let cap = if i mod 2 == 0: capProcess else: capFsRead
    let who = childName & "-" & $i
    let err = updateGrantLedgerAt(childPath, proc(l: var GrantLedger) =
      discard l.grant(who, cap, "2026-09-11T00:00:00Z", "concurrent writer"))
    if err.len > 0:
      stderr.writeLine err
      quit(1)
  quit(0)

const ExpectedAssertions = 147
  ## Written from a run, and asserted against the tally at the end of the file.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

const
  EnvNames = [componentsRootEnvVar, componentsPathEnvVar, componentDirEnvVar,
              ctrcPathEnvVar, userRootEnvVar]

type
  EnvSnapshot = object
    values: seq[(string, string, bool)]

proc snapshotEnv(): EnvSnapshot =
  for n in EnvNames:
    result.values.add (n, getEnv(n, ""), existsEnv(n))

proc restoreEnv(s: EnvSnapshot) =
  for (n, v, present) in s.values:
    if present: putEnv(n, v)
    else: delEnv(n)

proc isolateEnv() =
  ## Every variable this module reads, set to a known state. `delEnv` rather
  ## than `putEnv ""`, because `component_roots` tests LENGTH and an empty
  ## string is the same as absent there — but `existsEnv` is not, and a later
  ## `restoreEnv` has to be able to tell them apart.
  for n in EnvNames: delEnv(n)

proc writeComponent(root, name, version: string; manifest = "";
                    capabilities = "") =
  ## The layout `install_one` produces: `<root>/<name>@<version>/`, with
  ## whichever of the two files the caller asked for.
  let dir = root / (name & "@" & version)
  createDir(dir)
  if manifest.len > 0: writeFile(dir / PluginManifestFile, manifest)
  if capabilities.len > 0: writeFile(dir / CapabilityFile, capabilities)

proc manifestFor(id: string; version = "1.0.0"; caps: seq[string] = @[]): string =
  var body = "{\"id\": \"" & id & "\", \"version\": \"" & version & "\", " &
    "\"activation\": [{\"event\": \"trace-opened\"}]"
  if caps.len > 0:
    var quoted: seq[string] = @[]
    for c in caps: quoted.add "\"" & c & "\""
    body.add ", \"capabilities\": [" & quoted.join(", ") & "]"
    if "fs:read" in caps:
      body.add ", \"paths\": {\"read\": [\"/tmp\"]}"
  body & "}"

proc makeActive(root, name, version: string) =
  ## `install_one`'s own `ln -sfn "../components/v1/$C@$V" "$R/active/$C"`,
  ## except that this fixture's root IS the components directory, so the
  ## target is a sibling. `activeVersionAt` reads the TARGET's text and never
  ## follows it to a directory, exactly as `versionEligible` does.
  createDir(root / "active")
  let link = root / "active" / name
  if symlinkExists(link): removeFile(link)
  createSymlink("../" & name & "@" & version, link)

proc names(d: PluginDiscovery): seq[string] =
  for p in d.plugins: result.add $p.component

proc codes(d: PluginDiscovery): seq[PluginErrorCode] =
  for e in d.problems: result.add e.code

# ---------------------------------------------------------------------------

suite "PLAT-10: a plugin is discovered where `ct install` put it":

  setup:
    let saved = snapshotEnv()
    let tmp = getTempDir() / ("ct-plat10-disc-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64 & "-" & $rand(1 shl 30))
    let userRoot = tmp / "user" / "components" / "v1"
    createDir(userRoot)
    isolateEnv()
    putEnv(componentsRootEnvVar, userRoot)

  teardown:
    restoreEnv(saved)
    removeDir(tmp)

  test "one installed plugin, found, with the level and the rule it was chosen by":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.problems.len, 0
    ckEq d.plugins.len, 1
    ckEq d.plugins[0].component.name, "demo-plugin"
    ckEq d.plugins[0].component.version, "1.0.0"
    ckEq d.plugins[0].level, "user"
    ckEq d.plugins[0].selection.rule, vsrHighest
    ckEq d.plugins[0].dir, userRoot / "demo-plugin@1.0.0"
    ckEq d.plugins[0].manifestPath, userRoot / "demo-plugin@1.0.0" / "plugin.json"
    ck d.plugins[0].pinnable

  test "the discovered text is a manifest the REAL parser accepts":
    # Not "a file was read": the bytes are handed to `parseManifest`, which is
    # the same function the host uses, and the id that comes out is compared
    # with the component name it was installed as.
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin", caps = @["fs:read"]))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 1
    let parsed = parseManifest(d.plugins[0].manifestText,
                               d.plugins[0].manifestPath)
    ck parsed.isOk
    ckEq parsed.manifest.id, "demo-plugin"
    ckEq parsed.manifest.capabilities, {capFsRead}
    ckEq parsed.manifest.id, d.plugins[0].component.name

  test "an id that is not the component name is refused, naming both commands":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("somebody.else"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 1
    let parsed = parseManifest(d.plugins[0].manifestText, "x")
    ck parsed.isOk
    ck parsed.manifest.id != d.plugins[0].component.name
    let e = identityProblem(d.plugins[0], parsed.manifest)
    ckEq e.code, pecPluginIdComponentMismatch
    ck e.namesPlugin()
    ck e.detail.contains("ct install demo-plugin")
    ck e.detail.contains("ct uninstall demo-plugin@1.0.0")
    ck e.detail.contains("somebody.else")

  test "the highest version wins, and the others are not returned":
    for v in ["1.0.0", "1.2.0", "1.1.0"]:
      writeComponent(userRoot, "demo-plugin", v,
                     manifest = manifestFor("demo-plugin", v))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.names(), @["demo-plugin@1.2.0"]
    ckEq d.plugins[0].selection.rule, vsrHighest
    # The other two are STILL INSTALLED — this is a selection, not a removal,
    # which is what makes the pin below able to reach one of them.
    ck dirExists(userRoot / "demo-plugin@1.0.0")
    ck dirExists(userRoot / "demo-plugin@1.1.0")

  test "a REAL `active` symlink beats the highest version":
    for v in ["1.0.0", "2.0.0"]:
      writeComponent(userRoot, "demo-plugin", v,
                     manifest = manifestFor("demo-plugin", v))
    # The control first: with no symlink the answer is 2.0.0. Without it, a
    # discovery that had stopped reading symlinks would look identical to one
    # that read this one correctly if the fixture's highest happened to match.
    let before = discoverPlugins(collectComponentLevels(), @[])
    ckEq before.names(), @["demo-plugin@2.0.0"]
    ckEq before.plugins[0].selection.rule, vsrHighest
    makeActive(userRoot, "demo-plugin", "1.0.0")
    ck symlinkExists(userRoot / "active" / "demo-plugin")
    ckEq activeVersionAt(userRoot, "demo-plugin"), "1.0.0"
    let after = discoverPlugins(collectComponentLevels(), @[])
    ckEq after.names(), @["demo-plugin@1.0.0"]
    ckEq after.plugins[0].selection.rule, vsrActiveSymlink

  test "a DANGLING `active` symlink selects nothing, rather than falling back":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"))
    makeActive(userRoot, "demo-plugin", "7.7.7")
    ckEq activeVersionAt(userRoot, "demo-plugin"), "7.7.7"
    ck not dirExists(userRoot / "demo-plugin@7.7.7")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 0

  test "the `active` directory is never itself read as a component":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"))
    makeActive(userRoot, "demo-plugin", "1.0.0")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.names(), @["demo-plugin@1.0.0"]
    ckEq d.problems.len, 0

suite "PLAT-10: .ctrc pins select the version, from a file on disk":

  setup:
    let saved = snapshotEnv()
    let tmp = getTempDir() / ("ct-plat10-pin-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64 & "-" & $rand(1 shl 30))
    let userRoot = tmp / "user" / "components" / "v1"
    let project = tmp / "project" / "nested" / "deeper"
    createDir(userRoot)
    createDir(project)
    isolateEnv()
    putEnv(componentsRootEnvVar, userRoot)
    for v in ["1.0.0", "2.0.0"]:
      writeComponent(userRoot, "demo-plugin", v,
                     manifest = manifestFor("demo-plugin", v))

  teardown:
    restoreEnv(saved)
    removeDir(tmp)

  test "the walk finds `.ctrc` in an ancestor and the pin wins":
    writeFile(tmp / "project" / ".ctrc", "demo-plugin = 1.0.0\n")
    var pins: seq[CtrcPin]
    let found = loadCtrcPins(project, pins)
    ckEq found.path, tmp / "project" / ".ctrc"
    ckEq found.problem, cpOk
    ckEq pins.len, 1
    ckEq pinFor(pins, "demo-plugin"), "1.0.0"
    let d = discoverPlugins(collectComponentLevels(), pins)
    ckEq d.names(), @["demo-plugin@1.0.0"]
    ckEq d.plugins[0].selection.rule, vsrPinned
    # The control: without the pin, the same tree answers 2.0.0. A pin that is
    # merely agreeing with the default is a pin nothing has been shown about.
    let unpinned = discoverPlugins(collectComponentLevels(), @[])
    ckEq unpinned.names(), @["demo-plugin@2.0.0"]

  test "CODETRACER_CTRC_PATH short-circuits the walk, as the launcher exports it":
    writeFile(tmp / "project" / ".ctrc", "demo-plugin = 1.0.0\n")
    writeFile(tmp / "elsewhere.ctrc", "demo-plugin = 2.0.0\n")
    putEnv(ctrcPathEnvVar, tmp / "elsewhere.ctrc")
    var pins: seq[CtrcPin]
    let found = loadCtrcPins(project, pins)
    ckEq found.path, tmp / "elsewhere.ctrc"
    ckEq pinFor(pins, "demo-plugin"), "2.0.0"
    ckEq discoverPlugins(collectComponentLevels(), pins).names(),
         @["demo-plugin@2.0.0"]

  test "a pin to a version that is NOT installed refuses, and says how to fix it":
    # §4.1's rule reaching distribution: the plugin does not silently vanish.
    var pins = @[CtrcPin(name: "demo-plugin", version: "9.9.9")]
    let d = discoverPlugins(collectComponentLevels(), pins)
    ckEq d.plugins.len, 0
    ckEq d.codes(), @[pecPinnedVersionMissing]
    ck d.problems[0].namesPlugin()
    ck d.problems[0].detail.contains("ct install demo-plugin@")
    ck d.problems[0].detail.contains("1.0.0")
    ck d.problems[0].detail.contains("2.0.0")

  test "a pin on an ordinary command component is not this substrate's business":
    writeComponent(userRoot, "codetracer-tui", "1.0.0",
                   capabilities = "bin ct-tui\nreplay .rr\n")
    var pins = @[CtrcPin(name: "codetracer-tui", version: "9.9.9")]
    let d = discoverPlugins(collectComponentLevels(), pins)
    ckEq d.problems.len, 0
    ckEq d.plugins.len, 1          # demo-plugin, unpinned
    ckEq d.plugins[0].component.name, "demo-plugin"

suite "PLAT-10: a plugin component is not a dispatchable component":

  setup:
    let saved = snapshotEnv()
    let tmp = getTempDir() / ("ct-plat10-role-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64 & "-" & $rand(1 shl 30))
    let userRoot = tmp / "user" / "components" / "v1"
    createDir(userRoot)
    isolateEnv()
    putEnv(componentsRootEnvVar, userRoot)

  teardown:
    restoreEnv(saved)
    removeDir(tmp)

  test "a component carrying BOTH files is refused as a plugin, naming both":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"),
                   capabilities = "bin demo\ndemo .py\n")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.codes(), @[pecPluginAlsoDispatchable]
    ck d.problems[0].detail.contains(PluginManifestFile)
    ck d.problems[0].detail.contains(CapabilityFile)
    ck d.problems[0].detail.contains("demo-plugin@1.0.0")

  test "the POSITIVE TWIN: the same tree without `capabilities` IS a plugin":
    # Verification-Harness-Traps §4a. The refusal above is a "must not
    # contain"; without a twin through the same walk, a discovery that had
    # stopped finding anything at all would satisfy it.
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.problems.len, 0
    ckEq d.names(), @["demo-plugin@1.0.0"]

  test "a plain command component is not a plugin AND is not a problem":
    writeComponent(userRoot, "codetracer-tui", "1.0.0",
                   capabilities = "bin ct-tui\nreplay .rr\n")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 0

  test "a directory carrying neither file is neither, silently":
    createDir(userRoot / "empty-thing@1.0.0")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 0

  test "a plugin in a MISNAMED directory is reported, not skipped":
    createDir(userRoot / "no-version-here")
    writeFile(userRoot / "no-version-here" / PluginManifestFile,
              manifestFor("no-version-here"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.codes(), @[pecBadComponentDirectory]
    ck d.problems[0].detail.contains("no-version-here")
    ck d.problems[0].detail.contains("ct uninstall")

  test "a misnamed directory with NO plugin manifest is silent":
    # The complement, so the rule above is "a plugin that claims to be here"
    # rather than "any directory whose name I dislike". A components root with
    # a `README` directory in it is not a fault.
    createDir(userRoot / "no-version-here")
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.problems.len, 0

suite "PLAT-10: levels, in the launcher's priority order":

  setup:
    let saved = snapshotEnv()
    let tmp = getTempDir() / ("ct-plat10-lvl-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64 & "-" & $rand(1 shl 30))
    let userRoot = tmp / "user" / "components" / "v1"
    let systemRoot = tmp / "system" / "components" / "v1"
    createDir(userRoot)
    createDir(systemRoot)
    isolateEnv()
    putEnv(componentsRootEnvVar, userRoot)
    putEnv(componentsPathEnvVar, systemRoot)

  teardown:
    restoreEnv(saved)
    removeDir(tmp)

  test "a user install shadows a system one of the same name, at any version":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin", "1.0.0"))
    writeComponent(systemRoot, "demo-plugin", "9.9.9",
                   manifest = manifestFor("demo-plugin", "9.9.9"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.names(), @["demo-plugin@1.0.0"]
    ckEq d.plugins[0].level, "user"
    # The shadowed one is NOT reported as a problem: two levels holding the
    # same component is the ordinary state of an upgraded machine.
    ckEq d.problems.len, 0

  test "a system-only plugin is found, and says which level it came from":
    writeComponent(systemRoot, "other-plugin", "3.0.0",
                   manifest = manifestFor("other-plugin", "3.0.0"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.names(), @["other-plugin@3.0.0"]
    ckEq d.plugins[0].level, "system"

  test "a refusal at the user level does not let the system one through":
    # The shadow is by NAME, not by success. Otherwise a broken user install
    # would silently hand the user a system plugin they did not choose, which
    # is the same class of surprise as a pin falling back to the highest.
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"),
                   capabilities = "bin demo\n")
    writeComponent(systemRoot, "demo-plugin", "9.9.9",
                   manifest = manifestFor("demo-plugin", "9.9.9"))
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ckEq d.codes(), @[pecPluginAlsoDispatchable]

  test "the report names what is installed, what refused, and the pins":
    writeComponent(userRoot, "demo-plugin", "1.0.0",
                   manifest = manifestFor("demo-plugin"))
    writeComponent(systemRoot, "bad-plugin", "1.0.0",
                   manifest = manifestFor("bad-plugin"),
                   capabilities = "bin bad\n")
    var d = discoverPlugins(collectComponentLevels(),
                            @[CtrcPin(name: "x", version: "1.0.0")])
    d.ctrcPath = "/somewhere/.ctrc"
    d.pins = @[CtrcPin(name: "x", version: "1.0.0")]
    let text = d.report()
    ck text.contains("/somewhere/.ctrc")
    ck text.contains("x=1.0.0")
    ck text.contains("demo-plugin@1.0.0")
    ck text.contains("(user)")
    ck text.contains("bad-plugin")
    ck text.contains("command dispatch")

  test "an empty machine says so, with the command that changes it":
    let d = discoverPlugins(collectComponentLevels(), @[])
    ckEq d.plugins.len, 0
    ck d.report().contains("ct install")

suite "PLAT-10: the grant ledger on disk":

  setup:
    let saved = snapshotEnv()
    let tmp = getTempDir() / ("ct-plat10-grant-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64 & "-" & $rand(1 shl 30))
    createDir(tmp)
    isolateEnv()
    putEnv(userRootEnvVar, tmp)

  teardown:
    restoreEnv(saved)
    removeDir(tmp)

  test "the ledger lives beside the launcher's own installs":
    ckEq launcherUserRoot(), tmp
    ckEq grantLedgerPath(), tmp / "grants" / "v1" / "grants.tsv"

  test "a machine where nobody has granted anything reads as empty, not broken":
    ck not fileExists(grantLedgerPath())
    let parse = loadGrantLedger()
    ckEq parse.problems.len, 0
    ckEq parse.ledger.entries.len, 0

  test "a grant written here is a grant read back there":
    var l: GrantLedger
    ckEq l.grant("demo-plugin", capProcess, "2026-08-14T09:00:00Z",
                 "at install"), groRecorded
    ckEq l.grant("demo-plugin", capTrace, "2026-08-14T09:00:00Z", ""),
         groRecorded
    ckEq saveGrantLedger(l), ""
    ck fileExists(grantLedgerPath())
    let back = loadGrantLedger()
    ckEq back.problems.len, 0
    ckEq back.ledger.entries.len, 2
    ckEq back.ledger.stateOf("demo-plugin", capProcess), gsGranted
    ckEq back.ledger.decidedAt("demo-plugin", capProcess),
         "2026-08-14T09:00:00Z"

  test "a revocation written here is a revocation read back there":
    var l: GrantLedger
    ckEq l.grant("demo-plugin", capProcess, "2026-08-14T09:00:00Z"),
         groRecorded
    ckEq saveGrantLedger(l), ""
    var reopened = loadGrantLedger().ledger
    ckEq reopened.revoke("demo-plugin", capProcess, "2026-09-11T14:30:00Z",
                         "taken back"), groRecorded
    ckEq saveGrantLedger(reopened), ""
    let final = loadGrantLedger()
    ckEq final.problems.len, 0
    ckEq final.ledger.stateOf("demo-plugin", capProcess), gsRevoked
    ck final.ledger.describe("demo-plugin").contains("taken back")

  test "the write leaves no temporary behind":
    # THE LOCK FILE IS NOT A TEMPORARY and is listed here on purpose. It is a
    # separate inode from the ledger because the ledger is REPLACED by
    # `moveFile`, and an advisory lock lives on the inode — a lock taken on the
    # ledger itself would be dropped by the very next successful save. So it
    # outlives the write by design, and a case asserting "nothing is left
    # behind" has to name it rather than be surprised by it.
    var l: GrantLedger
    ckEq l.grant("demo-plugin", capProcess, "2026-08-14T09:00:00Z"),
         groRecorded
    ckEq saveGrantLedger(l), ""
    ck not fileExists(grantLedgerPath() & ".tmp")
    ck not fileExists(grantLedgerStagingPath(grantLedgerPath()))
    var listed: seq[string] = @[]
    var staging = 0
    for kind, child in walkDir(grantLedgerPath().parentDir):
      listed.add child.lastPathPart
      if child.lastPathPart.contains(".tmp"): inc staging
    ckEq staging, 0
    ckEq listed.sorted(), @["grants.tsv", "grants.tsv.lock"]

  test "the staging path carries the writer's pid, so two writers cannot share it":
    # THE FIXED `path & ".tmp"` WAS THE TORN-FILE CASE. Two savers interleaving
    # as write/write/rename/rename made one of them rename the OTHER's
    # half-written bytes over the ledger, and `parseLedger` is total, so a
    # truncation at a line boundary loads silently as FEWER grants. A lost
    # `revoke` line restores a capability the user took back — the one direction
    # this record must never fail in.
    #
    # This asserts the property that makes that unconstructible rather than
    # unlikely, and it asserts it as an INEQUALITY between two pids rather than
    # by matching the pid's text, so a staging name that stopped varying could
    # not satisfy it (Verification-Harness-Traps §4d: syntax, not vocabulary).
    let path = grantLedgerPath()
    let mine = grantLedgerStagingPath(path)
    ck mine != path & ".tmp"
    ck mine.startsWith(path & ".tmp.")
    ck mine.endsWith("." & $getCurrentProcessId())
    # …and a staging file left behind by a DIFFERENT writer is not ours and is
    # not renamed over the ledger by our save.
    createDir(path.parentDir)
    let foreign = path & ".tmp." & $(getCurrentProcessId() + 1)
    writeFile(foreign, "grant\tsomebody-else\tprocess\ttorn-half-a-line")
    var l: GrantLedger
    ckEq l.grant("demo-plugin", capProcess, "2026-08-14T09:00:00Z"),
         groRecorded
    ckEq saveGrantLedger(l), ""
    ck fileExists(foreign)
    let back = loadGrantLedger()
    ckEq back.problems.len, 0
    ckEq back.ledger.entries.len, 1
    ckEq back.ledger.stateOf("demo-plugin", capProcess), gsGranted
    ckEq back.ledger.stateOf("somebody-else", capProcess), gsUndecided
    removeFile(foreign)

  test "concurrent writers do not lose each other's decisions":
    # THE READ-MODIFY-WRITE, MEASURED WITH REAL PROCESSES. A pid-unique staging
    # path stops the file being TORN; it does not stop a decision being LOST.
    # Two processes that each load the same starting ledger, each append their
    # own entry and each save will both succeed, and the file carries whichever
    # was written last. Nothing is corrupt; one decision is simply gone.
    #
    # `updateGrantLedgerAt` holds one exclusive lock across the load and the
    # save, so every child's entry survives. Four children × eight grants = 32
    # interleaved read-modify-writes.
    #
    # IT IS ASSERTED AS A COUNT AND NOT AS "AT LEAST ONE SURVIVED"
    # (Verification-Harness-Traps §4b): the membership is knowable, written on
    # the line above, so the control has to be the number.
    #
    # MEASURED WITHOUT THE LOCK, on this machine, by replacing the `flockEx`
    # call in `withGrantLedgerLock` with a no-op and running the same four
    # children: **8, 8 and 25 of the 32 entries survived** across three runs.
    # With the lock: **32, 32 and 32**. That difference is what keeps this case
    # from being one that passes because races happen to be rare — and the 25
    # is why `GrantsPerWriter` is 8 rather than 1, because a run that lost seven
    # of thirty-two would have lost none of four.
    let path = grantLedgerPath()
    createDir(path.parentDir)
    var kids: seq[Process] = @[]
    for i in 0 ..< ConcurrentWriters:
      kids.add startProcess(getAppFilename(),
                            args = [LedgerWriterFlag, path, "writer" & $i],
                            options = {poStdErrToStdOut})
    var childFailures = 0
    for p in kids:
      if p.waitForExit() != 0: inc childFailures
      p.close()
    ckEq childFailures, 0
    let back = loadGrantLedgerFrom(path)
    ckEq back.problems.len, 0
    ckEq back.ledger.entries.len, ConcurrentWriters * GrantsPerWriter
    var present = 0
    for i in 0 ..< ConcurrentWriters:
      for j in 0 ..< GrantsPerWriter:
        let who = "writer" & $i & "-" & $j
        let cap = if j mod 2 == 0: capProcess else: capFsRead
        if back.ledger.stateOf(who, cap) == gsGranted: inc present
    ckEq present, ConcurrentWriters * GrantsPerWriter

  test "an update sees the ledger as it is on disk, not as the caller last saw it":
    # The read half of the read-modify-write. A caller holding a stale
    # `GrantLedger` value and saving it would overwrite a decision taken since;
    # `updateGrantLedger` hands the edit the CURRENT file, which is why it takes
    # a callback rather than a value.
    var first: GrantLedger
    ckEq first.grant("demo-plugin", capProcess, "2026-08-14T09:00:00Z"),
         groRecorded
    ckEq saveGrantLedger(first), ""
    # Somebody else revokes, on disk, while `first` is still in hand.
    ckEq updateGrantLedger("", proc(l: var GrantLedger) =
      discard l.revoke("demo-plugin", capProcess, "2026-09-11T14:30:00Z",
                       "taken back")), ""
    # A second update does not resurrect it, because it reads what is there.
    ckEq updateGrantLedger("", proc(l: var GrantLedger) =
      discard l.grant("other-plugin", capTrace, "2026-09-11T15:00:00Z")), ""
    let back = loadGrantLedger()
    ckEq back.problems.len, 0
    ckEq back.ledger.stateOf("demo-plugin", capProcess), gsRevoked
    ckEq back.ledger.stateOf("other-plugin", capTrace), gsGranted

  test "an unusable line is a PROBLEM, not a silent empty ledger":
    createDir(grantLedgerPath().parentDir)
    writeFile(grantLedgerPath(),
              "grant\tdemo\tprocess\t2026-08-14\tok\nsideways\tdemo\ttrace\tx\n")
    let parse = loadGrantLedger()
    ckEq parse.problems.len, 1
    ck parse.problems[0].contains(grantLedgerPath())
    ck parse.problems[0].contains("line 2")
    ckEq parse.ledger.stateOf("demo", capProcess), gsGranted
    let errs = ledgerProblemErrors(parse)
    ckEq errs.len, 1
    ck errs[0].namesPlugin()

  test "no user root at all is a problem rather than a path in the wrong place":
    delEnv(userRootEnvVar)
    let savedHome = getEnv("HOME", "")
    delEnv("HOME")
    ckEq launcherUserRoot(), ""
    ckEq grantLedgerPath(), ""
    let parse = loadGrantLedger()
    ckEq parse.problems.len, 1
    ck parse.problems[0].contains("no user root")
    var l: GrantLedger
    ck saveGrantLedger(l).contains("no user root")
    if savedHome.len > 0: putEnv("HOME", savedHome)

# ---------------------------------------------------------------------------

suite "PLAT-10: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c. A `setup` that failed to create a
    # directory, or a case that returned early, cannot reach the end of this
    # file with the right number.
    check countedAssertions == ExpectedAssertions
