## launch/project_definitions_dir.nim — PLAT-11's filesystem half: reading a
## checkout's `.codetracer/` directories off a disk.
##
## `common/project_definitions/` has the grammar and no filesystem. This file
## has the filesystem and no grammar. The split is the same one
## `plugin_model` / `plugin_components` draws, for the same reason, and it is
## what makes PLAT-11's third deliverable — "a loader with **no** I/O,
## network, process or filesystem access beyond the checkout" — checkable: the
## loader's import closure is asserted, and everything that can touch a disk
## is in this file, which is small enough to read in one sitting.
##
## ## WHAT THIS FILE OPENS, EXHAUSTIVELY
##
##   <root>/.codetracer/points.toml
##   <root>/.codetracer/visualisers.toml
##   <root>/.codetracer/scratchpad.toml
##   <root>/<package>/.codetracer/<the same three>
##
## and, for the user's own set, the same three names under a directory the
## CALLER names. Every one of those names comes from
## `layout.definitionFileName`, which is a `case` over a closed enum. **No
## string from inside any definition file ever reaches a filesystem call**,
## because no definition file is parsed here at all: this reads bytes and
## hands them over.
##
## That is the concrete form of §2's rule. A repository cannot cause CodeTracer
## to open a file of its choosing, so it cannot cause CodeTracer to load one,
## so it cannot cause CodeTracer to run one. The attack needs a name to travel
## from the data into a syscall and there is no channel for it.
##
## ## THE PACKAGE LIST IS THE CALLER'S, AND IS CHECKED
##
## `discoverProjectDefinitions` does not walk the tree looking for
## `.codetracer/` directories. A recursive walk of a cloned repository is an
## unbounded amount of work over attacker-chosen directory names, and the
## deepest nesting anyone would legitimately use is a handful of package
## directories somebody can list. So the caller passes the package scopes, and
## every one of them goes through `containment.pathProblem` before it is
## joined to the root — a scope is a path from the repository, and a path from
## the repository is checked the way every other one is.
##
## ## THE SIZE BOUND IS APPLIED BEFORE THE READ, NOT AFTER
##
## `getFileSize` first, `readFile` only if it fits. Reading a 4 GB
## `points.toml` into memory and *then* refusing it for being too large is a
## denial of service with a polite error message.
##
## ## THE OTHER TWO MEANINGS OF `.codetracer/`
##
## `$HOME/.codetracer` is the LAUNCHER's user root (registry, components,
## PLAT-10's grants) and `<repo>/.codetracer/<name>.trace` is a recording.
## The second is the same directory as this one and the two coexist without a
## rule because the file set here is a constant: a `.trace` is not one of the
## three names, so it is neither read nor reported.

import std/[os, strutils]

import ../../common/project_definitions

export project_definitions

type
  DiscoveryOutcome* = object
    ## What a scan of one root produced. `files` is what to hand
    ## `loadProjectDefinitions`; `problems` is what could not be read AT ALL —
    ## a file that exists and is unreadable, or one too large to read.
    ##
    ## A MISSING FILE IS NOT A PROBLEM. Almost every repository has no
    ## `.codetracer/` at all and reporting its absence would be noise on every
    ## launch. A present-but-unreadable one IS a problem, because somebody put
    ## it there.
    files*: seq[DefinitionFile]
    problems*: seq[ProjectDefinitionProblem]

proc readDefinitionFile(diskPath, reportedPath: string;
                        kind: DefinitionFileKind; origin: DefinitionOrigin;
                        scope: string; outcome: var DiscoveryOutcome) =
  ## Read one file of one known kind, if it is there.
  if not fileExists(diskPath):
    return

  if tierOf(kind) == dtExecutable:
    # PRESENT, AND NOT READ. Not `readFile`d, not parsed, not mapped, not
    # hashed. The `DefinitionFile` handed on carries an EMPTY `text`, and
    # `load.composeInto` turns it straight into the notice — so even the bytes
    # of an executable-tier definition never enter this process without the
    # grant PLAT-13 owns and this build does not implement.
    outcome.files.add DefinitionFile(kind: kind, origin: origin, scope: scope,
                                     path: reportedPath, text: "")
    return

  var size: BiggestInt = 0
  try:
    size = getFileSize(diskPath)
  except CatchableError as e:
    outcome.problems.add problem(reportedPath, 0, pdcMalformedToml,
      "could not be measured: " & e.msg)
    return
  if size > MaxDefinitionBytes:
    # BEFORE THE READ. See the header.
    outcome.problems.add problem(reportedPath, 0, pdcFileTooLarge,
      $size & " bytes on disk; the bound is " & $MaxDefinitionBytes &
      ". The size is taken before the file is opened for reading, so an " &
      "oversized definition costs a stat rather than a read")
    return

  var text = ""
  try:
    text = readFile(diskPath)
  except CatchableError as e:
    outcome.problems.add problem(reportedPath, 0, pdcMalformedToml,
      "could not be read: " & e.msg)
    return
  outcome.files.add DefinitionFile(kind: kind, origin: origin, scope: scope,
                                   path: reportedPath, text: text)

proc reportStrayTomlFiles(dir, scope: string;
                          outcome: var DiscoveryOutcome) =
  ## A `.toml` in a `.codetracer/` that is not one of the three names.
  ##
  ## THE ONE PLACE THIS DESIGN COULD STILL SWALLOW SOMETHING. The file set is
  ## a constant, which is the security property; the cost of that property is
  ## that `point.toml` — one character from `points.toml` — would otherwise be
  ## read by nobody and reported by nobody, and the author would see their
  ## definitions simply not apply. That is `lpUnknownPane` in its most
  ## invisible form, so it is a notice.
  ##
  ## SCOPED TO `.toml`. `<repo>/.codetracer/<name>.trace` is a RECORDING and
  ## lives in this same directory; reporting every file here would report
  ## every recording, and a report that fires constantly is one nobody reads.
  ##
  ## The listing is READ-ONLY and the names it produces are used for nothing
  ## except this message — none of them is ever opened.
  var known: seq[string] = @[]
  for kind in DefinitionFileKind: known.add definitionFileName(kind)
  var listed = 0
  try:
    for kind, path in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}: continue
      inc listed
      if listed > 256:
        # Bounded, like everything else that reads a cloned repository: a
        # `.codetracer/` with fifty thousand files gets one message rather
        # than fifty thousand.
        break
      let name = path.extractFilename
      if not name.toLowerAscii.endsWith(".toml"): continue
      if name in known: continue
      outcome.problems.add problem(
        (if scope.len == 0: ProjectDefinitionDir else: scope & "/" & ProjectDefinitionDir) &
          "/" & name,
        0, pdnUnrecognisedDefinitionFile,
        "'" & name & "' is not a definition file this build reads. The " &
        "declarative definitions are " & known[0] & ", " & known[1] & " and " &
        known[2] & ". It was not opened — the set of files read here is a " &
        "constant, so nothing in a repository can name another one — and it " &
        "is reported because a one-character typo in a definition's NAME " &
        "would otherwise be completely silent")
  except CatchableError:
    # A directory that cannot be listed is not a problem worth a message: the
    # three files either opened or did not, and that is already reported.
    discard

proc scanScope(root, scope: string; origin: DefinitionOrigin;
               outcome: var DiscoveryOutcome) =
  ## The three declarative names and the two executable ones, in one
  ## `.codetracer/`. DERIVED from the enum — see `layout.definitionFileName`
  ## — so a sixth file kind is scanned the day it is declared and never a day
  ## before.
  for kind in DefinitionFileKind:
    let reported = definitionPath(scope, kind)
    let disk = root / reported
    readDefinitionFile(disk, reported, kind, origin, scope, outcome)
  let dir = root / (if scope.len == 0: ProjectDefinitionDir
                    else: scope & "/" & ProjectDefinitionDir)
  if dirExists(dir):
    reportStrayTomlFiles(dir, scope, outcome)

proc discoverProjectDefinitions*(root: string;
                                 packageScopes: openArray[string] = []):
    DiscoveryOutcome =
  ## Every project definition in `root`, plus one per named package scope.
  ##
  ## `root` is the checkout. `packageScopes` are repository-relative package
  ## directories (§6's monorepo composition); each is checked against the
  ## containment grammar before it is joined, so a scope cannot be the channel
  ## a path outside the checkout arrives through.
  scanScope(root, "", doProject, result)
  var scopes = 0
  for scope in packageScopes:
    inc scopes
    if scopes > MaxDefinitionScopes:
      result.problems.add problem(ProjectDefinitionDir, 0, pdcTooManyEntries,
        "more than " & $MaxDefinitionScopes & " package scopes were offered " &
        "to one scan")
      break
    let sp = pathProblem(scope)
    if sp != ppOk:
      result.problems.add problem(
        scope & "/" & ProjectDefinitionDir, 0, pdcScopeEscapesProject,
        describe(sp, scope) & ". A package scope is a path from the " &
        "repository root and is checked as one, so composition cannot reach " &
        "outside the checkout")
      continue
    scanScope(root, scope, doProject, result)

proc discoverUserDefinitions*(userRoot: string): DiscoveryOutcome =
  ## The user's OWN definitions, from a directory outside any checkout.
  ##
  ## Tagged `doUser` at the point they enter the process, so §6's separation
  ## holds from the first byte rather than being applied later by whoever
  ## remembers to. `load.loadProjectDefinitions` refuses a project set
  ## containing one of these, and the tag is what makes that refusal possible.
  ##
  ## THE EXECUTABLE TIER IS NOT SPECIAL-CASED HERE EITHER. A user's own
  ## `visualisers.wasm` is still not read by this build — PLAT-13 owns the
  ## grant, and "the user put it there themselves" is a different argument
  ## that PLAT-13 gets to make rather than one this file makes for it.
  for kind in DefinitionFileKind:
    let name = definitionFileName(kind)
    readDefinitionFile(userRoot / name, "<user>/" & name, kind, doUser, "",
                       result)

proc loadCheckoutDefinitions*(root: string;
                              packageScopes: openArray[string] = [];
                              userRoot = ""): LoadedProjectDefinitions =
  ## The whole of PLAT-11, from a directory: discover, then load.
  ##
  ## THIS IS THE ONLY FUNCTION IN THE PRODUCT THAT TURNS A CHECKOUT INTO
  ## DEFINITIONS, and it is twelve lines, because everything interesting is on
  ## the other side of the pure/impure line.
  let projectScan = discoverProjectDefinitions(root, packageScopes)
  var userScan = DiscoveryOutcome()
  if userRoot.len > 0:
    userScan = discoverUserDefinitions(userRoot)
  result = loadProjectDefinitions(projectScan.files, userScan.files)
  # THE READ PROBLEMS COME FIRST in the combined list, because a file that
  # could not be read is upstream of every grammar problem and a reader
  # scanning the column should meet the cause before the consequences.
  var combined = projectScan.problems
  for p in userScan.problems: combined.add p
  for p in result.problems: combined.add p
  result.problems = combined

proc readSourceFile*(root, repoRelativePath: string): SourceFile =
  ## One source file of the checkout, for `resolve.resolveCollection`.
  ##
  ## THE PATH IS RE-CHECKED HERE, even though `parse.nim` already refused
  ## anything outside the grammar before it could become a `PointDefinition`.
  ## Verification-Harness-Traps §14 warns against two copies of a predicate,
  ## and this is not one: it is ONE predicate (`containment.pathProblem`)
  ## called at two places, which is the remedy rather than the defect. The
  ## second call is here because this is the function that turns a string into
  ## a syscall, and a check at the boundary that performs the dangerous
  ## operation survives a refactor of everything upstream of it.
  if pathProblem(repoRelativePath) != ppOk:
    return SourceFile(present: false)
  let disk = root / repoRelativePath
  if not fileExists(disk):
    return SourceFile(present: false)
  var text = ""
  try:
    text = readFile(disk)
  except CatchableError:
    return SourceFile(present: false)
  SourceFile(present: true, lines: text.splitLines())
