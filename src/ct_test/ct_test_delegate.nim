## ct_test_delegate.nim — where the ORC-built ``ct-test`` that a refc ``ct``
## hands ``test run`` to is found.
##
## ## Why ``ct`` delegates at all
##
## ``test run`` executes the discovered tests on a worker pool that shares
## sequences with the spawning thread (``run_orchestration.runUnits``). Under
## Nim's refc collector every thread owns a private heap, so a refc build of
## the runner crashes on the first run; ORC/ARC share one heap and do not. The
## ``ct`` binary is built ``--mm:refc`` for the rest of CodeTracer's sake, while
## ``ct-test`` (the same CLI from ``ct_test.nim``) is built ``--mm:orc`` and is
## shipped beside ``ct`` in every package. So ``ct test run …`` becomes
## ``ct-test test run …``: the argument vector ``runCtTest`` expects is already
## ``test run …``, so the arguments pass through unchanged, and so do the
## environment, the working directory and the standard streams.
##
## ## The lookup order
##
## 1. **Beside the running executable, after resolving symlinks.** Every
##    package installs ``ct-test`` in the same ``bin/`` as the real ``ct``
##    binary. Resolving symlinks first is what makes a ``ct`` that a user
##    linked into ``~/.local/bin`` still find its own ``ct-test`` rather than
##    whatever happens to sit next to the link.
## 2. **The install root's ``tools/`` directory**, when it exists — the
##    parent of that ``bin/`` plus ``tools``, which is where a packaged layout
##    keeps auxiliary programs.
## 3. **``PATH``.**
##
## A candidate that is the running executable itself is skipped, so a refc
## binary that happens to be NAMED ``ct-test`` can never hand ``test run`` to
## itself. The ORC ``ct-test`` never reaches this module's caller at all: the
## delegation is compiled only into refc builds.
##
## This module only answers "where"; it neither starts a process nor prints.
## ``src/ct/codetracer.nim`` performs the hand-over, and ``ct_test.nim`` uses
## ``describeCtTestLookup`` to name the places it tried when nothing was found.

import std/[os, strutils]

const
  CtTestProgram* = "ct-test"
    ## The ORC runner's program name, without the platform's executable
    ## extension.

type
  CtTestCandidateKind* = enum
    cckBesideExecutable ## next to the running executable's real path
    cckToolsDir         ## ``<install root>/tools``
    cckPath             ## the ``PATH`` search

  CtTestCandidate* = object
    kind*: CtTestCandidateKind
    path*: string
      ## The file this step would run. Empty for a step that had nothing to
      ## look at (``PATH`` with no match, no ``tools/`` directory).

  CtTestLookup* = object
    selfExe*: string
      ## The running executable's resolved path — the anchor of step 1, and
      ## the file no step may return.
    tried*: seq[CtTestCandidate]
      ## Every step, in order, including the ones that found nothing, so a
      ## refusal can name all of them.
    found*: string
      ## The first candidate that exists and is not ``selfExe``; "" if none.

proc ctTestFileName*(): string =
  ## ``ct-test`` with the platform's executable extension (``ct-test.exe`` on
  ## Windows).
  addFileExt(CtTestProgram, ExeExt)

proc resolvedPath(path: string): string =
  ## ``path`` with every symlink resolved, or ``path`` itself when it cannot
  ## be resolved (a file that does not exist, a permission error). A lookup
  ## must degrade to "not found" rather than raise.
  if path.len == 0:
    return ""
  try:
    expandFilename(path)
  except CatchableError:
    path

proc runningExecutable*(): string =
  ## The running process's executable, symlinks resolved.
  ##
  ## ``getAppFilename`` and not ``paths.ctAppFilename``: the latter prefers
  ## ``CODETRACER_APP_FILENAME``, which the AppImage's loader wrappers export
  ## and every child inherits, so a stale value could name another program.
  ## Only the DIRECTORY matters here, and the AppImage's bundled loader lives
  ## in the same ``bin/`` as the programs it starts, so the kernel's own answer
  ## is right in every layout.
  try:
    resolvedPath(getAppFilename())
  except CatchableError:
    ""

proc isUsable(candidate, selfExe: string): bool =
  candidate.len > 0 and fileExists(candidate) and
    (selfExe.len == 0 or resolvedPath(candidate) != selfExe)

proc locateCtTest*(selfExe = runningExecutable();
                   pathValue = getEnv("PATH")): CtTestLookup =
  ## Walk the lookup order for ``selfExe`` and ``pathValue`` (the ``PATH``
  ## value to search; parameters so a caller can ask about a layout other than
  ## its own).
  result.selfExe = resolvedPath(selfExe)
  let fileName = ctTestFileName()
  let binDir = if result.selfExe.len > 0: result.selfExe.parentDir else: ""

  var beside = CtTestCandidate(kind: cckBesideExecutable)
  if binDir.len > 0:
    beside.path = binDir / fileName
  result.tried.add beside

  var tools = CtTestCandidate(kind: cckToolsDir)
  if binDir.len > 0:
    let toolsDir = binDir.parentDir / "tools"
    if dirExists(toolsDir):
      tools.path = toolsDir / fileName
  result.tried.add tools

  # `findExe` is not used because it reads the process's own PATH; the
  # explicit walk below honours `pathValue` and skips `selfExe`, so a `ct-test`
  # that is the running binary does not hide a real one later on PATH.
  var onPath = CtTestCandidate(kind: cckPath)
  for dir in pathValue.split(PathSep):
    if dir.len == 0:
      continue
    let candidate = dir / fileName
    if isUsable(candidate, result.selfExe):
      onPath.path = candidate
      break
  result.tried.add onPath

  for candidate in result.tried:
    if isUsable(candidate.path, result.selfExe):
      result.found = candidate.path
      return

proc describeCtTestLookup*(lookup: CtTestLookup): string =
  ## The places ``lookup`` tried, as one sentence for a refusal message.
  var parts: seq[string] = @[]
  for candidate in lookup.tried:
    case candidate.kind
    of cckBesideExecutable:
      parts.add(if candidate.path.len > 0:
                  "next to this executable (" & candidate.path & ")"
                else:
                  "next to this executable (its path could not be determined)")
    of cckToolsDir:
      parts.add(if candidate.path.len > 0:
                  "the install's tools directory (" & candidate.path & ")"
                else:
                  "the install's tools directory (there is none)")
    of cckPath:
      parts.add("`" & ctTestFileName() & "` on PATH")
  "looked for `" & ctTestFileName() & "` " & parts.join(", then ")
