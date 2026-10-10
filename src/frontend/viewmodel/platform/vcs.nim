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
##
## ## Content ids: `contentId`
##
## The one read that is not a view of the panel. A test certificate is bound
## to the CONTENT of the tracked files (test-certificates-spec `Content-Id.md`),
## so the status bar's certificate indicator needs three content ids per
## certificate algorithm and scope: the working tree's (W), `HEAD`'s (H) and
## the user's index's (S) — Status-Bar.md, "Requirements". `contentId` answers
## exactly that, for every instantiation, by driving the ONE recipe
## `ct_test/certificate_content_id` implements through each host's own way of
## running git (`contentIdOver` below). No instantiation restates the recipe.

import std/strutils

import ./outcome
import ./capabilities
import ../../../ct_test/certificate_content_id

export outcome
export certificate_content_id.NoContentIdCondition,
       certificate_content_id.NoContentIdState,
       certificate_content_id.ContentIdHost,
       certificate_content_id.ContentAlgorithm

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

  VcsContentIdKind* = enum
    ## What `contentId` established. A FAILURE to establish anything (not a
    ## repository, git exiting non-zero, an invalid scope path) is not one of
    ## these: it is the outcome's error, so no caller can read it as an id.
    vcikComputed
      ## `id` holds the self-describing content id (Content-Id §1).
    vcikNoContentId
      ## The state is one Content-Id §3 says has NO content id — unmerged
      ## entries, an assume-unchanged entry, a skip-worktree entry whose file
      ## is present, a nested repository with modified content. `conditions`
      ## names each one found and its paths. Never an id that silently omits
      ## what the tests read.
    vcikCannotCompute
      ## This host cannot compute the algorithm for this state: an algorithm
      ## it does not implement, `git-tree-sha256` against a SHA-1 repository
      ## (or the reverse), or no git on this platform at all. Content-Id §5:
      ## a verifier reports that as unverifiable, never as a mismatch.

  VcsContentId* = object
    ## The answer of `contentId`.
    kind*: VcsContentIdKind
    id*: string
      ## The full content id, `<algorithm>:<digest>`; empty unless computed.
    algorithm*: string
      ## The algorithm identifier that was asked for, verbatim.
    conditions*: seq[NoContentIdState]
      ## Every Content-Id §3 condition found, when `vcikNoContentId`.
    reason*: string
      ## Empty when computed; otherwise what prevented an id, in words an
      ## operator can act on.

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
    contentId*: proc(repository: string; state: VcsBlobSource;
                     algorithm: string; scope: seq[string]
                    ): PlatformFuture[PlatformOutcome[VcsContentId]]
      ## The content id of one state of the repository containing
      ## `repository`: `vbsWorkingTree` is W (the tracked files as they are,
      ## computed in a temporary index), `vbsHead` is H (`HEAD^{tree}`) and
      ## `vbsIndex` is S (the user's index, via `git write-tree` on a copy).
      ## `algorithm` is the identifier as a content id spells it
      ## (`git-tree-sha1`, `git-tree-sha256`, `manifest-v1-sha256`); one this
      ## host does not implement is `vcikCannotCompute`, not an error. `scope`
      ## is a list of repository-relative paths, empty for the whole
      ## repository (Content-Id §4.1, "Scoped").
      ##
      ## **Requires `capVcsRead`** (`ContentIdRequires`); a host whose profile
      ## lacks it refuses with `pkNotSupported` naming the capability.
      ##
      ## **What it writes.** Computing W or S writes loose, content-addressed
      ## blob and tree objects into the repository's object store
      ## (`.git/objects`) — that is how git computes a tree id — and nothing
      ## else: no ref, no index (the user's index is copied into a temporary
      ## directory outside the repository and only the copy is written) and no
      ## working-tree file. It is classed a READ because what it writes is
      ## unobservable through any ref and is exactly what `git gc` prunes.

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

const
  ContentIdRequires*: CapabilitySet = {capVcsRead}
    ## What `contentId` requires, on every instantiation and at the endpoint
    ## verb `vcs.contentId`. Read, not write: see the field's documentation
    ## for what computing an id writes and why that is not a write in the
    ## facade's sense.

proc contentIdRefusal*(profile: PlatformProfile): PlatformOutcome[VcsContentId] =
  ## The refusal of a host whose profile lacks `ContentIdRequires`, naming
  ## the capability so the caller (and a log) can say what is missing.
  var missing: seq[string]
  for capability in ContentIdRequires - profile.capabilities:
    missing.add $capability
  failed[VcsContentId](pkNotSupported,
    "vcs.contentId requires " & missing.join(", ") & ", which " &
    profile.displayName & " does not grant")

proc cannotComputeContentId*(algorithm, reason: string): VcsContentId =
  VcsContentId(kind: vcikCannotCompute, algorithm: algorithm, reason: reason)

proc contentStateFor(state: VcsBlobSource): ContentState =
  case state
  of vbsWorkingTree: workingTreeState()
  of vbsIndex: indexState()
  of vbsHead: commitState("HEAD")

proc contentIdOver*(host: ContentIdHost; profile: PlatformProfile;
                    repository: string; state: VcsBlobSource;
                    algorithm: string; scope: openArray[string]
                   ): PlatformOutcome[VcsContentId] =
  ## `contentId`, implemented ONCE over the content-id recipe. Every
  ## instantiation that can run git calls this with its own `ContentIdHost`
  ## (`certificate_content_id_native` for a native process,
  ## `host/node_certificate_host` for Electron and the container endpoint), so W, H
  ## and S mean the same thing everywhere.
  if not profile.hasAll(ContentIdRequires):
    return contentIdRefusal(profile)
  let (known, parsedAlgorithm) = lookupAlgorithm(algorithm)
  if not known:
    return succeeded(cannotComputeContentId(algorithm,
      "this host does not implement the content id algorithm `" &
      algorithm & "`"))
  let computed = computeContentId(host, repository, contentStateFor(state),
                                  parsedAlgorithm, scope)
  case computed.outcome
  of cioComputed:
    succeeded(VcsContentId(kind: vcikComputed, id: computed.id,
                           algorithm: algorithm))
  of cioNoContentId:
    succeeded(VcsContentId(kind: vcikNoContentId, algorithm: algorithm,
                           conditions: computed.states,
                           reason: computed.reason))
  of cioCannotCompute:
    succeeded(cannotComputeContentId(algorithm, computed.reason))
  of cioFailed:
    # "No git on this platform" is not a failure of THIS computation but a
    # fact about the host, and Content-Id §5 makes it unverifiable. The
    # recipe cannot tell it from git failing, so it is asked once, only on
    # this path, with no working directory (a missing repository directory
    # must not read as a missing git). Judged by git ANSWERING, not by one
    # host's spelling of "could not launch": node reports a missing program
    # as a spawn error, the native process bridge as exit status 127.
    let probe = host.git(GitCall(argv: @["git", "--version"], cwd: ""))
    if probe.exitCode != 0 or not probe.stdout.startsWith("git version"):
      return succeeded(cannotComputeContentId(algorithm,
        "git cannot be run on this host" &
        (if probe.stderr.strip().len > 0: ": " & probe.stderr.strip() else: "")))
    failed[VcsContentId](pkFailed, computed.reason)

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
    contentId: proc(repository: string; state: VcsBlobSource; algorithm: string;
                    scope: seq[string]): auto =
      # NOT a refusal: a host with no version control cannot compute a content
      # id, which Content-Id §5 reads as unverifiable. A refusal would be an
      # error the indicator had to translate into the same thing.
      resolvedOk(cannotComputeContentId(algorithm,
        profile.displayName & " has no version control, so no content id " &
        "can be computed here")),
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
