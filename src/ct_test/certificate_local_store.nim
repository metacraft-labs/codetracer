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
## * **Writing (§2.3).** An existing user root must be owned by this
##   process's effective account, checked (by the reference library) before
##   ANY mutation, the `.write-lock` included; a foreign root is refused and
##   never adopted or repaired. Owner-only (`0700`) directories hold atomic,
##   flushed renames of `0600` record files, whatever the umask. Every writer holds the root's persistent `.write-lock` through
##   inspecting and publishing. Unsigned copies keep an existing record;
##   relayed signed copies replace only a well-formed unsigned twin. Only a
##   caller that made the new signature can replace an existing signed copy.
## * **Prune (§2.5).** On publish only, by the reference library's
##   ``pruneRoot``: whole content directories, keeping the ``keep`` most
##   recently written (by the directory's modification time, which a rename
##   into it updates) plus the one just written into and every HEAD content
##   id the library's ``pruneProtection`` computes — unscoped and in each
##   scope the repository declares (Tooling.md §3.1), in the native
##   ``git-tree-*`` algorithm and ``manifest-v1-sha256``. When those ids
##   cannot be computed for an existing HEAD, nothing is pruned at all. A directory a
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

import std/[os, strutils, times]

# The reference library (test-certificates-tools, Nim package
# `test_certificates`), linked for the rules it implements byte for byte:
# pruning (Transport.md §2.5), the HEAD protection a prune computes over
# declared scopes (Tooling.md §3.1) and the user-root ownership check (§2.3).
# Imported QUALIFIED ONLY: its names (`PruneStage`, `parseContentId`, …)
# overlap this module's and `certificate_content_id`'s, and an unqualified
# import would let an overload silently pick the other one.
from test_certificates/prune as tcprune import nil
from test_certificates/scopes as tcscopes import nil
from test_certificates/layout as tclayout import nil

when defined(windows):
  import std/winlean
  from test_certificates/windows_owner as tcowner import nil
else:
  import std/posix except Time
  from test_certificates/permissions as tcperm import nil
  var storeNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  var storeOpenDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

import certificate
import certificate_content_id
import certificate_content_id_native
import certificate_store
import certificate_store_roots_native

export certificate_store_roots_native

const
  DefaultRetention* = tcprune.DefaultKeep
    ## The reference policy's number of content directories kept
    ## (Transport.md §2.5).

  StaleTemporaryAge* = tcprune.StaleTemporaryAge
    ## A temporary file older than this belongs to a writer that died, not to
    ## one that is writing. Without an age a crashed run would pin its content
    ## directory against pruning forever.

  FreshDirectoryAge* = tcprune.FreshDirectoryAge
    ## A content directory modified more recently than this is treated as
    ## being written into, whether or not its temporary file exists yet: a
    ## writer creates the directory a moment BEFORE it opens the temporary
    ## file.

  TemporaryMarker* = tclayout.TemporaryMarker
    ## Part of every temporary name, after the leading ``.``.

  RemovalMarker* = tclayout.RemovalMarker
    ## Part of the name a content directory is renamed to while a prune
    ## deletes it: ``.<digest>.removing-<pid>-<counter>``.

  UserRecordFileMode = 0o600
    ## A record file in the user root (Transport.md §2.3 step 1): readable and
    ## writable by its owner only, WHATEVER THE UMASK. Set with ``fchmod``
    ## after creation rather than left to ``open``'s mode argument, which the
    ## umask can only narrow and which ``std/syncio``'s ``0666`` default would
    ## otherwise leave as ``0644`` under an ordinary umask.

type
  LocalStorePath* = tuple[path: string; error: string]
    ## A ``/``-separated store-relative path, or why there is none.

  PruneOutcome* = object
    removed*: seq[string]
      ## Content directories removed, store-relative (``v1/<alg>/<digest>``).
    errors*: seq[string]
      ## Directories that could not be removed, with the reason — or, when a
      ## prune did not run at all, why. Never fatal: pruning is a matter of
      ## disk space, not of correctness (§2.5).

  PruneStage* = enum
    ## The points of one directory's removal a ``PruneStepHook`` observes —
    ## the library's ``tcprune.PruneStage``, renamed for this module's callers.
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
      ## An unsigned copy or signed relay kept the existing record (§2.3).
      ## ``written`` is ``true`` too.
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
  ## Create ``path`` (a fresh temporary name: it must not exist), write
  ## ``content`` and flush it to stable storage before the rename that
  ## publishes it. On POSIX the file is ``0600`` (``UserRecordFileMode``)
  ## before a byte of the record is written, whatever the umask (§2.3).
  when defined(windows):
    var f: File
    if not open(f, path, fmWrite):
      raise newException(IOError, "cannot open '" & path & "' for writing: " &
                         osErrorMsg(osLastError()))
    try:
      f.write(content)
      f.flushFile()
    finally:
      f.close()
  else:
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or
      O_CLOEXEC or storeNoFollow, Mode(UserRecordFileMode))
    if fd < 0:
      raise newException(IOError, "cannot create '" & path & "': " &
                         osErrorMsg(osLastError()))
    var f: File
    if not open(f, fd, fmWrite):
      discard posix.close(fd)
      raise newException(IOError, "cannot open '" & path & "' for writing: " &
                         osErrorMsg(osLastError()))
    try:
      if fchmod(fd, Mode(UserRecordFileMode)) != 0:
        raise newException(IOError, "cannot make '" & path & "' owner-only: " &
                           osErrorMsg(osLastError()))
      f.write(content)
      f.flushFile()
      if fsync(fd) != 0:
        raise newException(IOError, "fsync of '" & path & "' failed: " &
                           osErrorMsg(osLastError()))
    finally:
      f.close()

proc userRootOwnerProblem*(root: string): string =
  ## "" when ``root`` does not exist yet or is owned by this process's
  ## EFFECTIVE account; otherwise why it must not be touched. Transport.md
  ## §2.3: "An existing user root MUST be owned by the writer's effective
  ## account … refuse and report a root owned by another account, even when
  ## that root is writable by the caller." The check is the reference
  ## library's — ``fstat`` of the OPENED directory against ``geteuid`` on
  ## POSIX, the directory's owner SID against the effective token's user on
  ## Windows — so an owner that cannot be read is a refusal, never permission.
  if not dirExists(root) and not symlinkExists(root) and not fileExists(root):
    return ""
  when defined(windows):
    tcowner.checkUserRootOwner(root)
  else:
    let fd = posix.open(root.cstring, O_RDONLY or storeOpenDirectory or O_CLOEXEC)
    if fd < 0:
      return "could not open the store root '" & root & "' to check its " &
        "owner: " & osErrorMsg(osLastError())
    defer: discard posix.close(fd)
    tcperm.checkOwner(fd, root)

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

# Writers in every implementation share this persistent root lock (Transport
# §2.3). Never unlink it: another process may already hold its inode open.
when defined(windows):
  proc storeCreateFile(path: WideCString; access, share: uint32; security: pointer;
                       disposition, flags: uint32; templateFile: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc storeCloseHandle(handle: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc storeLastError(): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
  type StoreWriteLock = pointer
else:
  proc storeFlock(fd, operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
  type StoreWriteLock = cint

proc acquireStoreWriteLock(root: string): StoreWriteLock =
  let path = root / ".write-lock"
  when defined(windows):
    while true:
      result = storeCreateFile(newWideCString(path), 0xC0000000'u32, 0,
        nil, 4, 0x80, nil)
      if result != cast[pointer](-1): return
      let error = storeLastError()
      if error != 32: raiseOSError(OSErrorCode(error), path)
      sleep(10)
  else:
    result = posix.open(path.cstring, O_RDWR or O_CREAT or storeNoFollow or
      O_CLOEXEC, Mode(0o600))
    if result < 0: raiseOSError(osLastError(), path)
    while storeFlock(result, 2) != 0: # LOCK_EX
      if errno == EINTR: continue
      let error = osLastError()
      discard posix.close(result)
      raiseOSError(error, path)

proc releaseStoreWriteLock(lock: StoreWriteLock) =
  when defined(windows):
    discard storeCloseHandle(lock)
  else:
    discard posix.close(lock)

proc publishRecord*(root, relative, document: string; signed: bool;
                    beforeRename: PublishStepHook = nil; signatureMade = false):
    tuple[kept, retried: bool; error: string] =
  ## Steps 1-3 of §2.3, with the one retry §2.5 allows when a concurrent
  ## prune removed the directory between creating it and renaming into it.
  ## The bare write: no root resolution, no working-tree guard, no prune —
  ## ``publishToLocalStore`` is the entry point; this is exported so the
  ## retry can be raced in a tight loop by the suite.
  ## ``signatureMade`` is true only for the immediate signing producer.
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
  # Before ANY mutation — creating the root's `.write-lock` included — an
  # existing root must be this account's (Transport.md §2.3). A foreign root
  # is reported and left exactly as it was: never adopted, never repaired.
  let ownerProblem = userRootOwnerProblem(root)
  if ownerProblem.len > 0:
    return (false, false, "refusing to write the certificate store: " &
                          ownerProblem)
  var writeLock: StoreWriteLock
  try:
    createOwnerOnlyDirs(root, "")
    writeLock = acquireStoreWriteLock(root)
  except CatchableError as err:
    return (false, false, err.msg)
  defer: releaseStoreWriteLock(writeLock)
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
      if symlinkExists(final) or dirExists(final):
        raise newException(IOError, "existing certificate is not a regular file")
      var keepExisting = false
      if fileExists(final):
        if not signatureMade:
          let existing = readCertificate(readFile(final))
          if existing.status != crsOk:
            raise newException(IOError, "existing certificate is malformed: " &
              existing.detail)
          let existingPath = localStoreRelativePath(existing.cert)
          if existingPath.error.len > 0 or existingPath.path != relative:
            raise newException(IOError, "existing certificate does not match its store name")
          keepExisting = not signed or existing.cert.isSigned
        elif not signed:
          keepExisting = true
      if keepExisting:
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


proc pruneLocalStore*(root: string; keep: int;
                      protected: openArray[string];
                      onStep: PruneStepHook = nil): PruneOutcome =
  ## Remove whole content directories from one root, keeping the ``keep``
  ## most recently written plus every directory in ``protected``
  ## (store-relative ``v1/<algorithm>/<digest>`` paths).
  ##
  ## The removal is the reference library's ``pruneRoot``
  ## (test-certificates-tools), linked rather than re-implemented so it
  ## cannot drift from the helper every other producer uses: a directory a
  ## producer is writing into (modified within ``FreshDirectoryAge``, or
  ## holding a temporary file younger than ``StaleTemporaryAge``) is never
  ## removed; a directory leaves the store in ONE atomic step — renamed aside
  ## within its parent — and is deleted only after; the leftovers of a prune
  ## that died are deleted; and an existing root owned by another account is
  ## refused before anything is renamed or deleted (Transport.md §2.5). This
  ## wrapper only translates this module's directory-shaped protection and
  ## step hook into the library's content-id-shaped ones.
  ##
  ## Never fails the publish: what could not be removed is in ``errors``.
  if root.len == 0:
    return
  var ids: seq[string] = @[]
  for dir in protected:
    let parts = dir.split('/')
    if parts.len == 3 and parts[0] == LocalStoreLayout:
      ids.add parts[1] & ":" & parts[2]
  let hook: tcprune.PruneStepHook =
    if onStep == nil: nil
    else:
      proc(stage: tcprune.PruneStage; relative: string) =
        onStep(if stage == tcprune.psChosen: psChosen else: psDetached,
               relative)
  let pruned = tcprune.pruneRoot(root, keep, ids, onStep = hook)
  result.removed = pruned.removed
  result.errors = pruned.errors

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

proc headPruneProtection*(repository: string):
    tuple[ok: bool; dirs: seq[string]; problem: string] =
  ## The content directories a prune of the user root must keep for
  ## ``repository`` (Transport.md §2.5): ``HEAD``'s content in the
  ## repository's native ``git-tree-*`` algorithm AND ``manifest-v1-sha256``,
  ## unscoped and in every scope the repository DECLARES (Tooling.md §3.1,
  ## ``[testCertificatesScope "<name>"] path = …``), all computed from one
  ## frozen ``HEAD`` tree by the reference library's ``pruneProtection``.
  ##
  ## ``ok`` with no ``dirs``: nothing to protect — no repository, or an
  ## unborn branch. ``ok = false``: ``HEAD`` exists and one of its ids could
  ## not be computed, or the scope declaration is invalid; the caller MUST
  ## then not prune at all, since pruning without that protection could
  ## delete the certificates of the very content checked out (§2.5).
  if repository.len == 0:
    return (true, @[], "")
  let protection = tcscopes.pruneProtection(repository)
  if not protection.ok:
    return (false, @[], protection.problem)
  result.ok = true
  for id in protection.ids:
    let dir = localStoreContentDir(id)
    if not dir.ok:
      return (false, @[], "HEAD content id '" & id & "' names no store " &
        "directory: " & dir.problem)
    if dir.relative notin result.dirs:
      result.dirs.add dir.relative

proc publishToLocalStore*(roots: CertificateStoreRoots; workspaceRoot: string;
                          document: string;
                          keep = DefaultRetention; signatureMade = false): PublishOutcome =
  ## Publish one issued certificate to the user root of ``roots`` and prune
  ## that root (Transport.md §2.3, §2.5).
  ##
  ## ``workspaceRoot`` is the repository the tests ran in: the root must not
  ## lie inside it, and its HEAD content directories (``headPruneProtection``:
  ## unscoped and every declared scope, in each computed algorithm) survive
  ## the prune — which does not run at all when they cannot be computed.
  ## Signedness is read from the document. This defaults to a relay, which
  ## upgrades only an unsigned twin. ``signatureMade`` may be true only when
  ## this caller made the incoming signature.
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

  let published = publishRecord(roots.user, relative.path, document, signed,
    signatureMade = signatureMade)
  if published.error.len > 0:
    result.retried = published.retried
    result.error = published.error
    return
  result.retried = published.retried
  result.written = true
  result.kept = published.kept

  let protection = headPruneProtection(workspaceRoot)
  if not protection.ok:
    # Transport.md §2.5: a failure computing a required id for an existing
    # HEAD aborts pruning before anything is removed — leftovers of an
    # interrupted prune included. The certificate was still delivered; only
    # the bounding of the store waits for a run that can compute what to keep.
    result.pruned.errors.add "the local certificate store was not pruned: " &
      "the content ids of HEAD could not be computed: " & protection.problem
    return
  var protected = @[relative.path[0 ..< relative.path.rfind('/')]]
  for dir in protection.dirs:
    if dir notin protected:
      protected.add dir
  result.pruned = pruneLocalStore(roots.user, keep, protected)
