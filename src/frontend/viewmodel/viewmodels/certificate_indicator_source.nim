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
## The facade operations used are `fs.listDir`, `fs.readText`, `fs.stat`,
## `fs.certificateStoreRoots`, and the VCS reads `repositoryRoot`,
## `contentId` (W, H and S, SB-2a) and `declaredScopes` (the scopes whose
## scoped ids W, H and S are also looked up by). Nothing here
## writes a file, a ref or the index — computing W writes only loose,
## content-addressed objects into the repository's object store, which is
## what `vcs.contentId` documents — and `CertificateStoreAccess` (the seam
## this fills in) has no write operation for a future caller to reach
## through.
##
## ## Where the records come from
##
## The user's local certificate store (Transport.md §2), both roots, looked up
## by the content ids of W, H and S in every `git-tree-*` algorithm the host
## can compute — whole-repository and in every scope the repository declares
## (Tooling §3.1), since a scoped certificate is filed under its scoped id —
## never enumerated, because it is shared by every repository
## the user works in. Nothing under the working tree is read: neither `ct
## test`'s old workspace store, `.ct/certificates` (CTC-3e), nor reprobuild's
## old `.repro/workspace/certificates`, now that reprobuild publishes to the
## local store too.
## How the indicator then decides between W, H and S is the ViewModel's
## (`evaluateCertificateIndicator`, Status-Bar.md's table).
##
## ## Synchronous and asynchronous, one read
##
## The facts are read by ONE body (`factsPass`), and the discovery rules in
## `certificate_store.nim` stay one synchronous implementation shared by the
## product and the tests. What differs is only how a facade future is
## settled, which a per-refresh `FactsSession` decides:
##
## * `platformCertificateFacts` / `platformCertificateFactsReader` —
##   SYNCHRONOUS, for the native and headless callers (GPUI and the
##   ViewModel suites), whose local instantiations really are synchronous
##   underneath. `awaitSync` settles each future; a genuinely remote
##   instantiation does not settle, and the facade's own `pkTimeout` outcome
##   then arrives as a refusal — *unverifiable*, the correct answer for "I
##   could not look".
## * `gatherCertificateFacts` / `platformCertificateFactsGatherer` —
##   ASYNCHRONOUS, for the Electron renderer, whose `vcs.contentId` and
##   `vcs.repositoryRoot` run git in child processes and answer later. Waiting
##   there was what froze the window for up to 1.2 s on every refresh
##   (Status-Bar.md, "A refresh never stalls the window"). An answer not yet
##   in is recorded as pending and the read runs again when it arrives; only
##   a read with nothing pending is handed over, so a partially gathered set
##   of facts is never displayed. The store reads (`fs.*`) are still settled
##   inline: on the desktop they are local `fs` calls, not the cost that was
##   paid.

import std/strutils

import ../platform/platform
import ../../../ct_test/certificate_content_id
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
  ## name the same repository. The name is informational — it is never
  ## compared with a record's `vcs.repo` (`certificate_indicator_vm`).
  var last = path.len - 1
  while last >= 0 and (path[last] == '/' or path[last] == '\\'):
    dec last
  if last < 0:
    return ""
  var start = last
  while start >= 0 and path[start] != '/' and path[start] != '\\':
    dec start
  path[start + 1 .. last]

type
  FactsSession = ref object
    ## Everything ONE refresh asks the facade about the repository — its root
    ## and every content id — memoised for that refresh only. A refresh
    ## builds a new session, so no answer outlives the facts it was computed
    ## from (the refresh requirement), while within a refresh each id runs
    ## git once however many records and passes ask for it.
    ##
    ## SYNCHRONOUS OR ASYNCHRONOUS, ONE BODY. In a synchronous session
    ## (`platformCertificateFacts`, the native and headless callers) every
    ## facade future is settled with `awaitSync`, exactly as before. In an
    ## asynchronous one (`gatherCertificateFacts`, the Electron renderer) a
    ## future that has not settled is recorded as PENDING, the question is
    ## answered "still being computed" for now, and the pass is marked
    ## incomplete; the gatherer runs the read again once every pending answer
    ## is in. Everything else — which ids are asked, how an answer is read,
    ## what the facts are — is the same code on both paths.
    host: Platform
    asynchronous: bool
    rootAsked: bool
    rootSettled: bool
    root: PlatformOutcome[string]
    scopesAsked: bool
    scopesSettled: bool
    scopes: PlatformOutcome[VcsDeclaredScopes]
      ## The repository's declared certificate scopes (Tooling §3.1), asked
      ## once per session, after the root.
    caches: seq[ContentFactCache]
      ## One per content state, made once the root is known.
    pending: int
      ## Asynchronous only: answers asked for and not yet in. Counted only
      ## for a future that was still unsettled AFTER its drain — an answer
      ## delivered during the drain is simply in, and never decrements.
    incomplete: bool
      ## The current pass read at least one answer that was not in yet, so
      ## the facts it built must not be shown (Status-Bar.md: "a partially
      ## gathered set of facts is never displayed").
    inPass: bool
    waiting: bool
      ## A pass ended incomplete with answers pending: resume when they are in.
    resume: proc() {.closure.}

  CachedContentAnswer = ref object
    ## A ref so the facade's callback can fill in the entry the oracle
    ## already returned, when the answer arrives after the question.
    algorithm: string
    paths: seq[string]
    settled: bool
      ## The answer is in. Until then the oracle says "still being computed".
    answer: ContentAnswer
    conditions: seq[NoContentIdState]
      ## The Content-Id §3 conditions, when the state has no content id.

  ContentFactCache = ref object
    ## One content state (W, H or S) of one repository, within one session.
    ## Memoised per (algorithm, scope) because the verifier asks once per
    ## record per pass and each answer runs git.
    session: FactsSession
    root: string
    source: VcsBlobSource
    entries: seq[CachedContentAnswer]

proc newFactsSession(host: Platform; asynchronous: bool): FactsSession =
  FactsSession(host: host, asynchronous: asynchronous)

proc answerArrived(session: FactsSession) =
  ## A PENDING answer is in. When it was the last one and a pass is waiting
  ## for it, run the read again.
  dec session.pending
  if session.pending == 0 and session.waiting and not session.inPass:
    session.waiting = false
    session.resume()

proc settleThrough[T](session: FactsSession;
                      future: PlatformFuture[PlatformOutcome[T]];
                      deliver: proc(outcome: PlatformOutcome[T])) =
  ## Hand `future`'s outcome to `deliver` — now if it is settled, later if
  ## the session is asynchronous and it is not.
  ##
  ## Synchronous: `awaitSync`, unchanged — an unsettled future becomes its
  ## `pkTimeout` outcome, which the indicator reads as "could not look".
  ##
  ## Asynchronous: subscribe, drain once (which settles anything a local
  ## instantiation already answered, as `awaitSync` does), and only if the
  ## answer is still not in count it pending. The count is taken AFTER the
  ## drain on purpose: a callback that ran inside the drain has delivered,
  ## and decrementing for it would release a waiting pass early.
  if not session.asynchronous:
    deliver(awaitSync(future))
    return
  var arrived = false
  var counted = false
  proc arrive(outcome: PlatformOutcome[T]) =
    if arrived:
      return
    arrived = true
    deliver(outcome)
    if counted:
      counted = false
      session.answerArrived()
  future.onComplete(
    proc(value: PlatformOutcome[T]) = arrive(value),
    proc(message: string) =
      arrive(failed[T](pkTransport, "the platform call failed", message)))
  drainPlatformCallbacks()
  if not arrived:
    counted = true
    inc session.pending
    session.incomplete = true

proc stateName(source: VcsBlobSource): string =
  case source
  of vbsWorkingTree: "the working tree"
  of vbsHead: "HEAD"
  of vbsIndex: "the staged content"

proc record(entry: CachedContentAnswer; name: string;
            outcome: PlatformOutcome[VcsContentId]) =
  ## Read the facade's answer into the entry. Every answer that is not an id
  ## stays "not computed", with the reason.
  if not outcome.ok:
    entry.answer = ContentAnswer(computed: false,
      reason: name & "'s content id could not be computed: " &
              $outcome.error)
  else:
    let id = outcome.value
    case id.kind
    of vcikComputed:
      entry.answer = ContentAnswer(computed: true, id: id.id)
    of vcikNoContentId:
      entry.answer = ContentAnswer(computed: false,
        reason: name & " has no content id: " & id.reason)
      entry.conditions = id.conditions
    of vcikCannotCompute:
      entry.answer = ContentAnswer(computed: false, reason: id.reason)
  entry.settled = true

proc ask(cache: ContentFactCache; algorithm: string;
         paths: seq[string]): CachedContentAnswer =
  ## The facade's `contentId` (SB-2a) for this state.
  ##
  ## Every answer that is not an id stays "not computed", with the reason: an
  ## algorithm this host cannot compute, a state with no content id (each
  ## condition named), a refusal, a failure, or a host that raised. The
  ## verifier reports each as unevaluated — never a match, and never the
  ## reassuring default of some other state's id.
  ##
  ## In an asynchronous session the entry may come back unsettled; asking
  ## for one still unsettled marks the pass incomplete, so it is never
  ## shown.
  for entry in cache.entries:
    if entry.algorithm == algorithm and entry.paths == paths:
      if not entry.settled:
        cache.session.incomplete = true
      return entry
  let entry = CachedContentAnswer(algorithm: algorithm, paths: paths)
  cache.entries.add entry
  let name = stateName(cache.source)
  try:
    cache.session.settleThrough(
      cache.session.host.vcs.contentId(cache.root, cache.source, algorithm,
                                       paths),
      proc(outcome: PlatformOutcome[VcsContentId]) =
        entry.record(name, outcome))
  except CatchableError as err:
    entry.answer = ContentAnswer(computed: false,
      reason: "computing " & name & "'s content id raised: " & err.msg)
    entry.settled = true
  except:
    entry.answer = ContentAnswer(computed: false,
      reason: "computing " & name & "'s content id raised: " &
              getCurrentExceptionMsg())
    entry.settled = true
  entry

proc oracle(cache: ContentFactCache): ContentOracle =
  let name = stateName(cache.source)
  result = proc(algorithm: string; paths: seq[string]): ContentAnswer
      {.closure.} =
    let entry = cache.ask(algorithm, paths)
    if entry.settled:
      entry.answer
    else:
      # Only ever read by a pass that is then discarded (`incomplete`).
      ContentAnswer(computed: false,
                    reason: name & "'s content id is still being computed")

proc cacheFor(session: FactsSession; root: string;
              source: VcsBlobSource): ContentFactCache =
  for cache in session.caches:
    if cache.source == source and cache.root == root:
      return cache
  result = ContentFactCache(session: session, root: root, source: source)
  session.caches.add result

proc repositoryRootOf(session: FactsSession; workspaceDir: string):
    tuple[known: bool; root: string] =
  ## The repository containing `workspaceDir`, asked once per session.
  ##
  ## Wrapped for the reason `platformStoreAccess` is, and with the same
  ## verdict: a host that raises has established NOTHING about the
  ## repository, which is `known = false` and therefore *unverifiable* —
  ## never a default.
  if not session.rootAsked:
    session.rootAsked = true
    try:
      session.settleThrough(session.host.vcs.repositoryRoot(workspaceDir),
        proc(outcome: PlatformOutcome[string]) =
          session.root = outcome
          session.rootSettled = true)
    except CatchableError as err:
      session.root = failed[string](pkFailed, "the repository root raised",
                                    err.msg)
      session.rootSettled = true
    except:
      session.root = failed[string](pkFailed, "the repository root raised",
                                    getCurrentExceptionMsg())
      session.rootSettled = true
  elif not session.rootSettled:
    session.incomplete = true
  if not session.rootSettled or not session.root.ok or
     session.root.value.len == 0:
    return (false, "")
  (true, session.root.value)

proc declaredScopesOf(session: FactsSession; root: string):
    tuple[scopes: seq[seq[string]]; problem: string] =
  ## The scopes `root` declares (the facade's `declaredScopes`), asked once
  ## per session. A problem — the declaration could not be read, is invalid,
  ## or the host raised — comes back as words, and the caller makes the
  ## search incomplete with them: scoped certificates could then not be
  ## looked up. An answer still pending (asynchronous session) is neither:
  ## the pass is incomplete and will be read again.
  if not session.scopesAsked:
    session.scopesAsked = true
    try:
      session.settleThrough(session.host.vcs.declaredScopes(root),
        proc(outcome: PlatformOutcome[VcsDeclaredScopes]) =
          session.scopes = outcome
          session.scopesSettled = true)
    except CatchableError as err:
      session.scopes = failed[VcsDeclaredScopes](pkFailed,
        "reading the declared certificate scopes raised", err.msg)
      session.scopesSettled = true
    except:
      session.scopes = failed[VcsDeclaredScopes](pkFailed,
        "reading the declared certificate scopes raised",
        getCurrentExceptionMsg())
      session.scopesSettled = true
  elif not session.scopesSettled:
    session.incomplete = true
  if not session.scopesSettled:
    return (@[], "")
  if not session.scopes.ok:
    return (@[], $session.scopes.error)
  if session.scopes.value.problems.len > 0:
    return (@[], "the declaration is invalid: " &
                 session.scopes.value.problems.join("; "))
  (session.scopes.value.scopes, "")

const LocalStoreAlgorithms = ["git-tree-sha1", "git-tree-sha256"]
  ## The tree algorithms a repository computes one of; the host answers
  ## "cannot compute" for the other, cheaply.

proc describeConditions*(conditions: seq[NoContentIdState]): string =
  ## Each Content-Id §3 condition with its paths, as a user reads it.
  var parts: seq[string] = @[]
  for state in conditions:
    parts.add $state.condition & " (" & state.paths.join(", ") & ")"
  parts.join("; ")

proc noContentIdRemedy*(conditions: seq[NoContentIdState]): string =
  ## How to clear each Content-Id §3 condition present (Status-Bar.md:
  ## "naming the condition and its remedy"), in the order the producer
  ## names them — an unmerged index first, because resolving a merge can
  ## change what the others report. The same remedies `ct test` gives when it
  ## withholds a certificate for such a tree (`certificate_issuance`); running
  ## the tests is not one of them, because a producer refuses this tree too.
  proc pathsOf(wanted: set[NoContentIdCondition]): seq[string] =
    for state in conditions:
      if state.condition in wanted:
        result.add state.paths
  var steps: seq[string] = @[]
  let unmerged = pathsOf({ncUnmergedEntries})
  if unmerged.len > 0:
    steps.add "Resolve the merge: edit " & unmerged.join(", ") &
      " to the content you mean and `git add` it, or abandon the merge " &
      "(`git merge --abort`)."
  let assumed = pathsOf({ncAssumeUnchanged})
  if assumed.len > 0:
    steps.add "Clear the flag: `git update-index --no-assume-unchanged -- " &
      assumed.join(" ") & "`."
  let skipped = pathsOf({ncSkipWorktreePresent})
  if skipped.len > 0:
    steps.add "Clear the flag: `git update-index --no-skip-worktree -- " &
      skipped.join(" ") & "`."
  let submodules = pathsOf({ncSubmoduleModified})
  if submodules.len > 0:
    steps.add "Commit or revert the changes inside the submodule " &
      submodules.join(", ") & " — a submodule is recorded by its checked-out " &
      "commit alone."
  let unrepresentable = pathsOf({ncUnrepresentablePath})
  if unrepresentable.len > 0:
    steps.add "Rename " & unrepresentable.join(", ") &
      " so the path can be represented."
  steps.join(" ")

proc sessionVcsState(session: FactsSession; workspaceDir: string):
    WorkspaceVcsState =
  ## `workspaceVcsState` within a session (see there).
  if not session.host.can(capVcsRead):
    return WorkspaceVcsState(known: false)
  let (known, root) = session.repositoryRootOf(workspaceDir)
  if not known:
    # Also the answer while the root is still pending in an asynchronous
    # session — a pass that is then discarded, never shown.
    return WorkspaceVcsState(known: false)
  let w = session.cacheFor(root, vbsWorkingTree)
  result = WorkspaceVcsState(
    known: true,
    # The repository root's directory name -- the same source the producer
    # uses for `vcs.repo` (`certificate_issuance.probeVcs`: the toplevel's
    # last path part). Informational: requiring the two to match would be
    # this consumer's choice (Verification.md §4.1), and it chooses not to —
    # content alone binds, so a clone under another directory name shares
    # certificates (`certificate_verification.verifyCertificates`).
    repo: lastPathSegment(root),
    repositoryRoot: root,
    workingTree: w.oracle,
    head: session.cacheFor(root, vbsHead).oracle,
    index: session.cacheFor(root, vbsIndex).oracle)
  for algorithm in LocalStoreAlgorithms:
    let asked = w.ask(algorithm, @[])
    if asked.conditions.len > 0:
      result.workingTreeProblem = describeConditions(asked.conditions)
      result.workingTreeRemedy = noContentIdRemedy(asked.conditions)
      break
  let declared = session.declaredScopesOf(root)
  result.declaredScopes = declared.scopes
  result.declaredScopesProblem = declared.problem

proc workspaceVcsState*(host: Platform; workspaceDir: string):
    WorkspaceVcsState =
  ## Establish the repository and its three content facts, or report honestly
  ## that it could not be. Synchronous: every facade answer is settled with
  ## `awaitSync` (see the module header).
  ##
  ## `known = false` is returned for every failure, and never a default. This
  ## mirrors `certificate_issuance.probeVcs` on the producing side: a consumer
  ## that could not establish the repository must not behave as though it
  ## had. Here that surfaces as **unverifiable**, not as "not certified".
  ##
  ## W, H and S are computed on demand, in the algorithm and over the scope
  ## of each record (Verification.md §4.1.1). No commit is read, because none
  ## is compared — a repository with no commits yet has a perfectly good W.
  ## The one thing computed up front is whether W has a content id at all,
  ## asked whole-repository in each tree algorithm: a Content-Id §3 state is
  ## a property of the tree, not of a record, and it is reported by name.
  sessionVcsState(newFactsSession(host, asynchronous = false), workspaceDir)

proc storeRoots(host: Platform): CertificateStoreRoots =
  ## The local store's roots as this host resolves them (SB-2a's facade
  ## operation). A host that cannot say has no local store as far as this
  ## read is concerned, which the reader reports as "could not look".
  try:
    let outcome = awaitSync(host.fs.certificateStoreRoots())
    if outcome.ok:
      return outcome.value
    noLocalStore("the local certificate store's roots could not be " &
                 "resolved: " & $outcome.error)
  except CatchableError as err:
    noLocalStore("resolving the local certificate store raised: " & err.msg)
  except:
    noLocalStore("resolving the local certificate store raised: " &
                 getCurrentExceptionMsg())

proc localStoreQuery*(host: Platform; workspaceDir: string;
                      vcs: WorkspaceVcsState): LocalStoreQuery =
  ## Which content directories of the local store to read: W's, H's and S's
  ## (Status-Bar.md: "every record found for the content ids of W, H and S"),
  ## whole-repository, in each tree algorithm the host can compute here —
  ## through the SAME memoised oracles the verifier then uses, so a refresh
  ## computes each id once. A state with no content id contributes no
  ## directory. No repository, no lookup. The store is never enumerated: it
  ## is shared by every repository the user works in.
  result.roots = storeRoots(host)
  if not vcs.known:
    return
  # Whole-repository first, then every scope the repository declares
  # (Tooling §3.1): a scoped certificate is filed under its scoped content
  # id (Transport §2.2), so it is found only by asking for that id. The
  # verifier then reads each record against the same memoised oracles, in
  # the record's own scope.
  var scopes: seq[seq[string]] = @[@[]]
  scopes.add vcs.declaredScopes
  for state in [vcs.workingTree, vcs.head, vcs.index]:
    if state.isNil:
      continue
    for scope in scopes:
      for algorithm in LocalStoreAlgorithms:
        let answer = state(algorithm, scope)
        if answer.computed and answer.id notin result.contentIds:
          result.contentIds.add answer.id

proc factsPass(session: FactsSession; workspaceDir: string;
               platformTriple: string;
               verifier: CertificateSignatureVerifier):
    CertificateIndicatorFacts =
  ## One read of everything the indicator is a function of, through
  ## `session`'s memoised answers. The body of both the synchronous reader
  ## and every pass of the asynchronous gatherer.
  let vcs = sessionVcsState(session, workspaceDir)
  let host = session.host
  let query = localStoreQuery(host, workspaceDir, vcs)
  var store = readCertificateStore(platformStoreAccess(host), query)
  if vcs.known and vcs.declaredScopesProblem.len > 0 and
     query.roots.available:
    # The scoped certificates could not be looked up: their ids depend on
    # the scopes, and the scopes could not be established. Nothing found is
    # then not evidence that nothing exists — the same reasoning as a root
    # that could not be searched (Transport §2.1, §5).
    store.present = true
    store.incomplete = true
    store.incompleteReasons.add "the repository's declared certificate " &
      "scopes (testCertificatesScope) could not be read, so scoped " &
      "certificates were not looked up: " & vcs.declaredScopesProblem
  if not query.roots.available and not store.unreadable:
    # A HOST WITH NO LOCAL STORE (a browser tab) has not looked, and "no
    # certificates" would claim it had (SB-2b: the web host reads
    # unverifiable). The reader only reaches this when a content id is looked
    # up, and a host with no version control has none to look up.
    store.unreadable = true
    store.unreadableReason = "this host has no local certificate store, so " &
      "it cannot look for certificates" &
      (if query.roots.problems.len > 0: ": " & query.roots.problems.join("; ")
       else: "")
  CertificateIndicatorFacts(
    store: store,
    vcs: vcs,
    platform: platformTriple,
    signatureVerifier: verifier)

proc platformCertificateFacts*(host: Platform; workspaceDir: string;
                               platformTriple: string;
                               verifier: CertificateSignatureVerifier = nil):
    CertificateIndicatorFacts =
  ## Everything the indicator is a function of, read once, synchronously.
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
  factsPass(newFactsSession(host, asynchronous = false), workspaceDir,
            platformTriple, verifier)

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

proc gatherCertificateFacts*(host: Platform; workspaceDir: string;
                             platformTriple: string;
                             verifier: CertificateSignatureVerifier;
                             done: proc(facts: CertificateIndicatorFacts)) =
  ## The facts `platformCertificateFacts` reads, gathered WITHOUT waiting for
  ## the facade: `done` is called once, when every answer the facts depend on
  ## is in — on a later turn of the event loop when the host answers later
  ## (the Electron renderer's git), before this returns when it answers at
  ## once (Status-Bar.md, "A refresh never stalls the window").
  ##
  ## ## Passes until nothing is pending
  ##
  ## Which content ids are needed is not known up front: the root comes
  ## first, then W, H and S whole-repository (which name the store
  ## directories to read), then — once the store has been read — each
  ## record's own algorithm and scope. So the read runs as passes over one
  ## session. A pass runs the whole read (store reads included, so a record
  ## that landed meanwhile is seen) AND the decision
  ## (`evaluateCertificateIndicator`), because the decision is what asks for
  ## a record's scoped id; an answer not yet in is "still being computed"
  ## and marks the pass incomplete. When every pending answer is in, the next
  ## pass runs. The first pass that reads nothing still being computed is
  ## handed to `done`: a partially gathered set of facts is never handed
  ## over, because a fact still being computed would read as *unverifiable*.
  ##
  ## It terminates because each pass either asks for nothing new (and then
  ## completes once its answers are in) or asks for content ids of a finite
  ## set — the root's states, in the algorithms and scopes of the records in
  ## the store — each asked once per session. The facts handed over keep
  ## their session: the ViewModel's own evaluation then reads only answers
  ## that are in.
  ##
  ## A pass that RAISES ends the gathering with facts that read
  ## *unverifiable* ("could not look"), so a refresh is never left waiting
  ## forever on an answer that will not come.
  let session = newFactsSession(host, asynchronous = true)
  var finished = false
  session.resume = proc() =
    while not finished:
      session.incomplete = false
      session.inPass = true
      var facts: CertificateIndicatorFacts
      var raised = ""
      try:
        facts = factsPass(session, workspaceDir, platformTriple, verifier)
        # Touch every oracle the decision consults; the model is discarded,
        # the ViewModel computes its own from the facts handed over.
        discard evaluateCertificateIndicator(facts)
      except CatchableError as err:
        raised = err.msg
      except:
        raised = getCurrentExceptionMsg()
      session.inPass = false
      if raised.len > 0:
        finished = true
        done(CertificateIndicatorFacts(
          store: CertificateStore(unreadable: true,
            unreadableReason: "gathering the certificate facts raised: " &
                              raised),
          vcs: WorkspaceVcsState(known: false),
          platform: platformTriple,
          signatureVerifier: verifier))
        return
      if not session.incomplete:
        finished = true
        done(facts)
        return
      if session.pending > 0:
        session.waiting = true      # `answerArrived` resumes
        return
      # Incomplete with nothing pending: an answer arrived DURING the pass
      # (a native drain delivers other futures' callbacks), after the pass
      # had read it as still being computed. Read again now.
  session.resume()

proc platformCertificateFactsGatherer*(host: Platform; workspaceDir: string;
                                       platformTriple: string;
                                       verifier: CertificateSignatureVerifier = nil):
    CertificateFactsGatherer =
  ## `platformCertificateFactsReader`'s asynchronous counterpart, for a
  ## ViewModel built with `newCertificateIndicatorVmWith`: every call gathers
  ## afresh, in a new session, so nothing outlives the refresh it answered.
  proc(done: proc(facts: CertificateIndicatorFacts)) {.closure.} =
    gatherCertificateFacts(host, workspaceDir, platformTriple, verifier, done)
