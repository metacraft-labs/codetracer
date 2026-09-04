## The store's layout and its version — Noir-Studio.md §4.5.
##
## "The store layout carries a schema version, migrated forward on open and
## **never silently**: an unrecognised future version is refused with an
## explanation and the export path, rather than opened optimistically by an
## older build that would rewrite it. A development environment that corrupts a
## project by being out of date is the one failure a user cannot forgive."
##
## Everything here is synchronous and pure. The *decision* — open, migrate, or
## refuse — is separated from the I/O that acts on it (`project_store.nim`)
## precisely so it can be asserted directly: `test_an_unrecognised_store_version_is_refused_not_rewritten`
## is then a check on a value rather than an integration test that has to
## observe the absence of a write.
##
## ## Why the metadata is hand-encoded rather than `std/json`
##
## Two reasons, and the second is the load-bearing one.
##
## 1. These records are four scalar fields. A JSON dependency to carry four
##    fields is weight in a module the host-free gate compiles standalone.
## 2. **A store written by a newer build must be *parseable enough to be
##    refused*.** If the metadata format itself can change, an older build
##    meeting a newer store gets a parse error rather than a version number,
##    and then cannot tell "written by the future" from "corrupt" — which are
##    the two cases §4.5 requires different answers for. So the first line is
##    frozen: `codetracer-store <version>`, and nothing may ever be added
##    before it. Everything after it is free to change.

import ./store_volume

const
  storeSchemaVersion* = 1
    ## The version this build writes and understands. Bumped by a change to
    ## the on-volume layout, never by a change to what a project contains.

  storeMagic* = "codetracer-store"

  storeMetadataPath* = "store" ## The store descriptor, at the volume root.

  projectsRoot* = "projects"

type
  StoreOpenVerdict* = enum
    ## What `readStoreMetadata` decided, before anything is written.
    sovFresh
      ## No store here. One will be created — the only verdict that writes on
      ## open, and only because there is nothing to damage.
    sovCurrent
    sovMigrate
      ## Older than this build. Migration runs forward on open.
    sovRefuseFuture
      ## Newer than this build. **Nothing is written**, the user is told, and
      ## the export path is offered.
    sovRefuseUnreadable
      ## Present but not a store descriptor at all. Also refused without
      ## writing: an unrecognised file at `store` is more likely someone
      ## else's data than a store we should overwrite.

  StoreMetadata* = object
    version*: int
    createdAtMs*: int64
    lastOpenedAtMs*: int64

  StoreOpenDecision* = object
    verdict*: StoreOpenVerdict
    metadata*: StoreMetadata
    foundVersion*: int
      ## What was on the volume. Meaningful for `sovMigrate` and
      ## `sovRefuseFuture`; zero otherwise.
    explanation*: string
      ## Shown to the user. Empty when the verdict needs no explaining.

# ---------------------------------------------------------------------------
# Paths inside the store
# ---------------------------------------------------------------------------
#
# Every path a project owns is derived here rather than concatenated at call
# sites, because §4.4's four classes have different recovery rules and the rule
# is chosen BY PATH: build outputs are discarded on doubt, git objects are
# garbage-collected, working-tree files are replaced atomically. A call site
# that spelled its own path would opt out of that classification silently.

proc projectRoot*(projectId: string): string =
  projectsRoot & "/" & projectId

proc projectMetadataPath*(projectId: string): string =
  projectRoot(projectId) & "/project"

proc projectLockPath*(projectId: string): string =
  projectRoot(projectId) & "/lock"

proc workingTreeRoot*(projectId: string): string =
  ## Where the user's files live. Deliberately a subdirectory rather than the
  ## project root, so `project`, `lock` and the build outputs are not files the
  ## user can see, name-collide with or delete from the file tree.
  projectRoot(projectId) & "/tree"

proc gitDirRoot*(projectId: string): string =
  ## Reserved for NS5. Named now because §4.4's recovery table classifies by
  ## path, and a class with no path is a class the store cannot apply.
  projectRoot(projectId) & "/git"

proc buildOutputRoot*(projectId: string): string =
  projectRoot(projectId) & "/out"

proc tempRoot*(projectId: string): string =
  ## Where write-temp-then-replace stages. Inside the project so a partial
  ## write is removed with the project, and *outside* the working tree so a
  ## crashed write can never be mistaken for one of the user's files.
  projectRoot(projectId) & "/tmp"

type
  StoreClass* = enum
    ## §4.4's four classes plus the two store-internal ones. The recovery rule
    ## follows from the class, and `classify` is the only place a path becomes
    ## a class.
    scWorkingTree
    scGitObject
    scGitRef
    scBuildOutput
    scStoreInternal
    scStagingTemp

proc classify*(projectId, path: string): StoreClass =
  ## `path` is a full volume path, not a project-relative one.
  if isUnder(tempRoot(projectId), path): scStagingTemp
  elif isUnder(buildOutputRoot(projectId), path): scBuildOutput
  elif isUnder(gitDirRoot(projectId) & "/objects", path): scGitObject
  elif isUnder(gitDirRoot(projectId) & "/refs", path): scGitRef
  elif isUnder(workingTreeRoot(projectId), path): scWorkingTree
  else: scStoreInternal

proc discardedOnDoubt*(class: StoreClass): bool =
  ## §4.4: build outputs are "discarded on doubt and regenerated. Never worth
  ## recovering", and a staging temp that outlived its write is by definition
  ## a write that did not complete.
  class in {scBuildOutput, scStagingTemp}

proc needsAtomicReplace*(class: StoreClass): bool =
  ## §4.4: "Working-tree files — the only class needing care." Git objects are
  ## content-addressed and write-once; refs are one small file replaced
  ## atomically, which is the same mechanism, so both are included and neither
  ## needs a journal.
  class in {scWorkingTree, scGitRef, scStoreInternal}

# ---------------------------------------------------------------------------
# The frozen metadata encoding
# ---------------------------------------------------------------------------

proc splitLines(text: string): seq[string] =
  var current = ""
  for c in text:
    if c == '\n':
      result.add current
      current = ""
    elif c != '\r':
      current.add c
  result.add current

proc parseNonNegative(text: string): int64 =
  ## -1 for anything that is not a run of digits. Deliberately not
  ## `parseBiggestInt`, which raises: a corrupt descriptor must produce a
  ## verdict, not an exception, because the verdict is what tells the user what
  ## happened.
  if text.len == 0: return -1
  var value: int64 = 0
  for c in text:
    if c < '0' or c > '9': return -1
    value = value * 10 + (ord(c) - ord('0')).int64
  value

proc formatInt(value: int64): string =
  if value == 0: return "0"
  var v = value
  var digits = ""
  let negative = v < 0
  if negative: v = -v
  while v > 0:
    digits.add chr(ord('0') + (v mod 10).int)
    v = v div 10
  for i in countdown(digits.len - 1, 0):
    result.add digits[i]
  if negative: result = "-" & result

proc encodeStoreMetadata*(metadata: StoreMetadata): string =
  ## The first line is frozen forever. See the module header.
  storeMagic & " " & formatInt(metadata.version.int64) & "\n" &
  "created " & formatInt(metadata.createdAtMs) & "\n" &
  "opened " & formatInt(metadata.lastOpenedAtMs) & "\n"

proc decodeStoreVersion*(text: string): int =
  ## The version, or -1 if this is not a store descriptor at all. Reads only
  ## the frozen first line, so it cannot be broken by anything a future build
  ## adds below.
  let lines = splitLines(text)
  if lines.len == 0: return -1
  let head = lines[0]
  if head.len <= storeMagic.len + 1: return -1
  if head[0 ..< storeMagic.len] != storeMagic: return -1
  if head[storeMagic.len] != ' ': return -1
  let parsed = parseNonNegative(head[storeMagic.len + 1 .. ^1])
  if parsed < 0: return -1
  parsed.int

proc decodeStoreMetadata*(text: string): StoreMetadata =
  result.version = decodeStoreVersion(text)
  for line in splitLines(text):
    if line.len > 8 and line[0 ..< 8] == "created ":
      let v = parseNonNegative(line[8 .. ^1])
      if v >= 0: result.createdAtMs = v
    elif line.len > 7 and line[0 ..< 7] == "opened ":
      let v = parseNonNegative(line[7 .. ^1])
      if v >= 0: result.lastOpenedAtMs = v

const refusalAdvice =
  ". Open it with a newer CodeTracer, or export it from the version that " &
  "saved it. Nothing here has been changed"

proc decideStoreOpen*(present: bool; text: string; nowMs: int64
                     ): StoreOpenDecision =
  ## The whole §4.5 decision, as a function of what is on the volume.
  ##
  ## Note what it does NOT do: it never returns a verdict that says "open it
  ## anyway". The optimistic path §4.5 forbids is not a branch anyone has to
  ## remember not to take — it is absent from the enum.
  if not present:
    return StoreOpenDecision(
      verdict: sovFresh,
      metadata: StoreMetadata(
        version: storeSchemaVersion,
        createdAtMs: nowMs,
        lastOpenedAtMs: nowMs))

  let found = decodeStoreVersion(text)
  if found < 0:
    return StoreOpenDecision(
      verdict: sovRefuseUnreadable,
      foundVersion: 0,
      explanation:
        "this browser's storage holds something that is not a CodeTracer " &
        "project, so nothing here will be read or changed")

  if found > storeSchemaVersion:
    return StoreOpenDecision(
      verdict: sovRefuseFuture,
      foundVersion: found,
      explanation:
        "this project was saved by a newer version of CodeTracer than " &
        "this one" & refusalAdvice)

  var metadata = decodeStoreMetadata(text)
  metadata.lastOpenedAtMs = nowMs
  if metadata.createdAtMs == 0: metadata.createdAtMs = nowMs
  if found < storeSchemaVersion:
    metadata.version = storeSchemaVersion
    return StoreOpenDecision(
      verdict: sovMigrate,
      metadata: metadata,
      foundVersion: found,
      explanation:
        "this store was written by an older build (store schema " &
        formatInt(found.int64) & ") and has been migrated forward to " &
        formatInt(storeSchemaVersion.int64))

  metadata.version = storeSchemaVersion
  StoreOpenDecision(
    verdict: sovCurrent, metadata: metadata, foundVersion: found)

proc refuses*(verdict: StoreOpenVerdict): bool =
  verdict in {sovRefuseFuture, sovRefuseUnreadable}

proc writesOnOpen*(verdict: StoreOpenVerdict): bool =
  ## The property `test_an_unrecognised_store_version_is_refused_not_rewritten`
  ## turns on: a refused store must not be touched, and this says so as a value
  ## the store's open path consults rather than as a rule the open path
  ## remembers.
  verdict in {sovFresh, sovCurrent, sovMigrate}
