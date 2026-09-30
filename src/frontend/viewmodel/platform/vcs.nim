## The version-control facade.
##
## Desktop: system git. Web: the same VCS layer over the project store
## (Noir-Studio.md §6.2a). Container: system git in the container.
##
## ## Why this is not "run a git command"
##
## `ui/git_cli.nim` today is a thin `execFileSync('git', argv)` wrapper, and
## everything above it composes git argv. That works on exactly one of the
## three platforms. Noir-Studio.md §3.2 makes the point sharply: "the panel
## exists, the engine does not" — the VCS panel's data sources are a git binary
## and an Electron file watcher, neither of which a tab has.
##
## So the facade is stated in terms of *what the panel needs to show*, not in
## terms of git's command line. Each operation is one the web instantiation can
## implement against a real git object store without pretending to have a
## shell, and one the desktop instantiation implements by running git — which
## it can, because these are all things git does.
##
## ## The read/write/remote split is the capability split
##
## `capVcsRead`, `capVcsWrite` and `capVcsRemote` are separate because they fail
## separately. A browser can read and write a local object store all day; it
## cannot fetch from a host that does not send CORS headers (§6.2a). A UI that
## treats "has git" as one bit shows a Push button that cannot work.

import std/strutils

import ./outcome
import ./capabilities

export outcome

type
  VcsFileStatus* = enum
    vfsUnmodified
    vfsModified
    vfsAdded
    vfsDeleted
    vfsRenamed
    vfsCopied
    vfsUntracked
    vfsIgnored
    vfsConflicted

  VcsFileChange* = object
    path*: string
      ## Repository-relative, always `/`-separated. An absolute path here would
      ## be meaningless to a container client and unrepresentable on the web.
    previousPath*: string
      ## Set for renames and copies.
    indexStatus*: VcsFileStatus
    workingTreeStatus*: VcsFileStatus

  VcsStatus* = object
    branch*: string
    upstream*: string
    ahead*: int
    behind*: int
    detached*: bool
    changes*: seq[VcsFileChange]

  VcsCommit* = object
    id*: string
    shortId*: string
    parents*: seq[string]
    authorName*: string
    authorEmail*: string
    authoredAtMs*: int64
    subject*: string
    body*: string

  VcsBlobSource* = enum
    ## Which of the three copies of a file a caller wants. Spelled as an enum
    ## rather than as a revision string because these three are what a diff
    ## view asks for, and every instantiation can answer all three; an
    ## arbitrary revspec is `readBlobAt`, which is a separate, weaker promise.
    vbsWorkingTree
    vbsIndex
    vbsHead

  VcsFacade* {.requiresInit.} = ref object
    ## `{.requiresInit.}` for the reason spelled out on `FileSystemFacade` in
    ## `fs.nim`: without it, an unassigned field is `nil` rather than a compile
    ## error, and an operation that only makes sense in-process could be added
    ## without `host/container_platform.nim` noticing.
    profile*: PlatformProfile

    # -- read (capVcsRead) --------------------------------------------------
    isRepository*: proc(path: string): PlatformFuture[PlatformOutcome[bool]]
    repositoryRoot*: proc(path: string): PlatformFuture[PlatformOutcome[string]]
    status*: proc(repository: string): PlatformFuture[PlatformOutcome[VcsStatus]]
    log*: proc(repository: string; maxCount: int;
               path: string): PlatformFuture[PlatformOutcome[seq[VcsCommit]]]
    readBlob*: proc(repository, path: string;
                    source: VcsBlobSource): PlatformFuture[PlatformOutcome[string]]
    readBlobAt*: proc(repository, path,
                      revision: string): PlatformFuture[PlatformOutcome[string]]
    diff*: proc(repository: string; paths: seq[string];
                staged: bool; contextLines: int
               ): PlatformFuture[PlatformOutcome[string]]
      ## Unified diff text. Deliberately text rather than a parsed structure:
      ## `ui/unified_diff.nim` already owns the parser and it is pure, so
      ## keeping the boundary at the wire format means the parser is shared by
      ## all three instantiations instead of reimplemented per platform.

    # -- write (capVcsWrite) ------------------------------------------------
    stage*: proc(repository: string;
                 paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]]
    unstage*: proc(repository: string;
                   paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]]
    discardChanges*: proc(repository: string;
                          paths: seq[string]): PlatformFuture[PlatformOutcome[Nothing]]
    applyPatch*: proc(repository, patch: string;
                      reverse: bool): PlatformFuture[PlatformOutcome[Nothing]]
    commit*: proc(repository, message, authorName, authorEmail: string
                 ): PlatformFuture[PlatformOutcome[VcsCommit]]
    initRepository*: proc(path: string): PlatformFuture[PlatformOutcome[Nothing]]

    # -- remote (capVcsRemote) ----------------------------------------------
    fetch*: proc(repository, remote: string): PlatformFuture[PlatformOutcome[Nothing]]
    push*: proc(repository, remote,
                refspec: string): PlatformFuture[PlatformOutcome[Nothing]]

func porcelainCode(c: char): VcsFileStatus =
  case c
  of 'M': vfsModified
  of 'A': vfsAdded
  of 'D': vfsDeleted
  of 'R': vfsRenamed
  of 'C': vfsCopied
  of 'U': vfsConflicted
  else: vfsUnmodified

func parsePorcelainV2*(text: string): VcsStatus =
  ## `git status --porcelain=v2 --branch`, read.
  ##
  ## ONE READER, TWO CALLERS: the native instantiation's `status` (below the
  ## facade, `host/desktop_native.nim`) and the desktop's VCS panel
  ## (`ui/vcs.nim`, which still runs git through the process facade) read the
  ## same output through this, so the terminal's VCS pane, GPUI's and the
  ## desktop's cannot disagree about a file's state (PLAT-47 deliverable 4).
  ## Pure and backend-neutral, so it compiles on both.
  ##
  ## Lines (https://git-scm.com/docs/git-status#_porcelain_format_version_2):
  ## `# branch.head <name>`, `# branch.upstream <ref>`, `# branch.ab +A -B`,
  ## `1 XY ... <path>` (ordinary), `2 XY ... <path>\t<orig>` (renamed or
  ## copied), `u XY ...` (unmerged) and `? <path>` (untracked).
  for line in text.splitLines():
    if line.len == 0: continue
    if line.startsWith("# branch.head "):
      result.branch = line[14 .. ^1]
      result.detached = result.branch == "(detached)"
    elif line.startsWith("# branch.upstream "):
      result.upstream = line[18 .. ^1]
    elif line.startsWith("# branch.ab "):
      let parts = line[12 .. ^1].split(' ')
      if parts.len == 2:
        try:
          result.ahead = parseInt(parts[0].strip(chars = {'+'}))
          result.behind = parseInt(parts[1].strip(chars = {'-'}))
        except ValueError:
          discard
    elif line.startsWith("? "):
      result.changes.add VcsFileChange(
        path: line[2 .. ^1], workingTreeStatus: vfsUntracked,
        indexStatus: vfsUnmodified)
    elif line.startsWith("1 ") or line.startsWith("2 "):
      # `1 XY sub mH mI mW hH hI <path>` / `2 XY sub mH mI mW hH hI Xs
      # <path><TAB><origPath>`: a fixed number of space-separated fields,
      # then the path, which may itself contain spaces.
      let parts = line.split(' ', maxsplit = if line[0] == '1': 8 else: 9)
      if parts.len >= 9:
        let xy = parts[1]
        var path = parts[^1]
        var previous = ""
        let tab = path.find('\t')
        if tab >= 0:
          previous = path[tab + 1 .. ^1]
          path = path[0 ..< tab]
        result.changes.add VcsFileChange(
          path: path, previousPath: previous,
          indexStatus: porcelainCode(xy[0]),
          workingTreeStatus: porcelainCode(xy[1]))
    elif line.startsWith("u "):
      # `u XY sub m1 m2 m3 mW h1 h2 h3 <path>`.
      let parts = line.split(' ', maxsplit = 10)
      if parts.len == 11:
        result.changes.add VcsFileChange(
          path: parts[^1], indexStatus: vfsConflicted,
          workingTreeStatus: vfsConflicted)

proc unavailableVcs*(profile: PlatformProfile): VcsFacade =
  VcsFacade(
    profile: profile,
    isRepository: proc(path: string): auto = resolvedUnsupported[bool]("version control"),
    repositoryRoot: proc(path: string): auto = resolvedUnsupported[string]("version control"),
    status: proc(repository: string): auto = resolvedUnsupported[VcsStatus]("version control"),
    log: proc(repository: string; maxCount: int; path: string): auto =
      resolvedUnsupported[seq[VcsCommit]]("version control"),
    readBlob: proc(repository, path: string; source: VcsBlobSource): auto =
      resolvedUnsupported[string]("version control"),
    readBlobAt: proc(repository, path, revision: string): auto =
      resolvedUnsupported[string]("version control"),
    diff: proc(repository: string; paths: seq[string]; staged: bool;
               contextLines: int): auto = resolvedUnsupported[string]("version control"),
    stage: proc(repository: string; paths: seq[string]): auto =
      resolvedUnsupported[Nothing]("staging changes"),
    unstage: proc(repository: string; paths: seq[string]): auto =
      resolvedUnsupported[Nothing]("staging changes"),
    discardChanges: proc(repository: string; paths: seq[string]): auto =
      resolvedUnsupported[Nothing]("discarding changes"),
    applyPatch: proc(repository, patch: string; reverse: bool): auto =
      resolvedUnsupported[Nothing]("applying patches"),
    commit: proc(repository, message, authorName, authorEmail: string): auto =
      resolvedUnsupported[VcsCommit]("committing"),
    initRepository: proc(path: string): auto =
      resolvedUnsupported[Nothing]("creating repositories"),
    fetch: proc(repository, remote: string): auto =
      resolvedUnsupported[Nothing]("fetching from a remote"),
    push: proc(repository, remote, refspec: string): auto =
      resolvedUnsupported[Nothing]("pushing to a remote"))
