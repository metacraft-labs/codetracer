## Where the certificate indicator's facts come from.
##
## The ViewModel next door decides what the facts *mean*; this module gathers
## them, and it does so through the **platform facade** rather than through a
## host API. That is what makes the indicator render "in every mode CodeTracer
## runs in" without a `when` anywhere: the Electron renderer, the native
## headless build and a browser tab each install their own instantiation, and
## a platform that cannot do something refuses in a way this module turns into
## an honest *unverifiable* rather than a guess.
##
## ## Read-only, and structurally so
##
## Four facade operations are used — `fs.listDir`, `fs.readText`, `fs.stat`,
## and the VCS reads `repositoryRoot` / `status` / `log`. Nothing here writes,
## creates or removes anything, and `CertificateStoreAccess` (the seam this
## fills in) has no write operation for a future caller to reach through.
##
## ## Why synchronous
##
## `awaitSync` settles the facade's futures for the local instantiations,
## whose work really is synchronous underneath. That keeps the discovery rules
## in `certificate_store.nim` as one synchronous implementation shared by the
## product and by the tests, instead of a promise-shaped copy for each. A
## genuinely remote instantiation does not settle, and the facade's own
## `pkTimeout` outcome then arrives here as a refusal — which becomes
## *unverifiable*, which is the correct answer for "I could not look".

import ../platform/platform
import ../../../ct_test/certificate_store
import certificate_indicator_vm

export certificate_indicator_vm

proc storeReadFor(outcome: PlatformOutcome[string]): StoreRead =
  ## Turn a facade read into the store reader's three-valued result.
  ##
  ## `pkNotFound` is **absence**, which is ordinary; everything else is a
  ## failure this consumer must report rather than absorb. Collapsing the two
  ## would render "no certificates" for a store the platform simply refused to
  ## read, which is the exact collapse Transport.md §4 forbids.
  if outcome.ok:
    return StoreRead(status: srOk, text: outcome.value)
  if outcome.error.kind == pkNotFound:
    return StoreRead(status: srAbsent)
  StoreRead(status: srUnreadable, detail: $outcome.error)

proc platformStoreAccess*(host: Platform): CertificateStoreAccess =
  ## The store reader's filesystem seam, filled in from the facade.
  ##
  ## A platform without `capFilesystemRead` — a browser tab with no project
  ## store open — reports every directory unreadable rather than absent. It has
  ## not established that there are no certificates; it has established that it
  ## cannot look, and those are different sentences.
  ##
  ## ## Every call is wrapped, and that is not defensive decoration
  ##
  ## The facade's contract is that failures are VALUES, and the local
  ## instantiations honour it — but a status bar is the wrong place to find out
  ## that one of them does not. The Electron instantiation's `jsGuard` re-threw
  ## every node exception for its whole life (see that template's own header),
  ## and the first caller to list a directory that might not exist got an
  ## `ENOENT` on `window.onerror` instead of a `pkNotFound` outcome. That is
  ## fixed at the facade, where it belongs; the wrappers here are so that the
  ## NEXT such lapse degrades this indicator to *unverifiable* — an honest "I
  ## could not look" — rather than taking down the renderer's status bar.
  ##
  ## A thrown call is `srUnreadable` and never `srAbsent`: an exception says
  ## nothing about whether the directory is there.
  let canRead = host.can(capFilesystemRead)
  CertificateStoreAccess(
    listFiles: proc(dir: string): StoreListing {.closure.} =
      if not canRead:
        return StoreListing(status: srUnreadable,
          detail: "this platform cannot read the filesystem, so the " &
                  "certificate store could not be listed")
      var entries: PlatformOutcome[seq[FsDirEntry]]
      try:
        entries = awaitSync(host.fs.listDir(dir))
      except CatchableError as err:
        return StoreListing(status: srUnreadable,
          detail: "listing '" & dir & "' raised: " & err.msg)
      except:
        # A BARE ARM, because a typed one catches nothing thrown by a host.
        # Nim's JS backend re-throws anything without an `m_type`, which is
        # every exception `require('fs')` produces.
        return StoreListing(status: srUnreadable,
          detail: "listing '" & dir & "' raised: " & getCurrentExceptionMsg())
      if not entries.ok:
        if entries.error.kind == pkNotFound:
          return StoreListing(status: srAbsent)
        return StoreListing(status: srUnreadable, detail: $entries.error)
      var names: seq[string] = @[]
      for entry in entries.value:
        # `fekSymlink` counts alongside `fekFile`: a store may legitimately
        # symlink a certificate produced elsewhere, and skipping one would
        # report "no certificates" for a store that has some.
        if entry.kind in {fekFile, fekSymlink}:
          names.add entry.name
      StoreListing(status: srOk, names: names)
    ,
    readText: proc(path: string): StoreRead {.closure.} =
      if not canRead:
        return StoreRead(status: srUnreadable,
          detail: "this platform cannot read the filesystem")
      try:
        storeReadFor(awaitSync(host.fs.readText(path)))
      except CatchableError as err:
        StoreRead(status: srUnreadable,
                  detail: "reading '" & path & "' raised: " & err.msg)
      except:
        StoreRead(status: srUnreadable, detail: "reading '" & path &
                  "' raised: " & getCurrentExceptionMsg())
    ,
    modifiedMs: proc(path: string): int64 {.closure.} =
      # `0` is the documented "unknown" value, so a host that throws here costs
      # the ordering its primary key rather than costing the user the whole
      # indicator. The name tiebreak keeps the result deterministic.
      if not canRead:
        return 0'i64
      try:
        let stat = awaitSync(host.fs.stat(path))
        if stat.ok: stat.value.modifiedMs else: 0'i64
      except CatchableError:
        0'i64
      except:
        0'i64
    )

proc standardPlatformTriple*(osName, archName: string): string =
  ## Spell a host's os and arch the way `[certificate].platform` does —
  ## ``os/arch``, e.g. ``linux/amd64`` (Standard.md §3.1).
  ##
  ## Pure, and here rather than in the host, for two reasons. It must be the
  ## SAME spelling `certificate_issuance.currentPlatform` produces on the
  ## producing side, or every certificate CodeTracer issues would read as
  ## belonging to another machine; and the renderer's inputs are node's
  ## ``process.platform`` / ``process.arch``, which use different words for the
  ## same things (``darwin``, ``win32``, ``x64``).
  ##
  ## **An unrecognised name yields ``""``, and that is deliberate.** A
  ## certificate covers exactly the platform that ran the tests, so a consumer
  ## that guessed at its own would be guessing about the one field a green
  ## Linux run says nothing about (Verification.md §5). The empty string
  ## reaches the ViewModel as "the host could not say" and renders
  ## *unverifiable* — which is the honest answer, and the loud one, on a
  ## platform nobody has taught this table about yet.
  let os =
    case osName
    of "linux": "linux"
    of "darwin", "macosx", "macos": "macos"
    of "win32", "windows": "windows"
    of "freebsd": "freebsd"
    of "openbsd": "openbsd"
    of "netbsd": "netbsd"
    else: ""
  let arch =
    case archName
    of "x64", "x86_64", "amd64": "amd64"
    of "arm64", "aarch64": "arm64"
    of "ia32", "i386", "x86": "i386"
    of "arm": "arm"
    of "riscv64": "riscv64"
    else: ""
  if os.len == 0 or arch.len == 0: "" else: os & "/" & arch

proc lastPathSegment(path: string): string =
  ## The repository's own name, as `[certificate.vcs].repo` spells it
  ## (Standard.md §3.2 — the producer writes `repoRoot.lastPathPart`).
  ##
  ## Written out rather than taken from `std/os`, which does not exist on the
  ## JS backend. Trailing separators are stripped first so `/a/b/` and `/a/b`
  ## name the same repository — otherwise a workspace root that happens to
  ## carry one would compare unequal to every certificate ever issued for it.
  var last = path.len - 1
  while last >= 0 and (path[last] == '/' or path[last] == '\\'):
    dec last
  if last < 0:
    return ""
  var start = last
  while start >= 0 and path[start] != '/' and path[start] != '\\':
    dec start
  path[start + 1 .. last]

proc workspaceVcsState*(host: Platform; workspaceDir: string):
    WorkspaceVcsState =
  ## Establish the repository state, or report honestly that it could not be.
  ##
  ## `known = false` is returned for every failure, and never a default. This
  ## mirrors `certificate_issuance.probeVcs` on the producing side, where
  ## Standard.md §3.2 forbids claiming `clean = true` without having checked:
  ## the same rule read from the other end says a consumer that could not
  ## determine cleanliness must not behave as though it had. Here that surfaces
  ## as **unverifiable**, not as "not certified".
  ##
  ## `tree` is deliberately left unknown. A modified-worktree certificate is
  ## matched by canonical content id (Verification.md §4.1.1), and the facade
  ## exposes no operation that computes one — so the indicator says it cannot
  ## tell rather than guessing, and the ViewModel turns that into
  ## *unverifiable*. No shipped producer emits such a record today (CTC-1
  ## defers the modified-worktree form outright), so this costs nothing now and
  ## is honest the day it does not.
  if not host.can(capVcsRead):
    return WorkspaceVcsState(known: false)

  var
    root: PlatformOutcome[string]
    commits: PlatformOutcome[seq[VcsCommit]]
    status: PlatformOutcome[VcsStatus]
  # Wrapped for the reason `platformStoreAccess` is, and with the same verdict:
  # a host that raises has established NOTHING about the repository, which is
  # `known = false` and therefore *unverifiable* — never a default.
  try:
    root = awaitSync(host.vcs.repositoryRoot(workspaceDir))
    if not root.ok or root.value.len == 0:
      return WorkspaceVcsState(known: false)
    commits = awaitSync(host.vcs.log(root.value, 1, ""))
    if not commits.ok or commits.value.len == 0 or commits.value[0].id.len == 0:
      # A repository with no commits yet: there is no commit the tested state
      # could be expressed relative to, so nothing can be established.
      return WorkspaceVcsState(known: false)
    status = awaitSync(host.vcs.status(root.value))
    if not status.ok:
      return WorkspaceVcsState(known: false)
  except CatchableError:
    return WorkspaceVcsState(known: false)
  except:
    return WorkspaceVcsState(known: false)

  result = WorkspaceVcsState(
    known: true,
    repo: lastPathSegment(root.value),
    commit: commits.value[0].id,
    clean: true,
    treeKnown: false,
    tree: "")

  for change in status.value.changes:
    # UNTRACKED AND IGNORED FILES DO NOT MAKE A TREE DIRTY, and the standard
    # says why: `vcs.clean` is about *tracked* files differing from the commit,
    # while untracked files get their own field because they usually mean
    # scratch work (Standard.md §3.2). Counting them here would report every
    # workspace with a build directory as stale forever, which is the fastest
    # way to make an indicator ignored.
    if change.workingTreeStatus in {vfsUntracked, vfsIgnored} and
       change.indexStatus in {vfsUnmodified, vfsUntracked, vfsIgnored}:
      continue
    if change.workingTreeStatus == vfsUnmodified and
       change.indexStatus == vfsUnmodified:
      continue
    result.clean = false
    break

proc platformCertificateFacts*(host: Platform; workspaceDir: string;
                               platformTriple: string;
                               verifier: CertificateSignatureVerifier = nil):
    CertificateIndicatorFacts =
  ## Everything the indicator is a function of, read once.
  ##
  ## `platformTriple` is passed in rather than derived here because it is a
  ## fact about the machine this build is *running* on, and a `nim js` bundle's
  ## compile-time `hostCPU` is a fact about the machine it was *built* on. An
  ## empty string is a supported value meaning "the host could not say", and
  ## the ViewModel reports that as unverifiable — a certificate covers exactly
  ## the platform that ran the tests, and a consumer that did not know its own
  ## would be guessing about the one field a green Linux run says nothing about
  ## (Verification.md §5).
  ##
  ## `verifier` is likewise injected. `nil` — the default, and what the
  ## renderer passes, because a browser has no `ssh-keygen` — means signatures
  ## cannot be checked at all, which is *undecidable* and lands as
  ## unverifiable. It is never silently read as valid.
  CertificateIndicatorFacts(
    store: readCertificateStore(platformStoreAccess(host), workspaceDir),
    vcs: workspaceVcsState(host, workspaceDir),
    platform: platformTriple,
    signatureVerifier: verifier)

proc platformCertificateFactsReader*(host: Platform; workspaceDir: string;
                                     platformTriple: string;
                                     verifier: CertificateSignatureVerifier = nil):
    CertificateFactsReader =
  ## A reader the ViewModel can call again on every refresh trigger.
  ##
  ## Returned as a closure over the *inputs* rather than over a gathered
  ## result, which is the whole of the refresh requirement: every call re-reads
  ## the store and re-asks git, so the indicator cannot go on claiming a
  ## validity it has lost.
  proc(): CertificateIndicatorFacts {.closure.} =
    platformCertificateFacts(host, workspaceDir, platformTriple, verifier)
