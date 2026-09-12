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
## `layout.definitionFileName`, which is a `case` over a closed enum, and **no
## definition file is parsed here at all**: this reads bytes and hands them
## over.
##
## That is the concrete form of §2's rule. A repository cannot cause CodeTracer
## to open a DEFINITION file of its choosing, so it cannot cause CodeTracer to
## load one, so it cannot cause CodeTracer to run one. The attack needs a name
## to travel from the data into a *loader* and there is no channel for it.
##
## ## ONE STRING FROM INSIDE A DEFINITION *DOES* REACH A SYSCALL
##
## Said here rather than left for a reader to discover, because the paragraph
## above used to end "**No string from inside any definition file ever reaches
## a filesystem call**" and that sentence is FALSE — PLAT-11's verification
## pass measured it on 2026-09-11.
##
## `readSourceFile` at the bottom of this file takes a POINT'S `path`, which a
## definition supplied, and opens `root / thatPath`. That is deliberate: it is
## what §4's re-resolution IS, and the bytes go into a line number rather than
## into anything that loads or runs. What was wrong was the SCOPE of the
## claim, and the cost of the over-wide version was concrete: it described a
## containment that was purely lexical as though nothing needed containing,
## and a checked-in symlink walked out of the checkout through it. See
## `readSourceFile`'s own header for the repair.
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

when defined(posix):
  import std/posix

import ../../common/project_definitions

export project_definitions

# PLAT-8's containment predicate, SHARED rather than re-derived.
#
# Verification-Harness-Traps §14 is "one predicate, one function", and §14a is
# the same rule with the worst instance attached: a whole module re-derived
# from the same examples, which then disagreed with its twin in a way that was
# invisible to every green run. "Is this resolved path inside this resolved
# root" is asked in exactly two places in this product — by `fs:read` /
# `fs:write` in `plugin_host/plugin_io.nim`, and here — so it is asked through
# one function.
#
# A `from … import` rather than a plain `import`, because ONE symbol is wanted
# and the rest of that module is PLAT-8's grant vocabulary. This is the
# filesystem half of PLAT-11 and is outside `common/project_definitions/` —
# whose import closure is asserted verbatim by `project_definitions_test` and
# still reaches four `std` modules and nothing else — so sharing a *path
# predicate* here does not make a project definition a plugin. There is still
# no `Capability`, no `GrantSet` and no grant ledger anywhere near a project
# definition.
#
# ITS ONE COST WAS A DEFECT, AND IT IS FIXED (2026-09-12). This paragraph used
# to record a "real narrowing of what a definition may name": `pathIsUnder`
# refused outright if the two characters `..` appeared ANYWHERE in either
# argument — a substring test, not a segment test — so a source file with `..`
# inside a NAME (`src/a..b.nim`, which `pathProblem` accepts) was refused here.
#
# The narrowing was wider than that sentence, which is why it is worth keeping
# the history. The predicate tests BOTH arguments and the second one is the
# RESOLVED CHECKOUT, so a checkout whose own path contains `..` — `my..project`,
# `v1..v2/checkout` — had EVERY file in it refused, and the row §4 shows the
# user said "'src/a.nim' is not in this checkout", which is false. It failed in
# the safe direction, so nothing anywhere went red
# (Verification-Harness-Traps §15).
#
# `capabilities.pathIsUnder` now tests for a `..` SEGMENT. The repair is in
# PLAT-8's file, with PLAT-8's arm (`V7`) and PLAT-8's re-recorded control
# digest, because that is whose file it is — and the positive is asserted HERE
# too, in `project_definitions_dir_test`, because this is the caller the outage
# was measured through.
from ../../common/plugin_model/capabilities import pathIsUnder

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

when defined(posix):
  let O_NOFOLLOW_CT {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    ## `std/posix` declares `O_CLOEXEC` and not this, on every platform —
    ## PLAT-8 checked `posix_linux_amd64_consts`, `posix_other_consts` and
    ## `posix_freertos_consts` and this file inherits that finding. Imported
    ## from the header rather than written as a number, because the value
    ## differs between Linux (0o400000), the BSDs (0x100) and macOS.

proc resolvedRealPath(path: string): string =
  ## `realpath(3)` on POSIX — every symlink in the path followed — or the
  ## empty string when the path resolves to nothing at all.
  ##
  ## ## WHY THIS IS NOT `plugin_io.canonicalPath`, MEASURED RATHER THAN
  ## ## PREFERRED
  ##
  ## PLAT-8's canonicaliser is three fallbacks deep — `absolutePath`, then
  ## `expandFilename`, then `expandFilename(parent) / leaf`, then
  ## `normalizedPath` — because `writePath` CREATES files and a leaf that does
  ## not exist yet cannot be `realpath`'d. Nothing here creates anything: a
  ## source file that cannot be resolved is a source file that cannot be read,
  ## and "it does not resolve" and "it is not there" are the same answer
  ## (`SourceFile(present: false)`). So the parent-fallback arm would be dead
  ## code carrying a security argument, which is worse than absent.
  ##
  ## It is also not IMPORTABLE. `canonicalPath` lives inside `plugin_io.nim`'s
  ## native `when` arm, behind `chronos`/`asyncdispatch` and the whole plugin
  ## host; and PLAT-8's mutation harness aims arms at needles that are literal
  ## lines of it (`      return expandFilename(absolute)`), so relocating it
  ## into a shared module would move those needles and leave the arms silently
  ## unkillable — Verification-Harness-Traps §16, arriving through a tidy-up.
  ##
  ## **The containment PREDICATE is shared** (`pathIsUnder`, above) and is the
  ## thing §14 is about: the canonicaliser produces an input, the predicate
  ## takes the decision, and there is one of the latter.
  ##
  ## ## AND IT IS A REAL RESOLUTION ONLY ON POSIX
  ##
  ## `os.expandFilename` is `realpath(3)` on POSIX and `GetFullPathNameW` on
  ## Windows, which normalises `.` and `..` and **resolves no symlink or
  ## junction at all** (its doc comment's "Follows symlinks" is true of one of
  ## its two `when` arms). The containment below is therefore a real
  ## containment on POSIX and a normalisation on Windows — the same bound
  ## PLAT-8 records for the same reason, not a new one.
  try:
    expandFilename(path)
  except CatchableError, Defect:
    ""

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
  ##
  ## ## AND THE LEXICAL CHECK IS NOT ENOUGH, WHICH WAS MEASURED
  ##
  ## PLAT-11's verification pass, 2026-09-11, against the product loader: a
  ## checkout carrying an ordinary checked-in symlink `vendor -> /elsewhere`,
  ## plus `path = "vendor/id_rsa"` in `points.toml`. `pathProblem` returns
  ## `ppOk` — the path IS lexically inside — `loadCheckoutDefinitions` accepts
  ## the collection, and `resolveCollection` over this function returned
  ## `prResolved` at line 1 of a file outside the checkout, with the outside
  ## file's bytes in `SourceFile.lines`. Remove the symlink and the same
  ## declaration finds nothing, so the symlink was doing the work.
  ##
  ## This is PLAT-8's `fs:read` repair arriving in a second place
  ## (Extensibility-Model §8: "`fs:read` reached recordings through an ordinary
  ## symlink until the containment moved to the realpath") and it takes the
  ## same two-part shape, for the same reasons:
  ##
  ##   1. **Resolve, then contain.** Both the root and the candidate go through
  ##      `resolvedRealPath` and the verdict is `pathIsUnder` — PLAT-8's own
  ##      predicate, not a second one.
  ##   2. **Open in a way that cannot disagree with the resolution.** See below.
  ##
  ## ## BOTH SIDES ARE RESOLVED, AND THAT IS THE HALF THAT IS EASY TO SKIP
  ##
  ## Verification-Harness-Traps §15: a half-repair that fails in the SAFE
  ## direction looks like nothing from outside. Resolving the candidate and
  ## comparing it against an unresolved `root` would make every checkout that
  ## is itself reached through a symlink — `/tmp` on macOS, a bind mount, a
  ## home under `/home/x` that is really `/data/home/x`, a worktree behind a
  ## convenience link — stop containing its own files. Every point in it would
  ## report "the file is not there", every security assertion here would be
  ## MORE satisfied, and nothing anywhere would go red. PLAT-8 found exactly
  ## this in `canonicalGrantsOf` by writing the positive twin, so the positive
  ## twin is written here too, as its own case in
  ## `project_definitions_dir_test`.
  ##
  ## ## THE TOCTOU SEAM, NAMED RATHER THAN HOPED AWAY
  ##
  ## The resolution happens, then the containment decision, then the open.
  ## Anyone who can write inside the checkout can change what a name means in
  ## that window, so "we resolved it" is a statement about the past. Three
  ## things, and what each does and does not cover:
  ##
  ##   * the path opened is the RESOLVED one, which by construction contains no
  ##     symlink as of the resolve — so there is no second traversal of the
  ##     unresolved string, and resolve and open cannot name two different
  ##     paths;
  ##   * `O_NOFOLLOW` — the kernel refuses if the FINAL component is a symlink
  ##     at the moment of the open. A leaf that has become one since the
  ##     resolve is precisely the swap, and `ELOOP` is the refusal;
  ##   * an `fstat` of the descriptor against an `lstat` of the same name,
  ##     compared on `(st_dev, st_ino)`. The bytes are then read from THAT
  ##     DESCRIPTOR and never by re-opening the name, so the file the check
  ##     passed is the file the caller gets.
  ##
  ## The check FAILS CLOSED — a disagreement is `present: false`, not a retry.
  ##
  ## **Two residuals, stated rather than implied away.** A swap of an
  ## INTERMEDIATE directory that completes BEFORE the open is followed
  ## consistently by both the open and the `lstat`, so they agree; only a swap
  ## racing the check itself is caught. Closing that needs per-component
  ## `openat(O_NOFOLLOW)` or Linux's `openat2(RESOLVE_BENEATH)`, which is one
  ## platform's answer to a problem the other two would still have. And a HARD
  ## LINK from inside the checkout to a file outside it defeats every
  ## path-based containment, this one included, because there is nothing left
  ## to resolve. Both need write access inside the checkout, which is the
  ## user's own; neither is reachable from `git clone`, which is the threat §2
  ## is about — a symlink IS.
  if pathProblem(repoRelativePath) != ppOk:
    return SourceFile(present: false)

  let resolvedRoot = resolvedRealPath(root)
  let resolvedFile = resolvedRealPath(root / repoRelativePath)
  if resolvedRoot.len == 0 or resolvedFile.len == 0:
    # Either the checkout or the file resolves to nothing. A file that is not
    # there and a file that cannot be resolved are one answer here.
    return SourceFile(present: false)
  if not pathIsUnder(resolvedFile, resolvedRoot):
    return SourceFile(present: false)

  var text = ""
  when not defined(posix):
    # No `O_NOFOLLOW` and no `(dev, ino)` re-verification off POSIX — see
    # `resolvedRealPath`'s header. The containment above still runs.
    try:
      text = readFile(resolvedFile)
    except CatchableError:
      return SourceFile(present: false)
  else:
    var fd = posix.open(resolvedFile.cstring,
                        O_RDONLY or O_NOFOLLOW_CT or O_CLOEXEC)
    if fd < 0:
      return SourceFile(present: false)
    var opened, named: Stat
    if fstat(fd, opened) != 0 or lstat(resolvedFile.cstring, named) != 0 or
       opened.st_dev != named.st_dev or opened.st_ino != named.st_ino:
      discard posix.close(fd)
      return SourceFile(present: false)
    var f: File
    if not open(f, FileHandle(fd), fmRead):
      discard posix.close(fd)
      return SourceFile(present: false)
    try:
      text = f.readAll()
    except CatchableError:
      f.close()
      return SourceFile(present: false)
    f.close()
  SourceFile(present: true, lines: text.splitLines())
