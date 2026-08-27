## Shared, scoped enumeration of a workspace's *own* source files.
##
## Why this module exists
## ---------------------
## Every ct_test provider used to answer "which files are in this workspace?"
## by calling ``std/os.walkDirRec(projectRoot)`` itself, each with its own
## ad-hoc, inconsistent reject list (``js_common`` skipped ``node_modules/``,
## ``go_test`` skipped ``vendor/``, ``python_common`` and ``nim_unittest``
## skipped nothing at all). That had two consequences, both of which this
## module exists to remove:
##
## 1. **Scope.** A workspace that keeps vendored upstream source trees in-tree
##    — ``references/llvm-project``, ``references/buildxl``, … — had all of it
##    enumerated as if it were the project's own test suite. On one real
##    consumer that was 45,256 of 53,322 catalog items (84.9%): foreign code,
##    reported as the project's tests, in a surface whose whole purpose is to
##    tell a caller what this project's tests *are*.
## 2. **Cost.** ``discover --workspace`` fans out to ~38 providers. With every
##    provider running its own full recursive traversal (and several *reading
##    every matching file* just to decide whether to claim the workspace), a
##    single discovery performed dozens of full walks of a tree it had already
##    walked. Sharing one pruned traversal collapses that to one.
##
## What counts as "the workspace's own files"
## ------------------------------------------
## Rather than invent a ct_test-specific ignore file that every project would
## have to author and keep in sync, this module **honours the declaration the
## workspace already maintains**: its version-control inventory.
##
## ``git ls-files --cached --others --exclude-standard`` is exactly the
## question we want answered — "the files this project considers its own" —
## and it comes with three properties no hand-rolled walk gets for free:
##
## * it applies the full ``.gitignore`` / ``.git/info/exclude`` /
##   ``core.excludesFile`` chain, including negations and nested files;
## * it stops at nested repository boundaries, so a vendored upstream checkout
##   is reported as a single directory entry instead of being descended into.
##   This is a BACKSTOP, not the rule that usually fires: in the workspace the
##   45,256-item measurement came from, the trees under ``references/`` are
##   gitignored and ``git ls-files`` reported no directory entries at all, so
##   the ignore chain above did every bit of the excluding. The nested-checkout
##   rule is what covers a workspace that vendors an upstream tree *without*
##   ignoring it; and
## * it includes *untracked but not ignored* files, so a test written thirty
##   seconds ago and not yet ``git add``-ed is still discovered — which a
##   tracked-files-only query would have silently dropped.
##
## When the root is not inside a Git checkout (temp-dir fixtures, exported
## tarballs, ``git`` unavailable), the module falls back to a pruning
## filesystem walk that (a) refuses to descend into nested VCS checkouts and
## (b) prunes a built-in list of directory names that never hold a project's
## own tests (``VendorDirNames`` below). The built-in list is applied in *both*
## modes, so an un-ignored ``node_modules`` is excluded either way.
##
## Escape hatch
## ------------
## Scoping is on by default — a default that enumerates 45k foreign items is a
## footgun, and "remember to pass ``--exclude-vendored``" is not a fix. Callers
## that genuinely want the old unscoped behaviour ask for it explicitly, via
## ``setWorkspaceScopeMode(wsmUnscoped)`` (``ct-test test discover --unscoped``)
## or the ``CT_TEST_SCOPE`` environment variable (``auto``/``vcs``/``walk``/
## ``unscoped``).
##
## Everything anchored to the workspace root lives here
## -----------------------------------------------------
## Enumeration is the largest of the questions this module answers but not the
## only one. It also owns the two other rules that must be decided from the
## workspace root the caller named and from nothing else:
##
## * ``workspaceRelativePath`` / ``isInsideWorkspace`` — *does this file belong
##   to the workspace?*, shared by discovery and attestation so the two cannot
##   disagree about what a run covered; and
## * ``siblingRepoInWorkspace`` — *where inside this workspace is repository
##   X?*, used to locate sibling recorder checkouts.
##
## They are collected here because they share one adversary: each was once
## answered from ``getCurrentDir()``, which names nothing the caller asked for,
## so the same command produced different results from different shells.

import std/[algorithm, os, sets, strutils, tables]

import process_exec

type
  WorkspaceScopeMode* = enum
    ## How the in-scope file set for a workspace root is decided.
    wsmAuto = "auto"
      ## VCS inventory when the root is inside a usable checkout, pruning
      ## filesystem walk otherwise. The default.
    wsmVcs = "vcs"
      ## Require the VCS inventory; yield nothing rather than silently
      ## widening to an unscoped walk. For callers that would rather see an
      ## empty catalog than a wrong one.
    wsmWalk = "walk"
      ## Always use the pruning filesystem walk, even inside a checkout.
    wsmUnscoped = "unscoped"
      ## No scoping beyond skipping VCS metadata directories: the historical
      ## ``walkDirRec`` behaviour, kept so a caller can reproduce it on purpose.

  WorkspaceScopeSource* = enum
    ## Which rule actually produced the file set (reported in diagnostics).
    wssVcsInventory = "vcs-inventory"
    wssFilesystemWalk = "filesystem-walk"
    wssUnscopedWalk = "unscoped-walk"
    wssUnavailable = "unavailable"

  WorkspaceScope* = ref object
    ## The resolved in-scope file set for one workspace root.
    root*: string                 ## absolute, normalized
    source*: WorkspaceScopeSource
    files*: seq[string]           ## absolute paths, sorted, files only
    excludedRoots*: seq[string]   ## root-relative subtrees that were pruned
    notes*: seq[string]           ## human-readable scoping notes

const
  VendorDirNames*: array[28, string] = [
    # Version-control metadata and nested-checkout markers.
    ".git", ".hg", ".svn", ".jj", "_darcs",
    # Dependency trees fetched by a package manager. Never first-party tests;
    # ``vendor``/``third_party`` are the canonical in-tree vendoring names in
    # Go, Ruby, PHP and C/C++ projects respectively.
    "node_modules", "vendor", "third_party", "thirdparty", "nimbledeps",
    # Language/tool caches.
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ".tox", ".nox", ".eggs", "nimcache", ".cache",
    # Virtual environments and per-directory environment managers.
    ".venv", "venv", ".direnv", ".devenv",
    # Editor/IDE and tool state.
    ".idea", ".vs", ".vscode", ".gradle", ".terraform"]
    ## Directory names pruned in every mode except ``wsmUnscoped``.
    ##
    ## Deliberately does NOT include build-output names (``build``, ``dist``,
    ## ``target``, ``out``): those are already gitignored in real projects (so
    ## the VCS inventory drops them anyway), several providers handle them
    ## themselves, and they are plausible names for a first-party source
    ## directory. Excluding them globally would trade one silent-wrong-answer
    ## for another.

  ScopeModeEnvVar* = "CT_TEST_SCOPE"
    ## Environment override for the default mode, for embedders that cannot
    ## reach ``setWorkspaceScopeMode`` (e.g. a provider suite invoked through a
    ## shell wrapper).

# ---------------------------------------------------------------------------
# Process-wide (thread-local) state.
#
# ``TestProvider``'s callbacks receive only ``projectRoot: string``, so the
# resolved scope cannot be threaded through them as a parameter without
# changing the provider contract in ~30 modules. Instead the scope is
# memoized here, keyed by absolute root, and ``discovery.discover`` calls
# ``invalidateWorkspaceScopes`` once per invocation so a long-lived process
# (the GUI's embedded ``ct test discover``) never serves a stale file set.
#
# Both are ``{.threadvar.}`` rather than plain globals: provider callbacks are
# ``{.gcsafe.}``, and the run orchestrator executes them on a worker pool. A
# thread-local memo is safe there by construction (no sharing, no lock), at the
# cost of one extra ``git ls-files`` per thread that discovers.
# ---------------------------------------------------------------------------
var
  scopeCache {.threadvar.}: Table[string, WorkspaceScope]
  scopeModeOverride {.threadvar.}: WorkspaceScopeMode
  scopeModeOverrideSet {.threadvar.}: bool
  vcsCaptureLimitOverride {.threadvar.}: int
  vcsCaptureLimitOverrideSet {.threadvar.}: bool

proc parseWorkspaceScopeMode*(raw: string): WorkspaceScopeMode =
  ## Parse a mode name; unknown values fall back to ``wsmAuto`` so a typo in
  ## the environment degrades to the safe default instead of aborting.
  case raw.strip.toLowerAscii
  of "vcs": wsmVcs
  of "walk": wsmWalk
  of "unscoped", "off", "none": wsmUnscoped
  else: wsmAuto

proc setWorkspaceScopeMode*(mode: WorkspaceScopeMode) =
  ## Pin the scoping mode for this thread and drop any memoized scopes
  ## resolved under the previous mode.
  scopeModeOverride = mode
  scopeModeOverrideSet = true
  scopeCache = initTable[string, WorkspaceScope]()

proc clearWorkspaceScopeMode*() =
  ## Return to ``CT_TEST_SCOPE``/``wsmAuto`` resolution. Exists so tests can
  ## restore the default without leaking a pinned mode into the next case.
  scopeModeOverrideSet = false
  scopeCache = initTable[string, WorkspaceScope]()

proc workspaceScopeMode*(): WorkspaceScopeMode =
  if scopeModeOverrideSet: scopeModeOverride
  else: parseWorkspaceScopeMode(getEnv(ScopeModeEnvVar, ""))

proc scopeModeRequestOrigin(): string =
  ## Name the surface the active mode actually came from.
  ##
  ## Both routes exist and the pinned mode (installed by ``--scope`` through
  ## ``setWorkspaceScopeMode``) wins over the environment variable, so a
  ## diagnostic that always blames ``CT_TEST_SCOPE`` sends a reader hunting for
  ## an environment variable nobody set.
  if scopeModeOverrideSet: "--scope "
  else: ScopeModeEnvVar & "="

proc invalidateWorkspaceScopes*() =
  ## Drop every memoized scope. Called at the top of each ``discover`` so the
  ## file set is re-resolved from the filesystem once per invocation while
  ## still being shared by all providers within it.
  scopeCache = initTable[string, WorkspaceScope]()

proc isVendorDir(name: string): bool =
  for vendored in VendorDirNames:
    if name == vendored:
      return true
  false

proc isNestedVcsRoot(path: string): bool =
  ## A directory that carries its own VCS metadata is a separate checkout —
  ## a vendored upstream tree, a submodule, or a ``repo``-tool sibling — not
  ## part of the workspace under discovery. ``.git`` is a *file* for worktrees
  ## and submodules, hence ``fileExists`` as well as ``dirExists``.
  for marker in [".git", ".hg", ".svn", ".jj"]:
    let candidate = path / marker
    if dirExists(candidate) or fileExists(candidate):
      return true
  false

proc relativeSlashPath(root, path: string): string =
  relativePath(path, root).replace('\\', '/')

proc walkPruned(root: string; prune: bool;
                excluded: var seq[string]): seq[string] =
  ## Iterative pre-order walk that *prunes the descent* rather than filtering
  ## results after the fact. Pruning is the whole point: the previous
  ## per-provider reject lists still paid to traverse ``node_modules`` and
  ## every vendored checkout before discarding what they found.
  result = @[]
  var pending = @[root]
  while pending.len > 0:
    let dir = pending.pop()
    var entries: seq[tuple[kind: PathComponent, path: string]] = @[]
    try:
      for kind, path in walkDir(dir):
        entries.add (kind, path)
    except OSError:
      # An unreadable directory is not a reason to fail discovery; the caller
      # sees a smaller file set and the note below explains nothing about it,
      # so record it as an excluded root for visibility.
      excluded.add relativeSlashPath(root, dir)
      continue
    for (kind, path) in entries:
      case kind
      of pcDir, pcLinkToDir:
        let name = splitPath(path).tail
        if prune and isVendorDir(name):
          excluded.add relativeSlashPath(root, path)
          continue
        if name == ".git" or name == ".hg" or name == ".svn" or name == ".jj":
          # Pruned even when ``prune`` is false: VCS metadata is never source.
          continue
        if prune and isNestedVcsRoot(path):
          excluded.add relativeSlashPath(root, path)
          continue
        # Symlinked directories are not followed. ``walkDirRec``'s default
        # ``followFilter`` is ``{pcDir}`` too, and following them turns a
        # workspace with a self-referential link into an unbounded walk.
        if kind == pcDir:
          pending.add path
      of pcFile:
        result.add path
      of pcLinkToFile:
        # ``walkDirRec``'s default ``yieldFilter`` is ``{pcFile}``, which
        # excludes symlinks; keep that so replacing the walk changes scope
        # only, never the kind of entry a provider sees.
        discard

proc vcsInventoryCaptureLimit(): int =
  ## Capture bound for the inventory command.
  ##
  ## Overridable so the truncation guard below can be exercised against a
  ## handful of files instead of the ~280,000 it would take to overrun the
  ## 16 MiB default. The guard is the only thing standing between a cut
  ## ``git ls-files`` and a silently short catalog, so it has to be tested.
  if vcsCaptureLimitOverrideSet: vcsCaptureLimitOverride
  else: DefaultCaptureLimit

proc setVcsInventoryCaptureLimit*(bytes: int) =
  ## Pin the inventory capture bound for this thread (tests only) and drop any
  ## scope memoized under the previous bound.
  vcsCaptureLimitOverride = bytes
  vcsCaptureLimitOverrideSet = true
  scopeCache = initTable[string, WorkspaceScope]()

proc clearVcsInventoryCaptureLimit*() =
  ## Return to ``DefaultCaptureLimit``.
  vcsCaptureLimitOverrideSet = false
  scopeCache = initTable[string, WorkspaceScope]()

proc vcsInventory(root: string; excluded: var seq[string]):
    tuple[ok: bool; files: seq[string]; failure: string] =
  ## Ask Git for the workspace's own files.
  ##
  ## ``git ls-files`` is scoped to the working directory it runs in, so a
  ## ``--workspace`` pointing at a subdirectory of a checkout yields only that
  ## subtree — no upward-walk heuristics needed here.
  ##
  ## ``-z`` because paths may contain anything but NUL (Git would otherwise
  ## quote and escape non-ASCII names, and we would have to unescape them).
  ##
  ## ``ok == false`` means "no usable inventory"; ``failure`` says why, so the
  ## caller can report the real reason instead of a generic one.
  result = (ok: false, files: @[], failure: "")
  let run = execCaptured(
    @["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    cwd = root, captureLimit = vcsInventoryCaptureLimit())
  if run.exitCode != 0 or run.timedOut:
    result.failure = "`git ls-files` did not succeed under " & root
    return
  if run.truncated:
    # A cut inventory is WORSE than no inventory. `git ls-files` emits paths in
    # sorted order, so truncation removes a contiguous tail of the alphabet —
    # a whole set of directories that simply never appear, with nothing in the
    # output to say so. Every other failure mode here is loud; this one would
    # hand back a plausible, short, wrong file set. Refuse it.
    result.failure =
      "`git ls-files` output exceeded the " & $vcsInventoryCaptureLimit() &
      " byte capture bound (" & $run.outputBytes & " bytes produced) under " &
      root & "; the inventory would be missing a tail of the sorted path list"
    return
  for raw in run.output.split('\0'):
    if raw.len == 0:
      continue
    let absolute = root / raw
    if dirExists(absolute):
      # Git reports a nested checkout as a single directory entry rather than
      # descending into it. That entry IS the vendored-tree boundary.
      excluded.add raw.strip(trailing = true, chars = {'/'})
      continue
    if not fileExists(absolute):
      # Deleted-but-still-indexed path; not something a provider can parse.
      continue
    var vendored = false
    for segment in raw.split('/'):
      if isVendorDir(segment):
        vendored = true
        break
    if vendored:
      continue
    result.files.add normalizedPath(absolute)
  result.ok = true

proc resolveScope(root: string; mode: WorkspaceScopeMode): WorkspaceScope =
  let normalizedRoot = normalizedPath(absolutePath(root))
  result = WorkspaceScope(
    root: normalizedRoot,
    source: wssUnavailable,
    files: @[],
    excludedRoots: @[],
    notes: @[])
  if not dirExists(normalizedRoot):
    result.notes.add "workspace scope: not a directory: " & normalizedRoot
    return

  if mode == wsmUnscoped:
    result.source = wssUnscopedWalk
    result.files = walkPruned(
      normalizedRoot, prune = false, result.excludedRoots)
    result.notes.add(
      "workspace scope: unscoped walk requested; vendored and ignored trees " &
      "are INCLUDED (" & $result.files.len & " files)")
  else:
    var usedVcs = false
    if mode in {wsmAuto, wsmVcs}:
      let inventory = vcsInventory(normalizedRoot, result.excludedRoots)
      if inventory.ok and inventory.files.len > 0:
        usedVcs = true
        result.source = wssVcsInventory
        result.files = inventory.files
      elif inventory.ok and mode == wsmVcs:
        # Explicitly asked for the VCS inventory and it is genuinely empty.
        usedVcs = true
        result.source = wssVcsInventory
      elif inventory.ok:
        # In a checkout, but it reports no files of its own — the usual cause
        # is a workspace directory that its enclosing repository ignores.
        # Widening to the filesystem walk beats reporting "no tests".
        result.excludedRoots = @[]
        result.notes.add(
          "workspace scope: git reported no files under this root (is it " &
          "ignored by an enclosing repository?); falling back to a pruning " &
          "filesystem walk")
      elif mode == wsmVcs:
        # `vcs` means "an inventory or nothing" — that is the whole point of
        # asking for it — so an unusable inventory is an error, not a quiet
        # widening to a different rule.
        result.notes.add(
          "workspace scope: " & scopeModeRequestOrigin() &
          "vcs was requested but the inventory is unusable: " &
          inventory.failure)
        result.source = wssUnavailable
        return
      else:
        # `auto`: fall through to the pruning filesystem walk, but say why —
        # an unusable inventory silently changing which rule produced the file
        # set is exactly the kind of invisible scope change this module exists
        # to make visible.
        result.excludedRoots = @[]
        result.notes.add(
          "workspace scope: falling back to a pruning filesystem walk: " &
          inventory.failure)

    if not usedVcs:
      result.excludedRoots = @[]
      result.source = wssFilesystemWalk
      result.files = walkPruned(
        normalizedRoot, prune = true, result.excludedRoots)

  result.files.sort(system.cmp[string])
  result.excludedRoots.sort(system.cmp[string])
  # Deduplicate: a path can be reported once per provider-visible route.
  var seenFiles = initHashSet[string]()
  var uniqueFiles: seq[string] = @[]
  for path in result.files:
    if not seenFiles.containsOrIncl(path):
      uniqueFiles.add path
  result.files = uniqueFiles
  var seenExcluded = initHashSet[string]()
  var uniqueExcluded: seq[string] = @[]
  for path in result.excludedRoots:
    if not seenExcluded.containsOrIncl(path):
      uniqueExcluded.add path
  result.excludedRoots = uniqueExcluded

proc workspaceScope*(root: string): WorkspaceScope =
  ## Resolve (and memoize for this thread) the in-scope file set for ``root``.
  if scopeCache.len == 0:
    scopeCache = initTable[string, WorkspaceScope]()
  let key = normalizedPath(absolutePath(root))
  if scopeCache.hasKey(key):
    return scopeCache[key]
  result = resolveScope(key, workspaceScopeMode())
  scopeCache[key] = result

proc scopeSummary*(scope: WorkspaceScope): string =
  ## One-line, machine-greppable description of what discovery was allowed to
  ## look at. Emitted as an ``info`` diagnostic by ``discovery.discover`` so a
  ## caller comparing catalogs against another runner can see *why* a file set
  ## is the size it is, instead of having to guess.
  result = "discovery scope: " & $scope.files.len & " file(s) under " &
    scope.root & " via " & $scope.source
  if scope.excludedRoots.len > 0:
    const MaxListed = 8
    var listed: seq[string] = @[]
    for i, path in scope.excludedRoots:
      if i >= MaxListed:
        listed.add "… and " & $(scope.excludedRoots.len - MaxListed) & " more"
        break
      listed.add path
    result.add "; excluded vendored/nested trees: " & listed.join(", ")

iterator walkWorkspaceFiles*(root: string): string =
  ## Drop-in replacement for ``std/os.walkDirRec(root)`` restricted to the
  ## workspace's own files.
  ##
  ## Providers call this instead of walking themselves, so (a) the traversal
  ## happens once per root per discovery rather than once per provider, and
  ## (b) a provider physically cannot enumerate a vendored tree even if it
  ## forgets to add that tree to its own reject list.
  ##
  ## Yields absolute paths to *files* only (``walkDirRec`` yields directories
  ## too under non-default flags; no ct_test caller used that).
  let scope = workspaceScope(root)
  for path in scope.files:
    yield path

proc workspaceRelativePath*(workspaceRoot, path: string): string =
  ## The workspace-relative spelling of ``path``, or ``""`` when ``path`` lies
  ## **outside** ``workspaceRoot``.
  ##
  ## The one containment test in ct_test, shared by the two places that must
  ## agree about it: discovery, which may not report a test the caller's
  ## workspace does not contain, and attestation
  ## (``certificate_issuance.targetOfUnit``), which may not claim coverage of
  ## one. They were previously separate — discovery had no bound at all — and
  ## the disagreement was observable: a run could report 331 discovered units
  ## and attest almost none of them, because the units belonged to sibling
  ## repositories the certificate's ``[certificate.vcs]`` section does not
  ## describe.
  ##
  ## **Containment is resolved, not spelled.** Deciding it on the written form
  ## — ``path == ".." or path.startsWith("../")`` — gets three cases wrong: a
  ## relative path whose *interior* ``..`` escapes
  ## (``sub/../../outside/tests/o.rb``) is not caught; a legitimate absolute
  ## path under a **symlinked** workspace root is wrongly rejected; and an
  ## interior ``..`` that resolves back inside is accepted under its
  ## unnormalized spelling, so one file can appear twice under two names and
  ## defeat deduplication. So both sides are resolved first: ``..`` segments
  ## are collapsed, and the root is additionally resolved through symlinks
  ## where the filesystem can answer.
  ##
  ## The file itself is **not** required to exist. Callers ask this about a
  ## path a provider reported — a test file deleted mid-run, or a fixture
  ## enumerated a moment ago — and a ``stat`` would answer a different
  ## question at a different time.
  ##
  ## One residue: a symlinked *directory inside* the root is reported under
  ## the link spelling rather than the target's, so one file can still be
  ## named two ways. That is an alias within the workspace rather than an
  ## escape from it, and resolving it would mean stat-ing every path
  ## component, which this deliberately does not do.
  if path.len == 0 or workspaceRoot.len == 0:
    return ""

  proc resolvedDir(dir: string): string =
    ## Collapse ``..``/``.`` and, when the directory exists, follow symlinks.
    ## Falls back to the lexical form so a not-yet-created root still works.
    let lexical = normalizedPath(absolutePath(dir))
    try:
      expandFilename(lexical)
    except OSError, IOError:
      lexical

  let roots = block:
    let lexical = normalizedPath(absolutePath(workspaceRoot))
    let real = resolvedDir(workspaceRoot)
    if real == lexical: @[lexical] else: @[lexical, real]

  # Resolve the path against the workspace root when it is relative, then
  # collapse. `..` that escapes the root survives this as a path outside it,
  # which the containment test below then rejects.
  let lexicalPath = normalizedPath(
    if isAbsolute(path): path
    else: normalizedPath(absolutePath(workspaceRoot)) / path)
  # A symlinked root reaches its files under the resolved name, so try that
  # spelling too — resolving the DIRECTORY only, never requiring the file.
  let realPath = block:
    let parent = resolvedDir(parentDir(lexicalPath))
    if parent.len == 0: lexicalPath else: parent / lastPathPart(lexicalPath)

  for root in roots:
    for candidate in [lexicalPath, realPath]:
      if candidate.len <= root.len or not candidate.startsWith(root):
        continue
      # Guard the prefix boundary: `/ws-other/x` must not count as inside
      # `/ws`, which a bare `startsWith` would accept.
      if candidate[root.len] != DirSep and candidate[root.len] != '/':
        continue
      return candidate[root.len + 1 .. ^1].replace('\\', '/')
  ""

proc isInsideWorkspace*(workspaceRoot, path: string): bool =
  ## Does ``path`` lie inside ``workspaceRoot``? See ``workspaceRelativePath``,
  ## whose answer this is the boolean form of — the same resolution, so the two
  ## questions cannot be answered differently.
  workspaceRelativePath(workspaceRoot, path).len > 0

proc siblingRepoInWorkspace*(workspaceRoot, repoName: string): string =
  ## Locate the checkout named ``repoName`` **inside the workspace root the
  ## caller named**, or return ``""`` to say it is not there.
  ##
  ## Two forms are recognised, and they are the two ways a caller names a
  ## multi-repo CodeTracer workspace:
  ##
  ## * ``workspaceRoot`` *is* that repository — ``ct test --workspace
  ##   codetracer-ruby-recorder``; and
  ## * ``workspaceRoot`` *contains* it as a sibling checkout — ``ct test
  ##   --workspace <multi-repo workspace>``.
  ##
  ## Nothing above the named root is searched, and — the point of this proc
  ## existing — ``getCurrentDir()`` is never consulted. Three call sites used
  ## to seed a sibling search from the process working directory, so *which*
  ## repository answered a question depended on the directory the shell
  ## happened to be in: `smart_contract_common.findRecorderRepo` (which decided
  ## which fixtures became test units), and the JS and Ruby recorder-prefix
  ## resolvers (which decide which recorder binary records a trace, if any).
  ## Measured for the JS one, same ``--workspace``, same binary, same
  ## environment, only the cwd differing: the workspace's own recorder, a
  ## refusal to record at all, and an unrelated sibling repository's recorder.
  ##
  ## The answer is therefore a function of the caller's argument alone, which
  ## is the only way a caller can predict it. Callers who want a sibling's
  ## recorder or fixtures still have an exact way to ask: name the workspace
  ## that contains it, or point the provider's ``*_RECORDER_PATH`` environment
  ## variable straight at the binary.
  ##
  ## The root is resolved (``..``/``.`` collapsed) but the sibling is *not*
  ## required to be a Git checkout: workspaces are also assembled by hand and
  ## in test fixtures, and demanding a ``.git`` here would make this stricter
  ## than the enumeration rules above it.
  if workspaceRoot.len == 0 or repoName.len == 0:
    return ""
  let root = normalizedPath(absolutePath(workspaceRoot))
  if splitPath(root).tail == repoName and dirExists(root):
    return root
  let nested = root / repoName
  if dirExists(nested):
    return nested
  ""
