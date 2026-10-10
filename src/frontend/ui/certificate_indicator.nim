## Wiring the status bar's test-certificate indicator into the running app.
##
## The decisions live in `viewmodel/viewmodels/certificate_indicator_vm.nim`
## and the fact-gathering in `certificate_indicator_source.nim`; this module is
## only the part that has to know it is inside CodeTracer — which workspace is
## open, which platform this process is on, and when to look again.
##
## ## Read-only, in the strongest sense available
##
## Everything below goes through `FileSystemFacade`'s read operations and
## `VcsFacade`'s read operations. Nothing here writes, and nothing here can
## reach `certificate_issuance.runAndAttest`, which is the only route to a
## signature in CodeTracer (Standard.md §6.2). `src/ct_test/certificate_store_test.nim`
## asserts that as a property of the import graph rather than leaving it to
## this comment.
##
## ## What refreshes it, and what — honestly — does not
##
## | trigger | wired by |
## |---|---|
## | first render | `ensureCertificateIndicator` |
## | a commit, checkout, rebase, merge, stage, `git checkout -- <file>` | a watch on `<repo>/.git` |
## | a certificate arriving, being replaced or removed | a watch on each store directory |
## | the store directory appearing for the first time, or a root-level edit | a watch on the workspace root, not recursive |
## | the user selecting the indicator | `selectCertificateIndicator` |
## | anything else, every `RevalidateIntervalMs` | a `setInterval` |
##
## The `.git` watch is not recursive, and it does not need to be: `HEAD`,
## `index`, `ORIG_HEAD` and `MERGE_HEAD` all sit directly in that directory, and
## every operation in the second row above rewrites at least one of them.
##
## **THE PERIODIC ARM IS A TIMER, NOT A RENDER HOOK, AND THAT CORRECTION CAME
## FROM WATCHING THE PRODUCT.** It was first written as "revalidate at most once
## every `RevalidateIntervalMs`, after a render pass", which reads sensibly and
## is inert: an idle CodeTracer does not render, so the backstop never fired.
## Observed rather than reasoned about — a certificate written into the store of
## a running app left the indicator's label unchanged for the whole wait, and
## only selecting it moved the answer. A timer fires whether or not anything is
## drawing, which is what "refresh when the underlying facts change" needs.
##
## **A bare edit to a tracked file DEEP in the tree touches nothing in `.git`
## and nothing at the workspace root.** A recursive watch would catch it and
## would also fire on every build artefact in a large tree, which is a cost this
## indicator does not earn — so that case is the timer's, and the consequence is
## stated rather than hidden: after a deep external edit the indicator can be up
## to `RevalidateIntervalMs` stale. It is never stale at the moment a user asks
## it a question, because selecting it re-reads first.

import ../viewmodel/viewmodels/certificate_indicator_source
import ../viewmodel/views/status_certificate_projection

# `statusCertificateModel` and `certificateTooltip` live in
# `viewmodel/views/status_certificate_projection.nim`, one layer down, so the
# headless view suite can assert what a user would see without importing this
# module — which reaches a host. Re-exported here so `ui/status.nim` has one
# import for the whole indicator.
export certificate_indicator_source, status_certificate_projection

when defined(js):
  from ../platform_host import
    ctPlatform, ctAwaitSync, Platform, can, capFilesystemWatch, FsWatchEvent, fs

  # `process.platform` / `process.arch` are node's names for this machine, read
  # AT RUN TIME. `hostOS` / `hostCPU` would be the machine that COMPILED the
  # bundle, which is a different fact and a wrong one for any build a user
  # downloaded. The guard is `typeof process` because a browser tab has none,
  # and the empty string it yields is a supported value meaning "the host could
  # not say" — which renders as *unverifiable*, not as a guess.
  proc nodePlatformName(): cstring =
    {.emit: "`result` = (typeof process === 'undefined') ? '' : process.platform;".}

  proc nodeArchName(): cstring =
    {.emit: "`result` = (typeof process === 'undefined') ? '' : process.arch;".}

  proc setRepeating(callback: proc(); intervalMs: int): void
    {.importjs: "setInterval(#, #)", discardable.}

  const RevalidateIntervalMs* = 15000
    ## How often the backstop looks again. Fifteen seconds is chosen against
    ## what a revalidation COSTS — one `git status` and two directory listings —
    ## rather than against how fresh a fact could be: the precise triggers above
    ## carry the cases that matter, and this is the backstop for the one they
    ## cannot see.

  var
    indicator: CertificateIndicatorVm = nil
    indicatorWorkspace = ""
    timerInstalled = false
      ## The backstop timer is installed ONCE for the life of the renderer and
      ## reads whatever indicator is current. Re-installing it per workspace
      ## would leave the old one running — `clearInterval` needs a handle this
      ## module would then have to keep correct across every early return, and
      ## a leaked timer that fires a `git status` forever is a worse failure
      ## than the one it would be guarding against.
    onIndicatorChanged: proc() = nil

  proc currentHostPlatform*(): string =
    ## This machine, spelled the way `[certificate].platform` spells it.
    standardPlatformTriple($nodePlatformName(), $nodeArchName())

  proc certificateIndicator*(): CertificateIndicatorVm =
    ## The indicator, or `nil` before `ensureCertificateIndicator` has run.
    indicator

  proc revalidateCertificateIndicator() =
    ## The backstop, on its own timer. Runs whether or not anything is drawing,
    ## which is the correction the product's own behaviour forced — see the
    ## module header.
    if indicator.isNil:
      return
    if indicator.refresh(citWorktreeChanged) and not onIndicatorChanged.isNil:
      onIndicatorChanged()

  proc watchDirectory(host: Platform; path: string;
                      trigger: CertificateIndicatorTrigger) =
    ## Ask the platform to tell us when `path` changes. A refusal is ignored on
    ## purpose: a missing store directory has nothing to watch yet, and a
    ## platform without `capFilesystemWatch` still has the throttled
    ## revalidation and the on-demand refresh. Failing loudly here would turn a
    ## degraded refresh into a broken status bar.
    discard host.fs.watch(path, false, proc(event: FsWatchEvent) =
      if indicator.isNil:
        return
      if indicator.refresh(trigger) and not onIndicatorChanged.isNil:
        onIndicatorChanged())

  proc ensureCertificateIndicator*(workspaceDir: string;
                                   onChanged: proc()) =
    ## Create the indicator for `workspaceDir`, or keep the existing one.
    ##
    ## Idempotent, because the status bar calls it on every render pass and a
    ## fresh ViewModel per render would re-read the filesystem 60+ times while
    ## a trace opens. A CHANGE of workspace does rebuild it — the certificate
    ## store, the repository and the answer are all different then, and keeping
    ## the old model would be the staleness this feature exists to prevent.
    onIndicatorChanged = onChanged
    # NO WORKSPACE, NO INDICATOR. `gitWorkingDirectory` answers "" when no
    # project folder is open, and "" means "the platform's default" to every
    # facade operation — which on the desktop is the RENDERER'S OWN CWD. An
    # indicator built on that would probe whatever repository CodeTracer
    # happens to have been launched from and report its certificates as the
    # user's, which is a wrong answer rather than a slow one. It would also run
    # `git status` over that tree on the first paint of every window.
    #
    # `nil` renders no element at all, which is the honest surface for "there
    # is no workspace to say anything about".
    if workspaceDir.len == 0:
      indicator = nil
      indicatorWorkspace = ""
      return
    if not indicator.isNil and indicatorWorkspace == workspaceDir:
      return

    let host = ctPlatform()
    indicator = newCertificateIndicatorVm(
      platformCertificateFactsReader(host, workspaceDir, currentHostPlatform()))
    indicatorWorkspace = workspaceDir
    discard indicator.refresh(citStartup)

    if not timerInstalled:
      timerInstalled = true
      setRepeating(proc() = revalidateCertificateIndicator(),
                   RevalidateIntervalMs)

    if not host.can(capFilesystemWatch):
      return
    let vcs = workspaceVcsState(host, workspaceDir)
    if vcs.known:
      # EVERYTHING HERE IS RELATIVE TO THE OPENED WORKSPACE DIRECTORY, not to
      # the repository root, and that is a stated limit rather than an
      # oversight. `readCertificateStore` searches `<workspaceDir>/.repro`
      # (beside the local certificate store, which is per user), so the
      # workspace carrier this indicator speaks for is the one beside the
      # folder the user opened; using a different root for the watch than for
      # the store would make the two disagree.
      #
      # The consequence, for a project opened at a SUBDIRECTORY of its
      # repository: `<workspaceDir>/.git` does not exist, `watchDirectory`'s
      # refusal is ignored (see its header), and the commit trigger degrades to
      # the periodic backstop. The VCS *facts* are still right — the facade's
      # `repositoryRoot` resolves upwards — so the indicator is correct and
      # merely slower to notice a commit. `WorkspaceVcsState` carries no root
      # path to watch instead; giving it one, and pooling the store from the
      # repository root, is a change with its own test surface.
      watchDirectory(host, workspaceDir & "/.git", citCommitChanged)
    for dir in CertificateStoreDirs:
      # A store directory that does not exist yet cannot be watched; the
      # workspace-root watch below is what notices it being created.
      watchDirectory(host, workspaceDir & "/" & dir, citStoreChanged)
    # THE LOCAL CERTIFICATE STORE (CTC-3e), where `ct test` publishes. Watched
    # at the user root's algorithm directories, which change when a content
    # directory is created (the first run on a new content), and at the
    # content directories of the states looked up now, which change when a
    # record lands in one that exists. Not recursive, and not re-installed
    # when W moves on: the periodic backstop covers a directory that did not
    # exist yet, and `ct test` rewriting one that did is caught directly.
    let query = localStoreQuery(host, workspaceDir, vcs)
    if query.roots.available and query.roots.user.len > 0:
      for algorithm in ["git-tree-sha1", "git-tree-sha256"]:
        watchDirectory(host, query.roots.user & "/" & LocalStoreLayout & "/" &
                       algorithm, citStoreChanged)
      for contentId in query.contentIds:
        let dir = localStoreContentDir(contentId)
        if dir.ok:
          watchDirectory(host, query.roots.user & "/" & dir.relative,
                         citStoreChanged)
    # NOT RECURSIVE. One watch on the workspace root costs one inotify slot and
    # catches the two things a root watch can catch that nothing else does: a
    # store directory appearing for the first time (`.repro/`), and an
    # edit to a tracked file at the top level. A recursive watch would also
    # catch every build artefact in the tree, which is the cost this indicator
    # does not earn.
    watchDirectory(host, workspaceDir, citStoreChanged)

  proc selectCertificateIndicator*() =
    ## The user selected the indicator: re-read, then toggle the disclosure.
    if indicator.isNil:
      return
    indicator.toggleDisclosure()
    if not onIndicatorChanged.isNil:
      onIndicatorChanged()

  # ---------------------------------------------------------------------------
  # The in-Electron verification seam for the content facts (SB-2a)
  # ---------------------------------------------------------------------------
  #
  # `window.__ctCertificateFacts` calls the INSTALLED platform's facade —
  # `ctPlatform()`, which in the shipped window is `desktop_electron` — and
  # hands back each outcome as JSON. It exists because the Electron
  # instantiation is compiled only into the renderer bundle, so no Nim lane can
  # run it: `certificate-content-facts-electron.spec.ts` drives it through this
  # object, from inside the real app.
  #
  # Deliberately NO try/except here. The facade's contract is that failures
  # are values; a facade operation that throws must make the spec's
  # `page.evaluate` reject, which is what lets the spec catch `jsGuard`
  # losing its bare `except:` arm (SB-1's fix, which had no in-Electron test).

  import std/[enumutils, json]
  import ../viewmodel/platform/platform

  proc errorJson(error: PlatformError): JsonNode =
    %*{"ok": false, "errorKind": $error.kind, "errorMessage": error.message}

  proc contentIdJson(repository, state, algorithm: cstring;
                     scope: seq[cstring]): cstring =
    var source = vbsWorkingTree
    case $state
    of "W": source = vbsWorkingTree
    of "S": source = vbsIndex
    of "H": source = vbsHead
    else: return cstring($(%*{"ok": false, "errorKind": "pkInvalidArgument",
                               "errorMessage": "state must be W, S or H"}))
    var paths: seq[string] = @[]
    for path in scope: paths.add $path
    let outcome = ctAwaitSync(ctPlatform().vcs.contentId(
      $repository, source, $algorithm, paths))
    if not outcome.ok:
      return cstring($errorJson(outcome.error))
    var conditions = newJArray()
    for state in outcome.value.conditions:
      conditions.add %*{"condition": symbolName(state.condition),
                        "paths": state.paths}
    cstring($(%*{"ok": true, "kind": $outcome.value.kind,
                 "id": outcome.value.id, "algorithm": outcome.value.algorithm,
                 "reason": outcome.value.reason, "conditions": conditions}))

  proc storeRootsJson(): cstring =
    let outcome = ctAwaitSync(ctPlatform().fs.certificateStoreRoots())
    if not outcome.ok:
      return cstring($errorJson(outcome.error))
    cstring($(%*{"ok": true, "available": outcome.value.available,
                 "user": outcome.value.user, "system": outcome.value.system,
                 "problems": outcome.value.problems}))

  proc listDirJson(path: cstring): cstring =
    let outcome = ctAwaitSync(ctPlatform().fs.listDir($path))
    if not outcome.ok:
      return cstring($errorJson(outcome.error))
    var names: seq[string] = @[]
    for entry in outcome.value: names.add entry.name
    cstring($(%*{"ok": true, "names": names}))

  proc installCertificateFactsProbe(
      contentId: proc(repository, state, algorithm: cstring;
                      scope: seq[cstring]): cstring;
      storeRoots: proc(): cstring;
      listDir: proc(path: cstring): cstring)
    {.importjs: "(typeof window !== 'undefined') && (window.__ctCertificateFacts = {contentId: #, storeRoots: #, listDir: #})".}

  installCertificateFactsProbe(contentIdJson, storeRootsJson, listDirJson)
