## ct_state_dir.nim
##
## The workspace-local ``.ct/`` directory, and the one rule every writer of it
## must follow: **``.ct/`` is ignored by git before anything is written into
## it.**
##
## Why this is a correctness rule, not tidiness
## --------------------------------------------
## ``.ct/`` holds derived state — review datasets (``ct agent end-of-turn``
## writes ``.ct/review`` by default), recordings (the documented workflow
## records into ``.ct/runs``). A test certificate records ``untracked = true``
## whenever ``git status`` reports any untracked, non-ignored path
## (``certificate_issuance.probeVcs``). An unignored ``.ct/`` therefore makes
## CodeTracer's own bookkeeping change what every later certificate says about
## the user's work — and a strict consumer that withholds on ``untracked``
## would withhold every one of them.
##
## Until CTC-3e the certificate store under ``.ct/certificates`` wrote the
## guard as a side effect of publishing, so every other writer of ``.ct/``
## silently relied on it. The store moved out of the workspace (Transport §2),
## so the guard now lives here, with the directory, and each writer calls it.
##
## The guard is ``.ct/.gitignore`` containing ``*``. ``*`` matches the
## ``.gitignore`` itself, so ``git status`` reports nothing for the directory
## and there is nothing the user has to commit for the guard to hold — the
## shape ``cargo`` writes into ``target/``. An existing ``.ct/.gitignore`` is
## the user's and is left untouched.
##
## ``ct test`` writes nothing under ``.ct/``: its certificates go to the local
## certificate store, outside the workspace.

import std/os

const
  CtStateDirName* = ".ct"
    ## The directory name. A path component equal to it — not a name ending
    ## in it: ``trace.ct`` is a CTFS container, not this directory.

  CtStateIgnoreFileName* = ".gitignore"

  CtStateIgnoreContent* = """# Written by CodeTracer.
#
# `.ct/` holds CodeTracer's derived workspace state (review datasets,
# recordings), not source. Left unignored it would show up as untracked files
# and change what CodeTracer reports about your work, e.g. a test
# certificate's `untracked` flag.
#
# `*` matches this file too, so nothing here has to be committed for the guard
# to hold.
*
"""

proc enclosingCtStateDir*(path: string): string =
  ## The ``.ct`` directory ``path`` is, or lies inside — the OUTERMOST one,
  ## as an absolute path — or "" when no component of ``path`` is ``.ct``.
  ## Relative paths are resolved against the current directory, which is
  ## what the writer will resolve them against.
  if path.len == 0:
    return ""
  let absolute = absolutePath(path).normalizedPath
  for candidate in parentDirs(absolute, fromRoot = true, inclusive = true):
    if candidate.lastPathPart == CtStateDirName:
      return candidate.parentDir / CtStateDirName
  ""

proc ensureCtStateDirIgnored*(ctDir: string): string =
  ## Create ``ctDir`` if needed and make sure it carries the ignore guard.
  ## Returns "" on success, otherwise why it could not. The file is written
  ## to a temporary name and renamed, so a concurrent writer never sees a
  ## half-written guard; an existing guard is never replaced.
  let guard = ctDir / CtStateIgnoreFileName
  try:
    createDir(ctDir)
    if fileExists(guard):
      return ""
    let temporary = guard & ".tmp-" & $getCurrentProcessId()
    writeFile(temporary, CtStateIgnoreContent)
    if fileExists(guard):
      removeFile(temporary)
    else:
      moveFile(temporary, guard)
    ""
  except CatchableError as e:
    "could not write the git ignore guard '" & guard & "': " & e.msg

proc guardCtStateWrite*(path: string): string =
  ## Call before writing ``path``: when it lies inside a ``.ct`` directory,
  ## that directory is made git-ignored first. Returns "" on success (and for
  ## any path outside ``.ct/``), otherwise the error.
  let ctDir = enclosingCtStateDir(path)
  if ctDir.len == 0:
    return ""
  ensureCtStateDirIgnored(ctDir)
