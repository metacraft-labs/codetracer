## launch/plugin_components.nim — PLAT-10 deliverable 1's filesystem half:
## which plugins are INSTALLED, at which version, and why that version.
##
## ## WHAT THIS FILE DELIBERATELY DOES NOT CONTAIN
##
## No download. No mirror. No registry. No `latest`. No version range. No
## directory creation. No removal. Extensibility-Model.md §8.3's whole point is
## that `codetracer-launcher` already has every one of those, and PLAT-10's
## verification gate is that no second one was written:
##
##   * installing is `ct install <name>[@<version>]`;
##   * upgrading is `ct update [<name>]`;
##   * removing is `ct uninstall <name>@<version>`;
##   * pinning is a `.ctrc` line, parsed by the launcher itself;
##   * the layout is `<components root>/<name>@<version>/`, created by the
##     launcher's own `install_one`.
##
## `src/ct/launch/plugin_distribution_e2e_test.nim` drives the real `ct`
## binary for all four verbs and then hands the resulting tree to THIS
## function, so the two halves are joined by a directory rather than by an
## agreement between two implementations.
##
## ## THE SEARCH ORDER IS `component_roots`', NOT A SECOND COPY OF IT
##
## `collectComponentLevels()` already mirrors the launcher's `collectLevels`
## and already carries the comment explaining why `CODETRACER_COMPONENTS_ROOT`
## REPLACES the real levels rather than prepending to them. Two callers used to
## have their own copies of that list and the drift was the defect; a third
## copy here would be the same mistake with a plugin in it.
##
## ## A NAME IS CLAIMED BY THE FIRST LEVEL THAT OFFERS IT
##
## The launcher's routing takes the first level with a match, so a user-level
## install shadows a system one. Discovery does the same, and the level LABEL
## travels with the answer — "user" / "system" / "distro" is what a user needs
## in order to know which `ct uninstall` would remove the thing they are
## looking at, since `ct uninstall` only removes user-level components.
##
## ## THE VERSION IS CHOSEN BEFORE THE FILE IS READ, WHICH IS THE LAUNCHER'S ORDER
##
## `scanLevelForCommand` filters by pin, then by `active/<name>`, then by
## highest, and only then opens `capabilities`. Doing it the other way round —
## "find the newest version that happens to be a plugin" — would make a
## component that STOPPED being a plugin at 2.0.0 go on loading its 1.0.0
## manifest for ever, silently, which is the shape §4.1 exists to refuse.

import std/[os, strutils]

import ./component_roots
import ../../common/plugin_model

export component_roots.ComponentLevel, component_roots.collectComponentLevels,
       # The env-var NAMES travel with the levels, because the only correct way
       # to point discovery somewhere else is the same override the launcher
       # honours, and a caller that spelled `"CODETRACER_COMPONENTS_ROOT"`
       # itself would be the second copy of a constant
       # (Verification-Harness-Traps §14).
       component_roots.componentsRootEnvVar,
       component_roots.componentsPathEnvVar,
       component_roots.componentDirEnvVar,
       component_roots.registryEnvVar

const
  ctrcPathEnvVar* = "CODETRACER_CTRC_PATH"
    ## The launcher EXPORTS this when its own walk finds a `.ctrc`
    ## (`launcher.nim`: `cSetenv(sCtrcPathEnv, …)`). Reading it is how a
    ## component learns which file the process that exec'd it read, rather
    ## than repeating the walk and possibly answering differently — the
    ## component's working directory is not guaranteed to be the launcher's.

  ctrcFileName* = ".ctrc"
  activeDirName* = "active"

type
  InstalledPlugin* = object
    component*: ComponentRef
      ## `<name>@<version>`, the identity `ct uninstall` takes.
    level*: string
      ## "self" | "user" | "system" | "distro" — `ComponentLevel.label`.
    dir*: string
      ## The component directory itself.
    manifestPath*: string
    manifestText*: string
    selection*: VersionSelection
      ## WHICH rule chose this version. A report that said only "1.2.0" could
      ## not tell a user whether their pin was honoured.
    pinnable*: bool
      ## Whether a `.ctrc` line could name this component at all. See
      ## `distribution.isPinnableComponentName`: a dotted id installs and
      ## uninstalls fine and cannot be pinned, and a user is owed that.

  PluginDiscovery* = object
    plugins*: seq[InstalledPlugin]
    problems*: seq[PluginError]
      ## Every refusal, in discovery order. §4.1's rule reaches this far: a
      ## plugin that is on disk and did not load must be SAID, never merely
      ## absent.
    ctrcPath*: string
      ## The `.ctrc` that was read, or "".
    pins*: seq[CtrcPin]

# ---------------------------------------------------------------------------
# `.ctrc`
# ---------------------------------------------------------------------------

proc findCtrc*(startDir: string): string =
  ## The launcher's walk: `<dir>/.ctrc`, then upwards. `CODETRACER_CTRC_PATH`
  ## short-circuits it, because the launcher already did the walk for this
  ## process and its answer is the authoritative one.
  let exported = getEnv(ctrcPathEnvVar, "")
  if exported.len > 0:
    return (if fileExists(exported): exported else: "")
  var dir = startDir
  while dir.len > 0:
    let probe = dir / ctrcFileName
    if fileExists(probe): return probe
    let parent = dir.parentDir
    if parent == dir or parent.len == 0: break
    dir = parent
  ""

proc loadCtrcPins*(startDir: string; dest: var seq[CtrcPin]): tuple[
    path: string; problem: CtrcProblem] =
  dest = @[]
  let path = findCtrc(startDir)
  if path.len == 0: return (path: "", problem: cpOk)
  var text: string
  try:
    text = readFile(path)
  except CatchableError:
    return (path: path, problem: cpOk)
  (path: path, problem: parseCtrcPins(text, dest))

# ---------------------------------------------------------------------------
# One level
# ---------------------------------------------------------------------------

proc activeVersionAt*(levelPath, name: string): string =
  ## The version `<level>/active/<name>` points at, or "". The launcher reads
  ## the symlink TARGET and takes the text after its last `@`
  ## (`versionEligible`), which is what this does — it never follows the link
  ## to a directory, so a dangling `active` symlink still names a version and
  ## still suppresses the highest-version rule, exactly as it does there.
  let link = levelPath / activeDirName / name
  if not symlinkExists(link): return ""
  var target: string
  try:
    target = expandSymlink(link)
  except CatchableError:
    return ""
  target = target.strip(leading = false, chars = {'/'})
  let base = target.extractFilename
  let at = base.rfind(ComponentSeparator)
  if at < 0 or at == base.high: return ""
  base[at + 1 .. ^1]

proc scanLevel(levelPath: string): tuple[
    byName: seq[tuple[name: string; versions: seq[string]]];
    badDirs: seq[string]] =
  ## Group a level's component directories by name. `active` is skipped
  ## because the launcher skips it by name too, and a dot-directory is skipped
  ## because `install_one` uses `.tmp` for its staging area.
  var order: seq[string] = @[]
  var versions: seq[seq[string]] = @[]
  for kind, child in walkDir(levelPath):
    if kind != pcDir and kind != pcLinkToDir: continue
    let base = child.lastPathPart
    if base == activeDirName: continue
    if base.len > 0 and base[0] == '.': continue
    var cref: ComponentRef
    let problem = parseComponentRef(base, cref)
    if problem != crpOk:
      # Only a directory that CLAIMS to be a plugin is worth a word. A
      # components root full of ordinary files is not a fault.
      if fileExists(child / PluginManifestFile):
        result.badDirs.add base
      continue
    var idx = -1
    for i, n in order:
      if n == cref.name: idx = i
    if idx < 0:
      order.add cref.name
      versions.add @[cref.version]
    else:
      versions[idx].add cref.version
  for i, n in order:
    result.byName.add (name: n, versions: versions[i])

# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

proc discoverPlugins*(levels: openArray[ComponentLevel];
                      pins: openArray[CtrcPin]): PluginDiscovery =
  ## Every installed plugin, one per component name, first level wins.
  var claimed: seq[string] = @[]
  for level in levels:
    if not dirExists(level.path): continue
    let scan = scanLevel(level.path)
    for bad in scan.badDirs:
      var throwaway: ComponentRef
      let why = parseComponentRef(bad, throwaway)
      result.problems.add pluginError(bad, pecBadComponentDirectory,
        describe(why, bad) &
        ". `ct install` creates '<name>" & $ComponentSeparator &
        "<version>' and nothing else reads any other shape, so a plugin here " &
        "is invisible to 'ct uninstall' as well as to CodeTracer")
    for entry in scan.byName:
      if entry.name in claimed: continue
      let pin = pinFor(pins, entry.name)
      let sel = selectVersion(entry.versions, pin,
                              activeVersionAt(level.path, entry.name))
      if sel.rule == vsrPinnedMissing:
        # Say so ONLY when some installed version of this name is a plugin.
        # A pin on an ordinary command component is the launcher's business
        # and printing it here would attribute a component's problem to the
        # plugin substrate.
        var anyPlugin = false
        for v in entry.versions:
          if fileExists(level.path / (entry.name & ComponentSeparator & v) /
                        PluginManifestFile):
            anyPlugin = true
        if anyPlugin:
          claimed.add entry.name
          result.problems.add pluginError(entry.name, pecPinnedVersionMissing,
            describe(sel, entry.name) & " (installed here: " &
            entry.versions.join(", ") & ")")
        continue
      if sel.rule == vsrNone: continue
      let dir = level.path / (entry.name & ComponentSeparator & sel.version)
      let manifestPath = dir / PluginManifestFile
      let role = componentRole(fileExists(manifestPath),
                               fileExists(dir / CapabilityFile))
      case role
      of crUnclassified, crCommandComponent:
        # Not a plugin. Not a problem either: this is what every ordinary
        # installed component looks like from here.
        discard
      of crAmbiguous:
        claimed.add entry.name
        result.problems.add roleError(entry.name,
          entry.name & ComponentSeparator & sel.version)
      of crPlugin:
        claimed.add entry.name
        var text: string
        try:
          text = readFile(manifestPath)
        except CatchableError as e:
          result.problems.add pluginError(entry.name, pecMalformedManifest,
            "could not read '" & manifestPath & "': " & e.msg)
          continue
        result.plugins.add InstalledPlugin(
          component: ComponentRef(name: entry.name, version: sel.version),
          level: level.label, dir: dir, manifestPath: manifestPath,
          manifestText: text, selection: sel,
          pinnable: isPinnableComponentName(entry.name))

proc discoverInstalledPlugins*(startDir = getCurrentDir()): PluginDiscovery =
  ## The whole of discovery, from the environment: the launcher's levels and
  ## the launcher's `.ctrc`.
  var pins: seq[CtrcPin] = @[]
  let ctrc = loadCtrcPins(startDir, pins)
  result = discoverPlugins(collectComponentLevels(), pins)
  result.ctrcPath = ctrc.path
  result.pins = pins
  if ctrc.problem == cpTooManyPins:
    result.problems.add pluginError("<.ctrc>", pecPinnedVersionMissing,
      "'" & ctrc.path & "' carries more than " & $MaxCtrcPins & " version " &
      "pins, which is the launcher's own limit — 'ct' exits 1 on this file, " &
      "so no component it pins would run either")

# ---------------------------------------------------------------------------
# Reading the result back
# ---------------------------------------------------------------------------

proc identityProblem*(p: InstalledPlugin; m: PluginManifest): PluginError =
  ## §4.1's identity against §8.3's distribution identity.
  ##
  ## The plugin `id` and the COMPONENT NAME must be the same string, and the
  ## reason is entirely practical: `ct install`, `ct uninstall` and a `.ctrc`
  ## pin all spell the component name, while every error, every grant record
  ## and every dependency spells the id. Two different strings would leave a
  ## user reading about `acme.metrics` with no way to find out that the thing
  ## to remove is called `metrics`.
  pluginError(m.id, pecPluginIdComponentMismatch,
    "'" & p.manifestPath & "' declares id '" & m.id & "', but it is installed " &
    "as component '" & p.component.name & "'. Every command that manages it " &
    "— " & installHintFor(p.component.name) & ", " &
    uninstallHintFor(p.component) & ", and a .ctrc pin — spells the component " &
    "name, so the two have to be one string")

proc describe*(p: InstalledPlugin): string =
  "  " & $p.component & "  (" & p.level & ")  " & p.dir & "\n    " &
    describe(p.selection, p.component.name) & "\n    " &
    pinnabilityNote(p.component.name)

proc report*(d: PluginDiscovery): string =
  ## What is installed and what refused to load, in one string, for the same
  ## reason `PluginHost.report` is one string: the user's question is "why is
  ## my plugin not there", and half an answer is worse than none.
  var lines: seq[string] = @[]
  if d.ctrcPath.len > 0:
    lines.add "version pins from " & d.ctrcPath & ": " &
      (if d.pins.len == 0: "(none)"
       else: (block:
         var ps: seq[string] = @[]
         for p in d.pins: ps.add p.name & "=" & p.version
         ps.join(", ")))
  if d.plugins.len == 0:
    lines.add "no plugin components are installed (" & installHintFor("<name>") &
      ")"
  else:
    lines.add $d.plugins.len & " plugin component(s) installed:"
    for p in d.plugins: lines.add describe(p)
  for e in d.problems: lines.add render(e)
  lines.join("\n")
