## component_roots.nim — where an installed CodeTracer component lives.
##
## ## Why this is its own module
##
## Two callers need the launcher's component-search order and neither may
## import the other:
##
##   * `launch/help_delegate.nim` walks it to assemble `ct --help` and shell
##     completion. It pulls in confutils, `osproc` and the whole
##     `CodetracerConf` bridge.
##   * `launch/ui_dispatch.nim` walks it in the ARGUMENT-PARSING PROLOGUE to
##     resolve `--ui=tui` to `codetracer-tui`'s binary
##     (`codetracer-specs/CLI/ct/ui-selection.md` §3.1). That path runs before
##     configuration, before the engine and before any window, and its budget is
##     measured in milliseconds, so importing the help delegate to reach one
##     `seq[string]` is exactly the mistake §3.1 warns about.
##
## The list itself was duplicated before this module existed; the copy that
## drifts is the one that stops finding a component a user installed.
##
## The order mirrors `codetracer-launcher/src/launcher.nim`'s `collectLevels`.
## `CODETRACER_COMPONENTS_ROOT` REPLACES the user, system and distro levels
## rather than being prepended to them — that is what makes it usable as a test
## isolation switch, and every suite in this repo that routes through the real
## launcher relies on it.

import std/[os, strutils]

const
  registryEnvVar* = "CODETRACER_REGISTRY_PATH"
    ## Test-only override: forces a specific registry root. Matches the
    ## launcher's ``CODETRACER_REGISTRY_PATH`` convention.

  componentsRootEnvVar* = "CODETRACER_COMPONENTS_ROOT"
    ## Test-only override: forces a specific components root, and SUPPRESSES
    ## the real user/system/distro levels. Matches the launcher's convention.

  componentsPathEnvVar* = "CODETRACER_COMPONENTS_PATH"
    ## Colon-separated extra component directories. Honoured for parity with
    ## the launcher, and never suppressed.

  componentDirEnvVar* = "CODETRACER_COMPONENT_DIR"
    ## The bundle directory the launcher exported for the component it execed
    ## — `<root>/<name>@<version>`. Its PARENT is the root that actually won
    ## the launcher's own scan, which is why `collectComponentLevels` puts it
    ## first: a component looking for a SIBLING component should look where it
    ## was itself found before it looks anywhere else.

type
  ComponentLevel* = object
    path*: string
    label*: string
      ## "self" | "user" | "system" | "distro" — the provenance column
      ## `ct --help` prints, and the tie-break order for a component installed
      ## at more than one level.

proc collectComponentLevels*(): seq[ComponentLevel] =
  ## The component search roots, highest priority first.
  ##
  ## The "self" level is not in the launcher's own list and cannot be: the
  ## launcher is the process that SETS `CODETRACER_COMPONENT_DIR`, so it never
  ## reads one. For a component resolving a sibling it is the most specific
  ## answer available and it costs no directory scan to produce.
  let componentDir = getEnv(componentDirEnvVar, "")
  if componentDir.len > 0:
    let siblingRoot = componentDir.parentDir
    if siblingRoot.len > 0:
      result.add ComponentLevel(path: siblingRoot, label: "self")

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

proc findComponentBinary*(componentName, binName: string): string =
  ## The absolute path of `<componentName>@<version>/bin/<binName>`, searched
  ## in `collectComponentLevels` order, or "" when no level holds one.
  ##
  ## The version is NOT parsed or compared. The launcher's own resolution reads
  ## a `latest` file and honours `.ctrc` pins, and reproducing that here would
  ## be a second implementation of it; when a level holds more than one version
  ## the lexicographically greatest directory name wins, which is stable and is
  ## the behaviour a single-version install (every install today) has anyway.
  let prefix = componentName & "@"
  for level in collectComponentLevels():
    if not dirExists(level.path):
      continue
    var bestName = ""
    var bestPath = ""
    for kind, child in walkDir(level.path):
      if kind != pcDir and kind != pcLinkToDir:
        continue
      let name = child.lastPathPart
      if not name.startsWith(prefix):
        continue
      if bestName.len > 0 and name <= bestName:
        continue
      let candidate = child / "bin" / binName
      if fileExists(candidate) or symlinkExists(candidate):
        bestName = name
        bestPath = candidate
    if bestPath.len > 0:
      return bestPath
  ""
