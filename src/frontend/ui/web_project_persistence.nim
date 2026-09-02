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
## has not shown anything reads as a lie". So the banner is inserted into the
## document FIRST and the acknowledgement is the next statement. §4.2's
## requirement is that the volatile session "**says so before the first
## keystroke**" — and this whole proc runs inside `ui_js.startWebArm`, before
## `startWebRenderer`, so there is no keystroke to be before: no editor exists
## yet.
##
## ## What happens on reload, precisely
##
## | Condition | Working tree | What the banner says |
## | --- | --- | --- |
## | `scPersistenceGranted` | OPFS, survives reload and crash | that it is saved in this browser |
## | `scPersistenceUnknown` / `scPersistenceDenied` | OPFS, survives reload; evictable under storage pressure | the report's sentence, and to export |
## | `scVolatile` — no OPFS | memory only, lost on close | the report's sentence, in full |
##
## The first three all survive a reload; only `scVolatile` does not, and it is
## the one row that says so in the product rather than only in a report.

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

const durabilityBannerId* = "codetracer-durability"
  ## The element the banner is rendered into. Named so the browser gate can
  ## hit-test the painted sentence rather than reading `innerText` — the
  ## instrument failure `ui_js.hideWebRendererStatus`'s header records, where
  ## 379 characters of diagnostic were counted by `innerText` and visible to
  ## nobody.

# NO HASH CHARACTER MAY APPEAR IN THE `importjs` BODY BELOW — not in a string,
# not in a comment. A hash is `importjs`'s parameter placeholder, so six CSS
# hex colours made the compiler demand eight arguments for a two-argument proc:
#
#     Error: wrong importcpp pattern; expected parameter at position 3
#            but got only: 2
#
# There is no escape for it. This is the same family as the defect
# `web_boot.jsReport`'s header records from the other side (binding one
# argument once because a second bare placeholder consumes a parameter that
# does not exist), and the reason every colour below is spelled `rgb(...)`.

proc renderDurabilityBanner(text: cstring; durable: bool) {.importjs: """
(function (message, isDurable) {
  try {
    if (typeof document === 'undefined' || !document.body) { return; }
    var id = 'codetracer-durability';
    var el = document.getElementById(id);
    if (!el) {
      el = document.createElement('div');
      el.id = id;
      document.body.appendChild(el);
    }
    el.textContent = message;
    // Painted, on top, and readable. A banner the layout covers is the same
    // failure as no banner: web_entry_surface mounts GoldenLayout over the
    // whole viewport, and the session container has already painted over one
    // surface in this codebase's history (see arm V of the browser gate).
    // rgb(), NOT hex -- see the Nim-side comment above this proc for why a
    // hash character cannot appear anywhere in this body, comments included.
    el.setAttribute('style', [
      'position:fixed', 'left:0', 'right:0', 'bottom:0', 'z-index:2147483646',
      'margin:0', 'padding:6px 12px', 'font:12px/1.5 sans-serif',
      'text-align:center',
      // NO 'pointer-events:none'. It was there to keep the strip from eating
      // clicks, and it made the banner UNHIT-TESTABLE: `elementFromPoint` at
      // the banner's own centre returned whatever was underneath, so a gate
      // asking "is this sentence actually on top of the page" could not get a
      // true answer, and neither could a user's mouse. An element the browser
      // reports as not-there at its own centre is exactly the "laid out but
      // visible to nobody" state this codebase has shipped once already.
      // The strip is 31px at the very bottom edge and covers no pane.
      'background:' + (isDurable ? 'rgb(29,59,42)' : 'rgb(74,45,18)'),
      'color:' + (isDurable ? 'rgb(183,228,199)' : 'rgb(255,217,160)'),
      'border-top:1px solid ' + (isDurable ? 'rgb(47,107,74)'
                                           : 'rgb(138,90,36)')
    ].join(';'));
  } catch (e) {}
})(#, #)""".}

const exportChordLabel* = "Ctrl+Shift+E"
  ## The gesture that performs the export every durability sentence tells the
  ## user to perform.

proc announceDurability(web: WebPlatform) =
  ## Show what will happen to the user's work, then record that it was shown.
  ##
  ## THE TWO STATEMENTS ARE IN THIS ORDER ON PURPOSE — see the header.
  let report = web.store.durability
  let durable = report.tiers[dtWorkingTree].available
  let sentence =
    if report.announcement.len > 0:
      report.announcement
    else:
      # `scPersistenceGranted` has no announcement because there is no warning
      # to give. Saying nothing at all would still leave the user guessing
      # where their work is, so the durable case gets a short positive line
      # DERIVED from the same report rather than invented here.
      "Your work is saved in this browser (" &
        report.tiers[dtWorkingTree].mechanism & ") and will still be here " &
        "when you come back. Export the project to keep a copy elsewhere."
  # NAME THE GESTURE. Every sentence above ends by telling the user to export,
  # and until `exportOpenProject` existed there was no way to. Appending the
  # chord is what turns the instruction into something actionable rather than
  # an instruction to do a thing the product does not offer.
  let full = sentence & "  (" & exportChordLabel & " exports this project.)"
  setDurabilityNotice(full, durable)
  renderDurabilityBanner(cstring(full), durable)
  # Only now. `readyForEditing` gates every write in the facade, and this is
  # the call it was waiting for since the store landed.
  web.store.acknowledgeDurability()

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
      false)
    renderDurabilityBanner(cstring(durabilityNoticeText()), false)
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
        false)
      renderDurabilityBanner(cstring(durabilityNoticeText()), false)
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
