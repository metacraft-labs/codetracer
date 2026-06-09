## M7: Help Assembly Implementation (CodeTracer Launcher campaign)
##
## codetracer-desktop is the **help delegate** for the ``ct`` launcher.
## The launcher, which is stack-only and very small (see
## ``codetracer-launcher/src/launcher.nim``), delegates help assembly
## and completion to whichever installed component declares
## ``help-delegate`` in its capabilities file -- in our distribution,
## that component is codetracer-desktop, the binary built from this
## repository.
##
## This module implements the three subcommands exposed by the help
## delegate, as specified in
## ``codetracer-specs/Planned-Features/CodeTracer-Launcher.md`` §2.6:
##
## * ``ct-describe-commands`` -- emit a line-oriented description of
##   every command this binary handles, with file-types,
##   project-markers and dynamic notes.
## * ``ct-help`` -- run ``ct-describe-commands`` on every installed
##   component, read the registry and per-component ``latest`` files,
##   merge the resulting :type:`RuntimeCommandSurface` values and
##   render a unified help screen with Installed / Not installed /
##   Commands-available-with-upgrade sections.
## * ``ct-complete`` -- return context-aware completion candidates for
##   a partial command line. Top-level completion returns command
##   names; subcommand completion filters file-system paths by the
##   subcommand's supported file extensions.
##
## All three subcommands are built on the M6 runtime-surface API
## (``confutils/runtime_surface``) -- we do not reimplement the
## render/merge/completion algorithms here. Surfaces are constructed
## from:
##
## * the compile-time-typed :type:`CodetracerConf` (via
##   ``surfaceFromType``) -- ground truth for codetracer-desktop's
##   own commands;
## * the line-oriented output of other components' ``ct-describe-commands``
##   (parsed by :proc:`parseDescribeCommandsOutput`);
## * the registry file at ``~/.codetracer/registry/v1/registry.txt``
##   (parsed by :proc:`readRegistry`); and
## * per-component ``latest`` files (parsed by :proc:`readLatestVersion`).
##
## Component-directory discovery mirrors the launcher's algorithm in
## ``codetracer-launcher/src/launcher.nim`` (``collectLevels``):
## ``CODETRACER_COMPONENTS_ROOT`` if set, otherwise
## ``$HOME/.codetracer/components/v1`` plus
## ``CODETRACER_COMPONENTS_PATH`` and the system + distro defaults.
## The override variables (``CODETRACER_COMPONENTS_ROOT``,
## ``CODETRACER_REGISTRY_PATH``) keep the test fixtures isolated from
## the user's real install -- this matches the launcher convention.

import
  std/[ os, osproc, streams, strutils, tables, algorithm ],
  ../codetracerconf,
  ../version,
  confutils,
  confutils/[ defs, runtime_surface ]

export defs, runtime_surface

const
  helpDelegateComponentName* = "codetracer-desktop"
    ## The component name codetracer-desktop publishes in its
    ## capabilities file. Used as the "self" entry when assembling
    ## the Installed section and matched by the launcher's
    ## help-delegate scan.

  registryEnvVar* = "CODETRACER_REGISTRY_PATH"
    ## Test-only override: forces a specific registry root. Matches the
    ## launcher's ``CODETRACER_REGISTRY_PATH`` convention.

  componentsRootEnvVar* = "CODETRACER_COMPONENTS_ROOT"
    ## Test-only override: forces a specific components root. Matches
    ## the launcher's ``CODETRACER_COMPONENTS_ROOT`` convention.

  componentsPathEnvVar* = "CODETRACER_COMPONENTS_PATH"
    ## Colon-separated extra component directories. Honoured for
    ## parity with the launcher.

# ---------------------------------------------------------------------------
# Self-surface construction (the compile-time typed CodetracerConf -> runtime
# surface bridge from M6 does the heavy lifting).
# ---------------------------------------------------------------------------

func augmentSelfCommand(cmd: var RuntimeCommand) =
  ## Add file-type and description metadata to commands of the
  ## self-surface that are not captured by the {.command.} discriminator
  ## (confutils' bridge does not currently carry per-command file types
  ## or human descriptions for case-object branches). The metadata
  ## values below mirror the spec §2.6 examples for
  ## codetracer-desktop.
  case cmd.name
  of "record":
    if cmd.description.len == 0:
      cmd.description = "Record a program execution"
    if cmd.fileTypes.len == 0:
      cmd.fileTypes = @[".py", ".rb", ".nr", ".styl", ".wasm"]
  of "record-test":
    if cmd.description.len == 0:
      cmd.description = "Record a test execution"
    if cmd.fileTypes.len == 0:
      cmd.fileTypes = @[".py", ".rb", ".nr"]
  of "run":
    if cmd.description.len == 0:
      cmd.description = "Record and immediately replay"
    if cmd.fileTypes.len == 0:
      cmd.fileTypes = @[".py", ".rb", ".nr", ".styl", ".wasm"]
  of "replay":
    if cmd.description.len == 0:
      cmd.description = "Replay a recorded trace"
  of "list":
    if cmd.description.len == 0:
      cmd.description = "List recorded traces"
  of "print":
    if cmd.description.len == 0:
      cmd.description = "Print trace events in human-readable format"
  of "install":
    if cmd.description.len == 0:
      cmd.description = "Install CodeTracer integration into the host environment"
  of "host":
    if cmd.description.len == 0:
      cmd.description = "Host a trace for remote replay"
  of "upload":
    if cmd.description.len == 0:
      cmd.description = "Upload a recorded trace"
  of "download":
    if cmd.description.len == 0:
      cmd.description = "Download a shared trace"
  of "login":
    if cmd.description.len == 0:
      cmd.description = "Sign in to CodeTracer cloud"
  of "edit":
    if cmd.description.len == 0:
      cmd.description = "Open a file or folder in CodeTracer"
  of "import":
    if cmd.description.len == 0:
      cmd.description = "Import a previously exported trace archive"
  of "ci":
    if cmd.description.len == 0:
      cmd.description = "Manage CodeTracer CI runs"
  of "help":
    if cmd.description.len == 0:
      cmd.description = "Show help"
  of "remote":
    if cmd.description.len == 0:
      cmd.description = "Manage remote trace sharing"
  of "activate":
    if cmd.description.len == 0:
      cmd.description = "Activate a CodeTracer license"
  of "check-license":
    if cmd.description.len == 0:
      cmd.description = "Check the current license status"
  # P7.1 user-facing wrappers around recorder-internal tools.
  # The launcher's help screen needs human descriptions for these
  # so they don't show up as bare command names in the desktop
  # ``ct --help`` rendering.
  of "trace":
    if cmd.description.len == 0:
      cmd.description = "Post-process a recorded trace (extract-gfx, export)"
  of "gfx-replay":
    if cmd.description.len == 0:
      cmd.description = "Replay an extracted graphics stream"
  of "doctor":
    if cmd.description.len == 0:
      cmd.description = "Check recorder readiness (per-language probes)"
  else:
    discard

proc selfSurface*(): RuntimeCommandSurface =
  ## Build the :type:`RuntimeCommandSurface` describing the commands
  ## that codetracer-desktop itself handles. We start from M6's
  ## compile-time bridge (``surfaceFromType``), then annotate the
  ## per-command file-types and descriptions that the confutils
  ## case-object discriminator does not carry.
  result = surfaceFromType(CodetracerConf, helpDelegateComponentName)
  result.version = version.CodeTracerVersionStr
  result.description = "CodeTracer - the user-friendly time-travelling debugger"
  for i in 0 ..< result.commands.len:
    augmentSelfCommand(result.commands[i])

# ---------------------------------------------------------------------------
# ct-describe-commands output: serialiser + parser.
# ---------------------------------------------------------------------------

const describeIgnoredCommands* = [
    "noCommand",
    "",
    # Help-delegate plumbing subcommands. They are an internal
    # protocol between the launcher and codetracer-desktop -- the
    # user should never see them in help/completion output.
    "ct-describe-commands",
    "ct-help",
    "ct-complete",
    "ct-completions",
    # Implementation-detail subcommands: useful for the desktop app
    # internals or tests, not user-facing.
    "electron",
    "trace-metadata",
    "start_backend",
  ]
  ## ``noCommand`` is confutils' sentinel for "no subcommand provided".
  ## It must never appear in the public describe output. The
  ## ``ct-*`` subcommands are reserved for the launcher-delegate
  ## protocol and are deliberately hidden from the user-facing
  ## help / completion lists.

func formatDescribeBlock*(cmd: RuntimeCommand): string =
  ## Render one command block in the line-oriented format from spec
  ## §2.6. Blocks end with a blank line.
  if cmd.name.len == 0: return ""
  if cmd.name in describeIgnoredCommands: return ""
  result.add "command " & cmd.name & "\n"
  if cmd.description.len > 0:
    result.add "description " & cmd.description & "\n"
  if cmd.fileTypes.len > 0:
    result.add "file-types " & cmd.fileTypes.join(" ") & "\n"
  if cmd.projectMarkers.len > 0:
    result.add "project-markers " & cmd.projectMarkers.join(" ") & "\n"
  if cmd.note.len > 0:
    result.add "note " & cmd.note & "\n"
  result.add "\n"

proc renderDescribeCommands*(surface: RuntimeCommandSurface): string =
  ## Render the full ``ct-describe-commands`` output for a surface.
  for cmd in surface.commands:
    result.add formatDescribeBlock(cmd)

proc parseDescribeCommandsOutput*(
    output: string,
    programName = "<component>"): RuntimeCommandSurface =
  ## Parse the line-oriented output produced by another component's
  ## ``ct-describe-commands``. The grammar is documented in
  ## launcher spec §2.6 -- we are deliberately tolerant: blank lines
  ## separate blocks, ``key value`` syntax, unknown keys are ignored
  ## for forward compatibility.
  result.programName = programName
  var current = newRuntimeCommand("")
  template flushBlock =
    if current.name.len > 0 and current.name notin describeIgnoredCommands:
      result.commands.add current
    current = newRuntimeCommand("")
  for rawLine in output.splitLines:
    let line = rawLine.strip(trailing = true)
    if line.len == 0 or line.startsWith("#"):
      if line.len == 0:
        flushBlock()
      continue
    let spaceIdx = line.find(' ')
    let key = if spaceIdx < 0: line else: line[0 ..< spaceIdx]
    let rest = if spaceIdx < 0: "" else: line[spaceIdx + 1 .. ^1].strip()
    case key
    of "command":
      flushBlock()
      current = newRuntimeCommand(rest)
    of "description":
      current.description = rest
    of "file-types":
      current.fileTypes = @[]
      for tok in rest.splitWhitespace:
        if tok.len > 0:
          current.fileTypes.add tok
    of "project-markers":
      current.projectMarkers = @[]
      for tok in rest.splitWhitespace:
        if tok.len > 0:
          current.projectMarkers.add tok
    of "note":
      current.note = rest
    else:
      discard
  flushBlock()

# ---------------------------------------------------------------------------
# Capability-file parsing (component dirs)
# ---------------------------------------------------------------------------

type
  InstalledComponent* = object
    name*: string         ## component name (from ``name`` line)
    version*: string      ## installed version (from ``version`` line or dir)
    binPath*: string      ## absolute path to the component binary
    capPath*: string      ## absolute path to the capabilities file
    levelIdx*: int        ## 0 = user, 1 = $COMPONENTS_PATH, 2 = system, 3 = distro
    levelLabel*: string   ## human label for the provenance column
    isHelpDelegate*: bool ## true if the capabilities file declares help-delegate
    description*: string  ## description from the capabilities file (when present)
    declaredCommands*: seq[string]
      ## command names declared in the capabilities file, in the order
      ## they appear. Populated by :proc:`parseCapabilitiesFile` from
      ## lines of the form ``<command> [.ext1 .ext2 ...]`` (i.e. lines
      ## whose first token is not a reserved capability-file keyword).
      ## Used by M8's fast-path top-level completion to enumerate
      ## known commands *without* spawning component binaries.
    surface*: RuntimeCommandSurface
      ## populated by :proc:`collectComponentSurfaces` after running
      ## ``<binPath> ct-describe-commands`` -- left empty by the
      ## capability-file parser.

  ComponentLevel = object
    path: string
    label: string

func splitComponentDirName(dirName: string):
    tuple[name, version: string] =
  ## ``<component>@<version>`` directory layout, per launcher spec.
  let atIdx = dirName.rfind('@')
  if atIdx < 0:
    return (dirName, "")
  (dirName[0 ..< atIdx], dirName[atIdx + 1 .. ^1])

const reservedCapabilityKeywords* = [
    "name", "version", "bin", "description", "help-delegate",
    "licensed", "project"
  ]
  ## Capability-file line keywords that are *not* command
  ## declarations. Every other first-token is treated as a command
  ## name (spec §2.3: ``<command> [.ext ...]`` lines).
  ## Forward-compatible: future capability keywords should be added
  ## here so they do not pollute the command-completion fast path.

proc parseCapabilitiesFile(content: string,
                            comp: var InstalledComponent) =
  ## Extract the structured fields we care about from a capabilities
  ## file. Format mirrors the launcher's strict byte parser
  ## (``codetracer-launcher/src/caps.nim``) but with full string
  ## tolerance: blank lines, ``#`` comments, ``key value`` shape.
  ##
  ## Beyond the structured fields, we also collect command-name
  ## declarations into ``declaredCommands``. This powers M8's fast-path
  ## top-level completion (spec §2.7) which must enumerate known
  ## commands without spawning any component binary.
  for rawLine in content.splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let spaceIdx = line.find(' ')
    let key = if spaceIdx < 0: line else: line[0 ..< spaceIdx]
    let rest = if spaceIdx < 0: "" else: line[spaceIdx + 1 .. ^1].strip()
    case key
    of "name":
      if comp.name.len == 0:
        comp.name = rest
    of "version":
      if comp.version.len == 0:
        comp.version = rest
    of "bin":
      if rest.len > 0 and comp.binPath.len == 0:
        # bin <name> refers to a binary inside the component's
        # bin/ subdirectory.
        let compDir = comp.capPath.parentDir
        let candidate = compDir / "bin" / rest
        if fileExists(candidate):
          comp.binPath = candidate
        else:
          # Fall back to the bare name -- caller may still resolve it
          # via PATH when running.
          comp.binPath = rest
    of "help-delegate":
      comp.isHelpDelegate = true
    of "description":
      if comp.description.len == 0:
        comp.description = rest
    else:
      # Anything that is not a reserved keyword is a command
      # declaration (spec §2.3: ``<cmd> [.ext ...]`` lines).
      if key.len > 0 and key notin reservedCapabilityKeywords and
         key notin describeIgnoredCommands and
         key notin comp.declaredCommands:
        comp.declaredCommands.add key

proc collectComponentLevels(): seq[ComponentLevel] =
  ## Build the list of search roots in launcher priority order.
  ## ``CODETRACER_COMPONENTS_ROOT`` suppresses the real user/system/distro
  ## paths (so tests stay isolated); ``CODETRACER_COMPONENTS_PATH`` is
  ## always honoured.
  let rootOverride = getEnv(componentsRootEnvVar, "")
  if rootOverride.len > 0:
    result.add ComponentLevel(path: rootOverride, label: "user")
  else:
    let home = getEnv("HOME", "")
    if home.len > 0:
      result.add ComponentLevel(
        path: home / ".codetracer" / "components" / "v1",
        label: "user")
  let extraPaths = getEnv(componentsPathEnvVar, "")
  if extraPaths.len > 0:
    for seg in extraPaths.split(':'):
      if seg.len > 0:
        result.add ComponentLevel(path: seg, label: "system")
  if rootOverride.len == 0:
    when defined(macosx):
      result.add ComponentLevel(
        path: "/usr/local/lib/codetracer/components/v1",
        label: "system")
      result.add ComponentLevel(
        path: "/Library/Application Support/CodeTracer/components/v1",
        label: "distro")
    else:
      result.add ComponentLevel(
        path: "/usr/local/lib/codetracer/components/v1",
        label: "system")
      result.add ComponentLevel(
        path: "/usr/lib/codetracer/components/v1",
        label: "distro")

proc scanInstalledComponents*(): seq[InstalledComponent] =
  ## Enumerate every ``<component>@<version>/capabilities`` file under
  ## the configured component roots. Higher-priority directories come
  ## first; for any single component, the first directory wins.
  let levels = collectComponentLevels()
  var seen = initTable[string, bool]()
  for idx, lvl in levels:
    if not dirExists(lvl.path): continue
    for kind, child in walkDir(lvl.path):
      if kind != pcDir: continue
      let capPath = child / "capabilities"
      if not fileExists(capPath): continue
      var comp = InstalledComponent(
        capPath: capPath,
        levelIdx: idx,
        levelLabel: lvl.label)
      let (defaultName, defaultVersion) =
        splitComponentDirName(child.lastPathPart)
      comp.name = defaultName
      comp.version = defaultVersion
      try:
        parseCapabilitiesFile(readFile(capPath), comp)
      except CatchableError:
        # Best-effort: corrupt files are skipped rather than crashing
        # the whole help screen. This matches the launcher's "fail
        # safe and keep going" stance.
        continue
      if comp.name.len == 0: continue
      if seen.getOrDefault(comp.name, false): continue
      seen[comp.name] = true
      result.add comp

# ---------------------------------------------------------------------------
# Component binary execution: run `<binary> ct-describe-commands`.
# ---------------------------------------------------------------------------

proc runDescribeCommands*(component: InstalledComponent): RuntimeCommandSurface =
  ## Spawn ``<component.binPath> ct-describe-commands`` and parse its
  ## stdout into a :type:`RuntimeCommandSurface`. On any failure --
  ## missing binary, non-zero exit code, parse error -- we return an
  ## empty surface so the help delegate degrades gracefully (the
  ## component still appears in the Installed section with whatever
  ## metadata its capabilities file carried).
  result = newRuntimeCommandSurface(component.name, version = component.version)
  if component.binPath.len == 0: return
  var args: seq[string] = @["ct-describe-commands"]
  try:
    let p = startProcess(component.binPath, args = args,
                         options = {poStdErrToStdOut, poUsePath})
    let outp = p.outputStream.readAll()
    let code = waitForExit(p)
    close p
    if code != 0:
      return
    let parsed = parseDescribeCommandsOutput(outp, component.name)
    result.commands = parsed.commands
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Registry parsing: read ~/.codetracer/registry/v1/registry.txt and the
# cached per-component "latest" files.
# ---------------------------------------------------------------------------

type
  RegistryEntry* = object
    name*: string
    description*: string
    installHint*: string
    tier*: string
    latest*: string
    commands*: seq[string]
    fileTypes*: seq[string]

proc registryRoot*(): string =
  ## Resolve the registry root following launcher conventions.
  let override = getEnv(registryEnvVar, "")
  if override.len > 0:
    return override
  let home = getEnv("HOME", "")
  if home.len == 0: return ""
  home / ".codetracer" / "registry" / "v1"

proc readRegistry*(path = ""): seq[RegistryEntry] =
  ## Parse the registry file. The grammar is the one emitted by the
  ## test mirror fixture generator (see
  ## ``codetracer-test-mirror/server/fixture_gen.py::write_registry``)
  ## and consumed by the launcher (``launcher.nim::tryRegistrySuggest``).
  ## We accept both 2-space and tab-indented "subkeys" inside a
  ## component block.
  let p = if path.len > 0: path
          else: registryRoot() / "registry.txt"
  if p.len == 0 or not fileExists(p): return
  var content: string
  try:
    content = readFile(p)
  except CatchableError:
    return
  var current = RegistryEntry()
  template flushEntry =
    if current.name.len > 0:
      result.add current
    current = RegistryEntry()
  for rawLine in content.splitLines:
    let stripped = rawLine.strip(leading = false, trailing = true)
    if stripped.len == 0: continue
    if stripped.strip().startsWith("#"): continue
    let indent =
      block:
        var n = 0
        while n < stripped.len and (stripped[n] == ' ' or stripped[n] == '\t'):
          inc n
        n
    let line = stripped.strip()
    let spaceIdx = line.find(' ')
    let key = if spaceIdx < 0: line else: line[0 ..< spaceIdx]
    let rest = if spaceIdx < 0: "" else: line[spaceIdx + 1 .. ^1].strip()
    if indent == 0:
      case key
      of "component":
        flushEntry()
        current.name = rest
      of "description":
        current.description = rest
      of "install-hint":
        current.installHint = rest
      of "tier":
        current.tier = rest
      of "latest":
        current.latest = rest
      else:
        discard
    else:
      case key
      of "commands":
        for tok in rest.splitWhitespace:
          if tok.len > 0:
            current.commands.add tok
      of "file-types":
        for tok in rest.splitWhitespace:
          if tok.len > 0:
            current.fileTypes.add tok
      else:
        discard
  flushEntry()

proc readLatestVersion*(component: string): string =
  ## Return the version string cached in
  ## ``<registry-root>/latest/<component>`` (or "" when absent).
  let root = registryRoot()
  if root.len == 0: return ""
  let path = root / "latest" / component
  if not fileExists(path): return ""
  try:
    result = readFile(path).strip()
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Aggregation: collect surfaces from every installed component + the
# registry, then merge them into a single view.
# ---------------------------------------------------------------------------

type
  HelpAssembly* = object
    ## The fully aggregated view used to render ``ct-help``.
    installed*: seq[InstalledComponent]
    registry*: seq[RegistryEntry]
    merged*: RuntimeCommandSurface
    latestByComponent*: Table[string, string]
    upgradeCommands*: seq[tuple[component, version: string, cmd: RuntimeCommand]]

proc gatherInstalledSurfaces(asm0: var HelpAssembly) =
  ## Run ``ct-describe-commands`` on each installed component and
  ## attach the resulting surface to the component entry.
  for i in 0 ..< asm0.installed.len:
    var comp = asm0.installed[i]
    if comp.name == helpDelegateComponentName:
      # We are the help delegate -- use our compile-time surface.
      comp.surface = selfSurface()
    else:
      comp.surface = runDescribeCommands(comp)
    asm0.installed[i] = comp

proc mergeInstalledIntoUnified(asm0: var HelpAssembly) =
  ## Merge every installed component's surface into ``asm0.merged``.
  ## The first component (highest priority) seeds program metadata.
  if asm0.installed.len == 0:
    asm0.merged = newRuntimeCommandSurface("ct")
    return
  asm0.merged = newRuntimeCommandSurface("ct")
  asm0.merged.description = "CodeTracer - the user-friendly time-travelling debugger"
  for comp in asm0.installed:
    asm0.merged = merge(asm0.merged, comp.surface)

proc detectUpgradeCommands(asm0: var HelpAssembly) =
  ## Identify commands listed in the registry's latest version for a
  ## given component but not present in the installed component's
  ## describe output. These are surfaced under
  ## "Commands (available with upgrade)" in the help screen.
  var installedByName = initTable[string, InstalledComponent]()
  for comp in asm0.installed:
    installedByName[comp.name] = comp
  for entry in asm0.registry:
    let installed = installedByName.getOrDefault(entry.name)
    if installed.name.len == 0: continue
    if entry.latest.len == 0: continue
    if installed.version == entry.latest: continue
    for cmdName in entry.commands:
      var found = false
      for c in installed.surface.commands:
        if c.name == cmdName:
          found = true
          break
      if not found:
        var rc = newRuntimeCommand(cmdName)
        for c2 in asm0.merged.commands:
          if c2.name == cmdName:
            rc.description = c2.description
            break
        asm0.upgradeCommands.add (entry.name, entry.latest, rc)

proc collectLatestCache(asm0: var HelpAssembly) =
  ## Populate ``latestByComponent`` from the registry's ``latest/``
  ## cache. Components without a cached entry simply do not appear in
  ## the table; the renderer treats absence as "no newer version known".
  for comp in asm0.installed:
    let v = readLatestVersion(comp.name)
    if v.len > 0:
      asm0.latestByComponent[comp.name] = v
  for entry in asm0.registry:
    if entry.name notin asm0.latestByComponent:
      let v = readLatestVersion(entry.name)
      if v.len > 0:
        asm0.latestByComponent[entry.name] = v
      elif entry.latest.len > 0:
        asm0.latestByComponent[entry.name] = entry.latest

proc ensureSelfPresent(asm0: var HelpAssembly) =
  ## If no installed-components scan found a codetracer-desktop
  ## entry, synthesise one from the running binary. Without this
  ## fallback, ``ct ct-help`` and ``ct ct-complete`` would emit empty
  ## output on a fresh checkout where the launcher has never been
  ## ``ct install``-ed -- which is exactly the configuration tests
  ## use, and also the most useful behaviour for a developer hacking
  ## on codetracer-desktop locally.
  for comp in asm0.installed:
    if comp.name == helpDelegateComponentName:
      return
  var self = InstalledComponent(
    name: helpDelegateComponentName,
    version: version.CodeTracerVersionStr,
    binPath: getAppFilename(),
    levelLabel: "self",
    isHelpDelegate: true,
    description: "CodeTracer desktop application -- launcher help delegate",
    surface: selfSurface())
  asm0.installed.add self

proc assembleHelp*(): HelpAssembly =
  ## End-to-end aggregation: scan installed components, run
  ## describe-commands on each, read the registry, read cached latest
  ## files, and merge everything into a unified
  ## :type:`RuntimeCommandSurface`. This is exposed publicly so tests
  ## (and future tooling) can inspect the assembled view without
  ## having to scrape ``ct-help`` output.
  result.installed = scanInstalledComponents()
  gatherInstalledSurfaces(result)
  ensureSelfPresent(result)
  result.registry = readRegistry()
  collectLatestCache(result)
  mergeInstalledIntoUnified(result)
  detectUpgradeCommands(result)

# ---------------------------------------------------------------------------
# Help-screen rendering.
# ---------------------------------------------------------------------------

func padRight(s: string, width: int): string =
  if s.len >= width: return s
  s & spaces(width - s.len)

proc renderCommandsSection(asm0: HelpAssembly): string =
  if asm0.merged.commands.len == 0: return ""
  result.add "Commands:\n"
  var width = 12
  for cmd in asm0.merged.commands:
    if cmd.name.len > width: width = cmd.name.len
  let nameCol = width + 2
  for cmd in asm0.merged.commands:
    if cmd.name in describeIgnoredCommands: continue
    var line = "  " & padRight(cmd.name, nameCol)
    if cmd.description.len > 0:
      line.add cmd.description
    if cmd.note.len > 0:
      line.add "  [" & cmd.note & "]"
    result.add line & "\n"
  result.add "\n"

proc renderInstalledSection(asm0: HelpAssembly): string =
  if asm0.installed.len == 0: return ""
  result.add "Installed:\n"
  var nameWidth = 20
  for comp in asm0.installed:
    if comp.name.len > nameWidth: nameWidth = comp.name.len
  var versionWidth = 8
  for comp in asm0.installed:
    if comp.version.len > versionWidth: versionWidth = comp.version.len
  for comp in asm0.installed:
    var line = "  " & padRight(comp.name, nameWidth + 2)
    line.add padRight(comp.version, versionWidth + 2)
    line.add "(" & comp.levelLabel & ")"
    let latest = asm0.latestByComponent.getOrDefault(comp.name, "")
    if latest.len > 0 and latest != comp.version:
      line.add "  [" & latest & " available]"
    result.add line & "\n"
  result.add "\n"

proc renderNotInstalledSection(asm0: HelpAssembly): string =
  var installedNames = initTable[string, bool]()
  for comp in asm0.installed:
    installedNames[comp.name] = true
  var rows: seq[tuple[name, hint, tier: string]]
  for entry in asm0.registry:
    if installedNames.getOrDefault(entry.name, false): continue
    rows.add (entry.name, entry.installHint, entry.tier)
  if rows.len == 0: return ""
  rows.sort do (a, b: tuple[name, hint, tier: string]) -> int:
    cmp(a.name, b.name)
  result.add "Not installed:\n"
  var nameWidth = 24
  for row in rows:
    if row.name.len > nameWidth: nameWidth = row.name.len
  for row in rows:
    var line = "  " & padRight(row.name, nameWidth + 2)
    if row.hint.len > 0:
      line.add row.hint
    if row.tier.len > 0 and row.tier != "free":
      line.add "  [" & row.tier & "]"
    result.add line & "\n"
  result.add "\n"

proc renderUpgradeSection(asm0: HelpAssembly): string =
  if asm0.upgradeCommands.len == 0: return ""
  result.add "Commands (available with upgrade):\n"
  for entry in asm0.upgradeCommands:
    var line = "  " & entry.cmd.name
    if entry.cmd.description.len > 0:
      line.add "  " & entry.cmd.description
    result.add line & "\n"
    result.add "    Available in " & entry.component &
               " " & entry.version & "\n"
    result.add "    Run: ct update " & entry.component & "\n"
  result.add "\n"

proc renderHelpScreen*(asm0: HelpAssembly): string =
  ## Render the full ``ct-help`` output. The structure follows the
  ## example in spec §2.6: header, Usage, Commands, Installed, Not
  ## installed, Commands (available with upgrade), tail tip.
  result.add "CodeTracer - the user-friendly time-travelling debugger\n\n"
  result.add "Usage: ct <command> [options] [args]\n\n"
  result.add renderCommandsSection(asm0)
  result.add renderInstalledSection(asm0)
  result.add renderNotInstalledSection(asm0)
  result.add renderUpgradeSection(asm0)
  result.add "Run 'ct <command> --help' for details on a specific command.\n"

# ---------------------------------------------------------------------------
# Subcommand entry points called from launch.nim.
# ---------------------------------------------------------------------------

proc runCtDescribeCommands*() =
  ## Entry point for ``codetracer ct-describe-commands``.
  ## Emits the line-oriented description of every command this binary
  ## handles, sourced from :proc:`selfSurface`.
  let surface = selfSurface()
  stdout.write renderDescribeCommands(surface)
  stdout.flushFile()

proc runCtHelp*() =
  ## Entry point for ``codetracer ct-help``.
  ## Assembles the full help screen and writes it to stdout.
  let asm0 = assembleHelp()
  stdout.write renderHelpScreen(asm0)
  stdout.flushFile()

# ---- Completion logic -----------------------------------------------------

func surfaceCommand(surface: RuntimeCommandSurface,
                     name: string): RuntimeCommand =
  let idx = findCommandIdx(surface, name)
  if idx >= 0: surface.commands[idx] else: newRuntimeCommand("")

proc completionsForSubcommand(asm0: HelpAssembly,
                              cmdName, prefix: string): seq[string] =
  ## File-system + flag completion within a known subcommand.
  let cmd = surfaceCommand(asm0.merged, cmdName)
  if prefix.startsWith("-"):
    # Flag completion: enumerate flag tokens of the subcommand.
    var flagTokens: seq[string]
    for f in cmd.flags:
      if f.name.len > 0:
        flagTokens.add "--" & f.name
      if f.short != '\0':
        flagTokens.add "-" & $f.short
    for tok in flagTokens:
      if tok.startsWith(prefix):
        result.add tok
    return
  # File-system completion filtered by the subcommand's file-types.
  let dirPart = prefix.parentDir
  let basePart = prefix.extractFilename
  let searchDir = if dirPart.len == 0: getCurrentDir() else: dirPart
  if not dirExists(searchDir): return
  for kind, child in walkDir(searchDir, relative = (dirPart.len == 0)):
    let leaf = (if dirPart.len == 0: child else: child.extractFilename)
    if not leaf.startsWith(basePart): continue
    let full = (if dirPart.len == 0: leaf else: dirPart / leaf)
    if kind == pcDir:
      result.add full & "/"
      continue
    if cmd.fileTypes.len == 0:
      result.add full
      continue
    let ext = splitFile(leaf).ext
    if ext in cmd.fileTypes:
      result.add full

proc fastTopLevelCommandNames*(): seq[string] =
  ## M8 fast path: enumerate every top-level command name known to the
  ## launcher *without* spawning any component binary. This must read
  ## only capability files (spec §2.7: "the help delegate reads
  ## capability files, no subprocess needed"). Sources:
  ##
  ## * codetracer-desktop's own commands -- discovered from the
  ##   compile-time :type:`CodetracerConf` surface (no I/O at all).
  ## * Every installed third-party component -- discovered from the
  ##   ``declaredCommands`` field populated by the capability-file
  ##   parser.
  var seen = initTable[string, bool]()
  # Self commands (codetracer-desktop is the help delegate).
  let self = selfSurface()
  for cmd in self.commands:
    if cmd.name.len == 0: continue
    if cmd.name in describeIgnoredCommands: continue
    if not seen.getOrDefault(cmd.name, false):
      seen[cmd.name] = true
      result.add cmd.name
  # Other installed components -- read their capabilities files only.
  for comp in scanInstalledComponents():
    if comp.name == helpDelegateComponentName: continue
    for c in comp.declaredCommands:
      if c.len == 0: continue
      if c in describeIgnoredCommands: continue
      if not seen.getOrDefault(c, false):
        seen[c] = true
        result.add c
  result.sort()

proc findComponentForCommand*(cmdName: string): InstalledComponent =
  ## Return the highest-priority installed component whose capability
  ## file declares ``cmdName``. Returns an empty component (``name ==
  ## ""``) if no installed component handles it. ``scanInstalledComponents``
  ## already returns the per-component first-wins list in priority
  ## order, so we just take the first hit.
  for comp in scanInstalledComponents():
    if comp.name == helpDelegateComponentName: continue
    if cmdName in comp.declaredCommands:
      return comp
  return InstalledComponent()

proc delegateCompletionToComponent*(comp: InstalledComponent,
                                    args: seq[string]): tuple[ok: bool, output: string] =
  ## Run ``<comp.binPath> ct-complete <args...>`` and return its
  ## stdout. ``ok`` is false on any failure (missing binary, non-zero
  ## exit, exception). Stderr is folded into the captured stream the
  ## same way M7's :proc:`runDescribeCommands` does -- the launcher
  ## treats a failing delegate as "no candidates" rather than aborting.
  if comp.binPath.len == 0: return (false, "")
  if not fileExists(comp.binPath): return (false, "")
  var procArgs: seq[string] = @["ct-complete"]
  for a in args:
    procArgs.add a
  try:
    let p = startProcess(comp.binPath, args = procArgs,
                         options = {poStdErrToStdOut, poUsePath})
    let outp = p.outputStream.readAll()
    let code = waitForExit(p)
    close p
    if code != 0:
      return (false, "")
    return (true, outp)
  except CatchableError:
    return (false, "")

proc selfHandlesCommand(cmdName: string): bool =
  ## True if codetracer-desktop's own surface declares the command.
  ## Used to short-circuit delegation when the launcher would route
  ## the command back to us anyway.
  let self = selfSurface()
  for cmd in self.commands:
    if cmd.name == cmdName: return true
  false

proc runCtComplete*(args: seq[string]) =
  ## Entry point for ``codetracer ct-complete``. M8 implements the
  ## two-level dispatch described in spec §2.7:
  ##
  ## **Fast path (top-level)**: when ``args`` is empty or is still
  ## typing the first token, return every top-level command name
  ## declared by an installed component's capability file (or by
  ## codetracer-desktop's own compile-time surface). This path
  ## explicitly avoids spawning any component binary -- exec
  ## overhead is unacceptable for interactive tab completion.
  ##
  ## **Delegation path (subcommand)**: when ``args`` starts with a
  ## known command:
  ##
  ## * If the command is handled by codetracer-desktop itself, run
  ##   the M7 file-system + flag completion logic locally.
  ## * Otherwise, find the component that declares the command in
  ##   its capabilities file and exec ``<binary> ct-complete <args>``
  ##   -- the component is responsible for context-aware completions
  ##   (trace IDs, license-gated flags, etc.).
  if args.len <= 1:
    # ---- Fast path: top-level command-name completion ----
    let prefix = if args.len == 1: args[0] else: ""
    for name in fastTopLevelCommandNames():
      if name.startsWith(prefix):
        stdout.writeLine name
    stdout.flushFile()
    return
  # ---- Delegation path: a subcommand was named ----
  let cmdName = args[0]
  let prefix = args[^1]
  if selfHandlesCommand(cmdName):
    # codetracer-desktop owns this command -- use M7's local
    # completion (file-system filtered by file-types, flag tokens).
    let asm0 = assembleHelp()
    if findCommandIdx(asm0.merged, cmdName) < 0:
      # Defensive: synthesize a minimal surface lookup.
      for cmd in asm0.merged.commands:
        if cmd.name.startsWith(cmdName):
          stdout.writeLine cmd.name
      stdout.flushFile()
      return
    for cand in completionsForSubcommand(asm0, cmdName, prefix):
      stdout.writeLine cand
    stdout.flushFile()
    return
  # Locate the component declaring this command and delegate.
  let comp = findComponentForCommand(cmdName)
  if comp.name.len == 0:
    # Unknown command -- fall back to filtered top-level names so
    # the user gets *something* useful from a typo.
    for name in fastTopLevelCommandNames():
      if name.startsWith(cmdName):
        stdout.writeLine name
    stdout.flushFile()
    return
  let (ok, outp) = delegateCompletionToComponent(comp, args)
  if ok:
    stdout.write outp
  stdout.flushFile()

# ---- Shell completion script generator (M8) -------------------------------
#
# Per spec §2.7, ``ct completion <shell>`` is delegated to the help
# delegate, which prints a per-shell completion script the user can
# source. The generated script calls back into ``codetracer
# ct-complete`` (bypassing the ``ct`` launcher to avoid an extra
# exec hop -- spec §2.7 closing paragraph). For each supported shell
# we ship a hardcoded snippet; the launcher repo's size budget does
# not apply here (codetracer-desktop has no size cap).

const
  bashCompletionScript* = """# bash completion script for the ct launcher
# Generated by `codetracer ct-completions bash`.
# Source this file (e.g. add to /etc/bash_completion.d/ct) or
# evaluate inline: `eval "$(codetracer ct-completions bash)"`.
#
# At runtime, _ct_completions calls `codetracer ct-complete ...`
# directly -- bypassing the `ct` launcher exec hop (spec §2.7).
_ct_completions() {
  local IFS=$'\n'
  local cur_words=("${COMP_WORDS[@]:1}")
  COMPREPLY=($(codetracer ct-complete "${cur_words[@]}"))
}
complete -F _ct_completions ct
"""

  zshCompletionScript* = """#compdef ct
# zsh completion script for the ct launcher
# Generated by `codetracer ct-completions zsh`.
# Save under a directory in $fpath (e.g. /usr/share/zsh/site-functions/_ct)
# or source inline: `source <(codetracer ct-completions zsh)`.
#
# At runtime, _ct calls `codetracer ct-complete ...` directly --
# bypassing the `ct` launcher exec hop (spec §2.7).
_ct() {
  local -a candidates
  local cur_word="${words[CURRENT]}"
  local -a partial
  partial=("${(@)words[2,CURRENT]}")
  candidates=("${(@f)$(codetracer ct-complete "${partial[@]}")}")
  compadd -a candidates
}
compdef _ct ct
"""

  fishCompletionScript* = """# fish completion script for the ct launcher
# Generated by `codetracer ct-completions fish`.
# Save under ~/.config/fish/completions/ct.fish or source it.
#
# At runtime, the completion calls `codetracer ct-complete ...`
# directly -- bypassing the `ct` launcher exec hop (spec §2.7).
function __ct_complete
  set -l tokens (commandline -opc)
  set -l current (commandline -ct)
  set -l partial $tokens[2..-1] $current
  codetracer ct-complete $partial
end
complete -c ct -f -a '(__ct_complete)'
"""

proc completionScriptFor*(shell: string): string =
  ## Return the canned completion script for ``shell`` (case
  ## insensitive). Returns the empty string for unknown shells; the
  ## caller is responsible for emitting a diagnostic.
  case shell.toLowerAscii()
  of "bash":
    bashCompletionScript
  of "zsh":
    zshCompletionScript
  of "fish":
    fishCompletionScript
  else:
    ""

proc runCtCompletions*(shell: string) =
  ## Entry point for ``codetracer ct-completions <shell>``.
  ## Emits the requested shell-completion script on stdout.
  ## Unknown shells produce a one-line error on stderr and an
  ## exit-style non-zero status (we use ``quit 1`` so the caller
  ## sees a real failure rather than a silently empty stdout).
  if shell.len == 0:
    stderr.writeLine "ct-completions: missing shell argument (expected bash, zsh, or fish)"
    quit 1
  let body = completionScriptFor(shell)
  if body.len == 0:
    stderr.writeLine "ct-completions: unsupported shell '" & shell &
                     "' (supported: bash, zsh, fish)"
    quit 1
  stdout.write body
  stdout.flushFile()
