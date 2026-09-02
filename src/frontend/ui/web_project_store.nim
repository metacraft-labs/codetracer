## The open project, as ONE mutable value — and the store it is written to.
##
## ## The defect this module exists to close
##
## Noir Studio accepted keystrokes and discarded them. A visitor could edit
## `src/main.nr`, press Ctrl+B, and watch a *successful build of code they had
## not written* — which is worse than a read-only editor, because it looks like
## it worked. Two independent halves produced that:
##
##   * `web_noir_build.templateVfsEntries` read `tmpl.files`, and
##     `ProjectTemplate` was never mutated by anything. `ProjectTemplate` is an
##     `object`, not a `ref object`, so the THREE copies the web arm held —
##     `web_noir_build.buildTemplate`, `web_entry_surface.mountedTemplate` and
##     the `tmpl` captured by `installTemplateHost`'s closure — were three
##     independent values. Even a mutation would have been invisible to the
##     other two.
##
##   * `CODETRACER::save-file` had no responder, so Ctrl+S reached
##     `ui_js.newWebIpc`'s `send`, found `responders["CODETRACER::save-file"]`
##     undefined, and logged *"no host for … this surface is not ported to the
##     browser yet"*. `CODETRACER::saved-file` therefore never arrived and
##     `onSavedFile` never cleared `tab.changed`.
##
## This module is the single mutable project all three former copies now read,
## and `web_entry_surface.installProjectSaveHost` is the missing responder.
##
## ## WHERE THE EDITS LIVE, and why it is not a new store
##
## It is not a new store. The store was already here, complete, and reached by
## nothing — the nineteenth instance of this campaign's shape:
##
##   | Present and correct | Product call sites before this change |
##   | --- | --- |
##   | `host/opfs_volume.newOpfsVolume` — async OPFS | 1 (`web_browser.boot`) |
##   | `platform/project_store` — sessions, locks, atomic replace | store opened, never used |
##   | `platform/store_durability` — §4.2's condition and sentence | computed, never shown |
##   | `web_platform.buildFileSystem` — a real fs over the store | facade built, never written through |
##   | `web_platform.activateProject` — §4.3's one writer | **zero** |
##   | `project_store.acknowledgeDurability` | **zero** |
##   | `project_store.createProject` | **zero** |
##   | `web_platform.exportProjectArchive` — §6.2 export | **zero** |
##
## `boot()` already builds an OPFS volume, already falls back to
## `memory_volume` when OPFS is absent, already opens the store and already
## installs the platform. What it never did was put a project in it. So this
## module does not choose a storage strategy; it reaches the one
## Noir-Studio.md §4 chose and the tree already implements.
##
## Three consequences worth stating plainly, because each was a live gap:
##
##   1. `readyForEditing` is false whenever
##      `durability.mustAnnounceBeforeEditing` is true, and
##      `acknowledgeDurability` had no callers — so in the degraded conditions
##      (§4.2 rows 2 and 3) **every** `fs.writeText` returned `pkAccessDenied`
##      with *"this session has not yet told you what will happen to your
##      work"*. A save host wired to the facade without an announcement would
##      have failed silently in exactly the conditions where losing work
##      matters most. `announceDurability` shows the sentence and only then
##      acknowledges, which is the order the proc's own doc comment demands
##      ("a call site which has not shown anything reads as a lie").
##
##   2. `activateProject` sets `web.activeProjectId`, which the filesystem
##      facade addresses every read and write through. It was `""` on every
##      load.
##
##   3. The bundled template is a compile-time constant (`noir_template.nim`'s
##      header: "it costs no storage, has no retention question, works offline
##      on a second visit, and cannot rot"). That remains true and is the
##      SEED, not the working copy: on a first visit the template is written
##      into the store; on a later visit the store's copy wins. The bundle is
##      still what a visitor with an empty store gets, offline, with no fetch.
##
## ## Why an in-memory copy at all, when there is a store
##
## Because the two readers that decide what gets COMPILED are synchronous and
## the store is not. `templateVfsEntries` builds a VFS request inside
## `startNoirBuild`, and `templateTabInfo` composes a `TabInfo` inside a
## `data.ipc.respond` callback; neither can await. So `liveProject` is the
## synchronous view of the store: seeded from it before the surface mounts
## (`prepareProject`), and updated on the same call that writes through
## (`saveProjectFile`). The store is the durable truth; this is the reading of
## it that the renderer is shaped to consume.
##
## That ordering is the whole correctness argument, and it is why
## `prepareProject` runs in `ui_js.startWebArm` — which is ALREADY `{.async.}`
## and already awaits `startWebSession()` before `startWebRenderer()`. The
## restore therefore completes before a single pane exists, so no reader can
## observe the bundled bytes where the store holds edited ones.

import std/strutils

import ../viewmodel/platform/noir_template

# ---------------------------------------------------------------------------
# EMT-D17's header text
# ---------------------------------------------------------------------------

proc savedFilesLabel*(command: string; saved: seq[string]): string =
  ## The pane header, naming the files a Build or Run saved — EMT-D17.
  ##
  ## > **EMT-D17 (decision).** Run **saves all modified editors first,
  ## > unconditionally**, and the Build pane header names the files saved.
  ##
  ## `noir_build_producer.beginPhase` passes this to `BuildVM.setCommand`, and
  ## `setCommand` is what the pane's header renders ("running …"). So the
  ## header is where the names go, which is what the decision asks for, rather
  ## than an output row — `beginPhase` calls `clearOutput` immediately
  ## afterwards, so a note emitted first would be wiped a line later.
  ##
  ## SILENT WHEN NOTHING WAS SAVED. A header reading "saved nothing" on every
  ## Build of an unmodified project is noise, and worse it would make the
  ## sentence unreadable in the case it exists for. The decision's requirement
  ## is that a save the user did not ask for is VISIBLE; a save that did not
  ## happen has nothing to make visible.
  ##
  ## Lives here rather than beside the dispatch it labels because it is a pure
  ## function of two values and `web_noir_build` is a `nim js` module — this
  ## one compiles on the C backend, so `test_noir_edit_persistence` asserts the
  ## sentence directly instead of scraping it out of a browser.
  if saved.len == 0:
    return command
  command & " — saved " & saved.join(", ")

# ---------------------------------------------------------------------------
# Paths — ONE implementation, which is why they moved here
# ---------------------------------------------------------------------------
#
# `templateProjectRoot`, `templateFilePath` and `templateFileFor` used to live
# in `web_entry_surface.nim`. They are pure functions of a `ProjectTemplate`
# and this module needs all three to turn the ABSOLUTE path a save message
# carries (`/hello_noir/src/main.nr`) into the project-relative key the store
# and the template are both keyed by (`src/main.nr`). Re-deriving the prefix
# here would have been a second statement of where the project is rooted — the
# hazard `templateProjectRoot`'s own doc comment warns about — so the
# definitions moved and `web_entry_surface` imports them.

proc templateProjectRoot*(tmpl: ProjectTemplate): string =
  ## The absolute path the project takes in this session.
  ##
  ## Absolute, with a leading `/`, and that is load-bearing rather than
  ## cosmetic: `utils.openTab` treats a relative name as a path it must rescue
  ## by matching the tail of an already-open tab, and `edit_mode.sourceScore`
  ## awards `+10` for a `/src/` segment. A project rooted at `hello_noir`
  ## instead of `/hello_noir` would take the rescue branch on every tab and
  ## score `src/main.nr` ten points lower.
  ##
  ## It names no real filesystem and is not meant to: it is the identity a tab,
  ## a tree row and a breakpoint table are keyed by, which is all a path is to
  ## the renderer. The STORE is keyed by the project-relative tail instead —
  ## see `projectRelative`.
  "/" & tmpl.name

proc templateFilePath*(tmpl: ProjectTemplate; path: string): string =
  templateProjectRoot(tmpl) & "/" & path

proc projectRelative*(tmpl: ProjectTemplate; path: string): string =
  ## The project-relative key for an absolute renderer path, or `""`.
  ##
  ## `""` rather than a raise or a guess: a save naming a path outside the
  ## project is a refusal the host reports by name, not something to coerce
  ## into a key that would write to the wrong file.
  let prefix = templateProjectRoot(tmpl) & "/"
  if path.len <= prefix.len or path[0 ..< prefix.len] != prefix:
    return ""
  path[prefix.len .. ^1]

proc templateFileFor*(tmpl: ProjectTemplate; path: string): int =
  ## The index in `tmpl.files` of the file an absolute path names, or `-1`.
  let relative = projectRelative(tmpl, path)
  if relative.len == 0:
    return -1
  for index, file in tmpl.files:
    if file.path == relative:
      return index
  -1

# ---------------------------------------------------------------------------
# The one project
# ---------------------------------------------------------------------------

var liveProject: ProjectTemplate
  ## The session's working tree, in memory. THE single value every reader that
  ## used to hold its own copy now goes through.

proc currentProject*(): ProjectTemplate =
  ## What Build compiles, what a `tab-load` answers from, and what a save
  ## mutates. One accessor, so the three cannot drift.
  liveProject

proc setCurrentProject*(tmpl: ProjectTemplate) =
  liveProject = tmpl

proc hasLiveProject*(): bool =
  liveProject.hasFiles

proc applyEditToMemory*(relativePath, content: string): bool =
  ## Replace one file's content in the live project. Returns whether a file
  ## matched.
  ##
  ## Returning a bool rather than adding the file is deliberate: a save for a
  ## path the project does not carry is a bug somewhere upstream, and inventing
  ## the file would hide it. The host reports the refusal on
  ## `CODETRACER::save-file-error`, which `ui_js.onSaveFileError` already
  ## renders — the buffer stays dirty, which is the honest state.
  for index in 0 ..< liveProject.files.len:
    if liveProject.files[index].path == relativePath:
      liveProject.files[index].content = content
      return true
  false

# ---------------------------------------------------------------------------
# What the user is TOLD about where their work lives — §4.2
# ---------------------------------------------------------------------------

type
  DurabilityNoticeLevel* = enum
    ## How urgently the notice must read — and therefore which
    ## `NotificationKind` the renderer raises it as.
    ##
    ## Carried as a value rather than inferred from the sentence. A severity
    ## recovered by grepping the text is a severity that silently changes the
    ## day someone rewords the text, which is precisely what this change does
    ## to the text.
    dnlReassurance
      ## The working tree is durable and the browser has undertaken to keep it.
      ## Nothing is at risk and there is nothing for the user to do.
    dnlEvictable
      ## On disk, surviving reload and crash, and reclaimable without a prompt
      ## if the device runs low. Export is the mitigation.
    dnlUnstored
      ## Not stored at all. It goes when the tab does.

var durabilityNotice: string
  ## The sentence shown in the product, or `""` when there is nothing to say.
  ##
  ## §4.2's third row requires the in-memory case to "say so **before the first
  ## keystroke**, because work will be lost on close. Never a blank failure."
  ## `store_durability.announcementFor` composes the sentence and
  ## `DurabilityReport.mustAnnounceBeforeEditing` says whether it is required;
  ## both existed and neither was ever read by a view.

var durabilityIsDurable: bool
  ## Whether the working tree actually survives a reload, as a value a test can
  ## assert and a view can style. Not derived from the notice text.

var durabilityLevel: DurabilityNoticeLevel

proc setDurabilityNotice*(text: string; durable: bool;
                          level: DurabilityNoticeLevel) =
  durabilityNotice = text
  durabilityIsDurable = durable
  durabilityLevel = level

proc durabilityNoticeText*(): string =
  durabilityNotice

proc durabilityNoticeLevel*(): DurabilityNoticeLevel =
  durabilityLevel

proc worksSurviveReload*(): bool =
  durabilityIsDurable

# ---------------------------------------------------------------------------
# Writing through to the store
# ---------------------------------------------------------------------------
#
# ## Why the writer is INJECTED rather than imported
#
# The store lives behind `viewmodel/platform/web_platform`, which is a `nim js`
# module: it reaches OPFS, the deployment descriptor and the wasm registry.
# `ui/web_entry_surface.nim` — where the save host belongs, beside
# `installTemplateHost`, whose pattern it copies exactly — states in its own
# header that it "compiles on the C backend for unit tests". Importing the
# platform into it would end that.
#
# So the direction is inverted: this module declares the shape of a writer, the
# js-only `web_project_persistence` installs one, and a unit test installs a
# fake. The host calls `saveProjectFile` and knows nothing about OPFS. That is
# also what makes the save path assertable without a browser — the arms in
# `test_web_project_store.nim` install a writer that records, and one that
# fails, and neither needs a DOM.

type
  SaveDone* = proc(ok: bool; error: string) {.closure.}
    ## Called exactly once per save, with the outcome. `error` is the sentence
    ## the host puts on `CODETRACER::save-file-error`, which
    ## `ui_js.onSaveFileError` already renders.

  ProjectWriter* = proc(relativePath, content: string; onDone: SaveDone)
    {.closure.}
    ## Persist one file. Asynchronous by necessity — OPFS is — which is why the
    ## outcome arrives by callback rather than as a return value.

var writeThrough: ProjectWriter

proc setProjectWriter*(writer: ProjectWriter) =
  writeThrough = writer

proc hasProjectWriter*(): bool =
  not writeThrough.isNil

proc saveProjectFile*(relativePath, content: string; onDone: SaveDone) =
  ## Apply one save to the live project, then persist it.
  ##
  ## MEMORY FIRST, AND THAT ORDER IS THE POINT. What Build compiles is
  ## `currentProject()`; what survives a reload is the store. If the write
  ## through failed and the in-memory update had been made conditional on it,
  ## a visitor in a degraded storage condition (§4.2 rows 2 and 3) would press
  ## Ctrl+S, see an error, and then have Build compile the OLD bytes — the
  ## original defect, reintroduced for the users least able to afford it. The
  ## edit is what the user typed; whether it is durable is a separate fact,
  ## reported separately, and `durabilityNoticeText` is where that is said.
  ##
  ## A path the project does not carry is refused rather than created — see
  ## `applyEditToMemory`.
  if not applyEditToMemory(relativePath, content):
    onDone(false,
      "'" & relativePath & "' is not a file in this project, so nothing " &
      "was written")
    return
  if writeThrough.isNil:
    # No store — the session is in memory only, which `durabilityNotice`
    # states in the product. The save SUCCEEDED as far as this tab is
    # concerned: the editor buffer is clean, and Build now compiles it.
    onDone(true, "")
    return
  writeThrough(relativePath, content, onDone)
