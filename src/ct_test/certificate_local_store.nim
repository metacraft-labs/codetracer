## Where a `ct test` run publishes the certificate it just issued: the user's
## local certificate store (test-certificates-spec ``Transport.md`` §2).
##
## Certificates are ephemeral and never live in the working tree. A
## certificate attests content that, when it is issued, usually exists only in
## one working tree; a record written into that tree would change the content
## it attests, and the next run would report the producer's own bookkeeping as
## the user's untracked work. So nothing here writes under the repository:
## every record goes to the store the standard defines, which every conforming
## producer populates and any tool — a pre-commit gate, the status bar — reads
## by content id.
##
## What this module does, rule by rule
## -----------------------------------
## * **Root (§2.1).** The USER root, resolved by ``certificate_store_roots``:
##   ``$TEST_CERTIFICATES_DIR`` when it is absolute, else the platform's
##   per-user state directory. `ct test` runs as the user, so it writes the
##   user root and never the system root, which belongs to a privileged
##   producer (§2.3). A root that resolves INSIDE the repository being tested
##   is refused: it would be the working tree again.
## * **Path (§2.2).** ``<root>/v1/<algorithm>/<digest>/<payload-hash>.toml``:
##   the content id split at its first ``:`` (``certificate_store``'s
##   ``localStoreContentDir``, shared with the reader), and the lowercase hex
##   SHA-256 of the record's CANONICAL PAYLOAD — rebuilt from the parsed
##   document, so the signature block is never hashed. The standard's
##   ``store/`` vectors pin this derivation; ``certificate_vectors_test.nim``
##   walks them through ``localStoreRelativePathOf`` below.
## * **Write (§2.3).** Directories are created owner-only. The record is
##   written under a temporary name in the SAME directory — beginning with
##   ``.`` and not ending in ``.toml``, so no reader ever lists it — flushed to
##   disk, and renamed onto its final name, so a reader sees the whole file or
##   none of it, and two writers either write different names or the same
##   bytes under one name. When the final name exists: a SIGNED record always
##   replaces it (its signature was just made, while the existing copy may be
##   unsigned or carry a signature that fails); an UNSIGNED record keeps it,
##   because the existing file is either the same claim or the same claim
##   signed, and replacing a signed copy with an unsigned one would discard the
##   signature.
## * **Prune (§2.5).** On publish only: whole content directories, keeping the
##   ``keep`` most recently written (by the directory's modification time,
##   which a rename into it updates) plus the directory of the current
##   repository's ``HEAD^{tree}`` and the one just written into. A directory a
##   producer is writing into — one holding a fresh temporary file, or
##   modified in the last few seconds — is never removed. A directory is
##   removed by first renaming it aside, within its parent, to a dot-named
##   name no reader or pruner treats as a content directory, and only then
##   deleting the renamed tree. The rename is the one atomic moment the
##   directory leaves the store, so a prune racing a publish costs at most one
##   retried rename: when the rename fails because the directory or the
##   temporary file vanished, the writer recreates the directory — a NEW
##   directory, which the removal in progress cannot reach — and tries once
##   more. Deleting in place instead (unlink the entries, then the directory)
##   is not atomic: one removal could also unlink the temporary file of the
##   writer's retry, created in the same still-present directory, and then
##   remove the directory under it.
##
## Nothing here signs. It is handed a rendered document and puts it somewhere;
## the only route to a signature remains ``certificate_issuance.runAndAttest``.
## It writes nothing but the store, reads nothing under ``.ct/``, and never
## touches the working tree or the user's index.

import std/[algorithm, atomics, os, strutils, times]

when defined(windows):
  import std/winlean
else:
  from std/posix import fsync
  proc c_rename(oldname, newname: cstring): cint {.
    importc: "rename", header: "<stdio.h>".}

import certificate
import certificate_content_id
import certificate_content_id_native
import certificate_store
import certificate_store_roots_native

export certificate_store_roots_native

const
  DefaultRetention* = 20
    ## The reference policy's number of content directories kept
    ## (Transport.md §2.5).

  StaleTemporaryAge* = initDuration(hours = 1)
    ## A temporary file older than this belongs to a writer that died, not to
    ## one that is writing. Without an age a crashed run would pin its content
    ## directory against pruning forever.

  FreshDirectoryAge* = initDuration(seconds = 10)
    ## A content directory modified more recently than this is treated as
    ## being written into, whether or not its temporary file exists yet: a
    ## writer creates the directory a moment BEFORE it opens the temporary
    ## file, and a prune landing in that moment would cost the writer its
    ## retry for nothing. Only ever protects a directory for seconds, and
    ## the newest directories are kept by the count anyway.

  TemporaryMarker* = ".tmp-"
    ## Part of every temporary name, after the leading ``.``.

  RemovalMarker* = ".removing-"
    ## Part of the name a content directory is renamed to while a prune
    ## deletes it: ``.<digest>.removing-<pid>-<counter>``, beside the
    ## directories of its algorithm. Begins with ``.``, so it is never a
    ## content directory (a digest is hex) and no reader lists it.

type
  LocalStorePath* = tuple[path: string; error: string]
    ## A ``/``-separated store-relative path, or why there is none.

  PruneOutcome* = object
    removed*: seq[string]
      ## Content directories removed, store-relative (``v1/<alg>/<digest>``).
    errors*: seq[string]
      ## Directories that could not be removed, with the reason. Never fatal:
      ## pruning is a matter of disk space, not of correctness (§2.5).

  PruneStage* = enum
    ## The points of one directory's removal a ``PruneStepHook`` observes.
    psChosen
      ## Chosen for removal — not kept, not protected, not being written —
      ## and nothing changed yet.
    psDetached
      ## Renamed aside: gone from the store, its tree not yet deleted.

  PruneStepHook* = proc(stage: PruneStage; relative: string) {.nimcall, gcsafe.}
    ## A test seam: lets the suite interleave a writer with a removal at a
    ## named point, deterministically. ``nil`` in production.

  PublishStepHook* = proc(attempt: int) {.nimcall, gcsafe.}
    ## A test seam: called with the attempt number (0, then 1 on the retry)
    ## once the temporary file is written and flushed, just before the
    ## rename. ``nil`` in production.

  PublishOutcome* = object
    ## What happened when the run tried to publish its certificate.
    ##
    ## Every failure is a **value**, never an exception: publishing is the last
    ## step of a run that already happened, and a store that could not be
    ## written must not change the run's verdict or its exit code.
    root*: string
      ## The user root written to; empty when none could be resolved.
    path*: string
      ## The record's full path. Set whenever it could be derived, written or
      ## not.
    written*: bool
      ## The record is at ``path`` — written now, or kept because an
      ## identical claim was already there.
    kept*: bool
      ## An unsigned record found its final name taken and left the existing
      ## file in place (§2.3). ``written`` is ``true`` too.
    retried*: bool
      ## The first attempt failed because a concurrent prune removed the
      ## content directory, and the write was retried once (§2.5).
    error*: string
      ## Why the record could not be written. Empty on success.
    pruned*: PruneOutcome

# ---------------------------------------------------------------------------
# The path (Transport.md §2.2)
# ---------------------------------------------------------------------------

proc localStoreRelativePath*(cert: TestCertificate): LocalStorePath =
  ## ``v1/<algorithm>/<digest>/<payload-hash>.toml`` for a record.
  ##
  ## The payload is ``canonicalPayload``: the bytes a signature covers, which
  ## exclude the signature block, so a signed record and the same record with
  ## its block removed or emptied share a name (Canonical-Payload.md §6).
  let dir = localStoreContentDir(cert.vcs.content)
  if not dir.ok:
    return ("", dir.problem)
  var payload: string
  try:
    payload = canonicalPayload(cert)
  except CatchableError as err:
    return ("", "the record has no canonical payload: " & err.msg)
  (dir.relative & "/" & sha256Hex(payload) & ".toml", "")

proc readForStore(document: string): tuple[path: LocalStorePath; signed: bool] =
  let read = readCertificate(document)
  if read.status != crsOk:
    return (("", "the record does not read: " & $read.status & " " &
             read.detail), false)
  (localStoreRelativePath(read.cert), read.cert.isSigned)

proc localStoreRelativePathOf*(document: string): LocalStorePath =
  ## The same, for a rendered document: parsed first, so the name is derived
  ## from the record's FIELDS (Canonical-Payload.md §5), never from the file's
  ## bytes. This is the derivation the standard's ``store/`` vectors test.
  readForStore(document).path

proc toNative(relative: string): string =
  relative.replace('/', DirSep)

# ---------------------------------------------------------------------------
# Writing (Transport.md §2.3)
# ---------------------------------------------------------------------------

proc ownerOnly(): set[FilePermission] = {fpUserRead, fpUserWrite, fpUserExec}

proc createOwnerOnlyDirs(root, relative: string) =
  ## Create ``root`` and every directory of ``relative`` below it that is
  ## missing, each readable and writable by the owner only. An existing
  ## directory's mode is left as its owner set it.
  var current = root
  var missing: seq[string] = @[]
  var probe = root
  while probe.len > 0 and not dirExists(probe):
    missing.add probe
    let parent = probe.parentDir
    if parent == probe:
      break
    probe = parent
  for i in countdown(missing.high, 0):
    if not dirExists(missing[i]):
      try:
        createDir(missing[i])
      except OSError:
        if not dirExists(missing[i]):
          raise
  # Only the root itself and what is below it are made owner-only; the
  # parents of the root (e.g. `~/.local/state`) are created by this call when
  # absent, but their modes are a matter for the platform's own conventions.
  if root in missing:
    setFilePermissions(root, ownerOnly())
  for part in relative.split('/'):
    if part.len == 0:
      continue
    current = current / part
    if not dirExists(current):
      try:
        createDir(current)
        setFilePermissions(current, ownerOnly())
      except OSError:
        # A concurrent writer created it first; that is the same directory.
        if not dirExists(current):
          raise

var temporaryCounter {.threadvar.}: int

proc temporaryName*(finalName: string): string =
  ## ``.<final>.tmp-<pid>-<counter>-<time>``: begins with ``.`` and does not
  ## end in ``.toml`` (§2.3), and is unique across concurrent processes (the
  ## pid) and calls (the counter and the clock).
  inc temporaryCounter
  "." & finalName & TemporaryMarker & $getCurrentProcessId() & "-" &
    $temporaryCounter & "-" & $getTime().toUnix() & $getTime().nanosecond

proc writeFlushed(path, content: string) =
  ## Write and flush to stable storage before the rename that publishes it.
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open '" & path & "' for writing: " &
                       osErrorMsg(osLastError()))
  try:
    f.write(content)
    f.flushFile()
    when not defined(windows):
      if fsync(getFileHandle(f)) != 0:
        raise newException(IOError, "fsync of '" & path & "' failed: " &
                           osErrorMsg(osLastError()))
  finally:
    f.close()

proc renameInto(temporary, final: string) =
  ## The atomic step. ``moveFile`` is ``rename(2)`` on POSIX (replacing an
  ## existing target atomically) and ``MoveFileEx`` with
  ## ``MOVEFILE_REPLACE_EXISTING`` on Windows.
  moveFile(temporary, final)

proc touchDirectory(dir: string) =
  ## Mark a content directory as written now. A rename into it does this by
  ## itself; a publish that KEPT an existing file has to say so, or a content
  ## that was just re-tested would look old to the pruner.
  try:
    setLastModificationTime(dir, getTime())
  except OSError:
    discard

proc directoryIdentity(dir: string): string =
  ## Device and file number of ``dir``, or ``""`` when there is none: tells
  ## the directory a write went into from one recreated at the same path.
  try:
    let info = getFileInfo(dir)
    $info.id.device & ":" & $info.id.file
  except OSError:
    ""

proc publishRecord*(root, relative, document: string; signed: bool;
                    beforeRename: PublishStepHook = nil):
    tuple[kept, retried: bool; error: string] =
  ## Steps 1-3 of §2.3, with the one retry §2.5 allows when a concurrent
  ## prune removed the directory between creating it and renaming into it.
  ## The bare write: no root resolution, no working-tree guard, no prune —
  ## ``publishToLocalStore`` is the entry point; this is exported so the
  ## retry can be raced in a tight loop by the suite.
  ##
  ## One retry is enough because a prune removes a directory by renaming it
  ## aside first (``pruneLocalStore``): a failure here means that rename has
  ## already happened, so the retry writes into a directory created after
  ## it, which that removal can no longer touch — and which no later prune
  ## takes, since it is modified within ``FreshDirectoryAge`` and then holds
  ## a fresh temporary file.
  let final = root / toNative(relative)
  let dir = final.parentDir
  let contentDir = relative[0 ..< relative.rfind('/')]
  for attempt in 0 .. 1:
    # A prune that chose this directory a moment before the temporary file
    # appeared can still remove it: it renames the directory aside, taking
    # the temporary file with it. A failure after the temporary file the
    # writer created vanished from its path, or while the directory is gone
    # or is no longer the one this attempt wrote into (another producer may
    # already have recreated it), is that race, and gets the retry.
    var temporaryVanished = false
    var identity = directoryIdentity(dir)
    try:
      createOwnerOnlyDirs(root, contentDir)
      identity = directoryIdentity(dir)
      if not signed and fileExists(final):
        touchDirectory(dir)
        return (true, attempt > 0, "")
      let temporary = dir / temporaryName(final.extractFilename)
      var created = false
      try:
        writeFlushed(temporary, document)
        created = true
        if beforeRename != nil:
          beforeRename(attempt)
        renameInto(temporary, final)
      except CatchableError:
        temporaryVanished = created and not fileExists(temporary)
        try: removeFile(temporary)
        except CatchableError: discard
        raise
      return (false, attempt > 0, "")
    except CatchableError as err:
      let now = directoryIdentity(dir)
      if attempt == 0 and (temporaryVanished or now.len == 0 or
                           now != identity):
        continue
      return (false, attempt > 0, err.msg)
  (false, true, "the content directory disappeared twice while it was written")

# ---------------------------------------------------------------------------
# Pruning (Transport.md §2.5)
# ---------------------------------------------------------------------------

proc beingWritten(dir: string; now: Time): bool =
  ## Whether a producer is writing into ``dir``: it was modified within
  ## ``FreshDirectoryAge``, or it holds a temporary file younger than
  ## ``StaleTemporaryAge``.
  try:
    if now - getLastModificationTime(dir) < FreshDirectoryAge:
      return true
  except OSError:
    return true
  try:
    for kind, path in walkDir(dir):
      let name = path.extractFilename
      if name.startsWith(".") and TemporaryMarker in name:
        try:
          if now - getLastModificationTime(path) < StaleTemporaryAge:
            return true
        except OSError:
          # Vanished between the listing and the stat: renamed into place a
          # moment ago, which is a write in progress too.
          return true
  except OSError:
    return true
  false

var removalCounter: Atomic[int]
  ## Process-wide, not per thread: two prunes on two threads of one process
  ## must never pick the same aside name for the same digest.

proc removalName(digest: string): string =
  "." & digest & RemovalMarker & $getCurrentProcessId() & "-" &
    $(removalCounter.fetchAdd(1) + 1)

proc renameAside(path, aside: string) =
  ## One ``rename(2)`` / ``MoveFileExW`` of a directory within its parent,
  ## and nothing else. ``moveDir`` would fall back to copying and deleting
  ## when the rename is refused, which is neither atomic nor wanted: Windows
  ## refuses exactly when a file inside is open — when a writer is in it.
  when defined(windows):
    if moveFileExW(newWideCString(path), newWideCString(aside), 0'i32) == 0:
      raiseOSError(osLastError(), path)
  else:
    if c_rename(path.cstring, aside.cstring) != 0:
      raiseOSError(osLastError(), path)

proc pruneLocalStore*(root: string; keep: int;
                      protected: openArray[string];
                      onStep: PruneStepHook = nil): PruneOutcome =
  ## Remove whole content directories from one root, keeping the ``keep``
  ## most recently written (directory modification time; ties broken by
  ## name, newest-looking first) plus every directory in ``protected``
  ## (store-relative ``v1/<algorithm>/<digest>`` paths).
  ##
  ## Never removes a directory a producer is writing into. Never fails the
  ## publish: a directory that cannot be removed is reported in ``errors``.
  ##
  ## A directory leaves the store in ONE atomic step — renamed aside within
  ## its parent (``RemovalMarker``) — and is deleted only after that. A
  ## writer that entered it between the check and the rename loses its
  ## rename and retries into a fresh directory, which this removal cannot
  ## reach. Directories left aside by a prune that died mid-delete are
  ## deleted by the next prune.
  let layout = root / LocalStoreLayout
  if not dirExists(layout):
    return
  var dirs: seq[tuple[relative: string; mtime: Time]] = @[]
  try:
    for algorithmKind, algorithmPath in walkDir(layout):
      if algorithmKind != pcDir:
        continue
      for digestKind, digestPath in walkDir(algorithmPath):
        if digestKind != pcDir:
          continue
        let digestName = digestPath.extractFilename
        if digestName.startsWith("."):
          if RemovalMarker in digestName:
            # Renamed aside by a prune that has not finished deleting it, or
            # never will. Another prune deleting it at the same time is
            # harmless: each tolerates entries the other already removed.
            try:
              removeDir(digestPath)
            except OSError as err:
              if dirExists(digestPath):
                result.errors.add "'" & digestPath &
                  "' could not be removed: " & err.msg
          continue
        let relative = LocalStoreLayout & "/" &
          algorithmPath.extractFilename & "/" & digestPath.extractFilename
        var mtime: Time
        try:
          mtime = getLastModificationTime(digestPath)
        except OSError:
          continue                      # gone already
        dirs.add (relative, mtime)
  except OSError as err:
    result.errors.add "the store at '" & layout & "' could not be listed: " &
      err.msg
    return
  dirs.sort(proc(a, b: tuple[relative: string; mtime: Time]): int =
    if a.mtime != b.mtime:
      return (if a.mtime > b.mtime: -1 else: 1)
    -cmp(a.relative, b.relative))
  let now = getTime()
  for i, entry in dirs:
    if i < keep or entry.relative in protected:
      continue
    let path = root / toNative(entry.relative)
    if beingWritten(path, now):
      continue
    if onStep != nil:
      onStep(psChosen, entry.relative)
    let aside = path.parentDir / removalName(path.extractFilename)
    try:
      renameAside(path, aside)
    except OSError as err:
      if dirExists(path):
        # Windows refuses to rename a directory with a file open inside:
        # a writer is in it, and it stays.
        result.errors.add "'" & path & "' could not be removed: " & err.msg
      continue                          # else another prune took it first
    result.removed.add entry.relative
    if onStep != nil:
      onStep(psDetached, entry.relative)
    try:
      removeDir(aside)
    except OSError as err:
      result.errors.add "'" & aside & "' could not be removed: " & err.msg

# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

proc isInside(path, ancestor: string): bool =
  ## Whether ``path`` is ``ancestor`` or below it, after resolving symbolic
  ## links in whatever prefix of each exists.
  proc resolved(p: string): string =
    var existing = absolutePath(p).normalizedPath
    var suffix: seq[string] = @[]
    while existing.len > 0 and not dirExists(existing) and
          not fileExists(existing):
      let parent = existing.parentDir
      if parent == existing:
        break
      suffix.insert(existing.extractFilename, 0)
      existing = parent
    try:
      existing = expandSymlink(existing)
    except OSError:
      discard
    try:
      existing = existing.expandFilename
    except OSError:
      discard
    for part in suffix:
      existing = existing / part
    existing
  let p = resolved(path)
  let a = resolved(ancestor)
  p == a or p.startsWith(a & DirSep)

proc repositoryToplevel(workspaceRoot: string): string =
  ## The repository's top level, or ``""`` when there is none.
  let host = nativeContentIdHost()
  let reply = host.git(GitCall(
    argv: @["git", "rev-parse", "--show-toplevel"], cwd: workspaceRoot,
    env: @[("GIT_OPTIONAL_LOCKS", "0")]))
  if reply.exitCode != 0 or not reply.complete:
    return ""
  reply.stdout.strip()

proc headContentDir(workspaceRoot, algorithm: string): string =
  ## The store-relative directory of the current repository's ``HEAD^{tree}``
  ## in ``algorithm``, or ``""`` when there is none (an unborn branch, an
  ## algorithm git cannot compute here).
  let (known, parsed) = lookupAlgorithm(algorithm)
  if not known:
    return ""
  let computed = computeContentId(nativeContentIdHost(), workspaceRoot,
                                  commitState("HEAD"), parsed)
  if computed.outcome != cioComputed:
    return ""
  let dir = localStoreContentDir(computed.id)
  if dir.ok: dir.relative else: ""

proc publishToLocalStore*(roots: CertificateStoreRoots; workspaceRoot: string;
                          document: string;
                          keep = DefaultRetention): PublishOutcome =
  ## Publish one issued certificate to the user root of ``roots`` and prune
  ## that root (Transport.md §2.3, §2.5).
  ##
  ## ``workspaceRoot`` is the repository the tests ran in: the root must not
  ## lie inside it, and its ``HEAD^{tree}`` directory survives the prune.
  ## Whether the record is signed — which decides between replacing and
  ## keeping an existing file of the same name — is read from the document
  ## itself, not taken from the caller.
  if not roots.available or roots.user.len == 0:
    result.error = "the local certificate store's user root could not be " &
      "resolved" &
      (if roots.problems.len > 0: ": " & roots.problems.join("; ") else: "")
    return
  result.root = roots.user
  let (relative, signed) = readForStore(document)
  if relative.error.len > 0:
    result.error = relative.error
    return
  result.path = roots.user / toNative(relative.path)

  let toplevel = repositoryToplevel(workspaceRoot)
  for tree in [workspaceRoot, toplevel]:
    if tree.len > 0 and isInside(roots.user, tree):
      result.error = "the local certificate store's user root '" & roots.user &
        "' is inside the repository at '" & tree & "', and a certificate " &
        "never belongs in the working tree it attests (Transport.md §2); " &
        "point TEST_CERTIFICATES_DIR outside the repository"
      return

  let published = publishRecord(roots.user, relative.path, document, signed)
  if published.error.len > 0:
    result.retried = published.retried
    result.error = published.error
    return
  result.retried = published.retried
  result.written = true
  result.kept = published.kept

  let contentDir = relative.path[0 ..< relative.path.rfind('/')]
  var protected = @[contentDir]
  let algorithm = contentDir.split('/')[1]
  let head = headContentDir(workspaceRoot, algorithm)
  if head.len > 0:
    protected.add head
  result.pruned = pruneLocalStore(roots.user, keep, protected)
