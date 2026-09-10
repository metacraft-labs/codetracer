## Where a `ct test` run publishes the certificate it just issued.
##
## CTC-1 issued certificates and wrote them **nowhere** unless
## ``--certificate <path>`` said where, and it recorded the reason as a hazard
## for this milestone rather than as a preference:
##
##   *Certificate placement is a foot-gun for CTC-2. Writing the certificate
##   inside the workspace makes the next run report ``untracked = true``.*
##
## That is the mild form. The severe one is worse and is the one this module
## exists to prevent: if the record ends up **tracked** — a user runs
## ``git add -A`` once, or commits the store on purpose so it travels with the
## repository — then every subsequent run rewrites a tracked file, ``git
## status`` reports it modified, ``probeVcs`` returns ``clean = false``, and
## ``issueCertificate`` withholds with *"commit your changes and run `ct test`
## again"*. Committing the certificate produces a new one, which is modified
## again. The producer's own bookkeeping has made the workspace permanently
## unattestable, and the remedy it prints makes it worse.
##
## The placement, and why it does not dirty the next run
## ----------------------------------------------------
## The record goes to ``<workspace>/.ct/certificates/<platform>.toml`` — the
## directory carrier ``certificate_store.CtTestStoreDir`` already discovers, so
## the status-bar indicator finds it with no second convention — and this module
## first writes ``<workspace>/.ct/.gitignore`` containing ``*``.
##
## ``*`` is what makes the guard **self-sufficient**: it matches every entry
## under ``.ct/`` *including ``.gitignore`` itself*, so `git status
## --porcelain=v1 --untracked-files=normal` reports nothing at all for the
## directory and there is no file the user has to remember to commit for the
## guard to hold. This is the same shape `cargo` writes into ``target/``.
##
## Note what is deliberately **not** done: ``probeVcs`` is not taught to skip
## the store. Filtering the producer's own paths out of `git status` would be a
## second, weaker theory of cleanliness sitting beside git's own, and it would
## be invisible to every other consumer — reprobuild, CI, the user's own
## ``git status``. Making git itself ignore the store keeps exactly one answer
## to "is this tree clean", and it is git's.
##
## What the guard cannot fix, and therefore reports
## ------------------------------------------------
## ``.gitignore`` has no effect on a path that is **already tracked**, so a
## workspace that committed its store before this existed stays in the loop
## described above. That case cannot be repaired from here — un-tracking a file
## is a change to the user's index and not a producer's business — so it is
## *detected* and reported instead: after writing, ``git check-ignore`` is asked
## whether the path it just wrote is ignored, and a "no" becomes a notice in the
## run summary and on stderr naming the remedy. A silent foot-gun becomes a
## loud one.
##
## One record per platform, by name
## --------------------------------
## The file is named after the platform, so a second run on the same machine
## **replaces** its own record instead of accumulating one file per run: the
## store stays bounded without anything having to prune it, and a workspace
## tested on several platforms keeps one record each — which is exactly the
## shape Transport.md §2 describes ("multiple certificates per commit are
## normal, typically one per platform") and which
## ``certificate_verification`` evaluates as a union.
##
## Read-only stays read-only
## -------------------------
## This module writes; ``certificate_store.nim`` reads. They are separate on
## purpose and the dependency runs one way — the writer imports the reader for
## the directory constant, so the published path and the discovered path cannot
## drift apart, and nothing the status-bar indicator imports can reach anything
## here. The indicator's import closure is asserted by name in
## ``certificate_store_test.nim``.
##
## Nothing here signs. It is handed a rendered document by the CLI and puts it
## somewhere; the only route to a signature remains
## ``certificate_issuance.runAndAttest``.

import std/[os, strutils]

import certificate_issuance
import certificate_store

const
  WorkspaceStateDir* = ".ct"
    ## `ct test`'s workspace-local state directory. ``CtTestStoreDir`` lives
    ## inside it, and the ignore guard covers the whole directory rather than
    ## just the store, because everything `ct test` keeps here is derived state
    ## rather than source.

  StoreIgnoreFileName* = ".gitignore"

  StoreIgnoreContent* = """# Written by `ct test`.
#
# The certificate store is workspace-local state, not source. A record inside
# a tracked tree makes the NEXT run's VCS probe report this tree as modified
# or as carrying untracked files, so the producer's own bookkeeping would
# change the answer it reports about your work.
#
# `*` matches this file too, so nothing here has to be committed for the guard
# to hold.
*
"""

  UnknownPlatformFileStem* = "unknown-platform"
    ## Used when ``platform`` sanitises to nothing at all. A producer with no
    ## platform never reaches here — ``currentPlatform()`` always answers — but
    ## a filename derived from an empty string would be ``.toml``, a dotfile
    ## the store's ``.toml`` allow-list would still pick up under a name that
    ## says nothing.

type
  PublishOutcome* = object
    ## What happened when the run tried to publish its certificate.
    ##
    ## Every failure is a **value**, never an exception: publishing is the last
    ## step of a run that already happened, and a store that could not be
    ## written must not change the run's verdict or its exit code.
    path*: string
      ## Workspace-relative path of the record, with ``/`` separators — the
      ## same spelling ``certificate_store`` reports, so the summary and the
      ## indicator name the same file.
    written*: bool
    error*: string
      ## Why the record could not be written. Empty on success.
    ignoreGuardCreated*: bool
      ## Whether this call created ``.ct/.gitignore``. ``false`` when one was
      ## already there — the guard is never overwritten, because a workspace
      ## that wrote its own rules there meant them.
    ignoreGuardError*: string
      ## Why the guard could not be written. Not fatal: the record is still
      ## published, and ``notIgnoredNotice`` is what tells the user what it
      ## costs.
    notIgnoredNotice*: string
      ## Non-empty when git reports the published path is **not** ignored, so
      ## the next run will see it. Empty when it is ignored, and empty when git
      ## could not answer — an unanswered question is not a finding.

proc certificateFileName*(platform: string): string =
  ## The store file name for a platform: ``linux/amd64`` → ``linux-amd64.toml``.
  ##
  ## Every byte outside ``[A-Za-z0-9_-]`` becomes ``-``, which is a whitelist
  ## rather than a "replace the separator" rule on purpose: ``platform`` reaches
  ## here from ``currentPlatform()`` today, but a file name is a filesystem
  ## operation and a value containing ``/``, ``\`` or ``..`` must not be able to
  ## decide where a write lands. ``.`` is excluded from the whitelist for the
  ## same reason, which also makes ``.`` and ``..`` unreachable as stems.
  var stem = ""
  for c in platform:
    case c
    of 'a'..'z', 'A'..'Z', '0'..'9', '_', '-': stem.add c
    else: stem.add '-'
  if stem.strip(chars = {'-'}).len == 0:
    stem = UnknownPlatformFileStem
  stem & ".toml"

proc defaultCertificateRelativePath*(platform: string): string =
  ## Where a run publishes, relative to the workspace root, ``/``-separated.
  CtTestStoreDir & "/" & certificateFileName(platform)

proc defaultCertificatePath*(workspaceRoot, platform: string): string =
  ## The same path on this host's filesystem.
  workspaceRoot / CtTestStoreDir / certificateFileName(platform)

proc ensureStoreIgnored*(workspaceRoot: string):
    tuple[created: bool; error: string] =
  ## Write ``<workspace>/.ct/.gitignore`` if it is not already there.
  ##
  ## Never overwrites: a workspace that put its own rules in that file meant
  ## them, and silently replacing them would be a producer editing a user's
  ## configuration. The trade is stated rather than hidden — a pre-existing
  ## guard that does *not* cover the store is caught after the write by
  ## ``git check-ignore``, which is the check that actually establishes the
  ## property this function is trying to obtain.
  let path = workspaceRoot / WorkspaceStateDir / StoreIgnoreFileName
  if fileExists(path):
    return (false, "")
  try:
    createDir(workspaceRoot / WorkspaceStateDir)
    writeFile(path, StoreIgnoreContent)
    (true, "")
  except CatchableError as err:
    (false, err.msg)

proc ignoreNotice(workspaceRoot, relativePath: string;
                  runner: GitCommandRunner): string =
  ## Ask git whether the path just written is ignored, and say what it costs
  ## when it is not.
  ##
  ## Three outcomes, and only one of them is a finding:
  ##
  ## * exit ``0`` — ignored. The guard holds and the next run sees a clean tree.
  ## * exit ``1`` — **not** ignored, which includes the case the guard cannot
  ##   repair: the path is already tracked. ``.gitignore`` has no effect on a
  ##   tracked path, and `git check-ignore` consults the index by default, so
  ##   this is the one call that can tell the two apart from a plain missing
  ##   rule.
  ## * anything else — git could not answer (not a repository, git absent).
  ##   **No notice**: the producer withholds rather than guesses everywhere else
  ##   in this feature, and warning about a state that was never established
  ##   would send an operator after a fault that may not exist.
  let git = if runner == nil: GitCommandRunner(defaultGitRunner) else: runner
  let checked = git(@["git", "check-ignore", "-q", "--", relativePath],
                    workspaceRoot)
  if checked.exitCode != 1:
    return ""
  "the certificate store at '" & WorkspaceStateDir & "/' is not ignored by " &
  "git, so the record just written will make the next run report this tree " &
  "as modified or as carrying untracked files. Add '" & WorkspaceStateDir &
  "/' to .gitignore — and if '" & relativePath & "' is already tracked, " &
  "`git rm --cached` it first, because .gitignore does not apply to a tracked " &
  "path. Passing --certificate <path> writes the record outside the " &
  "repository instead."

proc publishCertificate*(workspaceRoot, platform, document: string;
                         runner: GitCommandRunner = nil): PublishOutcome =
  ## Put an issued certificate in the workspace store, with the ignore guard in
  ## front of it.
  ##
  ## The guard is written **first**, so a run whose record write fails still
  ## leaves the directory invisible to git rather than leaving a bare, tracked
  ## ``.ct/`` behind.
  ##
  ## ``runner`` reaches git only for the ``check-ignore`` report and is
  ## injectable for the same reason ``probeVcs``'s is: the interesting answers
  ## (git absent, git refusing) cannot be produced against a real repository at
  ## test speed. It decides nothing about the certificate.
  result.path = defaultCertificateRelativePath(platform)

  let guard = ensureStoreIgnored(workspaceRoot)
  result.ignoreGuardCreated = guard.created
  result.ignoreGuardError = guard.error

  try:
    createDir(workspaceRoot / CtTestStoreDir)
    writeFile(defaultCertificatePath(workspaceRoot, platform), document)
    result.written = true
  except CatchableError as err:
    result.error = err.msg
    return

  result.notIgnoredNotice = ignoreNotice(workspaceRoot, result.path, runner)
