import std/strutils

proc normalizeSourcePath(path: string): string =
  path.replace('\\', '/')

proc normalizeForCompare(path: string): string =
  normalizeSourcePath(path).strip(leading = false, trailing = true, chars = {'/'})

proc isAncestorPathOf*(dir, path: string): bool =
  ## True when ``dir`` is a *strict* ancestor directory of ``path``.
  ##
  ## Comparison is done on separator-normalized, trailing-slash-stripped
  ## forms so ``C:\proj\src`` is recognized as an ancestor of
  ## ``C:/proj/src/main.rs`` and ``/proj/src/`` of ``/proj/src/main.rs``.
  ## A node whose path is empty (the synthetic "source folders" tree root)
  ## is never reported as an ancestor — callers descend through it
  ## explicitly instead, because it is a container rather than a folder on
  ## disk.  A bare filesystem root (``/``) IS an ancestor of every
  ## absolute path even though it normalizes to the empty string.
  let normalizedDir = normalizeSourcePath(dir)
  let p = normalizeForCompare(path)
  if p.len == 0:
    return false
  let d = normalizeForCompare(dir)
  if d.len == 0:
    # Either "" (not a path) or a filesystem root such as "/".
    return normalizedDir.len > 0 and normalizedDir[0] == '/' and
      p.len > 1 and p[0] == '/'
  d.len < p.len and p.startsWith(d & "/")

proc isPathWithinRoot*(root, path: string): bool =
  ## True when ``path`` *is* ``root`` or lives below it.  An empty
  ## ``root`` matches nothing, so an unset workspace folder never claims
  ## a path.
  if normalizeSourcePath(root).len == 0:
    return false
  let normalizedRoot = normalizeForCompare(root)
  if normalizedRoot.len > 0 and normalizedRoot == normalizeForCompare(path):
    return true
  isAncestorPathOf(root, path)

proc isAbsoluteTraceSourcePath*(path: string): bool =
  ## Check if a trace source path is absolute on Unix or Windows.
  if path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    return true
  path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')

proc isTreeAncestorOf*(nodePath, target: string): bool =
  ## True when the Files-pane folder at ``nodePath`` contains ``target``,
  ## the file the debugger reports — the test reveal-active-file walks the
  ## tree with (``filesystem_vm.collectActiveFileAncestors``).
  ##
  ## An absolute ``nodePath``, or a relative ``target``, keeps
  ## ``isAncestorPathOf``'s strict-prefix rule.  A RELATIVE ``nodePath``
  ## against an ABSOLUTE ``target`` is the imported-trace case: the tree is
  ## rooted in payload folders named relative to ``files/`` (``src``,
  ## ``src/sub``), while the debugger reports the absolute path the program
  ## was recorded at (``/home/u/proj/src/sub/deep.nr``).  The two share no
  ## prefix, so the folder matches when ``"/" & nodePath & "/"`` occurs in
  ## ``"/" & target`` — on whole segments, so ``src`` does not match
  ## ``/x/mysrc/a.nr``.  It is a suffix match on the recorded layout and
  ## cannot tell two ``src`` folders of the target's path apart; the tree
  ## below the root only ever offers the one the payload holds.
  ##
  ## Separators are normalized to ``/``; ``./`` prefixes and trailing
  ## separators on ``nodePath`` are dropped.  An empty path matches nothing.
  var node = normalizeSourcePath(nodePath)
  while node.startsWith("./"):
    node = node[2 .. ^1]
  node = node.strip(leading = false, trailing = true, chars = {'/'})
  let normalizedTarget = normalizeSourcePath(target)
  if node.len == 0 or normalizedTarget.len == 0:
    return isAncestorPathOf(nodePath, target)
  if isAbsoluteTraceSourcePath(node) or
      not isAbsoluteTraceSourcePath(normalizedTarget):
    return isAncestorPathOf(nodePath, target)
  ("/" & normalizedTarget).contains("/" & node & "/")

proc stripTraceSourceRoot*(path: string): string =
  ## Strip an OS root/drive so an absolute source path can be placed below
  ## a self-contained trace's ``files/`` directory.
  let normalized = normalizeSourcePath(path)
  if normalized.len >= 3 and normalized[1] == ':' and normalized[2] == '/':
    normalized[3 .. ^1]
  elif normalized.len > 0 and normalized[0] == '/':
    normalized[1 .. ^1]
  else:
    normalized

proc dropTraceFilesPrefix(path: string): string =
  let normalized = normalizeSourcePath(path)
  if normalized.startsWith("files/"):
    normalized["files/".len .. ^1]
  else:
    normalized

proc addPayloadCandidate(candidates: var seq[string]; path: string) =
  var candidate = dropTraceFilesPrefix(path)
  while candidate.startsWith("./"):
    candidate = candidate[2 .. ^1]
  candidate = candidate.strip(leading = true, trailing = true, chars = {'/'})
  if candidate.len == 0 or candidate == ".":
    return
  for existing in candidates:
    if existing == candidate:
      return
  candidates.add(candidate)

proc relativePathInsideRoot(path, root: string): string =
  let normalizedPath = normalizeForCompare(path)
  let normalizedRoot = normalizeForCompare(root)
  if normalizedPath.len == 0 or normalizedRoot.len == 0:
    return ""
  if normalizedPath == normalizedRoot:
    return ""
  let prefix = normalizedRoot & "/"
  if normalizedPath.startsWith(prefix):
    normalizedPath[prefix.len .. ^1]
  else:
    ""

proc selfContainedSourcePayloadCandidates*(
    filename, workdir: string,
    sourceFolders: openArray[string] = []): seq[string] =
  ## Return relative payload paths to try under a self-contained trace's
  ## ``files/`` directory for a source location reported by the replay backend.
  ##
  ## Older self-contained traces stored absolute source paths by stripping
  ## the filesystem root (``/workspace/src/main.c`` ->
  ## ``files/workspace/src/main.c``). Newer portable recorders can store
  ## paths relative to the recorded workdir (``files/src/main.nr``), while
  ## the debugger still reports absolute source locations. Try both forms.
  let normalized = normalizeSourcePath(filename)
  if normalized.len == 0:
    return

  if isAbsoluteTraceSourcePath(normalized):
    result.addPayloadCandidate(stripTraceSourceRoot(normalized))

    let workdirRelative = relativePathInsideRoot(normalized, workdir)
    if workdirRelative.len > 0:
      result.addPayloadCandidate(workdirRelative)

    for folder in sourceFolders:
      let folderRelative = relativePathInsideRoot(normalized, folder)
      if folderRelative.len > 0:
        result.addPayloadCandidate(folderRelative)
  else:
    result.addPayloadCandidate(normalized)

# ---------------------------------------------------------------------------
# Lazy file-tree expansion ("load-path-content") source resolution
# ---------------------------------------------------------------------------

type
  TraceContentRoot* = object
    ## Where the index process should read a lazily-expanded file-tree
    ## subtree from.
    ##
    ## ``filesRoot``     — the ``<trace>/files`` payload root, or ``""``
    ##                     when the subtree lives on the real filesystem.
    ##                     ``""`` is safe to pass down: the loader only
    ##                     consults it when ``selfContained`` is true.
    ## ``selfContained`` — read from the trace payload rather than from
    ##                     the live filesystem.
    filesRoot*: string
    selfContained*: bool

proc traceFilesRootFor*(traceOutputFolder: string): string =
  ## The ``files/`` payload root of a self-contained trace.
  ##
  ## Returns ``""`` for an empty output folder — i.e. when there is no
  ## trace at all.  This is what makes the "Open Folder" case safe: the
  ## index process has no ``Trace`` object then, and the previous
  ## unconditional ``join(trace.outputFolder, "files")`` dereferenced a
  ## nil trace and rejected the async handler's promise, so the file
  ## tree never received its children and stayed on "Loading..." forever.
  if traceOutputFolder.len == 0:
    ""
  else:
    normalizeForCompare(traceOutputFolder) & "/files"

proc pathContentRootFor*(
    traceOutputFolder: string;
    traceImported: bool;
    workspaceFolder: string;
    requestedPath: string): TraceContentRoot =
  ## Decide where a lazily-expanded file-tree node's children are read from.
  ##
  ## Three cases, in order:
  ##
  ## 1. No trace (``traceOutputFolder == ""``) — plain folder / edit mode.
  ##    Read from the live filesystem.
  ## 2. A trace exists but the requested path is inside the folder the
  ##    user explicitly opened.  Opening a folder does not clear the
  ##    index process's previously loaded ``Trace``, so a *stale* trace
  ##    would otherwise redirect the read into an unrelated trace payload
  ##    and produce a subtree from the wrong root.  The workspace folder
  ##    is only ever set by the edit/open-folder flow, so this branch is
  ##    inert during a normal replay session.
  ## 3. Otherwise the trace decides, exactly as before.
  if traceOutputFolder.len == 0:
    return TraceContentRoot(filesRoot: "", selfContained: false)
  if isPathWithinRoot(workspaceFolder, requestedPath):
    return TraceContentRoot(filesRoot: "", selfContained: false)
  TraceContentRoot(
    filesRoot: traceFilesRootFor(traceOutputFolder),
    selfContained: traceImported)

proc payloadPathOf*(filesRoot, readPath: string): string =
  ## **Where a file-tree node was read in a trace payload**, as a path
  ## relative to the payload's ``files/`` root (``filesRoot``), with ``/``
  ## separators.  ``""`` when ``readPath`` is not strictly below
  ## ``filesRoot`` (the node came from the live disk) or either is empty.
  ##
  ## The index process records it on every node it reads from the payload
  ## (``CodetracerFileData.payloadPath``) so that a later lazy load of that
  ## node (``load-path-content``) reads from the SAME place.  The displayed
  ## path is not enough to find it again: a portable payload stores
  ## ``files/src/main.nr`` while the tree shows it under the absolute
  ## recorded folder, so ``files/<root-stripped display path>`` names a
  ## folder that does not exist (see ``index/files.loadFile``'s overlay).
  ##
  ## Both arguments must be in the same normal form (``index/files`` passes
  ## them through ``path.normalize`` / ``path.join``); no ``..`` resolution
  ## is attempted here.
  relativePathInsideRoot(readPath, filesRoot)

proc payloadReadPathFor*(filesRoot, payloadPath: string): string =
  ## **The payload location a lazy file-tree load may read**, for a
  ## ``payloadPath`` the renderer sent back: ``<filesRoot>/<payloadPath>``,
  ## or ``""`` when the value must be refused.
  ##
  ## The value arrives over IPC from the renderer, so it is checked rather
  ## than trusted: it may only name something INSIDE the payload.  Refused,
  ## and answered with ``""`` so the caller falls back to its ordinary
  ## resolution:
  ##
  ## - an empty value, or an empty ``filesRoot`` (no trace payload);
  ## - an absolute path (``/etc``, ``C:\x``, ``\\server\share``);
  ## - any ``..`` segment, wherever it sits — even one that would resolve
  ##   back inside the payload is refused, because nothing the index
  ##   process produces contains one;
  ## - a value with a NUL byte, which no filesystem path may carry;
  ## - anything else whose joined form is not strictly below ``filesRoot``
  ##   (checked last, with ``isAncestorPathOf``, as a backstop).
  ##
  ## ``.`` segments and doubled or trailing separators are dropped.
  ## Backslashes are treated as separators, as everywhere in this module.
  let root = normalizeForCompare(filesRoot)
  if root.len == 0 or payloadPath.len == 0 or '\0' in payloadPath:
    return ""
  let normalized = normalizeSourcePath(payloadPath)
  if isAbsoluteTraceSourcePath(normalized) or
      (normalized.len >= 2 and normalized[1] == ':'):
    # The second test also refuses a drive-relative ``C:x``.
    return ""
  var segments: seq[string] = @[]
  for segment in normalized.split('/'):
    if segment == "..":
      return ""
    if segment.len == 0 or segment == ".":
      continue
    segments.add segment
  if segments.len == 0:
    return ""
  let joined = root & "/" & segments.join("/")
  if not isAncestorPathOf(root, joined):
    return ""
  joined

proc sourceFolderRootsOf*(tracePaths: openArray[string]): seq[string] =
  ## **The folders a recording's sources live in**, from its `paths.json` —
  ## the ONE rule both the desktop (`index/traces.sourceFoldersFromTracePaths`)
  ## and the native front-ends (`native_host.loadRecordingPanes`, PLAT-41) use
  ## to build a replay session's file tree.
  ##
  ## A recorded path is relative to the trace's `files/` store; its folder is
  ## a root (a bare file name at the top is its own root). Absolute paths are
  ## skipped: they name the recording host's disk, not the trace's store.
  ## First occurrence wins, so the order is the recording's.
  for raw in tracePaths:
    let path = normalizeSourcePath(raw)
    if path.len == 0 or isAbsoluteTraceSourcePath(path):
      continue
    let slash = path.rfind('/')
    let root = if slash <= 0: path else: path[0 ..< slash]
    if root notin result:
      result.add root

# ---------------------------------------------------------------------------
# Root folders of an imported (self-contained) trace's file tree
# ---------------------------------------------------------------------------

type
  ImportedTraceTreeInputs* = object
    ## What the index process knows about an imported trace when it picks
    ## the roots of the Files pane (`index/traces.sourceFoldersFromTracePaths`).
    ##
    ## ``recordedSourceFolders`` — the trace's ``source_folders`` column.
    ##                             These are folders ON THE RECORDING HOST:
    ##                             the git root of the recorded program, or
    ##                             absolute parent folders of its sources.
    ## ``workdir``               — the recorded working directory.
    ## ``tracePathsRead``        — whether the ``paths.json`` sidecar next
    ##                             to the trace was read and parsed.
    ## ``tracePaths``            — its entries, when it was.
    ## ``payloadTopLevel``       — the names directly under the trace's
    ##                             ``files/`` payload.
    ## ``liveFallback``          — `fallbackLiveSourceFolders` of the trace:
    ##                             the program or workdir, when they exist
    ##                             on this machine.
    recordedSourceFolders*: seq[string]
    workdir*: string
    tracePathsRead*: bool
    tracePaths*: seq[string]
    payloadTopLevel*: seq[string]
    liveFallback*: seq[string]

proc addUniqueRoot(roots: var seq[string]; root: string) =
  if root.len > 0 and root notin roots:
    roots.add root

proc resolveAgainstWorkdir(workdir: string;
                           folders: openArray[string]): seq[string] =
  ## A relative payload root resolved to the live folder it was recorded
  ## from.  Absolute roots, and every root when there is no workdir, are
  ## kept as they are.
  for folder in folders:
    if folder.len == 0:
      continue
    if isAbsoluteTraceSourcePath(folder) or workdir.len == 0:
      result.addUniqueRoot folder
    else:
      result.addUniqueRoot(
        normalizeForCompare(workdir) & "/" & normalizeSourcePath(folder))

proc importedTraceTreeRoots*(
    input: ImportedTraceTreeInputs;
    payloadHasEntries: proc(root: string): bool): seq[string] =
  ## **The roots of an imported trace's Files pane.**
  ##
  ## ``payloadHasEntries(root)`` answers whether ``files/<root>`` exists in
  ## the trace payload and is a file or a non-empty folder.
  ##
  ## An imported trace carries its sources in its payload, so the roots
  ## are payload folders whenever the payload holds any.  The recorded
  ## source folders are paths on the RECORDING host; a root that names one
  ## of them sends the loader to the live disk, which on another machine
  ## does not exist and on the recording machine is the whole repository
  ## (GitHub #785: a Noir program inside a git checkout got the checkout's
  ## root, and the Files pane listed every file in it).  In order:
  ##
  ## 1. the workdir, when the payload mirrors it (the root-stripped
  ##    absolute layout, ``files/home/dev/project/...``) and it lies in a
  ##    recorded source folder;
  ## 2. the recorded source folders, when the payload mirrors all of them;
  ## 3. the folders of the ``paths.json`` entries (`sourceFolderRootsOf`)
  ##    that hold files in the payload — a root the payload lacks (nargo
  ##    lists ``std/lib.nr`` but does not copy it) is dropped, not looked
  ##    up on the live disk;
  ## 4. without a usable ``paths.json``, the payload's own top-level
  ##    folders that hold files;
  ## 5. only when the payload holds nothing at all, the live folders: the
  ##    ``paths.json`` roots resolved against the workdir, the recorded
  ##    source folders, or ``liveFallback`` — the loader reads those with
  ##    the live-filesystem limits (`index/files.loadFile`).
  var sourceFolders = input.recordedSourceFolders

  if input.workdir.len > 0 and payloadHasEntries(input.workdir):
    var workdirInsideKnownSource = sourceFolders.len == 0
    for folder in sourceFolders:
      if isPathWithinRoot(folder, input.workdir):
        workdirInsideKnownSource = true
    if workdirInsideKnownSource:
      return @[input.workdir]

  if sourceFolders.len > 0:
    var allInPayload = true
    for folder in sourceFolders:
      if not payloadHasEntries(folder):
        allInPayload = false
    if allInPayload:
      return sourceFolders

  let folders =
    if input.tracePathsRead: sourceFolderRootsOf(input.tracePaths)
    else: @[]
  for folder in folders:
    if payloadHasEntries(folder):
      result.addUniqueRoot folder
  if result.len > 0:
    return

  for name in input.payloadTopLevel:
    if payloadHasEntries(name):
      result.addUniqueRoot name
  if result.len > 0:
    return

  if folders.len > 0:
    sourceFolders = resolveAgainstWorkdir(input.workdir, folders)
  if sourceFolders.len == 0:
    sourceFolders = input.liveFallback
  sourceFolders
