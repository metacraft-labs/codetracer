## The project store — Noir-Studio.md §4, and NS2's central deliverable.
##
## A directory tree the user owns that survives reloads and crashes: sources,
## `Nargo.toml`, tests, inputs and build outputs. Built over `StoreVolume`
## (OPFS in a tab, in memory when there is no OPFS) and presented to the front
## end as a `FileSystemFacade` by `web_platform.nim`.
##
## ## What this module adds over the volume, and why each is here
##
## | Added | Spec | Why the volume cannot do it |
## | --- | --- | --- |
## | Schema version, migrated or refused | §4.5 | A version is a store concept |
## | Per-file write-temp-then-replace | §4.4 | OPFS's `createWritable` truncates the target *first* |
## | Quota headroom before a large write | §4.4 | Needs to know how large "large" is |
## | One writer per project | §4.3 | Needs a lock record and a takeover protocol |
## | Durability tiers and the announcement | §4.1, §4.2 | The volume knows `durable`; the product owes a sentence |
## | Build outputs discarded on doubt | §4.4 | Needs the path classification in `store_schema` |
##
## ## The one thing it deliberately does NOT add
##
## **No journal.** §4.4: "the transaction format is *per-file atomic replace*,
## plus the guarantees git already provides — not a journal we design, debug
## and migrate." There is no log file, no transaction id and no replay-on-open.
## A write that did not finish leaves a file in `tmp/`, and `tmp/` is emptied on
## open because §4.4 classifies anything there as a write that did not complete.
##
## ## Why OPFS's `createWritable` forces the temp file rather than merely
## ## suggesting it
##
## Worth stating because it is the mechanism the whole atomicity claim rests
## on. `FileSystemFileHandle.createWritable()` defaults to
## `keepExistingData: false` — the target is emptied when the writable opens,
## before a single byte is written. So a tab closed between `createWritable`
## and `close` leaves an EMPTY file where the user's source was. Writing to
## `tmp/<n>` and then moving is not belt-and-braces; without it §4.4's "the
## previous contents survive any failure" is false on the platform NS2 is for.

import std/tables

import ./outcome
import ./store_volume
import ./store_schema
import ./store_durability

export outcome, store_volume, store_schema, store_durability

type
  WriterRole* = enum
    ## §4.3: "A project has exactly one writer. The holder takes a named lock;
    ## a second tab opens the project **read-only** and offers an explicit
    ## takeover."
    wrOwner
    wrReadOnly
    wrRelinquished
      ## We held the lock and someone took it over. Distinct from `wrReadOnly`
      ## because the UI owes a different sentence — "another tab took over" is
      ## news, "this tab is read-only" is a state — and because a relinquished
      ## writer must not silently re-acquire.

  ProjectLock* = object
    generation*: int
      ## Bumped by every acquisition. This is what makes takeover *clean*
      ## rather than last-writer-wins: the previous holder's generation no
      ## longer matches, so its next write is refused instead of interleaved.
    ownerId*: string
    sinceMs*: int64

  StoreSession* = ref object
    ## One tab's view of the store. Two of these over one volume is two tabs,
    ## which is exactly how `test_a_second_tab_cannot_corrupt_the_store` is
    ## driven without a browser.
    volume*: StoreVolume
    ownerId*: string
      ## Identifies this tab. Minted by the caller — `web_platform.nim` uses a
      ## random value per page load — and never derived from anything stable,
      ## because a stable id would make a reloaded tab indistinguishable from a
      ## second one.
    metadata*: StoreMetadata
    durability*: DurabilityReport
    announcementAcknowledged: bool
    openDecision*: StoreOpenDecision
    heldLocks: Table[string, ProjectLock]
    tempCounter: int
    everExported*: Table[string, bool]

  ProjectOpen* = object
    ## The answer to "open this project", which is not a yes/no.
    projectId*: string
    role*: WriterRole
    heldBy*: string
      ## Set when `role` is `wrReadOnly`: who holds the lock. Shown so the
      ## takeover offer names something rather than being a bare button.
    lock*: ProjectLock

const
  storeTempPrefix = "w"

# ---------------------------------------------------------------------------
# The lock record, in the same frozen-first-line style as the store descriptor
# ---------------------------------------------------------------------------

const lockMagic = "codetracer-lock"

proc encodeLock(lock: ProjectLock): string =
  var generation = ""
  var g = lock.generation
  if g == 0: generation = "0"
  else:
    var digits = ""
    while g > 0:
      digits.add chr(ord('0') + (g mod 10))
      g = g div 10
    for i in countdown(digits.len - 1, 0): generation.add digits[i]
  lockMagic & " " & generation & "\n" & "owner " & lock.ownerId & "\n"

proc decodeLock(text: string): ProjectLock =
  ## A lock record that does not parse is a lock nobody holds. That is the safe
  ## reading and not a shortcut: the failure mode of misreading garbage as a
  ## held lock is a project that can never be opened for writing again, with no
  ## way out except clearing browser storage.
  result = ProjectLock(generation: 0, ownerId: "")
  var lines: seq[string] = @[]
  var current = ""
  for c in text:
    if c == '\n':
      lines.add current
      current = ""
    elif c != '\r':
      current.add c
  lines.add current
  if lines.len == 0: return
  let head = lines[0]
  if head.len <= lockMagic.len + 1: return
  if head[0 ..< lockMagic.len] != lockMagic: return
  var generation = 0
  for c in head[lockMagic.len + 1 .. ^1]:
    if c < '0' or c > '9': return
    generation = generation * 10 + (ord(c) - ord('0'))
  result.generation = generation
  for line in lines:
    if line.len > 6 and line[0 ..< 6] == "owner ":
      result.ownerId = line[6 .. ^1]

proc toBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = text[i].byte

proc toText(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = bytes[i].char

# ---------------------------------------------------------------------------
# Opening the store
# ---------------------------------------------------------------------------

proc openStore*(volume: StoreVolume; ownerId: string;
                persistenceGranted, persistenceAnswered: bool;
                nowMs: int64): PlatformFuture[PlatformOutcome[StoreSession]] =
  ## §4.5's decision, then at most one write.
  ##
  ## The read of the descriptor is allowed to fail with `pkNotFound` — that is
  ## the first-visit case — and every other failure is reported rather than
  ## treated as "fresh", because opening a store we could not read as though it
  ## were empty is how an existing project gets overwritten.
  let condition = conditionFor(volume, persistenceGranted, persistenceAnswered)

  proc build(decision: StoreOpenDecision): StoreSession =
    StoreSession(
      volume: volume,
      ownerId: ownerId,
      metadata: decision.metadata,
      durability: durabilityReport(condition),
      announcementAcknowledged: false,
      openDecision: decision,
      heldLocks: initTable[string, ProjectLock](),
      tempCounter: 0,
      everExported: initTable[string, bool]())

  proc finish(decision: StoreOpenDecision
             ): PlatformFuture[PlatformOutcome[StoreSession]] =
    if decision.verdict.refuses:
      # NOT A SINGLE BYTE IS WRITTEN. `test_an_unrecognised_store_version_is_refused_not_rewritten`
      # asserts the volume's write count is unchanged across this path, which
      # is a stronger check than asserting the descriptor still parses.
      return resolvedErr[StoreSession](pkConflict, decision.explanation)
    let session = build(decision)
    let encoded = toBytes(encodeStoreMetadata(decision.metadata))
    thenOutcome(volume.writeBytes(storeMetadataPath, encoded),
      proc(ignored: Nothing): PlatformFuture[PlatformOutcome[StoreSession]] =
        resolvedOk(session))

  let read = volume.readBytes(storeMetadataPath)

  proc onMissing(error: PlatformError
                ): PlatformFuture[PlatformOutcome[seq[byte]]] =
    if error.kind == pkNotFound: resolvedOk(newSeq[byte](0))
    else: resolved(failed[seq[byte]](error))

  var sawDescriptor = true
  proc probe(error: PlatformError): PlatformFuture[PlatformOutcome[seq[byte]]] =
    if error.kind == pkNotFound: sawDescriptor = false
    onMissing(error)

  thenOutcome(recoverOutcome(read, probe),
    proc(bytes: seq[byte]): PlatformFuture[PlatformOutcome[StoreSession]] =
      finish(decideStoreOpen(sawDescriptor, toText(bytes), nowMs)))

proc readyForEditing*(session: StoreSession): bool =
  ## §4.2: the in-memory case "**says so before the first keystroke** rather
  ## than discovered on close".
  ##
  ## Modelled as a gate rather than as a notification, because a notification
  ## is something a view can forget to render and a gate is not. Nothing that
  ## can create a keystroke's worth of work is reachable until this is true,
  ## and it is only true once the announcement has been shown and
  ## acknowledged. Where there is no announcement — persistence granted — it is
  ## true immediately, so the normal path costs nothing.
  (not session.durability.mustAnnounceBeforeEditing) or
    session.announcementAcknowledged

proc acknowledgeDurability*(session: StoreSession) =
  ## Called by the view that showed `session.durability.announcement`. Named so
  ## that a call site which has not shown anything reads as a lie.
  session.announcementAcknowledged = true

proc announcement*(session: StoreSession): string =
  session.durability.announcement

# ---------------------------------------------------------------------------
# One writer per project — §4.3
# ---------------------------------------------------------------------------

proc readLock(session: StoreSession; projectId: string
             ): PlatformFuture[PlatformOutcome[ProjectLock]] =
  proc absent(error: PlatformError): PlatformFuture[PlatformOutcome[seq[byte]]] =
    if error.kind == pkNotFound: resolvedOk(newSeq[byte](0))
    else: resolved(failed[seq[byte]](error))
  mapOutcome(
    recoverOutcome(session.volume.readBytes(projectLockPath(projectId)), absent),
    proc(bytes: seq[byte]): ProjectLock = decodeLock(toText(bytes)))

proc writeLock(session: StoreSession; projectId: string; lock: ProjectLock
              ): PlatformFuture[PlatformOutcome[Nothing]] =
  session.volume.writeBytes(projectLockPath(projectId),
                            toBytes(encodeLock(lock)))

proc claim(session: StoreSession; projectId: string; previous: ProjectLock;
           nowMs: int64): PlatformFuture[PlatformOutcome[ProjectOpen]] =
  let lock = ProjectLock(
    generation: previous.generation + 1,
    ownerId: session.ownerId,
    sinceMs: nowMs)
  thenOutcome(session.writeLock(projectId, lock),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[ProjectOpen]] =
      session.heldLocks[projectId] = lock
      resolvedOk(ProjectOpen(
        projectId: projectId, role: wrOwner, heldBy: session.ownerId,
        lock: lock)))

proc openProject*(session: StoreSession; projectId: string; nowMs: int64
                 ): PlatformFuture[PlatformOutcome[ProjectOpen]] =
  ## Acquire the writer role if it is free, otherwise open read-only.
  ##
  ## There is deliberately **no staleness timeout**. A lock whose holder died
  ## without releasing it would, under a timeout, be silently stolen after N
  ## seconds — which is last-writer-wins with a delay, the thing §4.3 rules
  ## out. The recovery is `takeOverProject`, which is a user action, and the
  ## read-only tab says who holds it so the action is informed rather than
  ## blind.
  thenOutcome(session.readLock(projectId),
    proc(existing: ProjectLock): PlatformFuture[PlatformOutcome[ProjectOpen]] =
      if existing.generation == 0:
        return session.claim(projectId, existing, nowMs)
      if existing.ownerId == session.ownerId:
        # Our own lock, from earlier in this session. Re-entrant, and NOT a
        # generation bump: bumping here would invalidate a write we are in the
        # middle of issuing.
        session.heldLocks[projectId] = existing
        return resolvedOk(ProjectOpen(
          projectId: projectId, role: wrOwner, heldBy: session.ownerId,
          lock: existing))
      session.heldLocks.del(projectId)
      resolvedOk(ProjectOpen(
        projectId: projectId, role: wrReadOnly, heldBy: existing.ownerId,
        lock: existing)))

proc takeOverProject*(session: StoreSession; projectId: string; nowMs: int64
                     ): PlatformFuture[PlatformOutcome[ProjectOpen]] =
  ## The explicit takeover §4.3 requires. Bumps the generation, which is what
  ## the previous holder's next write will notice.
  thenOutcome(session.readLock(projectId),
    proc(existing: ProjectLock): PlatformFuture[PlatformOutcome[ProjectOpen]] =
      session.claim(projectId, existing, nowMs))

proc releaseProject*(session: StoreSession; projectId: string
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Relinquish cleanly. Removes the record rather than blanking it, so the
  ## next opener takes generation 1 and no state accumulates.
  if not session.heldLocks.hasKey(projectId):
    return resolvedOk()
  session.heldLocks.del(projectId)
  proc alreadyGone(error: PlatformError
                  ): PlatformFuture[PlatformOutcome[Nothing]] =
    if error.kind == pkNotFound: resolvedOk()
    else: resolved(failed[Nothing](error))
  recoverOutcome(
    session.volume.remove(projectLockPath(projectId), false), alreadyGone)

proc writerRole*(session: StoreSession; projectId: string): WriterRole =
  ## What this tab believes it is. The belief is re-checked against the volume
  ## before every write; this is the cheap answer for a view that has to render
  ## a read-only banner on every frame.
  if session.heldLocks.hasKey(projectId): wrOwner else: wrReadOnly

proc verifyWriter(session: StoreSession; projectId: string
                 ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Re-read the lock before writing.
  ##
  ## Yes, this is a read per write, and on OPFS that is a real cost. It is
  ## paid deliberately: the alternative is trusting a generation cached in this
  ## tab, and the whole failure §4.3 exists to prevent is precisely a tab that
  ## believes it still holds a lock it does not. A cached belief is exactly the
  ## thing under suspicion, so it cannot be the thing consulted.
  if not session.heldLocks.hasKey(projectId):
    return resolvedErr[Nothing](pkAccessDenied,
      "this tab has the project open read-only; take over the project to " &
      "make changes")
  let held = session.heldLocks[projectId]
  thenOutcome(session.readLock(projectId),
    proc(current: ProjectLock): PlatformFuture[PlatformOutcome[Nothing]] =
      if current.generation == held.generation and
         current.ownerId == held.ownerId:
        return resolvedOk()
      # Relinquish cleanly, here, rather than letting the caller retry into an
      # interleave. §4.3: "There is no merge and no last-writer-wins."
      session.heldLocks.del(projectId)
      resolvedErr[Nothing](pkConflict,
        "another tab has taken over this project, so this tab is now " &
        "read-only; nothing was written",
        "lock generation " & $held.generation & " -> " & $current.generation))

# ---------------------------------------------------------------------------
# Atomic writes — §4.4
# ---------------------------------------------------------------------------

proc nextTempPath(session: StoreSession; projectId: string): string =
  inc session.tempCounter
  tempRoot(projectId) & "/" & storeTempPrefix & $session.tempCounter

proc headroomFor*(session: StoreSession; bytes: int
                 ): PlatformFuture[PlatformOutcome[bool]] =
  ## NS2: "Storage usage surfaced, with headroom checked before large writes."
  ##
  ## An *unknown* usage answers `true`. That is the honest reading: the browser
  ## declining to estimate is not evidence that there is no room, and refusing
  ## every write on a Safari that will not answer would be a worse failure than
  ## the `QuotaExceededError` the write itself would report — which §4.4
  ## already handles without losing anything.
  mapOutcome(session.volume.usage(), proc(usage: VolumeUsage): bool =
    if not usage.known or usage.quotaBytes <= 0: true
    else: usage.usedBytes + bytes.int64 <= usage.quotaBytes)

proc writeThroughTemp(session: StoreSession; projectId, path: string;
                      content: seq[byte]
                     ): PlatformFuture[PlatformOutcome[Nothing]] =
  let temp = session.nextTempPath(projectId)

  proc cleanupThenFail(error: PlatformError
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
    ## The temp file is removed on every failure path, so a quota-exhausted or
    ## interrupted write leaves nothing behind AND leaves the original intact —
    ## §4.4's "a write that fails on `QuotaExceededError` discards the
    ## temporary file and leaves the original intact, because nothing is ever
    ## written in place".
    proc ignoreRemoveFailure(second: PlatformError
                            ): PlatformFuture[PlatformOutcome[Nothing]] =
      resolvedOk()
    thenOutcome(
      recoverOutcome(session.volume.remove(temp, false), ignoreRemoveFailure),
      proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
        resolved(failed[Nothing](error)))

  thenOutcome(session.volume.createDir(tempRoot(projectId)),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
      recoverOutcome(
        thenOutcome(session.volume.writeBytes(temp, content),
          proc(ignored2: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
            thenOutcome(session.volume.createDir(volumeParent(path)),
              proc(ignored3: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
                session.volume.move(temp, path))),
        cleanupThenFail))

proc writeProjectFile*(session: StoreSession; projectId, relativePath: string;
                       content: seq[byte]
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## A working-tree write. Verifies the writer role, then replaces atomically.
  let path = workingTreeRoot(projectId) & "/" & volumePath(relativePath)
  thenOutcome(session.verifyWriter(projectId),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
      session.writeThroughTemp(projectId, path, content))

proc writeProjectText*(session: StoreSession; projectId, relativePath: string;
                       text: string
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
  session.writeProjectFile(projectId, relativePath, toBytes(text))

proc writeBuildOutput*(session: StoreSession; projectId, relativePath: string;
                       content: seq[byte]
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Build outputs are §4.4's derived class: written straight through, no temp,
  ## no atomicity. A half-written one is not a loss, and paying for atomicity
  ## on a file that is discarded on doubt would be ceremony.
  let path = buildOutputRoot(projectId) & "/" & volumePath(relativePath)
  thenOutcome(session.verifyWriter(projectId),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
      thenOutcome(session.volume.createDir(volumeParent(path)),
        proc(ignored2: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
          session.volume.writeBytes(path, content)))

proc readProjectFile*(session: StoreSession; projectId, relativePath: string
                     ): PlatformFuture[PlatformOutcome[seq[byte]]] =
  session.volume.readBytes(
    workingTreeRoot(projectId) & "/" & volumePath(relativePath))

proc readProjectText*(session: StoreSession; projectId, relativePath: string
                     ): PlatformFuture[PlatformOutcome[string]] =
  mapOutcome(session.readProjectFile(projectId, relativePath), toText)

proc removeProjectFile*(session: StoreSession; projectId, relativePath: string
                       ): PlatformFuture[PlatformOutcome[Nothing]] =
  let path = workingTreeRoot(projectId) & "/" & volumePath(relativePath)
  thenOutcome(session.verifyWriter(projectId),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
      session.volume.remove(path, true))

proc listProjectDir*(session: StoreSession; projectId, relativePath: string
                    ): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]] =
  let normalized = volumePath(relativePath)
  let path =
    if normalized.len == 0: workingTreeRoot(projectId)
    else: workingTreeRoot(projectId) & "/" & normalized
  session.volume.list(path)

# ---------------------------------------------------------------------------
# Recovery — §4.4's "interrupted compilation" and "interrupted git write"
# ---------------------------------------------------------------------------

proc discardStaleWork*(session: StoreSession; projectId: string
                      ): PlatformFuture[PlatformOutcome[Nothing]] =
  ## Run on open. Removes everything §4.4 classifies as discardable on doubt:
  ## staging temps from writes that did not complete, and build outputs from a
  ## compilation that did not finish.
  ##
  ## Note what is NOT removed: unreferenced git objects. §4.4 calls them
  ## "garbage", not "corruption" — they are content-addressed and immutable, so
  ## a half-written one is unreachable rather than wrong, and collecting them
  ## is git's own `gc`, sequenced with the engine in NS5. Deleting them here
  ## would be this store inventing a git responsibility it does not have.
  proc ignoreMissing(error: PlatformError
                    ): PlatformFuture[PlatformOutcome[Nothing]] =
    if error.kind == pkNotFound: resolvedOk()
    else: resolved(failed[Nothing](error))
  thenOutcome(
    recoverOutcome(session.volume.remove(tempRoot(projectId), true),
                   ignoreMissing),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[Nothing]] =
      recoverOutcome(session.volume.remove(buildOutputRoot(projectId), true),
                     ignoreMissing))

# ---------------------------------------------------------------------------
# Creating and enumerating projects
# ---------------------------------------------------------------------------

proc createProject*(session: StoreSession; projectId, displayName: string;
                    nowMs: int64): PlatformFuture[PlatformOutcome[ProjectOpen]] =
  ## `projectId` is supplied by the caller and generated in the browser —
  ## Noir-Studio.md §1b.0 rule 1: "A project does get an identifier immediately
  ## — the project store needs one — but it is **generated in the browser and
  ## never appears in the URL**." This module therefore has no id generator,
  ## deliberately: a generator here would be the place a server-issued id later
  ## got plumbed in.
  thenOutcome(session.volume.createDir(workingTreeRoot(projectId)),
    proc(ignored: Nothing): PlatformFuture[PlatformOutcome[ProjectOpen]] =
      thenOutcome(
        session.volume.writeBytes(projectMetadataPath(projectId),
                                  toBytes("name " & displayName & "\n")),
        proc(ignored2: Nothing): PlatformFuture[PlatformOutcome[ProjectOpen]] =
          session.openProject(projectId, nowMs)))

proc listProjects*(session: StoreSession
                  ): PlatformFuture[PlatformOutcome[seq[string]]] =
  proc empty(error: PlatformError
            ): PlatformFuture[PlatformOutcome[seq[VolumeEntry]]] =
    if error.kind == pkNotFound: resolvedOk(newSeq[VolumeEntry](0))
    else: resolved(failed[seq[VolumeEntry]](error))
  mapOutcome(recoverOutcome(session.volume.list(projectsRoot), empty),
    proc(entries: seq[VolumeEntry]): seq[string] =
      for entry in entries:
        if entry.kind == vekDirectory: result.add entry.name)

proc markExported*(session: StoreSession; projectId: string) =
  session.everExported[projectId] = true

proc everExportedProject*(session: StoreSession; projectId: string): bool =
  session.everExported.getOrDefault(projectId, false)

proc exportWarning*(session: StoreSession; projectId: string): string =
  ## NS2: "A project that has never been exported is marked as such, and the
  ## export prompt **escalates** when persistence was denied."
  neverExportedWarning(session.durability,
                       session.everExportedProject(projectId))

# ---------------------------------------------------------------------------
# Walking the working tree, for export
# ---------------------------------------------------------------------------

type
  TreeFile* = object
    path*: string
      ## Project-relative, `/`-separated.
    content*: seq[byte]

proc collectTree*(session: StoreSession; projectId: string
                 ): PlatformFuture[PlatformOutcome[seq[TreeFile]]] =
  ## Every working-tree file, depth-first, sorted by the volume's own listing
  ## order (which `memory_volume` sorts and OPFS does not guarantee — see
  ## `archive.nim`, which sorts again for a reason).
  var collected: seq[TreeFile] = @[]
  let root = workingTreeRoot(projectId)

  proc walk(relative: string): PlatformFuture[PlatformOutcome[Nothing]] =
    let absolute = if relative.len == 0: root else: root & "/" & relative
    thenOutcome(session.volume.list(absolute),
      proc(entries: seq[VolumeEntry]): PlatformFuture[PlatformOutcome[Nothing]] =
        var steps: seq[VolumeEntry] = entries
        foldOutcome(steps, proc(entry: VolumeEntry
                               ): PlatformFuture[PlatformOutcome[Nothing]] =
          let childRelative =
            if relative.len == 0: entry.name else: relative & "/" & entry.name
          if entry.kind == vekDirectory:
            walk(childRelative)
          elif entry.kind == vekFile:
            mapOutcome(session.volume.readBytes(root & "/" & childRelative),
              proc(content: seq[byte]): Nothing =
                collected.add TreeFile(path: childRelative, content: content)
                nothing)
          else:
            resolvedOk()))

  mapOutcome(walk(""), proc(ignored: Nothing): seq[TreeFile] = collected)
