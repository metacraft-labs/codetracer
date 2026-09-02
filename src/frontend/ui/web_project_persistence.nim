## The project store, reached — and the sentence §4.2 requires, shown.
##
## `web_project_store.nim` holds the session's working tree in memory and knows
## nothing about OPFS. This module is the js-only half that gives it somewhere
## to live: it takes the `WebBoot` the boot sequence already produced, puts the
## project in the store, restores what the store already holds, and installs
## the writer every save then goes through.
##
## ## Everything here calls something that already existed
##
## Not one storage primitive is written in this file. `boot()` had already
## built an OPFS volume (`host/opfs_volume.newOpfsVolume`), already fallen back
## to `memory_volume` when OPFS is absent, already asked
## `navigator.storage.persist()`, already opened the store and already
## installed a platform whose filesystem facade writes through it. The pieces
## below are the call sites those procs never had:
##
##   * `web_platform.activateProject` — **zero** callers before this. It sets
##     `web.activeProjectId`, which every facade read and write is addressed
##     through, and takes §4.3's one-writer lock.
##   * `project_store.createProject` — **zero** callers. First visit.
##   * `project_store.acknowledgeDurability` — **zero** callers, which is the
##     one that bites hardest: `readyForEditing` is false whenever
##     `mustAnnounceBeforeEditing` is true, and `web_platform.writeText`
##     refuses with `pkAccessDenied` until it flips. In §4.2's degraded rows a
##     save host wired straight to the facade would have failed **silently, in
##     exactly the conditions where losing work matters most**.
##   * `store_durability`'s announcement — computed on every boot since the
##     store landed, reported on the console, and never shown to anyone.
##
## ## The order is the contract
##
## `acknowledgeDurability`'s own doc comment says it is "called by the view
## that showed `session.durability.announcement`", and that "a call site which
## has not shown anything reads as a lie". `prepareProject` therefore does not
## call it: it composes the sentence and ARMS the acknowledgement, and
## `takeDurabilityAnnouncement` — which the renderer calls at the moment it
## hands the sentence to the notification system — is what fires it. §4.2's
## requirement is that the session "**says so before the first keystroke**",
## and both halves still run inside `ui_js.startWebArm` before any editor is
## interactive.
##
## ## What happens on reload, precisely
##
## | Condition | Working tree | What is raised |
## | --- | --- | --- |
## | `scPersistenceGranted` | OPFS, survives reload and crash | a success notification: it is saved in this browser |
## | `scPersistenceUnknown` / `scPersistenceDenied` | OPFS, survives reload; evictable under storage pressure | a dismissible warning that leads with what is saved, and an Export action |
## | `scVolatile` — no OPFS | memory only, lost on close | a dismissible error, and an Export action |
##
## The first three all survive a reload; only `scVolatile` does not, and it is
## the one row that says so in the product rather than only in a report.
##
## Each is raised ONCE PER BROWSER SESSION, keyed on the condition — see
## `durabilityNoticeSessionKey`.

when not defined(js):
  {.error: "web_project_persistence.nim is part of the web instantiation; " &
           "it is compiled only by `nim js -d:ctWeb` builds".}

import std/[asyncjs]

import ../viewmodel/platform/outcome
import ../viewmodel/platform/project_store
import ../viewmodel/platform/store_durability
import ../viewmodel/platform/web_platform
import ../viewmodel/platform/noir_template
import ../viewmodel/host/web_browser
import ./web_project_store

# ---------------------------------------------------------------------------
# WHY THERE IS NO LONGER A BANNER HERE
# ---------------------------------------------------------------------------
#
# This module used to append a `<div id="codetracer-durability">` to
# `document.body` at `position:fixed; bottom:0; z-index:2147483646` and paint
# the durability sentence into it. Two things were wrong with that, and only
# one of them was a bug:
#
#   * IT SAT ON TOP OF THE STATUS BAR. `#status` is the bottom strip of the
#     application; a fixed element pinned to `bottom:0` with the largest
#     representable z-index covers it, and covered it on every load in the two
#     degraded storage rows — which is every first visit, because browsers deny
#     persistence to an origin a visitor has just arrived at. The banner's own
#     comment argued it "covers no pane"; the status bar is not a pane, and it
#     was the thing underneath.
#
#   * IT WAS A SECOND NOTIFICATION SYSTEM. `NotificationKind`,
#     `newNotification`, the toast stack in `ui/status.nim`, its dismiss
#     button, its action buttons and its auto-dismiss timers all already
#     existed and are what every other message in this product goes through.
#     `#active-notifications` is `position:fixed; bottom:38px; right:8px;
#     z-index:100` — it stacks ABOVE the status bar rather than over it, which
#     is the layout decision this file re-made and got wrong.
#
# So the sentence is now handed to the renderer instead of painted here.
# `ui_js.raiseDurabilityNotice` takes it through `takeDurabilityAnnouncement`
# below and raises it as a `Notification`, with the export offered as a
# notification action beside the chord.

const exportChordLabel* = "Ctrl+Shift+E"
  ## The gesture that performs the export every durability sentence tells the
  ## user to perform.

const durabilityNoticeSessionKey = "codetracer.durability.told"
  ## `sessionStorage`, not `localStorage`, and the difference is the decision.
  ##
  ## A reload is not a new visit: the tab is the same, the person is the same,
  ## and they read the sentence a moment ago. `sessionStorage` is per tab and
  ## dies with it, so the notice appears once per browser session and returns
  ## for the next one — a fresh tab tomorrow is told again, which is right,
  ## because the risk it describes has not gone away.
  ##
  ## The stored value is the CONDITION, not a flag: if the storage situation
  ## changes mid-session (persistence granted after engagement, or a store that
  ## refused to open) the tag no longer matches and the new state is announced.

proc jsSessionTag(key: cstring): cstring {.importjs: """
(function (k) {
  try {
    if (typeof sessionStorage === 'undefined') { return ''; }
    return sessionStorage.getItem(k) || '';
  } catch (e) { return ''; }
})(#)""".}

proc jsSetSessionTag(key, value: cstring) {.importjs: """
(function (k, v) {
  try {
    if (typeof sessionStorage === 'undefined') { return; }
    sessionStorage.setItem(k, v);
  } catch (e) {}
})(#, #)""".}

type
  DurabilityAnnouncement* = object
    ## What the renderer should raise, and whether it should raise it at all.
    text*: string
    level*: DurabilityNoticeLevel
    show*: bool
      ## False when there is nothing to say, or when this browser session has
      ## already been told this same thing.
    offerExport*: bool
      ## Whether an "Export project" action can be attached. False in the
      ## refused-boot rows, where there is no project in a store to export and
      ## a button that did nothing would be the exact defect
      ## `exportOpenProject`'s header records.

var pendingAcknowledgement: proc()
  ## `web.store.acknowledgeDurability`, bound at announce time and called when
  ## the sentence has actually been handed to the notification system.
  ##
  ## IT MOVED, AND THAT IS DELIBERATE. `acknowledgeDurability`'s own doc
  ## comment says it is "called by the view that showed
  ## `session.durability.announcement`", and that "a call site which has not
  ## shown anything reads as a lie". While this module painted the sentence
  ## itself, showing and acknowledging were adjacent statements. Now the
  ## showing happens one step later — the status bar does not exist until
  ## `startWebRenderer` has mounted — so the acknowledgement travels with it
  ## rather than being made on its behalf in advance.

var announcementTag: string
  ## The condition tag for the sentence currently held in `web_project_store`.

proc levelFor(report: DurabilityReport): DurabilityNoticeLevel =
  ## Derived from `ExportUrgency`, which already exists and already encodes
  ## exactly this ordering ("the export prompt is escalated rather than merely
  ## available"). A second severity enum keyed off `StorageCondition` would be
  ## a table that can disagree with the one beside it.
  case report.exportUrgency
  of euRoutine: dnlReassurance
  of euEscalated: dnlEvictable
  of euCritical: dnlUnstored

proc withChord(sentence: string): string =
  # NAME THE GESTURE. Every sentence ends by telling the user to export, and
  # until `exportOpenProject` existed there was no way to. Appending the chord
  # is what turns the instruction into something actionable rather than an
  # instruction to do a thing the product does not offer.
  sentence & "  (" & exportChordLabel & " exports this project.)"

proc grantedSentence(report: DurabilityReport): string =
  ## `scPersistenceGranted` has no announcement because there is no warning to
  ## give. Saying nothing at all would still leave the user guessing where
  ## their work is, so the durable case gets a short positive line DERIVED from
  ## the same report rather than invented here.
  "Your work is saved in this browser (" &
    report.tiers[dtWorkingTree].mechanism & ") and will still be here when " &
    "you come back. Export the project to keep a copy elsewhere."

proc announceDurability(web: WebPlatform) =
  ## Record what will happen to the user's work, and arm the acknowledgement.
  let report = web.store.durability
  let durable = report.tiers[dtWorkingTree].available
  let sentence =
    if report.announcement.len > 0: report.announcement
    else: grantedSentence(report)
  setDurabilityNotice(withChord(sentence), durable, levelFor(report))
  announcementTag = $report.condition
  pendingAcknowledgement = proc() = web.store.acknowledgeDurability()

var exportAction: proc()

proc canExportProject*(): bool =
  not exportAction.isNil

proc exportOpenProject*() =
  ## §6.2's "your work leaves with you", as something a user can actually do.
  ##
  ## ## Why this proc had to exist before the banner could be honest
  ##
  ## Every one of `store_durability.announcementFor`'s sentences ends in
  ## "Export to keep them" or "export the project before you leave", and
  ## `web_platform.exportProjectArchive` — which walks the working tree, builds
  ## a tar and hands it to the browser — had **zero callers**. So the product
  ## was instructing the user to take an action it offered no way to take.
  ##
  ## That is the same defect as the one this whole change is about, one clause
  ## further on: a true-sounding sentence about machinery that is present,
  ## correct and unreachable. A banner naming a chord that does nothing would
  ## have been worse than one that named nothing.
  if not exportAction.isNil:
    exportAction()

proc takeDurabilityAnnouncement*(): DurabilityAnnouncement =
  ## What to raise in the status bar, exactly once per page load.
  ##
  ## The acknowledgement happens here whether or not `show` comes back true,
  ## and that is not a loophole: a session that is being suppressed is being
  ## suppressed *because this browser session was already shown the sentence*,
  ## which is the fact `acknowledgeDurability` records. Leaving it unset would
  ## make `readyForEditing` false for the rest of a reloaded tab's life and
  ## refuse every facade write — the failure §4.2 is about, reintroduced by the
  ## fix for it.
  result.text = durabilityNoticeText()
  result.level = durabilityNoticeLevel()
  result.offerExport = canExportProject()
  if result.text.len == 0:
    return
  let tag = cstring(announcementTag)
  result.show = jsSessionTag(cstring(durabilityNoticeSessionKey)) != tag
  jsSetSessionTag(cstring(durabilityNoticeSessionKey), tag)
  if not pendingAcknowledgement.isNil:
    pendingAcknowledgement()
    pendingAcknowledgement = nil

# ---------------------------------------------------------------------------
# ASKING AGAIN, ONCE THE VISITOR HAS INVESTED SOMETHING
# ---------------------------------------------------------------------------
#
# `boot()` calls `navigator.storage.persist()` before a single character has
# been typed. Browsers grant persistence on engagement — repeat visits, a
# bookmark, an installed app — so a first visit is normally denied, and the
# product used to treat that first "no" as the permanent state of the world:
# nothing ever asked again, so a user who came back every day and did all their
# work here would be warned about eviction forever while the browser would
# happily have protected them.
#
# The first successful SAVE is the engagement signal: the visitor has typed
# something and asked for it to be kept. Asking then costs one call — and no
# prompt, because `jsRequestPersistence` checks `persisted()` first and every
# engine either resolves from its heuristics or has already decided.

var persistenceRecheckStarted = false
var onPersistenceUpgrade: proc(message: string)

proc setPersistenceUpgradeHandler*(handler: proc(message: string)) =
  ## Installed by `ui_js`, which owns the notification system. Injected rather
  ## than imported for the same reason the project writer is: this module is
  ## reachable from the platform, and `ui_js` is not.
  onPersistenceUpgrade = handler

proc recheckPersistence(web: WebPlatform) {.async.} =
  if persistenceRecheckStarted:
    return
  if not mayBeGrantedLater(web.store.durability.condition):
    return
  persistenceRecheckStarted = true
  let answer = await requestPersistenceAgain()
  if not (answer.answered and answer.granted):
    return
  # `scPersistenceGranted` DIRECTLY, without re-deriving from the volume.
  # `mayBeGrantedLater` already excluded `scVolatile`, so the volume behind
  # this session is durable; `conditionFor` would return the same value from
  # one more indirection, and reading the volume back out of the bridge here
  # would be a second source of truth for a fact already established above.
  web.store.refreshDurability(scPersistenceGranted)
  let sentence = withChord(grantedSentence(web.store.durability))
  setDurabilityNotice(sentence, true, dnlReassurance)
  announcementTag = $scPersistenceGranted
  # The tag has changed, so `takeDurabilityAnnouncement` would announce this on
  # the next load anyway; the handler is what tells the user NOW, in the
  # session where their work just became protected.
  if not onPersistenceUpgrade.isNil:
    onPersistenceUpgrade(sentence)

proc installExport(web: WebPlatform; projectId, displayName: string) =
  exportAction = proc() =
    proc run() {.async.} =
      discard await web.exportProjectArchive(projectId, displayName)
    discard run()

proc installWriter(web: WebPlatform; projectId: string) =
  ## Point `web_project_store.saveProjectFile` at the store.
  ##
  ## `writeProjectText` rather than the filesystem facade, deliberately. The
  ## facade addresses `web.activeProjectId` and adds a path guard the renderer's
  ## absolute paths would trip; the store takes the project and the
  ## project-relative key explicitly, which is what the save host already has in
  ## hand. Both end at the same atomic write-temp-then-rename.
  setProjectWriter(proc(relativePath, content: string; onDone: SaveDone) =
    proc run() {.async.} =
      let written = await web.store.writeProjectText(projectId, relativePath,
                                                     content)
      if written.ok:
        onDone(true, "")
        # AFTER the save is reported, never before: the recheck is a courtesy
        # and must not be able to delay or fail the thing the user asked for.
        discard recheckPersistence(web)
      else:
        onDone(false, written.error.message)
    discard run())

proc prepareProject*(booted: WebBoot; tmpl: ProjectTemplate): Future[void]
                    {.async.} =
  ## Put the project in the store, restore what is already there, and make the
  ## result the session's working tree.
  ##
  ## Called from `ui_js.startWebArm` between `startWebSession()` and
  ## `startWebRenderer()` — the seam that already exists because the boot is
  ## already awaited there. Nothing has mounted yet, so the restore cannot race
  ## the first `tab-load`.
  if not tmpl.hasFiles:
    return

  # A REFUSED BOOT STILL EDITS. §4.5's refusal has a UI, and `startWebArm`'s own
  # comment commits to rendering against `uninstalledProfile` rather than a
  # blank page. The session then runs entirely in memory — no writer is
  # installed, `saveProjectFile` succeeds against the live project alone, and
  # the banner says the work will not survive. That is strictly better than a
  # tab that accepts keystrokes and discards them, which is what shipped.
  if not booted.ok:
    setCurrentProject(tmpl)
    setDurabilityNotice(
      "This session has no project storage (" & booted.refusal & "), so " &
      "everything you write is held in this tab and will be lost when it " &
      "closes. You can still edit, compile and run — export before you leave.",
      false, dnlUnstored)
    announcementTag = "refused:" & booted.refusal
    return

  let web = booted.web
  let projectId = tmpl.name

  # THE ANNOUNCEMENT COMES FIRST, because everything below it writes.
  announceDurability(web)

  # Take the writer role. `activateProject` claims §4.3's lock and discards
  # anything §4.4 classifies as stale; a project the store has never seen has
  # no directory, so `createProject` makes one and opens it.
  var opened = await web.activateProject(projectId)
  if not opened.ok:
    let created = await web.store.createProject(projectId, tmpl.name,
                                                web.bridge.nowMs())
    if not created.ok:
      # The store is there and refused us. Run in memory and say so, rather
      # than editing against a project the store does not have.
      setCurrentProject(tmpl)
      setDurabilityNotice(
        "This project could not be opened in browser storage (" &
        created.error.message & "), so this session is held in this tab " &
        "only and will be lost when it closes. Export before you leave.",
        false, dnlUnstored)
      announcementTag = "unopenable:" & created.error.message
      return
    opened = await web.activateProject(projectId)
    if not opened.ok:
      setCurrentProject(tmpl)
      return

  installWriter(web, projectId)
  installExport(web, projectId, tmpl.name)

  # RESTORE, THEN SEED — per file, and the asymmetry is the point.
  #
  # A file the store already holds is the user's; the bundled copy is stale the
  # moment they edit it, so the store wins. A file the store does not hold is a
  # first visit for that file, and writing the bundled copy in is what makes
  # the project real in storage — so a later visit restores rather than
  # re-seeds, and so `collectTree` (which `exportProjectArchive` walks) has
  # something to export.
  #
  # Per file rather than per project, so a template that GAINS a file between
  # two visits seeds just the new one instead of overwriting the user's work.
  var effective = tmpl
  for index in 0 ..< tmpl.files.len:
    let stored = await web.store.readProjectText(projectId,
                                                 tmpl.files[index].path)
    if stored.ok:
      effective.files[index].content = stored.value
    else:
      discard await web.store.writeProjectText(projectId,
                                               tmpl.files[index].path,
                                               tmpl.files[index].content)
  setCurrentProject(effective)
