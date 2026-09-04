## What the store honestly promises — Noir-Studio.md §4.1 and §4.2.
##
## This module exists because the alternative is a sentence in a design
## document. §4.1's three tiers and §4.2's three platform conditions are both
## tables, and a table that is prose rots the way NS1's degradation table would
## have rotted had it not been made a value. So they are values, and the tests
## check them the way `test_every_absence_has_a_degradation` checks the
## capability table.
##
## ## The one claim this module exists to prevent
##
## **OPFS is a working copy, not durable storage the user owns.** §4.1 is
## explicit that calling it the latter "would be a promise the platform does
## not let us keep". So there is no `durable: bool` on the store and no
## `isPersistent()`; there is a *tier* — and the tier that survives eviction is
## export, which is not OPFS at all. A caller asking "is my work safe" gets a
## tier, and the tiers are ordered, so the question has an answer that cannot
## be rounded up.

import ./store_volume

type
  StorageCondition* = enum
    ## §4.2's three rows, in the order the product prefers them.
    ##
    ## `scPersistenceUnknown` is a fourth, and it is not a hedge: the
    ## Storage API's `persisted()` can be unavailable (older Safari) or the
    ## `persist()` request can be neither granted nor denied but simply not
    ## answered. §4.2 says "whether it was **granted** is shown rather than
    ## assumed", and reporting "granted" for an unanswered request is exactly
    ## the assumption it forbids.
    scPersistenceGranted
    scPersistenceUnknown
    scPersistenceDenied
    scVolatile
      ## OPFS unavailable. The session runs in memory and loses everything on
      ## close.

  DurabilityTier* = enum
    ## §4.1's table, weakest first. The ordering is used — `strongestTier` and
    ## `<` are how a caller asks "is there anything better than this".
    dtWorkingTree
    dtCommittedHistory
    dtExport

  TierState* = object
    tier*: DurabilityTier
    available*: bool
    survives*: string
      ## What this tier gets you through, in the user's terms.
    mechanism*: string
    unavailableBecause*: string
      ## Empty when available. Non-empty is a promise the product is
      ## deliberately not making yet, and saying which one is §4.1's
      ## "stated rather than absorbed".

  ExportUrgency* = enum
    ## §4.2: "the export prompt is escalated rather than merely available",
    ## and §4.1: "Export is the only recovery point, so the product must be
    ## correspondingly insistent about it — more so than it would need to be
    ## once commits exist, not less."
    euRoutine
    euEscalated
    euCritical

  DurabilityReport* = object
    condition*: StorageCondition
    tiers*: array[DurabilityTier, TierState]
    announcement*: string
      ## Empty when there is nothing the user must be told before starting.
      ## Non-empty means §4.2's "says so **before the first keystroke**", and
      ## `project_store.nim` refuses to report the store ready for editing
      ## until it has been acknowledged.
    mustAnnounceBeforeEditing*: bool
    exportUrgency*: ExportUrgency

const
  committedHistoryPending* =
    "there is no version control in the browser yet, so a bad edit or a " &
    "deleted file cannot be undone from a commit. An export is the only way " &
    "back"
    ## §4.1 again, and it is a quotation rather than a paraphrase on purpose.
    ## The day the git engine lands, this string is deleted and the tier turns
    ## available; nothing else in the product changes, which is the test that
    ## the tier was modelled and not merely described.

proc workingTreeState(condition: StorageCondition): TierState =
  case condition
  of scVolatile:
    TierState(
      tier: dtWorkingTree,
      available: false,
      survives: "nothing — this session's files are only in this tab",
      mechanism: "this tab's memory",
      unavailableBecause:
        "this browser has no origin-private filesystem available (private " &
        "browsing, or an engine that does not provide one), so closing the " &
        "tab loses the work")
  else:
    TierState(
      tier: dtWorkingTree,
      available: true,
      survives: "reload, tab close and crash",
      mechanism: "your browser's own storage, which it may reclaim",
      unavailableBecause: "")

proc committedHistoryState(): TierState =
  TierState(
    tier: dtCommittedHistory,
    available: false,
    survives: "a bad edit, a deleted file, a corrupted working tree",
    mechanism: "commits, kept beside the files",
    unavailableBecause: committedHistoryPending)

proc exportState(): TierState =
  ## Always available, on every condition including `scVolatile`. That is the
  ## point of the outermost tier: an in-memory session can still hand the user
  ## an archive, which is the only thing standing between them and total loss.
  TierState(
    tier: dtExport,
    available: true,
    survives: "eviction, a cleared origin, a different browser or device",
    mechanism: "an archive you download",
    unavailableBecause: "")

proc announcementFor(condition: StorageCondition): string =
  ## LEAD WITH WHAT IS TRUE, then name the risk — and the order is the finding.
  ##
  ## The first two degraded rows describe a working tree that IS on disk in
  ## OPFS and DOES survive reload, tab close and crash. Under the Storage
  ## Standard the only thing missing is the *persistent* box: a best-effort
  ## origin may be cleared without prompting when the device runs low. Opening
  ## on "this browser refused" reported the missing box as though it were the
  ## state of the user's work, at the moment a first-time visitor has invested
  ## nothing — and browsers deny a first visit as a matter of course, granting
  ## persistence later on engagement heuristics (repeat visits, a bookmark, an
  ## install). So the refusal is normal, usually temporary, and not the
  ## headline; the eviction risk is real and stays, because export is the only
  ## thing that removes it.
  ##
  ## `scVolatile` is the row that does NOT get this treatment. There is no
  ## reassuring true half to lead with: nothing is stored, and a sentence that
  ## opened "your work is saved" would be false.
  case condition
  of scPersistenceGranted: ""
  of scPersistenceUnknown:
    "Your work is saved in this browser and survives reloads, crashes and " &
    "restarts. This browser did not say whether it will keep it when storage " &
    "runs low, so export the project to keep a copy that cannot be reclaimed."
  of scPersistenceDenied:
    "Your work is saved in this browser and survives reloads, crashes and " &
    "restarts. This browser has not marked it as protected yet, so it can be " &
    "cleared if the device runs low on storage — export the project to keep a " &
    "copy that cannot be reclaimed."
  of scVolatile:
    "This browser has no storage available for projects, so everything you " &
    "write here is held in this tab and will be lost when it closes. You can " &
    "still edit, compile, run and debug — export the project before you leave."

proc urgencyFor(condition: StorageCondition): ExportUrgency =
  case condition
  of scPersistenceGranted: euRoutine
  of scPersistenceUnknown, scPersistenceDenied: euEscalated
  of scVolatile: euCritical

proc mayBeGrantedLater*(condition: StorageCondition): bool =
  ## Whether asking the browser again could change the answer.
  ##
  ## The Storage Standard grants persistence on engagement heuristics — repeat
  ## visits, a bookmark, an install — so a first visit is normally denied and
  ## the SAME origin is normally granted later. A product that asks once, at
  ## the moment the visitor has invested nothing, and never asks again has made
  ## that first refusal permanent for no reason.
  ##
  ## `scVolatile` is excluded because there is no OPFS to make persistent: a
  ## grant would be a promise over a volume that does not survive the tab.
  ## `scPersistenceGranted` is excluded because there is nothing left to ask.
  condition in {scPersistenceUnknown, scPersistenceDenied}

proc durabilityReport*(condition: StorageCondition): DurabilityReport =
  result.condition = condition
  result.tiers[dtWorkingTree] = workingTreeState(condition)
  result.tiers[dtCommittedHistory] = committedHistoryState()
  result.tiers[dtExport] = exportState()
  result.announcement = announcementFor(condition)
  result.mustAnnounceBeforeEditing = result.announcement.len > 0
  result.exportUrgency = urgencyFor(condition)

proc conditionFor*(volume: StoreVolume; persistenceGranted: bool;
                   persistenceAnswered: bool): StorageCondition =
  ## The condition is derived from what the volume *is* plus what the browser
  ## *said*, never from a build check. A volume that is not durable is
  ## `scVolatile` whatever the persistence answer was, because a granted
  ## persistence request over an in-memory volume would be the product
  ## reporting a promise it structurally cannot keep.
  if not volume.durable: scVolatile
  elif not persistenceAnswered: scPersistenceUnknown
  elif persistenceGranted: scPersistenceGranted
  else: scPersistenceDenied

proc strongestAvailableTier*(report: DurabilityReport): DurabilityTier =
  result = dtWorkingTree
  for tier in DurabilityTier:
    if report.tiers[tier].available:
      result = tier

proc survivesEviction*(report: DurabilityReport; everExported: bool): bool =
  ## The question the "never exported" marker answers. Deliberately takes
  ## `everExported` rather than reading it from anywhere: a store that has
  ## never been exported has no tier above the working tree, whatever the
  ## table says is *available*, and blurring "the mechanism exists" with "the
  ## user used it" is how a product ends up marking work safe that is not.
  everExported

proc neverExportedWarning*(report: DurabilityReport;
                           everExported: bool): string =
  ## NS2: "A project that has never been exported is marked as such, and the
  ## export prompt escalates when persistence was denied."
  if everExported: return ""
  case report.exportUrgency
  of euRoutine:
    "This project has never been exported. Browser storage can be cleared; " &
    "an export is the only copy that leaves with you."
  of euEscalated:
    "This project has never been exported, and this browser has not " &
    "guaranteed it will keep it. Export it now."
  of euCritical:
    "This project has never been exported and is not stored anywhere. It " &
    "will be lost when this tab closes. Export it before you go."
